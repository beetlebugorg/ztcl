//! The stress run of `aio` (task 06): a server and `--conns` clients on
//! 127.0.0.1 in one loop. The clients connect first, at most
//! `max_connecting` at a time. Then each client writes 16 bytes, the
//! server writes them back, and the client writes again, for
//! `--seconds`.
//!
//!   aio-stress [--conns N] [--seconds S] [--backend auto|uring|epoll]
//!
//! The program prints the round trips, the open descriptors, and the
//! resident memory after the connects, after the first minute (or the
//! half of a shorter run), and at the end. It exits with 1 when a
//! descriptor stays open after the close of all connections, or when the
//! memory at the end is more than 1 MiB above the memory at the
//! checkpoint.
//!
//! A run leaves the client sockets in TIME_WAIT for about a minute on
//! Linux and 30 s on macOS. A second run in that time can find no free
//! ephemeral port. Its connects then fail with EADDRNOTAVAIL, and the
//! program says to wait.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;
const sys = aio.sys;
const aio = @import("aio.zig");
const Loop = aio.Loop;
const Completion = aio.Completion;

const msg_len = 16;

/// The cap of the connects in flight, below the backlog of the
/// listener. macOS caps a backlog at kern.ipc.somaxconn, 128 by default.
const max_connecting: usize = if (@import("builtin").os.tag.isDarwin()) 100 else 256;

/// The target of the soft limit of descriptors: 10,000 connections need
/// 20,005. macOS takes a finite limit above OPEN_MAX (10,240) up to
/// kern.maxfilesperproc.
const fd_target = 40000;

var addr_busy: usize = 0;

const Conn = struct {
    fd: aio.fd_t = -1,
    peer: aio.fd_t = -1,
    c: Completion = undefined,
    s: Completion = undefined,
    cbuf: [msg_len]u8 = @splat(0x61),
    sbuf: [msg_len]u8 = undefined,
    trips: u64 = 0,
    stop: *bool,
};

var accepted: usize = 0;
var failed: usize = 0;
var connected: usize = 0;
var conns: []Conn = &.{};

fn check(r: i32) !i32 {
    if (r < 0) return error.SystemCall;
    return r;
}

const in = std.posix.sockaddr.in;

/// The count of open descriptors: the entries of /proc/self/fd on
/// Linux, and the descriptors below 65,536 that fcntl knows elsewhere.
fn openFds() usize {
    if (!sys.is_linux) {
        var n: usize = 0;
        for (0..65536) |fd| {
            if (std.c.fcntl(@intCast(fd), std.c.F.GETFD) != -1) n += 1;
        }
        return n;
    }
    var n: usize = 0;
    const dfd = aio.result(linux.open("/proc/self/fd", .{ .DIRECTORY = true, .CLOEXEC = true }, 0));
    if (dfd < 0) return 0;
    defer sys.close(dfd);
    var dents: [8192]u8 align(8) = undefined;
    while (true) {
        const got = aio.result(linux.getdents64(dfd, &dents, dents.len));
        if (got <= 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(got))) {
            const reclen = std.mem.readInt(u16, dents[off + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(dents[off + 19 ..], 0);
            if (name[0] != '.') n += 1;
            off += reclen;
        }
    }
    // The descriptor of the directory itself.
    return n - 1;
}

/// The resident size: /proc/self/statm on Linux, and the peak of
/// getrusage elsewhere (bytes on macOS).
fn rssKiB() usize {
    if (!sys.is_linux) {
        var ru: std.c.rusage = undefined;
        if (std.c.getrusage(std.c.rusage.SELF, &ru) != 0) return 0;
        return @as(usize, @intCast(ru.maxrss)) / 1024;
    }
    const fd = aio.result(linux.open("/proc/self/statm", .{ .CLOEXEC = true }, 0));
    if (fd < 0) return 0;
    defer sys.close(fd);
    var buf: [128]u8 = undefined;
    const n = aio.result(linux.read(fd, &buf, buf.len));
    if (n <= 0) return 0;
    var it = std.mem.tokenizeScalar(u8, buf[0..@intCast(n)], ' ');
    _ = it.next();
    const pages = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
    return pages * 4;
}

/// Client side: a write ended, so read the echo; a read ended, so write
/// again.
fn clientCb(l: *Loop, c: *Completion) void {
    const k: *Conn = @fieldParentPtr("c", c);
    // A connect gives 0, a read or a write gives the count of bytes.
    if (c.result < 0 and c.op == .connect) {
        failed += 1;
        if (c.result == -@as(i32, @backingInt(std.posix.E.ADDRNOTAVAIL))) addr_busy += 1;
    }
    if (c.result < 0 or (c.result == 0 and c.op != .connect)) return;
    switch (c.op) {
        .write => c.op = .{ .read = .{ .fd = k.fd, .buf = &k.cbuf } },
        .read => {
            k.trips += 1;
            if (k.stop.*) return;
            c.op = .{ .write = .{ .fd = k.fd, .buf = &k.cbuf } };
        },
        else => {
            // The connect ended. The writes start after the last accept.
            connected += 1;
            return;
        },
    }
    l.submit(c) catch {};
}

fn serverCb(l: *Loop, c: *Completion) void {
    const k: *Conn = @fieldParentPtr("s", c);
    if (c.result <= 0) return;
    switch (c.op) {
        .read => |o| c.op = .{ .write = .{ .fd = k.peer, .buf = o.buf[0..@intCast(c.result)] } },
        else => c.op = .{ .read = .{ .fd = k.peer, .buf = &k.sbuf } },
    }
    l.submit(c) catch {};
}

fn acceptCb(l: *Loop, c: *Completion) void {
    if (c.result < 0) {
        l.submit(c) catch {};
        return;
    }
    const k = &conns[accepted];
    accepted += 1;
    k.peer = c.result;
    k.s = .{ .op = .{ .read = .{ .fd = k.peer, .buf = &k.sbuf } }, .callback = serverCb };
    l.submit(&k.s) catch {};
    if (accepted < conns.len) l.submit(c) catch {};
}

fn stopCb(_: *Loop, c: *Completion) void {
    const stop: *bool = @ptrCast(@alignCast(c.ctx.?));
    stop.* = true;
}

/// macOS starts a process with 256 descriptors: raise the soft limit
/// to the hard limit, at most OPEN_MAX (10,240).
fn raiseFdLimit() void {
    var lim: std.c.rlimit = undefined;
    if (std.c.getrlimit(.NOFILE, &lim) != 0) return;
    lim.cur = @min(lim.max, fd_target);
    _ = std.c.setrlimit(.NOFILE, &lim);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var n_conns: usize = 1000;
    var seconds: u64 = 10;
    var backend: aio.Backend = .auto;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--conns")) n_conns = try std.fmt.parseInt(usize, args[i + 1], 10) else if (std.mem.eql(u8, args[i], "--seconds")) seconds = try std.fmt.parseInt(u64, args[i + 1], 10) else if (std.mem.eql(u8, args[i], "--backend")) backend = std.meta.stringToEnum(aio.Backend, args[i + 1]) orelse return error.BadBackend else return error.BadOption;
    }
    const fds_start = openFds();
    var l = try Loop.init(init.gpa, .{ .backend = backend, .entries = 4096 });
    defer l.deinit();
    std.debug.print("backend {t}, {d} connections, {d} s\n", .{ l.backend(), n_conns, seconds });
    if (!sys.is_linux) raiseFdLimit();
    var addr = std.mem.zeroes(in);
    addr.family = std.posix.AF.INET;
    addr.addr = std.mem.nativeToBig(u32, 0x7f000001);
    if (@hasField(in, "len")) addr.len = @sizeOf(in);
    const lfd = try check(sys.tcpSocket(std.posix.AF.INET));
    _ = try check(sys.bind(lfd, @ptrCast(&addr), @sizeOf(in)));
    _ = try check(sys.listen(lfd, 4096));
    var len: sys.socklen_t = @sizeOf(in);
    _ = try check(sys.getsockname(lfd, @ptrCast(&addr), &len));
    var stop = false;
    conns = try a.alloc(Conn, n_conns);
    var acc: Completion = .{ .op = .{ .accept = .{ .fd = lfd } }, .callback = acceptCb };
    try l.submit(&acc);
    for (conns, 0..) |*k, n| {
        // Keep the connects in progress below the backlog of the
        // listener.
        while (n - accepted - failed > max_connecting) _ = try l.run(std.time.ns_per_s);
        k.* = .{ .stop = &stop };
        k.fd = try check(sys.tcpSocket(std.posix.AF.INET));
        k.c = .{ .op = .{ .connect = .{ .fd = k.fd, .addr = @ptrCast(&addr), .len = @sizeOf(in) } }, .callback = clientCb };
        try l.submit(&k.c);
    }
    while (accepted + failed < n_conns or connected + failed < n_conns) _ = try l.run(std.time.ns_per_s);
    if (failed > 0) {
        std.debug.print("FAIL: {d} connects failed\n", .{failed});
        if (addr_busy > 0) std.debug.print("{d} found no free ephemeral port: sockets of an earlier run wait in TIME_WAIT; wait a minute and run again\n", .{addr_busy});
        std.process.exit(1);
    }
    for (conns) |*k| {
        k.c.op = .{ .write = .{ .fd = k.fd, .buf = &k.cbuf } };
        try l.submit(&k.c);
    }
    std.debug.print("connected: fds {d}, rss {d} KiB\n", .{ openFds(), rssKiB() });
    var timer: Completion = .{ .op = .{ .timer = .{ .ns = seconds * std.time.ns_per_s } }, .callback = stopCb, .ctx = &stop };
    try l.submit(&timer);
    const mark_s: u64 = @min(60, seconds / 2);
    const mark_at = aio.now() + mark_s * std.time.ns_per_s;
    var mark_rss: usize = 0;
    while (!stop) {
        _ = try l.run(std.time.ns_per_s);
        if (mark_rss == 0 and aio.now() >= mark_at) {
            mark_rss = rssKiB();
            std.debug.print("checkpoint: rss {d} KiB\n", .{mark_rss});
        }
    }
    // Each client ends after its next read.
    while (for (conns) |*k| {
        if (k.c.state == .pending) break true;
    } else false) _ = try l.run(std.time.ns_per_s);
    const end_rss = rssKiB();
    // The reads of the server wait for data: cancel them before the
    // close.
    for (conns) |*k| try l.cancel(&k.s);
    try l.cancel(&acc);
    try l.runAll();
    var trips: u64 = 0;
    for (conns) |*k| {
        trips += k.trips;
        sys.close(k.fd);
        sys.close(k.peer);
    }
    sys.close(lfd);
    const fds_end = openFds();
    std.debug.print("round trips {d}, end rss {d} KiB, fds before {d}, after {d}\n", .{ trips, end_rss, fds_start, fds_end });
    // The loop itself has its descriptors to the deinit.
    const loop_fds: usize = 2;
    var bad = false;
    if (fds_end > fds_start + loop_fds) {
        std.debug.print("FAIL: {d} descriptors stay open\n", .{fds_end - fds_start - loop_fds});
        bad = true;
    }
    if (mark_rss > 0 and end_rss > mark_rss + 1024) {
        std.debug.print("FAIL: the memory grew from {d} KiB to {d} KiB after the checkpoint\n", .{ mark_rss, end_rss });
        bad = true;
    }
    if (bad) std.process.exit(1);
}

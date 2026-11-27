//! The tests of `aio`. Each test runs on each backend of the system:
//! io_uring and epoll on Linux, kqueue on macOS, IOCP on Windows. io_uring is skipped
//! when the kernel refuses it.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const aio = @import("aio.zig");
const sys = aio.sys;
const Loop = aio.Loop;
const Completion = aio.Completion;
const in = std.posix.sockaddr.in;

const backends = if (sys.is_linux) [_]aio.Backend{ .uring, .epoll } else if (sys.is_windows) [_]aio.Backend{.iocp} else [_]aio.Backend{.kqueue};

fn open(b: aio.Backend) !?Loop {
    return Loop.init(std.testing.allocator, .{ .backend = b }) catch |e| {
        if (b == .uring) return null;
        return e;
    };
}

fn check(r: i32) !i32 {
    if (r < 0) return error.SystemCall;
    return r;
}

/// A listening TCP socket on 127.0.0.1 with a port of the kernel.
fn listener(addr: *in) !aio.fd_t {
    const fd = try check(sys.tcpSocket(std.posix.AF.INET));
    addr.* = std.mem.zeroes(in);
    addr.family = std.posix.AF.INET;
    if (@hasField(in, "len")) addr.len = @sizeOf(in);
    addr.addr = std.mem.nativeToBig(u32, 0x7f000001);
    _ = try check(sys.bind(fd, @ptrCast(addr), @sizeOf(in)));
    _ = try check(sys.listen(fd, 128));
    var len: sys.socklen_t = @sizeOf(in);
    _ = try check(sys.getsockname(fd, @ptrCast(addr), &len));
    return fd;
}

fn tcpSocket() !aio.fd_t {
    return check(sys.tcpSocket(std.posix.AF.INET));
}

const Log = struct {
    order: [8]u8 = undefined,
    n: usize = 0,

    fn cb(_: *Loop, c: *Completion) void {
        const log: *Log = @ptrCast(@alignCast(c.ctx.?));
        log.order[log.n] = @intCast(c.result & 0xff);
        log.n += 1;
    }

    fn mark(_: *Loop, c: *Completion) void {
        const log: *Log = @ptrCast(@alignCast(c.ctx.?));
        log.order[log.n] = if (c.op == .timer) @intCast(c.op.timer.ns / std.time.ns_per_ms) else 0;
        log.n += 1;
    }
};

fn noop(_: *Loop, _: *Completion) void {}

test "accept, connect, write, writev, and read on loopback" {
    for (backends) |b| {
        var l = (try open(b)) orelse continue;
        defer l.deinit();
        var addr: in = undefined;
        const lfd = try listener(&addr);
        defer sys.close(lfd);
        const cfd = try tcpSocket();
        defer sys.close(cfd);
        var acc: Completion = .{ .op = .{ .accept = .{ .fd = lfd } }, .callback = noop };
        var con: Completion = .{ .op = .{ .connect = .{ .fd = cfd, .addr = @ptrCast(&addr), .len = @sizeOf(in) } }, .callback = noop };
        try l.submit(&acc);
        try l.submit(&con);
        try l.runAll();
        try std.testing.expectEqual(@as(i32, 0), con.result);
        try std.testing.expect(acc.result >= 0);
        const sfd: aio.fd_t = acc.result;
        defer sys.close(sfd);
        var buf: [16]u8 = undefined;
        var rd: Completion = .{ .op = .{ .read = .{ .fd = sfd, .buf = &buf } }, .callback = noop };
        try l.submit(&rd);
        var wr: Completion = .{ .op = .{ .write = .{ .fd = cfd, .buf = "hello" } }, .callback = noop };
        try l.submit(&wr);
        try l.runAll();
        try std.testing.expectEqual(@as(i32, 5), wr.result);
        try std.testing.expectEqualStrings("hello", buf[0..@intCast(rd.result)]);
        // A writev sends its buffers in order.
        const iov = [_]std.posix.iovec_const{ .{ .base = "ab", .len = 2 }, .{ .base = "cde", .len = 3 } };
        rd = .{ .op = .{ .read = .{ .fd = sfd, .buf = &buf } }, .callback = noop };
        try l.submit(&rd);
        wr = .{ .op = .{ .writev = .{ .fd = cfd, .iov = &iov } }, .callback = noop };
        try l.submit(&wr);
        try l.runAll();
        try std.testing.expectEqual(@as(i32, 5), wr.result);
        try std.testing.expectEqualStrings("abcde", buf[0..@intCast(rd.result)]);
        // The end of the stream reads as 0.
        sys.shutdownWrite(cfd);
        rd = .{ .op = .{ .read = .{ .fd = sfd, .buf = &buf } }, .callback = noop };
        try l.submit(&rd);
        try l.runAll();
        try std.testing.expectEqual(@as(i32, 0), rd.result);
    }
}

test "a connect to a closed port gives ECONNREFUSED" {
    for (backends) |b| {
        var l = (try open(b)) orelse continue;
        defer l.deinit();
        var addr: in = undefined;
        const lfd = try listener(&addr);
        sys.close(lfd);
        const cfd = try tcpSocket();
        defer sys.close(cfd);
        var con: Completion = .{ .op = .{ .connect = .{ .fd = cfd, .addr = @ptrCast(&addr), .len = @sizeOf(in) } }, .callback = noop };
        try l.submit(&con);
        try l.runAll();
        try std.testing.expectEqual(sys.neg(.CONNREFUSED), con.result);
    }
}

test "timers end in the order of their deadlines" {
    for (backends) |b| {
        var l = (try open(b)) orelse continue;
        defer l.deinit();
        var log: Log = .{};
        var t: [3]Completion = undefined;
        for (&t, [_]u64{ 30, 10, 20 }) |*c, ms| {
            c.* = .{ .op = .{ .timer = .{ .ns = ms * std.time.ns_per_ms } }, .callback = Log.mark, .ctx = &log };
            try l.submit(c);
        }
        const start = aio.now();
        try l.runAll();
        try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, log.order[0..log.n]);
        try std.testing.expect(aio.now() - start >= 30 * std.time.ns_per_ms);
    }
}

test "cancel ends a read and a timer with ECANCELED" {
    for (backends) |b| {
        var l = (try open(b)) orelse continue;
        defer l.deinit();
        var fds: [2]i32 = undefined;
        _ = try check(sys.pipe(&fds));
        defer sys.close(fds[0]);
        defer sys.close(fds[1]);
        var buf: [4]u8 = undefined;
        var rd: Completion = .{ .op = .{ .read = .{ .fd = fds[0], .buf = &buf } }, .callback = noop };
        var tm: Completion = .{ .op = .{ .timer = .{ .ns = 10 * std.time.ns_per_s } }, .callback = noop };
        try l.submit(&rd);
        try l.submit(&tm);
        try std.testing.expectEqual(@as(usize, 0), try l.run(5 * std.time.ns_per_ms));
        try l.cancel(&rd);
        try l.cancel(&tm);
        try l.runAll();
        const canceled = sys.neg(.CANCELED);
        try std.testing.expectEqual(canceled, rd.result);
        try std.testing.expectEqual(canceled, tm.result);
    }
}

test "a wait with a time limit ends, and wake ends a wait from another thread" {
    for (backends) |b| {
        var l = (try open(b)) orelse continue;
        defer l.deinit();
        var start = aio.now();
        try std.testing.expectEqual(@as(usize, 0), try l.run(20 * std.time.ns_per_ms));
        const took = aio.now() - start;
        try std.testing.expect(took >= 15 * std.time.ns_per_ms and took < 2 * std.time.ns_per_s);
        const th = try std.Thread.spawn(.{}, struct {
            fn f(loop: *Loop) void {
                sys.sleepNs(20 * std.time.ns_per_ms);
                loop.wake();
            }
        }.f, .{&l});
        start = aio.now();
        _ = try l.run(null);
        th.join();
        try std.testing.expect(aio.now() - start < 5 * std.time.ns_per_s);
    }
}

/// A callback that submits the next read on the same completion.
const Echo = struct {
    fd: aio.fd_t,
    buf: [64]u8 = undefined,
    got: usize = 0,

    fn cb(l: *Loop, c: *Completion) void {
        const e: *Echo = @ptrCast(@alignCast(c.ctx.?));
        if (c.result <= 0) return;
        e.got += @intCast(c.result);
        c.op = .{ .read = .{ .fd = e.fd, .buf = &e.buf } };
        l.submit(c) catch {};
    }
};

test "a callback submits again on its own completion" {
    for (backends) |b| {
        var l = (try open(b)) orelse continue;
        defer l.deinit();
        var fds: [2]i32 = undefined;
        _ = try check(sys.pipe(&fds));
        defer sys.close(fds[0]);
        var e: Echo = .{ .fd = fds[0] };
        var rd: Completion = .{ .op = .{ .read = .{ .fd = fds[0], .buf = &e.buf } }, .callback = Echo.cb, .ctx = &e };
        try l.submit(&rd);
        for (0..3) |_| {
            _ = sys.write(fds[1], "abc");
            _ = try l.run(std.time.ns_per_s);
        }
        sys.close(fds[1]);
        try l.runAll();
        try std.testing.expectEqual(@as(usize, 9), e.got);
    }
}

test "auto uses a backend that works" {
    var l = try Loop.init(std.testing.allocator, .{});
    defer l.deinit();
    try std.testing.expect(l.backend() != .auto);
}

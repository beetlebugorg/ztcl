//! The guest agent of `ztcl::vm` (ztcl#203): the protocol of
//! `docs/dev/vm-agent.md` on vsock port 1024 (`exec`, `mount`, the
//! kernel log), and the probe of the start time on port 1025: 16 bytes
//! of the boot clock, then an echo, or the kernel log after a first
//! byte of 1.
//!
//! As the first process (`rdinit=/sbin/agent`), the agent mounts /proc,
//! /sys, /dev, /tmp, and the virtio-fs share `share0` at /mnt/share when
//! the guest has it. Each connection runs in a child process. The agent
//! uses no libc, so one file builds for each architecture:
//!
//!   zig build-exe -target aarch64-linux-musl -O ReleaseSmall agent.zig
//!   zig build-exe -target x86_64-linux-musl -O ReleaseSmall agent.zig
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const linux = std.os.linux;

const AF_VSOCK = 40;
const VMADDR_CID_ANY: u32 = 0xffff_ffff;
const port_agent: u32 = 1024;
const port_probe: u32 = 1025;
const version: u16 = 1;
const features: u32 = 0b111;
const max_frame = (1 << 20) + 1;

const t_hello = 0x01;
const t_exec = 0x10;
const t_mount = 0x11;
const t_log = 0x12;
const t_ping = 0x13;
const t_started = 0x20;
const t_stdout = 0x21;
const t_stderr = 0x22;
const t_stdin = 0x23;
const t_signal = 0x24;
const t_exit = 0x25;
const t_ok = 0x30;
const t_data = 0x31;
const t_error = 0x3f;

const SockaddrVm = extern struct {
    family: u16 = AF_VSOCK,
    reserved1: u16 = 0,
    port: u32,
    cid: u32,
    flags: u8 = 0,
    zero: [3]u8 = .{ 0, 0, 0 },
};

fn ok(rc: usize) ?usize {
    return if (linux.errno(rc) == .SUCCESS) rc else null;
}

fn errnoOf(rc: usize) u32 {
    return @backingInt(linux.errno(rc));
}

fn say(text: []const u8) void {
    _ = linux.write(2, text.ptr, text.len);
}

fn bootNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.BOOTTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

var times: [2]u64 = .{ 0, 0 };

/// The options of a 9p share of virtio.
const nine_p_options: [*:0]const u8 = "trans=virtio,version=9p2000.L";

// ---- The start ----

fn mkdirs(path: [*:0]const u8) void {
    var buf: [512]u8 = undefined;
    const p = std.mem.sliceTo(path, 0);
    if (p.len >= buf.len) return;
    var k: usize = 1;
    while (k <= p.len) : (k += 1) {
        if (k == p.len or p[k] == '/') {
            @memcpy(buf[0..k], p[0..k]);
            buf[k] = 0;
            _ = linux.mkdir(@ptrCast(&buf), 0o755);
        }
    }
}

fn mounts() void {
    mkdirs("/proc");
    mkdirs("/sys");
    mkdirs("/dev");
    mkdirs("/tmp");
    _ = linux.mount("proc", "/proc", "proc", 0, 0);
    _ = linux.mount("sys", "/sys", "sysfs", 0, 0);
    _ = linux.mount("dev", "/dev", "devtmpfs", 0, 0);
    _ = linux.mount("tmp", "/tmp", "tmpfs", 0, 0);
    // On the read-only root disk of a signed image, /mnt is a tmpfs, so
    // a mount point can be made there.
    mkdirs("/mnt");
    _ = linux.mount("mnt", "/mnt", "tmpfs", 0, 0);
    mkdirs("/mnt/share");
    // virtio-fs on Virtualization.framework, 9p on the KVM monitor.
    if (linux.errno(linux.mount("share0", "/mnt/share", "virtiofs", 0, 0)) != .SUCCESS)
        _ = linux.mount("share0", "/mnt/share", "9p", 0, @intFromPtr(nine_p_options));
}

fn listenOnce(port: u32) ?i32 {
    const fd: i32 = @intCast(ok(linux.socket(AF_VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) orelse return null);
    var addr: SockaddrVm = .{ .port = port, .cid = VMADDR_CID_ANY };
    if (ok(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrVm))) == null or ok(linux.listen(fd, 16)) == null) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// Listens on `port`. With `driver_async_probe=virtio-pci` the device of
/// vsock may come a moment after the agent starts, so a failure is
/// tried again each 0.2 ms for up to 2 seconds.
fn listenOn(port: u32) ?i32 {
    var k: u32 = 0;
    while (k < 10_000) : (k += 1) {
        if (listenOnce(port)) |fd| return fd;
        const ts: linux.timespec = .{ .sec = 0, .nsec = 200_000 };
        _ = linux.nanosleep(&ts, null);
    }
    return null;
}

pub fn main(init: std.process.Init.Minimal) void {
    // `agent connect PORT`: a client of the host on vsock, for the tests
    // of `ztcl::vm listen` and for a relay of a program of the guest.
    const argv = init.args.vector;
    if (argv.len == 3 and std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "connect")) {
        const port = std.fmt.parseInt(u32, std.mem.sliceTo(argv[2], 0), 10) catch return say("agent: bad port\n");
        return relay(port);
    }
    times[0] = bootNs();
    if (linux.getpid() == 1) mounts();
    // The children of the connections, and each orphan when the agent is
    // the first process, end with no wait.
    var sa: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(linux.SIG.CHLD, &sa, null);
    const a = listenOn(port_agent) orelse return say("agent: no vsock on 1024\n");
    const p = listenOn(port_probe) orelse return say("agent: no vsock on 1025\n");
    times[1] = bootNs();
    while (true) {
        var fds = [2]linux.pollfd{
            .{ .fd = a, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = p, .events = linux.POLL.IN, .revents = 0 },
        };
        _ = ok(linux.poll(&fds, 2, -1)) orelse continue;
        for (fds) |f| {
            if (f.revents == 0) continue;
            const c: i32 = @intCast(ok(linux.accept4(f.fd, null, null, linux.SOCK.CLOEXEC)) orelse continue);
            const pid = linux.fork();
            if (pid == 0) {
                _ = linux.close(a);
                _ = linux.close(p);
                var dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
                _ = linux.sigaction(linux.SIG.CHLD, &dfl, null);
                if (f.fd == a) serve(c) else probe(c);
                linux.exit_group(0);
            }
            _ = linux.close(c);
        }
    }
}

// ---- Port 1025: the probe of the start time ----

var log: [256 * 1024]u8 = undefined;

fn kernelLog() []const u8 {
    // syslog(2), SYSLOG_ACTION_READ_ALL.
    const len = ok(linux.syscall3(.syslog, 3, @intFromPtr(&log), log.len)) orelse 0;
    return log[0..len];
}

fn probe(c: i32) void {
    const head = std.mem.asBytes(&times);
    writeAll(c, head);
    var buf: [4096]u8 = undefined;
    var first = true;
    while (true) {
        const n = ok(linux.read(c, &buf, buf.len)) orelse return;
        if (n == 0) return;
        if (first and buf[0] == 1) return writeAll(c, kernelLog());
        first = false;
        writeAll(c, buf[0..n]);
    }
}

// ---- Port 1024: the protocol ----

fn writeAll(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) off += ok(linux.write(fd, bytes[off..].ptr, bytes.len - off)) orelse return;
}

fn send(c: i32, kind: u8, payload: []const u8) void {
    var head: [5]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], @intCast(payload.len + 1), .little);
    head[4] = kind;
    writeAll(c, &head);
    writeAll(c, payload);
}

fn sendError(c: i32, err: u32, text: []const u8) void {
    var b: [264]u8 = undefined;
    const t = text[0..@min(text.len, 256)];
    std.mem.writeInt(u32, b[0..4], err, .little);
    std.mem.writeInt(u32, b[4..8], @intCast(t.len), .little);
    @memcpy(b[8..][0..t.len], t);
    send(c, t_error, b[0 .. 8 + t.len]);
}

const Frame = struct { kind: u8, payload: []u8, size: usize };

/// The frames of the host: a buffer that fills from the socket.
const In = struct {
    fd: i32,
    buf: []u8,
    have: usize = 0,

    /// Reads more bytes. False at the end of the stream.
    fn fill(in: *In) bool {
        if (in.have == in.buf.len) return false;
        const n = ok(linux.read(in.fd, in.buf[in.have..].ptr, in.buf.len - in.have)) orelse return false;
        if (n == 0) return false;
        in.have += n;
        return true;
    }

    /// A whole frame at the front, or null.
    fn frame(in: *In) ?Frame {
        if (in.have < 5) return null;
        const len = std.mem.readInt(u32, in.buf[0..4], .little);
        if (len == 0 or len > max_frame) return null;
        if (in.have < 4 + len) return null;
        return .{ .kind = in.buf[4], .payload = in.buf[5 .. 4 + len], .size = 4 + len };
    }

    fn drop(in: *In, n: usize) void {
        std.mem.copyForwards(u8, in.buf[0 .. in.have - n], in.buf[n..in.have]);
        in.have -= n;
    }

    /// Waits for one whole frame. Null at the end of the stream or on a
    /// bad length.
    fn next(in: *In) ?Frame {
        while (true) {
            if (in.frame()) |f| return f;
            if (in.have >= 4) {
                const len = std.mem.readInt(u32, in.buf[0..4], .little);
                if (len == 0 or len > max_frame) return null;
            }
            if (!in.fill()) return null;
        }
    }
};

var in_buf: [max_frame + 4]u8 = undefined;
var req_buf: [max_frame]u8 = undefined;

fn serve(c: i32) void {
    var hello: [22]u8 = undefined;
    std.mem.writeInt(u16, hello[0..2], version, .little);
    std.mem.writeInt(u32, hello[2..6], features, .little);
    std.mem.writeInt(u64, hello[6..14], times[0], .little);
    std.mem.writeInt(u64, hello[14..22], times[1], .little);
    send(c, t_hello, &hello);
    var in: In = .{ .fd = c, .buf = &in_buf };
    const f = in.next() orelse return;
    // The request moves out of the buffer, which then holds the frames
    // that come after it.
    const req = req_buf[0..f.payload.len];
    @memcpy(req, f.payload);
    const kind = f.kind;
    in.drop(f.size);
    var r: Reader = .{ .b = req };
    switch (kind) {
        t_ping => send(c, t_ok, ""),
        t_log => {
            const l = kernelLog();
            var off: usize = 0;
            while (off < l.len) : (off += 1 << 16) send(c, t_data, l[off..@min(l.len, off + (1 << 16))]);
            send(c, t_ok, "");
        },
        t_mount => mount(c, &r),
        t_exec => exec(c, &in, req) catch sendError(c, 22, "bad exec request"),
        else => sendError(c, 95, "unknown request"),
    }
}

const Reader = struct {
    b: []const u8,
    i: usize = 0,

    fn int(r: *Reader, comptime T: type) ?T {
        if (r.b.len - r.i < @sizeOf(T)) return null;
        defer r.i += @sizeOf(T);
        return std.mem.readInt(T, r.b[r.i..][0..@sizeOf(T)], .little);
    }
    fn str(r: *Reader) ?[]const u8 {
        const n = r.int(u32) orelse return null;
        if (r.b.len - r.i < n) return null;
        defer r.i += n;
        return r.b[r.i..][0..n];
    }
};

/// Copies `s` with a NUL into `area` at `at`.
fn putZ(area: []u8, at: *usize, s: []const u8) ?[*:0]u8 {
    if (area.len - at.* < s.len + 1) return null;
    const p = area[at.*..];
    @memcpy(p[0..s.len], s);
    p[s.len] = 0;
    at.* += s.len + 1;
    return @ptrCast(p.ptr);
}

fn mount(c: i32, r: *Reader) void {
    var area: [1024]u8 = undefined;
    var at: usize = 0;
    const tag = putZ(&area, &at, r.str() orelse return sendError(c, 22, "bad mount request")) orelse return sendError(c, 36, "name too long");
    const path = putZ(&area, &at, r.str() orelse return sendError(c, 22, "bad mount request")) orelse return sendError(c, 36, "name too long");
    const flags = r.int(u8) orelse 0;
    mkdirs(path);
    const ro: u32 = if (flags & 1 != 0) linux.MS.RDONLY else 0;
    // Bit 1: a 9p share (the KVM monitor) in the place of virtio-fs.
    const rc = if (flags & 2 != 0)
        linux.mount(tag, path, "9p", ro, @intFromPtr(nine_p_options))
    else
        linux.mount(tag, path, "virtiofs", ro, 0);
    if (linux.errno(rc) != .SUCCESS) return sendError(c, errnoOf(rc), "mount failed");
    send(c, t_ok, "");
}

var strings: [1 << 20]u8 = undefined;
var argv_buf: [1024:null]?[*:0]const u8 = undefined;
var env_buf: [1024:null]?[*:0]const u8 = undefined;

fn list(r: *Reader, at: *usize, out: [:null]?[*:0]const u8) !void {
    const n = r.int(u32) orelse return error.Bad;
    if (n > out.len) return error.Bad;
    for (0..n) |k| out[k] = putZ(&strings, at, r.str() orelse return error.Bad) orelse return error.Bad;
    out[n] = null;
}

fn pipe() ?[2]i32 {
    var p: [2]i32 = undefined;
    _ = ok(linux.pipe2(&p, .{ .CLOEXEC = true })) orelse return null;
    return p;
}

/// Handles the whole frames of the host in the buffer: `STDIN` and
/// `SIGNAL`.
fn takeFrames(in: *In, child: i32, stdin_fd: *i32) void {
    while (in.frame()) |f| {
        switch (f.kind) {
            t_stdin => if (stdin_fd.* >= 0) {
                if (f.payload.len == 0) {
                    _ = linux.close(stdin_fd.*);
                    stdin_fd.* = -1;
                } else writeAll(stdin_fd.*, f.payload);
            },
            t_signal => if (f.payload.len >= 1) {
                _ = linux.syscall2(.kill, @as(usize, @bitCast(@as(isize, child))), f.payload[0]);
            },
            else => {},
        }
        in.drop(f.size);
    }
}

fn devNull() i32 {
    return @intCast(ok(linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0)) orelse 0);
}

fn exec(c: i32, in: *In, payload: []const u8) !void {
    var r: Reader = .{ .b = payload };
    var at: usize = 0;
    try list(&r, &at, &argv_buf);
    try list(&r, &at, &env_buf);
    const cwd_s = r.str() orelse return error.Bad;
    const cwd = putZ(&strings, &at, if (cwd_s.len == 0) "/" else cwd_s) orelse return error.Bad;
    const flags = r.int(u8) orelse 0;
    const prog = argv_buf[0] orelse return error.Bad;
    const pin = pipe() orelse return sendError(c, 24, "no pipe");
    const pout = pipe() orelse return sendError(c, 24, "no pipe");
    const perr = pipe() orelse return sendError(c, 24, "no pipe");
    const pstat = pipe() orelse return sendError(c, 24, "no pipe");
    const pid = linux.fork();
    if (pid == 0) {
        _ = linux.dup3(if (flags & 1 != 0) pin[0] else devNull(), 0, 0);
        _ = linux.dup3(pout[1], 1, 0);
        _ = linux.dup3(perr[1], 2, 0);
        var e: u32 = 0;
        const cd = linux.chdir(cwd);
        if (linux.errno(cd) != .SUCCESS) {
            e = errnoOf(cd);
        } else {
            e = errnoOf(linux.execve(prog, &argv_buf, &env_buf));
        }
        // execve failed: the errno goes to the agent over the pipe of the
        // status, which closes at a good execve.
        _ = linux.write(pstat[1], std.mem.asBytes(&e), 4);
        linux.exit_group(127);
    }
    if (linux.errno(pid) != .SUCCESS) return sendError(c, errnoOf(pid), "fork failed");
    const child: i32 = @intCast(pid);
    _ = linux.close(pin[0]);
    _ = linux.close(pout[1]);
    _ = linux.close(perr[1]);
    _ = linux.close(pstat[1]);
    var e: u32 = 0;
    if ((ok(linux.read(pstat[0], std.mem.asBytes(&e), 4)) orelse 0) == 4) {
        var st: i32 = 0;
        _ = linux.wait4(child, &st, 0, null);
        return sendError(c, e, "exec failed");
    }
    _ = linux.close(pstat[0]);
    var started: [4]u8 = undefined;
    std.mem.writeInt(u32, &started, @intCast(child), .little);
    send(c, t_started, &started);

    var stdin_fd: i32 = -1;
    if (flags & 1 != 0) stdin_fd = pin[1] else _ = linux.close(pin[1]);
    var out_fd: i32 = pout[0];
    var err_fd: i32 = perr[0];
    var conn_open = true;
    var buf: [65536]u8 = undefined;
    // Frames that came with the request wait in the buffer already.
    takeFrames(in, child, &stdin_fd);
    while (out_fd >= 0 or err_fd >= 0) {
        var fds = [3]linux.pollfd{
            .{ .fd = if (conn_open) c else -1, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = out_fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = err_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        _ = ok(linux.poll(&fds, 3, -1)) orelse continue;
        if (fds[0].revents != 0) {
            if (!in.fill()) {
                // The host went away: the program ends.
                _ = linux.kill(child, linux.SIG.KILL);
                conn_open = false;
            }
            takeFrames(in, child, &stdin_fd);
        }
        inline for (.{ 1, 2 }) |k| {
            if (fds[k].revents != 0) {
                const fd = if (k == 1) out_fd else err_fd;
                const n = ok(linux.read(fd, &buf, buf.len)) orelse 0;
                if (n == 0) {
                    _ = linux.close(fd);
                    if (k == 1) out_fd = -1 else err_fd = -1;
                } else if (conn_open) send(c, if (k == 1) t_stdout else t_stderr, buf[0..n]);
            }
        }
    }
    if (stdin_fd >= 0) _ = linux.close(stdin_fd);
    var st: i32 = 0;
    _ = linux.wait4(child, &st, 0, null);
    const status: u32 = @bitCast(st);
    const code: i32 = if (linux.W.IFEXITED(status)) @intCast(linux.W.EXITSTATUS(status)) else -@as(i32, @intCast(status & 0x7f));
    var ex: [4]u8 = undefined;
    std.mem.writeInt(i32, &ex, code, .little);
    if (conn_open) send(c, t_exit, &ex);
}

fn fail(text: []const u8) noreturn {
    say(text);
    linux.exit_group(1);
}

/// The CID of the host.
const VMADDR_CID_HOST: u32 = 2;

/// Connects to `port` of the host and copies stdin to the connection and
/// the connection to stdout, until both ends close.
fn relay(port: u32) void {
    const fd: i32 = @intCast(ok(linux.socket(AF_VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) orelse fail("agent: no vsock\n"));
    var addr: SockaddrVm = .{ .port = port, .cid = VMADDR_CID_HOST };
    _ = ok(linux.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrVm))) orelse fail("agent: no connection to the host\n");
    var in_open = true;
    var buf: [65536]u8 = undefined;
    while (true) {
        var fds = [2]linux.pollfd{
            .{ .fd = if (in_open) 0 else -1, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
        };
        _ = ok(linux.poll(&fds, 2, -1)) orelse continue;
        if (fds[0].revents != 0) {
            const n = ok(linux.read(0, &buf, buf.len)) orelse 0;
            if (n == 0) {
                in_open = false;
                _ = linux.shutdown(fd, linux.SHUT.WR);
            } else writeAll(fd, buf[0..n]);
        }
        if (fds[1].revents != 0) {
            const n = ok(linux.read(fd, &buf, buf.len)) orelse 0;
            if (n == 0) return;
            writeAll(1, buf[0..n]);
        }
    }
}

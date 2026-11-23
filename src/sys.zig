//! The platform interface of the event loop, `socket`, and `exec`.
//!
//! Each function here is one small host operation on a descriptor. The
//! callers (`event.zig`, `sock.zig`, `proc.zig`, `chan.zig`) have no
//! other platform code. This file has the Linux form, with direct
//! system calls. A port to another system writes these functions again
//! with the same contracts and sets `supported`.
//!
//! The rules of a port:
//! - `listenLoop` and `connectLoop` accept only a loopback address.
//!   They get the address as bytes, so no name lookup goes to a
//!   resolver.
//! - Each descriptor closes on exec.
//! - A call that the system interrupts runs again.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const supported = builtin.os.tag == .linux;

pub const Fd = i32;

/// A host error, as the POSIX name and the text of Tcl.
pub const Fail = struct { name: []const u8, text: []const u8 };

pub fn failOf(e: linux.E) Fail {
    return switch (e) {
        .NOENT => .{ .name = "ENOENT", .text = "no such file or directory" },
        .ACCES, .PERM => .{ .name = "EACCES", .text = "permission denied" },
        .CONNREFUSED => .{ .name = "ECONNREFUSED", .text = "connection refused" },
        .ADDRINUSE => .{ .name = "EADDRINUSE", .text = "address already in use" },
        .ADDRNOTAVAIL => .{ .name = "EADDRNOTAVAIL", .text = "can't assign requested address" },
        .CONNRESET => .{ .name = "ECONNRESET", .text = "connection reset by peer" },
        .PIPE => .{ .name = "EPIPE", .text = "broken pipe" },
        .NOTCONN => .{ .name = "ENOTCONN", .text = "socket is not connected" },
        .TIMEDOUT => .{ .name = "ETIMEDOUT", .text = "connection timed out" },
        .AGAIN => .{ .name = "EAGAIN", .text = "resource temporarily unavailable" },
        .INVAL => .{ .name = "EINVAL", .text = "invalid argument" },
        .BADF => .{ .name = "EBADF", .text = "bad file number" },
        .NOEXEC => .{ .name = "ENOEXEC", .text = "exec format error" },
        .ISDIR => .{ .name = "EISDIR", .text = "illegal operation on a directory" },
        .NOTDIR => .{ .name = "ENOTDIR", .text = "not a directory" },
        .MFILE, .NFILE => .{ .name = "EMFILE", .text = "too many open files" },
        .NOMEM => .{ .name = "ENOMEM", .text = "not enough memory" },
        else => .{ .name = "EIO", .text = "I/O error" },
    };
}

pub const IoResult = union(enum) {
    /// The count of bytes. A read of 0 bytes is the end of the data.
    n: usize,
    /// The descriptor is not blocking and has no data or no room.
    again,
    err: Fail,
};

pub fn read(fd: Fd, buf: []u8) IoResult {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return .{ .n = rc },
            .INTR => continue,
            .AGAIN => return .again,
            // The end of a closed connection reads as the end of data.
            .CONNRESET => return .{ .err = failOf(.CONNRESET) },
            else => |e| return .{ .err = failOf(e) },
        }
    }
}

pub fn write(fd: Fd, buf: []const u8) IoResult {
    while (true) {
        // MSG_NOSIGNAL is not possible on a pipe, so SIGPIPE is ignored
        // by `ignorePipeSignal` at the start of a runner.
        const rc = linux.write(fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return .{ .n = rc },
            .INTR => continue,
            .AGAIN => return .again,
            else => |e| return .{ .err = failOf(e) },
        }
    }
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

pub fn setBlocking(fd: Fd, on: bool) void {
    const fl = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(fl) != .SUCCESS) return;
    const bit: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    _ = linux.fcntl(fd, linux.F.SETFL, if (on) fl & ~bit else fl | bit);
}

/// A write to a closed pipe or socket gives an error and no signal.
pub fn ignorePipeSignal() void {
    var act: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = std.mem.zeroes(linux.sigset_t), .flags = 0 };
    _ = linux.sigaction(linux.SIG.PIPE, &act, null);
}

pub const Want = struct {
    fd: Fd,
    read: bool = false,
    write: bool = false,
    /// The answers of `poll`.
    can_read: bool = false,
    can_write: bool = false,
};

/// Waits until a descriptor is ready or the time ends. A negative time
/// has no end. An error or a closed peer counts as ready, so the
/// next read or write reports it.
pub fn poll(a: std.mem.Allocator, wants: []Want, timeout_ms: i32) void {
    const fds = a.alloc(linux.pollfd, wants.len) catch return;
    defer a.free(fds);
    for (wants, fds) |w, *p| {
        var ev: i16 = 0;
        if (w.read) ev |= linux.POLL.IN;
        if (w.write) ev |= linux.POLL.OUT;
        p.* = .{ .fd = w.fd, .events = ev, .revents = 0 };
    }
    const rc = linux.poll(fds.ptr, fds.len, timeout_ms);
    if (linux.errno(rc) != .SUCCESS) return;
    for (wants, fds) |*w, p| {
        const bad = p.revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0;
        w.can_read = w.read and (p.revents & linux.POLL.IN != 0 or bad);
        w.can_write = w.write and (p.revents & linux.POLL.OUT != 0 or bad);
    }
}

// ---- Loopback sockets ----

/// A loopback address: 127.0.0.1 or ::1.
pub const Loop = enum { v4, v6 };

pub const Name = struct { v6: bool, bytes: [16]u8, port: u16 };

const Addr = extern union { any: linux.sockaddr, in: linux.sockaddr.in, in6: linux.sockaddr.in6 };

fn loopAddr(kind: Loop, port: u16) struct { Addr, linux.socklen_t } {
    var a: Addr = undefined;
    switch (kind) {
        .v4 => {
            a.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
            return .{ a, @sizeOf(linux.sockaddr.in) };
        },
        .v6 => {
            a.in6 = .{ .port = std.mem.nativeToBig(u16, port), .flowinfo = 0, .addr = [_]u8{0} ** 15 ++ [_]u8{1}, .scope_id = 0 };
            return .{ a, @sizeOf(linux.sockaddr.in6) };
        },
    }
}

fn nameOf(a: *const Addr) Name {
    var n: Name = .{ .v6 = false, .bytes = @splat(0), .port = 0 };
    if (a.any.family == linux.AF.INET6) {
        n.v6 = true;
        n.bytes = a.in6.addr;
        n.port = std.mem.bigToNative(u16, a.in6.port);
    } else {
        @memcpy(n.bytes[0..4], std.mem.asBytes(&a.in.addr));
        n.port = std.mem.bigToNative(u16, a.in.port);
    }
    return n;
}

pub const SockResult = union(enum) { fd: Fd, err: Fail };

fn newSocket(kind: Loop) SockResult {
    const family: u32 = if (kind == .v4) linux.AF.INET else linux.AF.INET6;
    const rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return .{ .err = failOf(linux.errno(rc)) };
    return .{ .fd = @intCast(rc) };
}

/// A listening socket on a loopback address. Port 0 selects a free port.
pub fn listenLoop(kind: Loop, port: u16, reuse: bool) SockResult {
    const fd = switch (newSocket(kind)) {
        .fd => |x| x,
        .err => |e| return .{ .err = e },
    };
    if (reuse) {
        const one: u32 = 1;
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
    }
    const addr, const len = loopAddr(kind, port);
    var rc = linux.bind(fd, &addr.any, len);
    if (linux.errno(rc) == .SUCCESS) rc = linux.listen(fd, 128);
    if (linux.errno(rc) != .SUCCESS) {
        close(fd);
        return .{ .err = failOf(linux.errno(rc)) };
    }
    return .{ .fd = fd };
}

/// A connection to a loopback address. `my_port` binds the local port
/// when it is not 0. With `wait` false the connect continues in the
/// background, and `connectError` gives its end.
pub fn connectLoop(kind: Loop, port: u16, my_port: u16, wait: bool) SockResult {
    const fd = switch (newSocket(kind)) {
        .fd => |x| x,
        .err => |e| return .{ .err = e },
    };
    if (my_port != 0) {
        const one: u32 = 1;
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
        const mine, const mlen = loopAddr(kind, my_port);
        const rc = linux.bind(fd, &mine.any, mlen);
        if (linux.errno(rc) != .SUCCESS) {
            close(fd);
            return .{ .err = failOf(linux.errno(rc)) };
        }
    }
    if (!wait) setBlocking(fd, false);
    const addr, const len = loopAddr(kind, port);
    while (true) {
        const rc = linux.connect(fd, &addr.any, len);
        switch (linux.errno(rc)) {
            .SUCCESS, .INPROGRESS => return .{ .fd = fd },
            .INTR => continue,
            else => |e| {
                close(fd);
                return .{ .err = failOf(e) };
            },
        }
    }
}

/// The pending error of a socket, or null. The call clears the error.
pub fn connectError(fd: Fd) ?Fail {
    var code: u32 = 0;
    var len: linux.socklen_t = 4;
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, std.mem.asBytes(&code), &len);
    if (linux.errno(rc) != .SUCCESS or code == 0) return null;
    return failOf(@enumFromInt(code));
}

pub const Accepted = struct { fd: Fd, peer: Name };

/// The next connection of a listening socket, or null when none waits.
pub fn accept(fd: Fd) ?Accepted {
    var a: Addr = undefined;
    var len: linux.socklen_t = @sizeOf(Addr);
    while (true) {
        const rc = linux.accept4(fd, &a.any, &len, linux.SOCK.CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => return .{ .fd = @intCast(rc), .peer = nameOf(&a) },
            .INTR => continue,
            else => return null,
        }
    }
}

pub fn sockName(fd: Fd) ?Name {
    var a: Addr = undefined;
    var len: linux.socklen_t = @sizeOf(Addr);
    if (linux.errno(linux.getsockname(fd, &a.any, &len)) != .SUCCESS) return null;
    return nameOf(&a);
}

pub fn peerName(fd: Fd) ?Name {
    var a: Addr = undefined;
    var len: linux.socklen_t = @sizeOf(Addr);
    if (linux.errno(linux.getpeername(fd, &a.any, &len)) != .SUCCESS) return null;
    return nameOf(&a);
}

/// Ends one direction of a socket: 0 for reads, 1 for writes.
pub fn shutdown(fd: Fd, how: i32) void {
    _ = linux.shutdown(fd, how);
}

/// Moves the position of a file: `whence` is 0 for the start, 1 for
/// the current position, and 2 for the end. Gives the new position.
pub fn seek(fd: Fd, off: i64, whence: u8) union(enum) { at: i64, err: linux.E } {
    const rc = linux.lseek(fd, off, whence);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return .{ .err = e };
    return .{ .at = @intCast(rc) };
}

//! The system calls of `aio` and its tests, for Linux (raw system
//! calls, no libc) and for macOS and the BSDs (libc). Each function
//! gives the value of the call, or a negative errno.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const c = std.c;
const posix = std.posix;

pub const is_linux = builtin.os.tag == .linux;
pub const fd_t = posix.fd_t;
pub const sockaddr = posix.sockaddr;
pub const socklen_t = posix.socklen_t;
pub const E = posix.E;

/// The negative errno of `e`.
pub fn neg(e: E) i32 {
    return -@as(i32, @intCast(@backingInt(e)));
}

/// The result of a raw Linux system call.
fn lin(rc: usize) i32 {
    const e = linux.errno(rc);
    if (e != .SUCCESS) return neg(e);
    return @intCast(@as(isize, @bitCast(rc)));
}

/// The result of a libc call: -1 and errno, or the value.
fn lib(rc: anytype) i32 {
    if (rc == -1) return -@as(i32, @intCast(c._errno().*));
    return @intCast(rc);
}

fn o_nonblock() c_int {
    return @intCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
}

/// Sets O_NONBLOCK and FD_CLOEXEC on a new descriptor of libc.
fn prep(fd: i32) i32 {
    if (fd < 0) return fd;
    const fl = c.fcntl(fd, c.F.GETFL);
    if (fl == -1 or c.fcntl(fd, c.F.SETFL, fl | o_nonblock()) == -1 or c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) == -1) {
        const e = lib(@as(c_int, -1));
        _ = c.close(fd);
        return e;
    }
    return fd;
}

/// A non-blocking TCP socket with close-on-exec. On macOS it also has
/// SO_NOSIGPIPE, so a write to a closed peer gives EPIPE and no signal.
pub fn tcpSocket(family: u32) i32 {
    if (is_linux) return lin(linux.socket(family, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0));
    const fd = prep(lib(c.socket(family, c.SOCK.STREAM, 0)));
    if (fd >= 0) noSigpipe(fd);
    return fd;
}

fn noSigpipe(fd: i32) void {
    if (comptime builtin.os.tag.isDarwin()) {
        const one: c_int = 1;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, std.mem.asBytes(&one), @sizeOf(c_int));
    }
}

pub fn bind(fd: fd_t, addr: *const sockaddr, len: socklen_t) i32 {
    return if (is_linux) lin(linux.bind(fd, addr, len)) else lib(c.bind(fd, addr, len));
}

pub fn listen(fd: fd_t, backlog: u31) i32 {
    return if (is_linux) lin(linux.listen(fd, backlog)) else lib(c.listen(fd, backlog));
}

pub fn getsockname(fd: fd_t, addr: *sockaddr, len: *socklen_t) i32 {
    return if (is_linux) lin(linux.getsockname(fd, addr, len)) else lib(c.getsockname(fd, addr, len));
}

/// A new connection, non-blocking and close-on-exec.
pub fn accept(fd: fd_t) i32 {
    if (is_linux) return lin(linux.accept4(fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC));
    const s = prep(lib(c.accept(fd, null, null)));
    if (s >= 0) noSigpipe(s);
    return s;
}

pub fn connect(fd: fd_t, addr: *const sockaddr, len: socklen_t) i32 {
    return if (is_linux) lin(linux.connect(fd, addr, len)) else lib(c.connect(fd, addr, len));
}

pub fn read(fd: fd_t, buf: []u8) i32 {
    return if (is_linux) lin(linux.read(fd, buf.ptr, buf.len)) else lib(c.read(fd, buf.ptr, buf.len));
}

pub fn write(fd: fd_t, buf: []const u8) i32 {
    return if (is_linux) lin(linux.write(fd, buf.ptr, buf.len)) else lib(c.write(fd, buf.ptr, buf.len));
}

pub fn writev(fd: fd_t, iov: []const std.posix.iovec_const) i32 {
    return if (is_linux) lin(linux.writev(fd, iov.ptr, iov.len)) else lib(c.writev(fd, iov.ptr, @intCast(iov.len)));
}

pub fn close(fd: fd_t) void {
    if (is_linux) _ = linux.close(fd) else _ = c.close(fd);
}

pub fn shutdownWrite(fd: fd_t) void {
    if (is_linux) _ = linux.shutdown(fd, linux.SHUT.WR) else _ = c.shutdown(fd, c.SHUT.WR);
}

/// SO_ERROR of a socket, as a negative errno or 0.
pub fn sockError(fd: fd_t) i32 {
    var err: i32 = 0;
    var len: socklen_t = @sizeOf(i32);
    if (is_linux) {
        _ = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&err), &len);
    } else {
        _ = c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, @ptrCast(&err), &len);
    }
    return -err;
}

/// A non-blocking pipe with close-on-exec.
pub fn pipe(fds: *[2]fd_t) i32 {
    if (is_linux) return lin(linux.pipe2(fds, .{ .NONBLOCK = true, .CLOEXEC = true }));
    const rc = lib(c.pipe(fds));
    if (rc < 0) return rc;
    for (fds) |fd| {
        const r = prep(fd);
        if (r < 0) return r;
    }
    return 0;
}

pub fn sleepNs(ns: u64) void {
    var ts: posix.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    if (is_linux) _ = linux.nanosleep(&ts, null) else _ = c.nanosleep(&ts, null);
}

/// The monotonic clock in nanoseconds.
pub fn now() u64 {
    var ts: posix.timespec = undefined;
    if (is_linux) _ = linux.clock_gettime(.MONOTONIC, &ts) else _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

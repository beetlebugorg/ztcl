//! The WASI preview 1 form of the platform interface of `sys.zig`.
//!
//! Each function is one call of `wasi_snapshot_preview1` through
//! `std.os.wasi`. A descriptor is a WASI descriptor. `poll` makes one
//! subscription for each read or write that a caller wants, and one
//! clock subscription for the time limit, then calls `poll_oneoff` once.
//! Preview 1 has no socket that a program can open, so each socket
//! function gives ENOTSUP or no answer.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const wasi = std.os.wasi;
const sys = @import("sys.zig");

pub const E = wasi.errno_t;

pub fn read(fd: i32, buf: []u8) sys.IoResult {
    while (true) {
        var n: usize = 0;
        const iov = [1]wasi.iovec_t{.{ .base = buf.ptr, .len = buf.len }};
        switch (wasi.fd_read(fd, &iov, 1, &n)) {
            .SUCCESS => return .{ .n = n },
            .INTR => continue,
            .AGAIN => return .again,
            else => |e| return .{ .err = sys.failOf(e) },
        }
    }
}

pub fn readFile(fd: i32, buf: []u8) sys.FileRead {
    while (true) {
        var n: usize = 0;
        const iov = [1]wasi.iovec_t{.{ .base = buf.ptr, .len = buf.len }};
        switch (wasi.fd_read(fd, &iov, 1, &n)) {
            .SUCCESS => return .{ .n = n },
            .INTR => continue,
            else => |e| return .{ .err = e },
        }
    }
}

pub fn writeFile(fd: i32, buf: []const u8) sys.FileRead {
    while (true) {
        var n: usize = 0;
        const iov = [1]wasi.ciovec_t{.{ .base = buf.ptr, .len = buf.len }};
        switch (wasi.fd_write(fd, &iov, 1, &n)) {
            .SUCCESS => return .{ .n = n },
            .INTR => continue,
            else => |e| return .{ .err = e },
        }
    }
}

pub fn write(fd: i32, buf: []const u8) sys.IoResult {
    while (true) {
        var n: usize = 0;
        const iov = [1]wasi.ciovec_t{.{ .base = buf.ptr, .len = buf.len }};
        switch (wasi.fd_write(fd, &iov, 1, &n)) {
            .SUCCESS => return .{ .n = n },
            .INTR => continue,
            .AGAIN => return .again,
            else => |e| return .{ .err = sys.failOf(e) },
        }
    }
}

pub fn close(fd: i32) void {
    _ = wasi.fd_close(fd);
}

pub fn setBlocking(fd: i32, on: bool) void {
    var st: wasi.fdstat_t = undefined;
    if (wasi.fd_fdstat_get(fd, &st) != .SUCCESS) return;
    var flags = st.fs_flags;
    flags.NONBLOCK = !on;
    _ = wasi.fd_fdstat_set_flags(fd, flags);
}

pub fn poll(a: std.mem.Allocator, wants: []sys.Want, timeout_ms: i32) void {
    var count: usize = 0;
    for (wants) |w| count += @intFromBool(w.read) + @intFromBool(w.write);
    if (timeout_ms >= 0) count += 1;
    if (count == 0) return;
    const subs = a.alloc(wasi.subscription_t, count) catch return;
    defer a.free(subs);
    const events = a.alloc(wasi.event_t, count) catch return;
    defer a.free(events);
    // The userdata of a subscription is the index of its want, times 2,
    // plus 1 for a write.
    var k: usize = 0;
    for (wants, 0..) |w, i| {
        if (w.read) {
            subs[k] = .{ .userdata = 2 * i, .u = .{ .tag = .FD_READ, .u = .{ .fd_read = .{ .fd = w.fd } } } };
            k += 1;
        }
        if (w.write) {
            subs[k] = .{ .userdata = 2 * i + 1, .u = .{ .tag = .FD_WRITE, .u = .{ .fd_write = .{ .fd = w.fd } } } };
            k += 1;
        }
    }
    if (timeout_ms >= 0) {
        subs[k] = .{ .userdata = std.math.maxInt(u64), .u = .{ .tag = .CLOCK, .u = .{ .clock = .{
            .id = .MONOTONIC,
            .timeout = @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms,
            .precision = 0,
            .flags = 0,
        } } } };
        k += 1;
    }
    var n: usize = 0;
    if (wasi.poll_oneoff(&subs[0], &events[0], k, &n) != .SUCCESS) return;
    for (events[0..n]) |ev| {
        if (ev.type == .CLOCK) continue;
        const i: usize = @intCast(ev.userdata / 2);
        if (i >= wants.len) continue;
        // An error or a hangup counts as ready, so the next read or
        // write reports it.
        if (ev.userdata % 2 == 0) wants[i].can_read = true else wants[i].can_write = true;
    }
}

pub fn seek(fd: i32, off: i64, whence: u8) sys.SeekResult {
    var at: wasi.filesize_t = 0;
    const w: wasi.whence_t = switch (whence) {
        0 => .SET,
        1 => .CUR,
        else => .END,
    };
    const e = wasi.fd_seek(fd, off, w, &at);
    if (e != .SUCCESS) return .{ .err = e };
    return .{ .at = @intCast(at) };
}

const notsup: sys.Fail = .{ .name = "ENOTSUP", .text = "operation not supported" };

pub fn listenAt(_: sys.Addr, _: bool) sys.SockResult {
    return .{ .err = notsup };
}

pub fn connectTo(_: sys.Addr, _: ?sys.Addr, _: bool) sys.SockResult {
    return .{ .err = notsup };
}

/// Preview 1 has no name lookup, so the list stays empty.
pub fn resolve(_: std.mem.Allocator, _: []const u8, _: *std.ArrayList(sys.Addr)) std.mem.Allocator.Error!void {}

pub fn connectError(_: i32) ?sys.Fail {
    return notsup;
}

pub fn accept(_: i32) ?sys.Accepted {
    return null;
}

pub fn sockName(_: i32) ?sys.Addr {
    return null;
}

pub fn peerName(_: i32) ?sys.Addr {
    return null;
}

pub fn shutdown(_: i32, _: i32) void {}

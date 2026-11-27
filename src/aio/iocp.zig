//! The IOCP backend of `aio` (task 10, Windows): each operation starts
//! as an overlapped Winsock call, and its end comes back from the
//! completion port of the loop.
//!
//! - accept: AcceptEx with a new socket of the family of the listener,
//!   then SO_UPDATE_ACCEPT_CONTEXT. The result is the new socket.
//! - connect: ConnectEx on a socket that is bound first (to the address
//!   with no host and port 0 of its family), then
//!   SO_UPDATE_CONNECT_CONTEXT.
//! - read, write, writev: WSARecv and WSASend. Winsock copies the WSABUF
//!   array at the call, so the array is on the stack. A writev sends at
//!   most `max_bufs` buffers in one operation.
//! - timer: a list sorted by deadline. The wait of
//!   GetQueuedCompletionStatusEx ends at the first deadline.
//!
//! Each OVERLAPPED is a field of its `Completion`, so an entry of the
//! port gives the completion with no table. WSAGetOverlappedResult gives
//! the byte count or the WSA error of the operation, and `win.errno`
//! maps the error to `std.posix.E`.
//!
//! A socket joins the port at its first operation. Windows refuses a
//! second join of a socket with ERROR_INVALID_PARAMETER, so `submit`
//! joins each time and skips that error: a table of joined sockets goes
//! wrong when Windows gives the value of a closed socket to a new one.
//!
//! A call that fails at once ends in the ready list, and its callback
//! runs in the next `run`, as on the other backends. `cancel` calls
//! CancelIoEx; the operation then ends with ERROR_OPERATION_ABORTED,
//! which is -ECANCELED. `wake` posts an entry with the key `wake_key`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const aio = @import("aio.zig");
const sys = @import("sys.zig");
const win = sys.win;
const posix = std.posix;
const Completion = aio.Completion;

const max_events = 128;
pub const max_bufs = 16;
const wake_key: usize = 1;
/// The size of an address of AcceptEx: the largest sockaddr and 16.
pub const addr_len = @sizeOf(posix.sockaddr.in6) + 16;

/// The fields of a completion on Windows.
pub const Extra = struct {
    ov: win.OVERLAPPED = .{},
    accepted: win.SOCKET = win.invalid_socket,
    addrs: [2 * addr_len]u8 = undefined,
};

pub const Port = struct {
    port: win.HANDLE,
    accept_ex: win.AcceptEx,
    connect_ex: win.ConnectEx,
    ready: ?*Completion = null,
    ready_tail: ?*Completion = null,
    timers: ?*Completion = null,

    pub fn init(_: std.mem.Allocator) !Port {
        win.startup();
        const port = win.CreateIoCompletionPort(@ptrFromInt(win.invalid_socket), null, 0, 1) orelse return error.SystemResources;
        errdefer _ = win.CloseHandle(port);
        // The pointers of AcceptEx and ConnectEx, from any TCP socket.
        const s = sys.tcpSocket(posix.AF.INET);
        if (s < 0) return error.SystemResources;
        defer sys.close(s);
        return .{
            .port = port,
            .accept_ex = @ptrCast(try extension(s, &win.wsaid_acceptex)),
            .connect_ex = @ptrCast(try extension(s, &win.wsaid_connectex)),
        };
    }

    fn extension(s: i32, guid: *const win.GUID) !*const anyopaque {
        var f: ?*const anyopaque = null;
        var got: win.DWORD = 0;
        if (win.WSAIoctl(win.sock(s), win.SIO_GET_EXTENSION_FUNCTION_POINTER, guid, @sizeOf(win.GUID), @ptrCast(&f), @sizeOf(usize), &got, null, null) != 0) return error.SystemResources;
        return f orelse error.SystemResources;
    }

    pub fn deinit(p: *Port) void {
        _ = win.CloseHandle(p.port);
    }

    pub fn wake(p: *Port) void {
        _ = win.PostQueuedCompletionStatus(p.port, 0, wake_key, null);
    }

    fn pushReady(p: *Port, c: *Completion, res: i32) void {
        c.result = res;
        c.next = null;
        if (p.ready_tail) |t| t.next = c else p.ready = c;
        p.ready_tail = c;
    }

    fn fdOf(c: *const Completion) i32 {
        return switch (c.op) {
            inline .accept, .read, .write, .writev, .connect => |o| o.fd,
            .timer => unreachable,
        };
    }

    pub fn submit(p: *Port, c: *Completion) !void {
        if (c.op == .timer) {
            c.deadline = aio.now() + c.op.timer.ns;
            var at = &p.timers;
            while (at.*) |t| : (at = &t.next) {
                if (t.deadline > c.deadline) break;
            }
            c.next = at.*;
            at.* = c;
            return;
        }
        const fd = fdOf(c);
        // A second join fails with ERROR_INVALID_PARAMETER: see the top.
        _ = win.CreateIoCompletionPort(win.handle(fd), p.port, 0, 0);
        c.win = .{};
        const ov = &c.win.ov;
        const s = win.sock(fd);
        const ok: bool = switch (c.op) {
            .accept => blk: {
                var addr: posix.sockaddr.in6 = undefined;
                var len: posix.socklen_t = @sizeOf(posix.sockaddr.in6);
                const r = sys.getsockname(fd, @ptrCast(&addr), &len);
                if (r < 0) return p.pushReady(c, r);
                const a = sys.tcpSocket(addr.family);
                if (a < 0) return p.pushReady(c, a);
                c.win.accepted = win.sock(a);
                var got: win.DWORD = 0;
                break :blk p.accept_ex(s, c.win.accepted, &c.win.addrs, 0, addr_len, addr_len, &got, ov) != 0;
            },
            .connect => |o| blk: {
                // ConnectEx needs a bound socket.
                var any = std.mem.zeroes(posix.sockaddr.in6);
                any.family = o.addr.family;
                const any_len: posix.socklen_t = if (o.addr.family == posix.AF.INET6) @sizeOf(posix.sockaddr.in6) else @sizeOf(posix.sockaddr.in);
                const r = sys.bind(fd, @ptrCast(&any), any_len);
                if (r < 0 and r != sys.neg(.INVAL)) return p.pushReady(c, r);
                break :blk p.connect_ex(s, o.addr, @intCast(o.len), null, 0, null, ov) != 0;
            },
            .read => |o| blk: {
                const b = [1]win.WSABUF{.{ .len = @intCast(@min(o.buf.len, std.math.maxInt(u32))), .buf = o.buf.ptr }};
                var flags: win.DWORD = 0;
                break :blk win.WSARecv(s, &b, 1, null, &flags, ov, null) == 0;
            },
            .write => |o| blk: {
                const b = [1]win.WSABUF{.{ .len = @intCast(@min(o.buf.len, std.math.maxInt(u32))), .buf = o.buf.ptr }};
                break :blk win.WSASend(s, &b, 1, null, 0, ov, null) == 0;
            },
            .writev => |o| blk: {
                var b: [max_bufs]win.WSABUF = undefined;
                const n = @min(o.iov.len, max_bufs);
                for (o.iov[0..n], b[0..n]) |v, *w| w.* = .{ .len = @intCast(@min(v.len, std.math.maxInt(u32))), .buf = v.base };
                break :blk win.WSASend(s, &b, @intCast(n), null, 0, ov, null) == 0;
            },
            .timer => unreachable,
        };
        if (ok) return; // The port gives the end too.
        const code = win.WSAGetLastError();
        if (code == win.WSA_IO_PENDING) return;
        p.cleanupAccept(c);
        p.pushReady(c, win.errno(code));
    }

    fn cleanupAccept(_: *Port, c: *Completion) void {
        if (c.op == .accept and c.win.accepted != win.invalid_socket) {
            sys.close(@intCast(c.win.accepted));
            c.win.accepted = win.invalid_socket;
        }
    }

    pub fn cancel(p: *Port, c: *Completion) !void {
        if (c.op == .timer) {
            var at = &p.timers;
            while (at.*) |t| : (at = &t.next) {
                if (t == c) {
                    at.* = c.next;
                    p.pushReady(c, sys.neg(.CANCELED));
                    return;
                }
            }
            return;
        }
        // An operation in the ready list has its result already; for one
        // in the kernel, the port gives the end.
        _ = win.CancelIoEx(win.handle(fdOf(c)), &c.win.ov);
    }

    /// The result of an operation that the port gave.
    fn ended(p: *Port, c: *Completion) i32 {
        const fd = fdOf(c);
        var bytes: win.DWORD = 0;
        var flags: win.DWORD = 0;
        if (win.WSAGetOverlappedResult(win.sock(fd), &c.win.ov, &bytes, 0, &flags) == 0) {
            const e = win.wsaError();
            p.cleanupAccept(c);
            return e;
        }
        switch (c.op) {
            .accept => {
                const a = c.win.accepted;
                c.win.accepted = win.invalid_socket;
                const lsock = win.sock(fd);
                if (win.setsockopt(a, win.SOL_SOCKET, win.SO_UPDATE_ACCEPT_CONTEXT, @ptrCast(&lsock), @sizeOf(win.SOCKET)) != 0) {
                    const e = win.wsaError();
                    sys.close(@intCast(a));
                    return e;
                }
                return @intCast(a);
            },
            .connect => {
                if (win.setsockopt(win.sock(fd), win.SOL_SOCKET, win.SO_UPDATE_CONNECT_CONTEXT, null, 0) != 0) return win.wsaError();
                return 0;
            },
            else => return @intCast(bytes),
        }
    }

    pub fn run(p: *Port, l: *aio.Loop, timeout_ns: ?u64) !usize {
        var wait: ?u64 = timeout_ns;
        if (p.timers) |t| {
            const n = aio.now();
            const left = if (t.deadline > n) t.deadline - n else 0;
            if (wait == null or left < wait.?) wait = left;
        }
        if (p.ready != null) wait = 0;
        // Round up to whole milliseconds, so a timer does not end early.
        const ms: win.DWORD = if (wait) |w| @intCast(@min((w + std.time.ns_per_ms - 1) / std.time.ns_per_ms, win.INFINITE - 1)) else win.INFINITE;
        var entries: [max_events]win.OVERLAPPED_ENTRY = undefined;
        var n: u32 = 0;
        if (win.GetQueuedCompletionStatusEx(p.port, &entries, max_events, &n, ms, 0) == 0) {
            if (win.GetLastError() != win.WAIT_TIMEOUT) return error.SystemResources;
            n = 0;
        }
        for (entries[0..n]) |e| {
            if (e.key == wake_key) continue;
            const ov = e.ov orelse continue;
            const extra: *Extra = @fieldParentPtr("ov", ov);
            const c: *Completion = @fieldParentPtr("win", extra);
            p.pushReady(c, p.ended(c));
        }
        const t_now = aio.now();
        while (p.timers) |t| {
            if (t.deadline > t_now) break;
            p.timers = t.next;
            p.pushReady(t, 0);
        }
        var c = p.ready;
        p.ready = null;
        p.ready_tail = null;
        var count: usize = 0;
        while (c) |x| {
            c = x.next;
            l.finish(x, x.result);
            count += 1;
        }
        return count;
    }
};

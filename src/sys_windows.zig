//! The Windows form of `sys.zig`: Winsock sockets, file handles, and
//! the wait of the event loop.
//!
//! An `Fd` is an integer with a tag. The values 0, 1, and 2 name the
//! standard handles. A file handle is its own value. A socket is its
//! handle plus `sock_tag`. Windows keeps the significant bits of a
//! kernel handle in the low 32 bits, so the value fits in an `i32`. A
//! handle at or above the tag is closed and reported as an error.
//!
//! `WSAPoll` accepts only sockets, so `poll` checks each other handle by
//! its type. A disk file is always ready. A pipe is ready when
//! `PeekNamedPipe` finds data or an end. While a pipe or a console
//! waits, the wait runs in slices of 10 ms.
//!
//! A socket has no handle inheritance, and an IPv6 socket has
//! IPV6_V6ONLY, so an IPv4 peer cannot appear as an IPv6 address. A
//! listener has SO_EXCLUSIVEADDRUSE, because SO_REUSEADDR on Windows
//! lets another socket bind the same port.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const sys = @import("sys.zig");
const Fd = sys.Fd;
const Addr = sys.Addr;
const Fail = sys.Fail;
const IoResult = sys.IoResult;

const HANDLE = ?*anyopaque;
const BOOL = i32;
const DWORD = u32;
const SOCKET = usize;

const invalid_socket: SOCKET = ~@as(usize, 0);
const invalid_handle: HANDLE = @ptrFromInt(~@as(usize, 0));
const generic_read: DWORD = 0x8000_0000;
const file_share_read_write: DWORD = 3;
const open_existing: DWORD = 3;
const socket_error: i32 = -1;

/// The tag of a socket in an `Fd`.
const sock_tag: Fd = 0x4000_0000;

const af_inet: i32 = 2;
const af_inet6: i32 = 23;
const sock_stream: i32 = 1;
const ipproto_tcp: i32 = 6;
const ipproto_ipv6: i32 = 41;
const ipv6_v6only: i32 = 27;
const sol_socket: i32 = 0xffff;
const so_error: i32 = 0x1007;
const so_exclusiveaddruse: i32 = ~@as(i32, 4);
const fionbio: u32 = 0x8004_667e;
const wsa_flag_no_handle_inherit: u32 = 0x80;
const handle_flag_inherit: DWORD = 1;
const pipe_nowait: DWORD = 1;
const pipe_wait: DWORD = 0;

const pollrdnorm: i16 = 0x0100;
const pollwrnorm: i16 = 0x0010;
const pollerr: i16 = 0x0001;
const pollhup: i16 = 0x0002;
const pollnval: i16 = 0x0004;

const file_type_disk: DWORD = 1;
const file_type_char: DWORD = 2;
const file_type_pipe: DWORD = 3;

const error_access_denied: u32 = 5;
const error_invalid_function: u32 = 1;
const error_handle_eof: u32 = 38;
const error_broken_pipe: u32 = 109;
const error_no_data: u32 = 232;
const wsaeintr: u32 = 10004;
const wsaewouldblock: u32 = 10035;
const wsaenotconn: u32 = 10057;
const wsaeshutdown: u32 = 10058;

/// The slice of a wait while a pipe or a console has no data.
const slice_ms: i32 = 10;

const PollFd = extern struct { fd: SOCKET, events: i16, revents: i16 };
const SockIn = extern struct { family: u16, port: u16, addr: [4]u8, zero: [8]u8 };
const SockIn6 = extern struct { family: u16, port: u16, flowinfo: u32, addr: [16]u8, scope_id: u32 };
const Sock = extern union { family: u16, in: SockIn, in6: SockIn6 };

extern "kernel32" fn GetStdHandle(n: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: DWORD, got: *DWORD, over: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: DWORD, put: *DWORD, over: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn SetFilePointerEx(h: HANDLE, dist: i64, at: *i64, method: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileType(h: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn GetSystemDirectoryW(buf: [*]u16, size: u32) callconv(.winapi) u32;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, security: ?*anyopaque, disposition: DWORD, flags: DWORD, template: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn PeekNamedPipe(h: HANDLE, buf: ?*anyopaque, size: DWORD, got: ?*DWORD, avail: ?*DWORD, left: ?*DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetNamedPipeHandleState(h: HANDLE, mode: ?*DWORD, count: ?*DWORD, time: ?*DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetHandleInformation(h: HANDLE, mask: DWORD, flags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetHandleInformation(h: HANDLE, flags: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;

extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) i32;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
extern "ws2_32" fn WSASocketW(af: i32, kind: i32, protocol: i32, info: ?*anyopaque, group: u32, flags: u32) callconv(.winapi) SOCKET;
extern "ws2_32" fn WSAPoll(fds: [*]PollFd, n: u32, timeout: i32) callconv(.winapi) i32;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn bind(s: SOCKET, name: *const Sock, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
extern "ws2_32" fn accept(s: SOCKET, name: *Sock, len: *i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn connect(s: SOCKET, name: *const Sock, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn shutdown(s: SOCKET, how: i32) callconv(.winapi) i32;
extern "ws2_32" fn getsockname(s: SOCKET, name: *Sock, len: *i32) callconv(.winapi) i32;
extern "ws2_32" fn getpeername(s: SOCKET, name: *Sock, len: *i32) callconv(.winapi) i32;
extern "ws2_32" fn getsockopt(s: SOCKET, level: i32, name: i32, value: [*]u8, len: *i32) callconv(.winapi) i32;
extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, name: i32, value: [*]const u8, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: i32, arg: *u32) callconv(.winapi) i32;

var started = std.atomic.Value(bool).init(false);

/// WSAStartup counts its calls, so a race of two threads is harmless.
fn startup() void {
    if (started.load(.acquire)) return;
    var data: [512]u8 align(8) = undefined;
    if (WSAStartup(0x0202, &data) == 0) started.store(true, .release);
}

fn isSocket(fd: Fd) bool {
    return fd >= sock_tag;
}

fn socketOf(fd: Fd) SOCKET {
    return @intCast(fd - sock_tag);
}

fn handleOf(fd: Fd) HANDLE {
    if (fd >= 0 and fd <= 2) return GetStdHandle(@bitCast(-10 - fd));
    return @ptrFromInt(@as(usize, @intCast(fd)));
}

/// The system handle of a descriptor, for a child process.
pub fn rawHandle(fd: Fd) HANDLE {
    if (isSocket(fd)) return @ptrFromInt(socketOf(fd));
    return handleOf(fd);
}

/// The `Fd` of a file handle, or null for one outside the range.
pub fn fdOfHandle(h: HANDLE) ?Fd {
    const v = @intFromPtr(h);
    if (v <= 2 or v >= @as(usize, @intCast(sock_tag))) return null;
    return @intCast(v);
}

fn wsaError() u32 {
    return @intCast(WSAGetLastError());
}

fn fdOfSocket(s: SOCKET) ?Fd {
    if (s >= @as(usize, @intCast(sock_tag))) return null;
    return @as(Fd, @intCast(s)) + sock_tag;
}

/// A host error. The names are the POSIX names that `fsroot.posixError`
/// reads, and the values are Win32 codes. Another code stays as it is.
pub const E = enum(u32) {
    NOENT = 2,
    ACCES = 5,
    XDEV = 17,
    EXIST = 80,
    INVAL = 87,
    NOSYS = 120,
    NOTEMPTY = 145,
    NAMETOOLONG = 206,
    NOTDIR = 267,
    ISDIR = 336,
    PERM = 1314,
    LOOP = 1921,
    _,
};

pub fn failOf(e: E) Fail {
    return failCode(@intFromEnum(e));
}

fn failCode(e: u32) Fail {
    return switch (e) {
        2, 3 => .{ .name = "ENOENT", .text = "no such file or directory" },
        5, 10013 => .{ .name = "EACCES", .text = "permission denied" },
        10061 => .{ .name = "ECONNREFUSED", .text = "connection refused" },
        10048 => .{ .name = "EADDRINUSE", .text = "address already in use" },
        10049 => .{ .name = "EADDRNOTAVAIL", .text = "can't assign requested address" },
        10053, 10054 => .{ .name = "ECONNRESET", .text = "connection reset by peer" },
        109, 232, 10058 => .{ .name = "EPIPE", .text = "broken pipe" },
        10057 => .{ .name = "ENOTCONN", .text = "socket is not connected" },
        10060 => .{ .name = "ETIMEDOUT", .text = "connection timed out" },
        10035 => .{ .name = "EAGAIN", .text = "resource temporarily unavailable" },
        87, 10022 => .{ .name = "EINVAL", .text = "invalid argument" },
        193 => .{ .name = "ENOEXEC", .text = "exec format error" },
        206 => .{ .name = "E2BIG", .text = "argument list too long" },
        6, 10009, 10038 => .{ .name = "EBADF", .text = "bad file number" },
        267 => .{ .name = "ENOTDIR", .text = "not a directory" },
        336 => .{ .name = "EISDIR", .text = "illegal operation on a directory" },
        4, 10024 => .{ .name = "EMFILE", .text = "too many open files" },
        8, 14, 10055 => .{ .name = "ENOMEM", .text = "not enough memory" },
        else => .{ .name = "EIO", .text = "I/O error" },
    };
}

fn clampLen(n: usize) i32 {
    return @intCast(@min(n, std.math.maxInt(i32)));
}

pub fn read(fd: Fd, buf: []u8) IoResult {
    if (isSocket(fd)) {
        while (true) {
            const n = recv(socketOf(fd), buf.ptr, clampLen(buf.len), 0);
            // After a failed connect, Winsock can report the end of the
            // data. The socket has no peer, so the read is an error.
            if (n == 0 and buf.len > 0 and peerName(fd) == null) return .{ .err = failCode(wsaenotconn) };
            if (n != socket_error) return .{ .n = @intCast(n) };
            const e = wsaError();
            if (e == wsaeintr) continue;
            if (e == wsaewouldblock) return .again;
            // A read after `shutdown` is the end of the data.
            if (e == wsaeshutdown) {
                if (peerName(fd) == null) return .{ .err = failCode(wsaenotconn) };
                return .{ .n = 0 };
            }
            return .{ .err = failCode(e) };
        }
    }
    return switch (readFile(fd, buf)) {
        .n => |n| .{ .n = n },
        .err => |e| if (@intFromEnum(e) == error_no_data) .again else .{ .err = failOf(e) },
    };
}

pub fn readFile(fd: Fd, buf: []u8) sys.FileRead {
    var got: DWORD = 0;
    const room: DWORD = @intCast(@min(buf.len, std.math.maxInt(i32)));
    if (ReadFile(handleOf(fd), buf.ptr, room, &got, null) != 0) return .{ .n = got };
    const e = GetLastError();
    // The other end of a pipe closed: the end of the data.
    if (e == error_broken_pipe or e == error_handle_eof) return .{ .n = 0 };
    // ReadFile on the handle of a folder.
    if (e == error_invalid_function) return .{ .err = .ISDIR };
    return .{ .err = @enumFromInt(e) };
}

pub fn writeFile(fd: Fd, buf: []const u8) sys.FileRead {
    var put: DWORD = 0;
    const size: DWORD = @intCast(@min(buf.len, std.math.maxInt(i32)));
    if (WriteFile(handleOf(fd), buf.ptr, size, &put, null) == 0) return .{ .err = @enumFromInt(GetLastError()) };
    return .{ .n = put };
}

pub fn write(fd: Fd, buf: []const u8) IoResult {
    if (isSocket(fd)) {
        while (true) {
            const n = send(socketOf(fd), buf.ptr, clampLen(buf.len), 0);
            if (n != socket_error) return .{ .n = @intCast(n) };
            const e = wsaError();
            if (e == wsaeintr) continue;
            if (e == wsaewouldblock) return .again;
            return .{ .err = failCode(e) };
        }
    }
    var put: DWORD = 0;
    const size: DWORD = @intCast(@min(buf.len, std.math.maxInt(i32)));
    if (WriteFile(handleOf(fd), buf.ptr, size, &put, null) == 0) return .{ .err = failCode(GetLastError()) };
    // A pipe with no wait and no room writes no bytes.
    if (put == 0 and size > 0) return .again;
    return .{ .n = put };
}

pub fn close(fd: Fd) void {
    if (isSocket(fd)) {
        _ = closesocket(socketOf(fd));
    } else {
        _ = CloseHandle(handleOf(fd));
    }
}

pub fn setBlocking(fd: Fd, on: bool) void {
    if (isSocket(fd)) {
        var mode: u32 = if (on) 0 else 1;
        _ = ioctlsocket(socketOf(fd), @bitCast(fionbio), &mode);
        return;
    }
    const h = handleOf(fd);
    if (GetFileType(h) != file_type_pipe) return;
    var mode: DWORD = if (on) pipe_wait else pipe_nowait;
    _ = SetNamedPipeHandleState(h, &mode, null, null);
}

fn socketError(s: SOCKET) u32 {
    var code: u32 = 0;
    var len: i32 = 4;
    if (getsockopt(s, sol_socket, so_error, std.mem.asBytes(&code), &len) != 0) return 0;
    return code;
}

/// Checks a handle that is not a socket. Gives true when it is ready.
fn otherReady(w: *sys.Want, waits: *bool) bool {
    w.can_write = w.write;
    if (!w.read) return w.write;
    const h = handleOf(w.fd);
    switch (GetFileType(h)) {
        file_type_pipe => {
            var avail: DWORD = 0;
            // A failed peek is a closed pipe, so the read reports it.
            if (PeekNamedPipe(h, null, 0, null, &avail, null) == 0 or avail > 0) {
                w.can_read = true;
            } else {
                waits.* = true;
            }
        },
        file_type_char => {
            // The console handle is signaled when input waits. The NUL
            // device gives an error here, and it is always ready.
            if (WaitForSingleObject(h, 0) != 0x102) {
                w.can_read = true;
            } else {
                waits.* = true;
            }
        },
        else => w.can_read = true,
    }
    return w.can_read or w.can_write;
}

pub fn poll(a: std.mem.Allocator, wants: []sys.Want, timeout_ms: i32) void {
    startup();
    const fds = a.alloc(PollFd, wants.len) catch return;
    defer a.free(fds);
    const index = a.alloc(usize, wants.len) catch return;
    defer a.free(index);
    var count: usize = 0;
    for (wants, 0..) |*w, i| {
        w.can_read = false;
        w.can_write = false;
        if (!isSocket(w.fd)) continue;
        var ev: i16 = 0;
        if (w.read) ev |= pollrdnorm;
        if (w.write) ev |= pollwrnorm;
        fds[count] = .{ .fd = socketOf(w.fd), .events = ev, .revents = 0 };
        index[count] = i;
        count += 1;
    }
    const begin = GetTickCount64();
    while (true) {
        var ready = false;
        var waits = false;
        for (wants) |*w| {
            if (!isSocket(w.fd) and otherReady(w, &waits)) ready = true;
        }
        var left: i32 = -1;
        if (timeout_ms >= 0) {
            const spent = GetTickCount64() - begin;
            left = if (spent >= @as(u64, @intCast(timeout_ms))) 0 else timeout_ms - @as(i32, @intCast(spent));
        }
        var wait = left;
        if (ready) {
            wait = 0;
        } else if (waits) {
            wait = if (left < 0) slice_ms else @min(left, slice_ms);
        }
        if (count > 0) {
            const rc = WSAPoll(fds.ptr, @intCast(count), wait);
            if (rc == socket_error) {
                if (wsaError() == wsaeintr) continue;
                return;
            }
            for (fds[0..count], index[0..count]) |p, i| {
                const w = &wants[i];
                const bad = p.revents & (pollerr | pollhup | pollnval) != 0;
                w.can_read = w.read and (p.revents & pollrdnorm != 0 or bad);
                w.can_write = w.write and (p.revents & pollwrnorm != 0 or bad);
                // An older WSAPoll gives no event for a failed connect.
                if (rc == 0 and w.write and socketError(p.fd) != 0) w.can_write = true;
                if (w.can_read or w.can_write) ready = true;
            }
        } else if (wait != 0) {
            Sleep(if (wait < 0) std.math.maxInt(DWORD) else @intCast(wait));
        }
        if (ready or left == 0) return;
    }
}

fn toSock(addr: Addr) struct { Sock, i32 } {
    var a: Sock = undefined;
    const port = std.mem.nativeToBig(u16, addr.port);
    if (addr.v6) {
        a = .{ .in6 = .{ .family = @intCast(af_inet6), .port = port, .flowinfo = 0, .addr = addr.bytes, .scope_id = 0 } };
        return .{ a, @sizeOf(SockIn6) };
    }
    a = .{ .in = .{ .family = @intCast(af_inet), .port = port, .addr = addr.bytes[0..4].*, .zero = @splat(0) } };
    return .{ a, @sizeOf(SockIn) };
}

fn nameOf(a: *const Sock) Addr {
    var n: Addr = .{};
    if (a.family == @as(u16, @intCast(af_inet6))) {
        n.v6 = true;
        n.bytes = a.in6.addr;
        n.port = std.mem.bigToNative(u16, a.in6.port);
    } else {
        @memcpy(n.bytes[0..4], &a.in.addr);
        n.port = std.mem.bigToNative(u16, a.in.port);
    }
    return n;
}

fn newSocket(v6: bool) sys.SockResult {
    startup();
    const s = WSASocketW(if (v6) af_inet6 else af_inet, sock_stream, ipproto_tcp, null, 0, wsa_flag_no_handle_inherit);
    if (s == invalid_socket) return .{ .err = failCode(wsaError()) };
    const fd = fdOfSocket(s) orelse {
        _ = closesocket(s);
        return .{ .err = failCode(10024) };
    };
    if (v6) {
        const one: u32 = 1;
        if (setsockopt(s, ipproto_ipv6, ipv6_v6only, std.mem.asBytes(&one), 4) != 0) {
            const e = wsaError();
            _ = closesocket(s);
            return .{ .err = failCode(e) };
        }
    }
    return .{ .fd = fd };
}

/// `reuse` needs no option: Windows binds over a closed connection
/// that waits, and SO_EXCLUSIVEADDRUSE keeps other sockets off the port.
pub fn listenAt(addr: Addr, reuse: bool) sys.SockResult {
    _ = reuse;
    const fd = switch (newSocket(addr.v6)) {
        .fd => |x| x,
        .err => |e| return .{ .err = e },
    };
    const s = socketOf(fd);
    const one: u32 = 1;
    _ = setsockopt(s, sol_socket, so_exclusiveaddruse, std.mem.asBytes(&one), 4);
    const sa, const len = toSock(addr);
    if (bind(s, &sa, len) != 0 or listen(s, 128) != 0) {
        const e = wsaError();
        close(fd);
        return .{ .err = failCode(e) };
    }
    return .{ .fd = fd };
}

pub fn connectTo(addr: Addr, mine: ?Addr, wait: bool) sys.SockResult {
    const fd = switch (newSocket(addr.v6)) {
        .fd => |x| x,
        .err => |e| return .{ .err = e },
    };
    const s = socketOf(fd);
    if (mine) |m| {
        var local = m;
        local.v6 = addr.v6;
        const sa, const len = toSock(local);
        if (bind(s, &sa, len) != 0) {
            const e = wsaError();
            close(fd);
            return .{ .err = failCode(e) };
        }
    }
    if (!wait) setBlocking(fd, false);
    const sa, const len = toSock(addr);
    while (true) {
        if (connect(s, &sa, len) == 0) return .{ .fd = fd };
        const e = wsaError();
        if (e == wsaeintr) continue;
        if (e == wsaewouldblock) return .{ .fd = fd };
        close(fd);
        return .{ .err = failCode(e) };
    }
}

/// The name lookup, with the contract of the Linux form: a literal
/// address, `localhost`, and the hosts file of the system. It sends no
/// query to a name server, because `sock.zig` calls it before the
/// network policy, and a query sends the name off the machine.
pub fn resolve(a: std.mem.Allocator, host: []const u8, out: *std.ArrayList(Addr)) std.mem.Allocator.Error!void {
    if (sys.parseAddr(host)) |addr| {
        try out.append(a, addr);
        return;
    }
    if (host.len == 0 or host.len > 253) return;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) {
        try out.append(a, .{ .bytes = .{ 127, 0, 0, 1 } ++ [_]u8{0} ** 12 });
        try out.append(a, .{ .v6 = true, .bytes = [_]u8{0} ** 15 ++ [_]u8{1} });
        return;
    }
    var path: [320]u16 = undefined;
    const n = GetSystemDirectoryW(&path, 260);
    if (n == 0 or n >= 260) return;
    const tail = std.unicode.utf8ToUtf16LeStringLiteral("\\drivers\\etc\\hosts");
    @memcpy(path[n..][0..tail.len], tail);
    path[n + tail.len] = 0;
    const h = CreateFileW(@ptrCast(&path), generic_read, file_share_read_write, null, open_existing, 0, null);
    if (h == invalid_handle) return;
    defer _ = CloseHandle(h);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var buf: [4096]u8 = undefined;
    while (text.items.len < 1 << 20) {
        var got: DWORD = 0;
        if (ReadFile(h, &buf, buf.len, &got, null) == 0 or got == 0) break;
        try text.appendSlice(a, buf[0..got]);
    }
    try sys.hostsMatch(a, text.items, host, out);
}

pub fn connectError(fd: Fd) ?Fail {
    const s = socketOf(fd);
    const code = socketError(s);
    if (code == 0) return null;
    // A read of SO_ERROR leaves it set on Windows, so this call clears it.
    const zero: u32 = 0;
    _ = setsockopt(s, sol_socket, so_error, std.mem.asBytes(&zero), 4);
    return failCode(code);
}

pub fn acceptOn(fd: Fd) ?sys.Accepted {
    var sa: Sock = undefined;
    var len: i32 = @sizeOf(Sock);
    while (true) {
        const s = accept(socketOf(fd), &sa, &len);
        if (s == invalid_socket) {
            if (wsaError() == wsaeintr) continue;
            return null;
        }
        const conn = fdOfSocket(s) orelse {
            _ = closesocket(s);
            return null;
        };
        _ = SetHandleInformation(@ptrFromInt(s), handle_flag_inherit, 0);
        // A new socket has the mode of the listener. It starts blocking.
        setBlocking(conn, true);
        return .{ .fd = conn, .peer = nameOf(&sa) };
    }
}

pub fn sockName(fd: Fd) ?Addr {
    if (!isSocket(fd)) return null;
    var sa: Sock = undefined;
    var len: i32 = @sizeOf(Sock);
    if (getsockname(socketOf(fd), &sa, &len) != 0) return null;
    return nameOf(&sa);
}

pub fn peerName(fd: Fd) ?Addr {
    if (!isSocket(fd)) return null;
    var sa: Sock = undefined;
    var len: i32 = @sizeOf(Sock);
    if (getpeername(socketOf(fd), &sa, &len) != 0) return null;
    return nameOf(&sa);
}

pub fn shutdownOn(fd: Fd, how: i32) void {
    if (isSocket(fd)) _ = shutdown(socketOf(fd), how);
}

pub fn seek(fd: Fd, off: i64, whence: u8) sys.SeekResult {
    if (isSocket(fd)) return .{ .err = @enumFromInt(error_invalid_function) };
    const h = handleOf(fd);
    if (GetFileType(h) != file_type_disk) return .{ .err = @enumFromInt(error_invalid_function) };
    var at: i64 = 0;
    if (SetFilePointerEx(h, off, &at, whence) == 0) return .{ .err = @enumFromInt(GetLastError()) };
    return .{ .at = at };
}

/// True when a child process can inherit the handle.
pub fn inheritable(fd: Fd) bool {
    const h: HANDLE = if (isSocket(fd)) @ptrFromInt(socketOf(fd)) else handleOf(fd);
    var flags: DWORD = 0;
    if (GetHandleInformation(h, &flags) == 0) return false;
    return flags & handle_flag_inherit != 0;
}

/// True when an IPv6 socket has no IPv4 side.
pub fn v6Only(fd: Fd) bool {
    var on: u32 = 0;
    var len: i32 = 4;
    if (getsockopt(socketOf(fd), ipproto_ipv6, ipv6_v6only, std.mem.asBytes(&on), &len) != 0) return false;
    return on != 0;
}

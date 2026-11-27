//! The Winsock and kernel32 calls of `aio` on Windows, and the
//! functions of `sys.zig` for Windows.
//!
//! A descriptor of `aio` on Windows is a SOCKET in an `i32`: Windows
//! keeps the significant bits of a kernel handle in the low 32 bits, as
//! `src/sys_windows.zig` notes too. Each socket is overlapped
//! (WSA_FLAG_OVERLAPPED) with no handle inheritance, so IOCP can run its
//! operations. An error is a negative value of `std.posix.E`: `errno`
//! maps the WSA codes.
//!
//! Windows has no pipe for IOCP with no names, so `pipe` gives the two
//! ends of a loopback TCP connection.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const posix = std.posix;
const E = posix.E;

pub const SOCKET = usize;
pub const HANDLE = ?*anyopaque;
pub const BOOL = i32;
pub const DWORD = u32;
pub const invalid_socket: SOCKET = ~@as(SOCKET, 0);
pub const socket_error: i32 = -1;

pub const OVERLAPPED = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: HANDLE = null,
};

pub const OVERLAPPED_ENTRY = extern struct {
    key: usize,
    ov: ?*OVERLAPPED,
    internal: usize,
    bytes: DWORD,
};

pub const WSABUF = extern struct {
    len: u32,
    buf: [*]const u8,
};

pub const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

/// The GUIDs of mswsock.h for AcceptEx and ConnectEx.
pub const wsaid_acceptex: GUID = .{ .a = 0xb5367df1, .b = 0xcbac, .c = 0x11cf, .d = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 } };
pub const wsaid_connectex: GUID = .{ .a = 0x25a207b9, .b = 0xddf3, .c = 0x4660, .d = .{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e } };

pub const AcceptEx = *const fn (listen: SOCKET, accept: SOCKET, buf: [*]u8, data_len: DWORD, local_len: DWORD, remote_len: DWORD, bytes: *DWORD, ov: *OVERLAPPED) callconv(.winapi) BOOL;
pub const ConnectEx = *const fn (s: SOCKET, name: *const posix.sockaddr, len: i32, send: ?*const anyopaque, send_len: DWORD, sent: ?*DWORD, ov: *OVERLAPPED) callconv(.winapi) BOOL;

pub const SOL_SOCKET = 0xffff;
pub const SO_ERROR = 0x1007;
pub const SO_UPDATE_ACCEPT_CONTEXT = 0x700B;
pub const SO_UPDATE_CONNECT_CONTEXT = 0x7010;
pub const SIO_GET_EXTENSION_FUNCTION_POINTER: DWORD = 0xC8000006;
const WSA_FLAG_OVERLAPPED = 0x01;
const WSA_FLAG_NO_HANDLE_INHERIT = 0x80;
pub const WSA_IO_PENDING = 997;
pub const ERROR_OPERATION_ABORTED = 995;
pub const WAIT_TIMEOUT = 258;
pub const INFINITE: DWORD = 0xffffffff;

pub extern "kernel32" fn CreateIoCompletionPort(file: HANDLE, existing: HANDLE, key: usize, threads: DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetQueuedCompletionStatusEx(port: HANDLE, entries: [*]OVERLAPPED_ENTRY, count: u32, removed: *u32, ms: DWORD, alertable: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn PostQueuedCompletionStatus(port: HANDLE, bytes: DWORD, key: usize, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelIoEx(h: HANDLE, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) BOOL;

extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) i32;
pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
extern "ws2_32" fn WSASocketW(af: i32, kind: i32, protocol: i32, info: ?*anyopaque, group: u32, flags: u32) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn WSAIoctl(s: SOCKET, code: DWORD, in: ?*const anyopaque, in_len: DWORD, out: ?*anyopaque, out_len: DWORD, ret: *DWORD, ov: ?*OVERLAPPED, routine: ?*const anyopaque) callconv(.winapi) i32;
pub extern "ws2_32" fn WSARecv(s: SOCKET, bufs: [*]const WSABUF, n: DWORD, got: ?*DWORD, flags: *DWORD, ov: ?*OVERLAPPED, routine: ?*const anyopaque) callconv(.winapi) i32;
pub extern "ws2_32" fn WSASend(s: SOCKET, bufs: [*]const WSABUF, n: DWORD, sent: ?*DWORD, flags: DWORD, ov: ?*OVERLAPPED, routine: ?*const anyopaque) callconv(.winapi) i32;
pub extern "ws2_32" fn WSAGetOverlappedResult(s: SOCKET, ov: *OVERLAPPED, bytes: *DWORD, wait: BOOL, flags: *DWORD) callconv(.winapi) BOOL;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn bind(s: SOCKET, name: *const posix.sockaddr, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
extern "ws2_32" fn accept(s: SOCKET, name: ?*posix.sockaddr, len: ?*i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn connect(s: SOCKET, name: *const posix.sockaddr, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn shutdown(s: SOCKET, how: i32) callconv(.winapi) i32;
extern "ws2_32" fn getsockname(s: SOCKET, name: *posix.sockaddr, len: *i32) callconv(.winapi) i32;
extern "ws2_32" fn getsockopt(s: SOCKET, level: i32, name: i32, value: [*]u8, len: *i32) callconv(.winapi) i32;
pub extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, name: i32, value: ?[*]const u8, len: i32) callconv(.winapi) i32;

var started = std.atomic.Value(bool).init(false);

/// WSAStartup counts its calls, so a race of two threads is harmless.
pub fn startup() void {
    if (started.load(.acquire)) return;
    var data: [512]u8 align(8) = undefined;
    if (WSAStartup(0x0202, &data) == 0) started.store(true, .release);
}

pub fn sock(fd: i32) SOCKET {
    return @as(u32, @bitCast(fd));
}

pub fn handle(fd: i32) HANDLE {
    return @ptrFromInt(sock(fd));
}

/// The descriptor of a socket, or an error for a value past 31 bits.
fn fdOf(s: SOCKET) i32 {
    if (s == invalid_socket) return wsaError();
    if (s > std.math.maxInt(i32)) {
        _ = closesocket(s);
        return neg(.MFILE);
    }
    return @intCast(s);
}

fn neg(e: E) i32 {
    return -@as(i32, @intCast(@backingInt(e)));
}

/// The negative errno of a WSA or Win32 error code.
pub fn errno(code: i32) i32 {
    return neg(switch (code) {
        10035, WSA_IO_PENDING => .AGAIN,
        ERROR_OPERATION_ABORTED, 10004 => .CANCELED,
        10061, 1225 => .CONNREFUSED,
        10054, 64 => .CONNRESET,
        10053, 1236 => .CONNABORTED,
        10048 => .ADDRINUSE,
        10049 => .ADDRNOTAVAIL,
        10057 => .NOTCONN,
        10058 => .PIPE,
        10060, 121 => .TIMEDOUT,
        10051, 1231 => .NETUNREACH,
        10065, 1232 => .HOSTUNREACH,
        10022 => .INVAL,
        10024 => .MFILE,
        10038 => .BADF,
        10055 => .NOBUFS,
        10014 => .FAULT,
        else => .IO,
    });
}

pub fn wsaError() i32 {
    return errno(WSAGetLastError());
}

fn rc(r: i32) i32 {
    return if (r == socket_error) wsaError() else r;
}

pub fn tcpSocket(family: u32) i32 {
    startup();
    return fdOf(WSASocketW(@intCast(family), 1, 6, null, 0, WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT));
}

pub fn sockBind(fd: i32, addr: *const posix.sockaddr, len: posix.socklen_t) i32 {
    return rc(bind(sock(fd), addr, @intCast(len)));
}

pub fn sockListen(fd: i32, backlog: u31) i32 {
    return rc(listen(sock(fd), backlog));
}

pub fn sockName(fd: i32, addr: *posix.sockaddr, len: *posix.socklen_t) i32 {
    var l: i32 = @intCast(len.*);
    const r = rc(getsockname(sock(fd), addr, &l));
    len.* = @intCast(l);
    return r;
}

pub fn sockAccept(fd: i32) i32 {
    return fdOf(accept(sock(fd), null, null));
}

pub fn sockConnect(fd: i32, addr: *const posix.sockaddr, len: posix.socklen_t) i32 {
    return rc(connect(sock(fd), addr, @intCast(len)));
}

pub fn sockRead(fd: i32, buf: []u8) i32 {
    return rc(recv(sock(fd), buf.ptr, @intCast(@min(buf.len, std.math.maxInt(i32))), 0));
}

pub fn sockWrite(fd: i32, buf: []const u8) i32 {
    return rc(send(sock(fd), buf.ptr, @intCast(@min(buf.len, std.math.maxInt(i32))), 0));
}

pub fn sockClose(fd: i32) void {
    _ = closesocket(sock(fd));
}

pub fn sockShutdownWrite(fd: i32) void {
    _ = shutdown(sock(fd), 1);
}

pub fn sockError(fd: i32) i32 {
    var err: i32 = 0;
    var len: i32 = @sizeOf(i32);
    _ = getsockopt(sock(fd), SOL_SOCKET, SO_ERROR, @ptrCast(&err), &len);
    return if (err == 0) 0 else errno(err);
}

/// The two ends of a loopback TCP connection: fds[0] reads what fds[1]
/// writes.
pub fn pipe(fds: *[2]i32) i32 {
    const l = tcpSocket(posix.AF.INET);
    if (l < 0) return l;
    defer sockClose(l);
    var addr = std.mem.zeroes(posix.sockaddr.in);
    addr.family = posix.AF.INET;
    addr.addr = std.mem.nativeToBig(u32, 0x7f000001);
    var r = sockBind(l, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    if (r < 0) return r;
    r = sockListen(l, 1);
    if (r < 0) return r;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    r = sockName(l, @ptrCast(&addr), &len);
    if (r < 0) return r;
    const w = tcpSocket(posix.AF.INET);
    if (w < 0) return w;
    r = sockConnect(w, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    if (r < 0) {
        sockClose(w);
        return r;
    }
    const rd = sockAccept(l);
    if (rd < 0) {
        sockClose(w);
        return rd;
    }
    fds.* = .{ rd, w };
    return 0;
}

pub fn sleepNs(ns: u64) void {
    Sleep(@intCast(@min(ns / std.time.ns_per_ms, INFINITE - 1)));
}

var freq = std.atomic.Value(i64).init(0);

pub fn now() u64 {
    var f = freq.load(.monotonic);
    if (f == 0) {
        _ = QueryPerformanceFrequency(&f);
        freq.store(f, .monotonic);
    }
    var c: i64 = 0;
    _ = QueryPerformanceCounter(&c);
    const cu: u128 = @intCast(c);
    return @intCast(cu * std.time.ns_per_s / @as(u128, @intCast(f)));
}

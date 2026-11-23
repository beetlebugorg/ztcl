//! The platform interface of the event loop, `socket`, and `exec`.
//!
//! Each function here is one small host operation on a descriptor. The
//! callers (`event.zig`, `sock.zig`, `proc.zig`, `chan.zig`) have no
//! other platform code. This file has the Linux form, with direct
//! system calls, and the macOS form, with the same names over libc
//! (`darwin`). A port to another system writes these functions again
//! with the same contracts and sets `supported`.
//!
//! The rules of a port:
//! - `resolve` is the only name lookup. `listenAt` and `connectTo` get
//!   an address as bytes. `sock.zig` checks each address against the
//!   network policy of the embedder before the call, and it checks the
//!   address of each connection again after the call.
//! - Each descriptor closes on exec.
//! - A call that the system interrupts runs again.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const os = if (builtin.os.tag == .macos) darwin else std.os.linux;

/// The calls of this file on macOS, in the shape of `std.os.linux`: a
/// result is a `usize`, and `errno` reads an error from it. macOS has no
/// SOCK_CLOEXEC, accept4, or MSG_NOSIGNAL, so `socket` and `accept4` set
/// FD_CLOEXEC and SO_NOSIGPIPE on each new socket right after the call.
const darwin = struct {
    const c = std.c;
    pub const E = c.E;
    pub const F = c.F;
    pub const O = c.O;
    pub const SIG = c.SIG;
    pub const Sigaction = c.Sigaction;
    pub const sigset_t = c.sigset_t;
    pub const POLL = c.POLL;
    pub const pollfd = c.pollfd;
    pub const AF = c.AF;
    pub const SOCK = struct {
        pub const STREAM = c.SOCK.STREAM;
        pub const CLOEXEC = 0;
    };
    pub const IPPROTO = c.IPPROTO;
    pub const IPV6 = struct {
        pub const V6ONLY = 27;
    };
    pub const SOL = c.SOL;
    pub const SO = c.SO;
    pub const sockaddr = c.sockaddr;
    pub const socklen_t = c.socklen_t;

    /// A count of bytes for one call: the system refuses more than 2 GiB.
    const max_io = std.math.maxInt(i32);

    fn ret(r: anytype) usize {
        if (r == -1) return @bitCast(-@as(isize, c._errno().*));
        return @intCast(r);
    }

    pub fn errno(rc: usize) E {
        const s: isize = @bitCast(rc);
        return if (s < 0 and s > -4096) @enumFromInt(-s) else .SUCCESS;
    }

    pub fn read(fd: i32, buf: [*]u8, n: usize) usize {
        return ret(c.read(fd, buf, @min(n, max_io)));
    }

    pub fn write(fd: i32, buf: [*]const u8, n: usize) usize {
        return ret(c.write(fd, buf, @min(n, max_io)));
    }

    pub fn close(fd: i32) usize {
        return ret(c.close(fd));
    }

    pub fn open(path: [*:0]const u8, flags: O, mode: c.mode_t) usize {
        return ret(c.open(path, flags, mode));
    }

    pub fn fcntl(fd: i32, cmd: anytype, arg: usize) usize {
        return ret(c.fcntl(fd, @as(c_int, @intCast(cmd)), @as(c_int, @truncate(@as(isize, @bitCast(arg))))));
    }

    pub fn sigaction(sig: anytype, act: *const Sigaction, old: ?*Sigaction) usize {
        return ret(c.sigaction(sig, act, old));
    }

    pub fn poll(fds: [*]pollfd, n: usize, timeout: i32) usize {
        return ret(c.poll(fds, @intCast(n), timeout));
    }

    fn guard(fd: i32) void {
        _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        const one: c_int = 1;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
    }

    pub fn socket(family: u32, kind: u32, proto: u32) usize {
        const rc = c.socket(family, kind, proto);
        if (rc >= 0) guard(rc);
        return ret(rc);
    }

    pub fn accept4(fd: i32, addr: *sockaddr, len: *socklen_t, _: u32) usize {
        const rc = c.accept(fd, addr, len);
        if (rc >= 0) guard(rc);
        return ret(rc);
    }

    pub fn setsockopt(fd: i32, level: anytype, opt: anytype, val: [*]const u8, len: socklen_t) usize {
        return ret(c.setsockopt(fd, @intCast(level), @intCast(opt), val, len));
    }

    pub fn getsockopt(fd: i32, level: anytype, opt: anytype, val: [*]u8, len: *socklen_t) usize {
        return ret(c.getsockopt(fd, @intCast(level), @intCast(opt), val, len));
    }

    pub fn bind(fd: i32, addr: *const sockaddr, len: socklen_t) usize {
        return ret(c.bind(fd, addr, len));
    }

    pub fn listen(fd: i32, backlog: u31) usize {
        return ret(c.listen(fd, backlog));
    }

    pub fn connect(fd: i32, addr: *const sockaddr, len: socklen_t) usize {
        return ret(c.connect(fd, addr, len));
    }

    pub fn getsockname(fd: i32, addr: *sockaddr, len: *socklen_t) usize {
        return ret(c.getsockname(fd, addr, len));
    }

    pub fn getpeername(fd: i32, addr: *sockaddr, len: *socklen_t) usize {
        return ret(c.getpeername(fd, addr, len));
    }

    pub fn shutdown(fd: i32, how: i32) usize {
        return ret(c.shutdown(fd, how));
    }

    pub fn lseek(fd: i32, off: i64, whence: u8) usize {
        return ret(c.lseek(fd, off, whence));
    }
};

const on_mac = builtin.os.tag == .macos;

pub const supported = builtin.os.tag == .linux or (on_mac and builtin.cpu.arch == .aarch64);

pub const Fd = i32;

/// A host error number. Each port sets its own type.
pub const Errno = if (builtin.os.tag == .linux or on_mac) os.E else u32;

/// How to open a file. `fsroot.zig` maps these flags to the system.
pub const OpenFlags = struct {
    access: enum { read, write, read_write } = .read,
    create: bool = false,
    exclusive: bool = false,
    truncate: bool = false,
    append: bool = false,
    directory: bool = false,
    /// A descriptor for path operations, with no access to the data.
    path_only: bool = false,
};

/// A host error, as the POSIX name and the text of Tcl.
pub const Fail = struct { name: []const u8, text: []const u8 };

pub fn failOf(e: os.E) Fail {
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
        const rc = os.read(fd, buf.ptr, buf.len);
        switch (os.errno(rc)) {
            .SUCCESS => return .{ .n = rc },
            .INTR => continue,
            .AGAIN => return .again,
            // The end of a closed connection reads as the end of data.
            .CONNRESET => return .{ .err = failOf(.CONNRESET) },
            else => |e| return .{ .err = failOf(e) },
        }
    }
}

/// Reads a file for a caller that reports the host error itself. A
/// read of 0 bytes is the end of the file.
pub fn readFile(fd: Fd, buf: []u8) union(enum) { n: usize, err: Errno } {
    while (true) {
        const rc = os.read(fd, buf.ptr, buf.len);
        switch (os.errno(rc)) {
            .SUCCESS => return .{ .n = rc },
            .INTR => continue,
            else => |e| return .{ .err = e },
        }
    }
}

pub fn write(fd: Fd, buf: []const u8) IoResult {
    while (true) {
        // MSG_NOSIGNAL is not possible on a pipe, so SIGPIPE is ignored
        // by `ignorePipeSignal` at the start of a runner.
        const rc = os.write(fd, buf.ptr, buf.len);
        switch (os.errno(rc)) {
            .SUCCESS => return .{ .n = rc },
            .INTR => continue,
            .AGAIN => return .again,
            else => |e| return .{ .err = failOf(e) },
        }
    }
}

pub fn close(fd: Fd) void {
    _ = os.close(fd);
}

pub fn setBlocking(fd: Fd, on: bool) void {
    const fl = os.fcntl(fd, os.F.GETFL, 0);
    if (os.errno(fl) != .SUCCESS) return;
    const bit: usize = @as(u32, @bitCast(os.O{ .NONBLOCK = true }));
    _ = os.fcntl(fd, os.F.SETFL, if (on) fl & ~bit else fl | bit);
}

/// A write to a closed pipe or socket gives an error and no signal.
pub fn ignorePipeSignal() void {
    var act: os.Sigaction = .{ .handler = .{ .handler = os.SIG.IGN }, .mask = std.mem.zeroes(os.sigset_t), .flags = 0 };
    _ = os.sigaction(os.SIG.PIPE, &act, null);
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
    const fds = a.alloc(os.pollfd, wants.len) catch return;
    defer a.free(fds);
    for (wants, fds) |w, *p| {
        var ev: i16 = 0;
        if (w.read) ev |= os.POLL.IN;
        if (w.write) ev |= os.POLL.OUT;
        p.* = .{ .fd = w.fd, .events = ev, .revents = 0 };
    }
    const rc = os.poll(fds.ptr, fds.len, timeout_ms);
    if (os.errno(rc) != .SUCCESS) return;
    for (wants, fds) |*w, p| {
        const bad = p.revents & (os.POLL.ERR | os.POLL.HUP | os.POLL.NVAL) != 0;
        w.can_read = w.read and (p.revents & os.POLL.IN != 0 or bad);
        w.can_write = w.write and (p.revents & os.POLL.OUT != 0 or bad);
    }
}

// ---- Sockets ----

/// An IP address and a port. An IPv4 address uses the first 4 bytes.
pub const Addr = struct {
    v6: bool = false,
    bytes: [16]u8 = @splat(0),
    port: u16 = 0,
};

/// The older name of `Addr`.
pub const Name = Addr;

const Sock = extern union { any: os.sockaddr, in: os.sockaddr.in, in6: os.sockaddr.in6 };

fn toSock(addr: Addr) struct { Sock, os.socklen_t } {
    var a: Sock = undefined;
    if (addr.v6) {
        a.in6 = .{ .port = std.mem.nativeToBig(u16, addr.port), .flowinfo = 0, .addr = addr.bytes, .scope_id = 0 };
        return .{ a, @sizeOf(os.sockaddr.in6) };
    }
    a.in = .{ .port = std.mem.nativeToBig(u16, addr.port), .addr = @bitCast(addr.bytes[0..4].*) };
    return .{ a, @sizeOf(os.sockaddr.in) };
}

fn nameOf(a: *const Sock) Addr {
    var n: Addr = .{};
    if (a.any.family == os.AF.INET6) {
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

fn newSocket(v6: bool) SockResult {
    const family: u32 = if (v6) os.AF.INET6 else os.AF.INET;
    const rc = os.socket(family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    if (os.errno(rc) != .SUCCESS) return .{ .err = failOf(os.errno(rc)) };
    const fd: Fd = @intCast(rc);
    if (v6) {
        // An IPv6 socket has no IPv4 side, so each address family has
        // its own socket and its own policy check.
        const one: u32 = 1;
        _ = os.setsockopt(fd, os.IPPROTO.IPV6, os.IPV6.V6ONLY, std.mem.asBytes(&one), 4);
    }
    return .{ .fd = fd };
}

/// A listening socket on an address. Port 0 selects a free port. The
/// caller checks the address against the network policy first.
pub fn listenAt(addr: Addr, reuse: bool) SockResult {
    const fd = switch (newSocket(addr.v6)) {
        .fd => |x| x,
        .err => |e| return .{ .err = e },
    };
    if (reuse) {
        const one: u32 = 1;
        _ = os.setsockopt(fd, os.SOL.SOCKET, os.SO.REUSEADDR, std.mem.asBytes(&one), 4);
    }
    const sa, const len = toSock(addr);
    var rc = os.bind(fd, &sa.any, len);
    if (os.errno(rc) == .SUCCESS) rc = os.listen(fd, 128);
    if (os.errno(rc) != .SUCCESS) {
        close(fd);
        return .{ .err = failOf(os.errno(rc)) };
    }
    return .{ .fd = fd };
}

/// A connection to an address. `mine` binds the local address and
/// port. With `wait` false the connect continues in the background,
/// and `connectError` gives its end. The caller checks the address
/// against the network policy first.
pub fn connectTo(addr: Addr, mine: ?Addr, wait: bool) SockResult {
    const fd = switch (newSocket(addr.v6)) {
        .fd => |x| x,
        .err => |e| return .{ .err = e },
    };
    if (mine) |m| {
        const one: u32 = 1;
        _ = os.setsockopt(fd, os.SOL.SOCKET, os.SO.REUSEADDR, std.mem.asBytes(&one), 4);
        var local = m;
        local.v6 = addr.v6;
        const sa, const len = toSock(local);
        const rc = os.bind(fd, &sa.any, len);
        if (os.errno(rc) != .SUCCESS) {
            close(fd);
            return .{ .err = failOf(os.errno(rc)) };
        }
    }
    if (!wait) setBlocking(fd, false);
    const sa, const len = toSock(addr);
    while (true) {
        const rc = os.connect(fd, &sa.any, len);
        switch (os.errno(rc)) {
            .SUCCESS, .INPROGRESS => return .{ .fd = fd },
            .INTR => continue,
            else => |e| {
                close(fd);
                return .{ .err = failOf(e) };
            },
        }
    }
}

/// The address of an IPv4 or IPv6 literal, or null.
pub fn parseAddr(text: []const u8) ?Addr {
    var out: Addr = .{};
    if (std.mem.indexOfScalar(u8, text, ':') == null) {
        var parts = std.mem.splitScalar(u8, text, '.');
        var i: usize = 0;
        while (parts.next()) |p| : (i += 1) {
            if (i >= 4 or p.len == 0 or p.len > 3) return null;
            out.bytes[i] = std.fmt.parseInt(u8, p, 10) catch return null;
        }
        return if (i == 4) out else null;
    }
    out.v6 = true;
    // The groups before and after `::`.
    var groups: [8]u16 = @splat(0);
    var count: usize = 0;
    var gap: ?usize = null;
    var rest = text;
    if (std.mem.startsWith(u8, rest, "::")) {
        gap = 0;
        rest = rest[2..];
    }
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
        const g = rest[0..end];
        if (g.len == 0 or g.len > 4 or count >= 8) return null;
        groups[count] = std.fmt.parseInt(u16, g, 16) catch return null;
        count += 1;
        if (end == rest.len) break;
        rest = rest[end + 1 ..];
        if (rest.len == 0) return null;
        if (rest[0] == ':') {
            if (gap != null) return null;
            gap = count;
            rest = rest[1..];
        }
    }
    if (gap == null and count != 8) return null;
    if (gap != null and count >= 8) return null;
    const shift = 8 - count;
    for (0..count) |i| {
        const at = if (gap != null and i >= gap.?) i + shift else i;
        out.bytes[at * 2] = @intCast(groups[i] >> 8);
        out.bytes[at * 2 + 1] = @intCast(groups[i] & 0xff);
    }
    return out;
}

/// The addresses of a host word, in the order to try. This is the one
/// name lookup of the interpreter. It reads a literal address, the
/// name `localhost`, and the hosts file of the system. It sends no
/// query to a name server yet, so another name gives no address.
pub fn resolve(a: std.mem.Allocator, host: []const u8, out: *std.ArrayList(Addr)) std.mem.Allocator.Error!void {
    if (parseAddr(host)) |addr| {
        try out.append(a, addr);
        return;
    }
    if (host.len == 0 or host.len > 253) return;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) {
        try out.append(a, .{ .bytes = .{ 127, 0, 0, 1 } ++ [_]u8{0} ** 12 });
        try out.append(a, .{ .v6 = true, .bytes = [_]u8{0} ** 15 ++ [_]u8{1} });
        return;
    }
    // The hosts file: an address, then names, on each line.
    const rc = os.open("/etc/hosts", .{ .CLOEXEC = true }, 0);
    if (os.errno(rc) != .SUCCESS) return;
    const fd: Fd = @intCast(rc);
    defer close(fd);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var buf: [4096]u8 = undefined;
    while (text.items.len < 1 << 20) {
        switch (read(fd, &buf)) {
            .n => |n| if (n > 0) {
                try text.appendSlice(a, buf[0..n]);
                continue;
            },
            else => {},
        }
        break;
    }
    var lines = std.mem.splitScalar(u8, text.items, '\n');
    while (lines.next()) |line_in| {
        const line = line_in[0 .. std.mem.indexOfScalar(u8, line_in, '#') orelse line_in.len];
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const first = words.next() orelse continue;
        const addr = parseAddr(first) orelse continue;
        while (words.next()) |w| {
            if (std.ascii.eqlIgnoreCase(w, host)) try out.append(a, addr);
        }
    }
}

/// The pending error of a socket, or null. The call clears the error.
pub fn connectError(fd: Fd) ?Fail {
    var code: u32 = 0;
    var len: os.socklen_t = 4;
    const rc = os.getsockopt(fd, os.SOL.SOCKET, os.SO.ERROR, std.mem.asBytes(&code), &len);
    if (os.errno(rc) != .SUCCESS or code == 0) return null;
    return failOf(@enumFromInt(code));
}

pub const Accepted = struct { fd: Fd, peer: Addr };

/// The next connection of a listening socket, or null when none waits.
pub fn accept(fd: Fd) ?Accepted {
    var a: Sock = undefined;
    var len: os.socklen_t = @sizeOf(Sock);
    while (true) {
        const rc = os.accept4(fd, &a.any, &len, os.SOCK.CLOEXEC);
        switch (os.errno(rc)) {
            .SUCCESS => return .{ .fd = @intCast(rc), .peer = nameOf(&a) },
            .INTR => continue,
            else => return null,
        }
    }
}

pub fn sockName(fd: Fd) ?Addr {
    var a: Sock = undefined;
    var len: os.socklen_t = @sizeOf(Sock);
    if (os.errno(os.getsockname(fd, &a.any, &len)) != .SUCCESS) return null;
    return nameOf(&a);
}

pub fn peerName(fd: Fd) ?Addr {
    var a: Sock = undefined;
    var len: os.socklen_t = @sizeOf(Sock);
    if (os.errno(os.getpeername(fd, &a.any, &len)) != .SUCCESS) return null;
    return nameOf(&a);
}

/// Ends one direction of a socket: 0 for reads, 1 for writes.
pub fn shutdown(fd: Fd, how: i32) void {
    _ = os.shutdown(fd, how);
}

/// Moves the position of a file: `whence` is 0 for the start, 1 for
/// the current position, and 2 for the end. Gives the new position.
pub fn seek(fd: Fd, off: i64, whence: u8) union(enum) { at: i64, err: Errno } {
    const rc = os.lseek(fd, off, whence);
    const e = os.errno(rc);
    if (e != .SUCCESS) return .{ .err = e };
    return .{ .at = @intCast(rc) };
}

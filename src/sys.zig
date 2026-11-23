//! The platform interface of the event loop, `socket`, and `exec`.
//!
//! Each function here is one small host operation on a descriptor. The
//! callers (`event.zig`, `sock.zig`, `proc.zig`, `chan.zig`) have no
//! other platform code. This file has the Linux form, with direct
//! system calls. A port to another system writes these functions again
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

// ---- Sockets ----

/// An IP address and a port. An IPv4 address uses the first 4 bytes.
pub const Addr = struct {
    v6: bool = false,
    bytes: [16]u8 = @splat(0),
    port: u16 = 0,
};

/// The older name of `Addr`.
pub const Name = Addr;

const Sock = extern union { any: linux.sockaddr, in: linux.sockaddr.in, in6: linux.sockaddr.in6 };

fn toSock(addr: Addr) struct { Sock, linux.socklen_t } {
    var a: Sock = undefined;
    if (addr.v6) {
        a.in6 = .{ .port = std.mem.nativeToBig(u16, addr.port), .flowinfo = 0, .addr = addr.bytes, .scope_id = 0 };
        return .{ a, @sizeOf(linux.sockaddr.in6) };
    }
    a.in = .{ .port = std.mem.nativeToBig(u16, addr.port), .addr = @bitCast(addr.bytes[0..4].*) };
    return .{ a, @sizeOf(linux.sockaddr.in) };
}

fn nameOf(a: *const Sock) Addr {
    var n: Addr = .{};
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

fn newSocket(v6: bool) SockResult {
    const family: u32 = if (v6) linux.AF.INET6 else linux.AF.INET;
    const rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return .{ .err = failOf(linux.errno(rc)) };
    const fd: Fd = @intCast(rc);
    if (v6) {
        // An IPv6 socket has no IPv4 side, so each address family has
        // its own socket and its own policy check.
        const one: u32 = 1;
        _ = linux.setsockopt(fd, linux.IPPROTO.IPV6, linux.IPV6.V6ONLY, std.mem.asBytes(&one), 4);
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
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
    }
    const sa, const len = toSock(addr);
    var rc = linux.bind(fd, &sa.any, len);
    if (linux.errno(rc) == .SUCCESS) rc = linux.listen(fd, 128);
    if (linux.errno(rc) != .SUCCESS) {
        close(fd);
        return .{ .err = failOf(linux.errno(rc)) };
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
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
        var local = m;
        local.v6 = addr.v6;
        const sa, const len = toSock(local);
        const rc = linux.bind(fd, &sa.any, len);
        if (linux.errno(rc) != .SUCCESS) {
            close(fd);
            return .{ .err = failOf(linux.errno(rc)) };
        }
    }
    if (!wait) setBlocking(fd, false);
    const sa, const len = toSock(addr);
    while (true) {
        const rc = linux.connect(fd, &sa.any, len);
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
    const rc = linux.open("/etc/hosts", .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
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
    var len: linux.socklen_t = 4;
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, std.mem.asBytes(&code), &len);
    if (linux.errno(rc) != .SUCCESS or code == 0) return null;
    return failOf(@enumFromInt(code));
}

pub const Accepted = struct { fd: Fd, peer: Addr };

/// The next connection of a listening socket, or null when none waits.
pub fn accept(fd: Fd) ?Accepted {
    var a: Sock = undefined;
    var len: linux.socklen_t = @sizeOf(Sock);
    while (true) {
        const rc = linux.accept4(fd, &a.any, &len, linux.SOCK.CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => return .{ .fd = @intCast(rc), .peer = nameOf(&a) },
            .INTR => continue,
            else => return null,
        }
    }
}

pub fn sockName(fd: Fd) ?Addr {
    var a: Sock = undefined;
    var len: linux.socklen_t = @sizeOf(Sock);
    if (linux.errno(linux.getsockname(fd, &a.any, &len)) != .SUCCESS) return null;
    return nameOf(&a);
}

pub fn peerName(fd: Fd) ?Addr {
    var a: Sock = undefined;
    var len: linux.socklen_t = @sizeOf(Sock);
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

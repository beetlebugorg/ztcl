//! The optional `socket` command (capability `socket`).
//!
//! A socket is a channel of `chan.zig` on a TCP connection. The command
//! accepts only the loopback addresses 127.0.0.1 and ::1 and the name
//! `localhost`. It makes no name lookup, so no request leaves the host.
//! A server socket binds a loopback address, and it closes a connection
//! whose peer is not a loopback address. The event loop of `event.zig`
//! runs the accept command and the `fileevent` scripts.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const chan = @import("chan.zig");
const event = @import("event.zig");
const sys = @import("sys.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// True for 127.0.0.0/8 and ::1.
pub fn isLoop(n: sys.Name) bool {
    if (!n.v6) return n.bytes[0] == 127;
    const one = [_]u8{0} ** 15 ++ [_]u8{1};
    if (std.mem.eql(u8, &n.bytes, &one)) return true;
    // An IPv4 loopback address in the IPv6 form.
    const mapped = [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff, 127 };
    return std.mem.eql(u8, n.bytes[0..13], &mapped);
}

pub fn addrText(it: *Interp, n: sys.Name) Error![]const u8 {
    if (!n.v6) return std.fmt.allocPrint(it.alloc(), "{d}.{d}.{d}.{d}", .{ n.bytes[0], n.bytes[1], n.bytes[2], n.bytes[3] });
    return "::1";
}

/// The loopback kind of a host word, or null for another host.
fn loopOf(host: []const u8) ?sys.Loop {
    if (eql(host, "localhost") or eql(host, "127.0.0.1")) return .v4;
    if (eql(host, "::1") or eql(host, "ip6-localhost")) return .v6;
    return null;
}

fn sysError(it: *Interp, f: sys.Fail, what: []const u8) Error {
    const code = try std.fmt.allocPrint(it.alloc(), "POSIX {s} {{{s}}}", .{ f.name, f.text });
    return it.failCode(code, "{s}{s}", .{ what, f.text });
}

fn nameList(it: *Interp, n: sys.Name) Error!Value {
    const text = try addrText(it, n);
    return value.newList(it.alloc(), &.{ .{ .str = text }, .{ .str = if (isLoop(n)) "localhost" else text }, .{ .int = n.port } });
}

/// One option of `fconfigure` on a socket, or null.
pub fn option(it: *Interp, c: *chan.Channel, o: []const u8) Error!?Value {
    if (eql(o, "-sockname")) return try nameList(it, sys.sockName(c.fd) orelse return Value.empty);
    if (c.kind == .server) return null;
    if (eql(o, "-peername")) {
        const n = sys.peerName(c.fd) orelse return it.fail("can't get peername: socket is not connected", .{});
        return try nameList(it, n);
    }
    if (eql(o, "-error")) {
        if (c.connecting) chan.progress(it, c);
        if (c.fail == null and !c.connecting) c.fail = sys.connectError(c.fd);
        const f = c.fail orelse return Value.empty;
        c.fail = null;
        return .{ .str = f.text };
    }
    if (eql(o, "-connecting")) return .{ .int = @intFromBool(c.connecting) };
    return null;
}

/// Adds the socket options to the list of `fconfigure`.
pub fn options(it: *Interp, c: *chan.Channel, out: *std.ArrayList(Value)) Error!void {
    const a = it.alloc();
    if (c.kind == .socket) {
        if (sys.peerName(c.fd)) |n| {
            try out.append(a, .{ .str = "-peername" });
            try out.append(a, try nameList(it, n));
        }
    }
    if (sys.sockName(c.fd)) |n| {
        try out.append(a, .{ .str = "-sockname" });
        try out.append(a, try nameList(it, n));
    }
}

fn port(it: *Interp, v: Value) Error!u16 {
    const n = v.asInt() orelse return it.fail("expected integer but got \"{s}\"", .{try it.str(v)});
    if (n < 0 or n > 65535) return it.fail("couldn't open socket: port number too high", .{});
    return @intCast(n);
}

const usage = "socket ?-myaddr addr? ?-myport myport? ?-async? host port\" or \"socket -server command ?-myaddr addr? port";

pub fn cmdSocket(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var server: ?[]const u8 = null;
    var my_addr: ?[]const u8 = null;
    var my_port: ?Value = null;
    var is_async = false;
    const reuse = true;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (o.len == 0 or o[0] != '-') break;
        if (eql(o, "-async")) {
            if (server != null) return it.fail("cannot set -async option for server sockets", .{});
            is_async = true;
        } else if (eql(o, "-myaddr")) {
            i += 1;
            if (i >= argv.len) return it.fail("no argument given for -myaddr option", .{});
            my_addr = try it.str(argv[i]);
        } else if (eql(o, "-myport")) {
            i += 1;
            if (i >= argv.len) return it.fail("no argument given for -myport option", .{});
            my_port = argv[i];
            if (argv[i].asInt() == null) return it.fail("expected integer but got \"{s}\"", .{try it.str(argv[i])});
        } else if (eql(o, "-server")) {
            if (is_async) return it.fail("cannot set -async option for server sockets", .{});
            i += 1;
            if (i >= argv.len) return it.fail("no argument given for -server option", .{});
            server = try it.str(argv[i]);
        } else return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -async, -myaddr, -myport, or -server", .{o});
    }
    const rest = argv[i..];
    const a = it.alloc();
    if (server) |command| {
        if (my_port != null) return it.fail("option -myport is not valid for servers", .{});
        if (rest.len != 1) return it.wrongArgs(usage);
        const kind = loopOf(my_addr orelse "127.0.0.1") orelse return it.fail("couldn't open socket: the address \"{s}\" is not a loopback address", .{my_addr.?});
        const fd = switch (sys.listenLoop(kind, try port(it, rest[0]), reuse)) {
            .fd => |x| x,
            .err => |f| return sysError(it, f, "couldn't open socket: "),
        };
        sys.setBlocking(fd, false);
        const c = try chan.adopt(it, "sock", fd, false, false);
        c.kind = .server;
        c.accept = try a.dupe(u8, command);
        try event.watch(it, c.name);
        if (my_addr == null) {
            // A server with no address listens on both loopback
            // addresses, on one port.
            const bound = sys.sockName(fd);
            if (bound) |b| switch (sys.listenLoop(.v6, b.port, reuse)) {
                .fd => |fd6| {
                    sys.setBlocking(fd6, false);
                    const sib = try chan.adoptHidden(it, fd6);
                    sib.kind = .server;
                    sib.accept = c.accept;
                    c.sibling = sib;
                    try event.watch(it, sib.name);
                },
                .err => {},
            };
        }
        return .{ .str = c.name };
    }
    if (rest.len != 2) return it.wrongArgs(usage);
    const host = try it.str(rest[0]);
    const p = try port(it, rest[1]);
    const mine: u16 = if (my_port) |v| try port(it, v) else 0;
    const kind = loopOf(host) orelse return it.fail("couldn't open socket: the host \"{s}\" is not a loopback address", .{host});
    if (my_addr) |m| {
        if (loopOf(m) == null) return it.fail("couldn't open socket: the address \"{s}\" is not a loopback address", .{m});
    }
    const fd = switch (sys.connectLoop(kind, p, mine, !is_async)) {
        .fd => |x| x,
        .err => |f| return sysError(it, f, "couldn't open socket: "),
    };
    const c = try chan.adopt(it, "sock", fd, true, true);
    c.kind = .socket;
    c.connecting = is_async;
    return .{ .str = c.name };
}

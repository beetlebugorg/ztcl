//! The optional `socket` command (capability `socket`).
//!
//! A socket is a channel of `chan.zig` on a TCP connection. The
//! embedder gives a network policy in `Interp.net`:
//!
//! - `loopback` allows 127.0.0.0/8 and ::1. It is the default.
//! - `allow` is a list of rules. A rule has a host name or an address
//!   range, and a port range.
//! - `any` allows each address.
//!
//! `sys.resolve` is the only name lookup. The command checks each
//! address that a name gives before it connects, and it checks the
//! address of the connection again after the connect. A server checks
//! its listening address and each peer, and it closes a peer that the
//! policy does not allow. A child interpreter has the policy of its
//! parent. The event loop of `event.zig` runs the accept command and
//! the `fileevent` scripts.
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

/// One rule of an allowlist. An address matches when it is in the
/// range, or when the script gave the host name of the rule. The port
/// is the remote port of a client and the local port of a server.
pub const Rule = struct {
    host: ?[]const u8 = null,
    net: ?sys.Addr = null,
    /// The count of leading bits of `net` that must match.
    bits: u8 = 0,
    port_lo: u16 = 0,
    port_hi: u16 = 65535,
};

pub const Policy = union(enum) {
    loopback,
    allow: []const Rule,
    any,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// True for 127.0.0.0/8, ::1, and an IPv4 loopback address in the
/// IPv6 form.
pub fn isLoop(n: sys.Addr) bool {
    if (!n.v6) return n.bytes[0] == 127;
    const one = @as([15]u8, @splat(0)) ++ [_]u8{1};
    if (std.mem.eql(u8, &n.bytes, &one)) return true;
    const mapped = @as([10]u8, @splat(0)) ++ [_]u8{ 0xff, 0xff, 127 };
    return std.mem.eql(u8, n.bytes[0..13], &mapped);
}

fn inRange(addr: sys.Addr, net: sys.Addr, bits: u8) bool {
    if (addr.v6 != net.v6) return false;
    const total: u8 = if (addr.v6) 128 else 32;
    const n = @min(bits, total);
    const whole = n / 8;
    if (!std.mem.eql(u8, addr.bytes[0..whole], net.bytes[0..whole])) return false;
    const rest: u3 = @intCast(n % 8);
    if (rest == 0) return true;
    const mask: u8 = @as(u8, 0xff) << @intCast(8 - @as(u4, rest));
    return addr.bytes[whole] & mask == net.bytes[whole] & mask;
}

/// True when the policy allows a connection with this address and
/// port. `host` is the name that the script gave, or null for a peer.
pub fn permits(policy: Policy, addr: sys.Addr, port: u16, host: ?[]const u8) bool {
    switch (policy) {
        .any => return true,
        .loopback => return isLoop(addr),
        .allow => |rules| {
            for (rules) |r| {
                if (port < r.port_lo or port > r.port_hi) continue;
                if (r.net) |net| {
                    if (inRange(addr, net, r.bits)) return true;
                }
                if (r.host) |name| {
                    if (host) |h| if (std.ascii.eqlIgnoreCase(name, h)) return true;
                }
            }
            return false;
        },
    }
}

/// Reads a policy: `loopback`, `any`, or `allow=` and a list of rules
/// with commas between them. A rule is `host`, `address`, or
/// `address/bits`, with an optional `:port` or `:port-port`. An IPv6
/// address is in brackets. Gives null for a bad text.
pub fn parsePolicy(a: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?Policy {
    if (eql(text, "loopback")) return .loopback;
    if (eql(text, "any")) return .any;
    if (!std.mem.startsWith(u8, text, "allow=")) return null;
    var rules: std.ArrayList(Rule) = .empty;
    var items = std.mem.tokenizeScalar(u8, text[6..], ',');
    while (items.next()) |item| {
        var r: Rule = .{};
        var head = item;
        // The port part follows the last colon outside brackets.
        const close = std.mem.lastIndexOfScalar(u8, item, ']');
        if (std.mem.lastIndexOfScalar(u8, item, ':')) |k| {
            if (close == null or k > close.?) {
                if (close != null or std.mem.count(u8, item, ":") == 1) {
                    const ports = item[k + 1 ..];
                    head = item[0..k];
                    const dash = std.mem.indexOfScalar(u8, ports, '-');
                    r.port_lo = std.fmt.parseInt(u16, ports[0 .. dash orelse ports.len], 10) catch return null;
                    r.port_hi = if (dash) |d| std.fmt.parseInt(u16, ports[d + 1 ..], 10) catch return null else r.port_lo;
                }
            }
        }
        var bits: ?u8 = null;
        if (std.mem.lastIndexOfScalar(u8, head, '/')) |k| {
            bits = std.fmt.parseInt(u8, head[k + 1 ..], 10) catch return null;
            head = head[0..k];
        }
        if (head.len >= 2 and head[0] == '[' and head[head.len - 1] == ']') head = head[1 .. head.len - 1];
        if (head.len == 0) return null;
        if (sys.parseAddr(head)) |addr| {
            r.net = addr;
            r.bits = bits orelse if (addr.v6) 128 else 32;
            if (r.bits > (if (addr.v6) @as(u8, 128) else 32)) return null;
        } else {
            if (bits != null) return null;
            r.host = try a.dupe(u8, head);
        }
        try rules.append(a, r);
    }
    return .{ .allow = rules.items };
}

pub fn addrText(it: *Interp, n: sys.Addr) Error![]const u8 {
    const a = it.alloc();
    if (!n.v6) return std.fmt.allocPrint(a, "{d}.{d}.{d}.{d}", .{ n.bytes[0], n.bytes[1], n.bytes[2], n.bytes[3] });
    var groups: [8]u16 = undefined;
    for (0..8) |i| groups[i] = (@as(u16, n.bytes[i * 2]) << 8) | n.bytes[i * 2 + 1];
    // The longest run of zero groups becomes `::`.
    var best: usize = 0;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        var j = i;
        while (j < 8 and groups[j] == 0) j += 1;
        if (j - i > best_len) {
            best = i;
            best_len = j - i;
        }
        i = if (j == i) i + 1 else j;
    }
    var out: std.ArrayList(u8) = .empty;
    i = 0;
    while (i < 8) {
        if (best_len >= 2 and i == best) {
            try out.appendSlice(a, "::");
            i += best_len;
            continue;
        }
        if (out.items.len > 0 and out.items[out.items.len - 1] != ':') try out.append(a, ':');
        try out.print(a, "{x}", .{groups[i]});
        i += 1;
    }
    return out.items;
}

fn sysError(it: *Interp, f: sys.Fail, what: []const u8) Error {
    const code = try std.fmt.allocPrint(it.alloc(), "POSIX {s} {{{s}}}", .{ f.name, f.text });
    return it.failCode(code, "{s}{s}", .{ what, f.text });
}

fn nameList(it: *Interp, n: sys.Addr) Error!Value {
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

fn portOf(it: *Interp, v: Value) Error!u16 {
    const n = v.asInt() orelse return it.fail("expected integer but got \"{s}\"", .{try it.str(v)});
    if (n < 0 or n > 65535) return it.fail("couldn't open socket: port number too high", .{});
    return @intCast(n);
}

const usage = "socket ?-myaddr addr? ?-myport myport? ?-async? host port\" or \"socket -server command ?-myaddr addr? port";

fn denied(it: *Interp, what: []const u8, word: []const u8) Error {
    return it.failCode("ZTCL NET DENIED", "couldn't open socket: the network policy does not allow the {s} \"{s}\"", .{ what, word });
}

/// The addresses of a host word that the policy allows.
fn allowed(it: *Interp, host: []const u8, p: u16, what: []const u8) Error![]sys.Addr {
    const a = it.alloc();
    var found: std.ArrayList(sys.Addr) = .empty;
    try sys.resolve(a, host, &found);
    if (found.items.len == 0) return it.failCode("POSIX ENOENT {host is unknown}", "couldn't open socket: host is unreachable (Name or service not known)", .{});
    var out: std.ArrayList(sys.Addr) = .empty;
    for (found.items) |addr| {
        if (permits(it.net, addr, p, host)) try out.append(a, addr);
    }
    if (out.items.len == 0) return denied(it, what, host);
    return out.items;
}

/// Adds a connection that a server accepted. Gives null and closes it
/// when the policy does not allow the peer.
pub fn acceptable(it: *Interp, server: *chan.Channel, conn: sys.Accepted) bool {
    const local = sys.sockName(server.fd) orelse return false;
    return permits(it.net, conn.peer, local.port, null);
}

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
        const p = try portOf(it, rest[0]);
        // The addresses to listen on. With no address, a loopback
        // policy listens on both loopback addresses, and each other
        // policy listens on all addresses and checks each peer.
        var binds: std.ArrayList(sys.Addr) = .empty;
        if (my_addr) |m| {
            var found: std.ArrayList(sys.Addr) = .empty;
            try sys.resolve(a, m, &found);
            if (found.items.len == 0) return it.fail("couldn't open socket: host is unreachable (Name or service not known)", .{});
            for (found.items) |addr| {
                const wild = std.mem.allEqual(u8, &addr.bytes, 0);
                if (permits(it.net, addr, p, m) or (wild and it.net != .loopback)) try binds.append(a, addr);
            }
            if (binds.items.len == 0) return denied(it, "address", m);
        } else if (it.net == .loopback) {
            try binds.append(a, .{ .bytes = .{ 127, 0, 0, 1 } ++ @as([12]u8, @splat(0)) });
            try binds.append(a, .{ .v6 = true, .bytes = @as([15]u8, @splat(0)) ++ [_]u8{1} });
        } else {
            try binds.append(a, .{});
            try binds.append(a, .{ .v6 = true });
        }
        var first: ?*chan.Channel = null;
        var failure: ?sys.Fail = null;
        var bound_port = p;
        for (binds.items) |addr_in| {
            var addr = addr_in;
            addr.port = bound_port;
            switch (sys.listenAt(addr, reuse)) {
                .fd => |fd| {
                    sys.setBlocking(fd, false);
                    const c = if (first == null) try chan.adopt(it, "sock", fd, false, false) else try chan.adoptHidden(it, fd);
                    c.kind = .server;
                    c.accept = if (first) |f| f.accept else try a.dupe(u8, command);
                    try event.watch(it, c.name);
                    if (first) |f| {
                        // One more address of the same server.
                        c.sibling = f.sibling;
                        f.sibling = c;
                    } else {
                        first = c;
                        if (sys.sockName(fd)) |b| bound_port = b.port;
                    }
                },
                .err => |f| {
                    if (failure == null) failure = f;
                },
            }
            // A server with one address in the command has one socket.
            if (my_addr != null and first != null) break;
        }
        const c = first orelse return sysError(it, failure.?, "couldn't open socket: ");
        return .{ .str = c.name };
    }
    if (rest.len != 2) return it.wrongArgs(usage);
    const host = try it.str(rest[0]);
    const p = try portOf(it, rest[1]);
    var mine: ?sys.Addr = null;
    if (my_port) |v| mine = .{ .port = try portOf(it, v) };
    if (my_addr) |m| {
        var found: std.ArrayList(sys.Addr) = .empty;
        try sys.resolve(a, m, &found);
        if (found.items.len == 0) return it.fail("couldn't open socket: host is unreachable (Name or service not known)", .{});
        // The local address has the same rule as a server address.
        var ok: ?sys.Addr = null;
        for (found.items) |addr| {
            if (permits(it.net, addr, p, m) or it.net == .any) ok = ok orelse addr;
        }
        var local = ok orelse return denied(it, "address", m);
        local.port = if (mine) |x| x.port else 0;
        mine = local;
    }
    const targets = try allowed(it, host, p, "host");
    var failure: ?sys.Fail = null;
    for (targets) |t_in| {
        var t = t_in;
        t.port = p;
        var local = mine;
        if (local) |*l| {
            if (my_addr != null and l.v6 != t.v6) continue;
            l.v6 = t.v6;
        }
        const fd = switch (sys.connectTo(t, local, !is_async)) {
            .fd => |x| x,
            .err => |f| {
                failure = failure orelse f;
                continue;
            },
        };
        // The second check: the address of the connection itself.
        if (!is_async) {
            const peer = sys.peerName(fd);
            if (peer == null or !permits(it.net, peer.?, p, host)) {
                sys.close(fd);
                return denied(it, "host", host);
            }
        }
        const c = try chan.adopt(it, "sock", fd, true, true);
        c.kind = .socket;
        c.connecting = is_async;
        c.peer_host = try a.dupe(u8, host);
        if (@import("meter.zig").of(it)) |m| m.addConnection(host);
        return .{ .str = c.name };
    }
    return sysError(it, failure orelse .{ .name = "EADDRNOTAVAIL", .text = "can't assign requested address" }, "couldn't open socket: ");
}

/// The check of a background connect at its end. Gives false when the
/// policy does not allow the address of the connection.
pub fn checkPeer(it: *Interp, c: *chan.Channel) bool {
    const peer = sys.peerName(c.fd) orelse return true;
    return permits(it.net, peer, peer.port, if (c.peer_host.len > 0) c.peer_host else null);
}

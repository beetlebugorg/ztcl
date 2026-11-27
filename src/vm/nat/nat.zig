//! The user-mode NAT of `ztcl::vm -net nat` (ztcl#461, docs/dev/vm-net.md):
//! the frames of the virtio-net device of a guest go in with
//! `fromGuest`, and the frames to the guest go out through `Host.emit`.
//! The sources are RFC 826 (ARP), RFC 791 (IPv4), RFC 792 (ICMP), RFC 768
//! (UDP), RFC 2131 and RFC 2132 (DHCP), and RFC 1071 (the checksum).
//!
//! The network of the guest is 10.0.2.0/24. The guest is 10.0.2.15, the
//! gateway is 10.0.2.2, and the DNS server of the NAT is 10.0.2.3. The
//! NAT answers ARP for each address of the network other than the
//! guest, gives the guest its address with DHCP, and answers ICMP echo
//! to the gateway and to the DNS address. A UDP datagram of the guest to
//! an address outside the guest goes to `Host.udpSend`: the host sends
//! it from a socket of its own, and `udpToGuest` gives the answer back.
//! TCP comes in the next step of the plan.
//!
//! The checksum adds 32 bytes at a time with a vector of 16 words in
//! the byte order of the host, then swaps the bytes of the folded sum:
//! RFC 1071 shows that the one's complement sum does not depend on the
//! byte order of the words.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

pub const Ip4 = [4]u8;
pub const Mac = [6]u8;

pub const guest_ip: Ip4 = .{ 10, 0, 2, 15 };
pub const gateway_ip: Ip4 = .{ 10, 0, 2, 2 };
pub const dns_ip: Ip4 = .{ 10, 0, 2, 3 };
pub const netmask: Ip4 = .{ 255, 255, 255, 0 };
pub const guest_mac: Mac = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
pub const gateway_mac: Mac = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x02 };
const broadcast_mac: Mac = @splat(0xff);
const lease_seconds: u32 = 86400;

const eth_ip4 = 0x0800;
const eth_arp = 0x0806;
const proto_icmp = 1;
const proto_udp = 17;
const eth_len = 14;
const ip_len = 20;
const udp_len = 8;
/// The largest frame of the NAT: an Ethernet frame of 1514 bytes.
pub const max_frame = 1514;

/// The calls of the NAT to its host.
pub const Host = struct {
    ctx: *anyopaque,
    /// A frame for the guest. The bytes are valid only during the call.
    emit: *const fn (ctx: *anyopaque, frame: []const u8) void,
    /// A UDP datagram of the guest from `sport` to `dst:dport`.
    udpSend: *const fn (ctx: *anyopaque, sport: u16, dst: Ip4, dport: u16, payload: []const u8) void,
};

pub const Stack = struct {
    host: Host,
    /// The counts of the frames that the NAT dropped: bad, or of a kind
    /// that it does not handle.
    dropped: u64 = 0,
    buf: [max_frame]u8 = undefined,

    /// A frame of the guest, from the transmit queue of its device.
    pub fn fromGuest(n: *Stack, f: []const u8) void {
        if (f.len < eth_len) return n.drop();
        switch (be16(f[12..14])) {
            eth_arp => n.arp(f[eth_len..]),
            eth_ip4 => n.ip4(f),
            else => n.drop(),
        }
    }

    /// A UDP datagram of the host for the guest port `dport`, from
    /// `src:sport`.
    pub fn udpToGuest(n: *Stack, src: Ip4, sport: u16, dport: u16, payload: []const u8) void {
        if (payload.len > max_frame - eth_len - ip_len - udp_len) return n.drop();
        n.sendUdp(src, sport, guest_ip, guest_mac, dport, payload);
    }

    fn drop(n: *Stack) void {
        n.dropped += 1;
    }

    fn arp(n: *Stack, a: []const u8) void {
        if (a.len < 28) return n.drop();
        if (be16(a[0..2]) != 1 or be16(a[2..4]) != eth_ip4 or a[4] != 6 or a[5] != 4) return n.drop();
        if (be16(a[6..8]) != 1) return; // only requests need an answer
        const tpa: Ip4 = a[24..28].*;
        if (!inNet(tpa) or std.mem.eql(u8, &tpa, &guest_ip)) return;
        const o = &n.buf;
        @memcpy(o[0..6], a[8..14]);
        @memcpy(o[6..12], &gateway_mac);
        put16(o[12..14], eth_arp);
        const r = o[eth_len..][0..28];
        put16(r[0..2], 1);
        put16(r[2..4], eth_ip4);
        r[4] = 6;
        r[5] = 4;
        put16(r[6..8], 2);
        @memcpy(r[8..14], &gateway_mac);
        @memcpy(r[14..18], &tpa);
        @memcpy(r[18..28], a[8..18]);
        n.host.emit(n.host.ctx, o[0 .. eth_len + 28]);
    }

    fn ip4(n: *Stack, f: []const u8) void {
        const p = f[eth_len..];
        if (p.len < ip_len or p[0] >> 4 != 4) return n.drop();
        const ihl = @as(usize, p[0] & 0xf) * 4;
        const total = be16(p[2..4]);
        if (ihl < ip_len or total < ihl or total > p.len) return n.drop();
        if (be16(p[6..8]) & 0x3fff != 0) return n.drop(); // fragments
        if (checksum(p[0..ihl], 0) != 0) return n.drop();
        const src: Ip4 = p[12..16].*;
        const dst: Ip4 = p[16..20].*;
        const body = p[ihl..total];
        switch (p[9]) {
            proto_icmp => n.icmp(f[6..12].*, src, dst, body),
            proto_udp => n.udp(f[6..12].*, src, dst, body),
            else => n.drop(),
        }
    }

    fn icmp(n: *Stack, mac: Mac, src: Ip4, dst: Ip4, b: []const u8) void {
        if (b.len < 8 or b[0] != 8) return n.drop();
        if (!std.mem.eql(u8, &dst, &gateway_ip) and !std.mem.eql(u8, &dst, &dns_ip)) return n.drop();
        if (b.len > max_frame - eth_len - ip_len) return n.drop();
        if (checksum(b, 0) != 0) return n.drop();
        const o = n.buf[eth_len + ip_len ..][0..b.len];
        @memcpy(o, b);
        o[0] = 0;
        put16(o[2..4], 0);
        put16(o[2..4], checksum(o, 0));
        n.sendIp(dst, src, mac, proto_icmp, b.len);
    }

    fn udp(n: *Stack, mac: Mac, src: Ip4, dst: Ip4, b: []const u8) void {
        if (b.len < udp_len) return n.drop();
        const len = be16(b[4..6]);
        if (len < udp_len or len > b.len) return n.drop();
        const sport = be16(b[0..2]);
        const dport = be16(b[2..4]);
        const payload = b[udp_len..len];
        // The guest may send a zero checksum; an offload of the guest
        // also leaves the checksum to the device. Neither is checked.
        if (dport == 67 and sport == 68) return n.dhcp(mac, payload);
        if (std.mem.eql(u8, &src, &guest_ip) or std.mem.eql(u8, &src, &[4]u8{ 0, 0, 0, 0 })) {
            if (inNet(dst) and !std.mem.eql(u8, &dst, &gateway_ip) and !std.mem.eql(u8, &dst, &dns_ip)) return n.drop();
            n.host.udpSend(n.host.ctx, sport, dst, dport, payload);
        } else n.drop();
    }

    /// DHCP: an offer for a DISCOVER, an ack for a REQUEST.
    fn dhcp(n: *Stack, mac: Mac, d: []const u8) void {
        if (d.len < 240 or d[0] != 1 or be32(d[236..240]) != 0x63825363) return n.drop();
        var kind: u8 = 0;
        var i: usize = 240;
        while (i < d.len and d[i] != 255) {
            if (d[i] == 0) {
                i += 1;
                continue;
            }
            // Each byte is read once: the frame can be in guest memory.
            const code = d[i];
            if (i + 1 >= d.len) return n.drop();
            const olen: usize = d[i + 1];
            if (i + 2 + olen > d.len) return n.drop();
            if (code == 53 and olen == 1) kind = d[i + 2];
            i += 2 + olen;
        }
        const answer: u8 = switch (kind) {
            1 => 2, // DISCOVER: OFFER
            3 => 5, // REQUEST: ACK
            else => return n.drop(),
        };
        var r: [300]u8 = @splat(0);
        r[0] = 2;
        r[1] = 1;
        r[2] = 6;
        @memcpy(r[4..8], d[4..8]); // xid
        @memcpy(r[10..12], d[10..12]); // flags
        @memcpy(r[16..20], &guest_ip); // yiaddr
        @memcpy(r[20..24], &gateway_ip); // siaddr
        @memcpy(r[28..44], d[28..44]); // chaddr
        put32(r[236..240], 0x63825363);
        var o: usize = 240;
        const opts = [_]struct { code: u8, data: []const u8 }{
            .{ .code = 53, .data = &.{answer} },
            .{ .code = 54, .data = &gateway_ip },
            .{ .code = 51, .data = &std.mem.toBytes(std.mem.nativeToBig(u32, lease_seconds)) },
            .{ .code = 1, .data = &netmask },
            .{ .code = 3, .data = &gateway_ip },
            .{ .code = 6, .data = &dns_ip },
        };
        for (opts) |x| {
            r[o] = x.code;
            r[o + 1] = @intCast(x.data.len);
            @memcpy(r[o + 2 ..][0..x.data.len], x.data);
            o += 2 + x.data.len;
        }
        r[o] = 255;
        n.sendUdp(gateway_ip, 67, .{ 255, 255, 255, 255 }, if (be16(d[10..12]) & 0x8000 != 0) broadcast_mac else mac, 68, r[0..300]);
    }

    fn sendUdp(n: *Stack, src: Ip4, sport: u16, dst: Ip4, mac: Mac, dport: u16, payload: []const u8) void {
        const u = n.buf[eth_len + ip_len ..];
        const len = udp_len + payload.len;
        put16(u[0..2], sport);
        put16(u[2..4], dport);
        put16(u[4..6], @intCast(len));
        put16(u[6..8], 0);
        @memcpy(u[udp_len..len], payload);
        var c = checksum(u[0..len], pseudo(src, dst, proto_udp, len));
        if (c == 0) c = 0xffff;
        put16(u[6..8], c);
        n.sendIp(src, dst, mac, proto_udp, len);
    }

    /// Writes the Ethernet and IPv4 headers in front of `len` bytes at
    /// `buf[34..]`, and gives the frame to the host.
    fn sendIp(n: *Stack, src: Ip4, dst: Ip4, mac: Mac, proto: u8, len: usize) void {
        const o = &n.buf;
        @memcpy(o[0..6], &mac);
        @memcpy(o[6..12], &gateway_mac);
        put16(o[12..14], eth_ip4);
        const h = o[eth_len..][0..ip_len];
        h[0] = 0x45;
        h[1] = 0;
        put16(h[2..4], @intCast(ip_len + len));
        put16(h[4..6], 0);
        put16(h[6..8], 0x4000); // don't fragment
        h[8] = 64;
        h[9] = proto;
        put16(h[10..12], 0);
        @memcpy(h[12..16], &src);
        @memcpy(h[16..20], &dst);
        put16(h[10..12], checksum(h, 0));
        n.host.emit(n.host.ctx, o[0 .. eth_len + ip_len + len]);
    }
};

fn inNet(a: Ip4) bool {
    return a[0] == 10 and a[1] == 0 and a[2] == 2;
}

fn be16(b: *const [2]u8) u16 {
    return std.mem.readInt(u16, b, .big);
}
fn be32(b: *const [4]u8) u32 {
    return std.mem.readInt(u32, b, .big);
}
fn put16(b: *[2]u8, v: u16) void {
    std.mem.writeInt(u16, b, v, .big);
}
fn put32(b: *[4]u8, v: u32) void {
    std.mem.writeInt(u32, b, v, .big);
}

/// The sum of the pseudo-header of UDP and TCP, in the byte order of the
/// network, for `checksum`.
pub fn pseudo(src: Ip4, dst: Ip4, proto: u8, len: usize) u32 {
    return @as(u32, be16(src[0..2])) + be16(src[2..4]) + be16(dst[0..2]) + be16(dst[2..4]) + proto + @as(u32, @intCast(len));
}

/// The Internet checksum (RFC 1071) of `b`, with `start` (a sum in the
/// byte order of the network, such as `pseudo`) added. A packet with a
/// correct checksum in it gives 0.
pub fn checksum(b: []const u8, start: u32) u16 {
    const V = @Vector(16, u16);
    const W = @Vector(16, u32);
    var acc: W = @splat(0);
    var i: usize = 0;
    // Each lane adds at most 0xffff for each 32 bytes: 65,536 rounds fit
    // in a u32 lane, more than 2 MB of input.
    while (i + 32 <= b.len) : (i += 32) {
        const v: V = @bitCast(b[i..][0..32].*);
        acc += @as(W, v);
    }
    var s: u64 = @reduce(.Add, @as(@Vector(16, u64), acc));
    while (i + 2 <= b.len) : (i += 2) s += std.mem.readInt(u16, b[i..][0..2], .little);
    if (i < b.len) s += b[i];
    while (s >> 16 != 0) s = (s & 0xffff) + (s >> 16);
    // The words were added in the byte order of the host.
    var net: u32 = if (@import("builtin").cpu.arch.endian() == .little) @byteSwap(@as(u16, @intCast(s))) else @intCast(s);
    net += start;
    while (net >> 16 != 0) net = (net & 0xffff) + (net >> 16);
    return ~@as(u16, @intCast(net));
}

// ---------------------------------------------------------------------
// Tests

const Fake = struct {
    out: [8][max_frame]u8 = undefined,
    lens: [8]usize = @splat(0),
    n: usize = 0,
    udp_dst: Ip4 = @splat(0),
    udp_port: u16 = 0,
    udp_data: [64]u8 = undefined,
    udp_len: usize = 0,

    fn emit(ctx: *anyopaque, f: []const u8) void {
        const x: *Fake = @ptrCast(@alignCast(ctx));
        @memcpy(x.out[x.n][0..f.len], f);
        x.lens[x.n] = f.len;
        x.n += 1;
    }
    fn udpSend(ctx: *anyopaque, _: u16, dst: Ip4, dport: u16, p: []const u8) void {
        const x: *Fake = @ptrCast(@alignCast(ctx));
        x.udp_dst = dst;
        x.udp_port = dport;
        @memcpy(x.udp_data[0..p.len], p);
        x.udp_len = p.len;
    }
    fn nat(x: *Fake) Stack {
        return .{ .host = .{ .ctx = x, .emit = emit, .udpSend = udpSend } };
    }
    fn last(x: *Fake) []const u8 {
        return x.out[x.n - 1][0..x.lens[x.n - 1]];
    }
};

/// A frame of the guest: Ethernet, IPv4, and `body` of `proto`.
fn guestFrame(buf: []u8, dst: Ip4, proto: u8, body: []const u8) []u8 {
    @memcpy(buf[0..6], &gateway_mac);
    @memcpy(buf[6..12], &guest_mac);
    put16(buf[12..14], eth_ip4);
    const h = buf[eth_len..][0..ip_len];
    @memset(h, 0);
    h[0] = 0x45;
    put16(h[2..4], @intCast(ip_len + body.len));
    h[8] = 64;
    h[9] = proto;
    @memcpy(h[12..16], &guest_ip);
    @memcpy(h[16..20], &dst);
    put16(h[10..12], checksum(h, 0));
    @memcpy(buf[eth_len + ip_len ..][0..body.len], body);
    return buf[0 .. eth_len + ip_len + body.len];
}

test "nat: the checksum of RFC 1071" {
    // The example of RFC 1071, section 3: the sum is ddf2, so the
    // checksum is 220d.
    try std.testing.expectEqual(@as(u16, 0x220d), checksum(&.{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 }, 0));
    // The vector path and the word path agree, at each length.
    var b: [200]u8 = undefined;
    for (&b, 0..) |*x, i| x.* = @truncate(i *% 37 +% 11);
    for (0..b.len) |len| {
        var s: u32 = 0;
        var i: usize = 0;
        while (i + 1 < len) : (i += 2) s += be16(b[i..][0..2]);
        if (len % 2 == 1) s += @as(u32, b[len - 1]) << 8;
        while (s >> 16 != 0) s = (s & 0xffff) + (s >> 16);
        try std.testing.expectEqual(~@as(u16, @intCast(s)), checksum(b[0..len], 0));
    }
}

test "nat: ARP for the gateway" {
    var x: Fake = .{};
    var n = x.nat();
    var f: [42]u8 = @splat(0);
    @memcpy(f[0..6], &broadcast_mac);
    @memcpy(f[6..12], &guest_mac);
    put16(f[12..14], eth_arp);
    const a = f[14..];
    put16(a[0..2], 1);
    put16(a[2..4], eth_ip4);
    a[4] = 6;
    a[5] = 4;
    put16(a[6..8], 1);
    @memcpy(a[8..14], &guest_mac);
    @memcpy(a[14..18], &guest_ip);
    @memcpy(a[24..28], &gateway_ip);
    n.fromGuest(&f);
    try std.testing.expectEqual(@as(usize, 1), x.n);
    const r = x.last();
    try std.testing.expectEqualSlices(u8, &guest_mac, r[0..6]);
    try std.testing.expectEqual(@as(u16, 2), be16(r[20..22]));
    try std.testing.expectEqualSlices(u8, &gateway_mac, r[22..28]);
    try std.testing.expectEqualSlices(u8, &gateway_ip, r[28..32]);
    // No answer for the address of the guest itself.
    @memcpy(a[24..28], &guest_ip);
    n.fromGuest(&f);
    try std.testing.expectEqual(@as(usize, 1), x.n);
}

test "nat: DHCP offer and ack" {
    var x: Fake = .{};
    var n = x.nat();
    var d: [244]u8 = @splat(0);
    d[0] = 1;
    d[1] = 1;
    d[2] = 6;
    put32(d[4..8], 0x11223344);
    @memcpy(d[28..34], &guest_mac);
    put32(d[236..240], 0x63825363);
    for ([_]struct { kind: u8, answer: u8 }{ .{ .kind = 1, .answer = 2 }, .{ .kind = 3, .answer = 5 } }) |c| {
        d[240] = 53;
        d[241] = 1;
        d[242] = c.kind;
        d[243] = 255;
        var u: [8 + d.len]u8 = undefined;
        put16(u[0..2], 68);
        put16(u[2..4], 67);
        put16(u[4..6], u.len);
        put16(u[6..8], 0);
        @memcpy(u[8..], &d);
        var buf: [max_frame]u8 = undefined;
        // A client with no address yet sends from 0.0.0.0 to the
        // broadcast address.
        const f = guestFrame(&buf, .{ 255, 255, 255, 255 }, proto_udp, &u);
        @memset(f[eth_len + 12 ..][0..4], 0);
        put16(f[eth_len + 10 ..][0..2], 0);
        put16(f[eth_len + 10 ..][0..2], checksum(f[eth_len..][0..ip_len], 0));
        n.fromGuest(f);
        const r = x.last();
        const ip = r[eth_len..];
        try std.testing.expectEqual(@as(u16, 0), checksum(ip[0..ip_len], 0));
        const b = ip[ip_len + udp_len ..];
        try std.testing.expectEqual(@as(u32, 0x11223344), be32(b[4..8]));
        try std.testing.expectEqualSlices(u8, &guest_ip, b[16..20]);
        try std.testing.expectEqual(@as(u8, 53), b[240]);
        try std.testing.expectEqual(c.answer, b[242]);
        try std.testing.expectEqual(@as(u16, 0), checksum(ip[ip_len .. ip_len + udp_len + 300], pseudo(gateway_ip, .{ 255, 255, 255, 255 }, proto_udp, udp_len + 300)));
    }
    try std.testing.expectEqual(@as(usize, 2), x.n);
}

test "nat: ICMP echo to the gateway" {
    var x: Fake = .{};
    var n = x.nat();
    var e: [12]u8 = .{ 8, 0, 0, 0, 0x12, 0x34, 0, 1, 'p', 'i', 'n', 'g' };
    put16(e[2..4], checksum(&e, 0));
    var buf: [max_frame]u8 = undefined;
    n.fromGuest(guestFrame(&buf, gateway_ip, proto_icmp, &e));
    try std.testing.expectEqual(@as(usize, 1), x.n);
    const r = x.last()[eth_len..];
    try std.testing.expectEqualSlices(u8, &gateway_ip, r[12..16]);
    try std.testing.expectEqualSlices(u8, &guest_ip, r[16..20]);
    try std.testing.expectEqual(@as(u8, 0), r[ip_len]);
    try std.testing.expectEqual(@as(u16, 0), checksum(r[ip_len..][0..e.len], 0));
    try std.testing.expectEqualStrings("ping", r[ip_len + 8 ..][0..4]);
}

test "nat: UDP out and back" {
    var x: Fake = .{};
    var n = x.nat();
    var u: [12]u8 = undefined;
    put16(u[0..2], 40000);
    put16(u[2..4], 53);
    put16(u[4..6], 12);
    put16(u[6..8], 0);
    @memcpy(u[8..12], "abcd");
    var buf: [max_frame]u8 = undefined;
    n.fromGuest(guestFrame(&buf, .{ 192, 0, 2, 9 }, proto_udp, &u));
    try std.testing.expectEqual(@as(u16, 53), x.udp_port);
    try std.testing.expectEqualSlices(u8, &[4]u8{ 192, 0, 2, 9 }, &x.udp_dst);
    try std.testing.expectEqualStrings("abcd", x.udp_data[0..x.udp_len]);
    // A datagram to another address of the guest network goes nowhere.
    x.udp_len = 0;
    n.fromGuest(guestFrame(&buf, .{ 10, 0, 2, 77 }, proto_udp, &u));
    try std.testing.expectEqual(@as(usize, 0), x.udp_len);
    n.udpToGuest(.{ 192, 0, 2, 9 }, 53, 40000, "answer");
    const r = x.last()[eth_len..];
    try std.testing.expectEqualSlices(u8, &guest_ip, r[16..20]);
    try std.testing.expectEqual(@as(u16, 40000), be16(r[ip_len + 2 ..][0..2]));
    try std.testing.expectEqualStrings("answer", r[ip_len + udp_len ..][0..6]);
    try std.testing.expectEqual(@as(u16, 0), checksum(r[ip_len..][0 .. udp_len + 6], pseudo(.{ 192, 0, 2, 9 }, guest_ip, proto_udp, udp_len + 6)));
}

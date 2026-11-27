//! The allow and deny lists of one guest of `-net nat` (docs/dev/vm-net.md,
//! the policy). The lists narrow the network policy of the embedder; they
//! never widen it.
//!
//! - A rule is an address range (`10.0.0.0/8`), an address, a host name,
//!   or a pattern `*.SUFFIX`, each with an optional port or port range.
//! - A deny rule wins. With an allow list, a host address must match an
//!   allow rule; with no allow list, each address that the embedder
//!   permits is allowed.
//! - A host name matches in two places: in the DNS query of the guest,
//!   and in the addresses of the answer to an allowed query. The engine
//!   reads the A records of each answer and keeps each address with its
//!   name until its TTL ends (`learn`). A connection to that address then
//!   matches the rule of the name, and the embedder gets the name too.
//!
//! The engine checks the lists once for each new flow or connection, not
//! for each packet. The address rules are sorted by their first address,
//! and a lookup is a binary search for the rules that can contain the
//! address, then a scan of those.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const nat = @import("nat.zig");

const Ip4 = nat.Ip4;

pub const Rule = struct {
    /// A host name or a pattern `*.SUFFIX`; or null for an address range.
    host: ?[]const u8 = null,
    net: Ip4 = @splat(0),
    bits: u6 = 32,
    port_lo: u16 = 0,
    port_hi: u16 = 65535,
};

const Range = struct {
    lo: u32,
    hi: u32,
    port_lo: u16,
    port_hi: u16,
    /// The index of the rule in its list.
    rule: u16,
};

/// One list: the address ranges, sorted, and the names.
const List = struct {
    ranges: []Range = &.{},
    /// The largest `hi` of `ranges[0..i+1]`, for the search.
    max_hi: []u32 = &.{},
    names: []Rule = &.{},
    name_rule: []u16 = &.{},
    len: usize = 0,

    fn init(alloc: std.mem.Allocator, rules: []const Rule) !List {
        var l: List = .{ .len = rules.len };
        var nr: usize = 0;
        var nn: usize = 0;
        for (rules) |r| {
            if (r.host == null) nr += 1 else nn += 1;
        }
        l.ranges = try alloc.alloc(Range, nr);
        l.max_hi = try alloc.alloc(u32, nr);
        l.names = try alloc.alloc(Rule, nn);
        l.name_rule = try alloc.alloc(u16, nn);
        var i: usize = 0;
        var j: usize = 0;
        for (rules, 0..) |r, k| {
            if (r.host) |h| {
                l.names[j] = r;
                l.names[j].host = try alloc.dupe(u8, h);
                l.name_rule[j] = @intCast(k);
                j += 1;
                continue;
            }
            const a = std.mem.readInt(u32, &r.net, .big);
            const mask: u32 = if (r.bits == 0) 0 else ~@as(u32, 0) << @intCast(32 - @as(u7, r.bits));
            l.ranges[i] = .{ .lo = a & mask, .hi = (a & mask) | ~mask, .port_lo = r.port_lo, .port_hi = r.port_hi, .rule = @intCast(k) };
            i += 1;
        }
        std.mem.sort(Range, l.ranges, {}, struct {
            fn less(_: void, x: Range, y: Range) bool {
                return x.lo < y.lo;
            }
        }.less);
        var m: u32 = 0;
        for (l.ranges, l.max_hi) |r, *h| {
            m = @max(m, r.hi);
            h.* = m;
        }
        return l;
    }

    fn deinit(l: *List, alloc: std.mem.Allocator) void {
        for (l.names) |r| alloc.free(r.host.?);
        alloc.free(l.ranges);
        alloc.free(l.max_hi);
        alloc.free(l.names);
        alloc.free(l.name_rule);
    }

    /// The first rule (by index) whose range holds `a` and `port`.
    fn matchAddr(l: *const List, a: u32, port: u16) ?u16 {
        // The ranges with lo <= a are ranges[0..end].
        var lo: usize = 0;
        var hi: usize = l.ranges.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (l.ranges[mid].lo <= a) lo = mid + 1 else hi = mid;
        }
        var best: ?u16 = null;
        var i = lo;
        // Back from the last candidate while a range before can still
        // reach `a`.
        while (i > 0) {
            i -= 1;
            if (l.max_hi[i] < a) break;
            const r = l.ranges[i];
            if (r.hi >= a and port >= r.port_lo and port <= r.port_hi) {
                if (best == null or r.rule < best.?) best = r.rule;
            }
        }
        return best;
    }

    /// The first name rule that matches `name`, with any port.
    fn matchName(l: *const List, name: []const u8) ?usize {
        for (l.names, 0..) |r, i| if (nameMatch(r.host.?, name)) return i;
        return null;
    }
};

/// A name matches a host of a list: the same name, or a pattern
/// `*.SUFFIX` and a name below SUFFIX. Case does not matter.
pub fn nameMatch(pattern: []const u8, name: []const u8) bool {
    var p = pattern;
    if (p.len > 0 and p[p.len - 1] == '.') p = p[0 .. p.len - 1];
    if (std.mem.startsWith(u8, p, "*.")) {
        const suf = p[1..];
        return name.len > suf.len and std.ascii.endsWithIgnoreCase(name, suf);
    }
    return std.ascii.eqlIgnoreCase(p, name);
}

/// An address from a DNS answer, with its name.
const Learned = struct {
    addr: u32 = 0,
    until: u64 = 0,
    name: [253]u8 = undefined,
    name_len: u8 = 0,
};

pub const Decision = union(enum) {
    allow,
    /// Not on the allow list.
    not_allowed,
    /// The index of the deny rule.
    deny: u16,
};

pub const Policy = struct {
    alloc: std.mem.Allocator,
    allow: List = .{},
    deny: List = .{},
    learned: [max_learned]Learned = @splat(.{}),
    next: usize = 0,

    pub const max_learned = 256;
    const ttl_min: u64 = 30;
    const ttl_max: u64 = 3600;

    pub fn init(alloc: std.mem.Allocator, allow: []const Rule, deny: []const Rule) !*Policy {
        const p = try alloc.create(Policy);
        errdefer alloc.destroy(p);
        p.* = .{ .alloc = alloc };
        p.allow = try List.init(alloc, allow);
        p.deny = try List.init(alloc, deny);
        return p;
    }

    pub fn deinit(p: *Policy) void {
        p.allow.deinit(p.alloc);
        p.deny.deinit(p.alloc);
        p.alloc.destroy(p);
    }

    /// The name of a learned address, while its TTL lasts.
    pub fn nameOf(p: *const Policy, addr: Ip4, now_ns: u64) ?[]const u8 {
        const a = std.mem.readInt(u32, &addr, .big);
        for (&p.learned) |*l| if (l.addr == a and l.until > now_ns) return l.name[0..l.name_len];
        return null;
    }

    /// A host address and port: the deny list, then the allow list, by
    /// address and by the name that the address came from.
    pub fn check(p: *const Policy, addr: Ip4, port: u16, now_ns: u64) Decision {
        const a = std.mem.readInt(u32, &addr, .big);
        const name = p.nameOf(addr, now_ns);
        var deny: ?u16 = p.deny.matchAddr(a, port);
        if (name) |nm| if (p.deny.matchName(nm)) |i| {
            const r = p.deny.names[i];
            if (port >= r.port_lo and port <= r.port_hi) {
                const k = p.deny.name_rule[i];
                if (deny == null or k < deny.?) deny = k;
            }
        };
        if (deny) |k| return .{ .deny = k };
        if (p.allow.len == 0) return .allow;
        if (p.allow.matchAddr(a, port) != null) return .allow;
        if (name) |nm| if (p.allow.matchName(nm)) |i| {
            const r = p.allow.names[i];
            if (port >= r.port_lo and port <= r.port_hi) return .allow;
        };
        return .not_allowed;
    }

    /// A DNS name of a query: a deny name refuses it, and with an allow
    /// list, the name must match a name of it.
    pub fn checkName(p: *const Policy, name: []const u8) Decision {
        if (p.deny.matchName(name)) |i| return .{ .deny = p.deny.name_rule[i] };
        if (p.allow.len == 0 or p.allow.matchName(name) != null) return .allow;
        return .not_allowed;
    }

    /// Keeps an address of the answer to a query for `name`.
    pub fn learn(p: *Policy, name: []const u8, addr: Ip4, ttl: u32, now_ns: u64) void {
        const a = std.mem.readInt(u32, &addr, .big);
        const t = std.math.clamp(@as(u64, ttl), ttl_min, ttl_max) * std.time.ns_per_s;
        // The same address, or a free slot, or else the next slot in
        // turn.
        var found: ?*Learned = null;
        for (&p.learned) |*l| {
            if (l.addr == a or l.until <= now_ns) {
                found = l;
                break;
            }
        }
        const slot = found orelse blk: {
            const x = &p.learned[p.next];
            p.next = (p.next + 1) % max_learned;
            break :blk x;
        };
        const k = @min(name.len, slot.name.len);
        slot.addr = a;
        slot.until = now_ns + t;
        @memcpy(slot.name[0..k], name[0..k]);
        slot.name_len = @intCast(k);
    }
};

/// The A records of a DNS answer (RFC 1035 4.1): calls `f(addr, ttl)`
/// for each. A bad message gives no call.
pub fn answers(m: []const u8, ctx: anytype, f: fn (@TypeOf(ctx), Ip4, u32) void) void {
    if (m.len < 12 or m[2] & 0x80 == 0 or m[3] & 0x0f != 0) return;
    const qd = std.mem.readInt(u16, m[4..6], .big);
    const an = std.mem.readInt(u16, m[6..8], .big);
    var i: usize = 12;
    for (0..qd) |_| {
        i = skipName(m, i) orelse return;
        i += 4;
    }
    for (0..an) |_| {
        i = skipName(m, i) orelse return;
        if (i + 10 > m.len) return;
        const ty = std.mem.readInt(u16, m[i..][0..2], .big);
        const class = std.mem.readInt(u16, m[i + 2 ..][0..2], .big);
        const ttl = std.mem.readInt(u32, m[i + 4 ..][0..4], .big);
        const len = std.mem.readInt(u16, m[i + 8 ..][0..2], .big);
        i += 10;
        if (i + len > m.len) return;
        if (ty == 1 and class == 1 and len == 4) f(ctx, m[i..][0..4].*, ttl);
        i += len;
    }
}

/// The offset after a name at `i`: labels, then a 0 or a pointer.
fn skipName(m: []const u8, start: usize) ?usize {
    var i = start;
    while (i < m.len) {
        const l = m[i];
        if (l == 0) return i + 1;
        if (l & 0xc0 == 0xc0) return if (i + 2 <= m.len) i + 2 else null;
        if (l > 63) return null;
        i += 1 + l;
    }
    return null;
}

// ---------------------------------------------------------------------
// Tests

test "policy: deny wins, and an allow list narrows" {
    const a = std.testing.allocator;
    const p = try Policy.init(a, &.{
        .{ .net = .{ 10, 0, 0, 0 }, .bits = 8 },
        .{ .net = .{ 127, 0, 0, 1 }, .port_lo = 8000, .port_hi = 8999 },
        .{ .host = "*.ok.test", .port_lo = 443, .port_hi = 443 },
    }, &.{
        .{ .net = .{ 10, 9, 0, 0 }, .bits = 16 },
    });
    defer p.deinit();
    try std.testing.expectEqual(Decision.allow, p.check(.{ 10, 1, 2, 3 }, 22, 0));
    try std.testing.expectEqual(Decision{ .deny = 0 }, p.check(.{ 10, 9, 1, 1 }, 22, 0));
    try std.testing.expectEqual(Decision.allow, p.check(.{ 127, 0, 0, 1 }, 8080, 0));
    try std.testing.expectEqual(Decision.not_allowed, p.check(.{ 127, 0, 0, 1 }, 22, 0));
    try std.testing.expectEqual(Decision.not_allowed, p.check(.{ 192, 0, 2, 7 }, 443, 0));
    // An address of an answer for an allowed name.
    p.learn("www.ok.test", .{ 192, 0, 2, 7 }, 60, 0);
    try std.testing.expectEqual(Decision.allow, p.check(.{ 192, 0, 2, 7 }, 443, 1));
    try std.testing.expectEqual(Decision.not_allowed, p.check(.{ 192, 0, 2, 7 }, 80, 1));
    // The TTL ends.
    try std.testing.expectEqual(Decision.not_allowed, p.check(.{ 192, 0, 2, 7 }, 443, 61 * std.time.ns_per_s));
    try std.testing.expectEqual(Decision.allow, p.checkName("a.ok.test"));
    try std.testing.expectEqual(Decision.not_allowed, p.checkName("evil.test"));
}

test "policy: no allow list, and the search of overlapping ranges" {
    const a = std.testing.allocator;
    const p = try Policy.init(a, &.{}, &.{
        .{ .net = .{ 0, 0, 0, 0 }, .bits = 0, .port_lo = 25, .port_hi = 25 },
        .{ .net = .{ 192, 168, 0, 0 }, .bits = 16 },
        .{ .net = .{ 192, 168, 4, 0 }, .bits = 24 },
        .{ .host = "bad.test" },
    });
    defer p.deinit();
    try std.testing.expectEqual(Decision.allow, p.check(.{ 8, 8, 8, 8 }, 53, 0));
    try std.testing.expectEqual(Decision{ .deny = 0 }, p.check(.{ 8, 8, 8, 8 }, 25, 0));
    try std.testing.expectEqual(Decision{ .deny = 1 }, p.check(.{ 192, 168, 4, 9 }, 80, 0));
    try std.testing.expectEqual(Decision{ .deny = 3 }, p.checkName("BAD.test"));
}

test "policy: the A records of an answer" {
    // An answer for a.test: a CNAME, then an A record, with pointers.
    const m = [_]u8{
        0,    1,   0x81, 0x80, 0,   1,   0,   2, 0, 0,  0, 0,
        1,    'a', 4,    't',  'e', 's', 't', 0, 0, 1,  0, 1,
        0xc0, 12,  0,    5,    0,   1,   0,   0, 0, 60, 0, 2,
        0xc0, 12,  0xc0, 12,   0,   1,   0,   1, 0, 0,  1, 0,
        0,    4,   192,  0,    2,   9,
    };
    const S = struct {
        n: u32 = 0,
        addr: Ip4 = @splat(0),
        ttl: u32 = 0,
        fn got(s: *@This(), a: Ip4, t: u32) void {
            s.n += 1;
            s.addr = a;
            s.ttl = t;
        }
    };
    var s: S = .{};
    answers(&m, &s, S.got);
    try std.testing.expectEqual(@as(u32, 1), s.n);
    try std.testing.expectEqual(Ip4{ 192, 0, 2, 9 }, s.addr);
    try std.testing.expectEqual(@as(u32, 256), s.ttl);
}

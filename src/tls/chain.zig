//! The checks of a certificate chain (RFC 5280 section 6) for TLS.
//!
//! `verify` builds a path from the leaf to a trust anchor through the
//! certificates of the peer, and checks the path:
//!
//! - Each signature, with `crypto.verifyCert` on the key of the issuer.
//! - The dates of each certificate, the anchor too.
//! - Each issuer that is not an anchor has `basicConstraints` with the
//!   cA flag, and `keyCertSign` when it has `keyUsage`. A path length
//!   limits the count of the certificates below it that are not
//!   self-issued, the leaf not counted.
//! - A critical extension that the parse does not know ends the path.
//! - The extended key usage: the leaf has `serverAuth` (or `clientAuth`
//!   for a client) when it has the extension. An issuer with the
//!   extension has the same purpose or `anyExtendedKeyUsage`.
//! - The name constraints of each issuer and of the anchor, on the DNS
//!   names, the IP addresses, and the subject of each certificate below
//!   it. A constraint on a kind of name that this code does not check
//!   (email, URI, and others) ends the path when a certificate below it
//!   has a name of that kind.
//! - The host name against the DNS and IP names of the subject
//!   alternative names of the leaf (RFC 6125). The common name is not
//!   read. A wildcard is the whole first label, and matches one label.
//!
//! The search tries each issuer with the right subject, the anchors
//! first, to a depth of `max_depth` certificates. The count of
//! signature checks has a limit, so a peer cannot make the search run
//! for a long time.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const der = @import("der.zig");
const x509 = @import("x509.zig");
const tcrypto = @import("crypto.zig");
const Cert = x509.Cert;

pub const Error = error{
    BadCertificate,
    Unsupported,
    UnknownIssuer,
    Expired,
    BadSignature,
    NotCa,
    PathLength,
    BadUsage,
    NameConstraint,
    UnknownCritical,
    HostName,
    TooManyCertificates,
    TooMuchWork,
};

pub const Usage = enum { server, client };

pub const Options = struct {
    /// Seconds since 1970.
    now: i64,
    /// A DNS name or an IP address in text, or null for no check.
    host: ?[]const u8 = null,
    usage: Usage = .server,
    /// The most intermediates in the path that are not self-issued.
    /// The path has at most `max_path` certificates.
    max_depth: usize = 8,
    /// The most intermediates for the search.
    max_intermediates: usize = 16,
    /// The limit of signature checks for each call.
    max_signatures: usize = 64,
    /// The limit of the compares of a name with a name constraint.
    max_name_checks: usize = 1 << 16,
};

pub const max_path = 16;

const Ctx = struct {
    opts: Options,
    anchors: []const Cert,
    inter: []const Cert,
    path: [max_path]*const Cert = undefined,
    budget: usize,
    name_budget: usize,
    /// The error of the deepest path, for the result of a failed search.
    err: Error = error.UnknownIssuer,
};

/// Checks the leaf and the chain. `intermediates` are the other
/// certificates of the peer, in any order. `anchors` are the trust
/// anchors.
pub fn verify(leaf: *const Cert, intermediates: []const Cert, anchors: []const Cert, opts: Options) Error!void {
    if (intermediates.len > opts.max_intermediates) return error.TooManyCertificates;
    var ctx: Ctx = .{
        .opts = opts,
        .anchors = anchors,
        .inter = intermediates,
        .budget = opts.max_signatures,
        .name_budget = opts.max_name_checks,
    };
    try checkLeaf(leaf, opts);
    ctx.path[0] = leaf;
    return search(&ctx, 0);
}

/// The checks of the leaf alone.
fn checkLeaf(leaf: *const Cert, opts: Options) Error!void {
    try checkDates(leaf, opts.now);
    if (leaf.unknown_critical) return error.UnknownCritical;
    // RFC 5280 section 4.1.2.2: the serial number is positive.
    if (leaf.serial.len == 1 and leaf.serial[0] == 0) return error.BadCertificate;
    // A CA certificate is not a leaf, and name constraints are for CA
    // certificates only (RFC 5280 sections 4.2.1.9 and 4.2.1.10).
    if (leaf.is_ca or leaf.permitted != null or leaf.excluded != null) return error.BadUsage;
    if (leaf.key_usage) |ku| if (ku & x509.key_usage.key_cert_sign != 0) return error.BadUsage;
    // The extended key usage has the purpose, and no anyExtendedKeyUsage
    // and no critical flag (CA/Browser Forum 7.1.2.7.6).
    if (leaf.eku.present) {
        const ok = switch (opts.usage) {
            .server => leaf.eku.server,
            .client => leaf.eku.client,
        };
        if (!ok or leaf.eku.any or leaf.critical.contains(.ext_key_usage)) return error.BadUsage;
    }
    // RFC 5280 section 4.2.1.6: with an empty subject, the subject
    // alternative names are critical.
    if (leaf.san != null and isEmptyName(leaf.subject) and !leaf.critical.contains(.subject_alt_name)) return error.BadCertificate;
    if (leaf.san) |san| {
        var r = der.Reader.init(san);
        while (!r.done()) {
            const g = r.next() catch return error.BadCertificate;
            if (g.tag == 0x82 and !validDns(g.body, true)) return error.BadCertificate;
        }
    }
    // An RSA key for TLS 1.3 signatures: 2048 to 4096 bits, a multiple
    // of 8.
    const kind = leaf.key_kind orelse return error.Unsupported;
    if (kind == .rsa) {
        const k = tcrypto.rsaKey(leaf.key) catch return error.BadCertificate;
        const bits = k.n.bits();
        if (bits < 2048 or bits > 4096 or bits % 8 != 0) return error.BadCertificate;
    }
    if (opts.host) |h| try matchHost(leaf, h);
}

fn isEmptyName(n: []const u8) bool {
    return n.len == 2;
}

/// The LDH syntax of a DNS name (RFC 1034 section 3.5, RFC 5280 section
/// 4.2.1.6): labels of 1 to 63 letters, digits, and hyphens, with no
/// hyphen at the ends. A SAN can have `*.` in front.
fn validDns(name: []const u8, wildcard: bool) bool {
    var n = name;
    if (wildcard and std.mem.startsWith(u8, n, "*.")) n = n[2..];
    if (n.len == 0 or n.len > 253) return false;
    var it = std.mem.splitScalar(u8, n, '.');
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    }
    return true;
}

fn checkDates(c: *const Cert, now: i64) Error!void {
    if (now < c.not_before or now > c.not_after) return error.Expired;
}

fn search(ctx: *Ctx, depth: usize) Error!void {
    const cert = ctx.path[depth];
    for (ctx.anchors) |*a| {
        if (!std.mem.eql(u8, a.subject, cert.issuer)) continue;
        ctx.path[depth + 1] = a;
        if (link(ctx, a, cert, true)) {
            if (checkPath(ctx, depth + 1)) return else |e| ctx.err = e;
        } else |e| {
            if (e == error.TooMuchWork) return e;
            ctx.err = e;
        }
    }
    // The next issuer and its anchor are two more certificates.
    if (depth + 3 > max_path) return error.PathLength;
    var logical: usize = 0;
    for (ctx.path[1 .. depth + 1]) |p| {
        if (!p.selfIssued()) logical += 1;
    }
    next: for (ctx.inter) |*c| {
        if (!std.mem.eql(u8, c.subject, cert.issuer)) continue;
        if (logical + @intFromBool(!c.selfIssued()) > ctx.opts.max_depth) {
            ctx.err = error.PathLength;
            continue;
        }
        for (ctx.path[0 .. depth + 1]) |p| if (p == c or std.mem.eql(u8, p.raw, c.raw)) continue :next;
        if (link(ctx, c, cert, false)) {
            ctx.path[depth + 1] = c;
            if (search(ctx, depth + 1)) return else |e| if (e == error.TooMuchWork) return e;
        } else |e| {
            if (e == error.TooMuchWork) return e;
            ctx.err = e;
        }
    }
    return ctx.err;
}

/// The checks of one issuer of `child`.
fn link(ctx: *Ctx, issuer: *const Cert, child: *const Cert, anchor: bool) Error!void {
    try checkDates(issuer, ctx.opts.now);
    if (issuer.unknown_critical) return error.UnknownCritical;
    if (!issuer.has_bc or !issuer.is_ca or isEmptyName(issuer.subject)) return error.NotCa;
    if (issuer.key_usage) |ku| if (ku & x509.key_usage.key_cert_sign == 0) return error.BadUsage;
    if (!anchor) {
        if (issuer.eku.present and !issuer.eku.any) {
            const ok = switch (ctx.opts.usage) {
                .server => issuer.eku.server,
                .client => issuer.eku.client,
            };
            if (!ok) return error.BadUsage;
        }
    }
    if (ctx.budget == 0) return error.TooMuchWork;
    ctx.budget -= 1;
    const alg = child.sig_alg orelse return error.Unsupported;
    const kind = issuer.key_kind orelse return error.Unsupported;
    tcrypto.verifyCert(alg, kind, issuer.key, child.tbs, child.signature) catch |e| return switch (e) {
        error.Unsupported => error.Unsupported,
        else => error.BadSignature,
    };
}

/// The checks of the whole path `ctx.path[0..top + 1]`, where the last
/// is the anchor.
fn checkPath(ctx: *Ctx, top: usize) Error!void {
    const path = ctx.path[0 .. top + 1];
    for (path[1..], 1..) |ca, k| {
        if (ca.path_len) |limit| {
            var below: usize = 0;
            for (path[1..k]) |c| {
                if (!c.selfIssued()) below += 1;
            }
            if (below > limit) return error.PathLength;
        }
        if (ca.permitted != null or ca.excluded != null) {
            for (path[0..k], 0..) |c, j| {
                // RFC 5280 section 4.2.1.10: a self-issued certificate
                // other than the leaf has no name checks.
                if (j > 0 and c.selfIssued()) continue;
                try checkNames(ctx, ca, c);
            }
        }
    }
}

const Kind = enum { dns, ip, dn, other };

fn kindOf(t: u8) Kind {
    return switch (t) {
        0x82 => .dns,
        0x87 => .ip,
        0xa4 => .dn,
        else => .other,
    };
}

/// The name constraints of `ca` on the names of `c`.
fn checkNames(ctx: *Ctx, ca: *const Cert, c: *const Cert) Error!void {
    // The subject is a directory name of the certificate, when it is
    // not empty.
    const subject_body = (der.one(c.subject, der.tag.sequence) catch return error.BadCertificate).body;
    if (subject_body.len > 0) try checkName(ctx, ca, .dn, subject_body);
    if (c.san) |san| {
        var r = der.Reader.init(san);
        while (!r.done()) {
            const g = r.next() catch return error.BadCertificate;
            const k = kindOf(g.tag);
            const body = if (k == .dn) (der.one(g.body, der.tag.sequence) catch return error.BadCertificate).body else g.body;
            try checkName(ctx, ca, k, body);
        }
    }
}

fn checkName(ctx: *Ctx, ca: *const Cert, k: Kind, name: []const u8) Error!void {
    if (ca.excluded) |ex| {
        var r = der.Reader.init(ex);
        while (!r.done()) {
            const base = try subtreeBase(&r);
            if (kindOf(base.tag) != k) continue;
            if (k == .other) return error.NameConstraint;
            if (try spend(ctx) and try overlaps(k, name, base)) return error.NameConstraint;
        }
    }
    if (ca.permitted) |pm| {
        var any = false;
        var r = der.Reader.init(pm);
        while (!r.done()) {
            const base = try subtreeBase(&r);
            if (kindOf(base.tag) != k) continue;
            if (k == .other) return error.NameConstraint;
            any = true;
            if (try spend(ctx) and try within(k, name, base)) return;
        }
        if (any) return error.NameConstraint;
    }
}

fn spend(ctx: *Ctx) Error!bool {
    if (ctx.name_budget == 0) return error.TooMuchWork;
    ctx.name_budget -= 1;
    return true;
}

/// True when a name of the pattern `name` can be in `base`: for a
/// wildcard DNS name `*.b.c`, the subtree has `b.c`, or is one label
/// on the left of it.
fn overlaps(k: Kind, name: []const u8, base: der.Element) Error!bool {
    if (k == .dns and std.mem.startsWith(u8, name, "*.")) {
        const rest = name[2..];
        const c = try dnsBase(base.body);
        if (dnsWithin(rest, c)) return true;
        const dot = std.mem.indexOfScalar(u8, c, '.') orelse return false;
        return dot > 0 and std.ascii.eqlIgnoreCase(c[dot + 1 ..], rest);
    }
    return within(k, name, base);
}

/// A DNS constraint: an empty one, or a DNS name with no wildcard and
/// no dot in front.
fn dnsBase(c: []const u8) Error![]const u8 {
    if (c.len > 0 and !validDns(c, false)) return error.NameConstraint;
    return c;
}

fn subtreeBase(r: *der.Reader) Error!der.Element {
    var s = r.enter(der.tag.sequence) catch return error.BadCertificate;
    return s.next() catch return error.BadCertificate;
}

/// True when `name` is in the subtree `base` of the same kind.
fn within(k: Kind, name: []const u8, base: der.Element) Error!bool {
    switch (k) {
        .dns => {
            const c = try dnsBase(base.body);
            // The names of a wildcard are in the subtree when the rest
            // of the name is.
            const n = if (std.mem.startsWith(u8, name, "*.")) name[2..] else name;
            return dnsWithin(n, c);
        },
        .ip => {
            const b = base.body;
            if (b.len != 8 and b.len != 32) return error.BadCertificate;
            const n = b.len / 2;
            if (name.len != n) return false;
            for (name, b[0..n], b[n..]) |x, addr, mask| if (x & mask != addr & mask) return false;
            return true;
        },
        .dn => {
            // The RDNs of the base are the first RDNs of the name.
            const bb = (der.one(base.body, der.tag.sequence) catch return error.BadCertificate).body;
            return std.mem.startsWith(u8, name, bb);
        },
        .other => return false,
    }
}

/// RFC 5280: a DNS constraint matches the name and each name with more
/// labels on the left. The compare ignores ASCII case.
fn dnsWithin(name: []const u8, c: []const u8) bool {
    if (c.len == 0) return true;
    if (name.len == c.len) return std.ascii.eqlIgnoreCase(name, c);
    return name.len > c.len and name[name.len - c.len - 1] == '.' and std.ascii.endsWithIgnoreCase(name, c);
}

fn matchHost(leaf: *const Cert, host: []const u8) Error!void {
    const san = leaf.san orelse return error.HostName;
    var ip_buf: [16]u8 = undefined;
    var ip: ?[]const u8 = null;
    if (std.Io.net.Ip4Address.parse(host, 0)) |a| {
        ip_buf[0..4].* = a.bytes;
        ip = ip_buf[0..4];
    } else |_| if (std.mem.indexOfScalar(u8, host, ':') != null) {
        const a = std.Io.net.Ip6Address.parse(host, 0) catch return error.HostName;
        ip_buf = a.bytes;
        ip = &ip_buf;
    }
    var h = host;
    if (ip == null and h.len > 0 and h[h.len - 1] == '.') h = h[0 .. h.len - 1];
    var r = der.Reader.init(san);
    while (!r.done()) {
        const g = r.next() catch return error.BadCertificate;
        if (ip) |want| {
            if (g.tag == 0x87 and std.mem.eql(u8, g.body, want)) return;
        } else if (g.tag == 0x82 and dnsMatch(g.body, h)) return;
    }
    return error.HostName;
}

/// RFC 6125 section 6.4: the compare ignores ASCII case. `*.b.c`
/// matches `a.b.c` and not `b.c` or `x.a.b.c`.
fn dnsMatch(pattern: []const u8, host: []const u8) bool {
    if (pattern.len == 0 or host.len == 0) return false;
    if (std.mem.startsWith(u8, pattern, "*.")) {
        const rest = pattern[1..];
        // At least two labels after the wildcard.
        if (std.mem.indexOfScalar(u8, rest[1..], '.') == null) return false;
        const dot = std.mem.indexOfScalar(u8, host, '.') orelse return false;
        if (dot == 0) return false;
        return std.ascii.eqlIgnoreCase(host[dot..], rest);
    }
    if (std.mem.indexOfScalar(u8, pattern, '*') != null) return false;
    return std.ascii.eqlIgnoreCase(pattern, host);
}

test "host names" {
    try std.testing.expect(dnsMatch("*.example.com", "a.example.com"));
    try std.testing.expect(dnsMatch("Example.COM", "example.com"));
    try std.testing.expect(!dnsMatch("*.example.com", "example.com"));
    try std.testing.expect(!dnsMatch("*.example.com", "x.a.example.com"));
    try std.testing.expect(!dnsMatch("*.com", "example.com"));
    try std.testing.expect(!dnsMatch("a*.example.com", "ab.example.com"));
    try std.testing.expect(dnsWithin("a.example.com", "example.com"));
    try std.testing.expect(dnsWithin("example.com", "example.com"));
    try std.testing.expect(!dnsWithin("badexample.com", "example.com"));
}

/// The certificates of `testdata/chain`, from `openssl req` and
/// `openssl x509` with P-256 keys: a root, a leaf for `leaf.test` that
/// the root signs, and a leaf for `evil.test` that the first leaf
/// signs. They are valid from 2026-11-27 to 2036-11-24.
const TestChain = struct {
    bytes: [3][]u8,
    certs: [3]Cert,

    fn load(a: std.mem.Allocator) !TestChain {
        const pem = @import("pem.zig");
        var t: TestChain = undefined;
        inline for (.{ "root", "leaf", "evil" }, 0..) |n, i| {
            var it = pem.Iterator.init(@embedFile("testdata/chain/" ++ n ++ ".pem"));
            t.bytes[i] = (try it.next(a)).?.der;
            t.certs[i] = try x509.parse(t.bytes[i]);
        }
        return t;
    }

    fn deinit(t: *TestChain, a: std.mem.Allocator) void {
        for (t.bytes) |b| a.free(b);
    }
};

const in_2027 = 1798761600;

test "a chain to the root, the host name, and the dates" {
    var t = try TestChain.load(std.testing.allocator);
    defer t.deinit(std.testing.allocator);
    const root = t.certs[0..1];
    try verify(&t.certs[1], &.{}, root, .{ .now = in_2027, .host = "leaf.test" });
    try verify(&t.certs[1], &.{}, root, .{ .now = in_2027, .host = "LEAF.test." });
    try std.testing.expectError(error.HostName, verify(&t.certs[1], &.{}, root, .{ .now = in_2027, .host = "other.test" }));
    try std.testing.expectError(error.Expired, verify(&t.certs[1], &.{}, root, .{ .now = in_2027 + 20 * 365 * 86400 }));
    try std.testing.expectError(error.UnknownIssuer, verify(&t.certs[1], &.{}, &.{}, .{ .now = in_2027 }));
}

test "a leaf as a CA is refused, and std Parsed.verify alone accepts it" {
    var t = try TestChain.load(std.testing.allocator);
    defer t.deinit(std.testing.allocator);
    try std.testing.expectError(error.NotCa, verify(&t.certs[2], t.certs[1..2], t.certs[0..1], .{ .now = in_2027, .host = "evil.test" }));
    const C = std.crypto.Certificate;
    const evil = try (C{ .buffer = t.bytes[2], .index = 0 }).parse();
    const leaf = try (C{ .buffer = t.bytes[1], .index = 0 }).parse();
    try C.Parsed.verify(evil, leaf, in_2027);
}

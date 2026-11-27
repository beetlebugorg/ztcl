//! The parse of an X.509 certificate (RFC 5280) for the chain checks.
//!
//! `parse` reads each field of the certificate with the strict DER
//! reader of `der.zig` and keeps slices of the input. It has no
//! allocation. It gives `error.BadCertificate` for bytes that are not
//! DER, a field of the wrong form, a duplicate extension, a version 1
//! or 2 certificate with extensions, and a signature algorithm of the
//! TBS part that is not the same as the outer one. A key or a signature
//! algorithm that the TLS code has no check for gives a null kind:
//! SHA-1, keys other than RSA, P-256, P-384, and Ed25519, and PSS
//! parameters other than MGF1 of the same hash and a salt of the hash
//! length. The chain checks refuse a signature of a null kind.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const der = @import("der.zig");
const tcrypto = @import("crypto.zig");
const tag = der.tag;

pub const Error = error{ BadCertificate, Unsupported };

pub const oid = struct {
    pub const rsa_encryption = "\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01";
    pub const sha256_rsa = "\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0b";
    pub const sha384_rsa = "\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0c";
    pub const sha512_rsa = "\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0d";
    pub const rsa_pss = "\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0a";
    pub const mgf1 = "\x2a\x86\x48\x86\xf7\x0d\x01\x01\x08";
    pub const ec_public_key = "\x2a\x86\x48\xce\x3d\x02\x01";
    pub const p256 = "\x2a\x86\x48\xce\x3d\x03\x01\x07";
    pub const p384 = "\x2b\x81\x04\x00\x22";
    pub const ecdsa_sha256 = "\x2a\x86\x48\xce\x3d\x04\x03\x02";
    pub const ecdsa_sha384 = "\x2a\x86\x48\xce\x3d\x04\x03\x03";
    pub const ecdsa_sha512 = "\x2a\x86\x48\xce\x3d\x04\x03\x04";
    pub const ed25519 = "\x2b\x65\x70";
    pub const sha256 = "\x60\x86\x48\x01\x65\x03\x04\x02\x01";
    pub const sha384 = "\x60\x86\x48\x01\x65\x03\x04\x02\x02";
    pub const sha512 = "\x60\x86\x48\x01\x65\x03\x04\x02\x03";
    pub const server_auth = "\x2b\x06\x01\x05\x05\x07\x03\x01";
    pub const client_auth = "\x2b\x06\x01\x05\x05\x07\x03\x02";
    pub const any_eku = "\x55\x1d\x25\x00";
};

/// The extensions that the chain checks read or can ignore when they
/// are critical.
pub const Ext = enum {
    subject_key_id,
    key_usage,
    subject_alt_name,
    basic_constraints,
    name_constraints,
    certificate_policies,
    authority_key_id,
    ext_key_usage,

    const map = std.StaticStringMap(Ext).initComptime(.{
        .{ "\x55\x1d\x0e", .subject_key_id },
        .{ "\x55\x1d\x0f", .key_usage },
        .{ "\x55\x1d\x11", .subject_alt_name },
        .{ "\x55\x1d\x13", .basic_constraints },
        .{ "\x55\x1d\x1e", .name_constraints },
        .{ "\x55\x1d\x20", .certificate_policies },
        .{ "\x55\x1d\x23", .authority_key_id },
        .{ "\x55\x1d\x25", .ext_key_usage },
    });
};

/// The bits of `KeyUsage`, from the first bit of the BIT STRING.
pub const key_usage = struct {
    pub const digital_signature: u16 = 1 << 15;
    pub const key_cert_sign: u16 = 1 << 10;
};

pub const Eku = packed struct {
    present: bool = false,
    server: bool = false,
    client: bool = false,
    any: bool = false,
};

pub const Cert = struct {
    /// The whole certificate.
    raw: []const u8,
    /// The signed part, with its tag and length.
    tbs: []const u8,
    version: u2,
    serial: []const u8 = "",
    /// The issuer and the subject, with the tag and the length.
    issuer: []const u8,
    subject: []const u8,
    not_before: i64,
    not_after: i64,
    /// Null for a kind of key that the TLS code has no check for.
    key_kind: ?tcrypto.KeyKind,
    /// The RSAPublicKey DER, the SEC 1 point, or the Ed25519 key.
    key: []const u8,
    /// Null for a signature algorithm that the TLS code has no check
    /// for. An anchor signed with SHA-1 is still an anchor.
    sig_alg: ?tcrypto.SigAlg,
    signature: []const u8,

    /// basicConstraints: present, the cA flag, and the path length.
    has_bc: bool = false,
    is_ca: bool = false,
    path_len: ?u32 = null,
    /// keyUsage: null when absent.
    key_usage: ?u16 = null,
    eku: Eku = .{},
    /// The contents of the SEQUENCE of `GeneralName`, or null.
    san: ?[]const u8 = null,
    /// The contents of the two `GeneralSubtrees` of nameConstraints.
    permitted: ?[]const u8 = null,
    excluded: ?[]const u8 = null,
    /// A critical extension that `Ext` does not list, or a key identifier
    /// extension that is critical (RFC 5280 sections 4.2.1.1 and
    /// 4.2.1.2).
    unknown_critical: bool = false,
    /// The extensions that are critical.
    critical: std.EnumSet(Ext) = .empty,

    pub fn selfIssued(c: *const Cert) bool {
        return std.mem.eql(u8, c.issuer, c.subject);
    }
};

fn bad(_: anyerror) Error {
    return error.BadCertificate;
}

pub fn parse(bytes: []const u8) Error!Cert {
    var top = der.Reader.init(bytes);
    const whole = top.expect(tag.sequence) catch |e| return bad(e);
    if (!top.done()) return error.BadCertificate;
    var r = der.Reader.init(whole.body);
    const tbs = r.expect(tag.sequence) catch |e| return bad(e);
    const outer_alg = r.expect(tag.sequence) catch |e| return bad(e);
    const sig = der.bitStringBytes(r.next() catch |e| return bad(e)) catch |e| return bad(e);
    if (!r.done()) return error.BadCertificate;

    var c: Cert = undefined;
    c = .{
        .raw = whole.raw,
        .tbs = tbs.raw,
        .version = 0,
        .issuer = "",
        .subject = "",
        .not_before = 0,
        .not_after = 0,
        .key_kind = .rsa,
        .key = "",
        .sig_alg = .ed25519,
        .signature = sig,
    };
    var t = der.Reader.init(tbs.body);
    if (t.optional(tag.explicit(0)) catch |e| return bad(e)) |v| {
        var vr = der.Reader.init(v.body);
        const n = der.smallUint(vr.next() catch |e| return bad(e)) catch |e| return bad(e);
        // DER leaves out the default v1, so an explicit version is 2 or 3.
        if (!vr.done() or n == 0 or n > 2) return error.BadCertificate;
        c.version = @intCast(n);
    }
    const serial = der.integerBytes(t.next() catch |e| return bad(e)) catch |e| return bad(e);
    // RFC 5280 section 4.1.2.2: at most 20 bytes. Some roots in use have
    // the serial number zero, so `chain.zig` checks for zero in a leaf
    // only.
    if (serial.len > 21) return error.BadCertificate;
    c.serial = serial;
    const inner_alg = t.expect(tag.sequence) catch |e| return bad(e);
    if (!std.mem.eql(u8, inner_alg.raw, outer_alg.raw)) return error.BadCertificate;
    c.sig_alg = sigAlg(outer_alg.body) catch |e| switch (e) {
        error.Unsupported => null,
        else => return e,
    };
    c.issuer = (try name(&t)).raw;
    var val = t.enter(tag.sequence) catch |e| return bad(e);
    c.not_before = try time(val.next() catch |e| return bad(e));
    c.not_after = try time(val.next() catch |e| return bad(e));
    if (!val.done()) return error.BadCertificate;
    c.subject = (try name(&t)).raw;
    spki(&c, t.expect(tag.sequence) catch |e| return bad(e)) catch |e| switch (e) {
        error.Unsupported => c.key_kind = null,
        else => return e,
    };
    // The unique identifiers of version 2.
    if (t.optional(tag.implicit(1)) catch |e| return bad(e)) |_| if (c.version == 0) return error.BadCertificate;
    if (t.optional(tag.implicit(2)) catch |e| return bad(e)) |_| if (c.version == 0) return error.BadCertificate;
    if (t.optional(tag.explicit(3)) catch |e| return bad(e)) |x| {
        if (c.version != 2) return error.BadCertificate;
        var xr = der.Reader.init(x.body);
        const list = xr.expect(tag.sequence) catch |e| return bad(e);
        if (!xr.done() or list.body.len == 0) return error.BadCertificate;
        try extensions(&c, list.body);
    }
    if (!t.done()) return error.BadCertificate;
    return c;
}

fn name(r: *der.Reader) Error!der.Element {
    const n = r.expect(tag.sequence) catch |e| return bad(e);
    var rr = der.Reader.init(n.body);
    while (!rr.done()) {
        var set = rr.enter(tag.set) catch |e| return bad(e);
        if (set.done()) return error.BadCertificate;
        while (!set.done()) {
            var atv = set.enter(tag.sequence) catch |e| return bad(e);
            _ = atv.expect(tag.oid) catch |e| return bad(e);
            _ = atv.next() catch |e| return bad(e);
            if (!atv.done()) return error.BadCertificate;
        }
    }
    return n;
}

fn hashOf(o: []const u8) ?tcrypto.Hash {
    if (std.mem.eql(u8, o, oid.sha256)) return .sha256;
    if (std.mem.eql(u8, o, oid.sha384)) return .sha384;
    if (std.mem.eql(u8, o, oid.sha512)) return .sha512;
    return null;
}

fn hashLen(h: tcrypto.Hash) u32 {
    return switch (h) {
        .sha256 => 32,
        .sha384 => 48,
        .sha512 => 64,
    };
}

/// A hash AlgorithmIdentifier with absent or NULL parameters.
fn hashAlg(body: []const u8) Error!tcrypto.Hash {
    var r = der.Reader.init(body);
    const h = hashOf((r.expect(tag.oid) catch |e| return bad(e)).body) orelse return error.Unsupported;
    if (!r.done()) {
        const p = r.next() catch |e| return bad(e);
        if (p.tag != tag.null_ or p.body.len != 0 or !r.done()) return error.BadCertificate;
    }
    return h;
}

fn sigAlg(body: []const u8) Error!tcrypto.SigAlg {
    var r = der.Reader.init(body);
    const o = (r.expect(tag.oid) catch |e| return bad(e)).body;
    const rsa_hash: ?tcrypto.Hash = if (std.mem.eql(u8, o, oid.sha256_rsa)) .sha256 else if (std.mem.eql(u8, o, oid.sha384_rsa)) .sha384 else if (std.mem.eql(u8, o, oid.sha512_rsa)) .sha512 else null;
    if (rsa_hash) |h| {
        // RFC 4055 section 5: the parameters are NULL.
        const p = r.expect(tag.null_) catch |e| return bad(e);
        if (p.body.len != 0 or !r.done()) return error.BadCertificate;
        return .{ .rsa_pkcs1 = h };
    }
    const ec_hash: ?tcrypto.Hash = if (std.mem.eql(u8, o, oid.ecdsa_sha256)) .sha256 else if (std.mem.eql(u8, o, oid.ecdsa_sha384)) .sha384 else if (std.mem.eql(u8, o, oid.ecdsa_sha512)) .sha512 else null;
    if (ec_hash) |h| {
        if (!r.done()) return error.BadCertificate;
        return .{ .ecdsa = h };
    }
    if (std.mem.eql(u8, o, oid.ed25519)) {
        if (!r.done()) return error.BadCertificate;
        return .ed25519;
    }
    if (std.mem.eql(u8, o, oid.rsa_pss)) {
        // RFC 4055 section 3.1. Each field has a SHA-1 default, so each
        // must be present here.
        var p = r.enter(tag.sequence) catch |e| return bad(e);
        if (!r.done()) return error.BadCertificate;
        var f0 = p.enter(tag.explicit(0)) catch return error.Unsupported;
        const h = try hashAlg((f0.expect(tag.sequence) catch |e| return bad(e)).body);
        var f1 = p.enter(tag.explicit(1)) catch return error.Unsupported;
        var mgf = f1.enter(tag.sequence) catch |e| return bad(e);
        if (!std.mem.eql(u8, (mgf.expect(tag.oid) catch |e| return bad(e)).body, oid.mgf1)) return error.Unsupported;
        if (try hashAlg((mgf.expect(tag.sequence) catch |e| return bad(e)).body) != h) return error.Unsupported;
        var f2 = p.enter(tag.explicit(2)) catch return error.Unsupported;
        if ((der.smallUint(f2.next() catch |e| return bad(e)) catch |e| return bad(e)) != hashLen(h)) return error.Unsupported;
        if (p.optional(tag.explicit(3)) catch |e| return bad(e)) |f3| {
            var tr = der.Reader.init(f3.body);
            if ((der.smallUint(tr.next() catch |e| return bad(e)) catch |e| return bad(e)) != 1) return error.BadCertificate;
        }
        if (!p.done()) return error.BadCertificate;
        return .{ .rsa_pss = h };
    }
    return error.Unsupported;
}

fn spki(c: *Cert, e: der.Element) Error!void {
    var r = der.Reader.init(e.body);
    var alg = r.enter(tag.sequence) catch |x| return bad(x);
    const key = der.bitStringBytes(r.next() catch |x| return bad(x)) catch |x| return bad(x);
    if (!r.done()) return error.BadCertificate;
    c.key = key;
    const o = (alg.expect(tag.oid) catch |x| return bad(x)).body;
    if (std.mem.eql(u8, o, oid.rsa_encryption)) {
        const p = alg.expect(tag.null_) catch |x| return bad(x);
        if (p.body.len != 0) return error.BadCertificate;
        c.key_kind = .rsa;
    } else if (std.mem.eql(u8, o, oid.ec_public_key)) {
        const curve = (alg.expect(tag.oid) catch |x| return bad(x)).body;
        if (std.mem.eql(u8, curve, oid.p256)) {
            c.key_kind = .p256;
            if (key.len != 65 or key[0] != 4) return error.BadCertificate;
        } else if (std.mem.eql(u8, curve, oid.p384)) {
            c.key_kind = .p384;
            if (key.len != 97 or key[0] != 4) return error.BadCertificate;
        } else return error.Unsupported;
    } else if (std.mem.eql(u8, o, oid.ed25519)) {
        if (key.len != 32) return error.BadCertificate;
        c.key_kind = .ed25519;
    } else return error.Unsupported;
    if (!alg.done()) return error.BadCertificate;
    c.key = key;
}

/// UTCTime YYMMDDHHMMSSZ or GeneralizedTime YYYYMMDDHHMMSSZ (RFC 5280
/// section 4.1.2.5), as seconds since 1970.
pub fn time(e: der.Element) Error!i64 {
    const s = e.body;
    var year: i64 = undefined;
    var rest: []const u8 = undefined;
    switch (e.tag) {
        tag.utc_time => {
            if (s.len != 13) return error.BadCertificate;
            const yy = try digits(s[0..2]);
            year = if (yy >= 50) 1900 + yy else 2000 + yy;
            rest = s[2..];
        },
        tag.generalized_time => {
            if (s.len != 15) return error.BadCertificate;
            year = try digits(s[0..4]);
            rest = s[4..];
        },
        else => return error.BadCertificate,
    }
    if (rest[10] != 'Z') return error.BadCertificate;
    const month = try digits(rest[0..2]);
    const day = try digits(rest[2..4]);
    const hour = try digits(rest[4..6]);
    const minute = try digits(rest[6..8]);
    const second = try digits(rest[8..10]);
    if (month < 1 or month > 12 or day < 1 or day > daysIn(year, month) or hour > 23 or minute > 59 or second > 59) return error.BadCertificate;
    return daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second;
}

fn digits(s: []const u8) Error!i64 {
    var v: i64 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return error.BadCertificate;
        v = v * 10 + (ch - '0');
    }
    return v;
}

fn daysIn(y: i64, m: i64) i64 {
    const leap = (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
    return switch (m) {
        2 => if (leap) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// The days from 1970-01-01 to a date of the proleptic Gregorian
/// calendar.
pub fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn extensions(c: *Cert, body: []const u8) Error!void {
    var seen: std.EnumSet(Ext) = .empty;
    var r = der.Reader.init(body);
    // A duplicate of an extension that `Ext` does not list: the check
    // compares each OID with the OIDs before it.
    var unknown: [16][]const u8 = undefined;
    var n_unknown: usize = 0;
    while (!r.done()) {
        var x = r.enter(tag.sequence) catch |e| return bad(e);
        const o = (x.expect(tag.oid) catch |e| return bad(e)).body;
        var critical = false;
        if (x.optional(tag.boolean) catch |e| return bad(e)) |b| {
            critical = der.boolean(b) catch |e| return bad(e);
            // DER leaves out the default FALSE.
            if (!critical) return error.BadCertificate;
        }
        const value = (x.expect(tag.octet_string) catch |e| return bad(e)).body;
        if (!x.done()) return error.BadCertificate;
        const kind = Ext.map.get(o) orelse {
            for (unknown[0..n_unknown]) |u| if (std.mem.eql(u8, u, o)) return error.BadCertificate;
            if (n_unknown == unknown.len) return error.BadCertificate;
            unknown[n_unknown] = o;
            n_unknown += 1;
            if (critical) c.unknown_critical = true;
            continue;
        };
        if (seen.contains(kind)) return error.BadCertificate;
        seen.insert(kind);
        if (critical) {
            c.critical.insert(kind);
            if (kind == .subject_key_id or kind == .authority_key_id) c.unknown_critical = true;
        }
        try extension(c, kind, value);
    }
}

fn extension(c: *Cert, kind: Ext, value: []const u8) Error!void {
    var top = der.Reader.init(value);
    switch (kind) {
        .basic_constraints => {
            var r = top.enter(tag.sequence) catch |e| return bad(e);
            c.has_bc = true;
            if (r.optional(tag.boolean) catch |e| return bad(e)) |b| {
                c.is_ca = der.boolean(b) catch |e| return bad(e);
                if (!c.is_ca) return error.BadCertificate;
            }
            if (r.optional(tag.integer) catch |e| return bad(e)) |n| c.path_len = der.smallUint(n) catch |e| return bad(e);
            if (!r.done()) return error.BadCertificate;
        },
        .key_usage => {
            const e = top.expect(tag.bit_string) catch |x| return bad(x);
            const b = e.body;
            if (b.len < 2 or b.len > 3 or b[0] > 7) return error.BadCertificate;
            var bits: u16 = @as(u16, b[1]) << 8;
            if (b.len == 3) bits |= b[2];
            c.key_usage = bits;
        },
        .ext_key_usage => {
            var r = top.enter(tag.sequence) catch |e| return bad(e);
            if (r.done()) return error.BadCertificate;
            c.eku.present = true;
            while (!r.done()) {
                const o = (r.expect(tag.oid) catch |e| return bad(e)).body;
                if (std.mem.eql(u8, o, oid.server_auth)) c.eku.server = true;
                if (std.mem.eql(u8, o, oid.client_auth)) c.eku.client = true;
                if (std.mem.eql(u8, o, oid.any_eku)) c.eku.any = true;
            }
        },
        .subject_alt_name => {
            const s = top.expect(tag.sequence) catch |e| return bad(e);
            if (s.body.len == 0) return error.BadCertificate;
            try generalNames(s.body);
            c.san = s.body;
        },
        .name_constraints => {
            var r = top.enter(tag.sequence) catch |e| return bad(e);
            if (r.optional(tag.explicit(0)) catch |e| return bad(e)) |p| c.permitted = try subtrees(p.body);
            if (r.optional(tag.explicit(1)) catch |e| return bad(e)) |x| c.excluded = try subtrees(x.body);
            if (!r.done() or (c.permitted == null and c.excluded == null)) return error.BadCertificate;
        },
        .subject_key_id, .authority_key_id, .certificate_policies => _ = top.next() catch |e| return bad(e),
    }
    if (!top.done()) return error.BadCertificate;
}

fn generalNames(body: []const u8) Error!void {
    var r = der.Reader.init(body);
    while (!r.done()) _ = r.next() catch |e| return bad(e);
}

/// GeneralSubtrees: each base is a GeneralName, with no minimum other
/// than zero and no maximum (RFC 5280 section 4.2.1.10).
fn subtrees(body: []const u8) Error![]const u8 {
    if (body.len == 0) return error.BadCertificate;
    var r = der.Reader.init(body);
    while (!r.done()) {
        var s = r.enter(tag.sequence) catch |e| return bad(e);
        _ = s.next() catch |e| return bad(e);
        if (!s.done()) return error.BadCertificate;
    }
    return body;
}

test "dates" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 19723), daysFromCivil(2024, 1, 1));
    try std.testing.expectEqual(@as(i64, 1704067200), try time(.{ .tag = tag.utc_time, .body = "240101000000Z", .raw = "" }));
    try std.testing.expectEqual(@as(i64, 1704067200), try time(.{ .tag = tag.generalized_time, .body = "20240101000000Z", .raw = "" }));
    try std.testing.expectError(error.BadCertificate, time(.{ .tag = tag.utc_time, .body = "240230000000Z", .raw = "" }));
}

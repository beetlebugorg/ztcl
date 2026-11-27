//! PEM (RFC 7468) blocks, and the private keys of a TLS server.
//!
//! `Iterator.next` finds each `-----BEGIN label-----` line, and decodes
//! the Base64 up to the `-----END label-----` line of the same label.
//! Text between the blocks is skipped. The decoder ignores white space
//! in the Base64 and refuses any other byte that is not Base64.
//!
//! `privateKey` reads a PKCS#8 `PRIVATE KEY` (RFC 5208 and RFC 8410)
//! or a SEC 1 `EC PRIVATE KEY` (RFC 5915), for P-256, P-384, and
//! Ed25519. RSA server keys are later work (task 24).
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const der = @import("der.zig");
const x509 = @import("x509.zig");
const tag = der.tag;
const oid = x509.oid;

pub const Error = error{ BadPem, BadKey, Unsupported, OutOfMemory };

pub const Block = struct {
    label: []const u8,
    /// The decoded bytes, owned by the caller.
    der: []u8,
};

pub const Iterator = struct {
    text: []const u8,
    pos: usize = 0,

    const begin = "-----BEGIN ";
    const dashes = "-----";

    pub fn init(text: []const u8) Iterator {
        return .{ .text = text };
    }

    /// The next block, with its bytes from `a`, or null at the end.
    pub fn next(it: *Iterator, a: std.mem.Allocator) Error!?Block {
        const start = std.mem.indexOfPos(u8, it.text, it.pos, begin) orelse {
            it.pos = it.text.len;
            return null;
        };
        const label_start = start + begin.len;
        const label_end = std.mem.indexOfPos(u8, it.text, label_start, dashes) orelse return error.BadPem;
        const label = it.text[label_start..label_end];
        if (std.mem.indexOfScalar(u8, label, '\n') != null) return error.BadPem;
        const body_start = label_end + dashes.len;
        var end_buf: [80]u8 = undefined;
        const end_line = std.fmt.bufPrint(&end_buf, "-----END {s}-----", .{label}) catch return error.BadPem;
        const body_end = std.mem.indexOfPos(u8, it.text, body_start, end_line) orelse return error.BadPem;
        it.pos = body_end + end_line.len;
        const body = it.text[body_start..body_end];
        const dec = std.base64.standard.decoderWithIgnore(" \t\r\n");
        const max = dec.calcSizeUpperBound(body.len);
        const out = try a.alloc(u8, max);
        defer a.free(out);
        const n = dec.decode(out, body) catch return error.BadPem;
        const exact = try a.dupe(u8, out[0..n]);
        return .{ .label = label, .der = exact };
    }
};

pub const PrivateKey = union(enum) {
    p256: [32]u8,
    p384: [48]u8,
    /// The seed of RFC 8032.
    ed25519: [32]u8,
};

fn badKey(_: anyerror) Error {
    return error.BadKey;
}

/// The key of a PEM block with the label `PRIVATE KEY` or
/// `EC PRIVATE KEY`.
pub fn privateKey(b: Block) Error!PrivateKey {
    if (std.mem.eql(u8, b.label, "EC PRIVATE KEY")) return ecPrivateKey(b.der, null);
    if (!std.mem.eql(u8, b.label, "PRIVATE KEY")) return error.Unsupported;
    var top = der.Reader.init(b.der);
    var r = top.enter(tag.sequence) catch |e| return badKey(e);
    if (!top.done()) return error.BadKey;
    // Version 0 (RFC 5208) or 1 (RFC 5958, with a public key).
    const v = der.smallUint(r.next() catch |e| return badKey(e)) catch |e| return badKey(e);
    if (v > 1) return error.BadKey;
    var alg = r.enter(tag.sequence) catch |e| return badKey(e);
    const o = (alg.expect(tag.oid) catch |e| return badKey(e)).body;
    const key = (r.expect(tag.octet_string) catch |e| return badKey(e)).body;
    if (std.mem.eql(u8, o, oid.ed25519)) {
        if (!alg.done()) return error.BadKey;
        var kr = der.Reader.init(key);
        const seed = (kr.expect(tag.octet_string) catch |e| return badKey(e)).body;
        if (!kr.done() or seed.len != 32) return error.BadKey;
        return .{ .ed25519 = seed[0..32].* };
    }
    if (std.mem.eql(u8, o, oid.ec_public_key)) {
        const curve = (alg.expect(tag.oid) catch |e| return badKey(e)).body;
        if (!alg.done()) return error.BadKey;
        return ecPrivateKey(key, curve);
    }
    return error.Unsupported;
}

/// ECPrivateKey of RFC 5915 section 3. The curve comes from the
/// PKCS#8 algorithm or from the parameters of the key.
fn ecPrivateKey(bytes: []const u8, outer_curve: ?[]const u8) Error!PrivateKey {
    var top = der.Reader.init(bytes);
    var r = top.enter(tag.sequence) catch |e| return badKey(e);
    if (!top.done()) return error.BadKey;
    if ((der.smallUint(r.next() catch |e| return badKey(e)) catch |e| return badKey(e)) != 1) return error.BadKey;
    const k = (r.expect(tag.octet_string) catch |e| return badKey(e)).body;
    var curve = outer_curve;
    if (r.optional(tag.explicit(0)) catch |e| return badKey(e)) |p| {
        var pr = der.Reader.init(p.body);
        const c = (pr.expect(tag.oid) catch |e| return badKey(e)).body;
        if (curve) |oc| if (!std.mem.eql(u8, oc, c)) return error.BadKey;
        curve = c;
    }
    _ = r.optional(tag.explicit(1)) catch |e| return badKey(e);
    if (!r.done()) return error.BadKey;
    const c = curve orelse return error.BadKey;
    if (std.mem.eql(u8, c, oid.p256)) {
        if (k.len != 32) return error.BadKey;
        return .{ .p256 = k[0..32].* };
    }
    if (std.mem.eql(u8, c, oid.p384)) {
        if (k.len != 48) return error.BadKey;
        return .{ .p384 = k[0..48].* };
    }
    return error.Unsupported;
}

test "blocks and keys" {
    const a = std.testing.allocator;
    // The Ed25519 key of RFC 8410 section 10.3, and a P-256 SEC 1 key
    // from `openssl ecparam -genkey`.
    const text =
        \\junk
        \\-----BEGIN PRIVATE KEY-----
        \\MC4CAQAwBQYDK2VwBCIEINTuctv5E1hK1bbY8fdp+K06/nwoy/HU++CXqI9EdVhC
        \\-----END PRIVATE KEY-----
        \\-----BEGIN EC PRIVATE KEY-----
        \\MHcCAQEEIOvTLyRad07grWppPIrA5Lxiy0W7uQ+c8c7Sh9mzXZsvoAoGCCqGSM49
        \\AwEHoUQDQgAER+fd9WZu8QEr1oYPgGOGRy6cjzUElQiwYdotJUVclgmMzES63Qig
        \\jOWvoKvetsBps0OEDO9sWGk6ffB0A60nZA==
        \\-----END EC PRIVATE KEY-----
        \\
    ;
    var it = Iterator.init(text);
    const b1 = (try it.next(a)).?;
    defer a.free(b1.der);
    const k1 = try privateKey(b1);
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "d4ee72dbf913584ad5b6d8f1f769f8ad3afe7c28cbf1d4fbe097a88f44755842");
    try std.testing.expectEqualSlices(u8, &want, &k1.ed25519);
    const b2 = (try it.next(a)).?;
    defer a.free(b2.der);
    const k2 = try privateKey(b2);
    try std.testing.expect(k2 == .p256);
    try std.testing.expect((try it.next(a)) == null);
}

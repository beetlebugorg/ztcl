//! The signature checks and the key exchanges of TLS 1.3 on the
//! primitives of `std.crypto`. The handshake and the chain checks call
//! these functions only, and the Wycheproof sets (`wycheproof.zig`)
//! test them.
//!
//! Signatures (RFC 8446 section 4.2.3):
//!
//! - ECDSA on P-256 with SHA-256 and on P-384 with SHA-384. The key is a
//!   SEC 1 point. The signature is DER, and `std.crypto.ecdsa` reads
//!   only the minimal DER of two integers.
//! - RSASSA-PSS with an rsaEncryption key (`rsa_pss_rsae_*`), with the
//!   MGF1 of the same hash and a salt of the hash length.
//! - RSASSA-PKCS1-v1_5, for the signatures of certificates only.
//! - Ed25519 (RFC 8032), with the checks of `verifyStrict`: a canonical
//!   `S`, and no key or `R` of small order.
//!
//! An RSA key is the DER `RSAPublicKey` of RFC 8017, with a modulus of
//! 2048, 3072, or 4096 bits. The signature has the length of the
//! modulus exactly.
//!
//! Key exchange (section 4.2.8.2): X25519, and ECDH on P-256 and P-384
//! with uncompressed points only. A shared secret of X25519 that is all
//! zero gives an error (section 7.4.2).
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const crypto = std.crypto;
const rsa = crypto.Certificate.rsa;
const sha2 = crypto.hash.sha2;

pub const Error = error{ BadSignature, BadKey, Unsupported };

/// The values of `SignatureScheme` that this code checks.
pub const Scheme = enum(u16) {
    rsa_pkcs1_sha256 = 0x0401,
    rsa_pkcs1_sha384 = 0x0501,
    rsa_pkcs1_sha512 = 0x0601,
    ecdsa_secp256r1_sha256 = 0x0403,
    ecdsa_secp384r1_sha384 = 0x0503,
    rsa_pss_rsae_sha256 = 0x0804,
    rsa_pss_rsae_sha384 = 0x0805,
    rsa_pss_rsae_sha512 = 0x0806,
    ed25519 = 0x0807,
    _,
};

/// Checks `sig` on `msg` with `key` for `scheme`.
pub fn verify(scheme: Scheme, key: []const u8, msg: []const u8, sig: []const u8) Error!void {
    switch (scheme) {
        .ecdsa_secp256r1_sha256 => return ecdsa(crypto.sign.ecdsa.EcdsaP256Sha256, key, msg, sig),
        .ecdsa_secp384r1_sha384 => return ecdsa(crypto.sign.ecdsa.EcdsaP384Sha384, key, msg, sig),
        .rsa_pss_rsae_sha256 => return rsaVerify(.pss, sha2.Sha256, key, msg, sig),
        .rsa_pss_rsae_sha384 => return rsaVerify(.pss, sha2.Sha384, key, msg, sig),
        .rsa_pss_rsae_sha512 => return rsaVerify(.pss, sha2.Sha512, key, msg, sig),
        .rsa_pkcs1_sha256 => return rsaVerify(.pkcs1, sha2.Sha256, key, msg, sig),
        .rsa_pkcs1_sha384 => return rsaVerify(.pkcs1, sha2.Sha384, key, msg, sig),
        .rsa_pkcs1_sha512 => return rsaVerify(.pkcs1, sha2.Sha512, key, msg, sig),
        .ed25519 => {
            const E = crypto.sign.Ed25519;
            if (key.len != E.PublicKey.encoded_length) return error.BadKey;
            if (sig.len != E.Signature.encoded_length) return error.BadSignature;
            const pk = E.PublicKey.fromBytes(key[0..32].*) catch return error.BadKey;
            const s = E.Signature.fromBytes(sig[0..64].*);
            s.verifyStrict(msg, pk) catch return error.BadSignature;
        },
        _ => return error.Unsupported,
    }
}

fn ecdsa(comptime E: type, key: []const u8, msg: []const u8, sig: []const u8) Error!void {
    const pk = E.PublicKey.fromSec1(key) catch return error.BadKey;
    const s = E.Signature.fromDer(sig) catch return error.BadSignature;
    s.verify(msg, pk) catch return error.BadSignature;
}

const Padding = enum { pss, pkcs1 };

/// The modulus and the exponent of a DER `RSAPublicKey`.
pub fn rsaKey(der: []const u8) Error!rsa.PublicKey {
    const parts = rsa.PublicKey.parseDer(der) catch return error.BadKey;
    return rsa.PublicKey.fromBytes(parts.exponent, parts.modulus) catch error.BadKey;
}

/// The RSA checks have their own code: in Zig 0.17.0, the PSS check of
/// `std.crypto.Certificate.rsa` reads one byte of the zero padding of
/// `DB` only, and Wycheproof gives signatures that it accepts.
fn rsaVerify(comptime pad: Padding, comptime H: type, key: []const u8, msg: []const u8, sig: []const u8) Error!void {
    const pk = try rsaKey(key);
    const bits = pk.n.bits();
    inline for (.{ 2048, 3072, 4096 }) |b| {
        if (bits == b) {
            const k = b / 8;
            if (sig.len != k) return error.BadSignature;
            // RSAVP1 of RFC 8017 section 5.2.2: a signature of n or more
            // is not a representative.
            const s = std.crypto.ff.Modulus(4096).Fe.fromBytes(pk.n, sig, .big) catch return error.BadSignature;
            const m = pk.n.powPublic(s, pk.e) catch return error.BadSignature;
            var em: [k]u8 = undefined;
            m.toBytes(&em, .big) catch return error.BadSignature;
            var digest: [H.digest_length]u8 = undefined;
            H.hash(msg, &digest, .{});
            return switch (pad) {
                .pss => pssCheck(H, &em, &digest),
                .pkcs1 => pkcs1Check(H, &em, &digest),
            };
        }
    }
    return error.BadKey;
}

/// EMSA-PSS-VERIFY of RFC 8017 section 9.1.2, with MGF1 of `H` and a
/// salt of the hash length (RFC 8446 section 4.2.3). The modulus has a
/// multiple of 8 bits, so `emLen` is the length of `em` and the top bit
/// of `em` is the one bit that must be zero.
fn pssCheck(comptime H: type, em: []const u8, digest: *const [H.digest_length]u8) Error!void {
    const h_len = H.digest_length;
    const s_len = h_len;
    if (em.len < h_len + s_len + 2) return error.BadSignature;
    if (em[em.len - 1] != 0xbc) return error.BadSignature;
    const db_len = em.len - h_len - 1;
    const masked = em[0..db_len];
    const hh = em[db_len..][0..h_len];
    if (masked[0] & 0x80 != 0) return error.BadSignature;
    var db: [512]u8 = undefined;
    // MGF1: the hash of the seed and a 32-bit count, until db_len bytes.
    var i: usize = 0;
    var counter: u32 = 0;
    while (i < db_len) : (counter += 1) {
        var block: [h_len]u8 = undefined;
        var c: [4]u8 = undefined;
        std.mem.writeInt(u32, &c, counter, .big);
        var st = H.init(.{});
        st.update(hh);
        st.update(&c);
        st.final(&block);
        const n = @min(h_len, db_len - i);
        for (db[i..][0..n], block[0..n], masked[i..][0..n]) |*d, x, y| d.* = x ^ y;
        i += n;
    }
    db[0] &= 0x7f;
    const ps_len = db_len - s_len - 1;
    for (db[0..ps_len]) |x| if (x != 0) return error.BadSignature;
    if (db[ps_len] != 1) return error.BadSignature;
    var st = H.init(.{});
    st.update(&@as([8]u8, @splat(0)));
    st.update(digest);
    st.update(db[db_len - s_len .. db_len]);
    var h2: [h_len]u8 = undefined;
    st.final(&h2);
    if (!std.mem.eql(u8, hh, &h2)) return error.BadSignature;
}

/// EMSA-PKCS1-v1_5 of RFC 8017 section 9.2: the check encodes the
/// digest and compares the whole block. The `DigestInfo` has the NULL
/// parameters.
fn pkcs1Check(comptime H: type, em: []const u8, digest: *const [H.digest_length]u8) Error!void {
    const prefix: []const u8 = switch (H) {
        sha2.Sha256 => &.{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 },
        sha2.Sha384 => &.{ 0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30 },
        sha2.Sha512 => &.{ 0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40 },
        else => @compileError("no DigestInfo"),
    };
    const t_len = prefix.len + digest.len;
    if (em.len < t_len + 11) return error.BadSignature;
    const ps_end = em.len - t_len - 1;
    if (em[0] != 0 or em[1] != 1 or em[ps_end] != 0) return error.BadSignature;
    for (em[2..ps_end]) |x| if (x != 0xff) return error.BadSignature;
    if (!std.mem.eql(u8, em[ps_end + 1 ..][0..prefix.len], prefix)) return error.BadSignature;
    if (!std.mem.eql(u8, em[em.len - digest.len ..], digest)) return error.BadSignature;
}

/// The values of `NamedGroup` that this code uses.
pub const Group = enum(u16) {
    secp256r1 = 0x0017,
    secp384r1 = 0x0018,
    x25519 = 0x001d,
    _,

    /// The length of a key share and of the shared secret.
    pub fn shareLen(g: Group) usize {
        return switch (g) {
            .x25519 => 32,
            .secp256r1 => 65,
            .secp384r1 => 97,
            _ => 0,
        };
    }

    pub fn secretLen(g: Group) usize {
        return switch (g) {
            .x25519, .secp256r1 => 32,
            .secp384r1 => 48,
            _ => 0,
        };
    }
};

pub const max_secret = 48;

/// The shared secret of `private` (a scalar, big endian for the NIST
/// curves) and the key share `peer`. Gives the first `g.secretLen()`
/// bytes of `out`.
pub fn sharedSecret(g: Group, private: []const u8, peer: []const u8, out: *[max_secret]u8) Error![]const u8 {
    if (peer.len != g.shareLen()) return error.BadKey;
    switch (g) {
        .x25519 => {
            if (private.len != 32) return error.BadKey;
            const s = crypto.dh.X25519.scalarmult(private[0..32].*, peer[0..32].*) catch return error.BadKey;
            out[0..32].* = s;
            return out[0..32];
        },
        .secp256r1 => return nist(crypto.ecc.P256, private, peer, out),
        .secp384r1 => return nist(crypto.ecc.P384, private, peer, out),
        _ => return error.Unsupported,
    }
}

fn nist(comptime C: type, private: []const u8, peer: []const u8, out: *[max_secret]u8) Error![]const u8 {
    const n = C.scalar.encoded_length;
    if (private.len != n) return error.BadKey;
    // Section 4.2.8.2: the legacy form 4, then X and Y.
    if (peer[0] != 4) return error.BadKey;
    const p = C.fromSec1(peer) catch return error.BadKey;
    const q = p.mul(private[0..n].*, .big) catch return error.BadKey;
    out[0..n].* = q.affineCoordinates().x.toBytes(.big);
    return out[0..n];
}

test "an unknown scheme and group give Unsupported" {
    try std.testing.expectError(error.Unsupported, verify(@fromBackingInt(@intCast(0x0201)), "", "", ""));
    var out: [max_secret]u8 = undefined;
    try std.testing.expectError(error.Unsupported, sharedSecret(@fromBackingInt(@intCast(0x0100)), "", "", &out));
}

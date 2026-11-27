//! The key schedule of TLS 1.3 (RFC 8446 section 7), on HKDF of
//! `std.crypto.kdf.hkdf`.
//!
//! The schedule is a chain of HKDF-Extract steps. Each step takes the
//! salt `Derive-Secret(previous, "derived", "")` and new input keying
//! material: the PSK (or zeros) for the early secret, the shared secret
//! of the key exchange for the handshake secret, and zeros for the
//! master secret. Each traffic secret is `Derive-Secret(stage secret,
//! label, transcript hash)`. `HKDF-Expand-Label` encodes the struct
//! `HkdfLabel`: the length of the output in two bytes, the label with
//! the prefix "tls13 " after a length byte, and the context after a
//! length byte.
//!
//! A traffic secret gives the key and the IV of the AEAD of a record
//! (section 7.3), the finished key (section 4.4.4), and the next
//! traffic secret of a key update (section 7.2).
//!
//! `Schedule(Hash)` is generic over SHA-256 and SHA-384, the two hashes
//! of the cipher suites of RFC 8446.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const hkdf = std.crypto.kdf.hkdf;
const hmac = std.crypto.auth.hmac;

/// The longest label: "tls13 " and 249 bytes of the caller.
pub const max_label = 255;
/// The longest context of `HkdfLabel`.
pub const max_context = 255;
/// The size of the buffer of an encoded `HkdfLabel`.
pub const max_info = 2 + 1 + max_label + 1 + max_context;

/// Writes the struct `HkdfLabel` of `HKDF-Expand-Label` into `buf` and
/// gives its bytes. `label` has no "tls13 " prefix.
pub fn hkdfLabel(buf: *[max_info]u8, length: u16, label: []const u8, context: []const u8) []const u8 {
    const prefix = "tls13 ";
    std.debug.assert(prefix.len + label.len <= max_label and context.len <= max_context);
    std.mem.writeInt(u16, buf[0..2], length, .big);
    buf[2] = @intCast(prefix.len + label.len);
    var i: usize = 3;
    @memcpy(buf[i..][0..prefix.len], prefix);
    i += prefix.len;
    @memcpy(buf[i..][0..label.len], label);
    i += label.len;
    buf[i] = @intCast(context.len);
    i += 1;
    @memcpy(buf[i..][0..context.len], context);
    return buf[0 .. i + context.len];
}

pub fn Schedule(comptime Hash: type) type {
    return struct {
        pub const Hmac = hmac.Hmac(Hash);
        pub const Hkdf = hkdf.Hkdf(Hmac);
        pub const hash_len = Hash.digest_length;
        pub const Secret = [hash_len]u8;

        /// The hash of no bytes, the context of "derived".
        pub fn emptyHash() Secret {
            var h: Secret = undefined;
            Hash.hash("", &h, .{});
            return h;
        }

        pub fn extract(salt: []const u8, ikm: []const u8) Secret {
            return Hkdf.extract(salt, ikm);
        }

        /// `HKDF-Expand-Label(secret, label, context, out.len)`.
        pub fn expandLabel(out: []u8, secret: Secret, label: []const u8, context: []const u8) void {
            var buf: [max_info]u8 = undefined;
            Hkdf.expand(out, hkdfLabel(&buf, @intCast(out.len), label, context), secret);
        }

        /// `Derive-Secret(secret, label, transcript_hash)`.
        pub fn deriveSecret(secret: Secret, label: []const u8, transcript_hash: []const u8) Secret {
            var out: Secret = undefined;
            expandLabel(&out, secret, label, transcript_hash);
            return out;
        }

        /// The early secret of a PSK, or of zeros when `psk` is null.
        pub fn early(psk: ?[]const u8) Secret {
            const zeros: Secret = @splat(0);
            return extract(&zeros, psk orelse &zeros);
        }

        /// The next stage secret: the handshake secret from the early
        /// secret and the shared secret, or the master secret from the
        /// handshake secret and null.
        pub fn next(previous: Secret, ikm: ?[]const u8) Secret {
            const zeros: Secret = @splat(0);
            const salt = deriveSecret(previous, "derived", &emptyHash());
            return extract(&salt, ikm orelse &zeros);
        }

        /// The finished key of a traffic secret (section 4.4.4).
        pub fn finishedKey(secret: Secret) Secret {
            var out: Secret = undefined;
            expandLabel(&out, secret, "finished", "");
            return out;
        }

        /// The `verify_data` of a Finished message.
        pub fn finished(secret: Secret, transcript_hash: []const u8) Secret {
            var out: Secret = undefined;
            Hmac.create(&out, transcript_hash, &finishedKey(secret));
            return out;
        }

        /// The traffic secret after a key update (section 7.2).
        pub fn update(secret: Secret) Secret {
            return deriveSecret(secret, "traffic upd", "");
        }

        /// The key and the IV of the record AEAD of a traffic secret.
        pub fn trafficKey(key: []u8, iv: *[12]u8, secret: Secret) void {
            expandLabel(key, secret, "key", "");
            expandLabel(iv, secret, "iv", "");
        }

        /// The PSK of a ticket nonce (section 4.6.1).
        pub fn resumption(resumption_master: Secret, ticket_nonce: []const u8) Secret {
            return deriveSecret(resumption_master, "resumption", ticket_nonce);
        }
    };
}

pub const Sha256 = Schedule(std.crypto.hash.sha2.Sha256);
pub const Sha384 = Schedule(std.crypto.hash.sha2.Sha384);

fn unhex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "HKDF of RFC 5869 test case 1" {
    const H = Sha256.Hkdf;
    const prk = H.extract(&unhex("000102030405060708090a0b0c"), &unhex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"));
    try std.testing.expectEqualSlices(u8, &unhex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"), &prk);
    var okm: [42]u8 = undefined;
    H.expand(&okm, &unhex("f0f1f2f3f4f5f6f7f8f9"), prk);
    try std.testing.expectEqualSlices(u8, &unhex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"), &okm);
}

test "HKDF of RFC 5869 test case 3: no salt and no info" {
    const H = Sha256.Hkdf;
    const prk = H.extract("", &unhex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"));
    try std.testing.expectEqualSlices(u8, &unhex("19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04"), &prk);
    var okm: [42]u8 = undefined;
    H.expand(&okm, "", prk);
    try std.testing.expectEqualSlices(u8, &unhex("8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"), &okm);
}

test "the HkdfLabel of the label derived" {
    var buf: [max_info]u8 = undefined;
    const info = hkdfLabel(&buf, 32, "derived", &Sha256.emptyHash());
    try std.testing.expectEqualSlices(u8, &unhex("00200d746c733133206465726976656420e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"), info);
}

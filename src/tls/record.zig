//! The record layer of TLS 1.3 (RFC 8446 section 5), shared by the
//! client and the server.
//!
//! A record is a header of 5 bytes (the content type, the legacy version
//! 0x0303, and the length) and a fragment. Before the keys of a stage
//! exist, the fragment is plain. After, each record is the AEAD seal of
//! `TLSInnerPlaintext`: the content, the real content type in one byte,
//! and zero bytes of padding. The header is the additional data. The
//! nonce is the IV of the traffic secret XOR the sequence number of the
//! record, a 64-bit count in network order padded to 12 bytes on the
//! left. Each direction and each key has its own count, from zero.
//!
//! `open` decrypts, then finds the content type: the last byte that is
//! not zero. The scan reads each byte of the plaintext and has no
//! branch on a byte, so its time depends on the length only. The AEADs
//! of `std.crypto` compare the tag with `std.crypto.timing_safe.eql`.
//! The AEADs go through `aead.zig`, which picks the code for the CPU.
//!
//! The limits of section 5: a plain fragment and the content of a
//! protected record have at most 2^14 bytes, and a protected fragment
//! has at most 2^14 + 256 bytes. A larger length gives the alert
//! `record_overflow`. A bad tag gives `bad_record_mac`. A protected
//! record with no content type, or a handshake or alert record with no
//! content, gives `unexpected_message`. Section 5.5 limits AES-GCM to
//! 2^24.5 records for each key. `seal` gives `error.KeyLimit` at that
//! count, and `needsUpdate` is true 2^20 records before it, so the
//! caller can send a KeyUpdate first.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const schedule = @import("schedule.zig");
const aead = std.crypto.aead;
const fast = @import("aead.zig");

pub const header_len = 5;
pub const max_plaintext = 1 << 14;
pub const max_ciphertext = max_plaintext + 256;
pub const tag_len = 16;
/// The size of a buffer that holds any record.
pub const max_record = header_len + max_ciphertext;

pub const ContentType = enum(u8) {
    invalid = 0,
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
    _,
};

/// The alerts of RFC 8446 section 6.
pub const Alert = enum(u8) {
    close_notify = 0,
    unexpected_message = 10,
    bad_record_mac = 20,
    record_overflow = 22,
    handshake_failure = 40,
    bad_certificate = 42,
    unsupported_certificate = 43,
    certificate_revoked = 44,
    certificate_expired = 45,
    certificate_unknown = 46,
    illegal_parameter = 47,
    unknown_ca = 48,
    access_denied = 49,
    decode_error = 50,
    decrypt_error = 51,
    protocol_version = 70,
    insufficient_security = 71,
    internal_error = 80,
    inappropriate_fallback = 86,
    user_canceled = 90,
    missing_extension = 109,
    unsupported_extension = 110,
    unrecognized_name = 112,
    bad_certificate_status_response = 113,
    unknown_psk_identity = 115,
    certificate_required = 116,
    no_application_protocol = 120,
    _,
};

pub const Error = error{
    RecordOverflow,
    BadRecordMac,
    UnexpectedMessage,
    DecodeError,
    /// The key reached the record limit of its AEAD.
    KeyLimit,
    /// The output buffer is too small.
    NoSpace,
};

/// The alert that ends the connection after an error of this file.
pub fn alertOf(e: Error) Alert {
    return switch (e) {
        error.RecordOverflow => .record_overflow,
        error.BadRecordMac => .bad_record_mac,
        error.UnexpectedMessage => .unexpected_message,
        error.DecodeError => .decode_error,
        error.KeyLimit, error.NoSpace => .internal_error,
    };
}

/// The cipher suites of RFC 8446 section 9.1 and B.4 that ztcl has.
pub const Suite = enum(u16) {
    aes_128_gcm_sha256 = 0x1301,
    aes_256_gcm_sha384 = 0x1302,
    chacha20_poly1305_sha256 = 0x1303,

    pub fn keyLen(s: Suite) usize {
        return switch (s) {
            .aes_128_gcm_sha256 => 16,
            .aes_256_gcm_sha384, .chacha20_poly1305_sha256 => 32,
        };
    }

    pub fn hashLen(s: Suite) usize {
        return switch (s) {
            .aes_256_gcm_sha384 => 48,
            else => 32,
        };
    }

    /// The count of records of one key (section 5.5).
    pub fn recordLimit(s: Suite) u64 {
        return switch (s) {
            // floor(2^24.5)
            .aes_128_gcm_sha256, .aes_256_gcm_sha384 => 23_726_566,
            .chacha20_poly1305_sha256 => std.math.maxInt(u64),
        };
    }
};

pub const Header = struct {
    type: ContentType,
    version: u16,
    len: u16,

    pub fn parse(b: *const [header_len]u8) Header {
        return .{ .type = @fromBackingInt(@intCast(b[0])), .version = std.mem.readInt(u16, b[1..3], .big), .len = std.mem.readInt(u16, b[3..5], .big) };
    }

    fn write(h: Header, b: *[header_len]u8) void {
        b[0] = @backingInt(h.type);
        std.mem.writeInt(u16, b[1..3], h.version, .big);
        std.mem.writeInt(u16, b[3..5], h.len, .big);
    }
};

/// Writes a plain record into `out` and gives its bytes. The first
/// ClientHello uses the version 0x0301; each other record uses 0x0303.
pub fn writePlain(out: []u8, ct: ContentType, version: u16, fragment: []const u8) Error![]u8 {
    if (fragment.len > max_plaintext) return error.RecordOverflow;
    if (out.len < header_len + fragment.len) return error.NoSpace;
    (Header{ .type = ct, .version = version, .len = @intCast(fragment.len) }).write(out[0..header_len]);
    @memcpy(out[header_len..][0..fragment.len], fragment);
    return out[0 .. header_len + fragment.len];
}

/// Checks the header of a record before the keys of its stage exist.
/// `len` is the length of the fragment that follows.
pub fn checkPlain(h: Header) Error!void {
    if (h.len > max_plaintext) return error.RecordOverflow;
    switch (h.type) {
        .handshake, .alert => if (h.len == 0) return error.UnexpectedMessage,
        .change_cipher_spec, .application_data => {},
        else => return error.UnexpectedMessage,
    }
}

/// The plain content of an opened record.
pub const Plain = struct {
    type: ContentType,
    data: []u8,
};

/// The keys of one direction of a connection.
pub const Protection = struct {
    suite: Suite,
    /// The traffic secret, for the next key of a key update.
    secret: [48]u8,
    key: [32]u8,
    iv: [12]u8,
    seq: u64 = 0,
    /// The expanded AES-GCM key (aead.zig).
    gcm: fast.Gcm = undefined,
    /// The ChaCha20-Poly1305 key (aead.zig).
    cc: fast.ChaCha = undefined,

    pub fn init(suite: Suite, secret: []const u8) Protection {
        std.debug.assert(secret.len == suite.hashLen());
        var p: Protection = .{ .suite = suite, .secret = @splat(0), .key = @splat(0), .iv = undefined };
        @memcpy(p.secret[0..secret.len], secret);
        p.derive();
        return p;
    }

    fn derive(p: *Protection) void {
        switch (p.suite) {
            .aes_256_gcm_sha384 => schedule.Sha384.trafficKey(p.key[0..32], &p.iv, p.secret[0..48].*),
            else => |s| schedule.Sha256.trafficKey(p.key[0..s.keyLen()], &p.iv, p.secret[0..32].*),
        }
        switch (p.suite) {
            .aes_128_gcm_sha256, .aes_256_gcm_sha384 => |s| p.gcm = .init(p.key[0..s.keyLen()]),
            .chacha20_poly1305_sha256 => p.cc = .init(&p.key),
        }
    }

    /// The next key of a KeyUpdate (section 4.6.3). The count starts
    /// again at zero.
    pub fn update(p: *Protection) void {
        switch (p.suite) {
            .aes_256_gcm_sha384 => p.secret = schedule.Sha384.update(p.secret[0..48].*),
            else => p.secret[0..32].* = schedule.Sha256.update(p.secret[0..32].*),
        }
        p.seq = 0;
        p.derive();
    }

    /// True when the key is near its record limit.
    pub fn needsUpdate(p: *const Protection) bool {
        return p.seq >= p.suite.recordLimit() -| (1 << 20);
    }

    fn nonce(p: *const Protection) [12]u8 {
        var n = p.iv;
        var s: [8]u8 = undefined;
        std.mem.writeInt(u64, &s, p.seq, .big);
        for (n[4..], s) |*a, b| a.* ^= b;
        return n;
    }

    /// Seals `content` of type `ct` with `padding` zero bytes into `out`,
    /// and gives the record.
    pub fn seal(p: *Protection, out: []u8, ct: ContentType, content: []const u8, padding: usize) Error![]u8 {
        if (content.len > max_plaintext) return error.RecordOverflow;
        const inner_len = content.len + 1 + padding;
        if (inner_len > max_plaintext + 1) return error.RecordOverflow;
        const len = inner_len + tag_len;
        if (out.len < header_len + len) return error.NoSpace;
        if (p.seq >= p.suite.recordLimit()) return error.KeyLimit;
        const hdr = out[0..header_len];
        (Header{ .type = .application_data, .version = 0x0303, .len = @intCast(len) }).write(hdr);
        const inner = out[header_len..][0..inner_len];
        const tag = out[header_len + inner_len ..][0..tag_len];
        const n = p.nonce();
        // AES-GCM reads the content where it is, and the content type and
        // padding from `extra`, when the content does not overlap the
        // record or starts at the place of its content.
        const apart = content.ptr == inner.ptr or @intFromPtr(content.ptr) + content.len <= @intFromPtr(out.ptr) or
            @intFromPtr(out.ptr) + out.len <= @intFromPtr(content.ptr);
        if (apart and padding < fast.Gcm.max_extra) {
            var extra: [fast.Gcm.max_extra]u8 = @splat(0);
            extra[0] = @backingInt(ct);
            if (p.suite == .chacha20_poly1305_sha256)
                p.cc.sealExtra(inner, tag, content, extra[0 .. 1 + padding], hdr, &n)
            else
                p.gcm.sealExtra(inner, tag, content, extra[0 .. 1 + padding], hdr, &n);
            p.seq += 1;
            return out[0 .. header_len + len];
        }
        @memmove(inner[0..content.len], content);
        inner[content.len] = @backingInt(ct);
        @memset(inner[content.len + 1 ..], 0);
        switch (p.suite) {
            .aes_128_gcm_sha256, .aes_256_gcm_sha384 => p.gcm.seal(inner, tag, inner, hdr, &n),
            .chacha20_poly1305_sha256 => p.cc.seal(inner, tag, inner, hdr, &n),
        }
        p.seq += 1;
        return out[0 .. header_len + len];
    }

    /// Opens one whole protected record into `out`, which needs the
    /// length of the fragment less the tag.
    pub fn open(p: *Protection, out: []u8, record: []const u8) Error!Plain {
        const inner_len = try p.check(record);
        if (out.len < inner_len) return error.NoSpace;
        return p.openTo(out[0..inner_len], record);
    }

    /// Opens one whole protected record in place: the plaintext goes
    /// over the ciphertext in `record`, and the data of the result is a
    /// slice of `record`. It saves the copy of `open` to a second
    /// buffer.
    pub fn openInPlace(p: *Protection, record: []u8) Error!Plain {
        const inner_len = try p.check(record);
        return p.openTo(record[header_len..][0..inner_len], record);
    }

    /// The checks of the header and the count, and the length of the
    /// plaintext with the content type and the padding.
    fn check(p: *const Protection, record: []const u8) Error!usize {
        if (record.len < header_len) return error.DecodeError;
        const h = Header.parse(record[0..header_len]);
        if (h.type != .application_data) return error.UnexpectedMessage;
        if (h.len > max_ciphertext) return error.RecordOverflow;
        if (record.len != header_len + h.len) return error.DecodeError;
        if (h.len < tag_len + 1) return error.BadRecordMac;
        if (p.seq >= p.suite.recordLimit()) return error.KeyLimit;
        return h.len - tag_len;
    }

    /// Decrypts into `inner`, which is the place of the ciphertext in
    /// `record` or a buffer apart from it.
    fn openTo(p: *Protection, inner: []u8, record: []const u8) Error!Plain {
        const c = record[header_len..][0..inner.len];
        const tag = record[header_len + inner.len ..][0..tag_len].*;
        const ad = record[0..header_len].*;
        const n = p.nonce();
        (switch (p.suite) {
            .aes_128_gcm_sha256, .aes_256_gcm_sha384 => p.gcm.open(inner, c, &tag, &ad, &n),
            .chacha20_poly1305_sha256 => p.cc.open(inner, c, &tag, &ad, &n),
        }) catch return error.BadRecordMac;
        p.seq += 1;
        const end = contentEnd(inner);
        if (end == 0) return error.UnexpectedMessage;
        const data = inner[0 .. end - 1];
        if (data.len > max_plaintext) return error.RecordOverflow;
        const ct: ContentType = @fromBackingInt(@intCast(inner[end - 1]));
        switch (ct) {
            .handshake, .alert => if (data.len == 0) return error.UnexpectedMessage,
            .application_data => {},
            else => return error.UnexpectedMessage,
        }
        return .{ .type = ct, .data = data };
    }
};

/// One more than the place of the last byte that is not zero, or 0. The
/// loop reads each byte, and masks replace the branches on the values.
/// It compares 64 bytes at a time with vectors, and the bit mask of the
/// bytes that are not zero gives the last place in the 64.
fn contentEnd(inner: []const u8) usize {
    const n = 64;
    const Vn = @Vector(n, u8);
    var end: usize = 0;
    var i: usize = 0;
    while (i + n <= inner.len) : (i += n) {
        const v: Vn = inner[i..][0..n].*;
        const bits: u64 = @bitCast(v != @as(Vn, @splat(0)));
        const any: usize = @intFromBool(bits != 0);
        const mask = 0 -% any;
        const here = i + n - @as(usize, @clz(bits));
        end = (here & mask) | (end & ~mask);
    }
    for (inner[i..], i + 1..) |b, j| {
        const nz: usize = @intFromBool(b != 0);
        const mask = 0 -% nz;
        end = (j & mask) | (end & ~mask);
    }
    return end;
}

test "contentEnd" {
    try std.testing.expectEqual(@as(usize, 0), contentEnd(&.{ 0, 0, 0 }));
    try std.testing.expectEqual(@as(usize, 2), contentEnd(&.{ 5, 22, 0, 0 }));
    try std.testing.expectEqual(@as(usize, 1), contentEnd(&.{23}));
    var buf: [100]u8 = @splat(0);
    try std.testing.expectEqual(@as(usize, 0), contentEnd(&buf));
    for (0..buf.len) |k| {
        buf[k] = 1;
        try std.testing.expectEqual(k + 1, contentEnd(&buf));
        if (k > 0) try std.testing.expectEqual(k + 1, contentEnd(buf[k - 1 ..]) + k - 1);
    }
}

fn testProtection(suite: Suite) Protection {
    const secret: [48]u8 = @splat(7);
    return .init(suite, secret[0..suite.hashLen()]);
}

test "seal and open with padding for each suite" {
    for ([_]Suite{ .aes_128_gcm_sha256, .aes_256_gcm_sha384, .chacha20_poly1305_sha256 }) |suite| {
        var w = testProtection(suite);
        var r = testProtection(suite);
        var buf: [max_record]u8 = undefined;
        var out: [max_ciphertext]u8 = undefined;
        for (0..3) |i| {
            const rec = try w.seal(&buf, .handshake, "hello", i * 10);
            try std.testing.expectEqual(@as(usize, header_len + 5 + 1 + i * 10 + tag_len), rec.len);
            const got = try r.open(&out, rec);
            try std.testing.expectEqual(ContentType.handshake, got.type);
            try std.testing.expectEqualStrings("hello", got.data);
        }
    }
}

test "a record sealed from apart and from in place has the same bytes" {
    var data: [3000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 7 +% 1);
    for ([_]Suite{ .aes_128_gcm_sha256, .aes_256_gcm_sha384, .chacha20_poly1305_sha256 }) |suite| {
        for ([_]usize{ 0, 1, 15, 16, 127, 128, 129, 1000, 3000 }) |len| for ([_]usize{ 0, 1, 254, 255, 256, 300 }) |pad| {
            var a = testProtection(suite);
            var b = testProtection(suite);
            var buf1: [max_record]u8 = undefined;
            var buf2: [max_record]u8 = undefined;
            const r1 = try a.seal(&buf1, .application_data, data[0..len], pad);
            @memcpy(buf2[header_len..][0..len], data[0..len]);
            const r2 = try b.seal(&buf2, .application_data, buf2[header_len..][0..len], pad);
            try std.testing.expectEqualSlices(u8, r1, r2);
            var r = testProtection(suite);
            var out: [max_ciphertext]u8 = undefined;
            const got = try r.open(&out, r1);
            try std.testing.expectEqualSlices(u8, data[0..len], got.data);
        };
    }
}

test "openInPlace gives the data of open in the record buffer" {
    for ([_]Suite{ .aes_128_gcm_sha256, .aes_256_gcm_sha384, .chacha20_poly1305_sha256 }) |suite| {
        var w = testProtection(suite);
        var r1 = testProtection(suite);
        var r2 = testProtection(suite);
        var data: [3000]u8 = undefined;
        for (&data, 0..) |*b, i| b.* = @truncate(i *% 13 +% 5);
        for ([_]usize{ 1, 16, 600, 3000 }) |len| {
            var buf: [max_record]u8 = undefined;
            const rec = try w.seal(&buf, .application_data, data[0..len], 7);
            var out: [max_ciphertext]u8 = undefined;
            const a = try r1.open(&out, rec);
            const b = try r2.openInPlace(rec);
            try std.testing.expectEqualSlices(u8, a.data, b.data);
            try std.testing.expectEqual(@intFromPtr(rec.ptr) + header_len, @intFromPtr(b.data.ptr));
        }
        // A bad tag.
        var buf: [max_record]u8 = undefined;
        const rec = try w.seal(&buf, .application_data, "x", 0);
        rec[rec.len - 1] ^= 1;
        try std.testing.expectError(error.BadRecordMac, r2.openInPlace(rec));
    }
}

test "a bad tag, a bad type, and bad lengths give their alerts" {
    var w = testProtection(.aes_128_gcm_sha256);
    var buf: [max_record + 1]u8 = undefined;
    var out: [max_record]u8 = undefined;
    const rec = try w.seal(&buf, .application_data, "data", 0);
    var r = testProtection(.aes_128_gcm_sha256);
    rec[rec.len - 1] ^= 1;
    try std.testing.expectError(error.BadRecordMac, r.open(&out, rec));
    try std.testing.expectEqual(Alert.bad_record_mac, alertOf(error.BadRecordMac));
    rec[rec.len - 1] ^= 1;
    rec[0] = 22;
    try std.testing.expectError(error.UnexpectedMessage, r.open(&out, rec));
    rec[0] = 23;
    // A fragment above 2^14 + 256 bytes.
    @memset(&buf, 0);
    (Header{ .type = .application_data, .version = 0x0303, .len = max_ciphertext + 1 }).write(buf[0..header_len]);
    try std.testing.expectError(error.RecordOverflow, r.open(&out, buf[0 .. header_len + max_ciphertext + 1]));
    // Content above 2^14 bytes.
    const big: [max_plaintext + 1]u8 = @splat(1);
    try std.testing.expectError(error.RecordOverflow, w.seal(&buf, .application_data, &big, 0));
    try std.testing.expectError(error.RecordOverflow, w.seal(&buf, .application_data, big[0..max_plaintext], 1));
    try std.testing.expectError(error.RecordOverflow, writePlain(&buf, .handshake, 0x0303, &big));
    try std.testing.expectError(error.RecordOverflow, checkPlain(.{ .type = .handshake, .version = 0x0303, .len = max_plaintext + 1 }));
}

test "a protected record of all zeros and an empty handshake give unexpected_message" {
    var w = testProtection(.chacha20_poly1305_sha256);
    var r = testProtection(.chacha20_poly1305_sha256);
    var buf: [max_record]u8 = undefined;
    var out: [max_record]u8 = undefined;
    // Content type 0: the scan finds no type.
    const zero = try w.seal(&buf, .invalid, "", 4);
    try std.testing.expectError(error.UnexpectedMessage, r.open(&out, zero));
    const empty = try w.seal(&buf, .handshake, "", 0);
    try std.testing.expectError(error.UnexpectedMessage, r.open(&out, empty));
    const alert = try w.seal(&buf, .alert, "", 3);
    try std.testing.expectError(error.UnexpectedMessage, r.open(&out, alert));
    try std.testing.expectError(error.UnexpectedMessage, checkPlain(.{ .type = .invalid, .version = 0x0303, .len = 2 }));
    try std.testing.expectError(error.UnexpectedMessage, checkPlain(.{ .type = .handshake, .version = 0x0303, .len = 0 }));
}

test "a key update changes the key and starts the count at zero" {
    var w = testProtection(.aes_256_gcm_sha384);
    var r = testProtection(.aes_256_gcm_sha384);
    var buf: [max_record]u8 = undefined;
    var out: [max_record]u8 = undefined;
    _ = try r.open(&out, try w.seal(&buf, .application_data, "a", 0));
    const old = w.key;
    w.update();
    try std.testing.expect(!std.mem.eql(u8, &old, &w.key));
    try std.testing.expectEqual(@as(u64, 0), w.seq);
    const rec = try w.seal(&buf, .application_data, "b", 0);
    var stale = r;
    try std.testing.expectError(error.BadRecordMac, stale.open(&out, rec));
    r.update();
    try std.testing.expectEqualStrings("b", (try r.open(&out, rec)).data);
}

test "the record limit of AES-GCM" {
    var w = testProtection(.aes_128_gcm_sha256);
    var buf: [max_record]u8 = undefined;
    w.seq = Suite.aes_128_gcm_sha256.recordLimit() - (1 << 20);
    try std.testing.expect(w.needsUpdate());
    w.seq = Suite.aes_128_gcm_sha256.recordLimit();
    try std.testing.expectError(error.KeyLimit, w.seal(&buf, .application_data, "x", 0));
    var c = testProtection(.chacha20_poly1305_sha256);
    c.seq = 1 << 40;
    try std.testing.expect(!c.needsUpdate());
}

test "the AEAD vector of RFC 8439 section 2.8.2" {
    const C = aead.chacha_poly.ChaCha20Poly1305;
    var key: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    var nonce: [12]u8 = undefined;
    _ = try std.fmt.hexToBytes(&nonce, "070000004041424344454647");
    var ad: [12]u8 = undefined;
    _ = try std.fmt.hexToBytes(&ad, "50515253c0c1c2c3c4c5c6c7");
    const m = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    var c: [m.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    C.encrypt(&c, &tag, m, &ad, nonce, key);
    var want_tag: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want_tag, "1ae10b594f09e26a7e902ecbd0600691");
    try std.testing.expectEqualSlices(u8, &want_tag, &tag);
    var want_head: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want_head, "d31a8d34648e60db7b86afbc53ef7ec2");
    try std.testing.expectEqualSlices(u8, &want_head, c[0..16]);
}

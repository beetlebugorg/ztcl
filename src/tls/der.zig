//! A reader of DER (X.690) for certificates and keys from the network.
//!
//! Each read checks the length against the bytes that are left before
//! it reads the bytes. The reader accepts the DER forms only: a tag of
//! one byte, the shortest form of each length, and no indefinite
//! length. `std.crypto.Certificate.der.Element.parse` of Zig 0.17.0
//! has no bounds checks, so the TLS code does not use it on bytes from
//! a peer.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Error = error{BadDer};

pub const tag = struct {
    pub const boolean: u8 = 0x01;
    pub const integer: u8 = 0x02;
    pub const bit_string: u8 = 0x03;
    pub const octet_string: u8 = 0x04;
    pub const null_: u8 = 0x05;
    pub const oid: u8 = 0x06;
    pub const utf8_string: u8 = 0x0c;
    pub const printable_string: u8 = 0x13;
    pub const ia5_string: u8 = 0x16;
    pub const utc_time: u8 = 0x17;
    pub const generalized_time: u8 = 0x18;
    pub const sequence: u8 = 0x30;
    pub const set: u8 = 0x31;

    /// A context-specific tag: `[n]` with the constructed bit.
    pub fn explicit(n: u5) u8 {
        return 0xa0 | @as(u8, n);
    }

    /// A context-specific tag: `[n]` with no constructed bit.
    pub fn implicit(n: u5) u8 {
        return 0x80 | @as(u8, n);
    }
};

pub const Element = struct {
    tag: u8,
    /// The contents.
    body: []const u8,
    /// The tag, the length, and the contents.
    raw: []const u8,
};

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn done(r: *const Reader) bool {
        return r.pos == r.bytes.len;
    }

    pub fn peekTag(r: *const Reader) ?u8 {
        return if (r.pos < r.bytes.len) r.bytes[r.pos] else null;
    }

    pub fn next(r: *Reader) Error!Element {
        const start = r.pos;
        const rest = r.bytes[start..];
        if (rest.len < 2) return error.BadDer;
        const t = rest[0];
        // The high tag number form (a low tag of 31) is not in X.509.
        if (t & 0x1f == 0x1f) return error.BadDer;
        var i: usize = 2;
        var len: usize = rest[1];
        if (len & 0x80 != 0) {
            const n = len & 0x7f;
            // 0x80 is the indefinite length of BER. Four bytes of length
            // are more than any certificate needs.
            if (n == 0 or n > 4 or rest.len < 2 + n) return error.BadDer;
            len = 0;
            for (rest[2..][0..n]) |b| len = (len << 8) | b;
            // The shortest form: no zero byte in front, and no long form
            // for a length below 128.
            if (rest[2] == 0 or len < 0x80) return error.BadDer;
            i += n;
        }
        if (len > rest.len - i) return error.BadDer;
        r.pos = start + i + len;
        return .{ .tag = t, .body = rest[i..][0..len], .raw = rest[0 .. i + len] };
    }

    /// The next element, which must have the tag `t`.
    pub fn expect(r: *Reader, t: u8) Error!Element {
        const e = try r.next();
        if (e.tag != t) return error.BadDer;
        return e;
    }

    /// The next element if it has the tag `t`.
    pub fn optional(r: *Reader, t: u8) Error!?Element {
        if (r.peekTag() != t) return null;
        return try r.next();
    }

    /// A reader of the contents of the next element of tag `t`.
    pub fn enter(r: *Reader, t: u8) Error!Reader {
        return .init((try r.expect(t)).body);
    }
};

/// The one element of `bytes`, of the tag `t`, with no bytes after it.
pub fn one(bytes: []const u8, t: u8) Error!Element {
    var r = Reader.init(bytes);
    const e = try r.expect(t);
    if (!r.done()) return error.BadDer;
    return e;
}

/// The bytes of a BIT STRING with no unused bits.
pub fn bitStringBytes(e: Element) Error![]const u8 {
    if (e.tag != tag.bit_string or e.body.len == 0 or e.body[0] != 0) return error.BadDer;
    return e.body[1..];
}

/// A DER BOOLEAN: one byte, 0x00 or 0xff.
pub fn boolean(e: Element) Error!bool {
    if (e.tag != tag.boolean or e.body.len != 1) return error.BadDer;
    return switch (e.body[0]) {
        0x00 => false,
        0xff => true,
        else => error.BadDer,
    };
}

/// A non-negative INTEGER that fits in a u32, in the shortest form.
pub fn smallUint(e: Element) Error!u32 {
    const b = try integerBytes(e);
    if (b.len > 0 and b[0] & 0x80 != 0) return error.BadDer;
    var v: u64 = 0;
    for (b) |x| {
        v = (v << 8) | x;
        if (v > std.math.maxInt(u32)) return error.BadDer;
    }
    return @intCast(v);
}

/// The bytes of an INTEGER in the shortest form (X.690 8.3.2).
pub fn integerBytes(e: Element) Error![]const u8 {
    if (e.tag != tag.integer or e.body.len == 0) return error.BadDer;
    const b = e.body;
    if (b.len > 1 and ((b[0] == 0 and b[1] & 0x80 == 0) or (b[0] == 0xff and b[1] & 0x80 != 0))) return error.BadDer;
    return b;
}

test "the reader refuses a long form for a short length and a length past the end" {
    var r = Reader.init(&.{ 0x04, 0x81, 0x05, 1, 2, 3, 4, 5 });
    try std.testing.expectError(error.BadDer, r.next());
    r = Reader.init(&.{ 0x04, 0x03, 1, 2 });
    try std.testing.expectError(error.BadDer, r.next());
    r = Reader.init(&.{ 0x04, 0x80 });
    try std.testing.expectError(error.BadDer, r.next());
    r = Reader.init(&.{ 0x04, 0x02, 1, 2 });
    const e = try r.next();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, e.body);
    try std.testing.expect(r.done());
}

test "integers in the shortest form" {
    try std.testing.expectEqual(@as(u32, 128), try smallUint(.{ .tag = tag.integer, .body = &.{ 0, 0x80 }, .raw = "" }));
    try std.testing.expectError(error.BadDer, smallUint(.{ .tag = tag.integer, .body = &.{ 0, 0x7f }, .raw = "" }));
    try std.testing.expectError(error.BadDer, smallUint(.{ .tag = tag.integer, .body = &.{0x80}, .raw = "" }));
}

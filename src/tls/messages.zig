//! The framing of TLS 1.3 handshake messages (RFC 8446 section 4), for
//! the client and the server.
//!
//! `Reader` reads the vectors of the presentation language: each
//! length comes before its bytes, and each read checks the length
//! against the bytes that are left. `Builder` writes a message into a
//! fixed buffer, with the lengths of nested vectors filled in at the
//! end of each vector. `Assembler` joins the handshake messages of one
//! or more records, and gives each whole message with its header.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Error = error{ DecodeError, NoSpace, MessageTooLong };

pub const Type = enum(u8) {
    client_hello = 1,
    server_hello = 2,
    new_session_ticket = 4,
    end_of_early_data = 5,
    encrypted_extensions = 8,
    certificate = 11,
    certificate_request = 13,
    certificate_verify = 15,
    finished = 20,
    key_update = 24,
    message_hash = 254,
    _,
};

pub const ExtType = struct {
    pub const server_name: u16 = 0;
    pub const supported_groups: u16 = 10;
    pub const signature_algorithms: u16 = 13;
    pub const alpn: u16 = 16;
    pub const pre_shared_key: u16 = 41;
    pub const early_data: u16 = 42;
    pub const supported_versions: u16 = 43;
    pub const cookie: u16 = 44;
    pub const psk_key_exchange_modes: u16 = 45;
    pub const certificate_authorities: u16 = 47;
    pub const signature_algorithms_cert: u16 = 50;
    pub const key_share: u16 = 51;
};

pub const Reader = struct {
    b: []const u8,
    pos: usize = 0,

    pub fn init(b: []const u8) Reader {
        return .{ .b = b };
    }

    pub fn done(r: *const Reader) bool {
        return r.pos == r.b.len;
    }

    pub fn left(r: *const Reader) usize {
        return r.b.len - r.pos;
    }

    pub fn bytes(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.left()) return error.DecodeError;
        defer r.pos += n;
        return r.b[r.pos..][0..n];
    }

    pub fn int(r: *Reader, comptime T: type) Error!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        return std.mem.readInt(T, (try r.bytes(n))[0..n], .big);
    }

    /// A vector with a length of `T` in front, of `min` to `max` bytes.
    pub fn vec(r: *Reader, comptime T: type, min: usize, max: usize) Error![]const u8 {
        const n = try r.int(T);
        if (n < min or n > max) return error.DecodeError;
        return r.bytes(n);
    }

    /// A reader of a vector with a length of `T` in front.
    pub fn sub(r: *Reader, comptime T: type, min: usize, max: usize) Error!Reader {
        return .init(try r.vec(T, min, max));
    }

    pub fn end(r: *const Reader) Error!void {
        if (!r.done()) return error.DecodeError;
    }
};

pub const Builder = struct {
    buf: []u8,
    len: usize = 0,
    /// The places of the open length fields, and their sizes.
    open: [8]struct { at: usize, size: u8 } = undefined,
    depth: usize = 0,

    pub fn init(buf: []u8) Builder {
        return .{ .buf = buf };
    }

    pub fn slice(b: *const Builder) []u8 {
        return b.buf[0..b.len];
    }

    pub fn put(b: *Builder, data: []const u8) Error!void {
        if (data.len > b.buf.len - b.len) return error.NoSpace;
        @memcpy(b.buf[b.len..][0..data.len], data);
        b.len += data.len;
    }

    pub fn int(b: *Builder, comptime T: type, v: T) Error!void {
        var tmp: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .big);
        try b.put(&tmp);
    }

    /// Opens a vector with a length field of `size` bytes.
    pub fn begin(b: *Builder, size: u8) Error!void {
        if (b.depth == b.open.len) return error.NoSpace;
        b.open[b.depth] = .{ .at = b.len, .size = size };
        b.depth += 1;
        var zero: [3]u8 = @splat(0);
        try b.put(zero[0..size]);
    }

    /// Closes the last vector and writes its length.
    pub fn finish(b: *Builder) Error!void {
        b.depth -= 1;
        const o = b.open[b.depth];
        const n = b.len - o.at - o.size;
        if (n >> @intCast(8 * @as(usize, o.size)) != 0) return error.MessageTooLong;
        var i: usize = 0;
        while (i < o.size) : (i += 1) b.buf[o.at + i] = @truncate(n >> @intCast(8 * (o.size - 1 - i)));
    }

    pub fn vec(b: *Builder, size: u8, data: []const u8) Error!void {
        try b.begin(size);
        try b.put(data);
        try b.finish();
    }
};

/// The most bytes of one handshake message: a chain of 10 certificates
/// and the rest of the flight fit in it (docs/dev/stdlib.md).
pub const max_message = 1 << 16;

pub const Assembler = struct {
    buf: [max_message + 4]u8 = undefined,
    len: usize = 0,
    /// The start of the next message in `buf`.
    start: usize = 0,

    /// Adds the bytes of a handshake record.
    pub fn add(a: *Assembler, data: []const u8) Error!void {
        if (a.start > 0) {
            std.mem.copyForwards(u8, a.buf[0 .. a.len - a.start], a.buf[a.start..a.len]);
            a.len -= a.start;
            a.start = 0;
        }
        if (data.len > a.buf.len - a.len) return error.MessageTooLong;
        @memcpy(a.buf[a.len..][0..data.len], data);
        a.len += data.len;
    }

    /// The next whole message, with its header of 4 bytes, or null. The
    /// bytes are valid to the next `add`.
    pub fn next(a: *Assembler) Error!?[]const u8 {
        const rest = a.buf[a.start..a.len];
        if (rest.len < 4) return null;
        const n = std.mem.readInt(u24, rest[1..4], .big);
        if (n > max_message) return error.MessageTooLong;
        if (rest.len < 4 + n) return null;
        a.start += 4 + n;
        return rest[0 .. 4 + n];
    }

    /// True when no part of a message waits for more bytes. A change of
    /// keys must come at the end of a message (RFC 8446 section 5.1).
    pub fn empty(a: *const Assembler) bool {
        return a.start == a.len;
    }
};

test "builder lengths and reader bounds" {
    var buf: [32]u8 = undefined;
    var b = Builder.init(&buf);
    try b.begin(2);
    try b.int(u8, 7);
    try b.vec(1, "ab");
    try b.finish();
    try std.testing.expectEqualSlices(u8, &.{ 0, 4, 7, 2, 'a', 'b' }, b.slice());
    var r = Reader.init(b.slice());
    var s = try r.sub(u16, 0, 100);
    try std.testing.expectEqual(@as(u8, 7), try s.int(u8));
    try std.testing.expectEqualStrings("ab", try s.vec(u8, 1, 2));
    try s.end();
    var bad = Reader.init(&.{ 0, 9, 1 });
    try std.testing.expectError(error.DecodeError, bad.vec(u16, 0, 100));
}

test "assembler joins and splits messages" {
    var a: Assembler = .{};
    try a.add(&.{ 20, 0, 0, 2, 1 });
    try std.testing.expect((try a.next()) == null);
    try a.add(&.{ 2, 20, 0, 0, 0 });
    try std.testing.expectEqualSlices(u8, &.{ 20, 0, 0, 2, 1, 2 }, (try a.next()).?);
    try std.testing.expectEqualSlices(u8, &.{ 20, 0, 0, 0 }, (try a.next()).?);
    try std.testing.expect(a.empty());
}

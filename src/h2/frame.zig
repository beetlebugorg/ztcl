//! The frames of HTTP/2 (RFC 9113 section 4 and 6).
//!
//! A frame is a header of 9 bytes (the length of 24 bits, the type, the
//! flags, and the stream id of 31 bits) and a payload. `Header.parse`
//! reads a header in place, and the write functions put a whole frame
//! into a buffer of the caller.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const header_len = 9;
/// The client preface (section 3.4).
pub const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
/// The smallest SETTINGS_MAX_FRAME_SIZE, and the default.
pub const default_max_frame = 16384;
pub const default_window = 65535;

pub const Type = enum(u8) {
    data = 0,
    headers = 1,
    priority = 2,
    rst_stream = 3,
    settings = 4,
    push_promise = 5,
    ping = 6,
    goaway = 7,
    window_update = 8,
    continuation = 9,
    priority_update = 16,
    _,
};

pub const Flags = struct {
    pub const end_stream = 0x1;
    pub const ack = 0x1;
    pub const end_headers = 0x4;
    pub const padded = 0x8;
    pub const priority = 0x20;
};

/// The error codes of section 7.
pub const Code = enum(u32) {
    no_error = 0,
    protocol_error = 1,
    internal_error = 2,
    flow_control_error = 3,
    settings_timeout = 4,
    stream_closed = 5,
    frame_size_error = 6,
    refused_stream = 7,
    cancel = 8,
    compression_error = 9,
    connect_error = 10,
    enhance_your_calm = 11,
    inadequate_security = 12,
    http_1_1_required = 13,
    _,
};

pub const Setting = enum(u16) {
    header_table_size = 1,
    enable_push = 2,
    max_concurrent_streams = 3,
    initial_window_size = 4,
    max_frame_size = 5,
    max_header_list_size = 6,
    _,
};

pub const Header = struct {
    len: u24,
    type: Type,
    flags: u8,
    stream: u31,

    pub fn parse(b: *const [header_len]u8) Header {
        return .{
            .len = std.mem.readInt(u24, b[0..3], .big),
            .type = @fromBackingInt(@intCast(b[3])),
            .flags = b[4],
            .stream = @truncate(std.mem.readInt(u32, b[5..9], .big)),
        };
    }

    pub fn write(h: Header, b: *[header_len]u8) void {
        std.mem.writeInt(u24, b[0..3], h.len, .big);
        b[3] = @backingInt(h.type);
        b[4] = h.flags;
        std.mem.writeInt(u32, b[5..9], h.stream, .big);
    }
};

/// Writes a frame with `payload` into `out` and gives its length.
pub fn write(out: []u8, t: Type, flags: u8, stream: u31, payload: []const u8) usize {
    (Header{ .len = @intCast(payload.len), .type = t, .flags = flags, .stream = stream }).write(out[0..header_len]);
    @memcpy(out[header_len..][0..payload.len], payload);
    return header_len + payload.len;
}

/// A SETTINGS frame of pairs.
pub fn writeSettings(out: []u8, pairs: []const struct { Setting, u32 }) usize {
    var p: [6 * 8]u8 = undefined;
    for (pairs, 0..) |kv, i| {
        std.mem.writeInt(u16, p[6 * i ..][0..2], @backingInt(kv[0]), .big);
        std.mem.writeInt(u32, p[6 * i + 2 ..][0..4], kv[1], .big);
    }
    return write(out, .settings, 0, 0, p[0 .. 6 * pairs.len]);
}

pub fn writeWindowUpdate(out: []u8, stream: u31, inc: u31) usize {
    var p: [4]u8 = undefined;
    std.mem.writeInt(u32, &p, inc, .big);
    return write(out, .window_update, 0, stream, &p);
}

pub fn writeRst(out: []u8, stream: u31, code: Code) usize {
    var p: [4]u8 = undefined;
    std.mem.writeInt(u32, &p, @backingInt(code), .big);
    return write(out, .rst_stream, 0, stream, &p);
}

pub fn writeGoaway(out: []u8, last: u31, code: Code) usize {
    var p: [8]u8 = undefined;
    std.mem.writeInt(u32, p[0..4], last, .big);
    std.mem.writeInt(u32, p[4..8], @backingInt(code), .big);
    return write(out, .goaway, 0, 0, &p);
}

test "a header round trip" {
    var b: [header_len]u8 = undefined;
    const h: Header = .{ .len = 16384, .type = .headers, .flags = Flags.end_headers | Flags.end_stream, .stream = 0x7fffffff };
    h.write(&b);
    try std.testing.expectEqual(h, Header.parse(&b));
    // The reserved bit of the stream id is ignored on read.
    b[5] |= 0x80;
    try std.testing.expectEqual(h.stream, Header.parse(&b).stream);
}

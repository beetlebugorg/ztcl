//! The tests of `conn.zig` with a client in memory.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");
const conn = @import("conn.zig");
const testing = std.testing;
const gpa = testing.allocator;

var fake_now: u64 = 0;
fn clock() u64 {
    return fake_now;
}

/// Answers each request with 200 and the path as the body, or with the
/// request body for a POST.
fn echo(_: ?*anyopaque, c: *conn.Conn, req: *const conn.Request) void {
    const body = if (std.mem.eql(u8, req.method, "POST")) req.body else req.path;
    c.respond(req.stream, 200, &.{.{ .name = "content-type", .value = "text/plain" }}, body) catch unreachable;
}

const Client = struct {
    enc: hpack.Encoder,
    dec: hpack.Decoder,
    buf: std.ArrayList(u8) = .empty,

    fn init() !Client {
        return .{ .enc = try .init(gpa, 4096), .dec = try .init(gpa, 4096, 1 << 16) };
    }

    fn deinit(cl: *Client) void {
        cl.enc.deinit(gpa);
        cl.dec.deinit(gpa);
        cl.buf.deinit(gpa);
    }

    fn raw(cl: *Client, t: frame.Type, flags: u8, stream: u31, payload: []const u8) !void {
        var h: [frame.header_len]u8 = undefined;
        (frame.Header{ .len = @intCast(payload.len), .type = t, .flags = flags, .stream = stream }).write(&h);
        try cl.buf.appendSlice(gpa, &h);
        try cl.buf.appendSlice(gpa, payload);
    }

    fn start(cl: *Client) !void {
        try cl.buf.appendSlice(gpa, frame.preface);
        try cl.raw(.settings, 0, 0, "");
    }

    fn get(cl: *Client, stream: u31, path: []const u8, end: bool) !void {
        var blk: [512]u8 = undefined;
        const n = try cl.enc.encode(&blk, &.{
            .{ .name = ":method", .value = if (end) "GET" else "POST" },
            .{ .name = ":scheme", .value = "http" },
            .{ .name = ":authority", .value = "localhost" },
            .{ .name = ":path", .value = path },
        });
        try cl.raw(.headers, frame.Flags.end_headers | @as(u8, if (end) frame.Flags.end_stream else 0), stream, blk[0..n]);
    }
};

const Seen = struct {
    status: [8]u16 = @splat(0),
    body: [8]std.ArrayList(u8) = @splat(.empty),
    ended: [8]bool = @splat(false),
    goaway: ?frame.Code = null,
    rst: ?frame.Code = null,
    settings_ack: bool = false,

    fn deinit(s: *Seen) void {
        for (&s.body) |*b| b.deinit(gpa);
    }
};

/// Reads the frames of the server.
fn read(cl: *Client, out: []const u8, seen: *Seen) !void {
    var pos: usize = 0;
    while (pos + frame.header_len <= out.len) {
        const h = frame.Header.parse(out[pos..][0..frame.header_len]);
        const p = out[pos + frame.header_len ..][0..h.len];
        pos += frame.header_len + h.len;
        const k = h.stream / 2;
        switch (h.type) {
            .headers => {
                var scratch: [256]u8 = undefined;
                var b = cl.dec.block(p, &scratch);
                while (try b.next()) |f| {
                    if (std.mem.eql(u8, f.name, ":status")) seen.status[k] = try std.fmt.parseInt(u16, f.value, 10);
                }
                if (h.flags & frame.Flags.end_stream != 0) seen.ended[k] = true;
            },
            .data => {
                try seen.body[k].appendSlice(gpa, p);
                if (h.flags & frame.Flags.end_stream != 0) seen.ended[k] = true;
            },
            .goaway => seen.goaway = @fromBackingInt(@intCast(std.mem.readInt(u32, p[4..8], .big))),
            .rst_stream => seen.rst = @fromBackingInt(@intCast(std.mem.readInt(u32, p[0..4], .big))),
            .settings => if (h.flags & frame.Flags.ack != 0) {
                seen.settings_ack = true;
            },
            else => {},
        }
    }
    try testing.expectEqual(out.len, pos);
}

fn run(cl: *Client, c: *conn.Conn, seen: *Seen) !void {
    const n = try c.feed(cl.buf.items);
    try testing.expectEqual(cl.buf.items.len, n);
    cl.buf.clearRetainingCapacity();
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(gpa);
    // Half the pieces through `pendingVecs`, half through `pending`.
    var iov: [3]std.posix.iovec_const = undefined;
    var turn = false;
    while (c.pending().len > 0) : (turn = !turn) {
        if (turn) {
            const nv = c.pendingVecs(&iov);
            var total: usize = 0;
            for (iov[0..nv]) |v| {
                try all.appendSlice(gpa, v.base[0..v.len]);
                total += v.len;
            }
            c.sent(total);
        } else {
            const p = c.pending();
            try all.appendSlice(gpa, p);
            c.sent(p.len);
        }
    }
    try read(cl, all.items, seen);
}

test "GET requests on three streams" {
    var c = try conn.Conn.init(gpa, .{}, echo, null, clock);
    defer c.deinit();
    var cl = try Client.init();
    defer cl.deinit();
    var seen: Seen = .{};
    defer seen.deinit();
    try cl.start();
    try cl.get(1, "/a", true);
    try cl.get(3, "/bb", true);
    try cl.get(5, "/a", true);
    try run(&cl, &c, &seen);
    try testing.expect(seen.settings_ack);
    for ([_]usize{ 0, 1, 2 }, [_][]const u8{ "/a", "/bb", "/a" }) |k, body| {
        try testing.expectEqual(200, seen.status[k]);
        try testing.expectEqualStrings(body, seen.body[k].items);
        try testing.expect(seen.ended[k]);
    }
    try testing.expectEqual(0, c.streams.count());
}

test "a POST body in two DATA frames, and a response past the window" {
    var c = try conn.Conn.init(gpa, .{}, echo, null, clock);
    defer c.deinit();
    var cl = try Client.init();
    defer cl.deinit();
    var seen: Seen = .{};
    defer seen.deinit();
    try cl.start();
    // A window of 100 bytes for each stream.
    var sp: [6]u8 = undefined;
    std.mem.writeInt(u16, sp[0..2], @backingInt(frame.Setting.initial_window_size), .big);
    std.mem.writeInt(u32, sp[2..6], 100, .big);
    try cl.raw(.settings, 0, 0, &sp);
    try cl.get(1, "/post", false);
    var body: [300]u8 = undefined;
    for (&body, 0..) |*x, i| x.* = @truncate(i);
    try cl.raw(.data, 0, 1, body[0..150]);
    try cl.raw(.data, frame.Flags.end_stream, 1, body[150..]);
    try run(&cl, &c, &seen);
    try testing.expectEqual(200, seen.status[0]);
    try testing.expectEqual(100, seen.body[0].items.len);
    try testing.expect(!seen.ended[0]);
    var inc: [4]u8 = undefined;
    std.mem.writeInt(u32, &inc, 500, .big);
    try cl.raw(.window_update, 0, 1, &inc);
    try run(&cl, &c, &seen);
    try testing.expectEqualSlices(u8, &body, seen.body[0].items);
    try testing.expect(seen.ended[0]);
    try testing.expectEqual(0, c.streams.count());
}

test "protocol errors and floods close the connection" {
    const Case = struct { name: []const u8, code: frame.Code };
    const cases = [_]Case{
        .{ .name = "bad preface", .code = .protocol_error },
        .{ .name = "data on stream 0", .code = .protocol_error },
        .{ .name = "even stream", .code = .protocol_error },
        .{ .name = "ping flood", .code = .enhance_your_calm },
        .{ .name = "rapid reset", .code = .enhance_your_calm },
        .{ .name = "continuation flood", .code = .enhance_your_calm },
        .{ .name = "big frame", .code = .frame_size_error },
    };
    for (cases) |cs| {
        var c = try conn.Conn.init(gpa, .{ .max_resets = 10, .max_control = 10, .max_continuation = 4 }, echo, null, clock);
        defer c.deinit();
        var cl = try Client.init();
        defer cl.deinit();
        var seen: Seen = .{};
        defer seen.deinit();
        if (std.mem.eql(u8, cs.name, "bad preface")) {
            try cl.buf.appendSlice(gpa, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
        } else {
            try cl.start();
            if (std.mem.eql(u8, cs.name, "data on stream 0")) try cl.raw(.data, 0, 0, "x");
            if (std.mem.eql(u8, cs.name, "even stream")) try cl.get(2, "/", true);
            if (std.mem.eql(u8, cs.name, "ping flood")) for (0..20) |_| try cl.raw(.ping, 0, 0, "12345678");
            if (std.mem.eql(u8, cs.name, "rapid reset")) for (0..20) |i| {
                const id: u31 = @intCast(2 * i + 1);
                try cl.get(id, "/", false);
                var code: [4]u8 = undefined;
                std.mem.writeInt(u32, &code, 8, .big);
                try cl.raw(.rst_stream, 0, id, &code);
            };
            if (std.mem.eql(u8, cs.name, "continuation flood")) {
                try cl.raw(.headers, 0, 1, "\x82");
                for (0..10) |_| try cl.raw(.continuation, 0, 1, "\x84");
            }
            if (std.mem.eql(u8, cs.name, "big frame")) {
                var big: [frame.default_max_frame + 1]u8 = @splat(0);
                try cl.raw(.data, 0, 1, &big);
            }
        }
        _ = try c.feed(cl.buf.items);
        try read(&cl, c.pending(), &seen);
        testing.expectEqual(cs.code, seen.goaway.?) catch |e| {
            std.debug.print("{s}\n", .{cs.name});
            return e;
        };
        try testing.expect(c.closed);
    }
}

test "a request with an uppercase field or no :path gets RST_STREAM" {
    var c = try conn.Conn.init(gpa, .{}, echo, null, clock);
    defer c.deinit();
    var cl = try Client.init();
    defer cl.deinit();
    var seen: Seen = .{};
    defer seen.deinit();
    try cl.start();
    var blk: [256]u8 = undefined;
    const n = try cl.enc.encode(&blk, &.{ .{ .name = ":method", .value = "GET" }, .{ .name = ":scheme", .value = "http" }, .{ .name = ":path", .value = "/" }, .{ .name = "X-Up", .value = "1" } });
    try cl.raw(.headers, frame.Flags.end_headers | frame.Flags.end_stream, 1, blk[0..n]);
    try run(&cl, &c, &seen);
    try testing.expectEqual(frame.Code.protocol_error, seen.rst.?);
    try testing.expect(!c.closed);
    // The connection goes on.
    try cl.get(3, "/ok", true);
    try run(&cl, &c, &seen);
    try testing.expectEqualStrings("/ok", seen.body[1].items);
}

test "an empty :path and a PRIORITY on itself get RST_STREAM (h2spec 8.1.2.3, 5.3.1)" {
    inline for (.{ true, false }) |empty_path| {
        var c = try conn.Conn.init(gpa, .{}, echo, null, clock);
        defer c.deinit();
        var cl = try Client.init();
        defer cl.deinit();
        var seen: Seen = .{};
        defer seen.deinit();
        try cl.start();
        if (empty_path) {
            try cl.get(1, "", true);
        } else {
            try cl.raw(.priority, 0, 1, &.{ 0, 0, 0, 1, 16 });
        }
        try run(&cl, &c, &seen);
        try testing.expectEqual(frame.Code.protocol_error, seen.rst.?);
        try testing.expect(!c.closed);
        try testing.expectEqual(@as(u16, 0), seen.status[0]);
    }
}

var ref_body: [70_000]u8 = undefined;

fn bigRef(_: ?*anyopaque, c: *conn.Conn, req: *const conn.Request) void {
    c.respondRef(req.stream, 200, &.{}, &ref_body) catch unreachable;
}

test "respondRef sends the body of the caller past the windows" {
    for (&ref_body, 0..) |*x, i| x.* = @truncate(i *% 7);
    var c = try conn.Conn.init(gpa, .{}, bigRef, null, clock);
    defer c.deinit();
    var cl = try Client.init();
    defer cl.deinit();
    var seen: Seen = .{};
    defer seen.deinit();
    try cl.start();
    try cl.get(1, "/a", true);
    try cl.get(3, "/b", true);
    try run(&cl, &c, &seen);
    // The window of the connection is 65,535 bytes for the two streams.
    try testing.expectEqual(65_535, seen.body[0].items.len + seen.body[1].items.len);
    var inc: [4]u8 = undefined;
    std.mem.writeInt(u32, &inc, 1 << 20, .big);
    try cl.raw(.window_update, 0, 0, &inc);
    try cl.raw(.window_update, 0, 1, &inc);
    try cl.raw(.window_update, 0, 3, &inc);
    try run(&cl, &c, &seen);
    try testing.expectEqualSlices(u8, &ref_body, seen.body[0].items);
    try testing.expectEqualSlices(u8, &ref_body, seen.body[1].items);
    try testing.expect(seen.ended[0] and seen.ended[1]);
    try testing.expectEqual(0, c.streams.count());
    try testing.expectEqual(0, c.pending().len);
}

//! HTTP/2 over TLS 1.3 (RFC 9113 section 3.2): a server of `server.zig`
//! in front of an HTTP/2 connection of `h2` (`src/h2/conn.zig`), with no
//! I/O of its own.
//!
//! `feed` takes the bytes of the client. It opens each whole record in
//! place in the buffer of the caller and gives the data to the HTTP/2
//! connection, with no copy when a record holds whole frames. `pending`
//! and `sent` give the records to send.
//!
//! The records of the responses come from the pieces of
//! `Conn.pending`: the frame bytes and the body slices of `respondRef`.
//! The pieces go into the free space of the output buffer after a
//! record header, and the AEAD seals them there in place. So a body
//! byte is read once by the copy and once by the cipher, and the record
//! goes to the socket from the buffer where it was sealed.
//!
//! ALPN must give "h2". A client with no "h2" in its list gets the
//! `no_application_protocol` alert. A client with no ALPN gets
//! close_notify after the handshake. Neither gets HTTP/2.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const h2 = @import("h2");
pub const server = @import("server.zig");
const record = @import("record.zig");

pub const alpn = [_][]const u8{"h2"};

pub const Conn = struct {
    gpa: std.mem.Allocator,
    tls: *server.Server,
    h2: h2.Conn,
    /// The records to send: `tx.items[head..]`.
    tx: std.ArrayList(u8) = .empty,
    head: usize = 0,
    /// The data of the records that `h2.feed` did not read yet: a frame
    /// that goes on in the next record.
    rx: std.ArrayList(u8) = .empty,
    connected: bool = false,
    /// No more bytes are read: the peer closed, a TLS alert, or GOAWAY.
    closed: bool = false,

    /// `opts.alpn` must be `alpn`. The TLS server is on the heap: it
    /// has buffers of 50 KiB.
    pub fn init(gpa: std.mem.Allocator, opts: server.Options, ent: server.Entropy, limits: h2.Limits, handler: h2.Handler, ctx: ?*anyopaque, clock: *const fn () u64) !Conn {
        std.debug.assert(opts.alpn.len == 1 and std.mem.eql(u8, opts.alpn[0], "h2"));
        const t = try gpa.create(server.Server);
        errdefer gpa.destroy(t);
        t.init(opts, ent);
        return .{ .gpa = gpa, .tls = t, .h2 = try .init(gpa, limits, handler, ctx, clock) };
    }

    pub fn deinit(c: *Conn) void {
        c.h2.deinit();
        c.gpa.destroy(c.tls);
        c.tx.deinit(c.gpa);
        c.rx.deinit(c.gpa);
    }

    /// Reads the whole records at the start of `in`, and gives the count
    /// of bytes it read. The caller keeps the rest for the next call.
    /// It changes the bytes of the records it reads.
    pub fn feed(c: *Conn, in: []u8) !usize {
        var pos: usize = 0;
        defer c.seal() catch {
            c.closed = true;
        };
        while (!c.closed and in.len - pos >= record.header_len) {
            const len = std.mem.readInt(u16, in[pos + 3 ..][0..2], .big);
            if (len > record.max_ciphertext) {
                c.closed = true;
                return error.RecordOverflow;
            }
            const n = record.header_len + @as(usize, len);
            if (in.len - pos < n) break;
            const rec = in[pos..][0..n];
            pos += n;
            var out = std.Io.Writer.Allocating.fromArrayList(c.gpa, &c.tx);
            defer c.tx = out.toArrayList();
            const ev = c.tls.handleRecordInPlace(&out.writer, rec) catch |e| {
                c.closed = true;
                return e;
            };
            switch (ev) {
                .none => {},
                .handshake_done => {
                    c.connected = true;
                    if (c.tls.protocol() == null) {
                        // A client with no ALPN: no HTTP/2 over TLS.
                        c.tls.close(&out.writer) catch {};
                        c.closed = true;
                        return error.NoProtocol;
                    }
                },
                .closed => c.closed = true,
                .data => |d| try c.data(d),
            }
        }
        return pos;
    }

    fn data(c: *Conn, d: []const u8) !void {
        if (c.rx.items.len == 0) {
            // The frames are read where the record was opened.
            const n = try c.h2.feed(d);
            if (n < d.len) try c.rx.appendSlice(c.gpa, d[n..]);
        } else {
            try c.rx.appendSlice(c.gpa, d);
            const n = try c.h2.feed(c.rx.items);
            const rest = c.rx.items.len - n;
            std.mem.copyForwards(u8, c.rx.items[0..rest], c.rx.items[n..]);
            c.rx.items.len = rest;
        }
        if (c.h2.closed) c.closed = true;
    }

    /// Seals the pieces of `h2.pending` in records at the end of `tx`.
    fn seal(c: *Conn) !void {
        if (!c.connected) return;
        while (c.h2.pending().len > 0) {
            var out = std.Io.Writer.Allocating.fromArrayList(c.gpa, &c.tx);
            const p = c.tls.sealer(&out.writer) catch |e| {
                c.tx = out.toArrayList();
                return e;
            };
            c.tx = out.toArrayList();
            try c.tx.ensureUnusedCapacity(c.gpa, record.max_record);
            const buf = c.tx.unusedCapacitySlice()[0..record.max_record];
            const content = buf[record.header_len..];
            var n: usize = 0;
            while (n < record.max_plaintext) {
                const piece = c.h2.pending();
                if (piece.len == 0) break;
                const k = @min(piece.len, record.max_plaintext - n);
                @memcpy(content[n..][0..k], piece[0..k]);
                c.h2.sent(k);
                n += k;
            }
            const rec = try p.seal(buf, .application_data, content[0..n], 0);
            c.tx.items.len += rec.len;
        }
    }

    /// The records to send now.
    pub fn pending(c: *const Conn) []const u8 {
        return c.tx.items[c.head..];
    }

    /// Drops the first `n` bytes of `pending`, after a write.
    pub fn sent(c: *Conn, n: usize) void {
        c.head += n;
        if (c.head == c.tx.items.len) {
            c.tx.clearRetainingCapacity();
            c.head = 0;
        } else if (c.head >= 1 << 16 and c.head * 2 >= c.tx.items.len) {
            const rest = c.tx.items.len - c.head;
            std.mem.copyForwards(u8, c.tx.items[0..rest], c.tx.items[c.head..]);
            c.tx.items.len = rest;
            c.head = 0;
        }
    }
};

const client = server.client;
const pem = server.pem;
const frame = h2.frame;

var test_body: [40_000]u8 = undefined;

fn testHandler(_: ?*anyopaque, c: *h2.Conn, req: *const h2.Request) void {
    c.respondRef(req.stream, 200, &.{}, &test_body) catch unreachable;
}

fn testClock() u64 {
    return 0;
}

/// A GET over TLS with the client of client.zig in memory. Gives the
/// body of stream 1, or the error of the server.
fn loopback(a: std.mem.Allocator, protos: []const []const u8) ![]const u8 {
    const pem_text = @embedFile("testdata/server/p256.pem");
    var it = pem.Iterator.init(pem_text);
    const cert = (try it.next(a)).?;
    const key = try pem.privateKey((try it.next(a)).?);
    const chain = [_][]const u8{cert.der};
    var s_ent: server.Entropy = undefined;
    var c_ent: client.Entropy = undefined;
    std.testing.io.random(std.mem.asBytes(&s_ent));
    std.testing.io.random(std.mem.asBytes(&c_ent));
    var s = try Conn.init(a, .{ .chain = &chain, .key = key, .alpn = &alpn }, s_ent, .{}, testHandler, null, testClock);
    defer s.deinit();
    const c = try a.create(client.Client);
    c.init(.{ .host = "localhost.test", .roots = &.{}, .now = 1_800_000_000, .verify_chain = false, .alpn = protos }, c_ent);
    var to_s: std.Io.Writer.Allocating = .init(a);
    var to_c: std.ArrayList(u8) = .empty;
    try c.hello(&to_s.writer);
    var plain: std.ArrayList(u8) = .empty;
    var asked = false;
    var rounds: usize = 0;
    while (rounds < 40) : (rounds += 1) {
        const for_s = try a.dupe(u8, to_s.written());
        to_s.clearRetainingCapacity();
        const n = try s.feed(for_s);
        try std.testing.expectEqual(for_s.len, n);
        try to_c.appendSlice(a, s.pending());
        s.sent(s.pending().len);
        var rest: []const u8 = to_c.items;
        while (rest.len >= 5) {
            const m = 5 + @as(usize, std.mem.readInt(u16, rest[3..5], .big));
            if (rest.len < m) break;
            switch (try c.handleRecord(&to_s.writer, rest[0..m])) {
                .handshake_done => if (!asked) {
                    asked = true;
                    var req: std.ArrayList(u8) = .empty;
                    try req.appendSlice(a, frame.preface);
                    var b: [64]u8 = undefined;
                    try req.appendSlice(a, b[0..frame.writeSettings(&b, &.{})]);
                    var enc = try h2.hpack.Encoder.init(a, 4096);
                    var blk: [128]u8 = undefined;
                    const bl = try enc.encode(&blk, &.{ .{ .name = ":method", .value = "GET" }, .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost.test" }, .{ .name = ":path", .value = "/" } });
                    var hb: [frame.header_len]u8 = undefined;
                    (frame.Header{ .len = @intCast(bl), .type = .headers, .flags = frame.Flags.end_headers | frame.Flags.end_stream, .stream = 1 }).write(&hb);
                    try req.appendSlice(a, &hb);
                    try req.appendSlice(a, blk[0..bl]);
                    try c.write(&to_s.writer, req.items);
                },
                .data => |d| try plain.appendSlice(a, d),
                else => {},
            }
            rest = rest[m..];
        }
        to_c.items.len = 0;
        if (s.closed) break;
        // The body is in when a DATA frame with END_STREAM is.
        var body: std.ArrayList(u8) = .empty;
        var p: usize = 0;
        while (p + frame.header_len <= plain.items.len) {
            const h = frame.Header.parse(plain.items[p..][0..frame.header_len]);
            if (p + frame.header_len + h.len > plain.items.len) break;
            const pl = plain.items[p + frame.header_len ..][0..h.len];
            p += frame.header_len + h.len;
            if (h.type == .data and h.stream == 1) {
                try body.appendSlice(a, pl);
                if (h.flags & frame.Flags.end_stream != 0) return body.items;
            }
        }
    }
    return error.NoResponse;
}

test "a GET over TLS with ALPN h2 gets the body of respondRef" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (&test_body, 0..) |*x, i| x.* = @truncate(i *% 13);
    const got = try loopback(arena.allocator(), &.{ "h2", "http/1.1" });
    try std.testing.expectEqualSlices(u8, &test_body, got);
}

test "a client with no ALPN or with no h2 gets no HTTP/2" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NoProtocol, loopback(arena.allocator(), &.{}));
    try std.testing.expectError(error.AlertSent, loopback(arena.allocator(), &.{"http/1.1"}));
}

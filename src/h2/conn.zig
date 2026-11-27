//! The server side of an HTTP/2 connection (RFC 9113, task 29), with no
//! transport: `feed` takes the bytes from the client, and `pending`
//! gives the bytes to send. The caller runs the socket or the TLS
//! connection, so the same code serves `h2` over TLS and `h2c` with
//! prior knowledge.
//!
//! `feed` reads whole frames in place in the buffer of the caller. A
//! header block in one HEADERS frame decodes from that buffer, and the
//! fields of a request with END_STREAM on its HEADERS go to the handler
//! as slices of one buffer of the connection that keeps its capacity, so
//! a request needs no allocation once the buffers have grown. A request with a body keeps
//! a copy of its fields and its body in the stream until END_STREAM.
//! A header block in more than one frame (CONTINUATION) is copied into
//! one buffer first.
//!
//! The handler answers with `respond`, at once or later. The response
//! goes out as HEADERS and DATA frames within the flow control windows
//! of the stream and of the connection; the rest waits in the stream
//! for WINDOW_UPDATE.
//!
//! The limits of `Limits` close the connection with GOAWAY against the
//! known attacks: a header block past `max_header_block` or in more
//! than `max_continuation` frames (CONTINUATION flood), a header list
//! past `max_header_list` (HPACK bomb), more than `max_resets` streams
//! reset by the client in a second (rapid reset), and more than
//! `max_control` SETTINGS and PING frames in a second (settings and
//! ping floods), all with ENHANCE_YOUR_CALM, except the header list,
//! which resets the stream. A stream past `max_streams` gets
//! REFUSED_STREAM.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");
const Code = frame.Code;

pub const Limits = struct {
    max_streams: u32 = 100,
    max_header_list: u32 = 16384,
    max_header_block: u32 = 65536,
    max_continuation: u32 = 32,
    max_body: u32 = 1 << 20,
    max_resets: u32 = 200,
    max_control: u32 = 1000,
    /// The receive window of each stream and of the connection.
    window: u31 = 1 << 20,
};

pub const Field = hpack.Field;

pub const Request = struct {
    stream: u31,
    method: []const u8 = "",
    scheme: []const u8 = "",
    authority: []const u8 = "",
    path: []const u8 = "",
    /// The fields that are not pseudo-header fields.
    headers: []const Field,
    body: []const u8 = "",
};

/// Runs for each request. `req` and its slices are valid until the
/// handler returns or calls `respond`, the first of the two.
pub const Handler = *const fn (ctx: ?*anyopaque, c: *Conn, req: *const Request) void;

const Stream = struct {
    /// The client sent END_STREAM.
    remote_done: bool = false,
    send_window: i64,
    /// Kept fields and body of a request with a body.
    fields: std.ArrayList(Field) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    req: Request = .{ .stream = 0, .headers = &.{} },
    content_length: ?u64 = null,
    /// The part of the response body that waits for the windows: a copy
    /// in `out`, or the slice of the caller in `ref` (`respondRef`).
    out: std.ArrayList(u8) = .empty,
    ref: []const u8 = "",
    out_pos: usize = 0,
    responded: bool = false,

    fn waiting(s: *const Stream) []const u8 {
        return if (s.ref.len > 0) s.ref else s.out.items;
    }

    fn deinit(s: *Stream, gpa: std.mem.Allocator) void {
        s.fields.deinit(gpa);
        s.bytes.deinit(gpa);
        s.body.deinit(gpa);
        s.out.deinit(gpa);
    }
};

pub const Error = error{ OutOfMemory, Closed };

const Span = struct { off: usize, name_len: usize, value_len: usize };

/// The smallest piece of a `respondRef` body that goes out with no copy.
const ref_min = 1024;

/// A body slice of the caller that goes out after the first `at` bytes
/// of `Conn.out`. It is never empty.
const Ref = struct { at: usize, bytes: []const u8 };

pub const Conn = struct {
    gpa: std.mem.Allocator,
    limits: Limits,
    handler: Handler,
    ctx: ?*anyopaque,
    dec: hpack.Decoder,
    enc: hpack.Encoder,
    /// The bytes to send: `out[head..]`, with the body slices of `refs`
    /// in their places.
    out: std.ArrayList(u8) = .empty,
    head: usize = 0,
    refs: std.ArrayList(Ref) = .empty,
    /// The first ref that is not sent yet, and its bytes that are.
    ref_start: usize = 0,
    ref_off: usize = 0,
    streams: std.AutoHashMapUnmanaged(u31, Stream) = .empty,
    preface: bool = false,
    settings_seen: bool = false,
    last_stream: u31 = 0,
    /// GOAWAY went out: no more frames are read.
    closed: bool = false,
    send_window: i64 = frame.default_window,
    peer_initial_window: i64 = frame.default_window,
    peer_max_frame: u32 = frame.default_max_frame,
    recv_window: i64,
    /// The header block in CONTINUATION frames.
    block: std.ArrayList(u8) = .empty,
    block_stream: u31 = 0,
    block_flags: u8 = 0,
    block_frames: u32 = 0,
    scratch: []u8,
    /// The fields of the block now: their bytes, their places, and the
    /// slices. They keep their capacity from block to block.
    keep: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    fields: std.ArrayList(Field) = .empty,
    /// The counts of the second that starts at `window_start`.
    window_start: u64 = 0,
    resets: u32 = 0,
    control: u32 = 0,
    clock: *const fn () u64,

    pub fn init(gpa: std.mem.Allocator, limits: Limits, handler: Handler, ctx: ?*anyopaque, clock: *const fn () u64) !Conn {
        var c: Conn = .{
            .gpa = gpa,
            .limits = limits,
            .handler = handler,
            .ctx = ctx,
            .dec = try .init(gpa, 4096, limits.max_header_list),
            .enc = try .init(gpa, 4096),
            .recv_window = frame.default_window,
            .scratch = try gpa.alloc(u8, limits.max_header_list),
            .clock = clock,
        };
        // The settings of the server, and the window of the connection.
        try c.out.ensureUnusedCapacity(gpa, 64);
        var buf: [64]u8 = undefined;
        var n = frame.writeSettings(&buf, &.{
            .{ .max_concurrent_streams, limits.max_streams },
            .{ .initial_window_size, limits.window },
            .{ .max_header_list_size, limits.max_header_list },
            .{ .enable_push, 0 },
        });
        n += frame.writeWindowUpdate(buf[n..], 0, limits.window - frame.default_window);
        c.out.appendSliceAssumeCapacity(buf[0..n]);
        c.recv_window = limits.window;
        return c;
    }

    pub fn deinit(c: *Conn) void {
        var it = c.streams.valueIterator();
        while (it.next()) |s| s.deinit(c.gpa);
        c.streams.deinit(c.gpa);
        c.dec.deinit(c.gpa);
        c.enc.deinit(c.gpa);
        c.out.deinit(c.gpa);
        c.refs.deinit(c.gpa);
        c.block.deinit(c.gpa);
        c.fields.deinit(c.gpa);
        c.keep.deinit(c.gpa);
        c.spans.deinit(c.gpa);
        c.gpa.free(c.scratch);
    }

    /// The first piece of the bytes to send now: bytes of the
    /// connection, or a body slice of `respondRef`. It is empty only when
    /// all bytes are out.
    pub fn pending(c: *const Conn) []const u8 {
        if (c.ref_start < c.refs.items.len) {
            const r = c.refs.items[c.ref_start];
            if (c.head < r.at) return c.out.items[c.head..r.at];
            return r.bytes[c.ref_off..];
        }
        return c.out.items[c.head..];
    }

    /// Fills `iov` with the pieces to send now, in order, and gives
    /// their count. A write of all of them sends no copy of a body of
    /// `respondRef`.
    pub fn pendingVecs(c: *const Conn, iov: []std.posix.iovec_const) usize {
        var n: usize = 0;
        var head = c.head;
        var off = c.ref_off;
        for (c.refs.items[c.ref_start..]) |r| {
            if (n + 2 > iov.len) return n;
            if (head < r.at) {
                iov[n] = .{ .base = c.out.items[head..].ptr, .len = r.at - head };
                n += 1;
            }
            iov[n] = .{ .base = r.bytes[off..].ptr, .len = r.bytes.len - off };
            n += 1;
            head = r.at;
            off = 0;
        }
        if (head < c.out.items.len and n < iov.len) {
            iov[n] = .{ .base = c.out.items[head..].ptr, .len = c.out.items.len - head };
            n += 1;
        }
        return n;
    }

    /// Drops the first `n` bytes to send, after a write.
    pub fn sent(c: *Conn, n: usize) void {
        var left = n;
        while (left > 0) {
            if (c.ref_start < c.refs.items.len) {
                const r = c.refs.items[c.ref_start];
                if (c.head < r.at) {
                    const k = @min(left, r.at - c.head);
                    c.head += k;
                    left -= k;
                    continue;
                }
                const k = @min(left, r.bytes.len - c.ref_off);
                c.ref_off += k;
                left -= k;
                if (c.ref_off == r.bytes.len) {
                    c.ref_start += 1;
                    c.ref_off = 0;
                }
            } else {
                std.debug.assert(c.head + left <= c.out.items.len);
                c.head += left;
                left = 0;
            }
        }
        if (c.ref_start == c.refs.items.len and c.head == c.out.items.len) {
            c.out.clearRetainingCapacity();
            c.refs.clearRetainingCapacity();
            c.head = 0;
            c.ref_start = 0;
        } else if (c.head >= 1 << 16 and c.head * 2 >= c.out.items.len) {
            // Move the rest to the start, so the buffer does not grow
            // while a slow peer reads.
            const rest = c.out.items.len - c.head;
            std.mem.copyForwards(u8, c.out.items[0..rest], c.out.items[c.head..]);
            c.out.items.len = rest;
            const live = c.refs.items[c.ref_start..];
            for (live) |*r| r.at -= c.head;
            std.mem.copyForwards(Ref, c.refs.items[0..live.len], live);
            c.refs.items.len = live.len;
            c.head = 0;
            c.ref_start = 0;
        }
    }

    fn goaway(c: *Conn, code: Code) Error!void {
        var b: [17]u8 = undefined;
        try c.out.appendSlice(c.gpa, b[0..frame.writeGoaway(&b, c.last_stream, code)]);
        c.closed = true;
    }

    fn rst(c: *Conn, id: u31, code: Code) Error!void {
        var b: [13]u8 = undefined;
        try c.out.appendSlice(c.gpa, b[0..frame.writeRst(&b, id, code)]);
        c.closeStream(id);
    }

    fn closeStream(c: *Conn, id: u31) void {
        if (c.streams.fetchRemove(id)) |kv| {
            var s = kv.value;
            s.deinit(c.gpa);
        }
    }

    /// Counts a reset or a control frame in the second now. Gives true
    /// past the limit.
    fn flood(c: *Conn, counter: *u32, limit: u32) bool {
        const now = c.clock();
        if (now -% c.window_start >= std.time.ns_per_s) {
            c.window_start = now;
            c.resets = 0;
            c.control = 0;
        }
        counter.* += 1;
        return counter.* > limit;
    }

    /// Reads the whole frames at the start of `in` and gives the count
    /// of bytes it read. The caller keeps the rest for the next call.
    pub fn feed(c: *Conn, in: []const u8) Error!usize {
        var pos: usize = 0;
        if (!c.preface) {
            if (in.len < frame.preface.len) {
                if (!std.mem.startsWith(u8, frame.preface, in)) try c.goaway(.protocol_error);
                return 0;
            }
            if (!std.mem.eql(u8, in[0..frame.preface.len], frame.preface)) {
                try c.goaway(.protocol_error);
                return in.len;
            }
            c.preface = true;
            pos = frame.preface.len;
        }
        while (!c.closed and in.len - pos >= frame.header_len) {
            const h = frame.Header.parse(in[pos..][0..frame.header_len]);
            if (h.len > frame.default_max_frame) {
                try c.goaway(.frame_size_error);
                break;
            }
            if (in.len - pos - frame.header_len < h.len) break;
            const p = in[pos + frame.header_len ..][0..h.len];
            pos += frame.header_len + h.len;
            try c.onFrame(h, p);
        }
        if (c.closed) return in.len;
        return pos;
    }

    fn onFrame(c: *Conn, h: frame.Header, p: []const u8) Error!void {
        if (!c.settings_seen) {
            if (h.type != .settings or h.flags & frame.Flags.ack != 0) return c.goaway(.protocol_error);
            c.settings_seen = true;
        }
        if (c.block_frames != 0 and (h.type != .continuation or h.stream != c.block_stream)) return c.goaway(.protocol_error);
        switch (h.type) {
            .data => try c.onData(h, p),
            .headers => try c.onHeaders(h, p),
            .continuation => {
                if (c.block_frames == 0) return c.goaway(.protocol_error);
                c.block_frames += 1;
                if (c.block_frames > c.limits.max_continuation or c.block.items.len + p.len > c.limits.max_header_block) return c.goaway(.enhance_your_calm);
                try c.block.appendSlice(c.gpa, p);
                if (h.flags & frame.Flags.end_headers != 0) {
                    c.block_frames = 0;
                    const blk = try c.gpa.dupe(u8, c.block.items);
                    defer c.gpa.free(blk);
                    c.block.clearRetainingCapacity();
                    try c.onBlock(c.block_stream, c.block_flags, blk);
                }
            },
            .priority => {
                if (h.stream == 0) return c.goaway(.protocol_error);
                if (p.len != 5) return c.rst(h.stream, .frame_size_error);
                // RFC 9113 5.3.1: a stream that depends on itself is a stream error.
                if (std.mem.readInt(u32, p[0..4], .big) & 0x7fffffff == h.stream) return c.rst(h.stream, .protocol_error);
            },
            .rst_stream => {
                if (h.stream == 0 or h.stream > c.last_stream) return c.goaway(.protocol_error);
                if (p.len != 4) return c.goaway(.frame_size_error);
                if (c.flood(&c.resets, c.limits.max_resets)) return c.goaway(.enhance_your_calm);
                c.closeStream(h.stream);
            },
            .settings => try c.onSettings(h, p),
            .ping => {
                if (h.stream != 0) return c.goaway(.protocol_error);
                if (p.len != 8) return c.goaway(.frame_size_error);
                if (h.flags & frame.Flags.ack != 0) return;
                if (c.flood(&c.control, c.limits.max_control)) return c.goaway(.enhance_your_calm);
                var b: [17]u8 = undefined;
                try c.out.appendSlice(c.gpa, b[0..frame.write(&b, .ping, frame.Flags.ack, 0, p)]);
            },
            .goaway => {
                if (h.stream != 0) return c.goaway(.protocol_error);
                c.closed = true;
            },
            .window_update => try c.onWindowUpdate(h, p),
            .push_promise => return c.goaway(.protocol_error),
            else => {},
        }
    }

    fn onSettings(c: *Conn, h: frame.Header, p: []const u8) Error!void {
        if (h.stream != 0) return c.goaway(.protocol_error);
        if (h.flags & frame.Flags.ack != 0) {
            if (p.len != 0) return c.goaway(.frame_size_error);
            return;
        }
        if (p.len % 6 != 0) return c.goaway(.frame_size_error);
        if (c.flood(&c.control, c.limits.max_control)) return c.goaway(.enhance_your_calm);
        var i: usize = 0;
        while (i < p.len) : (i += 6) {
            const id: frame.Setting = @fromBackingInt(@intCast(std.mem.readInt(u16, p[i..][0..2], .big)));
            const v = std.mem.readInt(u32, p[i + 2 ..][0..4], .big);
            switch (id) {
                .header_table_size => c.enc.setMax(@min(v, c.enc.table.cap)),
                .enable_push => if (v > 1) return c.goaway(.protocol_error),
                .initial_window_size => {
                    if (v > std.math.maxInt(u31)) return c.goaway(.flow_control_error);
                    const delta = @as(i64, v) - c.peer_initial_window;
                    c.peer_initial_window = v;
                    var it = c.streams.valueIterator();
                    while (it.next()) |s| {
                        s.send_window += delta;
                        if (s.send_window > std.math.maxInt(u31)) return c.goaway(.flow_control_error);
                    }
                },
                .max_frame_size => {
                    if (v < frame.default_max_frame or v > (1 << 24) - 1) return c.goaway(.protocol_error);
                    c.peer_max_frame = v;
                },
                else => {},
            }
        }
        var b: [9]u8 = undefined;
        try c.out.appendSlice(c.gpa, b[0..frame.write(&b, .settings, frame.Flags.ack, 0, "")]);
        try c.flushAll();
    }

    fn onWindowUpdate(c: *Conn, h: frame.Header, p: []const u8) Error!void {
        if (p.len != 4) return c.goaway(.frame_size_error);
        const inc = std.mem.readInt(u32, p[0..4], .big) & 0x7fffffff;
        if (h.stream == 0) {
            if (inc == 0) return c.goaway(.protocol_error);
            c.send_window += inc;
            if (c.send_window > std.math.maxInt(u31)) return c.goaway(.flow_control_error);
            return c.flushAll();
        }
        if (h.stream > c.last_stream) return c.goaway(.protocol_error);
        const s = c.streams.getPtr(h.stream) orelse return;
        if (inc == 0) return c.rst(h.stream, .protocol_error);
        s.send_window += inc;
        if (s.send_window > std.math.maxInt(u31)) return c.rst(h.stream, .flow_control_error);
        try c.flush(h.stream);
    }

    /// The payload of HEADERS or DATA less its padding.
    fn unpad(h: frame.Header, p: []const u8) ?[]const u8 {
        if (h.flags & frame.Flags.padded == 0) return p;
        if (p.len < 1 or p[0] >= p.len) return null;
        return p[1 .. p.len - p[0]];
    }

    fn onData(c: *Conn, h: frame.Header, p: []const u8) Error!void {
        if (h.stream == 0 or h.stream > c.last_stream) return c.goaway(.protocol_error);
        c.recv_window -= @intCast(p.len);
        if (c.recv_window < 0) return c.goaway(.flow_control_error);
        // Give the window back at once: the body limit bounds the memory.
        var b: [26]u8 = undefined;
        var n: usize = 0;
        if (p.len > 0) {
            n = frame.writeWindowUpdate(&b, 0, @intCast(p.len));
            c.recv_window += @intCast(p.len);
        }
        const s = c.streams.getPtr(h.stream) orelse {
            try c.out.appendSlice(c.gpa, b[0..n]);
            return c.rst(h.stream, .stream_closed);
        };
        if (s.remote_done) {
            try c.out.appendSlice(c.gpa, b[0..n]);
            return c.rst(h.stream, .stream_closed);
        }
        const data = unpad(h, p) orelse return c.goaway(.protocol_error);
        if (s.body.items.len + data.len > c.limits.max_body) {
            try c.out.appendSlice(c.gpa, b[0..n]);
            return c.rst(h.stream, .refused_stream);
        }
        try s.body.appendSlice(c.gpa, data);
        if (p.len > 0 and h.flags & frame.Flags.end_stream == 0) n += frame.writeWindowUpdate(b[n..], h.stream, @intCast(p.len));
        try c.out.appendSlice(c.gpa, b[0..n]);
        if (h.flags & frame.Flags.end_stream != 0) {
            s.remote_done = true;
            if (s.content_length) |cl| if (cl != s.body.items.len) return c.rst(h.stream, .protocol_error);
            s.req.body = s.body.items;
            s.req.headers = s.fields.items;
            const req = s.req;
            c.handler(c.ctx, c, &req);
            // A response that went out before the end of the body.
            if (c.streams.getPtr(h.stream)) |s2| if (s2.responded and s2.out_pos >= s2.waiting().len) c.closeStream(h.stream);
        }
    }

    fn onHeaders(c: *Conn, h: frame.Header, p0: []const u8) Error!void {
        if (h.stream == 0 or h.stream % 2 == 0) return c.goaway(.protocol_error);
        var p = unpad(h, p0) orelse return c.goaway(.protocol_error);
        if (h.flags & frame.Flags.priority != 0) {
            if (p.len < 5) return c.goaway(.frame_size_error);
            if (std.mem.readInt(u32, p[0..4], .big) & 0x7fffffff == h.stream) return c.rst(h.stream, .protocol_error);
            p = p[5..];
        }
        if (h.flags & frame.Flags.end_headers == 0) {
            if (p.len > c.limits.max_header_block) return c.goaway(.enhance_your_calm);
            c.block.clearRetainingCapacity();
            try c.block.appendSlice(c.gpa, p);
            c.block_stream = h.stream;
            c.block_flags = h.flags;
            c.block_frames = 1;
            return;
        }
        try c.onBlock(h.stream, h.flags, p);
    }

    /// A whole header block of stream `id`.
    fn onBlock(c: *Conn, id: u31, flags: u8, blk: []const u8) Error!void {
        const end_stream = flags & frame.Flags.end_stream != 0;
        if (id <= c.last_stream) {
            // Trailers of an open stream, or a stream that is closed.
            const s = c.streams.getPtr(id) orelse return c.goaway(.stream_closed);
            if (s.remote_done or !end_stream) return c.goaway(.protocol_error);
            var b = c.dec.block(blk, c.scratch);
            while (b.next() catch return c.goaway(.compression_error)) |_| {}
            s.remote_done = true;
            s.req.body = s.body.items;
            s.req.headers = s.fields.items;
            const req = s.req;
            c.handler(c.ctx, c, &req);
            return;
        }
        c.last_stream = id;
        // Decode the block in each case: the HPACK state of the
        // connection needs it. The fields point into buffers that the
        // next field can change, so each one is copied into `keep`.
        c.spans.clearRetainingCapacity();
        c.keep.clearRetainingCapacity();
        const spans = &c.spans;
        const keep = &c.keep;
        var pseudo: [4]?Span = @splat(null);
        const pseudo_names = [4][]const u8{ ":method", ":scheme", ":authority", ":path" };
        var bad = false;
        var regular = false;
        var content_length: ?u64 = null;
        var b = c.dec.block(blk, c.scratch);
        while (true) {
            const f = b.next() catch |e| switch (e) {
                error.HeaderListTooLarge => return c.rst(id, .refused_stream),
                else => return c.goaway(.compression_error),
            } orelse break;
            const sp: Span = .{ .off = keep.items.len, .name_len = f.name.len, .value_len = f.value.len };
            try keep.appendSlice(c.gpa, f.name);
            try keep.appendSlice(c.gpa, f.value);
            if (f.name.len > 0 and f.name[0] == ':') {
                if (regular) bad = true;
                const k = for (pseudo_names, 0..) |n, k| {
                    if (std.mem.eql(u8, f.name, n)) break k;
                } else {
                    bad = true;
                    continue;
                };
                if (pseudo[k] != null) bad = true;
                pseudo[k] = sp;
                continue;
            }
            regular = true;
            for (f.name) |ch| if (ch >= 'A' and ch <= 'Z') {
                bad = true;
            };
            if (isConnectionField(f.name)) bad = true;
            if (std.mem.eql(u8, f.name, "te") and !std.mem.eql(u8, f.value, "trailers")) bad = true;
            if (std.mem.eql(u8, f.name, "content-length")) content_length = std.fmt.parseInt(u64, f.value, 10) catch blk: {
                bad = true;
                break :blk null;
            };
            try spans.append(c.gpa, sp);
        }
        if (bad or pseudo[0] == null or pseudo[1] == null or pseudo[3] == null or pseudo[3].?.value_len == 0) return c.rst(id, .protocol_error);
        if (c.streams.count() >= c.limits.max_streams) return c.rst(id, .refused_stream);
        const gop = try c.streams.getOrPut(c.gpa, id);
        gop.value_ptr.* = .{ .send_window = c.peer_initial_window, .content_length = content_length };
        const s = gop.value_ptr;
        // With END_STREAM the fields stay in `keep` for the handler; with
        // a body they move to the stream.
        if (!end_stream) std.mem.swap(std.ArrayList(u8), keep, &s.bytes);
        const bytes = if (end_stream) keep.items else s.bytes.items;
        c.fields.clearRetainingCapacity();
        const list = if (end_stream) &c.fields else &s.fields;
        for (spans.items) |sp| try list.append(c.gpa, .{ .name = bytes[sp.off..][0..sp.name_len], .value = bytes[sp.off + sp.name_len ..][0..sp.value_len] });
        var req: Request = .{ .stream = id, .headers = list.items };
        inline for (.{ "method", "scheme", "authority", "path" }, 0..) |name, k| {
            if (pseudo[k]) |sp| @field(req, name) = bytes[sp.off + sp.name_len ..][0..sp.value_len];
        }
        if (end_stream) {
            s.remote_done = true;
            if (content_length) |cl| if (cl != 0) return c.rst(id, .protocol_error);
            c.handler(c.ctx, c, &req);
            return;
        }
        s.req = req;
    }

    fn isConnectionField(name: []const u8) bool {
        inline for (.{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade" }) |n| {
            if (std.mem.eql(u8, name, n)) return true;
        }
        return false;
    }

    /// Sends the response of stream `id`: the status, the fields, and
    /// the body. The body goes out as the windows allow; `respond`
    /// copies it.
    pub fn respond(c: *Conn, id: u31, status: u16, headers: []const Field, body: []const u8) Error!void {
        return c.respondMode(id, status, headers, body, false);
    }

    /// `respond` with no copy of the body: the DATA frames point at
    /// `body` (see `pendingVecs`). The caller keeps `body` valid and
    /// unchanged until `deinit`.
    pub fn respondRef(c: *Conn, id: u31, status: u16, headers: []const Field, body: []const u8) Error!void {
        return c.respondMode(id, status, headers, body, true);
    }

    fn respondMode(c: *Conn, id: u31, status: u16, headers: []const Field, body: []const u8, borrowed: bool) Error!void {
        const s = c.streams.getPtr(id) orelse return error.Closed;
        if (s.responded) return error.Closed;
        s.responded = true;
        var st: [3]u8 = undefined;
        _ = std.fmt.bufPrint(&st, "{d}", .{status}) catch unreachable;
        // The header block: at most the frame size of the peer, in
        // HEADERS and CONTINUATION frames.
        var fields_buf: [64]Field = undefined;
        if (headers.len + 1 > fields_buf.len) return error.OutOfMemory;
        fields_buf[0] = .{ .name = ":status", .value = &st };
        @memcpy(fields_buf[1..][0..headers.len], headers);
        var size: usize = 64;
        for (headers) |f| size += f.name.len + f.value.len + 10;
        const start = c.out.items.len;
        try c.out.ensureUnusedCapacity(c.gpa, frame.header_len + size);
        const blk_len = c.enc.encode(c.out.unusedCapacitySlice()[frame.header_len..][0..size], fields_buf[0 .. headers.len + 1]) catch unreachable;
        c.out.items.len += frame.header_len + blk_len;
        const end_stream: u8 = if (body.len == 0) frame.Flags.end_stream else 0;
        if (blk_len <= c.peer_max_frame) {
            (frame.Header{ .len = @intCast(blk_len), .type = .headers, .flags = frame.Flags.end_headers | end_stream, .stream = id }).write(c.out.items[start..][0..frame.header_len]);
        } else {
            // Split into HEADERS and CONTINUATION frames.
            const blk = try c.gpa.dupe(u8, c.out.items[start + frame.header_len ..][0..blk_len]);
            defer c.gpa.free(blk);
            c.out.items.len = start;
            var off: usize = 0;
            while (off < blk.len) {
                const part = blk[off..@min(blk.len, off + c.peer_max_frame)];
                const t: frame.Type = if (off == 0) .headers else .continuation;
                const fl: u8 = (if (off + part.len == blk.len) @as(u8, frame.Flags.end_headers) else 0) | (if (off == 0) end_stream else 0);
                var hb: [frame.header_len]u8 = undefined;
                (frame.Header{ .len = @intCast(part.len), .type = t, .flags = fl, .stream = id }).write(&hb);
                try c.out.appendSlice(c.gpa, &hb);
                try c.out.appendSlice(c.gpa, part);
                off += part.len;
            }
        }
        if (body.len == 0) {
            if (s.remote_done) c.closeStream(id);
            return;
        }
        // DATA within the windows now, and the rest waits in the stream.
        const now = c.sendData(id, s, body, borrowed);
        if (now < body.len) {
            if (borrowed) {
                s.ref = body;
                s.out_pos = now;
            } else try s.out.appendSlice(c.gpa, body[now..]);
        } else if (s.remote_done) {
            c.closeStream(id);
        }
    }

    /// Writes DATA frames of `data` within the windows. Gives the count
    /// of bytes it wrote. The last byte of the body carries END_STREAM.
    fn sendData(c: *Conn, id: u31, s: *Stream, data: []const u8, borrow: bool) usize {
        var off: usize = 0;
        const total_left = data.len;
        while (off < data.len) {
            const win = @min(c.send_window, s.send_window);
            if (win <= 0) break;
            const n: usize = @min(@as(usize, @intCast(win)), c.peer_max_frame, data.len - off);
            const last = off + n == total_left;
            // A copy of a small piece costs less than one more iovec.
            const borrowed = borrow and n >= ref_min;
            c.out.ensureUnusedCapacity(c.gpa, frame.header_len + if (borrowed) 0 else n) catch break;
            if (borrowed) c.refs.ensureUnusedCapacity(c.gpa, 1) catch break;
            var hb: [frame.header_len]u8 = undefined;
            (frame.Header{ .len = @intCast(n), .type = .data, .flags = if (last) frame.Flags.end_stream else 0, .stream = id }).write(&hb);
            c.out.appendSliceAssumeCapacity(&hb);
            if (borrowed) {
                c.refs.appendAssumeCapacity(.{ .at = c.out.items.len, .bytes = data[off..][0..n] });
            } else {
                c.out.appendSliceAssumeCapacity(data[off..][0..n]);
            }
            off += n;
            c.send_window -= @intCast(n);
            s.send_window -= @intCast(n);
        }
        return off;
    }

    /// Sends the waiting body of stream `id` within the windows.
    fn flush(c: *Conn, id: u31) Error!void {
        const s = c.streams.getPtr(id) orelse return;
        const w = s.waiting();
        if (s.out_pos >= w.len) return;
        s.out_pos += c.sendData(id, s, w[s.out_pos..], s.ref.len > 0);
        if (s.out_pos == w.len) {
            s.out.clearRetainingCapacity();
            s.ref = "";
            s.out_pos = 0;
            if (s.remote_done) c.closeStream(id);
        }
    }

    fn flushAll(c: *Conn) Error!void {
        var ids: [256]u31 = undefined;
        var n: usize = 0;
        var it = c.streams.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.out_pos < kv.value_ptr.waiting().len and n < ids.len) {
                ids[n] = kv.key_ptr.*;
                n += 1;
            }
        }
        for (ids[0..n]) |id| try c.flush(id);
    }
};

test {
    _ = @import("conn_test.zig");
}

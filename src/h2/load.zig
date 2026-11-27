//! A load client for h2c with prior knowledge, in the manner of h2load:
//! `--conns` connections with `--streams` requests in flight on each,
//! for `--seconds`. Each response that ends starts the next request on
//! its connection. It prints the requests per second and the bytes of
//! the response bodies per second.
//!
//!   zig build h2-load -- --port 8080 [--conns 16] [--streams 32] [--seconds 10]
//!
//! The client sets its windows to 2^31 - 1, decodes each HEADERS block
//! (the HPACK state of the connection needs it), and counts the DATA
//! bytes.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;
const aio = @import("aio");
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");

var done_requests: u64 = 0;
var body_bytes: u64 = 0;
var errors: u64 = 0;
var stop = false;

const Conn = struct {
    gpa: std.mem.Allocator,
    fd: aio.fd_t,
    enc: hpack.Encoder,
    dec: hpack.Decoder,
    next_id: u31 = 1,
    in: [1 << 17]u8 = undefined,
    in_len: usize = 0,
    out: std.ArrayList(u8) = .empty,
    sending: std.ArrayList(u8) = .empty,
    rd: aio.Completion = undefined,
    wr: aio.Completion = undefined,
    con: aio.Completion = undefined,
    writing: bool = false,
    path: []const u8,
    consumed: u64 = 0,

    fn request(c: *Conn) !void {
        var blk: [256]u8 = undefined;
        const n = try c.enc.encode(&blk, &.{
            .{ .name = ":method", .value = "GET" },
            .{ .name = ":scheme", .value = "http" },
            .{ .name = ":authority", .value = "127.0.0.1" },
            .{ .name = ":path", .value = c.path },
        });
        var h: [frame.header_len]u8 = undefined;
        (frame.Header{ .len = @intCast(n), .type = .headers, .flags = frame.Flags.end_headers | frame.Flags.end_stream, .stream = c.next_id }).write(&h);
        c.next_id += 2;
        try c.out.appendSlice(c.gpa, &h);
        try c.out.appendSlice(c.gpa, blk[0..n]);
    }

    fn flush(c: *Conn, l: *aio.Loop) void {
        if (c.writing or c.out.items.len == 0) return;
        std.mem.swap(std.ArrayList(u8), &c.out, &c.sending);
        c.out.clearRetainingCapacity();
        c.writing = true;
        c.wr = .{ .op = .{ .write = .{ .fd = c.fd, .buf = c.sending.items } }, .callback = onWrite, .ctx = c };
        l.submit(&c.wr) catch {};
    }

    fn onWrite(l: *aio.Loop, comp: *aio.Completion) void {
        const c: *Conn = @ptrCast(@alignCast(comp.ctx.?));
        if (comp.result <= 0) {
            errors += 1;
            return;
        }
        const n: usize = @intCast(comp.result);
        if (n < c.sending.items.len) {
            std.mem.copyForwards(u8, c.sending.items[0 .. c.sending.items.len - n], c.sending.items[n..]);
            c.sending.items.len -= n;
            comp.op.write.buf = c.sending.items;
            l.submit(comp) catch {};
            return;
        }
        c.writing = false;
        c.flush(l);
    }

    fn read(c: *Conn, l: *aio.Loop) void {
        c.rd = .{ .op = .{ .read = .{ .fd = c.fd, .buf = c.in[c.in_len..] } }, .callback = onRead, .ctx = c };
        l.submit(&c.rd) catch {};
    }

    fn onRead(l: *aio.Loop, comp: *aio.Completion) void {
        const c: *Conn = @ptrCast(@alignCast(comp.ctx.?));
        if (comp.result <= 0) {
            errors += 1;
            return;
        }
        c.in_len += @intCast(comp.result);
        var pos: usize = 0;
        while (c.in_len - pos >= frame.header_len) {
            const h = frame.Header.parse(c.in[pos..][0..frame.header_len]);
            if (c.in_len - pos - frame.header_len < h.len) break;
            const p = c.in[pos + frame.header_len ..][0..h.len];
            pos += frame.header_len + h.len;
            c.onFrame(h, p) catch {
                errors += 1;
                return;
            };
        }
        std.mem.copyForwards(u8, c.in[0 .. c.in_len - pos], c.in[pos..c.in_len]);
        c.in_len -= pos;
        c.flush(l);
        if (!stop) c.read(l);
    }

    fn onFrame(c: *Conn, h: frame.Header, p: []const u8) !void {
        switch (h.type) {
            .headers => {
                var scratch: [512]u8 = undefined;
                var b = c.dec.block(p, &scratch);
                while (try b.next()) |_| {}
                if (h.flags & frame.Flags.end_stream != 0) try c.ended();
            },
            .data => {
                body_bytes += p.len;
                c.consumed += p.len;
                if (c.consumed > 1 << 30) {
                    var b: [13]u8 = undefined;
                    try c.out.appendSlice(c.gpa, b[0..frame.writeWindowUpdate(&b, 0, @intCast(c.consumed))]);
                    c.consumed = 0;
                }
                if (h.flags & frame.Flags.end_stream != 0) try c.ended();
            },
            .settings => if (h.flags & frame.Flags.ack == 0) {
                var b: [9]u8 = undefined;
                try c.out.appendSlice(c.gpa, b[0..frame.write(&b, .settings, frame.Flags.ack, 0, "")]);
            },
            .ping => if (h.flags & frame.Flags.ack == 0) {
                var b: [17]u8 = undefined;
                try c.out.appendSlice(c.gpa, b[0..frame.write(&b, .ping, frame.Flags.ack, 0, p)]);
            },
            .goaway, .rst_stream => return error.Refused,
            else => {},
        }
    }

    fn ended(c: *Conn) !void {
        done_requests += 1;
        if (!stop and c.next_id < std.math.maxInt(u31) - 2) try c.request();
    }

    fn onConnect(l: *aio.Loop, comp: *aio.Completion) void {
        const c: *Conn = @ptrCast(@alignCast(comp.ctx.?));
        if (comp.result < 0) {
            errors += 1;
            return;
        }
        c.flush(l);
        c.read(l);
    }
};

fn stopCb(_: *aio.Loop, _: *aio.Completion) void {
    stop = true;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var port: u16 = 8080;
    var n_conns: usize = 16;
    var n_streams: usize = 32;
    var seconds: u64 = 10;
    var path: []const u8 = "/";
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const v = args[i + 1];
        if (std.mem.eql(u8, args[i], "--port")) port = try std.fmt.parseInt(u16, v, 10) else if (std.mem.eql(u8, args[i], "--conns")) n_conns = try std.fmt.parseInt(usize, v, 10) else if (std.mem.eql(u8, args[i], "--streams")) n_streams = try std.fmt.parseInt(usize, v, 10) else if (std.mem.eql(u8, args[i], "--seconds")) seconds = try std.fmt.parseInt(u64, v, 10) else if (std.mem.eql(u8, args[i], "--path")) path = v else return error.BadOption;
    }
    const gpa = std.heap.smp_allocator;
    var l = try aio.Loop.init(gpa, .{ .entries = 4096 });
    defer l.deinit();
    var addr: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    const conns = try gpa.alloc(Conn, n_conns);
    for (conns) |*c| {
        const fd = aio.result(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0));
        if (fd < 0) return error.Socket;
        const one: i32 = 1;
        _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), 4);
        c.* = .{ .gpa = gpa, .fd = fd, .enc = try .init(gpa, 4096), .dec = try .init(gpa, 4096, 1 << 16), .path = path };
        try c.out.appendSlice(gpa, frame.preface);
        var b: [64]u8 = undefined;
        var n = frame.writeSettings(&b, &.{ .{ .initial_window_size, std.math.maxInt(u31) }, .{ .enable_push, 0 } });
        n += frame.writeWindowUpdate(b[n..], 0, std.math.maxInt(u31) - frame.default_window);
        try c.out.appendSlice(gpa, b[0..n]);
        for (0..n_streams) |_| try c.request();
        c.con = .{ .op = .{ .connect = .{ .fd = fd, .addr = @ptrCast(&addr), .len = @sizeOf(linux.sockaddr.in) } }, .callback = Conn.onConnect, .ctx = c };
        try l.submit(&c.con);
    }
    var timer: aio.Completion = .{ .op = .{ .timer = .{ .ns = seconds * std.time.ns_per_s } }, .callback = stopCb };
    try l.submit(&timer);
    const t0 = aio.now();
    while (!stop) _ = try l.run(null);
    const dt = @as(f64, @floatFromInt(aio.now() - t0)) / 1e9;
    std.debug.print("{d} connections, {d} streams each, {d:.1} s: {d} requests, {d:.0} req/s, {d:.1} MB/s of bodies, {d} errors\n", .{ n_conns, n_streams, dt, done_requests, @as(f64, @floatFromInt(done_requests)) / dt, @as(f64, @floatFromInt(body_bytes)) / dt / 1e6, errors });
}

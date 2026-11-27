//! A test server of `conn.zig` for h2c with prior knowledge, on the aio
//! loop (Linux). Each request gets 200 and a body of `--body` bytes.
//!
//!   zig build h2-serve -- --port 8080 [--body 13] [--backend uring]
//!   curl --http2-prior-knowledge http://127.0.0.1:8080/
//!
//! It is the peer of `zig build h2-load` and of curl. It reads into a
//! buffer of 64 KiB for each connection and writes the bytes of
//! `Conn.pending` with one write at a time.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;
const aio = @import("aio");
const conn = @import("conn.zig");

var body_buf: [1 << 20]u8 = undefined;
var body_len: usize = 13;

fn handler(_: ?*anyopaque, c: *conn.Conn, req: *const conn.Request) void {
    c.respond(req.stream, 200, &.{.{ .name = "content-type", .value = "text/plain" }}, body_buf[0..body_len]) catch {};
}

const Client = struct {
    gpa: std.mem.Allocator,
    fd: aio.fd_t,
    h2: conn.Conn,
    in: [65536]u8 = undefined,
    in_len: usize = 0,
    rd: aio.Completion = undefined,
    wr: aio.Completion = undefined,
    writing: bool = false,
    reading: bool = false,
    done: bool = false,

    fn startRead(cl: *Client, l: *aio.Loop) void {
        if (cl.reading or cl.done) return;
        cl.reading = true;
        cl.rd = .{ .op = .{ .read = .{ .fd = cl.fd, .buf = cl.in[cl.in_len..] } }, .callback = onRead, .ctx = cl };
        l.submit(&cl.rd) catch cl.finish(l);
    }

    fn startWrite(cl: *Client, l: *aio.Loop) void {
        if (cl.writing or cl.h2.pending().len == 0) return;
        cl.writing = true;
        cl.wr = .{ .op = .{ .write = .{ .fd = cl.fd, .buf = cl.h2.pending() } }, .callback = onWrite, .ctx = cl };
        l.submit(&cl.wr) catch cl.finish(l);
    }

    fn onRead(l: *aio.Loop, c: *aio.Completion) void {
        const cl: *Client = @ptrCast(@alignCast(c.ctx.?));
        cl.reading = false;
        if (c.result <= 0) return cl.finish(l);
        cl.in_len += @intCast(c.result);
        const n = cl.h2.feed(cl.in[0..cl.in_len]) catch return cl.finish(l);
        std.mem.copyForwards(u8, cl.in[0 .. cl.in_len - n], cl.in[n..cl.in_len]);
        cl.in_len -= n;
        cl.startWrite(l);
        if (cl.h2.closed) {
            cl.done = true;
            if (!cl.writing) cl.finish(l);
            return;
        }
        if (cl.in_len == cl.in.len) return cl.finish(l);
        // Read again when the output is out, so a slow reader of the
        // responses slows the requests too.
        if (!cl.writing) cl.startRead(l);
    }

    fn onWrite(l: *aio.Loop, c: *aio.Completion) void {
        const cl: *Client = @ptrCast(@alignCast(c.ctx.?));
        cl.writing = false;
        if (c.result <= 0) return cl.finish(l);
        cl.h2.sent(@intCast(c.result));
        if (cl.h2.pending().len > 0) return cl.startWrite(l);
        if (cl.done) return cl.finish(l);
        cl.startRead(l);
    }

    fn finish(cl: *Client, _: *aio.Loop) void {
        if (cl.reading or cl.writing) {
            cl.done = true;
            _ = linux.shutdown(cl.fd, linux.SHUT.RDWR);
            return;
        }
        _ = linux.close(cl.fd);
        cl.h2.deinit();
        cl.gpa.destroy(cl);
    }
};

const Server = struct {
    gpa: std.mem.Allocator,
    lfd: aio.fd_t,
    acc: aio.Completion = undefined,

    fn onAccept(l: *aio.Loop, c: *aio.Completion) void {
        const s: *Server = @ptrCast(@alignCast(c.ctx.?));
        if (c.result >= 0) blk: {
            const fd: aio.fd_t = c.result;
            const one: i32 = 1;
            _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), 4);
            const cl = s.gpa.create(Client) catch {
                _ = linux.close(fd);
                break :blk;
            };
            cl.* = .{ .gpa = s.gpa, .fd = fd, .h2 = conn.Conn.init(s.gpa, .{}, handler, null, aio.now) catch {
                s.gpa.destroy(cl);
                _ = linux.close(fd);
                break :blk;
            } };
            cl.startWrite(l);
            cl.startRead(l);
        }
        s.acc = .{ .op = .{ .accept = .{ .fd = s.lfd } }, .callback = onAccept, .ctx = s };
        l.submit(&s.acc) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var port: u16 = 8080;
    var backend: aio.Backend = .auto;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--port")) port = try std.fmt.parseInt(u16, args[i + 1], 10) else if (std.mem.eql(u8, args[i], "--body")) body_len = try std.fmt.parseInt(usize, args[i + 1], 10) else if (std.mem.eql(u8, args[i], "--backend")) backend = std.meta.stringToEnum(aio.Backend, args[i + 1]) orelse return error.BadBackend else return error.BadOption;
    }
    if (body_len > body_buf.len) return error.BodyTooLarge;
    @memset(body_buf[0..body_len], 'x');
    const gpa = std.heap.smp_allocator;
    var l = try aio.Loop.init(gpa, .{ .backend = backend, .entries = 4096 });
    defer l.deinit();
    const lfd = aio.result(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0));
    if (lfd < 0) return error.Socket;
    const one: i32 = 1;
    _ = linux.setsockopt(lfd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
    var addr: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (aio.result(linux.bind(lfd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) < 0) return error.Bind;
    if (aio.result(linux.listen(lfd, 4096)) < 0) return error.Listen;
    std.debug.print("h2c on 127.0.0.1:{d}, backend {t}, body {d} bytes\n", .{ port, l.backend(), body_len });
    var s: Server = .{ .gpa = gpa, .lfd = lfd };
    s.acc = .{ .op = .{ .accept = .{ .fd = lfd } }, .callback = Server.onAccept, .ctx = &s };
    try l.submit(&s.acc);
    while (true) _ = try l.run(null);
}

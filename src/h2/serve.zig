//! A test server of `conn.zig` for h2c with prior knowledge, on the aio
//! loop (Linux). Each request gets 200 and a body of `--body` bytes.
//!
//!   zig build h2-serve -- --port 8080 [--body 13] [--backend uring] [--copy on] [--tls PEM]
//!   curl --http2-prior-knowledge http://127.0.0.1:8080/
//!   curl --http2 -k https://127.0.0.1:8080/      (with --tls)
//!
//! It is the peer of `zig build h2-load` and of curl. It reads into a
//! buffer of 64 KiB for each connection and writes the pieces of
//! `Conn.pendingVecs` with one writev at a time. The body goes out
//! with `respondRef`, so no copy of it is made; `--copy on` uses
//! `respond`, which copies it.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;
const aio = @import("aio");
const conn = @import("h2");
const tls_h2 = @import("tls_h2");
const server = tls_h2.server;

/// The options of TLS with `--tls`, or null for h2c.
var tls_opts: ?server.Options = null;
var io: std.Io = undefined;

/// The HTTP/2 connection of a client: h2c, or h2 in TLS.
const Transport = union(enum) {
    plain: conn.Conn,
    tls: tls_h2.Conn,

    fn feed(t: *Transport, in: []u8) !usize {
        return switch (t.*) {
            .plain => |*c| c.feed(in),
            .tls => |*c| c.feed(in),
        };
    }

    fn pending(t: *const Transport) []const u8 {
        return switch (t.*) {
            inline else => |*c| c.pending(),
        };
    }

    fn sent(t: *Transport, n: usize) void {
        switch (t.*) {
            inline else => |*c| c.sent(n),
        }
    }

    fn closed(t: *const Transport) bool {
        return switch (t.*) {
            inline else => |*c| c.closed,
        };
    }

    fn deinit(t: *Transport) void {
        switch (t.*) {
            inline else => |*c| c.deinit(),
        }
    }
};

var body_buf: [1 << 20]u8 = undefined;
var body_len: usize = 13;

var copy_body = false;

fn handler(_: ?*anyopaque, c: *conn.Conn, req: *const conn.Request) void {
    const h: []const conn.Field = &.{.{ .name = "content-type", .value = "text/plain" }};
    // The body lives as long as the program, so it can go out with no
    // copy.
    if (copy_body) c.respond(req.stream, 200, h, body_buf[0..body_len]) catch {} else c.respondRef(req.stream, 200, h, body_buf[0..body_len]) catch {};
}

const Client = struct {
    gpa: std.mem.Allocator,
    fd: aio.fd_t,
    h2: Transport,
    in: [65536]u8 = undefined,
    in_len: usize = 0,
    rd: aio.Completion = undefined,
    wr: aio.Completion = undefined,
    iov: [64]std.posix.iovec_const = undefined,
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
        switch (cl.h2) {
            // The records of TLS are in one buffer.
            .tls => |*t| cl.wr = .{ .op = .{ .write = .{ .fd = cl.fd, .buf = t.pending() } }, .callback = onWrite, .ctx = cl },
            .plain => |*h| {
                const n = h.pendingVecs(&cl.iov);
                cl.wr = .{ .op = .{ .writev = .{ .fd = cl.fd, .iov = cl.iov[0..n] } }, .callback = onWrite, .ctx = cl };
            },
        }
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
        if (cl.h2.closed()) {
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
            const t: anyerror!Transport = if (tls_opts) |o|
                if (tls_h2.Conn.init(s.gpa, o, .fill(io), .{}, handler, null, aio.now)) |x| .{ .tls = x } else |e| e
            else if (conn.Conn.init(s.gpa, .{}, handler, null, aio.now)) |x| .{ .plain = x } else |e| e;
            cl.* = .{ .gpa = s.gpa, .fd = fd, .h2 = t catch {
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
    var tls_path: ?[]const u8 = null;
    io = init.io;
    var backend: aio.Backend = .auto;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--port")) port = try std.fmt.parseInt(u16, args[i + 1], 10) else if (std.mem.eql(u8, args[i], "--body")) body_len = try std.fmt.parseInt(usize, args[i + 1], 10) else if (std.mem.eql(u8, args[i], "--tls")) tls_path = args[i + 1] else if (std.mem.eql(u8, args[i], "--copy")) copy_body = std.mem.eql(u8, args[i + 1], "on") else if (std.mem.eql(u8, args[i], "--backend")) backend = std.meta.stringToEnum(aio.Backend, args[i + 1]) orelse return error.BadBackend else return error.BadOption;
    }
    if (body_len > body_buf.len) return error.BodyTooLarge;
    if (tls_path) |path| {
        // The certificates (the leaf first) and the private key of a
        // PEM file.
        const a = init.arena.allocator();
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
        var chain: std.ArrayList([]const u8) = .empty;
        var key: ?server.pem.PrivateKey = null;
        var it = server.pem.Iterator.init(text);
        while (try it.next(a)) |b| {
            if (std.mem.eql(u8, b.label, "CERTIFICATE")) try chain.append(a, b.der) else key = try server.pem.privateKey(b);
        }
        tls_opts = .{ .chain = chain.items, .key = key orelse return error.NoKey, .alpn = &tls_h2.alpn };
    }
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
    std.debug.print("{s} on 127.0.0.1:{d}, backend {t}, body {d} bytes\n", .{ if (tls_opts != null) "h2" else "h2c", port, l.backend(), body_len });
    var s: Server = .{ .gpa = gpa, .lfd = lfd };
    s.acc = .{ .op = .{ .accept = .{ .fd = lfd } }, .callback = Server.onAccept, .ctx = &s };
    try l.submit(&s.acc);
    while (true) _ = try l.run(null);
}

//! A test client for `tools/tls-interop.sh`: it connects to a TLS
//! server on 127.0.0.1, sends an HTTP/1.0 GET, and prints the first
//! line of the answer, the suite, and the protocol of ALPN.
//!
//!   tls-interop PORT CA.pem HOST [--group G] [--suite S] [--alpn P]
//!
//! G is x25519, secp256r1, or secp384r1, and S is a name of
//! `record.Suite`. The exit code is 0 for a good handshake and 1 for a
//! failed one.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const client = @import("client.zig");
const roots = @import("roots.zig");
const record = @import("record.zig");
const tcrypto = @import("crypto.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 4) {
        std.debug.print("usage: tls-interop PORT CA.pem HOST [--group G] [--suite S] [--alpn P]\n", .{});
        std.process.exit(2);
    }
    const port = try std.fmt.parseInt(u16, args[1], 10);
    var store = roots.Roots.init(init.gpa);
    defer store.deinit();
    _ = try store.addFile(io, Io.Dir.cwd(), args[2]);
    var opts: client.Options = .{ .host = args[3], .roots = store.slice(), .now = Io.Clock.real.now(io).toSeconds() };
    var group: [1]tcrypto.Group = undefined;
    var suite: [1]record.Suite = undefined;
    var alpn: [1][]const u8 = undefined;
    var k: usize = 4;
    while (k + 1 < args.len) : (k += 2) {
        const v = args[k + 1];
        if (std.mem.eql(u8, args[k], "--group")) {
            group[0] = std.meta.stringToEnum(tcrypto.Group, v) orelse return error.BadGroup;
            opts.groups = &group;
            opts.key_shares = &group;
        } else if (std.mem.eql(u8, args[k], "--suite")) {
            suite[0] = std.meta.stringToEnum(record.Suite, v) orelse return error.BadSuite;
            opts.suites = &suite;
        } else if (std.mem.eql(u8, args[k], "--alpn")) {
            alpn[0] = v;
            opts.alpn = &alpn;
        } else return error.BadOption;
    }
    const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var rbuf: [record.max_record]u8 = undefined;
    var wbuf: [record.max_record]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var sw = stream.writer(io, &wbuf);
    const conn = try a.create(client.Conn);
    conn.init(&sr.interface, &sw.interface, opts, .fill(io));
    conn.handshake() catch |e| {
        std.debug.print("handshake failed: {t} {s}\n", .{ e, if (conn.c.sent_alert) |al| @tagName(al) else "" });
        std.process.exit(1);
    };
    try conn.writeAll("GET / HTTP/1.0\r\n\r\n");
    var first: []const u8 = "";
    var total: usize = 0;
    while (conn.read() catch |e| switch (e) {
        // `openssl s_server -www` closes the socket with no close_notify.
        error.EndOfStream, error.ReadFailed => null,
        else => return e,
    }) |d| {
        if (total == 0) first = try a.dupe(u8, d[0 .. std.mem.indexOfScalar(u8, d, '\r') orelse d.len]);
        total += d.len;
    }
    std.debug.print("ok {s} {s} alpn={s} bytes={d}\n", .{ first, @tagName(conn.c.negotiatedSuite()), conn.c.protocol() orelse "-", total });
}

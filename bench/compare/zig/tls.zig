//! Opens COUNT TLS 1.3 connections with std.crypto.tls.Client. Each one
//! does a full handshake, checks the certificate against CA_FILE, reads
//! 1 MiB to the end, and closes.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const tls = std.crypto.tls;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const port = try std.fmt.parseInt(u16, args[1], 10);
    const count = try std.fmt.parseInt(usize, args[3], 10);
    const now = std.Io.Clock.real.now(io);
    var bundle: std.crypto.Certificate.Bundle = .empty;
    try bundle.addCertsFromFilePath(a, io, now, std.Io.Dir.cwd(), args[2]);
    var lock: std.Io.RwLock = .init;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const sock_rbuf = try a.alloc(u8, tls.Client.min_buffer_len);
    const sock_wbuf = try a.alloc(u8, tls.Client.min_buffer_len);
    const tls_rbuf = try a.alloc(u8, tls.Client.min_buffer_len);
    const tls_wbuf = try a.alloc(u8, tls.Client.min_buffer_len);
    var total: usize = 0;
    for (0..count) |_| {
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var sr = stream.reader(io, sock_rbuf);
        var sw = stream.writer(io, sock_wbuf);
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);
        var c = try tls.Client.init(&sr.interface, &sw.interface, .{
            .host = .{ .explicit = "localhost" },
            .ca = .{ .bundle = .{ .gpa = a, .io = io, .lock = &lock, .bundle = &bundle } },
            .read_buffer = tls_rbuf,
            .write_buffer = tls_wbuf,
            .entropy = &entropy,
            .realtime_now = now,
        });
        total += try c.reader.discardRemaining();
    }
    var buf: [64]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("{d}\n", .{total});
    try w.interface.flush();
}

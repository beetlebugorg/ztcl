//! An HTTP/1.1 server with keep-alive from std.http.Server, on one
//! thread. It serves one connection at a time.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

const body = "{\"ok\":true,\"n\":42}";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const port = try std.fmt.parseInt(u16, args[1], 10);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    var obuf: [64]u8 = undefined;
    var o = std.Io.File.stdout().writer(io, &obuf);
    try o.interface.writeAll("ready\n");
    try o.interface.flush();
    var rbuf: [8192]u8 = undefined;
    var wbuf: [8192]u8 = undefined;
    while (true) {
        const stream = try server.accept(io);
        defer stream.close(io);
        var sr = stream.reader(io, &rbuf);
        var sw = stream.writer(io, &wbuf);
        var http = std.http.Server.init(&sr.interface, &sw.interface);
        while (true) {
            var req = http.receiveHead() catch break;
            req.respond(body, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} }) catch break;
        }
    }
}

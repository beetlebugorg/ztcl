//! The load tool of the http task. It opens one keep-alive connection to
//! 127.0.0.1:PORT, sends GET requests one after the other for SECONDS,
//! and prints the requests for each second. Each response must have a
//! Content-Length header; the tool reads exactly that many bytes of body.
//!
//!   load PORT SECONDS
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

const request = "GET /json HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const port = try std.fmt.parseInt(u16, args[1], 10);
    const seconds = try std.fmt.parseFloat(f64, args[2]);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var rbuf: [16384]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var sw = stream.writer(io, &wbuf);
    const r = &sr.interface;
    const w = &sw.interface;
    const start = std.Io.Clock.awake.now(io);
    const limit_ns: i96 = @intFromFloat(seconds * 1e9);
    var n: u64 = 0;
    var elapsed: i96 = 0;
    while (elapsed < limit_ns) {
        try w.writeAll(request);
        try w.flush();
        var len: ?usize = null;
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            if (line.len <= 2) break;
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                len = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \r\n"), 10);
            }
        }
        const body = try r.take(len orelse return error.NoContentLength);
        if (n == 0 and !std.mem.eql(u8, body, "{\"ok\":true,\"n\":42}")) return error.BadBody;
        n += 1;
        elapsed = start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    }
    var obuf: [128]u8 = undefined;
    var o = std.Io.File.stdout().writer(io, &obuf);
    try o.interface.print("{d:.0}\n", .{@as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(elapsed)) / 1e9)});
    try o.interface.flush();
}

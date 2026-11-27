//! Renders an HTML table of N rows. The Zig standard library has no
//! template engine, so the rows come from a format string and an escape
//! function.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

fn escape(out: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try out.writeAll("&amp;"),
        '<' => try out.writeAll("&lt;"),
        '>' => try out.writeAll("&gt;"),
        else => try out.writeByte(c),
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const n = try std.fmt.parseInt(usize, args[1], 10);
    var buf: [65536]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    var name: [64]u8 = undefined;
    try out.writeAll("<table>\n");
    for (0..n) |i| {
        try out.print("<tr><td>{d}</td><td>", .{i});
        try escape(out, try std.fmt.bufPrint(&name, "Part {d} & <Co>", .{i % 97}));
        try out.print("</td><td>{d:.2}</td></tr>\n", .{@as(f64, @floatFromInt(i % 1000)) * 0.25});
    }
    try out.writeAll("</table>\n");
    try out.flush();
}

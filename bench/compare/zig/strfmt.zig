//! Builds one string of N formatted lines. Each line has 32 bytes.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const n = try std.fmt.parseInt(usize, args[1], 10);
    var s: std.Io.Writer.Allocating = .init(a);
    const b = &s.writer;
    var name: [16]u8 = undefined;
    for (0..n) |i| {
        const nm = try std.fmt.bufPrint(&name, "item{d}", .{i % 1000});
        try b.print("{d:0>7}|{s:<12}|{d:>10.3}\n", .{ i, nm, @as(f64, @floatFromInt(i)) * 1.5 / 7 });
    }
    const out = s.written();
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("{d} {s}\n", .{ out.len, out[out.len - 32 .. out.len - 1] });
    try w.interface.flush();
}

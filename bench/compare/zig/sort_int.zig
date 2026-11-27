//! Reads 1M integers and sorts them.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const path = try std.fs.path.join(a, &.{ args[1], "ints.txt" });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    var xs: std.ArrayList(i64) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |t| try xs.append(a, try std.fmt.parseInt(i64, t, 10));
    std.mem.sortUnstable(i64, xs.items, {}, std.sort.asc(i64));
    const s = xs.items;
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("{d} {d} {d} {d}\n", .{ s.len, s[0], s[s.len / 2], s[s.len - 1] });
    try w.interface.flush();
}

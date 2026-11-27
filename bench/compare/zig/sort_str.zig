//! Reads 1M strings and sorts them.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

fn less(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const path = try std.fs.path.join(a, &.{ args[1], "strs.txt" });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    var xs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |t| try xs.append(a, t);
    std.mem.sortUnstable([]const u8, xs.items, {}, less);
    const s = xs.items;
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("{d} {s} {s} {s}\n", .{ s.len, s[0], s[s.len / 2], s[s.len - 1] });
    try w.interface.flush();
}

//! Parses a JSON file of records and writes it again with no spaces.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

const Record = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
    active: bool,
    score: i64,
    tags: []const []const u8,
    address: struct { city: []const u8, zip: []const u8 },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const path = try std.fs.path.join(a, &.{ args[1], "data.json" });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    const recs = try std.json.parseFromSliceLeaky([]Record, a, text, .{});
    var buf: [65536]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("{f}\n", .{std.json.fmt(recs, .{})});
    try w.interface.flush();
}

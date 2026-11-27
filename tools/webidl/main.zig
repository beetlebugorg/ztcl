//! The program of the Web IDL generator (tools/webidl/webidl.zig).
//!
//! `webidl IDL OUT` reads the `.webidl` files of the folder IDL, in the
//! order of their names, and writes the table to OUT. The group of a
//! file is its name without `.webidl`, and `base.webidl` has no group.
//! With `--check` in front, it compares the output with OUT, and the
//! exit code is 1 when they differ.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const webidl = @import("webidl.zig");

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.toSlice(a);
    var check = false;
    if (args.len > 1 and std.mem.eql(u8, args[1], "--check")) {
        check = true;
        args = args[1..];
    }
    if (args.len != 3) {
        std.debug.print("usage: webidl [--check] IDL OUT\n", .{});
        std.process.exit(2);
    }
    var dir = try Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".webidl")) try names.append(a, try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var sources: std.ArrayList(webidl.Source) = .empty;
    for (names.items) |n| {
        const stem = n[0 .. n.len - ".webidl".len];
        const group: ?[]const u8 = if (std.mem.eql(u8, stem, "base")) null else stem;
        try sources.append(a, .{ .group = group, .text = try dir.readFileAlloc(io, n, a, .limited(1 << 20)) });
    }
    const out = webidl.generate(a, sources.items) catch |e| {
        std.debug.print("webidl: {t}\n", .{e});
        std.process.exit(1);
    };
    if (check) {
        const old = Io.Dir.cwd().readFileAlloc(io, args[2], a, .limited(16 << 20)) catch "";
        if (!std.mem.eql(u8, old, out)) {
            std.debug.print("{s} is not the output of tools/webidl. Run `zig build webidl`.\n", .{args[2]});
            std.process.exit(1);
        }
        return;
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out });
}

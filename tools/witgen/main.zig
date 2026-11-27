//! The program of the bindings generator (tools/witgen/witgen.zig).
//!
//! `witgen WIT NEEDED OUT` reads the `.wit` files of the folder WIT and of
//! each folder of WIT/deps, in the order of their names, and writes the
//! bindings of the functions of NEEDED to OUT. With `--check` in front, it
//! compares the output with OUT, and the exit code is 1 when they differ.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const witgen = @import("witgen.zig");

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// Appends the `.wit` files of one folder, in the order of their names.
fn addDir(a: std.mem.Allocator, io: Io, out: *std.ArrayList(witgen.Source), path: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".wit")) try names.append(a, try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |n| {
        const full = try std.fs.path.join(a, &.{ path, n });
        try out.append(a, .{ .dir = path, .path = full, .text = try dir.readFileAlloc(io, n, a, .limited(1 << 20)) });
    }
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
    if (args.len != 4) {
        std.debug.print("usage: witgen [--check] WIT NEEDED OUT\n", .{});
        std.process.exit(2);
    }
    var sources: std.ArrayList(witgen.Source) = .empty;
    try addDir(a, io, &sources, args[1]);
    const deps = try std.fs.path.join(a, &.{ args[1], "deps" });
    var dir = try Io.Dir.cwd().openDir(io, deps, .{ .iterate = true });
    var pkgs: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        if (e.kind == .directory) try pkgs.append(a, try a.dupe(u8, e.name));
    }
    dir.close(io);
    std.mem.sort([]const u8, pkgs.items, {}, lessThan);
    for (pkgs.items) |p| try addDir(a, io, &sources, try std.fs.path.join(a, &.{ deps, p }));

    const needed = try Io.Dir.cwd().readFileAlloc(io, args[2], a, .limited(1 << 20));
    const out = witgen.generate(a, sources.items, needed) catch |e| {
        std.debug.print("witgen: {t}\n", .{e});
        std.process.exit(1);
    };
    if (check) {
        const old = Io.Dir.cwd().readFileAlloc(io, args[3], a, .limited(16 << 20)) catch "";
        if (!std.mem.eql(u8, old, out)) {
            std.debug.print("{s} is not the output of witgen. Run `zig build witgen`.\n", .{args[3]});
            std.process.exit(1);
        }
        return;
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = out });
}

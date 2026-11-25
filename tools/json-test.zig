//! Runs the files of JSONTestSuite (`test_parsing/`) through both forms
//! of the JSON parser and through `std.json.Scanner`.
//!
//!   zig build json-test -- path/to/JSONTestSuite/test_parsing
//!
//! Each `y_` file must parse, and each `n_` file must fail, on both
//! forms. The result of each `i_` file is listed. The parse gives `null`
//! the value "null". The run fails when a `y_` or an `n_` file has the
//! wrong result, or when the two forms do not agree.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl");
const Io = std.Io;
const json = tcl.json;

fn verdict(it: *tcl.Interp, text: []const u8, scalar: bool) !?[]const u8 {
    const v = json.build.parse(it, text, .{ .null_value = .{ .str = "null" }, .scalar = scalar }) catch |e| switch (e) {
        error.TclError => return null,
        else => return e,
    };
    return try it.str(v);
}

fn stdAccepts(a: std.mem.Allocator, text: []const u8) bool {
    const v = std.json.parseFromSlice(std.json.Value, a, text, .{ .max_value_len = text.len + 1 }) catch return false;
    v.deinit();
    return true;
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: json-test DIR\n", .{});
        std.process.exit(2);
    }
    var dir = try Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".json")) try names.append(init.arena.allocator(), try init.arena.allocator().dupe(u8, e.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var y_ok: usize = 0;
    var y_all: usize = 0;
    var n_ok: usize = 0;
    var n_all: usize = 0;
    var bad: usize = 0;
    var std_diff: usize = 0;
    for (names.items) |name| {
        const text = try dir.readFileAlloc(io, name, a, .limited(64 << 20));
        defer a.free(text);
        var it: tcl.Interp = undefined;
        try it.init(a);
        defer it.deinit();
        const vec = try verdict(&it, text, false);
        const sca = try verdict(&it, text, true);
        const ok = vec != null;
        if (ok != (sca != null) or (ok and !std.mem.eql(u8, vec.?, sca.?))) {
            std.debug.print("DIFF {s}: the two forms do not agree\n", .{name});
            bad += 1;
        }
        if (ok != stdAccepts(a, text)) {
            std_diff += 1;
            std.debug.print("std.json differs: {s} (ztcl {s})\n", .{ name, if (ok) "accepts" else "rejects" });
        }
        switch (name[0]) {
            'y' => {
                y_all += 1;
                if (ok) y_ok += 1 else {
                    bad += 1;
                    std.debug.print("FAIL {s}: rejected\n", .{name});
                }
            },
            'n' => {
                n_all += 1;
                if (!ok) n_ok += 1 else {
                    bad += 1;
                    std.debug.print("FAIL {s}: accepted\n", .{name});
                }
            },
            else => std.debug.print("{s} {s}\n", .{ if (ok) "accept" else "reject", name }),
        }
    }
    std.debug.print("y_ accepted {d}/{d}, n_ rejected {d}/{d}, differences from std.json {d}, failures {d}\n", .{ y_ok, y_all, n_ok, n_all, std_diff, bad });
    if (bad != 0) std.process.exit(1);
}

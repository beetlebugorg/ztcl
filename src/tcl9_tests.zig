//! Tests of the Tcl release switch (`Interp.tcl`). Each case runs a
//! script in an interpreter that follows Tcl 8.6 and in one that follows
//! Tcl 9.1, and compares each result with the result of tclsh 8.6.16 and
//! tclsh 9.1.0. A result that starts with "!" is an error message.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl.zig");
const cap = tcl.interp.Capability;

/// One script and the result of each release.
const Case = struct { []const u8, []const u8, []const u8 };

fn run(it: *tcl.Interp, script: []const u8) ![]const u8 {
    if (it.eval(script)) |v| return it.str(v) else |e| switch (e) {
        error.TclError => return std.fmt.allocPrint(it.alloc(), "!{s}", .{try it.str(it.result)}),
        else => return e,
    }
}

fn checkOne(v: tcl.interp.TclVersion, caps: u32, script: []const u8, want: []const u8) !void {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(caps);
    try it.setTclVersion(v);
    const got = try run(&it, script);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("Tcl {s}: {s}\nwant: {s}\ngot:  {s}\n", .{ v.version(), script, want, got });
        return error.TestUnexpectedResult;
    }
}

fn check(caps: u32, cases: []const Case) !void {
    for (cases) |c| {
        try checkOne(.v8_6, caps, c[0], c[1]);
        try checkOne(.v9_1, caps, c[0], c[2]);
    }
}

test "the release sets the version and the patch level" {
    try check(0, &.{
        .{ "info tclversion", "8.6", "9.1" },
        .{ "info patchlevel", "8.6.16", "9.1.0" },
        .{ "list $tcl_version $tcl_patchLevel", "8.6 8.6.16", "9.1 9.1.0" },
    });
    try check(@backingInt(cap.package), &.{
        .{ "package provide Tcl", "8.6.16", "9.1.0" },
        .{ "package require Tcl", "8.6.16", "9.1.0" },
        .{ "package vsatisfies [package provide Tcl] 9", "0", "1" },
    });
}

test "a child interpreter follows the release of its parent" {
    const caps = @backingInt(cap.interp);
    try check(caps, &.{
        .{ "interp create c; c eval info patchlevel", "8.6.16", "9.1.0" },
        .{ "interp create c -tcl 9.1; c eval info patchlevel", "9.1.0", "9.1.0" },
        .{ "interp create -tcl 8.6 c; c eval info patchlevel", "8.6.16", "8.6.16" },
        .{ "interp create -safe -tcl 9.1 -- c; list [interp issafe c] [c eval info tclversion]", "1 9.1", "1 9.1" },
        .{ "interp create -tcl 9.0 c", "!bad Tcl version \"9.0\": must be 8.6 or 9.1", "!bad Tcl version \"9.0\": must be 8.6 or 9.1" },
        .{ "interp create -bad c", "!bad option \"-bad\": must be -safe or --", "!bad option \"-bad\": must be -safe or --" },
    });
}

test "a change of the release after a package command retags Tcl" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(cap.package));
    try std.testing.expectEqualStrings("8.6.16", try run(&it, "package provide Tcl"));
    try it.setTclVersion(.v9_1);
    try std.testing.expectEqualStrings("9.1.0", try run(&it, "package provide Tcl"));
}

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

const no86 = "!invalid command name \"";

test "lseq in Tcl 9.1" {
    try check(0, &.{
        .{ "lseq 5", no86 ++ "lseq\"", "0 1 2 3 4" },
        .{ "lseq 0", no86 ++ "lseq\"", "" },
        .{ "lseq 5 1", no86 ++ "lseq\"", "5 4 3 2 1" },
        .{ "lseq 1 to 5 by 2", no86 ++ "lseq\"", "1 3 5" },
        .{ "lseq 1 .. 5", no86 ++ "lseq\"", "1 2 3 4 5" },
        .{ "lseq 1 count 4 3", no86 ++ "lseq\"", "1 4 7 10" },
        .{ "lseq 0 1 0.25", no86 ++ "lseq\"", "0.0 0.25 0.5 0.75 1.0" },
        .{ "lseq 0 1 0.1", no86 ++ "lseq\"", "0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0" },
        .{ "lseq 1.5 4", no86 ++ "lseq\"", "1.5 2.5 3.5" },
        .{ "lseq 1e3 1002", no86 ++ "lseq\"", "1000.0 1001.0 1002.0" },
        .{ "lseq 5 1 -2", no86 ++ "lseq\"", "5 3 1" },
        .{ "lseq 1 5 -1", no86 ++ "lseq\"", "" },
        .{ "lseq 1 5 0", no86 ++ "lseq\"", "1" },
        .{ "lseq a", no86 ++ "lseq\"", "!expected number but got \"a\"" },
        .{ "lseq 1 to", no86 ++ "lseq\"", "!missing \"to\" value." },
        .{ "lseq 1 5 by", no86 ++ "lseq\"", "!missing \"by\" value." },
        .{ "lseq 1 2 3 4 5 6", no86 ++ "lseq\"", "!wrong # args: should be \"lseq n ??op? n ??by? n??\"" },
    });
}

test "list commands of Tcl 9.1" {
    try check(0, &.{
        .{ "set l {a b c}; list [lpop l] $l", no86 ++ "lpop\"", "c {a b}" },
        .{ "set l {{a b} c}; list [lpop l 0 1] $l", no86 ++ "lpop\"", "b {a c}" },
        .{ "set l {}; lpop l", no86 ++ "lpop\"", "!index \"end\" out of range" },
        .{ "set l {a b}; lpop l 5", no86 ++ "lpop\"", "!index \"5\" out of range" },
        .{ "lremove {a b c d} 1 end", no86 ++ "lremove\"", "a c" },
        .{ "lremove {a b c d} 0 0 2", no86 ++ "lremove\"", "b d" },
        .{ "set l {a b c d}; ledit l 1 2 X Y Z; set l", no86 ++ "ledit\"", "a X Y Z d" },
        .{ "set l {a b c d}; ledit l 1 0 X", no86 ++ "ledit\"", "a X b c d" },
        .{ "lfilter x {1 2 3 4} {expr {$x > 2}}", no86 ++ "lfilter\"", "3 4" },
        .{ "lfilter {a b} {1 2 3 4} {expr {$b == 4}}", no86 ++ "lfilter\"", "3" },
    });
}

test "subcommands of Tcl 9.1" {
    try check(0, &.{
        .{ "string insert abc 1 X", "!unknown or ambiguous subcommand \"insert\": must be bytelength, cat, compare, equal, first, index, is, last, length, map, match, range, repeat, replace, reverse, tolower, totitle, toupper, trim, trimleft, trimright, wordend, or wordstart", "aXbc" },
        .{ "list [string insert abc end X] [string insert abc 10 X] [string insert abc -1 X] [string insert abc end-1 X]", "!unknown or ambiguous subcommand \"insert\": must be bytelength, cat, compare, equal, first, index, is, last, length, map, match, range, repeat, replace, reverse, tolower, totitle, toupper, trim, trimleft, trimright, wordend, or wordstart", "abcX abcX Xabc abXc" },
        .{ "string bytelength abc", "3", "!unknown or ambiguous subcommand \"bytelength\": must be cat, compare, equal, first, index, insert, is, last, length, map, match, range, repeat, replace, reverse, tolower, totitle, toupper, trim, trimleft, trimright, wordend, or wordstart" },
        .{ "list [string is dict {a b}] [string is dict a]", "!bad class \"dict\": must be alnum, alpha, ascii, control, boolean, digit, double, entier, false, graph, integer, list, lower, print, punct, space, true, upper, wideinteger, wordchar, or xdigit", "1 0" },
        .{ "list [dict getdef {a 1} b 9] [dict getwithdefault {a 1} a 9] [dict getdef {a {b 2}} a b 0]", "!unknown or ambiguous subcommand \"getdef\": must be append, create, exists, filter, for, get, incr, info, keys, lappend, map, merge, remove, replace, set, size, unset, update, values, or with", "9 1 2" },
        .{ "dict getdef {a 1} a", "!unknown or ambiguous subcommand \"getdef\": must be append, create, exists, filter, for, get, incr, info, keys, lappend, map, merge, remove, replace, set, size, unset, update, values, or with", "!wrong # args: should be \"dict getdef dictionary ?key ...? key default\"" },
        .{ "array set B {x 1 y 2}; set r {}; array for {k v} B {lappend r $k $v}; set r", "!unknown or ambiguous subcommand \"for\": must be anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, or unset", "x 1 y 2" },
        .{ "array for {k v} nosuch {}", "!unknown or ambiguous subcommand \"for\": must be anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, or unset", "!\"nosuch\" isn't an array" },
    });
}

test "a change of the release adds and removes the commands of 9.1" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.setTclVersion(.v9_1);
    try std.testing.expectEqualStrings("lseq", try run(&it, "info commands lseq"));
    try it.setTclVersion(.v8_6);
    try std.testing.expectEqualStrings("", try run(&it, "info commands lseq"));
}

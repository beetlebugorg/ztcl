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
        .{ "lpop", no86 ++ "lpop\"", "!wrong # args: should be \"lpop listvar ?index?\"" },
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
        .{ "array set A {x 1}; array default set A 0; list $A(x) $A(y) [info exists A(y)] [array size A] [array get A]", "!unknown or ambiguous subcommand \"default\": must be anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, or unset", "1 0 0 1 {x 1}" },
        .{ "array default set B 7; incr B(k); lappend B(l) 2; list $B(k) $B(l) [array default get B] [array default exists B]", "!unknown or ambiguous subcommand \"default\": must be anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, or unset", "8 {7 2} 7 1" },
        .{ "array set C {}; array default set C {a b}; upvar 0 C(z) z; proc p {} {global C; set C(w)}; list $z [p] [dict set C(d) k v]", "!unknown or ambiguous subcommand \"default\": must be anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, or unset", "{a b} {a b} {a b k v}" },
        .{ "array set D {}; array default set D 1; array default unset D; list [array default exists D] [catch {set D(x)}]", "!unknown or ambiguous subcommand \"default\": must be anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, or unset", "0 1" },
        .{ "array set E {}; array default get E", "!unknown or ambiguous subcommand \"default\": must be anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, or unset", "!array has no default value" },
        .{ "set F 1; array default set F 2", "!unknown or ambiguous subcommand \"default\": must be anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, or unset", "!can't array default set \"F\": variable isn't array" },
        .{ "array default get nosuch", "!unknown or ambiguous subcommand \"default\": must be anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, or unset", "!\"nosuch\" isn't an array" },
        .{ "array default bogus a", "!unknown or ambiguous subcommand \"default\": must be anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, or unset", "!bad option \"bogus\": must be get, set, exists, or unset" },
        .{ "array default set a", "!unknown or ambiguous subcommand \"default\": must be anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, or unset", "!wrong # args: should be \"::tcl::array::default set arrayName value\"" },
        .{ "array set G {}; array default set G 4; trace add variable G read {apply {args {}}}; set G(q)", "!unknown or ambiguous subcommand \"default\": must be anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, or unset", "4" },
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

test "variable names in namespace eval" {
    try check(0, &.{
        .{ "set g 1; namespace eval q {set g}", "1", "!can't read \"g\": no such variable" },
        .{ "set g 1; namespace eval q {set g 2}; list $g [info exists q::g]", "2 0", "1 1" },
        .{ "namespace eval a {}; set a::v 5; namespace eval q {set a::v}", "5", "!can't read \"a::v\": no such variable" },
        .{ "namespace eval q {incr h}; list [info exists ::h] [info exists q::h]", "0 1", "0 1" },
        .{ "set g 1; proc p {} {set ::g}; p", "1", "1" },
    });
}

test "numbers with a leading zero" {
    try check(0, &.{
        .{ "expr {010}", "8", "10" },
        .{ "expr {0o10}", "8", "8" },
        .{ "expr {08 + 1}", "!invalid bareword \"08\"\nin expression \"08 + 1\";\nshould be \"$08\" or \"{08}\" or \"08(...)\" or ... (invalid octal number?)", "9" },
        .{ "string is integer 08", "0", "1" },
        .{ "incr x 010", "8", "10" },
        .{ "lindex {a b c d e f g h i j k} 010", "i", "k" },
    });
}

test "tcl_precision is absent in Tcl 9.1" {
    try check(0, &.{
        .{ "set tcl_precision", "0", "!can't read \"tcl_precision\": no such variable" },
        .{ "info exists tcl_precision", "1", "0" },
    });
}

test "encoding profiles of Tcl 9.1" {
    const caps = @backingInt(cap.channels);
    try check(caps, &.{
        .{ "string length [encoding convertfrom utf-8 \"a\\xffb\"]", "3", "!unexpected byte sequence starting at index 1: '\\xFF'" },
        .{ "catch {encoding convertfrom utf-8 \"a\\xffb\"} m o; dict get $o -errorcode", "!key \"-errorcode\" not known in dictionary", "TCL ENCODING ILLEGALSEQUENCE 1" },
        .{ "encoding convertfrom -profile replace utf-8 \"a\\xffb\"", "!wrong # args: should be \"encoding convertfrom ?encoding? data\"", "a\u{FFFD}b" },
        .{ "list [encoding convertfrom -failindex i utf-8 \"a\\xffb\"] $i", "!wrong # args: should be \"encoding convertfrom ?encoding? data\"", "a 1" },
        .{ "encoding convertto ascii \"a\\u00e9\"", "a?", "!unexpected character at index 1: 'U+0000E9'" },
        .{ "list [encoding convertto -failindex j ascii \"ab\\u00e9c\"] $j", "!wrong # args: should be \"encoding convertto ?encoding? data\"", "ab 2" },
        .{ "encoding convertfrom ascii \"a\\xe9\"", "a\u{e9}", "!unexpected byte sequence starting at index 1: '\\xE9'" },
        .{ "encoding convertfrom -profile bogus utf-8 a", "!wrong # args: should be \"encoding convertfrom ?encoding? data\"", "!bad profile name \"bogus\": must be replace, strict, or tcl8" },
        .{ "encoding profiles", "!unknown or ambiguous subcommand \"profiles\": must be convertfrom, convertto, dirs, names, or system", "replace strict tcl8" },
        .{ "encoding bogus", "!unknown or ambiguous subcommand \"bogus\": must be convertfrom, convertto, dirs, names, or system", "!unknown or ambiguous subcommand \"bogus\": must be convertfrom, convertto, dirs, names, profiles, system, or user" },
    });
}

test "switch -integer of Tcl 9.1" {
    try check(0, &.{
        .{ "switch -integer 0x10 16 {set r a} default {set r b}", "!bad option \"-integer\": must be -exact, -glob, -indexvar, -matchvar, -nocase, -regexp, or --", "a" },
        .{ "switch -integer 10 010 {set r a} default {set r b}", "!bad option \"-integer\": must be -exact, -glob, -indexvar, -matchvar, -nocase, -regexp, or --", "a" },
        .{ "switch -integer -- 2 {1 {set r a} 2 {set r b}}", "!bad option \"-integer\": must be -exact, -glob, -indexvar, -matchvar, -nocase, -regexp, or --", "b" },
        .{ "switch -integer abc default {set r d}", "!bad option \"-integer\": must be -exact, -glob, -indexvar, -matchvar, -nocase, -regexp, or --", "!expected integer but got \"abc\"" },
        .{ "switch -integer 5 abc {set r a} 5 {set r b}", "!bad option \"-integer\": must be -exact, -glob, -indexvar, -matchvar, -nocase, -regexp, or --", "!expected integer but got \"abc\"" },
        .{ "switch -integer 1 1 {set r a} abc {set r b}", "!bad option \"-integer\": must be -exact, -glob, -indexvar, -matchvar, -nocase, -regexp, or --", "a" },
        .{ "switch -integer 9223372036854775808 1 {}", "!bad option \"-integer\": must be -exact, -glob, -indexvar, -matchvar, -nocase, -regexp, or --", "!integer value too large to represent" },
        .{ "switch -integer -nocase 1 1 {set r a}", "!bad option \"-integer\": must be -exact, -glob, -indexvar, -matchvar, -nocase, -regexp, or --", "!-nocase option cannot be used with -integer option" },
        .{ "switch -integer -exact 1 1 {set r a}", "!bad option \"-integer\": must be -exact, -glob, -indexvar, -matchvar, -nocase, -regexp, or --", "!bad option \"-exact\": -integer option already found" },
        .{ "switch -i 1 1 {set r a}", "!-indexvar option requires -regexp option", "!ambiguous option \"-i\": must be -exact, -glob, -indexvar, -integer, -matchvar, -nocase, -regexp, or --" },
    });
}

test "the math functions and commands of Tcl 9.1" {
    try check(0, &.{
        .{ "expr {trunc(-2.5)}", "!invalid command name \"tcl::mathfunc::trunc\"", "-2.0" },
        .{ "expr {log2(8) + cbrt(8) + exp2(3)}", "!invalid command name \"tcl::mathfunc::log2\"", "13.0" },
        .{ "expr {gamma(27)}", "!invalid command name \"tcl::mathfunc::gamma\"", "4.0329146112660565e+26" },
        .{ "expr {erf(1)}", "!invalid command name \"tcl::mathfunc::erf\"", "0.8427007929497149" },
        .{ "expr {ldexp(1, 2**31)}", "!invalid command name \"tcl::mathfunc::ldexp\"", "0.0" },
        .{ "expr {ldexp(1, 1.5)}", "!invalid command name \"tcl::mathfunc::ldexp\"", "!expected integer but got \"1.5\"" },
        .{ "expr {isnan(NaN) + isinf(10**400) + signbit(-(10**30))}", "!invalid command name \"tcl::mathfunc::isnan\"", "3" },
        .{ "expr {trunc(NaN)}", "!invalid command name \"tcl::mathfunc::trunc\"", "!floating point value is Not a Number" },
        .{ "expr {log2(-1)}", "!invalid command name \"tcl::mathfunc::log2\"", "!domain error: argument not in valid range" },
        .{ "expr {fma(1, 2)}", "!invalid command name \"tcl::mathfunc::fma\"", "!not enough arguments for math function \"fma\"" },
        .{ "divmod -7 2", "!invalid command name \"divmod\"", "-4 1" },
        .{ "divmod 1000000000000000000000000000000 7", "!invalid command name \"divmod\"", "142857142857142857142857142857 1" },
        .{ "divmod 7 2.0", "!invalid command name \"divmod\"", "!divisor must be an integer" },
        .{ "list [frexp 10] [modf -2.5] [remquo 6 4] [fpclassify 1e-310]", "!invalid command name \"frexp\"", "{0.625 4} {-2.0 -0.5} {-2.0 2} subnormal" },
    });
}

test "the string order operators and the comments of expr in Tcl 9.1" {
    try check(0, &.{
        .{ "expr {\"a\" lt \"b\"}", "!invalid bareword \"lt\"\nin expression \"\"a\" lt \"b\"\";\nshould be \"$lt\" or \"{lt}\" or \"lt(...)\" or ...", "1" },
        .{ "list [expr {10 lt 9}] [expr {\"a\" le \"a\"}] [expr {\"b\" gt \"a\"}] [expr {\"a\" ge \"b\"}]", "!invalid bareword \"lt\"\nin expression \"10 lt 9\";\nshould be \"$lt\" or \"{lt}\" or \"lt(...)\" or ...", "1 1 1 0" },
        .{ "expr {\"b\" lt \"a\" == 0}", "!invalid bareword \"lt\"\nin expression \"\"b\" lt \"a\" == 0\";\nshould be \"$lt\" or \"{lt}\" or \"lt(...)\" or ...", "1" },
        .{ "tcl::mathop::lt a b c", "!invalid command name \"tcl::mathop::lt\"", "1" },
        .{ "tcl::mathop::ge c b b", "!invalid command name \"tcl::mathop::ge\"", "1" },
        .{ "expr {1 + # one\n 2}", "!invalid character \"#\"\nin expression \"1 + # one\n 2\"", "3" },
        .{ "expr {1 lt}", "!invalid bareword \"lt\"\nin expression \"1 lt\";\nshould be \"$lt\" or \"{lt}\" or \"lt(...)\" or ...", "!missing operand at _@_\nin expression \"1 lt_@_\"" },
    });
}

test "the number forms 0d10 and 1_000 of Tcl 9.1" {
    try check(0, &.{
        .{ "expr {1_000 + 0d10}", "!invalid bareword \"1_000\"\nin expression \"1_000 + 0d10\";\nshould be \"$1_000\" or \"{1_000}\" or \"1_000(...)\" or ...", "1010" },
        .{ "set x 0; incr x 1_0", "!expected integer but got \"1_0\"", "10" },
        .{ "string is double 1_0.5", "0", "1" },
        .{ "lindex {a b c} 0d1", "!bad index \"0d1\": must be integer?[+-]integer? or end?[+-]integer?", "b" },
        .{ "expr {\"0x1_0\" + 1}", "!can't use non-numeric string as operand of \"+\"", "17" },
        .{ "string is entier 1_000_000_000_000_000_000_000", "0", "1" },
        .{ "list [string is integer 1_] [string is integer _1] [string is integer 0x_1] [string is integer 1__0]", "0 0 0 0", "0 0 0 1" },
    });
}

test "lsearch -stride of Tcl 9.1" {
    const bad = "!bad option \"-stride\": must be -all, -ascii, -bisect, -decreasing, -dictionary, -exact, -glob, -increasing, -index, -inline, -integer, -nocase, -not, -real, -regexp, -sorted, -start, or -subindices";
    try check(0, &.{
        .{ "lsearch -stride 2 {a 1 b 2 c 3 b 4} b", bad, "2" },
        .{ "lsearch -stride 2 -index 1 -inline {a 1 b 2 c 3 b 4} 2", bad, "b 2" },
        .{ "lsearch -stride 2 -all -inline {a 1 b 2 c 3 b 4} b", bad, "b 2 b 4" },
        .{ "lsearch -stride 2 -subindices -index 1 -all {a 1 b 2 c 3 b 4} *", bad, "1 3 5 7" },
        .{ "lsearch -stride 2 -subindices -index {1 0} {a {x y} b {z w}} z", bad, "3 0" },
        .{ "lsearch -stride 2 -start 1 {b 1 b 2} b", bad, "0" },
        .{ "lsearch -stride 2 -bisect -inline {a 1 b 2 c 3} bb", bad, "b 2" },
        .{ "lsearch -stride 3 {a 1 b 2} b", bad, "!list size must be a multiple of the stride length" },
        .{ "lsearch -stride 0 {a 1} b", bad, "!stride length must be at least 1" },
        .{ "lsearch -stride 2 -index 2 {a 1} b", bad, "!when used with \"-stride\", the leading \"-index\" value must be within the group" },
    });
}

test "lsearch -subindices -inline gives the whole element in 8.6 with no -all" {
    try check(0, &.{
        .{ "lsearch -subindices -index 1 -inline {{x 1} {y 2}} 2", "y 2", "2" },
        .{ "lsearch -subindices -index {1 0} -inline {{x {1 a}}} 1", "x {1 a}", "1" },
        .{ "lsearch -subindices -index 1 -all -inline {{x 1} {y 2}} *", "1 2", "1 2" },
        .{ "lsearch -subindices -index 1 {{x 1} {y 2}} 2", "1 1", "1 1" },
    });
}

test "a \\u escape of each surrogate half is one character in 9.1" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    // 8.6 joins a high half and a low half after it.
    try std.testing.expectEqualStrings("1", try run(&it, "string length \"\\uD83D\\uDE02\""));
    try it.setTclVersion(.v9_1);
    try std.testing.expectEqualStrings("2", try run(&it, "string length \"\\uD83D\\uDE02\""));
    try std.testing.expectEqualStrings("1", try run(&it, "set x \\uD83D; append x \\uDE02; expr {$x eq \"\\uD83D\\uDE02\"}"));
    try std.testing.expectEqualStrings("1", try run(&it, "expr {[string reverse \\uD83D\\uDE02] eq \"\\uDE02\\uD83D\"}"));
    try std.testing.expectEqualStrings("2", try run(&it, "string length [subst {\\uD83D\\uDE02}]"));
}

test "coroinject and coroprobe in 9.1" {
    if (!tcl.coro.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try std.testing.expectEqualStrings("", try run(&it, "info commands coroinject"));
    try it.setTclVersion(.v9_1);
    // The command put in last runs first, with the suspending command and
    // the resume value, and its result goes on.
    try std.testing.expectEqualStrings("{} {} {x y} {yield x B yield x A}", try run(&it,
        \\set ::r {}
        \\coroutine d apply {{} { lmap i {1 2} yield }}
        \\coroinject d apply {{op val} {lappend ::r $op $val A; return $val}}
        \\coroinject d apply {{op val} {lappend ::r $op $val B; return $val}}
        \\list $::r [d x] [d y] $::r
    ));
    try std.testing.expectEqualStrings("1 {} 2 {{a b} {c d}}", try run(&it,
        \\coroutine e apply {{} { lmap i {1 2} {yieldto string cat} }}
        \\list [coroprobe e set i] [e a b] [coroprobe e set i] [e c d]
    ));
    try std.testing.expectEqualStrings("1 {} 2", try run(&it,
        \\coroutine f apply {{} { foreach i {1 2} yield }}
        \\list [catch {coroprobe f set}] [f] [coroprobe f set i]
    ));
}

test "lset: an index past the end in each release, and an add at each level" {
    try check(0, &.{
        .{ "set l {a b}; catch {lset l 5 c} m o; list $m [dict get $o -errorcode]", "{list index out of range} {TCL OPERATION LSET BADINDEX}", "{index \"5\" out of range} {TCL VALUE INDEX OUTOFRANGE}" },
        .{ "set l {a b}; catch {lset l end+2 c} m; set m", "list index out of range", "index \"end+2\" out of range" },
        .{ "set l {a {b c}}; catch {lset l 1 3 x} m; set m", "list index out of range", "index \"3\" out of range" },
        .{ "set l {a b c}; lset l 3 0 c", "a b c c", "a b c c" },
        .{ "set l {a {b c}}; lset l 1 2 0 x", "a {b c x}", "a {b c x}" },
        .{ "set l {}; lset l 0 0 0 x", "x", "x" },
        .{ "set l {a}; lset l {1 0} x", "a x", "a x" },
    });
}

test "string last and a bad regular expression: the messages of each release" {
    try check(0, &.{
        .{ "string last a", "!wrong # args: should be \"string last needleString haystackString ?startIndex?\"", "!wrong # args: should be \"string last needleString haystackString ?lastIndex?\"" },
        .{ "string first a", "!wrong # args: should be \"string first needleString haystackString ?startIndex?\"", "!wrong # args: should be \"string first needleString haystackString ?startIndex?\"" },
        .{ "regexp {(} x", "!couldn't compile regular expression pattern: parentheses () not balanced", "!cannot compile regular expression pattern: parentheses () not balanced" },
        .{ "regsub {(} x y", "!couldn't compile regular expression pattern: parentheses () not balanced", "!cannot compile regular expression pattern: parentheses () not balanced" },
        .{ "lsearch -regexp {a} (", "!couldn't compile regular expression pattern: parentheses () not balanced", "!cannot compile regular expression pattern: parentheses () not balanced" },
    });
}

test "dict map, dict incr, and string map -nocase as in Tcl" {
    try check(0, &.{
        .{ "dict map {k v} {a 1} {set k z; set v}", "z 1", "z 1" },
        .{ "dict map {k v} {a 1 b 2} {set k z}", "z z", "z z" },
        .{ "dict map {k v} {a 1 b 2} {if {$k eq \"a\"} continue; set v}", "b 2", "b 2" },
        .{ "dict map {k v} {a 1 b 2} {unset k; set v}", "!can't read \"k\": no such variable", "!can't read \"k\": no such variable" },
        .{ "set d {}; dict incr d m 0x10", "m 0x10", "m 0x10" },
        .{ "set d {}; dict incr d m 010", "m 010", "m 010" },
        .{ "set d {}; dict incr d m", "m 1", "m 1" },
        .{ "set d {}; dict incr d m 0x10; dict incr d m", "m 17", "m 17" },
        .{ "set d {m 1}; dict incr d m 0x10", "m 17", "m 17" },
        .{ "set d {}; dict incr d m abc", "!expected integer but got \"abc\"", "!expected integer but got \"abc\"" },
        .{ "string map -nocase {\u{e9} E} \u{c9}", "E", "E" },
        .{ "string map -nocase {\u{3a3} x} \u{3c3}\u{3c2}", "x\u{3c2}", "x\u{3c2}" },
        .{ "string map -nocase {\u{1c5} x} \u{1c6}\u{1c4}", "xx", "xx" },
        .{ "string map -nocase {ab X} aBAbc", "XXc", "XXc" },
        .{ "string map -nocase {\u{e9} E} a\u{e9}\u{c9}b", "aEEb", "aEEb" },
    });
}

test "the messages of an operand of the wrong type name the value and the side in 9.1" {
    try check(0, &.{
        .{ "catch {expr {\"ten\" + 1}} m o; list $m [dict get $o -errorcode]", "{can't use non-numeric string as operand of \"+\"} {ARITH DOMAIN {non-numeric string}}", "{cannot use non-numeric string \"ten\" as left operand of \"+\"} {ARITH DOMAIN {non-numeric string}}" },
        .{ "catch {expr {1 - \"ten\"}} m; set m", "can't use non-numeric string as operand of \"-\"", "cannot use non-numeric string \"ten\" as right operand of \"-\"" },
        .{ "catch {expr {!\"x\"}} m; set m", "can't use non-numeric string as operand of \"!\"", "cannot use non-numeric string \"x\" as operand of \"!\"" },
        .{ "catch {expr {7.0 % 2}} m o; list $m [dict get $o -errorcode]", "{can't use floating-point value as operand of \"%\"} {ARITH DOMAIN {floating-point value}}", "{cannot use floating-point value \"7.0\" as left operand of \"%\"} {ARITH DOMAIN {floating-point value}}" },
        .{ "set a {1 + 1}; catch {expr {$a * 2}} m o; list $m [dict get $o -errorcode]", "{can't use non-numeric string as operand of \"*\"} {ARITH DOMAIN {non-numeric string}}", "{cannot use a list as left operand of \"*\"} {ARITH DOMAIN list}" },
        .{ "catch {expr {\"\" + 1}} m; set m", "can't use empty string as operand of \"+\"", "cannot use non-numeric string \"\" as left operand of \"+\"" },
    });
}

test "file pathtype of a path with a leading ~: Tcl 8.6 expands it, Tcl 9.1 does not" {
    try check(@backingInt(cap.file), &.{
        .{ "lmap p {~ ~/a ~nobody a/~} {file pathtype $p}", "absolute absolute absolute relative", "relative relative relative relative" },
    });
}

test "the -errorcode of variable reads, lrepeat, lsearch, lsort, foreach, lmap, array, and encoding" {
    try check(0, &.{
        .{ "catch {set nod} m o; dict get $o -errorcode", "TCL LOOKUP VARNAME nod", "TCL LOOKUP VARNAME nod" },
        .{ "catch {set ::nod} m o; dict get $o -errorcode", "TCL LOOKUP VARNAME ::nod", "TCL LOOKUP VARNAME ::nod" },
        .{ "catch {set nod(x)} m o; dict get $o -errorcode", "TCL LOOKUP VARNAME nod", "TCL LOOKUP VARNAME nod" },
        .{ "array set ar {a 1}; catch {set ar(zz)} m o; dict get $o -errorcode", "TCL READ VARNAME", "TCL READ VARNAME" },
        .{ "array set ar {a 1}; catch {set ar} m o; dict get $o -errorcode", "TCL READ VARNAME", "TCL READ VARNAME" },
        .{ "proc p {} {set nod}; catch p m o; dict get $o -errorcode", "TCL READ VARNAME", "TCL READ VARNAME" },
        .{ "proc p {} {set nod(x)}; catch p m o; dict get $o -errorcode", "TCL LOOKUP VARNAME", "TCL LOOKUP VARNAME" },
        .{ "proc p {} {global nod; set nod}; catch p m o; dict get $o -errorcode", "TCL READ VARNAME", "TCL READ VARNAME" },
        .{ "catch {dict with nod {}} m o; dict get $o -errorcode", "TCL LOOKUP VARNAME nod", "TCL LOOKUP VARNAME nod" },
        .{ "catch {lrepeat -1 a} m o; dict get $o -errorcode", "TCL OPERATION LREPEAT NEGARG", "TCL OPERATION LREPEAT NEGARG" },
        .{ "catch {lsearch -bogus {a} a} m o; dict get $o -errorcode", "TCL LOOKUP INDEX option -bogus", "TCL LOOKUP INDEX option -bogus" },
        .{ "catch {lsearch -sorted -bisect -all {a b} a} m o; dict get $o -errorcode", "TCL OPERATION LSEARCH BAD_OPTION_MIX", "TCL OPERATION LSEARCH BAD_OPTION_MIX" },
        .{ "catch {lsort -bogus {a}} m o; dict get $o -errorcode", "TCL LOOKUP INDEX option -bogus", "TCL LOOKUP INDEX option -bogus" },
        .{ "catch {lsort -real {1 x}} m o; dict get $o -errorcode", "TCL VALUE NUMBER", "TCL VALUE NUMBER" },
        .{ "catch {lsort -index 1 {{a 1} {b}}} m o; dict get $o -errorcode", "TCL OPERATION LSORT INDEXFAILED", "TCL OPERATION LSORT INDEXFAILED" },
        .{ "catch {lsort -stride 3 {a b}} m o; dict get $o -errorcode", "TCL OPERATION LSORT BADSTRIDE", "TCL OPERATION LSORT BADSTRIDE" },
        .{ "catch {foreach {} {1} {}} m o; dict get $o -errorcode", "TCL OPERATION FOREACH NEEDVARS", "TCL OPERATION FOREACH NEEDVARS" },
        .{ "catch {lmap {} {1} {set x}} m o; dict get $o -errorcode", "TCL OPERATION LMAP NEEDVARS", "TCL OPERATION LMAP NEEDVARS" },
        .{ "catch {array nope a} m o; dict get $o -errorcode", "TCL LOOKUP SUBCOMMAND nope", "TCL LOOKUP SUBCOMMAND nope" },
    });
}

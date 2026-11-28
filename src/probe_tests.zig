//! Tests of the probes (`probe.zig`): the targets, the limits, the
//! queries, and the rule that a probe does not change the compute units,
//! the result, or the error state of a script.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl.zig");
const probe = @import("probe.zig");
const options = @import("build_options");

fn ev(it: *tcl.Interp, script: []const u8) ![]const u8 {
    const v = it.eval(script) catch |e| {
        std.debug.print("error in {s}: {s}\n", .{ script, it.str(it.result) catch "" });
        return e;
    };
    return it.str(v);
}

const parse_proc =
    \\proc parse {n} {
    \\    set toks {}
    \\    for {set i 0} {$i < $n} {incr i} {
    \\        lappend toks t$i
    \\        catch {
    \\            set last $i
    \\        }
    \\    }
    \\    return [llength $toks]
    \\}
    \\
;

fn newInterp(it: *tcl.Interp) !void {
    try it.init(std.testing.allocator);
    it.compute_limit = 10_000_000;
}

test "ztcl::probe is absent before package require" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    try std.testing.expect(it.findCommand("ztcl::probe") == null);
    _ = try ev(&it, "package require ztcl::probe");
    try std.testing.expect(it.findCommand("ztcl::probe") != null);
    try std.testing.expect(it.probes == null);
}

test "a proc probe and a line probe record their captures" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    _ = try ev(&it, "package require ztcl::probe");
    _ = try ev(&it, parse_proc);
    try std.testing.expectEqualStrings("p1", try ev(&it, "ztcl::probe add -proc parse -capture n"));
    _ = try ev(&it, "ztcl::probe add -proc parse -line 4 -if {$i % 2 == 0} -capture {i [llength $toks]}");
    // Line 6 is in the body of `catch`, which the general path runs. A
    // probe runs before its command, so it sees the value of before.
    _ = try ev(&it, "ztcl::probe add -proc parse -line 6 -capture last");
    try std.testing.expectEqualStrings("5", try ev(&it, "parse 5"));
    try std.testing.expectEqualStrings("{n 5}", try ev(&it, "lmap r [ztcl::probe records -probe p1] {dict get $r values}"));
    try std.testing.expectEqualStrings("{i 0 {[llength $toks]} 0} {i 2 {[llength $toks]} 2} {i 4 {[llength $toks]} 4}", try ev(&it, "lmap r [ztcl::probe records -probe p2] {dict get $r values}"));
    try std.testing.expectEqualStrings("{<no value>} 0 1 2 3", try ev(&it, "lmap r [ztcl::probe records -probe p3] {dict get $r values last}"));
    try std.testing.expectEqualStrings("{i 4 {[llength $toks]} 4}", try ev(&it, "lmap r [ztcl::probe records -where {i > 2}] {dict get $r values}"));
    try std.testing.expectEqualStrings("parse 5", try ev(&it, "dict get [lindex [ztcl::probe records -probe p1] 0] words"));
}

test "a probe that goes recompiles the body with no probe" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    _ = try ev(&it, "package require ztcl::probe");
    _ = try ev(&it, parse_proc);
    _ = try ev(&it, "parse 2");
    const c = it.findCommand("parse").?;
    const plain = c.impl.proc.code.?;
    try std.testing.expect(plain.probed == null);
    _ = try ev(&it, "ztcl::probe add -proc parse -line 4");
    try std.testing.expect(c.impl.proc.code == null);
    _ = try ev(&it, "parse 2");
    try std.testing.expect(c.impl.proc.code.?.probed != null);
    _ = try ev(&it, "ztcl::probe remove all");
    _ = try ev(&it, "parse 2");
    try std.testing.expect(c.impl.proc.code.?.probed == null);
    try std.testing.expectEqualStrings("2", try ev(&it, "llength [ztcl::probe records]"));
}

/// The compute units of `script` after `setup`.
fn unitsOf(setup: []const u8, script: []const u8) !u64 {
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    _ = try ev(&it, "package require ztcl::probe");
    _ = try ev(&it, parse_proc);
    _ = try ev(&it, setup);
    const before = it.compute_limit;
    _ = try ev(&it, script);
    return before - it.compute_limit;
}

test "a probe does not change the compute units of a script" {
    if (!options.mod_probe) return error.SkipZigTest;
    const script = "set total 0; foreach k {3 5 8} {incr total [parse $k]}; catch {expr {1/0}}; string length abc; set total";
    const base = try unitsOf("", script);
    const setups = [_][]const u8{
        "ztcl::probe add -proc parse -capture {n [string repeat x 100]}",
        "ztcl::probe add -proc parse -line 4 -if {$i > 1} -capture {i toks}",
        "ztcl::probe add -proc parse -line 6 -stack",
        "ztcl::probe add -var total -ops {read write}",
        "ztcl::probe add -error -stack",
        "ztcl::probe add -proc parse -if {[error boom]}",
        "ztcl::probe add -proc parse -capture {[while 1 {}]}",
        "ztcl::probe add -proc parse; ztcl::probe remove all",
    };
    for (setups) |s| {
        std.testing.expectEqual(base, try unitsOf(s, script)) catch |e| {
            std.debug.print("setup: {s}\n", .{s});
            return e;
        };
    }
}

test "a probe keeps the result and the error state of the script" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    _ = try ev(&it, "package require ztcl::probe");
    _ = try ev(&it, parse_proc);
    _ = try ev(&it, "ztcl::probe add -proc parse -if {[error boom]}");
    _ = try ev(&it, "ztcl::probe add -proc parse -capture {[while 1 {}] n}");
    _ = try ev(&it, "ztcl::probe add -error");
    try std.testing.expectEqualStrings("1 {divide by zero} {ARITH DIVZERO {divide by zero}}", try ev(&it, "list [catch {parse 2; expr {1/0}} m] $m $::errorCode"));
    try std.testing.expectEqualStrings("records 1 errors 1", try ev(&it, "dict filter [lindex [ztcl::probe list] 0] key errors records"));
    try std.testing.expectEqualStrings("boom", try ev(&it, "dict get [lindex [ztcl::probe records -probe p1] 0] probe_error"));
    try std.testing.expectEqualStrings("2", try ev(&it, "dict get [lindex [ztcl::probe records -probe p2] 0] values n"));
    try std.testing.expectEqualStrings("{divide by zero} {expr {1/0}}", try ev(&it, "set r [lindex [ztcl::probe records -probe p3] end]; list [dict get $r message] [dict get $r cmd]"));
}

test "a variable probe, a command probe, and the limits" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    _ = try ev(&it, "package require ztcl::probe");
    _ = try ev(&it, "ztcl::probe add -var x -ops {read write}");
    _ = try ev(&it, "ztcl::probe add -command lsort -leave");
    _ = try ev(&it, "ztcl::probe add -command lreverse -count 2");
    _ = try ev(&it, "ztcl::probe add -command llength -every 3");
    _ = try ev(&it, "proc f {} { global x; incr x; set y $x }");
    _ = try ev(&it, "set x 1; f; f; lsort {b a}; foreach k {1 2 3 4 5} {lreverse $k; llength $k}");
    try std.testing.expectEqualStrings("{write 1} {read 1} {write 2} {read 2} {read 2} {write 3} {read 3}", try ev(&it, "lmap r [ztcl::probe records -probe p1] {list [dict get $r op] [dict get $r value]}"));
    try std.testing.expectEqualStrings("{a b} 0", try ev(&it, "set r [lindex [ztcl::probe records -probe p2] 0]; list [dict get $r result] [dict get $r code]"));
    try std.testing.expectEqualStrings("2 3", try ev(&it, "set p [lindex [ztcl::probe list] 2]; list [dict get $p records] [dict get $p dropped]"));
    try std.testing.expectEqualStrings("2", try ev(&it, "llength [ztcl::probe records -probe p4]"));
    // `trace info` does not show a probe, and `unset` removes it.
    try std.testing.expectEqualStrings("", try ev(&it, "trace info variable x"));
    _ = try ev(&it, "unset x; set x 9");
    try std.testing.expectEqualStrings("waiting", try ev(&it, "dict get [lindex [ztcl::probe list] 0] state"));
    try std.testing.expectEqual(@as(u32, 0), it.var_traces);
}

test "the rate limit counts compute units" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    _ = try ev(&it, "package require ztcl::probe");
    _ = try ev(&it, "proc f {} {}");
    _ = try ev(&it, "ztcl::probe add -proc f -rate {2 1000}");
    _ = try ev(&it, "for {set k 0} {$k < 100} {incr k} {f}");
    const p = try ev(&it, "set p [lindex [ztcl::probe list] 0]; list [dict get $p hits] [dict get $p records]");
    try std.testing.expectEqualStrings("100 2", p);
}

test "records as JSON lines, the ring size, and the queries" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    _ = try ev(&it, "package require ztcl::probe");
    _ = try ev(&it, "ztcl::probe configure -size 3 -maxlen 16");
    _ = try ev(&it, "proc f {s} {}");
    _ = try ev(&it, "ztcl::probe add -proc f -capture s");
    _ = try ev(&it, "foreach k {1 2 3 4} {f $k}; f \"a\\\"b\\n[string repeat x 40]\"");
    try std.testing.expectEqualStrings("2 3 4", try ev(&it, "lmap r [ztcl::probe records] {dict get $r seq}"));
    try std.testing.expectEqualStrings("4", try ev(&it, "dict get [lindex [ztcl::probe records -since 3 -first 1] 0] values s"));
    const json = try ev(&it, "ztcl::probe records -last 1 -json");
    try std.testing.expect(std.mem.indexOf(u8, json, "\"values\":{\"s\":\"a\\\"b\\nxxxxxxxxxxxx... (44 bytes)\"}") != null);
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"seq\":4,"));
    try std.testing.expect(std.mem.endsWith(u8, json, "}\n"));
}

test "a probe waits for its proc, and a new proc keeps the probe" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    _ = try ev(&it, "package require ztcl::probe");
    _ = try ev(&it, "namespace eval ns { ztcl::probe add -proc g -capture a }");
    try std.testing.expectEqualStrings("waiting", try ev(&it, "dict get [lindex [ztcl::probe list] 0] state"));
    _ = try ev(&it, "proc ns::g {a} {}; ns::g 1; proc ns::g {a} {return $a}; ns::g 2");
    try std.testing.expectEqualStrings("1 2", try ev(&it, "lmap r [ztcl::probe records] {dict get $r values a}"));
}

test "a probe on a proc keeps the other procs in machine code" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    if (!it.enableJit(.{ .threshold = 0 })) return error.SkipZigTest;
    _ = try ev(&it, "package require ztcl::probe");
    _ = try ev(&it, parse_proc);
    _ = try ev(&it, "proc other {n} { set s 0; for {set i 0} {$i < $n} {incr i} {incr s $i}; return $s }");
    _ = try ev(&it, "ztcl::probe add -proc parse -line 4 -capture i");
    try std.testing.expectEqualStrings("3 6", try ev(&it, "list [parse 3] [other 4]"));
    try std.testing.expectEqualStrings("3 6", try ev(&it, "list [parse 3] [other 4]"));
    const parse_code = it.findCommand("parse").?.impl.proc.code.?;
    const other_code = it.findCommand("other").?.impl.proc.code.?;
    try std.testing.expect(parse_code.jit_state != .ready);
    try std.testing.expect(other_code.jit_state == .ready);
    try std.testing.expectEqualStrings("6", try ev(&it, "llength [ztcl::probe records]"));
}

test "a probe keeps its proc and scripts alive across collections" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    it.setGcStress(1);
    _ = try ev(&it, "package require ztcl::probe");
    _ = try ev(&it, parse_proc);
    _ = try ev(&it, "ztcl::probe add -proc parse -line 6 -capture {last [string repeat a 50]}");
    _ = try ev(&it, "parse 3");
    _ = try ev(&it, "rename parse {}");
    it.collect();
    _ = try ev(&it, "set junk [string repeat x 1000]; unset junk");
    it.collect();
    try std.testing.expectEqualStrings("3", try ev(&it, "llength [ztcl::probe records]"));
    _ = try ev(&it, "ztcl::probe remove all");
    try std.testing.expectEqualStrings("", try ev(&it, "ztcl::probe list"));
}

test "a line probe runs once for each run of its line" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    _ = try ev(&it, "package require ztcl::probe");
    _ = try ev(&it, "proc f {n} {\n  set s 0\n  for {set i 0} {$i < $n} {incr i} { if {$i % 2} {incr s} else {catch {incr s 2}} }\n  return [expr {$s + [llength {a b}]}]\n}");
    _ = try ev(&it, "ztcl::probe add -proc f -line 3 -capture i; ztcl::probe add -proc f -line 4");
    try std.testing.expectEqualStrings("7", try ev(&it, "f 3"));
    try std.testing.expectEqualStrings("1 1", try ev(&it, "lmap p [ztcl::probe list] {dict get $p hits}"));
}

test "the records are outside the memory count of the script" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    it.gc_on = false;
    _ = try ev(&it, "package require ztcl::probe; proc f {s} {}");
    _ = try ev(&it, "ztcl::probe add -proc f -capture s");
    _ = try ev(&it, "for {set k 0} {$k < 50} {incr k} {f [string repeat y 200]}");
    const s = it.probes.?;
    try std.testing.expectEqual(@as(usize, 50), s.ring.items.len);
    // A free of the records does not change the count of the heap.
    const before = it.memUsed();
    probe.clear(s);
    try std.testing.expectEqual(before, it.memUsed());
}

test "the argument checks and the error codes of ztcl::probe (#723)" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try newInterp(&it);
    defer it.deinit();
    _ = try ev(&it, "package require ztcl::probe\nproc f {n} {\n    set x [string repeat a $n]\n    return $n\n}\n");
    const one = "{a probe has one target: -proc, -command, -var, or -error} {TCL VALUE}";
    const cases = [_][2][]const u8{
        .{ "ztcl::probe add -proc f -var x", one },
        .{ "ztcl::probe add -proc f -command set", one },
        .{ "ztcl::probe add -error -proc f", one },
        .{ "ztcl::probe add -proc f -line 0", "{-line must be 1 or more} {TCL VALUE}" },
        .{ "ztcl::probe add -proc f -line -1", "{-line must be 1 or more} {TCL VALUE}" },
        .{ "ztcl::probe add -proc f -every 0", "{-every must be 1 or more} {TCL VALUE}" },
        .{ "ztcl::probe add -bogus", "{bad option \"-bogus\": must be -capture, -command, -count, -error, -every, -if, -leave, -line, -locals, -ops, -proc, -rate, -stack, or -var} {TCL LOOKUP INDEX option}" },
        .{ "ztcl::probe add -proc f -bogus 1", "{bad option \"-bogus\": must be -capture, -command, -count, -error, -every, -if, -leave, -line, -locals, -ops, -proc, -rate, -stack, or -var} {TCL LOOKUP INDEX option}" },
        .{ "ztcl::probe add -proc", "{option \"-proc\" needs a value} {TCL VALUE}" },
        .{ "ztcl::probe records -bogus", "{bad option \"-bogus\": must be -first, -json, -last, -probe, -since, or -where} {TCL LOOKUP INDEX option}" },
        .{ "ztcl::probe remove p99", "{no probe \"p99\"} {ZTCL PROBE ID}" },
        .{ "ztcl::probe remove nope", "{bad probe id \"nope\"} {ZTCL PROBE ID}" },
        .{ "ztcl::probe add -var v -ops bogus", "{bad operation \"bogus\": must be read, unset, or write} {TCL LOOKUP INDEX operation}" },
        .{ "ztcl::probe configure -size 2000000", "{-size must be at most 1000000} {TCL VALUE}" },
        .{ "ztcl::probe bogus", "{unknown subcommand \"bogus\": must be add, clear, configure, list, records, or remove} {TCL LOOKUP SUBCOMMAND bogus}" },
    };
    for (cases) |c| {
        const script = try std.fmt.allocPrint(it.alloc(), "catch {{{s}}} m o; list $m [dict get $o -errorcode]", .{c[0]});
        try std.testing.expectEqualStrings(c[1], try ev(&it, script));
    }
    try std.testing.expectEqualStrings("", try ev(&it, "ztcl::probe list"));
}

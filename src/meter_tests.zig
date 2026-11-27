//! Tests of the meters of ztcl#243 (`meter.zig`, `metercmd.zig`).
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl.zig");
const thread = tcl.thread;
const testing = std.testing;
const Cap = tcl.interp.Capability;

fn host(it: *tcl.Interp, jit: bool) !void {
    try it.init(testing.allocator);
    errdefer it.deinit();
    if (!jit) it.disableJit();
    try it.allow(@backingInt(Cap.thread) | @backingInt(Cap.meter) | @backingInt(Cap.interp) | @backingInt(Cap.channels));
}

fn evalStr(it: *tcl.Interp, s: []const u8) ![]const u8 {
    const v = it.eval(s) catch |e| {
        std.debug.print("error: {s}\n", .{it.str(it.result) catch "?"});
        return e;
    };
    return it.str(v);
}

fn evalInt(it: *tcl.Interp, s: []const u8) !i64 {
    return std.fmt.parseInt(i64, try evalStr(it, s), 10);
}

const work =
    \\proc fib n { if {$n < 2} { return $n }; expr {[fib [expr {$n - 1}]] + [fib [expr {$n - 2}]]} }
    \\set s 0
    \\for {set i 0} {$i < 2000} {incr i} { incr s [expr {$i % 7}] }
    \\fib 15
;

test "the default interpreter has no ztcl::meter" {
    var it: tcl.Interp = undefined;
    try it.init(testing.allocator);
    defer it.deinit();
    try testing.expect(it.findCommand("ztcl::meter") == null);
}

test "ztcl::meter run counts the same units on each run" {
    var it: tcl.Interp = undefined;
    try host(&it, true);
    defer it.deinit();
    _ = try evalStr(&it, "ztcl::meter create m -tenant acme");
    const s = try std.fmt.allocPrint(testing.allocator, "ztcl::meter run m {{{s}}}", .{work});
    defer testing.allocator.free(s);
    _ = try evalStr(&it, s);
    const one = try evalInt(&it, "dict get [ztcl::meter get m] units");
    try testing.expect(one > 1000);
    _ = try evalStr(&it, s);
    try testing.expectEqual(2 * one, try evalInt(&it, "dict get [ztcl::meter get m] units"));
    _ = try evalStr(&it, "ztcl::meter reset m");
    try testing.expectEqual(@as(i64, 0), try evalInt(&it, "dict get [ztcl::meter get m] units"));
    try testing.expectEqualStrings("m", try evalStr(&it, "ztcl::meter list"));
}

fn threadUnits(jit: bool) !i64 {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it, jit);
    defer it.deinit();
    const s = try std.fmt.allocPrint(testing.allocator, "set t [thread::create -joinable -meter job {{{s}}}]; thread::join $t; dict get [ztcl::meter get job] units", .{work});
    defer testing.allocator.free(s);
    const n = try evalInt(&it, s);
    try testing.expectEqual(@as(i64, 1), try evalInt(&it, "dict get [ztcl::meter get job] threads interp"));
    try testing.expect(try evalInt(&it, "dict get [ztcl::meter get job] mem_peak") > 0);
    return n;
}

test "a thread counts the same units with the JIT on and off" {
    const on = try threadUnits(true);
    const off = try threadUnits(false);
    try testing.expect(on > 1000);
    try testing.expectEqual(on, off);
}

test "a budget ends a thread with the compute limit" {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it, true);
    defer it.deinit();
    _ = try evalStr(&it, "ztcl::meter create b -budget 5000");
    _ = try evalStr(&it, "set t [thread::create -joinable -meter b {while 1 {incr x}}]; thread::join $t");
    try testing.expectEqual(@as(i64, 5000), try evalInt(&it, "dict get [ztcl::meter get b] units"));
    try testing.expectEqual(@as(i64, 0), try evalInt(&it, "dict get [ztcl::meter get b] left"));
    // A new thread on the spent budget gets no units.
    _ = try evalStr(&it, "set t [thread::create -joinable -meter b {set y 1}]; thread::join $t");
    try testing.expectEqual(@as(i64, 5000), try evalInt(&it, "dict get [ztcl::meter get b] units"));
    // ztcl::meter run gives the compute-limit error, and the caller goes on.
    try testing.expectEqualStrings("compute limit reached", try evalStr(&it, "catch {ztcl::meter run b {set z 1}} msg; set msg"));
}

test "thread::create -compute caps the units of a thread" {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it, true);
    defer it.deinit();
    _ = try evalStr(&it, "set t [thread::create -joinable -meter c -compute 700 {while 1 {incr x}}]; thread::join $t");
    try testing.expectEqual(@as(i64, 700), try evalInt(&it, "dict get [ztcl::meter get c] units"));
}

test "a child interpreter counts in its meter" {
    var it: tcl.Interp = undefined;
    try host(&it, true);
    defer it.deinit();
    _ = try evalStr(&it, "interp create -meter kid k; k eval {set a 1; set b 2; set c 3}");
    const n = try evalInt(&it, "dict get [ztcl::meter get kid] units");
    try testing.expect(n >= 3 and n < 20);
    _ = try evalStr(&it, "k eval {set d 4}");
    try testing.expect(try evalInt(&it, "dict get [ztcl::meter get kid] units") > n);
}

test "the meter counts the bytes of a pipe" {
    var it: tcl.Interp = undefined;
    try host(&it, true);
    defer it.deinit();
    _ = try evalStr(&it, "ztcl::meter create io");
    _ = try evalStr(&it,
        \\ztcl::meter run io {
        \\    lassign [chan pipe] r w
        \\    puts -nonewline $w hello; flush $w
        \\    read $r 5
        \\    close $w; close $r
        \\}
    );
    try testing.expectEqual(@as(i64, 5), try evalInt(&it, "dict get [ztcl::meter get io] io pipe write"));
    try testing.expectEqual(@as(i64, 5), try evalInt(&it, "dict get [ztcl::meter get io] io pipe read"));
}

test "a signed record verifies, and a changed one does not" {
    var it: tcl.Interp = undefined;
    try host(&it, true);
    defer it.deinit();
    _ = try evalStr(&it,
        \\ztcl::meter create r -tenant acme
        \\ztcl::meter run r {set x 1}
        \\set seed [string repeat 07 32]
        \\set rec [ztcl::meter record r -script {set x 1} -key $seed]
        \\set pk [ztcl::meter pubkey $seed]
    );
    try testing.expectEqualStrings("1", try evalStr(&it, "ztcl::meter verify $rec $pk"));
    try testing.expectEqualStrings("0", try evalStr(&it, "ztcl::meter verify [string map {acme acmf} $rec] $pk"));
    try testing.expect(std.mem.indexOf(u8, try evalStr(&it, "set rec"), "\"tenant\":\"acme\"") != null);
    // A host key signs with -sign, and the script never sees the key.
    try testing.expectError(error.TclError, it.eval("ztcl::meter record r -sign"));
}

test "the default interpreter has no ztcl::gc" {
    var it: tcl.Interp = undefined;
    try it.init(testing.allocator);
    defer it.deinit();
    try testing.expect(it.findCommand("ztcl::gc") == null);
}

test "ztcl::gc stats counts a collection, and reset starts the counts again" {
    if (!tcl.gc.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it, false);
    defer it.deinit();
    // 60 MB of garbage: collections at the safe points of the bytecode,
    // also in a precise build, where `ztcl::gc collect` in a native
    // command runs none.
    _ = try evalStr(&it, "for {set i 0} {$i < 300000} {incr i} {set s [string repeat x 200]}; ztcl::gc collect");
    try testing.expect(try evalInt(&it, "dict get [ztcl::gc stats] collections") >= 1);
    try testing.expect(try evalInt(&it, "dict get [ztcl::gc stats] allocated") > 40_000_000);
    try testing.expect(try evalInt(&it, "dict get [ztcl::gc stats] freed") > 20_000_000);
    try testing.expect(try evalInt(&it, "dict get [ztcl::gc stats] gc_ns") > 0);
    try testing.expectEqualStrings("1", try evalStr(&it, "set s [ztcl::gc stats]; expr {[dict get $s pause_max_ns] >= [dict get $s pause_p99_ns] && [dict get $s pause_p99_ns] >= [dict get $s pause_p50_ns] && [dict get $s heap_peak] >= [dict get $s heap_bytes] && [dict get $s mark_ns] + [dict get $s sweep_ns] <= [dict get $s gc_ns]}"));
    try testing.expectEqualStrings("21", try evalStr(&it, "dict size [ztcl::gc stats]"));
    _ = try evalStr(&it, "ztcl::gc reset");
    try testing.expectEqual(@as(i64, 0), try evalInt(&it, "dict get [ztcl::gc stats] collections"));
    try testing.expectEqual(@as(i64, 0), try evalInt(&it, "dict get [ztcl::gc stats] freed"));
    try testing.expectEqualStrings("wrong # args: should be \"ztcl::gc stats|collect|reset\"", try evalStr(&it, "catch {ztcl::gc} m; set m"));
    try testing.expectEqualStrings("bad option \"x\": must be collect, reset, or stats", try evalStr(&it, "catch {ztcl::gc x} m; set m"));
}

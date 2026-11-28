//! The tests of `ztcl::wasm`: calls, traps, limits, host functions,
//! memory, and the capabilities of WASI. The modules are hex text of
//! modules that `wasm-tools parse` made from the text format; the text
//! is in the comment above each one.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("../ztcl.zig");

// (module
//   (import "env" "cb" (func $cb (param i32) (result i32)))
//   (memory (export "memory") 1 100)
//   (global $g (export "g") (mut i64) (i64.const 5))
//   (data (i32.const 16) "hi there\00")
//   (func (export "div") (param i32 i32) (result i32) local.get 0 local.get 1 i32.div_s)
//   (func (export "spin") (loop br 0))
//   (func $rec (export "rec") (param i32) (result i32) local.get 0 call $rec)
//   (func (export "grow") (param i32) (result i32) local.get 0 memory.grow)
//   (func (export "twice") (param i32) (result i32) local.get 0 call $cb i32.const 2 i32.mul)
//   (func (export "pair") (param f64) (result f64 i64) local.get 0 f64.sqrt global.get $g)
//   (func (export "sum") (param i32 i32) (result i32) ...))
const test_mod = "0061736d0100000001150460017f017f60027f7f017f60000060017c027c7e020a0103656e760263620000030807010200000003010504010101640606017e0142050b073d09066d656d6f7279020001670300036469760001047370696e00020372656300030467726f7700040574776963650005047061697200060373756d00070a5d070700200020016d0b070003400c000b0b0600200010030b0600200040000b09002000100041026c0b070020009f23000b2b01017f024003402001450d01200220002d00006a2102200041016a2100200141016b21010c000b0b20020b0b0f010041100b09686920746865726500001f046e616d65010a020002636203037265630206010701020173070401000167";

// (module
//   (import "wasi_snapshot_preview1" "clock_time_get" (func (param i32 i64 i32) (result i32)))
//   (import "wasi_snapshot_preview1" "proc_exit" (func (param i32)))
//   (memory (export "memory") 1)
//   (func (export "now") (result i32) ...)  ;; clock_time_get into address 0
//   (func (export "_start") i32.const 3 call $exit))
const wasi_mod = "0061736d0100000001130460037f7e7f017f60017f006000017f600000024c0216776173695f736e617073686f745f70726576696577310e636c6f636b5f74696d655f676574000016776173695f736e617073686f745f70726576696577310970726f635f65786974000103030202030503010001071903066d656d6f72790200036e6f770002065f737461727400030a13020a0041004200410010000b0600410310010b0012046e616d65010b0200026374010465786974";

const setup = "package require ztcl::wasm\n" ++
    "proc cb {x} { return [expr {$x + 1}] }\n" ++
    "set m [ztcl::wasm new [binary decode hex " ++ test_mod ++ "]]\n" ++
    "set w [ztcl::wasm instantiate $m -imports {env {cb cb}}]\n";

fn run(script: []const u8, caps: u32, mem_limit: usize) ![]const u8 {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.compute_limit = 10_000_000;
    it.capabilities |= caps;
    it.mem_limit = mem_limit;
    const text = try std.mem.concat(std.testing.allocator, u8, &.{ setup, script });
    defer std.testing.allocator.free(text);
    const out = if (it.eval(text)) |v| try it.str(v) else |e| blk: {
        if (e != error.TclError) return e;
        break :blk try std.fmt.allocPrint(it.alloc(), "!{s}", .{try it.str(it.result)});
    };
    return std.testing.allocator.dupe(u8, out);
}

fn expect(script: []const u8, want: []const u8) !void {
    return expectCaps(script, want, 0);
}

fn expectCaps(script: []const u8, want: []const u8, caps: u32) !void {
    const got = try run(script, caps, 64 << 20);
    defer std.testing.allocator.free(got);
    std.testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("script: {s}\n", .{script});
        return e;
    };
}

test "ztcl::wasm: calls and results" {
    try expect("ztcl::wasm call $w div 7 2", "3");
    try expect("ztcl::wasm call $w div -7 2", "-3");
    try expect("ztcl::wasm call $w twice 20", "42");
    try expect("ztcl::wasm call $w pair 16", "4.0 5");
    try expect("ztcl::wasm call $w div -raw 4294967295 1", "4294967295");
    try expect("ztcl::wasm global $w g 9; ztcl::wasm call $w pair 1", "1.0 9");
    try expect("lindex [ztcl::wasm exports $m] 0", "memory");
    try expect("ztcl::wasm imports $m", "env cb func {i32 i32}");
    try expect("ztcl::wasm call $w div 1", "!the function \"div\" has 2 parameters and got 1 arguments");
}

test "ztcl::wasm: traps and limits" {
    try expect("catch {ztcl::wasm call $w div 1 0} msg o; list $msg [dict get $o -errorcode]", "{wasm trap: integer divide by zero} {ZTCL WASM TRAP {integer divide by zero}}");
    try expect("ztcl::wasm call $w div -2147483648 -1", "!wasm trap: integer overflow");
    try expect("ztcl::wasm call $w rec 1", "!wasm trap: call stack exhausted");
    try expect("catch {ztcl::wasm call $w spin -limit 1000} msg; set msg", "wasm trap: compute limit reached");
    // The global compute limit stops the loop as it stops a Tcl loop.
    try expect("ztcl::wasm call $w spin", "!compute limit reached");
}

test "ztcl::wasm: memory" {
    try expect("ztcl::wasm memory $w string 16", "hi there");
    try expect("ztcl::wasm memory $w write 100 [binary format c3 {1 2 3}]; ztcl::wasm call $w sum 100 3", "6");
    try expect("ztcl::wasm memory $w write 100 [binary format c3 {1 2 3}]; binary scan [ztcl::wasm memory $w read 100 3] c3 v; set v", "1 2 3");
    try expect("ztcl::wasm call $w grow 2", "1");
    try expect("ztcl::wasm call $w grow 1000", "-1");
    try expect("ztcl::wasm memory $w read 65530 10", "!the range 65530 to 65540 is outside the memory of 65536 bytes");
    // The memory limit of the interpreter caps memory.grow.
    const got = try run("ztcl::wasm call $w grow 90", 0, 2 << 20);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("-1", got);
}

// (module (func (export "f")))
const bare_mod = "0061736d0100000001040160000003020100070501016600000a040102000b";

test "ztcl::wasm: the order and the text of argument errors (#714)" {
    try expect("ztcl::wasm memory $w read -1 4", "!the range -1 to 3 is outside the memory of 65536 bytes");
    try expect("ztcl::wasm package x.wasm Add -wasi", "!wrong # args: should be \"ztcl::wasm package fileName ?prefix? ?-wasi dict?\"");
    try expect("catch {ztcl::wasm call $w div -bogus 1 2} msg o; list $msg [dict get $o -errorcode]", "{bad option \"-bogus\": must be -limit, -raw, or --} {TCL LOOKUP INDEX option}");
    try expect("ztcl::wasm call $w div -7 2", "-3");
    try expect("catch {ztcl::wasm call $w div -inf 1} msg; string match {bad option*} $msg", "0");
    const bare = "set b [ztcl::wasm instantiate [ztcl::wasm new [binary decode hex " ++ bare_mod ++ "]]]\n";
    try expect(bare ++ "ztcl::wasm memory $b bogus", "!unknown subcommand \"bogus\": must be grow, read, size, string, or write");
    try expect(bare ++ "ztcl::wasm memory $b s 16", "!unknown subcommand \"s\": must be grow, read, size, string, or write");
    try expect(bare ++ "ztcl::wasm memory $b size", "!the instance has no memory");
}

test "ztcl::wasm: capabilities" {
    try expect("ztcl::wasm load x.wasm", "!ztcl::wasm load needs the capability file");
    try expect("ztcl::wasm instantiate $m -wasi {dirs {. .}}", "!the WASI option dirs needs the capability file");
    const wasi_setup = "set c [ztcl::wasm new [binary decode hex " ++ wasi_mod ++ "]]\n";
    // ENOTCAPABLE (76) with no clock capability.
    try expect(wasi_setup ++ "ztcl::wasm call [ztcl::wasm instantiate $c -wasi {}] now", "76");
    try expect(wasi_setup ++ "ztcl::wasm run $c", "3");
    try expect(wasi_setup ++ "ztcl::wasm instantiate $c", "!missing import \"wasi_snapshot_preview1\" \"clock_time_get\"");
}

test {
    _ = @import("cext.zig");
}

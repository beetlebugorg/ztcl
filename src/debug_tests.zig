//! Tests of `ztcl debug` (`debug.zig`) and its MCP server
//! (`debugmcp.zig`), with no terminal and no process.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl.zig");
const debug = @import("debug.zig");
const debugmcp = @import("debugmcp.zig");
const options = @import("build_options");

const average =
    \\proc average {items} {
    \\    set total 0
    \\    set n 0
    \\    foreach x $items {
    \\        incr total $x
    \\        if {$x < 0} { set n 0 } else { incr n }
    \\    }
    \\    return [expr {$total / $n}]
    \\}
    \\proc report {} {
    \\    puts "avg [average {4 6 8}]"
    \\    puts "avg [average {3 -3}]"
    \\}
    \\report
    \\
;

fn has(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing: {s}\nin:\n{s}\n", .{ part, text });
        return error.TestExpectedEqual;
    }
}

test "explain gives the stack with the locals and the changes of the last call" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    var rep = try debug.run(&it, average, .{ .explain = true });
    defer rep.deinit();
    try std.testing.expect(!rep.ok);
    const text = try debug.writeText(it.alloc(), &rep, .{});
    try has(text, "error: divide by zero\n");
    try has(text, "at: expr {$total / $n}\n");
    try has(text, "  average {3 -3}\n    items = 3 -3\n    total = 0\n    n = 0\n    x = -3\n  report\n");
    try has(text, "  n: 1 -> 0 (line 6 to 8)\n");
    try has(text, "  x: 3 -> -3 (line 6 to 5)\n");
    // Only the last call: the changes of the first call are not there.
    try std.testing.expect(std.mem.indexOf(u8, text, "18") == null);
    const js = try debug.writeJson(it.alloc(), &rep, .{});
    try has(js, "\"status\":\"error\"");
    try has(js, "{\"var\":\"n\",\"from\":\"1\",\"to\":\"0\",\"line\":6,\"next\":8}");
}

test "a run with probes, the budget, and a bad probe" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    var rep = try debug.run(&it, "proc f {a} {expr {$a * 2}}; foreach i {1 2 3 4 5} {f $i}", .{ .probes = &.{"-proc f -capture a"} });
    defer rep.deinit();
    try std.testing.expect(rep.ok);
    const text = try debug.writeText(it.alloc(), &rep, .{ .last = 2 });
    try has(text, "status: ok\nprobes:\n");
    try has(text, "p2 proc f: 5 hits, 5 records, 0 dropped, 0 errors\n");
    try has(text, "records (the last 2 of 5; --detail records), oldest first:\n  #3 p2 proc=f words=f 4 a=4\n");
    const small = try debug.writeText(it.alloc(), &rep, .{ .budget = 40 });
    try has(small, "status: ok\n");
    try has(small, "bytes left out: use --budget ");
    try it.reset();
    try std.testing.expectError(error.TclError, debug.run(&it, "set x 1", .{ .probes = &.{"-bogus"} }));
}

fn noRead(_: ?*anyopaque, _: []const u8, _: std.mem.Allocator) anyerror![]u8 {
    return error.FileNotFound;
}

test "the MCP server answers initialize, tools/list, and tools/call" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ztcl_run","arguments":{"script":"proc f {a} {puts hi$a}; f 1; f 2","probes":["-proc f -capture a"]}}}
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ztcl_records","arguments":{"where":"a > 1"}}}
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ztcl_eval","arguments":{"code":"info procs f"}}}
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ztcl_run","arguments":{"path":"none.tcl"}}}
        \\{"jsonrpc":"2.0","id":7,"method":"bogus"}
        \\not json
        \\
    ;
    var in: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var server: debugmcp.Server = .{ .it = &it, .gpa = std.testing.allocator, .read = noRead };
    defer server.captured.deinit(std.testing.allocator);
    try debugmcp.serve(&server, &in, &out.writer);
    const text = out.written();
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |_| n += 1;
    // One answer for each request with an id, and one for the bad line.
    try std.testing.expectEqual(@as(usize, 8), n);
    try has(text, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}}");
    try has(text, "\"name\":\"ztcl_explain\"");
    try has(text, "status: ok\\nprobes:\\n  p2 proc f: 2 hits");
    try has(text, "output:\\nhi1\\nhi2\\n");
    try has(text, "\\\"values\\\":{\\\"a\\\":\\\"2\\\"}");
    try has(text, "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"f\"}],\"isError\":false}}");
    try has(text, "none.tcl: FileNotFound\"}],\"isError\":true");
    try has(text, "\"id\":7,\"error\":{\"code\":-32601");
    try has(text, "\"id\":null,\"error\":{\"code\":-32700");
}

var fake_now: i64 = 1000;
fn fakeClock(_: ?*anyopaque) i64 {
    fake_now += 7;
    return fake_now;
}

fn outText(ctx: ?*anyopaque, bytes: []const u8) void {
    const l: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx.?));
    l.appendSlice(std.testing.allocator, bytes) catch {};
}

/// Runs `script` with the fake clock and the tape `t`, and gives the
/// output of `puts`.
fn runTaped(t: *tcl.tape.Tape, script: []const u8, probes: []const []const u8, buf: *std.ArrayList(u8)) !debug.Report {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.clock_host = .{ .now = fakeClock };
    try it.allow(@backingInt(tcl.interp.Capability.clock));
    it.output = .{ .ctx = buf, .write = outText };
    return debug.run(&it, script, .{ .tape = t, .probes = probes });
}

test "a replay gives the recorded clock, also with new probes" {
    if (!options.mod_probe) return error.SkipZigTest;
    const script = "proc f {} {clock microseconds}; set a [f]; set b [f]; puts [expr {$b - $a}],[expr {$a % 1000}]";
    var rec: tcl.tape.Tape = .{ .gpa = std.testing.allocator, .mode = .record };
    defer rec.deinit();
    var out1: std.ArrayList(u8) = .empty;
    defer out1.deinit(std.testing.allocator);
    var r1 = try runTaped(&rec, script, &.{}, &out1);
    defer r1.deinit();
    try std.testing.expectEqual(@as(usize, 2), rec.entries.items.len);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(std.testing.allocator);
    try tcl.tape.write(&rec, std.testing.allocator, &file);
    // The clock moves on, and the replay still gives the old times.
    fake_now += 500;
    var rep_tape: tcl.tape.Tape = .{ .gpa = std.testing.allocator, .mode = .replay };
    defer rep_tape.deinit();
    try tcl.tape.parse(&rep_tape, file.items);
    var out2: std.ArrayList(u8) = .empty;
    defer out2.deinit(std.testing.allocator);
    var r2 = try runTaped(&rep_tape, script, &.{"-proc f -stack"}, &out2);
    defer r2.deinit();
    try std.testing.expectEqualStrings(out1.items, out2.items);
    try std.testing.expectEqualStrings("replayed 2 of 2 inputs", r2.tape_note);
    try std.testing.expectEqual(@as(usize, 2), r2.records.len);
    // A script that asks for the inputs in another order leaves the tape.
    var bad: tcl.tape.Tape = .{ .gpa = std.testing.allocator, .mode = .replay };
    defer bad.deinit();
    try tcl.tape.parse(&bad, file.items);
    var out3: std.ArrayList(u8) = .empty;
    defer out3.deinit(std.testing.allocator);
    var r3 = try runTaped(&bad, "set x 1; clock microseconds", &.{}, &out3);
    defer r3.deinit();
    try std.testing.expect(!r3.ok);
    try std.testing.expectEqualStrings("ZTCL TAPE DIVERGED", r3.errorcode);
    try has(r3.tape_note, "the replay left the tape: entry 1 of the tape is clock at unit ");
}

test "who set a variable, when it got a value, and the first error" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const script = "proc step {k} { global x; set x [expr {$x * 2 + $k}] }; set x 1; foreach k {1 2 3 4} { step $k }; catch {error early}; error late";
    var rep = try debug.run(&it, script, .{ .questions = &.{ .{ .kind = .who_set, .name = "x" }, .{ .kind = .when, .name = "x", .value = "8" } } });
    defer rep.deinit();
    try std.testing.expectEqual(@as(usize, 2), rep.answers.len);
    try has(rep.answers[0], "x: was last set to 42 at unit ");
    try has(rep.answers[0], "stack: {step 4}");
    try has(rep.answers[1], "x: got the value 8 at unit ");
    try has(rep.answers[1], "stack: {step 2}");
    try has(rep.first_error, "early (at error early, unit ");
}

/// Runs `script` with files in `.zig-cache/ztcl-tape-test`, `exec` of
/// `echo`, and the tape `t`.
fn runFiles(t: *tcl.tape.Tape, pre: []const u8, script: []const u8, buf: *std.ArrayList(u8)) !debug.Report {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(tcl.interp.Capability.file) | @backingInt(tcl.interp.Capability.channels) | @backingInt(tcl.interp.Capability.exec));
    it.exec_host = .{ .allow = &.{"echo"}, .timeout_ms = 5000, .env = &.{"PATH=/usr/bin:/bin"} };
    try tcl.fsroot.setRoot(&it, ".");
    _ = it.eval(pre) catch |e| {
        std.debug.print("setup: {s}\n", .{try it.str(it.result)});
        return e;
    };
    try tcl.fsroot.setRoot(&it, ".zig-cache/ztcl-tape-test");
    it.output = .{ .ctx = buf, .write = outText };
    return debug.run(&it, script, .{ .tape = t });
}

test "a replay gives the recorded file data and exec results" {
    if (!options.mod_probe) return error.SkipZigTest;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const make = "set d .zig-cache/ztcl-tape-test; file delete -force $d; file mkdir $d; set f [open $d/a.txt w]; puts -nonewline $f abc; close $f";
    const script = "puts [file exists a.txt],[file size a.txt],[glob -nocomplain *.txt],[exec echo hi],[catch {exec echo-none}]";
    var rec: tcl.tape.Tape = .{ .gpa = std.testing.allocator, .mode = .record };
    defer rec.deinit();
    var out1: std.ArrayList(u8) = .empty;
    defer out1.deinit(std.testing.allocator);
    var r1 = try runFiles(&rec, make, script, &out1);
    defer r1.deinit();
    try std.testing.expectEqualStrings("1,3,a.txt,hi,1\n", out1.items);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(std.testing.allocator);
    try tcl.tape.write(&rec, std.testing.allocator, &file);
    // The file goes away, and the replay still gives the old data.
    var rep: tcl.tape.Tape = .{ .gpa = std.testing.allocator, .mode = .replay };
    defer rep.deinit();
    try tcl.tape.parse(&rep, file.items);
    var out2: std.ArrayList(u8) = .empty;
    defer out2.deinit(std.testing.allocator);
    var r2 = try runFiles(&rep, "file delete -force .zig-cache/ztcl-tape-test/a.txt", script, &out2);
    defer r2.deinit();
    try std.testing.expectEqualStrings(out1.items, out2.items);
    try std.testing.expect(r2.ok);
}

fn fillHi(_: ?*anyopaque, a: std.mem.Allocator) std.mem.Allocator.Error!?[]const u8 {
    return try a.dupe(u8, "hi");
}

fn fillNone(_: ?*anyopaque, _: std.mem.Allocator) std.mem.Allocator.Error!?[]const u8 {
    return null;
}

test "a replay gives the recorded entropy and environment" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    var rec: tcl.tape.Tape = .{ .gpa = std.testing.allocator, .mode = .record };
    defer rec.deinit();
    tcl.tape.start(&it, &rec);
    try std.testing.expectEqualStrings("hi", (try tcl.tape.bytes(&it, .random, null, fillHi)).?);
    try std.testing.expect(try tcl.tape.bytes(&it, .env, null, fillNone) == null);
    tcl.tape.stop(&it);
    var rep: tcl.tape.Tape = .{ .gpa = std.testing.allocator, .mode = .replay };
    defer rep.deinit();
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(std.testing.allocator);
    try tcl.tape.write(&rec, std.testing.allocator, &file);
    try tcl.tape.parse(&rep, file.items);
    tcl.tape.start(&it, &rep);
    defer tcl.tape.stop(&it);
    try std.testing.expectEqualStrings("hi", (try tcl.tape.bytes(&it, .random, null, fillNone)).?);
    try std.testing.expect(try tcl.tape.bytes(&it, .env, null, fillHi) == null);
}

const dap_script =
    \\proc f {x} {
    \\    set y [expr {$x * 2}]
    \\    return $y
    \\}
    \\set r [f 3]
    \\puts $r
;

fn dapRead(_: ?*anyopaque, _: []const u8, a: std.mem.Allocator) anyerror![]u8 {
    return a.dupe(u8, dap_script);
}

fn frame(a: std.mem.Allocator, out: *std.ArrayList(u8), body: []const u8) !void {
    try out.print(a, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

test "the DAP server stops at a breakpoint, steps, and gives the stack" {
    if (!options.mod_probe) return error.SkipZigTest;
    const a = std.testing.allocator;
    var it: tcl.Interp = undefined;
    try it.init(a);
    defer it.deinit();
    var in: std.ArrayList(u8) = .empty;
    defer in.deinit(a);
    const reqs = [_][]const u8{
        \\{"seq":1,"type":"request","command":"initialize","arguments":{"adapterID":"ztcl"}}
        ,
        \\{"seq":2,"type":"request","command":"launch","arguments":{"program":"/w/t.tcl"}}
        ,
        \\{"seq":3,"type":"request","command":"setBreakpoints","arguments":{"source":{"path":"/w/t.tcl"},"breakpoints":[{"line":3},{"line":2,"condition":"$x > 5"}]}}
        ,
        \\{"seq":4,"type":"request","command":"configurationDone"}
        ,
        \\{"seq":5,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
        ,
        \\{"seq":6,"type":"request","command":"variables","arguments":{"variablesReference":1}}
        ,
        \\{"seq":7,"type":"request","command":"evaluate","arguments":{"expression":"expr {$y + 1}","frameId":0}}
        ,
        \\{"seq":8,"type":"request","command":"next","arguments":{"threadId":1}}
        ,
        \\{"seq":9,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
        ,
        \\{"seq":10,"type":"request","command":"continue","arguments":{"threadId":1}}
        ,
        \\{"seq":11,"type":"request","command":"disconnect"}
        ,
    };
    for (reqs) |r| try frame(a, &in, r);
    var reader: std.Io.Reader = .fixed(in.items);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var server: tcl.dap.Server = .{ .it = &it, .gpa = a, .in = &reader, .out = &out.writer, .read = dapRead };
    try tcl.dap.serve(&server);
    const text = out.written();
    // The condition of line 2 is false, so the first stop is line 3.
    try has(text, "\"event\":\"stopped\",\"body\":{\"reason\":\"breakpoint\"");
    try has(text, "{\"id\":0,\"name\":\"f 3\",\"line\":3,\"column\":1,\"source\":{\"name\":\"t.tcl\",\"path\":\"/w/t.tcl\"}}");
    try has(text, "{\"name\":\"x\",\"value\":\"3\",\"variablesReference\":0},{\"name\":\"y\",\"value\":\"6\"");
    try has(text, "\"command\":\"evaluate\",\"body\":{\"result\":\"7\"");
    // The step leaves `f` and stops at the next line of the top level.
    try has(text, "\"reason\":\"step\"");
    try has(text, "{\"id\":0,\"name\":\"<top>\",\"line\":6");
    try has(text, "\"category\":\"stdout\",\"output\":\"6\\n\"");
    try has(text, "\"event\":\"exited\",\"body\":{\"exitCode\":0}");
}

const dap_loop_script =
    \\set n 0
    \\while {$n < 3} {
    \\    incr n
    \\}
    \\catch {error boom}
    \\puts $n
;

fn dapReadLoop(_: ?*anyopaque, _: []const u8, a: std.mem.Allocator) anyerror![]u8 {
    return a.dupe(u8, dap_loop_script);
}

/// A poll that says a request waits after the first lines of the run.
fn pollLater(ctx: ?*anyopaque) bool {
    const n: *u32 = @ptrCast(@alignCast(ctx.?));
    n.* += 1;
    return n.* == 2;
}

test "the DAP server stops in a loop body of the top level, at an error, and at a pause" {
    if (!options.mod_probe) return error.SkipZigTest;
    const a = std.testing.allocator;
    var it: tcl.Interp = undefined;
    try it.init(a);
    defer it.deinit();
    var in: std.ArrayList(u8) = .empty;
    defer in.deinit(a);
    const reqs = [_][]const u8{
        \\{"seq":1,"type":"request","command":"initialize","arguments":{"adapterID":"ztcl"}}
        ,
        \\{"seq":2,"type":"request","command":"launch","arguments":{"program":"/w/l.tcl"}}
        ,
        \\{"seq":3,"type":"request","command":"setBreakpoints","arguments":{"source":{"path":"/w/l.tcl"},"breakpoints":[{"line":3,"condition":"$n == 1"}]}}
        ,
        \\{"seq":4,"type":"request","command":"setExceptionBreakpoints","arguments":{"filters":["error"]}}
        ,
        \\{"seq":5,"type":"request","command":"configurationDone"}
        ,
        \\{"seq":6,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
        ,
        \\{"seq":7,"type":"request","command":"continue","arguments":{"threadId":1}}
        ,
        \\{"seq":8,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
        ,
        \\{"seq":9,"type":"request","command":"continue","arguments":{"threadId":1}}
        ,
    };
    for (reqs) |r| try frame(a, &in, r);
    var reader: std.Io.Reader = .fixed(in.items);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var server: tcl.dap.Server = .{ .it = &it, .gpa = a, .in = &reader, .out = &out.writer, .read = dapReadLoop };
    try tcl.dap.serve(&server);
    const text = out.written();
    try has(text, "\"exceptionBreakpointFilters\":[{\"filter\":\"error\"");
    // Line 3 is in the body of the while. The condition holds at the second pass.
    try has(text, "\"reason\":\"breakpoint\"");
    try has(text, "{\"id\":0,\"name\":\"<top>\",\"line\":3");
    // The caught error stops, and the run goes on after it.
    try has(text, "\"reason\":\"exception\",\"threadId\":1,\"allThreadsStopped\":true,\"description\":\"boom\"");
    try has(text, "{\"id\":0,\"name\":\"<top>\",\"line\":5");
    try has(text, "\"output\":\"3\\n\"");

    // A pause in a run of the loop.
    var it2: tcl.Interp = undefined;
    try it2.init(a);
    defer it2.deinit();
    var in2: std.ArrayList(u8) = .empty;
    defer in2.deinit(a);
    const reqs2 = [_][]const u8{
        \\{"seq":1,"type":"request","command":"launch","arguments":{"program":"/w/l.tcl"}}
        ,
        \\{"seq":2,"type":"request","command":"configurationDone"}
        ,
        \\{"seq":3,"type":"request","command":"pause","arguments":{"threadId":1}}
        ,
        \\{"seq":4,"type":"request","command":"continue","arguments":{"threadId":1}}
        ,
    };
    for (reqs2) |r| try frame(a, &in2, r);
    var reader2: std.Io.Reader = .fixed(in2.items);
    var out2: std.Io.Writer.Allocating = .init(a);
    defer out2.deinit();
    var polls: u32 = 0;
    var server2: tcl.dap.Server = .{ .it = &it2, .gpa = a, .in = &reader2, .out = &out2.writer, .read = dapReadLoop, .poll = pollLater, .poll_ctx = &polls, .poll_every = 1 };
    try tcl.dap.serve(&server2);
    try has(out2.written(), "\"reason\":\"pause\"");
    try has(out2.written(), "\"event\":\"exited\",\"body\":{\"exitCode\":0}");
}

test "ztcl::disasm lists the bytecode under the line of each command" {
    if (!options.mod_disasm) return error.SkipZigTest;
    const a = std.testing.allocator;
    var it: tcl.Interp = undefined;
    try it.init(a);
    defer it.deinit();
    _ = try it.eval(
        \\package require ztcl::disasm
        \\proc twice {x} {
        \\    set y [expr {$x * 2}]
        \\    return $y
        \\}
    );
    const text = try it.str(try it.eval("ztcl::disasm proc twice"));
    try has(text, "twice: ");
    try has(text, "  slot 0 x (parameter)\n  slot 1 y\n  # line 2: \"set y [expr {$x * 2}]\"\n     0 guard");
    try has(text, "  # line 3: \"return $y\"\n     4 guard");
    try has(text, "store_pop 1 0 0  # $y");
    const loop = try it.str(try it.eval("ztcl::disasm script {foreach i {1 2 3} {incr n $i}}"));
    try has(loop, "push 0 0 0  # \"1 2 3\"");
    try has(loop, "script: instructions 17, literals 1, slots 2, stack 4, jit ");
    const tcl_form = try it.str(try it.eval("::tcl::unsupported::disassemble proc twice"));
    try has(tcl_form, "  Proc 0x");
    try has(tcl_form, "      slot 0, scalar, arg, \"x\"");
    try has(tcl_form, "      3: pc 5-6, src 31-39        \"return $y\"");
    try has(tcl_form, "  Command 3: \"return $y\"\n    (4) guard");
    try std.testing.expectError(error.TclError, it.eval("ztcl::disasm proc puts"));
    try std.testing.expectEqualStrings("\"puts\" isn't a procedure", try it.str(it.result));
}

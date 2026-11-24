//! Tests of the core of the capability `thread` (`thread.zig`).
//!
//! Each test starts a host interpreter with the capability, uses the Zig
//! calls of the core, and ends the host. `std.testing.allocator` finds
//! each leak of a thread, a message, or the group.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl.zig");
const thread = tcl.thread;
const testing = std.testing;

fn host(it: *tcl.Interp) !void {
    try it.init(testing.allocator);
    errdefer it.deinit();
    try it.allow(@intFromEnum(tcl.interp.Capability.thread));
}

test "the default interpreter has no thread commands" {
    var it: tcl.Interp = undefined;
    try it.init(testing.allocator);
    defer it.deinit();
    try testing.expect(it.findCommand("thread::create") == null);
    try testing.expect(it.findCommand("tsv::set") == null);
    try testing.expect(it.worker == null);
}

test "a host sends a script to a thread and gets the result" {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it);
    defer it.deinit();
    const id = try thread.create(&it, "", false, false);
    const v = try thread.sendWait(&it, id, "set x 6; expr {$x * 7}", false);
    try testing.expectEqualStrings("42", try it.str(v));
    // The thread keeps its interpreter between messages.
    const v2 = try thread.sendWait(&it, id, "incr x", false);
    try testing.expectEqualStrings("7", try it.str(v2));
}

test "an error of a thread goes back to the sender" {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it);
    defer it.deinit();
    const id = try thread.create(&it, "", false, false);
    try testing.expectError(error.TclError, thread.sendWait(&it, id, "error boom", false));
    try testing.expectEqualStrings("boom", try it.str(it.result));
}

test "a list of integers and doubles crosses with its kinds" {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it);
    defer it.deinit();
    const id = try thread.create(&it, "", false, false);
    const v = try thread.sendWait(&it, id, "list [expr {3}] [expr {2.5}] [list [expr {-7}] abc]", false);
    try testing.expect(v == .list);
    const items = v.list.items();
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expect(items[0] == .int and items[0].int == 3);
    try testing.expect(items[1] == .double and items[1].double == 2.5);
    try testing.expect(items[2] == .list);
    const inner = items[2].list.items();
    try testing.expect(inner[0] == .int and inner[0].int == -7);
    try testing.expectEqualStrings("abc", try it.str(inner[1]));
}

test "a deep list crosses as its string form" {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it);
    defer it.deinit();
    const id = try thread.create(&it, "", false, false);
    const v = try thread.sendWait(&it, id, "set l x; for {set i 0} {$i < 300} {incr i} {set l [list $l]}; set l", false);
    const want = try it.eval("set l x; for {set i 0} {$i < 300} {incr i} {set l [list $l]}; set l");
    try testing.expectEqualStrings(try it.str(want), try it.str(v));
}

test "deinit of the host ends a thread in an endless loop" {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it);
    _ = try thread.create(&it, "while 1 {}", false, false);
    _ = try thread.create(&it, "proc f {} {while 1 {}}; f", false, false);
    _ = try thread.create(&it, "", false, false);
    it.deinit();
}

test "reset of the host ends its threads and keeps the limits" {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it);
    defer it.deinit();
    var lim = it.thread_limits;
    lim.max_threads = 1;
    thread.setLimits(&it, lim);
    _ = try thread.create(&it, "while 1 {}", false, false);
    try testing.expectError(error.TclError, thread.create(&it, "", false, false));
    try it.reset();
    try testing.expectEqual(@as(u32, 1), it.thread_limits.max_threads);
}

test "the step limit of a thread stops only that thread" {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it);
    defer it.deinit();
    var lim = it.thread_limits;
    lim.step_limit = 10_000;
    thread.setLimits(&it, lim);
    const id = try thread.create(&it, "", false, false);
    try testing.expectError(error.TclError, thread.sendWait(&it, id, "while 1 {}", false));
    const v = try it.eval("expr {1 + 1}");
    try testing.expectEqualStrings("2", try it.str(v));
}

test "the total steps bound the sum of the steps of the threads" {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it);
    defer it.deinit();
    var lim = it.thread_limits;
    lim.step_limit = 600;
    lim.total_steps = 1000;
    thread.setLimits(&it, lim);
    const a = try thread.create(&it, "", false, false);
    // The second thread gets the 400 steps that are left.
    const b = try thread.create(&it, "", false, false);
    try testing.expectError(error.TclError, thread.sendWait(&it, b, "for {set i 0} {$i < 1000} {incr i} {}", false));
    try testing.expectEqualStrings("step limit reached", try it.str(it.result));
    _ = try thread.sendWait(&it, a, "for {set i 0} {$i < 100} {incr i} {}", false);
}

test "the memory limit of a thread stops only that thread" {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it);
    defer it.deinit();
    var lim = it.thread_limits;
    lim.mem_limit = 4 << 20;
    thread.setLimits(&it, lim);
    const id = try thread.create(&it, "", false, false);
    try testing.expectError(error.TclError, thread.sendWait(&it, id, "set s x; while 1 {append s $s}", false));
    try testing.expectEqualStrings("the script used too much memory", try it.str(it.result));
}

test "the total memory of the group fails the allocation of a thread" {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it);
    defer it.deinit();
    var lim = it.thread_limits;
    lim.total_mem = 8 << 20;
    thread.setLimits(&it, lim);
    const id = try thread.create(&it, "", false, false);
    try testing.expectError(error.TclError, thread.sendWait(&it, id, "set s x; while 1 {append s $s}", false));
    const g = it.worker.?.group;
    try testing.expect(g.memUsed() <= 8 << 20);
    // The memory of the ended thread goes back to the group.
    const id2 = try thread.create(&it, "", false, false);
    const v = try thread.sendWait(&it, id2, "string length [string repeat x 1000]", false);
    try testing.expectEqualStrings("1000", try it.str(v));
}

test "the tsv commands keep the inline forms of the core commands" {
    if (!thread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try host(&it);
    defer it.deinit();
    _ = try it.eval("proc f {} {set x 1; incr x; lappend l a; llength $l}; f");
    try testing.expect(it.unsafe_epoch != it.epoch);
    // A proc of the same name in another namespace turns them off.
    _ = try it.eval("namespace eval other {proc set {args} {}}; f");
    try testing.expect(it.unsafe_epoch == it.epoch);
}

//! The census of loops for tier 2.
//!
//! For each script, the tool runs it in an interpreter with a step limit,
//! then compiles the body of each proc to bytecode and runs the verifier
//! of the JIT on it. Each loop head of the verifier starts a loop that
//! ends at the last backward jump to the head. The tool puts each loop
//! in one class:
//!
//! - int: only instructions of the integer set of tier 2.
//! - calls: the integer set and calls of helpers.
//! - no: an inner loop or a `ret` inside the loop.
//!
//! For the classes calls and no, the tool counts the first instruction
//! that puts the loop in its class.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl");

const vm = tcl.vm;
const verify = tcl.jit_verify;
const Allocator = std.mem.Allocator;

pub const Class = enum { int, calls, no };

/// The second successor of an instruction, or null.
pub fn targetOf(i: vm.Ins) ?u32 {
    return switch (i.op) {
        .jump, .jump_false, .jump_true, .guard => i.a,
        .jf_vv, .jf_vi => i.c,
        .foreach_next, .str_eq_jump => i.b,
        else => null,
    };
}

/// True for an instruction of the integer set of tier 2.
pub fn intSet(code: *const vm.Code, i: vm.Ins) bool {
    return switch (i.op) {
        .guard, .step, .jump, .jump_false, .jump_true, .jf_vv, .jf_vi, .to_bool, .push_empty, .pop, .load, .store, .store_pop, .incr, .incr_drop, .incr_value, .bin_vv, .bin_vi => true,
        .push => code.lits[i.a] == .int or code.lits[i.a] == .double,
        .binary => switch (@as(tcl.expr.BinOp, @enumFromInt(i.x))) {
            .add, .sub, .mul, .lt, .le, .gt, .ge, .eq, .ne => true,
            else => false,
        },
        else => false,
    };
}

/// The last address with a backward jump to `head`. A cold block is
/// after the last `ret`, and its jump back is no loop.
pub fn backOf(code: *const vm.Code, head: u32) ?u32 {
    var end: usize = code.ins.len;
    while (end > 0 and code.ins[end - 1].op != .ret) end -= 1;
    var back: ?u32 = null;
    for (code.ins[0..end], 0..) |i, pc| {
        if (pc < head) continue;
        if (targetOf(i)) |t| if (t == head) {
            back = @intCast(pc);
        };
    }
    return back;
}

pub const Loop = struct { head: u32, back: u32, class: Class, first: ?vm.Op };

/// The class of the loop from `head` to `back`.
pub fn classify(code: *const vm.Code, heads: []const u32, head: u32, back: u32) Loop {
    var out: Loop = .{ .head = head, .back = back, .class = .int, .first = null };
    for (heads) |h| if (h > head and h <= back) {
        return .{ .head = head, .back = back, .class = .no, .first = code.ins[h].op };
    };
    for (code.ins[head .. back + 1]) |i| {
        if (i.op == .ret) return .{ .head = head, .back = back, .class = .no, .first = .ret };
        if (!intSet(code, i) and out.class == .int) {
            out.class = .calls;
            out.first = i.op;
        }
    }
    return out;
}

fn discard(_: ?*anyopaque, _: []const u8) void {}

pub fn procCode(it: *tcl.Interp, p: *tcl.interp.Proc) !*vm.Code {
    if (p.script == null) p.script = try it.compile(try it.str(p.body));
    return vm.compileProc(it, p, p.script.?);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const a = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(arena);
    var total: [3]u64 = @splat(0);
    var firsts: std.AutoArrayHashMapUnmanaged(vm.Op, u64) = .empty;
    for (args[1..]) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |e| {
            std.debug.print("{s}: {t}\n", .{ path, e });
            continue;
        };
        var it: tcl.Interp = undefined;
        try it.init(a);
        defer it.deinit();
        it.output = .{ .write = discard };
        it.step_limit = 20_000_000;
        it.gc_on = false;
        _ = it.eval(text) catch {};
        var counts: [3]u64 = @splat(0);
        var iter = it.commands.iterator();
        while (iter.next()) |e| {
            if (e.value_ptr.*.impl != .proc) continue;
            const code = procCode(&it, e.value_ptr.*.impl.proc) catch continue;
            var info = (try verify.verify(a, code)) orelse continue;
            defer info.deinit(a);
            for (info.loop_heads) |head| {
                const back = backOf(code, head) orelse continue;
                const loop = classify(code, info.loop_heads, head, back);
                counts[@intFromEnum(loop.class)] += 1;
                if (loop.first) |op| {
                    const g = try firsts.getOrPut(a, op);
                    if (!g.found_existing) g.value_ptr.* = 0;
                    g.value_ptr.* += 1;
                }
            }
        }
        std.debug.print("{s}: int {d} calls {d} no {d}\n", .{ path, counts[0], counts[1], counts[2] });
        for (&total, counts) |*t, c| t.* += c;
    }
    std.debug.print("total: int {d} calls {d} no {d}\n", .{ total[0], total[1], total[2] });
    std.debug.print("first instruction outside the integer set:", .{});
    for (firsts.keys(), firsts.values()) |op, n| std.debug.print(" {t}={d}", .{ op, n });
    std.debug.print("\n", .{});
}

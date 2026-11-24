//! The bytecode verifier of the JIT.
//!
//! Before a `Code` compiles, `verify` proves each fact that machine code
//! relies on: each opcode and operator, each index, the stack depth at
//! each instruction, the loop state of `foreach`, and the targets of
//! `break` and `continue`. A `Code` that fails a check stays in the
//! interpreter.
//!
//! A work list starts at address 0 with depth 0 and visits each
//! successor. Each instruction has a need (the values that it reads from
//! the stack) and an effect on the depth. Two paths to one address must
//! give the same depth. So the depth before each instruction is static,
//! and machine code needs no stack pointer: each stack value has a fixed
//! offset.
//!
//! A mark is the stack place of a list that `foreach_init` made. The
//! place above it holds the index. `foreach_next` reads both without a
//! check of their kinds, so it needs a mark on them. An instruction
//! that pops or replaces a place clears its mark, and two paths to one
//! address must give the same marks.
//!
//! Each cycle of the reachable instructions must pass through an
//! instruction that counts a step: `step`, `guard`, `invoke`,
//! `eval_cmd`, or `foreach_next`. So the step limit stops each loop. A
//! depth-first search over the other instructions finds a cycle.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vm = @import("../vm.zig");
const expr = @import("../expr.zig");

const Allocator = std.mem.Allocator;
const Op = vm.Op;
const Ins = vm.Ins;
const Code = vm.Code;

pub const max_ins = 32768;
pub const max_slots = 2048;
pub const max_stack = 2048;
pub const max_items = 65536;

pub const Info = struct {
    /// The stack depth before each instruction.
    depth: []const u16,
    reachable: []const bool,
    /// Each target of a backward jump.
    loop_heads: []const u32,
    has_loop: bool,

    pub fn deinit(info: *Info, a: Allocator) void {
        a.free(info.depth);
        a.free(info.reachable);
        a.free(info.loop_heads);
        info.* = undefined;
    }
};

const no_target = std.math.maxInt(u32);
const unset = std.math.maxInt(u16);

/// The stack effect of one instruction.
pub const Effect = struct {
    /// The values that the instruction reads.
    need: u32,
    /// The depth after the instruction is `depth - need + push`.
    push: u32,
    /// True when the instruction reads its values and leaves them as
    /// they were.
    keeps: bool = false,
    /// The second successor, or `no_target`.
    target: u32 = no_target,
    /// False for `jump` and `ret`.
    falls: bool = true,
};

fn isCompare(op: expr.BinOp) bool {
    return switch (op) {
        .lt, .gt, .le, .ge, .eq, .ne => true,
        else => false,
    };
}

/// The opcode of an instruction, or null for a byte that is no member
/// of `Op`.
fn opcode(i: *const Ins) ?Op {
    return std.enums.fromInt(Op, std.mem.asBytes(i)[0]);
}

/// A literal word of a command.
fn literalWord(code: *const Code, site: u32, k: usize) bool {
    const cmd = code.sites[site];
    return k < cmd.words.len and cmd.words[k].kind == .lit;
}

/// Checks the operands of one instruction and gives its effect, or null.
fn effect(code: *const Code, pc: u32) ?Effect {
    const i = &code.ins[pc];
    const op = opcode(i) orelse return null;
    const slots = code.names.len;
    const n: u32 = @intCast(code.ins.len);
    switch (op) {
        .push => {
            if (i.a >= code.lits.len) return null;
            return .{ .need = 0, .push = 1 };
        },
        .push_empty => return .{ .need = 0, .push = 1 },
        .load => {
            if (i.a >= slots) return null;
            return .{ .need = 0, .push = 1 };
        },
        .eval_cmd => {
            if (i.a >= code.sites.len) return null;
            if (i.x > 1) return null;
            if (i.x == 1) {
                // A cold block: `b` is the address of its guard.
                if (i.b >= n or opcode(&code.ins[i.b]) != .guard) return null;
            }
            return .{ .need = 0, .push = 1 };
        },
        .word => {
            if (i.a >= code.words.len) return null;
            return .{ .need = 0, .push = 1 };
        },
        .node => {
            if (i.a >= code.nodes.len) return null;
            return .{ .need = 0, .push = 1 };
        },
        .incr => {
            if (i.a >= slots) return null;
            return .{ .need = 0, .push = 1 };
        },
        .bin_vv => {
            if (i.a >= slots or i.b >= slots) return null;
            _ = std.enums.fromInt(expr.BinOp, i.x) orelse return null;
            return .{ .need = 0, .push = 1 };
        },
        .bin_vi => {
            if (i.a >= slots or i.b >= code.lits.len or code.lits[i.b] != .int) return null;
            _ = std.enums.fromInt(expr.BinOp, i.x) orelse return null;
            return .{ .need = 0, .push = 1 };
        },
        .pop => return .{ .need = 1, .push = 0 },
        .store_pop => {
            if (i.a >= slots) return null;
            return .{ .need = 1, .push = 0 };
        },
        .store => {
            if (i.a >= slots) return null;
            return .{ .need = 1, .push = 1, .keeps = true };
        },
        .to_bool, .number_form => return .{ .need = 1, .push = 1 },
        .unary => {
            _ = std.enums.fromInt(expr.UnOp, i.x) orelse return null;
            return .{ .need = 1, .push = 1 };
        },
        .incr_value, .lappend => {
            if (i.a >= slots) return null;
            return .{ .need = 1, .push = 1 };
        },
        .access => return switch (i.x) {
            0, 2 => .{ .need = 1, .push = 1 },
            1, 3 => .{ .need = 2, .push = 1 },
            else => null,
        },
        .binary => {
            _ = std.enums.fromInt(expr.BinOp, i.x) orelse return null;
            return .{ .need = 2, .push = 1 };
        },
        .guard => {
            // The target is the cold block of this guard.
            if (i.a >= n) return null;
            const cold = &code.ins[i.a];
            if (opcode(cold) != .eval_cmd or cold.x != 1) return null;
            if (cold.b != pc) return null;
            return .{ .need = 0, .push = 0, .target = i.a };
        },
        .step, .incr_drop => {
            if (op == .incr_drop and i.a >= slots) return null;
            return .{ .need = 0, .push = 0 };
        },
        .jump => {
            if (i.a >= n) return null;
            return .{ .need = 0, .push = 0, .target = i.a, .falls = false };
        },
        .jump_false, .jump_true => {
            if (i.a >= n) return null;
            return .{ .need = 1, .push = 0, .target = i.a };
        },
        .jf_vv, .jf_vi => {
            if (i.a >= slots or i.c >= n) return null;
            const cmp = std.enums.fromInt(expr.BinOp, i.x) orelse return null;
            if (!isCompare(cmp)) return null;
            if (op == .jf_vv and i.b >= slots) return null;
            if (op == .jf_vi and (i.b >= code.lits.len or code.lits[i.b] != .int)) return null;
            return .{ .need = 0, .push = 0, .target = i.c };
        },
        .invoke => {
            if (i.a >= code.sites.len or i.b < 1) return null;
            return .{ .need = i.b, .push = 1 };
        },
        .concat => {
            if (i.a < 1) return null;
            return .{ .need = i.a, .push = 1 };
        },
        .append => {
            if (i.a >= slots or i.b < 1 or i.b > 8) return null;
            return .{ .need = i.b, .push = 1 };
        },
        .dict_update, .dict_update_drop => {
            if (i.a >= slots or i.b >= code.sites.len or i.x > 1) return null;
            for (0..3) |k| if (!literalWord(code, i.b, k)) return null;
            return .{ .need = 1 + @as(u32, i.x), .push = @intFromBool(op == .dict_update) };
        },
        .foreach_init => return .{ .need = 1, .push = 2 },
        .foreach_next => {
            if (i.a >= code.tables.len or i.b >= n) return null;
            const t = code.tables[i.a];
            if (t.len == 0) return null;
            for (t) |s| if (s >= slots) return null;
            return .{ .need = 2, .push = 2, .keeps = true, .target = i.b };
        },
        .ret => return .{ .need = 1, .push = 1, .keeps = true, .falls = false },
        .str_eq_jump => {
            if (i.a >= code.lits.len or code.lits[i.a] != .str or i.b >= n) return null;
            return .{ .need = 1, .push = 1, .keeps = true, .target = i.b };
        },
        .lassign, .lassign_drop => {
            if (i.a >= code.tables.len) return null;
            const t = code.tables[i.a];
            if (t.len == 0) return null;
            for (t) |s| if (s >= slots) return null;
            return .{ .need = 1, .push = @intFromBool(op == .lassign) };
        },
        .lset, .lset_drop => {
            if (i.a >= slots or i.b >= code.sites.len) return null;
            for (0..2) |k| if (!literalWord(code, i.b, k)) return null;
            return .{ .need = 2, .push = @intFromBool(op == .lset) };
        },
    }
}

/// The effect of instruction `pc`, or null when its operands fail a
/// check. Tier 2 reads the stack effect of each helper call.
pub fn effectAt(code: *const Code, pc: u32) ?Effect {
    return effect(code, pc);
}

/// The marks of one address: the stack places of `foreach` lists, in
/// increasing order.
const Marks = []const u16;

fn sameMarks(a: Marks, b: Marks) bool {
    return std.mem.eql(u16, a, b);
}

/// The marks below `depth`.
fn below(m: Marks, depth: u32) Marks {
    var k: usize = 0;
    while (k < m.len and m[k] + 1 < depth) k += 1;
    return m[0..k];
}

/// Returns null for a `Code` that fails a check.
pub fn verify(a: Allocator, code: *const Code) Allocator.Error!?Info {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const n = code.ins.len;
    if (code.named) return null;
    if (n == 0 or n > max_ins) return null;
    if (code.names.len > max_slots or code.max_stack > max_stack or code.max_stack == 0) return null;
    if (code.lits.len > max_items or code.sites.len > max_items or code.words.len > max_items) return null;
    if (code.nodes.len > max_items or code.tables.len > max_items) return null;
    for (code.tables) |t| if (t.len > max_slots) return null;

    const depth = try a.alloc(u16, n);
    var ok = false;
    defer if (!ok) a.free(depth);
    @memset(depth, unset);
    const marks = try arena.alloc(Marks, n);
    const reachable = try a.alloc(bool, n);
    defer if (!ok) a.free(reachable);
    @memset(reachable, false);
    var heads: std.ArrayList(u32) = .empty;
    defer if (!ok) heads.deinit(a);

    // The end of the main code: the last `ret`.
    var main_end: usize = n;
    while (main_end > 0 and code.ins[main_end - 1].op != .ret) main_end -= 1;

    var work: std.ArrayList(u32) = .empty;
    try work.append(arena, 0);
    depth[0] = 0;
    marks[0] = &.{};
    const top = code.max_stack - 1;
    while (work.pop()) |pc| {
        reachable[pc] = true;
        const i = &code.ins[pc];
        const e = effect(code, pc) orelse return null;
        const d: u32 = depth[pc];
        if (d < e.need) return null;
        const after = d - e.need + e.push;
        if (after > top) return null;
        // The marks after the instruction.
        var m = marks[pc];
        const op = opcode(i).?;
        if (op == .foreach_next) {
            if (m.len == 0 or m[m.len - 1] != d - 2) return null;
        } else if (op == .foreach_init) {
            const kept = below(m, d - 1);
            const nm = try arena.alloc(u16, kept.len + 1);
            @memcpy(nm[0..kept.len], kept);
            nm[kept.len] = @intCast(d - 1);
            m = nm;
        } else if (!e.keeps) {
            m = below(m, d - e.need);
        }
        var succ: [2]u32 = .{ no_target, no_target };
        if (e.falls) succ[0] = @intCast(pc + 1);
        succ[1] = e.target;
        for (succ) |s| {
            if (s == no_target) continue;
            if (s >= n) return null;
            // A cold block is after the last `ret`, and its jump back is
            // no loop.
            if (s <= pc and pc < main_end and std.mem.indexOfScalar(u32, heads.items, s) == null) try heads.append(a, s);
            if (depth[s] == unset) {
                depth[s] = @intCast(after);
                marks[s] = m;
                try work.append(arena, s);
            } else if (depth[s] != after or !sameMarks(marks[s], m)) return null;
        }
    }

    // The targets of `break` and `continue`.
    for (code.ranges) |r| {
        if (r.start > r.end or r.end > n) return null;
        for ([_]u32{ r.brk, r.cont }) |t| {
            if (t == no_target) continue;
            if (t >= n or !reachable[t] or depth[t] != r.depth) return null;
            const want = below(marks[t], r.depth);
            for (r.start..r.end) |pc| {
                if (!reachable[pc]) continue;
                if (depth[pc] < r.depth) return null;
                if (!sameMarks(below(marks[pc], r.depth), want)) return null;
            }
        }
    }

    if (try stepFreeCycle(arena, code, reachable)) return null;

    ok = true;
    const loop_heads = try heads.toOwnedSlice(a);
    return .{ .depth = depth, .reachable = reachable, .loop_heads = loop_heads, .has_loop = loop_heads.len > 0 };
}

/// True for an instruction that counts a step on each path through it.
/// The cold path of `guard` goes to an `eval_cmd`, which counts one.
fn counts(op: Op) bool {
    return switch (op) {
        .step, .guard, .invoke, .eval_cmd, .foreach_next => true,
        else => false,
    };
}

/// True when the reachable instructions that count no step have a cycle.
/// Each successor of each instruction has a valid address: the work
/// list of `verify` checked it.
fn stepFreeCycle(arena: Allocator, code: *const Code, reachable: []const bool) Allocator.Error!bool {
    const n = code.ins.len;
    // 0: not seen, 1: on the path, 2: done.
    const color = try arena.alloc(u8, n);
    @memset(color, 0);
    const Frame = struct { pc: u32, next: u8 };
    var path: std.ArrayList(Frame) = .empty;
    for (0..n) |root| {
        if (!reachable[root] or color[root] != 0 or counts(code.ins[root].op)) continue;
        color[root] = 1;
        try path.append(arena, .{ .pc = @intCast(root), .next = 0 });
        while (path.items.len > 0) {
            const top = &path.items[path.items.len - 1];
            const e = effect(code, top.pc).?;
            var succ: ?u32 = null;
            while (top.next < 2 and succ == null) {
                const k = top.next;
                top.next += 1;
                if (k == 0 and e.falls) succ = top.pc + 1;
                if (k == 1 and e.target != no_target) succ = e.target;
            }
            const s = succ orelse {
                color[top.pc] = 2;
                path.items.len -= 1;
                continue;
            };
            if (counts(code.ins[s].op)) continue;
            switch (color[s]) {
                1 => return true,
                2 => {},
                else => {
                    color[s] = 1;
                    try path.append(arena, .{ .pc = s, .next = 0 });
                },
            }
        }
    }
    return false;
}

// ---- The test hook ----

/// Counts of the hook in `vm.compileProc` of a test build.
pub var hook_runs: usize = 0;
pub var hook_failures: usize = 0;

/// Runs the verifier on a new `Code` in a test build.
pub fn testHook(code: *const Code) void {
    hook_runs += 1;
    var info = (verify(std.testing.allocator, code) catch return) orelse {
        hook_failures += 1;
        return;
    };
    info.deinit(std.testing.allocator);
}

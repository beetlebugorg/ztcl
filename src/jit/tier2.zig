//! The loop plan of tier 2: the loops that tier 2 can compile, and a
//! kind for each value in them. This file makes no machine code.
//!
//! A loop is the range from a loop head of the verifier to the last
//! backward jump to that head. Each jump inside a loop goes forward,
//! except the jump back to the head, and a loop with an inner loop is
//! not eligible. So one pass over the instructions of the range in their
//! order sees each predecessor of an instruction before the instruction.
//! The pass gives each stack place and each slot a kind: `int`,
//! `double`, or `any`. Two paths to one address with different kinds
//! give `any`.
//!
//! The kind of a slot at the head comes from its cell when the plan is
//! made. At the backward jump, each slot must have its kind at the head.
//! When a slot differs, the plan runs again one time with that slot as
//! `any`. When the second plan also differs, the loop is not eligible.
//!
//! A part is a run of instructions with no branch target after its
//! first instruction, no branch before its last instruction, and no
//! call. Tier 2 checks the steps of a part one time at its start. A
//! `guard` is no branch in tier 2: the entry and each call that can run
//! a script check the epoch, so each `guard` of the loop passes.
//!
//! A helper call can change each cell, so the plan gives no kind to a
//! slot that a helper writes: it gets `any`. `foreach_next` is the one
//! exception. Its slots keep their kind, and tier 2 checks the tag of
//! each item before the store.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vm = @import("../vm.zig");
const expr = @import("../expr.zig");
const verify = @import("verify.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum(u8) { int, double, any };

pub const SlotUse = struct {
    slot: u32,
    read: bool = false,
    written: bool = false,
    /// The kind at the head of the loop.
    entry: Kind,
    /// The count of instructions that read or write the slot.
    uses: u32 = 0,
};

pub const Part = struct { first: u32, last: u32, steps: u32 };

pub const LoopPlan = struct {
    head: u32,
    back: u32,
    /// Each slot of the loop.
    slots: []SlotUse,
    /// For each instruction of the loop, from `head`: the kind of each
    /// stack place before the instruction.
    kinds: []const []const Kind,
    /// For each instruction of the loop: the kind of each slot of `slots`
    /// before the instruction.
    slot_kinds: []const []const Kind,
    /// For each instruction of the loop: the kind of each stack place
    /// after the instruction, for both successors.
    outs: []const []const Kind,
    parts: []const Part,
    /// Each address where a guard can fail.
    exits: []const u32,
    /// True when the loop calls a helper that tier 2 has no inline form for.
    calls: bool,
    /// True for each instruction of the loop that a path from the head
    /// reaches.
    seen: []const bool,
    /// The memory of the plan.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(p: *LoopPlan) void {
        p.arena.deinit();
        p.* = undefined;
    }

    /// The index of `slot` in `slots`.
    pub fn index(p: *const LoopPlan, slot: u32) ?usize {
        for (p.slots, 0..) |u, k| if (u.slot == slot) return k;
        return null;
    }

    /// The index of a slot of the loop in `slots`.
    pub fn slotIndex(p: *const LoopPlan, slot: u32) usize {
        return p.index(slot).?;
    }
};

/// The second successor of an instruction, or null.
pub fn targetOf(i: vm.Ins) ?u32 {
    return switch (i.op) {
        .jump, .jump_false, .jump_true, .guard => i.a,
        .jf_vv, .jf_vi => i.c,
        .foreach_next, .str_eq_jump => i.b,
        else => null,
    };
}

fn falls(op: vm.Op) bool {
    return op != .jump and op != .ret;
}

/// The last address before the cold blocks: a cold block is after the
/// last `ret`, and its jump back is no loop.
fn mainEnd(code: *const vm.Code) usize {
    var end: usize = code.ins.len;
    while (end > 0 and code.ins[end - 1].op != .ret) end -= 1;
    return end;
}

/// The last address of the main code with a backward jump to `head`.
pub fn backOf(code: *const vm.Code, head: u32) ?u32 {
    var back: ?u32 = null;
    for (code.ins[0..mainEnd(code)], 0..) |i, pc| {
        if (pc < head) continue;
        if (targetOf(i)) |t| if (t == head) {
            back = @intCast(pc);
        };
    }
    return back;
}

/// The slots that an instruction reads and writes.
fn slotsOf(code: *const vm.Code, i: vm.Ins, out: *std.ArrayList(u32), a: Allocator) Allocator.Error!void {
    switch (i.op) {
        .load, .store, .store_pop, .incr, .incr_drop, .incr_value, .lappend, .append, .lset, .lset_drop, .dict_update, .dict_update_drop => try out.append(a, i.a),
        .bin_vv, .jf_vv => {
            try out.append(a, i.a);
            try out.append(a, i.b);
        },
        .bin_vi, .jf_vi => try out.append(a, i.a),
        .foreach_next, .lassign, .lassign_drop => for (code.tables[i.a]) |s| try out.append(a, s),
        else => {},
    }
}

fn isCompare(op: expr.BinOp) bool {
    return switch (op) {
        .lt, .le, .gt, .ge, .eq, .ne => true,
        else => false,
    };
}

/// The kind of `x op y`, or null when the operation is a helper call.
pub fn binKind(op: expr.BinOp, x: Kind, y: Kind) ?Kind {
    if (x == .any or y == .any) return null;
    if (isCompare(op)) return .int;
    return switch (op) {
        .add, .sub, .mul, .div => if (x == .int and y == .int) .int else .double,
        .mod => if (x == .int and y == .int) .int else null,
        else => null,
    };
}

const Builder = struct {
    a: Allocator,
    code: *const vm.Code,
    info: *const verify.Info,
    head: u32,
    back: u32,
    slots: []SlotUse,
    kinds: [][]Kind,
    slot_kinds: [][]Kind,
    outs: [][]Kind,
    /// True for each instruction that a path reaches.
    seen: []bool,
    calls: bool = false,

    fn slotIndex(b: *const Builder, slot: u32) usize {
        for (b.slots, 0..) |u, k| if (u.slot == slot) return k;
        unreachable;
    }

    /// Merges a state into the state before instruction `pc` of the loop.
    fn merge(b: *Builder, pc: u32, stack: []const Kind, slots: []const Kind) Allocator.Error!void {
        const k = pc - b.head;
        if (!b.seen[k]) {
            b.seen[k] = true;
            b.kinds[k] = try b.a.dupe(Kind, stack);
            b.slot_kinds[k] = try b.a.dupe(Kind, slots);
            return;
        }
        for (b.kinds[k], stack) |*x, y| if (x.* != y) {
            x.* = .any;
        };
        for (b.slot_kinds[k], slots) |*x, y| if (x.* != y) {
            x.* = .any;
        };
    }

    /// The forward pass. Returns the slot kinds at the backward jump.
    fn run(b: *Builder) Allocator.Error!?[]Kind {
        const code = b.code;
        const n = b.back - b.head + 1;
        @memset(b.seen, false);
        const entry = try b.a.alloc(Kind, b.slots.len);
        for (b.slots, entry) |u, *e| e.* = u.entry;
        try b.merge(b.head, &.{}, entry);
        // The stack depth at the head of a loop is not zero for a loop
        // inside an expression. The places below the loop keep `any`.
        const base = b.info.depth[b.head];
        b.kinds[0] = try b.a.alloc(Kind, base);
        @memset(b.kinds[0], .any);
        var at_back: ?[]Kind = null;
        for (0..n) |k| {
            const pc: u32 = @intCast(b.head + k);
            if (!b.seen[k]) continue;
            const i = code.ins[pc];
            var stack: std.ArrayList(Kind) = .empty;
            try stack.appendSlice(b.a, b.kinds[k]);
            const slots = try b.a.dupe(Kind, b.slot_kinds[k]);
            if (!try b.step(pc, i, &stack, slots)) return null;
            b.outs[k] = try b.a.dupe(Kind, stack.items);
            if (pc == b.back) {
                at_back = slots;
                continue;
            }
            if (falls(i.op) and pc + 1 <= b.back) try b.merge(pc + 1, stack.items, slots);
            if (targetOf(i)) |t| {
                if (t > pc and t <= b.back) {
                    try b.merge(t, try b.after(i, stack.items), slots);
                } else if (t <= pc and t != b.head) return null;
            }
        }
        return at_back;
    }

    /// The stack of the second successor. `foreach_next` and
    /// `str_eq_jump` keep their places, and the conditional jumps pop the
    /// condition before both successors.
    fn after(b: *Builder, i: vm.Ins, stack: []const Kind) Allocator.Error![]const Kind {
        _ = b;
        _ = i;
        return stack;
    }

    fn pop(stack: *std.ArrayList(Kind), n: usize) void {
        stack.items.len -= n;
    }

    /// Applies one instruction. False when the loop is not eligible.
    fn step(b: *Builder, pc: u32, i: vm.Ins, stack: *std.ArrayList(Kind), slots: []Kind) Allocator.Error!bool {
        const code = b.code;
        const a = b.a;
        const top = stack.items.len;
        switch (i.op) {
            .ret, .foreach_init => return false,
            .guard, .step, .jump => {},
            .jump_false, .jump_true => pop(stack, 1),
            .jf_vv, .jf_vi => {},
            .to_bool => stack.items[top - 1] = .int,
            .push => try stack.append(a, switch (code.lits[i.a]) {
                .int => .int,
                .double => .double,
                else => .any,
            }),
            .push_empty => try stack.append(a, .any),
            .pop => pop(stack, 1),
            .load => try stack.append(a, slots[b.slotIndex(i.a)]),
            .store => slots[b.slotIndex(i.a)] = stack.items[top - 1],
            .store_pop => {
                slots[b.slotIndex(i.a)] = stack.items[top - 1];
                pop(stack, 1);
            },
            .incr, .incr_drop => {
                const s = &slots[b.slotIndex(i.a)];
                if (s.* != .int) {
                    s.* = .any;
                    b.calls = true;
                }
                if (i.op == .incr) try stack.append(a, s.*);
            },
            .incr_value => {
                // With an integer slot and a value of the kind `any`, the
                // helper leaves an integer in the slot or a value that the
                // check after the call finds. The sum stays `any`.
                const s = &slots[b.slotIndex(i.a)];
                if (s.* != .int) {
                    s.* = .any;
                    b.calls = true;
                    stack.items[top - 1] = .any;
                } else if (stack.items[top - 1] != .int) {
                    b.calls = true;
                } else stack.items[top - 1] = .int;
            },
            .bin_vv, .bin_vi => {
                const x = slots[b.slotIndex(i.a)];
                const y = if (i.op == .bin_vv) slots[b.slotIndex(i.b)] else .int;
                const k = binKind(@enumFromInt(i.x), x, y) orelse blk: {
                    b.calls = true;
                    break :blk .any;
                };
                try stack.append(a, k);
            },
            .binary => {
                const k = binKind(@enumFromInt(i.x), stack.items[top - 2], stack.items[top - 1]) orelse blk: {
                    b.calls = true;
                    break :blk .any;
                };
                pop(stack, 1);
                stack.items[top - 2] = k;
            },
            else => {
                // A helper call. Its result has the kind `any`, and a
                // script that it runs can change each slot. The slots
                // that the helper writes get `any`.
                b.calls = true;
                switch (i.op) {
                    .lappend, .append, .lset, .lset_drop, .dict_update, .dict_update_drop => slots[b.slotIndex(i.a)] = .any,
                    .lassign, .lassign_drop => for (code.tables[i.a]) |s| {
                        slots[b.slotIndex(s)] = .any;
                    },
                    else => {},
                }
                const e = verify.effectAt(code, pc) orelse return false;
                pop(stack, e.need);
                if (e.keeps) {
                    try stack.appendNTimes(a, .any, e.need);
                    for (stack.items[top - e.need ..]) |*x| x.* = .any;
                } else try stack.appendNTimes(a, .any, e.push);
                if (i.op == .access and i.x == 0) stack.items[stack.items.len - 1] = .int;
            },
        }
        return true;
    }
};

/// Makes the plan of the loop at `head`, or null when the loop is not
/// eligible. `entry` gives the kind of each slot of the code now.
pub fn plan(a: Allocator, code: *const vm.Code, info: *const verify.Info, head: u32, entry: []const Kind) Allocator.Error!?LoopPlan {
    const back = backOf(code, head) orelse return null;
    // An inner loop.
    for (info.loop_heads) |h| if (h > head and h <= back) return null;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const ar = arena.allocator();
    // The slots of the loop.
    var list: std.ArrayList(SlotUse) = .empty;
    var tmp: std.ArrayList(u32) = .empty;
    for (code.ins[head .. back + 1]) |i| {
        tmp.clearRetainingCapacity();
        try slotsOf(code, i, &tmp, ar);
        for (tmp.items, 0..) |s, k| {
            const at = for (list.items, 0..) |u, j| {
                if (u.slot == s) break j;
            } else blk: {
                try list.append(ar, .{ .slot = s, .entry = if (s < entry.len) entry[s] else .any });
                break :blk list.items.len - 1;
            };
            const u = &list.items[at];
            u.uses += 1;
            const writes = switch (i.op) {
                .store, .store_pop, .incr, .incr_drop, .incr_value, .lappend, .append, .lset, .lset_drop, .dict_update, .dict_update_drop, .foreach_next, .lassign, .lassign_drop => k == 0 or i.op == .foreach_next or i.op == .lassign or i.op == .lassign_drop,
                else => false,
            };
            if (writes) u.written = true else u.read = true;
        }
    }
    const n = back - head + 1;
    var b: Builder = .{
        .a = ar,
        .code = code,
        .info = info,
        .head = head,
        .back = back,
        .slots = list.items,
        .kinds = try ar.alloc([]Kind, n),
        .slot_kinds = try ar.alloc([]Kind, n),
        .outs = try ar.alloc([]Kind, n),
        .seen = try ar.alloc(bool, n),
    };
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        b.calls = false;
        const at_back = (try b.run()) orelse {
            arena.deinit();
            return null;
        };
        var same = true;
        for (b.slots, at_back) |*u, k| if (u.entry != k) {
            same = false;
            u.entry = .any;
        };
        if (same) break;
        if (tries == 1) {
            arena.deinit();
            return null;
        }
    }
    // The parts and the exits.
    var parts: std.ArrayList(Part) = .empty;
    var exits: std.ArrayList(u32) = .empty;
    const starts = try ar.alloc(bool, n);
    @memset(starts, false);
    starts[0] = true;
    for (0..n) |k| {
        const pc: u32 = @intCast(head + k);
        const i = code.ins[pc];
        // A guard never jumps in tier 2: the epoch changes only in a
        // call, and the entry and each call check it.
        if (targetOf(i)) |t| if (i.op != .guard) {
            if (t > head and t <= back) starts[t - head] = true;
            if (k + 1 < n) starts[k + 1] = true;
        };
        if (b.seen[k] and !noCall(i, b.kinds[k], b.slot_kinds[k], &b) and k + 1 < n) starts[k + 1] = true;
    }
    var first: u32 = head;
    var steps: u32 = 0;
    for (0..n) |k| {
        const pc: u32 = @intCast(head + k);
        if (k > 0 and starts[k]) {
            try parts.append(ar, .{ .first = first, .last = pc - 1, .steps = steps });
            first = pc;
            steps = 0;
        }
        const i = code.ins[pc];
        if (i.op == .guard or i.op == .step) steps += 1;
        if (b.seen[k] and exitsAt(i, b.kinds[k], b.slot_kinds[k], &b)) try exits.append(ar, pc);
    }
    try parts.append(ar, .{ .first = first, .last = back, .steps = steps });
    return .{
        .head = head,
        .back = back,
        .slots = b.slots,
        .kinds = b.kinds,
        .slot_kinds = b.slot_kinds,
        .outs = b.outs,
        .parts = parts.items,
        .exits = exits.items,
        .calls = b.calls,
        .seen = b.seen,
        .arena = arena,
    };
}

/// True for an operator that tier 2 runs inline on two operands of
/// the kinds `x` and `y`: `+`, `-`, `*`, and the compares on integers
/// and doubles, `/` on both, and `%` on integers.
pub fn inlineOp(op: expr.BinOp, x: Kind, y: Kind) bool {
    if (x == .any or y == .any) return false;
    if (isCompare(op)) return true;
    return switch (op) {
        .add, .sub, .mul, .div => true,
        .mod => x == .int and y == .int,
        else => false,
    };
}

/// True when tier 2 runs the instruction with no helper call on any
/// path. Each other instruction ends its part, because a helper counts
/// its own steps and a script that it runs can use the step limit.
pub fn noCall(i: vm.Ins, stack: []const Kind, slots: []const Kind, b: anytype) bool {
    const top = stack.len;
    return switch (i.op) {
        .guard, .step, .jump, .pop, .push, .push_empty => true,
        .load => slots[b.slotIndex(i.a)] != .any,
        .store, .store_pop => slots[b.slotIndex(i.a)] != .any and stack[top - 1] == slots[b.slotIndex(i.a)],
        .jump_false, .jump_true, .to_bool => stack[top - 1] == .int,
        .jf_vv => inlineOp(@enumFromInt(i.x), slots[b.slotIndex(i.a)], slots[b.slotIndex(i.b)]),
        .jf_vi => inlineOp(@enumFromInt(i.x), slots[b.slotIndex(i.a)], .int),
        .incr, .incr_drop => slots[b.slotIndex(i.a)] == .int,
        .incr_value => slots[b.slotIndex(i.a)] == .int and stack[top - 1] == .int,
        .bin_vv => inlineOp(@enumFromInt(i.x), slots[b.slotIndex(i.a)], slots[b.slotIndex(i.b)]),
        .bin_vi => inlineOp(@enumFromInt(i.x), slots[b.slotIndex(i.a)], .int),
        .binary => inlineOp(@enumFromInt(i.x), stack[top - 2], stack[top - 1]),
        else => false,
    };
}

/// True when an inline form of the instruction has a guard that can
/// fail: an overflow of `+`, `-`, `*`, or `incr` on integers, and a NaN
/// result of an operation on doubles.
fn exitsAt(i: vm.Ins, stack: []const Kind, slots: []const Kind, b: *const Builder) bool {
    if (!noCall(i, stack, slots, b)) return false;
    return switch (i.op) {
        .incr, .incr_drop, .incr_value => true,
        .bin_vv, .bin_vi, .binary => !isCompare(@enumFromInt(i.x)),
        else => false,
    };
}

/// The helpers that run no script and read or write no cell. After a
/// call of one of them, tier 2 loads its registers again with no check
/// of the epoch and of the tags of the cells. Each entry reads only
/// values of the stack. A value can change its form in place, and a
/// helper can allocate, so the memory check after the call stays.
pub fn runsNoScript(i: vm.Ins) bool {
    return switch (i.op) {
        // `llength`, `lindex`, `string length`, and `string index` of a
        // value: a parse of the value, with no command and no variable.
        .access => true,
        // The string of the joined values.
        .concat => true,
        // An operator of `expr` on two values or one value. `expr`
        // functions are nodes, so no operator calls a command.
        .binary, .unary => true,
        // The number form of a string.
        .number_form => true,
        // The truth value of a string, and a jump on it.
        .to_bool, .jump_false, .jump_true => true,
        else => false,
    };
}

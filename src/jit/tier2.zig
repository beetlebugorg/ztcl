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
//! call. Tier 2 checks the steps of a part one time at its start.
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
        .add, .sub, .mul => if (x == .int and y == .int) .int else .double,
        .div => if (x == .int and y == .int) null else .double,
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
                const s = &slots[b.slotIndex(i.a)];
                if (s.* != .int or stack.items[top - 1] != .int) {
                    s.* = .any;
                    b.calls = true;
                }
                stack.items[top - 1] = s.*;
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
                // script that it runs can change each slot.
                b.calls = true;
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
        // A guard in a loop with no call never jumps: the epoch changes
        // only in a call, and the entry checks it.
        if (targetOf(i)) |t| if (i.op != .guard or b.calls) {
            if (t > head and t <= back) starts[t - head] = true;
            if (k + 1 < n) starts[k + 1] = true;
        };
        if (!isInline(code, i, b.kinds[k], b.slot_kinds[k], &b) and k + 1 < n) starts[k + 1] = true;
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
        if (b.seen[k] and exitsAt(code, i, b.kinds[k], b.slot_kinds[k], &b)) try exits.append(ar, pc);
    }
    try parts.append(ar, .{ .first = first, .last = back, .steps = steps });
    return .{
        .head = head,
        .back = back,
        .slots = b.slots,
        .kinds = b.kinds,
        .slot_kinds = b.slot_kinds,
        .parts = parts.items,
        .exits = exits.items,
        .calls = b.calls,
        .seen = b.seen,
        .arena = arena,
    };
}

/// True when tier 2 runs the instruction with no helper call.
fn isInline(code: *const vm.Code, i: vm.Ins, stack: []const Kind, slots: []const Kind, b: *const Builder) bool {
    _ = code;
    const top = stack.len;
    return switch (i.op) {
        .guard, .step, .jump, .jump_false, .jump_true, .to_bool, .pop, .load, .store, .store_pop, .push, .push_empty => true,
        .jf_vv => slots[b.slotIndex(i.a)] == .int and slots[b.slotIndex(i.b)] == .int,
        .jf_vi => slots[b.slotIndex(i.a)] == .int,
        .incr, .incr_drop => slots[b.slotIndex(i.a)] == .int,
        .incr_value => slots[b.slotIndex(i.a)] == .int and stack[top - 1] == .int,
        .bin_vv => binKind(@enumFromInt(i.x), slots[b.slotIndex(i.a)], slots[b.slotIndex(i.b)]) != null,
        .bin_vi => binKind(@enumFromInt(i.x), slots[b.slotIndex(i.a)], .int) != null,
        .binary => binKind(@enumFromInt(i.x), stack[top - 2], stack[top - 1]) != null,
        else => false,
    };
}

/// True when an inline form of the instruction has a guard that can
/// fail: an overflow of `+`, `-`, `*`, or `incr` on integers, and a
/// compare of slots that are not both integers.
fn exitsAt(code: *const vm.Code, i: vm.Ins, stack: []const Kind, slots: []const Kind, b: *const Builder) bool {
    if (!isInline(code, i, stack, slots, b)) return false;
    return switch (i.op) {
        .incr, .incr_drop, .incr_value => true,
        .bin_vv, .bin_vi, .binary => switch (@as(expr.BinOp, @enumFromInt(i.x))) {
            .add, .sub, .mul => true,
            else => false,
        },
        .jump_false, .jump_true, .to_bool => stack[stack.len - 1] != .int,
        else => false,
    };
}

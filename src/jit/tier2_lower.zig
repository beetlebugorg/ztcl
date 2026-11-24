//! The part of the code generation of tier 2 that does not depend on
//! the instruction set: the facts that each backend reads from a loop
//! plan before it emits code.
//!
//! - `eligible` decides if a loop fits the registers of a backend. A
//!   backend gives its counts of registers as a `Budget`.
//! - `slotClass` puts each slot in a register of integers, a register of
//!   doubles, or its cell.
//! - `checkAt` and `stepsLeft` give the place of the step check of each
//!   part and the steps that an exit gives back.
//! - `needsFix` finds the edges where a place goes from a register to
//!   the value stack.
//! - `nanFree` decides when the result of an operation on doubles needs
//!   no check for a NaN.
//! - `branchTarget` gives the second successor of a helper call.
//!
//! Each fact here is a pure function of the bytecode, the verifier, and
//! the plan. The x86-64 backend uses each one, and the tests check them
//! with no machine code.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vm = @import("../vm.zig");
const expr = @import("../expr.zig");
const verify = @import("verify.zig");
const tier2 = @import("tier2.zig");

const Allocator = std.mem.Allocator;
const Kind = tier2.Kind;

/// The registers that a backend has for the values of a loop. A slot
/// register holds one slot for the whole loop. A place register holds
/// one stack place or one constant.
pub const Budget = struct {
    int_slots: usize,
    int_places: usize,
    double_slots: usize,
    double_places: usize,
};

/// x86-64: `r8` to `r11` and `rdx` for integer slots, and `rsi`, `rdi`,
/// and `r12` more for places. `xmm0` to `xmm3` for double slots, and
/// `xmm6` to `xmm15` more for places. A slot register that no slot uses
/// holds a place.
pub const x64_budget: Budget = .{ .int_slots = 5, .int_places = 3, .double_slots = 4, .double_places = 10 };

/// arm64, the plan of the hand-off in `docs/jit.md`: `x9` to `x13` for
/// integer slots and `x3` to `x8` for places, `d16` to `d19` for double
/// slots and `d22` to `d31` for places. `x14`, `x15`, `d20`, and `d21`
/// are scratch.
pub const a64_budget: Budget = .{ .int_slots = 5, .int_places = 6, .double_slots = 4, .double_places = 10 };

/// The kind of an exit, in the high bits of the fourth argument of
/// `resume_at`. The low bits are the number of the loop head.
pub const exit_guard: u32 = 1 << 30;
pub const exit_forced: u32 = 1 << 31;

pub const SlotClass = enum { int, double, cell };

/// The place of a slot: the kind at the head decides it. `eligible`
/// checks that the slot keeps that kind in the whole loop.
pub fn slotClass(u: tier2.SlotUse) SlotClass {
    return switch (u.entry) {
        .int => .int,
        .double => .double,
        .any => .cell,
    };
}

pub fn falls(op: vm.Op) bool {
    return op != .jump and op != .ret;
}

/// True when the backend can compile the loop of the plan with the
/// registers of `b`. Each slot keeps its kind at each instruction. Each
/// stack place below the depth of the head is `any`, and each place
/// above it fits in a register. On an edge, a place keeps its kind or
/// goes to the value stack. A double literal is not a NaN, and
/// `foreach_next` is only at the head.
pub fn eligible(code: *const vm.Code, info: *const verify.Info, p: *const tier2.LoopPlan, b: Budget) bool {
    var nint: usize = 0;
    var ndouble: usize = 0;
    for (p.slots) |u| switch (slotClass(u)) {
        .int => nint += 1,
        .double => ndouble += 1,
        .cell => {},
    };
    if (nint > b.int_slots or ndouble > b.double_slots) return false;
    const base = info.depth[p.head];
    const room = @min(b.int_slots - nint + b.int_places, b.double_slots - ndouble + b.double_places);
    for (p.head..p.back + 1) |pc| {
        const k = pc - p.head;
        if (!p.seen[k]) continue;
        const i = code.ins[pc];
        const outs = p.outs[k];
        for ([2]?u32{ if (falls(i.op)) @as(u32, @intCast(pc + 1)) else null, tier2.targetOf(i) }) |succ| {
            const t = succ orelse continue;
            if (i.op == .guard or t < p.head or t > p.back) continue;
            const into = p.kinds[t - p.head];
            if (into.len != outs.len) return false;
            for (outs, into) |x, y| if (x != y and y != .any) return false;
        }
        const e = verify.effectAt(code, @intCast(pc)) orelse return false;
        const d = info.depth[pc];
        if (d + e.push > base + room) return false;
        for (p.slot_kinds[k], p.slots) |kind, u| if (kind != u.entry) return false;
        for (p.kinds[k], 0..) |kind, place| if (kind != .any and place < base) return false;
        switch (i.op) {
            .push => if (code.lits[i.a] == .double and std.math.isNan(code.lits[i.a].double)) return false,
            // `foreach_next` reads its list and its index below the
            // places of the loop.
            .foreach_next => if (pc != p.head) return false,
            .ret, .foreach_init => return false,
            else => {},
        }
    }
    return true;
}

/// The address of the step check of a part: its first instruction that
/// is not a `pop`. A `pop` has no code, so the check there is the check
/// at the start of the part, and the place that the `pop` drops needs no
/// value at the exit of the check.
pub fn checkAt(code: *const vm.Code, part: tier2.Part) u32 {
    var pc = part.first;
    while (pc < part.last and code.ins[pc].op == .pop) pc += 1;
    return pc;
}

/// For each instruction of the loop: the steps of its part from the
/// instruction to the end of the part. An exit before the instruction
/// gives these steps back.
pub fn stepsLeft(a: Allocator, code: *const vm.Code, p: *const tier2.LoopPlan) Allocator.Error![]u32 {
    const left = try a.alloc(u32, p.back - p.head + 1);
    for (p.parts) |part| {
        var steps: u32 = 0;
        var pc = part.last + 1;
        while (pc > part.first) {
            pc -= 1;
            const op = code.ins[pc].op;
            if (op == .guard or op == .step) steps += 1;
            left[pc - p.head] = steps;
        }
    }
    return left;
}

/// True when a place in a register after `pc` is in the value stack
/// before `t`: two paths reach `t` with two kinds.
pub fn needsFix(p: *const tier2.LoopPlan, pc: u32, t: u32) bool {
    const outs = p.outs[pc - p.head];
    const into = p.kinds[t - p.head];
    for (outs, into) |x, y| if (x != .any and y == .any) return true;
    return false;
}

/// What the backend knows of an operand of an operation on doubles.
/// `finite` is true for an integer and for a finite literal, and
/// `nonzero` for a literal that is finite and not zero.
pub const Known = struct { finite: bool = false, nonzero: bool = false };

/// True when the result of `x op y` is never a NaN. No operand in a
/// register is a NaN. A sum or a difference is a NaN only for two
/// infinities of opposite signs, so one finite operand is enough. A
/// product is a NaN only for zero and an infinity, and a quotient only
/// for two zeros or two infinities, so a finite literal that is not
/// zero is enough.
pub fn nanFree(op: expr.BinOp, x: Known, y: Known) bool {
    return switch (op) {
        .add, .sub => x.finite or y.finite,
        .mul, .div => x.nonzero or y.nonzero,
        else => true,
    };
}

/// `Known` of a double literal.
pub fn knownOf(v: f64) Known {
    const f = std.math.isFinite(v);
    return .{ .finite = f, .nonzero = f and v != 0 };
}

/// The second successor of a helper call of `i`: the helper gives 1 to
/// go there. Null for a helper with one successor.
pub fn branchTarget(i: vm.Ins) ?u32 {
    return switch (i.op) {
        .jump_false, .jump_true => i.a,
        .jf_vv, .jf_vi => i.c,
        .foreach_next, .str_eq_jump => i.b,
        else => null,
    };
}

//! The code of tier 2 for x86-64: one loop with the integers and the
//! doubles of its slots and of its stack places in registers.
//!
//! Tier 1 jumps to the entry block of the loop with its own frame, so the
//! code of tier 2 has no prologue. The entry block checks that each slot
//! of the kind `int` is a plain cell with an integer, loads each integer
//! into its register, and checks the epoch and the memory count. A failed
//! check goes back to the tier 1 code of the loop head with no change.
//! A slot of the kind `any` stays in its cell.
//!
//! The value stack of the loop is virtual: stack place `k` above the
//! depth of the head is a fixed register when its kind is `int` at an
//! instruction, and it is in the value stack when its kind is `any`.
//! Each part of the plan checks its steps one time at its start. Each
//! operation writes a scratch register first, and a slot register or a
//! stack place changes only after the overflow check.
//!
//! A call out of the loop first writes each changed slot register to its
//! cell and each stack place in a register to the value stack. The state
//! is then the state of tier 1 at the instruction, so the helper of tier
//! 1 runs, and its error goes to the error stub of the instruction. After
//! a call that can run a script, the code checks the epoch, the memory
//! count, and the cell and the tag of each slot in a register, and loads
//! each register again. A failed check exits at the next instruction with
//! no value to write. The registers hold only integers, so the collector
//! sees each live pointer in a cell or in the value stack at each call.
//!
//! A double is in an SSE register, and `+`, `-`, `*`, `/`, and the
//! compares use `addsd`, `subsd`, `mulsd`, `divsd`, and `ucomisd`, with
//! no fused multiply-add and the rounding mode of the process. An
//! integer operand goes through `cvtsi2sd`, as `@floatFromInt` does. No
//! register holds a NaN: the entry and each load after a call check each
//! double, and a result that can be a NaN has a check after the
//! operation. A NaN result is a valid result in Tcl, so that check exits
//! after the instruction, with the result in its place. The interpreter
//! then raises the error at the next use of the NaN as an operand. So an
//! operand in a register is never a NaN, and `ucomisd` needs no check of
//! the parity flag. A stack place of a double can be the register of a
//! slot or of a constant until an instruction needs it in its own
//! register.
//!
//! An exit writes each slot register to its cell and each stack place to
//! the value stack, gives back the steps of the part that did not run,
//! and calls `resume_at`. That helper gives the address of the tier 1
//! code of the exit address, and the code jumps there. When tier 1 has
//! no code there, the function returns status 2 and `exec` runs.
//!
//! No value of a script is an immediate operand. The immediates are slot
//! offsets, literal offsets, bytecode addresses, stack depths, and step
//! counts of a part, and the verifier bounds each one.
//!
//! On Windows, `rsi`, `rdi`, and `xmm6` to `xmm15` are callee-saved.
//! Tier 2 uses them for stack places and constants, so a port to Windows
//! must save them in the prologue of tier 1 or take them out of
//! `extra_regs` and `extra_xregs`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vm = @import("../vm.zig");
const x64 = @import("x64.zig");
const abi = @import("abi.zig");
const verify = @import("verify.zig");
const layout = @import("layout.zig");
const helpers = @import("helpers.zig");
const tier2 = @import("tier2.zig");
const lower = @import("tier2_lower.zig");
const tier1 = @import("tier1_x64.zig");
const expr = @import("../expr.zig");
const jit = @import("../jit.zig");

const Allocator = std.mem.Allocator;
const Asm = x64.Asm;
const Label = x64.Label;
const Reg = x64.Reg;
const Xmm = x64.Xmm;
const Mem = x64.Mem;
const Cond = x64.Cond;
const Kind = tier2.Kind;
const Helper = helpers.Helper;

pub const Error = Allocator.Error || error{ Range, UnboundLabel, Layout };

/// The registers of the slots of the kind `int`, in the order of the
/// plan.
const slot_regs = [_]Reg{ .r8, .r9, .r10, .r11, .rdx };

/// The registers of stack places and constants: the slot registers that
/// no slot uses, then `rsi`, `rdi`, and `r12`. A call writes each one
/// that holds a value first and loads it again after. `r12` is the
/// pinned register of the helper table: a call and each exit load it
/// again from the context. On Windows, `rsi` and `rdi` are callee-saved.
const extra_regs = [_]Reg{ .rsi, .rdi, abi.helpers };

/// The registers of the slots of the kind `double`.
const slot_xregs = [_]Xmm{ .xmm0, .xmm1, .xmm2, .xmm3 };

/// The registers of stack places and constants of the kind `double`:
/// the slot registers that no slot uses, then these. `xmm4` and `xmm5`
/// are scratch. On Windows, `xmm6` to `xmm15` are callee-saved.
const extra_xregs = [_]Xmm{ .xmm6, .xmm7, .xmm8, .xmm9, .xmm10, .xmm11, .xmm12, .xmm13, .xmm14, .xmm15 };

/// True when tier 2 can compile the loop of the plan with the registers
/// of x86-64.
pub fn eligible(code: *const vm.Code, info: *const verify.Info, p: *const tier2.LoopPlan) bool {
    return lower.eligible(code, info, p, lower.x64_budget);
}

const falls = lower.falls;
const checkAt = lower.checkAt;

/// The kind of an exit, in the high bits of the fourth argument of
/// `resume_at`. The low bits are the number of the loop head.
pub const exit_guard = lower.exit_guard;
pub const exit_forced = lower.exit_forced;

const Exit = struct {
    at: Label,
    /// The address where tier 1 continues.
    pc: u32,
    refund: u32,
    kind: u32 = 0,
    /// The instruction whose kinds give the place of each stack value.
    from: u32,
    /// True when each value is in its cell and in the value stack.
    synced: bool = false,
    /// With `synced`: the integer slot registers have the values, and
    /// the exit writes them to their cells first.
    kept: bool = false,
};

/// A constant in a register: the step of the `incr` at address `index`,
/// or the integer literal `index`.
const Const = struct { lit: bool, index: u32, reg: Reg };

/// The double literal `index` in a register.
const XConst = struct { index: u32, reg: Xmm };

/// An operand of an operation on doubles. `finite` is true for an
/// integer and for a finite literal, and `nonzero` for a literal that is
/// finite and not zero.
const Operand = struct {
    loc: union(enum) { x: Xmm, g: Reg, lit: u32 },
    finite: bool = false,
    nonzero: bool = false,
};

/// The slow path of an instruction with a fast path: a call of its
/// helper with the state of tier 1. `saved` is a register that the fast
/// path pushed.
const Slow = struct { at: Label, pc: u32, saved: ?Reg = null };

/// A jump from `pc` to `to` that writes places to the value stack first.
const Fix = struct { at: Label, pc: u32, to: u32 };

const Emitter = struct {
    s: *Asm,
    a: Allocator,
    code: *const vm.Code,
    info: *const verify.Info,
    p: *const tier2.LoopPlan,
    l: layout.Layout,
    /// The label of each instruction of the loop.
    labels: []Label,
    base: u32,
    /// The register of each slot of the plan, or null for a slot that
    /// stays in its cell.
    regs: []?Reg,
    stack_regs: []Reg,
    /// The SSE register of each slot of the kind `double`.
    xregs: []?Xmm,
    xstack: []Xmm,
    xconsts: std.ArrayList(XConst) = .empty,
    /// For each stack place of the loop: the register that holds its
    /// double in place of its own register, and the value of a double
    /// literal in it.
    alias: []?Xmm,
    known: []?f64,
    exits: std.ArrayList(Exit) = .empty,
    slows: std.ArrayList(Slow) = .empty,
    fixes: std.ArrayList(Fix) = .empty,
    /// The error stubs of calls that kept the integer slot registers.
    kept: std.ArrayList(Fix) = .empty,
    /// The error stub of each instruction of the loop.
    stubs: []?Label,
    /// The registers of the constants that the entry block loads: the
    /// step of each `incr` and each integer literal of the loop.
    consts: std.ArrayList(Const) = .empty,
    /// True for each instruction of the loop that a jump reaches.
    targets: []bool,
    /// True for the instruction after a result that went to its slot or
    /// that the next `pop` drops.
    skip: bool = false,
    /// The number of the loop head in the function, and the count of
    /// loop heads: the stress counter follows the pass counters.
    loop: u32,
    heads: u32,
    /// The stress mode that fails each guard on a schedule.
    stress: bool,
    /// For each instruction of the loop: the steps of its part from the
    /// instruction to the end of the part.
    left: []u32,
    head_exit: Label,
    resume_l: Label,
    epilogue: Label,
    /// True when `r12` holds a stack place or a constant.
    r12_used: bool = false,

    fn itAt(off: u32) Mem {
        return .{ .base = abi.it, .disp = @intCast(off) };
    }

    fn ctxSlot() Mem {
        return .{ .base = abi.fp, .disp = abi.ctx_slot };
    }

    fn slotReg(e: *const Emitter, slot: u32) ?Reg {
        return e.regs[e.p.index(slot).?];
    }

    fn slotX(e: *const Emitter, slot: u32) ?Xmm {
        return e.xregs[e.p.index(slot).?];
    }

    /// The SSE register of stack place `k`.
    fn xplace(e: *const Emitter, k: u32) Xmm {
        return e.xstack[k - e.base];
    }

    /// The register that holds the double of place `k` now.
    fn xloc(e: *const Emitter, k: u32) Xmm {
        return e.alias[k - e.base] orelse e.xplace(k);
    }

    /// Moves each double of the places before `pc` below place `limit`
    /// to its own register.
    fn settleBelow(e: *Emitter, pc: u32, limit: u32) Error!void {
        var k = e.base;
        while (k < limit and k - e.base < e.alias.len) : (k += 1) {
            const a = e.alias[k - e.base] orelse continue;
            if (e.kindAt(pc, k) == .double) try e.s.movapd(e.xplace(k), a);
            e.alias[k - e.base] = null;
        }
    }

    /// `settleBelow` for each place before `pc`.
    fn settle(e: *Emitter, pc: u32) Error!void {
        try e.settleBelow(pc, e.depth(pc));
    }

    /// Moves each place below `limit` that holds the register `r` to its
    /// own register, before a write of `r`.
    fn settleReg(e: *Emitter, pc: u32, limit: u32, r: Xmm) Error!void {
        var k = e.base;
        while (k < limit) : (k += 1) {
            if (e.alias[k - e.base] != r) continue;
            if (e.kindAt(pc, k) == .double) try e.s.movapd(e.xplace(k), r);
            e.alias[k - e.base] = null;
        }
    }

    fn xconstReg(e: *const Emitter, index: u32) ?Xmm {
        for (e.xconsts.items) |c| if (c.index == index) return c.reg;
        return null;
    }

    fn litDouble(e: *Emitter, index: u32, dst: Xmm) Error!void {
        try e.s.movRM(.rax, .{ .base = abi.code, .disp = @intCast(e.l.code_lits) });
        try e.s.movsdXM(dst, try x64.at(.rax, @as(i64, index) * e.l.value_size + e.l.value_payload));
    }

    /// The register of stack place `k`.
    fn place(e: *const Emitter, k: u32) Reg {
        return e.stack_regs[k - e.base];
    }

    fn depth(e: *const Emitter, pc: u32) u32 {
        return e.info.depth[pc];
    }

    fn kinds(e: *const Emitter, pc: u32) []const Kind {
        return e.p.kinds[pc - e.p.head];
    }

    /// The kind of stack place `k` before instruction `pc`.
    fn kindAt(e: *const Emitter, pc: u32, k: u32) Kind {
        const ks = e.kinds(pc);
        return if (k < ks.len) ks[k] else .any;
    }

    fn inLoop(e: *const Emitter, pc: u32) bool {
        return pc >= e.p.head and pc <= e.p.back;
    }

    fn stackAt(e: *const Emitter, k: u32, off: u32) Error!Mem {
        return x64.at(abi.stack, @as(i64, k) * e.l.value_size + off);
    }

    fn exitFrom(e: *Emitter, pc: u32, from: u32, refund: u32, kind: u32) Error!Label {
        const l = try e.s.newLabel();
        try e.exits.append(e.a, .{ .at = l, .pc = pc, .refund = refund, .kind = kind, .from = from });
        return l;
    }

    fn exit(e: *Emitter, pc: u32, refund: u32) Error!Label {
        return e.exitFrom(pc, pc, refund, 0);
    }

    /// An exit at `pc` where each value is in its cell or in the value
    /// stack.
    fn synced(e: *Emitter, pc: u32, kind: u32) Error!Label {
        const l = try e.s.newLabel();
        try e.exits.append(e.a, .{ .at = l, .pc = pc, .refund = 0, .kind = kind, .from = pc, .synced = true });
        return l;
    }

    /// `synced` after a call that kept the integer slot registers.
    fn syncedKept(e: *Emitter, pc: u32, kind: u32, kept: bool) Error!Label {
        const l = try e.synced(pc, kind);
        e.exits.items[e.exits.items.len - 1].kept = kept;
        return l;
    }

    /// The stress check: the stress counter goes down, and at zero the
    /// code jumps to `forced`. It uses `rax`.
    fn stressCheck(e: *Emitter, forced: Label) Error!void {
        try e.s.movRM(.rax, ctxSlot());
        try e.s.movRM(.rax, .{ .base = .rax, .disp = @offsetOf(jit.EnterCtx, "counters") });
        try e.s.aluMI32(.sub, try x64.at(.rax, @as(i64, e.heads) * 4), 1);
        try e.s.jcc(.e, forced);
    }

    /// The exit of a guard that can fail at `pc`. In the stress mode, the
    /// stress counter goes down first, and at zero the guard fails.
    fn guardExit(e: *Emitter, pc: u32, refund: u32) Error!Label {
        const l = try e.exitFrom(pc, pc, refund, exit_guard);
        if (e.stress) try e.stressCheck(try e.exitFrom(pc, pc, refund, exit_forced));
        return l;
    }

    /// The label of a jump target of instruction `pc`: an instruction of
    /// the loop, or an exit to the code after it.
    fn target(e: *Emitter, pc: u32, t: u32) Error!Label {
        if (!e.inLoop(t)) return e.exitFrom(t, pc, e.left[pc - e.p.head], 0);
        if (!e.needsFix(pc, t)) return e.labels[t - e.p.head];
        const lb = try e.s.newLabel();
        try e.fixes.append(e.a, .{ .at = lb, .pc = pc, .to = t });
        return lb;
    }

    /// True when a place in a register after `pc` is in the value stack
    /// at `t`: two paths reach `t` with two kinds.
    fn needsFix(e: *const Emitter, pc: u32, t: u32) bool {
        return lower.needsFix(e.p, pc, t);
    }

    /// Writes each place in a register after `pc` that is in the value
    /// stack at `t`.
    fn fix(e: *Emitter, pc: u32, t: u32) Error!void {
        const outs = e.p.outs[pc - e.p.head];
        const into = e.kinds(t);
        for (outs, into, 0..) |x, y, k| if (x != .any and y == .any) try e.writePlace(@intCast(k), x, e.xloc(@intCast(k)));
    }

    /// Writes the value of place `k` of kind `kind` to the value stack.
    /// `x` is the register of a double.
    fn writePlace(e: *Emitter, k: u32, kind: Kind, x: Xmm) Error!void {
        const l = e.l;
        if (kind == .double) {
            try e.s.movsdMX(try e.stackAt(k, l.value_payload), x);
            try e.s.movMI8(try e.stackAt(k, l.value_tag), @intCast(l.tag_double));
        } else {
            try e.s.movMR(try e.stackAt(k, l.value_payload), e.place(k));
            try e.s.movMI8(try e.stackAt(k, l.value_tag), @intCast(l.tag_int));
        }
    }

    /// Writes each slot register that the loop changes to its cell. The
    /// tag of the cell is the tag of the kind of the slot already.
    fn writeSlots(e: *Emitter) Error!void {
        return e.writeSlotsOf(true, true);
    }

    /// `writeSlots` for the integer slots, the double slots, or both.
    fn writeSlotsOf(e: *Emitter, ints: bool, doubles_: bool) Error!void {
        const l = e.l;
        const pay: i32 = @intCast(l.var_payload + l.value_payload);
        for (e.p.slots, e.regs, e.xregs) |u, r, x| {
            if (!u.written) continue;
            if (r != null and !ints) continue;
            if (x != null and !doubles_) continue;
            if (r == null and x == null) continue;
            try e.cellPtr(u.slot, .rax);
            if (r) |reg| try e.s.movMR(.{ .base = .rax, .disp = pay }, reg);
            if (x) |xr| try e.s.movsdMX(.{ .base = .rax, .disp = pay }, xr);
        }
    }

    /// Loads each slot register from its cell. With `check`, a cell that
    /// is not plain, a value of another kind, and a NaN go to `fail`.
    fn loadSlots(e: *Emitter, check: bool, fail: Label) Error!void {
        return e.loadSlotsOf(check, fail, true, true);
    }

    /// `loadSlots` for the integer slots, the double slots, or both.
    fn loadSlotsOf(e: *Emitter, check: bool, fail: Label, ints: bool, doubles_: bool) Error!void {
        const s = e.s;
        const l = e.l;
        const pay: i32 = @intCast(l.var_payload + l.value_payload);
        for (e.p.slots, e.regs, e.xregs) |u, r, x| {
            if (r == null and x == null) continue;
            if (r != null and !ints) continue;
            if (x != null and !doubles_) continue;
            try e.cellPtr(u.slot, .rax);
            if (check) {
                // The slot entry itself must be a plain cell: a link fails.
                try s.cmpMI8(.{ .base = .rax, .disp = @intCast(l.var_tag) }, @intCast(l.var_val));
                try s.jcc(.ne, fail);
                try s.cmpMI8(.{ .base = .rax, .disp = @intCast(l.var_payload + l.value_tag) }, @intCast(if (r != null) l.tag_int else l.tag_double));
                try s.jcc(.ne, fail);
            }
            if (r) |reg| try s.movRM(reg, .{ .base = .rax, .disp = pay });
            if (x) |xr| {
                try s.movsdXM(xr, .{ .base = .rax, .disp = pay });
                if (check) {
                    try s.ucomisd(xr, xr);
                    try s.jcc(.p, fail);
                }
            }
        }
    }

    /// Loads the cell of `slot` into `r`, from the frame.
    fn cellPtr(e: *Emitter, slot: u32, r: Reg) Error!void {
        try e.s.movRM(r, .{ .base = abi.frame, .disp = @intCast(e.l.frame_items) });
        try e.s.movRM(r, try x64.at(r, @as(i64, slot) * e.l.entry_size + e.l.entry_cell));
    }

    fn constReg(e: *const Emitter, is_lit: bool, index: u32) ?Reg {
        for (e.consts.items) |c| if (c.lit == is_lit and c.index == index) return c.reg;
        return null;
    }

    /// The literal integer `index` in a register: its constant register,
    /// or `dst` after a load.
    fn lit(e: *Emitter, index: u32, dst: Reg) Error!Reg {
        if (e.constReg(true, index)) |r| return r;
        try e.litInt(index, dst);
        return dst;
    }

    fn litInt(e: *Emitter, index: u32, dst: Reg) Error!void {
        try e.s.movRM(dst, .{ .base = abi.code, .disp = @intCast(e.l.code_lits) });
        try e.s.movRM(dst, try x64.at(dst, @as(i64, index) * e.l.value_size + e.l.value_payload));
    }

    fn loadConsts(e: *Emitter) Error!void {
        for (e.consts.items) |c| {
            if (c.lit) try e.litInt(c.index, c.reg) else try e.incrBy(c.index, c.reg);
        }
        for (e.xconsts.items) |c| try e.litDouble(c.index, c.reg);
    }

    /// Copies a Value from `src + src_off` to `dst + dst_off` with `rcx`.
    fn copy(e: *Emitter, dst: Reg, dst_off: i64, src: Reg, src_off: i64) Error!void {
        const s = e.s;
        try s.movRM(.rcx, try x64.at(src, src_off));
        try s.movMR(try x64.at(dst, dst_off), .rcx);
        try s.movRM(.rcx, try x64.at(src, src_off + 8));
        try s.movMR(try x64.at(dst, dst_off + 8), .rcx);
        try s.movzxRM8(.rcx, try x64.at(src, src_off + e.l.value_tag));
        try s.movMR8(try x64.at(dst, dst_off + e.l.value_tag), .rcx);
    }

    fn entry(e: *Emitter) Error!void {
        const s = e.s;
        const l = e.l;
        try e.loadSlots(true, e.head_exit);
        try s.movRM32(.rax, itAt(l.it_epoch));
        try s.aluRM32(.cmp, .rax, itAt(l.it_safe_epoch));
        try s.jcc(.ne, e.head_exit);
        try s.movRM(.rax, itAt(l.it_mem_trip));
        try s.aluRM(.cmp, .rax, itAt(l.it_mem_limit));
        try s.jcc(.ae, e.head_exit);
        try e.loadConsts();
    }

    /// True when the next instruction after `pc` is a `pop` or a
    /// `store_pop` that no jump reaches.
    fn nextIs(e: *const Emitter, pc: u32, op: vm.Op) bool {
        const nx = pc + 1;
        if (nx > e.p.back or e.targets[nx - e.p.head]) return false;
        return e.code.ins[nx].op == op;
    }

    /// Writes the result in `rax` of instruction `pc` to stack place
    /// `k`. When the next instruction stores that place to a slot in a
    /// register and pops it, and no jump reaches the next instruction,
    /// the result goes to the slot, and the next instruction has no code.
    fn result(e: *Emitter, pc: u32, k: u32) Error!void {
        if (e.nextIs(pc, .store_pop)) {
            if (e.slotReg(e.code.ins[pc + 1].a)) |r| {
                try e.s.movRR(r, .rax);
                e.skip = true;
                return;
            }
        }
        try e.s.movRR(e.place(k), .rax);
    }

    fn compareCond(op: expr.BinOp) Cond {
        return switch (op) {
            .lt => .l,
            .le => .le,
            .gt => .g,
            .ge => .ge,
            .eq => .e,
            .ne => .ne,
            else => unreachable,
        };
    }

    /// The exit of the overflow check of `op` at `pc`, or null for a
    /// compare. It comes before the operands load: the stress check uses
    /// `rax`.
    fn overflowExit(e: *Emitter, op: expr.BinOp, pc: u32) Error!?Label {
        return switch (op) {
            .add, .sub, .mul, .div, .mod => try e.guardExit(pc, e.left[pc - e.p.head]),
            else => null,
        };
    }

    /// `rax = rax op y`, with the overflow check that jumps to `over`.
    /// `/` and `%` send a divisor of 0 or -1 to `over` and round the
    /// quotient down as Tcl does. They keep `rdx` and `rsi` on the stack,
    /// because `idiv` writes `rdx`. No call is between the push and the
    /// pop.
    fn arith(e: *Emitter, op: expr.BinOp, over: ?Label, y: Reg) Error!void {
        const s = e.s;
        if (op == .div or op == .mod) {
            try s.movRR(.rcx, y);
            try s.aluRI(.cmp, .rcx, 0);
            try s.jcc(.e, over.?);
            try s.aluRI(.cmp, .rcx, -1);
            try s.jcc(.e, over.?);
            try s.push(.rdx);
            try s.push(.rsi);
            try s.cqo();
            try s.idiv(.rcx);
            // A remainder with the sign opposite to the divisor moves the
            // quotient down by one and the remainder up by the divisor.
            const done = try s.newLabel();
            try s.aluRI(.cmp, .rdx, 0);
            try s.jcc(.e, done);
            try s.movRR(.rsi, .rdx);
            try s.aluRR(.xor, .rsi, .rcx);
            try s.jcc(.ns, done);
            if (op == .div) try s.aluRI(.sub, .rax, 1) else try s.aluRR(.add, .rdx, .rcx);
            s.bind(done);
            if (op == .mod) try s.movRR(.rax, .rdx);
            try s.pop(.rsi);
            try s.pop(.rdx);
            return;
        }
        switch (op) {
            .add => try s.aluRR(.add, .rax, y),
            .sub => try s.aluRR(.sub, .rax, y),
            .mul => try s.imulRR(.rax, y),
            else => {
                try s.aluRR(.cmp, .rax, y);
                try s.setcc(compareCond(op), .rax);
                try s.movzxRR8(.rax, .rax);
                return;
            },
        }
        try s.jcc(.o, over.?);
    }

    fn incrBy(e: *Emitter, pc: u32, dst: Reg) Error!void {
        // The step is in the instruction, never in the code.
        try e.s.movRM(dst, .{ .base = abi.code, .disp = @intCast(e.l.code_ins) });
        try e.s.movsxdRM(dst, try x64.at(dst, @as(i64, pc) * e.l.ins_size + 8));
    }

    /// True when the instruction at `pc` runs inline with no call.
    fn noCall(e: *const Emitter, pc: u32) bool {
        const k = pc - e.p.head;
        return tier2.noCall(e.code.ins[pc], e.p.kinds[k], e.p.slot_kinds[k], e.p);
    }

    /// Emits the code of `pc`. True when the code falls through to the
    /// next instruction with the places of `pc` in their registers.
    fn instruction(e: *Emitter, pc: u32) Error!bool {
        const s = e.s;
        const i = e.code.ins[pc];
        const d = e.depth(pc);
        const l = e.l;
        if (!e.noCall(pc)) {
            try e.settle(pc);
        }
        if (!e.noCall(pc)) switch (i.op) {
            .lappend => return e.lappend(pc),
            .foreach_next => return e.foreachNext(pc),
            .load => return e.loadCell(pc),
            .store, .store_pop => return e.storeCell(pc),
            .incr_value, .jump_false, .jump_true, .to_bool => return e.stackIntOp(pc),
            .access => if (i.x <= 1) return e.listAccess(pc) else {
                try e.callOut(pc, tier1.Emitter.helperOf(i), true);
                return false;
            },
            else => {
                try e.callOut(pc, tier1.Emitter.helperOf(i), tier2.runsNoScript(i));
                return false;
            },
        };
        if (try e.doubles(pc)) return true;
        switch (i.op) {
            // These have no exit and write no SSE register.
            .guard, .step, .load, .push, .push_empty, .store, .store_pop => {},
            else => try e.settle(pc),
        }
        switch (i.op) {
            .guard, .step, .pop => {},
            .push_empty => {
                try s.movRM(.rax, ctxSlot());
                try s.movRM(.rax, .{ .base = .rax, .disp = @offsetOf(jit.EnterCtx, "empty") });
                try e.copy(abi.stack, @as(i64, d) * l.value_size, .rax, 0);
            },
            .jump => {
                if (pc == e.p.back and e.p.calls) {
                    // A loop with calls counts its passes for `tier_up`.
                    try s.movRM(.rax, ctxSlot());
                    try s.movRM(.rax, .{ .base = .rax, .disp = @offsetOf(jit.EnterCtx, "counters") });
                    try s.aluMI32(.add, try x64.at(.rax, (@as(i64, e.heads) + 1 + e.loop) * 4), 1);
                }
                try s.jmp(try e.target(pc, i.a));
            },
            .push => if (e.code.lits[i.a] == .int) {
                try e.litInt(i.a, e.place(d));
            } else {
                try s.movRM(.rax, .{ .base = abi.code, .disp = @intCast(l.code_lits) });
                try e.copy(abi.stack, @as(i64, d) * l.value_size, .rax, @as(i64, i.a) * l.value_size);
            },
            .load => try s.movRR(e.place(d), e.slotReg(i.a).?),
            .store, .store_pop => try s.movRR(e.slotReg(i.a).?, e.place(d - 1)),
            .to_bool => {
                const r = e.place(d - 1);
                try s.aluRI(.cmp, r, 0);
                try s.setcc(.ne, .rax);
                try s.movzxRR8(r, .rax);
            },
            .jump_false, .jump_true => {
                try s.aluRI(.cmp, e.place(d - 1), 0);
                try s.jcc(if (i.op == .jump_false) .e else .ne, try e.target(pc, i.a));
            },
            .jf_vv, .jf_vi => {
                const y = if (i.op == .jf_vv) e.slotReg(i.b).? else try e.lit(i.b, .rcx);
                try s.aluRR(.cmp, e.slotReg(i.a).?, y);
                const c = compareCond(@enumFromInt(i.x));
                try s.jcc(@enumFromInt(@intFromEnum(c) ^ 1), try e.target(pc, i.c));
            },
            .incr, .incr_drop, .incr_value => {
                const r = e.slotReg(i.a).?;
                const over = try e.guardExit(pc, e.left[pc - e.p.head]);
                try s.movRR(.rax, r);
                const by = if (i.op == .incr_value) e.place(d - 1) else e.constReg(false, pc) orelse blk: {
                    try e.incrBy(pc, .rcx);
                    break :blk Reg.rcx;
                };
                try s.aluRR(.add, .rax, by);
                try s.jcc(.o, over);
                try s.movRR(r, .rax);
                switch (i.op) {
                    .incr => try s.movRR(e.place(d), .rax),
                    .incr_value => try s.movRR(e.place(d - 1), .rax),
                    else => {},
                }
            },
            .bin_vv, .bin_vi => {
                const y = if (i.op == .bin_vv) e.slotReg(i.b).? else try e.lit(i.b, .rcx);
                const over = try e.overflowExit(@enumFromInt(i.x), pc);
                try s.movRR(.rax, e.slotReg(i.a).?);
                try e.arith(@enumFromInt(i.x), over, y);
                try e.result(pc, d);
            },
            .binary => {
                const over = try e.overflowExit(@enumFromInt(i.x), pc);
                try s.movRR(.rax, e.place(d - 2));
                try e.arith(@enumFromInt(i.x), over, e.place(d - 1));
                try e.result(pc, d - 2);
            },
            else => unreachable,
        }
        return true;
    }

    // ---- Doubles ----

    fn ucond(op: expr.BinOp) Cond {
        return switch (op) {
            .lt => .b,
            .le => .be,
            .gt => .a,
            .ge => .ae,
            .eq => .e,
            .ne => .ne,
            else => unreachable,
        };
    }

    /// The operand of slot `slot`.
    fn slotOperand(e: *const Emitter, slot: u32) Operand {
        if (e.slotX(slot)) |x| return .{ .loc = .{ .x = x } };
        return .{ .loc = .{ .g = e.slotReg(slot).? }, .finite = true };
    }

    /// The operand of stack place `k` before `pc`.
    fn placeOperand(e: *const Emitter, pc: u32, k: u32) Operand {
        if (e.kindAt(pc, k) == .int) return .{ .loc = .{ .g = e.place(k) }, .finite = true };
        const v = e.known[k - e.base];
        return .{
            .loc = .{ .x = e.xloc(k) },
            .finite = v != null and std.math.isFinite(v.?),
            .nonzero = v != null and std.math.isFinite(v.?) and v.? != 0,
        };
    }

    /// The operand in an SSE register: an integer goes to `scratch`.
    fn inX(e: *Emitter, o: Operand, scratch: Xmm) Error!Xmm {
        switch (o.loc) {
            .x => |x| return x,
            .g => |r| try e.s.cvtsi2sd(scratch, r),
            .lit => |index| try e.s.cvtsi2sd(scratch, try e.lit(index, .rcx)),
        }
        return scratch;
    }

    fn isDouble(o: Operand) bool {
        return o.loc == .x;
    }

    /// The code of `pc` when it works on doubles. False for each other
    /// instruction. A double place that `load` and `push` make is the
    /// register of its slot or constant until an instruction needs it in
    /// its own register.
    fn doubles(e: *Emitter, pc: u32) Error!bool {
        const s = e.s;
        const i = e.code.ins[pc];
        const d = e.depth(pc);
        switch (i.op) {
            .pop => {
                e.alias[d - 1 - e.base] = null;
                e.known[d - 1 - e.base] = null;
                return true;
            },
            .load => {
                const x = e.slotX(i.a) orelse return false;
                e.alias[d - e.base] = x;
                e.known[d - e.base] = null;
                return true;
            },
            .push => {
                if (e.code.lits[i.a] != .double) return false;
                if (e.xconstReg(i.a)) |x| {
                    e.alias[d - e.base] = x;
                } else {
                    e.alias[d - e.base] = null;
                    try e.litDouble(i.a, e.xplace(d));
                }
                e.known[d - e.base] = e.code.lits[i.a].double;
                return true;
            },
            .store, .store_pop => {
                const x = e.slotX(i.a) orelse return false;
                try e.settleReg(pc, d - 1, x);
                const v = e.xloc(d - 1);
                if (v != x) try s.movapd(x, v);
                if (i.op == .store_pop) {
                    e.alias[d - 1 - e.base] = null;
                    e.known[d - 1 - e.base] = null;
                }
                return true;
            },
            .bin_vv, .bin_vi, .binary => {
                const a, const b, const k = switch (i.op) {
                    .bin_vv => .{ e.slotOperand(i.a), e.slotOperand(i.b), d },
                    .bin_vi => .{ e.slotOperand(i.a), Operand{ .loc = .{ .lit = i.b }, .finite = true, .nonzero = e.code.lits[i.b].int != 0 }, d },
                    else => .{ e.placeOperand(pc, d - 2), e.placeOperand(pc, d - 1), d - 2 },
                };
                if (!isDouble(a) and !isDouble(b)) return false;
                const op: expr.BinOp = @enumFromInt(i.x);
                if (op == .lt or op == .le or op == .gt or op == .ge or op == .eq or op == .ne) {
                    try e.settleBelow(pc, k);
                    const ax = try e.inX(a, .xmm4);
                    const bx = try e.inX(b, .xmm5);
                    try s.ucomisd(ax, bx);
                    try s.setcc(ucond(op), .rax);
                    try s.movzxRR8(.rax, .rax);
                    if (i.op == .binary) {
                        e.alias[d - 1 - e.base] = null;
                        e.known[d - 1 - e.base] = null;
                    }
                    e.alias[k - e.base] = null;
                    e.known[k - e.base] = null;
                    try e.result(pc, k);
                    return true;
                }
                try e.arithDouble(pc, op, a, b, k);
                return true;
            },
            .jf_vv, .jf_vi => {
                const a = e.slotOperand(i.a);
                const b = if (i.op == .jf_vv) e.slotOperand(i.b) else Operand{ .loc = .{ .lit = i.b }, .finite = true };
                if (!isDouble(a) and !isDouble(b)) return false;
                try e.settle(pc);
                const ax = try e.inX(a, .xmm4);
                const bx = try e.inX(b, .xmm5);
                try s.ucomisd(ax, bx);
                try s.jcc(@enumFromInt(@intFromEnum(ucond(@enumFromInt(i.x))) ^ 1), try e.target(pc, i.c));
                return true;
            },
            else => return false,
        }
    }

    /// `+`, `-`, `*`, or `/` of two operands at least one of which is a
    /// double, with the result in place `k`. When the next instruction
    /// stores the result to a slot and pops it, the result goes to the
    /// register of the slot.
    fn arithDouble(e: *Emitter, pc: u32, op: expr.BinOp, a: Operand, b: Operand, k: u32) Error!void {
        const s = e.s;
        const i = e.code.ins[pc];
        // A result with a finite operand of `+` or `-`, or with a literal
        // operand that is finite and not zero of `*` or `/`, is never a
        // NaN: no operand in a register is a NaN.
        const safe = lower.nanFree(op, .{ .finite = a.finite, .nonzero = a.nonzero }, .{ .finite = b.finite, .nonzero = b.nonzero });
        var dest = e.xplace(k);
        var resume_pc = pc + 1;
        var fused = false;
        if (e.nextIs(pc, .store_pop)) {
            if (e.slotX(e.code.ins[pc + 1].a)) |x| {
                dest = x;
                resume_pc = pc + 2;
                fused = true;
            }
        }
        // The places below the operands keep their values. A NaN check
        // exits after the instruction, so they go to their registers.
        if (!safe) try e.settleBelow(pc, k) else try e.settleReg(pc, k, dest);
        const ax = try e.inX(a, .xmm4);
        const bx = try e.inX(b, .xmm5);
        const o: Asm.Sse = switch (op) {
            .add => .addsd,
            .sub => .subsd,
            .mul => .mulsd,
            .div => .divsd,
            else => unreachable,
        };
        if (ax == dest) {
            try s.sse(o, dest, bx);
        } else if (bx == dest) {
            if (op == .add or op == .mul) {
                try s.sse(o, dest, ax);
            } else {
                if (ax != .xmm4) try s.movapd(.xmm4, ax);
                try s.sse(o, .xmm4, bx);
                try s.movapd(dest, .xmm4);
            }
        } else {
            try s.movapd(dest, ax);
            try s.sse(o, dest, bx);
        }
        if (i.op == .binary) {
            e.alias[k + 1 - e.base] = null;
            e.known[k + 1 - e.base] = null;
        }
        e.alias[k - e.base] = null;
        e.known[k - e.base] = null;
        if (fused) e.skip = true;
        if (!safe) {
            const refund = e.left[resume_pc - e.p.head];
            try s.ucomisd(dest, dest);
            try s.jcc(.p, try e.exitFrom(resume_pc, resume_pc, refund, exit_guard));
            if (e.stress) try e.stressCheck(try e.exitFrom(resume_pc, resume_pc, refund, exit_forced));
        }
    }

    // ---- Calls ----

    /// Writes each slot register that the loop changes to its cell, and
    /// each stack place in a register before `pc` to the value stack.
    fn sync(e: *Emitter, pc: u32) Error!void {
        try e.writeSlots();
        var k = e.base;
        while (k < e.depth(pc)) : (k += 1) {
            const kind = e.kindAt(pc, k);
            if (kind == .any) continue;
            try e.writePlace(k, kind, e.xloc(k));
        }
    }

    /// The error stub of `pc`: the state is the state of tier 1, so the
    /// stub writes the address and the depth and returns status 1.
    fn stub(e: *Emitter, pc: u32) Error!Label {
        const k = pc - e.p.head;
        if (e.stubs[k]) |lb| return lb;
        const lb = try e.s.newLabel();
        e.stubs[k] = lb;
        return lb;
    }

    /// The call of helper `h` for instruction `pc`, with the state of
    /// tier 1. The code after it loads the registers again for each
    /// successor. `fall` is true when the code of `pc + 1` follows.
    fn call(e: *Emitter, pc: u32, h: Helper, pure: bool, fall: bool) Error!void {
        const s = e.s;
        const i = e.code.ins[pc];
        // A helper that runs no script changes no cell. The integer slot
        // registers and the constant registers stay on the native stack
        // across its call, and its error stub writes the slots.
        var keep: [slot_regs.len + extra_regs.len]Reg = undefined;
        var nkeep: usize = 0;
        if (pure) {
            for (e.regs) |r| if (r) |reg| {
                keep[nkeep] = reg;
                nkeep += 1;
            };
            for (e.consts.items) |c| {
                keep[nkeep] = c.reg;
                nkeep += 1;
            }
        }
        const pad = nkeep % 2 == 1;
        if (pure) try e.syncKept(pc) else try e.sync(pc);
        for (keep[0..nkeep]) |r| try s.push(r);
        // The stack pointer stays 16-byte aligned at the call.
        if (pad) try s.aluRI(.sub, .rsp, 8);
        if (e.r12_used) {
            try s.movRM(abi.helpers, ctxSlot());
            try s.movRM(abi.helpers, .{ .base = abi.helpers, .disp = @offsetOf(jit.EnterCtx, "helpers") });
        }
        if (i.op == .invoke) {
            // The checks of `Interp.resolve` on the site, as in tier 1. A
            // valid site calls `call_direct`, and a miss calls `invoke`.
            const l = e.l;
            const miss = try s.newLabel();
            const called = try s.newLabel();
            try s.movRM(.rax, .{ .base = abi.code, .disp = @intCast(l.code_sites) });
            try s.movRM(.rax, try x64.at(.rax, @as(i64, i.a) * 8));
            try s.aluMI(.cmp, try x64.at(.rax, l.cmd_resolved), 0);
            try s.jcc(.e, miss);
            try s.movRM32(.rcx, try x64.at(.rax, l.cmd_epoch));
            try s.aluRM32(.cmp, .rcx, itAt(l.it_epoch));
            try s.jcc(.ne, miss);
            try s.movRM(.rcx, try x64.at(.rax, l.cmd_ns));
            try s.aluRM(.cmp, .rcx, itAt(l.it_ns));
            try s.jcc(.ne, miss);
            try e.helperCall(pc, .call_direct);
            try s.jmp(called);
            s.bind(miss);
            try e.helperCall(pc, .invoke);
            s.bind(called);
        } else try e.helperCall(pc, h);
        try s.aluRI32(.cmp, abi.ret, helpers.yes);
        // `add` changes the flags, so the pad goes with `lea`.
        if (pad) try s.lea(.rsp, .{ .base = .rsp, .disp = 8 });
        var k = nkeep;
        while (k > 0) {
            k -= 1;
            try s.pop(keep[k]);
        }
        try s.jcc(.a, if (pure) try e.keptStub(pc) else try e.stub(pc));
        if (lower.branchTarget(i)) |tt| {
            // Result 1 goes to the target.
            const not_taken = try s.newLabel();
            try s.jcc(.ne, not_taken);
            try e.after(pc, tt, pure, false);
            s.bind(not_taken);
        }
        try e.after(pc, pc + 1, pure, fall);
    }

    fn helperCall(e: *Emitter, pc: u32, h: Helper) Error!void {
        const s = e.s;
        try s.movRM(abi.arg0, ctxSlot());
        try s.movRI32(abi.arg1, @intCast(pc));
        try s.movRI32(abi.arg2, @intCast(e.depth(pc)));
        try s.callM(try x64.at(abi.helpers, 8 * @as(i64, @intFromEnum(h))));
    }

    /// `sync` for a call that keeps the integer slot registers: the
    /// double slots and the stack places.
    fn syncKept(e: *Emitter, pc: u32) Error!void {
        try e.writeSlotsOf(false, true);
        var k = e.base;
        while (k < e.depth(pc)) : (k += 1) {
            const kind = e.kindAt(pc, k);
            if (kind == .any) continue;
            try e.writePlace(k, kind, e.xloc(k));
        }
    }

    /// The error stub of a call that kept the integer slot registers: it
    /// writes them, then goes to the error stub.
    fn keptStub(e: *Emitter, pc: u32) Error!Label {
        const lb = try e.s.newLabel();
        try e.kept.append(e.a, .{ .at = lb, .pc = pc, .to = pc });
        return lb;
    }

    /// A call out of the loop at `pc` in the order of the code.
    fn callOut(e: *Emitter, pc: u32, h: Helper, pure: bool) Error!void {
        try e.call(pc, h, pure, true);
    }

    /// The code after a call at `pc` for the successor `next`: the
    /// checks, the loads of the registers, and a jump to `next`. A
    /// successor outside the loop is an exit with no value to write.
    fn after(e: *Emitter, pc: u32, next: u32, pure: bool, fall: bool) Error!void {
        const s = e.s;
        const l = e.l;
        if (!e.inLoop(next)) {
            try s.jmp(try e.syncedKept(next, 0, pure));
            return;
        }
        if (!pure) {
            const changed = try e.syncedKept(next, exit_guard, pure);
            try s.movRM32(.rax, itAt(l.it_epoch));
            try s.aluRM32(.cmp, .rax, itAt(l.it_safe_epoch));
            try s.jcc(.ne, changed);
        }
        if (e.stress) try e.stressCheck(try e.syncedKept(next, exit_forced, pure));
        try s.movRM(.rax, itAt(l.it_mem_trip));
        try s.aluRM(.cmp, .rax, itAt(l.it_mem_limit));
        try s.jcc(.ae, try e.syncedKept(next, 0, pure));
        const fail = try e.syncedKept(next, exit_guard, pure);
        try e.loadSlotsOf(!pure, fail, !pure, true);
        // The places that the call wrote get a check of their tag. The
        // places below them have the values that `sync` wrote.
        const ef = verify.effectAt(e.code, pc).?;
        const first = e.depth(pc) - ef.need;
        var k = e.base;
        while (k < e.depth(next)) : (k += 1) {
            const kind = e.kindAt(next, k);
            if (kind == .any) continue;
            if (k >= first) {
                try s.cmpMI8(try e.stackAt(k, l.value_tag), @intCast(if (kind == .int) l.tag_int else l.tag_double));
                try s.jcc(.ne, fail);
            }
            if (kind == .int) {
                try s.movRM(e.place(k), try e.stackAt(k, l.value_payload));
            } else {
                try s.movsdXM(e.xplace(k), try e.stackAt(k, l.value_payload));
                if (k >= first) {
                    try s.ucomisd(e.xplace(k), e.xplace(k));
                    try s.jcc(.p, fail);
                }
            }
        }
        if (pure) {
            for (e.xconsts.items) |c| try e.litDouble(c.index, c.reg);
        } else try e.loadConsts();
        if (!fall or next != pc + 1) try s.jmp(e.labels[next - e.p.head]);
    }

    /// Jumps to the slow path of `pc` on condition `c`.
    fn slow(e: *Emitter, pc: u32, saved: ?Reg) Error!Label {
        const lb = try e.s.newLabel();
        try e.slows.append(e.a, .{ .at = lb, .pc = pc, .saved = saved });
        return lb;
    }

    /// A register that holds no value at `pc`, or null.
    fn freeReg(e: *const Emitter, pc: u32) ?Reg {
        const used = e.depth(pc) - e.base;
        for (e.stack_regs[@min(used, e.stack_regs.len)..]) |r| {
            if (r == abi.helpers) continue;
            if (e.constUses(r)) continue;
            return r;
        }
        var all: [slot_regs.len + extra_regs.len]Reg = undefined;
        var n: usize = 0;
        for (slot_regs) |r| {
            all[n] = r;
            n += 1;
        }
        for (extra_regs[0..2]) |r| {
            all[n] = r;
            n += 1;
        }
        outer: for (all[0..n]) |r| {
            for (e.regs) |x| if (x == r) continue :outer;
            for (e.stack_regs) |x| if (x == r) continue :outer;
            if (e.constUses(r)) continue;
            return r;
        }
        return null;
    }

    fn constUses(e: *const Emitter, r: Reg) bool {
        for (e.consts.items) |c| if (c.reg == r) return true;
        return false;
    }

    /// `dst = src * value_size` with additions. `dst` and `src` differ.
    fn scale(e: *Emitter, dst: Reg, src: Reg) Error!void {
        const s = e.s;
        const n = e.l.value_size;
        try s.movRR(dst, src);
        var bit: u5 = 31 - @as(u5, @intCast(@clz(n)));
        while (bit > 0) {
            bit -= 1;
            try s.aluRR(.add, dst, dst);
            if ((n >> bit) & 1 != 0) try s.aluRR(.add, dst, src);
        }
    }

    /// `lappend` of one value to the list of a plain cell with room at
    /// its end. Each check comes before the first write. The slow path
    /// is a call of the helper.
    fn lappend(e: *Emitter, pc: u32) Error!bool {
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const d = e.depth(pc);
        if (e.slotReg(i.a) != null) {
            try e.callOut(pc, .lappend, false);
            return false;
        }
        // Three scratch registers: `rax`, `rcx`, and one more.
        const t, const saved = if (e.freeReg(pc)) |r| .{ r, false } else .{ Reg.rsi, true };
        if (saved) try s.push(t);
        const slow_l = try e.slow(pc, if (saved) t else null);
        try e.cellPtr(i.a, .rax);
        try s.cmpMI8(.{ .base = .rax, .disp = @intCast(l.var_tag) }, @intCast(l.var_val));
        try s.jcc(.ne, slow_l);
        try s.cmpMI8(.{ .base = .rax, .disp = @intCast(l.var_payload + l.value_tag) }, @intCast(l.tag_list));
        try s.jcc(.ne, slow_l);
        try s.movRM(t, .{ .base = .rax, .disp = @intCast(l.var_payload + l.value_len) });
        try s.movRM(.rcx, .{ .base = .rax, .disp = @intCast(l.var_payload + l.value_payload) });
        try s.aluRM(.cmp, t, try x64.at(.rcx, l.obj_used));
        try s.jcc(.ne, slow_l);
        try s.aluRM(.cmp, t, try x64.at(.rcx, l.obj_buf_len));
        try s.jcc(.ae, slow_l);
        // Each check passed. The value goes to the buffer, then `used`
        // and the length grow.
        try s.incM(try x64.at(.rcx, l.obj_used));
        try s.incM(.{ .base = .rax, .disp = @intCast(l.var_payload + l.value_len) });
        try e.scale(.rax, t);
        try s.aluRM(.add, .rax, try x64.at(.rcx, l.obj_buf));
        if (e.kindAt(pc, d - 1) == .int) {
            try s.movMR(try x64.at(.rax, l.value_payload), e.place(d - 1));
            try s.movMI(try x64.at(.rax, l.value_len), 0);
            try s.movMI8(try x64.at(.rax, l.value_tag), @intCast(l.tag_int));
        } else if (e.kindAt(pc, d - 1) == .double) {
            try s.movsdMX(try x64.at(.rax, l.value_payload), e.xplace(d - 1));
            try s.movMI(try x64.at(.rax, l.value_len), 0);
            try s.movMI8(try x64.at(.rax, l.value_tag), @intCast(l.tag_double));
        } else {
            try e.copy(.rax, 0, abi.stack, @as(i64, d - 1) * l.value_size);
        }
        if (saved) try s.pop(t);
        // The result is the list. The next `pop` drops it.
        if (e.nextIs(pc, .pop)) return true;
        try e.cellPtr(i.a, .rax);
        try e.copy(abi.stack, @as(i64, d - 1) * l.value_size, .rax, l.var_payload);
        return true;
    }

    /// `foreach_next` with the list and the index below the loop places
    /// and only slots of the kind `int`. The bound check, the tag check
    /// of each item, and the step check come before the first store, as
    /// in the interpreter. A failed tag check is an exit before the
    /// step.
    fn foreachNext(e: *Emitter, pc: u32) Error!bool {
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const table = e.code.tables[i.a];
        const d = e.depth(pc);
        var ok = table.len <= 4 and d >= 2 and d == e.base;
        for (table) |slot| {
            if (e.slotReg(slot) == null) ok = false;
        }
        if (!ok) {
            try e.callOut(pc, .foreach_next, false);
            return false;
        }
        const slow_l = try e.slow(pc, null);
        const list = d - 2;
        const idx = d - 1;
        // The stress check uses `rax`, so the exit comes first.
        const fail = try e.guardExit(pc, e.left[pc - e.p.head]);
        try s.cmpMI8(try e.stackAt(list, l.value_tag), @intCast(l.tag_list));
        try s.jcc(.ne, slow_l);
        try s.cmpMI8(try e.stackAt(idx, l.value_tag), @intCast(l.tag_int));
        try s.jcc(.ne, slow_l);
        try s.movRM(.rcx, try e.stackAt(idx, l.value_payload));
        try s.aluRM(.cmp, .rcx, try e.stackAt(list, l.value_len));
        try s.jcc(.ae, try e.target(pc, i.b));
        for (table, 0..) |_, k| {
            if (k > 0) {
                try s.movRM(.rcx, try e.stackAt(idx, l.value_payload));
                try s.aluRI(.add, .rcx, @intCast(k));
                // An item past the end is the empty string: no integer.
                try s.aluRM(.cmp, .rcx, try e.stackAt(list, l.value_len));
                try s.jcc(.ae, fail);
            }
            try e.scale(.rax, .rcx);
            try s.movRM(.rcx, try e.stackAt(list, l.value_payload));
            try s.aluRM(.add, .rax, try x64.at(.rcx, l.obj_buf));
            try s.cmpMI8(try x64.at(.rax, l.value_tag), @intCast(l.tag_int));
            try s.jcc(.ne, fail);
        }
        // The step of `foreach_next`. No code since the last memory check
        // allocates, so the memory check of the step passes.
        try s.aluMI(.cmp, itAt(l.it_step_limit), 0);
        try s.jcc(.e, slow_l);
        try s.decM(itAt(l.it_step_limit));
        var k: usize = table.len;
        while (k > 0) {
            k -= 1;
            if (k + 1 < table.len) {
                try s.movRM(.rcx, try e.stackAt(idx, l.value_payload));
                if (k > 0) try s.aluRI(.add, .rcx, @intCast(k));
                try e.scale(.rax, .rcx);
                try s.movRM(.rcx, try e.stackAt(list, l.value_payload));
                try s.aluRM(.add, .rax, try x64.at(.rcx, l.obj_buf));
            }
            try s.movRM(e.slotReg(table[k]).?, try x64.at(.rax, l.value_payload));
        }
        try s.aluMI(.add, try e.stackAt(idx, l.value_payload), @intCast(table.len));
        return true;
    }

    /// `incr_value`, `jump_false`, `jump_true`, and `to_bool` on a value
    /// in the value stack: an integer has the inline path of tier 1, and
    /// each other value goes to the helper.
    fn stackIntOp(e: *Emitter, pc: u32) Error!bool {
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const d = e.depth(pc);
        const reg = if (i.op == .incr_value) e.slotReg(i.a) else null;
        if (e.kindAt(pc, d - 1) != .any or (i.op == .incr_value and reg == null)) {
            try e.callOut(pc, tier1.Emitter.helperOf(i), tier2.runsNoScript(i));
            return false;
        }
        const slow_l = try e.slow(pc, null);
        try s.cmpMI8(try e.stackAt(d - 1, l.value_tag), @intCast(l.tag_int));
        try s.jcc(.ne, slow_l);
        switch (i.op) {
            .incr_value => {
                try s.movRR(.rax, reg.?);
                try s.aluRM(.add, .rax, try e.stackAt(d - 1, l.value_payload));
                try s.jcc(.o, slow_l);
                try s.movRR(reg.?, .rax);
                try s.movMR(try e.stackAt(d - 1, l.value_payload), .rax);
            },
            .to_bool => {
                // The result has the kind `int`, so it goes to the
                // register of the place.
                const r = e.place(d - 1);
                try s.aluMI(.cmp, try e.stackAt(d - 1, l.value_payload), 0);
                try s.setcc(.ne, .rax);
                try s.movzxRR8(r, .rax);
            },
            else => {
                try s.aluMI(.cmp, try e.stackAt(d - 1, l.value_payload), 0);
                try s.jcc(if (i.op == .jump_false) .e else .ne, try e.target(pc, i.a));
            },
        }
        return true;
    }

    /// `llength` and `lindex` of a list value in the value stack, as in
    /// tier 1: the length, or the item, or the empty string for an index
    /// out of range. Each other value goes to the helper.
    fn listAccess(e: *Emitter, pc: u32) Error!bool {
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const d = e.depth(pc);
        const list = if (i.x == 0) d - 1 else d - 2;
        if (e.kindAt(pc, list) != .any or (i.x == 0 and e.kindAt(pc + 1, d - 1) != .int)) {
            try e.callOut(pc, tier1.Emitter.helperOf(i), true);
            return false;
        }
        const slow_l = try e.slow(pc, null);
        try s.cmpMI8(try e.stackAt(list, l.value_tag), @intCast(l.tag_list));
        try s.jcc(.ne, slow_l);
        if (i.x == 0) {
            // The plan gives the length the kind `int`.
            try s.movRM(e.place(d - 1), try e.stackAt(list, l.value_len));
            return true;
        }
        switch (e.kindAt(pc, d - 1)) {
            .int => try s.movRR(.rcx, e.place(d - 1)),
            .any => {
                try s.cmpMI8(try e.stackAt(d - 1, l.value_tag), @intCast(l.tag_int));
                try s.jcc(.ne, slow_l);
                try s.movRM(.rcx, try e.stackAt(d - 1, l.value_payload));
            },
            .double => {
                try e.callOut(pc, .lindex, true);
                return false;
            },
        }
        // An unsigned compare: a negative index is out of range.
        const empty = try s.newLabel();
        const have = try s.newLabel();
        try s.aluRM(.cmp, .rcx, try e.stackAt(list, l.value_len));
        try s.jcc(.ae, empty);
        try e.scale(.rax, .rcx);
        try s.movRM(.rcx, try e.stackAt(list, l.value_payload));
        try s.aluRM(.add, .rax, try x64.at(.rcx, l.obj_buf));
        try s.jmp(have);
        s.bind(empty);
        try s.movRM(.rax, ctxSlot());
        try s.movRM(.rax, .{ .base = .rax, .disp = @offsetOf(jit.EnterCtx, "empty") });
        s.bind(have);
        try e.copy(abi.stack, @as(i64, list) * l.value_size, .rax, 0);
        return true;
    }

    /// `load` of a slot that stays in its cell: a copy of a plain cell,
    /// or the helper.
    fn loadCell(e: *Emitter, pc: u32) Error!bool {
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const slow_l = try e.slow(pc, null);
        try e.cellPtr(i.a, .rax);
        try s.cmpMI8(.{ .base = .rax, .disp = @intCast(l.var_tag) }, @intCast(l.var_val));
        try s.jcc(.ne, slow_l);
        try e.copy(abi.stack, @as(i64, e.depth(pc)) * l.value_size, .rax, l.var_payload);
        return true;
    }

    /// `store` of a place in the value stack to a slot that stays in its
    /// cell: a copy to a plain cell, or the helper.
    fn storeCell(e: *Emitter, pc: u32) Error!bool {
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const d = e.depth(pc);
        if (e.slotReg(i.a) != null or e.kindAt(pc, d - 1) != .any) {
            try e.callOut(pc, tier1.Emitter.helperOf(i), false);
            return false;
        }
        const slow_l = try e.slow(pc, null);
        try e.cellPtr(i.a, .rax);
        try s.cmpMI8(.{ .base = .rax, .disp = @intCast(l.var_tag) }, @intCast(l.var_val));
        try s.jcc(.ne, slow_l);
        try e.copy(.rax, l.var_payload, abi.stack, @as(i64, d - 1) * l.value_size);
        return true;
    }

    fn emitSlows(e: *Emitter) Error!void {
        var k: usize = 0;
        while (k < e.slows.items.len) : (k += 1) {
            const x = e.slows.items[k];
            e.s.bind(x.at);
            if (x.saved) |r| try e.s.pop(r);
            const i = e.code.ins[x.pc];
            try e.call(x.pc, tier1.Emitter.helperOf(i), tier2.runsNoScript(i), false);
        }
    }

    fn emitFixes(e: *Emitter) Error!void {
        for (e.fixes.items) |x| {
            e.s.bind(x.at);
            try e.fix(x.pc, x.to);
            try e.s.jmp(e.labels[x.to - e.p.head]);
        }
    }

    fn emitStubs(e: *Emitter) Error!void {
        const s = e.s;
        for (e.kept.items) |x| {
            s.bind(x.at);
            try e.writeSlotsOf(true, false);
            try s.jmp(try e.stub(x.pc));
        }
        for (e.stubs, 0..) |maybe, k| {
            const lb = maybe orelse continue;
            const pc: u32 = @intCast(e.p.head + k);
            s.bind(lb);
            try s.movRM(.rcx, ctxSlot());
            try s.movMI32(.{ .base = .rcx, .disp = @offsetOf(jit.EnterCtx, "pc") }, @intCast(pc));
            try s.movMI32(.{ .base = .rcx, .disp = @offsetOf(jit.EnterCtx, "sp") }, @intCast(e.depth(pc)));
            try s.movRI32(.rax, tier1.status_error);
            try s.jmp(e.epilogue);
        }
    }

    fn emitExits(e: *Emitter) Error!void {
        const s = e.s;
        const l = e.l;
        for (e.exits.items) |x| {
            s.bind(x.at);
            if (x.kept) try e.writeSlotsOf(true, false);
            if (!x.synced) {
                const d = e.depth(x.pc);
                var k = e.base;
                while (k < d) : (k += 1) {
                    const kind = e.kindAt(x.from, k);
                    if (kind == .any) continue;
                    try e.writePlace(k, kind, e.xplace(k));
                }
                try e.writeSlots();
                if (x.refund > 0) try s.aluMI(.add, itAt(l.it_step_limit), @intCast(x.refund));
            }
            try s.movRI32(abi.arg1, @intCast(x.pc));
            try s.movRI32(abi.arg2, @intCast(e.depth(x.pc)));
            try s.movRI32(.rcx, @bitCast(x.kind | e.loop));
            try s.jmp(e.resume_l);
        }
        s.bind(e.head_exit);
        try s.movRI32(abi.arg1, @intCast(e.p.head));
        try s.movRI32(abi.arg2, @intCast(e.depth(e.p.head)));
        try s.movRI32(.rcx, @bitCast(exit_guard | e.loop));
        // `resume_at` gives the address of the tier 1 code of `pc`, or 0,
        // and the code returns status 2 with the frame of tier 1.
        s.bind(e.resume_l);
        try s.movRM(abi.arg0, ctxSlot());
        try s.movRM(abi.helpers, .{ .base = abi.arg0, .disp = @offsetOf(jit.EnterCtx, "helpers") });
        try s.callM(try x64.at(abi.helpers, 8 * @as(i64, @intFromEnum(Helper.resume_at))));
        try s.aluRI(.cmp, .rax, 0);
        const ret = try s.newLabel();
        try s.jcc(.e, ret);
        try s.jmpR(.rax);
        s.bind(ret);
        try s.movRI32(.rax, tier1.status_exit);
        s.bind(e.epilogue);
        try s.aluRI(.add, .rsp, 8);
        var k: usize = abi.saved.len;
        while (k > 0) {
            k -= 1;
            try s.pop(abi.saved[k]);
        }
        try s.pop(.rbp);
        try s.ret();
    }
};

/// Assembles the tier 2 code of the loop of `p`. The entry block is at
/// offset 0.
/// `loop` is the number of the loop head in the function, `heads` the
/// count of loop heads, and `stress` turns on the schedule of failed
/// guards.
pub fn assemble(a: Allocator, s: *Asm, code: *const vm.Code, info: *const verify.Info, p: *const tier2.LoopPlan, l: layout.Layout, loop: u32, heads: u32, stress: bool) Error!void {
    const n = p.back - p.head + 1;
    const labels = try a.alloc(Label, n);
    defer a.free(labels);
    for (labels) |*lb| lb.* = try s.newLabel();
    const stubs = try a.alloc(?Label, n);
    defer a.free(stubs);
    @memset(stubs, null);
    const left = try lower.stepsLeft(a, code, p);
    defer a.free(left);
    // The registers of the slots of the kind `int`.
    const slot_reg = try a.alloc(?Reg, p.slots.len);
    defer a.free(slot_reg);
    var nslot: usize = 0;
    for (p.slots, slot_reg) |u, *r| {
        r.* = null;
        if (lower.slotClass(u) != .int) continue;
        r.* = slot_regs[nslot];
        nslot += 1;
    }
    // The registers of the slots of the kind `double`.
    const slot_xreg = try a.alloc(?Xmm, p.slots.len);
    defer a.free(slot_xreg);
    var nxslot: usize = 0;
    for (p.slots, slot_xreg) |u, *r| {
        r.* = null;
        if (lower.slotClass(u) != .double) continue;
        r.* = slot_xregs[nxslot];
        nxslot += 1;
    }
    var xregs: [slot_xregs.len + extra_xregs.len]Xmm = undefined;
    var nxr: usize = 0;
    for (slot_xregs[nxslot..]) |r| {
        xregs[nxr] = r;
        nxr += 1;
    }
    for (extra_xregs) |r| {
        xregs[nxr] = r;
        nxr += 1;
    }
    var regs: [slot_regs.len + extra_regs.len]Reg = undefined;
    var nr: usize = 0;
    for (slot_regs[nslot..]) |r| {
        regs[nr] = r;
        nr += 1;
    }
    for (extra_regs) |r| {
        regs[nr] = r;
        nr += 1;
    }
    const targets = try a.alloc(bool, n);
    defer a.free(targets);
    @memset(targets, false);
    // The stack places that the loop needs. The other registers hold
    // constants.
    const base = info.depth[p.head];
    var need: usize = 0;
    for (0..n) |k| {
        const pc: u32 = @intCast(p.head + k);
        if (!p.seen[k]) continue;
        const ef = verify.effectAt(code, pc).?;
        need = @max(need, (info.depth[pc] + ef.push) -| base);
        if (tier2.targetOf(code.ins[pc])) |t| if (t >= p.head and t <= p.back) {
            targets[t - p.head] = true;
        };
    }
    const alias = try a.alloc(?Xmm, need);
    defer a.free(alias);
    @memset(alias, null);
    const known = try a.alloc(?f64, need);
    defer a.free(known);
    @memset(known, null);
    var e: Emitter = .{
        .s = s,
        .a = a,
        .code = code,
        .info = info,
        .p = p,
        .l = l,
        .labels = labels,
        .base = base,
        .regs = slot_reg,
        .stack_regs = regs[0..need],
        .xregs = slot_xreg,
        .xstack = xregs[0..need],
        .alias = alias,
        .known = known,
        .stubs = stubs,
        .left = left,
        .head_exit = try s.newLabel(),
        .resume_l = try s.newLabel(),
        .epilogue = try s.newLabel(),
        .targets = targets,
        .loop = loop,
        .heads = heads,
        .stress = stress,
    };
    defer e.exits.deinit(a);
    defer e.consts.deinit(a);
    defer e.xconsts.deinit(a);
    defer e.slows.deinit(a);
    defer e.fixes.deinit(a);
    defer e.kept.deinit(a);
    var free_at = need;
    for (0..n) |k| {
        const pc: u32 = @intCast(p.head + k);
        if (!p.seen[k]) continue;
        const i = code.ins[pc];
        if (!e.noCall(pc)) continue;
        const w: struct { bool, u32 } = switch (i.op) {
            .incr, .incr_drop => .{ false, pc },
            .bin_vi, .jf_vi => .{ true, i.b },
            else => continue,
        };
        if (e.constReg(w[0], w[1]) != null or free_at >= nr) continue;
        try e.consts.append(a, .{ .lit = w[0], .index = w[1], .reg = regs[free_at] });
        free_at += 1;
    }
    // The double literals of the loop in the free SSE registers.
    var xfree_at = need;
    for (0..n) |k| {
        const pc: u32 = @intCast(p.head + k);
        if (!p.seen[k]) continue;
        const i = code.ins[pc];
        if (i.op != .push or code.lits[i.a] != .double) continue;
        if (e.xconstReg(i.a) != null or xfree_at >= nxr) continue;
        try e.xconsts.append(a, .{ .index = i.a, .reg = xregs[xfree_at] });
        xfree_at += 1;
    }
    for (regs[0..free_at]) |r| if (r == abi.helpers) {
        e.r12_used = true;
    };
    try s.reserveFor(n, 4 * n + 8);
    try e.entry();
    var part: usize = 0;
    for (0..n) |k| {
        const pc: u32 = @intCast(p.head + k);
        while (part < p.parts.len and p.parts[part].last < pc) part += 1;
        const pt = p.parts[part];
        const check = checkAt(code, pt) == pc and pt.steps > 0;
        // A jump target and the exit of a step check see each double in
        // its own register.
        if (p.seen[k] and (targets[k] or check)) try e.settle(pc);
        if (targets[k]) @memset(e.known, null);
        s.bind(labels[k]);
        if (check) {
            try s.aluMI(.cmp, Emitter.itAt(l.it_step_limit), @intCast(pt.steps));
            try s.jcc(.b, try e.exit(pc, 0));
            try s.aluMI(.sub, Emitter.itAt(l.it_step_limit), @intCast(pt.steps));
        }
        if (!p.seen[k]) {
            try s.ud2();
            continue;
        }
        var regs_live = true;
        if (e.skip) {
            e.skip = false;
        } else regs_live = try e.instruction(pc);
        // The edge to the next instruction.
        if (regs_live and falls(code.ins[pc].op) and pc < p.back and e.needsFix(pc, pc + 1)) try e.fix(pc, pc + 1);
    }
    // The last instruction of a loop is its jump back: no fall through.
    try s.ud2();
    try e.emitFixes();
    try e.emitSlows();
    try e.emitStubs();
    try e.emitExits();
    try s.finish();
}

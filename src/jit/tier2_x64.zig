//! The code of tier 2 for x86-64: one loop of integers with the values of
//! its slots in registers.
//!
//! Tier 1 jumps to the entry block of the loop with its own frame, so the
//! code of tier 2 has no prologue. The entry block checks that each slot
//! of the plan is a plain cell with an integer, loads each integer into
//! its register, and checks the epoch and the memory count. A failed
//! check goes back to the tier 1 code of the loop head with no change.
//!
//! The value stack of the loop is virtual: stack place `k` above the
//! depth of the head is a fixed register. Each part of the plan checks
//! its steps one time at its start. Each operation writes a scratch
//! register first, and a slot register or a stack place changes only
//! after the overflow check.
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
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vm = @import("../vm.zig");
const x64 = @import("x64.zig");
const abi = @import("abi.zig");
const verify = @import("verify.zig");
const layout = @import("layout.zig");
const helpers = @import("helpers.zig");
const tier2 = @import("tier2.zig");
const tier1 = @import("tier1_x64.zig");
const expr = @import("../expr.zig");

const Allocator = std.mem.Allocator;
const Asm = x64.Asm;
const Label = x64.Label;
const Reg = x64.Reg;
const Mem = x64.Mem;
const Cond = x64.Cond;

pub const Error = Allocator.Error || error{ Range, UnboundLabel, Layout };

/// The registers of the slots, in the order of the plan.
const slot_regs = [_]Reg{ .r8, .r9, .r10, .r11, .rdx };

/// The registers of stack places: the slot registers that no slot uses,
/// then `rsi`, `rdi`, and `r12`. The code calls no helper inside the
/// loop, so each one is free there. `r12` is the pinned register of the
/// helper table: each exit loads it again from the context.
const extra_regs = [_]Reg{ .rsi, .rdi, abi.helpers };

/// True when tier 2 can compile the loop of the plan: no call, each slot
/// an integer, at most five slots, and each stack place in a register.
/// A stack place of the kind `any` comes only from `push_empty`, and no
/// instruction reads it: such a place has no value in its register. At
/// each address where the code can exit, each stack place above the
/// head is an integer, so the exit can write it.
pub fn eligible(code: *const vm.Code, info: *const verify.Info, p: *const tier2.LoopPlan) bool {
    if (p.calls or p.slots.len > slot_regs.len) return false;
    for (p.slots) |u| if (u.entry != .int) return false;
    const base = info.depth[p.head];
    const room = slot_regs.len - p.slots.len + extra_regs.len;
    var part: usize = 0;
    for (p.head..p.back + 1) |pc| {
        const k = pc - p.head;
        if (!p.seen[k]) continue;
        const i = code.ins[pc];
        const e = verify.effectAt(code, @intCast(pc)) orelse return false;
        const d = info.depth[pc];
        if (d < base + e.need) return false;
        if (d - base + e.push > room) return false;
        for (p.slot_kinds[k]) |kind| if (kind != .int) return false;
        const places = p.kinds[k][@min(base, p.kinds[k].len)..];
        const top: tier2.Kind = if (places.len > 0) places[places.len - 1] else .int;
        while (part < p.parts.len and p.parts[part].last < pc) part += 1;
        const starts = checkAt(code, p.parts[part]) == pc and p.parts[part].steps > 0;
        const exits = std.mem.indexOfScalar(u32, p.exits, @intCast(pc)) != null;
        if (starts or exits) for (places) |kind| if (kind != .int) return false;
        if (tier2.targetOf(i)) |t| if (i.op != .guard and (t < p.head or t > p.back)) {
            const keep = info.depth[t] - base;
            if (keep > places.len) return false;
            for (places[0..keep]) |kind| if (kind != .int) return false;
        };
        switch (i.op) {
            .push => if (code.lits[i.a] != .int) return false,
            .bin_vv, .bin_vi, .binary => switch (@as(expr.BinOp, @enumFromInt(i.x))) {
                .add, .sub, .mul, .lt, .le, .gt, .ge, .eq, .ne => {},
                else => return false,
            },
            .jump_false, .jump_true, .to_bool, .incr_value, .store, .store_pop => if (top != .int) return false,
            .guard, .step, .jump, .jf_vv, .jf_vi, .pop, .push_empty, .load, .incr, .incr_drop => {},
            else => return false,
        }
    }
    return true;
}

/// The address of the step check of a part: its first instruction that
/// is not a `pop`. A `pop` has no code, so the check there is the check
/// at the start of the part, and the place that the `pop` drops needs no
/// value at the exit of the check.
fn checkAt(code: *const vm.Code, part: tier2.Part) u32 {
    var pc = part.first;
    while (pc < part.last and code.ins[pc].op == .pop) pc += 1;
    return pc;
}

/// The kind of an exit, in the high bits of the fourth argument of
/// `resume_at`. The low bits are the number of the loop head.
pub const exit_guard: u32 = 1 << 30;
pub const exit_forced: u32 = 1 << 31;

const Exit = struct { at: Label, pc: u32, refund: u32, kind: u32 = 0 };

/// A constant in a register: the step of the `incr` at address `index`,
/// or the integer literal `index`.
const Const = struct { lit: bool, index: u32, reg: Reg };

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
    stack_regs: []Reg,
    exits: std.ArrayList(Exit) = .empty,
    /// The registers of the constants that the entry block loads: the
    /// step of each `incr` and each integer literal of the loop.
    consts: std.ArrayList(Const) = .empty,
    /// True for each instruction of the loop that a jump reaches.
    targets: []bool,
    /// True for the instruction after a result that went to its slot.
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

    fn itAt(off: u32) Mem {
        return .{ .base = abi.it, .disp = @intCast(off) };
    }

    fn slotReg(e: *const Emitter, slot: u32) Reg {
        return slot_regs[e.p.index(slot).?];
    }

    /// The register of stack place `k`.
    fn place(e: *const Emitter, k: u32) Reg {
        return e.stack_regs[k - e.base];
    }

    fn depth(e: *const Emitter, pc: u32) u32 {
        return e.info.depth[pc];
    }

    fn exit(e: *Emitter, pc: u32, refund: u32) Error!Label {
        const l = try e.s.newLabel();
        try e.exits.append(e.a, .{ .at = l, .pc = pc, .refund = refund });
        return l;
    }

    /// The exit of a guard that can fail at `pc`. In the stress mode, the
    /// stress counter goes down first, and at zero the guard fails.
    fn guardExit(e: *Emitter, pc: u32, refund: u32) Error!Label {
        const l = try e.s.newLabel();
        try e.exits.append(e.a, .{ .at = l, .pc = pc, .refund = refund, .kind = exit_guard });
        if (e.stress) {
            const f = try e.s.newLabel();
            try e.exits.append(e.a, .{ .at = f, .pc = pc, .refund = refund, .kind = exit_forced });
            try e.s.movRM(.rax, .{ .base = abi.fp, .disp = abi.ctx_slot });
            try e.s.movRM(.rax, .{ .base = .rax, .disp = @offsetOf(@import("../jit.zig").EnterCtx, "counters") });
            try e.s.aluMI32(.sub, try x64.at(.rax, @as(i64, e.heads) * 4), 1);
            try e.s.jcc(.e, f);
        }
        return l;
    }

    /// The label of a jump target: an instruction of the loop, or an
    /// exit to the code after it.
    fn target(e: *Emitter, t: u32) Error!Label {
        if (t >= e.p.head and t <= e.p.back) return e.labels[t - e.p.head];
        return e.exit(t, 0);
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

    fn entry(e: *Emitter) Error!void {
        const s = e.s;
        const l = e.l;
        for (e.p.slots, 0..) |u, j| {
            try e.cellPtr(u.slot, .rax);
            // The slot entry itself must be a plain cell: a link fails.
            try s.cmpMI8(.{ .base = .rax, .disp = @intCast(l.var_tag) }, @intCast(l.var_val));
            try s.jcc(.ne, e.head_exit);
            try s.cmpMI8(.{ .base = .rax, .disp = @intCast(l.var_payload + l.value_tag) }, @intCast(l.tag_int));
            try s.jcc(.ne, e.head_exit);
            try s.movRM(slot_regs[j], .{ .base = .rax, .disp = @intCast(l.var_payload + l.value_payload) });
        }
        try s.movRM32(.rax, itAt(l.it_epoch));
        try s.aluRM32(.cmp, .rax, itAt(l.it_safe_epoch));
        try s.jcc(.ne, e.head_exit);
        try s.movRM(.rax, itAt(l.it_mem_trip));
        try s.aluRM(.cmp, .rax, itAt(l.it_mem_limit));
        try s.jcc(.ae, e.head_exit);
        for (e.consts.items) |c| {
            if (c.lit) try e.litInt(c.index, c.reg) else try e.incrBy(c.index, c.reg);
        }
    }

    /// Writes the result in `rax` of instruction `pc` to stack place
    /// `k`. When the next instruction stores that place to a slot and pops
    /// it, and no jump reaches the next instruction, the result goes to
    /// the slot, and the next instruction has no code.
    fn result(e: *Emitter, pc: u32, k: u32) Error!void {
        const nx = pc + 1;
        if (nx <= e.p.back and !e.targets[nx - e.p.head]) {
            const n = e.code.ins[nx];
            if (n.op == .store_pop) {
                try e.s.movRR(e.slotReg(n.a), .rax);
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

    /// `rax = rax op y`, with the overflow check that jumps to `over`.
    /// The exit of the overflow check of `op` at `pc`, or null for a
    /// compare. It comes before the operands load: the stress check uses
    /// `rax`.
    fn overflowExit(e: *Emitter, op: expr.BinOp, pc: u32) Error!?Label {
        return switch (op) {
            .add, .sub, .mul => try e.guardExit(pc, e.left[pc - e.p.head]),
            else => null,
        };
    }

    fn arith(e: *Emitter, op: expr.BinOp, over: ?Label, y: Reg) Error!void {
        const s = e.s;
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

    fn instruction(e: *Emitter, pc: u32) Error!void {
        const s = e.s;
        const i = e.code.ins[pc];
        const d = e.depth(pc);
        switch (i.op) {
            .guard, .step, .pop, .push_empty => {},
            .jump => try s.jmp(try e.target(i.a)),
            .push => try e.litInt(i.a, e.place(d)),
            .load => try s.movRR(e.place(d), e.slotReg(i.a)),
            .store, .store_pop => try s.movRR(e.slotReg(i.a), e.place(d - 1)),
            .to_bool => {
                const r = e.place(d - 1);
                try s.aluRI(.cmp, r, 0);
                try s.setcc(.ne, .rax);
                try s.movzxRR8(r, .rax);
            },
            .jump_false, .jump_true => {
                try s.aluRI(.cmp, e.place(d - 1), 0);
                try s.jcc(if (i.op == .jump_false) .e else .ne, try e.target(i.a));
            },
            .jf_vv, .jf_vi => {
                const y = if (i.op == .jf_vv) e.slotReg(i.b) else try e.lit(i.b, .rcx);
                try s.aluRR(.cmp, e.slotReg(i.a), y);
                const c = compareCond(@enumFromInt(i.x));
                try s.jcc(@enumFromInt(@intFromEnum(c) ^ 1), try e.target(i.c));
            },
            .incr, .incr_drop, .incr_value => {
                const r = e.slotReg(i.a);
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
                const y = if (i.op == .bin_vv) e.slotReg(i.b) else try e.lit(i.b, .rcx);
                const over = try e.overflowExit(@enumFromInt(i.x), pc);
                try s.movRR(.rax, e.slotReg(i.a));
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
    }

    /// The code of `resume_at` for address `pc`: jump to tier 1, or
    /// return status 2 with the frame of tier 1.
    fn resumeAt(e: *Emitter, pc: u32, kind: u32) Error!void {
        const s = e.s;
        try s.movRM(abi.arg0, .{ .base = abi.fp, .disp = abi.ctx_slot });
        try s.movRM(abi.helpers, .{ .base = abi.arg0, .disp = @offsetOf(@import("../jit.zig").EnterCtx, "helpers") });
        try s.movRI32(abi.arg1, @intCast(pc));
        try s.movRI32(abi.arg2, @intCast(e.depth(pc)));
        try s.movRI32(.rcx, @bitCast(kind | e.loop));
        try s.callM(try x64.at(abi.helpers, 8 * @as(i64, @intFromEnum(helpers.Helper.resume_at))));
        try s.aluRI(.cmp, .rax, 0);
        const ret = try s.newLabel();
        try s.jcc(.e, ret);
        try s.jmpR(.rax);
        s.bind(ret);
        try s.movRI32(.rax, tier1.status_exit);
        try s.aluRI(.add, .rsp, 8);
        var k: usize = abi.saved.len;
        while (k > 0) {
            k -= 1;
            try s.pop(abi.saved[k]);
        }
        try s.pop(.rbp);
        try s.ret();
    }

    fn emitExits(e: *Emitter) Error!void {
        const s = e.s;
        const l = e.l;
        for (e.exits.items) |x| {
            s.bind(x.at);
            const d = e.depth(x.pc);
            var k = e.base;
            while (k < d) : (k += 1) {
                try s.movMR(try x64.at(abi.stack, @as(i64, k) * l.value_size + l.value_payload), e.place(k));
                try s.movMI8(try x64.at(abi.stack, @as(i64, k) * l.value_size + l.value_tag), @intCast(l.tag_int));
            }
            for (e.p.slots, 0..) |u, j| {
                try e.cellPtr(u.slot, .rax);
                try s.movMR(.{ .base = .rax, .disp = @intCast(l.var_payload + l.value_payload) }, slot_regs[j]);
            }
            if (x.refund > 0) try s.aluMI(.add, itAt(l.it_step_limit), @intCast(x.refund));
            try e.resumeAt(x.pc, x.kind);
        }
        s.bind(e.head_exit);
        try e.resumeAt(e.p.head, exit_guard);
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
    const left = try a.alloc(u32, n);
    defer a.free(left);
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
    var regs: [slot_regs.len + extra_regs.len]Reg = undefined;
    var nr: usize = 0;
    for (slot_regs[p.slots.len..]) |r| {
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
        need = @max(need, info.depth[pc] - base + ef.push);
        if (tier2.targetOf(code.ins[pc])) |t| if (t >= p.head and t <= p.back) {
            targets[t - p.head] = true;
        };
    }
    var e: Emitter = .{ .s = s, .a = a, .code = code, .info = info, .p = p, .l = l, .labels = labels, .base = base, .stack_regs = regs[0..need], .left = left, .head_exit = try s.newLabel(), .targets = targets, .loop = loop, .heads = heads, .stress = stress };
    defer e.exits.deinit(a);
    defer e.consts.deinit(a);
    var free_at = need;
    for (0..n) |k| {
        const pc: u32 = @intCast(p.head + k);
        if (!p.seen[k]) continue;
        const i = code.ins[pc];
        const want: ?struct { bool, u32 } = switch (i.op) {
            .incr, .incr_drop => .{ false, pc },
            .bin_vi, .jf_vi => .{ true, i.b },
            .push => .{ true, i.a },
            else => null,
        };
        const w = want orelse continue;
        if (i.op == .push) continue;
        if (e.constReg(w[0], w[1]) != null or free_at >= nr) continue;
        try e.consts.append(a, .{ .lit = w[0], .index = w[1], .reg = regs[free_at] });
        free_at += 1;
    }
    try s.reserveFor(n, 4 * n + 8);
    try e.entry();
    var part: usize = 0;
    for (0..n) |k| {
        const pc: u32 = @intCast(p.head + k);
        s.bind(labels[k]);
        while (part < p.parts.len and p.parts[part].last < pc) part += 1;
        const pt = p.parts[part];
        if (checkAt(code, pt) == pc and pt.steps > 0) {
            try s.aluMI(.cmp, Emitter.itAt(l.it_step_limit), @intCast(pt.steps));
            try s.jcc(.b, try e.exit(pc, 0));
            try s.aluMI(.sub, Emitter.itAt(l.it_step_limit), @intCast(pt.steps));
        }
        if (!p.seen[k]) {
            try s.ud2();
            continue;
        }
        if (e.skip) {
            e.skip = false;
            continue;
        }
        try e.instruction(pc);
    }
    // The last instruction of a loop is its jump back: no fall through.
    try s.ud2();
    try e.emitExits();
    try s.finish();
}

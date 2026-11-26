//! The code of tier 2 for arm64: one loop with the integers and the
//! doubles of its slots and of its stack places in registers.
//!
//! The code follows `tier2_x64.zig` part by part, and the shared facts of
//! the plan come from `tier2_lower.zig`. Tier 1 jumps to the entry block
//! of the loop with its own frame, so the code of tier 2 has no
//! prologue. The entry block checks that each slot in a register is a
//! plain cell of its kind, loads it, checks a double for a NaN with
//! `fcmp` and `b.vs`, and checks the epoch and the memory count. A
//! failed check goes back to the tier 1 code of the loop head.
//!
//! The registers follow the plan of `docs/dev/jit.md`: `x9` to `x13` for the
//! integer slots, `x3` to `x8` for the integer stack places and
//! constants, `d16` to `d19` for the double slots, and `d22` to `d31`
//! for the double places and constants. A slot register that no slot
//! uses holds a place. `x14`, `x15`, `d20`, and `d21` are scratch, and
//! `x16` and `x17` are the temporaries of the assembler and of a tag
//! byte. Each one is caller-saved, so each call out writes the values to
//! their cells and to the value stack first and loads them again after.
//! The code never uses `x18` or `d8` to `d15`.
//!
//! The integer operations write a scratch register first, and the slot
//! register changes after the check: `adds` and `subs` with `b.vs`,
//! `mul` and `smulh` for a product, and `sdiv` with `msub` for `/` and
//! `%`, which round down as Tcl does. The double operations are `fadd`,
//! `fsub`, `fmul`, `fdiv`, and `scvtf` for an integer operand, with no
//! fused multiply-add. No register holds a NaN, so the compares use the
//! conditions `mi`, `ls`, `gt`, `ge`, `eq`, and `ne` after `fcmp`. A
//! result that can be a NaN gets `fcmp` with itself and `b.vs` to an exit
//! after the instruction, with the result in its place.
//!
//! An exit writes each slot register to its cell and each stack place to
//! the value stack, gives back the steps of the part that did not run,
//! and calls `resume_at`, which gives the address of the tier 1 code of
//! the exit address. When tier 1 has no code there, the function returns
//! status 2 and `exec` runs. `jit.compileLoop` flushes the instruction
//! cache before the first run, through the region.
//!
//! No value of a script is an immediate operand. The immediates are slot
//! offsets, literal offsets, bytecode addresses, stack depths, and step
//! counts of a part, and the verifier bounds each one.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vm = @import("../vm.zig");
const a64 = @import("a64.zig");
const abi = @import("abi.zig").a64;
const verify = @import("verify.zig");
const layout = @import("layout.zig");
const helpers = @import("helpers.zig");
const tier2 = @import("tier2.zig");
const lower = @import("tier2_lower.zig");
const tier1 = @import("tier1_a64.zig");
const expr = @import("../expr.zig");
const jit = @import("../jit.zig");

const Allocator = std.mem.Allocator;
const Asm = a64.Asm;
const Label = a64.Label;
const Reg = a64.Reg;
const DReg = a64.DReg;
const Cond = a64.Cond;
const Kind = tier2.Kind;
const Helper = helpers.Helper;

pub const Error = Allocator.Error || error{ Range, Reg, UnboundLabel, Layout };

/// The registers of the slots of the kind `int`, in the order of the plan.
const slot_regs = [_]Reg{ .x9, .x10, .x11, .x12, .x13 };

/// The registers of stack places and constants: the slot registers that
/// no slot uses, then these.
const extra_regs = [_]Reg{ .x3, .x4, .x5, .x6, .x7, .x8 };

const slot_dregs = [_]DReg{ .d16, .d17, .d18, .d19 };

const extra_dregs = [_]DReg{ .d22, .d23, .d24, .d25, .d26, .d27, .d28, .d29, .d30, .d31 };

/// The scratch registers. `rax` and `rcx` name the roles of the x86-64
/// code.
const rax: Reg = .x14;
const rcx: Reg = .x15;
const t16: Reg = .x16;
const tmp: Reg = .x17;
const dx0: DReg = .d20;
const dx1: DReg = .d21;

pub fn eligible(code: *const vm.Code, info: *const verify.Info, p: *const tier2.LoopPlan) bool {
    return lower.eligible(code, info, p, lower.a64_budget);
}

const falls = lower.falls;
const checkAt = lower.checkAt;
const exit_guard = lower.exit_guard;
const exit_forced = lower.exit_forced;

const Exit = struct {
    at: Label,
    pc: u32,
    refund: u32,
    kind: u32 = 0,
    from: u32,
    synced: bool = false,
    kept: bool = false,
};

const Const = struct { lit: bool, index: u32, reg: Reg };
const DConst = struct { index: u32, reg: DReg };

const Operand = struct {
    loc: union(enum) { d: DReg, g: Reg, lit: u32 },
    finite: bool = false,
    nonzero: bool = false,
};

const Slow = struct { at: Label, pc: u32 };
const Fix = struct { at: Label, pc: u32, to: u32 };

const Emitter = struct {
    s: *Asm,
    a: Allocator,
    code: *const vm.Code,
    info: *const verify.Info,
    p: *const tier2.LoopPlan,
    l: layout.Layout,
    labels: []Label,
    base: u32,
    regs: []?Reg,
    stack_regs: []Reg,
    dregs: []?DReg,
    dstack: []DReg,
    dconsts: std.ArrayList(DConst) = .empty,
    alias: []?DReg,
    known: []?f64,
    exits: std.ArrayList(Exit) = .empty,
    slows: std.ArrayList(Slow) = .empty,
    fixes: std.ArrayList(Fix) = .empty,
    kept: std.ArrayList(Fix) = .empty,
    stubs: []?Label,
    consts: std.ArrayList(Const) = .empty,
    targets: []bool,
    skip: bool = false,
    loop: u32,
    heads: u32,
    stress: bool,
    left: []u32,
    head_exit: Label,
    resume_l: Label,
    epilogue: Label,

    // ---- Loads and stores ----

    fn ldr(e: *Emitter, t: Reg, base: Reg, off: i64) Error!void {
        try e.s.load(.x, .{ .r = t }, base, off);
    }

    fn str(e: *Emitter, t: Reg, base: Reg, off: i64) Error!void {
        try e.s.store(.x, .{ .r = t }, base, off);
    }

    fn ldrW(e: *Emitter, t: Reg, base: Reg, off: i64) Error!void {
        try e.s.load(.w, .{ .r = t }, base, off);
    }

    fn strW(e: *Emitter, t: Reg, base: Reg, off: i64) Error!void {
        try e.s.store(.w, .{ .r = t }, base, off);
    }

    fn ldrD(e: *Emitter, t: DReg, base: Reg, off: i64) Error!void {
        try e.s.load(.d, .{ .d = t }, base, off);
    }

    fn strD(e: *Emitter, t: DReg, base: Reg, off: i64) Error!void {
        try e.s.store(.d, .{ .d = t }, base, off);
    }

    /// Compares the byte at `[base + off]` with `want`, with `x17`.
    fn cmpByte(e: *Emitter, base: Reg, off: i64, want: u8) Error!void {
        try e.s.load(.b, .{ .r = tmp }, base, off);
        try e.s.cmpWI(tmp, want);
    }

    /// Writes the byte `v` to `[base + off]`, with `x17`.
    fn putByte(e: *Emitter, base: Reg, off: i64, v: u8) Error!void {
        try e.s.movzW(tmp, v);
        try e.s.store(.b, .{ .r = tmp }, base, off);
    }

    fn ctx(e: *Emitter, r: Reg) Error!void {
        try e.ldr(r, abi.fp, abi.ctx_slot);
    }

    /// Compares the word at `[base + off]` with `v`, with `x17`.
    fn cmpWord(e: *Emitter, base: Reg, off: i64, v: i64) Error!void {
        try e.ldr(tmp, base, off);
        if (v >= 0 and v < 4096) return e.s.cmpI(tmp, v);
        try e.s.movImm(t16, v);
        try e.s.cmpR(tmp, t16, .lsl, 0);
    }

    /// Adds `v` to the word at `[base + off]`, with `x17`.
    fn addWord(e: *Emitter, base: Reg, off: i64, v: i64) Error!void {
        try e.ldr(tmp, base, off);
        try e.s.addImm(tmp, tmp, v);
        try e.str(tmp, base, off);
    }

    // ---- The facts of the plan ----

    fn slotReg(e: *const Emitter, slot: u32) ?Reg {
        return e.regs[e.p.index(slot).?];
    }

    fn slotD(e: *const Emitter, slot: u32) ?DReg {
        return e.dregs[e.p.index(slot).?];
    }

    fn dplace(e: *const Emitter, k: u32) DReg {
        return e.dstack[k - e.base];
    }

    fn dloc(e: *const Emitter, k: u32) DReg {
        return e.alias[k - e.base] orelse e.dplace(k);
    }

    fn settleBelow(e: *Emitter, pc: u32, limit: u32) Error!void {
        var k = e.base;
        while (k < limit and k - e.base < e.alias.len) : (k += 1) {
            const al = e.alias[k - e.base] orelse continue;
            if (e.kindAt(pc, k) == .double) try e.s.fmovDD(e.dplace(k), al);
            e.alias[k - e.base] = null;
        }
    }

    fn settle(e: *Emitter, pc: u32) Error!void {
        try e.settleBelow(pc, e.depth(pc));
    }

    fn settleReg(e: *Emitter, pc: u32, limit: u32, r: DReg) Error!void {
        var k = e.base;
        while (k < limit) : (k += 1) {
            if (e.alias[k - e.base] != r) continue;
            if (e.kindAt(pc, k) == .double) try e.s.fmovDD(e.dplace(k), r);
            e.alias[k - e.base] = null;
        }
    }

    fn dconstReg(e: *const Emitter, index: u32) ?DReg {
        for (e.dconsts.items) |c| if (c.index == index) return c.reg;
        return null;
    }

    fn litDouble(e: *Emitter, index: u32, dst: DReg) Error!void {
        try e.ldr(rax, abi.code, e.l.code_lits);
        try e.ldrD(dst, rax, @as(i64, index) * e.l.value_size + e.l.value_payload);
    }

    fn place(e: *const Emitter, k: u32) Reg {
        return e.stack_regs[k - e.base];
    }

    fn depth(e: *const Emitter, pc: u32) u32 {
        return e.info.depth[pc];
    }

    fn kinds(e: *const Emitter, pc: u32) []const Kind {
        return e.p.kinds[pc - e.p.head];
    }

    fn kindAt(e: *const Emitter, pc: u32, k: u32) Kind {
        const ks = e.kinds(pc);
        return if (k < ks.len) ks[k] else .any;
    }

    fn inLoop(e: *const Emitter, pc: u32) bool {
        return pc >= e.p.head and pc <= e.p.back;
    }

    fn stackOff(e: *const Emitter, k: u32, off: u32) i64 {
        return @as(i64, k) * e.l.value_size + off;
    }

    // ---- Exits ----

    fn exitFrom(e: *Emitter, pc: u32, from: u32, refund: u32, kind: u32) Error!Label {
        const lb = try e.s.newLabel();
        try e.exits.append(e.a, .{ .at = lb, .pc = pc, .refund = refund, .kind = kind, .from = from });
        return lb;
    }

    fn exit(e: *Emitter, pc: u32, refund: u32) Error!Label {
        return e.exitFrom(pc, pc, refund, 0);
    }

    fn synced(e: *Emitter, pc: u32, kind: u32) Error!Label {
        const lb = try e.s.newLabel();
        try e.exits.append(e.a, .{ .at = lb, .pc = pc, .refund = 0, .kind = kind, .from = pc, .synced = true });
        return lb;
    }

    fn syncedKept(e: *Emitter, pc: u32, kind: u32, kept: bool) Error!Label {
        const lb = try e.synced(pc, kind);
        e.exits.items[e.exits.items.len - 1].kept = kept;
        return lb;
    }

    /// The stress check: the stress counter goes down, and at zero the
    /// code jumps to `forced`. It uses `x14` and `x17`, so an operand in
    /// `x15` stays.
    fn stressCheck(e: *Emitter, forced: Label) Error!void {
        try e.ctx(rax);
        try e.ldr(rax, rax, @offsetOf(jit.EnterCtx, "counters"));
        const at = @as(i64, e.heads) * 4;
        try e.ldrW(tmp, rax, at);
        try e.s.subI(tmp, tmp, 1, false);
        try e.strW(tmp, rax, at);
        try e.s.cbzW(tmp, forced);
    }

    fn guardExit(e: *Emitter, pc: u32, refund: u32) Error!Label {
        const lb = try e.exitFrom(pc, pc, refund, exit_guard);
        if (e.stress) try e.stressCheck(try e.exitFrom(pc, pc, refund, exit_forced));
        return lb;
    }

    fn target(e: *Emitter, pc: u32, t: u32) Error!Label {
        if (!e.inLoop(t)) return e.exitFrom(t, pc, e.left[pc - e.p.head], 0);
        if (!lower.needsFix(e.p, pc, t)) return e.labels[t - e.p.head];
        const lb = try e.s.newLabel();
        try e.fixes.append(e.a, .{ .at = lb, .pc = pc, .to = t });
        return lb;
    }

    fn fix(e: *Emitter, pc: u32, t: u32) Error!void {
        const outs = e.p.outs[pc - e.p.head];
        const into = e.kinds(t);
        for (outs, into, 0..) |x, y, k| if (x != .any and y == .any) try e.writePlace(@intCast(k), x, e.dloc(@intCast(k)));
    }

    fn writePlace(e: *Emitter, k: u32, kind: Kind, d: DReg) Error!void {
        const l = e.l;
        if (kind == .double) {
            try e.strD(d, abi.stack, e.stackOff(k, l.value_payload));
            try e.putByte(abi.stack, e.stackOff(k, l.value_tag), l.tag_double);
        } else {
            try e.str(e.place(k), abi.stack, e.stackOff(k, l.value_payload));
            try e.putByte(abi.stack, e.stackOff(k, l.value_tag), l.tag_int);
        }
    }

    fn writeSlots(e: *Emitter) Error!void {
        return e.writeSlotsOf(true, true);
    }

    fn writeSlotsOf(e: *Emitter, ints: bool, doubles_: bool) Error!void {
        const l = e.l;
        const pay: i64 = l.var_payload + l.value_payload;
        for (e.p.slots, e.regs, e.dregs) |u, r, x| {
            if (!u.written) continue;
            if (r != null and !ints) continue;
            if (x != null and !doubles_) continue;
            if (r == null and x == null) continue;
            try e.cellPtr(u.slot, rax);
            if (r) |reg| try e.str(reg, rax, pay);
            if (x) |xr| try e.strD(xr, rax, pay);
        }
    }

    fn loadSlots(e: *Emitter, check: bool, fail: Label) Error!void {
        return e.loadSlotsOf(check, fail, true, true);
    }

    fn loadSlotsOf(e: *Emitter, check: bool, fail: Label, ints: bool, doubles_: bool) Error!void {
        const s = e.s;
        const l = e.l;
        const pay: i64 = l.var_payload + l.value_payload;
        for (e.p.slots, e.regs, e.dregs) |u, r, x| {
            if (r == null and x == null) continue;
            if (r != null and !ints) continue;
            if (x != null and !doubles_) continue;
            try e.cellPtr(u.slot, rax);
            if (check) {
                // The slot entry itself must be a plain cell: a link fails.
                try e.cmpByte(rax, l.var_tag, l.var_val);
                try s.bcond(.ne, fail);
                try e.cmpByte(rax, l.var_payload + l.value_tag, if (r != null) l.tag_int else l.tag_double);
                try s.bcond(.ne, fail);
            }
            if (r) |reg| try e.ldr(reg, rax, pay);
            if (x) |xr| {
                try e.ldrD(xr, rax, pay);
                if (check) {
                    try s.fcmp(xr, xr);
                    try s.bcond(.vs, fail);
                }
            }
        }
    }

    fn cellPtr(e: *Emitter, slot: u32, r: Reg) Error!void {
        try e.ldr(r, abi.frame, e.l.frame_items);
        try e.ldr(r, r, @as(i64, slot) * e.l.entry_size + e.l.entry_cell);
    }

    fn constReg(e: *const Emitter, is_lit: bool, index: u32) ?Reg {
        for (e.consts.items) |c| if (c.lit == is_lit and c.index == index) return c.reg;
        return null;
    }

    fn lit(e: *Emitter, index: u32, dst: Reg) Error!Reg {
        if (e.constReg(true, index)) |r| return r;
        try e.litInt(index, dst);
        return dst;
    }

    fn litInt(e: *Emitter, index: u32, dst: Reg) Error!void {
        try e.ldr(dst, abi.code, e.l.code_lits);
        try e.ldr(dst, dst, @as(i64, index) * e.l.value_size + e.l.value_payload);
    }

    fn loadConsts(e: *Emitter) Error!void {
        for (e.consts.items) |c| {
            if (c.lit) try e.litInt(c.index, c.reg) else try e.incrBy(c.index, c.reg);
        }
        for (e.dconsts.items) |c| try e.litDouble(c.index, c.reg);
    }

    /// Copies a Value with `x15` and `x17`.
    fn copy(e: *Emitter, dst: Reg, dst_off: i64, src: Reg, src_off: i64) Error!void {
        try e.ldr(rcx, src, src_off);
        try e.str(rcx, dst, dst_off);
        try e.ldr(rcx, src, src_off + 8);
        try e.str(rcx, dst, dst_off + 8);
        try e.s.load(.b, .{ .r = tmp }, src, src_off + e.l.value_tag);
        try e.s.store(.b, .{ .r = tmp }, dst, dst_off + e.l.value_tag);
    }

    fn epochCheck(e: *Emitter, fail: Label) Error!void {
        try e.ldrW(rax, abi.it, e.l.it_epoch);
        try e.ldrW(rcx, abi.it, e.l.it_safe_epoch);
        try e.s.cmpWR(rax, rcx);
        try e.s.bcond(.ne, fail);
    }

    fn memCheck(e: *Emitter, fail: Label) Error!void {
        try e.ldr(rax, abi.it, e.l.it_mem_trip);
        try e.ldr(rcx, abi.it, e.l.it_mem_limit);
        try e.s.cmpR(rax, rcx, .lsl, 0);
        try e.s.bcond(.hs, fail);
    }

    fn entry(e: *Emitter) Error!void {
        try e.loadSlots(true, e.head_exit);
        try e.epochCheck(e.head_exit);
        try e.memCheck(e.head_exit);
        try e.loadConsts();
    }

    fn nextIs(e: *const Emitter, pc: u32, op: vm.Op) bool {
        const nx = pc + 1;
        if (nx > e.p.back or e.targets[nx - e.p.head]) return false;
        return e.code.ins[nx].op == op;
    }

    /// Writes the result in `x14` of instruction `pc` to stack place `k`,
    /// or to the register of the slot of the next `store_pop`.
    fn result(e: *Emitter, pc: u32, k: u32) Error!void {
        if (e.nextIs(pc, .store_pop)) {
            if (e.slotReg(e.code.ins[pc + 1].a)) |r| {
                try e.s.movRR(r, rax);
                e.skip = true;
                return;
            }
        }
        try e.s.movRR(e.place(k), rax);
    }

    fn compareCond(op: expr.BinOp) Cond {
        return switch (op) {
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            .eq => .eq,
            .ne => .ne,
            else => unreachable,
        };
    }

    fn overflowExit(e: *Emitter, op: expr.BinOp, pc: u32) Error!?Label {
        return switch (op) {
            .add, .sub, .mul, .div, .mod => try e.guardExit(pc, e.left[pc - e.p.head]),
            else => null,
        };
    }

    /// `x14 = x14 op y`, with the overflow check that jumps to `over`. `/`
    /// and `%` send a divisor of 0 or -1 to `over` and round the quotient
    /// down. They use `x16` and `x17`.
    fn arith(e: *Emitter, op: expr.BinOp, over: ?Label, y: Reg) Error!void {
        const s = e.s;
        if (op == .div or op == .mod) {
            try s.cbz(y, over.?);
            try s.addsI(.zr, y, 1, false);
            try s.bcond(.eq, over.?);
            try s.sdiv(t16, rax, y);
            try s.msub(tmp, t16, y, rax);
            const done = try s.newLabel();
            try s.cbz(tmp, done);
            try s.opR(.eor, rax, tmp, y, .lsl, 0);
            try s.cmpR(rax, .zr, .lsl, 0);
            try s.bcond(.ge, done);
            if (op == .div) try s.subI(t16, t16, 1, false) else try s.opR(.add, tmp, tmp, y, .lsl, 0);
            s.bind(done);
            try s.movRR(rax, if (op == .div) t16 else tmp);
            return;
        }
        switch (op) {
            .add => try s.opR(.adds, rax, rax, y, .lsl, 0),
            .sub => try s.opR(.subs, rax, rax, y, .lsl, 0),
            .mul => {
                try s.mul(t16, rax, y);
                try s.smulh(tmp, rax, y);
                try s.cmpR(tmp, t16, .asr, 63);
                try s.bcond(.ne, over.?);
                try s.movRR(rax, t16);
                return;
            },
            else => {
                try s.cmpR(rax, y, .lsl, 0);
                try s.cset(rax, compareCond(op));
                return;
            },
        }
        try s.bcond(.vs, over.?);
    }

    /// The step of the `incr` at `pc` into `dst`: a 32-bit load and a sign
    /// extension.
    fn incrBy(e: *Emitter, pc: u32, dst: Reg) Error!void {
        try e.ldr(dst, abi.code, e.l.code_ins);
        try e.ldrW(dst, dst, @as(i64, pc) * e.l.ins_size + 8);
        try e.s.lslI(dst, dst, 32);
        try e.s.asrI(dst, dst, 32);
    }

    fn noCall(e: *const Emitter, pc: u32) bool {
        const k = pc - e.p.head;
        return tier2.noCall(e.code.ins[pc], e.p.kinds[k], e.p.slot_kinds[k], e.p);
    }

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
            .guard, .step, .load, .push, .push_empty, .store, .store_pop => {},
            else => try e.settle(pc),
        }
        switch (i.op) {
            .guard, .step, .pop => {},
            .push_empty => {
                try e.ctx(rax);
                try e.ldr(rax, rax, @offsetOf(jit.EnterCtx, "empty"));
                try e.copy(abi.stack, @as(i64, d) * l.value_size, rax, 0);
            },
            .jump => {
                if (pc == e.p.back and e.p.calls) {
                    // A loop with calls counts its passes for `tier_up`.
                    try e.ctx(rax);
                    try e.ldr(rax, rax, @offsetOf(jit.EnterCtx, "counters"));
                    const at = (@as(i64, e.heads) + 1 + e.loop) * 4;
                    try e.ldrW(rcx, rax, at);
                    try s.addI(rcx, rcx, 1, false);
                    try e.strW(rcx, rax, at);
                }
                try s.b(try e.target(pc, i.a));
            },
            .push => if (e.code.lits[i.a] == .int) {
                try e.litInt(i.a, e.place(d));
            } else {
                try e.ldr(rax, abi.code, l.code_lits);
                try e.copy(abi.stack, @as(i64, d) * l.value_size, rax, @as(i64, i.a) * l.value_size);
            },
            .load => try s.movRR(e.place(d), e.slotReg(i.a).?),
            .store, .store_pop => try s.movRR(e.slotReg(i.a).?, e.place(d - 1)),
            .to_bool => {
                const r = e.place(d - 1);
                try s.cmpI(r, 0);
                try s.cset(r, .ne);
            },
            .jump_false, .jump_true => {
                const t = try e.target(pc, i.a);
                if (i.op == .jump_false) try s.cbz(e.place(d - 1), t) else try s.cbnz(e.place(d - 1), t);
            },
            .jf_vv, .jf_vi => {
                const y = if (i.op == .jf_vv) e.slotReg(i.b).? else try e.lit(i.b, rcx);
                try s.cmpR(e.slotReg(i.a).?, y, .lsl, 0);
                try s.bcond(a64.invert(compareCond(@enumFromInt(i.x))), try e.target(pc, i.c));
            },
            .incr, .incr_drop, .incr_value => {
                const r = e.slotReg(i.a).?;
                const over = try e.guardExit(pc, e.left[pc - e.p.head]);
                const by = if (i.op == .incr_value) e.place(d - 1) else e.constReg(false, pc) orelse blk: {
                    try e.incrBy(pc, rcx);
                    break :blk rcx;
                };
                try s.opR(.adds, rax, r, by, .lsl, 0);
                try s.bcond(.vs, over);
                try s.movRR(r, rax);
                switch (i.op) {
                    .incr => try s.movRR(e.place(d), rax),
                    .incr_value => try s.movRR(e.place(d - 1), rax),
                    else => {},
                }
            },
            .bin_vv, .bin_vi => {
                const y = if (i.op == .bin_vv) e.slotReg(i.b).? else try e.lit(i.b, rcx);
                const over = try e.overflowExit(@enumFromInt(i.x), pc);
                try s.movRR(rax, e.slotReg(i.a).?);
                try e.arith(@enumFromInt(i.x), over, y);
                try e.result(pc, d);
            },
            .binary => {
                const over = try e.overflowExit(@enumFromInt(i.x), pc);
                try s.movRR(rax, e.place(d - 2));
                try e.arith(@enumFromInt(i.x), over, e.place(d - 1));
                try e.result(pc, d - 2);
            },
            else => unreachable,
        }
        return true;
    }

    // ---- Doubles ----

    /// The condition of a compare of doubles after `fcmp`, for operands
    /// that are not a NaN.
    fn dcond(op: expr.BinOp) Cond {
        return switch (op) {
            .lt => .mi,
            .le => .ls,
            .gt => .gt,
            .ge => .ge,
            .eq => .eq,
            .ne => .ne,
            else => unreachable,
        };
    }

    fn slotOperand(e: *const Emitter, slot: u32) Operand {
        if (e.slotD(slot)) |x| return .{ .loc = .{ .d = x } };
        return .{ .loc = .{ .g = e.slotReg(slot).? }, .finite = true };
    }

    fn placeOperand(e: *const Emitter, pc: u32, k: u32) Operand {
        if (e.kindAt(pc, k) == .int) return .{ .loc = .{ .g = e.place(k) }, .finite = true };
        const v = e.known[k - e.base];
        return .{
            .loc = .{ .d = e.dloc(k) },
            .finite = v != null and std.math.isFinite(v.?),
            .nonzero = v != null and std.math.isFinite(v.?) and v.? != 0,
        };
    }

    fn inD(e: *Emitter, o: Operand, scratch: DReg) Error!DReg {
        switch (o.loc) {
            .d => |x| return x,
            .g => |r| try e.s.scvtf(scratch, r),
            .lit => |index| try e.s.scvtf(scratch, try e.lit(index, rcx)),
        }
        return scratch;
    }

    fn isDouble(o: Operand) bool {
        return o.loc == .d;
    }

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
                const x = e.slotD(i.a) orelse return false;
                e.alias[d - e.base] = x;
                e.known[d - e.base] = null;
                return true;
            },
            .push => {
                if (e.code.lits[i.a] != .double) return false;
                if (e.dconstReg(i.a)) |x| {
                    e.alias[d - e.base] = x;
                } else {
                    e.alias[d - e.base] = null;
                    try e.litDouble(i.a, e.dplace(d));
                }
                e.known[d - e.base] = e.code.lits[i.a].double;
                return true;
            },
            .store, .store_pop => {
                const x = e.slotD(i.a) orelse return false;
                try e.settleReg(pc, d - 1, x);
                const v = e.dloc(d - 1);
                if (v != x) try s.fmovDD(x, v);
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
                    const ax = try e.inD(a, dx0);
                    const bx = try e.inD(b, dx1);
                    try s.fcmp(ax, bx);
                    try s.cset(rax, dcond(op));
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
                const ax = try e.inD(a, dx0);
                const bx = try e.inD(b, dx1);
                try s.fcmp(ax, bx);
                try s.bcond(a64.invert(dcond(@enumFromInt(i.x))), try e.target(pc, i.c));
                return true;
            },
            else => return false,
        }
    }

    fn arithDouble(e: *Emitter, pc: u32, op: expr.BinOp, a: Operand, b: Operand, k: u32) Error!void {
        const s = e.s;
        const i = e.code.ins[pc];
        const safe = lower.nanFree(op, .{ .finite = a.finite, .nonzero = a.nonzero }, .{ .finite = b.finite, .nonzero = b.nonzero });
        var dest = e.dplace(k);
        var resume_pc = pc + 1;
        var fused = false;
        if (e.nextIs(pc, .store_pop)) {
            if (e.slotD(e.code.ins[pc + 1].a)) |x| {
                dest = x;
                resume_pc = pc + 2;
                fused = true;
            }
        }
        if (!safe) try e.settleBelow(pc, k) else try e.settleReg(pc, k, dest);
        const ax = try e.inD(a, dx0);
        const bx = try e.inD(b, dx1);
        const o: a64.FOp = switch (op) {
            .add => .fadd,
            .sub => .fsub,
            .mul => .fmul,
            .div => .fdiv,
            else => unreachable,
        };
        // A three-operand form: the operands keep their registers.
        try s.fop(o, dest, ax, bx);
        if (i.op == .binary) {
            e.alias[k + 1 - e.base] = null;
            e.known[k + 1 - e.base] = null;
        }
        e.alias[k - e.base] = null;
        e.known[k - e.base] = null;
        if (fused) e.skip = true;
        if (!safe) {
            const refund = e.left[resume_pc - e.p.head];
            try s.fcmp(dest, dest);
            try s.bcond(.vs, try e.exitFrom(resume_pc, resume_pc, refund, exit_guard));
            if (e.stress) try e.stressCheck(try e.exitFrom(resume_pc, resume_pc, refund, exit_forced));
        }
    }

    // ---- Calls ----

    fn sync(e: *Emitter, pc: u32) Error!void {
        try e.writeSlots();
        var k = e.base;
        while (k < e.depth(pc)) : (k += 1) {
            const kind = e.kindAt(pc, k);
            if (kind == .any) continue;
            try e.writePlace(k, kind, e.dloc(k));
        }
    }

    fn stub(e: *Emitter, pc: u32) Error!Label {
        const k = pc - e.p.head;
        if (e.stubs[k]) |lb| return lb;
        const lb = try e.s.newLabel();
        e.stubs[k] = lb;
        return lb;
    }

    /// The call of helper `h` for `pc` with the state of tier 1. A helper
    /// that runs no script changes no cell, so the integer slot registers
    /// and the constant registers stay on the native stack across it, in
    /// pairs, with the stack pointer 16-byte aligned.
    fn call(e: *Emitter, pc: u32, h: Helper, pure: bool, fall: bool) Error!void {
        const s = e.s;
        const i = e.code.ins[pc];
        var keep: [slot_regs.len + extra_regs.len + 1]Reg = undefined;
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
        if (nkeep % 2 == 1) {
            keep[nkeep] = .zr;
            nkeep += 1;
        }
        if (pure) try e.syncKept(pc) else try e.sync(pc);
        var k: usize = 0;
        while (k < nkeep) : (k += 2) try s.stpPre(keep[k], keep[k + 1], .sp, -16);
        if (i.op == .invoke) {
            const l = e.l;
            const miss = try s.newLabel();
            const called = try s.newLabel();
            try e.ldr(rax, abi.code, l.code_sites);
            try e.ldr(rax, rax, @as(i64, i.a) * 8);
            try e.ldr(rcx, rax, l.cmd_resolved);
            try s.cbz(rcx, miss);
            try e.ldrW(rcx, rax, l.cmd_epoch);
            try e.ldrW(tmp, abi.it, l.it_epoch);
            try s.cmpWR(rcx, tmp);
            try s.bcond(.ne, miss);
            try e.ldr(rcx, rax, l.cmd_ns);
            try e.ldr(tmp, abi.it, l.it_ns);
            try s.cmpR(rcx, tmp, .lsl, 0);
            try s.bcond(.ne, miss);
            try e.helperCall(pc, .call_direct);
            try s.b(called);
            s.bind(miss);
            try e.helperCall(pc, .invoke);
            s.bind(called);
        } else try e.helperCall(pc, h);
        try s.cmpWI(abi.ret, helpers.yes);
        // `ldp` with post-index keeps the flags.
        k = nkeep;
        while (k > 0) {
            k -= 2;
            if (keep[k + 1] == .zr) try s.ldpPost(keep[k], .zr, .sp, 16) else try s.ldpPost(keep[k], keep[k + 1], .sp, 16);
        }
        try s.bcond(.hi, if (pure) try e.keptStub(pc) else try e.stub(pc));
        if (lower.branchTarget(i)) |tt| {
            const not_taken = try s.newLabel();
            try s.bcond(.ne, not_taken);
            try e.after(pc, tt, pure, false);
            s.bind(not_taken);
        }
        try e.after(pc, pc + 1, pure, fall);
    }

    fn helperCall(e: *Emitter, pc: u32, h: Helper) Error!void {
        const s = e.s;
        try e.ctx(abi.arg0);
        try s.movImm(abi.arg1, @intCast(pc));
        try s.movImm(abi.arg2, @intCast(e.depth(pc)));
        try e.ldr(t16, abi.helpers, 8 * @as(i64, @intFromEnum(h)));
        try s.blr(t16);
    }

    fn syncKept(e: *Emitter, pc: u32) Error!void {
        try e.writeSlotsOf(false, true);
        var k = e.base;
        while (k < e.depth(pc)) : (k += 1) {
            const kind = e.kindAt(pc, k);
            if (kind == .any) continue;
            try e.writePlace(k, kind, e.dloc(k));
        }
    }

    fn keptStub(e: *Emitter, pc: u32) Error!Label {
        const lb = try e.s.newLabel();
        try e.kept.append(e.a, .{ .at = lb, .pc = pc, .to = pc });
        return lb;
    }

    fn callOut(e: *Emitter, pc: u32, h: Helper, pure: bool) Error!void {
        try e.call(pc, h, pure, true);
    }

    fn after(e: *Emitter, pc: u32, next: u32, pure: bool, fall: bool) Error!void {
        const s = e.s;
        const l = e.l;
        if (!e.inLoop(next)) {
            try s.b(try e.syncedKept(next, 0, pure));
            return;
        }
        if (!pure) try e.epochCheck(try e.syncedKept(next, exit_guard, pure));
        if (e.stress) try e.stressCheck(try e.syncedKept(next, exit_forced, pure));
        try e.memCheck(try e.syncedKept(next, 0, pure));
        const fail = try e.syncedKept(next, exit_guard, pure);
        try e.loadSlotsOf(!pure, fail, !pure, true);
        const ef = verify.effectAt(e.code, pc).?;
        const first = e.depth(pc) - ef.need;
        var k = e.base;
        while (k < e.depth(next)) : (k += 1) {
            const kind = e.kindAt(next, k);
            if (kind == .any) continue;
            if (k >= first) {
                try e.cmpByte(abi.stack, e.stackOff(k, l.value_tag), if (kind == .int) l.tag_int else l.tag_double);
                try s.bcond(.ne, fail);
            }
            if (kind == .int) {
                try e.ldr(e.place(k), abi.stack, e.stackOff(k, l.value_payload));
            } else {
                try e.ldrD(e.dplace(k), abi.stack, e.stackOff(k, l.value_payload));
                if (k >= first) {
                    try s.fcmp(e.dplace(k), e.dplace(k));
                    try s.bcond(.vs, fail);
                }
            }
        }
        // A call writes the caller-saved constant registers, so each one
        // loads again. A pure call kept the integer constants.
        if (pure) {
            for (e.dconsts.items) |c| try e.litDouble(c.index, c.reg);
        } else try e.loadConsts();
        if (!fall or next != pc + 1) try s.b(e.labels[next - e.p.head]);
    }

    fn slow(e: *Emitter, pc: u32) Error!Label {
        const lb = try e.s.newLabel();
        try e.slows.append(e.a, .{ .at = lb, .pc = pc });
        return lb;
    }

    /// `dst = src * value_size`, with `x17`. `dst` and `src` differ.
    fn scale(e: *Emitter, dst: Reg, src: Reg) Error!void {
        try e.s.movImm(tmp, e.l.value_size);
        try e.s.mul(dst, src, tmp);
    }

    /// `lappend` of one value to the list of a plain cell with room at its
    /// end. The length goes to `x16`. No load between its set and its last
    /// use has an offset that needs `x16`: each offset is a small field.
    fn lappend(e: *Emitter, pc: u32) Error!bool {
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const d = e.depth(pc);
        if (e.slotReg(i.a) != null) {
            try e.callOut(pc, .lappend, false);
            return false;
        }
        const slow_l = try e.slow(pc);
        try e.cellPtr(i.a, rax);
        try e.cmpByte(rax, l.var_tag, l.var_val);
        try s.bcond(.ne, slow_l);
        try e.cmpByte(rax, l.var_payload + l.value_tag, l.tag_list);
        try s.bcond(.ne, slow_l);
        try e.ldr(t16, rax, l.var_payload + l.value_len);
        try e.ldr(rcx, rax, l.var_payload + l.value_payload);
        try e.ldr(tmp, rcx, l.obj_used);
        try s.cmpR(t16, tmp, .lsl, 0);
        try s.bcond(.ne, slow_l);
        try e.ldr(tmp, rcx, l.obj_buf_len);
        try s.cmpR(t16, tmp, .lsl, 0);
        try s.bcond(.hs, slow_l);
        // Each check passed. The value goes to the buffer, then `used`
        // and the length grow.
        try e.addWord(rcx, l.obj_used, 1);
        try e.addWord(rax, l.var_payload + l.value_len, 1);
        try e.ldr(rcx, rcx, l.obj_buf);
        try e.scale(rax, t16);
        try s.opR(.add, rax, rax, rcx, .lsl, 0);
        if (e.kindAt(pc, d - 1) == .int) {
            try e.str(e.place(d - 1), rax, l.value_payload);
            try e.str(.zr, rax, l.value_len);
            try e.putByte(rax, l.value_tag, l.tag_int);
        } else if (e.kindAt(pc, d - 1) == .double) {
            try e.strD(e.dplace(d - 1), rax, l.value_payload);
            try e.str(.zr, rax, l.value_len);
            try e.putByte(rax, l.value_tag, l.tag_double);
        } else {
            try e.copy(rax, 0, abi.stack, @as(i64, d - 1) * l.value_size);
        }
        if (e.nextIs(pc, .pop)) return true;
        try e.cellPtr(i.a, rax);
        try e.copy(abi.stack, @as(i64, d - 1) * l.value_size, rax, l.var_payload);
        return true;
    }

    /// The address of item `idx + k` of the list at place `list` into
    /// `x14`, with `x15`.
    fn itemAddr(e: *Emitter, list: u32, idx: u32, k: usize) Error!void {
        const l = e.l;
        try e.ldr(rcx, abi.stack, e.stackOff(idx, l.value_payload));
        if (k > 0) try e.s.addI(rcx, rcx, @intCast(k), false);
        try e.scale(rax, rcx);
        try e.ldr(rcx, abi.stack, e.stackOff(list, l.value_payload));
        try e.ldr(rcx, rcx, l.obj_buf);
        try e.s.opR(.add, rax, rax, rcx, .lsl, 0);
    }

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
        const slow_l = try e.slow(pc);
        const list = d - 2;
        const idx = d - 1;
        const fail = try e.guardExit(pc, e.left[pc - e.p.head]);
        try e.cmpByte(abi.stack, e.stackOff(list, l.value_tag), l.tag_list);
        try s.bcond(.ne, slow_l);
        try e.cmpByte(abi.stack, e.stackOff(idx, l.value_tag), l.tag_int);
        try s.bcond(.ne, slow_l);
        try e.ldr(rcx, abi.stack, e.stackOff(idx, l.value_payload));
        try e.ldr(tmp, abi.stack, e.stackOff(list, l.value_len));
        try s.cmpR(rcx, tmp, .lsl, 0);
        try s.bcond(.hs, try e.target(pc, i.b));
        for (table, 0..) |_, k| {
            if (k > 0) {
                try e.ldr(rcx, abi.stack, e.stackOff(idx, l.value_payload));
                try s.addI(rcx, rcx, @intCast(k), false);
                // An item past the end is the empty string: no integer.
                try e.ldr(tmp, abi.stack, e.stackOff(list, l.value_len));
                try s.cmpR(rcx, tmp, .lsl, 0);
                try s.bcond(.hs, fail);
            }
            try e.itemAddr(list, idx, k);
            try e.cmpByte(rax, l.value_tag, l.tag_int);
            try s.bcond(.ne, fail);
        }
        // The step of `foreach_next`. No code since the last memory check
        // allocates, so the memory check of the step passes.
        try e.ldr(rcx, abi.it, l.it_step_limit);
        try s.cbz(rcx, slow_l);
        try s.subI(rcx, rcx, 1, false);
        try e.str(rcx, abi.it, l.it_step_limit);
        var k: usize = table.len;
        while (k > 0) {
            k -= 1;
            if (k + 1 < table.len) try e.itemAddr(list, idx, k);
            try e.ldr(e.slotReg(table[k]).?, rax, l.value_payload);
        }
        try e.addWord(abi.stack, e.stackOff(idx, l.value_payload), @intCast(table.len));
        return true;
    }

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
        const slow_l = try e.slow(pc);
        try e.cmpByte(abi.stack, e.stackOff(d - 1, l.value_tag), l.tag_int);
        try s.bcond(.ne, slow_l);
        const at = e.stackOff(d - 1, l.value_payload);
        switch (i.op) {
            .incr_value => {
                try e.ldr(rcx, abi.stack, at);
                try s.opR(.adds, rax, reg.?, rcx, .lsl, 0);
                try s.bcond(.vs, slow_l);
                try s.movRR(reg.?, rax);
                try e.str(rax, abi.stack, at);
            },
            .to_bool => {
                // The result has the kind `int`, so it goes to the
                // register of the place.
                const r = e.place(d - 1);
                try e.ldr(rcx, abi.stack, at);
                try s.cmpI(rcx, 0);
                try s.cset(r, .ne);
            },
            else => {
                try e.ldr(rcx, abi.stack, at);
                const t = try e.target(pc, i.a);
                if (i.op == .jump_false) try s.cbz(rcx, t) else try s.cbnz(rcx, t);
            },
        }
        return true;
    }

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
        const slow_l = try e.slow(pc);
        try e.cmpByte(abi.stack, e.stackOff(list, l.value_tag), l.tag_list);
        try s.bcond(.ne, slow_l);
        if (i.x == 0) {
            try e.ldr(e.place(d - 1), abi.stack, e.stackOff(list, l.value_len));
            return true;
        }
        switch (e.kindAt(pc, d - 1)) {
            .int => try s.movRR(rcx, e.place(d - 1)),
            .any => {
                try e.cmpByte(abi.stack, e.stackOff(d - 1, l.value_tag), l.tag_int);
                try s.bcond(.ne, slow_l);
                try e.ldr(rcx, abi.stack, e.stackOff(d - 1, l.value_payload));
            },
            .double => {
                try e.callOut(pc, .lindex, true);
                return false;
            },
        }
        // An unsigned compare: a negative index is out of range.
        const empty = try s.newLabel();
        const have = try s.newLabel();
        try e.ldr(tmp, abi.stack, e.stackOff(list, l.value_len));
        try s.cmpR(rcx, tmp, .lsl, 0);
        try s.bcond(.hs, empty);
        try e.scale(rax, rcx);
        try e.ldr(rcx, abi.stack, e.stackOff(list, l.value_payload));
        try e.ldr(rcx, rcx, l.obj_buf);
        try s.opR(.add, rax, rax, rcx, .lsl, 0);
        try s.b(have);
        s.bind(empty);
        try e.ctx(rax);
        try e.ldr(rax, rax, @offsetOf(jit.EnterCtx, "empty"));
        s.bind(have);
        try e.copy(abi.stack, @as(i64, list) * l.value_size, rax, 0);
        return true;
    }

    fn loadCell(e: *Emitter, pc: u32) Error!bool {
        const l = e.l;
        const i = e.code.ins[pc];
        const slow_l = try e.slow(pc);
        try e.cellPtr(i.a, rax);
        try e.cmpByte(rax, l.var_tag, l.var_val);
        try e.s.bcond(.ne, slow_l);
        try e.copy(abi.stack, @as(i64, e.depth(pc)) * l.value_size, rax, l.var_payload);
        return true;
    }

    fn storeCell(e: *Emitter, pc: u32) Error!bool {
        const l = e.l;
        const i = e.code.ins[pc];
        const d = e.depth(pc);
        if (e.slotReg(i.a) != null or e.kindAt(pc, d - 1) != .any) {
            try e.callOut(pc, tier1.Emitter.helperOf(i), false);
            return false;
        }
        const slow_l = try e.slow(pc);
        try e.cellPtr(i.a, rax);
        try e.cmpByte(rax, l.var_tag, l.var_val);
        try e.s.bcond(.ne, slow_l);
        try e.copy(rax, l.var_payload, abi.stack, @as(i64, d - 1) * l.value_size);
        return true;
    }

    fn emitSlows(e: *Emitter) Error!void {
        var k: usize = 0;
        while (k < e.slows.items.len) : (k += 1) {
            const x = e.slows.items[k];
            e.s.bind(x.at);
            const i = e.code.ins[x.pc];
            try e.call(x.pc, tier1.Emitter.helperOf(i), tier2.runsNoScript(i), false);
        }
    }

    fn emitFixes(e: *Emitter) Error!void {
        for (e.fixes.items) |x| {
            e.s.bind(x.at);
            try e.fix(x.pc, x.to);
            try e.s.b(e.labels[x.to - e.p.head]);
        }
    }

    fn emitStubs(e: *Emitter) Error!void {
        const s = e.s;
        for (e.kept.items) |x| {
            s.bind(x.at);
            try e.writeSlotsOf(true, false);
            try s.b(try e.stub(x.pc));
        }
        for (e.stubs, 0..) |maybe, k| {
            const lb = maybe orelse continue;
            const pc: u32 = @intCast(e.p.head + k);
            s.bind(lb);
            try e.ctx(rcx);
            try s.movImm(rax, @intCast(pc));
            try e.strW(rax, rcx, @offsetOf(jit.EnterCtx, "pc"));
            try s.movImm(rax, @intCast(e.depth(pc)));
            try e.strW(rax, rcx, @offsetOf(jit.EnterCtx, "sp"));
            try s.movzW(abi.ret, tier1.status_error);
            try s.b(e.epilogue);
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
                    try e.writePlace(k, kind, e.dplace(k));
                }
                try e.writeSlots();
                if (x.refund > 0) try e.addWord(abi.it, l.it_step_limit, x.refund);
            }
            try s.movImm(abi.arg1, @intCast(x.pc));
            try s.movImm(abi.arg2, @intCast(e.depth(x.pc)));
            try s.movImm(.x3, @as(i64, x.kind | e.loop));
            try s.b(e.resume_l);
        }
        s.bind(e.head_exit);
        try s.movImm(abi.arg1, @intCast(e.p.head));
        try s.movImm(abi.arg2, @intCast(e.depth(e.p.head)));
        try s.movImm(.x3, @as(i64, exit_guard | e.loop));
        // `resume_at` gives the address of the tier 1 code of `pc`, or 0,
        // and the code returns status 2 with the frame of tier 1.
        s.bind(e.resume_l);
        try e.ctx(abi.arg0);
        try e.ldr(t16, abi.helpers, 8 * @as(i64, @intFromEnum(Helper.resume_at)));
        try s.blr(t16);
        const ret = try s.newLabel();
        try s.cbz(abi.ret, ret);
        try s.br(abi.ret);
        s.bind(ret);
        try s.movzW(abi.ret, tier1.status_exit);
        // The epilogue of the frame of tier 1.
        s.bind(e.epilogue);
        try s.ldpOff(.x23, t16, .sp, 48);
        try s.ldpOff(.x21, .x22, .sp, 32);
        try s.ldpOff(.x19, .x20, .sp, 16);
        try s.ldpPost(.x29, .x30, .sp, abi.frame_bytes);
        try s.ret();
    }
};

/// Assembles the tier 2 code of the loop of `p`. The entry block is at
/// offset 0. `loop` is the number of the loop head in the function,
/// `heads` the count of loop heads, and `stress` turns on the schedule of
/// failed guards.
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
    const slot_reg = try a.alloc(?Reg, p.slots.len);
    defer a.free(slot_reg);
    var nslot: usize = 0;
    for (p.slots, slot_reg) |u, *r| {
        r.* = null;
        if (lower.slotClass(u) != .int) continue;
        r.* = slot_regs[nslot];
        nslot += 1;
    }
    const slot_dreg = try a.alloc(?DReg, p.slots.len);
    defer a.free(slot_dreg);
    var ndslot: usize = 0;
    for (p.slots, slot_dreg) |u, *r| {
        r.* = null;
        if (lower.slotClass(u) != .double) continue;
        r.* = slot_dregs[ndslot];
        ndslot += 1;
    }
    var dregs: [slot_dregs.len + extra_dregs.len]DReg = undefined;
    var ndr: usize = 0;
    for (slot_dregs[ndslot..]) |r| {
        dregs[ndr] = r;
        ndr += 1;
    }
    for (extra_dregs) |r| {
        dregs[ndr] = r;
        ndr += 1;
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
    if (need > nr or need > ndr) return error.Range;
    const alias = try a.alloc(?DReg, need);
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
        .dregs = slot_dreg,
        .dstack = dregs[0..need],
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
    defer e.dconsts.deinit(a);
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
    var dfree_at = need;
    for (0..n) |k| {
        const pc: u32 = @intCast(p.head + k);
        if (!p.seen[k]) continue;
        const i = code.ins[pc];
        if (i.op != .push or code.lits[i.a] != .double) continue;
        if (e.dconstReg(i.a) != null or dfree_at >= ndr) continue;
        try e.dconsts.append(a, .{ .index = i.a, .reg = dregs[dfree_at] });
        dfree_at += 1;
    }
    try s.reserveFor(n, 4 * n + 8);
    try e.entry();
    var part: usize = 0;
    for (0..n) |k| {
        const pc: u32 = @intCast(p.head + k);
        while (part < p.parts.len and p.parts[part].last < pc) part += 1;
        const pt = p.parts[part];
        const check = checkAt(code, pt) == pc and pt.steps > 0;
        if (p.seen[k] and (targets[k] or check)) try e.settle(pc);
        if (targets[k]) @memset(e.known, null);
        s.bind(labels[k]);
        if (check) {
            // At least `steps` steps are left, or the exit, with no step
            // used.
            try e.cmpWord(abi.it, l.it_step_limit, pt.steps);
            try s.bcond(.lo, try e.exit(pc, 0));
            try e.addWord(abi.it, l.it_step_limit, -@as(i64, pt.steps));
        }
        if (!p.seen[k]) {
            try s.udf(0);
            continue;
        }
        var regs_live = true;
        if (e.skip) {
            e.skip = false;
        } else regs_live = try e.instruction(pc);
        if (regs_live and falls(code.ins[pc].op) and pc < p.back and lower.needsFix(p, pc, pc + 1)) try e.fix(pc, pc + 1);
    }
    try s.udf(0);
    try e.emitFixes();
    try e.emitSlows();
    try e.emitStubs();
    try e.emitExits();
    try s.finish();
}

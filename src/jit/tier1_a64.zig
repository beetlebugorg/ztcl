//! The templates of tier 1 for arm64.
//!
//! The templates follow `tier1_x64.zig` instruction by instruction: the
//! same fast paths, the same order of checks and effects, and the same
//! helper calls on the slow paths. Only the machine forms differ.
//!
//! The function of a `Code` has one fixed prologue. It saves `x29` and
//! `x30` with `stp` and pre-index, sets `x29`, saves the pinned
//! registers `x19` to `x23` and the context pointer in a frame of 64
//! bytes, loads the pinned registers from the context, and jumps to the
//! target address of the context. The stack pointer stays 16-byte
//! aligned. One epilogue restores the registers and returns `w0`.
//!
//! A helper call loads its address from the helper table (`x23`) into
//! `x16` and uses `blr`. Its arguments are the context (`x0`), the
//! bytecode address (`x1`), and the static stack depth (`x2`). A result
//! above 1 is an error, and the stub of the instruction writes the
//! address and the depth to the context and returns status 1.
//!
//! The overflow of `+` and `-` is the V flag of `adds` and `subs`. The
//! overflow of `*` is a high word of `smulh` that differs from the sign
//! of the low word of `mul`. `/` and `%` use `sdiv` and `msub`, with the
//! rounding down of Tcl. A tag check loads the byte with `ldrb` into
//! `w17` and compares it.
//!
//! The scratch registers are `x9` to `x15`, which stand for `rax`,
//! `rcx`, `rdx`, `r8`, `r9`, `r10`, and `r11` of the x86-64 templates.
//! `x16` is the temporary of a large offset, and `x17` holds a tag byte
//! or a constant of the layout. No value of a script is an immediate
//! operand: the immediates are bytecode addresses, stack depths, helper
//! numbers, field offsets, and tag numbers, and the verifier bounds each
//! one. A `Code` whose code is above 1 MiB has a branch that does not
//! reach, so the assembler fails and the `Code` stays in the interpreter.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vm = @import("../vm.zig");
const a64 = @import("a64.zig");
const abi = @import("abi.zig").a64;
const verify = @import("verify.zig");
const helpers = @import("helpers.zig");
const layout = @import("layout.zig");
const jit = @import("../jit.zig");
const expr = @import("../expr.zig");
const options = @import("build_options");

const Allocator = std.mem.Allocator;
const Asm = a64.Asm;
const Label = a64.Label;
const Helper = helpers.Helper;
const Reg = a64.Reg;
const Cond = a64.Cond;

pub const Error = Allocator.Error || error{ Range, Reg, UnboundLabel, Layout };

/// The registers of the x86-64 templates, by their role.
const rax: Reg = .x9;
const rcx: Reg = .x10;
const rdx: Reg = .x11;
const r8: Reg = .x12;
const r9: Reg = .x13;
const r10: Reg = .x14;
const r11: Reg = .x15;
/// A tag byte or a constant of the layout.
const tmp: Reg = .x17;

/// A piece of code after the last instruction, out of the hot path.
const Cold = union(enum) {
    link: struct { at: Label, cell: Reg, check: Label, slow: Label },
    slow: struct { at: Label, pc: u32, h: Helper, target: ?u32 },
    restore: struct { at: Label, slow: Label },
    recheck: struct { at: Label, pc: u32, cold: u32, back: Label },
    tier_up: struct { at: Label, pc: u32, back: Label },
};

pub const status_done = 0;
pub const status_error = 1;
pub const status_exit = 2;

pub const no_entry = std.math.maxInt(u32);

const ctx_pc: i64 = @offsetOf(jit.EnterCtx, "pc");
const ctx_sp: i64 = @offsetOf(jit.EnterCtx, "sp");

pub const Emitter = struct {
    s: *Asm,
    code: *const vm.Code,
    info: *const verify.Info,
    l: layout.Layout,
    labels: []Label,
    stubs: []?Label,
    epilogue: Label,
    a: Allocator,
    colds: std.ArrayList(Cold) = .empty,
    slows: []?Label,
    tier2: bool = false,

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

    fn ldrB(e: *Emitter, t: Reg, base: Reg, off: i64) Error!void {
        try e.s.load(.b, .{ .r = t }, base, off);
    }

    fn strB(e: *Emitter, t: Reg, base: Reg, off: i64) Error!void {
        try e.s.store(.b, .{ .r = t }, base, off);
    }

    /// Loads the context pointer into `r`.
    fn ctx(e: *Emitter, r: Reg) Error!void {
        try e.ldr(r, abi.fp, abi.ctx_slot);
    }

    fn prologue(e: *Emitter) Error!void {
        const s = e.s;
        try s.stpPre(.x29, .x30, .sp, -abi.frame_bytes);
        try s.movRR(.x29, .sp);
        try s.stpOff(.x19, .x20, .sp, 16);
        try s.stpOff(.x21, .x22, .sp, 32);
        try s.stpOff(.x23, abi.arg0, .sp, 48);
        try e.ldr(abi.it, abi.arg0, @offsetOf(jit.EnterCtx, "it"));
        try e.ldr(abi.code, abi.arg0, @offsetOf(jit.EnterCtx, "code"));
        try e.ldr(abi.frame, abi.arg0, @offsetOf(jit.EnterCtx, "frame"));
        try e.ldr(abi.stack, abi.arg0, @offsetOf(jit.EnterCtx, "stack"));
        try e.ldr(abi.helpers, abi.arg0, @offsetOf(jit.EnterCtx, "helpers"));
        try e.ldr(.x16, abi.arg0, @offsetOf(jit.EnterCtx, "target"));
        try s.br(.x16);
    }

    fn emitEpilogue(e: *Emitter) Error!void {
        const s = e.s;
        s.bind(e.epilogue);
        try s.ldpOff(.x23, .x16, .sp, 48);
        try s.ldpOff(.x21, .x22, .sp, 32);
        try s.ldpOff(.x19, .x20, .sp, 16);
        try s.ldpPost(.x29, .x30, .sp, abi.frame_bytes);
        try s.ret();
    }

    fn stub(e: *Emitter, pc: u32) Error!Label {
        if (e.stubs[pc]) |l| return l;
        const l = try e.s.newLabel();
        e.stubs[pc] = l;
        return l;
    }

    fn emitStubs(e: *Emitter) Error!void {
        const s = e.s;
        for (e.stubs, 0..) |maybe, pc| {
            const l = maybe orelse continue;
            s.bind(l);
            try e.ctx(rcx);
            try s.movImm(rdx, @intCast(pc));
            try e.strW(rdx, rcx, ctx_pc);
            try s.movImm(rdx, e.info.depth[pc]);
            try e.strW(rdx, rcx, ctx_sp);
            try s.movzW(abi.ret, status_error);
            try s.b(e.epilogue);
        }
    }

    /// Calls helper `h` for instruction `pc`: the result is in `w0`.
    pub fn call(e: *Emitter, h: Helper, pc: u32) Error!void {
        const s = e.s;
        try e.ctx(abi.arg0);
        try s.movImm(abi.arg1, @intCast(pc));
        try s.movImm(abi.arg2, e.info.depth[pc]);
        try e.ldr(.x16, abi.helpers, 8 * @as(i64, @intFromEnum(h)));
        try s.blr(.x16);
    }

    /// Jumps to the error stub of `pc` when `w0` is above 1. A helper
    /// returns `u32`, so the compare reads only `w0`.
    pub fn checkError(e: *Emitter, pc: u32) Error!void {
        try e.s.cmpWI(abi.ret, helpers.yes);
        try e.s.bcond(.hi, try e.stub(pc));
    }

    fn plain(e: *Emitter, h: Helper, pc: u32) Error!void {
        try e.call(h, pc);
        try e.checkError(pc);
    }

    fn branch(e: *Emitter, h: Helper, pc: u32, target: u32) Error!void {
        try e.call(h, pc);
        try e.checkError(pc);
        try e.s.bcond(.eq, e.labels[target]);
    }

    fn ret(e: *Emitter, pc: u32) Error!void {
        const s = e.s;
        try e.ctx(rcx);
        try s.movImm(rdx, e.info.depth[pc]);
        try e.strW(rdx, rcx, ctx_sp);
        try s.movzW(abi.ret, status_done);
        try s.b(e.epilogue);
    }

    fn instruction(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        if (e.code.named) switch (i.op) {
            .load, .store, .store_pop, .incr, .incr_drop, .incr_value, .bin_vv, .bin_vi => return e.plain(helperOf(i), pc),
            .jf_vv, .jf_vi => return e.branch(helperOf(i), pc, i.c),
            else => {},
        };
        switch (i.op) {
            .pop => {},
            .jump => try e.s.b(e.labels[i.a]),
            .ret => try e.ret(pc),
            .step => try e.step(pc, .step),
            .guard => try e.guard(pc),
            .push => try e.push(pc),
            .push_empty => try e.pushEmpty(pc),
            .load => try e.load(pc),
            .store, .store_pop => try e.store(pc),
            .jump_false, .jump_true => try e.jumpCond(pc),
            .to_bool => try e.toBool(pc),
            .bin_vv, .bin_vi => try e.binSlots(pc),
            .binary => try e.binary(pc),
            .jf_vv, .jf_vi => try e.jfSlots(pc),
            .incr, .incr_drop, .incr_value => try e.incr(pc),
            .str_eq_jump => try e.strEqJump(pc),
            .foreach_next => try e.foreachNext(pc),
            .lappend => try e.lappend(pc),
            .invoke => try e.invoke(pc),
            .lset_drop => try e.lsetDrop(pc),
            .access => switch (i.x) {
                0 => try e.llength(pc),
                1 => try e.lindex(pc),
                else => try e.plain(accessHelper(i.x), pc),
            },
            inline else => |op| try e.plain(@field(Helper, @tagName(op)), pc),
        }
    }

    // ---- The parts of the fast paths ----

    fn accessHelper(x: u8) Helper {
        return switch (x) {
            0 => .llength,
            1 => .lindex,
            2 => .string_length,
            else => .string_index,
        };
    }

    pub fn helperOf(i: vm.Ins) Helper {
        return switch (i.op) {
            .ret => unreachable,
            .access => accessHelper(i.x),
            inline else => |o| @field(Helper, @tagName(o)),
        };
    }

    fn slow(e: *Emitter, pc: u32) Error!Label {
        if (e.slows[pc]) |l| return l;
        const i = e.code.ins[pc];
        const l = try e.s.newLabel();
        e.slows[pc] = l;
        const target: ?u32 = switch (i.op) {
            .jump_false, .jump_true => i.a,
            .jf_vv, .jf_vi => i.c,
            .foreach_next, .str_eq_jump => i.b,
            else => null,
        };
        try e.colds.append(e.a, .{ .slow = .{ .at = l, .pc = pc, .h = helperOf(i), .target = target } });
        return l;
    }

    fn stackOff(e: *Emitter, k: i64, off: i64) i64 {
        return k * e.l.value_size + off;
    }

    /// Compares the byte at `[base + off]` with `want`.
    fn cmpByte(e: *Emitter, base: Reg, off: i64, want: u8) Error!void {
        try e.ldrB(tmp, base, off);
        try e.s.cmpWI(tmp, want);
    }

    fn cell(e: *Emitter, slot: u32, r: Reg, slow_l: Label) Error!void {
        return e.cellTag(slot, r, e.l.var_val, slow_l);
    }

    fn cellTag(e: *Emitter, slot: u32, r: Reg, want: u8, slow_l: Label) Error!void {
        const s = e.s;
        const l = e.l;
        try e.ldr(r, abi.frame, l.frame_items);
        try e.ldr(r, r, @as(i64, slot) * l.entry_size + l.entry_cell);
        const check = try s.newLabel();
        s.bind(check);
        try e.cmpByte(r, l.var_tag, want);
        const link = try s.newLabel();
        try s.bcond(.ne, link);
        try e.colds.append(e.a, .{ .link = .{ .at = link, .cell = r, .check = check, .slow = slow_l } });
    }

    fn cellValue(e: *Emitter, off: u32) i64 {
        return e.l.var_payload + off;
    }

    fn cellInt(e: *Emitter, r: Reg, dst: Reg, slow_l: Label) Error!void {
        try e.cmpByte(r, e.cellValue(e.l.value_tag), e.l.tag_int);
        try e.s.bcond(.ne, slow_l);
        try e.ldr(dst, r, e.cellValue(e.l.value_payload));
    }

    fn stackInt(e: *Emitter, k: i64, dst: Reg, slow_l: Label) Error!void {
        try e.cmpByte(abi.stack, e.stackOff(k, e.l.value_tag), e.l.tag_int);
        try e.s.bcond(.ne, slow_l);
        try e.ldr(dst, abi.stack, e.stackOff(k, e.l.value_payload));
    }

    fn putInt(e: *Emitter, k: i64, src: Reg) Error!void {
        try e.str(src, abi.stack, e.stackOff(k, e.l.value_payload));
        try e.s.movzW(tmp, e.l.tag_int);
        try e.strB(tmp, abi.stack, e.stackOff(k, e.l.value_tag));
    }

    /// Copies a Value: the two payload words and the tag byte. It uses
    /// `x10`, `x11`, and `x17`, so it keeps `x12` to `x15`.
    fn copy(e: *Emitter, dst: Reg, dst_off: i64, src: Reg, src_off: i64) Error!void {
        try e.ldr(rcx, src, src_off);
        try e.ldr(rdx, src, src_off + 8);
        try e.ldrB(tmp, src, src_off + e.l.value_tag);
        try e.str(rcx, dst, dst_off);
        try e.str(rdx, dst, dst_off + 8);
        try e.strB(tmp, dst, dst_off + e.l.value_tag);
    }

    /// `dst = src * value_size`. `dst` and `src` differ.
    fn scale(e: *Emitter, dst: Reg, src: Reg) Error!void {
        try e.s.movImm(tmp, e.l.value_size);
        try e.s.mul(dst, src, tmp);
    }

    fn stackTag(e: *Emitter, k: i64, tag: u8, l: Label) Error!void {
        try e.cmpByte(abi.stack, e.stackOff(k, e.l.value_tag), tag);
        try e.s.bcond(.ne, l);
    }

    fn emptyAddr(e: *Emitter, r: Reg) Error!void {
        try e.ctx(r);
        try e.ldr(r, r, @offsetOf(jit.EnterCtx, "empty"));
    }

    // ---- The templates ----

    fn step(e: *Emitter, pc: u32, comptime h: Helper) Error!void {
        const slow_l = try e.s.newLabel();
        try e.colds.append(e.a, .{ .slow = .{ .at = slow_l, .pc = pc, .h = h, .target = null } });
        return e.stepTo(slow_l);
    }

    /// The step check with the slow path `slow_l`. It uses `x9` to `x11`.
    fn stepTo(e: *Emitter, slow_l: Label) Error!void {
        const s = e.s;
        const l = e.l;
        try e.ldr(rax, abi.it, l.it_step_limit);
        try s.cbz(rax, slow_l);
        try s.subI(rax, rax, 1, false);
        try e.str(rax, abi.it, l.it_step_limit);
        try e.ldr(rax, abi.it, l.it_mem_trip);
        try e.ldr(rcx, abi.it, l.it_mem_limit);
        try s.cmpR(rax, rcx, .lsl, 0);
        const restore = try s.newLabel();
        try s.bcond(.hs, restore);
        try e.colds.append(e.a, .{ .restore = .{ .at = restore, .slow = slow_l } });
    }

    fn guard(e: *Emitter, pc: u32) Error!void {
        const s = e.s;
        const l = e.l;
        try e.ldrW(rax, abi.it, l.it_epoch);
        try e.ldrW(rcx, abi.it, l.it_safe_epoch);
        try s.cmpWR(rax, rcx);
        const recheck = try s.newLabel();
        const back = try s.newLabel();
        try s.bcond(.ne, recheck);
        try e.colds.append(e.a, .{ .recheck = .{ .at = recheck, .pc = pc, .cold = e.code.ins[pc].a, .back = back } });
        s.bind(back);
        try e.step(pc, .step);
    }

    fn push(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        try e.ldr(rax, abi.code, e.l.code_lits);
        try e.copy(abi.stack, d * e.l.value_size, rax, @as(i64, i.a) * e.l.value_size);
    }

    fn pushEmpty(e: *Emitter, pc: u32) Error!void {
        const d: i64 = e.info.depth[pc];
        try e.emptyAddr(rax);
        try e.copy(abi.stack, d * e.l.value_size, rax, 0);
    }

    fn load(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        try e.cell(i.a, rax, try e.slow(pc));
        try e.copy(abi.stack, d * e.l.value_size, rax, e.l.var_payload);
    }

    fn store(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        try e.cell(i.a, rax, try e.slow(pc));
        try e.copy(rax, e.l.var_payload, abi.stack, (d - 1) * e.l.value_size);
    }

    fn jumpCond(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        try e.stackInt(d - 1, rax, try e.slow(pc));
        if (i.op == .jump_false) try e.s.cbz(rax, e.labels[i.a]) else try e.s.cbnz(rax, e.labels[i.a]);
    }

    fn toBool(e: *Emitter, pc: u32) Error!void {
        const d: i64 = e.info.depth[pc];
        try e.stackInt(d - 1, rax, try e.slow(pc));
        try e.s.cmpI(rax, 0);
        try e.s.cset(rax, .ne);
        try e.str(rax, abi.stack, e.stackOff(d - 1, e.l.value_payload));
    }

    fn compareCond(op: expr.BinOp) ?Cond {
        return switch (op) {
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            .eq => .eq,
            .ne => .ne,
            else => null,
        };
    }

    fn fastOp(op: expr.BinOp) bool {
        return switch (op) {
            .add, .sub, .mul, .div, .mod => true,
            else => compareCond(op) != null,
        };
    }

    /// `x9 = x9 op x10` with the overflow check, or 0 or 1 for a compare.
    /// The overflow goes to `slow_l`. `/` and `%` send a divisor of 0 or
    /// -1 to `slow_l` and round the quotient down as Tcl does. They use
    /// `x11`, `x14`, and `x15`. `planted` leaves out the overflow check of
    /// `bin_vv` in a build with `-Djit_bug=true`.
    fn arith(e: *Emitter, op: expr.BinOp, slow_l: Label, planted: bool) Error!void {
        const s = e.s;
        if (op == .div or op == .mod) {
            try s.cbz(rcx, slow_l);
            // `cmn x10, #1`: a divisor of -1.
            try s.addsI(.zr, rcx, 1, false);
            try s.bcond(.eq, slow_l);
            try s.sdiv(rdx, rax, rcx);
            try s.msub(r10, rdx, rcx, rax);
            // A remainder with the sign opposite to the divisor moves the
            // quotient down by one and the remainder up by the divisor.
            const done = try s.newLabel();
            try s.cbz(r10, done);
            try s.opR(.eor, r11, r10, rcx, .lsl, 0);
            try s.cmpR(r11, .zr, .lsl, 0);
            try s.bcond(.ge, done);
            if (op == .div) try s.subI(rdx, rdx, 1, false) else try s.opR(.add, r10, r10, rcx, .lsl, 0);
            s.bind(done);
            try s.movRR(rax, if (op == .div) rdx else r10);
            return;
        }
        switch (op) {
            .add => try s.opR(.adds, rax, rax, rcx, .lsl, 0),
            .sub => try s.opR(.subs, rax, rax, rcx, .lsl, 0),
            .mul => {
                try s.mul(r10, rax, rcx);
                try s.smulh(r11, rax, rcx);
                try s.cmpR(r11, r10, .asr, 63);
                if (!planted) try s.bcond(.ne, slow_l);
                try s.movRR(rax, r10);
                return;
            },
            else => {
                try s.cmpR(rax, rcx, .lsl, 0);
                try s.cset(rax, compareCond(op).?);
                return;
            },
        }
        if (!planted) try s.bcond(.vs, slow_l);
    }

    /// The literal integer of `bin_vi` and `jf_vi` into `dst`.
    fn litInt(e: *Emitter, index: u32, dst: Reg) Error!void {
        try e.ldr(dst, abi.code, e.l.code_lits);
        try e.ldr(dst, dst, @as(i64, index) * e.l.value_size + e.l.value_payload);
    }

    fn binSlots(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const op: expr.BinOp = @enumFromInt(i.x);
        if (!fastOp(op)) return e.plain(helperOf(i), pc);
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.cell(i.a, r8, slow_l);
        try e.cellInt(r8, rax, slow_l);
        if (i.op == .bin_vv) {
            try e.cell(i.b, r9, slow_l);
            try e.cellInt(r9, rcx, slow_l);
        } else try e.litInt(i.b, rcx);
        try e.arith(op, slow_l, options.jit_bug and i.op == .bin_vv);
        try e.putInt(d, rax);
    }

    fn binary(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const op: expr.BinOp = @enumFromInt(i.x);
        if (!fastOp(op)) return e.plain(.binary, pc);
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.stackInt(d - 2, rax, slow_l);
        try e.stackInt(d - 1, rcx, slow_l);
        try e.arith(op, slow_l, false);
        try e.str(rax, abi.stack, e.stackOff(d - 2, e.l.value_payload));
    }

    fn jfSlots(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const cond = compareCond(@enumFromInt(i.x)).?;
        const slow_l = try e.slow(pc);
        try e.cell(i.a, r8, slow_l);
        try e.cellInt(r8, rax, slow_l);
        if (i.op == .jf_vv) {
            try e.cell(i.b, r9, slow_l);
            try e.cellInt(r9, rcx, slow_l);
        } else try e.litInt(i.b, rcx);
        try e.s.cmpR(rax, rcx, .lsl, 0);
        try e.s.bcond(a64.invert(cond), e.labels[i.c]);
    }

    fn incr(e: *Emitter, pc: u32) Error!void {
        const s = e.s;
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.cell(i.a, r8, slow_l);
        try e.cellInt(r8, rax, slow_l);
        if (i.op == .incr_value) {
            try e.stackInt(d - 1, rcx, slow_l);
        } else {
            // The step is in the instruction, never in the code: a 32-bit
            // load and a sign extension.
            try e.ldr(rcx, abi.code, e.l.code_ins);
            try e.ldrW(rcx, rcx, @as(i64, pc) * e.l.ins_size + 8);
            try s.lslI(rcx, rcx, 32);
            try s.asrI(rcx, rcx, 32);
        }
        try s.opR(.adds, rax, rax, rcx, .lsl, 0);
        try s.bcond(.vs, slow_l);
        try e.str(rax, r8, e.cellValue(e.l.value_payload));
        switch (i.op) {
            .incr => try e.putInt(d, rax),
            .incr_value => try e.str(rax, abi.stack, e.stackOff(d - 1, e.l.value_payload)),
            else => {},
        }
    }

    fn llength(e: *Emitter, pc: u32) Error!void {
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.stackTag(d - 1, e.l.tag_list, slow_l);
        try e.ldr(rax, abi.stack, e.stackOff(d - 1, e.l.value_len));
        try e.putInt(d - 1, rax);
    }

    fn lindex(e: *Emitter, pc: u32) Error!void {
        const s = e.s;
        const l = e.l;
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.stackTag(d - 2, l.tag_list, slow_l);
        try e.stackTag(d - 1, l.tag_int, slow_l);
        // An unsigned compare: a negative index is out of range.
        try e.ldr(r9, abi.stack, e.stackOff(d - 1, l.value_payload));
        try e.ldr(rcx, abi.stack, e.stackOff(d - 2, l.value_len));
        try s.cmpR(r9, rcx, .lsl, 0);
        const empty = try s.newLabel();
        const have = try s.newLabel();
        try s.bcond(.hs, empty);
        try e.scale(rax, r9);
        try e.ldr(rdx, abi.stack, e.stackOff(d - 2, l.value_payload));
        try e.ldr(rdx, rdx, l.obj_buf);
        try s.opR(.add, rax, rax, rdx, .lsl, 0);
        try s.b(have);
        s.bind(empty);
        try e.emptyAddr(rax);
        s.bind(have);
        try e.copy(abi.stack, (d - 2) * l.value_size, rax, 0);
    }

    fn lappend(e: *Emitter, pc: u32) Error!void {
        if (e.code.named) return e.plain(.lappend, pc);
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.cell(i.a, r8, slow_l);
        try e.cmpByte(r8, e.cellValue(l.value_tag), l.tag_list);
        try s.bcond(.ne, slow_l);
        try e.ldr(r9, r8, e.cellValue(l.value_payload));
        try e.ldr(r11, r8, e.cellValue(l.value_len));
        try e.ldr(r10, r9, l.obj_used);
        try s.cmpR(r11, r10, .lsl, 0);
        try s.bcond(.ne, slow_l);
        try e.ldr(r10, r9, l.obj_buf_len);
        try s.cmpR(r11, r10, .lsl, 0);
        try s.bcond(.hs, slow_l);
        try e.scale(rax, r11);
        try e.ldr(r10, r9, l.obj_buf);
        try s.opR(.add, rax, rax, r10, .lsl, 0);
        try e.copy(rax, 0, abi.stack, (d - 1) * l.value_size);
        try e.incAt(r9, l.obj_used);
        try e.incAt(r8, e.cellValue(l.value_len));
        try e.copy(abi.stack, (d - 1) * l.value_size, r8, l.var_payload);
    }

    /// Adds one to the word at `[base + off]` with `x17`.
    fn incAt(e: *Emitter, base: Reg, off: i64) Error!void {
        try e.ldr(tmp, base, off);
        try e.s.addI(tmp, tmp, 1, false);
        try e.str(tmp, base, off);
    }

    fn foreachNext(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const table = e.code.tables[i.a];
        if (e.code.named or table.len > 4) return e.branch(.foreach_next, pc, i.b);
        const s = e.s;
        const l = e.l;
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.stackTag(d - 2, l.tag_list, slow_l);
        try e.stackTag(d - 1, l.tag_int, slow_l);
        try e.ldr(rax, abi.stack, e.stackOff(d - 1, l.value_payload));
        try e.ldr(rcx, abi.stack, e.stackOff(d - 2, l.value_len));
        try s.cmpR(rax, rcx, .lsl, 0);
        try s.bcond(.hs, e.labels[i.b]);
        const regs = [_]Reg{ r8, r9, r10, r11 };
        for (table, 0..) |slot, k| try e.cell(slot, regs[k], slow_l);
        try e.stepTo(slow_l);
        for (table, 0..) |_, k| {
            const empty = try s.newLabel();
            const have = try s.newLabel();
            try e.ldr(rdx, abi.stack, e.stackOff(d - 1, l.value_payload));
            if (k > 0) try s.addI(rdx, rdx, @intCast(k), false);
            try e.ldr(rcx, abi.stack, e.stackOff(d - 2, l.value_len));
            try s.cmpR(rdx, rcx, .lsl, 0);
            try s.bcond(.hs, empty);
            try e.scale(rax, rdx);
            try e.ldr(rdx, abi.stack, e.stackOff(d - 2, l.value_payload));
            try e.ldr(rdx, rdx, l.obj_buf);
            try s.opR(.add, rax, rax, rdx, .lsl, 0);
            try s.b(have);
            s.bind(empty);
            try e.emptyAddr(rax);
            s.bind(have);
            try e.copy(regs[k], l.var_payload, rax, 0);
        }
        const at = e.stackOff(d - 1, l.value_payload);
        try e.ldr(tmp, abi.stack, at);
        try s.addI(tmp, tmp, @intCast(table.len), false);
        try e.str(tmp, abi.stack, at);
    }

    fn strEqJump(e: *Emitter, pc: u32) Error!void {
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.stackTag(d - 1, l.tag_str, slow_l);
        try e.ldr(rax, abi.code, l.code_lits);
        try e.ldr(rax, rax, @as(i64, i.a) * l.value_size + l.value_len);
        try e.ldr(rcx, abi.stack, e.stackOff(d - 1, l.value_len));
        try s.cmpR(rax, rcx, .lsl, 0);
        try s.bcond(.ne, e.labels[pc + 1]);
        try e.call(.str_bytes_eq, pc);
        try s.cmpWI(abi.ret, helpers.yes);
        try s.bcond(.eq, e.labels[i.b]);
    }

    fn lsetDrop(e: *Emitter, pc: u32) Error!void {
        if (e.code.named) return e.plain(.lset_drop, pc);
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.cellTag(i.a, r8, l.var_owned, slow_l);
        try e.cmpByte(r8, e.cellValue(l.value_tag), l.tag_list);
        try s.bcond(.ne, slow_l);
        try e.stackTag(d - 2, l.tag_int, slow_l);
        try e.ldr(r11, abi.stack, e.stackOff(d - 2, l.value_payload));
        try e.ldr(r10, r8, e.cellValue(l.value_len));
        try s.cmpR(r11, r10, .lsl, 0);
        try s.bcond(.hs, slow_l);
        try e.ldr(r9, r8, e.cellValue(l.value_payload));
        try e.scale(rax, r11);
        try e.ldr(r10, r9, l.obj_buf);
        try s.opR(.add, rax, rax, r10, .lsl, 0);
        try e.copy(rax, 0, abi.stack, (d - 1) * l.value_size);
        try e.str(.zr, r9, l.obj_dict_len);
        try e.str(.zr, r9, l.obj_index);
    }

    fn invoke(e: *Emitter, pc: u32) Error!void {
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const slow_l = try e.slow(pc);
        try e.ldr(rax, abi.code, l.code_sites);
        try e.ldr(rax, rax, @as(i64, i.a) * 8);
        try e.ldr(rcx, rax, l.cmd_resolved);
        try s.cbz(rcx, slow_l);
        try e.ldrW(rcx, rax, l.cmd_epoch);
        try e.ldrW(rdx, abi.it, l.it_epoch);
        try s.cmpWR(rcx, rdx);
        try s.bcond(.ne, slow_l);
        try e.ldr(rcx, rax, l.cmd_ns);
        try e.ldr(rdx, abi.it, l.it_ns);
        try s.cmpR(rcx, rdx, .lsl, 0);
        try s.bcond(.ne, slow_l);
        try e.plain(.call_cached, pc);
    }

    // ---- The cold code ----

    fn emitColds(e: *Emitter) Error!void {
        const s = e.s;
        var k: usize = 0;
        while (k < e.colds.items.len) : (k += 1) {
            switch (e.colds.items[k]) {
                .link => |c| {
                    s.bind(c.at);
                    try e.cmpByte(c.cell, e.l.var_tag, e.l.var_link);
                    try s.bcond(.ne, c.slow);
                    try e.ldr(c.cell, c.cell, e.l.var_payload);
                    try s.b(c.check);
                },
                .slow => |c| {
                    s.bind(c.at);
                    try e.call(c.h, c.pc);
                    try e.checkError(c.pc);
                    if (c.target) |t| try s.bcond(.eq, e.labels[t]);
                    try s.b(e.labels[c.pc + 1]);
                },
                .restore => |c| {
                    s.bind(c.at);
                    try e.incAt(abi.it, e.l.it_step_limit);
                    try s.b(c.slow);
                },
                .tier_up => |c| {
                    s.bind(c.at);
                    try e.call(.tier_up, c.pc);
                    try s.cbz(abi.ret, c.back);
                    try s.br(abi.ret);
                },
                .recheck => |c| {
                    s.bind(c.at);
                    try e.call(.recheck, c.pc);
                    try s.cmpWI(abi.ret, helpers.yes);
                    try s.bcond(.eq, e.labels[c.cold]);
                    try s.b(c.back);
                },
            }
        }
    }
};

/// The code at loop head number `k`: the counter of the loop goes down
/// by one, and at zero a cold block calls `tier_up`.
fn loopCounter(e: *Emitter, pc: u32, k: usize) Error!void {
    const s = e.s;
    try e.ctx(rax);
    try e.ldr(rax, rax, @offsetOf(jit.EnterCtx, "counters"));
    const at = @as(i64, @intCast(k)) * 4;
    try e.ldrW(rcx, rax, at);
    try s.subI(rcx, rcx, 1, false);
    try e.strW(rcx, rax, at);
    const cold = try s.newLabel();
    const back = try s.newLabel();
    try s.cbzW(rcx, cold);
    s.bind(back);
    try e.colds.append(e.a, .{ .tier_up = .{ .at = cold, .pc = pc, .back = back } });
}

/// Assembles the function of `code`. `entries` gets the offset of the
/// code of each instruction, or `no_entry`.
pub fn assemble(a: Allocator, s: *Asm, code: *const vm.Code, info: *const verify.Info, l: layout.Layout, entries: []u32, tier2: bool) Error!void {
    const n = code.ins.len;
    const labels = try a.alloc(Label, n);
    defer a.free(labels);
    const stubs = try a.alloc(?Label, n);
    defer a.free(stubs);
    @memset(stubs, null);
    const slows = try a.alloc(?Label, n);
    defer a.free(slows);
    @memset(slows, null);
    try s.reserveFor(n, 4 * n + 8);
    for (labels) |*lb| lb.* = try s.newLabel();
    const words_ok = (l.value_payload == 0 and l.value_len == 8) or (l.value_payload == 8 and l.value_len == 0);
    if (!words_ok or l.value_tag < 16 or l.value_tag >= l.value_size) return error.Layout;
    var e: Emitter = .{ .s = s, .code = code, .info = info, .l = l, .labels = labels, .stubs = stubs, .epilogue = try s.newLabel(), .a = a, .slows = slows, .tier2 = tier2 };
    defer e.colds.deinit(a);
    try e.prologue();
    for (0..n) |pc| {
        if (!info.reachable[pc]) {
            entries[pc] = no_entry;
            continue;
        }
        s.bind(labels[pc]);
        entries[pc] = s.here();
        if (tier2) if (std.mem.indexOfScalar(u32, info.loop_heads, @intCast(pc))) |k| try loopCounter(&e, @intCast(pc), k);
        try e.instruction(@intCast(pc));
    }
    var trap = false;
    for (labels) |lb| {
        if (s.isBound(lb)) continue;
        s.bind(lb);
        trap = true;
    }
    if (trap) try s.udf(0);
    try e.emitColds();
    try e.emitStubs();
    try e.emitEpilogue();
    try s.finish();
}

//! The templates of tier 1 for x86-64.
//!
//! The function of a `Code` has one fixed prologue: it saves `rbp` and
//! the five pinned registers, stores the context pointer at
//! `[rbp - 48]`, loads the pinned registers from the context, and jumps
//! to the target address of the context. The stack pointer is then
//! 16-byte aligned for each call, and the frame is 64 bytes with the
//! return address. One epilogue restores the registers and returns
//! `eax`.
//!
//! Each reachable instruction gets its code in the order of the
//! bytecode, so an instruction falls through to the next one. Its code
//! calls its helper with the context, its address, and its static stack
//! depth. A result above 1 is an error: a stub after the last
//! instruction writes the address and the depth to the context and
//! returns status 1. An instruction with two successors jumps to its
//! target on result 1. An unreachable instruction has no code.
//!
//! No value of a script is an immediate operand. The immediates are
//! bytecode addresses, stack depths, helper numbers, and field offsets,
//! and the verifier bounds each one.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vm = @import("../vm.zig");
const x64 = @import("x64.zig");
const abi = @import("abi.zig");
const verify = @import("verify.zig");
const helpers = @import("helpers.zig");
const layout = @import("layout.zig");
const jit = @import("../jit.zig");
const expr = @import("../expr.zig");
const options = @import("build_options");

const Allocator = std.mem.Allocator;
const Asm = x64.Asm;
const Label = x64.Label;
const Mem = x64.Mem;
const Helper = helpers.Helper;

pub const Error = Allocator.Error || error{ Range, UnboundLabel, Layout };

const Reg = x64.Reg;
const Cond = x64.Cond;

/// A piece of code after the last instruction, out of the hot path.
const Cold = union(enum) {
    /// The cell in `cell` is not a plain value. A link goes to its target
    /// and back to `check`. Each other tag goes to `slow`.
    link: struct { at: Label, cell: Reg, check: Label, slow: Label },
    /// The slow path of instruction `pc`: a call of its helper, then a
    /// jump to the next instruction, or to `target` on result 1.
    slow: struct { at: Label, pc: u32, h: Helper, target: ?u32 },
    /// The memory check of a step failed after the decrement: restore
    /// the count, then the slow path.
    restore: struct { at: Label, slow: Label },
    /// The epoch changed: `vm.guardJumps` decides, then the step.
    recheck: struct { at: Label, pc: u32, cold: u32, back: Label },
    /// The counter of a loop head reached zero: `tier_up` gives the
    /// address of the tier 2 code of the loop, or zero.
    tier_up: struct { at: Label, pc: u32, back: Label },
};

/// The status values of a function.
pub const status_done = 0;
pub const status_error = 1;
pub const status_exit = 2;

/// The entry offset of an instruction with no code.
pub const no_entry = std.math.maxInt(u32);

const ctx_pc: i32 = @offsetOf(jit.EnterCtx, "pc");
const ctx_sp: i32 = @offsetOf(jit.EnterCtx, "sp");

fn ctxField(comptime name: []const u8) Mem {
    return .{ .base = abi.arg0, .disp = @offsetOf(jit.EnterCtx, name) };
}

pub const Emitter = struct {
    s: *Asm,
    code: *const vm.Code,
    info: *const verify.Info,
    l: layout.Layout,
    /// The label of each instruction.
    labels: []Label,
    /// The error stub of each instruction, made on first use.
    stubs: []?Label,
    epilogue: Label,
    a: Allocator,
    colds: std.ArrayList(Cold) = .empty,
    /// The slow path of each instruction, made on first use.
    slows: []?Label,
    /// True when each loop head counts its passes for tier 2.
    tier2: bool = false,

    fn ctxSlot() Mem {
        return .{ .base = abi.fp, .disp = abi.ctx_slot };
    }

    fn prologue(e: *Emitter) Error!void {
        const s = e.s;
        try s.push(.rbp);
        try s.movRR(.rbp, .rsp);
        for (abi.saved) |r| try s.push(r);
        try s.push(abi.arg0);
        try s.movRM(abi.it, ctxField("it"));
        try s.movRM(abi.code, ctxField("code"));
        try s.movRM(abi.frame, ctxField("frame"));
        try s.movRM(abi.stack, ctxField("stack"));
        try s.movRM(abi.helpers, ctxField("helpers"));
        try s.jmpM(ctxField("target"));
    }

    fn emitEpilogue(e: *Emitter) Error!void {
        const s = e.s;
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

    /// The error stub of instruction `pc`.
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
            try s.movRM(.rcx, ctxSlot());
            try s.movMI32(.{ .base = .rcx, .disp = ctx_pc }, @intCast(pc));
            try s.movMI32(.{ .base = .rcx, .disp = ctx_sp }, e.info.depth[pc]);
            try s.movRI32(.rax, status_error);
            try s.jmp(e.epilogue);
        }
    }

    /// Calls helper `h` for instruction `pc`: the result is in `eax`.
    pub fn call(e: *Emitter, h: Helper, pc: u32) Error!void {
        const s = e.s;
        try s.movRM(abi.arg0, ctxSlot());
        try s.movRI32(abi.arg1, @intCast(pc));
        try s.movRI32(abi.arg2, e.info.depth[pc]);
        try s.callM(try x64.at(abi.helpers, 8 * @as(i64, @intFromEnum(h))));
    }

    /// Jumps to the error stub of `pc` when `eax` is above 1. A helper
    /// returns `u32`, and the ABI leaves the high half of `rax`
    /// undefined, so the compare reads only `eax`.
    pub fn checkError(e: *Emitter, pc: u32) Error!void {
        try e.s.aluRI32(.cmp, abi.ret, helpers.yes);
        try e.s.jcc(.a, try e.stub(pc));
    }

    /// A helper call with no jump.
    fn plain(e: *Emitter, h: Helper, pc: u32) Error!void {
        try e.call(h, pc);
        try e.checkError(pc);
    }

    /// A helper call that jumps to `target` on result 1.
    fn branch(e: *Emitter, h: Helper, pc: u32, target: u32) Error!void {
        try e.call(h, pc);
        try e.checkError(pc);
        try e.s.jcc(.e, e.labels[target]);
    }

    fn ret(e: *Emitter, pc: u32) Error!void {
        const s = e.s;
        try s.movRM(.rcx, ctxSlot());
        try s.movMI32(.{ .base = .rcx, .disp = ctx_sp }, e.info.depth[pc]);
        try s.movRI32(.rax, status_done);
        try s.jmp(e.epilogue);
    }

    fn instruction(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        // A named Code reads each variable by its name: a helper call.
        if (e.code.named) switch (i.op) {
            .load, .store, .store_pop, .incr, .incr_drop, .incr_value, .bin_vv, .bin_vi => return e.plain(helperOf(i), pc),
            .jf_vv, .jf_vi => return e.branch(helperOf(i), pc, i.c),
            else => {},
        };
        switch (i.op) {
            .pop => {},
            .jump => try e.s.jmp(e.labels[i.a]),
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
            .lassign_drop => try e.lassignDrop(pc),
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

    /// The helper of the whole instruction `i`.
    pub fn helperOf(i: vm.Ins) Helper {
        return switch (i.op) {
            .ret => unreachable,
            .access => accessHelper(i.x),
            inline else => |o| @field(Helper, @tagName(o)),
        };
    }

    /// The slow path of `pc`: the helper of the whole instruction.
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

    fn stackAt(e: *Emitter, k: i64, off: i64) Error!Mem {
        return x64.at(abi.stack, k * e.l.value_size + off);
    }

    fn itAt(off: u32) Mem {
        return .{ .base = abi.it, .disp = @intCast(off) };
    }

    /// Loads the cell of `slot` into `r`. A cell that is not a plain
    /// value follows its links in a cold loop, and each other cell goes
    /// to `slow_l`. The tag compare reads the full byte: a byte with high
    /// bits that the mask drops also goes to the slow path.
    fn cell(e: *Emitter, slot: u32, r: Reg, slow_l: Label) Error!void {
        return e.cellTag(slot, r, e.l.var_val, slow_l);
    }

    /// `cell` for a cell with the tag `want`.
    fn cellTag(e: *Emitter, slot: u32, r: Reg, want: u8, slow_l: Label) Error!void {
        const s = e.s;
        const l = e.l;
        try s.movRM(r, .{ .base = abi.frame, .disp = @intCast(l.frame_items) });
        try s.movRM(r, try x64.at(r, @as(i64, slot) * l.entry_size + l.entry_cell));
        const check = try s.newLabel();
        s.bind(check);
        try s.cmpMI8(.{ .base = r, .disp = @intCast(l.var_tag) }, @intCast(want));
        const link = try s.newLabel();
        try s.jcc(.ne, link);
        try e.colds.append(e.a, .{ .link = .{ .at = link, .cell = r, .check = check, .slow = slow_l } });
    }

    /// The memory operand of a field of the Value of cell `r`.
    fn cellValue(e: *Emitter, r: Reg, off: u32) Mem {
        return .{ .base = r, .disp = @intCast(e.l.var_payload + off) };
    }

    /// Loads the integer of the value of cell `r` into `dst`. Another
    /// kind goes to `slow_l`.
    fn cellInt(e: *Emitter, r: Reg, dst: Reg, slow_l: Label) Error!void {
        try e.s.cmpMI8(e.cellValue(r, e.l.value_tag), @intCast(e.l.tag_int));
        try e.s.jcc(.ne, slow_l);
        try e.s.movRM(dst, e.cellValue(r, e.l.value_payload));
    }

    /// Loads the integer of stack place `k` into `dst`. Another kind
    /// goes to `slow_l`.
    fn stackInt(e: *Emitter, k: i64, dst: Reg, slow_l: Label) Error!void {
        try e.s.cmpMI8(try e.stackAt(k, e.l.value_tag), @intCast(e.l.tag_int));
        try e.s.jcc(.ne, slow_l);
        try e.s.movRM(dst, try e.stackAt(k, e.l.value_payload));
    }

    /// Writes the integer in `src` to stack place `k`.
    fn putInt(e: *Emitter, k: i64, src: Reg) Error!void {
        try e.s.movMR(try e.stackAt(k, e.l.value_payload), src);
        try e.s.movMI8(try e.stackAt(k, e.l.value_tag), @intCast(e.l.tag_int));
    }

    /// Copies a Value: the two payload words and the tag byte. It uses
    /// `rcx`, `rdx`, and `r10`.
    fn copy(e: *Emitter, dst: Reg, dst_off: i64, src: Reg, src_off: i64) Error!void {
        const s = e.s;
        try s.movRM(.rcx, try x64.at(src, src_off));
        try s.movRM(.rdx, try x64.at(src, src_off + 8));
        try s.movzxRM8(.r10, try x64.at(src, src_off + e.l.value_tag));
        try s.movMR(try x64.at(dst, dst_off), .rcx);
        try s.movMR(try x64.at(dst, dst_off + 8), .rdx);
        try s.movMR8(try x64.at(dst, dst_off + e.l.value_tag), .r10);
    }

    /// `copy` with `rcx` as the one scratch register.
    fn copyRcx(e: *Emitter, dst: Reg, dst_off: i64, src: Reg, src_off: i64) Error!void {
        const s = e.s;
        try s.movRM(.rcx, try x64.at(src, src_off));
        try s.movMR(try x64.at(dst, dst_off), .rcx);
        try s.movRM(.rcx, try x64.at(src, src_off + 8));
        try s.movMR(try x64.at(dst, dst_off + 8), .rcx);
        try s.movzxRM8(.rcx, try x64.at(src, src_off + e.l.value_tag));
        try s.movMR8(try x64.at(dst, dst_off + e.l.value_tag), .rcx);
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

    /// Jumps to `l` when the tag of stack place `k` is not `tag`.
    fn stackTag(e: *Emitter, k: i64, tag: u8, l: Label) Error!void {
        try e.s.cmpMI8(try e.stackAt(k, e.l.value_tag), @intCast(tag));
        try e.s.jcc(.ne, l);
    }

    /// Loads the address of `Value.empty` into `r`.
    fn emptyAddr(e: *Emitter, r: Reg) Error!void {
        try e.s.movRM(r, ctxSlot());
        try e.s.movRM(r, .{ .base = r, .disp = @offsetOf(jit.EnterCtx, "empty") });
    }

    // ---- The templates ----

    /// The step limit and the memory limit. `h` is the helper that runs
    /// the whole check on the slow path: it sees the state before the
    /// check.
    fn step(e: *Emitter, pc: u32, comptime h: Helper) Error!void {
        const slow_l = try e.s.newLabel();
        try e.colds.append(e.a, .{ .slow = .{ .at = slow_l, .pc = pc, .h = h, .target = null } });
        return e.stepTo(slow_l);
    }

    /// The step check with the slow path `slow_l`. It uses `rax`.
    fn stepTo(e: *Emitter, slow_l: Label) Error!void {
        const s = e.s;
        const l = e.l;
        try s.aluMI(.cmp, itAt(l.it_step_limit), 0);
        try s.jcc(.e, slow_l);
        try s.decM(itAt(l.it_step_limit));
        try s.movRM(.rax, itAt(l.it_mem_trip));
        try s.aluRM(.cmp, .rax, itAt(l.it_mem_limit));
        const restore = try s.newLabel();
        try s.jcc(.ae, restore);
        try e.colds.append(e.a, .{ .restore = .{ .at = restore, .slow = slow_l } });
    }

    fn guard(e: *Emitter, pc: u32) Error!void {
        const s = e.s;
        const l = e.l;
        try s.movRM32(.rax, itAt(l.it_epoch));
        try s.aluRM32(.cmp, .rax, itAt(l.it_safe_epoch));
        const recheck = try s.newLabel();
        const back = try s.newLabel();
        try s.jcc(.ne, recheck);
        try e.colds.append(e.a, .{ .recheck = .{ .at = recheck, .pc = pc, .cold = e.code.ins[pc].a, .back = back } });
        s.bind(back);
        try e.step(pc, .step);
    }

    fn push(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        try e.s.movRM(.rax, .{ .base = abi.code, .disp = @intCast(e.l.code_lits) });
        try e.copy(abi.stack, d * e.l.value_size, .rax, @as(i64, i.a) * e.l.value_size);
    }

    fn pushEmpty(e: *Emitter, pc: u32) Error!void {
        const d: i64 = e.info.depth[pc];
        try e.s.movRM(.rax, ctxSlot());
        try e.s.movRM(.rax, .{ .base = .rax, .disp = @offsetOf(jit.EnterCtx, "empty") });
        try e.copy(abi.stack, d * e.l.value_size, .rax, 0);
    }

    fn load(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        if (i.x != 1) {
            try e.cell(i.a, .rax, try e.slow(pc));
            try e.copy(abi.stack, d * e.l.value_size, .rax, e.l.var_payload);
            return;
        }
        // A load for an access: an owned list stays owned, as in
        // `vm.loadSlow`. Both forms have the value at the same offset.
        const owned = try e.s.newLabel();
        const done = try e.s.newLabel();
        try e.cell(i.a, .rax, owned);
        try e.copy(abi.stack, d * e.l.value_size, .rax, e.l.var_payload);
        try e.s.jmp(done);
        e.s.bind(owned);
        try e.cellTag(i.a, .rax, e.l.var_owned, try e.slow(pc));
        try e.copy(abi.stack, d * e.l.value_size, .rax, e.l.var_payload);
        e.s.bind(done);
    }

    fn store(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        try e.cell(i.a, .rax, try e.slow(pc));
        try e.copy(.rax, e.l.var_payload, abi.stack, (d - 1) * e.l.value_size);
    }

    fn jumpCond(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        try e.stackInt(d - 1, .rax, try e.slow(pc));
        try e.s.aluRI(.cmp, .rax, 0);
        try e.s.jcc(if (i.op == .jump_false) .e else .ne, e.labels[i.a]);
    }

    fn toBool(e: *Emitter, pc: u32) Error!void {
        const d: i64 = e.info.depth[pc];
        try e.stackInt(d - 1, .rax, try e.slow(pc));
        try e.s.aluRI(.cmp, .rax, 0);
        try e.s.setcc(.ne, .rax);
        try e.s.movzxRR8(.rax, .rax);
        try e.s.movMR(try e.stackAt(d - 1, e.l.value_payload), .rax);
    }

    /// The condition of a compare that is true, or null for another
    /// operator.
    fn compareCond(op: expr.BinOp) ?Cond {
        return switch (op) {
            .lt => .l,
            .le => .le,
            .gt => .g,
            .ge => .ge,
            .eq => .e,
            .ne => .ne,
            else => null,
        };
    }

    fn negate(c: Cond) Cond {
        return @enumFromInt(@intFromEnum(c) ^ 1);
    }

    /// True for the operators of the fast path: `+`, `-`, `*`, and the
    /// six compares.
    fn fastOp(op: expr.BinOp) bool {
        return switch (op) {
            .add, .sub, .mul, .div, .mod => true,
            else => compareCond(op) != null,
        };
    }

    /// `rax = rax op rcx` with the overflow check, or 0 or 1 for a
    /// compare. The overflow goes to `slow_l`. `/` and `%` send a
    /// divisor of 0 or -1 to `slow_l`, and round the quotient down as
    /// Tcl does. They use `rdx` and `r10`. `planted` is true only for
    /// `bin_vv` in a build with `-Djit_bug=true`: the overflow check is
    /// then left out, so the test of the fuzzer has a bug to find.
    fn arith(e: *Emitter, op: expr.BinOp, slow_l: Label, planted: bool) Error!void {
        const s = e.s;
        if (op == .div or op == .mod) {
            try s.aluRI(.cmp, .rcx, 0);
            try s.jcc(.e, slow_l);
            try s.aluRI(.cmp, .rcx, -1);
            try s.jcc(.e, slow_l);
            try s.cqo();
            try s.idiv(.rcx);
            // A remainder with the sign opposite to the divisor moves the
            // quotient down by one and the remainder up by the divisor.
            const done = try s.newLabel();
            try s.aluRI(.cmp, .rdx, 0);
            try s.jcc(.e, done);
            try s.movRR(.r10, .rdx);
            try s.aluRR(.xor, .r10, .rcx);
            try s.jcc(.ns, done);
            if (op == .div) try s.aluRI(.sub, .rax, 1) else try s.aluRR(.add, .rdx, .rcx);
            s.bind(done);
            if (op == .mod) try s.movRR(.rax, .rdx);
            return;
        }
        switch (op) {
            .add => try s.aluRR(.add, .rax, .rcx),
            .sub => try s.aluRR(.sub, .rax, .rcx),
            .mul => try s.imulRR(.rax, .rcx),
            else => {
                try s.aluRR(.cmp, .rax, .rcx);
                try s.setcc(compareCond(op).?, .rax);
                try s.movzxRR8(.rax, .rax);
                return;
            },
        }
        if (!planted) try s.jcc(.o, slow_l);
    }

    /// The literal integer of `bin_vi` and `jf_vi` into `dst`. The
    /// verifier proved that the literal is an integer.
    fn litInt(e: *Emitter, index: u32, dst: Reg) Error!void {
        try e.s.movRM(dst, .{ .base = abi.code, .disp = @intCast(e.l.code_lits) });
        try e.s.movRM(dst, try x64.at(dst, @as(i64, index) * e.l.value_size + e.l.value_payload));
    }

    fn binSlots(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const op: expr.BinOp = @enumFromInt(i.x);
        if (!fastOp(op)) return e.plain(helperOf(i), pc);
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.cell(i.a, .r8, slow_l);
        try e.cellInt(.r8, .rax, slow_l);
        if (i.op == .bin_vv) {
            try e.cell(i.b, .r9, slow_l);
            try e.cellInt(.r9, .rcx, slow_l);
        } else try e.litInt(i.b, .rcx);
        try e.arith(op, slow_l, options.jit_bug and i.op == .bin_vv);
        try e.putInt(d, .rax);
    }

    fn binary(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const op: expr.BinOp = @enumFromInt(i.x);
        if (!fastOp(op)) return e.plain(.binary, pc);
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.stackInt(d - 2, .rax, slow_l);
        try e.stackInt(d - 1, .rcx, slow_l);
        try e.arith(op, slow_l, false);
        try e.s.movMR(try e.stackAt(d - 2, e.l.value_payload), .rax);
    }

    fn jfSlots(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const cond = compareCond(@enumFromInt(i.x)).?;
        const slow_l = try e.slow(pc);
        try e.cell(i.a, .r8, slow_l);
        try e.cellInt(.r8, .rax, slow_l);
        if (i.op == .jf_vv) {
            try e.cell(i.b, .r9, slow_l);
            try e.cellInt(.r9, .rcx, slow_l);
        } else try e.litInt(i.b, .rcx);
        try e.s.aluRR(.cmp, .rax, .rcx);
        try e.s.jcc(negate(cond), e.labels[i.c]);
    }

    fn incr(e: *Emitter, pc: u32) Error!void {
        const s = e.s;
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.cell(i.a, .r8, slow_l);
        try e.cellInt(.r8, .rax, slow_l);
        if (i.op == .incr_value) {
            try e.stackInt(d - 1, .rcx, slow_l);
        } else {
            // The step is in the instruction, never in the code.
            try s.movRM(.rcx, .{ .base = abi.code, .disp = @intCast(e.l.code_ins) });
            try s.movsxdRM(.rcx, try x64.at(.rcx, @as(i64, pc) * e.l.ins_size + 8));
        }
        try s.aluRR(.add, .rax, .rcx);
        try s.jcc(.o, slow_l);
        try s.movMR(e.cellValue(.r8, e.l.value_payload), .rax);
        switch (i.op) {
            .incr => try e.putInt(d, .rax),
            .incr_value => try s.movMR(try e.stackAt(d - 1, e.l.value_payload), .rax),
            else => {},
        }
    }

    /// `llength` of a list value: its length.
    fn llength(e: *Emitter, pc: u32) Error!void {
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.stackTag(d - 1, e.l.tag_list, slow_l);
        try e.s.movRM(.rax, try e.stackAt(d - 1, e.l.value_len));
        try e.putInt(d - 1, .rax);
    }

    /// `lindex` of a list value and an integer: the item, or the empty
    /// string for an index out of range.
    fn lindex(e: *Emitter, pc: u32) Error!void {
        const s = e.s;
        const l = e.l;
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.stackTag(d - 2, l.tag_list, slow_l);
        try e.stackTag(d - 1, l.tag_int, slow_l);
        // An unsigned compare: a negative index is out of range.
        try s.movRM(.r9, try e.stackAt(d - 1, l.value_payload));
        try s.aluRM(.cmp, .r9, try e.stackAt(d - 2, l.value_len));
        const empty = try s.newLabel();
        const have = try s.newLabel();
        try s.jcc(.ae, empty);
        try e.scale(.rax, .r9);
        try s.movRM(.rdx, try e.stackAt(d - 2, l.value_payload));
        try s.aluRM(.add, .rax, try x64.at(.rdx, l.obj_buf));
        try s.jmp(have);
        s.bind(empty);
        try e.emptyAddr(.rax);
        s.bind(have);
        try e.copy(abi.stack, (d - 2) * l.value_size, .rax, 0);
    }

    /// `lappend` of one value to a list with room at its end: the value
    /// goes to the buffer first, then `used` and the length grow.
    fn lappend(e: *Emitter, pc: u32) Error!void {
        if (e.code.named) return e.plain(.lappend, pc);
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.cell(i.a, .r8, slow_l);
        try s.cmpMI8(e.cellValue(.r8, l.value_tag), @intCast(l.tag_list));
        try s.jcc(.ne, slow_l);
        try s.movRM(.r9, e.cellValue(.r8, l.value_payload));
        try s.movRM(.r11, e.cellValue(.r8, l.value_len));
        try s.aluRM(.cmp, .r11, try x64.at(.r9, l.obj_used));
        try s.jcc(.ne, slow_l);
        try s.aluRM(.cmp, .r11, try x64.at(.r9, l.obj_buf_len));
        try s.jcc(.ae, slow_l);
        try e.scale(.rax, .r11);
        try s.aluRM(.add, .rax, try x64.at(.r9, l.obj_buf));
        try e.copy(.rax, 0, abi.stack, (d - 1) * l.value_size);
        try s.incM(try x64.at(.r9, l.obj_used));
        try s.incM(e.cellValue(.r8, l.value_len));
        try e.copy(abi.stack, (d - 1) * l.value_size, .r8, l.var_payload);
    }

    /// `foreach_next` with a list and an index on the stack and at most
    /// four plain cells. The step comes after the bound check and before
    /// the first store, as in the interpreter. Each check is before the
    /// step, so the slow path sees the state before the instruction.
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
        try s.movRM(.rax, try e.stackAt(d - 1, l.value_payload));
        try s.aluRM(.cmp, .rax, try e.stackAt(d - 2, l.value_len));
        try s.jcc(.ae, e.labels[i.b]);
        const regs = [_]Reg{ .r8, .r9, .r10, .r11 };
        for (table, 0..) |slot, k| try e.cell(slot, regs[k], slow_l);
        try e.stepTo(slow_l);
        for (table, 0..) |_, k| {
            const empty = try s.newLabel();
            const have = try s.newLabel();
            try s.movRM(.rdx, try e.stackAt(d - 1, l.value_payload));
            if (k > 0) try s.aluRI(.add, .rdx, @intCast(k));
            try s.aluRM(.cmp, .rdx, try e.stackAt(d - 2, l.value_len));
            try s.jcc(.ae, empty);
            try e.scale(.rax, .rdx);
            try s.movRM(.rdx, try e.stackAt(d - 2, l.value_payload));
            try s.aluRM(.add, .rax, try x64.at(.rdx, l.obj_buf));
            try s.jmp(have);
            s.bind(empty);
            try e.emptyAddr(.rax);
            s.bind(have);
            try e.copyRcx(regs[k], l.var_payload, .rax, 0);
        }
        try s.aluMI(.add, try e.stackAt(d - 1, l.value_payload), @intCast(table.len));
    }

    /// `lassign_drop` of a list value to at most four slots with plain
    /// cells: each cell gets its item, or the empty string after the end
    /// of the list. The checks of all cells come before the first store,
    /// so the helper runs from the start when one check fails.
    fn lassignDrop(e: *Emitter, pc: u32) Error!void {
        const i = e.code.ins[pc];
        const table = e.code.tables[i.a];
        if (e.code.named or table.len > 4) return e.plain(.lassign_drop, pc);
        const s = e.s;
        const l = e.l;
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.stackTag(d - 1, l.tag_list, slow_l);
        const regs = [_]Reg{ .r8, .r9, .r10, .r11 };
        for (table, 0..) |slot, k| try e.cell(slot, regs[k], slow_l);
        for (table, 0..) |_, k| {
            const empty = try s.newLabel();
            const have = try s.newLabel();
            try s.movRI32(.rdx, @intCast(k));
            try s.aluRM(.cmp, .rdx, try e.stackAt(d - 1, l.value_len));
            try s.jcc(.ae, empty);
            try e.scale(.rax, .rdx);
            try s.movRM(.rdx, try e.stackAt(d - 1, l.value_payload));
            try s.aluRM(.add, .rax, try x64.at(.rdx, l.obj_buf));
            try s.jmp(have);
            s.bind(empty);
            try e.emptyAddr(.rax);
            s.bind(have);
            try e.copyRcx(regs[k], l.var_payload, .rax, 0);
        }
    }

    /// `str_eq_jump` on a string: strings of other lengths differ, and a
    /// compare helper with no error path checks strings of equal length.
    fn strEqJump(e: *Emitter, pc: u32) Error!void {
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.stackTag(d - 1, l.tag_str, slow_l);
        try s.movRM(.rax, .{ .base = abi.code, .disp = @intCast(l.code_lits) });
        try s.movRM(.rax, try x64.at(.rax, @as(i64, i.a) * l.value_size + l.value_len));
        try s.aluRM(.cmp, .rax, try e.stackAt(d - 1, l.value_len));
        try s.jcc(.ne, e.labels[pc + 1]);
        try e.call(.str_bytes_eq, pc);
        try s.aluRI32(.cmp, abi.ret, helpers.yes);
        try s.jcc(.e, e.labels[i.b]);
    }

    /// `lset_drop` on a cell that owns its list, with an integer index in
    /// range: the value goes to the buffer, and the marks of a dict go.
    fn lsetDrop(e: *Emitter, pc: u32) Error!void {
        if (e.code.named) return e.plain(.lset_drop, pc);
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.cellTag(i.a, .r8, l.var_owned, slow_l);
        try s.cmpMI8(e.cellValue(.r8, l.value_tag), @intCast(l.tag_list));
        try s.jcc(.ne, slow_l);
        try e.stackTag(d - 2, l.tag_int, slow_l);
        try s.movRM(.r11, try e.stackAt(d - 2, l.value_payload));
        try s.aluRM(.cmp, .r11, e.cellValue(.r8, l.value_len));
        try s.jcc(.ae, slow_l);
        try s.movRM(.r9, e.cellValue(.r8, l.value_payload));
        try e.scale(.rax, .r11);
        try s.aluRM(.add, .rax, try x64.at(.r9, l.obj_buf));
        try e.copy(.rax, 0, abi.stack, (d - 1) * l.value_size);
        try s.movMI(try x64.at(.r9, l.obj_dict_len), 0);
        try s.movMI(try x64.at(.r9, l.obj_index), 0);
    }

    /// `invoke`: the checks of `Interp.resolve` on the site inline. A
    /// valid site calls `call_direct`, and a miss calls the helper of
    /// `invoke`, which resolves the name.
    fn invoke(e: *Emitter, pc: u32) Error!void {
        const s = e.s;
        const l = e.l;
        const i = e.code.ins[pc];
        const slow_l = try e.slow(pc);
        try s.movRM(.rax, .{ .base = abi.code, .disp = @intCast(l.code_sites) });
        try s.movRM(.rax, try x64.at(.rax, @as(i64, i.a) * 8));
        try s.aluMI(.cmp, try x64.at(.rax, l.cmd_resolved), 0);
        try s.jcc(.e, slow_l);
        try s.movRM32(.rcx, try x64.at(.rax, l.cmd_epoch));
        try s.aluRM32(.cmp, .rcx, itAt(l.it_epoch));
        try s.jcc(.ne, slow_l);
        try s.movRM(.rcx, try x64.at(.rax, l.cmd_ns));
        try s.aluRM(.cmp, .rcx, itAt(l.it_ns));
        try s.jcc(.ne, slow_l);
        try e.plain(.call_direct, pc);
    }

    // ---- The cold code ----

    fn emitColds(e: *Emitter) Error!void {
        const s = e.s;
        // The list grows while it is read: a slow path of a cold piece
        // can add no other piece, so the index loop ends.
        var k: usize = 0;
        while (k < e.colds.items.len) : (k += 1) {
            switch (e.colds.items[k]) {
                .link => |c| {
                    s.bind(c.at);
                    try s.cmpMI8(.{ .base = c.cell, .disp = @intCast(e.l.var_tag) }, @intCast(e.l.var_link));
                    try s.jcc(.ne, c.slow);
                    try s.movRM(c.cell, .{ .base = c.cell, .disp = @intCast(e.l.var_payload) });
                    try s.jmp(c.check);
                },
                .slow => |c| {
                    s.bind(c.at);
                    try e.call(c.h, c.pc);
                    try e.checkError(c.pc);
                    if (c.target) |t| try s.jcc(.e, e.labels[t]);
                    try s.jmp(e.labels[c.pc + 1]);
                },
                .restore => |c| {
                    s.bind(c.at);
                    try s.incM(itAt(e.l.it_step_limit));
                    try s.jmp(c.slow);
                },
                .tier_up => |c| {
                    s.bind(c.at);
                    try e.call(.tier_up, c.pc);
                    try s.aluRI(.cmp, .rax, 0);
                    try s.jcc(.e, c.back);
                    try s.jmpR(.rax);
                },
                .recheck => |c| {
                    s.bind(c.at);
                    try e.call(.recheck, c.pc);
                    try s.aluRI32(.cmp, abi.ret, helpers.yes);
                    try s.jcc(.e, e.labels[c.cold]);
                    try s.jmp(c.back);
                },
            }
        }
    }
};

/// Assembles the function of `code`. `entries` gets the offset of the
/// code of each instruction, or `no_entry`.
/// The code at loop head number `k`: the counter of the loop goes down
/// by one, and at zero a cold block calls `tier_up`. The counters are an
/// array of the function, reached through the context.
fn loopCounter(e: *Emitter, pc: u32, k: usize) Error!void {
    const s = e.s;
    try s.movRM(.rax, Emitter.ctxSlot());
    try s.movRM(.rax, .{ .base = .rax, .disp = @offsetOf(jit.EnterCtx, "counters") });
    try s.aluMI32(.sub, try x64.at(.rax, @as(i64, @intCast(k)) * 4), 1);
    const cold = try s.newLabel();
    const back = try s.newLabel();
    try s.jcc(.e, cold);
    s.bind(back);
    try e.colds.append(e.a, .{ .tier_up = .{ .at = cold, .pc = pc, .back = back } });
}

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
    // A copy of a Value moves the words at 0 and 8 and the tag byte.
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
    // An unreachable instruction has no code, and no reachable code
    // jumps to it. Its label goes to a trap.
    var trap = false;
    for (labels) |lb| {
        if (s.isBound(lb)) continue;
        s.bind(lb);
        trap = true;
    }
    if (trap) try s.ud2();
    try e.emitColds();
    try e.emitStubs();
    try e.emitEpilogue();
    try s.finish();
}

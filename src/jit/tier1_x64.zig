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
            .str_eq_jump => try e.branch(.str_eq_jump, pc, i.b),
            .foreach_next => try e.branch(.foreach_next, pc, i.b),
            .access => try e.plain(switch (i.x) {
                0 => .llength,
                1 => .lindex,
                2 => .string_length,
                else => .string_index,
            }, pc),
            inline else => |op| try e.plain(@field(Helper, @tagName(op)), pc),
        }
    }

    // ---- The parts of the fast paths ----

    fn helperOf(op: vm.Op) Helper {
        return switch (op) {
            .access, .ret => unreachable,
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
            else => null,
        };
        try e.colds.append(e.a, .{ .slow = .{ .at = l, .pc = pc, .h = helperOf(i.op), .target = target } });
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
        const s = e.s;
        const l = e.l;
        try s.movRM(r, .{ .base = abi.frame, .disp = @intCast(l.frame_items) });
        try s.movRM(r, try x64.at(r, @as(i64, slot) * l.entry_size + l.entry_cell));
        const check = try s.newLabel();
        s.bind(check);
        try s.cmpMI8(.{ .base = r, .disp = @intCast(l.var_tag) }, @intCast(l.var_val));
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

    /// Copies a Value: the two payload words and the tag byte.
    fn copy(e: *Emitter, dst: Reg, dst_off: i64, src: Reg, src_off: i64) Error!void {
        const s = e.s;
        try s.movRM(.rcx, try x64.at(src, src_off));
        try s.movRM(.rdx, try x64.at(src, src_off + 8));
        try s.movzxRM8(.r8, try x64.at(src, src_off + e.l.value_tag));
        try s.movMR(try x64.at(dst, dst_off), .rcx);
        try s.movMR(try x64.at(dst, dst_off + 8), .rdx);
        try s.movMR8(try x64.at(dst, dst_off + e.l.value_tag), .r8);
    }

    // ---- The templates ----

    /// The step limit and the memory limit. `h` is the helper that runs
    /// the whole check on the slow path: it sees the state before the
    /// check.
    fn step(e: *Emitter, pc: u32, comptime h: Helper) Error!void {
        const s = e.s;
        const l = e.l;
        const slow_l = try s.newLabel();
        try e.colds.append(e.a, .{ .slow = .{ .at = slow_l, .pc = pc, .h = h, .target = null } });
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
        try e.cell(i.a, .rax, try e.slow(pc));
        try e.copy(abi.stack, d * e.l.value_size, .rax, e.l.var_payload);
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
            .add, .sub, .mul => true,
            else => compareCond(op) != null,
        };
    }

    /// `rax = rax op rcx` with the overflow check, or 0 or 1 for a
    /// compare. The overflow goes to `slow_l`.
    fn arith(e: *Emitter, op: expr.BinOp, slow_l: Label) Error!void {
        const s = e.s;
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
        try s.jcc(.o, slow_l);
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
        if (!fastOp(op)) return e.plain(helperOf(i.op), pc);
        const d: i64 = e.info.depth[pc];
        const slow_l = try e.slow(pc);
        try e.cell(i.a, .r8, slow_l);
        try e.cellInt(.r8, .rax, slow_l);
        if (i.op == .bin_vv) {
            try e.cell(i.b, .r9, slow_l);
            try e.cellInt(.r9, .rcx, slow_l);
        } else try e.litInt(i.b, .rcx);
        try e.arith(op, slow_l);
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
        try e.arith(op, slow_l);
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
pub fn assemble(a: Allocator, s: *Asm, code: *const vm.Code, info: *const verify.Info, l: layout.Layout, entries: []u32) Error!void {
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
    var e: Emitter = .{ .s = s, .code = code, .info = info, .l = l, .labels = labels, .stubs = stubs, .epilogue = try s.newLabel(), .a = a, .slows = slows };
    defer e.colds.deinit(a);
    try e.prologue();
    for (0..n) |pc| {
        if (!info.reachable[pc]) {
            entries[pc] = no_entry;
            continue;
        }
        s.bind(labels[pc]);
        entries[pc] = s.here();
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

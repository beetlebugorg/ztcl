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

const Allocator = std.mem.Allocator;
const Asm = x64.Asm;
const Label = x64.Label;
const Mem = x64.Mem;
const Helper = helpers.Helper;

pub const Error = Allocator.Error || error{ Range, UnboundLabel };

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

    /// Jumps to the error stub of `pc` when `eax` is above 1.
    pub fn checkError(e: *Emitter, pc: u32) Error!void {
        try e.s.aluRI(.cmp, abi.ret, helpers.yes);
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
            .guard => try e.branch(.guard, pc, i.a),
            .str_eq_jump => try e.branch(.str_eq_jump, pc, i.b),
            .jump_false => try e.branch(.jump_false, pc, i.a),
            .jump_true => try e.branch(.jump_true, pc, i.a),
            .jf_vv => try e.branch(.jf_vv, pc, i.c),
            .jf_vi => try e.branch(.jf_vi, pc, i.c),
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
    for (labels) |*lb| lb.* = try s.newLabel();
    var e: Emitter = .{ .s = s, .code = code, .info = info, .l = l, .labels = labels, .stubs = stubs, .epilogue = try s.newLabel() };
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
    try e.emitStubs();
    try e.emitEpilogue();
    try s.finish();
}

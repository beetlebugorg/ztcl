//! The helper table of the JIT.
//!
//! Each helper wraps one instruction function of `vm.zig` with the C
//! calling convention: `fn (ctx, pc, sp) u32`. `pc` is the address of
//! the instruction and `sp` is its static stack depth. A helper returns
//! 0 for done or false, 1 for true, and 2 for an error. For an error, it
//! stores the Zig error in `ctx.err`. The machine code calls a helper
//! through the table, so the code has no absolute address. The table is
//! a constant of the binary.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vm = @import("../vm.zig");
const interp = @import("../interp.zig");
const jit = @import("../jit.zig");

const EnterCtx = jit.EnterCtx;
const Error = interp.Error;

pub const Fn = *const fn (ctx: *EnterCtx, pc: u32, sp: u32) callconv(.c) u32;

pub const done: u32 = 0;
pub const yes: u32 = 1;
pub const failed: u32 = 2;

/// One helper for each instruction, one for each form of `access`, and
/// the parts that the inline code of tier 1 calls on its slow paths.
pub const Helper = enum(u8) {
    push,
    push_empty,
    pop,
    load,
    store,
    llength,
    lindex,
    string_length,
    string_index,
    guard,
    step,
    jump,
    lassign,
    lassign_drop,
    lset,
    lset_drop,
    str_eq_jump,
    jump_false,
    jump_true,
    to_bool,
    invoke,
    eval_cmd,
    word,
    node,
    concat,
    binary,
    unary,
    number_form,
    incr,
    incr_value,
    lappend,
    store_pop,
    incr_drop,
    bin_vv,
    bin_vi,
    jf_vv,
    jf_vi,
    dict_update,
    dict_update_drop,
    append,
    foreach_init,
    foreach_next,
    /// 1 when the guard jumps to its cold block: `vm.guardJumps`.
    recheck,
    /// `invoke` for a site whose cached command the code checked.
    call_cached,
    /// The counter of a loop head reached zero. The result is the address
    /// of the tier 2 code of the loop, or zero.
    tier_up,
    /// The address of the tier 1 code of `pc`, or zero after it sets the
    /// place of the context for `exec`.
    resume_at,
    /// 1 when the bytes of the string on the top of the stack equal the
    /// string literal of `str_eq_jump`. It has no error.
    str_bytes_eq,
    lmap_add,
};

pub const count = @typeInfo(Helper).@"enum".fields.len;

/// The instruction function of a helper.
fn opOf(comptime h: Helper) @TypeOf(vm.opLoad) {
    return switch (h) {
        .push => vm.opPush,
        .push_empty => vm.opPushEmpty,
        .pop => vm.opPop,
        .load => vm.opLoad,
        .store => vm.opStore,
        .llength => vm.opLlength,
        .lindex => vm.opLindex,
        .string_length => vm.opStringLength,
        .string_index => vm.opStringIndex,
        .step => vm.opStep,
        .jump => vm.opJump,
        .lassign => vm.opLassign,
        .lassign_drop => vm.opLassignDrop,
        .lset => vm.opLset,
        .lset_drop => vm.opLsetDrop,
        .to_bool => vm.opToBool,
        .invoke => vm.opInvoke,
        .eval_cmd => vm.opEvalCmd,
        .word => vm.opWord,
        .node => vm.opNode,
        .concat => vm.opConcat,
        .binary => vm.opBinary,
        .unary => vm.opUnary,
        .number_form => vm.opNumberForm,
        .incr => vm.opIncr,
        .incr_value => vm.opIncrValue,
        .lappend => vm.opLappend,
        .store_pop => vm.opStorePop,
        .incr_drop => vm.opIncrDrop,
        .bin_vv => vm.opBinVv,
        .bin_vi => vm.opBinVi,
        .dict_update => vm.opDictUpdate,
        .dict_update_drop => vm.opDictUpdateDrop,
        .append => vm.opAppend,
        .foreach_init => vm.opForeachInit,
        .lmap_add => vm.opLmapAdd,
        else => unreachable,
    };
}

/// The function of a helper of an instruction with two successors.
fn branchOf(comptime h: Helper) @TypeOf(vm.opGuard) {
    return switch (h) {
        .guard => vm.opGuard,
        .str_eq_jump => vm.opStrEqJump,
        .jump_false => vm.opJumpFalse,
        .jump_true => vm.opJumpTrue,
        .jf_vv => vm.opJfVv,
        .jf_vi => vm.opJfVi,
        .foreach_next => vm.opForeachNext,
        else => unreachable,
    };
}

pub fn isBranch(h: Helper) bool {
    return switch (h) {
        .guard, .str_eq_jump, .jump_false, .jump_true, .jf_vv, .jf_vi, .foreach_next => true,
        else => false,
    };
}

fn fail(ctx: *EnterCtx, e: Error) u32 {
    ctx.err = @intFromError(e);
    return failed;
}

pub fn wrap(comptime h: Helper, comptime named: bool) Fn {
    if (h == .recheck) return &struct {
        fn f(ctx: *EnterCtx, pc: u32, sp: u32) callconv(.c) u32 {
            _ = .{ pc, sp };
            return @intFromBool(vm.guardJumps(ctx.it));
        }
    }.f;
    if (h == .tier_up) return @ptrCast(&jit.tierUp);
    if (h == .resume_at) return @ptrCast(&jit.resumeAt);
    if (h == .call_cached) return &struct {
        fn f(ctx: *EnterCtx, pc: u32, sp: u32) callconv(.c) u32 {
            const code = ctx.code;
            vm.opInvokeCached(ctx.it, code, ctx.stack, sp, &code.ins[pc]) catch |e| return fail(ctx, e);
            return done;
        }
    }.f;
    if (h == .str_bytes_eq) return &struct {
        fn f(ctx: *EnterCtx, pc: u32, sp: u32) callconv(.c) u32 {
            const code = ctx.code;
            return @intFromBool(std.mem.eql(u8, ctx.stack[sp - 1].str, code.lits[code.ins[pc].a].str));
        }
    }.f;
    if (comptime isBranch(h)) return &struct {
        fn f(ctx: *EnterCtx, pc: u32, sp: u32) callconv(.c) u32 {
            const code = ctx.code;
            const t = branchOf(h)(named, ctx.it, ctx.frame, code, ctx.stack, sp, &code.ins[pc]) catch |e| return fail(ctx, e);
            return @intFromBool(t);
        }
    }.f;
    return &struct {
        fn f(ctx: *EnterCtx, pc: u32, sp: u32) callconv(.c) u32 {
            const code = ctx.code;
            opOf(h)(named, ctx.it, ctx.frame, code, ctx.stack, sp, &code.ins[pc]) catch |e| return fail(ctx, e);
            return done;
        }
    }.f;
}

/// The helpers in the order of `Helper`, for the `Code` of a proc body.
pub const table: [count]*const anyopaque = tableOf(false);

/// The helpers for a named `Code`: each variable goes by its name.
pub const table_named: [count]*const anyopaque = tableOf(true);

fn tableOf(comptime named: bool) [count]*const anyopaque {
    var t: [count]*const anyopaque = undefined;
    for (0..count) |k| t[k] = @ptrCast(wrap(@enumFromInt(k), named));
    return t;
}

/// The table of `code`.
pub fn tableFor(code: *const vm.Code) [*]const *const anyopaque {
    return if (code.named) &table_named else &table;
}

/// The helper that runs the whole instruction `i`. `ret` has no helper.
pub fn forIns(i: *const vm.Ins) ?Helper {
    return switch (i.op) {
        .ret => null,
        .access => switch (i.x) {
            0 => .llength,
            1 => .lindex,
            2 => .string_length,
            else => .string_index,
        },
        inline else => |op| @field(Helper, @tagName(op)),
    };
}

/// The address of instruction `i` after its helper returned `r`: the
/// target on result 1 of a branch, the target of a `jump`, or the next
/// address.
pub fn next(i: *const vm.Ins, pc: u32, r: u32) u32 {
    if (i.op == .jump) return i.a;
    if (r != yes) return pc + 1;
    return switch (i.op) {
        .guard, .jump_false, .jump_true => i.a,
        .str_eq_jump, .foreach_next => i.b,
        .jf_vv, .jf_vi => i.c,
        else => pc + 1,
    };
}

/// The Zig error of `ctx.err`.
pub fn errorOf(ctx: *const EnterCtx) Error {
    return @errorCast(@errorFromInt(ctx.err));
}

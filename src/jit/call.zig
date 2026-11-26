//! The direct call of a proc from machine code: the helper
//! `call_direct`.
//!
//! The machine code of `invoke` checks the site inline. When the cached
//! command is valid, it calls `call_direct`. The helper serves a proc
//! with ready machine code of the current generation, one word for each
//! parameter, and no `args`. It does the work of `vm.opInvokeCached`,
//! `Interp.callProcFast`, `vm.runReady`, and `jit.enterStart` in one
//! function, in their order:
//!
//! 1. The step check.
//! 2. The frame, the namespace, and the cells (`Interp.enterProcDirect`).
//! 3. The native stack, the nest, and the value stack of the body.
//! 4. The call of the function of the body at address 0.
//! 5. On the status "done": the value stack, the nest, the namespace,
//!    and the frame go back, and the result goes to the stack slot of
//!    the command. Each other status goes to `finish`, which runs the
//!    rest of the body in `vm.runRest` and then the end of the call of
//!    `callProcFast` (`Interp.leaveProcDirect`).
//!
//! So the steps, the errors, `errorInfo`, the frames, and the memory
//! count are the same as on the general path. The general path copies
//! the result through each layer and keeps a native frame for each
//! layer. This helper copies the result one time and has one frame.
//! Each other command goes to `vm.opInvokeCached`. A redefined command
//! changes the epoch, so the inline checks of the site fail and the call
//! goes to the helper of `invoke`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vm = @import("../vm.zig");
const interp = @import("../interp.zig");
const jit = @import("../jit.zig");
const gc = @import("../gc.zig");
const helpers = @import("helpers.zig");
const mem = @import("mem.zig");
const tier1 = @import("tier1.zig");
const Value = @import("../value.zig").Value;

const EnterCtx = jit.EnterCtx;
const Interp = interp.Interp;
const Error = interp.Error;

fn fail(ctx: *EnterCtx, e: Error) u32 {
    @branchHint(.cold);
    ctx.err = @intFromError(e);
    return helpers.failed;
}

/// The helper `call_direct`.
pub fn direct(ctx: *EnterCtx, pc: u32, sp: u32) callconv(.c) u32 {
    const it = ctx.it;
    const code = ctx.code;
    const i = &code.ins[pc];
    const f, const p, const bc = target(it, code.sites[i.a], i.b) orelse {
        vm.opInvokeCached(it, code, ctx.stack, sp, i) catch |e| return fail(ctx, e);
        return helpers.done;
    };
    const argv = ctx.stack[sp - i.b .. sp];
    vm.step(it) catch |e| return fail(ctx, e);
    const saved_ns = it.enterProcDirect(p, bc, argv) catch |e| return fail(ctx, e);
    // The part of `vm.runReady` before the entry.
    const slot = &ctx.stack[sp - i.b];
    it.checkNative() catch |e| return finish(ctx, slot, argv, saved_ns, e);
    if (it.nest >= it.max_nest) return finish(ctx, slot, argv, saved_ns, it.fail("too many nested evaluations (infinite loop?)", .{}));
    it.nest += 1;
    const mark = it.stackMark();
    const stack = (it.stackAllocPub(bc.max_stack) catch |e| {
        it.nest -= 1;
        return finish(ctx, slot, argv, saved_ns, e);
    }).ptr;
    var c: EnterCtx = .{
        .it = it,
        .code = bc,
        .frame = it.frame,
        .stack = stack,
        .helpers = f.helpers,
        .target = @intFromPtr(f.base) + f.entries[0],
        .pc = 0,
        .sp = 0,
        .err = 0,
        .empty = &Value.empty,
        .counters = f.counters.ptr,
        .func = f,
    };
    const func: *const fn (*EnterCtx) callconv(.c) u32 = @ptrCast(@alignCast(f.base));
    mem.checkClosed();
    const raw = func(&c);
    if (raw != tier1.status_done) {
        const st = jit.statusOf(it, raw, &c);
        const r = vm.runRest(it, bc, f, stack, c.pc, c.sp, st);
        it.stackRelease(mark);
        it.nest -= 1;
        return finish(ctx, slot, argv, saved_ns, r);
    }
    const v = stack[c.sp - 1];
    it.stackRelease(mark);
    it.nest -= 1;
    it.ns = saved_ns;
    it.popFrame();
    slot.* = v;
    return helpers.done;
}

/// The proc, its body, and the function of the body for the command of
/// the site `c` with `n` words, or null when `direct` does not serve it.
inline fn target(it: *Interp, c: *const interp.Cmd, n: u32) ?struct { *jit.Fn, *interp.Proc, *vm.Code } {
    if (gc.precise) return null;
    const p = switch (c.resolved.?.impl) {
        .proc => |p| p,
        .native => return null,
    };
    const bc = p.code orelse return null;
    if (p.has_args or n - 1 != p.params.len or bc.jit_state != .ready) return null;
    const f = jit.readyFn(it, bc) orelse return null;
    if (f.enter_stress or f.entries.len == 0 or f.entries[0] >= f.len) return null;
    return .{ f, p, bc };
}

/// The end of a direct call with the result `r` of the body: the end of
/// `callProcFast`, then the result to `slot`, the stack slot of the
/// command.
noinline fn finish(ctx: *EnterCtx, slot: *Value, argv: []const Value, saved_ns: []const u8, r: Error!Value) u32 {
    @branchHint(.unlikely);
    const v = ctx.it.leaveProcDirect(saved_ns, argv, r) catch |e| return fail(ctx, e);
    slot.* = v;
    return helpers.done;
}

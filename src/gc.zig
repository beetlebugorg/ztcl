//! The roots of the collector.
//!
//! The collector is conservative and does not move a block. A root is a
//! range of memory. The mark reads each aligned word of a root as a
//! possible pointer. A root is one of these:
//!
//! 1. The bytes of an `Interp` struct. The root interpreter and each
//!    interpreter in its `kids` list count. All of them share one heap.
//! 2. The state of the point procs, which the embedder owns.
//! 3. A range that the embedder registers in `gc_roots`.
//! 4. The native stack, from the stack pointer of the collector up to
//!    `native_base`, and the registers that a callee must keep. The
//!    routine below copies them to the stack first.
//! 5. For each running coroutine, the stack of its resumer, from the
//!    saved stack pointer up to the saved base. A suspended coroutine
//!    keeps its stack in a block of the heap, which the mark scans.
//!
//! A collection starts only inside a script run (`nest` above zero), so
//! the base of the native stack is valid. On a target with no register
//! routine, the collector is off.
//!
//! The caches that key a value by its address (`script_cache`,
//! `expr_cache`, and the tails of `append`) go away at each collection.
//! The address of a freed block can come back for another string.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const heap_mod = @import("heap.zig");
const Heap = heap_mod.Heap;
const Interp = interp.Interp;

/// True on a target with a register routine.
pub const supported = switch (builtin.cpu.arch) {
    .x86_64, .aarch64 => builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .windows,
    else => false,
};

/// The most native stack that the collector scans: a guard against a
/// base that is not valid.
const max_stack: usize = 1 << 30;

/// Reads one general register.
inline fn readReg(comptime reg: []const u8) usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("movq %%" ++ reg ++ ", %[o]"
            : [o] "=r" (-> usize),
        ),
        .aarch64 => asm volatile ("mov %[o], " ++ reg
            : [o] "=r" (-> usize),
        ),
        else => 0,
    };
}

/// Reads one vector register of Windows.
inline fn readVec(comptime reg: []const u8) @Vector(2, usize) {
    return asm volatile ("movaps %%" ++ reg ++ ", %[o]"
        : [o] "=x" (-> @Vector(2, usize)),
    );
}

/// Copies the registers that a callee keeps into `out`. The compiler can
/// hold a pointer in one of them while it calls the allocator.
inline fn saveRegs(out: *[48]usize) void {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            const regs = .{ "rbx", "rbp", "r12", "r13", "r14", "r15", "rdi", "rsi" };
            inline for (regs, 0..) |r, i| out[i] = readReg(r);
            if (builtin.os.tag == .windows) {
                // The registers xmm6 to xmm15 are callee-saved here.
                const xs = .{ "xmm6", "xmm7", "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15" };
                inline for (xs, 0..) |r, i| {
                    const v = readVec(r);
                    out[8 + i * 2] = v[0];
                    out[9 + i * 2] = v[1];
                }
            }
        },
        .aarch64 => {
            const regs = .{ "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x29", "x30" };
            inline for (regs, 0..) |r, i| out[i] = readReg(r);
        },
        else => {},
    }
}

inline fn stackPointer() usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("movq %%rsp, %[o]"
            : [o] "=r" (-> usize),
        ),
        .aarch64 => asm volatile ("mov %[o], sp"
            : [o] "=r" (-> usize),
        ),
        else => 0,
    };
}

fn markStruct(h: *Heap, p: *const anyopaque, len: usize) void {
    heap_mod.markRange(h, @intFromPtr(p), len);
}

/// The roots that belong to one interpreter.
fn markInterp(it: *const Interp, h: *Heap) void {
    markStruct(h, it, @sizeOf(Interp));
    if (it.points) |p| markStruct(h, p, @sizeOf(@TypeOf(p.*)));
    for (it.gc_roots.items) |r| heap_mod.markRange(h, @intFromPtr(r.ptr), r.len);
    heap_mod.markRange(h, @intFromPtr(it.held.items.ptr), it.held.items.len * @sizeOf(interp.Value));
    // The stack of the resumer of each running coroutine.
    var c = it.coro;
    while (c) |co| : (c = co.prev) {
        const lo = co.caller_sp;
        const hi = co.saved.native_base;
        if (lo != 0 and hi > lo and hi - lo < max_stack) heap_mod.markRange(h, lo, hi - lo);
    }
}

/// Forgets what an address names. Each cache here compares an address.
fn dropAddressCaches(it: *Interp) void {
    it.script_cache.clearRetainingCapacity();
    it.expr_cache.clearRetainingCapacity();
    it.tails = @splat(.{});
    it.next_tail = 0;
}

/// Marks the roots of the interpreter in `ctx` and of its family. Returns
/// false when a collection is not possible now.
pub fn markRoots(ctx: *anyopaque, h: *Heap) bool {
    if (!supported) return false;
    const it: *Interp = @ptrCast(@alignCast(ctx));
    if (!it.gc_on or (it.nest == 0 and !it.gc_manual)) return false;
    var regs: [48]usize = undefined;
    @memset(&regs, 0);
    saveRegs(&regs);
    dropAddressCaches(it);
    for (it.kids.items) |k| dropAddressCaches(k);
    markInterp(it, h);
    for (it.kids.items) |k| markInterp(k, h);
    // The registers are on this frame, and the scan of the stack starts
    // below it.
    const sp = stackPointer();
    const base = it.native_base;
    if (it.nest > 0 and base > sp and base - sp < max_stack) heap_mod.markRange(h, sp, base - sp);
    std.mem.doNotOptimizeAway(&regs);
    return true;
}

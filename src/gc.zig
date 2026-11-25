//! The roots of the collector.
//!
//! The collector does not move a block. A collection starts only at a
//! safe point: a limit check between two commands or two bytecode
//! instructions (`Interp.memPoint`). A root is a range of memory, and
//! the mark reads each aligned word of a root as a possible pointer.
//! These ranges are roots on each target:
//!
//! 1. The bytes of each `Interp` of the tree. All of them share one heap.
//! 2. The state of the point procs, which the embedder owns.
//! 3. The ranges of `addRoot`, and the values of `hold`.
//! 4. The pins of a precise build.
//!
//! A native build also scans the native stacks and the registers:
//!
//! - The current stack, from the stack pointer to `native_base`. A naked
//!   routine pushes the callee-saved registers first, so they are in the
//!   scanned range. The scan runs only when `gc_scope` is above zero.
//!   Only `evalTop` and `enterHost` set it, so `native_base` is valid.
//! - For each running coroutine, the stack of its resumer. A suspended
//!   coroutine keeps its stack in a heap block, which the mark scans.
//!
//! A bad stack range stops the collection before the sweep. The memory
//! limit then applies with no block freed.
//!
//! WebAssembly has no way to read its locals or its value stack, so a
//! stack scan is not sound there. A precise build (`precise`) scans no
//! stack. It collects only at a safe point of `vm.exec` when each native
//! frame of the run is a clean frame: `evalTop`, `vm.run`, `vm.exec`, or
//! a proc call from bytecode. These frames keep their values on the word
//! stack, in cells, or in the pin list. `vm.run` ends the clean chain
//! unless its caller sets a token, so a native command is unclean by
//! default. Native builds can build this mode with `-Dgc-precise=true`,
//! so the stress tests run it with safety checks.
//!
//! The address of a freed block can come back for another string, so a
//! cache that keys a value by its address must not outlive the text.
//! `script_cache` and `expr_cache` have tables outside the heap. An
//! entry stays while its text is live, and the mark then keeps its
//! compiled form. So a collection does not change which run of a script
//! is its second run, and the step counts stay equal. The text cache is
//! in the interpreter, so `markInterp` marks its scripts and texts as
//! roots. The list cache and the tails of `append` hold no state that a
//! script can see. They go away at each collection.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const interp = @import("interp.zig");
const heap_mod = @import("heap.zig");
const Heap = heap_mod.Heap;
const Interp = interp.Interp;

/// True for a build that scans no native stack.
pub const precise = builtin.cpu.arch.isWasm() or options.gc_precise;

/// True on a target with a routine that spills the registers.
pub const native_scan = !precise and switch (builtin.cpu.arch) {
    .x86_64, .aarch64 => builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .windows,
    else => false,
};

/// True when this build can collect.
pub const supported = precise or native_scan;

/// The most native stack that the collector scans.
const max_stack: usize = 1 << 30;

// `ztcl_gc_spill(job, fn)` stores each callee-saved register on the
// stack and calls `fn(job, sp)`. `sp` is the lowest address of the saved
// registers. The routine is naked, so the compiler cannot move a store
// after the scan.
fn spillAsm() callconv(.naked) void {
    if (builtin.cpu.arch == .aarch64) asm volatile (
        \\ sub sp, sp, #160
        \\ stp x19, x20, [sp, #0]
        \\ stp x21, x22, [sp, #16]
        \\ stp x23, x24, [sp, #32]
        \\ stp x25, x26, [sp, #48]
        \\ stp x27, x28, [sp, #64]
        \\ stp x29, x30, [sp, #80]
        \\ stp d8, d9, [sp, #96]
        \\ stp d10, d11, [sp, #112]
        \\ stp d12, d13, [sp, #128]
        \\ stp d14, d15, [sp, #144]
        \\ mov x9, x1
        \\ mov x1, sp
        \\ blr x9
        \\ ldr x30, [sp, #88]
        \\ add sp, sp, #160
        \\ ret
    ) else if (builtin.os.tag == .windows) asm volatile (
        \\ subq $264, %%rsp
        \\ movaps %%xmm6, 32(%%rsp)
        \\ movaps %%xmm7, 48(%%rsp)
        \\ movaps %%xmm8, 64(%%rsp)
        \\ movaps %%xmm9, 80(%%rsp)
        \\ movaps %%xmm10, 96(%%rsp)
        \\ movaps %%xmm11, 112(%%rsp)
        \\ movaps %%xmm12, 128(%%rsp)
        \\ movaps %%xmm13, 144(%%rsp)
        \\ movaps %%xmm14, 160(%%rsp)
        \\ movaps %%xmm15, 176(%%rsp)
        \\ movq %%rbx, 192(%%rsp)
        \\ movq %%rbp, 200(%%rsp)
        \\ movq %%rdi, 208(%%rsp)
        \\ movq %%rsi, 216(%%rsp)
        \\ movq %%r12, 224(%%rsp)
        \\ movq %%r13, 232(%%rsp)
        \\ movq %%r14, 240(%%rsp)
        \\ movq %%r15, 248(%%rsp)
        \\ movq %%rdx, %%rax
        \\ leaq 32(%%rsp), %%rdx
        \\ callq *%%rax
        \\ addq $264, %%rsp
        \\ retq
    ) else asm volatile (
        \\ pushq %%rbp
        \\ pushq %%rbx
        \\ pushq %%r12
        \\ pushq %%r13
        \\ pushq %%r14
        \\ pushq %%r15
        \\ subq $8, %%rsp
        \\ movq %%rsi, %%rax
        \\ leaq 8(%%rsp), %%rsi
        \\ callq *%%rax
        \\ addq $56, %%rsp
        \\ retq
    );
}

comptime {
    if (native_scan) @export(&spillAsm, .{ .name = "ztcl_gc_spill", .visibility = .hidden });
}

const Job = extern struct { h: *Heap, base: usize, ok: bool };

extern fn ztcl_gc_spill(job: *Job, f: *const fn (*Job, usize) callconv(.c) void) callconv(.c) void;

fn scanFrom(job: *Job, sp: usize) callconv(.c) void {
    if (job.base <= sp or job.base - sp >= max_stack) {
        job.ok = false;
        return;
    }
    heap_mod.markStack(job.h, sp, job.base - sp);
}

/// True when a collection is safe for the running interpreter `it`.
pub fn allowed(it: *const Interp) bool {
    if (!supported) return false;
    var root = it;
    while (root.parent) |p| root = p;
    if (!root.gc_on) return false;
    // At nest 0 no frame of a script runs: only a call of `collect`.
    if (it.nest == 0 and it.gc_scope == 0) return it.gc_manual;
    if (it.gc_scope == 0) return false;
    if (precise) return isClean(it) and it.gc_vm_point;
    return true;
}

/// Precise builds: true when each native frame of the run is clean. A
/// coroutine holds values on its own native stack, so a live coroutine
/// stops collection. WebAssembly has no coroutines.
pub inline fn isClean(it: *const Interp) bool {
    return it.gc_clean_nest == it.nest and it.coro == null and it.coro_count == 0;
}

/// The roots that belong to one interpreter. Returns false for a bad
/// stack range.
fn markInterp(it: *const Interp, h: *Heap) bool {
    heap_mod.markRange(h, @intFromPtr(it), @sizeOf(Interp));
    if (it.points) |p| heap_mod.markRange(h, @intFromPtr(p), @sizeOf(@TypeOf(p.*)));
    for (it.gc_roots.items) |r| heap_mod.markRange(h, @intFromPtr(r.ptr), r.len);
    heap_mod.markRange(h, @intFromPtr(it.held.items.ptr), it.held.items.len * @sizeOf(interp.Value));
    for (it.pins.items) |w| heap_mod.markWord(h, w);
    if (!native_scan) return true;
    // The stack of the resumer of each running coroutine.
    var c = it.coro;
    while (c) |co| : (c = co.prev) {
        const lo = co.caller_sp;
        const hi = co.saved.native_base;
        if (lo == 0 or hi <= lo or hi - lo >= max_stack) return false;
        heap_mod.markStack(h, lo, hi - lo);
    }
    return true;
}

/// Forgets what an address names. Each cache here compares an address.
fn dropAddressCaches(it: *Interp) void {
    it.list_cache = @splat(.{});
    it.tails = @splat(.{});
    it.next_tail = 0;
}

/// Marks the value of each cache entry whose text is live. A compiled
/// form can hold the text of another entry, so this runs to a fixed point.
fn markCaches(root: *Interp, h: *Heap) void {
    var changed = true;
    while (changed) {
        changed = false;
        if (markCache(root, h)) changed = true;
        for (root.kids.items) |k| {
            if (markCache(k, h)) changed = true;
        }
    }
}

fn markCache(it: *Interp, h: *Heap) bool {
    var changed = false;
    inline for (.{ &it.script_cache, &it.expr_cache }) |map| {
        var e = map.iterator();
        while (e.next()) |x| {
            const key = x.key_ptr.*;
            const target = @intFromPtr(x.value_ptr.*);
            if (key.len == 0 or !heap_mod.isMarked(h, key.ptr) or heap_mod.isMarked(h, target)) continue;
            heap_mod.markRange(h, @intFromPtr(x.value_ptr), @sizeOf(usize));
            changed = true;
        }
    }
    return changed;
}

/// Removes each cache entry whose text is dead.
fn sweepCaches(it: *Interp, h: *Heap) void {
    inline for (.{ &it.script_cache, &it.expr_cache }) |map| {
        var e = map.iterator();
        while (e.next()) |x| {
            const key = x.key_ptr.*;
            if (key.len == 0 or !heap_mod.isMarked(h, key.ptr)) map.removeByPtr(x.key_ptr);
        }
    }
}

/// Marks the roots of the running interpreter in `ctx` and of its tree.
/// Returns false when the sweep must not run.
pub fn markRoots(ctx: *anyopaque, h: *Heap) bool {
    const it: *Interp = @ptrCast(@alignCast(ctx));
    if (!allowed(it)) return false;
    var root = it;
    while (root.parent) |p| root = p;
    dropAddressCaches(root);
    for (root.kids.items) |k| dropAddressCaches(k);
    if (!markInterp(root, h)) return false;
    for (root.kids.items) |k| if (!markInterp(k, h)) return false;
    if (native_scan and it.gc_scope != 0) {
        var job: Job = .{ .h = h, .base = it.native_base, .ok = true };
        ztcl_gc_spill(&job, &scanFrom);
        if (!job.ok) return false;
    }
    markCaches(root, h);
    // A work list that could not grow leaves some live text unmarked.
    if (!h.mark_ok) return false;
    sweepCaches(root, h);
    for (root.kids.items) |k| sweepCaches(k, h);
    return true;
}

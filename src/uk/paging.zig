//! The page tables of the ztcl unikernel (ztcl#471), from chapter 4 of
//! the Intel SDM, volume 3 (4-level paging).
//!
//! `init` replaces the identity map of the monitor with its own:
//!
//! - The first 4 GB, identity mapped. The 2 MB from address 0 and the
//!   2 MB pages that hold the image have 4 KiB pages: page 0 and the
//!   lowest page of the stack are absent, so a null pointer and a stack
//!   overflow fault; the code of the image is read-only and
//!   executable; the read-only data is read-only; and each other page
//!   is writable and not executable (NX). The rest of the 4 GB is 2 MB
//!   pages, writable and not executable.
//! - The JIT window at 4 GB: 1 GiB of address space in 4 KiB pages, absent
//!   until `protect` gives a page its rights. A page gets its memory from
//!   the heap at its first use. A page is writable or executable, never
//!   both.
//!
//! EFER.NXE turns on the NX bit, and CR0.WP makes a read-only page
//! read-only for ring 0 too.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const heap = @import("heap.zig");

pub const page: usize = 4096;
const big: usize = 2 << 20;
const p_present: u64 = 1;
const p_write: u64 = 2;
const p_big: u64 = 0x80;
const p_nx: u64 = 1 << 63;
const addr_mask: u64 = 0x000f_ffff_ffff_f000;

pub const jit_base: usize = 4 << 30;
pub const jit_window: usize = 1 << 30;

extern const __text_end: u8;
extern const __image_start: u8;
extern const uk_rodata_end: u8;

var pml4: *[512]u64 = undefined;
/// The next free page after the image, for the tables of `init`.
var next: usize = 0;

fn newTable() *[512]u64 {
    const t: *[512]u64 = @ptrFromInt(next);
    next += page;
    @memset(t, 0);
    return t;
}

fn heapTable() ?*[512]u64 {
    const m = heap.allocator.alignedAlloc(u8, .fromByteUnits(page), page) catch return null;
    @memset(m, 0);
    return @ptrCast(@alignCast(m.ptr));
}

/// Builds the tables and loads CR3. Gives the first free address after
/// the tables.
pub fn init(image_end: usize, mem_end: usize) usize {
    _ = mem_end;
    next = std.mem.alignForward(usize, image_end, page);
    pml4 = newTable();
    const pdpt = newTable();
    pml4[0] = @intFromPtr(pdpt) | p_present | p_write;
    const text_start = @intFromPtr(&__image_start);
    const text_end = @intFromPtr(&__text_end);
    const ro_end = @intFromPtr(&uk_rodata_end);
    const small_end = std.mem.alignForward(usize, image_end, big);
    const guard = @intFromPtr(&@import("uk.zig").uk_stack);
    for (0..4) |g| {
        const pd = newTable();
        pdpt[g] = @intFromPtr(pd) | p_present | p_write;
        for (0..512) |j| {
            const at: usize = (g << 30) | (j << 21);
            if (at != 0 and (at < text_start or at >= small_end)) {
                pd[j] = at | p_present | p_write | p_big | p_nx;
                continue;
            }
            const pt = newTable();
            pd[j] = @intFromPtr(pt) | p_present | p_write;
            for (0..512) |k| {
                const a = at + k * page;
                pt[k] = if (a == 0 or a == guard)
                    0
                else if (a >= text_start and a < text_end)
                    a | p_present
                else if (a >= text_end and a < ro_end)
                    a | p_present | p_nx
                else
                    a | p_present | p_write | p_nx;
            }
        }
    }
    // The JIT window is entry 4 of the same page directory pointer
    // table. Its page directories and tables come from the heap at their
    // first use.
    // EFER.NXE, then CR0.WP, then the new tables.
    asm volatile (
        \\mov $0xc0000080, %%ecx
        \\rdmsr
        \\or $0x800, %%eax
        \\wrmsr
        \\mov %%cr0, %%rax
        \\or $0x10000, %%rax
        \\mov %%rax, %%cr0
        ::: .{ .rax = true, .rcx = true, .rdx = true, .memory = true });
    asm volatile ("mov %[p], %%cr3"
        :
        : [p] "r" (@intFromPtr(pml4)),
        : .{ .memory = true });
    return next;
}

fn entryOf(addr: usize) ?*u64 {
    const pdpt: *[512]u64 = @ptrFromInt(pml4[(addr >> 39) & 511] & addr_mask);
    const l3 = (addr >> 30) & 511;
    if (pdpt[l3] & p_present == 0) {
        const t = heapTable() orelse return null;
        pdpt[l3] = @intFromPtr(t) | p_present | p_write;
    }
    const pd: *[512]u64 = @ptrFromInt(pdpt[l3] & addr_mask);
    const l2 = (addr >> 21) & 511;
    if (pd[l2] & p_present == 0) {
        const t = heapTable() orelse return null;
        pd[l2] = @intFromPtr(t) | p_present | p_write;
    }
    const pt: *[512]u64 = @ptrFromInt(pd[l2] & addr_mask);
    return &pt[(addr >> 12) & 511];
}

var reserved: usize = 0;

/// Takes `len` bytes of the JIT window, with no page present. Gives
/// null when the window is full.
pub fn reserve(len: usize) ?usize {
    const n = std.mem.alignForward(usize, len, page);
    if (n > jit_window - reserved) return null;
    const at = jit_base + reserved;
    reserved += n;
    return at;
}

pub const Prot = enum { none, read_write, read_exec };

/// Sets the rights of the pages of the JIT window from `at` for `len`
/// bytes. A page keeps its memory when it becomes absent, so its code
/// stays for a later `read_exec`. Gives false outside the window or with
/// no memory for a page.
pub fn protect(at: usize, len: usize, prot: Prot) bool {
    if (at < jit_base or len > jit_window or at - jit_base > jit_window - len) return false;
    var a = at & ~(page - 1);
    while (a < at + len) : (a += page) {
        const e = entryOf(a) orelse return false;
        var phys = e.* & addr_mask;
        if (phys == 0 and prot != .none) {
            const m = heap.allocator.alignedAlloc(u8, .fromByteUnits(page), page) catch return false;
            phys = @intFromPtr(m.ptr);
        }
        e.* = switch (prot) {
            .none => phys,
            .read_write => phys | p_present | p_write | p_nx,
            .read_exec => phys | p_present,
        };
        asm volatile ("invlpg (%[a])"
            :
            : [a] "r" (a),
            : .{ .memory = true });
    }
    return true;
}

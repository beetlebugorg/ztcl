//! The executable region of the JIT on Linux and on arm64 macOS.
//!
//! On Linux, the region is one reservation of address space with no
//! access, with one more page with no access before it and after it.
//! `append` copies one function to the next free pages in three steps:
//!
//! 1. `mprotect` the pages to read and write.
//! 2. Copy the code, and fill the rest of the last page with `int3`.
//! 3. `mprotect` the same pages to read and execute.
//!
//! So a page is writable or executable at each instant, never both. A
//! page that is executable never becomes writable again: the code is
//! write-once, and a failed protection change cannot harm a function
//! that exists. After a failed system call, the region stops, and each
//! later `append` returns null. No failure is an error of a script.
//!
//! On arm64 macOS, the region is one `mmap` with `MAP_JIT` and the
//! rights read, write, and execute. The system keeps each `MAP_JIT` page
//! writable or executable for one thread, never both, and
//! `pthread_jit_write_protect_np` switches the state of the thread.
//! macOS refuses `mprotect` on a `MAP_JIT` page and a `MAP_JIT` mapping
//! at a fixed address. So the guard pages are a mapping with no access
//! at a fixed address over the first and the last page of the `MAP_JIT`
//! mapping. The pages that hold no function yet keep the rights of the
//! mapping: they hold zero words, which are `udf` instructions, and the
//! write protection of each thread keeps them read-only. `append` turns
//! the write protection off, copies the function, turns it on again, and
//! flushes the instruction cache for the range of the function.
//! Functions pack with 16-byte alignment, and the fill is zero words. No
//! other code runs between the two switch calls.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const c = std.c;

const darwin = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;

/// The fill byte: `int3` on x86-64, and the zero word of `udf` on arm64.
pub const trap_byte: u8 = if (builtin.cpu.arch == .aarch64) 0x00 else 0xCC;

/// The alignment of a function in the region on arm64 macOS.
const pack = 16;

extern "c" fn pthread_jit_write_protect_supported_np() c_int;
extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

/// True while this thread has its write window open on arm64 macOS.
threadlocal var write_open: bool = false;

/// Stops the process when this thread has its write window open. Each
/// jump into JIT code calls it first on arm64 macOS.
pub fn checkClosed() void {
    if (comptime darwin) {
        if (write_open) @panic("the JIT write window is open before a jump into JIT code");
    }
}

pub const Region = struct {
    /// The first usable page. The guard page is before it.
    base: [*]u8,
    /// The usable bytes: a whole number of pages.
    limit: usize,
    /// The bytes of the pages that hold functions.
    used: usize = 0,
    page: usize,
    /// True after a failed system call.
    stopped: bool = false,
    /// The stress mode: each second `append` returns null, as for a full
    /// region.
    fail_second: bool = false,
    appends: u64 = 0,

    /// Reserves `limit` bytes of address space with no access, plus one
    /// page with no access before and after. Null when the system refuses.
    pub fn init(limit: usize) ?Region {
        if (comptime darwin) return initDarwin(limit);
        if (comptime builtin.os.tag != .linux) return null;
        const page = std.heap.pageSize();
        const usable = std.mem.alignForward(usize, @max(limit, page), page);
        const total = std.math.add(usize, usable, 2 * page) catch return null;
        const rc = linux.mmap(null, total, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const start: [*]u8 = @ptrFromInt(rc);
        return .{ .base = start + page, .limit = usable, .page = page };
    }

    fn initDarwin(limit: usize) ?Region {
        if (pthread_jit_write_protect_supported_np() == 0) return null;
        const page = std.heap.pageSize();
        const usable = std.mem.alignForward(usize, @max(limit, page), page);
        const total = std.math.add(usize, usable, 2 * page) catch return null;
        const p = c.mmap(null, total, .{ .READ = true, .WRITE = true, .EXEC = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true }, -1, 0);
        if (p == c.MAP_FAILED) return null;
        const start: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(p));
        // The guard pages replace the first and the last page.
        for ([_]usize{ 0, page + usable }) |off| {
            const g = c.mmap(@ptrCast(@alignCast(start + off)), page, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true }, -1, 0);
            if (g == c.MAP_FAILED) {
                _ = c.munmap(start, total);
                return null;
            }
        }
        return .{ .base = start + page, .limit = usable, .page = page };
    }

    pub fn deinit(r: *Region) void {
        const start: [*]align(std.heap.page_size_min) u8 = @alignCast(r.base - r.page);
        if (comptime darwin) _ = c.munmap(start, r.limit + 2 * r.page) else _ = linux.munmap(start, r.limit + 2 * r.page);
        r.* = undefined;
    }

    /// Copies `code` to new pages and makes them executable. Null when the
    /// region is full or a system call fails. After null from a failed
    /// system call, each later call returns null.
    pub fn append(r: *Region, code: []const u8) ?[]const u8 {
        if (r.stopped or code.len == 0) return null;
        r.appends += 1;
        if (r.fail_second and r.appends % 2 == 0) return null;
        if (comptime darwin) return r.appendDarwin(code);
        const len = std.mem.alignForward(usize, code.len, r.page);
        const end = std.math.add(usize, r.used, len) catch return null;
        if (end > r.limit) return null;
        const at = r.base + r.used;
        if (linux.errno(linux.mprotect(at, len, .{ .READ = true, .WRITE = true })) != .SUCCESS) {
            r.stopped = true;
            return null;
        }
        @memcpy(at[0..code.len], code);
        @memset(at[code.len..len], trap_byte);
        // arm64 has no coherent instruction cache: flush the new code.
        if (@import("builtin").cpu.arch == .aarch64) clearCache(at, at + code.len);
        if (linux.errno(linux.mprotect(at, len, .{ .READ = true, .EXEC = true })) != .SUCCESS) {
            _ = linux.mprotect(at, len, .{});
            r.stopped = true;
            return null;
        }
        r.used = end;
        return at[0..code.len];
    }

    fn appendDarwin(r: *Region, code: []const u8) ?[]const u8 {
        const len = std.mem.alignForward(usize, code.len, pack);
        const end = std.math.add(usize, r.used, len) catch return null;
        if (end > r.limit) return null;
        const at = r.base + r.used;
        write_open = true;
        pthread_jit_write_protect_np(0);
        @memcpy(at[0..code.len], code);
        @memset(at[code.len..len], trap_byte);
        pthread_jit_write_protect_np(1);
        write_open = false;
        sys_icache_invalidate(at, len);
        r.used = end;
        return at[0..code.len];
    }

    /// The bytes of the pages that hold functions. On arm64 macOS, the
    /// bytes of the packed functions.
    pub fn usedBytes(r: *const Region) usize {
        return r.used;
    }
};

/// The bytes of a function that returns 42 on this CPU. On x86-64 they
/// are `mov eax, 42` and `ret`. On arm64 they are `movz w0, #42` and
/// `ret`. Other CPUs have no bytes, so the self test fails there.
const answer: []const u8 = switch (@import("builtin").cpu.arch) {
    .x86_64 => &.{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 },
    .aarch64 => &.{ 0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6 },
    else => &.{},
};

/// Makes a function that returns 42 and calls it. False when the system
/// has no executable memory.
pub fn selfTest() bool {
    if (answer.len == 0) return false;
    return runConst(answer, 42);
}

/// Copies `code` to a new region, calls it, and compares the result.
pub fn runConst(code: []const u8, want: u32) bool {
    var r = Region.init(std.heap.pageSize()) orelse return false;
    defer r.deinit();
    const f = r.append(code) orelse return false;
    const func: *const fn () callconv(.c) u32 = @ptrCast(@alignCast(f.ptr));
    checkClosed();
    return func() == want;
}

/// The instruction cache flush of compiler-rt, for arm64.
extern fn __clear_cache(start: [*]u8, end: [*]u8) callconv(.c) void;

fn clearCache(start: [*]u8, end: [*]u8) void {
    __clear_cache(start, end);
}

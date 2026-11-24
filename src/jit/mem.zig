//! The executable region of the JIT on Linux.
//!
//! The region is one reservation of address space with no access, with
//! one more page with no access before it and after it. `append` copies
//! one function to the next free pages in three steps:
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
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

/// The fill byte of unused code bytes.
/// On x86-64 it is `int3`. On arm64 a word of zero bytes is `udf #0`.
pub const trap_byte: u8 = if (@import("builtin").cpu.arch == .aarch64) 0x00 else 0xCC;

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
        if (comptime builtin.os.tag != .linux) return null;
        const page = std.heap.pageSize();
        const usable = std.mem.alignForward(usize, @max(limit, page), page);
        const total = std.math.add(usize, usable, 2 * page) catch return null;
        const rc = linux.mmap(null, total, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const start: [*]u8 = @ptrFromInt(rc);
        return .{ .base = start + page, .limit = usable, .page = page };
    }

    pub fn deinit(r: *Region) void {
        _ = linux.munmap(r.base - r.page, r.limit + 2 * r.page);
        r.* = undefined;
    }

    /// Copies `code` to new pages and makes them executable. Null when the
    /// region is full or a system call fails. After null from a failed
    /// system call, each later call returns null.
    pub fn append(r: *Region, code: []const u8) ?[]const u8 {
        if (r.stopped or code.len == 0) return null;
        r.appends += 1;
        if (r.fail_second and r.appends % 2 == 0) return null;
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

    /// The bytes of the pages that hold functions.
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
    return func() == want;
}

/// The instruction cache flush of compiler-rt, for arm64.
extern fn __clear_cache(start: [*]u8, end: [*]u8) callconv(.c) void;

fn clearCache(start: [*]u8, end: [*]u8) void {
    __clear_cache(start, end);
}

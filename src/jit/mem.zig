//! The executable region of the JIT on Linux, on Windows, and on arm64 macOS.
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
//! A macOS with no write protection for each thread, such as a virtual
//! machine, gets the page form: a `MAP_JIT` mapping with read and write
//! rights and then no access, and the three steps of Linux for each
//! function, with `sys_icache_invalidate` before the pages become
//! executable. macOS accepts `mprotect` on a `MAP_JIT` mapping that
//! started without the execute right.
//!
//! On Windows, the region is one reservation with no access
//! (`VirtualAlloc` with `MEM_RESERVE`), with one more page in front for
//! the unwind info. `append` has the three steps of Linux: a commit with
//! read and write, the copy, and `VirtualProtect` to read and execute,
//! then `FlushInstructionCache`. Each function also gets an entry in the
//! growable function table of the region (`win.Unwind`).
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const c = std.c;

const darwin = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;

const on_win = builtin.os.tag == .windows;
const cc = @import("../jit.zig").cc;

/// The calls of the Windows form: a reservation with no access, then for
/// each function a commit with read and write, the copy, a protection
/// change to read and execute, and a flush of the instruction cache.
const win = struct {
    const mem_commit: u32 = 0x1000;
    const mem_reserve: u32 = 0x2000;
    const mem_release: u32 = 0x8000;
    const page_noaccess: u32 = 0x01;
    const page_readwrite: u32 = 0x04;
    const page_execute_read: u32 = 0x20;
    extern "kernel32" fn VirtualAlloc(at: ?*anyopaque, size: usize, kind: u32, protect: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn VirtualProtect(at: *anyopaque, size: usize, protect: u32, old: *u32) callconv(.winapi) i32;
    extern "kernel32" fn VirtualFree(at: *anyopaque, size: usize, kind: u32) callconv(.winapi) i32;
    extern "kernel32" fn FlushInstructionCache(process: *anyopaque, at: *const anyopaque, size: usize) callconv(.winapi) i32;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
    extern "ntdll" fn RtlAddGrowableFunctionTable(table: *?*anyopaque, entries: [*]RuntimeFunction, count: u32, max: u32, base: usize, end: usize) callconv(.winapi) i32;
    extern "ntdll" fn RtlGrowFunctionTable(table: *anyopaque, count: u32) callconv(.winapi) void;
    extern "ntdll" fn RtlDeleteGrowableFunctionTable(table: *anyopaque) callconv(.winapi) void;
    const page_readonly: u32 = 0x02;

    const RuntimeFunction = extern struct { begin: u32, end: u32, unwind: u32 };

    /// The offset of the unwind info in the unwind page.
    const info_at = 16;

    /// The unwind info of each function of the region: the frame of the
    /// prologue of tier 1 (`push rbp`, `mov rbp, rsp`, the pushes of
    /// `abi.saved`, and the context slot), which the code of tier 2
    /// shares. `rbp` is the frame register at 48 bytes above the context
    /// slot, so the unwinder finds `rsp` from `rbp` at each point of the
    /// body, also while a helper call has pushed registers. The codes
    /// undo the context slot, then pop `r15` to `rbx` and `rbp`. The
    /// prologue has size 0: the prologue makes no call and cannot fault
    /// past its pushes, so each point where an unwind starts is past it.
    /// A function with no frame, as in the tests, gets the same info,
    /// and no unwind starts in one.
    const info = [_]u8{
        0x01, 0x00, 0x08, 0x35, // version 1, no prologue, 8 codes, rbp at offset 3 * 16
        0x00, 0x03, // UWOP_SET_FPREG
        0x00, 0x02, // UWOP_ALLOC_SMALL 8: the context slot
        0x00, 0xF0, 0x00, 0xE0, 0x00, 0xD0, 0x00, 0xC0, // UWOP_PUSH_NONVOL r15, r14, r13, r12
        0x00, 0x30, 0x00, 0x50, // UWOP_PUSH_NONVOL rbx, rbp
    };

    /// The growable function table of a region, so exceptions, stack
    /// traces, and debuggers walk through JIT frames.
    const Unwind = struct {
        table: *anyopaque,
        entries: [*]RuntimeFunction,
        count: u32 = 0,
        max: u32,

        fn init(start: [*]u8, total: usize, max_fns: usize) ?Unwind {
            const page = std.heap.pageSize();
            if (VirtualAlloc(start, page, mem_commit, page_readwrite) == null) return null;
            @memcpy(start[info_at..][0..info.len], &info);
            var old: u32 = 0;
            if (VirtualProtect(start, page, page_readonly, &old) == 0) return null;
            const max: u32 = @intCast(max_fns);
            const raw = VirtualAlloc(null, @as(usize, max) * @sizeOf(RuntimeFunction), mem_commit | mem_reserve, page_readwrite) orelse return null;
            const entries: [*]RuntimeFunction = @ptrCast(@alignCast(raw));
            var table: ?*anyopaque = null;
            if (RtlAddGrowableFunctionTable(&table, entries, 0, max, @intFromPtr(start), @intFromPtr(start) + total) != 0 or table == null) {
                _ = VirtualFree(raw, 0, mem_release);
                return null;
            }
            return .{ .table = table.?, .entries = entries, .max = max };
        }

        /// Adds the function at `at`. The functions come in the order of
        /// their addresses, as the table needs.
        fn add(u: *Unwind, start: [*]u8, at: [*]u8, len: usize) void {
            if (u.count == u.max) return;
            const off: u32 = @intCast(at - start);
            u.entries[u.count] = .{ .begin = off, .end = off + @as(u32, @intCast(len)), .unwind = info_at };
            u.count += 1;
            RtlGrowFunctionTable(u.table, u.count);
        }

        fn deinit(u: *Unwind) void {
            RtlDeleteGrowableFunctionTable(u.table);
            _ = VirtualFree(u.entries, 0, mem_release);
        }
    };
};

/// The fill byte: `int3` on x86-64, and the zero word of `udf` on arm64.
pub const trap_byte: u8 = if (builtin.cpu.arch == .aarch64) 0x00 else 0xCC;

/// The alignment of a function in the region on arm64 macOS.
const pack = 16;

extern "c" fn pthread_jit_write_protect_supported_np() c_int;
extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

/// Why the last `Region.init` on arm64 macOS returned null, for the
/// messages of the tests and of `zig build jit-probe`.
pub const Failure = enum { none, map_jit, guard, protect };

/// The tests set it to run the page form on a Mac that has the write
/// protection for each thread.
pub var force_pages = false;
pub var last_failure: Failure = .none;
/// The errno of the failed call of `last_failure`.
pub var last_errno: c_int = 0;

fn failed(f: Failure) void {
    last_failure = f;
    last_errno = @backingInt(c.errno(-1));
}

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
    /// True for the page form on arm64 macOS: one function on its own
    /// pages, with `mprotect` for each one.
    pages: bool = false,
    /// The function table of the region on Windows.
    unwind: if (on_win) win.Unwind else void = if (on_win) undefined else {},

    /// Reserves `limit` bytes of address space with no access, plus one
    /// page with no access before and after. Null when the system refuses.
    pub fn init(limit: usize) ?Region {
        if (comptime darwin) return initDarwin(limit);
        if (comptime on_win) return initWindows(limit);
        if (comptime builtin.os.tag != .linux) return null;
        const page = std.heap.pageSize();
        const usable = std.mem.alignForward(usize, @max(limit, page), page);
        const total = std.math.add(usize, usable, 2 * page) catch return null;
        const rc = linux.mmap(null, total, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const start: [*]u8 = @ptrFromInt(rc);
        return .{ .base = start + page, .limit = usable, .page = page };
    }

    /// A reservation with no access: a page for the unwind info, the
    /// guard page, the usable pages, and the guard page. The guard pages
    /// and the free pages stay reserved and never get a commit. The
    /// unwind page is read-only after its write, and the function table
    /// of the region (`win.Unwind`) names each function that `append`
    /// adds.
    fn initWindows(limit: usize) ?Region {
        const page = std.heap.pageSize();
        const usable = std.mem.alignForward(usize, @max(limit, page), page);
        const total = std.math.add(usize, usable, 3 * page) catch return null;
        if (total > std.math.maxInt(u32)) return null; // The table holds 32-bit offsets.
        const p = win.VirtualAlloc(null, total, win.mem_reserve, win.page_noaccess) orelse return null;
        const start: [*]u8 = @ptrCast(p);
        var r: Region = .{ .base = start + 2 * page, .limit = usable, .page = page };
        r.unwind = win.Unwind.init(start, total, usable / page) orelse {
            _ = win.VirtualFree(start, 0, win.mem_release);
            return null;
        };
        return r;
    }

    /// The three steps on Windows: a commit with read and write, the copy,
    /// and read and execute, with the flush of the instruction cache.
    fn appendWindows(r: *Region, code: []const u8) ?[]const u8 {
        const len = std.mem.alignForward(usize, code.len, r.page);
        const end = std.math.add(usize, r.used, len) catch return null;
        if (end > r.limit) return null;
        const at = r.base + r.used;
        if (win.VirtualAlloc(at, len, win.mem_commit, win.page_readwrite) == null) {
            r.stopped = true;
            return null;
        }
        @memcpy(at[0..code.len], code);
        @memset(at[code.len..len], trap_byte);
        var old: u32 = 0;
        if (win.VirtualProtect(at, len, win.page_execute_read, &old) == 0) {
            _ = win.VirtualProtect(at, len, win.page_noaccess, &old);
            r.stopped = true;
            return null;
        }
        _ = win.FlushInstructionCache(win.GetCurrentProcess(), at, len);
        r.unwind.add(r.base - 2 * r.page, at, code.len);
        r.used = end;
        return at[0..code.len];
    }

    fn initDarwin(limit: usize) ?Region {
        if (force_pages or pthread_jit_write_protect_supported_np() == 0) return initPages(limit);
        const page = std.heap.pageSize();
        const usable = std.mem.alignForward(usize, @max(limit, page), page);
        const total = std.math.add(usize, usable, 2 * page) catch return null;
        const p = c.mmap(null, total, .{ .READ = true, .WRITE = true, .EXEC = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true }, -1, 0);
        if (p == c.MAP_FAILED) {
            failed(.map_jit);
            return null;
        }
        const start: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(p));
        // The guard pages replace the first and the last page.
        for ([_]usize{ 0, page + usable }) |off| {
            const g = c.mmap(@ptrCast(@alignCast(start + off)), page, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true }, -1, 0);
            if (g == c.MAP_FAILED) {
                failed(.guard);
                _ = c.munmap(start, total);
                return null;
            }
        }
        return .{ .base = start + page, .limit = usable, .page = page };
    }

    /// The page form: the whole region, its guard pages, and its free
    /// pages have no access after the map.
    fn initPages(limit: usize) ?Region {
        const page = std.heap.pageSize();
        const usable = std.mem.alignForward(usize, @max(limit, page), page);
        const total = std.math.add(usize, usable, 2 * page) catch return null;
        const p = c.mmap(null, total, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true }, -1, 0);
        if (p == c.MAP_FAILED) {
            failed(.map_jit);
            return null;
        }
        const start: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(p));
        if (c.mprotect(start, total, .{}) != 0) {
            failed(.protect);
            _ = c.munmap(start, total);
            return null;
        }
        return .{ .base = start + page, .limit = usable, .page = page, .pages = true };
    }

    pub fn deinit(r: *Region) void {
        const start: [*]align(std.heap.page_size_min) u8 = @alignCast(r.base - r.page);
        if (comptime on_win) {
            r.unwind.deinit();
            _ = win.VirtualFree(r.base - 2 * r.page, 0, win.mem_release);
        } else if (comptime darwin) _ = c.munmap(start, r.limit + 2 * r.page) else _ = linux.munmap(start, r.limit + 2 * r.page);
        r.* = undefined;
    }

    /// Copies `code` to new pages and makes them executable. Null when the
    /// region is full or a system call fails. After null from a failed
    /// system call, each later call returns null.
    pub fn append(r: *Region, code: []const u8) ?[]const u8 {
        if (r.stopped or code.len == 0) return null;
        r.appends += 1;
        if (r.fail_second and r.appends % 2 == 0) return null;
        if (comptime darwin) return if (r.pages) r.appendPages(code) else r.appendDarwin(code);
        if (comptime on_win) return r.appendWindows(code);
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

    /// The three steps of Linux on `MAP_JIT` pages, with the flush of the
    /// instruction cache before the pages become executable.
    fn appendPages(r: *Region, code: []const u8) ?[]const u8 {
        const len = std.mem.alignForward(usize, code.len, r.page);
        const end = std.math.add(usize, r.used, len) catch return null;
        if (end > r.limit) return null;
        const at: [*]align(std.heap.page_size_min) u8 = @alignCast(r.base + r.used);
        if (c.mprotect(at, len, .{ .READ = true, .WRITE = true }) != 0) {
            r.stopped = true;
            return null;
        }
        @memcpy(at[0..code.len], code);
        @memset(at[code.len..len], trap_byte);
        sys_icache_invalidate(at, len);
        if (c.mprotect(at, len, .{ .READ = true, .EXEC = true }) != 0) {
            _ = c.mprotect(at, len, .{});
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
    const func: *const fn () callconv(cc) u32 = @ptrCast(@alignCast(f.ptr));
    checkClosed();
    return func() == want;
}

/// The instruction cache flush of compiler-rt, for arm64.
extern fn __clear_cache(start: [*]u8, end: [*]u8) callconv(.c) void;

fn clearCache(start: [*]u8, end: [*]u8) void {
    __clear_cache(start, end);
}

//! The pages of the spans of the heap, from the system, so a page that
//! the heap frees can go back to the system (ztcl#526, step 2). The
//! allocator of an embedder keeps the memory that it frees for its next
//! requests, so a process that freed a peak of 200 MB held all of it.
//!
//! The pool gets arenas of 4 MiB of addresses from the system and gives
//! runs of 4 KiB pages. Each arena has two bitmaps of its pages: `used`,
//! the pages of a span, and `committed`, the pages that can hold memory
//! of the process (on Windows, committed; on Linux and macOS, touched
//! since the last advice). A request gets the first run of free pages
//! of the lowest arena that has one, so the live pages stay at low
//! addresses and the high arenas empty first. A run above 1 MiB is a
//! mapping of its own, and its free gives it back to the system at once.
//!
//! `trim` gives back the free pages above a number of bytes that the
//! heap keeps for its next spans: first each arena with no page in use,
//! then the free pages of the other arenas, from the top. Windows
//! decommits them (`VirtualFree` with `MEM_DECOMMIT`) and commits them
//! again at their next use. Linux drops them with `MADV_DONTNEED`, and
//! macOS with `MADV_FREE_REUSABLE`, and the next write gets zero pages.
//! The pages of the system can be larger than 4 KiB (16 KiB on Apple
//! silicon), so the advice covers only system pages that are free in
//! full.
//!
//! The pool counts no bytes: the heap charges the bytes of each span to
//! the counter of the interpreter, so the memory limit sees the same
//! bytes as with the allocator of the embedder. WebAssembly has no
//! mapping of pages, so there the heap keeps that allocator.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const supported = switch (builtin.os.tag) {
    .windows, .linux, .macos => !builtin.cpu.arch.isWasm(),
    else => false,
};

/// True where the system gives the pages written since the last read
/// (`dirty`), for the minor collections of the heap: Windows, with the
/// write watch of a region (`MEM_WRITE_WATCH` and `GetWriteWatch`). The
/// other systems keep full collections until they get a backend.
pub const dirty_supported = builtin.os.tag == .windows;

pub const page: usize = 4096;
const arena_pages = 1024;
pub const arena_bytes: usize = arena_pages * page;
const words = arena_pages / 64;
/// The longest run of an arena. A longer run is a mapping of its own.
pub const max_run: usize = 256;

const Arena = struct {
    base: usize,
    used: [words]u64 = @splat(0),
    committed: [words]u64 = @splat(0),
    /// The pages that a span had since the arena came from the system.
    touched: [words]u64 = @splat(0),
    nused: u32 = 0,

    fn bit(bits: *const [words]u64, i: usize) bool {
        return bits[i >> 6] >> @intCast(i & 63) & 1 != 0;
    }
    fn set(bits: *[words]u64, i: usize, on: bool) void {
        const m = @as(u64, 1) << @intCast(i & 63);
        if (on) bits[i >> 6] |= m else bits[i >> 6] &= ~m;
    }

    /// The first page of a run of `n` free pages, or null.
    fn findRun(a: *const Arena, n: usize) ?usize {
        var i: usize = 0;
        while (i + n <= arena_pages) {
            const w = a.used[i >> 6];
            // A word with no free page: the next word.
            if (i & 63 == 0 and w == std.math.maxInt(u64)) {
                i += 64;
                continue;
            }
            if (bit(&a.used, i)) {
                i += 1;
                continue;
            }
            var k: usize = 1;
            while (k < n and !bit(&a.used, i + k)) k += 1;
            if (k == n) return i;
            i += k + 1;
        }
        return null;
    }
};

pub const Pool = struct {
    gpa: Allocator,
    /// The arenas, by address.
    arenas: std.ArrayList(*Arena) = .empty,
    /// The bytes of committed pages that no span uses.
    free_committed: usize = 0,
    /// The bytes of the mappings of their own (runs above `max_run`).
    big_bytes: usize = 0,
    /// The bytes that `trim` gave back to the system, for the counts.
    returned: u64 = 0,
    /// True when the last run of `alloc` has a page that held a span before,
    /// with its old bytes: a span of pointers clears it.
    last_reused: bool = false,
    /// The pages of the pool have a write watch (`dirty`).
    watch: bool = false,
    /// The mappings of their own, with a watch, as (base, length).
    bigs: std.ArrayList([2]usize) = .empty,
    /// The addresses that the system gives for `dirty`, in memory of `gpa`:
    /// a collection scans the native stack, and a stale page address there
    /// would keep the blocks of that page.
    watch_buf: []usize = &.{},

    pub fn init(gpa: Allocator) Pool {
        return .{ .gpa = gpa };
    }

    /// A pool whose pages report the writes to them (`dirty`), where the
    /// system can.
    pub fn initWatched(gpa: Allocator) Pool {
        return .{ .gpa = gpa, .watch = dirty_supported };
    }

    /// Calls `cb` with the address of each page of the pool written since
    /// the last call (or `resetDirty`), and starts the watch again. A
    /// page that the system does not report has no write since then.
    pub fn dirty(p: *Pool, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque, addr: usize) void) void {
        if (!p.watch) return;
        if (p.watch_buf.len == 0) {
            p.watch_buf = p.gpa.alloc(usize, 512) catch {
                // With no buffer the watch cannot say which pages: each
                // page of the pool counts as written.
                for (p.arenas.items) |a| everyPage(a.base, arena_bytes, ctx, cb);
                for (p.bigs.items) |b| everyPage(b[0], b[1], ctx, cb);
                return;
            };
        }
        for (p.arenas.items) |a| os.dirtyPages(a.base, arena_bytes, p.watch_buf, ctx, cb);
        for (p.bigs.items) |b| os.dirtyPages(b[0], b[1], p.watch_buf, ctx, cb);
    }

    /// Starts the watch of each page again, with no page written.
    pub fn resetDirty(p: *Pool) void {
        if (!p.watch) return;
        for (p.arenas.items) |a| os.resetWatch(a.base, arena_bytes);
        for (p.bigs.items) |b| os.resetWatch(b[0], b[1]);
    }

    /// Gives each arena back to the system. Each span must be free, or
    /// its memory goes with the arena.
    pub fn deinit(p: *Pool) void {
        for (p.arenas.items) |a| {
            os.release(a.base, arena_bytes);
            p.gpa.destroy(a);
        }
        p.arenas.deinit(p.gpa);
        p.arenas = .empty;
        p.bigs.deinit(p.gpa);
        p.bigs = .empty;
        p.gpa.free(p.watch_buf);
        p.watch_buf = &.{};
        p.free_committed = 0;
    }

    /// `len` bytes, a multiple of `page`, at an address that is a multiple
    /// of `page`, or null.
    pub fn alloc(p: *Pool, len: usize) ?[*]u8 {
        std.debug.assert(len % page == 0 and len > 0);
        const n = len / page;
        p.last_reused = false;
        if (n > max_run) {
            const mem = os.map(len, p.watch) orelse return null;
            if (p.watch) p.bigs.append(p.gpa, .{ mem, len }) catch {
                os.release(mem, len);
                return null;
            };
            p.big_bytes += len;
            return @ptrFromInt(mem);
        }
        for (p.arenas.items) |a| {
            if (arena_pages - a.nused < n) continue;
            const at = a.findRun(n) orelse continue;
            if (p.take(a, at, n)) return @ptrFromInt(a.base + at * page);
            return null;
        }
        const a = p.newArena() orelse return null;
        if (p.take(a, 0, n)) return @ptrFromInt(a.base);
        return null;
    }

    /// Marks the run used, and commits each page of it that is not.
    fn take(p: *Pool, a: *Arena, at: usize, n: usize) bool {
        var need = false;
        var had: usize = 0;
        for (at..at + n) |i| {
            if (Arena.bit(&a.committed, i)) had += 1 else need = true;
            // A committed page that held a span keeps its bytes. A page that
            // got the advice reads as zeros on Windows and Linux, and can
            // keep its bytes on macOS until the system takes it.
            if (Arena.bit(&a.touched, i) and (Arena.bit(&a.committed, i) or builtin.os.tag == .macos)) p.last_reused = true;
        }
        if (need and !os.commit(a.base + at * page, n * page)) return false;
        for (at..at + n) |i| {
            Arena.set(&a.used, i, true);
            Arena.set(&a.committed, i, true);
            Arena.set(&a.touched, i, true);
        }
        a.nused += @intCast(n);
        p.free_committed -= had * page;
        return true;
    }

    fn newArena(p: *Pool) ?*Arena {
        const base = os.reserve(arena_bytes, p.watch) orelse return null;
        const a = p.gpa.create(Arena) catch {
            os.release(base, arena_bytes);
            return null;
        };
        a.* = .{ .base = base };
        // Keep the list by address.
        var i: usize = 0;
        while (i < p.arenas.items.len and p.arenas.items[i].base < base) i += 1;
        p.arenas.insert(p.gpa, i, a) catch {
            os.release(base, arena_bytes);
            p.gpa.destroy(a);
            return null;
        };
        return a;
    }

    fn arenaOf(p: *const Pool, addr: usize) ?*Arena {
        var lo: usize = 0;
        var hi: usize = p.arenas.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const a = p.arenas.items[mid];
            if (addr < a.base) {
                hi = mid;
            } else if (addr >= a.base + arena_bytes) {
                lo = mid + 1;
            } else return a;
        }
        return null;
    }

    /// Frees a run of `alloc`. The pages stay committed until `trim`.
    pub fn free(p: *Pool, ptr: [*]u8, len: usize) void {
        const n = len / page;
        const addr = @intFromPtr(ptr);
        if (n > max_run) {
            if (p.watch) for (p.bigs.items, 0..) |b, i| if (b[0] == addr) {
                _ = p.bigs.swapRemove(i);
                break;
            };
            os.release(addr, len);
            p.big_bytes -= len;
            p.returned += len;
            return;
        }
        const a = p.arenaOf(addr) orelse unreachable;
        const at = (addr - a.base) / page;
        for (at..at + n) |i| Arena.set(&a.used, i, false);
        a.nused -= @intCast(n);
        p.free_committed += n * page;
    }

    /// Gives free committed pages back to the system until at most `keep`
    /// bytes of them stay: the arenas with no page in use first, then
    /// the free pages from the highest arena down. Gives the bytes that
    /// went back.
    pub fn trim(p: *Pool, keep: usize) usize {
        if (p.free_committed <= keep) return 0;
        var back: usize = 0;
        // Empty arenas, from the top. The lowest arena stays, so a small
        // heap does not map and free an arena at each collection.
        var i = p.arenas.items.len;
        while (i > 1 and p.free_committed > keep) {
            i -= 1;
            const a = p.arenas.items[i];
            if (a.nused != 0) continue;
            var committed: usize = 0;
            for (a.committed) |w| committed += @popCount(w);
            releaser.later(a.base, arena_bytes);
            p.free_committed -= committed * page;
            back += committed * page;
            _ = p.arenas.orderedRemove(i);
            p.gpa.destroy(a);
        }
        // The free pages of the other arenas, in whole system pages.
        const sys_page = @max(page, os.pageSize());
        const per = sys_page / page;
        i = p.arenas.items.len;
        while (i > 0 and p.free_committed > keep) {
            i -= 1;
            const a = p.arenas.items[i];
            // A run of system pages to give back, as [run_lo, run_hi) in
            // pages of the arena, with one call of the system for each run.
            var run_lo: usize = 0;
            var run_hi: usize = 0;
            var g: usize = arena_pages / per;
            while (g > 0 and p.free_committed > keep) {
                g -= 1;
                const first = g * per;
                var any = false;
                var ok = true;
                for (first..first + per) |k| {
                    if (Arena.bit(&a.used, k)) ok = false;
                    if (Arena.bit(&a.committed, k)) any = true;
                }
                if (!ok or !any) {
                    if (run_hi > run_lo) os.decommit(a.base + run_lo * page, (run_hi - run_lo) * page);
                    run_hi = run_lo;
                    continue;
                }
                var gone: usize = 0;
                for (first..first + per) |k| {
                    if (Arena.bit(&a.committed, k)) gone += 1;
                    Arena.set(&a.committed, k, false);
                }
                if (run_hi == run_lo) run_hi = first + per;
                run_lo = first;
                p.free_committed -= gone * page;
                back += gone * page;
            }
            if (run_hi > run_lo) os.decommit(a.base + run_lo * page, (run_hi - run_lo) * page);
        }
        p.returned += back;
        return back;
    }
};

/// The release of empty arenas on a thread of its own, so a collection
/// after a peak does not pause while the system unmaps the pages: 200 MB
/// of arenas took 16 ms on Windows. An arena leaves its pool before it
/// goes here, so no span can use its pages again. A full ring, or a build
/// with one thread, releases at once.
const releaser = struct {
    var lock: std.atomic.Mutex = .unlocked;
    var ring: [256][2]usize = undefined;
    var head: usize = 0;
    var len: usize = 0;
    var started = false;
    var seq: std.atomic.Value(u32) = .init(0);

    fn io() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    fn grab() void {
        while (!lock.tryLock()) std.Thread.yield() catch {};
    }

    fn later(base: usize, n: usize) void {
        if (builtin.single_threaded) return os.release(base, n);
        grab();
        if (!started) {
            const t = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, run, .{}) catch {
                lock.unlock();
                return os.release(base, n);
            };
            t.detach();
            started = true;
        }
        if (len == ring.len) {
            lock.unlock();
            return os.release(base, n);
        }
        ring[(head + len) % ring.len] = .{ base, n };
        len += 1;
        lock.unlock();
        _ = seq.fetchAdd(1, .release);
        io().futexWake(u32, &seq.raw, 1);
    }

    fn run() void {
        while (true) {
            const s = seq.load(.acquire);
            grab();
            const got: ?[2]usize = if (len > 0) blk: {
                const r = ring[head];
                head = (head + 1) % ring.len;
                len -= 1;
                break :blk r;
            } else null;
            lock.unlock();
            if (got) |r| {
                os.release(r[0], r[1]);
                continue;
            }
            io().futexWaitTimeout(u32, &seq.raw, s, .{ .duration = .{ .raw = .fromNanoseconds(std.time.ns_per_s), .clock = .awake } }) catch {};
        }
    }
};

/// Calls `cb` with each page of [base, base + len): the answer of a watch
/// that cannot tell which pages have writes.
fn everyPage(base: usize, len: usize, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque, addr: usize) void) void {
    var a = base;
    while (a < base + len) : (a += page) cb(ctx, a);
}

/// The calls of the system for pages.
const os = struct {
    const windows = builtin.os.tag == .windows;
    const mem_commit: u32 = 0x1000;
    const mem_reserve: u32 = 0x2000;
    const mem_decommit: u32 = 0x4000;
    const mem_release: u32 = 0x8000;
    const mem_write_watch: u32 = 0x00200000;
    const write_watch_flag_reset: u32 = 1;
    const page_readwrite: u32 = 0x04;
    const page_noaccess: u32 = 0x01;

    extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, kind: u32, protect: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn VirtualFree(addr: *anyopaque, size: usize, kind: u32) callconv(.winapi) i32;

    /// Addresses with no memory yet: on Windows reserved, elsewhere a
    /// mapping that the system fills on the first write.
    fn reserve(len: usize, watch: bool) ?usize {
        if (windows) {
            const p = VirtualAlloc(null, len, mem_reserve | (if (watch) mem_write_watch else 0), page_noaccess) orelse return null;
            return @intFromPtr(p);
        }
        return posixMap(len);
    }

    /// A mapping of `len` bytes that can hold memory now.
    fn map(len: usize, watch: bool) ?usize {
        if (windows) {
            const p = VirtualAlloc(null, len, mem_reserve | mem_commit | (if (watch) mem_write_watch else 0), page_readwrite) orelse return null;
            return @intFromPtr(p);
        }
        return posixMap(len);
    }

    fn posixMap(len: usize) ?usize {
        if (windows) unreachable;
        const m = std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch return null;
        return @intFromPtr(m.ptr);
    }

    fn commit(addr: usize, len: usize) bool {
        if (windows) return VirtualAlloc(@ptrFromInt(addr), len, mem_commit, page_readwrite) != null;
        return true;
    }

    fn decommit(addr: usize, len: usize) void {
        if (windows) {
            _ = VirtualFree(@ptrFromInt(addr), len, mem_decommit);
            return;
        }
        const advice: u32 = if (builtin.os.tag == .macos) std.c.MADV.FREE_REUSABLE else std.posix.MADV.DONTNEED;
        std.posix.madvise(@ptrFromInt(addr), len, advice) catch {};
    }

    fn release(addr: usize, len: usize) void {
        if (windows) {
            _ = VirtualFree(@ptrFromInt(addr), 0, mem_release);
            return;
        }
        const m: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(addr);
        std.posix.munmap(m[0..len]);
    }

    fn pageSize() usize {
        return std.heap.pageSize();
    }

    extern "kernel32" fn GetWriteWatch(flags: u32, base: *anyopaque, size: usize, addrs: [*]usize, count: *usize, granularity: *u32) callconv(.winapi) u32;
    extern "kernel32" fn ResetWriteWatch(base: *anyopaque, size: usize) callconv(.winapi) u32;

    /// Calls `cb` with each page of [base, base + len) written since the
    /// last reset of its watch, and resets it. The system gives at most a
    /// batch of addresses for each call, so a full batch asks again.
    fn dirtyPages(base: usize, len: usize, addrs: []usize, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque, addr: usize) void) void {
        if (!windows) return;
        while (true) {
            var count: usize = addrs.len;
            var gran: u32 = 0;
            if (GetWriteWatch(write_watch_flag_reset, @ptrFromInt(base), len, addrs.ptr, &count, &gran) != 0) {
                // A failed read says nothing of the pages: each counts as
                // written.
                everyPage(base, len, ctx, cb);
                return;
            }
            for (addrs[0..count]) |a| cb(ctx, a);
            if (count < addrs.len) return;
        }
    }

    fn resetWatch(base: usize, len: usize) void {
        if (!windows) return;
        _ = ResetWriteWatch(@ptrFromInt(base), len);
    }
};

test "pagepool: runs, reuse, and trim" {
    if (!supported) return error.SkipZigTest;
    var p = Pool.init(std.testing.allocator);
    defer p.deinit();
    const a = p.alloc(4 * page).?;
    @memset(a[0 .. 4 * page], 0xab);
    const b = p.alloc(16 * page).?;
    @memset(b[0 .. 16 * page], 0xcd);
    try std.testing.expect(@intFromPtr(b) >= @intFromPtr(a) + 4 * page or @intFromPtr(b) + 16 * page <= @intFromPtr(a));
    try std.testing.expectEqual(@as(usize, 0), p.free_committed);
    p.free(a, 4 * page);
    try std.testing.expectEqual(4 * page, p.free_committed);
    // A run of the same size gets the free pages again.
    const c = p.alloc(4 * page).?;
    try std.testing.expectEqual(@intFromPtr(a), @intFromPtr(c));
    try std.testing.expectEqual(@as(usize, 0), p.free_committed);
    p.free(c, 4 * page);
    p.free(b, 16 * page);
    // Trim to 0: each free committed page goes back, and a page that
    // comes again can be written.
    _ = p.trim(0);
    try std.testing.expectEqual(@as(usize, 0), p.free_committed);
    const d = p.alloc(8 * page).?;
    @memset(d[0 .. 8 * page], 0x11);
    try std.testing.expectEqual(@as(u8, 0x11), d[8 * page - 1]);
    p.free(d, 8 * page);
}

test "pagepool: a large run is a mapping of its own, and arenas go back" {
    if (!supported) return error.SkipZigTest;
    var p = Pool.init(std.testing.allocator);
    defer p.deinit();
    const big = p.alloc(2 << 20).?;
    big[(2 << 20) - 1] = 7;
    try std.testing.expectEqual(@as(usize, 2 << 20), p.big_bytes);
    p.free(big, 2 << 20);
    try std.testing.expectEqual(@as(usize, 0), p.big_bytes);
    // Fill two arenas with runs of 256 pages, free them, and trim.
    var runs: [8][*]u8 = undefined;
    for (&runs) |*r| {
        r.* = p.alloc(max_run * page).?;
        r.*[0] = 1;
    }
    try std.testing.expectEqual(@as(usize, 2), p.arenas.items.len);
    for (runs) |r| p.free(r, max_run * page);
    const back = p.trim(0);
    try std.testing.expectEqual(8 * max_run * page, back);
    // The lowest arena stays for the next spans.
    try std.testing.expectEqual(@as(usize, 1), p.arenas.items.len);
}

fn testDirty(ctx: *anyopaque, addr: usize) void {
    const l: *std.ArrayList(usize) = @ptrCast(@alignCast(ctx));
    l.append(std.testing.allocator, addr) catch {};
}

test "pagepool: the write watch gives the written pages, once" {
    if (!dirty_supported) return error.SkipZigTest;
    var p = Pool.initWatched(std.testing.allocator);
    defer p.deinit();
    const a = p.alloc(8 * page).?;
    const big = p.alloc(2 << 20).?;
    p.resetDirty();
    a[3 * page + 10] = 1;
    big[(1 << 20) + 5] = 2;
    var got: std.ArrayList(usize) = .empty;
    defer got.deinit(std.testing.allocator);
    p.dirty(&got, testDirty);
    std.mem.sort(usize, got.items, {}, std.sort.asc(usize));
    try std.testing.expectEqual(@as(usize, 2), got.items.len);
    const want = [2]usize{ @intFromPtr(a) + 3 * page, @intFromPtr(big) + (1 << 20) };
    std.mem.sort(usize, @constCast(&want), {}, std.sort.asc(usize));
    try std.testing.expectEqualSlices(usize, &want, got.items);
    // The read reset the watch.
    got.clearRetainingCapacity();
    p.dirty(&got, testDirty);
    try std.testing.expectEqual(@as(usize, 0), got.items.len);
    p.free(big, 2 << 20);
    p.free(a, 8 * page);
}

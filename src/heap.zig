//! The heap of an interpreter: pages of blocks in size classes.
//!
//! A page has 4 KiB or more and holds blocks of one size class. A request
//! above 8 KiB, or with an alignment above 16, is a large block with a
//! span of its own. Each span has a free bitmap and a mark bitmap. A set
//! free bit means that the block can be handed out. An allocation uses
//! the lowest set free bit of the current page of its class, so it needs
//! no lookup of an address. A sorted table of the spans gives the block
//! of an address in O(log n). A pointer into the middle of a block gives
//! the block.
//!
//! A request with an alignment below 8 cannot hold a pointer. Such a
//! block goes to pages of its own kind, and a scan of the heap does not
//! read it.
//!
//! The function `free` frees no block. Code of the interpreter keeps views of a buffer
//! after the buffer grows. `resize` succeeds only inside the size of the
//! block, and `remap` never moves a block. The mark and the sweep are at
//! the end of the file. They free the blocks that no root reaches.
//!
//! Each span starts on a 4 KiB boundary. At the start of a collection,
//! a hash table of the 4 KiB chunks of the spans gives the span of an
//! address in about one probe. The mark uses it for each candidate word.
//!
//! An allocation does not start a collection. The interpreter starts
//! one at a safe point (see `Interp.memPoint`). Only the stress mode of
//! a native build collects inside an allocation.
//!
//! An optimizing compiler can keep a pointer just outside a block in a
//! native frame: the end of a slice, or one element before the start.
//! So a word of a native stack also keeps the block before it and the
//! block after it. A word in a heap block has no such margin.
//!
//! All memory comes from the backing allocator, so the counting
//! allocator of the interpreter sees each byte. The heap is not thread
//! safe.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const pagepool = @import("pagepool.zig");

/// The bytes of a page. A small heap uses pages of 4 KiB and at least
/// four blocks, so a short script holds little memory. A larger heap
/// uses 16 KiB and at least eight blocks.
fn pageBytes(size: usize, heap_bytes: usize) usize {
    if (heap_bytes < small_heap) return @max(4096, std.mem.alignForward(usize, size * 4, 4096));
    return @max(16 * 1024, std.mem.alignForward(usize, size * 8, 4096));
}
const small_heap: usize = 2 << 20;
/// The largest block of a size class.
pub const max_small: usize = 8192;
const max_small_align = 16;
const chunk_shift = 12;
const span_align: Alignment = .fromByteUnits(1 << chunk_shift);
pub const class_count = 32;
const kinds = 2;
/// The least heap size for a collection.
pub const min_threshold: usize = 16 * 1024 * 1024;

/// The block size of each class: 16 to 128 in steps of 16, then four
/// classes for each power of two up to 8 KiB.
const class_size: [class_count]u32 = blk: {
    var t: [class_count]u32 = undefined;
    for (0..8) |i| t[i] = 16 * (i + 1);
    for (8..class_count) |c| {
        const octave = (c - 8) / 4;
        const step = (c - 8) % 4;
        t[c] = (128 << octave) + (32 << octave) * (step + 1);
    }
    break :blk t;
};

fn classOf(len: usize) usize {
    if (len <= 128) return (@max(len, 1) + 15) / 16 - 1;
    const n = len - 1;
    const msb: usize = @bitSizeOf(usize) - 1 - @clz(n);
    const shift: std.math.Log2Int(usize) = @intCast(msb - 2);
    return 8 + (msb - 7) * 4 + ((n >> shift) & 3);
}

/// The fill of a freed block in a build with safety checks.
pub const dead_byte: u8 = 0xDD;
const fill_dead = builtin.mode == .debug or builtin.mode == .safe;

pub const Span = struct {
    base: usize,
    /// The bytes of the span.
    len: usize,
    /// The bytes of one block. For a large block, the bytes of the block.
    size: u32,
    count: u32,
    nwords: u32,
    /// The first word of `free` that can have a set bit.
    cursor: u32 = 0,
    class: u8,
    noscan: bool,
    large: bool,
    alignment: Alignment = .@"16",
    /// True for a span of the page pool of the heap.
    pooled: bool = false,
    /// True for a span of the pool with the watch of writes (`wpool`).
    watched: bool = false,
    next: ?*Span = null,
    /// A set bit: the block is free.
    free: []u64,
    /// A set bit: a root reaches the block.
    mark: []u64,

    fn blockIndex(s: *const Span, addr: usize) usize {
        if (s.large) return 0;
        return (addr - s.base) / s.size;
    }

    fn isFree(s: *const Span, i: usize) bool {
        return s.free[i >> 6] >> @intCast(i & 63) & 1 != 0;
    }
};

pub const Heap = struct {
    backing: Allocator,
    /// The bytes of the heap at which the next collection starts.
    threshold: usize = min_threshold,
    /// The spans, sorted by address.
    spans: std.ArrayList(*Span) = .empty,
    lo: usize = std.math.maxInt(usize),
    hi: usize = 0,
    /// The page that serves the allocations of a class and a kind.
    cur: [kinds * class_count]?*Span = @splat(null),
    /// The pages of a class and a kind with free blocks, but not `cur`.
    partial: [kinds * class_count]?*Span = @splat(null),
    /// The bytes that the spans hold.
    bytes: usize = 0,
    /// Called at the start of a collection to mark the roots.
    roots_fn: ?*const fn (ctx: *anyopaque, h: *Heap) bool = null,
    roots_ctx: *anyopaque = undefined,
    /// The work list of the mark. It lives outside the heap.
    work: std.ArrayList(Range) = .empty,
    /// False when the work list could not grow: the sweep must not run.
    mark_ok: bool = true,
    live_bytes: usize = 0,
    collections: u64 = 0,
    /// The counts of the collections, for `ztcl::gc stats`.
    stats: Stats = .{},
    /// The pages of the spans, from the system (`pagepool.zig`), when the
    /// embedder gave `charge` (`usePool`). Null: the backing allocator.
    pool: ?pagepool.Pool = null,
    /// The pool of the pages of pointers in the generational mode, with the
    /// watch of writes. `pool` then has the pages of the other spans.
    wpool: ?pagepool.Pool = null,
    charge: ?Charge = null,
    /// Generational collection with sticky mark bits: a minor collection
    /// keeps the marks of the old blocks, and marks only the new blocks that
    /// the roots and the old blocks on pages written since the last
    /// collection reach (`collectKind`). On where the page pool can watch
    /// its pages for writes.
    gen: bool = false,
    /// The minor collections since the last major one, and the live bytes
    /// after that major one.
    minors: u32 = 0,
    live_major: usize = 0,
    /// The next collection must be major: the marks or the watch of the
    /// writes are not whole.
    need_major: bool = true,
    /// True while the sweep of a minor collection runs.
    sweep_minor: bool = false,
    /// The bytes in use after the last sweep or `resetStats`: the base of
    /// the count of allocated bytes.
    alloc_base: usize = 0,
    /// Above zero, each safe point of this count starts a collection.
    /// The count grows by its own value for each 16 MiB of heap.
    stress: u32 = 0,
    /// The count of host entries that run in this interpreter tree. Only
    /// the first entry can make the native stack scannable.
    scopes: u32 = 0,
    /// True when the stress mode also collects inside an allocation.
    /// This needs a scan of the native stack.
    stress_alloc: bool = false,
    /// The span of each 4 KiB chunk during a mark. Empty when the table
    /// could not grow: the mark then uses the sorted list.
    table: []?*Span = &.{},
    table_on: bool = false,
    table_shift: std.math.Log2Int(usize) = 0,
    /// The span of the last address that the mark found.
    last: ?*Span = null,
    stress_left: u32 = 0,
    /// The character counts of the last long strings in heap blocks.
    /// The bytes of a block do not change while the block is live, so
    /// an entry stays true until a sweep or a reset frees blocks.
    counts: [4]Count = @splat(.{}),
    next_count: u8 = 0,

    pub const Count = struct { ptr: usize = 0, len: usize = 0, n: usize = 0 };

    /// The counts of the collections. The times come from a clock that
    /// does not go back (`meter.monoNs`), read only at the start, the end
    /// of the mark, and the end of the sweep, so an allocation costs no
    /// more. The bytes that the program allocated are counted at each
    /// collection: the blocks in use before the sweep, less the live
    /// bytes after the last one.
    pub const Stats = struct {
        gc_ns: u64 = 0,
        mark_ns: u64 = 0,
        sweep_ns: u64 = 0,
        max_pause_ns: u64 = 0,
        /// The pauses of the last `pause_ring` collections, in ns, for the
        /// percentiles.
        pauses: [pause_ring]u32 = @splat(0),
        npauses: u64 = 0,
        /// The major collections of the generational mode. Without it each
        /// collection is major.
        majors: u64 = 0,
        /// The bytes that the program allocated up to the last
        /// collection, and the bytes that the sweeps freed.
        allocated: u64 = 0,
        freed: u64 = 0,
        peak_bytes: usize = 0,
        /// The clock at the start of the counts.
        start_ns: u64 = 0,

        pub const pause_ring = 1024;

        fn pause(st: *Stats, ns: u64) void {
            st.pauses[@intCast(st.npauses % pause_ring)] = @intCast(@min(ns, std.math.maxInt(u32)));
            st.npauses += 1;
            st.max_pause_ns = @max(st.max_pause_ns, ns);
        }

        /// The pause at fraction `q` (0.5 for the median) of the pauses in
        /// the ring, in ns. 0 with no collection.
        pub fn percentile(st: *const Stats, q: f64, scratch: *[pause_ring]u32) u64 {
            const n: usize = @intCast(@min(st.npauses, pause_ring));
            if (n == 0) return 0;
            @memcpy(scratch[0..n], st.pauses[0..n]);
            std.mem.sort(u32, scratch[0..n], {}, std.sort.asc(u32));
            const at: usize = @intFromFloat(@floor(q * @as(f64, @floatFromInt(n - 1)) + 0.5));
            return scratch[@min(at, n - 1)];
        }
    };

    /// The bytes of the blocks in use: each block of a size class with a
    /// clear free bit, and each large block.
    pub fn usedBytes(h: *const Heap) usize {
        var used: usize = 0;
        for (h.spans.items) |s| {
            if (s.large) {
                used += s.len;
                continue;
            }
            var nfree: usize = 0;
            for (s.free[0..s.nwords]) |w| nfree += @popCount(w);
            used += (s.count - nfree) * s.size;
        }
        return used;
    }

    /// The bytes that the program allocated since the start of the counts.
    pub fn allocatedBytes(h: *const Heap) u64 {
        return h.stats.allocated + (h.usedBytes() -| h.alloc_base);
    }

    /// Starts the counts again, as at a new heap.
    pub fn resetStats(h: *Heap, now_ns: u64) void {
        h.stats = .{ .start_ns = now_ns, .peak_bytes = h.bytes, .allocated = 0 };
        h.alloc_base = h.usedBytes();
    }

    pub const Range = struct { ptr: usize, len: usize, stack: bool = false };

    pub fn init(backing: Allocator) Heap {
        return .{ .backing = backing };
    }

    /// The charge of the bytes of a span of the pool to the counter of the
    /// interpreter: `add` true for a new span, which can fail at the memory
    /// limit, and false for a freed one.
    pub const Charge = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, len: usize, add: bool) bool,
    };

    /// Gets the pages of the spans from the system, with their bytes
    /// charged to `c`, where the target has a page pool. Call it before the
    /// first allocation.
    pub fn usePool(h: *Heap, c: Charge) void {
        if (comptime !pagepool.supported) return;
        std.debug.assert(h.spans.items.len == 0);
        h.pool = pagepool.Pool.init(h.backing);
        if (pagepool.dirty_supported) h.wpool = pagepool.Pool.initWatched(h.backing);
        h.charge = c;
        h.gen = pagepool.dirty_supported;
    }

    /// The bytes of free pages that the pool keeps after a sweep: the pages
    /// that the heap fills before its next collection (the threshold less
    /// the bytes of its spans), and at least 4 MiB. A heap at a steady
    /// size then gives back no page, and a heap after a peak gives back
    /// the pages above its new threshold.
    fn keepFree(h: *const Heap) usize {
        return @max(4 << 20, h.threshold -| h.bytes);
    }

    /// Frees all memory of the heap.
    pub fn deinit(h: *Heap) void {
        h.reset();
        if (h.pool) |*p| p.deinit();
        if (h.wpool) |*p| p.deinit();
        h.wpool = null;
        h.pool = null;
        h.spans.deinit(h.backing);
        h.work.deinit(h.backing);
        h.backing.free(h.table);
        h.table = &.{};
        h.table_on = false;
        h.spans = .empty;
        h.work = .empty;
    }

    /// Frees each span and keeps the heap usable.
    pub fn reset(h: *Heap) void {
        for (h.spans.items) |s| h.freeSpan(s);
        if (h.pool) |*p| _ = p.trim(4 << 20);
        if (h.wpool) |*p| _ = p.trim(4 << 20);
        h.spans.clearRetainingCapacity();
        h.cur = @splat(null);
        h.partial = @splat(null);
        h.last = null;
        h.lo = std.math.maxInt(usize);
        h.hi = 0;
        h.bytes = 0;
        h.live_bytes = 0;
        h.threshold = min_threshold;
        h.alloc_base = 0;
        h.need_major = true;
        h.minors = 0;
        h.live_major = 0;
        h.counts = @splat(.{});
    }

    /// The stored character count of `s`, or null.
    pub inline fn cachedCount(h: *const Heap, s: []const u8) ?usize {
        for (&h.counts) |*c| {
            if (c.ptr == @intFromPtr(s.ptr) and c.len == s.len) return c.n;
        }
        return null;
    }

    /// Stores the character count of `s` when its bytes are in a block
    /// of this heap. Other memory can change, so it gets no entry.
    pub fn putCount(h: *Heap, s: []const u8, n: usize) void {
        if (h.find(@intFromPtr(s.ptr)) == null) return;
        h.counts[h.next_count] = .{ .ptr = @intFromPtr(s.ptr), .len = s.len, .n = n };
        h.next_count = @intCast((h.next_count + 1) % h.counts.len);
    }

    pub fn allocator(h: *Heap) Allocator {
        return .{ .ptr = h, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Allocates a span record with its two bitmaps after it.
    fn makeSpan(h: *Heap, words: usize, t: Span) ?*Span {
        const raw = h.backing.rawAlloc(@sizeOf(Span) + words * 16, .of(Span), 0) orelse return null;
        const s: *Span = @ptrCast(@alignCast(raw));
        const bits: [*]u64 = @ptrCast(@alignCast(raw + @sizeOf(Span)));
        s.* = t;
        s.nwords = @intCast(words);
        s.free = bits[0..words];
        s.mark = bits[words .. words * 2];
        @memset(s.free, 0);
        @memset(s.mark, 0);
        return s;
    }

    fn freeMeta(h: *Heap, s: *Span) void {
        const raw: [*]u8 = @ptrCast(s);
        h.backing.rawFree(raw[0 .. @sizeOf(Span) + s.nwords * 16], .of(Span), 0);
    }

    fn freeSpan(h: *Heap, s: *Span) void {
        h.spanFree(@ptrFromInt(s.base), s.len, s.alignment, s.pooled, s.watched);
        h.freeMeta(s);
    }

    const SpanMem = struct { mem: [*]u8, pooled: bool, watched: bool };

    /// The memory of a span of `len` bytes: from the page pool when the
    /// heap has one and the alignment is at most a page, else from the
    /// backing allocator. The pool rounds the run up to whole pages, and
    /// the span and the counter keep `len`, so the threshold and the memory
    /// limit see the same bytes as with the allocator of the embedder.
    fn spanMem(h: *Heap, len: usize, a: Alignment, noscan: bool) ?SpanMem {
        if (h.pool != null and a.toByteUnits() <= pagepool.page) {
            // The pages of pointers come from the pool with the watch of
            // writes, and the others from the pool with none, so the read
            // of the written pages covers only the pages that a minor
            // collection scans.
            const watched = h.wpool != null and !noscan;
            const pool = if (watched) &h.wpool.? else &h.pool.?;
            const c = h.charge.?;
            if (!c.func(c.ctx, len, true)) return null;
            const mem = pool.alloc(std.mem.alignForward(usize, len, pagepool.page)) orelse {
                _ = c.func(c.ctx, len, false);
                return null;
            };
            // A span of pointers on pages that held a span before starts at
            // zero: a scan of a block reads its bytes past its own data, and
            // the old pointers there would keep their blocks.
            if (!noscan and pool.last_reused) @memset(mem[0..len], 0);
            return .{ .mem = mem, .pooled = true, .watched = watched };
        }
        const mem = h.backing.rawAlloc(len, a, 0) orelse return null;
        return .{ .mem = mem, .pooled = false, .watched = false };
    }

    fn spanFree(h: *Heap, mem: [*]u8, len: usize, a: Alignment, pooled: bool, watched: bool) void {
        if (pooled) {
            const pool = if (watched) &h.wpool.? else &h.pool.?;
            pool.free(mem, std.mem.alignForward(usize, len, pagepool.page));
            const c = h.charge.?;
            _ = c.func(c.ctx, len, false);
            return;
        }
        h.backing.rawFree(mem[0..len], a, 0);
    }

    /// The index in `spans` of the first span that ends above `addr`.
    fn lowerBound(h: *const Heap, addr: usize) usize {
        var lo: usize = 0;
        var hi: usize = h.spans.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const s = h.spans.items[mid];
            if (s.base + s.len <= addr) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Builds the chunk table for one mark.
    fn buildTable(h: *Heap) void {
        h.table_on = false;
        var chunks: usize = 0;
        for (h.spans.items) |s| chunks += (s.len + (1 << chunk_shift) - 1) >> chunk_shift;
        if (chunks == 0) return;
        const want = std.math.ceilPowerOfTwo(usize, chunks * 2) catch return;
        if (h.table.len < want) {
            const t = h.backing.alloc(?*Span, want) catch return;
            h.backing.free(h.table);
            h.table = t;
        }
        const size = std.math.ceilPowerOfTwo(usize, h.table.len) catch return;
        const table = h.table[0..size];
        @memset(table, null);
        h.table_shift = @intCast(@bitSizeOf(usize) - @ctz(size));
        for (h.spans.items) |s| {
            var c = s.base >> chunk_shift;
            const end = (s.base + s.len - 1) >> chunk_shift;
            while (c <= end) : (c += 1) {
                var i = chunkHash(c) >> h.table_shift;
                while (table[i] != null) i = (i + 1) & (size - 1);
                table[i] = s;
            }
        }
        h.table_on = true;
    }

    inline fn chunkHash(c: usize) usize {
        return c *% @as(usize, @truncate(0x9e3779b97f4a7c15));
    }

    /// The span of a candidate word during a mark.
    pub inline fn lookup(h: *const Heap, addr: usize) ?*Span {
        if (!h.table_on) return h.find(addr);
        const mask = (@as(usize, 1) << @intCast(@bitSizeOf(usize) - @as(usize, h.table_shift))) - 1;
        var i = chunkHash(addr >> chunk_shift) >> h.table_shift;
        while (h.table[i]) |s| : (i = (i + 1) & mask) {
            if (addr -% s.base < s.len) return s;
        }
        return null;
    }

    /// The span that holds `addr`, or null.
    pub fn find(h: *const Heap, addr: usize) ?*Span {
        if (addr < h.lo or addr >= h.hi) return null;
        const i = h.lowerBound(addr);
        if (i == h.spans.items.len) return null;
        const s = h.spans.items[i];
        if (addr < s.base) return null;
        return s;
    }

    fn insert(h: *Heap, s: *Span) Allocator.Error!void {
        const i = h.lowerBound(s.base);
        try h.spans.insert(h.backing, i, s);
        h.lo = @min(h.lo, s.base);
        h.hi = @max(h.hi, s.base + s.len);
        h.bytes += s.len;
        h.stats.peak_bytes = @max(h.stats.peak_bytes, h.bytes);
        if (h.stats.start_ns == 0) h.stats.start_ns = @max(1, clock());
    }

    fn newPage(h: *Heap, index: usize) ?*Span {
        const class = index % class_count;
        const size = class_size[class];
        const page = pageBytes(size, h.bytes);
        const count: usize = page / size;
        const got = h.spanMem(page, span_align, index >= class_count) orelse return null;
        const mem = got.mem;
        const s = h.makeSpan((count + 63) / 64, .{
            .base = @intFromPtr(mem),
            .len = page,
            .pooled = got.pooled,
            .watched = got.watched,
            .size = size,
            .count = @intCast(count),
            .nwords = 0,
            .class = @intCast(class),
            .noscan = index >= class_count,
            .large = false,
            .alignment = span_align,
            .free = &.{},
            .mark = &.{},
        }) orelse {
            h.spanFree(mem, page, span_align, got.pooled, got.watched);
            return null;
        };
        var i: usize = 0;
        while (i < count) : (i += 1) s.free[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
        h.insert(s) catch {
            h.freeSpan(s);
            return null;
        };
        return s;
    }

    fn allocLarge(h: *Heap, len: usize, alignment: Alignment) ?[*]u8 {
        const a = alignment.max(span_align);
        const size = std.mem.alignForward(usize, len, 16);
        const got = h.spanMem(size, a, alignment.toByteUnits() < @sizeOf(usize)) orelse return null;
        const mem = got.mem;
        const s = h.makeSpan(1, .{
            .base = @intFromPtr(mem),
            .len = size,
            .pooled = got.pooled,
            .watched = got.watched,
            .size = @intCast(@min(size, std.math.maxInt(u32))),
            .count = 1,
            .nwords = 0,
            .class = 0,
            .noscan = alignment.toByteUnits() < @sizeOf(usize),
            .large = true,
            .alignment = a,
            .free = &.{},
            .mark = &.{},
        }) orelse {
            h.spanFree(mem, size, a, got.pooled, got.watched);
            return null;
        };
        h.insert(s) catch {
            h.freeSpan(s);
            return null;
        };
        return mem;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const h: *Heap = @ptrCast(@alignCast(ctx));
        if (h.stress_alloc) h.stressTick();
        if (len > max_small or alignment.toByteUnits() > max_small_align) return h.allocLarge(len, alignment);
        const kind: usize = @intFromBool(alignment.toByteUnits() < @sizeOf(usize));
        const index = kind * class_count + classOf(len);
        if (h.cur[index]) |s| {
            const w = s.free[s.cursor];
            if (w != 0) {
                s.free[s.cursor] = w & (w - 1);
                const bit = s.cursor * 64 + @ctz(w);
                return @ptrFromInt(s.base + bit * s.size);
            }
        }
        return h.allocSlow(index);
    }

    /// Finds a page with a free block for the class, or makes one.
    fn allocSlow(h: *Heap, index: usize) ?[*]u8 {
        while (true) {
            if (h.cur[index]) |s| {
                while (s.cursor < s.nwords) : (s.cursor += 1) {
                    const w = s.free[s.cursor];
                    if (w == 0) continue;
                    s.free[s.cursor] = w & (w - 1);
                    const bit = s.cursor * 64 + @ctz(w);
                    return @ptrFromInt(s.base + bit * s.size);
                }
                h.cur[index] = null;
            }
            if (h.partial[index]) |p| {
                h.partial[index] = p.next;
                p.next = null;
                h.cur[index] = p;
                continue;
            }
            h.cur[index] = h.newPage(index) orelse return null;
        }
    }

    fn stressTick(h: *Heap) void {
        if (h.stressDue()) collect(h);
    }

    /// Counts one stress event. True when a collection is due.
    pub fn stressDue(h: *Heap) bool {
        if (h.stress_left > 1) {
            h.stress_left -= 1;
            return false;
        }
        // A large heap makes a collection slow, so the gap grows with the
        // heap: one more step for each 16 MiB.
        h.stress_left = h.stress * @as(u32, @intCast(@min(1 + (h.bytes >> 24), 1 << 16)));
        return true;
    }

    fn resize(ctx: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
        const h: *Heap = @ptrCast(@alignCast(ctx));
        const s = h.find(@intFromPtr(memory.ptr)) orelse return false;
        return new_len <= (if (s.large) s.len else s.size);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
    }

    fn free(_: *anyopaque, _: []u8, _: Alignment, _: usize) void {}
};

// ---- The mark and the sweep ----

/// Marks the block that holds the word `w`, when the word is an address
/// of a live block. The block goes on the work list, unless it holds no
/// pointer.
pub fn markWord(h: *Heap, w: usize) void {
    if (w < h.lo or w >= h.hi) return;
    markHit(h, w);
}

/// `markWord` for a word inside the bounds of the heap.
fn markHit(h: *Heap, w: usize) void {
    // Pointers cluster, so the span of the last hit often serves.
    const s = if (h.last) |l| (if (w -% l.base < l.len) l else h.lookup(w)) else h.lookup(w);
    const sp = s orelse return;
    h.last = sp;
    return markIn(h, sp, w);
}

inline fn markIn(h: *Heap, s: *Span, w: usize) void {
    var idx: usize = 0;
    if (!s.large) {
        idx = (w - s.base) / s.size;
        if (idx >= s.count) return;
    }
    const word = idx >> 6;
    const bit = @as(u64, 1) << @intCast(idx & 63);
    if (s.free[word] & bit != 0 or s.mark[word] & bit != 0) return;
    s.mark[word] |= bit;
    if (s.noscan) return;
    const start = if (s.large) s.base else s.base + idx * s.size;
    const is_stack = s.large and s.len == coro_stack_bytes;
    h.work.append(h.backing, .{ .ptr = start, .len = if (s.large) s.len else s.size, .stack = is_stack }) catch {
        h.mark_ok = false;
    };
}

/// True when the block of `addr` has its mark bit. An address outside
/// the heap counts as marked: such memory does not go away.
/// True when the block of `addr` is free in its span, or when no span
/// holds `addr`. A large span is live while it is in the heap. Tests
/// read it to see the result of a sweep with no read of freed bytes.
pub fn isFree(h: *const Heap, addr: usize) bool {
    if (addr < h.lo or addr >= h.hi) return true;
    const s = h.lookup(addr) orelse return true;
    if (s.large) return false;
    const idx = (addr - s.base) / s.size;
    if (idx >= s.count) return true;
    return s.free[idx >> 6] >> @intCast(idx & 63) & 1 != 0;
}

pub fn isMarked(h: *const Heap, addr: usize) bool {
    if (addr < h.lo or addr >= h.hi) return true;
    const s = h.lookup(addr) orelse return true;
    var idx: usize = 0;
    if (!s.large) {
        idx = (addr - s.base) / s.size;
        if (idx >= s.count) return true;
    }
    return s.mark[idx >> 6] >> @intCast(idx & 63) & 1 != 0;
}

/// The bytes of a coroutine stack. A block of this size is scanned as a
/// native stack. A list of the same size gets a wider margin, and that
/// is safe. A test checks this number against `coro.zig`.
pub const coro_stack_bytes: usize = if (builtin.mode == .debug) 16 << 20 else 1 << 20;
/// The bytes that a native pointer can be before the start of its block.
/// A stack word also marks the block that holds the address 64 bytes
/// higher: a pointer at most 64 bytes below the start of a block keeps it
/// only if that address falls in the block. This is not a full range scan.
const stack_margin: usize = 64;

/// Reads each aligned word of a native stack as a possible pointer, with
/// the margin for a pointer just outside a block.
pub fn markStack(h: *Heap, ptr: usize, len: usize) void {
    scanStack(h, ptr, len);
    drain(h);
}

fn scanStack(h: *Heap, ptr: usize, len: usize) void {
    const first = std.mem.alignForward(usize, ptr, @sizeOf(usize));
    const end = ptr +| len;
    if (end < first + @sizeOf(usize)) return;
    var p = first;
    while (p + @sizeOf(usize) <= end) : (p += @sizeOf(usize)) {
        const w = @as(*const usize, @ptrFromInt(p)).*;
        markWord(h, w);
        markWord(h, w -% 1);
        markWord(h, w +% stack_margin);
    }
}

/// Reads each aligned word of the range as a possible pointer and marks
/// what the words reach.
pub fn markRange(h: *Heap, ptr: usize, len: usize) void {
    scan(h, ptr, len);
    drain(h);
}

fn scan(h: *Heap, ptr: usize, len: usize) void {
    const first = std.mem.alignForward(usize, ptr, @sizeOf(usize));
    const end = ptr +| len;
    if (end < first + @sizeOf(usize)) return;
    // Most words are not addresses of the heap, so the bound check is
    // inline and the lookup is a call.
    const lo = h.lo;
    const span = h.hi -% lo;
    var p = first;
    while (p + @sizeOf(usize) <= end) : (p += @sizeOf(usize)) {
        const w = @as(*const usize, @ptrFromInt(p)).*;
        if (w -% lo < span) markHit(h, w);
    }
}

fn drain(h: *Heap) void {
    while (h.work.pop()) |r| {
        if (r.stack) scanStack(h, r.ptr, r.len) else scan(h, r.ptr, r.len);
    }
}

/// Runs a collection. The roots come from `roots_fn`. The sweep frees
/// each block that no root reached. A failed mark frees no block. In the
/// generational mode it can be a minor collection (`collectKind`).
pub fn collect(h: *Heap) void {
    collectKind(h, false);
    clearStack();
}

/// Runs a major collection: each block that no root reaches goes, old or
/// new. For an explicit collection and at the memory limit.
pub fn collectMajor(h: *Heap) void {
    collectKind(h, true);
    clearStack();
}

/// The most minor collections in a row.
const max_minors = 8;

/// A collection. With `gen` it is minor unless `major`, `need_major`,
/// `max_minors` minor ones in a row, or a live set that doubled since the
/// last major one.
///
/// The invariant of the sticky marks: after each collection, each block
/// that a marked block points to is marked. A major collection clears
/// each mark and marks from the roots, so it holds. A minor one keeps the
/// marks: a marked (old) block is not marked again, so the mark of a
/// root that reaches it stops there. A store into an old block after the
/// last collection is on a page that the pool reports as written
/// (`Pool.dirty`), so the minor collection scans each marked block of
/// each such page as a root, and the invariant holds again. A block that
/// lost its last reference while old stays until the next major one.
noinline fn collectKind(h: *Heap, major_asked: bool) void {
    const roots = h.roots_fn orelse return;
    const t0 = clock();
    defer {
        const t2 = clock();
        h.stats.gc_ns += t2 -| t0;
        h.stats.pause(t2 -| t0);
    }
    const major = !h.gen or major_asked or h.need_major or h.minors >= max_minors or
        h.live_bytes > 2 * @max(h.live_major, min_threshold / 2);
    h.mark_ok = true;
    h.work.clearRetainingCapacity();
    h.buildTable();
    defer h.table_on = false;
    if (h.gen) {
        if (major) {
            for (h.spans.items) |s| @memset(s.mark, 0);
            if (h.wpool) |*p| p.resetDirty();
        } else markOld(h);
    }
    if (!roots(h.roots_ctx, h)) {
        // A mark that stopped early leaves mark bits. With the marks of
        // the old blocks gone, the next collection must be major.
        h.mark_ok = false;
        h.need_major = true;
        h.work.clearRetainingCapacity();
        for (h.spans.items) |s| @memset(s.mark, 0);
        return;
    }
    drain(h);
    h.work.clearRetainingCapacity();
    if (!h.mark_ok) h.need_major = true;
    if (h.mark_ok) h.collections += 1;
    const t1 = clock();
    h.stats.mark_ns += t1 -| t0;
    h.sweep_minor = h.gen and !major;
    sweep(h);
    h.sweep_minor = false;
    h.stats.sweep_ns += clock() -| t1;
    if (h.gen and h.mark_ok) {
        if (major) {
            h.live_major = h.live_bytes;
            h.minors = 0;
            h.need_major = false;
            h.stats.majors += 1;
        } else h.minors += 1;
    }
}

/// Writes zeros to the stack below the frame of the caller, where the
/// frames of the collection were. Those frames held the addresses of old
/// blocks (`markOld`). A later call can leave such a slot as it is, and
/// the scan of the stack of the next collection would read it as a
/// pointer: a stale address of a large list kept its old copies, 35 MB,
/// through each major collection. `collectKind` is noinline, so its frame
/// is below the caller of this, with the frames of the mark.
noinline fn clearStack() void {
    var buf: [32 * 1024]u8 = undefined;
    const v: *volatile [32 * 1024]u8 = &buf;
    @memset(v, 0);
}

/// The roots of a minor collection: each marked block on a page written
/// since the last collection, and each marked block of a span outside
/// the pool, which has no watch.
fn markOld(h: *Heap) void {
    if (h.wpool) |*p| p.dirty(h, dirtyPage);
    for (h.spans.items) |s| {
        if (!s.pooled and !s.noscan) scanOld(h, s, s.base, s.base + s.len);
    }
}

fn dirtyPage(ctx: *anyopaque, addr: usize) void {
    const h: *Heap = @ptrCast(@alignCast(ctx));
    const s = h.lookup(addr) orelse return;
    if (s.noscan) return;
    scanOld(h, s, addr, addr + pagepool.page);
}

/// Scans the marked blocks of `s` in [lo, hi): of a large block, only the
/// written range, and of a span of a class, each marked block that the
/// range touches.
fn scanOld(h: *Heap, s: *Span, lo: usize, hi: usize) void {
    if (s.large) {
        if (s.mark[0] & 1 == 0) return;
        const a = @max(lo, s.base);
        const b = @min(hi, s.base + s.len);
        if (b <= a) return;
        if (s.len == coro_stack_bytes) scanStack(h, a, b - a) else scan(h, a, b - a);
        return;
    }
    const a = @max(lo, s.base);
    const b = @min(hi, s.base + @as(usize, s.count) * s.size);
    if (b <= a) return;
    const first = (a - s.base) / s.size;
    const last = (b - 1 - s.base) / s.size;
    // The set bits of the mark words of the range: a page of new blocks
    // has none, and costs a few loads.
    var w = first >> 6;
    while (w <= last >> 6) : (w += 1) {
        var m = s.mark[w];
        if (w == first >> 6) m &= ~@as(u64, 0) << @intCast(first & 63);
        if (w == last >> 6 and last & 63 != 63) m &= (@as(u64, 1) << @intCast((last & 63) + 1)) - 1;
        while (m != 0) : (m &= m - 1) {
            const i = w * 64 + @ctz(m);
            scan(h, s.base + i * s.size, s.size);
        }
    }
}

fn clock() u64 {
    return @import("meter.zig").monoNs();
}

fn sweep(h: *Heap) void {
    if (!h.mark_ok) {
        for (h.spans.items) |s| @memset(s.mark, 0);
        return;
    }
    h.cur = @splat(null);
    h.partial = @splat(null);
    h.last = null;
    h.counts = @splat(.{});
    // The stress mode poisons in each build, so a suite run in
    // ReleaseFast also shows a use of a freed block.
    const poison = fill_dead or h.stress != 0;
    const before = h.bytes;
    var live_bytes: usize = 0;
    // The bytes of the blocks in use before the sweep: live and dead.
    var used_before: usize = 0;
    var keep: usize = 0;
    const items = h.spans.items;
    for (items) |s| {
        if (s.large) {
            used_before += s.len;
            if (s.mark[0] == 0) {
                if (poison) @memset(@as([*]u8, @ptrFromInt(s.base))[0..s.len], dead_byte);
                h.bytes -= s.len;
                h.freeSpan(s);
                continue;
            }
            // The generational mode keeps the marks: the block is old.
            if (!h.gen) s.mark[0] = 0;
            live_bytes += s.len;
            items[keep] = s;
            keep += 1;
            continue;
        }
        var live: usize = 0;
        var any_free = false;
        for (0..s.nwords) |w| {
            var valid: u64 = ~@as(u64, 0);
            const rest = s.count - w * 64;
            if (rest < 64) valid = (@as(u64, 1) << @intCast(rest)) - 1;
            const m = s.mark[w];
            const new_free = ~m & valid;
            used_before += @as(usize, @popCount(~s.free[w] & valid)) * s.size;
            // A dead block of pointers goes to zero, so its next owner does not
            // keep its old pointers in the bytes past its own data.
            if (poison or !s.noscan) {
                var dead = new_free & ~s.free[w];
                const fill: u8 = if (poison) dead_byte else 0;
                while (dead != 0) : (dead &= dead - 1) {
                    const i = w * 64 + @ctz(dead);
                    @memset(@as([*]u8, @ptrFromInt(s.base + i * s.size))[0..s.size], fill);
                }
            }
            s.free[w] = new_free;
            if (!h.gen) s.mark[w] = 0;
            live += @popCount(m);
            if (new_free != 0) any_free = true;
        }
        if (live == 0) {
            h.bytes -= s.len;
            h.freeSpan(s);
            continue;
        }
        live_bytes += live * s.size;
        s.cursor = 0;
        // After a minor collection a span with old blocks and pointers serves
        // no new block until the next major one: a new block on its page
        // would mark the page as written, and the next minor collection
        // would scan each old block of the page.
        if (any_free and (s.noscan or !h.sweep_minor)) {
            const index = @as(usize, @intFromBool(s.noscan)) * class_count + s.class;
            s.next = h.partial[index];
            h.partial[index] = s;
        }
        items[keep] = s;
        keep += 1;
    }
    h.spans.shrinkRetainingCapacity(keep);
    // A collection that frees under half of the heap shows a heap that
    // grows with live data. The next one then waits for four times the
    // live bytes, so the mark cost of a growing structure stays low.
    const grew = live_bytes * 2 > before;
    h.live_bytes = live_bytes;
    h.stats.allocated += used_before -| h.alloc_base;
    h.stats.freed += used_before -| live_bytes;
    h.alloc_base = live_bytes;
    h.threshold = @max(min_threshold, (if (grew) @as(usize, 4) else 2) *| live_bytes);
    // The free pages above what the heap fills before its next collection
    // go back to the system.
    if (h.pool) |*p| _ = p.trim(h.keepFree());
    if (h.wpool) |*p| _ = p.trim(h.keepFree());
    // The bounds may be wider than the spans. That is safe.
}

test "each size class serves its block size" {
    var h = Heap.init(std.testing.allocator);
    defer h.deinit();
    const a = h.allocator();
    for (class_size, 0..) |size, c| {
        try std.testing.expectEqual(c, classOf(size));
        try std.testing.expectEqual(c, classOf(size - 15 + 0 * c));
        const p = try a.alloc(u64, size / 8);
        @memset(p, 7);
        const s = h.find(@intFromPtr(p.ptr)).?;
        try std.testing.expectEqual(size, s.size);
        try std.testing.expect(!s.noscan);
    }
    // A block of bytes goes to a page that a scan skips.
    const bytes = try a.alloc(u8, 100);
    try std.testing.expect(h.find(@intFromPtr(bytes.ptr)).?.noscan);
}

test "blocks do not overlap and keep their data" {
    var h = Heap.init(std.testing.allocator);
    defer h.deinit();
    const a = h.allocator();
    var ptrs: [2000][]u64 = undefined;
    for (&ptrs, 0..) |*p, i| {
        p.* = try a.alloc(u64, 1 + i % 40);
        @memset(p.*, i);
    }
    for (ptrs, 0..) |p, i| for (p) |w| try std.testing.expectEqual(i, w);
}

test "large blocks and the address lookup" {
    var h = Heap.init(std.testing.allocator);
    defer h.deinit();
    const a = h.allocator();
    const big = try a.alloc(u64, 5000);
    const s = h.find(@intFromPtr(big.ptr) + 20000).?;
    try std.testing.expect(s.large);
    try std.testing.expectEqual(@intFromPtr(big.ptr), s.base);
    // A request with a large alignment is a large block.
    const al = try a.alignedAlloc(u8, .@"64", 100);
    try std.testing.expect(h.find(@intFromPtr(al.ptr)).?.large);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(al.ptr), 64));
    // An address inside a page gives the page.
    const small = try a.alloc(u64, 3);
    try std.testing.expect(h.find(@intFromPtr(small.ptr) + 8) != null);
    // Addresses outside the heap give null.
    var local: u64 = 0;
    try std.testing.expect(h.find(@intFromPtr(&local)) == null);
    try std.testing.expect(h.find(0) == null);
    try std.testing.expect(h.find(std.math.maxInt(usize)) == null);
}

test "resize stays inside the block and remap never moves" {
    var h = Heap.init(std.testing.allocator);
    defer h.deinit();
    const a = h.allocator();
    var buf = try a.alloc(u64, 5);
    // The class of 40 bytes has 48 bytes.
    try std.testing.expect(a.resize(buf, 6));
    buf = buf.ptr[0..6];
    try std.testing.expect(!a.resize(buf, 7));
    const grown = try a.realloc(buf, 100);
    try std.testing.expect(grown.ptr != buf.ptr);
}

fn failMark(_: *anyopaque, h: *Heap) bool {
    // Marks one block, then reports a mark that did not finish.
    const first = h.spans.items[0];
    first.mark[0] |= 1;
    return false;
}

test "a failed mark frees no block and leaves no mark bit" {
    var h = Heap.init(std.testing.allocator);
    defer h.deinit();
    const a = h.allocator();
    const p = try a.alloc(u64, 4);
    @memset(p, 0x1234);
    const bytes = h.bytes;
    var ctx: u8 = 0;
    h.roots_ctx = &ctx;
    h.roots_fn = failMark;
    collect(&h);
    try std.testing.expect(!h.mark_ok);
    try std.testing.expectEqual(@as(u64, 0), h.collections);
    try std.testing.expectEqual(bytes, h.bytes);
    for (h.spans.items) |s| for (s.mark) |w| try std.testing.expectEqual(@as(u64, 0), w);
    for (p) |w| try std.testing.expectEqual(@as(u64, 0x1234), w);
}

test "reset frees all pages" {
    var h = Heap.init(std.testing.allocator);
    defer h.deinit();
    const a = h.allocator();
    for (0..1000) |_| _ = try a.alloc(u8, 70);
    _ = try a.alloc(u8, 100_000);
    try std.testing.expect(h.bytes > 100_000);
    h.reset();
    try std.testing.expectEqual(@as(usize, 0), h.bytes);
    _ = try a.alloc(u64, 4);
}

fn noRoots(_: *anyopaque, _: *Heap) bool {
    return true;
}

const TestCharge = struct {
    used: usize = 0,
    limit: usize = std.math.maxInt(usize),
    fn func(ctx: *anyopaque, len: usize, add: bool) bool {
        const c: *TestCharge = @ptrCast(@alignCast(ctx));
        if (add) {
            if (c.used + len > c.limit) return false;
            c.used += len;
        } else c.used -= len;
        return true;
    }
};

test "the page pool charges each span, and a sweep gives the free pages back" {
    if (!pagepool.supported) return error.SkipZigTest;
    var h = Heap.init(std.testing.allocator);
    defer h.deinit();
    var charge: TestCharge = .{};
    h.usePool(.{ .ctx = &charge, .func = TestCharge.func });
    const a = h.allocator();
    // 64 MiB of blocks of 1,000 bytes, and one large block.
    for (0..64 * 1024) |_| {
        const p = try a.alloc(u8, 1000);
        @memset(p, 0x5a);
    }
    _ = try a.alloc(u8, 3 << 20);
    try std.testing.expectEqual(h.bytes, charge.used);
    // No root: the sweep frees each span, and the pool keeps at most the
    // pages of the next threshold.
    var ctx: u8 = 0;
    h.roots_ctx = &ctx;
    h.roots_fn = noRoots;
    collect(&h);
    try std.testing.expectEqual(@as(usize, 0), h.bytes);
    try std.testing.expectEqual(@as(usize, 0), charge.used);
    const pool = &h.pool.?;
    try std.testing.expect(pool.returned >= 32 << 20);
    try std.testing.expect(pool.free_committed <= h.keepFree());
    // The pages come again and hold data.
    for (0..1024) |_| {
        const p = try a.alloc(u8, 1000);
        @memset(p, 0x77);
        try std.testing.expectEqual(@as(u8, 0x77), p[999]);
    }
    try std.testing.expectEqual(h.bytes, charge.used);
    // A charge that fails is an allocation that fails.
    charge.limit = charge.used;
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 5 << 20));
}

var test_root: usize = 0;

fn testRoots(_: *anyopaque, h: *Heap) bool {
    markRange(h, @intFromPtr(&test_root), @sizeOf(usize));
    return true;
}

test "a minor collection keeps a new block that an old block points to" {
    if (!pagepool.dirty_supported) return error.SkipZigTest;
    var h = Heap.init(std.testing.allocator);
    defer h.deinit();
    var charge: TestCharge = .{};
    h.usePool(.{ .ctx = &charge, .func = TestCharge.func });
    try std.testing.expect(h.gen);
    const al = h.allocator();
    var ctx: u8 = 0;
    h.roots_ctx = &ctx;
    h.roots_fn = testRoots;
    // An old block A, from the root.
    const a = try al.alloc(usize, 4);
    @memset(a, 0);
    test_root = @intFromPtr(a.ptr);
    collect(&h);
    try std.testing.expectEqual(@as(u64, 1), h.stats.majors);
    // A new block B, reached only from a store into A: the page of A is
    // written, so the minor collection scans A.
    const b = try al.alloc(usize, 4);
    @memset(b, 7);
    a[0] = @intFromPtr(b.ptr);
    collect(&h);
    try std.testing.expectEqual(@as(u64, 1), h.stats.majors);
    try std.testing.expectEqual(@as(u32, 1), h.minors);
    try std.testing.expect(!isFree(&h, @intFromPtr(b.ptr)));
    try std.testing.expectEqual(@as(usize, 7), b[3]);
    // A new block C that nothing reaches goes in a minor collection.
    const c = try al.alloc(usize, 4);
    @memset(c, 9);
    const c_addr = @intFromPtr(c.ptr);
    collect(&h);
    try std.testing.expect(isFree(&h, c_addr));
    // B is old now: after its pointer goes, it stays until a major
    // collection.
    a[0] = 0;
    collect(&h);
    try std.testing.expect(!isFree(&h, @intFromPtr(b.ptr)));
    collectMajor(&h);
    try std.testing.expect(isFree(&h, @intFromPtr(b.ptr)));
    try std.testing.expect(!isFree(&h, @intFromPtr(a.ptr)));
    test_root = 0;
}

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
/// The places of `Heap.spare_large`, and the most bytes of the blocks
/// that they keep.
const spare_large_max = 128;
const spare_large_bytes = 32 << 20;

const SpareLarge = struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,
    alignment: Alignment = .@"16",
};

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
    /// The threads of the pool of the process that help a mark of a large
    /// heap (`par`), with no thread of the interpreter. 0: the mark runs on
    /// the thread of the interpreter alone.
    mark_threads: u32 = 3,
    /// The live bytes of the last collection that a parallel mark needs: a
    /// small heap marks in less time than the threads need to wake.
    par_min_live: usize = 16 << 20,
    /// The marks that ran on more than one thread, for the tests.
    par_marks: u32 = 0,
    /// False when the work list could not grow: the sweep must not run.
    mark_ok: bool = true,
    live_bytes: usize = 0,
    collections: u64 = 0,
    /// The counts of the collections, for `ztcl::gc stats`.
    stats: Stats = .{},
    /// The pages of the spans, from the system (`pagepool.zig`), when the
    /// embedder gave `charge` (`usePool`). Null: the backing allocator.
    pool: ?pagepool.Pool = null,
    charge: ?Charge = null,
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
    /// Large blocks with no address in them (`noscan`) that a sweep
    /// freed, for the next large block of the same size and alignment.
    /// A loop that makes a large string in each pass then reuses the
    /// pages, with no new mapping and no page fault. The heap counts no
    /// byte of a kept block (`bytes`), so the memory count of a script
    /// does not change.
    spare_large: [spare_large_max]SpareLarge = @splat(.{}),
    stress_left: u32 = 0,
    /// The character counts of the last long strings in heap blocks.
    /// The bytes of a block do not change while the block is live, so
    /// an entry stays true until a sweep or a reset frees blocks.
    counts: [4]Count = @splat(.{}),
    next_count: u8 = 0,
    /// The bytes of the last long strings that `binary` read or made: the
    /// byte form beside the string (src/more.zig `toBytes`). An entry
    /// stays true until a sweep or a reset, as for `counts`, and a sweep
    /// drops the entries before it frees a block.
    bytes_of: [4]BytesOf = @splat(.{}),
    next_bytes: u8 = 0,
    /// The grapheme marks of the last long strings (src/text/cmd.zig).
    /// The marks are in a heap block, so the same rule holds.
    graphemes: [2]Graphemes = @splat(.{}),
    next_grapheme: u8 = 0,

    pub const Count = struct { ptr: usize = 0, len: usize = 0, n: usize = 0 };
    pub const BytesOf = struct { ptr: usize = 0, len: usize = 0, bytes: []const u8 = &.{} };
    pub const Graphemes = struct { ptr: usize = 0, len: usize = 0, n: usize = 0, marks: []const u32 = &.{} };

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
        h.charge = c;
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
        h.dropSpareLarge();
        for (h.spans.items) |s| h.freeSpan(s);
        if (h.pool) |*p| _ = p.trim(4 << 20);
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
        h.counts = @splat(.{});
        h.bytes_of = @splat(.{});
        h.graphemes = @splat(.{});
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

    /// The stored byte form of `s`, or null.
    pub inline fn cachedBytes(h: *const Heap, s: []const u8) ?[]const u8 {
        for (&h.bytes_of) |*e| {
            if (e.ptr == @intFromPtr(s.ptr) and e.len == s.len) return e.bytes;
        }
        return null;
    }

    /// Stores `b` as the byte form of `s`, a string in a block of this
    /// heap. `b` must not change while `s` lives.
    pub fn putBytes(h: *Heap, s: []const u8, b: []const u8) void {
        if (h.find(@intFromPtr(s.ptr)) == null) return;
        h.bytes_of[h.next_bytes] = .{ .ptr = @intFromPtr(s.ptr), .len = s.len, .bytes = b };
        h.next_bytes = @intCast((h.next_bytes + 1) % h.bytes_of.len);
    }

    /// The stored grapheme marks of `s`, or null.
    pub fn cachedGraphemes(h: *const Heap, s: []const u8) ?Graphemes {
        for (h.graphemes) |g| {
            if (g.ptr == @intFromPtr(s.ptr) and g.len == s.len) return g;
        }
        return null;
    }

    /// Stores the grapheme marks of `s`, a string in a heap block.
    pub fn putGraphemes(h: *Heap, s: []const u8, n: usize, marks: []const u32) void {
        h.graphemes[h.next_grapheme] = .{ .ptr = @intFromPtr(s.ptr), .len = s.len, .n = n, .marks = marks };
        h.next_grapheme ^= 1;
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
        h.spanFree(@ptrFromInt(s.base), s.len, s.alignment, s.pooled);
        h.freeMeta(s);
    }

    const SpanMem = struct { mem: [*]u8, pooled: bool };

    /// The memory of a span of `len` bytes: from the page pool when the
    /// heap has one and the alignment is at most a page, else from the
    /// backing allocator. The pool rounds the run up to whole pages, and
    /// the span and the counter keep `len`, so the threshold and the memory
    /// limit see the same bytes as with the allocator of the embedder.
    fn spanMem(h: *Heap, len: usize, a: Alignment) ?SpanMem {
        if (h.pool) |*pool| if (a.toByteUnits() <= pagepool.page) {
            const c = h.charge.?;
            if (!c.func(c.ctx, len, true)) return null;
            const mem = pool.alloc(std.mem.alignForward(usize, len, pagepool.page)) orelse {
                _ = c.func(c.ctx, len, false);
                return null;
            };
            return .{ .mem = mem, .pooled = true };
        };
        const mem = h.backing.rawAlloc(len, a, 0) orelse return null;
        return .{ .mem = mem, .pooled = false };
    }

    fn spanFree(h: *Heap, mem: [*]u8, len: usize, a: Alignment, pooled: bool) void {
        if (pooled) {
            h.pool.?.free(mem, std.mem.alignForward(usize, len, pagepool.page));
            const c = h.charge.?;
            _ = c.func(c.ctx, len, false);
            return;
        }
        h.backing.rawFree(mem[0..len], a, 0);
    }

    /// A kept large block of `size` bytes and alignment `a`, or null.
    fn takeSpareLarge(h: *Heap, size: usize, a: Alignment, noscan: bool) ?[*]u8 {
        if (!noscan) return null;
        for (&h.spare_large) |*e| {
            if (e.len == size and e.alignment == a) if (e.ptr) |p| {
                e.ptr = null;
                return p;
            };
        }
        return null;
    }

    /// Frees a dead large span. A `noscan` block goes to `spare_large`
    /// when a place is free (an empty place, or the place of a smaller
    /// block) and the kept blocks stay within `spare_large_bytes`. Each
    /// block that leaves the list goes back to the backing allocator. A
    /// span of the page pool goes back to the pool, which keeps its pages.
    fn freeLarge(h: *Heap, s: *Span, poison: bool) void {
        if (poison or s.pooled or !s.noscan or s.len > spare_large_bytes) return h.freeSpan(s);
        var at: ?*SpareLarge = null;
        for (&h.spare_large) |*e| {
            if (e.ptr == null) {
                at = e;
                break;
            }
            if (e.len < s.len and (at == null or e.len < at.?.len)) at = e;
        }
        const e = at orelse return h.freeSpan(s);
        var total: usize = s.len;
        for (&h.spare_large) |*o| if (o != e and o.ptr != null) {
            total += o.len;
        };
        if (total > spare_large_bytes) return h.freeSpan(s);
        if (e.ptr) |p| h.backing.rawFree(p[0..e.len], e.alignment, 0);
        e.* = .{ .ptr = @ptrFromInt(s.base), .len = s.len, .alignment = s.alignment };
        h.freeMeta(s);
    }

    fn dropSpareLarge(h: *Heap) void {
        for (&h.spare_large) |*e| {
            if (e.ptr) |p| h.backing.rawFree(p[0..e.len], e.alignment, 0);
            e.* = .{};
        }
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
        const got = h.spanMem(page, span_align) orelse return null;
        const mem = got.mem;
        const s = h.makeSpan((count + 63) / 64, .{
            .base = @intFromPtr(mem),
            .len = page,
            .pooled = got.pooled,
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
            h.spanFree(mem, page, span_align, got.pooled);
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
        const noscan = alignment.toByteUnits() < @sizeOf(usize);
        const got: SpanMem = if (h.takeSpareLarge(size, a, noscan)) |p|
            .{ .mem = p, .pooled = false }
        else
            h.spanMem(size, a) orelse return null;
        const mem = got.mem;
        const s = h.makeSpan(1, .{
            .base = @intFromPtr(mem),
            .len = size,
            .pooled = got.pooled,
            .size = @intCast(@min(size, std.math.maxInt(u32))),
            .count = 1,
            .nwords = 0,
            .class = 0,
            .noscan = noscan,
            .large = true,
            .alignment = a,
            .free = &.{},
            .mark = &.{},
        }) orelse {
            h.spanFree(mem, size, a, got.pooled);
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

/// The state of one thread of a mark: the span of its last hit, its work
/// list, and the allocator of the list. The mark on the thread of the
/// interpreter uses the fields of the heap (`marker`). A thread of a
/// parallel mark (`par`) has its own, and `shared` for the work that the
/// other threads can steal.
const Marker = struct {
    h: *Heap,
    last: ?*Span,
    work: *std.ArrayList(Heap.Range),
    gpa: Allocator,
    ok: bool = true,
    shared: ?*par.Shared = null,
};

fn marker(h: *Heap) Marker {
    return .{ .h = h, .last = h.last, .work = &h.work, .gpa = h.backing };
}

fn sync(h: *Heap, m: Marker) void {
    h.last = m.last;
    if (!m.ok) h.mark_ok = false;
}

/// Marks the block that holds the word `w`, when the word is an address
/// of a live block. The block goes on the work list, unless it holds no
/// pointer.
pub fn markWord(h: *Heap, w: usize) void {
    if (w < h.lo or w >= h.hi) return;
    var m = marker(h);
    markHit(false, &m, w);
    sync(h, m);
}

/// `markWord` for a word inside the bounds of the heap.
inline fn markHit(comptime parallel: bool, m: *Marker, w: usize) void {
    // Pointers cluster, so the span of the last hit often serves.
    const s = if (m.last) |l| (if (w -% l.base < l.len) l else m.h.lookup(w)) else m.h.lookup(w);
    const sp = s orelse return;
    m.last = sp;
    markIn(parallel, m, sp, w);
}

/// Sets the mark bit of the block of `w` in `s`, and puts the block on
/// the work list when it holds pointers. In a parallel mark the bit goes
/// in with an atomic OR, so of two threads that reach one block, only the
/// one that set the bit scans it.
inline fn markIn(comptime parallel: bool, m: *Marker, s: *Span, w: usize) void {
    var idx: usize = 0;
    if (!s.large) {
        idx = (w - s.base) / s.size;
        if (idx >= s.count) return;
    }
    const word = idx >> 6;
    const bit = @as(u64, 1) << @intCast(idx & 63);
    if (s.free[word] & bit != 0) return;
    if (parallel) {
        // Most hits find the bit set. A plain load first keeps those off
        // the atomic OR, which pulls the cache line away from the other threads:
        // with the OR alone, the mark of the live benchmark took 4 times as
        // long on 4 threads as on one.
        if (@atomicLoad(u64, &s.mark[word], .monotonic) & bit != 0) return;
        if (@atomicRmw(u64, &s.mark[word], .Or, bit, .monotonic) & bit != 0) return;
    } else {
        if (s.mark[word] & bit != 0) return;
        s.mark[word] |= bit;
    }
    if (s.noscan) return;
    const start = if (s.large) s.base else s.base + idx * s.size;
    const is_stack = s.large and s.len == coro_stack_bytes;
    push(parallel, m, .{ .ptr = start, .len = if (s.large) s.len else s.size, .stack = is_stack });
}

/// Puts a range on the work list of `m`. In a parallel mark a large range
/// goes as pieces of `par.chunk` bytes, so other threads can scan parts of
/// one large list, and a long list gives half of its ranges to the others.
fn push(comptime parallel: bool, m: *Marker, r: Heap.Range) void {
    if (parallel and r.len > par.chunk) {
        var at: usize = 0;
        while (at < r.len) : (at += par.chunk) {
            m.work.append(m.gpa, .{ .ptr = r.ptr + at, .len = @min(par.chunk, r.len - at), .stack = r.stack }) catch {
                m.ok = false;
                return;
            };
        }
    } else {
        m.work.append(m.gpa, r) catch {
            m.ok = false;
            return;
        };
    }
    if (parallel and m.work.items.len >= par.share_at) m.shared.?.share(m);
}

fn scanRange(comptime parallel: bool, m: *Marker, r: Heap.Range) void {
    if (r.stack) scanStack(parallel, m, r.ptr, r.len) else scan(parallel, m, r.ptr, r.len);
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
    var m = marker(h);
    scanStack(false, &m, ptr, len);
    sync(h, m);
    drain(h);
}

fn scanStack(comptime parallel: bool, m: *Marker, ptr: usize, len: usize) void {
    const first = std.mem.alignForward(usize, ptr, @sizeOf(usize));
    const end = ptr +| len;
    if (end < first + @sizeOf(usize)) return;
    const lo = m.h.lo;
    const span = m.h.hi -% lo;
    var p = first;
    while (p + @sizeOf(usize) <= end) : (p += @sizeOf(usize)) {
        const w = @as(*const usize, @ptrFromInt(p)).*;
        inline for (.{ w, w -% 1, w +% stack_margin }) |x| {
            if (x -% lo < span) markHit(parallel, m, x);
        }
    }
}

/// Reads each aligned word of the range as a possible pointer and marks
/// what the words reach.
pub fn markRange(h: *Heap, ptr: usize, len: usize) void {
    var m = marker(h);
    scan(false, &m, ptr, len);
    sync(h, m);
    drain(h);
}

fn scan(comptime parallel: bool, m: *Marker, ptr: usize, len: usize) void {
    const first = std.mem.alignForward(usize, ptr, @sizeOf(usize));
    const end = ptr +| len;
    if (end < first + @sizeOf(usize)) return;
    // Most words are not addresses of the heap, so the bound check is
    // inline and the lookup is a call.
    const lo = m.h.lo;
    const span = m.h.hi -% lo;
    var p = first;
    while (p + @sizeOf(usize) <= end) : (p += @sizeOf(usize)) {
        const w = @as(*const usize, @ptrFromInt(p)).*;
        if (w -% lo < span) markHit(parallel, m, w);
    }
}

/// Scans each range of the work list. When a range is large or the list
/// is long, the rest of the work goes to the threads of `par`, if the
/// pool is free.
fn drain(h: *Heap) void {
    var m = marker(h);
    // The stress mode runs each mark on the threads, so its tests cover
    // the parallel mark.
    const stress = h.stress != 0;
    // A target with no threads (`par.enabled`) compiles no part of the
    // parallel mark.
    var try_par = (comptime par.enabled) and h.mark_threads > 0 and (stress or h.live_bytes >= h.par_min_live) and par.ready.load(.acquire);
    if (comptime !par.enabled) _ = &try_par;
    while (m.work.pop()) |r| {
        if (comptime par.enabled) {
            if (try_par and (stress or r.len >= par.min_range or m.work.items.len >= par.min_items)) {
                m.work.appendAssumeCapacity(r);
                sync(h, m);
                if (par.drain(h)) {
                    h.par_marks += 1;
                    m = marker(h);
                    continue;
                }
                // The pool serves another heap: this mark goes on alone.
                try_par = false;
                m = marker(h);
                continue;
            }
        }
        scanRange(false, &m, r);
    }
    sync(h, m);
}

/// The parallel mark: a pool of threads of the process that scan the work
/// of one heap with the thread of its interpreter. Each thread has its
/// own work list. A thread with `share_at` ranges or more gives half of
/// them to the shared queue, and a thread with none steals from it.
///
/// One word (`Shared.state`) holds the count of threads in the mark, the
/// count of those that wait, a bit for the end, and the number of the
/// mark. The mark ends when each thread in it waits: a thread waits only
/// when its list is empty and the queue was empty, and only a thread that
/// does not wait can give ranges to the queue, so no range is left. A
/// worker that wakes after the end does not join, so the thread of the
/// interpreter does not wait for a worker that is slow to wake. A thread
/// of an older mark finds another number in the word, and leaves.
///
/// A mark bit goes in with an atomic OR (`markIn`), so each block is
/// scanned once. The set of marked blocks is the set that the roots reach,
/// in any order of the scans, so a parallel mark keeps the blocks that a
/// mark on one thread keeps.
const par = struct {
    pub const enabled = !builtin.single_threaded and !builtin.cpu.arch.isWasm();
    /// The most threads of the pool, with no thread of an interpreter.
    const max_workers = 7;
    /// A range of this many bytes, or a list of this many ranges, starts a
    /// parallel mark, once the threads run (`ready`).
    pub const min_range: usize = 256 * 1024;
    pub const min_items: usize = 64;
    /// The bytes of the pieces of a large range.
    pub const chunk: usize = 64 * 1024;
    /// The length of a work list that gives half of it.
    pub const share_at: usize = 64;

    const ga = std.heap.smp_allocator;

    // The fields of `Shared.state`.
    const one_idle: u64 = 1;
    const one_joined: u64 = 1 << 16;
    const done_bit: u64 = 1 << 32;
    const gen_shift = 33;

    fn idleOf(s: u64) u64 {
        return s & 0xffff;
    }
    fn joinedOf(s: u64) u64 {
        return s >> 16 & 0xffff;
    }
    fn genOf(s: u64) u64 {
        return s >> gen_shift;
    }

    pub const Shared = struct {
        h: *Heap = undefined,
        /// The threads that can join the mark, with the thread of the
        /// interpreter.
        n: u32 = 1,
        lock: std.atomic.Mutex = .unlocked,
        queue: std.ArrayList(Heap.Range) = .empty,
        /// The count of ranges of `queue`, read with no lock.
        queued: std.atomic.Value(usize) = .init(0),
        ok: std.atomic.Value(bool) = .init(true),
        state: std.atomic.Value(u64) = .init(0),

        fn grab(sh: *Shared) void {
            while (!sh.lock.tryLock()) std.atomic.spinLoopHint();
        }

        /// Moves the older half of the ranges of `m` to the queue, when the
        /// queue is short.
        pub fn share(sh: *Shared, m: *Marker) void {
            if (sh.queued.load(.monotonic) >= share_at * sh.n) return;
            const half = m.work.items.len / 2;
            sh.grab();
            defer sh.lock.unlock();
            sh.queue.appendSlice(ga, m.work.items[0..half]) catch return;
            sh.queued.store(sh.queue.items.len, .release);
            const rest = m.work.items.len - half;
            std.mem.copyForwards(Heap.Range, m.work.items[0..rest], m.work.items[half..]);
            m.work.items.len = rest;
        }

        /// Moves a share of the ranges of the queue to `m`, at most
        /// `share_at / 2`. False with none.
        fn steal(sh: *Shared, m: *Marker) bool {
            if (sh.queued.load(.acquire) == 0) return false;
            sh.grab();
            defer sh.lock.unlock();
            // A share for each thread, so one thread does not get all the work
            // of a mark that starts with few ranges.
            const len = sh.queue.items.len;
            if (len == 0) return false;
            const n = std.math.clamp(len / sh.n, 1, share_at / 2);
            const from = sh.queue.items.len - n;
            m.work.appendSlice(m.gpa, sh.queue.items[from..]) catch {
                // The mark fails, and the sweep frees no block: the queue
                // goes, so no thread waits on ranges that none can steal.
                m.ok = false;
                sh.ok.store(false, .release);
                sh.queue.items.len = 0;
                sh.queued.store(0, .release);
                return false;
            };
            sh.queue.items.len = from;
            sh.queued.store(from, .release);
            return true;
        }

        /// Adds this thread to mark `gen`. False when that mark is over.
        fn join(sh: *Shared, gen: u64) bool {
            var s = sh.state.load(.acquire);
            while (true) {
                if (genOf(s) != gen or s & done_bit != 0) return false;
                s = sh.state.cmpxchgWeak(s, s + one_joined, .acq_rel, .acquire) orelse return true;
            }
        }
    };

    /// One heap at a time uses the pool, so one `Shared` serves.
    var shared: Shared = .{};
    var busy: std.atomic.Value(bool) = .init(false);
    var start_lock: std.atomic.Mutex = .unlocked;
    var started = false;
    var nworkers: u32 = 0;
    /// True once `start` has made its threads.
    pub var ready: std.atomic.Value(bool) = .init(false);
    /// A new value wakes the workers for a mark.
    var epoch: std.atomic.Value(u32) = .init(0);

    fn io() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    fn start(count: u32) void {
        while (!start_lock.tryLock()) std.Thread.yield() catch {};
        defer start_lock.unlock();
        if (started) return;
        started = true;
        const cpus: u32 = @intCast(std.Thread.getCpuCount() catch 1);
        const n = @min(count, @min(max_workers, cpus -| 1));
        for (0..n) |_| {
            // The worker gets the epoch of now: a mark that comes after the
            // spawn has a later one, so the worker does not miss it.
            const t = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, workerMain, .{epoch.load(.acquire)}) catch break;
            t.detach();
            nworkers += 1;
        }
        ready.store(nworkers > 0, .release);
    }

    fn workerMain(first: u32) void {
        var seen = first;
        while (true) {
            const now = epoch.load(.acquire);
            if (now == seen) {
                io().futexWaitTimeout(u32, &epoch.raw, seen, .{ .duration = .{ .raw = .fromNanoseconds(std.time.ns_per_s), .clock = .awake } }) catch {};
                continue;
            }
            seen = now;
            const sh = &shared;
            const gen = genOf(sh.state.load(.acquire));
            if (sh.join(gen)) run(sh, gen);
        }
    }

    /// Scans the work of `h` on the threads of the pool and this thread.
    /// False when the pool has no thread or serves another heap.
    fn drain(h: *Heap) bool {
        if (nworkers == 0) return false;
        if (busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return false;
        defer busy.store(false, .release);
        const sh = &shared;
        {
            sh.grab();
            defer sh.lock.unlock();
            sh.queue.clearRetainingCapacity();
            // The mark on one thread puts a large block on its list whole:
            // it goes to the queue in pieces, for each thread to steal some.
            for (h.work.items) |r| {
                var at: usize = 0;
                while (at < r.len) : (at += chunk) {
                    sh.queue.append(ga, .{ .ptr = r.ptr + at, .len = @min(chunk, r.len - at), .stack = r.stack }) catch return false;
                }
            }
            sh.queued.store(sh.queue.items.len, .release);
        }
        h.work.clearRetainingCapacity();
        sh.h = h;
        sh.n = nworkers + 1;
        sh.ok.store(true, .monotonic);
        // This thread is the first in the mark.
        const gen = genOf(sh.state.load(.monotonic)) + 1;
        sh.state.store(gen << gen_shift | one_joined, .release);
        _ = epoch.fetchAdd(1, .release);
        io().futexWake(u32, &epoch.raw, std.math.maxInt(u32));
        run(sh, gen);
        if (!sh.ok.load(.acquire)) h.mark_ok = false;
        return true;
    }

    /// One thread of mark `gen`: its own ranges, then ranges of the queue,
    /// until each thread in the mark waits.
    fn run(sh: *Shared, gen: u64) void {
        var list: std.ArrayList(Heap.Range) = .empty;
        defer list.deinit(ga);
        var m: Marker = .{ .h = sh.h, .last = null, .work = &list, .gpa = ga, .shared = sh };
        outer: while (true) {
            while (list.pop()) |r| scanRange(true, &m, r);
            if (sh.steal(&m)) continue;
            if (!m.ok) sh.ok.store(false, .release);
            // A thread that does not wait is in the mark of now, so this
            // add needs no check of the number.
            _ = sh.state.fetchAdd(one_idle, .acq_rel);
            var s = sh.state.load(.acquire);
            var spins: u32 = 0;
            while (true) {
                if (genOf(s) != gen or s & done_bit != 0) return;
                if (sh.queued.load(.acquire) > 0) {
                    s = sh.state.cmpxchgWeak(s, s - one_idle, .acq_rel, .acquire) orelse continue :outer;
                    continue;
                }
                if (idleOf(s) == joinedOf(s)) {
                    s = sh.state.cmpxchgWeak(s, s | done_bit, .acq_rel, .acquire) orelse return;
                    continue;
                }
                // A short spin, then a yield: a waiting thread does not keep a
                // processor from a thread with work on a busy host.
                spins += 1;
                if (spins < 64) std.atomic.spinLoopHint() else std.Thread.yield() catch {};
                s = sh.state.load(.acquire);
            }
        }
    }
};

/// Runs a collection. The roots come from `roots_fn`. The sweep frees
/// each block that no root reached. A failed mark frees no block.
pub fn collect(h: *Heap) void {
    collectOnce(h);
    // The threads of the parallel mark start after the first collection
    // that finds a large heap, so no pause pays for them.
    if (comptime par.enabled) if (h.mark_threads > 0 and (h.stress != 0 or h.live_bytes >= h.par_min_live)) par.start(h.mark_threads);
}

fn collectOnce(h: *Heap) void {
    const roots = h.roots_fn orelse return;
    const t0 = clock();
    defer {
        const t2 = clock();
        h.stats.gc_ns += t2 -| t0;
        h.stats.pause(t2 -| t0);
    }
    h.mark_ok = true;
    h.work.clearRetainingCapacity();
    h.buildTable();
    defer h.table_on = false;
    if (!roots(h.roots_ctx, h)) {
        // A mark that stopped early leaves mark bits.
        h.mark_ok = false;
        h.work.clearRetainingCapacity();
        for (h.spans.items) |s| @memset(s.mark, 0);
        return;
    }
    drain(h);
    h.work.clearRetainingCapacity();
    if (h.mark_ok) h.collections += 1;
    const t1 = clock();
    h.stats.mark_ns += t1 -| t0;
    sweep(h);
    h.stats.sweep_ns += clock() -| t1;
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
    h.bytes_of = @splat(.{});
    h.graphemes = @splat(.{});
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
                h.freeLarge(s, poison);
                continue;
            }
            s.mark[0] = 0;
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
            if (poison) {
                var dead = new_free & ~s.free[w];
                while (dead != 0) : (dead &= dead - 1) {
                    const i = w * 64 + @ctz(dead);
                    @memset(@as([*]u8, @ptrFromInt(s.base + i * s.size))[0..s.size], dead_byte);
                }
            }
            s.free[w] = new_free;
            s.mark[w] = 0;
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
        if (any_free) {
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

/// A heap with a large array of pointers to small blocks, each of which
/// points to a second block, and as many blocks of garbage. Gives the
/// array.
fn buildGraph(a: Allocator, n: usize) ![]usize {
    const arr = try a.alloc(usize, n);
    for (arr, 0..) |*slot, i| {
        const b = try a.alloc(usize, 4);
        const c = try a.alloc(usize, 2);
        c[0] = i;
        c[1] = 0;
        b[0] = @intFromPtr(c.ptr);
        b[1] = i;
        b[2] = 0;
        b[3] = 0;
        slot.* = @intFromPtr(b.ptr);
        const junk = try a.alloc(usize, 4);
        @memset(junk, 0);
    }
    return arr;
}

test "a parallel mark keeps what a mark on one thread keeps" {
    const n = 64 * 1024;
    var results: [2]usize = undefined;
    for ([_]u32{ 0, 3 }, 0..) |threads, k| {
        var h = Heap.init(std.testing.allocator);
        defer h.deinit();
        h.mark_threads = threads;
        h.par_min_live = 0;
        const a = h.allocator();
        const arr = try buildGraph(a, n);
        test_root = @intFromPtr(arr.ptr);
        var ctx: u8 = 0;
        h.roots_ctx = &ctx;
        h.roots_fn = testRoots;
        // The first collection starts the threads, and the second uses them.
        collect(&h);
        collect(&h);
        try std.testing.expect(h.mark_ok);
        try std.testing.expectEqual(threads > 0, h.par_marks > 0);
        // Each block of the graph is live, with its data, and the garbage
        // is gone: the array, 2 blocks for each slot.
        for (arr, 0..) |p, i| {
            const b: [*]const usize = @ptrFromInt(p);
            try std.testing.expect(!isFree(&h, p));
            try std.testing.expectEqual(i, b[1]);
            const c: [*]const usize = @ptrFromInt(b[0]);
            try std.testing.expect(!isFree(&h, b[0]));
            try std.testing.expectEqual(i, c[0]);
        }
        results[k] = h.live_bytes;
        test_root = 0;
    }
    try std.testing.expectEqual(results[0], results[1]);
}

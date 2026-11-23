//! The heap of an interpreter: pages of blocks in size classes.
//!
//! A page has 16 KiB or more and holds blocks of one size class. A request
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
//! All memory comes from the backing allocator, so the counting
//! allocator of the interpreter sees each byte. The heap is not thread
//! safe.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// The bytes of a page: 16 KiB, and at least eight blocks.
fn pageBytes(size: usize) usize {
    return @max(16 * 1024, std.mem.alignForward(usize, size * 8, 4096));
}
/// The largest block of a size class.
pub const max_small: usize = 8192;
const max_small_align = 16;
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
const fill_dead = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

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
    /// The bytes that the counting allocator holds.
    used: *const usize,
    /// The memory limit of the root interpreter. A collection starts
    /// when an allocation brings the heap above it.
    limit: *const usize,
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
    /// Above zero, each allocation of this count starts a collection
    /// first. The count grows by its own value for each 16 MiB of heap.
    stress: u32 = 0,
    /// The span of the last address that the mark found.
    last: ?*Span = null,
    stress_left: u32 = 0,

    pub const Range = struct { ptr: usize, len: usize };

    pub fn init(backing: Allocator, used: *const usize, limit: *const usize) Heap {
        return .{ .backing = backing, .used = used, .limit = limit };
    }

    /// Frees all memory of the heap.
    pub fn deinit(h: *Heap) void {
        h.reset();
        h.spans.deinit(h.backing);
        h.work.deinit(h.backing);
        h.spans = .empty;
        h.work = .empty;
    }

    /// Frees each span and keeps the heap usable.
    pub fn reset(h: *Heap) void {
        for (h.spans.items) |s| h.freeSpan(s);
        h.spans.clearRetainingCapacity();
        h.cur = @splat(null);
        h.partial = @splat(null);
        h.last = null;
        h.lo = std.math.maxInt(usize);
        h.hi = 0;
        h.bytes = 0;
        h.live_bytes = 0;
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
        const base: [*]u8 = @ptrFromInt(s.base);
        h.backing.rawFree(base[0..s.len], s.alignment, 0);
        h.freeMeta(s);
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
    }

    fn newPage(h: *Heap, index: usize) ?*Span {
        const class = index % class_count;
        const size = class_size[class];
        const page = pageBytes(size);
        const count: usize = page / size;
        const mem = h.backing.rawAlloc(page, .@"16", 0) orelse return null;
        const s = h.makeSpan((count + 63) / 64, .{
            .base = @intFromPtr(mem),
            .len = page,
            .size = size,
            .count = @intCast(count),
            .nwords = 0,
            .class = @intCast(class),
            .noscan = index >= class_count,
            .large = false,
            .free = &.{},
            .mark = &.{},
        }) orelse {
            h.backing.rawFree(mem[0..page], .@"16", 0);
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

    /// Starts a collection when the heap is at its threshold, or when an
    /// allocation of `extra` bytes goes above the memory limit. The test
    /// reads byte counts only.
    fn maybeCollect(h: *Heap, extra: usize) void {
        if (h.roots_fn == null) return;
        if (h.bytes + extra < h.threshold and h.used.* + extra <= h.limit.*) return;
        collect(h);
    }

    fn allocLarge(h: *Heap, len: usize, alignment: Alignment) ?[*]u8 {
        h.maybeCollect(len);
        const a = alignment.max(.@"16");
        const size = std.mem.alignForward(usize, len, 16);
        const mem = h.backing.rawAlloc(size, a, 0) orelse return null;
        const s = h.makeSpan(1, .{
            .base = @intFromPtr(mem),
            .len = size,
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
            h.backing.rawFree(mem[0..size], a, 0);
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
        if (h.stress != 0) h.stressTick();
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
            h.maybeCollect(pageBytes(class_size[index % class_count]));
            if (h.cur[index] != null or h.partial[index] != null) continue;
            h.cur[index] = h.newPage(index) orelse return null;
        }
    }

    fn stressTick(h: *Heap) void {
        if (h.stress_left > 1) {
            h.stress_left -= 1;
            return;
        }
        // A large heap makes a collection slow, so the gap grows with the
        // heap: one more step for each 16 MiB.
        h.stress_left = h.stress * @as(u32, @intCast(@min(1 + (h.bytes >> 24), 1 << 16)));
        collect(h);
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
    // Pointers cluster, so the span of the last hit often serves.
    const s = if (h.last) |l| (if (w -% l.base < l.len) l else h.find(w)) else h.find(w);
    const sp = s orelse return;
    h.last = sp;
    return markIn(h, sp, w);
}

fn markIn(h: *Heap, s: *Span, w: usize) void {
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
    h.work.append(h.backing, .{ .ptr = start, .len = if (s.large) s.len else s.size }) catch {
        h.mark_ok = false;
    };
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
    var p = first;
    while (p + @sizeOf(usize) <= end) : (p += @sizeOf(usize)) {
        const w = @as(*const usize, @ptrFromInt(p)).*;
        markWord(h, w);
    }
}

fn drain(h: *Heap) void {
    while (h.work.pop()) |r| scan(h, r.ptr, r.len);
}

/// Runs a collection. The roots come from `roots_fn`. The sweep frees
/// each block that no root reached. A failed mark frees no block.
pub fn collect(h: *Heap) void {
    const roots = h.roots_fn orelse return;
    h.collections += 1;
    h.mark_ok = true;
    h.work.clearRetainingCapacity();
    if (!roots(h.roots_ctx, h)) {
        h.work.clearRetainingCapacity();
        return;
    }
    drain(h);
    h.work.clearRetainingCapacity();
    sweep(h);
}

fn sweep(h: *Heap) void {
    if (!h.mark_ok) {
        for (h.spans.items) |s| @memset(s.mark, 0);
        return;
    }
    h.cur = @splat(null);
    h.partial = @splat(null);
    h.last = null;
    var live_bytes: usize = 0;
    var keep: usize = 0;
    const items = h.spans.items;
    for (items) |s| {
        if (s.large) {
            if (s.mark[0] == 0) {
                if (fill_dead) @memset(@as([*]u8, @ptrFromInt(s.base))[0..s.len], dead_byte);
                h.bytes -= s.len;
                h.freeSpan(s);
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
            if (fill_dead) {
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
    h.live_bytes = live_bytes;
    h.threshold = @max(min_threshold, 2 * live_bytes);
    // The bounds may be wider than the spans. That is safe.
}

test "each size class serves its block size" {
    var used: usize = 0;
    var limit: usize = std.math.maxInt(usize);
    var h = Heap.init(std.testing.allocator, &used, &limit);
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
    var used: usize = 0;
    var limit: usize = std.math.maxInt(usize);
    var h = Heap.init(std.testing.allocator, &used, &limit);
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
    var used: usize = 0;
    var limit: usize = std.math.maxInt(usize);
    var h = Heap.init(std.testing.allocator, &used, &limit);
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
    var used: usize = 0;
    var limit: usize = std.math.maxInt(usize);
    var h = Heap.init(std.testing.allocator, &used, &limit);
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

test "reset frees all pages" {
    var used: usize = 0;
    var limit: usize = std.math.maxInt(usize);
    var h = Heap.init(std.testing.allocator, &used, &limit);
    defer h.deinit();
    const a = h.allocator();
    for (0..1000) |_| _ = try a.alloc(u8, 70);
    _ = try a.alloc(u8, 100_000);
    try std.testing.expect(h.bytes > 100_000);
    h.reset();
    try std.testing.expectEqual(@as(usize, 0), h.bytes);
    _ = try a.alloc(u64, 4);
}

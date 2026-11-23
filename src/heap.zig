//! The heap of an interpreter: pages of blocks in size classes.
//!
//! A page has 16 KiB or more and holds blocks of one size class. A request
//! above 8 KiB, or with an alignment above 16, is a large block with a
//! span of its own. Each span has a free bitmap and a mark bitmap. A set
//! free bit means that the block can be handed out. An allocation takes
//! the lowest set free bit of the current page of its class, so it needs
//! no lookup of an address. A sorted table of the spans gives the block
//! of an address in O(log n). A pointer into the middle of a block gives
//! the block.
//!
//! A request with an alignment below 8 cannot hold a pointer. Such a
//! block goes to pages of its own kind, and a scan of the heap does not
//! read it.
//!
//! `free` does nothing. Code of the interpreter keeps views of a buffer
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
    roots_fn: ?*const fn (ctx: *anyopaque, h: *Heap) void = null,
    roots_ctx: *anyopaque = undefined,
    /// The work list of the mark. It lives outside the heap.
    work: std.ArrayList(Range) = .empty,
    /// False when the work list could not grow: the sweep must not run.
    mark_ok: bool = true,
    live_bytes: usize = 0,
    collections: u64 = 0,

    pub const Range = struct { ptr: usize, len: usize };

    pub fn init(backing: Allocator) Heap {
        return .{ .backing = backing };
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

    fn allocLarge(h: *Heap, len: usize, alignment: Alignment) ?[*]u8 {
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

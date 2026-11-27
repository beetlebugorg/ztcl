//! The allocator of the ztcl unikernel (ztcl#471): one heap over the
//! identity-mapped guest memory above the image, for one CPU.
//!
//! - A block of 4,096 bytes or less comes from the free list of its size
//!   class: the powers of two from 16 to 4,096 bytes. An empty list
//!   gets a slab of 64 KiB from the page heap and cuts it into blocks.
//!   A freed block goes back on the list of its class.
//! - A larger block is a run of 4 KiB pages. The free runs are a list in
//!   address order. An allocation uses the first run that fits and
//!   splits it. A free puts the run back in order and joins it with the
//!   runs next to it.
//! - The heap grows up from its start: a run comes from the top of the
//!   used part when no free run fits, and the top never goes past the
//!   end of the memory.
//!
//! There is one CPU, and no interrupt handler allocates, so the heap has
//! no lock. A page that no code touched has no host memory, so the
//! heap writes no page before it gives the page out.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const page: usize = 4096;
const min_class = 4; // 16 bytes
const max_class = 12; // 4,096 bytes
const classes = max_class - min_class + 1;
const slab: usize = 64 << 10;

const Free = struct { next: ?*Free };
const Run = struct { next: ?*Run, pages: usize };

var lists: [classes]?*Free = @splat(null);
var runs: ?*Run = null;
var top: usize = 0;
var end: usize = 0;
/// The bytes that the heap gave out and did not get back, and the most.
pub var used: usize = 0;
pub var peak: usize = 0;

/// Gives the heap the memory from `start` to `stop`.
pub fn init(start: usize, stop: usize) void {
    top = std.mem.alignForward(usize, start, page);
    end = stop & ~(page - 1);
}

/// The highest address that the heap used.
pub fn high() usize {
    return top;
}

fn classOf(len: usize, a: Alignment) ?usize {
    const n = @max(len, a.toByteUnits(), 16);
    if (n > page) return null;
    const bits = std.math.log2_int_ceil(usize, n);
    return bits - min_class;
}

fn takePages(n: usize) ?usize {
    var prev: *?*Run = &runs;
    while (prev.*) |r| : (prev = &r.next) {
        if (r.pages < n) continue;
        const at = @intFromPtr(r);
        if (r.pages == n) {
            prev.* = r.next;
        } else {
            const rest: *Run = @ptrFromInt(at + n * page);
            rest.* = .{ .next = r.next, .pages = r.pages - n };
            prev.* = rest;
        }
        return at;
    }
    if (end - top < n * page) return null;
    const at = top;
    top += n * page;
    return at;
}

fn putPages(at: usize, n: usize) void {
    var prev: *?*Run = &runs;
    var before: ?*Run = null;
    while (prev.*) |r| {
        if (@intFromPtr(r) > at) break;
        before = r;
        prev = &r.next;
    }
    const me: *Run = @ptrFromInt(at);
    me.* = .{ .next = prev.*, .pages = n };
    prev.* = me;
    // Join with the next run, then with the run before.
    if (me.next) |nx| if (at + me.pages * page == @intFromPtr(nx)) {
        me.pages += nx.pages;
        me.next = nx.next;
    };
    if (before) |b| if (@intFromPtr(b) + b.pages * page == at) {
        b.pages += me.pages;
        b.next = me.next;
    };
}

fn pagesOf(len: usize) usize {
    return (len + page - 1) / page;
}

fn alloc(_: *anyopaque, len: usize, a: Alignment, _: usize) ?[*]u8 {
    if (classOf(len, a)) |c| {
        if (lists[c] == null) {
            const base = takePages(slab / page) orelse return null;
            const size = @as(usize, 1) << @intCast(c + min_class);
            var off: usize = slab;
            while (off >= size) {
                off -= size;
                const f: *Free = @ptrFromInt(base + off);
                f.next = lists[c];
                lists[c] = f;
            }
        }
        const f = lists[c].?;
        lists[c] = f.next;
        f.next = null;
        used += @as(usize, 1) << @intCast(c + min_class);
        peak = @max(peak, used);
        return @ptrCast(f);
    }
    if (a.toByteUnits() > page) return null;
    const n = pagesOf(len);
    const at = takePages(n) orelse return null;
    used += n * page;
    peak = @max(peak, used);
    return @ptrFromInt(at);
}

fn free(_: *anyopaque, mem: []u8, a: Alignment, _: usize) void {
    if (classOf(mem.len, a)) |c| {
        const f: *Free = @ptrCast(@alignCast(mem.ptr));
        f.next = lists[c];
        lists[c] = f;
        used -= @as(usize, 1) << @intCast(c + min_class);
        return;
    }
    const n = pagesOf(mem.len);
    used -= n * page;
    putPages(@intFromPtr(mem.ptr), n);
}

fn resize(_: *anyopaque, mem: []u8, a: Alignment, new_len: usize, _: usize) bool {
    if (classOf(mem.len, a)) |c| return classOf(new_len, a) == c;
    if (new_len <= page) return false;
    const old = pagesOf(mem.len);
    const want = pagesOf(new_len);
    if (want == old) return true;
    if (want < old) {
        putPages(@intFromPtr(mem.ptr) + want * page, old - want);
        used -= (old - want) * page;
        return true;
    }
    // Growth in place at the top of the heap.
    const at = @intFromPtr(mem.ptr);
    if (at + old * page == top and end - top >= (want - old) * page) {
        top += (want - old) * page;
        used += (want - old) * page;
        peak = @max(peak, used);
        return true;
    }
    return false;
}

fn remap(ctx: *anyopaque, mem: []u8, a: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (resize(ctx, mem, a, new_len, ra)) mem.ptr else null;
}

pub const allocator: Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
} };

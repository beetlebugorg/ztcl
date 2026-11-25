//! The threads of the WebAssembly build with one shared memory.
//!
//! Each ztcl thread runs in its own Web Worker, or in a `worker_threads`
//! worker in Node.js. Each worker has its own instance of the one
//! compiled module, and all instances use one shared memory. The host
//! makes the workers. This file has the parts that `std.Thread` and
//! `std.Io` give on the native platforms:
//!
//! - A thread start: `spawn` allocates one block for the stack, the
//!   thread-local data, and the start record, and calls the import
//!   `thread_spawn`. The new worker calls the export `ztcl_thread_start`
//!   with the address of the record. That function sets the stack
//!   pointer of its instance and the thread-local data, and runs the
//!   thread. After the return, the host stores 1 in `done` and wakes
//!   the futex of `done`. `join` waits for that word and frees the
//!   block, so no thread frees a stack that it still uses.
//! - A futex: `memory.atomic.wait32` and `memory.atomic.notify`. A wait
//!   needs a worker or Node.js: a browser does not allow it on its main
//!   thread.
//! - A lock: a word with three states (free, held, held with waiters).
//! - An allocator: free lists of size classes on pages of
//!   `memory.grow`, under one lock.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Makes a worker that calls `ztcl_thread_start(arg)`. Gives 0 on
/// success.
extern "ztcl" fn thread_spawn(arg: usize) i32;
/// Milliseconds since 1970 on a clock that does not go back:
/// `performance.timeOrigin + performance.now()`. Each worker gets the
/// same value at the same time.
extern "ztcl" fn now_ms() f64;

extern fn __wasm_init_tls(mem: [*]u8) void;

fn tlsSize() usize {
    return asm volatile (
        \\.globaltype __tls_size, i32, immutable
        \\global.get __tls_size
        \\local.set %[ret]
        : [ret] "=r" (-> usize),
    );
}

fn tlsAlign() usize {
    return asm volatile (
        \\.globaltype __tls_align, i32, immutable
        \\global.get __tls_align
        \\local.set %[ret]
        : [ret] "=r" (-> usize),
    );
}

fn setStackPointer(sp: usize) void {
    asm volatile (
        \\.globaltype __stack_pointer, i32
        \\local.get %[sp]
        \\global.set __stack_pointer
        :
        : [sp] "r" (sp),
    );
}

/// Waits while `ptr.*` is `expect`, at most `ns` nanoseconds, or with no
/// end for a negative `ns`.
pub fn futexWait(ptr: *const u32, expect: u32, ns: i64) void {
    _ = asm volatile (
        \\local.get %[ptr]
        \\local.get %[expect]
        \\local.get %[ns]
        \\memory.atomic.wait32 0
        \\local.set %[ret]
        : [ret] "=r" (-> u32),
        : [ptr] "r" (ptr),
          [expect] "r" (@as(i32, @bitCast(expect))),
          [ns] "r" (ns),
    );
}

pub fn futexWake(ptr: *const u32, n: u32) void {
    _ = asm volatile (
        \\local.get %[ptr]
        \\local.get %[n]
        \\memory.atomic.notify 0
        \\local.set %[ret]
        : [ret] "=r" (-> u32),
        : [ptr] "r" (ptr),
          [n] "r" (n),
    );
}

pub fn nowNs() i96 {
    return @intFromFloat(now_ms() * std.time.ns_per_ms);
}

/// The host of the capabilities `clock` and `event`.
pub fn nowMicros(_: ?*anyopaque) i64 {
    return @intFromFloat(now_ms() * 1000);
}

pub fn sleepMicros(_: ?*anyopaque, us: i64) void {
    const word: u32 = 0;
    if (us > 0) futexWait(&word, 0, us * 1000);
}

/// 0 is free, 1 is held, and 2 is held with waiters.
pub const Lock = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn lock(l: *Lock) void {
        if (l.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
        while (l.state.swap(2, .acquire) != 0) futexWait(&l.state.raw, 2, -1);
    }

    pub fn unlock(l: *Lock) void {
        if (l.state.swap(0, .release) == 2) futexWake(&l.state.raw, 1);
    }
};

// ---- Threads ----

const Block = struct {
    /// The host stores 1 here after the thread returns.
    done: std.atomic.Value(u32) = .init(0),
    mem: []u8,
    gpa: Allocator,
    stack_top: usize,
    tls: usize,
    run: *const fn (*Block) void,
    args: usize,
};

pub const Thread = struct {
    b: *Block,

    pub fn spawn(config: std.Thread.SpawnConfig, comptime f: anytype, args: anytype) !Thread {
        const Args = @TypeOf(args);
        const W = struct {
            fn run(b: *Block) void {
                const a: *Args = @ptrFromInt(b.args);
                @call(.auto, f, a.*);
            }
        };
        const gpa = config.allocator.?;
        const stack = std.mem.alignForward(usize, config.stack_size, 16);
        const tls_at = stack;
        const args_at = std.mem.alignForward(usize, tls_at + tlsSize(), @max(@alignOf(Args), 8));
        const block_at = std.mem.alignForward(usize, args_at + @sizeOf(Args), @alignOf(Block));
        const total = block_at + @sizeOf(Block);
        const align_tls = @max(tlsAlign(), 16);
        const mem = try gpa.alignedAlloc(u8, .fromByteUnits(16), total + align_tls);
        const base = @intFromPtr(mem.ptr);
        const tls = std.mem.alignForward(usize, base + tls_at, align_tls);
        const a: *Args = @ptrFromInt(base + args_at + align_tls);
        a.* = args;
        const b: *Block = @ptrFromInt(base + block_at + align_tls);
        b.* = .{ .mem = mem, .gpa = gpa, .stack_top = base + stack, .tls = tls, .run = W.run, .args = @intFromPtr(a) };
        if (thread_spawn(@intFromPtr(b)) != 0) {
            gpa.free(mem);
            return error.SystemResources;
        }
        return .{ .b = b };
    }

    pub fn join(t: Thread) void {
        while (t.b.done.load(.acquire) == 0) futexWait(&t.b.done.raw, 0, -1);
        t.b.gpa.free(t.b.mem);
    }
};

/// The entry of a new worker. The function has no frame of its own:
/// it sets the stack pointer before a call uses the stack.
export fn ztcl_thread_start(b: *Block) void {
    setStackPointer(b.stack_top);
    start(b);
}

noinline fn start(b: *Block) void {
    __wasm_init_tls(@ptrFromInt(b.tls));
    b.run(b);
}

/// The address of `done` in the record, for the host.
export fn ztcl_thread_done(b: *Block) *u32 {
    return &b.done.raw;
}

// ---- The allocator ----

const page = std.wasm.page_size;
/// The small size classes: 16 bytes to 32 KiB, powers of two.
const small_min = 4;
const small_max = 15;
/// The large size classes: 1 to 2^15 pages.
const big_classes = 16;

const Heap = struct {
    lock: Lock = .{},
    free_small: [small_max + 1]usize = @splat(0),
    free_big: [big_classes]usize = @splat(0),
    /// The next free byte and the end of the current page of small
    /// blocks.
    next: usize = 0,
    end: usize = 0,
};

var heap: Heap = .{};

pub const heap_allocator: Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
} };

/// The class of a request: a small class gives a power of two of bytes,
/// and a big class a power of two of pages.
const Class = union(enum) { small: u5, big: u5 };

fn classOf(len: usize, alignment: Alignment) ?Class {
    const n = @max(len, alignment.toByteUnits(), 1 << small_min);
    if (n <= 1 << small_max) return .{ .small = @intCast(std.math.log2_int_ceil(usize, n)) };
    const pages = (n + page - 1) / page;
    const c = std.math.log2_int_ceil(usize, pages);
    if (c >= big_classes) return null;
    return .{ .big = @intCast(c) };
}

fn grow(pages: usize) ?usize {
    const at = @wasmMemoryGrow(0, pages);
    if (at < 0) return null;
    return @as(usize, @intCast(at)) * page;
}

fn alloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const c = classOf(len, alignment) orelse return null;
    heap.lock.lock();
    defer heap.lock.unlock();
    switch (c) {
        .small => |k| {
            const size = @as(usize, 1) << k;
            if (heap.free_small[k] != 0) {
                const p = heap.free_small[k];
                heap.free_small[k] = @as(*usize, @ptrFromInt(p)).*;
                return @ptrFromInt(p);
            }
            // A block of a class is aligned to its size inside a page.
            var at = std.mem.alignForward(usize, heap.next, size);
            if (at + size > heap.end) {
                at = grow(1) orelse return null;
                heap.end = at + page;
            }
            heap.next = at + size;
            return @ptrFromInt(at);
        },
        .big => |k| {
            if (heap.free_big[k] != 0) {
                const p = heap.free_big[k];
                heap.free_big[k] = @as(*usize, @ptrFromInt(p)).*;
                return @ptrFromInt(p);
            }
            return @ptrFromInt(grow(@as(usize, 1) << k) orelse return null);
        },
    }
}

fn resize(_: *anyopaque, mem: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    const old = classOf(mem.len, alignment) orelse return false;
    const new = classOf(new_len, alignment) orelse return false;
    return std.meta.eql(old, new);
}

fn remap(ctx: *anyopaque, mem: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (resize(ctx, mem, alignment, new_len, ra)) mem.ptr else null;
}

fn free(_: *anyopaque, mem: []u8, alignment: Alignment, _: usize) void {
    const c = classOf(mem.len, alignment).?;
    heap.lock.lock();
    defer heap.lock.unlock();
    const p = @intFromPtr(mem.ptr);
    const list = switch (c) {
        .small => |k| &heap.free_small[k],
        .big => |k| &heap.free_big[k],
    };
    @as(*usize, @ptrFromInt(p)).* = list.*;
    list.* = p;
}

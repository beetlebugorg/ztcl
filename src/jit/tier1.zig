//! The driver of tier 1: verify, assemble, and copy one function.
//!
//! The verifier gives the static depth of each instruction, the
//! templates of `tier1_x64.zig` make the bytes, and the executable
//! region gets a copy. The record of the function (`Fn`) lives outside
//! the heap and outside the executable pages. It has the offset of the
//! code of each instruction and the depth of each instruction, so
//! `jit.enter` can check an entry. Each failure gives null, and the
//! `Code` then stays in the interpreter.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vm = @import("../vm.zig");
const x64 = @import("x64.zig");
const verify = @import("verify.zig");
const layout = @import("layout.zig");
const mem = @import("mem.zig");
const templates = @import("tier1_x64.zig");

const Allocator = std.mem.Allocator;

pub const no_entry = templates.no_entry;
pub const status_done = templates.status_done;
pub const status_error = templates.status_error;
pub const status_exit = templates.status_exit;

/// A compiled function.
pub const Fn = struct {
    /// The first byte of the function in the executable region.
    base: [*]const u8,
    len: u32,
    /// The offset of the code of each instruction, or `no_entry`.
    entries: []u32,
    /// The stack depth before each instruction.
    depth: []const u16,
    /// The loop heads of the verifier, and a pass counter and a record
    /// of tier 2 for each one. Empty when tier 2 is off. One more counter
    /// after the pass counters serves the stress mode of tier 2.
    heads: []const u32 = &.{},
    /// The place in `stress_counts` of the stress counter.
    stress_at: u8 = 0,
    counters: []u32 = &.{},
    loops: []Loop = &.{},

    /// The bytes of the executable pages of the function.
    pub fn pages(f: *const Fn, page: usize) usize {
        return std.mem.alignForward(usize, f.len, page);
    }

    /// The bytes of the record.
    pub fn bytes(f: *const Fn) usize {
        return @sizeOf(Fn) + f.entries.len * @sizeOf(u32) + f.depth.len * @sizeOf(u16) + f.heads.len * (2 * @sizeOf(u32) + @sizeOf(Loop)) + f.counters.len;
    }

    pub fn free(f: *Fn, a: Allocator) void {
        a.free(f.entries);
        a.free(f.depth);
        a.free(f.heads);
        a.free(f.counters);
        a.free(f.loops);
        a.destroy(f);
    }
};

/// The tier 2 state of one loop head.
pub const Loop = struct {
    /// The entry of the tier 2 code, in the executable region.
    code: ?[*]const u8 = null,
    tried: bool = false,
    /// The exits of failed guards that the stress mode did not force.
    exits: u8 = 0,
};

/// The counts of the stress schedule of tier 2: the Nth check of a guard
/// fails, for each N in turn.
pub const stress_counts = [_]u32{ 3, 7, 13 };

/// The result of one compile.
pub const Result = union(enum) {
    ok: *Fn,
    /// The verifier, the assembler, or an allocation failed.
    failed,
    /// The JIT memory limit is reached.
    full,
    /// A system call of the region failed.
    stopped,
};

/// Compiles `code`. `budget` is the bytes left below the JIT memory
/// limit. The function and its record use `pages(f) + f.bytes()`.
/// `tier2_count` is the count of passes of a loop before tier 2 compiles
/// it, or 0 when tier 2 is off.
pub fn compile(a: Allocator, region: *mem.Region, l: layout.Layout, code: *const vm.Code, budget: usize, tier2_count: u32) Result {
    const tier2 = tier2_count != 0;
    var info = (verify.verify(a, code) catch return .failed) orelse return .failed;
    var keep_depth = false;
    defer {
        a.free(info.reachable);
        a.free(info.loop_heads);
        if (!keep_depth) a.free(info.depth);
    }
    const entries = a.alloc(u32, code.ins.len) catch return .failed;
    var keep_entries = false;
    defer if (!keep_entries) a.free(entries);
    var s = x64.Asm.init(a);
    defer s.deinit();
    templates.assemble(a, &s, code, &info, l, entries, tier2) catch return .failed;
    const nh = if (tier2) info.loop_heads.len else 0;
    const heads = a.dupe(u32, info.loop_heads[0..nh]) catch return .failed;
    var keep_heads = false;
    defer if (!keep_heads) a.free(heads);
    const counters = a.alloc(u32, if (tier2) nh + 1 else 0) catch return .failed;
    defer if (!keep_heads) a.free(counters);
    @memset(counters, tier2_count);
    if (tier2) counters[nh] = stress_counts[0];
    const loops = a.alloc(Loop, nh) catch return .failed;
    defer if (!keep_heads) a.free(loops);
    @memset(loops, .{});
    const pages = std.mem.alignForward(usize, s.bytes().len, region.page);
    const data = @sizeOf(Fn) + entries.len * @sizeOf(u32) + info.depth.len * @sizeOf(u16) + nh * (2 * @sizeOf(u32) + @sizeOf(Loop));
    if (pages + data > budget) return .full;
    const f = a.create(Fn) catch return .failed;
    const placed = region.append(s.bytes()) orelse {
        a.destroy(f);
        return if (region.stopped) .stopped else .full;
    };
    f.* = .{ .base = placed.ptr, .len = @intCast(placed.len), .entries = entries, .depth = info.depth, .heads = heads, .counters = counters, .loops = loops };
    keep_heads = true;
    keep_entries = true;
    keep_depth = true;
    return .{ .ok = f };
}

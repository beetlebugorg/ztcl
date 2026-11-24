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

    /// The bytes of the executable pages of the function.
    pub fn pages(f: *const Fn, page: usize) usize {
        return std.mem.alignForward(usize, f.len, page);
    }

    /// The bytes of the record.
    pub fn bytes(f: *const Fn) usize {
        return @sizeOf(Fn) + f.entries.len * @sizeOf(u32) + f.depth.len * @sizeOf(u16);
    }

    pub fn free(f: *Fn, a: Allocator) void {
        a.free(f.entries);
        a.free(f.depth);
        a.destroy(f);
    }
};

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
pub fn compile(a: Allocator, region: *mem.Region, l: layout.Layout, code: *const vm.Code, budget: usize) Result {
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
    templates.assemble(a, &s, code, &info, l, entries) catch return .failed;
    const pages = std.mem.alignForward(usize, s.bytes().len, region.page);
    const data = @sizeOf(Fn) + entries.len * @sizeOf(u32) + info.depth.len * @sizeOf(u16);
    if (pages + data > budget) return .full;
    const f = a.create(Fn) catch return .failed;
    const placed = region.append(s.bytes()) orelse {
        a.destroy(f);
        return if (region.stopped) .stopped else .full;
    };
    f.* = .{ .base = placed.ptr, .len = @intCast(placed.len), .entries = entries, .depth = info.depth };
    keep_entries = true;
    keep_depth = true;
    return .{ .ok = f };
}

//! The machine code of the JIT for `ztcl::disasm machine`: assembles a
//! `Code` again into a buffer that never runs, with the marks of each
//! bytecode instruction, and gives the text of each instruction with the
//! disassemblers of `x64_dis.zig` and `a64_dis.zig`, for the target of
//! the host.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const vm = @import("../vm.zig");
const verify = @import("verify.zig");
const layout = @import("layout.zig");
const marks = @import("marks.zig");
const tier2 = @import("tier2.zig");

const Allocator = std.mem.Allocator;

pub const Arch = enum { x86_64, aarch64 };

pub const native: Arch = if (builtin.cpu.arch == .aarch64) .aarch64 else .x86_64;

/// One machine instruction: its offset, its bytes, its text, and the
/// bytecode instruction that it belongs to (`marks.none` for the entry,
/// the exit, and the shared parts).
pub const Line = struct { at: u32, bytes: []const u8, text: []const u8, pc: u32 };

pub const Listing = struct {
    lines: []Line,
    len: u32,
};

pub const Error = error{ NotCompiled, OutOfMemory };

/// The tier 1 code of `code` for `arch`.
pub fn tier1(a: Allocator, code: *const vm.Code, arch: Arch) Error!Listing {
    const l = layout.probe() orelse return error.NotCompiled;
    var info = (try verify.verify(a, code)) orelse return error.NotCompiled;
    defer info.deinit(a);
    const entries = try a.alloc(u32, code.ins.len);
    defer a.free(entries);
    var m: marks.Marks = .{ .a = a };
    defer m.deinit();
    // Only the target of the host: the emitters of the other target
    // would add their whole size to the runner.
    if (arch != native) return error.NotCompiled;
    const t = comptime native;
    {
        const A = asmOf(t);
        var s = A.init(a);
        defer s.deinit();
        s.marks = &m;
        (if (t == .aarch64) @import("tier1_a64.zig") else @import("tier1_x64.zig")).assemble(a, &s, code, &info, l, entries, true) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return error.NotCompiled;
        };
        return lines(a, t, s.bytes(), m.list.items);
    }
}

/// The tier 2 code of the loop at `head` for `arch`, with the slots of
/// the kinds `kinds` at the entry of the loop. Null when the loop is not
/// eligible for tier 2.
pub fn loop(a: Allocator, code: *const vm.Code, head: u32, kinds: []const tier2.Kind, arch: Arch) Error!?Listing {
    const l = layout.probe() orelse return error.NotCompiled;
    var info = (try verify.verify(a, code)) orelse return error.NotCompiled;
    defer info.deinit(a);
    const k = std.mem.indexOfScalar(u32, info.loop_heads, head) orelse return null;
    var p = (try tier2.plan(a, code, &info, head, kinds)) orelse return null;
    defer p.deinit();
    var m: marks.Marks = .{ .a = a };
    defer m.deinit();
    // Only the target of the host: the emitters of the other target
    // would add their whole size to the runner.
    if (arch != native) return error.NotCompiled;
    const t = comptime native;
    {
        const be = if (t == .aarch64) @import("tier2_a64.zig") else @import("tier2_x64.zig");
        if (!be.eligible(code, &info, &p)) return null;
        var s = asmOf(t).init(a);
        defer s.deinit();
        s.marks = &m;
        be.assemble(a, &s, code, &info, &p, l, @intCast(k), @intCast(info.loop_heads.len), false) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return null;
        };
        return try lines(a, t, s.bytes(), m.list.items);
    }
}

/// The loop heads of `code`, for `loop`.
pub fn heads(a: Allocator, code: *const vm.Code) Error![]u32 {
    var info = (try verify.verify(a, code)) orelse return error.NotCompiled;
    defer info.deinit(a);
    return a.dupe(u32, info.loop_heads);
}

fn asmOf(comptime t: Arch) type {
    return if (t == .aarch64) @import("a64.zig").Asm else @import("x64.zig").Asm;
}

fn lines(a: Allocator, comptime t: Arch, bytes: []const u8, ms: []const marks.Mark) Error!Listing {
    const dis = if (t == .aarch64) @import("a64_dis.zig") else @import("x64_dis.zig");
    var out: std.ArrayList(Line) = .empty;
    var at: usize = 0;
    var mk: usize = 0;
    var pc: u32 = marks.none;
    while (at < bytes.len) {
        // The last mark at or before `at` names the instruction.
        while (mk < ms.len and ms[mk].at <= at) : (mk += 1) pc = ms[mk].pc;
        const ins = dis.decode(a, bytes, at);
        const n: usize = @max(ins.len, 1);
        const text = dis.text(a, ins, bytes, at) catch return error.OutOfMemory;
        try out.append(a, .{ .at = @intCast(at), .bytes = bytes[at..@min(at + n, bytes.len)], .text = text, .pc = pc });
        at += n;
    }
    // The bytes of the lines point into the buffer of the assembler,
    // which ends with this call: each line keeps a copy.
    for (out.items) |*ln| ln.bytes = try a.dupe(u8, ln.bytes);
    return .{ .lines = try out.toOwnedSlice(a), .len = @intCast(bytes.len) };
}

//! A disassembler for the instruction forms of `a64.zig`, for the
//! listings of `ztcl::disasm machine`. For each form of the assembler
//! (`a64.Form`) it reads the operand fields of the word, makes a row of
//! the golden table, and encodes that row again with `a64.encodeRow`.
//! The first row that gives the same word is the instruction. A word
//! that no row gives is not a form of the JIT, and shows as `.word`. So
//! the assembler is the table of the decoder, and the golden table
//! tests it.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const a64 = @import("a64.zig");
const helpers = @import("helpers.zig");
const abi = @import("abi.zig");

const Allocator = std.mem.Allocator;
const Row = a64.Row;
const Form = a64.Form;

pub const Ins = struct { len: u8 = 4, row: ?Row = null, target: ?i64 = null };

/// The field of a register operand: bits 0, 5, 16, or 10 of the word.
const Src = enum { none, d, n, m, t2 };

const Spec = struct { f: Form, a: Src = .none, b: Src = .none, c: Src = .none, ks: u8 = 1 };

const specs = [_]Spec{
    .{ .f = .mov_rr, .a = .d, .b = .m },
    .{ .f = .mov_rr, .a = .d, .b = .n },
    .{ .f = .mov_rr32, .a = .d, .b = .m },
    .{ .f = .movz, .a = .d },
    .{ .f = .movk, .a = .d },
    .{ .f = .movn, .a = .d },
    .{ .f = .movz_w, .a = .d },
    .{ .f = .ldr_u, .a = .d, .b = .n, .ks = 4 },
    .{ .f = .str_u, .a = .d, .b = .n, .ks = 4 },
    .{ .f = .ldur, .a = .d, .b = .n, .ks = 4 },
    .{ .f = .stur, .a = .d, .b = .n, .ks = 4 },
    .{ .f = .ldr_r, .a = .d, .b = .n, .c = .m, .ks = 4 },
    .{ .f = .str_r, .a = .d, .b = .n, .c = .m, .ks = 4 },
    .{ .f = .stp_pre, .a = .d, .b = .t2, .c = .n },
    .{ .f = .stp_post, .a = .d, .b = .t2, .c = .n },
    .{ .f = .stp_off, .a = .d, .b = .t2, .c = .n },
    .{ .f = .ldp_pre, .a = .d, .b = .t2, .c = .n },
    .{ .f = .ldp_post, .a = .d, .b = .t2, .c = .n },
    .{ .f = .ldp_off, .a = .d, .b = .t2, .c = .n },
    .{ .f = .cmp_i, .a = .n },
    .{ .f = .add_i, .a = .d, .b = .n },
    .{ .f = .sub_i, .a = .d, .b = .n },
    .{ .f = .adds_i, .a = .d, .b = .n },
    .{ .f = .subs_i, .a = .d, .b = .n },
    .{ .f = .cmp_wi, .a = .n },
    .{ .f = .cmp_wr, .a = .n, .b = .m },
    .{ .f = .cmp_r, .a = .n, .b = .m },
    .{ .f = .op_r, .a = .d, .b = .n, .c = .m, .ks = a64.ops.len },
    .{ .f = .tst_i, .a = .n },
    .{ .f = .and_i, .a = .d, .b = .n },
    .{ .f = .mul, .a = .d, .b = .n, .c = .m },
    .{ .f = .smulh, .a = .d, .b = .n, .c = .m },
    .{ .f = .sdiv, .a = .d, .b = .n, .c = .m },
    .{ .f = .msub, .a = .d, .b = .n, .c = .m },
    .{ .f = .asr_i, .a = .d, .b = .n },
    .{ .f = .lsl_i, .a = .d, .b = .n },
    .{ .f = .cset, .a = .d, .ks = 14 },
    .{ .f = .b },
    .{ .f = .bcond, .ks = 14 },
    .{ .f = .cbz, .a = .d },
    .{ .f = .cbnz, .a = .d },
    .{ .f = .cbz_w, .a = .d },
    .{ .f = .cbnz_w, .a = .d },
    .{ .f = .br, .a = .n },
    .{ .f = .blr, .a = .n },
    .{ .f = .ret },
    .{ .f = .brk },
    .{ .f = .udf },
    .{ .f = .nop },
    .{ .f = .fmov_dd, .a = .d, .b = .n },
    .{ .f = .fmov_dx, .a = .d, .b = .n },
    .{ .f = .fmov_xd, .a = .d, .b = .n },
    .{ .f = .fop, .a = .d, .b = .n, .c = .m, .ks = a64.fops.len },
    .{ .f = .fcmp, .a = .n, .b = .m },
    .{ .f = .scvtf, .a = .d, .b = .n },
};

fn field(w: u32, src: Src) u8 {
    return @intCast(switch (src) {
        .none => 0,
        .d => w & 31,
        .n => (w >> 5) & 31,
        .m => (w >> 16) & 31,
        .t2 => (w >> 10) & 31,
    });
}

fn sext(v: u32, bits: u6) i64 {
    const sh: u6 = @intCast(64 - @as(u7, bits));
    return @as(i64, @bitCast(@as(u64, v) << sh)) >> sh;
}

/// The immediate operands of the form `f` in the word `w`.
fn imms(f: Form, w: u32, r: *Row) void {
    switch (f) {
        .movz, .movk, .movn => {
            r.i = (w >> 5) & 0xFFFF;
            r.j = @intCast(((w >> 21) & 3) * 16);
        },
        .movz_w, .brk => r.i = (w >> 5) & 0xFFFF,
        .udf => r.i = w & 0xFFFF,
        .ldr_u, .str_u => {
            const sh: u6 = switch (a64.sizes[r.k & 3]) {
                .x, .d => 3,
                .w => 2,
                .b => 0,
            };
            r.i = @as(i64, (w >> 10) & 0xFFF) << sh;
        },
        .ldur, .stur => r.i = sext((w >> 12) & 0x1FF, 9),
        .stp_pre, .stp_post, .stp_off, .ldp_pre, .ldp_post, .ldp_off => r.i = sext((w >> 15) & 0x7F, 7) * 8,
        .add_i, .sub_i, .adds_i, .subs_i, .cmp_i, .cmp_wi => {
            r.i = (w >> 10) & 0xFFF;
            r.j = @intCast((w >> 22) & 1);
        },
        .op_r, .cmp_r => {
            r.j = @intCast((w >> 22) & 3);
            r.i = (w >> 10) & 63;
        },
        .and_i, .tst_i => {
            const ones: u7 = @intCast(((w >> 10) & 63) + 1);
            r.i = if (ones >= 64) -1 else @bitCast((@as(u64, 1) << @intCast(ones)) - 1);
        },
        // Register 31 of `msub` is `zr`.
        .msub => r.j = @intCast(if ((w >> 10) & 31 == 31) 32 else (w >> 10) & 31),
        .asr_i => r.i = (w >> 16) & 63,
        .lsl_i => r.i = 64 - @as(i64, (w >> 16) & 63),
        else => {},
    }
}

/// The bits of the offset of a branch form, or 0.
fn branchMask(f: Form) u32 {
    return switch (f) {
        .b => 0x03FF_FFFF,
        .bcond, .cbz, .cbnz, .cbz_w, .cbnz_w => 0x00FF_FFE0,
        else => 0,
    };
}

fn encodeWord(scratch: Allocator, row: Row) ?u32 {
    var s = a64.Asm.init(scratch);
    defer s.deinit();
    s.reserveFor(1, 2) catch return null;
    a64.encodeRow(&s, row) catch return null;
    const b = s.bytes();
    if (b.len != 4) return null;
    return std.mem.readInt(u32, b[0..4], .little);
}

/// Decodes the word at `code[at..]`.
pub fn decode(scratch: Allocator, code: []const u8, at: usize) Ins {
    if (at + 4 > code.len) return .{ .len = @intCast(code.len - at) };
    const w = std.mem.readInt(u32, code[at..][0..4], .little);
    for (specs) |sp| {
        const mask = branchMask(sp.f);
        const srcs = [_]Src{ sp.a, sp.b, sp.c };
        // A field of 31 is `sp` or `zr`: each choice in turn.
        var amb: u3 = 0;
        for (srcs, 0..) |src, k| if (src != .none and field(w, src) == 31) {
            amb |= @as(u3, 1) << @intCast(k);
        };
        var v: u4 = 0;
        while (v < 8) : (v += 1) {
            if (v & ~@as(u4, amb) != 0) continue;
            var regs: [3]u8 = undefined;
            for (srcs, 0..) |src, k| regs[k] = field(w, src) + @as(u8, if (v >> @intCast(k) & 1 != 0) 1 else 0);
            var k: u8 = 0;
            while (k < sp.ks) : (k += 1) {
                var row: Row = .{ .f = sp.f, .a = regs[0], .b = regs[1], .c = regs[2], .k = k, .bytes = "" };
                imms(sp.f, w, &row);
                // `encodeRow` takes only the shifts of `a64.Shift`.
                if ((sp.f == .op_r or sp.f == .cmp_r) and row.j > 2) continue;
                const got = encodeWord(scratch, row) orelse continue;
                if (got & ~mask != w & ~mask) continue;
                var out: Ins = .{ .row = row };
                if (mask != 0) {
                    const off = if (sp.f == .b) sext(w & mask, 26) else sext((w & mask) >> 5, 19);
                    out.target = @as(i64, @intCast(at)) + off * 4;
                }
                return out;
            }
        }
    }
    return .{};
}

const conds = [_][]const u8{ "eq", "ne", "hs", "lo", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le" };

fn xr(v: u8, w: bool) []const u8 {
    const x = [_][]const u8{ "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x29", "x30", "sp", "xzr" };
    const ws = [_][]const u8{ "w0", "w1", "w2", "w3", "w4", "w5", "w6", "w7", "w8", "w9", "w10", "w11", "w12", "w13", "w14", "w15", "w16", "w17", "w18", "w19", "w20", "w21", "w22", "w23", "w24", "w25", "w26", "w27", "w28", "w29", "w30", "wsp", "wzr" };
    return if (w) ws[@min(v, 32)] else x[@min(v, 32)];
}

/// The text of one instruction, with a note for a call of a helper.
pub fn text(a: Allocator, ins: Ins, code: []const u8, at: usize) ![]const u8 {
    const row = ins.row orelse {
        if (at + 4 > code.len) return a.dupe(u8, ".byte");
        return std.fmt.allocPrint(a, ".word 0x{x:0>8}", .{std.mem.readInt(u32, code[at..][0..4], .little)});
    };
    const tgt = ins.target orelse 0;
    const z = a64.sizes[row.k & 3];
    const t: []const u8 = if (z == .d) try std.fmt.allocPrint(a, "d{d}", .{row.a & 31}) else xr(row.a, z == .w or z == .b);
    const ls = [_][]const u8{ "", "", "b", "" };
    return switch (row.f) {
        .mov_rr => std.fmt.allocPrint(a, "mov {s}, {s}", .{ xr(row.a, false), xr(row.b, false) }),
        .mov_rr32 => std.fmt.allocPrint(a, "mov {s}, {s}", .{ xr(row.a, true), xr(row.b, true) }),
        .movz, .movk, .movn => std.fmt.allocPrint(a, "{t} {s}, 0x{x}, lsl {d}", .{ row.f, xr(row.a, false), row.i, row.j }),
        .movz_w => std.fmt.allocPrint(a, "movz {s}, 0x{x}", .{ xr(row.a, true), row.i }),
        .ldr_u, .ldur => if (helperOf(row)) |h|
            std.fmt.allocPrint(a, "ldr {s}, [{s}, {d}]  ; {t}", .{ t, xr(row.b, false), row.i, h })
        else
            std.fmt.allocPrint(a, "ldr{s} {s}, [{s}, {d}]", .{ ls[row.k & 3], t, xr(row.b, false), row.i }),
        .str_u, .stur => std.fmt.allocPrint(a, "str{s} {s}, [{s}, {d}]", .{ ls[row.k & 3], t, xr(row.b, false), row.i }),
        .ldr_r => std.fmt.allocPrint(a, "ldr{s} {s}, [{s}, {s}]", .{ ls[row.k & 3], t, xr(row.b, false), xr(row.c, false) }),
        .str_r => std.fmt.allocPrint(a, "str{s} {s}, [{s}, {s}]", .{ ls[row.k & 3], t, xr(row.b, false), xr(row.c, false) }),
        .stp_pre, .ldp_pre => std.fmt.allocPrint(a, "{s} {s}, {s}, [{s}, {d}]!", .{ if (row.f == .stp_pre) "stp" else "ldp", xr(row.a, false), xr(row.b, false), xr(row.c, false), row.i }),
        .stp_post, .ldp_post => std.fmt.allocPrint(a, "{s} {s}, {s}, [{s}], {d}", .{ if (row.f == .stp_post) "stp" else "ldp", xr(row.a, false), xr(row.b, false), xr(row.c, false), row.i }),
        .stp_off, .ldp_off => std.fmt.allocPrint(a, "{s} {s}, {s}, [{s}, {d}]", .{ if (row.f == .stp_off) "stp" else "ldp", xr(row.a, false), xr(row.b, false), xr(row.c, false), row.i }),
        .add_i, .sub_i, .adds_i, .subs_i => std.fmt.allocPrint(a, "{s} {s}, {s}, {d}{s}", .{ switch (row.f) {
            .add_i => "add",
            .sub_i => "sub",
            .adds_i => "adds",
            else => "subs",
        }, xr(row.a, false), xr(row.b, false), row.i, if (row.j != 0) ", lsl 12" else "" }),
        .cmp_i => std.fmt.allocPrint(a, "cmp {s}, {d}", .{ xr(row.a, false), row.i }),
        .cmp_wi => std.fmt.allocPrint(a, "cmp {s}, {d}", .{ xr(row.a, true), row.i }),
        .cmp_wr => std.fmt.allocPrint(a, "cmp {s}, {s}", .{ xr(row.a, true), xr(row.b, true) }),
        .op_r => std.fmt.allocPrint(a, "{t} {s}, {s}, {s}{s}", .{ a64.ops[row.k], xr(row.a, false), xr(row.b, false), xr(row.c, false), try shiftText(a, row) }),
        .cmp_r => std.fmt.allocPrint(a, "cmp {s}, {s}{s}", .{ xr(row.a, false), xr(row.b, false), try shiftText(a, row) }),
        .and_i => std.fmt.allocPrint(a, "and {s}, {s}, 0x{x}", .{ xr(row.a, false), xr(row.b, false), @as(u64, @bitCast(row.i)) }),
        .tst_i => std.fmt.allocPrint(a, "tst {s}, 0x{x}", .{ xr(row.a, false), @as(u64, @bitCast(row.i)) }),
        .mul, .smulh, .sdiv => std.fmt.allocPrint(a, "{t} {s}, {s}, {s}", .{ row.f, xr(row.a, false), xr(row.b, false), xr(row.c, false) }),
        .msub => std.fmt.allocPrint(a, "msub {s}, {s}, {s}, {s}", .{ xr(row.a, false), xr(row.b, false), xr(row.c, false), xr(row.j, false) }),
        .asr_i => std.fmt.allocPrint(a, "asr {s}, {s}, {d}", .{ xr(row.a, false), xr(row.b, false), row.i }),
        .lsl_i => std.fmt.allocPrint(a, "lsl {s}, {s}, {d}", .{ xr(row.a, false), xr(row.b, false), row.i }),
        .cset => std.fmt.allocPrint(a, "cset {s}, {s}", .{ xr(row.a, false), conds[row.k] }),
        .b => std.fmt.allocPrint(a, "b 0x{x}", .{tgt}),
        .bcond => std.fmt.allocPrint(a, "b.{s} 0x{x}", .{ conds[row.k], tgt }),
        .cbz, .cbnz => std.fmt.allocPrint(a, "{t} {s}, 0x{x}", .{ row.f, xr(row.a, false), tgt }),
        .cbz_w, .cbnz_w => std.fmt.allocPrint(a, "{s} {s}, 0x{x}", .{ if (row.f == .cbz_w) "cbz" else "cbnz", xr(row.a, true), tgt }),
        .br => std.fmt.allocPrint(a, "br {s}", .{xr(row.a, false)}),
        .blr => std.fmt.allocPrint(a, "blr {s}", .{xr(row.a, false)}),
        .ret, .nop => a.dupe(u8, @tagName(row.f)),
        .brk, .udf => std.fmt.allocPrint(a, "{t} 0x{x}", .{ row.f, row.i }),
        .fmov_dd => std.fmt.allocPrint(a, "fmov d{d}, d{d}", .{ row.a, row.b }),
        .fmov_dx => std.fmt.allocPrint(a, "fmov d{d}, {s}", .{ row.a, xr(row.b, false) }),
        .fmov_xd => std.fmt.allocPrint(a, "fmov {s}, d{d}", .{ xr(row.a, false), row.b }),
        .fop => std.fmt.allocPrint(a, "{t} d{d}, d{d}, d{d}", .{ a64.fops[row.k], row.a, row.b, row.c }),
        .fcmp => std.fmt.allocPrint(a, "fcmp d{d}, d{d}", .{ row.a, row.b }),
        .scvtf => std.fmt.allocPrint(a, "scvtf d{d}, {s}", .{ row.a, xr(row.b, false) }),
    };
}

fn shiftText(a: Allocator, row: Row) ![]const u8 {
    if (row.i == 0) return "";
    const names = [_][]const u8{ "lsl", "lsr", "asr", "ror" };
    return std.fmt.allocPrint(a, ", {s} {d}", .{ names[row.j & 3], row.i });
}

/// The helper of a load from the helper table: `ldr x?, [x23, 8*h]`.
pub fn helperOf(row: Row) ?helpers.Helper {
    if (row.f != .ldr_u or row.k != 0 or row.b != @backingInt(abi.a64.helpers)) return null;
    if (@rem(row.i, 8) != 0 or @divExact(row.i, 8) >= helpers.count) return null;
    return @fromBackingInt(@intCast(@divExact(row.i, 8)));
}

test "a64_dis: each row of the golden table decodes to its own word" {
    const golden = @import("a64_golden.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad: usize = 0;
    for (golden.rows) |row| {
        const ins = decode(std.testing.allocator, row.bytes, 0);
        if (ins.row == null) {
            if (bad < 10) std.debug.print("a64_dis: {t} {x}\n", .{ row.f, row.bytes });
            bad += 1;
            continue;
        }
        _ = try text(a, ins, row.bytes, 0);
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

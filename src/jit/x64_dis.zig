//! A disassembler for the instruction forms of `x64.zig`, for the
//! listings of `ztcl::disasm machine`. It decodes only the forms of the
//! assembler (`x64.Form`): it reads the prefix, the REX byte, the opcode,
//! the ModRM byte, the displacement, and the immediate, makes a row of
//! the golden table, and encodes that row again with `x64.encodeRow`. A
//! row whose bytes differ is not a form of the JIT, and its first byte
//! shows as `.byte`. So the assembler is the table of the decoder, and
//! the golden table tests it.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const x64 = @import("x64.zig");
const helpers = @import("helpers.zig");
const abi = @import("abi.zig");

const Allocator = std.mem.Allocator;
const Row = x64.Row;
const Form = x64.Form;

/// One decoded instruction: its length, its row (null for an unknown
/// byte), and the offset of the target of a branch.
pub const Ins = struct { len: u8, row: ?Row = null, target: ?i64 = null };

const Parts = struct {
    prefix: u8 = 0,
    w: bool = false,
    r: u8 = 0,
    b: u8 = 0,
    two: bool = false,
    op: u8 = 0,
    /// The ModRM fields: mode, reg (with REX.R), and rm (with REX.B).
    mode: u2 = 0,
    reg: u8 = 0,
    rm: u8 = 0,
    disp: i32 = 0,
    at: usize = 0,
};

fn readModrm(code: []const u8, p: *Parts) bool {
    if (p.at >= code.len) return false;
    const m = code[p.at];
    p.at += 1;
    p.mode = @intCast(m >> 6);
    p.reg = ((m >> 3) & 7) | p.r << 3;
    const low = m & 7;
    p.rm = low | p.b << 3;
    if (p.mode == 3) return true;
    if (low == 4) {
        // The SIB byte of a base with no index: the assembler writes 0x24.
        if (p.at >= code.len or code[p.at] != 0x24) return false;
        p.at += 1;
    }
    if (p.mode == 0 and low == 5) return false;
    switch (p.mode) {
        1 => {
            if (p.at >= code.len) return false;
            p.disp = @as(i8, @bitCast(code[p.at]));
            p.at += 1;
        },
        2 => {
            if (p.at + 4 > code.len) return false;
            p.disp = std.mem.readInt(i32, code[p.at..][0..4], .little);
            p.at += 4;
        },
        else => {},
    }
    return true;
}

fn imm8(code: []const u8, p: *Parts) ?i32 {
    if (p.at >= code.len) return null;
    const v: i8 = @bitCast(code[p.at]);
    p.at += 1;
    return v;
}

fn imm32(code: []const u8, p: *Parts) ?i32 {
    if (p.at + 4 > code.len) return null;
    const v = std.mem.readInt(i32, code[p.at..][0..4], .little);
    p.at += 4;
    return v;
}

/// The row of the instruction at the start of `code`, before the check
/// by encoding.
fn guess(code: []const u8, p: *Parts) ?Row {
    var at: usize = 0;
    if (at < code.len and (code[at] == 0x66 or code[at] == 0xF2)) {
        p.prefix = code[at];
        at += 1;
    }
    if (at < code.len and code[at] & 0xF0 == 0x40) {
        p.w = code[at] & 8 != 0;
        p.r = (code[at] >> 2) & 1;
        p.b = code[at] & 1;
        at += 1;
    }
    if (at >= code.len) return null;
    p.op = code[at];
    at += 1;
    if (p.op == 0x0F) {
        if (at >= code.len) return null;
        p.two = true;
        p.op = code[at];
        at += 1;
    }
    p.at = at;
    const o = p.op;
    const mem = struct {
        fn is(q: *const Parts) bool {
            return q.mode != 3;
        }
    }.is;
    if (p.two) {
        if (o >= 0x80 and o <= 0x8F) {
            _ = imm32(code, p) orelse return null;
            return .{ .f = .jcc, .k = o - 0x80, .bytes = "" };
        }
        if (o == 0x0B) return .{ .f = .ud2, .bytes = "" };
        if (!readModrm(code, p)) return null;
        return switch (p.prefix) {
            0xF2 => switch (o) {
                0x10 => .{ .f = .movsd_xm, .a = p.reg, .b = p.rm, .d = p.disp, .bytes = "" },
                0x11 => .{ .f = .movsd_mx, .a = p.rm, .b = p.reg, .d = p.disp, .bytes = "" },
                0x58, 0x59, 0x5C, 0x5E => .{ .f = .sse, .a = p.reg, .b = p.rm, .k = o, .bytes = "" },
                0x2A => .{ .f = .cvtsi2sd, .a = p.reg, .b = p.rm, .bytes = "" },
                else => null,
            },
            0x66 => switch (o) {
                0x28 => .{ .f = .movapd, .a = p.reg, .b = p.rm, .bytes = "" },
                0x2E => .{ .f = .ucomisd, .a = p.reg, .b = p.rm, .bytes = "" },
                0x6E => .{ .f = .movq_xr, .a = p.reg, .b = p.rm, .bytes = "" },
                0x7E => .{ .f = .movq_rx, .a = p.rm, .b = p.reg, .bytes = "" },
                else => null,
            },
            else => switch (o) {
                0xAF => if (mem(p)) .{ .f = .imul_rm64, .a = p.reg, .b = p.rm, .d = p.disp, .bytes = "" } else .{ .f = .imul_rr64, .a = p.reg, .b = p.rm, .bytes = "" },
                0xB6 => if (mem(p)) .{ .f = .movzx_rm8, .a = p.reg, .b = p.rm, .d = p.disp, .bytes = "" } else .{ .f = .movzx_rr8, .a = p.reg, .b = p.rm, .bytes = "" },
                0x90...0x9F => .{ .f = .setcc, .a = p.rm, .k = o - 0x90, .bytes = "" },
                else => null,
            },
        };
    }
    if (p.prefix != 0) return null;
    switch (o) {
        0x50...0x57 => return .{ .f = .push, .a = (o - 0x50) | p.b << 3, .bytes = "" },
        0x58...0x5F => return .{ .f = .pop, .a = (o - 0x58) | p.b << 3, .bytes = "" },
        0xB8...0xBF => return .{ .f = .mov_ri32, .a = (o - 0xB8) | p.b << 3, .i = imm32(code, p) orelse return null, .bytes = "" },
        0xC3 => return .{ .f = .ret, .bytes = "" },
        0xCC => return .{ .f = .int3, .bytes = "" },
        0x90 => return .{ .f = .nop, .bytes = "" },
        0x99 => return .{ .f = .cqo, .bytes = "" },
        0xE9 => {
            _ = imm32(code, p) orelse return null;
            return .{ .f = .jmp_rel32, .bytes = "" };
        },
        0x05, 0x0D, 0x25, 0x2D, 0x35, 0x3D => return .{ .f = if (p.w) .alu_ri64 else .alu_ri32, .k = o >> 3, .i = imm32(code, p) orelse return null, .bytes = "" },
        else => {},
    }
    if (!readModrm(code, p)) return null;
    const m = mem(p);
    const ext: u8 = p.reg & 7;
    return switch (o) {
        0x89 => if (m) .{ .f = if (p.w) .mov_mr64 else .mov_mr32, .a = p.rm, .b = p.reg, .d = p.disp, .bytes = "" } else .{ .f = if (p.w) .mov_rr64 else .mov_rr32, .a = p.rm, .b = p.reg, .bytes = "" },
        0x8B => if (m) .{ .f = if (p.w) .mov_rm64 else .mov_rm32, .a = p.reg, .b = p.rm, .d = p.disp, .bytes = "" } else null,
        0x88 => if (m) .{ .f = .mov_mr8, .a = p.rm, .b = p.reg, .d = p.disp, .bytes = "" } else null,
        0x63 => if (m) .{ .f = .movsxd_rm, .a = p.reg, .b = p.rm, .d = p.disp, .bytes = "" } else null,
        0x8D => if (m) .{ .f = .lea, .a = p.reg, .b = p.rm, .d = p.disp, .bytes = "" } else null,
        0xC7 => if (m and ext == 0) .{ .f = if (p.w) .mov_mi64 else .mov_mi32, .a = p.rm, .d = p.disp, .i = imm32(code, p) orelse return null, .bytes = "" } else null,
        0xC6 => if (m and ext == 0) .{ .f = .mov_mi8, .a = p.rm, .d = p.disp, .i = imm8(code, p) orelse return null, .bytes = "" } else null,
        0x01, 0x09, 0x21, 0x29, 0x31, 0x39 => if (!m) .{ .f = .alu_rr64, .a = p.rm, .b = p.reg, .k = o >> 3, .bytes = "" } else null,
        0x03, 0x0B, 0x23, 0x2B, 0x33, 0x3B => if (m) .{ .f = if (p.w) .alu_rm64 else .alu_rm32, .a = p.reg, .b = p.rm, .d = p.disp, .k = o >> 3, .bytes = "" } else null,
        0x83, 0x81 => blk: {
            const v = (if (o == 0x83) imm8(code, p) else imm32(code, p)) orelse return null;
            if (m) break :blk .{ .f = if (p.w) .alu_mi64 else .alu_mi32, .a = p.rm, .d = p.disp, .k = ext, .i = v, .bytes = "" };
            break :blk .{ .f = if (p.w) .alu_ri64 else .alu_ri32, .a = p.rm, .k = ext, .i = v, .bytes = "" };
        },
        0x80 => if (m and ext == 7) .{ .f = .cmp_mi8, .a = p.rm, .d = p.disp, .i = imm8(code, p) orelse return null, .bytes = "" } else null,
        0x85 => if (!m) .{ .f = .test_rr32, .a = p.rm, .b = p.reg, .bytes = "" } else null,
        0xF6 => if (m and ext == 0) .{ .f = .test_mi8, .a = p.rm, .d = p.disp, .i = imm8(code, p) orelse return null, .bytes = "" } else null,
        0xF7 => if (m) null else switch (ext) {
            3 => .{ .f = .neg_r64, .a = p.rm, .bytes = "" },
            7 => .{ .f = .idiv_r64, .a = p.rm, .bytes = "" },
            else => null,
        },
        0xFF => switch (ext) {
            0 => if (m) .{ .f = .inc_m64, .a = p.rm, .d = p.disp, .bytes = "" } else null,
            1 => if (m) .{ .f = .dec_m64, .a = p.rm, .d = p.disp, .bytes = "" } else null,
            2 => if (m) .{ .f = .call_m, .a = p.rm, .d = p.disp, .bytes = "" } else .{ .f = .call_r64, .a = p.rm, .bytes = "" },
            4 => if (m) .{ .f = .jmp_m, .a = p.rm, .d = p.disp, .bytes = "" } else .{ .f = .jmp_r64, .a = p.rm, .bytes = "" },
            else => null,
        },
        else => null,
    };
}

/// The length of the operand of a branch form.
fn relLen(f: Form) usize {
    return if (f == .jcc or f == .jmp_rel32) 4 else 0;
}

/// Decodes the instruction at `code[at..]`.
pub fn decode(scratch: Allocator, code: []const u8, at: usize) Ins {
    const rest = code[at..];
    var p: Parts = .{};
    const row = guess(rest, &p) orelse return .{ .len = 1 };
    const n = p.at;
    // The check: the assembler makes the same bytes from the row. A
    // branch of a row goes to the next instruction, so its offset is 0.
    var s = x64.Asm.init(scratch);
    defer s.deinit();
    s.reserveFor(1, 2) catch return .{ .len = 1 };
    x64.encodeRow(&s, row) catch return .{ .len = 1 };
    const want = s.bytes();
    const rl = relLen(row.f);
    if (want.len != n or !std.mem.eql(u8, want[0 .. n - rl], rest[0 .. n - rl])) return .{ .len = 1 };
    var out: Ins = .{ .len = @intCast(n), .row = row };
    if (rl != 0) out.target = @as(i64, @intCast(at + n)) + std.mem.readInt(i32, rest[n - 4 ..][0..4], .little);
    return out;
}

const regs64 = [_][]const u8{ "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };
const regs32 = [_][]const u8{ "eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d" };
const regs8 = [_][]const u8{ "al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil", "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b" };
const conds = [_][]const u8{ "o", "no", "b", "ae", "e", "ne", "be", "a", "s", "ns", "p", "np", "l", "ge", "le", "g" };
const alus = [_][]const u8{ "add", "or", "?", "?", "and", "sub", "xor", "cmp" };

fn r64(v: u8) []const u8 {
    return regs64[v & 15];
}

fn memText(a: Allocator, size: []const u8, base: u8, d: i32) ![]const u8 {
    if (d == 0) return std.fmt.allocPrint(a, "{s}[{s}]", .{ size, r64(base) });
    const sign: u8 = if (d < 0) '-' else '+';
    return std.fmt.allocPrint(a, "{s}[{s}{c}0x{x}]", .{ size, r64(base), sign, @abs(d) });
}

/// The text of one instruction, with a note for a call of a helper.
pub fn text(a: Allocator, ins: Ins, code: []const u8, at: usize) ![]const u8 {
    const row = ins.row orelse return std.fmt.allocPrint(a, ".byte 0x{x:0>2}", .{code[at]});
    const ra = row.a & 15;
    const rb = row.b & 15;
    const tgt = ins.target orelse 0;
    return switch (row.f) {
        .mov_rr64 => std.fmt.allocPrint(a, "mov {s}, {s}", .{ r64(ra), r64(rb) }),
        .mov_rr32 => std.fmt.allocPrint(a, "mov {s}, {s}", .{ regs32[ra], regs32[rb] }),
        .mov_rm64 => std.fmt.allocPrint(a, "mov {s}, {s}", .{ r64(ra), try memText(a, "", rb, row.d) }),
        .mov_mr64 => std.fmt.allocPrint(a, "mov {s}, {s}", .{ try memText(a, "", ra, row.d), r64(rb) }),
        .mov_rm32 => std.fmt.allocPrint(a, "mov {s}, {s}", .{ regs32[ra], try memText(a, "", rb, row.d) }),
        .mov_mr32 => std.fmt.allocPrint(a, "mov {s}, {s}", .{ try memText(a, "", ra, row.d), regs32[rb] }),
        .mov_mr8 => std.fmt.allocPrint(a, "mov {s}, {s}", .{ try memText(a, "", ra, row.d), regs8[rb] }),
        .movzx_rm8 => std.fmt.allocPrint(a, "movzx {s}, {s}", .{ regs32[ra], try memText(a, "byte ", rb, row.d) }),
        .movzx_rr8 => std.fmt.allocPrint(a, "movzx {s}, {s}", .{ regs32[ra], regs8[rb] }),
        .movsxd_rm => std.fmt.allocPrint(a, "movsxd {s}, {s}", .{ r64(ra), try memText(a, "dword ", rb, row.d) }),
        .mov_ri32 => std.fmt.allocPrint(a, "mov {s}, {d}", .{ regs32[ra], row.i }),
        .mov_mi64 => std.fmt.allocPrint(a, "mov {s}, {d}", .{ try memText(a, "qword ", ra, row.d), row.i }),
        .mov_mi32 => std.fmt.allocPrint(a, "mov {s}, {d}", .{ try memText(a, "dword ", ra, row.d), row.i }),
        .mov_mi8 => std.fmt.allocPrint(a, "mov {s}, {d}", .{ try memText(a, "byte ", ra, row.d), row.i }),
        .lea => std.fmt.allocPrint(a, "lea {s}, {s}", .{ r64(ra), try memText(a, "", rb, row.d) }),
        .alu_rr64 => std.fmt.allocPrint(a, "{s} {s}, {s}", .{ alus[row.k & 7], r64(ra), r64(rb) }),
        .alu_rm64 => std.fmt.allocPrint(a, "{s} {s}, {s}", .{ alus[row.k & 7], r64(ra), try memText(a, "", rb, row.d) }),
        .alu_rm32 => std.fmt.allocPrint(a, "{s} {s}, {s}", .{ alus[row.k & 7], regs32[ra], try memText(a, "", rb, row.d) }),
        .alu_ri64 => std.fmt.allocPrint(a, "{s} {s}, {d}", .{ alus[row.k & 7], r64(ra), row.i }),
        .alu_ri32, .and_ri32 => std.fmt.allocPrint(a, "{s} {s}, {d}", .{ if (row.f == .and_ri32) "and" else alus[row.k & 7], regs32[ra], row.i }),
        .alu_mi64 => std.fmt.allocPrint(a, "{s} {s}, {d}", .{ alus[row.k & 7], try memText(a, "qword ", ra, row.d), row.i }),
        .alu_mi32 => std.fmt.allocPrint(a, "{s} {s}, {d}", .{ alus[row.k & 7], try memText(a, "dword ", ra, row.d), row.i }),
        .cmp_mi8 => std.fmt.allocPrint(a, "cmp {s}, {d}", .{ try memText(a, "byte ", ra, row.d), row.i }),
        .test_rr32 => std.fmt.allocPrint(a, "test {s}, {s}", .{ regs32[ra], regs32[rb] }),
        .test_mi8 => std.fmt.allocPrint(a, "test {s}, {d}", .{ try memText(a, "byte ", ra, row.d), row.i }),
        .imul_rr64 => std.fmt.allocPrint(a, "imul {s}, {s}", .{ r64(ra), r64(rb) }),
        .imul_rm64 => std.fmt.allocPrint(a, "imul {s}, {s}", .{ r64(ra), try memText(a, "", rb, row.d) }),
        .inc_m64 => std.fmt.allocPrint(a, "inc {s}", .{try memText(a, "qword ", ra, row.d)}),
        .dec_m64 => std.fmt.allocPrint(a, "dec {s}", .{try memText(a, "qword ", ra, row.d)}),
        .neg_r64 => std.fmt.allocPrint(a, "neg {s}", .{r64(ra)}),
        .cqo => a.dupe(u8, "cqo"),
        .idiv_r64 => std.fmt.allocPrint(a, "idiv {s}", .{r64(ra)}),
        .setcc => std.fmt.allocPrint(a, "set{s} {s}", .{ conds[row.k & 15], regs8[ra] }),
        .jcc => std.fmt.allocPrint(a, "j{s} 0x{x}", .{ conds[row.k & 15], tgt }),
        .jmp_rel32 => std.fmt.allocPrint(a, "jmp 0x{x}", .{tgt}),
        .jmp_r64 => std.fmt.allocPrint(a, "jmp {s}", .{r64(ra)}),
        .jmp_m => std.fmt.allocPrint(a, "jmp {s}", .{try memText(a, "qword ", ra, row.d)}),
        .call_m => blk: {
            const m = try memText(a, "qword ", ra, row.d);
            // A call through the helper table names the helper.
            if (ra == @backingInt(abi.helpers) and row.d >= 0 and @rem(row.d, 8) == 0 and @divExact(row.d, 8) < helpers.count) {
                const h: helpers.Helper = @fromBackingInt(@intCast(@divExact(row.d, 8)));
                break :blk std.fmt.allocPrint(a, "call {s}  ; {s}", .{ m, @tagName(h) });
            }
            break :blk std.fmt.allocPrint(a, "call {s}", .{m});
        },
        .call_r64 => std.fmt.allocPrint(a, "call {s}", .{r64(ra)}),
        .ret => a.dupe(u8, "ret"),
        .push => std.fmt.allocPrint(a, "push {s}", .{r64(ra)}),
        .pop => std.fmt.allocPrint(a, "pop {s}", .{r64(ra)}),
        .int3 => a.dupe(u8, "int3"),
        .ud2 => a.dupe(u8, "ud2"),
        .nop => a.dupe(u8, "nop"),
        .movsd_xm => std.fmt.allocPrint(a, "movsd xmm{d}, {s}", .{ ra, try memText(a, "", rb, row.d) }),
        .movsd_mx => std.fmt.allocPrint(a, "movsd {s}, xmm{d}", .{ try memText(a, "", ra, row.d), rb }),
        .movapd => std.fmt.allocPrint(a, "movapd xmm{d}, xmm{d}", .{ ra, rb }),
        .sse => std.fmt.allocPrint(a, "{s} xmm{d}, xmm{d}", .{ switch (row.k) {
            0x58 => "addsd",
            0x59 => "mulsd",
            0x5C => "subsd",
            else => "divsd",
        }, ra, rb }),
        .ucomisd => std.fmt.allocPrint(a, "ucomisd xmm{d}, xmm{d}", .{ ra, rb }),
        .cvtsi2sd => std.fmt.allocPrint(a, "cvtsi2sd xmm{d}, {s}", .{ ra, r64(rb) }),
        .movq_xr => std.fmt.allocPrint(a, "movq xmm{d}, {s}", .{ ra, r64(rb) }),
        .movq_rx => std.fmt.allocPrint(a, "movq {s}, xmm{d}", .{ r64(ra), rb }),
    };
}

test "x64_dis: each row of the golden table decodes to its own bytes" {
    const golden = @import("x64_golden.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad: usize = 0;
    for (golden.rows) |row| {
        const ins = decode(std.testing.allocator, row.bytes, 0);
        if (ins.row == null or ins.len != row.bytes.len) {
            if (bad < 10) std.debug.print("x64_dis: {t} {x}\n", .{ row.f, row.bytes });
            bad += 1;
            continue;
        }
        _ = try text(a, ins, row.bytes, 0);
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

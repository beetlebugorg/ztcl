//! An assembler for the x86-64 instruction forms of the JIT.
//!
//! Each emit function appends the bytes of one instruction to a growable
//! buffer. A memory operand is a base register and a signed 32-bit
//! displacement, with no index register. The encoder picks the shortest
//! form that the assembler of `zig cc` picks: an 8-bit displacement or
//! immediate when the value fits, and the short form for `rax` in the
//! arithmetic group. `src/jit/x64_golden.zig` has the bytes of `zig cc`
//! for each form, and a unit test compares them.
//!
//! A branch is always `rel32`. A label has a list of fix-ups, and `bind`
//! writes each one. A branch to a bound label gets its offset at once.
//! An offset that does not fit in 32 bits sets an error flag, and
//! `finish` returns the error. `finish` also fails for a label that a
//! branch uses and that is not bound. A value never wraps: a caller
//! makes each displacement with `at`, which checks the range.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Reg = enum(u4) { rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi, r8, r9, r10, r11, r12, r13, r14, r15 };
pub const Xmm = enum(u4) { xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7, xmm8, xmm9, xmm10, xmm11, xmm12, xmm13, xmm14, xmm15 };

pub const Cond = enum(u4) { o, no, b, ae, e, ne, be, a, s, ns, p, np, l, ge, le, g };

/// The operation numbers of the arithmetic group.
pub const Alu = enum(u3) { add = 0, @"or" = 1, @"and" = 4, sub = 5, xor = 6, cmp = 7 };

/// `[base + disp]`.
pub const Mem = struct { base: Reg, disp: i32 = 0 };

/// A memory operand with a checked displacement.
pub fn at(base: Reg, off: i64) error{Range}!Mem {
    return .{ .base = base, .disp = std.math.cast(i32, off) orelse return error.Range };
}

/// A checked 32-bit immediate.
pub fn imm32(v: i64) error{Range}!i32 {
    return std.math.cast(i32, v) orelse return error.Range;
}

pub const Label = struct { id: u32 };

const none = std.math.maxInt(u32);

const Fixup = struct {
    /// The offset of the 32-bit field.
    at: u32,
    next: u32,
};

const LabelState = struct {
    pos: u32 = none,
    first: u32 = none,
    used: bool = false,
};

fn lo(r: anytype) u8 {
    return @as(u8, @intFromEnum(r)) & 7;
}

fn hi(r: anytype) bool {
    return @intFromEnum(r) >= 8;
}

fn fits8(v: i64) bool {
    return v >= -128 and v <= 127;
}

/// The fields of an instruction that hold 8-bit registers.
const Bytes = enum { none, rm, both };

/// The operand of the r/m field: a register number or a memory operand.
const Rm = union(enum) { reg: u4, mem: Mem };

pub const Asm = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,
    labels: std.ArrayList(LabelState) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    /// True after a branch offset did not fit in 32 bits.
    bad: bool = false,

    pub fn init(a: Allocator) Asm {
        return .{ .a = a };
    }

    pub fn deinit(s: *Asm) void {
        s.buf.deinit(s.a);
        s.labels.deinit(s.a);
        s.fixups.deinit(s.a);
    }

    pub fn here(s: *const Asm) u32 {
        return @intCast(s.buf.items.len);
    }

    pub fn bytes(s: *const Asm) []const u8 {
        return s.buf.items;
    }

    // ---- Labels ----

    pub fn newLabel(s: *Asm) Allocator.Error!Label {
        try s.labels.append(s.a, .{});
        return .{ .id = @intCast(s.labels.items.len - 1) };
    }

    /// Binds `l` to the current address and writes each of its fix-ups.
    pub fn bind(s: *Asm, l: Label) void {
        const st = &s.labels.items[l.id];
        std.debug.assert(st.pos == none);
        st.pos = s.here();
        var f = st.first;
        while (f != none) {
            const fx = s.fixups.items[f];
            s.patch(fx.at, st.pos);
            f = fx.next;
        }
        st.first = none;
    }

    pub fn isBound(s: *const Asm, l: Label) bool {
        return s.labels.items[l.id].pos != none;
    }

    pub fn labelPos(s: *const Asm, l: Label) u32 {
        return s.labels.items[l.id].pos;
    }

    fn patch(s: *Asm, field: u32, target: u32) void {
        const rel = @as(i64, target) - (@as(i64, field) + 4);
        const v = std.math.cast(i32, rel) orelse {
            s.bad = true;
            return;
        };
        std.mem.writeInt(i32, s.buf.items[field..][0..4], v, .little);
    }

    /// Appends a 32-bit branch field for `l`.
    fn rel32(s: *Asm, l: Label) Allocator.Error!void {
        const field = s.here();
        s.buf.appendNTimesAssumeCapacity(0, 4);
        const st = &s.labels.items[l.id];
        st.used = true;
        if (st.pos != none) return s.patch(field, st.pos);
        try s.fixups.append(s.a, .{ .at = field, .next = st.first });
        st.first = @intCast(s.fixups.items.len - 1);
    }

    /// Fails for a label that a branch uses and that is not bound, and
    /// for a branch offset that does not fit.
    pub fn finish(s: *const Asm) error{ UnboundLabel, Range }!void {
        for (s.labels.items) |l| {
            if (l.used and l.pos == none) return error.UnboundLabel;
        }
        if (s.bad) return error.Range;
    }

    // ---- Encoding ----

    /// The most bytes of one instruction with its immediate.
    const max_len = 24;

    /// Makes room for one instruction. Each public emit function calls
    /// it first, so the parts of the encoding append with no check.
    fn reserve(s: *Asm) Allocator.Error!void {
        try s.buf.ensureUnusedCapacity(s.a, max_len);
    }

    /// Makes room for the code of `n` bytecode instructions at once.
    pub fn reserveFor(s: *Asm, n: usize, labels: usize) Allocator.Error!void {
        try s.buf.ensureTotalCapacity(s.a, n * 64);
        try s.labels.ensureTotalCapacity(s.a, labels);
        try s.fixups.ensureTotalCapacity(s.a, labels);
    }

    fn byte(s: *Asm, b: u8) Allocator.Error!void {
        s.buf.appendAssumeCapacity(b);
    }

    fn put(s: *Asm, b: []const u8) Allocator.Error!void {
        s.buf.appendSliceAssumeCapacity(b);
    }

    fn i32le(s: *Asm, v: i32) Allocator.Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, v, .little);
        try s.put(&b);
    }

    /// The REX prefix, when one is needed. `byte_regs` names the fields
    /// that hold 8-bit registers: then `spl`, `bpl`, `sil`, and `dil`
    /// need a REX prefix.
    fn rex(s: *Asm, w: bool, reg: u4, rm: Rm, byte_regs: Bytes) Allocator.Error!void {
        var v: u8 = 0x40;
        if (w) v |= 8;
        if (reg >= 8) v |= 4;
        var force = byte_regs == .both and reg >= 4 and reg < 8;
        switch (rm) {
            .reg => |q| {
                if (q >= 8) v |= 1;
                if (byte_regs != .none and q >= 4 and q < 8) force = true;
            },
            .mem => |m| if (hi(m.base)) {
                v |= 1;
            },
        }
        if (v != 0x40 or force) try s.byte(v);
    }

    /// The ModRM byte, the SIB byte, and the displacement.
    fn modrm(s: *Asm, reg: u4, rm: Rm) Allocator.Error!void {
        const rr: u8 = @as(u8, reg) & 7;
        switch (rm) {
            .reg => |q| try s.byte(0xC0 | rr << 3 | (@as(u8, q) & 7)),
            .mem => |m| {
                const b = lo(m.base);
                const mode: u8 = if (m.disp == 0 and b != 5) 0 else if (fits8(m.disp)) 1 else 2;
                try s.byte(mode << 6 | rr << 3 | b);
                if (b == 4) try s.byte(0x24);
                switch (mode) {
                    1 => try s.byte(@bitCast(@as(i8, @intCast(m.disp)))),
                    2 => try s.i32le(m.disp),
                    else => {},
                }
            },
        }
    }

    /// One instruction with an optional legacy prefix, a REX prefix when
    /// needed, the opcode bytes, and the ModRM part.
    fn op(s: *Asm, prefix: ?u8, w: bool, opcode: []const u8, reg: u4, rm: Rm, byte_regs: Bytes) Allocator.Error!void {
        if (prefix) |p| try s.byte(p);
        try s.rex(w, reg, rm, byte_regs);
        try s.put(opcode);
        try s.modrm(reg, rm);
    }

    fn rmR(v: Reg) Rm {
        return .{ .reg = @intFromEnum(v) };
    }

    fn rmM(v: Mem) Rm {
        return .{ .mem = v };
    }

    fn num(v: anytype) u4 {
        return @intFromEnum(v);
    }

    // ---- Moves ----

    pub fn movRR(s: *Asm, dst: Reg, src: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{0x89}, num(src), rmR(dst), .none);
    }
    pub fn movRR32(s: *Asm, dst: Reg, src: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{0x89}, num(src), rmR(dst), .none);
    }
    pub fn movRM(s: *Asm, dst: Reg, src: Mem) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{0x8B}, num(dst), rmM(src), .none);
    }
    pub fn movMR(s: *Asm, dst: Mem, src: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{0x89}, num(src), rmM(dst), .none);
    }
    pub fn movRM32(s: *Asm, dst: Reg, src: Mem) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{0x8B}, num(dst), rmM(src), .none);
    }
    pub fn movMR32(s: *Asm, dst: Mem, src: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{0x89}, num(src), rmM(dst), .none);
    }
    pub fn movMR8(s: *Asm, dst: Mem, src: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{0x88}, num(src), rmM(dst), .both);
    }
    pub fn movzxRM8(s: *Asm, dst: Reg, src: Mem) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{ 0x0F, 0xB6 }, num(dst), rmM(src), .none);
    }
    pub fn movzxRR8(s: *Asm, dst: Reg, src: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{ 0x0F, 0xB6 }, num(dst), rmR(src), .rm);
    }
    /// `movsxd r64, dword m`: a signed 32-bit load.
    pub fn movsxdRM(s: *Asm, dst: Reg, src: Mem) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{0x63}, num(dst), rmM(src), .none);
    }
    pub fn movRI32(s: *Asm, dst: Reg, v: i32) Allocator.Error!void {
        try s.reserve();
        if (hi(dst)) try s.byte(0x41);
        try s.byte(0xB8 + lo(dst));
        try s.i32le(v);
    }
    pub fn movMI(s: *Asm, dst: Mem, v: i32) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{0xC7}, 0, rmM(dst), .none);
        try s.i32le(v);
    }
    pub fn movMI32(s: *Asm, dst: Mem, v: i32) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{0xC7}, 0, rmM(dst), .none);
        try s.i32le(v);
    }
    pub fn movMI8(s: *Asm, dst: Mem, v: i8) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{0xC6}, 0, rmM(dst), .none);
        try s.byte(@bitCast(v));
    }
    pub fn lea(s: *Asm, dst: Reg, src: Mem) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{0x8D}, num(dst), rmM(src), .none);
    }

    // ---- Arithmetic ----

    pub fn aluRR(s: *Asm, o: Alu, dst: Reg, src: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{@as(u8, @intFromEnum(o)) << 3 | 1}, num(src), rmR(dst), .none);
    }
    pub fn aluRM(s: *Asm, o: Alu, dst: Reg, src: Mem) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{@as(u8, @intFromEnum(o)) << 3 | 3}, num(dst), rmM(src), .none);
    }
    pub fn aluRM32(s: *Asm, o: Alu, dst: Reg, src: Mem) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{@as(u8, @intFromEnum(o)) << 3 | 3}, num(dst), rmM(src), .none);
    }
    fn aluImm(s: *Asm, o: Alu, w: bool, dst: Rm, v: i32) Allocator.Error!void {
        const k: u4 = @intFromEnum(o);
        if (fits8(v)) {
            try s.op(null, w, &.{0x83}, k, dst, .none);
            try s.byte(@bitCast(@as(i8, @intCast(v))));
        } else if (dst == .reg and dst.reg == 0) {
            if (w) try s.byte(0x48);
            try s.byte(@as(u8, k) << 3 | 5);
            try s.i32le(v);
        } else {
            try s.op(null, w, &.{0x81}, k, dst, .none);
            try s.i32le(v);
        }
    }
    pub fn aluRI(s: *Asm, o: Alu, dst: Reg, v: i32) Allocator.Error!void {
        try s.reserve();
        try s.aluImm(o, true, rmR(dst), v);
    }
    pub fn aluMI(s: *Asm, o: Alu, dst: Mem, v: i32) Allocator.Error!void {
        try s.reserve();
        try s.aluImm(o, true, rmM(dst), v);
    }
    pub fn aluMI32(s: *Asm, o: Alu, dst: Mem, v: i32) Allocator.Error!void {
        try s.reserve();
        try s.aluImm(o, false, rmM(dst), v);
    }
    pub fn andRI32(s: *Asm, dst: Reg, v: i32) Allocator.Error!void {
        try s.reserve();
        try s.aluImm(.@"and", false, rmR(dst), v);
    }
    pub fn cmpMI8(s: *Asm, dst: Mem, v: i8) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{0x80}, 7, rmM(dst), .none);
        try s.byte(@bitCast(v));
    }
    pub fn testRR32(s: *Asm, a: Reg, b: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{0x85}, num(b), rmR(a), .none);
    }
    pub fn testMI8(s: *Asm, dst: Mem, v: i8) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{0xF6}, 0, rmM(dst), .none);
        try s.byte(@bitCast(v));
    }
    pub fn imulRR(s: *Asm, dst: Reg, src: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{ 0x0F, 0xAF }, num(dst), rmR(src), .none);
    }
    pub fn imulRM(s: *Asm, dst: Reg, src: Mem) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{ 0x0F, 0xAF }, num(dst), rmM(src), .none);
    }
    pub fn incM(s: *Asm, dst: Mem) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{0xFF}, 0, rmM(dst), .none);
    }
    pub fn decM(s: *Asm, dst: Mem) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{0xFF}, 1, rmM(dst), .none);
    }
    pub fn neg(s: *Asm, dst: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{0xF7}, 3, rmR(dst), .none);
    }
    pub fn cqo(s: *Asm) Allocator.Error!void {
        try s.reserve();
        try s.put(&.{ 0x48, 0x99 });
    }
    pub fn idiv(s: *Asm, src: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, true, &.{0xF7}, 7, rmR(src), .none);
    }

    // ---- Flags and control ----

    pub fn setcc(s: *Asm, c: Cond, dst: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{ 0x0F, 0x90 + @as(u8, @intFromEnum(c)) }, 0, rmR(dst), .rm);
    }
    pub fn jcc(s: *Asm, c: Cond, l: Label) Allocator.Error!void {
        try s.reserve();
        try s.put(&.{ 0x0F, 0x80 + @as(u8, @intFromEnum(c)) });
        try s.rel32(l);
    }
    pub fn jmp(s: *Asm, l: Label) Allocator.Error!void {
        try s.reserve();
        try s.byte(0xE9);
        try s.rel32(l);
    }
    pub fn jmpR(s: *Asm, dst: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{0xFF}, 4, rmR(dst), .none);
    }
    pub fn jmpM(s: *Asm, dst: Mem) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{0xFF}, 4, rmM(dst), .none);
    }
    pub fn callM(s: *Asm, dst: Mem) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{0xFF}, 2, rmM(dst), .none);
    }
    pub fn callR(s: *Asm, dst: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(null, false, &.{0xFF}, 2, rmR(dst), .none);
    }
    pub fn ret(s: *Asm) Allocator.Error!void {
        try s.reserve();
        try s.byte(0xC3);
    }
    pub fn push(s: *Asm, v: Reg) Allocator.Error!void {
        try s.reserve();
        if (hi(v)) try s.byte(0x41);
        try s.byte(0x50 + lo(v));
    }
    pub fn pop(s: *Asm, v: Reg) Allocator.Error!void {
        try s.reserve();
        if (hi(v)) try s.byte(0x41);
        try s.byte(0x58 + lo(v));
    }
    pub fn int3(s: *Asm) Allocator.Error!void {
        try s.reserve();
        try s.byte(0xCC);
    }
    pub fn ud2(s: *Asm) Allocator.Error!void {
        try s.reserve();
        try s.put(&.{ 0x0F, 0x0B });
    }
    pub fn nop(s: *Asm) Allocator.Error!void {
        try s.reserve();
        try s.byte(0x90);
    }

    // ---- SSE2 ----

    fn rmX(v: Xmm) Rm {
        return .{ .reg = @intFromEnum(v) };
    }

    pub fn movsdXM(s: *Asm, dst: Xmm, src: Mem) Allocator.Error!void {
        try s.reserve();
        try s.op(0xF2, false, &.{ 0x0F, 0x10 }, num(dst), rmM(src), .none);
    }
    pub fn movsdMX(s: *Asm, dst: Mem, src: Xmm) Allocator.Error!void {
        try s.reserve();
        try s.op(0xF2, false, &.{ 0x0F, 0x11 }, num(src), rmM(dst), .none);
    }
    pub fn movapd(s: *Asm, dst: Xmm, src: Xmm) Allocator.Error!void {
        try s.reserve();
        try s.op(0x66, false, &.{ 0x0F, 0x28 }, num(dst), rmX(src), .none);
    }
    pub const Sse = enum(u8) { addsd = 0x58, mulsd = 0x59, subsd = 0x5C, divsd = 0x5E };
    pub fn sse(s: *Asm, o: Sse, dst: Xmm, src: Xmm) Allocator.Error!void {
        try s.reserve();
        try s.op(0xF2, false, &.{ 0x0F, @intFromEnum(o) }, num(dst), rmX(src), .none);
    }
    pub fn ucomisd(s: *Asm, a: Xmm, b: Xmm) Allocator.Error!void {
        try s.reserve();
        try s.op(0x66, false, &.{ 0x0F, 0x2E }, num(a), rmX(b), .none);
    }
    pub fn cvtsi2sd(s: *Asm, dst: Xmm, src: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(0xF2, true, &.{ 0x0F, 0x2A }, num(dst), rmR(src), .none);
    }
    pub fn movqXR(s: *Asm, dst: Xmm, src: Reg) Allocator.Error!void {
        try s.reserve();
        try s.op(0x66, true, &.{ 0x0F, 0x6E }, num(dst), rmR(src), .none);
    }
    pub fn movqRX(s: *Asm, dst: Reg, src: Xmm) Allocator.Error!void {
        try s.reserve();
        try s.op(0x66, true, &.{ 0x0F, 0x7E }, num(src), rmR(dst), .none);
    }
};

// ---- The forms of the golden table ----

/// Each instruction form of the golden table. The operands of a row are
/// `a` and `b` (register numbers), `d` (a displacement), `i` (an
/// immediate), and `c` (a condition).
pub const Form = enum {
    mov_rr64,
    mov_rr32,
    mov_rm64,
    mov_mr64,
    mov_rm32,
    mov_mr32,
    mov_mr8,
    movzx_rm8,
    movzx_rr8,
    movsxd_rm,
    mov_ri32,
    mov_mi64,
    mov_mi32,
    mov_mi8,
    lea,
    alu_rr64,
    alu_rm64,
    alu_ri64,
    alu_mi64,
    alu_mi32,
    alu_rm32,
    cmp_mi8,
    test_rr32,
    test_mi8,
    and_ri32,
    imul_rr64,
    imul_rm64,
    inc_m64,
    dec_m64,
    neg_r64,
    cqo,
    idiv_r64,
    setcc,
    jcc,
    jmp_rel32,
    jmp_r64,
    jmp_m,
    call_m,
    call_r64,
    ret,
    push,
    pop,
    int3,
    ud2,
    nop,
    movsd_xm,
    movsd_mx,
    movapd,
    sse,
    ucomisd,
    cvtsi2sd,
    movq_xr,
    movq_rx,
};

pub const Row = struct {
    f: Form,
    a: u8 = 0,
    b: u8 = 0,
    d: i32 = 0,
    i: i32 = 0,
    /// The ALU operation, the SSE operation, or the condition.
    k: u8 = 0,
    bytes: []const u8,
};

/// Encodes one row of the golden table. A branch row goes to the next
/// instruction, so its offset is zero.
pub fn encodeRow(s: *Asm, row: Row) Allocator.Error!void {
    const ra: Reg = @enumFromInt(@as(u4, @intCast(row.a)));
    const rb: Reg = @enumFromInt(@as(u4, @intCast(row.b)));
    const xa: Xmm = @enumFromInt(@as(u4, @intCast(row.a)));
    const xb: Xmm = @enumFromInt(@as(u4, @intCast(row.b)));
    const ma: Mem = .{ .base = ra, .disp = row.d };
    const mb: Mem = .{ .base = rb, .disp = row.d };
    switch (row.f) {
        .mov_rr64 => try s.movRR(ra, rb),
        .mov_rr32 => try s.movRR32(ra, rb),
        .mov_rm64 => try s.movRM(ra, mb),
        .mov_mr64 => try s.movMR(ma, rb),
        .mov_rm32 => try s.movRM32(ra, mb),
        .mov_mr32 => try s.movMR32(ma, rb),
        .mov_mr8 => try s.movMR8(ma, rb),
        .movzx_rm8 => try s.movzxRM8(ra, mb),
        .movzx_rr8 => try s.movzxRR8(ra, rb),
        .movsxd_rm => try s.movsxdRM(ra, mb),
        .mov_ri32 => try s.movRI32(ra, row.i),
        .mov_mi64 => try s.movMI(ma, row.i),
        .mov_mi32 => try s.movMI32(ma, row.i),
        .mov_mi8 => try s.movMI8(ma, @intCast(row.i)),
        .lea => try s.lea(ra, mb),
        .alu_rr64 => try s.aluRR(@as(Alu, @enumFromInt(@as(u3, @intCast(row.k)))), ra, rb),
        .alu_rm64 => try s.aluRM(@as(Alu, @enumFromInt(@as(u3, @intCast(row.k)))), ra, mb),
        .alu_ri64 => try s.aluRI(@as(Alu, @enumFromInt(@as(u3, @intCast(row.k)))), ra, row.i),
        .alu_mi64 => try s.aluMI(@as(Alu, @enumFromInt(@as(u3, @intCast(row.k)))), ma, row.i),
        .alu_mi32 => try s.aluMI32(@as(Alu, @enumFromInt(@as(u3, @intCast(row.k)))), ma, row.i),
        .alu_rm32 => try s.aluRM32(@as(Alu, @enumFromInt(@as(u3, @intCast(row.k)))), ra, mb),
        .cmp_mi8 => try s.cmpMI8(ma, @intCast(row.i)),
        .test_rr32 => try s.testRR32(ra, rb),
        .test_mi8 => try s.testMI8(ma, @intCast(row.i)),
        .and_ri32 => try s.andRI32(ra, row.i),
        .imul_rr64 => try s.imulRR(ra, rb),
        .imul_rm64 => try s.imulRM(ra, mb),
        .inc_m64 => try s.incM(ma),
        .dec_m64 => try s.decM(ma),
        .neg_r64 => try s.neg(ra),
        .cqo => try s.cqo(),
        .idiv_r64 => try s.idiv(ra),
        .setcc => try s.setcc(@enumFromInt(@as(u4, @intCast(row.k))), ra),
        .jcc, .jmp_rel32 => {
            const l = try s.newLabel();
            if (row.f == .jcc) try s.jcc(@enumFromInt(@as(u4, @intCast(row.k))), l) else try s.jmp(l);
            s.bind(l);
        },
        .jmp_r64 => try s.jmpR(ra),
        .jmp_m => try s.jmpM(ma),
        .call_m => try s.callM(ma),
        .call_r64 => try s.callR(ra),
        .ret => try s.ret(),
        .push => try s.push(ra),
        .pop => try s.pop(ra),
        .int3 => try s.int3(),
        .ud2 => try s.ud2(),
        .nop => try s.nop(),
        .movsd_xm => try s.movsdXM(xa, mb),
        .movsd_mx => try s.movsdMX(ma, xb),
        .movapd => try s.movapd(xa, xb),
        .sse => try s.sse(@enumFromInt(row.k), xa, xb),
        .ucomisd => try s.ucomisd(xa, xb),
        .cvtsi2sd => try s.cvtsi2sd(xa, rb),
        .movq_xr => try s.movqXR(xa, rb),
        .movq_rx => try s.movqRX(ra, xb),
    }
}

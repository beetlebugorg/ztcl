//! An assembler for the AArch64 instruction forms of the JIT.
//!
//! Each emit function appends one or more 32-bit instruction words to a
//! growable buffer. The primitive forms map one call to one word, and
//! `src/jit/a64_golden.zig` has the words of `zig cc` for each of them.
//! A unit test compares them. The helper forms (`load`, `store`,
//! `addImm`, `movImm`) pick a primitive form for an offset or a value,
//! and fall back to `movz` and `movk` into `x16` or `x17` with a register
//! offset form when no immediate form fits.
//!
//! The assembler never emits a use of `x18`, the platform register of
//! Apple and Windows. A call with `x18` returns `error.Reg`, and a call
//! with a value that does not fit its field returns `error.Range`. No
//! encoder wraps or truncates a value.
//!
//! A branch to a label has a fix-up of the field of its form: 26 bits
//! for `b`, and 19 bits for `b.cond`, `cbz`, and `cbnz`, which reach
//! 1 MiB. `bind` writes each fix-up, and a branch to a bound label gets
//! its offset at once. An offset that does not fit sets an error flag,
//! and `finish` returns `error.Range`. `finish` also fails for a label
//! that a branch uses and that is not bound.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Marks = @import("marks.zig").Marks;
const Allocator = std.mem.Allocator;

/// The general registers. `sp` and `zr` share the number 31 in the
/// encoding. Each form accepts only the one that it can encode.
pub const Reg = enum(u6) {
    x0,
    x1,
    x2,
    x3,
    x4,
    x5,
    x6,
    x7,
    x8,
    x9,
    x10,
    x11,
    x12,
    x13,
    x14,
    x15,
    x16,
    x17,
    x18,
    x19,
    x20,
    x21,
    x22,
    x23,
    x24,
    x25,
    x26,
    x27,
    x28,
    x29,
    x30,
    sp,
    zr,
};

/// The double registers.
pub const DReg = enum(u5) {
    d0,
    d1,
    d2,
    d3,
    d4,
    d5,
    d6,
    d7,
    d8,
    d9,
    d10,
    d11,
    d12,
    d13,
    d14,
    d15,
    d16,
    d17,
    d18,
    d19,
    d20,
    d21,
    d22,
    d23,
    d24,
    d25,
    d26,
    d27,
    d28,
    d29,
    d30,
    d31,
};

/// The 14 conditions of `b.cond` and `cset`.
pub const Cond = enum(u4) { eq, ne, hs, lo, mi, pl, vs, vc, hi, ls, ge, lt, gt, le };

pub fn invert(c: Cond) Cond {
    return @fromBackingInt(@intCast(@backingInt(c) ^ 1));
}

/// The shift of the second register of a data operation.
pub const Shift = enum(u2) { lsl = 0, lsr = 1, asr = 2 };

/// The operations of the register forms of the arithmetic and logic
/// groups. The value is the fixed part of the instruction word.
pub const Op = enum(u32) {
    add = 0x8B000000,
    adds = 0xAB000000,
    sub = 0xCB000000,
    subs = 0xEB000000,
    @"and" = 0x8A000000,
    orr = 0xAA000000,
    eor = 0xCA000000,
};

/// The operations of the double group: `fadd`, `fsub`, `fmul`, `fdiv`.
pub const FOp = enum(u32) { fmul = 0x1E600800, fdiv = 0x1E601800, fadd = 0x1E602800, fsub = 0x1E603800 };

/// The size of a load or a store: 8 bytes, 4 bytes, 1 byte, or a double.
pub const Size = enum { x, w, b, d };

pub const Error = Allocator.Error || error{ Range, Reg };

pub const Label = struct { id: u32 };

const none = std.math.maxInt(u32);

const Field = enum(u1) { imm26, imm19 };

const Fixup = struct {
    /// The offset of the instruction word.
    at: u32,
    field: Field,
    next: u32,
};

const LabelState = struct {
    pos: u32 = none,
    first: u32 = none,
    used: bool = false,
};

/// The number of a register in a field where 31 is the zero register.
fn gr(r: Reg) error{Reg}!u32 {
    return switch (r) {
        .x18, .sp => error.Reg,
        .zr => 31,
        else => @backingInt(r),
    };
}

/// The number of a register in a field where 31 is the stack pointer.
fn sr(r: Reg) error{Reg}!u32 {
    return switch (r) {
        .x18, .zr => error.Reg,
        .sp => 31,
        else => @backingInt(r),
    };
}

fn dr(r: DReg) u32 {
    return @backingInt(r);
}

/// A checked unsigned field.
fn ufield(v: i64, bits: u6) error{Range}!u32 {
    if (v < 0 or v >= (@as(i64, 1) << bits)) return error.Range;
    return @intCast(v);
}

/// A checked signed field, as its low `bits` bits.
fn sfield(v: i64, bits: u6) error{Range}!u32 {
    const half = @as(i64, 1) << (bits - 1);
    if (v < -half or v >= half) return error.Range;
    const mask = (@as(u64, 1) << bits) - 1;
    return @intCast(@as(u64, @bitCast(v)) & mask);
}

/// The scale of a size in bits: the shift of a scaled offset.
fn scaleOf(z: Size) u6 {
    return switch (z) {
        .x, .d => 3,
        .w => 2,
        .b => 0,
    };
}

/// The fixed parts of the load and store forms of each size.
const LsForm = struct { ldr: u32, str: u32, ldur: u32, stur: u32, ldr_r: u32, str_r: u32 };

fn lsForm(z: Size) LsForm {
    return switch (z) {
        .x => .{ .ldr = 0xF9400000, .str = 0xF9000000, .ldur = 0xF8400000, .stur = 0xF8000000, .ldr_r = 0xF8606800, .str_r = 0xF8206800 },
        .w => .{ .ldr = 0xB9400000, .str = 0xB9000000, .ldur = 0xB8400000, .stur = 0xB8000000, .ldr_r = 0xB8606800, .str_r = 0xB8206800 },
        .b => .{ .ldr = 0x39400000, .str = 0x39000000, .ldur = 0x38400000, .stur = 0x38000000, .ldr_r = 0x38606800, .str_r = 0x38206800 },
        .d => .{ .ldr = 0xFD400000, .str = 0xFD000000, .ldur = 0xFC400000, .stur = 0xFC000000, .ldr_r = 0xFC606800, .str_r = 0xFC206800 },
    };
}

/// The register field of a load or a store: a general or a double
/// register.
pub const Rt = union(enum) { r: Reg, d: DReg };

fn rt(t: Rt) error{Reg}!u32 {
    return switch (t) {
        .r => |r| gr(r),
        .d => |d| dr(d),
    };
}

/// The logic immediate of a mask of `k` low ones, 1 <= k <= 63:
/// N=1, immr=0, imms=k-1. Other masks return `error.Range`.
fn lowMask(mask: u64) error{Range}!u32 {
    if (mask == 0 or mask == std.math.maxInt(u64) or mask & (mask + 1) != 0) return error.Range;
    const k: u32 = @popCount(mask);
    return 1 << 22 | (k - 1) << 10;
}

pub const Asm = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,
    labels: std.ArrayList(LabelState) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    /// True after a branch offset did not fit its field.
    bad: bool = false,
    /// The marks of a listing (`marks.zig`), or null in a compile for a run.
    marks: ?*Marks = null,

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

    /// The code from here on belongs to the bytecode instruction `pc`.
    pub fn mark(s: *Asm, pc: u32) void {
        if (s.marks) |m| m.note(s.here(), pc);
    }

    pub fn bytes(s: *const Asm) []const u8 {
        return s.buf.items;
    }

    /// Makes room for the code of `n` bytecode instructions at once.
    pub fn reserveFor(s: *Asm, n: usize, labels: usize) Allocator.Error!void {
        try s.buf.ensureTotalCapacity(s.a, n * 96);
        try s.labels.ensureTotalCapacity(s.a, labels);
        try s.fixups.ensureTotalCapacity(s.a, labels);
    }

    fn word(s: *Asm, w: u32) Allocator.Error!void {
        var four: [4]u8 = undefined;
        std.mem.writeInt(u32, &four, w, .little);
        try s.buf.appendSlice(s.a, &four);
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
            s.patch(fx.at, fx.field, st.pos);
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

    /// Writes the offset of the branch at `at` to `target`, in words.
    fn patch(s: *Asm, at: u32, field: Field, target: u32) void {
        const rel = @divExact(@as(i64, target) - @as(i64, at), 4);
        const p = s.buf.items[at..][0..4];
        var w = std.mem.readInt(u32, p, .little);
        switch (field) {
            .imm26 => {
                const v = sfield(rel, 26) catch {
                    s.bad = true;
                    return;
                };
                w = (w & ~@as(u32, 0x03FFFFFF)) | v;
            },
            .imm19 => {
                const v = sfield(rel, 19) catch {
                    s.bad = true;
                    return;
                };
                w = (w & ~@as(u32, 0x7FFFF << 5)) | v << 5;
            },
        }
        std.mem.writeInt(u32, p, w, .little);
    }

    /// Appends the branch word `w` with a field for `l`.
    fn branchTo(s: *Asm, w: u32, field: Field, l: Label) Allocator.Error!void {
        const at = s.here();
        try s.word(w);
        const st = &s.labels.items[l.id];
        st.used = true;
        if (st.pos != none) return s.patch(at, field, st.pos);
        try s.fixups.append(s.a, .{ .at = at, .field = field, .next = st.first });
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

    // ---- Moves ----

    /// `mov xd, xn`. With `sp` in either place, `add xd, xn, #0`.
    pub fn movRR(s: *Asm, d: Reg, n: Reg) Error!void {
        if (d == .sp or n == .sp) return s.word(0x91000000 | try sr(n) << 5 | try sr(d));
        try s.word(0xAA0003E0 | try gr(n) << 16 | try gr(d));
    }

    /// `mov wd, wn`: the high half of `xd` becomes zero.
    pub fn movRR32(s: *Asm, d: Reg, n: Reg) Error!void {
        try s.word(0x2A0003E0 | try gr(n) << 16 | try gr(d));
    }

    fn movWide(s: *Asm, fixed: u32, d: Reg, imm: i64, shift: u6) Error!void {
        if (shift % 16 != 0 or shift > 48) return error.Range;
        try s.word(fixed | @as(u32, shift / 16) << 21 | try ufield(imm, 16) << 5 | try gr(d));
    }

    /// `movz xd, #imm, lsl #shift`.
    pub fn movz(s: *Asm, d: Reg, imm: i64, shift: u6) Error!void {
        try s.movWide(0xD2800000, d, imm, shift);
    }

    /// `movk xd, #imm, lsl #shift`.
    pub fn movk(s: *Asm, d: Reg, imm: i64, shift: u6) Error!void {
        try s.movWide(0xF2800000, d, imm, shift);
    }

    /// `movn xd, #imm, lsl #shift`.
    pub fn movn(s: *Asm, d: Reg, imm: i64, shift: u6) Error!void {
        try s.movWide(0x92800000, d, imm, shift);
    }

    /// `movz wd, #imm`.
    pub fn movzW(s: *Asm, d: Reg, imm: i64) Error!void {
        try s.word(0x52800000 | try ufield(imm, 16) << 5 | try gr(d));
    }

    /// Any 64-bit value into `d` with `movz` or `movn` and `movk`.
    pub fn movImm(s: *Asm, d: Reg, v: i64) Error!void {
        if (v == 0) return s.movz(d, 0, 0);
        const u: u64 = @bitCast(v);
        const neg = v < 0;
        // A negative value starts from all ones with movn.
        const base: u64 = if (neg) std.math.maxInt(u64) else 0;
        var first = true;
        var k: u6 = 0;
        while (true) : (k += 1) {
            const part: u16 = @truncate(u >> (16 * @as(u6, k)));
            const fill: u16 = @truncate(base);
            if (part != fill or (first and k == 3)) {
                if (first) {
                    if (neg) try s.movn(d, ~part, 16 * k) else try s.movz(d, part, 16 * k);
                    first = false;
                } else try s.movk(d, part, 16 * k);
            }
            if (k == 3) break;
        }
    }

    // ---- Loads and stores ----

    /// `ldr` with a scaled unsigned 12-bit offset.
    pub fn ldrU(s: *Asm, z: Size, t: Rt, n: Reg, off: i64) Error!void {
        try s.lsScaled(lsForm(z).ldr, z, t, n, off);
    }

    /// `str` with a scaled unsigned 12-bit offset.
    pub fn strU(s: *Asm, z: Size, t: Rt, n: Reg, off: i64) Error!void {
        try s.lsScaled(lsForm(z).str, z, t, n, off);
    }

    fn lsScaled(s: *Asm, fixed: u32, z: Size, t: Rt, n: Reg, off: i64) Error!void {
        const sh = scaleOf(z);
        if (off < 0 or @rem(off, @as(i64, 1) << sh) != 0) return error.Range;
        try s.word(fixed | try ufield(off >> sh, 12) << 10 | try sr(n) << 5 | try rt(t));
    }

    /// `ldur` with a signed 9-bit offset.
    pub fn ldur(s: *Asm, z: Size, t: Rt, n: Reg, off: i64) Error!void {
        try s.word(lsForm(z).ldur | try sfield(off, 9) << 12 | try sr(n) << 5 | try rt(t));
    }

    /// `stur` with a signed 9-bit offset.
    pub fn stur(s: *Asm, z: Size, t: Rt, n: Reg, off: i64) Error!void {
        try s.word(lsForm(z).stur | try sfield(off, 9) << 12 | try sr(n) << 5 | try rt(t));
    }

    /// `ldr t, [n, m]`: a register offset.
    pub fn ldrR(s: *Asm, z: Size, t: Rt, n: Reg, m: Reg) Error!void {
        try s.word(lsForm(z).ldr_r | try gr(m) << 16 | try sr(n) << 5 | try rt(t));
    }

    /// `str t, [n, m]`: a register offset.
    pub fn strR(s: *Asm, z: Size, t: Rt, n: Reg, m: Reg) Error!void {
        try s.word(lsForm(z).str_r | try gr(m) << 16 | try sr(n) << 5 | try rt(t));
    }

    /// The temporary of a large offset: `x16`, or `x17` when the base is
    /// `x16`.
    fn temp(n: Reg) Reg {
        return if (n == .x16) .x17 else .x16;
    }

    /// A load of `t` from `[n + off]` with the shortest form.
    pub fn load(s: *Asm, z: Size, t: Rt, n: Reg, off: i64) Error!void {
        if (s.ldrU(z, t, n, off)) |_| return else |e| if (e != error.Range) return e;
        if (s.ldur(z, t, n, off)) |_| return else |e| if (e != error.Range) return e;
        const tmp = temp(n);
        try s.movImm(tmp, off);
        try s.ldrR(z, t, n, tmp);
    }

    /// A store of `t` to `[n + off]` with the shortest form.
    pub fn store(s: *Asm, z: Size, t: Rt, n: Reg, off: i64) Error!void {
        if (s.strU(z, t, n, off)) |_| return else |e| if (e != error.Range) return e;
        if (s.stur(z, t, n, off)) |_| return else |e| if (e != error.Range) return e;
        const tmp = temp(n);
        if (t == .r and t.r == tmp) return error.Reg;
        try s.movImm(tmp, off);
        try s.strR(z, t, n, tmp);
    }

    /// The pair forms of `x` registers. `mode`: 1 post-index, 2 offset,
    /// 3 pre-index.
    fn pair(s: *Asm, load_bit: u32, mode: u32, t1: Reg, t2: Reg, n: Reg, off: i64) Error!void {
        if (@rem(off, 8) != 0) return error.Range;
        try s.word(0xA8000000 | mode << 23 | load_bit << 22 | try sfield(@divExact(off, 8), 7) << 15 | try gr(t2) << 10 | try sr(n) << 5 | try gr(t1));
    }

    pub fn stpPre(s: *Asm, t1: Reg, t2: Reg, n: Reg, off: i64) Error!void {
        try s.pair(0, 3, t1, t2, n, off);
    }

    pub fn stpPost(s: *Asm, t1: Reg, t2: Reg, n: Reg, off: i64) Error!void {
        try s.pair(0, 1, t1, t2, n, off);
    }

    pub fn stpOff(s: *Asm, t1: Reg, t2: Reg, n: Reg, off: i64) Error!void {
        try s.pair(0, 2, t1, t2, n, off);
    }

    pub fn ldpPre(s: *Asm, t1: Reg, t2: Reg, n: Reg, off: i64) Error!void {
        try s.pair(1, 3, t1, t2, n, off);
    }

    pub fn ldpPost(s: *Asm, t1: Reg, t2: Reg, n: Reg, off: i64) Error!void {
        try s.pair(1, 1, t1, t2, n, off);
    }

    pub fn ldpOff(s: *Asm, t1: Reg, t2: Reg, n: Reg, off: i64) Error!void {
        try s.pair(1, 2, t1, t2, n, off);
    }

    // ---- Arithmetic ----

    /// The add and sub forms with an immediate. `fixed` has the
    /// operation and the flag bit. `d` is `zr` for a compare.
    fn arithImm(s: *Asm, fixed: u32, d: Reg, n: Reg, imm: i64, shift12: bool, flags: bool) Error!void {
        const rd = if (flags) try gr(d) else try sr(d);
        try s.word(fixed | @as(u32, @intFromBool(shift12)) << 22 | try ufield(imm, 12) << 10 | try sr(n) << 5 | rd);
    }

    pub fn addI(s: *Asm, d: Reg, n: Reg, imm: i64, shift12: bool) Error!void {
        try s.arithImm(0x91000000, d, n, imm, shift12, false);
    }

    pub fn subI(s: *Asm, d: Reg, n: Reg, imm: i64, shift12: bool) Error!void {
        try s.arithImm(0xD1000000, d, n, imm, shift12, false);
    }

    pub fn addsI(s: *Asm, d: Reg, n: Reg, imm: i64, shift12: bool) Error!void {
        try s.arithImm(0xB1000000, d, n, imm, shift12, true);
    }

    pub fn subsI(s: *Asm, d: Reg, n: Reg, imm: i64, shift12: bool) Error!void {
        try s.arithImm(0xF1000000, d, n, imm, shift12, true);
    }

    /// `cmp xn, #imm`.
    pub fn cmpI(s: *Asm, n: Reg, imm: i64) Error!void {
        try s.subsI(.zr, n, imm, false);
    }

    /// `cmp wn, #imm`.
    pub fn cmpWI(s: *Asm, n: Reg, imm: i64) Error!void {
        try s.word(0x7100001F | try ufield(imm, 12) << 10 | try sr(n) << 5);
    }

    /// `cmp wn, wm`.
    pub fn cmpWR(s: *Asm, n: Reg, m: Reg) Error!void {
        try s.word(0x6B00001F | try gr(m) << 16 | try gr(n) << 5);
    }

    /// `d = n + v` for any `v`: `add` or `sub` with an immediate, with a
    /// shift of 12 when the low bits are zero, or `x16` (`x17`) and a
    /// register `add`.
    pub fn addImm(s: *Asm, d: Reg, n: Reg, v: i64) Error!void {
        const mag = if (v < 0) -%v else v;
        if (mag >= 0 and mag < 4096) return if (v < 0) s.subI(d, n, mag, false) else s.addI(d, n, mag, false);
        if (mag >= 0 and mag & 0xFFF == 0 and mag >> 12 < 4096) return if (v < 0) s.subI(d, n, mag >> 12, true) else s.addI(d, n, mag >> 12, true);
        const tmp = temp(n);
        if (d == tmp) return error.Reg;
        try s.movImm(tmp, v);
        try s.opR(.add, d, n, tmp, .lsl, 0);
    }

    /// A register form of `op` with a shift of the second register.
    pub fn opR(s: *Asm, op: Op, d: Reg, n: Reg, m: Reg, sh: Shift, amount: i64) Error!void {
        try s.word(@backingInt(op) | @as(u32, @backingInt(sh)) << 22 | try gr(m) << 16 | try ufield(amount, 6) << 10 | try gr(n) << 5 | try gr(d));
    }

    /// `cmp xn, xm` with a shift of `xm`.
    pub fn cmpR(s: *Asm, n: Reg, m: Reg, sh: Shift, amount: i64) Error!void {
        try s.opR(.subs, .zr, n, m, sh, amount);
    }

    /// `and xd, xn, #mask` for a mask of low ones.
    pub fn andI(s: *Asm, d: Reg, n: Reg, mask: u64) Error!void {
        try s.word(0x92000000 | try lowMask(mask) | try gr(n) << 5 | try sr(d));
    }

    /// `tst xn, #mask` for a mask of low ones.
    pub fn tstI(s: *Asm, n: Reg, mask: u64) Error!void {
        try s.word(0xF200001F | try lowMask(mask) | try gr(n) << 5);
    }

    pub fn mul(s: *Asm, d: Reg, n: Reg, m: Reg) Error!void {
        try s.word(0x9B007C00 | try gr(m) << 16 | try gr(n) << 5 | try gr(d));
    }

    pub fn smulh(s: *Asm, d: Reg, n: Reg, m: Reg) Error!void {
        try s.word(0x9B407C00 | try gr(m) << 16 | try gr(n) << 5 | try gr(d));
    }

    pub fn sdiv(s: *Asm, d: Reg, n: Reg, m: Reg) Error!void {
        try s.word(0x9AC00C00 | try gr(m) << 16 | try gr(n) << 5 | try gr(d));
    }

    /// `msub xd, xn, xm, xa`: `d = a - n * m`.
    pub fn msub(s: *Asm, d: Reg, n: Reg, m: Reg, a: Reg) Error!void {
        try s.word(0x9B008000 | try gr(m) << 16 | try gr(a) << 10 | try gr(n) << 5 | try gr(d));
    }

    /// `asr xd, xn, #sh`.
    pub fn asrI(s: *Asm, d: Reg, n: Reg, sh: i64) Error!void {
        try s.word(0x9340FC00 | try ufield(sh, 6) << 16 | try gr(n) << 5 | try gr(d));
    }

    /// `lsl xd, xn, #sh`, 1 <= sh <= 63.
    pub fn lslI(s: *Asm, d: Reg, n: Reg, sh: i64) Error!void {
        if (sh < 1 or sh > 63) return error.Range;
        const immr: u32 = @intCast(64 - sh);
        const imms: u32 = @intCast(63 - sh);
        try s.word(0xD3400000 | immr << 16 | imms << 10 | try gr(n) << 5 | try gr(d));
    }

    /// `cset xd, c`.
    pub fn cset(s: *Asm, d: Reg, c: Cond) Error!void {
        try s.word(0x9A9F07E0 | @as(u32, @backingInt(invert(c))) << 12 | try gr(d));
    }

    // ---- Control ----

    pub fn b(s: *Asm, l: Label) Error!void {
        try s.branchTo(0x14000000, .imm26, l);
    }

    pub fn bcond(s: *Asm, c: Cond, l: Label) Error!void {
        try s.branchTo(0x54000000 | @as(u32, @backingInt(c)), .imm19, l);
    }

    pub fn cbz(s: *Asm, t: Reg, l: Label) Error!void {
        try s.branchTo(0xB4000000 | try gr(t), .imm19, l);
    }

    pub fn cbnz(s: *Asm, t: Reg, l: Label) Error!void {
        try s.branchTo(0xB5000000 | try gr(t), .imm19, l);
    }

    /// `cbz wt`: a 32-bit test, for the `u32` result of a helper.
    pub fn cbzW(s: *Asm, t: Reg, l: Label) Error!void {
        try s.branchTo(0x34000000 | try gr(t), .imm19, l);
    }

    pub fn cbnzW(s: *Asm, t: Reg, l: Label) Error!void {
        try s.branchTo(0x35000000 | try gr(t), .imm19, l);
    }

    pub fn br(s: *Asm, n: Reg) Error!void {
        try s.word(0xD61F0000 | try gr(n) << 5);
    }

    pub fn blr(s: *Asm, n: Reg) Error!void {
        try s.word(0xD63F0000 | try gr(n) << 5);
    }

    pub fn ret(s: *Asm) Error!void {
        try s.word(0xD65F03C0);
    }

    // ---- Other ----

    pub fn brk(s: *Asm, imm: i64) Error!void {
        try s.word(0xD4200000 | try ufield(imm, 16) << 5);
    }

    pub fn udf(s: *Asm, imm: i64) Error!void {
        try s.word(try ufield(imm, 16));
    }

    pub fn nop(s: *Asm) Error!void {
        try s.word(0xD503201F);
    }

    // ---- Doubles ----

    pub fn fmovDD(s: *Asm, d: DReg, n: DReg) Error!void {
        try s.word(0x1E604000 | dr(n) << 5 | dr(d));
    }

    /// `fmov dd, xn`: the bits of `xn`.
    pub fn fmovDX(s: *Asm, d: DReg, n: Reg) Error!void {
        try s.word(0x9E670000 | try gr(n) << 5 | dr(d));
    }

    /// `fmov xd, dn`: the bits of `dn`.
    pub fn fmovXD(s: *Asm, d: Reg, n: DReg) Error!void {
        try s.word(0x9E660000 | dr(n) << 5 | try gr(d));
    }

    pub fn fop(s: *Asm, op: FOp, d: DReg, n: DReg, m: DReg) Error!void {
        try s.word(@backingInt(op) | dr(m) << 16 | dr(n) << 5 | dr(d));
    }

    /// `fabs dd, dn`.
    pub fn fabs(s: *Asm, d: DReg, n: DReg) Error!void {
        try s.word(0x1E60C000 | dr(n) << 5 | dr(d));
    }

    /// `fsqrt dd, dn`.
    pub fn fsqrt(s: *Asm, d: DReg, n: DReg) Error!void {
        try s.word(0x1E61C000 | dr(n) << 5 | dr(d));
    }

    pub fn fcmp(s: *Asm, n: DReg, m: DReg) Error!void {
        try s.word(0x1E602000 | dr(m) << 16 | dr(n) << 5);
    }

    /// `scvtf dd, xn`.
    pub fn scvtf(s: *Asm, d: DReg, n: Reg) Error!void {
        try s.word(0x9E620000 | try gr(n) << 5 | dr(d));
    }
};

// ---- The forms of the golden table ----

/// Each primitive form of the golden table. The operands of a row are
/// `a`, `b`, and `c` (register numbers), `i` (an offset or an
/// immediate), `j` (a shift), and `k` (an operation, a size, or a
/// condition).
pub const Form = enum {
    mov_rr,
    mov_rr32,
    movz,
    movk,
    movn,
    movz_w,
    ldr_u,
    str_u,
    ldur,
    stur,
    ldr_r,
    str_r,
    stp_pre,
    stp_post,
    stp_off,
    ldp_pre,
    ldp_post,
    ldp_off,
    add_i,
    sub_i,
    adds_i,
    subs_i,
    cmp_i,
    cmp_wi,
    cmp_wr,
    op_r,
    cmp_r,
    and_i,
    tst_i,
    mul,
    smulh,
    sdiv,
    msub,
    asr_i,
    lsl_i,
    cset,
    b,
    bcond,
    cbz,
    cbnz,
    cbz_w,
    cbnz_w,
    br,
    blr,
    ret,
    brk,
    udf,
    nop,
    fmov_dd,
    fmov_dx,
    fmov_xd,
    fop,
    fcmp,
    scvtf,
};

pub const Row = struct {
    f: Form,
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    i: i64 = 0,
    j: u8 = 0,
    k: u8 = 0,
    bytes: []const u8,
};

pub const sizes = [_]Size{ .x, .w, .b, .d };
pub const ops = [_]Op{ .add, .adds, .sub, .subs, .@"and", .orr, .eor };
pub const fops = [_]FOp{ .fadd, .fsub, .fmul, .fdiv };

/// Encodes one row of the golden table. A branch row goes to the next
/// instruction, so its offset is one word.
pub fn encodeRow(s: *Asm, row: Row) Error!void {
    const ra: Reg = @fromBackingInt(@intCast(row.a));
    const rb: Reg = @fromBackingInt(@intCast(row.b));
    const rc: Reg = @fromBackingInt(@intCast(row.c));
    const da: DReg = @fromBackingInt(@intCast(@as(u5, @truncate(row.a))));
    const db: DReg = @fromBackingInt(@intCast(@as(u5, @truncate(row.b))));
    const dc: DReg = @fromBackingInt(@intCast(@as(u5, @truncate(row.c))));
    // The size and the register of the load and store forms.
    const z: Size = sizes[row.k & 3];
    const t: Rt = if (z == .d) .{ .d = da } else .{ .r = ra };
    switch (row.f) {
        .mov_rr => try s.movRR(ra, rb),
        .mov_rr32 => try s.movRR32(ra, rb),
        .movz => try s.movz(ra, row.i, @intCast(row.j)),
        .movk => try s.movk(ra, row.i, @intCast(row.j)),
        .movn => try s.movn(ra, row.i, @intCast(row.j)),
        .movz_w => try s.movzW(ra, row.i),
        .ldr_u => try s.ldrU(z, t, rb, row.i),
        .str_u => try s.strU(z, t, rb, row.i),
        .ldur => try s.ldur(z, t, rb, row.i),
        .stur => try s.stur(z, t, rb, row.i),
        .ldr_r => try s.ldrR(z, t, rb, rc),
        .str_r => try s.strR(z, t, rb, rc),
        .stp_pre => try s.stpPre(ra, rb, rc, row.i),
        .stp_post => try s.stpPost(ra, rb, rc, row.i),
        .stp_off => try s.stpOff(ra, rb, rc, row.i),
        .ldp_pre => try s.ldpPre(ra, rb, rc, row.i),
        .ldp_post => try s.ldpPost(ra, rb, rc, row.i),
        .ldp_off => try s.ldpOff(ra, rb, rc, row.i),
        .add_i => try s.addI(ra, rb, row.i, row.j != 0),
        .sub_i => try s.subI(ra, rb, row.i, row.j != 0),
        .adds_i => try s.addsI(ra, rb, row.i, row.j != 0),
        .subs_i => try s.subsI(ra, rb, row.i, row.j != 0),
        .cmp_i => try s.cmpI(ra, row.i),
        .cmp_wi => try s.cmpWI(ra, row.i),
        .cmp_wr => try s.cmpWR(ra, rb),
        .op_r => try s.opR(ops[row.k], ra, rb, rc, @fromBackingInt(@intCast(@as(u2, @intCast(row.j)))), row.i),
        .cmp_r => try s.cmpR(ra, rb, @fromBackingInt(@intCast(@as(u2, @intCast(row.j)))), row.i),
        .and_i => try s.andI(ra, rb, @bitCast(row.i)),
        .tst_i => try s.tstI(ra, @bitCast(row.i)),
        .mul => try s.mul(ra, rb, rc),
        .smulh => try s.smulh(ra, rb, rc),
        .sdiv => try s.sdiv(ra, rb, rc),
        .msub => try s.msub(ra, rb, rc, @fromBackingInt(@intCast(row.j))),
        .asr_i => try s.asrI(ra, rb, row.i),
        .lsl_i => try s.lslI(ra, rb, row.i),
        .cset => try s.cset(ra, @fromBackingInt(@intCast(@as(u4, @intCast(row.k))))),
        .b, .bcond, .cbz, .cbnz, .cbz_w, .cbnz_w => {
            const l = try s.newLabel();
            switch (row.f) {
                .b => try s.b(l),
                .bcond => try s.bcond(@fromBackingInt(@intCast(@as(u4, @intCast(row.k)))), l),
                .cbz => try s.cbz(ra, l),
                .cbnz => try s.cbnz(ra, l),
                .cbz_w => try s.cbzW(ra, l),
                else => try s.cbnzW(ra, l),
            }
            s.bind(l);
        },
        .br => try s.br(ra),
        .blr => try s.blr(ra),
        .ret => try s.ret(),
        .brk => try s.brk(row.i),
        .udf => try s.udf(row.i),
        .nop => try s.nop(),
        .fmov_dd => try s.fmovDD(da, db),
        .fmov_dx => try s.fmovDX(da, rb),
        .fmov_xd => try s.fmovXD(ra, db),
        .fop => try s.fop(fops[row.k], da, db, dc),
        .fcmp => try s.fcmp(da, db),
        .scvtf => try s.scvtf(da, rb),
    }
}

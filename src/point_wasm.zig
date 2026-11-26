//! Compiles a point proc to a standalone WebAssembly module.
//!
//! The input is the vector program of `point.zig` (`Program`). The
//! output is a copy of the runtime module (`point_rt.zig`) with one new
//! function `run`, a memory of a fixed size, the globals of the column
//! offsets, and the custom section `ztcl.point`. See
//! `docs/dev/wasm-compile.md` for the ABI.
//!
//! The layout of the memory is fixed when the module is made: after the
//! data and the stack of the runtime come the table of output columns
//! for `rt_bound`, the five limits, the feature column (one byte for
//! each point), and one column of f64 for each input field and each
//! output. So each load and store has the column address in its memory
//! argument, and the address operand is the point index times 8.
//!
//! `run` checks the compute limit before each block of `point.block`
//! points, as `Program.steps` counts. In a block, the SIMD form runs the
//! operations of the program for two points at a time, with each
//! register in a `v128` local of two f64 lanes, and the last point of
//! an odd block in a body with `f64` locals. The scalar form uses only
//! the `f64` body. All operations of a program are in one loop body, so
//! a register needs no scratch memory. An `if` of the proc is a mask
//! and a select, as in `Program.run`.
//!
//! An operation uses a wasm instruction only when that instruction
//! gives the bits of `Program.run` for each input. Each such case has
//! its reason in a comment. The other operations call the runtime one
//! lane at a time. A NaN can differ in its payload only where `bound`
//! later replaces it, because `bound` makes each non-finite output its
//! start value.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const point = @import("point.zig");
const expr = @import("expr.zig");
const w = @import("wasm_out.zig");
const link = @import("wasm_link.zig");

pub const abi_version = 1;

pub const Options = struct {
    simd: bool = true,
    /// The size of the memory in bytes. It is rounded down to pages.
    max_mem: u64 = 16 << 20,
    features: []const []const u8 = &point.default_features,
    /// The SHA-256 of the source, in hex, for the custom section.
    source_sha256: []const u8 = "",
};

pub const Error = link.Error || error{ MemoryTooSmall, InvalidBody };

const field_count = @typeInfo(point.Field).@"enum".field_names.len;
const out_count = @typeInfo(point.Out).@"enum".field_names.len;

/// The addresses of the parts of the memory.
pub const Layout = struct {
    pages: u32,
    cap: u32,
    outs_table: u32,
    limits: u32,
    /// The feature column, or null when the proc has no feature input.
    feature: ?u32 = null,
    in: [field_count]?u32 = @splat(null),
    out: [out_count]?u32 = @splat(null),
};

/// The outputs that a program writes: the columns of its `store` ops.
pub fn outputs(p: *const point.Program) [out_count]bool {
    var o: [out_count]bool = @splat(false);
    for (p.ops) |op| if (op.code == .store) {
        o[op.col] = true;
    };
    return o;
}

/// The input columns: the parameters, and `width` for `bound`.
fn inputs(p: *const point.Program) [field_count]bool {
    var f: [field_count]bool = @splat(false);
    f[@backingInt(point.Field.width)] = true;
    for (p.params) |q| f[@backingInt(q)] = true;
    f[@backingInt(point.Field.feature)] = false;
    return f;
}

fn hasFeature(p: *const point.Program) bool {
    for (p.params) |q| if (q == .feature) return true;
    return false;
}

pub fn layout(p: *const point.Program, free: u32, max_mem: u64) Error!Layout {
    const page = 65536;
    const pages64: u64 = @min(max_mem / page, 65536);
    const bytes: u64 = pages64 * page;
    var l: Layout = .{ .pages = @intCast(pages64), .cap = 0, .outs_table = free, .limits = free + 32 };
    const start: u64 = free + 80;
    const ins = inputs(p);
    const outs = outputs(p);
    var cols: u64 = 0;
    for (ins) |b| cols += @intFromBool(b);
    for (outs) |b| cols += @intFromBool(b);
    const feat = hasFeature(p);
    const per_point = cols * 8 + @intFromBool(feat);
    if (bytes < start + 64) return error.MemoryTooSmall;
    var cap = (bytes - start - 16) / per_point;
    cap = @min(cap & ~@as(u64, 1), std.math.maxInt(i32) - 16);
    if (cap < 2) return error.MemoryTooSmall;
    l.cap = @intCast(cap);
    var at = start;
    if (feat) {
        l.feature = @intCast(at);
        at += std.mem.alignForward(u64, cap, 16);
    }
    for (ins, 0..) |b, k| if (b) {
        l.in[k] = @intCast(at);
        at += cap * 8;
    };
    for (outs, 0..) |b, k| if (b) {
        l.out[k] = @intCast(at);
        at += cap * 8;
    };
    std.debug.assert(at <= bytes);
    return l;
}

const run_type: w.FuncType = .{ .params = &.{ .i32, .i32, .i32, .i32, .i64 }, .results = &.{.i64} };

const Gen = struct {
    b: *w.Body,
    rt: *const link.Runtime,
    l: Layout,
    p: *const point.Program,
    /// The register locals of the two bodies.
    vregs: []u32,
    fregs: []u32,
    /// The present flag of each input field and output column.
    in_present: [field_count]u32,
    out_present: [out_count]u32,
    feature_present: u32,
    i: u32,
    off: u32,
    zero_v: u32,
    one_v: u32,
    t0: u32,
    t1: u32,
    /// Scratch locals of `clamp`.
    vt: u32 = 0,
    ft: u32 = 0,
    /// A register that stays 0, for the z of `noise2`. Locals start at 0.
    zero_reg: u16 = 0,

    fn rtFunc(g: *Gen, name: []const u8) Error!u32 {
        return g.rt.func(name) orelse error.Unsupported;
    }

    /// The body of one step: the operations for 2 points (`wide`) or 1.
    fn body(g: *Gen, wide: bool) Error!void {
        const b = g.b;
        try b.localGet(g.i);
        try b.i32Const(3);
        try b.num(.i32_shl);
        try b.localSet(g.off);
        for (g.p.ops) |op| try g.emit(op, wide);
    }

    fn reg(g: *Gen, r: u16, wide: bool) u32 {
        return if (wide) g.vregs[r] else g.fregs[r];
    }

    fn get(g: *Gen, r: u16, wide: bool) Error!void {
        try g.b.localGet(g.reg(r, wide));
    }

    fn set(g: *Gen, r: u16, wide: bool) Error!void {
        try g.b.localSet(g.reg(r, wide));
    }

    fn zero(g: *Gen, wide: bool) Error!void {
        if (wide) try g.b.localGet(g.zero_v) else try g.b.f64Const(0);
    }

    /// The condition `x != 0`: a lane mask, or an i32.
    fn cond(g: *Gen, r: u16, wide: bool) Error!void {
        try g.get(r, wide);
        try g.zero(wide);
        // f64.ne and f64x2.ne are true for NaN, as `x != 0` in Zig.
        if (wide) try g.b.vec(.f64x2_ne) else try g.b.num(.f64_ne);
    }

    /// A condition to the number 1 or 0, as `b2f`.
    fn toNum(g: *Gen, wide: bool) Error!void {
        if (wide) {
            // A lane of all ones and 1.0 gives the bits of 1.0; a lane of
            // zeros gives +0, the bits of `b2f(false)`.
            try g.b.localGet(g.one_v);
            try g.b.vec(.v128_and);
        } else try g.b.num(.f64_convert_i32_u);
    }

    /// Selects between the values on the stack with the condition on
    /// top: the first value where the condition is true.
    fn pick(g: *Gen, wide: bool) Error!void {
        if (wide) try g.b.vec(.v128_bitselect) else try g.b.select(.f64);
    }

    fn compare(g: *Gen, op: anytype, wide: bool, v: w.Body.Vec, s: w.Body.Num) Error!void {
        try g.get(op.a, wide);
        try g.get(op.b, wide);
        // IEEE compares are exact and false for NaN, except `ne`, as in Zig.
        if (wide) try g.b.vec(v) else try g.b.num(s);
        try g.toNum(wide);
    }

    fn binary(g: *Gen, a: u16, bb: u16, wide: bool, v: w.Body.Vec, s: w.Body.Num) Error!void {
        try g.get(a, wide);
        try g.get(bb, wide);
        if (wide) try g.b.vec(v) else try g.b.num(s);
    }

    fn unary(g: *Gen, a: u16, wide: bool, v: w.Body.Vec, s: w.Body.Num) Error!void {
        try g.get(a, wide);
        if (wide) try g.b.vec(v) else try g.b.num(s);
    }

    /// A call of the runtime for each lane. `args` are registers; the
    /// seed goes first when `seed`.
    fn laneCall(g: *Gen, func: u32, seed: bool, args: []const u16, wide: bool) Error!void {
        const b = g.b;
        if (!wide) {
            if (seed) try b.localGet(1);
            for (args) |r| try g.get(r, false);
            return b.call(func);
        }
        for ([_]u8{ 0, 1 }, [_]u32{ g.t0, g.t1 }) |lane, t| {
            if (seed) try b.localGet(1);
            for (args) |r| {
                try g.get(r, true);
                try b.f64x2ExtractLane(lane);
            }
            try b.call(func);
            try b.localSet(t);
        }
        try g.joinLanes();
    }

    fn joinLanes(g: *Gen) Error!void {
        try g.b.localGet(g.t0);
        try g.b.f64x2Splat();
        try g.b.localGet(g.t1);
        try g.b.f64x2ReplaceLane(1);
    }

    /// `expr.maxF(a, b)` or `expr.minF(a, b)` of the two values in the
    /// locals: `isNan(a) ? b : (b > a ? b : a)`. A select copies bits,
    /// so the result has the bits of the Zig function.
    fn minMaxF(g: *Gen, a: u32, bb: u32, max: bool, wide: bool) Error!void {
        const b = g.b;
        try b.localGet(bb);
        try b.localGet(bb);
        try b.localGet(a);
        try b.localGet(bb);
        try b.localGet(a);
        if (wide) try b.vec(if (max) .f64x2_gt else .f64x2_lt) else try b.num(if (max) .f64_gt else .f64_lt);
        try g.pick(wide);
        try b.localGet(a);
        try b.localGet(a);
        if (wide) try b.vec(.f64x2_ne) else try b.num(.f64_ne);
        try g.pick(wide);
    }

    fn emit(g: *Gen, op: anytype, wide: bool) Error!void {
        const b = g.b;
        const T: w.ValType = if (wide) .v128 else .f64;
        switch (op.code) {
            .konst => unreachable,
            .field => {
                // A missing input column reads as 0.
                try b.localGet(g.off);
                if (wide) try b.v128Load(.{ .align_log2 = 3, .offset = g.l.in[op.col].? }) else try b.load(.f64, .{ .align_log2 = 3, .offset = g.l.in[op.col].? });
                try g.zero(wide);
                try b.localGet(g.in_present[op.col]);
                try b.select(T);
            },
            .feature => {
                const col = g.l.feature.?;
                for (0..@as(u32, if (wide) 2 else 1)) |lane| {
                    try b.localGet(g.i);
                    try b.load(.i32_8u, .{ .align_log2 = 0, .offset = col + @as(u32, @intCast(lane)) });
                    try b.num(.f64_convert_i32_u);
                    if (wide) {
                        if (lane == 0) try b.f64x2Splat() else try b.f64x2ReplaceLane(1);
                    }
                }
                try g.zero(wide);
                try b.localGet(g.feature_present);
                try b.select(T);
            },
            .out_load => {
                // A missing output column reads as 0.
                try b.localGet(g.off);
                if (wide) try b.v128Load(.{ .align_log2 = 3, .offset = g.l.out[op.col].? }) else try b.load(.f64, .{ .align_log2 = 3, .offset = g.l.out[op.col].? });
                try g.zero(wide);
                try b.localGet(g.out_present[op.col]);
                try b.select(T);
                try g.set(op.dst, wide);
                return;
            },
            .store => {
                // A missing output column is not written.
                try b.localGet(g.out_present[op.col]);
                try b.@"if"(null);
                try b.localGet(g.off);
                try g.get(op.a, wide);
                if (wide) try b.v128Store(.{ .align_log2 = 3, .offset = g.l.out[op.col].? }) else try b.store(.f64, .{ .align_log2 = 3, .offset = g.l.out[op.col].? });
                try b.end();
                return;
            },
            // Negation flips the sign bit, as `-x` in Zig.
            .neg => try g.unary(op.a, wide, .f64x2_neg, .f64_neg),
            // IEEE add, sub, mul, and div round the same on each target.
            .add => try g.binary(op.a, op.b, wide, .f64x2_add, .f64_add),
            .sub => try g.binary(op.a, op.b, wide, .f64x2_sub, .f64_sub),
            .mul => try g.binary(op.a, op.b, wide, .f64x2_mul, .f64_mul),
            .div => try g.binary(op.a, op.b, wide, .f64x2_div, .f64_div),
            .idiv => {
                // `@floor(x / y)`: floor is exact.
                try g.binary(op.a, op.b, wide, .f64x2_div, .f64_div);
                if (wide) try b.vec(.f64x2_floor) else try b.num(.f64_floor);
            },
            .imod => {
                // `x - @floor(x / y) * y`, in the same order, with no fused
                // multiply and add, as Zig compiles it.
                try g.get(op.a, wide);
                try g.binary(op.a, op.b, wide, .f64x2_div, .f64_div);
                if (wide) try b.vec(.f64x2_floor) else try b.num(.f64_floor);
                try g.get(op.b, wide);
                if (wide) try b.vec(.f64x2_mul) else try b.num(.f64_mul);
                if (wide) try b.vec(.f64x2_sub) else try b.num(.f64_sub);
            },
            .lt => try g.compare(op, wide, .f64x2_lt, .f64_lt),
            .le => try g.compare(op, wide, .f64x2_le, .f64_le),
            .gt => try g.compare(op, wide, .f64x2_gt, .f64_gt),
            .ge => try g.compare(op, wide, .f64x2_ge, .f64_ge),
            .eq => try g.compare(op, wide, .f64x2_eq, .f64_eq),
            .ne => try g.compare(op, wide, .f64x2_ne, .f64_ne),
            .truthy => {
                try g.cond(op.a, wide);
                try g.toNum(wide);
            },
            .lnot => {
                try g.get(op.a, wide);
                try g.zero(wide);
                if (wide) try b.vec(.f64x2_eq) else try b.num(.f64_eq);
                try g.toNum(wide);
            },
            .land, .lor => {
                try g.cond(op.a, wide);
                try g.cond(op.b, wide);
                if (op.code == .land) {
                    if (wide) try b.vec(.v128_and) else try b.num(.i32_and);
                } else {
                    if (wide) try b.vec(.v128_or) else try b.num(.i32_or);
                }
                try g.toNum(wide);
            },
            .select => {
                // `if (m != 0) x else y`: a select copies the bits.
                try g.get(op.b, wide);
                try g.get(op.c, wide);
                try g.cond(op.a, wide);
                try g.pick(wide);
            },
            .clamp => {
                // `expr.clamp`: minF(maxF(x, lo), hi), with selects.
                const t: u32 = if (wide) g.vt else g.ft;
                const lo = g.reg(op.b, wide);
                const hi = g.reg(op.c, wide);
                try g.minMaxF(g.reg(op.a, wide), lo, true, wide);
                try b.localSet(t);
                try g.minMaxF(t, hi, false, wide);
            },
            .lerp => {
                // `x + (y - x) * t` in the same order.
                try g.get(op.a, wide);
                try g.get(op.b, wide);
                try g.get(op.a, wide);
                if (wide) try b.vec(.f64x2_sub) else try b.num(.f64_sub);
                try g.get(op.c, wide);
                if (wide) try b.vec(.f64x2_mul) else try b.num(.f64_mul);
                if (wide) try b.vec(.f64x2_add) else try b.num(.f64_add);
            },
            .noise3 => try g.noise(op, wide),
            .fn1 => switch (op.f) {
                // abs clears the sign bit; sqrt is correctly rounded; floor,
                // ceil, and trunc are exact. Each gives the bits of the
                // Zig builtin.
                .abs => try g.unary(op.a, wide, .f64x2_abs, .f64_abs),
                .sqrt => try g.unary(op.a, wide, .f64x2_sqrt, .f64_sqrt),
                .floor => try g.unary(op.a, wide, .f64x2_floor, .f64_floor),
                .ceil => try g.unary(op.a, wide, .f64x2_ceil, .f64_ceil),
                .int, .wide, .entier => try g.unary(op.a, wide, .f64x2_trunc, .f64_trunc),
                .double => try g.get(op.a, wide),
                else => {
                    var buf: [32]u8 = undefined;
                    const name = std.fmt.bufPrint(&buf, "rt_{s}", .{@tagName(op.f)}) catch unreachable;
                    try g.laneCall(try g.rtFunc(name), false, &.{op.a}, wide);
                },
            },
            .fn2 => switch (op.f) {
                // `if (y < x) y else x` and `if (y > x) y else x`: a select.
                .min, .max => {
                    try g.get(op.b, wide);
                    try g.get(op.a, wide);
                    try g.get(op.b, wide);
                    try g.get(op.a, wide);
                    if (op.f == .min) {
                        if (wide) try b.vec(.f64x2_lt) else try b.num(.f64_lt);
                    } else {
                        if (wide) try b.vec(.f64x2_gt) else try b.num(.f64_gt);
                    }
                    try g.pick(wide);
                },
                .noise2 => {
                    // `noise3Seed(seed, x, y, 0)`.
                    const zr = g.zero_reg;
                    try g.laneCall(try g.rtFunc("rt_noise3"), true, &.{ op.a, op.b, zr }, wide);
                },
                else => {
                    var buf: [32]u8 = undefined;
                    const name = std.fmt.bufPrint(&buf, "rt_{s}", .{@tagName(op.f)}) catch unreachable;
                    try g.laneCall(try g.rtFunc(name), false, &.{ op.a, op.b }, wide);
                },
            },
        }
        try g.set(op.dst, wide);
    }

    /// `noise3` runs only for the lanes in its mask. Another lane gets
    /// 0; no output uses it, as in `Program.run`.
    fn noise(g: *Gen, op: anytype, wide: bool) Error!void {
        const b = g.b;
        const f = try g.rtFunc("rt_noise3");
        if (op.m == none) return g.laneCall(f, true, &.{ op.a, op.b, op.c }, wide);
        const lanes: []const u8 = if (wide) &.{ 0, 1 } else &.{0};
        const temps = [_]u32{ g.t0, g.t1 };
        for (lanes, temps[0..lanes.len]) |lane, t| {
            try g.get(op.m, wide);
            if (wide) try b.f64x2ExtractLane(lane);
            try b.f64Const(0);
            try b.num(.f64_ne);
            try b.@"if"(.f64);
            try b.localGet(1);
            for ([_]u16{ op.a, op.b, op.c }) |r| {
                try g.get(r, wide);
                if (wide) try b.f64x2ExtractLane(lane);
            }
            try b.call(f);
            try b.@"else"();
            try b.f64Const(0);
            try b.end();
            if (wide) try b.localSet(t);
        }
        if (wide) try g.joinLanes();
    }
};

const none: u16 = 0xffff;

pub const Compiled = struct { bytes: []u8, layout: Layout };

/// Makes the module of a point proc.
pub fn compile(a: Allocator, p: *const point.Program, opts: Options) Error!Compiled {
    const rt_bytes = if (opts.simd) link.runtime_simd else link.runtime_scalar;
    const rt = try link.read(a, rt_bytes);
    const l = try layout(p, rt.free, opts.max_mem);
    const funcs = try link.allFuncTypes(a, &rt, &.{run_type});
    var b = try w.Body.init(a, run_type, funcs, rt.global_types);
    // Registers: one more for the constant 0 of noise2.
    const nregs = p.regs + 1;
    var g: Gen = .{
        .b = &b,
        .rt = &rt,
        .l = l,
        .p = p,
        .vregs = try a.alloc(u32, nregs),
        .fregs = try a.alloc(u32, nregs),
        .in_present = undefined,
        .out_present = undefined,
        .feature_present = try b.local(.i32),
        .i = try b.local(.i32),
        .off = try b.local(.i32),
        .zero_v = try b.local(.v128),
        .one_v = try b.local(.v128),
        .t0 = try b.local(.f64),
        .t1 = try b.local(.f64),
        .zero_reg = @intCast(p.regs),
    };
    g.vt = try b.local(.v128);
    g.ft = try b.local(.f64);
    for (&g.in_present) |*x| x.* = try b.local(.i32);
    for (&g.out_present) |*x| x.* = try b.local(.i32);
    const used = try b.local(.i64);
    const start = try b.local(.i32);
    const end = try b.local(.i32);
    const ops_len: i64 = @intCast(p.ops.len);
    const setup_len: i64 = @intCast(p.setup.len);
    for (g.fregs) |*r| r.* = try b.local(.f64);
    if (opts.simd) {
        for (g.vregs) |*r| r.* = try b.local(.v128);
    }
    const wide_ok = opts.simd;

    // n > cap gives -2.
    try b.localGet(0);
    try b.i32Const(@bitCast(l.cap));
    try b.num(.i32_gt_u);
    try b.@"if"(null);
    try b.i64Const(-2);
    try b.ret();
    try b.end();
    // The setup costs its count of steps once.
    try b.localGet(4);
    try b.i64Const(setup_len);
    try b.num(.i64_lt_s);
    try b.@"if"(null);
    try b.i64Const(-1);
    try b.ret();
    try b.end();
    try b.i64Const(setup_len);
    try b.localSet(used);
    // The present flags.
    for (0..field_count) |k| {
        try b.localGet(2);
        try b.i32Const(@as(i32, 1) << @intCast(k));
        try b.num(.i32_and);
        try b.i32Const(0);
        try b.num(.i32_ne);
        if (k == @backingInt(point.Field.feature)) try b.localSet(g.feature_present) else try b.localSet(g.in_present[k]);
    }
    for (0..out_count) |k| {
        try b.localGet(3);
        try b.i32Const(@as(i32, 1) << @intCast(k));
        try b.num(.i32_and);
        try b.i32Const(0);
        try b.num(.i32_ne);
        try b.localSet(g.out_present[k]);
    }
    // The table of output columns for `rt_bound`: the address of each
    // output that the proc writes and the host gives, or 0.
    for (0..out_count) |k| {
        try b.i32Const(@bitCast(l.outs_table + 4 * @as(u32, @intCast(k))));
        if (l.out[k]) |col| {
            try b.i32Const(@bitCast(col));
            try b.i32Const(0);
            try b.localGet(g.out_present[k]);
            try b.select(.i32);
        } else try b.i32Const(0);
        try b.store(.i32, .{ .align_log2 = 2 });
    }
    // The constants.
    try b.v128Const(@splat(0));
    try b.localSet(g.zero_v);
    try b.f64Const(1);
    try b.f64x2Splat();
    try b.localSet(g.one_v);
    for (p.setup) |op| {
        try b.f64Const(op.imm);
        try b.localSet(g.fregs[op.dst]);
        if (wide_ok) {
            try b.localGet(g.fregs[op.dst]);
            try b.f64x2Splat();
            try b.localSet(g.vregs[op.dst]);
        }
    }
    // The block loop.
    try b.block(null);
    try b.loop(null);
    try b.localGet(start);
    try b.localGet(0);
    try b.num(.i32_ge_u);
    try b.brIf(1);
    // The step check: a block costs the count of `ops`.
    try b.localGet(4);
    try b.localGet(used);
    try b.num(.i64_sub);
    try b.i64Const(ops_len);
    try b.num(.i64_lt_s);
    try b.@"if"(null);
    try b.i64Const(-1);
    try b.ret();
    try b.end();
    try b.localGet(used);
    try b.i64Const(ops_len);
    try b.num(.i64_add);
    try b.localSet(used);
    // end = min(start + block, n)
    try b.localGet(start);
    try b.i32Const(point.block);
    try b.num(.i32_add);
    try b.localTee(end);
    try b.localGet(0);
    try b.localGet(end);
    try b.localGet(0);
    try b.num(.i32_lt_u);
    try b.select(.i32);
    try b.localSet(end);
    try b.localGet(start);
    try b.localSet(g.i);
    if (wide_ok) {
        // Two points at a time while i + 2 <= end.
        try b.block(null);
        try b.loop(null);
        try b.localGet(g.i);
        try b.i32Const(2);
        try b.num(.i32_add);
        try b.localGet(end);
        try b.num(.i32_gt_u);
        try b.brIf(1);
        try g.body(true);
        try b.localGet(g.i);
        try b.i32Const(2);
        try b.num(.i32_add);
        try b.localSet(g.i);
        try b.br(0);
        try b.end();
        try b.end();
    }
    // One point at a time while i < end.
    try b.block(null);
    try b.loop(null);
    try b.localGet(g.i);
    try b.localGet(end);
    try b.num(.i32_ge_u);
    try b.brIf(1);
    try g.body(false);
    try b.localGet(g.i);
    try b.i32Const(1);
    try b.num(.i32_add);
    try b.localSet(g.i);
    try b.br(0);
    try b.end();
    try b.end();
    try b.localGet(end);
    try b.localSet(start);
    try b.br(0);
    try b.end();
    try b.end();
    // The limits of the outputs, for all points.
    try b.localGet(0);
    try b.i32Const(@bitCast(l.in[@backingInt(point.Field.width)].?));
    try b.i32Const(0);
    try b.localGet(g.in_present[@backingInt(point.Field.width)]);
    try b.select(.i32);
    try b.i32Const(@bitCast(l.outs_table));
    try b.i32Const(@bitCast(l.limits));
    try b.call(try g.rtFunc("rt_bound"));
    try b.localGet(used);
    const code = try b.finish();

    // The globals and the exports.
    var globals: std.ArrayList(w.Global) = .empty;
    var exports: std.ArrayList(w.Export) = .empty;
    try exports.append(a, .{ .name = "memory", .kind = .memory, .index = 0 });
    try exports.append(a, .{ .name = "run", .kind = .func, .index = link.nextFunc(&rt) });
    const g0 = link.nextGlobal(&rt);
    const addGlobal = struct {
        fn f(al: Allocator, gl: *std.ArrayList(w.Global), ex: *std.ArrayList(w.Export), base: u32, name: []const u8, v: u32) Allocator.Error!void {
            try ex.append(al, .{ .name = name, .kind = .global, .index = base + @as(u32, @intCast(gl.items.len)) });
            try gl.append(al, .{ .t = .i32, .init = v });
        }
    }.f;
    try addGlobal(a, &globals, &exports, g0, "abi", abi_version);
    try addGlobal(a, &globals, &exports, g0, "cap", l.cap);
    for (l.in, 0..) |c, k| if (c) |addr| {
        try addGlobal(a, &globals, &exports, g0, try std.fmt.allocPrint(a, "in_{s}", .{@tagName(@as(point.Field, @fromBackingInt(@intCast(k))))}), addr);
    };
    if (l.feature) |addr| try addGlobal(a, &globals, &exports, g0, "feature", addr);
    for (l.out, 0..) |c, k| if (c) |addr| {
        try addGlobal(a, &globals, &exports, g0, try std.fmt.allocPrint(a, "out_{s}", .{@tagName(@as(point.Out, @fromBackingInt(@intCast(k))))}), addr);
    };
    try addGlobal(a, &globals, &exports, g0, "limits", l.limits);

    // The default limits as a data segment.
    const lim: point.Limits = .{};
    var lim_bytes: [40]u8 = undefined;
    for ([_]f64{ lim.max_offset, lim.max_move, lim.min_width, lim.max_width, lim.fallback_width }, 0..) |v, k| {
        std.mem.writeInt(u64, lim_bytes[k * 8 ..][0..8], @bitCast(v), .little);
    }

    const meta = try metadata(a, p, l, opts);
    const bytes = try link.link(a, &rt, .{
        .funcs = &.{.{ .t = run_type, .code = code }},
        .globals = globals.items,
        .exports = exports.items,
        .memory = .{ .min = l.pages, .max = l.pages },
        .datas = &.{.{ .offset = l.limits, .bytes = &lim_bytes }},
        .customs = &.{.{ .name = "ztcl.point", .data = meta }},
    });
    return .{ .bytes = bytes, .layout = l };
}

/// The JSON of the custom section `ztcl.point`.
pub fn metadata(a: Allocator, p: *const point.Program, l: Layout, opts: Options) Allocator.Error![]u8 {
    var params: std.ArrayList([]const u8) = .empty;
    for (p.params) |q| try params.append(a, @tagName(q));
    var outs: std.ArrayList([]const u8) = .empty;
    for (outputs(p), 0..) |b, k| if (b) try outs.append(a, @tagName(@as(point.Out, @fromBackingInt(@intCast(k)))));
    return std.json.Stringify.valueAlloc(a, .{
        .abi = abi_version,
        .proc = p.name,
        .params = params.items,
        .outputs = outs.items,
        .features = opts.features,
        .block = point.block,
        .setup_steps = p.setup.len,
        .block_steps = p.ops.len,
        .cap = l.cap,
        .memory = @as(u64, l.pages) * 65536,
        .simd = opts.simd,
        .sha256 = opts.source_sha256,
    }, .{});
}

test "the fuzzy skin proc compiles to a module in both forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var it: @import("interp.zig").Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    var state: point.State = .{};
    try point.install(&it, &state);
    _ = try it.eval(
        \\point proc fuzzy {x y z feature} {
        \\    if {$feature ne "outer_wall"} { return }
        \\    set n [noise3 $x $y [expr {$z * 4}]]
        \\    offset [expr {$n * 0.3}]
        \\}
    );
    const prog = state.program("fuzzy").?;
    for ([_]bool{ true, false }) |simd| {
        const c = try compile(a, prog, .{ .simd = simd, .max_mem = 1 << 20 });
        try std.testing.expectEqual(@as(u32, 16), c.layout.pages);
        try std.testing.expect(c.layout.cap > 1000);
        const secs = try w.readSections(a, c.bytes);
        try std.testing.expectEqual(@as(u8, 0), secs[secs.len - 1].id);
    }
    try std.testing.expectError(error.MemoryTooSmall, compile(a, prog, .{ .max_mem = 65536 }));
}

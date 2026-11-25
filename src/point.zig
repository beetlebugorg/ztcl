//! Point procs: a small part of Tcl that runs for each point of a path.
//!
//! ```tcl
//! point proc fuzzy {x y z feature} {
//!     if {$feature ne "outer_wall"} { return }
//!     set n [noise3 $x $y [expr {$z * 4}]]
//!     offset [expr {$n * 0.3}]
//! }
//! ```
//!
//! `point proc` makes a normal proc (the slow path, one call for each
//! point) and compiles the same body to a vector program (the fast
//! path). The vector program works on blocks of points: each operation
//! runs over a whole block, so the cost of the interpreter is paid once
//! for each block. An `if` becomes a mask and a select; no branch
//! depends on a point.
//!
//! The check accepts only this part of Tcl:
//!
//! - parameters that are point fields (`x y z width height speed flow
//!   feature layer path dist`),
//! - `set name value` for local numbers,
//! - `if` / `elseif` / `else` with braced conditions,
//! - `return` with no value,
//! - `expr` with numbers, the math functions, and a compare of the
//!   feature with a name (`$feature ne "outer_wall"`),
//! - `[noise3 x y z]` and `[noise2 x y]`,
//! - the output commands `offset v`, `move dx dy`, `width v`, `flow v`,
//!   `speed v`, and `skip`.
//!
//! All other commands fail the check, with the line and the reason.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const interp = @import("interp.zig");
const value = @import("value.zig");
const expr = @import("expr.zig");
const noise = @import("noise.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Error = interp.Error;

/// The input columns of a point.
pub const Field = enum { x, y, z, width, height, speed, flow, feature, layer, path, dist };
/// The output columns of a point.
pub const Out = enum { offset, move_x, move_y, width, flow, speed, skip };

const field_count = @typeInfo(Field).@"enum".fields.len;
const out_count = @typeInfo(Out).@"enum".fields.len;

/// The names of the features. The number of a feature is its index.
pub const default_features = [_][]const u8{ "outer_wall", "inner_wall", "skin", "infill", "support", "travel" };

/// Points as a struct of arrays. A missing input column reads as 0. A
/// missing output column is not written. An output column holds the
/// start value of each point; a proc changes only the points it sets.
pub const Points = struct {
    len: usize,
    in: [field_count]?[]const f64 = @splat(null),
    /// The feature number of each point.
    feature: ?[]const u8 = null,
    out: [out_count]?[]f64 = @splat(null),
    /// The seed of the noise. Both paths use it.
    seed: u32 = noise.default_seed,
    /// The limits of the outputs. Both paths apply them at the end.
    limits: Limits = .{},
};

/// The limits of the outputs of a point proc. The unit of `offset` and
/// `move` is the line width of the point (the `width` input). When the
/// points have no width input, the unit is `fallback_width`.
///
/// The rule, for each point:
/// - An output that is not finite becomes its start value: 0, or the
///   width input for `width`.
/// - `offset` stays in [-max_offset, max_offset] line widths.
/// - The vector of `move` keeps its direction, and its length is at
///   most `max_move` line widths.
/// - `width` stays in [min_width, max_width] line widths.
pub const Limits = struct {
    max_offset: f64 = 1.0,
    max_move: f64 = 1.0,
    min_width: f64 = 0.25,
    max_width: f64 = 2.0,
    fallback_width: f64 = 0.4,
};

/// Applies the limits to the outputs of all points. `Program.run` and
/// `runSlow` call it, so the two paths give equal bits.
pub fn bound(pts: *const Points) void {
    const lim = pts.limits;
    const widths = pts.in[@intFromEnum(Field.width)];
    for (pts.out, 0..) |col, k| {
        const o = col orelse continue;
        const is_width = k == @intFromEnum(Out.width);
        for (o, 0..) |*v, i| {
            if (std.math.isFinite(v.*)) continue;
            v.* = if (is_width) (if (widths) |w| w[i] else lim.fallback_width) else 0;
        }
    }
    if (pts.out[@intFromEnum(Out.offset)]) |o| for (o, 0..) |*v, i| {
        const w = @abs(if (widths) |col| col[i] else lim.fallback_width) * lim.max_offset;
        v.* = expr.maxF(-w, expr.minF(w, v.*));
    };
    if (pts.out[@intFromEnum(Out.width)]) |o| for (o, 0..) |*v, i| {
        const w = @abs(if (widths) |col| col[i] else lim.fallback_width);
        v.* = expr.maxF(w * lim.min_width, expr.minF(w * lim.max_width, v.*));
    };
    const mx = pts.out[@intFromEnum(Out.move_x)] orelse return;
    const my = pts.out[@intFromEnum(Out.move_y)] orelse return;
    for (mx, my, 0..) |*x, *y, i| {
        const w = @abs(if (widths) |col| col[i] else lim.fallback_width) * lim.max_move;
        const len = @sqrt(x.* * x.* + y.* * y.*);
        if (len > w) {
            const scale = w / len;
            x.* *= scale;
            y.* *= scale;
        }
    }
}

/// The points of one block of the vector program.
pub const block = 1024;

const none: u16 = 0xffff;

const Code = enum(u8) {
    konst,
    field,
    feature,
    out_load,
    store,
    add,
    sub,
    mul,
    div,
    idiv,
    imod,
    neg,
    lt,
    le,
    gt,
    ge,
    eq,
    ne,
    land,
    lor,
    lnot,
    truthy,
    select,
    fn1,
    fn2,
    clamp,
    lerp,
    noise3,
};

const Op = struct {
    code: Code,
    dst: u16 = 0,
    a: u16 = 0,
    b: u16 = 0,
    c: u16 = 0,
    /// A mask register for an operation that skips points, or `none`.
    m: u16 = none,
    f: expr.Func = .abs,
    imm: f64 = 0,
    /// The field or the output column.
    col: u8 = 0,
};

/// A compiled point proc.
pub const Program = struct {
    name: []const u8,
    /// Operations that run once (the constants).
    setup: []const Op,
    /// Operations that run for each block.
    ops: []const Op,
    regs: usize,
    params: []const Field,

    /// The count of f64 that `run` needs as scratch memory: a block for
    /// each register, and one slot for each register in the table of
    /// register addresses.
    pub fn scratchLen(p: *const Program) usize {
        return p.regs * block + p.regs;
    }

    /// Runs the program over all points. `scratch` has `scratchLen()`
    /// elements. Two threads can run one program with their own scratch.
    pub fn run(p: *const Program, pts: *const Points, scratch: []f64) void {
        std.debug.assert(scratch.len >= p.scratchLen());
        for (p.setup) |op| @memset(scratch[@as(usize, op.dst) * block ..][0..block], op.imm);
        // A register of an input field points into the input column, so
        // the field needs no copy. No operation writes to that register.
        // An output column that overlaps an input column needs the copy.
        const direct = !outputsOverlapInputs(pts);
        const table: [*][*]f64 = @ptrCast(scratch.ptr + p.regs * block);
        for (0..p.regs) |r| table[r] = scratch.ptr + r * block;
        var start: usize = 0;
        while (start < pts.len) : (start += block) {
            const n = @min(block, pts.len - start);
            for (p.ops) |op| exec(op, pts, table, direct, start, n);
        }
        bound(pts);
    }
};

fn outputsOverlapInputs(pts: *const Points) bool {
    for (pts.out) |maybe_out| {
        const o = maybe_out orelse continue;
        const lo = @intFromPtr(o.ptr);
        const hi = lo + o.len * @sizeOf(f64);
        for (pts.in) |maybe_in| {
            const c = maybe_in orelse continue;
            const c_lo = @intFromPtr(c.ptr);
            if (lo < c_lo + c.len * @sizeOf(f64) and c_lo < hi) return true;
        }
    }
    return false;
}

inline fn reg(table: [*][*]f64, r: u16, n: usize) []f64 {
    return table[r][0..n];
}

fn b2f(b: bool) f64 {
    return @floatFromInt(@intFromBool(b));
}

fn exec(op: Op, pts: *const Points, scratch: [*][*]f64, direct: bool, start: usize, n: usize) void {
    if (op.code == .field) {
        if (pts.in[op.col]) |col| {
            if (direct) {
                scratch[op.dst] = @constCast(col[start..].ptr);
            } else @memcpy(reg(scratch, op.dst, n), col[start..][0..n]);
        } else @memset(reg(scratch, op.dst, n), 0);
        return;
    }
    const d = reg(scratch, op.dst, n);
    switch (op.code) {
        .konst, .field => {},
        .feature => {
            if (pts.feature) |col| {
                for (d, col[start..][0..n]) |*o, f| o.* = @floatFromInt(f);
            } else @memset(d, 0);
        },
        .out_load => {
            if (pts.out[op.col]) |col| @memcpy(d, col[start..][0..n]) else @memset(d, 0);
        },
        .store => {
            if (pts.out[op.col]) |col| @memcpy(col[start..][0..n], reg(scratch, op.a, n));
        },
        .neg => for (d, reg(scratch, op.a, n)) |*o, x| {
            o.* = -x;
        },
        .lnot => for (d, reg(scratch, op.a, n)) |*o, x| {
            o.* = b2f(x == 0);
        },
        .truthy => for (d, reg(scratch, op.a, n)) |*o, x| {
            o.* = b2f(x != 0);
        },
        .select => for (d, reg(scratch, op.a, n), reg(scratch, op.b, n), reg(scratch, op.c, n)) |*o, m, x, y| {
            o.* = if (m != 0) x else y;
        },
        .clamp => for (d, reg(scratch, op.a, n), reg(scratch, op.b, n), reg(scratch, op.c, n)) |*o, x, lo, hi| {
            o.* = clamp(x, lo, hi);
        },
        .lerp => for (d, reg(scratch, op.a, n), reg(scratch, op.b, n), reg(scratch, op.c, n)) |*o, x, y, t| {
            o.* = x + (y - x) * t;
        },
        .noise3 => {
            const xs = reg(scratch, op.a, n);
            const ys = reg(scratch, op.b, n);
            const zs = reg(scratch, op.c, n);
            // A point outside the mask does not use the result. When few
            // points of the block are in the mask, the noise runs only
            // for those points.
            var in_mask = n;
            if (op.m != none) {
                in_mask = 0;
                for (reg(scratch, op.m, n)) |m| in_mask += @intFromBool(m != 0);
            }
            if (in_mask * 4 >= n) {
                noise.noise3BlockSeed(pts.seed, d, xs, ys, zs);
            } else {
                for (d, xs, ys, zs, reg(scratch, op.m, n)) |*o, x, y, z, m| {
                    o.* = if (m != 0) noise.noise3Seed(pts.seed, x, y, z) else 0;
                }
            }
        },
        .fn1 => {
            const a = reg(scratch, op.a, n);
            switch (op.f) {
                .abs => for (d, a) |*o, x| {
                    o.* = @abs(x);
                },
                .sqrt => for (d, a) |*o, x| {
                    o.* = @sqrt(x);
                },
                .floor => for (d, a) |*o, x| {
                    o.* = @floor(x);
                },
                .ceil => for (d, a) |*o, x| {
                    o.* = @ceil(x);
                },
                .round => for (d, a) |*o, x| {
                    o.* = @round(x);
                },
                .int, .wide, .entier => for (d, a) |*o, x| {
                    o.* = @trunc(x);
                },
                .double => @memcpy(d, a),
                else => for (d, a) |*o, x| {
                    o.* = scalar1(op.f, x);
                },
            }
        },
        else => {
            const a = reg(scratch, op.a, n);
            const b = reg(scratch, op.b, n);
            switch (op.code) {
                .add => for (d, a, b) |*o, x, y| {
                    o.* = x + y;
                },
                .sub => for (d, a, b) |*o, x, y| {
                    o.* = x - y;
                },
                .mul => for (d, a, b) |*o, x, y| {
                    o.* = x * y;
                },
                .div => for (d, a, b) |*o, x, y| {
                    o.* = x / y;
                },
                .idiv => for (d, a, b) |*o, x, y| {
                    o.* = @floor(x / y);
                },
                .imod => for (d, a, b) |*o, x, y| {
                    o.* = x - @floor(x / y) * y;
                },
                .lt => for (d, a, b) |*o, x, y| {
                    o.* = b2f(x < y);
                },
                .le => for (d, a, b) |*o, x, y| {
                    o.* = b2f(x <= y);
                },
                .gt => for (d, a, b) |*o, x, y| {
                    o.* = b2f(x > y);
                },
                .ge => for (d, a, b) |*o, x, y| {
                    o.* = b2f(x >= y);
                },
                .eq => for (d, a, b) |*o, x, y| {
                    o.* = b2f(x == y);
                },
                .ne => for (d, a, b) |*o, x, y| {
                    o.* = b2f(x != y);
                },
                .land => for (d, a, b) |*o, x, y| {
                    o.* = b2f(x != 0 and y != 0);
                },
                .lor => for (d, a, b) |*o, x, y| {
                    o.* = b2f(x != 0 or y != 0);
                },
                .fn2 => for (d, a, b) |*o, x, y| {
                    o.* = scalar2(pts.seed, op.f, x, y);
                },
                else => unreachable,
            }
        },
    }
}

/// The runtime of a compiled point proc (`point_rt.zig`) calls
/// `scalar1`, `scalar2`, and `clamp`.
pub inline fn clamp(x: f64, lo: f64, hi: f64) f64 {
    return expr.clamp(x, lo, hi);
}

pub fn scalar1(f: expr.Func, x: f64) f64 {
    return switch (f) {
        .acos => std.math.acos(x),
        .asin => std.math.asin(x),
        .atan => std.math.atan(x),
        .cos => @cos(x),
        .cosh => std.math.cosh(x),
        .exp => @exp(x),
        .log => @log(x),
        .log10 => @log10(x),
        .sin => @sin(x),
        .sinh => std.math.sinh(x),
        .tan => @tan(x),
        .tanh => std.math.tanh(x),
        else => unreachable,
    };
}

pub fn scalar2(seed: u32, f: expr.Func, x: f64, y: f64) f64 {
    return switch (f) {
        .atan2 => std.math.atan2(x, y),
        .fmod => @rem(x, y),
        .hypot => std.math.hypot(x, y),
        .pow => std.math.pow(f64, x, y),
        .min => if (y < x) y else x,
        .max => if (y > x) y else x,
        .noise2 => noise.noise3Seed(seed, x, y, 0),
        else => unreachable,
    };
}

// ---- The check and the compiler ----

/// The kind of a value in the normal interpreter. The vector program
/// holds all numbers as f64, so the check tracks the kind to keep the
/// integer division of Tcl. `mixed` is a number that is an integer for
/// some points and a double for others.
const Kind = enum {
    double,
    int,
    mixed,
    feature,

    fn merge(x: Kind, y: Kind) Kind {
        return if (x == y) x else .mixed;
    }

    /// The kind of `x + y`, `x - y`, or `x * y`.
    fn arith(x: Kind, y: Kind) Kind {
        if (x == .double or y == .double) return .double;
        if (x == .int and y == .int) return .int;
        return .mixed;
    }
};
const V = struct { reg: u16, kind: Kind };
const Local = struct { name: []const u8, v: V, depth: u32 };

const Compiler = struct {
    it: *Interp,
    a: Allocator,
    name: []const u8,
    features: []const []const u8,
    setup: std.ArrayList(Op) = .empty,
    ops: std.ArrayList(Op) = .empty,
    locals: std.ArrayList(Local) = .empty,
    regs: u16 = 0,
    line: u32 = 1,
    /// The line of the proc where the current script starts.
    base: u32 = 1,
    depth: u32 = 0,
    /// The mask of the current block, or `none` for all points.
    mask: u16 = none,
    /// The mask of the points that have returned, or `none` for no point.
    returned: u16 = none,
    outs: [out_count]u16 = @splat(none),

    fn fail(c: *Compiler, comptime fmt: []const u8, args: anytype) Error {
        return c.it.fail("point proc {s}, line {d}: " ++ fmt, .{ c.name, c.line } ++ args);
    }

    fn newReg(c: *Compiler) Error!u16 {
        if (c.regs >= 4096) return c.fail("the proc is too large", .{});
        c.regs += 1;
        return c.regs - 1;
    }

    fn emit(c: *Compiler, op: Op) Error!u16 {
        var o = op;
        o.dst = try c.newReg();
        try c.ops.append(c.a, o);
        return o.dst;
    }

    fn konst(c: *Compiler, x: f64) Error!u16 {
        for (c.setup.items) |op| {
            if (@as(u64, @bitCast(op.imm)) == @as(u64, @bitCast(x))) return op.dst;
        }
        const r = try c.newReg();
        try c.setup.append(c.a, .{ .code = .konst, .dst = r, .imm = x });
        return r;
    }

    /// The mask of the points that a statement changes here.
    fn effMask(c: *Compiler) Error!u16 {
        if (c.returned == none) return c.mask;
        const live = try c.emit(.{ .code = .lnot, .a = c.returned });
        if (c.mask == none) return live;
        return c.emit(.{ .code = .land, .a = c.mask, .b = live });
    }

    fn lookup(c: *Compiler, name: []const u8) ?*Local {
        for (c.locals.items) |*l| if (std.mem.eql(u8, l.name, name)) return l;
        return null;
    }

    fn body(c: *Compiler, script: *interp.Script, base_line: u32) Error!void {
        const outer = c.base;
        defer c.base = outer;
        c.base = base_line;
        for (script.cmds) |*cmd| {
            c.line = base_line + cmd.line - 1;
            try c.statement(cmd);
        }
    }

    fn litText(c: *Compiler, w: *const interp.Word) Error!?[]const u8 {
        if (w.expand) return c.fail("{{*}} is not allowed", .{});
        if (w.kind != .lit) return null;
        return try c.it.str(w.kind.lit);
    }

    fn statement(c: *Compiler, cmd: *interp.Cmd) Error!void {
        const w = cmd.words;
        const name = try c.litText(&w[0]) orelse return c.fail("the command name must be a plain word", .{});
        const stmt_line = c.line;
        if (std.mem.eql(u8, name, "set")) {
            if (w.len != 3) return c.fail("set needs a name and a value", .{});
            const var_name = try c.litText(&w[1]) orelse return c.fail("the name of a variable must be a plain word", .{});
            if (std.mem.indexOfScalar(u8, var_name, '(') != null) return c.fail("arrays are not allowed", .{});
            var v = try c.word(&w[2]);
            const m = try c.effMask();
            if (c.lookup(var_name)) |l| {
                if (m != none) {
                    if ((l.v.kind == .feature) != (v.kind == .feature)) return c.fail("variable \"{s}\" changes between a feature and a number", .{var_name});
                    v.kind = l.v.kind.merge(v.kind);
                    v.reg = try c.emit(.{ .code = .select, .a = m, .b = v.reg, .c = l.v.reg });
                }
                l.v = v;
            } else {
                try c.locals.append(c.a, .{ .name = var_name, .v = v, .depth = c.depth });
            }
        } else if (std.mem.eql(u8, name, "return")) {
            if (w.len != 1) return c.fail("return with a value is not allowed", .{});
            // The points of this block that have not returned yet return now.
            if (c.mask == none) {
                c.returned = try c.konst(1);
            } else if (c.returned == none) {
                c.returned = c.mask;
            } else {
                c.returned = try c.emit(.{ .code = .lor, .a = c.returned, .b = c.mask });
            }
        } else if (std.mem.eql(u8, name, "if")) {
            try c.ifStatement(cmd, stmt_line);
        } else if (std.mem.eql(u8, name, "skip")) {
            if (w.len != 1) return c.fail("skip has no arguments", .{});
            try c.output(.skip, .{ .reg = try c.konst(1), .kind = .int });
        } else if (std.mem.eql(u8, name, "move")) {
            if (w.len != 3) return c.fail("move needs dx and dy", .{});
            try c.output(.move_x, try c.word(&w[1]));
            try c.output(.move_y, try c.word(&w[2]));
        } else if (std.meta.stringToEnum(Out, name)) |o| {
            if (o == .move_x or o == .move_y) return c.fail("\"{s}\" is not allowed in a point proc", .{name});
            if (w.len != 2) return c.fail("{s} needs one value", .{name});
            try c.output(o, try c.word(&w[1]));
        } else {
            return c.fail("\"{s}\" is not allowed in a point proc", .{name});
        }
    }

    fn output(c: *Compiler, o: Out, v: V) Error!void {
        if (v.kind == .feature) return c.fail("an output needs a number", .{});
        const k = @intFromEnum(o);
        if (c.outs[k] == none) c.outs[k] = try c.emit(.{ .code = .out_load, .col = k });
        const m = try c.effMask();
        c.outs[k] = if (m == none) v.reg else try c.emit(.{ .code = .select, .a = m, .b = v.reg, .c = c.outs[k] });
    }

    fn ifStatement(c: *Compiler, cmd: *interp.Cmd, line: u32) Error!void {
        const w = cmd.words;
        const outer = c.mask;
        defer c.mask = outer;
        // The points of the block that no earlier branch has taken.
        var rest = outer;
        var i: usize = 1;
        while (true) {
            c.line = line;
            if (i >= w.len) return c.fail("if needs a condition", .{});
            const cond_text = try c.litText(&w[i]) orelse return c.fail("a condition must be in braces", .{});
            const cond = try c.truthy(try c.exprText(cond_text));
            i += 1;
            if (i < w.len) if (try c.litText(&w[i])) |t| {
                if (std.mem.eql(u8, t, "then")) i += 1;
            };
            if (i >= w.len) return c.fail("if needs a body", .{});
            const then_mask = if (rest == none) cond else try c.emit(.{ .code = .land, .a = rest, .b = cond });
            const not_cond = try c.emit(.{ .code = .lnot, .a = cond });
            const else_mask = if (rest == none) not_cond else try c.emit(.{ .code = .land, .a = rest, .b = not_cond });
            try c.branch(&w[i], then_mask);
            rest = else_mask;
            i += 1;
            if (i >= w.len) return;
            const word_text = try c.litText(&w[i]) orelse return c.fail("a body must be in braces", .{});
            if (std.mem.eql(u8, word_text, "elseif")) {
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, word_text, "else")) i += 1;
            if (i != w.len - 1) return c.fail("if has extra words", .{});
            return c.branch(&w[i], rest);
        }
    }

    fn branch(c: *Compiler, w: *const interp.Word, mask: u16) Error!void {
        const line = c.base + w.line - 1;
        c.line = line;
        const text = try c.litText(w) orelse return c.fail("a body must be in braces", .{});
        var p: interp.Parser = .{ .a = c.a, .src = text };
        const script = p.parseScript(false) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TclError => return c.fail("{s}", .{p.message}),
        };
        c.mask = mask;
        c.depth += 1;
        const count = c.locals.items.len;
        try c.body(script, line);
        // A variable that starts in a branch is not set on all paths.
        c.locals.shrinkRetainingCapacity(count);
        c.depth -= 1;
    }

    fn truthy(c: *Compiler, v: V) Error!u16 {
        if (v.kind == .feature) return c.fail("a feature is not a condition; compare it with a name", .{});
        return c.emit(.{ .code = .truthy, .a = v.reg });
    }

    /// The value of one word of a command.
    fn word(c: *Compiler, w: *const interp.Word) Error!V {
        if (w.expand) return c.fail("{{*}} is not allowed", .{});
        switch (w.kind) {
            .lit => |v| return c.number(v),
            .single => |part| switch (part) {
                .variable => |r| return c.variable(r),
                .script => |s| return c.subst(s),
                .lit => |s| return c.number(.{ .str = s }),
            },
            .multi => return c.fail("a word that joins texts is not allowed", .{}),
        }
    }

    fn number(c: *Compiler, v: Value) Error!V {
        const n = v.asNumber() orelse return c.fail("\"{s}\" is not a number", .{try c.it.str(v)});
        return switch (n) {
            .int => |i| .{ .reg = try c.konst(@floatFromInt(i)), .kind = .int },
            .double => |d| .{ .reg = try c.konst(d), .kind = .double },
            else => unreachable,
        };
    }

    fn variable(c: *Compiler, r: interp.VarRef) Error!V {
        if (r.index != null) return c.fail("arrays are not allowed", .{});
        if (c.lookup(r.name)) |l| return l.v;
        return c.fail("variable \"{s}\" is not set on all paths to this line", .{r.name});
    }

    /// A command substitution: `[expr {...}]`, `[noise3 x y z]`, or
    /// `[noise2 x y]`.
    fn subst(c: *Compiler, s: *interp.Script) Error!V {
        if (s.cmds.len != 1) return c.fail("a substitution holds one command", .{});
        const w = s.cmds[0].words;
        const name = try c.litText(&w[0]) orelse return c.fail("the command name must be a plain word", .{});
        if (std.mem.eql(u8, name, "expr")) {
            if (w.len != 2) return c.fail("expr needs one braced expression", .{});
            const text = try c.litText(&w[1]) orelse return c.fail("expr needs one braced expression", .{});
            return c.exprText(text);
        }
        if (std.mem.eql(u8, name, "noise3") or std.mem.eql(u8, name, "noise2")) {
            const want: usize = if (name[5] == '3') 4 else 3;
            if (w.len != want) return c.fail("{s} needs {d} values", .{ name, want - 1 });
            var args: [3]u16 = undefined;
            for (w[1..], 0..) |*aw, i| args[i] = try c.num(try c.word(aw));
            if (want == 3) args[2] = try c.konst(0);
            return .{ .reg = try c.emit(.{ .code = .noise3, .a = args[0], .b = args[1], .c = args[2], .m = try c.effMask() }), .kind = .double };
        }
        return c.fail("\"{s}\" is not allowed in a point proc", .{name});
    }

    fn num(c: *Compiler, v: V) Error!u16 {
        if (v.kind == .feature) return c.fail("a feature is not a number; compare it with a name", .{});
        return v.reg;
    }

    fn exprText(c: *Compiler, text: []const u8) Error!V {
        const node = expr.compile(c.it, text) catch |e| {
            if (e != error.TclError) return e;
            return c.fail("{s}", .{try c.it.str(c.it.result)});
        };
        return c.lower(node);
    }

    fn featureId(c: *Compiler, node: *const expr.Node) Error!u16 {
        if (node.* != .constant or node.constant != .str) return c.fail("compare a feature with a name in quotes", .{});
        const want = node.constant.str;
        for (c.features, 0..) |f, i| {
            if (std.mem.eql(u8, f, want)) return c.konst(@floatFromInt(i));
        }
        return c.fail("\"{s}\" is not a feature name", .{want});
    }

    fn isFeature(c: *Compiler, node: *const expr.Node) bool {
        if (node.* != .variable or node.variable.index != null) return false;
        const l = c.lookup(node.variable.name) orelse return false;
        return l.v.kind == .feature;
    }

    fn lower(c: *Compiler, node: *const expr.Node) Error!V {
        switch (node.*) {
            .constant => |v| {
                if (v == .str) return c.fail("the text \"{s}\" is allowed only in a compare with a feature", .{v.str});
                return c.number(v);
            },
            .variable => |r| return c.variable(r),
            .script => |s| return c.subst(s),
            .parts => return c.fail("a text with substitutions is not allowed", .{}),
            .call => |f| return c.fail("the function \"{s}\" is not allowed", .{f.name}),
            .unary => |u| {
                const x = try c.lower(u.a);
                const r = try c.num(x);
                return switch (u.op) {
                    .neg => .{ .reg = try c.emit(.{ .code = .neg, .a = r }), .kind = x.kind },
                    .pos => x,
                    .not => .{ .reg = try c.emit(.{ .code = .lnot, .a = r }), .kind = .int },
                    .bitnot => c.fail("\"~\" is not allowed in a point proc", .{}),
                };
            },
            .ternary => |t| {
                const cond = try c.truthy(try c.lower(t[0]));
                const x = try c.lower(t[1]);
                const y = try c.lower(t[2]);
                return .{ .reg = try c.emit(.{ .code = .select, .a = cond, .b = try c.num(x), .c = try c.num(y) }), .kind = x.kind.merge(y.kind) };
            },
            .binary => |b| {
                const is_eq = b.op == .eq or b.op == .streq;
                const is_ne = b.op == .ne or b.op == .strne;
                const fa = c.isFeature(b.a);
                const fb = c.isFeature(b.b);
                if (fa or fb) {
                    if (!is_eq and !is_ne) return c.fail("a feature allows only eq, ne, ==, and !=", .{});
                    const x = if (fa) (try c.lower(b.a)).reg else try c.featureId(b.a);
                    const y = if (fb) (try c.lower(b.b)).reg else try c.featureId(b.b);
                    return .{ .reg = try c.emit(.{ .code = if (is_eq) .eq else .ne, .a = x, .b = y }), .kind = .int };
                }
                const x = try c.lower(b.a);
                const y = try c.lower(b.b);
                const xr = try c.num(x);
                const yr = try c.num(y);
                const ints = x.kind == .int and y.kind == .int;
                const kind = x.kind.arith(y.kind);
                if (kind == .mixed and (b.op == .div or b.op == .mod or b.op == .pow)) {
                    return c.fail("\"{s}\" has a value that is an integer for some points only; use double() or int()", .{b.op.text()});
                }
                const code: Code = switch (b.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    // Two integers divide as integers, as in Tcl.
                    .div => if (ints) .idiv else .div,
                    .mod => if (ints) .imod else return c.fail("\"%\" needs two integers", .{}),
                    .pow => {
                        const r = try c.emit(.{ .code = .fn2, .f = .pow, .a = xr, .b = yr });
                        // Two integers give an integer, as in Tcl.
                        return .{ .reg = if (ints) try c.emit(.{ .code = .fn1, .f = .int, .a = r }) else r, .kind = kind };
                    },
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                    .eq => .eq,
                    .ne => .ne,
                    .land, .lor => {
                        const tx = try c.emit(.{ .code = .truthy, .a = xr });
                        const ty = try c.emit(.{ .code = .truthy, .a = yr });
                        return .{ .reg = try c.emit(.{ .code = if (b.op == .land) .land else .lor, .a = tx, .b = ty }), .kind = .int };
                    },
                    .streq, .strne => return c.fail("use == and != for numbers; eq and ne compare a feature with a name", .{}),
                    else => return c.fail("\"{s}\" is not allowed in a point proc", .{b.op.text()}),
                };
                const cmp = switch (b.op) {
                    .lt, .le, .gt, .ge, .eq, .ne => true,
                    else => false,
                };
                return .{ .reg = try c.emit(.{ .code = code, .a = xr, .b = yr }), .kind = if (cmp) .int else kind };
            },
            .func => |f| {
                var args: [3]V = undefined;
                if (f.args.len > 3 and f.f != .min and f.f != .max) return c.fail("too many arguments", .{});
                switch (f.f) {
                    .min, .max => {
                        var acc = try c.lower(f.args[0]);
                        _ = try c.num(acc);
                        for (f.args[1..]) |an| {
                            const y = try c.lower(an);
                            acc = .{ .reg = try c.emit(.{ .code = .fn2, .f = f.f, .a = acc.reg, .b = try c.num(y) }), .kind = acc.kind.merge(y.kind) };
                        }
                        return acc;
                    },
                    .rand, .srand => return c.fail("{s}() depends on the order of the points; use noise3", .{@tagName(f.f)}),
                    .isqrt => return c.fail("isqrt() is not allowed in a point proc", .{}),
                    else => {},
                }
                for (f.args, 0..) |an, i| {
                    args[i] = try c.lower(an);
                    _ = try c.num(args[i]);
                }
                const a0 = args[0].reg;
                switch (f.f) {
                    .bool => return .{ .reg = try c.emit(.{ .code = .truthy, .a = a0 }), .kind = .int },
                    .abs => return .{ .reg = try c.emit(.{ .code = .fn1, .f = .abs, .a = a0 }), .kind = args[0].kind },
                    .int, .wide, .entier => return .{ .reg = try c.emit(.{ .code = .fn1, .f = .int, .a = a0 }), .kind = .int },
                    .round => return .{ .reg = try c.emit(.{ .code = .fn1, .f = .round, .a = a0 }), .kind = .int },
                    .atan2, .fmod, .hypot, .pow, .noise2 => return .{ .reg = try c.emit(.{ .code = .fn2, .f = f.f, .a = a0, .b = args[1].reg }), .kind = .double },
                    .clamp => return .{ .reg = try c.emit(.{ .code = .clamp, .a = a0, .b = args[1].reg, .c = args[2].reg }), .kind = .double },
                    .lerp => return .{ .reg = try c.emit(.{ .code = .lerp, .a = a0, .b = args[1].reg, .c = args[2].reg }), .kind = .double },
                    .noise3 => return .{ .reg = try c.emit(.{ .code = .noise3, .a = a0, .b = args[1].reg, .c = args[2].reg, .m = try c.effMask() }), .kind = .double },
                    else => return .{ .reg = try c.emit(.{ .code = .fn1, .f = f.f, .a = a0 }), .kind = .double },
                }
            },
        }
    }
};

/// Checks and compiles a point proc. After error.TclError, the result
/// of the interpreter names the line and the reason.
pub fn compile(it: *Interp, name: []const u8, params: Value, body_text: []const u8, features: []const []const u8) Error!*Program {
    const a = it.alloc();
    var c: Compiler = .{ .it = it, .a = a, .name = name, .features = features };
    var fields: std.ArrayList(Field) = .empty;
    for (try it.list(params)) |pv| {
        const pname = try it.str(pv);
        const f = std.meta.stringToEnum(Field, pname) orelse
            return c.fail("parameter \"{s}\" is not a point field (x y z width height speed flow feature layer path dist)", .{pname});
        try fields.append(a, f);
        const r = if (f == .feature) try c.emit(.{ .code = .feature }) else try c.emit(.{ .code = .field, .col = @intFromEnum(f) });
        try c.locals.append(a, .{ .name = pname, .v = .{ .reg = r, .kind = if (f == .feature) .feature else .double }, .depth = 0 });
    }
    var p: interp.Parser = .{ .a = a, .src = body_text };
    const script = p.parseScript(false) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TclError => {
            c.line = p.line;
            return c.fail("{s}", .{p.message});
        },
    };
    try c.body(script, 1);
    for (c.outs, 0..) |r, k| {
        if (r != none) try c.ops.append(a, .{ .code = .store, .a = r, .col = @intCast(k) });
    }
    const prog = try a.create(Program);
    prog.* = .{ .name = name, .setup = c.setup.items, .ops = c.ops.items, .regs = c.regs, .params = fields.items };
    return prog;
}

// ---- The commands of the interpreter ----

/// The point procs of one interpreter, and the outputs of the point
/// that the slow path works on.
pub const State = struct {
    programs: std.StringHashMapUnmanaged(*Program) = .empty,
    features: []const []const u8 = &default_features,
    cur: [out_count]f64 = @splat(0),

    pub fn program(s: *State, name: []const u8) ?*const Program {
        return s.programs.get(name);
    }
};

/// Adds `point proc` and the output commands to an interpreter. The
/// state must outlive the interpreter.
pub fn install(it: *Interp, state: *State) Allocator.Error!void {
    it.user = state;
    it.points = state;
    try it.register("point", cmdPoint);
    inline for (.{ "offset", "move", "width", "flow", "speed", "skip" }) |n| try it.register(n, cmdOutput);
}

/// A copy of the table of programs in the arena of the copier.
pub fn copyPrograms(s: *State, c: *@import("compact.zig").Copier) Allocator.Error!@TypeOf(s.programs) {
    var out: @TypeOf(s.programs) = .empty;
    try out.ensureTotalCapacity(c.a, s.programs.count());
    var iter = s.programs.iterator();
    while (iter.next()) |e| {
        const p = try c.a.create(Program);
        p.* = e.value_ptr.*.*;
        p.setup = try c.a.dupe(Op, p.setup);
        p.ops = try c.a.dupe(Op, p.ops);
        p.params = try c.a.dupe(Field, p.params);
        try c.text(&p.name);
        const gop = out.getOrPutAssumeCapacity(e.key_ptr.*);
        gop.value_ptr.* = p;
        try c.text(@constCast(gop.key_ptr));
    }
    return out;
}

fn stateOf(it: *Interp) *State {
    return @ptrCast(@alignCast(it.user.?));
}

fn cmdPoint(it: *Interp, argv: []const Value, _: ?*interp.Cmd) Error!Value {
    if (argv.len != 5 or !std.mem.eql(u8, try it.str(argv[1]), "proc")) return it.wrongArgs("point proc name params body");
    const name = try it.alloc().dupe(u8, try it.str(argv[2]));
    // The slow path: a normal proc of the same name.
    _ = try it.callWords(&.{ .{ .str = "proc" }, argv[2], argv[3], argv[4] });
    const state = stateOf(it);
    const prog = try compile(it, name, argv[3], try it.str(argv[4]), state.features);
    try state.programs.put(it.alloc(), name, prog);
    return Value.empty;
}

fn toF(it: *Interp, v: Value) Error!f64 {
    return switch (v.asNumber() orelse return it.fail("expected floating-point number but got \"{s}\"", .{try it.str(v)})) {
        .int => |i| @floatFromInt(i),
        .double => |d| d,
        else => unreachable,
    };
}

fn cmdOutput(it: *Interp, argv: []const Value, _: ?*interp.Cmd) Error!Value {
    const s = stateOf(it);
    const name = try it.str(argv[0]);
    if (std.mem.eql(u8, name, "skip")) {
        if (argv.len != 1) return it.wrongArgs("skip");
        s.cur[@intFromEnum(Out.skip)] = 1;
    } else if (std.mem.eql(u8, name, "move")) {
        if (argv.len != 3) return it.wrongArgs("move dx dy");
        s.cur[@intFromEnum(Out.move_x)] = try toF(it, argv[1]);
        s.cur[@intFromEnum(Out.move_y)] = try toF(it, argv[2]);
    } else {
        if (argv.len != 2) return it.fail("wrong # args: should be \"{s} value\"", .{name});
        s.cur[@intFromEnum(std.meta.stringToEnum(Out, name).?)] = try toF(it, argv[1]);
    }
    return Value.empty;
}

/// The slow path: calls the proc once for each point in the normal
/// interpreter. It gives the same outputs as `Program.run`.
pub fn runSlow(it: *Interp, name: []const u8, pts: *const Points) Error!void {
    const s = stateOf(it);
    const prog = s.programs.get(name) orelse return it.fail("\"{s}\" is not a point proc", .{name});
    var argv: [field_count + 1]Value = undefined;
    argv[0] = .{ .str = prog.name };
    const command = it.findCommand(prog.name) orelse return it.fail("invalid command name \"{s}\"", .{prog.name});
    const saved_seed = it.noise_seed;
    it.noise_seed = pts.seed;
    defer it.noise_seed = saved_seed;
    for (0..pts.len) |i| {
        for (prog.params, 1..) |f, k| {
            if (f == .feature) {
                const id: usize = if (pts.feature) |col| col[i] else 0;
                argv[k] = .{ .str = if (id < s.features.len) s.features[id] else "" };
            } else {
                argv[k] = .{ .double = if (pts.in[@intFromEnum(f)]) |col| col[i] else 0 };
            }
        }
        for (&s.cur, pts.out) |*c, col| c.* = if (col) |o| o[i] else 0;
        _ = try it.call(command, argv[0 .. prog.params.len + 1], null);
        for (s.cur, pts.out) |c, col| if (col) |o| {
            o[i] = c;
        };
    }
    bound(pts);
}

// ---- Tests ----

const fuzzy =
    \\point proc fuzzy {x y z feature} {
    \\    if {$feature ne "outer_wall"} { return }
    \\    set n [noise3 $x $y [expr {$z * 4}]]
    \\    offset [expr {$n * 0.3}]
    \\}
;

const TestPoints = struct {
    x: []f64,
    y: []f64,
    z: []f64,
    w: []f64,
    feature: []u8,

    fn init(a: Allocator, n: usize) !TestPoints {
        const t: TestPoints = .{ .x = try a.alloc(f64, n), .y = try a.alloc(f64, n), .z = try a.alloc(f64, n), .w = try a.alloc(f64, n), .feature = try a.alloc(u8, n) };
        var seed: u64 = 12345;
        for (0..n) |i| {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            const fi: f64 = @floatFromInt(i);
            t.x[i] = 100 + 40 * @cos(fi * 0.01) + @as(f64, @floatFromInt(seed >> 40)) * 1e-7;
            t.y[i] = 100 + 40 * @sin(fi * 0.01);
            t.z[i] = 0.2 * @floor(fi / 500);
            t.w[i] = 0.4 + 0.05 * @sin(fi * 0.3);
            t.feature[i] = @intCast((seed >> 33) % 3);
        }
        return t;
    }

    fn points(t: TestPoints, outs: *[out_count][]f64) Points {
        var p: Points = .{ .len = t.x.len, .feature = t.feature };
        p.in[@intFromEnum(Field.x)] = t.x;
        p.in[@intFromEnum(Field.y)] = t.y;
        p.in[@intFromEnum(Field.z)] = t.z;
        p.in[@intFromEnum(Field.width)] = t.w;
        for (&p.out, outs) |*o, col| o.* = col;
        return p;
    }
};

/// Runs a point proc on both paths and expects equal bits in all outputs.
fn expectSame(script: []const u8, name: []const u8, n: usize) !void {
    return expectSameJit(script, name, n, false);
}

/// `expectSame` with the slow path in the JIT with tier 2 when `jit`.
fn expectSameJit(script: []const u8, name: []const u8, n: usize, jit: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{};
    var it: Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try install(&it, &state);
    if (jit and !it.enableJit(.{ .threshold = 0, .tier2 = true, .tier2_count = 2 })) return error.SkipZigTest;
    _ = it.eval(script) catch |e| {
        std.debug.print("{s}\n", .{try it.str(it.result)});
        return e;
    };
    const t = try TestPoints.init(a, n);
    var fast: [out_count][]f64 = undefined;
    var slow: [out_count][]f64 = undefined;
    for (&fast, &slow, 0..) |*f, *s, k| {
        f.* = try a.alloc(f64, n);
        s.* = try a.alloc(f64, n);
        // The width starts at the width of the point; the others at 0.
        const start: ?[]f64 = if (k == @intFromEnum(Out.width)) t.w else null;
        for (f.*, s.*, 0..) |*fv, *sv, i| {
            fv.* = if (start) |col| col[i] else 0;
            sv.* = fv.*;
        }
    }
    const prog = state.program(name).?;
    const fp = t.points(&fast);
    prog.run(&fp, try a.alloc(f64, prog.scratchLen()));
    const sp = t.points(&slow);
    runSlow(&it, name, &sp) catch |e| {
        std.debug.print("{s}\n", .{try it.str(it.result)});
        return e;
    };
    var changed: usize = 0;
    for (fast, slow) |f, s| {
        for (f, s) |fv, sv| {
            try std.testing.expectEqual(@as(u64, @bitCast(sv)), @as(u64, @bitCast(fv)));
            if (fv != 0) changed += 1;
        }
    }
    try std.testing.expect(changed > 0);
}

test "the fuzzy skin proc gives equal results on both paths" {
    try expectSame(fuzzy, "fuzzy", 5000);
}

test "both point procs give equal results with the slow path in the JIT" {
    try expectSameJit(fuzzy, "fuzzy", 3000, true);
    try expectSameJit(branches, "p", 3000, true);
}

const branches =
    \\point proc p {x y z width feature} {
    \\    set k 2
    \\    if {$feature eq "infill"} {
    \\        skip
    \\        return
    \\    } elseif {$feature == "skin" && $z > 0.5} {
    \\        set k [expr {$k + 7 / 2}]
    \\        flow [expr {1.0 + 0.1 * sin($x)}]
    \\    } else {
    \\        if {$x > 100} { set k [expr {$k * 3}] }
    \\        width [expr {$width * ($y > 100 ? 1.1 : 0.9)}]
    \\    }
    \\    move [expr {0.01 * $k}] [expr {clamp(noise3($x, $y, $z), -0.5, 0.5)}]
    \\    if {$k % 2 == 0} { return }
    \\    speed [expr {max(10, min(60, hypot($x - 100, $y - 100)))}]
    \\}
;

test "branches, locals, and outputs give equal results on both paths" {
    try expectSame(
        \\point proc p {x y z width feature} {
        \\    set k 2
        \\    if {$feature eq "infill"} {
        \\        skip
        \\        return
        \\    } elseif {$feature == "skin" && $z > 0.5} {
        \\        set k [expr {$k + 7 / 2}]
        \\        flow [expr {1.0 + 0.1 * sin($x)}]
        \\    } else {
        \\        if {$x > 100} { set k [expr {$k * 3}] }
        \\        width [expr {$width * ($y > 100 ? 1.1 : 0.9)}]
        \\    }
        \\    move [expr {0.01 * $k}] [expr {clamp(noise3($x, $y, $z), -0.5, 0.5)}]
        \\    if {$k % 2 == 0} { return }
        \\    speed [expr {max(10, min(60, hypot($x - 100, $y - 100)))}]
        \\}
    , "p", 3000);
}

test "an output column that is also an input column reads the old input" {
    var it: Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    var state: State = .{};
    try install(&it, &state);
    _ = try it.eval("point proc half {x} { offset [expr {$x * 0.5}]; move [expr {$x * 0.25}] 0 }");
    const prog = state.program("half").?;
    var col: [block + 3]f64 = undefined;
    var mx: [block + 3]f64 = undefined;
    var my: [block + 3]f64 = undefined;
    for (&col, &mx, &my, 0..) |*c, *m, *o, i| {
        c.* = @as(f64, @floatFromInt(i % 7)) * 0.01;
        m.* = 0;
        o.* = 0;
    }
    const start = col;
    var pts: Points = .{ .len = col.len };
    pts.in[@intFromEnum(Field.x)] = &col;
    pts.out[@intFromEnum(Out.offset)] = &col;
    pts.out[@intFromEnum(Out.move_x)] = &mx;
    pts.out[@intFromEnum(Out.move_y)] = &my;
    const scratch = try std.testing.allocator.alloc(f64, prog.scratchLen());
    defer std.testing.allocator.free(scratch);
    prog.run(&pts, scratch);
    for (col, mx, start) |c, m, x| {
        try std.testing.expectEqual(x * 0.5, c);
        try std.testing.expectEqual(x * 0.25, m);
    }
}

test "the check names the line and the reason" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "point proc p {x} {\n set i 0\n while {$i < 3} { incr i }\n}", "point proc p, line 3: \"while\" is not allowed in a point proc" },
        .{ "point proc p {x} {\n offset [string length $x]\n}", "point proc p, line 2: \"string\" is not allowed in a point proc" },
        .{ "point proc p {x q} {}", "point proc p, line 1: parameter \"q\" is not a point field (x y z width height speed flow feature layer path dist)" },
        .{ "point proc p {x} {\n if {$x > 1} { set a 1 }\n offset $a\n}", "point proc p, line 3: variable \"a\" is not set on all paths to this line" },
        .{ "point proc p {x feature} {\n\n if {$feature eq \"wall\"} { skip }\n}", "point proc p, line 3: \"wall\" is not a feature name" },
        .{ "point proc p {x} {\n offset [expr {rand()}]\n}", "point proc p, line 2: rand() depends on the order of the points; use noise3" },
        .{ "point proc p {x} {\n return 5\n}", "point proc p, line 2: return with a value is not allowed" },
        .{ "point proc p {x} {\n if {$x > 1} {\n  offset 1\n  puts hi\n }\n}", "point proc p, line 4: \"puts\" is not allowed in a point proc" },
    };
    for (cases) |c| {
        var state: State = .{};
        var it: Interp = undefined;
        try it.init(std.testing.allocator);
        defer it.deinit();
        try install(&it, &state);
        try std.testing.expectError(error.TclError, it.eval(c[0]));
        try std.testing.expectEqualStrings(c[1], try it.str(it.result));
    }
}

test "the outputs of a point proc have limits, and the seed changes the noise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{};
    var it: Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try install(&it, &state);
    _ = try it.eval(
        \\point proc wild {x y z width} {
        \\    offset [expr {100.0 * ($x > 0 ? 1 : -1)}]
        \\    move 3.0 4.0
        \\    width [expr {$width / ($x - $x)}]
        \\    flow [expr {noise3($x, $y, $z)}]
        \\}
    );
    const n = 2000;
    const t = try TestPoints.init(a, n);
    const prog = state.program("wild").?;
    var runs: [3][out_count][]f64 = undefined;
    for (&runs, 0..) |*outs, r| {
        for (outs, 0..) |*col, k| {
            col.* = try a.alloc(f64, n);
            for (col.*, 0..) |*v, i| v.* = if (k == @intFromEnum(Out.width)) t.w[i] else 0;
        }
        var pts = t.points(outs);
        // Runs 0 and 1 use one seed on the two paths; run 2 uses a new seed.
        pts.seed = if (r == 2) 99 else 7;
        if (r == 1) try runSlow(&it, "wild", &pts) else prog.run(&pts, try a.alloc(f64, prog.scratchLen()));
    }
    var differ = false;
    for (0..n) |i| {
        const w = t.w[i];
        const o = runs[0];
        try std.testing.expect(@abs(o[@intFromEnum(Out.offset)][i]) <= w);
        const mx = o[@intFromEnum(Out.move_x)][i];
        const my = o[@intFromEnum(Out.move_y)][i];
        try std.testing.expect(@sqrt(mx * mx + my * my) <= w * 1.000001);
        try std.testing.expectEqual(w, o[@intFromEnum(Out.width)][i]);
        for (runs[0], runs[1]) |f, s| try std.testing.expectEqual(@as(u64, @bitCast(f[i])), @as(u64, @bitCast(s[i])));
        if (runs[0][@intFromEnum(Out.flow)][i] != runs[2][@intFromEnum(Out.flow)][i]) differ = true;
    }
    try std.testing.expect(differ);
}

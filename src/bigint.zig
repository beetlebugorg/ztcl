//! Integers above 64 bits.
//!
//! A big integer has no value kind of its own. It is a string with the
//! canonical decimal text, and a script cannot see a difference. An
//! integer that fits in 64 bits is always an `int`, so the fast paths
//! of the interpreter stay as they were. Only an overflow comes here.
//!
//! Each operation reads the operands into `std.math.big.int.Managed`,
//! computes the result, and writes the text. The memory of the
//! operation goes through the counter of the interpreter and is free
//! at the end. An operation uses steps in proportion to the square of
//! the operand size, and a result has at most `max_bits` bits.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const expr = @import("expr.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Error = interp.Error;
const Big = std.math.big.int.Managed;

/// The largest size of a big integer. Tcl has no fixed limit. This
/// limit keeps the time of one operation small.
pub const max_bits = 1 << 20;

const too_large = "integer value too large to represent";

fn gpa(it: *Interp) std.mem.Allocator {
    return it.counter.allocator();
}

fn mem(e: anyerror) Error {
    return if (e == error.OutOfMemory) error.OutOfMemory else unreachable;
}

/// Uses steps for an operation on `limbs` limbs.
fn charge(it: *Interp, limbs: usize) Error!void {
    const cost = limbs * limbs / 64 + 1;
    if (it.step_limit < cost) {
        it.step_limit = 0;
        return it.fail("step limit reached", .{});
    }
    it.step_limit -= cost;
}

const Parts = struct { neg: bool, base: u8, body: []const u8 };

/// Splits integer text by the rules of `value.parseInt`, or gives null
/// when the text is not an integer.
fn split(text: []const u8) ?Parts {
    var s = value.trimSpace(text);
    if (s.len == 0) return null;
    var neg = false;
    if (s[0] == '-' or s[0] == '+') {
        neg = s[0] == '-';
        s = s[1..];
    }
    if (s.len == 0) return null;
    var base: u8 = 10;
    if (s.len >= 2 and s[0] == '0') {
        switch (s[1]) {
            'x', 'X' => base = 16,
            'o', 'O' => base = 8,
            'b', 'B' => base = 2,
            else => {},
        }
        if (base != 10) {
            s = s[2..];
            if (s.len == 0) return null;
        } else {
            base = 8;
            s = s[1..];
        }
    }
    for (s) |c| {
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        if (d >= base) return null;
    }
    return .{ .neg = neg, .base = base, .body = s };
}

/// True for integer text of any size.
pub fn isIntegerText(text: []const u8) bool {
    return split(text) != null;
}

fn parse(it: *Interp, text: []const u8) Error!?Big {
    const p = split(text) orelse return null;
    const per_digit: usize = switch (p.base) {
        2 => 1,
        8 => 3,
        10 => 4,
        else => 4,
    };
    if ((p.body.len -| 1) * (if (p.base == 10) 3 else per_digit) > max_bits) return null;
    var b = Big.init(gpa(it)) catch |e| return mem(e);
    errdefer b.deinit();
    try charge(it, p.body.len / 16);
    b.setString(p.base, p.body) catch |e| return mem(e);
    if (p.neg) b.negate();
    if (b.bitCountAbs() > max_bits) {
        b.deinit();
        return null;
    }
    return b;
}

/// The value of integer text that does not fit in 64 bits: the
/// canonical text, or an `int` for text with leading zeros. Null when
/// the text is above the size limit.
pub fn canonical(it: *Interp, text: []const u8) Error!?Value {
    const s = value.trimSpace(text);
    if (isCanonical(s)) return .{ .str = s };
    var b = try parse(it, s) orelse return null;
    defer b.deinit();
    return try finish(it, &b);
}

fn isCanonical(s: []const u8) bool {
    const d = if (s.len > 0 and s[0] == '-') s[1..] else s;
    if (d.len == 0 or d[0] == '0' or d.len * 3 > max_bits) return false;
    for (d) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn load(it: *Interp, v: Value) Error!Big {
    switch (v) {
        .int => |i| return Big.initSet(gpa(it), i) catch |e| return mem(e),
        .str => |s| return (try parse(it, s)) orelse it.fail(too_large, .{}),
        else => unreachable,
    }
}

/// The value of a result: an `int` when it fits, or else the text.
fn finish(it: *Interp, b: *Big) Error!Value {
    if (b.fits(i64)) return .{ .int = b.toInt(i64) catch unreachable };
    if (b.bitCountAbs() > max_bits) return it.fail(too_large, .{});
    try charge(it, b.len());
    return .{ .str = b.toString(it.alloc(), 10, .lower) catch |e| return mem(e) };
}

fn isNegative(v: Value) bool {
    return switch (v) {
        .int => |i| i < 0,
        .str => |s| s.len > 0 and value.trimSpace(s)[0] == '-',
        else => unreachable,
    };
}

/// A binary operator on two integers. Each is an `int` or big text.
pub fn binary(it: *Interp, op: expr.BinOp, x: Value, y: Value) Error!Value {
    var a = try load(it, x);
    defer a.deinit();
    var b = try load(it, y);
    defer b.deinit();
    var r = Big.init(gpa(it)) catch |e| return mem(e);
    defer r.deinit();
    try charge(it, @max(a.len(), b.len()));
    switch (op) {
        .add => r.add(&a, &b) catch |e| return mem(e),
        .sub => r.sub(&a, &b) catch |e| return mem(e),
        .mul => {
            if (a.bitCountAbs() + b.bitCountAbs() > max_bits + 1) return it.fail(too_large, .{});
            try charge(it, a.len() + b.len());
            r.mul(&a, &b) catch |e| return mem(e);
        },
        .div, .mod => {
            if (b.eqlZero()) return it.fail("divide by zero", .{});
            var q = Big.init(gpa(it)) catch |e| return mem(e);
            defer q.deinit();
            var m = Big.init(gpa(it)) catch |e| return mem(e);
            defer m.deinit();
            q.divFloor(&m, &a, &b) catch |e| return mem(e);
            return finish(it, if (op == .div) &q else &m);
        },
        .pow => return power(it, &a, &b, &r),
        .shl => {
            if (!b.isPositive() and !b.eqlZero()) return it.fail("negative shift argument", .{});
            if (a.eqlZero()) return .{ .int = 0 };
            const n = b.toInt(usize) catch return it.fail(too_large, .{});
            if (n > max_bits or n + a.bitCountAbs() > max_bits) return it.fail(too_large, .{});
            r.shiftLeft(&a, n) catch |e| return mem(e);
        },
        .shr => {
            if (!b.isPositive() and !b.eqlZero()) return it.fail("negative shift argument", .{});
            const n = b.toInt(usize) catch return .{ .int = if (a.isPositive()) 0 else -1 };
            if (n >= a.bitCountAbs() + 1) return .{ .int = if (a.isPositive() or a.eqlZero()) 0 else -1 };
            r.shiftRight(&a, n) catch |e| return mem(e);
        },
        .bitand, .bitor, .bitxor => bitOp(it, op, &a, &b, &r) catch |e| return mem(e),
        else => unreachable,
    }
    return finish(it, &r);
}

/// Sets `m` to ~v. The value is -v - 1.
fn invert(m: *Big, v: *const Big) !void {
    try m.copy(v.toConst());
    m.negate();
    try m.addScalar(m, -1);
}

/// A bit operator in two's complement. A negative operand x is ~y with
/// y not negative, so the operators run on values that are not negative.
fn bitOp(it: *Interp, op: expr.BinOp, a: *const Big, b: *const Big, r: *Big) !void {
    const an = !a.isPositive() and !a.eqlZero();
    const bn = !b.isPositive() and !b.eqlZero();
    var x = try Big.init(gpa(it));
    defer x.deinit();
    var y = try Big.init(gpa(it));
    defer y.deinit();
    var t = try Big.init(gpa(it));
    defer t.deinit();
    if (an) try invert(&x, a) else try x.copy(a.toConst());
    if (bn) try invert(&y, b) else try y.copy(b.toConst());
    var flip = false;
    switch (op) {
        .bitand => {
            if (an and bn) {
                try r.bitOr(&x, &y);
                flip = true;
            } else if (an or bn) {
                // The operand that is not negative, with the bits of
                // the inverted operand removed.
                const keep = if (an) &y else &x;
                const drop = if (an) &x else &y;
                try t.bitAnd(keep, drop);
                try r.bitXor(keep, &t);
            } else try r.bitAnd(&x, &y);
        },
        .bitor => {
            if (an and bn) {
                try r.bitAnd(&x, &y);
                flip = true;
            } else if (an or bn) {
                const neg = if (an) &x else &y;
                const pos = if (an) &y else &x;
                try t.bitAnd(neg, pos);
                try r.bitXor(neg, &t);
                flip = true;
            } else try r.bitOr(&x, &y);
        },
        else => {
            try r.bitXor(&x, &y);
            flip = an != bn;
        },
    }
    if (flip) {
        try t.copy(r.toConst());
        try invert(r, &t);
    }
}

fn power(it: *Interp, a: *Big, b: *Big, r: *Big) Error!Value {
    const odd = !b.eqlZero() and b.toConst().limbs[0] & 1 == 1;
    if (a.eqlZero()) {
        if (!b.isPositive() and !b.eqlZero()) return it.fail("exponentiation of zero by negative power", .{});
        return .{ .int = @intFromBool(b.eqlZero()) };
    }
    if (a.toConst().orderAgainstScalar(1) == .eq) return .{ .int = 1 };
    if (a.toConst().orderAgainstScalar(-1) == .eq) return .{ .int = if (odd) -1 else 1 };
    if (!b.isPositive() and !b.eqlZero()) return .{ .int = 0 };
    const n = b.toInt(u32) catch return it.fail("exponent too large", .{});
    if ((a.bitCountAbs() - 1) * @as(u64, n) > max_bits) return it.fail("exponent too large", .{});
    try charge(it, (a.bitCountAbs() * @as(usize, n)) / 64 + 1);
    r.pow(a, n) catch |e| return mem(e);
    return finish(it, r);
}

pub fn negate(it: *Interp, v: Value) Error!Value {
    var a = try load(it, v);
    defer a.deinit();
    a.negate();
    return finish(it, &a);
}

pub fn abs(it: *Interp, v: Value) Error!Value {
    return if (isNegative(v)) negate(it, v) else v;
}

pub fn bitNot(it: *Interp, v: Value) Error!Value {
    // ~x equals -x - 1.
    const n = try negate(it, v);
    return if (n == .int and n.int != std.math.minInt(i64)) .{ .int = n.int - 1 } else binary(it, .sub, n, .{ .int = 1 });
}

/// The whole part of a finite double as an integer of any size.
pub fn fromDouble(it: *Interp, d: f64) Error!Value {
    const t = @trunc(d);
    if (t > -9.2e18 and t < 9.2e18) return .{ .int = @intFromFloat(t) };
    const fr = std.math.frexp(@abs(t));
    const mant: u64 = @intFromFloat(std.math.ldexp(fr.significand, 53));
    var b = Big.initSet(gpa(it), mant) catch |e| return mem(e);
    defer b.deinit();
    const shift: i32 = fr.exponent - 53;
    if (shift > 0) {
        b.shiftLeft(&b, @intCast(shift)) catch |e| return mem(e);
    } else if (shift < 0) {
        b.shiftRight(&b, @intCast(-shift)) catch |e| return mem(e);
    }
    if (t < 0) b.negate();
    return finish(it, &b);
}

/// The low 64 bits of an integer, as a signed number.
pub fn low64(it: *Interp, v: Value) Error!i64 {
    if (v == .int) return v.int;
    var a = try load(it, v);
    defer a.deinit();
    var r = Big.init(gpa(it)) catch |e| return mem(e);
    defer r.deinit();
    r.truncate(&a, .signed, 64) catch |e| return mem(e);
    return r.toInt(i64) catch unreachable;
}

/// The floor of the square root of an integer that is not negative.
pub fn isqrt(it: *Interp, v: Value) Error!Value {
    var a = try load(it, v);
    defer a.deinit();
    var r = Big.init(gpa(it)) catch |e| return mem(e);
    defer r.deinit();
    try charge(it, a.len());
    r.sqrt(&a) catch |e| return mem(e);
    return finish(it, &r);
}

/// The order of two numbers, where at least one is big text. Null when
/// one is NaN. A double compares by its exact value.
pub fn compare(it: *Interp, x: Value, y: Value) Error!?std.math.Order {
    if (x == .double) {
        const o = try compare(it, y, x) orelse return null;
        return o.invert();
    }
    if (y == .double) {
        const d = y.double;
        if (std.math.isNan(d)) return null;
        if (std.math.isInf(d)) return if (d > 0) .lt else .gt;
        const whole = try fromDouble(it, d);
        const o = try compareInts(it, x, whole);
        if (o != .eq) return o;
        const frac = d - @trunc(d);
        return if (frac > 0) .lt else if (frac < 0) .gt else .eq;
    }
    return try compareInts(it, x, y);
}

fn compareInts(it: *Interp, x: Value, y: Value) Error!std.math.Order {
    if (x == .int and y == .int) return std.math.order(x.int, y.int);
    var a = try load(it, x);
    defer a.deinit();
    var b = try load(it, y);
    defer b.deinit();
    return a.order(b);
}

/// The digits of big text in a base, with a minus sign when negative.
pub fn digits(it: *Interp, v: Value, base: u8, case: std.fmt.Case) Error![]const u8 {
    var a = try load(it, v);
    defer a.deinit();
    try charge(it, a.len());
    return a.toString(it.alloc(), base, case) catch |e| return mem(e);
}

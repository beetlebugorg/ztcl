//! The math functions and commands of Tcl 9.1 that Tcl 8.6 does not have.
//!
//! TIP 521 adds the functions `isfinite`, `isinf`, `isnan`, `isnormal`,
//! `issubnormal`, and `isunordered`, and the command `fpclassify`. TIP 745
//! adds the functions of C99 (`acosh` to `trunc`) and the commands
//! `divmod`, `frexp`, `modf`, and `remquo`. Each function is a command in
//! `tcl::mathfunc`, so `expr` calls it as a function that a script made.
//! The commands `tcl::mathop::lt`, `gt`, `le`, and `ge` are the string
//! order operators of TIP 461. `tcl9.zig` puts these commands in the
//! command table only while the interpreter follows 9.1.
//!
//! The results and the error messages follow tclsh 9.1.0, with these
//! differences, where tclsh 9.1.0 gives a wrong result:
//! - `divmod` is exact for each pair of integers. tclsh gives a wrong
//!   quotient for `divmod 9223372036854775807 -1` and ends with SIGFPE
//!   for `divmod -9223372036854775808 -1`.
//! - `remquo` with a zero divisor or an infinite dividend is a domain
//!   error, as `remainder` is. tclsh gives NaN and an undefined quotient.
//! - The functions of doubles come from `std.math` of Zig, a port of the
//!   functions of musl. The last digit of a result can differ from
//!   tclsh: tclsh gives 3.0000000000000004 for `cbrt(27)`, and ztcl gives
//!   3.0. `gamma` of an integer is the nearest double to the factorial.
//! - tclsh gives the error "floating-point value too large to represent"
//!   for some results below 2**-1022, such as `asinh(1e-310)`. ztcl gives
//!   the result.
//!
//! `erf` and `erfc` are a port of the functions of musl
//! (`src/math/erf.c`, from FreeBSD msun and the fdlibm of Sun).
//! `docs/references/tcl.md` lists the source.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const expr = @import("expr.zig");
const mathns = @import("mathns.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

const Kind = enum {
    /// An argument of a function on doubles: NaN is an error.
    float,
    /// An argument of a function that classifies a number: NaN is a value.
    any,
};

/// The number of an argument, or the error of tclsh 9.1.
fn number(it: *Interp, v: Value, comptime kind: Kind) Error!Value {
    const n = (try expr.numberOf(it, v)) orelse {
        const what = if (kind == .float) "floating-point number" else "number";
        return it.failCode("TCL VALUE NUMBER", "expected " ++ what ++ " but got \"{s}\"", .{try it.str(v)});
    };
    if (kind == .float and n == .double and std.math.isNan(n.double)) return notANumber(it);
    return n;
}

fn notANumber(it: *Interp) Error {
    return it.failCode("TCL VALUE DOUBLE NAN", "floating point value is Not a Number", .{});
}

fn domainError(it: *Interp) Error {
    return it.failCode("ARITH DOMAIN {domain error: argument not in valid range}", "domain error: argument not in valid range", .{});
}

fn tooLarge(it: *Interp) Error {
    return it.failCode("ARITH IOVERFLOW {integer value too large to represent}", "integer value too large to represent", .{});
}

/// A number as a double. A big integer out of range is an infinity.
fn toF(n: Value) f64 {
    return switch (n) {
        .int => |i| @floatFromInt(i),
        .double => |d| d,
        .str => |s| std.fmt.parseFloat(f64, s) catch if (s.len > 0 and s[0] == '-') -std.math.inf(f64) else std.math.inf(f64),
        else => unreachable,
    };
}

fn float(it: *Interp, v: Value) Error!f64 {
    return toF(try number(it, v, .float));
}

/// An argument as a C int, as `Tcl_GetIntFromObj` reads it: a value from
/// -2**31 to 2**32-1, with the values above 2**31-1 taken modulo 2**32.
fn int32(it: *Interp, v: Value) Error!i32 {
    const n = (try expr.numberOf(it, v)) orelse
        return it.failCode("TCL VALUE NUMBER", "expected integer but got \"{s}\"", .{try it.str(v)});
    switch (n) {
        .int => |i| {
            if (i < std.math.minInt(i32) or i > std.math.maxInt(u32)) return tooLarge(it);
            return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(i)))));
        },
        .double => return it.failCode("TCL VALUE INTEGER", "expected integer but got \"{s}\"", .{try it.str(v)}),
        else => return tooLarge(it),
    }
}

fn arity(it: *Interp, argv: []const Value, comptime n: usize) Error!void {
    const name = try it.str(argv[0]);
    const short = if (std.mem.lastIndexOf(u8, name, "::")) |i| name[i + 2 ..] else name;
    if (argv.len - 1 < n) return it.failCode("TCL WRONGARGS", "not enough arguments for math function \"{s}\"", .{short});
    if (argv.len - 1 > n) return it.failCode("TCL WRONGARGS", "too many arguments for math function \"{s}\"", .{short});
}

fn result(it: *Interp, d: f64) Error!Value {
    if (std.math.isNan(d)) return domainError(it);
    return .{ .double = d };
}

fn bool2(b: bool) Value {
    return .{ .int = @intFromBool(b) };
}

const min_normal: f64 = 2.2250738585072014e-308;

/// A function of one double.
fn unary(comptime f: fn (f64) f64) interp.NativeFn {
    return struct {
        fn call(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            try arity(it, argv, 1);
            return result(it, f(try float(it, argv[1])));
        }
    }.call;
}

/// A function of two doubles.
fn binary(comptime f: fn (f64, f64) f64) interp.NativeFn {
    return struct {
        fn call(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            try arity(it, argv, 2);
            const x = try float(it, argv[1]);
            return result(it, f(x, try float(it, argv[2])));
        }
    }.call;
}

/// A test of one number. NaN is a value here.
fn test1(comptime f: fn (f64) bool) interp.NativeFn {
    return struct {
        fn call(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            try arity(it, argv, 1);
            return bool2(f(toF(try number(it, argv[1], .any))));
        }
    }.call;
}

fn acosh(x: f64) f64 {
    return std.math.acosh(x);
}
fn asinh(x: f64) f64 {
    return std.math.asinh(x);
}
fn atanh(x: f64) f64 {
    return std.math.atanh(x);
}
fn cbrt(x: f64) f64 {
    return std.math.cbrt(x);
}
fn exp2(x: f64) f64 {
    return @exp2(x);
}
fn expm1(x: f64) f64 {
    return std.math.expm1(x);
}
fn log1p(x: f64) f64 {
    return std.math.log1p(x);
}
fn log2(x: f64) f64 {
    // @log2 loses digits for a subnormal argument: scale it first.
    if (x > 0 and x < min_normal) return @log2(x * 0x1p54) - 54;
    return @log2(x);
}
fn trunc(x: f64) f64 {
    return @trunc(x);
}
/// The factorials 0! to 170! as the nearest doubles. A product of
/// doubles rounds at each step, so the table comes from exact integers.
const factorials = blk: {
    @setEvalBranchQuota(100_000);
    var t: [171]f64 = undefined;
    var n: u1100 = 1;
    for (&t, 0..) |*f, i| {
        if (i > 0) n *= i;
        f.* = @floatFromInt(n);
    }
    break :blk t;
};

fn gamma(x: f64) f64 {
    if (x >= 1 and x <= 171 and x == @trunc(x)) return factorials[@intFromFloat(x - 1)];
    return std.math.gamma(f64, x);
}
fn lgamma(x: f64) f64 {
    return std.math.lgamma(f64, x);
}
fn logb(x: f64) f64 {
    if (x == 0) return -std.math.inf(f64);
    if (std.math.isInf(x)) return std.math.inf(f64);
    return @floatFromInt(std.math.ilogb(x));
}
fn copysign(x: f64, y: f64) f64 {
    return std.math.copysign(x, y);
}
fn dim(x: f64, y: f64) f64 {
    return if (x > y) x - y else 0;
}
fn nextafter(x: f64, y: f64) f64 {
    return std.math.nextAfter(f64, x, y);
}
fn remainder(x: f64, y: f64) f64 {
    const r = remQuo(x, y) orelse return std.math.nan(f64);
    return r.rem;
}

fn isfinite(x: f64) bool {
    return std.math.isFinite(x);
}
fn isinf(x: f64) bool {
    return std.math.isInf(x);
}
fn isnan(x: f64) bool {
    return std.math.isNan(x);
}
fn isnormal(x: f64) bool {
    return std.math.isNormal(x);
}
fn issubnormal(x: f64) bool {
    return x != 0 and @abs(x) < min_normal;
}

const RemQuo = struct { rem: f64, quo: i64 };

/// The remainder of IEEE 754 and the low 3 bits of the quotient, with
/// the sign of the quotient, as C99 `remquo` gives. Null for a zero
/// divisor, an infinite dividend, or a NaN.
fn remQuo(x: f64, y: f64) ?RemQuo {
    if (std.math.isNan(x) or std.math.isNan(y) or y == 0 or std.math.isInf(x)) return null;
    const neg_q = std.math.signbit(x) != std.math.signbit(y);
    if (std.math.isInf(y)) return .{ .rem = x, .quo = 0 };
    const ax = @abs(x);
    const ay = @abs(y);
    // fmod is exact. With 8*ay above the largest double, ax < 8*ay.
    const y8 = ay * 8;
    var r = if (std.math.isInf(y8)) ax else @rem(ax, y8);
    var q: i64 = 0;
    // Each step subtracts a value within a factor of 2 of r: exact.
    if (r >= ay * 4) {
        r -= ay * 4;
        q += 4;
    }
    if (r >= ay * 2) {
        r -= ay * 2;
        q += 2;
    }
    if (r >= ay) {
        r -= ay;
        q += 1;
    }
    // Round the quotient to the nearest integer, ties to even.
    const rest = ay - r;
    if (r > rest or (r == rest and q & 1 == 1)) {
        r -= ay;
        q += 1;
    }
    q &= 7;
    return .{ .rem = if (std.math.signbit(x)) -r else r, .quo = if (neg_q) -q else q };
}

fn cmdLdexp(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    try arity(it, argv, 2);
    const x = try float(it, argv[1]);
    return result(it, std.math.ldexp(x, try int32(it, argv[2])));
}

fn cmdFma(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    try arity(it, argv, 3);
    const a = try float(it, argv[1]);
    const b = try float(it, argv[2]);
    return result(it, @mulAdd(f64, a, b, try float(it, argv[3])));
}

fn cmdSignbit(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    try arity(it, argv, 1);
    return switch (try number(it, argv[1], .any)) {
        .int => |i| bool2(i < 0),
        .double => |d| bool2(std.math.signbit(d)),
        .str => |s| bool2(s.len > 0 and s[0] == '-'),
        else => unreachable,
    };
}

fn cmdIsunordered(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    try arity(it, argv, 2);
    const x = toF(try number(it, argv[1], .any));
    const y = toF(try number(it, argv[2], .any));
    return bool2(std.math.isNan(x) or std.math.isNan(y));
}

fn cmdErf(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    try arity(it, argv, 1);
    return result(it, erf(try float(it, argv[1])));
}

fn cmdErfc(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    try arity(it, argv, 1);
    return result(it, erfc(try float(it, argv[1])));
}

fn pair(it: *Interp, a: Value, b: Value) Error!Value {
    return value.newList(it.alloc(), &.{ a, b });
}

fn cmdFpclassify(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("fpclassify floatValue");
    const x = toF(try number(it, argv[1], .any));
    const name: []const u8 = if (std.math.isNan(x))
        "nan"
    else if (std.math.isInf(x))
        "infinite"
    else if (x == 0)
        "zero"
    else if (@abs(x) < min_normal)
        "subnormal"
    else
        "normal";
    return .{ .str = name };
}

fn cmdDivmod(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3) return it.wrongArgs("divmod dividend divisor");
    const a = try number(it, argv[1], .any);
    const b = try number(it, argv[2], .any);
    if (a == .double) return it.failCode("TCL VALUE INTEGER", "dividend must be an integer", .{});
    if (b == .double) return it.failCode("TCL VALUE INTEGER", "divisor must be an integer", .{});
    const q = try expr.binaryOp(it, .div, a, b);
    return pair(it, q, try expr.binaryOp(it, .mod, a, b));
}

fn cmdFrexp(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("frexp floatValue");
    const x = try float(it, argv[1]);
    if (std.math.isInf(x)) return pair(it, .{ .double = x }, .{ .int = 0 });
    const f = std.math.frexp(x);
    return pair(it, .{ .double = f.significand }, .{ .int = f.exponent });
}

fn cmdModf(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("modf floatValue");
    const x = try float(it, argv[1]);
    if (std.math.isInf(x)) return pair(it, .{ .double = x }, .{ .double = std.math.copysign(@as(f64, 0), x) });
    const m = std.math.modf(x);
    return pair(it, .{ .double = m.ipart }, .{ .double = std.math.copysign(m.fpart, x) });
}

fn cmdRemquo(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3) return it.wrongArgs("remquo dividend divisor");
    const x = try float(it, argv[1]);
    const r = remQuo(x, try float(it, argv[2])) orelse return domainError(it);
    return pair(it, .{ .double = r.rem }, .{ .int = r.quo });
}

pub const Entry = struct { name: []const u8, f: interp.NativeFn };

/// The commands of this file, for the table of `tcl9.zig`.
pub const commands = [_]Entry{
    .{ .name = "tcl::mathfunc::acosh", .f = unary(acosh) },
    .{ .name = "tcl::mathfunc::asinh", .f = unary(asinh) },
    .{ .name = "tcl::mathfunc::atanh", .f = unary(atanh) },
    .{ .name = "tcl::mathfunc::cbrt", .f = unary(cbrt) },
    .{ .name = "tcl::mathfunc::copysign", .f = binary(copysign) },
    .{ .name = "tcl::mathfunc::dim", .f = binary(dim) },
    .{ .name = "tcl::mathfunc::erf", .f = cmdErf },
    .{ .name = "tcl::mathfunc::erfc", .f = cmdErfc },
    .{ .name = "tcl::mathfunc::exp2", .f = unary(exp2) },
    .{ .name = "tcl::mathfunc::expm1", .f = unary(expm1) },
    .{ .name = "tcl::mathfunc::fma", .f = cmdFma },
    .{ .name = "tcl::mathfunc::gamma", .f = unary(gamma) },
    .{ .name = "tcl::mathfunc::isfinite", .f = test1(isfinite) },
    .{ .name = "tcl::mathfunc::isinf", .f = test1(isinf) },
    .{ .name = "tcl::mathfunc::isnan", .f = test1(isnan) },
    .{ .name = "tcl::mathfunc::isnormal", .f = test1(isnormal) },
    .{ .name = "tcl::mathfunc::issubnormal", .f = test1(issubnormal) },
    .{ .name = "tcl::mathfunc::isunordered", .f = cmdIsunordered },
    .{ .name = "tcl::mathfunc::ldexp", .f = cmdLdexp },
    .{ .name = "tcl::mathfunc::lgamma", .f = unary(lgamma) },
    .{ .name = "tcl::mathfunc::log1p", .f = unary(log1p) },
    .{ .name = "tcl::mathfunc::log2", .f = unary(log2) },
    .{ .name = "tcl::mathfunc::logb", .f = unary(logb) },
    .{ .name = "tcl::mathfunc::nextafter", .f = binary(nextafter) },
    .{ .name = "tcl::mathfunc::remainder", .f = binary(remainder) },
    .{ .name = "tcl::mathfunc::signbit", .f = cmdSignbit },
    .{ .name = "tcl::mathfunc::trunc", .f = unary(trunc) },
    .{ .name = "tcl::mathop::lt", .f = mathns.chainCmd(.strlt) },
    .{ .name = "tcl::mathop::gt", .f = mathns.chainCmd(.strgt) },
    .{ .name = "tcl::mathop::le", .f = mathns.chainCmd(.strle) },
    .{ .name = "tcl::mathop::ge", .f = mathns.chainCmd(.strge) },
    .{ .name = "divmod", .f = cmdDivmod },
    .{ .name = "fpclassify", .f = cmdFpclassify },
    .{ .name = "frexp", .f = cmdFrexp },
    .{ .name = "modf", .f = cmdModf },
    .{ .name = "remquo", .f = cmdRemquo },
};

// The port of erf and erfc of musl. The comments and the constants are
// those of `src/math/erf.c` of musl:
//
// Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
// Developed at SunPro, a Sun Microsystems, Inc. business.
// Permission to use, copy, modify, and distribute this
// software is freely granted, provided that this notice
// is preserved.

const erx = 8.45062911510467529297e-01;
// Coefficients for approximation to erf on [0,0.84375]
const efx8 = 1.02703333676410069053e+00;
const pp0 = 1.28379167095512558561e-01;
const pp1 = -3.25042107247001499370e-01;
const pp2 = -2.84817495755985104766e-02;
const pp3 = -5.77027029648944159157e-03;
const pp4 = -2.37630166566501626084e-05;
const qq1 = 3.97917223959155352819e-01;
const qq2 = 6.50222499887672944485e-02;
const qq3 = 5.08130628187576562776e-03;
const qq4 = 1.32494738004321644526e-04;
const qq5 = -3.96022827877536812320e-06;
// Coefficients for approximation to erf in [0.84375,1.25]
const pa0 = -2.36211856075265944077e-03;
const pa1 = 4.14856118683748331666e-01;
const pa2 = -3.72207876035701323847e-01;
const pa3 = 3.18346619901161753674e-01;
const pa4 = -1.10894694282396677476e-01;
const pa5 = 3.54783043256182359371e-02;
const pa6 = -2.16637559486879084300e-03;
const qa1 = 1.06420880400844228286e-01;
const qa2 = 5.40397917702171048937e-01;
const qa3 = 7.18286544141962662868e-02;
const qa4 = 1.26171219808761642112e-01;
const qa5 = 1.36370839120290507362e-02;
const qa6 = 1.19844998467991074170e-02;
// Coefficients for approximation to erfc in [1.25,1/0.35]
const ra0 = -9.86494403484714822705e-03;
const ra1 = -6.93858572707181764372e-01;
const ra2 = -1.05586262253232909814e+01;
const ra3 = -6.23753324503260060396e+01;
const ra4 = -1.62396669462573470355e+02;
const ra5 = -1.84605092906711035994e+02;
const ra6 = -8.12874355063065934246e+01;
const ra7 = -9.81432934416914548592e+00;
const sa1 = 1.96512716674392571292e+01;
const sa2 = 1.37657754143519042600e+02;
const sa3 = 4.34565877475229228821e+02;
const sa4 = 6.45387271733267880336e+02;
const sa5 = 4.29008140027567833386e+02;
const sa6 = 1.08635005541779435134e+02;
const sa7 = 6.57024977031928170135e+00;
const sa8 = -6.04244152148580987438e-02;
// Coefficients for approximation to erfc in [1/.35,28]
const rb0 = -9.86494292470009928597e-03;
const rb1 = -7.99283237680523006574e-01;
const rb2 = -1.77579549177547519889e+01;
const rb3 = -1.60636384855821916062e+02;
const rb4 = -6.37566443368389627722e+02;
const rb5 = -1.02509513161107724954e+03;
const rb6 = -4.83519191608651397019e+02;
const sb1 = 3.03380607434824582924e+01;
const sb2 = 3.25792512996573918826e+02;
const sb3 = 1.53672958608443695994e+03;
const sb4 = 3.19985821950859553908e+03;
const sb5 = 2.55305040643316442583e+03;
const sb6 = 4.74528541206955367215e+02;
const sb7 = -2.24409524465858183362e+01;

fn highWord(x: f64) u32 {
    return @truncate(@as(u64, @bitCast(x)) >> 32);
}

fn erfc1(x: f64) f64 {
    const s = @abs(x) - 1;
    const p = pa0 + s * (pa1 + s * (pa2 + s * (pa3 + s * (pa4 + s * (pa5 + s * pa6)))));
    const q = 1 + s * (qa1 + s * (qa2 + s * (qa3 + s * (qa4 + s * (qa5 + s * qa6)))));
    return 1 - erx - p / q;
}

fn erfc2(ix: u32, x0: f64) f64 {
    if (ix < 0x3ff40000) return erfc1(x0); // |x| < 1.25
    const x = @abs(x0);
    const s = 1 / (x * x);
    var r: f64 = undefined;
    var t: f64 = undefined;
    if (ix < 0x4006db6d) { // |x| < 1/.35 ~ 2.85714
        r = ra0 + s * (ra1 + s * (ra2 + s * (ra3 + s * (ra4 + s * (ra5 + s * (ra6 + s * ra7))))));
        t = 1.0 + s * (sa1 + s * (sa2 + s * (sa3 + s * (sa4 + s * (sa5 + s * (sa6 + s * (sa7 + s * sa8)))))));
    } else { // |x| > 1/.35
        r = rb0 + s * (rb1 + s * (rb2 + s * (rb3 + s * (rb4 + s * (rb5 + s * rb6)))));
        t = 1.0 + s * (sb1 + s * (sb2 + s * (sb3 + s * (sb4 + s * (sb5 + s * (sb6 + s * sb7))))));
    }
    // z is x with the low word of its bits set to zero.
    const z: f64 = @bitCast(@as(u64, @bitCast(x)) & 0xffffffff00000000);
    return @exp(-z * z - 0.5625) * @exp((z - x) * (z + x) + r / t) / x;
}

fn erf(x: f64) f64 {
    const hi = highWord(x);
    const sign = hi >> 31 != 0;
    const ix = hi & 0x7fffffff;
    if (ix >= 0x7ff00000) {
        // erf(nan)=nan, erf(+-inf)=+-1
        return @as(f64, if (sign) -1 else 1) + 1 / x;
    }
    if (ix < 0x3feb0000) { // |x| < 0.84375
        if (ix < 0x3e300000) { // |x| < 2**-28, avoid underflow
            return 0.125 * (8 * x + efx8 * x);
        }
        const z = x * x;
        const r = pp0 + z * (pp1 + z * (pp2 + z * (pp3 + z * pp4)));
        const s = 1.0 + z * (qq1 + z * (qq2 + z * (qq3 + z * (qq4 + z * qq5))));
        return x + x * (r / s);
    }
    const y = if (ix < 0x40180000) // 0.84375 <= |x| < 6
        1 - erfc2(ix, x)
    else
        1 - 0x1p-1022;
    return if (sign) -y else y;
}

fn erfc(x: f64) f64 {
    const hi = highWord(x);
    const sign = hi >> 31 != 0;
    const ix = hi & 0x7fffffff;
    if (ix >= 0x7ff00000) {
        // erfc(nan)=nan, erfc(+-inf)=0,2
        return @as(f64, if (sign) 2 else 0) + 1 / x;
    }
    if (ix < 0x3feb0000) { // |x| < 0.84375
        if (ix < 0x3c700000) return 1.0 - x; // |x| < 2**-56
        const z = x * x;
        const r = pp0 + z * (pp1 + z * (pp2 + z * (pp3 + z * pp4)));
        const s = 1.0 + z * (qq1 + z * (qq2 + z * (qq3 + z * (qq4 + z * qq5))));
        const y = r / s;
        if (sign or ix < 0x3fd00000) return 1.0 - (x + x * y); // x < 1/4
        return 0.5 - (x - 0.5 + x * y);
    }
    if (ix < 0x403c0000) { // 0.84375 <= |x| < 28
        return if (sign) 2 - erfc2(ix, x) else erfc2(ix, x);
    }
    return if (sign) 2 - 0x1p-1022 else 0x1p-1022 * 0x1p-1022;
}

test "remQuo gives the IEEE remainder and the low bits of the quotient" {
    const cases = [_][4]f64{
        .{ 7, 2, -1, 4 },  .{ 100, 3, 1, 1 }, .{ -100, 3, -1, -1 }, .{ 5, -3, -1, -2 },
        .{ -5, -3, 1, 2 }, .{ 6, 4, -2, 2 },  .{ 10, 4, 2, 2 },     .{ 2, 4, 2, 0 },
    };
    for (cases) |c| {
        const r = remQuo(c[0], c[1]).?;
        try std.testing.expectEqual(c[2], r.rem);
        try std.testing.expectEqual(@as(i64, @intFromFloat(c[3])), r.quo);
    }
    try std.testing.expect(remQuo(7, 0) == null);
    try std.testing.expect(remQuo(std.math.inf(f64), 1) == null);
}

test "erf and erfc give the values of tclsh 9.1" {
    try std.testing.expectEqual(@as(f64, 0.8427007929497149), erf(1));
    try std.testing.expectEqual(@as(f64, 1), erf(std.math.inf(f64)));
    try std.testing.expectEqual(@as(f64, 0), erfc(30));
}

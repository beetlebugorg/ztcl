//! The `format` command: the conversions of C `printf` that Tcl has.
//!
//! Conversions: d i u x X o b c s f e E g G and %%, with the flags
//! `- + space 0 #`, a width, a precision, and `*` for both. Without an
//! `l` size, an integer conversion keeps 32 bits, as Tcl 8.6 does.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const expr = @import("expr.zig");
const bigint = @import("bigint.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Error = interp.Error;

const Spec = struct {
    left: bool = false,
    plus: bool = false,
    space: bool = false,
    zero: bool = false,
    alt: bool = false,
    width: usize = 0,
    prec: ?usize = null,
    long: bool = false,
    /// The size `ll`: an integer prints with all its digits.
    full: bool = false,
};

pub fn cmdFormat(it: *Interp, argv: []const Value, _: ?*interp.Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("format formatString ?arg ...?");
    const a = it.alloc();
    const f = try it.str(argv[1]);
    var out: std.ArrayList(u8) = .empty;
    var next: usize = 2;
    var saw_pos = false;
    var saw_seq = false;
    var i: usize = 0;
    while (i < f.len) {
        if (f[i] != '%') {
            try out.append(a, f[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= f.len) return it.fail("format string ended in middle of field specifier", .{});
        if (f[i] == '%') {
            try out.append(a, '%');
            i += 1;
            continue;
        }
        // The form %n$ names the argument.
        var positional: ?usize = null;
        var di = i;
        while (di < f.len and std.ascii.isDigit(f[di])) di += 1;
        if (di > i and di < f.len and f[di] == '$') {
            if (saw_seq) return it.fail("cannot mix \"%\" and \"%n$\" conversion specifiers", .{});
            saw_pos = true;
            const n = std.fmt.parseInt(usize, f[i..di], 10) catch std.math.maxInt(usize);
            if (n == 0 or n > argv.len - 2) return it.fail("\"%n$\" argument index out of range", .{});
            positional = n + 1;
            i = di + 1;
        } else {
            if (saw_pos) return it.fail("cannot mix \"%\" and \"%n$\" conversion specifiers", .{});
            saw_seq = true;
        }
        var sp: Spec = .{};
        while (i < f.len) : (i += 1) {
            switch (f[i]) {
                '-' => sp.left = true,
                '+' => sp.plus = true,
                ' ' => sp.space = true,
                '0' => sp.zero = true,
                '#' => sp.alt = true,
                else => break,
            }
        }
        if (i < f.len and f[i] == '*') {
            if (next >= argv.len) return it.fail("not enough arguments for all format specifiers", .{});
            const w = try it.int(argv[next]);
            next += 1;
            if (w < 0) sp.left = true;
            sp.width = @intCast(@min(@abs(w), 1 << 20));
            i += 1;
        } else while (i < f.len and std.ascii.isDigit(f[i])) : (i += 1) {
            sp.width = @min(sp.width * 10 + (f[i] - '0'), 1 << 20);
        }
        if (i < f.len and f[i] == '.') {
            i += 1;
            var p: usize = 0;
            if (i < f.len and f[i] == '*') {
                if (next >= argv.len) return it.fail("not enough arguments for all format specifiers", .{});
                const w = try it.int(argv[next]);
                next += 1;
                p = @intCast(std.math.clamp(w, 0, 1 << 20));
                i += 1;
            } else while (i < f.len and std.ascii.isDigit(f[i])) : (i += 1) {
                p = @min(p * 10 + (f[i] - '0'), 1 << 20);
            }
            sp.prec = p;
        }
        while (i < f.len and (f[i] == 'l' or f[i] == 'h' or f[i] == 'L')) : (i += 1) {
            if (f[i] != 'h') {
                if (sp.long and f[i] == 'l') sp.full = true;
                sp.long = true;
            }
        }
        if (i >= f.len) return it.fail("format string ended in middle of field specifier", .{});
        const conv = f[i];
        i += 1;
        if (std.mem.indexOfScalar(u8, "diuxXobcsfeEgG", conv) == null) {
            return it.fail("bad field specifier \"{c}\"", .{conv});
        }
        var arg_at = next;
        if (positional) |k| {
            arg_at = k;
        } else {
            if (next >= argv.len) return it.fail("not enough arguments for all format specifiers", .{});
            next += 1;
        }
        const arg = argv[arg_at];
        var sign: []const u8 = "";
        var body: []const u8 = "";
        var numeric = true;
        sw: switch (conv) {
            's' => {
                body = try it.str(arg);
                if (sp.prec) |p| body = body[0..@min(p, body.len)];
                numeric = false;
            },
            'c' => {
                const cp = try it.int(arg);
                var b: [4]u8 = undefined;
                const c: u21 = if (cp < 0 or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) 0xfffd else @intCast(cp);
                const n = std.unicode.utf8Encode(c, &b) catch unreachable;
                body = try a.dupe(u8, b[0..n]);
                numeric = false;
            },
            'd', 'i' => {
                const iv = try expr.intArg(it, arg);
                if (iv == .str and sp.full) {
                    const t = value.trimSpace(iv.str);
                    const neg = t[0] == '-';
                    sign = if (neg) "-" else if (sp.plus) "+" else if (sp.space) " " else "";
                    body = if (neg) t[1..] else t;
                    break :sw;
                }
                const n = try bigint.low64(it, iv);

                sign = if (n < 0) "-" else if (sp.plus) "+" else if (sp.space) " " else "";
                body = try std.fmt.allocPrint(a, "{d}", .{@abs(n)});
            },
            'u', 'x', 'X', 'o', 'b' => {
                const uv = try expr.intArg(it, arg);
                if (sp.full and (uv == .str or uv.int < 0)) {
                    const base: u8 = switch (conv) {
                        'u' => 10,
                        'o' => 8,
                        'b' => 2,
                        else => 16,
                    };
                    const t = try bigint.digits(it, uv, base, if (conv == 'X') .upper else .lower);
                    const neg = t[0] == '-';
                    sign = if (neg) "-" else "";
                    body = if (neg) t[1..] else t;
                    break :sw;
                }
                const n = try bigint.low64(it, uv);
                const u: u64 = @bitCast(n);
                body = switch (conv) {
                    'u' => try std.fmt.allocPrint(a, "{d}", .{u}),
                    'x' => try std.fmt.allocPrint(a, "{x}", .{u}),
                    'X' => try std.fmt.allocPrint(a, "{X}", .{u}),
                    'o' => try std.fmt.allocPrint(a, "{o}", .{u}),
                    else => try std.fmt.allocPrint(a, "{b}", .{u}),
                };
                if (sp.alt and u != 0) sign = switch (conv) {
                    'x' => "0x",
                    'X' => "0X",
                    'o' => "0",
                    'b' => "0b",
                    else => "",
                };
            },
            else => {
                const nv = arg.asNumber() orelse
                    return it.fail("expected floating-point number but got \"{s}\"", .{try it.str(arg)});
                var x: f64 = if (nv == .int) @floatFromInt(nv.int) else nv.double;
                const neg = std.math.signbit(x) and !std.math.isNan(x);
                sign = if (neg) "-" else if (sp.plus) "+" else if (sp.space) " " else "";
                x = @abs(x);
                body = try formatFloat(a, x, conv, sp.prec, sp.alt);
                if (std.math.isNan(x) or std.math.isInf(x)) sp.zero = false;
            },
        }
        if (numeric and sp.prec != null and std.mem.indexOfScalar(u8, "diuxXob", conv) != null) {
            // The precision of an integer is the least count of digits.
            if (body.len < sp.prec.?) {
                const z = try a.alloc(u8, sp.prec.? - body.len);
                @memset(z, '0');
                body = try std.mem.concat(a, u8, &.{ z, body });
            }
            sp.zero = false;
        }
        const len = sign.len + body.len;
        const pad = if (sp.width > len) sp.width - len else 0;
        if (sp.left) {
            try out.appendSlice(a, sign);
            try out.appendSlice(a, body);
            try out.appendNTimes(a, ' ', pad);
        } else if (sp.zero and numeric) {
            try out.appendSlice(a, sign);
            try out.appendNTimes(a, '0', pad);
            try out.appendSlice(a, body);
        } else {
            try out.appendNTimes(a, ' ', pad);
            try out.appendSlice(a, sign);
            try out.appendSlice(a, body);
        }
    }
    return .{ .str = out.items };
}

/// Formats a double that is not negative as %f, %e, or %g does.
fn formatFloat(a: std.mem.Allocator, x: f64, conv: u8, prec_in: ?usize, alt: bool) Error![]const u8 {
    const upper = conv == 'E' or conv == 'G';
    if (std.math.isNan(x)) return if (upper) "NAN" else "nan";
    if (std.math.isInf(x)) return if (upper) "INF" else "inf";
    var prec = @min(prec_in orelse 6, 300);
    const buf = try a.alloc(u8, 400 + prec);
    switch (conv) {
        'f' => return fixed(a, buf, x, prec),
        'e', 'E' => return sci(a, buf, x, prec, upper),
        else => {
            if (prec == 0) prec = 1;
            // The exponent after the value is rounded to `prec` digits.
            const s = std.fmt.float.render(buf, x, .{ .mode = .scientific, .precision = prec - 1 }) catch return error.OutOfMemory;
            const epos = std.mem.indexOfScalar(u8, s, 'e').?;
            const exp = std.fmt.parseInt(i32, s[epos + 1 ..], 10) catch 0;
            var body: []const u8 = undefined;
            if (x != 0 and (exp < -4 or exp >= prec)) {
                body = try sci(a, try a.alloc(u8, 400 + prec), x, prec - 1, upper);
            } else {
                const decimals: usize = @intCast(@as(i64, @intCast(prec)) - 1 - exp);
                body = std.fmt.float.render(buf, x, .{ .mode = .decimal, .precision = decimals }) catch return error.OutOfMemory;
            }
            if (alt) return body;
            // %g drops the zeros at the end of the fraction.
            const e2 = std.mem.indexOfAny(u8, body, "eE") orelse body.len;
            var m = body[0..e2];
            if (std.mem.indexOfScalar(u8, m, '.') != null) {
                m = std.mem.trimEnd(u8, m, "0");
                m = std.mem.trimEnd(u8, m, ".");
            }
            return std.mem.concat(a, u8, &.{ m, body[e2..] });
        },
    }
}

/// Fixed form with `prec` decimals, rounded as C does: by the exact
/// value of the double, and to the even digit at an exact half.
fn fixed(a: std.mem.Allocator, buf: []u8, x: f64, prec: usize) Error![]const u8 {
    // The shortest digits that read back to `x`.
    const short = std.fmt.float.render(buf, x, .{ .mode = .decimal }) catch return error.OutOfMemory;
    const dot = std.mem.indexOfScalar(u8, short, '.');
    const decimals = if (dot) |d| short.len - d - 1 else 0;
    // Only digits that end in a 5 one place after the last kept place
    // can round the wrong way: the exact value can be below the half.
    if (decimals != prec + 1 or short[short.len - 1] != '5') {
        return std.fmt.float.render(try a.alloc(u8, buf.len), x, .{ .mode = .decimal, .precision = prec }) catch return error.OutOfMemory;
    }
    const half = std.fmt.parseFloat(f128, short) catch return error.OutOfMemory;
    const exact: f128 = x;
    var keep = short[0 .. short.len - 1];
    if (prec == 0) keep = keep[0 .. keep.len - 1];
    const last = keep[keep.len - 1];
    const up = if (exact == half) (last - '0') % 2 == 1 else exact > half;
    const out = try a.alloc(u8, keep.len + 1);
    out[0] = '0';
    @memcpy(out[1..], keep);
    if (up) {
        // Add one to the last digit, with the carry.
        var i = out.len;
        while (i > 0) {
            i -= 1;
            if (out[i] == '.') continue;
            if (out[i] == '9') {
                out[i] = '0';
            } else {
                out[i] += 1;
                break;
            }
        }
    }
    return if (out[0] == '0') out[1..] else out;
}

/// Scientific form with a sign and two digits in the exponent.
fn sci(a: std.mem.Allocator, buf: []u8, x: f64, prec: usize, upper: bool) Error![]const u8 {
    const s = std.fmt.float.render(buf, x, .{ .mode = .scientific, .precision = prec }) catch return error.OutOfMemory;
    const epos = std.mem.indexOfScalar(u8, s, 'e').?;
    const exp = std.fmt.parseInt(i32, s[epos + 1 ..], 10) catch 0;
    return std.fmt.allocPrint(a, "{s}{c}{c}{d:0>2}", .{
        s[0..epos],
        @as(u8, if (upper) 'E' else 'e'),
        @as(u8, if (exp < 0) '-' else '+'),
        @abs(exp),
    });
}

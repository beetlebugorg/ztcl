//! The Eisel-Lemire step for the numbers of the JSON parser.
//!
//! The parser reads the decimal digits of a number into a 64-bit
//! mantissa `w` and a power of ten `q`. The double is w * 10^q, and
//! 10^q = 5^q * 2^q. A table has a 128-bit approximation of 5^q for
//! each q in -342 to 308, with the most significant bit set. The
//! product of `w` and the high word of the entry gives the 54 most
//! significant bits of w * 5^q. A second multiply with the low word
//! is needed only when the bits below them are all ones. The result
//! is exact unless it is too near the halfway point of two doubles.
//! Then the function gives null, and the caller uses the full parse of
//! the text (`std.fmt.parseFloat`).
//!
//! The method is from Daniel Lemire, "Number Parsing at a Gigabyte per
//! Second" (2021), sections 5 and 6, as `std.fmt.parse_float` of Zig
//! has it (see docs/references/stdlib.md). The table is made at compile
//! time with the rules of the paper: a power with q >= 0 is truncated,
//! and a power with q < 0 is rounded up.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

const smallest_q = -342;
const largest_q = 308;

const Pow5 = struct { hi: u64, lo: u64 };

fn bitLen(x: anytype) usize {
    return @bitSizeOf(@TypeOf(x)) - @clz(x);
}

/// 5^q in 128 bits, with the most significant bit set.
const table: [largest_q - smallest_q + 1]Pow5 = blk: {
    @setEvalBranchQuota(10_000_000);
    const Big = u2048;
    var t: [largest_q - smallest_q + 1]Pow5 = undefined;
    // Negative powers: c = 2^b / 5^-q + 1, then cut to 128 bits.
    var p5: Big = 1;
    var n: usize = 1;
    while (n <= -smallest_q) : (n += 1) {
        p5 *= 5;
        const q: i32 = -@as(i32, @intCast(n));
        const z = bitLen(p5);
        const b = if (q >= -27) z + 127 else 2 * z + 128;
        var c: Big = (@as(Big, 1) << b) / p5 + 1;
        const len = bitLen(c);
        if (len > 128) c >>= len - 128;
        t[@intCast(q - smallest_q)] = .{ .hi = @truncate(c >> 64), .lo = @truncate(c) };
    }
    // Positive powers: 5^q, shifted or truncated to 128 bits.
    p5 = 1;
    var k: usize = 0;
    while (k <= largest_q) : (k += 1) {
        const len = bitLen(p5);
        const c: Big = if (len > 128) p5 >> (len - 128) else p5 << (128 - len);
        t[k + -smallest_q] = .{ .hi = @truncate(c >> 64), .lo = @truncate(c) };
        p5 *= 5;
    }
    break :blk t;
};

const mantissa_bits = 52;
const min_exponent = -1023;
const infinite_power = 0x7FF;

/// The double w * 10^q, or null when the step cannot round it exactly.
/// `w` is the exact value of all the digits of the number.
pub fn eiselLemire(w_in: u64, q: i64, negative: bool) ?f64 {
    const sign: u64 = if (negative) 1 << 63 else 0;
    if (w_in == 0 or q < smallest_q) return @bitCast(sign);
    if (q > largest_q) return @bitCast(sign | (@as(u64, infinite_power) << mantissa_bits));
    const lz: u6 = @intCast(@clz(w_in));
    const w = w_in << lz;
    const pow = table[@intCast(q - smallest_q)];
    // The product of w and the high word. The bits below the 55 high
    // bits are all ones only when the low word can change the result.
    var x = @as(u128, w) * pow.hi;
    var hi: u64 = @truncate(x >> 64);
    var lo: u64 = @truncate(x);
    const mask: u64 = std.math.maxInt(u64) >> (mantissa_bits + 3);
    if (hi & mask == mask) {
        x = @as(u128, w) * pow.lo;
        const second_hi: u64 = @truncate(x >> 64);
        lo +%= second_hi;
        if (second_hi > lo) hi += 1;
    }
    if (lo == std.math.maxInt(u64) and !(q >= -27 and q <= 55)) return null;
    const upper: u6 = @intCast(hi >> 63);
    const shift: u6 = upper + (64 - mantissa_bits - 3);
    var m: u64 = hi >> shift;
    // The binary exponent: floor(q * log2(10)) + 63, from 217706 / 2^16.
    const q32: i32 = @intCast(q);
    var e2: i32 = ((q32 *% (152170 + 65536)) >> 16) + 63 + @as(i32, upper) - @as(i32, lz) - min_exponent;
    if (e2 <= 0) {
        if (-e2 + 1 >= 64) return @bitCast(sign);
        // A subnormal double.
        m >>= @intCast(-e2 + 1);
        m += m & 1;
        m >>= 1;
        const e: u64 = @intFromBool(m >= (@as(u64, 1) << mantissa_bits));
        return @bitCast(sign | (e << mantissa_bits) | (m & ((@as(u64, 1) << mantissa_bits) - 1)));
    }
    // A product that is exactly halfway rounds to even.
    if (lo <= 1 and q >= -4 and q <= 23 and m & 3 == 1 and
        (m << shift) == hi)
    {
        m &= ~@as(u64, 1);
    }
    m += m & 1;
    m >>= 1;
    if (m >= (@as(u64, 2) << mantissa_bits)) {
        m = @as(u64, 1) << mantissa_bits;
        e2 += 1;
    }
    m &= ~(@as(u64, 1) << mantissa_bits);
    if (e2 >= infinite_power) return @bitCast(sign | (@as(u64, infinite_power) << mantissa_bits));
    return @bitCast(sign | (@as(u64, @intCast(e2)) << mantissa_bits) | m);
}

test "the table has the powers of the paper" {
    const T = std.testing;
    try T.expectEqual(Pow5{ .hi = 0xeef453d6923bd65a, .lo = 0x113faa2906a13b3f }, table[0]);
    try T.expectEqual(Pow5{ .hi = 0x9558b4661b6565f8, .lo = 0x4ac7ca59a424c507 }, table[1]);
    try T.expectEqual(Pow5{ .hi = 0xcccccccccccccccc, .lo = 0xcccccccccccccccd }, table[-1 - smallest_q]);
    try T.expectEqual(Pow5{ .hi = 1 << 63, .lo = 0 }, table[-smallest_q]);
    try T.expectEqual(Pow5{ .hi = 0xa000000000000000, .lo = 0 }, table[1 - smallest_q]);
}

fn expectSame(w: u64, q: i64, neg: bool) !void {
    const d = eiselLemire(w, q, neg) orelse return;
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}{d}e{d}", .{ if (neg) "-" else "", w, q }) catch unreachable;
    const want = try std.fmt.parseFloat(f64, text);
    if (@as(u64, @bitCast(d)) != @as(u64, @bitCast(want))) {
        std.debug.print("{s}: {x} want {x}\n", .{ text, @as(u64, @bitCast(d)), @as(u64, @bitCast(want)) });
        return error.TestExpectedEqual;
    }
}

test "eiselLemire equals parseFloat bit for bit" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    // The edges of the exponent range and of the mantissa.
    const ws = [_]u64{ 1, 2, 5, 9, 10, 17, 4503599627370496, 9007199254740991, 9007199254740993, 9999999999999999999, std.math.maxInt(u64) };
    var q: i64 = -360;
    while (q <= 330) : (q += 1) {
        for (ws) |w| try expectSame(w, q, false);
    }
    for (0..200_000) |_| {
        // Mantissas of 1 to 19 digits and exponents of normal JSON text.
        const digits = r.intRangeAtMost(u6, 1, 19);
        const w = r.uintLessThan(u64, std.math.powi(u64, 10, digits) catch unreachable) + 1;
        const e = r.intRangeAtMost(i64, -40, 40) - digits;
        try expectSame(w, e, r.boolean());
    }
    for (0..100_000) |_| {
        try expectSame(r.int(u64) | 1, r.intRangeAtMost(i64, -345, 310), false);
    }
    // Halfway cases: an odd multiple of 2^-53 near one.
    for (0..20_000) |_| {
        const m = r.uintLessThan(u64, 1 << 53) | (1 << 53);
        const half = m * 2 + 1;
        // half * 2^-54 as a decimal: half * 5^54 * 10^-54 does not fit, so
        // use small exponents where 5^-q times an integer is exact.
        try expectSame(half, 0, false);
        try expectSame(half * 5, -1, false);
    }
}

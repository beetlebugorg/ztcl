//! Gradient noise with a fixed seed.
//!
//! The same function serves `noise3` in `expr`, the `noise3` command,
//! and the vector code of point procs, so all paths give equal bits.
//! The method is the gradient noise of Ken Perlin ("Improving Noise",
//! 2002), with a hash of the cell corner in place of his table.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

/// The seed of the noise when the embedder gives none.
pub const default_seed: u32 = 0x5eed1234;

/// One step of the hash of a cell corner: mixes one coordinate in.
inline fn mix(h: u32, v: i32, k: u32) u32 {
    var r = h ^ (@as(u32, @bitCast(v)) *% k);
    r = (r ^ (r >> 15)) *% 0x2c1b3c6d;
    return r ^ (r >> 13);
}

/// The dot product of the offset with the direction of a corner. Four
/// bits of the hash select one of the 12 edge directions of a cube (4
/// of them twice). Each direction has two parts of +1 or -1, so the
/// product is a sum of two coordinates with signs, and no table.
inline fn grad(h: u32, x: f64, y: f64, z: f64) f64 {
    const b = (h >> 7) & 15;
    const u = if (b < 8) x else y;
    const v = if (b < 4) y else if (b == 12) x else if (b == 14) x else z;
    return (if (b & 1 == 0) u else -u) + (if (b & 2 == 0) v else -v);
}

fn fade(t: f64) f64 {
    return t * t * t * (t * (t * 6 - 15) + 10);
}

fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * t;
}

fn cell(v: f64) i32 {
    const f = @floor(v);
    if (!(f > -2e9 and f < 2e9)) return 0;
    return @intFromFloat(f);
}

/// Noise at a point, from about -1 to 1. It is 0 at whole coordinates.
pub fn noise3(x: f64, y: f64, z: f64) f64 {
    return noise3Seed(default_seed, x, y, z);
}

/// Noise at a point for a seed of the embedder.
pub fn noise3Seed(seed: u32, x: f64, y: f64, z: f64) f64 {
    const xi = cell(x);
    const yi = cell(y);
    const zi = cell(z);
    const fx = x - @floor(x);
    const fy = y - @floor(y);
    const fz = z - @floor(z);
    const u = fade(fx);
    const v = fade(fy);
    const w = fade(fz);
    // The hash of a corner mixes x, then y, then z, so corners share steps.
    const hx0 = mix(seed, xi, 0x8da6b343);
    const hx1 = mix(seed, xi +% 1, 0x8da6b343);
    const h00 = mix(hx0, yi, 0xd8163841);
    const h10 = mix(hx1, yi, 0xd8163841);
    const h01 = mix(hx0, yi +% 1, 0xd8163841);
    const h11 = mix(hx1, yi +% 1, 0xd8163841);
    const z1 = zi +% 1;
    const k: u32 = 0xcb1ab31f;
    const a = lerp(grad(mix(h00, zi, k), fx, fy, fz), grad(mix(h10, zi, k), fx - 1, fy, fz), u);
    const b = lerp(grad(mix(h01, zi, k), fx, fy - 1, fz), grad(mix(h11, zi, k), fx - 1, fy - 1, fz), u);
    const c = lerp(grad(mix(h00, z1, k), fx, fy, fz - 1), grad(mix(h10, z1, k), fx - 1, fy, fz - 1), u);
    const d = lerp(grad(mix(h01, z1, k), fx, fy - 1, fz - 1), grad(mix(h11, z1, k), fx - 1, fy - 1, fz - 1), u);
    return lerp(lerp(a, b, v), lerp(c, d, v), w);
}

/// The lanes of the vector form: 4 doubles fill one AVX2 register.
const lanes = 4;
const F = @Vector(lanes, f64);
const I = @Vector(lanes, i32);
/// A hash in each lane, as a u32 in a 64-bit lane. The lane has the
/// width of a double, so a mask needs no widening, and the low 32 bits
/// of a product come from the 32 x 32 multiply of AVX2.
const U = @Vector(lanes, u64);
const low32: U = @splat(0xffff_ffff);

inline fn widen(v: I) U {
    const w: @Vector(lanes, u32) = @bitCast(v);
    return @intCast(w);
}

inline fn mixV(h: U, v: U, k: u32) U {
    var r = h ^ ((v *% @as(U, @splat(k))) & low32);
    r = ((r ^ (r >> @splat(15))) *% @as(U, @splat(0x2c1b3c6d))) & low32;
    return r ^ (r >> @splat(13));
}

inline fn gradV(h: U, x: F, y: F, z: F) F {
    const b = (h >> @splat(7)) & @as(U, @splat(15));
    const zero: U = @splat(0);
    const u = @select(f64, (b & @as(U, @splat(8))) == zero, x, y);
    // The directions 12 and 14 use x in place of z.
    const xz = @select(f64, (b & @as(U, @splat(13))) == @as(U, @splat(12)), x, z);
    const v = @select(f64, (b & @as(U, @splat(12))) == zero, y, xz);
    // Bits 0 and 1 of the direction are the signs of the two parts.
    const su: U = @as(U, @bitCast(u)) ^ (b << @splat(63));
    const sv: U = @as(U, @bitCast(v)) ^ ((b & @as(U, @splat(2))) << @splat(62));
    return @as(F, @bitCast(su)) + @as(F, @bitCast(sv));
}

inline fn fadeV(t: F) F {
    return t * t * t * (t * (t * @as(F, @splat(6)) - @as(F, @splat(15))) + @as(F, @splat(10)));
}

inline fn lerpV(a: F, b: F, t: F) F {
    return a + (b - a) * t;
}

inline fn cellV(f: F) I {
    const zero: F = @splat(0);
    const lo = @select(f64, f > @as(F, @splat(-2e9)), f, zero);
    return @intFromFloat(@select(f64, f < @as(F, @splat(2e9)), lo, zero));
}

/// The corner hashes of the last 4 points. A path moves in small steps,
/// so the next 4 points are often in the same cells, and the hashes
/// stay valid. A hash depends only on the seed and the cell.
const Corners = struct {
    valid: bool = false,
    xi: I = undefined,
    yi: I = undefined,
    zi: I = undefined,
    h: [8]U = undefined,

    inline fn update(c: *Corners, seed: u32, xi: I, yi: I, zi: I) void {
        if (c.valid and @reduce(.And, (xi ^ c.xi) | (yi ^ c.yi) | (zi ^ c.zi) == @as(I, @splat(0)))) return;
        c.valid = true;
        c.xi = xi;
        c.yi = yi;
        c.zi = zi;
        const step: I = @splat(1);
        const s: U = @splat(seed);
        const x0 = widen(xi);
        const x1 = widen(xi +% step);
        const y0 = widen(yi);
        const y1 = widen(yi +% step);
        const z0 = widen(zi);
        const z1 = widen(zi +% step);
        const hx0 = mixV(s, x0, 0x8da6b343);
        const hx1 = mixV(s, x1, 0x8da6b343);
        const h00 = mixV(hx0, y0, 0xd8163841);
        const h10 = mixV(hx1, y0, 0xd8163841);
        const h01 = mixV(hx0, y1, 0xd8163841);
        const h11 = mixV(hx1, y1, 0xd8163841);
        const k: u32 = 0xcb1ab31f;
        c.h = .{
            mixV(h00, z0, k), mixV(h10, z0, k), mixV(h01, z0, k), mixV(h11, z0, k),
            mixV(h00, z1, k), mixV(h10, z1, k), mixV(h01, z1, k), mixV(h11, z1, k),
        };
    }
};

/// `noise3` for 4 points at once. Each lane does the operations of
/// `noise3` in the same order, so the bits are equal.
inline fn noise3V(corners: *Corners, seed: u32, x: F, y: F, z: F) F {
    const one: F = @splat(1);
    const flx = @floor(x);
    const fly = @floor(y);
    const flz = @floor(z);
    corners.update(seed, cellV(flx), cellV(fly), cellV(flz));
    const h = &corners.h;
    const fx = x - flx;
    const fy = y - fly;
    const fz = z - flz;
    const u = fadeV(fx);
    const v = fadeV(fy);
    const w = fadeV(fz);
    const a = lerpV(gradV(h[0], fx, fy, fz), gradV(h[1], fx - one, fy, fz), u);
    const b = lerpV(gradV(h[2], fx, fy - one, fz), gradV(h[3], fx - one, fy - one, fz), u);
    const c = lerpV(gradV(h[4], fx, fy, fz - one), gradV(h[5], fx - one, fy, fz - one), u);
    const d = lerpV(gradV(h[6], fx, fy - one, fz - one), gradV(h[7], fx - one, fy - one, fz - one), u);
    return lerpV(lerpV(a, b, v), lerpV(c, d, v), w);
}

/// `noise3` of each point of a block. The results have the same bits
/// as `noise3` gives for one point.
pub fn noise3Block(out: []f64, xs: []const f64, ys: []const f64, zs: []const f64) void {
    noise3BlockSeed(default_seed, out, xs, ys, zs);
}

/// `noise3Seed` of each point of a block, with the same bits.
pub fn noise3BlockSeed(seed: u32, out: []f64, xs: []const f64, ys: []const f64, zs: []const f64) void {
    var i: usize = 0;
    var corners: Corners = .{};
    while (i + lanes <= out.len) : (i += lanes) {
        const r = noise3V(&corners, seed, xs[i..][0..lanes].*, ys[i..][0..lanes].*, zs[i..][0..lanes].*);
        out[i..][0..lanes].* = r;
    }
    while (i < out.len) : (i += 1) out[i] = noise3Seed(seed, xs[i], ys[i], zs[i]);
}

test "the block form of the noise gives the bits of the scalar form" {
    var xs: [203]f64 = undefined;
    var ys: [203]f64 = undefined;
    var zs: [203]f64 = undefined;
    var out: [203]f64 = undefined;
    for (0..xs.len) |i| {
        const t: f64 = @floatFromInt(i);
        xs[i] = t * 0.731 - 40;
        ys[i] = @sin(t) * 1e3;
        zs[i] = t * t * 0.01 - 3;
    }
    xs[7] = std.math.nan(f64);
    ys[8] = std.math.inf(f64);
    zs[9] = -1e300;
    xs[10] = -0.0;
    noise3Block(&out, &xs, &ys, &zs);
    for (out, xs, ys, zs) |o, x, y, z| {
        try std.testing.expectEqual(@as(u64, @bitCast(noise3(x, y, z))), @as(u64, @bitCast(o)));
    }
}

test "the block form equals the scalar form on random and edge inputs" {
    const edge = [_]f64{
        0,                  -0.0,                1,                 -1,
        0.5,                -0.5,                1.9999999999999998, -1.0000000000000002,
        2e9,                -2e9,                2e9 - 1,           -2e9 + 1,
        2147483647.5,       -2147483648.5,       1e300,             -1e300,
        5e-324,             -5e-324,             std.math.inf(f64), -std.math.inf(f64),
        std.math.nan(f64),
    };
    var prng = std.Random.DefaultPrng.init(11);
    const rng = prng.random();
    const n = 4096;
    var xs: [n]f64 = undefined;
    var ys: [n]f64 = undefined;
    var zs: [n]f64 = undefined;
    var out: [n]f64 = undefined;
    for ([_]*[n]f64{ &xs, &ys, &zs }) |col| {
        for (col) |*c| c.* = switch (rng.int(u8) % 4) {
            0 => edge[rng.uintLessThan(usize, edge.len)],
            1 => (rng.float(f64) - 0.5) * 8,
            2 => (rng.float(f64) - 0.5) * 4e9,
            else => @bitCast(rng.int(u64)),
        };
    }
    for ([_]u32{ default_seed, 0, 0xffff_ffff, 12345 }) |seed| {
        noise3BlockSeed(seed, &out, &xs, &ys, &zs);
        for (out, xs, ys, zs) |o, x, y, z| {
            const scalar = noise3Seed(seed, x, y, z);
            // The sign of a NaN depends on the operand order that the
            // optimizer picks. `point.bound` replaces each NaN output.
            if (std.math.isNan(scalar)) {
                try std.testing.expect(std.math.isNan(o));
            } else {
                try std.testing.expectEqual(@as(u64, @bitCast(scalar)), @as(u64, @bitCast(o)));
            }
        }
    }
}

test "the block form equals the scalar form on a path in small steps" {
    const n = 4099;
    var xs: [n]f64 = undefined;
    var ys: [n]f64 = undefined;
    var zs: [n]f64 = undefined;
    var out: [n]f64 = undefined;
    for (0..n) |i| {
        const t: f64 = @floatFromInt(i);
        // Each cell has many points, and the path crosses cell borders.
        xs[i] = -3 + t * 0.013;
        ys[i] = 2 - t * 0.007;
        zs[i] = @floor(t / 900) * 0.2;
    }
    noise3BlockSeed(default_seed, &out, &xs, &ys, &zs);
    for (out, xs, ys, zs) |o, x, y, z| {
        try std.testing.expectEqual(@as(u64, @bitCast(noise3(x, y, z))), @as(u64, @bitCast(o)));
    }
}

test "noise is zero on the grid and bounded" {
    try std.testing.expectEqual(@as(f64, 0), noise3(1, 2, 3));
    var i: usize = 0;
    var lo: f64 = 0;
    var hi: f64 = 0;
    while (i < 1000) : (i += 1) {
        const t: f64 = @floatFromInt(i);
        const n = noise3(t * 0.37, t * 0.11, t * 0.73);
        lo = @min(lo, n);
        hi = @max(hi, n);
    }
    try std.testing.expect(lo < -0.2 and hi > 0.2 and lo >= -1.5 and hi <= 1.5);
}

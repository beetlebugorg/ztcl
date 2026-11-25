//! The runtime of a compiled point proc.
//!
//! The build compiles this file for `wasm32-freestanding` with no
//! imports. Each export calls the function that `Program.run` calls in
//! `point.zig` or `noise.zig`, so the module and the interpreter use one
//! source for each function, and the compiled bodies differ only in the
//! target. `point_wasm.zig` adds the function `run` to a copy of this
//! module, and `run` calls these exports one lane at a time.
//!
//! `bound` gets the address of each column, or 0 for a missing column,
//! and builds a `point.Points` for one block of points.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const point = @import("point.zig");
const noise = @import("noise.zig");

export fn rt_acos(x: f64) f64 {
    return point.scalar1(.acos, x);
}
export fn rt_asin(x: f64) f64 {
    return point.scalar1(.asin, x);
}
export fn rt_atan(x: f64) f64 {
    return point.scalar1(.atan, x);
}
export fn rt_cos(x: f64) f64 {
    return point.scalar1(.cos, x);
}
export fn rt_cosh(x: f64) f64 {
    return point.scalar1(.cosh, x);
}
export fn rt_exp(x: f64) f64 {
    return point.scalar1(.exp, x);
}
export fn rt_log(x: f64) f64 {
    return point.scalar1(.log, x);
}
export fn rt_log10(x: f64) f64 {
    return point.scalar1(.log10, x);
}
export fn rt_sin(x: f64) f64 {
    return point.scalar1(.sin, x);
}
export fn rt_sinh(x: f64) f64 {
    return point.scalar1(.sinh, x);
}
export fn rt_tan(x: f64) f64 {
    return point.scalar1(.tan, x);
}
export fn rt_tanh(x: f64) f64 {
    return point.scalar1(.tanh, x);
}
export fn rt_round(x: f64) f64 {
    return @round(x);
}
export fn rt_atan2(x: f64, y: f64) f64 {
    return point.scalar2(0, .atan2, x, y);
}
export fn rt_fmod(x: f64, y: f64) f64 {
    return point.scalar2(0, .fmod, x, y);
}
export fn rt_hypot(x: f64, y: f64) f64 {
    return point.scalar2(0, .hypot, x, y);
}
export fn rt_pow(x: f64, y: f64) f64 {
    return point.scalar2(0, .pow, x, y);
}
export fn rt_clamp(x: f64, lo: f64, hi: f64) f64 {
    return point.clamp(x, lo, hi);
}
export fn rt_noise3(seed: u32, x: f64, y: f64, z: f64) f64 {
    return noise.noise3Seed(seed, x, y, z);
}

fn col(addr: u32, n: u32) ?[]f64 {
    if (addr == 0) return null;
    const p: [*]f64 = @ptrFromInt(addr);
    return p[0..n];
}

/// `point.bound` for `n` points. `outs` is the address of 7 column
/// addresses in the order of `point.Out`. `limits` is the address of the
/// five values of `point.Limits`.
export fn rt_bound(n: u32, width: u32, outs: u32, limits: u32) void {
    var pts: point.Points = .{ .len = n };
    pts.in[@intFromEnum(point.Field.width)] = col(width, n);
    const addrs: [*]const u32 = @ptrFromInt(outs);
    for (&pts.out, 0..) |*o, k| o.* = col(addrs[k], n);
    const lim: *const [5]f64 = @ptrFromInt(limits);
    pts.limits = .{ .max_offset = lim[0], .max_move = lim[1], .min_width = lim[2], .max_width = lim[3], .fallback_width = lim[4] };
    point.bound(&pts);
}

//! The library of `ztcl::fhe`: computation on encrypted data.
//!
//! `ntt.zig` has the modular arithmetic and the transform, `ckks.zig`
//! the scheme for vectors of real numbers, and `tfhe.zig` the scheme for
//! bits. This library imports no file of the interpreter. `cmd.zig` has
//! the Tcl commands.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
pub const ntt = @import("ntt.zig");
pub const ckks = @import("ckks.zig");
pub const tfhe = @import("tfhe.zig");

/// The coefficients of the polynomial of degree 3 that Kim, Song, Wang,
/// Xia, and Jiang fit to the logistic function on [-8, 8] by least
/// squares: 0.5 + 0.197 y - 0.004 y^3.
pub const sigmoid3 = [3]f64{ 0.5, 0.197, -0.004 };

pub fn sigmoid3Plain(y: f64) f64 {
    return sigmoid3[0] + sigmoid3[1] * y + sigmoid3[2] * y * y * y;
}

/// The score of a logistic regression model on encrypted features:
/// sigmoid3(<w, x> + bias) in slot 0. The model is plain. The keys must
/// have the Galois keys of `ckks.sumRotations(count)`. The score uses 3
/// levels.
pub fn logisticScore(ctx: *ckks.Context, keys: *const ckks.Keys, x: ckks.Ciphertext, weights: []const f64, bias: f64, count: usize) !ckks.Ciphertext {
    const wx = try ckks.mulPlain(ctx, x, weights);
    defer wx.deinit(ctx);
    const sum = try ckks.sumSlots(ctx, keys, wx, count);
    defer sum.deinit(ctx);
    const y = try ckks.addScalar(ctx, sum, bias);
    defer y.deinit(ctx);
    // y^3 * c3 = (y * y) * (y * c3).
    const y2 = try ckks.mul(ctx, keys, y, y);
    defer y2.deinit(ctx);
    const yc = try ckks.mulScalar(ctx, y, sigmoid3[2]);
    defer yc.deinit(ctx);
    const cube = try ckks.mul(ctx, keys, y2, yc);
    defer cube.deinit(ctx);
    const lin = try ckks.mulScalar(ctx, y, sigmoid3[1]);
    defer lin.deinit(ctx);
    const part = try ckks.add(ctx, cube, lin);
    defer part.deinit(ctx);
    return ckks.addScalar(ctx, part, sigmoid3[0]);
}

test {
    _ = ntt;
    _ = ckks;
    _ = tfhe;
}

test "the logistic regression score matches the plain polynomial" {
    const gpa = std.testing.allocator;
    const ctx = try ckks.Context.init(gpa, .{ .log_n = 8, .levels = 4 });
    defer ctx.deinit();
    var prng = std.Random.DefaultPrng.init(31);
    const rng = prng.random();
    var rot: [16]i64 = undefined;
    var keys = try ckks.keygen(ctx, rng, ckks.sumRotations(16, &rot));
    defer keys.deinit(ctx);
    var x: [16]f64 = undefined;
    var w: [16]f64 = undefined;
    var y: f64 = -0.25;
    for (&x, &w) |*a, *b| {
        a.* = rng.float(f64) * 2 - 1;
        b.* = rng.float(f64) * 2 - 1;
        y += a.* * b.*;
    }
    const cx = try ckks.encryptValues(ctx, &keys, rng, &x);
    defer cx.deinit(ctx);
    const score = try logisticScore(ctx, &keys, cx, &w, -0.25, 16);
    defer score.deinit(ctx);
    const d = try ckks.decrypt(ctx, &keys, score);
    defer gpa.free(d);
    try std.testing.expectApproxEqAbs(sigmoid3Plain(y), d[0], 1e-5);
}

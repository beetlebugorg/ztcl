//! A fuzzer of the modular arithmetic and the transform of `ntt.zig`.
//!
//!   zig build fhe-ntt-fuzz -- [--seconds N] [--seed N]
//!
//! Each round selects a size from 4 to 4,096, a prime of 20 to 61 bits
//! for that size, and a polynomial. The coefficients are random, or all
//! 0, or all q - 1, or one nonzero place. The round checks that:
//!
//! - the Barrett and Shoup products are the remainders of the 128-bit
//!   products;
//! - the scalar and the vector transforms give the same words, each
//!   below q;
//! - the inverse of the transform is the input;
//! - the transform of a sum is the sum of the transforms;
//! - for a size up to 64, the product in NTT form is the schoolbook
//!   product modulo X^n + 1;
//! - the automorphism table gives a permutation, and the table of g
//!   followed by the table of g^-1 is the identity.
//!
//! A build with safety checks also stops at an overflow or an index out
//! of range.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const ntt = @import("ntt.zig");

fn fail(comptime what: []const u8, seed: u64, round_no: u64, n: usize, q: u64) noreturn {
    std.debug.print("ntt-fuzz: " ++ what ++ ": seed {d}, round {d}, n {d}, q {d}\n", .{ seed, round_no, n, q });
    std.process.exit(1);
}

fn fill(r: std.Random, q: u64, a: []u64) void {
    switch (r.uintLessThan(u8, 8)) {
        0 => @memset(a, 0),
        1 => @memset(a, q - 1),
        2 => {
            @memset(a, 0);
            a[r.uintLessThan(usize, a.len)] = 1 + r.uintLessThan(u64, q - 1);
        },
        else => for (a) |*x| {
            x.* = r.uintLessThan(u64, q);
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var seconds: u64 = 10;
    var seed: u64 = 1;
    var k: usize = 1;
    while (k + 1 < args.len) : (k += 2) {
        const v = std.fmt.parseInt(u64, args[k + 1], 10) catch 0;
        if (std.mem.eql(u8, args[k], "--seconds")) seconds = v else if (std.mem.eql(u8, args[k], "--seed")) seed = v else {
            std.debug.print("usage: fhe-ntt-fuzz [--seconds N] [--seed N]\n", .{});
            std.process.exit(2);
        }
    }
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const max_n = 4096;
    const buf = try gpa.alloc(u64, 6 * max_n);
    defer gpa.free(buf);
    const perm = try gpa.alloc(u32, 2 * max_n);
    defer gpa.free(perm);

    const start = Io.Clock.awake.now(io);
    var rounds: u64 = 0;
    while (true) : (rounds += 1) {
        if (rounds % 16 == 0) {
            const secs = @divFloor(start.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_s);
            if (secs >= seconds) break;
        }
        const log_n: u6 = 2 + r.uintLessThan(u6, 11);
        const n = @as(usize, 1) << log_n;
        const bits = 20 + r.uintLessThan(u6, 42);
        const limit = @min((@as(u64, 1) << bits) + r.uintLessThan(u64, @as(u64, 1) << (bits - 1)), ntt.max_modulus);
        const q = ntt.primeBelow(limit, n, &.{}) orelse continue;
        const m = ntt.Modulus.init(q);

        for (0..64) |_| {
            const x = r.int(u128);
            if (m.reduce128(x) != x % q) fail("reduce128", seed, rounds, n, q);
            const y = r.int(u64);
            if (m.reduce(y) != y % q) fail("reduce", seed, rounds, n, q);
            const w = r.uintLessThan(u64, q);
            const want: u64 = @intCast(@as(u128, w) * y % q);
            if (ntt.mulShoup(y, w, ntt.shoup(w, q), q) != want) fail("mulShoup", seed, rounds, n, q);
        }

        var t = try ntt.Table.init(gpa, q, n);
        defer t.deinit(gpa);
        const a = buf[0..n];
        const b = buf[n .. 2 * n];
        const fa = buf[2 * n .. 3 * n];
        const fb = buf[3 * n .. 4 * n];
        const x = buf[4 * n .. 5 * n];
        const y = buf[5 * n .. 6 * n];
        fill(r, q, a);
        fill(r, q, b);
        @memcpy(fa, a);
        @memcpy(x, a);
        t.forwardScalar(fa);
        t.forwardVec(x);
        if (!std.mem.eql(u64, fa, x)) fail("forward: scalar and vector differ", seed, rounds, n, q);
        for (fa) |v| if (v >= q) fail("forward: a word is not below q", seed, rounds, n, q);
        t.inverseScalar(x);
        if (!std.mem.eql(u64, a, x)) fail("inverse (scalar) of forward", seed, rounds, n, q);
        @memcpy(x, fa);
        t.inverseVec(x);
        if (!std.mem.eql(u64, a, x)) fail("inverse (vector) of forward", seed, rounds, n, q);

        @memcpy(fb, b);
        t.forward(fb);
        ntt.addInto(m, x, a, b);
        t.forward(x);
        ntt.addInto(m, y, fa, fb);
        if (!std.mem.eql(u64, x, y)) fail("the transform of a sum", seed, rounds, n, q);

        if (n <= 64) {
            ntt.mulSchoolbook(m, x, a, b);
            ntt.mulInto(m, y, fa, fb);
            t.inverse(y);
            if (!std.mem.eql(u64, x, y)) fail("the product", seed, rounds, n, q);
        }

        const g = 2 * r.uintLessThan(u64, n) + 1;
        const two_n: u64 = 2 * @as(u64, n);
        // g^-1 modulo 2n: g^(n - 1), because the group has the exponent n / 2.
        var g_inv: u64 = 1;
        for (0..n - 1) |_| g_inv = g_inv * g % two_n;
        ntt.galoisPerm(perm[0..n], log_n, g);
        ntt.galoisPerm(perm[n .. 2 * n], log_n, g_inv);
        for (0..n) |i| {
            if (perm[n + perm[i]] != i) fail("the automorphism tables", seed, rounds, n, q);
        }
    }
    std.debug.print("{d} rounds, {d} s, seed {d}\n", .{ rounds, seconds, seed });
}

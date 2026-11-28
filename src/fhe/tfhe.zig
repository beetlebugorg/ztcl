//! TFHE, the scheme for encrypted bits and small integers with a
//! bootstrap in each gate (Chillotti, Gama, Georgieva, and Izabachene).
//!
//! A value is a 32-bit word of the torus: the word x is the real number
//! x / 2^32 modulo 1. An LWE ciphertext is n words a and one word b, and
//! its phase is b - <a, s>. A bit is the phase 1/8 (true) or -1/8
//! (false).
//!
//! The bootstrap is the blind rotation of the paper: an accumulator in
//! the ring of degree N starts as the test polynomial times X^-b, and one
//! external product with the bootstrap key of each key bit multiplies it
//! by X^(a_i * s_i). The constant coefficient of the result is the value
//! of the test polynomial at the phase. A test polynomial with one value
//! in each place gives the sign of the phase: a gate. A test polynomial
//! with the values of a table gives the table at the encrypted integer:
//! the programmable bootstrap.
//!
//! The paper multiplies the polynomials with a floating-point FFT. This
//! file uses the NTT of `ntt.zig` with one prime of 59 bits. Each
//! coefficient of an external product is an integer below 2^50 in
//! magnitude, so the product modulo the prime is the exact integer, and
//! the result modulo 2^32 has no rounding error.
//!
//! The prototype is not constant time, and it does not clear secret
//! data from freed memory.
//!
//! The sources are in docs/references/fhe.md.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ntt = @import("ntt.zig");
const Allocator = std.mem.Allocator;

pub const Params = struct {
    /// The dimension of the LWE key.
    n: u32,
    /// The degree of the ring of the bootstrap. The rank k is 1.
    big_n: u32,
    /// The deviation of the error of an LWE ciphertext and of the
    /// key-switch key, as a part of the torus.
    lwe_sigma: f64,
    /// The deviation of the error of the bootstrap key.
    bk_sigma: f64,
    /// The length and the base (in bits) of the gadget of the bootstrap key.
    bk_l: u32,
    bk_bg_bit: u5,
    /// The length and the base (in bits) of the key-switch digits.
    ks_t: u32,
    ks_base_bit: u5,
};

/// The parameter set that the TFHE library has for 128 bits of security
/// (the set `TFHE_LIB_PARAMETERS` in the benchmark table of TFHE-rs).
pub const lib_128: Params = .{
    .n = 630,
    .big_n = 1024,
    .lwe_sigma = 0x1p-15,
    .bk_sigma = 0x1p-25,
    .bk_l = 3,
    .bk_bg_bit = 7,
    .ks_t = 8,
    .ks_base_bit = 2,
};

/// The word of the torus value num / den.
pub fn torus(num: i64, den: i64) u32 {
    return @truncate(@as(u64, @bitCast(@divFloor(num << 32, den))));
}

pub const Context = struct {
    gpa: Allocator,
    params: Params,
    table: ntt.Table,

    pub fn init(gpa: Allocator, params: Params) !*Context {
        const big_n: usize = params.big_n;
        if (!std.math.isPowerOfTwo(big_n) or big_n < 8 or big_n > 4096) return error.BadParams;
        if (params.bk_l * params.bk_bg_bit > 32 or params.ks_t * params.ks_base_bit > 31) return error.BadParams;
        // The sum of 2 * l products of a digit, below 2^(bg_bit - 1), and
        // a word of the key, below 2^31, in N places must stay below q / 2.
        const bound_bits = @as(u32, params.bk_bg_bit) - 1 + 31 + std.math.log2_int(usize, big_n) + std.math.log2_int_ceil(u32, 2 * params.bk_l);
        if (bound_bits > 57) return error.BadParams;
        const ctx = try gpa.create(Context);
        errdefer gpa.destroy(ctx);
        const q = ntt.primeBelow(1 << 59, big_n, &.{}) orelse return error.BadParams;
        ctx.* = .{ .gpa = gpa, .params = params, .table = try ntt.Table.init(gpa, q, big_n) };
        return ctx;
    }

    pub fn deinit(ctx: *Context) void {
        ctx.table.deinit(ctx.gpa);
        ctx.gpa.destroy(ctx);
    }

    /// The count of words of a ciphertext.
    pub fn lweLen(ctx: *const Context) usize {
        return ctx.params.n + 1;
    }
};

pub const SecretKey = struct {
    /// The bits of the LWE key.
    lwe: []u8,
    /// The bits of the ring key.
    ring: []u8,

    pub fn deinit(k: SecretKey, gpa: Allocator) void {
        gpa.free(k.lwe);
        gpa.free(k.ring);
    }
};

/// The public key of the gates.
pub const CloudKey = struct {
    /// For each bit of the LWE key, 2 * l rows of two polynomials in NTT
    /// form: the gadget encryption of the bit under the ring key.
    bk: []u64,
    /// For each bit i of the ring key, each digit place j, and each digit
    /// v from 1, the LWE encryption of v * bit / base^(j + 1).
    ks: []u32,

    pub fn deinit(k: CloudKey, gpa: Allocator) void {
        gpa.free(k.bk);
        gpa.free(k.ks);
    }

    pub fn bytes(k: CloudKey) usize {
        return k.bk.len * 8 + k.ks.len * 4;
    }
};

fn gaussian(rng: std.Random, sigma: f64) u32 {
    const x: i64 = @intFromFloat(@round(rng.floatNorm(f64) * sigma * 0x1p32));
    return @truncate(@as(u64, @bitCast(x)));
}

/// An LWE encryption of the torus word `mu` in `out` (the words a, then
/// b).
fn lweEncrypt(rng: std.Random, key: []const u8, mu: u32, sigma: f64, out: []u32) void {
    var b = mu +% gaussian(rng, sigma);
    for (out[0..key.len], key) |*a, s| {
        a.* = rng.int(u32);
        if (s != 0) b +%= a.*;
    }
    out[key.len] = b;
}

fn lwePhase(key: []const u8, ct: []const u32) u32 {
    var p = ct[key.len];
    for (ct[0..key.len], key) |a, s| {
        if (s != 0) p -%= a;
    }
    return p;
}

/// The residue modulo q of a torus word as a signed 32-bit integer.
inline fn liftSigned(q: u64, x: u32) u64 {
    const v: i32 = @bitCast(x);
    return if (v < 0) q - @as(u64, @intCast(-@as(i64, v))) else @intCast(v);
}

/// The low 32 bits of the integer in (-q/2, q/2) of a residue.
inline fn lowerCentered(q: u64, v: u64) u32 {
    return @truncate(if (v > q / 2) v -% q else v);
}

pub fn keygen(ctx: *const Context, rng: std.Random) !struct { SecretKey, CloudKey } {
    const gpa = ctx.gpa;
    const p = ctx.params;
    const big_n: usize = p.big_n;
    const t = &ctx.table;
    const q = t.m.q;

    const lwe = try gpa.alloc(u8, p.n);
    errdefer gpa.free(lwe);
    const ring = try gpa.alloc(u8, big_n);
    errdefer gpa.free(ring);
    for (lwe) |*s| s.* = rng.int(u1);
    for (ring) |*s| s.* = rng.int(u1);

    const rows = 2 * p.bk_l;
    const bk = try gpa.alloc(u64, @as(usize, p.n) * rows * 2 * big_n);
    errdefer gpa.free(bk);
    const work = try gpa.alloc(u64, 2 * big_n);
    defer gpa.free(work);
    const s_ntt = work[0..big_n];
    const prod = work[big_n..];
    for (s_ntt, ring) |*o, s| o.* = s;
    t.forward(s_ntt);
    for (0..p.n) |i| {
        for (0..rows) |r| {
            const ra = bk[((i * rows + r) * 2) * big_n ..][0..big_n];
            const rb = bk[((i * rows + r) * 2 + 1) * big_n ..][0..big_n];
            // b = a * s + e in the ring, with a in [0, 2^32).
            for (ra) |*a| a.* = rng.int(u32);
            @memcpy(prod, ra);
            t.forward(prod);
            ntt.mulInto(t.m, prod, prod, s_ntt);
            t.inverse(prod);
            for (rb, prod) |*b, x| b.* = lowerCentered(q, x) +% gaussian(rng, p.bk_sigma);
            // The gadget: the key bit over Bg^(j + 1) in one part.
            if (lwe[i] != 0) {
                const j: u5 = @intCast(r % p.bk_l);
                const g = @as(u32, 1) << @intCast(32 - (@as(u32, j) + 1) * p.bk_bg_bit);
                const part = if (r < p.bk_l) ra else rb;
                part[0] = @as(u32, @truncate(part[0])) +% g;
            }
            for (ra) |*a| a.* = liftSigned(q, @truncate(a.*));
            for (rb) |*b| b.* = liftSigned(q, @truncate(b.*));
            t.forward(ra);
            t.forward(rb);
        }
    }

    const base: usize = @as(usize, 1) << p.ks_base_bit;
    const len = p.n + 1;
    const ks = try gpa.alloc(u32, big_n * p.ks_t * (base - 1) * len);
    errdefer gpa.free(ks);
    var at: usize = 0;
    for (0..big_n) |i| for (0..p.ks_t) |j| for (1..base) |v| {
        const unit = @as(u32, 1) << @intCast(32 - (j + 1) * p.ks_base_bit);
        const mu: u32 = if (ring[i] != 0) @as(u32, @intCast(v)) *% unit else 0;
        lweEncrypt(rng, lwe, mu, p.lwe_sigma, ks[at..][0..len]);
        at += len;
    };
    return .{ .{ .lwe = lwe, .ring = ring }, .{ .bk = bk, .ks = ks } };
}

/// The encryption of a bit.
pub fn encryptBit(ctx: *const Context, sk: *const SecretKey, rng: std.Random, bit: bool, out: []u32) void {
    lweEncrypt(rng, sk.lwe, if (bit) torus(1, 8) else torus(-1, 8), ctx.params.lwe_sigma, out);
}

pub fn decryptBit(sk: *const SecretKey, ct: []const u32) bool {
    return @as(i32, @bitCast(lwePhase(sk.lwe, ct))) > 0;
}

/// The encryption of an integer m below `space`, as the phase
/// m / (2 * space). The top half of the torus stays free.
pub fn encryptInt(ctx: *const Context, sk: *const SecretKey, rng: std.Random, m: u32, space: u32, out: []u32) void {
    lweEncrypt(rng, sk.lwe, torus(m, 2 * @as(i64, space)), ctx.params.lwe_sigma, out);
}

pub fn decryptInt(sk: *const SecretKey, ct: []const u32, space: u32) u32 {
    const unit = torus(1, 2 * @as(i64, space));
    return ((lwePhase(sk.lwe, ct) +% unit / 2) / unit) % space;
}

/// out = X^a * in modulo X^N + 1, for 0 < a < 2N.
fn mulByXai(out: []u32, in: []const u32, a: usize) void {
    const big_n = in.len;
    if (a < big_n) {
        for (0..a) |k| out[k] = 0 -% in[k + big_n - a];
        for (a..big_n) |k| out[k] = in[k - a];
    } else {
        const r = a - big_n;
        for (0..r) |k| out[k] = in[k + big_n - r];
        for (r..big_n) |k| out[k] = 0 -% in[k - r];
    }
}

/// The scratch memory of one bootstrap.
const Work = struct {
    acc: []u32,
    diff: []u32,
    dec: []u64,
    sum: []u128,
    big: []u32,

    fn init(ctx: *const Context) !Work {
        const gpa = ctx.gpa;
        const big_n: usize = ctx.params.big_n;
        const acc = try gpa.alloc(u32, 2 * big_n);
        errdefer gpa.free(acc);
        const diff = try gpa.alloc(u32, 2 * big_n);
        errdefer gpa.free(diff);
        const dec = try gpa.alloc(u64, big_n);
        errdefer gpa.free(dec);
        const sum = try gpa.alloc(u128, 2 * big_n);
        errdefer gpa.free(sum);
        const big = try gpa.alloc(u32, big_n + 1);
        return .{ .acc = acc, .diff = diff, .dec = dec, .sum = sum, .big = big };
    }

    fn deinit(w: Work, gpa: Allocator) void {
        gpa.free(w.acc);
        gpa.free(w.diff);
        gpa.free(w.dec);
        gpa.free(w.sum);
        gpa.free(w.big);
    }
};

/// acc = acc + bk_i (*) (X^a * acc - acc): the accumulator times X^a when
/// the key bit is 1, and with no change when it is 0.
fn rotateStep(ctx: *const Context, w: *const Work, bk_i: []const u64, a: usize) void {
    const p = ctx.params;
    const big_n: usize = p.big_n;
    const t = &ctx.table;
    const q = t.m.q;
    for (0..2) |c| {
        const acc = w.acc[c * big_n ..][0..big_n];
        const diff = w.diff[c * big_n ..][0..big_n];
        mulByXai(diff, acc, a);
        for (diff, acc) |*d, x| d.* -%= x;
    }
    @memset(w.sum, 0);
    const half_bg: u32 = @as(u32, 1) << (p.bk_bg_bit - 1);
    const mask: u32 = 2 * half_bg - 1;
    var offset: u32 = 0;
    for (1..p.bk_l + 1) |j| offset +%= half_bg << @intCast(32 - j * p.bk_bg_bit);
    for (0..2) |c| {
        const diff = w.diff[c * big_n ..][0..big_n];
        for (0..p.bk_l) |j| {
            const shift: u5 = @intCast(32 - (j + 1) * p.bk_bg_bit);
            for (w.dec, diff) |*o, x| {
                const digit = ((x +% offset) >> shift) & mask;
                o.* = if (digit >= half_bg) digit - half_bg else q - (half_bg - digit);
            }
            t.forward(w.dec);
            const r = c * p.bk_l + j;
            const ka = bk_i[(r * 2) * big_n ..][0..big_n];
            const kb = bk_i[(r * 2 + 1) * big_n ..][0..big_n];
            for (w.sum[0..big_n], w.sum[big_n..], w.dec, ka, kb) |*s0, *s1, d, x, y| {
                s0.* += @as(u128, d) * x;
                s1.* += @as(u128, d) * y;
            }
        }
    }
    for (0..2) |c| {
        for (w.dec, w.sum[c * big_n ..][0..big_n]) |*o, s| o.* = t.m.reduce128(s);
        t.inverse(w.dec);
        for (w.acc[c * big_n ..][0..big_n], w.dec) |*o, v| o.* +%= lowerCentered(q, v);
    }
}

/// The blind rotation and the extraction. `ct` is under the LWE key.
/// The result in `w.big` is under the ring key: N words a and one word
/// b, with the phase tv(phase of ct) and a small new error.
fn blindRotate(ctx: *const Context, ck: *const CloudKey, w: *const Work, ct: []const u32, tv: []const u32) void {
    const p = ctx.params;
    const big_n: usize = p.big_n;
    const log_2n: u5 = @intCast(std.math.log2_int(usize, big_n) + 1);
    const shift: u5 = @intCast(32 - @as(u32, log_2n));
    const round: u32 = @as(u32, 1) << (shift - 1);
    const two_n = 2 * big_n;
    const bbar: usize = (ct[p.n] +% round) >> shift;
    @memset(w.acc[0..big_n], 0);
    if (bbar == 0) @memcpy(w.acc[big_n..], tv) else mulByXai(w.acc[big_n..], tv, two_n - bbar);
    const row_len = 2 * p.bk_l * 2 * big_n;
    for (0..p.n) |i| {
        const abar: usize = (ct[i] +% round) >> shift;
        if (abar == 0) continue;
        rotateStep(ctx, w, ck.bk[i * row_len ..][0..row_len], abar);
    }
    // The constant coefficient of b - a * s is b_0 - a_0 * s_0 +
    // sum(a_(N - j) * s_j).
    const a = w.acc[0..big_n];
    w.big[0] = a[0];
    for (1..big_n) |j| w.big[j] = 0 -% a[big_n - j];
    w.big[big_n] = w.acc[big_n];
}

/// From the ring key to the LWE key.
fn keySwitch(ctx: *const Context, ck: *const CloudKey, big: []const u32, out: []u32) void {
    const p = ctx.params;
    const big_n: usize = p.big_n;
    const len = p.n + 1;
    const base: usize = @as(usize, 1) << p.ks_base_bit;
    const mask: u32 = @intCast(base - 1);
    const round: u32 = @as(u32, 1) << @intCast(31 - p.ks_t * p.ks_base_bit);
    @memset(out[0..p.n], 0);
    out[p.n] = big[big_n];
    for (0..big_n) |i| {
        const a = big[i] +% round;
        for (0..p.ks_t) |j| {
            const digit = (a >> @intCast(32 - (j + 1) * p.ks_base_bit)) & mask;
            if (digit == 0) continue;
            const k = ck.ks[((i * p.ks_t + j) * (base - 1) + digit - 1) * len ..][0..len];
            for (out, k) |*o, x| o.* -%= x;
        }
    }
}

/// The bootstrap with a test polynomial, then the key switch. `out` gets
/// a ciphertext of the value of `tv` at the phase of `ct`: tv[j] for a
/// phase of j / 2N in the lower half of the torus, and -tv[j] for a
/// phase of 1/2 + j / 2N.
pub fn bootstrap(ctx: *const Context, ck: *const CloudKey, ct: []const u32, tv: []const u32, out: []u32) !void {
    const w = try Work.init(ctx);
    defer w.deinit(ctx.gpa);
    blindRotate(ctx, ck, &w, ct, tv);
    keySwitch(ctx, ck, w.big, out);
}

/// The programmable bootstrap of an integer below `space`. `table` has
/// the result for each integer, also below `space`.
pub fn lookup(ctx: *const Context, ck: *const CloudKey, ct: []const u32, space: u32, table: []const u32, out: []u32) !void {
    const gpa = ctx.gpa;
    const big_n: usize = ctx.params.big_n;
    if (table.len != space or big_n % space != 0) return error.BadTable;
    const tv = try gpa.alloc(u32, big_n);
    defer gpa.free(tv);
    const sector = big_n / space;
    for (tv, 0..) |*o, j| o.* = torus(table[j / sector], 2 * @as(i64, space));
    // A shift by half a sector puts each integer in the middle of its
    // sector.
    const shifted = try gpa.dupe(u32, ct);
    defer gpa.free(shifted);
    shifted[ctx.params.n] +%= torus(1, 4 * @as(i64, space));
    try bootstrap(ctx, ck, shifted, tv, out);
}

pub const Gate = enum { nand, @"and", @"or", xor, nor, xnor };

/// A gate of two encrypted bits: a sum of the inputs and a constant,
/// then the bootstrap of the sign.
pub fn gate(ctx: *const Context, ck: *const CloudKey, op: Gate, a: []const u32, b: []const u32, out: []u32) !void {
    const gpa = ctx.gpa;
    const n = ctx.params.n;
    const sum = try gpa.alloc(u32, n + 1);
    defer gpa.free(sum);
    switch (op) {
        .nand, .nor => for (sum, a, b) |*o, x, y| {
            o.* = 0 -% x -% y;
        },
        .@"and", .@"or" => for (sum, a, b) |*o, x, y| {
            o.* = x +% y;
        },
        .xor => for (sum, a, b) |*o, x, y| {
            o.* = 2 *% (x +% y);
        },
        .xnor => for (sum, a, b) |*o, x, y| {
            o.* = 0 -% 2 *% (x +% y);
        },
    }
    sum[n] +%= switch (op) {
        .nand, .@"or" => torus(1, 8),
        .@"and", .nor => torus(-1, 8),
        .xor => torus(1, 4),
        .xnor => torus(-1, 4),
    };
    const tv = try gpa.alloc(u32, ctx.params.big_n);
    defer gpa.free(tv);
    @memset(tv, torus(1, 8));
    try bootstrap(ctx, ck, sum, tv, out);
}

/// The negation of a bit. It needs no bootstrap.
pub fn not(a: []const u32, out: []u32) void {
    for (out, a) |*o, x| o.* = 0 -% x;
}

const testing = std.testing;

/// A small set for the tests. It has no security.
const test_params: Params = .{
    .n = 64,
    .big_n = 256,
    .lwe_sigma = 0x1p-22,
    .bk_sigma = 0x1p-28,
    .bk_l = 3,
    .bk_bg_bit = 7,
    .ks_t = 8,
    .ks_base_bit = 2,
};

fn truth(op: Gate, a: bool, b: bool) bool {
    return switch (op) {
        .nand => !(a and b),
        .@"and" => a and b,
        .@"or" => a or b,
        .xor => a != b,
        .nor => !(a or b),
        .xnor => a == b,
    };
}

fn gateTable(params: Params, seed: u64) !void {
    const gpa = testing.allocator;
    const ctx = try Context.init(gpa, params);
    defer ctx.deinit();
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const sk, const ck = try keygen(ctx, rng);
    defer sk.deinit(gpa);
    defer ck.deinit(gpa);
    const len = ctx.lweLen();
    const buf = try gpa.alloc(u32, 4 * len);
    defer gpa.free(buf);
    const ca = buf[0..len];
    const cb = buf[len .. 2 * len];
    const out = buf[2 * len .. 3 * len];
    const out2 = buf[3 * len ..];
    for ([_]bool{ false, true }) |a| for ([_]bool{ false, true }) |b| {
        encryptBit(ctx, &sk, rng, a, ca);
        encryptBit(ctx, &sk, rng, b, cb);
        try testing.expectEqual(a, decryptBit(&sk, ca));
        inline for (comptime std.enums.values(Gate)) |op| {
            try gate(ctx, &ck, op, ca, cb, out);
            try testing.expectEqual(truth(op, a, b), decryptBit(&sk, out));
            // The result of a gate is the input of the next gate.
            try gate(ctx, &ck, .nand, out, cb, out2);
            try testing.expectEqual(!(truth(op, a, b) and b), decryptBit(&sk, out2));
        }
        not(ca, out);
        try testing.expectEqual(!a, decryptBit(&sk, out));
    };
}

test "each gate has its truth table (small parameters)" {
    try gateTable(test_params, 21);
}

test "each gate has its truth table (128-bit parameters)" {
    if (@import("builtin").mode == .debug) return error.SkipZigTest;
    try gateTable(lib_128, 22);
}

test "the programmable bootstrap gives a table at an encrypted integer" {
    const gpa = testing.allocator;
    const ctx = try Context.init(gpa, test_params);
    defer ctx.deinit();
    var prng = std.Random.DefaultPrng.init(23);
    const rng = prng.random();
    const sk, const ck = try keygen(ctx, rng);
    defer sk.deinit(gpa);
    defer ck.deinit(gpa);
    const len = ctx.lweLen();
    const buf = try gpa.alloc(u32, 2 * len);
    defer gpa.free(buf);
    const ct = buf[0..len];
    const out = buf[len..];
    // m -> m^2 + 1 modulo 4.
    const table = [_]u32{ 1, 2, 1, 2 };
    for (0..4) |m| {
        encryptInt(ctx, &sk, rng, @intCast(m), 4, ct);
        try testing.expectEqual(@as(u32, @intCast(m)), decryptInt(&sk, ct, 4));
        try lookup(ctx, &ck, ct, 4, &table, out);
        try testing.expectEqual(table[m], decryptInt(&sk, out, 4));
    }
}

//! CKKS, the scheme for approximate arithmetic on encrypted vectors of
//! real numbers (Cheon, Kim, Kim, and Song), in its full-RNS form (Cheon,
//! Han, Kim, Kim, and Song).
//!
//! A ciphertext is a pair of polynomials of Z_Q[X]/(X^n + 1). Q is a
//! product of primes, and each polynomial is one row of residues for each
//! prime, in NTT form. The level of a ciphertext is the index of its last
//! prime. A rescale divides by the last prime and removes its row.
//!
//! Key switching has one special prime P and one digit for each prime of
//! Q. The key of digit i is an encryption, modulo QP, of P times the new
//! secret in the row of prime i. A switch multiplies the residue row i of
//! the input by key i, adds the products, and divides by P. This is the
//! special-modulus method of Gentry, Halevi, and Smart on the RNS digits
//! of Bajard, Eynard, Hasan, and Zucca.
//!
//! The scale of each level is fixed: S[L] = 2^scale_bits and
//! S[l-1] = S[l]^2 / q_l. The setup selects q_l as the prime nearest to
//! S[l]^2 / 2^scale_bits, so each S[l] stays near 2^scale_bits (Kim,
//! Papadimitriou, and Polyakov). `mul`, `mulPlain`, `mulScalar`, and
//! `toLevel` give a result with the scale of its level, so `add` adds
//! ciphertexts of one level with no change.
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
const Modulus = ntt.Modulus;

/// The standard deviation of the error, from the HomomorphicEncryption.org
/// standard.
pub const sigma = 3.2;
/// The largest count of primes of Q. The 128-bit sums of `keySwitch`
/// hold this many products.
pub const max_primes = 31;

pub const Params = struct {
    log_n: u6,
    /// The count of primes after the first prime: the count of rescales.
    levels: u8,
    first_bits: u6 = 60,
    scale_bits: u6 = 40,
    special_bits: u6 = 60,

    /// The size of QP in bits, as the sum of the nominal sizes.
    pub fn totalBits(p: Params) u32 {
        return @as(u32, p.first_bits) + @as(u32, p.levels) * p.scale_bits + p.special_bits;
    }

    /// The largest size of QP in bits for 128 bits of classical security
    /// with a ternary secret, from Table 1 of the standard. The table
    /// stops at n = 2^15. For n = 2^16 this function gives the limit of
    /// 2^15: a larger n with the same modulus is a harder problem.
    pub fn maxBits(log_n: u6) ?u32 {
        return switch (log_n) {
            10 => 27,
            11 => 54,
            12 => 109,
            13 => 218,
            14 => 438,
            15, 16 => 881,
            else => null,
        };
    }
};

/// The parameter sets of the measurements. The sizes of QP are 200, 360,
/// 600, and 600 bits.
pub const set_13: Params = .{ .log_n = 13, .levels = 2 };
pub const set_14: Params = .{ .log_n = 14, .levels = 6 };
pub const set_15: Params = .{ .log_n = 15, .levels = 12 };
pub const set_16: Params = .{ .log_n = 16, .levels = 12 };

const Complex = struct { re: f64, im: f64 };

pub const Context = struct {
    gpa: Allocator,
    params: Params,
    n: usize,
    slots: usize,
    /// The count of primes of Q.
    nq: usize,
    /// The tables of q_0 .. q_L, then P.
    tables: []ntt.Table,
    /// S[l], the scale of level l.
    scales: []f64,
    /// P mod q_i, P^-1 mod q_i, and the Shoup word of the inverse.
    p_mod: []u64,
    p_inv: []u64,
    p_inv_p: []u64,
    /// (q_0 * ... * q_(i-1))^-1 mod q_i, for the decoder.
    garner: []u64,
    /// 5^j mod 2n.
    rot_group: []u32,
    /// exp(2 pi i k / 2n).
    ksi: []Complex,
    perms: std.AutoHashMapUnmanaged(u64, []u32) = .empty,

    pub fn init(gpa: Allocator, params: Params) !*Context {
        if (params.log_n < 3 or params.log_n > 16) return error.BadParams;
        if (params.levels + 1 > max_primes) return error.BadParams;
        if (params.first_bits > 60 or params.special_bits > 60 or params.scale_bits < 20) return error.BadParams;
        const n = @as(usize, 1) << params.log_n;
        const nq = @as(usize, params.levels) + 1;
        const ctx = try gpa.create(Context);
        errdefer gpa.destroy(ctx);

        var primes: [max_primes + 1]u64 = undefined;
        // P is the largest prime, so each residue of Q is below P.
        primes[nq] = ntt.primeBelow(@as(u64, 1) << params.special_bits, n, &.{}) orelse return error.BadParams;
        primes[0] = ntt.primeBelow(@as(u64, 1) << params.first_bits, n, primes[nq .. nq + 1]) orelse return error.BadParams;
        const scales = try gpa.alloc(f64, nq);
        errdefer gpa.free(scales);
        const delta: f64 = @floatFromInt(@as(u64, 1) << params.scale_bits);
        scales[nq - 1] = delta;
        var l = nq - 1;
        while (l > 0) : (l -= 1) {
            var used: [max_primes + 1]u64 = undefined;
            used[0] = primes[0];
            used[1] = primes[nq];
            const others = primes[l + 1 .. nq];
            @memcpy(used[2..][0..others.len], others);
            const target: u64 = @intFromFloat(@round(scales[l] * scales[l] / delta));
            primes[l] = ntt.primeNear(target, n, used[0 .. 2 + others.len]) orelse return error.BadParams;
            scales[l - 1] = scales[l] * scales[l] / @as(f64, @floatFromInt(primes[l]));
        }

        const tables = try gpa.alloc(ntt.Table, nq + 1);
        errdefer gpa.free(tables);
        var made: usize = 0;
        errdefer for (tables[0..made]) |*t| t.deinit(gpa);
        while (made < nq + 1) : (made += 1) tables[made] = try ntt.Table.init(gpa, primes[made], n);

        const words = try gpa.alloc(u64, nq * 4);
        errdefer gpa.free(words);
        const p = primes[nq];
        for (0..nq) |i| {
            const m = tables[i].m;
            words[i] = p % m.q;
            words[nq + i] = m.inv(words[i]);
            words[2 * nq + i] = ntt.shoup(words[nq + i], m.q);
            var prod: u64 = 1;
            for (0..i) |j| prod = m.mul(prod, primes[j] % m.q);
            words[3 * nq + i] = m.inv(prod);
        }

        const nh = n / 2;
        const rot_group = try gpa.alloc(u32, nh);
        errdefer gpa.free(rot_group);
        var g: usize = 1;
        for (rot_group) |*r| {
            r.* = @intCast(g);
            g = g * 5 % (2 * n);
        }
        const ksi = try gpa.alloc(Complex, 2 * n + 1);
        errdefer gpa.free(ksi);
        for (ksi, 0..) |*k, i| {
            const a = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(2 * n));
            k.* = .{ .re = @cos(a), .im = @sin(a) };
        }

        ctx.* = .{
            .gpa = gpa,
            .params = params,
            .n = n,
            .slots = nh,
            .nq = nq,
            .tables = tables,
            .scales = scales,
            .p_mod = words[0..nq],
            .p_inv = words[nq .. 2 * nq],
            .p_inv_p = words[2 * nq .. 3 * nq],
            .garner = words[3 * nq ..],
            .rot_group = rot_group,
            .ksi = ksi,
        };
        return ctx;
    }

    pub fn deinit(ctx: *Context) void {
        const gpa = ctx.gpa;
        var it = ctx.perms.valueIterator();
        while (it.next()) |v| gpa.free(v.*);
        ctx.perms.deinit(gpa);
        gpa.free(ctx.ksi);
        gpa.free(ctx.rot_group);
        gpa.free(ctx.p_mod.ptr[0 .. ctx.nq * 4]);
        for (ctx.tables) |*t| t.deinit(gpa);
        gpa.free(ctx.tables);
        gpa.free(ctx.scales);
        gpa.destroy(ctx);
    }

    /// The level of a new ciphertext.
    pub fn top(ctx: *const Context) usize {
        return ctx.nq - 1;
    }

    fn row(ctx: *const Context, buf: anytype, i: usize) @TypeOf(buf[0..ctx.n]) {
        return buf[i * ctx.n ..][0..ctx.n];
    }

    /// The Galois element of a rotation of the slots to the left by
    /// `steps`.
    pub fn galoisElt(ctx: *const Context, steps: i64) u64 {
        const r: usize = @intCast(@mod(steps, @as(i64, @intCast(ctx.slots))));
        return ctx.rot_group[r];
    }

    fn perm(ctx: *Context, g: u64) ![]const u32 {
        if (ctx.perms.get(g)) |p| return p;
        const p = try ctx.gpa.alloc(u32, ctx.n);
        errdefer ctx.gpa.free(p);
        ntt.galoisPerm(p, ctx.params.log_n, g);
        try ctx.perms.put(ctx.gpa, g, p);
        return p;
    }

    // ---- The encoder: the canonical embedding of HEAAN ----

    fn bitReverse(vals: []Complex) void {
        const bits: u6 = @intCast(std.math.log2_int(usize, vals.len));
        for (0..vals.len) |i| {
            const j = ntt.bitrev(i, bits);
            if (i < j) std.mem.swap(Complex, &vals[i], &vals[j]);
        }
    }

    /// From the coefficients to the slots.
    fn fftSpecial(ctx: *const Context, vals: []Complex) void {
        const size = vals.len;
        const m = 2 * ctx.n;
        bitReverse(vals);
        var len: usize = 2;
        while (len <= size) : (len <<= 1) {
            const lenh = len >> 1;
            const lenq = len << 2;
            var i: usize = 0;
            while (i < size) : (i += len) {
                for (0..lenh) |j| {
                    const w = ctx.ksi[(ctx.rot_group[j] % lenq) * (m / lenq)];
                    const u = vals[i + j];
                    const x = vals[i + j + lenh];
                    const v: Complex = .{ .re = x.re * w.re - x.im * w.im, .im = x.re * w.im + x.im * w.re };
                    vals[i + j] = .{ .re = u.re + v.re, .im = u.im + v.im };
                    vals[i + j + lenh] = .{ .re = u.re - v.re, .im = u.im - v.im };
                }
            }
        }
    }

    /// From the slots to the coefficients.
    fn fftSpecialInv(ctx: *const Context, vals: []Complex) void {
        const size = vals.len;
        const m = 2 * ctx.n;
        var len = size;
        while (len >= 2) : (len >>= 1) {
            const lenh = len >> 1;
            const lenq = len << 2;
            var i: usize = 0;
            while (i < size) : (i += len) {
                for (0..lenh) |j| {
                    const w = ctx.ksi[(lenq - ctx.rot_group[j] % lenq) * (m / lenq)];
                    const a = vals[i + j];
                    const b = vals[i + j + lenh];
                    const d: Complex = .{ .re = a.re - b.re, .im = a.im - b.im };
                    vals[i + j] = .{ .re = a.re + b.re, .im = a.im + b.im };
                    vals[i + j + lenh] = .{ .re = d.re * w.re - d.im * w.im, .im = d.re * w.im + d.im * w.re };
                }
            }
        }
        bitReverse(vals);
        const inv = 1.0 / @as(f64, @floatFromInt(size));
        for (vals) |*v| v.* = .{ .re = v.re * inv, .im = v.im * inv };
    }

    /// The plaintext of `values` at a level and a scale. The slots after
    /// the last value are 0.
    pub fn encode(ctx: *const Context, values: []const f64, level: usize, scale: f64) !Plaintext {
        if (values.len > ctx.slots) return error.TooManyValues;
        const gpa = ctx.gpa;
        const n = ctx.n;
        const nh = ctx.slots;
        const vals = try gpa.alloc(Complex, nh);
        defer gpa.free(vals);
        for (vals, 0..) |*v, i| v.* = .{ .re = if (i < values.len) values[i] else 0, .im = 0 };
        ctx.fftSpecialInv(vals);
        const m = try gpa.alloc(u64, (level + 1) * n);
        errdefer gpa.free(m);
        for (0..nh) |i| {
            const parts = [2]f64{ vals[i].re * scale, vals[i].im * scale };
            for (parts, [2]usize{ i, i + nh }) |x, k| {
                if (!(@abs(x) < 0x1p120)) return error.ValueTooLarge;
                const v: i128 = @intFromFloat(@round(x));
                for (0..level + 1) |r| m[r * n + k] = ctx.tables[r].m.fromSigned(v);
            }
        }
        for (0..level + 1) |r| ctx.tables[r].forward(ctx.row(m, r));
        return .{ .m = m, .level = level, .scale = scale };
    }

    /// The residues of round(c * scale), one for each prime of a level.
    fn constResidues(ctx: *const Context, c: f64, scale: f64, level: usize, out: []u64) !void {
        const x = c * scale;
        if (!(@abs(x) < 0x1p120)) return error.ValueTooLarge;
        const v: i128 = @intFromFloat(@round(x));
        for (0..level + 1) |r| out[r] = ctx.tables[r].m.fromSigned(v);
    }

    /// The real parts of the slots of a polynomial in coefficient form.
    /// The coefficients are residues for the primes 0 .. level.
    fn decode(ctx: *const Context, coef: []const u64, level: usize, scale: f64) ![]f64 {
        const gpa = ctx.gpa;
        const n = ctx.n;
        const nh = ctx.slots;
        const real = try gpa.alloc(f64, n);
        defer gpa.free(real);
        ctx.liftCentered(coef, level, real);
        const vals = try gpa.alloc(Complex, nh);
        defer gpa.free(vals);
        for (vals, 0..) |*v, i| v.* = .{ .re = real[i] / scale, .im = real[i + nh] / scale };
        ctx.fftSpecial(vals);
        const out = try gpa.alloc(f64, nh);
        for (out, vals) |*o, v| o.* = v.re;
        return out;
    }

    /// The integer in (-Q/2, Q/2] of each coefficient, as a float. The
    /// mixed-radix digits of Garner give the integer from its residues.
    fn liftCentered(ctx: *const Context, coef: []const u64, level: usize, out: []f64) void {
        const n = ctx.n;
        const k = level + 1;
        var qmod: [max_primes][max_primes]u64 = undefined;
        for (0..k) |i| for (0..i) |j| {
            qmod[i][j] = ctx.tables[j].m.q % ctx.tables[i].m.q;
        };
        // Q and Q / 2 in 64-bit limbs.
        var big_q: [max_primes + 1]u64 = @splat(0);
        big_q[0] = 1;
        for (0..k) |i| mulAddLimbs(big_q[0 .. k + 1], ctx.tables[i].m.q, 0);
        var half: [max_primes + 1]u64 = undefined;
        for (0..k + 1) |i| half[i] = (big_q[i] >> 1) | (if (i + 1 < k + 1) big_q[i + 1] << 63 else 0);

        var digits: [max_primes]u64 = undefined;
        var x: [max_primes + 1]u64 = undefined;
        for (0..n) |c| {
            digits[0] = coef[c];
            for (1..k) |i| {
                const m = ctx.tables[i].m;
                var t = m.reduce(digits[i - 1]);
                var j = i - 1;
                while (j > 0) : (j -= 1) t = m.reduce128(@as(u128, t) * qmod[i][j - 1] + digits[j - 1]);
                digits[i] = m.mul(m.sub(coef[i * n + c], t), ctx.garner[i]);
            }
            @memset(x[0 .. k + 1], 0);
            x[0] = digits[k - 1];
            var i = k - 1;
            while (i > 0) : (i -= 1) mulAddLimbs(x[0 .. k + 1], ctx.tables[i - 1].m.q, digits[i - 1]);
            const negative = greater(x[0 .. k + 1], half[0 .. k + 1]);
            if (negative) {
                var borrow: u1 = 0;
                for (0..k + 1) |w| {
                    const d1 = @subWithOverflow(big_q[w], x[w]);
                    const d2 = @subWithOverflow(d1[0], borrow);
                    x[w] = d2[0];
                    borrow = d1[1] | d2[1];
                }
            }
            var f: f64 = 0;
            var w = k + 1;
            while (w > 0) : (w -= 1) f = f * 0x1p64 + @as(f64, @floatFromInt(x[w - 1]));
            out[c] = if (negative) -f else f;
        }
    }
};

/// x = x * m + a, in limbs with the low limb first.
fn mulAddLimbs(x: []u64, m: u64, a: u64) void {
    var carry: u64 = a;
    for (x) |*w| {
        const t = @as(u128, w.*) * m + carry;
        w.* = @truncate(t);
        carry = @truncate(t >> 64);
    }
}

fn greater(a: []const u64, b: []const u64) bool {
    var i = a.len;
    while (i > 0) : (i -= 1) {
        if (a[i - 1] != b[i - 1]) return a[i - 1] > b[i - 1];
    }
    return false;
}

pub const Plaintext = struct {
    m: []u64,
    level: usize,
    scale: f64,

    pub fn deinit(p: Plaintext, ctx: *const Context) void {
        ctx.gpa.free(p.m);
    }
};

pub const Ciphertext = struct {
    c0: []u64,
    c1: []u64,
    level: usize,
    scale: f64,

    pub fn deinit(ct: Ciphertext, ctx: *const Context) void {
        ctx.gpa.free(ct.c0);
        ctx.gpa.free(ct.c1);
    }

    pub fn clone(ct: Ciphertext, ctx: *const Context) !Ciphertext {
        const c0 = try ctx.gpa.dupe(u64, ct.c0);
        errdefer ctx.gpa.free(c0);
        return .{ .c0 = c0, .c1 = try ctx.gpa.dupe(u64, ct.c1), .level = ct.level, .scale = ct.scale };
    }

    pub fn bytes(ct: Ciphertext) usize {
        return (ct.c0.len + ct.c1.len) * 8;
    }
};

/// The key of one switch: for each digit i, the rows of q_0 .. q_L and P.
pub const SwitchKey = struct {
    b: []u64,
    a: []u64,

    pub fn deinit(k: SwitchKey, gpa: Allocator) void {
        gpa.free(k.b);
        gpa.free(k.a);
    }

    pub fn bytes(k: SwitchKey) usize {
        return (k.b.len + k.a.len) * 8;
    }
};

pub const Keys = struct {
    /// The secret in NTT form, in the rows of q_0 .. q_L and P.
    secret: []u64,
    pub_b: []u64,
    pub_a: []u64,
    relin: SwitchKey,
    galois: std.AutoHashMapUnmanaged(u64, SwitchKey) = .empty,

    pub fn deinit(k: *Keys, ctx: *const Context) void {
        const gpa = ctx.gpa;
        gpa.free(k.secret);
        gpa.free(k.pub_b);
        gpa.free(k.pub_a);
        k.relin.deinit(gpa);
        var it = k.galois.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        k.galois.deinit(gpa);
    }

    pub fn secretBytes(k: *const Keys) usize {
        return k.secret.len * 8;
    }

    pub fn publicBytes(k: *const Keys) usize {
        return (k.pub_b.len + k.pub_a.len) * 8;
    }

    pub fn galoisBytes(k: *const Keys) usize {
        var sum: usize = 0;
        var it = k.galois.valueIterator();
        while (it.next()) |v| sum += v.bytes();
        return sum;
    }
};

fn sampleTernary(rng: std.Random, out: []i8) void {
    for (out) |*o| o.* = @as(i8, @intCast(rng.uintLessThan(u8, 3))) - 1;
}

/// A rounded normal value with the deviation `sigma`, cut at 6 sigma.
fn sampleError(rng: std.Random, out: []i8) void {
    for (out) |*o| {
        while (true) {
            const x = rng.floatNorm(f64) * sigma;
            if (@abs(x) > 6 * sigma) continue;
            o.* = @intFromFloat(@round(x));
            break;
        }
    }
}

fn sampleUniform(rng: std.Random, q: u64, out: []u64) void {
    for (out) |*o| o.* = rng.uintLessThan(u64, q);
}

/// The NTT form of a polynomial with small coefficients, for one prime.
fn smallToNtt(t: *const ntt.Table, small: []const i8, out: []u64) void {
    for (out, small) |*o, s| o.* = if (s < 0) t.m.q - @as(u64, @intCast(-@as(i16, s))) else @intCast(s);
    t.forward(out);
}

/// The keys: the secret, the public key, the relinearization key, and
/// one Galois key for each rotation of `rotations`.
pub fn keygen(ctx: *Context, rng: std.Random, rotations: []const i64) !Keys {
    const gpa = ctx.gpa;
    const n = ctx.n;
    const kr = ctx.nq + 1;
    const small = try gpa.alloc(i8, n);
    defer gpa.free(small);

    const secret = try gpa.alloc(u64, kr * n);
    errdefer gpa.free(secret);
    sampleTernary(rng, small);
    for (0..kr) |j| smallToNtt(&ctx.tables[j], small, ctx.row(secret, j));

    const pub_b = try gpa.alloc(u64, ctx.nq * n);
    errdefer gpa.free(pub_b);
    const pub_a = try gpa.alloc(u64, ctx.nq * n);
    errdefer gpa.free(pub_a);
    sampleError(rng, small);
    for (0..ctx.nq) |j| {
        const m = ctx.tables[j].m;
        const b = ctx.row(pub_b, j);
        const a = ctx.row(pub_a, j);
        sampleUniform(rng, m.q, a);
        smallToNtt(&ctx.tables[j], small, b);
        for (b, a, ctx.row(secret, j)) |*pb, pa, s| pb.* = m.sub(pb.*, m.mul(pa, s));
    }

    // The relinearization key switches from s^2 to s.
    const s2 = try gpa.alloc(u64, kr * n);
    defer gpa.free(s2);
    for (0..kr) |j| ntt.mulInto(ctx.tables[j].m, ctx.row(s2, j), ctx.row(secret, j), ctx.row(secret, j));
    var keys: Keys = .{
        .secret = secret,
        .pub_b = pub_b,
        .pub_a = pub_a,
        .relin = try genSwitchKey(ctx, rng, secret, s2),
    };
    errdefer {
        keys.relin.deinit(gpa);
        var it = keys.galois.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        keys.galois.deinit(gpa);
    }
    for (rotations) |steps| try addGaloisKey(ctx, &keys, rng, ctx.galoisElt(steps));
    return keys;
}

/// Adds the Galois key of the element g, if the keys do not have it.
pub fn addGaloisKey(ctx: *Context, keys: *Keys, rng: std.Random, g: u64) !void {
    if (keys.galois.contains(g)) return;
    const gpa = ctx.gpa;
    const n = ctx.n;
    const kr = ctx.nq + 1;
    const p = try ctx.perm(g);
    const sg = try gpa.alloc(u64, kr * n);
    defer gpa.free(sg);
    for (0..kr) |j| for (ctx.row(sg, j), p) |*o, src| {
        o.* = keys.secret[j * n + src];
    };
    const key = try genSwitchKey(ctx, rng, keys.secret, sg);
    errdefer key.deinit(gpa);
    try keys.galois.put(gpa, g, key);
}

fn genSwitchKey(ctx: *const Context, rng: std.Random, secret: []const u64, new_secret: []const u64) !SwitchKey {
    const gpa = ctx.gpa;
    const n = ctx.n;
    const kr = ctx.nq + 1;
    const kb = try gpa.alloc(u64, ctx.nq * kr * n);
    errdefer gpa.free(kb);
    const ka = try gpa.alloc(u64, ctx.nq * kr * n);
    errdefer gpa.free(ka);
    const small = try gpa.alloc(i8, n);
    defer gpa.free(small);
    for (0..ctx.nq) |i| {
        sampleError(rng, small);
        for (0..kr) |j| {
            const m = ctx.tables[j].m;
            const b = kb[(i * kr + j) * n ..][0..n];
            const a = ka[(i * kr + j) * n ..][0..n];
            sampleUniform(rng, m.q, a);
            smallToNtt(&ctx.tables[j], small, b);
            for (b, a, ctx.row(secret, j)) |*pb, pa, s| pb.* = m.sub(pb.*, m.mul(pa, s));
            if (j == i) {
                const f = ctx.p_mod[i];
                for (b, ctx.row(new_secret, j)) |*pb, s| pb.* = m.add(pb.*, m.mul(f, s));
            }
        }
    }
    return .{ .b = kb, .a = ka };
}

/// The encryption of a plaintext with the public key.
pub fn encrypt(ctx: *const Context, keys: *const Keys, rng: std.Random, pt: Plaintext) !Ciphertext {
    const gpa = ctx.gpa;
    const n = ctx.n;
    const rows = pt.level + 1;
    const c0 = try gpa.alloc(u64, rows * n);
    errdefer gpa.free(c0);
    const c1 = try gpa.alloc(u64, rows * n);
    errdefer gpa.free(c1);
    const small = try gpa.alloc(i8, 3 * n);
    defer gpa.free(small);
    sampleTernary(rng, small[0..n]);
    sampleError(rng, small[n..]);
    const u = try gpa.alloc(u64, n);
    defer gpa.free(u);
    for (0..rows) |j| {
        const t = &ctx.tables[j];
        const m = t.m;
        const r0 = ctx.row(c0, j);
        const r1 = ctx.row(c1, j);
        smallToNtt(t, small[0..n], u);
        smallToNtt(t, small[n .. 2 * n], r0);
        smallToNtt(t, small[2 * n ..], r1);
        for (r0, r1, u, ctx.row(keys.pub_b, j), ctx.row(keys.pub_a, j), ctx.row(pt.m, j)) |*p0, *p1, x, b, a, msg| {
            p0.* = m.add(m.add(p0.*, m.mul(b, x)), msg);
            p1.* = m.add(p1.*, m.mul(a, x));
        }
    }
    return .{ .c0 = c0, .c1 = c1, .level = pt.level, .scale = pt.scale };
}

/// The encryption of real values at the top level.
pub fn encryptValues(ctx: *const Context, keys: *const Keys, rng: std.Random, values: []const f64) !Ciphertext {
    const pt = try ctx.encode(values, ctx.top(), ctx.scales[ctx.top()]);
    defer pt.deinit(ctx);
    return encrypt(ctx, keys, rng, pt);
}

/// The real parts of the slots of a ciphertext. The caller frees the
/// result with the allocator of the context.
pub fn decrypt(ctx: *const Context, keys: *const Keys, ct: Ciphertext) ![]f64 {
    const gpa = ctx.gpa;
    const n = ctx.n;
    const rows = ct.level + 1;
    const m = try gpa.alloc(u64, rows * n);
    defer gpa.free(m);
    for (0..rows) |j| {
        const md = ctx.tables[j].m;
        const r = ctx.row(m, j);
        for (r, ctx.row(ct.c0, j), ctx.row(ct.c1, j), ctx.row(keys.secret, j)) |*o, a, b, s| o.* = md.add(a, md.mul(b, s));
        ctx.tables[j].inverse(r);
    }
    return ctx.decode(m, ct.level, ct.scale);
}

fn sameLevel(a: Ciphertext, b: Ciphertext) !void {
    if (a.level != b.level) return error.LevelMismatch;
}

/// a + b for two ciphertexts of one level.
pub fn addRaw(ctx: *const Context, a: Ciphertext, b: Ciphertext) !Ciphertext {
    try sameLevel(a, b);
    const c0 = try ctx.gpa.alloc(u64, a.c0.len);
    errdefer ctx.gpa.free(c0);
    const out: Ciphertext = .{ .c0 = c0, .c1 = try ctx.gpa.alloc(u64, a.c1.len), .level = a.level, .scale = a.scale };
    for (0..a.level + 1) |j| {
        const m = ctx.tables[j].m;
        ntt.addInto(m, ctx.row(out.c0, j), ctx.row(a.c0, j), ctx.row(b.c0, j));
        ntt.addInto(m, ctx.row(out.c1, j), ctx.row(a.c1, j), ctx.row(b.c1, j));
    }
    return out;
}

/// a = a + b for two ciphertexts of one level, with no new memory.
pub fn addAssign(ctx: *const Context, a: *Ciphertext, b: Ciphertext) !void {
    try sameLevel(a.*, b);
    for (0..a.level + 1) |j| {
        const m = ctx.tables[j].m;
        ntt.addInto(m, ctx.row(a.c0, j), ctx.row(a.c0, j), ctx.row(b.c0, j));
        ntt.addInto(m, ctx.row(a.c1, j), ctx.row(a.c1, j), ctx.row(b.c1, j));
    }
}

pub fn subRaw(ctx: *const Context, a: Ciphertext, b: Ciphertext) !Ciphertext {
    try sameLevel(a, b);
    const c0 = try ctx.gpa.alloc(u64, a.c0.len);
    errdefer ctx.gpa.free(c0);
    const out: Ciphertext = .{ .c0 = c0, .c1 = try ctx.gpa.alloc(u64, a.c1.len), .level = a.level, .scale = a.scale };
    for (0..a.level + 1) |j| {
        const m = ctx.tables[j].m;
        ntt.subInto(m, ctx.row(out.c0, j), ctx.row(a.c0, j), ctx.row(b.c0, j));
        ntt.subInto(m, ctx.row(out.c1, j), ctx.row(a.c1, j), ctx.row(b.c1, j));
    }
    return out;
}

/// The switch of the polynomial `d` (NTT form, level + 1 rows) from the
/// secret of `key` to the secret s. out0 + out1 * s is d times the
/// secret of the key, plus a small error.
fn keySwitch(ctx: *const Context, key: *const SwitchKey, level: usize, d: []const u64, out0: []u64, out1: []u64) !void {
    const gpa = ctx.gpa;
    const n = ctx.n;
    const rows = level + 2;
    const kr = ctx.nq + 1;
    const acc = try gpa.alloc(u128, 2 * rows * n);
    defer gpa.free(acc);
    @memset(acc, 0);
    const acc0 = acc[0 .. rows * n];
    const acc1 = acc[rows * n ..];
    const scratch = try gpa.alloc(u64, 2 * n);
    defer gpa.free(scratch);
    const coef = scratch[0..n];
    const tmp = scratch[n..];
    for (0..level + 1) |i| {
        @memcpy(coef, ctx.row(d, i));
        ctx.tables[i].inverse(coef);
        for (0..rows) |jr| {
            const j = if (jr == level + 1) ctx.nq else jr;
            var src: []const u64 = ctx.row(d, i);
            if (j != i) {
                const mj = ctx.tables[j].m;
                if (ctx.tables[i].m.q > mj.q) {
                    for (tmp, coef) |*t, c| t.* = mj.reduce(c);
                } else @memcpy(tmp, coef);
                ctx.tables[j].forward(tmp);
                src = tmp;
            }
            const kb = key.b[(i * kr + j) * n ..][0..n];
            const ka = key.a[(i * kr + j) * n ..][0..n];
            for (ctx.row(acc0, jr), ctx.row(acc1, jr), src, kb, ka) |*x0, *x1, s, b, a| {
                x0.* += @as(u128, s) * b;
                x1.* += @as(u128, s) * a;
            }
        }
    }
    // The division by P: subtract the residue modulo P, then multiply by
    // P^-1 in each row.
    const tp = &ctx.tables[ctx.nq];
    inline for (.{ acc0, acc1 }, .{ out0, out1 }) |part, out| {
        for (coef, ctx.row(part, level + 1)) |*c, x| c.* = tp.m.reduce128(x);
        tp.inverse(coef);
        for (0..level + 1) |j| {
            const mj = ctx.tables[j].m;
            for (tmp, coef) |*t, c| t.* = mj.reduce(c);
            ctx.tables[j].forward(tmp);
            const pinv = ctx.p_inv[j];
            const pinvp = ctx.p_inv_p[j];
            for (ctx.row(out, j), ctx.row(part, j), tmp) |*o, x, t| {
                o.* = ntt.mulShoup(mj.sub(mj.reduce128(x), t), pinv, pinvp, mj.q);
            }
        }
    }
}

/// a * b with the relinearization and no rescale. The scale of the
/// result is the product of the two scales.
pub fn mulRelin(ctx: *const Context, keys: *const Keys, a: Ciphertext, b: Ciphertext) !Ciphertext {
    try sameLevel(a, b);
    const gpa = ctx.gpa;
    const n = ctx.n;
    const rows = a.level + 1;
    const c0 = try gpa.alloc(u64, rows * n);
    errdefer gpa.free(c0);
    const c1 = try gpa.alloc(u64, rows * n);
    errdefer gpa.free(c1);
    const work = try gpa.alloc(u64, 3 * rows * n);
    defer gpa.free(work);
    const d2 = work[0 .. rows * n];
    const p0 = work[rows * n .. 2 * rows * n];
    const p1 = work[2 * rows * n ..];
    for (0..rows) |j| {
        const m = ctx.tables[j].m;
        for (ctx.row(c0, j), ctx.row(c1, j), ctx.row(d2, j), ctx.row(a.c0, j), ctx.row(a.c1, j), ctx.row(b.c0, j), ctx.row(b.c1, j)) |*o0, *o1, *o2, a0, a1, b0, b1| {
            o0.* = m.mul(a0, b0);
            o1.* = m.reduce128(@as(u128, a0) * b1 + @as(u128, a1) * b0);
            o2.* = m.mul(a1, b1);
        }
    }
    try keySwitch(ctx, &keys.relin, a.level, d2, p0, p1);
    for (0..rows) |j| {
        const m = ctx.tables[j].m;
        ntt.addInto(m, ctx.row(c0, j), ctx.row(c0, j), ctx.row(p0, j));
        ntt.addInto(m, ctx.row(c1, j), ctx.row(c1, j), ctx.row(p1, j));
    }
    return .{ .c0 = c0, .c1 = c1, .level = a.level, .scale = a.scale * b.scale };
}

/// Divides a ciphertext by its last prime and removes the row of that
/// prime. The ciphertext changes in place.
pub fn rescale(ctx: *const Context, ct: *Ciphertext) !void {
    if (ct.level == 0) return error.NoLevel;
    const gpa = ctx.gpa;
    const n = ctx.n;
    const l = ct.level;
    const scratch = try gpa.alloc(u64, 2 * n);
    defer gpa.free(scratch);
    const coef = scratch[0..n];
    const tmp = scratch[n..];
    const ql = ctx.tables[l].m.q;
    inline for (.{ &ct.c0, &ct.c1 }) |pc| {
        const c = pc.*;
        @memcpy(coef, ctx.row(c, l));
        ctx.tables[l].inverse(coef);
        for (0..l) |j| {
            const m = ctx.tables[j].m;
            for (tmp, coef) |*t, x| t.* = m.reduce(x);
            ctx.tables[j].forward(tmp);
            const inv = m.inv(ql % m.q);
            const invp = ntt.shoup(inv, m.q);
            for (ctx.row(c, j), tmp) |*o, t| o.* = ntt.mulShoup(m.sub(o.*, t), inv, invp, m.q);
        }
        pc.* = if (gpa.resize(c, l * n)) c[0 .. l * n] else blk: {
            const smaller = try gpa.dupe(u64, c[0 .. l * n]);
            gpa.free(c);
            break :blk smaller;
        };
    }
    ct.level = l - 1;
    ct.scale /= @floatFromInt(ql);
}

/// The ciphertext with its slots rotated to the left by `steps`. The
/// keys must have the Galois key of the rotation.
pub fn rotate(ctx: *Context, keys: *const Keys, ct: Ciphertext, steps: i64) !Ciphertext {
    const g = ctx.galoisElt(steps);
    if (g == 1) return ct.clone(ctx);
    const key = keys.galois.getPtr(g) orelse return error.NoGaloisKey;
    const p = try ctx.perm(g);
    const gpa = ctx.gpa;
    const n = ctx.n;
    const rows = ct.level + 1;
    const c0 = try gpa.alloc(u64, rows * n);
    errdefer gpa.free(c0);
    const c1 = try gpa.alloc(u64, rows * n);
    errdefer gpa.free(c1);
    const work = try gpa.alloc(u64, 2 * rows * n);
    defer gpa.free(work);
    const r1 = work[0 .. rows * n];
    const p0 = work[rows * n ..];
    for (0..rows) |j| {
        for (ctx.row(c0, j), ctx.row(r1, j), p) |*o0, *o1, src| {
            o0.* = ct.c0[j * n + src];
            o1.* = ct.c1[j * n + src];
        }
    }
    try keySwitch(ctx, key, ct.level, r1, p0, c1);
    for (0..rows) |j| ntt.addInto(ctx.tables[j].m, ctx.row(c0, j), ctx.row(c0, j), ctx.row(p0, j));
    return .{ .c0 = c0, .c1 = c1, .level = ct.level, .scale = ct.scale };
}

/// Multiplies each row by the residues of an integer constant.
fn mulResidues(ctx: *const Context, ct: *Ciphertext, res: []const u64) void {
    for (0..ct.level + 1) |j| {
        const q = ctx.tables[j].m.q;
        const wp = ntt.shoup(res[j], q);
        for (ctx.row(ct.c0, j)) |*o| o.* = ntt.mulShoup(o.*, res[j], wp, q);
        for (ctx.row(ct.c1, j)) |*o| o.* = ntt.mulShoup(o.*, res[j], wp, q);
    }
}

/// A copy of the ciphertext at a lower level, with the scale of that
/// level. The rows of the primes above level + 1 go out with no change
/// of the value. The last step multiplies by the integer nearest to
/// S[level] * q / scale and rescales by q, the prime of level + 1.
pub fn toLevel(ctx: *const Context, ct: Ciphertext, level: usize) !Ciphertext {
    if (level > ct.level) return error.LevelMismatch;
    if (level == ct.level) return ct.clone(ctx);
    const gpa = ctx.gpa;
    const len = (level + 2) * ctx.n;
    const c0 = try gpa.dupe(u64, ct.c0[0..len]);
    errdefer gpa.free(c0);
    const c1 = try gpa.dupe(u64, ct.c1[0..len]);
    var out: Ciphertext = .{ .c0 = c0, .c1 = c1, .level = level + 1, .scale = ct.scale };
    errdefer gpa.free(out.c1);
    const factor = ctx.scales[level] * @as(f64, @floatFromInt(ctx.tables[level + 1].m.q)) / ct.scale;
    var res: [max_primes]u64 = undefined;
    try ctx.constResidues(1.0, factor, level + 1, &res);
    mulResidues(ctx, &out, &res);
    out.scale *= @round(factor);
    try rescale(ctx, &out);
    return out;
}

/// a + b. The ciphertext of the higher level goes down to the lower
/// level first.
pub fn add(ctx: *const Context, a: Ciphertext, b: Ciphertext) !Ciphertext {
    if (a.level == b.level) return addRaw(ctx, a, b);
    const hi, const lo = if (a.level > b.level) .{ a, b } else .{ b, a };
    const down = try toLevel(ctx, hi, lo.level);
    defer down.deinit(ctx);
    return addRaw(ctx, down, lo);
}

/// a * b with the relinearization and the rescale. The result is one
/// level below the lower level of the two.
pub fn mul(ctx: *const Context, keys: *const Keys, a: Ciphertext, b: Ciphertext) !Ciphertext {
    const level = @min(a.level, b.level);
    if (level == 0) return error.NoLevel;
    const x = try toLevel(ctx, a, level);
    defer x.deinit(ctx);
    const y = try toLevel(ctx, b, level);
    defer y.deinit(ctx);
    var out = try mulRelin(ctx, keys, x, y);
    errdefer out.deinit(ctx);
    try rescale(ctx, &out);
    return out;
}

/// The scale of a plaintext factor that gives the scale of the level
/// below after the rescale.
fn factorScale(ctx: *const Context, ct: Ciphertext) f64 {
    return ctx.scales[ct.level - 1] * @as(f64, @floatFromInt(ctx.tables[ct.level].m.q)) / ct.scale;
}

/// The product of each slot with the plain value of that slot, with the
/// rescale.
pub fn mulPlain(ctx: *const Context, a: Ciphertext, values: []const f64) !Ciphertext {
    if (a.level == 0) return error.NoLevel;
    const pt = try ctx.encode(values, a.level, factorScale(ctx, a));
    defer pt.deinit(ctx);
    var out = try a.clone(ctx);
    errdefer out.deinit(ctx);
    for (0..a.level + 1) |j| {
        const m = ctx.tables[j].m;
        ntt.mulInto(m, ctx.row(out.c0, j), ctx.row(out.c0, j), ctx.row(pt.m, j));
        ntt.mulInto(m, ctx.row(out.c1, j), ctx.row(out.c1, j), ctx.row(pt.m, j));
    }
    out.scale *= pt.scale;
    try rescale(ctx, &out);
    return out;
}

/// The product of each slot with one plain value, with the rescale.
pub fn mulScalar(ctx: *const Context, a: Ciphertext, c: f64) !Ciphertext {
    if (a.level == 0) return error.NoLevel;
    const s = factorScale(ctx, a);
    var res: [max_primes]u64 = undefined;
    try ctx.constResidues(c, s, a.level, &res);
    var out = try a.clone(ctx);
    errdefer out.deinit(ctx);
    mulResidues(ctx, &out, &res);
    out.scale *= s;
    try rescale(ctx, &out);
    return out;
}

/// The sum of each slot with the plain value of that slot.
pub fn addPlain(ctx: *const Context, a: Ciphertext, values: []const f64) !Ciphertext {
    const pt = try ctx.encode(values, a.level, a.scale);
    defer pt.deinit(ctx);
    const out = try a.clone(ctx);
    for (0..a.level + 1) |j| ntt.addInto(ctx.tables[j].m, ctx.row(out.c0, j), ctx.row(out.c0, j), ctx.row(pt.m, j));
    return out;
}

/// The sum of each slot with one plain value. A constant polynomial has
/// the same value in each place of its NTT form.
pub fn addScalar(ctx: *const Context, a: Ciphertext, c: f64) !Ciphertext {
    var res: [max_primes]u64 = undefined;
    try ctx.constResidues(c, a.scale, a.level, &res);
    const out = try a.clone(ctx);
    for (0..a.level + 1) |j| {
        const m = ctx.tables[j].m;
        for (ctx.row(out.c0, j)) |*o| o.* = m.add(o.*, res[j]);
    }
    return out;
}

/// The ciphertext in which slot i has the sum of the slots i .. i +
/// count - 1. `count` is a power of two. The keys must have the Galois
/// keys of the rotations 1, 2, 4, .. count / 2.
pub fn sumSlots(ctx: *Context, keys: *const Keys, ct: Ciphertext, count: usize) !Ciphertext {
    if (!std.math.isPowerOfTwo(count) or count > ctx.slots) return error.BadCount;
    var acc = try ct.clone(ctx);
    errdefer acc.deinit(ctx);
    var step: usize = 1;
    while (step < count) : (step <<= 1) {
        const r = try rotate(ctx, keys, acc, @intCast(step));
        defer r.deinit(ctx);
        const next = try addRaw(ctx, acc, r);
        acc.deinit(ctx);
        acc = next;
    }
    return acc;
}

/// The dot product of the first `count` slots of a and b, in slot 0.
pub fn dot(ctx: *Context, keys: *const Keys, a: Ciphertext, b: Ciphertext, count: usize) !Ciphertext {
    const prod = try mul(ctx, keys, a, b);
    defer prod.deinit(ctx);
    return sumSlots(ctx, keys, prod, count);
}

/// The rotations that `sumSlots` needs for a count.
pub fn sumRotations(count: usize, buf: *[16]i64) []const i64 {
    var k: usize = 0;
    var step: usize = 1;
    while (step < count) : (step <<= 1) {
        buf[k] = @intCast(step);
        k += 1;
    }
    return buf[0..k];
}

const testing = std.testing;

/// A small ring for the tests. It has no security.
const test_params: Params = .{ .log_n = 8, .levels = 4 };

fn expectClose(want: []const f64, got: []const f64, tol: f64) !void {
    for (want, got[0..want.len], 0..) |w, g, i| {
        if (!(@abs(w - g) <= tol)) {
            std.debug.print("slot {d}: want {d}, got {d}\n", .{ i, w, g });
            return error.TestExpectedApproxEq;
        }
    }
}

test "the primes of the scale keep each level near 2^40" {
    const ctx = try Context.init(testing.allocator, set_13);
    defer ctx.deinit();
    try testing.expect(set_13.totalBits() <= Params.maxBits(13).?);
    try testing.expect(set_14.totalBits() <= Params.maxBits(14).?);
    try testing.expect(set_15.totalBits() <= Params.maxBits(15).?);
    try testing.expect(set_16.totalBits() <= Params.maxBits(16).?);
    for (ctx.scales) |s| try testing.expect(@abs(s / 0x1p40 - 1) < 1e-4);
    // P is above each prime of Q, and the actual size of QP is below the
    // nominal size.
    var bits: f64 = 0;
    for (ctx.tables) |t| {
        try testing.expect(t.m.q <= ctx.tables[ctx.nq].m.q);
        bits += @log2(@as(f64, @floatFromInt(t.m.q)));
    }
    try testing.expect(bits < 200.001);
}

test "decrypt(encrypt(x)) is x, and add, mul, rotate match the plain result" {
    const ctx = try Context.init(testing.allocator, test_params);
    defer ctx.deinit();
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(11);
    const rng = prng.random();
    var keys = try keygen(ctx, rng, &.{ 1, 2, -1 });
    defer keys.deinit(ctx);

    var x: [128]f64 = undefined;
    var y: [128]f64 = undefined;
    for (&x, &y) |*a, *b| {
        a.* = rng.float(f64) * 4 - 2;
        b.* = rng.float(f64) * 4 - 2;
    }
    const cx = try encryptValues(ctx, &keys, rng, &x);
    defer cx.deinit(ctx);
    const cy = try encryptValues(ctx, &keys, rng, &y);
    defer cy.deinit(ctx);

    const dx = try decrypt(ctx, &keys, cx);
    defer gpa.free(dx);
    try expectClose(&x, dx, 1e-7);

    var want: [128]f64 = undefined;
    {
        const s = try add(ctx, cx, cy);
        defer s.deinit(ctx);
        const d = try decrypt(ctx, &keys, s);
        defer gpa.free(d);
        for (&want, x, y) |*w, a, b| w.* = a + b;
        try expectClose(&want, d, 1e-7);
    }
    {
        // The product before the rescale has the scale 2^80: the decoder
        // reads an integer of more than 64 bits.
        const p = try mulRelin(ctx, &keys, cx, cy);
        defer p.deinit(ctx);
        const d = try decrypt(ctx, &keys, p);
        defer gpa.free(d);
        for (&want, x, y) |*w, a, b| w.* = a * b;
        try expectClose(&want, d, 1e-6);
    }
    {
        const p = try mul(ctx, &keys, cx, cy);
        defer p.deinit(ctx);
        try testing.expectEqual(ctx.top() - 1, p.level);
        const d = try decrypt(ctx, &keys, p);
        defer gpa.free(d);
        try expectClose(&want, d, 1e-6);
        // x * y + x: `add` moves x one level down.
        const s = try add(ctx, p, cx);
        defer s.deinit(ctx);
        const ds = try decrypt(ctx, &keys, s);
        defer gpa.free(ds);
        for (&want, x, y) |*w, a, b| w.* = a * b + a;
        try expectClose(&want, ds, 1e-6);
    }
    for ([_]i64{ 1, 2, -1 }) |steps| {
        const r = try rotate(ctx, &keys, cx, steps);
        defer r.deinit(ctx);
        const d = try decrypt(ctx, &keys, r);
        defer gpa.free(d);
        for (&want, 0..) |*w, i| w.* = x[@intCast(@mod(@as(i64, @intCast(i)) + steps, 128))];
        try expectClose(&want, d, 1e-6);
    }
    try testing.expectError(error.NoGaloisKey, rotate(ctx, &keys, cx, 3));
}

test "a chain of products uses each level" {
    const ctx = try Context.init(testing.allocator, test_params);
    defer ctx.deinit();
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(12);
    const rng = prng.random();
    var keys = try keygen(ctx, rng, &.{});
    defer keys.deinit(ctx);
    var x: [128]f64 = undefined;
    for (&x) |*a| a.* = rng.float(f64) * 2 - 1;
    var acc = try encryptValues(ctx, &keys, rng, &x);
    defer acc.deinit(ctx);
    var want = x;
    // x^2, x^4, x^8, x^16, then the plain factors.
    for (0..4) |_| {
        const next = try mul(ctx, &keys, acc, acc);
        acc.deinit(ctx);
        acc = next;
        for (&want) |*w| w.* *= w.*;
    }
    try testing.expectEqual(@as(usize, 0), acc.level);
    try testing.expectError(error.NoLevel, mul(ctx, &keys, acc, acc));
    const d = try decrypt(ctx, &keys, acc);
    defer gpa.free(d);
    try expectClose(&want, d, 1e-5);
}

test "plain factors, plain terms, and the dot product" {
    const ctx = try Context.init(testing.allocator, test_params);
    defer ctx.deinit();
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(13);
    const rng = prng.random();
    var rot: [16]i64 = undefined;
    var keys = try keygen(ctx, rng, sumRotations(64, &rot));
    defer keys.deinit(ctx);
    var x: [64]f64 = undefined;
    var y: [64]f64 = undefined;
    var sum: f64 = 0;
    for (&x, &y) |*a, *b| {
        a.* = rng.float(f64) * 2 - 1;
        b.* = rng.float(f64) * 2 - 1;
        sum += a.* * b.*;
    }
    const cx = try encryptValues(ctx, &keys, rng, &x);
    defer cx.deinit(ctx);
    const cy = try encryptValues(ctx, &keys, rng, &y);
    defer cy.deinit(ctx);
    {
        const r = try dot(ctx, &keys, cx, cy, 64);
        defer r.deinit(ctx);
        const d = try decrypt(ctx, &keys, r);
        defer gpa.free(d);
        try testing.expectApproxEqAbs(sum, d[0], 1e-5);
    }
    {
        // 0.5 + 0.25 * (x * y_plain) - 3 * x
        const p = try mulPlain(ctx, cx, &y);
        defer p.deinit(ctx);
        const q = try mulScalar(ctx, p, 0.25);
        defer q.deinit(ctx);
        const t = try mulScalar(ctx, cx, -3);
        defer t.deinit(ctx);
        const s = try add(ctx, q, t);
        defer s.deinit(ctx);
        const f = try addScalar(ctx, s, 0.5);
        defer f.deinit(ctx);
        const g = try addPlain(ctx, f, &y);
        defer g.deinit(ctx);
        const d = try decrypt(ctx, &keys, g);
        defer gpa.free(d);
        var want: [64]f64 = undefined;
        for (&want, x, y) |*w, a, b| w.* = 0.5 + 0.25 * a * b - 3 * a + b;
        try expectClose(&want, d, 1e-6);
    }
}

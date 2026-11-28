//! The number-theory core of `ztcl::fhe`: arithmetic modulo a prime
//! below 2^61 and the negacyclic number-theoretic transform (NTT) of
//! Z_q[X]/(X^n + 1).
//!
//! The forward transform is the Cooley-Tukey form and the inverse is the
//! Gentleman-Sande form, each with the powers of the 2n-th root psi in
//! bit-reversed order (Longa and Naehrig). No separate multiplication by
//! the powers of psi and no bit-reversal pass are necessary. The
//! butterflies use the lazy reduction of Harvey: a multiplication by a
//! constant w uses the word w' = floor(w * 2^64 / q) (Shoup), and the
//! values stay below 4q between the layers. A product of two variable
//! values uses the Barrett reduction of a 128-bit word.
//!
//! After `forward`, the place i has the value of the polynomial at
//! psi^(2 * bitrev(i) + 1). `galoisPerm` uses this order.
//!
//! `forwardVec` and `inverseVec` do the same work with vectors of four
//! 64-bit words. AVX2 has no 64-bit high multiplication, so the vector
//! code makes it from four 32-bit multiplications. On the measured AVX2
//! host the vector code is 1.13 to 1.19 times as fast forward and 1.00
//! to 1.05 times as fast for the inverse (docs/dev/fhe.md), so a build for a CPU with
//! AVX2 uses it. The selection is at compile time: a build for the
//! baseline x86-64 CPU uses the scalar code. The vector code compiles
//! for arm64, where no measurement exists, so arm64 uses the scalar
//! code.
//!
//! The sources are in docs/references/fhe.md.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// The largest modulus: 4q must fit in 63 bits for the vector compare.
pub const max_modulus: u64 = (1 << 61) - 1;

/// True when the target has the vector code: 256-bit integer vectors or
/// NEON. The fuzzer and the tests run the scalar and the vector code.
pub const has_vec = (builtin.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .avx2)) or builtin.cpu.arch == .aarch64;

/// True when `forward` and `inverse` use the vector code.
pub const use_vec = builtin.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .avx2);

pub const Modulus = struct {
    q: u64,
    /// floor(2^128 / q).
    r_hi: u64,
    r_lo: u64,

    pub fn init(q: u64) Modulus {
        std.debug.assert(q > 1 and q <= max_modulus);
        const r: u128 = @as(u128, std.math.maxInt(u128)) / q;
        return .{ .q = q, .r_hi = @truncate(r >> 64), .r_lo = @truncate(r) };
    }

    /// x mod q for any 128-bit x (Barrett).
    pub inline fn reduce128(m: Modulus, x: u128) u64 {
        const x0: u64 = @truncate(x);
        const x1: u64 = @truncate(x >> 64);
        const carry: u64 = @truncate((@as(u128, x0) * m.r_lo) >> 64);
        const t2 = @as(u128, x0) * m.r_hi + carry;
        const t3 = @as(u128, x1) * m.r_lo + @as(u64, @truncate(t2));
        const qhat: u64 = x1 *% m.r_hi +% @as(u64, @truncate(t2 >> 64)) +% @as(u64, @truncate(t3 >> 64));
        var r = x0 -% qhat *% m.q;
        if (r >= m.q) r -= m.q;
        if (r >= m.q) r -= m.q;
        return r;
    }

    pub inline fn reduce(m: Modulus, x: u64) u64 {
        // floor(x * floor(2^128 / q) / 2^128) needs only the high word.
        const qhat: u64 = @truncate((@as(u128, x) * m.r_hi) >> 64);
        var r = x -% qhat *% m.q;
        if (r >= m.q) r -= m.q;
        if (r >= m.q) r -= m.q;
        return r;
    }

    pub inline fn mul(m: Modulus, a: u64, b: u64) u64 {
        return m.reduce128(@as(u128, a) * b);
    }

    pub inline fn add(m: Modulus, a: u64, b: u64) u64 {
        return condSub(a + b, m.q);
    }

    pub inline fn sub(m: Modulus, a: u64, b: u64) u64 {
        // a - b wraps to a value above a + q - b when a is below b.
        const d = a -% b;
        return @min(d, d +% m.q);
    }

    pub inline fn neg(m: Modulus, a: u64) u64 {
        return if (a == 0) 0 else m.q - a;
    }

    pub fn pow(m: Modulus, base: u64, exp: u64) u64 {
        var r: u64 = 1;
        var b = base % m.q;
        var e = exp;
        while (e != 0) : (e >>= 1) {
            if (e & 1 != 0) r = m.mul(r, b);
            b = m.mul(b, b);
        }
        return r;
    }

    /// The inverse of a nonzero `a`. q is a prime.
    pub fn inv(m: Modulus, a: u64) u64 {
        return m.pow(a, m.q - 2);
    }

    /// The residue of a signed integer.
    pub inline fn fromSigned(m: Modulus, v: i128) u64 {
        const r: i128 = @rem(v, @as(i128, m.q));
        return @intCast(if (r < 0) r + m.q else r);
    }
};

/// floor(w * 2^64 / q), the second word of a Shoup multiplication by w.
pub inline fn shoup(w: u64, q: u64) u64 {
    return @truncate((@as(u128, w) << 64) / q);
}

/// w * x mod q in [0, 2q), for any 64-bit x.
pub inline fn mulShoupLazy(x: u64, w: u64, wp: u64, q: u64) u64 {
    const qhat: u64 = @truncate((@as(u128, x) * wp) >> 64);
    return w *% x -% qhat *% q;
}

/// x - m when x >= m, else x, with no branch: when x is below m the
/// difference wraps to a value above x.
pub inline fn condSub(x: u64, m: u64) u64 {
    return @min(x, x -% m);
}

/// w * x mod q in [0, q).
pub inline fn mulShoup(x: u64, w: u64, wp: u64, q: u64) u64 {
    return condSub(mulShoupLazy(x, w, wp, q), q);
}

/// The Miller-Rabin test with the first 12 primes as bases. This set of
/// bases gives the exact answer for each 64-bit integer.
pub fn isPrime(n: u64) bool {
    if (n < 2) return false;
    const bases = [_]u64{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 };
    for (bases) |p| {
        if (n == p) return true;
        if (n % p == 0) return false;
    }
    var d = n - 1;
    var s: u32 = 0;
    while (d & 1 == 0) : (d >>= 1) s += 1;
    for (bases) |a| {
        var x = powMod(a, d, n);
        if (x == 1 or x == n - 1) continue;
        var composite = true;
        var r: u32 = 1;
        while (r < s) : (r += 1) {
            x = @intCast(@as(u128, x) * x % n);
            if (x == n - 1) {
                composite = false;
                break;
            }
        }
        if (composite) return false;
    }
    return true;
}

fn powMod(base: u64, exp: u64, n: u64) u64 {
    var r: u64 = 1;
    var b = base % n;
    var e = exp;
    while (e != 0) : (e >>= 1) {
        if (e & 1 != 0) r = @intCast(@as(u128, r) * b % n);
        b = @intCast(@as(u128, b) * b % n);
    }
    return r;
}

/// The prime p with p = 1 (mod 2n) that is nearest to `target` and not
/// in `used`. The search goes up and down from the target in steps of 2n.
pub fn primeNear(target: u64, n: usize, used: []const u64) ?u64 {
    const step: u64 = 2 * @as(u64, n);
    const base = target - target % step + 1;
    var k: u64 = 0;
    while (k < 1 << 22) : (k += 1) {
        const up = base + k * step;
        // A candidate below 1 wraps to a large value, and the range
        // check leaves it out.
        const down = base -% (k + 1) * step;
        const du = if (up > target) up - target else target - up;
        const dd = if (down > target) down - target else target - down;
        const first, const second = if (du <= dd) .{ up, down } else .{ down, up };
        inline for (.{ first, second }) |c| {
            if (c > step and c <= max_modulus and std.mem.indexOfScalar(u64, used, c) == null and isPrime(c)) return c;
        }
    }
    return null;
}

/// The largest prime p below `limit` with p = 1 (mod 2n) that is not in
/// `used`.
pub fn primeBelow(limit: u64, n: usize, used: []const u64) ?u64 {
    const step: u64 = 2 * @as(u64, n);
    var c = (limit - 1) - (limit - 1) % step + 1;
    if (c >= limit) c -= step;
    while (c > step) : (c -= step) {
        if (std.mem.indexOfScalar(u64, used, c) == null and isPrime(c)) return c;
    }
    return null;
}

pub fn bitrev(x: usize, bits: u6) usize {
    if (bits == 0) return 0;
    return @bitReverse(x) >> @intCast(@bitSizeOf(usize) - @as(u32, bits));
}

/// The tables of one prime and one size.
pub const Table = struct {
    m: Modulus,
    n: usize,
    log_n: u6,
    /// psi^bitrev(k), and its Shoup word.
    w: []u64,
    wp: []u64,
    /// psi^-bitrev(k), and its Shoup word.
    iw: []u64,
    iwp: []u64,
    n_inv: u64,
    n_inv_p: u64,
    /// n^-1 * iw[1], for the last layer of the inverse.
    last_w: u64,
    last_wp: u64,
    psi: u64,

    pub fn init(gpa: Allocator, q: u64, n: usize) !Table {
        std.debug.assert(std.math.isPowerOfTwo(n) and n >= 4);
        if ((q - 1) % (2 * n) != 0) return error.NotNttPrime;
        const m = Modulus.init(q);
        const log_n: u6 = @intCast(std.math.log2_int(usize, n));
        const psi = findPsi(m, n) orelse return error.NotNttPrime;
        const psi_inv = m.inv(psi);
        const w = try gpa.alloc(u64, n * 4);
        var t: Table = .{
            .m = m,
            .n = n,
            .log_n = log_n,
            .w = w[0..n],
            .wp = w[n .. 2 * n],
            .iw = w[2 * n .. 3 * n],
            .iwp = w[3 * n ..],
            .n_inv = m.inv(@intCast(n)),
            .n_inv_p = 0,
            .last_w = 0,
            .last_wp = 0,
            .psi = psi,
        };
        var p: u64 = 1;
        var ip: u64 = 1;
        for (0..n) |k| {
            const r = bitrev(k, log_n);
            t.w[r] = p;
            t.iw[r] = ip;
            p = m.mul(p, psi);
            ip = m.mul(ip, psi_inv);
        }
        for (0..n) |k| {
            t.wp[k] = shoup(t.w[k], q);
            t.iwp[k] = shoup(t.iw[k], q);
        }
        t.n_inv_p = shoup(t.n_inv, q);
        t.last_w = m.mul(t.n_inv, t.iw[1]);
        t.last_wp = shoup(t.last_w, q);
        return t;
    }

    pub fn deinit(t: *Table, gpa: Allocator) void {
        gpa.free(t.w.ptr[0 .. t.n * 4]);
    }

    pub fn forward(t: *const Table, a: []u64) void {
        if (use_vec) t.forwardVec(a) else t.forwardScalar(a);
    }

    pub fn inverse(t: *const Table, a: []u64) void {
        if (use_vec) t.inverseVec(a) else t.inverseScalar(a);
    }

    /// The transform in place. The input is in [0, q) and so is the
    /// output.
    pub fn forwardScalar(t: *const Table, a: []u64) void {
        std.debug.assert(a.len == t.n);
        const q = t.m.q;
        const two_q = 2 * q;
        var len = t.n;
        var m: usize = 1;
        while (m < t.n) : (m <<= 1) {
            len >>= 1;
            for (0..m) |i| {
                const w = t.w[m + i];
                const wp = t.wp[m + i];
                const x = a[2 * i * len ..][0..len];
                const y = a[2 * i * len + len ..][0..len];
                for (x, y) |*px, *py| {
                    const u = condSub(px.*, two_q);
                    const v = mulShoupLazy(py.*, w, wp, q);
                    px.* = u + v;
                    py.* = u + two_q - v;
                }
            }
        }
        for (a) |*p| p.* = condSub(condSub(p.*, two_q), q);
    }

    /// The inverse transform in place, with the division by n. The input
    /// is in [0, q) and so is the output.
    pub fn inverseScalar(t: *const Table, a: []u64) void {
        std.debug.assert(a.len == t.n);
        const q = t.m.q;
        const two_q = 2 * q;
        var len: usize = 1;
        var m = t.n;
        while (m > 2) : (m >>= 1) {
            const h = m >> 1;
            for (0..h) |i| {
                const w = t.iw[h + i];
                const wp = t.iwp[h + i];
                const x = a[2 * i * len ..][0..len];
                const y = a[2 * i * len + len ..][0..len];
                for (x, y) |*px, *py| {
                    const u = px.*;
                    const v = py.*;
                    px.* = condSub(u + v, two_q);
                    py.* = mulShoupLazy(u + two_q - v, w, wp, q);
                }
            }
            len <<= 1;
        }
        // The last layer has n^-1 in its two constants.
        const x = a[0..len];
        const y = a[len..][0..len];
        for (x, y) |*px, *py| {
            const u = px.*;
            const v = py.*;
            px.* = mulShoup(u + v, t.n_inv, t.n_inv_p, q);
            py.* = mulShoup(u + two_q - v, t.last_w, t.last_wp, q);
        }
    }

    const V = @Vector(4, u64);
    const Vi = @Vector(4, i64);
    const lo_mask: V = @splat(0xffff_ffff);
    const sh32: @Vector(4, u6) = @splat(32);

    /// The high 64 bits of each 64-bit product, from four 32-bit
    /// multiplications.
    inline fn mulHiVec(x: V, y: V) V {
        const xl = x & lo_mask;
        const xh = x >> sh32;
        const yl = y & lo_mask;
        const yh = y >> sh32;
        const ll = xl * yl;
        const lh = xl * yh;
        const hl = xh * yl;
        const hh = xh * yh;
        const mid = (ll >> sh32) + (lh & lo_mask) + (hl & lo_mask);
        return hh + (lh >> sh32) + (hl >> sh32) + (mid >> sh32);
    }

    /// x - m in each place where x >= m. The values are below 2^63.
    inline fn condSubVec(x: V, mv: V) V {
        const ge = @as(Vi, @bitCast(x)) >= @as(Vi, @bitCast(mv));
        return @select(u64, ge, x -% mv, x);
    }

    inline fn mulShoupLazyVec(x: V, w: V, wp: V, q: V) V {
        return w *% x -% mulHiVec(x, wp) *% q;
    }

    pub fn forwardVec(t: *const Table, a: []u64) void {
        std.debug.assert(a.len == t.n);
        if (t.n < 8) return t.forwardScalar(a);
        const q = t.m.q;
        const two_q = 2 * q;
        const qv: V = @splat(q);
        const two_qv: V = @splat(two_q);
        var len = t.n;
        var m: usize = 1;
        while (m < t.n) : (m <<= 1) {
            len >>= 1;
            for (0..m) |i| {
                const w = t.w[m + i];
                const wp = t.wp[m + i];
                const x = a[2 * i * len ..][0..len];
                const y = a[2 * i * len + len ..][0..len];
                if (len >= 4) {
                    const wv: V = @splat(w);
                    const wpv: V = @splat(wp);
                    var j: usize = 0;
                    while (j < len) : (j += 4) {
                        const u = condSubVec(x[j..][0..4].*, two_qv);
                        const v = mulShoupLazyVec(y[j..][0..4].*, wv, wpv, qv);
                        x[j..][0..4].* = u + v;
                        y[j..][0..4].* = u + two_qv - v;
                    }
                } else for (x, y) |*px, *py| {
                    const u = condSub(px.*, two_q);
                    const v = mulShoupLazy(py.*, w, wp, q);
                    px.* = u + v;
                    py.* = u + two_q - v;
                }
            }
        }
        var j: usize = 0;
        while (j < t.n) : (j += 4) {
            a[j..][0..4].* = condSubVec(condSubVec(a[j..][0..4].*, two_qv), qv);
        }
    }

    pub fn inverseVec(t: *const Table, a: []u64) void {
        std.debug.assert(a.len == t.n);
        if (t.n < 8) return t.inverseScalar(a);
        const q = t.m.q;
        const two_q = 2 * q;
        const qv: V = @splat(q);
        const two_qv: V = @splat(two_q);
        var len: usize = 1;
        var m = t.n;
        while (m > 2) : (m >>= 1) {
            const h = m >> 1;
            for (0..h) |i| {
                const w = t.iw[h + i];
                const wp = t.iwp[h + i];
                const x = a[2 * i * len ..][0..len];
                const y = a[2 * i * len + len ..][0..len];
                if (len >= 4) {
                    const wv: V = @splat(w);
                    const wpv: V = @splat(wp);
                    var j: usize = 0;
                    while (j < len) : (j += 4) {
                        const u: V = x[j..][0..4].*;
                        const v: V = y[j..][0..4].*;
                        x[j..][0..4].* = condSubVec(u + v, two_qv);
                        y[j..][0..4].* = mulShoupLazyVec(u + two_qv - v, wv, wpv, qv);
                    }
                } else for (x, y) |*px, *py| {
                    const u = px.*;
                    const v = py.*;
                    px.* = condSub(u + v, two_q);
                    py.* = mulShoupLazy(u + two_q - v, w, wp, q);
                }
            }
            len <<= 1;
        }
        const nv: V = @splat(t.n_inv);
        const npv: V = @splat(t.n_inv_p);
        const lv: V = @splat(t.last_w);
        const lpv: V = @splat(t.last_wp);
        var j: usize = 0;
        while (j < len) : (j += 4) {
            const u: V = a[j..][0..4].*;
            const v: V = a[len + j ..][0..4].*;
            a[j..][0..4].* = condSubVec(mulShoupLazyVec(u + v, nv, npv, qv), qv);
            a[len + j ..][0..4].* = condSubVec(mulShoupLazyVec(u + two_qv - v, lv, lpv, qv), qv);
        }
    }
};

/// A primitive 2n-th root of unity modulo q: x^((q-1)/2n) for the first
/// x that gives an element of order 2n.
fn findPsi(m: Modulus, n: usize) ?u64 {
    const e = (m.q - 1) / (2 * @as(u64, n));
    var x: u64 = 2;
    while (x < 1000) : (x += 1) {
        const psi = m.pow(x, e);
        if (m.pow(psi, @intCast(n)) == m.q - 1) return psi;
    }
    return null;
}

/// out[i] = a[i] * b[i] mod q.
pub fn mulInto(m: Modulus, out: []u64, a: []const u64, b: []const u64) void {
    for (out, a, b) |*o, x, y| o.* = m.mul(x, y);
}

pub fn addInto(m: Modulus, out: []u64, a: []const u64, b: []const u64) void {
    for (out, a, b) |*o, x, y| o.* = m.add(x, y);
}

pub fn subInto(m: Modulus, out: []u64, a: []const u64, b: []const u64) void {
    for (out, a, b) |*o, x, y| o.* = m.sub(x, y);
}

/// The table of the automorphism X -> X^g on a polynomial in NTT form:
/// out[i] = in[perm[i]]. g is odd.
pub fn galoisPerm(perm: []u32, log_n: u6, g: u64) void {
    const n = perm.len;
    const mask: u64 = 2 * @as(u64, n) - 1;
    for (perm, 0..) |*p, i| {
        const e = (2 * @as(u64, bitrev(i, log_n)) + 1) * g & mask;
        p.* = @intCast(bitrev(@intCast((e - 1) / 2), log_n));
    }
}

/// The product of two polynomials modulo X^n + 1 and q, by the schoolbook
/// method. The tests and the fuzzer compare the transform with it.
pub fn mulSchoolbook(m: Modulus, out: []u64, a: []const u64, b: []const u64) void {
    const n = a.len;
    @memset(out, 0);
    for (0..n) |i| for (0..n) |j| {
        const p = m.mul(a[i], b[j]);
        const k = i + j;
        if (k < n) out[k] = m.add(out[k], p) else out[k - n] = m.sub(out[k - n], p);
    };
}

const testing = std.testing;

test "Barrett reduction against the 128-bit remainder" {
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    const qs = [_]u64{ 3, 12289, (1 << 40) + 1 - (1 << 14), 1152921504606584833, max_modulus };
    for (qs) |q| {
        const m = Modulus.init(q);
        for (0..2000) |_| {
            const x = r.int(u128);
            try testing.expectEqual(@as(u64, @intCast(x % q)), m.reduce128(x));
            const y = r.int(u64);
            try testing.expectEqual(y % q, m.reduce(y));
        }
        try testing.expectEqual(@as(u64, @intCast(@as(u128, std.math.maxInt(u128)) % q)), m.reduce128(std.math.maxInt(u128)));
    }
}

test "the transform has the documented order, and the inverse returns the input" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(2);
    const r = prng.random();
    for ([_]usize{ 4, 8, 64, 1024 }) |n| {
        const q = primeBelow(1 << 60, n, &.{}).?;
        var t = try Table.init(gpa, q, n);
        defer t.deinit(gpa);
        const a = try gpa.alloc(u64, n * 3);
        defer gpa.free(a);
        for (a[0..n]) |*x| x.* = r.uintLessThan(u64, q);
        @memcpy(a[n .. 2 * n], a[0..n]);
        @memcpy(a[2 * n ..], a[0..n]);
        t.forwardScalar(a[n .. 2 * n]);
        t.forwardVec(a[2 * n ..]);
        try testing.expectEqualSlices(u64, a[n .. 2 * n], a[2 * n ..]);
        // The place i has the value at psi^(2 * bitrev(i) + 1).
        for ([_]usize{ 0, 1, n - 1 }) |i| {
            const x = t.m.pow(t.psi, 2 * bitrev(i, t.log_n) + 1);
            var acc: u64 = 0;
            var k = n;
            while (k > 0) : (k -= 1) acc = t.m.add(t.m.mul(acc, x), a[k - 1]);
            try testing.expectEqual(acc, a[n + i]);
        }
        t.inverseScalar(a[n .. 2 * n]);
        t.inverseVec(a[2 * n ..]);
        try testing.expectEqualSlices(u64, a[0..n], a[n .. 2 * n]);
        try testing.expectEqualSlices(u64, a[0..n], a[2 * n ..]);
    }
}

test "the product in NTT form is the negacyclic product" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    const n = 64;
    const q = primeNear(1 << 40, n, &.{}).?;
    var t = try Table.init(gpa, q, n);
    defer t.deinit(gpa);
    var a: [n]u64 = undefined;
    var b: [n]u64 = undefined;
    var want: [n]u64 = undefined;
    for (&a, &b) |*x, *y| {
        x.* = r.uintLessThan(u64, q);
        y.* = r.uintLessThan(u64, q);
    }
    mulSchoolbook(t.m, &want, &a, &b);
    t.forward(&a);
    t.forward(&b);
    mulInto(t.m, &a, &a, &b);
    t.inverse(&a);
    try testing.expectEqualSlices(u64, &want, &a);
}

test "the automorphism in NTT form is the automorphism of the coefficients" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(4);
    const r = prng.random();
    const n = 32;
    const q = primeNear(1 << 40, n, &.{}).?;
    var t = try Table.init(gpa, q, n);
    defer t.deinit(gpa);
    var a: [n]u64 = undefined;
    for (&a) |*x| x.* = r.uintLessThan(u64, q);
    for ([_]u64{ 5, 25, 2 * n - 1 }) |g| {
        // a(X^g) from the coefficients.
        var want: [n]u64 = @splat(0);
        for (a, 0..) |c, i| {
            const e = i * g % (2 * n);
            if (e < n) want[e] = t.m.add(want[e], c) else want[e - n] = t.m.sub(want[e - n], c);
        }
        var f = a;
        t.forward(&f);
        var perm: [n]u32 = undefined;
        galoisPerm(&perm, t.log_n, g);
        var out: [n]u64 = undefined;
        for (&out, perm) |*o, p| o.* = f[p];
        t.inverse(&out);
        try testing.expectEqualSlices(u64, &want, &out);
    }
}

//! ChaCha20-Poly1305 (RFC 8439) for x86-64 CPUs with AVX2, in the
//! module `crypto_x86_avx2` (see `x86_avx2.zig`).
//!
//! ChaCha20 runs 8 blocks at a time: each of the 16 words of the state
//! is a vector of 8 lanes, one lane for each block. After the rounds, a
//! transpose of the two 8 by 8 halves gives the key stream of each
//! block. A rotation by 16 or 8 bits is a byte shuffle.
//!
//! Poly1305 of whole steps of 512 bytes runs 4 blocks at a time in AVX2,
//! with five limbs of 26 bits and 32 by 32 bit products (VPMULUDQ), and
//! the powers r^1 to r^4 (Goll and Gueron, "Vectorization of
//! Poly1305 Message Authentication Code"). The rest is scalar, with two
//! 64-bit limbs and a third small limb. The loop of `seal` and `open`
//! encrypts 512 bytes and hashes 512 bytes of ciphertext in the same
//! step.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

const V8 = @Vector(8, u32);

inline fn rotl(x: V8, comptime n: u5) V8 {
    return (x << @splat(n)) | (x >> @splat(@as(u5, @intCast(32 - @as(u6, n)))));
}

inline fn quarter(x: *[16]V8, comptime a: usize, comptime b: usize, comptime c: usize, comptime d: usize) void {
    x[a] +%= x[b];
    x[d] = rotl(x[d] ^ x[a], 16);
    x[c] +%= x[d];
    x[b] = rotl(x[b] ^ x[c], 12);
    x[a] +%= x[b];
    x[d] = rotl(x[d] ^ x[a], 8);
    x[c] +%= x[d];
    x[b] = rotl(x[b] ^ x[c], 7);
}

/// The 8 by 8 transpose of 32-bit words: out[j][i] = in[i][j].
inline fn transpose(v: [8]V8) [8]V8 {
    // Stage 1: pairs of words.
    var a: [8]V8 = undefined;
    inline for (0..4) |k| {
        a[2 * k] = @shuffle(u32, v[2 * k], v[2 * k + 1], [8]i32{ 0, -1, 1, -2, 4, -5, 5, -6 });
        a[2 * k + 1] = @shuffle(u32, v[2 * k], v[2 * k + 1], [8]i32{ 2, -3, 3, -4, 6, -7, 7, -8 });
    }
    // Stage 2: pairs of 64-bit units.
    var b: [8]V8 = undefined;
    inline for (0..2) |k| {
        inline for (0..2) |h| {
            const p = a[4 * k + h];
            const q = a[4 * k + 2 + h];
            b[4 * k + h] = @shuffle(u32, p, q, [8]i32{ 0, 1, -1, -2, 4, 5, -5, -6 });
            b[4 * k + 2 + h] = @shuffle(u32, p, q, [8]i32{ 2, 3, -3, -4, 6, 7, -7, -8 });
        }
    }
    // Stage 3: halves of 128 bits.
    var o: [8]V8 = undefined;
    inline for (0..4) |k| {
        o[k] = @shuffle(u32, b[k], b[k + 4], [8]i32{ 0, 1, 2, 3, -1, -2, -3, -4 });
        o[k + 4] = @shuffle(u32, b[k], b[k + 4], [8]i32{ 4, 5, 6, 7, -5, -6, -7, -8 });
    }
    // The order of the rows after the stages: stage 1 puts lanes 0, 1,
    // 4, 5 in a[2k] and 2, 3, 6, 7 in a[2k+1]; the rest follows.
    return .{ o[0], o[2], o[1], o[3], o[4], o[6], o[5], o[7] };
}

/// The state of ChaCha20 for a key and nonce: the 16 words, with the
/// block count in word 12.
const State = [16]u32;

fn initState(key: *const [32]u8, nonce: *const [12]u8, count: u32) State {
    var s: State = undefined;
    s[0] = 0x61707865;
    s[1] = 0x3320646e;
    s[2] = 0x79622d32;
    s[3] = 0x6b206574;
    for (0..8) |i| s[4 + i] = std.mem.readInt(u32, key[4 * i ..][0..4], .little);
    s[12] = count;
    for (0..3) |i| s[13 + i] = std.mem.readInt(u32, nonce[4 * i ..][0..4], .little);
    return s;
}

/// Writes the key stream of 8 blocks, 512 bytes, from block `s[12]`.
inline fn blocks8(s: *const State, out: *[512]u8) void {
    @setEvalBranchQuota(100_000);
    var x: [16]V8 = undefined;
    inline for (0..16) |i| x[i] = @splat(s[i]);
    const lanes = V8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    x[12] +%= lanes;
    inline for (0..10) |_| {
        quarter(&x, 0, 4, 8, 12);
        quarter(&x, 1, 5, 9, 13);
        quarter(&x, 2, 6, 10, 14);
        quarter(&x, 3, 7, 11, 15);
        quarter(&x, 0, 5, 10, 15);
        quarter(&x, 1, 6, 11, 12);
        quarter(&x, 2, 7, 8, 13);
        quarter(&x, 3, 4, 9, 14);
    }
    // The input words again from `s`: a broadcast from memory, so the
    // rounds have each of the 16 vector registers.
    inline for (0..16) |i| x[i] +%= @as(V8, @splat(s[i]));
    x[12] +%= lanes;
    const lo = transpose(x[0..8].*);
    const hi = transpose(x[8..16].*);
    inline for (0..8) |j| {
        out[64 * j ..][0..32].* = @bitCast(lo[j]);
        out[64 * j + 32 ..][0..32].* = @bitCast(hi[j]);
    }
}

const R = @Vector(4, u32);

inline fn rotl4(x: R, comptime n: u5) R {
    return (x << @splat(n)) | (x >> @splat(@as(u5, @intCast(32 - @as(u6, n)))));
}

inline fn round4(a: *R, b: *R, c: *R, d: *R) void {
    a.* +%= b.*;
    d.* = rotl4(d.* ^ a.*, 16);
    c.* +%= d.*;
    b.* = rotl4(b.* ^ c.*, 12);
    a.* +%= b.*;
    d.* = rotl4(d.* ^ a.*, 8);
    c.* +%= d.*;
    b.* = rotl4(b.* ^ c.*, 7);
}

/// One block of key stream for block `count`, with the four rows of the
/// state in four vectors of 4 lanes: a quarter of the work of `blocks8`.
/// The diagonal rounds turn rows b, c, and d by one, two, and three
/// lanes, and turn them back after.
fn block1(s: *const State, count: u32) [64]u8 {
    const a0: R = s[0..4].*;
    const b0: R = s[4..8].*;
    const c0: R = s[8..12].*;
    const d0: R = .{ count, s[13], s[14], s[15] };
    var a = a0;
    var b = b0;
    var c = c0;
    var d = d0;
    inline for (0..10) |_| {
        round4(&a, &b, &c, &d);
        b = @shuffle(u32, b, undefined, [4]i32{ 1, 2, 3, 0 });
        c = @shuffle(u32, c, undefined, [4]i32{ 2, 3, 0, 1 });
        d = @shuffle(u32, d, undefined, [4]i32{ 3, 0, 1, 2 });
        round4(&a, &b, &c, &d);
        b = @shuffle(u32, b, undefined, [4]i32{ 3, 0, 1, 2 });
        c = @shuffle(u32, c, undefined, [4]i32{ 2, 3, 0, 1 });
        d = @shuffle(u32, d, undefined, [4]i32{ 1, 2, 3, 0 });
    }
    var out: [64]u8 = undefined;
    out[0..16].* = @bitCast(a +% a0);
    out[16..32].* = @bitCast(b +% b0);
    out[32..48].* = @bitCast(c +% c0);
    out[48..64].* = @bitCast(d +% d0);
    return out;
}

/// XORs the key stream of 8 blocks into 512 bytes.
inline fn xor8(s: *const State, dst: *[512]u8, src: *const [512]u8) void {
    var ks: [512]u8 align(32) = undefined;
    blocks8(s, &ks);
    const B = @Vector(32, u8);
    inline for (0..16) |i| {
        const a: B = src[32 * i ..][0..32].*;
        const k: B = ks[32 * i ..][0..32].*;
        dst[32 * i ..][0..32].* = a ^ k;
    }
}

/// Poly1305 with limbs of 64 bits.
const Poly = struct {
    r0: u64,
    r1: u64,
    s1: u64,
    h0: u64 = 0,
    h1: u64 = 0,
    h2: u64 = 0,
    pad: [2]u64,

    fn init(key: *const [32]u8) Poly {
        const r0 = std.mem.readInt(u64, key[0..8], .little) & 0x0ffffffc0fffffff;
        const r1 = std.mem.readInt(u64, key[8..16], .little) & 0x0ffffffc0ffffffc;
        return .{
            .r0 = r0,
            .r1 = r1,
            // r1 has its 2 low bits clear, so r1 * 2^128 = 5 * (r1 / 4)
            // modulo 2^130 - 5.
            .s1 = r1 + (r1 >> 2),
            .pad = .{ std.mem.readInt(u64, key[16..24], .little), std.mem.readInt(u64, key[24..32], .little) },
        };
    }

    /// Adds the 16-byte block with the bit 2^128 set and multiplies by r.
    inline fn block(p: *Poly, m: *const [16]u8, comptime hibit: u64) void {
        const t0 = std.mem.readInt(u64, m[0..8], .little);
        const t1 = std.mem.readInt(u64, m[8..16], .little);
        const a0 = @addWithOverflow(p.h0, t0);
        const a1 = @addWithOverflow(p.h1, t1);
        const a1c = @addWithOverflow(a1[0], a0[1]);
        const h0 = a0[0];
        const h1 = a1c[0];
        const h2 = p.h2 + a1[1] + a1c[1] + hibit;
        const d0 = @as(u128, h0) * p.r0 + @as(u128, h1) * p.s1;
        const d1 = @as(u128, h0) * p.r1 + @as(u128, h1) * p.r0 + @as(u128, h2) * p.s1 + (d0 >> 64);
        const d2 = h2 * p.r0 + @as(u64, @truncate(d1 >> 64));
        // Fold the bits from 2^130 up back in with a multiply by 5.
        const c = (d2 >> 2) + (d2 & ~@as(u64, 3));
        const n0 = @addWithOverflow(@as(u64, @truncate(d0)), c);
        const n1 = @addWithOverflow(@as(u64, @truncate(d1)), n0[1]);
        p.h0 = n0[0];
        p.h1 = n1[0];
        p.h2 = (d2 & 3) + n1[1];
    }

    fn blocks(p: *Poly, data: []const u8) void {
        var i: usize = 0;
        while (i + 16 <= data.len) : (i += 16) p.block(data[i..][0..16], 1);
    }

    /// The data, then zero bytes to a multiple of 16.
    fn padded(p: *Poly, data: []const u8) void {
        const whole = data.len & ~@as(usize, 15);
        p.blocks(data[0..whole]);
        if (whole < data.len) {
            var b: [16]u8 = @splat(0);
            @memcpy(b[0 .. data.len - whole], data[whole..]);
            p.block(&b, 1);
        }
    }

    fn final(p: *Poly, ad_len: usize, len: usize) [16]u8 {
        var b: [16]u8 = undefined;
        std.mem.writeInt(u64, b[0..8], ad_len, .little);
        std.mem.writeInt(u64, b[8..16], len, .little);
        p.block(&b, 1);
        // h mod 2^130 - 5: h + 5 when it reaches 2^130, with a mask.
        const g0 = @addWithOverflow(p.h0, 5);
        const g1 = @addWithOverflow(p.h1, g0[1]);
        const g2 = p.h2 + g1[1];
        const mask = 0 -% (g2 >> 2);
        const h0 = (g0[0] & mask) | (p.h0 & ~mask);
        const h1 = (g1[0] & mask) | (p.h1 & ~mask);
        const t0 = @addWithOverflow(h0, p.pad[0]);
        const t1 = h1 +% p.pad[1] +% t0[1];
        var out: [16]u8 = undefined;
        std.mem.writeInt(u64, out[0..8], t0[0], .little);
        std.mem.writeInt(u64, out[8..16], t1, .little);
        return out;
    }
};

const V4 = @Vector(4, u64);
const L = [5]V4;
const m26: u64 = 0x3ffffff;

/// A field element in five limbs of 26 bits.
fn to26(h0: u64, h1: u64, h2: u64) [5]u64 {
    return .{ h0 & m26, (h0 >> 26) & m26, ((h0 >> 52) | (h1 << 12)) & m26, (h1 >> 14) & m26, (h1 >> 40) | (h2 << 24) };
}

/// The product of two elements in limbs of 26 bits, modulo 2^130 - 5,
/// with each limb below 2^26 plus a small carry.
fn mul26(a: [5]u64, b: [5]u64) [5]u64 {
    var av: L = undefined;
    var bv: L = undefined;
    for (0..5) |i| {
        av[i] = @splat(a[i]);
        bv[i] = @splat(b[i]);
    }
    const r = mulv(av, bv, five(bv));
    var out: [5]u64 = undefined;
    for (0..5) |i| out[i] = r[i][0];
    return out;
}

inline fn five(r: L) L {
    var s: L = undefined;
    inline for (0..5) |i| s[i] = r[i] * @as(V4, @splat(5));
    return s;
}

/// Lane by lane: h * r modulo 2^130 - 5, with a carry pass. `s` is 5 * r.
/// Each input limb is below 2^27 and each limb of r below 2^26, so each
/// sum of five products is below 2^58.
inline fn mulv(h: L, r: L, s: L) L {
    const lo: V4 = @splat(0xffffffff);
    var d: L = undefined;
    // d[k] = sum over i + j = k of h[i] r[j], with 5 r[j] for the wrap.
    inline for (0..5) |k| {
        var acc: V4 = @splat(0);
        inline for (0..5) |i| {
            const j = (k + 5 - i) % 5;
            const t = (h[i] & lo) * ((if (j > k) s[j] else r[j]) & lo);
            acc +%= t;
        }
        d[k] = acc;
    }
    return carry(d);
}

/// A carry pass in two chains at a time: 0 to 1 and 3 to 4, then 1 to 2
/// and 4 to 0, then 2 to 3 and 0 to 1, then 3 to 4. Each limb ends below
/// 2^26 plus a small carry.
inline fn carry(d0: L) L {
    var d = d0;
    const m: V4 = @splat(m26);
    const sh: @Vector(4, u6) = @splat(26);
    var a = d[0] >> sh;
    var b = d[3] >> sh;
    d[0] &= m;
    d[3] &= m;
    d[1] +%= a;
    d[4] +%= b;
    a = d[1] >> sh;
    b = d[4] >> sh;
    d[1] &= m;
    d[4] &= m;
    d[2] +%= a;
    d[0] +%= b + (b << @splat(2));
    a = d[2] >> sh;
    b = d[0] >> sh;
    d[2] &= m;
    d[0] &= m;
    d[3] +%= a;
    d[1] +%= b;
    a = d[3] >> sh;
    d[3] &= m;
    d[4] +%= a;
    return d;
}

/// Poly1305 over 4 blocks at a time: lane j of `h` has the blocks j,
/// j + 4, j + 8, and so on. Each step is h = h * r^4 + m. The end
/// multiplies the lanes by r^4, r^3, r^2, and r, and adds them.
const PolyV = struct {
    h: L,
    r4: L,
    s4: L,
    rl: L,
    sl: L,
    /// The scalar state, for the first 4 blocks.
    start: [5]u64,
    first: bool = true,

    fn init(p: *const Poly) PolyV {
        const r = to26(p.r0, p.r1, 0);
        const r2 = mul26(r, r);
        const r3 = mul26(r2, r);
        const r4 = mul26(r2, r2);
        var v: PolyV = .{ .h = undefined, .r4 = undefined, .s4 = undefined, .rl = undefined, .sl = undefined, .start = to26(p.h0, p.h1, p.h2) };
        for (0..5) |i| {
            v.r4[i] = @splat(r4[i]);
            v.rl[i] = .{ r4[i], r3[i], r2[i], r[i] };
        }
        v.s4 = five(v.r4);
        v.sl = five(v.rl);
        return v;
    }

    /// The limbs of 4 blocks of 16 bytes, with the bit 2^128 set.
    inline fn load(b: *const [64]u8) L {
        const a: V4 = @bitCast(@as(@Vector(32, u8), b[0..32].*));
        const c: V4 = @bitCast(@as(@Vector(32, u8), b[32..64].*));
        const lo = @shuffle(u64, a, c, [4]i32{ 0, 2, -1, -3 });
        const hi = @shuffle(u64, a, c, [4]i32{ 1, 3, -2, -4 });
        const m: V4 = @splat(m26);
        const S = @Vector(4, u6);
        return .{
            lo & m,
            (lo >> @as(S, @splat(26))) & m,
            ((lo >> @as(S, @splat(52))) | (hi << @as(S, @splat(12)))) & m,
            (hi >> @as(S, @splat(14))) & m,
            (hi >> @as(S, @splat(40))) | @as(V4, @splat(1 << 24)),
        };
    }

    inline fn absorb(v: *PolyV, b: *const [64]u8) void {
        const m = load(b);
        const t = mulv(v.h, v.r4, v.s4);
        inline for (0..5) |i| v.h[i] = t[i] +% m[i];
    }

    fn absorb512(v: *PolyV, b: *const [512]u8) void {
        if (v.first) {
            // The first 4 blocks, with the scalar state added to block 0.
            v.first = false;
            v.h = load(b[0..64]);
            inline for (0..5) |i| v.h[i][0] +%= v.start[i];
            inline for (1..8) |k| v.absorb(b[64 * k ..][0..64]);
            return;
        }
        inline for (0..8) |k| v.absorb(b[64 * k ..][0..64]);
    }

    /// Writes the sum back to the scalar state.
    fn finish(v: *const PolyV, p: *Poly) void {
        if (v.first) return;
        const t = mulv(v.h, v.rl, v.sl);
        var l: [5]u64 = undefined;
        for (0..5) |i| l[i] = @reduce(.Add, t[i]);
        // A full carry pass: each limb below 2^26, the last one too.
        inline for (0..2) |_| {
            l[1] += l[0] >> 26;
            l[0] &= m26;
            l[2] += l[1] >> 26;
            l[1] &= m26;
            l[3] += l[2] >> 26;
            l[2] &= m26;
            l[4] += l[3] >> 26;
            l[3] &= m26;
            l[0] += (l[4] >> 26) * 5;
            l[4] &= m26;
        }
        p.h0 = l[0] | (l[1] << 26) | (l[2] << 52);
        p.h1 = (l[2] >> 12) | (l[3] << 14) | (l[4] << 40);
        p.h2 = l[4] >> 24;
    }
};

/// The key of Poly1305: the first 32 bytes of block 0.
fn polyKey(key: *const [32]u8, nonce: *const [12]u8) Poly {
    const s = initState(key, nonce, 0);
    var ks = block1(&s, 0);
    const p = Poly.init(ks[0..32]);
    std.crypto.secureZero(u8, &ks);
    return p;
}

/// XORs the key stream from block `s[12]` into fewer than 512 bytes.
fn xorTail(s: *const State, dst: []u8, src: []const u8) void {
    if (src.len <= 128) {
        // One or two blocks: `block1` costs a quarter of `blocks8`.
        var off: usize = 0;
        var n: u32 = 0;
        while (off < src.len) : (n += 1) {
            const ks = block1(s, s[12] +% n);
            const k = @min(64, src.len - off);
            for (dst[off..][0..k], src[off..][0..k], ks[0..k]) |*d, a, b| d.* = a ^ b;
            off += k;
        }
        return;
    }
    var ks: [512]u8 = undefined;
    blocks8(s, &ks);
    for (dst, src, ks[0..src.len]) |*d, a, k| d.* = a ^ k;
}

/// Encrypts `src` and then `extra` into `dst` and gives the tag. `dst`
/// has the length of the two. `dst` and `src` start at the same place
/// or do not overlap. `extra` has at most 256 bytes.
pub fn seal(key: *const [32]u8, dst: []u8, tag: *[16]u8, src: []const u8, extra: []const u8, ad: []const u8, nonce: *const [12]u8) void {
    std.debug.assert(extra.len <= 256 and dst.len == src.len + extra.len);
    var p = polyKey(key, nonce);
    p.padded(ad);
    var s = initState(key, nonce, 1);
    var i: usize = 0;
    if (src.len >= 512) {
        var v = PolyV.init(&p);
        xor8(&s, dst[0..512], src[0..512]);
        s[12] +%= 8;
        i = 512;
        while (i + 512 <= src.len) : (i += 512) {
            xor8(&s, dst[i..][0..512], src[i..][0..512]);
            s[12] +%= 8;
            v.absorb512(dst[i - 512 ..][0..512]);
        }
        v.absorb512(dst[i - 512 ..][0..512]);
        v.finish(&p);
    }
    // The rest of `src` and then `extra`, in a buffer when `extra` has
    // bytes.
    var buf: [512 + 256]u8 = undefined;
    const rest_len = src.len - i + extra.len;
    const out = if (extra.len == 0) dst[i..] else buf[0..rest_len];
    const in = if (extra.len == 0) src[i..] else blk: {
        @memcpy(buf[0 .. src.len - i], src[i..]);
        @memcpy(buf[src.len - i ..][0..extra.len], extra);
        break :blk buf[0..rest_len];
    };
    var k: usize = 0;
    while (k + 512 <= in.len) : (k += 512) {
        xor8(&s, out[k..][0..512], in[k..][0..512]);
        s[12] +%= 8;
    }
    if (k < in.len) xorTail(&s, out[k..in.len], in[k..]);
    p.padded(out[0..in.len]);
    if (extra.len != 0) @memcpy(dst[i..][0..rest_len], out);
    tag.* = p.final(ad.len, src.len + extra.len);
}

/// Checks the tag and decrypts `src` into `dst`. On a bad tag, `dst` is
/// all zero bytes and the result is false.
pub fn open(key: *const [32]u8, dst: []u8, src: []const u8, tag: *const [16]u8, ad: []const u8, nonce: *const [12]u8) bool {
    var p = polyKey(key, nonce);
    p.padded(ad);
    var s = initState(key, nonce, 1);
    var i: usize = 0;
    var v = PolyV.init(&p);
    while (i + 512 <= src.len) : (i += 512) {
        v.absorb512(src[i..][0..512]);
        xor8(&s, dst[i..][0..512], src[i..][0..512]);
        s[12] +%= 8;
    }
    v.finish(&p);
    p.padded(src[i..]);
    if (i < src.len) xorTail(&s, dst[i..src.len], src[i..]);
    const t = p.final(ad.len, src.len);
    var d: u8 = 0;
    for (t, tag) |a, b| d |= a ^ b;
    if (d != 0) {
        std.crypto.secureZero(u8, dst[0..src.len]);
        return false;
    }
    return true;
}

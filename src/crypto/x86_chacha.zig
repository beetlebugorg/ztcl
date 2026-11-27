//! ChaCha20-Poly1305 (RFC 8439) for x86-64 CPUs with AVX2, in the
//! module `crypto_x86_avx2` (see `x86_avx2.zig`).
//!
//! ChaCha20 runs 8 blocks at a time: each of the 16 words of the state
//! is a vector of 8 lanes, one lane for each block. After the rounds, a
//! transpose of the two 8 by 8 halves gives the key stream of each
//! block. A rotation by 16 or 8 bits is a byte shuffle.
//!
//! Poly1305 is scalar, with two 64-bit limbs and a third small limb and
//! 64 by 64 bit products. The loop of `seal` and `open` encrypts 512
//! bytes and runs Poly1305 over 512 bytes of ciphertext in the same
//! step, so the vector units and the multiplier work at the same time.
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
    x[12] +%= V8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const x0 = x;
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
    inline for (0..16) |i| x[i] +%= x0[i];
    const lo = transpose(x[0..8].*);
    const hi = transpose(x[8..16].*);
    inline for (0..8) |j| {
        out[64 * j ..][0..32].* = @bitCast(lo[j]);
        out[64 * j + 32 ..][0..32].* = @bitCast(hi[j]);
    }
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

fn polyKey(key: *const [32]u8, nonce: *const [12]u8) Poly {
    const s = initState(key, nonce, 0);
    var ks: [512]u8 = undefined;
    blocks8(&s, &ks);
    const p = Poly.init(ks[0..32]);
    std.crypto.secureZero(u8, &ks);
    return p;
}

/// XORs the key stream from block `s[12]` into fewer than 512 bytes.
fn xorTail(s: *const State, dst: []u8, src: []const u8) void {
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
        xor8(&s, dst[0..512], src[0..512]);
        s[12] +%= 8;
        i = 512;
        while (i + 512 <= src.len) : (i += 512) {
            xor8(&s, dst[i..][0..512], src[i..][0..512]);
            s[12] +%= 8;
            p.blocks(dst[i - 512 ..][0..512]);
        }
        p.blocks(dst[i - 512 ..][0..512]);
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
    while (i + 512 <= src.len) : (i += 512) {
        p.blocks(src[i..][0..512]);
        xor8(&s, dst[i..][0..512], src[i..][0..512]);
        s[12] +%= 8;
    }
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

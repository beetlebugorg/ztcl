//! AES-GCM for aarch64 CPUs with the ARMv8 cryptographic extension
//! (AESE, AESMC, and PMULL).
//!
//! build.zig compiles this file as its own module, `crypto_arm_aes`,
//! with the `aes` feature added to the target. LLVM gives each function
//! of the module this feature, so a release binary for the baseline CPU
//! has this code too. `src/tls/aead.zig` reads the HWCAP bits (Linux) or
//! the processor feature of Windows and calls it only on a CPU with
//! AES and PMULL. The functions of this module take pointers and slices
//! only.
//!
//! The method is the one of `x86_avx2.zig`: one pass, 8 blocks of AES at
//! a time, and GHASH of 8 blocks with one reduction. AESE adds the round
//! key before the S-box, so the rounds add the last key with an XOR. The
//! key expansion gets SubWord from AESE with a zero key on a word that
//! fills the four columns: ShiftRows does not move a byte to a column
//! with a different value.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");

/// The CPU features of this module, for the check in `aead.zig`.
pub const features = builtin.cpu.features;

/// True when this module has its CPU features: an aarch64 target with
/// the LLVM backend.
pub const enabled = builtin.cpu.arch == .aarch64 and builtin.zig_backend == .stage2_llvm and
    builtin.cpu.has(.aarch64, .aes);

const V = @Vector(2, u64);
const B = @Vector(16, u8);
const W = @Vector(4, u32);

/// The expanded key of AES-128 or AES-256 and the powers H^1 to H^8 of
/// the GHASH key.
pub const Gcm = struct {
    rk: [15]V align(16),
    h: [8]V align(16),
    rounds: u8,
};

/// One full round: AddRoundKey, SubBytes, ShiftRows, MixColumns.
inline fn round(s: V, k: V) V {
    return asm (
        \\aese %[s].16b, %[k].16b
        \\aesmc %[s].16b, %[s].16b
        : [s] "=w" (-> V),
        : [in] "0" (s),
          [k] "w" (k),
    );
}

/// AddRoundKey, SubBytes, ShiftRows.
inline fn roundLast(s: V, k: V) V {
    return asm ("aese %[s].16b, %[k].16b"
        : [s] "=w" (-> V),
        : [in] "0" (s),
          [k] "w" (k),
    );
}

inline fn pmull(a: V, b: V) V {
    return asm ("pmull %[o].1q, %[a].1d, %[b].1d"
        : [o] "=w" (-> V),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

inline fn pmull2(a: V, b: V) V {
    return asm ("pmull2 %[o].1q, %[a].2d, %[b].2d"
        : [o] "=w" (-> V),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

/// The 64-bit carry-less product of a half of `a` and a half of `b`.
/// Bit 0 of `imm` picks the half of `a`, and bit 4 the half of `b`, as
/// for PCLMULQDQ.
inline fn clmul(a: V, b: V, comptime imm: u8) V {
    return switch (imm) {
        0x00 => pmull(a, b),
        0x11 => pmull2(a, b),
        0x01 => pmull(swap(a), b),
        0x10 => pmull(a, swap(b)),
        else => unreachable,
    };
}

/// The words 2 and 3 of AESKEYGENASSIST of x86: SubWord of word 3, and
/// RotWord of it XOR `rcon`.
inline fn keyAssist(a: V, comptime rcon: u8) V {
    const w: W = @bitCast(a);
    const s: W = @bitCast(roundLast(@bitCast(@as(W, @splat(w[3]))), zero));
    return @bitCast(W{ 0, 0, s[0], std.math.rotr(u32, s[0], 8) ^ rcon });
}

inline fn load(p: *const [16]u8) V {
    return @bitCast(@as(B, p.*));
}

inline fn store(p: *[16]u8, v: V) void {
    p.* = @as(B, @bitCast(v));
}

/// The block as the GHASH integer: the bytes in reverse order.
inline fn rev(v: V) V {
    const b: B = @bitCast(v);
    return @bitCast(@shuffle(u8, b, undefined, [16]i32{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 }));
}

inline fn swap(v: V) V {
    return @shuffle(u64, v, undefined, [2]i32{ 1, 0 });
}

const zero: V = @splat(0);

/// The 256-bit product of a carry-less multiplication, in three parts:
/// lo, the middle sum, and hi.
const Wide = struct {
    lo: V,
    mid: V,
    hi: V,

    inline fn of(a: V, b: V) Wide {
        return .{
            .lo = clmul(a, b, 0x00),
            .mid = clmul(a, b, 0x01) ^ clmul(a, b, 0x10),
            .hi = clmul(a, b, 0x11),
        };
    }

    inline fn add(w: *Wide, a: V, b: V) void {
        w.lo ^= clmul(a, b, 0x00);
        w.mid ^= clmul(a, b, 0x01) ^ clmul(a, b, 0x10);
        w.hi ^= clmul(a, b, 0x11);
    }

    /// Reduces modulo x^128 + x^127 + x^126 + x^121 + 1.
    inline fn reduce(w: Wide) V {
        const lo = w.lo ^ @shuffle(u64, w.mid, zero, [2]i32{ -1, 0 });
        const hi = w.hi ^ @shuffle(u64, w.mid, zero, [2]i32{ 1, -1 });
        const p: V = .{ 0xc200000000000000, 0 };
        const b = swap(lo) ^ clmul(lo, p, 0x00);
        const d = swap(b) ^ clmul(b, p, 0x00);
        return d ^ hi;
    }
};

inline fn mul(a: V, h: V) V {
    return Wide.of(a, h).reduce();
}

/// The running XOR of the four 32-bit words: word i is the XOR of
/// words 0 to i.
inline fn prefix(a: V) V {
    const w: W = @bitCast(a);
    const z: W = @splat(0);
    var x = w ^ @shuffle(u32, w, z, [4]i32{ -1, 0, 1, 2 });
    x ^= @shuffle(u32, x, z, [4]i32{ -1, -1, 0, 1 });
    return @bitCast(x);
}

inline fn lane(a: V, comptime i: i32) V {
    const w: W = @bitCast(a);
    return @bitCast(@shuffle(u32, w, undefined, [4]i32{ i, i, i, i }));
}

/// Expands a key of 16 or 32 bytes and computes the powers of H.
pub fn init(g: *Gcm, key: []const u8) void {
    @setEvalBranchQuota(100_000);
    std.debug.assert(key.len == 16 or key.len == 32);
    if (key.len == 16) {
        g.rounds = 10;
        g.rk[0] = load(key[0..16]);
        inline for (.{ 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36 }, 1..) |rc, i| {
            g.rk[i] = prefix(g.rk[i - 1]) ^ lane(keyAssist(g.rk[i - 1], rc), 3);
        }
    } else {
        g.rounds = 14;
        g.rk[0] = load(key[0..16]);
        g.rk[1] = load(key[16..32]);
        inline for (.{ 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40 }, 0..) |rc, j| {
            const i = 2 + 2 * j;
            g.rk[i] = prefix(g.rk[i - 2]) ^ lane(keyAssist(g.rk[i - 1], rc), 3);
            if (i + 1 < 15) g.rk[i + 1] = prefix(g.rk[i - 1]) ^ lane(keyAssist(g.rk[i], 0), 2);
        }
    }
    const e = if (g.rounds == 10) encrypt1(10, &g.rk, zero) else encrypt1(14, &g.rk, zero);
    const r = rev(e);
    // H times x: shift left by one bit and reduce.
    const carry: u64 = 0 -% (r[1] >> 63);
    const h: V = .{ (r[0] << 1) ^ (1 & carry), ((r[1] << 1) | (r[0] >> 63)) ^ (0xc200000000000000 & carry) };
    g.h[0] = h;
    for (1..8) |i| g.h[i] = mul(g.h[i - 1], h);
}

inline fn encrypt1(comptime nr: comptime_int, rk: *const [15]V, x: V) V {
    var s = x;
    inline for (0..nr - 1) |r| s = round(s, rk[r]);
    return roundLast(s, rk[nr - 1]) ^ rk[nr];
}

inline fn encrypt8(comptime nr: comptime_int, rk: *const [15]V, s: *[8]V) void {
    inline for (0..nr - 1) |r| {
        const k = rk[r];
        inline for (s) |*x| x.* = round(x.*, k);
    }
    const k = rk[nr - 1];
    const l = rk[nr];
    inline for (s) |*x| x.* = roundLast(x.*, k) ^ l;
}

/// The counter block: the nonce and the 32-bit count in network order.
inline fn counter(n: W, c: u32) V {
    var w = n;
    w[3] = @byteSwap(c);
    return @bitCast(w);
}

/// The 8 counter blocks from `c`. When the last byte of the count does
/// not carry, a 32-bit add into that byte of the first block gives each
/// one.
inline fn counters8(n: W, c: u32, s: *[8]V) void {
    if (c & 0xff <= 0xff - 7) {
        const base: W = @bitCast(counter(n, c));
        inline for (s, 0..) |*x, j| x.* = @bitCast(base +% W{ 0, 0, 0, @as(u32, j) << 24 });
    } else {
        inline for (s, 0..) |*x, j| x.* = counter(n, c +% @as(u32, j));
    }
}

/// Folds 8 blocks into the GHASH state with one reduction.
inline fn ghash8(g: *const Gcm, acc: V, blocks: *const [128]u8) V {
    var w = Wide.of(rev(load(blocks[0..16])) ^ acc, g.h[7]);
    inline for (1..8) |j| w.add(rev(load(blocks[16 * j ..][0..16])), g.h[7 - j]);
    return w.reduce();
}

fn ghash(g: *const Gcm, acc0: V, data: []const u8) V {
    var acc = acc0;
    var i: usize = 0;
    while (i + 128 <= data.len) : (i += 128) acc = ghash8(g, acc, data[i..][0..128]);
    while (i + 16 <= data.len) : (i += 16) acc = mul(acc ^ rev(load(data[i..][0..16])), g.h[0]);
    if (i < data.len) {
        var buf: [16]u8 = @splat(0);
        @memcpy(buf[0 .. data.len - i], data[i..]);
        acc = mul(acc ^ rev(load(&buf)), g.h[0]);
    }
    return acc;
}

fn finish(comptime nr: comptime_int, g: *const Gcm, acc0: V, j0: V, ad_len: usize, len: usize) V {
    const lens: V = .{ @as(u64, len) * 8, @as(u64, ad_len) * 8 };
    const acc = mul(acc0 ^ lens, g.h[0]);
    return rev(acc) ^ encrypt1(nr, &g.rk, j0);
}

/// XORs the key stream of `ctr` into the tail of fewer than 16 bytes.
fn xorTail(comptime nr: comptime_int, g: *const Gcm, ctr: V, dst: []u8, src: []const u8) void {
    var buf: [16]u8 = @splat(0);
    @memcpy(buf[0..src.len], src);
    store(&buf, load(&buf) ^ encrypt1(nr, &g.rk, ctr));
    @memcpy(dst, buf[0..src.len]);
}

/// The longest `extra` of `seal`.
pub const max_extra = 256;

/// Encrypts the bytes of `src` and then of `extra` into `dst`.
fn sealN(comptime nr: comptime_int, g: *const Gcm, dst: []u8, tag: *[16]u8, src: []const u8, extra: []const u8, ad: []const u8, nonce: *const [12]u8) void {
    @setEvalBranchQuota(100_000);
    const n: W = .{ std.mem.readInt(u32, nonce[0..4], .little), std.mem.readInt(u32, nonce[4..8], .little), std.mem.readInt(u32, nonce[8..12], .little), 0 };
    var acc = ghash(g, zero, ad);
    var c: u32 = 2;
    var i: usize = 0;
    if (src.len >= 128) {
        var s: [8]V = undefined;
        counters8(n, c, &s);
        c +%= 8;
        encrypt8(nr, &g.rk, &s);
        inline for (s, 0..) |x, j| store(dst[16 * j ..][0..16], x ^ load(src[16 * j ..][0..16]));
        i = 128;
        while (i + 128 <= src.len) : (i += 128) {
            counters8(n, c, &s);
            c +%= 8;
            encrypt8(nr, &g.rk, &s);
            acc = ghash8(g, acc, dst[i - 128 ..][0..128]);
            inline for (s, 0..) |x, j| store(dst[i + 16 * j ..][0..16], x ^ load(src[i + 16 * j ..][0..16]));
        }
        acc = ghash8(g, acc, dst[i - 128 ..][0..128]);
    }
    // The rest of `src` and then `extra`: in a buffer when `extra` has
    // bytes.
    var buf: [128 + max_extra]u8 = undefined;
    const rest_len = src.len - i + extra.len;
    const out = if (extra.len == 0) dst[i..] else buf[0..rest_len];
    const in = if (extra.len == 0) src[i..] else blk: {
        @memcpy(buf[0 .. src.len - i], src[i..]);
        @memcpy(buf[src.len - i ..][0..extra.len], extra);
        break :blk buf[0..rest_len];
    };
    var k: usize = 0;
    while (k + 16 <= in.len) : (k += 16) {
        store(out[k..][0..16], load(in[k..][0..16]) ^ encrypt1(nr, &g.rk, counter(n, c)));
        c +%= 1;
    }
    if (k < in.len) xorTail(nr, g, counter(n, c), out[k..in.len], in[k..]);
    acc = ghash(g, acc, out[0..in.len]);
    if (extra.len != 0) @memcpy(dst[i..][0..rest_len], out);
    store(tag, finish(nr, g, acc, counter(n, 1), ad.len, src.len + extra.len));
}

fn openN(comptime nr: comptime_int, g: *const Gcm, dst: []u8, src: []const u8, tag: *const [16]u8, ad: []const u8, nonce: *const [12]u8) bool {
    @setEvalBranchQuota(100_000);
    const n: W = .{ std.mem.readInt(u32, nonce[0..4], .little), std.mem.readInt(u32, nonce[4..8], .little), std.mem.readInt(u32, nonce[8..12], .little), 0 };
    var acc = ghash(g, zero, ad);
    var c: u32 = 2;
    var i: usize = 0;
    while (i + 128 <= src.len) : (i += 128) {
        var s: [8]V = undefined;
        counters8(n, c, &s);
        c +%= 8;
        var in: [8]V = undefined;
        inline for (&in, 0..) |*x, j| x.* = load(src[i + 16 * j ..][0..16]);
        acc = ghash8(g, acc, src[i..][0..128]);
        encrypt8(nr, &g.rk, &s);
        inline for (s, in, 0..) |x, y, j| store(dst[i + 16 * j ..][0..16], x ^ y);
    }
    acc = ghash(g, acc, src[i..]);
    while (i + 16 <= src.len) : (i += 16) {
        store(dst[i..][0..16], load(src[i..][0..16]) ^ encrypt1(nr, &g.rk, counter(n, c)));
        c +%= 1;
    }
    if (i < src.len) xorTail(nr, g, counter(n, c), dst[i..src.len], src[i..]);
    const t = finish(nr, g, acc, counter(n, 1), ad.len, src.len) ^ load(tag);
    if ((t[0] | t[1]) != 0) {
        std.crypto.secureZero(u8, dst[0..src.len]);
        return false;
    }
    return true;
}

/// Encrypts `src` and then `extra` into `dst` and gives the tag. `dst`
/// has the length of the two. `dst` and `src` start at the same place
/// or do not overlap. `extra` has at most `max_extra` bytes.
pub fn seal(g: *const Gcm, dst: []u8, tag: *[16]u8, src: []const u8, extra: []const u8, ad: []const u8, nonce: *const [12]u8) void {
    std.debug.assert(extra.len <= max_extra and dst.len == src.len + extra.len);
    if (g.rounds == 10) sealN(10, g, dst, tag, src, extra, ad, nonce) else sealN(14, g, dst, tag, src, extra, ad, nonce);
}

/// Checks the tag and decrypts `src` into `dst`. On a bad tag, `dst` is
/// all zero bytes and the result is false. `dst` and `src` are the same
/// buffer or do not overlap.
pub fn open(g: *const Gcm, dst: []u8, src: []const u8, tag: *const [16]u8, ad: []const u8, nonce: *const [12]u8) bool {
    return if (g.rounds == 10) openN(10, g, dst, src, tag, ad, nonce) else openN(14, g, dst, src, tag, ad, nonce);
}

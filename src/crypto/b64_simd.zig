//! The vector loops of base64 for `binary encode base64` and `binary
//! decode base64` (src/more.zig).
//!
//! The method comes from the paper of Wojciech Muła and Daniel Lemire,
//! "Faster Base64 Encoding and Decoding Using AVX2 Instructions" (ACM
//! Transactions on the Web, 2018): each 32-bit lane holds the bits of
//! three bytes, shifts and masks give the four 6-bit values, and a
//! translation by ranges gives the characters. The decoder translates
//! each character back by its range, checks that each character of the
//! block is valid, packs four 6-bit values into three bytes, and
//! compresses the lanes with one shuffle. This file is our own code of
//! that method with the portable vectors of Zig. The translation uses
//! compares and selects in place of the byte lookups of the paper, so
//! the same code builds for AVX2, SSE2, NEON, and SIMD128.
//!
//! build.zig compiles this file as its own module, `b64_simd`. On
//! x86-64 the module has AVX2 and the other features of
//! `crypto_x86_avx2`, and src/more.zig calls it only on a CPU that has
//! them (`aead.available(.x86_avx2)`). On other targets it has the
//! features of the target. The functions take slices only, so the ABI
//! is the same with and without AVX.
//!
//! Each function does only whole blocks and gives the count that it
//! did. The scalar code of src/more.zig does the rest: the tail, the
//! padding, the white space, and each error with its position.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");

/// The bytes of one vector: 32 with AVX2, else 16.
const n = if (builtin.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .avx2)) 32 else 16;

/// True when this module has vectors worth a call: AVX2 on x86-64,
/// NEON on aarch64, SIMD128 on wasm. The UEFI build of the enclave has
/// no check of the CPU, so it uses the scalar code.
pub const enabled = builtin.zig_backend == .stage2_llvm and builtin.os.tag != .uefi and switch (builtin.cpu.arch) {
    .x86_64 => builtin.cpu.has(.x86, .avx2),
    .aarch64 => builtin.cpu.has(.aarch64, .neon),
    .wasm32 => builtin.cpu.has(.wasm, .simd128),
    else => false,
};

const V8 = @Vector(n, u8);
const V32 = @Vector(n / 4, u32);

fn splat8(x: u8) V8 {
    return @splat(x);
}

fn splat32(x: u32) V32 {
    return @splat(x);
}

/// A shift count for each 32-bit lane.
fn sh(x: u5) @Vector(n / 4, u5) {
    return @splat(x);
}

/// The input lanes of the encoder: lane 4g+0..3 has bytes 3g+2, 3g+1,
/// 3g, 3g of the block, so a little-endian 32-bit lane is
/// b0 << 16 | b1 << 8 | b2 in its low 24 bits.
const enc_mask: [n]i32 = blk: {
    var m: [n]i32 = undefined;
    for (0..n / 4) |g| {
        m[4 * g + 0] = @intCast(3 * g + 2);
        m[4 * g + 1] = @intCast(3 * g + 1);
        m[4 * g + 2] = @intCast(3 * g);
        m[4 * g + 3] = @intCast(3 * g);
    }
    break :blk m;
};

/// The bytes of the decoder output: bytes 2, 1, and 0 of each lane.
const dec_mask: [n / 4 * 3]i32 = blk: {
    var m: [n / 4 * 3]i32 = undefined;
    for (0..n / 4) |g| {
        m[3 * g + 0] = @intCast(4 * g + 2);
        m[3 * g + 1] = @intCast(4 * g + 1);
        m[3 * g + 2] = @intCast(4 * g);
    }
    break :blk m;
};

/// The characters of the 6-bit values of `idx`.
inline fn chars(idx: V8) V8 {
    // A-Z: +65, a-z: +71, 0-9: -4, '+': -19, '/': -16 (as wrapping adds).
    const off = @select(u8, idx < splat8(26), splat8(65), @select(u8, idx < splat8(52), splat8(71), @select(u8, idx < splat8(62), splat8(@bitCast(@as(i8, -4))), @select(u8, idx == splat8(62), splat8(@bitCast(@as(i8, -19))), splat8(@bitCast(@as(i8, -16)))))));
    return idx +% off;
}

/// Encodes whole blocks of `in` to `out`: `n` characters for each
/// `n / 4 * 3` bytes. A block reads `n` bytes, so the loop stops while
/// `n` bytes remain. Gives the count of bytes of `in` that it did; the
/// count of characters is that count / 3 * 4.
pub fn encode(out: []u8, in: []const u8) usize {
    const step = n / 4 * 3;
    var i: usize = 0;
    var o: usize = 0;
    while (i + n <= in.len and o + n <= out.len) : ({
        i += step;
        o += n;
    }) {
        const raw: V8 = in[i..][0..n].*;
        const lanes: V8 = @shuffle(u8, raw, undefined, enc_mask);
        const v: V32 = @bitCast(lanes);
        const m6 = splat32(63);
        const f = ((v >> sh(18)) & m6) |
            (((v >> sh(12)) & m6) << sh(8)) |
            (((v >> sh(6)) & m6) << sh(16)) |
            ((v & m6) << sh(24));
        out[o..][0..n].* = chars(@bitCast(f));
    }
    return i;
}

/// Decodes whole blocks of `n` valid characters of `in` to `out`:
/// `n / 4 * 3` bytes for each block. The first block with another
/// character (padding, white space, or an invalid byte) stops the loop.
/// Gives the count of characters of `in` that it did; the count of
/// bytes is that count / 4 * 3.
pub fn decode(out: []u8, in: []const u8) usize {
    const step = n / 4 * 3;
    var i: usize = 0;
    var o: usize = 0;
    while (i + n <= in.len and o + step <= out.len) : ({
        i += n;
        o += step;
    }) {
        const c: V8 = in[i..][0..n].*;
        const up = (c >= splat8('A')) & (c <= splat8('Z'));
        const low = (c >= splat8('a')) & (c <= splat8('z'));
        const dig = (c >= splat8('0')) & (c <= splat8('9'));
        const plus = c == splat8('+');
        const slash = c == splat8('/');
        const ok = up | low | dig | plus | slash;
        if (!@reduce(.And, ok)) break;
        // A-Z: -65, a-z: -71, 0-9: +4, '+': +19, '/': +16.
        const off = @select(u8, up, splat8(@bitCast(@as(i8, -65))), @select(u8, low, splat8(@bitCast(@as(i8, -71))), @select(u8, dig, splat8(4), @select(u8, plus, splat8(19), splat8(16)))));
        const d: V32 = @bitCast(c +% off);
        const m8 = splat32(0xff);
        const x = ((d & m8) << sh(18)) |
            (((d >> sh(8)) & m8) << sh(12)) |
            (((d >> sh(16)) & m8) << sh(6)) |
            (d >> sh(24));
        const bytes: V8 = @bitCast(x);
        const packed_bytes: @Vector(step, u8) = @shuffle(u8, bytes, undefined, dec_mask);
        out[o..][0..step].* = packed_bytes;
    }
    return i;
}

/// The count of bytes at the start of `s` in whole blocks of 4 vectors
/// with no byte above 127. The caller checks the rest.
pub fn asciiPrefix(s: []const u8) usize {
    var i: usize = 0;
    while (i + 4 * n <= s.len) : (i += 4 * n) {
        const a: V8 = s[i..][0..n].*;
        const b: V8 = s[i + n ..][0..n].*;
        const c: V8 = s[i + 2 * n ..][0..n].*;
        const d: V8 = s[i + 3 * n ..][0..n].*;
        if (@reduce(.Max, a | b | c | d) >= 0x80) break;
    }
    return i;
}

/// The lanes of the hex encoder: the high and the low digit of each
/// byte, one after the other. Lane k of `a` is -(k + 1) in a mask.
const hex_mask: [2 * n]i32 = blk: {
    var m: [2 * n]i32 = undefined;
    for (0..n) |k| {
        m[2 * k] = @intCast(k);
        m[2 * k + 1] = ~@as(i32, @intCast(k));
    }
    break :blk m;
};

inline fn hexDigits(d: V8) V8 {
    return d +% @select(u8, d < splat8(10), splat8('0'), splat8('a' - 10));
}

/// Encodes whole blocks of `n` bytes of `in` to hex in `out`. Gives
/// the count of bytes that it did.
pub fn hexEncode(out: []u8, in: []const u8) usize {
    var i: usize = 0;
    while (i + n <= in.len and 2 * i + 2 * n <= out.len) : (i += n) {
        const b: V8 = in[i..][0..n].*;
        const hi = hexDigits(b >> @splat(4));
        const lo = hexDigits(b & splat8(15));
        out[2 * i ..][0 .. 2 * n].* = @as([2 * n]u8, @shuffle(u8, hi, lo, hex_mask));
    }
    return i;
}

const even_mask: [n / 2]i32 = blk: {
    var m: [n / 2]i32 = undefined;
    for (0..n / 2) |k| m[k] = @intCast(2 * k);
    break :blk m;
};

const odd_mask: [n / 2]i32 = blk: {
    var m: [n / 2]i32 = undefined;
    for (0..n / 2) |k| m[k] = @intCast(2 * k + 1);
    break :blk m;
};

/// Decodes whole blocks of `n` hex digits of `in` to `out`: `n / 2`
/// bytes for each block. The first block with another character stops
/// the loop. Gives the count of characters that it did.
pub fn hexDecode(out: []u8, in: []const u8) usize {
    var i: usize = 0;
    while (i + n <= in.len and i / 2 + n / 2 <= out.len) : (i += n) {
        const c: V8 = in[i..][0..n].*;
        const dig = (c >= splat8('0')) & (c <= splat8('9'));
        const l = c | splat8(0x20);
        const alpha = (l >= splat8('a')) & (l <= splat8('f'));
        if (!@reduce(.And, dig | alpha)) break;
        const d = @select(u8, dig, c -% splat8('0'), l -% splat8('a' - 10));
        const hi: @Vector(n / 2, u8) = @shuffle(u8, d, undefined, even_mask);
        const lo: @Vector(n / 2, u8) = @shuffle(u8, d, undefined, odd_mask);
        out[i / 2 ..][0 .. n / 2].* = @as([n / 2]u8, (hi << @splat(4)) | lo);
    }
    return i;
}

test "hex encode and decode" {
    var in: [100]u8 = undefined;
    for (&in, 0..) |*b, k| b.* = @truncate(k *% 37 +% 1);
    var out: [200]u8 = undefined;
    const did = hexEncode(&out, &in);
    for (in[0..did], 0..) |b, k| {
        try std.testing.expectEqual("0123456789abcdef"[b >> 4], out[2 * k]);
        try std.testing.expectEqual("0123456789abcdef"[b & 15], out[2 * k + 1]);
    }
    for (out[0 .. 2 * did], 0..) |*c, k| if (k % 3 == 0) {
        c.* = std.ascii.toUpper(c.*);
    };
    var back: [100]u8 = undefined;
    const used = hexDecode(&back, out[0 .. 2 * did]);
    try std.testing.expectEqualSlices(u8, in[0 .. used / 2], back[0 .. used / 2]);
}

test "encode and decode match the scalar form" {
    const b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var in: [300]u8 = undefined;
    for (&in, 0..) |*b, k| b.* = @truncate(k *% 151 +% 7);
    var out: [400]u8 = undefined;
    const did = encode(&out, &in);
    try std.testing.expect(did % 3 == 0 and did > 0);
    var k: usize = 0;
    while (k < did) : (k += 3) {
        const v = @as(u32, in[k]) << 16 | @as(u32, in[k + 1]) << 8 | in[k + 2];
        const o = k / 3 * 4;
        try std.testing.expectEqual(b64[v >> 18], out[o]);
        try std.testing.expectEqual(b64[(v >> 12) & 63], out[o + 1]);
        try std.testing.expectEqual(b64[(v >> 6) & 63], out[o + 2]);
        try std.testing.expectEqual(b64[v & 63], out[o + 3]);
    }
    var back: [300]u8 = undefined;
    const used = decode(&back, out[0 .. did / 3 * 4]);
    try std.testing.expect(used % n == 0);
    try std.testing.expectEqualSlices(u8, in[0 .. used / 4 * 3], back[0 .. used / 4 * 3]);
}

const test_b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const test_hex = "0123456789abcdef";
const test_value: [256]u8 = blk: {
    var v: [256]u8 = @splat(255);
    for (test_b64, 0..) |c, i| v[c] = @intCast(i);
    break :blk v;
};

test "the vector loops of base64 and hex match the scalar code" {
    if (!enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x6236345f73696d64);
    const r = prng.random();
    const alphabet = test_b64 ++ "=\n \t!-\x80";
    for (0..2000) |round| {
        const len = r.uintLessThan(usize, 400);
        const bytes = try a.alloc(u8, len);
        defer a.free(bytes);
        r.bytes(bytes);
        // Encode: the vector part equals the scalar table.
        const text = try a.alloc(u8, (len + 2) / 3 * 4);
        defer a.free(text);
        const did = encode(text, bytes);
        try std.testing.expect(did % 3 == 0 and did <= len);
        var k: usize = 0;
        while (k < did) : (k += 3) {
            const v = @as(u32, bytes[k]) << 16 | @as(u32, bytes[k + 1]) << 8 | bytes[k + 2];
            try std.testing.expectEqualSlices(u8, &([4]u8{ test_b64[v >> 18], test_b64[(v >> 12) & 63], test_b64[(v >> 6) & 63], test_b64[v & 63] }), text[k / 3 * 4 ..][0..4]);
        }
        // Decode of a text with a few other characters: each whole
        // block before the first other character, and no more.
        const txt = try a.alloc(u8, len);
        defer a.free(txt);
        for (txt) |*c| c.* = test_b64[r.uintLessThan(usize, 64)];
        if (round % 2 == 0 and len > 0) txt[r.uintLessThan(usize, len)] = alphabet[64 + r.uintLessThan(usize, alphabet.len - 64)];
        const out = try a.alloc(u8, len / 4 * 3 + 3);
        defer a.free(out);
        const used = decode(out, txt);
        try std.testing.expect(used % 4 == 0 and used <= len);
        for (txt[0..used]) |c| try std.testing.expect(test_value[c] < 64);
        var q: usize = 0;
        while (q < used) : (q += 4) {
            const v = @as(u32, test_value[txt[q]]) << 18 | @as(u32, test_value[txt[q + 1]]) << 12 | @as(u32, test_value[txt[q + 2]]) << 6 | test_value[txt[q + 3]];
            try std.testing.expectEqualSlices(u8, &[3]u8{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) }, out[q / 4 * 3 ..][0..3]);
        }
        // The loop stops only at a block with another character or at
        // the end.
        const step = used + 64;
        if (step <= len) {
            var bad = false;
            for (txt[used..step]) |c| bad = bad or test_value[c] >= 64;
            try std.testing.expect(bad or step - used < 64);
        }
        // Hex.
        const hex = try a.alloc(u8, 2 * len);
        defer a.free(hex);
        const hd = hexEncode(hex, bytes);
        for (bytes[0..hd], 0..) |b, j| try std.testing.expectEqualSlices(u8, &[2]u8{ test_hex[b >> 4], test_hex[b & 15] }, hex[2 * j ..][0..2]);
        for (hex[0 .. 2 * hd]) |*c| if (r.boolean()) {
            c.* = std.ascii.toUpper(c.*);
        };
        const back = try a.alloc(u8, len);
        defer a.free(back);
        const hu = hexDecode(back, hex[0 .. 2 * hd]);
        try std.testing.expect(hu % 2 == 0);
        try std.testing.expectEqualSlices(u8, bytes[0 .. hu / 2], back[0 .. hu / 2]);
        // The ASCII scan.
        const ap = asciiPrefix(bytes);
        for (bytes[0..ap]) |b| try std.testing.expect(b < 0x80);
    }
}

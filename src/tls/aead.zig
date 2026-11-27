//! AES-GCM with a choice of code at run time.
//!
//! A release binary targets the baseline CPU of its architecture, and
//! `std.crypto` picks AES-NI and PCLMULQDQ at compile time from the
//! target, so a release binary has the software AES of `std.crypto`
//! only. This file reads the CPU features once (CPUID and XGETBV on
//! x86-64, the HWCAP bits on aarch64 Linux, the processor features on
//! aarch64 Windows) and calls the code of `src/crypto/x86_avx2.zig` or
//! `src/crypto/arm_aes.zig` when the CPU has each feature that build.zig
//! gives that module. On another CPU, or another architecture, it calls
//! `std.crypto`.
//!
//! The check is at compile time too: each feature of the module past
//! the target of this file has a CPUID bit in `x86_bits` or an entry in
//! `arm_extra`, or the build fails.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const kx = @import("crypto_x86_avx2");
const ka = @import("crypto_arm_aes");

comptime {
    if (kx.enabled) std.debug.assert(kx.max_extra == Gcm.max_extra);
    if (ka.enabled) std.debug.assert(ka.max_extra == Gcm.max_extra);
}
const soft = std.crypto.aead.aes_gcm;

pub const tag_len = 16;
pub const nonce_len = 12;

/// The code that `Gcm` calls.
pub const Impl = enum(u8) { unknown, soft, x86_avx2, arm_aes };

var impl_cache: std.atomic.Value(Impl) = .init(.unknown);

/// Gives the code for this CPU. The first call reads the CPU.
pub fn impl() Impl {
    const v = impl_cache.load(.monotonic);
    if (v != .unknown) return v;
    const d = detect();
    impl_cache.store(d, .monotonic);
    return d;
}

/// Sets the code for the tests and the bench. `.unknown` reads the CPU
/// again on the next call.
pub fn force(i: Impl) void {
    impl_cache.store(i, .monotonic);
}

/// True when `i` runs on this CPU.
pub fn available(i: Impl) bool {
    return switch (i) {
        .unknown, .soft => true,
        .x86_avx2, .arm_aes => detect() == i,
    };
}

const Bit = struct { f: std.Target.x86.Feature, leaf: u32, reg: enum { ebx, ecx }, bit: u5 };

/// The CPUID bits of the x86 features that a module of src/crypto can
/// have past the baseline: leaf 1 or leaf 7 (subleaf 0).
const x86_bits = [_]Bit{
    .{ .f = .sse3, .leaf = 1, .reg = .ecx, .bit = 0 },
    .{ .f = .pclmul, .leaf = 1, .reg = .ecx, .bit = 1 },
    .{ .f = .ssse3, .leaf = 1, .reg = .ecx, .bit = 9 },
    .{ .f = .sse4_1, .leaf = 1, .reg = .ecx, .bit = 19 },
    .{ .f = .sse4_2, .leaf = 1, .reg = .ecx, .bit = 20 },
    .{ .f = .crc32, .leaf = 1, .reg = .ecx, .bit = 20 },
    .{ .f = .popcnt, .leaf = 1, .reg = .ecx, .bit = 23 },
    .{ .f = .aes, .leaf = 1, .reg = .ecx, .bit = 25 },
    .{ .f = .avx, .leaf = 1, .reg = .ecx, .bit = 28 },
    .{ .f = .bmi, .leaf = 7, .reg = .ebx, .bit = 3 },
    .{ .f = .avx2, .leaf = 7, .reg = .ebx, .bit = 5 },
    .{ .f = .bmi2, .leaf = 7, .reg = .ebx, .bit = 8 },
};

/// The features of module `m` that the target of this file does not
/// have. Each one has an entry in `x86_bits`.
fn extraX86(comptime m: std.Target.Cpu.Feature.Set) []const Bit {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: []const Bit = &.{};
        const here = builtin.cpu.features;
        for (std.enums.values(std.Target.x86.Feature)) |f| {
            const i = @backingInt(f);
            if (!m.isEnabled(i) or here.isEnabled(i)) continue;
            const b = for (x86_bits) |b| {
                if (b.f == f) break b;
            } else @compileError("src/crypto has the x86 feature " ++ @tagName(f) ++ " with no CPUID bit in aead.zig");
            out = out ++ &[_]Bit{b};
        }
        return out;
    }
}

const Cpuid = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf: u32, sub: u32) Cpuid {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (a),
          [_] "={ebx}" (b),
          [_] "={ecx}" (c),
          [_] "={edx}" (d),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (sub),
    );
    return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
}

fn xcr0() u32 {
    return asm volatile (
        \\ xor %%ecx, %%ecx
        \\ xgetbv
        : [_] "={eax}" (-> u32),
        :
        : .{ .edx = true, .ecx = true });
}

/// True when the CPU has each feature of `bits`. An AVX feature also
/// needs the OS to save the YMM registers: OSXSAVE and bits 1 and 2 of
/// XCR0.
fn hasX86(comptime bits: []const Bit) bool {
    const max = cpuid(0, 0).eax;
    if (max < 7) return false;
    const l1 = cpuid(1, 0);
    const l7 = cpuid(7, 0);
    inline for (bits) |b| {
        const r = if (b.leaf == 1) l1 else l7;
        const v = if (b.reg == .ebx) r.ebx else r.ecx;
        if ((v >> b.bit) & 1 == 0) return false;
    }
    const avx = comptime for (bits) |b| {
        if (b.f == .avx or b.f == .avx2) break true;
    } else false;
    if (avx) {
        if ((l1.ecx >> 27) & 1 == 0) return false;
        if (xcr0() & 6 != 6) return false;
    }
    return true;
}

/// The aarch64 features that a module of src/crypto can have past the
/// target. `aes` is AES and PMULL (FEAT_AES and FEAT_PMULL).
const arm_extra = [_]std.Target.aarch64.Feature{.aes};

fn extraArm(comptime m: std.Target.Cpu.Feature.Set) usize {
    comptime {
        @setEvalBranchQuota(100_000);
        var n: usize = 0;
        const here = builtin.cpu.features;
        for (std.enums.values(std.Target.aarch64.Feature)) |f| {
            const i = @backingInt(f);
            if (!m.isEnabled(i) or here.isEnabled(i)) continue;
            if (std.mem.indexOfScalar(std.Target.aarch64.Feature, &arm_extra, f) == null)
                @compileError("src/crypto has the aarch64 feature " ++ @tagName(f) ++ " with no check in aead.zig");
            n += 1;
        }
        return n;
    }
}

/// True when the CPU has AES and PMULL. Linux: bits 3 and 4 of
/// AT_HWCAP. Windows: PF_ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE (30).
/// macOS: each Apple CPU has them, and the target of Zig has them.
fn hasArmAes() bool {
    switch (builtin.os.tag) {
        .linux => {
            const hw = std.os.linux.getauxval(16); // AT_HWCAP
            return hw & (1 << 3) != 0 and hw & (1 << 4) != 0;
        },
        .windows => return IsProcessorFeaturePresent(30) != 0,
        else => return false,
    }
}

extern "kernel32" fn IsProcessorFeaturePresent(feature: u32) callconv(.winapi) i32;

fn detect() Impl {
    if (kx.enabled and builtin.cpu.arch == .x86_64) {
        if (comptime extraX86(kx.features).len == 0) return .x86_avx2;
        if (hasX86(comptime extraX86(kx.features))) return .x86_avx2;
    }
    if (ka.enabled and builtin.cpu.arch == .aarch64) {
        if (comptime extraArm(ka.features) == 0) return .arm_aes;
        if (hasArmAes()) return .arm_aes;
    }
    return .soft;
}

/// The state of one AES-GCM key: the expanded key of the code for this
/// CPU, or the key for `std.crypto`.
pub const Gcm = struct {
    impl: Impl,
    key: [32]u8,
    key_len: u8,
    x86: if (kx.enabled) kx.Gcm else void,
    arm: if (ka.enabled) ka.Gcm else void,

    pub fn init(key: []const u8) Gcm {
        std.debug.assert(key.len == 16 or key.len == 32);
        var g: Gcm = .{ .impl = impl(), .key = @splat(0), .key_len = @intCast(key.len), .x86 = undefined, .arm = undefined };
        @memcpy(g.key[0..key.len], key);
        if (kx.enabled and g.impl == .x86_avx2) kx.init(&g.x86, key);
        if (ka.enabled and g.impl == .arm_aes) ka.init(&g.arm, key);
        return g;
    }

    /// Zeros the keys.
    pub fn deinit(g: *Gcm) void {
        std.crypto.secureZero(u8, std.mem.asBytes(g));
    }

    /// Encrypts `src` into `dst`, which has the same length, and gives
    /// the tag. `dst` and `src` are the same buffer or do not overlap.
    pub fn seal(g: *const Gcm, dst: []u8, tag: *[tag_len]u8, src: []const u8, ad: []const u8, nonce: *const [nonce_len]u8) void {
        g.sealExtra(dst, tag, src, "", ad, nonce);
    }

    /// The longest `extra` of `sealExtra`.
    pub const max_extra = 256;

    /// Encrypts the bytes of `src` and then of `extra` into `dst`, which
    /// has the length of the two, and gives the tag. `dst` and `src`
    /// start at the same place or do not overlap. A TLS record has its
    /// content in `src` and its content type and padding in `extra`, so
    /// the content goes into the record with no copy.
    pub fn sealExtra(g: *const Gcm, dst: []u8, tag: *[tag_len]u8, src: []const u8, extra: []const u8, ad: []const u8, nonce: *const [nonce_len]u8) void {
        std.debug.assert(dst.len == src.len + extra.len and extra.len <= max_extra);
        if (kx.enabled and g.impl == .x86_avx2) return kx.seal(&g.x86, dst, tag, src, extra, ad, nonce);
        if (ka.enabled and g.impl == .arm_aes) return ka.seal(&g.arm, dst, tag, src, extra, ad, nonce);
        if (src.ptr != dst.ptr) @memcpy(dst[0..src.len], src);
        @memcpy(dst[src.len..], extra);
        if (g.key_len == 16)
            soft.Aes128Gcm.encrypt(dst, tag, dst, ad, nonce.*, g.key[0..16].*)
        else
            soft.Aes256Gcm.encrypt(dst, tag, dst, ad, nonce.*, g.key);
    }

    /// Checks the tag and decrypts `src` into `dst`. A bad tag gives
    /// `error.AuthenticationFailed` and zeros `dst`.
    pub fn open(g: *const Gcm, dst: []u8, src: []const u8, tag: *const [tag_len]u8, ad: []const u8, nonce: *const [nonce_len]u8) error{AuthenticationFailed}!void {
        std.debug.assert(dst.len == src.len);
        if (kx.enabled and g.impl == .x86_avx2) {
            if (!kx.open(&g.x86, dst, src, tag, ad, nonce)) return error.AuthenticationFailed;
            return;
        }
        if (ka.enabled and g.impl == .arm_aes) {
            if (!ka.open(&g.arm, dst, src, tag, ad, nonce)) return error.AuthenticationFailed;
            return;
        }
        (if (g.key_len == 16)
            soft.Aes128Gcm.decrypt(dst, src, tag.*, ad, nonce.*, g.key[0..16].*)
        else
            soft.Aes256Gcm.decrypt(dst, src, tag.*, ad, nonce.*, g.key)) catch |e| {
            std.crypto.secureZero(u8, dst);
            return e;
        };
    }
};

/// ChaCha20-Poly1305 with the code for this CPU.
pub const ChaCha = struct {
    impl: Impl,
    key: [32]u8,

    pub fn init(key: *const [32]u8) ChaCha {
        return .{ .impl = impl(), .key = key.* };
    }

    pub fn deinit(c: *ChaCha) void {
        std.crypto.secureZero(u8, std.mem.asBytes(c));
    }

    pub const max_extra = 256;

    /// As `Gcm.sealExtra`.
    pub fn sealExtra(c: *const ChaCha, dst: []u8, tag: *[tag_len]u8, src: []const u8, extra: []const u8, ad: []const u8, nonce: *const [nonce_len]u8) void {
        std.debug.assert(dst.len == src.len + extra.len and extra.len <= max_extra);
        if (kx.enabled and c.impl == .x86_avx2) return kx.chacha.seal(&c.key, dst, tag, src, extra, ad, nonce);
        if (src.ptr != dst.ptr) @memcpy(dst[0..src.len], src);
        @memcpy(dst[src.len..], extra);
        std.crypto.aead.chacha_poly.ChaCha20Poly1305.encrypt(dst, tag, dst, ad, nonce.*, c.key);
    }

    pub fn seal(c: *const ChaCha, dst: []u8, tag: *[tag_len]u8, src: []const u8, ad: []const u8, nonce: *const [nonce_len]u8) void {
        c.sealExtra(dst, tag, src, "", ad, nonce);
    }

    /// As `Gcm.open`.
    pub fn open(c: *const ChaCha, dst: []u8, src: []const u8, tag: *const [tag_len]u8, ad: []const u8, nonce: *const [nonce_len]u8) error{AuthenticationFailed}!void {
        std.debug.assert(dst.len == src.len);
        if (kx.enabled and c.impl == .x86_avx2) {
            if (!kx.chacha.open(&c.key, dst, src, tag, ad, nonce)) return error.AuthenticationFailed;
            return;
        }
        std.crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(dst, src, tag.*, ad, nonce.*, c.key) catch |e| {
            std.crypto.secureZero(u8, dst);
            return e;
        };
    }
};

test "ChaCha20-Poly1305 for this CPU matches std.crypto" {
    const C = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
    var key: [32]u8 = undefined;
    var nonce: [12]u8 = undefined;
    var ad: [40]u8 = undefined;
    var m: [20000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xc4a);
    const r = prng.random();
    for (0..100) |_| {
        r.bytes(&key);
        r.bytes(&nonce);
        r.bytes(&ad);
        r.bytes(&m);
        const len = if (r.boolean()) r.uintLessThan(usize, 1100) else r.uintLessThan(usize, m.len + 1);
        const al = r.uintLessThan(usize, ad.len + 1);
        var want: [20000]u8 = undefined;
        var want_tag: [16]u8 = undefined;
        C.encrypt(want[0..len], &want_tag, m[0..len], ad[0..al], nonce, key);
        inline for (.{ Impl.soft, Impl.x86_avx2 }) |i| {
            if (available(i)) {
                force(i);
                defer force(.unknown);
                const c = ChaCha.init(&key);
                var got: [20000]u8 = undefined;
                var tag: [16]u8 = undefined;
                c.seal(got[0..len], &tag, m[0..len], ad[0..al], &nonce);
                try std.testing.expectEqualSlices(u8, want[0..len], got[0..len]);
                try std.testing.expectEqualSlices(u8, &want_tag, &tag);
                const xl = @min(r.uintLessThan(usize, len + 1), ChaCha.max_extra);
                c.sealExtra(got[0..len], &tag, m[0 .. len - xl], m[len - xl .. len], ad[0..al], &nonce);
                try std.testing.expectEqualSlices(u8, want[0..len], got[0..len]);
                try std.testing.expectEqualSlices(u8, &want_tag, &tag);
                try c.open(got[0..len], got[0..len], &tag, ad[0..al], &nonce);
                try std.testing.expectEqualSlices(u8, m[0..len], got[0..len]);
                tag[r.uintLessThan(usize, 16)] ^= @as(u8, 1) << r.int(u3);
                try std.testing.expectError(error.AuthenticationFailed, c.open(got[0..len], want[0..len], &tag, ad[0..al], &nonce));
                for (got[0..len]) |b| try std.testing.expectEqual(0, b);
            }
        }
    }
}

test "the code for this CPU matches std.crypto" {
    var key: [32]u8 = undefined;
    var nonce: [12]u8 = undefined;
    var ad: [40]u8 = undefined;
    var m: [20000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    for ([_]usize{ 16, 32 }) |kl| {
        for (0..100) |_| {
            r.bytes(&key);
            r.bytes(&nonce);
            r.bytes(&ad);
            r.bytes(&m);
            // Short lengths for the tails, and long ones past the carry
            // of the last byte of the count.
            const len = if (r.boolean()) r.uintLessThan(usize, 600) else r.uintLessThan(usize, m.len + 1);
            const al = r.uintLessThan(usize, ad.len + 1);
            var want: [20000]u8 = undefined;
            var want_tag: [16]u8 = undefined;
            if (kl == 16)
                soft.Aes128Gcm.encrypt(want[0..len], &want_tag, m[0..len], ad[0..al], nonce, key[0..16].*)
            else
                soft.Aes256Gcm.encrypt(want[0..len], &want_tag, m[0..len], ad[0..al], nonce, key);
            inline for (.{ Impl.soft, Impl.x86_avx2, Impl.arm_aes }) |i| {
                if (available(i)) {
                    force(i);
                    defer force(.unknown);
                    var g = Gcm.init(key[0..kl]);
                    var got: [20000]u8 = undefined;
                    var tag: [16]u8 = undefined;
                    g.seal(got[0..len], &tag, m[0..len], ad[0..al], &nonce);
                    try std.testing.expectEqualSlices(u8, want[0..len], got[0..len]);
                    try std.testing.expectEqualSlices(u8, &want_tag, &tag);
                    // In place.
                    var buf = m;
                    g.seal(buf[0..len], &tag, buf[0..len], ad[0..al], &nonce);
                    try std.testing.expectEqualSlices(u8, want[0..len], buf[0..len]);
                    try g.open(buf[0..len], buf[0..len], &tag, ad[0..al], &nonce);
                    try std.testing.expectEqualSlices(u8, m[0..len], buf[0..len]);
                    // The content and a tail in two parts.
                    const xl = @min(r.uintLessThan(usize, len + 1), Gcm.max_extra);
                    var two: [20000]u8 = undefined;
                    g.sealExtra(two[0..len], &tag, m[0 .. len - xl], m[len - xl .. len], ad[0..al], &nonce);
                    try std.testing.expectEqualSlices(u8, want[0..len], two[0..len]);
                    try std.testing.expectEqualSlices(u8, &want_tag, &tag);
                    var back: [20000]u8 = undefined;
                    try g.open(back[0..len], want[0..len], &tag, ad[0..al], &nonce);
                    try std.testing.expectEqualSlices(u8, m[0..len], back[0..len]);
                    tag[r.uintLessThan(usize, 16)] ^= @as(u8, 1) << r.int(u3);
                    try std.testing.expectError(error.AuthenticationFailed, g.open(back[0..len], want[0..len], &tag, ad[0..al], &nonce));
                    for (back[0..len]) |b| try std.testing.expectEqual(0, b);
                }
            }
        }
    }
}

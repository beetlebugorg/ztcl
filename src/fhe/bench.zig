//! The measurements of docs/dev/fhe.md.
//!
//!   zig build fhe-bench -Doptimize=ReleaseFast -- [ntt] [ckks13] [ckks14]
//!       [ckks15] [ckks16] [tfhe] [dot] [logreg]
//!
//! With no argument each part runs. Each time is the CPU time of the
//! thread, and the least of the runs of one operation.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const fhe = @import("fhe.zig");
const ntt = fhe.ntt;
const ckks = fhe.ckks;
const tfhe = fhe.tfhe;

fn nowNs() u64 {
    switch (builtin.os.tag) {
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.THREAD_CPUTIME_ID, &ts);
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        },
        else => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.THREAD_CPUTIME_ID, &ts);
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        },
    }
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn mb(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

/// An allocator that counts the live bytes and their peak.
const Counting = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(c: *Counting) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn note(c: *Counting, add: usize, sub: usize) void {
        c.live = c.live + add - sub;
        c.peak = @max(c.peak, c.live);
    }
    fn alloc(p: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(p));
        const r = c.child.rawAlloc(len, a, ra) orelse return null;
        c.note(len, 0);
        return r;
    }
    fn resize(p: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(p));
        if (!c.child.rawResize(m, a, new_len, ra)) return false;
        c.note(new_len, m.len);
        return true;
    }
    fn remap(p: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(p));
        const r = c.child.rawRemap(m, a, new_len, ra) orelse return null;
        c.note(new_len, m.len);
        return r;
    }
    fn free(p: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const c: *Counting = @ptrCast(@alignCast(p));
        c.child.rawFree(m, a, ra);
        c.note(0, m.len);
    }
};

fn benchNtt(gpa: std.mem.Allocator) !void {
    std.debug.print("\n## NTT (one prime; microseconds for one transform)\n", .{});
    std.debug.print("n\tbits\tforward\tinverse\tforward-vec\tinverse-vec\n", .{});
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    for ([_]u6{ 50, 60 }) |bits| {
        var log_n: u6 = 10;
        while (log_n <= 16) : (log_n += 1) {
            const n = @as(usize, 1) << log_n;
            const q = ntt.primeBelow(@as(u64, 1) << bits, n, &.{}).?;
            var t = try ntt.Table.init(gpa, q, n);
            defer t.deinit(gpa);
            const a = try gpa.alloc(u64, n);
            defer gpa.free(a);
            for (a) |*x| x.* = r.uintLessThan(u64, q);
            var best: [4]u64 = @splat(std.math.maxInt(u64));
            const reps: usize = @max(8, (1 << 22) / n);
            for (0..5) |_| {
                inline for (0..4) |kind| {
                    const t0 = nowNs();
                    for (0..reps) |_| switch (kind) {
                        0 => t.forwardScalar(a),
                        1 => t.inverseScalar(a),
                        2 => t.forwardVec(a),
                        3 => t.inverseVec(a),
                        else => unreachable,
                    };
                    best[kind] = @min(best[kind], (nowNs() - t0) / reps);
                }
            }
            std.debug.print("{d}\t{d}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\n", .{ n, bits, ms(best[0]) * 1e3, ms(best[1]) * 1e3, ms(best[2]) * 1e3, ms(best[3]) * 1e3 });
        }
    }
}

fn benchCkks(child: std.mem.Allocator, params: ckks.Params, reps: usize) !void {
    var counting: Counting = .{ .child = child };
    const gpa = counting.allocator();
    std.debug.print("\n## CKKS n = 2^{d}, QP = {d} bits ({d} + {d} x {d} + {d}), limit of the standard {d} bits\n", .{ params.log_n, params.totalBits(), params.first_bits, params.levels, params.scale_bits, params.special_bits, ckks.Params.maxBits(params.log_n).? });
    var prng = std.Random.DefaultCsprng.init(@splat(7));
    const rng = prng.random();
    var t0 = nowNs();
    const ctx = try ckks.Context.init(gpa, params);
    defer ctx.deinit();
    std.debug.print("context\t{d:.1} ms\t{d:.1} MB\n", .{ ms(nowNs() - t0), mb(counting.live) });
    t0 = nowNs();
    const before = counting.live;
    var keys = try ckks.keygen(ctx, rng, &.{1});
    defer keys.deinit(ctx);
    std.debug.print("keygen (secret, public, relin, 1 Galois)\t{d:.1} ms\n", .{ms(nowNs() - t0)});
    std.debug.print("memory: secret {d:.2} MB, public {d:.2} MB, relin {d:.2} MB, each Galois key {d:.2} MB, key set {d:.2} MB\n", .{ mb(keys.secretBytes()), mb(keys.publicBytes()), mb(keys.relin.bytes()), mb(keys.galoisBytes()), mb(counting.live - before) });

    const x = try gpa.alloc(f64, ctx.slots);
    defer gpa.free(x);
    for (x, 0..) |*v, i| v.* = @sin(@as(f64, @floatFromInt(i)));
    const top = ctx.top();
    var best: [10]u64 = @splat(std.math.maxInt(u64));
    var worst_err: f64 = 0;
    for (0..reps) |_| {
        t0 = nowNs();
        const pt = try ctx.encode(x, top, ctx.scales[top]);
        best[0] = @min(best[0], nowNs() - t0);
        defer pt.deinit(ctx);
        t0 = nowNs();
        const ct = try ckks.encrypt(ctx, &keys, rng, pt);
        best[1] = @min(best[1], nowNs() - t0);
        defer ct.deinit(ctx);
        t0 = nowNs();
        const d = try ckks.decrypt(ctx, &keys, ct);
        best[2] = @min(best[2], nowNs() - t0);
        gpa.free(d);
        t0 = nowNs();
        const s = try ckks.addRaw(ctx, ct, ct);
        best[3] = @min(best[3], nowNs() - t0);
        var s2 = s;
        t0 = nowNs();
        try ckks.addAssign(ctx, &s2, ct);
        best[9] = @min(best[9], nowNs() - t0);
        s.deinit(ctx);
        t0 = nowNs();
        var p = try ckks.mulRelin(ctx, &keys, ct, ct);
        best[4] = @min(best[4], nowNs() - t0);
        defer p.deinit(ctx);
        t0 = nowNs();
        try ckks.rescale(ctx, &p);
        best[5] = @min(best[5], nowNs() - t0);
        t0 = nowNs();
        const rot = try ckks.rotate(ctx, &keys, ct, 1);
        best[6] = @min(best[6], nowNs() - t0);
        rot.deinit(ctx);
        t0 = nowNs();
        const pp = try ckks.mulPlain(ctx, ct, x);
        best[7] = @min(best[7], nowNs() - t0);
        pp.deinit(ctx);
        t0 = nowNs();
        const dp = try ckks.decrypt(ctx, &keys, p);
        best[8] = @min(best[8], nowNs() - t0);
        defer gpa.free(dp);
        for (x, dp) |v, g| worst_err = @max(worst_err, @abs(v * v - g));
    }
    const names = [_][]const u8{ "encode", "encrypt", "decrypt (top level)", "add (new ciphertext)", "multiply + relinearize", "rescale", "rotate", "multiply by plain + rescale (with encode)", "decrypt (one level down)", "add (in place)" };
    for (names, best) |name, b| std.debug.print("{s}\t{d:.3} ms\n", .{ name, ms(b) });
    std.debug.print("largest error of x * x in {d} slots\t{e:.2}\n", .{ ctx.slots, worst_err });
    std.debug.print("ciphertext at the top level\t{d:.2} MB\npeak memory\t{d:.1} MB\n", .{ mb(2 * (top + 1) * ctx.n * 8), mb(counting.peak) });
}

fn benchTfhe(child: std.mem.Allocator) !void {
    var counting: Counting = .{ .child = child };
    const gpa = counting.allocator();
    const p = tfhe.lib_128;
    std.debug.print("\n## TFHE n = {d}, N = {d}, l = {d}, Bg = 2^{d}, key switch t = {d}, base 2^{d}\n", .{ p.n, p.big_n, p.bk_l, p.bk_bg_bit, p.ks_t, p.ks_base_bit });
    const ctx = try tfhe.Context.init(gpa, p);
    defer ctx.deinit();
    var prng = std.Random.DefaultCsprng.init(@splat(9));
    const rng = prng.random();
    var t0 = nowNs();
    const sk, const ck = try tfhe.keygen(ctx, rng);
    defer sk.deinit(gpa);
    defer ck.deinit(gpa);
    std.debug.print("keygen\t{d:.0} ms\n", .{ms(nowNs() - t0)});
    std.debug.print("memory: bootstrap key {d:.1} MB, key-switch key {d:.1} MB, cloud key {d:.1} MB, ciphertext {d} bytes\n", .{ mb(ck.bk.len * 8), mb(ck.ks.len * 4), mb(ck.bytes()), ctx.lweLen() * 4 });
    const len = ctx.lweLen();
    const buf = try gpa.alloc(u32, 3 * len);
    defer gpa.free(buf);
    const a = buf[0..len];
    const b = buf[len .. 2 * len];
    const out = buf[2 * len ..];
    var best: u64 = std.math.maxInt(u64);
    var total: u64 = 0;
    var wrong: usize = 0;
    const gates = 200;
    for (0..gates) |i| {
        const x = i & 1 != 0;
        const y = i & 2 != 0;
        tfhe.encryptBit(ctx, &sk, rng, x, a);
        tfhe.encryptBit(ctx, &sk, rng, y, b);
        t0 = nowNs();
        try tfhe.gate(ctx, &ck, .nand, a, b, out);
        const dt = nowNs() - t0;
        best = @min(best, dt);
        total += dt;
        if (tfhe.decryptBit(&sk, out) != !(x and y)) wrong += 1;
    }
    std.debug.print("NAND gate with bootstrap and key switch\tleast {d:.2} ms\tmean {d:.2} ms\t{d} of {d} wrong\n", .{ ms(best), ms(total / gates), wrong, gates });
}

fn benchDot(child: std.mem.Allocator) !void {
    var counting: Counting = .{ .child = child };
    const gpa = counting.allocator();
    const count = 4096;
    std.debug.print("\n## The dot product of {d} encrypted values with {d} encrypted values, CKKS n = 2^13\n", .{ count, count });
    const ctx = try ckks.Context.init(gpa, ckks.set_13);
    defer ctx.deinit();
    var prng = std.Random.DefaultCsprng.init(@splat(11));
    const rng = prng.random();
    var rot: [16]i64 = undefined;
    var t0 = nowNs();
    var keys = try ckks.keygen(ctx, rng, ckks.sumRotations(count, &rot));
    defer keys.deinit(ctx);
    const t_keys = nowNs() - t0;
    var x: [count]f64 = undefined;
    var y: [count]f64 = undefined;
    var want: f64 = 0;
    for (&x, &y) |*a, *b| {
        a.* = rng.float(f64) * 2 - 1;
        b.* = rng.float(f64) * 2 - 1;
        want += a.* * b.*;
    }
    t0 = nowNs();
    const cx = try ckks.encryptValues(ctx, &keys, rng, &x);
    defer cx.deinit(ctx);
    const cy = try ckks.encryptValues(ctx, &keys, rng, &y);
    defer cy.deinit(ctx);
    const t_enc = nowNs() - t0;
    var best: u64 = std.math.maxInt(u64);
    var got: f64 = 0;
    for (0..5) |_| {
        t0 = nowNs();
        const r = try ckks.dot(ctx, &keys, cx, cy, count);
        best = @min(best, nowNs() - t0);
        defer r.deinit(ctx);
        const d = try ckks.decrypt(ctx, &keys, r);
        got = d[0];
        gpa.free(d);
    }
    std.debug.print("keygen with 12 Galois keys\t{d:.1} ms\nencode + encrypt, 2 vectors\t{d:.2} ms\ndot product (1 multiply, 1 rescale, 12 rotations)\t{d:.2} ms\n", .{ ms(t_keys), ms(t_enc), ms(best) });
    std.debug.print("plain result {d:.9}, decrypted {d:.9}, error {e:.2}\nGalois keys {d:.1} MB, peak memory {d:.1} MB\n", .{ want, got, @abs(want - got), mb(keys.galoisBytes()), mb(counting.peak) });
}

fn benchLogreg(child: std.mem.Allocator) !void {
    var counting: Counting = .{ .child = child };
    const gpa = counting.allocator();
    const count = 1024;
    std.debug.print("\n## The logistic regression score of {d} encrypted features with a plain model, CKKS n = 2^14\n", .{count});
    const ctx = try ckks.Context.init(gpa, ckks.set_14);
    defer ctx.deinit();
    var prng = std.Random.DefaultCsprng.init(@splat(13));
    const rng = prng.random();
    var rot: [16]i64 = undefined;
    var t0 = nowNs();
    var keys = try ckks.keygen(ctx, rng, ckks.sumRotations(count, &rot));
    defer keys.deinit(ctx);
    const t_keys = nowNs() - t0;
    var x: [count]f64 = undefined;
    var w: [count]f64 = undefined;
    const bias = 0.3;
    var y: f64 = bias;
    for (&x, &w) |*a, *b| {
        a.* = rng.float(f64) * 2 - 1;
        // The dot product stays near the middle of [-8, 8].
        b.* = (rng.float(f64) * 2 - 1) * 0.1;
        y += a.* * b.*;
    }
    t0 = nowNs();
    const cx = try ckks.encryptValues(ctx, &keys, rng, &x);
    defer cx.deinit(ctx);
    const t_enc = nowNs() - t0;
    var best: u64 = std.math.maxInt(u64);
    var got: f64 = 0;
    var level: usize = 0;
    for (0..3) |_| {
        t0 = nowNs();
        const r = try fhe.logisticScore(ctx, &keys, cx, &w, bias, count);
        best = @min(best, nowNs() - t0);
        defer r.deinit(ctx);
        level = r.level;
        const d = try ckks.decrypt(ctx, &keys, r);
        got = d[0];
        gpa.free(d);
    }
    const poly = fhe.sigmoid3Plain(y);
    const exact = 1.0 / (1.0 + @exp(-y));
    std.debug.print("keygen with 10 Galois keys\t{d:.1} ms\nencode + encrypt\t{d:.2} ms\nscore (1 plain multiply, 10 rotations, 2 multiplies, 2 scalar multiplies)\t{d:.2} ms\n", .{ ms(t_keys), ms(t_enc), ms(best) });
    std.debug.print("w.x + b = {d:.6}; plain polynomial {d:.9}, decrypted {d:.9}, error {e:.2}; logistic function {d:.6}\nresult level {d} of {d}, Galois keys {d:.1} MB, peak memory {d:.1} MB\n", .{ y, poly, got, @abs(poly - got), exact, level, ctx.top(), mb(keys.galoisBytes()), mb(counting.peak) });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const all = args.len < 2;
    const want = struct {
        fn f(list: []const []const u8, on: bool, name: []const u8) bool {
            if (on) return true;
            for (list[1..]) |a| if (std.mem.eql(u8, a, name)) return true;
            return false;
        }
    }.f;
    std.debug.print("vector code: {s}; NTT in use: {s}; build {t}\n", .{ if (ntt.has_vec) "4 x 64 bits" else "none", if (ntt.use_vec) "vector" else "scalar", builtin.mode });
    if (want(args, all, "ntt")) try benchNtt(gpa);
    if (want(args, all, "ckks13")) try benchCkks(gpa, ckks.set_13, 10);
    if (want(args, all, "ckks14")) try benchCkks(gpa, ckks.set_14, 5);
    if (want(args, all, "ckks15")) try benchCkks(gpa, ckks.set_15, 3);
    if (want(args, all, "ckks16")) try benchCkks(gpa, ckks.set_16, 2);
    if (want(args, all, "tfhe")) try benchTfhe(gpa);
    if (want(args, all, "dot")) try benchDot(gpa);
    if (want(args, all, "logreg")) try benchLogreg(gpa);
}

//! The speed of the TLS record layer: `Protection.seal` and
//! `Protection.open` of `record.zig` on records of 16,384 bytes of
//! application data, for each suite. It prints MB/s (10^6 bytes per
//! second of plaintext), the best of 5 runs of about 0.5 s each. The
//! clock is the CPU time of the thread, as `openssl speed` measures
//! by default, so other jobs on the machine change the numbers less.
//!
//!   zig build tls-bench [-Dcpu=baseline]
//!
//! Then it prints the speed of AES-GCM of `aead.zig` alone, on 16,384
//! bytes in place.
//!
//! `tools/tls-bench.sh` runs it next to `openssl speed -evp` for the
//! same AEADs.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const record = @import("record.zig");
const aead = @import("aead.zig");

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.THREAD_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    const secret: [48]u8 = @splat(7);
    var plain: [record.max_plaintext]u8 = @splat(0x61);
    // A batch of 8 records between two reads of the clock.
    const batch = 8;
    var rec_buf: [batch][record.max_record]u8 = undefined;
    var recs: [batch][]u8 = undefined;
    var out: [record.max_ciphertext]u8 = undefined;
    inline for (.{ record.Suite.aes_128_gcm_sha256, record.Suite.aes_256_gcm_sha384, record.Suite.chacha20_poly1305_sha256 }) |suite| {
        var best_seal: f64 = 0;
        var best_open: f64 = 0;
        var best_place: f64 = 0;
        for (0..5) |_| {
            var w = record.Protection.init(suite, secret[0..suite.hashLen()]);
            var r = record.Protection.init(suite, secret[0..suite.hashLen()]);
            var w2 = record.Protection.init(suite, secret[0..suite.hashLen()]);
            var r2 = record.Protection.init(suite, secret[0..suite.hashLen()]);
            var n: usize = 0;
            var t_seal: u64 = 0;
            var t_open: u64 = 0;
            var t_place: u64 = 0;
            while (t_seal + t_open + t_place < 750 * std.time.ns_per_ms) : (n += batch) {
                const a = nowNs();
                for (&recs, &rec_buf) |*rec, *buf| rec.* = try w.seal(buf, .application_data, &plain, 0);
                const b = nowNs();
                for (recs) |rec| {
                    const got = try r.open(&out, rec);
                    std.mem.doNotOptimizeAway(got.data.len);
                }
                const c = nowNs();
                for (&recs, &rec_buf) |*rec, *buf| rec.* = try w2.seal(buf, .application_data, &plain, 0);
                const d = nowNs();
                for (recs) |rec| {
                    const got = try r2.openInPlace(rec);
                    std.mem.doNotOptimizeAway(got.data.len);
                }
                const e = nowNs();
                t_seal += b - a;
                t_open += c - b;
                t_place += e - d;
            }
            const bytes: f64 = @floatFromInt(n * plain.len);
            best_seal = @max(best_seal, bytes / @as(f64, @floatFromInt(t_seal)) * 1000);
            best_open = @max(best_open, bytes / @as(f64, @floatFromInt(t_open)) * 1000);
            best_place = @max(best_place, bytes / @as(f64, @floatFromInt(t_place)) * 1000);
        }
        std.debug.print("{t}\tseal {d:.0} MB/s\topen {d:.0} MB/s\topen in place {d:.0} MB/s\n", .{ suite, best_seal, best_open, best_place });
    }
    // The AEAD alone, as `openssl speed -evp` measures it: 16,384 bytes
    // in place, no record header.
    std.debug.print("aead.zig code: {t}\n", .{aead.impl()});
    inline for (.{ 16, 32 }) |kl| {
        const key: [kl]u8 = @splat(9);
        const g = aead.Gcm.init(&key);
        const nonce: [12]u8 = @splat(1);
        var bufs: [batch][record.max_plaintext]u8 = @splat(plain);
        var tags: [batch][16]u8 = undefined;
        var best_seal: f64 = 0;
        var best_open: f64 = 0;
        for (0..5) |_| {
            var n: usize = 0;
            var t_seal: u64 = 0;
            var t_open: u64 = 0;
            while (t_seal + t_open < 500 * std.time.ns_per_ms) : (n += batch) {
                const a = nowNs();
                for (&bufs, &tags) |*m, *t| g.seal(m, t, m, "", &nonce);
                const b = nowNs();
                for (&bufs, &tags) |*m, *t| try g.open(m, m, t, "", &nonce);
                const c = nowNs();
                t_seal += b - a;
                t_open += c - b;
            }
            const bytes: f64 = @floatFromInt(n * plain.len);
            best_seal = @max(best_seal, bytes / @as(f64, @floatFromInt(t_seal)) * 1000);
            best_open = @max(best_open, bytes / @as(f64, @floatFromInt(t_open)) * 1000);
        }
        std.debug.print("AES-{d}-GCM alone\tseal {d:.0} MB/s\topen {d:.0} MB/s\n", .{ kl * 8, best_seal, best_open });
    }
    // ChaCha20-Poly1305 alone for small and large messages: a small one
    // shows the fixed cost of a message (the key of Poly1305, the tail).
    const cc = aead.ChaCha.init(&@as([32]u8, @splat(9)));
    inline for (.{ 64, 256, 1350, 16384 }) |len| {
        var m: [len]u8 = @splat(7);
        var tag: [16]u8 = undefined;
        const nonce: [12]u8 = @splat(1);
        var best: u64 = std.math.maxInt(u64);
        for (0..5) |_| {
            const reps = 4_000_000 / len + 100;
            const a = nowNs();
            for (0..reps) |_| {
                cc.seal(&m, &tag, &m, "", &nonce);
                std.mem.doNotOptimizeAway(&tag);
            }
            best = @min(best, (nowNs() - a) / reps);
        }
        std.debug.print("ChaCha20-Poly1305 alone, {d} bytes\tseal {d} ns\t{d:.0} MB/s\n", .{ len, best, @as(f64, len) * 1000 / @as(f64, @floatFromInt(@max(best, 1))) });
    }
}

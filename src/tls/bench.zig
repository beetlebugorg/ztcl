//! The speed of the TLS record layer: `Protection.seal` and
//! `Protection.open` of `record.zig` on records of 16,384 bytes of
//! application data, for each suite. It prints MB/s (10^6 bytes per
//! second of plaintext), the best of 5 runs of about 0.5 s each.
//!
//!   zig build tls-bench [-Dcpu=baseline]
//!
//! `tools/tls-bench.sh` runs it next to `openssl speed -evp` for the
//! same AEADs.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const record = @import("record.zig");

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    const secret: [48]u8 = @splat(7);
    var plain: [record.max_plaintext]u8 = @splat(0x61);
    var rec_buf: [record.max_record]u8 = undefined;
    var out: [record.max_ciphertext]u8 = undefined;
    inline for (.{ record.Suite.aes_128_gcm_sha256, record.Suite.aes_256_gcm_sha384, record.Suite.chacha20_poly1305_sha256 }) |suite| {
        var best_seal: f64 = 0;
        var best_open: f64 = 0;
        for (0..5) |_| {
            var w = record.Protection.init(suite, secret[0..suite.hashLen()]);
            var r = record.Protection.init(suite, secret[0..suite.hashLen()]);
            var n: usize = 0;
            var t_seal: u64 = 0;
            var t_open: u64 = 0;
            while (t_seal + t_open < 500 * std.time.ns_per_ms) : (n += 1) {
                const a = nowNs();
                const rec = try w.seal(&rec_buf, .application_data, &plain, 0);
                const b = nowNs();
                const got = try r.open(&out, rec);
                const c = nowNs();
                std.mem.doNotOptimizeAway(got.data.len);
                t_seal += b - a;
                t_open += c - b;
            }
            const bytes: f64 = @floatFromInt(n * plain.len);
            best_seal = @max(best_seal, bytes / @as(f64, @floatFromInt(t_seal)) * 1000);
            best_open = @max(best_open, bytes / @as(f64, @floatFromInt(t_open)) * 1000);
        }
        std.debug.print("{t}\tseal {d:.0} MB/s\topen {d:.0} MB/s\n", .{ suite, best_seal, best_open });
    }
}

//! The fuzz run of `hpack.zig`.
//!
//!   zig build hpack-fuzz -- --seconds N [--seed S]
//!
//! Each round encodes random fields with a random table size and
//! Huffman mode, decodes the block, and checks the fields and the two
//! tables. It also decodes random bytes and random changes of a good
//! block, which must end with a field, the end, or an error, and never
//! with a crash. ReleaseSafe checks each bound and each integer.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const hpack = @import("hpack.zig");
const tables = @import("hpack_tables.zig");

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn drain(b: *hpack.Block) void {
    while (true) {
        const f = b.next() catch return;
        if (f == null) return;
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var seconds: u64 = 10;
    var seed: u64 = 1;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--seconds")) seconds = try std.fmt.parseInt(u64, args[i + 1], 10) else if (std.mem.eql(u8, args[i], "--seed")) seed = try std.fmt.parseInt(u64, args[i + 1], 10) else return error.BadOption;
    }
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const end = nowNs() + seconds * std.time.ns_per_s;
    var rounds: usize = 0;
    var fields_done: usize = 0;
    while (nowNs() < end) {
        const cap = r.uintLessThan(usize, 4097);
        var e = try hpack.Encoder.init(gpa, cap);
        defer e.deinit(gpa);
        var d = try hpack.Decoder.init(gpa, cap, 1 << 20);
        defer d.deinit(gpa);
        var junk = try hpack.Decoder.init(gpa, cap, r.uintLessThan(usize, 8192));
        defer junk.deinit(gpa);
        var strings: [16][64]u8 = undefined;
        for (&strings) |*s| r.bytes(s);
        for (0..200) |_| {
            if (r.uintLessThan(u8, 20) == 0) e.setMax(r.uintLessThan(usize, cap + 1));
            var fields: [24]hpack.Field = undefined;
            const nf = r.uintLessThan(usize, fields.len + 1);
            for (fields[0..nf]) |*f| {
                f.* = switch (r.uintLessThan(u8, 4)) {
                    0 => tables.static[r.uintLessThan(usize, 61)],
                    1 => .{ .name = tables.static[r.uintLessThan(usize, 61)].name, .value = strings[r.uintLessThan(usize, 16)][0..r.uintLessThan(usize, 65)] },
                    else => .{ .name = strings[r.uintLessThan(usize, 16)][0 .. r.uintLessThan(usize, 64) + 1], .value = strings[r.uintLessThan(usize, 16)][0..r.uintLessThan(usize, 65)] },
                };
            }
            e.huffman = r.enumValue(hpack.Huffman);
            var out: [8192]u8 = undefined;
            const n = try e.encode(&out, fields[0..nf]);
            var scratch: [256]u8 = undefined;
            var b = d.block(out[0..n], &scratch);
            for (fields[0..nf]) |f| {
                const got = (try b.next()) orelse return error.Short;
                if (!std.mem.eql(u8, f.name, got.name) or !std.mem.eql(u8, f.value, got.value)) return error.Mismatch;
            }
            if (try b.next() != null) return error.Long;
            if (e.table.size != d.table.size or e.table.count != d.table.count) return error.TableMismatch;
            fields_done += nf;
            // A change of a good block, then random bytes.
            if (n > 0) out[r.uintLessThan(usize, n)] ^= @as(u8, 1) << r.int(u3);
            var jb = junk.block(out[0..n], scratch[0..r.uintLessThan(usize, scratch.len + 1)]);
            drain(&jb);
            const jn = r.uintLessThan(usize, 128);
            r.bytes(out[0..jn]);
            jb = junk.block(out[0..jn], &scratch);
            drain(&jb);
        }
        rounds += 1;
    }
    std.debug.print("hpack fuzz: {d} rounds, {d} fields, seed {d}, no failure\n", .{ rounds, fields_done, seed });
}

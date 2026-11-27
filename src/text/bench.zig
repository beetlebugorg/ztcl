//! Prints the speed of the segmenters of seg.zig on UTF-8 files, in MB/s
//! of input, the best of 5 runs. The clock is the CPU time of the
//! thread. bench/text/run.sh writes the files and runs ICU on the same
//! files.
//!
//!   zig build text-bench -- FILE ...
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const seg = @import("seg.zig");

fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.THREAD_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn graphemes(s: []const u8) usize {
    return seg.count(s);
}

fn graphemeWalk(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) i = seg.graphemeEnd(s, i);
    return n;
}

fn words(s: []const u8) usize {
    var w: seg.Words = .{ .s = s };
    var n: usize = 0;
    while (w.next()) |_| n += 1;
    return n;
}

fn sentences(s: []const u8) usize {
    var z: seg.Sentences = .{ .s = s };
    var n: usize = 0;
    while (z.next()) |_| n += 1;
    return n;
}

fn width(s: []const u8) usize {
    return seg.width(s, .narrow);
}

fn run(name: []const u8, kind: []const u8, s: []const u8, f: *const fn ([]const u8) usize) void {
    var best: u64 = std.math.maxInt(u64);
    var n: usize = 0;
    for (0..5) |_| {
        const t0 = now();
        n = f(s);
        std.mem.doNotOptimizeAway(n);
        best = @min(best, now() - t0);
    }
    const mbs = @as(f64, @floatFromInt(s.len)) / (@as(f64, @floatFromInt(@max(best, 1))) / 1e9) / 1e6;
    std.debug.print("ztcl\t{s}\t{s}\t{d}\t{d:.1}\n", .{ name, kind, n, mbs });
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    for (args[1..]) |path| {
        const s = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited);
        const name = std.fs.path.stem(path);
        run(name, "graphemes", s, graphemes);
        run(name, "grapheme-walk", s, graphemeWalk);
        run(name, "words", s, words);
        run(name, "sentences", s, sentences);
        run(name, "width", s, width);
    }
}

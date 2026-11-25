//! The native side of `tools/point-rt-diff.mjs`.
//!
//! It reads records of four f64 from stdin (x, y, z, and the seed in
//! the low 32 bits of the fourth) and writes, for each record, the
//! outputs of the runtime functions of point procs as f64, in the order
//! of `tools/point-rt-diff.mjs`. It calls the functions of `point.zig`
//! and `noise.zig` that `src/point_rt.zig` calls.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl");
const point = tcl.point;

pub const outputs = 13 + 4 + 2 + 7;

fn eval(rec: [4]f64, out: *[outputs]f64) void {
    const x = rec[0];
    const y = rec[1];
    const z = rec[2];
    const seed: u32 = @truncate(@as(u64, @bitCast(rec[3])));
    var k: usize = 0;
    inline for (.{ .acos, .asin, .atan, .cos, .cosh, .exp, .log, .log10, .sin, .sinh, .tan, .tanh }) |f| {
        out[k] = point.scalar1(f, x);
        k += 1;
    }
    out[k] = @round(x);
    k += 1;
    inline for (.{ .atan2, .fmod, .hypot, .pow }) |f| {
        out[k] = point.scalar2(0, f, x, y);
        k += 1;
    }
    out[k] = point.clamp(x, y, z);
    out[k + 1] = tcl.noise.noise3Seed(seed, x, y, z);
    k += 2;
    // `bound` for one point: width input z, and the outputs in the
    // order of point.Out.
    var cols = [7]f64{ x, y, z, y, x, y, z };
    var width = [1]f64{z};
    var pts: point.Points = .{ .len = 1 };
    pts.in[@intFromEnum(point.Field.width)] = &width;
    for (&pts.out, &cols) |*o, *c| o.* = @as(*[1]f64, c);
    point.bound(&pts);
    for (cols) |c| {
        out[k] = c;
        k += 1;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var in_buf: [1 << 16]u8 = undefined;
    var out_buf: [1 << 16]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buf);
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const r = &stdin.interface;
    const wr = &stdout.interface;
    while (true) {
        var rec: [4]f64 = undefined;
        r.readSliceAll(std.mem.asBytes(&rec)) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        var out: [outputs]f64 = undefined;
        eval(rec, &out);
        try wr.writeAll(std.mem.asBytes(&out));
    }
    try wr.flush();
}

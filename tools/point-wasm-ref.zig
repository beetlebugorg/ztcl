//! The native side of `tools/point-wasm-diff.mjs`.
//!
//!   point-wasm-ref FILE PROC IN.bin N SEED IN_MASK OUT_MASK
//!
//! IN.bin has 11 input columns of N f64 in the order of `point.Field`,
//! N feature bytes, and 7 output columns of N f64 with the start values,
//! in the order of `point.Out`. A column is present when its bit of
//! IN_MASK or OUT_MASK is set and, for an output, when the proc writes
//! it. The tool runs `Program.run` and `point.runSlow` on copies of the
//! points and exits with 3 when their bits differ. Then it writes the
//! outputs of `Program.run` to stdout: one line of 16 hex digits for
//! each value, column after column, then the line `slow-skipped K`
//! (the points where the slow path gave a Tcl error), and last the
//! line `steps S`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl");
const point = tcl.point;

const nf = @typeInfo(point.Field).@"enum".fields.len;
const no = @typeInfo(point.Out).@"enum".fields.len;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 8) {
        std.debug.print("usage: point-wasm-ref FILE PROC IN.bin N SEED IN_MASK OUT_MASK\n", .{});
        return 2;
    }
    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[1], a, .limited(1 << 24));
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, args[3], a, .limited(1 << 30));
    const n = try std.fmt.parseInt(usize, args[4], 10);
    const seed = try std.fmt.parseInt(u32, args[5], 10);
    const in_mask = try std.fmt.parseInt(u32, args[6], 10);
    const out_mask = try std.fmt.parseInt(u32, args[7], 10);
    if (raw.len != n * 8 * (nf + no) + n) return error.BadInput;

    var it: tcl.Interp = undefined;
    try it.init(init.gpa);
    defer it.deinit();
    var state: point.State = .{};
    try point.install(&it, &state);
    _ = it.eval(text) catch {
        std.debug.print("{s}\n", .{try it.str(it.result)});
        return 1;
    };
    const prog = state.program(args[2]) orelse return error.NoProc;
    const writes = tcl.point_wasm.outputs(prog);

    var fields: [nf][]f64 = undefined;
    for (&fields, 0..) |*c, k| {
        c.* = try a.alloc(f64, n);
        @memcpy(std.mem.sliceAsBytes(c.*), raw[k * n * 8 ..][0 .. n * 8]);
    }
    const feat = raw[nf * n * 8 ..][0..n];
    const outs_at = nf * n * 8 + n;
    var runs: [2][no][]f64 = undefined;
    for (&runs) |*outs| for (outs, 0..) |*c, k| {
        c.* = try a.alloc(f64, n);
        @memcpy(std.mem.sliceAsBytes(c.*), raw[outs_at + k * n * 8 ..][0 .. n * 8]);
    };
    var pts: [2]point.Points = undefined;
    for (&pts, &runs) |*p, *outs| {
        p.* = .{ .len = n, .seed = seed };
        for (0..nf) |k| {
            if (in_mask & (@as(u32, 1) << @intCast(k)) == 0) continue;
            if (k == @intFromEnum(point.Field.feature)) p.feature = feat else p.in[k] = fields[k];
        }
        for (0..no) |k| {
            if (out_mask & (@as(u32, 1) << @intCast(k)) != 0 and writes[k]) p.out[k] = outs[k];
        }
    }
    prog.run(&pts[0], try a.alloc(f64, prog.scratchLen()));
    // The slow path runs one point at a time. A point where Tcl gives an
    // error (a NaN or an integer that is too large) has no result on the
    // slow path, and only Program.run checks it.
    var failed = try a.alloc(bool, n);
    var skipped: usize = 0;
    for (0..n) |i| {
        var one = pts[1];
        one.len = 1;
        if (one.feature) |f| one.feature = f[i..][0..1];
        for (&one.in) |*c| if (c.*) |col| {
            c.* = col[i..][0..1];
        };
        for (&one.out) |*c| if (c.*) |col| {
            c.* = col[i..][0..1];
        };
        failed[i] = false;
        point.runSlow(&it, args[2], &one) catch {
            failed[i] = true;
            skipped += 1;
        };
    }
    for (0..no) |k| {
        for (runs[0][k], runs[1][k], 0..) |x, y, i| {
            if (failed[i]) continue;
            if (@as(u64, @bitCast(x)) != @as(u64, @bitCast(y))) {
                std.debug.print("Program.run and runSlow differ: column {d} point {d}: {x} {x}\n", .{ k, i, @as(u64, @bitCast(x)), @as(u64, @bitCast(y)) });
                return 3;
            }
        }
    }
    var buf: [1 << 16]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    for (0..no) |k| {
        if (pts[0].out[k] == null) continue;
        for (runs[0][k]) |v| try out.print("{x:0>16}\n", .{@as(u64, @bitCast(v))});
    }
    try out.print("slow-skipped {d}\n", .{skipped});
    try out.print("steps {d}\n", .{prog.setup.len + (n + point.block - 1) / point.block * prog.ops.len});
    try out.flush();
    return 0;
}

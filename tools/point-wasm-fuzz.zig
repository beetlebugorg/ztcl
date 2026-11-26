//! The differential fuzzer of compiled point procs.
//!
//!   zig build point-wasm-fuzz -- [--count N] [--seed S] [--batch B]
//!
//! For each case it makes a random proc (`src/point_fuzz.zig`) and
//! random points with special values, runs `Program.run` and
//! `point.runSlow` (one point at a time), and compiles the proc in the
//! SIMD form or the scalar form. A batch of cases goes to one run of
//! `node tools/point-wasm-fuzz.mjs`, which runs each module and returns
//! its outputs and steps. The fuzzer compares the bits of each output
//! with `Program.run`, the steps with `Program.steps(n)`, and
//! `Program.run` with `runSlow` on the points where the slow path gives
//! no Tcl error. On a difference of the module it writes the proc and
//! the seed to `zig-out/point-wasm-fuzz-fail.tcl` and exits with 1.
//!
//! A difference of `Program.run` and `runSlow` ends the run too, and
//! writes the proc to `zig-out/point-wasm-fuzz-fail.tcl`, except a
//! difference in the sign of a zero, which the fuzzer counts: see the
//! comment at the compare. `--strict-slow 0` counts the other
//! differences of the slow path and writes the first proc to
//! `zig-out/point-wasm-fuzz-slow.tcl`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const tcl = @import("ztcl");
const point = tcl.point;

const nf = @typeInfo(point.Field).@"enum".field_names.len;
const no = @typeInfo(point.Out).@"enum".field_names.len;

const Case = struct {
    seed: u64,
    text: []const u8,
    prog: *const point.Program,
    n: usize,
    in_mask: u32,
    out_mask: u32,
    point_seed: u32,
    simd: bool,
    /// The outputs of Program.run, for the present columns.
    want: [no]?[]f64,
};

const special = [_]f64{ std.math.nan(f64), -0.0, 0.0, std.math.inf(f64), -std.math.inf(f64), 5e-324, -5e-324, 1.0, -1.0, 0.5, 1e300, -1e300 };

fn le(list: *std.ArrayList(u8), a: std.mem.Allocator, comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try list.appendSlice(a, &b);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var count: usize = 1000;
    var seed: u64 = 1;
    var batch: usize = 200;
    var strict_slow = true;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const v = try std.fmt.parseInt(u64, args[i + 1], 10);
        if (std.mem.eql(u8, args[i], "--strict-slow")) strict_slow = v != 0 else if (std.mem.eql(u8, args[i], "--count")) count = v else if (std.mem.eql(u8, args[i], "--seed")) seed = v else if (std.mem.eql(u8, args[i], "--batch")) batch = v else return error.BadArgs;
    }
    var rejected: usize = 0;
    var cases_run: usize = 0;
    var slow_skipped: usize = 0;
    var slow_diffs: usize = 0;
    var zero_signs: usize = 0;
    var case_seed = seed;
    while (cases_run < count) {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var it: tcl.Interp = undefined;
        try it.init(gpa);
        defer it.deinit();
        var state: point.State = .{};
        try point.install(&it, &state);
        var cases: std.ArrayList(Case) = .empty;
        var bytes: std.ArrayList(u8) = .empty;
        try le(&bytes, a, u32, 0);
        while (cases.items.len < batch and cases_run + cases.items.len < count) {
            case_seed += 1;
            var prng = std.Random.DefaultPrng.init(case_seed *% 0x9e3779b97f4a7c15);
            const r = prng.random();
            const name = try std.fmt.allocPrint(a, "f{d}", .{case_seed});
            const text = try tcl.point_fuzz.proc(a, case_seed, name);
            _ = it.eval(text) catch {
                rejected += 1;
                continue;
            };
            const prog = state.program(name).?;
            const simd = r.boolean();
            const compiled = try tcl.point_wasm.compile(a, prog, .{ .simd = simd, .max_mem = 2 << 20 });
            const n = @min(r.uintLessThan(usize, 2600), compiled.layout.cap);
            const in_mask: u32 = if (r.boolean()) (1 << nf) - 1 else r.int(u32) & ((1 << nf) - 1);
            const out_mask: u32 = if (r.boolean()) (1 << no) - 1 else r.int(u32) & ((1 << no) - 1);
            const point_seed = r.int(u32);
            // The points.
            var cols: [nf][]f64 = undefined;
            for (&cols, 0..) |*c, k| {
                c.* = try a.alloc(f64, n);
                for (c.*, 0..) |*v, j| {
                    const t: f64 = @floatFromInt(j);
                    v.* = if (r.uintLessThan(u32, 50) == 0) special[r.uintLessThan(usize, special.len)] else switch (k) {
                        0 => 100 + 40 * @cos(t * 0.01) + r.float(f64) * 1e-3,
                        1 => 100 + 40 * @sin(t * 0.01),
                        2 => 0.2 * @floor(t / 500),
                        3 => 0.4 + 0.05 * @sin(t * 0.3),
                        else => (r.float(f64) - 0.5) * 20,
                    };
                }
            }
            const feat = try a.alloc(u8, n);
            for (feat) |*f| f.* = r.uintLessThan(u8, 7);
            var starts: [no][]f64 = undefined;
            for (&starts, 0..) |*c, k| {
                c.* = try a.alloc(f64, n);
                for (c.*, 0..) |*v, j| v.* = if (k == @intFromEnum(point.Out.width)) cols[3][j] else if (r.boolean()) 0 else (r.float(f64) - 0.5) * 0.2;
            }
            const writes = tcl.point_wasm.outputs(prog);
            var runs: [2][no]?[]f64 = .{ @splat(null), @splat(null) };
            var pts: [2]point.Points = undefined;
            for (&pts, &runs) |*p, *outs| {
                p.* = .{ .len = n, .seed = point_seed };
                for (0..nf) |k| {
                    if (in_mask & (@as(u32, 1) << @intCast(k)) == 0) continue;
                    if (k == @intFromEnum(point.Field.feature)) p.feature = feat else p.in[k] = cols[k];
                }
                for (0..no) |k| {
                    if (out_mask & (@as(u32, 1) << @intCast(k)) == 0 or !writes[k]) continue;
                    outs[k] = try a.dupe(f64, starts[k]);
                    p.out[k] = outs[k];
                }
            }
            prog.run(&pts[0], try a.alloc(f64, prog.scratchLen()));
            for (0..n) |j| {
                var one = pts[1];
                one.len = 1;
                if (one.feature) |f| one.feature = f[j..][0..1];
                for (&one.in) |*c| if (c.*) |col| {
                    c.* = col[j..][0..1];
                };
                for (&one.out) |*c| if (c.*) |col| {
                    c.* = col[j..][0..1];
                };
                point.runSlow(&it, name, &one) catch {
                    slow_skipped += 1;
                    continue;
                };
                for (0..no) |k| if (runs[0][k]) |fast| {
                    if (@as(u64, @bitCast(fast[j])) != @as(u64, @bitCast(runs[1][k].?[j]))) {
                        // A value that is an integer for some points and a
                        // double for others ("mixed" in point.zig) can be
                        // a zero with either sign: Tcl gives 0 for an
                        // integer and -0.0 for a double, and the vector
                        // program has no type for each point. Such a
                        // difference counts, and does not end the run.
                        if (fast[j] == 0 and runs[1][k].?[j] == 0) {
                            zero_signs += 1;
                            continue;
                        }
                        slow_diffs += 1;
                        if (strict_slow or slow_diffs == 1) try fail(io, a, if (strict_slow) "zig-out/point-wasm-fuzz-fail.tcl" else "zig-out/point-wasm-fuzz-slow.tcl", text, case_seed, simd, "Program.run and runSlow differ", k, j, fast[j], runs[1][k].?[j]);
                        if (strict_slow) return 1;
                        break;
                    }
                };
            }
            // The case for Node.js.
            try le(&bytes, a, u32, @intCast(compiled.bytes.len));
            try bytes.appendSlice(a, compiled.bytes);
            for ([_]u32{ @intCast(n), point_seed, in_mask, out_mask }) |v| try le(&bytes, a, u32, v);
            for (cols) |c| try bytes.appendSlice(a, std.mem.sliceAsBytes(c));
            try bytes.appendSlice(a, feat);
            for (starts) |c| try bytes.appendSlice(a, std.mem.sliceAsBytes(c));
            try cases.append(a, .{ .seed = case_seed, .text = text, .prog = prog, .n = n, .in_mask = in_mask, .out_mask = out_mask, .point_seed = point_seed, .simd = simd, .want = runs[0] });
        }
        std.mem.writeInt(u32, bytes.items[0..4], @intCast(cases.items.len), .little);
        try Io.Dir.cwd().createDirPath(io, "zig-out");
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = "zig-out/point-wasm-fuzz.bin", .data = bytes.items });
        const res = try std.process.run(gpa, io, .{ .argv = &.{ "node", "tools/point-wasm-fuzz.mjs", "zig-out/point-wasm-fuzz.bin" } });
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) {
            std.debug.print("node failed: {s}\n", .{res.stderr});
            return 1;
        }
        var pos: usize = 0;
        for (cases.items) |c| {
            const steps = std.mem.readInt(i64, res.stdout[pos..][0..8], .little);
            pos += 8;
            if (steps != @as(i64, @intCast(c.prog.steps(c.n)))) {
                std.debug.print("seed {d}: steps {d}, Program.steps {d}\n", .{ c.seed, steps, c.prog.steps(c.n) });
                try fail(io, a, "zig-out/point-wasm-fuzz-fail.tcl", c.text, c.seed, c.simd, "steps differ", 0, 0, 0, 0);
                return 1;
            }
            for (c.want, 0..) |maybe, k| {
                const want = maybe orelse continue;
                for (want, 0..) |v, j| {
                    const got = std.mem.readInt(u64, res.stdout[pos..][0..8], .little);
                    pos += 8;
                    if (got != @as(u64, @bitCast(v))) {
                        try fail(io, a, "zig-out/point-wasm-fuzz-fail.tcl", c.text, c.seed, c.simd, "the module and Program.run differ", k, j, @bitCast(got), v);
                        return 1;
                    }
                }
            }
        }
        cases_run += cases.items.len;
    }
    std.debug.print("point-wasm-fuzz: {d} procs, 0 differences of the module, {d} procs failed the check, {d} points with a Tcl error on the slow path, {d} points where Program.run and runSlow differ, {d} points where only the sign of a zero differs\n", .{ cases_run, rejected, slow_skipped, slow_diffs, zero_signs });
    return 0;
}

fn fail(io: Io, a: std.mem.Allocator, path: []const u8, text: []const u8, seed: u64, simd: bool, what: []const u8, col: usize, j: usize, x: f64, y: f64) !void {
    const msg = try std.fmt.allocPrint(a, "# {s}: seed {d}, simd {}, column {d}, point {d}: {x} {x}\n{s}", .{ what, seed, simd, col, j, @as(u64, @bitCast(x)), @as(u64, @bitCast(y)), text });
    std.debug.print("{s}\n", .{msg[0 .. std.mem.indexOfScalar(u8, msg, '\n') orelse msg.len]});
    try Io.Dir.cwd().createDirPath(io, "zig-out");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = msg });
}

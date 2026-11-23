//! The benchmark of the point procs: `zig build bench`.
//!
//! It runs the fuzzy skin proc over 1 million and 10 million points on
//! the fast path (the vector program) and on the slow path (one call of
//! the normal interpreter for each point), and prints the time for each
//! point. `--no-slow` leaves the slow path out.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const tcl = @import("ztcl");
const point = tcl.point;

const fuzzy =
    \\point proc fuzzy {x y z feature} {
    \\    if {$feature ne "outer_wall"} { return }
    \\    set n [noise3 $x $y [expr {$z * 4}]]
    \\    offset [expr {$n * 0.3}]
    \\}
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var slow = true;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--no-slow")) slow = false;
    }

    var buf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    var state: point.State = .{};
    var it: tcl.Interp = undefined;
    try it.init(gpa);
    defer it.deinit();
    try point.install(&it, &state);
    _ = try it.eval(fuzzy);
    const prog = state.program("fuzzy").?;
    try out.print("fuzzy: {d} operations for each block of {d} points, {d} registers\n", .{ prog.ops.len, point.block, prog.regs });

    // `walls` is the share of the points on the outer wall, in percent.
    for ([_]usize{ 1_000_000, 10_000_000 }) |n| {
        for ([_]u8{ 33, 100 }) |walls| {
            const x = try gpa.alloc(f64, n);
            defer gpa.free(x);
            const y = try gpa.alloc(f64, n);
            defer gpa.free(y);
            const z = try gpa.alloc(f64, n);
            defer gpa.free(z);
            const feature = try gpa.alloc(u8, n);
            defer gpa.free(feature);
            const offset = try gpa.alloc(f64, n);
            defer gpa.free(offset);
            var seed: u64 = 99;
            for (0..n) |i| {
                seed = seed *% 6364136223846793005 +% 1442695040888963407;
                const fi: f64 = @floatFromInt(i);
                x[i] = 100 + 40 * @cos(fi * 0.001);
                y[i] = 100 + 40 * @sin(fi * 0.001);
                z[i] = 0.2 * @floor(fi / 4000);
                feature[i] = if ((seed >> 33) % 100 < walls) 0 else 1 + @as(u8, @intCast((seed >> 40) % 3));
            }
            var pts: point.Points = .{ .len = n, .feature = feature };
            pts.in[@intFromEnum(point.Field.x)] = x;
            pts.in[@intFromEnum(point.Field.y)] = y;
            pts.in[@intFromEnum(point.Field.z)] = z;
            pts.out[@intFromEnum(point.Out.offset)] = offset;

            const scratch = try gpa.alloc(f64, prog.scratchLen());
            defer gpa.free(scratch);
            var best: u64 = std.math.maxInt(u64);
            for (0..5) |_| {
                @memset(offset, 0);
                const t0 = Io.Clock.awake.now(io);
                prog.run(&pts, scratch);
                best = @min(best, @as(u64, @intCast(t0.untilNow(io, .awake).toNanoseconds())));
            }
            var sum: f64 = 0;
            for (offset) |o| sum += o;
            const nf: f64 = @floatFromInt(n);
            try out.print("{d:>9} points, {d:>3}% outer wall: fast {d:>6.2} ns/point ({d:.1} ms)", .{ n, walls, @as(f64, @floatFromInt(best)) / nf, @as(f64, @floatFromInt(best)) / 1e6 });
            if (slow) {
                @memset(offset, 0);
                const t0 = Io.Clock.awake.now(io);
                try point.runSlow(&it, "fuzzy", &pts);
                const ns: f64 = @floatFromInt(t0.untilNow(io, .awake).toNanoseconds());
                var sum2: f64 = 0;
                for (offset) |o| sum2 += o;
                try out.print(", slow {d:>7.1} ns/point ({d:.0} ms), same sum: {}", .{ ns / nf, ns / 1e6, sum == sum2 });
            }
            try out.print("\n", .{});
            try out.flush();
        }
    }
}

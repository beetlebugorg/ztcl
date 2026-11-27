//! Micro benchmark: the n-body simulation of the Computer Language
//! Benchmarks Game, for N steps.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

const pi: f64 = std.math.pi;
const solar_mass: f64 = 4 * pi * pi;
const days: f64 = 365.24;

const Body = struct { x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, mass: f64 };

fn energy(bs: []const Body) f64 {
    var e: f64 = 0;
    for (bs, 0..) |b, i| {
        e += 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz);
        for (bs[i + 1 ..]) |b2| {
            const dx = b.x - b2.x;
            const dy = b.y - b2.y;
            const dz = b.z - b2.z;
            e -= b.mass * b2.mass / @sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}

fn advance(bs: []Body, dt: f64) void {
    for (bs, 0..) |*b, i| {
        for (bs[i + 1 ..]) |*b2| {
            const dx = b.x - b2.x;
            const dy = b.y - b2.y;
            const dz = b.z - b2.z;
            const d2 = dx * dx + dy * dy + dz * dz;
            const mag = dt / (d2 * @sqrt(d2));
            b.vx -= dx * b2.mass * mag;
            b.vy -= dy * b2.mass * mag;
            b.vz -= dz * b2.mass * mag;
            b2.vx += dx * b.mass * mag;
            b2.vy += dy * b.mass * mag;
            b2.vz += dz * b.mass * mag;
        }
    }
    for (bs) |*b| {
        b.x += dt * b.vx;
        b.y += dt * b.vy;
        b.z += dt * b.vz;
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const n = try std.fmt.parseInt(usize, args[1], 10);
    var bs = [_]Body{
        .{ .x = 0, .y = 0, .z = 0, .vx = 0, .vy = 0, .vz = 0, .mass = solar_mass },
        .{ .x = 4.84143144246472090e+00, .y = -1.16032004402742839e+00, .z = -1.03622044471123109e-01, .vx = 1.66007664274403694e-03 * days, .vy = 7.69901118419740425e-03 * days, .vz = -6.90460016972063023e-05 * days, .mass = 9.54791938424326609e-04 * solar_mass },
        .{ .x = 8.34336671824457987e+00, .y = 4.12479856412430479e+00, .z = -4.03523417114321381e-01, .vx = -2.76742510726862411e-03 * days, .vy = 4.99852801234917238e-03 * days, .vz = 2.30417297573763929e-05 * days, .mass = 2.85885980666130812e-04 * solar_mass },
        .{ .x = 1.28943695621391310e+01, .y = -1.51111514016986312e+01, .z = -2.23307578892655734e-01, .vx = 2.96460137564761618e-03 * days, .vy = 2.37847173959480950e-03 * days, .vz = -2.96589568540237556e-05 * days, .mass = 4.36624404335156298e-05 * solar_mass },
        .{ .x = 1.53796971148509165e+01, .y = -2.59193146099879641e+01, .z = 1.79258772950371181e-01, .vx = 2.68067772490389322e-03 * days, .vy = 1.62824170038242295e-03 * days, .vz = -9.51592254519715870e-05 * days, .mass = 5.15138902046611451e-05 * solar_mass },
    };
    var px: f64 = 0;
    var py: f64 = 0;
    var pz: f64 = 0;
    for (bs) |b| {
        px += b.vx * b.mass;
        py += b.vy * b.mass;
        pz += b.vz * b.mass;
    }
    bs[0].vx = -px / solar_mass;
    bs[0].vy = -py / solar_mass;
    bs[0].vz = -pz / solar_mass;
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d:.9}\n", .{energy(&bs)});
    for (0..n) |_| advance(&bs, 0.01);
    try w.interface.print("{d:.9}\n", .{energy(&bs)});
    try w.interface.flush();
}

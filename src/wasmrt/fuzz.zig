//! The differential fuzzer of the wasm JIT: random valid modules, run in
//! the interpreter and in the JIT, with the same arguments.
//!
//! The generator writes functions of the type (i32 i32 i64) -> i64 from
//! a typed expression grammar: integer and float arithmetic (with the
//! divisions and conversions that trap), compares, selects, blocks, ifs,
//! bounded loops with `br_if`, loads and stores near the end of memory,
//! `memory.grow`, and calls to the earlier functions. Each run compares
//! the results, the trap, the compute units left, and the bytes of
//! memory. A budget of compute units below the need of a call checks
//! that both tiers stop at the same point.
//!
//! Usage: wasm-fuzz ?-seed N? ?-count N?
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const mod = @import("module.zig");
const exec = @import("exec.zig");

const Gen = struct {
    r: std.Random,
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    nfuncs: u32,
    loops: u32 = 0,

    fn b(g: *Gen, x: u8) !void {
        try g.out.append(g.a, x);
    }

    fn uleb(g: *Gen, v: u64) !void {
        var x = v;
        while (true) {
            const byte: u8 = @intCast(x & 0x7f);
            x >>= 7;
            if (x == 0) return g.b(byte);
            try g.b(byte | 0x80);
        }
    }

    fn sleb(g: *Gen, v: i64) !void {
        var x = v;
        while (true) {
            const byte: u8 = @intCast(x & 0x7f);
            x >>= 7;
            if ((x == 0 and byte & 0x40 == 0) or (x == -1 and byte & 0x40 != 0)) return g.b(byte);
            try g.b(byte | 0x80);
        }
    }

    fn interesting(g: *Gen) i64 {
        const vals = [_]i64{ 0, 1, -1, 2, 7, 31, 32, 63, 64, 0x7fffffff, -0x80000000, 0xffffffff, 65535, 65532, std.math.maxInt(i64), std.math.minInt(i64) };
        if (g.r.boolean()) return vals[g.r.uintLessThan(usize, vals.len)];
        return g.r.int(i64);
    }

    fn addr(g: *Gen) !void {
        // An address near the end of one or two pages, or a computed one.
        if (g.r.uintLessThan(u8, 3) == 0) {
            try g.i32_(2);
            try g.b(0x41);
            try g.sleb(0x1ffff);
            try g.b(0x71);
        } else {
            try g.b(0x41);
            try g.sleb(@intCast(g.r.intRangeAtMost(i64, 65500, 65540)));
        }
    }

    fn i32_(g: *Gen, depth: u32) anyerror!void {
        if (depth == 0) return g.leafI32();
        switch (g.r.uintLessThan(u8, 14)) {
            0, 1 => {
                try g.i32_(depth - 1);
                try g.i32_(depth - 1);
                try g.b(@intCast(0x6a + g.r.uintLessThan(u8, 15)));
            },
            2 => {
                try g.i64_(depth - 1);
                try g.i64_(depth - 1);
                try g.b(@intCast(0x51 + g.r.uintLessThan(u8, 10)));
            },
            3 => {
                try g.i32_(depth - 1);
                try g.i32_(depth - 1);
                try g.b(@intCast(0x46 + g.r.uintLessThan(u8, 10)));
            },
            4 => {
                try g.i64_(depth - 1);
                try g.b(0xa7);
            },
            5 => {
                try g.addr();
                const ops = [_]u8{ 0x28, 0x2c, 0x2d, 0x2e, 0x2f };
                try g.b(ops[g.r.uintLessThan(usize, ops.len)]);
                try g.b(0);
                try g.uleb(g.r.uintLessThan(u32, 8));
            },
            6 => {
                try g.i32_(depth - 1);
                try g.i32_(depth - 1);
                try g.i32_(depth - 1);
                try g.b(0x1b);
            },
            7 => {
                try g.b(0x02);
                try g.b(0x7f);
                try g.i32_(depth - 1);
                try g.i32_(depth - 1);
                try g.b(0x0d);
                try g.b(0);
                try g.b(0x1a);
                try g.i32_(depth - 1);
                try g.b(0x0b);
            },
            8 => {
                try g.i32_(depth - 1);
                try g.b(0x04);
                try g.b(0x7f);
                try g.i32_(depth - 1);
                try g.b(0x05);
                try g.i32_(depth - 1);
                try g.b(0x0b);
            },
            9 => {
                try g.i32_(depth - 1);
                try g.b(@intCast(0x67 + g.r.uintLessThan(u8, 3)));
            },
            10 => {
                try g.i32_(depth - 1);
                try g.b(@intCast(0xc0 + g.r.uintLessThan(u8, 2)));
            },
            11 => {
                try g.i32_(depth - 1);
                try g.b(0x22);
                try g.b(3);
            },
            12 => {
                try g.f64_(depth - 1);
                if (g.r.boolean()) {
                    try g.b(0xfc);
                    try g.b(2);
                } else try g.b(0xaa);
            },
            else => {
                try g.b(0x41);
                try g.sleb(g.r.intRangeAtMost(i64, 0, 2));
                try g.b(0x40);
                try g.b(0);
            },
        }
    }

    fn leafI32(g: *Gen) !void {
        switch (g.r.uintLessThan(u8, 3)) {
            0 => {
                try g.b(0x20);
                try g.b(g.r.uintLessThan(u8, 2));
            },
            1 => {
                try g.b(0x20);
                try g.b(3);
            },
            else => {
                try g.b(0x41);
                try g.sleb(@as(i32, @truncate(g.interesting())));
            },
        }
    }

    fn i64_(g: *Gen, depth: u32) anyerror!void {
        if (depth == 0) {
            if (g.r.boolean()) {
                try g.b(0x20);
                try g.b(if (g.r.boolean()) 2 else 4);
            } else {
                try g.b(0x42);
                try g.sleb(g.interesting());
            }
            return;
        }
        switch (g.r.uintLessThan(u8, 10)) {
            0, 1, 2 => {
                try g.i64_(depth - 1);
                try g.i64_(depth - 1);
                try g.b(@intCast(0x7c + g.r.uintLessThan(u8, 15)));
            },
            3 => {
                try g.i32_(depth - 1);
                try g.b(if (g.r.boolean()) 0xac else 0xad);
            },
            4 => {
                try g.addr();
                const ops = [_]u8{ 0x29, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35 };
                try g.b(ops[g.r.uintLessThan(usize, ops.len)]);
                try g.b(0);
                try g.uleb(g.r.uintLessThan(u32, 8));
            },
            5 => if (g.loops < 2) {
                // local 3 counts down from a small number.
                g.loops += 1;
                defer g.loops -= 1;
                try g.b(0x41);
                try g.sleb(g.r.intRangeAtMost(i64, 0, 12));
                try g.b(0x21);
                try g.b(3);
                try g.b(0x03);
                try g.b(0x40);
                try g.b(0x20);
                try g.b(4);
                try g.i64_(depth - 1);
                try g.b(0x7c);
                try g.b(0x21);
                try g.b(4);
                try g.b(0x20);
                try g.b(3);
                try g.b(0x41);
                try g.b(1);
                try g.b(0x6b);
                try g.b(0x22);
                try g.b(3);
                try g.b(0x0d);
                try g.b(0);
                try g.b(0x0b);
                try g.b(0x20);
                try g.b(4);
            } else try g.i64_(0),
            6 => if (g.nfuncs > 0) {
                try g.i32_(depth - 1);
                try g.i32_(depth - 1);
                try g.i64_(depth - 1);
                try g.b(0x10);
                try g.uleb(g.r.uintLessThan(u32, g.nfuncs));
            } else try g.i64_(0),
            7 => {
                try g.f64_(depth - 1);
                if (g.r.boolean()) try g.b(0xbd) else {
                    try g.b(0xfc);
                    try g.b(6);
                }
            },
            8 => {
                try g.addr();
                try g.i64_(depth - 1);
                try g.b(0x37);
                try g.b(0);
                try g.b(0);
                try g.i64_(depth - 1);
            },
            else => {
                try g.i64_(depth - 1);
                try g.b(@intCast(0x79 + g.r.uintLessThan(u8, 3)));
            },
        }
    }

    fn f64_(g: *Gen, depth: u32) anyerror!void {
        if (depth == 0) {
            try g.i64_(0);
            try g.b(if (g.r.boolean()) 0xb9 else 0xbf);
            return;
        }
        switch (g.r.uintLessThan(u8, 4)) {
            0, 1 => {
                try g.f64_(depth - 1);
                try g.f64_(depth - 1);
                try g.b(@intCast(0xa0 + g.r.uintLessThan(u8, 7)));
            },
            2 => {
                try g.f64_(depth - 1);
                try g.b(@intCast(0x99 + g.r.uintLessThan(u8, 7)));
            },
            else => {
                try g.i32_(depth - 1);
                try g.b(0xb7);
            },
        }
    }
};

fn section(out: *std.ArrayList(u8), a: std.mem.Allocator, id: u8, body: []const u8) !void {
    try out.append(a, id);
    var g: Gen = .{ .r = undefined, .out = out, .a = a, .nfuncs = 0 };
    try g.uleb(body.len);
    try out.appendSlice(a, body);
}

/// A module of `n` functions of the type (i32 i32 i64) -> i64.
fn module(a: std.mem.Allocator, r: std.Random, n: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "\x00asm\x01\x00\x00\x00");
    try section(&out, a, 1, "\x01\x60\x03\x7f\x7f\x7e\x01\x7e");
    var funcs: std.ArrayList(u8) = .empty;
    var g0: Gen = .{ .r = r, .out = &funcs, .a = a, .nfuncs = 0 };
    try g0.uleb(n);
    for (0..n) |_| try funcs.append(a, 0);
    try section(&out, a, 3, funcs.items);
    try section(&out, a, 5, "\x01\x01\x01\x03");
    var ex: std.ArrayList(u8) = .empty;
    var ge: Gen = .{ .r = r, .out = &ex, .a = a, .nfuncs = 0 };
    try ge.uleb(n);
    for (0..n) |i| {
        try ex.append(a, 2);
        try ex.append(a, 'f');
        try ex.append(a, @intCast('a' + i));
        try ex.append(a, 0);
        try ge.uleb(i);
    }
    try section(&out, a, 7, ex.items);
    var code: std.ArrayList(u8) = .empty;
    var gc: Gen = .{ .r = r, .out = &code, .a = a, .nfuncs = 0 };
    try gc.uleb(n);
    for (0..n) |i| {
        var body: std.ArrayList(u8) = .empty;
        var g: Gen = .{ .r = r, .out = &body, .a = a, .nfuncs = @intCast(i) };
        try body.appendSlice(a, "\x02\x01\x7f\x01\x7e");
        try g.i64_(g.r.intRangeAtMost(u32, 1, 6));
        try body.append(a, 0x0b);
        try gc.uleb(body.items.len);
        try code.appendSlice(a, body.items);
    }
    try section(&out, a, 10, code.items);
    return out.items;
}

const Outcome = struct { trap: ?anyerror, result: u64, units: u64, mem: u64 };

fn runOne(gpa: std.mem.Allocator, m: *const mod.Module, jit: bool, f: u32, args: [3]u64, units: u64) !Outcome {
    var s = exec.Store.init(gpa);
    s.fixUnits();
    defer s.deinit();
    s.jit_on = jit and s.jit_on;
    const inst = try s.instantiate(m, &.{});
    s.own_units = units;
    var res: [1]u64 = .{0};
    var trap: ?anyerror = null;
    s.invoke(inst.funcs[f], &args, &res) catch |e| {
        trap = e;
    };
    return .{ .trap = trap, .result = if (trap == null) res[0] else 0, .units = s.own_units, .mem = std.hash.Wyhash.hash(0, inst.mems[0].bytes) };
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var seed: u64 = 1;
    var count: u64 = 200;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const v = try std.fmt.parseInt(u64, args[i + 1], 10);
        if (std.mem.eql(u8, args[i], "-seed")) seed = v else if (std.mem.eql(u8, args[i], "-count")) count = v;
    }
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var runs: u64 = 0;
    var bad: u64 = 0;
    var trapped: u64 = 0;
    for (0..count) |n| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const bytes = try module(arena.allocator(), r, 1 + r.uintLessThan(u32, 6));
        var diag: mod.Diag = .{};
        const m = mod.decode(gpa, bytes, &diag) catch |e| {
            std.debug.print("module {d}: the generator wrote an invalid module: {s}: {s} at {d}\n", .{ n, @errorName(e), diag.msg, diag.offset });
            bad += 1;
            continue;
        };
        defer m.deinit();
        for (0..m.funcs.len) |f| {
            for (0..8) |_| {
                const a3 = [3]u64{ r.int(u32) % 70000, r.int(u32), r.int(u64) };
                const units: u64 = if (r.uintLessThan(u8, 4) == 0) r.uintLessThan(u64, 40) else 1_000_000;
                const x = try runOne(gpa, m, false, @intCast(f), a3, units);
                const y = try runOne(gpa, m, true, @intCast(f), a3, units);
                runs += 1;
                if (x.trap != null) trapped += 1;
                if (x.trap != y.trap or x.result != y.result or x.units != y.units or x.mem != y.mem) {
                    bad += 1;
                    std.debug.print("DIFF seed {d} module {d} func {d}: interp {s} {x} units {d} / jit {s} {x} units {d}\n", .{ seed, n, f, if (x.trap) |e| @errorName(e) else "ok", x.result, x.units, if (y.trap) |e| @errorName(e) else "ok", y.result, y.units });
                }
            }
        }
    }
    std.debug.print("wasm-fuzz: {d} calls, {d} traps, {d} differences\n", .{ runs, trapped, bad });
    return if (bad == 0) 0 else 1;
}

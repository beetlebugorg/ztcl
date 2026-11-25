//! A generator of random point procs for the differential fuzzer of
//! compiled point procs (`tools/point-wasm-fuzz.zig`).
//!
//! `proc` writes the Tcl text of one proc from a seed. The text uses
//! each part of the subset of the check: parameters that are point
//! fields, `set` of locals, nested `if` / `elseif` / `else`, `return`,
//! each output command, `noise3` and `noise2` as commands and as
//! functions, each math function, `clamp`, `lerp`, `min` and `max` with
//! more than two arguments, the compare of the feature with a name, and
//! edge constants (-0.0, a huge value, a division by zero).
//!
//! The generator tracks the locals that are set on all paths, so most
//! procs pass the check. The argument of `int()`, `round()`,
//! `entier()`, and `wide()` goes through `fmod(..., 1e6)`, because the
//! slow path gives an integer of 64 bits for a larger value and the
//! vector program keeps a double. `%` gets two integers, and `/` and
//! `**` get a double or two integers, as the check needs.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

const fields = [_][]const u8{ "x", "y", "z", "width", "height", "speed", "flow", "layer", "path", "dist" };
const fn1 = [_][]const u8{ "abs", "acos", "asin", "atan", "ceil", "cos", "cosh", "double", "exp", "floor", "log", "log10", "sin", "sinh", "sqrt", "tan", "tanh" };
const fn2 = [_][]const u8{ "atan2", "fmod", "hypot", "pow", "noise2" };
const int_fns = [_][]const u8{ "int", "round", "entier", "wide" };
const features = [_][]const u8{ "outer_wall", "inner_wall", "skin", "infill", "support", "travel" };
const consts = [_][]const u8{ "0", "1", "2", "-3", "0.5", "-0.0", "0.25", "1e308", "-1e308", "3.75", "100", "7" };

const Gen = struct {
    a: Allocator,
    r: std.Random,
    out: std.ArrayList(u8) = .empty,
    params: std.ArrayList([]const u8) = .empty,
    has_feature: bool = false,
    /// The locals that are set on all paths: the name and true for an
    /// integer.
    locals: std.ArrayList(struct { []const u8, bool }) = .empty,
    names: usize = 0,

    fn w(g: *Gen, s: []const u8) !void {
        try g.out.appendSlice(g.a, s);
    }

    fn pick(g: *Gen, list: []const []const u8) []const u8 {
        return list[g.r.uintLessThan(usize, list.len)];
    }

    fn chance(g: *Gen, percent: u32) bool {
        return g.r.uintLessThan(u32, 100) < percent;
    }

    /// A numeric expression. `int` is true when the value is an integer
    /// for each point.
    fn expr(g: *Gen, depth: u32) Allocator.Error!bool {
        if (depth == 0 or g.chance(25)) return g.leaf();
        switch (g.r.uintLessThan(u32, 12)) {
            0, 1 => {
                try g.w("(");
                const x = try g.expr(depth - 1);
                try g.w(g.pick(&.{ " + ", " - ", " * " }));
                const y = try g.expr(depth - 1);
                try g.w(")");
                return x and y;
            },
            2 => {
                try g.w("(double(");
                _ = try g.expr(depth - 1);
                try g.w(") / ");
                _ = try g.expr(depth - 1);
                try g.w(")");
                return false;
            },
            3 => {
                // Two integers: integer division or remainder.
                try g.w("(int(fmod(");
                _ = try g.expr(depth - 1);
                try g.w(", 1e6))");
                try g.w(g.pick(&.{ " / ", " % " }));
                try g.w(g.pick(&.{ "3", "-2", "0", "7" }));
                try g.w(")");
                return true;
            },
            4 => {
                try g.w(g.pick(&fn1));
                try g.w("(");
                _ = try g.expr(depth - 1);
                try g.w(")");
                return false;
            },
            5 => {
                try g.w(g.pick(&fn2));
                try g.w("(");
                _ = try g.expr(depth - 1);
                try g.w(", ");
                _ = try g.expr(depth - 1);
                try g.w(")");
                return false;
            },
            6 => {
                try g.w(g.pick(&int_fns));
                try g.w("(fmod(");
                _ = try g.expr(depth - 1);
                try g.w(", 1e6))");
                return true;
            },
            7 => {
                try g.w(g.pick(&.{ "clamp(", "lerp(", "noise3(" }));
                for (0..3) |i| {
                    if (i > 0) try g.w(", ");
                    _ = try g.expr(depth - 1);
                }
                try g.w(")");
                return false;
            },
            8 => {
                try g.w(g.pick(&.{ "min(", "max(" }));
                const k = 2 + g.r.uintLessThan(usize, 3);
                var all = true;
                for (0..k) |i| {
                    if (i > 0) try g.w(", ");
                    all = (try g.expr(depth - 1)) and all;
                }
                try g.w(")");
                return all;
            },
            9 => {
                try g.w("(");
                try g.cond(depth - 1);
                try g.w(" ? ");
                const x = try g.expr(depth - 1);
                try g.w(" : ");
                const y = try g.expr(depth - 1);
                try g.w(")");
                return x and y;
            },
            10 => {
                try g.w(g.pick(&.{ "-", "+" }));
                return g.expr(depth - 1);
            },
            else => {
                try g.w(g.pick(&.{ "bool(", "!(" }));
                _ = try g.expr(depth - 1);
                try g.w(")");
                return true;
            },
        }
    }

    fn leaf(g: *Gen) Allocator.Error!bool {
        const n = g.params.items.len + g.locals.items.len;
        if (n > 0 and g.chance(70)) {
            const i = g.r.uintLessThan(usize, n);
            if (i < g.params.items.len) {
                try g.w("$");
                try g.w(g.params.items[i]);
                return false;
            }
            const l = g.locals.items[i - g.params.items.len];
            try g.w("$");
            try g.w(l[0]);
            return l[1];
        }
        const c = g.pick(&consts);
        try g.w(c);
        return std.mem.indexOfAny(u8, c, ".e") == null;
    }

    fn cond(g: *Gen, depth: u32) Allocator.Error!void {
        if (g.has_feature and g.chance(30)) {
            try g.w("$feature ");
            try g.w(g.pick(&.{ "eq", "ne", "==", "!=" }));
            try g.w(" \"");
            try g.w(g.pick(&features));
            try g.w("\"");
            return;
        }
        if (g.chance(20)) {
            try g.w("(");
            try g.cond(depth);
            try g.w(g.pick(&.{ " && ", " || " }));
            try g.cond(depth);
            try g.w(")");
            return;
        }
        _ = try g.expr(depth);
        try g.w(g.pick(&.{ " < ", " <= ", " > ", " >= ", " == ", " != " }));
        _ = try g.expr(depth);
    }

    fn indent(g: *Gen, level: u32) !void {
        for (0..level + 1) |_| try g.w("    ");
    }

    fn value(g: *Gen) !void {
        if (g.chance(15)) {
            try g.w(g.pick(&.{ "[noise3 ", "[noise2 " }));
            const k: usize = if (g.out.items[g.out.items.len - 2] == '3') 3 else 2;
            for (0..k) |i| {
                if (i > 0) try g.w(" ");
                try g.w("[expr {");
                _ = try g.expr(2);
                try g.w("}]");
            }
            try g.w("]");
            return;
        }
        try g.w("[expr {");
        _ = try g.expr(3);
        try g.w("}]");
    }

    fn block(g: *Gen, level: u32, count: usize) anyerror!void {
        for (0..count) |_| {
            try g.indent(level);
            switch (g.r.uintLessThan(u32, 10)) {
                0, 1, 2 => {
                    // A new local, or a new value of an old one.
                    var name: []const u8 = undefined;
                    var is_new = true;
                    if (g.locals.items.len > 0 and g.chance(40)) {
                        name = g.locals.items[g.r.uintLessThan(usize, g.locals.items.len)][0];
                        is_new = false;
                    } else {
                        name = try std.fmt.allocPrint(g.a, "v{d}", .{g.names});
                        g.names += 1;
                    }
                    try g.w("set ");
                    try g.w(name);
                    try g.w(" ");
                    try g.value();
                    try g.w("\n");
                    // A changed local can turn from an integer to a double
                    // on some paths; mark it as a double.
                    if (is_new) {
                        try g.locals.append(g.a, .{ name, false });
                    } else for (g.locals.items) |*l| {
                        if (std.mem.eql(u8, l[0], name)) l[1] = false;
                    }
                },
                3, 4 => if (level < 3) {
                    try g.w("if {");
                    try g.cond(2);
                    try g.w("} {\n");
                    try g.branch(level);
                    while (g.chance(30)) {
                        try g.indent(level);
                        try g.w("} elseif {");
                        try g.cond(2);
                        try g.w("} {\n");
                        try g.branch(level);
                    }
                    if (g.chance(50)) {
                        try g.indent(level);
                        try g.w("} else {\n");
                        try g.branch(level);
                    }
                    try g.indent(level);
                    try g.w("}\n");
                } else try g.w("skip\n"),
                5 => try g.w(if (level > 0 and g.chance(50)) "return\n" else "skip\n"),
                6 => {
                    try g.w("move ");
                    try g.value();
                    try g.w(" ");
                    try g.value();
                    try g.w("\n");
                },
                else => {
                    try g.w(g.pick(&.{ "offset ", "width ", "flow ", "speed " }));
                    try g.value();
                    try g.w("\n");
                },
            }
        }
    }

    fn branch(g: *Gen, level: u32) !void {
        const keep = g.locals.items.len;
        try g.block(level + 1, 1 + g.r.uintLessThan(usize, 3));
        // A local that starts in a branch is not set on all paths.
        g.locals.shrinkRetainingCapacity(keep);
    }
};

/// The Tcl text of a random point proc named `name`.
pub fn proc(a: Allocator, seed: u64, name: []const u8) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    var g: Gen = .{ .a = a, .r = prng.random() };
    for (fields) |f| if (g.chance(45)) try g.params.append(a, f);
    if (g.params.items.len == 0) try g.params.append(a, "x");
    g.has_feature = g.chance(60);
    try g.w("point proc ");
    try g.w(name);
    try g.w(" {");
    for (g.params.items, 0..) |p, i| {
        if (i > 0) try g.w(" ");
        try g.w(p);
    }
    if (g.has_feature) try g.w(" feature");
    try g.w("} {\n");
    try g.block(0, 2 + g.r.uintLessThan(usize, 6));
    try g.w("}\n");
    return g.out.toOwnedSlice(a);
}

test "the generator makes procs that pass the check" {
    const interp = @import("interp.zig");
    const point = @import("point.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ok: usize = 0;
    for (0..50) |seed| {
        var it: interp.Interp = undefined;
        try it.init(std.testing.allocator);
        defer it.deinit();
        var state: point.State = .{};
        try point.install(&it, &state);
        const text = try proc(arena.allocator(), seed, "f");
        if (it.eval(text)) |_| ok += 1 else |_| {}
    }
    try std.testing.expect(ok >= 35);
}

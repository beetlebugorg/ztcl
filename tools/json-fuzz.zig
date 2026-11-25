//! The fuzzer of the JSON parser.
//!
//!   zig build json-fuzz -- [--seconds N] [--count N] [--seed N]
//!
//! It makes random JSON texts from a small grammar and mutates them: a
//! byte flip, an insert, a delete, a cut, or a copy of a range. For each
//! input, the vector form and the scalar form of stage 1 must give the
//! same verdict and, for a valid input, the same value. `std.json.Scanner`
//! must give the same verdict, except for a text with a `\\u` escape of a
//! surrogate: std.json rejects a lone surrogate, and ztcl makes it U+FFFD. The run stops at the first
//! difference and prints the input as hex.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl");
const Io = std.Io;
const json = tcl.json;

const Gen = struct {
    r: std.Random,
    out: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,

    fn add(g: *Gen, s: []const u8) !void {
        try g.out.appendSlice(g.a, s);
    }

    fn ws(g: *Gen) !void {
        if (g.r.uintLessThan(u8, 4) == 0) try g.add(([_][]const u8{ " ", "\n", "\t", "\r\n  " })[g.r.uintLessThan(usize, 4)]);
    }

    fn str(g: *Gen) !void {
        try g.add("\"");
        const n = g.r.uintLessThan(usize, 12);
        for (0..n) |_| {
            const parts = [_][]const u8{ "a", "Z", " ", "\\\"", "\\\\", "\\n", "\\u00e9", "\\ud83d\\ude00", "\\ud800", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80", "/", "\\/" };
            try g.add(parts[g.r.uintLessThan(usize, parts.len)]);
        }
        try g.add("\"");
    }

    fn num(g: *Gen) !void {
        const parts = [_][]const u8{ "0", "-0", "1", "-12", "3.25", "1e10", "-1.5E-7", "123456789012345678901234", "9223372036854775807", "-9223372036854775809", "0.1", "2.2250738585072014e-308", "1e400", "17976931348623157e292" };
        try g.add(parts[g.r.uintLessThan(usize, parts.len)]);
    }

    fn val(g: *Gen, depth: u32) !void {
        try g.ws();
        const k = g.r.uintLessThan(u8, if (depth > 6) 6 else 8);
        switch (k) {
            0, 1 => try g.num(),
            2, 3 => try g.str(),
            4 => try g.add(([_][]const u8{ "true", "false", "null" })[g.r.uintLessThan(usize, 3)]),
            5 => try g.num(),
            6 => {
                try g.add("[");
                const n = g.r.uintLessThan(usize, 6);
                for (0..n) |i| {
                    if (i > 0) try g.add(",");
                    try g.val(depth + 1);
                }
                try g.ws();
                try g.add("]");
            },
            else => {
                try g.add("{");
                const n = g.r.uintLessThan(usize, 6);
                for (0..n) |i| {
                    if (i > 0) try g.add(",");
                    try g.ws();
                    try g.str();
                    try g.ws();
                    try g.add(":");
                    try g.val(depth + 1);
                }
                try g.ws();
                try g.add("}");
            },
        }
        try g.ws();
    }

    fn mutate(g: *Gen) !void {
        const n = g.r.uintLessThan(u8, 4);
        for (0..n) |_| {
            const len = g.out.items.len;
            if (len == 0) return;
            const at = g.r.uintLessThan(usize, len);
            switch (g.r.uintLessThan(u8, 5)) {
                0 => g.out.items[at] = "\"\\{}[]:,0e.-a \x00\xc3\x80\xff"[g.r.uintLessThan(usize, 18)],
                1 => try g.out.insert(g.a, at, "\"\\{}[]:,1"[g.r.uintLessThan(usize, 9)]),
                2 => _ = g.out.orderedRemove(at),
                3 => g.out.items.len = at,
                else => {
                    const end = at + g.r.uintLessThan(usize, @min(64, len - at) + 1);
                    const copy = try g.a.dupe(u8, g.out.items[at..end]);
                    defer g.a.free(copy);
                    try g.out.insertSlice(g.a, g.r.uintLessThan(usize, len), copy);
                },
            }
        }
    }
};

fn verdict(it: *tcl.Interp, text: []const u8, scalar: bool) !?[]const u8 {
    const v = json.build.parse(it, text, .{ .null_value = .{ .str = "null" }, .scalar = scalar }) catch |e| switch (e) {
        error.TclError => return null,
        else => return e,
    };
    return try it.str(v);
}

fn stdAccepts(a: std.mem.Allocator, text: []const u8) bool {
    var sc = std.json.Scanner.initCompleteInput(a, text);
    defer sc.deinit();
    var depth: usize = 0;
    while (true) {
        const t = sc.next() catch return false;
        switch (t) {
            .object_begin, .array_begin => depth += 1,
            .object_end, .array_end => depth -= 1,
            .end_of_document => return true,
            else => {},
        }
    }
}

fn hasSurrogate(text: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "\\u")) |at| : (i = at + 1) {
        if (at + 3 < text.len and (text[at + 2] == 'd' or text[at + 2] == 'D')) {
            switch (text[at + 3]) {
                '8', '9', 'a'...'f', 'A'...'F' => return true,
                else => {},
            }
        }
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var seconds: u64 = 10;
    var count: u64 = std.math.maxInt(u64);
    var seed: u64 = 1;
    var k: usize = 1;
    while (k + 1 < args.len) : (k += 2) {
        const v = try std.fmt.parseInt(u64, args[k + 1], 10);
        if (std.mem.eql(u8, args[k], "--seconds")) seconds = v else if (std.mem.eql(u8, args[k], "--count")) count = v else if (std.mem.eql(u8, args[k], "--seed")) seed = v else {
            std.debug.print("usage: json-fuzz [--seconds N] [--count N] [--seed N]\n", .{});
            std.process.exit(2);
        }
    }
    var prng = std.Random.DefaultPrng.init(seed);
    const start = Io.Clock.awake.now(io);
    var it: tcl.Interp = undefined;
    try it.init(a);
    defer it.deinit();
    var n: u64 = 0;
    var valid: u64 = 0;
    while (n < count) : (n += 1) {
        if (n % 256 == 0) {
            const secs = @divFloor(start.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_s);
            if (secs >= seconds) break;
            // A new interpreter now and then keeps the heap small.
            it.deinit();
            try it.init(a);
        }
        var g: Gen = .{ .r = prng.random(), .a = a };
        defer g.out.deinit(a);
        try g.val(0);
        if (g.r.boolean()) try g.mutate();
        const text = g.out.items;
        const x = try verdict(&it, text, false);
        const y = try verdict(&it, text, true);
        // std.json rejects a lone surrogate, and ztcl makes it U+FFFD.
        const s = if (hasSurrogate(text)) x != null else stdAccepts(a, text);
        const same_value = (x == null) == (y == null) and (x == null or std.mem.eql(u8, x.?, y.?));
        if (!same_value or (x != null) != s) {
            std.debug.print("difference after {d} inputs: vector {s}, scalar {s}, std.json {s}\ninput (hex): {x}\n", .{
                n, if (x != null) "accepts" else "rejects", if (y != null) "accepts" else "rejects", if (s) "accepts" else "rejects", text,
            });
            std.process.exit(1);
        }
        if (x != null) valid += 1;
    }
    std.debug.print("json-fuzz: {d} inputs, {d} valid, no difference\n", .{ n, valid });
}

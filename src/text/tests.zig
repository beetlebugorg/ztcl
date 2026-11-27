//! Tests of ztcl::text: the full GraphemeBreakTest, WordBreakTest, and
//! SentenceBreakTest files of Unicode 18.0.0, and the Tcl commands.
//!
//! A line of a test file is a list of code points in hex with "÷" (a
//! boundary) or "×" (no boundary) before and after each one. The test
//! makes the UTF-8 text and compares the boundaries of each segmenter
//! with the marks.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const seg = @import("seg.zig");

const Kind = enum { grapheme, word, sentence };

fn boundaries(kind: Kind, s: []const u8, out: *std.ArrayList(usize)) !void {
    const a = std.testing.allocator;
    out.clearRetainingCapacity();
    try out.append(a, 0);
    switch (kind) {
        .grapheme => {
            var i: usize = 0;
            while (i < s.len) {
                i = seg.graphemeEnd(s, i);
                try out.append(a, i);
            }
        },
        .word => {
            var w: seg.Words = .{ .s = s };
            while (w.next()) |_| try out.append(a, w.i);
        },
        .sentence => {
            var z: seg.Sentences = .{ .s = s };
            while (z.next()) |_| try out.append(a, z.i);
        },
    }
}

fn runFile(kind: Kind, data: []const u8) !void {
    const a = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var want: std.ArrayList(usize) = .empty;
    defer want.deinit(a);
    var got: std.ArrayList(usize) = .empty;
    defer got.deinit(a);
    var lines = std.mem.splitScalar(u8, data, '\n');
    var cases: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        text.clearRetainingCapacity();
        want.clearRetainingCapacity();
        var toks = std.mem.tokenizeAny(u8, line, " \t");
        while (toks.next()) |tok| {
            if (std.mem.eql(u8, tok, "÷")) {
                try want.append(a, text.items.len);
            } else if (std.mem.eql(u8, tok, "×")) {} else {
                const cp = try std.fmt.parseInt(u21, tok, 16);
                var buf: [4]u8 = undefined;
                const n = try std.unicode.wtf8Encode(cp, &buf);
                try text.appendSlice(a, buf[0..n]);
            }
        }
        try boundaries(kind, text.items, &got);
        std.testing.expectEqualSlices(usize, want.items, got.items) catch |e| {
            std.debug.print("{s} case: {s}\n", .{ @tagName(kind), line });
            return e;
        };
        // Each boundary inside the text is the start of the cluster
        // before the next byte, from any byte of that cluster.
        if (kind == .grapheme) {
            var k: usize = 1;
            while (k + 1 < got.items.len) : (k += 1) {
                try std.testing.expectEqual(got.items[k], seg.graphemeBefore(text.items, got.items[k + 1]));
            }
            try std.testing.expectEqual(got.items.len - 1, seg.count(text.items));
        }
        cases += 1;
    }
    try std.testing.expect(cases > 500);
}

test "GraphemeBreakTest-18.0.0" {
    try runFile(.grapheme, @embedFile("../testdata/unicode/GraphemeBreakTest.txt"));
}

test "WordBreakTest-18.0.0" {
    try runFile(.word, @embedFile("../testdata/unicode/WordBreakTest.txt"));
}

test "SentenceBreakTest-18.0.0" {
    try runFile(.sentence, @embedFile("../testdata/unicode/SentenceBreakTest.txt"));
}

test "the vector path and the scalar walk give the same clusters" {
    // Each prefix of a mixed text, so each block edge falls on each byte.
    const parts = [_][]const u8{ "a", "\r\n", "\u{e9}", "e\u{301}", " ", "\u{1F44D}\u{1F3FD}", "\u{2CF}", "\r", "\n", "\u{2FF}", "x" };
    var buf: [600]u8 = undefined;
    var n: usize = 0;
    var r: u32 = 7;
    while (n + 8 < buf.len) {
        r = r *% 1103515245 +% 12345;
        const p = parts[(r >> 16) % parts.len];
        @memcpy(buf[n .. n + p.len], p);
        n += p.len;
    }
    var end: usize = 1;
    while (end <= n) : (end += 1) {
        const s = buf[0..end];
        var walk: usize = 0;
        var i: usize = 0;
        while (i < s.len) : (walk += 1) i = seg.graphemeEnd(s, i);
        try std.testing.expectEqual(walk, seg.count(s));
        if (end % 13 != 0) continue;
        var j: usize = 0;
        var k: usize = 0;
        while (k <= walk) : (k += 1) {
            try std.testing.expectEqual(j, seg.skip(s, 0, k).pos);
            if (j < s.len) j = seg.graphemeEnd(s, j);
        }
    }
}

test "the ASCII skip of sentences gives the same sentences" {
    const parts = [_][]const u8{ "Mr. ", "Smith ", "went ", "to ", "Washington", ". ", "He ", "said: \"Hi!\" ", "3.14 ", "is ", "pi? ", "e.g. ", "x\u{301} ", "\r\n", "\n", "(Yes.) ", "ok", "\u{3002}", "a.b ", "ETC. ", "end. lower " };
    var buf: [4000]u8 = undefined;
    var r: u32 = 11;
    for (0..20) |_| {
        var n: usize = 0;
        while (n + 16 < buf.len) {
            r = r *% 1103515245 +% 12345;
            const p = parts[(r >> 16) % parts.len];
            @memcpy(buf[n .. n + p.len], p);
            n += p.len;
        }
        var a: seg.Sentences = .{ .s = buf[0..n] };
        var b: seg.Sentences = .{ .s = buf[0..n], .fast = false };
        while (true) {
            const x = a.next();
            const y = b.next();
            try std.testing.expectEqual(y == null, x == null);
            if (x == null) break;
            try std.testing.expectEqual(y.?.len, x.?.len);
        }
    }
}

test {
    _ = seg;
}

const tcl = @import("../ztcl.zig");

fn eval(script: []const u8, want: []const u8) !void {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    it.compute_limit = 50_000_000;
    const got = if (it.eval(script)) |v| try it.str(v) else |e| blk: {
        if (e != error.TclError) return e;
        break :blk try std.fmt.allocPrint(it.alloc(), "!{s}", .{try it.str(it.result)});
    };
    std.testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("script: {s}\n", .{script});
        return e;
    };
}

test "the commands of ztcl::text" {
    try eval("package require ztcl::text; llength [ztcl::text graphemes \"e\\u0301\\U1F1FA\\U1F1F8\\U1F468\\u200D\\U1F469\"]", "3");
    try eval("package require ztcl::text; ztcl::text words {Don't stop: 3.14 is pi.}", "Don't stop 3.14 is pi");
    try eval("package require ztcl::text; join [ztcl::text words -all {a, b}] |", "a|,| |b");
    try eval("package require ztcl::text; ztcl::text sentences {It is 3.5 m long. Is it? Yes.}", "{It is 3.5 m long. } {Is it? } Yes.");
    try eval("package require ztcl::text; ztcl::text width \"ab\\u4E2D\\u2764\\uFE0F\"", "6");
    try eval("package require ztcl::text; ztcl::text width -ambiguous wide \\u00B1", "2");
    try eval("package require ztcl::text; ztcl::text bounds \"ae\\u0301b\"", "0 1 3 4");
    try eval("package require ztcl::text; ztcl::text bounds -unit sentence {}", "0");
    try eval("package require ztcl::text; ztcl::text width -ambiguous big a", "!bad value \"big\": must be narrow or wide");
    try eval("package require ztcl::text; ztcl::text bounds -unit line a", "!bad unit \"line\": must be grapheme, word, or sentence");
}

test "the -grapheme forms of string and split" {
    try eval("string length -grapheme \"na\\u0303o\"", "3");
    try eval("string equal [string index -grapheme \"na\\u0303o\" 1] \"a\\u0303\"", "1");
    try eval("string index -grapheme \"na\\u0303o\" end", "o");
    try eval("string index -grapheme abc 5", "");
    try eval("string equal [string range -grapheme \"na\\u0303o\" 1 end] \"a\\u0303o\"", "1");
    try eval("string range -grapheme abc 2 1", "");
    try eval("string equal [string reverse -grapheme \"na\\u0303o\"] \"oa\\u0303n\"", "1");
    try eval("llength [split \"na\\u0303o\" {} -grapheme]", "3");
    try eval("llength [split \"a,b,\\u0301c\" , -grapheme]", "2");
    // The plain forms keep the behavior of Tcl.
    try eval("string length -grapheme", "9");
    try eval("split a-grapheme -grapheme", "{} {} {} {} {} {} {} {} {} {} {}");
    try eval("string length \"na\\u0303o\"", "4");
}

test "the grapheme marks of a long string" {
    // 8,000 clusters of 1 to 3 code points: each index from the marks
    // equals the walk from the start.
    try eval(
        \\set s [string repeat "áb\U1F44D\U1F3FD " 2000]
        \\set ok 1
        \\foreach i {0 1 63 64 65 127 128 4001 7998 7999 8000} {
        \\    set want [lindex [split $s {} -grapheme] $i]
        \\    if {[string index -grapheme $s $i] ne $want} {set ok "index $i"}
        \\}
        \\if {[string range -grapheme $s 64 67] ne [join [lrange [split $s {} -grapheme] 64 67] {}]} {set ok range}
        \\list $ok [string length -grapheme $s]
    , "1 8000");
}

test "the widths equal the cursor moves of libghostty-vt" {
    if (comptime !@import("build_options").mod_vt) return;
    try eval(
        \\package require ztcl::vt
        \\package require ztcl::text
        \\set samples [list a é 中 \U1F600 ❤ ❤️ ☺️ \U1F600︎ \U1F1FA\U1F1F8 \U1F1FA \
        \\    \U1F468‍\U1F469‍\U1F467 \U1F44D\U1F3FD \U1F3FD ± ­ ​ 각 가 \
        \\    क्ष कि #️⃣ กำ Ａ 　 ́ a‍b é \
        \\    \U1F9D1‍\U1F4BB ☁ ☁️ ⌚ \U1F170 \U1F170️ "ab 中文 é \U1F44D\U1F3FD"]
        \\set bad {}
        \\foreach s $samples {
        \\    set t [ztcl::vt new -size {40 2}]
        \\    ztcl::vt feed $t "\x1b\[?2027h$s"
        \\    set x [lindex [ztcl::vt cursor $t] 0]
        \\    ztcl::vt delete $t
        \\    if {$x != [ztcl::text width $s]} {lappend bad $s}
        \\}
        \\llength $bad
    , "0");
}

test "a cell of ztcl::vt has the whole cluster" {
    if (comptime !@import("build_options").mod_vt) return;
    try eval(
        \\package require ztcl::vt
        \\set t [ztcl::vt new -size {10 1}]
        \\ztcl::vt feed $t "é\U1F468‍\U1F469‍\U1F467x"
        \\set c [lindex [ztcl::vt cells $t 0] 0]
        \\list [string equal [lindex $c 0 0] "é"] [string equal [lindex $c 1 0] "\U1F468‍\U1F469‍\U1F467"] [lindex $c 1 1] [lindex $c 3 0] [ztcl::vt cursor $t]
    , "1 1 2 x {4 0}");
}

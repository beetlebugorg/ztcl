//! The tests of the JSON parser: the two forms of stage 1, the values of
//! stage 2, the errors, and the limits.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const index = @import("index.zig");
const build = @import("build.zig");

test {
    _ = @import("number.zig");
}
const Interp = @import("../interp.zig").Interp;
const Value = @import("../value.zig").Value;

/// The positions of both forms of stage 1, and the fault of each.
fn positions(input: []const u8, scalar: bool, out: *std.ArrayList(u32)) !index.Fault {
    const a = std.testing.allocator;
    const buf = try a.alloc(u32, index.buf_len);
    defer a.free(buf);
    if (scalar) {
        var s = index.Scalar.init(input);
        while (!s.done() and s.fault == .none) try out.appendSlice(a, buf[0..s.next(buf)]);
        return s.fault;
    }
    var v = index.Indexer.init(input);
    while (!v.done() and v.fault == .none) try out.appendSlice(a, buf[0..v.next(buf)]);
    return v.fault;
}

fn expectSameIndex(input: []const u8) !void {
    const a = std.testing.allocator;
    var x: std.ArrayList(u32) = .empty;
    defer x.deinit(a);
    var y: std.ArrayList(u32) = .empty;
    defer y.deinit(a);
    const fx = try positions(input, false, &x);
    const fy = try positions(input, true, &y);
    try std.testing.expectEqual(fx == .none, fy == .none);
    if (fx == .none) try std.testing.expectEqualSlices(u32, y.items, x.items);
}

test "both forms of stage 1 give the same positions" {
    const cases = [_][]const u8{
        "{\"a\":1,\"b\":[true,false,null],\"c\":\"x\\\"y\"}",
        "[\"\\\\\",\"\\\\\\\"\",1e5,-0.5]",
        "  [ 1 , 2 ]  ",
        "\"abc",
        "\"a\x01b\"",
        "[\"\xe2\x82\xac\", \"\xf0\x9f\x98\x80\"]",
        "[\"\xc3\x28\"]",
        "\\\"x\" 1",
    };
    for (cases) |c| try expectSameIndex(c);
    // Random inputs from a small alphabet, with runs of backslashes over
    // the edges of the blocks.
    var prng = std.Random.DefaultPrng.init(27);
    const r = prng.random();
    const alphabet = "\\\\\\\"\"{}[]:, a1\n\xc3\xa9";
    var buf: [700]u8 = undefined;
    for (0..3000) |_| {
        const len = r.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        try expectSameIndex(buf[0..len]);
    }
}

fn parseText(it: *Interp, text: []const u8, opts: build.Options) ![]const u8 {
    const v = try build.parse(it, text, opts);
    return it.str(v);
}

test "values of the parser" {
    var it: Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const n: build.Options = .{ .null_value = .{ .str = "null" } };
    const cases = [_][2][]const u8{
        .{ "{\"a\":1,\"b\":[1,2.5,\"x y\"],\"c\":{\"d\":true}}", "a 1 b {1 2.5 {x y}} c {d true}" },
        .{ "[]", "" },
        .{ "{}", "" },
        .{ "[[],{}]", "{} {}" },
        .{ "\"a\\n\\u00e9\\ud83d\\ude00\\\"\"", "a\n\xc3\xa9\xf0\x9f\x98\x80\"" },
        .{ "\"\\ud800x\"", "\xef\xbf\xbdx" },
        .{ "[0,-0,123456789012345678901234567890,-9223372036854775808,9223372036854775807]", "0 0 123456789012345678901234567890 -9223372036854775808 9223372036854775807" },
        .{ "[1.0,1e2,0.1,-2.5E-3,1E400]", "1.0 100.0 0.1 -0.0025 Inf" },
        .{ "[9223372036854775808]", "9223372036854775808" },
        .{ "{\"a\":1,\"b\":2,\"a\":3}", "a 3 b 2" },
        .{ "[null]", "null" },
        .{ " 7 ", "7" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], try parseText(&it, c[0], n));
    // A dict of many keys with one key twice.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.append(std.testing.allocator, '{');
    for (0..40) |i| try text.print(std.testing.allocator, "\"k{d}\":{d},", .{ i, i });
    try text.appendSlice(std.testing.allocator, "\"k3\":99}");
    const v = try build.parse(&it, text.items, n);
    try std.testing.expectEqual(@as(usize, 80), v.list.len);
    try std.testing.expectEqual(@as(i64, 99), v.list.items()[7].int);
    try std.testing.expectEqual(@as(usize, 80), v.list.obj.dict_len);
}

test "errors of the parser" {
    var it: Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const bad = [_][]const u8{ "", "[", "]", "[1,]", "{\"a\"}", "{\"a\":}", "[01]", "[1.]", "[.5]", "tru", "truex", "[1 2]", "\"\\x\"", "[\"a\" 1]", "{1:2}", "[1]x", "-", "[1e]", "nul", "\"\\u12g4\"" };
    for (bad) |b| {
        try std.testing.expectError(error.TclError, build.parse(&it, b, .{ .null_value = Value.empty }));
        try std.testing.expectError(error.TclError, build.validate(&it, b, .{}));
    }
    try std.testing.expectError(error.TclError, build.parse(&it, "[null]", .{}));
    try std.testing.expectEqualStrings("ZT JSON NULL", try it.str(it.error_code));
    try std.testing.expectError(error.TclError, build.parse(&it, "[1,\n  x]", .{}));
    try std.testing.expectEqualStrings("ZT JSON SYNTAX 2 3", try it.str(it.error_code));
}

test "the depth limit" {
    var it: Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const a = std.testing.allocator;
    const deep = try a.alloc(u8, 200_000);
    defer a.free(deep);
    @memset(deep[0..100_000], '[');
    @memset(deep[100_000..], ']');
    try std.testing.expectError(error.TclError, build.parse(&it, deep, .{}));
    try std.testing.expectEqualStrings("ZT JSON DEPTH", try it.str(it.error_code));
    // 512 levels pass, and 513 levels fail.
    try std.testing.expectEqual(@as(usize, 1), (try build.parse(&it, deep[100_000 - 512 .. 100_000 + 512], .{})).list.len);
    try std.testing.expectError(error.TclError, build.parse(&it, deep[100_000 - 513 .. 100_000 + 513], .{}));
}

test "the compute limit and the memory limit stop a large parse early" {
    const a = std.testing.allocator;
    // 16 MiB of "[1,1,1,...]".
    const size = 16 << 20;
    const text = try a.alloc(u8, size);
    defer a.free(text);
    var i: usize = 1;
    text[0] = '[';
    while (i + 2 < size) : (i += 2) {
        text[i] = '1';
        text[i + 1] = ',';
    }
    text[i] = '1';
    text[size - 1] = ']';
    {
        var it: Interp = undefined;
        try it.init(a);
        defer it.deinit();
        it.compute_limit = 5000;
        var p = try build.Parser(.build).init(&it, text, .{});
        try std.testing.expectError(error.TclError, p.document());
        try std.testing.expectEqual(@as(u64, 0), it.compute_limit);
        // A chunk of 64 KiB has 32 768 values. The safe point before the
        // second chunk pays them, so the parse stops after two chunks.
        try std.testing.expect(p.s.vec.pos <= 2 * 64 * 1024);
    }
    {
        var it: Interp = undefined;
        try it.init(a);
        defer it.deinit();
        it.mem_limit = 4 << 20;
        var p = try build.Parser(.build).init(&it, text, .{});
        // The memory limit, or a request above the hard cap of the counter.
        if (p.document()) |_| return error.TestUnexpectedResult else |e| try std.testing.expect(e == error.TclError or e == error.OutOfMemory);
        try std.testing.expect(it.overLimit());
        // Each chunk makes about 512 KiB of values, so the parse stops
        // at most a few chunks after the limit.
        try std.testing.expect(p.s.vec.pos <= 16 * 64 * 1024);
    }
}

test "a path query" {
    var it: Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const text = "{\"a\":{\"b\":[10,{\"c\":\"x\"},[1,2]]},\"d\":[{\"e\":1}],\"a\":{\"b\":[20,{\"c\":\"last\"}]}}";
    const v = (try build.get(&it, text, &.{ "a", "b", "1", "c" }, .{})).?;
    try std.testing.expectEqualStrings("last", try it.str(v));
    const w = (try build.get(&it, text, &.{ "d", "0" }, .{})).?;
    try std.testing.expectEqualStrings("e 1", try it.str(w));
    try std.testing.expect((try build.get(&it, text, &.{ "d", "3" }, .{})) == null);
    try std.testing.expect((try build.get(&it, text, &.{"z"}, .{})) == null);
}

test "the UTF-8 check agrees with std.unicode" {
    const a = std.testing.allocator;
    const bytes = [_]u8{ 'a', ' ', 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF, 0xE0, 0xE1, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF4, 0xF5, 0xFF };
    var prng = std.Random.DefaultPrng.init(3629);
    const r = prng.random();
    var buf: [300]u8 = undefined;
    const out = try a.alloc(u32, index.buf_len);
    defer a.free(out);
    for (0..200_000) |_| {
        // A string with a random body. The body starts at a random place
        // so its sequences cross the edges of the blocks.
        const pad = r.uintLessThan(usize, 64);
        const len = r.uintLessThan(usize, 12);
        @memset(buf[0..pad], ' ');
        buf[pad] = '"';
        for (buf[pad + 1 .. pad + 1 + len]) |*b| b.* = bytes[r.uintLessThan(usize, bytes.len)];
        buf[pad + 1 + len] = '"';
        const text = buf[0 .. pad + 2 + len];
        var ix = index.Indexer.init(text);
        while (!ix.done() and ix.fault == .none) _ = ix.next(out);
        const ok = std.unicode.utf8ValidateSlice(buf[pad + 1 .. pad + 1 + len]);
        try std.testing.expectEqual(ok, ix.fault != .utf8);
    }
}

test "a path query keeps its memory below two times the input" {
    const a = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try text.appendSlice(a, "{\"performances\":[");
    for (0..20000) |i| {
        if (i > 0) try text.append(a, ',');
        try text.print(a, "{{\"id\":{d},\"name\":\"show {d}\",\"seats\":[1,2,3,4],\"venueCode\":\"V{d}\"}}", .{ i, i, i % 7 });
    }
    try text.appendSlice(a, "],\"end\":1}");
    var it: Interp = undefined;
    try it.init(a);
    defer it.deinit();
    const base = it.counter.used;
    it.counter.mem_peak = base;
    const v = (try build.get(&it, text.items, &.{ "performances", "19000", "venueCode" }, .{})).?;
    try std.testing.expectEqualStrings("V2", try it.str(v));
    try std.testing.expect(it.counter.mem_peak - base < 2 * text.items.len);
}

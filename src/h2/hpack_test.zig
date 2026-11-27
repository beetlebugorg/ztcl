//! The tests of `hpack.zig`: the examples of RFC 7541 appendix C byte
//! for byte, round trips of random fields, and bad blocks.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const hpack = @import("hpack.zig");
const tables = @import("hpack_tables.zig");
const testing = std.testing;

test "C.1: integers" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{0x0a}, buf[0..hpack.writeInt(&buf, 10, 5, 0)]);
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x9a, 0x0a }, buf[0..hpack.writeInt(&buf, 1337, 5, 0)]);
    try testing.expectEqualSlices(u8, &.{0x2a}, buf[0..hpack.writeInt(&buf, 42, 8, 0)]);
    var pos: usize = 0;
    try testing.expectEqual(1337, try hpack.readInt(&.{ 0x1f, 0x9a, 0x0a }, &pos, 5));
    try testing.expectEqual(3, pos);
    for ([_]u32{ 0, 30, 31, 127, 128, 1337, 1 << 20, std.math.maxInt(u32) }) |v| {
        const n = hpack.writeInt(&buf, v, 5, 0xe0);
        try testing.expectEqual(n, hpack.intLen(v, 5));
        pos = 0;
        try testing.expectEqual(v, try hpack.readInt(buf[0..n], &pos, 5));
    }
    pos = 0;
    try testing.expectError(error.IntegerOverflow, hpack.readInt(&.{ 0x1f, 0xff, 0xff, 0xff, 0xff, 0x7f }, &pos, 5));
    pos = 0;
    try testing.expectError(error.Truncated, hpack.readInt(&.{ 0x1f, 0x9a }, &pos, 5));
}

test "C.2: one field of each representation" {
    const gpa = testing.allocator;
    var d = try hpack.Decoder.init(gpa, 4096, 1 << 16);
    defer d.deinit(gpa);
    var scratch: [256]u8 = undefined;
    // C.2.1, C.2.2, C.2.3, C.2.4.
    const blocks = [_][]const u8{
        "\x40\x0acustom-key\x0dcustom-header",
        "\x04\x0c/sample/path",
        "\x10\x08password\x06secret",
        "\x82",
    };
    const want = [_][2][]const u8{ .{ "custom-key", "custom-header" }, .{ ":path", "/sample/path" }, .{ "password", "secret" }, .{ ":method", "GET" } };
    for (blocks, want, 0..) |blk, w, i| {
        var b = d.block(blk, &scratch);
        const f = (try b.next()).?;
        try testing.expectEqualStrings(w[0], f.name);
        try testing.expectEqualStrings(w[1], f.value);
        try testing.expectEqual(i == 2, f.never_index);
        try testing.expectEqual(null, try b.next());
    }
    try testing.expectEqual(55, d.table.size);
}

test "C.3 to C.6: the examples byte for byte" {
    const gpa = testing.allocator;
    var g: usize = 0;
    while (g < 4) : (g += 1) {
        const cap: usize = if (g >= 2) 256 else 4096;
        const huff: hpack.Huffman = if (g % 2 == 1) .always else .never;
        var e = try hpack.Encoder.init(gpa, cap);
        defer e.deinit(gpa);
        e.huffman = huff;
        var d = try hpack.Decoder.init(gpa, cap, 1 << 16);
        defer d.deinit(gpa);
        for (tables.examples[3 * g ..][0..3]) |ex| {
            var out: [512]u8 = undefined;
            const n = try e.encode(&out, ex.headers);
            testing.expectEqualSlices(u8, ex.encoded, out[0..n]) catch |err| {
                std.debug.print("{s}\n", .{ex.name});
                return err;
            };
            var scratch: [512]u8 = undefined;
            var b = d.block(ex.encoded, &scratch);
            for (ex.headers) |h| {
                const f = (try b.next()).?;
                try testing.expectEqualStrings(h.name, f.name);
                try testing.expectEqualStrings(h.value, f.value);
            }
            try testing.expectEqual(null, try b.next());
            for (&[_]*const hpack.Table{ &e.table, &d.table }) |t| {
                try testing.expectEqual(ex.table_size, t.size);
                try testing.expectEqual(ex.table.len, t.count);
                for (ex.table, 0..) |want, i| {
                    const got = try t.get(62 + i);
                    try testing.expectEqualStrings(want.name, got.name);
                    try testing.expectEqualStrings(want.value, got.value);
                }
            }
        }
    }
}

test "the Huffman code: each byte value, and bad padding" {
    var s: [256]u8 = undefined;
    for (&s, 0..) |*b, i| b.* = @intCast(i);
    var enc: [1024]u8 = undefined;
    const n = hpack.huffmanEncode(&enc, &s);
    try testing.expectEqual(hpack.huffmanLen(&s), n);
    var out: [256]u8 = undefined;
    try testing.expectEqualSlices(u8, &s, try hpack.huffmanDecode(&out, enc[0..n]));
    // "www.example.com" of C.4.1.
    try testing.expectEqualStrings("www.example.com", try hpack.huffmanDecode(&out, "\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff"));
    // Padding of 8 bits.
    try testing.expectError(error.BadHuffman, hpack.huffmanDecode(&out, "\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff\xff"));
    // Padding with a zero bit: "a" is 00011, then 000 is not all ones.
    try testing.expectError(error.BadHuffman, hpack.huffmanDecode(&out, "\x18"));
    // EOS in the string.
    try testing.expectError(error.BadHuffman, hpack.huffmanDecode(&out, "\xff\xff\xff\xff"));
    try testing.expectError(error.NoScratch, hpack.huffmanDecode(out[0..3], "\xf1\xe3\xc2\xe5"));
}

test "round trips of random fields with a small table" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x4a9c);
    const r = prng.random();
    for ([_]usize{ 0, 64, 256, 4096 }) |cap| {
        var e = try hpack.Encoder.init(gpa, cap);
        defer e.deinit(gpa);
        var d = try hpack.Decoder.init(gpa, cap, 1 << 20);
        defer d.deinit(gpa);
        var names: [8][16]u8 = undefined;
        for (&names) |*n| for (n) |*c| {
            c.* = 'a' + r.uintLessThan(u8, 26);
        };
        for (0..300) |round| {
            if (round % 50 == 49) e.setMax(r.uintLessThan(usize, cap + 1));
            var vals: [10][40]u8 = undefined;
            var fields: [10]hpack.Field = undefined;
            const nf = r.uintLessThan(usize, 10) + 1;
            for (fields[0..nf], vals[0..nf]) |*f, *v| {
                r.bytes(v);
                const vl = r.uintLessThan(usize, 41);
                if (r.boolean()) for (v[0..vl]) |*c| {
                    c.* = 'a' + c.* % 26;
                };
                f.* = if (r.uintLessThan(u8, 4) == 0)
                    tables.static[r.uintLessThan(usize, 61)]
                else
                    .{ .name = names[r.uintLessThan(usize, 8)][0 .. r.uintLessThan(usize, 16) + 1], .value = v[0..vl] };
            }
            e.huffman = r.enumValue(hpack.Huffman);
            var out: [2048]u8 = undefined;
            const n = try e.encode(&out, fields[0..nf]);
            var scratch: [256]u8 = undefined;
            var b = d.block(out[0..n], &scratch);
            for (fields[0..nf]) |f| {
                const got = (try b.next()).?;
                try testing.expectEqualStrings(f.name, got.name);
                try testing.expectEqualStrings(f.value, got.value);
            }
            try testing.expectEqual(null, try b.next());
            try testing.expectEqual(e.table.size, d.table.size);
        }
    }
}

test "bad blocks give errors" {
    const gpa = testing.allocator;
    var d = try hpack.Decoder.init(gpa, 4096, 100);
    defer d.deinit(gpa);
    var scratch: [64]u8 = undefined;
    const cases = [_]struct { []const u8, anyerror }{
        .{ "\x80", error.BadIndex },
        .{ "\xbe", error.BadIndex },
        .{ "\x40\x0acustom", error.Truncated },
        .{ "\x82\x3f\xe1\x1f", error.BadTableSizeUpdate },
        .{ "\x3f\xe2\x1f", error.BadTableSizeUpdate },
        // A field of 10 + 90 + 32 bytes: past the limit of 100.
        .{ "\x00\x0acustom-key\x5a" ++ &@as([90]u8, @splat('v')), error.HeaderListTooLarge },
    };
    for (cases) |c| {
        var b = d.block(c[0], &scratch);
        const got = while (true) {
            const f = b.next() catch |err| break err;
            if (f == null) break error.NoError;
        };
        try testing.expectEqual(c[1], got);
    }
}

test "garbage blocks do not crash" {
    const gpa = testing.allocator;
    var d = try hpack.Decoder.init(gpa, 256, 4096);
    defer d.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var buf: [64]u8 = undefined;
    var scratch: [128]u8 = undefined;
    for (0..20_000) |_| {
        const n = r.uintLessThan(usize, buf.len);
        r.bytes(buf[0..n]);
        var b = d.block(buf[0..n], &scratch);
        while (true) {
            const f = b.next() catch break;
            if (f == null) break;
        }
    }
}

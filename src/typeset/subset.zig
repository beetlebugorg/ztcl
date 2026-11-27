//! The subset of a TrueType font for a PDF: the glyphs of a page set,
//! with their glyph numbers kept, so the PDF uses the identity map from
//! CID to glyph. The glyphs that the document does not use are empty.
//!
//! The closure adds the components of each composite glyph, to a depth
//! of 8. The output has the tables head, hhea, maxp, hmtx, loca, glyf,
//! and the hint tables cvt, fpgm, and prep when the font has them
//! (the section "Embedded font programs" of ISO 32000-2 names these tables).
//! The glyph count ends after the last glyph in use. The loca table
//! has the long form, and each table has its checksum.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ttf = @import("ttf.zig");

const be16 = ttf.be16;

const keep_tables = [_]*const [4]u8{ "cvt ", "fpgm", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "prep" };

/// Adds the components of composite glyphs to `used`.
fn closure(face: *const ttf.Face, used: []bool) void {
    var depth: usize = 0;
    var changed = true;
    while (changed and depth < 8) : (depth += 1) {
        changed = false;
        for (used, 0..) |u, g| {
            if (!u) continue;
            const d = face.glyphData(@intCast(g)) catch continue;
            if (d.len < 10) continue;
            const contours: i16 = @bitCast(be16(d, 0) catch continue);
            if (contours >= 0) continue;
            var at: usize = 10;
            var n: usize = 0;
            while (n < 64) : (n += 1) {
                const flags = be16(d, at) catch break;
                const comp = be16(d, at + 2) catch break;
                if (comp < used.len and !used[comp]) {
                    used[comp] = true;
                    changed = true;
                }
                at += 4;
                at += if (flags & 0x0001 != 0) 4 else 2;
                if (flags & 0x0008 != 0) at += 2 else if (flags & 0x0040 != 0) at += 4 else if (flags & 0x0080 != 0) at += 8;
                if (flags & 0x0020 == 0) break;
            }
        }
    }
}

/// The font program with only the glyphs of `used_in` (glyph 0 is always
/// in). The caller frees the result.
pub fn subset(gpa: std.mem.Allocator, face: *const ttf.Face, used_in: []const bool) ![]u8 {
    const data = face.data;
    const used = try gpa.alloc(bool, face.glyph_count);
    defer gpa.free(used);
    @memset(used, false);
    for (used_in, 0..) |u, i| if (u and i < used.len) {
        used[i] = true;
    };
    used[0] = true;
    closure(face, used);
    var last: usize = 0;
    for (used, 0..) |u, i| if (u) {
        last = i;
    };
    const count = last + 1;

    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(gpa);
    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(gpa);
    for (0..count) |g| {
        try appendBe32(gpa, &loca, @intCast(glyf.items.len));
        if (!used[g]) continue;
        const d = face.glyphData(@intCast(g)) catch continue;
        try glyf.appendSlice(gpa, d);
        while (glyf.items.len % 4 != 0) try glyf.append(gpa, 0);
    }
    try appendBe32(gpa, &loca, @intCast(glyf.items.len));

    const nh: usize = @min(face.num_hmetrics, count);
    var hmtx: std.ArrayList(u8) = .empty;
    defer hmtx.deinit(gpa);
    try hmtx.appendSlice(gpa, face.hmtx[0 .. nh * 4]);
    // The glyphs after the long metrics have only a left side bearing.
    for (nh..count) |g| {
        const off = @as(usize, face.num_hmetrics) * 4 + (g - face.num_hmetrics) * 2;
        if (off + 2 <= face.hmtx.len) try hmtx.appendSlice(gpa, face.hmtx[off .. off + 2]) else try hmtx.appendSlice(gpa, &.{ 0, 0 });
    }

    const Table = struct { tag: *const [4]u8, bytes: []u8 };
    var tables: std.ArrayList(Table) = .empty;
    defer {
        for (tables.items) |t| gpa.free(t.bytes);
        tables.deinit(gpa);
    }
    for (keep_tables) |tag| {
        const bytes: []u8 = if (std.mem.eql(u8, tag, "glyf"))
            try gpa.dupe(u8, glyf.items)
        else if (std.mem.eql(u8, tag, "loca"))
            try gpa.dupe(u8, loca.items)
        else if (std.mem.eql(u8, tag, "hmtx"))
            try gpa.dupe(u8, hmtx.items)
        else blk: {
            const src = (ttf.Face.table(data, tag) catch null) orelse continue;
            const copy = try gpa.dupe(u8, src);
            if (std.mem.eql(u8, tag, "head") and copy.len >= 54) {
                @memset(copy[8..12], 0); // checkSumAdjustment
                copy[50] = 0;
                copy[51] = 1; // the long form of loca
            } else if (std.mem.eql(u8, tag, "maxp") and copy.len >= 6) {
                std.mem.writeInt(u16, copy[4..6], @intCast(count), .big);
            } else if (std.mem.eql(u8, tag, "hhea") and copy.len >= 36) {
                std.mem.writeInt(u16, copy[34..36], @intCast(nh), .big);
            }
            break :blk copy;
        };
        try tables.append(gpa, .{ .tag = tag, .bytes = bytes });
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const n: u16 = @intCast(tables.items.len);
    var pow: u16 = 1;
    var log: u16 = 0;
    while (pow * 2 <= n) : (log += 1) pow *= 2;
    try appendBe32(gpa, &out, 0x00010000);
    try appendBe16(gpa, &out, n);
    try appendBe16(gpa, &out, pow * 16);
    try appendBe16(gpa, &out, log);
    try appendBe16(gpa, &out, n * 16 - pow * 16);
    var off: usize = 12 + @as(usize, n) * 16;
    for (tables.items) |t| {
        try out.appendSlice(gpa, t.tag);
        try appendBe32(gpa, &out, checksum(t.bytes));
        try appendBe32(gpa, &out, @intCast(off));
        try appendBe32(gpa, &out, @intCast(t.bytes.len));
        off += (t.bytes.len + 3) & ~@as(usize, 3);
    }
    for (tables.items) |t| {
        try out.appendSlice(gpa, t.bytes);
        while (out.items.len % 4 != 0) try out.append(gpa, 0);
    }
    return out.toOwnedSlice(gpa);
}

fn checksum(b: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < b.len) : (i += 4) {
        var w: [4]u8 = .{ 0, 0, 0, 0 };
        const n = @min(4, b.len - i);
        @memcpy(w[0..n], b[i .. i + n]);
        sum +%= std.mem.readInt(u32, &w, .big);
    }
    return sum;
}

fn appendBe16(gpa: std.mem.Allocator, l: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try l.appendSlice(gpa, &b);
}

fn appendBe32(gpa: std.mem.Allocator, l: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try l.appendSlice(gpa, &b);
}

//! Paragraphs for any output: the words of a plain text, broken into
//! lines of one width, with the place of each word on its line.
//!
//! The width of a word comes from a font and a size, or, with no font,
//! from the count of its characters (a monospace grid, for a terminal or
//! a README). Between two words is glue: the width of a space that can
//! stretch by half and shrink by a third (no shrink on a grid). The
//! patterns of `hyph.zig` give the places where a word can take a hyphen.
//!
//! Two methods break the lines. `total` is the total-fit algorithm of
//! Knuth and Plass (`knuth.zig`): it looks at the whole paragraph and
//! picks the breaks with the fewest demerits, so the spaces of the lines
//! stay even. `greedy` (first fit) fills each line as full as it can
//! and goes to the next line, as most text editors and browsers do.
//!
//! After the breaks, each line gets its words and their x positions for
//! the alignment: `justify` (each line but the last fills the width),
//! `left`, `right`, or `center`. On a grid, each space has a whole
//! number of characters: the extra spaces of a justified line go to the
//! gaps from the left, one each, in turn.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const knuth = @import("knuth.zig");
const hyph = @import("hyph.zig");
const Font = @import("font.zig").Font;

pub const Method = enum { total, greedy };
pub const Align = enum { justify, left, right, center };

pub const Options = struct {
    width: f32,
    /// null: a grid of characters, each one unit wide.
    font: ?*const Font = null,
    size: f32 = 1,
    method: Method = .total,
    hyphenate: bool = true,
    hy: ?*const hyph.Hyphenator = null,
    indent: f32 = 0,
    tolerance: f32 = 200,
    @"align": Align = .justify,
    max_steps: usize = 50_000_000,
};

pub const Word = struct { text: []const u8, x: f32, width: f32 };

pub const Line = struct {
    words: []Word,
    /// The line ends with a hyphen (in the text of the last word).
    hyphen: bool,
    /// The adjustment ratio of the glue: 0 is the natural width, 1 is
    /// all of the stretch, -1 all of the shrink.
    ratio: f32,
    /// The width of the line from the left of the first word to the
    /// right of the last word.
    width: f32,
};

pub const Result = struct { lines: []Line, steps: usize };

fn graphemes(s: []const u8) f32 {
    return @floatFromInt(std.unicode.utf8CountCodepoints(s) catch s.len);
}

fn widthOf(a: std.mem.Allocator, o: Options, s: []const u8) !f32 {
    const f = o.font orelse return graphemes(s);
    const g = try f.shape(a, s, true);
    var w: i64 = 0;
    for (g) |x| w += x.advance;
    return @as(f32, @floatFromInt(w)) * o.size / f.unitsPerEm();
}

/// Breaks `text` into lines. All memory is in `a` (an arena).
pub fn breakText(a: std.mem.Allocator, text: []const u8, o: Options) !Result {
    var items: std.ArrayList(knuth.Item) = .empty;
    var texts: std.ArrayList([]const u8) = .empty;
    const grid = o.font == null;
    const sw = try widthOf(a, o, " ");
    const hw = try widthOf(a, o, "-");
    if (o.indent > 0) {
        try items.append(a, .{ .kind = .box, .width = o.indent });
        try texts.append(a, "");
    }
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var first = true;
    while (words.next()) |w| {
        if (!first) {
            try items.append(a, .{ .kind = .glue, .width = sw, .stretch = if (grid) sw else sw / 2, .shrink = if (grid) 0 else sw / 3 });
            try texts.append(a, " ");
        }
        first = false;
        var marks: [64]bool = @splat(false);
        var lo: usize = 0;
        while (lo < w.len and !std.ascii.isAlphabetic(w[lo])) lo += 1;
        var hi = w.len;
        while (hi > lo and !std.ascii.isAlphabetic(w[hi - 1])) hi -= 1;
        const core = w[lo..hi];
        const n = if (o.hyphenate and o.hy != null and core.len >= 5 and core.len <= 64) o.hy.?.hyphenate(core, &marks) else 0;
        var start: usize = 0;
        if (n > 0) for (0..core.len) |i| {
            if (!marks[i]) continue;
            const end = lo + i + 1;
            try items.append(a, .{ .kind = .box, .width = try widthOf(a, o, w[start..end]) });
            try texts.append(a, w[start..end]);
            try items.append(a, .{ .kind = .penalty, .width = hw, .penalty = 50, .flagged = true });
            try texts.append(a, "");
            start = end;
        };
        try items.append(a, .{ .kind = .box, .width = try widthOf(a, o, w[start..]) });
        try texts.append(a, w[start..]);
    }
    try items.append(a, .{ .kind = .penalty, .penalty = knuth.inf_penalty });
    try texts.append(a, "");
    try items.append(a, .{ .kind = .glue, .stretch = 100000 });
    try texts.append(a, "");
    try items.append(a, .{ .kind = .penalty, .penalty = -knuth.inf_penalty });
    try texts.append(a, "");

    var steps: usize = 0;
    const breaks: []knuth.Break = switch (o.method) {
        .total => (try knuth.breakLines(a, items.items, &.{o.width}, .{ .tolerance = o.tolerance, .max_steps = o.max_steps }, &steps)) orelse
            (try knuth.breakLines(a, items.items, &.{o.width}, .{ .tolerance = 100000, .emergency = sw * 4, .max_steps = o.max_steps }, &steps)) orelse
            try greedy(a, items.items, o.width),
        .greedy => try greedy(a, items.items, o.width),
    };
    var lines: std.ArrayList(Line) = .empty;
    var from: usize = 0;
    for (breaks, 0..) |b, bi| {
        const last = bi == breaks.len - 1;
        var start = from;
        if (bi > 0) while (start < b.pos and items.items[start].kind != .box) {
            start += 1;
        };
        // The natural width, the stretch, and the shrink of the line.
        var nat: f32 = 0;
        var y: f32 = 0;
        var z: f32 = 0;
        var gaps: usize = 0;
        var k = start;
        while (k < b.pos) : (k += 1) {
            const x = items.items[k];
            switch (x.kind) {
                .box => nat += x.width,
                .glue => if (x.stretch < 100000) {
                    nat += x.width;
                    y += x.stretch;
                    z += x.shrink;
                    gaps += 1;
                },
                .penalty => {},
            }
        }
        const hyphen = items.items[b.pos].kind == .penalty and items.items[b.pos].width > 0;
        if (hyphen) nat += hw;
        var r: f32 = 0;
        if (o.@"align" == .justify and !last) {
            if (nat < o.width and y > 0) r = (o.width - nat) / y else if (nat > o.width and z > 0) r = @max(-1, (o.width - nat) / z);
        }
        const used = if (r >= 0) nat + r * y else nat + r * z;
        // On a grid, each gap gets a whole number of extra characters.
        const extra_total: usize = if (grid and r > 0) @intFromFloat(@round(r * y)) else 0;
        var x: f32 = switch (o.@"align") {
            .justify, .left => 0,
            .right => o.width - used,
            .center => (o.width - used) / 2,
        };
        var out: std.ArrayList(Word) = .empty;
        var cur: ?Word = null;
        var gap_i: usize = 0;
        k = start;
        while (k < b.pos) : (k += 1) {
            const it = items.items[k];
            switch (it.kind) {
                .box => {
                    if (cur) |*c| {
                        c.text = try std.mem.concat(a, u8, &.{ c.text, texts.items[k] });
                        c.width += it.width;
                    } else cur = .{ .text = texts.items[k], .x = x, .width = it.width };
                    x += it.width;
                },
                .glue => {
                    if (it.stretch >= 100000) continue;
                    if (cur) |c| try out.append(a, c);
                    cur = null;
                    if (grid) {
                        const add: usize = if (gaps > 0) extra_total / gaps + @intFromBool(gap_i < extra_total % gaps) else 0;
                        x += it.width + @as(f32, @floatFromInt(add));
                        gap_i += 1;
                    } else x += it.width + (if (r >= 0) r * it.stretch else r * it.shrink);
                },
                .penalty => {},
            }
        }
        if (hyphen) {
            if (cur) |*c| {
                c.text = try std.mem.concat(a, u8, &.{ c.text, "-" });
                c.width += hw;
            }
            x += hw;
        }
        if (cur) |c| try out.append(a, c);
        const ws = try out.toOwnedSlice(a);
        try lines.append(a, .{ .words = ws, .hyphen = hyphen, .ratio = r, .width = if (ws.len > 0) ws[ws.len - 1].x + ws[ws.len - 1].width - ws[0].x else 0 });
        from = b.pos + 1;
    }
    return .{ .lines = try lines.toOwnedSlice(a), .steps = steps };
}

/// First fit: each line ends at the last break that fits.
fn greedy(a: std.mem.Allocator, items: []const knuth.Item, width: f32) ![]knuth.Break {
    var out: std.ArrayList(knuth.Break) = .empty;
    var start: usize = 0;
    var w: f32 = 0;
    var last_fit: ?usize = null;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const it = items[i];
        if (it.kind == .penalty and it.penalty <= -knuth.inf_penalty) {
            try out.append(a, .{ .pos = i, .ratio = 0 });
            break;
        }
        const legal = (it.kind == .glue and i > 0 and items[i - 1].kind == .box) or (it.kind == .penalty and it.penalty < knuth.inf_penalty);
        if (legal) {
            const line_w = w + (if (it.kind == .penalty) it.width else 0);
            if (line_w <= width) {
                last_fit = i;
            } else if (last_fit) |lf| {
                try out.append(a, .{ .pos = lf, .ratio = 0 });
                // Start again after the break.
                i = lf;
                start = lf + 1;
                while (start < items.len and items[start].kind != .box and !(items[start].kind == .penalty and items[start].penalty <= -knuth.inf_penalty)) start += 1;
                i = start - 1;
                w = 0;
                last_fit = null;
                continue;
            }
        }
        if (it.kind == .box or it.kind == .glue) w += it.width;
    }
    return out.toOwnedSlice(a);
}

/// Places the lines of paragraphs on pages of `per_column` lines and
/// `columns` columns, with no orphan (one first line at the bottom of a
/// column) and no widow (one last line at the top), unless a paragraph
/// has too few lines. `counts` has the line count of each paragraph, and
/// `gap` lines go between two paragraphs. The result has, for each page
/// and column, the slices {paragraph, first line, last line + 1}.
pub const Piece = struct { para: u32, from: u32, to: u32 };

pub fn pages(a: std.mem.Allocator, counts: []const u32, per_column: u32, columns: u32, gap: u32) ![][][]Piece {
    var out: std.ArrayList([][]Piece) = .empty;
    var page: std.ArrayList([]Piece) = .empty;
    var col: std.ArrayList(Piece) = .empty;
    var used: u32 = 0;
    for (counts, 0..) |n, p| {
        var line: u32 = 0;
        if (used > 0 and n > 0) used += gap;
        while (line < n) {
            var room = if (used >= per_column) 0 else per_column - used;
            const left = n - line;
            var take = @min(room, left);
            // No widow: leave at least two lines for the next column.
            if (take < left and left - take == 1 and take > 1) take -= 1;
            // No orphan: a first line alone at the bottom moves on.
            if (line == 0 and take == 1 and left > 1) take = 0;
            if (take == 0 and used == 0) take = @min(left, per_column);
            if (take > 0) {
                try col.append(a, .{ .para = @intCast(p), .from = line, .to = line + take });
                line += take;
                used += take;
                room -= take;
            }
            if (line < n) {
                try page.append(a, try col.toOwnedSlice(a));
                used = 0;
                if (page.items.len == columns) try out.append(a, try page.toOwnedSlice(a));
            }
        }
    }
    if (col.items.len > 0) try page.append(a, try col.toOwnedSlice(a));
    if (page.items.len > 0) try out.append(a, try page.toOwnedSlice(a));
    return out.toOwnedSlice(a);
}

test "para: a grid paragraph, total and greedy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "The quick brown fox jumps over the lazy dog and keeps on running far away.";
    const t = try breakText(a, text, .{ .width = 20, .hyphenate = false });
    for (t.lines[0 .. t.lines.len - 1]) |l| try std.testing.expectEqual(@as(f32, 20), l.width);
    const g = try breakText(a, text, .{ .width = 20, .method = .greedy, .hyphenate = false });
    try std.testing.expectEqualStrings("The", g.lines[0].words[0].text);
    const pg = try pages(a, &.{ 5, 3, 4 }, 6, 1, 0);
    try std.testing.expect(pg.len >= 2);
}

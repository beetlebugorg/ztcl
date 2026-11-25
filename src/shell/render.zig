//! The screen of the line editor: the rows of the prompt, the command,
//! the hint, and the completion menu, and the update of a terminal from
//! the last frame to the next with the fewest bytes.
//!
//! `build` lays out a frame. Each logical line of the command gets the
//! prompt (the first line) or the continuation prompt (the others), and
//! wraps at the width of the terminal. A wide character that does not fit
//! at the end of a row goes to the next row. The cursor position is the
//! row and the column of the cursor byte. When the cursor is right after
//! a full row, it goes to the start of the next row, and the frame has
//! that row.
//!
//! `Screen.update` compares the cells of each row with the last frame.
//! For a row that changed, it moves to the first cell that differs,
//! writes the cells from there with their colors, and clears the rest of
//! the row. It clears the rows of the last frame below the new frame, and
//! then moves to the cursor. Each move is relative to the row of the
//! cursor, so the frame needs no row number of the terminal.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const text = @import("text.zig");
const hl = @import("highlight.zig");

const Allocator = std.mem.Allocator;

pub const Style = enum(u8) { plain, command, unknown, string, brace, variable, comment, number, match, prompt, hint, select, menu, menu_sel, prompt_normal };

pub fn fromHl(s: hl.Style) Style {
    return @enumFromInt(@intFromEnum(s));
}

/// The SGR text of each style. An empty text is the default color.
pub const Theme = struct {
    sgr: [@typeInfo(Style).@"enum".fields.len][]const u8 = .{
        "", // plain
        "1;34", // command
        "1;31", // unknown
        "32", // string
        "35", // brace
        "36", // variable
        "2;37", // comment
        "33", // number
        "1;7", // match
        "1;32", // prompt
        "2", // hint
        "7", // select
        "2", // menu
        "7", // menu_sel
        "1;33", // prompt_normal: the prompt in the normal mode of vim
    },
    on: bool = true,

    pub fn get(t: *const Theme, s: Style) []const u8 {
        return if (t.on) t.sgr[@intFromEnum(s)] else "";
    }
};

pub const Cell = struct {
    bytes: [16]u8 = undefined,
    len: u8 = 0,
    width: u8 = 1,
    style: Style = .plain,

    fn eql(a: Cell, b: Cell) bool {
        return a.len == b.len and a.style == b.style and std.mem.eql(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
    }
};

pub const Row = std.ArrayList(Cell);

pub const Frame = struct {
    rows: std.ArrayList(Row) = .empty,
    cur_row: usize = 0,
    cur_col: usize = 0,

    pub fn deinit(f: *Frame, a: Allocator) void {
        for (f.rows.items) |*r| r.deinit(a);
        f.rows.deinit(a);
    }

    /// The visible text of row `i`, for the tests.
    pub fn rowText(f: *const Frame, a: Allocator, i: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (f.rows.items[i].items) |c| try out.appendSlice(a, c.bytes[0..c.len]);
        return out.toOwnedSlice(a);
    }
};

/// The input of `build`.
pub const View = struct {
    prompt: []const u8,
    prompt_style: Style = .prompt,
    cont: []const u8 = "> ",
    buf: []const u8,
    cur: usize,
    styles: []const hl.Style,
    /// A selection to show reversed, as a byte span.
    select: ?[2]usize = null,
    match: ?usize = null,
    /// The dim text after the end of the buffer.
    hint: []const u8 = "",
    /// Rows under the command: the argument hint, the menu, the search.
    below: []const []const u8 = &.{},
    below_sel: ?usize = null,
    width: usize,
};

const Builder = struct {
    a: Allocator,
    f: *Frame,
    width: usize,
    col: usize = 0,

    fn row(b: *Builder) *Row {
        return &b.f.rows.items[b.f.rows.items.len - 1];
    }

    fn newRow(b: *Builder) Allocator.Error!void {
        try b.f.rows.append(b.a, .empty);
        b.col = 0;
    }

    fn put(b: *Builder, bytes: []const u8, w: usize, style: Style) Allocator.Error!void {
        if (b.col + w > b.width and b.col > 0) try b.newRow();
        var c: Cell = .{ .width = @intCast(w), .style = style };
        const n = @min(bytes.len, c.bytes.len);
        @memcpy(c.bytes[0..n], bytes[0..n]);
        c.len = @intCast(n);
        try b.row().append(b.a, c);
        b.col += w;
    }

    /// Text with its ANSI sequences left out, one cell for each cluster.
    fn putText(b: *Builder, s: []const u8, style: Style) Allocator.Error!void {
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == 0x1B) {
                i = text.skipEscape(s, i);
                continue;
            }
            const j = text.nextCluster(s, i);
            if (s[i] == '\t') {
                try b.put(" ", 1, style);
            } else if (s[i] < 0x20 or s[i] == 0x7F) {
                // A control character shows as ^X.
                const cap = [2]u8{ '^', (s[i] +% 64) & 0x7F };
                try b.put(&cap, 2, style);
            } else {
                try b.put(s[i..j], @max(text.clusterWidth(s, i), 1), style);
            }
            i = j;
        }
    }
};

pub fn build(a: Allocator, v: View) Allocator.Error!Frame {
    var f: Frame = .{};
    var b: Builder = .{ .a = a, .f = &f, .width = @max(v.width, 4) };
    try b.newRow();
    try b.putText(v.prompt, v.prompt_style);
    var i: usize = 0;
    var cursor_set = false;
    while (true) {
        if (i == v.cur) {
            if (b.col >= b.width) try b.newRow();
            f.cur_row = f.rows.items.len - 1;
            f.cur_col = b.col;
            cursor_set = true;
        }
        if (i >= v.buf.len) break;
        if (v.buf[i] == '\n') {
            try b.newRow();
            try b.putText(v.cont, .prompt);
            i += 1;
            continue;
        }
        const j = text.nextCluster(v.buf, i);
        var style = fromHl(if (i < v.styles.len) v.styles[i] else .plain);
        if (v.select) |sel| {
            if (i >= sel[0] and i < sel[1]) style = .select;
        }
        if (v.match) |m| {
            if (m == i) style = .match;
        }
        try b.putText(v.buf[i..j], style);
        i = j;
    }
    if (!cursor_set) {
        f.cur_row = f.rows.items.len - 1;
        f.cur_col = b.col;
    }
    if (v.hint.len > 0) try b.putText(v.hint, .hint);
    for (v.below, 0..) |line, k| {
        try b.newRow();
        try b.putText(line, if (v.below_sel == k) .menu_sel else .menu);
    }
    return f;
}

/// The terminal state of the last frame.
pub const Screen = struct {
    a: Allocator,
    last: Frame = .{},
    /// The row of the terminal cursor, from the first row of the frame.
    at_row: usize = 0,
    theme: Theme = .{},

    pub fn init(a: Allocator) Screen {
        return .{ .a = a };
    }

    pub fn deinit(s: *Screen) void {
        s.last.deinit(s.a);
    }

    /// Forgets the last frame, after output of a command: the next frame
    /// starts at the row of the terminal cursor.
    pub fn forget(s: *Screen) void {
        s.last.deinit(s.a);
        s.last = .{};
        s.at_row = 0;
    }

    fn moveRow(out: *std.ArrayList(u8), a: Allocator, from: usize, to: usize) Allocator.Error!void {
        if (to > from) try out.print(a, "\x1b[{d}B", .{to - from});
        if (to < from) try out.print(a, "\x1b[{d}A", .{from - to});
    }

    fn moveCol(out: *std.ArrayList(u8), a: Allocator, col: usize) Allocator.Error!void {
        try out.append(a, '\r');
        if (col > 0) try out.print(a, "\x1b[{d}C", .{col});
    }

    fn writeCells(s: *Screen, out: *std.ArrayList(u8), cells: []const Cell) Allocator.Error!void {
        var style: ?Style = null;
        for (cells) |c| {
            if (s.theme.on and style != c.style) {
                try out.appendSlice(s.a, "\x1b[0m");
                const sgr = s.theme.get(c.style);
                if (sgr.len > 0) try out.print(s.a, "\x1b[{s}m", .{sgr});
                style = c.style;
            }
            try out.appendSlice(s.a, c.bytes[0..c.len]);
        }
        if (s.theme.on and style != null) try out.appendSlice(s.a, "\x1b[0m");
    }

    /// The bytes that change the terminal from the last frame to `f`.
    /// The screen keeps `f`.
    pub fn update(s: *Screen, f: Frame, out: *std.ArrayList(u8)) Allocator.Error!void {
        const a = s.a;
        var row = s.at_row;
        const old = s.last.rows.items;
        for (f.rows.items, 0..) |r, k| {
            const prev: []const Cell = if (k < old.len) old[k].items else &.{};
            var first: usize = 0;
            var col: usize = 0;
            while (first < r.items.len and first < prev.len and r.items[first].eql(prev[first])) : (first += 1) col += r.items[first].width;
            const same = first == r.items.len and first == prev.len and k < old.len;
            if (same) continue;
            if (k >= old.len and k > 0) {
                // A new row: go down from the last row with a newline,
                // so the terminal scrolls when it must.
                try moveRow(out, a, row, @max(old.len, 1) - 1);
                row = @max(old.len, 1) - 1;
                while (row < k) : (row += 1) try out.appendSlice(a, "\r\n");
            } else {
                try moveRow(out, a, row, k);
                row = k;
            }
            try moveCol(out, a, col);
            try s.writeCells(out, r.items[first..]);
            try out.appendSlice(a, "\x1b[K");
        }
        // Rows of the last frame below the new frame.
        var k = f.rows.items.len;
        while (k < old.len) : (k += 1) {
            try moveRow(out, a, row, k);
            row = k;
            try out.appendSlice(a, "\r\x1b[K");
        }
        try moveRow(out, a, row, f.cur_row);
        try moveCol(out, a, f.cur_col);
        s.at_row = f.cur_row;
        s.last.deinit(a);
        s.last = f;
    }

    /// Moves below the last frame, for the output of a command.
    pub fn finish(s: *Screen, out: *std.ArrayList(u8)) Allocator.Error!void {
        const n = s.last.rows.items.len;
        if (n > 0) try moveRow(out, s.a, s.at_row, n - 1);
        try out.appendSlice(s.a, "\r\n");
        s.forget();
    }
};

test "render: wrap, continuation, cursor, and the update" {
    const t = std.testing;
    const a = t.allocator;
    const buf = "abcdef\nxy";
    const st: [buf.len]hl.Style = @splat(.plain);
    var f = try build(a, .{ .prompt = "% ", .buf = buf, .cur = 8, .styles = &st, .width = 5 });
    try t.expectEqual(@as(usize, 3), f.rows.items.len);
    const r0 = try f.rowText(a, 0);
    defer a.free(r0);
    try t.expectEqualStrings("% abc", r0);
    const r2 = try f.rowText(a, 2);
    defer a.free(r2);
    try t.expectEqualStrings("> xy", r2);
    try t.expectEqual(@as(usize, 2), f.cur_row);
    try t.expectEqual(@as(usize, 3), f.cur_col);
    var s = Screen.init(a);
    defer s.deinit();
    s.theme.on = false;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try s.update(f, &out);
    // The same frame again sends only the cursor move.
    out.clearRetainingCapacity();
    const g = try build(a, .{ .prompt = "% ", .buf = buf, .cur = 8, .styles = &st, .width = 5 });
    try s.update(g, &out);
    try t.expectEqualStrings("\r\x1b[3C", out.items);
    // One more character sends that character and the clear. The row is
    // full, so the cursor goes to the start of a new row.
    out.clearRetainingCapacity();
    const buf2 = "abcdef\nxyz";
    const st2: [buf2.len]hl.Style = @splat(.plain);
    const h = try build(a, .{ .prompt = "% ", .buf = buf2, .cur = 10, .styles = &st2, .width = 5 });
    try s.update(h, &out);
    try t.expectEqualStrings("\r\x1b[4Cz\x1b[K\r\n\r\x1b[K\r", out.items);
}

//! The Markdown reader of the typesetter. It reads the blocks of a
//! chapter and the spans of each paragraph into an arena.
//!
//! Blocks: ATX headings (`#` to `####`) with an optional `{#id}` at the
//! end, paragraphs, fenced code blocks, lists (`-`, `*`, or `1.`), block
//! quotes, figures (`![caption](file){#id}` alone on a line), and HTML
//! comments, which the reader drops. A block quote that starts with
//! `[!NOTE]`, `[!HINT]`, `[!WARNING]`, or `[!MISSING]` is an aside of
//! that kind.
//!
//! The info string of a fence has the language and the flags: `run`
//! (run the block at build time and compare its output), `output` (the
//! expected output of the `run` block before it), and `glob` (each line
//! of the expected output is a pattern, where `*` matches any text).
//!
//! Spans: `*em*` or `_em_`, `**strong**`, `` `code` ``, links
//! `[text](url)`, cross references `[](#id)` (the text comes from the
//! target), index entries `{^term}` (no text), and the escape `\`. The
//! reader makes the typographic quotes and the en dash (`--`).
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Style = packed struct(u8) {
    em: bool = false,
    strong: bool = false,
    code: bool = false,
    _: u5 = 0,
};

pub const Span = struct {
    kind: enum { text, xref, index } = .text,
    text: []const u8,
    style: Style = .{},
    /// A URL, or `#id` for a place in the book.
    link: []const u8 = "",
};

pub const Kind = enum { heading, para, code, item, aside, figure };

pub const Block = struct {
    kind: Kind,
    line: usize = 0,
    level: u8 = 0,
    id: []const u8 = "",
    spans: []Span = &.{},
    /// The code of a code block, or the file of a figure.
    text: []const u8 = "",
    lang: []const u8 = "",
    run: bool = false,
    output: bool = false,
    glob: bool = false,
    /// The kind of an aside: NOTE, HINT, WARNING, or MISSING.
    aside: []const u8 = "",
    children: []Block = &.{},
    /// The number of an item of an ordered list, or 0 for a bullet.
    ordinal: u32 = 0,
    /// The number of a heading, such as "13.2", from the book.
    number: []const u8 = "",
};

pub const Error = error{OutOfMemory};

/// Reads `src`. The result and its strings live in `a` (an arena).
pub fn parse(a: std.mem.Allocator, src: []const u8) Error![]Block {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(a, std.mem.trimEnd(u8, l, "\r"));
    return parseLines(a, lines.items, 1);
}

fn isBlank(l: []const u8) bool {
    return std.mem.trim(u8, l, " \t").len == 0;
}

fn fenceOf(l: []const u8) ?usize {
    const t = std.mem.trimStart(u8, l, " ");
    if (std.mem.startsWith(u8, t, "```")) {
        var n: usize = 0;
        while (n < t.len and t[n] == '`') n += 1;
        return n;
    }
    return null;
}

fn headingLevel(l: []const u8) u8 {
    var n: u8 = 0;
    while (n < l.len and l[n] == '#') n += 1;
    if (n == 0 or n > 6 or n >= l.len or l[n] != ' ') return 0;
    return n;
}

/// The marker length of a list item, and its number (0 for a bullet).
fn listMarker(l: []const u8) ?struct { len: usize, ordinal: u32 } {
    if (l.len >= 2 and (l[0] == '-' or l[0] == '*') and l[1] == ' ') return .{ .len = 2, .ordinal = 0 };
    var n: usize = 0;
    while (n < l.len and n < 9 and std.ascii.isDigit(l[n])) n += 1;
    if (n > 0 and n + 1 < l.len and l[n] == '.' and l[n + 1] == ' ') {
        return .{ .len = n + 2, .ordinal = std.fmt.parseInt(u32, l[0..n], 10) catch 1 };
    }
    return null;
}

fn startsBlock(l: []const u8) bool {
    return headingLevel(l) > 0 or fenceOf(l) != null or std.mem.startsWith(u8, l, ">") or listMarker(l) != null or std.mem.startsWith(u8, l, "<!--");
}

/// Splits a trailing `{#id}` off `s`.
fn takeId(s: []const u8) struct { text: []const u8, id: []const u8 } {
    const t = std.mem.trimEnd(u8, s, " ");
    if (std.mem.endsWith(u8, t, "}")) {
        if (std.mem.lastIndexOf(u8, t, "{#")) |at| {
            return .{ .text = std.mem.trimEnd(u8, t[0..at], " "), .id = t[at + 2 .. t.len - 1] };
        }
    }
    return .{ .text = t, .id = "" };
}

fn parseLines(a: std.mem.Allocator, lines: []const []const u8, first_line: usize) Error![]Block {
    var out: std.ArrayList(Block) = .empty;
    var i: usize = 0;
    while (i < lines.len) {
        const l = lines[i];
        const ln = first_line + i;
        if (isBlank(l)) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, l, "<!--")) {
            while (i < lines.len and std.mem.indexOf(u8, lines[i], "-->") == null) i += 1;
            i += 1;
            continue;
        }
        const hl = headingLevel(l);
        if (hl > 0) {
            const t = takeId(l[hl + 1 ..]);
            try out.append(a, .{ .kind = .heading, .line = ln, .level = hl, .id = t.id, .spans = try parseSpans(a, t.text) });
            i += 1;
            continue;
        }
        if (fenceOf(l)) |n| {
            const info = std.mem.trim(u8, std.mem.trimStart(u8, l, " ")[n..], " ");
            var b: Block = .{ .kind = .code, .line = ln };
            var words = std.mem.tokenizeScalar(u8, info, ' ');
            if (words.next()) |lang| b.lang = lang;
            while (words.next()) |w| {
                if (std.mem.eql(u8, w, "run")) b.run = true;
                if (std.mem.eql(u8, w, "output")) b.output = true;
                if (std.mem.eql(u8, w, "glob")) b.glob = true;
            }
            if (std.mem.eql(u8, b.lang, "output")) b.output = true;
            i += 1;
            var body: std.ArrayList(u8) = .empty;
            while (i < lines.len) : (i += 1) {
                if (fenceOf(lines[i])) |m| if (m >= n and isBlank(std.mem.trimStart(u8, lines[i], " ")[m..])) break;
                if (body.items.len > 0) try body.append(a, '\n');
                try body.appendSlice(a, lines[i]);
            }
            i += 1;
            b.text = body.items;
            try out.append(a, b);
            continue;
        }
        if (std.mem.startsWith(u8, l, ">")) {
            var inner: std.ArrayList([]const u8) = .empty;
            const start = i;
            while (i < lines.len and std.mem.startsWith(u8, lines[i], ">")) : (i += 1) {
                const s = lines[i][1..];
                try inner.append(a, if (s.len > 0 and s[0] == ' ') s[1..] else s);
            }
            var b: Block = .{ .kind = .aside, .line = first_line + start, .aside = "QUOTE" };
            if (inner.items.len > 0) {
                const f = std.mem.trim(u8, inner.items[0], " ");
                if (std.mem.startsWith(u8, f, "[!") and std.mem.indexOfScalar(u8, f, ']') != null) {
                    const close = std.mem.indexOfScalar(u8, f, ']').?;
                    b.aside = f[2..close];
                    const rest = std.mem.trim(u8, f[close + 1 ..], " ");
                    if (rest.len > 0) inner.items[0] = rest else inner.items = inner.items[1..];
                }
            }
            b.children = try parseLines(a, inner.items, first_line + start + 1);
            try out.append(a, b);
            continue;
        }
        if (listMarker(l)) |m| {
            // An item: the marker line and the lines after it that are
            // indented or that continue its paragraph.
            var inner: std.ArrayList([]const u8) = .empty;
            try inner.append(a, l[m.len..]);
            const start = i;
            i += 1;
            while (i < lines.len) : (i += 1) {
                const x = lines[i];
                if (isBlank(x)) {
                    if (i + 1 < lines.len and std.mem.startsWith(u8, lines[i + 1], "  ")) {
                        try inner.append(a, "");
                        continue;
                    }
                    break;
                }
                if (std.mem.startsWith(u8, x, "  ")) {
                    try inner.append(a, std.mem.trimStart(u8, x, " "));
                    continue;
                }
                if (startsBlock(x)) break;
                try inner.append(a, x);
            }
            const kids = try parseLines(a, inner.items, first_line + start);
            try out.append(a, .{ .kind = .item, .line = first_line + start, .ordinal = m.ordinal, .children = kids });
            continue;
        }
        if (std.mem.startsWith(u8, l, "![")) {
            if (std.mem.indexOf(u8, l, "](")) |mid| {
                if (std.mem.indexOfScalarPos(u8, l, mid, ')')) |close| {
                    const t = takeId(l[close + 1 ..]);
                    try out.append(a, .{ .kind = .figure, .line = ln, .spans = try parseSpans(a, l[2..mid]), .text = l[mid + 2 .. close], .id = t.id });
                    i += 1;
                    continue;
                }
            }
        }
        // A paragraph.
        var text: std.ArrayList(u8) = .empty;
        const start = i;
        while (i < lines.len and !isBlank(lines[i]) and (i == start or !startsBlock(lines[i]))) : (i += 1) {
            if (text.items.len > 0) try text.append(a, ' ');
            try text.appendSlice(a, std.mem.trim(u8, lines[i], " \t"));
        }
        try out.append(a, .{ .kind = .para, .line = first_line + start, .spans = try parseSpans(a, text.items) });
    }
    return out.toOwnedSlice(a);
}

/// Reads the spans of the text of one paragraph.
pub fn parseSpans(a: std.mem.Allocator, s: []const u8) Error![]Span {
    var p: SpanParser = .{ .a = a, .src = s };
    try p.run(s, "", .{});
    try p.flush();
    return p.out.toOwnedSlice(a);
}

const SpanParser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    out: std.ArrayList(Span) = .empty,
    buf: std.ArrayList(u8) = .empty,
    style: Style = .{},
    link: []const u8 = "",
    /// The last character of the text, for the quotes.
    last: u8 = ' ',

    fn flush(p: *SpanParser) Error!void {
        if (p.buf.items.len == 0) return;
        try p.out.append(p.a, .{ .text = try p.a.dupe(u8, p.buf.items), .style = p.style, .link = p.link });
        p.buf.clearRetainingCapacity();
    }

    fn put(p: *SpanParser, s: []const u8) Error!void {
        try p.buf.appendSlice(p.a, s);
        if (s.len > 0) p.last = s[s.len - 1];
    }

    fn run(p: *SpanParser, s: []const u8, link: []const u8, base: Style) Error!void {
        _ = base;
        _ = link;
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            switch (c) {
                '\\' => {
                    if (i + 1 < s.len) {
                        try p.put(s[i + 1 .. i + 2]);
                        i += 2;
                    } else i += 1;
                },
                '`' => {
                    var n: usize = 0;
                    while (i + n < s.len and s[i + n] == '`') n += 1;
                    const fence = s[i .. i + n];
                    if (std.mem.indexOfPos(u8, s, i + n, fence)) |end| {
                        try p.flush();
                        var code = s[i + n .. end];
                        if (code.len > 1 and code[0] == ' ' and code[code.len - 1] == ' ') code = code[1 .. code.len - 1];
                        var st = p.style;
                        st.code = true;
                        try p.out.append(p.a, .{ .text = code, .style = st, .link = p.link });
                        p.last = 'x';
                        i = end + n;
                    } else {
                        try p.put(fence);
                        i += n;
                    }
                },
                '*', '_' => {
                    const double = i + 1 < s.len and s[i + 1] == c;
                    const prev: u8 = if (i > 0) s[i - 1] else ' ';
                    const next: u8 = if (i + @as(usize, if (double) 2 else 1) < s.len) s[i + @as(usize, if (double) 2 else 1)] else ' ';
                    // `_` inside a word is a letter (snake_case names).
                    if (c == '_' and std.ascii.isAlphanumeric(prev) and std.ascii.isAlphanumeric(next)) {
                        try p.put("_");
                        i += 1;
                        continue;
                    }
                    const opens = next != ' ';
                    const closes = prev != ' ';
                    try p.flush();
                    if (double) {
                        if (p.style.strong and closes) p.style.strong = false else if (opens) p.style.strong = true else try p.put(s[i .. i + 2]);
                        i += 2;
                    } else {
                        if (p.style.em and closes) p.style.em = false else if (opens) p.style.em = true else try p.put(s[i .. i + 1]);
                        i += 1;
                    }
                },
                '[' => {
                    const close = matchBracket(s, i) orelse {
                        try p.put("[");
                        i += 1;
                        continue;
                    };
                    if (close + 1 < s.len and s[close + 1] == '(') {
                        if (std.mem.indexOfScalarPos(u8, s, close + 2, ')')) |end| {
                            const target = s[close + 2 .. end];
                            const inner = s[i + 1 .. close];
                            try p.flush();
                            if (inner.len == 0 and target.len > 1 and target[0] == '#') {
                                try p.out.append(p.a, .{ .kind = .xref, .text = "", .style = p.style, .link = target });
                                p.last = 'x';
                            } else {
                                const saved = p.link;
                                p.link = target;
                                try p.run(inner, target, p.style);
                                try p.flush();
                                p.link = saved;
                            }
                            i = end + 1;
                            continue;
                        }
                    }
                    try p.put("[");
                    i += 1;
                },
                '{' => {
                    if (i + 1 < s.len and s[i + 1] == '^') {
                        if (std.mem.indexOfScalarPos(u8, s, i, '}')) |end| {
                            try p.flush();
                            try p.out.append(p.a, .{ .kind = .index, .text = s[i + 2 .. end] });
                            i = end + 1;
                            continue;
                        }
                    }
                    try p.put("{");
                    i += 1;
                },
                '"' => {
                    try p.put(if (opensQuote(p.last)) "\u{201c}" else "\u{201d}");
                    p.last = '"';
                    i += 1;
                },
                '\'' => {
                    try p.put(if (opensQuote(p.last)) "\u{2018}" else "\u{2019}");
                    p.last = '\'';
                    i += 1;
                },
                '-' => {
                    if (i + 1 < s.len and s[i + 1] == '-') {
                        try p.put("\u{2013}");
                        i += 2;
                    } else {
                        try p.put("-");
                        i += 1;
                    }
                },
                else => {
                    try p.buf.append(p.a, c);
                    p.last = c;
                    i += 1;
                },
            }
        }
    }
};

fn opensQuote(last: u8) bool {
    return last == ' ' or last == '(' or last == '[' or last == '\u{0}' or last == '-';
}

fn matchBracket(s: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\\' => i += 1,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            '`' => {
                const end = std.mem.indexOfScalarPos(u8, s, i + 1, '`') orelse return null;
                i = end;
            },
            else => {},
        }
    }
    return null;
}

test "md: blocks and spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\# Title {#ch:t}
        \\
        \\Some *em* and `code` and a [link](https://x.org) "quoted".
        \\
        \\```sh run
        \\$ echo hi
        \\hi
        \\```
        \\
        \\> [!NOTE]
        \\> A note {^term}.
        \\
        \\- one
        \\- two [](#ch:t)
    ;
    const b = try parse(a, src);
    try std.testing.expectEqual(@as(usize, 6), b.len);
    try std.testing.expectEqualStrings("ch:t", b[0].id);
    try std.testing.expect(b[2].run);
    try std.testing.expectEqualStrings("NOTE", b[3].aside);
    try std.testing.expectEqual(.xref, b[5].children[0].spans[1].kind);
}

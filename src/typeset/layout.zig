//! The page layout of a book: Markdown chapters in, PDF pages out.
//!
//! The work goes in four steps:
//!
//! 1. Read each chapter (`md.zig`), give each heading its number, and
//!    collect the targets of the cross references. Run the code blocks
//!    with the flag `run` through the caller, and compare the output.
//! 2. Build the vertical list. Each paragraph goes through the line
//!    breaker (`knuth.zig`) and gives one item for each line. Each other
//!    block (a heading, a code block, an aside, a figure, the chapter
//!    opener) is one unit. Each item fills a whole number of lines of
//!    the baseline grid, so the body text of each page sits on the
//!    grid. A unit is centered in its lines.
//! 3. Break the list into pages. The builder fills a page item by item
//!    and ends it at the last legal break before the first item that does
//!    not fit. A break after the first line or before the last line of a
//!    paragraph is not legal (orphan and widow control), and a heading
//!    stays with the two lines after it. A figure that does not fit
//!    floats to the top of the next page, and a long code block splits.
//! 4. Render each page: the running head, the folio, the lines, the
//!    units, the links, the outline, and the targets. The index pages
//!    come last, from the index entries of each page.
//!
//! A paragraph runs through up to four passes of the line breaker: no
//! hyphens and tolerance 100, then hyphens and tolerance 200, then extra
//! stretch, then any break. Each line uses margin kerning: a period, a
//! comma, a hyphen, or a quote at the end of a line goes a part of its
//! width into the margin, so the edge of the text looks straight.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const pdf = @import("pdf.zig");
const md = @import("md.zig");
const knuth = @import("knuth.zig");
const hyph = @import("hyph.zig");
const fontmod = @import("font.zig");

const Glyph = fontmod.Glyph;
const Rgb = pdf.Rgb;
const Allocator = std.mem.Allocator;

pub const Fonts = struct {
    serif: u32,
    italic: u32,
    bold: u32,
    bold_italic: u32,
    sans: u32,
    sans_bold: u32,
    mono: u32,
    mono_bold: u32,
};

pub const Style = struct {
    page_w: f32 = 504,
    page_h: f32 = 666,
    inner: f32 = 72,
    outer: f32 = 90,
    /// From the top of the page to the first baseline.
    top: f32 = 84,
    lines: u32 = 38,
    leading: f32 = 13.5,
    size: f32 = 10,
    indent: f32 = 12,
    code_size: f32 = 8.2,
    code_leading: f32 = 11,
    code_pad: f32 = 6,
    mono_scale: f32 = 0.86,
    h1_size: f32 = 22,
    h2_size: f32 = 13,
    h3_size: f32 = 10.5,
    head_size: f32 = 7.5,
    tolerance: f32 = 200,
    hyphen_penalty: f32 = 50,
    first_folio: u32 = 1,
    text: Rgb = .{ 0.08, 0.08, 0.08 },
    gray: Rgb = .{ 0.42, 0.42, 0.42 },
    link: Rgb = .{ 0.08, 0.2, 0.45 },
    code_bg: Rgb = .{ 0.955, 0.955, 0.95 },
    aside_bg: Rgb = .{ 0.95, 0.96, 0.975 },
    rule: Rgb = .{ 0.75, 0.75, 0.75 },
    chapter_word: []const u8 = "Chapter",
};

pub const Chapter = struct {
    name: []const u8,
    source: []const u8,
    /// The chapter number, or 0 for no number.
    number: u32,
};

pub const Runner = struct {
    ctx: *anyopaque,
    /// Runs `code` of language `lang` and returns its output in `a`.
    run: *const fn (ctx: *anyopaque, a: Allocator, lang: []const u8, code: []const u8) anyerror![]const u8,
};

pub const Stats = struct {
    pages: u32 = 0,
    lines: u32 = 0,
    hyphens: u32 = 0,
    overfull: u32 = 0,
    loose: u32 = 0,
    code_wide: u32 = 0,
    checked: u32 = 0,
    widest_code: u32 = 0,
};

const BoxInfo = struct {
    font: u32 = 0,
    size: f32 = 0,
    glyphs: []Glyph = &.{},
    text: []const u8 = "",
    color: Rgb = .{ 0, 0, 0 },
    link: []const u8 = "",
    index: []const []const u8 = &.{},
};

const Para = struct {
    items: []knuth.Item,
    infos: []BoxInfo,
    hyphen_font: u32,
    size: f32,
};

const Line = struct {
    para: u32,
    from: u32,
    to: u32,
    ratio: f32,
    x: f32,
    width: f32,
    first: bool,
    marker: []const u8 = "",
    /// A heading line keeps the natural width of its glue.
    ragged: bool = false,
    color: Rgb,
};

const UnitKind = enum { opener, heading, code, aside, figure, index_head };

const Unit = struct {
    kind: UnitKind,
    block: *const md.Block,
    chapter: u32,
    /// The lines of a code block in this unit.
    code_from: u32 = 0,
    code_to: u32 = 0,
    /// The heading lines (greedy breaks) or the aside lines.
    lines: []Line = &.{},
    /// The height of the content in points.
    height: f32 = 0,
    title: []const u8 = "",
    image: ?u32 = null,
    /// The output block that goes under a code block, in the same box.
    extra: ?*const md.Block = null,
    img_w: f32 = 0,
    img_h: f32 = 0,
};

const VItem = struct {
    kind: enum { line, unit },
    ref: u32,
    k: u32,
    k_top: u32,
    no_break_before: bool = false,
    page_break: bool = false,
    float: bool = false,
    chapter: u32,
};

const Target = struct { text: []const u8, dest: []const u8 };

const IndexMark = struct { term: []const u8, page: u32 };

const Mark = struct { chapter: []const u8, section: []const u8 };

pub const Ctx = struct {
    gpa: Allocator,
    a: Allocator,
    doc: *pdf.Doc,
    f: Fonts,
    st: Style,
    hy: *const hyph.Hyphenator,
    stats: Stats = .{},
    msgs: *std.ArrayList(u8),
    paras: std.ArrayList(Para) = .empty,
    lines: std.ArrayList(Line) = .empty,
    units: std.ArrayList(Unit) = .empty,
    items: std.ArrayList(VItem) = .empty,
    targets: std.StringHashMapUnmanaged(Target) = .empty,
    index: std.ArrayList(IndexMark) = .empty,
    chapter_titles: std.ArrayList([]const u8) = .empty,
    /// The page that the render is on, for the index marks.
    cur_page: u32 = 0,
    cur_folio: u32 = 0,
    steps: usize = 0,
    max_steps: usize = 200_000_000,

    fn msg(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        c.msgs.print(c.gpa, fmt ++ "\n", args) catch {};
    }

    fn L(c: *const Ctx) f32 {
        return c.st.leading;
    }

    fn measure(c: *const Ctx) f32 {
        return c.st.page_w - c.st.inner - c.st.outer;
    }

    // ---- shaping ----

    fn shape(c: *Ctx, font: u32, size: f32, text: []const u8, ligatures: bool) !BoxInfo {
        const ft = c.doc.font(font);
        const g = try ft.shape(c.a, text, ligatures);
        return .{ .font = font, .size = size, .glyphs = g, .text = text };
    }

    fn widthOf(c: *Ctx, b: BoxInfo) f32 {
        var w: i64 = 0;
        for (b.glyphs) |g| w += g.advance;
        return @as(f32, @floatFromInt(w)) * b.size / c.doc.font(b.font).unitsPerEm();
    }

    fn textWidth(c: *Ctx, font: u32, size: f32, text: []const u8) !f32 {
        return c.widthOf(try c.shape(font, size, text, true));
    }

    fn fontFor(c: *const Ctx, s: md.Style, sans: bool) u32 {
        if (s.code) return if (s.strong) c.f.mono_bold else c.f.mono;
        if (sans) return if (s.strong) c.f.sans_bold else c.f.sans;
        if (s.strong and s.em) return c.f.bold_italic;
        if (s.strong) return c.f.bold;
        if (s.em) return c.f.italic;
        return c.f.serif;
    }

    // ---- paragraphs ----

    const ParaOpts = struct {
        size: f32,
        sans: bool = false,
        indent: f32 = 0,
        /// A run-in label in the bold sans face, such as "Note:".
        label: []const u8 = "",
        color: Rgb,
    };

    /// Turns spans into the items of the line breaker.
    fn buildPara(c: *Ctx, spans: []const md.Span, o: ParaOpts) !Para {
        var items: std.ArrayList(knuth.Item) = .empty;
        var infos: std.ArrayList(BoxInfo) = .empty;
        var pending_index: std.ArrayList([]const u8) = .empty;
        var space_before = false;
        if (o.label.len > 0) {
            var lb = try c.shape(c.f.sans_bold, o.size * 0.93, o.label, false);
            lb.color = o.color;
            try items.append(c.a, .{ .kind = .box, .width = c.widthOf(lb) });
            try infos.append(c.a, lb);
            space_before = true;
        }
        if (o.indent > 0) {
            try items.append(c.a, .{ .kind = .box, .width = o.indent });
            try infos.append(c.a, .{});
        }
        for (spans) |sp| {
            if (sp.kind == .index) {
                // The entry goes with the box before it, or the next box.
                var at = infos.items.len;
                while (at > 0) : (at -= 1) {
                    if (items.items[at - 1].kind == .box and infos.items[at - 1].glyphs.len > 0) break;
                }
                if (at > 0) {
                    const old = infos.items[at - 1].index;
                    const nw = try c.a.alloc([]const u8, old.len + 1);
                    @memcpy(nw[0..old.len], old);
                    nw[old.len] = sp.text;
                    infos.items[at - 1].index = nw;
                } else try pending_index.append(c.a, sp.text);
                continue;
            }
            var text = sp.text;
            if (sp.kind == .xref) {
                const t = c.targets.get(sp.link[1..]) orelse blk: {
                    c.msg("unknown cross reference \"{s}\"", .{sp.link});
                    break :blk Target{ .text = "??", .dest = "" };
                };
                text = t.text;
            }
            const font = c.fontFor(sp.style, o.sans);
            const size = if (sp.style.code) o.size * c.st.mono_scale else o.size;
            const color: Rgb = if (sp.link.len > 0) c.st.link else o.color;
            var i: usize = 0;
            while (i < text.len) {
                if (text[i] == ' ' or text[i] == '\n') {
                    while (i < text.len and (text[i] == ' ' or text[i] == '\n')) i += 1;
                    space_before = true;
                    continue;
                }
                var j = i;
                while (j < text.len and text[j] != ' ' and text[j] != '\n') j += 1;
                if (space_before and items.items.len > 0) {
                    const sw = c.widthOf(try c.shape(c.f.serif, o.size, " ", false));
                    const gf: f32 = if (sp.style.code) 1.0 else 1.0;
                    try items.append(c.a, .{ .kind = .glue, .width = sw * gf, .stretch = sw * 0.5, .shrink = sw * 0.33 });
                    try infos.append(c.a, .{});
                }
                space_before = false;
                try c.addWord(&items, &infos, text[i..j], font, size, color, sp.link, sp.style.code);
                if (pending_index.items.len > 0) {
                    infos.items[infos.items.len - 1].index = try pending_index.toOwnedSlice(c.a);
                }
                i = j;
            }
        }
        // The end: no break before the fill glue, then a forced break.
        try items.append(c.a, .{ .kind = .penalty, .penalty = knuth.inf_penalty });
        try infos.append(c.a, .{});
        try items.append(c.a, .{ .kind = .glue, .stretch = 100000 });
        try infos.append(c.a, .{});
        try items.append(c.a, .{ .kind = .penalty, .penalty = -knuth.inf_penalty });
        try infos.append(c.a, .{});
        return .{ .items = try items.toOwnedSlice(c.a), .infos = try infos.toOwnedSlice(c.a), .hyphen_font = if (o.sans) c.f.sans else c.f.serif, .size = o.size };
    }

    fn addBox(c: *Ctx, items: *std.ArrayList(knuth.Item), infos: *std.ArrayList(BoxInfo), text: []const u8, font: u32, size: f32, color: Rgb, link: []const u8, ligatures: bool) !void {
        var b = try c.shape(font, size, text, ligatures);
        b.color = color;
        b.link = link;
        try items.append(c.a, .{ .kind = .box, .width = c.widthOf(b) });
        try infos.append(c.a, b);
    }

    fn addHyphen(c: *Ctx, items: *std.ArrayList(knuth.Item), infos: *std.ArrayList(BoxInfo), font: u32, size: f32, width: bool, penalty: f32) !void {
        const hw = if (width) c.widthOf(try c.shape(font, size, "-", false)) else 0;
        try items.append(c.a, .{ .kind = .penalty, .width = hw, .penalty = penalty, .flagged = true });
        try infos.append(c.a, .{ .font = font, .size = size });
    }

    /// Adds one word: boxes, with a hyphen penalty at each place that the
    /// patterns give, or after `::` and `/` in code.
    fn addWord(c: *Ctx, items: *std.ArrayList(knuth.Item), infos: *std.ArrayList(BoxInfo), word: []const u8, font: u32, size: f32, color: Rgb, link: []const u8, code: bool) !void {
        if (code) {
            var start: usize = 0;
            var i: usize = 0;
            while (i < word.len) : (i += 1) {
                const cut = (word[i] == '/' and i + 1 < word.len) or (i + 1 < word.len and word[i] == ':' and word[i + 1] == ':' and i + 2 < word.len);
                if (!cut) continue;
                const end = if (word[i] == ':') i + 2 else i + 1;
                try c.addBox(items, infos, word[start..end], font, size, color, link, false);
                try items.append(c.a, .{ .kind = .penalty, .penalty = 200 });
                try infos.append(c.a, .{});
                start = end;
                i = end - 1;
            }
            try c.addBox(items, infos, word[start..], font, size, color, link, false);
            return;
        }
        // Split at explicit hyphens and dashes.
        if (std.mem.indexOfScalar(u8, word, '-') != null and word.len > 2) {
            var it = std.mem.splitScalar(u8, word, '-');
            var first = true;
            var rest = word;
            while (it.next()) |part| {
                if (!first) {
                    try c.addBox(items, infos, "-", font, size, color, link, true);
                    try items.append(c.a, .{ .kind = .penalty, .penalty = c.st.hyphen_penalty, .flagged = true });
                    try infos.append(c.a, .{});
                }
                first = false;
                if (part.len > 0) try c.addBox(items, infos, part, font, size, color, link, true);
                rest = rest[@min(rest.len, part.len + 1)..];
            }
            return;
        }
        // The letters of the word, without the punctuation at each end.
        var a: usize = 0;
        while (a < word.len and !std.ascii.isAlphabetic(word[a])) a += 1;
        var b = word.len;
        while (b > a and !std.ascii.isAlphabetic(word[b - 1])) b -= 1;
        const core = word[a..b];
        var marks: [64]bool = undefined;
        const n = if (core.len >= 5 and core.len <= 64) c.hy.hyphenate(core, &marks) else 0;
        if (n == 0) {
            try c.addBox(items, infos, word, font, size, color, link, true);
            return;
        }
        var start: usize = 0;
        for (core, 0..) |_, k| {
            if (!marks[k]) continue;
            const end = a + k + 1;
            try c.addBox(items, infos, word[start..end], font, size, color, link, true);
            try c.addHyphen(items, infos, font, size, true, c.st.hyphen_penalty);
            start = end;
        }
        try c.addBox(items, infos, word[start..], font, size, color, link, true);
    }

    /// Breaks a paragraph into lines of `width` and appends them to
    /// `out`.
    fn breakPara(c: *Ctx, p: Para, para_id: u32, x: f32, width: f32, color: Rgb, out: *std.ArrayList(Line)) !void {
        const widths = [_]f32{width};
        const passes = [_]struct { tol: f32, hyph: bool, emerg: f32 }{
            .{ .tol = 100, .hyph = false, .emerg = 0 },
            .{ .tol = c.st.tolerance, .hyph = true, .emerg = 0 },
            .{ .tol = c.st.tolerance * 2, .hyph = true, .emerg = 1.5 * p.size },
            .{ .tol = 100000, .hyph = true, .emerg = 3 * p.size },
        };
        var items = p.items;
        var brks: ?[]knuth.Break = null;
        for (passes) |ps| {
            if (!ps.hyph) {
                const copy = try c.a.dupe(knuth.Item, p.items);
                for (copy) |*it| if (it.kind == .penalty and it.flagged and it.width > 0) {
                    it.penalty = knuth.inf_penalty;
                };
                items = copy;
            } else items = p.items;
            brks = try knuth.breakLines(c.a, items, &widths, .{ .tolerance = ps.tol, .emergency = ps.emerg, .max_steps = c.max_steps }, &c.steps);
            if (brks != null) break;
        }
        const br = brks orelse return c.greedy(p, para_id, x, width, color, out);
        var from: u32 = 0;
        for (br, 0..) |b, i| {
            if (b.ratio > 1) c.stats.loose += 1;
            if (b.ratio < -1) c.stats.overfull += 1;
            const it = p.items[b.pos];
            if (it.kind == .penalty and it.width > 0) c.stats.hyphens += 1;
            try out.append(c.a, .{ .para = para_id, .from = from, .to = @intCast(b.pos), .ratio = b.ratio, .x = x, .width = width, .first = i == 0, .color = color });
            from = @intCast(b.pos + 1);
        }
    }

    /// A break with no tolerance: fill each line, for a box wider than
    /// the line.
    fn greedy(c: *Ctx, p: Para, para_id: u32, x: f32, width: f32, color: Rgb, out: *std.ArrayList(Line)) !void {
        var from: u32 = 0;
        var w: f32 = 0;
        var last_break: ?u32 = null;
        var i: u32 = 0;
        var first = true;
        while (i < p.items.len) : (i += 1) {
            const it = p.items[i];
            switch (it.kind) {
                .box => w += it.width,
                .glue => {
                    last_break = i;
                    w += it.width;
                },
                .penalty => if (it.penalty <= -knuth.inf_penalty) {
                    try out.append(c.a, .{ .para = para_id, .from = from, .to = i, .ratio = 0, .x = x, .width = width, .first = first, .color = color });
                    return;
                },
            }
            if (w > width and last_break != null and last_break.? > from) {
                try out.append(c.a, .{ .para = para_id, .from = from, .to = last_break.?, .ratio = 0, .x = x, .width = width, .first = first, .color = color });
                c.stats.overfull += 1;
                first = false;
                from = last_break.? + 1;
                i = from;
                w = 0;
                last_break = null;
                if (i < p.items.len) i -= 1 else break;
            }
        }
    }

    // ---- the vertical list ----

    fn addPara(c: *Ctx, spans: []const md.Span, indent: bool, x: f32, width: f32, marker: []const u8, chapter: u32, no_break_first: bool) !void {
        const p = try c.buildPara(spans, .{ .size = c.st.size, .indent = if (indent) c.st.indent else 0, .color = c.st.text });
        const id: u32 = @intCast(c.paras.items.len);
        try c.paras.append(c.gpa, p);
        var tmp: std.ArrayList(Line) = .empty;
        try c.breakPara(p, id, x, width, c.st.text, &tmp);
        const n = tmp.items.len;
        for (tmp.items, 0..) |ln, i| {
            var l = ln;
            if (i == 0) l.marker = marker;
            const li: u32 = @intCast(c.lines.items.len);
            try c.lines.append(c.gpa, l);
            c.stats.lines += 1;
            // Orphans and widows: no break after line 1 or before the last line.
            const nb = (i == 0 and no_break_first) or (i == 1) or (i > 0 and i == n - 1);
            try c.items.append(c.gpa, .{ .kind = .line, .ref = li, .k = 1, .k_top = 1, .no_break_before = nb, .chapter = chapter });
        }
    }

    fn bodyAsc(c: *const Ctx) f32 {
        return c.st.size * 0.72;
    }

    fn bodyDesc(c: *const Ctx) f32 {
        return c.st.size * 0.25;
    }

    /// The fewest grid lines for a unit of height `h` with `gap` above
    /// and below.
    fn linesFor(c: *const Ctx, h: f32, gap: f32, at_top: bool) u32 {
        const top_part: f32 = if (at_top) c.bodyAsc() else gap + c.bodyDesc();
        const need = top_part + h + gap + c.bodyAsc();
        const k = @ceil(need / c.L() - 1 - 0.001);
        return @intFromFloat(@max(1, k));
    }

    fn addUnit(c: *Ctx, u: Unit, gap: f32, opts: struct { no_break_before: bool = false, page_break: bool = false, float: bool = false, chapter: u32 }) !void {
        const id: u32 = @intCast(c.units.items.len);
        try c.units.append(c.gpa, u);
        try c.items.append(c.gpa, .{ .kind = .unit, .ref = id, .k = c.linesFor(u.height, gap, false), .k_top = c.linesFor(u.height, gap, true), .no_break_before = opts.no_break_before, .page_break = opts.page_break, .float = opts.float, .chapter = opts.chapter });
    }

    fn codeGap(c: *const Ctx) f32 {
        return c.L() * 0.45;
    }

    fn codeHeight(c: *const Ctx, n: u32) f32 {
        return @as(f32, @floatFromInt(n)) * c.st.code_leading + 2 * c.st.code_pad - (c.st.code_leading - c.st.code_size);
    }

    fn headingLines(c: *Ctx, b: *const md.Block, size: f32, width: f32) ![]Line {
        const p = try c.buildPara(b.spans, .{ .size = size, .sans = true, .color = c.st.text });
        const id: u32 = @intCast(c.paras.items.len);
        try c.paras.append(c.gpa, p);
        var tmp: std.ArrayList(Line) = .empty;
        try c.greedy(p, id, 0, width, c.st.text, &tmp);
        // A heading line is ragged: its glue keeps the natural width.
        for (tmp.items) |*l| {
            l.ratio = 0;
            l.ragged = true;
        }
        return tmp.toOwnedSlice(c.a);
    }

    fn addBlocks(c: *Ctx, blocks: []const md.Block, chapter: u32, x: f32, width: f32) !void {
        var after_break = true;
        for (blocks, 0..) |*b, bi| {
            switch (b.kind) {
                .heading => {
                    if (b.level == 1) {
                        const lines = try c.headingLines(b, c.st.h1_size, width);
                        const h = 8 * c.L();
                        try c.addUnit(.{ .kind = .opener, .block = b, .chapter = chapter, .lines = lines, .height = h }, 0, .{ .page_break = c.items.items.len > 0, .chapter = chapter });
                        // The opener has a fixed height of 8 lines.
                        const last = &c.items.items[c.items.items.len - 1];
                        last.k = 8;
                        last.k_top = 8;
                    } else {
                        const size = if (b.level == 2) c.st.h2_size else c.st.h3_size;
                        const lines = try c.headingLines(b, size, width);
                        const nl: f32 = @floatFromInt(lines.len);
                        try c.addUnit(.{ .kind = .heading, .block = b, .chapter = chapter, .lines = lines, .height = nl * size * 1.2 }, 0, .{ .chapter = chapter });
                        const last = &c.items.items[c.items.items.len - 1];
                        const extra: u32 = @intCast(lines.len - 1);
                        last.k = (if (b.level == 2) @as(u32, 3) else 2) + extra;
                        last.k_top = 2 + extra;
                    }
                    after_break = true;
                },
                .para => {
                    const prev_heading = bi > 0 and blocks[bi - 1].kind == .heading;
                    try c.addPara(b.spans, !after_break, x, width, "", chapter, prev_heading);
                    after_break = false;
                },
                .item => {
                    const marker = if (b.ordinal > 0) try std.fmt.allocPrint(c.a, "{d}.", .{b.ordinal}) else "\u{2022}";
                    const hang = c.st.indent * 1.25;
                    for (b.children, 0..) |*k, ki| {
                        if (k.kind == .para) {
                            try c.addPara(k.spans, false, x + hang, width - hang, if (ki == 0) marker else "", chapter, false);
                        } else try c.addBlocks(k[0..1], chapter, x + hang, width - hang);
                    }
                    after_break = true;
                },
                .code => {
                    // An output block after a code block goes in its box.
                    if (b.output and bi > 0 and blocks[bi - 1].kind == .code and !blocks[bi - 1].output) continue;
                    const n: u32 = @intCast(std.mem.count(u8, b.text, "\n") + 1);
                    try c.checkCodeWidth(b);
                    var u: Unit = .{ .kind = .code, .block = b, .chapter = chapter, .code_from = 0, .code_to = n, .height = c.codeHeight(n) };
                    if (!b.output and bi + 1 < blocks.len and blocks[bi + 1].kind == .code and blocks[bi + 1].output) {
                        const o = &blocks[bi + 1];
                        try c.checkCodeWidth(o);
                        const m: u32 = @intCast(std.mem.count(u8, o.text, "\n") + 1);
                        u.extra = o;
                        u.height = c.codeHeight(n + m) + c.st.code_pad;
                    }
                    try c.addUnit(u, c.codeGap(), .{ .chapter = chapter });
                    after_break = true;
                },
                .aside => {
                    var lines: std.ArrayList(Line) = .empty;
                    const pad = c.st.indent;
                    var first = true;
                    for (b.children) |*k| {
                        if (k.kind != .para) continue;
                        const label = if (first) asideLabel(b.aside) else "";
                        const p = try c.buildPara(k.spans, .{ .size = c.st.size * 0.92, .indent = 0, .color = c.st.text, .label = label });
                        first = false;
                        const id: u32 = @intCast(c.paras.items.len);
                        try c.paras.append(c.gpa, p);
                        try c.breakPara(p, id, x + pad, width - 2 * pad, c.st.text, &lines);
                    }
                    c.stats.lines += @intCast(lines.items.len);
                    const nl: f32 = @floatFromInt(lines.items.len);
                    // The lines sit on the grid inside the unit.
                    try c.addUnit(.{ .kind = .aside, .block = b, .chapter = chapter, .lines = try lines.toOwnedSlice(c.a), .height = nl * c.L() }, 0, .{ .chapter = chapter });
                    const last = &c.items.items[c.items.items.len - 1];
                    last.k = @as(u32, @intFromFloat(nl)) + 1;
                    last.k_top = last.k;
                    after_break = true;
                },
                .figure => {
                    try c.addUnit(.{ .kind = .figure, .block = b, .chapter = chapter, .height = 6 * c.L() }, c.codeGap(), .{ .float = true, .chapter = chapter });
                    after_break = true;
                },
            }
        }
    }

    fn checkCodeWidth(c: *Ctx, b: *const md.Block) !void {
        var it = std.mem.splitScalar(u8, b.text, '\n');
        const avail = c.measure() - 2 * c.st.code_pad;
        while (it.next()) |l| {
            const n: u32 = @intCast(std.unicode.utf8CountCodepoints(l) catch l.len);
            if (n > c.stats.widest_code) c.stats.widest_code = n;
            const w = try c.textWidth(c.f.mono, c.st.code_size, l);
            if (w > avail) {
                c.stats.code_wide += 1;
                c.msg("line {d}: a code line is {d:.1} pt wider than the text: {s}", .{ b.line, w - avail, l });
            }
        }
    }

    // ---- pages ----

    const PageItems = struct { items: []u32, chapter: u32 };

    fn paginate(c: *Ctx) ![]PageItems {
        var pages: std.ArrayList(PageItems) = .empty;
        var deferred: std.ArrayList(u32) = .empty;
        var i: u32 = 0;
        const total = c.st.lines;
        while (i < c.items.items.len or deferred.items.len > 0) {
            var content: std.ArrayList(u32) = .empty;
            var used: u32 = 0;
            const page_chapter = if (i < c.items.items.len) c.items.items[i].chapter else 0;
            // Floats from the page before go at the top.
            const d: usize = 0;
            while (d < deferred.items.len) {
                const it = c.items.items[deferred.items[d]];
                const k = if (used == 0) it.k_top else it.k;
                if (used + k <= total) {
                    try content.append(c.a, deferred.items[d]);
                    used += k;
                    _ = deferred.orderedRemove(d);
                } else break;
            }
            var best: ?struct { len: usize, at: u32, used: u32 } = null;
            const start = i;
            while (i < c.items.items.len) {
                const it = &c.items.items[i];
                if (it.page_break and content.items.len > 0) break;
                if (!it.no_break_before and content.items.len > 0 and i > start) best = .{ .len = content.items.len, .at = i, .used = used };
                const k = if (used == 0) it.k_top else it.k;
                if (used + k <= total) {
                    try content.append(c.a, i);
                    used += k;
                    i += 1;
                    continue;
                }
                if (it.float and content.items.len > 0) {
                    try deferred.append(c.a, i);
                    i += 1;
                    continue;
                }
                // A long code block splits when 3 or more lines fit.
                if (it.kind == .unit and c.units.items[it.ref].kind == .code and try c.splitCode(i, total - used, used == 0)) continue;
                if (best) |b| {
                    if (b.at > start) {
                        content.shrinkRetainingCapacity(b.len);
                        // Drop deferred floats past the break: they come again.
                        var q: usize = 0;
                        while (q < deferred.items.len) {
                            if (deferred.items[q] >= b.at) _ = deferred.orderedRemove(q) else q += 1;
                        }
                        i = b.at;
                        break;
                    }
                }
                if (content.items.len == 0) {
                    try content.append(c.a, i);
                    i += 1;
                    c.msg("an item of {d} lines does not fit on a page", .{k});
                }
                break;
            }
            if (content.items.len == 0 and i >= c.items.items.len and deferred.items.len > 0) {
                // A float that fits on no page.
                try content.append(c.a, deferred.orderedRemove(0));
            }
            try pages.append(c.a, .{ .items = try content.toOwnedSlice(c.a), .chapter = page_chapter });
        }
        return pages.toOwnedSlice(c.a);
    }

    /// Splits the code unit of item `i` so its first part fills `room`
    /// lines. Returns false when a part has fewer than 3 lines.
    fn splitCode(c: *Ctx, i: u32, room: u32, at_top: bool) !bool {
        const u = c.units.items[c.items.items[i].ref];
        const n = u.code_to - u.code_from;
        if (n < 6 or u.extra != null) return false;
        var m: u32 = n - 3;
        while (m >= 3) : (m -= 1) {
            if (c.linesFor(c.codeHeight(m), c.codeGap(), at_top) <= room) break;
        }
        if (m < 3) return false;
        var a = u;
        a.code_to = u.code_from + m;
        a.height = c.codeHeight(m);
        var b = u;
        b.code_from = u.code_from + m;
        b.height = c.codeHeight(n - m);
        c.units.items[c.items.items[i].ref] = a;
        const it = c.items.items[i];
        c.items.items[i].k = c.linesFor(a.height, c.codeGap(), false);
        c.items.items[i].k_top = c.linesFor(a.height, c.codeGap(), true);
        const id: u32 = @intCast(c.units.items.len);
        try c.units.append(c.gpa, b);
        try c.items.insert(c.gpa, i + 1, .{ .kind = .unit, .ref = id, .k = c.linesFor(b.height, c.codeGap(), false), .k_top = c.linesFor(b.height, c.codeGap(), true), .chapter = it.chapter });
        return true;
    }

    // ---- render ----

    fn gridY(c: *const Ctx, line: f32) f32 {
        return c.st.page_h - c.st.top - line * c.L();
    }

    fn leftX(c: *const Ctx, folio: u32) f32 {
        return if (folio % 2 == 1) c.st.inner else c.st.outer;
    }

    fn renderPages(c: *Ctx, pages: []const PageItems) !void {
        var chapter_title: []const u8 = "";
        var section: []const u8 = "";
        for (pages, 0..) |pg, pi| {
            const p = try c.doc.addPage(c.st.page_w, c.st.page_h);
            c.cur_page = p;
            const folio: u32 = c.st.first_folio + @as(u32, @intCast(pi));
            c.cur_folio = folio;
            const x0 = c.leftX(folio);
            var used: i32 = 0;
            var opener = false;
            var first_section: []const u8 = "";
            for (pg.items, 0..) |idx, n| {
                const it = c.items.items[idx];
                const k: i32 = @intCast(if (n == 0) it.k_top else it.k);
                switch (it.kind) {
                    .line => try c.renderLine(c.lines.items[it.ref], x0, c.gridY(@floatFromInt(used + k - 1))),
                    .unit => {
                        const u = &c.units.items[it.ref];
                        if (u.kind == .opener) {
                            opener = true;
                            chapter_title = u.title;
                        }
                        if (u.kind == .heading and u.block.level == 2) {
                            section = u.title;
                            if (first_section.len == 0) first_section = u.title;
                        }
                        try c.renderUnit(u, x0, used, k, n == 0);
                    },
                }
                used += k;
            }
            try c.doc.setLabel(p, try std.fmt.allocPrint(c.a, "arabic:{d}", .{c.st.first_folio}));
            try c.renderHead(p, folio, x0, opener, chapter_title, if (first_section.len > 0) first_section else section, pg.chapter);
        }
        c.stats.pages = @intCast(pages.len);
    }

    fn renderHead(c: *Ctx, p: u32, folio: u32, x0: f32, opener: bool, chapter_title: []const u8, section: []const u8, chapter: u32) !void {
        const size = c.st.head_size;
        const num = try std.fmt.allocPrint(c.a, "{d}", .{folio});
        const y_foot = c.gridY(@floatFromInt(c.st.lines - 1)) - 2.6 * c.L();
        if (opener) {
            const w = try c.textWidth(c.f.sans, size + 0.5, num);
            _ = try c.doc.text(p, c.f.sans, size + 0.5, x0 + (c.measure() - w) / 2, y_foot, num, c.st.gray, false);
            return;
        }
        const y = c.st.page_h - c.st.top + 2.2 * c.L();
        const verso = folio % 2 == 0;
        var label: []const u8 = undefined;
        if (verso) {
            label = if (chapter > 0)
                try std.fmt.allocPrint(c.a, "{s} {d}  \u{00b7}  {s}", .{ c.st.chapter_word, chapter, chapter_title })
            else
                chapter_title;
        } else label = section;
        const up = try upper(c.a, label);
        const tr = try c.tracked(c.f.sans, size, up, 0.08);
        const nw = try c.textWidth(c.f.sans_bold, size + 0.5, num);
        if (verso) {
            _ = try c.doc.text(p, c.f.sans_bold, size + 0.5, x0, y, num, c.st.text, false);
            try c.doc.glyphRun(p, c.f.sans, size, x0 + nw + 12, y, tr.glyphs, up, c.st.gray);
        } else {
            const lw = c.widthOf(tr);
            try c.doc.glyphRun(p, c.f.sans, size, x0 + c.measure() - nw - 12 - lw, y, tr.glyphs, up, c.st.gray);
            _ = try c.doc.text(p, c.f.sans_bold, size + 0.5, x0 + c.measure() - nw, y, num, c.st.text, false);
        }
    }

    /// A run with `em` of extra space after each glyph.
    fn tracked(c: *Ctx, font: u32, size: f32, text: []const u8, em: f32) !BoxInfo {
        const b = try c.shape(font, size, text, false);
        const add: i32 = @intFromFloat(em * c.doc.font(font).unitsPerEm());
        for (b.glyphs) |*g| g.advance += add;
        return b;
    }

    fn protrusion(cp: u21) f32 {
        return switch (cp) {
            '.', ',' => 0.6,
            '-', '\u{2013}' => 0.5,
            '\u{2019}', '\u{201d}', '\'' => 0.6,
            ':', ';' => 0.4,
            '\u{2018}', '\u{201c}' => 0.6,
            else => 0,
        };
    }

    fn lastCp(s: []const u8) u21 {
        if (s.len == 0) return 0;
        var i = s.len - 1;
        while (i > 0 and s[i] & 0xc0 == 0x80) i -= 1;
        return std.unicode.utf8Decode(s[i..]) catch 0;
    }

    fn firstCp(s: []const u8) u21 {
        if (s.len == 0) return 0;
        const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0;
        if (n > s.len) return 0;
        return std.unicode.utf8Decode(s[0..n]) catch 0;
    }

    fn renderLine(c: *Ctx, l: Line, x0: f32, y: f32) !void {
        const p = c.paras.items[l.para];
        var start = l.from;
        if (!l.first) {
            while (start < l.to and p.items[start].kind != .box) start += 1;
        }
        const end = l.to;
        // Sums of the line, for the ratio with margin kerning.
        var w: f32 = 0;
        var y_s: f32 = 0;
        var z_s: f32 = 0;
        var last_box: ?u32 = null;
        var first_box: ?u32 = null;
        var k = start;
        while (k < end) : (k += 1) {
            const it = p.items[k];
            switch (it.kind) {
                .box => {
                    w += it.width;
                    if (p.infos[k].glyphs.len > 0) {
                        last_box = k;
                        if (first_box == null) first_box = k;
                    }
                },
                .glue => {
                    w += it.width;
                    y_s += it.stretch;
                    z_s += it.shrink;
                },
                .penalty => {},
            }
        }
        const brk = p.items[end];
        const hyphen = brk.kind == .penalty and brk.width > 0;
        if (hyphen) w += brk.width;
        var pr: f32 = 0;
        var pl: f32 = 0;
        if (hyphen) {
            pr = brk.width * 0.5;
        } else if (last_box) |lb| {
            const inf = p.infos[lb];
            const cp = lastCp(inf.text);
            if (inf.font != c.f.mono and inf.font != c.f.mono_bold) pr = protrusion(cp) * c.doc.font(inf.font).unitsPerEm() * 0 + protrusion(cp) * charWidth(c, inf, cp);
        }
        if (first_box) |fb| {
            const inf = p.infos[fb];
            const cp = firstCp(inf.text);
            if (cp == '\u{201c}' or cp == '\u{2018}') pl = protrusion(cp) * charWidth(c, inf, cp);
        }
        const last_line = brk.kind == .penalty and brk.penalty <= -knuth.inf_penalty;
        const target = l.width + pr + pl;
        var r: f32 = 0;
        if (w < target) {
            r = if (y_s > 0) (target - w) / y_s else 0;
        } else if (w > target) {
            r = if (z_s > 0) (target - w) / z_s else 0;
            if (r < -1) r = -1;
        }
        if ((last_line and w <= target) or (l.ragged and w <= target)) r = 0;
        var x = x0 + l.x - pl;
        if (l.marker.len > 0) {
            const mw = try c.textWidth(c.f.serif, c.st.size, l.marker);
            _ = try c.doc.text(c.cur_page, c.f.serif, c.st.size, x0 + l.x - mw - c.st.indent * 0.5, y, l.marker, c.st.text, false);
        }
        k = start;
        var link_from: ?f32 = null;
        var link_url: []const u8 = "";
        while (k < end) : (k += 1) {
            const it = p.items[k];
            switch (it.kind) {
                .box => {
                    const inf = p.infos[k];
                    if (inf.glyphs.len > 0) {
                        try c.doc.glyphRun(c.cur_page, inf.font, inf.size, x, y, inf.glyphs, inf.text, inf.color);
                        for (inf.index) |term| try c.index.append(c.a, .{ .term = term, .page = c.cur_folio });
                    }
                    if (inf.link.len > 0) {
                        if (link_from == null or !std.mem.eql(u8, link_url, inf.link)) {
                            try c.flushLink(&link_from, link_url, x, y);
                            link_from = x;
                            link_url = inf.link;
                        }
                    } else try c.flushLink(&link_from, link_url, x, y);
                    x += it.width;
                },
                .glue => {
                    x += it.width + (if (r >= 0) r * it.stretch else r * it.shrink);
                },
                .penalty => {},
            }
        }
        if (hyphen) {
            const inf = p.infos[end];
            _ = try c.doc.text(c.cur_page, inf.font, inf.size, x, y, "-", l.color, false);
            x += brk.width;
        }
        try c.flushLink(&link_from, link_url, x, y);
    }

    fn charWidth(c: *Ctx, inf: BoxInfo, cp: u21) f32 {
        const ft = c.doc.font(inf.font);
        return @as(f32, @floatFromInt(ft.advanceOf(cp))) * inf.size / ft.unitsPerEm();
    }

    fn flushLink(c: *Ctx, from: *?f32, url: []const u8, x: f32, y: f32) !void {
        const x1 = from.* orelse return;
        from.* = null;
        if (url.len == 0) return;
        const r = [4]f32{ x1, y - 3, x, y + c.st.size * 0.8 };
        if (url[0] == '#') {
            if (c.targets.get(url[1..])) |t| try c.doc.link(c.cur_page, r, null, t.dest);
        } else try c.doc.link(c.cur_page, r, url, null);
    }

    fn renderUnit(c: *Ctx, u: *Unit, x0: f32, used: i32, k: i32, at_top: bool) !void {
        const L_ = c.L();
        // The area between the text line before and the text line after.
        const top_y: f32 = if (at_top) c.gridY(0) + c.bodyAsc() else c.gridY(@floatFromInt(used - 1)) - c.bodyDesc();
        const bottom_y: f32 = c.gridY(@floatFromInt(used + k)) + c.bodyAsc();
        const page = c.cur_page;
        switch (u.kind) {
            .opener => {
                const b = u.block;
                const label = if (u.chapter > 0) try std.fmt.allocPrint(c.a, "{s} {d}", .{ c.st.chapter_word, u.chapter }) else "";
                const y_label = c.gridY(1);
                if (label.len > 0) {
                    const up = try upper(c.a, label);
                    const t = try c.tracked(c.f.sans_bold, 9, up, 0.12);
                    try c.doc.glyphRun(page, c.f.sans_bold, 9, x0, y_label, t.glyphs, up, c.st.gray);
                }
                var y = c.gridY(3);
                for (u.lines) |l| {
                    try c.renderHeadingLine(l, x0, y, c.f.sans_bold);
                    y -= c.st.h1_size * 1.15;
                }
                const rule_y = y + c.st.h1_size * 1.15 - c.st.h1_size * 0.55;
                try c.doc.line(page, x0, rule_y, x0 + c.measure(), rule_y, 0.6, c.st.rule);
                try c.doc.addDest(b.id, page, x0, c.gridY(0) + 20);
                try c.doc.addOutline(u.title, 1, page, c.gridY(0) + 20);
            },
            .heading => {
                const b = u.block;
                const size = if (b.level == 2) c.st.h2_size else c.st.h3_size;
                const nl: f32 = @floatFromInt(u.lines.len);
                // The last heading line sits a fixed space above the next text line.
                const after: f32 = if (b.level == 2) 1.45 * L_ else 1.3 * L_;
                var y = c.gridY(@floatFromInt(used + k)) + after + (nl - 1) * size * 1.2;
                if (at_top) y = @min(y, c.gridY(0));
                if (b.number.len > 0) {
                    const nw = try c.textWidth(c.f.sans, size, b.number);
                    _ = try c.doc.text(page, c.f.sans, size, x0 - nw - 8, y, b.number, c.st.gray, false);
                }
                const ytop = y;
                for (u.lines) |l| {
                    try c.renderHeadingLine(l, x0, y, c.f.sans_bold);
                    y -= size * 1.2;
                }
                if (b.id.len > 0) try c.doc.addDest(b.id, page, x0 - 30, ytop + size + 4);
                try c.doc.addOutline(u.title, b.level, page, ytop + size + 4);
            },
            .code => {
                const b = u.block;
                const h = u.height;
                const mid = (top_y + bottom_y) / 2;
                const box_top = if (at_top) top_y else mid + h / 2;
                const box_w = c.measure();
                try c.doc.rect(page, x0, box_top - h, box_w, h, if (b.output) .{ 1, 1, 1 } else c.st.code_bg);
                if (b.output) try c.doc.rect(page, x0, box_top - h, 1.2, h, c.st.rule);
                var y = box_top - c.st.code_pad - c.st.code_size * 0.78;
                var it = std.mem.splitScalar(u8, b.text, '\n');
                var n: u32 = 0;
                while (it.next()) |line| : (n += 1) {
                    if (n < u.code_from) continue;
                    if (n >= u.code_to) break;
                    try c.renderCodeLine(b, line, x0 + c.st.code_pad, y);
                    y -= c.st.code_leading;
                }
                if (u.extra) |o| {
                    // A thin rule, then the output.
                    const ry = y + c.st.code_leading - c.st.code_size * 0.3 - c.st.code_pad * 0.5;
                    try c.doc.line(page, x0 + c.st.code_pad, ry, x0 + box_w - c.st.code_pad, ry, 0.4, c.st.rule);
                    y -= c.st.code_pad;
                    var ot = std.mem.splitScalar(u8, o.text, '\n');
                    while (ot.next()) |line| {
                        try c.renderCodeLine(o, line, x0 + c.st.code_pad, y);
                        y -= c.st.code_leading;
                    }
                }
            },
            .aside => {
                const b = u.block;
                const n: f32 = @floatFromInt(u.lines.len);
                const first_base = c.gridY(@floatFromInt(used + 1)) + (if (at_top) L_ else 0);
                const last_base = first_base - (n - 1) * L_;
                const pad = 0.42 * L_;
                const box_top = first_base + c.bodyAsc() + pad;
                const box_bot = last_base - c.bodyDesc() - pad;
                const missing = std.mem.eql(u8, b.aside, "MISSING");
                try c.doc.rect(page, x0, box_bot, c.measure(), box_top - box_bot, if (missing) .{ 0.985, 0.96, 0.92 } else c.st.aside_bg);
                try c.doc.rect(page, x0, box_bot, 2, box_top - box_bot, if (missing) .{ 0.8, 0.55, 0.2 } else .{ 0.45, 0.55, 0.7 });
                var y = first_base;
                for (u.lines) |l| {
                    try c.renderLine(l, x0, y);
                    y -= L_;
                }
            },
            .figure => {
                const b = u.block;
                _ = b;
                const mid = (top_y + bottom_y) / 2;
                if (u.image) |img| try c.doc.image(page, img, x0 + (c.measure() - u.img_w) / 2, mid - u.img_h / 2, u.img_w, u.img_h);
            },
            .index_head => {},
        }
    }

    fn renderHeadingLine(c: *Ctx, l: Line, x0: f32, y: f32, font: u32) !void {
        _ = font;
        try c.renderLine(l, x0, y);
    }

    // ---- code ----

    const TokKind = enum { plain, comment, prompt, keyword, output, string };

    fn renderCodeLine(c: *Ctx, b: *const md.Block, line: []const u8, x0: f32, y: f32) !void {
        var x = x0;
        const size = c.st.code_size;
        const Tok = struct { text: []const u8, kind: TokKind };
        var toks: std.ArrayList(Tok) = .empty;
        const sh = std.mem.eql(u8, b.lang, "sh") or std.mem.eql(u8, b.lang, "console") or std.mem.eql(u8, b.lang, "shell");
        const tcl = std.mem.eql(u8, b.lang, "tcl");
        if (b.output) {
            try toks.append(c.a, .{ .text = line, .kind = .output });
        } else if (sh) {
            if (std.mem.startsWith(u8, line, "$ ")) {
                try toks.append(c.a, .{ .text = "$ ", .kind = .prompt });
                const rest = line[2..];
                const hash = commentStart(rest);
                try toks.append(c.a, .{ .text = rest[0..hash], .kind = .plain });
                if (hash < rest.len) try toks.append(c.a, .{ .text = rest[hash..], .kind = .comment });
            } else if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "#")) {
                try toks.append(c.a, .{ .text = line, .kind = .comment });
            } else try toks.append(c.a, .{ .text = line, .kind = if (b.run) .output else .plain });
        } else if (tcl) {
            const t = std.mem.trimStart(u8, line, " ");
            if (std.mem.startsWith(u8, t, "#")) {
                try toks.append(c.a, .{ .text = line, .kind = .comment });
            } else {
                // A keyword at the start of a command is bold.
                var i: usize = 0;
                var cmd_start = true;
                while (i < line.len) {
                    const ch = line[i];
                    if (ch == ' ' or ch == '\t') {
                        var j = i;
                        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
                        try toks.append(c.a, .{ .text = line[i..j], .kind = .plain });
                        i = j;
                        continue;
                    }
                    if (ch == '[' or ch == '{' or ch == ';') {
                        try toks.append(c.a, .{ .text = line[i .. i + 1], .kind = .plain });
                        i += 1;
                        cmd_start = true;
                        continue;
                    }
                    if (ch == '"') {
                        var j = i + 1;
                        while (j < line.len and line[j] != '"') : (j += 1) {
                            if (line[j] == '\\') j += 1;
                        }
                        j = @min(j + 1, line.len);
                        try toks.append(c.a, .{ .text = line[i..j], .kind = .string });
                        i = j;
                        cmd_start = false;
                        continue;
                    }
                    var j = i;
                    while (j < line.len and line[j] != ' ' and line[j] != '\t' and line[j] != '[' and line[j] != ']' and line[j] != '{' and line[j] != '}' and line[j] != ';') j += 1;
                    if (j == i) j = i + 1;
                    const word = line[i..j];
                    try toks.append(c.a, .{ .text = word, .kind = if (cmd_start and isKeyword(word)) .keyword else .plain });
                    cmd_start = false;
                    i = j;
                }
            }
        } else try toks.append(c.a, .{ .text = line, .kind = .plain });
        for (toks.items) |t| {
            if (t.text.len == 0) continue;
            const font = if (t.kind == .keyword) c.f.mono_bold else c.f.mono;
            const color: Rgb = switch (t.kind) {
                .comment, .prompt => c.st.gray,
                .output => .{ 0.25, 0.25, 0.25 },
                .string => .{ 0.1, 0.1, 0.1 },
                else => c.st.text,
            };
            x += try c.doc.text(c.cur_page, font, size, x, y, t.text, color, false);
        }
    }

    // ---- the index ----

    fn renderIndex(c: *Ctx) !void {
        if (c.index.items.len == 0) return;
        const Entry = struct { term: []const u8, pages: std.ArrayList(u32) };
        var map: std.StringArrayHashMapUnmanaged(std.ArrayList(u32)) = .empty;
        for (c.index.items) |m| {
            const gop = try map.getOrPut(c.a, m.term);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            if (std.mem.indexOfScalar(u32, gop.value_ptr.items, m.page) == null) try gop.value_ptr.append(c.a, m.page);
        }
        var entries: std.ArrayList(Entry) = .empty;
        var it = map.iterator();
        while (it.next()) |e| try entries.append(c.a, .{ .term = e.key_ptr.*, .pages = e.value_ptr.* });
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lt(_: void, x: Entry, y: Entry) bool {
                return std.ascii.lessThanIgnoreCase(sortKey(x.term), sortKey(y.term));
            }
        }.lt);
        // Two columns on pages of their own.
        const col_gap: f32 = 18;
        const col_w = (c.measure() - col_gap) / 2;
        var page_no: u32 = c.st.first_folio + c.stats.pages;
        var p = try c.doc.addPage(c.st.page_w, c.st.page_h);
        c.cur_page = p;
        var x0 = c.leftX(page_no);
        _ = try c.doc.text(p, c.f.sans_bold, c.st.h1_size, x0, c.gridY(3.4), "Index", c.st.text, true);
        try c.doc.addOutline("Index", 1, p, c.gridY(0) + 20);
        var line: u32 = 8;
        var col: u32 = 0;
        var letter: u8 = 0;
        for (entries.items) |e| {
            const first = std.ascii.toUpper(sortKey(e.term)[0]);
            const need: u32 = if (first != letter) 2 else 1;
            if (line + need > c.st.lines) {
                col += 1;
                line = if (page_no == c.st.first_folio + c.stats.pages) 8 else 0;
                if (col == 2) {
                    col = 0;
                    line = 0;
                    page_no += 1;
                    p = try c.doc.addPage(c.st.page_w, c.st.page_h);
                    c.cur_page = p;
                    x0 = c.leftX(page_no);
                }
            }
            const cx = x0 + @as(f32, @floatFromInt(col)) * (col_w + col_gap);
            if (first != letter) {
                if (line > 0 and line != 8) line += 1;
                letter = first;
            }
            var s: std.ArrayList(u8) = .empty;
            try s.appendSlice(c.a, e.term);
            for (e.pages.items, 0..) |pgn, i| try s.print(c.a, "{s}{d}", .{ if (i == 0) ", " else ", ", pgn });
            _ = try c.doc.text(p, c.f.serif, c.st.size * 0.9, cx, c.gridY(@floatFromInt(line)), s.items, c.st.text, true);
            line += 1;
        }
        c.stats.pages += page_no - (c.st.first_folio + c.stats.pages) + 1;
    }
};

fn sortKey(t: []const u8) []const u8 {
    var i: usize = 0;
    while (i < t.len and !std.ascii.isAlphanumeric(t[i])) i += 1;
    return if (i < t.len) t[i..] else t;
}

fn isKeyword(w: []const u8) bool {
    const kw = [_][]const u8{ "proc", "set", "if", "else", "elseif", "foreach", "for", "while", "return", "puts", "package", "namespace", "expr", "incr", "list", "dict", "string", "try", "catch", "switch", "lappend", "variable", "global", "upvar", "error", "throw", "break", "continue", "apply", "coroutine", "yield", "oo::class", "method", "constructor" };
    for (kw) |k| if (std.mem.eql(u8, k, w)) return true;
    return false;
}

fn commentStart(s: []const u8) usize {
    var i: usize = 0;
    var q: u8 = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (q != 0) {
            if (ch == q) q = 0;
            continue;
        }
        if (ch == '\'' or ch == '"') q = ch;
        if (ch == '#' and (i == 0 or s[i - 1] == ' ')) {
            // Keep the spaces before the comment with the command.
            return i;
        }
    }
    return s.len;
}

fn asideLabel(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "NOTE")) return "Note:";
    if (std.mem.eql(u8, kind, "HINT")) return "Hint:";
    if (std.mem.eql(u8, kind, "WARNING")) return "Warning:";
    if (std.mem.eql(u8, kind, "MISSING")) return "Not yet in ztcl:";
    return "";
}

fn upper(a: Allocator, s: []const u8) ![]u8 {
    const out = try a.dupe(u8, s);
    for (out) |*ch| ch.* = std.ascii.toUpper(ch.*);
    return out;
}

fn plainText(a: Allocator, spans: []const md.Span) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    for (spans) |sp| if (sp.kind == .text) try s.appendSlice(a, sp.text);
    return s.toOwnedSlice(a);
}

/// Compares the output of a run with the expected text, line by line,
/// with the trailing spaces of each line and the last newlines removed.
/// With `glob`, `*` in an expected line matches any text.
fn sameOutput(got: []const u8, want: []const u8, glob: bool) bool {
    var g = std.mem.splitScalar(u8, std.mem.trimEnd(u8, got, "\n"), '\n');
    var w = std.mem.splitScalar(u8, std.mem.trimEnd(u8, want, "\n"), '\n');
    while (true) {
        const a = g.next();
        const b = w.next();
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        const x = std.mem.trimEnd(u8, a.?, " \t\r");
        const y = std.mem.trimEnd(u8, b.?, " \t\r");
        if (glob) {
            if (!globMatch(y, x)) return false;
        } else if (!std.mem.eql(u8, x, y)) return false;
    }
}

fn globMatch(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;
    if (p[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) if (globMatch(p[1..], s[i..])) return true;
        return false;
    }
    return s.len > 0 and s[0] == p[0] and globMatch(p[1..], s[1..]);
}

/// Runs the code blocks with the flag `run` and compares the output.
fn checkBlocks(c: *Ctx, runner: Runner, ch: Chapter, blocks: []const md.Block) !void {
    for (blocks, 0..) |*b, i| {
        if (b.kind == .aside or b.kind == .item) try checkBlocks(c, runner, ch, b.children);
        if (b.kind != .code or !b.run) continue;
        if (std.mem.eql(u8, b.lang, "sh")) {
            // Each `$ ` line is a command; the lines after it are its output.
            var cmds: std.ArrayList([]const u8) = .empty;
            var outs: std.ArrayList(std.ArrayList(u8)) = .empty;
            var it = std.mem.splitScalar(u8, b.text, '\n');
            while (it.next()) |l| {
                if (std.mem.startsWith(u8, l, "$ ")) {
                    try cmds.append(c.a, l[2..]);
                    try outs.append(c.a, .empty);
                } else if (outs.items.len > 0) {
                    const o = &outs.items[outs.items.len - 1];
                    try o.appendSlice(c.a, l);
                    try o.append(c.a, '\n');
                }
            }
            for (cmds.items, outs.items) |cmd, want| {
                c.stats.checked += 1;
                const got = runner.run(runner.ctx, c.a, "sh", cmd) catch |e| {
                    c.msg("{s}:{d}: the command `{s}` failed: {s}", .{ ch.name, b.line, cmd, @errorName(e) });
                    continue;
                };
                if (!sameOutput(got, want.items, b.glob)) c.msg("{s}:{d}: the output of `{s}` differs.\n--- expected\n{s}--- got\n{s}", .{ ch.name, b.line, cmd, want.items, got });
            }
        } else {
            c.stats.checked += 1;
            const got = runner.run(runner.ctx, c.a, b.lang, b.text) catch |e| {
                c.msg("{s}:{d}: the {s} block failed: {s}", .{ ch.name, b.line, b.lang, @errorName(e) });
                continue;
            };
            const want: []const u8 = if (i + 1 < blocks.len and blocks[i + 1].kind == .code and blocks[i + 1].output) blocks[i + 1].text else "";
            const glob = b.glob or (i + 1 < blocks.len and blocks[i + 1].glob);
            if (!sameOutput(got, want, glob)) c.msg("{s}:{d}: the output of the {s} block differs.\n--- expected\n{s}\n--- got\n{s}", .{ ch.name, b.line, b.lang, want, got });
        }
    }
}

/// Numbers the headings and records the targets of the cross references.
fn collect(c: *Ctx, ch: Chapter, blocks: []md.Block, sec: *u32, fig: *u32) !void {
    for (blocks) |*b| {
        switch (b.kind) {
            .heading => {
                const title = try plainText(c.a, b.spans);
                var text: []const u8 = title;
                if (b.level == 1) {
                    if (ch.number > 0) text = try std.fmt.allocPrint(c.a, "{s} {d}", .{ c.st.chapter_word, ch.number });
                    if (b.id.len == 0) b.id = try std.fmt.allocPrint(c.a, "chapter-{d}", .{ch.number});
                } else if (b.level == 2) {
                    sec.* += 1;
                    if (ch.number > 0) {
                        b.number = try std.fmt.allocPrint(c.a, "{d}.{d}", .{ ch.number, sec.* });
                        text = try std.fmt.allocPrint(c.a, "Section {s}", .{b.number});
                    }
                } else text = try std.fmt.allocPrint(c.a, "\u{201c}{s}\u{201d}", .{title});
                if (b.id.len == 0) b.id = try std.fmt.allocPrint(c.a, "h-{d}-{d}", .{ ch.number, b.line });
                try c.targets.put(c.a, b.id, .{ .text = text, .dest = b.id });
            },
            .figure => {
                fig.* += 1;
                if (b.id.len > 0) try c.targets.put(c.a, b.id, .{ .text = try std.fmt.allocPrint(c.a, "Figure {d}.{d}", .{ ch.number, fig.* }), .dest = b.id });
            },
            .aside, .item => try collect(c, ch, b.children, sec, fig),
            else => {},
        }
    }
}

/// Lays out `chapters` into new pages of `doc`. Messages (failed runs,
/// unknown references, wide code) go in `msgs`; the caller decides if
/// they are errors. `arena` holds the work data.
pub fn typeset(gpa: Allocator, arena: Allocator, doc: *pdf.Doc, fonts: Fonts, style: Style, hy: *const hyph.Hyphenator, chapters: []const Chapter, runner: ?Runner, msgs: *std.ArrayList(u8), max_steps: usize) !Stats {
    var c: Ctx = .{ .gpa = gpa, .a = arena, .doc = doc, .f = fonts, .st = style, .hy = hy, .msgs = msgs, .max_steps = max_steps };
    defer {
        c.paras.deinit(gpa);
        c.lines.deinit(gpa);
        c.units.deinit(gpa);
        c.items.deinit(gpa);
    }
    const parsed = try arena.alloc([]md.Block, chapters.len);
    for (chapters, 0..) |ch, i| {
        parsed[i] = try md.parse(arena, ch.source);
        var sec: u32 = 0;
        var fig: u32 = 0;
        try collect(&c, ch, parsed[i], &sec, &fig);
        if (runner) |r| try checkBlocks(&c, r, ch, parsed[i]);
    }
    const m = c.measure();
    for (chapters, 0..) |ch, i| {
        const start_units = c.units.items.len;
        try c.addBlocks(parsed[i], ch.number, 0, m);
        for (c.units.items[start_units..]) |*u| {
            if (u.kind == .heading or u.kind == .opener) u.title = try plainText(arena, u.block.spans);
        }
    }
    const pages = try c.paginate();
    try c.renderPages(pages);
    try c.renderIndex();
    return c.stats;
}

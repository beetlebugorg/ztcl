//! The commands `ztcl::pdf` and `ztcl::typeset`.
//!
//! `ztcl::pdf` makes a PDF document: pages, text in embedded TrueType
//! fonts, rectangles, lines, images, links, named targets, the outline,
//! and the document information (`pdf.zig`). A handle `pdfN` is the
//! index N in the state of the interpreter. `ztcl::typeset` breaks
//! paragraphs into lines (`knuth.zig`), hyphenates words (`hyph.zig`),
//! and lays out Markdown chapters into the pages of a document
//! (`layout.zig`).
//!
//! The commands reach no file and no other resource of the host, so
//! they need no capability. A script reads the font and image files and
//! writes the bytes of the PDF. Each command uses compute units: one for
//! each 4,096 bytes that it reads or writes, and one for each 64 steps
//! of the line breaker. A font or an image has at most 64 MiB, and a
//! document has at most 100,000 pages.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("../interp.zig");
const mods = @import("../modules.zig");
const value = @import("../value.zig");
const more = @import("../more.zig");
const pdf = @import("pdf.zig");
const hyph = @import("hyph.zig");
const knuth = @import("knuth.zig");
const layout = @import("layout.zig");
const para = @import("para.zig");
const Font = @import("font.zig").Font;

const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;

const max_bytes = 64 << 20;
const max_pages = 100_000;

pub const modules_list = [_]mods.Module{
    .{ .name = "ztcl::pdf", .version = "1.0", .install = installPdf },
    .{ .name = "ztcl::typeset", .version = "1.0", .install = installTypeset },
};

pub const modules: []const mods.Module = &modules_list;

const FontRec = struct { data: []u8, font: Font };

const State = struct {
    docs: std.ArrayList(?*pdf.Doc) = .empty,
    fonts: std.ArrayList(FontRec) = .empty,
    hy: ?hyph.Hyphenator = null,
};

fn installPdf(it: *Interp) Error!void {
    try it.register("ztcl::pdf", pdfCmd);
}

fn installTypeset(it: *Interp) Error!void {
    try it.register("ztcl::typeset", typesetCmd);
}

/// Frees each document of `it`. `Interp.deinit` calls it.
pub fn closeAll(it: *Interp) void {
    const s: *State = @ptrCast(@alignCast(it.typeset_state orelse return));
    const gpa = it.heap.backing;
    for (s.docs.items) |d| if (d) |p| {
        p.deinit();
        gpa.destroy(p);
    };
    s.docs.deinit(gpa);
    for (s.fonts.items) |f| gpa.free(f.data);
    s.fonts.deinit(gpa);
    if (s.hy) |*h| h.deinit();
    gpa.destroy(s);
    it.typeset_state = null;
}

fn state(it: *Interp) Error!*State {
    if (it.typeset_state) |p| return @ptrCast(@alignCast(p));
    const s = try it.heap.backing.create(State);
    s.* = .{};
    it.typeset_state = s;
    return s;
}

fn hyphenator(it: *Interp) Error!*hyph.Hyphenator {
    const s = try state(it);
    if (s.hy == null) s.hy = try hyph.Hyphenator.init(it.heap.backing, hyph.en_us_patterns, hyph.en_us_exceptions);
    return &s.hy.?;
}

fn charge(it: *Interp, units: u64) Error!void {
    if (units == 0) return;
    if (it.compute_limit < units) {
        it.compute_limit = 0;
        return it.fail("compute limit reached", .{});
    }
    it.compute_limit -= units;
}

fn lookup(it: *Interp, v: Value) Error!*pdf.Doc {
    const name = try it.str(v);
    const s = try state(it);
    if (std.mem.startsWith(u8, name, "pdf")) {
        if (std.fmt.parseInt(usize, name[3..], 10)) |i| {
            if (i < s.docs.items.len) if (s.docs.items[i]) |d| return d;
        } else |_| {}
    }
    return it.failCode("ZTCL PDF HANDLE", "can not find document \"{s}\"", .{name});
}

fn num(it: *Interp, v: Value) Error!f32 {
    const n = v.asNumber() orelse return it.fail("expected number but got \"{s}\"", .{try it.str(v)});
    const d: f64 = switch (n) {
        .int => |i| @floatFromInt(i),
        .double => |x| x,
        else => unreachable,
    };
    if (!std.math.isFinite(d) or @abs(d) > 1e7) return it.failCode("ZTCL PDF NUMBER", "the number {d} is outside the range of a PDF", .{d});
    return @floatCast(d);
}

fn index(it: *Interp, v: Value, count: usize, what: []const u8) Error!u32 {
    const i = try it.int(v);
    if (i < 0 or i >= count) return it.failCode("ZTCL PDF INDEX", "there is no {s} {d}", .{ what, i });
    return @intCast(i);
}

fn color(it: *Interp, v: Value) Error!pdf.Rgb {
    const items = try it.list(v);
    if (items.len != 3) return it.failCode("ZTCL PDF COLOR", "a color is a list of 3 numbers from 0 to 1", .{});
    var c: pdf.Rgb = undefined;
    for (items, 0..) |x, i| c[i] = std.math.clamp(try num(it, x), 0, 1);
    return c;
}

fn docError(it: *Interp, e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadFont => it.failCode("ZTCL PDF FONT", "the font is not a valid TrueType font", .{}),
        error.Unsupported => it.failCode("ZTCL PDF UNSUPPORTED", "the file has a form that ztcl::pdf does not read (CFF outlines, a font collection, a variable font, or an interlaced or 16-bit PNG)", .{}),
        error.BadImage => it.failCode("ZTCL PDF IMAGE", "the image is not a valid PNG or JPEG file", .{}),
        error.BadDest => it.failCode("ZTCL PDF DEST", "a link names a target that the document does not have", .{}),
        error.BadPage => it.failCode("ZTCL PDF INDEX", "there is no such page", .{}),
        error.TooMuchWork => it.fail("compute limit reached", .{}),
        else => it.fail("ztcl::pdf: {s}", .{@errorName(e)}),
    };
}

fn bytesArg(it: *Interp, v: Value) Error![]const u8 {
    const b = try more.toBytes(it, try it.str(v));
    if (b.len > max_bytes) return it.failCode("ZTCL PDF SIZE", "the data has more than 64 MiB", .{});
    try charge(it, b.len / 4096);
    return b;
}

/// Reads `-name value` options from `argv`. Returns the value of each
/// name in `names`, or null.
fn options(it: *Interp, argv: []const Value, comptime names: []const []const u8, comptime usage: []const u8) Error![names.len]?Value {
    var out: [names.len]?Value = @splat(null);
    var i: usize = 0;
    outer: while (i < argv.len) : (i += 2) {
        const k = try it.str(argv[i]);
        inline for (names, 0..) |n, j| {
            if (std.mem.eql(u8, k, n)) {
                if (i + 1 >= argv.len) return it.wrongArgs(usage);
                out[j] = argv[i + 1];
                continue :outer;
            }
        }
        return it.fail("unknown option \"{s}\": the options are {s}", .{ k, comptime blk: {
            var s: []const u8 = "";
            for (names, 0..) |n, j| s = s ++ (if (j == 0) "" else ", ") ++ n;
            break :blk s;
        } });
    }
    return out;
}

const pdf_usage = "ztcl::pdf create|font|page|text|measure|rect|line|image|place|link|dest|outline|info|bytes|pages|delete ?arg ...?";

fn pdfCmd(it: *Interp, argv: []const Value, _: ?*interp.Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs(pdf_usage);
    const sub = try it.str(argv[1]);
    const s = try state(it);
    const gpa = it.heap.backing;
    if (std.mem.eql(u8, sub, "create")) {
        const o = try options(it, argv[2..], &.{"-compress"}, "ztcl::pdf create ?-compress bool?");
        const d = try gpa.create(pdf.Doc);
        d.* = pdf.Doc.init(gpa);
        if (o[0]) |v| d.compress = (v.asInt() orelse 1) != 0;
        try s.docs.append(gpa, d);
        return .{ .str = try std.fmt.allocPrint(it.alloc(), "pdf{d}", .{s.docs.items.len - 1}) };
    }
    if (argv.len < 3) return it.wrongArgs(pdf_usage);
    const d = try lookup(it, argv[2]);
    if (std.mem.eql(u8, sub, "font")) {
        if (argv.len != 4) return it.wrongArgs("ztcl::pdf font doc bytes");
        const id = d.addFont(try bytesArg(it, argv[3])) catch |e| return docError(it, e);
        return .{ .int = id };
    }
    if (std.mem.eql(u8, sub, "page")) {
        if (argv.len != 3 and argv.len != 5) return it.wrongArgs("ztcl::pdf page doc ?width height?");
        if (d.pages.items.len >= max_pages) return it.failCode("ZTCL PDF SIZE", "a document has at most 100,000 pages", .{});
        const w: f32 = if (argv.len == 5) try num(it, argv[3]) else 595.276;
        const h: f32 = if (argv.len == 5) try num(it, argv[4]) else 841.89;
        if (w < 1 or h < 1 or w > 14400 or h > 14400) return it.failCode("ZTCL PDF NUMBER", "a page side is from 1 to 14400 points", .{});
        return .{ .int = d.addPage(w, h) catch |e| return docError(it, e) };
    }
    if (std.mem.eql(u8, sub, "text")) {
        const usage = "ztcl::pdf text doc page font size x y string ?-color rgb? ?-ligatures bool?";
        if (argv.len < 9) return it.wrongArgs(usage);
        const o = try options(it, argv[9..], &.{ "-color", "-ligatures" }, usage);
        const pg = try index(it, argv[3], d.pages.items.len, "page");
        const f = try index(it, argv[4], d.fonts.items.len, "font");
        const text = try it.str(argv[8]);
        try charge(it, 1 + text.len / 256);
        const w = d.text(pg, f, try num(it, argv[5]), try num(it, argv[6]), try num(it, argv[7]), text, if (o[0]) |c| try color(it, c) else .{ 0, 0, 0 }, if (o[1]) |l| (l.asInt() orelse 1) != 0 else true) catch |e| return docError(it, e);
        return .{ .double = w };
    }
    if (std.mem.eql(u8, sub, "measure")) {
        if (argv.len != 6) return it.wrongArgs("ztcl::pdf measure doc font size string");
        const f = try index(it, argv[3], d.fonts.items.len, "font");
        const text = try it.str(argv[5]);
        try charge(it, 1 + text.len / 256);
        const ft = d.font(f);
        const g = ft.shape(gpa, text, true) catch return error.OutOfMemory;
        defer gpa.free(g);
        var w: i64 = 0;
        for (g) |x| w += x.advance;
        return .{ .double = @as(f64, @floatFromInt(w)) * (try num(it, argv[4])) / ft.unitsPerEm() };
    }
    if (std.mem.eql(u8, sub, "rect")) {
        const usage = "ztcl::pdf rect doc page x y width height ?-fill rgb?";
        if (argv.len < 8) return it.wrongArgs(usage);
        const o = try options(it, argv[8..], &.{"-fill"}, usage);
        const pg = try index(it, argv[3], d.pages.items.len, "page");
        d.rect(pg, try num(it, argv[4]), try num(it, argv[5]), try num(it, argv[6]), try num(it, argv[7]), if (o[0]) |c| try color(it, c) else .{ 0, 0, 0 }) catch |e| return docError(it, e);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "line")) {
        const usage = "ztcl::pdf line doc page x0 y0 x1 y1 ?-width w? ?-color rgb?";
        if (argv.len < 8) return it.wrongArgs(usage);
        const o = try options(it, argv[8..], &.{ "-width", "-color" }, usage);
        const pg = try index(it, argv[3], d.pages.items.len, "page");
        d.line(pg, try num(it, argv[4]), try num(it, argv[5]), try num(it, argv[6]), try num(it, argv[7]), if (o[0]) |v| try num(it, v) else 1, if (o[1]) |c| try color(it, c) else .{ 0, 0, 0 }) catch |e| return docError(it, e);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "image")) {
        if (argv.len != 4) return it.wrongArgs("ztcl::pdf image doc bytes");
        const id = d.addImage(try bytesArg(it, argv[3])) catch |e| return docError(it, e);
        const sz = d.imageSize(id);
        return value.wrapList(it.alloc(), try it.alloc().dupe(Value, &.{ .{ .int = id }, .{ .int = sz[0] }, .{ .int = sz[1] } }));
    }
    if (std.mem.eql(u8, sub, "place")) {
        if (argv.len != 9) return it.wrongArgs("ztcl::pdf place doc page image x y width height");
        const pg = try index(it, argv[3], d.pages.items.len, "page");
        const im = try index(it, argv[4], d.images.items.len, "image");
        d.image(pg, im, try num(it, argv[5]), try num(it, argv[6]), try num(it, argv[7]), try num(it, argv[8])) catch |e| return docError(it, e);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "link")) {
        const usage = "ztcl::pdf link doc page x0 y0 x1 y1 -uri url|-dest name";
        if (argv.len != 10) return it.wrongArgs(usage);
        const pg = try index(it, argv[3], d.pages.items.len, "page");
        const r = [4]f32{ try num(it, argv[4]), try num(it, argv[5]), try num(it, argv[6]), try num(it, argv[7]) };
        const kind = try it.str(argv[8]);
        const target = try it.str(argv[9]);
        if (std.mem.eql(u8, kind, "-uri")) {
            d.link(pg, r, target, null) catch |e| return docError(it, e);
        } else if (std.mem.eql(u8, kind, "-dest")) {
            d.link(pg, r, null, target) catch |e| return docError(it, e);
        } else return it.wrongArgs(usage);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "dest")) {
        if (argv.len != 7) return it.wrongArgs("ztcl::pdf dest doc name page x y");
        const pg = try index(it, argv[4], d.pages.items.len, "page");
        d.addDest(try it.str(argv[3]), pg, try num(it, argv[5]), try num(it, argv[6])) catch |e| return docError(it, e);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "outline")) {
        if (argv.len != 7) return it.wrongArgs("ztcl::pdf outline doc title level page y");
        const lv = try it.int(argv[4]);
        if (lv < 1 or lv > 16) return it.failCode("ZTCL PDF INDEX", "the level {d} is outside 1 to 16", .{lv});
        const pg = try index(it, argv[5], d.pages.items.len, "page");
        d.addOutline(try it.str(argv[3]), @intCast(lv), pg, try num(it, argv[6])) catch |e| return docError(it, e);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "info")) {
        if (argv.len != 5) return it.wrongArgs("ztcl::pdf info doc key value");
        const k = try it.str(argv[3]);
        for (pdf.Doc.info_keys, 0..) |name, i| {
            if (std.ascii.eqlIgnoreCase(name, k)) {
                d.setInfo(i, try it.str(argv[4])) catch |e| return docError(it, e);
                return Value.empty;
            }
        }
        return it.fail("unknown key \"{s}\": the keys are Title, Author, Subject, and Keywords", .{k});
    }
    if (std.mem.eql(u8, sub, "bytes")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::pdf bytes doc");
        const b = d.write() catch |e| return docError(it, e);
        defer gpa.free(b);
        try charge(it, b.len / 4096);
        return .{ .str = try more.fromBytes(it, try it.alloc().dupe(u8, b)) };
    }
    if (std.mem.eql(u8, sub, "pages")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::pdf pages doc");
        return .{ .int = @intCast(d.pages.items.len) };
    }
    if (std.mem.eql(u8, sub, "delete")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::pdf delete doc");
        const name = try it.str(argv[2]);
        const i = std.fmt.parseInt(usize, name[3..], 10) catch unreachable;
        d.deinit();
        gpa.destroy(d);
        s.docs.items[i] = null;
        return Value.empty;
    }
    return it.fail("unknown subcommand \"{s}\": must be {s}", .{ sub, pdf_usage[10..] });
}

const ts_usage = "ztcl::typeset hyphenate|break|justify|svg|pages|font|book|markdown ?arg ...?";

fn typesetCmd(it: *Interp, argv: []const Value, _: ?*interp.Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs(ts_usage);
    const sub = try it.str(argv[1]);
    if (std.mem.eql(u8, sub, "hyphenate")) return cmdHyphenate(it, argv);
    if (std.mem.eql(u8, sub, "break")) return cmdBreak(it, argv);
    if (std.mem.eql(u8, sub, "justify")) return cmdJustify(it, argv);
    if (std.mem.eql(u8, sub, "svg")) return cmdSvg(it, argv);
    if (std.mem.eql(u8, sub, "pages")) return cmdPages(it, argv);
    if (std.mem.eql(u8, sub, "font")) return cmdFont(it, argv);
    if (std.mem.eql(u8, sub, "book")) return cmdBook(it, argv);
    if (std.mem.eql(u8, sub, "markdown")) {
        // One unnumbered chapter: `markdown doc text ?options?`.
        if (argv.len < 4) return it.wrongArgs("ztcl::typeset markdown doc text -fonts dict ?-style dict? ?-run prefix?");
        const chapter = try value.wrapList(it.alloc(), try it.alloc().dupe(Value, &.{ .{ .str = "markdown" }, .{ .int = 0 }, argv[3] }));
        const words = try it.alloc().alloc(Value, argv.len);
        words[0] = argv[0];
        words[1] = argv[1];
        words[2] = argv[2];
        words[3] = try value.wrapList(it.alloc(), try it.alloc().dupe(Value, &.{chapter}));
        @memcpy(words[4..], argv[4..]);
        return cmdBook(it, words);
    }
    return it.fail("unknown subcommand \"{s}\": must be book, break, font, hyphenate, justify, markdown, pages, or svg", .{sub});
}

fn cmdHyphenate(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len != 3 and !(argv.len == 5 and std.mem.eql(u8, try it.str(argv[3]), "-lang"))) return it.wrongArgs("ztcl::typeset hyphenate word ?-lang en-us?");
    if (argv.len == 5) try checkLang(it, argv[4]);
    const h = try hyphenator(it);
    const w = try it.str(argv[2]);
    var marks: [64]bool = undefined;
    if (w.len > 64 or h.hyphenate(w, &marks) == 0) return .{ .str = w };
    var out: std.ArrayList(u8) = .empty;
    for (w, 0..) |c, i| {
        try out.append(it.alloc(), c);
        if (marks[i]) try out.append(it.alloc(), '-');
    }
    return .{ .str = out.items };
}

fn fontLookup(it: *Interp, v: Value) Error!*const Font {
    const name = try it.str(v);
    const s = try state(it);
    if (std.mem.startsWith(u8, name, "font")) {
        if (std.fmt.parseInt(usize, name[4..], 10)) |i| {
            if (i < s.fonts.items.len) return &s.fonts.items[i].font;
        } else |_| {}
    }
    return it.failCode("ZTCL TYPESET HANDLE", "can not find font \"{s}\"", .{name});
}

/// `ztcl::typeset font load bytes`, `font metrics font size`, and
/// `font measure font size string`.
fn cmdFont(it: *Interp, argv: []const Value) Error!Value {
    const usage = "ztcl::typeset font load bytes | metrics font size | measure font size string";
    if (argv.len < 4) return it.wrongArgs(usage);
    const sub = try it.str(argv[2]);
    const s = try state(it);
    const gpa = it.heap.backing;
    if (std.mem.eql(u8, sub, "load")) {
        if (argv.len != 4) return it.wrongArgs("ztcl::typeset font load bytes");
        const data = try gpa.dupe(u8, try bytesArg(it, argv[3]));
        errdefer gpa.free(data);
        const f = Font.init(data) catch |e| return docError(it, e);
        try s.fonts.append(gpa, .{ .data = data, .font = f });
        return .{ .str = try std.fmt.allocPrint(it.alloc(), "font{d}", .{s.fonts.items.len - 1}) };
    }
    const f = try fontLookup(it, argv[3]);
    if (std.mem.eql(u8, sub, "metrics")) {
        if (argv.len != 5) return it.wrongArgs("ztcl::typeset font metrics font size");
        const k = (try num(it, argv[4])) / f.unitsPerEm();
        const sc = struct {
            fn v(x: anytype, kk: f32) Value {
                return .{ .double = @as(f64, @as(f32, @floatFromInt(x)) * kk) };
            }
        };
        return value.wrapList(it.alloc(), try it.alloc().dupe(Value, &.{
            .{ .str = "family" },     .{ .str = try it.alloc().dupe(u8, f.face.family()) },
            .{ .str = "name" },       .{ .str = try it.alloc().dupe(u8, f.psName()) },
            .{ .str = "ascent" },     sc.v(f.face.ascent, k),
            .{ .str = "descent" },    sc.v(f.face.descent, k),
            .{ .str = "linegap" },    sc.v(f.face.line_gap, k),
            .{ .str = "capheight" },  sc.v(f.cap_height, k),
            .{ .str = "xheight" },    sc.v(f.x_height, k),
            .{ .str = "unitsperem" }, .{ .int = f.face.units_per_em },
            .{ .str = "glyphs" },     .{ .int = f.face.glyph_count },
            .{ .str = "fixed" },      .{ .int = @intFromBool(f.fixed_pitch) },
        }));
    }
    if (std.mem.eql(u8, sub, "measure")) {
        if (argv.len != 6) return it.wrongArgs("ztcl::typeset font measure font size string");
        const text = try it.str(argv[5]);
        try charge(it, 1 + text.len / 256);
        const g = f.shape(gpa, text, true) catch return error.OutOfMemory;
        defer gpa.free(g);
        var w: i64 = 0;
        for (g) |x| w += x.advance;
        return .{ .double = @as(f64, @floatFromInt(w)) * (try num(it, argv[4])) / f.unitsPerEm() };
    }
    return it.wrongArgs(usage);
}

const break_opts = [_][]const u8{ "-width", "-font", "-size", "-method", "-hyphenate", "-indent", "-tolerance", "-align", "-lang" };

fn paraOptions(it: *Interp, argv: []const Value, comptime usage: []const u8) Error!para.Options {
    const o = try options(it, argv, &break_opts, usage);
    var po: para.Options = .{ .width = if (o[0]) |v| try num(it, v) else return it.fail("-width is needed", .{}) };
    if (po.width <= 0) return it.fail("-width must be more than 0", .{});
    if (o[1]) |v| po.font = try fontLookup(it, v);
    if (o[2]) |v| po.size = try num(it, v) else if (po.font != null) {
        po.size = 10;
    }
    if (o[3]) |v| {
        const m = try it.str(v);
        po.method = std.meta.stringToEnum(para.Method, m) orelse return it.fail("unknown method \"{s}\": must be total or greedy", .{m});
    }
    if (o[4]) |v| po.hyphenate = (v.asInt() orelse 1) != 0;
    if (o[5]) |v| po.indent = try num(it, v);
    if (o[6]) |v| po.tolerance = try num(it, v);
    if (o[7]) |v| {
        const al = try it.str(v);
        po.@"align" = std.meta.stringToEnum(para.Align, al) orelse return it.fail("unknown alignment \"{s}\": must be justify, left, right, or center", .{al});
    }
    if (o[8]) |v| try checkLang(it, v);
    po.hy = try hyphenator(it);
    po.max_steps = @intCast(@min(it.compute_limit, std.math.maxInt(u32)) * 64);
    return po;
}

fn checkLang(it: *Interp, v: Value) Error!void {
    const l = try it.str(v);
    if (!std.ascii.eqlIgnoreCase(l, "en-us") and !std.ascii.eqlIgnoreCase(l, "en")) return it.failCode("ZTCL TYPESET LANG", "no hyphenation patterns for \"{s}\": the languages are en-us", .{l});
}

fn runBreak(it: *Interp, a: std.mem.Allocator, text: []const u8, po: para.Options) Error!para.Result {
    try charge(it, 1 + text.len / 256);
    const r = para.breakText(a, text, po) catch |e| return docError(it, e);
    try charge(it, r.steps / 64);
    return r;
}

/// `ztcl::typeset break text -width w ?options?`: a list of lines, each
/// a dict of text, ratio, width, hyphen, and words {x word ...}.
fn cmdBreak(it: *Interp, argv: []const Value) Error!Value {
    const usage = "ztcl::typeset break text -width w ?-font font? ?-size points? ?-method total|greedy? ?-hyphenate bool? ?-indent n? ?-tolerance n? ?-align justify|left|right|center? ?-lang en-us?";
    if (argv.len < 5) return it.wrongArgs(usage);
    const po = try paraOptions(it, argv[3..], usage);
    var arena = std.heap.ArenaAllocator.init(it.heap.backing);
    defer arena.deinit();
    const r = try runBreak(it, arena.allocator(), try it.str(argv[2]), po);
    const A = it.alloc();
    var lines: std.ArrayList(Value) = .empty;
    for (r.lines) |l| {
        var text: std.ArrayList(u8) = .empty;
        var words: std.ArrayList(Value) = .empty;
        for (l.words, 0..) |w, i| {
            if (i > 0) try text.append(A, ' ');
            try text.appendSlice(A, w.text);
            try words.append(A, .{ .double = w.x });
            try words.append(A, .{ .str = try A.dupe(u8, w.text) });
        }
        try lines.append(A, try value.wrapList(A, try A.dupe(Value, &.{
            .{ .str = "text" },   .{ .str = text.items },
            .{ .str = "ratio" },  .{ .double = l.ratio },
            .{ .str = "width" },  .{ .double = l.width },
            .{ .str = "hyphen" }, .{ .int = @intFromBool(l.hyphen) },
            .{ .str = "words" },  try value.wrapList(A, words.items),
        })));
    }
    return value.wrapList(A, lines.items);
}

/// `ztcl::typeset justify text -width columns`: the text as lines of
/// characters, for a terminal.
fn cmdJustify(it: *Interp, argv: []const Value) Error!Value {
    const usage = "ztcl::typeset justify text -width columns ?-method total|greedy? ?-hyphenate bool? ?-indent n? ?-align justify|left|right|center?";
    if (argv.len < 5) return it.wrongArgs(usage);
    var po = try paraOptions(it, argv[3..], usage);
    if (po.font != null) return it.fail("justify works on a grid of characters: give no -font", .{});
    po.width = @floor(po.width);
    var arena = std.heap.ArenaAllocator.init(it.heap.backing);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    const A = it.alloc();
    // Each blank line starts a new paragraph.
    var paras = std.mem.splitSequence(u8, try it.str(argv[2]), "\n\n");
    var first = true;
    while (paras.next()) |ptext| {
        if (std.mem.trim(u8, ptext, " \t\r\n").len == 0) continue;
        if (!first) try out.append(A, '\n');
        first = false;
        const r = try runBreak(it, arena.allocator(), ptext, po);
        for (r.lines) |l| {
            var col: usize = 0;
            for (l.words) |w| {
                const x: usize = @intFromFloat(@round(@max(0, w.x)));
                while (col < x) : (col += 1) try out.append(A, ' ');
                try out.appendSlice(A, w.text);
                col += std.unicode.utf8CountCodepoints(w.text) catch w.text.len;
            }
            try out.append(A, '\n');
        }
    }
    return .{ .str = out.items };
}

/// `ztcl::typeset svg text -width w -font font ?options? ?-family css?`:
/// an SVG image of the paragraph. Each line is a `<text>` element, and
/// each word has its own x, so a browser shows the same breaks.
fn cmdSvg(it: *Interp, argv: []const Value) Error!Value {
    const usage = "ztcl::typeset svg text -width w -font font ?-size points? ?-leading points? ?-family css-family? ?break options?";
    if (argv.len < 5) return it.wrongArgs(usage);
    // Take -leading and -family out of the options of break.
    var rest: std.ArrayList(Value) = .empty;
    var leading: ?f32 = null;
    var family: []const u8 = "";
    var i: usize = 3;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) return it.wrongArgs(usage);
        const k = try it.str(argv[i]);
        if (std.mem.eql(u8, k, "-leading")) {
            leading = try num(it, argv[i + 1]);
        } else if (std.mem.eql(u8, k, "-family")) {
            family = try it.str(argv[i + 1]);
        } else {
            try rest.append(it.alloc(), argv[i]);
            try rest.append(it.alloc(), argv[i + 1]);
        }
    }
    const po = try paraOptions(it, rest.items, usage);
    const f = po.font orelse return it.fail("svg needs -font", .{});
    if (family.len == 0) family = f.face.family();
    const lead = leading orelse po.size * 1.35;
    var arena = std.heap.ArenaAllocator.init(it.heap.backing);
    defer arena.deinit();
    const r = try runBreak(it, arena.allocator(), try it.str(argv[2]), po);
    const A = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    const h = lead * @as(f32, @floatFromInt(r.lines.len)) + po.size * 0.4;
    try out.print(A, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d:.1}\" height=\"{d:.1}\" viewBox=\"0 0 {d:.1} {d:.1}\">\n", .{ po.width, h, po.width, h });
    try out.print(A, "<g font-family=\"", .{});
    try xmlText(A, &out, family);
    try out.print(A, "\" font-size=\"{d:.2}\" xml:space=\"preserve\">\n", .{po.size});
    for (r.lines, 0..) |l, li| {
        const y = po.size + lead * @as(f32, @floatFromInt(li));
        try out.print(A, "<text y=\"{d:.2}\">", .{y});
        for (l.words) |w| {
            try out.print(A, "<tspan x=\"{d:.2}\">", .{w.x});
            try xmlText(A, &out, w.text);
            try out.appendSlice(A, "</tspan>");
        }
        try out.appendSlice(A, "</text>\n");
    }
    try out.appendSlice(A, "</g>\n</svg>\n");
    return .{ .str = out.items };
}

fn xmlText(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '&' => try out.appendSlice(a, "&amp;"),
        '"' => try out.appendSlice(a, "&quot;"),
        else => try out.append(a, c),
    };
}

/// `ztcl::typeset pages counts -lines n ?-columns c? ?-gap g?`
fn cmdPages(it: *Interp, argv: []const Value) Error!Value {
    const usage = "ztcl::typeset pages counts -lines n ?-columns c? ?-gap lines?";
    if (argv.len < 5) return it.wrongArgs(usage);
    const o = try options(it, argv[3..], &.{ "-lines", "-columns", "-gap" }, usage);
    const per = try it.int(o[0] orelse return it.wrongArgs(usage));
    const cols = if (o[1]) |v| try it.int(v) else 1;
    const gap = if (o[2]) |v| try it.int(v) else 0;
    if (per < 1 or per > 10000 or cols < 1 or cols > 100 or gap < 0 or gap > 100) return it.fail("-lines is 1 to 10000, -columns 1 to 100, -gap 0 to 100", .{});
    const items = try it.list(argv[2]);
    var arena = std.heap.ArenaAllocator.init(it.heap.backing);
    defer arena.deinit();
    const a = arena.allocator();
    const counts = try a.alloc(u32, items.len);
    var total: u64 = 0;
    for (items, 0..) |v, i| {
        const n = try it.int(v);
        if (n < 0 or n > 1_000_000) return it.fail("a line count is 0 to 1,000,000", .{});
        counts[i] = @intCast(n);
        total += counts[i];
    }
    try charge(it, 1 + total / 64);
    const pg = para.pages(a, counts, @intCast(per), @intCast(cols), @intCast(gap)) catch return error.OutOfMemory;
    const A = it.alloc();
    var pv: std.ArrayList(Value) = .empty;
    for (pg) |page| {
        var cv: std.ArrayList(Value) = .empty;
        for (page) |col| {
            var xs: std.ArrayList(Value) = .empty;
            for (col) |p| try xs.append(A, try value.wrapList(A, try A.dupe(Value, &.{ .{ .int = p.para }, .{ .int = p.from }, .{ .int = p.to } })));
            try cv.append(A, try value.wrapList(A, xs.items));
        }
        try pv.append(A, try value.wrapList(A, cv.items));
    }
    return value.wrapList(A, pv.items);
}

const RunCtx = struct { it: *Interp, prefix: []const Value };

fn runBlock(ctx: *anyopaque, a: std.mem.Allocator, lang: []const u8, code: []const u8) anyerror![]const u8 {
    const rc: *RunCtx = @ptrCast(@alignCast(ctx));
    const it = rc.it;
    const words = try it.alloc().alloc(Value, rc.prefix.len + 2);
    @memcpy(words[0..rc.prefix.len], rc.prefix);
    words[rc.prefix.len] = .{ .str = try it.alloc().dupe(u8, lang) };
    words[rc.prefix.len + 1] = .{ .str = try it.alloc().dupe(u8, code) };
    const r = it.evalWords(words) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.RunFailed,
    };
    return a.dupe(u8, try it.str(r));
}

const style_fields = [_][]const u8{ "page_w", "page_h", "inner", "outer", "top", "leading", "size", "indent", "code_size", "code_leading", "code_pad", "mono_scale", "h1_size", "h2_size", "h3_size", "head_size", "tolerance", "hyphen_penalty" };

/// `ztcl::typeset book doc -fonts dict ?-style dict? ?-run prefix? chapters`
fn cmdBook(it: *Interp, argv: []const Value) Error!Value {
    const usage = "ztcl::typeset book doc chapters -fonts dict ?-style dict? ?-run prefix?";
    if (argv.len < 6) return it.wrongArgs(usage);
    const o = try options(it, argv[4..], &.{ "-fonts", "-style", "-run" }, usage);
    const d = try lookup(it, argv[2]);
    const fd = o[0] orelse return it.wrongArgs(usage);
    const fitems = try it.list(fd);
    if (fitems.len % 2 != 0) return it.fail("the -fonts value is not a dict", .{});
    var fonts: layout.Fonts = undefined;
    var have: u8 = 0;
    const font_keys = [_][]const u8{ "serif", "italic", "bold", "bolditalic", "sans", "sansbold", "mono", "monobold" };
    var i: usize = 0;
    while (i < fitems.len) : (i += 2) {
        const k = try it.str(fitems[i]);
        const id = try index(it, fitems[i + 1], d.fonts.items.len, "font");
        inline for (font_keys, 0..) |name, j| {
            if (std.mem.eql(u8, k, name)) {
                @field(fonts, @typeInfo(layout.Fonts).@"struct".field_names[j]) = id;
                have |= @as(u8, 1) << j;
            }
        }
    }
    // Only serif is needed. Each other face falls back to a near face.
    if (have & 1 == 0) return it.failCode("ZTCL TYPESET FONTS", "-fonts needs at least the key serif", .{});
    if (have & 2 == 0) fonts.italic = fonts.serif;
    if (have & 4 == 0) fonts.bold = fonts.serif;
    if (have & 8 == 0) fonts.bold_italic = if (have & 4 != 0) fonts.bold else fonts.italic;
    if (have & 16 == 0) fonts.sans = fonts.serif;
    if (have & 32 == 0) fonts.sans_bold = if (have & 16 != 0) fonts.sans else fonts.bold;
    if (have & 64 == 0) fonts.mono = fonts.serif;
    if (have & 128 == 0) fonts.mono_bold = fonts.mono;
    var st: layout.Style = .{};
    if (o[1]) |sv| {
        const sitems = try it.list(sv);
        if (sitems.len % 2 != 0) return it.fail("the -style value is not a dict", .{});
        var k: usize = 0;
        sk: while (k < sitems.len) : (k += 2) {
            const key = try it.str(sitems[k]);
            inline for (style_fields) |f| {
                if (std.mem.eql(u8, key, f)) {
                    @field(st, f) = try num(it, sitems[k + 1]);
                    continue :sk;
                }
            }
            if (std.mem.eql(u8, key, "lines")) {
                const n = try it.int(sitems[k + 1]);
                if (n < 4 or n > 200) return it.fail("lines is from 4 to 200", .{});
                st.lines = @intCast(n);
            } else if (std.mem.eql(u8, key, "first_folio")) {
                const n = try it.int(sitems[k + 1]);
                if (n < 1 or n > 1_000_000) return it.fail("first_folio is from 1 to 1,000,000", .{});
                st.first_folio = @intCast(n);
            } else if (std.mem.eql(u8, key, "chapter_word")) {
                st.chapter_word = try it.str(sitems[k + 1]);
            } else return it.fail("unknown style key \"{s}\"", .{key});
        }
        if (st.leading <= 0 or st.size <= 0 or st.code_leading <= 0 or st.page_w - st.inner - st.outer < 36) return it.fail("the style gives no room for text", .{});
    }
    // The chapters: a list of {name number text}.
    const citems = try it.list(argv[3]);
    const gpa = it.heap.backing;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var chapters: std.ArrayList(layout.Chapter) = .empty;
    for (citems) |cv| {
        const c = try it.list(cv);
        if (c.len != 3) return it.fail("a chapter is a list of {{name number text}}", .{});
        const n = try it.int(c[1]);
        if (n < 0 or n > 10000) return it.fail("a chapter number is from 0 to 10000", .{});
        const text = try it.str(c[2]);
        try charge(it, text.len / 1024);
        try chapters.append(a, .{ .name = try a.dupe(u8, try it.str(c[0])), .source = try a.dupe(u8, text), .number = @intCast(n) });
    }
    var rc: RunCtx = .{ .it = it, .prefix = if (o[2]) |r| try it.list(r) else &.{} };
    const runner: ?layout.Runner = if (o[2] != null) .{ .ctx = &rc, .run = runBlock } else null;
    var msgs: std.ArrayList(u8) = .empty;
    defer msgs.deinit(gpa);
    const limit: usize = @intCast(@min(it.compute_limit, std.math.maxInt(u32)) * 64);
    const stats = layout.typeset(gpa, a, d, fonts, st, try hyphenator(it), chapters.items, runner, &msgs, limit) catch |e| return docError(it, e);
    try charge(it, stats.lines);
    var out: std.ArrayList(Value) = .empty;
    inline for (@typeInfo(layout.Stats).@"struct".field_names) |name| {
        try out.append(it.alloc(), .{ .str = name });
        try out.append(it.alloc(), .{ .int = @field(stats, name) });
    }
    var ml: std.ArrayList(Value) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, msgs.items, "\n"), '\n');
    if (msgs.items.len > 0) while (lines.next()) |l| try ml.append(it.alloc(), .{ .str = try it.alloc().dupe(u8, l) });
    try out.append(it.alloc(), .{ .str = "messages" });
    try out.append(it.alloc(), try value.wrapList(it.alloc(), ml.items));
    return value.wrapList(it.alloc(), out.items);
}

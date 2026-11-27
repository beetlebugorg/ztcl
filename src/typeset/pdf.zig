//! A PDF writer, from ISO 32000-2 (PDF 2.0). The output is a PDF 1.7
//! file, which each PDF 2.0 reader opens too.
//!
//! A document has pages, fonts, images, links, named destinations, an
//! outline, and the document information. Each page has a content
//! stream of PDF operators that the calls append. At `write`, the
//! writer numbers the objects, compresses each stream with Flate, and
//! adds the cross-reference table and the trailer.
//!
//! A font is a TrueType font as a Type 0 font with the encoding
//! Identity-H: the codes of the text are glyph numbers ("Composite
//! fonts"). The writer embeds a subset of each font (`subset.zig`), the
//! widths of the glyphs in use, and a ToUnicode map, so a reader
//! can copy and search the text. The subset tag is six letters from a
//! hash of the glyphs in use.
//!
//! An image is a PNG file (8 bits for each sample, no interlace) or a
//! JPEG file. The samples of a PNG go in as the Flate data of the file
//! with the PNG predictors, and an alpha channel goes in as a soft mask.
//! A JPEG goes in with no change, with the filter DCTDecode.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Font = @import("font.zig").Font;
const Glyph = @import("font.zig").Glyph;
const subset = @import("subset.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, BadFont, Unsupported, BadImage, BadDest, BadPage };

pub const Rgb = [3]f32;

const FontRec = struct {
    data: []u8,
    font: Font,
    used: []bool,
    /// The text of each glyph in use, for the ToUnicode map.
    text: std.AutoHashMapUnmanaged(u16, []u8) = .empty,
};

const Image = struct {
    width: u32,
    height: u32,
    /// The color space name: DeviceGray, DeviceRGB, or DeviceCMYK.
    space: []const u8,
    /// For a palette image: the palette bytes (RGB).
    palette: []u8 = &.{},
    bits: u8 = 8,
    filter: enum { flate, dct },
    /// The Flate data with the PNG predictor of `colors` samples, the
    /// already-compressed data, or the JPEG data.
    data: []u8,
    predictor: bool,
    colors: u8,
    alpha: ?[]u8 = null,
};

const Link = struct {
    rect: [4]f32,
    uri: ?[]u8,
    dest: ?[]u8,
};

const Page = struct {
    width: f32,
    height: f32,
    content: std.ArrayList(u8) = .empty,
    links: std.ArrayList(Link) = .empty,
    fonts_used: std.ArrayList(u32) = .empty,
    images_used: std.ArrayList(u32) = .empty,
    label: ?[]u8 = null,
};

const Dest = struct { page: u32, x: f32, y: f32 };

const OutlineItem = struct { title: []u8, level: u8, dest: Dest };

pub const Doc = struct {
    gpa: Allocator,
    pages: std.ArrayList(Page) = .empty,
    fonts: std.ArrayList(*FontRec) = .empty,
    images: std.ArrayList(Image) = .empty,
    dests: std.StringHashMapUnmanaged(Dest) = .empty,
    outline: std.ArrayList(OutlineItem) = .empty,
    info: [4]?[]u8 = .{ null, null, null, null },
    /// Compress the streams. Off gives readable files for the tests.
    compress: bool = true,

    pub const info_keys = [_][]const u8{ "Title", "Author", "Subject", "Keywords" };

    pub fn init(gpa: Allocator) Doc {
        return .{ .gpa = gpa };
    }

    pub fn deinit(d: *Doc) void {
        const gpa = d.gpa;
        for (d.pages.items) |*p| {
            p.content.deinit(gpa);
            for (p.links.items) |l| {
                if (l.uri) |u| gpa.free(u);
                if (l.dest) |x| gpa.free(x);
            }
            p.links.deinit(gpa);
            p.fonts_used.deinit(gpa);
            p.images_used.deinit(gpa);
            if (p.label) |l| gpa.free(l);
        }
        d.pages.deinit(gpa);
        for (d.fonts.items) |f| {
            gpa.free(f.data);
            gpa.free(f.used);
            var it = f.text.valueIterator();
            while (it.next()) |v| gpa.free(v.*);
            f.text.deinit(gpa);
            gpa.destroy(f);
        }
        d.fonts.deinit(gpa);
        for (d.images.items) |im| {
            gpa.free(im.data);
            gpa.free(im.palette);
            if (im.alpha) |a| gpa.free(a);
        }
        d.images.deinit(gpa);
        var dit = d.dests.keyIterator();
        while (dit.next()) |k| gpa.free(k.*);
        d.dests.deinit(gpa);
        for (d.outline.items) |o| gpa.free(o.title);
        d.outline.deinit(gpa);
        for (d.info) |v| if (v) |x| gpa.free(x);
    }

    /// Adds a font from the bytes of a TrueType file. The doc keeps a copy.
    pub fn addFont(d: *Doc, bytes: []const u8) Error!u32 {
        const gpa = d.gpa;
        const rec = try gpa.create(FontRec);
        errdefer gpa.destroy(rec);
        const data = try gpa.dupe(u8, bytes);
        errdefer gpa.free(data);
        const ft = try Font.init(data);
        const used = try gpa.alloc(bool, ft.face.glyph_count);
        @memset(used, false);
        rec.* = .{ .data = data, .font = ft, .used = used };
        try d.fonts.append(gpa, rec);
        return @intCast(d.fonts.items.len - 1);
    }

    pub fn font(d: *Doc, id: u32) *const Font {
        return &d.fonts.items[id].font;
    }

    pub fn addPage(d: *Doc, width: f32, height: f32) Error!u32 {
        try d.pages.append(d.gpa, .{ .width = width, .height = height });
        return @intCast(d.pages.items.len - 1);
    }

    fn page(d: *Doc, p: u32) Error!*Page {
        if (p >= d.pages.items.len) return error.BadPage;
        return &d.pages.items[p];
    }

    fn out(d: *Doc, p: *Page, comptime fmt: []const u8, args: anytype) Error!void {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return error.OutOfMemory;
        try p.content.appendSlice(d.gpa, s);
    }

    fn useFont(d: *Doc, p: *Page, f: u32) Error!void {
        if (std.mem.indexOfScalar(u32, p.fonts_used.items, f) == null) try p.fonts_used.append(d.gpa, f);
    }

    /// Records the text of the glyphs of a shaped run, for the subset and
    /// the ToUnicode map.
    fn markGlyphs(d: *Doc, f: u32, glyphs: []const Glyph, src: []const u8) Error!void {
        const rec = d.fonts.items[f];
        for (glyphs) |g| {
            if (g.id < rec.used.len) rec.used[g.id] = true;
            const gop = try rec.text.getOrPut(d.gpa, g.id);
            if (!gop.found_existing) {
                const t = if (g.end <= src.len and g.start <= g.end) src[g.start..g.end] else "";
                gop.value_ptr.* = d.gpa.dupe(u8, t) catch |e| {
                    _ = rec.text.remove(g.id);
                    return e;
                };
            }
        }
    }

    /// Shows a shaped run of glyphs at (x, y), the left end of the
    /// baseline, in points from the lower-left corner. `text` is the input
    /// of the shaper. The extra space after each space glyph is `word`.
    pub fn glyphRun(d: *Doc, pg: u32, f: u32, size: f32, x: f32, y: f32, glyphs: []const Glyph, src: []const u8, color: Rgb) Error!void {
        if (glyphs.len == 0) return;
        const p = try d.page(pg);
        try d.useFont(p, f);
        try d.markGlyphs(f, glyphs, src);
        const ft = &d.fonts.items[f].font;
        const upem = ft.unitsPerEm();
        try d.out(p, "BT\n{d:.3} {d:.3} {d:.3} rg\n/F{d} {d:.2} Tf\n{d:.3} {d:.3} Td\n[<", .{ color[0], color[1], color[2], f, size, x, y });
        for (glyphs, 0..) |g, i| {
            try d.out(p, "{x:0>4}", .{g.id});
            const natural: i32 = ft.face.advance(g.id);
            if (g.advance != natural and i + 1 < glyphs.len) {
                // TJ moves left by n/1000 of the size for a positive n.
                const adj = -@as(f32, @floatFromInt(g.advance - natural)) * 1000.0 / upem;
                try d.out(p, "> {d:.1} <", .{adj});
            }
        }
        try p.content.appendSlice(d.gpa, ">] TJ\nET\n");
    }

    /// Shapes and shows `text` with the kerning and ligatures of the font.
    /// Returns the width in points.
    pub fn text(d: *Doc, pg: u32, f: u32, size: f32, x: f32, y: f32, s: []const u8, color: Rgb, ligatures: bool) Error!f32 {
        const glyphs = try d.fonts.items[f].font.shape(d.gpa, s, ligatures);
        defer d.gpa.free(glyphs);
        try d.glyphRun(pg, f, size, x, y, glyphs, s, color);
        var w: i64 = 0;
        for (glyphs) |g| w += g.advance;
        return @as(f32, @floatFromInt(w)) * size / d.fonts.items[f].font.unitsPerEm();
    }

    pub fn rect(d: *Doc, pg: u32, x: f32, y: f32, w: f32, h: f32, fill: Rgb) Error!void {
        const p = try d.page(pg);
        try d.out(p, "{d:.3} {d:.3} {d:.3} rg\n{d:.3} {d:.3} {d:.3} {d:.3} re f\n", .{ fill[0], fill[1], fill[2], x, y, w, h });
    }

    pub fn line(d: *Doc, pg: u32, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, color: Rgb) Error!void {
        const p = try d.page(pg);
        try d.out(p, "{d:.3} {d:.3} {d:.3} RG\n{d:.3} w\n{d:.3} {d:.3} m {d:.3} {d:.3} l S\n", .{ color[0], color[1], color[2], width, x0, y0, x1, y1 });
    }

    pub fn link(d: *Doc, pg: u32, r: [4]f32, uri: ?[]const u8, dest: ?[]const u8) Error!void {
        const p = try d.page(pg);
        const u = if (uri) |x| try d.gpa.dupe(u8, x) else null;
        errdefer if (u) |x| d.gpa.free(x);
        const de = if (dest) |x| try d.gpa.dupe(u8, x) else null;
        errdefer if (de) |x| d.gpa.free(x);
        try p.links.append(d.gpa, .{ .rect = r, .uri = u, .dest = de });
    }

    pub fn addDest(d: *Doc, name: []const u8, pg: u32, x: f32, y: f32) Error!void {
        _ = try d.page(pg);
        const gop = try d.dests.getOrPut(d.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = d.gpa.dupe(u8, name) catch |e| {
                _ = d.dests.remove(name);
                return e;
            };
        }
        gop.value_ptr.* = .{ .page = pg, .x = x, .y = y };
    }

    pub fn addOutline(d: *Doc, title: []const u8, level: u8, pg: u32, y: f32) Error!void {
        _ = try d.page(pg);
        const t = try d.gpa.dupe(u8, title);
        errdefer d.gpa.free(t);
        try d.outline.append(d.gpa, .{ .title = t, .level = @max(level, 1), .dest = .{ .page = pg, .x = 0, .y = y } });
    }

    pub fn setInfo(d: *Doc, key: usize, v: []const u8) Error!void {
        if (d.info[key]) |old| d.gpa.free(old);
        d.info[key] = try d.gpa.dupe(u8, v);
    }

    pub fn setLabel(d: *Doc, pg: u32, label: []const u8) Error!void {
        const p = try d.page(pg);
        if (p.label) |l| d.gpa.free(l);
        p.label = try d.gpa.dupe(u8, label);
    }

    pub fn image(d: *Doc, pg: u32, img: u32, x: f32, y: f32, w: f32, h: f32) Error!void {
        const p = try d.page(pg);
        if (img >= d.images.items.len) return error.BadImage;
        if (std.mem.indexOfScalar(u32, p.images_used.items, img) == null) try p.images_used.append(d.gpa, img);
        try d.out(p, "q {d:.3} 0 0 {d:.3} {d:.3} {d:.3} cm /Im{d} Do Q\n", .{ w, h, x, y, img });
    }

    pub fn imageSize(d: *Doc, img: u32) [2]u32 {
        const im = d.images.items[img];
        return .{ im.width, im.height };
    }

    /// Adds a PNG or JPEG image from its bytes.
    pub fn addImage(d: *Doc, bytes: []const u8) Error!u32 {
        const im = if (bytes.len > 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n"))
            try readPng(d.gpa, bytes)
        else if (bytes.len > 3 and bytes[0] == 0xff and bytes[1] == 0xd8)
            try readJpeg(d.gpa, bytes)
        else
            return error.BadImage;
        try d.images.append(d.gpa, im);
        return @intCast(d.images.items.len - 1);
    }

    // ---- the file ----

    /// The bytes of the PDF file. The caller frees them.
    pub fn write(d: *Doc) Error![]u8 {
        var w: Writer = .{ .gpa = d.gpa, .compress = d.compress };
        defer w.offsets.deinit(d.gpa);
        errdefer w.buf.deinit(d.gpa);
        try w.raw("%PDF-1.7\n%\xe2\xe3\xcf\xd3\n");

        // Fixed numbers: 1 catalog, 2 page tree, 3 info.
        var next: u32 = 4;
        const font_base = next;
        next += @intCast(d.fonts.items.len * 5);
        const image_base = next;
        next += @intCast(d.images.items.len * 2);
        const page_base = next;
        next += @intCast(d.pages.items.len * 2);
        const outline_root = next;
        next += 1;
        const outline_base = next;
        next += @intCast(d.outline.items.len);
        var annot_next = next;

        // Catalog.
        try w.begin(1);
        try w.raw("<< /Type /Catalog /Pages 2 0 R");
        if (d.outline.items.len > 0) try w.print(" /Outlines {d} 0 R /PageMode /UseOutlines", .{outline_root});
        try d.writeLabels(&w);
        try w.raw(" >>\n");
        try w.end();

        try w.begin(2);
        try w.print("<< /Type /Pages /Count {d} /Kids [", .{d.pages.items.len});
        for (0..d.pages.items.len) |i| try w.print(" {d} 0 R", .{page_base + i * 2});
        try w.raw(" ] >>\n");
        try w.end();

        try w.begin(3);
        try w.raw("<< /Producer (ztcl::pdf)");
        for (d.info, 0..) |v, k| if (v) |s| {
            try w.print(" /{s} ", .{info_keys[k]});
            try w.textString(s);
        };
        try w.raw(" >>\n");
        try w.end();

        // A font with no glyph on a page stays out of the file.
        for (d.fonts.items, 0..) |f, i| if (f.text.count() > 0) try d.writeFont(&w, f, font_base + @as(u32, @intCast(i)) * 5);
        for (d.images.items, 0..) |im, i| try writeImage(&w, im, image_base + @as(u32, @intCast(i)) * 2);

        for (d.pages.items, 0..) |p, i| {
            const num = page_base + @as(u32, @intCast(i)) * 2;
            try w.begin(num);
            try w.print("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {d:.3} {d:.3}] /Contents {d} 0 R /Resources << /Font <<", .{ p.width, p.height, num + 1 });
            for (p.fonts_used.items) |f| try w.print(" /F{d} {d} 0 R", .{ f, font_base + f * 5 });
            try w.raw(" >>");
            if (p.images_used.items.len > 0) {
                try w.raw(" /XObject <<");
                for (p.images_used.items) |m| try w.print(" /Im{d} {d} 0 R", .{ m, image_base + m * 2 });
                try w.raw(" >>");
            }
            try w.raw(" >>");
            if (p.links.items.len > 0) {
                try w.raw(" /Annots [");
                for (0..p.links.items.len) |k| try w.print(" {d} 0 R", .{annot_next + k});
                try w.raw(" ]");
            }
            try w.raw(" >>\n");
            try w.end();
            try w.stream(num + 1, "", p.content.items, true);
            for (p.links.items) |l| {
                try w.begin(annot_next);
                annot_next += 1;
                try w.print("<< /Type /Annot /Subtype /Link /Rect [{d:.2} {d:.2} {d:.2} {d:.2}] /Border [0 0 0]", .{ l.rect[0], l.rect[1], l.rect[2], l.rect[3] });
                if (l.uri) |u| {
                    try w.raw(" /A << /S /URI /URI ");
                    try w.literal(u);
                    try w.raw(" >>");
                } else if (l.dest) |name| {
                    const de = d.dests.get(name) orelse return error.BadDest;
                    try w.print(" /Dest [{d} 0 R /XYZ {d:.2} {d:.2} null]", .{ page_base + de.page * 2, de.x, de.y });
                }
                try w.raw(" >>\n");
                try w.end();
            }
        }

        if (d.outline.items.len > 0) try d.writeOutline(&w, outline_root, outline_base, page_base);

        const xref = w.buf.items.len;
        const count = annot_next;
        try w.print("xref\n0 {d}\n0000000000 65535 f \n", .{count});
        for (1..count) |n| {
            const off = if (n < w.offsets.items.len) w.offsets.items[n] else 0;
            // A number with no object (an outline root with no outline) is free.
            if (off == 0) try w.raw("0000000000 65535 f \n") else try w.print("{d:0>10} 00000 n \n", .{off});
        }
        var id: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(w.buf.items, &id, .{});
        try w.print("trailer\n<< /Size {d} /Root 1 0 R /Info 3 0 R /ID [<{x}> <{x}>] >>\nstartxref\n{d}\n%%EOF\n", .{ count, &id, &id, xref });
        return w.buf.toOwnedSlice(d.gpa);
    }

    fn writeLabels(d: *Doc, w: *Writer) Error!void {
        var any = false;
        for (d.pages.items) |p| if (p.label != null) {
            any = true;
        };
        if (!any) return;
        try w.raw(" /PageLabels << /Nums [");
        var prev: ?[]const u8 = null;
        for (d.pages.items, 0..) |p, i| {
            const l = p.label orelse "";
            // A label "roman:N" or "arabic:N" starts a range of folios.
            if (prev != null and std.mem.eql(u8, prev.?, l)) continue;
            prev = l;
            var it = std.mem.splitScalar(u8, l, ':');
            const style = it.next() orelse "";
            const start = std.fmt.parseInt(u32, it.next() orelse "1", 10) catch 1;
            const s: []const u8 = if (std.mem.eql(u8, style, "roman")) "/r" else if (std.mem.eql(u8, style, "arabic")) "/D" else "";
            if (s.len == 0) continue;
            try w.print(" {d} << /S {s} /St {d} >>", .{ i, s, start });
        }
        try w.raw(" ] >>");
    }

    fn writeOutline(d: *Doc, w: *Writer, root: u32, base: u32, page_base: u32) Error!void {
        const items = d.outline.items;
        const n = items.len;
        // The parent, the previous and next sibling, and the first and
        // last child of each item, from the levels.
        const gpa = d.gpa;
        const parent = try gpa.alloc(?usize, n);
        defer gpa.free(parent);
        const prev = try gpa.alloc(?usize, n);
        defer gpa.free(prev);
        const nxt = try gpa.alloc(?usize, n);
        defer gpa.free(nxt);
        const first = try gpa.alloc(?usize, n);
        defer gpa.free(first);
        const last = try gpa.alloc(?usize, n);
        defer gpa.free(last);
        const count = try gpa.alloc(usize, n);
        defer gpa.free(count);
        @memset(parent, null);
        @memset(prev, null);
        @memset(nxt, null);
        @memset(first, null);
        @memset(last, null);
        @memset(count, 0);
        var stack: [16]usize = undefined;
        var depth: usize = 0;
        var top_first: ?usize = null;
        var top_last: ?usize = null;
        for (items, 0..) |it, i| {
            const level = @min(@as(usize, it.level), stack.len);
            while (depth >= level) depth -= 1;
            if (depth > 0) {
                const p = stack[depth - 1];
                parent[i] = p;
                if (last[p]) |l| {
                    nxt[l] = i;
                    prev[i] = l;
                } else first[p] = i;
                last[p] = i;
            } else {
                if (top_last) |l| {
                    nxt[l] = i;
                    prev[i] = l;
                } else top_first = i;
                top_last = i;
            }
            stack[depth] = i;
            depth += 1;
        }
        var i = n;
        while (i > 0) {
            i -= 1;
            if (parent[i]) |p| count[p] += 1 + count[i];
        }
        var top_count: usize = 0;
        for (parent) |p| if (p == null) {
            top_count += 1;
        };
        try w.begin(root);
        try w.print("<< /Type /Outlines /First {d} 0 R /Last {d} 0 R /Count {d} >>\n", .{ base + top_first.?, base + top_last.?, top_count });
        try w.end();
        for (items, 0..) |it, k| {
            try w.begin(base + @as(u32, @intCast(k)));
            try w.raw("<< /Title ");
            try w.textString(it.title);
            try w.print(" /Parent {d} 0 R", .{if (parent[k]) |p| base + p else root});
            if (prev[k]) |p| try w.print(" /Prev {d} 0 R", .{base + p});
            if (nxt[k]) |p| try w.print(" /Next {d} 0 R", .{base + p});
            if (first[k]) |p| try w.print(" /First {d} 0 R /Last {d} 0 R /Count -{d}", .{ base + p, base + last[k].?, count[k] });
            try w.print(" /Dest [{d} 0 R /XYZ 0 {d:.2} null] >>\n", .{ page_base + it.dest.page * 2, it.dest.y });
            try w.end();
        }
    }

    fn writeFont(d: *Doc, w: *Writer, f: *FontRec, num: u32) Error!void {
        const gpa = d.gpa;
        const ft = &f.font;
        const upem = ft.unitsPerEm();
        const scale = 1000.0 / upem;
        // The subset tag: six capital letters from a hash of the glyphs.
        var h = std.hash.Wyhash.init(num);
        for (f.used, 0..) |u, g| if (u) h.update(std.mem.asBytes(&@as(u32, @intCast(g))));
        var hv = h.final();
        var tag: [6]u8 = undefined;
        for (&tag) |*c| {
            c.* = 'A' + @as(u8, @intCast(hv % 26));
            hv /= 26;
        }
        // Type 0 font.
        try w.begin(num);
        try w.print("<< /Type /Font /Subtype /Type0 /BaseFont /{s}+{s} /Encoding /Identity-H /DescendantFonts [{d} 0 R] /ToUnicode {d} 0 R >>\n", .{ &tag, ft.psName(), num + 1, num + 3 });
        try w.end();
        // CID font with the widths.
        try w.begin(num + 1);
        try w.print("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /{s}+{s} /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor {d} 0 R /CIDToGIDMap /Identity /DW 0 /W [", .{ &tag, ft.psName(), num + 2 });
        var g: usize = 0;
        while (g < f.used.len) {
            if (!f.used[g]) {
                g += 1;
                continue;
            }
            try w.print(" {d} [", .{g});
            while (g < f.used.len and f.used[g]) : (g += 1) {
                try w.print(" {d}", .{@as(i64, @intFromFloat(@round(@as(f32, @floatFromInt(ft.face.advance(@intCast(g)))) * scale)))});
            }
            try w.raw(" ]");
        }
        try w.raw(" ] >>\n");
        try w.end();
        // Descriptor.
        var flags: u32 = 32; // nonsymbolic
        if (ft.fixed_pitch) flags |= 1;
        if (ft.serif) flags |= 2;
        if (ft.italic_angle != 0) flags |= 64;
        const s = struct {
            fn v(x: i32, sc: f32) i64 {
                return @intFromFloat(@round(@as(f32, @floatFromInt(x)) * sc));
            }
        };
        try w.begin(num + 2);
        try w.print("<< /Type /FontDescriptor /FontName /{s}+{s} /Flags {d} /FontBBox [{d} {d} {d} {d}] /ItalicAngle {d:.2} /Ascent {d} /Descent {d} /CapHeight {d} /XHeight {d} /StemV 80 /FontFile2 {d} 0 R >>\n", .{
            &tag,                        ft.psName(),               flags,
            s.v(ft.bbox[0], scale),      s.v(ft.bbox[1], scale),    s.v(ft.bbox[2], scale),
            s.v(ft.bbox[3], scale),      ft.italic_angle,           s.v(ft.face.ascent, scale),
            s.v(ft.face.descent, scale), s.v(ft.cap_height, scale), s.v(ft.x_height, scale),
            num + 4,
        });
        try w.end();
        // ToUnicode.
        var cmap: std.ArrayList(u8) = .empty;
        defer cmap.deinit(gpa);
        try cmap.appendSlice(gpa, "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
        var keys: std.ArrayList(u16) = .empty;
        defer keys.deinit(gpa);
        var kit = f.text.keyIterator();
        while (kit.next()) |k| try keys.append(gpa, k.*);
        std.mem.sort(u16, keys.items, {}, std.sort.asc(u16));
        var at: usize = 0;
        while (at < keys.items.len) {
            const chunk = @min(100, keys.items.len - at);
            var line_buf: [64]u8 = undefined;
            try cmap.appendSlice(gpa, std.fmt.bufPrint(&line_buf, "{d} beginbfchar\n", .{chunk}) catch unreachable);
            for (keys.items[at .. at + chunk]) |k| {
                try cmap.appendSlice(gpa, std.fmt.bufPrint(&line_buf, "<{x:0>4}> <", .{k}) catch unreachable);
                const t = f.text.get(k).?;
                var view = std.unicode.Utf8View.init(t) catch std.unicode.Utf8View.initUnchecked("");
                var cps = view.iterator();
                var any = false;
                while (cps.nextCodepoint()) |cp| {
                    any = true;
                    var u16buf: [2]u16 = undefined;
                    const n: usize = if (cp >= 0x10000) 2 else 1;
                    if (n == 2) {
                        const v = cp - 0x10000;
                        u16buf[0] = @intCast(0xd800 + (v >> 10));
                        u16buf[1] = @intCast(0xdc00 + (v & 0x3ff));
                    } else u16buf[0] = @intCast(cp);
                    for (u16buf[0..n]) |u| try cmap.appendSlice(gpa, std.fmt.bufPrint(&line_buf, "{x:0>4}", .{u}) catch unreachable);
                }
                if (!any) try cmap.appendSlice(gpa, "fffd");
                try cmap.appendSlice(gpa, ">\n");
            }
            try cmap.appendSlice(gpa, "endbfchar\n");
            at += chunk;
        }
        try cmap.appendSlice(gpa, "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
        try w.stream(num + 3, "", cmap.items, true);
        // The font program.
        const prog = subset.subset(gpa, &ft.face, f.used) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer gpa.free(prog);
        var len_buf: [32]u8 = undefined;
        try w.stream(num + 4, std.fmt.bufPrint(&len_buf, " /Length1 {d}", .{prog.len}) catch unreachable, prog, true);
    }
};

fn writeImage(w: *Writer, im: Image, num: u32) Error!void {
    var dict: std.ArrayList(u8) = .empty;
    defer dict.deinit(w.gpa);
    var b: [256]u8 = undefined;
    try dict.appendSlice(w.gpa, std.fmt.bufPrint(&b, " /Type /XObject /Subtype /Image /Width {d} /Height {d} /BitsPerComponent {d}", .{ im.width, im.height, im.bits }) catch unreachable);
    if (im.palette.len > 0) {
        try dict.appendSlice(w.gpa, std.fmt.bufPrint(&b, " /ColorSpace [/Indexed /DeviceRGB {d} <", .{im.palette.len / 3 - 1}) catch unreachable);
        for (im.palette) |c| try dict.appendSlice(w.gpa, std.fmt.bufPrint(&b, "{x:0>2}", .{c}) catch unreachable);
        try dict.appendSlice(w.gpa, ">]");
    } else try dict.appendSlice(w.gpa, std.fmt.bufPrint(&b, " /ColorSpace /{s}", .{im.space}) catch unreachable);
    if (im.alpha != null) try dict.appendSlice(w.gpa, std.fmt.bufPrint(&b, " /SMask {d} 0 R", .{num + 1}) catch unreachable);
    switch (im.filter) {
        .dct => {
            try dict.appendSlice(w.gpa, " /Filter /DCTDecode");
            try w.stream(num, dict.items, im.data, false);
        },
        .flate => {
            try dict.appendSlice(w.gpa, " /Filter /FlateDecode");
            if (im.predictor) try dict.appendSlice(w.gpa, std.fmt.bufPrint(&b, " /DecodeParms << /Predictor 15 /Colors {d} /BitsPerComponent {d} /Columns {d} >>", .{ im.colors, im.bits, im.width }) catch unreachable);
            try w.stream(num, dict.items, im.data, false);
        },
    }
    if (im.alpha) |a| {
        const sm = std.fmt.bufPrint(&b, " /Type /XObject /Subtype /Image /Width {d} /Height {d} /BitsPerComponent 8 /ColorSpace /DeviceGray", .{ im.width, im.height }) catch unreachable;
        try w.stream(num + 1, sm, a, true);
    }
}

const Writer = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    offsets: std.ArrayList(usize) = .empty,
    compress: bool,

    fn raw(w: *Writer, s: []const u8) Error!void {
        try w.buf.appendSlice(w.gpa, s);
    }

    fn print(w: *Writer, comptime fmt: []const u8, args: anytype) Error!void {
        try w.buf.print(w.gpa, fmt, args);
    }

    fn begin(w: *Writer, num: u32) Error!void {
        while (w.offsets.items.len <= num) try w.offsets.append(w.gpa, 0);
        w.offsets.items[num] = w.buf.items.len;
        try w.print("{d} 0 obj\n", .{num});
    }

    fn end(w: *Writer) Error!void {
        try w.raw("endobj\n");
    }

    /// A stream object. `extra` goes in the dictionary. With `deflate`,
    /// the data goes in compressed (when the doc compresses).
    fn stream(w: *Writer, num: u32, extra: []const u8, data: []const u8, deflate: bool) Error!void {
        try w.begin(num);
        if (deflate and w.compress) {
            const z = try zlib(w.gpa, data);
            defer w.gpa.free(z);
            try w.print("<<{s} /Length {d} /Filter /FlateDecode >>\nstream\n", .{ extra, z.len });
            try w.raw(z);
        } else {
            try w.print("<<{s} /Length {d} >>\nstream\n", .{ extra, data.len });
            try w.raw(data);
        }
        try w.raw("\nendstream\n");
        try w.end();
    }

    /// A text string: PDFDocEncoding for ASCII, else UTF-16BE with a BOM.
    fn textString(w: *Writer, s: []const u8) Error!void {
        var ascii = true;
        for (s) |c| if (c >= 0x80) {
            ascii = false;
        };
        if (ascii) return w.literal(s);
        try w.raw("<FEFF");
        var view = std.unicode.Utf8View.init(s) catch std.unicode.Utf8View.initUnchecked("");
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp >= 0x10000) {
                const v = cp - 0x10000;
                try w.print("{X:0>4}{X:0>4}", .{ 0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff) });
            } else try w.print("{X:0>4}", .{cp});
        }
        try w.raw(">");
    }

    fn literal(w: *Writer, s: []const u8) Error!void {
        try w.raw("(");
        for (s) |c| switch (c) {
            '(', ')', '\\' => {
                try w.raw("\\");
                try w.buf.append(w.gpa, c);
            },
            0...0x1f, 0x7f...0xff => try w.print("\\{o:0>3}", .{c}),
            else => try w.buf.append(w.gpa, c),
        };
        try w.raw(")");
    }
};

pub fn zlib(gpa: Allocator, data: []const u8) Error![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, data.len / 2 + 64);
    errdefer aw.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var c = std.compress.flate.Compress.init(&aw.writer, window, .zlib, .default) catch return error.OutOfMemory;
    c.writer.writeAll(data) catch return error.OutOfMemory;
    c.finish() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn inflate(gpa: Allocator, data: []const u8, limit: usize) Error![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var d = std.compress.flate.Decompress.init(&in, .zlib, &.{});
    _ = d.reader.streamRemaining(&aw.writer) catch return error.BadImage;
    if (aw.written().len > limit) return error.BadImage;
    return aw.toOwnedSlice();
}

fn readPng(gpa: Allocator, b: []const u8) Error!Image {
    var at: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var depth: u8 = 0;
    var ctype: u8 = 0;
    var interlace: u8 = 0;
    var palette: []const u8 = &.{};
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    while (at + 12 <= b.len) {
        const len = std.mem.readInt(u32, b[at..][0..4], .big);
        const kind = b[at + 4 ..][0..4];
        if (at + 12 + @as(usize, len) > b.len) return error.BadImage;
        const body = b[at + 8 ..][0..len];
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.BadImage;
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            depth = body[8];
            ctype = body[9];
            interlace = body[12];
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette = body;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, body);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
        at += 12 + len;
    }
    if (width == 0 or height == 0 or width > 1 << 15 or height > 1 << 15) return error.BadImage;
    if (depth != 8 or interlace != 0) return error.Unsupported;
    const colors: u8 = switch (ctype) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.BadImage,
    };
    const space: []const u8 = if (ctype == 2 or ctype == 6) "DeviceRGB" else "DeviceGray";
    if (ctype == 0 or ctype == 2 or ctype == 3) {
        const pal = try gpa.dupe(u8, if (ctype == 3) palette else "");
        errdefer gpa.free(pal);
        if (ctype == 3 and (pal.len == 0 or pal.len % 3 != 0)) return error.BadImage;
        return .{ .width = width, .height = height, .space = space, .palette = pal, .filter = .flate, .data = try idat.toOwnedSlice(gpa), .predictor = true, .colors = colors };
    }
    // An alpha channel: unfilter, then split the color and the alpha.
    const stride = @as(usize, width) * colors;
    const raw = try inflate(gpa, idat.items, (stride + 1) * height);
    defer gpa.free(raw);
    if (raw.len < (stride + 1) * height) return error.BadImage;
    const pix = try gpa.alloc(u8, stride * height);
    defer gpa.free(pix);
    for (0..height) |y| {
        const ft = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const dst = pix[y * stride ..][0..stride];
        const up: ?[]const u8 = if (y > 0) pix[(y - 1) * stride ..][0..stride] else null;
        for (0..stride) |i| {
            const a: u8 = if (i >= colors) dst[i - colors] else 0;
            const u: u8 = if (up) |p| p[i] else 0;
            const c: u8 = if (i >= colors and up != null) up.?[i - colors] else 0;
            dst[i] = src[i] +% switch (ft) {
                0 => 0,
                1 => a,
                2 => u,
                3 => @as(u8, @intCast((@as(u16, a) + u) / 2)),
                4 => paeth(a, u, c),
                else => return error.BadImage,
            };
        }
    }
    const cn = colors - 1;
    const color = try gpa.alloc(u8, @as(usize, width) * height * cn);
    defer gpa.free(color);
    const alpha = try gpa.alloc(u8, @as(usize, width) * height);
    defer gpa.free(alpha);
    for (0..@as(usize, width) * height) |p| {
        @memcpy(color[p * cn ..][0..cn], pix[p * colors ..][0..cn]);
        alpha[p] = pix[p * colors + cn];
    }
    const zc = try zlib(gpa, color);
    errdefer gpa.free(zc);
    return .{ .width = width, .height = height, .space = space, .filter = .flate, .data = zc, .predictor = false, .colors = cn, .alpha = try gpa.dupe(u8, alpha) };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn readJpeg(gpa: Allocator, b: []const u8) Error!Image {
    var at: usize = 2;
    while (at + 4 <= b.len) {
        if (b[at] != 0xff) return error.BadImage;
        const marker = b[at + 1];
        const len = std.mem.readInt(u16, b[at + 2 ..][0..2], .big);
        // SOF0 to SOF15, except DHT (C4), JPG (C8), and DAC (CC).
        if (marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc) {
            if (at + 10 > b.len) return error.BadImage;
            const h = std.mem.readInt(u16, b[at + 5 ..][0..2], .big);
            const w = std.mem.readInt(u16, b[at + 7 ..][0..2], .big);
            const comps = b[at + 9];
            const space: []const u8 = switch (comps) {
                1 => "DeviceGray",
                3 => "DeviceRGB",
                4 => "DeviceCMYK",
                else => return error.BadImage,
            };
            return .{ .width = w, .height = h, .space = space, .filter = .dct, .data = try gpa.dupe(u8, b), .predictor = false, .colors = comps };
        }
        at += 2 + len;
    }
    return error.BadImage;
}

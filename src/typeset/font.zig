//! A font for the typesetter: a TrueType face with the metrics of the PDF
//! font descriptor, the `liga` ligatures of GSUB, and a shaper.
//!
//! The shaper maps each code point to a glyph through `cmap`, replaces
//! glyph runs with ligatures (GSUB lookup type 4, also inside extension
//! lookups of type 7), and adds the GPOS pair kerning of `ttf.zig`. The
//! result has one entry for each glyph, with its advance in font units
//! and the text that it shows, for the ToUnicode map of the PDF.
//! The source is the OpenType specification (docs/references/typeset.md).
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ttf = @import("ttf.zig");

const be16 = ttf.be16;
const be16s = ttf.be16s;
const be32 = ttf.be32;

/// The most ligature subtables. A font input sets the count, so it has a limit.
const max_liga = 32;
/// The most steps of one ligature walk.
const max_liga_steps = 1 << 14;

pub const Glyph = struct {
    id: u16,
    /// The advance in font units, with the kerning to the next glyph.
    advance: i32,
    /// The offsets of the text of the glyph in the input.
    start: u32,
    end: u32,
};

pub const Font = struct {
    face: ttf.Face,
    data: []const u8,
    ps_name: [64]u8 = undefined,
    ps_len: u8 = 0,
    bbox: [4]i16 = .{ 0, 0, 0, 0 },
    italic_angle: f32 = 0,
    cap_height: i16 = 0,
    x_height: i16 = 0,
    fixed_pitch: bool = false,
    serif: bool = false,
    gsub: []const u8 = &.{},
    liga: [max_liga]u32 = undefined,
    liga_count: u8 = 0,

    /// Reads a font. `data` must stay valid as long as the font.
    pub fn init(data: []const u8) error{ BadFont, Unsupported }!Font {
        var f: Font = .{ .face = try ttf.Face.init(data), .data = data };
        const head = (try ttf.Face.table(data, "head")) orelse return error.BadFont;
        f.bbox = .{ try be16s(head, 36), try be16s(head, 38), try be16s(head, 40), try be16s(head, 42) };
        if (try ttf.Face.table(data, "post")) |post| {
            const fixed: i32 = @bitCast(try be32(post, 4));
            f.italic_angle = @as(f32, @floatFromInt(fixed)) / 65536.0;
            f.fixed_pitch = (try be32(post, 12)) != 0;
        }
        if (try ttf.Face.table(data, "OS/2")) |os2| {
            const version = try be16(os2, 0);
            if (version >= 2 and os2.len >= 90) {
                f.x_height = try be16s(os2, 86);
                f.cap_height = try be16s(os2, 88);
            }
            // The serif style of the family class (IBM classes 1 to 7).
            const class = try be16(os2, 30) >> 8;
            f.serif = class >= 1 and class <= 7;
        }
        if (f.cap_height == 0) f.cap_height = @intCast(@divTrunc(@as(i32, f.face.ascent) * 7, 10));
        if (try ttf.Face.table(data, "name")) |n| f.readPsName(n) catch {};
        if (f.ps_len == 0) {
            const fallback = "Font";
            @memcpy(f.ps_name[0..fallback.len], fallback);
            f.ps_len = fallback.len;
        }
        if (try ttf.Face.table(data, "GSUB")) |g| {
            f.gsub = g;
            f.findLiga() catch {
                f.liga_count = 0;
            };
        }
        return f;
    }

    pub fn psName(f: *const Font) []const u8 {
        return f.ps_name[0..f.ps_len];
    }

    pub fn unitsPerEm(f: *const Font) f32 {
        return @floatFromInt(f.face.units_per_em);
    }

    /// Name ID 6 of the name table. Only the printable ASCII characters
    /// that a PDF name can hold go in.
    fn readPsName(f: *Font, n: []const u8) ttf.Err!void {
        const count = try be16(n, 2);
        const strings: usize = try be16(n, 4);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const rec = 6 + i * 12;
            const platform = try be16(n, rec);
            const id = try be16(n, rec + 6);
            if (id != 6) continue;
            const len: usize = try be16(n, rec + 8);
            const off: usize = strings + try be16(n, rec + 10);
            if (off + len > n.len) return error.BadFont;
            const raw = n[off .. off + len];
            const wide = platform == 3 or platform == 0;
            var j: usize = if (wide) 1 else 0;
            f.ps_len = 0;
            while (j < raw.len and f.ps_len < f.ps_name.len) : (j += if (wide) 2 else 1) {
                const c = raw[j];
                if (c > 0x20 and c < 0x7f and std.mem.indexOfScalar(u8, "()<>[]{}/%#", c) == null) {
                    f.ps_name[f.ps_len] = c;
                    f.ps_len += 1;
                }
            }
            if (f.ps_len > 0) return;
        }
    }

    fn findLiga(f: *Font) ttf.Err!void {
        const g = f.gsub;
        const script_list: usize = try be16(g, 4);
        const feature_list: usize = try be16(g, 6);
        const lookup_list: usize = try be16(g, 8);
        var lookups: [max_liga]u16 = undefined;
        var nl: usize = 0;
        const nscripts = try be16(g, script_list);
        var si: usize = 0;
        while (si < nscripts and si < 64) : (si += 1) {
            const rec = script_list + 2 + si * 6;
            if (rec + 6 > g.len) return error.BadFont;
            const tag = g[rec..][0..4];
            if (!std.mem.eql(u8, tag, "DFLT") and !std.mem.eql(u8, tag, "latn")) continue;
            const script: usize = script_list + try be16(g, rec + 4);
            const lang_off: usize = try be16(g, script);
            if (lang_off == 0) continue;
            const lang: usize = script + lang_off;
            const nfeat = try be16(g, lang + 4);
            var fi: usize = 0;
            while (fi < nfeat and fi < 256) : (fi += 1) {
                const idx = try be16(g, lang + 6 + fi * 2);
                const frec = feature_list + 2 + @as(usize, idx) * 6;
                if (frec + 6 > g.len) return error.BadFont;
                if (!std.mem.eql(u8, g[frec..][0..4], "liga")) continue;
                const feat: usize = feature_list + try be16(g, frec + 4);
                const nli = try be16(g, feat + 2);
                var li: usize = 0;
                while (li < nli and li < 64) : (li += 1) {
                    const lidx = try be16(g, feat + 4 + li * 2);
                    if (std.mem.indexOfScalar(u16, lookups[0..nl], lidx) == null and nl < lookups.len) {
                        lookups[nl] = lidx;
                        nl += 1;
                    }
                }
            }
        }
        std.mem.sort(u16, lookups[0..nl], {}, std.sort.asc(u16));
        for (lookups[0..nl]) |lidx| {
            const lo: usize = lookup_list + try be16(g, lookup_list + 2 + @as(usize, lidx) * 2);
            const ltype = try be16(g, lo);
            const nsub = try be16(g, lo + 4);
            var k: usize = 0;
            while (k < nsub and k < 64) : (k += 1) {
                var sub: usize = lo + try be16(g, lo + 6 + k * 2);
                var t = ltype;
                if (t == 7) {
                    t = try be16(g, sub + 2);
                    sub += try be32(g, sub + 4);
                }
                if (t != 4 or (try be16(g, sub)) != 1) continue;
                if (f.liga_count == max_liga) return;
                f.liga[f.liga_count] = std.math.cast(u32, sub) orelse return error.BadFont;
                f.liga_count += 1;
            }
        }
    }

    /// The ligature at the start of `glyphs`: the glyph and the count of
    /// glyphs that it replaces, or null.
    fn ligature(f: *const Font, glyphs: []const u16) ?struct { id: u16, len: usize } {
        var steps: usize = 0;
        for (f.liga[0..f.liga_count]) |sub| {
            const r = ligaAt(f.gsub, sub, glyphs, &steps) catch return null;
            if (r) |x| return .{ .id = x.id, .len = x.len };
        }
        return null;
    }

    /// Shapes `text` (UTF-8). With `ligatures` off, each code point is one
    /// glyph. The caller frees the result.
    pub fn shape(f: *const Font, gpa: std.mem.Allocator, text: []const u8, ligatures: bool) ![]Glyph {
        var out: std.ArrayList(Glyph) = .empty;
        errdefer out.deinit(gpa);
        var ids: std.ArrayList(u16) = .empty;
        defer ids.deinit(gpa);
        var starts: std.ArrayList(u32) = .empty;
        defer starts.deinit(gpa);
        var i: usize = 0;
        while (i < text.len) {
            const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const cp: u21 = if (i + n <= text.len) (std.unicode.utf8Decode(text[i .. i + n]) catch 0xfffd) else 0xfffd;
            try ids.append(gpa, f.face.glyphIndex(cp));
            try starts.append(gpa, @intCast(i));
            i += if (i + n <= text.len) n else 1;
        }
        try starts.append(gpa, @intCast(text.len));
        var k: usize = 0;
        while (k < ids.items.len) {
            var id = ids.items[k];
            var len: usize = 1;
            if (ligatures and f.liga_count > 0) {
                if (f.ligature(ids.items[k..])) |l| {
                    id = l.id;
                    len = l.len;
                }
            }
            try out.append(gpa, .{ .id = id, .advance = f.face.advance(id), .start = starts.items[k], .end = starts.items[k + len] });
            k += len;
        }
        for (out.items[0..out.items.len -| 1], 1..) |*gl, j| gl.advance += f.face.kerning(gl.id, out.items[j].id);
        return out.toOwnedSlice(gpa);
    }

    /// The advance of a code point in font units.
    pub fn advanceOf(f: *const Font, cp: u21) i32 {
        return f.face.advance(f.face.glyphIndex(cp));
    }
};

fn coverage(g: []const u8, off: usize, glyph: u16) ttf.Err!?usize {
    const format = try be16(g, off);
    const count = try be16(g, off + 2);
    if (format == 1) {
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const v = try be16(g, off + 4 + mid * 2);
            if (v == glyph) return mid;
            if (v < glyph) lo = mid + 1 else hi = mid;
        }
        return null;
    }
    if (format == 2) {
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = off + 4 + mid * 6;
            const first = try be16(g, r);
            const last = try be16(g, r + 2);
            if (glyph < first) {
                hi = mid;
            } else if (glyph > last) {
                lo = mid + 1;
            } else return @as(usize, try be16(g, r + 4)) + (glyph - first);
        }
        return null;
    }
    return null;
}

fn ligaAt(g: []const u8, sub: usize, glyphs: []const u16, steps: *usize) ttf.Err!?struct { id: u16, len: usize } {
    const cov = sub + try be16(g, sub + 2);
    const idx = (try coverage(g, cov, glyphs[0])) orelse return null;
    const nsets = try be16(g, sub + 4);
    if (idx >= nsets) return error.BadFont;
    const set = sub + try be16(g, sub + 6 + idx * 2);
    const nlig = try be16(g, set);
    var li: usize = 0;
    while (li < nlig) : (li += 1) {
        steps.* += 1;
        if (steps.* > max_liga_steps) return error.BadFont;
        const lig = set + try be16(g, set + 2 + li * 2);
        const glyph = try be16(g, lig);
        const comps: usize = try be16(g, lig + 2);
        if (comps == 0 or comps > glyphs.len) continue;
        var ok = true;
        var c: usize = 1;
        while (c < comps) : (c += 1) {
            if ((try be16(g, lig + 4 + (c - 1) * 2)) != glyphs[c]) {
                ok = false;
                break;
            }
        }
        if (ok) return .{ .id = glyph, .len = comps };
    }
    return null;
}

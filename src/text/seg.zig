//! Text segmentation of UAX #29 and display width of UAX #11 and UTS #51.
//!
//! One lookup in the tables of tables.zig gives the 32-bit `Props` of a
//! code point: the Grapheme_Cluster_Break, Word_Break, and Sentence_Break
//! classes, Indic_Conjunct_Break, Extended_Pictographic, the emoji
//! flags, and the width.
//!
//! Grapheme clusters: `graphemeEnd` walks one cluster from a boundary.
//! A 14 x 14 bit table holds the pair rules GB3 to GB9b. Three small
//! states hold the rules with context: an odd count of regional
//! indicators (GB12, GB13), the emoji state "Extended_Pictographic
//! Extend* ZWJ" (GB11), and the conjunct state "InCB=Linker
//! InCB=Extend*" (GB9c). A cluster always starts these states again,
//! since each of the three contexts is inside one cluster.
//!
//! `skip` and `count` read 16 or 32 bytes at a time when the bytes are
//! ASCII or the two-byte forms of U+0080 to U+02FF. Each such code point
//! is a cluster of its own, except LF after CR, so the count of clusters
//! is the count of first bytes less the count of CR LF pairs. The last
//! code point of the block goes to the scalar walk, since a combining
//! mark after the block can join it.
//!
//! Words and sentences: `Words` and `Sentences` step one code point at a
//! time and keep the classes of the last two code points that the
//! ignore rules (WB4, SB5) keep. A look ahead past Extend and Format
//! gives the right context of WB6, WB7b, WB12, and SB8.
//!
//! Width: a code point has width 0 (marks, formats, controls, default
//! ignorables, the medial and final jamo of Hangul), 1, 2 (East Asian
//! Wide and Fullwidth, and Emoji_Presentation), or "ambiguous". A
//! cluster has the largest width of its code points, plus the width of
//! each spacing mark and each conjunct consonant after the first code
//! point. VS16 after an emoji makes it 2, and a pair of regional
//! indicators is 2. The rules give the cursor moves of libghostty-vt
//! with mode 2027, which src/text/tests.zig checks.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const t = @import("tables.zig");

pub const Gcb = enum(u4) { other, cr, lf, control, extend, zwj, ri, prepend, spacing_mark, l, v, t, lv, lvt, _ };
pub const Wb = enum(u5) { other, cr, lf, newline, extend, zwj, ri, format, katakana, hebrew_letter, aletter, single_quote, double_quote, midnumlet, midletter, midnum, numeric, extendnumlet, wsegspace, _ };
pub const Sb = enum(u4) { other, cr, lf, extend, sep, format, sp, lower, upper, oletter, numeric, aterm, scontinue, sterm, close, _ };
pub const Incb = enum(u2) { none, linker, consonant, extend };

/// The properties of one code point, as tools/text-gen.py packs them.
pub const Props = packed struct(u32) {
    gcb: Gcb,
    incb: Incb,
    ep: bool,
    wb: Wb,
    sb: Sb,
    /// 0, 1, 2, or 3 for East Asian Ambiguous.
    width: u2,
    emoji: bool,
    epres: bool,
    /// The general category is a letter or a number.
    alnum: bool,
    _: u11,
};

pub inline fn props(cp: u21) Props {
    if (cp < 128) return @bitCast(t.rows[t.ascii[cp]]);
    const mid: usize = t.stage1[cp >> (t.leaf_bits + t.mid_bits)];
    const leaf: usize = t.stage2[(mid << t.mid_bits) | ((cp >> t.leaf_bits) & t.mid_mask)];
    return @bitCast(t.rows[t.stage3[(leaf << t.leaf_bits) | (cp & t.leaf_mask)]]);
}

pub const Cp = struct { cp: u21, len: u3 };

/// Decodes the code point at byte `i`. A byte that does not start a
/// valid sequence is one code point with the value of the byte, as in
/// `ucd.next`. Surrogate halves in the generalized form decode too.
pub inline fn decode(s: []const u8, i: usize) Cp {
    const c = s[i];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    const bad: Cp = .{ .cp = c, .len = 1 };
    if (c < 0xC2) return bad;
    if (c < 0xE0) {
        if (i + 1 >= s.len or s[i + 1] & 0xC0 != 0x80) return bad;
        return .{ .cp = @as(u21, c & 0x1F) << 6 | (s[i + 1] & 0x3F), .len = 2 };
    }
    if (c < 0xF0) {
        if (i + 2 >= s.len or s[i + 1] & 0xC0 != 0x80 or s[i + 2] & 0xC0 != 0x80) return bad;
        if (c == 0xE0 and s[i + 1] < 0xA0) return bad;
        return .{ .cp = @as(u21, c & 0x0F) << 12 | @as(u21, s[i + 1] & 0x3F) << 6 | (s[i + 2] & 0x3F), .len = 3 };
    }
    if (c < 0xF5) {
        if (i + 3 >= s.len or s[i + 1] & 0xC0 != 0x80 or s[i + 2] & 0xC0 != 0x80 or s[i + 3] & 0xC0 != 0x80) return bad;
        if ((c == 0xF0 and s[i + 1] < 0x90) or (c == 0xF4 and s[i + 1] >= 0x90)) return bad;
        return .{ .cp = @as(u21, c & 0x07) << 18 | @as(u21, s[i + 1] & 0x3F) << 12 | @as(u21, s[i + 2] & 0x3F) << 6 | (s[i + 3] & 0x3F), .len = 4 };
    }
    return bad;
}

/// The start of the code point that ends at byte `p` (p > 0).
pub fn prevCp(s: []const u8, p: usize) usize {
    var k: usize = 1;
    while (k <= 4 and k <= p) : (k += 1) {
        const c = s[p - k];
        if (c & 0xC0 != 0x80) {
            if (decode(s, p - k).len == k) return p - k;
            return p - 1;
        }
    }
    return p - 1;
}

// ---- Grapheme clusters ----

/// Bit q of `join[p]` is set when GB3 to GB9b keep the classes p and q
/// in one cluster.
const join: [16]u16 = blk: {
    var j: [16]u16 = @splat(0);
    const b = struct {
        fn bit(g: Gcb) u16 {
            return @as(u16, 1) << @backingInt(g);
        }
    }.bit;
    for (0..14) |pi| {
        const p: Gcb = @fromBackingInt(@intCast(pi));
        var m: u16 = 0;
        if (p != .cr and p != .lf and p != .control) {
            m |= b(.extend) | b(.zwj) | b(.spacing_mark); // GB9, GB9a
            if (p == .prepend) m |= ~(b(.cr) | b(.lf) | b(.control)); // GB9b
            if (p == .l) m |= b(.l) | b(.v) | b(.lv) | b(.lvt); // GB6
            if (p == .lv or p == .v) m |= b(.v) | b(.t); // GB7
            if (p == .lvt or p == .t) m |= b(.t); // GB8
        }
        if (p == .cr) m = b(.lf); // GB3, GB4
        j[pi] = m;
    }
    break :blk j;
};

/// The state of a walk inside one cluster.
const GState = struct {
    p: Props,
    ri_odd: bool,
    /// 1 after Extended_Pictographic Extend*, 2 after its ZWJ.
    emo: u2,
    /// After InCB=Linker InCB=Extend*.
    linker: bool,

    inline fn start(p: Props) GState {
        return .{ .p = p, .ri_odd = p.gcb == .ri, .emo = @intFromBool(p.ep), .linker = p.incb == .linker };
    }

    inline fn joins(g: GState, q: Props) bool {
        if ((join[@backingInt(g.p.gcb)] >> @backingInt(q.gcb)) & 1 != 0) return true;
        if (g.linker and q.incb == .consonant) return true; // GB9c
        if (g.emo == 2 and q.ep) return true; // GB11
        return g.ri_odd and q.gcb == .ri; // GB12, GB13
    }

    inline fn step(g: *GState, q: Props) void {
        g.ri_odd = q.gcb == .ri and !g.ri_odd;
        g.emo = if (q.ep) 1 else if (g.emo == 1 and q.gcb == .extend) 1 else if (g.emo == 1 and q.gcb == .zwj) 2 else 0;
        g.linker = q.incb == .linker or (g.linker and q.incb == .extend);
        g.p = q;
    }
};

/// The end of the grapheme cluster that starts at byte `i` (a boundary).
pub fn graphemeEnd(s: []const u8, i: usize) usize {
    const c = s[i];
    if (c < 0x80 and c != '\r' and (i + 1 == s.len or s[i + 1] < 0x80)) return i + 1;
    const d = decode(s, i);
    var g = GState.start(props(d.cp));
    var j = i + d.len;
    while (j < s.len) {
        const e = decode(s, j);
        const q = props(e.cp);
        if (!g.joins(q)) break;
        g.step(q);
        j += e.len;
    }
    return j;
}

/// The start of the grapheme cluster that holds the byte before `pos`
/// (pos > 0). The walk goes back to a code point with a boundary before
/// it by GB4, GB5, or GB999, and then forward.
pub fn graphemeBefore(s: []const u8, pos: usize) usize {
    var p = pos;
    while (p > 0) {
        p = prevCp(s, p);
        if (p == 0) break;
        const q = props(decode(s, p).cp);
        const safe = switch (q.gcb) {
            .control, .cr => true,
            .lf => s[p - 1] != '\r',
            .other => !q.ep and q.incb != .consonant and props(decode(s, prevCp(s, p)).cp).gcb != .prepend,
            else => false,
        };
        if (safe and p < pos) break;
    }
    var start = p;
    while (true) {
        const e = graphemeEnd(s, start);
        if (e >= pos) return start;
        start = e;
    }
}

const V = std.simd.suggestVectorLength(u8) orelse 16;
const Mask = @Int(.unsigned, V);

/// The result of a skip: the byte offset and the count of clusters.
pub const Skip = struct { pos: usize, n: usize };

/// Skips up to `k` clusters from the boundary `start`.
pub fn skip(s: []const u8, start: usize, k: usize) Skip {
    var i = start;
    var n: usize = 0;
    var simd_from = i;
    while (i < s.len and n < k) {
        if (i >= simd_from and i + V <= s.len) {
            if (block(s[i..][0..V])) |b| {
                if (n + b.n <= k) {
                    n += b.n;
                    i += b.len;
                    continue;
                }
            } else simd_from = i + V;
        }
        i = graphemeEnd(s, i);
        n += 1;
    }
    return .{ .pos = i, .n = n };
}

pub fn count(s: []const u8) usize {
    return skip(s, 0, std.math.maxInt(usize)).n;
}

/// The clusters of a block of V bytes before its last code point, when
/// each byte is ASCII, a continuation byte, or a lead byte of U+0080 to
/// U+02FF (C2 to CB). The block starts at a boundary.
inline fn block(p: *const [V]u8) ?struct { n: usize, len: usize } {
    const v: @Vector(V, u8) = p.*;
    const latin = (v < @as(@Vector(V, u8), @splat(0xC0))) | ((v >= @as(@Vector(V, u8), @splat(0xC2))) & (v <= @as(@Vector(V, u8), @splat(0xCB))));
    if (!@reduce(.And, latin)) return null;
    const cont: Mask = @bitCast((v & @as(@Vector(V, u8), @splat(0xC0))) == @as(@Vector(V, u8), @splat(0x80)));
    const cr: Mask = @bitCast(v == @as(@Vector(V, u8), @splat('\r')));
    const lf: Mask = @bitCast(v == @as(@Vector(V, u8), @splat('\n')));
    if (cont & 1 != 0) return null;
    const starts = ~cont;
    var last: usize = V - 1 - @clz(starts);
    // LF after CR is in the cluster of the CR.
    if (last > 0 and p[last] == '\n' and p[last - 1] == '\r') last -= 1;
    if (last == 0) return null;
    const below: Mask = (@as(Mask, 1) << @intCast(last)) - 1;
    const joined = (cr << 1) & lf & below;
    return .{ .n = @popCount(starts & below) - @popCount(joined), .len = last };
}

// ---- Words ----

inline fn ah(w: Wb) bool {
    return w == .aletter or w == .hebrew_letter;
}

inline fn midLetQ(w: Wb) bool {
    return w == .midnumlet or w == .single_quote;
}

inline fn newline(w: Wb) bool {
    return w == .newline or w == .cr or w == .lf;
}

inline fn ignoredW(w: Wb) bool {
    return w == .extend or w == .format or w == .zwj;
}

/// The Word_Break class of the first code point at or after `j` that WB4
/// keeps, or null at the end.
fn aheadW(s: []const u8, j: usize) ?Wb {
    var i = j;
    while (i < s.len) {
        const d = decode(s, i);
        const w = props(d.cp).wb;
        if (!ignoredW(w)) return w;
        i += d.len;
    }
    return null;
}

/// The word segments of UAX #29, in order. Each byte of the text is in
/// one segment.
pub const Words = struct {
    s: []const u8,
    i: usize = 0,
    /// The raw class of the code point before `i`.
    raw: Wb = .other,
    /// The last two classes that WB4 keeps; null before the text.
    l1: ?Wb = null,
    l2: ?Wb = null,
    ri_odd: bool = false,
    ep_prev: bool = false,

    /// True when a word boundary is between the code point before `j`
    /// and the code point `q` at `j`, with `len` bytes.
    fn breaks(w: *const Words, j: usize, q: Props, len: usize) bool {
        const p = w.raw;
        const c = q.wb;
        // Two letters: no rule before WB5 matches, and WB5 joins them.
        if (ah(p) and ah(c)) return false;
        if (p == .cr and c == .lf) return false; // WB3
        if (newline(p) or newline(c)) return true; // WB3a, WB3b
        if (p == .zwj and q.ep) return false; // WB3c
        if (p == .wsegspace and c == .wsegspace) return false; // WB3d
        if (ignoredW(c)) return false; // WB4
        const l = w.l1 orelse return true;
        const l2 = w.l2;
        if (ah(l) and ah(c)) return false; // WB5
        if (ah(l) and (c == .midletter or midLetQ(c))) {
            if (aheadW(w.s, j + len)) |a| if (ah(a)) return false; // WB6
        }
        if (l2 != null and ah(l2.?) and (l == .midletter or midLetQ(l)) and ah(c)) return false; // WB7
        if (l == .hebrew_letter and c == .single_quote) return false; // WB7a
        if (l == .hebrew_letter and c == .double_quote) {
            if (aheadW(w.s, j + len) == .hebrew_letter) return false; // WB7b
        }
        if (l2 == .hebrew_letter and l == .double_quote and c == .hebrew_letter) return false; // WB7c
        if (l == .numeric and c == .numeric) return false; // WB8
        if (ah(l) and c == .numeric) return false; // WB9
        if (l == .numeric and ah(c)) return false; // WB10
        if (l2 == .numeric and (l == .midnum or midLetQ(l)) and c == .numeric) return false; // WB11
        if (l == .numeric and (c == .midnum or midLetQ(c))) {
            if (aheadW(w.s, j + len) == .numeric) return false; // WB12
        }
        if (l == .katakana and c == .katakana) return false; // WB13
        if ((ah(l) or l == .numeric or l == .katakana or l == .extendnumlet) and c == .extendnumlet) return false; // WB13a
        if (l == .extendnumlet and (ah(c) or c == .numeric or c == .katakana)) return false; // WB13b
        if (l == .ri and c == .ri and w.ri_odd) return false; // WB15, WB16
        return true; // WB999
    }

    fn step(w: *Words, q: Props) void {
        const c = q.wb;
        w.raw = c;
        if (ignoredW(c)) {
            if (w.l1) |l| if (!newline(l)) return;
        }
        w.ri_odd = c == .ri and !(w.l1 == .ri and w.ri_odd);
        w.l2 = w.l1;
        w.l1 = c;
    }

    /// The next segment, or null at the end.
    pub fn next(w: *Words) ?[]const u8 {
        const s = w.s;
        if (w.i >= s.len) return null;
        const start = w.i;
        var j = start;
        while (j < s.len) {
            const d = decode(s, j);
            const q = props(d.cp);
            if (j > start and w.breaks(j, q, d.len)) break;
            w.step(q);
            j += d.len;
        }
        w.i = j;
        return s[start..j];
    }
};

/// True when the segment has a letter or a number: a word in the sense
/// of `ztcl::text words` without -all.
pub fn wordLike(seg: []const u8) bool {
    var i: usize = 0;
    while (i < seg.len) {
        const d = decode(seg, i);
        if (props(d.cp).alnum) return true;
        i += d.len;
    }
    return false;
}

/// The word segment that holds byte `i`, as [start, end).
pub fn wordAt(s: []const u8, i: usize) [2]usize {
    var w: Words = .{ .s = s };
    var start: usize = 0;
    while (w.next()) |seg| {
        const end = start + seg.len;
        if (i < end) return .{ start, end };
        start = end;
    }
    return .{ s.len, s.len };
}

// ---- Sentences ----

inline fn paraSep(c: Sb) bool {
    return c == .sep or c == .cr or c == .lf;
}

inline fn saTerm(c: Sb) bool {
    return c == .sterm or c == .aterm;
}

/// The sentence segments of UAX #29, in order.
pub const Sentences = struct {
    s: []const u8,
    i: usize = 0,
    raw: Sb = .other,
    l1: ?Sb = null,
    l2: ?Sb = null,
    /// 0: no terminator; 1: SATerm Close*; 2: SATerm Close* Sp+.
    phase: u2 = 0,
    aterm: bool = false,
    /// The ASCII skip of `skipAscii`. A test turns it off to compare.
    fast: bool = true,

    fn breaks(z: *const Sentences, j: usize, q: Props) bool {
        const p = z.raw;
        const c = q.sb;
        // With no terminator before, only SB3 and SB4 can break: SB6 and
        // SB7 need ATerm before, which sets the phase.
        if (z.phase == 0 and z.l1 != null) return paraSep(p) and !(p == .cr and c == .lf);
        if (p == .cr and c == .lf) return false; // SB3
        if (paraSep(p)) return true; // SB4
        if (c == .extend or c == .format) return false; // SB5
        const l = z.l1 orelse return true;
        if (l == .aterm and c == .numeric) return false; // SB6
        if ((z.l2 == .upper or z.l2 == .lower) and l == .aterm and c == .upper) return false; // SB7
        if (z.phase == 0) return false; // SB998
        if (z.aterm) {
            // SB8: ( ¬(OLetter | Upper | Lower | ParaSep | SATerm) )* Lower
            var k = j;
            while (k < z.s.len) {
                const d = decode(z.s, k);
                const b = props(d.cp).sb;
                if (b == .lower) return false;
                if (b == .oletter or b == .upper or paraSep(b) or saTerm(b)) break;
                k += d.len;
            }
        }
        if (c == .scontinue or saTerm(c)) return false; // SB8a
        if (z.phase == 1 and (c == .close or c == .sp or paraSep(c))) return false; // SB9
        if (c == .sp or paraSep(c)) return false; // SB10
        return true; // SB11
    }

    /// With no terminator before and no paragraph separator just before,
    /// no rule breaks before an ASCII byte other than `.`, `!`, `?`, CR,
    /// and LF, and such a byte only moves the last two classes. The scan
    /// reads 16 or 32 bytes at a time. It gives the first byte that needs
    /// the full step.
    fn skipAscii(z: *Sentences, j0: usize) usize {
        const s = z.s;
        var j = j0;
        while (j + V <= s.len) {
            const v: @Vector(V, u8) = s[j..][0..V].*;
            const stop = (v >= @as(@Vector(V, u8), @splat(0x80))) | (v == @as(@Vector(V, u8), @splat('.'))) |
                (v == @as(@Vector(V, u8), @splat('!'))) | (v == @as(@Vector(V, u8), @splat('?'))) |
                (v == @as(@Vector(V, u8), @splat('\r'))) | (v == @as(@Vector(V, u8), @splat('\n')));
            const m: Mask = @bitCast(stop);
            if (m != 0) {
                j += @ctz(m);
                break;
            }
            j += V;
        } else {
            while (j < s.len and s[j] < 0x80 and s[j] != '.' and s[j] != '!' and s[j] != '?' and s[j] != '\r' and s[j] != '\n') j += 1;
        }
        if (j - j0 >= 2) {
            z.l2 = props(s[j - 2]).sb;
            z.l1 = props(s[j - 1]).sb;
            z.raw = z.l1.?;
        } else if (j - j0 == 1) {
            z.l2 = z.l1;
            z.l1 = props(s[j - 1]).sb;
            z.raw = z.l1.?;
        }
        return j;
    }

    fn step(z: *Sentences, q: Props) void {
        const c = q.sb;
        z.raw = c;
        if (c == .extend or c == .format) {
            if (z.l1) |l| if (!paraSep(l)) return;
        }
        z.l2 = z.l1;
        z.l1 = c;
        if (saTerm(c)) {
            z.phase = 1;
            z.aterm = c == .aterm;
        } else if (c == .close and z.phase == 1) {} else if (c == .sp and z.phase != 0) {
            z.phase = 2;
        } else z.phase = 0;
    }

    pub fn next(z: *Sentences) ?[]const u8 {
        const s = z.s;
        if (z.i >= s.len) return null;
        const start = z.i;
        var j = start;
        while (j < s.len) {
            if (z.fast and z.phase == 0 and j > start and !paraSep(z.raw)) j = z.skipAscii(j);
            if (j >= s.len) break;
            const d = decode(s, j);
            const q = props(d.cp);
            if (j > start and z.breaks(j, q)) break;
            z.step(q);
            j += d.len;
        }
        z.i = j;
        return s[start..j];
    }
};

// ---- Width ----

pub const Ambiguous = enum { narrow, wide };

inline fn cpWidth(p: Props, amb: Ambiguous) u2 {
    return if (p.width == 3) (if (amb == .wide) 2 else 1) else p.width;
}

/// The columns of one grapheme cluster. A spacing mark (GB9a) and a
/// consonant after a conjunct linker (GB9c) start a new column group,
/// as in terminals: the cluster is the sum of the largest width of each
/// group.
pub fn clusterWidth(c: []const u8, amb: Ambiguous) usize {
    var i: usize = 0;
    var total: usize = 0;
    var w: u2 = 0;
    var prev_emoji = false;
    var ri: u8 = 0;
    var vs16 = false;
    while (i < c.len) {
        const d = decode(c, i);
        const p = props(d.cp);
        if (d.cp == 0xFE0F and prev_emoji) vs16 = true;
        if (p.gcb == .ri) ri += 1;
        if (i > 0 and (p.gcb == .spacing_mark or p.incb == .consonant)) {
            total += w;
            w = 0;
        }
        w = @max(w, cpWidth(p, amb));
        prev_emoji = p.emoji;
        i += d.len;
    }
    total += w;
    if (vs16 or ri >= 2) return @max(total, 2);
    return total;
}

/// The columns of a text: the sum of the widths of its clusters.
pub fn width(s: []const u8, amb: Ambiguous) usize {
    var total: usize = 0;
    var i: usize = 0;
    var simd_from: usize = 0;
    while (i < s.len) {
        if (i >= simd_from and i + V <= s.len) {
            const v: @Vector(V, u8) = s[i..][0..V].*;
            if (@reduce(.And, v < @as(@Vector(V, u8), @splat(0x80)))) {
                // Each byte before the last is a cluster of its own (CR
                // LF has width 0 both ways), and a printable byte has
                // width 1.
                const pr: Mask = @bitCast((v >= @as(@Vector(V, u8), @splat(0x20))) & (v < @as(@Vector(V, u8), @splat(0x7F))));
                total += @popCount(pr & ((@as(Mask, 1) << (V - 1)) - 1));
                i += V - 1;
                continue;
            }
            simd_from = i + V;
        }
        const e = graphemeEnd(s, i);
        total += clusterWidth(s[i..e], amb);
        i = e;
    }
    return total;
}

// ---- Tests ----

const testing = std.testing;

test "props of some code points" {
    try testing.expectEqual(Gcb.cr, props('\r').gcb);
    try testing.expectEqual(Gcb.extend, props(0x301).gcb);
    try testing.expectEqual(Gcb.zwj, props(0x200D).gcb);
    try testing.expectEqual(Gcb.ri, props(0x1F1FA).gcb);
    try testing.expect(props(0x1F600).ep);
    try testing.expectEqual(Wb.aletter, props('a').wb);
    try testing.expectEqual(Sb.aterm, props('.').sb);
    try testing.expectEqual(@as(u2, 2), props(0x4E00).width);
    try testing.expectEqual(@as(u2, 0), props(0x301).width);
    try testing.expectEqual(Incb.linker, props(0x94D).incb);
}

test "grapheme counts" {
    try testing.expectEqual(@as(usize, 0), count(""));
    try testing.expectEqual(@as(usize, 3), count("a\r\nb"));
    try testing.expectEqual(@as(usize, 1), count("e\u{301}"));
    try testing.expectEqual(@as(usize, 1), count("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"));
    try testing.expectEqual(@as(usize, 2), count("\u{1F1FA}\u{1F1F8}\u{1F1EB}\u{1F1F7}"));
    // A long Latin text with marks and CR LF goes through the vector path.
    const long = "abc\r\ndef ghi jkl mno pqr stu vwx yz\u{e9}\u{e8} ABCDEFGHIJKLMNOPQRSTUVWXYZ e\u{301}\r\n";
    try testing.expectEqual(@as(usize, 66), count(long));
}

test "width" {
    try testing.expectEqual(@as(usize, 5), width("hello", .narrow));
    try testing.expectEqual(@as(usize, 4), width("\u{4E2D}\u{6587}", .narrow));
    try testing.expectEqual(@as(usize, 2), width("\u{1F468}\u{200D}\u{1F469}", .narrow));
    try testing.expectEqual(@as(usize, 2), width("\u{2764}\u{FE0F}", .narrow));
    try testing.expectEqual(@as(usize, 1), width("e\u{301}", .narrow));
    try testing.expectEqual(@as(usize, 2), width("\u{1F1FA}\u{1F1F8}", .narrow));
    try testing.expectEqual(@as(usize, 2), width("\u{B1}\u{B1}", .narrow));
    try testing.expectEqual(@as(usize, 4), width("\u{B1}\u{B1}", .wide));
}

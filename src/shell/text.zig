//! Text helpers of the line editor: UTF-8 clusters, display width, and
//! word boundaries.
//!
//! The editor moves the cursor by clusters. A cluster is one code point
//! and the code points of width zero after it: combining marks,
//! variation selectors, and the code point after a zero-width joiner. So
//! an accent or an emoji sequence moves and deletes as one character.
//! The width of a cluster is the width of its first code point: 2 for
//! the wide ranges of East Asian scripts and most emoji, 0 for a control
//! code, and 1 for the rest. The tables are short ranges of the Unicode
//! data, enough for a terminal line. A byte that is not valid UTF-8 is
//! one cluster of width 1.
//!
//! Words follow two rules. A vim `word` is a run of letters, digits, and
//! `_`, or a run of other characters that are not spaces. A `WORD` is a
//! run of characters that are not spaces. The Emacs word motions use the
//! vim `word` and skip the other characters.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

/// The code point at `i` and its length, or the byte as a code point of
/// length 1 when it is not valid UTF-8.
pub fn decode(s: []const u8, i: usize) struct { cp: u21, len: u3 } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = s[i], .len = 1 };
    if (i + n > s.len) return .{ .cp = s[i], .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = s[i], .len = 1 };
    return .{ .cp = cp, .len = n };
}

const Range = struct { lo: u21, hi: u21 };

/// Code points of width zero that join the cluster before them.
const zero_width = [_]Range{
    .{ .lo = 0x0300, .hi = 0x036F },   .{ .lo = 0x0483, .hi = 0x0489 }, .{ .lo = 0x0591, .hi = 0x05BD },
    .{ .lo = 0x0610, .hi = 0x061A },   .{ .lo = 0x064B, .hi = 0x065F }, .{ .lo = 0x0E31, .hi = 0x0E31 },
    .{ .lo = 0x0E34, .hi = 0x0E3A },   .{ .lo = 0x0E47, .hi = 0x0E4E }, .{ .lo = 0x1AB0, .hi = 0x1AFF },
    .{ .lo = 0x1DC0, .hi = 0x1DFF },   .{ .lo = 0x200B, .hi = 0x200F }, .{ .lo = 0x20D0, .hi = 0x20FF },
    .{ .lo = 0xFE00, .hi = 0xFE0F },   .{ .lo = 0xFE20, .hi = 0xFE2F }, .{ .lo = 0x1F3FB, .hi = 0x1F3FF },
    .{ .lo = 0xE0100, .hi = 0xE01EF },
};

/// Code points of width two.
const wide = [_]Range{
    .{ .lo = 0x1100, .hi = 0x115F },   .{ .lo = 0x231A, .hi = 0x231B },   .{ .lo = 0x2329, .hi = 0x232A },
    .{ .lo = 0x23E9, .hi = 0x23EC },   .{ .lo = 0x25FD, .hi = 0x25FE },   .{ .lo = 0x2614, .hi = 0x2615 },
    .{ .lo = 0x2648, .hi = 0x2653 },   .{ .lo = 0x26A1, .hi = 0x26A1 },   .{ .lo = 0x26AA, .hi = 0x26AB },
    .{ .lo = 0x26BD, .hi = 0x26BE },   .{ .lo = 0x26C4, .hi = 0x26C5 },   .{ .lo = 0x26D4, .hi = 0x26D4 },
    .{ .lo = 0x26EA, .hi = 0x26EA },   .{ .lo = 0x26F2, .hi = 0x26F5 },   .{ .lo = 0x26FA, .hi = 0x26FD },
    .{ .lo = 0x2705, .hi = 0x2705 },   .{ .lo = 0x270A, .hi = 0x270B },   .{ .lo = 0x2728, .hi = 0x2728 },
    .{ .lo = 0x274C, .hi = 0x274C },   .{ .lo = 0x2753, .hi = 0x2755 },   .{ .lo = 0x2757, .hi = 0x2757 },
    .{ .lo = 0x2795, .hi = 0x2797 },   .{ .lo = 0x27B0, .hi = 0x27B0 },   .{ .lo = 0x27BF, .hi = 0x27BF },
    .{ .lo = 0x2B1B, .hi = 0x2B1C },   .{ .lo = 0x2B50, .hi = 0x2B50 },   .{ .lo = 0x2B55, .hi = 0x2B55 },
    .{ .lo = 0x2E80, .hi = 0x303E },   .{ .lo = 0x3041, .hi = 0x33FF },   .{ .lo = 0x3400, .hi = 0x4DBF },
    .{ .lo = 0x4E00, .hi = 0x9FFF },   .{ .lo = 0xA000, .hi = 0xA4CF },   .{ .lo = 0xA960, .hi = 0xA97F },
    .{ .lo = 0xAC00, .hi = 0xD7A3 },   .{ .lo = 0xF900, .hi = 0xFAFF },   .{ .lo = 0xFE30, .hi = 0xFE4F },
    .{ .lo = 0xFF00, .hi = 0xFF60 },   .{ .lo = 0xFFE0, .hi = 0xFFE6 },   .{ .lo = 0x16FE0, .hi = 0x18CFF },
    .{ .lo = 0x1B000, .hi = 0x1B2FF }, .{ .lo = 0x1F004, .hi = 0x1F004 }, .{ .lo = 0x1F0CF, .hi = 0x1F0CF },
    .{ .lo = 0x1F18E, .hi = 0x1F18E }, .{ .lo = 0x1F191, .hi = 0x1F19A }, .{ .lo = 0x1F200, .hi = 0x1F2FF },
    .{ .lo = 0x1F300, .hi = 0x1F64F }, .{ .lo = 0x1F680, .hi = 0x1F6FF }, .{ .lo = 0x1F7E0, .hi = 0x1F7EB },
    .{ .lo = 0x1F90C, .hi = 0x1F9FF }, .{ .lo = 0x1FA70, .hi = 0x1FAFF }, .{ .lo = 0x20000, .hi = 0x2FFFD },
    .{ .lo = 0x30000, .hi = 0x3FFFD },
};

fn inRanges(cp: u21, rs: []const Range) bool {
    var lo: usize = 0;
    var hi: usize = rs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < rs[mid].lo) hi = mid else if (cp > rs[mid].hi) lo = mid + 1 else return true;
    }
    return false;
}

pub fn isZeroWidth(cp: u21) bool {
    return inRanges(cp, &zero_width);
}

/// The columns of one code point on a terminal.
pub fn cpWidth(cp: u21) u2 {
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0;
    if (isZeroWidth(cp)) return 0;
    if (inRanges(cp, &wide)) return 2;
    return 1;
}

/// The end of the cluster that starts at `i`.
pub fn nextCluster(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var d = decode(s, i);
    var j = i + d.len;
    var joined = d.cp == 0x200D;
    while (j < s.len) {
        d = decode(s, j);
        if (joined or isZeroWidth(d.cp) or d.cp == 0x200D) {
            joined = d.cp == 0x200D;
            j += d.len;
        } else break;
    }
    return j;
}

/// The start of the cluster that ends at `i`.
pub fn prevCluster(s: []const u8, i: usize) usize {
    if (i == 0) return 0;
    // Walk forward from the start of the line: lines are short, and the
    // forward rule is the only rule.
    var start: usize = 0;
    var p: usize = 0;
    while (p < i) {
        start = p;
        p = nextCluster(s, p);
    }
    return start;
}

/// The columns of the cluster at `i`.
pub fn clusterWidth(s: []const u8, i: usize) usize {
    if (i >= s.len) return 0;
    if (s[i] == '\t') return 1;
    return cpWidth(decode(s, i).cp);
}

/// The columns of `s`.
pub fn width(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        w += clusterWidth(s, i);
        i = nextCluster(s, i);
    }
    return w;
}

/// The columns of `s` with the bytes of ANSI escape sequences left out.
pub fn visibleWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1B) {
            i = skipEscape(s, i);
            continue;
        }
        w += clusterWidth(s, i);
        i = nextCluster(s, i);
    }
    return w;
}

/// The end of the escape sequence at `i`: CSI (`ESC [` ... final byte) or
/// OSC (`ESC ]` ... BEL or ST), or two bytes for another escape.
pub fn skipEscape(s: []const u8, i: usize) usize {
    if (i + 1 >= s.len) return s.len;
    var j = i + 2;
    switch (s[i + 1]) {
        '[' => {
            while (j < s.len and (s[j] < 0x40 or s[j] > 0x7E)) j += 1;
            return @min(s.len, j + 1);
        },
        ']' => {
            while (j < s.len) : (j += 1) {
                if (s[j] == 0x07) return j + 1;
                if (s[j] == 0x1B and j + 1 < s.len and s[j + 1] == '\\') return j + 2;
            }
            return s.len;
        },
        else => return j,
    }
}

// ---- Words ----

pub const Class = enum { space, word, punct };

fn classAt(s: []const u8, i: usize, big: bool) Class {
    const cp = decode(s, i).cp;
    if (cp == ' ' or cp == '\t' or cp == '\n') return .space;
    if (big) return .word;
    if (cp == '_' or (cp < 128 and std.ascii.isAlphanumeric(@intCast(cp))) or cp >= 128) return .word;
    return .punct;
}

/// `w`: the start of the next word after `i`, or the end.
pub fn nextWordStart(s: []const u8, i: usize, big: bool) usize {
    if (i >= s.len) return s.len;
    var j = i;
    const c = classAt(s, j, big);
    if (c != .space) {
        while (j < s.len and classAt(s, j, big) == c) j = nextCluster(s, j);
    }
    while (j < s.len and classAt(s, j, big) == .space) j = nextCluster(s, j);
    return j;
}

/// `e`: the last character of the word at or after `i + 1`.
pub fn wordEnd(s: []const u8, i: usize, big: bool) usize {
    if (s.len == 0) return 0;
    var j = nextCluster(s, i);
    while (j < s.len and classAt(s, j, big) == .space) j = nextCluster(s, j);
    if (j >= s.len) return prevCluster(s, s.len);
    const c = classAt(s, j, big);
    var last = j;
    while (j < s.len and classAt(s, j, big) == c) {
        last = j;
        j = nextCluster(s, j);
    }
    return last;
}

/// `b`: the start of the word before `i`.
pub fn prevWordStart(s: []const u8, i: usize, big: bool) usize {
    var j = i;
    while (j > 0) {
        const p = prevCluster(s, j);
        if (classAt(s, p, big) != .space) break;
        j = p;
    }
    if (j == 0) return 0;
    const c = classAt(s, prevCluster(s, j), big);
    while (j > 0) {
        const p = prevCluster(s, j);
        if (classAt(s, p, big) != c) break;
        j = p;
    }
    return j;
}

/// Emacs `Alt-F`: the end of the next run of word characters.
pub fn emacsForward(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and classAt(s, j, false) != .word) j = nextCluster(s, j);
    while (j < s.len and classAt(s, j, false) == .word) j = nextCluster(s, j);
    return j;
}

/// Emacs `Alt-B`: the start of the run of word characters before `i`.
pub fn emacsBackward(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and classAt(s, prevCluster(s, j), false) != .word) j = prevCluster(s, j);
    while (j > 0 and classAt(s, prevCluster(s, j), false) == .word) j = prevCluster(s, j);
    return j;
}

/// The start of the line of the buffer that holds `i`.
pub fn lineStart(s: []const u8, i: usize) usize {
    var j = @min(i, s.len);
    while (j > 0 and s[j - 1] != '\n') j -= 1;
    return j;
}

/// The end of the line of the buffer that holds `i`: its newline or the
/// end of the buffer.
pub fn lineEnd(s: []const u8, i: usize) usize {
    var j = @min(i, s.len);
    while (j < s.len and s[j] != '\n') j += 1;
    return j;
}

/// The first character of the line that is not a space (`^`).
pub fn firstNonBlank(s: []const u8, i: usize) usize {
    var j = lineStart(s, i);
    const e = lineEnd(s, i);
    while (j < e and (s[j] == ' ' or s[j] == '\t')) j += 1;
    return j;
}

/// The column of `i` in its line, in clusters.
pub fn columnOf(s: []const u8, i: usize) usize {
    var j = lineStart(s, i);
    var n: usize = 0;
    while (j < i) {
        j = nextCluster(s, j);
        n += 1;
    }
    return n;
}

/// The byte offset of cluster column `col` of the line that starts at
/// `start`, or its end.
pub fn atColumn(s: []const u8, start: usize, col: usize) usize {
    var j = start;
    const e = lineEnd(s, start);
    var n: usize = 0;
    while (j < e and n < col) {
        j = nextCluster(s, j);
        n += 1;
    }
    return j;
}

test "clusters and widths" {
    const t = std.testing;
    const s = "e\u{301}x\u{4E2D}\u{1F468}\u{200D}\u{1F469}";
    try t.expectEqual(@as(usize, 3), nextCluster(s, 0));
    try t.expectEqual(@as(usize, 4), nextCluster(s, 3));
    try t.expectEqual(@as(usize, 7), nextCluster(s, 4));
    try t.expectEqual(s.len, nextCluster(s, 7));
    try t.expectEqual(@as(usize, 7), prevCluster(s, s.len));
    try t.expectEqual(@as(usize, 1 + 1 + 2 + 2), width(s));
    try t.expectEqual(@as(usize, 3), visibleWidth("\x1b[31mabc\x1b[0m"));
}

test "words" {
    const t = std.testing;
    const s = "set foo(bar) [list a.b]";
    try t.expectEqual(@as(usize, 4), nextWordStart(s, 0, false));
    try t.expectEqual(@as(usize, 7), nextWordStart(s, 4, false));
    try t.expectEqual(@as(usize, 13), nextWordStart(s, 4, true));
    try t.expectEqual(@as(usize, 6), wordEnd(s, 4, false));
    try t.expectEqual(@as(usize, 11), wordEnd(s, 4, true));
    try t.expectEqual(@as(usize, 8), prevWordStart(s, 11, false));
    try t.expectEqual(@as(usize, 4), prevWordStart(s, 13, true));
    try t.expectEqual(@as(usize, 7), emacsForward(s, 3));
    try t.expectEqual(@as(usize, 21), emacsBackward(s, 22));
}

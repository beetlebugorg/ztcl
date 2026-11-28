//! Unicode character classes and simple case maps.
//!
//! The case maps and the classes upper, lower, and title come from the
//! tables of `ucd_case.zig` (Unicode 17.0.0, made by tools/ucd-case.tcl),
//! with the rule of Tcl: a map to a longer UTF-8 form is left out. The
//! other classes cover ASCII, Latin-1, the space characters, and the
//! common punctuation blocks. A character outside those ranges counts as
//! a letter when it is in a block of letters.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub fn isSpace(c: u21) bool {
    return switch (c) {
        9...13, ' ', 0x85, 0xA0, 0x1680, 0x180E, 0x2000...0x200B, 0x2028, 0x2029, 0x202F, 0x205F, 0x2060, 0x3000, 0xFEFF => true,
        else => false,
    };
}

pub fn isPunct(c: u21) bool {
    if (c < 128) return std.ascii.isPunctuation(@intCast(c));
    return switch (c) {
        0xA1, 0xA7, 0xAB, 0xB6, 0xB7, 0xBB, 0xBF, 0x37E, 0x387, 0x55A...0x55F, 0x589, 0x58A, 0x1361...0x1368, 0x2010...0x2027, 0x2030...0x205E, 0x3001...0x3003, 0x3008...0x3011 => true,
        else => false,
    };
}

pub fn isUpper(c: u21) bool {
    if (c < 128) return c >= 'A' and c <= 'Z';
    return caseOf(c).kind == .upper;
}

pub fn isLower(c: u21) bool {
    if (c < 128) return c >= 'a' and c <= 'z';
    return caseOf(c).kind == .lower;
}

pub fn isDigit(c: u21) bool {
    return switch (c) {
        '0'...'9', 0x660...0x669, 0x6F0...0x6F9, 0x966...0x96F, 0xFF10...0xFF19 => true,
        else => false,
    };
}

pub fn isAlpha(c: u21) bool {
    if (c < 128) return std.ascii.isAlphabetic(@intCast(c));
    if (c < 0xC0) return c == 0xAA or c == 0xB5 or c == 0xBA;
    if (c == 0xD7 or c == 0xF7) return false;
    if (isSpace(c) or isPunct(c) or isDigit(c)) return false;
    return switch (c) {
        0x300...0x36F, 0x2000...0x2BFF, 0x3000...0x303F, 0xD800...0xF8FF, 0xFE00...0xFE6F, 0xFFF0...0xFFFF => false,
        else => true,
    };
}

pub fn isWordChar(c: u21) bool {
    return isAlpha(c) or isDigit(c) or c == '_' or (c >= 0x203F and c <= 0x2040);
}

pub fn isControl(c: u21) bool {
    return c < 32 or (c >= 127 and c < 160);
}

pub fn isGraph(c: u21) bool {
    return !isControl(c) and !isSpace(c);
}

pub fn isPrint(c: u21) bool {
    return !isControl(c) and (c == ' ' or !isSpace(c) or c >= 128);
}

const case_table = @import("ucd_case.zig");

/// The entry of `c` in the two-stage tables of `ucd_case.zig`.
fn caseOf(c: u21) case_table.Case {
    if (c >= case_table.end) return case_table.cases[0];
    const block: usize = case_table.blocks[c >> 7];
    return case_table.cases[case_table.items[(block << 7) | (c & 127)]];
}

fn moved(c: u21, d: i32) u21 {
    return @intCast(@as(i32, c) + d);
}

pub fn toLower(c: u21) u21 {
    if (c < 128) return if (c >= 'A' and c <= 'Z') c + 32 else c;
    return moved(c, caseOf(c).lower);
}

pub fn toUpper(c: u21) u21 {
    if (c < 128) return if (c >= 'a' and c <= 'z') c - 32 else c;
    return moved(c, caseOf(c).upper);
}

pub fn toTitle(c: u21) u21 {
    if (c < 128) return if (c >= 'a' and c <= 'z') c - 32 else c;
    return moved(c, caseOf(c).title);
}

/// The case of a letter after the first one of `string totitle`: the
/// lowercase, except for the Georgian Mtavruli letters (U+1C90 to
/// U+1CBF), which keep their case there, as in Tcl.
pub fn toLowerAfterTitle(c: u21) u21 {
    if (c >= 0x1C90 and c <= 0x1CBF) return c;
    return toLower(c);
}

/// Decodes the character at `s[i]`. A surrogate half in the three-byte
/// form is one character. An invalid byte is one character.
pub fn next(s: []const u8, i: usize) struct { cp: u21, len: usize } {
    const c = s[i];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    const n = std.unicode.utf8ByteSequenceLength(c) catch return .{ .cp = c, .len = 1 };
    if (i + n > s.len) return .{ .cp = c, .len = 1 };
    const cp = std.unicode.wtf8Decode(s[i .. i + n]) catch return .{ .cp = c, .len = 1 };
    return .{ .cp = cp, .len = n };
}

pub fn appendCp(a: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) std.mem.Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.wtf8Encode(cp, &buf) catch {
        try out.append(a, @truncate(cp));
        return;
    };
    try out.appendSlice(a, buf[0..n]);
}

test "the case maps of a few letters, as in Tcl" {
    const t = std.testing;
    try t.expectEqual(@as(u21, 'i'), toLower(0x130));
    try t.expectEqual(@as(u21, 0x2D00), toLower(0x10A0));
    try t.expectEqual(@as(u21, 'k'), toLower(0x212A));
    try t.expectEqual(@as(u21, 0x3C3), toLower(0x3A3));
    try t.expectEqual(@as(u21, 0x3A3), toUpper(0x3C2));
    try t.expectEqual(@as(u21, 0x1C5), toTitle(0x1C6));
    try t.expectEqual(@as(u21, 0x1C4), toUpper(0x1C6));
    // A map to a longer UTF-8 form is left out: U+023A keeps its case,
    // and its lowercase U+2C65 maps back up.
    try t.expectEqual(@as(u21, 0x23A), toLower(0x23A));
    try t.expectEqual(@as(u21, 0x23A), toUpper(0x2C65));
    try t.expect(isUpper(0x10A0) and !isLower(0x10A0));
    try t.expect(isLower(0xDF) and !isUpper(0xDF));
    try t.expect(!isUpper(0x1C5) and !isLower(0x1C5));
    // `string totitle` keeps a Mtavruli letter after the first.
    try t.expectEqual(@as(u21, 0x1C90), toLowerAfterTitle(0x1C90));
    try t.expectEqual(@as(u21, 0x10D0), toLower(0x1C90));
    try t.expectEqual(@as(u21, 'b'), toLowerAfterTitle('B'));
}

test "the case maps and classes of each code point are those of tclsh 9.0.4" {
    // One line for each code point from 0 to 0x1FFFF with no surrogate:
    // the code point, its lowercase, its uppercase, its titlecase, and
    // 1 or 0 for `string is upper` and `string is lower`, in decimal.
    // tools/case-check.tcl writes the same lines in tclsh 9.0.4 (Windows
    // x64), and the hash is the SHA-256 of that output, with LF line ends.
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64]u8 = undefined;
    var c: u21 = 0;
    while (c < 0x20000) : (c += 1) {
        if (c >= 0xD800 and c <= 0xDFFF) continue;
        const line = try std.fmt.bufPrint(&buf, "{d} {d} {d} {d} {d} {d}\n", .{ c, toLower(c), toUpper(c), toTitle(c), @intFromBool(isUpper(c)), @intFromBool(isLower(c)) });
        h.update(line);
    }
    var got: [32]u8 = undefined;
    h.final(&got);
    const tclsh_hash = "1d7429e459c440fde94b950811e0cc1215b4a559f376a56451fee283ca1c0233";
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{&got});
    try std.testing.expectEqualStrings(tclsh_hash, &hex);
}

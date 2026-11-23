//! A small model of Unicode character classes and simple case maps.
//!
//! It covers ASCII, Latin-1, Latin Extended-A, Greek, Cyrillic, the
//! space characters, and the common punctuation blocks. A character
//! outside those ranges counts as a letter when it is in a block of
//! letters, and it has no case. This is an approximation of the full
//! tables of Tcl 8.6.
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
    return toLower(c) != c and c != 0x1C5 and c != 0x1C8 and c != 0x1CB and c != 0x1F2;
}

pub fn isLower(c: u21) bool {
    if (c < 128) return c >= 'a' and c <= 'z';
    if (c == 0xDF or c == 0xFF or c == 0xAA or c == 0xBA or c == 0xB5) return true;
    return toUpper(c) != c and c != 0x1C5 and c != 0x1C8 and c != 0x1CB and c != 0x1F2;
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

pub fn toLower(c: u21) u21 {
    if (c < 128) return if (c >= 'A' and c <= 'Z') c + 32 else c;
    return switch (c) {
        0xC0...0xD6, 0xD8...0xDE => c + 32,
        0x100...0x12F, 0x132...0x137, 0x14A...0x177, 0x1E00...0x1E95, 0x1EA0...0x1EFF => if (c % 2 == 0) c + 1 else c,
        0x139...0x148, 0x179...0x17E => if (c % 2 == 1) c + 1 else c,
        0x178 => 0xFF,
        0x1C4, 0x1C7, 0x1CA, 0x1F1 => c + 2,
        0x1C5, 0x1C8, 0x1CB, 0x1F2 => c + 1,
        0x386 => 0x3AC,
        0x388...0x38A => c + 37,
        0x38C => 0x3CC,
        0x38E, 0x38F => c + 63,
        0x391...0x3A1, 0x3A3...0x3AB => c + 32,
        0x400...0x40F => c + 80,
        0x410...0x42F => c + 32,
        0x460...0x481, 0x48A...0x4BF, 0x4D0...0x52F => if (c % 2 == 0) c + 1 else c,
        0x531...0x556 => c + 48,
        0xFF21...0xFF3A => c + 32,
        else => c,
    };
}

pub fn toUpper(c: u21) u21 {
    if (c < 128) return if (c >= 'a' and c <= 'z') c - 32 else c;
    return switch (c) {
        0xB5 => 0x39C,
        0xE0...0xF6, 0xF8...0xFE => c - 32,
        0xFF => 0x178,
        0x100...0x12F, 0x132...0x137, 0x14A...0x177, 0x1E00...0x1E95, 0x1EA0...0x1EFF => if (c % 2 == 1) c - 1 else c,
        0x139...0x148, 0x179...0x17E => if (c % 2 == 0) c - 1 else c,
        0x1C6, 0x1C9, 0x1CC, 0x1F3 => c - 2,
        0x1C5, 0x1C8, 0x1CB, 0x1F2 => c - 1,
        0x3AC => 0x386,
        0x3AD...0x3AF => c - 37,
        0x3CC => 0x38C,
        0x3CD, 0x3CE => c - 63,
        0x3B1...0x3C1, 0x3C3...0x3CB => c - 32,
        0x3C2 => 0x3A3,
        0x450...0x45F => c - 80,
        0x430...0x44F => c - 32,
        0x460...0x481, 0x48A...0x4BF, 0x4D0...0x52F => if (c % 2 == 1) c - 1 else c,
        0x561...0x586 => c - 48,
        0xFF41...0xFF5A => c - 32,
        else => c,
    };
}

pub fn toTitle(c: u21) u21 {
    return switch (c) {
        0x1C4, 0x1C5, 0x1C6 => 0x1C5,
        0x1C7, 0x1C8, 0x1C9 => 0x1C8,
        0x1CA, 0x1CB, 0x1CC => 0x1CB,
        0x1F1, 0x1F2, 0x1F3 => 0x1F2,
        else => toUpper(c),
    };
}

/// Decodes the character at `s[i]`. An invalid byte is one character.
pub fn next(s: []const u8, i: usize) struct { cp: u21, len: usize } {
    const c = s[i];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    const n = std.unicode.utf8ByteSequenceLength(c) catch return .{ .cp = c, .len = 1 };
    if (i + n > s.len) return .{ .cp = c, .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = c, .len = 1 };
    return .{ .cp = cp, .len = n };
}

pub fn appendCp(a: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) std.mem.Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.append(a, @truncate(cp));
        return;
    };
    try out.appendSlice(a, buf[0..n]);
}

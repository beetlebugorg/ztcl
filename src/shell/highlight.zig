//! Syntax colors for the line editor, as the user types.
//!
//! `styles` gives one style for each byte of a command. The scan follows
//! the rules of Tcl that a reader sees: a command starts at the start of
//! the text, after a newline or a `;`, and after a `[`. Its first word
//! is the command name, and the shell says if a command of that name
//! exists, so a name that does not exist shows in red before Enter. A
//! `#` at the start of a command starts a comment to the end of the
//! line. `"` starts a string, `$` a variable, and a word of digits is a
//! number. Braces and brackets have their own color, and a backslash
//! keeps the next character as text. Inside braces, the text is a body
//! or a list that the shell does not read, so it keeps the plain style,
//! but its variables and brackets still show.
//!
//! `matchAt` finds the bracket that matches the one at or before the
//! cursor, for the match highlight.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Style = enum(u8) { plain, command, unknown, string, brace, variable, comment, number, match };

pub const Lookup = struct {
    ctx: ?*anyopaque = null,
    /// True when a command of this name exists.
    exists: *const fn (ctx: ?*anyopaque, name: []const u8) bool = always,

    fn always(_: ?*anyopaque, _: []const u8) bool {
        return true;
    }
};

fn isVarChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == ':';
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Fills `out` (one style for each byte of `s`).
pub fn styles(s: []const u8, out: []Style, look: Lookup) void {
    @memset(out, .plain);
    var i: usize = 0;
    var cmd_start = true;
    var depth: usize = 0; // braces
    var quote = false;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len) {
            out[i] = if (quote) .string else .plain;
            out[i + 1] = out[i];
            i += 2;
            continue;
        }
        if (depth == 0 and !quote) {
            if (c == '\n' or c == ';') {
                cmd_start = true;
                i += 1;
                continue;
            }
            if (isSpace(c)) {
                i += 1;
                continue;
            }
            if (cmd_start) {
                cmd_start = false;
                if (c == '#') {
                    while (i < s.len and s[i] != '\n') : (i += 1) out[i] = .comment;
                    continue;
                }
                if (c != '{' and c != '"' and c != '[' and c != '$') {
                    // The command name.
                    var j = i;
                    while (j < s.len and !isSpace(s[j]) and s[j] != '\n' and s[j] != ';' and s[j] != ']' and s[j] != '[') j += 1;
                    const st: Style = if (look.exists(look.ctx, s[i..j])) .command else .unknown;
                    @memset(out[i..j], st);
                    i = j;
                    continue;
                }
            }
            // A number word.
            if (std.ascii.isDigit(c) or (c == '-' and i + 1 < s.len and std.ascii.isDigit(s[i + 1]))) {
                var j = i + 1;
                while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '.')) j += 1;
                if (j == s.len or isSpace(s[j]) or s[j] == '\n' or s[j] == ';' or s[j] == ']') {
                    @memset(out[i..j], .number);
                    i = j;
                    continue;
                }
            }
        }
        switch (c) {
            '"' => if (depth == 0) {
                out[i] = .string;
                quote = !quote;
                i += 1;
                continue;
            },
            '{' => if (!quote) {
                depth += 1;
                out[i] = .brace;
                i += 1;
                continue;
            },
            '}' => if (!quote and depth > 0) {
                depth -= 1;
                out[i] = .brace;
                i += 1;
                continue;
            },
            '[' => {
                out[i] = .brace;
                if (depth == 0) cmd_start = true;
                i += 1;
                continue;
            },
            ']' => {
                out[i] = .brace;
                i += 1;
                continue;
            },
            '$' => {
                var j = i + 1;
                if (j < s.len and s[j] == '{') {
                    while (j < s.len and s[j] != '}') j += 1;
                    j = @min(j + 1, s.len);
                } else {
                    while (j < s.len and isVarChar(s[j])) j += 1;
                    // An array element.
                    if (j < s.len and s[j] == '(') {
                        while (j < s.len and s[j] != ')') j += 1;
                        j = @min(j + 1, s.len);
                    }
                }
                if (j > i + 1) {
                    @memset(out[i..j], .variable);
                    i = j;
                    continue;
                }
            },
            else => {},
        }
        out[i] = if (quote) .string else .plain;
        i += 1;
    }
}

/// The offset of the bracket that matches the bracket at `cur`, or at
/// `cur - 1`, or null.
pub fn matchAt(s: []const u8, cur: usize) ?usize {
    for ([_]usize{ cur, cur -% 1 }) |p| {
        if (p >= s.len) continue;
        const c = s[p];
        const pair: ?struct { open: u8, close: u8, fwd: bool } = switch (c) {
            '{' => .{ .open = '{', .close = '}', .fwd = true },
            '[' => .{ .open = '[', .close = ']', .fwd = true },
            '(' => .{ .open = '(', .close = ')', .fwd = true },
            '}' => .{ .open = '{', .close = '}', .fwd = false },
            ']' => .{ .open = '[', .close = ']', .fwd = false },
            ')' => .{ .open = '(', .close = ')', .fwd = false },
            else => null,
        };
        const pr = pair orelse continue;
        var depth: usize = 0;
        if (pr.fwd) {
            var j = p + 1;
            while (j < s.len) : (j += 1) {
                if (s[j] == pr.open) depth += 1;
                if (s[j] == pr.close) {
                    if (depth == 0) return j;
                    depth -= 1;
                }
            }
        } else {
            var j = p;
            while (j > 0) {
                j -= 1;
                if (s[j] == pr.close) depth += 1;
                if (s[j] == pr.open) {
                    if (depth == 0) return j;
                    depth -= 1;
                }
            }
        }
        return null;
    }
    return null;
}

test "highlight: the styles of a command" {
    const t = std.testing;
    const s = "set x [llength $l] ;# c\nnope \"a $b\" {x $y} 42";
    var out: [s.len]Style = undefined;
    const look: Lookup = .{ .exists = struct {
        fn f(_: ?*anyopaque, n: []const u8) bool {
            return !std.mem.eql(u8, n, "nope");
        }
    }.f };
    styles(s, &out, look);
    try t.expectEqual(Style.command, out[0]);
    try t.expectEqual(Style.plain, out[4]);
    try t.expectEqual(Style.brace, out[6]);
    try t.expectEqual(Style.command, out[7]);
    try t.expectEqual(Style.variable, out[15]);
    try t.expectEqual(Style.comment, out[20]);
    const n = std.mem.indexOf(u8, s, "nope").?;
    try t.expectEqual(Style.unknown, out[n]);
    try t.expectEqual(Style.string, out[n + 5]);
    try t.expectEqual(Style.variable, out[std.mem.indexOf(u8, s, "$b").?]);
    try t.expectEqual(Style.brace, out[std.mem.indexOf(u8, s, "{x").?]);
    try t.expectEqual(Style.variable, out[std.mem.indexOf(u8, s, "$y").?]);
    try t.expectEqual(Style.number, out[s.len - 1]);
    try t.expectEqual(@as(?usize, 17), matchAt(s, 6));
    try t.expectEqual(@as(?usize, 6), matchAt(s, 18));
}

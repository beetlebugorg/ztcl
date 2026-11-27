//! The syntax error of an expression, as Tcl 8.6.16 reports it.
//!
//! `expr.zig` parses an expression by recursive descent. When that parse
//! fails, `diagnose` reads the text again the way the operator
//! precedence parser of Tcl reads it, so the message, the `_@_` mark,
//! and the -errorcode `TCL PARSE EXPR code` are the ones of Tcl.
//!
//! The pass splits the text into lexemes. A lexeme is a leaf (a number,
//! a boolean word, a quoted or braced word, a variable, or a command
//! substitution), a unary operator (a sign, `!`, `~`, a function name,
//! or an open paren), or a binary operator (the others, a close paren,
//! a comma, and the end of the text). A stack of the operators that
//! wait for their right operand gives the context of each error: a
//! binary operator after an operator is a missing operand, a leaf after
//! an operand is a missing operator, and the reduction of the stack at
//! a binary operator finds an open paren with no close paren, a `?`
//! with no `:`, and a `:` or a comma in the wrong place.
//!
//! Only the error path runs this pass. When it finds no error, as for
//! the arguments of a math function, `diagnose` returns null and the
//! message of `expr.zig` stays.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const Interp = interp.Interp;

/// Tcl shows at most this many bytes of each part of the expression.
const limit = 25;

const Lex = enum {
    // Leaves.
    leaf,
    // Unary operators.
    start,
    uplus,
    uminus,
    not,
    bitnot,
    function,
    open_paren,
    // Binary operators.
    plus,
    minus,
    mult,
    divide,
    mod,
    expon,
    less,
    greater,
    leq,
    geq,
    lshift,
    rshift,
    equal,
    neq,
    streq,
    strneq,
    in_list,
    not_in_list,
    bit_and,
    bit_xor,
    bit_or,
    and_,
    or_,
    question,
    colon,
    comma,
    close_paren,
    end,
    // Errors of the lexer, and the other lexemes.
    invalid,
    incomplete,
    bareword,
    quoted,
    braced,
    variable,
    script,
};

const Prec = enum(u8) { end, start, close_paren, open_paren, comma, conditional, or_, and_, bit_or, bit_xor, bit_and, equal, compare, shift, add, mult, expon, unary };

fn prec(l: Lex) Prec {
    return switch (l) {
        .start => .start,
        .uplus, .uminus, .not, .bitnot, .function => .unary,
        .open_paren => .open_paren,
        .plus, .minus => .add,
        .mult, .divide, .mod => .mult,
        .expon => .expon,
        .less, .greater, .leq, .geq => .compare,
        .lshift, .rshift => .shift,
        .equal, .neq, .streq, .strneq, .in_list, .not_in_list => .equal,
        .bit_and => .bit_and,
        .bit_xor => .bit_xor,
        .bit_or => .bit_or,
        .and_ => .and_,
        .or_ => .or_,
        .question, .colon => .conditional,
        .comma => .comma,
        .close_paren => .close_paren,
        else => .end,
    };
}

fn isUnary(l: Lex) bool {
    return switch (l) {
        .start, .uplus, .uminus, .not, .bitnot, .function, .open_paren => true,
        else => false,
    };
}

pub const Diag = struct {
    msg: []const u8,
    /// The -errorcode words after `TCL PARSE EXPR`. Tcl gives none for
    /// the error of a word that has its close delimiter.
    code: ?[]const u8,
    /// The byte where the error is, and the bytes of the lexeme there.
    at: usize,
    scanned: usize,
    mark: bool,
    /// The text after the expression, for a bareword.
    post: ?[]const u8 = null,
};

/// A letter, a digit, or `_` (ASCII only), as TclIsBareword.
fn bare(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The length of the number at the start of `s`, or 0. It accepts the
/// forms of Tcl 8.6: decimal and octal integers, 0x, 0o, 0b, decimal
/// fractions with an exponent, Inf, Infinity, and NaN.
fn numberLen(s: []const u8) usize {
    const lower = struct {
        fn starts(t: []const u8, w: []const u8) bool {
            return t.len >= w.len and std.ascii.eqlIgnoreCase(t[0..w.len], w);
        }
    };
    if (lower.starts(s, "infinity")) return 8;
    if (lower.starts(s, "inf")) return 3;
    if (lower.starts(s, "nan")) return 3;
    if (s.len == 0) return 0;
    if (s[0] == '0' and s.len > 1) {
        const radix: ?u8 = switch (s[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (radix) |r| {
            var i: usize = 2;
            while (i < s.len and (std.fmt.charToDigit(s[i], r) catch null) != null) i += 1;
            return if (i > 2) i else 1;
        }
    }
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    var digits = i;
    if (i < s.len and s[i] == '.') {
        var j = i + 1;
        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
        digits += j - i - 1;
        if (digits == 0) return 0;
        i = j;
    }
    if (digits == 0) return 0;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        if (j < s.len and std.ascii.isDigit(s[j])) {
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            i = j;
        }
    }
    // An integer with a leading 0 is octal in Tcl 8.6.
    if (s[0] == '0' and i > 1 and std.mem.indexOfAny(u8, s[0..i], ".eE") == null) {
        var k: usize = 1;
        while (k < i and s[k] < '8') k += 1;
        return k;
    }
    return i;
}

fn utf8Len(c: u8) usize {
    return std.unicode.utf8ByteSequenceLength(c) catch 1;
}

/// The lexeme at the start of `s` and its length in bytes.
fn lexeme(s: []const u8) struct { Lex, usize } {
    if (s.len == 0) return .{ .end, 0 };
    const c = s[0];
    const two = s.len > 1;
    const after_word = s.len == 2 or (s.len > 2 and (s[2] & 0x80 != 0 or !std.ascii.isAlphabetic(s[2])));
    switch (c) {
        '"' => return .{ .quoted, 1 },
        '$' => return .{ .variable, 1 },
        '%' => return .{ .mod, 1 },
        '(' => return .{ .open_paren, 1 },
        ')' => return .{ .close_paren, 1 },
        '+' => return .{ .plus, 1 },
        ',' => return .{ .comma, 1 },
        '-' => return .{ .minus, 1 },
        '/' => return .{ .divide, 1 },
        ':' => return .{ .colon, 1 },
        '?' => return .{ .question, 1 },
        '[' => return .{ .script, 1 },
        '^' => return .{ .bit_xor, 1 },
        '{' => return .{ .braced, 1 },
        '~' => return .{ .bitnot, 1 },
        '*' => return if (two and s[1] == '*') .{ .expon, 2 } else .{ .mult, 1 },
        '=' => return if (two and s[1] == '=') .{ .equal, 2 } else .{ .incomplete, 1 },
        '!' => return if (two and s[1] == '=') .{ .neq, 2 } else .{ .not, 1 },
        '&' => return if (two and s[1] == '&') .{ .and_, 2 } else .{ .bit_and, 1 },
        '|' => return if (two and s[1] == '|') .{ .or_, 2 } else .{ .bit_or, 1 },
        '<' => return if (two and s[1] == '<') .{ .lshift, 2 } else if (two and s[1] == '=') .{ .leq, 2 } else .{ .less, 1 },
        '>' => return if (two and s[1] == '>') .{ .rshift, 2 } else if (two and s[1] == '=') .{ .geq, 2 } else .{ .greater, 1 },
        'i' => if (two and s[1] == 'n' and after_word) return .{ .in_list, 2 },
        // The string order operators of Tcl 9.1. `value.octal_zero` is
        // false while an interpreter that follows 9.1 runs.
        'l', 'g' => if (two and after_word and !@import("value.zig").octal_zero) {
            if (s[1] == 't') return .{ if (s[0] == 'l') .less else .greater, 2 };
            if (s[1] == 'e') return .{ if (s[0] == 'l') .leq else .geq, 2 };
        },
        'e' => if (two and s[1] == 'q' and after_word) return .{ .streq, 2 },
        'n' => if (two and after_word) {
            if (s[1] == 'e') return .{ .strneq, 2 };
            if (s[1] == 'i') return .{ .not_in_list, 2 };
        },
        else => {},
    }
    const n = numberLen(s);
    if (n > 0) {
        // A number followed by a bareword character is a bareword, unless
        // it has a character outside the barewords or a binary operator
        // follows it.
        if (n < s.len and !bare(s[n])) return .{ .leaf, n };
        for (s[0..n]) |b| if (!bare(b)) return .{ .leaf, n };
        const next, _ = lexeme(s[n..]);
        if (@backingInt(next) >= @backingInt(Lex.plus) and @backingInt(next) <= @backingInt(Lex.end)) return .{ .leaf, n };
    }
    if (!bare(c) or c == '_') return .{ .invalid, @min(utf8Len(c), s.len) };
    var i: usize = 0;
    while (i < s.len and bare(s[i])) i += 1;
    return .{ .bareword, i };
}

/// The bytes of white space at the start of `s`: the space characters
/// and backslash-newline sequences with the white space after them.
fn white(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == ' ' or (c >= 9 and c <= 13)) {
            i += 1;
        } else if (c == '\\' and i + 1 < s.len and s[i + 1] == '\n') {
            i += 2;
            while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        } else break;
    }
    return i;
}

const Node = struct { lex: Lex, prev: usize };
/// The values of `complete` and `last` that are not operator nodes.
const operand: isize = -1;

/// Reads `text` as Tcl does and returns its first syntax error, or null.
pub fn diagnose(it: *Interp, text: []const u8, isBool: *const fn ([]const u8) bool) !?Diag {
    const a = it.alloc();
    var nodes: std.ArrayList(Node) = .empty;
    try nodes.append(a, .{ .lex = .start, .prev = 0 });
    var incomplete: usize = 0;
    var last: isize = 0;
    var complete: isize = operand;
    var pos: usize = 0;
    while (true) {
        pos += white(text[pos..]);
        var lex, var scanned = lexeme(text[pos..]);
        const D = struct {
            fn at(msg: []const u8, code: []const u8, p: usize) Diag {
                return .{ .msg = msg, .code = code, .at = p, .scanned = 0, .mark = true };
            }
            fn here(msg: []const u8, code: []const u8, p: usize, n: usize) Diag {
                return .{ .msg = msg, .code = code, .at = p, .scanned = n, .mark = false };
            }
        };
        switch (lex) {
            .invalid => return D.here(try std.fmt.allocPrint(a, "invalid character \"{s}\"", .{text[pos .. pos + scanned]}), "BADCHAR", pos, scanned),
            .incomplete => return D.here(try std.fmt.allocPrint(a, "incomplete operator \"{s}\"", .{text[pos .. pos + scanned]}), "PARTOP", pos, scanned),
            .bareword => {
                const rest = pos + scanned;
                const w = rest + white(text[rest..]);
                if (w < text.len and text[w] == '(') {
                    lex = .function;
                } else if (isBool(text[pos..rest])) {
                    lex = .leaf;
                } else return try bareword(a, text, pos, scanned);
            },
            .plus => if (last >= 0) {
                lex = .uplus;
            },
            .minus => if (last >= 0) {
                lex = .uminus;
            },
            else => {},
        }
        switch (lex) {
            .leaf, .quoted, .braced, .variable, .script => {
                if (last < 0) return D.at("missing operator at _@_", "MISSING", pos);
                if (lex != .leaf) {
                    var p: interp.Parser = .{ .a = a, .src = text, .pos = pos };
                    const ok = leafEnd(&p, lex) catch |e| {
                        if (e == error.OutOfMemory) return e;
                        // An open delimiter with no close is incomplete.
                        const open = !std.mem.startsWith(u8, p.message, "extra characters");
                        return .{ .msg = p.message, .code = if (open) "UNBALANCED" else null, .at = p.term, .scanned = @intFromBool(open), .mark = false };
                    };
                    if (!ok) return D.here("invalid character \"$\"", "BADCHAR", pos, 1);
                    scanned = p.pos - pos;
                }
                complete = operand;
                last = operand;
            },
            .start, .uplus, .uminus, .not, .bitnot, .function, .open_paren => {
                if (last < 0) return D.at("missing operator at _@_", "MISSING", pos);
                try nodes.append(a, .{ .lex = lex, .prev = incomplete });
                incomplete = nodes.items.len - 1;
                last = @intCast(incomplete);
            },
            else => {
                const p = prec(lex);
                const items = nodes.items;
                if (last >= 0) {
                    const top = items[items.len - 1].lex;
                    const below: ?Lex = if (items.len >= 2) items[items.len - 2].lex else null;
                    if (lex == .close_paren and top == .open_paren) {
                        if (below == .function) {
                            // A function with no arguments: the close
                            // paren goes again, after an empty operand.
                            complete = operand;
                            last = operand;
                            continue;
                        }
                        return D.at("empty subexpression at _@_", "EMPTY", pos);
                    }
                    if (@backingInt(prec(top)) > @backingInt(p)) {
                        if (top == .open_paren) return D.here("unbalanced open paren", "UNBALANCED", pos, scanned);
                        if (top == .comma) return D.at("missing function argument at _@_", "MISSING", pos);
                        if (top == .start) return D.here("empty expression", "EMPTY", pos, scanned);
                    } else if (lex == .close_paren) {
                        return D.here("unbalanced close paren", "UNBALANCED", pos, scanned);
                    } else if (lex == .comma and top == .open_paren and below == .function) {
                        return D.at("missing function argument at _@_", "UNBALANCED", pos);
                    }
                    return D.at("missing operand at _@_", "MISSING", pos);
                }
                var inc = incomplete;
                while (true) {
                    const n = nodes.items[inc];
                    const np = prec(n.lex);
                    const colon_done = complete >= 0 and nodes.items[@intCast(complete)].lex == .colon;
                    if (@backingInt(np) < @backingInt(p)) break;
                    if (np == p) {
                        if (lex == .expon) break;
                        if (n.lex == .question and !colon_done) break;
                        if (n.lex == .colon and lex == .question) break;
                    }
                    if (n.lex == .open_paren and lex != .close_paren) return D.here("unbalanced open paren", "UNBALANCED", pos, scanned);
                    if (n.lex == .question and !colon_done) return D.at("missing operator \":\" at _@_", "MISSING", pos);
                    if (colon_done and n.lex != .question) return D.here("unexpected operator \":\" without preceding \"?\"", "SURPRISE", pos, scanned);
                    if (n.lex == .start) return null;
                    complete = @intCast(inc);
                    incomplete = n.prev;
                    if (n.lex == .open_paren) break;
                    inc = incomplete;
                }
                const stop = nodes.items[inc].lex;
                if (lex == .close_paren and stop != .open_paren) return D.here("unbalanced close paren", "UNBALANCED", pos, scanned);
                if (lex == .comma and (stop != .open_paren or inc == 0 or nodes.items[inc - 1].lex != .function)) {
                    return D.here("unexpected \",\" outside function argument list", "SURPRISE", pos, scanned);
                }
                if (complete >= 0 and nodes.items[@intCast(complete)].lex == .colon) {
                    return D.here("unexpected operator \":\" without preceding \"?\"", "SURPRISE", pos, scanned);
                }
                if (lex != .close_paren) {
                    try nodes.append(a, .{ .lex = lex, .prev = incomplete });
                    incomplete = nodes.items.len - 1;
                    last = @intCast(incomplete);
                }
            },
        }
        if (lex == .end) return null;
        pos += scanned;
    }
}

/// Moves `p` past the word that starts at its position. False for a `$`
/// with no variable name.
fn leafEnd(p: *interp.Parser, lex: Lex) !bool {
    switch (lex) {
        .quoted => {
            const quote = p.pos;
            p.pos += 1;
            var parts: interp.Parts = .{ .a = p.a };
            try p.parseParts(&parts, .quote);
            if (p.pos >= p.src.len) {
                p.term = quote;
                p.message = "missing \"";
                return error.TclError;
            }
            p.pos += 1;
        },
        .braced => _ = try p.parseBraced(),
        .variable => return (try p.parseVar()) != null,
        else => {
            p.pos += 1;
            _ = try p.parseScript(true);
        },
    }
    return true;
}

/// The error of a bareword that is not a function name or a boolean.
fn bareword(a: std.mem.Allocator, text: []const u8, pos: usize, n: usize) !Diag {
    const w = text[pos .. pos + n];
    const shown = if (n < limit) w else w[0 .. limit - 3];
    const dots = if (n < limit) "" else "...";
    var post: std.ArrayList(u8) = .empty;
    try post.print(a, "should be \"${s}{s}\" or \"{{{s}{s}}}\" or \"{s}{s}(...)\" or ...", .{ shown, dots, shown, dots, shown, dots });
    var code: []const u8 = "BAREWORD";
    if (w[0] == '0') {
        // A word that starts as a number and goes on is a bad number when
        // it has a digit where the number stops, or only a 0 before a
        // radix letter.
        const stop = numberLen(w);
        if ((stop < w.len and std.ascii.isDigit(w[stop])) or stop == 1) {
            const kind: ?[]const u8 = if (w.len > 1) switch (w[1]) {
                'b' => "binary",
                'o' => "octal",
                else => if (std.ascii.isDigit(w[1])) "octal" else null,
            } else null;
            if (kind) |k| {
                try post.print(a, " (invalid {s} number?)", .{k});
                code = if (k[0] == 'b') "BADNUMBER BINARY" else "BADNUMBER OCTAL";
            }
        }
    }
    return .{
        .msg = try std.fmt.allocPrint(a, "invalid bareword \"{s}{s}\"", .{ shown, dots }),
        .code = code,
        .at = pos,
        .scanned = n,
        .mark = false,
        .post = post.items,
    };
}

/// `s` cut to at most `n` bytes, with no partial UTF-8 sequence at the
/// end.
fn cut(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var k = n;
    while (k > 0 and s[k] & 0xC0 == 0x80) k -= 1;
    if (k > 0 and k + utf8Len(s[k]) > n) return s[0..k];
    return s[0..n];
}

/// `s` without the bytes of a partial UTF-8 sequence at its start.
fn skipCont(s: []const u8) []const u8 {
    var k: usize = 0;
    while (k < s.len and s[k] & 0xC0 == 0x80) k += 1;
    return s[k..];
}

/// The message of `d` with the part of the expression around the error.
pub fn message(it: *Interp, text: []const u8, d: Diag) ![]const u8 {
    const a = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, d.msg);
    try out.appendSlice(a, "\nin expression \"");
    const start = d.at;
    if (start < limit) {
        try out.appendSlice(a, text[0..start]);
    } else {
        try out.appendSlice(a, "...");
        try out.appendSlice(a, skipCont(text[start - limit + 3 .. start]));
    }
    const lex = text[start..@min(start + d.scanned, text.len)];
    if (d.scanned < limit) try out.appendSlice(a, lex) else {
        try out.appendSlice(a, cut(lex, limit - 3));
        try out.appendSlice(a, "...");
    }
    if (d.mark) try out.appendSlice(a, "_@_");
    const after = text[@min(start + d.scanned, text.len)..];
    if (start + d.scanned + limit > text.len) try out.appendSlice(a, after) else {
        try out.appendSlice(a, cut(after, limit - 3));
        try out.appendSlice(a, "...");
    }
    try out.append(a, '"');
    if (d.post) |p| {
        try out.appendSlice(a, ";\n");
        try out.appendSlice(a, p);
    }
    return out.items;
}

/// The line that Tcl adds to the errorInfo of a syntax error.
pub fn infoLine(it: *Interp, text: []const u8) ![]const u8 {
    if (text.len < limit) return std.fmt.allocPrint(it.alloc(), "\n    (parsing expression \"{s}\")", .{text});
    return std.fmt.allocPrint(it.alloc(), "\n    (parsing expression \"{s}...\")", .{cut(text, limit - 3)});
}

//! The parse slots of the stubs table of Tcl 8.6 and
//! `Tcl_ParseArgsObjv`. The native path (`stubs.zig`) and the
//! WebAssembly path (`wasm_stubs.zig`) use this one file.
//!
//! This file is a port to Zig of parts of Tcl 8.6.16: the parser of
//! `generic/tclParse.c`, the expression parser and `ConvertTreeToTokens`
//! of `generic/tclCompExpr.c`, the number scan of `TclParseNumber` in
//! `generic/tclStrToD.c`, `FindElement` of `generic/tclUtil.c`, and
//! `Tcl_ParseArgsObjv` of `generic/tclIndexObj.c`. Tcl has a BSD-style
//! license: `licenses/tcl-license.txt`. A C package reads the token tree
//! directly, so the tree is the tree of Tcl 8.6: the same tokens, the
//! same sizes, and the same `numComponents`.
//!
//! `Tcl_EvalTokensStandard` gets a variable and runs a command through
//! the variable and script functions of `host.zig`.
//!
//! A syntax error of `Tcl_ParseExpr` sets the result text and the error
//! code {TCL PARSE EXPR ...} of Tcl.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const obj = @import("obj.zig");
const host = @import("host.zig");

const Obj = obj.Obj;
const Interp = obj.Interp;
const OK = obj.OK;
const ERROR = obj.ERROR;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();

extern "c" fn snprintf(buf: [*]u8, n: usize, fmt: [*:0]const u8, ...) c_int;

// ---- The layouts of tcl.h ----

pub const TOKEN_WORD: c_int = 1;
pub const TOKEN_SIMPLE_WORD: c_int = 2;
pub const TOKEN_TEXT: c_int = 4;
pub const TOKEN_BS: c_int = 8;
pub const TOKEN_COMMAND: c_int = 16;
pub const TOKEN_VARIABLE: c_int = 32;
pub const TOKEN_SUB_EXPR: c_int = 64;
pub const TOKEN_OPERATOR: c_int = 128;
pub const TOKEN_EXPAND_WORD: c_int = 256;

pub const PARSE_SUCCESS: c_int = 0;
pub const PARSE_QUOTE_EXTRA: c_int = 1;
pub const PARSE_BRACE_EXTRA: c_int = 2;
pub const PARSE_MISSING_BRACE: c_int = 3;
pub const PARSE_MISSING_BRACKET: c_int = 4;
pub const PARSE_MISSING_PAREN: c_int = 5;
pub const PARSE_MISSING_QUOTE: c_int = 6;
pub const PARSE_MISSING_VAR_BRACE: c_int = 7;
pub const PARSE_SYNTAX: c_int = 8;
pub const PARSE_BAD_NUMBER: c_int = 9;

const SUBST_COMMANDS: c_int = 1;
const SUBST_VARIABLES: c_int = 2;
const SUBST_BACKSLASHES: c_int = 4;
const SUBST_ALL: c_int = 7;

const BREAK: c_int = 3;
const CONTINUE: c_int = 4;

pub const NUM_STATIC_TOKENS = 20;

/// `Tcl_Token`.
pub const Token = extern struct {
    type: c_int,
    start: [*]const u8,
    size: c_int,
    numComponents: c_int,
};

/// `Tcl_Parse`.
pub const Parse = extern struct {
    commentStart: ?[*]const u8,
    commentSize: c_int,
    commandStart: ?[*]const u8,
    commandSize: c_int,
    numWords: c_int,
    tokenPtr: [*]Token,
    numTokens: c_int,
    tokensAvailable: c_int,
    errorType: c_int,
    string: [*]const u8,
    end: [*]const u8,
    interp: ?*Interp,
    term: [*]const u8,
    incomplete: c_int,
    staticTokens: [NUM_STATIC_TOKENS]Token,
};

// ---- The character types of tclParse.h ----

const TYPE_NORMAL: u8 = 0;
const TYPE_SPACE: u8 = 0x1;
const TYPE_COMMAND_END: u8 = 0x2;
const TYPE_SUBS: u8 = 0x4;
const TYPE_QUOTE: u8 = 0x8;
const TYPE_CLOSE_PAREN: u8 = 0x10;
const TYPE_CLOSE_BRACK: u8 = 0x20;
const TYPE_BRACE: u8 = 0x40;

fn ctype(c: u8) u8 {
    return switch (c) {
        0, '$', '[', '\\' => TYPE_SUBS,
        '\t', 0x0b, 0x0c, '\r', ' ' => TYPE_SPACE,
        '\n', ';' => TYPE_COMMAND_END,
        '"' => TYPE_QUOTE,
        ')' => TYPE_CLOSE_PAREN,
        ']' => TYPE_CLOSE_BRACK,
        '{', '}' => TYPE_BRACE,
        else => TYPE_NORMAL,
    };
}

fn isSpace(c: u8) bool {
    return ctype(c) & TYPE_SPACE != 0 or c == '\n';
}

fn isBareword(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The byte count from `b` to `a`.
fn diff(a: [*]const u8, b: [*]const u8) usize {
    return @intFromPtr(a) - @intFromPtr(b);
}

fn cint(n: usize) c_int {
    return @intCast(n);
}

fn setMsg(ip: ?*Interp, s: []const u8) void {
    if (ip) |i| obj.setResultText(i, s);
}

// ---- The token array ----

fn initParse(ip: ?*Interp, start: [*]const u8, n: usize, p: *Parse) void {
    p.numWords = 0;
    p.tokenPtr = &p.staticTokens;
    p.numTokens = 0;
    p.tokensAvailable = NUM_STATIC_TOKENS;
    p.string = start;
    p.end = start + n;
    p.term = p.end;
    p.interp = ip;
    p.incomplete = 0;
    p.errorType = PARSE_SUCCESS;
}

/// Makes room for `more` tokens after `numTokens`.
fn grow(p: *Parse, more: usize) void {
    const need: usize = @as(usize, @intCast(p.numTokens)) + more;
    const have: usize = @intCast(p.tokensAvailable);
    if (need <= have) return;
    const count = 2 * need;
    const mem: [*]Token = @ptrCast(@alignCast(std.c.malloc(count * @sizeOf(Token)) orelse obj.panicText("out of memory")));
    @memcpy(mem[0..@intCast(p.numTokens)], p.tokenPtr[0..@intCast(p.numTokens)]);
    if (p.tokenPtr != @as([*]Token, &p.staticTokens)) std.c.free(p.tokenPtr);
    p.tokenPtr = mem;
    p.tokensAvailable = cint(count);
}

fn tok(p: *Parse, i: anytype) *Token {
    return &p.tokenPtr[@intCast(i)];
}

pub fn Tcl_FreeParse(p: *Parse) callconv(.c) void {
    if (p.tokenPtr != @as([*]Token, &p.staticTokens)) {
        std.c.free(p.tokenPtr);
        p.tokenPtr = &p.staticTokens;
    }
}

// ---- White space, backslashes, and comments ----

fn parseWhiteSpace(src: [*]const u8, n0: usize, incomplete: *c_int, typ: *u8) usize {
    var t: u8 = TYPE_NORMAL;
    var p = src;
    var n = n0;
    while (true) {
        while (n != 0) {
            t = ctype(p[0]);
            if (t & TYPE_SPACE == 0) break;
            n -= 1;
            p += 1;
        }
        if (n != 0 and t & TYPE_SUBS != 0) {
            if (p[0] != '\\') break;
            n -= 1;
            if (n == 0) break;
            if (p[1] != '\n') break;
            p += 2;
            n -= 1;
            if (n == 0) {
                incomplete.* = 1;
                break;
            }
            continue;
        }
        break;
    }
    typ.* = t;
    return diff(p, src);
}

/// `TclParseAllWhiteSpace`: white space and newlines.
fn allWhiteSpace(src: [*]const u8, n0: usize) usize {
    var dummy: c_int = 0;
    var t: u8 = 0;
    var p = src;
    var n = n0;
    while (true) {
        const s = parseWhiteSpace(p, n, &dummy, &t);
        p += s;
        n -= s;
        if (n != 0 and p[0] == '\n') {
            p += 1;
            n -= 1;
            if (n != 0) continue;
        }
        break;
    }
    return diff(p, src);
}

fn parseHex(src: [*]const u8, n0: usize, out: *u32) usize {
    var r: u32 = 0;
    var i: usize = 0;
    while (i < n0) : (i += 1) {
        const d = src[i];
        if (!std.ascii.isHex(d) or r > 0x10FFF) break;
        r = (r << 4) | (std.fmt.charToDigit(d, 16) catch unreachable);
    }
    out.* = r;
    return i;
}

/// Writes `ch` in the UTF-8 of Tcl 8.6 with a `TCL_UTF_MAX` of 3: U+0000
/// is C0 80 and a surrogate is its own 3 bytes.
fn putUtf(ch0: u32, dst: *[4]u8) usize {
    const ch = if (ch0 > 0xFFFF) 0xFFFD else ch0;
    if (ch >= 1 and ch < 0x80) {
        dst[0] = @intCast(ch);
        return 1;
    }
    if (ch < 0x800) {
        dst[0] = @intCast(0xC0 | (ch >> 6));
        dst[1] = @intCast(0x80 | (ch & 0x3F));
        return 2;
    }
    dst[0] = @intCast(0xE0 | (ch >> 12));
    dst[1] = @intCast(0x80 | ((ch >> 6) & 0x3F));
    dst[2] = @intCast(0x80 | (ch & 0x3F));
    return 3;
}

/// Reads one character of UTF-8. A byte that does not start a valid
/// sequence is one character with its own value.
fn getUtf(s: []const u8, out: *u32) usize {
    if (s.len == 0) {
        out.* = 0;
        return 0;
    }
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch {
        out.* = s[0];
        return 1;
    };
    if (n <= s.len) {
        if (std.unicode.utf8Decode(s[0..n])) |c| {
            out.* = c;
            return n;
        } else |_| {}
    }
    out.* = s[0];
    return 1;
}

/// `TclParseBackslash`: the bytes that the backslash at `src` reads go
/// to `read`, and its character goes to `dst`. The return is the byte
/// count of the character.
pub fn parseBackslash(src: [*]const u8, n: usize, read: ?*usize, dst: ?*[4]u8) usize {
    var buf: [4]u8 = undefined;
    const d = dst orelse &buf;
    if (n == 0) {
        if (read) |r| r.* = 0;
        return 0;
    }
    var result: u32 = undefined;
    var count: usize = 2;
    if (n == 1) {
        result = '\\';
        count = 1;
    } else {
        const p = src + 1;
        switch (p[0]) {
            'a' => result = 0x7,
            'b' => result = 0x8,
            'f' => result = 0xC,
            'n' => result = 0xA,
            'r' => result = 0xD,
            't' => result = 0x9,
            'v' => result = 0xB,
            'x' => {
                count += parseHex(p + 1, if (n > 3) 2 else n - 2, &result);
                result = if (count == 2) 'x' else result & 0xFF;
            },
            'u' => {
                count += parseHex(p + 1, if (n > 5) 4 else n - 2, &result);
                if (count == 2) result = 'u';
            },
            'U' => {
                count += parseHex(p + 1, if (n > 9) 8 else n - 2, &result);
                if (count == 2) result = 'U';
            },
            '\n' => {
                count -= 1;
                var q = p;
                while (true) {
                    q += 1;
                    count += 1;
                    if (!(count < n and (q[0] == ' ' or q[0] == '\t'))) break;
                }
                result = ' ';
            },
            0 => {
                result = '\\';
                count = 1;
            },
            else => |c| if (c >= '0' and c <= '7') {
                result = c - '0';
                if (n == 2 or !(p[1] >= '0' and p[1] <= '7')) {} else {
                    count = 3;
                    result = (result << 3) + (p[1] - '0');
                    if (n == 3 or !(p[2] >= '0' and p[2] <= '7') or result >= 0x20) {} else {
                        count = 4;
                        result = ((result << 3) + (p[2] - '0')) & 0xFF;
                    }
                }
            } else {
                count = getUtf(p[0 .. n - 1], &result) + 1;
            },
        }
    }
    if (read) |r| r.* = count;
    return putUtf(result, d);
}

fn parseComment(src: [*]const u8, n0: usize, p: *Parse) usize {
    var q = src;
    var n = n0;
    var t: u8 = 0;
    while (n != 0) {
        while (true) {
            const s = parseWhiteSpace(q, n, &p.incomplete, &t);
            q += s;
            n -= s;
            if (n != 0 and q[0] == '\n') {
                q += 1;
                n -= 1;
                continue;
            }
            break;
        }
        if (n == 0 or q[0] != '#') break;
        if (p.commentStart == null) p.commentStart = q;
        while (n != 0) {
            if (q[0] == '\\') {
                var s = parseWhiteSpace(q, n, &p.incomplete, &t);
                if (s == 0) _ = parseBackslash(q, n, &s, null);
                q += s;
                n -= s;
            } else {
                q += 1;
                n -= 1;
                if ((q - 1)[0] == '\n') break;
            }
        }
        p.commentSize = cint(diff(q, p.commentStart.?));
    }
    return diff(q, src);
}

// ---- Words ----

fn parseTokens(src0: [*]const u8, n0: usize, mask: u8, flags: c_int, p: *Parse) c_int {
    var src = src0;
    var n = n0;
    const original = p.numTokens;
    while (n != 0) {
        const t = ctype(src[0]);
        if (t & mask != 0) break;
        grow(p, 1);
        const ti = p.numTokens;
        tok(p, ti).start = src;
        tok(p, ti).numComponents = 0;
        if (t & TYPE_SUBS == 0) {
            while (true) {
                src += 1;
                n -= 1;
                if (n == 0 or ctype(src[0]) & (mask | TYPE_SUBS) != 0) break;
            }
            tok(p, ti).type = TOKEN_TEXT;
            tok(p, ti).size = cint(diff(src, tok(p, ti).start));
            p.numTokens += 1;
        } else if (src[0] == '$') {
            if (flags & SUBST_VARIABLES == 0) {
                textOne(p, ti);
                src += 1;
                n -= 1;
                continue;
            }
            if (Tcl_ParseVarName(p.interp, src, cint(n), p, 1) != OK) return ERROR;
            const size: usize = @intCast(tok(p, ti).size);
            src += size;
            n -= size;
        } else if (src[0] == '[') {
            if (flags & SUBST_COMMANDS == 0) {
                textOne(p, ti);
                src += 1;
                n -= 1;
                continue;
            }
            src += 1;
            n -= 1;
            var nested: Parse = undefined;
            while (true) {
                if (Tcl_ParseCommand(p.interp, src, cint(n), 1, &nested) != OK) {
                    p.errorType = nested.errorType;
                    p.term = nested.term;
                    p.incomplete = nested.incomplete;
                    return ERROR;
                }
                const cur_end = src + n;
                src = nested.commandStart.? + @as(usize, @intCast(nested.commandSize));
                n = diff(cur_end, src);
                Tcl_FreeParse(&nested);
                if (@intFromPtr(nested.term) < @intFromPtr(p.end) and nested.term[0] == ']' and nested.incomplete == 0) break;
                if (n == 0) {
                    setMsg(p.interp, "missing close-bracket");
                    p.errorType = PARSE_MISSING_BRACKET;
                    p.term = tok(p, ti).start;
                    p.incomplete = 1;
                    return ERROR;
                }
            }
            tok(p, ti).type = TOKEN_COMMAND;
            tok(p, ti).size = cint(diff(src, tok(p, ti).start));
            p.numTokens += 1;
        } else if (src[0] == '\\') {
            if (flags & SUBST_BACKSLASHES == 0) {
                textOne(p, ti);
                src += 1;
                n -= 1;
                continue;
            }
            var size: usize = 0;
            _ = parseBackslash(src, n, &size, null);
            tok(p, ti).size = cint(size);
            if (size == 1) {
                tok(p, ti).type = TOKEN_TEXT;
                p.numTokens += 1;
                src += 1;
                n -= 1;
                continue;
            }
            if (src[1] == '\n') {
                if (n == 2) p.incomplete = 1;
                if (mask & TYPE_SPACE != 0) {
                    if (p.numTokens == original) {
                        tok(p, ti).type = TOKEN_TEXT;
                        tok(p, ti).size = 0;
                        p.numTokens += 1;
                        p.term = src;
                        return OK;
                    }
                    break;
                }
            }
            tok(p, ti).type = TOKEN_BS;
            p.numTokens += 1;
            src += size;
            n -= size;
        } else {
            // A NUL byte.
            textOne(p, ti);
            src += 1;
            n -= 1;
        }
    }
    if (p.numTokens == original) {
        grow(p, 1);
        const ti = p.numTokens;
        tok(p, ti).* = .{ .type = TOKEN_TEXT, .start = src, .size = 0, .numComponents = 0 };
        p.numTokens += 1;
    }
    p.term = src;
    return OK;
}

fn textOne(p: *Parse, ti: c_int) void {
    tok(p, ti).type = TOKEN_TEXT;
    tok(p, ti).size = 1;
    p.numTokens += 1;
}

/// `FindElement` of tclUtil.c with no interp: the next element of the
/// list text `s`. Null for a list with a syntax error.
fn findElement(s: []const u8, elem: *usize, next: *usize, size: *usize, literal: *bool) bool {
    var p: usize = 0;
    var open: usize = 0;
    var quotes = false;
    var lit = true;
    while (p < s.len and isSpace(s[p])) p += 1;
    if (p == s.len) {
        elem.* = s.len;
        next.* = s.len;
        size.* = 0;
        literal.* = true;
        return true;
    }
    if (s[p] == '{') {
        open = 1;
        p += 1;
    } else if (s[p] == '"') {
        quotes = true;
        p += 1;
    }
    const start = p;
    var sz: usize = 0;
    var done = false;
    while (p < s.len) {
        switch (s[p]) {
            '{' => if (open != 0) {
                open += 1;
            },
            '}' => if (open > 1) {
                open -= 1;
            } else if (open == 1) {
                sz = p - start;
                p += 1;
                if (p >= s.len or isSpace(s[p])) {
                    done = true;
                    break;
                }
                return false;
            },
            '\\' => {
                if (open == 0) lit = false;
                var k: usize = 0;
                _ = parseBackslash(s.ptr + p, s.len - p, &k, null);
                p += k - 1;
            },
            '"' => if (quotes) {
                sz = p - start;
                p += 1;
                if (p >= s.len or isSpace(s[p])) {
                    done = true;
                    break;
                }
                return false;
            },
            else => if (isSpace(s[p]) and open == 0 and !quotes) {
                sz = p - start;
                done = true;
                break;
            },
        }
        p += 1;
    }
    if (!done) {
        if (open != 0 or quotes) return false;
        sz = p - start;
    }
    while (p < s.len and isSpace(s[p])) p += 1;
    elem.* = start;
    next.* = p;
    size.* = sz;
    literal.* = lit;
    return true;
}

pub fn Tcl_ParseCommand(ip: ?*Interp, start0: ?[*]const u8, len: c_int, nested: c_int, p: *Parse) callconv(.c) c_int {
    const start: [*]const u8 = start0 orelse "";
    var n: usize = if (len < 0) (if (start0) |s| std.mem.len(@as([*:0]const u8, @ptrCast(s))) else 0) else @intCast(len);
    initParse(ip, start, n, p);
    if (start0 == null and n != 0) {
        setMsg(ip, "can't parse a NULL pointer");
        return ERROR;
    }
    p.commentStart = null;
    p.commentSize = 0;
    p.commandStart = null;
    p.commandSize = 0;
    const terminators: u8 = if (nested != 0) TYPE_COMMAND_END | TYPE_CLOSE_BRACK else TYPE_COMMAND_END;
    var scanned = parseComment(start, n, p);
    var src = start + scanned;
    n -= scanned;
    if (n == 0 and nested != 0) p.incomplete = nested;
    p.commandStart = src;
    var t: u8 = 0;
    words: while (true) {
        var expand = false;
        grow(p, 1);
        const wi = p.numTokens;
        tok(p, wi).type = TOKEN_WORD;
        scanned = parseWhiteSpace(src, n, &p.incomplete, &t);
        src += scanned;
        n -= scanned;
        if (n == 0) {
            p.term = src;
            break;
        }
        if (t & terminators != 0) {
            p.term = src;
            src += 1;
            break;
        }
        tok(p, wi).start = src;
        p.numTokens += 1;
        p.numWords += 1;
        while (true) {
            if (src[0] == '"') {
                var term: [*]const u8 = undefined;
                if (Tcl_ParseQuotedString(ip, src, cint(n), p, 1, &term) != OK) return parseError(p);
                src = term;
                n = diff(p.end, src);
            } else if (src[0] == '{') {
                const ei = wi + 1;
                var term: [*]const u8 = undefined;
                if (Tcl_ParseBraces(ip, src, cint(n), p, 1, &term) != OK) return parseError(p);
                src = term;
                n = diff(p.end, src);
                const e = tok(p, ei);
                if (!expand and p.numTokens - ei == 1 and e.size == 1 and e.start[0] == '*' and n > 0 and
                    parseWhiteSpace(term, n, &p.incomplete, &t) == 0 and t != TYPE_COMMAND_END)
                {
                    expand = true;
                    p.numTokens -= 1;
                    continue;
                }
            } else {
                if (parseTokens(src, n, TYPE_SPACE | terminators, SUBST_ALL, p) != OK) return parseError(p);
                src = p.term;
                n = diff(p.end, src);
            }
            break;
        }
        const w = tok(p, wi);
        w.size = cint(diff(src, w.start));
        w.numComponents = p.numTokens - (wi + 1);
        if (expand) {
            expandWord(p, wi);
        } else if (w.numComponents == 1 and tok(p, wi + 1).type == TOKEN_TEXT) {
            w.type = TOKEN_SIMPLE_WORD;
        }
        scanned = parseWhiteSpace(src, n, &p.incomplete, &t);
        if (scanned != 0) {
            src += scanned;
            n -= scanned;
            continue :words;
        }
        if (n == 0) {
            p.term = src;
            break;
        }
        if (t & terminators != 0) {
            p.term = src;
            src += 1;
            break;
        }
        if ((src - 1)[0] == '"') {
            setMsg(ip, "extra characters after close-quote");
            p.errorType = PARSE_QUOTE_EXTRA;
        } else {
            setMsg(ip, "extra characters after close-brace");
            p.errorType = PARSE_BRACE_EXTRA;
        }
        p.term = src;
        return parseError(p);
    }
    p.commandSize = cint(diff(src, p.commandStart.?));
    return OK;
}

fn parseError(p: *Parse) c_int {
    Tcl_FreeParse(p);
    p.commandSize = cint(diff(p.end, p.commandStart.?));
    return ERROR;
}

/// The word of `{*}` at token `wi`. A word of literal text becomes one
/// simple word for each element of its list.
fn expandWord(p: *Parse, wi: c_int) void {
    const w = tok(p, wi);
    const nc = w.numComponents;
    var i: c_int = 1;
    while (i <= nc) : (i += 1) {
        if (tok(p, wi + i).type != TOKEN_TEXT) {
            tok(p, wi).type = TOKEN_EXPAND_WORD;
            return;
        }
    }
    const last = tok(p, wi + nc);
    const list_start = tok(p, wi + 1).start;
    const list = list_start[0..diff(last.start + @as(usize, @intCast(last.size)), list_start)];
    var count: c_int = 0;
    var at: usize = 0;
    var elem: usize = 0;
    var next: usize = 0;
    var size: usize = 0;
    var literal = true;
    while (at < list.len) {
        if (!findElement(list[at..], &elem, &next, &size, &literal) or !literal) {
            tok(p, wi).type = TOKEN_EXPAND_WORD;
            return;
        }
        if (at + elem < list.len) count += 1;
        at += next;
    }
    if (count == 0) {
        p.numWords -= 1;
        p.numTokens = wi;
        return;
    }
    p.numWords += count - 1;
    const need = wi + 2 * count - p.numTokens;
    if (need > 0) grow(p, @intCast(need));
    p.numTokens = wi + 2 * count;
    var ti = wi;
    at = 0;
    while (at < list.len) {
        _ = findElement(list[at..], &elem, &next, &size, &literal);
        const es = at + elem;
        at += next;
        const quoted = es > 0 and (list[es - 1] == '{' or list[es - 1] == '"');
        const q: usize = @intFromBool(quoted);
        tok(p, ti).* = .{ .type = TOKEN_SIMPLE_WORD, .start = list.ptr + es - q, .size = cint(size + 2 * q), .numComponents = 1 };
        tok(p, ti + 1).* = .{ .type = TOKEN_TEXT, .start = list.ptr + es, .size = cint(size), .numComponents = 0 };
        ti += 2;
    }
}

pub fn Tcl_ParseVarName(ip: ?*Interp, start0: ?[*]const u8, len: c_int, p: *Parse, append: c_int) callconv(.c) c_int {
    const start: [*]const u8 = start0 orelse "";
    var n: usize = if (len < 0) (if (start0) |s| std.mem.len(@as([*:0]const u8, @ptrCast(s))) else 0) else @intCast(len);
    if (append == 0) initParse(ip, start, n, p);
    if (n == 0 or start0 == null) return ERROR;
    var src = start;
    grow(p, 2);
    const vi = p.numTokens;
    tok(p, vi).* = .{ .type = TOKEN_VARIABLE, .start = src, .size = 0, .numComponents = 0 };
    p.numTokens += 1;
    const ti = vi + 1;
    src += 1;
    n -= 1;
    if (n == 0) return dollar(p, vi);
    tok(p, ti).* = .{ .type = TOKEN_TEXT, .start = src, .size = 0, .numComponents = 0 };
    if (src[0] == '{') {
        src += 1;
        n -= 1;
        tok(p, ti).start = src;
        while (n != 0 and src[0] != '}') {
            n -= 1;
            src += 1;
        }
        if (n == 0) {
            setMsg(p.interp, "missing close-brace for variable name");
            p.errorType = PARSE_MISSING_VAR_BRACE;
            p.term = tok(p, ti).start - 1;
            p.incomplete = 1;
            Tcl_FreeParse(p);
            return ERROR;
        }
        tok(p, ti).size = cint(diff(src, tok(p, ti).start));
        tok(p, vi).size = cint(diff(src, tok(p, vi).start));
        p.numTokens += 1;
        src += 1;
    } else {
        while (n != 0) {
            if (isBareword(src[0])) {
                src += 1;
                n -= 1;
                continue;
            }
            if (src[0] == ':' and n != 1 and src[1] == ':') {
                src += 2;
                n -= 2;
                while (n != 0 and src[0] == ':') {
                    src += 1;
                    n -= 1;
                }
                continue;
            }
            break;
        }
        const array = n != 0 and src[0] == '(';
        tok(p, ti).size = cint(diff(src, tok(p, ti).start));
        if (tok(p, ti).size == 0 and !array) return dollar(p, vi);
        p.numTokens += 1;
        if (array) {
            if (parseTokens(src + 1, n - 1, TYPE_CLOSE_PAREN, SUBST_ALL, p) != OK) {
                Tcl_FreeParse(p);
                return ERROR;
            }
            if (p.term == src + n or p.term[0] != ')') {
                setMsg(p.interp, "missing )");
                p.errorType = PARSE_MISSING_PAREN;
                p.term = src;
                p.incomplete = 1;
                Tcl_FreeParse(p);
                return ERROR;
            }
            src = p.term + 1;
        }
    }
    const v = tok(p, vi);
    v.size = cint(diff(src, v.start));
    v.numComponents = p.numTokens - (vi + 1);
    return OK;
}

fn dollar(p: *Parse, vi: c_int) c_int {
    const v = tok(p, vi);
    v.type = TOKEN_TEXT;
    v.size = 1;
    v.numComponents = 0;
    return OK;
}

pub fn Tcl_ParseVar(ip: *Interp, start: [*:0]const u8, term: ?*[*]const u8) callconv(.c) ?[*:0]const u8 {
    var p: Parse = undefined;
    if (Tcl_ParseVarName(ip, start, -1, &p, 0) != OK) return null;
    if (term) |t| t.* = start + @as(usize, @intCast(p.tokenPtr[0].size));
    if (p.numTokens == 1) return "$";
    const code = substTokens(ip, p.tokenPtr, p.numTokens);
    Tcl_FreeParse(&p);
    if (code != OK) return null;
    // The value stays alive until the command returns.
    const o = host.own(obj.Tcl_GetObjResult(ip));
    obj.Tcl_ResetResult(ip);
    return obj.Tcl_GetString(o);
}

pub fn Tcl_ParseBraces(ip: ?*Interp, start0: ?[*]const u8, len: c_int, p: *Parse, append: c_int, term: ?*[*]const u8) callconv(.c) c_int {
    const start: [*]const u8 = start0 orelse "";
    var n: usize = if (len < 0) (if (start0) |s| std.mem.len(@as([*:0]const u8, @ptrCast(s))) else 0) else @intCast(len);
    if (append == 0) initParse(ip, start, n, p);
    if (n == 0 or start0 == null) return ERROR;
    var src = start;
    const si = p.numTokens;
    grow(p, 1);
    var ti = si;
    tok(p, ti).* = .{ .type = TOKEN_TEXT, .start = src + 1, .size = 0, .numComponents = 0 };
    var level: usize = 1;
    while (true) {
        while (true) {
            src += 1;
            n -= 1;
            if (n == 0 or ctype(src[0]) != TYPE_NORMAL) break;
        }
        if (n == 0) break;
        switch (src[0]) {
            '{' => level += 1,
            '}' => {
                level -= 1;
                if (level == 0) {
                    if (src != tok(p, ti).start or p.numTokens == si) {
                        tok(p, ti).size = cint(diff(src, tok(p, ti).start));
                        p.numTokens += 1;
                    }
                    if (term) |t| t.* = src + 1;
                    return OK;
                }
            },
            '\\' => {
                var length: usize = 0;
                _ = parseBackslash(src, n, &length, null);
                if (length > 1 and src[1] == '\n') {
                    if (n == 2) p.incomplete = 1;
                    tok(p, ti).size = cint(diff(src, tok(p, ti).start));
                    if (tok(p, ti).size != 0) p.numTokens += 1;
                    grow(p, 2);
                    ti = p.numTokens;
                    tok(p, ti).* = .{ .type = TOKEN_BS, .start = src, .size = cint(length), .numComponents = 0 };
                    p.numTokens += 1;
                    src += length - 1;
                    n -= length - 1;
                    ti += 1;
                    tok(p, ti).* = .{ .type = TOKEN_TEXT, .start = src + 1, .size = 0, .numComponents = 0 };
                } else {
                    src += length - 1;
                    n -= length - 1;
                }
            },
            else => {},
        }
    }
    p.errorType = PARSE_MISSING_BRACE;
    p.term = start;
    p.incomplete = 1;
    if (p.interp) |i| {
        var msg: []const u8 = "missing close-brace";
        var open = false;
        var q = src;
        while (true) {
            q -= 1;
            if (@intFromPtr(q) <= @intFromPtr(start)) break;
            switch (q[0]) {
                '{' => open = true,
                '\n' => open = false,
                '#' => if (open and isSpace((q - 1)[0])) {
                    msg = "missing close-brace: possible unbalanced brace in comment";
                    break;
                },
                else => {},
            }
        }
        obj.setResultText(i, msg);
    }
    Tcl_FreeParse(p);
    return ERROR;
}

pub fn Tcl_ParseQuotedString(ip: ?*Interp, start0: ?[*]const u8, len: c_int, p: *Parse, append: c_int, term: ?*[*]const u8) callconv(.c) c_int {
    const start: [*]const u8 = start0 orelse "";
    const n: usize = if (len < 0) (if (start0) |s| std.mem.len(@as([*:0]const u8, @ptrCast(s))) else 0) else @intCast(len);
    if (append == 0) initParse(ip, start, n, p);
    if (n == 0 or start0 == null) return ERROR;
    if (parseTokens(start + 1, n - 1, TYPE_QUOTE, SUBST_ALL, p) != OK) {
        Tcl_FreeParse(p);
        return ERROR;
    }
    if (p.term == p.end or p.term[0] != '"') {
        setMsg(p.interp, "missing \"");
        p.errorType = PARSE_MISSING_QUOTE;
        p.term = start;
        p.incomplete = 1;
        Tcl_FreeParse(p);
        return ERROR;
    }
    if (term) |t| t.* = p.term + 1;
    return OK;
}

// ---- Substitution of tokens ----

/// `TclSubstTokens`: the text of `count` tokens in the interp result.
fn substTokens(ip: *Interp, toks: [*]Token, count0: c_int) c_int {
    var code: c_int = OK;
    var res: ?*Obj = null;
    var count = count0;
    var t = toks;
    while (count > 0 and code == OK) : ({
        count -= 1;
        t += 1;
    }) {
        var append_obj: ?*Obj = null;
        var chars: [4]u8 = undefined;
        var bytes: []const u8 = &.{};
        const k = &t[0];
        switch (k.type) {
            TOKEN_TEXT => bytes = k.start[0..@intCast(k.size)],
            TOKEN_BS => bytes = chars[0..parseBackslash(k.start, @intCast(k.size), null, &chars)],
            TOKEN_COMMAND => {
                code = host.evalText(ip, k.start[1..@intCast(k.size - 1)], 0);
                append_obj = obj.Tcl_GetObjResult(ip);
            },
            TOKEN_VARIABLE => {
                var index: ?*Obj = null;
                if (k.numComponents > 1) {
                    code = substTokens(ip, t + 2, k.numComponents - 1);
                    index = obj.Tcl_GetObjResult(ip);
                    obj.incr(index.?);
                }
                if (code == OK) {
                    const nm = t[1].start[0..@intCast(t[1].size)];
                    append_obj = host.getVar(ip, nm, if (index) |x| obj.text(x) else null, host.TCL_LEAVE_ERR_MSG);
                    if (append_obj == null) code = ERROR;
                }
                if (code != OK and code != ERROR and code != BREAK and code != CONTINUE) append_obj = obj.Tcl_GetObjResult(ip);
                if (index) |x| obj.decr(x);
                count -= k.numComponents;
                t += @intCast(k.numComponents);
            },
            else => obj.panicText("unexpected token type in TclSubstTokens"),
        }
        if (code == BREAK or code == CONTINUE) continue;
        if (res) |r0| {
            var r = r0;
            if (r.refCount > 1) {
                obj.decr(r);
                r = obj.Tcl_DuplicateObj(r);
                obj.incr(r);
                res = r;
            }
            if (append_obj) |a| obj.Tcl_AppendObjToObj(r, a) else obj.Tcl_AppendToObj(r, bytes.ptr, cint(bytes.len));
        } else {
            const r = append_obj orelse obj.Tcl_NewStringObj(bytes.ptr, cint(bytes.len));
            obj.incr(r);
            res = r;
        }
    }
    if (code != ERROR) {
        if (res) |r| obj.Tcl_SetObjResult(ip, r) else obj.Tcl_ResetResult(ip);
    }
    if (res) |r| obj.decr(r);
    return code;
}

pub fn Tcl_EvalTokensStandard(ip: *Interp, toks: [*]Token, count: c_int) callconv(.c) c_int {
    return substTokens(ip, toks, count);
}

pub fn Tcl_EvalTokens(ip: *Interp, toks: [*]Token, count: c_int) callconv(.c) ?*Obj {
    if (substTokens(ip, toks, count) != OK) return null;
    const r = obj.Tcl_GetObjResult(ip);
    obj.incr(r);
    obj.Tcl_ResetResult(ip);
    return r;
}

// ---- Expressions ----

const NODE_TYPE: u8 = 0xC0;
const BINARY: u8 = 0x40;
const UNARY: u8 = 0x80;
const LEAF: u8 = 0xC0;

const PLUS: u8 = 1;
const MINUS: u8 = 2;
const BAREWORD: u8 = 3;
const INCOMPLETE: u8 = 4;
const INVALID: u8 = 5;

const NUMBER: u8 = LEAF | 1;
const SCRIPT: u8 = LEAF | 2;
const BOOLEAN: u8 = LEAF | BAREWORD;
const BRACED: u8 = LEAF | 4;
const VARIABLE: u8 = LEAF | 5;
const QUOTED: u8 = LEAF | 6;

const UNARY_PLUS: u8 = UNARY | PLUS;
const UNARY_MINUS: u8 = UNARY | MINUS;
const FUNCTION: u8 = UNARY | BAREWORD;
const START: u8 = UNARY | 4;
const OPEN_PAREN: u8 = UNARY | 5;
const NOT: u8 = UNARY | 6;
const BIT_NOT: u8 = UNARY | 7;

const COMMA: u8 = BINARY | 3;
const MULT: u8 = BINARY | 4;
const DIVIDE: u8 = BINARY | 5;
const MOD: u8 = BINARY | 6;
const LESS: u8 = BINARY | 7;
const GREATER: u8 = BINARY | 8;
const BIT_AND: u8 = BINARY | 9;
const BIT_XOR: u8 = BINARY | 10;
const BIT_OR: u8 = BINARY | 11;
const QUESTION: u8 = BINARY | 12;
const COLON: u8 = BINARY | 13;
const LEFT_SHIFT: u8 = BINARY | 14;
const RIGHT_SHIFT: u8 = BINARY | 15;
const LEQ: u8 = BINARY | 16;
const GEQ: u8 = BINARY | 17;
const EQUAL: u8 = BINARY | 18;
const NEQ: u8 = BINARY | 19;
const AND: u8 = BINARY | 20;
const OR: u8 = BINARY | 21;
const STREQ: u8 = BINARY | 22;
const STRNEQ: u8 = BINARY | 23;
const EXPON: u8 = BINARY | 24;
const IN_LIST: u8 = BINARY | 25;
const NOT_IN_LIST: u8 = BINARY | 26;
const CLOSE_PAREN: u8 = BINARY | 27;
const END: u8 = BINARY | 28;

const PREC_END: u8 = 1;
const PREC_START: u8 = 2;
const PREC_CLOSE_PAREN: u8 = 3;
const PREC_OPEN_PAREN: u8 = 4;
const PREC_COMMA: u8 = 5;
const PREC_CONDITIONAL: u8 = 6;
const PREC_OR: u8 = 7;
const PREC_AND: u8 = 8;
const PREC_BIT_OR: u8 = 9;
const PREC_BIT_XOR: u8 = 10;
const PREC_BIT_AND: u8 = 11;
const PREC_EQUAL: u8 = 12;
const PREC_COMPARE: u8 = 13;
const PREC_SHIFT: u8 = 14;
const PREC_ADD: u8 = 15;
const PREC_MULT: u8 = 16;
const PREC_EXPON: u8 = 17;
const PREC_UNARY: u8 = 18;

fn prec(l: u8) u8 {
    if (l & NODE_TYPE == BINARY) {
        const binary = [_]u8{
            0,            PREC_ADD,     PREC_ADD,     PREC_COMMA,   PREC_MULT,   PREC_MULT,        PREC_MULT,
            PREC_COMPARE, PREC_COMPARE, PREC_BIT_AND, PREC_BIT_XOR, PREC_BIT_OR, PREC_CONDITIONAL, PREC_CONDITIONAL,
            PREC_SHIFT,   PREC_SHIFT,   PREC_COMPARE, PREC_COMPARE, PREC_EQUAL,  PREC_EQUAL,       PREC_AND,
            PREC_OR,      PREC_EQUAL,   PREC_EQUAL,   PREC_EXPON,   PREC_EQUAL,  PREC_EQUAL,       PREC_CLOSE_PAREN,
            PREC_END,
        };
        const i = l & 0x3F;
        return if (i < binary.len) binary[i] else 0;
    }
    if (l & NODE_TYPE == UNARY) {
        const unary = [_]u8{ 0, PREC_UNARY, PREC_UNARY, PREC_UNARY, PREC_START, PREC_OPEN_PAREN, PREC_UNARY, PREC_UNARY };
        const i = l & 0x3F;
        return if (i < unary.len) unary[i] else 0;
    }
    return 0;
}

/// The lexeme of one ASCII byte, or 0 when the byte needs more look.
fn lexemeOf(c: u8) u8 {
    return switch (c) {
        0...32, '#', '\'', ';', '@', '\\', ']', '_', '`', '}', 127 => INVALID,
        '"' => QUOTED,
        '$' => VARIABLE,
        '%' => MOD,
        '(' => OPEN_PAREN,
        ')' => CLOSE_PAREN,
        '+' => PLUS,
        ',' => COMMA,
        '-' => MINUS,
        '/' => DIVIDE,
        ':' => COLON,
        '?' => QUESTION,
        '[' => SCRIPT,
        '^' => BIT_XOR,
        '{' => BRACED,
        '~' => BIT_NOT,
        else => 0,
    };
}

const Num = struct { ok: bool, end: usize, double: bool };

/// The number scan of `TclParseNumber` with `TCL_PARSE_NO_WHITESPACE`
/// and no sign. `end` is the end of the longest number at the start of
/// `s`, or the stop of the scan when no number is there.
fn scanNumber(s: []const u8) Num {
    const State = enum { initial, zero, zero_x, hex, zero_b, binary, zero_o, octal, bad_octal, decimal, leading_point, fraction, exp_start, exp_sign, exponent, i, in, inf, infi, infin, infini, infinit, infinity, n, na, nan, nan_paren, nan_hex, nan_finish };
    var state: State = .initial;
    var accept: State = .initial;
    var accept_at: usize = 0;
    var explicit_octal = false;
    var nan_digits: usize = 0;
    var p: usize = 0;
    scan: while (true) : (p += 1) {
        const c: u8 = if (p < s.len) s[p] else 0;
        state: switch (state) {
            .initial => switch (c) {
                '0' => state = .zero,
                '1'...'9' => state = .decimal,
                '.' => state = .leading_point,
                'I', 'i' => state = .i,
                'N', 'n' => state = .n,
                else => break :scan,
            },
            .zero => {
                accept = .zero;
                accept_at = p;
                switch (c) {
                    'x', 'X' => state = .zero_x,
                    'b', 'B' => state = .zero_b,
                    'o', 'O' => {
                        explicit_octal = true;
                        state = .zero_o;
                    },
                    else => continue :state .octal,
                }
            },
            .octal, .zero_o => {
                if (state == .octal) {
                    accept = .octal;
                    accept_at = p;
                }
                switch (c) {
                    '0'...'7' => state = .octal,
                    else => continue :state .bad_octal,
                }
            },
            .bad_octal => {
                if (explicit_octal) break :scan;
                switch (c) {
                    '0'...'9' => state = .bad_octal,
                    '.' => state = .fraction,
                    'E', 'e' => state = .exp_start,
                    else => break :scan,
                }
            },
            .hex, .zero_x => {
                if (state == .hex) {
                    accept = .hex;
                    accept_at = p;
                }
                if (std.ascii.isHex(c)) state = .hex else break :scan;
            },
            .binary, .zero_b => {
                if (state == .binary) {
                    accept = .binary;
                    accept_at = p;
                }
                if (c == '0' or c == '1') state = .binary else break :scan;
            },
            .decimal => {
                accept = .decimal;
                accept_at = p;
                switch (c) {
                    '0'...'9' => {},
                    '.' => state = .fraction,
                    'E', 'e' => state = .exp_start,
                    else => break :scan,
                }
            },
            .fraction => {
                accept = .fraction;
                accept_at = p;
                switch (c) {
                    'E', 'e' => state = .exp_start,
                    '0'...'9' => {},
                    else => break :scan,
                }
            },
            .leading_point => if (std.ascii.isDigit(c)) {
                state = .fraction;
            } else break :scan,
            .exp_start => switch (c) {
                '+', '-' => state = .exp_sign,
                else => continue :state .exp_sign,
            },
            .exp_sign => if (std.ascii.isDigit(c)) {
                state = .exponent;
            } else break :scan,
            .exponent => {
                accept = .exponent;
                accept_at = p;
                if (!std.ascii.isDigit(c)) break :scan;
            },
            .i => if (c == 'n' or c == 'N') {
                state = .in;
            } else break :scan,
            .in => if (c == 'f' or c == 'F') {
                state = .inf;
            } else break :scan,
            .inf => {
                accept = .inf;
                accept_at = p;
                if (c == 'i' or c == 'I') state = .infi else break :scan;
            },
            .infi => if (c == 'n' or c == 'N') {
                state = .infin;
            } else break :scan,
            .infin => if (c == 'i' or c == 'I') {
                state = .infini;
            } else break :scan,
            .infini => if (c == 't' or c == 'T') {
                state = .infinit;
            } else break :scan,
            .infinit => if (c == 'y' or c == 'Y') {
                state = .infinity;
            } else break :scan,
            .n => if (c == 'a' or c == 'A') {
                state = .na;
            } else break :scan,
            .na => if (c == 'n' or c == 'N') {
                state = .nan;
            } else break :scan,
            .nan => {
                accept = .nan;
                accept_at = p;
                if (c == '(') state = .nan_paren else break :scan;
            },
            .nan_hex, .nan_paren => {
                if (state == .nan_hex and c == ')') {
                    state = .nan_finish;
                } else if (isSpace(c)) {} else if (nan_digits < 13 and std.ascii.isHex(c)) {
                    nan_digits += 1;
                    state = .nan_hex;
                } else break :scan;
            },
            .nan_finish, .infinity => {
                accept = state;
                accept_at = p;
                break :scan;
            },
        }
        if (p >= s.len) break;
    }
    if (accept == .initial) return .{ .ok = false, .end = p, .double = false };
    const double = switch (accept) {
        .fraction, .exponent, .inf, .infinity, .nan, .nan_finish => true,
        else => false,
    };
    return .{ .ok = true, .end = accept_at, .double = double };
}

/// `ParseLexeme`: the lexeme at the start of `s` and its byte count.
fn parseLexeme(s: []const u8, lexeme: *u8) usize {
    if (s.len == 0) {
        lexeme.* = END;
        return 0;
    }
    const b = s[0];
    if (b < 128) {
        const l = lexemeOf(b);
        if (l != 0) {
            lexeme.* = l;
            return 1;
        }
    }
    const next: u8 = if (s.len > 1) s[1] else 0;
    const word_end = s.len == 2 or (s.len > 2 and (s[2] & 0x80 != 0 or !std.ascii.isAlphabetic(s[2])));
    switch (b) {
        '*' => return two(lexeme, next == '*', EXPON, MULT),
        '=' => return two(lexeme, next == '=', EQUAL, INCOMPLETE),
        '!' => return two(lexeme, next == '=', NEQ, NOT),
        '&' => return two(lexeme, next == '&', AND, BIT_AND),
        '|' => return two(lexeme, next == '|', OR, BIT_OR),
        '<' => {
            if (next == '<') return two(lexeme, true, LEFT_SHIFT, 0);
            return two(lexeme, next == '=', LEQ, LESS);
        },
        '>' => {
            if (next == '>') return two(lexeme, true, RIGHT_SHIFT, 0);
            return two(lexeme, next == '=', GEQ, GREATER);
        },
        'i' => if (next == 'n' and word_end) return two(lexeme, true, IN_LIST, 0),
        'e' => if (next == 'q' and word_end) return two(lexeme, true, STREQ, 0),
        'n' => if (s.len > 1 and word_end) {
            if (next == 'e') return two(lexeme, true, STRNEQ, 0);
            if (next == 'i') return two(lexeme, true, NOT_IN_LIST, 0);
        },
        else => {},
    }
    const num = scanNumber(s);
    if (num.ok) {
        var is_number = num.end < s.len and !isBareword(s[num.end]);
        if (!is_number and num.double) {
            for (s[0..num.end]) |c| if (!isBareword(c)) {
                is_number = true;
                break;
            };
        }
        if (!is_number) {
            var l: u8 = 0;
            _ = parseLexeme(s[num.end..], &l);
            is_number = l & NODE_TYPE == BINARY;
        }
        if (is_number) {
            lexeme.* = NUMBER;
            return num.end;
        }
    }
    if (!isBareword(b) or b == '_') {
        var ch: u32 = 0;
        lexeme.* = INVALID;
        return getUtf(s, &ch);
    }
    var e: usize = 0;
    while (e < s.len and isBareword(s[e])) e += 1;
    lexeme.* = BAREWORD;
    return e;
}

fn two(lexeme: *u8, cond: bool, yes: u8, no: u8) usize {
    lexeme.* = if (cond) yes else no;
    return if (cond) 2 else 1;
}

const OT_LITERAL: c_int = -3;
const OT_TOKENS: c_int = -2;
const OT_EMPTY: c_int = -1;

const MARK_LEFT: u8 = 0;
const MARK_RIGHT: u8 = 1;
const MARK_PARENT: u8 = 2;

const OpNode = struct {
    left: c_int = 0,
    right: c_int = 0,
    /// The parent of a complete node, or the previous incomplete node.
    p: c_int = 0,
    lexeme: u8,
    precedence: u8,
    mark: u8,
};

const Nodes = std.ArrayList(OpNode);
const gpa = std.heap.c_allocator;

fn isOperator(i: c_int) bool {
    return i >= 0;
}

const limit: usize = 25;

/// An error message of the expression parser.
const Msg = struct {
    buf: std.ArrayList(u8) = .empty,
    set: bool = false,

    fn print(m: *Msg, comptime fmt: []const u8, args: anytype) void {
        m.buf.print(gpa, fmt, args) catch obj.panicText("out of memory");
        m.set = true;
    }
};

/// `%.*s` of the text of a word for a message, cut to `limit`.
fn cut(s: []const u8) struct { []const u8, []const u8 } {
    return if (s.len < limit) .{ s, "" } else .{ s[0 .. limit - 3], "..." };
}

fn parseExpr(ip: ?*Interp, start0: [*]const u8, n0: usize, nodes: *Nodes, p: *Parse) c_int {
    initParse(ip, start0, n0, p);
    var start = start0;
    var n = n0;
    var msg: Msg = .{};
    defer msg.buf.deinit(gpa);
    var post: Msg = .{};
    // The last words of the error code {TCL PARSE EXPR ...} of Tcl.
    var ecode: struct { ?[]const u8, ?[]const u8 } = .{ null, null };
    defer post.buf.deinit(gpa);
    var scanned: usize = 0;
    var insert_mark = false;
    nodes.append(gpa, .{ .lexeme = START, .precedence = prec(START), .mark = MARK_RIGHT }) catch obj.panicText("out of memory");
    var incomplete: c_int = 0;
    var last: c_int = 0;
    var complete: c_int = OT_EMPTY;
    const mark = "_@_";
    err: {
        while (true) {
            const used: c_int = @intCast(nodes.items.len);
            scanned = allWhiteSpace(start, n);
            start += scanned;
            n -= scanned;
            var lexeme: u8 = 0;
            scanned = parseLexeme(start[0..n], &lexeme);
            if (lexeme & NODE_TYPE == 0) {
                switch (lexeme) {
                    INVALID => {
                        msg.print("invalid character \"{s}\"", .{start[0..scanned]});
                        ecode = .{ "BADCHAR", null };
                        break :err;
                    },
                    INCOMPLETE => {
                        msg.print("incomplete operator \"{s}\"", .{start[0..scanned]});
                        ecode = .{ "PARTOP", null };
                        break :err;
                    },
                    BAREWORD => {
                        const ws = scanned + allWhiteSpace(start + scanned, n - scanned);
                        const word = start[0..scanned];
                        if (ws < n and start[ws] == '(') {
                            lexeme = FUNCTION;
                        } else if (obj.parseBool(word) != null) {
                            lexeme = BOOLEAN;
                        } else {
                            const w = cut(word);
                            msg.print("invalid bareword \"{s}{s}\"", .{ w[0], w[1] });
                            ecode = .{ "BAREWORD", null };
                            post.print("should be \"${s}{s}\" or \"{{{s}{s}}}\" or \"{s}{s}(...)\" or ...", .{ w[0], w[1], w[0], w[1], w[0], w[1] });
                            if (start[0] == '0') {
                                const num = scanNumber(word);
                                const stop: u8 = if (num.end < n) start[num.end] else 0;
                                if (std.ascii.isDigit(stop) or num.end == 1) {
                                    const c1: u8 = if (n > 1) start[1] else 0;
                                    switch (c1) {
                                        'b' => {
                                            post.print(" (invalid binary number?)", .{});
                                            p.errorType = PARSE_BAD_NUMBER;
                                            ecode = .{ "BADNUMBER", "BINARY" };
                                        },
                                        'o' => {
                                            post.print(" (invalid octal number?)", .{});
                                            p.errorType = PARSE_BAD_NUMBER;
                                            ecode = .{ "BADNUMBER", "OCTAL" };
                                        },
                                        else => if (std.ascii.isDigit(c1)) {
                                            post.print(" (invalid octal number?)", .{});
                                            p.errorType = PARSE_BAD_NUMBER;
                                            ecode = .{ "BADNUMBER", "OCTAL" };
                                        },
                                    }
                                }
                            }
                            break :err;
                        }
                    },
                    PLUS, MINUS => lexeme |= if (isOperator(last)) UNARY else BINARY,
                    else => {},
                }
            }
            switch (lexeme & NODE_TYPE) {
                LEAF => {
                    if (!isOperator(last)) {
                        msg.print("missing operator at {s}", .{mark});
                        ecode = .{ "MISSING", null };
                        scanned = 0;
                        insert_mark = true;
                        break :err;
                    }
                    if (lexeme == NUMBER or lexeme == BOOLEAN) {
                        complete = OT_LITERAL;
                        last = OT_LITERAL;
                        start += scanned;
                        n -= scanned;
                        continue;
                    }
                    grow(p, 2);
                    const wi = p.numTokens;
                    tok(p, wi).type = TOKEN_WORD;
                    tok(p, wi).start = start;
                    p.numTokens += 1;
                    var code: c_int = OK;
                    switch (lexeme) {
                        QUOTED => {
                            var end: [*]const u8 = start;
                            code = Tcl_ParseQuotedString(null, start, cint(n), p, 1, &end);
                            scanned = diff(end, start);
                        },
                        BRACED => {
                            var end: [*]const u8 = start;
                            code = Tcl_ParseBraces(null, start, cint(n), p, 1, &end);
                            scanned = diff(end, start);
                        },
                        VARIABLE => {
                            code = Tcl_ParseVarName(null, start, cint(n), p, 1);
                            if (code == OK and tok(p, wi + 1).type != TOKEN_VARIABLE) {
                                msg.print("invalid character \"$\"", .{});
                                ecode = .{ "BADCHAR", null };
                                break :err;
                            }
                            scanned = @intCast(tok(p, wi + 1).size);
                        },
                        SCRIPT => {
                            const ci = p.numTokens;
                            tok(p, ci).* = .{ .type = TOKEN_COMMAND, .start = start, .size = 0, .numComponents = 0 };
                            const end = start + n;
                            var s = start + 1;
                            var nested: Parse = undefined;
                            while (true) {
                                code = Tcl_ParseCommand(ip, s, cint(diff(end, s)), 1, &nested);
                                if (code != OK) {
                                    p.term = nested.term;
                                    p.errorType = nested.errorType;
                                    p.incomplete = nested.incomplete;
                                    break;
                                }
                                s = nested.commandStart.? + @as(usize, @intCast(nested.commandSize));
                                Tcl_FreeParse(&nested);
                                if (@intFromPtr(nested.term) < @intFromPtr(end) and nested.term[0] == ']' and nested.incomplete == 0) break;
                                if (s == end) {
                                    msg.print("missing close-bracket", .{});
                                    ecode = .{ "UNBALANCED", null };
                                    p.term = tok(p, ci).start;
                                    p.errorType = PARSE_MISSING_BRACKET;
                                    p.incomplete = 1;
                                    code = ERROR;
                                    break;
                                }
                            }
                            scanned = diff(s, start);
                            tok(p, ci).size = cint(scanned);
                            p.numTokens += 1;
                        },
                        else => unreachable,
                    }
                    if (code != OK) {
                        start = p.term;
                        scanned = @intCast(p.incomplete);
                        break :err;
                    }
                    const w = tok(p, wi);
                    w.size = cint(scanned);
                    w.numComponents = p.numTokens - wi - 1;
                    complete = OT_TOKENS;
                    last = OT_TOKENS;
                },
                UNARY => {
                    if (!isOperator(last)) {
                        msg.print("missing operator at {s}", .{mark});
                        ecode = .{ "MISSING", null };
                        scanned = 0;
                        insert_mark = true;
                        break :err;
                    }
                    nodes.append(gpa, .{ .lexeme = lexeme, .precedence = prec(lexeme), .mark = MARK_RIGHT, .p = incomplete }) catch obj.panicText("out of memory");
                    incomplete = used;
                    last = used;
                },
                BINARY => {
                    const precedence = prec(lexeme);
                    const items = nodes.items;
                    const u: usize = @intCast(used);
                    if (isOperator(last)) {
                        if (lexeme == CLOSE_PAREN and items[u - 1].lexeme == OPEN_PAREN) {
                            if (items[u - 2].lexeme == FUNCTION) {
                                scanned = 0;
                                complete = OT_EMPTY;
                                last = OT_EMPTY;
                                start += scanned;
                                n -= scanned;
                                continue;
                            }
                            msg.print("empty subexpression at {s}", .{mark});
                            ecode = .{ "EMPTY", null };
                            scanned = 0;
                            insert_mark = true;
                            break :err;
                        }
                        if (items[u - 1].precedence > precedence) {
                            if (items[u - 1].lexeme == OPEN_PAREN) {
                                msg.print("unbalanced open paren", .{});
                                ecode = .{ "UNBALANCED", null };
                                p.errorType = PARSE_MISSING_PAREN;
                            } else if (items[u - 1].lexeme == COMMA) {
                                msg.print("missing function argument at {s}", .{mark});
                                ecode = .{ "MISSING", null };
                                scanned = 0;
                                insert_mark = true;
                            } else if (items[u - 1].lexeme == START) {
                                msg.print("empty expression", .{});
                                ecode = .{ "EMPTY", null };
                            }
                        } else if (lexeme == CLOSE_PAREN) {
                            msg.print("unbalanced close paren", .{});
                            ecode = .{ "UNBALANCED", null };
                        } else if (lexeme == COMMA and items[u - 1].lexeme == OPEN_PAREN and items[u - 2].lexeme == FUNCTION) {
                            msg.print("missing function argument at {s}", .{mark});
                            ecode = .{ "UNBALANCED", null };
                            scanned = 0;
                            insert_mark = true;
                        }
                        if (!msg.set) {
                            msg.print("missing operand at {s}", .{mark});
                            ecode = .{ "MISSING", null };
                            scanned = 0;
                            insert_mark = true;
                        }
                        break :err;
                    }
                    var inc: *OpNode = undefined;
                    while (true) {
                        inc = &items[@intCast(incomplete)];
                        if (inc.precedence < precedence) break;
                        if (inc.precedence == precedence) {
                            if (lexeme == EXPON) break;
                            if (inc.lexeme == QUESTION and (!isOperator(complete) or items[@intCast(complete)].lexeme != COLON)) break;
                            if (inc.lexeme == COLON and lexeme == QUESTION) break;
                        }
                        if (inc.lexeme == OPEN_PAREN and lexeme != CLOSE_PAREN) {
                            msg.print("unbalanced open paren", .{});
                            ecode = .{ "UNBALANCED", null };
                            p.errorType = PARSE_MISSING_PAREN;
                            break :err;
                        }
                        if (inc.lexeme == QUESTION and (!isOperator(complete) or items[@intCast(complete)].lexeme != COLON)) {
                            msg.print("missing operator \":\" at {s}", .{mark});
                            ecode = .{ "MISSING", null };
                            scanned = 0;
                            insert_mark = true;
                            break :err;
                        }
                        if (isOperator(complete) and items[@intCast(complete)].lexeme == COLON and inc.lexeme != QUESTION) {
                            msg.print("unexpected operator \":\" without preceding \"?\"", .{});
                            ecode = .{ "SURPRISE", null };
                            break :err;
                        }
                        inc.right = complete;
                        if (isOperator(complete)) items[@intCast(complete)].p = incomplete;
                        if (inc.lexeme == START) return OK;
                        complete = incomplete;
                        incomplete = inc.p;
                        if (inc.lexeme == OPEN_PAREN) break;
                    }
                    if (lexeme == CLOSE_PAREN and inc.lexeme != OPEN_PAREN) {
                        msg.print("unbalanced close paren", .{});
                        ecode = .{ "UNBALANCED", null };
                        break :err;
                    }
                    if (lexeme == COMMA) {
                        const ii: usize = @intCast(@intFromPtr(inc) - @intFromPtr(items.ptr));
                        const idx = ii / @sizeOf(OpNode);
                        if (inc.lexeme != OPEN_PAREN or idx == 0 or items[idx - 1].lexeme != FUNCTION) {
                            msg.print("unexpected \",\" outside function argument list", .{});
                            ecode = .{ "SURPRISE", null };
                            break :err;
                        }
                    }
                    if (isOperator(complete) and items[@intCast(complete)].lexeme == COLON) {
                        msg.print("unexpected operator \":\" without preceding \"?\"", .{});
                        ecode = .{ "SURPRISE", null };
                        break :err;
                    }
                    if (lexeme != CLOSE_PAREN) {
                        if (isOperator(complete)) items[@intCast(complete)].p = used;
                        nodes.append(gpa, .{ .lexeme = lexeme, .precedence = precedence, .mark = MARK_LEFT, .left = complete, .p = incomplete }) catch obj.panicText("out of memory");
                        incomplete = used;
                        last = used;
                    }
                },
                else => unreachable,
            }
            start += scanned;
            n -= scanned;
        }
    }
    if (p.errorType == PARSE_SUCCESS) p.errorType = PARSE_SYNTAX;
    const i = ip orelse return ERROR;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, if (msg.set) msg.buf.items else obj.text(obj.Tcl_GetObjResult(i))) catch obj.panicText("out of memory");
    const before = diff(start, p.string);
    const end_left = diff(p.end, start);
    const head: []const u8 = if (before < limit) p.string[0..before] else (start - (limit - 3))[0 .. limit - 3];
    const here: []const u8 = start[0..@min(if (scanned < limit) scanned else limit - 3, end_left)];
    const tail_long = scanned + limit <= end_left;
    const tail_len = if (tail_long) limit - 3 else end_left - @min(scanned, end_left);
    const tail = (start + @min(scanned, end_left))[0..tail_len];
    out.print(gpa, "\nin expression \"{s}{s}{s}{s}{s}{s}{s}\"", .{
        if (before < limit) "" else "...",  head,                          here,
        if (scanned < limit) "" else "...", if (insert_mark) mark else "", tail,
        if (tail_long) "..." else "",
    }) catch obj.panicText("out of memory");
    if (post.set) out.print(gpa, ";\n{s}", .{post.buf.items}) catch obj.panicText("out of memory");
    obj.setResultText(i, out.items);
    // An error of a nested word (a quote, a brace, a variable) is
    // UNBALANCED in Tcl.
    if (!msg.set and ecode[0] == null) ecode = .{ "UNBALANCED", null };
    var words: [5][]const u8 = .{ "TCL", "PARSE", "EXPR", "", "" };
    var nw: usize = 3;
    inline for (0..2) |k| if (ecode[k]) |w| {
        words[nw] = w;
        nw += 1;
    };
    const errors = @import("errors.zig");
    errors.setErrorCodeWords(i, words[0..nw]);
    const all = p.string[0..diff(p.end, p.string)];
    const w = cut(all);
    var info: std.ArrayList(u8) = .empty;
    defer info.deinit(gpa);
    info.print(gpa, "\n    (parsing expression \"{s}{s}\")", .{ w[0], w[1] }) catch obj.panicText("out of memory");
    errors.Tcl_AddObjErrorInfo(i, info.items.ptr, @intCast(info.items.len));
    return ERROR;
}

fn convertTree(start0: [*]const u8, n0: usize, nodes: []OpNode, in: [*]Token, p: *Parse) void {
    var start = start0;
    var n = n0;
    var t = in;
    var sub: c_int = 0;
    var node: *OpNode = &nodes[0];
    var next = node.right;
    var lexeme: u8 = 0;
    while (true) {
        node.mark += 1;
        switch (next) {
            OT_EMPTY => {},
            OT_LITERAL => {
                var s = allWhiteSpace(start, n);
                start += s;
                n -= s;
                s = parseLexeme(start[0..n], &lexeme);
                grow(p, 2);
                const k = p.numTokens;
                tok(p, k).* = .{ .type = TOKEN_SUB_EXPR, .start = start, .size = cint(s), .numComponents = 1 };
                tok(p, k + 1).* = .{ .type = TOKEN_TEXT, .start = start, .size = cint(s), .numComponents = 0 };
                p.numTokens += 2;
                start += s;
                n -= s;
            },
            OT_TOKENS => {
                const copy: usize = @intCast(t[0].numComponents + 1);
                if (t[0].numComponents == t[1].numComponents + 1) {
                    grow(p, copy);
                    const k: usize = @intCast(p.numTokens);
                    @memcpy(p.tokenPtr[k .. k + copy], t[0..copy]);
                    p.tokenPtr[k].type = TOKEN_SUB_EXPR;
                    p.numTokens += cint(copy);
                } else {
                    grow(p, copy + 1);
                    const k: usize = @intCast(p.numTokens);
                    p.tokenPtr[k] = t[0];
                    p.tokenPtr[k].type = TOKEN_SUB_EXPR;
                    p.tokenPtr[k].numComponents += 1;
                    @memcpy(p.tokenPtr[k + 1 .. k + 1 + copy], t[0..copy]);
                    p.numTokens += cint(copy + 1);
                }
                const s = diff(t[0].start + @as(usize, @intCast(t[0].size)), start);
                start += s;
                n -= s;
                t += copy;
            },
            else => {
                node = &nodes[@intCast(next)];
                const s = allWhiteSpace(start, n);
                start += s;
                n -= s;
                switch (node.lexeme) {
                    OPEN_PAREN, COMMA, COLON => {},
                    else => {
                        const parent = sub;
                        grow(p, 2);
                        sub = p.numTokens;
                        p.numTokens += 2;
                        tok(p, sub).type = TOKEN_SUB_EXPR;
                        tok(p, sub).start = start;
                        tok(p, sub + 1).type = TOKEN_OPERATOR;
                        tok(p, sub + 1).numComponents = parent;
                    },
                }
            },
        }
        while (true) {
            switch (node.mark) {
                MARK_LEFT => next = node.left,
                MARK_RIGHT => {
                    next = node.right;
                    var s = allWhiteSpace(start, n);
                    start += s;
                    n -= s;
                    s = parseLexeme(start[0..n], &lexeme);
                    switch (node.lexeme) {
                        OPEN_PAREN, COMMA, COLON => {},
                        else => {
                            tok(p, sub + 1).start = start;
                            tok(p, sub + 1).size = cint(s);
                        },
                    }
                    start += s;
                    n -= s;
                },
                else => {
                    switch (node.lexeme) {
                        START => return,
                        COMMA, COLON => {},
                        OPEN_PAREN => {
                            var s = allWhiteSpace(start, n);
                            start += s;
                            n -= s;
                            s = parseLexeme(start[0..n], &lexeme);
                            start += s;
                            n -= s;
                        },
                        else => {
                            const k = tok(p, sub);
                            k.size = cint(diff(start, k.start));
                            k.numComponents = p.numTokens - sub - 1;
                            const parent = tok(p, sub + 1).numComponents;
                            tok(p, sub + 1).numComponents = 0;
                            sub = parent;
                        },
                    }
                    node = &nodes[@intCast(node.p)];
                    continue;
                },
            }
            break;
        }
    }
}

pub fn Tcl_ParseExpr(ip: ?*Interp, start0: ?[*]const u8, len: c_int, p: *Parse) callconv(.c) c_int {
    const start: [*]const u8 = start0 orelse "";
    const n: usize = if (len < 0) (if (start0) |s| std.mem.len(@as([*:0]const u8, @ptrCast(s))) else 0) else @intCast(len);
    var nodes: Nodes = .empty;
    defer nodes.deinit(gpa);
    var ep: Parse = undefined;
    const code = parseExpr(ip, start, n, &nodes, &ep);
    initParse(ip, start, n, p);
    if (code == OK) {
        convertTree(start, n, nodes.items, ep.tokenPtr, p);
    } else {
        p.term = ep.term;
        p.errorType = ep.errorType;
    }
    Tcl_FreeParse(&ep);
    return code;
}

// ---- Tcl_ParseArgsObjv ----

const ARGV_CONSTANT: c_int = 15;
const ARGV_INT: c_int = 16;
const ARGV_STRING: c_int = 17;
const ARGV_REST: c_int = 18;
const ARGV_FLOAT: c_int = 19;
const ARGV_FUNC: c_int = 20;
const ARGV_GENFUNC: c_int = 21;
const ARGV_HELP: c_int = 22;
const ARGV_END: c_int = 23;

/// `Tcl_ArgvInfo`.
pub const ArgvInfo = extern struct {
    type: c_int,
    keyStr: ?[*:0]const u8,
    srcPtr: ?*anyopaque,
    dstPtr: ?*anyopaque,
    helpStr: ?[*:0]const u8,
    clientData: ?*anyopaque,
};

const ArgvFunc = *const fn (?*anyopaque, ?*Obj, ?*anyopaque) callconv(.c) c_int;
const ArgvGenFunc = *const fn (?*anyopaque, *Interp, c_int, [*]const *Obj, ?*anyopaque) callconv(.c) c_int;

fn setMsgf(ip: *Interp, comptime fmt: []const u8, args: anytype) void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    b.print(gpa, fmt, args) catch obj.panicText("out of memory");
    obj.setResultText(ip, b.items);
}

pub fn Tcl_ParseArgsObjv(ip: *Interp, table: [*]const ArgvInfo, objc_ptr: *c_int, objv: [*]const *Obj, rem: ?*[*]*Obj) callconv(.c) c_int {
    const total: usize = @intCast(objc_ptr.*);
    var left: ?[*]*Obj = null;
    var nrem: usize = 0;
    if (rem != null) {
        left = @ptrCast(@alignCast(std.c.malloc((1 + total) * @sizeOf(*Obj)) orelse obj.panicText("out of memory")));
        left.?[0] = objv[0];
        nrem = 1;
    }
    var src: usize = 1;
    var dst: c_int = 1;
    var objc: usize = total -| 1;
    var str: []const u8 = "";
    ok: {
        while (objc > 0) {
            const cur = objv[src];
            src += 1;
            objc -= 1;
            str = obj.text(cur);
            const c: u8 = if (str.len > 1) str[1] else 0;
            var match: ?*const ArgvInfo = null;
            var info = table;
            const found: ?*const ArgvInfo = while (info[0].type != ARGV_END) : (info += 1) {
                const key = info[0].keyStr orelse continue;
                if (key[1] != c or !prefixOf(key, str)) continue;
                if (key[str.len] == 0) break &info[0];
                if (match != null) {
                    setMsgf(ip, "ambiguous option \"{s}\"", .{str});
                    return argvError(left);
                }
                match = &info[0];
            } else match;
            const m = found orelse {
                if (rem == null) {
                    setMsgf(ip, "unrecognized argument \"{s}\"", .{str});
                    return argvError(left);
                }
                dst += 1;
                left.?[nrem] = cur;
                nrem += 1;
                continue;
            };
            const key = std.mem.span(m.keyStr.?);
            switch (m.type) {
                ARGV_CONSTANT => @as(*c_int, @ptrCast(@alignCast(m.dstPtr))).* = @truncate(@as(isize, @bitCast(if (m.srcPtr) |s| @intFromPtr(s) else 0))),
                ARGV_INT => {
                    if (objc == 0) break :ok;
                    if (obj.Tcl_GetIntFromObj(ip, objv[src], @ptrCast(@alignCast(m.dstPtr))) != OK) {
                        setMsgf(ip, "expected integer argument for \"{s}\" but got \"{s}\"", .{ key, obj.text(objv[src]) });
                        return argvError(left);
                    }
                    src += 1;
                    objc -= 1;
                },
                ARGV_STRING => {
                    if (objc == 0) break :ok;
                    @as(*[*:0]const u8, @ptrCast(@alignCast(m.dstPtr))).* = obj.Tcl_GetString(objv[src]);
                    src += 1;
                    objc -= 1;
                },
                ARGV_REST => {
                    if (m.dstPtr) |d| @as(*c_int, @ptrCast(@alignCast(d))).* = dst;
                    break;
                },
                ARGV_FLOAT => {
                    if (objc == 0) break :ok;
                    if (obj.Tcl_GetDoubleFromObj(ip, objv[src], @ptrCast(@alignCast(m.dstPtr))) != OK) {
                        setMsgf(ip, "expected floating-point argument for \"{s}\" but got \"{s}\"", .{ key, obj.text(objv[src]) });
                        return argvError(left);
                    }
                    src += 1;
                    objc -= 1;
                },
                ARGV_FUNC => {
                    const f: ArgvFunc = @ptrCast(@alignCast(m.srcPtr));
                    if (f(m.clientData, if (objc == 0) null else objv[src], m.dstPtr) != 0) {
                        src += 1;
                        objc -= 1;
                    }
                },
                ARGV_GENFUNC => {
                    const f: ArgvGenFunc = @ptrCast(@alignCast(m.srcPtr));
                    const r = f(m.clientData, ip, @intCast(objc), objv + src, m.dstPtr);
                    if (r < 0) return argvError(left);
                    src += @intCast(r);
                    objc -= @intCast(r);
                },
                ARGV_HELP => {
                    usage(ip, table);
                    return argvError(left);
                },
                else => {
                    setMsgf(ip, "bad argument type {d} in Tcl_ArgvInfo", .{m.type});
                    return argvError(left);
                },
            }
        }
        const out = rem orelse return OK;
        if (objc > 0) {
            @memcpy(left.?[nrem .. nrem + objc], objv[src .. src + objc]);
            nrem += objc;
        }
        objc_ptr.* = cint(nrem);
        @as([*]?*Obj, @ptrCast(left.?))[nrem] = null;
        out.* = left.?;
        return OK;
    }
    setMsgf(ip, "\"{s}\" option requires an additional argument", .{str});
    return argvError(left);
}

/// `strncmp(key, s, len(s)) == 0`.
fn prefixOf(key: [*:0]const u8, s: []const u8) bool {
    for (s, 0..) |c, i| {
        if (key[i] != c) return false;
        if (c == 0) return true;
    }
    return true;
}

fn argvError(left: ?[*]*Obj) c_int {
    if (left) |l| std.c.free(@ptrCast(l));
    return ERROR;
}

fn usage(ip: *Interp, table: [*]const ArgvInfo) void {
    var width: usize = 4;
    var info = table;
    while (info[0].type != ARGV_END) : (info += 1) {
        if (info[0].keyStr) |k| width = @max(width, std.mem.len(k));
    }
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    b.appendSlice(gpa, "Command-specific options:") catch obj.panicText("out of memory");
    info = table;
    while (info[0].type != ARGV_END) : (info += 1) {
        const m = &info[0];
        const help: []const u8 = if (m.helpStr) |h| std.mem.span(h) else "(null)";
        if (m.type == ARGV_HELP and m.keyStr == null) {
            b.print(gpa, "\n{s}", .{help}) catch obj.panicText("out of memory");
            continue;
        }
        const key: []const u8 = if (m.keyStr) |k| std.mem.span(k) else "(null)";
        b.print(gpa, "\n {s}:", .{key}) catch obj.panicText("out of memory");
        b.appendNTimes(gpa, ' ', width + 1 -| key.len) catch obj.panicText("out of memory");
        b.appendSlice(gpa, help) catch obj.panicText("out of memory");
        switch (m.type) {
            ARGV_INT => b.print(gpa, "\n\t\tDefault value: {d}", .{@as(*const c_int, @ptrCast(@alignCast(m.dstPtr))).*}) catch obj.panicText("out of memory"),
            ARGV_FLOAT => {
                var g: [64]u8 = undefined;
                const len = snprintf(&g, g.len, "%g", @as(*const f64, @ptrCast(@alignCast(m.dstPtr))).*);
                b.print(gpa, "\n\t\tDefault value: {s}", .{g[0..@intCast(len)]}) catch obj.panicText("out of memory");
            },
            ARGV_STRING => if (@as(*const ?[*:0]const u8, @ptrCast(@alignCast(m.dstPtr))).*) |s| {
                b.print(gpa, "\n\t\tDefault value: \"{s}\"", .{std.mem.span(s)}) catch obj.panicText("out of memory");
            },
            else => {},
        }
    }
    obj.setResultText(ip, b.items);
}

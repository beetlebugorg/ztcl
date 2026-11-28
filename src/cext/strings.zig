//! The string slots of the stubs table of Tcl 8.6: format and append,
//! the UTF-8 and `Tcl_UniChar` functions, the classes and the case maps
//! of characters, glob matches, backslashes, and the Unicode form of an
//! object. The native path (`stubs.zig`) and the WebAssembly path
//! (`wasm_stubs.zig`) use this one file.
//!
//! The text of Tcl is modified UTF-8: U+0000 is C0 80, and a byte that
//! does not start a whole sequence is one character with the value of
//! the byte. A `Tcl_UniChar` has 16 bits (`TCL_UTF_MAX` 3), so a
//! character above U+FFFF is a pair of surrogates in a `Tcl_UniChar`
//! array. `format` of ztcl (`render` of `src/format.zig`) makes the text
//! of Tcl_Format, with the objects of the package as its arguments.
//! Tcl_ObjPrintf reads its C arguments by the conversions of the format
//! string, makes an object of each one, and gives them to the same
//! function. The Unicode form is the internal form of the type "string":
//! the `Tcl_UniChar` array of the text, with a 0 at the end.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const obj = @import("obj.zig");
const value = @import("../value.zig");
const format = @import("../format.zig");
const ucd = @import("../ucd.zig");
const cmds = @import("../cmds.zig");
const parse = @import("parse.zig");

const Obj = obj.Obj;
const Interp = obj.Interp;
const DString = obj.DString;
const Value = value.Value;
const OK = obj.OK;
const ERROR = obj.ERROR;
const gpa = std.heap.c_allocator;
const panicText = obj.panicText;

/// `Tcl_UniChar`.
pub const UniChar = u16;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();

fn span(p: [*]const u8, length: c_int) []const u8 {
    return if (length < 0) std.mem.span(@as([*:0]const u8, @ptrCast(p))) else p[0..@intCast(length)];
}

// ---- Characters of modified UTF-8 ----

/// One character at the start of `s`, which is not empty: its code
/// point and its byte count.
const Char = struct { cp: u21, len: usize };

fn decode(s: []const u8) Char {
    const c = s[0];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    const more: usize = if (c >= 0xC0 and c < 0xE0) 1 else if (c >= 0xE0 and c < 0xF0) 2 else if (c >= 0xF0 and c < 0xF8) 3 else 0;
    if (more == 0 or more >= s.len) return .{ .cp = c, .len = 1 };
    var cp: u21 = c & (@as(u8, 0x3F) >> @intCast(more));
    for (s[1..][0..more]) |b| {
        if (b & 0xC0 != 0x80) return .{ .cp = c, .len = 1 };
        cp = (cp << 6) | (b & 0x3F);
    }
    if (more == 3 and cp > 0x10FFFF) return .{ .cp = c, .len = 1 };
    return .{ .cp = cp, .len = 1 + more };
}

/// The bytes of `cp` in `buf`: U+0000 is C0 80.
fn encode(cp: u21, buf: *[4]u8) usize {
    if (cp == 0) {
        buf.* = .{ 0xC0, 0x80, 0, 0 };
        return 2;
    }
    if (cp < 0x80) {
        buf[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        buf[0] = @intCast(0xC0 | (cp >> 6));
        buf[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        buf[0] = @intCast(0xE0 | (cp >> 12));
        buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    buf[0] = @intCast(0xF0 | (cp >> 18));
    buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    buf[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

/// The byte count of the NUL-terminated text at `p`, at most `max`.
fn cLen(p: [*]const u8, max: usize) usize {
    var n: usize = 0;
    while (n < max and p[n] != 0) n += 1;
    return n;
}

/// One character of the NUL-terminated text at `p`. The bytes after a
/// 0 byte are not read.
fn decodeAt(p: [*]const u8) Char {
    return decode(p[0..@max(cLen(p, 4), 1)]);
}

/// Appends the `Tcl_UniChar` array of `s` to `out`.
fn toUni(out: *std.ArrayList(UniChar), s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        const d = decode(s[i..]);
        i += d.len;
        if (d.cp > 0xFFFF) {
            const v = d.cp - 0x10000;
            out.appendSlice(gpa, &.{ @intCast(0xD800 + (v >> 10)), @intCast(0xDC00 + (v & 0x3FF)) }) catch panicText("out of memory");
        } else out.append(gpa, @intCast(d.cp)) catch panicText("out of memory");
    }
}

/// Appends the text of the `Tcl_UniChar` array `u` to `out`.
fn fromUni(out: *std.ArrayList(u8), u: []const UniChar) void {
    var i: usize = 0;
    while (i < u.len) : (i += 1) {
        var cp: u21 = u[i];
        if (cp >= 0xD800 and cp < 0xDC00 and i + 1 < u.len and u[i + 1] >= 0xDC00 and u[i + 1] < 0xE000) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (u[i + 1] - 0xDC00);
            i += 1;
        }
        var b: [4]u8 = undefined;
        out.appendSlice(gpa, b[0..encode(cp, &b)]) catch panicText("out of memory");
    }
}

fn uniSpan(u: [*]const UniChar, length: c_int) []const UniChar {
    if (length >= 0) return u[0..@intCast(length)];
    var n: usize = 0;
    while (u[n] != 0) n += 1;
    return u[0..n];
}

pub fn Tcl_NumUtfChars(src: [*]const u8, length: c_int) callconv(.c) c_int {
    return @intCast(obj.charCount(span(src, length)));
}

pub fn Tcl_UtfToUniChar(src: [*]const u8, ch: *UniChar) callconv(.c) c_int {
    const d = decodeAt(src);
    if (d.cp > 0xFFFF) {
        // A character above U+FFFF has no one `Tcl_UniChar`: the first
        // byte stands for itself.
        ch.* = src[0];
        return 1;
    }
    ch.* = @intCast(d.cp);
    return @intCast(d.len);
}

pub fn Tcl_UniCharToUtf(ch: c_int, buf: [*]u8) callconv(.c) c_int {
    const cp: u21 = if (ch < 0 or ch > 0x10FFFF) 0xFFFD else @intCast(ch);
    var b: [4]u8 = undefined;
    const n = encode(cp, &b);
    @memcpy(buf[0..n], b[0..n]);
    return @intCast(n);
}

pub fn Tcl_UniCharToUtfDString(u: [*]const UniChar, length: c_int, ds: *DString) callconv(.c) [*:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    fromUni(&out, uniSpan(u, length));
    obj.dsAppend(ds, out.items);
    return @ptrCast(ds.string);
}

pub fn Tcl_UtfToUniCharDString(src: [*]const u8, length: c_int, ds: *DString) callconv(.c) [*:0]UniChar {
    var u: std.ArrayList(UniChar) = .empty;
    defer u.deinit(gpa);
    toUni(&u, span(src, length));
    u.append(gpa, 0) catch panicText("out of memory");
    const bytes = std.mem.sliceAsBytes(u.items);
    // The array starts at an even offset of the string of the DString.
    const old: usize = @intCast(ds.length);
    const at = (old + 1) & ~@as(usize, 1);
    obj.dsReserve(ds, at + bytes.len);
    @memset(ds.string[old..at], 0);
    @memcpy(ds.string[at..][0..bytes.len], bytes);
    ds.length = @intCast(at + bytes.len - 2);
    return @ptrCast(@alignCast(ds.string + at));
}

pub fn Tcl_UniCharLen(u: [*]const UniChar) callconv(.c) c_int {
    return @intCast(uniSpan(u, -1).len);
}

pub fn Tcl_UniCharNcmp(a: [*]const UniChar, b: [*]const UniChar, n: c_ulong) callconv(.c) c_int {
    for (0..n) |i| if (a[i] != b[i]) return @as(c_int, a[i]) - @as(c_int, b[i]);
    return 0;
}

pub fn Tcl_UniCharNcasecmp(a: [*]const UniChar, b: [*]const UniChar, n: c_ulong) callconv(.c) c_int {
    for (0..n) |i| {
        if (a[i] == b[i]) continue;
        const x: c_int = ucd.toLower(a[i]);
        const y: c_int = ucd.toLower(b[i]);
        if (x != y) return x - y;
    }
    return 0;
}

/// The address of character `index` of the text at `src`.
fn atIndex(src: [*]const u8, index: c_int) [*]const u8 {
    var p = src;
    var k: c_int = 0;
    while (k < index) : (k += 1) p += decodeAt(p).len;
    return p;
}

pub fn Tcl_UtfAtIndex(src: [*]const u8, index: c_int) callconv(.c) [*]const u8 {
    return atIndex(src, index);
}

pub fn Tcl_UniCharAtIndex(src: [*]const u8, index: c_int) callconv(.c) UniChar {
    var ch: UniChar = 0;
    _ = Tcl_UtfToUniChar(atIndex(src, index), &ch);
    return ch;
}

pub fn Tcl_UtfCharComplete(src: [*]const u8, length: c_int) callconv(.c) c_int {
    if (length <= 0) return 0;
    const c = src[0];
    const need: c_int = if (c < 0xC0) 1 else if (c < 0xE0) 2 else if (c < 0xF0) 3 else if (c < 0xF8) 4 else 1;
    return @intFromBool(length >= need);
}

pub fn Tcl_UtfNext(src: [*]const u8) callconv(.c) [*]const u8 {
    if (src[0] == 0) return src;
    return src + decodeAt(src).len;
}

pub fn Tcl_UtfPrev(src: [*]const u8, start: [*]const u8) callconv(.c) [*]const u8 {
    if (@intFromPtr(src) <= @intFromPtr(start)) return src;
    // The start of the last whole character before `src`.
    var back: usize = 1;
    while (back <= 4 and @intFromPtr(src) - back >= @intFromPtr(start)) : (back += 1) {
        const p = src - back;
        if (p[0] & 0xC0 != 0x80) {
            if (p + decode(p[0..back]).len == src) return p;
            break;
        }
    }
    return src - 1;
}

pub fn Tcl_UtfFindFirst(src: [*]const u8, ch: c_int) callconv(.c) ?[*]const u8 {
    var p = src;
    while (true) {
        const d = decodeAt(p);
        if (d.cp == ch and !(p[0] == 0 and ch != 0)) return p;
        if (p[0] == 0) return null;
        p += d.len;
    }
}

pub fn Tcl_UtfFindLast(src: [*]const u8, ch: c_int) callconv(.c) ?[*]const u8 {
    var p = src;
    var last: ?[*]const u8 = null;
    while (true) {
        const d = decodeAt(p);
        if (d.cp == ch) last = p;
        if (p[0] == 0) return last;
        p += d.len;
    }
}

/// Maps each character of the NUL-terminated text at `src` with `f`, in
/// place, and gives the new byte count. A character whose map has more
/// bytes stays as it is.
fn mapCase(src: [*]u8, comptime f: fn (u21) u21, comptime first: ?fn (u21) u21) c_int {
    var r: usize = 0;
    var w: usize = 0;
    while (src[r] != 0) {
        const d = decodeAt(src + r);
        const m = if (first != null and r == 0) first.?(d.cp) else f(d.cp);
        var b: [4]u8 = undefined;
        const n = encode(m, &b);
        if (n <= d.len) {
            @memcpy(src[w..][0..n], b[0..n]);
            w += n;
        } else {
            std.mem.copyForwards(u8, src[w..][0..d.len], src[r..][0..d.len]);
            w += d.len;
        }
        r += d.len;
    }
    src[w] = 0;
    return @intCast(w);
}

fn lower(c: u21) u21 {
    return ucd.toLower(c);
}
fn upper(c: u21) u21 {
    return ucd.toUpper(c);
}
fn title(c: u21) u21 {
    return ucd.toTitle(c);
}
fn lowerAfterTitle(c: u21) u21 {
    return ucd.toLowerAfterTitle(c);
}

pub fn Tcl_UtfToLower(src: [*]u8) callconv(.c) c_int {
    return mapCase(src, lower, null);
}

pub fn Tcl_UtfToUpper(src: [*]u8) callconv(.c) c_int {
    return mapCase(src, upper, null);
}

pub fn Tcl_UtfToTitle(src: [*]u8) callconv(.c) c_int {
    return mapCase(src, lowerAfterTitle, title);
}

/// The order of the first `n` characters of `a` and `b`, by code point.
fn utfCompare(a0: [*]const u8, b0: [*]const u8, n: c_ulong, nocase: bool) c_int {
    var a = a0;
    var b = b0;
    var k: c_ulong = 0;
    while (k < n) : (k += 1) {
        const x = decodeAt(a);
        const y = decodeAt(b);
        var cx: c_int = @intCast(x.cp);
        var cy: c_int = @intCast(y.cp);
        if (a[0] == 0) cx = 0;
        if (b[0] == 0) cy = 0;
        if (cx != cy and nocase) {
            cx = ucd.toLower(@intCast(cx));
            cy = ucd.toLower(@intCast(cy));
        }
        if (cx != cy) return cx - cy;
        if (a[0] == 0) return 0;
        a += x.len;
        b += y.len;
    }
    return 0;
}

pub fn Tcl_UtfNcmp(a: [*]const u8, b: [*]const u8, n: c_ulong) callconv(.c) c_int {
    return utfCompare(a, b, n, false);
}

pub fn Tcl_UtfNcasecmp(a: [*]const u8, b: [*]const u8, n: c_ulong) callconv(.c) c_int {
    return utfCompare(a, b, n, true);
}

// ---- Classes and case maps ----

fn cpOf(ch: c_int) u21 {
    return @intCast(ch & 0xFFFF);
}

pub fn Tcl_UniCharToLower(ch: c_int) callconv(.c) UniChar {
    return @intCast(ucd.toLower(cpOf(ch)) & 0xFFFF);
}
pub fn Tcl_UniCharToUpper(ch: c_int) callconv(.c) UniChar {
    return @intCast(ucd.toUpper(cpOf(ch)) & 0xFFFF);
}
pub fn Tcl_UniCharToTitle(ch: c_int) callconv(.c) UniChar {
    return @intCast(ucd.toTitle(cpOf(ch)) & 0xFFFF);
}
pub fn Tcl_UniCharIsAlnum(ch: c_int) callconv(.c) c_int {
    return @intFromBool(ucd.isAlpha(cpOf(ch)) or ucd.isDigit(cpOf(ch)));
}
pub fn Tcl_UniCharIsAlpha(ch: c_int) callconv(.c) c_int {
    return @intFromBool(ucd.isAlpha(cpOf(ch)));
}
pub fn Tcl_UniCharIsDigit(ch: c_int) callconv(.c) c_int {
    return @intFromBool(ucd.isDigit(cpOf(ch)));
}
pub fn Tcl_UniCharIsLower(ch: c_int) callconv(.c) c_int {
    return @intFromBool(ucd.isLower(cpOf(ch)));
}
pub fn Tcl_UniCharIsUpper(ch: c_int) callconv(.c) c_int {
    return @intFromBool(ucd.isUpper(cpOf(ch)));
}
pub fn Tcl_UniCharIsSpace(ch: c_int) callconv(.c) c_int {
    return @intFromBool(ucd.isSpace(cpOf(ch)));
}
pub fn Tcl_UniCharIsWordChar(ch: c_int) callconv(.c) c_int {
    return @intFromBool(ucd.isWordChar(cpOf(ch)));
}
pub fn Tcl_UniCharIsControl(ch: c_int) callconv(.c) c_int {
    return @intFromBool(ucd.isControl(cpOf(ch)));
}
pub fn Tcl_UniCharIsGraph(ch: c_int) callconv(.c) c_int {
    return @intFromBool(ucd.isGraph(cpOf(ch)));
}
pub fn Tcl_UniCharIsPrint(ch: c_int) callconv(.c) c_int {
    return @intFromBool(ucd.isPrint(cpOf(ch)));
}
pub fn Tcl_UniCharIsPunct(ch: c_int) callconv(.c) c_int {
    return @intFromBool(ucd.isPunct(cpOf(ch)));
}

// ---- Matches, backslashes, and doubles ----

pub fn Tcl_StringMatch(s: [*:0]const u8, pattern: [*:0]const u8) callconv(.c) c_int {
    return @intFromBool(cmds.globMatch(std.mem.span(pattern), std.mem.span(s), false));
}

pub fn Tcl_StringCaseMatch(s: [*:0]const u8, pattern: [*:0]const u8, nocase: c_int) callconv(.c) c_int {
    return @intFromBool(cmds.globMatch(std.mem.span(pattern), std.mem.span(s), nocase != 0));
}

pub fn Tcl_UniCharCaseMatch(s: [*]const UniChar, pattern: [*]const UniChar, nocase: c_int) callconv(.c) c_int {
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    fromUni(&a, uniSpan(s, -1));
    fromUni(&b, uniSpan(pattern, -1));
    return @intFromBool(cmds.globMatch(b.items, a.items, nocase != 0));
}

pub fn Tcl_UtfBackslash(src: [*]const u8, read: ?*c_int, dst: [*]u8) callconv(.c) c_int {
    var n: usize = 0;
    var buf: [4]u8 = undefined;
    const len = parse.parseBackslash(src, cLen(src, 16), &n, &buf);
    @memcpy(dst[0..len], buf[0..len]);
    if (read) |r| r.* = @intCast(n);
    return @intCast(len);
}

pub fn Tcl_Backslash(src: [*]const u8, read: ?*c_int) callconv(.c) u8 {
    var buf: [4]u8 = undefined;
    const len: usize = @intCast(Tcl_UtfBackslash(src, read, &buf));
    var ch: UniChar = 0;
    _ = Tcl_UtfToUniChar(buf[0..len].ptr, &ch);
    return @truncate(ch);
}

/// `TCL_DOUBLE_SPACE` of `tcl.h`.
const double_space = 27;

pub fn Tcl_PrintDouble(_: ?*Interp, d: f64, dst: [*]u8) callconv(.c) void {
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const s = value.formatDouble(fba.allocator(), d) catch unreachable;
    const n = @min(s.len, double_space - 1);
    @memcpy(dst[0..n], s[0..n]);
    dst[n] = 0;
}

// ---- The Unicode form of an object ----

const UniRep = struct {
    /// The characters and a 0 at the end.
    chars: std.ArrayList(UniChar) = .empty,
};

fn uniRep(o: *Obj) *UniRep {
    return @ptrCast(@alignCast(o.rep.two.p1.?));
}

fn freeUni(o: *Obj) callconv(.c) void {
    const r = uniRep(o);
    r.chars.deinit(gpa);
    gpa.destroy(r);
}

fn dupUni(src: *Obj, dst: *Obj) callconv(.c) void {
    const r = gpa.create(UniRep) catch panicText("out of memory");
    r.* = .{ .chars = uniRep(src).chars.clone(gpa) catch panicText("out of memory") };
    dst.rep = .{ .two = .{ .p1 = r, .p2 = null } };
    dst.typePtr = &string_type;
}

fn updateUni(o: *Obj) callconv(.c) void {
    const u = uniRep(o).chars.items;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    fromUni(&out, u[0 .. u.len - 1]);
    obj.setText(o, out.items);
}

/// The type of the Unicode form.
pub const string_type: obj.ObjType = .{ .name = "string", .free = &freeUni, .dup = &dupUni, .update = &updateUni, .set_from_any = null };

/// The Unicode form of `o`, made on demand.
fn uniOf(o: *Obj) []UniChar {
    if (o.typePtr != &string_type) {
        const r = gpa.create(UniRep) catch panicText("out of memory");
        r.* = .{};
        toUni(&r.chars, obj.text(o));
        r.chars.append(gpa, 0) catch panicText("out of memory");
        obj.shimmer(o, &string_type, .{ .two = .{ .p1 = r, .p2 = null } });
    }
    const u = uniRep(o).chars.items;
    return u[0 .. u.len - 1];
}

/// Sets `o` to the characters `u`: no text form until one is asked for.
fn setUni(o: *Obj, u: []const UniChar) void {
    obj.freeIntRep(o);
    obj.invalidate(o);
    const r = gpa.create(UniRep) catch panicText("out of memory");
    r.* = .{};
    r.chars.appendSlice(gpa, u) catch panicText("out of memory");
    r.chars.append(gpa, 0) catch panicText("out of memory");
    o.typePtr = &string_type;
    o.rep = .{ .two = .{ .p1 = r, .p2 = null } };
}

pub fn Tcl_NewUnicodeObj(u: [*]const UniChar, n: c_int) callconv(.c) *Obj {
    const o = obj.newObj();
    setUni(o, uniSpan(u, n));
    return o;
}

pub fn Tcl_SetUnicodeObj(o: *Obj, u: [*]const UniChar, n: c_int) callconv(.c) void {
    if (o.refCount > 1) panicText("Tcl_SetUnicodeObj called with shared object");
    setUni(o, uniSpan(u, n));
}

pub fn Tcl_GetUnicodeFromObj(o: *Obj, len: ?*c_int) callconv(.c) [*:0]UniChar {
    const u = uniOf(o);
    if (len) |l| l.* = @intCast(u.len);
    return @ptrCast(u.ptr);
}

pub fn Tcl_GetUnicode(o: *Obj) callconv(.c) [*:0]UniChar {
    return Tcl_GetUnicodeFromObj(o, null);
}

pub fn Tcl_GetUniChar(o: *Obj, index: c_int) callconv(.c) UniChar {
    const u = uniOf(o);
    if (index < 0 or index >= u.len) return 0;
    return u[@intCast(index)];
}

pub fn Tcl_GetRange(o: *Obj, first: c_int, last: c_int) callconv(.c) *Obj {
    const u = uniOf(o);
    const f: usize = @intCast(@max(first, 0));
    const l: isize = @min(@as(isize, last), @as(isize, @intCast(u.len)) - 1);
    if (l < @as(isize, @intCast(f))) return obj.Tcl_NewObj();
    const r = obj.Tcl_NewObj();
    setUni(r, u[f..@intCast(l + 1)]);
    return r;
}

pub fn Tcl_AppendUnicodeToObj(o: *Obj, u: [*]const UniChar, n: c_int) callconv(.c) void {
    if (o.refCount > 1) panicText("Tcl_AppendUnicodeToObj called with shared object");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    fromUni(&out, uniSpan(u, n));
    obj.appendText(o, out.items);
}

// ---- Format and append ----

/// The objects of a package as the arguments of `format.render`.
const ObjArgs = struct {
    objv: []const *Obj,
    a: std.mem.Allocator,
    msg: *[]const u8,

    pub fn str(s: ObjArgs, k: usize) error{ Format, OutOfMemory }![]const u8 {
        return obj.text(s.objv[k]);
    }
    pub fn int(s: ObjArgs, k: usize) error{ Format, OutOfMemory }!i64 {
        var w: i64 = 0;
        if (obj.Tcl_GetWideIntFromObj(null, s.objv[k], &w) != OK) return s.fail("expected integer but got \"{s}\"", .{obj.text(s.objv[k])});
        return w;
    }
    pub fn intArg(s: ObjArgs, k: usize) error{ Format, OutOfMemory }!Value {
        return .{ .int = try s.int(k) };
    }
    pub fn low64(_: ObjArgs, v: Value) error{ Format, OutOfMemory }!i64 {
        return v.int;
    }
    pub fn digits(s: ObjArgs, v: Value, base: u8, case: std.fmt.Case) error{ Format, OutOfMemory }![]const u8 {
        var buf: [72]u8 = undefined;
        const neg = v.int < 0;
        const n = std.fmt.printInt(buf[1..], @abs(v.int), base, case, .{});
        buf[0] = '-';
        return s.a.dupe(u8, buf[@intFromBool(!neg) .. 1 + n]);
    }
    pub fn number(s: ObjArgs, k: usize) error{ Format, OutOfMemory }!?Value {
        var d: f64 = 0;
        if (obj.Tcl_GetDoubleFromObj(null, s.objv[k], &d) != OK) return null;
        return .{ .double = d };
    }
    pub fn fail(s: ObjArgs, comptime fmt: []const u8, args: anytype) error{ Format, OutOfMemory } {
        s.msg.* = try std.fmt.allocPrint(s.a, fmt, args);
        return error.Format;
    }
};

pub fn Tcl_AppendFormatToObj(ip: ?*Interp, o: *Obj, fmt: [*:0]const u8, objc: c_int, objv: ?[*]const *Obj) callconv(.c) c_int {
    if (o.refCount > 1) panicText("Tcl_AppendFormatToObj called with shared object");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var msg: []const u8 = "";
    const n: usize = @intCast(@max(objc, 0));
    const src: ObjArgs = .{ .objv = if (objv) |v| v[0..n] else &.{}, .a = arena.allocator(), .msg = &msg };
    const out = format.render(src, arena.allocator(), std.mem.span(fmt), n) catch |e| {
        if (e == error.OutOfMemory) panicText("out of memory");
        if (ip) |i| obj.setResultText(i, msg);
        return ERROR;
    };
    obj.appendText(o, out);
    return OK;
}

pub fn Tcl_Format(ip: ?*Interp, fmt: [*:0]const u8, objc: c_int, objv: ?[*]const *Obj) callconv(.c) ?*Obj {
    const o = obj.Tcl_NewObj();
    if (Tcl_AppendFormatToObj(ip, o, fmt, objc, objv) != OK) {
        obj.incr(o);
        obj.decr(o);
        return null;
    }
    return o;
}

/// Reads the C arguments of the conversions of `fmt` from `ap` into
/// objects, as `format` reads them: an int, a long, a long long, a
/// double, or the text of a `char *`.
fn printfArgs(list: *std.ArrayList(*Obj), fmt_z: [*:0]const u8, ap: *obj.va.VaList) callconv(.c) void {
    const fmt = std.mem.span(fmt_z);
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            i += 1;
            continue;
        }
        i += 1;
        if (i < fmt.len and fmt[i] == '%') {
            i += 1;
            continue;
        }
        // An %n$ form names its arguments in order of use here too.
        var di = i;
        while (di < fmt.len and std.ascii.isDigit(fmt[di])) di += 1;
        if (di > i and di < fmt.len and fmt[di] == '$') i = di + 1;
        while (i < fmt.len and std.mem.indexOfScalar(u8, "-+ 0#", fmt[i]) != null) i += 1;
        if (i < fmt.len and fmt[i] == '*') {
            push(list, obj.Tcl_NewIntObj(obj.va.arg(ap, c_int)));
            i += 1;
        } else while (i < fmt.len and std.ascii.isDigit(fmt[i])) i += 1;
        var prec: ?usize = null;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            if (i < fmt.len and fmt[i] == '*') {
                const p = obj.va.arg(ap, c_int);
                push(list, obj.Tcl_NewIntObj(p));
                prec = @intCast(@max(p, 0));
                i += 1;
            } else {
                var p: usize = 0;
                while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) p = p * 10 + (fmt[i] - '0');
                prec = p;
            }
        }
        var longs: u8 = 0;
        while (i < fmt.len and (fmt[i] == 'l' or fmt[i] == 'h')) : (i += 1) {
            if (fmt[i] == 'l') longs += 1;
        }
        if (i >= fmt.len) return;
        const conv = fmt[i];
        i += 1;
        switch (conv) {
            's' => {
                const p = obj.va.arg(ap, ?[*:0]const u8) orelse {
                    push(list, obj.Tcl_NewObj());
                    continue;
                };
                // With a precision, the text has at most that many bytes
                // and can end without a 0.
                push(list, obj.Tcl_NewStringObj(p, @intCast(cLen(p, prec orelse std.math.maxInt(usize)))));
            },
            'c' => push(list, obj.Tcl_NewIntObj(obj.va.arg(ap, c_int))),
            // An unsigned conversion reads a signed value of the same size.
            'd', 'i', 'u', 'o', 'x', 'X', 'b' => push(list, switch (longs) {
                0 => obj.Tcl_NewIntObj(obj.va.arg(ap, c_int)),
                1 => obj.Tcl_NewWideIntObj(obj.va.arg(ap, c_long)),
                else => obj.Tcl_NewWideIntObj(obj.va.arg(ap, c_longlong)),
            }),
            'e', 'E', 'f', 'g', 'G' => push(list, obj.Tcl_NewDoubleObj(obj.va.arg(ap, f64))),
            else => {},
        }
    }
}

fn push(list: *std.ArrayList(*Obj), o: *Obj) void {
    obj.incr(o);
    list.append(gpa, o) catch panicText("out of memory");
}

fn appendPrintf(o: *Obj, fmt: [*:0]const u8, ap: *obj.va.VaList) void {
    var list: std.ArrayList(*Obj) = .empty;
    defer {
        for (list.items) |e| obj.decr(e);
        list.deinit(gpa);
    }
    printfArgs(&list, fmt, ap);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var msg: []const u8 = "";
    const src: ObjArgs = .{ .objv = list.items, .a = arena.allocator(), .msg = &msg };
    const out = format.render(src, arena.allocator(), std.mem.span(fmt), list.items.len) catch |e| {
        if (e == error.OutOfMemory) panicText("out of memory");
        // The message has the arguments as a list.
        const args = obj.Tcl_NewListObj(@intCast(list.items.len), list.items.ptr);
        obj.incr(args);
        defer obj.decr(args);
        const t = std.fmt.allocPrint(arena.allocator(), "Unable to format \"{s}\" with supplied arguments: {s}", .{ fmt, obj.text(args) }) catch panicText("out of memory");
        obj.appendText(o, t);
        return;
    };
    obj.appendText(o, out);
}

pub const Tcl_AppendPrintfToObj = if (obj.va.own) obj.va.Stub(2, "ztcl_va_AppendPrintfToObj").f else appendPrintfToObj;

fn appendPrintfToObj(o: *Obj, fmt: [*:0]const u8, ...) callconv(.c) void {
    if (o.refCount > 1) panicText("Tcl_AppendPrintfToObj called with shared object");
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    appendPrintf(o, fmt, &ap);
}

pub const Tcl_ObjPrintf = if (obj.va.own) obj.va.Stub(1, "ztcl_va_ObjPrintf").f else objPrintf;

fn objPrintf(fmt: [*:0]const u8, ...) callconv(.c) *Obj {
    const o = obj.Tcl_NewObj();
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    appendPrintf(o, fmt, &ap);
    return o;
}

/// The bodies of the variadic entry points of aarch64 Linux (`va.zig`).
fn appendPrintfToObjVA(o: *Obj, fmt: [*:0]const u8, ap: *obj.va.VaList) callconv(.c) void {
    if (o.refCount > 1) panicText("Tcl_AppendPrintfToObj called with shared object");
    appendPrintf(o, fmt, ap);
}

fn objPrintfVA(fmt: [*:0]const u8, ap: *obj.va.VaList) callconv(.c) *Obj {
    const o = obj.Tcl_NewObj();
    appendPrintf(o, fmt, ap);
    return o;
}

comptime {
    if (obj.va.exports) {
        obj.va.exportBody(&appendPrintfToObjVA, "ztcl_va_AppendPrintfToObj");
        obj.va.exportBody(&objPrintfVA, "ztcl_va_ObjPrintf");
    }
}

pub fn Tcl_AppendLimitedToObj(o: *Obj, bytes: ?[*]const u8, length: c_int, limit: c_int, ellipsis: ?[*:0]const u8) callconv(.c) void {
    if (o.refCount > 1) panicText("Tcl_AppendLimitedToObj called with shared object");
    const s = if (bytes) |b| span(b, length) else "";
    const lim: usize = @intCast(@max(limit, 0));
    if (s.len <= lim) return obj.appendText(o, s);
    const e0 = if (ellipsis) |p| std.mem.span(p) else "...";
    // An ellipsis longer than the limit is cut to the limit.
    const e = e0[0..@min(e0.len, lim)];
    // The cut is at the start of the character of byte `limit - len(e)`.
    var cut = lim - e.len;
    while (cut > 0 and s[cut] & 0xC0 == 0x80) cut -= 1;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, s[0..cut]) catch panicText("out of memory");
    out.appendSlice(gpa, e) catch panicText("out of memory");
    obj.appendText(o, out.items);
}

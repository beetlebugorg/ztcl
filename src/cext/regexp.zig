//! The regular expression slots of the stubs table of Tcl 8.6. The
//! native path (`stubs.zig`) and the WebAssembly path (`wasm_stubs.zig`)
//! use this one file.
//!
//! The `regexp` command of ztcl compiles and runs each expression: the
//! slots evaluate `::regexp` with the options of the flags, and the
//! interp result is the same after the call. A `Tcl_RegExp` is the
//! address of a `Re`: the pattern, the flags, and the indices of the
//! last match. Tcl_RegExpCompile checks the pattern with `-about`,
//! which also gives the count of subexpressions. An `Re` is kept in a
//! list of the thread for its pattern and flags, so the same pattern
//! gives the same handle, and a handle stays valid until the thread
//! ends.
//!
//! An exec of the text at `text` with the start of the string at
//! `start` gives `regexp -start` the characters between the two, so
//! `^` does not match at `text` when `text` is after `start`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const obj = @import("obj.zig");
const host = @import("host.zig");

const Obj = obj.Obj;
const Interp = obj.Interp;
const OK = obj.OK;
const ERROR = obj.ERROR;
const gpa = std.heap.c_allocator;
const panicText = obj.panicText;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();

const ADVANCED: c_int = 0o3;
const QUOTE: c_int = 0o4;
const NOCASE: c_int = 0o10;
const EXPANDED: c_int = 0o40;
const NLSTOP: c_int = 0o100;
const NLANCH: c_int = 0o200;
const NOTBOL: c_int = 0o1;

/// `Tcl_RegExpIndices`.
pub const Indices = extern struct { start: c_long, end: c_long };

/// `Tcl_RegExpInfo`.
pub const Info = extern struct {
    nsubs: c_int,
    matches: ?[*]Indices,
    extend_start: c_long,
    reserved: c_long,
};

const Re = struct {
    pattern: []u8,
    flags: c_int,
    ip: *Interp,
    nsubs: c_int,
    /// The character indices of the last match, end after the last
    /// character, or -1.
    matches: std.ArrayList(Indices) = .empty,
    /// The string of the indices of the last Tcl_RegExpExec.
    text: ?[*]const u8 = null,
};

threadlocal var cache: std.ArrayList(*Re) = .empty;

fn word(s: []const u8) *Obj {
    return obj.Tcl_NewStringObj(s.ptr, @intCast(s.len));
}

/// The words of a `regexp` command for `re`, up to the `--`.
fn optionWords(list: *std.ArrayList(*Obj), flags: c_int) void {
    const add = struct {
        fn f(l: *std.ArrayList(*Obj), s: []const u8) void {
            const o = word(s);
            obj.incr(o);
            l.append(gpa, o) catch panicText("out of memory");
        }
    }.f;
    add(list, "::regexp");
    if (flags & NOCASE != 0) add(list, "-nocase");
    if (flags & EXPANDED != 0) add(list, "-expanded");
    if (flags & NLSTOP != 0) add(list, "-linestop");
    if (flags & NLANCH != 0) add(list, "-lineanchor");
}

/// The pattern with the prefix of the syntax of `flags`.
fn fullPattern(a: std.mem.Allocator, pat: []const u8, flags: c_int) []const u8 {
    const prefix: []const u8 = if (flags & QUOTE != 0) "***=" else switch (flags & ADVANCED) {
        0 => "(?b)",
        1 => "(?e)",
        else => "",
    };
    return std.mem.concat(a, u8, &.{ prefix, pat }) catch panicText("out of memory");
}

/// Evaluates the words `list` and frees them. The interp result is the
/// same after the call, unless the command fails. `out` gets the
/// result of a success.
pub fn run(ip: *Interp, list: *std.ArrayList(*Obj), out: *?*Obj) c_int {
    defer {
        for (list.items) |o| obj.decr(o);
        list.deinit(gpa);
    }
    const saved = obj.result(ip);
    obj.incr(saved);
    defer obj.decr(saved);
    const rc = host.Tcl_EvalObjv(ip, @intCast(list.items.len), list.items.ptr, 0);
    if (rc != OK) return rc;
    const r = obj.result(ip);
    obj.incr(r);
    out.* = r;
    obj.Tcl_SetObjResult(ip, saved);
    return OK;
}

fn push(list: *std.ArrayList(*Obj), o: *Obj) void {
    obj.incr(o);
    list.append(gpa, o) catch panicText("out of memory");
}

fn compile(ip: *Interp, pat: []const u8, flags: c_int) ?*Re {
    for (cache.items) |re| {
        if (re.flags == flags and re.ip == ip and std.mem.eql(u8, re.pattern, pat)) return re;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var list: std.ArrayList(*Obj) = .empty;
    optionWords(&list, flags);
    push(&list, word("-about"));
    push(&list, word("--"));
    push(&list, word(fullPattern(arena.allocator(), pat, flags)));
    var r: ?*Obj = null;
    if (run(ip, &list, &r) != OK) return null;
    defer obj.decr(r.?);
    var n: c_int = 0;
    var first: ?*Obj = null;
    if (obj.Tcl_ListObjIndex(null, r.?, 0, &first) == OK) if (first) |f| {
        _ = obj.Tcl_GetIntFromObj(null, f, &n);
    };
    const re = gpa.create(Re) catch panicText("out of memory");
    re.* = .{ .pattern = gpa.dupe(u8, pat) catch panicText("out of memory"), .flags = flags, .ip = ip, .nsubs = n };
    cache.append(gpa, re) catch panicText("out of memory");
    return re;
}

/// Runs `re` on `text` from character `start`, and keeps the indices of
/// the match relative to `start`. Gives 1 for a match, 0 for none, and
/// -1 for an error.
fn exec(ip0: ?*Interp, re: *Re, text: []const u8, start: usize) c_int {
    const ip = ip0 orelse re.ip;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var list: std.ArrayList(*Obj) = .empty;
    optionWords(&list, re.flags);
    push(&list, word("-inline"));
    push(&list, word("-indices"));
    if (start > 0) {
        push(&list, word("-start"));
        push(&list, obj.Tcl_NewWideIntObj(@intCast(start)));
    }
    push(&list, word("--"));
    push(&list, word(fullPattern(arena.allocator(), re.pattern, re.flags)));
    push(&list, word(text));
    var r: ?*Obj = null;
    if (run(ip, &list, &r) != OK) return -1;
    defer obj.decr(r.?);
    re.matches.clearRetainingCapacity();
    var objc: c_int = 0;
    var objv: [*]*Obj = undefined;
    if (obj.Tcl_ListObjGetElements(null, r.?, &objc, &objv) != OK) return -1;
    if (objc == 0) return 0;
    for (objv[0..@intCast(objc)]) |pair| {
        var a: ?*Obj = null;
        var b: ?*Obj = null;
        var s: c_long = -1;
        var e: c_long = -1;
        if (obj.Tcl_ListObjIndex(null, pair, 0, &a) == OK and obj.Tcl_ListObjIndex(null, pair, 1, &b) == OK and a != null and b != null) {
            _ = obj.Tcl_GetLongFromObj(null, a.?, &s);
            _ = obj.Tcl_GetLongFromObj(null, b.?, &e);
        }
        const st: c_long = @intCast(start);
        re.matches.append(gpa, if (s < 0) .{ .start = -1, .end = -1 } else .{ .start = s - st, .end = e + 1 - st }) catch panicText("out of memory");
    }
    return 1;
}

/// The byte offset of character `k` of `s`.
fn byteAt(s: []const u8, k: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < k) : (n += 1) {
        const c = s[i];
        i += if (c < 0xC0) 1 else if (c < 0xE0) 2 else if (c < 0xF0) 3 else 4;
    }
    return @min(i, s.len);
}

pub fn Tcl_RegExpCompile(ip: *Interp, pattern: [*:0]const u8) callconv(.c) ?*anyopaque {
    return compile(ip, std.mem.span(pattern), ADVANCED);
}

pub fn Tcl_GetRegExpFromObj(ip: *Interp, pattern: *Obj, flags: c_int) callconv(.c) ?*anyopaque {
    return compile(ip, obj.text(pattern), flags);
}

pub fn Tcl_RegExpExec(ip: ?*Interp, h: *anyopaque, text: [*:0]const u8, start: [*:0]const u8) callconv(.c) c_int {
    const re: *Re = @ptrCast(@alignCast(h));
    const begin = if (@intFromPtr(start) <= @intFromPtr(text)) start else text;
    const all = std.mem.span(begin);
    const skip = obj.charCount(all[0 .. @intFromPtr(text) - @intFromPtr(begin)]);
    const rc = exec(ip, re, all, skip);
    re.text = text;
    return rc;
}

pub fn Tcl_RegExpRange(h: *anyopaque, index: c_int, start: *?[*]const u8, end: *?[*]const u8) callconv(.c) void {
    const re: *Re = @ptrCast(@alignCast(h));
    start.* = null;
    end.* = null;
    if (index < 0 or index >= re.matches.items.len) return;
    const m = re.matches.items[@intCast(index)];
    const t = re.text orelse return;
    if (m.start < 0) return;
    const s = std.mem.span(@as([*:0]const u8, @ptrCast(t)));
    start.* = t + byteAt(s, @intCast(m.start));
    end.* = t + byteAt(s, @intCast(m.end));
}

pub fn Tcl_RegExpMatch(ip: *Interp, text: [*:0]const u8, pattern: [*:0]const u8) callconv(.c) c_int {
    const re = Tcl_RegExpCompile(ip, pattern) orelse return -1;
    return Tcl_RegExpExec(ip, re, text, text);
}

pub fn Tcl_RegExpExecObj(ip: ?*Interp, h: *anyopaque, text: *Obj, offset: c_int, _: c_int, flags: c_int) callconv(.c) c_int {
    const re: *Re = @ptrCast(@alignCast(h));
    re.text = null;
    const s = obj.text(text);
    const off: usize = @intCast(@max(offset, 0));
    if (flags & NOTBOL != 0 or off == 0) return exec(ip, re, s, off);
    // From the offset, `^` matches at the offset.
    const tail = gpa.dupe(u8, s[byteAt(s, off)..]) catch panicText("out of memory");
    defer gpa.free(tail);
    return exec(ip, re, tail, 0);
}

pub fn Tcl_RegExpGetInfo(h: *anyopaque, info: *Info) callconv(.c) void {
    const re: *Re = @ptrCast(@alignCast(h));
    // The array has an entry for each subexpression and the match.
    while (re.matches.items.len < @as(usize, @intCast(re.nsubs)) + 1) re.matches.append(gpa, .{ .start = -1, .end = -1 }) catch panicText("out of memory");
    info.* = .{ .nsubs = re.nsubs, .matches = re.matches.items.ptr, .extend_start = 0, .reserved = 0 };
}

pub fn Tcl_RegExpMatchObj(ip: *Interp, text: *Obj, pattern: *Obj) callconv(.c) c_int {
    const re = Tcl_GetRegExpFromObj(ip, pattern, ADVANCED) orelse return -1;
    return Tcl_RegExpExecObj(ip, re, text, 0, 0, 0);
}

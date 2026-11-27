//! The module ztcl::text, and the -grapheme forms of `string` and
//! `split`.
//!
//! The commands segment a string with seg.zig and give the segments as
//! a list, or the character index of each boundary. The -grapheme forms
//! count in grapheme clusters, and the plain forms of the core commands
//! stay as in Tcl.
//!
//! A string of 256 bytes or more in a heap block gets a mark list in
//! the heap: the byte offset of every 64th cluster, and the count. The
//! list is in a heap block too, and a sweep clears the cache, so a mark
//! list never outlives its string. A loop of `string index -grapheme`
//! on one long string then walks at most 64 clusters per call.
//!
//! Each command charges one compute unit for each 4,096 bytes that it
//! reads, before the walk.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("../interp.zig");
const mods = @import("../modules.zig");
const cmds = @import("../cmds.zig");
const value = @import("../value.zig");
const seg = @import("seg.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const Cmd = interp.Cmd;

const modules_list = [_]mods.Module{.{
    .name = "ztcl::text",
    .version = "1.0",
    .install = install,
    .script =
    \\namespace eval ::ztcl::text {
    \\    namespace export graphemes words sentences width bounds
    \\    namespace ensemble create
    \\}
    ,
}};

pub const modules: []const mods.Module = &modules_list;

fn install(it: *Interp) Error!void {
    try it.register("ztcl::text::graphemes", cmdGraphemes);
    try it.register("ztcl::text::words", cmdWords);
    try it.register("ztcl::text::sentences", cmdSentences);
    try it.register("ztcl::text::width", cmdWidth);
    try it.register("ztcl::text::bounds", cmdBounds);
}

fn charge(it: *Interp, s: []const u8) Error!void {
    try cmds.chargeWork(it, s.len);
}

fn cmdGraphemes(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("ztcl::text graphemes string");
    const s = try it.str(argv[1]);
    try charge(it, s);
    return graphemeList(it, s);
}

pub fn graphemeList(it: *Interp, s: []const u8) Error!Value {
    const a = it.alloc();
    var out: std.ArrayList(Value) = .empty;
    try out.ensureTotalCapacity(a, s.len / 2 + 1);
    var i: usize = 0;
    while (i < s.len) {
        const e = seg.graphemeEnd(s, i);
        try out.append(a, .{ .str = s[i..e] });
        i = e;
    }
    return value.wrapList(a, out.items);
}

fn cmdWords(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const usage = "ztcl::text words ?-all? string";
    var all = false;
    if (argv.len == 3) {
        if (!std.mem.eql(u8, try it.str(argv[1]), "-all")) return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -all", .{try it.str(argv[1])});
        all = true;
    } else if (argv.len != 2) return it.wrongArgs(usage);
    const s = try it.str(argv[argv.len - 1]);
    try charge(it, s);
    const a = it.alloc();
    var out: std.ArrayList(Value) = .empty;
    var w: seg.Words = .{ .s = s };
    while (w.next()) |part| {
        if (all or seg.wordLike(part)) try out.append(a, .{ .str = part });
    }
    return value.wrapList(a, out.items);
}

fn cmdSentences(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("ztcl::text sentences string");
    const s = try it.str(argv[1]);
    try charge(it, s);
    const a = it.alloc();
    var out: std.ArrayList(Value) = .empty;
    var z: seg.Sentences = .{ .s = s };
    while (z.next()) |part| try out.append(a, .{ .str = part });
    return value.wrapList(a, out.items);
}

fn cmdWidth(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const usage = "ztcl::text width ?-ambiguous narrow|wide? string";
    var amb: seg.Ambiguous = .narrow;
    if (argv.len == 4) {
        if (!std.mem.eql(u8, try it.str(argv[1]), "-ambiguous")) return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -ambiguous", .{try it.str(argv[1])});
        const v = try it.str(argv[2]);
        amb = std.meta.stringToEnum(seg.Ambiguous, v) orelse return it.failCode("TCL LOOKUP INDEX value", "bad value \"{s}\": must be narrow or wide", .{v});
    } else if (argv.len != 2) return it.wrongArgs(usage);
    const s = try it.str(argv[argv.len - 1]);
    try charge(it, s);
    return .{ .int = @intCast(seg.width(s, amb)) };
}

const Unit = enum { grapheme, word, sentence };

fn cmdBounds(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const usage = "ztcl::text bounds ?-unit grapheme|word|sentence? string";
    var unit: Unit = .grapheme;
    if (argv.len == 4) {
        if (!std.mem.eql(u8, try it.str(argv[1]), "-unit")) return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -unit", .{try it.str(argv[1])});
        const v = try it.str(argv[2]);
        unit = std.meta.stringToEnum(Unit, v) orelse return it.failCode("TCL LOOKUP INDEX value", "bad unit \"{s}\": must be grapheme, word, or sentence", .{v});
    } else if (argv.len != 2) return it.wrongArgs(usage);
    const s = try it.str(argv[argv.len - 1]);
    try charge(it, s);
    const a = it.alloc();
    var out: std.ArrayList(Value) = .empty;
    try out.append(a, .{ .int = 0 });
    var chars: usize = 0;
    var start: usize = 0;
    switch (unit) {
        .grapheme => while (start < s.len) {
            const e = seg.graphemeEnd(s, start);
            chars += cmds.charCount(s[start..e]);
            try out.append(a, .{ .int = @intCast(chars) });
            start = e;
        },
        .word => {
            var w: seg.Words = .{ .s = s };
            while (w.next()) |part| {
                chars += cmds.charCount(part);
                try out.append(a, .{ .int = @intCast(chars) });
            }
        },
        .sentence => {
            var z: seg.Sentences = .{ .s = s };
            while (z.next()) |part| {
                chars += cmds.charCount(part);
                try out.append(a, .{ .int = @intCast(chars) });
            }
        },
    }
    if (s.len == 0) out.items.len = 1;
    return value.wrapList(a, out.items);
}

// ---- The -grapheme forms of the core commands ----

/// The count of clusters and the offset of every `step`-th one.
const Marks = struct {
    n: usize,
    /// marks[k] is the byte offset of cluster k * step.
    marks: []const u32,
};

const step = 64;

/// The mark list of `s`, from the heap cache or new. Null when `s` is
/// short or outside the heap: the caller walks from the start.
fn marksOf(it: *Interp, s: []const u8) Error!?Marks {
    if (s.len < 256 or s.len > std.math.maxInt(u32)) return null;
    const h = it.heap;
    if (h.cachedGraphemes(s)) |g| return .{ .n = g.n, .marks = g.marks };
    if (h.find(@intFromPtr(s.ptr)) == null) return null;
    const a = it.alloc();
    var list: std.ArrayList(u32) = .empty;
    var pos: usize = 0;
    var n: usize = 0;
    while (true) {
        try list.append(a, @intCast(pos));
        const r = seg.skip(s, pos, step);
        n += r.n;
        pos = r.pos;
        if (r.n < step or pos >= s.len) break;
    }
    h.putGraphemes(s, n, list.items);
    return .{ .n = n, .marks = list.items };
}

/// The count of clusters of `s`.
pub fn count(it: *Interp, s: []const u8) Error!usize {
    try charge(it, s);
    if (try marksOf(it, s)) |m| return m.n;
    return seg.count(s);
}

/// The byte offset of cluster `k` of `s` (s.len when k is the count).
fn offsetOf(s: []const u8, m: ?Marks, k: usize) usize {
    if (m) |mk| {
        const at = @min(k / step, mk.marks.len - 1);
        return seg.skip(s, mk.marks[at], k - at * step).pos;
    }
    return seg.skip(s, 0, k).pos;
}

/// `string length -grapheme string`.
pub fn length(it: *Interp, s: []const u8) Error!Value {
    return .{ .int = @intCast(try count(it, s)) };
}

/// `string index -grapheme string index`.
pub fn index(it: *Interp, s: []const u8, iv: Value) Error!Value {
    try charge(it, s);
    const m = try marksOf(it, s);
    const n = if (m) |mk| mk.n else seg.count(s);
    const i = try cmds.index(it, iv, n);
    if (i < 0 or i >= n) return Value.empty;
    const b = offsetOf(s, m, @intCast(i));
    return .{ .str = s[b..seg.graphemeEnd(s, b)] };
}

/// `string range -grapheme string first last`.
pub fn range(it: *Interp, s: []const u8, fv: Value, lv: Value) Error!Value {
    try charge(it, s);
    const m = try marksOf(it, s);
    const n = if (m) |mk| mk.n else seg.count(s);
    var first = try cmds.index(it, fv, n);
    var last = try cmds.index(it, lv, n);
    first = @max(first, 0);
    last = @min(last, @as(i64, @intCast(n)) - 1);
    if (first > last) return Value.empty;
    const b0 = offsetOf(s, m, @intCast(first));
    const b1 = seg.skip(s, b0, @intCast(last - first + 1)).pos;
    return .{ .str = s[b0..b1] };
}

/// `string reverse -grapheme string`: the clusters in reverse order,
/// each with its code points in order.
pub fn reverse(it: *Interp, s: []const u8) Error!Value {
    try charge(it, s);
    const out = try it.alloc().alloc(u8, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const e = seg.graphemeEnd(s, i);
        @memcpy(out[s.len - e .. s.len - i], s[i..e]);
        i = e;
    }
    return .{ .str = out };
}

/// `split string splitChars -grapheme`: with no split characters, each
/// cluster is one element. Else the string splits at each cluster that
/// is one of the split characters.
pub fn split(it: *Interp, s: []const u8, seps: []const u8) Error!Value {
    try charge(it, s);
    if (s.len == 0) return Value.empty;
    if (seps.len == 0) return graphemeList(it, s);
    const a = it.alloc();
    var out: std.ArrayList(Value) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const e = seg.graphemeEnd(s, i);
        const c = s[i..e];
        var j: usize = 0;
        const hit = while (j < seps.len) {
            const d = seg.decode(seps, j);
            if (d.len == c.len and std.mem.eql(u8, seps[j .. j + d.len], c)) break true;
            j += d.len;
        } else false;
        if (hit) {
            try out.append(a, .{ .str = s[start..i] });
            start = e;
        }
        i = e;
    }
    try out.append(a, .{ .str = s[start..] });
    return value.wrapList(a, out.items);
}

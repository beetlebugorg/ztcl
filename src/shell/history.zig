//! The history of the line editor.
//!
//! The list holds the commands of this session and of the history file,
//! the oldest first. `add` skips an empty command, a command that starts
//! with a space, and a command equal to the last one, and drops the
//! oldest command above the size limit.
//!
//! The file has one command on each line. A newline or a backslash in a
//! command is written as `\n` or `\\`. Each session appends its new
//! commands at its end, so two sessions share one file: `save` reads the
//! file again, adds the commands of this session that it does not have
//! yet, and writes the file with the size limit. The runner gives the folder of the file.
//!
//! Two searches serve the editor. `prefix` finds the next older or newer
//! command that starts with a text. `fuzzy` scores each command for a
//! query, as Ctrl-R does: each character of the query must come in order,
//! and a match at the start of a word or right after the last match
//! scores more.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const History = struct {
    a: Allocator,
    items: std.ArrayList([]u8) = .empty,
    /// The first command in `items` that the file does not have yet.
    session_start: usize = 0,
    limit: usize = 1000,

    pub fn init(a: Allocator) History {
        return .{ .a = a };
    }

    pub fn deinit(h: *History) void {
        for (h.items.items) |s| h.a.free(s);
        h.items.deinit(h.a);
    }

    pub fn len(h: *const History) usize {
        return h.items.items.len;
    }

    pub fn get(h: *const History, i: usize) []const u8 {
        return h.items.items[i];
    }

    pub fn add(h: *History, cmd: []const u8) Allocator.Error!void {
        const t = std.mem.trimEnd(u8, cmd, "\n");
        if (t.len == 0 or t[0] == ' ') return;
        if (h.items.items.len > 0 and std.mem.eql(u8, h.items.getLast(), t)) return;
        try h.items.append(h.a, try h.a.dupe(u8, t));
        h.trim();
    }

    /// After a write of the file: each command is in the file now.
    pub fn markSaved(h: *History) void {
        h.session_start = h.items.items.len;
    }

    fn trim(h: *History) void {
        while (h.items.items.len > h.limit) {
            h.a.free(h.items.orderedRemove(0));
            if (h.session_start > 0) h.session_start -= 1;
        }
    }

    /// The index of the next command before `from` (or after it, with
    /// `newer`) that starts with `text`, or null.
    pub fn prefix(h: *const History, from: usize, text: []const u8, newer: bool) ?usize {
        var i = from;
        while (true) {
            if (newer) {
                i += 1;
                if (i >= h.items.items.len) return null;
            } else {
                if (i == 0) return null;
                i -= 1;
            }
            const s = h.items.items[i];
            if (std.mem.startsWith(u8, s, text) and !std.mem.eql(u8, s, text)) return i;
        }
    }

    /// The best command for `query` with an index below `before`, the
    /// newest first among equal scores, or null.
    pub fn fuzzy(h: *const History, query: []const u8, before: usize) ?usize {
        var best: ?usize = null;
        var best_score: i64 = 0;
        var i = @min(before, h.items.items.len);
        while (i > 0) {
            i -= 1;
            const sc = score(h.items.items[i], query) orelse continue;
            if (best == null or sc > best_score) {
                best = i;
                best_score = sc;
            }
        }
        return best;
    }

    // ---- The file ----

    /// Reads the commands of a history file text.
    pub fn load(h: *History, text: []const u8) Allocator.Error!void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const cmd = try unescape(h.a, line);
            defer h.a.free(cmd);
            try h.add(cmd);
        }
        h.session_start = h.items.items.len;
    }

    /// The text of the history file: the commands of `old` (the file as
    /// another session left it) and then the new commands of this
    /// session, at most `limit`.
    pub fn merged(h: *const History, a: Allocator, old: []const u8) Allocator.Error![]u8 {
        var all = History.init(a);
        defer all.deinit();
        all.limit = h.limit;
        try all.load(old);
        for (h.items.items[@min(h.session_start, h.items.items.len)..]) |cmd| try all.add(cmd);
        var out: std.ArrayList(u8) = .empty;
        for (all.items.items) |cmd| {
            try escape(a, &out, cmd);
            try out.append(a, '\n');
        }
        return out.toOwnedSlice(a);
    }
};

fn escape(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    for (s) |c| switch (c) {
        '\n' => try out.appendSlice(a, "\\n"),
        '\\' => try out.appendSlice(a, "\\\\"),
        else => try out.append(a, c),
    };
}

fn unescape(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try out.append(a, if (s[i] == 'n') '\n' else s[i]);
        } else try out.append(a, s[i]);
    }
    return out.toOwnedSlice(a);
}

fn lower(c: u8) u8 {
    return std.ascii.toLower(c);
}

/// The score of `text` for `query`, or null when the characters of the
/// query do not come in order. Case does not count.
pub fn score(text: []const u8, query: []const u8) ?i64 {
    if (query.len == 0) return 0;
    var s: i64 = 0;
    var qi: usize = 0;
    var last: ?usize = null;
    for (text, 0..) |c, i| {
        if (qi == query.len) break;
        if (lower(c) != lower(query[qi])) continue;
        s += 1;
        if (last != null and last.? + 1 == i) s += 4;
        if (i == 0 or !std.ascii.isAlphanumeric(text[i - 1])) s += 3;
        last = i;
        qi += 1;
    }
    if (qi < query.len) return null;
    // A shorter command with the same matches is a better match.
    return s * 1000 - @as(i64, @intCast(@min(text.len, 999)));
}

test "history: add, prefix, fuzzy, and the file" {
    const t = std.testing;
    var h = History.init(t.allocator);
    defer h.deinit();
    try h.add("set a 1");
    try h.add("set a 1");
    try h.add(" secret");
    try h.add("");
    try h.add("puts $a");
    try h.add("set b {x\ny}");
    try t.expectEqual(@as(usize, 3), h.len());
    try t.expectEqual(@as(?usize, 0), h.prefix(3, "set a", false));
    try t.expectEqual(@as(?usize, 2), h.prefix(0, "set", true));
    try t.expectEqual(@as(?usize, 1), h.fuzzy("pts", 3));
    try t.expectEqual(@as(?usize, null), h.fuzzy("zz", 3));
    const text = try h.merged(t.allocator, "old one\n");
    defer t.allocator.free(text);
    try t.expectEqualStrings("old one\nset a 1\nputs $a\nset b {x\\ny}\n", text);
    var g = History.init(t.allocator);
    defer g.deinit();
    try g.load(text);
    try t.expectEqualStrings("set b {x\ny}", g.get(3));
}

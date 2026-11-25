//! The state machine of the line editor: the buffer, the cursor, the
//! keys of Emacs and of vim, the kill ring, undo, history, and the
//! incremental search. It reads keys and changes its state. It does no
//! input and no output, so the tests drive it with keys alone.
//!
//! The buffer holds the whole command, also a command of many lines. The
//! cursor is a byte offset at the start of a cluster (`text.zig`).
//!
//! Emacs keys are the default. In vim mode, the editor starts each line
//! in insert mode, and Escape goes to normal mode. Normal mode has
//! counts, the motions `h l w b e W B E 0 ^ $ f t F T ; ,`, the operators
//! `d c y` with a motion, a doubled operator, or a text object (`iw aw
//! i" a" i' a' i( a( i[ a[ i{ a{`), and `x X r R s S p P u Ctrl-R . ~ D
//! C Y i a I A o O`. `V` starts the visual mode, where the motions move
//! the end of the selection and `d c y x ~` act on it. `"` and a letter
//! name a register. `v` opens the buffer in an editor, as in bash. `j`
//! and `k` move between the lines of the buffer, and at the first or the
//! last line they go through the history.
//!
//! `.` repeats the last change: the editor keeps the keys of the last
//! command that changed the buffer, from the normal mode key to the
//! Escape that ended its insert, and plays them again.
//!
//! Undo keeps a copy of the buffer and the cursor before each change.
//! The characters of one insert are one change.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const text = @import("text.zig");
const keys = @import("keys.zig");
const History = @import("history.zig").History;

const Allocator = std.mem.Allocator;
const Key = keys.Key;
const Error = Allocator.Error;

pub const Mode = enum { emacs, insert, normal, visual, replace };

/// What the shell does after a key.
pub const Action = enum {
    none,
    /// The command is complete: run it.
    accept,
    /// Ctrl-D on an empty line.
    eof,
    /// Ctrl-C: the command is dropped.
    interrupt,
    clear_screen,
    /// Tab: the shell completes the word at the cursor.
    complete,
    /// Ctrl-X Ctrl-E or `v`: the shell opens the buffer in an editor.
    open_editor,
    /// Alt-T: the shell shows the whole `errorInfo` of the last error.
    show_trace,
};

/// The callbacks of the shell.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// True when the text is a complete command (`info complete`).
    complete: *const fn (ctx: ?*anyopaque, text: []const u8) bool = alwaysComplete,

    fn alwaysComplete(_: ?*anyopaque, _: []const u8) bool {
        return true;
    }
};

const Snapshot = struct { buf: []u8, cur: usize };

/// The state of a vim command that waits for more keys.
const Pending = union(enum) {
    none,
    /// An operator (`d`, `c`, `y`) that waits for its motion.
    op: u8,
    /// `f t F T` that wait for their character, with the operator before
    /// them (0 for none).
    find: struct { kind: u8, op: u8 },
    /// `r` waits for its character.
    replace_char,
    /// `"` waits for the name of a register.
    register,
    /// `i` or `a` after an operator wait for the object.
    object: struct { op: u8, around: bool },
    /// Ctrl-X waits for Ctrl-E.
    ctrl_x,
};

pub const Editor = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,
    cur: usize = 0,
    vi: bool = false,
    mode: Mode = .emacs,
    host: Host = .{},
    history: ?*History = null,
    /// The history entry on show, or null for the line being typed.
    hist_at: ?usize = null,
    /// The line being typed when the history walk started.
    saved: std.ArrayList(u8) = .empty,
    /// The text before the cursor when Up with a prefix started.
    hist_prefix: ?[]u8 = null,

    kill_ring: std.ArrayList([]u8) = .empty,
    /// True when the last key killed text, so the next kill joins it.
    last_kill: bool = false,
    /// The start and the end of the last yank, for Alt-Y.
    yank_span: ?struct { start: usize, end: usize, index: usize } = null,

    undo: std.ArrayList(Snapshot) = .empty,
    redo: std.ArrayList(Snapshot) = .empty,
    /// True while an insert goes on: its characters are one change.
    in_insert_group: bool = false,

    // vim
    count: usize = 0,
    op_count: usize = 0,
    pending: Pending = .none,
    register: u8 = '"',
    registers: [27]?[]u8 = @splat(null),
    last_find: ?struct { kind: u8, ch: u21 } = null,
    visual_start: usize = 0,
    /// The keys of the last change, for `.`, and the keys of the change
    /// that goes on now.
    dot: std.ArrayList(Key) = .empty,
    dot_now: std.ArrayList(Key) = .empty,
    recording: bool = false,
    replaying: bool = false,

    // search
    searching: bool = false,
    query: std.ArrayList(u8) = .empty,
    /// The match of the search, or null when no entry matches.
    found: ?usize = null,

    pub fn init(a: Allocator) Editor {
        return .{ .a = a };
    }

    pub fn deinit(e: *Editor) void {
        e.buf.deinit(e.a);
        e.saved.deinit(e.a);
        if (e.hist_prefix) |p| e.a.free(p);
        for (e.kill_ring.items) |s| e.a.free(s);
        e.kill_ring.deinit(e.a);
        e.clearSnapshots(&e.undo);
        e.clearSnapshots(&e.redo);
        e.undo.deinit(e.a);
        e.redo.deinit(e.a);
        for (&e.registers) |*r| if (r.*) |s| e.a.free(s);
        e.dot.deinit(e.a);
        e.dot_now.deinit(e.a);
        e.query.deinit(e.a);
    }

    fn clearSnapshots(e: *Editor, list: *std.ArrayList(Snapshot)) void {
        for (list.items) |s| e.a.free(s.buf);
        list.clearRetainingCapacity();
    }

    pub fn setVi(e: *Editor, on: bool) void {
        e.vi = on;
        e.mode = if (on) .insert else .emacs;
    }

    pub fn text_(e: *const Editor) []const u8 {
        return e.buf.items;
    }

    /// Starts a new line: an empty buffer, no undo, no history walk.
    pub fn reset(e: *Editor) void {
        e.buf.clearRetainingCapacity();
        e.cur = 0;
        e.hist_at = null;
        if (e.hist_prefix) |p| e.a.free(p);
        e.hist_prefix = null;
        e.clearSnapshots(&e.undo);
        e.clearSnapshots(&e.redo);
        e.in_insert_group = false;
        e.pending = .none;
        e.count = 0;
        e.searching = false;
        e.yank_span = null;
        e.last_kill = false;
        e.mode = if (e.vi) .insert else .emacs;
    }

    /// Replaces the buffer, with the cursor at the end.
    pub fn setText(e: *Editor, s: []const u8) Error!void {
        e.buf.clearRetainingCapacity();
        try e.buf.appendSlice(e.a, s);
        e.cur = s.len;
        if (e.mode == .normal) e.clampNormal();
    }

    // ---- Changes ----

    fn snapshot(e: *Editor) Error!void {
        try e.undo.append(e.a, .{ .buf = try e.a.dupe(u8, e.buf.items), .cur = e.cur });
        e.clearSnapshots(&e.redo);
        if (e.undo.items.len > 200) {
            e.a.free(e.undo.orderedRemove(0).buf);
        }
    }

    /// Takes a snapshot before a change that is not part of an insert.
    fn change(e: *Editor) Error!void {
        e.in_insert_group = false;
        try e.snapshot();
    }

    fn restore(e: *Editor, from: *std.ArrayList(Snapshot), to: *std.ArrayList(Snapshot)) Error!void {
        const s = from.pop() orelse return;
        try to.append(e.a, .{ .buf = try e.a.dupe(u8, e.buf.items), .cur = e.cur });
        e.buf.clearRetainingCapacity();
        try e.buf.appendSlice(e.a, s.buf);
        e.a.free(s.buf);
        e.cur = @min(s.cur, e.buf.items.len);
        e.in_insert_group = false;
        if (e.mode == .normal) e.clampNormal();
    }

    pub fn insertText(e: *Editor, s: []const u8) Error!void {
        if (!e.in_insert_group) {
            try e.snapshot();
            e.in_insert_group = true;
        }
        try e.buf.insertSlice(e.a, e.cur, s);
        e.cur += s.len;
    }

    fn insertCp(e: *Editor, cp: u21) Error!void {
        var b: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &b) catch return;
        try e.insertText(b[0..n]);
    }

    fn deleteRange(e: *Editor, start: usize, end: usize) void {
        if (end <= start) return;
        const n = end - start;
        std.mem.copyForwards(u8, e.buf.items[start..], e.buf.items[end..]);
        e.buf.items.len -= n;
        if (e.cur > end) e.cur -= n else if (e.cur > start) e.cur = start;
    }

    // ---- The kill ring ----

    fn kill(e: *Editor, start: usize, end: usize, before: bool) Error!void {
        if (end <= start) return;
        try e.change();
        const piece = e.buf.items[start..end];
        if (e.last_kill and e.kill_ring.items.len > 0) {
            const old = e.kill_ring.items[e.kill_ring.items.len - 1];
            const joined = if (before) try std.mem.concat(e.a, u8, &.{ piece, old }) else try std.mem.concat(e.a, u8, &.{ old, piece });
            e.a.free(old);
            e.kill_ring.items[e.kill_ring.items.len - 1] = joined;
        } else {
            try e.kill_ring.append(e.a, try e.a.dupe(u8, piece));
            if (e.kill_ring.items.len > 16) e.a.free(e.kill_ring.orderedRemove(0));
        }
        e.deleteRange(start, end);
    }

    fn yank(e: *Editor) Error!void {
        if (e.kill_ring.items.len == 0) return;
        try e.change();
        const index = e.kill_ring.items.len - 1;
        const s = e.kill_ring.items[index];
        const start = e.cur;
        try e.buf.insertSlice(e.a, e.cur, s);
        e.cur += s.len;
        e.yank_span = .{ .start = start, .end = e.cur, .index = index };
    }

    /// Alt-Y after a yank: the yanked text becomes the older kill.
    fn yankPop(e: *Editor) Error!void {
        const span = e.yank_span orelse return;
        if (e.kill_ring.items.len < 2) return;
        const index = if (span.index == 0) e.kill_ring.items.len - 1 else span.index - 1;
        e.deleteRange(span.start, span.end);
        e.cur = span.start;
        const s = e.kill_ring.items[index];
        try e.buf.insertSlice(e.a, e.cur, s);
        e.cur += s.len;
        e.yank_span = .{ .start = span.start, .end = e.cur, .index = index };
    }

    // ---- History ----

    fn currentLine(e: *const Editor) usize {
        var n: usize = 0;
        for (e.buf.items[0..e.cur]) |c| {
            if (c == '\n') n += 1;
        }
        return n;
    }

    fn lineCount(e: *const Editor) usize {
        return std.mem.count(u8, e.buf.items, "\n") + 1;
    }

    /// Up (`older`) or Down. With text typed before the cursor on the
    /// first walk, the walk goes through the entries with that prefix.
    fn historyMove(e: *Editor, older: bool) Error!void {
        const h = e.history orelse return;
        if (e.hist_at == null) {
            e.saved.clearRetainingCapacity();
            try e.saved.appendSlice(e.a, e.buf.items);
            if (e.hist_prefix) |p| e.a.free(p);
            e.hist_prefix = if (e.cur > 0 and e.cur == e.buf.items.len) try e.a.dupe(u8, e.buf.items) else null;
        }
        const pre = e.hist_prefix orelse "";
        const from = e.hist_at orelse h.len();
        const next = h.prefix(from, pre, !older);
        if (next) |i| {
            e.hist_at = i;
            try e.setText(h.get(i));
        } else if (!older and e.hist_at != null) {
            e.hist_at = null;
            try e.setText(e.saved.items);
        }
        e.in_insert_group = false;
    }

    fn lineUp(e: *Editor) Error!void {
        if (e.currentLine() == 0) return e.historyMove(true);
        const col = text.columnOf(e.buf.items, e.cur);
        const start = text.lineStart(e.buf.items, e.cur);
        e.cur = text.atColumn(e.buf.items, text.lineStart(e.buf.items, start - 1), col);
    }

    fn lineDown(e: *Editor) Error!void {
        if (e.currentLine() + 1 >= e.lineCount()) return e.historyMove(false);
        const col = text.columnOf(e.buf.items, e.cur);
        const end = text.lineEnd(e.buf.items, e.cur);
        e.cur = text.atColumn(e.buf.items, end + 1, col);
    }

    // ---- Search ----

    fn searchUpdate(e: *Editor, before: usize) void {
        const h = e.history orelse return;
        e.found = h.fuzzy(e.query.items, before);
    }

    fn searchKey(e: *Editor, k: Key) Error!Action {
        switch (k.code) {
            .char => |c| if (!k.alt) {
                var b: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &b) catch 1;
                try e.query.appendSlice(e.a, b[0..n]);
                e.searchUpdate(if (e.history) |h| h.len() else 0);
                return .none;
            },
            .special => |s| switch (s) {
                .backspace => {
                    if (e.query.items.len > 0) e.query.items.len = text.prevCluster(e.query.items, e.query.items.len);
                    e.searchUpdate(if (e.history) |h| h.len() else 0);
                    return .none;
                },
                .escape => {
                    // Escape keeps the match in the buffer, to edit it.
                    e.searching = false;
                    if (e.found) |f| if (e.history) |h| try e.setText(h.get(f));
                    return .none;
                },
                else => {},
            },
            .ctrl => |c| switch (c) {
                'r' => {
                    // The next older match.
                    if (e.found) |f| e.searchUpdate(f);
                    return .none;
                },
                'g', 'c' => {
                    e.searching = false;
                    return .none;
                },
                else => {},
            },
            .paste => {},
        }
        // Each other key puts the match in the buffer and then acts.
        e.searching = false;
        if (e.found) |f| if (e.history) |h| try e.setText(h.get(f));
        return e.handle(k);
    }

    /// The text of the search line: the query and the match.
    pub fn searchLine(e: *const Editor) ?struct { query: []const u8, match: ?[]const u8 } {
        if (!e.searching) return null;
        return .{ .query = e.query.items, .match = if (e.found) |f| e.history.?.get(f) else null };
    }

    // ---- Keys ----

    pub fn handle(e: *Editor, k: Key) Error!Action {
        if (e.searching) return e.searchKey(k);
        const was_kill = e.last_kill;
        e.last_kill = false;
        const keep_yank = e.yank_span;
        e.yank_span = null;
        if (k.code == .paste) {
            if (e.mode == .normal or e.mode == .visual) e.mode = .insert;
            try e.change();
            // A terminal sends each line end of a paste as CR.
            var at = e.cur;
            var i: usize = 0;
            const p = k.code.paste;
            while (i < p.len) : (i += 1) {
                if (p[i] == '\r') {
                    try e.buf.insert(e.a, at, '\n');
                    if (i + 1 < p.len and p[i + 1] == '\n') i += 1;
                } else try e.buf.insert(e.a, at, p[i]);
                at += 1;
            }
            e.cur = at;
            return .none;
        }
        if (e.mode == .normal or e.mode == .visual) return e.normalKey(k);
        return e.insertKey(k, was_kill, keep_yank);
    }

    /// The keys of Emacs mode and of the insert and replace modes of vim.
    fn insertKey(e: *Editor, k: Key, was_kill: bool, keep_yank: anytype) Error!Action {
        const s = e.buf.items;
        if (e.pending == .ctrl_x) {
            e.pending = .none;
            if (k.code == .ctrl and k.code.ctrl == 'e') return .open_editor;
        }
        if (e.recording) try e.dot_now.append(e.a, k);
        if (k.alt) {
            switch (k.code) {
                .char => |c| switch (c) {
                    'b' => e.cur = text.emacsBackward(s, e.cur),
                    'f' => e.cur = text.emacsForward(s, e.cur),
                    'd' => {
                        e.last_kill = was_kill;
                        try e.kill(e.cur, text.emacsForward(s, e.cur), false);
                        e.last_kill = true;
                    },
                    'y' => {
                        e.yank_span = keep_yank;
                        try e.yankPop();
                    },
                    't' => return .show_trace,
                    else => {},
                },
                .special => |sp| switch (sp) {
                    .backspace => {
                        e.last_kill = was_kill;
                        try e.kill(text.emacsBackward(s, e.cur), e.cur, true);
                        e.last_kill = true;
                    },
                    .left => e.cur = text.emacsBackward(s, e.cur),
                    .right => e.cur = text.emacsForward(s, e.cur),
                    else => {},
                },
                else => {},
            }
            return .none;
        }
        switch (k.code) {
            .char => |c| {
                if (e.mode == .replace and e.cur < s.len and s[e.cur] != '\n') {
                    if (!e.in_insert_group) {
                        try e.snapshot();
                        e.in_insert_group = true;
                    }
                    e.deleteRange(e.cur, text.nextCluster(s, e.cur));
                    e.in_insert_group = true;
                }
                try e.insertCp(c);
            },
            .ctrl => |c| switch (c) {
                'a' => e.cur = text.lineStart(s, e.cur),
                'e' => e.cur = text.lineEnd(s, e.cur),
                'b' => e.cur = text.prevCluster(s, e.cur),
                'f' => e.cur = text.nextCluster(s, e.cur),
                'p' => try e.lineUp(),
                'n' => try e.lineDown(),
                'd' => {
                    if (s.len == 0) return .eof;
                    if (e.cur < s.len) {
                        try e.change();
                        e.deleteRange(e.cur, text.nextCluster(s, e.cur));
                    }
                },
                'h' => try e.backspace(),
                'k' => {
                    e.last_kill = was_kill;
                    const end = text.lineEnd(s, e.cur);
                    try e.kill(e.cur, if (end == e.cur and end < s.len) end + 1 else end, false);
                    e.last_kill = true;
                },
                'u' => {
                    e.last_kill = was_kill;
                    try e.kill(text.lineStart(s, e.cur), e.cur, true);
                    e.last_kill = true;
                },
                'w' => {
                    e.last_kill = was_kill;
                    try e.kill(text.prevWordStart(s, e.cur, true), e.cur, true);
                    e.last_kill = true;
                },
                'y' => try e.yank(),
                't' => try e.transpose(),
                'l' => return .clear_screen,
                'c' => return .interrupt,
                'r' => {
                    e.searching = true;
                    e.query.clearRetainingCapacity();
                    e.found = null;
                },
                '_' => try e.restore(&e.undo, &e.redo),
                'x' => e.pending = .ctrl_x,
                'j' => return e.enter(),
                else => {},
            },
            .special => |sp| switch (sp) {
                .enter => return e.enter(),
                .tab => return .complete,
                .backspace => try e.backspace(),
                .delete => if (e.cur < s.len) {
                    try e.change();
                    e.deleteRange(e.cur, text.nextCluster(s, e.cur));
                },
                .left => e.cur = if (k.ctrl) text.emacsBackward(s, e.cur) else text.prevCluster(s, e.cur),
                .right => e.cur = if (k.ctrl) text.emacsForward(s, e.cur) else text.nextCluster(s, e.cur),
                .home => e.cur = text.lineStart(s, e.cur),
                .end => e.cur = text.lineEnd(s, e.cur),
                .up => try e.lineUp(),
                .down => try e.lineDown(),
                .escape => if (e.vi) {
                    e.toNormal();
                },
                else => {},
            },
            .paste => unreachable,
        }
        return .none;
    }

    fn backspace(e: *Editor) Error!void {
        if (e.cur == 0) return;
        if (!e.in_insert_group) {
            try e.snapshot();
            e.in_insert_group = true;
        }
        e.deleteRange(text.prevCluster(e.buf.items, e.cur), e.cur);
    }

    fn transpose(e: *Editor) Error!void {
        const s = e.buf.items;
        if (s.len < 2 or e.cur == 0) return;
        var at = e.cur;
        if (at >= s.len or s[at] == '\n') at = text.prevCluster(s, at);
        const a0 = text.prevCluster(s, at);
        const a1 = at;
        const b1 = text.nextCluster(s, at);
        if (a0 == a1) return;
        try e.change();
        const first = try e.a.dupe(u8, s[a0..a1]);
        defer e.a.free(first);
        const second = try e.a.dupe(u8, s[a1..b1]);
        defer e.a.free(second);
        @memcpy(e.buf.items[a0 .. a0 + second.len], second);
        @memcpy(e.buf.items[a0 + second.len .. b1], first);
        e.cur = b1;
    }

    /// Enter: the command runs when it is complete. An open brace,
    /// bracket, or quote adds a new line.
    fn enter(e: *Editor) Error!Action {
        if (e.host.complete(e.host.ctx, e.buf.items)) return .accept;
        e.cur = e.buf.items.len;
        try e.insertText("\n");
        e.in_insert_group = false;
        return .none;
    }

    // ---- vim normal mode ----

    fn toNormal(e: *Editor) void {
        e.mode = .normal;
        e.in_insert_group = false;
        if (e.cur > text.lineStart(e.buf.items, e.cur)) e.cur = text.prevCluster(e.buf.items, e.cur);
        e.clampNormal();
        if (e.recording) {
            e.recording = false;
            if (!e.replaying) {
                e.dot.clearRetainingCapacity();
                e.dot.appendSlice(e.a, e.dot_now.items) catch {};
            }
        }
    }

    /// In normal mode the cursor is on a character. It is never after the last.
    fn clampNormal(e: *Editor) void {
        const s = e.buf.items;
        const end = text.lineEnd(s, e.cur);
        if (e.cur >= end and end > text.lineStart(s, e.cur)) e.cur = text.prevCluster(s, end);
    }

    fn takeCount(e: *Editor) usize {
        const n = if (e.count == 0) 1 else e.count;
        e.count = 0;
        return n;
    }

    fn regIndex(r: u8) usize {
        return if (r >= 'a' and r <= 'z') r - 'a' + 1 else 0;
    }

    fn setRegister(e: *Editor, s: []const u8) Error!void {
        const copy = try e.a.dupe(u8, s);
        const i = regIndex(e.register);
        if (e.registers[i]) |old| e.a.free(old);
        e.registers[i] = copy;
        if (i != 0) {
            if (e.registers[0]) |old| e.a.free(old);
            e.registers[0] = try e.a.dupe(u8, s);
        }
        e.register = '"';
    }

    /// The end of a motion from the cursor, or null for an unknown key.
    /// `incl` is set for a motion that includes its last character.
    fn motion(e: *Editor, c: u21, n: usize, incl: *bool) ?usize {
        const s = e.buf.items;
        var p = e.cur;
        incl.* = false;
        switch (c) {
            'h' => for (0..n) |_| {
                if (p > text.lineStart(s, p)) p = text.prevCluster(s, p);
            },
            'l', ' ' => for (0..n) |_| {
                if (p < text.lineEnd(s, p)) p = text.nextCluster(s, p);
            },
            'w' => for (0..n) |_| {
                p = text.nextWordStart(s, p, false);
            },
            'W' => for (0..n) |_| {
                p = text.nextWordStart(s, p, true);
            },
            'b' => for (0..n) |_| {
                p = text.prevWordStart(s, p, false);
            },
            'B' => for (0..n) |_| {
                p = text.prevWordStart(s, p, true);
            },
            'e', 'E' => {
                for (0..n) |_| p = text.wordEnd(s, p, c == 'E');
                incl.* = true;
            },
            '0' => p = text.lineStart(s, p),
            '^' => p = text.firstNonBlank(s, p),
            '$' => {
                p = text.lineEnd(s, p);
                incl.* = false;
            },
            else => return null,
        }
        return p;
    }

    /// `f t F T` from the cursor: the position, or null.
    fn findChar(e: *Editor, kind: u8, ch: u21, n: usize) ?usize {
        const s = e.buf.items;
        var p = e.cur;
        const start = text.lineStart(s, p);
        const end = text.lineEnd(s, p);
        var left = n;
        if (kind == 'f' or kind == 't') {
            var q = text.nextCluster(s, p);
            if (kind == 't' and q < end) q = text.nextCluster(s, q);
            while (q < end) : (q = text.nextCluster(s, q)) {
                if (text.decode(s, q).cp == ch) {
                    left -= 1;
                    if (left == 0) {
                        p = q;
                        break;
                    }
                }
            } else return null;
            if (kind == 't') p = text.prevCluster(s, p);
        } else {
            var q = p;
            if (kind == 'T' and q > start) q = text.prevCluster(s, q);
            while (q > start) {
                q = text.prevCluster(s, q);
                if (text.decode(s, q).cp == ch) {
                    left -= 1;
                    if (left == 0) {
                        p = q;
                        break;
                    }
                }
            } else return null;
            if (kind == 'T') p = text.nextCluster(s, p);
        }
        return p;
    }

    /// The span of a text object at the cursor, or null.
    fn object(e: *Editor, c: u21, around: bool) ?[2]usize {
        const s = e.buf.items;
        if (s.len == 0) return null;
        const p = @min(e.cur, s.len - 1);
        switch (c) {
            'w', 'W' => {
                const big = c == 'W';
                const isWord = struct {
                    fn f(t: []const u8, i: usize, b: bool) bool {
                        const ch = t[i];
                        if (ch == ' ' or ch == '\t' or ch == '\n') return false;
                        if (b) return true;
                        return ch == '_' or std.ascii.isAlphanumeric(ch) or ch >= 128;
                    }
                }.f;
                const word = isWord(s, p, big);
                var a = p;
                var b = p;
                while (a > 0 and isWord(s, a - 1, big) == word and s[a - 1] != ' ' and s[a - 1] != '\n') a -= 1;
                while (b < s.len and isWord(s, b, big) == word and s[b] != ' ' and s[b] != '\n') b += 1;
                if (around) {
                    while (b < s.len and s[b] == ' ') b += 1;
                }
                return .{ a, b };
            },
            '"', '\'' => {
                // The quotes of the line pair in order. The pair that
                // holds the cursor wins, else the first pair after it.
                const q: u8 = @intCast(c);
                const ls = text.lineStart(s, p);
                const le = text.lineEnd(s, p);
                var i = ls;
                while (std.mem.indexOfScalarPos(u8, s[0..le], i, q)) |o| {
                    const close = std.mem.indexOfScalarPos(u8, s[0..le], o + 1, q) orelse return null;
                    if (p <= close) return if (around) .{ o, close + 1 } else .{ o + 1, close };
                    i = close + 1;
                }
                return null;
            },
            '(', ')', 'b', '[', ']', '{', '}', 'B' => {
                const pair: [2]u8 = switch (c) {
                    '(', ')', 'b' => .{ '(', ')' },
                    '[', ']' => .{ '[', ']' },
                    else => .{ '{', '}' },
                };
                // The nearest open bracket before the cursor with its match.
                var depth: usize = 0;
                var i = p + 1;
                const o = while (i > 0) {
                    i -= 1;
                    if (s[i] == pair[1] and i != p) depth += 1;
                    if (s[i] == pair[0]) {
                        if (depth == 0) break i;
                        depth -= 1;
                    }
                } else return null;
                depth = 0;
                var j = o + 1;
                const close = while (j < s.len) : (j += 1) {
                    if (s[j] == pair[0]) depth += 1;
                    if (s[j] == pair[1]) {
                        if (depth == 0) break j;
                        depth -= 1;
                    }
                } else return null;
                return if (around) .{ o, close + 1 } else .{ o + 1, close };
            },
            else => return null,
        }
    }

    /// Applies operator `op` to the span, and ends the command.
    fn apply(e: *Editor, op: u8, start: usize, end: usize) Error!void {
        if (end < start) return e.apply(op, end, start);
        try e.setRegister(e.buf.items[start..end]);
        switch (op) {
            'y' => e.cur = start,
            'd' => {
                try e.change();
                e.deleteRange(start, end);
                e.cur = start;
                e.clampNormal();
            },
            'c' => {
                try e.change();
                e.deleteRange(start, end);
                e.cur = start;
                e.mode = .insert;
                e.in_insert_group = true;
            },
            '~' => {
                try e.change();
                for (e.buf.items[start..end]) |*ch| {
                    ch.* = if (std.ascii.isUpper(ch.*)) std.ascii.toLower(ch.*) else std.ascii.toUpper(ch.*);
                }
                e.cur = start;
            },
            else => {},
        }
    }

    fn beginChange(e: *Editor, k: Key) Error!void {
        if (e.replaying) return;
        e.dot_now.clearRetainingCapacity();
        e.recording = true;
        try e.dot_now.append(e.a, k);
    }

    /// Ends a change of normal mode that has no insert after it.
    fn endChange(e: *Editor) void {
        // An operator, `r`, or `f` waits for more keys of the same change.
        if (!e.recording or e.mode != .normal or e.pending != .none) return;
        e.recording = false;
        if (e.replaying) return;
        e.dot.clearRetainingCapacity();
        e.dot.appendSlice(e.a, e.dot_now.items) catch {};
    }

    fn normalKey(e: *Editor, k: Key) Error!Action {
        // The keys of the command that goes on are kept for `.`.
        if (e.recording and !e.replaying) try e.dot_now.append(e.a, k);
        const act = try e.normalKey2(k);
        e.endChange();
        return act;
    }

    fn normalKey2(e: *Editor, k: Key) Error!Action {
        const s = e.buf.items;
        switch (k.code) {
            .special => |sp| switch (sp) {
                .escape => {
                    e.pending = .none;
                    e.count = 0;
                    e.recording = false;
                    if (e.mode == .visual) e.mode = .normal;
                    return .none;
                },
                .enter => return e.enter(),
                .left => return e.normalKey2(Key.ch('h')),
                .right => return e.normalKey2(Key.ch('l')),
                .up => return e.normalKey2(Key.ch('k')),
                .down => return e.normalKey2(Key.ch('j')),
                .home => return e.normalKey2(Key.ch('0')),
                .end => return e.normalKey2(Key.ch('$')),
                .backspace => return e.normalKey2(Key.ch('h')),
                .delete => return e.normalKey2(Key.ch('x')),
                else => return .none,
            },
            .ctrl => |c| switch (c) {
                'r' => {
                    try e.restore(&e.redo, &e.undo);
                    return .none;
                },
                'c' => return .interrupt,
                'l' => return .clear_screen,
                'd' => return if (s.len == 0) .eof else .none,
                else => return .none,
            },
            .paste => unreachable,
            .char => {},
        }
        const c = k.code.char;
        // A key that completes a pending command.
        switch (e.pending) {
            .register => {
                e.pending = .none;
                if (c < 128) e.register = @intCast(c);
                return .none;
            },
            .replace_char => {
                e.pending = .none;
                const n = e.takeCount();
                try e.change();
                var p = e.cur;
                for (0..n) |_| {
                    if (p >= text.lineEnd(s, p)) break;
                    const q = text.nextCluster(e.buf.items, p);
                    e.deleteRange(p, q);
                    e.cur = p;
                    var b: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(c, &b) catch 1;
                    try e.buf.insertSlice(e.a, p, b[0..len]);
                    p += len;
                }
                e.cur = if (p > 0) text.prevCluster(e.buf.items, p) else 0;
                return .none;
            },
            .find => |f| {
                e.pending = .none;
                e.last_find = .{ .kind = f.kind, .ch = c };
                const n = e.takeCount() * (if (e.op_count == 0) 1 else e.op_count);
                e.op_count = 0;
                const p = e.findChar(f.kind, c, n) orelse return .none;
                if (f.op != 0) return e.applyOp(f.op, p, true);
                e.cur = p;
                return .none;
            },
            .object => |o| {
                e.pending = .none;
                e.count = 0;
                const span = e.object(c, o.around) orelse return .none;
                if (o.op == 'v') {
                    e.visual_start = span[0];
                    e.cur = if (span[1] > span[0]) text.prevCluster(s, span[1]) else span[0];
                    return .none;
                }
                try e.apply(o.op, span[0], span[1]);
                return .none;
            },
            .op => |op| {
                if (c >= '1' and c <= '9' or (c == '0' and e.count > 0)) {
                    e.count = e.count * 10 + (c - '0');
                    return .none;
                }
                if (c == op) {
                    // A doubled operator: the whole line.
                    e.pending = .none;
                    e.count = 0;
                    const ls = text.lineStart(s, e.cur);
                    var le = text.lineEnd(s, e.cur);
                    if (op == 'd' and le < s.len) le += 1;
                    if (op == 'c') {
                        try e.apply('c', ls, text.lineEnd(s, e.cur));
                    } else try e.apply(op, ls, le);
                    return .none;
                }
                if (c == 'i' or c == 'a') {
                    e.pending = .{ .object = .{ .op = op, .around = c == 'a' } };
                    return .none;
                }
                if (c == 'f' or c == 't' or c == 'F' or c == 'T') {
                    e.pending = .{ .find = .{ .kind = @intCast(c), .op = op } };
                    return .none;
                }
                e.pending = .none;
                var incl = false;
                const n = e.takeCount() * (if (e.op_count == 0) 1 else e.op_count);
                e.op_count = 0;
                // `cw` changes to the end of the word, as in vim.
                const mc: u21 = if (op == 'c' and c == 'w') 'e' else if (op == 'c' and c == 'W') 'E' else c;
                const p = e.motion(mc, n, &incl) orelse return .none;
                return e.applyOp(op, p, incl);
            },
            .ctrl_x, .none => {},
        }
        if (c >= '1' and c <= '9' or (c == '0' and e.count > 0)) {
            e.count = e.count * 10 + (c - '0');
            return .none;
        }
        if (e.mode == .visual) return e.visualKey(c);
        switch (c) {
            'i' => try e.toInsert(k, e.cur),
            'a' => try e.toInsert(k, if (e.cur < text.lineEnd(s, e.cur)) text.nextCluster(s, e.cur) else e.cur),
            'I' => try e.toInsert(k, text.firstNonBlank(s, e.cur)),
            'A' => try e.toInsert(k, text.lineEnd(s, e.cur)),
            'o', 'O' => {
                try e.beginChange(k);
                try e.change();
                const at = if (c == 'o') text.lineEnd(s, e.cur) else text.lineStart(s, e.cur);
                try e.buf.insert(e.a, at, '\n');
                e.cur = if (c == 'o') at + 1 else at;
                e.mode = .insert;
                e.in_insert_group = true;
            },
            'R' => {
                try e.beginChange(k);
                e.mode = .replace;
                e.in_insert_group = false;
            },
            'x', 'X' => {
                try e.beginChange(k);
                const n = e.takeCount();
                var incl = false;
                if (c == 'x') {
                    _ = &incl;
                    const end = blk: {
                        var p = e.cur;
                        for (0..n) |_| {
                            if (p < text.lineEnd(s, p)) p = text.nextCluster(s, p);
                        }
                        break :blk p;
                    };
                    try e.apply('d', e.cur, end);
                } else {
                    var p = e.cur;
                    for (0..n) |_| {
                        if (p > text.lineStart(s, p)) p = text.prevCluster(s, p);
                    }
                    try e.apply('d', p, e.cur);
                }
            },
            's' => {
                try e.beginChange(k);
                const n = e.takeCount();
                var p = e.cur;
                for (0..n) |_| {
                    if (p < text.lineEnd(s, p)) p = text.nextCluster(s, p);
                }
                try e.apply('c', e.cur, p);
            },
            'S' => {
                try e.beginChange(k);
                e.count = 0;
                try e.apply('c', text.lineStart(s, e.cur), text.lineEnd(s, e.cur));
            },
            'D' => {
                try e.beginChange(k);
                e.count = 0;
                try e.apply('d', e.cur, text.lineEnd(s, e.cur));
            },
            'C' => {
                try e.beginChange(k);
                e.count = 0;
                try e.apply('c', e.cur, text.lineEnd(s, e.cur));
            },
            'Y' => {
                e.count = 0;
                try e.apply('y', text.lineStart(s, e.cur), text.lineEnd(s, e.cur));
            },
            'd', 'c', 'y' => {
                if (c != 'y') try e.beginChange(k);
                e.op_count = e.count;
                e.count = 0;
                e.pending = .{ .op = @intCast(c) };
            },
            'r' => {
                try e.beginChange(k);
                e.pending = .replace_char;
            },
            '"' => e.pending = .register,
            'f', 't', 'F', 'T' => e.pending = .{ .find = .{ .kind = @intCast(c), .op = 0 } },
            ';', ',' => if (e.last_find) |lf| {
                var kind = lf.kind;
                if (c == ',') kind = switch (kind) {
                    'f' => 'F',
                    'F' => 'f',
                    't' => 'T',
                    else => 't',
                };
                if (e.findChar(kind, lf.ch, e.takeCount())) |p| e.cur = p;
            },
            'p', 'P' => {
                try e.beginChange(k);
                const n = e.takeCount();
                const reg = e.registers[regIndex(e.register)] orelse return .none;
                e.register = '"';
                try e.change();
                var at = e.cur;
                if (c == 'p' and e.cur < text.lineEnd(s, e.cur)) at = text.nextCluster(s, e.cur);
                for (0..n) |_| {
                    try e.buf.insertSlice(e.a, at, reg);
                    at += reg.len;
                }
                e.cur = if (at > 0) text.prevCluster(e.buf.items, at) else 0;
            },
            'u' => try e.restore(&e.undo, &e.redo),
            '.' => {
                const n = e.takeCount();
                const saved = try e.a.dupe(Key, e.dot.items);
                defer e.a.free(saved);
                e.replaying = true;
                defer e.replaying = false;
                for (0..n) |_| {
                    for (saved) |dk| _ = try e.handle(dk);
                }
            },
            '~' => {
                try e.beginChange(k);
                const n = e.takeCount();
                var p = e.cur;
                for (0..n) |_| {
                    if (p < text.lineEnd(s, p)) p = text.nextCluster(s, p);
                }
                try e.apply('~', e.cur, p);
                e.cur = p;
                e.clampNormal();
            },
            'j' => for (0..e.takeCount()) |_| try e.lineDown(),
            'k' => for (0..e.takeCount()) |_| try e.lineUp(),
            'V' => {
                e.mode = .visual;
                e.visual_start = e.cur;
            },
            'v' => return .open_editor,
            '/' => {
                e.searching = true;
                e.query.clearRetainingCapacity();
                e.found = null;
            },
            else => {
                var incl = false;
                if (e.motion(c, e.takeCount(), &incl)) |p| {
                    e.cur = p;
                    e.clampNormal();
                }
            },
        }
        return .none;
    }

    fn toInsert(e: *Editor, k: Key, at: usize) Error!void {
        try e.beginChange(k);
        e.count = 0;
        e.cur = at;
        e.mode = .insert;
        e.in_insert_group = false;
    }

    /// An operator with the motion to `p`.
    fn applyOp(e: *Editor, op: u8, p: usize, incl: bool) Error!Action {
        var end = p;
        if (incl or p < e.cur) {
            if (p >= e.cur) end = text.nextCluster(e.buf.items, p);
        }
        if (p < e.cur and incl) end = p;
        try e.apply(op, @min(e.cur, end), @max(e.cur, end));
        return .none;
    }

    fn visualKey(e: *Editor, c: u21) Error!Action {
        const s = e.buf.items;
        const a = @min(e.visual_start, e.cur);
        const b = if (s.len == 0) 0 else text.nextCluster(s, @max(e.visual_start, e.cur));
        switch (c) {
            'd', 'x', 'c', 'y', '~' => {
                e.mode = .normal;
                const op: u8 = if (c == 'x') 'd' else @intCast(c);
                try e.apply(op, a, b);
            },
            'i', 'a' => e.pending = .{ .object = .{ .op = 'v', .around = c == 'a' } },
            'o' => {
                const t = e.visual_start;
                e.visual_start = e.cur;
                e.cur = t;
            },
            else => {
                var incl = false;
                if (e.motion(c, e.takeCount(), &incl)) |p| e.cur = p;
            },
        }
        return .none;
    }

    /// The selection of the visual mode: start and end, or null.
    pub fn selection(e: *const Editor) ?[2]usize {
        if (e.mode != .visual or e.buf.items.len == 0) return null;
        return .{ @min(e.visual_start, e.cur), text.nextCluster(e.buf.items, @max(e.visual_start, e.cur)) };
    }

    /// Replaces the word before the cursor (from `start`) with `s`, for
    /// a completion.
    pub fn replaceWord(e: *Editor, start: usize, s: []const u8) Error!void {
        try e.change();
        e.deleteRange(start, e.cur);
        e.cur = start;
        try e.buf.insertSlice(e.a, e.cur, s);
        e.cur += s.len;
    }
};

// ---- Tests ----

fn typeKeys(e: *Editor, s: []const u8) !void {
    var d = keys.Decoder.init(std.testing.allocator);
    defer d.deinit();
    try d.feed(s);
    while (try d.next(true)) |k| _ = try e.handle(k);
}

fn expectState(e: *const Editor, want: []const u8) !void {
    // `|` marks the cursor in `want`.
    const bar = std.mem.indexOfScalar(u8, want, '|').?;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    try got.appendSlice(std.testing.allocator, e.buf.items[0..e.cur]);
    try got.append(std.testing.allocator, '|');
    try got.appendSlice(std.testing.allocator, e.buf.items[e.cur..]);
    _ = bar;
    try std.testing.expectEqualStrings(want, got.items);
}

test "editor: emacs keys" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();
    try typeKeys(&e, "set foo bar");
    try expectState(&e, "set foo bar|");
    try typeKeys(&e, "\x01");
    try expectState(&e, "|set foo bar");
    try typeKeys(&e, "\x1bf\x1bf");
    try expectState(&e, "set foo| bar");
    try typeKeys(&e, "\x17");
    try expectState(&e, "set | bar");
    try typeKeys(&e, "\x19");
    try expectState(&e, "set foo| bar");
    try typeKeys(&e, "\x05\x15");
    try expectState(&e, "|");
    try typeKeys(&e, "\x19");
    try expectState(&e, "set foo bar|");
    // Ctrl-T swaps the characters around the cursor.
    try typeKeys(&e, "\x02\x02\x14");
    try expectState(&e, "set foo ab|r");
    try typeKeys(&e, "\x1f");
    try expectState(&e, "set foo b|ar");
    try typeKeys(&e, "\x05");
    // Ctrl-K, then Ctrl-K again: the kills join.
    try typeKeys(&e, "\x01\x1bf\x0b");
    try expectState(&e, "set|");
    try typeKeys(&e, "\x19");
    try expectState(&e, "set foo bar|");
}

test "editor: multi-line input and the line keys" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();
    e.host = .{ .complete = struct {
        fn f(_: ?*anyopaque, t: []const u8) bool {
            return std.mem.count(u8, t, "{") == std.mem.count(u8, t, "}");
        }
    }.f };
    try typeKeys(&e, "proc f {} {\r");
    try expectState(&e, "proc f {} {\n|");
    try typeKeys(&e, "  return 1\r}");
    try expectState(&e, "proc f {} {\n  return 1\n}|");
    try typeKeys(&e, "\x1b[A\x1b[A");
    try expectState(&e, "p|roc f {} {\n  return 1\n}");
    var d = keys.Decoder.init(std.testing.allocator);
    defer d.deinit();
    try d.feed("\r");
    try std.testing.expectEqual(Action.accept, try e.handle((try d.next(true)).?));
}

test "editor: history with a prefix, and the fuzzy search" {
    var h = History.init(std.testing.allocator);
    defer h.deinit();
    try h.add("set a 1");
    try h.add("puts hello");
    try h.add("set b 2");
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();
    e.history = &h;
    try typeKeys(&e, "\x1b[A");
    try expectState(&e, "set b 2|");
    try typeKeys(&e, "\x1b[A\x1b[A");
    try expectState(&e, "set a 1|");
    try typeKeys(&e, "\x1b[B\x1b[B\x1b[B");
    try expectState(&e, "|");
    try typeKeys(&e, "set\x1b[A");
    try expectState(&e, "set b 2|");
    try typeKeys(&e, "\x1b[A");
    try expectState(&e, "set a 1|");
    e.reset();
    try typeKeys(&e, "\x12phl");
    try std.testing.expectEqualStrings("puts hello", e.searchLine().?.match.?);
    try typeKeys(&e, "\x05");
    try expectState(&e, "puts hello|");
}

test "editor: vim motions, operators, and text objects" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();
    e.setVi(true);
    try typeKeys(&e, "set foo [list a b] \"x y\"\x1b");
    try expectState(&e, "set foo [list a b] \"x y|\"");
    try typeKeys(&e, "0w");
    try expectState(&e, "set |foo [list a b] \"x y\"");
    try typeKeys(&e, "dw");
    try expectState(&e, "set |[list a b] \"x y\"");
    try typeKeys(&e, "u");
    try expectState(&e, "set |foo [list a b] \"x y\"");
    try typeKeys(&e, "fbci[l\x1b");
    try expectState(&e, "set foo [|l] \"x y\"");
    try typeKeys(&e, "$di\"");
    try expectState(&e, "set foo [l] \"|\"");
    try typeKeys(&e, "0cwput\x1b");
    try expectState(&e, "pu|t foo [l] \"\"");
    try typeKeys(&e, "w.");
    try expectState(&e, "put pu|t [l] \"\"");
    try typeKeys(&e, "02x");
    try expectState(&e, "|t put [l] \"\"");
    try typeKeys(&e, "$p");
    try expectState(&e, "t put [l] \"\"p|u");
    // After `p` the cursor is on the last character of the text.
    try typeKeys(&e, "0\"ayiw$\"ap");
    try expectState(&e, "t put [l] \"\"pu|t");
    try typeKeys(&e, "0~~");
    try expectState(&e, "T |put [l] \"\"put");
    try typeKeys(&e, "Vee\x1b");
    try typeKeys(&e, "0Vlld");
    try expectState(&e, "|ut [l] \"\"put");
    try typeKeys(&e, "3l");
    try expectState(&e, "ut |[l] \"\"put");
    try typeKeys(&e, "rx");
    try expectState(&e, "ut |xl] \"\"put");
    try typeKeys(&e, "ddiabc\x1b");
    try expectState(&e, "ab|c");
}

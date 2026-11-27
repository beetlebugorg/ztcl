//! The static scan of `ztcl build --strip` and `ztk bundle --strip`.
//!
//! `Scan.script` parses a script with the parser of the interpreter and
//! walks each command: the commands in `[...]`, and each literal word
//! that has a space, a tab, a newline, or a `;`, as a script of its
//! own (a body of `proc`, `if`, `foreach`, a `-command` option). For
//! each command it records:
//!
//! - the name, when the first word is a literal;
//! - the pairs "name word" for the second word and for each later word
//!   that starts with `-`, so a table entry such as "switch -regexp" or
//!   "info object" matches;
//! - each literal word, for the token rule of `Plan` (`trust`);
//! - the names of `package require`;
//! - a dynamic site for a name that is not a literal (`$cmd args`), a
//!   script that is not a literal (`eval $x`, `uplevel $body`, `subst`,
//!   `namespace eval ns $body`, `interp eval`), and a `package require`
//!   or a `source` of a name that is not a literal.
//!
//! `plan` maps the records to the features of `features_table.zig`. A
//! feature of the capability kind stays only when the program has the
//! capability. A feature of the commands kind or the capability kind
//! stays when the scan saw one of its commands or options, and stays
//! for any dynamic site of a command name or a script, unless `trust`
//! is on: then a literal word anywhere in the scripts that names one of
//! its commands keeps it. A module stays when a `package require` names
//! it or one of its commands is used, and each module stays for a
//! `package require` of a computed name.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const ft = @import("features_table.zig");

const Allocator = std.mem.Allocator;
const Interp = interp.Interp;

pub const SiteKind = enum {
    computed_command,
    computed_script,
    computed_package,
    computed_source,

    pub fn text(k: SiteKind) []const u8 {
        return switch (k) {
            .computed_command => "computed command name",
            .computed_script => "eval of computed text",
            .computed_package => "package require of a computed name",
            .computed_source => "source of a computed path",
        };
    }
};

pub const Site = struct {
    file: []const u8,
    line: u32,
    kind: SiteKind,
    /// The first line of the command, at most 72 bytes.
    text: []const u8,
};

const Set = std.StringArrayHashMapUnmanaged(void);

pub const Scan = struct {
    a: Allocator,
    commands: Set = .empty,
    pairs: Set = .empty,
    words: Set = .empty,
    packages: Set = .empty,
    sites: std.ArrayList(Site) = .empty,
    file: []const u8 = "",
    /// The line of the start of the text in its file, less 1.
    base: u32 = 0,

    pub fn init(a: Allocator) Scan {
        return .{ .a = a };
    }

    /// Adds the records of the script `text` of the file `file`.
    pub fn script(s: *Scan, it: *Interp, file: []const u8, text: []const u8) Allocator.Error!void {
        s.file = file;
        s.base = 0;
        try s.walkText(it, text, 0, true);
    }

    /// Gives the count of the dynamic sites of the kind `k`.
    pub fn count(s: *const Scan, k: SiteKind) usize {
        var n: usize = 0;
        for (s.sites.items) |x| n += @intFromBool(x.kind == k);
        return n;
    }

    /// Walks `text` as a script. `sure` is false for a literal word that
    /// may be data: its commands are recorded, and its dynamic sites are
    /// not, since `$a and $b` in a message is no command.
    fn walkText(s: *Scan, it: *Interp, text: []const u8, depth: u32, sure: bool) Allocator.Error!void {
        if (depth > 64) return;
        const sc = it.compile(text) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return;
        };
        try s.walk(it, sc, depth, sure);
    }

    fn walk(s: *Scan, it: *Interp, sc: *interp.Script, depth: u32, sure: bool) Allocator.Error!void {
        for (sc.cmds) |*c| try s.command(it, c, depth, sure);
    }

    fn command(s: *Scan, it: *Interp, c: *const interp.Cmd, depth: u32, sure: bool) Allocator.Error!void {
        const w = c.words;
        if (w.len == 0) return;
        const name: []const u8 = if (lit(&w[0])) |n| std.mem.trimStart(u8, n, ":") else "";
        if (name.len > 0) {
            try s.commands.put(s.a, try s.a.dupe(u8, name), {});
            for (w[1..], 1..) |*wd, i| {
                const t = lit(wd) orelse continue;
                if (i == 1 or (t.len > 1 and t[0] == '-')) try s.pairs.put(s.a, try std.fmt.allocPrint(s.a, "{s} {s}", .{ name, t }), {});
                if (i == 2 and t.len > 1 and t[0] == '-') if (lit(&w[1])) |sub|
                    try s.pairs.put(s.a, try std.fmt.allocPrint(s.a, "{s} {s} {s}", .{ name, sub, t }), {});
            }
            if (sure) try s.dynamic(c, name);
        } else if (sure) try s.site(c, .computed_command);
        for (w, 0..) |*wd, i| {
            const r = role(name, w, i);
            if (r == .arms) {
                if (lit(wd)) |t| try s.arms(it, wd, t, depth, sure) else try s.word(it, wd, depth, .data, sure);
            } else try s.word(it, wd, depth, r, sure);
        }
    }

    /// The bodies of a `switch` list: each second element is a script.
    fn arms(s: *Scan, it: *Interp, wd: *const interp.Word, t: []const u8, depth: u32, sure: bool) Allocator.Error!void {
        try s.tokens(t);
        // The last body of the form with no list: its commands are
        // recorded too.
        try s.nested(it, wd, t, depth, false);
        const items = it.list(.{ .str = t }) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return;
        };
        var k: usize = 1;
        while (k < items.len) : (k += 2) {
            const body = it.str(items[k]) catch continue;
            if (std.mem.eql(u8, body, "-")) continue;
            try s.nested(it, wd, body, depth, sure);
        }
    }

    /// Records the dynamic sites of the command `n` at `c`.
    fn dynamic(s: *Scan, c: *const interp.Cmd, n: []const u8) Allocator.Error!void {
        const w = c.words;
        const eql = std.mem.eql;
        if (eql(u8, n, "eval") or eql(u8, n, "subst") or eql(u8, n, "uplevel")) {
            for (w[1..]) |*x| if (lit(x) == null) return s.site(c, .computed_script);
        } else if (eql(u8, n, "namespace") or eql(u8, n, "interp")) {
            if (w.len >= 4 and lit(&w[1]) != null and (eql(u8, lit(&w[1]).?, "eval") or eql(u8, lit(&w[1]).?, "inscope"))) {
                for (w[3..]) |*x| if (lit(x) == null) return s.site(c, .computed_script);
            }
        } else if (eql(u8, n, "package")) {
            if (w.len >= 3 and lit(&w[1]) != null and eql(u8, lit(&w[1]).?, "require")) {
                var i: usize = 2;
                while (i < w.len) : (i += 1) {
                    const t = lit(&w[i]) orelse return s.site(c, .computed_package);
                    if (eql(u8, t, "-exact")) continue;
                    try s.packages.put(s.a, try s.a.dupe(u8, t), {});
                    break;
                }
            }
        } else if (eql(u8, n, "source")) {
            if (w.len >= 2 and lit(&w[w.len - 1]) == null) return s.site(c, .computed_source);
        }
    }

    fn word(s: *Scan, it: *Interp, w: *const interp.Word, depth: u32, r: Role, sure: bool) Allocator.Error!void {
        switch (w.kind) {
            .lit => |v| if (v == .str) {
                try s.tokens(v.str);
                switch (r) {
                    .script => try s.nested(it, w, v.str, depth, sure),
                    .expr => try s.exprText(it, w, v.str, depth, sure),
                    .data, .arms => if (std.mem.indexOfAny(u8, v.str, " \t\n;[") != null) try s.nested(it, w, v.str, depth, false),
                }
            },
            .single => |p| try s.part(it, p, depth, sure),
            .multi => |ps| for (ps) |p| try s.part(it, p, depth, sure),
        }
    }

    /// Walks the literal `t` of the word `w` as a script, with the lines
    /// of the sites counted from the line of the word.
    fn nested(s: *Scan, it: *Interp, w: *const interp.Word, t: []const u8, depth: u32, sure: bool) Allocator.Error!void {
        const saved = s.base;
        s.base += if (w.line > 0) w.line - 1 else 0;
        defer s.base = saved;
        try s.walkText(it, t, depth + 1, sure);
    }

    /// Walks each `[...]` of the expression `t` as a script.
    fn exprText(s: *Scan, it: *Interp, w: *const interp.Word, t: []const u8, depth: u32, sure: bool) Allocator.Error!void {
        var i: usize = 0;
        while (i < t.len) : (i += 1) {
            if (t[i] == '\\') {
                i += 1;
                continue;
            }
            if (t[i] != '[') continue;
            var level: usize = 1;
            var j = i + 1;
            while (j < t.len and level > 0) : (j += 1) {
                switch (t[j]) {
                    '\\' => j += 1,
                    '[' => level += 1,
                    ']' => level -= 1,
                    else => {},
                }
            }
            if (level != 0) return;
            try s.nested(it, w, t[i + 1 .. j - 1], depth, sure);
            i = j - 1;
        }
    }

    fn part(s: *Scan, it: *Interp, p: interp.Part, depth: u32, sure: bool) Allocator.Error!void {
        switch (p) {
            .lit => |t| try s.tokens(t),
            .variable => {},
            .script => |sc| try s.walk(it, sc, depth + 1, sure),
        }
    }

    /// Adds each run of name characters of `t` to `words`.
    fn tokens(s: *Scan, t: []const u8) Allocator.Error!void {
        var i: usize = 0;
        while (i < t.len) {
            while (i < t.len and !nameChar(t[i])) i += 1;
            const start = i;
            while (i < t.len and nameChar(t[i])) i += 1;
            if (i > start) {
                const tok = std.mem.trimStart(u8, t[start..i], ":");
                if (tok.len > 0 and !s.words.contains(tok)) try s.words.put(s.a, try s.a.dupe(u8, tok), {});
            }
        }
    }

    fn site(s: *Scan, c: *const interp.Cmd, k: SiteKind) Allocator.Error!void {
        var t = c.text;
        if (std.mem.indexOfScalar(u8, t, '\n')) |nl| t = t[0..nl];
        if (t.len > 72) t = t[0..72];
        try s.sites.append(s.a, .{ .file = s.file, .line = s.base + c.line, .kind = k, .text = try s.a.dupe(u8, t) });
    }
};

/// The part of a word in a command.
const Role = enum {
    /// A script that runs: a body of `proc`, `if`, `while`, `foreach`.
    script,
    /// An expression of `if`, `while`, `for`, `expr`.
    expr,
    /// The list of patterns and bodies of `switch`.
    arms,
    /// Any other word. It may be a script, such as a `-command` option.
    data,
};

/// The role of the word `i` of a command with the literal name `n`
/// (empty for a computed name).
fn role(n: []const u8, w: []const interp.Word, i: usize) Role {
    if (i == 0) return .data;
    const eql = std.mem.eql;
    const prev: []const u8 = lit(&w[i - 1]) orelse "";
    const last = i == w.len - 1;
    if (eql(u8, n, "proc") or eql(u8, n, "method")) return if (i == 3) .script else .data;
    if (eql(u8, n, "constructor")) return if (i == 2) .script else .data;
    if (eql(u8, n, "destructor")) return if (i == 1) .script else .data;
    if (eql(u8, n, "if")) {
        if (i == 1 or eql(u8, prev, "elseif")) return .expr;
        const t = lit(&w[i]) orelse return .data;
        if (eql(u8, t, "then") or eql(u8, t, "else") or eql(u8, t, "elseif")) return .data;
        return .script;
    }
    if (eql(u8, n, "while")) return if (i == 1) .expr else .script;
    if (eql(u8, n, "for")) return if (i == 2) .expr else .script;
    if (eql(u8, n, "expr")) return .expr;
    if (eql(u8, n, "foreach") or eql(u8, n, "lmap")) return if (last) .script else .data;
    if (eql(u8, n, "catch") or eql(u8, n, "time")) return if (i == 1) .script else .data;
    if (eql(u8, n, "eval") or eql(u8, n, "uplevel")) return .script;
    if (eql(u8, n, "try")) return if (i == 1 or last or eql(u8, prev, "finally")) .script else .data;
    if (eql(u8, n, "switch")) return if (last) .arms else .data;
    if (eql(u8, n, "namespace")) {
        const sub = lit(&w[1]) orelse "";
        return if (eql(u8, sub, "eval") and i >= 3) .script else .data;
    }
    if (eql(u8, n, "dict")) {
        const sub = lit(&w[1]) orelse "";
        return if ((eql(u8, sub, "for") or eql(u8, sub, "map") or eql(u8, sub, "with") or eql(u8, sub, "update")) and last) .script else .data;
    }
    return .data;
}

fn nameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == ':';
}

fn lit(w: *const interp.Word) ?[]const u8 {
    if (w.expand) return null;
    return switch (w.kind) {
        .lit => |v| if (v == .str) v.str else null,
        else => null,
    };
}

pub const Options = struct {
    /// The capabilities of the program, as for `--allow`.
    allow: []const u8 = "",
    /// Use the token rule for dynamic sites of command names and scripts.
    trust: bool = false,
    jit: bool = true,
    /// Comma lists of features from `--keep`, `--drop-module`, and the
    /// manifest. A name in `keep` can also be a command, which keeps its
    /// feature.
    keep: []const u8 = "",
    drop: []const u8 = "",
    /// The command names that a profile run recorded (`--profile`). When
    /// set, a feature of the commands kind or the capability kind stays
    /// when the scan saw one of its commands or options as a literal, or
    /// when a recorded command is in it. A dynamic site keeps no feature.
    profile: ?*const Set = null,
};

pub const Plan = PlanOf(ft.table.len);

/// The result of `planFor` for a table of `n` features.
pub fn PlanOf(comptime n: usize) type {
    return struct {
        on: [n]bool,
        why: [n][]const u8,

        /// The comma list of the dropped features of `tbl`, for `-Ddrop`.
        pub fn dropListOf(p: *const @This(), a: Allocator, tbl: []const ft.Feature) Allocator.Error![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (tbl, p.on) |f, v| {
                if (v) continue;
                if (out.items.len > 0) try out.append(a, ',');
                try out.appendSlice(a, f.name);
            }
            return out.items;
        }

        pub fn dropList(p: *const @This(), a: Allocator) Allocator.Error![]const u8 {
            return p.dropListOf(a, &ft.table);
        }
    };
}

/// Gives true when a command of the feature `f` is in `set`.
fn usedIn(f: ft.Feature, set: *const Set) bool {
    for (f.commands) |c| {
        if (std.mem.indexOfScalar(u8, c, ' ') != null) continue;
        if (std.mem.endsWith(u8, c, "::")) {
            for (set.keys()) |k| if (k.len > c.len and std.mem.startsWith(u8, k, c)) return true;
        } else if (set.contains(c)) return true;
    }
    return false;
}

fn pairUsed(f: ft.Feature, s: *const Scan) bool {
    for (f.commands) |c| if (std.mem.indexOfScalar(u8, c, ' ') != null and s.pairs.contains(c)) return true;
    for (f.options) |o| if (s.pairs.contains(o)) return true;
    return false;
}

fn keepHas(list: []const u8, f: ft.Feature) bool {
    if (ft.listHas(list, f.name)) return true;
    var parts = std.mem.splitScalar(u8, list, ',');
    while (parts.next()) |p| {
        const n = std.mem.trimStart(u8, p, ":");
        if (n.len == 0) continue;
        for (f.commands) |c| {
            if (std.mem.endsWith(u8, c, "::")) {
                if (n.len > c.len and std.mem.startsWith(u8, n, c)) return true;
            } else if (std.mem.eql(u8, c, n)) return true;
        }
    }
    return false;
}

/// Maps the records of `s` to the features of the build.
pub fn plan(s: *const Scan, o: Options) Plan {
    return planFor(&ft.table, s, o);
}

/// `plan` for the features of `tbl`, such as the table of ztk.
pub fn planFor(comptime tbl: []const ft.Feature, s: *const Scan, o: Options) PlanOf(tbl.len) {
    var p: PlanOf(tbl.len) = undefined;
    const dyn = s.count(.computed_command) + s.count(.computed_script) > 0;
    const dyn_pkg = s.count(.computed_package) > 0;
    for (tbl, 0..) |f, i| {
        const r: struct { bool, []const u8 } = blk: {
            if (keepHas(o.keep, f)) break :blk .{ true, "kept by --keep" };
            if (ft.listHas(o.drop, f.name)) break :blk .{ false, "left out by --drop-module" };
            switch (f.kind) {
                .engine => break :blk if (o.jit) .{ true, "on by default" } else .{ false, "--no-jit" },
                .module => {
                    for (f.packages) |n| if (s.packages.contains(n)) break :blk .{ true, "package require" };
                    if (usedIn(f, &s.commands)) break :blk .{ true, "a command is used" };
                    if (dyn_pkg) break :blk .{ true, "kept for a package require of a computed name" };
                    break :blk .{ false, "no package require" };
                },
                .capability => if (!ft.listHas(o.allow, f.capability)) break :blk .{ false, "the program has no capability" },
                .commands => {},
            }
            if (usedIn(f, &s.commands)) break :blk .{ true, "a command is used" };
            if (pairUsed(f, s)) break :blk .{ true, "an option is used" };
            if (o.profile) |prof| {
                if (usedIn(f, prof)) break :blk .{ true, "ran in the profile" };
                break :blk .{ false, "not used, and not in the profile" };
            }
            if (dyn and !o.trust) break :blk .{ true, "kept for the dynamic sites" };
            if (dyn and usedIn(f, &s.words)) break :blk .{ true, "a word of the scripts names it" };
            break :blk .{ false, "not used" };
        };
        p.on[i] = r[0];
        p.why[i] = r[1];
    }
    var before = p.on;
    if (ft.closeNeedsIn(tbl, &p.on)) {
        for (&before, p.on, 0..) |b, v, i| if (!b and v) {
            p.why[i] = "a feature in the build needs it";
        };
    }
    return p;
}

test "the scan finds commands, options, packages, and dynamic sites" {
    var it: Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Scan.init(arena.allocator());
    try s.script(&it, "a.tcl",
        \\package require ztcl::json
        \\proc f {x} { switch -regexp -- $x { a.* { return [string length $x] } } }
        \\set c puts
        \\$c hi
        \\eval $c
    );
    try std.testing.expect(s.commands.contains("switch"));
    try std.testing.expect(s.commands.contains("string"));
    try std.testing.expect(s.pairs.contains("switch -regexp"));
    try std.testing.expect(s.packages.contains("ztcl::json"));
    try std.testing.expectEqual(@as(usize, 1), s.count(.computed_command));
    try std.testing.expectEqual(@as(usize, 1), s.count(.computed_script));
    const p = plan(&s, .{ .trust = true });
    try std.testing.expect(p.on[ft.index("regexp").?]);
    try std.testing.expect(p.on[ft.index("json").?]);
    try std.testing.expect(!p.on[ft.index("oo").?]);
    try std.testing.expect(!p.on[ft.index("clock").?]);
    const q = plan(&s, .{});
    try std.testing.expect(q.on[ft.index("oo").?]);
}

test "a capability feature needs the capability" {
    var it: Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Scan.init(arena.allocator());
    try s.script(&it, "a.tcl", "puts [clock seconds]\nafter 10");
    try std.testing.expect(!plan(&s, .{}).on[ft.index("clock").?]);
    const p = plan(&s, .{ .allow = "clock,event" });
    try std.testing.expect(p.on[ft.index("clock").?]);
    try std.testing.expect(p.on[ft.index("event").?]);
    try std.testing.expect(!p.on[ft.index("exec").?]);
    try std.testing.expect(!plan(&s, .{ .allow = "clock", .drop = "clock" }).on[ft.index("clock").?]);
    try std.testing.expect(plan(&s, .{ .keep = "regsub" }).on[ft.index("regexp").?]);
}

//! Small core commands: `array`, `case`, `tcl::prefix`, and the word
//! boundary procs of the Tcl library.
//!
//! `array startsearch` keeps a position in the insert order of the
//! array. A search ends when the count of elements changes.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const cmds = @import("cmds.zig");
const regex = @import("regex.zig");
const trace = @import("trace.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("array", cmdArray);
    try it.register("case", cmdCase);
    try it.register("tcl::prefix", cmdPrefix);
    _ = try it.internNs("tcl");
    try it.register("tcl_wordBreakAfter", wordCmd(.after, "tcl_wordBreakAfter"));
    try it.register("tcl_wordBreakBefore", wordCmd(.before, "tcl_wordBreakBefore"));
    try it.register("tcl_endOfWord", wordCmd(.end, "tcl_endOfWord"));
    try it.register("tcl_startOfNextWord", wordCmd(.next, "tcl_startOfNextWord"));
    try it.register("tcl_startOfPreviousWord", wordCmd(.prev, "tcl_startOfPreviousWord"));
}

// ---- Word boundaries ----

const WordOp = enum { after, before, end, next, prev };

fn isWord(cp: u21) bool {
    if (cp < 128) return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_';
    return true;
}

fn decode(it: *Interp, s: []const u8) Error![]const u21 {
    var out: std.ArrayList(u21) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (i + n <= s.len) {
            if (std.unicode.utf8Decode(s[i .. i + n])) |cp| {
                try out.append(it.alloc(), cp);
                i += n;
                continue;
            } else |_| {}
        }
        try out.append(it.alloc(), s[i]);
        i += 1;
    }
    return out.items;
}

fn wordOp(op: WordOp, t: []const u21, start_in: i64) i64 {
    const n: i64 = @intCast(t.len);
    const w = struct {
        fn at(x: []const u21, i: i64) bool {
            return isWord(x[@intCast(i)]);
        }
    }.at;
    switch (op) {
        .after => {
            var i = @max(start_in, 0);
            while (i + 1 < n) : (i += 1) {
                if (w(t, i) != w(t, i + 1)) return i + 1;
            }
            return -1;
        },
        .before => {
            var i = @min(start_in, n - 1);
            while (i >= 1) : (i -= 1) {
                if (w(t, i) != w(t, i - 1)) return i;
            }
            return -1;
        },
        .end => {
            var i = @max(start_in, 0);
            while (i < n and !w(t, i)) i += 1;
            if (i >= n) return -1;
            while (i < n and w(t, i)) i += 1;
            return i;
        },
        .next => {
            var i = @max(start_in, 0);
            while (i < n and w(t, i)) i += 1;
            while (i < n and !w(t, i)) i += 1;
            return if (i < n) i else -1;
        },
        .prev => {
            var i = @min(start_in, n) - 1;
            while (i >= 0 and !w(t, i)) i -= 1;
            if (i < 0) return -1;
            while (i > 0 and w(t, i - 1)) i -= 1;
            return i;
        },
    }
}

fn wordCmd(comptime op: WordOp, comptime name: []const u8) interp.NativeFn {
    return struct {
        fn call(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len != 3) return it.wrongArgs(name ++ " str start");
            const t = try decode(it, try it.str(argv[1]));
            const start = try cmds.index(it, argv[2], t.len);
            return .{ .int = wordOp(op, t, start) };
        }
    }.call;
}

// ---- case ----

fn cmdCase(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len < 3) return it.wrongArgs("case string ?in? ?pattern body ...? ?default body?");
    const s = try it.str(argv[1]);
    var first: usize = 2;
    if (eql(try it.str(argv[2]), "in")) first = 3;
    var arms = argv[first..];
    var from_list = false;
    if (arms.len == 1) {
        arms = try it.list(arms[0]);
        from_list = true;
    }
    if (arms.len % 2 != 0) return it.fail("extra case pattern with no body", .{});
    var chosen: ?usize = null;
    var i: usize = 0;
    outer: while (i < arms.len) : (i += 2) {
        const pat = try it.str(arms[i]);
        if (eql(pat, "default")) {
            chosen = chosen orelse i;
            continue;
        }
        for (try it.list(arms[i])) |p| {
            if (cmds.globMatch(try it.str(p), s, false)) {
                chosen = i;
                break :outer;
            }
        }
    }
    const k = chosen orelse return Value.empty;
    const script = if (from_list) try it.scriptOfValue(arms[k + 1], null) else try it.scriptOf(argv, first + k + 1, cmd);
    return it.evalScript(script) catch |e| {
        if (e == error.TclError and it.in_error) {
            try it.error_info.print(it.alloc(), "\n    (\"{s}\" arm line {d})", .{ try it.str(arms[k]), it.error_line });
        }
        return e;
    };
}

// ---- tcl::prefix ----

/// Writes "a, b, or c".
fn joinChoices(it: *Interp, out: *std.ArrayList(u8), items: []const Value) Error!void {
    const a = it.alloc();
    for (items, 0..) |v, i| {
        if (i > 0) try out.appendSlice(a, if (items.len == 2) " " else ", ");
        if (i > 0 and i == items.len - 1) try out.appendSlice(a, "or ");
        try out.appendSlice(a, try it.str(v));
    }
}

fn prefixMatch(it: *Interp, args: []const Value) Error!Value {
    const a = it.alloc();
    if (args.len < 2) return it.wrongArgs("tcl::prefix match ?options? table string");
    var exact = false;
    var what: []const u8 = "option";
    var err_opts: ?[]const Value = null;
    var i: usize = 0;
    while (i + 2 < args.len) : (i += 1) {
        const o = try it.str(args[i]);
        if (eql(o, "-exact")) {
            exact = true;
        } else if (eql(o, "-message")) {
            i += 1;
            if (i + 2 >= args.len) return it.fail("missing value for -message", .{});
            what = try it.str(args[i]);
        } else if (eql(o, "-error")) {
            i += 1;
            if (i + 2 >= args.len) return it.fail("missing value for -error", .{});
            const l = try listOrError(it, args[i]);
            if (l.len % 2 != 0) return it.fail("error options must have an even number of elements", .{});
            err_opts = l;
        } else return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -error, -exact, or -message", .{o});
    }
    const table = try listOrError(it, args[args.len - 2]);
    const word = try it.str(args[args.len - 1]);
    var found: ?Value = null;
    var count: usize = 0;
    for (table) |v| {
        const t = try it.str(v);
        if (eql(t, word)) return v;
        if (!exact and word.len > 0 and std.mem.startsWith(u8, t, word)) {
            found = v;
            count += 1;
        }
    }
    if (count == 1) return found.?;
    var msg: std.ArrayList(u8) = .empty;
    if (table.len == 0) {
        try msg.print(a, "bad {s} \"{s}\": no valid options", .{ what, word });
    } else {
        try msg.print(a, "{s} {s} \"{s}\": must be ", .{ if (count > 1) "ambiguous" else "bad", what, word });
        try joinChoices(it, &msg, table);
    }
    const code = try value.newList(a, &.{ .{ .str = "TCL" }, .{ .str = "LOOKUP" }, .{ .str = "INDEX" }, .{ .str = what }, .{ .str = word } });
    if (err_opts) |opts| {
        if (opts.len == 0) return Value.empty;
        var words: std.ArrayList(Value) = .empty;
        try words.appendSlice(a, &.{ .{ .str = "::return" }, .{ .str = "-code" }, .{ .str = "error" }, .{ .str = "-errorcode" }, code });
        try words.appendSlice(a, opts);
        try words.append(a, .{ .str = msg.items });
        return it.callWords(words.items);
    }
    it.result = .{ .str = msg.items };
    it.error_code = code;
    return error.TclError;
}

/// The elements of a list. The error text names the bad character.
fn listOrError(it: *Interp, v: Value) Error![]const Value {
    return it.list(v);
}

fn cmdPrefix(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("tcl::prefix subcommand ?arg ...?");
    const sub = try it.str(argv[1]);
    const args = argv[2..];
    if (sub.len > 0 and std.mem.startsWith(u8, "match", sub)) return prefixMatch(it, args);
    const is_all = sub.len > 0 and std.mem.startsWith(u8, "all", sub);
    const is_longest = sub.len > 0 and std.mem.startsWith(u8, "longest", sub);
    if (!is_all and !is_longest) return it.fail("unknown or ambiguous subcommand \"{s}\": must be all, longest, or match", .{sub});
    if (args.len != 2) {
        if (is_all) return it.wrongArgs("tcl::prefix all table string");
        return it.wrongArgs("tcl::prefix longest table string");
    }
    const table = try listOrError(it, args[0]);
    const word = try it.str(args[1]);
    var out: std.ArrayList(Value) = .empty;
    for (table) |v| if (std.mem.startsWith(u8, try it.str(v), word)) try out.append(it.alloc(), v);
    if (is_all) return value.wrapList(it.alloc(), out.items);
    if (out.items.len == 0) return Value.empty;
    var common = try it.str(out.items[0]);
    for (out.items[1..]) |v| {
        const t = try it.str(v);
        var n: usize = 0;
        while (n < common.len and n < t.len and common[n] == t[n]) n += 1;
        // The common part ends at a character boundary.
        while (n > 0 and n < common.len and common[n] & 0xC0 == 0x80) n -= 1;
        common = common[0..n];
    }
    return .{ .str = common };
}

// ---- array ----

pub const Search = struct {
    map: *interp.ArrayMap,
    num: u32,
    id: []const u8,
    pos: usize = 0,
    count: usize,
};

fn notArray(it: *Interp, name: []const u8) Error {
    return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP ARRAY {s}", .{name}), "\"{s}\" isn't an array", .{name});
}

fn findSearch(it: *Interp, m: *interp.ArrayMap, name: []const u8, id: []const u8) Error!usize {
    // The form of an id is s-<number>-<array name>.
    const good = blk: {
        if (!std.mem.startsWith(u8, id, "s-")) break :blk false;
        const dash = std.mem.indexOfScalarPos(u8, id, 2, '-') orelse break :blk false;
        _ = std.fmt.parseInt(u32, id[2..dash], 10) catch break :blk false;
        break :blk eql(id[dash + 1..], name);
    };
    if (!good) return it.failCode("TCL LOOKUP ARRAYSEARCH", "illegal search identifier \"{s}\"", .{id});
    for (it.searches.items, 0..) |s, i| {
        if (s.map == m and eql(s.id, id) and s.count == m.count()) return i;
    }
    return it.failCode("TCL LOOKUP ARRAYSEARCH", "couldn't find search \"{s}\"", .{id});
}

fn cmdArray(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("array subcommand ?arg ...?");
    const a = it.alloc();
    const Sub = enum { anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, unset };
    const word = try it.str(argv[1]);
    var which: ?Sub = std.meta.stringToEnum(Sub, word);
    if (which == null and word.len > 0) {
        var hits: usize = 0;
        inline for (@typeInfo(Sub).@"enum".fields) |f| {
            if (std.mem.startsWith(u8, f.name, word)) {
                which = @enumFromInt(f.value);
                hits += 1;
            }
        }
        if (hits != 1) which = null;
    }
    const sub = which orelse return it.failCode("TCL LOOKUP INDEX subcommand", "unknown or ambiguous subcommand \"{s}\": must be anymore, donesearch, exists, get, names, nextelement, set, size, startsearch, statistics, or unset", .{word});
    if (argv.len < 3) {
        return switch (sub) {
            .anymore => it.wrongArgs("array anymore arrayName searchId"),
            .donesearch => it.wrongArgs("array donesearch arrayName searchId"),
            .exists => it.wrongArgs("array exists arrayName"),
            .get => it.wrongArgs("array get arrayName ?pattern?"),
            .names => it.wrongArgs("array names arrayName ?mode? ?pattern?"),
            .nextelement => it.wrongArgs("array nextelement arrayName searchId"),
            .set => it.wrongArgs("array set arrayName list"),
            .size => it.wrongArgs("array size arrayName"),
            .startsearch => it.wrongArgs("array startsearch arrayName"),
            .statistics => it.wrongArgs("array statistics arrayName"),
            .unset => it.wrongArgs("array unset arrayName ?pattern?"),
        };
    }
    const name = try it.str(argv[2]);
    const cell = try it.findVar(it.frame, name, false);
    if (cell != null and cell.?.v == .traced) try trace.arrayOp(it, cell.?, name);
    var map: ?*interp.ArrayMap = if (cell != null and cell.?.v == .arr) cell.?.v.arr else null;
    if (cell != null and cell.?.v == .traced and cell.?.v.traced.inner == .arr) map = cell.?.v.traced.inner.arr;
    switch (sub) {
        .exists => {
            if (argv.len != 3) return it.wrongArgs("array exists arrayName");
            return .{ .int = @intFromBool(map != null) };
        },
        .size => {
            if (argv.len != 3) return it.wrongArgs("array size arrayName");
            return .{ .int = if (map) |m| @intCast(m.count()) else 0 };
        },
        .set => {
            if (argv.len != 4) return it.wrongArgs("array set arrayName list");
            const items = try it.list(argv[3]);
            if (items.len % 2 != 0) return it.failCode("TCL WRONGARGS", "list must have an even number of elements", .{});
            if (map == null) {
                const c = (try it.findVar(it.frame, name, true)).?;
                if (c.v == .traced) {
                    if (c.v.traced.inner == .val) return it.fail("can't array set \"{s}\": variable isn't array", .{name});
                } else if (c.v != .undef) return it.fail("can't array set \"{s}\": variable isn't array", .{name});
                const m = try a.create(interp.ArrayMap);
                m.* = .empty;
                if (c.v == .traced) {
                    c.v.traced.inner = .{ .arr = m };
                } else c.v = .{ .arr = m };
            }
            var i: usize = 0;
            while (i < items.len) : (i += 2) {
                try it.setVar(try std.fmt.allocPrint(a, "{s}({s})", .{ name, try it.str(items[i]) }), items[i + 1]);
            }
            return Value.empty;
        },
        .get => {
            if (argv.len > 4) return it.wrongArgs("array get arrayName ?pattern?");
            const pattern: ?[]const u8 = if (argv.len == 4) try it.str(argv[3]) else null;
            var out: std.ArrayList(Value) = .empty;
            if (map) |m| for (m.keys(), m.values()) |k, v| {
                if (pattern) |p| if (!cmds.globMatch(p, k, false)) continue;
                try out.append(a, .{ .str = k });
                try out.append(a, v);
            };
            return value.wrapList(a, out.items);
        },
        .names => {
            if (argv.len > 5) return it.wrongArgs("array names arrayName ?mode? ?pattern?");
            var mode: []const u8 = "-glob";
            var pattern: ?Value = null;
            if (argv.len == 5) {
                mode = try it.str(argv[3]);
                pattern = argv[4];
                if (!eql(mode, "-exact") and !eql(mode, "-glob") and !eql(mode, "-regexp")) {
                    return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -exact, -glob, or -regexp", .{mode});
                }
            } else if (argv.len == 4) pattern = argv[3];
            var out: std.ArrayList(Value) = .empty;
            if (map) |m| for (m.keys()) |k| {
                if (pattern) |pv| {
                    const p = try it.str(pv);
                    const hit = if (eql(mode, "-exact")) eql(p, k) else if (eql(mode, "-regexp")) try regex.matches(it, p, k, false) else cmds.globMatch(p, k, false);
                    if (!hit) continue;
                }
                try out.append(a, .{ .str = k });
            };
            return value.wrapList(a, out.items);
        },
        .unset => {
            if (argv.len > 4) return it.wrongArgs("array unset arrayName ?pattern?");
            if (map) |m| {
                if (argv.len == 4) {
                    const p = try it.str(argv[3]);
                    var i: usize = m.count();
                    while (i > 0) : (i -= 1) {
                        if (cmds.globMatch(p, m.keys()[i - 1], false)) m.orderedRemoveAt(i - 1);
                    }
                } else if (cell.?.v == .traced) {
                    _ = try it.unsetVar(name);
                } else cell.?.v = .undef;
            }
            return Value.empty;
        },
        .startsearch => {
            if (argv.len != 3) return it.wrongArgs("array startsearch arrayName");
            const m = map orelse return notArray(it, name);
            var top: u32 = 0;
            for (it.searches.items) |s| {
                if (s.map == m and s.count == m.count()) top = @max(top, s.num);
            }
            const id = try std.fmt.allocPrint(a, "s-{d}-{s}", .{ top + 1, name });
            try it.searches.append(a, .{ .map = m, .num = top + 1, .id = id, .count = m.count() });
            return .{ .str = id };
        },
        .anymore, .nextelement, .donesearch => {
            if (argv.len != 4) {
                return switch (sub) {
                    .anymore => it.wrongArgs("array anymore arrayName searchId"),
                    .nextelement => it.wrongArgs("array nextelement arrayName searchId"),
                    else => it.wrongArgs("array donesearch arrayName searchId"),
                };
            }
            const m = map orelse return notArray(it, name);
            const i = try findSearch(it, m, name, try it.str(argv[3]));
            const s = &it.searches.items[i];
            switch (sub) {
                .anymore => return .{ .int = @intFromBool(s.pos < m.count()) },
                .nextelement => {
                    if (s.pos >= m.count()) return Value.empty;
                    s.pos += 1;
                    return .{ .str = m.keys()[s.pos - 1] };
                },
                else => {
                    _ = it.searches.orderedRemove(i);
                    return Value.empty;
                },
            }
        },
        .statistics => {
            const m = map orelse return notArray(it, name);
            return .{ .str = try std.fmt.allocPrint(a, "{d} entries in table", .{m.count()}) };
        },
    }
}

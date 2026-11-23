//! Namespaces: the `namespace` command.
//!
//! A namespace is a prefix of names. The command `a::b::f` has the key
//! "a::b::f" in the command table, and the variable `a::b::x` is a
//! global cell with the name "a::b::x". The interpreter has a current
//! namespace. A proc runs in the namespace of its name, and
//! `namespace eval` runs a script in a frame of the namespace.
//!
//! An imported command is a second key for the same `Command`, so its
//! `name` field gives the origin. A name with no command goes to the
//! unknown handler of the namespace (`dispatchUnknown`).
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const interp = @import("interp.zig");
const value = @import("value.zig");
const cmds = @import("cmds.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The part of a name before the last "::".
pub fn qualifiers(name: []const u8) []const u8 {
    const i = std.mem.lastIndexOf(u8, name, "::") orelse return "";
    var end = i;
    while (end > 0 and name[end - 1] == ':') end -= 1;
    return name[0..end];
}

/// The part of a name after the last "::".
pub fn tail(name: []const u8) []const u8 {
    const i = std.mem.lastIndexOf(u8, name, "::") orelse return name;
    return name[i + 2 ..];
}

/// The full name of a namespace word, with no leading "::".
fn resolve(it: *Interp, word: []const u8) Error![]const u8 {
    const full = try it.qualify(std.mem.trimEnd(u8, word, ":"));
    if (std.mem.startsWith(u8, word, "::")) return std.mem.trimStart(u8, std.mem.trimEnd(u8, word, ":"), ":");
    return std.mem.trimEnd(u8, full, ":");
}

fn display(it: *Interp, name: []const u8) Error!Value {
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "::{s}", .{name}) };
}

/// True when the namespace exports the command name.
fn exported(it: *Interp, space: []const u8, name: []const u8) bool {
    const pats = it.exports.get(space) orelse return false;
    for (pats.items) |p| if (cmds.globMatch(p, name, false)) return true;
    return false;
}

const Ensemble = struct {
    ns: []const u8,
    /// Pairs: a subcommand and the words that it stands for.
    map: []const Value = &.{},
    subs: ?[]const Value = null,
    params: []const Value = &.{},
    prefixes: bool = true,
    unknown: ?Value = null,
};

fn ensembleOf(it: *Interp, name: []const u8) ?*Ensemble {
    const c = it.findCommand(name) orelse return null;
    if (c.impl != .native or c.impl.native != &ensembleCall) return null;
    return @ptrCast(@alignCast(c.ctx.?));
}

/// Applies one option of `create` or `configure`.
fn ensembleOption(it: *Interp, e: *Ensemble, o: []const u8, v: Value) Error!void {
    if (eql(o, "-map")) {
        const l = try it.list(v);
        if (l.len % 2 != 0) return it.fail("missing value to go with key", .{});
        var k: usize = 1;
        while (k < l.len) : (k += 2) {
            if ((try it.list(l[k])).len == 0) return it.fail("ensemble subcommand implementations must be non-empty lists", .{});
        }
        e.map = l;
    } else if (eql(o, "-subcommands")) {
        const l = try it.list(v);
        e.subs = if (l.len == 0) null else l;
    } else if (eql(o, "-parameters")) {
        e.params = try it.list(v);
    } else if (eql(o, "-prefixes")) {
        e.prefixes = try @import("expr.zig").truthy(it, v);
    } else if (eql(o, "-unknown")) {
        e.unknown = if ((try it.list(v)).len == 0) null else v;
    } else if (eql(o, "-namespace")) {
        const space = try resolve(it, try it.str(v));
        if (space.len > 0 and !it.namespaces.contains(space)) return it.fail("namespace \"{s}\" not found", .{try it.str(v)});
        e.ns = try it.internNs(space);
    } else return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -map, -namespace, -parameters, -prefixes, -subcommands, or -unknown", .{o});
}

fn ensembleOptionName(word: []const u8) []const u8 {
    for ([_][]const u8{ "-map", "-namespace", "-parameters", "-prefixes", "-subcommands", "-unknown", "-command" }) |n| {
        if (word.len > 1 and std.mem.startsWith(u8, n, word)) return n;
    }
    return word;
}

fn ensembleRead(it: *Interp, e: *Ensemble, o: []const u8) Error!Value {
    const a = it.alloc();
    if (eql(o, "-map")) return value.newList(a, e.map);
    if (eql(o, "-namespace")) return display(it, e.ns);
    if (eql(o, "-parameters")) return value.newList(a, e.params);
    if (eql(o, "-prefixes")) return .{ .int = @intFromBool(e.prefixes) };
    if (eql(o, "-subcommands")) return value.newList(a, e.subs orelse &.{});
    if (eql(o, "-unknown")) return e.unknown orelse Value.empty;
    return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -map, -namespace, -parameters, -prefixes, -subcommands, or -unknown", .{o});
}

/// `namespace ensemble create`, `configure`, and `exists`.
fn ensemble(it: *Interp, args: []const Value) Error!Value {
    const a = it.alloc();
    if (args.len < 1) return it.wrongArgs("namespace ensemble subcommand ?arg ...?");
    const word = try it.str(args[0]);
    var sub: []const u8 = word;
    for ([_][]const u8{ "configure", "create", "exists" }) |n| {
        if (word.len >= 2 and std.mem.startsWith(u8, n, word)) sub = n;
    }
    if (eql(sub, "exists")) {
        if (args.len != 2) return it.wrongArgs("namespace ensemble exists cmdname");
        return .{ .int = @intFromBool(ensembleOf(it, try it.str(args[1])) != null) };
    }
    if (eql(sub, "configure")) {
        if (args.len < 2) return it.wrongArgs("namespace ensemble configure cmdname ?-option value ...?");
        const name = try it.str(args[1]);
        const e = ensembleOf(it, name) orelse return it.failCode(try std.fmt.allocPrint(a, "TCL LOOKUP ENSEMBLE {s}", .{name}), "\"{s}\" is not an ensemble command", .{name});
        if (args.len == 2) {
            var out: std.ArrayList(Value) = .empty;
            for ([_][]const u8{ "-map", "-namespace", "-parameters", "-prefixes", "-subcommands", "-unknown" }) |o| {
                try out.append(a, .{ .str = o });
                try out.append(a, try ensembleRead(it, e, o));
            }
            return value.wrapList(a, out.items);
        }
        if (args.len == 3) return ensembleRead(it, e, ensembleOptionName(try it.str(args[2])));
        if (args.len % 2 != 0) return it.wrongArgs("namespace ensemble configure cmdname ?-option value ...?");
        var i: usize = 2;
        while (i + 1 < args.len) : (i += 2) try ensembleOption(it, e, ensembleOptionName(try it.str(args[i])), args[i + 1]);
        it.epoch += 1;
        return Value.empty;
    }
    if (!eql(sub, "create")) return it.failCode("TCL LOOKUP INDEX subcommand", "bad subcommand \"{s}\": must be configure, create, or exists", .{word});
    if (args.len % 2 != 1) return it.wrongArgs("namespace ensemble create ?option value ...?");
    const e = try a.create(Ensemble);
    e.* = .{ .ns = it.ns };
    var name: []const u8 = it.ns;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const o = ensembleOptionName(try it.str(args[i]));
        if (eql(o, "-command")) {
            name = try it.qualify(try it.str(args[i + 1]));
            name = std.mem.trimStart(u8, name, ":");
        } else try ensembleOption(it, e, o, args[i + 1]);
    }
    if (name.len == 0) return it.fail("an ensemble of the global namespace needs -command", .{});
    const c = try a.create(interp.Command);
    c.* = .{ .name = name, .impl = .{ .native = ensembleCall }, .ctx = e };
    try it.commands.put(a, name, c);
    it.epoch += 1;
    return display(it, name);
}

/// True when a native function is the call of an ensemble.
pub fn isEnsemble(f: interp.NativeFn) bool {
    return f == ensembleCall;
}

/// A copy of the data of an ensemble in the arena of the copier.
pub fn copyEnsemble(c: *@import("compact.zig").Copier, ctx: *anyopaque) Allocator.Error!*anyopaque {
    const old: *Ensemble = @ptrCast(@alignCast(ctx));
    const e = try c.a.create(Ensemble);
    e.* = old.*;
    try c.text(&e.ns);
    e.map = try c.vals(old.map);
    e.params = try c.vals(old.params);
    if (old.subs) |l| e.subs = try c.vals(l);
    if (old.unknown) |u| {
        var copy = u;
        try c.val(&copy);
        e.unknown = copy;
    }
    return e;
}

/// The subcommand names of an ensemble, sorted.
fn ensembleNames(it: *Interp, e: *Ensemble) Error![]const []const u8 {
    const a = it.alloc();
    var names: std.ArrayList([]const u8) = .empty;
    if (e.subs) |l| {
        for (l) |v| try names.append(a, try it.str(v));
    } else if (e.map.len > 0) {
        var k: usize = 0;
        while (k < e.map.len) : (k += 2) try names.append(a, try it.str(e.map[k]));
    } else {
        const prefix = if (e.ns.len == 0) "" else try std.fmt.allocPrint(a, "{s}::", .{e.ns});
        var iter = it.commands.keyIterator();
        while (iter.next()) |k| {
            if (!std.mem.startsWith(u8, k.*, prefix)) continue;
            const rest = k.*[prefix.len..];
            if (std.mem.indexOf(u8, rest, "::") == null and exported(it, e.ns, rest)) try names.append(a, rest);
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return names.items;
}

fn ensembleCall(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    // A map can name the ensemble itself, so each call is one level.
    try it.checkNative();
    if (it.nest >= it.max_nest) return it.fail("too many nested evaluations (infinite loop?)", .{});
    it.nest += 1;
    defer it.nest -= 1;
    const a = it.alloc();
    const self = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name \"{s}\"", .{try it.str(argv[0])});
    const e: *Ensemble = @ptrCast(@alignCast(self.ctx orelse return it.fail("\"{s}\" is not an ensemble", .{try it.str(argv[0])})));
    const np = e.params.len;
    if (argv.len < 2 + np) {
        var usage: std.ArrayList(u8) = .empty;
        try usage.print(a, "wrong # args: should be \"{s}", .{try it.str(argv[0])});
        for (e.params) |p| try usage.print(a, " {s}", .{try it.str(p)});
        try usage.appendSlice(a, " subcommand ?arg ...?\"");
        it.result = .{ .str = usage.items };
        it.error_code = .{ .str = "TCL WRONGARGS" };
        return error.TclError;
    }
    const params = argv[1 .. 1 + np];
    const sub = try it.str(argv[1 + np]);
    const rest = argv[2 + np..];
    var tried_unknown = false;
    while (true) {
        const names = try ensembleNames(it, e);
        // An exact name, or the one name that starts with the word.
        var chosen: ?[]const u8 = null;
        var count: usize = 0;
        for (names) |n| {
            if (eql(n, sub)) {
                chosen = n;
                count = 1;
                break;
            }
            if (e.prefixes and sub.len > 0 and std.mem.startsWith(u8, n, sub)) {
                chosen = n;
                count += 1;
            }
        }
        if (count != 1) {
            if (e.unknown != null and !tried_unknown) {
                tried_unknown = true;
                var words: std.ArrayList(Value) = .empty;
                try words.appendSlice(a, try it.list(e.unknown.?));
                try words.append(a, argv[0]);
                try words.appendSlice(a, params);
                try words.append(a, argv[1 + np]);
                try words.appendSlice(a, rest);
                const got = it.callWords(words.items) catch |err| switch (err) {
                    error.TclError, error.OutOfMemory => return err,
                    else => return it.failCode("TCL ENSEMBLE UNKNOWN_RESULT", "unknown subcommand handler returned bad code: {s}", .{codeWord(err)}),
                };
                const prefix = it.list(got) catch return error.TclError;
                if (prefix.len == 0) continue;
                var run: std.ArrayList(Value) = .empty;
                try run.appendSlice(a, prefix);
                try run.appendSlice(a, params);
                try run.appendSlice(a, rest);
                return it.callWords(run.items);
            }
            var msg: std.ArrayList(u8) = .empty;
            if (names.len == 0) {
                try msg.print(a, "unknown subcommand \"{s}\": namespace ::{s} does not export any commands", .{ sub, e.ns });
            } else {
                try msg.print(a, "unknown {s}subcommand \"{s}\": must be ", .{ if (e.prefixes) "or ambiguous " else "", sub });
                for (names, 0..) |n, k| {
                    if (k > 0) try msg.appendSlice(a, ", ");
                    if (k > 0 and k == names.len - 1) try msg.appendSlice(a, "or ");
                    try msg.appendSlice(a, n);
                }
            }
            it.result = .{ .str = msg.items };
            it.error_code = try value.newList(a, &.{ .{ .str = "TCL" }, .{ .str = "LOOKUP" }, .{ .str = "SUBCOMMAND" }, .{ .str = sub } });
            return error.TclError;
        }
        var words: std.ArrayList(Value) = .empty;
        var mapped = false;
        var k: usize = 0;
        while (k < e.map.len) : (k += 2) {
            if (eql(try it.str(e.map[k]), chosen.?)) {
                try words.appendSlice(a, try it.list(e.map[k + 1]));
                mapped = true;
                break;
            }
        }
        if (!mapped) try words.append(a, .{ .str = try std.fmt.allocPrint(a, "::{s}::{s}", .{ e.ns, chosen.? }) });
        try words.appendSlice(a, params);
        try words.appendSlice(a, rest);
        // A relative word of the map is a command of the namespace.
        const saved_ns = it.ns;
        it.ns = try it.internNs(e.ns);
        defer it.ns = saved_ns;
        return it.callWords(words.items);
    }
}

fn codeWord(e: Error) []const u8 {
    return switch (e) {
        error.TclBreak => "break",
        error.TclContinue => "continue",
        error.TclReturn => "return",
        else => "error",
    };
}

// ---- unknown ----

/// The default `::unknown` command.
pub fn cmdUnknown(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("unknown commandName ?arg ...?");
    return lookupError(it, try it.str(argv[1]));
}

fn lookupError(it: *Interp, name: []const u8) Error {
    const a = it.alloc();
    it.result = .{ .str = try std.fmt.allocPrint(a, "invalid command name \"{s}\"", .{name}) };
    it.error_code = try value.newList(a, &.{ .{ .str = "TCL" }, .{ .str = "LOOKUP" }, .{ .str = "COMMAND" }, .{ .str = name } });
    return error.TclError;
}

/// The function of a name with no command. It calls the unknown handler
/// of the current namespace.
pub fn dispatchUnknown(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const a = it.alloc();
    const name = try it.str(argv[0]);
    var handler: []const Value = &.{.{ .str = "::unknown" }};
    if (it.ns_unknown.get(it.ns)) |h| handler = try it.list(h);
    if (handler.len == 0) return lookupError(it, name);
    const first = try it.str(handler[0]);
    const target = it.findCommand(first) orelse return lookupError(it, name);
    if (target.impl == .native and target.impl.native == &cmdUnknown) return lookupError(it, name);
    try it.checkNative();
    if (it.unknown_depth >= 64) return lookupError(it, name);
    it.unknown_depth += 1;
    defer it.unknown_depth -= 1;
    const words = try a.alloc(Value, handler.len + argv.len);
    @memcpy(words[0..handler.len], handler);
    @memcpy(words[handler.len..], argv);
    return it.call(target, words, null);
}

/// Runs a script in a namespace.
fn evalIn(it: *Interp, space: []const u8, script: *interp.Script, argv: []const Value) Error!Value {
    const saved_ns = it.ns;
    it.ns = try it.internNs(space);
    defer it.ns = saved_ns;
    if (space.len == 0) {
        const saved = it.frame;
        it.frame = &it.global;
        defer it.frame = saved;
        return it.evalBody(script, argv, &.{ @intFromPtr(saved), @intFromPtr(saved_ns.ptr) });
    }
    const f = try it.pushFrame(argv);
    defer it.popFrame();
    f.ns = it.ns;
    f.space = it.ns;
    return it.evalBody(script, argv, &.{ @intFromPtr(saved_ns.ptr), @intFromPtr(space.ptr) }) catch |e| {
        if (e == error.TclError and it.in_error) {
            it.error_info.print(it.alloc(), "\n    (in namespace eval \"::{s}\" script line {d})", .{ space, it.proc_line }) catch {};
        }
        return e;
    };
}

/// `namespace path ?list?`: reads or sets the search path of the
/// current namespace. Each name of a new path must exist.
fn nsPath(it: *Interp, args: []const Value) Error!Value {
    const a = it.alloc();
    if (args.len > 1) return it.wrongArgs("namespace path ?pathList?");
    if (args.len == 0) {
        var out: std.ArrayList(Value) = .empty;
        if (it.ns_paths.get(it.ns)) |path| for (path) |space| try out.append(a, try display(it, space));
        return value.wrapList(a, out.items);
    }
    const words = try it.list(args[0]);
    const path = try a.alloc([]const u8, words.len);
    for (words, path) |w, *out| {
        const text = try it.str(w);
        const space = try resolve(it, text);
        if (space.len > 0 and !it.namespaces.contains(space)) {
            return it.failCode(try std.fmt.allocPrint(a, "TCL LOOKUP NAMESPACE {s}", .{text}), "namespace \"{s}\" not found in \"::{s}\"", .{ text, it.ns });
        }
        out.* = try it.internNs(space);
    }
    try it.ns_paths.put(a, it.ns, path);
    it.epoch += 1;
    return Value.empty;
}

pub fn cmdNamespace(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("namespace subcommand ?arg ...?");
    const a = it.alloc();
    const word = try it.str(argv[1]);
    const args = argv[2..];
    var sub: []const u8 = word;
    var hits: usize = 0;
    for ([_][]const u8{ "children", "code", "current", "delete", "ensemble", "eval", "exists", "export", "forget", "import", "inscope", "origin", "parent", "path", "qualifiers", "tail", "unknown", "upvar", "which" }) |n| {
        if (eql(n, word)) {
            sub = n;
            hits = 1;
            break;
        }
        if (word.len > 0 and std.mem.startsWith(u8, n, word)) {
            sub = n;
            hits += 1;
        }
    }
    if (hits != 1) sub = word;
    if (eql(sub, "eval")) {
        if (args.len < 2) return it.wrongArgs("namespace eval name arg ?arg...?");
        const space = try resolve(it, try it.str(args[0]));
        if (args.len == 2) return evalIn(it, space, try it.scriptOf(argv, 3, cmd), argv);
        var text: std.ArrayList(u8) = .empty;
        for (args[1..], 0..) |v, i| {
            if (i > 0) try text.append(a, ' ');
            try text.appendSlice(a, try it.str(v));
        }
        return evalIn(it, space, try it.scriptOfValue(.{ .str = text.items }, null), argv);
    }
    if (eql(sub, "inscope")) {
        if (args.len < 2) return it.wrongArgs("namespace inscope name arg ?arg...?");
        const space = try resolve(it, try it.str(args[0]));
        if (it.namespaces.getKey(space) == null and space.len > 0) return it.fail("namespace \"{s}\" not found in \"::{s}\"", .{ try it.str(args[0]), it.ns });
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(a, try it.str(args[1]));
        for (args[2..]) |v| {
            try text.append(a, ' ');
            try value.appendElement(a, &text, try it.str(v), true);
        }
        return evalIn(it, space, try it.scriptOfValue(.{ .str = text.items }, null), argv);
    }
    if (eql(sub, "code")) {
        if (args.len != 1) return it.wrongArgs("namespace code arg");
        const text = try it.str(args[0]);
        if (std.mem.startsWith(u8, text, "::namespace inscope ")) return args[0];
        return value.newList(a, &.{ .{ .str = "::namespace" }, .{ .str = "inscope" }, try display(it, it.ns), args[0] });
    }
    if (eql(sub, "current")) {
        if (args.len != 0) return it.wrongArgs("namespace current");
        return display(it, it.ns);
    }
    if (eql(sub, "qualifiers") or eql(sub, "tail")) {
        if (args.len != 1) {
            if (eql(sub, "tail")) return it.wrongArgs("namespace tail string");
            return it.wrongArgs("namespace qualifiers string");
        }
        const s = try it.str(args[0]);
        return .{ .str = if (eql(sub, "tail")) tail(s) else qualifiers(s) };
    }
    if (eql(sub, "exists")) {
        if (args.len != 1) return it.wrongArgs("namespace exists name");
        const space = try resolve(it, try it.str(args[0]));
        return .{ .int = @intFromBool(space.len == 0 or it.namespaces.contains(space)) };
    }
    if (eql(sub, "parent")) {
        if (args.len > 1) return it.wrongArgs("namespace parent ?name?");
        const space = if (args.len == 1) try resolve(it, try it.str(args[0])) else it.ns;
        if (space.len == 0) return Value.empty;
        if (!it.namespaces.contains(space)) return it.fail("namespace \"{s}\" not found in \"::{s}\"", .{ try it.str(args[0]), it.ns });
        return display(it, qualifiers(space));
    }
    if (eql(sub, "children")) {
        if (args.len > 2) return it.wrongArgs("namespace children ?name? ?pattern?");
        const space = if (args.len >= 1) try resolve(it, try it.str(args[0])) else it.ns;
        var out: std.ArrayList(Value) = .empty;
        for (it.namespaces.keys()) |k| {
            if (!eql(qualifiers(k), space)) continue;
            if (space.len == 0 and std.mem.indexOf(u8, k, "::") != null) continue;
            const shown = try display(it, k);
            if (args.len == 2) {
                var pat = try it.str(args[1]);
                if (!std.mem.startsWith(u8, pat, "::")) pat = try std.fmt.allocPrint(a, "::{s}{s}{s}", .{ space, if (space.len > 0) "::" else "", pat });
                if (!cmds.globMatch(pat, shown.str, false)) continue;
            }
            try out.append(a, shown);
        }
        return value.wrapList(a, out.items);
    }
    if (eql(sub, "delete")) {
        for (args) |v| {
            const space = try resolve(it, try it.str(v));
            if (space.len == 0 or !it.namespaces.contains(space)) return it.fail("unknown namespace \"{s}\" in namespace delete command", .{try it.str(v)});
            const prefix = try std.fmt.allocPrint(a, "{s}::", .{space});
            // The objects of the namespace end first.
            try @import("oo.zig").namespaceGone(it, space, prefix);
            // The namespace, its children, its commands, and its variables.
            var i: usize = 0;
            while (i < it.namespaces.count()) {
                const k = it.namespaces.keys()[i];
                if (eql(k, space) or std.mem.startsWith(u8, k, prefix)) it.namespaces.orderedRemoveAt(i) else i += 1;
            }
            var gone: std.ArrayList([]const u8) = .empty;
            var iter = it.commands.keyIterator();
            while (iter.next()) |k| if (std.mem.startsWith(u8, k.*, prefix)) try gone.append(a, k.*);
            for (gone.items) |k| _ = it.commands.remove(k);
            for (it.global.vars.items) |e| if (std.mem.startsWith(u8, e.name, prefix)) {
                e.cell.v = .undef;
            };
            it.epoch += 1;
        }
        return Value.empty;
    }
    if (eql(sub, "which")) {
        var kind_var = false;
        var i: usize = 0;
        if (args.len == 2) {
            const o = try it.str(args[0]);
            if (o.len > 1 and std.mem.startsWith(u8, "-variable", o)) kind_var = true else if (!(o.len > 1 and std.mem.startsWith(u8, "-command", o))) return it.wrongArgs("namespace which ?-command? ?-variable? name");
            i = 1;
        } else if (args.len != 1) return it.wrongArgs("namespace which ?-command? ?-variable? name");
        const name = try it.str(args[i]);
        if (kind_var) {
            const full = try it.qualify(name);
            for (it.global.vars.items) |e| if (eql(e.name, full)) return display(it, full);
            if (it.ns.len > 0 and !std.mem.startsWith(u8, name, "::")) {
                for (it.global.vars.items) |e| if (eql(e.name, name)) return display(it, name);
            }
            return Value.empty;
        }
        const key = it.commandKey(name) orelse return Value.empty;
        return display(it, key);
    }
    if (eql(sub, "origin")) {
        if (args.len != 1) return it.wrongArgs("namespace origin name");
        const key = it.commandKey(try it.str(args[0])) orelse return it.fail("invalid command name \"{s}\"", .{try it.str(args[0])});
        return display(it, it.commands.get(key).?.name);
    }
    if (eql(sub, "import")) {
        if (args.len == 0) {
            var out: std.ArrayList(Value) = .empty;
            var iter = it.commands.iterator();
            while (iter.next()) |e| {
                if (!eql(qualifiers(e.key_ptr.*), it.ns) or eql(e.key_ptr.*, e.value_ptr.*.name)) continue;
                try out.append(a, .{ .str = tail(e.key_ptr.*) });
            }
            return value.wrapList(a, out.items);
        }
        var force = false;
        for (args, 0..) |v, n| {
            const text = try it.str(v);
            if (n == 0 and eql(text, "-force")) {
                force = true;
                continue;
            }
            if (text.len == 0) return it.fail("empty import pattern", .{});
            const tail_pat = tail(text);
            if (tail_pat.len == 0) return it.fail("empty import pattern", .{});
            const from = try resolve(it, qualifiers(text));
            if (std.mem.indexOf(u8, text, "::") == null or (from.len > 0 and !it.namespaces.contains(from))) {
                return it.failCode("TCL LOOKUP NAMESPACE", "unknown namespace in import pattern \"{s}\"", .{text});
            }
            if (eql(from, it.ns)) return it.fail("import pattern \"{s}\" tries to import from namespace \"{s}\" into itself", .{ text, tail(from) });
            const prefix = if (from.len == 0) "" else try std.fmt.allocPrint(a, "{s}::", .{from});
            var found: std.ArrayList([]const u8) = .empty;
            var iter = it.commands.keyIterator();
            while (iter.next()) |k| {
                if (!std.mem.startsWith(u8, k.*, prefix)) continue;
                const rest = k.*[prefix.len..];
                if (std.mem.indexOf(u8, rest, "::") != null) continue;
                if (!exported(it, from, rest)) continue;
                if (cmds.globMatch(tail_pat, rest, false)) try found.append(a, k.*);
            }
            for (found.items) |k| {
                const target = it.commands.get(k).?;
                const name = try it.qualify(k[prefix.len..]);
                if (eql(name, k)) continue;
                if (it.commands.get(name)) |old| {
                    if (old == target) continue;
                    if (eql(old.name, target.name)) continue;
                    if (eql(old.name, name) and eql(qualifiers(target.name), it.ns)) {
                        return it.fail("import pattern \"{s}\" would create a loop containing command \"::{s}\"", .{ text, name });
                    }
                    if (!force) return it.fail("can't import command \"{s}\": already exists", .{k[prefix.len..]});
                }
                if (eql(qualifiers(target.name), it.ns)) {
                    return it.fail("import pattern \"{s}\" would create a loop containing command \"::{s}\"", .{ text, name });
                }
                try it.commands.put(a, name, target);
            }
            it.epoch += 1;
        }
        return Value.empty;
    }
    if (eql(sub, "forget")) {
        for (args) |v| {
            const text = try it.str(v);
            const has_ns = std.mem.indexOf(u8, text, "::") != null;
            const from = if (has_ns) try resolve(it, qualifiers(text)) else "";
            if (has_ns and from.len > 0 and !it.namespaces.contains(from)) {
                return it.failCode("TCL LOOKUP NAMESPACE", "unknown namespace in namespace forget pattern \"{s}\"", .{text});
            }
            const pat = tail(text);
            var gone: std.ArrayList([]const u8) = .empty;
            var iter = it.commands.iterator();
            while (iter.next()) |e| {
                const key = e.key_ptr.*;
                if (!eql(qualifiers(key), it.ns) or eql(key, e.value_ptr.*.name)) continue;
                if (has_ns and !eql(qualifiers(e.value_ptr.*.name), from)) continue;
                if (cmds.globMatch(pat, tail(key), false)) try gone.append(a, key);
            }
            for (gone.items) |k| _ = it.commands.remove(k);
            it.epoch += 1;
        }
        return Value.empty;
    }
    if (eql(sub, "unknown")) {
        if (args.len > 1) return it.wrongArgs("namespace unknown ?script?");
        if (args.len == 0) {
            if (it.ns_unknown.get(it.ns)) |h| return h;
            if (it.ns.len == 0) return .{ .str = "::unknown" };
            return Value.empty;
        }
        if ((try it.list(args[0])).len == 0) {
            _ = it.ns_unknown.remove(it.ns);
        } else try it.ns_unknown.put(a, it.ns, args[0]);
        return args[0];
    }
    if (eql(sub, "upvar")) {
        if (args.len < 1 or args.len % 2 != 1) return it.wrongArgs("namespace upvar ns ?otherVar myVar ...?");
        const space = try resolve(it, try it.str(args[0]));
        var i: usize = 1;
        while (i + 1 < args.len) : (i += 2) {
            const other = try it.str(args[i]);
            const full = if (space.len > 0) try std.fmt.allocPrint(a, "{s}::{s}", .{ space, other }) else other;
            const target = try it.globalVar(full);
            try it.linkVar(try it.str(args[i + 1]), target);
        }
        return Value.empty;
    }
    if (eql(sub, "export")) {
        const gop = try it.exports.getOrPut(a, it.ns);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        if (args.len == 0) {
            var out: std.ArrayList(Value) = .empty;
            for (gop.value_ptr.items) |p| try out.append(a, .{ .str = p });
            return value.wrapList(a, out.items);
        }
        for (args, 0..) |v, n| {
            const pat = try it.str(v);
            if (n == 0 and eql(pat, "-clear")) {
                gop.value_ptr.* = .empty;
                continue;
            }
            if (std.mem.indexOf(u8, pat, "::") != null) {
                return it.fail("invalid export pattern \"{s}\": pattern can't specify a namespace", .{pat});
            }
            var seen = false;
            for (gop.value_ptr.items) |old| {
                if (eql(old, pat)) seen = true;
            }
            if (!seen) try gop.value_ptr.append(a, pat);
        }
        return Value.empty;
    }
    if (eql(sub, "ensemble")) return ensemble(it, args);
    if (eql(sub, "path")) return nsPath(it, args);
    return it.failCode("TCL LOOKUP INDEX subcommand", "unknown or ambiguous subcommand \"{s}\": must be children, code, current, delete, ensemble, eval, exists, export, forget, import, inscope, origin, parent, path, qualifiers, tail, unknown, upvar, or which", .{word});
}

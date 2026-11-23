//! Namespaces: the `namespace` command.
//!
//! A namespace is a prefix of names. The command `a::b::f` has the key
//! "a::b::f" in the command table, and the variable `a::b::x` is a
//! global cell with the name "a::b::x". The interpreter has a current
//! namespace. A proc runs in the namespace of its name, and
//! `namespace eval` runs a script in a frame of the namespace.
//!
//! Known differences from Tcl: `namespace path` and `namespace unknown`
//! have no effect, an imported command does not follow a later rename
//! of its source, and `namespace ensemble` has only `create` (with
//! `-command`, `-map`, and `-subcommands`) and `exists`.
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
};

/// `namespace ensemble create` and `namespace ensemble exists`.
fn ensemble(it: *Interp, args: []const Value) Error!Value {
    const a = it.alloc();
    if (args.len < 1) return it.wrongArgs("namespace ensemble subcommand ?arg ...?");
    const sub = try it.str(args[0]);
    if (eql(sub, "exists")) {
        if (args.len != 2) return it.wrongArgs("namespace ensemble exists cmdname");
        const c = it.findCommand(try it.str(args[1])) orelse return .{ .int = 0 };
        return .{ .int = @intFromBool(c.impl == .native and c.impl.native == &ensembleCall) };
    }
    if (!eql(sub, "create")) return it.fail("namespace ensemble {s} is not supported", .{sub});
    if (args.len % 2 != 1) return it.wrongArgs("namespace ensemble create ?option value ...?");
    const e = try a.create(Ensemble);
    e.* = .{ .ns = it.ns };
    var name: []const u8 = it.ns;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const o = try it.str(args[i]);
        if (eql(o, "-command")) {
            name = try it.qualify(try it.str(args[i + 1]));
        } else if (eql(o, "-map")) {
            e.map = try it.list(args[i + 1]);
            if (e.map.len % 2 != 0) return it.fail("missing value to go with key", .{});
        } else if (eql(o, "-subcommands")) {
            const l = try it.list(args[i + 1]);
            e.subs = if (l.len == 0) null else l;
        } else if (eql(o, "-prefixes") or eql(o, "-unknown") or eql(o, "-parameters")) {
            // These options have no effect.
        } else return it.fail("bad option \"{s}\": must be -command, -map, -parameters, -prefixes, -subcommands, or -unknown", .{o});
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
    if (old.subs) |l| e.subs = try c.vals(l);
    return e;
}

fn ensembleCall(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const a = it.alloc();
    const self = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name \"{s}\"", .{try it.str(argv[0])});
    const e: *Ensemble = @ptrCast(@alignCast(self.ctx orelse return it.fail("\"{s}\" is not an ensemble", .{try it.str(argv[0])})));
    if (argv.len < 2) return it.fail("wrong # args: should be \"{s} subcommand ?arg ...?\"", .{try it.str(argv[0])});
    const sub = try it.str(argv[1]);
    // The names: the given list, or the map, or the exported commands.
    var names: std.ArrayList([]const u8) = .empty;
    if (e.subs) |l| {
        for (l) |v| try names.append(a, try it.str(v));
    } else if (e.map.len > 0) {
        var k: usize = 0;
        while (k < e.map.len) : (k += 2) try names.append(a, try it.str(e.map[k]));
    } else {
        const prefix = try std.fmt.allocPrint(a, "{s}::", .{e.ns});
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
    // An exact name, or the one name that starts with the word.
    var chosen: ?[]const u8 = null;
    var count: usize = 0;
    for (names.items) |n| {
        if (eql(n, sub)) {
            chosen = n;
            count = 1;
            break;
        }
        if (sub.len > 0 and std.mem.startsWith(u8, n, sub)) {
            chosen = n;
            count += 1;
        }
    }
    if (count != 1) {
        var msg: std.ArrayList(u8) = .empty;
        try msg.print(a, "unknown or ambiguous subcommand \"{s}\": must be ", .{sub});
        for (names.items, 0..) |n, k| {
            if (k > 0) try msg.appendSlice(a, ", ");
            if (k > 0 and k == names.items.len - 1) try msg.appendSlice(a, "or ");
            try msg.appendSlice(a, n);
        }
        it.result = .{ .str = msg.items };
        it.error_code = .{ .str = "NONE" };
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
    try words.appendSlice(a, argv[2..]);
    // A relative word of the map is a command of the namespace.
    const saved_ns = it.ns;
    it.ns = try it.internNs(e.ns);
    defer it.ns = saved_ns;
    return it.callWords(words.items);
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
        return it.evalScript(script);
    }
    const f = try it.pushFrame(argv);
    defer it.popFrame();
    f.ns = it.ns;
    f.space = it.ns;
    return it.evalScript(script);
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
    const sub = try it.str(argv[1]);
    const args = argv[2..];
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
            if (eql(o, "-variable")) kind_var = true else if (!eql(o, "-command")) return it.wrongArgs("namespace which ?-command? ?-variable? name");
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
        return display(it, key);
    }
    if (eql(sub, "import")) {
        for (args) |v| {
            const word = try it.str(v);
            if (eql(word, "-force")) continue;
            const pat = std.mem.trimStart(u8, word, ":");
            const from = qualifiers(pat);
            const tail_pat = tail(pat);
            const prefix = try std.fmt.allocPrint(a, "{s}::", .{from});
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
                try it.commands.put(a, name, target);
            }
            it.epoch += 1;
        }
        return Value.empty;
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
        for (args) |v| {
            const word = try it.str(v);
            if (eql(word, "-clear")) {
                gop.value_ptr.* = .empty;
            } else try gop.value_ptr.append(a, word);
        }
        return Value.empty;
    }
    if (eql(sub, "ensemble")) return ensemble(it, args);
    if (eql(sub, "path")) return nsPath(it, args);
    if (eql(sub, "forget") or eql(sub, "unknown")) return Value.empty;
    return it.fail("unknown or ambiguous subcommand \"{s}\": must be children, code, current, delete, eval, exists, export, forget, import, inscope, origin, parent, path, qualifiers, tail, unknown, upvar, or which", .{sub});
}

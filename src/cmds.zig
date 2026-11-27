//! The core commands of the interpreter.
//!
//! No command opens a file, a socket, or a process, and no command reads
//! a clock. `puts` writes to the output callback of the interpreter.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const bigint = @import("bigint.zig");
const expr = @import("expr.zig");
const format = @import("format.zig");
const noise = @import("noise.zig");
const more = @import("more.zig");
const regex = @import("regex.zig");
const features = @import("features.zig");
const ns = @import("ns.zig");
const ucd = @import("ucd.zig");
const trace = @import("trace.zig");
const coro = @import("coro.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    const table = .{
        .{ "set", cmdSet },              .{ "unset", cmdUnset },        .{ "incr", cmdIncr },
        .{ "append", cmdAppend },        .{ "if", cmdIf },              .{ "while", cmdWhile },
        .{ "for", cmdFor },              .{ "foreach", cmdForeach },    .{ "lmap", cmdForeach },
        .{ "break", cmdBreak },          .{ "continue", cmdContinue },  .{ "proc", cmdProc },
        .{ "return", cmdReturn },        .{ "error", cmdError },        .{ "catch", cmdCatch },
        .{ "uplevel", cmdUplevel },      .{ "upvar", cmdUpvar },        .{ "global", cmdGlobal },
        .{ "expr", cmdExpr },            .{ "eval", cmdEval },          .{ "list", cmdList },
        .{ "lindex", cmdLindex },        .{ "llength", cmdLlength },    .{ "lappend", cmdLappend },
        .{ "lrange", cmdLrange },        .{ "lsearch", cmdLsearch },    .{ "lsort", more.cmdLsort },
        .{ "lreverse", cmdLreverse },    .{ "linsert", cmdLinsert },    .{ "lreplace", cmdLreplace },
        .{ "lassign", cmdLassign },      .{ "lrepeat", cmdLrepeat },    .{ "join", cmdJoin },
        .{ "split", cmdSplit },          .{ "concat", cmdConcat },      .{ "string", cmdString },
        .{ "format", format.cmdFormat }, .{ "info", cmdInfo },          .{ "puts", cmdPuts },
        .{ "switch", cmdSwitch },        .{ "rename", cmdRename },      .{ "apply", cmdApply },
        .{ "noise3", cmdNoise3 },        .{ "subst", cmdSubst },        .{ "lset", more.cmdLset },
        .{ "scan", more.cmdScan },       .{ "variable", cmdVariable },  .{ "namespace", ns.cmdNamespace },
        .{ "try", cmdTry },              .{ "throw", cmdThrow },        .{ "dict", @import("dict.zig").cmdDict },
        .{ "trace", trace.cmdTrace },    .{ "unknown", ns.cmdUnknown },
    };
    inline for (table) |t| try it.register(t[0], t[1]);
    if (comptime features.on("binary")) try it.register("binary", more.cmdBinary);
    if (comptime features.on("regexp")) {
        try it.register("regexp", regex.cmdRegexp);
        try it.register("regsub", regex.cmdRegsub);
    }
    try @import("mathns.zig").register(it);
    try @import("extra.zig").register(it);
    try coro.register(it);
    // The small `package` of the built-in modules.
    try @import("pkg.zig").registerBuiltin(it);
}

/// The direct form of a command site, or `.none`. The site must have a
/// literal name and no `{*}` word.
pub fn classify(command: *interp.Command, c: *Cmd) interp.Fast {
    if (command.impl != .native) return .none;
    const f = command.impl.native;
    const w = c.words;
    if (f == &cmdSet or f == &cmdIncr) {
        if (w.len < 2 or w[1].kind != .lit or w[1].kind.lit != .str) return .none;
        const name = w[1].kind.lit.str;
        // A plain local name: no array element and no namespace.
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "(:") != null) return .none;
        if (f == &cmdSet) return if (w.len == 3) .set else .none;
        if (w.len == 2) {
            c.by = 1;
            return .incr;
        }
        if (w.len == 3 and w[2].kind == .lit and w[2].kind.lit == .int) {
            c.by = w[2].kind.lit.int;
            return .incr;
        }
        return .none;
    }
    if (f == &cmdExpr) return if (w.len == 2 and w[1].kind == .lit) .expr else .none;
    if (f == &cmdIf) {
        for (w) |x| if (x.kind != .lit) return .none;
        if (w.len == 3) return .if_then;
        if (w.len == 5 and w[3].kind.lit == .str and eql(w[3].kind.lit.str, "else")) return .if_else;
    }
    return .none;
}

/// The function of a core command that the bytecode inlines.
pub fn coreFn(name: []const u8) ?interp.NativeFn {
    const table = [_]struct { []const u8, interp.NativeFn }{
        .{ "set", cmdSet },                       .{ "incr", cmdIncr },       .{ "expr", cmdExpr },
        .{ "if", cmdIf },                         .{ "while", cmdWhile },     .{ "for", cmdFor },
        .{ "foreach", cmdForeach },               .{ "return", cmdReturn },   .{ "break", cmdBreak },
        .{ "continue", cmdContinue },             .{ "lappend", cmdLappend }, .{ "append", cmdAppend },
        .{ "dict", @import("dict.zig").cmdDict }, .{ "lindex", cmdLindex },   .{ "llength", cmdLlength },
        .{ "string", cmdString },                 .{ "switch", cmdSwitch },   .{ "lassign", cmdLassign },
        .{ "lset", more.cmdLset },                .{ "lmap", cmdForeach },
    };
    for (table) |e| if (eql(e[0], name)) return e[1];
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---- Variables ----

fn cmdSet(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len == 3) {
        const name = try it.str(argv[1]);
        try it.setVar(name, argv[2]);
        // A write trace can change the value.
        if (it.var_traces != 0) return it.getVarPlain(name);
        return argv[2];
    }
    if (argv.len == 2) return it.getVar(try it.str(argv[1]));
    return it.wrongArgs("set varName ?newValue?");
}

fn cmdUnset(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var complain = true;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const s = try it.str(argv[i]);
        if (i == 1 and eql(s, "-nocomplain")) {
            complain = false;
        } else if (i <= 2 and eql(s, "--")) {
            continue;
        } else if (!try it.unsetVar(s) and complain) {
            return it.fail("can't unset \"{s}\": no such variable", .{s});
        }
    }
    return Value.empty;
}

pub fn cmdIncr(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2 and argv.len != 3) return it.wrongArgs("incr varName ?increment?");
    const name = try it.str(argv[1]);
    const by: Value = if (argv.len == 3) try expr.intArg(it, argv[2]) else .{ .int = 1 };
    const cur: Value = if (try it.getVarOpt(name)) |v| try expr.intArg(it, v) else .{ .int = 0 };
    const out = try expr.addInts(it, cur, by);
    try it.setVar(name, out);
    return out;
}

pub fn cmdAppend(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("append varName ?value ...?");
    const name = try it.str(argv[1]);
    if (argv.len == 2) return it.getVar(name);
    // Tcl runs no read trace for `append`.
    const cur = if (try it.getVarQuiet(name)) |v| try it.str(v) else "";
    var small: [8][]const u8 = undefined;
    const parts = if (argv.len - 2 <= small.len) small[0 .. argv.len - 2] else try it.alloc().alloc([]const u8, argv.len - 2);
    for (argv[2..], parts) |v, *s| s.* = try it.str(v);
    const res: Value = .{ .str = try it.appendStr(cur, parts) };
    try it.setVar(name, res);
    return res;
}

fn cmdGlobal(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (it.frame == &it.global) return Value.empty;
    for (argv[1..]) |v| {
        const name = try it.str(v);
        const target = (try it.findVar(&it.global, name, true)).?;
        try it.linkVar(ns.tail(name), target);
    }
    return Value.empty;
}

/// `variable name ?value? ...`: there is one namespace, so the name is
/// a global variable.
fn cmdVariable(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("variable ?name value...? name ?value?");
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        const given = try it.str(argv[i]);
        // The variable of the current namespace is a global cell with
        // the full name.
        const name = try it.qualify(given);
        const target = try it.globalVar(name);
        if (i + 1 < argv.len) {
            if (target.v == .arr) return it.fail("can't set \"{s}\": variable is array", .{name});
            if (target.v == .traced) {
                try @import("trace.zig").write(it, target, name, null, argv[i + 1]);
            } else target.v = .{ .val = argv[i + 1] };
        }
        if (it.frame != &it.global and it.frame.ns == null) try it.linkVar(ns.tail(given), target);
    }
    return Value.empty;
}

fn cmdUpvar(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const usage = "upvar ?level? otherVar localVar ?otherVar localVar ...?";
    if (argv.len < 3) return it.wrongArgs(usage);
    var i: usize = 1;
    var frame = it.frame.parent orelse it.frame;
    if (argv.len % 2 == 0) {
        frame = try it.frameAt(try it.str(argv[1])) orelse
            return it.fail("bad level \"{s}\"", .{try it.str(argv[1])});
        i = 2;
    } else if (it.frame == &it.global) {
        return it.fail("bad level \"1\"", .{});
    }
    while (i + 1 < argv.len) : (i += 2) {
        const other = try it.str(argv[i]);
        const base, const elem = Interp.splitName(other);
        if (elem) |at| {
            const array = (try it.findVar(frame, base, true)).?;
            if (array.v == .val) return it.fail("can't upvar from variable to itself", .{});
            try it.linkVar(try it.str(argv[i + 1]), try it.elemCell(array, base, at));
            continue;
        }
        const target = (try it.findVar(frame, other, true)).?;
        try it.linkVar(try it.str(argv[i + 1]), target);
    }
    return Value.empty;
}

fn cmdUplevel(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("uplevel ?level? command ?arg ...?");
    var i: usize = 1;
    var frame = it.frame.parent orelse it.frame;
    if (try it.frameAt(try it.str(argv[1]))) |f| {
        if (argv.len == 2) return it.wrongArgs("uplevel ?level? command ?arg ...?");
        frame = f;
        i = 2;
    }
    const saved = it.frame;
    const saved_ns = it.ns;
    it.frame = frame;
    it.ns = frame.space;
    defer {
        it.frame = saved;
        it.ns = saved_ns;
    }
    // The frame of the caller is not in the chain of `frame`.
    const keep = [_]usize{ @intFromPtr(saved), @intFromPtr(saved_ns.ptr) };
    if (i == argv.len - 1 and argv[i] == .list and it.nest != 0) return it.evalWords(argv[i].list.items());
    if (i == argv.len - 1) return it.evalBody(try it.scriptOf(argv, i, cmd), argv, &keep);
    if (it.nest != 0) if (try joinWords(it, argv[i..])) |words| return it.evalWords(words);
    return it.evalBody(try it.scriptOfValue(.{ .str = try concat(it, argv[i..]) }, null), argv, &keep);
}

/// The words of the `concat` of `args` when each one is a list, an
/// integer, or a double: the items of the lists and the numbers, in
/// order. A number has the string form of one word. Null when an
/// argument is a string, or when the result has no word. The text path
/// then parses the `concat` of the texts.
fn joinWords(it: *Interp, args: []const Value) Error!?[]const Value {
    var n: usize = 0;
    for (args) |v| n += switch (v) {
        .list => |l| l.len,
        .int, .double => 1,
        .str => return null,
    };
    if (n == 0) return null;
    const words = try it.alloc().alloc(Value, n);
    var k: usize = 0;
    for (args) |v| {
        if (v == .list) {
            @memcpy(words[k..][0..v.list.len], v.list.items());
            k += v.list.len;
        } else {
            words[k] = v;
            k += 1;
        }
    }
    return words;
}

/// True for a native command whose frame keeps each value across its
/// body in `argv` or in the `keep` list of `Interp.evalBody`. Add a
/// command here only after a check of its locals. A stress run of a
/// precise build shows a missed value.
pub fn isBodyCommand(f: interp.NativeFn) bool {
    return f == &cmdCatch or f == &cmdTry or f == &cmdEval or f == &cmdUplevel or f == &cmdApply or
        f == &ns.cmdNamespace or ((comptime features.on("oo")) and f == &@import("oo.zig").objCmd);
}

// ---- Control flow ----

fn cmdIf(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    var i: usize = 1;
    // The body to run. The scan goes on after a true condition, so that
    // a wrong word after it is still an error.
    var chosen: ?usize = null;
    var done = false;
    while (true) {
        if (i >= argv.len) return it.fail("wrong # args: no expression after \"{s}\" argument", .{try it.str(argv[i - 1])});
        const cond = !done and try expr.truthy(it, try expr.eval(it, try it.exprOf(argv, i, cmd)));
        i += 1;
        if (i < argv.len and argv[i] == .str and eql(argv[i].str, "then")) i += 1;
        if (i >= argv.len) return it.fail("wrong # args: no script following \"{s}\" argument", .{try it.str(argv[i - 1])});
        if (cond) {
            chosen = i;
            done = true;
        }
        i += 1;
        if (i >= argv.len) break;
        const word = try it.str(argv[i]);
        if (eql(word, "elseif")) {
            i += 1;
            continue;
        }
        if (eql(word, "else")) {
            i += 1;
            if (i >= argv.len) return it.fail("wrong # args: no script following \"else\" argument", .{});
        }
        if (i != argv.len - 1) return it.fail("wrong # args: extra words after \"else\" clause in \"if\" command", .{});
        if (!done) chosen = i;
        break;
    }
    if (chosen) |k| return it.evalScript(try it.scriptOf(argv, k, cmd));
    return Value.empty;
}

pub fn step(it: *Interp) Error!void {
    if (it.compute_limit == 0) return it.fail("compute limit reached", .{});
    it.compute_limit -= 1;
    try it.checkMem();
}

fn cmdWhile(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len != 3) return it.wrongArgs("while test command");
    const cond = try it.exprOf(argv, 1, cmd);
    const body = try it.scriptOf(argv, 2, cmd);
    while (try expr.truthy(it, try expr.eval(it, cond))) {
        try step(it);
        _ = it.evalScript(body) catch |e| switch (e) {
            error.TclBreak => break,
            error.TclContinue => continue,
            else => return e,
        };
    }
    return Value.empty;
}

fn cmdFor(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len != 5) return it.wrongArgs("for start test next command");
    _ = try it.evalScript(try it.scriptOf(argv, 1, cmd));
    const cond = try it.exprOf(argv, 2, cmd);
    const next = try it.scriptOf(argv, 3, cmd);
    const body = try it.scriptOf(argv, 4, cmd);
    while (try expr.truthy(it, try expr.eval(it, cond))) {
        try step(it);
        _ = it.evalScript(body) catch |e| switch (e) {
            error.TclBreak => break,
            error.TclContinue => {},
            else => return e,
        };
        _ = it.evalScript(next) catch |e| switch (e) {
            error.TclBreak => break,
            else => return e,
        };
    }
    return Value.empty;
}

/// `foreach` and `lmap`: the name of the command selects the result.
fn cmdForeach(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    return loop(it, argv, cmd, if (eql(try it.str(argv[0]), "lmap")) .map else .each);
}

/// lfilter varList list ?varList list ...? command (Tcl 9.1): the values
/// of the first variable for the passes where the command gives true.
pub fn cmdLfilter(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    return loop(it, argv, cmd, .filter);
}

fn loop(it: *Interp, argv: []const Value, cmd: ?*Cmd, mode: enum { each, map, filter }) Error!Value {
    const is_map = mode != .each;
    if (argv.len < 4 or argv.len % 2 != 0) {
        return switch (mode) {
            .map => it.wrongArgs("lmap varList list ?varList list ...? command"),
            .filter => it.wrongArgs("lfilter varList list ?varList list ...? command"),
            .each => it.wrongArgs("foreach varList list ?varList list ...? command"),
        };
    }
    const a = it.alloc();
    const n = (argv.len - 2) / 2;
    const names = try a.alloc([]const Value, n);
    const lists = try a.alloc([]const Value, n);
    var passes: usize = 0;
    for (0..n) |k| {
        names[k] = try it.list(argv[1 + 2 * k]);
        lists[k] = try it.list(argv[2 + 2 * k]);
        if (names[k].len == 0) return it.fail("{s} varlist is empty", .{switch (mode) {
            .each => "foreach",
            .map => "lmap",
            .filter => "lfilter",
        }});
        passes = @max(passes, (lists[k].len + names[k].len - 1) / names[k].len);
    }
    const body = try it.scriptOf(argv, argv.len - 1, cmd);
    var out: std.ArrayList(Value) = .empty;
    var pass: usize = 0;
    while (pass < passes) : (pass += 1) {
        try step(it);
        for (0..n) |k| {
            for (names[k], 0..) |name, j| {
                const idx = pass * names[k].len + j;
                try it.setVar(try it.str(name), if (idx < lists[k].len) lists[k][idx] else Value.empty);
            }
        }
        const v = it.evalScript(body) catch |e| switch (e) {
            error.TclBreak => break,
            error.TclContinue => continue,
            else => return e,
        };
        switch (mode) {
            .map => try out.append(a, v),
            .filter => if (try @import("expr.zig").truthy(it, v)) try out.append(a, if (lists[0].len > pass * names[0].len) lists[0][pass * names[0].len] else Value.empty),
            .each => {},
        }
    }
    if (is_map) return value.wrapList(a, out.items);
    return Value.empty;
}

fn cmdBreak(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("break");
    it.result = Value.empty;
    return error.TclBreak;
}

fn cmdContinue(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("continue");
    it.result = Value.empty;
    return error.TclContinue;
}

/// A value of `switch -integer` as a 64-bit integer, as Tcl 9.1 reads it.
fn switchInt(it: *Interp, v: Value) Error!i64 {
    if (v == .int) return v.int;
    const s = try it.str(v);
    if (value.parseIntStrict(s)) |n| return n;
    if (bigint.isIntegerText(s)) return it.failCode("ARITH IOVERFLOW {integer value too large to represent}", "integer value too large to represent", .{});
    return it.failCode("TCL VALUE NUMBER", "expected integer but got \"{s}\"", .{s});
}

fn cmdSwitch(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    var i: usize = 1;
    const Match = enum { exact, glob, regexp, integer };
    const t9 = it.tcl9();
    var match: Match = .exact;
    var nocase = false;
    var match_var: ?Value = null;
    var index_var: ?Value = null;
    var mode_word: ?[]const u8 = null;
    // As in Tcl, the options end two words before the end, so the last
    // two words are always the string and the patterns.
    while (i + 2 < argv.len) : (i += 1) {
        const s = try it.str(argv[i]);
        if (s.len == 0 or s[0] != '-') break;
        if (eql(s, "--")) {
            i += 1;
            break;
        }
        var opt: []const u8 = s;
        var hits: usize = 0;
        // Tcl 9.1 adds -integer (TIP 730).
        const names8 = [_][]const u8{ "-exact", "-glob", "-indexvar", "-matchvar", "-nocase", "-regexp" };
        const names9 = [_][]const u8{ "-exact", "-glob", "-indexvar", "-integer", "-matchvar", "-nocase", "-regexp" };
        const names: []const []const u8 = if (t9) &names9 else &names8;
        for (names) |n| {
            if (s.len > 1 and std.mem.startsWith(u8, n, s)) {
                opt = n;
                hits += 1;
            }
            if (eql(n, s)) {
                opt = n;
                hits = 1;
                break;
            }
        }
        if (hits != 1) {
            const head = if (hits > 1) "ambiguous" else "bad";
            if (t9) return it.failCode("TCL LOOKUP INDEX option", "{s} option \"{s}\": must be -exact, -glob, -indexvar, -integer, -matchvar, -nocase, -regexp, or --", .{ head, s });
            return it.failCode("TCL LOOKUP INDEX option", "{s} option \"{s}\": must be -exact, -glob, -indexvar, -matchvar, -nocase, -regexp, or --", .{ head, s });
        }
        if (eql(opt, "-glob") or eql(opt, "-exact") or eql(opt, "-regexp") or eql(opt, "-integer")) {
            if (mode_word) |prev| return it.failCode("TCL OPERATION SWITCH DOUBLEOPT", "bad option \"{s}\": {s} option already found", .{ s, prev });
            mode_word = opt;
            match = if (eql(opt, "-glob")) .glob else if (eql(opt, "-exact")) .exact else if (eql(opt, "-integer")) .integer else .regexp;
        } else if (eql(opt, "-nocase")) {
            nocase = true;
        } else {
            i += 1;
            if (i + 2 >= argv.len) return it.fail("missing variable name argument to {s} option", .{opt});
            if (eql(opt, "-matchvar")) match_var = argv[i] else index_var = argv[i];
        }
    }
    if (match == .integer and nocase) return it.failCode("TCL OPERATION SWITCH MODERESTRICTION", "-nocase option cannot be used with -integer option", .{});
    if (match != .regexp and match_var != null) return it.fail("-matchvar option requires -regexp option", .{});
    if (match != .regexp and index_var != null) return it.fail("-indexvar option requires -regexp option", .{});
    if (i + 1 >= argv.len) return it.wrongArgs("switch ?-option ...? string ?pattern body ...? ?default body?");
    const subject = try it.str(argv[i]);
    const subject_int: i64 = if (match == .integer) try switchInt(it, argv[i]) else 0;
    i += 1;
    var arms = argv[i..];
    const one_list = arms.len == 1;
    if (one_list) arms = try it.list(arms[0]);
    if (arms.len == 0) return it.wrongArgs("switch ?-option ...? string {{?pattern body ...? ?default body?}}");
    if (arms.len % 2 != 0) {
        // A comment in a braced body is a common cause of this error.
        if (one_list) for (arms) |w| {
            if ((try it.str(w)).len > 0 and (try it.str(w))[0] == '#') {
                return it.fail("extra switch pattern with no body, this may be due to a comment incorrectly placed outside of a switch body - see the \"switch\" documentation", .{});
            }
        };
        return it.fail("extra switch pattern with no body", .{});
    }
    if (eql(try it.str(arms[arms.len - 1]), "-")) {
        return it.fail("no body specified for pattern \"{s}\"", .{try it.str(arms[arms.len - 2])});
    }
    var k: usize = 0;
    while (k < arms.len) : (k += 2) {
        const pat = try it.str(arms[k]);
        var hit = k == arms.len - 2 and eql(pat, "default");
        if (hit) {
            if (match_var) |mv| try it.setVar(try it.str(mv), Value.empty);
            if (index_var) |iv| try it.setVar(try it.str(iv), Value.empty);
        } else switch (match) {
            .exact => hit = if (nocase) std.ascii.eqlIgnoreCase(pat, subject) else eql(pat, subject),
            .glob => hit = try globSteps(it, pat, subject, nocase),
            .integer => hit = try switchInt(it, arms[k]) == subject_int,
            .regexp => {
                if (comptime !features.on("regexp")) return features.fail(it, "regexp", "switch -regexp");
                const re = try regex.compile(it, pat, .{ .nocase = nocase });
                var m = try regex.Matcher.init(it, re, subject);
                hit = try m.search(0);
                if (hit) {
                    var texts: std.ArrayList(Value) = .empty;
                    var spans: std.ArrayList(Value) = .empty;
                    for (0..re.ncap) |g| {
                        const lo = m.caps[2 * g];
                        const hi = m.caps[2 * g + 1];
                        const have = lo != null and hi != null;
                        try texts.append(it.alloc(), if (have) .{ .str = subject[lo.?..hi.?] } else Value.empty);
                        const span = [2]Value{ .{ .int = if (have) @intCast(lo.?) else -1 }, .{ .int = if (have) @as(i64, @intCast(hi.?)) - 1 else -1 } };
                        try spans.append(it.alloc(), try value.newList(it.alloc(), &span));
                    }
                    if (match_var) |mv| try it.setVar(try it.str(mv), try value.wrapList(it.alloc(), texts.items));
                    if (index_var) |iv| try it.setVar(try it.str(iv), try value.wrapList(it.alloc(), spans.items));
                }
            },
        }
        if (!hit) continue;
        // A body of "-" means the body of the next arm.
        while (k + 2 < arms.len and eql(try it.str(arms[k + 1]), "-")) k += 2;
        if (one_list) return it.evalScript(try it.scriptOfValue(arms[k + 1], null));
        return it.evalScript(try it.scriptOf(argv, i + k + 1, cmd));
    }
    return Value.empty;
}

// ---- Procedures, results, and errors ----

pub fn makeProc(it: *Interp, params_v: Value, body: Value) Error!*interp.Proc {
    const a = it.alloc();
    const plist = try it.list(params_v);
    var params: std.ArrayList(interp.Param) = .empty;
    var has_args = false;
    for (plist, 0..) |pv, i| {
        const parts = try it.list(pv);
        if (parts.len == 0) return it.fail("argument with no name", .{});
        if (parts.len > 2) return it.fail("too many fields in argument specifier \"{s}\"", .{try it.str(pv)});
        const name = try it.str(parts[0]);
        if (Interp.splitName(name)[1] != null) return it.fail("formal parameter \"{s}\" is an array element", .{name});
        if (std.mem.indexOf(u8, name, "::") != null) return it.fail("formal parameter \"{s}\" is not a simple name", .{name});
        if (i == plist.len - 1 and eql(name, "args") and parts.len == 1) {
            has_args = true;
        } else {
            try params.append(a, .{ .name = name, .default = if (parts.len == 2) parts[1] else null });
        }
    }
    const p = try a.create(interp.Proc);
    p.* = .{ .params = params.items, .has_args = has_args, .body = body, .params_text = params_v };
    return p;
}

fn cmdProc(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 4) return it.wrongArgs("proc name args body");
    const a = it.alloc();
    const p = try makeProc(it, argv[2], argv[3]);
    const name = try it.qualify(try it.str(argv[1]));
    // The proc runs in the namespace of its name.
    p.ns = try it.internNs(ns.qualifiers(name));
    if (it.commands.get(name)) |old| try trace.commandEvent(it, old, name, "", 2);
    const c = try a.create(interp.Command);
    c.* = .{ .name = name, .impl = .{ .proc = p } };
    try it.commands.put(a, name, c);
    it.epoch += 1;
    if (@import("probe.zig").enabled and it.probes != null) @import("probe.zig").procDefined(it, name, p);
    return Value.empty;
}

fn stripNs(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "::")) name[2..] else name;
}

fn cmdApply(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("apply lambdaExpr ?arg ...?");
    const p = try lambdaProc(it, argv[1]);
    const mark = try it.beginProcBody(argv, &.{@intFromPtr(p)});
    defer it.endProcBody(mark);
    return it.callLambda(p, argv);
}

/// The proc of a lambda, from `lambda_cache` or new. The key of a list
/// is its items, and a hit also needs the same first two items, because
/// a write in place can change an item. A string does not change. The
/// namespace check runs on each call, because a script can delete the
/// namespace. A bad lambda does not go in the table. `makeProc` uses no
/// compute unit, so a hit and a miss use the same units.
fn lambdaProc(it: *Interp, lam: Value) Error!*interp.Proc {
    const key: Interp.SliceKey = switch (lam) {
        .list => |l| .{ .ptr = @intFromPtr(l.obj.buf.ptr), .len = l.len | Interp.lambda_list_bit },
        .str => |t| .{ .ptr = @intFromPtr(t.ptr), .len = t.len },
        else => .{ .ptr = 0, .len = 0 },
    };
    var ns_word: ?Value = null;
    const p = hit: {
        if (key.len != 0) if (it.lambda_cache.get(key)) |p| {
            if (lam != .list) {
                ns_word = p.lambda_ns;
                break :hit p;
            }
            const items = lam.list.items();
            if (sameValue(items[0], p.params_text) and sameValue(items[1], p.body)) {
                if (items.len == 3) ns_word = items[2];
                break :hit p;
            }
        };
        const lambda = try it.list(lam);
        if (lambda.len < 2 or lambda.len > 3) return it.fail("can't interpret \"{s}\" as a lambda expression", .{try it.str(lam)});
        const p = makeProc(it, lambda[0], lambda[1]) catch |e| {
            if (e == error.TclError) {
                it.in_error = true;
                it.error_info = .empty;
                try it.error_info.print(it.alloc(), "{s}\n    (parsing lambda expression \"{s}\")", .{ try it.str(it.result), try it.str(lam) });
            }
            return e;
        };
        if (lambda.len == 3) ns_word = lambda[2];
        p.lambda_ns = ns_word;
        if (key.len != 0) try it.lambda_cache.put(it.heap.backing, key, p);
        break :hit p;
    };
    p.ns = "";
    if (ns_word) |w| {
        const raw = try it.str(w);
        const space = std.mem.trim(u8, raw, ":");
        if (space.len > 0 and !it.namespaces.contains(space)) {
            // Tcl names the namespace of a lambda from the global one.
            const given = if (std.mem.startsWith(u8, raw, "::")) raw else try std.fmt.allocPrint(it.alloc(), "::{s}", .{raw});
            return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP NAMESPACE {s}", .{given}), "namespace \"{s}\" not found", .{given});
        }
        p.ns = try it.internNs(space);
    }
    return p;
}

/// True when two values are the same bits: the same number, or the same
/// bytes or items at the same address.
fn sameValue(a: Value, b: Value) bool {
    return switch (a) {
        .int => |x| b == .int and b.int == x,
        .double => |x| b == .double and @as(u64, @bitCast(b.double)) == @as(u64, @bitCast(x)),
        .str => |x| b == .str and b.str.ptr == x.ptr and b.str.len == x.len,
        .list => |x| b == .list and b.list.obj == x.obj and b.list.len == x.len,
    };
}

fn cmdRename(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3) return it.wrongArgs("rename oldName newName");
    const old = it.commandKey(try it.str(argv[1])) orelse stripNs(try it.str(argv[1]));
    const new_given = try it.str(argv[2]);
    const new = if (new_given.len == 0) new_given else try it.qualify(new_given);
    const kv = it.commands.fetchRemove(old) orelse
        return it.fail("can't {s} \"{s}\": command doesn't exist", .{ if (new.len == 0) "delete" else "rename", old });
    it.epoch += 1;
    if (new.len == 0) {
        try trace.commandEvent(it, kv.value, old, "", 2);
        coro.commandGone(it, kv.value);
        if (comptime features.on("oo")) @import("oo.zig").commandGone(it, kv.value);
        // The imports of a deleted command go away.
        if (eql(kv.value.name, old)) {
            var gone: std.ArrayList([]const u8) = .empty;
            try chargeEntries(it, it.commands.count());
            var iter = it.commands.iterator();
            while (iter.next()) |e| if (e.value_ptr.* == kv.value) try gone.append(it.alloc(), e.key_ptr.*);
            for (gone.items) |k| _ = it.commands.remove(k);
        }
        return Value.empty;
    }
    if (it.commands.contains(new)) {
        try it.commands.put(it.alloc(), kv.key, kv.value);
        return it.fail("can't rename to \"{s}\": command already exists", .{new});
    }
    const new_key = try it.alloc().dupe(u8, new);
    try it.commands.put(it.alloc(), new_key, kv.value);
    if (eql(kv.value.name, old)) kv.value.name = new_key;
    try trace.commandEvent(it, kv.value, old, new, 1);
    return Value.empty;
}

fn codeOf(it: *Interp, v: Value) Error!interp.ReturnCode {
    const s = try it.str(v);
    if (std.meta.stringToEnum(interp.ReturnCode, s)) |c| return c;
    if (v.asInt()) |n| if (n >= 0 and n <= std.math.maxInt(u32)) return @fromBackingInt(@intCast(@as(u32, @intCast(n))));
    return it.fail("bad completion code \"{s}\": must be ok, error, return, break, continue, or an integer", .{s});
}

fn cmdReturn(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var code: interp.ReturnCode = .ok;
    var level: u32 = 1;
    var ecode: ?Value = null;
    var einfo: ?Value = null;
    var i: usize = 1;
    // The pairs of the options. `-options` adds the pairs of its dict.
    var pairs: std.ArrayList(Value) = .empty;
    while (i + 1 < argv.len) : (i += 2) {
        const opt = try it.str(argv[i]);
        if (opt.len == 0 or opt[0] != '-') break;
        if (eql(opt, "-options")) {
            try pairs.appendSlice(it.alloc(), try it.list(argv[i + 1]));
        } else try pairs.appendSlice(it.alloc(), argv[i .. i + 2]);
    }
    // The options other than -code and -level, as a dict: a key keeps
    // the place of its first pair and the value of its last pair.
    var extra: std.ArrayList(Value) = .empty;
    var k: usize = 0;
    while (k + 1 < pairs.items.len) : (k += 2) {
        const opt = try it.str(pairs.items[k]);
        const v = pairs.items[k + 1];
        if (!eql(opt, "-code") and !eql(opt, "-level")) {
            var j: usize = 0;
            while (j < extra.items.len) : (j += 2) {
                if (eql(try it.str(extra.items[j]), opt)) break;
            }
            if (j < extra.items.len) extra.items[j + 1] = v else try extra.appendSlice(it.alloc(), &.{ pairs.items[k], v });
        }
        if (eql(opt, "-code")) {
            code = try codeOf(it, v);
        } else if (eql(opt, "-level")) {
            const n = v.asInt() orelse -1;
            if (n < 0) return it.fail("bad -level value: expected non-negative integer but got \"{s}\"", .{try it.str(v)});
            level = @intCast(n);
        } else if (eql(opt, "-errorcode")) {
            ecode = v;
        } else if (eql(opt, "-errorinfo")) {
            einfo = v;
        }
    }
    it.result = if (i < argv.len) argv[i] else Value.empty;
    if (code == .@"error") {
        it.error_code = ecode orelse .{ .str = "NONE" };
        if (einfo) |info| try startInfo(it, info);
    }
    // A forged tail code must not run tail call words that a `catch`
    // stopped earlier.
    if (@backingInt(code) == @import("coro.zig").tail_code) it.tail_words = null;
    if (level == 0) {
        // The code applies to the `return` command itself.
        return switch (code) {
            .ok => it.result,
            .@"error" => error.TclError,
            .@"return" => blk: {
                it.ret_code = .ok;
                it.ret_level = 1;
                it.ret_opts = &.{};
                break :blk error.TclReturn;
            },
            .@"break" => error.TclBreak,
            .@"continue" => error.TclContinue,
            _ => blk: {
                it.custom_code = @backingInt(code);
                break :blk error.TclCustom;
            },
        };
    }
    // `-code return` with a level of n is the code ok with a level of
    // n + 1, as in Tcl.
    if (code == .@"return") {
        code = .ok;
        level += 1;
    }
    it.ret_code = code;
    it.ret_level = level;
    it.ret_opts = extra.items;
    return error.TclReturn;
}

/// Starts the trace of an error with a given text.
fn startInfo(it: *Interp, info: Value) Error!void {
    const text = try it.str(info);
    if (text.len == 0) return;
    it.in_error = true;
    it.error_info = .empty;
    try it.error_info.appendSlice(it.alloc(), text);
    it.skip_info = true;
}

fn cmdError(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2 or argv.len > 4) return it.wrongArgs("error message ?errorInfo? ?errorCode?");
    it.result = argv[1];
    it.error_code = if (argv.len == 4) argv[3] else .{ .str = "NONE" };
    if (argv.len >= 3) try startInfo(it, argv[2]);
    return error.TclError;
}

fn cmdThrow(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3) return it.wrongArgs("throw type message");
    if ((try it.list(argv[1])).len == 0) return it.fail("type must be non-empty list", .{});
    it.result = argv[2];
    it.error_code = argv[1];
    return error.TclError;
}

/// The end of a script that ran under `catch` or `try`.
pub const Caught = struct {
    code: i64 = 0,
    res: Value = Value.empty,
    /// The code and the level of a caught `return`.
    ret_code: interp.ReturnCode = .ok,
    ret_level: u32 = 1,
    /// The other options of a caught `return`, as pairs.
    ret_opts: []const Value = &.{},
    error_code: Value = .{ .str = "NONE" },
    error_info: Value = Value.empty,
    error_line: u32 = 0,
    /// The options of the exception that this one replaced in `try`.
    during: ?Value = null,

    /// The options dict: the third argument of `catch`.
    pub fn options(c: Caught, it: *Interp) Error!Value {
        if (c.code == 2 and c.ret_opts.len > 0) return c.returnOptions(it);
        var o: [12]Value = undefined;
        o[0] = .{ .str = "-code" };
        o[1] = .{ .int = if (c.code == 2) @backingInt(c.ret_code) else c.code };
        o[2] = .{ .str = "-level" };
        o[3] = .{ .int = if (c.code == 2) c.ret_level else 0 };
        if (c.code != 1) return value.newList(it.alloc(), o[0..4]);
        o[4] = .{ .str = "-errorcode" };
        o[5] = c.error_code;
        o[6] = .{ .str = "-errorinfo" };
        o[7] = c.error_info;
        o[8] = .{ .str = "-errorline" };
        o[9] = .{ .int = c.error_line };
        if (c.during) |d| {
            o[10] = .{ .str = "-during" };
            o[11] = d;
            return value.newList(it.alloc(), &o);
        }
        return value.newList(it.alloc(), o[0..10]);
    }

    /// The options dict of a caught `return` with options: its options
    /// in their order, then `-code` and `-level`. With `-code error` and
    /// `-errorinfo`, Tcl also adds `-errorcode NONE` and `-errorline 1`
    /// when they are absent.
    fn returnOptions(c: Caught, it: *Interp) Error!Value {
        const a = it.alloc();
        var o: std.ArrayList(Value) = .empty;
        try o.appendSlice(a, c.ret_opts);
        try o.appendSlice(a, &.{ .{ .str = "-code" }, .{ .int = @backingInt(c.ret_code) }, .{ .str = "-level" }, .{ .int = c.ret_level } });
        if (c.ret_code == .@"error" and try hasKey(it, c.ret_opts, "-errorinfo")) {
            if (!try hasKey(it, c.ret_opts, "-errorcode")) try o.appendSlice(a, &.{ .{ .str = "-errorcode" }, .{ .str = "NONE" } });
            if (!try hasKey(it, c.ret_opts, "-errorline")) try o.appendSlice(a, &.{ .{ .str = "-errorline" }, .{ .int = 1 } });
        }
        return value.newList(a, o.items);
    }

    fn hasKey(it: *Interp, pairs: []const Value, key: []const u8) Error!bool {
        var k: usize = 0;
        while (k + 1 < pairs.len) : (k += 2) {
            if (eql(try it.str(pairs[k]), key)) return true;
        }
        return false;
    }

    /// Gives the end of the script again to the caller.
    pub fn raise(c: Caught, it: *Interp) Error!Value {
        it.result = c.res;
        switch (c.code) {
            0 => return c.res,
            1 => {
                it.error_code = c.error_code;
                try startInfo(it, c.error_info);
                it.skip_info = false;
                it.pending_during = c.during;
                return error.TclError;
            },
            2 => {
                it.ret_code = c.ret_code;
                it.ret_level = c.ret_level;
                it.ret_opts = c.ret_opts;
                return error.TclReturn;
            },
            3 => return error.TclBreak,
            4 => return error.TclContinue,
            else => {
                it.custom_code = @intCast(c.code);
                return error.TclCustom;
            },
        }
    }
};

/// Runs a script and catches its end. The end of the compute limit is not
/// caught: it stays an error.
pub fn runCaught(it: *Interp, script: Error!*interp.Script) Error!Caught {
    return runCaughtBody(it, script, &.{}, null);
}

/// `runCaught` for the body of a command with the words `argv`.
/// With `site`, an error gets that command in its trace before the catch.
fn runCaughtBody(it: *Interp, script: Error!*interp.Script, argv: []const Value, site: ?*Cmd) Error!Caught {
    const depth = it.depth;
    const frame = it.frame;
    var c: Caught = .{};
    const r = if (script) |sc| it.evalBody(sc, argv, &.{}) else |e| e;
    if (r) |v| {
        c.res = v;
    } else |e| {
        c.code = switch (e) {
            error.OutOfMemory => return e,
            error.TclError => 1,
            error.TclReturn => 2,
            error.TclBreak => 3,
            error.TclContinue => 4,
            error.TclCustom => it.custom_code,
        };
        // `break` and `continue` leave an empty result, and
        // `return -level 0 -code break VALUE` leaves VALUE.
        c.res = it.result;
        if (c.code == 2) {
            c.ret_code = it.ret_code;
            c.ret_level = it.ret_level;
            c.ret_opts = it.ret_opts;
            it.ret_opts = &.{};
        }
    }
    if (c.code == 1) {
        // A script cannot catch the end of its compute limit or of its memory.
        if (it.uncatchable() or coro.unwinding(it)) return error.TclError;
        c.error_line = it.proc_line;
        if (site) |s| if (it.in_error) try it.addErrorInfo(s);
        try it.finishError();
        c.error_code = it.error_code;
        c.error_info = it.last_info;
        c.during = it.last_during;
    }
    std.debug.assert(it.depth == depth and it.frame == frame);
    it.error_line = 0;
    return c;
}

/// The debugger counts the open bodies that catch an error, for its
/// exception filter `uncaught`. With no debugger, it costs one test.
fn enterCatch(it: *Interp) bool {
    const probe = @import("probe.zig");
    if (comptime !probe.enabled) return false;
    const s = it.probes orelse return false;
    if (s.line_hook == null) return false;
    s.catching += 1;
    return true;
}

fn leaveCatch(it: *Interp, on: bool) void {
    if (!on) return;
    if (it.probes) |s| s.catching -|= 1;
}

fn cmdCatch(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len < 2 or argv.len > 4) return it.wrongArgs("catch script ?resultVarName? ?optionVarName?");
    // Tcl compiles `catch` in a proc body, and also outside one when it
    // has no variables. A compiled `catch` of a script that is not a
    // literal word adds the `catch` command to the error trace.
    var site: ?*Cmd = null;
    if (cmd) |c| {
        const in_proc = it.frame != &it.global and it.frame.ns == null;
        const literal = !c.has_expand and c.words.len > 1 and c.words[1].kind == .lit;
        if (!literal and (in_proc or argv.len == 2)) site = c;
    }
    const counted = enterCatch(it);
    const r = runCaughtBody(it, it.scriptOf(argv, 1, cmd), argv, site);
    leaveCatch(it, counted);
    const c = try r;
    if (argv.len >= 3) try it.setVar(try it.str(argv[2]), c.res);
    if (argv.len == 4) try it.setVar(try it.str(argv[3]), try c.options(it));
    return .{ .int = c.code };
}

/// `try body ?on code vars script ...? ?trap pattern vars script ...?
/// ?finally script?`
fn cmdTry(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    const usage = "try body ?handler ...? ?finally script?";
    if (argv.len < 2) return it.wrongArgs(usage);
    var finally: ?usize = null;
    var end = argv.len;
    if (argv.len >= 4 and eql(try it.str(argv[argv.len - 2]), "finally")) {
        finally = argv.len - 1;
        end = argv.len - 2;
    }
    if ((end - 2) % 4 != 0) {
        if (end == argv.len - 0 and (end - 2) % 4 == 1 and eql(try it.str(argv[end - 1]), "finally"))
            return it.fail("wrong # args to finally clause: must be \"... finally script\"", .{});
        // The first clause with too few words names the error.
        var k: usize = 2;
        while (k + 4 <= end) k += 4;
        if (k < end) {
            const kind = try it.str(argv[k]);
            if (eql(kind, "on")) return it.fail("wrong # args to on clause: must be \"... on code variableList script\"", .{});
            if (eql(kind, "trap")) return it.fail("wrong # args to trap clause: must be \"... trap pattern variableList script\"", .{});
        }
        return it.wrongArgs(usage);
    }
    // Check the handlers before the body runs. A `trap` or an `on
    // error` handler catches an error, for the debugger.
    var catches = false;
    var h: usize = 2;
    while (h < end) : (h += 4) {
        const kind = try it.str(argv[h]);
        if (eql(kind, "on")) {
            catches = catches or (try tryCode(it, argv[h + 1])) == 1;
        } else if (eql(kind, "trap")) {
            catches = true;
            _ = it.list(argv[h + 1]) catch return it.fail("bad prefix '{s}': must be a list", .{try it.str(argv[h + 1])});
        } else return it.fail("bad handler \"{s}\": must be finally, on, or trap", .{kind});
        if ((try it.list(argv[h + 2])).len > 2) return it.fail("wrong # args to {s} clause: must be \"... {s} {s} variableList script\"", .{ kind, kind, if (eql(kind, "on")) "code" else "pattern" });
    }
    if (end > 2 and eql(try it.str(argv[end - 1]), "-")) return it.fail("last non-finally clause must not have a body of \"-\"", .{});

    const counted = catches and enterCatch(it);
    const first = runCaughtBody(it, it.scriptOf(argv, 1, cmd), argv, null);
    leaveCatch(it, counted);
    var out = try first;
    h = 2;
    while (h < end) : (h += 4) {
        const kind = try it.str(argv[h]);
        var hit = false;
        if (eql(kind, "on")) {
            hit = (try tryCode(it, argv[h + 1])) == out.code;
        } else if (out.code == 1) {
            const pat = try it.list(argv[h + 1]);
            const code = it.list(out.error_code) catch &[_]Value{};
            hit = pat.len <= code.len;
            if (hit) for (pat, code[0..pat.len]) |x, y| {
                if (!eql(try it.str(x), try it.str(y))) hit = false;
            };
        }
        if (!hit) continue;
        const vars = try it.list(argv[h + 2]);
        const opts = try out.options(it);
        // A body of "-" uses the body of the next handler.
        var body = h + 3;
        while (eql(try it.str(argv[body]), "-")) body += 4;
        const res = out.res;
        out = blk: {
            if (vars.len >= 1) it.setVar(try it.str(vars[0]), res) catch |e| break :blk try runCaught(it, e);
            if (vars.len == 2) it.setVar(try it.str(vars[1]), opts) catch |e| break :blk try runCaught(it, e);
            var next = try runCaught(it, it.scriptOf(argv, body, cmd));
            if (next.code == 1) next.during = opts;
            break :blk next;
        };
        break;
    }
    if (finally) |f| {
        var fin = try runCaught(it, it.scriptOf(argv, f, cmd));
        if (fin.code != 0) {
            if (fin.code == 1) fin.during = try out.options(it);
            out = fin;
        }
    }
    return out.raise(it);
}

fn tryCode(it: *Interp, v: Value) Error!i64 {
    const s = try it.str(v);
    if (std.meta.stringToEnum(interp.ReturnCode, s)) |c| return @backingInt(c);
    if (v.asInt()) |n| return n;
    return it.fail("bad completion code \"{s}\": must be ok, error, return, break, continue, or an integer", .{s});
}

fn cmdExpr(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len == 2) return expr.numberForm(it, try expr.eval(it, try it.exprOf(argv, 1, cmd)));
    if (argv.len < 2) return it.wrongArgs("expr arg ?arg ...?");
    var out: std.ArrayList(u8) = .empty;
    for (argv[1..], 0..) |v, i| {
        if (i > 0) try out.append(it.alloc(), ' ');
        try out.appendSlice(it.alloc(), try it.str(v));
    }
    return expr.numberForm(it, try expr.eval(it, try expr.compile(it, out.items)));
}

fn cmdEval(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("eval arg ?arg ...?");
    // A list value has its words already, as in Tcl: no text, no parse.
    if (argv.len == 2 and argv[1] == .list and it.nest != 0) return it.evalWords(argv[1].list.items());
    if (argv.len == 2) return it.evalBody(try it.scriptOf(argv, 1, cmd), argv, &.{});
    if (it.nest != 0) if (try joinWords(it, argv[1..])) |words| return it.evalWords(words);
    return it.evalBody(try it.scriptOfValue(.{ .str = try concat(it, argv[1..]) }, null), argv, &.{});
}

fn cmdSubst(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("subst ?-nobackslashes? ?-nocommands? ?-novariables? string");
    // A substituted command can call `subst`, so each call is one level.
    try it.checkNative();
    if (it.nest >= it.max_nest) return it.fail("too many nested evaluations (infinite loop?)", .{});
    it.nest += 1;
    defer it.nest -= 1;
    const a = it.alloc();
    var do_bs = true;
    var do_cmd = true;
    var do_var = true;
    for (argv[1 .. argv.len - 1]) |v| {
        const o = try it.str(v);
        const names = [_][]const u8{ "-nobackslashes", "-nocommands", "-novariables" };
        var hit: ?usize = null;
        var count: usize = 0;
        for (names, 0..) |n, k| {
            if (o.len > 0 and std.mem.startsWith(u8, n, o)) {
                hit = k;
                count += 1;
            }
        }
        if (count != 1) return it.failCode("TCL LOOKUP INDEX option", "{s} option \"{s}\": must be -nobackslashes, -nocommands, or -novariables", .{ if (count > 1) "ambiguous" else "bad", o });
        switch (hit.?) {
            0 => do_bs = false,
            1 => do_cmd = false,
            else => do_var = false,
        }
    }
    const s = try it.str(argv[argv.len - 1]);
    var out: std.ArrayList(u8) = .empty;
    const flags: u64 = @as(u64, @intFromBool(do_bs)) | @as(u64, @intFromBool(do_cmd)) << 1 | @as(u64, @intFromBool(do_var)) << 2;
    if (s.len > 0) if (try it.subst_cache.find(it, s, flags, substParts)) |parts| {
        for (parts) |*part| switch (part.*) {
            .lit => |b| try out.appendSlice(a, b),
            .variable => |*ref| {
                const v = it.readRef(ref) catch |e| switch (substCode(it, e)) {
                    .stop => return .{ .str = out.items },
                    .skip => continue,
                    .use => it.result,
                    .fail => return e,
                };
                try out.appendSlice(a, try it.str(v));
            },
            .script => |sc| {
                var res: Value = Value.empty;
                var skip = false;
                for (sc.cmds) |*one| {
                    res = it.evalCmd(one) catch |e| switch (substCode(it, e)) {
                        .stop => return .{ .str = out.items },
                        .skip => {
                            skip = true;
                            break;
                        },
                        .use => {
                            res = it.result;
                            break;
                        },
                        .fail => return e,
                    };
                }
                if (!skip) try out.appendSlice(a, try it.str(res));
            },
        };
        return .{ .str = out.items };
    };
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and do_bs) {
            i = try value.backslash(a, s, i, &out);
        } else if (c == '$' and do_var) {
            var q: interp.Parser = .{ .a = a, .src = s, .pos = i };
            const r = q.parseVar() catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TclError => return it.fail("{s}", .{q.message}),
            };
            if (r) |ref| {
                i = q.pos;
                const v = it.readRef(&ref) catch |e| switch (substCode(it, e)) {
                    .stop => return .{ .str = out.items },
                    .skip => continue,
                    .use => it.result,
                    .fail => return e,
                };
                try out.appendSlice(a, try it.str(v));
            } else {
                try out.append(a, '$');
                i += 1;
            }
        } else if (c == '[' and do_cmd) {
            var q: interp.Parser = .{ .a = a, .src = s, .pos = i + 1 };
            var bad = false;
            const cmd_list: []interp.Cmd = if (q.parseScript(true)) |sc| sc.cmds else |e| blk: {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                bad = true;
                // A command that the end of the text cut off does not run.
                var done = q.partial;
                if (done.len > 0) {
                    const last = done[done.len - 1].text;
                    if (@intFromPtr(last.ptr) + last.len >= @intFromPtr(s.ptr) + s.len) done = done[0 .. done.len - 1];
                }
                break :blk done;
            };
            var res: Value = Value.empty;
            var skip = false;
            for (cmd_list) |*one| {
                res = it.evalCmd(one) catch |e| switch (substCode(it, e)) {
                    .stop => return .{ .str = out.items },
                    .skip => {
                        skip = true;
                        break;
                    },
                    .use => {
                        res = it.result;
                        break;
                    },
                    .fail => return e,
                };
            }
            if (bad and !skip) return it.fail("{s}", .{q.message});
            if (bad) return .{ .str = out.items };
            i = q.pos;
            if (!skip) try out.appendSlice(a, try it.str(res));
        } else {
            try out.append(a, c);
            i += 1;
        }
    }
    return .{ .str = out.items };
}

/// The parts of the text `s` of `subst` with the options `flags` (bit 0
/// backslashes, bit 1 commands, bit 2 variables), for the parse cache.
/// A text with a syntax error gets null: it runs on the slow path of
/// `cmdSubst`, which runs the parts before the error. The parse charges
/// no compute units, so a hit and a miss count the same.
fn substParts(it: *Interp, s: []const u8, flags: u64) Error!?[]const interp.Part {
    const a = it.alloc();
    var parts: std.ArrayList(interp.Part) = .empty;
    var lit: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and flags & 1 != 0) {
            i = try value.backslash(a, s, i, &lit);
            continue;
        }
        if (c == '$' and flags & 4 != 0) {
            var q: interp.Parser = .{ .a = a, .src = s, .pos = i };
            const r = q.parseVar() catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TclError => return null,
            };
            if (r) |ref| {
                i = q.pos;
                try flushLit(a, &parts, &lit);
                try parts.append(a, .{ .variable = ref });
                continue;
            }
        } else if (c == '[' and flags & 2 != 0) {
            var q: interp.Parser = .{ .a = a, .src = s, .pos = i + 1 };
            const sc = q.parseScript(true) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TclError => return null,
            };
            i = q.pos;
            try flushLit(a, &parts, &lit);
            try parts.append(a, .{ .script = sc });
            continue;
        }
        try lit.append(a, c);
        i += 1;
    }
    try flushLit(a, &parts, &lit);
    return parts.items;
}

fn flushLit(a: std.mem.Allocator, parts: *std.ArrayList(interp.Part), lit: *std.ArrayList(u8)) !void {
    if (lit.items.len == 0) return;
    try parts.append(a, .{ .lit = lit.items });
    lit.* = .empty;
}

const SubstAction = enum { stop, skip, use, fail };

/// What `subst` does with the code of a substitution.
fn substCode(it: *Interp, e: Error) SubstAction {
    switch (e) {
        error.TclBreak => return .stop,
        error.TclContinue => return .skip,
        error.TclReturn => {
            it.ret_code = .ok;
            it.ret_level = 1;
            it.ret_opts = &.{};
            return .use;
        },
        error.TclCustom => return .use,
        else => return .fail,
    }
}

// ---- Lists ----

fn cmdList(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    return value.newList(it.alloc(), argv[1..]);
}

/// An index word: "3", "end", "end-1", "2+1". The result may lie
/// outside the list.
pub fn index(it: *Interp, v: Value, len: usize) Error!i64 {
    if (v == .int) return @as(i32, @truncate(v.int));
    const s = try it.str(v);
    const bad = "bad index \"{s}\": must be integer?[+-]integer? or end?[+-]integer?";
    const t = value.trimSpace(s);
    var base: i64 = undefined;
    var rest: []const u8 = undefined;
    var word: usize = 0;
    while (word < t.len and word < 3 and t[word] == "end"[word]) word += 1;
    if (word > 0 and (word == t.len or t[word] == '+' or t[word] == '-')) {
        base = @as(i64, @intCast(len)) - 1;
        rest = t[word..];
        if (rest.len == 0) return base;
        if (rest[0] != '+' and rest[0] != '-') return it.fail(bad, .{s});
    } else {
        // The first sign after the first character starts the offset.
        var i: usize = 1;
        while (i < t.len and t[i] != '+' and t[i] != '-') i += 1;
        if (t.len == 0) return it.fail(bad, .{s});
        base = indexInt(t[0..@min(i, t.len)]) orelse return badIndex(it, s, t[0..@min(i, t.len)]);
        rest = t[@min(i, t.len)..];
        if (rest.len == 0) return base;
    }
    const off = indexInt(rest[1..]) orelse return badIndex(it, s, rest[1..]);
    return if (rest[0] == '+') base +% off else base -% off;
}

/// Checks the indices of `-index` of lsearch and lsort, as Tcl does when
/// it parses the option: an index before the start (such as -1) or after
/// the end (such as end+1) is an error for any list. Two lengths give
/// the form of the index: the value of an index from the end changes
/// with the length.
pub fn checkSelect(it: *Interp, ixs: []const Value) Error!void {
    for (ixs) |ix| {
        const a = try index(it, ix, 0);
        const b = try index(it, ix, 1 << 20);
        if ((a == b and a < 0) or (a != b and a >= 0)) {
            return it.fail("index \"{s}\" cannot select an element from any list", .{try it.str(ix)});
        }
    }
}

/// An integer of an index. Tcl 8.6 keeps the low 32 bits of an index.
fn indexInt(t: []const u8) ?i64 {
    if (t.len == 0) return null;
    const n = value.parseInt(t) orelse return null;
    return @as(i32, @truncate(n));
}

fn badIndex(it: *Interp, s: []const u8, part: []const u8) Error {
    var t = part;
    if (t.len > 0 and (t[0] == '+' or t[0] == '-')) t = t[1..];
    var octal = t.len > 1 and t[0] == '0';
    if (octal) {
        var d = t[1..];
        if (d.len > 0 and (d[0] == 'o' or d[0] == 'O')) d = d[1..];
        var high = false;
        for (d) |c| {
            if (c < '0' or c > '9') octal = false;
            if (c >= '8') high = true;
        }
        octal = octal and high;
    }
    if (octal) return it.fail("bad index \"{s}\": must be integer?[+-]integer? or end?[+-]integer? (looks like invalid octal number)", .{s});
    return it.fail("bad index \"{s}\": must be integer?[+-]integer? or end?[+-]integer?", .{s});
}

pub fn cmdLindex(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("lindex list ?index ...?");
    var cur = argv[1];
    var idxs = argv[2..];
    if (idxs.len == 1 and idxs[0] != .int) idxs = try it.list(idxs[0]);
    for (idxs) |iv| {
        const items = try it.list(cur);
        const i = try index(it, iv, items.len);
        if (i < 0 or i >= items.len) return Value.empty;
        cur = items[@intCast(i)];
    }
    return cur;
}

fn cmdLlength(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("llength list");
    return .{ .int = @intCast((try it.list(argv[1])).len) };
}

pub fn cmdLappend(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("lappend varName ?value ...?");
    const name = try it.str(argv[1]);
    const old = try it.getVarOpt(name);
    if (argv.len == 2) {
        // With no values, as in Tcl: the value stays as it is, after a
        // check that it is a list. A missing variable is set to "".
        const v = old orelse {
            try it.setVar(name, Value.empty);
            return Value.empty;
        };
        _ = v.toList(it.alloc()) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadList => return it.listError(v),
        };
        return v;
    }
    const cur = old orelse Value.empty;
    var l = cur.toList(it.alloc()) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadList => return it.listError(cur),
    };
    for (argv[2..]) |v| l = try l.append(it.alloc(), v);
    const out: Value = .{ .list = l };
    try it.setVar(name, out);
    return out;
}

fn clampRange(first: i64, last: i64, len: usize) ?[2]usize {
    const f: i64 = @max(first, 0);
    const l: i64 = @min(last, @as(i64, @intCast(len)) - 1);
    if (f > l) return null;
    return .{ @intCast(f), @intCast(l) };
}

fn cmdLrange(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 4) return it.wrongArgs("lrange list first last");
    const items = try it.list(argv[1]);
    const r = clampRange(try index(it, argv[2], items.len), try index(it, argv[3], items.len), items.len) orelse return Value.empty;
    return value.newList(it.alloc(), items[r[0] .. r[1] + 1]);
}

fn cmdLreverse(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("lreverse list");
    const out = try it.alloc().dupe(Value, try it.list(argv[1]));
    std.mem.reverse(Value, out);
    return value.wrapList(it.alloc(), out);
}

fn cmdLinsert(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 3) return it.wrongArgs("linsert list index ?element ...?");
    const items = try it.list(argv[1]);
    var i = try index(it, argv[2], items.len);
    if (std.mem.startsWith(u8, try it.str(argv[2]), "end")) i += 1;
    const at: usize = @intCast(std.math.clamp(i, 0, @as(i64, @intCast(items.len))));
    const out = try std.mem.concat(it.alloc(), Value, &.{ items[0..at], argv[3..], items[at..] });
    return value.wrapList(it.alloc(), out);
}

pub fn cmdLreplace(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 4) return it.wrongArgs("lreplace list first last ?element ...?");
    const items = try it.list(argv[1]);
    const n: i64 = @intCast(items.len);
    const first: usize = @intCast(std.math.clamp(try index(it, argv[2], items.len), 0, n));
    const last = try index(it, argv[3], items.len);
    const after: usize = @intCast(std.math.clamp(last + 1, @as(i64, @intCast(first)), n));
    const out = try std.mem.concat(it.alloc(), Value, &.{ items[0..first], argv[4..], items[after..] });
    return value.wrapList(it.alloc(), out);
}

fn cmdLassign(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("lassign list ?varName ...?");
    const items = try it.list(argv[1]);
    for (argv[2..], 0..) |name, i| {
        try it.setVar(try it.str(name), if (i < items.len) items[i] else Value.empty);
    }
    const used = @min(items.len, argv.len - 2);
    return value.newList(it.alloc(), items[used..]);
}

fn cmdLrepeat(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("lrepeat count ?value ...?");
    const n = try it.int(argv[1]);
    if (n < 0) return it.fail("bad count \"{d}\": must be integer >= 0", .{n});
    const per = argv.len - 2;
    const total = std.math.mul(usize, @intCast(n), per) catch return it.fail("max length of a Tcl list exceeded", .{});
    if (total > 1 << 24) return it.fail("max length of a Tcl list exceeded", .{});
    try chargeEntries(it, total);
    const out = try it.alloc().alloc(Value, total);
    for (out, 0..) |*o, i| o.* = argv[2 + i % per];
    return value.wrapList(it.alloc(), out);
}

fn cmdLsearch(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const Match = enum { exact, glob, regexp, sorted };
    const Kind = enum { ascii, dictionary, integer, real };
    var match: Match = .glob;
    var kind: Kind = .ascii;
    var all = false;
    var inl = false;
    var not = false;
    var nocase = false;
    var bisect = false;
    var desc = false;
    var subindices = false;
    var start_v: ?Value = null;
    var path: ?[]const Value = null;
    // The groups of -stride (Tcl 9.1, TIP 351). A stride of 1 is no group.
    var stride: usize = 1;
    if (argv.len < 3) return it.wrongArgs("lsearch ?-option value ...? list pattern");
    const last = argv.len - 2;
    var oi: usize = 1;
    while (oi < last) : (oi += 1) {
        const s = try it.str(argv[oi]);
        if (eql(s, "-exact")) {
            match = .exact;
        } else if (eql(s, "-glob")) {
            match = .glob;
        } else if (eql(s, "-regexp")) {
            match = .regexp;
        } else if (eql(s, "-sorted")) {
            match = .sorted;
        } else if (eql(s, "-bisect")) {
            match = .sorted;
            bisect = true;
        } else if (eql(s, "-integer")) {
            kind = .integer;
        } else if (eql(s, "-real")) {
            kind = .real;
        } else if (eql(s, "-ascii")) {
            kind = .ascii;
        } else if (eql(s, "-dictionary")) {
            kind = .dictionary;
        } else if (eql(s, "-nocase")) {
            nocase = true;
        } else if (eql(s, "-increasing")) {
            desc = false;
        } else if (eql(s, "-decreasing")) {
            desc = true;
        } else if (eql(s, "-all")) {
            all = true;
        } else if (eql(s, "-inline")) {
            inl = true;
        } else if (eql(s, "-not")) {
            not = true;
        } else if (eql(s, "-subindices")) {
            subindices = true;
        } else if (eql(s, "-start")) {
            if (oi + 1 >= last) return it.fail("missing starting index", .{});
            oi += 1;
            start_v = argv[oi];
        } else if (eql(s, "-index")) {
            if (oi + 1 >= last) return it.fail("\"-index\" option must be followed by list index", .{});
            oi += 1;
            path = try it.list(argv[oi]);
            try checkSelect(it, path.?);
        } else if (it.tcl9() and eql(s, "-stride")) {
            if (oi + 1 >= last) return it.fail("\"-stride\" option must be followed by stride length", .{});
            oi += 1;
            const n = try it.int(argv[oi]);
            if (n < 1) return it.fail("stride length must be at least 1", .{});
            stride = std.math.cast(usize, n) orelse return it.fail("list size must be a multiple of the stride length", .{});
        } else if (it.tcl9()) {
            return it.fail("bad option \"{s}\": must be -all, -ascii, -bisect, -decreasing, -dictionary, -exact, -glob, -increasing, -index, -inline, -integer, -nocase, -not, -real, -regexp, -sorted, -start, -stride, or -subindices", .{s});
        } else return it.fail("bad option \"{s}\": must be -all, -ascii, -bisect, -decreasing, -dictionary, -exact, -glob, -increasing, -index, -inline, -integer, -nocase, -not, -real, -regexp, -sorted, -start, or -subindices", .{s});
    }
    if (subindices and path == null) return it.fail("-subindices cannot be used without -index option", .{});
    if (bisect and (all or not)) return it.fail("-bisect is not compatible with -all or -not", .{});
    const items = try it.list(argv[argv.len - 2]);
    if (items.len % stride != 0) return it.fail("list size must be a multiple of the stride length", .{});
    // With groups, the first index of -index picks the element of the
    // group, and the rest of the indexes apply to that element.
    var lead: usize = 0;
    if (stride > 1) if (path) |p| {
        const n = try index(it, p[0], stride);
        if (n < 0) return it.fail("index \"{s}\" out of range", .{try it.str(p[0])});
        if (n >= stride) return it.fail("when used with \"-stride\", the leading \"-index\" value must be within the group", .{});
        lead = @intCast(n);
        path = p[1..];
    };
    const pat_v = argv[argv.len - 1];
    const pat = try it.str(pat_v);
    const typed = match == .exact or match == .sorted;
    const want_i: i64 = if (typed and kind == .integer) try it.int(pat_v) else 0;
    const want_f: f64 = if (typed and kind == .real) try realOf(it, pat_v) else 0;
    var first: usize = 0;
    if (start_v) |sv| {
        const n = try index(it, sv, items.len);
        first = if (n < 0) 0 else @intCast(n);
        // A start in a group starts at the group.
        first -= first % stride;
    }
    // The first exact match needs only equality. A string item of
    // another length fails with one compare.
    if (match == .exact and kind == .ascii and !nocase and path == null and !all and !not and stride == 1) {
        for (items[@min(first, items.len)..], @min(first, items.len)..) |key, k| {
            const text = if (key == .str) key.str else try it.str(key);
            if (text.len == pat.len and std.mem.eql(u8, text, pat)) return if (inl) key else .{ .int = @intCast(k) };
        }
        return if (inl) Value.empty else .{ .int = -1 };
    }
    var out: std.ArrayList(Value) = .empty;
    var best: i64 = -1;
    var i = first;
    while (i < items.len) : (i += stride) {
        var key = items[i + lead];
        if (path) |p| for (p) |ix| {
            const sub = try it.list(key);
            const n = try index(it, ix, sub.len);
            if (n < 0 or n >= sub.len) return it.fail("element {d} missing from sublist \"{s}\"", .{ n, try it.str(key) });
            key = sub[@intCast(n)];
        };
        var order: std.math.Order = .eq;
        const hit = switch (match) {
            .glob => try globSteps(it, pat, try it.str(key), nocase),
            .regexp => if (comptime features.on("regexp")) try regex.matches(it, pat, try it.str(key), nocase) else return features.fail(it, "regexp", "lsearch -regexp"),
            .exact, .sorted => blk: {
                order = switch (kind) {
                    .integer => std.math.order(try it.int(key), want_i),
                    .real => std.math.order(try realOf(it, key), want_f),
                    .dictionary => more.dictOrder(try it.str(key), pat),
                    .ascii => if (nocase) std.ascii.orderIgnoreCase(try it.str(key), pat) else std.mem.order(u8, try it.str(key), pat),
                };
                break :blk order == .eq;
            },
        };
        if (bisect) {
            const o = if (desc) order.invert() else order;
            if (o != .gt) best = @intCast(i);
            continue;
        }
        if (hit == not) continue;
        var v: Value = .{ .int = @intCast(i) };
        if (inl) {
            if (!subindices and stride > 1) {
                if (!all) return value.wrapList(it.alloc(), try it.alloc().dupe(Value, items[i .. i + stride]));
                try out.appendSlice(it.alloc(), items[i .. i + stride]);
                continue;
            }
            v = if (subindices) key else items[i];
        } else if (subindices) {
            v = .{ .int = @intCast(i + lead) };
            if (path.?.len > 0) {
                const full = try it.alloc().alloc(Value, path.?.len + 1);
                full[0] = v;
                @memcpy(full[1..], path.?);
                v = try value.wrapList(it.alloc(), full);
            }
        }
        if (!all) return v;
        try out.append(it.alloc(), v);
    }
    if (bisect) {
        if (!inl) return .{ .int = best };
        if (best < 0) return Value.empty;
        const b: usize = @intCast(best);
        return if (stride > 1) value.wrapList(it.alloc(), try it.alloc().dupe(Value, items[b .. b + stride])) else items[b];
    }
    if (all) return value.wrapList(it.alloc(), out.items);
    return if (inl) Value.empty else .{ .int = -1 };
}

fn realOf(it: *Interp, v: Value) Error!f64 {
    const n = v.asNumber() orelse return it.fail("expected floating-point number but got \"{s}\"", .{try it.str(v)});
    return if (n == .int) @floatFromInt(n.int) else n.double;
}

fn cmdJoin(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2 and argv.len != 3) return it.wrongArgs("join list ?joinString?");
    const sep = if (argv.len == 3) try it.str(argv[2]) else " ";
    var out: std.ArrayList(u8) = .empty;
    for (try it.list(argv[1]), 0..) |v, i| {
        if (i > 0) try out.appendSlice(it.alloc(), sep);
        try out.appendSlice(it.alloc(), try it.str(v));
    }
    return .{ .str = out.items };
}

/// True when `v` is the word -grapheme. A form with the word has one
/// more argument than the plain form, so plain Tcl gives it an error.
fn isGrapheme(it: *Interp, v: Value) Error!bool {
    return std.mem.eql(u8, try it.str(v), "-grapheme");
}

/// The -grapheme forms of src/text/cmd.zig. A build with no module
/// ztcl::text has none of its code or tables, and the forms fail.
const text_cmd = if (@import("build_options").mod_text) @import("text/cmd.zig") else struct {
    fn no(it: *Interp) Error!Value {
        return it.fail("-grapheme needs the module ztcl::text in the build", .{});
    }
    pub fn length(it: *Interp, _: []const u8) Error!Value {
        return no(it);
    }
    pub fn index(it: *Interp, _: []const u8, _: Value) Error!Value {
        return no(it);
    }
    pub fn range(it: *Interp, _: []const u8, _: Value, _: Value) Error!Value {
        return no(it);
    }
    pub fn reverse(it: *Interp, _: []const u8) Error!Value {
        return no(it);
    }
    pub fn split(it: *Interp, _: []const u8, _: []const u8) Error!Value {
        return no(it);
    }
};

fn cmdSplit(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len == 4 and try isGrapheme(it, argv[3])) return text_cmd.split(it, try it.str(argv[1]), try it.str(argv[2]));
    if (argv.len != 2 and argv.len != 3) return it.wrongArgs("split string ?splitChars?");
    const s = try it.str(argv[1]);
    const seps = if (argv.len == 3) try it.str(argv[2]) else " \t\n\r";
    var out: std.ArrayList(Value) = .empty;
    const a = it.alloc();
    if (s.len == 0) return Value.empty;
    if (seps.len == 0) {
        // Each character is one element.
        var i: usize = 0;
        while (i < s.len) {
            const n = ucd.next(s, i).len;
            try out.append(a, .{ .str = s[i .. i + n] });
            i += n;
        }
    } else if (!isAscii(seps)) {
        // A split character above ASCII: compare whole characters.
        var start: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const d = ucd.next(s, i);
            var j: usize = 0;
            const hit = while (j < seps.len) {
                const e = ucd.next(seps, j);
                if (e.len == d.len and std.mem.eql(u8, seps[j .. j + e.len], s[i .. i + d.len])) break true;
                j += e.len;
            } else false;
            if (hit) {
                try out.append(a, .{ .str = s[start..i] });
                start = i + d.len;
            }
            i += d.len;
        }
        try out.append(a, .{ .str = s[start..] });
    } else {
        // A bitmap of the split bytes makes the test of each byte one
        // lookup, so the work is linear in both lengths.
        var set = std.StaticBitSet(256).empty;
        for (seps) |c| set.set(c);
        var start: usize = 0;
        for (s, 0..) |c, i| {
            if (set.isSet(c)) {
                try out.append(a, .{ .str = s[start..i] });
                start = i + 1;
            }
        }
        try out.append(a, .{ .str = s[start..] });
    }
    return value.wrapList(a, out.items);
}

fn isAscii(s: []const u8) bool {
    for (s) |c| if (c >= 0x80) return false;
    return true;
}

pub fn concat(it: *Interp, args: []const Value) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (args) |v| {
        const s = value.trimSpace(try it.str(v));
        if (s.len == 0) continue;
        if (out.items.len > 0) try out.append(it.alloc(), ' ');
        try out.appendSlice(it.alloc(), s);
    }
    return out.items;
}

fn cmdConcat(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    return .{ .str = try concat(it, argv[1..]) };
}

// ---- Strings ----

/// Matches a glob pattern: `*`, `?`, `[a-z]`, and `\x`.
/// The glob match of `string match`. The time is at most the length of
/// the pattern times the length of the string: after a mismatch, the
/// match goes back only to the last `*`.
pub fn globMatch(pat: []const u8, s: []const u8, nocase: bool) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star_p: ?usize = null;
    var star_i: usize = 0;
    while (true) {
        if (p < pat.len and pat[p] == '*') {
            while (p < pat.len and pat[p] == '*') p += 1;
            if (p == pat.len) return true;
            star_p = p;
            star_i = i;
            continue;
        }
        if (i >= s.len) return p == pat.len;
        const d = ucd.next(s, i);
        if (p < pat.len) {
            if (globOne(pat, p, d.cp, nocase)) |after| {
                p = after;
                i += d.len;
                continue;
            }
        }
        const sp = star_p orelse return false;
        star_i += ucd.next(s, star_i).len;
        i = star_i;
        p = sp;
    }
}

/// Matches one character with the pattern element at `p_in`. Returns
/// the position after the element, or null.
fn globOne(pat: []const u8, p_in: usize, c_in: u21, nocase: bool) ?usize {
    var p = p_in;
    const c = pat[p];
    const ch = if (nocase) ucd.toLower(c_in) else c_in;
    if (c == '?') return p + 1 + (ucd.next(pat, p).len - 1);
    if (c == '[') {
        p += 1;
        var hit = false;
        while (p < pat.len and pat[p] != ']') {
            if (pat[p] == '\\' and p + 1 < pat.len) p += 1;
            const first = ucd.next(pat, p);
            var lo = first.cp;
            var hi = lo;
            p += first.len;
            if (p + 1 < pat.len and pat[p] == '-' and pat[p + 1] != ']') {
                p += 1;
                if (pat[p] == '\\' and p + 1 < pat.len) p += 1;
                const second = ucd.next(pat, p);
                hi = second.cp;
                p += second.len;
            }
            if (nocase) {
                lo = ucd.toLower(lo);
                hi = ucd.toLower(hi);
            }
            if (ch >= @min(lo, hi) and ch <= @max(lo, hi)) hit = true;
        }
        if (p < pat.len) p += 1;
        return if (hit) p else null;
    }
    if (c == '\\') {
        // A backslash at the end of the pattern matches no character.
        if (p + 1 >= pat.len) return null;
        p += 1;
    }
    const lit = ucd.next(pat, p);
    const want = if (nocase) ucd.toLower(lit.cp) else lit.cp;
    return if (want == ch) p + lit.len else null;
}

/// The bytes of work of one compute unit. A command whose work grows
/// with the size of its input or of its result uses one compute unit for
/// each `bytes_per_unit` bytes of work.
pub const bytes_per_unit = 4096;
/// The bytes of work of one entry of a table, one element of a list, or
/// one compare of a sort.
pub const entry_units = 64;

/// Uses one compute unit for each `bytes_per_unit` bytes of work. The caller
/// charges the work before it does the work, when it knows the size.
pub fn chargeWork(it: *Interp, units: usize) Error!void {
    const cost = units / bytes_per_unit;
    if (cost > it.compute_limit) {
        it.compute_limit = 0;
        return it.fail("compute limit reached", .{});
    }
    it.compute_limit -= cost;
}

/// Uses the steps of a scan or a build of `n` entries.
pub fn chargeEntries(it: *Interp, n: usize) Error!void {
    return chargeWork(it, n *| entry_units);
}

/// Counts the units of work of a loop, and uses one step for each
/// `bytes_per_unit` units. The rest stays for the next call of `add`.
pub const Meter = struct {
    units: usize = 0,

    pub inline fn add(m: *Meter, it: *Interp, n: usize) Error!void {
        m.units +|= n;
        if (m.units >= bytes_per_unit) {
            try chargeWork(it, m.units);
            m.units %= bytes_per_unit;
        }
    }
};

/// The first position of `needle` in `hay` at or after `start`, or null.
/// The search is Boyer-Moore-Horspool. Each compare of the needle uses
/// `needle.len` units of the compute limit, so a text that makes each
/// position compare the full needle uses steps for that work.
fn findFirst(it: *Interp, hay: []const u8, start: usize, needle: []const u8) Error!?usize {
    if (needle.len <= 4 or hay.len < 52) return std.mem.indexOfPos(u8, hay, start, needle);
    if (needle.len > hay.len) return null;
    var skip: [256]usize = @splat(needle.len);
    for (needle[0 .. needle.len - 1], 0..) |c, k| skip[c] = needle.len - 1 - k;
    var meter: Meter = .{};
    var i = start;
    while (i <= hay.len - needle.len) {
        try meter.add(it, needle.len);
        if (eql(hay[i..][0..needle.len], needle)) return i;
        i += skip[hay[i + needle.len - 1]];
    }
    return null;
}

/// The last position of `needle` in `hay`, or null. It is the reverse
/// form of `findFirst`, with the same use of steps.
fn findLast(it: *Interp, hay: []const u8, needle: []const u8) Error!?usize {
    if (needle.len <= 4 or hay.len < 52) return std.mem.lastIndexOf(u8, hay, needle);
    if (needle.len > hay.len) return null;
    var skip: [256]usize = @splat(needle.len);
    var k = needle.len - 1;
    while (k > 0) : (k -= 1) skip[needle[k]] = k;
    var meter: Meter = .{};
    var i = hay.len - needle.len;
    while (true) {
        try meter.add(it, needle.len);
        if (eql(hay[i..][0..needle.len], needle)) return i;
        const back = skip[hay[i]];
        if (back > i) return null;
        i -= back;
    }
}

/// A glob match that uses the compute limit: one step for each 4096 units of
/// the pattern length times the string length.
pub fn globSteps(it: *Interp, pat: []const u8, s: []const u8, nocase: bool) Error!bool {
    try chargeWork(it, pat.len *| s.len);
    return globMatch(pat, s, nocase);
}

/// The count of characters of a UTF-8 string: the bytes that do not
/// continue a character.
pub fn charCount(s: []const u8) usize {
    // Eight bytes at a time: a continuation byte has bit 7 set and bit 6
    // clear, so `w & ~(w << 1)` keeps bit 7 of each one.
    var cont: usize = 0;
    var i: usize = 0;
    // A target with SIMD counts the bytes of one vector at a time. A
    // block of at most 255 vectors keeps each lane count in a byte.
    if (comptime std.simd.suggestVectorLength(u8)) |n| {
        const V = @Vector(n, u8);
        while (i + n <= s.len) {
            var acc: V = @splat(0);
            var k: usize = 0;
            while (k < 255 and i + n <= s.len) : ({
                k += 1;
                i += n;
            }) {
                const v: V = s[i..][0..n].*;
                acc += @intFromBool(v & @as(V, @splat(0xC0)) == @as(V, @splat(0x80)));
            }
            cont += @reduce(.Add, @as(@Vector(n, u16), acc));
        }
    }
    const high: u64 = 0x8080808080808080;
    while (i + 8 <= s.len) : (i += 8) {
        const w = std.mem.readInt(u64, s[i..][0..8], .little);
        cont += @popCount(w & ~(w << 1) & high);
    }
    while (i < s.len) : (i += 1) cont += @intFromBool(s[i] & 0xC0 == 0x80);
    return s.len - cont;
}

/// The count of characters of a string of a value. The count of a long
/// string in the heap goes in the cache of the heap, so a loop of
/// `string index` over one string counts it once.
pub fn charCountOf(it: *Interp, s: []const u8) usize {
    if (s.len < 256) return charCount(s);
    if (it.heap.cachedCount(s)) |n| return n;
    const n = charCount(s);
    it.heap.putCount(s, n);
    return n;
}

/// The byte offset of character `k` of a string with `n` characters.
pub fn byteOf(s: []const u8, n: usize, k: usize) usize {
    if (n == s.len) return @min(k, s.len);
    if (k >= n) return s.len;
    var seen: usize = 0;
    for (s, 0..) |c, i| {
        if (c & 0xC0 != 0x80) {
            if (seen == k) return i;
            seen += 1;
        }
    }
    return s.len;
}

/// The subcommand that the site `cmd` keeps for the command function
/// `self`, or null. A site whose second word is a literal keeps the enum
/// value of its subcommand in `Cmd.sub`, with the address of `self` in
/// `Cmd.sub_fn` (see `noteSub`). A hit needs the same function, the same
/// word count, and the value of the literal word in `argv[1]`. So a
/// rename or an alias finds the name again. The hint depends only on the
/// literal, on the function, and on the release of the interpreter of
/// the site, so it needs no epoch.
inline fn siteSub(comptime Sub: type, comptime self: interp.NativeFn, argv: []const Value, cmd: ?*Cmd) ?Sub {
    const c = cmd orelse return null;
    if (c.sub_fn != @intFromPtr(self) or !siteLit(c, argv)) return null;
    return @fromBackingInt(@as(@typeInfo(Sub).@"enum".tag_type, @intCast(c.sub)));
}

/// Keeps the subcommand `s` of `argv[1]` in the site `cmd`.
inline fn noteSub(comptime Sub: type, comptime self: interp.NativeFn, argv: []const Value, cmd: ?*Cmd, s: Sub) void {
    const c = cmd orelse return;
    if (!siteLit(c, argv)) return;
    c.sub_fn = @intFromPtr(self);
    c.sub = @backingInt(s);
}

/// True when `argv[1]` is the literal second word of the site `c`.
fn siteLit(c: *const Cmd, argv: []const Value) bool {
    if (c.has_expand or c.words.len != argv.len or argv.len < 2) return false;
    const lit = switch (c.words[1].kind) {
        .lit => |v| v,
        else => return false,
    };
    return lit == .str and argv[1] == .str and lit.str.ptr == argv[1].str.ptr and lit.str.len == argv[1].str.len;
}

pub fn cmdString(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("string subcommand ?arg ...?");
    const a = it.alloc();
    const sub = try it.str(argv[1]);
    const args = argv[2..];
    const Sub = enum { bytelength, length, index, insert, range, equal, compare, first, last, map, tolower, toupper, totitle, trim, trimleft, trimright, repeat, is, match, reverse, cat, replace, wordstart, wordend };
    const which = siteSub(Sub, &cmdString, argv, cmd) orelse blk: {
        const w = try @import("tcl9.zig").pick(it, Sub, sub, .{ .v8_6 = &.{.bytelength}, .v9_1 = &.{.insert} });
        noteSub(Sub, &cmdString, argv, cmd, w);
        break :blk w;
    };
    switch (which) {
        .insert => {
            if (args.len != 3) return it.wrongArgs("string insert string index insertString");
            const s = try it.str(args[0]);
            const n = charCountOf(it, s);
            var i = try index(it, args[1], n);
            if (std.mem.startsWith(u8, value.trimSpace(try it.str(args[1])), "end")) i += 1;
            const at: usize = @intCast(std.math.clamp(i, 0, @as(i64, @intCast(n))));
            const b = byteOf(s, n, at);
            return .{ .str = try std.mem.concat(a, u8, &.{ s[0..b], try it.str(args[2]), s[b..] }) };
        },
        .bytelength => {
            if (args.len != 1) return it.wrongArgs("string bytelength string");
            return .{ .int = @intCast((try it.str(args[0])).len) };
        },
        .length => {
            if (args.len == 2 and try isGrapheme(it, args[0])) return text_cmd.length(it, try it.str(args[1]));
            if (args.len != 1) return it.wrongArgs("string length string");
            return .{ .int = @intCast(charCountOf(it, try it.str(args[0]))) };
        },
        .index => {
            if (args.len == 3 and try isGrapheme(it, args[0])) return text_cmd.index(it, try it.str(args[1]), args[2]);
            if (args.len != 2) return it.wrongArgs("string index string charIndex");
            const s = try it.str(args[0]);
            const n = charCountOf(it, s);
            const i = try index(it, args[1], n);
            if (i < 0 or i >= n) return Value.empty;
            return .{ .str = s[byteOf(s, n, @intCast(i))..byteOf(s, n, @intCast(i + 1))] };
        },
        .range => {
            if (args.len == 4 and try isGrapheme(it, args[0])) return text_cmd.range(it, try it.str(args[1]), args[2], args[3]);
            if (args.len != 3) return it.wrongArgs("string range string first last");
            const s = try it.str(args[0]);
            const n = charCountOf(it, s);
            const r = clampRange(try index(it, args[1], n), try index(it, args[2], n), n) orelse return Value.empty;
            return .{ .str = s[byteOf(s, n, r[0])..byteOf(s, n, r[1] + 1)] };
        },
        .replace => {
            if (args.len != 3 and args.len != 4) return it.wrongArgs("string replace string first last ?string?");
            const s = try it.str(args[0]);
            const n = charCountOf(it, s);
            var first = try index(it, args[1], n);
            var last = try index(it, args[2], n);
            const count: i64 = @intCast(n);
            if (last < first or last < 0 or first >= count and count > 0) return args[0];
            if (first >= count and count == 0 and first > 0) return args[0];
            first = @max(first, 0);
            last = @min(last, count - 1);
            const mid = if (args.len == 4) try it.str(args[3]) else "";
            const head = byteOf(s, n, @intCast(first));
            const tail_at = if (last < first) head else byteOf(s, n, @intCast(last + 1));
            return .{ .str = try std.mem.concat(a, u8, &.{ s[0..head], mid, s[tail_at..] }) };
        },
        .equal, .compare => {
            const usage = if (which == .equal) "string equal ?-nocase? ?-length int? string1 string2" else "string compare ?-nocase? ?-length int? string1 string2";
            if (args.len < 2 or args.len > 5) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s}\"", .{usage});
            var nocase = false;
            var limit: ?usize = null;
            var i: usize = 0;
            while (i + 2 < args.len) : (i += 1) {
                const o = try it.str(args[i]);
                if (o.len >= 2 and std.mem.startsWith(u8, "-nocase", o)) {
                    nocase = true;
                } else if (o.len >= 2 and std.mem.startsWith(u8, "-length", o)) {
                    if (i + 3 >= args.len) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s}\"", .{usage});
                    i += 1;
                    const big = try expr.intArg(it, args[i]);
                    if (big != .int) return it.fail("integer value too large to represent", .{});
                    if (big.int >= 0) limit = @intCast(big.int);
                } else return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -nocase or -length", .{o});
            }
            const o = compareStrings(try it.str(args[args.len - 2]), try it.str(args[args.len - 1]), nocase, limit);
            if (which == .equal) return .{ .int = @intFromBool(o == .eq) };
            return .{ .int = switch (o) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            } };
        },
        .first, .last => {
            if (args.len != 2 and args.len != 3) {
                return if (which == .first) it.wrongArgs("string first needleString haystackString ?startIndex?") else it.wrongArgs("string last needleString haystackString ?startIndex?");
            }
            const needle = try it.str(args[0]);
            const hay = try it.str(args[1]);
            if (needle.len == 0) return .{ .int = -1 };
            // The indexes count characters; the search uses bytes.
            const n = charCountOf(it, hay);
            const count: i64 = @intCast(n);
            if (which == .first) {
                var start: usize = 0;
                if (args.len == 3) {
                    const at = try index(it, args[2], n);
                    if (at >= count) return .{ .int = -1 };
                    start = byteOf(hay, n, @intCast(@max(at, 0)));
                }
                const pos = try findFirst(it, hay, start, needle) orelse return .{ .int = -1 };
                return .{ .int = @intCast(charCount(hay[0..pos])) };
            }
            var end: usize = hay.len;
            if (args.len == 3) {
                const at = try index(it, args[2], n);
                if (at < 0) return .{ .int = -1 };
                end = byteOf(hay, n, @intCast(@min(at + 1, count)));
            }
            const pos = try findLast(it, hay[0..end], needle) orelse return .{ .int = -1 };
            return .{ .int = @intCast(charCount(hay[0..pos])) };
        },
        .map => {
            var nocase = false;
            if (args.len != 2 and args.len != 3) return it.wrongArgs("string map ?-nocase? charMap string");
            if (args.len == 3) {
                const o = try it.str(args[0]);
                if (o.len < 2 or !std.mem.startsWith(u8, "-nocase", o)) return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -nocase", .{o});
                nocase = true;
            }
            const pairs = try it.list(args[args.len - 2]);
            if (pairs.len % 2 != 0) return it.fail("char map list unbalanced", .{});
            const s = try it.str(args[args.len - 1]);
            const keys = try a.alloc([]const u8, pairs.len);
            for (pairs, keys) |p, *k| k.* = try it.str(p);
            // The first bytes of the keys. A byte that starts no key
            // goes to the output in a run with no compare.
            var starts: [256]bool = @splat(false);
            for (0..keys.len / 2) |k| {
                const key = keys[2 * k];
                if (key.len == 0) continue;
                starts[key[0]] = true;
                if (nocase) {
                    starts[std.ascii.toLower(key[0])] = true;
                    starts[std.ascii.toUpper(key[0])] = true;
                }
            }
            var out: std.ArrayList(u8) = .empty;
            // Each compare of a key uses its length in units of work.
            var meter: Meter = .{};
            var i: usize = 0;
            outer: while (i < s.len) {
                if (!starts[s[i]]) {
                    var j = i + 1;
                    while (j < s.len and !starts[s[j]]) j += 1;
                    // The units of the compares that the run skips: each
                    // key that fits at a position of the run.
                    var k: usize = 0;
                    while (k < keys.len) : (k += 2) {
                        const len = keys[k].len;
                        if (len == 0 or len > s.len) continue;
                        const fits = @min(j, s.len - len + 1) -| i;
                        try meter.add(it, len *| fits);
                    }
                    try out.appendSlice(a, s[i..j]);
                    i = j;
                    continue;
                }
                var k: usize = 0;
                while (k < keys.len) : (k += 2) {
                    const key = keys[k];
                    if (key.len == 0 or i + key.len > s.len) continue;
                    try meter.add(it, key.len);
                    const same = if (nocase) std.ascii.eqlIgnoreCase(s[i .. i + key.len], key) else eql(s[i .. i + key.len], key);
                    if (same) {
                        try out.appendSlice(a, keys[k + 1]);
                        i += key.len;
                        continue :outer;
                    }
                }
                try out.append(a, s[i]);
                i += 1;
            }
            return .{ .str = out.items };
        },
        .tolower, .toupper, .totitle => {
            if (args.len < 1 or args.len > 3) return it.fail("wrong # args: should be \"string {s} string ?first? ?last?\"", .{@tagName(which)});
            const s = try it.str(args[0]);
            const n = charCountOf(it, s);
            var first: i64 = 0;
            var last: i64 = @as(i64, @intCast(n)) - 1;
            if (args.len >= 2) {
                first = try index(it, args[1], n);
                last = if (args.len == 3) try index(it, args[2], n) else first;
            }
            if (first < 0) first = 0;
            if (last >= n) last = @as(i64, @intCast(n)) - 1;
            if (first > last) return args[0];
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            var k: i64 = 0;
            while (i < s.len) : (k += 1) {
                const d = ucd.next(s, i);
                if (k < first or k > last) {
                    try out.appendSlice(a, s[i .. i + d.len]);
                } else {
                    const cp = switch (which) {
                        .tolower => ucd.toLower(d.cp),
                        .toupper => ucd.toUpper(d.cp),
                        else => if (k == first) ucd.toTitle(d.cp) else ucd.toLower(d.cp),
                    };
                    try ucd.appendCp(a, &out, cp);
                }
                i += d.len;
            }
            return .{ .str = out.items };
        },
        .trim, .trimleft, .trimright => {
            if (args.len != 1 and args.len != 2) return it.fail("wrong # args: should be \"string {s} string ?chars?\"", .{@tagName(which)});
            const s = try it.str(args[0]);
            const chars: ?[]const u8 = if (args.len == 2) try it.str(args[1]) else null;
            return .{ .str = try trimChars(it, s, chars, which != .trimright, which != .trimleft) };
        },
        .repeat => {
            if (args.len != 2) return it.wrongArgs("string repeat string count");
            const s = try it.str(args[0]);
            const n = try it.int(args[1]);
            if (n <= 0 or s.len == 0) return Value.empty;
            const total = std.math.mul(usize, s.len, @intCast(n)) catch return it.fail("result exceeds max size for a Tcl value", .{});
            if (total > 1 << 28) return it.fail("result exceeds max size for a Tcl value", .{});
            try chargeWork(it, total);
            const out = try a.alloc(u8, total);
            // Each copy doubles the filled part, so the time is linear in
            // the result also for a short string.
            @memcpy(out[0..s.len], s);
            var done = s.len;
            while (done < total) {
                const k = @min(done, total - done);
                @memcpy(out[done..][0..k], out[0..k]);
                done += k;
            }
            return .{ .str = out };
        },
        .reverse => {
            if (args.len == 2 and try isGrapheme(it, args[0])) return text_cmd.reverse(it, try it.str(args[1]));
            if (args.len != 1) return it.wrongArgs("string reverse string");
            const s = try it.str(args[0]);
            const out = try a.alloc(u8, s.len);
            // Each character keeps the order of its bytes.
            var i: usize = 0;
            while (i < s.len) {
                var e = i + 1;
                while (e < s.len and s[e] & 0xC0 == 0x80) e += 1;
                @memcpy(out[s.len - e .. s.len - i], s[i..e]);
                i = e;
            }
            return .{ .str = out };
        },
        .cat => {
            var out: std.ArrayList(u8) = .empty;
            for (args) |v| try out.appendSlice(a, try it.str(v));
            return .{ .str = out.items };
        },
        .match => {
            var nocase = false;
            if (args.len != 2 and args.len != 3) return it.wrongArgs("string match ?-nocase? pattern string");
            if (args.len == 3) {
                const o = try it.str(args[0]);
                if (o.len < 2 or !std.mem.startsWith(u8, "-nocase", o)) return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -nocase", .{o});
                nocase = true;
            }
            var pat = try it.str(args[args.len - 2]);
            if (nocase) pat = try std.ascii.allocLowerString(a, pat);
            return .{ .int = @intFromBool(try globSteps(it, pat, try it.str(args[args.len - 1]), nocase)) };
        },
        .wordstart, .wordend => {
            if (args.len != 2) {
                if (which == .wordend) return it.wrongArgs("string wordend string index");
                return it.wrongArgs("string wordstart string index");
            }
            const s = try it.str(args[0]);
            var cps: std.ArrayList(u21) = .empty;
            var bi: usize = 0;
            while (bi < s.len) {
                const d = ucd.next(s, bi);
                try cps.append(a, d.cp);
                bi += d.len;
            }
            const t = cps.items;
            const n = try index(it, args[1], t.len);
            if (t.len == 0) return .{ .int = 0 };
            var at: usize = if (n < 0) 0 else @intCast(n);
            if (which == .wordend) {
                if (at >= t.len) return .{ .int = @intCast(t.len) };
                if (!ucd.isWordChar(t[at])) return .{ .int = @intCast(at + 1) };
                while (at < t.len and ucd.isWordChar(t[at])) at += 1;
                return .{ .int = @intCast(at) };
            }
            if (at >= t.len) at = t.len - 1;
            if (!ucd.isWordChar(t[at])) return .{ .int = @intCast(at) };
            while (at > 0 and ucd.isWordChar(t[at - 1])) at -= 1;
            return .{ .int = @intCast(at) };
        },
        .is => return stringIs(it, args),
    }
}

const class_names = [_][]const u8{ "alnum", "alpha", "ascii", "control", "boolean", "digit", "double", "entier", "false", "graph", "integer", "list", "lower", "print", "punct", "space", "true", "upper", "wideinteger", "wordchar", "xdigit" };
/// The classes of Tcl 9.1: also `dict`.
const class_names9 = [_][]const u8{ "alnum", "alpha", "ascii", "control", "boolean", "dict", "digit", "double", "entier", "false", "graph", "integer", "list", "lower", "print", "punct", "space", "true", "upper", "wideinteger", "wordchar", "xdigit" };

fn classOk(class: []const u8, c: u21) bool {
    if (eql(class, "alnum")) return ucd.isAlpha(c) or ucd.isDigit(c);
    if (eql(class, "alpha")) return ucd.isAlpha(c);
    if (eql(class, "ascii")) return c < 128;
    if (eql(class, "control")) return ucd.isControl(c);
    if (eql(class, "digit")) return ucd.isDigit(c);
    if (eql(class, "graph")) return ucd.isGraph(c);
    if (eql(class, "lower")) return ucd.isLower(c);
    if (eql(class, "print")) return ucd.isPrint(c);
    if (eql(class, "punct")) return ucd.isPunct(c);
    if (eql(class, "space")) return ucd.isSpace(c);
    if (eql(class, "upper")) return ucd.isUpper(c);
    if (eql(class, "wordchar")) return ucd.isWordChar(c);
    return c < 128 and std.ascii.isHex(@intCast(c));
}

/// The length of the longest start of `s` that is a number of the
/// kind. The kind is "int" or "double".
fn numberPrefix(s: []const u8, double: bool) usize {
    var i: usize = 0;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    const start = i;
    if (i + 1 < s.len and s[i] == '0' and (s[i + 1] | 32 == 'x' or s[i + 1] | 32 == 'b' or s[i + 1] | 32 == 'o')) {
        const kind = s[i + 1] | 32;
        var j = i + 2;
        while (j < s.len) : (j += 1) {
            const c = s[j];
            const ok = switch (kind) {
                'x' => std.ascii.isHex(c),
                'b' => c == '0' or c == '1',
                else => c >= '0' and c <= '7',
            };
            if (!ok) break;
        }
        if (j > i + 2) return j;
        return i + 1;
    }
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (!double) return if (i > start) i else 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    if (i == start or (i == start + 1 and s[start] == '.')) return 0;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        if (j < s.len and std.ascii.isDigit(s[j])) {
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            i = j;
        }
    }
    return i;
}

fn stringIs(it: *Interp, args: []const Value) Error!Value {
    const a = it.alloc();
    if (args.len < 2 or args.len > 5) return it.wrongArgs("string is class ?-strict? ?-failindex var? str");
    const word = try it.str(args[0]);
    const classes: []const []const u8 = if (it.tcl9()) &class_names9 else &class_names;
    var class: ?[]const u8 = null;
    var hits: usize = 0;
    for (classes) |c| {
        if (eql(c, word)) {
            class = c;
            hits = 1;
            break;
        }
        if (word.len > 0 and std.mem.startsWith(u8, c, word)) {
            class = c;
            hits += 1;
        }
    }
    if (hits != 1) {
        var msg: std.ArrayList(u8) = .empty;
        try msg.print(a, "{s} class \"{s}\": must be ", .{ if (hits > 1) "ambiguous" else "bad", word });
        for (classes, 0..) |c, i| {
            if (i > 0) try msg.appendSlice(a, ", ");
            if (i == classes.len - 1) try msg.appendSlice(a, "or ");
            try msg.appendSlice(a, c);
        }
        it.result = .{ .str = msg.items };
        it.error_code = .{ .str = "TCL LOOKUP INDEX class" };
        return error.TclError;
    }
    const cl = class.?;
    var strict = false;
    var fail_var: ?Value = null;
    var oi: usize = 1;
    while (oi < args.len - 1) : (oi += 1) {
        const o = try it.str(args[oi]);
        if (o.len >= 2 and std.mem.startsWith(u8, "-strict", o)) {
            strict = true;
        } else if (o.len >= 2 and std.mem.startsWith(u8, "-failindex", o)) {
            if (oi + 2 >= args.len) return it.fail("wrong # args: should be \"string is {s} ?-strict? ?-failindex var? str\"", .{cl});
            oi += 1;
            fail_var = args[oi];
        } else return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -strict or -failindex", .{o});
    }
    const v = args[args.len - 1];
    const s = try it.str(v);
    var ok = true;
    var at: i64 = 0;
    if (s.len == 0) {
        ok = !strict or eql(cl, "list");
    } else if (eql(cl, "boolean") or eql(cl, "true") or eql(cl, "false")) {
        ok = boolWordOf(s, cl);
    } else if (eql(cl, "integer") or eql(cl, "wideinteger") or eql(cl, "entier")) {
        const n = expr.intArg(it, v) catch |e| blk: {
            if (e != error.TclError) return e;
            break :blk null;
        };
        ok = n != null;
        if (ok and !eql(cl, "entier")) {
            if (n.? != .int) ok = false;
            if (ok and eql(cl, "integer") and (n.?.int > 0xFFFFFFFF or n.?.int < -0x80000000)) ok = false;
        }
        if (!ok) {
            at = if (n != null) -1 else @intCast(numberPrefix(s, false));
        }
    } else if (eql(cl, "double")) {
        // The number forms of Tcl 9.1, such as 1_000.5, in the forms of 8.6.
        const body = value.tcl9Form(s) orelse value.trimSpace(s);
        const prefix = numberPrefix(body, true);
        const plain = prefix == body.len and value.parseDouble(body) != null;
        const named = value.parseDouble(body) != null and body.len > 0 and !std.ascii.isDigit(body[body.len - 1]) and body[body.len - 1] != '.';
        ok = v == .double or v == .int or plain or named or (expr.intArg(it, v) catch null) != null;
        if (!ok) at = @intCast(numberPrefix(s, true));
    } else if (eql(cl, "list")) {
        ok = true;
        if (value.listFault(s) != null) {
            ok = false;
            at = @intCast(listFaultStart(s));
        }
    } else if (eql(cl, "dict")) {
        ok = value.listFault(s) == null and (try it.list(v)).len % 2 == 0;
    } else {
        var i: usize = 0;
        var k: usize = 0;
        while (i < s.len) : (k += 1) {
            const d = ucd.next(s, i);
            if (!classOk(cl, d.cp)) {
                ok = false;
                at = @intCast(k);
                break;
            }
            i += d.len;
        }
    }
    if (!ok) if (fail_var) |fv| try it.setVar(try it.str(fv), .{ .int = @intCast(at) });
    return .{ .int = @intFromBool(ok) };
}

/// The character index of the element with the open brace or quote.
fn listFaultStart(s: []const u8) usize {
    var i: usize = 0;
    var start: usize = 0;
    while (i < s.len) {
        while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
        if (i >= s.len) break;
        start = i;
        if (s[i] == '{') {
            var depth: usize = 0;
            while (i < s.len) : (i += 1) {
                if (s[i] == '\\') {
                    i += 1;
                } else if (s[i] == '{') {
                    depth += 1;
                } else if (s[i] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (i >= s.len) return charCount(s[0..start]);
            i += 1;
            if (i < s.len and !std.ascii.isWhitespace(s[i])) return charCount(s[0..start]);
        } else if (s[i] == '"') {
            i += 1;
            while (i < s.len and s[i] != '"') : (i += 1) {
                if (s[i] == '\\') i += 1;
            }
            if (i >= s.len) return charCount(s[0..start]);
            i += 1;
            if (i < s.len and !std.ascii.isWhitespace(s[i])) return charCount(s[0..start]);
        } else {
            while (i < s.len and !std.ascii.isWhitespace(s[i])) : (i += 1) {
                if (s[i] == '\\') i += 1;
            }
        }
    }
    return charCount(s[0..start]);
}

/// True when `s` is a boolean word of the class. Tcl accepts a unique
/// prefix of the words, in any case.
fn boolWordOf(s: []const u8, class: []const u8) bool {
    const t = s;
    var truth: ?bool = null;
    if (eql(t, "0") or eql(t, "1")) {
        truth = t[0] == '1';
    } else {
        const yes = [_][]const u8{ "true", "yes", "on" };
        const no = [_][]const u8{ "false", "no", "off" };
        const lower = t;
        for (yes) |w| {
            if (lower.len <= w.len and std.ascii.eqlIgnoreCase(lower, w[0..lower.len]) and !(eql(w, "on") and lower.len < 2)) truth = true;
        }
        for (no) |w| {
            if (lower.len <= w.len and std.ascii.eqlIgnoreCase(lower, w[0..lower.len]) and !(eql(w, "off") and lower.len < 2)) truth = false;
        }
    }
    const b = truth orelse return false;
    if (eql(class, "boolean")) return true;
    return b == eql(class, "true");
}

/// Compares by characters. A limit counts characters.
fn compareStrings(x: []const u8, y: []const u8, nocase: bool, limit: ?usize) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    var n: usize = 0;
    while (limit == null or n < limit.?) : (n += 1) {
        if (i >= x.len or j >= y.len) {
            if (i >= x.len and j >= y.len) return .eq;
            return if (i >= x.len) .lt else .gt;
        }
        const p = ucd.next(x, i);
        const q = ucd.next(y, j);
        const c = if (nocase) ucd.toLower(p.cp) else p.cp;
        const d = if (nocase) ucd.toLower(q.cp) else q.cp;
        if (c != d) return std.math.order(c, d);
        i += p.len;
        j += q.len;
    }
    return .eq;
}

/// The set of code points of `string trim`. The default set is the
/// Unicode spaces and NUL. A given set has a bitmap for the code points
/// below 256 and a hash table with linear probing for the others. So
/// the test of each code point of the string reads no list, and the
/// work is linear in the length of the string and of the set.
const TrimSet = struct {
    default: bool,
    low: std.StaticBitSet(256) = .empty,
    /// Each used slot holds a code point plus 1. An empty slot is 0.
    slots: []u32 = &.{},

    fn slotOf(slots: []const u32, cp: u21) usize {
        // The Fibonacci hash of the code point.
        const h: u32 = @as(u32, cp) *% 0x9E3779B1;
        return h & (slots.len - 1);
    }

    fn init(it: *Interp, chars: ?[]const u8) Error!TrimSet {
        const t = chars orelse return .{ .default = true };
        var set: TrimSet = .{ .default = false };
        var high: usize = 0;
        var i: usize = 0;
        while (i < t.len) {
            const d = ucd.next(t, i);
            if (d.cp < 256) set.low.set(d.cp) else high += 1;
            i += d.len;
        }
        if (high == 0) return set;
        const cap = std.math.ceilPowerOfTwo(usize, @max(16, 2 * high)) catch return error.OutOfMemory;
        set.slots = try it.alloc().alloc(u32, cap);
        @memset(set.slots, 0);
        i = 0;
        while (i < t.len) {
            const d = ucd.next(t, i);
            i += d.len;
            if (d.cp < 256) continue;
            var at = slotOf(set.slots, d.cp);
            var n: u32 = 0;
            while (set.slots[at] != 0 and set.slots[at] != @as(u32, d.cp) + 1) : (at = (at + 1) & (set.slots.len - 1)) {
                n +%= 1;
                if (n & 63 == 0) try step(it);
            }
            set.slots[at] = @as(u32, d.cp) + 1;
        }
        return set;
    }

    fn has(set: *const TrimSet, it: *Interp, cp: u21) Error!bool {
        if (set.default) return cp == 0 or ucd.isSpace(cp);
        if (cp < 256) return set.low.isSet(cp);
        if (set.slots.len == 0) return false;
        var at = slotOf(set.slots, cp);
        var n: u32 = 0;
        while (set.slots[at] != 0) : (at = (at + 1) & (set.slots.len - 1)) {
            if (set.slots[at] == @as(u32, cp) + 1) return true;
            // A long probe uses steps, as in the table of a dict.
            n +%= 1;
            if (n & 63 == 0) try step(it);
        }
        return false;
    }
};

fn trimChars(it: *Interp, s: []const u8, chars: ?[]const u8, left: bool, right: bool) Error![]const u8 {
    const set = try TrimSet.init(it, chars);
    var start: usize = 0;
    var end: usize = s.len;
    if (left) while (start < end) {
        const d = ucd.next(s, start);
        if (!try set.has(it, d.cp)) break;
        start += d.len;
    };
    if (right) while (end > start) {
        var k = end - 1;
        while (k > start and s[k] & 0xC0 == 0x80) k -= 1;
        const d = ucd.next(s, k);
        if (!try set.has(it, d.cp)) break;
        end = k;
    };
    return s[start..end];
}

// ---- info, puts, array ----

fn namesList(it: *Interp, frame: *interp.Frame, pattern: ?[]const u8, links: bool) Error!Value {
    var out: std.ArrayList(Value) = .empty;
    try chargeEntries(it, frame.vars.items.len);
    for (frame.vars.items) |e| {
        // The global frame also has the variables of the namespaces, by
        // their qualified names. They are not global variables.
        if (frame == &it.global and std.mem.indexOf(u8, e.name, "::") != null) continue;
        if (!isSet(e.cell, links)) continue;
        if (pattern) |p| if (!try globSteps(it, p, e.name, false)) continue;
        try out.append(it.alloc(), .{ .str = e.name });
    }
    return value.wrapList(it.alloc(), out.items);
}

fn isSet(cell: *interp.Var, links: bool) bool {
    var c = cell;
    if (c.v == .link and !links) return false;
    while (c.v == .link) c = c.v.link;
    return !(c.v == .undef or (c.v == .traced and c.v.traced.inner == .undef));
}

/// The variables of the namespace `space` (no leading "::", "" for the
/// global namespace) whose names match `pattern`. With `full`, each name
/// has the full form "::space::name".
fn nsVarNames(it: *Interp, space: []const u8, pattern: []const u8, full: bool, out: *std.ArrayList(Value)) Error!void {
    try chargeEntries(it, it.global.vars.items.len);
    for (it.global.vars.items) |e| {
        var name = e.name;
        if (space.len > 0) {
            if (!std.mem.startsWith(u8, name, space) or !std.mem.startsWith(u8, name[space.len..], "::")) continue;
            name = name[space.len + 2 ..];
        }
        if (std.mem.indexOf(u8, name, "::") != null) continue;
        if (!isSet(e.cell, true)) continue;
        if (!try globSteps(it, pattern, name, false)) continue;
        const v: Value = if (!full) .{ .str = name } else if (space.len > 0) .{ .str = try std.fmt.allocPrint(it.alloc(), "::{s}::{s}", .{ space, name }) } else .{ .str = try std.fmt.allocPrint(it.alloc(), "::{s}", .{name}) };
        try out.append(it.alloc(), v);
    }
}

/// `info vars`: a pattern with "::" lists the variables of that
/// namespace by their full names. In a frame of `namespace eval`, the
/// list has the variables of the namespace and the global variables.
fn infoVars(it: *Interp, pattern: ?[]const u8) Error!Value {
    var out: std.ArrayList(Value) = .empty;
    if (pattern) |p| if (std.mem.indexOf(u8, p, "::") != null) {
        const q = ns.qualifiers(p);
        var space: []const u8 = undefined;
        if (std.mem.startsWith(u8, p, "::")) {
            space = std.mem.trim(u8, q, ":");
        } else if (it.ns.len > 0) {
            space = try std.fmt.allocPrint(it.alloc(), "{s}::{s}", .{ it.ns, q });
            if (!it.namespaces.contains(space)) space = q;
        } else space = q;
        try nsVarNames(it, space, ns.tail(p), true, &out);
        return value.wrapList(it.alloc(), out.items);
    };
    if (it.frame.ns) |space| {
        const pat = pattern orelse "*";
        try nsVarNames(it, space, pat, false, &out);
        var globals: std.ArrayList(Value) = .empty;
        try nsVarNames(it, "", pat, false, &globals);
        for (globals.items) |g| {
            for (out.items) |o| {
                if (eql(o.str, g.str)) break;
            } else try out.append(it.alloc(), g);
        }
        return value.wrapList(it.alloc(), out.items);
    }
    return namesList(it, it.frame, pattern, true);
}

/// The subcommand of `info` that `word` names or is a unique prefix of.
fn infoSub(word: []const u8) ?InfoSub {
    if (std.meta.stringToEnum(InfoSub, word)) |w| return w;
    if (word.len == 0) return null;
    var found: ?InfoSub = null;
    inline for (comptime std.meta.fieldNames(InfoSub)) |name| {
        if (std.mem.startsWith(u8, name, word)) {
            if (found != null) return null;
            found = @field(InfoSub, name);
        }
    }
    return found;
}

const InfoSub = enum { args, body, class, cmdcount, commands, complete, coroutine, default, exists, functions, globals, level, library, loaded, locals, nameofexecutable, object, patchlevel, procs, script, sharedlibextension, tclversion, vars };

fn cmdInfo(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("info subcommand ?arg ...?");
    const a = it.alloc();
    const word = try it.str(argv[1]);
    const which: ?InfoSub = siteSub(InfoSub, &cmdInfo, argv, cmd) orelse infoSub(word);
    if (which) |w| noteSub(InfoSub, &cmdInfo, argv, cmd, w);
    const sub: []const u8 = if (which) |w| @tagName(w) else word;
    const pattern: ?[]const u8 = if (argv.len > 2) try it.str(argv[2]) else null;
    if (which) |w| switch (w) {
        .commands, .globals, .locals, .procs, .vars => if (argv.len > 3) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"info {s} ?pattern?\"", .{sub}),
        .cmdcount, .nameofexecutable, .patchlevel, .sharedlibextension, .tclversion, .library => if (argv.len != 2) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"info {s}\"", .{sub}),
        else => {},
    };
    if (which == .cmdcount) return .{ .int = @bitCast(std.math.maxInt(u64) - it.compute_limit) };
    if (which == .coroutine) {
        if (argv.len != 2) return it.wrongArgs("info coroutine");
        return coro.current(it);
    }
    if (which == .sharedlibextension) return .{ .str = ".so" };
    if (which == .library) {
        return (try it.getVarOpt("::tcl_library")) orelse it.fail("no library has been specified for Tcl", .{});
    }
    if (which == .loaded) {
        if (argv.len > 3) return it.wrongArgs("info loaded ?interp?");
        if (argv.len == 3 and pattern.?.len > 0) return it.failCode("TCL LOOKUP INTERP", "could not find interpreter \"{s}\"", .{pattern.?});
        return Value.empty;
    }
    if (which == .functions) {
        if (argv.len > 3) return it.wrongArgs("info functions ?pattern?");
        var out: std.ArrayList(Value) = .empty;
        try chargeEntries(it, it.commands.count());
        var iter = it.commands.keyIterator();
        while (iter.next()) |k| {
            if (!std.mem.startsWith(u8, k.*, "tcl::mathfunc::")) continue;
            const name = k.*["tcl::mathfunc::".len..];
            if (pattern) |p| if (!try globSteps(it, p, name, false)) continue;
            try out.append(a, .{ .str = name });
        }
        std.mem.sort(Value, out.items, {}, struct {
            fn less(_: void, x: Value, y: Value) bool {
                return std.mem.order(u8, x.str, y.str) == .lt;
            }
        }.less);
        return value.wrapList(a, out.items);
    }
    if (which == .exists) {
        if (argv.len != 3) return it.wrongArgs("info exists varName");
        const name, const idx = Interp.splitName(pattern.?);
        const cell = try it.findVar(it.frame, name, false) orelse return .{ .int = 0 };
        if (cell.v == .elem) return .{ .int = @intFromBool(cell.exists()) };
        if (cell.v == .traced) {
            const inner = cell.v.traced.inner;
            if (idx) |i| return .{ .int = @intFromBool(inner == .arr and inner.arr.contains(i)) };
            return .{ .int = @intFromBool(inner != .undef) };
        }
        if (idx) |i| return .{ .int = @intFromBool(cell.v == .arr and cell.v.arr.contains(i)) };
        return .{ .int = @intFromBool(cell.exists()) };
    } else if (which == .commands or which == .procs) {
        var out: std.ArrayList(Value) = .empty;
        const only_procs = which == .procs;
        // A qualified pattern lists one namespace with full names. A
        // plain pattern lists the current and the global namespace.
        const qualified = if (pattern) |p| std.mem.indexOf(u8, p, "::") != null else false;
        const space = if (qualified) std.mem.trim(u8, ns.qualifiers(pattern.?), ":") else it.ns;
        const pat: ?[]const u8 = if (qualified) ns.tail(pattern.?) else pattern;
        try chargeEntries(it, it.commands.count());
        var iter = it.commands.iterator();
        while (iter.next()) |e| {
            if (only_procs and e.value_ptr.*.impl != .proc) continue;
            const key = e.key_ptr.*;
            const local = eql(ns.qualifiers(key), space);
            const global = !qualified and std.mem.indexOf(u8, key, "::") == null;
            if (!local and !global) continue;
            if (!local and only_procs) continue;
            if (!local and it.ns.len > 0) {
                const mine = try std.fmt.allocPrint(a, "{s}::{s}", .{ it.ns, key });
                if (it.commands.contains(mine)) continue;
            }
            if (pat) |p| if (!try globSteps(it, p, ns.tail(key), false)) continue;
            var shown: []const u8 = key;
            if (qualified) {
                shown = try std.fmt.allocPrint(a, "::{s}", .{key});
            } else if (local and it.ns.len > 0) {
                shown = if (only_procs) ns.tail(key) else try std.fmt.allocPrint(a, "::{s}", .{key});
            }
            try out.append(a, .{ .str = shown });
        }
        // A fixed order, for determinism.
        const S = struct {
            fn less(_: void, x: Value, y: Value) bool {
                return std.mem.order(u8, x.str, y.str) == .lt;
            }
        };
        std.mem.sort(Value, out.items, {}, S.less);
        return value.wrapList(a, out.items);
    } else if (which == .default) {
        if (argv.len != 5) return it.wrongArgs("info default procname arg varname");
        const c = it.findCommand(pattern.?);
        if (c == null or c.?.impl != .proc) return it.fail("\"{s}\" isn't a procedure", .{pattern.?});
        const want = try it.str(argv[3]);
        for (c.?.impl.proc.params) |prm| {
            if (!eql(prm.name, want)) continue;
            try it.setVar(try it.str(argv[4]), prm.default orelse Value.empty);
            return .{ .int = @intFromBool(prm.default != null) };
        }
        if (c.?.impl.proc.has_args and eql(want, "args")) {
            try it.setVar(try it.str(argv[4]), Value.empty);
            return .{ .int = 0 };
        }
        return it.fail("procedure \"{s}\" doesn't have an argument \"{s}\"", .{ pattern.?, want });
    } else if (which == .object) {
        if (comptime !features.on("oo")) return features.fail(it, "oo", "info object");
        return @import("oo.zig").infoObject(it, argv);
    } else if (which == .class) {
        if (comptime !features.on("oo")) return features.fail(it, "oo", "info class");
        return @import("oo.zig").infoClass(it, argv);
    } else if (which == .args or which == .body) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"info {s} procname\"", .{sub});
        const c = it.findCommand(pattern.?);
        if (c == null or c.?.impl != .proc) return it.fail("\"{s}\" isn't a procedure", .{pattern.?});
        const p = c.?.impl.proc;
        if (which == .body) return p.body;
        var out: std.ArrayList(Value) = .empty;
        for (p.params) |prm| try out.append(a, .{ .str = prm.name });
        if (p.has_args) try out.append(a, .{ .str = "args" });
        return value.wrapList(a, out.items);
    } else if (which == .level) {
        if (argv.len > 3) return it.wrongArgs("info level ?number?");
        if (argv.len == 2) return .{ .int = it.frame.level };
        const n = try it.int(argv[2]);
        const target: i64 = if (n <= 0) @as(i64, it.frame.level) + n else n;
        if (target <= 0 or target > it.frame.level) return it.fail("bad level \"{s}\"", .{pattern.?});
        var f = it.frame;
        while (f.level > target) f = f.parent.?;
        return value.newList(a, f.argv);
    } else if (which == .vars) {
        return infoVars(it, pattern);
    } else if (which == .locals) {
        if (it.frame == &it.global) return Value.empty;
        return namesList(it, it.frame, pattern, false);
    } else if (which == .globals) {
        // A pattern can name the global namespace: "::x" and ":::x" are "x".
        var pat = pattern;
        if (pat) |q| {
            if (std.mem.startsWith(u8, q, "::")) pat = std.mem.trimStart(u8, q[2..], ":");
        }
        return namesList(it, &it.global, pat, true);
    } else if (which == .complete) {
        if (argv.len != 3) return it.wrongArgs("info complete command");
        // A backslash and a newline at the end continue the command.
        const text = pattern.?;
        if (text.len >= 2 and text[text.len - 1] == '\n') {
            var k = text.len - 1;
            var slashes: usize = 0;
            while (k > 0 and text[k - 1] == '\\') : (k -= 1) slashes += 1;
            if (slashes % 2 == 1) return .{ .int = 0 };
        }
        var p: interp.Parser = .{ .a = a, .src = pattern.? };
        if (p.parseScript(false)) |_| return .{ .int = 1 } else |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return .{ .int = @intFromBool(std.mem.indexOf(u8, p.message, "missing") == null) };
        }
    } else if (which == .tclversion) {
        // The message names the variable with no `::`, as in Tcl.
        return (try it.getVarOpt("::tcl_version")) orelse it.fail("can't read \"tcl_version\": no such variable", .{});
    } else if (which == .patchlevel) {
        return (try it.getVarOpt("::tcl_patchLevel")) orelse it.fail("can't read \"tcl_patchLevel\": no such variable", .{});
    } else if (which == .script) {
        if (argv.len > 3) return it.wrongArgs("info script ?filename?");
        if (argv.len == 3) it.script_name = try a.dupe(u8, pattern.?);
        return .{ .str = it.script_name };
    } else if (which == .nameofexecutable) {
        return .{ .str = it.exe_name };
    }
    return it.failCode("TCL LOOKUP INDEX subcommand", "unknown or ambiguous subcommand \"{s}\": must be args, body, cmdcount, commands, complete, default, exists, functions, globals, level, library, loaded, locals, nameofexecutable, patchlevel, procs, script, sharedlibextension, tclversion, or vars", .{word});
}

pub fn cmdPuts(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var args = argv[1..];
    var newline = true;
    if (args.len > 0 and eql(try it.str(args[0]), "-nonewline")) {
        newline = false;
        args = args[1..];
    }
    var std_name: []const u8 = "stdout";
    if (args.len == 2) {
        const chan = try it.str(args[0]);
        if (!eql(chan, "stdout") and !eql(chan, "stderr")) {
            if (comptime @import("sys.zig").supported) {
                if (try @import("chan.zig").putsTo(it, chan, try it.str(args[1]), newline)) return Value.empty;
            }
            if (it.soft_chans) |sc| {
                if (try sc.puts(it, chan, try it.str(args[1]), newline)) return Value.empty;
            }
            return it.fail("can not find channel named \"{s}\"", .{chan});
        }
        if (eql(chan, "stderr")) std_name = "stderr";
        args = args[1..];
    }
    if (args.len != 1) return it.wrongArgs("puts ?-nonewline? ?channelId? string");
    if (comptime @import("sys.zig").supported) {
        // A runner that acts as `tclsh` has real standard channels.
        if (it.chans.table.count() > 0) {
            if (try @import("chan.zig").putsTo(it, std_name, try it.str(args[0]), newline)) return Value.empty;
        }
    }
    if (it.output) |out| {
        // One call for each `puts`, so a host that shows each call sees
        // the line and its newline together.
        const s = try it.str(args[0]);
        out.write(out.ctx, if (newline) try std.mem.concat(it.alloc(), u8, &.{ s, "\n" }) else s);
    }
    return Value.empty;
}

fn cmdNoise3(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 4) return it.wrongArgs("noise3 x y z");
    var c: [3]f64 = undefined;
    for (argv[1..], 0..) |v, i| {
        c[i] = switch (v.asNumber() orelse return it.fail("expected floating-point number but got \"{s}\"", .{try it.str(v)})) {
            .int => |n| @floatFromInt(n),
            .double => |d| d,
            else => unreachable,
        };
    }
    return .{ .double = noise.noise3Seed(it.noise_seed, c[0], c[1], c[2]) };
}

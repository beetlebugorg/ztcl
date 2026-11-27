//! The `package` command.
//!
//! It keeps the provided versions and the `ifneeded` scripts in memory.
//! It reads no files. A script loads a package with `ifneeded`, or a
//! built-in module of `modules.zig` by its name.
//!
//! The full command needs the capability `package`. A build with
//! modules also has a small `package` by default: `names`, `present`,
//! `provide`, `require`, and `versions`. It sees the built-in modules and
//! the names that a script provides, and it runs no `ifneeded` script.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;
const modules = @import("modules.zig");

pub const Pkg = struct {
    version: ?[]const u8 = null,
    /// Pairs of a version and a script, in the order of definition.
    needed: std.ArrayList([2]Value) = .empty,
};

pub const State = struct {
    /// True after the first `package` call provides `Tcl`.
    tcl_provided: bool = false,
    table: std.StringArrayHashMapUnmanaged(*Pkg) = .empty,
    unknown: ?Value = null,
    prefer_latest: bool = false,
    /// One bit for each module of `modules.table` that is installed.
    installed: u64 = 0,
    /// One bit for each name of `modules.find` that `package forget` hid.
    forgotten: u64 = 0,
};

/// The built-in module of a name, unless `package forget` hid the name.
fn builtin(it: *Interp, name: []const u8) ?modules.Found {
    const f = modules.find(name) orelse return null;
    if (it.pkg.forgotten & (@as(u64, 1) << @intCast(f.ordinal)) != 0) return null;
    return f;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// A version as numbers. `a` is -2 and `b` is -1 between two numbers.
fn parseVersion(a: std.mem.Allocator, s: []const u8) !?[]const i64 {
    if (s.len == 0) return null;
    var out: std.ArrayList(i64) = .empty;
    var i: usize = 0;
    var after_ab = false;
    while (true) {
        if (i >= s.len or !std.ascii.isDigit(s[i])) return null;
        var n: i64 = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) n = n *| 10 +| (s[i] - '0');
        try out.append(a, n);
        if (i >= s.len) return out.items;
        const c = s[i];
        if (c == '.') {
            try out.append(a, 0);
        } else if ((c == 'a' or c == 'b') and !after_ab) {
            after_ab = true;
            try out.append(a, if (c == 'a') -2 else -1);
        } else return null;
        i += 1;
    }
}

fn compare(x: []const i64, y: []const i64) i64 {
    var i: usize = 0;
    while (i < x.len or i < y.len) : (i += 1) {
        const p: i64 = if (i < x.len) x[i] else 0;
        const q: i64 = if (i < y.len) y[i] else 0;
        if (p != q) return if (p < q) -1 else 1;
    }
    return 0;
}

fn version(it: *Interp, v: Value) Error![]const i64 {
    const s = try it.str(v);
    return (try parseVersion(it.alloc(), s)) orelse it.failCode("TCL VALUE VERSION", "expected version number but got \"{s}\"", .{s});
}

fn isStable(v: []const i64) bool {
    for (v) |x| if (x < 0) return false;
    return true;
}

/// True when the version meets one requirement: `a`, `a-`, or `a-b`.
fn meets(it: *Interp, ver: []const i64, req: []const u8) Error!bool {
    const a = it.alloc();
    if (std.mem.indexOfScalar(u8, req, '-')) |d| {
        const lo = (try parseVersion(a, req[0..d])) orelse return badReq(it, req);
        if (d + 1 == req.len) return compare(ver, lo) >= 0;
        const hi = (try parseVersion(a, req[d + 1 ..])) orelse return badReq(it, req);
        if (compare(lo, hi) == 0) return compare(ver, lo) == 0;
        return compare(ver, lo) >= 0 and compare(ver, hi) < 0;
    }
    const lo = (try parseVersion(a, req)) orelse return badReq(it, req);
    if (compare(ver, lo) < 0) return false;
    return ver[0] == lo[0];
}

fn badReq(it: *Interp, req: []const u8) Error {
    if (std.mem.indexOfScalar(u8, req, '-') != null) {
        return it.failCode("TCL VALUE VERSION", "expected versionMin-versionMax but got \"{s}\"", .{req});
    }
    return it.failCode("TCL VALUE VERSION", "expected version number but got \"{s}\"", .{req});
}

fn meetsAny(it: *Interp, ver: []const i64, reqs: []const Value) Error!bool {
    if (reqs.len == 0) return true;
    for (reqs) |r| if (try meets(it, ver, try it.str(r))) return true;
    return false;
}

fn entry(it: *Interp, name: []const u8) Error!*Pkg {
    const st = &it.pkg;
    if (st.table.get(name)) |p| return p;
    const p = try it.alloc().create(Pkg);
    p.* = .{};
    try st.table.put(it.alloc(), try it.alloc().dupe(u8, name), p);
    return p;
}

fn checkReqs(it: *Interp, reqs: []const Value) Error!void {
    for (reqs) |r| {
        const s = try it.str(r);
        if (std.mem.indexOfScalar(u8, s, '-') != null) {
            _ = try meets(it, &.{0}, s);
        } else _ = try version(it, r);
    }
}

fn require(it: *Interp, name: []const u8, reqs: []const Value, exact: bool) Error!Value {
    const a = it.alloc();
    var words: []const Value = reqs;
    if (exact) {
        const r = try it.str(reqs[0]);
        words = try a.dupe(Value, &.{.{ .str = try std.fmt.allocPrint(a, "{s}-{s}", .{ r, r }) }});
    }
    var tried_unknown = false;
    while (true) {
        const p = try entry(it, name);
        if (p.version) |have| {
            if (try meetsAny(it, try version(it, .{ .str = have }), words)) return .{ .str = have };
            return it.failCode("TCL PACKAGE VERSIONCONFLICT", "version conflict for package \"{s}\": have {s}, need {s}{s}", .{ name, have, if (exact) "exactly " else "", try it.str(try value.newList(a, reqs)) });
        }
        // The best script: the highest stable version, then any.
        var best: ?[2]Value = null;
        var best_v: []const i64 = &.{};
        var best_stable = false;
        for (p.needed.items) |pair| {
            const v = try version(it, pair[0]);
            if (!try meetsAny(it, v, words)) continue;
            const stable = isStable(v) or it.pkg.prefer_latest;
            if (best == null or (stable and !best_stable) or (stable == best_stable and compare(v, best_v) > 0)) {
                best = pair;
                best_v = v;
                best_stable = stable;
            }
        }
        if (best) |b| {
            const script = try it.scriptOfValue(b[1], null);
            // The script runs at the global level and in the global
            // namespace, as in Tcl, so a `namespace eval` in it is global.
            const saved_frame = it.frame;
            const saved_ns = it.ns;
            it.frame = &it.global;
            it.ns = "";
            defer {
                it.frame = saved_frame;
                it.ns = saved_ns;
            }
            _ = it.evalScript(script) catch |e| switch (e) {
                error.TclReturn => {
                    it.ret_code = .ok;
                    it.ret_level = 1;
                    it.ret_opts = &.{};
                },
                error.TclError => {
                    it.result = .{ .str = try std.fmt.allocPrint(a, "attempt to provide package {s} {s} failed: {s}", .{ name, try it.str(b[0]), try it.str(it.result) }) };
                    return e;
                },
                error.TclBreak, error.TclContinue, error.TclCustom => return it.failCode("TCL PACKAGE", "attempt to provide package {s} {s} failed: bad return code: {d}", .{ name, try it.str(b[0]), @as(u32, switch (e) {
                    error.TclBreak => 3,
                    error.TclContinue => 4,
                    else => it.custom_code,
                }) }),
                else => return e,
            };
            const now = (try entry(it, name)).version orelse
                return it.failCode("TCL PACKAGE UNPROVIDED", "attempt to provide package {s} {s} failed: package {s} {s} not provided", .{ name, try it.str(b[0]), name, try it.str(b[0]) });
            if (compare(try version(it, .{ .str = now }), best_v) != 0) {
                return it.failCode("TCL PACKAGE WRONGVERSION", "attempt to provide package {s} {s} failed: package {s} {s} provided instead", .{ name, try it.str(b[0]), name, now });
            }
            return .{ .str = now };
        }
        if (builtin(it, name)) |f| {
            const have = f.version();
            if (try meetsAny(it, try version(it, .{ .str = have }), words)) {
                try modules.load(it, f, &it.pkg.installed);
                (try entry(it, name)).version = have;
                return .{ .str = have };
            }
        }
        if (it.pkg.unknown != null and !tried_unknown) {
            tried_unknown = true;
            var cmd: std.ArrayList(Value) = .empty;
            try cmd.appendSlice(a, try it.list(it.pkg.unknown.?));
            try cmd.append(a, .{ .str = name });
            try cmd.appendSlice(a, words);
            _ = try it.callWords(cmd.items);
            continue;
        }
        if (reqs.len == 0) return it.failCode("TCL PACKAGE UNFOUND", "can't find package {s}", .{name});
        return it.failCode("TCL PACKAGE UNFOUND", "can't find package {s} {s}{s}", .{ name, if (exact) "exactly " else "", try it.str(try value.newList(a, reqs)) });
    }
}

/// Provides the package `Tcl` once, at the patch level of the interpreter.
/// A script can forget it after that, as in Tcl.
fn provideTcl(it: *Interp) Error!void {
    if (it.pkg.tcl_provided) return;
    it.pkg.tcl_provided = true;
    const level = it.getVar("::tcl_patchLevel") catch Value{ .str = it.tcl.patchLevel() };
    (try entry(it, "Tcl")).version = try it.alloc().dupe(u8, try it.str(level));
}

/// Sets the version of the package `Tcl` again after a change of
/// `Interp.tcl`. Before the first `package` command, `provideTcl` reads
/// the new patch level itself.
pub fn retagTcl(it: *Interp) Error!void {
    if (!it.pkg.tcl_provided) return;
    it.pkg.tcl_provided = false;
    try provideTcl(it);
}

pub fn cmdPackage(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("package option ?arg ...?");
    try provideTcl(it);
    const a = it.alloc();
    const word = try it.str(argv[1]);
    const names = [_][]const u8{ "forget", "ifneeded", "names", "prefer", "present", "provide", "require", "unknown", "vcompare", "versions", "vsatisfies" };
    var sub: []const u8 = word;
    var hits: usize = 0;
    for (names) |n| {
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
    if (hits != 1) return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be forget, ifneeded, names, prefer, present, provide, require, unknown, vcompare, versions, or vsatisfies", .{word});
    const args = argv[2..];
    const st = &it.pkg;
    if (eql(sub, "forget")) {
        for (args) |v| {
            const name = try it.str(v);
            _ = st.table.orderedRemove(name);
            if (modules.find(name)) |f| st.forgotten |= @as(u64, 1) << @intCast(f.ordinal);
        }
        return Value.empty;
    }
    if (eql(sub, "ifneeded")) {
        if (args.len != 2 and args.len != 3) return it.wrongArgs("package ifneeded package version ?script?");
        _ = try version(it, args[1]);
        const name = try it.str(args[0]);
        const ver = try version(it, args[1]);
        if (args.len == 2) {
            const p = st.table.get(name) orelse return Value.empty;
            for (p.needed.items) |pair| {
                if (compare(try version(it, pair[0]), ver) == 0) return pair[1];
            }
            return Value.empty;
        }
        const p = try entry(it, name);
        for (p.needed.items) |*pair| {
            if (compare(try version(it, pair[0]), ver) == 0) {
                pair[1] = args[2];
                return Value.empty;
            }
        }
        try p.needed.append(a, .{ args[1], args[2] });
        return Value.empty;
    }
    if (eql(sub, "names")) {
        if (args.len != 0) return it.wrongArgs("package names");
        var out: std.ArrayList(Value) = .empty;
        for (st.table.keys(), st.table.values()) |k, p| {
            if (p.version != null or p.needed.items.len > 0) try out.append(a, .{ .str = k });
        }
        try modules.eachName(NameList{ .it = it, .out = &out }, NameList.add);
        return value.wrapList(a, out.items);
    }
    if (eql(sub, "prefer")) {
        if (args.len > 1) return it.wrongArgs("package prefer ?latest|stable?");
        if (args.len == 1) {
            const m = try it.str(args[0]);
            if (eql(m, "latest")) {
                st.prefer_latest = true;
            } else if (eql(m, "stable")) {
                if (st.prefer_latest) return it.fail("cannot change the preference to stable", .{});
            } else return it.failCode("TCL LOOKUP INDEX preference", "bad preference \"{s}\": must be latest or stable", .{m});
        }
        return .{ .str = if (st.prefer_latest) "latest" else "stable" };
    }
    if (eql(sub, "provide")) {
        if (args.len != 1 and args.len != 2) return it.wrongArgs("package provide package ?version?");
        const name = try it.str(args[0]);
        if (args.len == 1) {
            const p = st.table.get(name) orelse return Value.empty;
            return .{ .str = p.version orelse "" };
        }
        const ver = try version(it, args[1]);
        const p = try entry(it, name);
        if (p.version) |have| {
            if (compare(try version(it, .{ .str = have }), ver) != 0) {
                return it.failCode("TCL PACKAGE VERSIONCONFLICT", "conflicting versions provided for package \"{s}\": {s}, then {s}", .{ name, have, try it.str(args[1]) });
            }
            return Value.empty;
        }
        p.version = try a.dupe(u8, try it.str(args[1]));
        return Value.empty;
    }
    if (eql(sub, "present") or eql(sub, "require")) {
        const usage = if (eql(sub, "present")) "package present ?-exact? package ?requirement ...?" else "package require ?-exact? package ?requirement ...?";
        var rest = args;
        var exact = false;
        if (rest.len > 0 and eql(try it.str(rest[0]), "-exact")) {
            exact = true;
            rest = rest[1..];
        }
        if (rest.len == 0 or (exact and rest.len != 2)) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s}\"", .{usage});
        const name = try it.str(rest[0]);
        const reqs = rest[1..];
        try checkReqs(it, reqs);
        if (eql(sub, "require")) return require(it, name, reqs, exact);
        const p = st.table.get(name);
        if (p == null or p.?.version == null) {
            if (reqs.len == 0) return it.failCode("TCL PACKAGE UNFOUND", "package {s} is not present", .{name});
            return it.failCode("TCL PACKAGE UNFOUND", "package {s} {s} is not present", .{ name, try it.str(try value.newList(a, reqs)) });
        }
        const have = p.?.version.?;
        var words = reqs;
        if (exact) {
            const r = try it.str(reqs[0]);
            words = try a.dupe(Value, &.{.{ .str = try std.fmt.allocPrint(a, "{s}-{s}", .{ r, r }) }});
        }
        if (!try meetsAny(it, try version(it, .{ .str = have }), words)) {
            return it.failCode("TCL PACKAGE VERSIONCONFLICT", "version conflict for package \"{s}\": have {s}, need {s}{s}", .{ name, have, if (exact) "exactly " else "", try it.str(try value.newList(a, reqs)) });
        }
        return .{ .str = have };
    }
    if (eql(sub, "unknown")) {
        if (args.len > 1) return it.wrongArgs("package unknown ?command?");
        if (args.len == 0) return st.unknown orelse Value.empty;
        st.unknown = if ((try it.str(args[0])).len == 0) null else args[0];
        return Value.empty;
    }
    if (eql(sub, "vcompare")) {
        if (args.len != 2) return it.wrongArgs("package vcompare version1 version2");
        return .{ .int = compare(try version(it, args[0]), try version(it, args[1])) };
    }
    if (eql(sub, "versions")) {
        if (args.len != 1) return it.wrongArgs("package versions package");
        var out: std.ArrayList(Value) = .empty;
        const name = try it.str(args[0]);
        if (st.table.get(name)) |p| for (p.needed.items) |pair| try out.append(a, pair[0]);
        if (builtin(it, name)) |f| {
            const have = try version(it, .{ .str = f.version() });
            for (out.items) |v| {
                if (compare(try version(it, v), have) == 0) break;
            } else try out.append(a, .{ .str = f.version() });
        }
        return value.wrapList(a, out.items);
    }
    // vsatisfies
    if (args.len < 2) return it.wrongArgs("package vsatisfies version ?requirement ...?");
    const ver = try version(it, args[0]);
    try checkReqs(it, args[1..]);
    return .{ .int = @intFromBool(try meetsAny(it, ver, args[1..])) };
}

/// Adds each name of a built-in module that the table does not list.
const NameList = struct {
    it: *Interp,
    out: *std.ArrayList(Value),

    fn add(self: NameList, name: []const u8) Error!void {
        if (self.it.pkg.table.get(name)) |p| {
            if (p.version != null or p.needed.items.len > 0) return;
        }
        if (builtin(self.it, name) == null) return;
        try self.out.append(self.it.alloc(), .{ .str = name });
    }
};

/// Registers the small `package` when the build has modules.
pub fn registerBuiltin(it: *Interp) std.mem.Allocator.Error!void {
    if (comptime modules.table.len == 0) return;
    try it.register("package", cmdPackageSmall);
}

/// The small `package`: the subcommands of the full command that see
/// only the built-in modules and the provided names.
fn cmdPackageSmall(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("package option ?arg ...?");
    const word = try it.str(argv[1]);
    const names = [_][]const u8{ "names", "present", "provide", "require", "versions" };
    var sub: ?[]const u8 = null;
    var hits: usize = 0;
    for (names) |n| {
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
    if (hits != 1) return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be names, present, provide, require, or versions", .{word});
    const words = try it.alloc().dupe(Value, argv);
    words[1] = .{ .str = sub.? };
    return cmdPackage(it, words, cmd);
}

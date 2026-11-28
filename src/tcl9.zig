//! The commands and subcommands that exist in one Tcl release only.
//!
//! An interpreter follows Tcl 8.6 or Tcl 9.1 (`Interp.tcl`). A command
//! of 9.1 only (`lseq`, `lpop`, `lremove`, `ledit`, `lfilter`, and the
//! math functions and commands of `math9.zig`) is in the command table
//! only while the interpreter follows 9.1: `apply` adds or removes it at
//! each change of the release. An ensemble command with a
//! subcommand of one release only calls `pick`, which matches a name or
//! a unique prefix among the subcommands of the release of the
//! interpreter, and gives the error message of Tcl with the names of that
//! release in alphabetical order.
//!
//! `lseq` makes the whole list. A series of doubles rounds each element
//! to the most digits after the decimal point of the arguments, so
//! `lseq 0 1 0.1` gives 0.3 and not 0.30000000000000004. The length of
//! such a series comes from the integer distance and step after a scale
//! by the same power of ten. This follows the behavior of tclsh 9.1.0;
//! `docs/references/tcl.md` lists it.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
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

/// The subcommands of `Sub` that exist in one release only.
pub fn Only(comptime Sub: type) type {
    return struct {
        v8_6: []const Sub = &.{},
        v9_1: []const Sub = &.{},
        /// The start of the error message, before the quoted word.
        head: []const u8 = "unknown or ambiguous subcommand",
        /// The `errorCode` of the error. Null gives NONE.
        code: ?[]const u8 = null,
    };
}

/// The subcommand that `text` names, or that it is a unique prefix of,
/// among the subcommands of the release of `it`. The fields of `Sub`
/// must have the values 0, 1, 2, ... in order.
pub fn pick(it: *Interp, comptime Sub: type, text: []const u8, comptime only: Only(Sub)) Error!Sub {
    const names = comptime std.meta.fieldNames(Sub);
    const absent = comptime .{ mask(Sub, only.v9_1), mask(Sub, only.v8_6) };
    const i = try pickName(it, names, if (it.tcl9()) absent[1] else absent[0], text, only.head, only.code);
    return @fromBackingInt(@intCast(i));
}

fn mask(comptime Sub: type, comptime subs: []const Sub) u64 {
    var m: u64 = 0;
    for (subs) |s| m |= @as(u64, 1) << @backingInt(s);
    return m;
}

/// The index of the name of `names` that `text` matches, among the names
/// with no bit in `absent`.
fn pickName(it: *Interp, names: []const [:0]const u8, absent: u64, text: []const u8, head: []const u8, code: ?[]const u8) Error!usize {
    var found: usize = 0;
    var hits: usize = 0;
    for (names, 0..) |name, i| {
        if (absent & (@as(u64, 1) << @intCast(i)) != 0) continue;
        if (eql(name, text)) return i;
        if (text.len > 0 and std.mem.startsWith(u8, name, text)) {
            found = i;
            hits += 1;
        }
    }
    if (hits == 1) return found;
    // The names of the release, in alphabetical order.
    const a = it.alloc();
    var list: std.ArrayList([]const u8) = .empty;
    for (names, 0..) |name, i| {
        if (absent & (@as(u64, 1) << @intCast(i)) == 0) try list.append(a, name);
    }
    // An insertion sort: a list of subcommands is short.
    const l = list.items;
    for (1..l.len) |i| {
        var j = i;
        while (j > 0 and std.mem.order(u8, l[j - 1], l[j]) == .gt) : (j -= 1) std.mem.swap([]const u8, &l[j - 1], &l[j]);
    }
    var msg: std.ArrayList(u8) = .empty;
    try msg.print(a, "{s} \"{s}\": must be ", .{ head, text });
    for (list.items, 0..) |n, i| {
        if (i > 0) try msg.appendSlice(a, if (i + 1 == list.items.len) (if (list.items.len > 2) ", or " else " or ") else ", ");
        try msg.appendSlice(a, n);
    }
    it.result = .{ .str = msg.items };
    it.error_code = .{ .str = code orelse "NONE" };
    return error.TclError;
}

/// The commands of Tcl 9.1 that Tcl 8.6 does not have.
const Entry = @import("math9.zig").Entry;
const commands = [_]Entry{
    .{ .name = "lseq", .f = cmdLseq },
    .{ .name = "lpop", .f = cmdLpop },
    .{ .name = "lremove", .f = cmdLremove },
    .{ .name = "ledit", .f = cmdLedit },
    .{ .name = "lfilter", .f = cmds.cmdLfilter },
} ++ @import("math9.zig").commands ++ (if (@import("features.zig").on("coroutine")) [_]Entry{
    .{ .name = "coroinject", .f = @import("coro.zig").cmdCoroInject },
    .{ .name = "coroprobe", .f = @import("coro.zig").cmdCoroProbe },
} else [_]Entry{});

/// Adds the commands of the release of `it` and removes the commands of
/// the other release. A command that a script made with the same name
/// stays.
pub fn apply(it: *Interp) std.mem.Allocator.Error!void {
    for (commands) |c| {
        const have = it.commands.get(c.name);
        if (it.tcl9()) {
            if (have == null) try it.register(c.name, c.f);
        } else if (have) |h| {
            if (h.impl == .native and h.impl.native == c.f) {
                _ = it.commands.remove(c.name);
                it.epoch += 1;
            }
        }
    }
}

fn outOfRange(it: *Interp, v: Value) Error {
    return it.failCode("TCL VALUE INDEX OUTOFRANGE", "index \"{s}\" out of range", .{try it.str(v)});
}

/// The most elements of a list that `lseq` makes, as for `lrepeat`.
const max_items = 1 << 24;

fn number(it: *Interp, v: Value) Error!Value {
    return v.asNumber() orelse it.failCode("TCL VALUE NUMBER", "expected number but got \"{s}\"", .{try it.str(v)});
}

/// The count of digits after the decimal point of a double argument
/// in decimal form. Zero for an integer and for exponent form.
fn decimals(it: *Interp, v: Value, n: Value) Error!u32 {
    if (n != .double) return 0;
    const s = try it.str(v);
    if (std.mem.indexOfAny(u8, s, "eE") != null) return 0;
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return 0;
    return @intCast(@min(value.trimSpace(s[dot + 1 ..]).len, 17));
}

fn asF64(n: Value) f64 {
    return switch (n) {
        .int => |i| @floatFromInt(i),
        .double => |d| d,
        else => unreachable,
    };
}

/// The powers of ten up to the most decimal places of `decimals`.
const pow10 = blk: {
    var t: [18]f64 = undefined;
    var x: f64 = 1;
    for (&t) |*v| {
        v.* = x;
        x *= 10;
    }
    break :blk t;
};

fn round(d: f64, scale: f64) f64 {
    if (scale == 1) return d;
    return @round(d * scale) / scale;
}

/// lseq n | lseq start ?to|..? end ??by? step? | lseq start count n ??by? step?
fn cmdLseq(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const usage = "lseq n ??op? n ??by? n??";
    const w = argv[1..];
    if (w.len == 0 or w.len > 5) return it.wrongArgs(usage);
    const Op = enum { to, count };
    var op: Op = .to;
    var start_v: Value = .{ .int = 0 };
    var end_v: Value = undefined;
    var step_v: ?Value = null;
    if (w.len == 1) {
        op = .count;
        end_v = w[0];
        step_v = .{ .int = 1 };
    } else {
        start_v = w[0];
        var i: usize = 1;
        const kw = try it.str(w[1]);
        if (eql(kw, "to") or eql(kw, "..") or eql(kw, "count")) {
            op = if (eql(kw, "count")) .count else .to;
            i += 1;
            if (i >= w.len) return it.fail("missing \"{s}\" value.", .{kw});
        }
        end_v = w[i];
        i += 1;
        if (i < w.len) {
            if (eql(try it.str(w[i]), "by")) {
                i += 1;
                if (i >= w.len) return it.fail("missing \"by\" value.", .{});
            }
            step_v = w[i];
            i += 1;
        }
        if (i != w.len) return it.wrongArgs(usage);
    }
    const start = try number(it, start_v);
    const end = try number(it, end_v);
    const step = if (step_v) |s| try number(it, s) else null;
    const all_int = start == .int and end == .int and (step == null or step.? == .int);
    if (op == .count) {
        const n = if (end == .int) end.int else @as(i64, @intFromFloat(@trunc(end.double)));
        const st = step orelse Value{ .int = 1 };
        return series(it, start, st, if (n < 0) 0 else n, all_int, try precision(it, start_v, start, step_v, st, null, null));
    }
    if (all_int) {
        const s0 = start.int;
        const s1 = end.int;
        const st = if (step) |s| s.int else if (s1 >= s0) @as(i64, 1) else -1;
        var len: i64 = 0;
        if (st == 0) {
            len = 1;
        } else if (!((st < 0 and s1 > s0) or (st > 0 and s1 < s0))) {
            len = @divTrunc(s1 -% s0, st) + 1;
        }
        return series(it, start, .{ .int = st }, len, true, 0);
    }
    const d0 = asF64(start);
    const d1 = asF64(end);
    const st: f64 = if (step) |s| asF64(s) else if (d1 >= d0) 1 else -1;
    const p = try precision(it, start_v, start, step_v, if (step) |s| s else Value{ .double = st }, end_v, end);
    var len: i64 = 1;
    if (st != 0) {
        const scale = pow10[p];
        const dist = (d1 - d0) * scale;
        const sst = st * scale;
        const wide: f64 = @floatFromInt(std.math.maxInt(i64));
        const idist: i64 = if (@abs(dist) < wide) @intFromFloat(if (dist < 0) dist - 0.5 else dist + 0.5) else 0;
        const istep: i64 = if (@abs(sst) < wide) @intFromFloat(if (sst < 0) sst - 0.5 else sst + 0.5) else 0;
        if ((st < 0 and d1 > d0) or (st > 0 and d1 < d0)) {
            len = 0;
        } else if (istep != 0 and @abs(dist) < wide) {
            len = @max(@divTrunc(idist, istep) + 1, 0);
        } else {
            const f = dist / sst + 1;
            len = if (f <= 0) 1 else if (f >= max_items + 1) max_items + 1 else @intFromFloat(f);
        }
    }
    return series(it, start, .{ .double = st }, len, false, p);
}

fn precision(it: *Interp, sv: Value, s: Value, stv: ?Value, st: Value, ev: ?Value, e: ?Value) Error!u32 {
    var p = try decimals(it, sv, s);
    if (stv) |x| p = @max(p, try decimals(it, x, st));
    if (ev) |x| p = @max(p, try decimals(it, x, e.?));
    return p;
}

fn series(it: *Interp, start: Value, step: Value, len: i64, all_int: bool, p: u32) Error!Value {
    if (len <= 0) return Value.empty;
    if (len > max_items) return it.fail("max length of a Tcl list exceeded", .{});
    const n: usize = @intCast(len);
    try cmds.chargeEntries(it, n);
    const out = try it.alloc().alloc(Value, n);
    if (all_int) {
        for (out, 0..) |*o, k| o.* = .{ .int = start.int +% @as(i64, @intCast(k)) *% step.int };
    } else {
        const scale = pow10[p];
        const d0 = asF64(start);
        const st = asF64(step);
        for (out, 0..) |*o, k| o.* = .{ .double = round(d0 + @as(f64, @floatFromInt(k)) * st, scale) };
    }
    return value.wrapList(it.alloc(), out);
}

/// The list `v` with the element at the index path `path` taken out, and
/// that element.
fn popPath(it: *Interp, v: Value, path: []const Value) Error![2]Value {
    const items = try it.list(v);
    const i = try cmds.index(it, path[0], items.len);
    if (i < 0 or i >= @as(i64, @intCast(items.len))) return outOfRange(it, path[0]);
    const at: usize = @intCast(i);
    const a = it.alloc();
    if (path.len == 1) {
        const rest = try std.mem.concat(a, Value, &.{ items[0..at], items[at + 1 ..] });
        return .{ items[at], try value.wrapList(a, rest) };
    }
    const inner = try popPath(it, items[at], path[1..]);
    const copy = try a.dupe(Value, items);
    copy[at] = inner[1];
    return .{ inner[0], try value.wrapList(a, copy) };
}

/// lpop listVar ?index ...?
fn cmdLpop(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("lpop listVar ?index?");
    const name = try it.str(argv[1]);
    const cur = try it.getVar(name);
    var path: []const Value = argv[2..];
    const end = [1]Value{.{ .str = "end" }};
    if (path.len == 0) path = &end;
    if (path.len == 1) {
        const l = try it.list(path[0]);
        if (l.len > 1) path = l;
    }
    const r = try popPath(it, cur, path);
    try it.setVar(name, r[1]);
    return r[0];
}

/// lremove list ?index ...?
fn cmdLremove(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("lremove list ?index ...?");
    const items = try it.list(argv[1]);
    const a = it.alloc();
    const drop = try a.alloc(bool, items.len);
    @memset(drop, false);
    for (argv[2..]) |iv| {
        const i = try cmds.index(it, iv, items.len);
        if (i >= 0 and i < @as(i64, @intCast(items.len))) drop[@intCast(i)] = true;
    }
    var out: std.ArrayList(Value) = .empty;
    for (items, drop) |x, d| if (!d) try out.append(a, x);
    return value.wrapList(a, out.items);
}

/// ledit listVar first last ?element ...?
fn cmdLedit(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len < 4) return it.wrongArgs("ledit listVar first last ?element ...?");
    const name = try it.str(argv[1]);
    const words = try it.alloc().dupe(Value, argv);
    words[1] = try it.getVar(name);
    const out = try cmds.cmdLreplace(it, words, cmd);
    try it.setVar(name, out);
    return out;
}

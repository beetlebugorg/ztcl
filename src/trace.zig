//! The `trace` command: variable, command, and execution traces.
//!
//! A traced variable has the cell form `.traced`. The fast paths of the
//! bytecode test for `.val`, so a read of a traced cell goes to the
//! general path, and the general path runs the traces. While any
//! variable has a trace, the inline forms of the bytecode are off.
//!
//! A command with an execution trace has a wrapper as its function.
//! A call of an untraced command has no added cost.
//!
//! Limits: `enterstep` and `leavestep` traces are stored and do not
//! run. `Interp.compact` drops all traces.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;
const Var = interp.Var;
const cmds = @import("cmds.zig");

pub const op_read: u8 = 1;
pub const op_write: u8 = 2;
pub const op_unset: u8 = 4;
pub const op_array: u8 = 8;

pub const VarTrace = struct {
    ops: u8,
    cmd: Value,
    /// The index of a trace on one element, or null.
    elem: ?[]const u8 = null,
    /// The letters of a trace from `trace variable`, or null.
    old: ?[]const u8 = null,
    /// A trace of `vwait`: a write or an unset sets the flag and runs
    /// no script. `trace info` does not list it.
    flag: ?*bool = null,
};

pub const Traced = struct {
    inner: union(enum) { undef, val: Value, arr: *interp.ArrayMap } = .undef,
    list: std.ArrayList(VarTrace) = .empty,
    /// Goes up at each change of `list`. A run of the traces checks that
    /// a trace is still in the list only after a change.
    changes: u32 = 0,
    busy: bool = false,
    /// The cell of `tcl_precision`. A write sets the print precision,
    /// and an unset keeps the value. It does not turn the inline forms
    /// off, because a store to a `.traced` cell uses the general path.
    precision: bool = false,
};

/// Makes the variable `tcl_precision`.
pub fn installPrecision(it: *Interp) std.mem.Allocator.Error!void {
    const cell = (try it.findVar(&it.global, "tcl_precision", true)).?;
    const t = try it.alloc().create(Traced);
    t.* = .{ .inner = .{ .val = .{ .int = 0 } }, .precision = true };
    cell.v = .{ .traced = t };
}

fn setPrecision(it: *Interp, t: *Traced, old: @FieldType(Traced, "inner"), v: Value) Error!void {
    const n: ?i64 = v.asInt();
    if (n == null or n.? < 0 or n.? > 17) {
        t.inner = old;
        return it.fail("can't set \"tcl_precision\": improper value for precision", .{});
    }
    it.precision = @intCast(n.?);
    value.precision = it.precision;
}

const ExecTrace = struct { ops: u8, cmd: Value };
pub const CmdTraces = struct {
    /// Rename (1) and delete (2) traces, newest first.
    cmds: std.ArrayList(ExecTrace) = .empty,
    /// Enter (1), leave (2), enterstep (4), and leavestep (8) traces.
    execs: std.ArrayList(ExecTrace) = .empty,
    /// The function of the command under the wrapper.
    orig: ?@FieldType(interp.Command, "impl") = null,
    busy: bool = false,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn opName(op: u8) []const u8 {
    return switch (op) {
        op_read => "read",
        op_write => "write",
        op_unset => "unset",
        else => "array",
    };
}

fn oldLetter(op: u8) []const u8 {
    return switch (op) {
        op_read => "r",
        op_write => "w",
        op_unset => "u",
        else => "a",
    };
}

/// Runs `cmd word...` in the current frame. Keeps the result of the
/// interpreter. Returns the error message of the script, or null.
fn runHook(it: *Interp, cmd: Value, words: []const []const u8) Error!?[]const u8 {
    const a = it.alloc();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, try it.str(cmd));
    for (words) |w| {
        try text.append(a, ' ');
        try value.appendElement(a, &text, w, true);
    }
    const saved = it.result;
    const saved_code = it.error_code;
    const saved_in = it.in_error;
    const saved_info = it.error_info;
    const saved_skip = it.skip_info;
    it.in_error = false;
    it.error_info = .empty;
    defer {
        it.in_error = saved_in;
        it.error_info = saved_info;
        it.skip_info = saved_skip;
    }
    const script = try it.compile(text.items);
    _ = it.evalScript(script) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.TclError => {
            const msg = try it.str(it.result);
            if (it.step_limit == 0 or it.overLimit()) return e;
            it.result = saved;
            it.error_code = saved_code;
            return msg;
        },
        else => {},
    };
    it.result = saved;
    it.error_code = saved_code;
    return null;
}

/// Runs the traces of an operation, newest first.
fn fire(it: *Interp, t: *Traced, name: []const u8, idx: ?[]const u8, op: u8) Error!?[]const u8 {
    // The name of an element link applies to this event only. A script
    // that the trace runs starts with no such name.
    const shown = it.trace_shown;
    it.trace_shown = null;
    if (t.busy) return null;
    t.busy = true;
    defer t.busy = false;
    try cmds.chargeEntries(it, t.list.items.len);
    const snapshot = try it.alloc().dupe(VarTrace, t.list.items);
    const changes = t.changes;
    var meter: cmds.Meter = .{};
    for (snapshot) |tr| {
        if (tr.ops & op == 0) continue;
        if (tr.elem) |e| {
            const i = idx orelse continue;
            if (!eql(e, i)) continue;
        }
        // A trace can remove a later trace of the same variable. With no
        // change of the list, each trace of the snapshot is still there.
        if (t.changes != changes) {
            try meter.add(it, t.list.items.len *| cmds.entry_units);
            if (!still(t, tr)) continue;
        }
        if (tr.flag) |f| {
            f.* = true;
            continue;
        }
        const word = if (tr.old != null) oldLetter(op) else opName(op);
        if (try runHook(it, tr.cmd, &.{ shown orelse name, if (shown != null) "" else idx orelse "", word })) |msg| return msg;
    }
    return null;
}

fn still(t: *const Traced, tr: VarTrace) bool {
    for (t.list.items) |x| {
        if (x.ops == tr.ops and std.meta.eql(x.cmd, tr.cmd) and (x.old == null) == (tr.old == null)) return true;
    }
    return false;
}

fn fullName(it: *Interp, name: []const u8, idx: ?[]const u8) Error![]const u8 {
    if (idx) |i| return std.fmt.allocPrint(it.alloc(), "{s}({s})", .{ name, i });
    return name;
}

// ---- The variable operations of the interpreter ----

pub fn read(it: *Interp, cell: *Var, name: []const u8, idx: ?[]const u8) Error!Value {
    const t = cell.v.traced;
    // An element of a variable that is not an array has no trace to run.
    if (idx != null and t.inner != .arr) return peek(it, cell, name, idx);
    if (try fire(it, t, name, idx, op_read)) |msg| {
        return it.fail("can't read \"{s}\": {s}", .{ try fullName(it, name, idx), msg });
    }
    return peek(it, cell, name, idx);
}

/// The value after the traces, with no trace run.
fn peek(it: *Interp, cell: *Var, name: []const u8, idx: ?[]const u8) Error!Value {
    if (cell.v != .traced) {
        if (idx) |i| {
            if (cell.v == .arr) {
                if (cell.v.arr.get(i)) |v| return v;
                return it.fail("can't read \"{s}({s})\": no such element in array", .{ name, i });
            }
            return it.fail("can't read \"{s}({s})\": no such variable", .{ name, i });
        }
        if (cell.v == .val) return cell.v.val;
        if (cell.v == .arr) return it.fail("can't read \"{s}\": variable is array", .{name});
        return it.fail("can't read \"{s}\": no such variable", .{name});
    }
    const t = cell.v.traced;
    if (idx) |i| switch (t.inner) {
        .arr => |m| {
            if (m.get(i)) |v| return v;
            return it.fail("can't read \"{s}({s})\": no such element in array", .{ name, i });
        },
        .val => return it.fail("can't read \"{s}({s})\": variable isn't array", .{ name, i }),
        .undef => return it.fail("can't read \"{s}({s})\": no such variable", .{ name, i }),
    };
    return switch (t.inner) {
        .val => |v| v,
        .arr => it.fail("can't read \"{s}\": variable is array", .{name}),
        .undef => it.fail("can't read \"{s}\": no such variable", .{name}),
    };
}

/// A read for `incr`, `append`, and `lappend`: an unset name gives null.
pub fn readOpt(it: *Interp, cell: *Var, name: []const u8, idx: ?[]const u8) Error!?Value {
    const t = cell.v.traced;
    if (try fire(it, t, name, idx, op_read)) |msg| {
        return it.fail("can't read \"{s}\": {s}", .{ try fullName(it, name, idx), msg });
    }
    if (cell.v != .traced) return null;
    return switch (t.inner) {
        .val => |v| if (idx == null) v else null,
        .arr => |m| if (idx) |i| m.get(i) else null,
        .undef => null,
    };
}

pub fn write(it: *Interp, cell: *Var, name: []const u8, idx: ?[]const u8, v: Value) Error!void {
    const t = cell.v.traced;
    if (idx) |i| {
        switch (t.inner) {
            .undef => {
                const m = try it.alloc().create(interp.ArrayMap);
                m.* = .empty;
                t.inner = .{ .arr = m };
            },
            .arr => {},
            .val => return it.fail("can't set \"{s}({s})\": variable isn't array", .{ name, i }),
        }
        const gop = try t.inner.arr.getOrPut(it.alloc(), i);
        if (!gop.found_existing) gop.key_ptr.* = try it.alloc().dupe(u8, i);
        gop.value_ptr.* = v;
    } else {
        if (t.inner == .arr) return it.fail("can't set \"{s}\": variable is array", .{name});
        const old = t.inner;
        t.inner = .{ .val = v };
        if (t.precision) try setPrecision(it, t, old, v);
    }
    if (try fire(it, t, name, idx, op_write)) |msg| {
        return it.fail("can't set \"{s}\": {s}", .{ try fullName(it, name, idx), msg });
    }
}

/// The value of a traced variable after a write, for the result of `set`.
pub fn after(it: *Interp, cell: *Var, name: []const u8, idx: ?[]const u8) Error!Value {
    return peek(it, cell, name, idx);
}

pub fn unset(it: *Interp, cell: *Var, name: []const u8, idx: ?[]const u8) Error!bool {
    const t = cell.v.traced;
    if (t.precision) return true;
    if (idx) |i| {
        if (t.inner != .arr) return false;
        if (!t.inner.arr.orderedRemove(i)) return false;
        // The traces of the element go away before they run. The first
        // pass can fail, and it changes no state. The second pass keeps the
        // other traces in one pass.
        try cmds.chargeEntries(it, t.list.items.len);
        var gone: Traced = .{ .inner = .undef };
        for (t.list.items) |tr| {
            if (tr.elem == null or eql(tr.elem.?, i)) try gone.list.append(it.alloc(), tr);
        }
        var keep: usize = 0;
        for (t.list.items) |tr| {
            if (tr.elem != null and eql(tr.elem.?, i)) continue;
            t.list.items[keep] = tr;
            keep += 1;
        }
        if (keep != t.list.items.len) t.changes +%= 1;
        t.list.shrinkRetainingCapacity(keep);
        _ = try fire(it, &gone, name, i, op_unset);
        return true;
    }
    const existed = t.inner != .undef;
    // All traces go away before they run. A trace can add a new one.
    var gone: Traced = .{ .inner = t.inner };
    gone.list = t.list;
    t.list = .empty;
    t.changes +%= 1;
    t.inner = .undef;
    drop(it, cell);
    gone.inner = .undef;
    _ = try fire(it, &gone, name, null, op_unset);
    return existed;
}

/// Removes the traces of a cell. The cell keeps its value.
fn drop(it: *Interp, cell: *Var) void {
    if (cell.v != .traced) return;
    const t = cell.v.traced;
    if (t.precision) return;
    switch (t.inner) {
        .undef => cell.v = .undef,
        .val => |v| cell.v = .{ .val = v },
        .arr => |m| cell.v = .{ .arr = m },
    }
    it.var_traces -= 1;
    it.epoch += 1;
}

/// Runs the unset traces of the locals of a frame that ends.
pub fn frameGone(it: *Interp, f: *interp.Frame) void {
    for (f.vars.items) |e| {
        if (e.cell.v != .traced) continue;
        const t = e.cell.v.traced;
        if (t.inner != .undef) {
            t.inner = .undef;
            _ = fire(it, t, e.name, null, op_unset) catch {};
        }
        drop(it, e.cell);
    }
}

/// Runs the `array` traces of a variable.
pub fn arrayOp(it: *Interp, cell: *Var, name: []const u8) Error!void {
    const t = cell.v.traced;
    if (try fire(it, t, name, null, op_array)) |msg| {
        return it.fail("can't trace array \"{s}\": {s}", .{ name, msg });
    }
}

// ---- The command ----

fn parseVarOps(it: *Interp, v: Value) Error!u8 {
    const words = try it.list(v);
    if (words.len == 0) return it.fail("bad operation list \"\": must be one or more of array, read, unset, or write", .{});
    var ops: u8 = 0;
    for (words) |w| {
        const s = try it.str(w);
        if (eql(s, "read")) {
            ops |= op_read;
        } else if (eql(s, "write")) {
            ops |= op_write;
        } else if (eql(s, "unset")) {
            ops |= op_unset;
        } else if (eql(s, "array")) {
            ops |= op_array;
        } else return it.failCode("TCL LOOKUP INDEX operation", "bad operation \"{s}\": must be array, read, unset, or write", .{s});
    }
    return ops;
}

fn parseOldOps(it: *Interp, text: []const u8) Error!u8 {
    var ops: u8 = 0;
    if (text.len == 0) return it.fail("bad operations \"\": should be one or more of rwua", .{});
    for (text) |c| {
        ops |= switch (c) {
            'r' => op_read,
            'w' => op_write,
            'u' => op_unset,
            'a' => op_array,
            else => return it.fail("bad operations \"{s}\": should be one or more of rwua", .{text}),
        };
    }
    return ops;
}

/// The cell and index that a trace on `name` applies to. A name that is
/// an element link (`upvar a(i) x`) means that element of the array.
const Target = struct { cell: *Var, idx: ?[]const u8 };

fn targetOf(it: *Interp, name: []const u8, make: bool) Error!?Target {
    const base, const idx = Interp.splitName(name);
    const cell = try it.findVar(it.frame, base, make) orelse return null;
    if (idx == null and cell.v == .elem) return .{ .cell = cell.v.elem.array, .idx = cell.v.elem.index };
    return .{ .cell = cell, .idx = idx };
}

fn tracedOf(it: *Interp, cell: *Var) Error!*Traced {
    if (cell.v == .traced) return cell.v.traced;
    const t = try it.alloc().create(Traced);
    t.* = .{};
    switch (cell.v) {
        .val => |v| t.inner = .{ .val = v },
        .owned => |v| t.inner = .{ .val = v },
        .arr => |m| t.inner = .{ .arr = m },
        else => {},
    }
    cell.v = .{ .traced = t };
    it.var_traces += 1;
    it.epoch += 1;
    return t;
}

fn opsList(it: *Interp, ops: u8) Error!Value {
    var out: std.ArrayList(Value) = .empty;
    const a = it.alloc();
    if (ops & op_array != 0) try out.append(a, .{ .str = "array" });
    if (ops & op_read != 0) try out.append(a, .{ .str = "read" });
    if (ops & op_write != 0) try out.append(a, .{ .str = "write" });
    if (ops & op_unset != 0) try out.append(a, .{ .str = "unset" });
    return value.wrapList(a, out.items);
}

fn varInfo(it: *Interp, name: []const u8, old_form: bool) Error!Value {
    const a = it.alloc();
    const target = try targetOf(it, name, false) orelse return Value.empty;
    const cell = target.cell;
    const idx = target.idx;
    if (cell.v != .traced) return Value.empty;
    var out: std.ArrayList(Value) = .empty;
    for (cell.v.traced.list.items) |tr| {
        if (idx) |i| {
            if (tr.elem == null or !eql(tr.elem.?, i)) continue;
        } else if (tr.elem != null) continue;
        if (tr.flag != null) continue;
        if (old_form != (tr.old != null)) {
            if (old_form) continue;
        }
        const ops: Value = if (old_form) .{ .str = tr.old.? } else try opsList(it, tr.ops);
        try out.append(a, try value.newList(a, &.{ ops, tr.cmd }));
    }
    return value.wrapList(a, out.items);
}

fn varRemove(it: *Interp, name: []const u8, ops: u8, cmd: Value, old: bool) Error!void {
    const target = try targetOf(it, name, false) orelse return;
    const cell = target.cell;
    const idx = target.idx;
    if (cell.v != .traced) return;
    const t = cell.v.traced;
    const text = try it.str(cmd);
    try cmds.chargeEntries(it, t.list.items.len);
    for (t.list.items, 0..) |tr, k| {
        if (tr.ops != ops or (tr.old != null) != old) continue;
        if ((tr.elem == null) != (idx == null)) continue;
        if (idx) |i| if (!eql(tr.elem.?, i)) continue;
        if (!eql(try it.str(tr.cmd), text)) continue;
        _ = t.list.orderedRemove(k);
        t.changes +%= 1;
        break;
    }
    if (t.list.items.len == 0) drop(it, cell);
}

fn varAdd(it: *Interp, name: []const u8, ops: u8, cmd: Value, old: ?[]const u8) Error!void {
    const target = (try targetOf(it, name, true)).?;
    const t = try tracedOf(it, target.cell);
    const copy: ?[]const u8 = if (target.idx) |i| try it.alloc().dupe(u8, i) else null;
    // The insert moves each trace of the list.
    try cmds.chargeEntries(it, t.list.items.len);
    try t.list.insert(it.alloc(), 0, .{ .ops = ops, .cmd = cmd, .elem = copy, .old = old });
    t.changes +%= 1;
}

/// Adds the trace of `vwait` to a variable of the current frame.
pub fn addFlag(it: *Interp, name: []const u8, flag: *bool) Error!void {
    const base, const idx = Interp.splitName(name);
    if (idx != null) {
        if (try it.findVar(it.frame, base, false)) |cell| {
            const scalar = switch (cell.target().v) {
                .val, .owned => true,
                .traced => |t| t.inner == .val,
                else => false,
            };
            if (scalar) return it.fail("can't trace \"{s}\": variable isn't array", .{name});
        }
    }
    const target = (try targetOf(it, name, true)).?;
    const t = try tracedOf(it, target.cell);
    const copy: ?[]const u8 = if (target.idx) |i| try it.alloc().dupe(u8, i) else null;
    try t.list.insert(it.alloc(), 0, .{ .ops = op_write | op_unset, .cmd = Value.empty, .elem = copy, .flag = flag });
    t.changes +%= 1;
}

pub fn removeFlag(it: *Interp, name: []const u8, flag: *bool) void {
    const target = (targetOf(it, name, false) catch return) orelse return;
    const cell = target.cell;
    if (cell.v != .traced) return;
    const t = cell.v.traced;
    for (t.list.items, 0..) |tr, k| {
        if (tr.flag == flag) {
            _ = t.list.orderedRemove(k);
            t.changes +%= 1;
            break;
        }
    }
    if (t.list.items.len == 0) drop(it, cell);
}

fn traceData(it: *Interp, c: *interp.Command) Error!*CmdTraces {
    if (c.traces) |t| return t;
    const t = try it.alloc().create(CmdTraces);
    t.* = .{};
    c.traces = t;
    return t;
}

fn parseCmdOps(it: *Interp, v: Value) Error!u8 {
    const words = try it.list(v);
    if (words.len == 0) return it.fail("bad operation list \"\": must be one or more of delete or rename", .{});
    var ops: u8 = 0;
    for (words) |w| {
        const s = try it.str(w);
        if (eql(s, "rename")) {
            ops |= 1;
        } else if (eql(s, "delete")) {
            ops |= 2;
        } else return it.failCode("TCL LOOKUP INDEX operation", "bad operation \"{s}\": must be delete or rename", .{s});
    }
    return ops;
}

fn parseExecOps(it: *Interp, v: Value) Error!u8 {
    const words = try it.list(v);
    if (words.len == 0) return it.fail("bad operation list \"\": must be one or more of enter, leave, enterstep, or leavestep", .{});
    var ops: u8 = 0;
    for (words) |w| {
        const s = try it.str(w);
        if (eql(s, "enter")) {
            ops |= 1;
        } else if (eql(s, "leave")) {
            ops |= 2;
        } else if (eql(s, "enterstep")) {
            ops |= 4;
        } else if (eql(s, "leavestep")) {
            ops |= 8;
        } else return it.failCode("TCL LOOKUP INDEX operation", "bad operation \"{s}\": must be enter, leave, enterstep, or leavestep", .{s});
    }
    return ops;
}

fn cmdOpsList(it: *Interp, ops: u8, exec: bool) Error!Value {
    var out: std.ArrayList(Value) = .empty;
    const a = it.alloc();
    if (exec) {
        if (ops & 1 != 0) try out.append(a, .{ .str = "enter" });
        if (ops & 2 != 0) try out.append(a, .{ .str = "leave" });
        if (ops & 4 != 0) try out.append(a, .{ .str = "enterstep" });
        if (ops & 8 != 0) try out.append(a, .{ .str = "leavestep" });
    } else {
        if (ops & 1 != 0) try out.append(a, .{ .str = "rename" });
        if (ops & 2 != 0) try out.append(a, .{ .str = "delete" });
    }
    return value.wrapList(a, out.items);
}

fn needCommand(it: *Interp, name: []const u8) Error!*interp.Command {
    return it.findCommand(name) orelse it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP COMMAND {s}", .{name}), "unknown command \"{s}\"", .{name});
}

/// The wrapper of a command with an execution trace.
fn execCall(it: *Interp, argv: []const Value, c: ?*Cmd) Error!Value {
    const self = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name \"{s}\"", .{try it.str(argv[0])});
    const t = self.traces.?;
    const under: interp.Command = .{ .name = self.name, .impl = t.orig.?, .ctx = self.ctx };
    var inner = under;
    if (t.busy) return it.call(&inner, argv, c);
    const a = it.alloc();
    const text = try value.listToString(a, argv);
    try cmds.chargeEntries(it, t.execs.items.len);
    const snapshot = try a.dupe(ExecTrace, t.execs.items);
    t.busy = true;
    for (snapshot) |tr| {
        if (tr.ops & 1 == 0) continue;
        if (try runHook(it, tr.cmd, &.{ text, "enter" })) |msg| {
            t.busy = false;
            return it.fail("{s}", .{msg});
        }
    }
    t.busy = false;
    var code: i64 = 0;
    var failure: ?Error = null;
    var out: Value = Value.empty;
    if (it.call(&inner, argv, c)) |v| {
        out = v;
        it.result = v;
    } else |e| {
        failure = e;
        code = switch (e) {
            error.TclError => 1,
            error.TclReturn => 2,
            error.TclBreak => 3,
            error.TclContinue => 4,
            error.TclCustom => it.custom_code,
            else => return e,
        };
    }
    const res_text = try it.str(it.result);
    const code_text = try std.fmt.allocPrint(a, "{d}", .{code});
    t.busy = true;
    for (snapshot) |tr| {
        if (tr.ops & 2 == 0) continue;
        if (try runHook(it, tr.cmd, &.{ text, code_text, res_text, "leave" })) |msg| {
            t.busy = false;
            return it.fail("{s}", .{msg});
        }
    }
    t.busy = false;
    if (failure) |e| return e;
    return out;
}

/// Runs the rename or delete traces of a command.
pub fn commandEvent(it: *Interp, c: *interp.Command, old: []const u8, new: []const u8, bit: u8) Error!void {
    const t = c.traces orelse return;
    if (t.busy) return;
    t.busy = true;
    defer t.busy = false;
    const a = it.alloc();
    const old_full = try std.fmt.allocPrint(a, "::{s}", .{std.mem.trimStart(u8, old, ":")});
    const new_full = if (new.len == 0) "" else try std.fmt.allocPrint(a, "::{s}", .{std.mem.trimStart(u8, new, ":")});
    try cmds.chargeEntries(it, t.cmds.items.len);
    const snapshot = try a.dupe(ExecTrace, t.cmds.items);
    for (snapshot) |tr| {
        if (tr.ops & bit == 0) continue;
        _ = try runHook(it, tr.cmd, &.{ old_full, new_full, if (bit == 1) "rename" else "delete" });
    }
}

pub fn cmdTrace(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("trace option ?arg ...?");
    const a = it.alloc();
    const sub = try it.str(argv[1]);
    const Sub = enum { add, info, remove, variable, vdelete, vinfo };
    var which: ?Sub = std.meta.stringToEnum(Sub, sub);
    if (which == null and sub.len > 0) {
        var hits: usize = 0;
        inline for (@typeInfo(Sub).@"enum".field_names, @typeInfo(Sub).@"enum".field_values) |f_name, f_value| {
            if (std.mem.startsWith(u8, f_name, sub)) {
                which = @fromBackingInt(@intCast(f_value));
                hits += 1;
            }
        }
        if (hits != 1) which = null;
    }
    const op = which orelse return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be add, info, remove, variable, vdelete, or vinfo", .{sub});
    switch (op) {
        .variable => {
            if (argv.len != 5) return it.wrongArgs("trace variable name ops command");
            const text = try it.str(argv[3]);
            try varAdd(it, try it.str(argv[2]), try parseOldOps(it, text), argv[4], text);
            return Value.empty;
        },
        .vdelete => {
            if (argv.len != 5) return it.wrongArgs("trace vdelete name ops command");
            try varRemove(it, try it.str(argv[2]), try parseOldOps(it, try it.str(argv[3])), argv[4], true);
            return Value.empty;
        },
        .vinfo => {
            if (argv.len != 3) return it.wrongArgs("trace vinfo name");
            return varInfo(it, try it.str(argv[2]), true);
        },
        else => {},
    }
    if (argv.len < 3) {
        return switch (op) {
            .add => it.wrongArgs("trace add type ?arg ...?"),
            .remove => it.wrongArgs("trace remove type ?arg ...?"),
            else => it.wrongArgs("trace info type name"),
        };
    }
    const type_word = try it.str(argv[2]);
    const Kind = enum { command, execution, variable };
    var kind: ?Kind = std.meta.stringToEnum(Kind, type_word);
    if (kind == null and type_word.len > 0) {
        inline for (@typeInfo(Kind).@"enum".field_names, @typeInfo(Kind).@"enum".field_values) |f_name, f_value| {
            if (std.mem.startsWith(u8, f_name, type_word)) kind = @fromBackingInt(@intCast(f_value));
        }
    }
    const k = kind orelse return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be execution, command, or variable", .{type_word});
    if (op == .info) {
        if (argv.len != 4) {
            return switch (k) {
                .variable => it.wrongArgs("trace info variable name"),
                .command => it.wrongArgs("trace info command name"),
                .execution => it.wrongArgs("trace info execution name"),
            };
        }
        const name = try it.str(argv[3]);
        if (k == .variable) return varInfo(it, name, false);
        const c = try needCommand(it, name);
        const t = c.traces orelse return Value.empty;
        var out: std.ArrayList(Value) = .empty;
        for (if (k == .command) t.cmds.items else t.execs.items) |tr| {
            try out.append(a, try value.newList(a, &.{ try cmdOpsList(it, tr.ops, k == .execution), tr.cmd }));
        }
        return value.wrapList(a, out.items);
    }
    if (argv.len != 6) {
        if (op == .add) {
            return switch (k) {
                .variable => it.wrongArgs("trace add variable name opList command"),
                .command => it.wrongArgs("trace add command name opList command"),
                .execution => it.wrongArgs("trace add execution name opList command"),
            };
        }
        return switch (k) {
            .variable => it.wrongArgs("trace remove variable name opList command"),
            .command => it.wrongArgs("trace remove command name opList command"),
            .execution => it.wrongArgs("trace remove execution name opList command"),
        };
    }
    const name = try it.str(argv[3]);
    if (k == .variable) {
        const ops = try parseVarOps(it, argv[4]);
        if (op == .add) {
            try varAdd(it, name, ops, argv[5], null);
        } else try varRemove(it, name, ops, argv[5], false);
        return Value.empty;
    }
    const ops = if (k == .command) try parseCmdOps(it, argv[4]) else try parseExecOps(it, argv[4]);
    const c = try needCommand(it, name);
    const t = try traceData(it, c);
    const list = if (k == .command) &t.cmds else &t.execs;
    // An insert or a remove moves each trace of the list.
    try cmds.chargeEntries(it, list.items.len);
    if (op == .add) {
        try list.insert(a, 0, .{ .ops = ops, .cmd = argv[5] });
        if (k == .execution and t.orig == null) {
            t.orig = c.impl;
            c.impl = .{ .native = execCall };
            it.epoch += 1;
        }
    } else {
        const text = try it.str(argv[5]);
        for (list.items, 0..) |tr, i| {
            if (tr.ops == ops and eql(try it.str(tr.cmd), text)) {
                _ = list.orderedRemove(i);
                break;
            }
        }
        if (k == .execution and t.execs.items.len == 0 and t.orig != null) {
            c.impl = t.orig.?;
            t.orig = null;
            it.epoch += 1;
        }
    }
    return Value.empty;
}

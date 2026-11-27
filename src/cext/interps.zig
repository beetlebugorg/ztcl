//! The slots of the area interps and commands of the stubs table of Tcl
//! 8.6: command tokens, command traces, math functions, child interps,
//! aliases, hidden commands, limits, and the procs of interp deletion.
//! The native path (`stubs.zig`) and the WebAssembly path
//! (`wasm_stubs.zig`) use this one file. The slots of `Tcl_CreateInterp`,
//! `Tcl_CreateCommand`, and the command info are in `app.zig`.
//!
//! A token of a command of ztcl is a `host.Command` with no function. Its
//! name is the full name from `namespace which`, and the token keeps that
//! name after a rename. A command trace is a hidden command of the
//! package and a `trace add command` of ztcl, as the variable traces of
//! `vars.zig`. A math function is the command `tcl::mathfunc::NAME`
//! that converts its arguments to `Tcl_Value`s.
//!
//! The interp tree goes through `host.interp_op` (`zside.interpOp`): an
//! interp of ztcl has a handle, and `host.interpFor` gives the interp of
//! the package for a handle. `Tcl_CreateSlave` runs `interp create`, so
//! it needs the capability `interp`.
//!
//! A limit is state of this file. `Tcl_LimitCheck` and `Tcl_LimitReady`
//! follow Tcl with the granularity ticker, the handlers (newest first),
//! and the command count of `info cmdcount`. A script of ztcl does not
//! call the check, so a limit stops a script only through the calls of
//! the package.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const obj = @import("obj.zig");
const host = @import("host.zig");
const regexp = @import("regexp.zig");

const Obj = obj.Obj;
const Interp = obj.Interp;
const Command = host.Command;
const InterpOp = host.InterpOp;
const OK = obj.OK;
const ERROR = obj.ERROR;
const gpa = std.heap.c_allocator;
const panicText = obj.panicText;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();

const GLOBAL_ONLY: c_int = 1;
const LEAVE_ERR_MSG: c_int = 0x200;
const TRACE_DESTROYED: c_int = 0x80;
const TRACE_RENAME: c_int = 0x2000;
const TRACE_DELETE: c_int = 0x4000;

fn oom() noreturn {
    panicText("out of memory");
}

fn word(list: *std.ArrayList(*Obj), s: []const u8) void {
    push(list, obj.Tcl_NewStringObj(s.ptr, @intCast(s.len)));
}

fn push(list: *std.ArrayList(*Obj), o: *Obj) void {
    obj.incr(o);
    list.append(gpa, o) catch oom();
}

/// Evaluates the words of `list`, and frees them. Gives the result with
/// a reference, or null after an error, with the message in the result
/// of `ip` when `keep_err`.
fn evalWords(ip: *Interp, list: *std.ArrayList(*Obj), keep_err: bool) ?*Obj {
    const saved = obj.result(ip);
    obj.incr(saved);
    defer obj.decr(saved);
    var r: ?*Obj = null;
    if (regexp.run(ip, list, &r) != OK) {
        if (!keep_err) obj.Tcl_SetObjResult(ip, saved);
        return null;
    }
    return r;
}

fn hiddenNamespace(ip: *Interp) void {
    var ns: std.ArrayList(*Obj) = .empty;
    for ([_][]const u8{ "::namespace", "eval", "::tcl::cext", "" }) |w| word(&ns, w);
    if (evalWords(ip, &ns, false)) |o| obj.decr(o);
}

// ---- Command tokens ----

/// The tokens of the commands of ztcl that `Tcl_FindCommand` gave.
threadlocal var foreign: std.ArrayList(*Command) = .empty;

/// The names with a NUL of `Tcl_GetCommandName`, by token.
const Name = struct { c: *Command, z: [:0]u8 };
threadlocal var names: std.ArrayList(Name) = .empty;

/// `name` with `::` in front.
fn fullOf(buf: *std.ArrayList(u8), name: []const u8) []const u8 {
    buf.clearRetainingCapacity();
    if (!std.mem.startsWith(u8, name, "::")) buf.appendSlice(gpa, "::") catch oom();
    buf.appendSlice(gpa, name) catch oom();
    return buf.items;
}

/// `fullName` of a `Tcl_Namespace`: the second field of the struct.
const Namespace = extern struct { name: [*:0]const u8, full_name: [*:0]const u8 };

pub fn Tcl_FindCommand(ip: *Interp, name: [*:0]const u8, ns: ?*const Namespace, flags: c_int) callconv(.c) ?*Command {
    const n = std.mem.span(name);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var list: std.ArrayList(*Obj) = .empty;
    if (ns != null and flags & GLOBAL_ONLY == 0) {
        // `namespace which` in the namespace of the caller.
        var inner: std.ArrayList(*Obj) = .empty;
        defer {
            for (inner.items) |o| obj.decr(o);
            inner.deinit(gpa);
        }
        for ([_][]const u8{ "::namespace", "which", "-command", n }) |w| word(&inner, w);
        word(&list, "::namespace");
        word(&list, "eval");
        word(&list, std.mem.span(ns.?.full_name));
        push(&list, obj.Tcl_NewListObj(@intCast(inner.items.len), inner.items.ptr));
    } else {
        for ([_][]const u8{ "::namespace", "which", "-command", if (flags & GLOBAL_ONLY != 0) fullOf(&buf, n) else n }) |w| word(&list, w);
    }
    const r = evalWords(ip, &list, false) orelse return null;
    defer obj.decr(r);
    const full = obj.text(r);
    if (full.len == 0) {
        if (flags & LEAVE_ERR_MSG != 0) {
            const msg = std.fmt.allocPrint(gpa, "unknown command \"{s}\"", .{n}) catch oom();
            defer gpa.free(msg);
            obj.setResultText(ip, msg);
        }
        return null;
    }
    for (host.commands.items) |c| {
        if (c.live and c.interp == ip and std.mem.eql(u8, fullOf(&buf, c.name), full)) return c;
    }
    for (foreign.items) |c| {
        if (c.live and c.interp == ip and std.mem.eql(u8, c.name, full)) return c;
    }
    const c = gpa.create(Command) catch oom();
    c.* = .{ .proc = null, .nre = null, .cd = null, .delete = null, .interp = ip, .name = gpa.dupe(u8, full) catch oom() };
    foreign.append(gpa, c) catch oom();
    return c;
}

pub fn Tcl_GetCommandFromObj(ip: *Interp, o: *Obj) callconv(.c) ?*Command {
    const s = gpa.dupeSentinel(u8, obj.text(o), 0) catch oom();
    defer gpa.free(s);
    return Tcl_FindCommand(ip, s.ptr, null, 0);
}

/// The name of the token in its namespace, as in Tcl.
pub fn Tcl_GetCommandName(_: *Interp, c: *Command) callconv(.c) [*:0]const u8 {
    const tail = if (std.mem.lastIndexOf(u8, c.name, "::")) |i| c.name[i + 2 ..] else c.name;
    for (names.items) |*e| {
        if (e.c == c) {
            if (!std.mem.eql(u8, e.z, tail)) {
                gpa.free(e.z);
                e.z = gpa.dupeSentinel(u8, tail, 0) catch oom();
            }
            return e.z.ptr;
        }
    }
    const z = gpa.dupeSentinel(u8, tail, 0) catch oom();
    names.append(gpa, .{ .c = c, .z = z }) catch oom();
    return z.ptr;
}

pub fn Tcl_GetCommandFullName(_: *Interp, c: *Command, o: *Obj) callconv(.c) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const full = fullOf(&buf, c.name);
    obj.Tcl_AppendToObj(o, full.ptr, @intCast(full.len));
}

// ---- Command traces ----

pub const CommandTraceProc = *const fn (?*anyopaque, *Interp, ?[*:0]const u8, ?[*:0]const u8, c_int) callconv(.c) void;

const Trace = struct {
    ip: *Interp,
    /// The full name of the command, which follows its renames.
    name: []u8,
    flags: c_int,
    proc: CommandTraceProc,
    cd: ?*anyopaque,
    cmd: [:0]u8,
    live: bool = true,
    busy: bool = false,
};

threadlocal var ctraces: std.ArrayList(*Trace) = .empty;
threadlocal var next_trace: u32 = 0;

fn freeTrace(t: *Trace) void {
    gpa.free(t.name);
    gpa.free(t.cmd);
    gpa.destroy(t);
}

/// Frees the records of the traces that a delete ended.
fn sweep() void {
    var i = ctraces.items.len;
    while (i > 0) {
        i -= 1;
        const t = ctraces.items[i];
        if (t.live or t.busy) continue;
        _ = host.Tcl_DeleteCommand(t.ip, t.cmd[2..].ptr);
        _ = ctraces.orderedRemove(i);
        freeTrace(t);
    }
}

fn traceOps(flags: c_int) []const u8 {
    if (flags & TRACE_RENAME != 0 and flags & TRACE_DELETE != 0) return "rename delete";
    return if (flags & TRACE_RENAME != 0) "rename" else "delete";
}

fn commandTraceCmd(cd: ?*anyopaque, ip: *Interp, objc: c_int, objv: [*]const *Obj) callconv(.c) c_int {
    const t: *Trace = @ptrCast(@alignCast(cd.?));
    if (!t.live or objc < 4) return OK;
    const old = gpa.dupeSentinel(u8, obj.text(objv[1]), 0) catch oom();
    defer gpa.free(old);
    const new = gpa.dupeSentinel(u8, obj.text(objv[2]), 0) catch oom();
    defer gpa.free(new);
    const del = std.mem.eql(u8, obj.text(objv[3]), "delete");
    var flags: c_int = if (del) TRACE_DELETE else TRACE_RENAME;
    if (del) {
        // A delete removes the trace in ztcl too.
        flags |= TRACE_DESTROYED;
        t.live = false;
    } else {
        gpa.free(t.name);
        t.name = gpa.dupe(u8, new) catch oom();
    }
    t.busy = true;
    t.proc(t.cd, ip, old.ptr, if (del) null else new.ptr, flags);
    t.busy = false;
    return OK;
}

fn commandTraceWords(list: *std.ArrayList(*Obj), t: *Trace, sub: []const u8) void {
    for ([_][]const u8{ "::trace", sub, "command", t.name, traceOps(t.flags), t.cmd }) |w| word(list, w);
}

pub fn Tcl_TraceCommand(ip: *Interp, name: [*:0]const u8, flags: c_int, proc: CommandTraceProc, cd: ?*anyopaque) callconv(.c) c_int {
    sweep();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const t = gpa.create(Trace) catch oom();
    t.* = .{
        .ip = ip,
        .name = gpa.dupe(u8, fullOf(&buf, std.mem.span(name))) catch oom(),
        .flags = flags,
        .proc = proc,
        .cd = cd,
        .cmd = std.fmt.allocPrintSentinel(gpa, "::tcl::cext::ctrace{d}", .{next_trace}, 0) catch oom(),
    };
    next_trace += 1;
    hiddenNamespace(ip);
    // The table of commands has the name with no `::` in front.
    _ = host.createCommand(ip, t.cmd[2..].ptr, &commandTraceCmd, null, t, null);
    var list: std.ArrayList(*Obj) = .empty;
    commandTraceWords(&list, t, "add");
    const r = evalWords(ip, &list, true) orelse {
        _ = host.Tcl_DeleteCommand(ip, t.cmd[2..].ptr);
        // The message of `trace` names the full name. Tcl names the name
        // as the package gave it.
        const msg = std.fmt.allocPrint(gpa, "unknown command \"{s}\"", .{std.mem.span(name)}) catch oom();
        defer gpa.free(msg);
        obj.setResultText(ip, msg);
        freeTrace(t);
        return ERROR;
    };
    obj.decr(r);
    ctraces.append(gpa, t) catch oom();
    return OK;
}

fn sameTrace(t: *Trace, ip: *Interp, name: [*:0]const u8, buf: *std.ArrayList(u8)) bool {
    return t.live and t.ip == ip and std.mem.eql(u8, t.name, fullOf(buf, std.mem.span(name)));
}

pub fn Tcl_UntraceCommand(ip: *Interp, name: [*:0]const u8, flags: c_int, proc: CommandTraceProc, cd: ?*anyopaque) callconv(.c) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const mask = TRACE_RENAME | TRACE_DELETE;
    for (ctraces.items) |t| {
        if (!sameTrace(t, ip, name, &buf) or t.proc != proc or t.cd != cd or t.flags & mask != flags & mask) continue;
        var list: std.ArrayList(*Obj) = .empty;
        commandTraceWords(&list, t, "remove");
        if (evalWords(ip, &list, false)) |o| obj.decr(o);
        t.live = false;
        break;
    }
    sweep();
}

pub fn Tcl_CommandTraceInfo(ip: *Interp, name: [*:0]const u8, _: c_int, proc: CommandTraceProc, prev: ?*anyopaque) callconv(.c) ?*anyopaque {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var seen = prev == null;
    // The newest trace comes first, as in Tcl.
    var i = ctraces.items.len;
    while (i > 0) {
        i -= 1;
        const t = ctraces.items[i];
        if (!sameTrace(t, ip, name, &buf) or t.proc != proc) continue;
        if (seen) return t.cd;
        if (t.cd == prev) seen = true;
    }
    return null;
}

// ---- Math functions ----

const ValueType = enum(c_int) { int = 0, double = 1, either = 2, wide = 3, _ };

/// `Tcl_Value` of tcl.h.
const Value = extern struct {
    type: ValueType = .int,
    int_value: c_long = 0,
    double_value: f64 = 0,
    wide_value: i64 = 0,
};

pub const MathProc = *const fn (?*anyopaque, *Interp, [*]Value, *Value) callconv(.c) c_int;

const MathFunc = struct {
    ip: *Interp,
    name: [:0]u8,
    types: []ValueType,
    proc: MathProc,
    cd: ?*anyopaque,
};

threadlocal var funcs: std.ArrayList(*MathFunc) = .empty;

fn mathFail(ip: *Interp, comptime fmt: []const u8, name: []const u8) c_int {
    const msg = std.fmt.allocPrint(gpa, fmt, .{name}) catch oom();
    defer gpa.free(msg);
    obj.setResultText(ip, msg);
    return ERROR;
}

fn mathCmd(cd: ?*anyopaque, ip: *Interp, objc: c_int, objv: [*]const *Obj) callconv(.c) c_int {
    const f: *MathFunc = @ptrCast(@alignCast(cd.?));
    const n: usize = @intCast(objc - 1);
    if (n < f.types.len) return mathFail(ip, "not enough arguments for math function \"{s}\"", f.name);
    if (n > f.types.len) return mathFail(ip, "too many arguments for math function \"{s}\"", f.name);
    const args = gpa.alloc(Value, @max(n, 1)) catch oom();
    defer gpa.free(args);
    for (f.types, args, objv[1..][0..n]) |ty, *v, o| {
        var w: i64 = 0;
        var d: f64 = 0;
        const is_int = obj.Tcl_GetWideIntFromObj(null, o, &w) == OK;
        if (!is_int and obj.Tcl_GetDoubleFromObj(null, o, &d) != OK) {
            obj.setResultText(ip, "argument to math function didn't have numeric value");
            return ERROR;
        }
        if (is_int) d = @floatFromInt(w) else w = if (std.math.isFinite(d) and @abs(d) < 9.2e18) @intFromFloat(d) else 0;
        v.* = .{};
        switch (ty) {
            .double => v.* = .{ .type = .double, .double_value = d },
            .wide => v.* = .{ .type = .wide, .wide_value = w },
            .either => v.* = if (!is_int) .{ .type = .double, .double_value = d } else if (std.math.cast(c_long, w)) |l| .{ .type = .int, .int_value = l } else .{ .type = .wide, .wide_value = w },
            else => v.* = .{ .type = .int, .int_value = @truncate(w) },
        }
    }
    var res: Value = .{};
    if (f.proc(f.cd, ip, args.ptr, &res) != OK) return ERROR;
    obj.Tcl_SetObjResult(ip, switch (res.type) {
        .double => obj.Tcl_NewDoubleObj(res.double_value),
        .wide => obj.Tcl_NewWideIntObj(res.wide_value),
        else => obj.Tcl_NewWideIntObj(res.int_value),
    });
    return OK;
}

fn findFunc(ip: *Interp, name: []const u8) ?usize {
    for (funcs.items, 0..) |f, i| {
        if (f.ip == ip and std.mem.eql(u8, f.name, name)) return i;
    }
    return null;
}

pub fn Tcl_CreateMathFunc(ip: *Interp, name: [*:0]const u8, n: c_int, types: ?[*]const ValueType, proc: MathProc, cd: ?*anyopaque) callconv(.c) void {
    const nm = std.mem.span(name);
    if (findFunc(ip, nm)) |i| {
        const old = funcs.orderedRemove(i);
        gpa.free(old.name);
        gpa.free(old.types);
        gpa.destroy(old);
    }
    const count: usize = @intCast(@max(n, 0));
    const f = gpa.create(MathFunc) catch oom();
    f.* = .{ .ip = ip, .name = gpa.dupeSentinel(u8, nm, 0) catch oom(), .types = gpa.alloc(ValueType, count) catch oom(), .proc = proc, .cd = cd };
    if (count > 0) @memcpy(f.types, types.?[0..count]);
    funcs.append(gpa, f) catch oom();
    const cmd = std.fmt.allocPrintSentinel(gpa, "tcl::mathfunc::{s}", .{nm}, 0) catch oom();
    defer gpa.free(cmd);
    _ = host.createCommand(ip, cmd.ptr, &mathCmd, null, f, null);
}

pub fn Tcl_GetMathFuncInfo(ip: *Interp, name: [*:0]const u8, n: ?*c_int, types: ?*?[*]ValueType, proc: ?*?MathProc, cd: ?*?*anyopaque) callconv(.c) c_int {
    const nm = std.mem.span(name);
    if (findFunc(ip, nm)) |i| {
        const f = funcs.items[i];
        if (n) |p| p.* = @intCast(f.types.len);
        if (types) |p| p.* = f.types.ptr;
        if (proc) |p| p.* = f.proc;
        if (cd) |p| p.* = f.cd;
        return OK;
    }
    const all = Tcl_ListMathFuncs(ip, null) orelse return ERROR;
    obj.incr(all);
    defer obj.decr(all);
    var count: c_int = 0;
    var items: [*]*Obj = undefined;
    if (obj.Tcl_ListObjGetElements(null, all, &count, &items) != OK) return ERROR;
    for (items[0..@intCast(count)]) |e| {
        if (!std.mem.eql(u8, obj.text(e), nm)) continue;
        // A function that is not of Tcl_CreateMathFunc has no count.
        if (n) |p| p.* = -1;
        if (types) |p| p.* = null;
        if (proc) |p| p.* = null;
        if (cd) |p| p.* = null;
        return OK;
    }
    return mathFail(ip, "unknown math function \"{s}\"", nm);
}

pub fn Tcl_ListMathFuncs(ip: *Interp, pattern: ?[*:0]const u8) callconv(.c) ?*Obj {
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::info");
    word(&list, "functions");
    if (pattern) |p| word(&list, std.mem.span(p));
    const r = evalWords(ip, &list, true) orelse return null;
    // The caller gets the object with no reference.
    r.refCount -= 1;
    return r;
}

// ---- Process and misc ----

extern "c" fn setenv(name: [*:0]const u8, val: [*:0]const u8, overwrite: c_int) c_int;

pub fn Tcl_PutEnv(assignment: [*:0]const u8) callconv(.c) c_int {
    const s = std.mem.span(assignment);
    const eq = std.mem.indexOfScalar(u8, s, '=') orelse return 0;
    if (eq == 0) return 0;
    const name = gpa.dupeSentinel(u8, s[0..eq], 0) catch oom();
    defer gpa.free(name);
    const val = s[eq + 1 ..];
    _ = setenv(name.ptr, @ptrCast(val.ptr), 1);
    // The array `env` of ztcl, when the interp has one.
    const ip = @import("chan.zig").last orelse return 0;
    var list: std.ArrayList(*Obj) = .empty;
    for ([_][]const u8{ "::array", "exists", "::env" }) |w| word(&list, w);
    const r = evalWords(ip, &list, false) orelse return 0;
    defer obj.decr(r);
    if (!std.mem.eql(u8, obj.text(r), "1")) return 0;
    const key = std.fmt.allocPrint(gpa, "::env({s})", .{name}) catch oom();
    defer gpa.free(key);
    var set: std.ArrayList(*Obj) = .empty;
    for ([_][]const u8{ "::set", key, val }) |w| word(&set, w);
    if (evalWords(ip, &set, false)) |o| obj.decr(o);
    return 0;
}

var host_name: [256:0]u8 = @splat(0);

/// The node name of the host. WASI has none, so the WebAssembly path
/// gives "localhost".
pub fn Tcl_GetHostName() callconv(.c) [*:0]const u8 {
    if (host_name[0] == 0) {
        const n: []const u8 = if (builtin.os.tag == .wasi or builtin.os.tag == .freestanding) "localhost" else blk: {
            const u = std.posix.uname();
            break :blk std.mem.sliceTo(&u.nodename, 0);
        };
        const len = @min(n.len, host_name.len);
        @memcpy(host_name[0..len], n[0..len]);
    }
    return &host_name;
}

pub fn Tcl_ProcObjCmd(_: ?*anyopaque, ip: *Interp, objc: c_int, objv: [*]const *Obj) callconv(.c) c_int {
    var list: std.ArrayList(*Obj) = .empty;
    defer {
        for (list.items) |o| obj.decr(o);
        list.deinit(gpa);
    }
    word(&list, "::proc");
    if (objc > 1) for (objv[1..@intCast(objc)]) |o| push(&list, o);
    return host.Tcl_EvalObjv(ip, @intCast(list.items.len), list.items.ptr, 0);
}

/// Slot 690 of the public table. Tcl 8.6 has no function in it.
pub fn TclUnusedStubEntry() callconv(.c) void {}

// ---- The interp tree ----

/// Runs operation `op` on `ip` with the words of `list`, and frees them.
/// Gives the code, with the value or the message in `host.reply`.
fn op(ip: *Interp, o: InterpOp, list: *std.ArrayList(*Obj)) c_int {
    const l = obj.Tcl_NewListObj(@intCast(list.items.len), list.items.ptr);
    obj.incr(l);
    for (list.items) |e| obj.decr(e);
    list.deinit(gpa);
    defer obj.decr(l);
    const f = host.host.interp_op orelse {
        host.reply = .{ .kind = 0, .len = 27, .bits = @intFromPtr("this path has no interp op".ptr) };
        return ERROR;
    };
    const a = host.argOf(l);
    return f(ip.handle, @backingInt(o), &a);
}

fn opNone(ip: *Interp, o: InterpOp) c_int {
    var list: std.ArrayList(*Obj) = .empty;
    return op(ip, o, &list);
}

/// The int of the reply of an operation.
fn replyInt() i64 {
    return if (host.reply.kind == 1) @bitCast(host.reply.bits) else 0;
}

fn handleWord(list: *std.ArrayList(*Obj), ip: *Interp) void {
    push(list, obj.Tcl_NewWideIntObj(ip.handle));
}

fn interpOfReply() ?*Interp {
    return host.interpFor(@intCast(replyInt()));
}

pub fn Tcl_GetSlave(ip: *Interp, name: [*:0]const u8) callconv(.c) ?*Interp {
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, std.mem.span(name));
    if (op(ip, .child, &list) != OK) return null;
    return interpOfReply();
}

pub fn Tcl_GetMaster(ip: *Interp) callconv(.c) ?*Interp {
    if (opNone(ip, .parent) != OK) return null;
    return interpOfReply();
}

pub fn Tcl_CreateSlave(ip: *Interp, name: [*:0]const u8, safe: c_int) callconv(.c) ?*Interp {
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::interp");
    word(&list, "create");
    if (safe != 0) word(&list, "-safe");
    word(&list, "--");
    word(&list, std.mem.span(name));
    const r = evalWords(ip, &list, true) orelse return null;
    obj.decr(r);
    return Tcl_GetSlave(ip, name);
}

pub fn Tcl_GetInterpPath(ip: *Interp, child: *Interp) callconv(.c) c_int {
    var list: std.ArrayList(*Obj) = .empty;
    handleWord(&list, child);
    const rc = op(ip, .path, &list);
    host.takeReply(ip);
    return if (rc == OK) OK else ERROR;
}

pub fn Tcl_IsSafe(ip: *Interp) callconv(.c) c_int {
    if (opNone(ip, .is_safe) != OK) return 0;
    return @intCast(replyInt());
}

pub fn Tcl_MakeSafe(ip: *Interp) callconv(.c) c_int {
    const rc = opNone(ip, .make_safe);
    if (rc != OK) host.takeReply(ip);
    return rc;
}

pub fn Tcl_InterpActive(ip: *Interp) callconv(.c) c_int {
    if (opNone(ip, .active) != OK) return 0;
    return @intCast(replyInt());
}

pub fn Tcl_SetRecursionLimit(ip: *Interp, depth: c_int) callconv(.c) c_int {
    var list: std.ArrayList(*Obj) = .empty;
    push(&list, obj.Tcl_NewWideIntObj(depth));
    if (op(ip, .recursion, &list) != OK) return 0;
    return @intCast(replyInt());
}

fn nameOp(ip: *Interp, o: InterpOp, a: [*:0]const u8, b: [*:0]const u8) c_int {
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, std.mem.span(a));
    word(&list, std.mem.span(b));
    const rc = op(ip, o, &list);
    if (rc != OK) host.takeReply(ip);
    return if (rc == OK) OK else ERROR;
}

pub fn Tcl_HideCommand(ip: *Interp, name: [*:0]const u8, hidden: [*:0]const u8) callconv(.c) c_int {
    return nameOp(ip, .hide, name, hidden);
}

pub fn Tcl_ExposeCommand(ip: *Interp, hidden: [*:0]const u8, name: [*:0]const u8) callconv(.c) c_int {
    return nameOp(ip, .expose, hidden, name);
}

// ---- Aliases ----

fn aliasOp(child: *Interp, cmd: [*:0]const u8, target: *Interp, tcmd: [*:0]const u8, words: []const *Obj) c_int {
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, std.mem.span(cmd));
    handleWord(&list, target);
    word(&list, std.mem.span(tcmd));
    for (words) |o| push(&list, o);
    const rc = op(child, .alias, &list);
    // The result is the name of the alias, or the message.
    host.takeReply(child);
    return if (rc == OK) OK else ERROR;
}

pub fn Tcl_CreateAlias(child: *Interp, cmd: [*:0]const u8, target: *Interp, tcmd: [*:0]const u8, argc: c_int, argv: ?[*]const [*:0]const u8) callconv(.c) c_int {
    const n: usize = @intCast(@max(argc, 0));
    const objs = gpa.alloc(*Obj, n) catch oom();
    defer {
        for (objs) |o| obj.decr(o);
        gpa.free(objs);
    }
    for (objs, 0..) |*o, i| {
        const s = std.mem.span(argv.?[i]);
        o.* = obj.Tcl_NewStringObj(s.ptr, @intCast(s.len));
        obj.incr(o.*);
    }
    return aliasOp(child, cmd, target, tcmd, objs);
}

pub fn Tcl_CreateAliasObj(child: *Interp, cmd: [*:0]const u8, target: *Interp, tcmd: [*:0]const u8, objc: c_int, objv: ?[*]const *Obj) callconv(.c) c_int {
    const n: usize = @intCast(@max(objc, 0));
    return aliasOp(child, cmd, target, tcmd, if (n == 0) &.{} else objv.?[0..n]);
}

/// The words of an alias that `Tcl_GetAlias` gave. The strings stay
/// until the interp goes.
const AliasInfo = struct {
    ip: *Interp,
    name: []u8,
    words: []*Obj,
    argv: [][*:0]const u8,
};

threadlocal var alias_infos: std.ArrayList(*AliasInfo) = .empty;

fn freeAliasInfo(a: *AliasInfo) void {
    for (a.words) |o| obj.decr(o);
    gpa.free(a.words);
    gpa.free(a.argv);
    gpa.free(a.name);
    gpa.destroy(a);
}

fn aliasInfo(ip: *Interp, name: [*:0]const u8, target: ?*?*Interp) ?*AliasInfo {
    const nm = std.mem.span(name);
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, nm);
    if (op(ip, .get_alias, &list) != OK) {
        host.takeReply(ip);
        return null;
    }
    const l = host.objOf(host.reply);
    obj.incr(l);
    defer obj.decr(l);
    var count: c_int = 0;
    var items: [*]*Obj = undefined;
    if (obj.Tcl_ListObjGetElements(null, l, &count, &items) != OK or count < 2) return null;
    var h: i64 = 0;
    _ = obj.Tcl_GetWideIntFromObj(null, items[0], &h);
    if (target) |p| p.* = host.interpFor(@intCast(h));
    // The strings of an earlier call stay valid: a call for the same
    // words gives the same record.
    const n: usize = @intCast(count - 1);
    for (alias_infos.items) |a| {
        if (a.ip != ip or !std.mem.eql(u8, a.name, nm) or a.words.len != n) continue;
        for (a.words, items[1..][0..n]) |w, o| {
            if (!std.mem.eql(u8, obj.text(w), obj.text(o))) break;
        } else return a;
    }
    const a = gpa.create(AliasInfo) catch oom();
    a.* = .{ .ip = ip, .name = gpa.dupe(u8, nm) catch oom(), .words = gpa.alloc(*Obj, n) catch oom(), .argv = gpa.alloc([*:0]const u8, n) catch oom() };
    for (a.words, a.argv, items[1..][0..n]) |*w, *s, o| {
        w.* = o;
        obj.incr(o);
        s.* = obj.Tcl_GetString(o);
    }
    alias_infos.append(gpa, a) catch oom();
    return a;
}

pub fn Tcl_GetAlias(ip: *Interp, name: [*:0]const u8, target: ?*?*Interp, tcmd: ?*[*:0]const u8, argc: ?*c_int, argv: ?*[*]const [*:0]const u8) callconv(.c) c_int {
    const a = aliasInfo(ip, name, target) orelse return ERROR;
    if (tcmd) |p| p.* = a.argv[0];
    if (argc) |p| p.* = @intCast(a.argv.len - 1);
    if (argv) |p| p.* = a.argv[1..].ptr;
    return OK;
}

pub fn Tcl_GetAliasObj(ip: *Interp, name: [*:0]const u8, target: ?*?*Interp, tcmd: ?*[*:0]const u8, objc: ?*c_int, objv: ?*[*]*Obj) callconv(.c) c_int {
    const a = aliasInfo(ip, name, target) orelse return ERROR;
    if (tcmd) |p| p.* = a.argv[0];
    if (objc) |p| p.* = @intCast(a.words.len - 1);
    if (objv) |p| p.* = a.words[1..].ptr;
    return OK;
}

// ---- Procs of interp deletion ----

pub const InterpDeleteProc = *const fn (?*anyopaque, *Interp) callconv(.c) void;

const WhenDeleted = struct { ip: *Interp, proc: InterpDeleteProc, cd: ?*anyopaque };

threadlocal var when_deleted: std.ArrayList(WhenDeleted) = .empty;

pub fn Tcl_CallWhenDeleted(ip: *Interp, proc: InterpDeleteProc, cd: ?*anyopaque) callconv(.c) void {
    for (when_deleted.items) |w| {
        if (w.ip == ip and w.proc == proc and w.cd == cd) return;
    }
    when_deleted.append(gpa, .{ .ip = ip, .proc = proc, .cd = cd }) catch oom();
}

pub fn Tcl_DontCallWhenDeleted(ip: *Interp, proc: InterpDeleteProc, cd: ?*anyopaque) callconv(.c) void {
    for (when_deleted.items, 0..) |w, i| {
        if (w.ip == ip and w.proc == proc and w.cd == cd) {
            _ = when_deleted.orderedRemove(i);
            return;
        }
    }
}

/// Runs the procs of `Tcl_CallWhenDeleted` of `ip` and frees the state of
/// this file for `ip`. The free of the interp calls it first.
pub fn dropInterp(ip: *Interp) void {
    var i: usize = 0;
    while (i < when_deleted.items.len) {
        const w = when_deleted.items[i];
        if (w.ip != ip) {
            i += 1;
            continue;
        }
        _ = when_deleted.orderedRemove(i);
        w.proc(w.cd, ip);
    }
    @import("vars.zig").dropInterp(ip);
    @import("namespaces.zig").dropInterp(ip);
    if (findLimit(ip)) |li| {
        const l = limits.swapRemove(li);
        for (l.handlers.items) |h| freeHandler(h);
        l.handlers.deinit(gpa);
        gpa.destroy(l);
    }
    i = alias_infos.items.len;
    while (i > 0) {
        i -= 1;
        if (alias_infos.items[i].ip == ip) freeAliasInfo(alias_infos.swapRemove(i));
    }
    i = funcs.items.len;
    while (i > 0) {
        i -= 1;
        const f = funcs.items[i];
        if (f.ip != ip) continue;
        _ = funcs.swapRemove(i);
        gpa.free(f.name);
        gpa.free(f.types);
        gpa.destroy(f);
    }
    i = ctraces.items.len;
    while (i > 0) {
        i -= 1;
        const t = ctraces.items[i];
        if (t.ip != ip) continue;
        _ = ctraces.swapRemove(i);
        freeTrace(t);
    }
    i = foreign.items.len;
    while (i > 0) {
        i -= 1;
        const c = foreign.items[i];
        if (c.interp != ip) continue;
        _ = foreign.swapRemove(i);
        var j = names.items.len;
        while (j > 0) {
            j -= 1;
            if (names.items[j].c == c) gpa.free(names.swapRemove(j).z);
        }
        gpa.free(c.name);
        gpa.destroy(c);
    }
}

// ---- Limits ----

const LIMIT_COMMANDS: c_int = 1;
const LIMIT_TIME: c_int = 2;

/// `Tcl_Time` of tcl.h.
const Time = extern struct { sec: c_long, usec: c_long };

pub const LimitHandlerProc = *const fn (?*anyopaque, *Interp) callconv(.c) void;
pub const LimitDeleteProc = *const fn (?*anyopaque) callconv(.c) void;

const Handler = struct { type: c_int, proc: LimitHandlerProc, cd: ?*anyopaque, delete: ?LimitDeleteProc };

const Limit = struct {
    ip: *Interp,
    active: c_int = 0,
    exceeded: c_int = 0,
    commands: c_int = 0,
    time: Time = .{ .sec = 0, .usec = 0 },
    gran_commands: c_int = 1,
    gran_time: c_int = 10,
    ticker: c_int = 0,
    /// The newest handler comes first.
    handlers: std.ArrayList(Handler) = .empty,
};

threadlocal var limits: std.ArrayList(*Limit) = .empty;

fn findLimit(ip: *Interp) ?usize {
    for (limits.items, 0..) |l, i| {
        if (l.ip == ip) return i;
    }
    return null;
}

fn limitOf(ip: *Interp) *Limit {
    if (findLimit(ip)) |i| return limits.items[i];
    const l = gpa.create(Limit) catch oom();
    l.* = .{ .ip = ip };
    limits.append(gpa, l) catch oom();
    return l;
}

/// TCL_DYNAMIC of tcl.h as a delete proc: the data is freed.
const dynamic: usize = 3;

fn freeHandler(h: Handler) void {
    const d = h.delete orelse return;
    if (@intFromPtr(d) == dynamic) {
        @import("mem.zig").slots.Tcl_Free(@ptrCast(h.cd));
    } else d(h.cd);
}

pub fn Tcl_LimitAddHandler(ip: *Interp, ty: c_int, proc: LimitHandlerProc, cd: ?*anyopaque, delete: ?LimitDeleteProc) callconv(.c) void {
    limitOf(ip).handlers.insert(gpa, 0, .{ .type = ty, .proc = proc, .cd = cd, .delete = delete }) catch oom();
}

pub fn Tcl_LimitRemoveHandler(ip: *Interp, ty: c_int, proc: LimitHandlerProc, cd: ?*anyopaque) callconv(.c) void {
    const l = limitOf(ip);
    for (l.handlers.items, 0..) |h, i| {
        if (h.type == ty and h.proc == proc and h.cd == cd) {
            freeHandler(l.handlers.orderedRemove(i));
            return;
        }
    }
}

fn tick(l: *Limit, ty: c_int) bool {
    const g = if (ty == LIMIT_COMMANDS) l.gran_commands else l.gran_time;
    return l.active & ty != 0 and (g == 1 or @rem(l.ticker, g) == 0);
}

pub fn Tcl_LimitReady(ip: *Interp) callconv(.c) c_int {
    const l = limitOf(ip);
    if (l.active == 0) return 0;
    l.ticker +%= 1;
    return @intFromBool(tick(l, LIMIT_COMMANDS) or tick(l, LIMIT_TIME));
}

/// The command count of `info cmdcount`.
fn commandCount(ip: *Interp) i64 {
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::info");
    word(&list, "cmdcount");
    const r = evalWords(ip, &list, false) orelse return 0;
    defer obj.decr(r);
    var n: i64 = 0;
    _ = obj.Tcl_GetWideIntFromObj(null, r, &n);
    return n;
}

fn now() Time {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return .{ .sec = @intCast(ts.sec), .usec = @intCast(@divTrunc(ts.nsec, 1000)) };
}

fn timeOver(l: *Limit) bool {
    const t = now();
    return l.time.sec < t.sec or (l.time.sec == t.sec and l.time.usec < t.usec);
}

fn runHandlers(l: *Limit, ty: c_int) void {
    // A handler can remove handlers, so the list is copied first.
    const copy = gpa.dupe(Handler, l.handlers.items) catch oom();
    defer gpa.free(copy);
    for (copy) |h| {
        if (h.type == ty) h.proc(h.cd, l.ip);
    }
}

/// Checks limit `ty` of `l`. Gives false when it is exceeded after the
/// handlers ran.
fn checkOne(l: *Limit, ty: c_int, comptime over: fn (*Limit) bool, msg: []const u8) bool {
    if (!tick(l, ty) or !over(l)) return true;
    l.exceeded |= ty;
    runHandlers(l, ty);
    if (l.active & ty == 0 or !over(l)) {
        l.exceeded &= ~ty;
        return true;
    }
    obj.Tcl_ResetResult(l.ip);
    obj.setResultText(l.ip, msg);
    return false;
}

fn commandsOver(l: *Limit) bool {
    return commandCount(l.ip) > l.commands;
}

pub fn Tcl_LimitCheck(ip: *Interp) callconv(.c) c_int {
    const l = limitOf(ip);
    if (l.active == 0) return OK;
    l.ticker +%= 1;
    if (!checkOne(l, LIMIT_COMMANDS, commandsOver, "command count limit exceeded")) return ERROR;
    if (!checkOne(l, LIMIT_TIME, timeOver, "time limit exceeded")) return ERROR;
    return OK;
}

pub fn Tcl_LimitExceeded(ip: *Interp) callconv(.c) c_int {
    return @intFromBool(limitOf(ip).exceeded != 0);
}

pub fn Tcl_LimitSetCommands(ip: *Interp, n: c_int) callconv(.c) void {
    const l = limitOf(ip);
    l.commands = n;
    l.exceeded &= ~LIMIT_COMMANDS;
}

pub fn Tcl_LimitGetCommands(ip: *Interp) callconv(.c) c_int {
    return limitOf(ip).commands;
}

pub fn Tcl_LimitSetTime(ip: *Interp, t: *const Time) callconv(.c) void {
    const l = limitOf(ip);
    l.time = t.*;
    l.exceeded &= ~LIMIT_TIME;
}

pub fn Tcl_LimitGetTime(ip: *Interp, t: *Time) callconv(.c) void {
    t.* = limitOf(ip).time;
}

pub fn Tcl_LimitSetGranularity(ip: *Interp, ty: c_int, g: c_int) callconv(.c) void {
    if (g < 1) return;
    const l = limitOf(ip);
    if (ty == LIMIT_COMMANDS) l.gran_commands = g else if (ty == LIMIT_TIME) l.gran_time = g;
}

pub fn Tcl_LimitGetGranularity(ip: *Interp, ty: c_int) callconv(.c) c_int {
    const l = limitOf(ip);
    return if (ty == LIMIT_COMMANDS) l.gran_commands else if (ty == LIMIT_TIME) l.gran_time else 0;
}

pub fn Tcl_LimitTypeEnabled(ip: *Interp, ty: c_int) callconv(.c) c_int {
    return @intFromBool(limitOf(ip).active & ty != 0);
}

pub fn Tcl_LimitTypeExceeded(ip: *Interp, ty: c_int) callconv(.c) c_int {
    return @intFromBool(limitOf(ip).exceeded & ty != 0);
}

pub fn Tcl_LimitTypeSet(ip: *Interp, ty: c_int) callconv(.c) void {
    limitOf(ip).active |= ty;
}

pub fn Tcl_LimitTypeReset(ip: *Interp, ty: c_int) callconv(.c) void {
    const l = limitOf(ip);
    l.active &= ~ty;
    l.exceeded &= ~ty;
}

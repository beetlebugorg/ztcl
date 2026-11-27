//! The variable slots of the stubs table of Tcl 8.6 that are not get and
//! set: unset, upvar, traces, and linked variables. The native path
//! (`stubs.zig`) and the WebAssembly path (`wasm_stubs.zig`) use this
//! one file.
//!
//! Unset and upvar evaluate `::unset` and `::upvar` in the frame of the
//! command of the package. A trace of C is a hidden command of the
//! package and a `trace add variable` of ztcl with that command. The
//! command calls the trace proc with the names and the flag of the
//! operation, and a message from the proc is the error of the access.
//! An unset removes the trace, as in Tcl, and the proc gets
//! TCL_TRACE_DESTROYED. A linked variable is a global variable with a
//! trace of this file: a read sets the variable to the value of the C
//! memory, a write parses the new value into the C memory, and an unset
//! makes the variable and its trace again.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const obj = @import("obj.zig");
const host = @import("host.zig");
const regexp = @import("regexp.zig");

const Obj = obj.Obj;
const Interp = obj.Interp;
const OK = obj.OK;
const ERROR = obj.ERROR;
const gpa = std.heap.c_allocator;
const panicText = obj.panicText;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();

const GLOBAL_ONLY: c_int = 1;
const NAMESPACE_ONLY: c_int = 2;
const LEAVE_ERR_MSG: c_int = 0x200;
const TRACE_READS: c_int = 0x10;
const TRACE_WRITES: c_int = 0x20;
const TRACE_UNSETS: c_int = 0x40;
const TRACE_DESTROYED: c_int = 0x80;
const TRACE_ARRAY: c_int = 0x800;

fn oom() noreturn {
    panicText("out of memory");
}

fn word(list: *std.ArrayList(*Obj), s: []const u8) void {
    const o = obj.Tcl_NewStringObj(s.ptr, @intCast(s.len));
    obj.incr(o);
    list.append(gpa, o) catch oom();
}

/// The name of a variable for a script: `n1` or `n1(n2)`, with `::` in
/// front for TCL_GLOBAL_ONLY.
fn fullName(buf: *std.ArrayList(u8), n1: []const u8, n2: ?[]const u8, flags: c_int) []const u8 {
    if (flags & GLOBAL_ONLY != 0 and !std.mem.startsWith(u8, n1, "::")) buf.appendSlice(gpa, "::") catch oom();
    buf.appendSlice(gpa, n1) catch oom();
    if (n2) |e| {
        buf.append(gpa, '(') catch oom();
        buf.appendSlice(gpa, e) catch oom();
        buf.append(gpa, ')') catch oom();
    }
    return buf.items;
}

/// Evaluates `list`. Without TCL_LEAVE_ERR_MSG, an error leaves the
/// interp result as it was.
fn evalFlags(ip: *Interp, list: *std.ArrayList(*Obj), flags: c_int) c_int {
    const saved = obj.result(ip);
    obj.incr(saved);
    defer obj.decr(saved);
    var r: ?*Obj = null;
    const rc = regexp.run(ip, list, &r);
    if (r) |o| obj.decr(o);
    if (rc != OK and flags & LEAVE_ERR_MSG == 0) obj.Tcl_SetObjResult(ip, saved);
    return rc;
}

fn spanOr(p: ?[*:0]const u8) ?[]const u8 {
    return if (p) |s| std.mem.span(s) else null;
}

pub fn Tcl_UnsetVar2(ip: *Interp, n1: [*:0]const u8, n2: ?[*:0]const u8, flags: c_int) callconv(.c) c_int {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::unset");
    word(&list, "--");
    word(&list, fullName(&buf, std.mem.span(n1), spanOr(n2), flags));
    return if (evalFlags(ip, &list, flags) == OK) OK else ERROR;
}

pub fn Tcl_UnsetVar(ip: *Interp, n: [*:0]const u8, flags: c_int) callconv(.c) c_int {
    return Tcl_UnsetVar2(ip, n, null, flags);
}

pub fn Tcl_UpVar2(ip: *Interp, frame: [*:0]const u8, n1: [*:0]const u8, n2: ?[*:0]const u8, local: [*:0]const u8, flags: c_int) callconv(.c) c_int {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::upvar");
    word(&list, std.mem.span(frame));
    word(&list, fullName(&buf, std.mem.span(n1), spanOr(n2), flags));
    word(&list, std.mem.span(local));
    return if (evalFlags(ip, &list, LEAVE_ERR_MSG) == OK) OK else ERROR;
}

pub fn Tcl_UpVar(ip: *Interp, frame: [*:0]const u8, n: [*:0]const u8, local: [*:0]const u8, flags: c_int) callconv(.c) c_int {
    return Tcl_UpVar2(ip, frame, n, null, local, flags);
}

// ---- Traces ----

pub const TraceProc = *const fn (?*anyopaque, *Interp, [*:0]const u8, ?[*:0]const u8, c_int) callconv(.c) ?[*:0]const u8;

const Trace = struct {
    ip: *Interp,
    /// The name as the package gave it, and the name for the script.
    n1: [:0]u8,
    n2: ?[:0]u8,
    name: []u8,
    flags: c_int,
    proc: TraceProc,
    cd: ?*anyopaque,
    cmd: [:0]u8,
    live: bool = true,
    /// The trace proc runs.
    busy: bool = false,
};

threadlocal var traces: std.ArrayList(*Trace) = .empty;
threadlocal var next_id: u32 = 0;

fn opsText(flags: c_int) []const u8 {
    const all = [_]struct { f: c_int, t: []const u8 }{
        .{ .f = TRACE_ARRAY, .t = "array" },
        .{ .f = TRACE_READS, .t = "read" },
        .{ .f = TRACE_WRITES, .t = "write" },
        .{ .f = TRACE_UNSETS, .t = "unset" },
    };
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    for (all) |o| if (flags & o.f != 0) {
        if (n > 0) {
            buf[n] = ' ';
            n += 1;
        }
        @memcpy(buf[n..][0..o.t.len], o.t);
        n += o.t.len;
    };
    return gpa.dupe(u8, buf[0..n]) catch oom();
}

fn freeTrace(t: *Trace) void {
    gpa.free(t.n1);
    if (t.n2) |n| gpa.free(n);
    gpa.free(t.name);
    gpa.free(t.cmd);
    gpa.destroy(t);
}

/// Frees the records of the traces that an unset or an untrace ended,
/// with their hidden commands.
fn sweep() void {
    var i = traces.items.len;
    while (i > 0) {
        i -= 1;
        const t = traces.items[i];
        if (t.live or t.busy) continue;
        _ = host.Tcl_DeleteCommand(t.ip, t.cmd[2..].ptr);
        _ = traces.orderedRemove(i);
        freeTrace(t);
    }
}

fn traceCmd(cd: ?*anyopaque, ip: *Interp, objc: c_int, objv: [*]const *Obj) callconv(.c) c_int {
    const t: *Trace = @ptrCast(@alignCast(cd.?));
    if (!t.live or objc < 4) return OK;
    const op = obj.text(objv[3]);
    var flag: c_int = if (std.mem.eql(u8, op, "read")) TRACE_READS else if (std.mem.eql(u8, op, "write")) TRACE_WRITES else if (std.mem.eql(u8, op, "unset")) TRACE_UNSETS else TRACE_ARRAY;
    if (flag & TRACE_UNSETS != 0) {
        // The unset removes the trace in ztcl too.
        flag |= TRACE_DESTROYED;
        t.live = false;
    }
    const n2 = obj.text(objv[2]);
    const n2z = gpa.dupeSentinel(u8, n2, 0) catch oom();
    defer gpa.free(n2z);
    t.busy = true;
    const msg = t.proc(t.cd, ip, t.n1.ptr, if (n2.len > 0) n2z.ptr else null, flag);
    t.busy = false;
    if (msg == null) return OK;
    obj.setResultText(ip, std.mem.span(msg.?));
    return ERROR;
}

fn traceWords(list: *std.ArrayList(*Obj), t: *Trace, sub: []const u8) void {
    word(list, "::trace");
    word(list, sub);
    word(list, "variable");
    word(list, t.name);
    const ops = opsText(t.flags);
    defer gpa.free(ops);
    word(list, ops);
    word(list, t.cmd);
}

pub fn Tcl_TraceVar2(ip: *Interp, n1: [*:0]const u8, n2: ?[*:0]const u8, flags: c_int, proc: TraceProc, cd: ?*anyopaque) callconv(.c) c_int {
    sweep();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const t = gpa.create(Trace) catch oom();
    const id = next_id;
    next_id += 1;
    t.* = .{
        .ip = ip,
        .n1 = gpa.dupeSentinel(u8, std.mem.span(n1), 0) catch oom(),
        .n2 = if (n2) |p| gpa.dupeSentinel(u8, std.mem.span(p), 0) catch oom() else null,
        .name = gpa.dupe(u8, fullName(&buf, std.mem.span(n1), spanOr(n2), flags)) catch oom(),
        .flags = flags,
        .proc = proc,
        .cd = cd,
        .cmd = std.fmt.allocPrintSentinel(gpa, "::tcl::cext::trace{d}", .{id}, 0) catch oom(),
    };
    // The namespace of the hidden commands.
    var ns: std.ArrayList(*Obj) = .empty;
    for ([_][]const u8{ "::namespace", "eval", "::tcl::cext", "" }) |w| word(&ns, w);
    _ = evalFlags(ip, &ns, 0);
    // The table of commands has the name with no `::` in front.
    _ = host.createCommand(ip, t.cmd[2..].ptr, &traceCmd, null, t, null);
    var list: std.ArrayList(*Obj) = .empty;
    traceWords(&list, t, "add");
    if (evalFlags(ip, &list, LEAVE_ERR_MSG) != OK) {
        _ = host.Tcl_DeleteCommand(ip, t.cmd[2..].ptr);
        freeTrace(t);
        return ERROR;
    }
    traces.append(gpa, t) catch oom();
    return OK;
}

/// Frees the trace records and the links of `ip`, with no call to ztcl.
/// The free of the interp calls it.
pub fn dropInterp(ip: *Interp) void {
    var i = traces.items.len;
    while (i > 0) {
        i -= 1;
        const t = traces.items[i];
        if (t.ip != ip) continue;
        _ = traces.orderedRemove(i);
        freeTrace(t);
    }
    i = links.items.len;
    while (i > 0) {
        i -= 1;
        const l = links.items[i];
        if (l.ip != ip) continue;
        _ = links.orderedRemove(i);
        l.last.deinit(gpa);
        gpa.free(l.name);
        gpa.destroy(l);
    }
}

pub fn Tcl_TraceVar(ip: *Interp, n: [*:0]const u8, flags: c_int, proc: TraceProc, cd: ?*anyopaque) callconv(.c) c_int {
    return Tcl_TraceVar2(ip, n, null, flags, proc, cd);
}

fn same(t: *Trace, ip: *Interp, n1: [*:0]const u8, n2: ?[*:0]const u8) bool {
    if (t.ip != ip or !std.mem.eql(u8, t.n1, std.mem.span(n1))) return false;
    if ((t.n2 == null) != (n2 == null)) return false;
    return t.n2 == null or std.mem.eql(u8, t.n2.?, std.mem.span(n2.?));
}

const trace_mask = TRACE_READS | TRACE_WRITES | TRACE_UNSETS | TRACE_ARRAY;

pub fn Tcl_UntraceVar2(ip: *Interp, n1: [*:0]const u8, n2: ?[*:0]const u8, flags: c_int, proc: TraceProc, cd: ?*anyopaque) callconv(.c) void {
    // Each record of the trace goes: an unset leaves a record that is
    // not live.
    for (traces.items) |t| {
        if (!same(t, ip, n1, n2) or t.proc != proc or t.cd != cd or t.flags & trace_mask != flags & trace_mask) continue;
        if (t.live) {
            var list: std.ArrayList(*Obj) = .empty;
            traceWords(&list, t, "remove");
            _ = evalFlags(ip, &list, 0);
        }
        t.live = false;
    }
    // A record of a running trace proc goes later.
    sweep();
}

pub fn Tcl_UntraceVar(ip: *Interp, n: [*:0]const u8, flags: c_int, proc: TraceProc, cd: ?*anyopaque) callconv(.c) void {
    Tcl_UntraceVar2(ip, n, null, flags, proc, cd);
}

pub fn Tcl_VarTraceInfo2(ip: *Interp, n1: [*:0]const u8, n2: ?[*:0]const u8, _: c_int, proc: TraceProc, prev: ?*anyopaque) callconv(.c) ?*anyopaque {
    var seen = prev == null;
    // The newest trace comes first, as in Tcl.
    var i = traces.items.len;
    while (i > 0) {
        i -= 1;
        const t = traces.items[i];
        if (!t.live or !same(t, ip, n1, n2) or t.proc != proc) continue;
        if (seen) return t.cd;
        if (t.cd == prev) seen = true;
    }
    return null;
}

pub fn Tcl_VarTraceInfo(ip: *Interp, n: [*:0]const u8, flags: c_int, proc: TraceProc, prev: ?*anyopaque) callconv(.c) ?*anyopaque {
    return Tcl_VarTraceInfo2(ip, n, null, flags, proc, prev);
}

// ---- Linked variables ----

const LinkType = enum(c_int) { int = 1, double = 2, boolean = 3, string = 4, wide = 5, char = 6, uchar = 7, short = 8, ushort = 9, uint = 10, long = 11, ulong = 12, float = 13, wide_uint = 14, _ };
const READ_ONLY: c_int = 0x80;

const Link = struct {
    ip: *Interp,
    name: [:0]u8,
    addr: *anyopaque,
    type: LinkType,
    read_only: bool,
    /// The text of the last value that the variable had.
    last: std.ArrayList(u8) = .empty,
    busy: bool = false,
};

threadlocal var links: std.ArrayList(*Link) = .empty;

fn at(comptime T: type, l: *Link) *align(1) T {
    return @ptrCast(l.addr);
}

/// The text of the C value of `l`.
fn linkText(l: *Link, out: *std.ArrayList(u8)) void {
    out.clearRetainingCapacity();
    switch (l.type) {
        .int => out.print(gpa, "{d}", .{at(c_int, l).*}) catch oom(),
        .boolean => out.print(gpa, "{d}", .{@intFromBool(at(c_int, l).* != 0)}) catch oom(),
        .wide => out.print(gpa, "{d}", .{at(i64, l).*}) catch oom(),
        .char => out.print(gpa, "{d}", .{at(i8, l).*}) catch oom(),
        .uchar => out.print(gpa, "{d}", .{at(u8, l).*}) catch oom(),
        .short => out.print(gpa, "{d}", .{at(i16, l).*}) catch oom(),
        .ushort => out.print(gpa, "{d}", .{at(u16, l).*}) catch oom(),
        .uint => out.print(gpa, "{d}", .{at(c_uint, l).*}) catch oom(),
        .long => out.print(gpa, "{d}", .{at(c_long, l).*}) catch oom(),
        .ulong => out.print(gpa, "{d}", .{at(c_ulong, l).*}) catch oom(),
        .wide_uint => out.print(gpa, "{d}", .{at(u64, l).*}) catch oom(),
        .double, .float => {
            const d: f64 = if (l.type == .double) at(f64, l).* else at(f32, l).*;
            var buf: [32]u8 = undefined;
            @import("strings.zig").Tcl_PrintDouble(null, d, &buf);
            out.appendSlice(gpa, std.mem.span(@as([*:0]const u8, @ptrCast(&buf)))) catch oom();
        },
        .string => {
            const p = at(?[*:0]const u8, l).*;
            out.appendSlice(gpa, if (p) |s| std.mem.span(s) else "NULL") catch oom();
        },
        _ => {},
    }
}

fn setLinkVar(l: *Link) void {
    var t: std.ArrayList(u8) = .empty;
    defer t.deinit(gpa);
    linkText(l, &t);
    l.busy = true;
    defer l.busy = false;
    _ = host.setVar(l.ip, l.name, null, obj.Tcl_NewStringObj(t.items.ptr, @intCast(t.items.len)), GLOBAL_ONLY);
    l.last.clearRetainingCapacity();
    l.last.appendSlice(gpa, t.items) catch oom();
}

fn intIn(comptime T: type, s: []const u8) ?T {
    const w = @import("../value.zig").parseInt(s) orelse return null;
    return std.math.cast(T, w);
}

/// Stores the text `s` in the C memory of `l`, or gives the message.
fn store(l: *Link, s: []const u8) ?[*:0]const u8 {
    const o = obj.Tcl_NewStringObj(s.ptr, @intCast(s.len));
    obj.incr(o);
    defer obj.decr(o);
    switch (l.type) {
        .int => at(c_int, l).* = intIn(c_int, s) orelse return "variable must have integer value",
        .wide => at(i64, l).* = intIn(i64, s) orelse return "variable must have integer value",
        .char => at(i8, l).* = intIn(i8, s) orelse return "variable must have char value",
        .uchar => at(u8, l).* = intIn(u8, s) orelse return "variable must have unsigned char value",
        .short => at(i16, l).* = intIn(i16, s) orelse return "variable must have short value",
        .ushort => at(u16, l).* = intIn(u16, s) orelse return "variable must have unsigned short value",
        .uint => at(c_uint, l).* = intIn(c_uint, s) orelse return "variable must have unsigned int value",
        .long => at(c_long, l).* = intIn(c_long, s) orelse return "variable must have long value",
        .ulong => at(c_ulong, l).* = intIn(c_ulong, s) orelse return "variable must have unsigned long value",
        .wide_uint => at(u64, l).* = intIn(u64, s) orelse return "variable must have unsigned wide int value",
        .boolean => {
            var b: c_int = 0;
            if (obj.Tcl_GetBooleanFromObj(null, o, &b) != OK) return "variable must have boolean value";
            at(c_int, l).* = b;
        },
        .double, .float => {
            var d: f64 = 0;
            if (obj.Tcl_GetDoubleFromObj(null, o, &d) != OK) return if (l.type == .double) "variable must have real value" else "variable must have float value";
            if (l.type == .double) at(f64, l).* = d else at(f32, l).* = @floatCast(d);
        },
        .string => {
            const p = at(?[*:0]u8, l);
            if (p.*) |old| std.c.free(old);
            const n: [*]u8 = @ptrCast(std.c.malloc(s.len + 1) orelse oom());
            @memcpy(n[0..s.len], s);
            n[s.len] = 0;
            p.* = @ptrCast(n);
        },
        _ => {},
    }
    return null;
}

fn linkTrace(cd: ?*anyopaque, ip: *Interp, _: [*:0]const u8, _: ?[*:0]const u8, flags: c_int) callconv(.c) ?[*:0]const u8 {
    const l: *Link = @ptrCast(@alignCast(cd.?));
    if (l.busy) return null;
    if (flags & TRACE_UNSETS != 0) {
        setLinkVar(l);
        _ = Tcl_TraceVar2(ip, l.name.ptr, null, GLOBAL_ONLY | TRACE_READS | TRACE_WRITES | TRACE_UNSETS, &linkTrace, l);
        return null;
    }
    if (flags & TRACE_READS != 0) {
        setLinkVar(l);
        return null;
    }
    // A write.
    const v = host.getVar(ip, l.name, null, GLOBAL_ONLY) orelse return null;
    const s = gpa.dupe(u8, obj.text(v)) catch oom();
    defer gpa.free(s);
    if (l.read_only) {
        setLinkVar(l);
        return "linked variable is read-only";
    }
    if (store(l, s)) |msg| {
        // The variable gets the old value back.
        l.busy = true;
        defer l.busy = false;
        _ = host.setVar(ip, l.name, null, obj.Tcl_NewStringObj(l.last.items.ptr, @intCast(l.last.items.len)), GLOBAL_ONLY);
        return msg;
    }
    l.last.clearRetainingCapacity();
    l.last.appendSlice(gpa, s) catch oom();
    return null;
}

pub fn Tcl_LinkVar(ip: *Interp, name: [*:0]const u8, addr: *anyopaque, kind: c_int) callconv(.c) c_int {
    const l = gpa.create(Link) catch oom();
    l.* = .{ .ip = ip, .name = gpa.dupeSentinel(u8, std.mem.span(name), 0) catch oom(), .addr = addr, .type = @fromBackingInt(@intCast(kind & ~READ_ONLY)), .read_only = kind & READ_ONLY != 0 };
    setLinkVar(l);
    if (Tcl_TraceVar2(ip, name, null, GLOBAL_ONLY | TRACE_READS | TRACE_WRITES | TRACE_UNSETS, &linkTrace, l) != OK) {
        gpa.free(l.name);
        gpa.destroy(l);
        return ERROR;
    }
    links.append(gpa, l) catch oom();
    return OK;
}

fn findLink(ip: *Interp, name: [*:0]const u8) ?usize {
    for (links.items, 0..) |l, i| {
        if (l.ip == ip and std.mem.eql(u8, l.name, std.mem.span(name))) return i;
    }
    return null;
}

pub fn Tcl_UnlinkVar(ip: *Interp, name: [*:0]const u8) callconv(.c) void {
    const i = findLink(ip, name) orelse return;
    const l = links.orderedRemove(i);
    Tcl_UntraceVar2(ip, name, null, GLOBAL_ONLY | TRACE_READS | TRACE_WRITES | TRACE_UNSETS, &linkTrace, l);
    l.last.deinit(gpa);
    gpa.free(l.name);
    gpa.destroy(l);
}

pub fn Tcl_UpdateLinkedVar(ip: *Interp, name: [*:0]const u8) callconv(.c) void {
    const i = findLink(ip, name) orelse return;
    setLinkVar(links.items[i]);
}

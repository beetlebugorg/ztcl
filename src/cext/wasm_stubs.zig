//! The stubs table of Tcl 8.6 for a C package that `zig cc -target
//! wasm32-wasi` builds (docs/dev/cext-tasks/04w-wasm-bridge.md).
//!
//! The library links into the package. `Tcl_InitStubs` points
//! `tclStubsPtr` at a table of 691 slots in the published order of
//! `tclDecls.h`. A slot with no implementation calls `Tcl_Panic` with its
//! number.
//!
//! The objects, the interp result, the dynamic strings, and
//! `Tcl_GetIndexFromObjStruct` are in `obj.zig`, and the memory slots
//! are in `mem.zig`. The native path uses the same two files. These
//! slots are in the package, so they make no call out of the module.
//! This file has the slots that call ztcl through the imports of the
//! module, and the table (`table.zig` builds it from the three groups).
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../value.zig");
const obj = @import("obj.zig");
const tables = @import("table.zig");
const chan = @import("chan.zig");
const ChannelType = chan.ChannelType;
const Channel = chan.Channel;

const gpa = std.heap.c_allocator;

// The names of obj.zig that this file uses.
const DString = obj.DString;
const ERROR = obj.ERROR;
const Interp = obj.Interp;
const OK = obj.OK;
const Obj = obj.Obj;
const Rep = obj.Rep;
const Tcl_AppendElement = obj.Tcl_AppendElement;
const Tcl_DStringAppend = obj.Tcl_DStringAppend;
const Tcl_DStringAppendElement = obj.Tcl_DStringAppendElement;
const Tcl_DStringFree = obj.Tcl_DStringFree;
const Tcl_DStringInit = obj.Tcl_DStringInit;
const Tcl_GetBooleanFromObj = obj.Tcl_GetBooleanFromObj;
const Tcl_GetByteArrayFromObj = obj.Tcl_GetByteArrayFromObj;
const Tcl_GetDoubleFromObj = obj.Tcl_GetDoubleFromObj;
const Tcl_GetIndexFromObjStruct = obj.Tcl_GetIndexFromObjStruct;
const Tcl_GetIntFromObj = obj.Tcl_GetIntFromObj;
const Tcl_GetString = obj.Tcl_GetString;
const Tcl_GetStringResult = obj.Tcl_GetStringResult;
const Tcl_GetWideIntFromObj = obj.Tcl_GetWideIntFromObj;
const Tcl_ListObjAppendElement = obj.Tcl_ListObjAppendElement;
const Tcl_ListObjGetElements = obj.Tcl_ListObjGetElements;
const Tcl_ListObjLength = obj.Tcl_ListObjLength;
const Tcl_NewByteArrayObj = obj.Tcl_NewByteArrayObj;
const Tcl_NewDoubleObj = obj.Tcl_NewDoubleObj;
const Tcl_NewIntObj = obj.Tcl_NewIntObj;
const Tcl_NewListObj = obj.Tcl_NewListObj;
const Tcl_NewObj = obj.Tcl_NewObj;
const Tcl_NewStringObj = obj.Tcl_NewStringObj;
const Tcl_NewWideIntObj = obj.Tcl_NewWideIntObj;
const Tcl_ResetResult = obj.Tcl_ResetResult;
const Tcl_SetObjResult = obj.Tcl_SetObjResult;
const Tcl_WrongNumArgs = obj.Tcl_WrongNumArgs;
const decr = obj.decr;
const dsAppend = obj.dsAppend;
const expected = obj.expected;
const incr = obj.incr;
const panicText = obj.panicText;
const result = obj.result;
const setResultText = obj.setResultText;
const text = obj.text;

pub fn Tcl_TranslateFileName(_: ?*Interp, name: [*:0]const u8, ds: *DString) callconv(.c) [*:0]u8 {
    Tcl_DStringInit(ds);
    dsAppend(ds, std.mem.span(name));
    return @ptrCast(ds.string);
}

pub fn Tcl_PkgRequireEx(ip: *Interp, name: [*:0]const u8, version: ?[*:0]const u8, exact: c_int, client_data: ?*anyopaque) callconv(.c) ?[*:0]const u8 {
    _ = exact;
    if (client_data) |cd| @as(*?*anyopaque, @ptrCast(@alignCast(cd))).* = null;
    if (std.mem.eql(u8, std.mem.span(name), "Tcl")) {
        const v = if (version) |p| std.mem.span(p) else "";
        if (v.len == 0 or v[0] == '8') return "8.6.16";
        setResultText(ip, "version conflict for package \"Tcl\": have 8.6.16");
        return null;
    }
    setResultText(ip, "Tcl_PkgRequireEx: only the package Tcl is available");
    return null;
}

// ---- Commands, scripts, and variables ----
//
// These slots call ztcl through the imports of the module `ztcl`. A
// value crosses as an `Arg`: its kind, and an int, a double, or the
// address and the length of its text. The text of a reply from ztcl is
// in the exchange buffer of the package (`ztcl_cext_buf`).

/// A value that crosses the boundary. `kind` is 0 for text, 1 for an
/// int, and 2 for a double. For text, `bits` is the address in the
/// memory of the side that sends it.
pub const Arg = extern struct {
    kind: u32,
    len: u32,
    bits: u64,
};

/// The imports to ztcl. The tests set fakes.
pub const Host = struct {
    cmd_create: *const fn (handle: u32, id: u32, name: [*]const u8, len: usize) callconv(.c) i32,
    cmd_delete: *const fn (handle: u32, name: [*]const u8, len: usize) callconv(.c) i32,
    /// Runs a script. Gives the code of Tcl, and the result in the reply.
    eval: *const fn (handle: u32, script: [*]const u8, len: usize, flags: c_int) callconv(.c) i32,
    /// Reads a variable. Gives 0 with the value in the reply, or 1 with
    /// the error in the reply.
    var_get: *const fn (handle: u32, name: [*]const u8, len: usize, flags: c_int) callconv(.c) i32,
    var_set: *const fn (handle: u32, name: [*]const u8, len: usize, v: *const Arg, flags: c_int) callconv(.c) i32,
    pkg_provide: *const fn (handle: u32, name: [*]const u8, len: usize, version: [*]const u8, vlen: usize) callconv(.c) i32,
};

const wasm_host = struct {
    extern "ztcl" fn cmd_create(handle: u32, id: u32, name: [*]const u8, len: usize) i32;
    extern "ztcl" fn cmd_delete(handle: u32, name: [*]const u8, len: usize) i32;
    extern "ztcl" fn eval(handle: u32, script: [*]const u8, len: usize, flags: c_int) i32;
    extern "ztcl" fn var_get(handle: u32, name: [*]const u8, len: usize, flags: c_int) i32;
    extern "ztcl" fn var_set(handle: u32, name: [*]const u8, len: usize, v: *const Arg, flags: c_int) i32;
    extern "ztcl" fn pkg_provide(handle: u32, name: [*]const u8, len: usize, version: [*]const u8, vlen: usize) i32;
};

fn noHost() noreturn {
    panicText("the package has no host");
}

pub var host: Host = if (builtin.target.cpu.arch == .wasm32) .{
    .cmd_create = &wasm_host.cmd_create,
    .cmd_delete = &wasm_host.cmd_delete,
    .eval = &wasm_host.eval,
    .var_get = &wasm_host.var_get,
    .var_set = &wasm_host.var_set,
    .pkg_provide = &wasm_host.pkg_provide,
} else .{
    .cmd_create = struct {
        fn f(_: u32, _: u32, _: [*]const u8, _: usize) callconv(.c) i32 {
            noHost();
        }
    }.f,
    .cmd_delete = struct {
        fn f(_: u32, _: [*]const u8, _: usize) callconv(.c) i32 {
            noHost();
        }
    }.f,
    .eval = struct {
        fn f(_: u32, _: [*]const u8, _: usize, _: c_int) callconv(.c) i32 {
            noHost();
        }
    }.f,
    .var_get = struct {
        fn f(_: u32, _: [*]const u8, _: usize, _: c_int) callconv(.c) i32 {
            noHost();
        }
    }.f,
    .var_set = struct {
        fn f(_: u32, _: [*]const u8, _: usize, _: *const Arg, _: c_int) callconv(.c) i32 {
            noHost();
        }
    }.f,
    .pkg_provide = struct {
        fn f(_: u32, _: [*]const u8, _: usize, _: [*]const u8, _: usize) callconv(.c) i32 {
            noHost();
        }
    }.f,
};

/// The reply of the last call to ztcl, and the reply of a dispatch.
pub var reply: Arg = .{ .kind = 0, .len = 0, .bits = 0 };

/// The exchange buffer for text from the other side, and the area of
/// the arguments of a dispatch.
var xbuf: std.ArrayList(u8) = .empty;
var args_area: std.ArrayList(Arg) = .empty;

fn ztcl_cext_buf(len: usize) callconv(.c) [*]u8 {
    xbuf.ensureTotalCapacity(gpa, @max(len, 1)) catch panicText("out of memory");
    return xbuf.items.ptr;
}

fn ztcl_cext_args(argc: usize) callconv(.c) [*]Arg {
    args_area.ensureTotalCapacity(gpa, @max(argc, 1)) catch panicText("out of memory");
    return args_area.items.ptr;
}

fn ztcl_cext_reply() callconv(.c) *Arg {
    return &reply;
}

/// The object of a reply or an argument from ztcl.
fn objOf(a: Arg) *Obj {
    return switch (a.kind) {
        1 => Tcl_NewWideIntObj(@bitCast(a.bits)),
        2 => Tcl_NewDoubleObj(@bitCast(a.bits)),
        else => blk: {
            const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(a.bits)));
            break :blk Tcl_NewStringObj(p, @intCast(a.len));
        },
    };
}

/// The value of an object for ztcl. Text stays in the memory of the
/// package until the next call.
fn argOf(o: *Obj) Arg {
    if (o.typePtr == &obj.wide_type) return .{ .kind = 1, .len = 0, .bits = @bitCast(o.rep.wide) };
    if (o.typePtr == &obj.double_type) return .{ .kind = 2, .len = 0, .bits = @bitCast(o.rep.double) };
    const s = text(o);
    return .{ .kind = 0, .len = @intCast(s.len), .bits = @intFromPtr(s.ptr) };
}

pub const ObjCmdProc = *const fn (?*anyopaque, *Interp, c_int, [*]const *Obj) callconv(.c) c_int;
pub const DeleteProc = *const fn (?*anyopaque) callconv(.c) void;
pub const NRPostProc = *const fn ([*]?*anyopaque, *Interp, c_int) callconv(.c) c_int;

const Command = struct {
    proc: ?ObjCmdProc,
    nre: ?ObjCmdProc,
    cd: ?*anyopaque,
    delete: ?DeleteProc,
    interp: *Interp,
    name: []u8,
    live: bool = true,
};

var commands: std.ArrayList(*Command) = .empty;

fn createCommand(ip: *Interp, name: [*:0]const u8, proc: ?ObjCmdProc, nre: ?ObjCmdProc, cd: ?*anyopaque, delete: ?DeleteProc) *Command {
    const c = gpa.create(Command) catch panicText("out of memory");
    const n = std.mem.span(name);
    c.* = .{ .proc = proc, .nre = nre, .cd = cd, .delete = delete, .interp = ip, .name = gpa.dupe(u8, n) catch panicText("out of memory") };
    const id: u32 = @intCast(commands.items.len);
    commands.append(gpa, c) catch panicText("out of memory");
    if (host.cmd_create(ip.handle, id, n.ptr, n.len) != 0) panicText("Tcl_CreateObjCommand: ztcl gave an error");
    return c;
}

pub fn Tcl_CreateObjCommand(ip: *Interp, name: [*:0]const u8, proc: ObjCmdProc, cd: ?*anyopaque, delete: ?DeleteProc) callconv(.c) *Command {
    return createCommand(ip, name, proc, null, cd, delete);
}

pub fn Tcl_NRCreateCommand(ip: *Interp, name: [*:0]const u8, proc: ?ObjCmdProc, nre: ObjCmdProc, cd: ?*anyopaque, delete: ?DeleteProc) callconv(.c) *Command {
    return createCommand(ip, name, proc, nre, cd, delete);
}

/// Runs the delete proc of a command once.
fn forget(c: *Command) void {
    if (!c.live) return;
    c.live = false;
    if (c.delete) |d| d(c.cd);
}

pub fn Tcl_DeleteCommand(ip: *Interp, name: [*:0]const u8) callconv(.c) c_int {
    const n = std.mem.span(name);
    const plain = if (std.mem.startsWith(u8, n, "::")) n[2..] else n;
    for (commands.items) |c| {
        if (c.live and c.interp == ip and std.mem.eql(u8, c.name, plain)) {
            _ = host.cmd_delete(ip.handle, n.ptr, n.len);
            forget(c);
            return 0;
        }
    }
    return if (host.cmd_delete(ip.handle, n.ptr, n.len) == 0) 0 else -1;
}

pub fn Tcl_DeleteCommandFromToken(ip: *Interp, c: *Command) callconv(.c) c_int {
    if (!c.live) return -1;
    _ = host.cmd_delete(ip.handle, c.name.ptr, c.name.len);
    forget(c);
    return 0;
}

// The non-recursive engine. A frame has the script of `Tcl_NREvalObj`
// and the callbacks of `Tcl_NRAddCallback`. After the function of a
// command returns, the script runs, and then the callbacks, last in
// first, each with the code of the step before it.

const Callback = struct { proc: NRPostProc, data: [4]?*anyopaque };

const NRFrame = struct {
    eval: ?*Obj = null,
    eval_flags: c_int = 0,
    callbacks: std.ArrayList(Callback) = .empty,
    /// The objects of `Tcl_GetVar2Ex` and `Tcl_ObjSetVar2`. In Tcl the
    /// variable owns them. Here the frame owns them until the command
    /// returns.
    owned: std.ArrayList(*Obj) = .empty,
};

var frames: std.ArrayList(NRFrame) = .empty;

fn top() ?*NRFrame {
    if (frames.items.len == 0) return null;
    return &frames.items[frames.items.len - 1];
}

/// Keeps `o` alive until the current command returns.
fn own(o: *Obj) *Obj {
    incr(o);
    if (top()) |f| f.owned.append(gpa, o) catch panicText("out of memory") else {
        // Outside a command, for example in the init function, the object
        // stays.
    }
    return o;
}

fn runNR(ip: *Interp, first: c_int) c_int {
    var code = first;
    while (true) {
        const f = top().?;
        if (f.eval) |o| {
            f.eval = null;
            code = Tcl_EvalObjEx(ip, o, f.eval_flags);
            decr(o);
            continue;
        }
        const cb = f.callbacks.pop() orelse break;
        var d = cb.data;
        code = cb.proc(&d, ip, code);
    }
    return code;
}

fn pushFrame() void {
    frames.append(gpa, .{}) catch panicText("out of memory");
}

fn popFrame() void {
    var f = frames.pop().?;
    for (f.owned.items) |o| decr(o);
    f.owned.deinit(gpa);
    f.callbacks.deinit(gpa);
}

pub fn Tcl_NREvalObj(_: *Interp, o: *Obj, flags: c_int) callconv(.c) c_int {
    const f = top() orelse panicText("Tcl_NREvalObj: no command runs");
    incr(o);
    if (f.eval) |old| decr(old);
    f.eval = o;
    f.eval_flags = flags;
    return OK;
}

pub fn Tcl_NRAddCallback(_: *Interp, proc: NRPostProc, d0: ?*anyopaque, d1: ?*anyopaque, d2: ?*anyopaque, d3: ?*anyopaque) callconv(.c) void {
    const f = top() orelse panicText("Tcl_NRAddCallback: no command runs");
    f.callbacks.append(gpa, .{ .proc = proc, .data = .{ d0, d1, d2, d3 } }) catch panicText("out of memory");
}

pub fn Tcl_NRCallObjProc(ip: *Interp, proc: ObjCmdProc, cd: ?*anyopaque, objc: c_int, objv: [*]const *Obj) callconv(.c) c_int {
    pushFrame();
    defer popFrame();
    return runNR(ip, proc(cd, ip, objc, objv));
}

// The objects of short text arguments are kept in a table by their
// text. The table holds one reference, so a command sees a shared
// object, as in Tcl, where the object of a literal word lives in the
// compiled script. The next call with the same text gets the same object
// and its internal form, for example the index of
// `Tcl_GetIndexFromObjStruct`.

const arg_cache_bits = 8;
const arg_cache_max = 128;
var arg_cache: [1 << arg_cache_bits]?*Obj = @splat(null);

fn argObj(a: Arg) *Obj {
    if (a.kind != 0 or a.len > arg_cache_max) return objOf(a);
    const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(a.bits)));
    const s = p[0..a.len];
    const h = std.hash.Wyhash.hash(0, s);
    const slot = &arg_cache[@intCast(h >> (64 - arg_cache_bits))];
    if (slot.*) |o| {
        // A command can change the text of the object only when it has
        // the sole reference, so the text is checked.
        if (o.bytes != null and o.length == a.len and std.mem.eql(u8, o.bytes.?[0..a.len], s)) return o;
        decr(o);
    }
    const o = objOf(a);
    incr(o);
    slot.* = o;
    return o;
}

/// Runs command `id` with the `argc` arguments of `ztcl_cext_args`.
/// Gives the code of Tcl, and the result in `reply`.
fn ztcl_cext_dispatch(id: u32, argc: usize) callconv(.c) i32 {
    const c = commands.items[id];
    const ip = c.interp;
    var small: [16]*Obj = undefined;
    const objv = if (argc <= small.len) small[0..argc] else gpa.alloc(*Obj, argc) catch panicText("out of memory");
    defer if (argc > small.len) gpa.free(objv);
    // The text of each argument is in `xbuf`, so the objects copy it
    // before a nested call uses the buffer again.
    for (args_area.items.ptr[0..argc], objv) |a, *o| {
        o.* = argObj(a);
        incr(o.*);
    }
    defer for (objv) |o| decr(o);
    Tcl_ResetResult(ip);
    pushFrame();
    const code = if (c.nre) |nre| runNR(ip, nre(c.cd, ip, @intCast(argc), objv.ptr)) else c.proc.?(c.cd, ip, @intCast(argc), objv.ptr);
    popFrame();
    reply = argOf(result(ip));
    return code;
}

/// Makes the interp of the package for interp `handle` of ztcl.
/// Sets the `tcl_precision` of the text of doubles. ztcl gives its value
/// before a command of the package when it changes.
fn ztcl_cext_precision(p: u32) callconv(.c) void {
    value.precision = @intCast(@min(p, 17));
}

fn ztcl_cext_interp(handle: u32) callconv(.c) *Interp {
    const ip = gpa.create(Interp) catch panicText("out of memory");
    ip.* = .{ .handle = handle };
    return ip;
}

/// Puts the result of `ip` in `reply`, after the init function.
fn ztcl_cext_result(ip: *Interp) callconv(.c) *Arg {
    reply = argOf(result(ip));
    return &reply;
}

/// The result object of a reply from ztcl.
fn takeReply(ip: *Interp) void {
    Tcl_SetObjResult(ip, objOf(reply));
}

pub fn Tcl_EvalObjEx(ip: *Interp, o: *Obj, flags: c_int) callconv(.c) c_int {
    incr(o);
    defer decr(o);
    const s = text(o);
    const code = host.eval(ip.handle, s.ptr, s.len, flags);
    takeReply(ip);
    return code;
}

fn evalText(ip: *Interp, s: []const u8, flags: c_int) c_int {
    const code = host.eval(ip.handle, s.ptr, s.len, flags);
    takeReply(ip);
    return code;
}

const TCL_EVAL_GLOBAL: c_int = 0x20000;

pub fn Tcl_Eval(ip: *Interp, script: [*:0]const u8) callconv(.c) c_int {
    return evalText(ip, std.mem.span(script), 0);
}

pub fn Tcl_EvalEx(ip: *Interp, script: [*]const u8, len: c_int, flags: c_int) callconv(.c) c_int {
    return evalText(ip, if (len < 0) std.mem.span(@as([*:0]const u8, @ptrCast(script))) else script[0..@intCast(len)], flags);
}

pub fn Tcl_GlobalEval(ip: *Interp, script: [*:0]const u8) callconv(.c) c_int {
    return evalText(ip, std.mem.span(script), TCL_EVAL_GLOBAL);
}

pub fn Tcl_VarEval(ip: *Interp, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    while (true) {
        const p = @cVaArg(&ap, ?[*:0]const u8) orelse break;
        out.appendSlice(gpa, std.mem.span(p)) catch panicText("out of memory");
    }
    return evalText(ip, out.items, 0);
}

const TCL_LEAVE_ERR_MSG: c_int = 0x200;

/// The name `name1(name2)`, or `name1`.
fn varName(buf: *std.ArrayList(u8), n1: []const u8, n2: ?[]const u8) []const u8 {
    const b = n2 orelse return n1;
    buf.appendSlice(gpa, n1) catch panicText("out of memory");
    buf.append(gpa, '(') catch panicText("out of memory");
    buf.appendSlice(gpa, b) catch panicText("out of memory");
    buf.append(gpa, ')') catch panicText("out of memory");
    return buf.items;
}

fn getVar(ip: *Interp, n1: []const u8, n2: ?[]const u8, flags: c_int) ?*Obj {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const n = varName(&buf, n1, n2);
    if (host.var_get(ip.handle, n.ptr, n.len, flags) != 0) {
        if (flags & TCL_LEAVE_ERR_MSG != 0) takeReply(ip);
        return null;
    }
    return own(objOf(reply));
}

pub fn Tcl_GetVar2Ex(ip: *Interp, n1: [*:0]const u8, n2: ?[*:0]const u8, flags: c_int) callconv(.c) ?*Obj {
    return getVar(ip, std.mem.span(n1), if (n2) |p| std.mem.span(p) else null, flags);
}

pub fn Tcl_ObjGetVar2(ip: *Interp, n1: *Obj, n2: ?*Obj, flags: c_int) callconv(.c) ?*Obj {
    return getVar(ip, text(n1), if (n2) |p| text(p) else null, flags);
}

pub fn Tcl_GetVar2(ip: *Interp, n1: [*:0]const u8, n2: ?[*:0]const u8, flags: c_int) callconv(.c) ?[*:0]u8 {
    const o = Tcl_GetVar2Ex(ip, n1, n2, flags) orelse return null;
    return Tcl_GetString(o);
}

pub fn Tcl_GetVar(ip: *Interp, n: [*:0]const u8, flags: c_int) callconv(.c) ?[*:0]u8 {
    return Tcl_GetVar2(ip, n, null, flags);
}

fn setVar(ip: *Interp, n1: []const u8, n2: ?[]const u8, v: *Obj, flags: c_int) ?*Obj {
    _ = own(v);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const n = varName(&buf, n1, n2);
    const a = argOf(v);
    if (host.var_set(ip.handle, n.ptr, n.len, &a, flags) != 0) {
        if (flags & TCL_LEAVE_ERR_MSG != 0) takeReply(ip);
        return null;
    }
    return v;
}

pub fn Tcl_ObjSetVar2(ip: *Interp, n1: *Obj, n2: ?*Obj, v: *Obj, flags: c_int) callconv(.c) ?*Obj {
    return setVar(ip, text(n1), if (n2) |p| text(p) else null, v, flags);
}

pub fn Tcl_SetVar2Ex(ip: *Interp, n1: [*:0]const u8, n2: ?[*:0]const u8, v: *Obj, flags: c_int) callconv(.c) ?*Obj {
    return setVar(ip, std.mem.span(n1), if (n2) |p| std.mem.span(p) else null, v, flags);
}

pub fn Tcl_SetVar2(ip: *Interp, n1: [*:0]const u8, n2: ?[*:0]const u8, s: [*:0]const u8, flags: c_int) callconv(.c) ?[*:0]u8 {
    const o = Tcl_SetVar2Ex(ip, n1, n2, Tcl_NewStringObj(s, -1), flags) orelse return null;
    return Tcl_GetString(o);
}

pub fn Tcl_SetVar(ip: *Interp, n: [*:0]const u8, s: [*:0]const u8, flags: c_int) callconv(.c) ?[*:0]u8 {
    return Tcl_SetVar2(ip, n, null, s, flags);
}

pub fn Tcl_PkgProvideEx(ip: *Interp, name: [*:0]const u8, version: [*:0]const u8, _: ?*const anyopaque) callconv(.c) c_int {
    const n = std.mem.span(name);
    const v = std.mem.span(version);
    if (host.pkg_provide(ip.handle, n.ptr, n.len, v.ptr, v.len) != 0) {
        takeReply(ip);
        return ERROR;
    }
    return OK;
}

/// Runs `bgerror` with the result. An error of `bgerror` is dropped.
pub fn Tcl_BackgroundError(ip: *Interp) callconv(.c) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "bgerror ") catch panicText("out of memory");
    value.appendElement(gpa, &out, text(result(ip)), false) catch panicText("out of memory");
    _ = host.eval(ip.handle, out.items.ptr, out.items.len, TCL_EVAL_GLOBAL);
    Tcl_ResetResult(ip);
}

comptime {
    if (builtin.target.cpu.arch == .wasm32) {
        @export(&ztcl_cext_buf, .{ .name = "ztcl_cext_buf" });
        @export(&ztcl_cext_args, .{ .name = "ztcl_cext_args" });
        @export(&ztcl_cext_reply, .{ .name = "ztcl_cext_reply" });
        @export(&ztcl_cext_dispatch, .{ .name = "ztcl_cext_dispatch" });
        @export(&ztcl_cext_interp, .{ .name = "ztcl_cext_interp" });
        @export(&ztcl_cext_result, .{ .name = "ztcl_cext_result" });
        @export(&ztcl_cext_precision, .{ .name = "ztcl_cext_precision" });
    }
}

pub fn Tcl_Panic(format: [*:0]const u8, ...) callconv(.c) noreturn {
    // The format arguments are not expanded.
    panicText(std.mem.span(format));
}

/// A slot with no implementation.
fn missing(comptime n: usize) *const anyopaque {
    return @ptrCast(&struct {
        fn f() callconv(.c) noreturn {
            panicText(std.fmt.comptimePrint("slot {d} of the Tcl stubs table has no implementation", .{n}));
        }
    }.f);
}

// ---- The table ----

pub const slot_count = tables.len(.public);

/// The groups of the WebAssembly path, for the builder of `table.zig`.
/// The slots of this file come first, then the slots of the two paths.
const groups = .{
    @This(),
    @import("obj.zig").slots,
    @import("chan.zig").slots,
    @import("mem.zig").slots,
};

fn missingFn(comptime k: tables.Kind, comptime n: usize) *const anyopaque {
    _ = k;
    return missing(n);
}

pub const Table = tables.Table(slot_count);

/// TCL_STUB_MAGIC of Tcl 8.6.
pub const stub_magic = tables.magic;

pub const table: Table = .{ .magic = stub_magic, .hooks = null, .slots = tables.fill(groups, .public, missingFn) };

/// The number of slots with an implementation.
pub const implemented_count = blk: {
    @setEvalBranchQuota(400_000);
    var n: usize = 0;
    for (0..slot_count) |i| {
        if (tables.name(.public, i)) |nm| {
            if (tables.find(groups, nm) != null) n += 1;
        }
    }
    break :blk n;
};

/// The pointers that the stubs macros of `tcl.h` read.
pub var tclStubsPtr: ?*const Table = null;
pub var tclPlatStubsPtr: ?*const anyopaque = null;
pub var tclIntStubsPtr: ?*const anyopaque = null;
pub var tclIntPlatStubsPtr: ?*const anyopaque = null;

pub fn Tcl_InitStubs(ip: *Interp, version: ?[*:0]const u8, exact: c_int) callconv(.c) ?[*:0]const u8 {
    tclStubsPtr = &table;
    return Tcl_PkgRequireEx(ip, "Tcl", version, exact, null);
}

comptime {
    if (builtin.target.cpu.arch == .wasm32) {
        @export(&tclStubsPtr, .{ .name = "tclStubsPtr" });
        @export(&tclPlatStubsPtr, .{ .name = "tclPlatStubsPtr" });
        @export(&tclIntStubsPtr, .{ .name = "tclIntStubsPtr" });
        @export(&tclIntPlatStubsPtr, .{ .name = "tclIntPlatStubsPtr" });
        @export(&Tcl_InitStubs, .{ .name = "Tcl_InitStubs" });
    }
}

// ---- Tests ----

const testing = std.testing;

fn call(comptime n: usize, comptime F: type) F {
    return @ptrCast(@alignCast(table.slots[n].?));
}

test "the layout of Tcl_Obj" {
    if (@sizeOf(usize) == 8) try testing.expectEqual(48, @sizeOf(Obj));
    if (@sizeOf(usize) == 4) try testing.expectEqual(24, @sizeOf(Obj));
    try testing.expectEqual(@sizeOf(usize), @offsetOf(Obj, "bytes"));
    try testing.expectEqual(@sizeOf(Obj) - @sizeOf(Rep), @offsetOf(Obj, "rep"));
}

test "ints and doubles get the text of Tcl on demand" {
    const i = Tcl_NewWideIntObj(-1234567);
    incr(i);
    defer decr(i);
    try testing.expect(i.bytes == null);
    try testing.expectEqualStrings("-1234567", std.mem.span(Tcl_GetString(i)));
    try testing.expectEqualStrings(if (@sizeOf(c_long) == 8) "int" else "wideInt", std.mem.span(i.typePtr.?.name));
    const d = Tcl_NewDoubleObj(1.0);
    incr(d);
    defer decr(d);
    try testing.expectEqualStrings("1.0", std.mem.span(Tcl_GetString(d)));
    const e = Tcl_NewDoubleObj(0.1);
    incr(e);
    defer decr(e);
    try testing.expectEqualStrings("0.1", std.mem.span(Tcl_GetString(e)));
}

test "a string shimmers to an int and keeps its text" {
    var ip: Interp = .{};
    defer Tcl_ResetResult(&ip);
    const o = Tcl_NewStringObj("0x10", -1);
    incr(o);
    defer decr(o);
    var w: i64 = 0;
    try testing.expectEqual(OK, Tcl_GetWideIntFromObj(&ip, o, &w));
    try testing.expectEqual(16, w);
    try testing.expectEqualStrings("0x10", std.mem.span(Tcl_GetString(o)));
    const bad = Tcl_NewStringObj("abc", 3);
    incr(bad);
    defer decr(bad);
    try testing.expectEqual(ERROR, Tcl_GetWideIntFromObj(&ip, bad, &w));
    try testing.expectEqualStrings("expected integer but got \"abc\"", std.mem.span(Tcl_GetStringResult(&ip)));
    var d: f64 = 0;
    try testing.expectEqual(OK, Tcl_GetDoubleFromObj(&ip, Tcl_NewStringObj("2.5", -1), &d));
    try testing.expectEqual(2.5, d);
}

test "booleans take the words of Tcl" {
    var ip: Interp = .{};
    defer Tcl_ResetResult(&ip);
    var b: c_int = 0;
    for ([_][]const u8{ "true", "YES", "on", "1", "t", "10" }) |s| {
        b = 0;
        try testing.expectEqual(OK, Tcl_GetBooleanFromObj(&ip, Tcl_NewStringObj(s.ptr, @intCast(s.len)), &b));
        try testing.expectEqual(1, b);
    }
    for ([_][]const u8{ "false", "no", "off", "0", "f" }) |s| {
        b = 1;
        try testing.expectEqual(OK, Tcl_GetBooleanFromObj(&ip, Tcl_NewStringObj(s.ptr, @intCast(s.len)), &b));
        try testing.expectEqual(0, b);
    }
    try testing.expectEqual(ERROR, Tcl_GetBooleanFromObj(&ip, Tcl_NewStringObj("o", -1), &b));
    try testing.expectEqualStrings("expected boolean value but got \"o\"", std.mem.span(Tcl_GetStringResult(&ip)));
}

test "lists have the quoting of the list command" {
    var ip: Interp = .{};
    defer Tcl_ResetResult(&ip);
    const l = Tcl_NewListObj(0, null);
    incr(l);
    defer decr(l);
    for ([_][]const u8{ "a", "b c", "", "{x" }) |s| {
        try testing.expectEqual(OK, Tcl_ListObjAppendElement(&ip, l, Tcl_NewStringObj(s.ptr, @intCast(s.len))));
    }
    try testing.expectEqual(OK, Tcl_ListObjAppendElement(&ip, l, Tcl_NewWideIntObj(7)));
    try testing.expectEqualStrings("a {b c} {} \\{x 7", std.mem.span(Tcl_GetString(l)));
    // The text parses back to the same elements.
    const back = Tcl_NewStringObj(Tcl_GetString(l), -1);
    incr(back);
    defer decr(back);
    var n: c_int = 0;
    var v: [*]*Obj = undefined;
    try testing.expectEqual(OK, Tcl_ListObjGetElements(&ip, back, &n, &v));
    try testing.expectEqual(5, n);
    try testing.expectEqualStrings("{x", std.mem.span(Tcl_GetString(v[3])));
    const bad = Tcl_NewStringObj("a {b", -1);
    incr(bad);
    defer decr(bad);
    try testing.expectEqual(ERROR, Tcl_ListObjLength(&ip, bad, &n));
    try testing.expectEqualStrings("unmatched open brace in list", std.mem.span(Tcl_GetStringResult(&ip)));
}

test "byte arrays keep each byte" {
    const data = [_]u8{ 0, 1, 0x7F, 0x80, 0xFF };
    const o = Tcl_NewByteArrayObj(&data, data.len);
    incr(o);
    defer decr(o);
    try testing.expectEqualStrings("bytearray", std.mem.span(o.typePtr.?.name));
    try testing.expectEqualSlices(u8, "\xC0\x80\x01\x7F\xC2\x80\xC3\xBF", std.mem.span(Tcl_GetString(o)));
    // A string gives the low 8 bits of each character.
    const s = Tcl_NewStringObj(Tcl_GetString(o), -1);
    incr(s);
    defer decr(s);
    var n: c_int = 0;
    const p = Tcl_GetByteArrayFromObj(s, &n);
    try testing.expectEqualSlices(u8, &data, p[0..@intCast(n)]);
}

test "the result and the append slots" {
    var ip: Interp = .{};
    defer Tcl_ResetResult(&ip);
    call(70, *const fn (*Interp, ...) callconv(.c) void)(&ip, @as([*:0]const u8, "a"), @as([*:0]const u8, "bc"), @as(?[*:0]const u8, null));
    try testing.expectEqualStrings("abc", std.mem.span(Tcl_GetStringResult(&ip)));
    Tcl_AppendElement(&ip, "d e");
    try testing.expectEqualStrings("abc {d e}", std.mem.span(Tcl_GetStringResult(&ip)));
    Tcl_ResetResult(&ip);
    try testing.expectEqualStrings("", std.mem.span(Tcl_GetStringResult(&ip)));
    const argv = [_]*Obj{ Tcl_NewStringObj("db", -1), Tcl_NewStringObj("eval", -1) };
    for (argv) |o| incr(o);
    defer for (argv) |o| decr(o);
    Tcl_WrongNumArgs(&ip, 2, &argv, "sql ?script?");
    try testing.expectEqualStrings("wrong # args: should be \"db eval sql ?script?\"", std.mem.span(Tcl_GetStringResult(&ip)));
}

test "dynamic strings grow past the static space" {
    var ds: DString = undefined;
    Tcl_DStringInit(&ds);
    defer Tcl_DStringFree(&ds);
    var i: usize = 0;
    while (i < 100) : (i += 1) _ = Tcl_DStringAppend(&ds, "abc", 3);
    try testing.expectEqual(300, ds.length);
    _ = Tcl_DStringAppendElement(&ds, "x y");
    try testing.expect(std.mem.endsWith(u8, std.mem.span(@as([*:0]u8, @ptrCast(ds.string))), "abc {x y}"));
}

test "Tcl_GetIndexFromObjStruct accepts a unique prefix and caches it" {
    var ip: Interp = .{};
    defer Tcl_ResetResult(&ip);
    const names = [_]?[*:0]const u8{ "close", "collate", "eval", null };
    var idx: c_int = -1;
    const o = Tcl_NewStringObj("ev", -1);
    incr(o);
    defer decr(o);
    try testing.expectEqual(OK, Tcl_GetIndexFromObjStruct(&ip, o, &names, @sizeOf(?[*:0]const u8), "option", 0, &idx));
    try testing.expectEqual(2, idx);
    try testing.expect(o.typePtr == &obj.index_type);
    try testing.expectEqual(OK, Tcl_GetIndexFromObjStruct(&ip, o, &names, @sizeOf(?[*:0]const u8), "option", 0, &idx));
    try testing.expectEqual(2, idx);
    try testing.expectEqualStrings("ev", std.mem.span(Tcl_GetString(o)));
    const c = Tcl_NewStringObj("c", -1);
    incr(c);
    defer decr(c);
    try testing.expectEqual(ERROR, Tcl_GetIndexFromObjStruct(&ip, c, &names, @sizeOf(?[*:0]const u8), "option", 0, &idx));
    try testing.expectEqualStrings("ambiguous option \"c\": must be close, collate, or eval", std.mem.span(Tcl_GetStringResult(&ip)));
}

test "freed records go to the free list" {
    const a = Tcl_NewStringObj("x", 1);
    incr(a);
    decr(a);
    const b = Tcl_NewObj();
    try testing.expect(a == b);
    incr(b);
    decr(b);
}

test "the last unregister of a channel calls its close procedure" {
    const S = struct {
        var closed: c_int = 0;
        fn close(data: ?*anyopaque, _: ?*Interp) callconv(.c) c_int {
            const n: *c_int = @ptrCast(@alignCast(data.?));
            closed += n.*;
            return OK;
        }
    };
    var tag: c_int = 7;
    const t: ChannelType = .{ .name = "test", .version = null, .close = &S.close, .input = null, .output = null, .seek = null, .set_option = null, .get_option = null, .watch = null, .get_handle = null, .close2 = null };
    const c = call(88, *const fn (*const ChannelType, ?[*:0]const u8, ?*anyopaque, c_int) callconv(.c) *Channel)(&t, "incrblob_1", &tag, 6);
    try testing.expectEqualStrings("incrblob_1", std.mem.span(call(156, *const fn (*Channel) callconv(.c) [*:0]const u8)(c)));
    call(210, *const fn (?*Interp, ?*Channel) callconv(.c) void)(null, c);
    call(210, *const fn (?*Interp, ?*Channel) callconv(.c) void)(null, c);
    const unreg = call(252, *const fn (?*Interp, *Channel) callconv(.c) c_int);
    try testing.expectEqual(OK, unreg(null, c));
    try testing.expectEqual(@as(c_int, 0), S.closed);
    try testing.expectEqual(OK, unreg(null, c));
    try testing.expectEqual(@as(c_int, 7), S.closed);
}

test "the table has the magic number and each slot" {
    try testing.expectEqual(stub_magic, table.magic);
    try testing.expect(table.slots[56] == @as(*const anyopaque, @ptrCast(&Tcl_NewStringObj)));
    try testing.expect(implemented_count > 60);
}

/// A fake ztcl for the tests: `eval` gives the script back as the
/// result, and the variables are in a map.
const Fake = struct {
    var vars: std.StringHashMapUnmanaged([]u8) = .empty;
    var evals: usize = 0;
    var keep: std.ArrayList(u8) = .empty;

    fn cmdCreate(_: u32, _: u32, _: [*]const u8, _: usize) callconv(.c) i32 {
        return 0;
    }
    fn cmdDelete(_: u32, _: [*]const u8, _: usize) callconv(.c) i32 {
        return 0;
    }
    fn replyText(s: []const u8) void {
        keep.clearRetainingCapacity();
        keep.appendSlice(gpa, s) catch unreachable;
        reply = .{ .kind = 0, .len = @intCast(s.len), .bits = @intFromPtr(keep.items.ptr) };
    }
    fn eval(_: u32, p: [*]const u8, n: usize, _: c_int) callconv(.c) i32 {
        evals += 1;
        replyText(p[0..n]);
        return 0;
    }
    fn varGet(_: u32, p: [*]const u8, n: usize, _: c_int) callconv(.c) i32 {
        const v = vars.get(p[0..n]) orelse {
            replyText("no such variable");
            return 1;
        };
        replyText(v);
        return 0;
    }
    fn varSet(_: u32, p: [*]const u8, n: usize, a: *const Arg, _: c_int) callconv(.c) i32 {
        const o = objOf(a.*);
        incr(o);
        defer decr(o);
        const k = gpa.dupe(u8, p[0..n]) catch unreachable;
        vars.put(gpa, k, gpa.dupe(u8, text(o)) catch unreachable) catch unreachable;
        return 0;
    }
    fn provide(_: u32, _: [*]const u8, _: usize, _: [*]const u8, _: usize) callconv(.c) i32 {
        return 0;
    }
    const h: Host = .{ .cmd_create = cmdCreate, .cmd_delete = cmdDelete, .eval = eval, .var_get = varGet, .var_set = varSet, .pkg_provide = provide };
};

/// A command that counts to the int of its argument through
/// `Tcl_NREvalObj` and a callback, as `db eval` with a script does.
const Count = struct {
    var rows: c_int = 0;
    fn next(data: [*]?*anyopaque, ip: *Interp, code: c_int) callconv(.c) c_int {
        if (code != OK) return code;
        const left: *c_int = @ptrCast(@alignCast(data[0].?));
        if (left.* == 0) {
            Tcl_SetObjResult(ip, Tcl_NewIntObj(rows));
            return OK;
        }
        left.* -= 1;
        rows += 1;
        _ = Tcl_ObjSetVar2(ip, Tcl_NewStringObj("row", -1), null, Tcl_NewIntObj(rows), 0);
        Tcl_NRAddCallback(ip, next, left, null, null, null);
        return Tcl_NREvalObj(ip, Tcl_NewStringObj("body", -1), 0);
    }
    var left_store: c_int = 0;
    fn cmd(_: ?*anyopaque, ip: *Interp, objc: c_int, objv: [*]const *Obj) callconv(.c) c_int {
        if (objc != 2) {
            Tcl_WrongNumArgs(ip, 1, objv, "n");
            return ERROR;
        }
        if (Tcl_GetIntFromObj(ip, objv[1], &left_store) != OK) return ERROR;
        rows = 0;
        Tcl_NRAddCallback(ip, next, &left_store, null, null, null);
        return OK;
    }
};

test "a dispatch runs the script and the callbacks of the non-recursive engine" {
    const saved = host;
    host = Fake.h;
    defer host = saved;
    const ip = ztcl_cext_interp(1);
    defer gpa.destroy(ip);
    defer Tcl_ResetResult(ip);
    const c = Tcl_NRCreateCommand(ip, "count", null, Count.cmd, null, null);
    const id: u32 = @intCast(std.mem.indexOfScalar(*Command, commands.items, c).?);
    const argv = ztcl_cext_args(2);
    argv[0] = .{ .kind = 0, .len = 5, .bits = @intFromPtr("count".ptr) };
    argv[1] = .{ .kind = 1, .len = 0, .bits = 3 };
    Fake.evals = 0;
    try testing.expectEqual(OK, ztcl_cext_dispatch(id, 2));
    try testing.expectEqual(1, reply.kind);
    try testing.expectEqual(3, reply.bits);
    try testing.expectEqual(3, Fake.evals);
    try testing.expectEqualStrings("3", Fake.vars.get("row").?);
    try testing.expect(frames.items.len == 0);
    argv[1] = .{ .kind = 0, .len = 1, .bits = @intFromPtr("x".ptr) };
    try testing.expectEqual(ERROR, ztcl_cext_dispatch(id, 2));
    try testing.expectEqualStrings("expected integer but got \"x\"", @as([*]const u8, @ptrFromInt(@as(usize, @intCast(reply.bits))))[0..reply.len]);
    // A variable that ztcl does not have gives null and the message.
    try testing.expect(Tcl_GetVar2Ex(ip, "nope", null, TCL_LEAVE_ERR_MSG) == null);
    try testing.expectEqualStrings("no such variable", std.mem.span(Tcl_GetStringResult(ip)));
    try testing.expectEqual(OK, Tcl_DeleteCommandFromToken(ip, c));
}

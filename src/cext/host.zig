//! The slots that call ztcl: commands, scripts, variables, the
//! non-recursive engine, and `Tcl_PkgProvideEx`. The native path
//! (`stubs.zig`) and the WebAssembly path (`wasm_stubs.zig`) use this one
//! file, so each slot here has one implementation for the two paths.
//!
//! A call to ztcl goes through `host`, a set of functions with the
//! handle of the interp of ztcl. In the WebAssembly path, they are the
//! imports of the module `ztcl`. In the native path, `native.zig` sets
//! them to functions that call the interpreter. A value crosses as an
//! `Arg`: its kind, and an int, a double, or the address and the length
//! of its text. Text from ztcl is in the exchange buffer
//! (`ztcl_cext_buf`). ztcl calls a command of a package through
//! `ztcl_cext_dispatch` with the arguments in `ztcl_cext_args`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../value.zig");
const obj = @import("obj.zig");

const gpa = std.heap.c_allocator;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();

// The names of obj.zig that this file uses.
const DString = obj.DString;
const ERROR = obj.ERROR;
const Interp = obj.Interp;
const OK = obj.OK;
const Obj = obj.Obj;
const Tcl_DStringInit = obj.Tcl_DStringInit;
const Tcl_GetIndexFromObjStruct = obj.Tcl_GetIndexFromObjStruct;
const Tcl_GetString = obj.Tcl_GetString;
const Tcl_NewDoubleObj = obj.Tcl_NewDoubleObj;
const Tcl_NewStringObj = obj.Tcl_NewStringObj;
const Tcl_NewWideIntObj = obj.Tcl_NewWideIntObj;
const Tcl_ResetResult = obj.Tcl_ResetResult;
const Tcl_SetObjResult = obj.Tcl_SetObjResult;
const decr = obj.decr;
const dsAppend = obj.dsAppend;
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

pub fn noHost() noreturn {
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
pub threadlocal var xbuf: std.ArrayList(u8) = .empty;
pub threadlocal var args_area: std.ArrayList(Arg) = .empty;

pub fn ztcl_cext_buf(len: usize) callconv(.c) [*]u8 {
    xbuf.ensureTotalCapacity(gpa, @max(len, 1)) catch panicText("out of memory");
    return xbuf.items.ptr;
}

pub fn ztcl_cext_args(argc: usize) callconv(.c) [*]Arg {
    args_area.ensureTotalCapacity(gpa, @max(argc, 1)) catch panicText("out of memory");
    return args_area.items.ptr;
}

pub fn ztcl_cext_reply() callconv(.c) *Arg {
    return &reply;
}

/// The object of a reply or an argument from ztcl.
pub fn objOf(a: Arg) *Obj {
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
pub fn argOf(o: *Obj) Arg {
    if (o.typePtr == &obj.wide_type) return .{ .kind = 1, .len = 0, .bits = @bitCast(o.rep.wide) };
    if (o.typePtr == &obj.double_type) return .{ .kind = 2, .len = 0, .bits = @bitCast(o.rep.double) };
    const s = text(o);
    return .{ .kind = 0, .len = @intCast(s.len), .bits = @intFromPtr(s.ptr) };
}

pub const ObjCmdProc = *const fn (?*anyopaque, *Interp, c_int, [*]const *Obj) callconv(.c) c_int;
pub const DeleteProc = *const fn (?*anyopaque) callconv(.c) void;
pub const NRPostProc = *const fn ([*]?*anyopaque, *Interp, c_int) callconv(.c) c_int;

pub const Command = struct {
    proc: ?ObjCmdProc,
    nre: ?ObjCmdProc,
    cd: ?*anyopaque,
    delete: ?DeleteProc,
    interp: *Interp,
    name: []u8,
    live: bool = true,
};

pub threadlocal var commands: std.ArrayList(*Command) = .empty;

pub fn createCommand(ip: *Interp, name: [*:0]const u8, proc: ?ObjCmdProc, nre: ?ObjCmdProc, cd: ?*anyopaque, delete: ?DeleteProc) *Command {
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
pub fn forget(c: *Command) void {
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

pub const Callback = struct { proc: NRPostProc, data: [4]?*anyopaque };

pub const NRFrame = struct {
    eval: ?*Obj = null,
    eval_flags: c_int = 0,
    callbacks: std.ArrayList(Callback) = .empty,
    /// The objects of `Tcl_GetVar2Ex` and `Tcl_ObjSetVar2`. In Tcl the
    /// variable owns them. Here the frame owns them until the command
    /// returns.
    owned: std.ArrayList(*Obj) = .empty,
};

pub threadlocal var frames: std.ArrayList(NRFrame) = .empty;

pub fn top() ?*NRFrame {
    if (frames.items.len == 0) return null;
    return &frames.items[frames.items.len - 1];
}

/// Keeps `o` alive until the current command returns.
pub fn own(o: *Obj) *Obj {
    incr(o);
    if (top()) |f| f.owned.append(gpa, o) catch panicText("out of memory") else {
        // Outside a command, for example in the init function, the object
        // stays.
    }
    return o;
}

pub fn runNR(ip: *Interp, first: c_int) c_int {
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

pub fn pushFrame() void {
    frames.append(gpa, .{}) catch panicText("out of memory");
}

pub fn popFrame() void {
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
pub threadlocal var arg_cache: [1 << arg_cache_bits]?*Obj = @splat(null);

pub fn argObj(a: Arg) *Obj {
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
pub fn ztcl_cext_dispatch(id: u32, argc: usize) callconv(.c) i32 {
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

/// Sets the `tcl_precision` of the text of doubles. ztcl gives its value
/// before a command of the package when it changes.
pub fn ztcl_cext_precision(p: u32) callconv(.c) void {
    value.precision = @intCast(@min(p, 17));
}

/// Makes the interp of the package for interp `handle` of ztcl.
pub fn ztcl_cext_interp(handle: u32) callconv(.c) *Interp {
    const ip = gpa.create(Interp) catch panicText("out of memory");
    ip.* = .{ .handle = handle };
    return ip;
}

/// Puts the result of `ip` in `reply`, after the init function.
pub fn ztcl_cext_result(ip: *Interp) callconv(.c) *Arg {
    reply = argOf(result(ip));
    return &reply;
}

/// The result object of a reply from ztcl.
pub fn takeReply(ip: *Interp) void {
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

pub fn evalText(ip: *Interp, s: []const u8, flags: c_int) c_int {
    const code = host.eval(ip.handle, s.ptr, s.len, flags);
    takeReply(ip);
    return code;
}

pub const TCL_EVAL_GLOBAL: c_int = 0x20000;

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

pub const TCL_LEAVE_ERR_MSG: c_int = 0x200;

/// The name `name1(name2)`, or `name1`.
pub fn varName(buf: *std.ArrayList(u8), n1: []const u8, n2: ?[]const u8) []const u8 {
    const b = n2 orelse return n1;
    buf.appendSlice(gpa, n1) catch panicText("out of memory");
    buf.append(gpa, '(') catch panicText("out of memory");
    buf.appendSlice(gpa, b) catch panicText("out of memory");
    buf.append(gpa, ')') catch panicText("out of memory");
    return buf.items;
}

pub fn getVar(ip: *Interp, n1: []const u8, n2: ?[]const u8, flags: c_int) ?*Obj {
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

pub fn setVar(ip: *Interp, n1: []const u8, n2: ?[]const u8, v: *Obj, flags: c_int) ?*Obj {
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

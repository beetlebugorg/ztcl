//! The slots that call ztcl: commands, scripts, variables, the
//! non-recursive engine, and the package slots. The native path
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
const Tcl_GetBooleanFromObj = obj.Tcl_GetBooleanFromObj;
const Tcl_GetDoubleFromObj = obj.Tcl_GetDoubleFromObj;
const Tcl_GetLongFromObj = obj.Tcl_GetLongFromObj;
const setText = obj.setText;
const freeIntRep = obj.freeIntRep;
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

// ---- Commands, scripts, and variables ----
//
// These slots call ztcl through the imports of the module `ztcl`. A
// value crosses as an `Arg`: its kind, and an int, a double, or the
// address and the length of its text. The text of a reply from ztcl is
// in the exchange buffer of the package (`ztcl_cext_buf`).

/// A value that crosses the boundary. `kind` is 0 for text, 1 for an
/// int, 2 for a double, and 3 for a list. For text, `bits` is the
/// address in the memory of the side that sends it. For a list, `len` is
/// the count of elements and `bits` the address of an array of `Arg`s
/// in that memory. Text is in the modified UTF-8 of Tcl, where U+0000 is
/// the two bytes C0 80.
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
    /// Cancels the script of the interp, from any thread. Text of length
    /// 0 gives the default message. Null when the path has no cancel.
    cancel: ?*const fn (handle: u32, unwind: c_int, text: [*]const u8, len: usize) callconv(.c) i32 = null,
    /// Gives 1 when a cancel of the interp is pending, and 2 for an
    /// unwind, with the message in the reply. It takes the pending
    /// cancel. With `unwind_only`, a cancel with no unwind gives 0.
    canceled: ?*const fn (handle: u32, unwind_only: c_int) callconv(.c) i32 = null,
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
        3 => blk: {
            const o = obj.Tcl_NewListObj(0, null);
            if (a.len == 0) break :blk o;
            const p: [*]const Arg = @ptrFromInt(@as(usize, @intCast(a.bits)));
            const l = obj.listRep(o);
            l.items.ensureTotalCapacity(gpa, a.len) catch panicText("out of memory");
            for (p[0..a.len]) |e| {
                const eo = objOf(e);
                incr(eo);
                l.items.appendAssumeCapacity(eo);
            }
            break :blk o;
        },
        else => blk: {
            const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(a.bits)));
            break :blk Tcl_NewStringObj(p, @intCast(a.len));
        },
    };
}

/// The `Arg` arrays of the lists of the last `argOf`.
threadlocal var list_area: std.ArrayList(Arg) = .empty;

/// The value of an object for ztcl. Text stays in the memory of the
/// package until the next call, and the elements of a list stay until
/// the next `argOf`.
pub fn argOf(o: *Obj) Arg {
    if (o.typePtr != &obj.list_type) return leafOf(o);
    // The area does not move while it fills, so the size comes first.
    list_area.clearRetainingCapacity();
    list_area.ensureTotalCapacity(gpa, @max(elementCount(o), 1)) catch panicText("out of memory");
    return listOf(o);
}

fn leafOf(o: *Obj) Arg {
    if (o.typePtr == &obj.wide_type) return .{ .kind = 1, .len = 0, .bits = @bitCast(o.rep.wide) };
    if (o.typePtr == &obj.double_type) return .{ .kind = 2, .len = 0, .bits = @bitCast(o.rep.double) };
    const s = text(o);
    return .{ .kind = 0, .len = @intCast(s.len), .bits = @intFromPtr(s.ptr) };
}

/// The count of the elements of list `o` and of its inner lists.
fn elementCount(o: *Obj) usize {
    var n: usize = 0;
    for (obj.listRep(o).items.items) |e| n += 1 + if (e.typePtr == &obj.list_type) elementCount(e) else 0;
    return n;
}

fn listOf(o: *Obj) Arg {
    const items = obj.listRep(o).items.items;
    const start = list_area.items.len;
    list_area.items.len += items.len;
    const out = list_area.items[start..][0..items.len];
    for (items, out) |e, *a| a.* = if (e.typePtr == &obj.list_type) listOf(e) else leafOf(e);
    return .{ .kind = 3, .len = @intCast(items.len), .bits = @intFromPtr(out.ptr) };
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
    @import("chan.zig").last = ip;
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
    @import("chan.zig").last = ip;
    return ip;
}

/// Frees the interp of the package for the interp `ip.handle` of ztcl.
/// It runs the delete procs of the assoc data. The interp of ztcl calls
/// it before it goes.
pub fn ztcl_cext_interp_free(ip: *Interp) callconv(.c) void {
    @import("hash.zig").dropAssoc(ip);
    @import("chan.zig").dropInterp(ip);
    dropPkgs(ip);
    if (ip.result) |r| decr(r);
    gpa.destroy(ip);
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

// ---- Packages ----
//
// The package `Tcl` is ztcl itself at version 8.6.16. Its client data is
// the public stubs table of the path (`Interp.stub_table`), so
// `Tcl_InitStubs` of a package gets the table from `Tcl_PkgRequireEx`.
// Each other package goes to the `package` command of the interp, when
// it has one. The client data of `Tcl_PkgProvideEx` is in the list
// `Interp.pkgs`.

const tcl_version = "8.6.16";
const tcl_parts = [_]u32{ 8, 6, 16 };

/// The parts of a version such as "8.6.16". Null when the text is not a
/// version.
fn versionParts(t: []const u8, out: *[8]u32) ?[]u32 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, t, '.');
    while (it.next()) |p| {
        if (n == out.len or p.len == 0) return null;
        out[n] = std.fmt.parseInt(u32, p, 10) catch return null;
        n += 1;
    }
    return out[0..n];
}

fn versionOrder(a: []const u32, b: []const u32) std.math.Order {
    for (0..@max(a.len, b.len)) |i| {
        const x = if (i < a.len) a[i] else 0;
        const y = if (i < b.len) b[i] else 0;
        if (x != y) return std.math.order(x, y);
    }
    return .eq;
}

/// True when Tcl 8.6.16 satisfies `want`: the same major version and no
/// lower, or the same version with `exact`.
pub fn tclOk(want: []const u8, exact: bool) bool {
    var buf: [8]u32 = undefined;
    const w = versionParts(want, &buf) orelse return false;
    if (exact) return versionOrder(&tcl_parts, w) == .eq;
    return w[0] == tcl_parts[0] and versionOrder(&tcl_parts, w) != .lt;
}

/// The client data of a package of `Tcl_PkgProvideEx`.
pub const PkgData = struct {
    next: ?*PkgData,
    name: []u8,
    data: ?*anyopaque,
};

fn pkgData(ip: *Interp, name: []const u8) ?*PkgData {
    var p: ?*PkgData = @ptrCast(@alignCast(ip.pkgs));
    while (p) |d| : (p = d.next) {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}

/// Frees the list `Interp.pkgs`.
pub fn dropPkgs(ip: *Interp) void {
    while (ip.pkgs) |p| {
        const d: *PkgData = @ptrCast(@alignCast(p));
        ip.pkgs = d.next;
        gpa.free(d.name);
        gpa.destroy(d);
    }
}

fn spanOr(p: ?[*:0]const u8) []const u8 {
    return if (p) |q| std.mem.span(q) else "";
}

pub fn Tcl_PkgProvideEx(ip: *Interp, name: [*:0]const u8, version: [*:0]const u8, data: ?*anyopaque) callconv(.c) c_int {
    const n = std.mem.span(name);
    const v = std.mem.span(version);
    if (std.mem.eql(u8, n, "Tcl")) return if (std.mem.eql(u8, v, tcl_version)) OK else ERROR;
    if (host.pkg_provide(ip.handle, n.ptr, n.len, v.ptr, v.len) != 0) {
        takeReply(ip);
        return ERROR;
    }
    if (pkgData(ip, n)) |d| {
        d.data = data;
        return OK;
    }
    const d = gpa.create(PkgData) catch panicText("out of memory");
    d.* = .{ .next = @ptrCast(@alignCast(ip.pkgs)), .name = gpa.dupe(u8, n) catch panicText("out of memory"), .data = data };
    ip.pkgs = d;
    return OK;
}

pub fn Tcl_PkgProvide(ip: *Interp, name: [*:0]const u8, version: [*:0]const u8) callconv(.c) c_int {
    return Tcl_PkgProvideEx(ip, name, version, null);
}

/// `package require` or `package present` of `name`. The text of the
/// version stays valid until the command of the package returns.
fn require(ip: *Interp, name: []const u8, version: []const u8, exact: bool, data: ?*?*anyopaque, present: bool) ?[*:0]const u8 {
    if (std.mem.eql(u8, name, "Tcl")) {
        if (version.len != 0 and !tclOk(version, exact)) {
            var b: std.ArrayList(u8) = .empty;
            defer b.deinit(gpa);
            b.print(gpa, "version conflict for package \"Tcl\": have {s}, need {s}{s}", .{ tcl_version, if (exact) "exactly " else "", version }) catch panicText("out of memory");
            setResultText(ip, b.items);
            return null;
        }
        if (data) |d| d.* = @constCast(ip.stub_table);
        return tcl_version;
    }
    // The script gives the error of Tcl when the interp has no command
    // `package`.
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(gpa);
    s.appendSlice(gpa, "if {[llength [info commands ::package]]} {::package ") catch panicText("out of memory");
    s.appendSlice(gpa, if (present) "present" else "require") catch panicText("out of memory");
    if (exact) s.appendSlice(gpa, " -exact") catch panicText("out of memory");
    s.append(gpa, ' ') catch panicText("out of memory");
    value.appendElement(gpa, &s, name, false) catch panicText("out of memory");
    if (version.len != 0) {
        s.append(gpa, ' ') catch panicText("out of memory");
        value.appendElement(gpa, &s, version, false) catch panicText("out of memory");
    }
    s.appendSlice(gpa, "} else {::error ") catch panicText("out of memory");
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    msg.print(gpa, "can't find package {s}", .{name}) catch panicText("out of memory");
    value.appendElement(gpa, &s, msg.items, false) catch panicText("out of memory");
    s.appendSlice(gpa, " {} {TCL PACKAGE UNFOUND}}") catch panicText("out of memory");
    if (evalText(ip, s.items, TCL_EVAL_GLOBAL) != OK) return null;
    const o = own(result(ip));
    if (data) |d| d.* = if (pkgData(ip, name)) |p| p.data else null;
    return Tcl_GetString(o);
}

pub fn Tcl_PkgRequireEx(ip: *Interp, name: [*:0]const u8, version: ?[*:0]const u8, exact: c_int, data: ?*?*anyopaque) callconv(.c) ?[*:0]const u8 {
    return require(ip, std.mem.span(name), spanOr(version), exact != 0, data, false);
}

pub fn Tcl_PkgRequire(ip: *Interp, name: [*:0]const u8, version: ?[*:0]const u8, exact: c_int) callconv(.c) ?[*:0]const u8 {
    return require(ip, std.mem.span(name), spanOr(version), exact != 0, null, false);
}

pub fn Tcl_PkgPresentEx(ip: *Interp, name: [*:0]const u8, version: ?[*:0]const u8, exact: c_int, data: ?*?*anyopaque) callconv(.c) ?[*:0]const u8 {
    return require(ip, std.mem.span(name), spanOr(version), exact != 0, data, true);
}

pub fn Tcl_PkgPresent(ip: *Interp, name: [*:0]const u8, version: ?[*:0]const u8, exact: c_int) callconv(.c) ?[*:0]const u8 {
    return require(ip, std.mem.span(name), spanOr(version), exact != 0, null, true);
}

test "cext: the version rule of Tcl_PkgRequireEx" {
    try std.testing.expect(tclOk("8.6", false));
    try std.testing.expect(tclOk("8.4", false));
    try std.testing.expect(!tclOk("9.0", false));
    try std.testing.expect(!tclOk("8.6", true));
    try std.testing.expect(tclOk("8.6.16", true));
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

// ---- More scripts ----

pub fn Tcl_EvalObj(ip: *Interp, o: *Obj) callconv(.c) c_int {
    return Tcl_EvalObjEx(ip, o, 0);
}

pub fn Tcl_GlobalEvalObj(ip: *Interp, o: *Obj) callconv(.c) c_int {
    return Tcl_EvalObjEx(ip, o, TCL_EVAL_GLOBAL);
}

/// The text of a command of the words `objv`, with the quoting of the
/// `list` command, so each word is one word with no substitution.
fn wordsText(out: *std.ArrayList(u8), objv: []const *Obj) void {
    for (objv, 0..) |o, i| {
        if (i > 0) out.append(gpa, ' ') catch panicText("out of memory");
        value.appendElement(gpa, out, text(o), i == 0) catch panicText("out of memory");
    }
}

pub fn Tcl_EvalObjv(ip: *Interp, objc: c_int, objv: [*]const *Obj, flags: c_int) callconv(.c) c_int {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    wordsText(&out, objv[0..@intCast(objc)]);
    return evalText(ip, out.items, flags);
}

pub fn Tcl_NREvalObjv(ip: *Interp, objc: c_int, objv: [*]const *Obj, flags: c_int) callconv(.c) c_int {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    wordsText(&out, objv[0..@intCast(objc)]);
    return Tcl_NREvalObj(ip, Tcl_NewStringObj(out.items.ptr, @intCast(out.items.len)), flags);
}

pub fn Tcl_VarEvalVA(ip: *Interp, ap: *std.builtin.VaList) callconv(.c) c_int {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    while (true) {
        const p = @cVaArg(ap, ?[*:0]const u8) orelse break;
        out.appendSlice(gpa, std.mem.span(p)) catch panicText("out of memory");
    }
    return evalText(ip, out.items, 0);
}

/// Runs `cmd` and `word` as a command of two words.
fn evalWith(ip: *Interp, cmd: []const u8, word: []const u8, flags: c_int) c_int {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, cmd) catch panicText("out of memory");
    out.append(gpa, ' ') catch panicText("out of memory");
    value.appendElement(gpa, &out, word, false) catch panicText("out of memory");
    return evalText(ip, out.items, flags);
}

pub fn Tcl_EvalFile(ip: *Interp, name: [*:0]const u8) callconv(.c) c_int {
    return evalWith(ip, "source", std.mem.span(name), 0);
}

/// `TCL_NO_EVAL` of `tcl.h`. ztcl keeps no history, so the record part
/// of these two slots has no effect.
const TCL_NO_EVAL: c_int = 0x10000;

pub fn Tcl_RecordAndEval(ip: *Interp, cmd: [*:0]const u8, flags: c_int) callconv(.c) c_int {
    if (flags & TCL_NO_EVAL != 0) return OK;
    return evalText(ip, std.mem.span(cmd), TCL_EVAL_GLOBAL);
}

pub fn Tcl_RecordAndEvalObj(ip: *Interp, o: *Obj, flags: c_int) callconv(.c) c_int {
    if (flags & TCL_NO_EVAL != 0) return OK;
    return Tcl_EvalObjEx(ip, o, TCL_EVAL_GLOBAL);
}

// The expression slots run the `expr` command of ztcl.

fn expr(ip: *Interp, s: []const u8) c_int {
    return evalWith(ip, "expr", s, 0);
}

/// The object of the value of an expression, with one reference.
pub fn Tcl_ExprObj(ip: *Interp, o: *Obj, out: **Obj) callconv(.c) c_int {
    incr(o);
    defer decr(o);
    if (expr(ip, text(o)) != OK) return ERROR;
    const r = result(ip);
    incr(r);
    out.* = r;
    Tcl_ResetResult(ip);
    return OK;
}

fn exprTo(ip: *Interp, s: []const u8, comptime f: anytype, out: anytype) c_int {
    if (expr(ip, s) != OK) return ERROR;
    const r = result(ip);
    incr(r);
    defer decr(r);
    Tcl_ResetResult(ip);
    return f(ip, r, out);
}

/// The number of an expression for the long and double forms. A value
/// that is not a number gets the message of Tcl.
fn exprNumber(ip: *Interp, s: []const u8, comptime f: anytype, out: anytype) c_int {
    if (expr(ip, s) != OK) return ERROR;
    const r = result(ip);
    incr(r);
    defer decr(r);
    Tcl_ResetResult(ip);
    if (f(null, r, out) == OK) return OK;
    var w: std.ArrayList(u8) = .empty;
    defer w.deinit(gpa);
    w.print(gpa, "expected number but got \"{s}\"", .{text(r)}) catch panicText("out of memory");
    setResultText(ip, w.items);
    return ERROR;
}

pub fn Tcl_ExprLongObj(ip: *Interp, o: *Obj, out: *c_long) callconv(.c) c_int {
    return exprNumber(ip, text(o), Tcl_GetLongFromObj, out);
}

pub fn Tcl_ExprDoubleObj(ip: *Interp, o: *Obj, out: *f64) callconv(.c) c_int {
    return exprNumber(ip, text(o), Tcl_GetDoubleFromObj, out);
}

pub fn Tcl_ExprBooleanObj(ip: *Interp, o: *Obj, out: *c_int) callconv(.c) c_int {
    return exprTo(ip, text(o), Tcl_GetBooleanFromObj, out);
}

pub fn Tcl_ExprLong(ip: *Interp, s: [*:0]const u8, out: *c_long) callconv(.c) c_int {
    return exprNumber(ip, std.mem.span(s), Tcl_GetLongFromObj, out);
}

pub fn Tcl_ExprDouble(ip: *Interp, s: [*:0]const u8, out: *f64) callconv(.c) c_int {
    return exprNumber(ip, std.mem.span(s), Tcl_GetDoubleFromObj, out);
}

pub fn Tcl_ExprBoolean(ip: *Interp, s: [*:0]const u8, out: *c_int) callconv(.c) c_int {
    return exprTo(ip, std.mem.span(s), Tcl_GetBooleanFromObj, out);
}

/// The value of the expression is the result.
pub fn Tcl_ExprString(ip: *Interp, s: [*:0]const u8) callconv(.c) c_int {
    return expr(ip, std.mem.span(s));
}

/// The non-recursive form runs the expression at once. `out` gets the
/// value.
pub fn Tcl_NRExprObj(ip: *Interp, o: *Obj, out: *Obj) callconv(.c) c_int {
    incr(o);
    defer decr(o);
    if (expr(ip, text(o)) != OK) return ERROR;
    setText(out, text(result(ip)));
    freeIntRep(out);
    Tcl_ResetResult(ip);
    return OK;
}

/// The flags of `subst` in `tcl.h`.
const TCL_SUBST_COMMANDS: c_int = 1;
const TCL_SUBST_VARIABLES: c_int = 2;
const TCL_SUBST_BACKSLASHES: c_int = 4;

fn substCmd(flags: c_int) []const u8 {
    const i: usize = @intCast(flags & 7);
    return switch (i) {
        7 => "subst",
        6 => "subst -nocommands",
        5 => "subst -novariables",
        4 => "subst -nocommands -novariables",
        3 => "subst -nobackslashes",
        2 => "subst -nobackslashes -nocommands",
        1 => "subst -nobackslashes -novariables",
        else => "subst -nobackslashes -nocommands -novariables",
    };
}

/// A new object with no reference, or null with the error in the
/// result.
pub fn Tcl_SubstObj(ip: *Interp, o: *Obj, flags: c_int) callconv(.c) ?*Obj {
    incr(o);
    defer decr(o);
    if (evalWith(ip, substCmd(flags), text(o), 0) != OK) return null;
    const r = result(ip);
    incr(r);
    Tcl_ResetResult(ip);
    r.refCount -= 1;
    return r;
}

/// The non-recursive form runs `subst` at once, and the value is the
/// result.
pub fn Tcl_NRSubstObj(ip: *Interp, o: *Obj, flags: c_int) callconv(.c) c_int {
    incr(o);
    defer decr(o);
    return evalWith(ip, substCmd(flags), text(o), 0);
}

/// `TCL_CANCEL_UNWIND` of `tcl.h`.
const TCL_CANCEL_UNWIND: c_int = 0x100000;

/// Cancels the script of `ip`, from any thread. The text of `msg`
/// replaces the message "eval canceled".
pub fn Tcl_CancelEval(ip: ?*Interp, msg: ?*Obj, _: ?*anyopaque, flags: c_int) callconv(.c) c_int {
    const i = ip orelse return ERROR;
    const f = host.cancel orelse {
        setResultText(i, "Tcl_CancelEval: this path has no cancel");
        return ERROR;
    };
    const t: []const u8 = if (msg) |o| text(o) else "";
    return f(i.handle, @intFromBool(flags & TCL_CANCEL_UNWIND != 0), t.ptr, t.len);
}

/// ERROR when a cancel of `ip` is pending or an unwind runs, and the
/// pending cancel is taken. With TCL_CANCEL_UNWIND, only an unwind
/// counts. With TCL_LEAVE_ERR_MSG, the result is the message of the
/// cancel.
pub fn Tcl_Canceled(ip: *Interp, flags: c_int) callconv(.c) c_int {
    const f = host.canceled orelse return OK;
    const state = f(ip.handle, @intFromBool(flags & TCL_CANCEL_UNWIND != 0));
    if (state == 0) return OK;
    if (flags & TCL_LEAVE_ERR_MSG != 0) takeReply(ip);
    return ERROR;
}

/// Runs the command of token `c` with the words `objv`.
pub fn Tcl_NRCmdSwap(ip: *Interp, c: *Command, objc: c_int, objv: [*]const *Obj, _: c_int) callconv(.c) c_int {
    const proc = c.nre orelse c.proc orelse return ERROR;
    return Tcl_NRCallObjProc(ip, proc, c.cd, objc, objv);
}

/// The state of `Tcl_SaveInterpState`: the code, the result, and the
/// values of `::errorInfo` and `::errorCode`.
const InterpState = struct {
    code: c_int,
    result: *Obj,
    info: ?*Obj,
    code_var: ?*Obj,
};

fn readGlobal(ip: *Interp, name: []const u8) ?*Obj {
    if (host.var_get(ip.handle, name.ptr, name.len, 0) != 0) return null;
    const o = objOf(reply);
    incr(o);
    return o;
}

pub fn Tcl_SaveInterpState(ip: *Interp, code: c_int) callconv(.c) *InterpState {
    const st = gpa.create(InterpState) catch panicText("out of memory");
    const r = result(ip);
    incr(r);
    st.* = .{ .code = code, .result = r, .info = readGlobal(ip, "::errorInfo"), .code_var = readGlobal(ip, "::errorCode") };
    return st;
}

pub fn Tcl_DiscardInterpState(st: *InterpState) callconv(.c) void {
    decr(st.result);
    if (st.info) |o| decr(o);
    if (st.code_var) |o| decr(o);
    gpa.destroy(st);
}

pub fn Tcl_RestoreInterpState(ip: *Interp, st: *InterpState) callconv(.c) c_int {
    const code = st.code;
    inline for (.{ .{ "::errorInfo", "info" }, .{ "::errorCode", "code_var" } }) |p| {
        if (@field(st, p[1])) |o| {
            const a = argOf(o);
            _ = host.var_set(ip.handle, p[0].ptr, p[0].len, &a, 0);
        }
    }
    Tcl_SetObjResult(ip, st.result);
    Tcl_DiscardInterpState(st);
    return code;
}

/// True when `s` has no open brace, quote, or bracket: the rule of
/// `info complete`.
pub fn Tcl_CommandComplete(s: [*:0]const u8) callconv(.c) c_int {
    return @intFromBool(complete(std.mem.span(s)));
}

pub fn complete(s: []const u8) bool {
    var i: usize = 0;
    return scanScript(s, &i, false) and i >= s.len;
}

/// Scans commands up to the end, or up to the "]" of a nested command.
/// False when the text ends in an open word.
fn scanScript(s: []const u8, i: *usize, nested: bool) bool {
    var start = true;
    while (i.* < s.len) {
        const c = s[i.*];
        switch (c) {
            ' ', '\t', '\r', '\x0b', '\x0c' => i.* += 1,
            '\n', ';' => {
                i.* += 1;
                start = true;
                continue;
            },
            ']' => {
                if (nested) return true;
                i.* += 1;
            },
            '#' => {
                if (!start) {
                    if (!scanWord(s, i)) return false;
                } else {
                    while (i.* < s.len and s[i.*] != '\n') {
                        if (s[i.*] == '\\') i.* += 1;
                        i.* += 1;
                    }
                }
            },
            '\\' => {
                if (i.* + 1 < s.len and s[i.* + 1] == '\n') {
                    i.* += 2;
                    continue;
                }
                if (!scanWord(s, i)) return false;
            },
            else => if (!scanWord(s, i)) return false,
        }
        start = false;
    }
    return !nested;
}

fn scanWord(s: []const u8, i: *usize) bool {
    if (s[i.*] == '{') {
        var depth: usize = 0;
        while (i.* < s.len) : (i.* += 1) {
            switch (s[i.*]) {
                '\\' => i.* += 1,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        i.* += 1;
                        return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }
    const quoted = s[i.*] == '"';
    if (quoted) i.* += 1;
    while (i.* < s.len) {
        switch (s[i.*]) {
            '\\' => i.* += 2,
            '[' => {
                i.* += 1;
                if (!scanScript(s, i, true) or i.* >= s.len) return false;
                i.* += 1;
            },
            '"' => {
                i.* += 1;
                if (quoted) return true;
            },
            ' ', '\t', '\n', ';', '\r' => if (quoted) {
                i.* += 1;
            } else return true,
            ']' => if (quoted) {
                i.* += 1;
            } else return true,
            else => i.* += 1,
        }
    }
    return !quoted;
}

test "Tcl_CommandComplete follows info complete" {
    try std.testing.expect(complete("set a 1"));
    try std.testing.expect(complete(""));
    try std.testing.expect(!complete("set a {"));
    try std.testing.expect(!complete("set a \"b"));
    try std.testing.expect(!complete("set a [b"));
    try std.testing.expect(complete("set a [b {c]}]"));
    try std.testing.expect(complete("set a \\{"));
    try std.testing.expect(complete("# {\n"));
    try std.testing.expect(!complete("puts \"[x\""));
}

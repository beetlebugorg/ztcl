//! The command slots of the native path that read or change a command
//! by its name: `Tcl_CreateCommand` (a command with a string function),
//! `Tcl_GetCommandInfo`, `Tcl_SetCommandInfo`, and their forms with a
//! token. Expect and the Tcl package of newt call them.
//!
//! A command of `Tcl_CreateCommand` is a command of `host.zig` whose
//! object function is `objToStr`, with a `StrCmd` as its data.
//! `objToStr` gives the words to the string function as C strings.
//!
//! The info of a command of ztcl (a builtin or a proc) has an object
//! function that runs a copy of the command. The copy has a hidden name
//! of its own, so a new command with the old name, as Expect makes for
//! `close`, does not change what the function runs.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const cext = @import("cext.zig");
const host = @import("host.zig");
const native = @import("native.zig");
const obj = @import("obj.zig");
const interp_mod = @import("../interp.zig");

pub const slots = @This();

const gpa = std.heap.c_allocator;
const Interp = obj.Interp;
const Obj = obj.Obj;
const Command = host.Command;
const ObjCmdProc = host.ObjCmdProc;
const DeleteProc = host.DeleteProc;
const panicText = obj.panicText;

pub const CmdProc = *const fn (?*anyopaque, *Interp, c_int, [*]?[*:0]const u8) callconv(.c) c_int;

/// `Tcl_CmdInfo` of tcl.h.
pub const CmdInfo = extern struct {
    is_native_object_proc: c_int,
    obj_proc: ?ObjCmdProc,
    obj_client_data: ?*anyopaque,
    proc: ?CmdProc,
    client_data: ?*anyopaque,
    delete_proc: ?DeleteProc,
    delete_data: ?*anyopaque,
    namespace: ?*anyopaque,
};

/// The data of a command with a string function.
const StrCmd = struct {
    proc: ?CmdProc,
    cd: ?*anyopaque,
    delete: ?DeleteProc,
    delete_data: ?*anyopaque,
};

/// The data of the object function of a command of ztcl: the hidden
/// name of its copy.
const Builtin = struct {
    name: *Obj,
};

/// The legacy result of a string function starts as this text. Another
/// pointer after the call is a result that the function set in
/// `interp->result`.
const empty: [*:0]const u8 = "";

fn objToStr(cd: ?*anyopaque, ip: *Interp, objc: c_int, objv: [*]const *Obj) callconv(.c) c_int {
    const sc: *StrCmd = @ptrCast(@alignCast(cd.?));
    const n: usize = @intCast(objc);
    var small: [16]?[*:0]const u8 = undefined;
    const argv = if (n < small.len) small[0 .. n + 1] else gpa.alloc(?[*:0]const u8, n + 1) catch panicText("out of memory");
    defer if (n >= small.len) gpa.free(argv);
    for (objv[0..n], argv[0..n]) |o, *a| a.* = obj.Tcl_GetString(o);
    argv[n] = null;
    ip.result_dont_use = empty;
    ip.free_proc_dont_use = null;
    const code = sc.proc.?(sc.cd, ip, objc, argv.ptr);
    takeLegacy(ip);
    return code;
}

/// Moves a result of `interp->result` to the result object.
fn takeLegacy(ip: *Interp) void {
    const r = ip.result_dont_use;
    const f = @intFromPtr(ip.free_proc_dont_use);
    ip.result_dont_use = empty;
    ip.free_proc_dont_use = null;
    if (r == empty) return;
    obj.setResultText(ip, std.mem.span(r));
    // TCL_STATIC 0, TCL_VOLATILE 1, TCL_DYNAMIC 3, else a function.
    switch (f) {
        0, 1 => {},
        3 => std.c.free(@constCast(r)),
        else => {
            const free: *const fn ([*:0]u8) callconv(.c) void = @ptrFromInt(f);
            free(@constCast(r));
        },
    }
}

fn strDelete(cd: ?*anyopaque) callconv(.c) void {
    const sc: *StrCmd = @ptrCast(@alignCast(cd.?));
    if (sc.delete) |d| d(sc.delete_data);
    gpa.destroy(sc);
}

/// The string function of a command with an object function: the data
/// is the command.
fn strToObj(cd: ?*anyopaque, ip: *Interp, argc: c_int, argv: [*]?[*:0]const u8) callconv(.c) c_int {
    const c: *Command = @ptrCast(@alignCast(cd.?));
    const n: usize = @intCast(argc);
    const objv = gpa.alloc(*Obj, n) catch panicText("out of memory");
    defer gpa.free(objv);
    for (argv[0..n], objv) |a, *o| {
        o.* = obj.Tcl_NewStringObj(a.?, -1);
        obj.incr(o.*);
    }
    defer for (objv) |o| obj.decr(o);
    if (c.proc) |p| return p(c.cd, ip, argc, objv.ptr);
    return host.Tcl_NRCallObjProc(ip, c.nre.?, c.cd, argc, objv.ptr);
}

/// The object function of a command of ztcl: runs its copy.
fn builtinObj(cd: ?*anyopaque, ip: *Interp, objc: c_int, objv: [*]const *Obj) callconv(.c) c_int {
    const b: *Builtin = @ptrCast(@alignCast(cd.?));
    const n: usize = @intCast(objc);
    const words = gpa.alloc(*Obj, n) catch panicText("out of memory");
    defer gpa.free(words);
    words[0] = b.name;
    @memcpy(words[1..], objv[1..n]);
    return host.Tcl_EvalObjv(ip, objc, words.ptr, 0);
}

fn builtinStr(cd: ?*anyopaque, ip: *Interp, argc: c_int, argv: [*]?[*:0]const u8) callconv(.c) c_int {
    const n: usize = @intCast(argc);
    const objv = gpa.alloc(*Obj, n) catch panicText("out of memory");
    defer gpa.free(objv);
    for (argv[0..n], objv) |a, *o| {
        o.* = obj.Tcl_NewStringObj(a.?, -1);
        obj.incr(o.*);
    }
    defer for (objv) |o| obj.decr(o);
    return builtinObj(cd, ip, argc, objv.ptr);
}

pub fn Tcl_CreateCommand(ip: *Interp, name: [*:0]const u8, proc: CmdProc, cd: ?*anyopaque, delete: ?DeleteProc) callconv(.c) *Command {
    const sc = gpa.create(StrCmd) catch panicText("out of memory");
    sc.* = .{ .proc = proc, .cd = cd, .delete = delete, .delete_data = cd };
    return host.createCommand(ip, name, &objToStr, null, sc, &strDelete);
}

/// The copies of the commands of ztcl, by the command, so a second call
/// for the same command gives the same copy.
threadlocal var copies: std.AutoHashMapUnmanaged(*interp_mod.Command, *Builtin) = .empty;
threadlocal var copy_count: u32 = 0;

const Found = union(enum) { c: *Command, ztcl: *interp_mod.Command };

fn find(ip: *Interp, name: [*:0]const u8) ?Found {
    const sh: *cext.Shadow = @ptrCast(@alignCast(ip));
    const zc = sh.it.findCommand(std.mem.span(name)) orelse return null;
    if (zc.impl == .native and zc.impl.native == &native.cmdC) {
        const id = @intFromPtr(zc.ctx.?) - 1;
        if (id < host.commands.items.len) return .{ .c = host.commands.items[id] };
    }
    return .{ .ztcl = zc };
}

fn copyOf(ip: *Interp, zc: *interp_mod.Command) *Builtin {
    if (copies.get(zc)) |b| return b;
    const it = @as(*cext.Shadow, @ptrCast(@alignCast(ip))).it;
    const a = it.alloc();
    copy_count += 1;
    const key = std.fmt.allocPrint(a, "tcl::cext::orig{d}", .{copy_count}) catch panicText("out of memory");
    const nc = a.create(interp_mod.Command) catch panicText("out of memory");
    nc.* = zc.*;
    nc.name = key;
    nc.traces = null;
    it.commands.put(a, key, nc) catch panicText("out of memory");
    it.epoch += 1;
    const b = gpa.create(Builtin) catch panicText("out of memory");
    var full: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&full, "::{s}", .{key}) catch unreachable;
    b.* = .{ .name = obj.Tcl_NewStringObj(text.ptr, @intCast(text.len)) };
    obj.incr(b.name);
    copies.put(gpa, zc, b) catch panicText("out of memory");
    return b;
}

fn infoOf(c: *Command, info: *CmdInfo) void {
    if (c.proc == &objToStr) {
        const sc: *StrCmd = @ptrCast(@alignCast(c.cd.?));
        info.* = .{
            .is_native_object_proc = 0,
            .obj_proc = &objToStr,
            .obj_client_data = sc,
            .proc = sc.proc,
            .client_data = sc.cd,
            .delete_proc = sc.delete,
            .delete_data = sc.delete_data,
            .namespace = null,
        };
        return;
    }
    info.* = .{
        .is_native_object_proc = 1,
        .obj_proc = c.proc,
        .obj_client_data = c.cd,
        .proc = &strToObj,
        .client_data = c,
        .delete_proc = c.delete,
        .delete_data = c.delete_data,
        .namespace = null,
    };
}

pub fn Tcl_GetCommandInfo(ip: *Interp, name: [*:0]const u8, info: *CmdInfo) callconv(.c) c_int {
    switch (find(ip, name) orelse return 0) {
        .c => |c| infoOf(c, info),
        .ztcl => |zc| {
            const b = copyOf(ip, zc);
            info.* = .{
                .is_native_object_proc = 1,
                .obj_proc = &builtinObj,
                .obj_client_data = b,
                .proc = &builtinStr,
                .client_data = b,
                .delete_proc = null,
                .delete_data = null,
                .namespace = null,
            };
        },
    }
    return 1;
}

pub fn Tcl_GetCommandInfoFromToken(c: ?*Command, info: *CmdInfo) callconv(.c) c_int {
    const cmd = c orelse return 0;
    if (!cmd.live) return 0;
    infoOf(cmd, info);
    return 1;
}

fn setInfo(c: *Command, info: *const CmdInfo) void {
    const old: ?*StrCmd = if (c.proc == &objToStr) @ptrCast(@alignCast(c.cd.?)) else null;
    if (info.obj_proc == null or info.obj_proc == &objToStr) {
        // A string function: the object function of the command gives
        // it the words as C strings.
        const sc = old orelse gpa.create(StrCmd) catch panicText("out of memory");
        sc.* = .{ .proc = info.proc, .cd = info.client_data, .delete = info.delete_proc, .delete_data = info.delete_data };
        c.proc = &objToStr;
        c.cd = sc;
        c.delete = &strDelete;
        c.delete_data = sc;
        return;
    }
    if (old) |sc| gpa.destroy(sc);
    c.proc = info.obj_proc;
    c.cd = info.obj_client_data;
    c.delete = info.delete_proc;
    c.delete_data = info.delete_data;
}

pub fn Tcl_SetCommandInfo(ip: *Interp, name: [*:0]const u8, info: *const CmdInfo) callconv(.c) c_int {
    switch (find(ip, name) orelse return 0) {
        .c => |c| setInfo(c, info),
        // A command of ztcl becomes a command of C with the same name.
        .ztcl => setInfo(host.createCommand(ip, name, null, null, null, null), info),
    }
    return 1;
}

pub fn Tcl_SetCommandInfoFromToken(c: ?*Command, info: *const CmdInfo) callconv(.c) c_int {
    const cmd = c orelse return 0;
    if (!cmd.live) return 0;
    setInfo(cmd, info);
    return 1;
}

/// Slot 96 of the internal table: `rename old new`. An empty new name
/// deletes the command.
pub fn TclRenameCommand(ip: *Interp, old: [*:0]const u8, new: [*:0]const u8) callconv(.c) c_int {
    var words = [_]*Obj{ obj.Tcl_NewStringObj("rename", 6), obj.Tcl_NewStringObj(old, -1), obj.Tcl_NewStringObj(new, -1) };
    for (words) |o| obj.incr(o);
    defer for (words) |o| obj.decr(o);
    return host.Tcl_EvalObjv(ip, 3, &words, 0);
}

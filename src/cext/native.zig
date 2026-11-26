//! The functions of `host.host` in the native path. A C package calls
//! them through the shared slots of `host.zig`, and they call the
//! interpreter through `zside.zig`, the same functions that the exports
//! of ztcl.wasm call. The handle of an interp is its place in a list of
//! shadows, plus 1. A command of a package is a command of ztcl that
//! fills the arguments of `host.ztcl_cext_args` and calls
//! `host.ztcl_cext_dispatch` with the id of the command.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const cext = @import("cext.zig");
const host = @import("host.zig");
const zside = @import("zside.zig");
const interp_mod = @import("../interp.zig");
const Interp = interp_mod.Interp;
const Value = @import("../value.zig").Value;
const Error = interp_mod.Error;
const Arg = host.Arg;

var shadows: std.ArrayList(?*cext.Shadow) = .empty;
var lock: std.atomic.Mutex = .unlocked;

fn grab() void {
    while (!lock.tryLock()) {}
}

/// Gives `sh` a handle and sets the functions of `host.host`.
pub fn register(sh: *cext.Shadow) Error!u32 {
    host.host = .{
        .cmd_create = &cmdCreate,
        .cmd_delete = &cmdDelete,
        .eval = &eval,
        .var_get = &varGet,
        .var_set = &varSet,
        .pkg_provide = &pkgProvide,
        .cancel = &cancel,
        .canceled = &canceled,
    };
    grab();
    defer lock.unlock();
    for (shadows.items, 0..) |*s, i| {
        if (s.* == null) {
            s.* = sh;
            return @intCast(i + 1);
        }
    }
    try shadows.append(cext.gpa, sh);
    return @intCast(shadows.items.len);
}

pub fn unregister(handle: u32) void {
    grab();
    defer lock.unlock();
    if (handle != 0 and handle <= shadows.items.len) shadows.items[handle - 1] = null;
}

fn interpOf(handle: u32) *Interp {
    grab();
    defer lock.unlock();
    return shadows.items[handle - 1].?.it;
}

/// A command of a package. Its data is the id of the command, plus 1.
fn cmdC(it: *Interp, argv: []const Value, _: ?*interp_mod.Cmd) Error!Value {
    const self = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name", .{});
    const id: u32 = @intCast(@intFromPtr(self.ctx.?) - 1);
    const sh = try cext.shadowOf(it);
    const args = host.ztcl_cext_args(argv.len);
    for (argv, args[0..argv.len]) |v, *a| a.* = try zside.argOf(it, v);
    const code = try cext.callC(sh, i32, host.ztcl_cext_dispatch, .{ id, argv.len });
    return zside.resultOf(it, code, try zside.valueOf(it, host.reply));
}

fn cmdCreate(handle: u32, id: u32, name: [*]const u8, len: usize) callconv(.c) i32 {
    zside.command(interpOf(handle), name[0..len], cmdC, @ptrFromInt(@as(usize, id) + 1)) catch return 1;
    return 0;
}

fn cmdDelete(handle: u32, name: [*]const u8, len: usize) callconv(.c) i32 {
    return zside.delete(interpOf(handle), name[0..len], &host.reply);
}

fn eval(handle: u32, script: [*]const u8, len: usize, flags: c_int) callconv(.c) i32 {
    return zside.eval(interpOf(handle), script[0..len], flags, &host.reply);
}

fn varGet(handle: u32, name: [*]const u8, len: usize, _: c_int) callconv(.c) i32 {
    return zside.varGet(interpOf(handle), name[0..len], &host.reply);
}

fn varSet(handle: u32, name: [*]const u8, len: usize, v: *const Arg, _: c_int) callconv(.c) i32 {
    return zside.varSet(interpOf(handle), name[0..len], v, &host.reply);
}

fn pkgProvide(handle: u32, name: [*]const u8, len: usize, version: [*]const u8, vlen: usize) callconv(.c) i32 {
    return zside.provide(interpOf(handle), name[0..len], version[0..vlen], &host.reply);
}

fn cancel(handle: u32, unwind: c_int, text: [*]const u8, len: usize) callconv(.c) i32 {
    interpOf(handle).cancelEval(unwind != 0, if (len == 0) null else text[0..len]) catch return 1;
    return 0;
}

/// The message of the cancel goes to `host.reply`, and its error code
/// to `zside.pending_code`.
fn canceled(handle: u32, unwind_only: c_int) callconv(.c) i32 {
    const it = interpOf(handle);
    const state = it.takeCanceled(unwind_only != 0) catch return 0;
    if (state != 0) {
        zside.pending_code = it.error_code;
        host.reply = zside.argOf(it, it.result) catch host.reply;
    }
    return state;
}

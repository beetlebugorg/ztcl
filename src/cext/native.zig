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
    setChannelHooks();
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

// ---- Channels ----
//
// A channel of a package that `Tcl_RegisterChannel` gives to an interp
// is a channel of ztcl with `ext` set. The channel commands of a script
// on it call `extOp`, which runs the generic layer of `chan.zig` of the
// package. The text of C is in modified UTF-8.

const chan_ok = @import("../sys.zig").supported;
const zchan = if (chan_ok) @import("../chan.zig") else struct {};
const cchan = @import("chan.zig");
const obj = @import("obj.zig");

const TCL_READABLE: c_int = 1 << 1;
const TCL_WRITABLE: c_int = 1 << 2;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The hooks of `chan.zig` and the commands of `../chan.zig`.
fn setChannelHooks() void {
    if (comptime !chan_ok) return;
    cchan.hooks = .{ .register = &hookRegister, .unregister = &hookUnregister, .stack = &hookStack, .unstack = &hookUnstack, .adopt = &hookAdopt };
    zchan.ext_op = &extOp;
}

fn extChannel(it: *Interp, name: []const u8, st: *cchan.State) Error!void {
    const c = try it.alloc().create(zchan.Channel);
    c.* = .{ .name = name, .fd = -1, .readable = st.mask & TCL_READABLE != 0, .writable = st.mask & TCL_WRITABLE != 0, .ext = st };
    try zchan.install(it, c);
}

fn hookRegister(handle: u32, name: []const u8, st: *cchan.State) void {
    const it = interpOf(handle);
    extChannel(it, zside.fromModified(it, name, true) catch return, st) catch {};
}

fn hookUnregister(handle: u32, name: []const u8) void {
    const it = interpOf(handle);
    _ = zchan.release(it, zside.fromModified(it, name, true) catch return);
}

/// The channel of ztcl goes to the name "\x00cext:" and the name, which
/// no script can give.
fn hookStack(handle: u32, name: []const u8, st: *cchan.State) ?[]const u8 {
    const it = interpOf(handle);
    const n = zside.fromModified(it, name, true) catch return null;
    const c = zchan.release(it, n) orelse return null;
    const hidden = std.fmt.allocPrint(it.alloc(), "\x00cext:{s}", .{n}) catch return null;
    c.name = hidden;
    zchan.install(it, c) catch return null;
    extChannel(it, n, st) catch return null;
    return zside.toModified(it, hidden) catch null;
}

fn hookUnstack(handle: u32, name: []const u8, hidden: []const u8) void {
    const it = interpOf(handle);
    const n = zside.fromModified(it, name, true) catch return;
    _ = zchan.release(it, n);
    const c = zchan.release(it, zside.fromModified(it, hidden, true) catch return) orelse return;
    c.name = n;
    zchan.install(it, c) catch {};
}

fn hookAdopt(handle: u32, fd: c_int, mask: c_int, sock: bool) ?[]const u8 {
    const it = interpOf(handle);
    const c = zchan.adopt(it, if (sock) "sock" else "file", fd, mask & TCL_READABLE != 0, mask & TCL_WRITABLE != 0) catch return null;
    if (sock) c.kind = .socket;
    return c.name;
}

/// The text of the result of the interp of the package, for ztcl.
fn cResult(it: *Interp, ip: *obj.Interp) Error![]const u8 {
    return zside.fromModified(it, obj.text(obj.result(ip)), true);
}

fn posixFail(it: *Interp, comptime what: []const u8, name: []const u8) Error {
    const msg = std.mem.span(cchan.Tcl_ErrnoMsg(cchan.Tcl_GetErrno()));
    return it.fail(what ++ " \"{s}\": {s}", .{ name, msg });
}

/// The text of a C object for ztcl. It drops the reference of `o`.
fn objText(it: *Interp, o: *obj.Obj) Error![]const u8 {
    defer obj.decr(o);
    return zside.fromModified(it, obj.text(o), true);
}

fn extOp(it: *Interp, zc: *zchan.Channel, op: []const u8, args: []const Value) Error!Value {
    const st: *cchan.State = @ptrCast(@alignCast(zc.ext.?));
    const sh = try cext.shadowOf(it);
    const ip = &sh.core;
    const ch = st.top;
    const name = zc.name;
    const rd = st.mask & TCL_READABLE != 0;
    const wr = st.mask & TCL_WRITABLE != 0;
    if (eql(op, "puts") or eql(op, "putsnl")) {
        if (!wr) return it.fail("channel \"{s}\" wasn't opened for writing", .{name});
        var t = try zside.toModified(it, try it.str(args[0]));
        if (eql(op, "putsnl")) t = try std.mem.concat(it.alloc(), u8, &.{ t, "\n" });
        if (try cext.callC(sh, c_int, cchan.Tcl_WriteChars, .{ ch, t.ptr, @as(c_int, @intCast(t.len)) }) < 0) return posixFail(it, "error writing", name);
        return Value.empty;
    }
    if (eql(op, "read") or eql(op, "read-nonewline")) {
        if (!rd) return it.fail("channel \"{s}\" wasn't opened for reading", .{name});
        var n: c_int = -1;
        if (args.len == 1) {
            const k = it.int(args[0]) catch return it.fail("expected non-negative integer but got \"{s}\"", .{try it.str(args[0])});
            if (k < 0) return it.fail("expected non-negative integer but got \"{s}\"", .{try it.str(args[0])});
            n = @intCast(@min(k, std.math.maxInt(c_int)));
        }
        const o = obj.Tcl_NewObj();
        obj.incr(o);
        if (try cext.callC(sh, c_int, cchan.Tcl_ReadChars, .{ ch, o, n, @as(c_int, 0) }) < 0) {
            obj.decr(o);
            return posixFail(it, "error reading", name);
        }
        var t = try objText(it, o);
        if (eql(op, "read-nonewline") and t.len > 0 and t[t.len - 1] == '\n') t = t[0 .. t.len - 1];
        return .{ .str = t };
    }
    if (eql(op, "gets")) {
        if (!rd) return it.fail("channel \"{s}\" wasn't opened for reading", .{name});
        const o = obj.Tcl_NewObj();
        obj.incr(o);
        const n = try cext.callC(sh, c_int, cchan.Tcl_GetsObj, .{ ch, o });
        const line = try objText(it, o);
        if (n < 0 and cchan.Tcl_Eof(ch) == 0 and cchan.Tcl_InputBlocked(ch) == 0) return posixFail(it, "error reading", name);
        if (args.len == 1) {
            try it.setVar(try it.str(args[0]), .{ .str = line });
            return .{ .int = n };
        }
        return .{ .str = line };
    }
    if (eql(op, "flush")) {
        if (!wr) return it.fail("channel \"{s}\" wasn't opened for writing", .{name});
        if (try cext.callC(sh, c_int, cchan.Tcl_Flush, .{ch}) != obj.OK) return posixFail(it, "error flushing", name);
        return Value.empty;
    }
    if (eql(op, "eof")) return .{ .int = cchan.Tcl_Eof(ch) };
    if (eql(op, "fblocked")) {
        if (!rd) return it.fail("channel \"{s}\" wasn't opened for reading", .{name});
        return .{ .int = cchan.Tcl_InputBlocked(ch) };
    }
    if (eql(op, "tell")) return .{ .int = try cext.callC(sh, i64, cchan.Tcl_Tell, .{ch}) };
    if (eql(op, "seek")) {
        const off = try it.int(args[0]);
        var whence: c_int = 0;
        if (args.len == 2) {
            const w = try it.str(args[1]);
            whence = if (eql(w, "start")) 0 else if (eql(w, "current")) 1 else if (eql(w, "end")) 2 else return it.failCode("TCL LOOKUP INDEX origin", "bad origin \"{s}\": must be start, current, or end", .{w});
        }
        if (try cext.callC(sh, i64, cchan.Tcl_Seek, .{ ch, off, whence }) < 0) return posixFail(it, "error during seek on", name);
        return Value.empty;
    }
    if (eql(op, "pending")) {
        const mode = try it.str(args[0]);
        if (eql(mode, "input")) return .{ .int = if (rd) cchan.Tcl_InputBuffered(ch) else -1 };
        if (eql(mode, "output")) return .{ .int = if (wr) cchan.Tcl_OutputBuffered(ch) else -1 };
        return it.failCode("TCL LOOKUP INDEX mode", "bad mode \"{s}\": must be input or output", .{mode});
    }
    if (eql(op, "fconfigure")) {
        if (args.len <= 1) {
            var ds: obj.DString = undefined;
            obj.Tcl_DStringInit(&ds);
            defer obj.Tcl_DStringFree(&ds);
            const opt: ?[*:0]const u8 = if (args.len == 1) (try it.alloc().dupeSentinel(u8, try zside.toModified(it, try it.str(args[0])), 0)).ptr else null;
            if (try cext.callC(sh, c_int, cchan.Tcl_GetChannelOption, .{ ip, ch, opt, &ds }) != obj.OK) return it.fail("{s}", .{try cResult(it, ip)});
            return .{ .str = try zside.fromModified(it, ds.string[0..@intCast(ds.length)], true) };
        }
        if (args.len % 2 != 0) return it.fail("wrong # args: should be \"fconfigure channelId ?-option value ...?\"", .{});
        var i: usize = 0;
        while (i < args.len) : (i += 2) {
            const o = try it.alloc().dupeSentinel(u8, try zside.toModified(it, try it.str(args[i])), 0);
            const v = try it.alloc().dupeSentinel(u8, try zside.toModified(it, try it.str(args[i + 1])), 0);
            if (try cext.callC(sh, c_int, cchan.Tcl_SetChannelOption, .{ ip, ch, o.ptr, v.ptr }) != obj.OK) return it.fail("{s}", .{try cResult(it, ip)});
        }
        return Value.empty;
    }
    if (eql(op, "close")) {
        if (args.len == 1) {
            const dir = try it.str(args[0]);
            const flags: c_int = if (dir.len > 0 and std.mem.startsWith(u8, "read", dir)) TCL_READABLE else if (dir.len > 0 and std.mem.startsWith(u8, "write", dir)) TCL_WRITABLE else return it.failCode("TCL LOOKUP INDEX direction", "bad direction \"{s}\": must be read or write", .{dir});
            if (try cext.callC(sh, c_int, cchan.Tcl_CloseEx, .{ ip, ch, flags }) != obj.OK) return it.fail("{s}", .{try cResult(it, ip)});
            return Value.empty;
        }
        const rc = if (cchan.Tcl_IsChannelRegistered(ip, ch) == 1)
            try cext.callC(sh, c_int, cchan.Tcl_UnregisterChannel, .{ ip, ch })
        else blk: {
            _ = zchan.release(it, name);
            break :blk try cext.callC(sh, c_int, cchan.Tcl_Close, .{ ip, ch });
        };
        if (rc != obj.OK) {
            const r = try cResult(it, ip);
            if (r.len > 0) return it.fail("{s}", .{r});
            return posixFail(it, "error closing", name);
        }
        return Value.empty;
    }
    return it.fail("{s} does not support a channel of a C package", .{op});
}

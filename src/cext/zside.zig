//! The side of ztcl of the calls of `host.zig`: the functions that run a
//! script, read and write a variable, and make and delete a command for
//! a C package. The native path (`native.zig`) calls them directly, and
//! the WebAssembly path (`src/wasm_cext.zig`) calls them from the
//! exports of ztcl.wasm. Each one gives the code of Tcl and puts the
//! value or the message in an `Arg`. Text in an `Arg` is in the memory
//! of the interpreter until the next call.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const value = @import("../value.zig");
const interp_mod = @import("../interp.zig");
const Interp = interp_mod.Interp;
const Value = value.Value;
const Error = interp_mod.Error;
pub const Arg = @import("host.zig").Arg;

pub const TCL_EVAL_GLOBAL: c_int = 0x20000;

pub fn argOf(it: *Interp, v: Value) Error!Arg {
    return switch (v) {
        .int => |i| .{ .kind = 1, .len = 0, .bits = @bitCast(i) },
        .double => |d| .{ .kind = 2, .len = 0, .bits = @bitCast(d) },
        else => blk: {
            const s = try it.str(v);
            break :blk .{ .kind = 0, .len = @intCast(s.len), .bits = @intFromPtr(s.ptr) };
        },
    };
}

/// The value of an `Arg`. Text is copied into the interp.
pub fn valueOf(it: *Interp, a: Arg) Error!Value {
    return switch (a.kind) {
        1 => .{ .int = @bitCast(a.bits) },
        2 => .{ .double = @bitCast(a.bits) },
        else => blk: {
            // A copy of 0 bytes has no valid address for the host.
            if (a.len == 0) break :blk Value.empty;
            const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(a.bits)));
            break :blk .{ .str = try it.alloc().dupe(u8, p[0..a.len]) };
        },
    };
}

/// The error code of the command of a package that runs, when a slot
/// such as `Tcl_Canceled` gives one. `resultOf` takes it.
pub threadlocal var pending_code: ?Value = null;

/// The value of a command of a package with code `code` and result `r`,
/// or the error of ztcl for the code.
pub fn resultOf(it: *Interp, code: i32, r: Value) Error!Value {
    const pc = pending_code;
    pending_code = null;
    return switch (code) {
        0 => r,
        2 => blk: {
            it.result = r;
            break :blk error.TclReturn;
        },
        3 => error.TclBreak,
        4 => error.TclContinue,
        else => blk: {
            it.result = r;
            it.error_code = pc orelse .{ .str = "NONE" };
            break :blk error.TclError;
        },
    };
}

/// Sets `out` to `v`.
fn put(it: *Interp, v: Value, out: *Arg) void {
    out.* = argOf(it, v) catch .{ .kind = 0, .len = 13, .bits = @intFromPtr("out of memory".ptr) };
}

/// The code of Tcl of `e`, with the result of the interp in `out`.
pub fn codeOf(it: *Interp, e: Error, out: *Arg) i32 {
    return switch (e) {
        error.TclReturn => blk: {
            put(it, it.result, out);
            break :blk 2;
        },
        error.TclBreak => 3,
        error.TclContinue => 4,
        error.TclError => blk: {
            put(it, it.result, out);
            break :blk 1;
        },
        else => blk: {
            const n = @errorName(e);
            out.* = .{ .kind = 0, .len = @intCast(n.len), .bits = @intFromPtr(n.ptr) };
            break :blk 1;
        },
    };
}

/// Makes command `name` with the function `f` and the data `ctx`.
pub fn command(it: *Interp, name: []const u8, f: interp_mod.NativeFn, ctx: ?*anyopaque) Error!void {
    const a = it.alloc();
    const n = try a.dupe(u8, name);
    const c = try a.create(interp_mod.Command);
    c.* = .{ .name = n, .impl = .{ .native = f }, .ctx = ctx };
    try it.commands.put(a, n, c);
    it.epoch += 1;
}

/// Runs a script in the current frame, or at the global level with
/// TCL_EVAL_GLOBAL. The compiled script of the same text comes from the
/// text cache of the interp.
pub fn eval(it: *Interp, text: []const u8, flags: c_int, out: *Arg) i32 {
    const run = struct {
        fn f(i: *Interp, t0: []const u8, global: bool) Error!Value {
            // The text is in the memory of the package, and the next call
            // can write over it. The text cache keeps a copy, but a script
            // longer than the cache compiles in place, and its procs keep
            // slices of the text. So a long script gets its own copy.
            const t = if (t0.len > interp_mod.text_cache_max) try i.alloc().dupe(u8, t0) else t0;
            if (global) {
                var buf: std.ArrayList(u8) = .empty;
                try buf.appendSlice(i.alloc(), "uplevel #0 ");
                try value.appendElement(i.alloc(), &buf, t, false);
                return i.evalScript(try i.scriptOfText(buf.items));
            }
            return i.evalScript(try i.scriptOfText(t));
        }
    }.f;
    if (run(it, text, flags & TCL_EVAL_GLOBAL != 0)) |v| {
        put(it, v, out);
        return 0;
    } else |e| return codeOf(it, e, out);
}

/// Reads a variable of the current frame.
pub fn varGet(it: *Interp, name: []const u8, out: *Arg) i32 {
    if (it.getVar(name)) |v| {
        put(it, v, out);
        return 0;
    } else |e| return codeOf(it, e, out);
}

/// Sets a variable of the current frame to the value of `a`.
pub fn varSet(it: *Interp, name: []const u8, a: *const Arg, out: *Arg) i32 {
    const v = valueOf(it, a.*) catch |e| return codeOf(it, e, out);
    it.setVar(name, v) catch |e| return codeOf(it, e, out);
    return 0;
}

/// Deletes command `name`.
pub fn delete(it: *Interp, name: []const u8, out: *Arg) i32 {
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(it.alloc(), "rename ") catch |e| return codeOf(it, e, out);
    value.appendElement(it.alloc(), &buf, name, false) catch |e| return codeOf(it, e, out);
    buf.appendSlice(it.alloc(), " {}") catch |e| return codeOf(it, e, out);
    _ = it.eval(buf.items) catch |e| return codeOf(it, e, out);
    return 0;
}

/// Provides package `name` at `version`.
pub fn provide(it: *Interp, name: []const u8, version: []const u8, out: *Arg) i32 {
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(it.alloc(), "package provide ") catch |e| return codeOf(it, e, out);
    value.appendElement(it.alloc(), &buf, name, false) catch |e| return codeOf(it, e, out);
    buf.append(it.alloc(), ' ') catch |e| return codeOf(it, e, out);
    value.appendElement(it.alloc(), &buf, version, false) catch |e| return codeOf(it, e, out);
    _ = it.eval(buf.items) catch |e| return codeOf(it, e, out);
    return 0;
}

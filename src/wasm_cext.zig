//! The side of ztcl of the bridge of C packages in WebAssembly
//! (docs/dev/cext-tasks/04w-wasm-bridge.md), in the wasm libraries
//! with `-Dcext-wasm` only.
//!
//! A package is its own module with the stubs table of
//! `src/cext/wasm_stubs.zig`. The JavaScript glue (`web/ztcl.mjs`,
//! `Interp.loadPackage`) links the two modules. A command of the package
//! is a native command of ztcl. Its call goes out through the import
//! `ztcl_cext.call` with the arguments as `Arg` records, and the glue
//! calls `ztcl_cext_dispatch` of the package. The exports of this file
//! are the other direction: the package makes commands, runs scripts,
//! and reads and writes variables. An int and a double cross as 64 bits
//! with no text form. Text crosses through the exchange buffer of the
//! side that receives it.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl.zig");
const wasm = @import("wasm.zig");
const value = ztcl.value;
const Handle = wasm.Handle;
const Value = ztcl.Value;
const gpa = wasm.gpa;

/// A value that crosses the boundary. `kind` is 0 for text, 1 for an
/// int, and 2 for a double. The layout is the `Arg` of the package.
pub const Arg = extern struct {
    kind: u32,
    len: u32,
    bits: u64,
};

const glue = struct {
    /// Runs command `id` of package `pkg`. `precision` is the value of
    /// `tcl_precision`, for the text of the doubles of the package. Gives
    /// the code of Tcl, and the result in `reply`.
    extern "ztcl_cext" fn call(pkg: u32, id: u32, argc: usize, argv: [*]const Arg, precision: u32) i32;
};

/// The reply of a call to the package or of an export of this file.
var reply: Arg = .{ .kind = 0, .len = 0, .bits = 0 };
var xbuf: std.ArrayList(u8) = .empty;

fn ztcl_cext_reply() callconv(.c) *Arg {
    return &reply;
}

fn ztcl_cext_buf(len: usize) callconv(.c) ?[*]u8 {
    xbuf.ensureTotalCapacity(gpa, @max(len, 1)) catch return null;
    return xbuf.items.ptr;
}

const Target = struct { pkg: u32, id: u32 };

fn argOf(it: *ztcl.Interp, v: Value) !Arg {
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
fn valueOf(it: *ztcl.Interp, a: Arg) !Value {
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

fn cextCmd(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.interp.Error!Value {
    const self = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name", .{});
    const t: *const Target = @ptrCast(@alignCast(self.ctx.?));
    const args = try it.alloc().alloc(Arg, argv.len);
    for (argv, args) |v, *a| a.* = try argOf(it, v);
    const code = glue.call(t.pkg, t.id, argv.len, args.ptr, it.precision);
    const r = try valueOf(it, reply);
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
            it.error_code = .{ .str = "NONE" };
            break :blk error.TclError;
        },
    };
}

/// Makes command `name` that runs command `id` of package `pkg`.
fn ztcl_cext_command(h: *Handle, pkg: u32, id: u32, ptr: [*]const u8, len: usize) callconv(.c) i32 {
    const it = &h.it;
    const a = it.alloc();
    const name = a.dupe(u8, ptr[0..len]) catch return 1;
    const t = a.create(Target) catch return 1;
    t.* = .{ .pkg = pkg, .id = id };
    const c = a.create(ztcl.interp.Command) catch return 1;
    c.* = .{ .name = name, .impl = .{ .native = cextCmd }, .ctx = t };
    it.commands.put(a, name, c) catch return 1;
    it.epoch += 1;
    return 0;
}

/// Sets `reply` to `v`, or to the result of the interp.
fn setReply(it: *ztcl.Interp, v: Value) void {
    reply = argOf(it, v) catch .{ .kind = 0, .len = 13, .bits = @intFromPtr("out of memory".ptr) };
}

fn codeOf(it: *ztcl.Interp, e: ztcl.interp.Error) i32 {
    return switch (e) {
        error.TclReturn => blk: {
            setReply(it, it.result);
            break :blk 2;
        },
        error.TclBreak => 3,
        error.TclContinue => 4,
        error.TclError => blk: {
            setReply(it, it.result);
            break :blk 1;
        },
        else => blk: {
            const n = @errorName(e);
            reply = .{ .kind = 0, .len = @intCast(n.len), .bits = @intFromPtr(n.ptr) };
            break :blk 1;
        },
    };
}

const TCL_EVAL_GLOBAL: c_int = 0x20000;

/// Runs a script in the current frame, or at the global level with
/// TCL_EVAL_GLOBAL. The compiled script of the same text comes from the
/// text cache of the interp. Gives the code of Tcl, and the result in
/// `reply`.
fn ztcl_cext_eval(h: *Handle, ptr: [*]const u8, len: usize, flags: c_int) callconv(.c) i32 {
    const it = &h.it;
    const text = ptr[0..len];
    const run = struct {
        fn f(i: *ztcl.Interp, t0: []const u8, global: bool) ztcl.interp.Error!Value {
            // The text is in the exchange buffer, and the next call writes
            // over it. The text cache keeps a copy, but a script longer
            // than the cache compiles in place, and its procs keep slices
            // of the text. So a long script gets its own copy.
            const t = if (t0.len > ztcl.interp.text_cache_max) try i.alloc().dupe(u8, t0) else t0;
            if (global) {
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(i.alloc(), "uplevel #0 ");
                try value.appendElement(i.alloc(), &out, t, false);
                return i.evalScript(try i.scriptOfText(out.items));
            }
            return i.evalScript(try i.scriptOfText(t));
        }
    }.f;
    if (run(it, text, flags & TCL_EVAL_GLOBAL != 0)) |v| {
        setReply(it, v);
        return 0;
    } else |e| return codeOf(it, e);
}

/// Reads a variable of the current frame. Gives 0 with the value in
/// `reply`, or 1 with the error in `reply`.
fn ztcl_cext_var_get(h: *Handle, ptr: [*]const u8, len: usize, _: c_int) callconv(.c) i32 {
    const it = &h.it;
    if (it.getVar(ptr[0..len])) |v| {
        setReply(it, v);
        return 0;
    } else |e| return codeOf(it, e);
}

/// Sets a variable of the current frame to the value of `a`. Text is in
/// the exchange buffer.
fn ztcl_cext_var_set(h: *Handle, ptr: [*]const u8, len: usize, a: *const Arg, _: c_int) callconv(.c) i32 {
    const it = &h.it;
    const name = ptr[0..len];
    const v = valueOf(it, a.*) catch return codeOf(it, error.OutOfMemory);
    it.setVar(name, v) catch |e| return codeOf(it, e);
    return 0;
}

/// Deletes command `name`.
fn ztcl_cext_delete(h: *Handle, ptr: [*]const u8, len: usize) callconv(.c) i32 {
    const it = &h.it;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(it.alloc(), "rename ") catch return 1;
    value.appendElement(it.alloc(), &out, ptr[0..len], false) catch return 1;
    out.appendSlice(it.alloc(), " {}") catch return 1;
    _ = it.eval(out.items) catch |e| return codeOf(it, e);
    return 0;
}

comptime {
    @export(&ztcl_cext_reply, .{ .name = "ztcl_cext_reply" });
    @export(&ztcl_cext_buf, .{ .name = "ztcl_cext_buf" });
    @export(&ztcl_cext_command, .{ .name = "ztcl_cext_command" });
    @export(&ztcl_cext_eval, .{ .name = "ztcl_cext_eval" });
    @export(&ztcl_cext_var_get, .{ .name = "ztcl_cext_var_get" });
    @export(&ztcl_cext_var_set, .{ .name = "ztcl_cext_var_set" });
    @export(&ztcl_cext_delete, .{ .name = "ztcl_cext_delete" });
}

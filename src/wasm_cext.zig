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
//! side that receives it. The work of each export is in
//! `src/cext/zside.zig`, which the native path uses too.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl.zig");
const wasm = @import("wasm.zig");
const Handle = wasm.Handle;
const Value = ztcl.Value;
const gpa = wasm.gpa;

const zside = @import("cext/zside.zig");
const Arg = zside.Arg;

const glue = struct {
    /// Runs command `id` of package `pkg`. `precision` is the value of
    /// `tcl_precision`, for the text of the doubles of the package. Gives
    /// the code of Tcl, and the result in `reply`.
    extern "ztcl_cext" fn call(pkg: u32, id: u32, argc: usize, argv: [*]const Arg, precision: u32) i32;
    /// The child interp of `handle` goes.
    extern "ztcl_cext" fn interp_gone(handle: u32) void;
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

fn cextCmd(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.interp.Error!Value {
    const self = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name", .{});
    const t: *const Target = @ptrCast(@alignCast(self.ctx.?));
    const args = try it.alloc().alloc(Arg, argv.len);
    for (argv, args) |v, *a| a.* = try zside.argOf(it, v);
    const code = glue.call(t.pkg, t.id, argv.len, args.ptr, it.precision);
    return zside.resultOf(it, code, try zside.valueOf(it, reply));
}

/// Makes command `name` that runs command `id` of package `pkg`.
fn ztcl_cext_command(h: u32, pkg: u32, id: u32, ptr: [*]const u8, len: usize) callconv(.c) i32 {
    const it = itOf(h) orelse return 1;
    const t = it.alloc().create(Target) catch return 1;
    t.* = .{ .pkg = pkg, .id = id };
    zside.command(it, ptr[0..len], cextCmd, t) catch return 1;
    return 0;
}

fn ztcl_cext_eval(h: u32, ptr: [*]const u8, len: usize, flags: c_int) callconv(.c) i32 {
    return zside.eval(itOf(h) orelse return 1, ptr[0..len], flags, &reply);
}

fn ztcl_cext_var_get(h: u32, ptr: [*]const u8, len: usize, _: c_int) callconv(.c) i32 {
    return zside.varGet(itOf(h) orelse return 1, ptr[0..len], &reply);
}

/// Text of `a` is in the exchange buffer.
fn ztcl_cext_var_set(h: u32, ptr: [*]const u8, len: usize, a: *const Arg, _: c_int) callconv(.c) i32 {
    return zside.varSet(itOf(h) orelse return 1, ptr[0..len], a, &reply);
}

/// The error state of ztcl after an error goes to the reply.
fn ztcl_cext_err_get(h: u32) callconv(.c) i32 {
    return zside.errGet(itOf(h) orelse return 1, &reply);
}

/// The error state of a command of a package, as a list `Arg`.
fn ztcl_cext_err_set(h: u32, a: *const Arg) callconv(.c) i32 {
    return zside.errSet(itOf(h) orelse return 1, a);
}

fn ztcl_cext_delete(h: u32, ptr: [*]const u8, len: usize) callconv(.c) i32 {
    return zside.delete(itOf(h) orelse return 1, ptr[0..len], &reply);
}

/// Provides package `name` at `version`. The name and the version are
/// next to each other in the exchange buffer.
fn ztcl_cext_provide(h: u32, ptr: [*]const u8, len: usize, vptr: [*]const u8, vlen: usize) callconv(.c) i32 {
    return zside.provide(itOf(h) orelse return 1, ptr[0..len], vptr[0..vlen], &reply);
}

/// The children of `interpOp`. A handle of a child is the address of its
/// interp, and a handle of a top interp is the address of its `Handle`.
const Kid = struct { it: *ztcl.Interp, parent: u32, name: []const u8 };
var kids: std.ArrayList(Kid) = .empty;

const Handles = struct {
    pub fn handleOf(it: *ztcl.Interp) ztcl.interp.Error!u32 {
        const p = it.parent orelse return @intCast(@intFromPtr(@as(*Handle, @fieldParentPtr("it", it))));
        for (kids.items) |k| {
            if (k.it == it) return @intCast(@intFromPtr(it));
        }
        var iter = p.children.iterator();
        const name = while (iter.next()) |e| {
            if (e.value_ptr.*.it == it) break e.key_ptr.*;
        } else return error.OutOfMemory;
        try kids.append(gpa, .{ .it = it, .parent = try handleOf(p), .name = try gpa.dupe(u8, name) });
        @import("cext/cext.zig").drop_hook = &dropKid;
        return @intCast(@intFromPtr(it));
    }

    /// The interp of `handle`. A child must still be in its parent.
    pub fn interpOf(handle: u32) ?*ztcl.Interp {
        for (kids.items, 0..) |k, i| {
            if (@intFromPtr(k.it) != handle) continue;
            const p = interpOf(k.parent) orelse return null;
            const c = p.children.get(k.name) orelse {
                gpa.free(k.name);
                _ = kids.swapRemove(i);
                return null;
            };
            return if (c.it == k.it) k.it else null;
        }
        if (handle == 0) return null;
        const h: *Handle = @ptrFromInt(handle);
        return &h.it;
    }
};

/// Tells the packages that a child with a handle goes.
fn dropKid(it: *ztcl.Interp) void {
    for (kids.items, 0..) |k, i| {
        if (k.it != it) continue;
        gpa.free(k.name);
        _ = kids.swapRemove(i);
        glue.interp_gone(@intCast(@intFromPtr(it)));
        return;
    }
}

fn itOf(h: u32) ?*ztcl.Interp {
    return Handles.interpOf(h);
}

/// Runs an operation of the interp tree with the list `a`.
fn ztcl_cext_interp_op(h: u32, op: u32, a: *const Arg) callconv(.c) i32 {
    const it = itOf(h) orelse return 1;
    return zside.interpOp(it, op, a, &reply, Handles);
}

comptime {
    @export(&ztcl_cext_interp_op, .{ .name = "ztcl_cext_interp_op" });
    @export(&ztcl_cext_provide, .{ .name = "ztcl_cext_provide" });
    @export(&ztcl_cext_reply, .{ .name = "ztcl_cext_reply" });
    @export(&ztcl_cext_buf, .{ .name = "ztcl_cext_buf" });
    @export(&ztcl_cext_command, .{ .name = "ztcl_cext_command" });
    @export(&ztcl_cext_eval, .{ .name = "ztcl_cext_eval" });
    @export(&ztcl_cext_var_get, .{ .name = "ztcl_cext_var_get" });
    @export(&ztcl_cext_var_set, .{ .name = "ztcl_cext_var_set" });
    @export(&ztcl_cext_delete, .{ .name = "ztcl_cext_delete" });
    @export(&ztcl_cext_err_get, .{ .name = "ztcl_cext_err_get" });
    @export(&ztcl_cext_err_set, .{ .name = "ztcl_cext_err_set" });
}

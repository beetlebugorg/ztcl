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

/// The `Arg` of `v`. A list keeps its elements: `len` is the count and
/// `bits` the address of an array of `Arg`s. Text goes out in the
/// modified UTF-8 of Tcl, where U+0000 is the two bytes C0 80.
pub fn argOf(it: *Interp, v: Value) Error!Arg {
    return switch (v) {
        .int => |i| .{ .kind = 1, .len = 0, .bits = @bitCast(i) },
        .double => |d| .{ .kind = 2, .len = 0, .bits = @bitCast(d) },
        .list => |l| blk: {
            const items = l.items();
            const out = try it.alloc().alloc(Arg, items.len);
            for (items, out) |e, *a| a.* = try argOf(it, e);
            break :blk .{ .kind = 3, .len = @intCast(items.len), .bits = @intFromPtr(out.ptr) };
        },
        else => blk: {
            const s = try toModified(it, try it.str(v));
            break :blk .{ .kind = 0, .len = @intCast(s.len), .bits = @intFromPtr(s.ptr) };
        },
    };
}

/// The value of an `Arg`. Text is copied into the interp.
pub fn valueOf(it: *Interp, a: Arg) Error!Value {
    return switch (a.kind) {
        1 => .{ .int = @bitCast(a.bits) },
        2 => .{ .double = @bitCast(a.bits) },
        3 => blk: {
            if (a.len == 0) break :blk value.newList(it.alloc(), &.{});
            const p: [*]const Arg = @ptrFromInt(@as(usize, @intCast(a.bits)));
            const vals = try it.alloc().alloc(Value, a.len);
            for (p[0..a.len], vals) |e, *v| v.* = try valueOf(it, e);
            break :blk value.newList(it.alloc(), vals);
        },
        else => blk: {
            // A copy of 0 bytes has no valid address for the host.
            if (a.len == 0) break :blk Value.empty;
            const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(a.bits)));
            break :blk .{ .str = try fromModified(it, p[0..a.len], true) };
        },
    };
}

/// `s` with each U+0000 as C0 80. Text with no U+0000 is not copied.
pub fn toModified(it: *Interp, s: []const u8) Error![]const u8 {
    const n = std.mem.count(u8, s, "\x00");
    if (n == 0) return s;
    const out = try it.alloc().alloc(u8, s.len + n);
    var j: usize = 0;
    for (s) |c| {
        if (c == 0) {
            out[j] = 0xC0;
            out[j + 1] = 0x80;
            j += 2;
        } else {
            out[j] = c;
            j += 1;
        }
    }
    return out;
}

/// `s` with each C0 80 as U+0000. With `copy`, the text is always a
/// copy in the interp; else only text with a C0 80 is copied.
pub fn fromModified(it: *Interp, s: []const u8, copy: bool) Error![]const u8 {
    if (std.mem.indexOf(u8, s, "\xc0\x80") == null) return if (copy) try it.alloc().dupe(u8, s) else s;
    const out = try it.alloc().alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        out[n] = s[i];
        if (s[i] == 0xC0 and i + 1 < s.len and s[i + 1] == 0x80) {
            out[n] = 0;
            i += 1;
        }
        n += 1;
    }
    return out[0..n];
}

/// The error code of the command of a package that runs, when a slot
/// such as `Tcl_Canceled` gives one. `resultOf` takes it.
pub threadlocal var pending_code: ?Value = null;

/// The error state that a command of a package gives with its error
/// or its return (`errSet`). `resultOf` takes it.
const ErrState = struct {
    info: ?[]const u8,
    line: u32,
    ret_code: i64,
    ret_level: i64,
};
threadlocal var pending_err: ?ErrState = null;

/// The value of a command of a package with code `code` and result `r`,
/// or the error of ztcl for the code.
pub fn resultOf(it: *Interp, code: i32, r: Value) Error!Value {
    const pc = pending_code;
    pending_code = null;
    const pe = pending_err;
    pending_err = null;
    return switch (code) {
        0 => r,
        2 => blk: {
            it.result = r;
            if (pe) |e| {
                it.ret_code = @fromBackingInt(@intCast(@as(u32, @intCast(std.math.clamp(e.ret_code, 0, std.math.maxInt(u32))))));
                it.ret_level = @intCast(std.math.clamp(e.ret_level, 0, std.math.maxInt(u32)));
                if (e.ret_code == 1) setInfo(it, pc, e) catch {};
            }
            break :blk error.TclReturn;
        },
        // Tcl keeps the result of a break or a continue.
        3 => blk: {
            it.result = r;
            break :blk error.TclBreak;
        },
        4 => blk: {
            it.result = r;
            break :blk error.TclContinue;
        },
        else => blk: {
            it.result = r;
            it.error_code = pc orelse .{ .str = "NONE" };
            if (pe) |e| try setInfo(it, pc, e);
            break :blk error.TclError;
        },
    };
}

/// The error info and the error line of a package. With no error info,
/// the error info of ztcl starts again from the result.
fn setInfo(it: *Interp, pc: ?Value, e: ErrState) Error!void {
    if (pc) |c| it.error_code = c;
    if (e.line != 0) it.error_line = e.line;
    it.error_info = .empty;
    it.in_error = false;
    if (e.info) |t| {
        try it.error_info.appendSlice(it.alloc(), t);
        it.in_error = true;
    }
}

/// The error state of ztcl after an error, for the package: the list
/// {errorCode errorInfo errorLine}.
pub fn errGet(it: *Interp, out: *Arg) i32 {
    const info: []const u8 = if (it.in_error) it.error_info.items else it.str(it.result) catch "";
    const items = [_]Value{ it.error_code, .{ .str = info }, .{ .int = it.error_line } };
    const l = value.newList(it.alloc(), &items) catch return codeOf(it, error.OutOfMemory, out);
    put(it, l, out);
    return 0;
}

/// Takes the error state of a command of a package: the list
/// {errorCode errorInfo hasInfo errorLine returnCode returnLevel}.
pub fn errSet(it: *Interp, a: *const Arg) i32 {
    const v = valueOf(it, a.*) catch return 1;
    const items = if (v == .list) v.list.items() else return 1;
    if (items.len != 6) return 1;
    const int = struct {
        fn f(x: *Interp, y: Value) i64 {
            return x.int(y) catch 0;
        }
    }.f;
    const empty = if (items[0] == .str) items[0].str.len == 0 else false;
    if (!empty) pending_code = items[0];
    pending_err = .{
        .info = if (int(it, items[2]) != 0) (it.str(items[1]) catch null) else null,
        .line = @intCast(std.math.clamp(int(it, items[3]), 0, std.math.maxInt(u32))),
        .ret_code = int(it, items[4]),
        .ret_level = int(it, items[5]),
    };
    return 0;
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
            // slices of the text. So a long script gets its own copy. A
            // U+0000 of the script comes as C0 80.
            const t1 = try fromModified(i, t0, false);
            const t = if (t1.ptr == t0.ptr and t0.len > interp_mod.text_cache_max) try i.alloc().dupe(u8, t0) else t1;
            // A call of a program of libztcl with no script of ztcl
            // running is a top-level eval: it sets the scan range of the
            // collector, and an error ends there and sets errorInfo.
            if (i.heap.scopes == 0) return i.evalTop(try i.scriptOfText(t));
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
    // A delete of the C API runs no execution trace.
    it.exec_quiet += 1;
    defer it.exec_quiet -= 1;
    _ = it.eval(buf.items) catch |e| return codeOf(it, e, out);
    return 0;
}

/// Provides package `name` at `version`.
pub fn provide(it: *Interp, name: []const u8, version: []const u8, out: *Arg) i32 {
    // An interp with no command `package` keeps no versions.
    if (it.findCommand("package") == null) return 0;
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(it.alloc(), "package provide ") catch |e| return codeOf(it, e, out);
    value.appendElement(it.alloc(), &buf, name, false) catch |e| return codeOf(it, e, out);
    buf.append(it.alloc(), ' ') catch |e| return codeOf(it, e, out);
    value.appendElement(it.alloc(), &buf, version, false) catch |e| return codeOf(it, e, out);
    _ = it.eval(buf.items) catch |e| return codeOf(it, e, out);
    return 0;
}

pub const InterpOp = @import("host.zig").InterpOp;

/// The commands that `Tcl_MakeSafe` hides, as the safe interps of Tcl 8.6
/// do.
const unsafe_commands = [_][]const u8{ "cd", "exec", "exit", "fconfigure", "file", "glob", "load", "open", "pwd", "socket", "source", "unload" };

/// Runs operation `op` of the interp tree for a C package. `H` maps an
/// interp to its handle (`handleOf`) and a handle to its interp
/// (`interpOf`). Gives the code of Tcl, and the value or the message in
/// `out`.
pub fn interpOp(it: *Interp, op: u32, a: *const Arg, out: *Arg, comptime H: type) i32 {
    const r = interpRun(it, op, a, H) catch |e| return codeOf(it, e, out);
    put(it, r, out);
    return 0;
}

fn handleValue(comptime H: type, x: ?*Interp) Error!Value {
    const p = x orelse return .{ .int = 0 };
    return .{ .int = try H.handleOf(p) };
}

fn interpRun(it: *Interp, op: u32, a: *const Arg, comptime H: type) Error!Value {
    const child = @import("../child.zig");
    const v = try valueOf(it, a.*);
    const args = if (v == .list) v.list.items() else &[_]Value{v};
    const need = struct {
        fn f(i: *Interp, xs: []const Value, n: usize) Error!void {
            if (xs.len < n) return i.fail("the operation needs {d} arguments", .{n});
        }
    }.f;
    switch (@as(InterpOp, @fromBackingInt(@intCast(op)))) {
        .child => {
            try need(it, args, 1);
            var cur = it;
            for (try it.list(args[0])) |w| {
                const c = cur.children.get(try it.str(w)) orelse return .{ .int = 0 };
                cur = c.it;
            }
            return handleValue(H, cur);
        },
        .parent => return handleValue(H, it.parent),
        .path => {
            try need(it, args, 1);
            const target = H.interpOf(@intCast(try it.int(args[0]))) orelse return it.fail("", .{});
            // The names from `it` down to `target`, last first.
            var names: std.ArrayList(Value) = .empty;
            var cur = target;
            while (cur != it) {
                const p = cur.parent orelse return it.fail("", .{});
                var iter = p.children.iterator();
                const name = while (iter.next()) |e| {
                    if (e.value_ptr.*.it == cur) break e.key_ptr.*;
                } else return it.fail("", .{});
                try names.append(it.alloc(), .{ .str = name });
                cur = p;
            }
            std.mem.reverse(Value, names.items);
            return value.newList(it.alloc(), names.items);
        },
        .is_safe => return .{ .int = @intFromBool(it.is_safe) },
        .make_safe => {
            it.is_safe = true;
            for (unsafe_commands) |n| {
                if (it.commands.get(n) != null) _ = try child.hideCmd(it, it, n, n);
            }
            return Value.empty;
        },
        .alias => {
            try need(it, args, 3);
            const target = H.interpOf(@intCast(try it.int(args[1]))) orelse return it.fail("target interpreter not found", .{});
            return child.makeAlias(it, it, try it.str(args[0]), target, args[2..]);
        },
        .get_alias => {
            try need(it, args, 1);
            const name = try it.str(args[0]);
            const al = try child.aliasOf(it, name) orelse return it.fail("alias \"{s}\" not found", .{name});
            const items = try it.alloc().alloc(Value, al.words.len + 1);
            items[0] = try handleValue(H, al.target);
            @memcpy(items[1..], al.words);
            return value.newList(it.alloc(), items);
        },
        .hide => {
            try need(it, args, 2);
            return child.hideCmd(it, it, try it.str(args[0]), try it.str(args[1]));
        },
        .expose => {
            try need(it, args, 2);
            return child.exposeCmd(it, it, try it.str(args[0]), try it.str(args[1]));
        },
        .recursion => {
            try need(it, args, 1);
            const old = it.max_depth;
            const n = try it.int(args[0]);
            if (n > 0) it.max_depth = @intCast(@min(n, 600));
            return .{ .int = old };
        },
        .active => return .{ .int = @intFromBool(it.active > 0 or it.depth > 0) },
        .exec_hook => {
            const trace = @import("../trace.zig");
            try need(it, args, 2);
            const name = try it.str(args[1]);
            if (std.mem.eql(u8, try it.str(args[0]), "remove")) return .{ .int = @intFromBool(trace.removeExecHook(it, name)) };
            try need(it, args, 4);
            const level = try it.int(args[2]);
            // The namespace of the hidden command, with no trace.
            it.exec_quiet += 1;
            defer it.exec_quiet -= 1;
            _ = try it.eval("namespace eval ::tcl::cext {}");
            try trace.addExecHook(it, name, @intCast(std.math.clamp(level, 0, std.math.maxInt(u32))), try it.int(args[3]) != 0);
            return Value.empty;
        },
        _ => return it.fail("unknown interp operation {d}", .{op}),
    }
}

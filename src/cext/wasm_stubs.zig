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
const bridge = @import("host.zig");

const gpa = std.heap.c_allocator;

// The names of host.zig that this file uses.
const Arg = bridge.Arg;
const Command = bridge.Command;
const Host = bridge.Host;
const TCL_LEAVE_ERR_MSG = bridge.TCL_LEAVE_ERR_MSG;
const Tcl_DeleteCommandFromToken = bridge.Tcl_DeleteCommandFromToken;
const Tcl_GetVar2Ex = bridge.Tcl_GetVar2Ex;
const Tcl_NRAddCallback = bridge.Tcl_NRAddCallback;
const Tcl_NRCreateCommand = bridge.Tcl_NRCreateCommand;
const Tcl_NREvalObj = bridge.Tcl_NREvalObj;
const Tcl_ObjSetVar2 = bridge.Tcl_ObjSetVar2;
const Tcl_PkgRequireEx = bridge.Tcl_PkgRequireEx;
const objOf = bridge.objOf;
const ztcl_cext_args = bridge.ztcl_cext_args;
const ztcl_cext_buf = bridge.ztcl_cext_buf;
const ztcl_cext_dispatch = bridge.ztcl_cext_dispatch;
const ztcl_cext_interp = bridge.ztcl_cext_interp;
const ztcl_cext_interp_free = bridge.ztcl_cext_interp_free;
const ztcl_cext_precision = bridge.ztcl_cext_precision;
const ztcl_cext_reply = bridge.ztcl_cext_reply;
const ztcl_cext_result = bridge.ztcl_cext_result;

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

comptime {
    if (builtin.target.cpu.arch == .wasm32) {
        @export(&ztcl_cext_buf, .{ .name = "ztcl_cext_buf" });
        @export(&ztcl_cext_args, .{ .name = "ztcl_cext_args" });
        @export(&ztcl_cext_reply, .{ .name = "ztcl_cext_reply" });
        @export(&ztcl_cext_dispatch, .{ .name = "ztcl_cext_dispatch" });
        @export(&ztcl_cext_interp, .{ .name = "ztcl_cext_interp" });
        @export(&ztcl_cext_interp_free, .{ .name = "ztcl_cext_interp_free" });
        @export(&ztcl_cext_result, .{ .name = "ztcl_cext_result" });
        @export(&ztcl_cext_precision, .{ .name = "ztcl_cext_precision" });
    }
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
    @import("host.zig").slots,
    @import("obj.zig").slots,
    @import("chan.zig").slots,
    @import("mem.zig").slots,
    @import("hash.zig").slots,
    @import("parse.zig").slots,
    @import("errors.zig").slots,
    @import("strings.zig").slots,
    @import("encoding.zig").slots,
    @import("regexp.zig").slots,
    @import("lists.zig").slots,
    @import("vars.zig").slots,
    @import("interps.zig").slots,
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
    // `package require Tcl` gives this table as its client data.
    ip.stub_table = &table;
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
        bridge.reply = .{ .kind = 0, .len = @intCast(s.len), .bits = @intFromPtr(keep.items.ptr) };
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
    const saved = bridge.host;
    bridge.host = Fake.h;
    defer bridge.host = saved;
    const ip = ztcl_cext_interp(1);
    defer ztcl_cext_interp_free(ip);
    const c = Tcl_NRCreateCommand(ip, "count", null, Count.cmd, null, null);
    const id: u32 = @intCast(std.mem.indexOfScalar(*Command, bridge.commands.items, c).?);
    const argv = ztcl_cext_args(2);
    argv[0] = .{ .kind = 0, .len = 5, .bits = @intFromPtr("count".ptr) };
    argv[1] = .{ .kind = 1, .len = 0, .bits = 3 };
    Fake.evals = 0;
    try testing.expectEqual(OK, ztcl_cext_dispatch(id, 2));
    try testing.expectEqual(1, bridge.reply.kind);
    try testing.expectEqual(3, bridge.reply.bits);
    try testing.expectEqual(3, Fake.evals);
    try testing.expectEqualStrings("3", Fake.vars.get("row").?);
    try testing.expect(bridge.frames.items.len == 0);
    argv[1] = .{ .kind = 0, .len = 1, .bits = @intFromPtr("x".ptr) };
    try testing.expectEqual(ERROR, ztcl_cext_dispatch(id, 2));
    try testing.expectEqualStrings("expected integer but got \"x\"", @as([*]const u8, @ptrFromInt(@as(usize, @intCast(bridge.reply.bits))))[0..bridge.reply.len]);
    // A variable that ztcl does not have gives null and the message.
    try testing.expect(Tcl_GetVar2Ex(ip, "nope", null, TCL_LEAVE_ERR_MSG) == null);
    try testing.expectEqualStrings("no such variable", std.mem.span(Tcl_GetStringResult(ip)));
    try testing.expectEqual(OK, Tcl_DeleteCommandFromToken(ip, c));
}

test "the free of an interp runs the delete procs and drops the package data" {
    const saved = bridge.host;
    bridge.host = Fake.h;
    defer bridge.host = saved;
    const D = struct {
        var runs: usize = 0;
        fn drop(_: ?*anyopaque, _: *Interp) callconv(.c) void {
            runs += 1;
        }
    };
    const hash = @import("hash.zig");
    const ip = ztcl_cext_interp(1);
    hash.Tcl_SetAssocData(ip, "a", D.drop, null);
    hash.Tcl_SetAssocData(ip, "b", D.drop, null);
    var marker: u8 = 0;
    try testing.expectEqual(OK, bridge.Tcl_PkgProvideEx(ip, "p", "1.0", &marker));
    try testing.expect(ip.pkgs != null);
    Tcl_SetObjResult(ip, Tcl_NewStringObj("x", 1));
    D.runs = 0;
    ztcl_cext_interp_free(ip);
    try testing.expectEqual(2, D.runs);
}

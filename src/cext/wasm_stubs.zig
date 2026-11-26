//! The stubs table of Tcl 8.6 for a C package that `zig cc -target
//! wasm32-wasi` builds (docs/dev/cext-tasks/04w-wasm-bridge.md).
//!
//! The library links into the package. `Tcl_InitStubs` points
//! `tclStubsPtr` at a table of 691 slots in the published order of
//! `tclDecls.h`. A slot with no implementation calls `Tcl_Panic` with its
//! number.
//!
//! The `Tcl_Obj` records are in the memory of the package, in the layout
//! of Tcl 8.6, because C code reads and writes `refCount`, `bytes`, and
//! `typePtr` directly. Each value has a reference count, an optional text
//! form, and an internal form of one type. A type has the four procs of
//! `Tcl_ObjType`, and the library calls them for its own types and for
//! the types of the package. The text form is made on demand: an int with
//! the digits, a double with the shortest digits that read back (the
//! `formatDouble` of ztcl), and a list with the quoting of the `list`
//! command. A record that is freed goes to a free list for the next
//! `Tcl_NewObj`.
//!
//! The interp result, the dynamic strings, `Tcl_GetIndexFromObjStruct`,
//! and the memory slots are in the package too, so these slots make no
//! call out of the module.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const value = @import("value");

const gpa = std.heap.c_allocator;

// ---- The objects ----

pub const FreeProc = *const fn (*Obj) callconv(.c) void;
pub const DupProc = *const fn (*Obj, *Obj) callconv(.c) void;
pub const UpdateProc = *const fn (*Obj) callconv(.c) void;
pub const SetProc = *const fn (?*Interp, *Obj) callconv(.c) c_int;

/// `Tcl_ObjType`.
pub const ObjType = extern struct {
    name: [*:0]const u8,
    free: ?FreeProc,
    dup: ?DupProc,
    update: ?UpdateProc,
    set_from_any: ?SetProc,
};

/// The internal form of `Tcl_Obj`: 8 bytes on wasm32 and 16 on x86-64.
pub const Rep = extern union {
    long: c_long,
    double: f64,
    wide: i64,
    two: extern struct { p1: ?*anyopaque, p2: ?*anyopaque },
};

/// `Tcl_Obj`.
pub const Obj = extern struct {
    refCount: c_int,
    bytes: ?[*]u8,
    length: c_int,
    typePtr: ?*const ObjType,
    rep: Rep,
};

/// The public part of `Tcl_Interp` in Tcl 8.6, then the fields of the
/// library.
pub const Interp = extern struct {
    result_dont_use: [*:0]const u8 = "",
    free_proc_dont_use: ?*anyopaque = null,
    error_line_dont_use: c_int = 0,
    result: ?*Obj = null,
    /// The id of the interp of ztcl.
    handle: u32 = 0,
};

pub const OK: c_int = 0;
pub const ERROR: c_int = 1;

/// The text of an empty string. It is never freed.
var empty_rep: [1:0]u8 = .{0};

var free_list: ?*Obj = null;

fn newObj() *Obj {
    const o: *Obj = if (free_list) |f| blk: {
        free_list = @ptrCast(@alignCast(f.rep.two.p1));
        break :blk f;
    } else gpa.create(Obj) catch panicText("out of memory");
    o.* = .{ .refCount = 0, .bytes = &empty_rep, .length = 0, .typePtr = null, .rep = .{ .wide = 0 } };
    return o;
}

fn freeIntRep(o: *Obj) void {
    if (o.typePtr) |t| if (t.free) |f| f(o);
    o.typePtr = null;
}

fn invalidate(o: *Obj) void {
    if (o.bytes) |b| if (b != @as([*]u8, &empty_rep)) std.c.free(b);
    o.bytes = null;
    o.length = 0;
}

/// Sets the text form to a copy of `s`.
fn setText(o: *Obj, s: []const u8) void {
    invalidate(o);
    if (s.len == 0) {
        o.bytes = &empty_rep;
        return;
    }
    const p: [*]u8 = @ptrCast(std.c.malloc(s.len + 1) orelse panicText("out of memory"));
    @memcpy(p[0..s.len], s);
    p[s.len] = 0;
    o.bytes = p;
    o.length = @intCast(s.len);
}

/// The text form, made on demand.
pub fn text(o: *Obj) []const u8 {
    if (o.bytes == null) {
        const t = o.typePtr orelse unreachable;
        (t.update orelse panicText("Tcl_GetString: a type with no text and no update proc"))(o);
    }
    return o.bytes.?[0..@intCast(o.length)];
}

fn tclFreeObj(o: *Obj) callconv(.c) void {
    freeIntRep(o);
    invalidate(o);
    o.rep.two.p1 = free_list;
    free_list = o;
}

fn incr(o: *Obj) void {
    o.refCount += 1;
}

fn decr(o: *Obj) void {
    o.refCount -= 1;
    if (o.refCount <= 0) tclFreeObj(o);
}

// Ints and doubles keep the value in the internal form.

fn updateWide(o: *Obj) callconv(.c) void {
    var buf: [24]u8 = undefined;
    setText(o, value.writeInt(&buf, o.rep.wide));
}

fn updateDouble(o: *Obj) callconv(.c) void {
    var fba_buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    setText(o, value.formatDouble(fba.allocator(), o.rep.double) catch unreachable);
}

/// Ints have the type name of Tcl on a 32-bit `long`. The SQLite binding
/// reads the name to bind a variable as a number.
pub const wide_type: ObjType = .{ .name = "wideInt", .free = null, .dup = null, .update = &updateWide, .set_from_any = null };
pub const double_type: ObjType = .{ .name = "double", .free = null, .dup = null, .update = &updateDouble, .set_from_any = null };

// A list keeps an array of objects, each with one reference of the list.

const ListRep = struct {
    items: std.ArrayList(*Obj) = .empty,
};

fn listRep(o: *Obj) *ListRep {
    return @ptrCast(@alignCast(o.rep.two.p1));
}

fn freeList(o: *Obj) callconv(.c) void {
    const l = listRep(o);
    for (l.items.items) |e| decr(e);
    l.items.deinit(gpa);
    gpa.destroy(l);
}

fn dupList(src: *Obj, dst: *Obj) callconv(.c) void {
    const l = gpa.create(ListRep) catch panicText("out of memory");
    l.* = .{};
    l.items.appendSlice(gpa, listRep(src).items.items) catch panicText("out of memory");
    for (l.items.items) |e| incr(e);
    dst.rep = .{ .two = .{ .p1 = l, .p2 = null } };
    dst.typePtr = &list_type;
}

fn updateList(o: *Obj) callconv(.c) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (listRep(o).items.items, 0..) |e, n| {
        if (n > 0) out.append(gpa, ' ') catch panicText("out of memory");
        value.appendElement(gpa, &out, text(e), n == 0) catch panicText("out of memory");
    }
    setText(o, out.items);
}

pub const list_type: ObjType = .{ .name = "list", .free = &freeList, .dup = &dupList, .update = &updateList, .set_from_any = null };

// A byte array keeps its bytes. The text form has one character for each
// byte, U+0000 to U+00FF, in the modified UTF-8 of Tcl (U+0000 is C0 80).

const ByteRep = struct {
    data: std.ArrayList(u8) = .empty,
};

fn byteRep(o: *Obj) *ByteRep {
    return @ptrCast(@alignCast(o.rep.two.p1));
}

fn freeBytes(o: *Obj) callconv(.c) void {
    const r = byteRep(o);
    r.data.deinit(gpa);
    gpa.destroy(r);
}

fn dupBytes(src: *Obj, dst: *Obj) callconv(.c) void {
    setByteRep(dst, byteRep(src).data.items);
}

fn updateBytes(o: *Obj) callconv(.c) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (byteRep(o).data.items) |c| {
        if (c >= 1 and c < 0x80) {
            out.append(gpa, c) catch panicText("out of memory");
        } else {
            out.appendSlice(gpa, &.{ 0xC0 | (c >> 6), 0x80 | (c & 0x3F) }) catch panicText("out of memory");
        }
    }
    setText(o, out.items);
}

pub const bytes_type: ObjType = .{ .name = "bytearray", .free = &freeBytes, .dup = &dupBytes, .update = &updateBytes, .set_from_any = null };

fn setByteRep(o: *Obj, data: []const u8) void {
    const r = gpa.create(ByteRep) catch panicText("out of memory");
    r.* = .{};
    r.data.appendSlice(gpa, data) catch panicText("out of memory");
    o.rep = .{ .two = .{ .p1 = r, .p2 = null } };
    o.typePtr = &bytes_type;
}

// The index type keeps the table and the index of the last match of
// `Tcl_GetIndexFromObjStruct`. The text form stays.

pub const index_type: ObjType = .{ .name = "index", .free = null, .dup = null, .update = null, .set_from_any = null };

// ---- The slots of the objects group ----

fn Tcl_NewObj() callconv(.c) *Obj {
    return newObj();
}

fn Tcl_NewStringObj(bytes: ?[*]const u8, length: c_int) callconv(.c) *Obj {
    const o = newObj();
    if (bytes) |b| setText(o, if (length < 0) std.mem.span(@as([*:0]const u8, @ptrCast(b))) else b[0..@intCast(length)]);
    return o;
}

pub fn Tcl_NewWideIntObj(w: i64) callconv(.c) *Obj {
    const o = newObj();
    o.bytes = null;
    o.typePtr = &wide_type;
    o.rep = .{ .wide = w };
    return o;
}

fn Tcl_NewIntObj(i: c_int) callconv(.c) *Obj {
    return Tcl_NewWideIntObj(i);
}

fn Tcl_NewLongObj(i: c_long) callconv(.c) *Obj {
    return Tcl_NewWideIntObj(i);
}

fn Tcl_NewBooleanObj(b: c_int) callconv(.c) *Obj {
    return Tcl_NewWideIntObj(@intFromBool(b != 0));
}

pub fn Tcl_NewDoubleObj(d: f64) callconv(.c) *Obj {
    const o = newObj();
    o.bytes = null;
    o.typePtr = &double_type;
    o.rep = .{ .double = d };
    return o;
}

fn Tcl_NewByteArrayObj(bytes: ?[*]const u8, length: c_int) callconv(.c) *Obj {
    const o = newObj();
    o.bytes = null;
    setByteRep(o, if (bytes) |b| b[0..@intCast(@max(length, 0))] else &.{});
    return o;
}

fn newListRep(o: *Obj) *ListRep {
    const l = gpa.create(ListRep) catch panicText("out of memory");
    l.* = .{};
    o.bytes = null;
    o.rep = .{ .two = .{ .p1 = l, .p2 = null } };
    o.typePtr = &list_type;
    return l;
}

pub fn Tcl_NewListObj(objc: c_int, objv: ?[*]const *Obj) callconv(.c) *Obj {
    const o = newObj();
    const l = newListRep(o);
    if (objc > 0) {
        const items = objv.?[0..@intCast(objc)];
        l.items.appendSlice(gpa, items) catch panicText("out of memory");
        for (items) |e| incr(e);
    }
    return o;
}

fn Tcl_DuplicateObj(src: *Obj) callconv(.c) *Obj {
    const o = newObj();
    o.bytes = null;
    if (src.bytes != null) setText(o, text(src));
    if (src.typePtr) |t| {
        if (t.dup) |d| d(src, o) else {
            o.rep = src.rep;
            o.typePtr = t;
        }
    }
    return o;
}

fn Tcl_DbIncrRefCount(o: *Obj, _: [*:0]const u8, _: c_int) callconv(.c) void {
    incr(o);
}

fn Tcl_DbDecrRefCount(o: *Obj, _: [*:0]const u8, _: c_int) callconv(.c) void {
    decr(o);
}

fn Tcl_DbIsShared(o: *Obj, _: [*:0]const u8, _: c_int) callconv(.c) c_int {
    return @intFromBool(o.refCount > 1);
}

pub fn Tcl_GetString(o: *Obj) callconv(.c) [*:0]u8 {
    _ = text(o);
    return @ptrCast(o.bytes.?);
}

fn Tcl_GetStringFromObj(o: *Obj, len: ?*c_int) callconv(.c) [*:0]u8 {
    const s = text(o);
    if (len) |l| l.* = @intCast(s.len);
    return @ptrCast(o.bytes.?);
}

fn Tcl_InvalidateStringRep(o: *Obj) callconv(.c) void {
    invalidate(o);
}

fn Tcl_GetCharLength(o: *Obj) callconv(.c) c_int {
    if (o.typePtr == &bytes_type and o.bytes == null) return @intCast(byteRep(o).data.items.len);
    return @intCast(std.unicode.utf8CountCodepoints(text(o)) catch text(o).len);
}

/// Sets the result to "expected WHAT but got "TEXT"" and gives ERROR.
fn expected(interp: ?*Interp, what: []const u8, o: *Obj) c_int {
    if (interp) |ip| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        out.print(gpa, "expected {s} but got \"{s}\"", .{ what, text(o) }) catch panicText("out of memory");
        setResultText(ip, out.items);
    }
    return ERROR;
}

/// Gives the internal form a new type: frees the old one and keeps the
/// text form.
fn shimmer(o: *Obj, t: *const ObjType, rep: Rep) void {
    _ = text(o);
    freeIntRep(o);
    o.typePtr = t;
    o.rep = rep;
}

pub fn Tcl_GetWideIntFromObj(interp: ?*Interp, o: *Obj, out: *i64) callconv(.c) c_int {
    if (o.typePtr == &wide_type) {
        out.* = o.rep.wide;
        return OK;
    }
    if (o.typePtr == &double_type) return expected(interp, "integer", o);
    const w = value.parseInt(text(o)) orelse return expected(interp, "integer", o);
    shimmer(o, &wide_type, .{ .wide = w });
    out.* = w;
    return OK;
}

fn Tcl_GetIntFromObj(interp: ?*Interp, o: *Obj, out: *c_int) callconv(.c) c_int {
    var w: i64 = 0;
    if (Tcl_GetWideIntFromObj(interp, o, &w) != OK) return ERROR;
    // Tcl accepts a value up to the range of an unsigned int and wraps it.
    if (w < -0xFFFFFFFF or w > 0xFFFFFFFF) {
        if (interp) |ip| setResultText(ip, "integer value too large to represent");
        return ERROR;
    }
    out.* = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(w)))));
    return OK;
}

fn Tcl_GetLongFromObj(interp: ?*Interp, o: *Obj, out: *c_long) callconv(.c) c_int {
    if (@sizeOf(c_long) == 8) return Tcl_GetWideIntFromObj(interp, o, @ptrCast(out));
    var i: c_int = 0;
    if (Tcl_GetIntFromObj(interp, o, &i) != OK) return ERROR;
    out.* = i;
    return OK;
}

pub fn Tcl_GetDoubleFromObj(interp: ?*Interp, o: *Obj, out: *f64) callconv(.c) c_int {
    if (o.typePtr == &double_type) {
        out.* = o.rep.double;
        return OK;
    }
    if (o.typePtr == &wide_type) {
        out.* = @floatFromInt(o.rep.wide);
        return OK;
    }
    const s = text(o);
    if (value.parseInt(s)) |w| {
        out.* = @floatFromInt(w);
        return OK;
    }
    const d = value.parseDouble(s) orelse return expected(interp, "floating-point number", o);
    if (std.math.isNan(d)) return expected(interp, "floating-point number", o);
    shimmer(o, &double_type, .{ .double = d });
    out.* = d;
    return OK;
}

/// The boolean words of Tcl. A unique prefix of a word is also a match.
fn parseBool(s0: []const u8) ?bool {
    const s = value.trimSpace(s0);
    if (s.len == 0 or s.len > 5) return null;
    var low: [5]u8 = undefined;
    for (s, 0..) |c, i| low[i] = std.ascii.toLower(c);
    const w = low[0..s.len];
    const words = [_]struct { []const u8, bool }{
        .{ "true", true },   .{ "yes", true }, .{ "on", true },
        .{ "false", false }, .{ "no", false }, .{ "off", false },
    };
    // "o" is a prefix of "on" and "off".
    if (std.mem.eql(u8, w, "o")) return null;
    for (words) |e| if (std.mem.startsWith(u8, e[0], w)) return e[1];
    return null;
}

fn Tcl_GetBooleanFromObj(interp: ?*Interp, o: *Obj, out: *c_int) callconv(.c) c_int {
    if (o.typePtr == &wide_type) {
        out.* = @intFromBool(o.rep.wide != 0);
        return OK;
    }
    if (o.typePtr == &double_type) {
        out.* = @intFromBool(o.rep.double != 0);
        return OK;
    }
    const s = text(o);
    if (value.parseInt(s)) |w| {
        out.* = @intFromBool(w != 0);
        return OK;
    }
    if (parseBool(s)) |b| {
        out.* = @intFromBool(b);
        return OK;
    }
    if (value.parseDouble(s)) |d| if (!std.math.isNan(d)) {
        out.* = @intFromBool(d != 0);
        return OK;
    };
    return expected(interp, "boolean value", o);
}

fn Tcl_GetByteArrayFromObj(o: *Obj, len: ?*c_int) callconv(.c) [*]u8 {
    if (o.typePtr != &bytes_type) {
        // Each character gives its low 8 bits.
        const s = text(o);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        var i: usize = 0;
        while (i < s.len) {
            // C0 80 is U+0000 in the modified UTF-8 of Tcl. A byte that
            // starts no valid sequence stands for itself.
            if (s[i] == 0xC0 and i + 1 < s.len and s[i + 1] == 0x80) {
                data.append(gpa, 0) catch panicText("out of memory");
                i += 2;
                continue;
            }
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const cp: ?u21 = if (i + n <= s.len) (std.unicode.utf8Decode(s[i..][0..n]) catch null) else null;
            data.append(gpa, @truncate(cp orelse s[i])) catch panicText("out of memory");
            i += if (cp != null) n else 1;
        }
        freeIntRep(o);
        setByteRep(o, data.items);
    }
    const r = byteRep(o);
    if (len) |l| l.* = @intCast(r.data.items.len);
    // An empty array still gives a valid address.
    return if (r.data.items.len == 0) @ptrCast(&empty_rep) else r.data.items.ptr;
}

fn Tcl_SetWideIntObj(o: *Obj, w: i64) callconv(.c) void {
    freeIntRep(o);
    invalidate(o);
    o.typePtr = &wide_type;
    o.rep = .{ .wide = w };
}

fn Tcl_SetIntObj(o: *Obj, i: c_int) callconv(.c) void {
    Tcl_SetWideIntObj(o, i);
}

fn Tcl_SetLongObj(o: *Obj, i: c_long) callconv(.c) void {
    Tcl_SetWideIntObj(o, i);
}

fn Tcl_SetBooleanObj(o: *Obj, b: c_int) callconv(.c) void {
    Tcl_SetWideIntObj(o, @intFromBool(b != 0));
}

fn Tcl_SetDoubleObj(o: *Obj, d: f64) callconv(.c) void {
    freeIntRep(o);
    invalidate(o);
    o.typePtr = &double_type;
    o.rep = .{ .double = d };
}

fn Tcl_SetStringObj(o: *Obj, bytes: ?[*]const u8, length: c_int) callconv(.c) void {
    freeIntRep(o);
    const b = bytes orelse return setText(o, "");
    setText(o, if (length < 0) std.mem.span(@as([*:0]const u8, @ptrCast(b))) else b[0..@intCast(length)]);
}

fn Tcl_SetByteArrayObj(o: *Obj, bytes: ?[*]const u8, length: c_int) callconv(.c) void {
    freeIntRep(o);
    invalidate(o);
    setByteRep(o, if (bytes) |b| b[0..@intCast(@max(length, 0))] else &.{});
}

/// Gives the object the list type. The text is parsed by the rules of
/// Tcl lists.
fn toList(interp: ?*Interp, o: *Obj) ?*ListRep {
    if (o.typePtr == &list_type) return listRep(o);
    const s = text(o);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = value.parseList(arena.allocator(), s) catch {
        if (interp) |ip| setResultText(ip, listFaultText(arena.allocator(), s));
        return null;
    };
    var objs: std.ArrayList(*Obj) = .empty;
    objs.ensureTotalCapacity(gpa, items.len) catch panicText("out of memory");
    for (items) |e| {
        const eo = Tcl_NewStringObj(e.str.ptr, @intCast(e.str.len));
        incr(eo);
        objs.appendAssumeCapacity(eo);
    }
    const l = gpa.create(ListRep) catch panicText("out of memory");
    l.* = .{ .items = objs };
    shimmer(o, &list_type, .{ .two = .{ .p1 = l, .p2 = null } });
    return l;
}

fn listFaultText(a: std.mem.Allocator, s: []const u8) []const u8 {
    const f = value.listFault(s) orelse return "bad list";
    return switch (f.kind) {
        .brace => "unmatched open brace in list",
        .quote => "unmatched open quote in list",
        .after_brace => std.fmt.allocPrint(a, "list element in braces followed by \"{s}\" instead of space", .{f.rest}) catch "bad list",
        .after_quote => std.fmt.allocPrint(a, "list element in quotes followed by \"{s}\" instead of space", .{f.rest}) catch "bad list",
    };
}

fn Tcl_ListObjAppendElement(interp: ?*Interp, o: *Obj, e: *Obj) callconv(.c) c_int {
    const l = toList(interp, o) orelse return ERROR;
    l.items.append(gpa, e) catch panicText("out of memory");
    incr(e);
    invalidate(o);
    return OK;
}

fn Tcl_ListObjAppendList(interp: ?*Interp, o: *Obj, other: *Obj) callconv(.c) c_int {
    const src = toList(interp, other) orelse return ERROR;
    const l = toList(interp, o) orelse return ERROR;
    // `other` can be `o`, so the items are taken first.
    const items = gpa.dupe(*Obj, src.items.items) catch panicText("out of memory");
    defer gpa.free(items);
    l.items.appendSlice(gpa, items) catch panicText("out of memory");
    for (items) |e| incr(e);
    invalidate(o);
    return OK;
}

fn Tcl_ListObjGetElements(interp: ?*Interp, o: *Obj, objc: *c_int, objv: *[*]*Obj) callconv(.c) c_int {
    const l = toList(interp, o) orelse return ERROR;
    objc.* = @intCast(l.items.items.len);
    objv.* = l.items.items.ptr;
    return OK;
}

fn Tcl_ListObjIndex(interp: ?*Interp, o: *Obj, index: c_int, out: *?*Obj) callconv(.c) c_int {
    const l = toList(interp, o) orelse return ERROR;
    out.* = if (index >= 0 and index < l.items.items.len) l.items.items[@intCast(index)] else null;
    return OK;
}

fn Tcl_ListObjLength(interp: ?*Interp, o: *Obj, len: *c_int) callconv(.c) c_int {
    const l = toList(interp, o) orelse return ERROR;
    len.* = @intCast(l.items.items.len);
    return OK;
}

fn Tcl_ListObjReplace(interp: ?*Interp, o: *Obj, first0: c_int, count0: c_int, objc: c_int, objv: ?[*]const *Obj) callconv(.c) c_int {
    const l = toList(interp, o) orelse return ERROR;
    const n = l.items.items.len;
    const first: usize = @intCast(std.math.clamp(first0, 0, @as(c_int, @intCast(n))));
    const count: usize = @intCast(std.math.clamp(count0, 0, @as(c_int, @intCast(n - first))));
    const add: []const *Obj = if (objc > 0) objv.?[0..@intCast(objc)] else &.{};
    for (add) |e| incr(e);
    for (l.items.items[first..][0..count]) |e| decr(e);
    l.items.replaceRange(gpa, first, count, add) catch panicText("out of memory");
    invalidate(o);
    return OK;
}

fn Tcl_SetListObj(o: *Obj, objc: c_int, objv: ?[*]const *Obj) callconv(.c) void {
    freeIntRep(o);
    invalidate(o);
    const l = newListRep(o);
    if (objc > 0) {
        const items = objv.?[0..@intCast(objc)];
        l.items.appendSlice(gpa, items) catch panicText("out of memory");
        for (items) |e| incr(e);
    }
}

fn appendText(o: *Obj, s: []const u8) void {
    const old = text(o);
    var out = gpa.alloc(u8, old.len + s.len) catch panicText("out of memory");
    defer gpa.free(out);
    @memcpy(out[0..old.len], old);
    @memcpy(out[old.len..], s);
    freeIntRep(o);
    setText(o, out);
}

fn Tcl_AppendToObj(o: *Obj, bytes: [*]const u8, length: c_int) callconv(.c) void {
    appendText(o, if (length < 0) std.mem.span(@as([*:0]const u8, @ptrCast(bytes))) else bytes[0..@intCast(length)]);
}

fn Tcl_AppendObjToObj(o: *Obj, other: *Obj) callconv(.c) void {
    const s = gpa.dupe(u8, text(other)) catch panicText("out of memory");
    defer gpa.free(s);
    appendText(o, s);
}

fn Tcl_AppendStringsToObj(o: *Obj, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    while (true) {
        const p = @cVaArg(&ap, ?[*:0]const u8) orelse break;
        appendText(o, std.mem.span(p));
    }
}

// ---- Results ----

fn result(ip: *Interp) *Obj {
    if (ip.result == null) {
        const o = newObj();
        incr(o);
        ip.result = o;
    }
    return ip.result.?;
}

pub fn Tcl_SetObjResult(ip: *Interp, o: *Obj) callconv(.c) void {
    incr(o);
    if (ip.result) |old| decr(old);
    ip.result = o;
}

pub fn Tcl_GetObjResult(ip: *Interp) callconv(.c) *Obj {
    return result(ip);
}

pub fn setResultText(ip: *Interp, s: []const u8) void {
    Tcl_SetObjResult(ip, Tcl_NewStringObj(s.ptr, @intCast(s.len)));
}

/// The values of `Tcl_FreeProc` that are not procs.
const TCL_STATIC: usize = 0;
const TCL_VOLATILE: usize = 1;
const TCL_DYNAMIC: usize = 3;

fn Tcl_SetResult(ip: *Interp, s: ?[*:0]u8, free_proc: usize) callconv(.c) void {
    const str = s orelse return Tcl_ResetResult(ip);
    setResultText(ip, std.mem.span(str));
    switch (free_proc) {
        TCL_STATIC, TCL_VOLATILE => {},
        TCL_DYNAMIC => std.c.free(str),
        else => {
            const f: *const fn ([*:0]u8) callconv(.c) void = @ptrFromInt(free_proc);
            f(str);
        },
    }
}

fn Tcl_GetStringResult(ip: *Interp) callconv(.c) [*:0]u8 {
    return Tcl_GetString(result(ip));
}

pub fn Tcl_ResetResult(ip: *Interp) callconv(.c) void {
    if (ip.result) |old| {
        if (old.refCount == 1 and old.typePtr == null and old.bytes == @as([*]u8, &empty_rep)) return;
        decr(old);
    }
    ip.result = null;
}

/// Gives an unshared result for an append.
fn ownResult(ip: *Interp) *Obj {
    const r = result(ip);
    if (r.refCount > 1) {
        const d = Tcl_DuplicateObj(r);
        Tcl_SetObjResult(ip, d);
        return d;
    }
    return r;
}

fn Tcl_AppendResult(ip: *Interp, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const r = ownResult(ip);
    while (true) {
        const p = @cVaArg(&ap, ?[*:0]const u8) orelse break;
        appendText(r, std.mem.span(p));
    }
}

fn Tcl_AppendElement(ip: *Interp, s: [*:0]const u8) callconv(.c) void {
    const r = ownResult(ip);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const old = text(r);
    out.appendSlice(gpa, old) catch panicText("out of memory");
    if (old.len > 0) out.append(gpa, ' ') catch panicText("out of memory");
    value.appendElement(gpa, &out, std.mem.span(s), old.len == 0) catch panicText("out of memory");
    freeIntRep(r);
    setText(r, out.items);
}

fn Tcl_WrongNumArgs(ip: *Interp, objc: c_int, objv: ?[*]const *Obj, message: ?[*:0]const u8) callconv(.c) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "wrong # args: should be \"") catch panicText("out of memory");
    var n: usize = 0;
    while (n < objc) : (n += 1) {
        if (n > 0) out.append(gpa, ' ') catch panicText("out of memory");
        value.appendElement(gpa, &out, text(objv.?[n]), false) catch panicText("out of memory");
    }
    if (message) |m| {
        if (objc > 0) out.append(gpa, ' ') catch panicText("out of memory");
        out.appendSlice(gpa, std.mem.span(m)) catch panicText("out of memory");
    }
    out.append(gpa, '"') catch panicText("out of memory");
    setResultText(ip, out.items);
}

// ---- Dynamic strings ----

/// `Tcl_DString` of Tcl 8.6.
pub const DString = extern struct {
    string: [*]u8,
    length: c_int,
    space: c_int,
    static_space: [200]u8,
};

fn Tcl_DStringInit(ds: *DString) callconv(.c) void {
    ds.string = &ds.static_space;
    ds.length = 0;
    ds.space = ds.static_space.len;
    ds.static_space[0] = 0;
}

fn dsReserve(ds: *DString, need: usize) void {
    if (need < @as(usize, @intCast(ds.space))) return;
    const cap = @max(need + 1, @as(usize, @intCast(ds.space)) * 2);
    const p: [*]u8 = @ptrCast(std.c.malloc(cap) orelse panicText("out of memory"));
    @memcpy(p[0..@intCast(ds.length + 1)], ds.string[0..@intCast(ds.length + 1)]);
    if (ds.string != @as([*]u8, &ds.static_space)) std.c.free(ds.string);
    ds.string = p;
    ds.space = @intCast(cap);
}

fn dsAppend(ds: *DString, s: []const u8) void {
    const len: usize = @intCast(ds.length);
    dsReserve(ds, len + s.len);
    @memcpy(ds.string[len..][0..s.len], s);
    ds.length = @intCast(len + s.len);
    ds.string[len + s.len] = 0;
}

fn Tcl_DStringAppend(ds: *DString, bytes: [*]const u8, length: c_int) callconv(.c) [*]u8 {
    dsAppend(ds, if (length < 0) std.mem.span(@as([*:0]const u8, @ptrCast(bytes))) else bytes[0..@intCast(length)]);
    return ds.string;
}

fn Tcl_DStringAppendElement(ds: *DString, s: [*:0]const u8) callconv(.c) [*]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // A separator goes in after text that does not end a sublist.
    const len: usize = @intCast(ds.length);
    const first = len == 0 or ds.string[len - 1] == '{';
    if (!first) out.append(gpa, ' ') catch panicText("out of memory");
    value.appendElement(gpa, &out, std.mem.span(s), first) catch panicText("out of memory");
    dsAppend(ds, out.items);
    return ds.string;
}

fn Tcl_DStringFree(ds: *DString) callconv(.c) void {
    if (ds.string != @as([*]u8, &ds.static_space)) std.c.free(ds.string);
    Tcl_DStringInit(ds);
}

fn Tcl_DStringSetLength(ds: *DString, length: c_int) callconv(.c) void {
    const n: usize = @intCast(@max(length, 0));
    dsReserve(ds, n);
    ds.length = @intCast(n);
    ds.string[n] = 0;
}

fn Tcl_DStringResult(ip: *Interp, ds: *DString) callconv(.c) void {
    setResultText(ip, ds.string[0..@intCast(ds.length)]);
    Tcl_DStringFree(ds);
}

fn Tcl_DStringGetResult(ip: *Interp, ds: *DString) callconv(.c) void {
    Tcl_DStringFree(ds);
    dsAppend(ds, text(result(ip)));
    Tcl_ResetResult(ip);
}

fn Tcl_DStringStartSublist(ds: *DString) callconv(.c) void {
    const len: usize = @intCast(ds.length);
    dsAppend(ds, if (len == 0 or ds.string[len - 1] == '{') "{" else " {");
}

fn Tcl_DStringEndSublist(ds: *DString) callconv(.c) void {
    dsAppend(ds, "}");
}

// ---- Helpers ----

fn Tcl_GetVersion(major: ?*c_int, minor: ?*c_int, patch: ?*c_int, kind: ?*c_int) callconv(.c) void {
    if (major) |p| p.* = 8;
    if (minor) |p| p.* = 6;
    if (patch) |p| p.* = 16;
    // TCL_FINAL_RELEASE
    if (kind) |p| p.* = 2;
}

const TCL_EXACT: c_int = 1;

pub fn Tcl_GetIndexFromObjStruct(ip: ?*Interp, o: *Obj, tbl: *const anyopaque, offset: c_int, msg: [*:0]const u8, flags: c_int, out: *c_int) callconv(.c) c_int {
    const base: [*]const u8 = @ptrCast(tbl);
    const stride: usize = @intCast(offset);
    const entry = struct {
        fn at(b: [*]const u8, s: usize, i: usize) ?[*:0]const u8 {
            const p: *align(1) const ?[*:0]const u8 = @ptrCast(b + i * s);
            return p.*;
        }
    }.at;
    if (o.typePtr == &index_type and o.rep.two.p1 == @as(?*anyopaque, @ptrCast(@constCast(tbl)))) {
        out.* = @intCast(@intFromPtr(o.rep.two.p2));
        return OK;
    }
    const key = text(o);
    var found: ?usize = null;
    var matches: usize = 0;
    var i: usize = 0;
    while (entry(base, stride, i)) |name| : (i += 1) {
        const n = std.mem.span(name);
        if (std.mem.eql(u8, n, key)) {
            found = i;
            matches = 1;
            break;
        }
        if (flags & TCL_EXACT == 0 and key.len > 0 and std.mem.startsWith(u8, n, key)) {
            found = i;
            matches += 1;
        }
    }
    if (found != null and matches == 1) {
        shimmer(o, &index_type, .{ .two = .{ .p1 = @constCast(tbl), .p2 = @ptrFromInt(found.?) } });
        out.* = @intCast(found.?);
        return OK;
    }
    if (ip) |interp| {
        var w: std.ArrayList(u8) = .empty;
        defer w.deinit(gpa);
        const m = std.mem.span(msg);
        w.print(gpa, "{s} {s} \"{s}\": must be ", .{ if (matches > 1) "ambiguous" else "bad", m, key }) catch panicText("out of memory");
        // Tcl leaves out the empty names from the list.
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        var j: usize = 0;
        while (entry(base, stride, j)) |name| : (j += 1) {
            if (name[0] != 0) names.append(gpa, std.mem.span(name)) catch panicText("out of memory");
        }
        for (names.items, 0..) |n, k| {
            if (k > 0) w.appendSlice(gpa, if (k + 1 == names.items.len) (if (names.items.len > 2) ", or " else " or ") else ", ") catch panicText("out of memory");
            w.appendSlice(gpa, n) catch panicText("out of memory");
        }
        setResultText(interp, w.items);
    }
    return ERROR;
}

/// File names go to WASI as they are, so the translation is a copy.
fn Tcl_TranslateFileName(_: ?*Interp, name: [*:0]const u8, ds: *DString) callconv(.c) [*:0]u8 {
    Tcl_DStringInit(ds);
    dsAppend(ds, std.mem.span(name));
    return @ptrCast(ds.string);
}

fn Tcl_PkgRequireEx(ip: *Interp, name: [*:0]const u8, version: ?[*:0]const u8, exact: c_int, client_data: ?*anyopaque) callconv(.c) ?[*:0]const u8 {
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

fn noHost() noreturn {
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
var xbuf: std.ArrayList(u8) = .empty;
var args_area: std.ArrayList(Arg) = .empty;

fn ztcl_cext_buf(len: usize) callconv(.c) [*]u8 {
    xbuf.ensureTotalCapacity(gpa, @max(len, 1)) catch panicText("out of memory");
    return xbuf.items.ptr;
}

fn ztcl_cext_args(argc: usize) callconv(.c) [*]Arg {
    args_area.ensureTotalCapacity(gpa, @max(argc, 1)) catch panicText("out of memory");
    return args_area.items.ptr;
}

fn ztcl_cext_reply() callconv(.c) *Arg {
    return &reply;
}

/// The object of a reply or an argument from ztcl.
fn objOf(a: Arg) *Obj {
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
fn argOf(o: *Obj) Arg {
    if (o.typePtr == &wide_type) return .{ .kind = 1, .len = 0, .bits = @bitCast(o.rep.wide) };
    if (o.typePtr == &double_type) return .{ .kind = 2, .len = 0, .bits = @bitCast(o.rep.double) };
    const s = text(o);
    return .{ .kind = 0, .len = @intCast(s.len), .bits = @intFromPtr(s.ptr) };
}

pub const ObjCmdProc = *const fn (?*anyopaque, *Interp, c_int, [*]const *Obj) callconv(.c) c_int;
pub const DeleteProc = *const fn (?*anyopaque) callconv(.c) void;
pub const NRPostProc = *const fn ([*]?*anyopaque, *Interp, c_int) callconv(.c) c_int;

const Command = struct {
    proc: ?ObjCmdProc,
    nre: ?ObjCmdProc,
    cd: ?*anyopaque,
    delete: ?DeleteProc,
    interp: *Interp,
    name: []u8,
    live: bool = true,
};

var commands: std.ArrayList(*Command) = .empty;

fn createCommand(ip: *Interp, name: [*:0]const u8, proc: ?ObjCmdProc, nre: ?ObjCmdProc, cd: ?*anyopaque, delete: ?DeleteProc) *Command {
    const c = gpa.create(Command) catch panicText("out of memory");
    const n = std.mem.span(name);
    c.* = .{ .proc = proc, .nre = nre, .cd = cd, .delete = delete, .interp = ip, .name = gpa.dupe(u8, n) catch panicText("out of memory") };
    const id: u32 = @intCast(commands.items.len);
    commands.append(gpa, c) catch panicText("out of memory");
    if (host.cmd_create(ip.handle, id, n.ptr, n.len) != 0) panicText("Tcl_CreateObjCommand: ztcl gave an error");
    return c;
}

fn Tcl_CreateObjCommand(ip: *Interp, name: [*:0]const u8, proc: ObjCmdProc, cd: ?*anyopaque, delete: ?DeleteProc) callconv(.c) *Command {
    return createCommand(ip, name, proc, null, cd, delete);
}

fn Tcl_NRCreateCommand(ip: *Interp, name: [*:0]const u8, proc: ?ObjCmdProc, nre: ObjCmdProc, cd: ?*anyopaque, delete: ?DeleteProc) callconv(.c) *Command {
    return createCommand(ip, name, proc, nre, cd, delete);
}

/// Runs the delete proc of a command once.
fn forget(c: *Command) void {
    if (!c.live) return;
    c.live = false;
    if (c.delete) |d| d(c.cd);
}

fn Tcl_DeleteCommand(ip: *Interp, name: [*:0]const u8) callconv(.c) c_int {
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

fn Tcl_DeleteCommandFromToken(ip: *Interp, c: *Command) callconv(.c) c_int {
    if (!c.live) return -1;
    _ = host.cmd_delete(ip.handle, c.name.ptr, c.name.len);
    forget(c);
    return 0;
}

// The non-recursive engine. A frame has the script of `Tcl_NREvalObj`
// and the callbacks of `Tcl_NRAddCallback`. After the function of a
// command returns, the script runs, and then the callbacks, last in
// first, each with the code of the step before it.

const Callback = struct { proc: NRPostProc, data: [4]?*anyopaque };

const NRFrame = struct {
    eval: ?*Obj = null,
    eval_flags: c_int = 0,
    callbacks: std.ArrayList(Callback) = .empty,
    /// The objects of `Tcl_GetVar2Ex` and `Tcl_ObjSetVar2`. In Tcl the
    /// variable owns them. Here the frame owns them until the command
    /// returns.
    owned: std.ArrayList(*Obj) = .empty,
};

var frames: std.ArrayList(NRFrame) = .empty;

fn top() ?*NRFrame {
    if (frames.items.len == 0) return null;
    return &frames.items[frames.items.len - 1];
}

/// Keeps `o` alive until the current command returns.
fn own(o: *Obj) *Obj {
    incr(o);
    if (top()) |f| f.owned.append(gpa, o) catch panicText("out of memory") else {
        // Outside a command, for example in the init function, the object
        // stays.
    }
    return o;
}

fn runNR(ip: *Interp, first: c_int) c_int {
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

fn pushFrame() void {
    frames.append(gpa, .{}) catch panicText("out of memory");
}

fn popFrame() void {
    var f = frames.pop().?;
    for (f.owned.items) |o| decr(o);
    f.owned.deinit(gpa);
    f.callbacks.deinit(gpa);
}

fn Tcl_NREvalObj(_: *Interp, o: *Obj, flags: c_int) callconv(.c) c_int {
    const f = top() orelse panicText("Tcl_NREvalObj: no command runs");
    incr(o);
    if (f.eval) |old| decr(old);
    f.eval = o;
    f.eval_flags = flags;
    return OK;
}

fn Tcl_NRAddCallback(_: *Interp, proc: NRPostProc, d0: ?*anyopaque, d1: ?*anyopaque, d2: ?*anyopaque, d3: ?*anyopaque) callconv(.c) void {
    const f = top() orelse panicText("Tcl_NRAddCallback: no command runs");
    f.callbacks.append(gpa, .{ .proc = proc, .data = .{ d0, d1, d2, d3 } }) catch panicText("out of memory");
}

fn Tcl_NRCallObjProc(ip: *Interp, proc: ObjCmdProc, cd: ?*anyopaque, objc: c_int, objv: [*]const *Obj) callconv(.c) c_int {
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
var arg_cache: [1 << arg_cache_bits]?*Obj = @splat(null);

fn argObj(a: Arg) *Obj {
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
fn ztcl_cext_dispatch(id: u32, argc: usize) callconv(.c) i32 {
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

/// Makes the interp of the package for interp `handle` of ztcl.
fn ztcl_cext_interp(handle: u32) callconv(.c) *Interp {
    const ip = gpa.create(Interp) catch panicText("out of memory");
    ip.* = .{ .handle = handle };
    return ip;
}

/// Puts the result of `ip` in `reply`, after the init function.
fn ztcl_cext_result(ip: *Interp) callconv(.c) *Arg {
    reply = argOf(result(ip));
    return &reply;
}

/// The result object of a reply from ztcl.
fn takeReply(ip: *Interp) void {
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

fn evalText(ip: *Interp, s: []const u8, flags: c_int) c_int {
    const code = host.eval(ip.handle, s.ptr, s.len, flags);
    takeReply(ip);
    return code;
}

const TCL_EVAL_GLOBAL: c_int = 0x20000;

fn Tcl_Eval(ip: *Interp, script: [*:0]const u8) callconv(.c) c_int {
    return evalText(ip, std.mem.span(script), 0);
}

fn Tcl_EvalEx(ip: *Interp, script: [*]const u8, len: c_int, flags: c_int) callconv(.c) c_int {
    return evalText(ip, if (len < 0) std.mem.span(@as([*:0]const u8, @ptrCast(script))) else script[0..@intCast(len)], flags);
}

fn Tcl_GlobalEval(ip: *Interp, script: [*:0]const u8) callconv(.c) c_int {
    return evalText(ip, std.mem.span(script), TCL_EVAL_GLOBAL);
}

fn Tcl_VarEval(ip: *Interp, ...) callconv(.c) c_int {
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

const TCL_LEAVE_ERR_MSG: c_int = 0x200;

/// The name `name1(name2)`, or `name1`.
fn varName(buf: *std.ArrayList(u8), n1: []const u8, n2: ?[]const u8) []const u8 {
    const b = n2 orelse return n1;
    buf.appendSlice(gpa, n1) catch panicText("out of memory");
    buf.append(gpa, '(') catch panicText("out of memory");
    buf.appendSlice(gpa, b) catch panicText("out of memory");
    buf.append(gpa, ')') catch panicText("out of memory");
    return buf.items;
}

fn getVar(ip: *Interp, n1: []const u8, n2: ?[]const u8, flags: c_int) ?*Obj {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const n = varName(&buf, n1, n2);
    if (host.var_get(ip.handle, n.ptr, n.len, flags) != 0) {
        if (flags & TCL_LEAVE_ERR_MSG != 0) takeReply(ip);
        return null;
    }
    return own(objOf(reply));
}

fn Tcl_GetVar2Ex(ip: *Interp, n1: [*:0]const u8, n2: ?[*:0]const u8, flags: c_int) callconv(.c) ?*Obj {
    return getVar(ip, std.mem.span(n1), if (n2) |p| std.mem.span(p) else null, flags);
}

fn Tcl_ObjGetVar2(ip: *Interp, n1: *Obj, n2: ?*Obj, flags: c_int) callconv(.c) ?*Obj {
    return getVar(ip, text(n1), if (n2) |p| text(p) else null, flags);
}

fn Tcl_GetVar2(ip: *Interp, n1: [*:0]const u8, n2: ?[*:0]const u8, flags: c_int) callconv(.c) ?[*:0]u8 {
    const o = Tcl_GetVar2Ex(ip, n1, n2, flags) orelse return null;
    return Tcl_GetString(o);
}

fn Tcl_GetVar(ip: *Interp, n: [*:0]const u8, flags: c_int) callconv(.c) ?[*:0]u8 {
    return Tcl_GetVar2(ip, n, null, flags);
}

fn setVar(ip: *Interp, n1: []const u8, n2: ?[]const u8, v: *Obj, flags: c_int) ?*Obj {
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

fn Tcl_ObjSetVar2(ip: *Interp, n1: *Obj, n2: ?*Obj, v: *Obj, flags: c_int) callconv(.c) ?*Obj {
    return setVar(ip, text(n1), if (n2) |p| text(p) else null, v, flags);
}

fn Tcl_SetVar2Ex(ip: *Interp, n1: [*:0]const u8, n2: ?[*:0]const u8, v: *Obj, flags: c_int) callconv(.c) ?*Obj {
    return setVar(ip, std.mem.span(n1), if (n2) |p| std.mem.span(p) else null, v, flags);
}

fn Tcl_SetVar2(ip: *Interp, n1: [*:0]const u8, n2: ?[*:0]const u8, s: [*:0]const u8, flags: c_int) callconv(.c) ?[*:0]u8 {
    const o = Tcl_SetVar2Ex(ip, n1, n2, Tcl_NewStringObj(s, -1), flags) orelse return null;
    return Tcl_GetString(o);
}

fn Tcl_SetVar(ip: *Interp, n: [*:0]const u8, s: [*:0]const u8, flags: c_int) callconv(.c) ?[*:0]u8 {
    return Tcl_SetVar2(ip, n, null, s, flags);
}

fn Tcl_PkgProvideEx(ip: *Interp, name: [*:0]const u8, version: [*:0]const u8, _: ?*const anyopaque) callconv(.c) c_int {
    const n = std.mem.span(name);
    const v = std.mem.span(version);
    if (host.pkg_provide(ip.handle, n.ptr, n.len, v.ptr, v.len) != 0) {
        takeReply(ip);
        return ERROR;
    }
    return OK;
}

/// Runs `bgerror` with the result. An error of `bgerror` is dropped.
fn Tcl_BackgroundError(ip: *Interp) callconv(.c) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "bgerror ") catch panicText("out of memory");
    value.appendElement(gpa, &out, text(result(ip)), false) catch panicText("out of memory");
    _ = host.eval(ip.handle, out.items.ptr, out.items.len, TCL_EVAL_GLOBAL);
    Tcl_ResetResult(ip);
}

comptime {
    if (builtin.target.cpu.arch == .wasm32) {
        @export(&ztcl_cext_buf, .{ .name = "ztcl_cext_buf" });
        @export(&ztcl_cext_args, .{ .name = "ztcl_cext_args" });
        @export(&ztcl_cext_reply, .{ .name = "ztcl_cext_reply" });
        @export(&ztcl_cext_dispatch, .{ .name = "ztcl_cext_dispatch" });
        @export(&ztcl_cext_interp, .{ .name = "ztcl_cext_interp" });
        @export(&ztcl_cext_result, .{ .name = "ztcl_cext_result" });
    }
}

// ---- Memory ----

fn Tcl_Alloc(size: c_uint) callconv(.c) [*]u8 {
    return @ptrCast(std.c.malloc(@max(size, 1)) orelse panicText("out of memory"));
}

fn Tcl_AttemptAlloc(size: c_uint) callconv(.c) ?[*]u8 {
    return @ptrCast(std.c.malloc(@max(size, 1)));
}

fn Tcl_Free(p: ?[*]u8) callconv(.c) void {
    std.c.free(p);
}

fn Tcl_Realloc(p: ?[*]u8, size: c_uint) callconv(.c) [*]u8 {
    return @ptrCast(std.c.realloc(p, @max(size, 1)) orelse panicText("out of memory"));
}

fn Tcl_AttemptRealloc(p: ?[*]u8, size: c_uint) callconv(.c) ?[*]u8 {
    return @ptrCast(std.c.realloc(p, @max(size, 1)));
}

// ---- Panic ----

/// The handler of a panic. The tests set it. In the package it is the
/// import `ztcl.panic`, then a trap.
pub var panic_hook: ?*const fn ([]const u8) void = null;

fn panicText(msg: []const u8) noreturn {
    if (panic_hook) |h| h(msg);
    @panic(msg);
}

fn Tcl_Panic(format: [*:0]const u8, ...) callconv(.c) noreturn {
    // The format arguments are not expanded.
    panicText(std.mem.span(format));
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

pub const slot_count = 691;

/// The implemented slots, by number.
const implemented = [_]struct { usize, *const anyopaque }{
    .{ 0, &Tcl_PkgProvideEx },
    .{ 1, &Tcl_PkgRequireEx },
    .{ 2, &Tcl_Panic },
    .{ 3, &Tcl_Alloc },
    .{ 4, &Tcl_Free },
    .{ 5, &Tcl_Realloc },
    .{ 15, &Tcl_AppendStringsToObj },
    .{ 16, &Tcl_AppendToObj },
    .{ 19, &Tcl_DbDecrRefCount },
    .{ 20, &Tcl_DbIncrRefCount },
    .{ 21, &Tcl_DbIsShared },
    .{ 29, &Tcl_DuplicateObj },
    .{ 30, &tclFreeObj },
    .{ 32, &Tcl_GetBooleanFromObj },
    .{ 33, &Tcl_GetByteArrayFromObj },
    .{ 35, &Tcl_GetDoubleFromObj },
    .{ 38, &Tcl_GetIntFromObj },
    .{ 39, &Tcl_GetLongFromObj },
    .{ 41, &Tcl_GetStringFromObj },
    .{ 42, &Tcl_InvalidateStringRep },
    .{ 43, &Tcl_ListObjAppendList },
    .{ 44, &Tcl_ListObjAppendElement },
    .{ 45, &Tcl_ListObjGetElements },
    .{ 46, &Tcl_ListObjIndex },
    .{ 47, &Tcl_ListObjLength },
    .{ 48, &Tcl_ListObjReplace },
    .{ 49, &Tcl_NewBooleanObj },
    .{ 50, &Tcl_NewByteArrayObj },
    .{ 51, &Tcl_NewDoubleObj },
    .{ 52, &Tcl_NewIntObj },
    .{ 53, &Tcl_NewListObj },
    .{ 54, &Tcl_NewLongObj },
    .{ 55, &Tcl_NewObj },
    .{ 56, &Tcl_NewStringObj },
    .{ 57, &Tcl_SetBooleanObj },
    .{ 59, &Tcl_SetByteArrayObj },
    .{ 60, &Tcl_SetDoubleObj },
    .{ 61, &Tcl_SetIntObj },
    .{ 62, &Tcl_SetListObj },
    .{ 63, &Tcl_SetLongObj },
    .{ 65, &Tcl_SetStringObj },
    .{ 69, &Tcl_AppendElement },
    .{ 70, &Tcl_AppendResult },
    .{ 76, &Tcl_BackgroundError },
    .{ 96, &Tcl_CreateObjCommand },
    .{ 103, &Tcl_DeleteCommand },
    .{ 104, &Tcl_DeleteCommandFromToken },
    .{ 117, &Tcl_DStringAppend },
    .{ 118, &Tcl_DStringAppendElement },
    .{ 119, &Tcl_DStringEndSublist },
    .{ 120, &Tcl_DStringFree },
    .{ 121, &Tcl_DStringGetResult },
    .{ 122, &Tcl_DStringInit },
    .{ 123, &Tcl_DStringResult },
    .{ 124, &Tcl_DStringSetLength },
    .{ 125, &Tcl_DStringStartSublist },
    .{ 129, &Tcl_Eval },
    .{ 166, &Tcl_GetObjResult },
    .{ 174, &Tcl_GetStringResult },
    .{ 175, &Tcl_GetVar },
    .{ 176, &Tcl_GetVar2 },
    .{ 177, &Tcl_GlobalEval },
    .{ 195, &Tcl_ObjGetVar2 },
    .{ 196, &Tcl_ObjSetVar2 },
    .{ 217, &Tcl_ResetResult },
    .{ 232, &Tcl_SetResult },
    .{ 235, &Tcl_SetObjResult },
    .{ 237, &Tcl_SetVar },
    .{ 238, &Tcl_SetVar2 },
    .{ 249, &Tcl_TranslateFileName },
    .{ 260, &Tcl_VarEval },
    .{ 264, &Tcl_WrongNumArgs },
    .{ 279, &Tcl_GetVersion },
    .{ 286, &Tcl_AppendObjToObj },
    .{ 291, &Tcl_EvalEx },
    .{ 293, &Tcl_EvalObjEx },
    .{ 304, &Tcl_GetIndexFromObjStruct },
    .{ 306, &Tcl_GetVar2Ex },
    .{ 317, &Tcl_SetVar2Ex },
    .{ 340, &Tcl_GetString },
    .{ 380, &Tcl_GetCharLength },
    .{ 428, &Tcl_AttemptAlloc },
    .{ 430, &Tcl_AttemptRealloc },
    .{ 487, &Tcl_GetWideIntFromObj },
    .{ 488, &Tcl_NewWideIntObj },
    .{ 489, &Tcl_SetWideIntObj },
    .{ 583, &Tcl_NRCreateCommand },
    .{ 584, &Tcl_NREvalObj },
    .{ 587, &Tcl_NRAddCallback },
    .{ 588, &Tcl_NRCallObjProc },
};

/// `TclStubs` of Tcl 8.6: the magic number, the hooks, and the slots.
pub const Table = extern struct {
    magic: c_int,
    hooks: *const Hooks,
    slots: [slot_count]*const anyopaque,
};

pub const Hooks = extern struct {
    plat: ?*const anyopaque = null,
    int: ?*const anyopaque = null,
    int_plat: ?*const anyopaque = null,
};

/// TCL_STUB_MAGIC of Tcl 8.6.
pub const stub_magic: c_int = @bitCast(@as(u32, 0xFCA3BACF));

const hooks: Hooks = .{};

pub const table: Table = blk: {
    @setEvalBranchQuota(100_000);
    var t: Table = .{ .magic = stub_magic, .hooks = &hooks, .slots = undefined };
    for (0..slot_count) |n| t.slots[n] = missing(n);
    for (implemented) |e| t.slots[e[0]] = e[1];
    break :blk t;
};

/// The number of slots with an implementation.
pub const implemented_count = implemented.len;

/// The pointers that the stubs macros of `tcl.h` read.
pub var tclStubsPtr: ?*const Table = null;
pub var tclPlatStubsPtr: ?*const anyopaque = null;
pub var tclIntStubsPtr: ?*const anyopaque = null;
pub var tclIntPlatStubsPtr: ?*const anyopaque = null;

fn Tcl_InitStubs(ip: *Interp, version: ?[*:0]const u8, exact: c_int) callconv(.c) ?[*:0]const u8 {
    tclStubsPtr = &table;
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
    return @ptrCast(table.slots[n]);
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
    try testing.expectEqualStrings("wideInt", std.mem.span(i.typePtr.?.name));
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
    try testing.expect(o.typePtr == &index_type);
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
        reply = .{ .kind = 0, .len = @intCast(s.len), .bits = @intFromPtr(keep.items.ptr) };
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
    const saved = host;
    host = Fake.h;
    defer host = saved;
    const ip = ztcl_cext_interp(1);
    defer gpa.destroy(ip);
    defer Tcl_ResetResult(ip);
    const c = Tcl_NRCreateCommand(ip, "count", null, Count.cmd, null, null);
    const id: u32 = @intCast(std.mem.indexOfScalar(*Command, commands.items, c).?);
    const argv = ztcl_cext_args(2);
    argv[0] = .{ .kind = 0, .len = 5, .bits = @intFromPtr("count".ptr) };
    argv[1] = .{ .kind = 1, .len = 0, .bits = 3 };
    Fake.evals = 0;
    try testing.expectEqual(OK, ztcl_cext_dispatch(id, 2));
    try testing.expectEqual(1, reply.kind);
    try testing.expectEqual(3, reply.bits);
    try testing.expectEqual(3, Fake.evals);
    try testing.expectEqualStrings("3", Fake.vars.get("row").?);
    try testing.expect(frames.items.len == 0);
    argv[1] = .{ .kind = 0, .len = 1, .bits = @intFromPtr("x".ptr) };
    try testing.expectEqual(ERROR, ztcl_cext_dispatch(id, 2));
    try testing.expectEqualStrings("expected integer but got \"x\"", @as([*]const u8, @ptrFromInt(@as(usize, @intCast(reply.bits))))[0..reply.len]);
    // A variable that ztcl does not have gives null and the message.
    try testing.expect(Tcl_GetVar2Ex(ip, "nope", null, TCL_LEAVE_ERR_MSG) == null);
    try testing.expectEqualStrings("no such variable", std.mem.span(Tcl_GetStringResult(ip)));
    try testing.expectEqual(OK, Tcl_DeleteCommandFromToken(ip, c));
}

//! The objects, the interp result, and the dynamic strings of the stubs
//! table of Tcl 8.6. The native path (`stubs.zig`) and the WebAssembly
//! path (`wasm_stubs.zig`) use this one file, so each slot here has one
//! implementation for the two paths.
//!
//! The `Tcl_Obj` records are in C memory, in the layout of Tcl 8.6,
//! because C code reads and writes `refCount`, `bytes`, and `typePtr`
//! directly. Each value has a reference count, an optional text form,
//! and an internal form of one type. A type has the four procs of
//! `Tcl_ObjType`, and this file calls them for its own types and for the
//! types of a package. The text form is made on demand: an int with the
//! digits, a double with the shortest digits that read back (the
//! `formatDouble` of ztcl), and a list with the quoting of the `list`
//! command. A record that is freed goes to a free list of its thread for
//! the next `Tcl_NewObj`.
//!
//! `Interp` is the start of the `Tcl_Interp` of a package: the public
//! fields of Tcl 8.6, `stubTable`, and the result object. The two paths
//! add their own fields after it.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const value = @import("../value.zig");

const gpa = std.heap.c_allocator;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();
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

/// The start of `struct Interp` of Tcl 8.6, then the result object.
/// A path puts its own fields after it.
pub const Interp = extern struct {
    result_dont_use: [*:0]const u8 = "",
    free_proc_dont_use: ?*anyopaque = null,
    error_line_dont_use: c_int = 0,
    stub_table: ?*const anyopaque = null,
    result: ?*Obj = null,
    /// The id of the interp of ztcl in the WebAssembly path.
    handle: u32 = 0,
    /// The assoc data of the interp: a list of `hash.Assoc`.
    assoc: ?*anyopaque = null,
    /// The client data of the packages: a list of `host.PkgData`.
    pkgs: ?*anyopaque = null,
};

pub const OK: c_int = 0;
pub const ERROR: c_int = 1;

/// The text of an empty string. It is never freed.
var empty_rep: [1:0]u8 = .{0};

threadlocal var free_list: ?*Obj = null;

pub fn newObj() *Obj {
    const o: *Obj = if (free_list) |f| blk: {
        free_list = @ptrCast(@alignCast(f.rep.two.p1));
        break :blk f;
    } else gpa.create(Obj) catch panicText("out of memory");
    o.* = .{ .refCount = 0, .bytes = &empty_rep, .length = 0, .typePtr = null, .rep = .{ .wide = 0 } };
    return o;
}

pub fn freeIntRep(o: *Obj) void {
    if (o.typePtr) |t| if (t.free) |f| f(o);
    o.typePtr = null;
}

pub fn invalidate(o: *Obj) void {
    if (o.bytes) |b| if (b != @as([*]u8, &empty_rep)) std.c.free(b);
    o.bytes = null;
    o.length = 0;
}

/// Sets the text form to a copy of `s`.
pub fn setText(o: *Obj, s: []const u8) void {
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

pub fn TclFreeObj(o: *Obj) callconv(.c) void {
    freeIntRep(o);
    invalidate(o);
    o.rep.two.p1 = free_list;
    free_list = o;
}

pub fn incr(o: *Obj) void {
    o.refCount += 1;
}

pub fn decr(o: *Obj) void {
    o.refCount -= 1;
    if (o.refCount <= 0) TclFreeObj(o);
}

// Ints and doubles keep the value in the internal form.

pub fn updateWide(o: *Obj) callconv(.c) void {
    var buf: [24]u8 = undefined;
    setText(o, value.writeInt(&buf, o.rep.wide));
}

pub fn updateDouble(o: *Obj) callconv(.c) void {
    var fba_buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    setText(o, value.formatDouble(fba.allocator(), o.rep.double) catch unreachable);
}

/// Ints have the type name of Tcl on a 32-bit `long`. The SQLite binding
/// reads the name to bind a variable as a number.
/// The name of the int type of Tcl 8.6: "int" where a long has 64 bits
/// (LP64 Unix), and "wideInt" where it has 32 bits.
const wide_name = if (@sizeOf(c_long) == 8) "int" else "wideInt";
pub const wide_type: ObjType = .{ .name = wide_name, .free = null, .dup = null, .update = &updateWide, .set_from_any = null };
pub const double_type: ObjType = .{ .name = "double", .free = null, .dup = null, .update = &updateDouble, .set_from_any = null };

// A list keeps an array of objects, each with one reference of the list.

pub const ListRep = struct {
    items: std.ArrayList(*Obj) = .empty,
};

pub fn listRep(o: *Obj) *ListRep {
    return @ptrCast(@alignCast(o.rep.two.p1));
}

pub fn freeList(o: *Obj) callconv(.c) void {
    const l = listRep(o);
    for (l.items.items) |e| decr(e);
    l.items.deinit(gpa);
    gpa.destroy(l);
}

pub fn dupList(src: *Obj, dst: *Obj) callconv(.c) void {
    const l = gpa.create(ListRep) catch panicText("out of memory");
    l.* = .{};
    l.items.appendSlice(gpa, listRep(src).items.items) catch panicText("out of memory");
    for (l.items.items) |e| incr(e);
    dst.rep = .{ .two = .{ .p1 = l, .p2 = null } };
    dst.typePtr = &list_type;
}

pub fn updateList(o: *Obj) callconv(.c) void {
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

pub fn byteRep(o: *Obj) *ByteRep {
    return @ptrCast(@alignCast(o.rep.two.p1));
}

pub fn freeBytes(o: *Obj) callconv(.c) void {
    const r = byteRep(o);
    r.data.deinit(gpa);
    gpa.destroy(r);
}

pub fn dupBytes(src: *Obj, dst: *Obj) callconv(.c) void {
    setByteRep(dst, byteRep(src).data.items);
}

pub fn updateBytes(o: *Obj) callconv(.c) void {
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

pub fn setByteRep(o: *Obj, data: []const u8) void {
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

pub fn Tcl_NewObj() callconv(.c) *Obj {
    return newObj();
}

pub fn Tcl_NewStringObj(bytes: ?[*]const u8, length: c_int) callconv(.c) *Obj {
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

pub fn Tcl_NewIntObj(i: c_int) callconv(.c) *Obj {
    return Tcl_NewWideIntObj(i);
}

pub fn Tcl_NewLongObj(i: c_long) callconv(.c) *Obj {
    return Tcl_NewWideIntObj(i);
}

pub fn Tcl_NewBooleanObj(b: c_int) callconv(.c) *Obj {
    return Tcl_NewWideIntObj(@intFromBool(b != 0));
}

pub fn Tcl_NewDoubleObj(d: f64) callconv(.c) *Obj {
    const o = newObj();
    o.bytes = null;
    o.typePtr = &double_type;
    o.rep = .{ .double = d };
    return o;
}

pub fn Tcl_NewByteArrayObj(bytes: ?[*]const u8, length: c_int) callconv(.c) *Obj {
    const o = newObj();
    o.bytes = null;
    setByteRep(o, if (bytes) |b| b[0..@intCast(@max(length, 0))] else &.{});
    return o;
}

pub fn newListRep(o: *Obj) *ListRep {
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

pub fn Tcl_DuplicateObj(src: *Obj) callconv(.c) *Obj {
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

pub fn Tcl_DbIncrRefCount(o: *Obj, _: [*:0]const u8, _: c_int) callconv(.c) void {
    incr(o);
}

pub fn Tcl_DbDecrRefCount(o: *Obj, _: [*:0]const u8, _: c_int) callconv(.c) void {
    decr(o);
}

pub fn Tcl_DbIsShared(o: *Obj, _: [*:0]const u8, _: c_int) callconv(.c) c_int {
    return @intFromBool(o.refCount > 1);
}

pub fn Tcl_GetString(o: *Obj) callconv(.c) [*:0]u8 {
    _ = text(o);
    return @ptrCast(o.bytes.?);
}

pub fn Tcl_GetStringFromObj(o: *Obj, len: ?*c_int) callconv(.c) [*:0]u8 {
    const s = text(o);
    if (len) |l| l.* = @intCast(s.len);
    return @ptrCast(o.bytes.?);
}

pub fn Tcl_InvalidateStringRep(o: *Obj) callconv(.c) void {
    invalidate(o);
}

pub fn Tcl_GetCharLength(o: *Obj) callconv(.c) c_int {
    if (o.typePtr == &bytes_type and o.bytes == null) return @intCast(byteRep(o).data.items.len);
    return @intCast(std.unicode.utf8CountCodepoints(text(o)) catch text(o).len);
}

/// Sets the result to "expected WHAT but got "TEXT"" and gives ERROR.
pub fn expected(interp: ?*Interp, what: []const u8, o: *Obj) c_int {
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
pub fn shimmer(o: *Obj, t: *const ObjType, rep: Rep) void {
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

pub fn Tcl_GetIntFromObj(interp: ?*Interp, o: *Obj, out: *c_int) callconv(.c) c_int {
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

pub fn Tcl_GetLongFromObj(interp: ?*Interp, o: *Obj, out: *c_long) callconv(.c) c_int {
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
pub fn parseBool(s0: []const u8) ?bool {
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

pub fn Tcl_GetBooleanFromObj(interp: ?*Interp, o: *Obj, out: *c_int) callconv(.c) c_int {
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

pub fn Tcl_GetByteArrayFromObj(o: *Obj, len: ?*c_int) callconv(.c) [*]u8 {
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

pub fn Tcl_SetWideIntObj(o: *Obj, w: i64) callconv(.c) void {
    freeIntRep(o);
    invalidate(o);
    o.typePtr = &wide_type;
    o.rep = .{ .wide = w };
}

pub fn Tcl_SetIntObj(o: *Obj, i: c_int) callconv(.c) void {
    Tcl_SetWideIntObj(o, i);
}

pub fn Tcl_SetLongObj(o: *Obj, i: c_long) callconv(.c) void {
    Tcl_SetWideIntObj(o, i);
}

pub fn Tcl_SetBooleanObj(o: *Obj, b: c_int) callconv(.c) void {
    Tcl_SetWideIntObj(o, @intFromBool(b != 0));
}

pub fn Tcl_SetDoubleObj(o: *Obj, d: f64) callconv(.c) void {
    freeIntRep(o);
    invalidate(o);
    o.typePtr = &double_type;
    o.rep = .{ .double = d };
}

pub fn Tcl_SetStringObj(o: *Obj, bytes: ?[*]const u8, length: c_int) callconv(.c) void {
    freeIntRep(o);
    const b = bytes orelse return setText(o, "");
    setText(o, if (length < 0) std.mem.span(@as([*:0]const u8, @ptrCast(b))) else b[0..@intCast(length)]);
}

pub fn Tcl_SetByteArrayObj(o: *Obj, bytes: ?[*]const u8, length: c_int) callconv(.c) void {
    freeIntRep(o);
    invalidate(o);
    setByteRep(o, if (bytes) |b| b[0..@intCast(@max(length, 0))] else &.{});
}

/// Gives the object the list type. The text is parsed by the rules of
/// Tcl lists.
pub fn toList(interp: ?*Interp, o: *Obj) ?*ListRep {
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

pub fn listFaultText(a: std.mem.Allocator, s: []const u8) []const u8 {
    const f = value.listFault(s) orelse return "bad list";
    return switch (f.kind) {
        .brace => "unmatched open brace in list",
        .quote => "unmatched open quote in list",
        .after_brace => std.fmt.allocPrint(a, "list element in braces followed by \"{s}\" instead of space", .{f.rest}) catch "bad list",
        .after_quote => std.fmt.allocPrint(a, "list element in quotes followed by \"{s}\" instead of space", .{f.rest}) catch "bad list",
    };
}

pub fn Tcl_ListObjAppendElement(interp: ?*Interp, o: *Obj, e: *Obj) callconv(.c) c_int {
    const l = toList(interp, o) orelse return ERROR;
    l.items.append(gpa, e) catch panicText("out of memory");
    incr(e);
    invalidate(o);
    return OK;
}

pub fn Tcl_ListObjAppendList(interp: ?*Interp, o: *Obj, other: *Obj) callconv(.c) c_int {
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

pub fn Tcl_ListObjGetElements(interp: ?*Interp, o: *Obj, objc: *c_int, objv: *[*]*Obj) callconv(.c) c_int {
    const l = toList(interp, o) orelse return ERROR;
    objc.* = @intCast(l.items.items.len);
    objv.* = l.items.items.ptr;
    return OK;
}

pub fn Tcl_ListObjIndex(interp: ?*Interp, o: *Obj, index: c_int, out: *?*Obj) callconv(.c) c_int {
    const l = toList(interp, o) orelse return ERROR;
    out.* = if (index >= 0 and index < l.items.items.len) l.items.items[@intCast(index)] else null;
    return OK;
}

pub fn Tcl_ListObjLength(interp: ?*Interp, o: *Obj, len: *c_int) callconv(.c) c_int {
    const l = toList(interp, o) orelse return ERROR;
    len.* = @intCast(l.items.items.len);
    return OK;
}

pub fn Tcl_ListObjReplace(interp: ?*Interp, o: *Obj, first0: c_int, count0: c_int, objc: c_int, objv: ?[*]const *Obj) callconv(.c) c_int {
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

pub fn Tcl_SetListObj(o: *Obj, objc: c_int, objv: ?[*]const *Obj) callconv(.c) void {
    freeIntRep(o);
    invalidate(o);
    const l = newListRep(o);
    if (objc > 0) {
        const items = objv.?[0..@intCast(objc)];
        l.items.appendSlice(gpa, items) catch panicText("out of memory");
        for (items) |e| incr(e);
    }
}

pub fn appendText(o: *Obj, s: []const u8) void {
    const old = text(o);
    var out = gpa.alloc(u8, old.len + s.len) catch panicText("out of memory");
    defer gpa.free(out);
    @memcpy(out[0..old.len], old);
    @memcpy(out[old.len..], s);
    freeIntRep(o);
    setText(o, out);
}

pub fn Tcl_AppendToObj(o: *Obj, bytes: [*]const u8, length: c_int) callconv(.c) void {
    appendText(o, if (length < 0) std.mem.span(@as([*:0]const u8, @ptrCast(bytes))) else bytes[0..@intCast(length)]);
}

pub fn Tcl_AppendObjToObj(o: *Obj, other: *Obj) callconv(.c) void {
    const s = gpa.dupe(u8, text(other)) catch panicText("out of memory");
    defer gpa.free(s);
    appendText(o, s);
}

pub fn Tcl_AppendStringsToObj(o: *Obj, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    while (true) {
        const p = @cVaArg(&ap, ?[*:0]const u8) orelse break;
        appendText(o, std.mem.span(p));
    }
}

// ---- Results ----

pub fn result(ip: *Interp) *Obj {
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

pub fn Tcl_SetResult(ip: *Interp, s: ?[*:0]u8, free_proc: usize) callconv(.c) void {
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

pub fn Tcl_GetStringResult(ip: *Interp) callconv(.c) [*:0]u8 {
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
pub fn ownResult(ip: *Interp) *Obj {
    const r = result(ip);
    if (r.refCount > 1) {
        const d = Tcl_DuplicateObj(r);
        Tcl_SetObjResult(ip, d);
        return d;
    }
    return r;
}

pub fn Tcl_AppendResult(ip: *Interp, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const r = ownResult(ip);
    while (true) {
        const p = @cVaArg(&ap, ?[*:0]const u8) orelse break;
        appendText(r, std.mem.span(p));
    }
}

pub fn Tcl_AppendResultVA(ip: *Interp, ap: *std.builtin.VaList) callconv(.c) void {
    const r = ownResult(ip);
    while (true) {
        const p = @cVaArg(ap, ?[*:0]const u8) orelse break;
        appendText(r, std.mem.span(p));
    }
}

/// The text of `Tcl_SetResult` is in the result object, so there is no
/// separate text to free, and the result stays.
pub fn Tcl_FreeResult(_: *Interp) callconv(.c) void {}

/// `Tcl_SavedResult` of `tcl.h`. Only `objResultPtr` holds a value here:
/// the result object of the interp.
pub const SavedResult = extern struct {
    result: ?[*:0]u8,
    free_proc: ?*anyopaque,
    obj: ?*Obj,
    append_result: ?[*]u8,
    append_avl: c_int,
    append_used: c_int,
    space: [201]u8,
};

/// Moves the result to `state` and leaves the interp with the empty
/// result.
pub fn Tcl_SaveResult(ip: *Interp, state: *SavedResult) callconv(.c) void {
    state.obj = result(ip);
    ip.result = null;
}

pub fn Tcl_RestoreResult(ip: *Interp, state: *SavedResult) callconv(.c) void {
    Tcl_ResetResult(ip);
    if (ip.result) |old| decr(old);
    ip.result = state.obj;
    state.obj = null;
}

pub fn Tcl_DiscardResult(state: *SavedResult) callconv(.c) void {
    if (state.obj) |o| decr(o);
    state.obj = null;
}

/// Moves the result of `src` to `dst`.
pub fn Tcl_TransferResult(src: *Interp, _: c_int, dst: ?*Interp) callconv(.c) void {
    const to = dst orelse return;
    if (to == src) return;
    Tcl_SetObjResult(to, result(src));
    Tcl_ResetResult(src);
}

pub fn Tcl_AppendElement(ip: *Interp, s: [*:0]const u8) callconv(.c) void {
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

pub fn Tcl_WrongNumArgs(ip: *Interp, objc: c_int, objv: ?[*]const *Obj, message: ?[*:0]const u8) callconv(.c) void {
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

pub fn Tcl_DStringInit(ds: *DString) callconv(.c) void {
    ds.string = &ds.static_space;
    ds.length = 0;
    ds.space = ds.static_space.len;
    ds.static_space[0] = 0;
}

pub fn dsReserve(ds: *DString, need: usize) void {
    if (need < @as(usize, @intCast(ds.space))) return;
    const cap = @max(need + 1, @as(usize, @intCast(ds.space)) * 2);
    const p: [*]u8 = @ptrCast(std.c.malloc(cap) orelse panicText("out of memory"));
    @memcpy(p[0..@intCast(ds.length + 1)], ds.string[0..@intCast(ds.length + 1)]);
    if (ds.string != @as([*]u8, &ds.static_space)) std.c.free(ds.string);
    ds.string = p;
    ds.space = @intCast(cap);
}

pub fn dsAppend(ds: *DString, s: []const u8) void {
    const len: usize = @intCast(ds.length);
    dsReserve(ds, len + s.len);
    @memcpy(ds.string[len..][0..s.len], s);
    ds.length = @intCast(len + s.len);
    ds.string[len + s.len] = 0;
}

pub fn Tcl_DStringAppend(ds: *DString, bytes: [*]const u8, length: c_int) callconv(.c) [*]u8 {
    dsAppend(ds, if (length < 0) std.mem.span(@as([*:0]const u8, @ptrCast(bytes))) else bytes[0..@intCast(length)]);
    return ds.string;
}

pub fn Tcl_DStringAppendElement(ds: *DString, s: [*:0]const u8) callconv(.c) [*]u8 {
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

pub fn Tcl_DStringFree(ds: *DString) callconv(.c) void {
    if (ds.string != @as([*]u8, &ds.static_space)) std.c.free(ds.string);
    Tcl_DStringInit(ds);
}

pub fn Tcl_DStringSetLength(ds: *DString, length: c_int) callconv(.c) void {
    const n: usize = @intCast(@max(length, 0));
    dsReserve(ds, n);
    ds.length = @intCast(n);
    ds.string[n] = 0;
}

pub fn Tcl_DStringResult(ip: *Interp, ds: *DString) callconv(.c) void {
    setResultText(ip, ds.string[0..@intCast(ds.length)]);
    Tcl_DStringFree(ds);
}

pub fn Tcl_DStringGetResult(ip: *Interp, ds: *DString) callconv(.c) void {
    Tcl_DStringFree(ds);
    dsAppend(ds, text(result(ip)));
    Tcl_ResetResult(ip);
}

pub fn Tcl_DStringStartSublist(ds: *DString) callconv(.c) void {
    const len: usize = @intCast(ds.length);
    dsAppend(ds, if (len == 0 or ds.string[len - 1] == '{') "{" else " {");
}

pub fn Tcl_DStringEndSublist(ds: *DString) callconv(.c) void {
    dsAppend(ds, "}");
}

// ---- Helpers ----
pub fn Tcl_GetVersion(major: ?*c_int, minor: ?*c_int, patch: ?*c_int, kind: ?*c_int) callconv(.c) void {
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

// ---- The debug forms ----
//
// A package built with TCL_MEM_DEBUG calls these forms with its file
// and line. ztcl has no memory debugger, so they make the plain objects.

pub fn Tcl_DbNewObj(_: ?[*:0]const u8, _: c_int) callconv(.c) *Obj {
    return Tcl_NewObj();
}

pub fn Tcl_DbNewBooleanObj(b: c_int, _: ?[*:0]const u8, _: c_int) callconv(.c) *Obj {
    return Tcl_NewBooleanObj(b);
}

pub fn Tcl_DbNewByteArrayObj(bytes: ?[*]const u8, length: c_int, _: ?[*:0]const u8, _: c_int) callconv(.c) *Obj {
    return Tcl_NewByteArrayObj(bytes, length);
}

pub fn Tcl_DbNewDoubleObj(d: f64, _: ?[*:0]const u8, _: c_int) callconv(.c) *Obj {
    return Tcl_NewDoubleObj(d);
}

pub fn Tcl_DbNewLongObj(i: c_long, _: ?[*:0]const u8, _: c_int) callconv(.c) *Obj {
    return Tcl_NewLongObj(i);
}

pub fn Tcl_DbNewWideIntObj(w: i64, _: ?[*:0]const u8, _: c_int) callconv(.c) *Obj {
    return Tcl_NewWideIntObj(w);
}

pub fn Tcl_DbNewStringObj(bytes: ?[*]const u8, length: c_int, _: ?[*:0]const u8, _: c_int) callconv(.c) *Obj {
    return Tcl_NewStringObj(bytes, length);
}

pub fn Tcl_DbNewListObj(objc: c_int, objv: ?[*]const *Obj, _: ?[*:0]const u8, _: c_int) callconv(.c) *Obj {
    return Tcl_NewListObj(objc, objv);
}

// ---- The string forms of the Get slots ----
//
// Each one reads the text through a temporary object, so the rules and
// the error messages are the ones of the object form.

fn withText(s: [*:0]const u8, comptime f: anytype, ip: ?*Interp, out: anytype) c_int {
    const o = Tcl_NewStringObj(s, -1);
    incr(o);
    defer decr(o);
    return f(ip, o, out);
}

pub fn Tcl_GetInt(ip: ?*Interp, s: [*:0]const u8, out: *c_int) callconv(.c) c_int {
    return withText(s, Tcl_GetIntFromObj, ip, out);
}

pub fn Tcl_GetDouble(ip: ?*Interp, s: [*:0]const u8, out: *f64) callconv(.c) c_int {
    return withText(s, Tcl_GetDoubleFromObj, ip, out);
}

pub fn Tcl_GetBoolean(ip: ?*Interp, s: [*:0]const u8, out: *c_int) callconv(.c) c_int {
    return withText(s, Tcl_GetBooleanFromObj, ip, out);
}

/// The table is an array of string pointers that ends with null.
pub fn Tcl_GetIndexFromObj(ip: ?*Interp, o: *Obj, tbl: *const anyopaque, msg: [*:0]const u8, flags: c_int, out: *c_int) callconv(.c) c_int {
    return Tcl_GetIndexFromObjStruct(ip, o, tbl, @sizeOf(?[*:0]const u8), msg, flags, out);
}

// ---- Lengths ----

/// Sets the length of the text form. The new bytes have no set value,
/// as in Tcl, and the internal form is freed.
pub fn Tcl_SetObjLength(o: *Obj, length: c_int) callconv(.c) void {
    if (Tcl_AttemptSetObjLength(o, length) == 0) panicText("out of memory");
}

pub fn Tcl_AttemptSetObjLength(o: *Obj, length: c_int) callconv(.c) c_int {
    const n: usize = @intCast(@max(length, 0));
    const old = text(o);
    const p: [*]u8 = @ptrCast(std.c.malloc(n + 1) orelse return 0);
    const keep = @min(old.len, n);
    @memcpy(p[0..keep], old[0..keep]);
    if (n > keep) @memset(p[keep..n], 0);
    p[n] = 0;
    freeIntRep(o);
    invalidate(o);
    o.bytes = p;
    o.length = @intCast(n);
    return 1;
}

/// Sets the length of a byte array. Tcl leaves the new bytes unset, and
/// here they are 0.
pub fn Tcl_SetByteArrayLength(o: *Obj, length: c_int) callconv(.c) [*]u8 {
    _ = Tcl_GetByteArrayFromObj(o, null);
    const r = byteRep(o);
    const n: usize = @intCast(@max(length, 0));
    const old = r.data.items.len;
    r.data.resize(gpa, n) catch panicText("out of memory");
    if (n > old) @memset(r.data.items[old..n], 0);
    invalidate(o);
    // A byte array of length 0 has a buffer too.
    r.data.ensureTotalCapacity(gpa, 1) catch panicText("out of memory");
    return r.data.items.ptr;
}

pub fn Tcl_AppendStringsToObjVA(o: *Obj, ap: *std.builtin.VaList) callconv(.c) void {
    while (true) {
        const p = @cVaArg(ap, ?[*:0]const u8) orelse break;
        appendText(o, std.mem.span(p));
    }
}

// ---- The registry of types ----
//
// The types of this file are in the registry from the start, and a
// package adds its own types. A lookup by name gives the last type of
// that name. The registry is for the process, as in Tcl.

var types: std.ArrayList(*const ObjType) = .empty;
var types_lock: std.atomic.Mutex = .unlocked;

fn lockTypes() void {
    while (!types_lock.tryLock()) {}
}

fn builtinTypes() [4]*const ObjType {
    return .{ &wide_type, &double_type, &list_type, &bytes_type };
}

pub fn Tcl_RegisterObjType(t: *const ObjType) callconv(.c) void {
    lockTypes();
    defer types_lock.unlock();
    types.append(gpa, t) catch panicText("out of memory");
}

pub fn Tcl_GetObjType(name: [*:0]const u8) callconv(.c) ?*const ObjType {
    const n = std.mem.span(name);
    lockTypes();
    defer types_lock.unlock();
    var i = types.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, std.mem.span(types.items[i].name), n)) return types.items[i];
    }
    for (builtinTypes()) |t| {
        if (std.mem.eql(u8, std.mem.span(t.name), n)) return t;
    }
    return null;
}

/// Appends the name of each type to the list `o`.
pub fn Tcl_AppendAllObjTypes(ip: ?*Interp, o: *Obj) callconv(.c) c_int {
    if (toList(ip, o) == null) return ERROR;
    for (builtinTypes()) |t| _ = Tcl_ListObjAppendElement(ip, o, Tcl_NewStringObj(t.name, -1));
    lockTypes();
    const all = gpa.dupe(*const ObjType, types.items) catch panicText("out of memory");
    types_lock.unlock();
    defer gpa.free(all);
    for (all) |t| _ = Tcl_ListObjAppendElement(ip, o, Tcl_NewStringObj(t.name, -1));
    return OK;
}

/// Gives `o` the internal form of type `t`. The types of this file have
/// no `setFromAnyProc`, so the Get slot of the type makes the form.
pub fn Tcl_ConvertToType(ip: ?*Interp, o: *Obj, t: *const ObjType) callconv(.c) c_int {
    if (o.typePtr == t) return OK;
    if (t == &wide_type) {
        var w: i64 = 0;
        return Tcl_GetWideIntFromObj(ip, o, &w);
    }
    if (t == &double_type) {
        var d: f64 = 0;
        return Tcl_GetDoubleFromObj(ip, o, &d);
    }
    if (t == &list_type) return if (toList(ip, o) != null) OK else ERROR;
    if (t == &bytes_type) {
        _ = Tcl_GetByteArrayFromObj(o, null);
        return OK;
    }
    if (t.set_from_any) |f| return f(ip, o);
    if (ip) |interp| {
        var w: std.ArrayList(u8) = .empty;
        defer w.deinit(gpa);
        w.print(gpa, "can't convert value to type {s}", .{t.name}) catch panicText("out of memory");
        setResultText(interp, w.items);
    }
    return ERROR;
}

// ---- Panic ----

/// The handler of a panic in this file. The tests and the WebAssembly
/// path set it.
pub var panic_hook: ?*const fn ([]const u8) void = null;

pub fn panicText(msg: []const u8) noreturn {
    if (panic_hook) |h| h(msg);
    @panic(msg);
}

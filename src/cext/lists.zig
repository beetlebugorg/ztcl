//! The list text and dict slots of the stubs table of Tcl 8.6. The
//! native path (`stubs.zig`) and the WebAssembly path (`wasm_stubs.zig`)
//! use this one file.
//!
//! The quoting of an element is the quoting of the `list` command of
//! ztcl (`value.appendElement`), and a list text splits with
//! `value.parseList`. A dict is the internal form of the type "dict":
//! the keys and the values in the order of insertion, each with one
//! reference of the dict, and a map from the text of a key to its
//! place. Its text form is the list of the keys and the values. A
//! search holds a copy of the keys and the values, so a change of the
//! dict does not change a search that runs.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const obj = @import("obj.zig");
const value = @import("../value.zig");

const Obj = obj.Obj;
const Interp = obj.Interp;
const OK = obj.OK;
const ERROR = obj.ERROR;
const gpa = std.heap.c_allocator;
const panicText = obj.panicText;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();

const DONT_QUOTE_HASH: c_int = 8;

fn oom() noreturn {
    panicText("out of memory");
}

/// A copy of `s` in memory of Tcl_Alloc, with a 0 at the end.
fn cString(s: []const u8) [*:0]u8 {
    const p: [*]u8 = @ptrCast(std.c.malloc(s.len + 1) orelse oom());
    @memcpy(p[0..s.len], s);
    p[s.len] = 0;
    return @ptrCast(p);
}

fn quoted(out: *std.ArrayList(u8), s: []const u8, first: bool) void {
    value.appendElement(gpa, out, s, first) catch oom();
}

fn span(p: [*]const u8, length: c_int) []const u8 {
    return if (length < 0) std.mem.span(@as([*:0]const u8, @ptrCast(p))) else p[0..@intCast(length)];
}

// ---- List text ----

pub fn Tcl_ScanCountedElement(src: [*]const u8, length: c_int, flags: *c_int) callconv(.c) c_int {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    quoted(&out, span(src, length), true);
    flags.* = 0;
    return @intCast(out.items.len);
}

pub fn Tcl_ScanElement(src: [*:0]const u8, flags: *c_int) callconv(.c) c_int {
    return Tcl_ScanCountedElement(src, -1, flags);
}

pub fn Tcl_ConvertCountedElement(src: [*]const u8, length: c_int, dst: [*]u8, flags: c_int) callconv(.c) c_int {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    quoted(&out, span(src, length), flags & DONT_QUOTE_HASH == 0);
    @memcpy(dst[0..out.items.len], out.items);
    dst[out.items.len] = 0;
    return @intCast(out.items.len);
}

pub fn Tcl_ConvertElement(src: [*:0]const u8, dst: [*]u8, flags: c_int) callconv(.c) c_int {
    return Tcl_ConvertCountedElement(src, -1, dst, flags);
}

pub fn Tcl_Merge(argc: c_int, argv: ?[*]const [*:0]const u8) callconv(.c) [*:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const n: usize = @intCast(@max(argc, 0));
    for (0..n) |i| {
        if (i > 0) out.append(gpa, ' ') catch oom();
        quoted(&out, std.mem.span(argv.?[i]), i == 0);
    }
    return cString(out.items);
}

pub fn Tcl_SplitList(ip: ?*Interp, list: [*:0]const u8, argc: *c_int, argv: *?[*]?[*:0]u8) callconv(.c) c_int {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const s = std.mem.span(list);
    const items = value.parseList(arena.allocator(), s) catch {
        if (ip) |i| obj.setResultText(i, obj.listFaultText(arena.allocator(), s));
        return ERROR;
    };
    // One block: the array of pointers with a null at the end, then the
    // text of each element. Tcl_Free of the array frees it all.
    var size = (items.len + 1) * @sizeOf(?[*:0]u8);
    for (items) |e| size += e.str.len + 1;
    const block: [*]u8 = @ptrCast(std.c.malloc(size) orelse oom());
    const ptrs: [*]?[*:0]u8 = @ptrCast(@alignCast(block));
    var at = (items.len + 1) * @sizeOf(?[*:0]u8);
    for (items, 0..) |e, i| {
        @memcpy(block[at..][0..e.str.len], e.str);
        block[at + e.str.len] = 0;
        ptrs[i] = @ptrCast(block + at);
        at += e.str.len + 1;
    }
    ptrs[items.len] = null;
    argc.* = @intCast(items.len);
    argv.* = ptrs;
    return OK;
}

/// The text of `concat`: each part with no white space at its ends,
/// and one space between two parts that are not empty.
fn concatText(out: *std.ArrayList(u8), part: []const u8) void {
    const t = std.mem.trim(u8, part, " \t\n\r\x0b\x0c");
    if (t.len == 0) return;
    if (out.items.len > 0) out.append(gpa, ' ') catch oom();
    out.appendSlice(gpa, t) catch oom();
}

pub fn Tcl_Concat(argc: c_int, argv: ?[*]const [*:0]const u8) callconv(.c) [*:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..@intCast(@max(argc, 0))) |i| concatText(&out, std.mem.span(argv.?[i]));
    return cString(out.items);
}

pub fn Tcl_ConcatObj(objc: c_int, objv: ?[*]const *Obj) callconv(.c) *Obj {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..@intCast(@max(objc, 0))) |i| concatText(&out, obj.text(objv.?[i]));
    return obj.Tcl_NewStringObj(out.items.ptr, @intCast(out.items.len));
}

// ---- Dicts ----

const DictRep = struct {
    keys: std.ArrayList(*Obj) = .empty,
    vals: std.ArrayList(*Obj) = .empty,
    /// The text of each key (owned) and its place.
    map: std.StringHashMapUnmanaged(usize) = .empty,

    fn put(d: *DictRep, k: *Obj, v: *Obj) void {
        obj.incr(v);
        const t = obj.text(k);
        if (d.map.get(t)) |i| {
            obj.decr(d.vals.items[i]);
            d.vals.items[i] = v;
            return;
        }
        obj.incr(k);
        d.map.put(gpa, gpa.dupe(u8, t) catch oom(), d.keys.items.len) catch oom();
        d.keys.append(gpa, k) catch oom();
        d.vals.append(gpa, v) catch oom();
    }

    fn remove(d: *DictRep, k: []const u8) void {
        const kv = d.map.fetchRemove(k) orelse return;
        gpa.free(kv.key);
        const i = kv.value;
        obj.decr(d.keys.orderedRemove(i));
        obj.decr(d.vals.orderedRemove(i));
        var it = d.map.valueIterator();
        while (it.next()) |p| {
            if (p.* > i) p.* -= 1;
        }
    }

    fn deinit(d: *DictRep) void {
        for (d.keys.items) |k| obj.decr(k);
        for (d.vals.items) |v| obj.decr(v);
        d.keys.deinit(gpa);
        d.vals.deinit(gpa);
        var it = d.map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        d.map.deinit(gpa);
    }
};

fn dictRep(o: *Obj) *DictRep {
    return @ptrCast(@alignCast(o.rep.two.p1.?));
}

fn freeDict(o: *Obj) callconv(.c) void {
    const d = dictRep(o);
    d.deinit();
    gpa.destroy(d);
}

fn dupDict(src: *Obj, dst: *Obj) callconv(.c) void {
    const s = dictRep(src);
    const d = gpa.create(DictRep) catch oom();
    d.* = .{};
    for (s.keys.items, s.vals.items) |k, v| d.put(k, v);
    dst.rep = .{ .two = .{ .p1 = d, .p2 = null } };
    dst.typePtr = &dict_type;
}

fn updateDict(o: *Obj) callconv(.c) void {
    const d = dictRep(o);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (d.keys.items, d.vals.items, 0..) |k, v, i| {
        if (i > 0) out.append(gpa, ' ') catch oom();
        quoted(&out, obj.text(k), i == 0);
        out.append(gpa, ' ') catch oom();
        quoted(&out, obj.text(v), false);
    }
    obj.setText(o, out.items);
}

/// The type of a dict.
pub const dict_type: obj.ObjType = .{ .name = "dict", .free = &freeDict, .dup = &dupDict, .update = &updateDict, .set_from_any = null };

/// The dict form of `o`, made on demand, or null with the message in
/// the result of `ip`.
fn toDict(ip: ?*Interp, o: *Obj) ?*DictRep {
    if (o.typePtr == &dict_type) return dictRep(o);
    const l = obj.toList(null, o) orelse {
        if (ip) |i| {
            // The message of the list parser, with "dict" for "list".
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var t = obj.listFaultText(a, obj.text(o));
            if (std.mem.endsWith(u8, t, " in list")) t = std.mem.concat(a, u8, &.{ t[0 .. t.len - 4], "dict" }) catch oom();
            if (std.mem.startsWith(u8, t, "list ")) t = std.mem.concat(a, u8, &.{ "dict ", t[5..] }) catch oom();
            obj.setResultText(i, t);
        }
        return null;
    };
    const items = l.items.items;
    if (items.len % 2 != 0) {
        if (ip) |i| obj.setResultText(i, "missing value to go with key");
        return null;
    }
    const d = gpa.create(DictRep) catch oom();
    d.* = .{};
    var k: usize = 0;
    while (k < items.len) : (k += 2) d.put(items[k], items[k + 1]);
    obj.shimmer(o, &dict_type, .{ .two = .{ .p1 = d, .p2 = null } });
    return d;
}

fn unshared(o: *Obj, comptime name: []const u8) void {
    if (o.refCount > 1) panicText(name ++ " called with shared object");
}

pub fn Tcl_NewDictObj() callconv(.c) *Obj {
    const o = obj.newObj();
    const d = gpa.create(DictRep) catch oom();
    d.* = .{};
    obj.invalidate(o);
    o.typePtr = &dict_type;
    o.rep = .{ .two = .{ .p1 = d, .p2 = null } };
    return o;
}

pub fn Tcl_DbNewDictObj(_: ?[*:0]const u8, _: c_int) callconv(.c) *Obj {
    return Tcl_NewDictObj();
}

pub fn Tcl_DictObjPut(ip: ?*Interp, o: *Obj, k: *Obj, v: *Obj) callconv(.c) c_int {
    unshared(o, "Tcl_DictObjPut");
    const d = toDict(ip, o) orelse return ERROR;
    d.put(k, v);
    obj.invalidate(o);
    return OK;
}

pub fn Tcl_DictObjGet(ip: ?*Interp, o: *Obj, k: *Obj, out: *?*Obj) callconv(.c) c_int {
    const d = toDict(ip, o) orelse {
        out.* = null;
        return ERROR;
    };
    out.* = if (d.map.get(obj.text(k))) |i| d.vals.items[i] else null;
    return OK;
}

pub fn Tcl_DictObjRemove(ip: ?*Interp, o: *Obj, k: *Obj) callconv(.c) c_int {
    unshared(o, "Tcl_DictObjRemove");
    const d = toDict(ip, o) orelse return ERROR;
    d.remove(obj.text(k));
    obj.invalidate(o);
    return OK;
}

pub fn Tcl_DictObjSize(ip: ?*Interp, o: *Obj, size: *c_int) callconv(.c) c_int {
    const d = toDict(ip, o) orelse return ERROR;
    size.* = @intCast(d.keys.items.len);
    return OK;
}

/// `Tcl_DictSearch`.
pub const Search = extern struct {
    next: ?*anyopaque,
    epoch: c_int,
    dict: ?*anyopaque,
};

/// The keys and the values of a search, then the place of the next one.
const Walk = struct {
    pairs: std.ArrayList(*Obj) = .empty,
    at: usize = 0,
};

fn step(s: *Search, k: ?*?*Obj, v: ?*?*Obj, done: *c_int) void {
    const w: *Walk = @ptrCast(@alignCast(s.next orelse {
        done.* = 1;
        return;
    }));
    if (w.at >= w.pairs.items.len) {
        Tcl_DictObjDone(s);
        done.* = 1;
        return;
    }
    if (k) |p| p.* = w.pairs.items[w.at];
    if (v) |p| p.* = w.pairs.items[w.at + 1];
    w.at += 2;
    done.* = 0;
}

pub fn Tcl_DictObjFirst(ip: ?*Interp, o: *Obj, s: *Search, k: ?*?*Obj, v: ?*?*Obj, done: *c_int) callconv(.c) c_int {
    const d = toDict(ip, o) orelse return ERROR;
    const w = gpa.create(Walk) catch oom();
    w.* = .{};
    for (d.keys.items, d.vals.items) |kk, vv| {
        obj.incr(kk);
        obj.incr(vv);
        w.pairs.appendSlice(gpa, &.{ kk, vv }) catch oom();
    }
    s.* = .{ .next = w, .epoch = 0, .dict = o };
    step(s, k, v, done);
    return OK;
}

pub fn Tcl_DictObjNext(s: *Search, k: ?*?*Obj, v: ?*?*Obj, done: *c_int) callconv(.c) void {
    step(s, k, v, done);
}

pub fn Tcl_DictObjDone(s: *Search) callconv(.c) void {
    const w: *Walk = @ptrCast(@alignCast(s.next orelse return));
    for (w.pairs.items) |o| obj.decr(o);
    w.pairs.deinit(gpa);
    gpa.destroy(w);
    s.next = null;
    s.epoch = -1;
}

/// The dict at `keyv` under `o`, unshared so the caller can change it.
/// With `make`, a key that is not there gets a new dict.
fn path(ip: ?*Interp, o: *Obj, keyv: []const *Obj, make: bool) ?*Obj {
    var cur = o;
    for (keyv) |k| {
        const d = toDict(ip, cur) orelse return null;
        const t = obj.text(k);
        var child: *Obj = undefined;
        if (d.map.get(t)) |i| {
            child = d.vals.items[i];
            if (child.refCount > 1) {
                child = obj.Tcl_DuplicateObj(child);
                d.put(k, child);
            }
        } else {
            if (!make) {
                if (ip) |x| {
                    var out: std.ArrayList(u8) = .empty;
                    defer out.deinit(gpa);
                    out.print(gpa, "key \"{s}\" not known in dictionary", .{t}) catch oom();
                    obj.setResultText(x, out.items);
                }
                return null;
            }
            child = Tcl_NewDictObj();
            d.put(k, child);
        }
        obj.invalidate(cur);
        cur = child;
    }
    return cur;
}

pub fn Tcl_DictObjPutKeyList(ip: ?*Interp, o: *Obj, keyc: c_int, keyv: [*]const *Obj, v: *Obj) callconv(.c) c_int {
    unshared(o, "Tcl_DictObjPutKeyList");
    if (keyc < 1) {
        if (ip) |x| obj.setResultText(x, "missing keys to put");
        return ERROR;
    }
    const n: usize = @intCast(keyc);
    if (toDict(ip, o) == null) return ERROR;
    const last = path(ip, o, keyv[0 .. n - 1], true) orelse return ERROR;
    const d = toDict(ip, last) orelse return ERROR;
    d.put(keyv[n - 1], v);
    obj.invalidate(last);
    obj.invalidate(o);
    return OK;
}

pub fn Tcl_DictObjRemoveKeyList(ip: ?*Interp, o: *Obj, keyc: c_int, keyv: [*]const *Obj) callconv(.c) c_int {
    unshared(o, "Tcl_DictObjRemoveKeyList");
    if (keyc < 1) {
        if (ip) |x| obj.setResultText(x, "missing keys to remove");
        return ERROR;
    }
    const n: usize = @intCast(keyc);
    if (toDict(ip, o) == null) return ERROR;
    const last = path(ip, o, keyv[0 .. n - 1], false) orelse return ERROR;
    const d = toDict(ip, last) orelse return ERROR;
    d.remove(obj.text(keyv[n - 1]));
    obj.invalidate(last);
    obj.invalidate(o);
    return OK;
}

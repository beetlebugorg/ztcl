//! The filesystem slots of the native path that servers such as
//! NaviServer call with paths of the native system: the path functions
//! (`Tcl_FSGetNormalizedPath`, `Tcl_FSSplitPath`, `Tcl_FSJoinPath`,
//! `Tcl_FSGetCwd`), the file functions over the C library (`Tcl_FSStat`,
//! `Tcl_FSAccess`, `Tcl_FSRenameFile`, and others), `Tcl_FSMatchInDirectory`
//! over `glob`, and `Tcl_FSLoadFile` over `dlopen`. They follow the
//! manual page `FileSystem.3` of Tcl 8.6 for the native filesystem of
//! Unix. There are no virtual filesystems.
//!
//! The normalized and the translated path of a path object are in the
//! internal form of the object (the type "path"), so they live as long
//! as the object, as in Tcl. A normalized path is its own normalized
//! path.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const obj = @import("obj.zig");
const host = @import("host.zig");

pub const slots = @This();

const c = std.c;
const gpa = std.heap.c_allocator;
const Interp = obj.Interp;
const Obj = obj.Obj;
const panicText = obj.panicText;
const OK: c_int = 0;
const ERROR: c_int = 1;

const mac = builtin.os.tag.isDarwin();
extern "c" fn lstat(path: [*:0]const u8, buf: *anyopaque) c_int;
extern "c" fn @"lstat$INODE64"(path: [*:0]const u8, buf: *anyopaque) c_int;
extern "c" fn stat(path: [*:0]const u8, buf: *anyopaque) c_int;
extern "c" fn @"stat$INODE64"(path: [*:0]const u8, buf: *anyopaque) c_int;
const inode64 = mac and builtin.cpu.arch == .x86_64;
const lstatC = if (inode64) @"lstat$INODE64" else lstat;
const statC = if (inode64) @"stat$INODE64" else stat;

fn span(o: *Obj) [:0]const u8 {
    const p = obj.Tcl_GetString(o);
    return std.mem.span(p);
}

/// The type of a path object: p1 is the normalized path, p2 the text
/// of `Tcl_FSGetTranslatedStringPath`, each an object or null.
const path_type: obj.ObjType = .{ .name = "path", .free = &freePath, .dup = &dupPath, .update = null, .set_from_any = null };

fn freePath(o: *Obj) callconv(.c) void {
    if (o.rep.two.p1) |p| if (p != @as(*anyopaque, o)) obj.decr(@ptrCast(@alignCast(p)));
    if (o.rep.two.p2) |p| obj.decr(@ptrCast(@alignCast(p)));
    o.rep.two = .{ .p1 = null, .p2 = null };
}

fn dupPath(src: *Obj, dst: *Obj) callconv(.c) void {
    dst.rep.two = src.rep.two;
    if (dst.rep.two.p1) |p| {
        if (p == @as(*anyopaque, src)) dst.rep.two.p1 = dst else obj.incr(@ptrCast(@alignCast(p)));
    }
    if (dst.rep.two.p2) |p| obj.incr(@ptrCast(@alignCast(p)));
    dst.typePtr = &path_type;
}

/// Gives `o` the path type, with its text kept.
fn asPath(o: *Obj) void {
    if (o.typePtr == &path_type) return;
    _ = obj.Tcl_GetString(o);
    obj.freeIntRep(o);
    o.rep.two = .{ .p1 = null, .p2 = null };
    o.typePtr = &path_type;
}

/// The path with `~` and `~/...` in the home folder.
fn tilde(a: std.mem.Allocator, p: []const u8) ![]u8 {
    if (p.len == 0 or p[0] != '~' or (p.len > 1 and p[1] != '/')) return a.dupe(u8, p);
    const home = std.mem.span(c.getenv("HOME") orelse return a.dupe(u8, p));
    return std.mem.concat(a, u8, &.{ home, p[1..] });
}

/// The absolute path with no `.`, `..`, or double `/`. The folder part
/// has its symbolic links resolved when it exists, as in Tcl.
fn normalize(a: std.mem.Allocator, p0: []const u8) ![]u8 {
    const p = try tilde(a, p0);
    var full: std.ArrayList(u8) = .empty;
    if (p.len == 0 or p[0] != '/') {
        var buf: [4096]u8 = undefined;
        const cwd = c.getcwd(&buf, buf.len) orelse return error.NoCwd;
        try full.appendSlice(a, std.mem.span(@as([*:0]u8, @ptrCast(cwd))));
        try full.append(a, '/');
    }
    try full.appendSlice(a, p);
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, full.items, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(a, part);
    }
    var out: std.ArrayList(u8) = .empty;
    for (parts.items) |part| {
        try out.append(a, '/');
        try out.appendSlice(a, part);
    }
    if (out.items.len == 0) try out.append(a, '/');
    // The folder with its links resolved.
    const cut = std.mem.lastIndexOfScalar(u8, out.items, '/').?;
    if (cut > 0) {
        const dir = try a.dupeSentinel(u8, out.items[0..cut], 0);
        var rb: [4096]u8 = undefined;
        if (c.realpath(dir.ptr, &rb)) |r| {
            const real = std.mem.span(@as([*:0]u8, @ptrCast(r)));
            var res: std.ArrayList(u8) = .empty;
            try res.appendSlice(a, real);
            if (!std.mem.eql(u8, real, "/")) try res.append(a, '/');
            try res.appendSlice(a, out.items[cut + 1 ..]);
            return res.items;
        }
    }
    return out.items;
}

fn newText(s: []const u8) *Obj {
    return obj.Tcl_NewStringObj(s.ptr, @intCast(s.len));
}

/// The normalized path. The object of `path` holds it.
pub fn Tcl_FSGetNormalizedPath(_: ?*Interp, path: *Obj) callconv(.c) ?*Obj {
    asPath(path);
    if (path.rep.two.p1) |p| return @ptrCast(@alignCast(p));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const n = normalize(arena.allocator(), span(path)) catch return null;
    // A path that is normalized is its own normalized path, as in Tcl,
    // so its text stays when the object changes type.
    if (std.mem.eql(u8, n, span(path))) {
        path.rep.two.p1 = path;
        return path;
    }
    const o = newText(n);
    obj.incr(o);
    path.rep.two.p1 = o;
    return o;
}

/// The path with `~` replaced, as `Tcl_FSGetTranslatedPath` gives it,
/// in a new object with a count of 1. The object of `path` keeps one too.
pub fn Tcl_FSGetTranslatedPath(_: ?*Interp, path: *Obj) callconv(.c) ?*Obj {
    asPath(path);
    const o: *Obj = if (path.rep.two.p2) |p| @ptrCast(@alignCast(p)) else blk: {
        const t = tilde(gpa, span(path)) catch return null;
        defer gpa.free(t);
        const n = newText(t);
        obj.incr(n);
        path.rep.two.p2 = n;
        break :blk n;
    };
    obj.incr(o);
    return o;
}

/// The translated path as C text. The manual page says the caller owns
/// the text and frees it with `ckfree` (`Tcl_Free`, the C library here).
pub fn Tcl_FSGetTranslatedStringPath(ip: ?*Interp, path: *Obj) callconv(.c) ?[*:0]u8 {
    const o = Tcl_FSGetTranslatedPath(ip, path) orelse return null;
    defer obj.decr(o);
    const s = span(o);
    const p: [*]u8 = @ptrCast(c.malloc(s.len + 1) orelse return null);
    @memcpy(p[0..s.len], s);
    p[s.len] = 0;
    return @ptrCast(p);
}

/// The text of the translated path, kept by the object of `path`.
fn native(path: *Obj) ?[*:0]const u8 {
    const o = Tcl_FSGetTranslatedPath(null, path) orelse return null;
    obj.decr(o);
    return obj.Tcl_GetString(o);
}

/// The parts of the path, as `file split` gives them, in a new list.
pub fn Tcl_FSSplitPath(path: *Obj, len: ?*c_int) callconv(.c) *Obj {
    const s = span(path);
    const l = obj.Tcl_NewListObj(0, null);
    var n: c_int = 0;
    if (s.len > 0 and s[0] == '/') {
        _ = obj.Tcl_ListObjAppendElement(null, l, newText("/"));
        n += 1;
    }
    var it = std.mem.tokenizeScalar(u8, s, '/');
    var first = n == 0;
    while (it.next()) |part| {
        // A part after the first that starts with ~ gets ./ before it.
        if (!first and part[0] == '~') {
            const t = std.mem.concat(gpa, u8, &.{ "./", part }) catch panicText("out of memory");
            defer gpa.free(t);
            _ = obj.Tcl_ListObjAppendElement(null, l, newText(t));
        } else _ = obj.Tcl_ListObjAppendElement(null, l, newText(part));
        first = false;
        n += 1;
    }
    if (len) |p| p.* = n;
    return l;
}

/// Joins the first `n` elements of the list (all of them when `n` is
/// below 0), as `file join` does.
pub fn Tcl_FSJoinPath(list: *Obj, n: c_int) callconv(.c) ?*Obj {
    var count: c_int = 0;
    var elems: [*]*Obj = undefined;
    if (obj.Tcl_ListObjGetElements(null, list, &count, &elems) != OK) return null;
    const k: usize = @intCast(if (n < 0 or n > count) count else n);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (elems[0..k]) |e| {
        const s = span(e);
        if (s.len == 0) continue;
        // An absolute element starts the path again.
        if (s[0] == '/' or s[0] == '~') out.clearRetainingCapacity();
        if (out.items.len != 0 and out.items[out.items.len - 1] != '/') out.append(gpa, '/') catch panicText("out of memory");
        out.appendSlice(gpa, s) catch panicText("out of memory");
    }
    while (out.items.len > 1 and out.items[out.items.len - 1] == '/') _ = out.pop();
    return newText(out.items);
}

/// The current folder, in a new object with a count of 1.
pub fn Tcl_FSGetCwd(ip: ?*Interp) callconv(.c) ?*Obj {
    var buf: [4096]u8 = undefined;
    const cwd = c.getcwd(&buf, buf.len) orelse {
        if (ip) |i| obj.setResultText(i, "error getting working directory name");
        return null;
    };
    const o = newText(std.mem.span(@as([*:0]u8, @ptrCast(cwd))));
    obj.incr(o);
    return o;
}

pub fn Tcl_FSChdir(path: *Obj) callconv(.c) c_int {
    return c.chdir(native(path) orelse return -1);
}

pub fn Tcl_FSStat(path: *Obj, buf: *anyopaque) callconv(.c) c_int {
    return statC(native(path) orelse return -1, buf);
}

pub fn Tcl_FSLstat(path: *Obj, buf: *anyopaque) callconv(.c) c_int {
    return lstatC(native(path) orelse return -1, buf);
}

pub fn Tcl_Stat(path: [*:0]const u8, buf: *anyopaque) callconv(.c) c_int {
    return statC(path, buf);
}

pub fn Tcl_AllocStatBuf() callconv(.c) ?*anyopaque {
    return c.malloc(@sizeOf(c.Stat));
}

pub fn Tcl_FSAccess(path: *Obj, mode: c_int) callconv(.c) c_int {
    return c.access(native(path) orelse return -1, @intCast(mode));
}

pub fn Tcl_Access(path: [*:0]const u8, mode: c_int) callconv(.c) c_int {
    return c.access(path, @intCast(mode));
}

pub fn Tcl_FSCreateDirectory(path: *Obj) callconv(.c) c_int {
    return c.mkdir(native(path) orelse return -1, 0o777);
}

pub fn Tcl_FSRemoveDirectory(path: *Obj, recursive: c_int, err: ?*?*Obj) callconv(.c) c_int {
    _ = recursive;
    const p = native(path) orelse return -1;
    const r = c.rmdir(p);
    if (r != 0) if (err) |e| {
        e.* = newText(std.mem.span(p));
        obj.incr(e.*.?);
    };
    return r;
}

pub fn Tcl_FSDeleteFile(path: *Obj) callconv(.c) c_int {
    return c.unlink(native(path) orelse return -1);
}

pub fn Tcl_FSRenameFile(src: *Obj, dst: *Obj) callconv(.c) c_int {
    const s = native(src) orelse return -1;
    const d = native(dst) orelse return -1;
    return c.rename(s, d);
}

pub fn Tcl_FSEvalFile(ip: *Interp, path: *Obj) callconv(.c) c_int {
    return host.Tcl_EvalFile(ip, obj.Tcl_GetString(path));
}

pub fn Tcl_FSEvalFileEx(ip: *Interp, path: *Obj, _: ?[*:0]const u8) callconv(.c) c_int {
    return host.Tcl_EvalFile(ip, obj.Tcl_GetString(path));
}

/// `Tcl_GlobTypeData` of tcl.h.
const GlobTypes = extern struct { type: c_int, perm: c_int, mac_type: ?*Obj, mac_creator: ?*Obj };

/// The letters of `glob -types` for the bits of `Tcl_GlobTypeData`.
fn typeWords(out: *std.ArrayList(u8), t: *const GlobTypes) void {
    const types = [_]struct { c_int, []const u8 }{ .{ 1, "b" }, .{ 2, "c" }, .{ 4, "d" }, .{ 8, "p" }, .{ 16, "f" }, .{ 32, "l" }, .{ 64, "s" } };
    const perms = [_]struct { c_int, []const u8 }{ .{ 1, "readonly" }, .{ 2, "hidden" }, .{ 4, "r" }, .{ 8, "w" }, .{ 16, "x" } };
    for (types) |p| if (t.type & p[0] != 0) {
        out.appendSlice(gpa, p[1]) catch panicText("out of memory");
        out.append(gpa, ' ') catch panicText("out of memory");
    };
    for (perms) |p| if (t.perm & p[0] != 0) {
        out.appendSlice(gpa, p[1]) catch panicText("out of memory");
        out.append(gpa, ' ') catch panicText("out of memory");
    };
}

/// Appends to `result` the files of the folder `path` that match
/// `pattern` and `types`. With no pattern, `path` itself is tested.
pub fn Tcl_FSMatchInDirectory(ip: *Interp, result: *Obj, path: *Obj, pattern: ?[*:0]const u8, types: ?*const GlobTypes) callconv(.c) c_int {
    var argv: [8]*Obj = undefined;
    var k: usize = 0;
    argv[k] = newText("glob");
    argv[k + 1] = newText("-nocomplain");
    k += 2;
    if (types) |t| {
        var tw: std.ArrayList(u8) = .empty;
        defer tw.deinit(gpa);
        typeWords(&tw, t);
        argv[k] = newText("-types");
        argv[k + 1] = newText(tw.items);
        k += 2;
    }
    argv[k] = newText("-directory");
    if (pattern) |p| {
        argv[k + 1] = path;
        argv[k + 3] = newText(std.mem.span(p));
    } else {
        // The folder and the escaped name of the path.
        const s = span(path);
        const cut = std.mem.lastIndexOfScalar(u8, s, '/');
        argv[k + 1] = if (cut) |i| newText(if (i == 0) "/" else s[0..i]) else newText(".");
        var esc: std.ArrayList(u8) = .empty;
        defer esc.deinit(gpa);
        for (s[if (cut) |i| i + 1 else 0..]) |ch| {
            if (std.mem.indexOfScalar(u8, "*?[]{}\\", ch) != null) esc.append(gpa, '\\') catch panicText("out of memory");
            esc.append(gpa, ch) catch panicText("out of memory");
        }
        argv[k + 3] = newText(esc.items);
    }
    argv[k + 2] = newText("--");
    k += 4;
    for (argv[0..k]) |w| obj.incr(w);
    defer for (argv[0..k]) |w| obj.decr(w);
    if (host.Tcl_EvalObjv(ip, @intCast(k), &argv, 0) != OK) return ERROR;
    const found = obj.result(ip);
    obj.incr(found);
    defer obj.decr(found);
    var count: c_int = 0;
    var elems: [*]*Obj = undefined;
    if (obj.Tcl_ListObjGetElements(ip, found, &count, &elems) != OK) return ERROR;
    for (elems[0..@intCast(count)]) |e| {
        if (pattern == null) {
            _ = obj.Tcl_ListObjAppendElement(ip, result, path);
        } else _ = obj.Tcl_ListObjAppendElement(ip, result, e);
    }
    obj.Tcl_ResetResult(ip);
    return OK;
}

pub const UnloadProc = *const fn (?*anyopaque) callconv(.c) void;

fn unload(handle: ?*anyopaque) callconv(.c) void {
    if (handle) |h| _ = c.dlclose(h);
}

/// Loads a shared library and finds two symbols in it.
pub fn Tcl_FSLoadFile(ip: ?*Interp, path: *Obj, sym1: ?[*:0]const u8, sym2: ?[*:0]const u8, p1: ?*?*anyopaque, p2: ?*?*anyopaque, handle: *?*anyopaque, unload_proc: ?*?UnloadProc) callconv(.c) c_int {
    const p = native(path) orelse return ERROR;
    const h = c.dlopen(p, .{ .NOW = true }) orelse {
        if (ip) |i| {
            const msg = std.fmt.allocPrint(gpa, "couldn't load file \"{s}\": {s}", .{ span(path), if (c.dlerror()) |e| std.mem.span(e) else "unknown error" }) catch panicText("out of memory");
            defer gpa.free(msg);
            obj.setResultText(i, msg);
        }
        return ERROR;
    };
    if (p1) |q| q.* = if (sym1) |s| c.dlsym(h, s) else null;
    if (p2) |q| q.* = if (sym2) |s| c.dlsym(h, s) else null;
    handle.* = h;
    if (unload_proc) |u| u.* = &unload;
    return OK;
}

test "normalize" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/", try normalize(a, "/"));
    try std.testing.expectEqualStrings("/", try normalize(a, "/.."));
    try std.testing.expectEqualStrings("/nosuch/b", try normalize(a, "/nosuch/./a/../b"));
}

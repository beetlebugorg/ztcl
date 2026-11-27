//! The encoding slots of the stubs table of Tcl 8.6. The native path
//! (`stubs.zig`) and the WebAssembly path (`wasm_stubs.zig`) use this
//! one file.
//!
//! The built-in encodings are the ones with no table: `utf-8`,
//! `iso8859-1`, `ascii`, `identity`, and `unicode` (UTF-16 in the byte
//! order of the host). A package can
//! add an encoding with Tcl_CreateEncoding: its two procs convert the
//! text, and a later encoding of the same name hides the earlier one.
//! The encodings of a package are in the list of this file, so the
//! `encoding` command of ztcl does not see them. A `Tcl_Encoding` is the
//! address of an `Enc`.
//!
//! A conversion reads one character of the source at a time and stops
//! when the next character does not fit in the destination
//! (TCL_CONVERT_NOSPACE), or when the source ends in the middle of a
//! character and TCL_ENCODING_END is not set (TCL_CONVERT_MULTIBYTE).
//! Without TCL_ENCODING_STOPONERROR, a byte that does not start a
//! character of UTF-8 is the character of the same value, and a
//! character that an external encoding does not have is `?`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const obj = @import("obj.zig");

const Obj = obj.Obj;
const Interp = obj.Interp;
const DString = obj.DString;
const OK = obj.OK;
const ERROR = obj.ERROR;
const gpa = std.heap.c_allocator;
const panicText = obj.panicText;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();

const START: c_int = 0x01;
const END: c_int = 0x02;
const STOPONERROR: c_int = 0x04;
const NO_TERMINATE: c_int = 0x08;
const CHAR_LIMIT: c_int = 0x10;
const MULTIBYTE: c_int = -1;
const SYNTAX: c_int = -2;
const UNKNOWN: c_int = -3;
const NOSPACE: c_int = -4;
/// `TCL_UTF_MAX` of `tcl.h`.
const utf_max = 3;

pub const ConvertProc = *const fn (?*anyopaque, [*]const u8, c_int, c_int, ?*?*anyopaque, [*]u8, c_int, ?*c_int, ?*c_int, ?*c_int) callconv(.c) c_int;
pub const FreeProc = *const fn (?*anyopaque) callconv(.c) void;

/// `Tcl_EncodingType`.
pub const EncodingType = extern struct {
    name: ?[*:0]const u8,
    to_utf: ?ConvertProc,
    from_utf: ?ConvertProc,
    free: ?FreeProc,
    client_data: ?*anyopaque,
    null_size: c_int,
};

const Kind = enum { utf8, latin1, ascii, identity, unicode, package };

const Enc = struct {
    name: [:0]const u8,
    kind: Kind,
    /// The type of an encoding of a package.
    type: EncodingType = undefined,
    refs: usize = 1,
};

var utf8: Enc = .{ .name = "utf-8", .kind = .utf8 };
var latin1: Enc = .{ .name = "iso8859-1", .kind = .latin1 };
var ascii: Enc = .{ .name = "ascii", .kind = .ascii };
var identity: Enc = .{ .name = "identity", .kind = .identity };
var unicode: Enc = .{ .name = "unicode", .kind = .unicode };
const builtins = [_]*Enc{ &ascii, &identity, &latin1, &unicode, &utf8 };

var made: std.ArrayList(*Enc) = .empty;
var lock: std.atomic.Mutex = .unlocked;
var system: *Enc = &utf8;
var default_dir: ?[:0]u8 = null;
var search_path: ?*Obj = null;

fn lockAll() void {
    while (!lock.tryLock()) {}
}

fn find(name: []const u8) ?*Enc {
    lockAll();
    defer lock.unlock();
    var i = made.items.len;
    while (i > 0) {
        i -= 1;
        const e = made.items[i];
        if (std.mem.eql(u8, e.name, name)) {
            e.refs += 1;
            return e;
        }
    }
    for (builtins) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

fn encOf(h: ?*anyopaque) *Enc {
    return if (h) |p| @ptrCast(@alignCast(p)) else system;
}

pub fn Tcl_GetEncoding(ip: ?*Interp, name: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const n = if (name) |p| std.mem.span(p) else return system;
    if (find(n)) |e| return e;
    if (ip) |i| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        out.print(gpa, "unknown encoding \"{s}\"", .{n}) catch panicText("out of memory");
        obj.setResultText(i, out.items);
    }
    return null;
}

pub fn Tcl_FreeEncoding(h: ?*anyopaque) callconv(.c) void {
    const e: *Enc = @ptrCast(@alignCast(h orelse return));
    if (e.kind != .package) return;
    lockAll();
    e.refs -= 1;
    const last = e.refs == 0;
    if (last) {
        if (std.mem.indexOfScalar(*Enc, made.items, e)) |k| _ = made.orderedRemove(k);
    }
    lock.unlock();
    if (!last) return;
    if (e.type.free) |f| f(e.type.client_data);
    gpa.free(e.name);
    gpa.destroy(e);
}

pub fn Tcl_GetEncodingName(h: ?*anyopaque) callconv(.c) [*:0]const u8 {
    return encOf(h).name.ptr;
}

pub fn Tcl_GetEncodingNames(ip: *Interp) callconv(.c) void {
    const l = obj.Tcl_NewListObj(0, null);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (builtins) |e| names.append(gpa, e.name) catch panicText("out of memory");
    lockAll();
    for (made.items) |e| {
        for (names.items) |n| {
            if (std.mem.eql(u8, n, e.name)) break;
        } else names.append(gpa, e.name) catch panicText("out of memory");
    }
    for (names.items) |n| _ = obj.Tcl_ListObjAppendElement(null, l, obj.Tcl_NewStringObj(n.ptr, @intCast(n.len)));
    lock.unlock();
    obj.Tcl_SetObjResult(ip, l);
}

pub fn Tcl_GetEncodingFromObj(ip: ?*Interp, o: *Obj, out: *?*anyopaque) callconv(.c) c_int {
    const t = obj.text(o);
    const z = gpa.dupeSentinel(u8, t, 0) catch panicText("out of memory");
    defer gpa.free(z);
    out.* = Tcl_GetEncoding(ip, z.ptr) orelse return ERROR;
    return OK;
}

pub fn Tcl_SetSystemEncoding(ip: ?*Interp, name: ?[*:0]const u8) callconv(.c) c_int {
    const n = name orelse {
        system = &utf8;
        return OK;
    };
    if (n[0] == 0) {
        system = &utf8;
        return OK;
    }
    const h = Tcl_GetEncoding(ip, n) orelse return ERROR;
    const old = system;
    system = @ptrCast(@alignCast(h));
    Tcl_FreeEncoding(old);
    return OK;
}

pub fn Tcl_CreateEncoding(t: *const EncodingType) callconv(.c) ?*anyopaque {
    const e = gpa.create(Enc) catch panicText("out of memory");
    e.* = .{ .name = gpa.dupeSentinel(u8, std.mem.span(t.name orelse ""), 0) catch panicText("out of memory"), .kind = .package, .type = t.* };
    lockAll();
    defer lock.unlock();
    // The reference is the one of the caller. The encoding leaves the
    // list when its last reference goes.
    made.append(gpa, e) catch panicText("out of memory");
    return e;
}

pub fn Tcl_GetEncodingNameFromEnvironment(ds: *DString) callconv(.c) [*:0]const u8 {
    obj.Tcl_DStringInit(ds);
    obj.dsAppend(ds, "utf-8");
    return @ptrCast(ds.string);
}

pub fn Tcl_GetDefaultEncodingDir() callconv(.c) ?[*:0]const u8 {
    return if (default_dir) |d| d.ptr else null;
}

pub fn Tcl_SetDefaultEncodingDir(path: ?[*:0]const u8) callconv(.c) void {
    if (default_dir) |d| gpa.free(d);
    default_dir = if (path) |p| gpa.dupeSentinel(u8, std.mem.span(p), 0) catch panicText("out of memory") else null;
}

pub fn Tcl_GetEncodingSearchPath() callconv(.c) *Obj {
    if (search_path == null) {
        search_path = obj.Tcl_NewListObj(0, null);
        obj.incr(search_path.?);
    }
    return search_path.?;
}

pub fn Tcl_SetEncodingSearchPath(path: *Obj) callconv(.c) c_int {
    if (obj.toList(null, path) == null) return ERROR;
    obj.incr(path);
    if (search_path) |old| obj.decr(old);
    search_path = path;
    return OK;
}

// ---- Conversions ----

const Got = struct { rc: c_int = OK, read: usize = 0, wrote: usize = 0, chars: usize = 0 };

/// The byte count of the UTF-8 sequence of lead byte `c`, or 0 for a
/// byte that does not start one.
fn seqLen(c: u8) usize {
    return if (c < 0x80) 1 else if (c >= 0xC0 and c < 0xE0) 2 else if (c >= 0xE0 and c < 0xF0) 3 else if (c >= 0xF0 and c < 0xF5) 4 else 0;
}

/// The length of the whole sequence at the start of `s`, 0 when it is
/// not one, or null when `s` ends inside it.
fn whole(s: []const u8) ?usize {
    const n = seqLen(s[0]);
    if (n <= 1) return n;
    for (1..n) |k| {
        if (k >= s.len) return null;
        if (s[k] & 0xC0 != 0x80) return 0;
    }
    return n;
}

fn putCp(buf: *[4]u8, cp: u21) usize {
    if (cp == 0) {
        buf[0] = 0xC0;
        buf[1] = 0x80;
        return 2;
    }
    return std.unicode.utf8Encode(cp, buf) catch blk: {
        // A surrogate: the three bytes of its value.
        buf[0] = @intCast(0xE0 | (cp >> 12));
        buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (cp & 0x3F));
        break :blk 3;
    };
}

fn decodeCp(s: []const u8, n: usize) u21 {
    if (n == 1) return s[0];
    var cp: u21 = s[0] & (@as(u8, 0x7F) >> @intCast(n));
    for (s[1..n]) |b| cp = (cp << 6) | (b & 0x3F);
    return cp;
}

/// External bytes `src` to UTF-8 in `dst`.
fn toUtf(e: *Enc, src: []const u8, flags: c_int, dst: []u8, max_chars: usize) Got {
    var g: Got = .{};
    const end = flags & END != 0;
    while (g.read < src.len and g.chars < max_chars) {
        var buf: [4]u8 = undefined;
        var out: []const u8 = undefined;
        var used: usize = 1;
        const rest = src[g.read..];
        switch (e.kind) {
            .identity => out = rest[0..1],
            .latin1 => out = buf[0..putCp(&buf, rest[0])],
            .ascii => {
                if (rest[0] >= 0x80 and flags & STOPONERROR != 0) {
                    g.rc = SYNTAX;
                    break;
                }
                out = buf[0..putCp(&buf, if (rest[0] < 0x80) rest[0] else '?')];
            },
            .utf8 => {
                const n0 = whole(rest);
                if (n0 == null and !end) {
                    g.rc = MULTIBYTE;
                    break;
                }
                const n = n0 orelse 0;
                if (n == 0) {
                    if (flags & STOPONERROR != 0) {
                        g.rc = SYNTAX;
                        break;
                    }
                    out = buf[0..putCp(&buf, rest[0])];
                } else if (n == 1 and rest[0] == 0) {
                    out = buf[0..putCp(&buf, 0)];
                } else {
                    out = rest[0..n];
                    used = n;
                }
            },
            .unicode => {
                if (rest.len < 2) {
                    if (!end) g.rc = MULTIBYTE;
                    if (!end) break;
                    g.read += 1;
                    break;
                }
                var cp: u21 = std.mem.readInt(u16, rest[0..2], builtin.cpu.arch.endian());
                used = 2;
                if (cp >= 0xD800 and cp < 0xDC00 and rest.len >= 4) {
                    const lo = std.mem.readInt(u16, rest[2..4], builtin.cpu.arch.endian());
                    if (lo >= 0xDC00 and lo < 0xE000) {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        used = 4;
                    }
                }
                out = buf[0..putCp(&buf, cp)];
            },
            .package => unreachable,
        }
        // As in Tcl, a character goes in only while the free space is
        // at least TCL_UTF_MAX bytes.
        if (g.wrote + utf_max > dst.len) {
            g.rc = NOSPACE;
            break;
        }
        @memcpy(dst[g.wrote..][0..out.len], out);
        g.wrote += out.len;
        g.read += used;
        g.chars += 1;
    }
    return g;
}

/// UTF-8 text `src` to external bytes in `dst`.
fn fromUtf(e: *Enc, src: []const u8, flags: c_int, dst: []u8) Got {
    var g: Got = .{};
    const end = flags & END != 0;
    while (g.read < src.len) {
        const rest = src[g.read..];
        var used: usize = 1;
        var cp: u21 = rest[0];
        if (e.kind != .identity) {
            const n0 = whole(rest);
            if (n0 == null and !end) {
                g.rc = MULTIBYTE;
                break;
            }
            const n = n0 orelse 1;
            if (n > 1) {
                cp = decodeCp(rest, n);
                used = n;
            }
        }
        var buf: [4]u8 = undefined;
        var out: []const u8 = undefined;
        switch (e.kind) {
            .identity => out = rest[0..1],
            .utf8 => out = if (cp == 0) buf[0..1] else rest[0..used],
            .latin1, .ascii => {
                const top: u21 = if (e.kind == .latin1) 0xFF else 0x7F;
                if (cp > top) {
                    if (flags & STOPONERROR != 0) {
                        g.rc = UNKNOWN;
                        break;
                    }
                    cp = '?';
                }
                buf[0] = @intCast(cp);
                out = buf[0..1];
            },
            .unicode => {
                const en = builtin.cpu.arch.endian();
                if (cp > 0xFFFF) {
                    const v = cp - 0x10000;
                    std.mem.writeInt(u16, buf[0..2], @intCast(0xD800 + (v >> 10)), en);
                    std.mem.writeInt(u16, buf[2..4], @intCast(0xDC00 + (v & 0x3FF)), en);
                    out = buf[0..4];
                } else {
                    std.mem.writeInt(u16, buf[0..2], @intCast(cp), en);
                    out = buf[0..2];
                }
            },
            .package => unreachable,
        }
        if (cp == 0 and e.kind == .utf8) buf[0] = 0;
        // UTF-8 needs TCL_UTF_MAX bytes of free space for a character,
        // and the other encodings need the bytes of the character.
        const need = if (e.kind == .utf8) @max(out.len, utf_max) else out.len;
        if (g.wrote + need > dst.len) {
            g.rc = NOSPACE;
            break;
        }
        @memcpy(dst[g.wrote..][0..out.len], out);
        g.wrote += out.len;
        g.read += used;
        g.chars += 1;
    }
    return g;
}

fn nullSize(e: *Enc) usize {
    return switch (e.kind) {
        .unicode => 2,
        .package => @intCast(@max(e.type.null_size, 1)),
        else => 1,
    };
}

/// The byte count of external text that ends with `size` zero bytes.
fn externalLen(src: [*]const u8, size: usize) usize {
    var n: usize = 0;
    while (true) : (n += size) {
        if (std.mem.allEqual(u8, src[n..][0..size], 0)) return n;
    }
}

fn convert(ip: ?*Interp, h: ?*anyopaque, to: bool, src0: ?[*]const u8, len: c_int, flags0: c_int, state: ?*?*anyopaque, dst: [*]u8, dst_len: c_int, read: ?*c_int, wrote: ?*c_int, chars: ?*c_int) c_int {
    _ = ip;
    const e = encOf(h);
    var flags = flags0;
    if (state == null) flags |= START | END;
    const src: [*]const u8 = src0 orelse "";
    const n: usize = if (src0 == null) 0 else if (len >= 0) @intCast(len) else if (to) externalLen(src, nullSize(e)) else std.mem.len(@as([*:0]const u8, @ptrCast(src)));
    const term: usize = if (flags & NO_TERMINATE != 0) 0 else if (to) 1 else nullSize(e);
    const room: usize = @intCast(@max(dst_len, 0));
    const space = room -| term;
    const max_chars: usize = if (flags & CHAR_LIMIT != 0 and chars != null) @intCast(@max(chars.?.*, 0)) else std.math.maxInt(usize);
    if (e.kind == .package) {
        const p = (if (to) e.type.to_utf else e.type.from_utf) orelse return OK;
        var r: c_int = 0;
        var w: c_int = 0;
        var c: c_int = 0;
        var st: ?*anyopaque = null;
        const rc = p(e.type.client_data, src, @intCast(n), flags, state orelse &st, dst, @intCast(space), &r, &w, &c);
        if (term > 0 and room >= term) @memset(dst[@intCast(w)..][0..term], 0);
        if (read) |x| x.* = r;
        if (wrote) |x| x.* = w;
        if (chars) |x| x.* = c;
        return rc;
    }
    const g = if (to) toUtf(e, src[0..n], flags, dst[0..space], max_chars) else fromUtf(e, src[0..n], flags, dst[0..space]);
    if (term > 0 and room >= term) @memset(dst[g.wrote..][0..term], 0);
    if (read) |x| x.* = @intCast(g.read);
    if (wrote) |x| x.* = @intCast(g.wrote);
    if (chars) |x| x.* = @intCast(g.chars);
    return g.rc;
}

pub fn Tcl_ExternalToUtf(ip: ?*Interp, h: ?*anyopaque, src: ?[*]const u8, len: c_int, flags: c_int, state: ?*?*anyopaque, dst: [*]u8, dst_len: c_int, read: ?*c_int, wrote: ?*c_int, chars: ?*c_int) callconv(.c) c_int {
    return convert(ip, h, true, src, len, flags, state, dst, dst_len, read, wrote, chars);
}

pub fn Tcl_UtfToExternal(ip: ?*Interp, h: ?*anyopaque, src: ?[*]const u8, len: c_int, flags: c_int, state: ?*?*anyopaque, dst: [*]u8, dst_len: c_int, read: ?*c_int, wrote: ?*c_int, chars: ?*c_int) callconv(.c) c_int {
    return convert(ip, h, false, src, len, flags, state, dst, dst_len, read, wrote, chars);
}

/// The whole conversion of `src` into `ds`, in steps of the free space
/// of the DString.
fn convertAll(h: ?*anyopaque, to: bool, src0: ?[*]const u8, len: c_int, ds: *DString) [*:0]u8 {
    obj.Tcl_DStringInit(ds);
    const e = encOf(h);
    const src: [*]const u8 = src0 orelse "";
    var n: usize = if (src0 == null) 0 else if (len >= 0) @intCast(len) else if (to) externalLen(src, nullSize(e)) else std.mem.len(@as([*:0]const u8, @ptrCast(src)));
    var at: usize = 0;
    var state: ?*anyopaque = null;
    var flags: c_int = START | END;
    while (true) {
        const free: usize = @as(usize, @intCast(ds.space)) - @as(usize, @intCast(ds.length));
        var r: c_int = 0;
        var w: c_int = 0;
        const rc = convert(null, h, to, src + at, @intCast(n), flags, &state, ds.string + @as(usize, @intCast(ds.length)), @intCast(free), &r, &w, null);
        ds.length += w;
        at += @intCast(r);
        n -= @intCast(r);
        flags &= ~START;
        if (rc != NOSPACE or (r == 0 and w == 0 and free > 16)) break;
        obj.dsReserve(ds, @as(usize, @intCast(ds.space)) * 2);
    }
    // The text ends with the zero bytes of the encoding.
    const term: usize = if (to) 1 else nullSize(e);
    obj.dsReserve(ds, @as(usize, @intCast(ds.length)) + term);
    @memset(ds.string[@intCast(ds.length)..][0..term], 0);
    return @ptrCast(ds.string);
}

pub fn Tcl_ExternalToUtfDString(h: ?*anyopaque, src: ?[*]const u8, len: c_int, ds: *DString) callconv(.c) [*:0]u8 {
    return convertAll(h, true, src, len, ds);
}

pub fn Tcl_UtfToExternalDString(h: ?*anyopaque, src: ?[*]const u8, len: c_int, ds: *DString) callconv(.c) [*:0]u8 {
    return convertAll(h, false, src, len, ds);
}

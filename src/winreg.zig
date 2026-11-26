//! The optional `ztcl::win::registry` command: the registry of Windows
//! (capability `registry`, part of ztcl#111).
//!
//!     ztcl::win::registry get key name      ;# "" is the default value
//!     ztcl::win::registry set key ?name value ?type??
//!     ztcl::win::registry type key name
//!     ztcl::win::registry delete key ?name?
//!     ztcl::win::registry keys key ?pattern?
//!     ztcl::win::registry values key ?pattern?
//!
//! WARNING: the registry holds the settings of the user and of the
//! system, and a key such as `Run` starts a program at the next login.
//! The command reaches only the keys of `Interp.registry_allow` and the
//! keys below them, so the embedder lists the keys of its app. An empty
//! list reaches no key.
//!
//! A key is a root and a path, with `\` or `/` between the parts:
//! `HKEY_CURRENT_USER\Software\App`. The roots are `HKEY_CLASSES_ROOT`,
//! `HKEY_CURRENT_USER`, `HKEY_LOCAL_MACHINE`, `HKEY_USERS`, and
//! `HKEY_CURRENT_CONFIG`, and the short forms `HKCR`, `HKCU`, `HKLM`,
//! `HKU`, and `HKCC`. The check of the list compares the long form of
//! the root and the path, with no regard to case, part by part.
//!
//! The values, as in the `registry` package of Tcl: `sz` and
//! `expand_sz` are strings, `dword` and `qword` are integers,
//! `multi_sz` is a list, and `binary` and the other types are byte
//! strings (each byte is the character of its code). `set` makes the
//! key when it is absent, and its default type is `sz`. `delete` of a
//! key removes the key and each key below it. An absent key or value is
//! the error `ZTCL REGISTRY NOENT`, and a key outside the list is
//! `ZTCL REGISTRY DENIED`.
//!
//! The command exists only on Windows.
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;

pub const supported = builtin.os.tag == .windows;

const HKEY = *opaque {};
const LSTATUS = i32;
extern "advapi32" fn RegOpenKeyExW(key: HKEY, sub: ?[*:0]const u16, opts: u32, sam: u32, out: *HKEY) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegCreateKeyExW(key: HKEY, sub: [*:0]const u16, reserved: u32, class: ?[*:0]const u16, opts: u32, sam: u32, sec: ?*anyopaque, out: *HKEY, disp: ?*u32) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegQueryValueExW(key: HKEY, name: [*:0]const u16, reserved: ?*u32, kind: ?*u32, data: ?[*]u8, len: ?*u32) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegSetValueExW(key: HKEY, name: [*:0]const u16, reserved: u32, kind: u32, data: [*]const u8, len: u32) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegDeleteValueW(key: HKEY, name: [*:0]const u16) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegDeleteTreeW(key: HKEY, sub: ?[*:0]const u16) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegEnumKeyExW(key: HKEY, index: u32, name: [*]u16, len: *u32, reserved: ?*u32, class: ?[*]u16, class_len: ?*u32, time: ?*u64) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegEnumValueW(key: HKEY, index: u32, name: [*]u16, len: *u32, reserved: ?*u32, kind: ?*u32, data: ?[*]u8, data_len: ?*u32) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) LSTATUS;

const KEY_READ = 0x20019;
const KEY_WRITE = 0x20006;
const DELETE = 0x10000;
const ERROR_FILE_NOT_FOUND = 2;
const ERROR_ACCESS_DENIED = 5;
const ERROR_MORE_DATA = 234;
const ERROR_NO_MORE_ITEMS = 259;

const Type = enum(u32) { none = 0, sz = 1, expand_sz = 2, binary = 3, dword = 4, dword_big_endian = 5, link = 6, multi_sz = 7, resource_list = 8, full_resource_descriptor = 9, resource_requirements_list = 10, qword = 11 };

const roots = [_]struct { long: []const u8, short: []const u8, bits: u32 }{
    .{ .long = "HKEY_CLASSES_ROOT", .short = "HKCR", .bits = 0x80000000 },
    .{ .long = "HKEY_CURRENT_USER", .short = "HKCU", .bits = 0x80000001 },
    .{ .long = "HKEY_LOCAL_MACHINE", .short = "HKLM", .bits = 0x80000002 },
    .{ .long = "HKEY_USERS", .short = "HKU", .bits = 0x80000003 },
    .{ .long = "HKEY_CURRENT_CONFIG", .short = "HKCC", .bits = 0x80000005 },
};

/// A key: the index of its root and its path with `\` between the parts.
pub const Key = struct { root: usize, path: []const u8 };

/// Parses a key, or gives null for a bad root.
pub fn parseKey(a: std.mem.Allocator, text: []const u8) !?Key {
    const cut = std.mem.indexOfAny(u8, text, "\\/") orelse text.len;
    const head = text[0..cut];
    const root = for (roots, 0..) |r, i| {
        if (std.ascii.eqlIgnoreCase(head, r.long) or std.ascii.eqlIgnoreCase(head, r.short)) break i;
    } else return null;
    var path: std.ArrayList(u8) = .empty;
    var parts = std.mem.tokenizeAny(u8, if (cut < text.len) text[cut + 1 ..] else "", "\\/");
    while (parts.next()) |p| {
        if (path.items.len > 0) try path.append(a, '\\');
        try path.appendSlice(a, p);
    }
    return .{ .root = root, .path = path.items };
}

/// True when `key` is an entry of the list or below one.
pub fn allowed(a: std.mem.Allocator, list: []const []const u8, key: Key) !bool {
    for (list) |entry| {
        const e = (try parseKey(a, entry)) orelse continue;
        if (e.root != key.root) continue;
        if (e.path.len == 0) return true;
        if (key.path.len < e.path.len or !std.ascii.eqlIgnoreCase(key.path[0..e.path.len], e.path)) continue;
        if (key.path.len == e.path.len or key.path[e.path.len] == '\\') return true;
    }
    return false;
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    if (comptime supported) try it.register("ztcl::win::registry", cmdRegistry);
}

const usage = "ztcl::win::registry delete|get|keys|set|type|values key ?arg ...?";

fn cmdRegistry(it: *Interp, args: []const Value, _: ?*interp.Cmd) Error!Value {
    if (args.len < 3) return it.wrongArgs(usage);
    const sub = try it.str(args[1]);
    const a = it.alloc();
    const text = try it.str(args[2]);
    const key = (try parseKey(a, text)) orelse return it.failCode("ZTCL REGISTRY KEY", "bad key \"{s}\": the root must be HKEY_CLASSES_ROOT, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, HKEY_USERS, or HKEY_CURRENT_CONFIG", .{text});
    if (!try allowed(a, it.registry_allow, key)) return it.failCode("ZTCL REGISTRY DENIED", "the embedder did not allow the key \"{s}\"", .{text});
    if (std.mem.eql(u8, sub, "get")) {
        if (args.len != 4) return it.wrongArgs("ztcl::win::registry get key name");
        const h = try open(it, key, KEY_READ, text);
        defer _ = RegCloseKey(h);
        const v = try query(it, h, try it.str(args[3]), text);
        return decode(it, v.kind, v.data);
    }
    if (std.mem.eql(u8, sub, "type")) {
        if (args.len != 4) return it.wrongArgs("ztcl::win::registry type key name");
        const h = try open(it, key, KEY_READ, text);
        defer _ = RegCloseKey(h);
        const v = try query(it, h, try it.str(args[3]), text);
        return .{ .str = if (std.enums.fromInt(Type, v.kind)) |t| @tagName(t) else "none" };
    }
    if (std.mem.eql(u8, sub, "set")) {
        if (args.len != 3 and args.len != 5 and args.len != 6) return it.wrongArgs("ztcl::win::registry set key ?name value ?type??");
        var h: HKEY = undefined;
        const wpath = try wide(a, key.path);
        const st = RegCreateKeyExW(rootKey(key.root), wpath, 0, null, 0, KEY_WRITE, null, &h, null);
        if (st != 0) return status(it, st, "could not make the key", text);
        defer _ = RegCloseKey(h);
        if (args.len == 3) return .{ .str = "" };
        const kind_name = if (args.len == 6) try it.str(args[5]) else "sz";
        const kind = std.meta.stringToEnum(Type, kind_name) orelse return it.fail("bad type \"{s}\": must be binary, dword, expand_sz, multi_sz, qword, or sz", .{kind_name});
        const data = try encode(it, kind, args[4]);
        const st2 = RegSetValueExW(h, try wide(a, try it.str(args[3])), 0, @backingInt(kind), data.ptr, @intCast(data.len));
        if (st2 != 0) return status(it, st2, "could not set the value", text);
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "delete")) {
        if (args.len == 3) {
            if (key.path.len == 0) return it.failCode("ZTCL REGISTRY DENIED", "ztcl::win::registry does not delete a root key", .{});
            // With a name, RegDeleteTreeW removes the key and each key below it.
            const st = RegDeleteTreeW(rootKey(key.root), try wide(a, key.path));
            if (st != 0 and st != ERROR_FILE_NOT_FOUND) return status(it, st, "could not delete the key", text);
            return .{ .str = "" };
        }
        if (args.len != 4) return it.wrongArgs("ztcl::win::registry delete key ?name?");
        const h = try open(it, key, KEY_WRITE, text);
        defer _ = RegCloseKey(h);
        const st = RegDeleteValueW(h, try wide(a, try it.str(args[3])));
        if (st != 0 and st != ERROR_FILE_NOT_FOUND) return status(it, st, "could not delete the value", text);
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "keys") or std.mem.eql(u8, sub, "values")) {
        if (args.len != 3 and args.len != 4) return it.wrongArgs("ztcl::win::registry keys|values key ?pattern?");
        const pat: ?[]const u8 = if (args.len == 4) try it.str(args[3]) else null;
        const h = try open(it, key, KEY_READ, text);
        defer _ = RegCloseKey(h);
        var out: std.ArrayList(Value) = .empty;
        var buf: [16384]u16 = undefined;
        var i: u32 = 0;
        while (true) : (i += 1) {
            var n: u32 = buf.len;
            const st = if (sub[0] == 'k') RegEnumKeyExW(h, i, &buf, &n, null, null, null, null) else RegEnumValueW(h, i, &buf, &n, null, null, null, null);
            if (st == ERROR_NO_MORE_ITEMS) break;
            if (st != 0) return status(it, st, "could not list the key", text);
            const name = try utf8(a, buf[0..n]);
            if (pat) |p| if (!@import("cmds.zig").globMatch(p, name, true)) continue;
            try out.append(a, .{ .str = name });
        }
        return value.newList(a, out.items);
    }
    return it.fail("bad option \"{s}\": must be delete, get, keys, set, type, or values", .{sub});
}

fn rootKey(i: usize) HKEY {
    const bits: i32 = @bitCast(roots[i].bits);
    return @ptrFromInt(@as(usize, @bitCast(@as(isize, bits))));
}

fn open(it: *Interp, key: Key, sam: u32, text: []const u8) Error!HKEY {
    var h: HKEY = undefined;
    const st = RegOpenKeyExW(rootKey(key.root), if (key.path.len == 0) null else try wide(it.alloc(), key.path), 0, sam, &h);
    if (st != 0) return status(it, st, "could not open the key", text);
    return h;
}

fn status(it: *Interp, st: LSTATUS, what: []const u8, text: []const u8) Error {
    return switch (st) {
        ERROR_FILE_NOT_FOUND => it.failCode("ZTCL REGISTRY NOENT", "{s} \"{s}\": no such key or value", .{ what, text }),
        ERROR_ACCESS_DENIED => it.failCode("ZTCL REGISTRY ACCES", "{s} \"{s}\": permission denied", .{ what, text }),
        else => it.failCode("ZTCL REGISTRY ERROR", "{s} \"{s}\": error {d}", .{ what, text, st }),
    };
}

const Raw = struct { kind: u32, data: []const u8 };

fn query(it: *Interp, h: HKEY, name: []const u8, text: []const u8) Error!Raw {
    const a = it.alloc();
    const w = try wide(a, name);
    var kind: u32 = 0;
    var len: u32 = 0;
    var st = RegQueryValueExW(h, w, null, &kind, null, &len);
    while (true) {
        if (st != 0 and st != ERROR_MORE_DATA) return status(it, st, "could not read the value of", text);
        const data = try a.alloc(u8, len);
        st = RegQueryValueExW(h, w, null, &kind, data.ptr, &len);
        if (st == 0) return .{ .kind = kind, .data = data[0..len] };
    }
}

fn decode(it: *Interp, kind: u32, data: []const u8) Error!Value {
    const a = it.alloc();
    switch (kind) {
        @backingInt(Type.sz), @backingInt(Type.expand_sz) => return .{ .str = try utf8(a, trimNul(units(a, data) catch return error.OutOfMemory)) },
        @backingInt(Type.dword) => if (data.len >= 4) return .{ .int = std.mem.readInt(u32, data[0..4], .little) },
        @backingInt(Type.qword) => if (data.len >= 8) return .{ .int = @bitCast(std.mem.readInt(u64, data[0..8], .little)) },
        @backingInt(Type.multi_sz) => {
            const u = try units(a, data);
            var out: std.ArrayList(Value) = .empty;
            var parts = std.mem.splitScalar(u16, u, 0);
            while (parts.next()) |p| {
                if (p.len == 0) continue;
                try out.append(a, .{ .str = try utf8(a, p) });
            }
            return value.newList(a, out.items);
        },
        else => {},
    }
    // A byte string: each byte is the character of its code.
    var out: std.ArrayList(u8) = .empty;
    for (data) |b| {
        var tmp: [2]u8 = undefined;
        const n = std.unicode.utf8Encode(b, &tmp) catch unreachable;
        try out.appendSlice(a, tmp[0..n]);
    }
    return .{ .str = out.items };
}

fn encode(it: *Interp, kind: Type, v: Value) Error![]const u8 {
    const a = it.alloc();
    switch (kind) {
        .sz, .expand_sz, .link => {
            const w = try wide(a, try it.str(v));
            return std.mem.sliceAsBytes(w[0 .. w.len + 1]);
        },
        .dword => {
            const n = try it.int(v);
            if (n < 0 or n > std.math.maxInt(u32)) return it.fail("expected a dword from 0 to 4294967295 but got \"{d}\"", .{n});
            const out = try a.alloc(u8, 4);
            std.mem.writeInt(u32, out[0..4], @intCast(n), .little);
            return out;
        },
        .qword => {
            const out = try a.alloc(u8, 8);
            std.mem.writeInt(u64, out[0..8], @bitCast(try it.int(v)), .little);
            return out;
        },
        .multi_sz => {
            var out: std.ArrayList(u16) = .empty;
            for (try it.readList(v)) |e| {
                const w = try wide(a, try it.str(e));
                try out.appendSlice(a, w);
                try out.append(a, 0);
            }
            try out.append(a, 0);
            return std.mem.sliceAsBytes(out.items);
        },
        else => {
            // A byte string: each character below 256 is one byte.
            const s = try it.str(v);
            var out: std.ArrayList(u8) = .empty;
            const view = std.unicode.Utf8View.init(s) catch return it.fail("a byte string must be valid UTF-8", .{});
            var iter = view.iterator();
            while (iter.nextCodepoint()) |c| {
                if (c > 0xff) return it.fail("a byte string has characters below 256 only", .{});
                try out.append(a, @intCast(c));
            }
            return out.items;
        },
    }
}

fn wide(a: std.mem.Allocator, s: []const u8) Error![:0]const u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, s) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.unicode.utf8ToUtf16LeAllocZ(a, "") catch return error.OutOfMemory,
    };
}

fn units(a: std.mem.Allocator, data: []const u8) ![]const u16 {
    const out = try a.alloc(u16, data.len / 2);
    for (out, 0..) |*u, i| u.* = std.mem.readInt(u16, data[i * 2 ..][0..2], .little);
    return out;
}

fn trimNul(u: []const u16) []const u16 {
    var n = u.len;
    while (n > 0 and u[n - 1] == 0) n -= 1;
    return u[0..n];
}

fn utf8(a: std.mem.Allocator, u: []const u16) Error![]const u8 {
    return std.unicode.utf16LeToUtf8Alloc(a, u) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // An unpaired surrogate: the replacement character for each.
        else => {
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < u.len) : (i += 1) {
                var c: u21 = u[i];
                if (c >= 0xd800 and c < 0xdc00 and i + 1 < u.len and u[i + 1] >= 0xdc00 and u[i + 1] < 0xe000) {
                    c = 0x10000 + ((c - 0xd800) << 10) + (u[i + 1] - 0xdc00);
                    i += 1;
                } else if (c >= 0xd800 and c < 0xe000) c = 0xfffd;
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &tmp) catch unreachable;
                try out.appendSlice(a, tmp[0..n]);
            }
            return out.items;
        },
    };
}

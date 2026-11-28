//! The Windows form of the folder jail of `fsroot.zig`.
//!
//! The embedder gives one root folder. Each operation walks the path one
//! name at a time. `NtCreateFile` opens each name relative to the handle
//! of its parent, with FILE_OPEN_REPARSE_POINT, so the system follows no
//! symlink, junction, or mount point. The walk reads the attribute tag of
//! each handle, and any reparse point is an error. A race that swaps a folder
//! for a junction gives the handle of the junction, so the check sees it.
//!
//! The text check runs before any system call. These names are errors: a
//! name with a stream (`:`), a separator, a wildcard, or a control
//! character, a name that ends with a dot or a space, a device name with
//! or without an extension, and an NTFS metafile name such as `$MFT`. A name with `~` and a digit can be an 8.3 short name, so it
//! must be byte-equal to the long name on the disk.
//!
//! After each open, `GetFinalPathNameByHandleW` gives the real path of
//! the object, and it must be below the real path of the root. This is
//! the second check, and it fails closed. A truncate runs after both
//! checks, so a name that fails a check is never changed.
//!
//! One limit needs a process outside the sandbox with write access to the
//! root. If that process moves a folder out of the root right after
//! `parentOf` checks it, `mkdirAt`, `removeAt`, or `renameAt` acts in the
//! moved folder. An open and a stat check the object itself, so they give
//! an error.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const sys = @import("sys.zig");
const fsroot = @import("fsroot.zig");
const Interp = interp.Interp;
const Error = interp.Error;
const E = sys.win.E;

const HANDLE = ?*anyopaque;
const BOOL = i32;
const DWORD = u32;

const invalid_handle: HANDLE = @ptrFromInt(~@as(usize, 0));

const delete_access: u32 = 0x0001_0000;
const read_control: u32 = 0x0002_0000;
const synchronize: u32 = 0x0010_0000;
const file_read_data: u32 = 0x0001;
const file_write_data: u32 = 0x0002;
const file_append_data: u32 = 0x0004;
const file_read_ea: u32 = 0x0008;
const file_write_ea: u32 = 0x0010;
const file_traverse: u32 = 0x0020;
const file_read_attributes: u32 = 0x0080;
const file_write_attributes: u32 = 0x0100;
const dir_access: u32 = file_read_data | file_traverse | file_read_attributes | synchronize;
const read_access: u32 = read_control | file_read_data | file_read_attributes | file_read_ea | synchronize;
const write_access: u32 = read_control | file_write_attributes | file_write_ea | file_read_attributes | synchronize;

const share_all: u32 = 7;
const file_open: u32 = 1;
const file_create: u32 = 2;
const file_open_if: u32 = 3;
const opt_directory: u32 = 0x0000_0001;
const opt_sync: u32 = 0x0000_0020;
const opt_non_directory: u32 = 0x0000_0040;
const opt_open_reparse: u32 = 0x0020_0000;
const obj_case_insensitive: u32 = 0x40;
const attr_readonly: u32 = 0x0001;
const attr_directory: u32 = 0x0010;
const attr_normal: u32 = 0x0080;
const attr_reparse: u32 = 0x0400;
const flag_backup_semantics: u32 = 0x0200_0000;
const open_existing: u32 = 3;
const volume_name_nt: u32 = 2;
const duplicate_same_access: u32 = 2;

const class_basic: u32 = 4;
const class_standard: u32 = 5;
const class_internal: u32 = 6;
const class_rename: u32 = 10;
const class_names: u32 = 12;
const class_disposition: u32 = 13;
const class_end_of_file: u32 = 20;
const class_attribute_tag: u32 = 35;
const class_disposition_ex: u32 = 64;
const class_rename_ex: u32 = 65;

const status_no_more_files: u32 = 0x8000_0006;
const status_no_such_file: u32 = 0xC000_000F;

/// The longest final path that the check accepts, in UTF-16 units. A
/// longer path fails closed.
const final_cap = 4096;
const name_cap = 255;

const UnicodeString = extern struct { len: u16, max: u16, buf: ?[*]const u16 };
const ObjectAttributes = extern struct {
    length: u32,
    root: HANDLE,
    name: *const UnicodeString,
    attributes: u32,
    security: ?*anyopaque,
    qos: ?*anyopaque,
};
const IoStatus = extern struct { status: usize, info: usize };
const BasicInfo = extern struct { creation: i64, access: i64, write: i64, change: i64, attributes: u32, pad: u32 };
const StandardInfo = extern struct { allocation: i64, size: i64, links: u32, pending: u8, directory: u8, pad: u16 };
const TagInfo = extern struct { attributes: u32, tag: u32 };

extern "ntdll" fn NtCreateFile(out: *HANDLE, access: u32, attributes: *const ObjectAttributes, io: *IoStatus, size: ?*i64, file_attributes: u32, share: u32, disposition: u32, options: u32, ea: ?*anyopaque, ea_len: u32) callconv(.winapi) i32;
extern "ntdll" fn NtQueryInformationFile(h: HANDLE, io: *IoStatus, buf: *anyopaque, len: u32, class: u32) callconv(.winapi) i32;
extern "ntdll" fn NtSetInformationFile(h: HANDLE, io: *IoStatus, buf: *const anyopaque, len: u32, class: u32) callconv(.winapi) i32;
extern "ntdll" fn NtQueryDirectoryFile(h: HANDLE, event: HANDLE, apc: ?*anyopaque, context: ?*anyopaque, io: *IoStatus, buf: *anyopaque, len: u32, class: u32, single: u8, name: ?*const UnicodeString, restart: u8) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, security: ?*anyopaque, disposition: DWORD, flags: DWORD, template: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn DuplicateHandle(from: HANDLE, h: HANDLE, to: HANDLE, out: *HANDLE, access: DWORD, inherit: BOOL, options: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn GetFinalPathNameByHandleW(h: HANDLE, buf: [*]u16, size: DWORD, flags: DWORD) callconv(.winapi) DWORD;

fn ntError(status: i32) E {
    return switch (@as(u32, @bitCast(status))) {
        0xC000_000F, 0xC000_0034, 0xC000_003A => .NOENT,
        0xC000_0022, 0xC000_0043, 0xC000_0056, 0xC000_0121 => .ACCES,
        0xC000_0035 => .EXIST,
        0xC000_0103 => .NOTDIR,
        0xC000_00BA => .ISDIR,
        0xC000_0101 => .NOTEMPTY,
        0xC000_0033, 0xC000_000D => .INVAL,
        0xC000_0106 => .NAMETOOLONG,
        0xC000_00D4 => .XDEV,
        0x8000_002D, 0xC000_0275 => .LOOP,
        0xC000_0002, 0xC000_00BB => .NOSYS,
        else => @fromBackingInt(@intCast(1117)),
    };
}

/// True for a device name, with or without an extension.
fn isDevice(name: []const u8) bool {
    const stem = std.mem.trimEnd(u8, name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len], " ");
    var up: [8]u8 = undefined;
    if (stem.len > up.len) return false;
    for (stem, 0..) |c, i| up[i] = std.ascii.toUpper(c);
    const s = up[0..stem.len];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", "CLOCK$" }) |d| {
        if (std.mem.eql(u8, s, d)) return true;
    }
    if (s.len < 4 or !(std.mem.startsWith(u8, s, "COM") or std.mem.startsWith(u8, s, "LPT"))) return false;
    const tail = s[3..];
    if (tail.len == 1 and std.ascii.isDigit(tail[0])) return true;
    // The superscript digits 1, 2, and 3 name the same devices.
    return tail.len == 2 and tail[0] == 0xC2 and (tail[1] == 0xB9 or tail[1] == 0xB2 or tail[1] == 0xB3);
}

/// True for a metafile of NTFS, which exists at the top of a volume.
fn isMetafile(name: []const u8) bool {
    for ([_][]const u8{ "$MFT", "$MFTMirr", "$LogFile", "$Volume", "$AttrDef", "$Bitmap", "$Boot", "$BadClus", "$Secure", "$UpCase", "$Extend" }) |m| {
        if (std.ascii.eqlIgnoreCase(name, m)) return true;
    }
    return false;
}

/// The text check of one name. It makes no system call.
pub fn nameOk(name: []const u8) bool {
    if (name.len == 0) return false;
    const last = name[name.len - 1];
    if (last == '.' or last == ' ') return false;
    for (name) |c| {
        if (c < 0x20 or std.mem.indexOfScalar(u8, "\\/:*?\"<>|", c) != null) return false;
    }
    return !isDevice(name) and !isMetafile(name);
}

/// True when a name can be an 8.3 short name.
fn hasShortMark(name: []const u16) bool {
    if (name.len < 2) return false;
    for (name[0 .. name.len - 1], name[1..]) |a, b| {
        if (a == '~' and b >= '0' and b <= '9') return true;
    }
    return false;
}

fn toWide(name: []const u8, buf: *[name_cap]u16) ?[]const u16 {
    const n = std.unicode.calcUtf16LeLen(name) catch return null;
    if (n == 0 or n > name_cap) return null;
    const got = std.unicode.utf8ToUtf16Le(buf, name) catch return null;
    return buf[0..got];
}

fn finalPath(h: HANDLE, buf: *[final_cap]u16) ?[]const u16 {
    const n = GetFinalPathNameByHandleW(h, buf, final_cap, volume_name_nt);
    if (n == 0 or n >= final_cap) return null;
    return buf[0..n];
}

/// The second check: the real path of the handle is the root or below it.
fn insideRoot(it: *const Interp, h: HANDLE) bool {
    var buf: [final_cap]u16 = undefined;
    const got = finalPath(h, &buf) orelse return false;
    const root = it.fs.final;
    if (root.len == 0 or !std.mem.startsWith(u16, got, root)) return false;
    if (got.len == root.len or root[root.len - 1] == '\\') return true;
    return got[root.len] == '\\';
}

fn isReparse(h: HANDLE) bool {
    var io: IoStatus = undefined;
    var info: TagInfo = undefined;
    // With no answer, the handle counts as a reparse point.
    if (NtQueryInformationFile(h, &io, &info, @sizeOf(TagInfo), class_attribute_tag) < 0) return true;
    return info.attributes & attr_reparse != 0;
}

/// The error of a reparse point, or of a short name of another long name.
fn verified(h: HANDLE, name: []const u16) ?E {
    if (isReparse(h)) return .LOOP;
    if (hasShortMark(name)) {
        var buf: [final_cap]u16 = undefined;
        const got = finalPath(h, &buf) orelse return .ACCES;
        const cut = std.mem.lastIndexOfScalar(u16, got, '\\') orelse return .ACCES;
        if (!std.mem.eql(u16, got[cut + 1 ..], name)) return .ACCES;
    }
    return null;
}

fn openChild(parent: HANDLE, name: []const u16, access: u32, attributes: u32, disposition: u32, options: u32, out: *HANDLE) i32 {
    const bytes: u16 = @intCast(name.len * 2);
    const text: UnicodeString = .{ .len = bytes, .max = bytes, .buf = name.ptr };
    const object: ObjectAttributes = .{
        .length = @sizeOf(ObjectAttributes),
        .root = parent,
        .name = &text,
        .attributes = obj_case_insensitive,
        .security = null,
        .qos = null,
    };
    var io: IoStatus = undefined;
    return NtCreateFile(out, access, &object, &io, null, attributes, share_all, disposition, options | opt_sync | opt_open_reparse, null, 0);
}

fn dupOf(h: HANDLE) ?HANDLE {
    var out: HANDLE = null;
    const me = GetCurrentProcess();
    if (DuplicateHandle(me, h, me, &out, 0, 0, duplicate_same_access) == 0) return null;
    return out;
}

fn rootHandle(it: *const Interp) HANDLE {
    return @ptrFromInt(@as(usize, @intCast(it.fs.fd)));
}

const DirResult = union(enum) { h: HANDLE, err: E };

/// Opens the folder `dir` below the root, one name at a time.
fn openDir(it: *const Interp, dir: []const u8) DirResult {
    var cur = dupOf(rootHandle(it)) orelse return .{ .err = .ACCES };
    var parts = std.mem.tokenizeScalar(u8, dir, '/');
    while (parts.next()) |name| {
        var buf: [name_cap]u16 = undefined;
        const wide = (if (nameOk(name)) toWide(name, &buf) else null) orelse {
            _ = CloseHandle(cur);
            return .{ .err = .ACCES };
        };
        var next: HANDLE = null;
        const st = openChild(cur, wide, dir_access, 0, file_open, opt_directory, &next);
        _ = CloseHandle(cur);
        if (st < 0) return .{ .err = ntError(st) };
        if (verified(next, wide)) |e| {
            _ = CloseHandle(next);
            return .{ .err = e };
        }
        cur = next;
    }
    if (!insideRoot(it, cur)) {
        _ = CloseHandle(cur);
        return .{ .err = .ACCES };
    }
    return .{ .h = cur };
}

fn splitRel(rel: []const u8) struct { []const u8, []const u8 } {
    const cut = std.mem.lastIndexOfScalar(u8, rel, '/');
    return .{ if (cut) |c| rel[0..c] else "", if (cut) |c| rel[c + 1 ..] else rel };
}

pub fn setRoot(it: *Interp, path: []const u8) !void {
    const a = it.alloc();
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    const h = CreateFileW(wide.ptr, dir_access, share_all, null, open_existing, flag_backup_semantics, null);
    if (h == invalid_handle) return error.BadRoot;
    errdefer _ = CloseHandle(h);
    var io: IoStatus = undefined;
    var info: TagInfo = undefined;
    if (NtQueryInformationFile(h, &io, &info, @sizeOf(TagInfo), class_attribute_tag) < 0) return error.BadRoot;
    if (info.attributes & attr_directory == 0) return error.BadRoot;
    var buf: [final_cap]u16 = undefined;
    const final = finalPath(h, &buf) orelse return error.BadRoot;
    const fd = sys.win.fdOfHandle(h) orelse return error.BadRoot;
    it.fs.final = try a.dupe(u16, final);
    it.fs.path = try a.dupe(u8, std.mem.trimEnd(u8, path, "/\\"));
    it.fs.fd = fd;
}

/// A child interpreter gets its own handle of the root.
pub fn shareRoot(it: *const Interp, child: *Interp) std.mem.Allocator.Error!void {
    if (it.fs.fd < 0) return;
    const h = dupOf(rootHandle(it)) orelse return;
    const fd = sys.win.fdOfHandle(h) orelse {
        _ = CloseHandle(h);
        return;
    };
    child.fs.final = try child.alloc().dupe(u16, it.fs.final);
    child.fs.fd = fd;
}

pub fn openRel(it: *Interp, rel: []const u8, flags: sys.OpenFlags, mode: u32) Error!fsroot.OpenResult {
    if (it.fs.fd < 0) return it.fail("the embedder gave no root folder", .{});
    if (rel.len == 0) {
        if (!flags.directory and flags.access != .read) return .{ .err = .ISDIR };
        const h = dupOf(rootHandle(it)) orelse return .{ .err = .ACCES };
        const fd = sys.win.fdOfHandle(h) orelse {
            _ = CloseHandle(h);
            return .{ .err = .ACCES };
        };
        return .{ .fd = fd };
    }
    const dir, const base = splitRel(rel);
    var buf: [name_cap]u16 = undefined;
    const wide = (if (nameOk(base)) toWide(base, &buf) else null) orelse return .{ .err = .ACCES };
    const parent = switch (openDir(it, dir)) {
        .h => |h| h,
        .err => |e| return .{ .err = e },
    };
    defer _ = CloseHandle(parent);
    var access: u32 = read_access;
    if (flags.directory or flags.path_only) {
        access = dir_access;
    } else {
        if (flags.access == .write) access = write_access;
        if (flags.access == .read_write) access = read_access | write_access;
        if (flags.access != .read) {
            // With FILE_APPEND_DATA alone, each write goes to the end.
            access |= if (flags.append and !flags.truncate) file_append_data else file_write_data | file_append_data;
        }
    }
    const disposition: u32 = if (flags.create and flags.exclusive) file_create else if (flags.create) file_open_if else file_open;
    // As on Linux, a folder opens for reading, and its read is an error.
    const options: u32 = if (flags.directory) opt_directory else if (flags.path_only or flags.access == .read) 0 else opt_non_directory;
    const attributes: u32 = if (flags.create and mode & 0o200 == 0) attr_readonly else attr_normal;
    var h: HANDLE = null;
    const st = openChild(parent, wide, access, attributes, disposition, options, &h);
    if (st < 0) return .{ .err = ntError(st) };
    var keep = false;
    defer if (!keep) {
        _ = CloseHandle(h);
    };
    if (verified(h, wide)) |e| return .{ .err = e };
    if (!insideRoot(it, h)) return .{ .err = .ACCES };
    if (flags.truncate) {
        var io: IoStatus = undefined;
        const zero: i64 = 0;
        const rc = NtSetInformationFile(h, &io, &zero, @sizeOf(i64), class_end_of_file);
        if (rc < 0) return .{ .err = ntError(rc) };
    }
    const fd = sys.win.fdOfHandle(h) orelse return .{ .err = .ACCES };
    keep = true;
    return .{ .fd = fd };
}

pub fn parentOf(it: *Interp, rel: []const u8) Error!fsroot.ParentResult {
    const dir, const base = splitRel(rel);
    if (!nameOk(base)) return .{ .err = .ACCES };
    const h = switch (openDir(it, dir)) {
        .h => |x| x,
        .err => |e| return .{ .err = e },
    };
    const fd = sys.win.fdOfHandle(h) orelse {
        _ = CloseHandle(h);
        return .{ .err = .ACCES };
    };
    const name = it.alloc().dupeSentinel(u8, base, 0) catch |e| {
        _ = CloseHandle(h);
        return e;
    };
    return .{ .ok = .{ .fd = fd, .base = name } };
}

fn unixTime(t: i64) i64 {
    return @divFloor(t - 116_444_736_000_000_000, 10_000_000);
}

/// The data of a path. A reparse point is reported as a link, and the
/// walk never reads its target.
pub fn stat(it: *Interp, rel: []const u8) Error!fsroot.StatResult {
    var h: HANDLE = null;
    if (rel.len == 0) {
        h = dupOf(rootHandle(it)) orelse return .{ .err = .ACCES };
    } else {
        const dir, const base = splitRel(rel);
        var buf: [name_cap]u16 = undefined;
        const wide = (if (nameOk(base)) toWide(base, &buf) else null) orelse return .{ .err = .ACCES };
        const parent = switch (openDir(it, dir)) {
            .h => |x| x,
            .err => |e| return .{ .err = e },
        };
        defer _ = CloseHandle(parent);
        const st = openChild(parent, wide, file_read_attributes | synchronize, 0, file_open, 0, &h);
        if (st < 0) return .{ .err = ntError(st) };
        if (hasShortMark(wide) and !isReparse(h)) {
            if (verified(h, wide)) |e| {
                _ = CloseHandle(h);
                return .{ .err = e };
            }
        }
    }
    defer _ = CloseHandle(h);
    if (!insideRoot(it, h)) return .{ .err = .ACCES };
    return statHandle(h);
}

/// The data of an open handle.
fn statHandle(h: HANDLE) fsroot.StatResult {
    var io: IoStatus = undefined;
    var basic: BasicInfo = undefined;
    var standard: StandardInfo = undefined;
    var index: i64 = 0;
    var rc = NtQueryInformationFile(h, &io, &basic, @sizeOf(BasicInfo), class_basic);
    if (rc < 0) return .{ .err = ntError(rc) };
    rc = NtQueryInformationFile(h, &io, &standard, @sizeOf(StandardInfo), class_standard);
    if (rc < 0) return .{ .err = ntError(rc) };
    rc = NtQueryInformationFile(h, &io, &index, @sizeOf(i64), class_internal);
    if (rc < 0) return .{ .err = ntError(rc) };
    var kind: u32 = if (basic.attributes & attr_readonly != 0) 0o100444 else 0o100666;
    if (basic.attributes & attr_directory != 0) kind = 0o040777;
    if (basic.attributes & attr_reparse != 0) kind = 0o120777;
    return .{
        .ok = .{
            .mode = kind,
            .size = @intCast(@max(standard.size, 0)),
            .mtime = unixTime(basic.write),
            .atime = unixTime(basic.access),
            .ctime = unixTime(basic.change),
            // The file index names the file on its volume. Each file of the
            // jail is on the volume of the root: a reparse point (also a
            // mount point) does not open, so `dev` stays 0.
            .ino = @bitCast(index),
            .nlink = standard.links,
            .uid = 0,
            .gid = 0,
        },
    };
}

pub fn listDir(it: *Interp, rel: []const u8) Error!fsroot.ListResult {
    const a = it.alloc();
    // The open of fsroot, which also has host mode.
    const fd = switch (try fsroot.openRel(it, rel, .{ .directory = true }, 0)) {
        .fd => |x| x,
        .err => |e| return .{ .err = e },
    };
    defer sys.close(fd);
    const h: HANDLE = @ptrFromInt(@as(usize, @intCast(fd)));
    var out: std.ArrayList([]const u8) = .empty;
    var buf: [16384]u8 align(8) = undefined;
    var restart: u8 = 1;
    while (true) {
        var io: IoStatus = undefined;
        const st = NtQueryDirectoryFile(h, null, null, null, &io, &buf, buf.len, class_names, 0, null, restart);
        restart = 0;
        const code: u32 = @bitCast(st);
        if (code == status_no_more_files or code == status_no_such_file) break;
        if (st < 0) return .{ .err = ntError(st) };
        var off: usize = 0;
        while (true) {
            const next = std.mem.readInt(u32, buf[off..][0..4], .little);
            const len = std.mem.readInt(u32, buf[off + 8 ..][0..4], .little);
            const units: [*]align(1) const u16 = @ptrCast(&buf[off + 12]);
            var wide: [name_cap]u16 = undefined;
            const count = @min(len / 2, name_cap);
            for (0..count) |i| wide[i] = units[i];
            // A name that is not valid Unicode cannot be named by a script.
            if (std.unicode.utf16LeToUtf8Alloc(a, wide[0..count])) |name| {
                if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) try out.append(a, name);
            } else |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            }
            if (next == 0) break;
            off += next;
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return .{ .ok = out.items };
}

/// How `openAt` opens a name.
pub const OpenHow = enum { dir, read, create_new, any, read_write, write, open_new, create_rw };

/// Opens the name `name` relative to the folder `dir`, with no reparse
/// point and no short name of another long name: a folder to walk and
/// list, a file to read, or a new file to write. For a caller with its
/// own folder of the host, such as the store of `vmstore.zig`, with no
/// check of a jail root.
pub fn openAt(dir: i32, name: []const u8, how: OpenHow) union(enum) { fd: i32, err: E } {
    if (!nameOk(name)) return .{ .err = .ACCES };
    var buf: [name_cap]u16 = undefined;
    const wide = toWide(name, &buf) orelse return .{ .err = .ACCES };
    var h: HANDLE = null;
    const parent_h: HANDLE = @ptrFromInt(@as(usize, @intCast(dir)));
    const st = switch (how) {
        .dir => openChild(parent_h, wide, dir_access, 0, file_open, opt_directory, &h),
        .read => openChild(parent_h, wide, read_access, 0, file_open, opt_non_directory, &h),
        .create_new => openChild(parent_h, wide, write_access | file_write_data, attr_normal, file_create, opt_non_directory, &h),
        // The attributes of a file or a folder, for a stat.
        .any => openChild(parent_h, wide, file_read_attributes | read_control | synchronize, 0, file_open, 0, &h),
        .read_write => openChild(parent_h, wide, read_access | write_access | file_write_data | file_append_data, 0, file_open, opt_non_directory, &h),
        .write => openChild(parent_h, wide, write_access | file_write_data | file_append_data, 0, file_open, opt_non_directory, &h),
        // A new file, or the file that exists, for read and write.
        .open_new => openChild(parent_h, wide, read_access | write_access | file_write_data | file_append_data, attr_normal, file_open_if, opt_non_directory, &h),
        .create_rw => openChild(parent_h, wide, read_access | write_access | file_write_data | file_append_data, attr_normal, file_create, opt_non_directory, &h),
    };
    if (st < 0) return .{ .err = ntError(st) };
    if (verified(h, wide)) |e| {
        _ = CloseHandle(h);
        return .{ .err = e };
    }
    const fd = sys.win.fdOfHandle(h.?) orelse {
        _ = CloseHandle(h);
        return .{ .err = .ACCES };
    };
    return .{ .fd = fd };
}

/// The names in the open folder `fd`, with no `.` and `..`, in memory
/// of `a`. A name that is not valid Unicode is left out.
pub fn namesAt(a: std.mem.Allocator, fd: i32) ![][]u8 {
    const h: HANDLE = @ptrFromInt(@as(usize, @intCast(fd)));
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |x| a.free(x);
        out.deinit(a);
    }
    var buf: [16384]u8 align(8) = undefined;
    var restart: u8 = 1;
    while (true) {
        var io: IoStatus = undefined;
        const st = NtQueryDirectoryFile(h, null, null, null, &io, &buf, buf.len, class_names, 0, null, restart);
        restart = 0;
        const code: u32 = @bitCast(st);
        if (code == status_no_more_files or code == status_no_such_file) break;
        if (st < 0) return error.Io;
        var off: usize = 0;
        while (true) {
            const next = std.mem.readInt(u32, buf[off..][0..4], .little);
            const len = std.mem.readInt(u32, buf[off + 8 ..][0..4], .little);
            const units: [*]align(1) const u16 = @ptrCast(&buf[off + 12]);
            var wide: [name_cap]u16 = undefined;
            const count = @min(len / 2, name_cap);
            for (0..count) |i| wide[i] = units[i];
            if (std.unicode.utf16LeToUtf8Alloc(a, wide[0..count])) |name| {
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) a.free(name) else try out.append(a, name);
            } else |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            }
            if (next == 0) break;
            off += next;
        }
    }
    return out.toOwnedSlice(a);
}
fn parentHandle(p: fsroot.Parent) HANDLE {
    return @ptrFromInt(@as(usize, @intCast(p.fd)));
}

/// Deletes the last name. A reparse point is an error.
pub fn removeAt(p: fsroot.Parent, dir: bool) ?E {
    var buf: [name_cap]u16 = undefined;
    const wide = toWide(p.base, &buf) orelse return .ACCES;
    var h: HANDLE = null;
    const st = openChild(parentHandle(p), wide, delete_access | file_read_attributes | synchronize, 0, file_open, 0, &h);
    if (st < 0) return ntError(st);
    defer _ = CloseHandle(h);
    if (verified(h, wide)) |e| return e;
    var io: IoStatus = undefined;
    // As with `unlinkat`, the kind of the object must match the call.
    var tag: TagInfo = undefined;
    const kind = NtQueryInformationFile(h, &io, &tag, @sizeOf(TagInfo), class_attribute_tag);
    if (kind < 0) return ntError(kind);
    const is_dir = tag.attributes & attr_directory != 0;
    if (dir and !is_dir) return .NOTDIR;
    if (!dir and is_dir) return .ISDIR;
    // DELETE, POSIX semantics, and a read-only file too.
    const flags: u32 = 0x1 | 0x2 | 0x10;
    var rc = NtSetInformationFile(h, &io, &flags, 4, class_disposition_ex);
    if (rc < 0 and ntError(rc) != .NOTEMPTY) {
        const on: u8 = 1;
        rc = NtSetInformationFile(h, &io, &on, 1, class_disposition);
    }
    return if (rc < 0) ntError(rc) else null;
}

pub fn mkdirAt(p: fsroot.Parent) ?E {
    var buf: [name_cap]u16 = undefined;
    const wide = toWide(p.base, &buf) orelse return .ACCES;
    var h: HANDLE = null;
    const st = openChild(parentHandle(p), wide, dir_access, attr_normal, file_create, opt_directory, &h);
    if (st < 0) return ntError(st);
    _ = CloseHandle(h);
    return null;
}

/// Moves a name between two folders of the jail. It replaces a file at
/// the new name. A reparse point on either side is an error.
pub fn renameAt(p: fsroot.Parent, q: fsroot.Parent) ?E {
    var from: [name_cap]u16 = undefined;
    var to: [name_cap]u16 = undefined;
    const source = toWide(p.base, &from) orelse return .ACCES;
    const target = toWide(q.base, &to) orelse return .ACCES;
    var old: HANDLE = null;
    const here = openChild(parentHandle(q), target, file_read_attributes | synchronize, 0, file_open, 0, &old);
    if (here >= 0) {
        const bad = verified(old, target);
        _ = CloseHandle(old);
        if (bad) |e| return e;
    }
    var h: HANDLE = null;
    const st = openChild(parentHandle(p), source, delete_access | file_read_attributes | synchronize, 0, file_open, 0, &h);
    if (st < 0) return ntError(st);
    defer _ = CloseHandle(h);
    if (verified(h, source)) |e| return e;
    // FILE_RENAME_INFORMATION: flags, the root handle, the length, the name.
    var info: [24 + 2 * name_cap]u8 align(8) = undefined;
    @memset(info[0..24], 0);
    std.mem.writeInt(u32, info[0..4], 0x1 | 0x2, .little); // replace, POSIX
    std.mem.writeInt(usize, info[8..16], @intFromPtr(parentHandle(q)), .little);
    const bytes: u32 = @intCast(target.len * 2);
    std.mem.writeInt(u32, info[16..20], bytes, .little);
    @memcpy(info[20..][0..bytes], std.mem.sliceAsBytes(target));
    // The size of the structure is 24 with its padding, and a shorter
    // length, as for a name of one letter, gives
    // STATUS_INFO_LENGTH_MISMATCH.
    const size: u32 = @max(24, 20 + bytes);
    var io: IoStatus = undefined;
    var rc = NtSetInformationFile(h, &io, &info, size, class_rename_ex);
    if (rc < 0 and ntError(rc) == .NOSYS or rc == @as(i32, @bitCast(@as(u32, 0xC000_0003)))) {
        info[0] = 1; // ReplaceIfExists
        info[1] = 0;
        rc = NtSetInformationFile(h, &io, &info, size, class_rename);
    }
    return if (rc < 0) ntError(rc) else null;
}

// ---- Host mode ----
//
// In host mode the path is an absolute path of the host (`C:/a/b` or
// `//server/share/a`), and each open names it in full with `CreateFileW`,
// which follows symlinks, junctions, and mount points as tclsh does. The
// calls at a parent (`removeAt`, `mkdirAt`, `renameAt`) run on a handle of
// the parent folder, which `hostParent` opens by its full path.

extern "kernel32" fn GetCurrentDirectoryW(len: DWORD, buf: ?[*]u16) callconv(.winapi) DWORD;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

const create_new: u32 = 1;
const open_always: u32 = 4;

/// The current folder of the process.
pub fn currentFolder(a: std.mem.Allocator) ![]const u16 {
    const n = GetCurrentDirectoryW(0, null);
    if (n == 0) return error.BadRoot;
    const buf = try a.alloc(u16, n);
    const got = GetCurrentDirectoryW(n, buf.ptr);
    if (got == 0 or got >= n) return error.BadRoot;
    return buf[0..got];
}

/// The error of the last call, with the codes of the same meaning joined.
fn lastError() E {
    return switch (GetLastError()) {
        2, 3, 161 => .NOENT,
        5, 32 => .ACCES,
        80, 183 => .EXIST,
        145 => .NOTEMPTY,
        267 => .NOTDIR,
        206 => .NAMETOOLONG,
        else => |c| @fromBackingInt(@intCast(c)),
    };
}

fn widePath(a: std.mem.Allocator, path: []const u8) ![:0]u16 {
    const w = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    for (w) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    return w;
}

fn isFolder(h: HANDLE) ?bool {
    var io: IoStatus = undefined;
    var tag: TagInfo = undefined;
    if (NtQueryInformationFile(h, &io, &tag, @sizeOf(TagInfo), class_attribute_tag) < 0) return null;
    return tag.attributes & attr_directory != 0;
}

pub fn hostOpen(it: *Interp, path: []const u8, flags: sys.OpenFlags, mode: u32) Error!fsroot.OpenResult {
    const wide = widePath(it.alloc(), path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = .ACCES },
    };
    var access: u32 = read_access;
    if (flags.directory or flags.path_only) {
        access = dir_access;
    } else {
        if (flags.access == .write) access = write_access;
        if (flags.access == .read_write) access = read_access | write_access;
        if (flags.access != .read) access |= if (flags.append and !flags.truncate) file_append_data else file_write_data | file_append_data;
    }
    const disposition: u32 = if (flags.create and flags.exclusive) create_new else if (flags.create) open_always else open_existing;
    const attributes: u32 = if (flags.create and mode & 0o200 == 0) attr_readonly else attr_normal;
    // Backup semantics open a folder too. The kind check is below.
    const h = CreateFileW(wide.ptr, access, share_all, null, disposition, attributes | flag_backup_semantics, null);
    if (h == invalid_handle) return .{ .err = lastError() };
    var keep = false;
    defer if (!keep) {
        _ = CloseHandle(h);
    };
    const folder = isFolder(h) orelse return .{ .err = .ACCES };
    if (flags.directory and !folder) return .{ .err = .NOTDIR };
    // As on Linux, a folder opens for reading, and its read is an error.
    if (!flags.directory and !flags.path_only and flags.access != .read and folder) return .{ .err = .ISDIR };
    if (flags.truncate) {
        var io: IoStatus = undefined;
        const zero: i64 = 0;
        const rc = NtSetInformationFile(h, &io, &zero, @sizeOf(i64), class_end_of_file);
        if (rc < 0) return .{ .err = ntError(rc) };
    }
    const fd = sys.win.fdOfHandle(h) orelse return .{ .err = .ACCES };
    keep = true;
    return .{ .fd = fd };
}

/// A handle of the parent folder of an absolute host path, and the last name.
pub fn hostParent(it: *Interp, path: []const u8) Error!fsroot.ParentResult {
    const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse return .{ .err = .ACCES };
    const base = path[cut + 1 ..];
    if (base.len == 0) return .{ .err = .ACCES };
    // The parent of `C:/x` is `C:/`, with its separator.
    const dir = if (cut > 0 and path[cut - 1] == ':') path[0 .. cut + 1] else path[0..cut];
    const h = switch (try hostOpen(it, dir, .{ .directory = true }, 0)) {
        .fd => |fd| fd,
        .err => |e| return .{ .err = e },
    };
    const name = it.alloc().dupeSentinel(u8, base, 0) catch |e| {
        sys.close(h);
        return e;
    };
    return .{ .ok = .{ .fd = h, .base = name } };
}

pub fn hostStat(it: *Interp, path: []const u8) Error!fsroot.StatResult {
    const wide = widePath(it.alloc(), path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = .ACCES },
    };
    const h = CreateFileW(wide.ptr, file_read_attributes | synchronize, share_all, null, open_existing, flag_backup_semantics, null);
    if (h == invalid_handle) return .{ .err = lastError() };
    defer _ = CloseHandle(h);
    return statHandle(h);
}

extern "kernel32" fn GetLogicalDrives() callconv(.winapi) DWORD;
extern "kernel32" fn GetVolumeInformationW(root: [*:0]const u16, name: ?[*]u16, name_len: DWORD, serial: ?*DWORD, max_component: ?*DWORD, flags: ?*DWORD, fs_name: ?[*]u16, fs_name_len: DWORD) callconv(.winapi) BOOL;

/// The drives of the system as a list for `file volumes` in host mode:
/// `C:/ D:/`, in the order of their letters.
pub fn volumes(a: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    const mask = GetLogicalDrives();
    var out: std.ArrayList(u8) = .empty;
    for (0..26) |i| {
        if (mask >> @intCast(i) & 1 == 0) continue;
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, &.{ @as(u8, 'A') + @as(u8, @intCast(i)), ':', '/' });
    }
    return out.items;
}

/// The name of the file system of the volume `prefix` (`C:` or
/// `//server/share`), such as NTFS, or null when the system gives none.
pub fn fsName(a: std.mem.Allocator, prefix: []const u8) std.mem.Allocator.Error!?[]const u8 {
    var root: [600]u16 = undefined;
    var n: usize = 0;
    for (prefix) |c| {
        if (n + 2 >= root.len) return null;
        root[n] = if (c == '/') '\\' else c;
        n += 1;
    }
    root[n] = '\\';
    root[n + 1] = 0;
    var name: [64]u16 = undefined;
    if (GetVolumeInformationW(@ptrCast(&root), null, 0, null, null, null, &name, name.len) == 0) return null;
    const len = std.mem.indexOfScalar(u16, &name, 0) orelse name.len;
    return std.unicode.utf16LeToUtf8Alloc(a, name[0..len]) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

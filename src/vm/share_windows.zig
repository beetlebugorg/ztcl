//! The files of a 9p share on Windows: the `Fs` of `virtio/ninep.zig` on
//! the handle of the root folder of the share, which ztcl opens in the
//! file jail.
//!
//! Each path walks one name at a time from the root folder with
//! `fsroot_windows.openAt`, which opens the name relative to the handle
//! of its folder with FILE_OPEN_REPARSE_POINT and refuses a reparse
//! point (a symbolic link, a junction, or a mount point) and a short name
//! of another long name, so no step of a path leaves the folder. The
//! changes of a name (mkdir, unlink, rename) are the calls of the file
//! jail at the handle of the folder. The guest is Linux, so each error is
//! a Linux errno, and the attributes come from the NT information of the
//! file: a folder is 0755, a file 0644, or 0444 with the read-only
//! attribute, and the inode is the file ID of NTFS.
//!
//! A share of Windows has no symbolic links and no hard links: `symlink`
//! and `link` give EPERM, and `readlink` gives EINVAL. `setattr` changes
//! the size and the times, and keeps the mode and the owner.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const ninep = @import("virtio/ninep.zig");
const fw = @import("../fsroot_windows.zig");
const sys = @import("../sys.zig");

const HANDLE = *anyopaque;
const E = ninep.E;
const a = std.heap.smp_allocator;

pub const Share = struct {
    /// The root folder of the share: a descriptor of ztcl (the value of
    /// its handle), opened as a folder.
    root: i32,
    read_only: bool,
    /// The folders that walks opened lately, by their path. A walk
    /// starts at the deepest one of its path in the place of the root.
    cache: [cache_slots]Cached = @splat(.{}),

    pub fn fs(s: *Share) ninep.Fs {
        return .{ .ctx = s, .read_only = s.read_only, .vt = &vtable };
    }
};

const vtable: ninep.Fs.VTable = .{
    .stat = stat,
    .open = open,
    .create = create,
    .close = close,
    .read = read,
    .write = write,
    .readdir = readdir,
    .fsync = fsync,
    .mkdir = mkdir,
    .symlink = symlink,
    .link = link,
    .readlink = readlink,
    .unlink = unlink,
    .rename = rename,
    .setattr = setattr,
    .statfs = statfs,
};

/// An open file of the guest.
const Open = struct {
    fd: i32,
    append: bool,
    /// The names of a folder, from `listFolder`.
    list: std.ArrayList(u8) = .empty,
};

extern "ntdll" fn NtQueryInformationFile(h: HANDLE, io: *IoStatus, buf: *anyopaque, len: u32, class: u32) callconv(.winapi) i32;
extern "ntdll" fn NtSetInformationFile(h: HANDLE, io: *IoStatus, buf: *const anyopaque, len: u32, class: u32) callconv(.winapi) i32;
extern "ntdll" fn NtQueryVolumeInformationFile(h: HANDLE, io: *IoStatus, buf: *anyopaque, len: u32, class: u32) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, got: *u32, ov: *Overlapped) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, put: *u32, ov: *Overlapped) callconv(.winapi) i32;
extern "kernel32" fn FlushFileBuffers(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetFileInformationByHandleEx(h: HANDLE, class: u32, buf: *anyopaque, len: u32) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetSystemTimePreciseAsFileTime(t: *i64) callconv(.winapi) void;
extern "kernel32" fn DuplicateHandle(from: HANDLE, h: HANDLE, to: HANDLE, out: *?HANDLE, access: u32, inherit: i32, options: u32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;

const IoStatus = extern struct { status: usize = 0, info: usize = 0 };
const Overlapped = extern struct { internal: usize = 0, internal_high: usize = 0, offset: u32 = 0, offset_high: u32 = 0, event: ?HANDLE = null };
const BasicInfo = extern struct { creation: i64 = 0, access: i64 = 0, write: i64 = 0, change: i64 = 0, attributes: u32 = 0, pad: u32 = 0 };
const StandardInfo = extern struct { allocation: i64, size: i64, links: u32, pending: u8, directory: u8, pad: u16 };
const InternalInfo = extern struct { index: u64 };
const FullSizeInfo = extern struct { total: i64, caller_free: i64, actual_free: i64, sectors_per_unit: u32, bytes_per_sector: u32 };

const class_basic = 4;
const class_standard = 5;
const class_internal = 6;
const class_end_of_file = 20;
const fs_full_size = 7;
const attr_readonly: u32 = 0x1;
const attr_directory: u32 = 0x10;
const attr_reparse: u32 = 0x400;

fn handleOf(fd: i32) HANDLE {
    return @ptrFromInt(@as(usize, @intCast(fd)));
}

/// The errno of Linux for an error of the file jail of Windows.
fn errnoOf(e: sys.win.E) u32 {
    return switch (e) {
        .NOENT => E.NOENT,
        .ACCES => 13,
        .EXIST => E.EXIST,
        .INVAL => E.INVAL,
        .NOSYS => E.NOSYS,
        .NOTEMPTY => 39,
        .NAMETOOLONG => E.NAMETOOLONG,
        .NOTDIR => E.NOTDIR,
        .ISDIR => E.ISDIR,
        .PERM => E.PERM,
        .LOOP => 40,
        .XDEV => 18,
        _ => E.IO,
    };
}

fn shareOf(ctx: *anyopaque) *Share {
    return @ptrCast(@alignCast(ctx));
}

// ---- The cache of folders ----
//
// A walk of each request opened each name of its path again, about 60 µs
// for a path of three names. The share keeps the folders of the last
// walks open, by path: a walk finds the deepest one of its path and opens
// only the names after it. An entry lives 1 s, so a folder that the host
// removed and made again under the same name is not served from an old
// handle for long. A rename or a removal of the guest drops the entries
// of its path and of the paths below it. A walk pins its entry until
// `done`, so a second walk of the same request never closes it.

const cache_slots = 32;
const ttl_ms = 1000;

const Cached = struct {
    path: []u8 = &.{},
    fd: i32 = -1,
    at: u64 = 0,
    pins: u32 = 0,
    /// Dropped while pinned: `done` closes it.
    dead: bool = false,
};

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

fn fresh(c: *const Cached, now: u64) bool {
    return c.fd >= 0 and !c.dead and now -% c.at < ttl_ms;
}

fn free(c: *Cached) void {
    if (c.fd >= 0) sys.close(c.fd);
    a.free(c.path);
    c.* = .{};
}

/// Keeps `fd` as the folder of `path`, pinned. False when each slot is
/// pinned: the caller keeps the descriptor.
fn keep(s: *Share, path: []const u8, fd: i32, now: u64) bool {
    var slot: ?*Cached = null;
    var oldest: u64 = std.math.maxInt(u64);
    for (&s.cache) |*c| {
        if (c.pins != 0) continue;
        if (c.fd < 0) {
            slot = c;
            break;
        }
        if (c.at < oldest) {
            oldest = c.at;
            slot = c;
        }
    }
    const c = slot orelse return false;
    const p = a.dupe(u8, path) catch return false;
    free(c);
    c.* = .{ .path = p, .fd = fd, .at = now, .pins = 1 };
    return true;
}

/// Drops the entries of `path` and of the paths below it.
fn drop(s: *Share, path: []const u8) void {
    for (&s.cache) |*c| {
        if (c.fd < 0) continue;
        const under = std.mem.eql(u8, c.path, path) or
            (c.path.len > path.len and std.mem.startsWith(u8, c.path, path) and c.path[path.len] == '/');
        if (!under) continue;
        if (c.pins == 0) free(c) else c.dead = true;
    }
}

/// The folder at `path` below the root, opened one name at a time from
/// the deepest folder of the cache on the path. Give the result to
/// `done`.
fn walk(s: *Share, path: []const u8, out: *i32) u32 {
    if (path.len == 0) {
        out.* = s.root;
        return 0;
    }
    const now = GetTickCount64();
    var best: ?*Cached = null;
    for (&s.cache) |*c| {
        if (!fresh(c, now)) continue;
        const prefix = std.mem.eql(u8, c.path, path) or
            (path.len > c.path.len and std.mem.startsWith(u8, path, c.path) and path[c.path.len] == '/');
        if (prefix and (best == null or c.path.len > best.?.path.len)) best = c;
    }
    if (best) |b| if (b.path.len == path.len) {
        b.pins += 1;
        out.* = b.fd;
        return 0;
    };
    var cur = if (best) |b| b.fd else s.root;
    const start = if (best) |b| b.path.len + 1 else 0;
    var owned = false;
    var it = std.mem.splitScalar(u8, path[start..], '/');
    while (it.next()) |name| {
        const r = fw.openAt(cur, name, .dir);
        if (owned) sys.close(cur);
        switch (r) {
            .fd => |f| {
                cur = f;
                owned = true;
            },
            .err => |e| return errnoOf(e),
        }
    }
    if (!keep(s, path, cur, now)) {
        // Each slot is pinned: the descriptor is the caller's to close.
        out.* = cur;
        return 0;
    }
    out.* = cur;
    return 0;
}

/// The end of the use of a folder of `walk`.
fn done(s: *Share, fd: i32) void {
    if (fd == s.root) return;
    for (&s.cache) |*c| if (c.fd == fd) {
        c.pins -= 1;
        if (c.pins == 0 and c.dead) free(c);
        return;
    };
    sys.close(fd);
}

/// The folder and the last name of a path. The root has no last name.
fn split(path: []const u8) struct { dir: []const u8, name: []const u8 } {
    const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse return .{ .dir = "", .name = path };
    return .{ .dir = path[0..cut], .name = path[cut + 1 ..] };
}

/// Opens the file or the folder of `path` with `how`.
fn openPath(s: *Share, path: []const u8, how: fw.OpenHow, out: *i32) u32 {
    if (path.len == 0) return E.ISDIR;
    const p = split(path);
    var dir: i32 = undefined;
    const err = walk(s, p.dir, &dir);
    if (err != 0) return err;
    defer done(s, dir);
    return switch (fw.openAt(dir, p.name, how)) {
        .fd => |f| blk: {
            out.* = f;
            break :blk 0;
        },
        .err => |e| errnoOf(e),
    };
}

/// A time of Linux from a time of NT: 100 ns since 1601.
fn timeOf(t: i64) ninep.Time {
    const unix = t - 116444736000000000;
    if (unix < 0) return .{};
    const u: u64 = @intCast(unix);
    return .{ .sec = u / 10_000_000, .nsec = (u % 10_000_000) * 100 };
}

fn ntTime(t: ninep.Time) i64 {
    return @as(i64, @intCast(t.sec)) * 10_000_000 + @as(i64, @intCast(t.nsec / 100)) + 116444736000000000;
}

/// The attributes of an open file or folder.
fn attrOf(fd: i32, out: *ninep.Attr) u32 {
    const h = handleOf(fd);
    var io: IoStatus = .{};
    var b: BasicInfo = .{};
    var st: StandardInfo = undefined;
    var in: InternalInfo = undefined;
    if (NtQueryInformationFile(h, &io, &b, @sizeOf(BasicInfo), class_basic) < 0) return E.IO;
    if (NtQueryInformationFile(h, &io, &st, @sizeOf(StandardInfo), class_standard) < 0) return E.IO;
    if (NtQueryInformationFile(h, &io, &in, @sizeOf(InternalInfo), class_internal) < 0) return E.IO;
    const is_dir = b.attributes & attr_directory != 0;
    out.* = .{
        .mode = if (is_dir) 0o040755 else if (b.attributes & attr_readonly != 0) 0o100444 else 0o100644,
        .nlink = if (is_dir) 2 else st.links,
        .size = if (is_dir) 0 else @intCast(@max(st.size, 0)),
        .blocks = @intCast(@divTrunc(@max(st.allocation, 0), 512)),
        .atime = timeOf(b.access),
        .mtime = timeOf(b.write),
        .ctime = timeOf(b.change),
        .ino = in.index,
    };
    return 0;
}

const UnicodeString = extern struct { len: u16, max: u16, buf: ?[*]const u16 };
const ObjectAttributes = extern struct {
    length: u32 = @sizeOf(ObjectAttributes),
    root: ?HANDLE,
    name: *const UnicodeString,
    attributes: u32 = 0x40, // OBJ_CASE_INSENSITIVE
    security: ?*anyopaque = null,
    qos: ?*anyopaque = null,
};
/// FILE_STAT_INFORMATION: 72 bytes.
const StatInfo = extern struct {
    id: u64,
    creation: i64,
    access: i64,
    write: i64,
    change: i64,
    allocation: i64,
    size: i64,
    attributes: u32,
    reparse_tag: u32,
    links: u32,
    access_mask: u32,
};
const class_stat = 68;
extern "ntdll" fn NtQueryInformationByName(oa: *const ObjectAttributes, io: *IoStatus, buf: *anyopaque, len: u32, class: u32) callconv(.winapi) i32;

/// True when a name can be an 8.3 short name of another long name.
fn shortMark(name: []const u8) bool {
    if (name.len < 2) return false;
    for (name[0 .. name.len - 1], name[1..]) |c, d| if (c == '~' and d >= '0' and d <= '9') return true;
    return false;
}

/// The attributes of `name` in the folder `dir` with no open: one
/// `NtQueryInformationByName`, which gives the reparse tag of the name
/// itself. A reparse point is ELOOP, as a walk gives it.
fn statByName(dir: i32, name: []const u8, out: *ninep.Attr) u32 {
    var wide: [256]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, name) catch return E.INVAL;
    const text: UnicodeString = .{ .len = @intCast(n * 2), .max = @intCast(n * 2), .buf = &wide };
    const oa: ObjectAttributes = .{ .root = handleOf(dir), .name = &text };
    var io: IoStatus = .{};
    var st: StatInfo = undefined;
    const r = NtQueryInformationByName(&oa, &io, &st, @sizeOf(StatInfo), class_stat);
    if (r < 0) return switch (@as(u32, @bitCast(r))) {
        0xC000_0034, 0xC000_003A, 0xC000_000F => E.NOENT,
        0xC000_0022 => 13,
        0xC000_0103 => E.NOTDIR,
        else => E.IO,
    };
    if (st.attributes & attr_reparse != 0) return 40;
    const is_dir = st.attributes & attr_directory != 0;
    out.* = .{
        .mode = if (is_dir) 0o040755 else if (st.attributes & attr_readonly != 0) 0o100444 else 0o100644,
        .nlink = if (is_dir) 2 else st.links,
        .size = if (is_dir) 0 else @intCast(@max(st.size, 0)),
        .blocks = @intCast(@divTrunc(@max(st.allocation, 0), 512)),
        .atime = timeOf(st.access),
        .mtime = timeOf(st.write),
        .ctime = timeOf(st.change),
        .ino = st.id,
    };
    return 0;
}

fn stat(ctx: *anyopaque, path: []const u8, out: *ninep.Attr) u32 {
    const s = shareOf(ctx);
    if (path.len == 0) return attrOf(s.root, out);
    const p = split(path);
    if (fw.nameOk(p.name) and !shortMark(p.name)) {
        var dir: i32 = undefined;
        const e = walk(s, p.dir, &dir);
        if (e != 0) return e;
        defer done(s, dir);
        return statByName(dir, p.name, out);
    }
    var fd: i32 = undefined;
    const e = openPath(s, path, .any, &fd);
    if (e != 0) return e;
    defer sys.close(fd);
    return attrOf(fd, out);
}

fn newOpen(fd: i32, flags: u32, out: *u64) u32 {
    const o = a.create(Open) catch {
        sys.close(fd);
        return E.NOMEM;
    };
    o.* = .{ .fd = fd, .append = flags & ninep.O.APPEND != 0 };
    out.* = @intFromPtr(o);
    return 0;
}

fn truncate(fd: i32) u32 {
    var io: IoStatus = .{};
    const zero: i64 = 0;
    if (NtSetInformationFile(handleOf(fd), &io, &zero, 8, class_end_of_file) < 0) return E.IO;
    return 0;
}

fn howOf(flags: u32) fw.OpenHow {
    return switch (flags & ninep.O.ACCMODE) {
        ninep.O.WRONLY => .write,
        ninep.O.RDWR => .read_write,
        else => .read,
    };
}

fn open(ctx: *anyopaque, path: []const u8, flags: u32, out: *u64) u32 {
    const s = shareOf(ctx);
    const writes = flags & ninep.O.ACCMODE != ninep.O.RDONLY or flags & ninep.O.TRUNC != 0;
    if (writes and s.read_only) return E.ROFS;
    var fd: i32 = undefined;
    // A folder opens as a folder, for readdir.
    if (path.len == 0) {
        const e = walkCopy(s, "", &fd);
        if (e != 0) return e;
        return newOpen(fd, flags, out);
    }
    var e = openPath(s, path, howOf(flags), &fd);
    if (e == E.ISDIR or (e != 0 and flags & ninep.O.DIRECTORY != 0)) {
        if (writes) return E.ISDIR;
        e = walkCopy(s, path, &fd);
    }
    if (e != 0) return e;
    if (flags & ninep.O.TRUNC != 0) {
        const t = truncate(fd);
        if (t != 0) {
            sys.close(fd);
            return t;
        }
    }
    return newOpen(fd, flags, out);
}

/// The folder at `path` as a descriptor of its own, also for the root.
fn walkCopy(s: *Share, path: []const u8, out: *i32) u32 {
    if (path.len == 0) {
        // A copy of the handle of the root, which `close` closes.
        var h: ?HANDLE = null;
        const me = GetCurrentProcess();
        // DUPLICATE_SAME_ACCESS
        if (DuplicateHandle(me, handleOf(s.root), me, &h, 0, 0, 2) == 0) return E.IO;
        out.* = sys.win.fdOfHandle(h.?) orelse return E.IO;
        return 0;
    }
    // A copy of the folder of the walk, which `close` closes: the cache
    // keeps its own.
    var d: i32 = undefined;
    const e = walk(s, path, &d);
    if (e != 0) return e;
    defer done(s, d);
    var h: ?HANDLE = null;
    const me = GetCurrentProcess();
    if (DuplicateHandle(me, handleOf(d), me, &h, 0, 0, 2) == 0) return E.IO;
    out.* = sys.win.fdOfHandle(h.?) orelse return E.IO;
    return 0;
}

fn create(ctx: *anyopaque, dir_path: []const u8, name: []const u8, flags: u32, mode: u32, out: *u64) u32 {
    _ = mode;
    const s = shareOf(ctx);
    if (s.read_only) return E.ROFS;
    var dir: i32 = undefined;
    const e = walk(s, dir_path, &dir);
    if (e != 0) return e;
    defer done(s, dir);
    const how: fw.OpenHow = if (flags & ninep.O.EXCL != 0) .create_rw else .open_new;
    const fd = switch (fw.openAt(dir, name, how)) {
        .fd => |f| f,
        .err => |x| return errnoOf(x),
    };
    if (flags & ninep.O.TRUNC != 0) {
        const t = truncate(fd);
        if (t != 0) {
            sys.close(fd);
            return t;
        }
    }
    return newOpen(fd, flags, out);
}

fn openOf(h: u64) *Open {
    return @ptrFromInt(@as(usize, @intCast(h)));
}

/// The file handle of the open `h` of this backend, for a view of the
/// file in the DAX window of virtio-fs.
pub fn fileOf(h: u64) HANDLE {
    return handleOf(openOf(h).fd);
}

fn close(_: *anyopaque, h: u64) void {
    const o = openOf(h);
    sys.close(o.fd);
    o.list.deinit(a);
    a.destroy(o);
}

fn read(_: *anyopaque, h: u64, off: u64, buf: []u8, n: *usize) u32 {
    const o = openOf(h);
    var ov: Overlapped = .{ .offset = @truncate(off), .offset_high = @truncate(off >> 32) };
    var got: u32 = 0;
    const len: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
    if (ReadFile(handleOf(o.fd), buf.ptr, len, &got, &ov) == 0) {
        // ERROR_HANDLE_EOF
        if (GetLastError() == 38) {
            n.* = 0;
            return 0;
        }
        return E.IO;
    }
    n.* = got;
    return 0;
}

fn write(_: *anyopaque, h: u64, off: u64, data: []const u8, n: *usize) u32 {
    const o = openOf(h);
    // An offset of all ones writes at the end of the file.
    const at: u64 = if (o.append) ~@as(u64, 0) else off;
    var ov: Overlapped = .{ .offset = @truncate(at), .offset_high = @truncate(at >> 32) };
    var put: u32 = 0;
    const len: u32 = @intCast(@min(data.len, std.math.maxInt(u32)));
    if (WriteFile(handleOf(o.fd), data.ptr, len, &put, &ov) == 0) return E.IO;
    n.* = put;
    return 0;
}

/// A listing of a folder: at offset 0 the backend reads each name of the
/// folder into `Open.list`, and each offset after that is an index into
/// it. A scan of the folder from its start at each call skips names when
/// the guest deletes them as it reads (`rm -r`), so the list stays fixed
/// from offset 0 to the next offset 0, as POSIX lets `readdir` be.
fn readdir(_: *anyopaque, h: u64, off: u64, sink: ninep.DirSink) u32 {
    const o = openOf(h);
    if (off == 0 or o.list.items.len == 0) {
        const e = listFolder(o);
        if (e != 0) return e;
    }
    var at: usize = 0;
    var index: u64 = 0;
    while (at < o.list.items.len) : (index += 1) {
        const l = o.list.items[at..];
        const id = std.mem.readInt(u64, l[0..8], .little);
        const kind = l[8];
        const nl = std.mem.readInt(u16, l[9..11], .little);
        const name = l[11..][0..nl];
        at += 11 + nl;
        if (index < off) continue;
        if (!sink.put(sink.ctx, .{ .ino = id, .next = index + 1, .kind = kind, .name = name })) return 0;
    }
    return 0;
}

/// Reads each name of the folder of `o` into `o.list`: the file ID (8
/// bytes), the kind (1 byte), the length of the name (2 bytes), and the
/// name in UTF-8.
fn listFolder(o: *Open) u32 {
    o.list.clearRetainingCapacity();
    var buf: [16384]u8 align(8) = undefined;
    var first = true;
    while (true) {
        // FileIdBothDirectoryRestartInfo first, then FileIdBothDirectoryInfo.
        const class: u32 = if (first) 0xB else 0xA;
        first = false;
        if (GetFileInformationByHandleEx(handleOf(o.fd), class, &buf, buf.len) == 0) {
            // ERROR_NO_MORE_FILES
            if (GetLastError() == 18) return 0;
            return E.IO;
        }
        var at: usize = 0;
        while (true) {
            const next = std.mem.readInt(u32, buf[at..][0..4], .little);
            const attrs = std.mem.readInt(u32, buf[at + 56 ..][0..4], .little);
            const len = std.mem.readInt(u32, buf[at + 60 ..][0..4], .little);
            const id = std.mem.readInt(u64, buf[at + 96 ..][0..8], .little);
            const units: [*]align(1) const u16 = @ptrCast(&buf[at + 104]);
            var wide: [256]u16 = undefined;
            const count = @min(len / 2, wide.len);
            for (0..count) |i| wide[i] = units[i];
            var name: [1024]u8 = undefined;
            if (std.unicode.utf16LeToUtf8(&name, wide[0..count])) |nl| {
                // DT_DIR 4, DT_LNK 10, DT_REG 8.
                const kind: u8 = if (attrs & attr_reparse != 0) 10 else if (attrs & attr_directory != 0) 4 else 8;
                var head: [11]u8 = undefined;
                std.mem.writeInt(u64, head[0..8], id, .little);
                head[8] = kind;
                std.mem.writeInt(u16, head[9..11], @intCast(nl), .little);
                o.list.appendSlice(a, &head) catch return E.NOMEM;
                o.list.appendSlice(a, name[0..nl]) catch return E.NOMEM;
            } else |_| {}
            if (next == 0) break;
            at += next;
        }
    }
}

fn fsync(_: *anyopaque, h: u64, data_only: bool) u32 {
    _ = data_only;
    if (FlushFileBuffers(handleOf(openOf(h).fd)) == 0) return E.IO;
    return 0;
}

fn mkdir(ctx: *anyopaque, dir_path: []const u8, name: []const u8, mode: u32) u32 {
    _ = mode;
    const s = shareOf(ctx);
    if (s.read_only) return E.ROFS;
    var dir: i32 = undefined;
    const e = walk(s, dir_path, &dir);
    if (e != 0) return e;
    defer done(s, dir);
    const base = a.dupeSentinel(u8, name, 0) catch return E.NOMEM;
    defer a.free(base);
    if (fw.mkdirAt(.{ .fd = dir, .base = base })) |x| return errnoOf(x);
    return 0;
}

fn symlink(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) u32 {
    return E.PERM;
}

fn link(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) u32 {
    return E.PERM;
}

fn readlink(_: *anyopaque, _: []const u8, _: []u8, _: *usize) u32 {
    return E.INVAL;
}

fn unlink(ctx: *anyopaque, dir_path: []const u8, name: []const u8, is_dir: bool) u32 {
    const s = shareOf(ctx);
    if (s.read_only) return E.ROFS;
    var dir: i32 = undefined;
    const e = walk(s, dir_path, &dir);
    if (e != 0) return e;
    defer done(s, dir);
    const base = a.dupeSentinel(u8, name, 0) catch return E.NOMEM;
    defer a.free(base);
    // The folders of the cache below the name go first: a handle of
    // the cache keeps no folder from its removal, but a new folder of
    // the same name must not find it.
    if (is_dir) dropJoined(s, dir_path, name);
    if (fw.removeAt(.{ .fd = dir, .base = base }, is_dir)) |x| return errnoOf(x);
    return 0;
}

fn rename(ctx: *anyopaque, dir_path: []const u8, name: []const u8, new_dir: []const u8, new_name: []const u8) u32 {
    const s = shareOf(ctx);
    if (s.read_only) return E.ROFS;
    var from: i32 = undefined;
    var e = walk(s, dir_path, &from);
    if (e != 0) return e;
    defer done(s, from);
    var to: i32 = undefined;
    e = walk(s, new_dir, &to);
    if (e != 0) return e;
    defer done(s, to);
    const b1 = a.dupeSentinel(u8, name, 0) catch return E.NOMEM;
    defer a.free(b1);
    const b2 = a.dupeSentinel(u8, new_name, 0) catch return E.NOMEM;
    defer a.free(b2);
    dropJoined(s, dir_path, name);
    dropJoined(s, new_dir, new_name);
    if (fw.renameAt(.{ .fd = from, .base = b1 }, .{ .fd = to, .base = b2 })) |x| return errnoOf(x);
    return 0;
}

fn setattr(ctx: *anyopaque, path: []const u8, sa: ninep.SetAttr) u32 {
    const s = shareOf(ctx);
    const changes = sa.size != null or sa.atime != .keep or sa.mtime != .keep;
    if (!changes) return 0;
    if (s.read_only) return E.ROFS;
    var fd: i32 = undefined;
    const e = if (sa.size != null) openPath(s, path, .write, &fd) else openPath(s, path, .any, &fd);
    if (e != 0) return e;
    defer sys.close(fd);
    var io: IoStatus = .{};
    if (sa.size) |size| {
        const v: i64 = @intCast(size);
        if (NtSetInformationFile(handleOf(fd), &io, &v, 8, class_end_of_file) < 0) return E.IO;
    }
    if (sa.atime != .keep or sa.mtime != .keep) {
        var b: BasicInfo = .{};
        var now_nt: i64 = 0;
        GetSystemTimePreciseAsFileTime(&now_nt);
        b.access = switch (sa.atime) {
            .keep => 0,
            .now => now_nt,
            .at => |t| ntTime(t),
        };
        b.write = switch (sa.mtime) {
            .keep => 0,
            .now => now_nt,
            .at => |t| ntTime(t),
        };
        // A time of 0 in FILE_BASIC_INFORMATION keeps the time.
        if (NtSetInformationFile(handleOf(fd), &io, &b, @sizeOf(BasicInfo), class_basic) < 0) return E.IO;
    }
    return 0;
}

fn statfs(ctx: *anyopaque, out: *ninep.StatFs) u32 {
    const s = shareOf(ctx);
    var io: IoStatus = .{};
    var f: FullSizeInfo = undefined;
    if (NtQueryVolumeInformationFile(handleOf(s.root), &io, &f, @sizeOf(FullSizeInfo), fs_full_size) < 0) return E.IO;
    const unit: u64 = @as(u64, f.sectors_per_unit) * f.bytes_per_sector;
    out.* = .{
        .bsize = @intCast(@min(unit, std.math.maxInt(u32))),
        .blocks = @intCast(f.total),
        .bfree = @intCast(f.actual_free),
        .bavail = @intCast(f.caller_free),
    };
    return 0;
}

/// Drops the cache entries of `dir/name` and below.
fn dropJoined(s: *Share, dir: []const u8, name: []const u8) void {
    var buf: [ninep.max_path]u8 = undefined;
    const p = if (dir.len == 0) name else std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return;
    drop(s, p);
}

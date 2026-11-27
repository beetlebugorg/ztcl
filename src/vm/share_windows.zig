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

/// The folder at `path` below the root, opened one name at a time. The
/// root itself is the descriptor of the share: close the result only
/// when it is not the root.
fn walk(s: *Share, path: []const u8, out: *i32) u32 {
    var cur = s.root;
    if (path.len == 0) {
        out.* = cur;
        return 0;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |name| {
        const r = fw.openAt(cur, name, .dir);
        if (cur != s.root) sys.close(cur);
        switch (r) {
            .fd => |f| cur = f,
            .err => |e| return errnoOf(e),
        }
    }
    out.* = cur;
    return 0;
}

fn done(s: *Share, fd: i32) void {
    if (fd != s.root) sys.close(fd);
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

fn stat(ctx: *anyopaque, path: []const u8, out: *ninep.Attr) u32 {
    const s = shareOf(ctx);
    if (path.len == 0) return attrOf(s.root, out);
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
    return walk(s, path, out);
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

fn close(_: *anyopaque, h: u64) void {
    const o = openOf(h);
    sys.close(o.fd);
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

fn readdir(_: *anyopaque, h: u64, off: u64, sink: ninep.DirSink) u32 {
    const o = openOf(h);
    var buf: [16384]u8 align(8) = undefined;
    var index: u64 = 0;
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
            if (index >= off) {
                var wide: [256]u16 = undefined;
                const count = @min(len / 2, wide.len);
                for (0..count) |i| wide[i] = units[i];
                var name: [1024]u8 = undefined;
                if (std.unicode.utf16LeToUtf8(&name, wide[0..count])) |nl| {
                    // DT_DIR 4, DT_LNK 10, DT_REG 8.
                    const kind: u8 = if (attrs & attr_reparse != 0) 10 else if (attrs & attr_directory != 0) 4 else 8;
                    if (!sink.put(sink.ctx, .{ .ino = id, .next = index + 1, .kind = kind, .name = name[0..nl] })) return 0;
                } else |_| {}
            }
            index += 1;
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

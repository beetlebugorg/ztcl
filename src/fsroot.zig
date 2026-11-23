//! The folder jail of the optional `file` and channel commands.
//!
//! The embedder gives one root folder. A script sees it as `/`. A path
//! is normalized as text, and a `..` above the root is an error. Each
//! open then uses `openat2` with RESOLVE_BENEATH, RESOLVE_NO_SYMLINKS,
//! and RESOLVE_NO_MAGICLINKS, so the kernel refuses a symlink or an
//! escape in any component, also when another process changes the tree.
//! A kernel with no `openat2` gives an error, so the check fails closed.
//! Other operations run on a descriptor of the parent folder, on the
//! last name, with no symlink followed.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const Interp = interp.Interp;
const Error = interp.Error;
const sys = @import("sys.zig");
const linux = std.os.linux;

pub const supported = builtin.os.tag == .linux;

const resolve_flags: u64 = 2 | 4 | 8; // NO_MAGICLINKS, NO_SYMLINKS, BENEATH
const statx_mask = linux.STATX.BASIC_STATS;
const OpenHow = extern struct { flags: u64, mode: u64, resolve: u64 };

pub const State = struct {
    /// The descriptor of the root, or -1.
    fd: i32 = -1,
    /// The current folder, relative to the root, with no leading `/`.
    cwd: []const u8 = "",
    /// The host path of the root. `exec` uses it to find a program
    /// that a script names with a path.
    path: []const u8 = "",
};

/// Opens the root. The runner calls it. Later paths stay below it.
pub fn setRoot(it: *Interp, path: []const u8) !void {
    if (comptime !supported) return error.BadRoot;
    const z = try it.alloc().dupeZ(u8, path);
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .DIRECTORY = true, .CLOEXEC = true, .PATH = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.BadRoot;
    it.fs.fd = @intCast(rc);
    it.fs.path = try it.alloc().dupe(u8, std.mem.trimEnd(u8, path, "/"));
}

pub fn posixError(it: *Interp, e: sys.Errno, what: []const u8) Error {
    if (comptime !supported) return it.failCode("POSIX EACCES {permission denied}", "{s}permission denied", .{what});
    const name: []const u8, const text: []const u8 = switch (e) {
        .NOENT => .{ "ENOENT", "no such file or directory" },
        .ACCES, .PERM, .XDEV, .LOOP => .{ "EACCES", "permission denied" },
        .EXIST => .{ "EEXIST", "file already exists" },
        .NOTDIR => .{ "ENOTDIR", "not a directory" },
        .ISDIR => .{ "EISDIR", "illegal operation on a directory" },
        .NOTEMPTY => .{ "ENOTEMPTY", "file already exists" },
        .INVAL => .{ "EINVAL", "invalid argument" },
        .NAMETOOLONG => .{ "ENAMETOOLONG", "file name too long" },
        .NOSYS => .{ "ENOSYS", "function not implemented" },
        else => .{ "EIO", "input/output error" },
    };
    const code = try std.fmt.allocPrint(it.alloc(), "POSIX {s} {{{s}}}", .{ name, text });
    return it.failCode(code, "{s}{s}", .{ what, text });
}

/// The normal form of a path: relative to the root, with no `.`, `..`,
/// or empty parts. Gives null for a path above the root.
pub fn normal(it: *Interp, path: []const u8) Error!?[]const u8 {
    const a = it.alloc();
    var parts: std.ArrayList([]const u8) = .empty;
    const absolute = path.len > 0 and path[0] == '/';
    if (!absolute and it.fs.cwd.len > 0) {
        var c = std.mem.tokenizeScalar(u8, it.fs.cwd, '/');
        while (c.next()) |w| try parts.append(a, w);
    }
    var iter = std.mem.tokenizeScalar(u8, path, '/');
    while (iter.next()) |w| {
        if (std.mem.indexOfScalar(u8, w, 0) != null) return null;
        if (std.mem.eql(u8, w, ".")) continue;
        if (std.mem.eql(u8, w, "..")) {
            if (parts.items.len == 0) return null;
            parts.items.len -= 1;
            continue;
        }
        try parts.append(a, w);
    }
    return try std.mem.join(a, "/", parts.items);
}

fn escaped(it: *Interp, path: []const u8) Error {
    return it.failCode("POSIX EACCES {permission denied}", "couldn't access \"{s}\": permission denied", .{path});
}

/// The Linux open flags, with close-on-exec.
pub fn hostFlags(flags: sys.OpenFlags) linux.O {
    return .{
        .ACCMODE = switch (flags.access) {
            .read => .RDONLY,
            .write => .WRONLY,
            .read_write => .RDWR,
        },
        .CREAT = flags.create,
        .EXCL = flags.exclusive,
        .TRUNC = flags.truncate,
        .APPEND = flags.append,
        .DIRECTORY = flags.directory,
        .PATH = flags.path_only,
        .CLOEXEC = true,
    };
}

/// Opens a normal path below the root. Gives the descriptor or an errno.
pub fn openRel(it: *Interp, rel: []const u8, flags: sys.OpenFlags, mode: u32) Error!union(enum) { fd: i32, err: sys.Errno } {
    // With no jail for this target, each open is an error.
    if (comptime !supported) return it.fail("the file system is not available on this target", .{});
    if (it.fs.fd < 0) return it.fail("the embedder gave no root folder", .{});
    const z = try it.alloc().dupeZ(u8, if (rel.len == 0) "." else rel);
    const f = hostFlags(flags);
    var how: OpenHow = .{ .flags = @as(u32, @bitCast(f)), .mode = if (f.CREAT) mode else 0, .resolve = resolve_flags };
    const rc = linux.syscall4(.openat2, @as(usize, @bitCast(@as(isize, it.fs.fd))), @intFromPtr(z.ptr), @intFromPtr(&how), @sizeOf(OpenHow));
    const e = linux.errno(rc);
    if (e != .SUCCESS) return .{ .err = e };
    return .{ .fd = @intCast(rc) };
}

pub const Parent = struct { fd: i32, base: [:0]const u8 };

/// A descriptor of the parent folder and the last name of a normal path.
pub fn parentOf(it: *Interp, rel: []const u8) Error!union(enum) { ok: Parent, err: linux.E } {
    const cut = std.mem.lastIndexOfScalar(u8, rel, '/');
    const dir = if (cut) |c| rel[0..c] else "";
    const base = if (cut) |c| rel[c + 1 ..] else rel;
    if (base.len == 0) return .{ .err = .ACCES };
    switch (try openRel(it, dir, .{ .directory = true, .path_only = true }, 0)) {
        .fd => |fd| return .{ .ok = .{ .fd = fd, .base = try it.alloc().dupeZ(u8, base) } },
        .err => |e| return .{ .err = e },
    }
}

pub const Info = struct { mode: u32, size: u64, mtime: i64, atime: i64, ctime: i64, ino: u64, nlink: u32, uid: u32, gid: u32 };

/// The data of a path. A symlink is reported as a symlink.
pub fn stat(it: *Interp, rel: []const u8) Error!union(enum) { ok: Info, err: linux.E } {
    var st: linux.Statx = undefined;
    var rc: usize = undefined;
    if (rel.len == 0) {
        rc = linux.statx(it.fs.fd, "", 0x1000, statx_mask, &st);
    } else {
        const p = switch (try parentOf(it, rel)) {
            .ok => |x| x,
            .err => |e| return .{ .err = e },
        };
        defer _ = linux.close(p.fd);
        rc = linux.statx(p.fd, p.base, 0x100, statx_mask, &st);
    }
    const e = linux.errno(rc);
    if (e != .SUCCESS) return .{ .err = e };
    return .{ .ok = .{ .mode = st.mode, .size = st.size, .mtime = st.mtime.sec, .atime = st.atime.sec, .ctime = st.ctime.sec, .ino = st.ino, .nlink = st.nlink, .uid = st.uid, .gid = st.gid } };
}

pub fn isDir(mode: u32) bool {
    return mode & 0o170000 == 0o040000;
}

pub fn isFile(mode: u32) bool {
    return mode & 0o170000 == 0o100000;
}

/// The names in a folder, with no `.` or `..`.
pub fn listDir(it: *Interp, rel: []const u8) Error!union(enum) { ok: []const []const u8, err: linux.E } {
    const fd = switch (try openRel(it, rel, .{ .directory = true }, 0)) {
        .fd => |x| x,
        .err => |e| return .{ .err = e },
    };
    defer _ = linux.close(fd);
    const a = it.alloc();
    var out: std.ArrayList([]const u8) = .empty;
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        const e = linux.errno(n);
        if (e != .SUCCESS) return .{ .err = e };
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const reclen = std.mem.readInt(u16, buf[off + 16..][0..2], .little);
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf[off + 19])), 0);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) try out.append(a, try a.dupe(u8, name));
            off += reclen;
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return .{ .ok = out.items };
}

/// Normalizes a path or gives the error of an escape.
pub fn need(it: *Interp, path: []const u8) Error![]const u8 {
    return (try normal(it, path)) orelse escaped(it, path);
}

//! The folder jail of the optional `file` and channel commands.
//!
//! The embedder gives one root folder. A script sees it as `/`. A path
//! is normalized as text, and a `..` above the root is an error. Each
//! open then uses `openat2` with RESOLVE_BENEATH, RESOLVE_NO_SYMLINKS,
//! and RESOLVE_NO_MAGICLINKS, so the kernel refuses a symlink or an
//! escape in any component, also when another process changes the tree.
//! A kernel with no `openat2` gives an error, so the check fails closed.
//! macOS has no `openat2`. There each open walks the path from the root
//! descriptor, one name at a time, with O_NOFOLLOW, and no system call
//! gets a path of more than one name. macOS refuses O_NOFOLLOW together
//! with O_NOFOLLOW_ANY (EINVAL), and for one name they are equal. A folder
//! that another process swaps for a symlink gives ELOOP or ENOTDIR.
//!
//! One limit needs a process outside the sandbox with write access to the
//! root. If that process moves a folder out of the root after the walk
//! opens it, the next name of the walk resolves in the moved folder.
//! Other operations run on a descriptor of the parent folder, on the
//! last name, with no symlink followed. `fsroot_windows.zig` has the
//! Windows form.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const Interp = interp.Interp;
const Error = interp.Error;
const sys = @import("sys.zig");
const linux = sys.os;

const on_mac = builtin.os.tag == .macos;
const on_win = builtin.os.tag == .windows and builtin.cpu.arch == .x86_64;
const win = @import("fsroot_windows.zig");
const on_wasi = builtin.os.tag == .wasi;
/// The command component of WASI 0.3.2 uses `fsroot_wasi3.zig`.
const wfs = if (sys.wasi_p3) @import("fsroot_wasi3.zig") else @import("fsroot_wasi.zig");
/// ARM64 Windows stays off until its tests can run.
pub const supported = builtin.os.tag == .linux or on_mac or on_win or on_wasi;

// The macOS open flag that `std.c.O` does not name.
const o_exec: u32 = 0x40000000;

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
    /// The real path of the root on Windows, for the second check.
    final: []const u16 = &.{},
    /// Host mode: real paths of the host, with no root and no jail, as in
    /// tclsh. `cwd` is then an absolute path of the host.
    host: bool = false,
};

/// Turns on host mode: the file commands use the real paths of the host
/// and follow symlinks, as tclsh does. The current folder starts as the
/// current folder of the process. The `ztcl` and `ztk` programs call it
/// by default, and an embedder only by choice. WASI has only the folders
/// that the runtime opens, so it has no host mode.
pub fn setHost(it: *Interp) !void {
    if (comptime on_wasi or !supported) return error.BadRoot;
    it.fs.cwd = try processCwd(it.alloc());
    it.fs.host = true;
}

/// The current folder of the process, in the form of `normal` in host mode.
fn processCwd(a: std.mem.Allocator) ![]const u8 {
    if (comptime on_win) {
        const wide = try win.currentFolder(a);
        const text = try std.unicode.utf16LeToUtf8Alloc(a, wide);
        return (try joinWindows(a, "C:/", text)) orelse error.BadRoot;
    }
    var buf: [4096]u8 = undefined;
    if (comptime on_mac) {
        if (std.c.getcwd(&buf, buf.len) == null) return error.BadRoot;
    } else {
        const n = linux.getcwd(&buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.BadRoot;
    }
    return a.dupe(u8, std.mem.sliceTo(&buf, 0));
}

/// The parts of a path between `/`, with `.` dropped and `..` taking off
/// the last part. A `..` at the top stays at the top, as on the host.
fn fold(a: std.mem.Allocator, parts: *std.ArrayList([]const u8), path: []const u8) !void {
    var iter = std.mem.tokenizeScalar(u8, path, '/');
    while (iter.next()) |w| {
        if (std.mem.eql(u8, w, ".")) continue;
        if (std.mem.eql(u8, w, "..")) {
            if (parts.items.len > 0) parts.items.len -= 1;
            continue;
        }
        try parts.append(a, w);
    }
}

/// An absolute host path of POSIX for `path` from the folder `cwd`: `/`
/// and the parts. A NUL byte gives null.
pub fn joinPosix(a: std.mem.Allocator, cwd: []const u8, path: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    var parts: std.ArrayList([]const u8) = .empty;
    if (path.len == 0 or path[0] != '/') try fold(a, &parts, cwd);
    try fold(a, &parts, path);
    const body = try std.mem.join(a, "/", parts.items);
    return try std.fmt.allocPrint(a, "/{s}", .{body});
}

/// An absolute host path of Windows for `path` from the folder `cwd`,
/// with `/` between the parts: `C:/a/b` for a drive, `//server/share/a`
/// for a UNC path. `\` is a separator. A path that starts with `/` is on
/// the drive or the share of `cwd`. A drive with no `/` after it
/// (`C:a`) counts from the top of that drive. A NUL byte gives null.
pub fn joinWindows(a: std.mem.Allocator, cwd: []const u8, path_in: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, path_in, 0) != null) return null;
    const path = try a.dupe(u8, path_in);
    for (path) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    var parts: std.ArrayList([]const u8) = .empty;
    var prefix: []const u8 = undefined;
    var rest: []const u8 = path;
    if (prefixOf(path)) |p| {
        prefix = p;
        rest = path[p.len..];
    } else {
        const cp = prefixOf(cwd) orelse return null;
        prefix = cp;
        if (path.len == 0 or path[0] != '/') try fold(a, &parts, cwd[cp.len..]);
    }
    try fold(a, &parts, rest);
    const body = try std.mem.join(a, "/", parts.items);
    return try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, body });
}

/// The drive (`C:`) or the UNC share (`//server/share`) at the start of a
/// path with `/` separators, or null.
fn prefixOf(path: []const u8) ?[]const u8 {
    if (path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0])) return path[0..2];
    if (path.len > 2 and path[0] == '/' and path[1] == '/' and path[2] != '/') {
        const server_end = std.mem.indexOfScalarPos(u8, path, 2, '/') orelse return null;
        const share_end = std.mem.indexOfScalarPos(u8, path, server_end + 1, '/') orelse path.len;
        if (share_end == server_end + 1) return null;
        return path[0..share_end];
    }
    return null;
}

/// The drive or the share at the start of a path in host mode on
/// Windows (`C:` of `C:/a`), or null. `glob` starts its walk there.
pub fn hostPrefix(it: *const Interp, path: []const u8) ?[]const u8 {
    if (!it.fs.host or !on_win) return null;
    return prefixOf(path);
}

/// The path of a normal path for a script: in host mode the path itself,
/// and in the jail `/` and the path below the root.
pub fn shown(it: *Interp, rel: []const u8) Error![]const u8 {
    if (it.fs.host) return rel;
    return std.fmt.allocPrint(it.alloc(), "/{s}", .{rel});
}

/// Opens the root. The runner calls it. Later paths stay below it.
pub fn setRoot(it: *Interp, path: []const u8) !void {
    // A root ends host mode, and the current folder is the root.
    it.fs.host = false;
    it.fs.cwd = "";
    if (comptime on_win) return win.setRoot(it, path);
    if (comptime on_wasi) return wfs.setRoot(it, path);
    if (comptime !supported) return error.BadRoot;
    const z = try it.alloc().dupeSentinel(u8, path, 0);
    const rc = if (comptime on_mac)
        linux.openat(linux.AT.FDCWD, z, searchFlags(), 0)
    else
        linux.openat(linux.AT.FDCWD, z, .{ .DIRECTORY = true, .CLOEXEC = true, .PATH = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.BadRoot;
    it.fs.fd = @intCast(rc);
    it.fs.path = try it.alloc().dupe(u8, std.mem.trimEnd(u8, path, "/"));
}

pub fn posixError(it: *Interp, e: sys.Errno, what: []const u8) Error {
    if (comptime !supported) return it.failCode("POSIX EIO {input/output error}", "{s}input/output error", .{what});
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
    // In host mode the normal form is the absolute path of the host.
    if (it.fs.host) {
        // An empty path names no file, as in Tcl: it is not the current folder.
        if (path.len == 0) return "";
        // As in Tcl 8.6, ~ at the start is the folder of $env(HOME).
        var p = path;
        if (p.len > 0 and p[0] == '~' and (p.len == 1 or p[1] == '/')) {
            if (it.getVar("::env(HOME)")) |home| {
                p = try std.mem.concat(a, u8, &.{ try it.str(home), p[1..] });
            } else |_| {}
        }
        return if (comptime on_win) try joinWindows(a, it.fs.cwd, p) else try joinPosix(a, it.fs.cwd, p);
    }
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

/// A descriptor of a folder for lookups only, on macOS (O_SEARCH). The
/// root itself can be a symlink, as the embedder names it.
fn searchFlags() linux.O {
    const base: u32 = @bitCast(linux.O{ .DIRECTORY = true, .CLOEXEC = true });
    return @bitCast(base | o_exec);
}

/// The macOS flags of the last name of a path. No symlink is followed.
fn lastFlags(flags: sys.OpenFlags) linux.O {
    const f: linux.O = .{
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
        .NOFOLLOW = true,
        .CLOEXEC = true,
    };
    var bits: u32 = @bitCast(f);
    if (flags.path_only and flags.directory) bits |= o_exec;
    return @bitCast(bits);
}

/// A name that is not one plain entry of a folder: empty, `.`, `..`, or
/// with a NUL byte. The walk and `parentOf` check it without `normal`.
fn badName(w: []const u8) bool {
    return w.len == 0 or std.mem.eql(u8, w, ".") or std.mem.eql(u8, w, "..") or std.mem.indexOfScalar(u8, w, 0) != null;
}

/// Opens a normal path on macOS, one name at a time from the root. A name
/// that `badName` refuses is an error here too, so this walk does not
/// depend on `normal`.
fn walk(root: i32, rel: []const u8, flags: sys.OpenFlags, mode: u32) union(enum) { fd: i32, err: sys.Errno } {
    const last = lastFlags(flags);
    const open_mode: u16 = if (flags.create) @intCast(mode & 0o7777) else 0;
    if (rel.len == 0) {
        const rc = linux.openat(root, ".", last, open_mode);
        const e = linux.errno(rc);
        return if (e == .SUCCESS) .{ .fd = @intCast(rc) } else .{ .err = e };
    }
    const folder: linux.O = blk: {
        const f: u32 = @bitCast(searchFlags());
        const n: u32 = @bitCast(linux.O{ .NOFOLLOW = true });
        break :blk @bitCast(f | n);
    };
    var name: [1025]u8 = undefined;
    var cur = root;
    defer if (cur != root) {
        _ = linux.close(cur);
    };
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |w| {
        if (badName(w)) return .{ .err = .ACCES };
        if (w.len >= name.len) return .{ .err = .NAMETOOLONG };
        @memcpy(name[0..w.len], w);
        name[w.len] = 0;
        const z: [:0]const u8 = name[0..w.len :0];
        if (parts.peek() == null) {
            const rc = linux.openat(cur, z, last, open_mode);
            const e = linux.errno(rc);
            return if (e == .SUCCESS) .{ .fd = @intCast(rc) } else .{ .err = e };
        }
        const rc = linux.openat(cur, z, folder, 0);
        const e = linux.errno(rc);
        if (e != .SUCCESS) return .{ .err = e };
        if (cur != root) _ = linux.close(cur);
        cur = @intCast(rc);
    }
    return .{ .err = .ACCES };
}

/// The open flags of the host, with close-on-exec.
pub fn hostFlags(flags: sys.OpenFlags) linux.O {
    if (comptime on_mac) return lastFlags(flags);
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
pub const OpenResult = union(enum) { fd: i32, err: sys.Errno };

pub fn openRel(it: *Interp, rel: []const u8, flags: sys.OpenFlags, mode: u32) Error!OpenResult {
    if (it.fs.host) return hostOpen(it, rel, flags, mode);
    if (comptime on_win) return win.openRel(it, rel, flags, mode);
    if (comptime on_wasi) return wfs.openRel(it, rel, flags, mode);
    // With no jail for this target, each open is an error.
    if (comptime !supported) return it.fail("the file system is not available on this target", .{});
    if (it.fs.fd < 0) return it.fail("the embedder gave no root folder", .{});
    if (comptime on_mac) return switch (walk(it.fs.fd, rel, flags, mode)) {
        .fd => |fd| .{ .fd = fd },
        .err => |e| .{ .err = e },
    };
    const z = try it.alloc().dupeSentinel(u8, if (rel.len == 0) "." else rel, 0);
    const f = hostFlags(flags);
    var how: OpenHow = .{ .flags = @as(u32, @bitCast(f)), .mode = if (f.CREAT) mode else 0, .resolve = resolve_flags };
    const rc = linux.syscall4(.openat2, @as(usize, @bitCast(@as(isize, it.fs.fd))), @intFromPtr(z.ptr), @intFromPtr(&how), @sizeOf(OpenHow));
    const e = linux.errno(rc);
    if (e != .SUCCESS) return .{ .err = e };
    return .{ .fd = @intCast(rc) };
}

/// The flags of an open in host mode, which follows symlinks.
fn followFlags(flags: sys.OpenFlags) linux.O {
    var f = hostFlags(flags);
    if (comptime on_mac) f.NOFOLLOW = false;
    return f;
}

/// Opens an absolute host path, with each symlink followed.
fn hostOpen(it: *Interp, path: []const u8, flags: sys.OpenFlags, mode: u32) Error!OpenResult {
    if (comptime on_win) return win.hostOpen(it, path, flags, mode);
    if (comptime on_wasi or !supported) return it.fail("the file system is not available on this target", .{});
    const z = try it.alloc().dupeSentinel(u8, path, 0);
    const f = followFlags(flags);
    const rc = linux.openat(linux.AT.FDCWD, z, f, if (f.CREAT) @intCast(mode) else 0);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return .{ .err = e };
    return .{ .fd = @intCast(rc) };
}

pub const Parent = struct { fd: i32, base: [:0]const u8 };

/// A descriptor of the parent folder and the last name of a normal path.
pub const ParentResult = union(enum) { ok: Parent, err: sys.Errno };

pub fn parentOf(it: *Interp, rel: []const u8) Error!ParentResult {
    if (it.fs.host) {
        if (comptime on_win) return win.hostParent(it, rel);
        // The full path from the current folder of the process: the calls
        // at a parent take AT_FDCWD and an absolute path as they take a
        // descriptor and a name, and a close of AT_FDCWD has no effect.
        return .{ .ok = .{ .fd = linux.AT.FDCWD, .base = try it.alloc().dupeSentinel(u8, rel, 0) } };
    }
    if (comptime on_win) return win.parentOf(it, rel);
    const cut = std.mem.lastIndexOfScalar(u8, rel, '/');
    const dir = if (cut) |c| rel[0..c] else "";
    const base = if (cut) |c| rel[c + 1 ..] else rel;
    if (badName(base)) return .{ .err = .ACCES };
    switch (try openRel(it, dir, .{ .directory = true, .path_only = true }, 0)) {
        .fd => |fd| return .{ .ok = .{ .fd = fd, .base = try it.alloc().dupeSentinel(u8, base, 0) } },
        .err => |e| return .{ .err = e },
    }
}

pub const Info = struct {
    mode: u32,
    size: u64,
    mtime: i64,
    atime: i64,
    ctime: i64,
    ino: u64,
    nlink: u32,
    uid: u32,
    gid: u32,
    /// The device of the file. With `ino`, it names one file.
    dev: u64 = 0,

    /// True when both name the same file.
    pub fn same(x: Info, y: Info) bool {
        return x.ino == y.ino and x.dev == y.dev;
    }
};

pub const StatResult = union(enum) { ok: Info, err: sys.Errno };

/// The data of a path. A symlink is reported as a symlink.
pub fn stat(it: *Interp, rel: []const u8) Error!StatResult {
    if (it.fs.host and comptime on_win) return win.hostStat(it, rel);
    if (comptime on_win) return win.stat(it, rel);
    if (comptime on_wasi) return wfs.stat(it, rel);
    if (comptime on_mac) {
        var st: std.c.Stat = undefined;
        var src: usize = undefined;
        if (rel.len == 0) {
            src = linux.statFd(it.fs.fd, &st);
        } else {
            const p = switch (try parentOf(it, rel)) {
                .ok => |x| x,
                .err => |e| return .{ .err = e },
            };
            defer _ = linux.close(p.fd);
            src = linux.statAt(p.fd, p.base, &st);
        }
        const se = linux.errno(src);
        if (se != .SUCCESS) return .{ .err = se };
        return .{ .ok = .{
            .mode = st.mode,
            .size = @intCast(st.size),
            .mtime = st.mtimespec.sec,
            .atime = st.atimespec.sec,
            .ctime = st.ctimespec.sec,
            .ino = st.ino,
            .nlink = st.nlink,
            .uid = st.uid,
            .gid = st.gid,
            .dev = @bitCast(@as(i64, st.dev)),
        } };
    }
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
        // The jail follows no symlink (AT_SYMLINK_NOFOLLOW), and host mode
        // follows them, as the stat of tclsh does.
        rc = linux.statx(p.fd, p.base, if (it.fs.host) 0 else 0x100, statx_mask, &st);
    }
    const e = linux.errno(rc);
    if (e != .SUCCESS) return .{ .err = e };
    return .{ .ok = .{ .mode = st.mode, .size = st.size, .mtime = st.mtime.sec, .atime = st.atime.sec, .ctime = st.ctime.sec, .ino = st.ino, .nlink = st.nlink, .uid = st.uid, .gid = st.gid, .dev = (@as(u64, st.dev_major) << 32) | st.dev_minor } };
}

pub fn isDir(mode: u32) bool {
    return mode & 0o170000 == 0o040000;
}

pub fn isFile(mode: u32) bool {
    return mode & 0o170000 == 0o100000;
}

pub const ListResult = union(enum) { ok: []const []const u8, err: sys.Errno };

/// The names in a folder, with no `.` or `..`.
pub fn listDir(it: *Interp, rel: []const u8) Error!ListResult {
    if (comptime on_win) return win.listDir(it, rel);
    if (comptime on_wasi) return wfs.listDir(it, rel);
    const fd = switch (try openRel(it, rel, .{ .directory = true }, 0)) {
        .fd => |x| x,
        .err => |e| return .{ .err = e },
    };
    const a = it.alloc();
    var out: std.ArrayList([]const u8) = .empty;
    if (comptime on_mac) {
        // `closedir` closes the descriptor.
        const dir = sys.os.openDir(fd) orelse {
            _ = linux.close(fd);
            return .{ .err = .IO };
        };
        defer _ = std.c.closedir(dir);
        while (linux.nextName(dir)) |name| {
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) try out.append(a, try a.dupe(u8, name));
        }
        std.mem.sort([]const u8, out.items, {}, nameLess);
        return .{ .ok = out.items };
    }
    defer _ = linux.close(fd);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        const e = linux.errno(n);
        if (e != .SUCCESS) return .{ .err = e };
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf[off + 19])), 0);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) try out.append(a, try a.dupe(u8, name));
            off += reclen;
        }
    }
    std.mem.sort([]const u8, out.items, {}, nameLess);
    return .{ .ok = out.items };
}

fn nameLess(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// Gives a child interpreter its own descriptor of the root.
pub fn shareRoot(it: *const Interp, child: *Interp) std.mem.Allocator.Error!void {
    // A child of a host-mode parent is in host mode too. A later setRoot of
    // the embedder can still put it in a jail.
    child.fs.host = it.fs.host;
    if (comptime on_win) return win.shareRoot(it, child);
    if (comptime on_wasi) return wfs.shareRoot(it, child);
    if (it.fs.fd >= 0) {
        const rc = linux.fcntl(it.fs.fd, linux.F.DUPFD_CLOEXEC, 3);
        if (linux.errno(rc) == .SUCCESS) child.fs.fd = @intCast(rc);
    }
}

/// Deletes the last name of a parent. Gives null or the error.
pub fn removeAt(p: Parent, dir: bool) ?sys.Errno {
    if (comptime on_win) return win.removeAt(p, dir);
    if (comptime on_wasi) return wfs.removeAt(p, dir);
    const e = linux.errno(linux.unlinkat(p.fd, p.base, if (dir) linux.AT.REMOVEDIR else 0));
    return if (e == .SUCCESS) null else e;
}

/// Makes a folder at the last name of a parent.
pub fn mkdirAt(p: Parent) ?sys.Errno {
    if (comptime on_win) return win.mkdirAt(p);
    if (comptime on_wasi) return wfs.mkdirAt(p);
    const e = linux.errno(linux.mkdirat(p.fd, p.base, 0o777));
    return if (e == .SUCCESS) null else e;
}

/// Moves a name between two parents below the root.
pub fn renameAt(p: Parent, q: Parent) ?sys.Errno {
    if (comptime on_win) return win.renameAt(p, q);
    if (comptime on_wasi) return wfs.renameAt(p, q);
    const e = linux.errno(linux.renameat(p.fd, p.base, q.fd, q.base));
    return if (e == .SUCCESS) null else e;
}

/// Normalizes a path or gives the error of an escape.
pub fn need(it: *Interp, path: []const u8) Error![]const u8 {
    return (try normal(it, path)) orelse escaped(it, path);
}

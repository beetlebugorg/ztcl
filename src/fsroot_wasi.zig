//! The WASI preview 1 form of the folder jail of `fsroot.zig`.
//!
//! The root is a descriptor below a preopen of the host. `setRoot` finds
//! the preopen with the longest name that is a prefix of the root path
//! at a `/`, and opens the rest of the path below it. `fsroot.normal`
//! checks each path as text first, so a `..` above the root is an error
//! before a call. Each open then walks the path from the root
//! descriptor, one name at a time, with no symlink followed, as on
//! macOS. A symlink in any component gives an error, so no open leaves
//! the root. The host checks each path against the preopen too.
//!
//! WASI has no mode bits, users, or groups. `stat` gives 0o755 for a
//! folder, 0o644 for other files, and 0 for the user and the group.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const wasi = std.os.wasi;
const interp = @import("interp.zig");
const Interp = interp.Interp;
const Error = interp.Error;
const sys = @import("sys.zig");
const fsroot = @import("fsroot.zig");

const E = wasi.errno_t;

/// The rights of a folder descriptor.
const dir_rights: wasi.rights_t = .{
    .FD_FILESTAT_GET = true,
    .FD_FDSTAT_SET_FLAGS = true,
    .FD_READDIR = true,
    .PATH_CREATE_DIRECTORY = true,
    .PATH_CREATE_FILE = true,
    .PATH_OPEN = true,
    .PATH_READLINK = true,
    .PATH_RENAME_SOURCE = true,
    .PATH_RENAME_TARGET = true,
    .PATH_FILESTAT_GET = true,
    .PATH_FILESTAT_SET_SIZE = true,
    .PATH_FILESTAT_SET_TIMES = true,
    .PATH_SYMLINK = true,
    .PATH_REMOVE_DIRECTORY = true,
    .PATH_UNLINK_FILE = true,
};

/// The rights of a file descriptor for the access of `flags`.
fn fileRights(flags: sys.OpenFlags) wasi.rights_t {
    var r: wasi.rights_t = .{ .FD_FILESTAT_GET = true, .FD_FDSTAT_SET_FLAGS = true, .FD_SEEK = true, .FD_TELL = true, .POLL_FD_READWRITE = true };
    if (flags.access != .write) r.FD_READ = true;
    if (flags.access != .read) {
        r.FD_WRITE = true;
        r.FD_DATASYNC = true;
        r.FD_SYNC = true;
        r.FD_FILESTAT_SET_SIZE = true;
        r.FD_FILESTAT_SET_TIMES = true;
    }
    return r;
}

/// The error of the jail for an error of the host. The host gives
/// NOTCAPABLE for a path outside its preopen.
fn jailError(e: E) E {
    return if (e == .NOTCAPABLE) .ACCES else e;
}

fn openAt(dir: i32, name: []const u8, oflags: wasi.oflags_t, rights: wasi.rights_t, fdflags: wasi.fdflags_t) union(enum) { fd: i32, err: E } {
    var fd: i32 = -1;
    while (true) {
        const inheriting = if (oflags.DIRECTORY) dir_rights else wasi.rights_t{};
        switch (wasi.path_open(dir, .{}, name.ptr, name.len, oflags, rights, inheriting, fdflags, &fd)) {
            .SUCCESS => return .{ .fd = fd },
            .INTR => continue,
            else => |e| return .{ .err = jailError(e) },
        }
    }
}

/// The preopen with the longest name that is a prefix of `path` at a
/// `/`, and the rest of the path. Null when no preopen matches.
fn preopenOf(path: []const u8) ?struct { fd: i32, rest: []const u8 } {
    var best: ?i32 = null;
    var best_len: usize = 0;
    var name: [4096]u8 = undefined;
    var fd: i32 = 3;
    while (true) : (fd += 1) {
        var ps: wasi.prestat_t = undefined;
        if (wasi.fd_prestat_get(fd, &ps) != .SUCCESS) break;
        const n = ps.u.dir.pr_name_len;
        if (n > name.len or wasi.fd_prestat_dir_name(fd, &name, n) != .SUCCESS) continue;
        const base = std.mem.trimEnd(u8, name[0..n], "/");
        if (!std.mem.startsWith(u8, path, base)) continue;
        if (path.len > base.len and path[base.len] != '/') continue;
        if (best != null and base.len <= best_len) continue;
        best = fd;
        best_len = base.len;
    }
    const b = best orelse return null;
    return .{ .fd = b, .rest = std.mem.trimStart(u8, path[best_len..], "/") };
}

pub fn setRoot(it: *Interp, path: []const u8) !void {
    const p = preopenOf(path) orelse return error.BadRoot;
    const rest = if (p.rest.len == 0) "." else p.rest;
    switch (openAt(p.fd, rest, .{ .DIRECTORY = true }, dir_rights, .{})) {
        .fd => |fd| it.fs.fd = fd,
        .err => return error.BadRoot,
    }
    it.fs.path = try it.alloc().dupe(u8, std.mem.trimEnd(u8, path, "/"));
}

/// Opens a normal path below the root, one name at a time from the root.
pub fn openRel(it: *Interp, rel: []const u8, flags: sys.OpenFlags, mode: u32) Error!fsroot.OpenResult {
    _ = mode;
    if (it.fs.fd < 0) return it.fail("the embedder gave no root folder", .{});
    const want_dir = flags.directory or flags.path_only;
    const last_oflags: wasi.oflags_t = .{ .CREAT = flags.create, .EXCL = flags.exclusive, .TRUNC = flags.truncate, .DIRECTORY = flags.directory };
    const last_rights = if (want_dir) dir_rights else fileRights(flags);
    const last_fdflags: wasi.fdflags_t = .{ .APPEND = flags.append };
    if (rel.len == 0) return switch (openAt(it.fs.fd, ".", last_oflags, last_rights, last_fdflags)) {
        .fd => |fd| .{ .fd = fd },
        .err => |e| .{ .err = e },
    };
    var cur = it.fs.fd;
    defer if (cur != it.fs.fd) {
        _ = wasi.fd_close(cur);
    };
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |w| {
        if (w.len == 0 or std.mem.eql(u8, w, ".") or std.mem.eql(u8, w, "..") or std.mem.indexOfScalar(u8, w, 0) != null) return .{ .err = .ACCES };
        if (parts.peek() == null) return switch (openAt(cur, w, last_oflags, last_rights, last_fdflags)) {
            .fd => |fd| .{ .fd = fd },
            .err => |e| .{ .err = e },
        };
        switch (openAt(cur, w, .{ .DIRECTORY = true }, dir_rights, .{})) {
            .fd => |fd| {
                if (cur != it.fs.fd) _ = wasi.fd_close(cur);
                cur = fd;
            },
            .err => |e| return .{ .err = e },
        }
    }
    return .{ .err = .ACCES };
}

fn info(st: wasi.filestat_t) fsroot.Info {
    const kind: u32 = switch (st.filetype) {
        .DIRECTORY => 0o040000,
        .REGULAR_FILE => 0o100000,
        .SYMBOLIC_LINK => 0o120000,
        .CHARACTER_DEVICE => 0o020000,
        .BLOCK_DEVICE => 0o060000,
        .SOCKET_STREAM, .SOCKET_DGRAM => 0o140000,
        else => 0,
    };
    const perm: u32 = if (st.filetype == .DIRECTORY) 0o755 else 0o644;
    const sec = std.time.ns_per_s;
    return .{
        .mode = kind | perm,
        .size = st.size,
        .mtime = @intCast(st.mtim / sec),
        .atime = @intCast(st.atim / sec),
        .ctime = @intCast(st.ctim / sec),
        .ino = st.ino,
        .nlink = @intCast(@min(st.nlink, std.math.maxInt(u32))),
        .uid = 0,
        .gid = 0,
        .dev = st.dev,
    };
}

pub fn stat(it: *Interp, rel: []const u8) Error!fsroot.StatResult {
    var st: wasi.filestat_t = undefined;
    if (rel.len == 0) {
        const e = wasi.fd_filestat_get(it.fs.fd, &st);
        if (e != .SUCCESS) return .{ .err = jailError(e) };
        return .{ .ok = info(st) };
    }
    const p = switch (try fsroot.parentOf(it, rel)) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    defer _ = wasi.fd_close(p.fd);
    const e = wasi.path_filestat_get(p.fd, .{}, p.base.ptr, p.base.len, &st);
    if (e != .SUCCESS) return .{ .err = jailError(e) };
    return .{ .ok = info(st) };
}

pub fn listDir(it: *Interp, rel: []const u8) Error!fsroot.ListResult {
    const fd = switch (try openRel(it, rel, .{ .directory = true }, 0)) {
        .fd => |x| x,
        .err => |e| return .{ .err = e },
    };
    defer _ = wasi.fd_close(fd);
    const a = it.alloc();
    var out: std.ArrayList([]const u8) = .empty;
    var buf: [8192]u8 align(8) = undefined;
    var cookie: wasi.dircookie_t = wasi.DIRCOOKIE_START;
    const head = @sizeOf(wasi.dirent_t);
    while (true) {
        var used: usize = 0;
        const e = wasi.fd_readdir(fd, &buf, buf.len, cookie, &used);
        if (e != .SUCCESS) return .{ .err = jailError(e) };
        var off: usize = 0;
        var progress = false;
        while (off + head <= used) {
            var d: wasi.dirent_t = undefined;
            @memcpy(std.mem.asBytes(&d), buf[off..][0..head]);
            // A name that does not fit in the buffer reads again from
            // its cookie with the next call.
            if (off + head + d.namlen > used) break;
            const name = buf[off + head ..][0..d.namlen];
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) try out.append(a, try a.dupe(u8, name));
            cookie = d.next;
            off += head + d.namlen;
            progress = true;
        }
        if (used < buf.len) break;
        if (!progress) return .{ .err = .NAMETOOLONG };
    }
    std.mem.sort([]const u8, out.items, {}, nameLess);
    return .{ .ok = out.items };
}

fn nameLess(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// WASI has no dup, so the child opens the root folder again.
pub fn shareRoot(it: *const Interp, child: *Interp) std.mem.Allocator.Error!void {
    if (it.fs.fd < 0) return;
    switch (openAt(it.fs.fd, ".", .{ .DIRECTORY = true }, dir_rights, .{})) {
        .fd => |fd| child.fs.fd = fd,
        .err => {},
    }
}

pub fn removeAt(p: fsroot.Parent, dir: bool) ?E {
    const e = if (dir) wasi.path_remove_directory(p.fd, p.base.ptr, p.base.len) else wasi.path_unlink_file(p.fd, p.base.ptr, p.base.len);
    return if (e == .SUCCESS) null else jailError(e);
}

pub fn mkdirAt(p: fsroot.Parent) ?E {
    const e = wasi.path_create_directory(p.fd, p.base.ptr, p.base.len);
    return if (e == .SUCCESS) null else jailError(e);
}

pub fn renameAt(p: fsroot.Parent, q: fsroot.Parent) ?E {
    const e = wasi.path_rename(p.fd, p.base.ptr, p.base.len, q.fd, q.base.ptr, q.base.len);
    return if (e == .SUCCESS) null else jailError(e);
}

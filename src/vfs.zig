//! The mounts of zip archives under `//zipfs:/`, and the `zipfs`
//! command.
//!
//! Each interpreter has a table of mounts. A mount has a point (such
//! as `app` for `//zipfs:/app`) and an archive of `zipread.zig`. The
//! commands `open`, `source`, `glob`, and `file` call `find` first,
//! with the path of the script. A path that starts with `//zipfs:/`
//! is a path of the table, and other paths go to the jail of
//! `fsroot.zig` or to the host. `//zipfs:/` is not a path of the jail
//! or of a host, so a mount hides no real file. The lookup is before
//! the jail and the host, so it is the same in both modes of `file`.
//!
//! The mounts are read-only. A path is normalized as text, and a `..`
//! above `//zipfs:/` stays at `//zipfs:/`, as in a real root folder.
//! `read` decompresses an entry whole into memory of the interpreter,
//! so the memory limit applies to the output before the decode runs,
//! and the size in the central header is the limit of the output. A
//! zip bomb stops at the memory limit. Each byte of output is work by
//! the rule of `cmds.chargeWork`.
//!
//! `zipfs mount` of a file reads the file through `fsroot.zig`, so the
//! archive is a file that the script can open. The embedder mounts
//! memory of its own with `mountBytes`, as the payload of a binary of
//! `ztcl build`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const zipread = @import("zipread.zig");
const cmds = @import("cmds.zig");
const value = @import("value.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Cmd = interp.Cmd;
const Error = interp.Error;

pub const root = "//zipfs:/";

pub const Mount = struct {
    /// The point below the root, with no leading or trailing `/`.
    point: []const u8,
    /// The name of the zip file, or the empty string for memory of
    /// the embedder.
    file: []const u8,
    z: zipread.Archive,
};

pub const State = struct {
    mounts: std.ArrayList(Mount) = .empty,
};

pub const Kind = enum { none, file, dir };

/// A path of the table.
pub const Hit = struct {
    /// Null for a folder above each mount, such as `//zipfs:/`.
    m: ?*Mount,
    /// The name in the archive. The empty string is the mount point.
    rel: []const u8,
    /// The normal path, `//zipfs:/` and the parts.
    full: []const u8,
};

/// True when the path is a path of the table.
pub fn isOurs(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "//zipfs:");
}

/// The parts of a path below the root, with `.` and `..` resolved.
fn parts(it: *Interp, path: []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.tokenizeScalar(u8, path["//zipfs:".len..], '/');
    while (iter.next()) |w| {
        if (std.mem.eql(u8, w, ".")) continue;
        if (std.mem.eql(u8, w, "..")) {
            if (out.items.len > 0) out.items.len -= 1;
            continue;
        }
        try out.append(it.alloc(), w);
    }
    return out.items;
}

/// The hit of `path`, or null for a path outside the table.
pub fn find(it: *Interp, path: []const u8) Error!?Hit {
    if (!isOurs(path)) return null;
    const ps = try parts(it, path);
    const joined = try std.mem.join(it.alloc(), "/", ps);
    const full = try std.mem.concat(it.alloc(), u8, &.{ root, joined });
    var best: ?*Mount = null;
    for (it.vfs.mounts.items) |*m| {
        if (under(joined, m.point) and (best == null or m.point.len > best.?.point.len)) best = m;
    }
    if (best) |m| {
        const rel = if (joined.len == m.point.len) "" else joined[m.point.len + 1 ..];
        return .{ .m = m, .rel = rel, .full = full };
    }
    return .{ .m = null, .rel = joined, .full = full };
}

/// True when `path` is `point` or below it.
fn under(path: []const u8, point: []const u8) bool {
    if (point.len == 0) return true;
    if (!std.mem.startsWith(u8, path, point)) return false;
    return path.len == point.len or path[point.len] == '/';
}

/// The hit of a path of a command. A path outside the table needs the
/// capability `host` (`channels` for `open` and `source`, `file` for
/// `file` and `glob`), and without it the path is the error
/// "permission denied". Gives null for a path of the jail or the host.
pub fn gate(it: *Interp, path: []const u8, host: interp.Capability, what: []const u8) Error!?Hit {
    if (try find(it, path)) |h| return h;
    if (!has(it, host)) return it.failCode("POSIX EACCES {permission denied}", "{s} \"{s}\": permission denied", .{ what, path });
    return null;
}

/// The kind of a hit.
pub fn kind(it: *Interp, h: Hit) Kind {
    if (h.m) |m| {
        if (m.z.isDir(h.rel)) return .dir;
        return if (m.z.find(h.rel) != null) .file else .none;
    }
    // A folder above a mount point, or the root.
    for (it.vfs.mounts.items) |m| {
        if (h.rel.len == 0 or under(m.point, h.rel)) return .dir;
    }
    return .none;
}

/// The data of `fsroot.Info` for a hit, or null.
pub fn stat(it: *Interp, h: Hit) ?@import("fsroot.zig").Info {
    const k = kind(it, h);
    if (k == .none) return null;
    var size: u64 = 0;
    var mtime: i64 = 0;
    if (h.m) |m| if (m.z.find(h.rel)) |e| {
        mtime = e.mtime;
        if (!e.dir) size = e.size;
    };
    const mode: u32 = if (k == .dir) 0o040555 else 0o100444;
    // The inode is a hash of the path, so `file copy` sees two names as
    // two files.
    const ino = std.hash.Wyhash.hash(0, h.full) >> 1;
    return .{ .mode = mode, .size = size, .mtime = mtime, .atime = mtime, .ctime = mtime, .ino = ino, .nlink = 1, .uid = 0, .gid = 0, .dev = 0x7a6970 };
}

/// The error of a write to the table.
pub fn readOnly(it: *Interp, what: []const u8, path: []const u8) Error {
    return it.failCode("POSIX EROFS {read-only file system}", "{s} \"{s}\": read-only file system", .{ what, path });
}

fn noFile(it: *Interp, what: []const u8, path: []const u8) Error {
    return it.failCode("POSIX ENOENT {no such file or directory}", "{s} \"{s}\": no such file or directory", .{ what, path });
}

/// The bytes of the file of a hit. `what` starts the error message.
pub fn read(it: *Interp, h: Hit, what: []const u8, path: []const u8) Error![]const u8 {
    const m = h.m orelse return if (kind(it, h) == .dir) isDirError(it, what, path) else noFile(it, what, path);
    const e = m.z.find(h.rel) orelse return if (m.z.isDir(h.rel)) isDirError(it, what, path) else noFile(it, what, path);
    if (e.dir) return isDirError(it, what, path);
    try cmds.chargeWork(it, std.math.cast(usize, e.size) orelse std.math.maxInt(usize));
    const data = m.z.extract(it.alloc(), e) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return it.failCode("POSIX EIO {input/output error}", "{s} \"{s}\": bad data in the zip archive", .{ what, path }),
    };
    try it.checkMem();
    return data;
}

fn isDirError(it: *Interp, what: []const u8, path: []const u8) Error {
    return it.failCode("POSIX EISDIR {illegal operation on a directory}", "{s} \"{s}\": illegal operation on a directory", .{ what, path });
}

/// The names in the folder of a hit, with no path.
pub fn list(it: *Interp, h: Hit) Error![]const []const u8 {
    const a = it.alloc();
    var out: std.ArrayList([]const u8) = .empty;
    if (h.m) |m| {
        const pre = if (h.rel.len == 0) "" else try std.mem.concat(a, u8, &.{ h.rel, "/" });
        var i = m.z.lowerBound(pre);
        while (i < m.z.entries.len and std.mem.startsWith(u8, m.z.entries[i].name, pre)) : (i += 1) {
            const rest = m.z.entries[i].name[pre.len..];
            if (rest.len == 0) continue;
            const name = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
            if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1], name)) continue;
            try addUnique(a, &out, name);
        }
    }
    // The mount points below the folder.
    const here = h.full[root.len..];
    for (it.vfs.mounts.items) |m| {
        if (m.point.len <= here.len or !under(m.point, here)) continue;
        const rest = if (here.len == 0) m.point else m.point[here.len + 1 ..];
        try addUnique(a, &out, rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len]);
    }
    return out.items;
}

fn addUnique(a: std.mem.Allocator, out: *std.ArrayList([]const u8), name: []const u8) !void {
    for (out.items) |x| if (std.mem.eql(u8, x, name)) return;
    try out.append(a, name);
}

/// `glob` on a pattern of the table. Each part of the pattern matches
/// one part of a path, with the rules of `string match`.
pub fn glob(it: *Interp, pattern: []const u8, results: *std.ArrayList([]const u8)) Error!void {
    const ps = try parts(it, pattern);
    var level: std.ArrayList([]const u8) = .empty;
    try level.append(it.alloc(), "");
    for (ps) |p| {
        var next: std.ArrayList([]const u8) = .empty;
        for (level.items) |dir| {
            const h = (try find(it, try std.mem.concat(it.alloc(), u8, &.{ root, dir }))).?;
            if (kind(it, h) != .dir) continue;
            for (try list(it, h)) |name| {
                // As in Tcl, a pattern matches a name with a leading `.`
                // only when the pattern has the `.`.
                if (name[0] == '.' and p[0] != '.') continue;
                if (!cmds.globMatch(p, name, false)) continue;
                try next.append(it.alloc(), if (dir.len == 0) name else try std.mem.concat(it.alloc(), u8, &.{ dir, "/", name }));
            }
        }
        level = next;
    }
    std.mem.sort([]const u8, level.items, {}, lessThan);
    for (level.items) |p| try results.append(it.alloc(), try std.mem.concat(it.alloc(), u8, &.{ root, p }));
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// The point of a mount from a script word: `app`, `/app`, or
/// `//zipfs:/app` give `app`. Gives null for a bad point.
fn pointOf(it: *Interp, word: []const u8) Error!?[]const u8 {
    const full = if (isOurs(word)) word else try std.mem.concat(it.alloc(), u8, &.{ root, word });
    const ps = try parts(it, full);
    const joined = try std.mem.join(it.alloc(), "/", ps);
    if (joined.len > 0 and !zipread.goodName(joined)) return null;
    return joined;
}

/// Mounts the zip archive `bytes` at `point`. The embedder keeps
/// `bytes` alive until the interpreter ends or the mount goes away.
pub fn mountBytes(it: *Interp, point: []const u8, file: []const u8, bytes: []const u8) (zipread.Error || error{InUse})!void {
    for (it.vfs.mounts.items) |m| if (std.mem.eql(u8, m.point, point)) return error.InUse;
    const z = try zipread.Archive.parse(it.alloc(), bytes);
    try it.vfs.mounts.append(it.alloc(), .{ .point = try it.alloc().dupe(u8, point), .file = try it.alloc().dupe(u8, file), .z = z });
}

fn has(it: *Interp, cap: interp.Capability) bool {
    return it.capabilities & @backingInt(cap) != 0;
}

fn cmdZipfs(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("zipfs subcommand ?arg ...?");
    const sub = try it.str(argv[1]);
    const a = it.alloc();
    const eql = std.mem.eql;
    if (eql(u8, sub, "root")) {
        if (argv.len != 2) return it.wrongArgs("zipfs root");
        return .{ .str = root };
    }
    if (eql(u8, sub, "mount")) {
        if (argv.len > 4) return it.wrongArgs("zipfs mount ?zipfile? ?mountpoint?");
        if (argv.len == 2) {
            var out: std.ArrayList(Value) = .empty;
            for (it.vfs.mounts.items) |m| {
                try out.append(a, .{ .str = try std.mem.concat(a, u8, &.{ root, m.point }) });
                try out.append(a, .{ .str = m.file });
            }
            return value.wrapList(a, out.items);
        }
        if (argv.len == 3) {
            // The zip file of a mount point.
            const p = (try pointOf(it, try it.str(argv[2]))) orelse return Value.empty;
            for (it.vfs.mounts.items) |m| if (eql(u8, m.point, p)) return .{ .str = m.file };
            return Value.empty;
        }
        if (!has(it, .file)) return it.fail("zipfs mount of a file needs the file capability", .{});
        const file = try it.str(argv[2]);
        const word = try it.str(argv[3]);
        const point = (try pointOf(it, word)) orelse return it.fail("bad mount point \"{s}\"", .{word});
        const bytes = try readHost(it, file);
        mountBytes(it, point, file, bytes) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.InUse => it.fail("{s} is already mounted at {s}{s}", .{ word, root, point }),
            else => it.fail("archive \"{s}\" is not a valid zip archive: {s}", .{ file, @errorName(e) }),
        };
        return Value.empty;
    }
    if (eql(u8, sub, "unmount")) {
        if (argv.len != 3) return it.wrongArgs("zipfs unmount mountpoint");
        const word = try it.str(argv[2]);
        const p = (try pointOf(it, word)) orelse return Value.empty;
        for (it.vfs.mounts.items, 0..) |m, i| {
            if (!eql(u8, m.point, p)) continue;
            // An embedder mount stays: its memory belongs to the embedder.
            if (m.file.len == 0) return it.fail("\"{s}\" is a mount of the program", .{word});
            _ = it.vfs.mounts.orderedRemove(i);
            return Value.empty;
        }
        return Value.empty;
    }
    if (eql(u8, sub, "exists")) {
        if (argv.len != 3) return it.wrongArgs("zipfs exists filename");
        const h = (try find(it, try it.str(argv[2]))) orelse return .{ .int = 0 };
        return .{ .int = @intFromBool(kind(it, h) != .none) };
    }
    if (eql(u8, sub, "info")) {
        if (argv.len != 3) return it.wrongArgs("zipfs info filename");
        const path = try it.str(argv[2]);
        const h = (try find(it, path)) orelse return it.fail("path \"{s}\" not found in any zipfs volume", .{path});
        const m = h.m orelse return it.fail("path \"{s}\" not found in any zipfs volume", .{path});
        const e = m.z.find(h.rel) orelse return it.fail("path \"{s}\" not found in any zipfs volume", .{path});
        var out = [_]Value{ .{ .str = m.file }, .{ .int = @intCast(e.size) }, .{ .int = @intCast(e.csize) }, .{ .int = @intCast(e.data) } };
        return value.wrapList(a, try a.dupe(Value, &out));
    }
    if (eql(u8, sub, "list")) {
        if (argv.len > 4) return it.wrongArgs("zipfs list ?(-glob|-regexp)? ?pattern?");
        var pat: ?[]const u8 = null;
        if (argv.len == 4) {
            if (!eql(u8, try it.str(argv[2]), "-glob")) return it.fail("bad option \"{s}\": must be -glob", .{try it.str(argv[2])});
            pat = try it.str(argv[3]);
        } else if (argv.len == 3) pat = try it.str(argv[2]);
        var out: std.ArrayList(Value) = .empty;
        for (it.vfs.mounts.items) |m| {
            for (m.z.entries) |e| {
                const full = try std.mem.concat(a, u8, &.{ root, m.point, if (m.point.len > 0) "/" else "", e.name });
                if (pat) |p| if (!cmds.globMatch(p, full, false)) continue;
                try out.append(a, .{ .str = full });
            }
        }
        return value.wrapList(a, out.items);
    }
    return it.fail("unknown or ambiguous subcommand \"{s}\": must be exists, info, list, mount, root, or unmount", .{sub});
}

/// The bytes of a file of the jail or the host, for `zipfs mount`.
fn readHost(it: *Interp, path: []const u8) Error![]const u8 {
    const fsroot = @import("fsroot.zig");
    const sys = @import("sys.zig");
    const what = try std.fmt.allocPrint(it.alloc(), "couldn't open \"{s}\": ", .{path});
    const rel = (try fsroot.normal(it, path)) orelse return it.failCode("POSIX EACCES {permission denied}", "{s}permission denied", .{what});
    const fd = switch (try fsroot.openRel(it, rel, .{}, 0)) {
        .fd => |x| x,
        .err => |e| return fsroot.posixError(it, e, what),
    };
    defer sys.close(fd);
    var data: std.ArrayList(u8) = .empty;
    while (true) {
        try data.ensureUnusedCapacity(it.alloc(), 1 << 16);
        const got = switch (sys.readFile(fd, data.unusedCapacitySlice())) {
            .n => |x| x,
            .err => |e| return fsroot.posixError(it, e, what),
        };
        if (got == 0) break;
        data.items.len += got;
        try it.checkMem();
    }
    return data.items;
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("zipfs", cmdZipfs);
}

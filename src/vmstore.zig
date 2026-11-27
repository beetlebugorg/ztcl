//! The store of signed guest images of `ztcl::vm` (ztcl#312, step 3):
//! a folder of the user, with each file of an image under the name of
//! its SHA-256, and each release that passed `vmimage.verify`.
//!
//!   STORE/objects/SHA256              a kernel, an initramfs, or a disk
//!   STORE/releases/NAME/COUNTER/      manifest.json, manifest.json.sig
//!   STORE/releases/NAME/current       the counter of the release in use
//!   STORE/releases/NAME/highest       the highest counter that passed
//!   STORE/tmp/                        files on their way in
//!
//! A file comes in under tmp/, is checked against the SHA-256 of the
//! signed manifest, and then moves to objects/ with one rename, so a
//! file in objects/ always has the bytes of its name. A release becomes
//! visible with the rename of its folder, after each of its files, and
//! `current` changes last, with a rename too: an update is atomic, and a
//! guest that runs keeps the descriptors of its files.
//!
//! The paths of the store are paths of the host, outside the file jail
//! of a script: only ztcl writes there, and a script names a release by
//! its name, never by a path.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const vmimage = @import("vmimage.zig");
const os = sys.os;
const Allocator = std.mem.Allocator;

pub const Error = error{ NoStore, Io, NotFound, Missing } || vmimage.Error;

/// The platforms of the store: the hosts of `ztcl::vm`. On Windows the
/// guest of the store runs on the Windows Hypervisor Platform.
pub const supported = builtin.os.tag == .macos or builtin.os.tag == .linux or on_win;
const on_win = builtin.os.tag == .windows;

/// The architecture of the host in a manifest.
pub const host_arch = switch (builtin.cpu.arch) {
    .aarch64 => "arm64",
    .x86_64 => "x86_64",
    else => "other",
};

fn z(a: Allocator, s: []const u8) Allocator.Error![:0]u8 {
    return a.dupeSentinel(u8, s, 0);
}

/// The calls of the store on a descriptor of a folder: each opens one
/// name relative to the folder, with no symlink. POSIX has `openat` with
/// `O_NOFOLLOW`. Windows has `NtCreateFile` relative to the handle of the
/// folder, with FILE_OPEN_REPARSE_POINT, and a reparse point (a symlink,
/// a junction, or a mount point) is an error (`fsroot_windows.openAt`).
const fs = if (on_win) struct {
    const fw = @import("fsroot_windows.zig");

    fn openDir(dir: i32, name: [:0]const u8) Error!i32 {
        return switch (fw.openAt(dir, name, .dir)) {
            .fd => |f| f,
            .err => |e| if (e == .NOENT) error.NotFound else error.Io,
        };
    }
    fn openRead(dir: i32, name: [:0]const u8) Error!i32 {
        return switch (fw.openAt(dir, name, .read)) {
            .fd => |f| f,
            .err => |e| if (e == .NOENT) error.NotFound else error.Io,
        };
    }
    fn createNew(dir: i32, name: [:0]const u8) Error!i32 {
        return switch (fw.openAt(dir, name, .create_new)) {
            .fd => |f| f,
            .err => error.Io,
        };
    }
    /// A folder that exists already is no error.
    fn mkdir(dir: i32, name: [:0]const u8) Error!void {
        if (fw.mkdirAt(.{ .fd = dir, .base = name })) |e| if (e != .EXIST) return error.Io;
    }
    fn rename(fd: i32, from: [:0]const u8, td: i32, to: [:0]const u8) bool {
        return fw.renameAt(.{ .fd = fd, .base = from }, .{ .fd = td, .base = to }) == null;
    }
    fn unlink(dir: i32, name: [:0]const u8, is_dir: bool) void {
        _ = fw.removeAt(.{ .fd = dir, .base = name }, is_dir);
    }
    fn read(fd: i32, buf: []u8) ?usize {
        return switch (sys.read(fd, buf)) {
            .n => |n| n,
            else => null,
        };
    }
    fn write(fd: i32, buf: []const u8) ?usize {
        return switch (sys.write(fd, buf)) {
            .n => |n| n,
            else => null,
        };
    }
    fn close(fd: i32) void {
        sys.close(fd);
    }
    /// Closes `fd`.
    fn names(a: Allocator, fd: i32) Error![][]u8 {
        defer sys.close(fd);
        return fw.namesAt(a, fd) catch |e| if (e == error.OutOfMemory) error.OutOfMemory else error.Io;
    }
    /// Makes the folder `path` of the host and its parents, and opens it.
    /// The path of the store comes from the embedder, and the system
    /// follows a reparse point in it.
    fn openRoot(a: Allocator, path: []const u8) ?i32 {
        const w = std.unicode.utf8ToUtf16LeAllocZ(a, path) catch return null;
        defer a.free(w);
        // Each parent, then the folder. A folder that exists is no error.
        for (w, 0..) |c, k| if (k > 0 and (c == '/' or c == '\\') and w[k - 1] != ':') {
            w[k] = 0;
            _ = CreateDirectoryW(w.ptr, null);
            w[k] = c;
        };
        _ = CreateDirectoryW(w.ptr, null);
        // FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES |
        // SYNCHRONIZE, all sharing, OPEN_EXISTING, BACKUP_SEMANTICS for a
        // folder.
        const h = CreateFileW(w.ptr, 0x0010_00a1, 7, null, 3, 0x0200_0000, null);
        if (@intFromPtr(h) == ~@as(usize, 0)) return null;
        return sys.win.fdOfHandle(h.?) orelse {
            _ = CloseHandle(h);
            return null;
        };
    }
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn CloseHandle(h: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CreateDirectoryW(name: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) i32;
} else struct {
    const nofollow_dir: os.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };

    fn ok(rc: usize) bool {
        return os.errno(rc) == .SUCCESS;
    }
    fn openDir(dir: i32, name: [:0]const u8) Error!i32 {
        const rc = os.openat(dir, name, nofollow_dir, 0);
        if (!ok(rc)) return if (os.errno(rc) == .NOENT) error.NotFound else error.Io;
        return @intCast(rc);
    }
    fn openRead(dir: i32, name: [:0]const u8) Error!i32 {
        const rc = os.openat(dir, name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }, 0);
        if (!ok(rc)) return if (os.errno(rc) == .NOENT) error.NotFound else error.Io;
        return @intCast(rc);
    }
    fn createNew(dir: i32, name: [:0]const u8) Error!i32 {
        const rc = os.openat(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o644);
        if (!ok(rc)) return error.Io;
        return @intCast(rc);
    }
    fn mkdir(dir: i32, name: [:0]const u8) Error!void {
        const rc = os.mkdirat(dir, name, 0o755);
        if (!ok(rc) and os.errno(rc) != .EXIST) return error.Io;
    }
    fn rename(fd: i32, from: [:0]const u8, td: i32, to: [:0]const u8) bool {
        return ok(os.renameat(fd, from, td, to));
    }
    fn unlink(dir: i32, name: [:0]const u8, is_dir: bool) void {
        _ = os.unlinkat(dir, name, if (is_dir) os.AT.REMOVEDIR else 0);
    }
    fn read(fd: i32, buf: []u8) ?usize {
        const n = os.read(fd, buf.ptr, buf.len);
        return if (ok(n)) n else null;
    }
    fn write(fd: i32, buf: []const u8) ?usize {
        const n = os.write(fd, buf.ptr, buf.len);
        return if (ok(n)) n else null;
    }
    fn close(fd: i32) void {
        _ = os.close(fd);
    }
    /// Closes `fd`.
    fn names(a: Allocator, fd: i32) Error![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |x| a.free(x);
            out.deinit(a);
        }
        if (comptime builtin.os.tag == .macos) {
            // `closedir` closes the descriptor.
            const d = os.openDir(fd) orelse {
                _ = os.close(fd);
                return error.Io;
            };
            defer _ = std.c.closedir(d);
            while (os.nextName(d)) |name| {
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                try out.append(a, try a.dupe(u8, name));
            }
            return out.toOwnedSlice(a);
        }
        defer _ = os.close(fd);
        var buf: [8192]u8 align(8) = undefined;
        while (true) {
            const n = os.getdents64(fd, &buf, buf.len);
            if (!ok(n)) return error.Io;
            if (n == 0) break;
            var off: usize = 0;
            while (off < n) {
                const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf[off + 19])), 0);
                if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) try out.append(a, try a.dupe(u8, name));
                off += reclen;
            }
        }
        return out.toOwnedSlice(a);
    }
    /// Makes the folder `path` of the host and its parents, and opens it.
    /// The path of the store comes from the embedder and may have
    /// symlinks (/var on macOS); the names below it may not.
    fn openRoot(a: Allocator, root: []const u8) ?i32 {
        var k: usize = if (root[0] == '/') 1 else 0;
        while (k <= root.len) : (k += 1) {
            if (k == 0) continue;
            if (k == root.len or root[k] == '/') {
                const pz = z(a, root[0..k]) catch return null;
                defer a.free(pz);
                _ = os.mkdirat(os.AT.FDCWD, pz, 0o755);
            }
        }
        const rz = z(a, root) catch return null;
        defer a.free(rz);
        const rc = os.open(rz, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (!ok(rc)) return null;
        return @intCast(rc);
    }
};

/// The parent folder of `path` below `dir`, opened one name at a time
/// with no symlink, and the last name. Close `fd` when it is not `dir`.
const Parent = struct {
    fd: i32,
    own: bool,
    base: [:0]u8,

    fn close(p: Parent, a: Allocator) void {
        if (p.own) fs.close(p.fd);
        a.free(p.base);
    }
};

fn badName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return true;
    // A separator or a stream of Windows in a name.
    return on_win and std.mem.indexOfAny(u8, name, "\\:") != null;
}

fn parent(a: Allocator, dir: i32, path: []const u8) Error!Parent {
    if (path.len == 0 or path[0] == '/') return error.Io;
    var cur = dir;
    var own = false;
    errdefer if (own) fs.close(cur);
    var it = std.mem.splitScalar(u8, path, '/');
    var name = it.next().?;
    while (it.next()) |next| {
        if (badName(name)) return error.Io;
        const nz = try z(a, name);
        defer a.free(nz);
        const fd = try fs.openDir(cur, nz);
        if (own) fs.close(cur);
        cur = fd;
        own = true;
        name = next;
    }
    if (badName(name)) return error.Io;
    return .{ .fd = cur, .own = own, .base = try z(a, name) };
}

/// Makes the folder `path` below `dir` and each parent, with no symlink.
fn mkdirs(a: Allocator, dir: i32, path: []const u8) Error!void {
    var k: usize = 1;
    while (k <= path.len) : (k += 1) {
        if (k == path.len or path[k] == '/') {
            const p = try parent(a, dir, path[0..k]);
            defer p.close(a);
            try fs.mkdir(p.fd, p.base);
            // A name that exists must be a folder, not a symlink.
            fs.close(try fs.openDir(p.fd, p.base));
        }
    }
}

fn join(a: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
    return std.mem.join(a, "/", parts);
}

/// Reads the file `path` below `dir`. A symlink on the way is an error.
fn readAll(a: Allocator, dir: i32, path: []const u8, max: usize) Error![]u8 {
    const p = try parent(a, dir, path);
    defer p.close(a);
    const fd = try fs.openRead(p.fd, p.base);
    defer fs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = fs.read(fd, &buf) orelse return error.Io;
        if (n == 0) break;
        if (out.items.len + n > max) return error.Io;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

/// Writes `data` to `path` through a file of tmp/ and a rename.
fn writeAtomic(a: Allocator, s: Store, path: []const u8, data: []const u8) Error!void {
    const tmp = try s.tmpName(a);
    defer a.free(tmp);
    try writeNew(a, s.fd, tmp, data);
    try rename(a, s.fd, tmp, path);
}

fn writeNew(a: Allocator, dir: i32, path: []const u8, data: []const u8) Error!void {
    const p = try parent(a, dir, path);
    defer p.close(a);
    const fd = try fs.createNew(p.fd, p.base);
    defer fs.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = fs.write(fd, data[off..]) orelse return error.Io;
        if (n == 0) return error.Io;
        off += n;
    }
}

fn rename(a: Allocator, dir: i32, from: []const u8, to: []const u8) Error!void {
    const f = try parent(a, dir, from);
    defer f.close(a);
    const t = try parent(a, dir, to);
    defer t.close(a);
    if (!fs.rename(f.fd, f.base, t.fd, t.base)) return error.Io;
}

fn exists(a: Allocator, dir: i32, path: []const u8) bool {
    const p = parent(a, dir, path) catch return false;
    defer p.close(a);
    // A folder or a file.
    const fd = fs.openRead(p.fd, p.base) catch fs.openDir(p.fd, p.base) catch return false;
    fs.close(fd);
    return true;
}

fn unlink(a: Allocator, dir: i32, path: []const u8, is_dir: bool) void {
    const p = parent(a, dir, path) catch return;
    defer p.close(a);
    fs.unlink(p.fd, p.base, is_dir);
}

/// The names in the folder `path` below `dir`, with no `.` and `..`.
fn listDir(a: Allocator, dir: i32, path: []const u8) Error![][]u8 {
    const p = parent(a, dir, path) catch |e| return if (e == error.NotFound) &.{} else e;
    defer p.close(a);
    const fd = fs.openDir(p.fd, p.base) catch |e| return if (e == error.NotFound) &.{} else e;
    return fs.names(a, fd);
}

fn freeList(a: Allocator, l: [][]u8) void {
    for (l) |x| a.free(x);
    a.free(l);
}

var tmp_counter = std.atomic.Value(u64).init(0);

pub const Store = struct {
    /// The path of the store, for the paths of objects that a guest
    /// gets, and the descriptor of its folder: each step of the store is
    /// relative to it, with no symlink below it.
    root: []const u8,
    fd: i32,

    /// Opens the store at `root`, and makes its folders. Call `close`.
    pub fn open(a: Allocator, root: []const u8) Error!Store {
        if (root.len == 0) return error.NoStore;
        const fd = fs.openRoot(a, root) orelse return error.NoStore;
        const s: Store = .{ .root = root, .fd = fd };
        errdefer s.close();
        for ([_][]const u8{ "objects", "releases", "tmp" }) |sub| try mkdirs(a, s.fd, sub);
        return s;
    }

    pub fn close(s: Store) void {
        fs.close(s.fd);
    }

    fn tmpName(_: Store, a: Allocator) Allocator.Error![]u8 {
        var r: [8]u8 = undefined;
        @import("isoproto.zig").entropy(&r);
        const n = tmp_counter.fetchAdd(1, .monotonic);
        return std.fmt.allocPrint(a, "tmp/{x}-{d}", .{ std.mem.readInt(u64, &r, .little), n });
    }

    /// The host path of an object, for a guest.
    pub fn objectPath(s: Store, a: Allocator, sha: []const u8) Allocator.Error![]u8 {
        return join(a, &.{ s.root, "objects", sha });
    }

    fn objectRel(a: Allocator, sha: []const u8) Allocator.Error![]u8 {
        return join(a, &.{ "objects", sha });
    }

    /// The bytes of an object, read through the descriptor of the store
    /// and checked against their SHA-256, for a monitor that boots from
    /// memory: the check is on the bytes that the guest gets.
    pub fn readObject(s: Store, a: Allocator, sha: []const u8) Error![]u8 {
        const p = try objectRel(a, sha);
        defer a.free(p);
        const data = readAll(a, s.fd, p, 8 << 30) catch |e| return if (e == error.NotFound) error.Missing else e;
        errdefer a.free(data);
        try vmimage.checkHash(data, sha);
        return data;
    }

    /// A descriptor of an object to read, opened through the descriptor
    /// of the store, for a disk. A disk with verity checks itself in the
    /// guest.
    pub fn openObject(s: Store, a: Allocator, sha: []const u8) Error!i32 {
        const p = try objectRel(a, sha);
        defer a.free(p);
        const par = try parent(a, s.fd, p);
        defer par.close(a);
        return fs.openRead(par.fd, par.base) catch |e| if (e == error.NotFound) error.Missing else e;
    }

    fn counterFile(s: Store, a: Allocator, name: []const u8, which: []const u8) Error!?u64 {
        const p = try join(a, &.{ "releases", name, which });
        defer a.free(p);
        const t = readAll(a, s.fd, p, 64) catch |e| return if (e == error.NotFound) null else e;
        defer a.free(t);
        return std.fmt.parseInt(u64, std.mem.trim(u8, t, " \n"), 10) catch error.Io;
    }

    /// The highest counter of `name` that the store accepted, or 0.
    pub fn highest(s: Store, a: Allocator, name: []const u8) Error!u64 {
        return (try s.counterFile(a, name, "highest")) orelse 0;
    }

    /// The counter of the release of `name` in use, or null.
    pub fn current(s: Store, a: Allocator, name: []const u8) Error!?u64 {
        return s.counterFile(a, name, "current");
    }

    /// Copies one file of a release into objects/ after a check of its
    /// SHA-256. A file that is there already stays.
    fn addObject(s: Store, a: Allocator, data: []const u8, sha: []const u8) Error!void {
        try vmimage.checkHash(data, sha);
        const dest = try objectRel(a, sha);
        defer a.free(dest);
        if (exists(a, s.fd, dest)) return;
        try writeAtomic(a, s, dest, data);
    }

    /// Installs the release in the folder `src` (a manifest, its
    /// signature, and the files of the manifest): the files of `arch`
    /// must be there, and the files of the other architectures that are
    /// there come too. Gives the name and the counter.
    pub fn install(s: Store, a: Allocator, src: i32, arch: []const u8, allow_rollback: bool) Error!struct { name: []u8, counter: u64, key: []const u8 } {
        const manifest = try readAll(a, src, "manifest.json", 1 << 20);
        defer a.free(manifest);
        const sig = try readAll(a, src, "manifest.json.sig", 1 << 16);
        defer a.free(sig);
        // The signature first, with no rollback check, for the name.
        var pre = try vmimage.verify(a, manifest, sig, 0, true);
        const name = try a.dupe(u8, pre.parsed.value.name);
        pre.deinit();
        errdefer a.free(name);
        if (std.mem.indexOfAny(u8, name, "/\\") != null or name.len == 0 or name[0] == '.') return error.BadManifest;
        var c = try vmimage.verify(a, manifest, sig, try s.highest(a, name), allow_rollback);
        defer c.deinit();
        const m = c.parsed.value;
        if (m.archs.map.get(arch) == null) return error.Missing;
        for (m.archs.map.keys(), m.archs.map.values()) |an, x| {
            const required = std.mem.eql(u8, an, arch);
            var files: std.ArrayList(vmimage.File) = .empty;
            defer files.deinit(a);
            try files.append(a, x.kernel);
            if (x.initrd) |f| try files.append(a, f);
            for (x.disks) |d| try files.append(a, .{ .file = d.file, .sha256 = d.sha256 });
            for (files.items) |f| {
                if (std.mem.indexOf(u8, f.file, "..") != null) return error.BadManifest;
                const data = readAll(a, src, f.file, 8 << 30) catch |e| switch (e) {
                    error.NotFound => if (required) return error.Missing else continue,
                    else => return e,
                };
                defer a.free(data);
                try s.addObject(a, data, f.sha256);
            }
        }
        // The release folder, then `highest` and `current`.
        var num: [24]u8 = undefined;
        const cs = std.fmt.bufPrint(&num, "{d}", .{m.counter}) catch unreachable;
        const ndir = try join(a, &.{ "releases", name });
        defer a.free(ndir);
        try mkdirs(a, s.fd, ndir);
        const rdir = try join(a, &.{ ndir, cs });
        defer a.free(rdir);
        if (!exists(a, s.fd, rdir)) {
            const tmp = try s.tmpName(a);
            defer a.free(tmp);
            try mkdirs(a, s.fd, tmp);
            for ([_][]const u8{ "manifest.json", "manifest.json.sig" }, [_][]const u8{ manifest, sig }) |fname, data| {
                const p = try join(a, &.{ tmp, fname });
                defer a.free(p);
                try writeNew(a, s.fd, p, data);
            }
            try rename(a, s.fd, tmp, rdir);
        }
        const hp = try join(a, &.{ ndir, "highest" });
        defer a.free(hp);
        if (m.counter > try s.highest(a, name)) try writeAtomic(a, s, hp, cs);
        const cp = try join(a, &.{ ndir, "current" });
        defer a.free(cp);
        try writeAtomic(a, s, cp, cs);
        return .{ .name = name, .counter = m.counter, .key = c.key.name };
    }

    /// The manifest of a release, checked again: its signature, with no
    /// rollback check, since the store keeps older releases on purpose.
    pub fn load(s: Store, a: Allocator, name: []const u8, counter: u64) Error!vmimage.Checked {
        var num: [24]u8 = undefined;
        const cs = std.fmt.bufPrint(&num, "{d}", .{counter}) catch unreachable;
        const mp = try join(a, &.{ "releases", name, cs, "manifest.json" });
        defer a.free(mp);
        const sp = try join(a, &.{ "releases", name, cs, "manifest.json.sig" });
        defer a.free(sp);
        const manifest = try readAll(a, s.fd, mp, 1 << 20);
        defer a.free(manifest);
        const sig = try readAll(a, s.fd, sp, 1 << 16);
        defer a.free(sig);
        return vmimage.verify(a, manifest, sig, 0, true);
    }

    /// Checks each file of the release of `arch` in objects/ against its
    /// SHA-256. Gives the count of the files.
    pub fn verifyRelease(s: Store, a: Allocator, name: []const u8, counter: u64, arch: []const u8) Error!usize {
        var c = try s.load(a, name, counter);
        defer c.deinit();
        const x = c.parsed.value.archs.map.get(arch) orelse return error.Missing;
        var n: usize = 0;
        var files: std.ArrayList(vmimage.File) = .empty;
        defer files.deinit(a);
        try files.append(a, x.kernel);
        if (x.initrd) |f| try files.append(a, f);
        for (x.disks) |d| try files.append(a, .{ .file = d.file, .sha256 = d.sha256 });
        for (files.items) |f| {
            const p = try objectRel(a, f.sha256);
            defer a.free(p);
            const data = readAll(a, s.fd, p, 8 << 30) catch |e| return if (e == error.NotFound) error.Missing else e;
            defer a.free(data);
            try vmimage.checkHash(data, f.sha256);
            n += 1;
        }
        return n;
    }

    pub const Entry = struct { name: []u8, counters: []u64, current: ?u64 };

    /// Each name and the counters of its releases, in order.
    pub fn list(s: Store, a: Allocator) Error![]Entry {
        const rp = try join(a, &.{"releases"});
        defer a.free(rp);
        const names = try listDir(a, s.fd, rp);
        defer freeList(a, names);
        std.mem.sort([]u8, names, {}, struct {
            fn lt(_: void, x: []u8, y: []u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        var out: std.ArrayList(Entry) = .empty;
        for (names) |n| {
            const np = try join(a, &.{ rp, n });
            defer a.free(np);
            const subs = try listDir(a, s.fd, np);
            defer freeList(a, subs);
            var cs: std.ArrayList(u64) = .empty;
            for (subs) |x| if (std.fmt.parseInt(u64, x, 10)) |v| try cs.append(a, v) else |_| {};
            std.mem.sort(u64, cs.items, {}, std.sort.asc(u64));
            // A name with no release keeps its folder for `highest`.
            if (cs.items.len == 0) {
                cs.deinit(a);
                continue;
            }
            try out.append(a, .{ .name = try a.dupe(u8, n), .counters = try cs.toOwnedSlice(a), .current = try s.current(a, n) });
        }
        return out.toOwnedSlice(a);
    }

    /// A new folder of tmp/ for a download. `Temp.remove` takes it away.
    pub fn tempDir(s: Store, a: Allocator) Error!Temp {
        const rel = try s.tmpName(a);
        errdefer a.free(rel);
        try mkdirs(a, s.fd, rel);
        const p = try parent(a, s.fd, rel);
        defer p.close(a);
        const fd = fs.openDir(p.fd, p.base) catch return error.Io;
        return .{ .fd = fd, .rel = rel };
    }

    /// The name, the counter, and the files of this architecture of the
    /// signed manifest in the folder `dir`, before an install.
    pub fn peek(s: Store, a: Allocator, dir: i32) Error!struct { name: []u8, counter: u64, files: [][]u8 } {
        _ = s;
        const manifest = try readAll(a, dir, "manifest.json", 1 << 20);
        defer a.free(manifest);
        const sig = try readAll(a, dir, "manifest.json.sig", 1 << 16);
        defer a.free(sig);
        var c = try vmimage.verify(a, manifest, sig, 0, true);
        defer c.deinit();
        const x = c.parsed.value.archs.map.get(host_arch) orelse return error.Missing;
        var files: std.ArrayList([]u8) = .empty;
        try files.append(a, try a.dupe(u8, x.kernel.file));
        if (x.initrd) |f| try files.append(a, try a.dupe(u8, f.file));
        for (x.disks) |d| try files.append(a, try a.dupe(u8, d.file));
        return .{ .name = try a.dupe(u8, c.parsed.value.name), .counter = c.parsed.value.counter, .files = try files.toOwnedSlice(a) };
    }

    /// Removes a release, or each release of `name` when `counter` is
    /// null, then each object that no release names.
    pub fn remove(s: Store, a: Allocator, name: []const u8, counter: ?u64) Error!void {
        const np = try join(a, &.{ "releases", name });
        defer a.free(np);
        if (!exists(a, s.fd, np)) return error.NotFound;
        const subs = try listDir(a, s.fd, np);
        defer freeList(a, subs);
        var num: [24]u8 = undefined;
        const want: ?[]const u8 = if (counter) |c| std.fmt.bufPrint(&num, "{d}", .{c}) catch unreachable else null;
        var found = false;
        for (subs) |x| {
            if (std.fmt.parseInt(u64, x, 10)) |_| {} else |_| continue;
            if (want) |w| if (!std.mem.eql(u8, w, x)) continue;
            found = true;
            for ([_][]const u8{ "manifest.json", "manifest.json.sig" }) |f| {
                const p = try join(a, &.{ np, x, f });
                defer a.free(p);
                unlink(a, s.fd, p, false);
            }
            const d = try join(a, &.{ np, x });
            defer a.free(d);
            unlink(a, s.fd, d, true);
        }
        if (!found) return error.NotFound;
        if (counter == null or (try s.current(a, name)) == counter) {
            const cp = try join(a, &.{ np, "current" });
            defer a.free(cp);
            unlink(a, s.fd, cp, false);
        }
        if (counter == null) {
            // `highest` stays: a removal is no reason to accept an older
            // release later.
        }
        try s.collect(a);
    }

    /// Removes each object that no release names.
    fn collect(s: Store, a: Allocator) Error!void {
        var keep: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = keep.keyIterator();
            while (it.next()) |k| a.free(k.*);
            keep.deinit(a);
        }
        const entries = try s.list(a);
        defer freeEntries(a, entries);
        for (entries) |e| for (e.counters) |c| {
            var m = s.load(a, e.name, c) catch continue;
            defer m.deinit();
            for (m.parsed.value.archs.map.values()) |x| {
                try keep.put(a, try a.dupe(u8, x.kernel.sha256), {});
                if (x.initrd) |f| try keep.put(a, try a.dupe(u8, f.sha256), {});
                for (x.disks) |d| try keep.put(a, try a.dupe(u8, d.sha256), {});
            }
        };
        const op = try a.dupe(u8, "objects");
        defer a.free(op);
        const objs = try listDir(a, s.fd, op);
        defer freeList(a, objs);
        for (objs) |o| if (!keep.contains(o)) {
            const p = try join(a, &.{ op, o });
            defer a.free(p);
            unlink(a, s.fd, p, false);
        };
    }
};

/// A folder of tmp/ of the store, for a download.
pub const Temp = struct {
    fd: i32,
    rel: []u8,

    /// A new file in the folder, for the bytes of a download.
    pub fn create(t: Temp, a: Allocator, name: []const u8) Error!i32 {
        if (std.mem.indexOfScalar(u8, name, '/') != null or badName(name)) return error.BadManifest;
        const nz = try z(a, name);
        defer a.free(nz);
        return fs.createNew(t.fd, nz);
    }

    /// Removes the folder and its files.
    pub fn remove(t: Temp, a: Allocator, s: Store) void {
        if (listDir(a, s.fd, t.rel)) |names| {
            for (names) |n| {
                const nz = z(a, n) catch continue;
                defer a.free(nz);
                fs.unlink(t.fd, nz, false);
            }
            freeList(a, names);
        } else |_| {}
        fs.close(t.fd);
        unlink(a, s.fd, t.rel, true);
        a.free(t.rel);
    }
};

pub fn freeEntries(a: Allocator, entries: []Store.Entry) void {
    for (entries) |e| {
        a.free(e.name);
        a.free(e.counters);
    }
    a.free(entries);
}

fn openDirFd(a: Allocator, path: []const u8) !i32 {
    return fs.openRoot(a, path) orelse error.Io;
}

/// A symlink at `path` below `dir` to `target`, relative to the folder
/// of the link. On Windows a symlink needs a right of the user or the
/// developer mode, so the test makes a junction, a reparse point of a
/// mount point, which needs neither: the store refuses each reparse point.
fn symlinkAt(a: Allocator, target: []const u8, dir: i32, path: []const u8) !void {
    if (comptime on_win) return junctionAt(a, target, dir, path);
    const t = try z(a, target);
    defer a.free(t);
    const pz = try z(a, path);
    defer a.free(pz);
    if (!fs.ok(os.symlinkat(t, dir, pz))) return error.Io;
}

/// Removes the link of `symlinkAt`. The store refuses to remove a reparse
/// point, so on Windows the test removes its junction by its path.
fn unlinkLink(a: Allocator, dir: i32, path: []const u8) !void {
    if (comptime !on_win) return unlink(a, dir, path, false);
    const W = struct {
        extern "kernel32" fn GetFinalPathNameByHandleW(h: ?*anyopaque, buf: [*]u16, size: u32, flags: u32) callconv(.winapi) u32;
        extern "kernel32" fn RemoveDirectoryW(name: [*:0]const u16) callconv(.winapi) i32;
    };
    var wbuf: [1024]u16 = undefined;
    const n = W.GetFinalPathNameByHandleW(@ptrFromInt(@as(usize, @intCast(dir))), &wbuf, wbuf.len, 0);
    if (n == 0 or n >= wbuf.len) return error.Io;
    const dos = try std.unicode.utf16LeToUtf8Alloc(a, wbuf[4..n]);
    defer a.free(dos);
    const link = try std.fs.path.resolve(a, &.{ dos, path });
    defer a.free(link);
    const lw = try std.unicode.utf8ToUtf16LeAllocZ(a, link);
    defer a.free(lw);
    if (W.RemoveDirectoryW(lw.ptr) == 0) return error.Io;
}

fn junctionAt(a: Allocator, target: []const u8, dir: i32, path: []const u8) !void {
    const W = struct {
        extern "kernel32" fn GetFinalPathNameByHandleW(h: ?*anyopaque, buf: [*]u16, size: u32, flags: u32) callconv(.winapi) u32;
        extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn DeviceIoControl(h: ?*anyopaque, code: u32, in: ?*const anyopaque, in_len: u32, out: ?*anyopaque, out_len: u32, got: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
        extern "kernel32" fn CloseHandle(h: ?*anyopaque) callconv(.winapi) i32;
    };
    // The real path of the folder, as \\?\C:\...
    var wbuf: [1024]u16 = undefined;
    const n = W.GetFinalPathNameByHandleW(@ptrFromInt(@as(usize, @intCast(dir))), &wbuf, wbuf.len, 0);
    if (n == 0 or n >= wbuf.len) return error.Io;
    const dos = try std.unicode.utf16LeToUtf8Alloc(a, wbuf[4..n]);
    defer a.free(dos);
    const link = try std.fs.path.resolve(a, &.{ dos, path });
    defer a.free(link);
    const to = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(link).?, target });
    defer a.free(to);
    try mkdirs(a, dir, path);
    const lw = try std.unicode.utf8ToUtf16LeAllocZ(a, link);
    defer a.free(lw);
    // GENERIC_WRITE, OPEN_EXISTING, BACKUP_SEMANTICS | OPEN_REPARSE_POINT.
    const h = W.CreateFileW(lw.ptr, 0x4000_0000, 0, null, 3, 0x0200_0000 | 0x0020_0000, null);
    if (@intFromPtr(h) == ~@as(usize, 0)) return error.Io;
    defer _ = W.CloseHandle(h);
    // REPARSE_DATA_BUFFER of IO_REPARSE_TAG_MOUNT_POINT: the substitute
    // name \??\C:\... and an empty print name, each with its zero.
    const subst = try std.fmt.allocPrint(a, "\\??\\{s}", .{to});
    defer a.free(subst);
    const sw = try std.unicode.utf8ToUtf16LeAlloc(a, subst);
    defer a.free(sw);
    const sub_bytes: u16 = @intCast(sw.len * 2);
    const data_len: u16 = 8 + sub_bytes + 2 + 2;
    var buf: [2048]u8 align(4) = @splat(0);
    std.mem.writeInt(u32, buf[0..4], 0xA000_0003, .little);
    std.mem.writeInt(u16, buf[4..6], data_len, .little);
    std.mem.writeInt(u16, buf[10..12], sub_bytes, .little); // the substitute name at 0
    std.mem.writeInt(u16, buf[12..14], sub_bytes + 2, .little); // the print name after it
    @memcpy(buf[16..][0..sub_bytes], std.mem.sliceAsBytes(sw));
    var got: u32 = 0;
    // FSCTL_SET_REPARSE_POINT.
    if (W.DeviceIoControl(h, 0x0009_00A4, &buf, 8 + @as(u32, data_len), null, 0, &got, null) == 0) return error.Io;
}

test "vmstore: install, list, check, rollback, and remove" {
    if (comptime !supported) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(base);
    const bfd = try openDirFd(a, base);
    defer fs.close(bfd);
    // A release folder: the signed manifest of the fixtures, and its
    // kernel, the 4 bytes "test".
    try mkdirs(a, bfd, "src");
    const files = [_][2][]const u8{
        .{ "src/manifest.json", @embedFile("vmimage_fixtures/manifest.json") },
        .{ "src/manifest.json.sig", @embedFile("vmimage_fixtures/manifest.json.sig.good") },
        .{ "src/Image", "test" },
        .{ "real", "test" },
    };
    for (files) |f| try writeNew(a, bfd, f[0], f[1]);
    const src = try join(a, &.{ base, "src" });
    defer a.free(src);
    const sfd = try openDirFd(a, src);
    defer fs.close(sfd);
    const root = try join(a, &.{ base, "store" });
    defer a.free(root);
    const s = try Store.open(a, root);
    defer s.close();
    const r = try s.install(a, sfd, "arm64", false);
    defer a.free(r.name);
    try std.testing.expectEqualStrings("ztcl-guest-test", r.name);
    try std.testing.expectEqual(@as(u64, 3), r.counter);
    try std.testing.expectEqual(@as(?u64, 3), try s.current(a, r.name));
    try std.testing.expectEqual(@as(usize, 1), try s.verifyRelease(a, r.name, 3, "arm64"));
    const l = try s.list(a);
    defer freeEntries(a, l);
    try std.testing.expectEqual(@as(usize, 1), l.len);
    try std.testing.expectEqualSlices(u64, &.{3}, l[0].counters);
    // An architecture that the manifest does not have.
    try std.testing.expectError(error.Missing, s.install(a, sfd, "x86_64", false));
    // A changed object fails the check.
    const obj = "objects/9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";
    unlink(a, s.fd, obj, false);
    try writeNew(a, s.fd, obj, "tesT");
    try std.testing.expectError(error.Hash, s.verifyRelease(a, r.name, 3, "arm64"));
    // A higher counter seen before: the same release is a rollback.
    const hp = try join(a, &.{ "releases", r.name, "highest" });
    defer a.free(hp);
    try writeAtomic(a, s, hp, "9");
    try std.testing.expectError(error.Rollback, s.install(a, sfd, "arm64", false));
    // The removal of the release takes its objects.
    try s.remove(a, r.name, null);
    try std.testing.expect(!exists(a, s.fd, obj));
    try std.testing.expectEqual(@as(?u64, null), try s.current(a, r.name));
    try std.testing.expectError(error.NotFound, s.remove(a, r.name, 3));
}

test "vmstore: a symlink in the release or in the store is refused" {
    if (comptime !supported) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(base);
    const bfd = try openDirFd(a, base);
    defer fs.close(bfd);
    try mkdirs(a, bfd, "src");
    try writeNew(a, bfd, "src/manifest.json", @embedFile("vmimage_fixtures/manifest.json"));
    try writeNew(a, bfd, "src/manifest.json.sig", @embedFile("vmimage_fixtures/manifest.json.sig.good"));
    // The kernel of the release is a symlink to a file with the right
    // bytes outside the folder: a swap that the jail checked before.
    try writeNew(a, bfd, "outside", "test");
    try symlinkAt(a, "../outside", bfd, "src/Image");
    const src = try join(a, &.{ base, "src" });
    defer a.free(src);
    const sfd = try openDirFd(a, src);
    defer fs.close(sfd);
    const root = try join(a, &.{ base, "store" });
    defer a.free(root);
    const s = try Store.open(a, root);
    defer s.close();
    try std.testing.expectError(error.Io, s.install(a, sfd, "arm64", false));
    // The file itself, then objects/ of the store swapped for a symlink.
    try unlinkLink(a, bfd, "src/Image");
    try writeNew(a, bfd, "src/Image", "test");
    try mkdirs(a, bfd, "elsewhere");
    unlink(a, s.fd, "objects", true);
    try symlinkAt(a, "../elsewhere", s.fd, "objects");
    try std.testing.expect(std.meta.isError(s.install(a, sfd, "arm64", false)));
    try std.testing.expect(!exists(a, bfd, "elsewhere/9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"));
}

//! The files of a 9p share on Linux: the `Fs` of `virtio/ninep.zig` on
//! the descriptor of the root folder of the share. ztcl opens that
//! folder in the file jail.
//!
//! Each path goes through `openat2` with `RESOLVE_BENEATH` and
//! `RESOLVE_NO_SYMLINKS` from the root folder, so no step of a path
//! leaves the folder or goes through a symbolic link. A call on a file
//! uses an `O_PATH` descriptor of the file, and a call on a name uses a
//! descriptor of its folder and the one name. The calls that have no
//! form for an `O_PATH` descriptor (chmod, utimensat, linkat) use
//! `/proc/self/fd/N`, which names that same file.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const linux = std.os.linux;
const ninep = @import("virtio/ninep.zig");

const resolve_no_magiclinks = 0x02;
const resolve_no_symlinks = 0x04;
const resolve_beneath = 0x08;

pub const Share = struct {
    /// The root folder of the share, opened with `O_PATH`.
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

fn share(ctx: *anyopaque) *Share {
    return @ptrCast(@alignCast(ctx));
}

fn err(rc: usize) u32 {
    const e = linux.errno(rc);
    return if (e == .SUCCESS) 0 else @intCast(@backingInt(e));
}

/// A path as a C string: "." for the root folder.
const CPath = struct {
    b: [ninep.max_path + 1]u8 = undefined,
    fn of(p: *CPath, path: []const u8) ?[*:0]const u8 {
        const s = if (path.len == 0) "." else path;
        if (s.len >= p.b.len or std.mem.indexOfScalar(u8, s, 0) != null) return null;
        @memcpy(p.b[0..s.len], s);
        p.b[s.len] = 0;
        return p.b[0..s.len :0].ptr;
    }
};

/// Opens `path` below the root folder with `flags` and `O_NOFOLLOW`, and
/// no step through a symbolic link. Gives a descriptor or minus an
/// errno.
fn openBeneath(s: *Share, path: []const u8, flags: linux.O, mode: u32) i32 {
    var cp: CPath = .{};
    const p = cp.of(path) orelse return -ninep.E.NAMETOOLONG;
    var f = flags;
    f.NOFOLLOW = true;
    f.CLOEXEC = true;
    var how: extern struct { flags: u64, mode: u64, resolve: u64 } = .{
        .flags = @as(u32, @bitCast(f)),
        .mode = mode,
        .resolve = resolve_beneath | resolve_no_symlinks | resolve_no_magiclinks,
    };
    while (true) {
        const rc = linux.syscall4(.openat2, @as(usize, @bitCast(@as(isize, s.root))), @intFromPtr(p), @intFromPtr(&how), @sizeOf(@TypeOf(how)));
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR, .AGAIN => continue,
            else => |e| return -@as(i32, @intCast(@backingInt(e))),
        }
    }
}

fn pathFd(s: *Share, path: []const u8) i32 {
    return openBeneath(s, path, .{ .PATH = true }, 0);
}

fn dirFd(s: *Share, path: []const u8) i32 {
    return openBeneath(s, path, .{ .PATH = true, .DIRECTORY = true }, 0);
}

fn nameZ(buf: *[256]u8, name: []const u8) ?[*:0]const u8 {
    if (!ninep.validName(name)) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return buf[0..name.len :0].ptr;
}

/// The name `/proc/self/fd/N` of a descriptor.
fn procName(buf: *[32]u8, fd: i32) [*:0]const u8 {
    const s = std.fmt.bufPrintSentinel(buf, "/proc/self/fd/{d}", .{fd}, 0) catch unreachable;
    return s.ptr;
}

fn statFd(fd: i32, out: *ninep.Attr) u32 {
    var x: linux.Statx = undefined;
    const e = err(linux.statx(fd, "", linux.AT.EMPTY_PATH | linux.AT.SYMLINK_NOFOLLOW, linux.STATX.BASIC_STATS, &x));
    if (e != 0) return e;
    const dev = (@as(u64, x.dev_major) << 32) | x.dev_minor;
    out.* = .{
        .mode = x.mode,
        .uid = x.uid,
        .gid = x.gid,
        .nlink = x.nlink,
        .rdev = (@as(u64, x.rdev_major) << 8) | x.rdev_minor,
        .size = x.size,
        .blksize = x.blksize,
        .blocks = x.blocks,
        .atime = .{ .sec = @bitCast(x.atime.sec), .nsec = x.atime.nsec },
        .mtime = .{ .sec = @bitCast(x.mtime.sec), .nsec = x.mtime.nsec },
        .ctime = .{ .sec = @bitCast(x.ctime.sec), .nsec = x.ctime.nsec },
        .ino = x.ino ^ std.math.rotl(u64, dev *% 0x9e3779b97f4a7c15, 32),
    };
    return 0;
}

fn stat(ctx: *anyopaque, path: []const u8, out: *ninep.Attr) u32 {
    const fd = pathFd(share(ctx), path);
    if (fd < 0) return @intCast(-fd);
    defer _ = linux.close(fd);
    return statFd(fd, out);
}

fn openFlags(flags: u32) linux.O {
    var o: linux.O = .{};
    o.ACCMODE = switch (flags & ninep.O.ACCMODE) {
        ninep.O.WRONLY => .WRONLY,
        ninep.O.RDWR => .RDWR,
        else => .RDONLY,
    };
    o.TRUNC = flags & ninep.O.TRUNC != 0;
    o.APPEND = flags & ninep.O.APPEND != 0;
    o.EXCL = flags & ninep.O.EXCL != 0;
    o.DIRECTORY = flags & ninep.O.DIRECTORY != 0;
    o.DSYNC = flags & ninep.O.DSYNC != 0;
    o.SYNC = flags & ninep.O.SYNC == ninep.O.SYNC;
    return o;
}

fn open(ctx: *anyopaque, path: []const u8, flags: u32, out: *u64) u32 {
    // O_NONBLOCK: the open of a FIFO of the host does not stop the vCPU.
    var o = openFlags(flags);
    o.NONBLOCK = true;
    const fd = openBeneath(share(ctx), path, o, 0);
    if (fd < 0) return @intCast(-fd);
    out.* = @intCast(fd);
    return 0;
}

fn create(ctx: *anyopaque, dir: []const u8, name: []const u8, flags: u32, mode: u32, out: *u64) u32 {
    const d = dirFd(share(ctx), dir);
    if (d < 0) return @intCast(-d);
    defer _ = linux.close(d);
    var nb: [256]u8 = undefined;
    const n = nameZ(&nb, name) orelse return ninep.E.INVAL;
    var o = openFlags(flags);
    o.CREAT = true;
    o.NONBLOCK = true;
    o.NOFOLLOW = true;
    o.CLOEXEC = true;
    const rc = linux.openat(d, n, o, mode);
    const e = err(rc);
    if (e != 0) return e;
    out.* = rc;
    return 0;
}

fn close(_: *anyopaque, h: u64) void {
    _ = linux.close(@intCast(h));
}

fn read(_: *anyopaque, h: u64, off: u64, buf: []u8, n: *usize) u32 {
    const rc = linux.pread(@intCast(h), buf.ptr, buf.len, @bitCast(off));
    const e = err(rc);
    if (e == 0) n.* = rc;
    return e;
}

fn write(_: *anyopaque, h: u64, off: u64, data: []const u8, n: *usize) u32 {
    const rc = linux.pwrite(@intCast(h), data.ptr, data.len, @bitCast(off));
    const e = err(rc);
    if (e == 0) n.* = rc;
    return e;
}

fn readdir(_: *anyopaque, h: u64, off: u64, sink: ninep.DirSink) u32 {
    const fd: i32 = @intCast(h);
    var e = err(linux.lseek(fd, @bitCast(off), linux.SEEK.SET));
    if (e != 0) return e;
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const rc = linux.getdents64(fd, &buf, buf.len);
        e = err(rc);
        if (e != 0) return e;
        if (rc == 0) return 0;
        var i: usize = 0;
        while (i < rc) {
            const d: *align(1) const linux.dirent64 = @ptrCast(&buf[i]);
            const name_start = i + @offsetOf(linux.dirent64, "name");
            const name = std.mem.sliceTo(buf[name_start .. i + d.reclen], 0);
            if (!sink.put(sink.ctx, .{ .ino = d.ino, .next = d.off, .kind = d.type, .name = name })) return 0;
            i += d.reclen;
        }
    }
}

fn fsync(_: *anyopaque, h: u64, data_only: bool) u32 {
    return err(if (data_only) linux.fdatasync(@intCast(h)) else linux.fsync(@intCast(h)));
}

fn mkdir(ctx: *anyopaque, dir: []const u8, name: []const u8, mode: u32) u32 {
    const d = dirFd(share(ctx), dir);
    if (d < 0) return @intCast(-d);
    defer _ = linux.close(d);
    var nb: [256]u8 = undefined;
    return err(linux.mkdirat(d, nameZ(&nb, name) orelse return ninep.E.INVAL, mode));
}

fn symlink(ctx: *anyopaque, dir: []const u8, name: []const u8, target: []const u8) u32 {
    const d = dirFd(share(ctx), dir);
    if (d < 0) return @intCast(-d);
    defer _ = linux.close(d);
    var nb: [256]u8 = undefined;
    var tb: CPath = .{};
    if (target.len == 0) return ninep.E.NOENT;
    const t = tb.of(target) orelse return ninep.E.NAMETOOLONG;
    return err(linux.symlinkat(t, d, nameZ(&nb, name) orelse return ninep.E.INVAL));
}

fn link(ctx: *anyopaque, path: []const u8, dir: []const u8, name: []const u8) u32 {
    const s = share(ctx);
    const f = pathFd(s, path);
    if (f < 0) return @intCast(-f);
    defer _ = linux.close(f);
    const d = dirFd(s, dir);
    if (d < 0) return @intCast(-d);
    defer _ = linux.close(d);
    var nb: [256]u8 = undefined;
    var pb: [32]u8 = undefined;
    return err(linux.linkat(linux.AT.FDCWD, procName(&pb, f), d, nameZ(&nb, name) orelse return ninep.E.INVAL, linux.AT.SYMLINK_FOLLOW));
}

fn readlink(ctx: *anyopaque, path: []const u8, buf: []u8, n: *usize) u32 {
    const f = pathFd(share(ctx), path);
    if (f < 0) return @intCast(-f);
    defer _ = linux.close(f);
    const rc = linux.readlinkat(f, "", buf.ptr, buf.len);
    const e = err(rc);
    if (e == 0) n.* = rc;
    return e;
}

fn unlink(ctx: *anyopaque, dir: []const u8, name: []const u8, is_dir: bool) u32 {
    const d = dirFd(share(ctx), dir);
    if (d < 0) return @intCast(-d);
    defer _ = linux.close(d);
    var nb: [256]u8 = undefined;
    return err(linux.unlinkat(d, nameZ(&nb, name) orelse return ninep.E.INVAL, if (is_dir) linux.AT.REMOVEDIR else 0));
}

fn rename(ctx: *anyopaque, dir: []const u8, name: []const u8, new_dir: []const u8, new_name: []const u8) u32 {
    const s = share(ctx);
    const d = dirFd(s, dir);
    if (d < 0) return @intCast(-d);
    defer _ = linux.close(d);
    const nd = dirFd(s, new_dir);
    if (nd < 0) return @intCast(-nd);
    defer _ = linux.close(nd);
    var ob: [256]u8 = undefined;
    var nb: [256]u8 = undefined;
    const o = nameZ(&ob, name) orelse return ninep.E.INVAL;
    const n = nameZ(&nb, new_name) orelse return ninep.E.INVAL;
    return err(linux.renameat(d, o, nd, n));
}

fn timespec(t: ninep.TimeSet) linux.timespec {
    return switch (t) {
        .keep => linux.UTIME.OMIT,
        .now => linux.UTIME.NOW,
        .at => |a| .{ .sec = @intCast(a.sec), .nsec = @intCast(a.nsec) },
    };
}

fn setattr(ctx: *anyopaque, path: []const u8, sa: ninep.SetAttr) u32 {
    const s = share(ctx);
    const f = pathFd(s, path);
    if (f < 0) return @intCast(-f);
    defer _ = linux.close(f);
    var a: ninep.Attr = .{};
    var e = statFd(f, &a);
    if (e != 0) return e;
    const is_link = a.mode & 0o170000 == 0o120000;
    var pb: [32]u8 = undefined;
    const proc = procName(&pb, f);
    if (sa.mode) |m| if (!is_link) {
        e = err(linux.fchmodat(linux.AT.FDCWD, proc, m));
        if (e != 0) return e;
    };
    if (sa.uid != null or sa.gid != null) {
        const uid: u32 = sa.uid orelse std.math.maxInt(u32);
        const gid: u32 = sa.gid orelse std.math.maxInt(u32);
        e = err(linux.fchownat(f, "", uid, gid, linux.AT.EMPTY_PATH | linux.AT.SYMLINK_NOFOLLOW));
        if (e != 0) return e;
    }
    if (sa.size) |size| {
        if (is_link) return ninep.E.INVAL;
        const w = openBeneath(s, path, .{ .ACCMODE = .WRONLY }, 0);
        if (w < 0) return @intCast(-w);
        defer _ = linux.close(w);
        e = err(linux.ftruncate(w, @bitCast(size)));
        if (e != 0) return e;
    }
    if ((sa.atime != .keep or sa.mtime != .keep) and !is_link) {
        const ts = [2]linux.timespec{ timespec(sa.atime), timespec(sa.mtime) };
        e = err(linux.utimensat(linux.AT.FDCWD, proc, &ts, 0));
        if (e != 0) return e;
    }
    return 0;
}

const KStatfs = extern struct {
    kind: i64,
    bsize: i64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    namelen: i64,
    frsize: i64,
    flags: i64,
    spare: [4]i64,
};

fn statfs(ctx: *anyopaque, out: *ninep.StatFs) u32 {
    var k: KStatfs = undefined;
    const e = err(linux.syscall2(.fstatfs, @as(usize, @bitCast(@as(isize, share(ctx).root))), @intFromPtr(&k)));
    if (e != 0) return e;
    out.* = .{
        .kind = @truncate(@as(u64, @bitCast(k.kind))),
        .bsize = @intCast(@max(k.bsize, 0)),
        .blocks = k.blocks,
        .bfree = k.bfree,
        .bavail = k.bavail,
        .files = k.files,
        .ffree = k.ffree,
        .fsid = @bitCast(k.fsid),
        .namelen = @intCast(@max(k.namelen, 0)),
    };
    return 0;
}

test "share_linux: a share of a temporary folder" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var s: Share = .{ .root = tmp.dir.handle, .read_only = false };
    const f = s.fs();
    var h: u64 = 0;
    try testing.expectEqual(@as(u32, 0), f.vt.create(f.ctx, "", "a", ninep.O.RDWR, 0o644, &h));
    var n: usize = 0;
    try testing.expectEqual(@as(u32, 0), f.vt.write(f.ctx, h, 0, "hello", &n));
    f.vt.close(f.ctx, h);
    var a: ninep.Attr = .{};
    try testing.expectEqual(@as(u32, 0), f.vt.stat(f.ctx, "a", &a));
    try testing.expectEqual(@as(u64, 5), a.size);
    try testing.expectEqual(@as(u32, 0), f.vt.mkdir(f.ctx, "", "d", 0o755));
    try testing.expectEqual(@as(u32, 0), f.vt.symlink(f.ctx, "d", "up", "../.."));
    // A walk through the symbolic link stops: the guest resolves it.
    try testing.expectEqual(@as(u32, 40), f.vt.stat(f.ctx, "d/up/a", &a)); // ELOOP
    try testing.expectEqual(@as(u32, 0), f.vt.stat(f.ctx, "d/up", &a));
    try testing.expectEqual(ninep.Qid.symlink, a.qid().kind);
    var lb: [64]u8 = undefined;
    try testing.expectEqual(@as(u32, 0), f.vt.readlink(f.ctx, "d/up", &lb, &n));
    try testing.expectEqualStrings("../..", lb[0..n]);
    try testing.expectEqual(@as(u32, 0), f.vt.rename(f.ctx, "", "a", "d", "b"));
    try testing.expectEqual(@as(u32, 0), f.vt.setattr(f.ctx, "d/b", .{ .size = 2, .mode = 0o600 }));
    try testing.expectEqual(@as(u32, 0), f.vt.stat(f.ctx, "d/b", &a));
    try testing.expectEqual(@as(u64, 2), a.size);
    try testing.expectEqual(@as(u32, 0o100600), a.mode);
    try testing.expectEqual(@as(u32, 0), f.vt.open(f.ctx, "d", ninep.O.RDONLY | ninep.O.DIRECTORY, &h));
    const Names = struct {
        got: [4][16]u8 = undefined,
        n: usize = 0,
        fn put(ctx: *anyopaque, e: ninep.Dirent) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (e.name[0] == '.' and (e.name.len == 1 or e.name[1] == '.')) return true;
            @memcpy(self.got[self.n][0..e.name.len], e.name);
            self.got[self.n][e.name.len] = 0;
            self.n += 1;
            return true;
        }
    };
    var names: Names = .{};
    try testing.expectEqual(@as(u32, 0), f.vt.readdir(f.ctx, h, 0, .{ .ctx = &names, .put = Names.put }));
    f.vt.close(f.ctx, h);
    try testing.expectEqual(@as(usize, 2), names.n);
    try testing.expectEqual(@as(u32, 0), f.vt.unlink(f.ctx, "d", "b", false));
    try testing.expectEqual(@as(u32, 0), f.vt.unlink(f.ctx, "d", "up", false));
    try testing.expectEqual(@as(u32, 0), f.vt.unlink(f.ctx, "", "d", true));
    var st: ninep.StatFs = .{};
    try testing.expectEqual(@as(u32, 0), f.vt.statfs(f.ctx, &st));
    try testing.expect(st.bsize > 0);
}

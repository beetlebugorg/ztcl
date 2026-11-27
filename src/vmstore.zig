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

/// The platforms of the store: the hosts of `ztcl::vm`.
pub const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

/// The architecture of the host in a manifest.
pub const host_arch = switch (builtin.cpu.arch) {
    .aarch64 => "arm64",
    .x86_64 => "x86_64",
    else => "other",
};

fn ok(rc: usize) bool {
    return os.errno(rc) == .SUCCESS;
}

fn z(a: Allocator, s: []const u8) Allocator.Error![:0]u8 {
    return a.dupeSentinel(u8, s, 0);
}

/// Makes the folder `path` and each parent.
fn mkdirs(a: Allocator, path: []const u8) Error!void {
    var k: usize = 1;
    while (k <= path.len) : (k += 1) {
        if (k == path.len or path[k] == '/') {
            const p = try z(a, path[0..k]);
            defer a.free(p);
            const rc = os.mkdirat(os.AT.FDCWD, p, 0o755);
            if (!ok(rc) and os.errno(rc) != .EXIST) return error.Io;
        }
    }
}

fn join(a: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
    return std.mem.join(a, "/", parts);
}

fn readAll(a: Allocator, path: []const u8, max: usize) Error![]u8 {
    const p = try z(a, path);
    defer a.free(p);
    const rc = os.open(p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (!ok(rc)) return if (os.errno(rc) == .NOENT) error.NotFound else error.Io;
    const fd: i32 = @intCast(rc);
    defer _ = os.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = os.read(fd, &buf, buf.len);
        if (!ok(n)) return error.Io;
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
    try writeNew(a, tmp, data);
    try rename(a, tmp, path);
}

fn writeNew(a: Allocator, path: []const u8, data: []const u8) Error!void {
    const p = try z(a, path);
    defer a.free(p);
    const rc = os.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o644);
    if (!ok(rc)) return error.Io;
    const fd: i32 = @intCast(rc);
    defer _ = os.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = os.write(fd, data[off..].ptr, data.len - off);
        if (!ok(n) or n == 0) return error.Io;
        off += n;
    }
}

fn rename(a: Allocator, from: []const u8, to: []const u8) Error!void {
    const f = try z(a, from);
    defer a.free(f);
    const t = try z(a, to);
    defer a.free(t);
    if (!ok(os.renameat(os.AT.FDCWD, f, os.AT.FDCWD, t))) return error.Io;
}

fn exists(a: Allocator, path: []const u8) bool {
    const p = z(a, path) catch return false;
    defer a.free(p);
    const rc = os.open(p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (!ok(rc)) return false;
    _ = os.close(@intCast(rc));
    return true;
}

fn unlink(a: Allocator, path: []const u8, dir: bool) void {
    const p = z(a, path) catch return;
    defer a.free(p);
    _ = os.unlinkat(os.AT.FDCWD, p, if (dir) os.AT.REMOVEDIR else 0);
}

/// The names in the folder `path`, with no `.` and `..`.
fn listDir(a: Allocator, path: []const u8) Error![][]u8 {
    const p = try z(a, path);
    defer a.free(p);
    const rc = os.open(p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (!ok(rc)) return if (os.errno(rc) == .NOENT) &.{} else error.Io;
    const fd: i32 = @intCast(rc);
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

fn freeList(a: Allocator, l: [][]u8) void {
    for (l) |x| a.free(x);
    a.free(l);
}

var tmp_counter = std.atomic.Value(u64).init(0);

pub const Store = struct {
    root: []const u8,

    /// Opens the store at `root`, and makes its folders.
    pub fn open(a: Allocator, root: []const u8) Error!Store {
        if (root.len == 0) return error.NoStore;
        for ([_][]const u8{ "objects", "releases", "tmp" }) |sub| {
            const p = try join(a, &.{ root, sub });
            defer a.free(p);
            try mkdirs(a, p);
        }
        return .{ .root = root };
    }

    fn tmpName(s: Store, a: Allocator) Allocator.Error![]u8 {
        var r: [8]u8 = undefined;
        @import("isoproto.zig").entropy(&r);
        const n = tmp_counter.fetchAdd(1, .monotonic);
        return std.fmt.allocPrint(a, "{s}/tmp/{x}-{d}", .{ s.root, std.mem.readInt(u64, &r, .little), n });
    }

    pub fn objectPath(s: Store, a: Allocator, sha: []const u8) Allocator.Error![]u8 {
        return join(a, &.{ s.root, "objects", sha });
    }

    fn counterFile(s: Store, a: Allocator, name: []const u8, which: []const u8) Error!?u64 {
        const p = try join(a, &.{ s.root, "releases", name, which });
        defer a.free(p);
        const t = readAll(a, p, 64) catch |e| return if (e == error.NotFound) null else e;
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
        const dest = try s.objectPath(a, sha);
        defer a.free(dest);
        if (exists(a, dest)) return;
        try writeAtomic(a, s, dest, data);
    }

    /// Installs the release in the folder `src` (a manifest, its
    /// signature, and the files of the manifest): the files of `arch`
    /// must be there, and the files of the other architectures that are
    /// there come too. Gives the name and the counter.
    pub fn install(s: Store, a: Allocator, src: []const u8, arch: []const u8, allow_rollback: bool) Error!struct { name: []u8, counter: u64, key: []const u8 } {
        const mpath = try join(a, &.{ src, "manifest.json" });
        defer a.free(mpath);
        const manifest = try readAll(a, mpath, 1 << 20);
        defer a.free(manifest);
        const spath = try join(a, &.{ src, "manifest.json.sig" });
        defer a.free(spath);
        const sig = try readAll(a, spath, 1 << 16);
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
                const p = try join(a, &.{ src, f.file });
                defer a.free(p);
                const data = readAll(a, p, 8 << 30) catch |e| switch (e) {
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
        const ndir = try join(a, &.{ s.root, "releases", name });
        defer a.free(ndir);
        try mkdirs(a, ndir);
        const rdir = try join(a, &.{ ndir, cs });
        defer a.free(rdir);
        if (!exists(a, rdir)) {
            const tmp = try s.tmpName(a);
            defer a.free(tmp);
            try mkdirs(a, tmp);
            for ([_][]const u8{ "manifest.json", "manifest.json.sig" }, [_][]const u8{ manifest, sig }) |fname, data| {
                const p = try join(a, &.{ tmp, fname });
                defer a.free(p);
                try writeNew(a, p, data);
            }
            try rename(a, tmp, rdir);
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
        const mp = try join(a, &.{ s.root, "releases", name, cs, "manifest.json" });
        defer a.free(mp);
        const sp = try join(a, &.{ s.root, "releases", name, cs, "manifest.json.sig" });
        defer a.free(sp);
        const manifest = try readAll(a, mp, 1 << 20);
        defer a.free(manifest);
        const sig = try readAll(a, sp, 1 << 16);
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
            const p = try s.objectPath(a, f.sha256);
            defer a.free(p);
            const data = readAll(a, p, 8 << 30) catch |e| return if (e == error.NotFound) error.Missing else e;
            defer a.free(data);
            try vmimage.checkHash(data, f.sha256);
            n += 1;
        }
        return n;
    }

    pub const Entry = struct { name: []u8, counters: []u64, current: ?u64 };

    /// Each name and the counters of its releases, in order.
    pub fn list(s: Store, a: Allocator) Error![]Entry {
        const rp = try join(a, &.{ s.root, "releases" });
        defer a.free(rp);
        const names = try listDir(a, rp);
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
            const subs = try listDir(a, np);
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

    /// Removes a release, or each release of `name` when `counter` is
    /// null, then each object that no release names.
    pub fn remove(s: Store, a: Allocator, name: []const u8, counter: ?u64) Error!void {
        const np = try join(a, &.{ s.root, "releases", name });
        defer a.free(np);
        if (!exists(a, np)) return error.NotFound;
        const subs = try listDir(a, np);
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
                unlink(a, p, false);
            }
            const d = try join(a, &.{ np, x });
            defer a.free(d);
            unlink(a, d, true);
        }
        if (!found) return error.NotFound;
        if (counter == null or (try s.current(a, name)) == counter) {
            const cp = try join(a, &.{ np, "current" });
            defer a.free(cp);
            unlink(a, cp, false);
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
        const op = try join(a, &.{ s.root, "objects" });
        defer a.free(op);
        const objs = try listDir(a, op);
        defer freeList(a, objs);
        for (objs) |o| if (!keep.contains(o)) {
            const p = try join(a, &.{ op, o });
            defer a.free(p);
            unlink(a, p, false);
        };
    }
};

pub fn freeEntries(a: Allocator, entries: []Store.Entry) void {
    for (entries) |e| {
        a.free(e.name);
        a.free(e.counters);
    }
    a.free(entries);
}

test "vmstore: install, list, check, rollback, and remove" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(base);
    // A release folder: the signed manifest of the fixtures, and its
    // kernel, the 4 bytes "test".
    const src = try join(a, &.{ base, "src" });
    defer a.free(src);
    try mkdirs(a, src);
    const files = [_][2][]const u8{
        .{ "manifest.json", @embedFile("vmimage_fixtures/manifest.json") },
        .{ "manifest.json.sig", @embedFile("vmimage_fixtures/manifest.json.sig.good") },
        .{ "Image", "test" },
    };
    for (files) |f| {
        const p = try join(a, &.{ src, f[0] });
        defer a.free(p);
        try writeNew(a, p, f[1]);
    }
    const root = try join(a, &.{ base, "store" });
    defer a.free(root);
    const s = try Store.open(a, root);
    const r = try s.install(a, src, "arm64", false);
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
    try std.testing.expectError(error.Missing, s.install(a, src, "x86_64", false));
    // A changed object fails the check.
    const obj = try s.objectPath(a, "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08");
    defer a.free(obj);
    unlink(a, obj, false);
    try writeNew(a, obj, "tesT");
    try std.testing.expectError(error.Hash, s.verifyRelease(a, r.name, 3, "arm64"));
    // A higher counter seen before: the same release is a rollback.
    const hp = try join(a, &.{ root, "releases", r.name, "highest" });
    defer a.free(hp);
    try writeAtomic(a, s, hp, "9");
    try std.testing.expectError(error.Rollback, s.install(a, src, "arm64", false));
    // The removal of the release takes its objects.
    try s.remove(a, r.name, null);
    try std.testing.expect(!exists(a, obj));
    try std.testing.expectEqual(@as(?u64, null), try s.current(a, r.name));
    try std.testing.expectError(error.NotFound, s.remove(a, r.name, 3));
}

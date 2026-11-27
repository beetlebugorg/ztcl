//! The WASI 0.3.2 form of the folder jail of `fsroot.zig`, for the
//! command component (docs/dev/wasi-tasks/06-native.md).
//!
//! The root is a `descriptor` of `wasi:filesystem` below a preopen, in a
//! slot of the table of `sys_wasi3.zig`. `setRoot` finds the preopen with
//! the longest name that is a prefix of the root path at a `/`, and opens
//! the rest of the path below it. `fsroot.normal` checks each path as
//! text first, so a `..` above the root is an error before a call. Each
//! open then walks the path from the root descriptor, one name at a time,
//! with no symlink followed. A symlink in any component gives an error,
//! so no open leaves the root. The host checks each path against the
//! preopen too.
//!
//! The calls of `wasi:filesystem` are `async func`: each one waits in the
//! waitable set of `sys_wasi3.zig` for its subtask. WASI 0.3.2 has no
//! mode bits, users, groups, or inode numbers. `stat` gives 0o755 for a
//! folder, 0o644 for other files, 0 for the user and the group, and the
//! two halves of `metadata-hash-at` as the inode and the device.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const Interp = interp.Interp;
const Error = interp.Error;
const sys = @import("sys.zig");
const fsroot = @import("fsroot.zig");
const host = @import("sys_wasi3.zig");
const p3 = @import("wasi/p3.zig");
const abi = @import("wasi/async.zig");

const T = p3.filesystem_types;
const E = std.os.wasi.errno_t;
const gpa = std.heap.wasm_allocator;

fn str(s: []const u8) p3.String {
    return .{ .ptr = @intFromPtr(s.ptr), .len = @intCast(s.len) };
}

/// Frees a text that the host put in memory through `cabi_realloc`.
fn freeText(s: p3.String) void {
    if (s.len > 0) gpa.free(@as([*]u8, @ptrFromInt(s.ptr))[0..s.len]);
}

fn freeError(c: T.ErrorCode) void {
    if (c.tag == .other and c.payload.other.tag == 1) freeText(c.payload.other.value);
}

/// The errno of a failed result, with its text freed.
fn fail(c: T.ErrorCode) E {
    freeError(c);
    return host.errnoOf(c);
}

fn descOf(fd: i32) ?T.Descriptor {
    const s = host.slotOf(fd) orelse return null;
    return s.desc;
}

/// The `path-flags` of a call that follows no symlink.
const no_follow: u32 = @as(u8, @bitCast(T.PathFlags{}));

const Opened = union(enum) { desc: T.Descriptor, err: E };

fn openAt(dir: T.Descriptor, name: []const u8, oflags: T.OpenFlags, flags: T.DescriptorFlags) Opened {
    var params: T.descriptor_open_at.Params = .{
        .self = dir,
        .path_flags = .{},
        .path = str(name),
        .open_flags = oflags,
        .flags = flags,
    };
    var ret: T.descriptor_open_at.Ret = undefined;
    if (!abi.call(host.set(), T.descriptor_open_at.call(@intFromPtr(&params), @intFromPtr(&ret)))) return .{ .err = .IO };
    if (ret.tag != 0) return .{ .err = fail(ret.payload.err) };
    return .{ .desc = ret.payload.ok };
}

const dir_flags: T.DescriptorFlags = .{ .read = true, .mutate_directory = true };

fn fileFlags(flags: sys.OpenFlags) T.DescriptorFlags {
    return .{ .read = flags.access != .write, .write = flags.access != .read };
}

fn toFd(o: Opened, append: bool) fsroot.OpenResult {
    switch (o) {
        .desc => |d| {
            const fd = host.addSlot(d, append) orelse {
                T.drop_descriptor(d);
                return .{ .err = .NOMEM };
            };
            return .{ .fd = fd };
        },
        .err => |e| return .{ .err = e },
    }
}

pub fn setRoot(it: *Interp, path: []const u8) !void {
    const p = host.preopenOf(path) orelse return error.BadRoot;
    const rest = if (p.rest.len == 0) "." else p.rest;
    switch (toFd(openAt(p.dir, rest, .{ .directory = true }, dir_flags), false)) {
        .fd => |fd| it.fs.fd = fd,
        .err => return error.BadRoot,
    }
    it.fs.path = try it.alloc().dupe(u8, std.mem.trimEnd(u8, path, "/"));
}

/// Opens a normal path below the root, one name at a time from the root.
pub fn openRel(it: *Interp, rel: []const u8, flags: sys.OpenFlags, mode: u32) Error!fsroot.OpenResult {
    _ = mode;
    const root = descOf(it.fs.fd) orelse return it.fail("the embedder gave no root folder", .{});
    const want_dir = flags.directory or flags.path_only;
    const last_oflags: T.OpenFlags = .{ .create = flags.create, .exclusive = flags.exclusive, .truncate = flags.truncate, .directory = flags.directory };
    const last_flags = if (want_dir) dir_flags else fileFlags(flags);
    if (rel.len == 0) return toFd(openAt(root, ".", last_oflags, last_flags), flags.append);
    var cur = root;
    defer if (cur != root) T.drop_descriptor(cur);
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |w| {
        if (w.len == 0 or std.mem.eql(u8, w, ".") or std.mem.eql(u8, w, "..") or std.mem.indexOfScalar(u8, w, 0) != null) return .{ .err = .ACCES };
        if (parts.peek() == null) return toFd(openAt(cur, w, last_oflags, last_flags), flags.append);
        switch (openAt(cur, w, .{ .directory = true }, dir_flags)) {
            .desc => |d| {
                if (cur != root) T.drop_descriptor(cur);
                cur = d;
            },
            .err => |e| return .{ .err = e },
        }
    }
    return .{ .err = .ACCES };
}

fn seconds(t: p3.Option(p3.clocks_system_clock.Instant)) i64 {
    return if (t.tag == 1) t.value.seconds else 0;
}

fn info(st: T.DescriptorStat, hash: [2]u64) fsroot.Info {
    if (st.type.tag == .other and st.type.payload.other.tag == 1) freeText(st.type.payload.other.value);
    const kind: u32 = switch (st.type.tag) {
        .directory => 0o040000,
        .regular_file => 0o100000,
        .symbolic_link => 0o120000,
        .character_device => 0o020000,
        .block_device => 0o060000,
        .fifo => 0o010000,
        .socket => 0o140000,
        .other => 0,
    };
    const perm: u32 = if (st.type.tag == .directory) 0o755 else 0o644;
    return .{
        .mode = kind | perm,
        .size = st.size,
        .mtime = seconds(st.data_modification_timestamp),
        .atime = seconds(st.data_access_timestamp),
        .ctime = seconds(st.status_change_timestamp),
        .ino = hash[0],
        .nlink = @intCast(@min(st.link_count, std.math.maxInt(u32))),
        .uid = 0,
        .gid = 0,
        .dev = hash[1],
    };
}

/// The two halves of `metadata-hash-at`, or zeros.
fn hashAt(dir: T.Descriptor, name: []const u8) [2]u64 {
    var ret: T.descriptor_metadata_hash_at.Ret = undefined;
    if (!abi.call(host.set(), T.descriptor_metadata_hash_at.call(dir, no_follow, @intFromPtr(name.ptr), @intCast(name.len), @intFromPtr(&ret)))) return .{ 0, 0 };
    if (ret.tag != 0) {
        freeError(ret.payload.err);
        return .{ 0, 0 };
    }
    return .{ ret.payload.ok.lower, ret.payload.ok.upper };
}

pub fn stat(it: *Interp, rel: []const u8) Error!fsroot.StatResult {
    var ret: T.descriptor_stat_at.Ret = undefined;
    if (rel.len == 0) {
        const root = descOf(it.fs.fd) orelse return .{ .err = .BADF };
        if (!abi.call(host.set(), T.descriptor_stat_at.call(root, no_follow, @intFromPtr(".".ptr), 1, @intFromPtr(&ret)))) return .{ .err = .IO };
        if (ret.tag != 0) return .{ .err = fail(ret.payload.err) };
        return .{ .ok = info(ret.payload.ok, hashAt(root, ".")) };
    }
    const p = switch (try fsroot.parentOf(it, rel)) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    defer host.close(p.fd);
    const dir = descOf(p.fd) orelse return .{ .err = .BADF };
    if (!abi.call(host.set(), T.descriptor_stat_at.call(dir, no_follow, @intFromPtr(p.base.ptr), @intCast(p.base.len), @intFromPtr(&ret)))) return .{ .err = .IO };
    if (ret.tag != 0) return .{ .err = fail(ret.payload.err) };
    return .{ .ok = info(ret.payload.ok, hashAt(dir, p.base)) };
}

pub fn listDir(it: *Interp, rel: []const u8) Error!fsroot.ListResult {
    const fd = switch (try openRel(it, rel, .{ .directory = true }, 0)) {
        .fd => |x| x,
        .err => |e| return .{ .err = e },
    };
    defer host.close(fd);
    const D = T.descriptor_read_directory;
    var pair: D.Ret = undefined;
    D.call(descOf(fd).?, @intFromPtr(&pair));
    const st = pair.@"0";
    const fut = pair.@"1";
    const a = it.alloc();
    var out: std.ArrayList([]const u8) = .empty;
    var buf: [32]T.DirectoryEntry = undefined;
    var oom = false;
    while (true) {
        const c = abi.finish(host.set(), st, D.stream0.read(st, @intFromPtr(&buf), buf.len));
        for (buf[0..c.count]) |e| {
            if (e.type.tag == .other and e.type.payload.other.tag == 1) freeText(e.type.payload.other.value);
            const name = if (e.name.len == 0) "" else @as([*]const u8, @ptrFromInt(e.name.ptr))[0..e.name.len];
            if (!oom and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                if (a.dupe(u8, name)) |d| {
                    out.append(a, d) catch {
                        oom = true;
                    };
                } else |_| oom = true;
            }
            freeText(e.name);
        }
        if (c.state != .completed) break;
    }
    D.stream0.drop_readable(st);
    var res: D.future1.Elem = undefined;
    _ = abi.finish(host.set(), fut, D.future1.read(fut, @intFromPtr(&res)));
    D.future1.drop_readable(fut);
    if (oom) return error.OutOfMemory;
    if (res.tag != 0) return .{ .err = fail(res.payload.err) };
    std.mem.sort([]const u8, out.items, {}, nameLess);
    return .{ .ok = out.items };
}

fn nameLess(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// The child opens the root folder again.
pub fn shareRoot(it: *const Interp, child: *Interp) std.mem.Allocator.Error!void {
    const root = descOf(it.fs.fd) orelse return;
    switch (toFd(openAt(root, ".", .{ .directory = true }, dir_flags), false)) {
        .fd => |fd| child.fs.fd = fd,
        .err => {},
    }
}

fn done(status: u32, ret: *const T.descriptor_unlink_file_at.Ret) ?E {
    if (!abi.call(host.set(), status)) return .IO;
    if (ret.tag != 0) return fail(ret.payload.err);
    return null;
}

pub fn removeAt(p: fsroot.Parent, dir: bool) ?E {
    const d = descOf(p.fd) orelse return .BADF;
    var ret: T.descriptor_unlink_file_at.Ret = undefined;
    const ptr: u32 = @intFromPtr(p.base.ptr);
    const len: u32 = @intCast(p.base.len);
    const status = if (dir)
        T.descriptor_remove_directory_at.call(d, ptr, len, @intFromPtr(&ret))
    else
        T.descriptor_unlink_file_at.call(d, ptr, len, @intFromPtr(&ret));
    return done(status, &ret);
}

pub fn mkdirAt(p: fsroot.Parent) ?E {
    const d = descOf(p.fd) orelse return .BADF;
    var ret: T.descriptor_unlink_file_at.Ret = undefined;
    return done(T.descriptor_create_directory_at.call(d, @intFromPtr(p.base.ptr), @intCast(p.base.len), @intFromPtr(&ret)), &ret);
}

pub fn renameAt(p: fsroot.Parent, q: fsroot.Parent) ?E {
    const d = descOf(p.fd) orelse return .BADF;
    const e = descOf(q.fd) orelse return .BADF;
    var params: T.descriptor_rename_at.Params = .{ .self = d, .old_path = str(p.base), .new_descriptor = e, .new_path = str(q.base) };
    var ret: T.descriptor_unlink_file_at.Ret = undefined;
    return done(T.descriptor_rename_at.call(@intFromPtr(&params), @intFromPtr(&ret)), &ret);
}

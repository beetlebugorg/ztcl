//! `file link`, `file readlink`, `file attributes`, and `file atime` and
//! `file mtime` with a new time, on Linux and macOS.
//!
//! Each call works on the descriptor of the parent folder and the last
//! name, from `fsroot.parentOf`, with the `*at` system calls: `symlinkat`,
//! `linkat`, `readlinkat`, `utimensat`, `fchmodat2`, and `fchownat`. So a
//! call in the root folder stays below the root, as each other call of
//! `file` does. In the root folder each change has AT_SYMLINK_NOFOLLOW:
//! a symbolic link of the host there never takes a change to a file
//! outside the root. The root folder has no new links: each open there refuses
//! a symbolic link, so a link has no use there. `file readlink` there
//! gives the error of a file that is not a link, so the text of a link
//! that the host made stays hidden.
//!
//! The names of `-owner` and `-group` come from `/etc/passwd` and
//! `/etc/group` in host mode, since ztcl links no C library. A user or a
//! group with no line there shows as its number. Windows has none of these
//! calls in this version: each one is an error there.
// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const fsroot = @import("fsroot.zig");
const sys = @import("sys.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Error = interp.Error;
const os = sys.os;

/// True on the targets of this file.
pub const supported = builtin.os.tag == .linux or builtin.os.tag == .macos;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn errnoOf(rc: usize) ?sys.Errno {
    const e = os.errno(rc);
    return if (e == .SUCCESS) null else e;
}

/// The parent folder of the path `name`, or the POSIX error of `what`.
fn parent(it: *Interp, name: []const u8, what: []const u8) Error!fsroot.Parent {
    const rel = try fsroot.need(it, name);
    return switch (try fsroot.parentOf(it, rel)) {
        .ok => |p| p,
        .err => |e| fsroot.posixError(it, e, what),
    };
}

/// The data of `name`, or the error `could not read "NAME": ...`.
fn info(it: *Interp, name: []const u8) Error!fsroot.Info {
    const rel = try fsroot.need(it, name);
    return switch (try fsroot.stat(it, rel)) {
        .ok => |x| x,
        .err => |e| fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "could not read \"{s}\": ", .{name})),
    };
}

/// The flags of a change: in the root folder no symlink is followed,
/// and host mode follows them, as tclsh does.
fn noFollow(it: *const Interp) u32 {
    return if (it.fs.host) 0 else @intCast(os.AT.SYMLINK_NOFOLLOW);
}

/// A test hook: true takes the path of a Linux kernel with no
/// `fchmodat2` (before 6.6) in the root folder.
pub var test_no_fchmodat2 = false;

/// A change of the permissions of the name of `p`. Host mode follows a
/// symbolic link, as tclsh does. The root folder never follows one:
/// `fchmodat2` with AT_SYMLINK_NOFOLLOW, and on a kernel with no
/// `fchmodat2`, a descriptor of the name with O_PATH and O_NOFOLLOW and
/// a `fchmodat` of its `/proc/self/fd` name. With no `/proc`, the
/// change is an error: no call there refuses a link.
fn chmodAt(it: *Interp, p: fsroot.Parent, name: []const u8, mode: u32) Error!?sys.Errno {
    const flags = noFollow(it);
    if (builtin.os.tag == .macos) return errnoOf(os.fchmodat2(p.fd, p.base, @intCast(mode), flags));
    if (flags == 0) return errnoOf(os.fchmodat(p.fd, p.base, mode));
    if (!test_no_fchmodat2) {
        const e = errnoOf(os.fchmodat2(p.fd, p.base, mode, flags)) orelse return null;
        // A symbolic link: the root jail refuses it.
        if (e == .OPNOTSUPP) return .ACCES;
        if (e != .NOSYS) return e;
    }
    return chmodByFd(it, p, name, mode);
}

/// The path of `chmodAt` with no `fchmodat2`, on Linux.
fn chmodByFd(it: *Interp, p: fsroot.Parent, name: []const u8, mode: u32) Error!?sys.Errno {
    const rc = os.openat(p.fd, p.base, .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (errnoOf(rc)) |e| return e;
    const fd: i32 = @intCast(rc);
    defer _ = os.close(fd);
    var st: os.Statx = undefined;
    // AT_EMPTY_PATH: the data of the descriptor itself.
    if (errnoOf(os.statx(fd, "", 0x1000, .{ .TYPE = true }, &st))) |e| return e;
    if (st.mode & 0o170000 == 0o120000) return .ACCES;
    var buf: [32:0]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "/proc/self/fd/{d}", .{fd}, 0) catch unreachable;
    const e = errnoOf(os.fchmodat(os.AT.FDCWD, path, mode)) orelse return null;
    if (e == .NOENT) return it.failCode("POSIX ENOSYS {function not implemented}", "could not set permissions for file \"{s}\": the system has no safe call for a change in the root folder", .{name});
    return e;
}

// ---- Times ----

/// `file atime NAME TIME` and `file mtime NAME TIME`: sets the time and
/// gives it. The other time stays.
pub fn setTime(it: *Interp, sub: []const u8, name: []const u8, time: Value) Error!Value {
    const t = try it.int(time);
    if (comptime !supported) return it.fail("file {s} with a new time is not available on this platform", .{sub});
    const st = try info(it, name);
    var times: [2]os.timespec = .{
        .{ .sec = @intCast(st.atime), .nsec = 0 },
        .{ .sec = @intCast(st.mtime), .nsec = 0 },
    };
    times[if (eql(sub, "atime")) 0 else 1] = .{ .sec = @intCast(t), .nsec = 0 };
    const what = try std.fmt.allocPrint(it.alloc(), "could not set {s} time for file \"{s}\": ", .{ if (eql(sub, "atime")) "access" else "modification", name });
    const p = try parent(it, name, what);
    defer sys.close(p.fd);
    if (errnoOf(os.utimensat(p.fd, p.base, &times, noFollow(it)))) |e| return fsroot.posixError(it, e, what);
    return .{ .int = t };
}

// ---- Links ----

/// `file link ?-symbolic|-hard? LINK ?TARGET?`.
pub fn link(it: *Interp, args: []const Value) Error!Value {
    if (args.len < 1 or args.len > 3) return it.wrongArgs("file link ?-linktype? linkname ?target?");
    if (args.len == 1) return readLink(it, try it.str(args[0]));
    var kind: enum { any, symbolic, hard } = .any;
    var at: usize = 0;
    if (args.len == 3) {
        const o = try it.str(args[0]);
        if (o.len > 1 and std.mem.startsWith(u8, "-symbolic", o)) {
            kind = .symbolic;
        } else if (o.len > 1 and std.mem.startsWith(u8, "-hard", o)) {
            kind = .hard;
        } else return it.failWords(&.{ "TCL", "LOOKUP", "INDEX", "option", o }, "bad option \"{s}\": must be -symbolic or -hard", .{o});
        at = 1;
    }
    const name = try it.str(args[at]);
    const target = try it.str(args[at + 1]);
    if (comptime !supported) return it.failCode("POSIX EACCES {permission denied}", "could not create new link \"{s}\": links are not available on this platform", .{name});
    if (!it.fs.host) return it.failCode("POSIX EACCES {permission denied}", "could not create new link \"{s}\": links are not available in the root folder", .{name});
    const a = it.alloc();
    // The name must not exist, and the target must, as in Tcl.
    if (try exists(it, name)) return it.failCode("POSIX EEXIST {file already exists}", "could not create new link \"{s}\": that path already exists", .{name});
    if (!try exists(it, target)) {
        if (!try exists(it, dirname(name))) return it.failCode("POSIX ENOENT {no such file or directory}", "could not create new link \"{s}\": no such file or directory", .{name});
        return it.failCode("POSIX ENOENT {no such file or directory}", "could not create new link \"{s}\": target \"{s}\" doesn't exist", .{ name, target });
    }
    const what = try std.fmt.allocPrint(a, "could not create new link \"{s}\" pointing to \"{s}\": ", .{ name, target });
    const p = try parent(it, name, what);
    defer sys.close(p.fd);
    if (kind != .hard) {
        const tz = try a.dupeSentinel(u8, target, 0);
        const e = errnoOf(os.symlinkat(tz, p.fd, p.base)) orelse return args[at + 1];
        if (kind == .symbolic) return fsroot.posixError(it, e, what);
    }
    // A hard link of the target: the target is a path of this mode.
    const q = try parent(it, target, what);
    defer sys.close(q.fd);
    if (errnoOf(os.linkat(q.fd, q.base, p.fd, p.base, 0))) |e| return fsroot.posixError(it, e, what);
    return args[at + 1];
}

fn dirname(p: []const u8) []const u8 {
    const k = std.mem.lastIndexOfScalar(u8, p, '/') orelse return ".";
    return if (k == 0) "/" else p[0..k];
}

/// True when `name` names a file of any kind, a link included.
fn exists(it: *Interp, name: []const u8) Error!bool {
    const rel = (try fsroot.normal(it, name)) orelse return false;
    return switch (try fsroot.stat(it, rel)) {
        .ok => true,
        .err => false,
    };
}

/// `file readlink NAME`: the text of the symbolic link NAME.
pub fn readLink(it: *Interp, name: []const u8) Error!Value {
    const what = try std.fmt.allocPrint(it.alloc(), "could not read link \"{s}\": ", .{name});
    if (comptime !supported) return it.failCode("POSIX EACCES {permission denied}", "could not read link \"{s}\": links are not available on this platform", .{name});
    // The root folder has no links for a script: a name there reads as a
    // file that is not a link, and the text of a link stays hidden.
    if (!it.fs.host) {
        if (try exists(it, name)) return it.failCode("POSIX EINVAL {invalid argument}", "could not read link \"{s}\": invalid argument", .{name});
        return it.failCode("POSIX ENOENT {no such file or directory}", "could not read link \"{s}\": no such file or directory", .{name});
    }
    const p = try parent(it, name, what);
    defer sys.close(p.fd);
    var buf: [4096]u8 = undefined;
    const rc = os.readlinkat(p.fd, p.base, &buf, buf.len);
    if (errnoOf(rc)) |e| return fsroot.posixError(it, e, what);
    return .{ .str = try it.alloc().dupe(u8, buf[0..rc]) };
}

// ---- Attributes ----

const attr_names = [_][]const u8{ "-group", "-owner", "-permissions" };

/// `file attributes NAME ?OPTION? ?OPTION VALUE ...?`.
pub fn attributes(it: *Interp, args: []const Value) Error!Value {
    if (args.len < 1) return it.wrongArgs("file attributes name ?-option value ...?");
    const name = try it.str(args[0]);
    if (comptime !supported) return it.fail("file attributes is not available on this platform", .{});
    const st = try info(it, name);
    const a = it.alloc();
    if (args.len == 1) {
        var out: [6]Value = undefined;
        for (attr_names, 0..) |n, k| {
            out[2 * k] = .{ .str = n };
            out[2 * k + 1] = try get(it, k, st);
        }
        return value.newList(a, &out);
    }
    if (args.len == 2) return get(it, try option(it, args[1]), st);
    if (args.len % 2 == 0) return it.fail("wrong # args: must be \"file attributes name ?-option value ...?\"", .{});
    var k: usize = 1;
    while (k < args.len) : (k += 2) _ = try option(it, args[k]);
    k = 1;
    while (k < args.len) : (k += 2) try set(it, name, try option(it, args[k]), try it.str(args[k + 1]), st);
    return Value.empty;
}

/// The index of an option name or of a unique prefix of one.
fn option(it: *Interp, v: Value) Error!usize {
    const o = try it.str(v);
    var hit: ?usize = null;
    for (attr_names, 0..) |n, k| {
        if (eql(n, o)) return k;
        if (o.len > 1 and std.mem.startsWith(u8, n, o)) hit = if (hit == null) k else attr_names.len;
    }
    if (hit) |k| if (k < attr_names.len) return k;
    return it.failWords(&.{ "TCL", "LOOKUP", "INDEX", "option", o }, "bad option \"{s}\": must be -group, -owner, or -permissions", .{o});
}

fn get(it: *Interp, k: usize, st: fsroot.Info) Error!Value {
    const a = it.alloc();
    return switch (k) {
        0 => .{ .str = try nameOf(it, "/etc/group", st.gid) },
        1 => .{ .str = try nameOf(it, "/etc/passwd", st.uid) },
        else => blk: {
            // The form of `%0#5lo` in Tcl: a leading 0, at least 5 digits.
            const o = try std.fmt.allocPrint(a, "0{o}", .{st.mode & 0o7777});
            if (o.len >= 5) break :blk .{ .str = o };
            break :blk .{ .str = try std.mem.concat(a, u8, &.{ "00000"[0 .. 5 - o.len], o }) };
        },
    };
}

fn set(it: *Interp, name: []const u8, k: usize, v: []const u8, st: fsroot.Info) Error!void {
    const a = it.alloc();
    switch (k) {
        0, 1 => {
            const db = if (k == 0) "/etc/group" else "/etc/passwd";
            const id = std.fmt.parseInt(u32, v, 10) catch (try idOf(it, db, v)) orelse {
                if (k == 0) return it.failCode("TCL OPERATION SETGRP NO_GROUP", "could not set group for file \"{s}\": group \"{s}\" does not exist", .{ name, v });
                return it.failCode("TCL OPERATION SETOWN NO_USER", "could not set owner for file \"{s}\": user \"{s}\" does not exist", .{ name, v });
            };
            const what = try std.fmt.allocPrint(a, "could not set {s} for file \"{s}\": ", .{ if (k == 0) "group" else "owner", name });
            const p = try parent(it, name, what);
            defer sys.close(p.fd);
            const none: u32 = std.math.maxInt(u32);
            const rc = if (k == 0) os.fchownat(p.fd, p.base, none, id, noFollow(it)) else os.fchownat(p.fd, p.base, id, none, noFollow(it));
            if (errnoOf(rc)) |e| return fsroot.posixError(it, e, what);
        },
        else => {
            const mode = permissions(v, st.mode & 0o7777) orelse return it.failCode("TCL VALUE PERMISSION", "unknown permission string format \"{s}\"", .{v});
            const what = try std.fmt.allocPrint(a, "could not set permissions for file \"{s}\": ", .{name});
            const p = try parent(it, name, what);
            defer sys.close(p.fd);
            if (try chmodAt(it, p, name, mode)) |e| return fsroot.posixError(it, e, what);
        },
    }
}

/// The mode of a permission string of Tcl: an octal number, nine
/// characters such as `rwxr-x---`, or symbolic changes such as
/// `u+x,go-w` to the mode `old`. Null for another form.
pub fn permissions(s: []const u8, old: u32) ?u32 {
    if (s.len > 0 and std.mem.indexOfNone(u8, s, "01234567") == null) {
        return std.fmt.parseInt(u32, s, 8) catch null;
    }
    if (s.len == 9 and std.mem.indexOfNone(u8, s, "rwx-") == null) {
        var mode: u32 = 0;
        for (s, 0..) |c, k| {
            const want = "rwxrwxrwx"[k];
            if (c == want) {
                mode |= @as(u32, 1) << @intCast(8 - k);
            } else if (c != '-') return null;
        }
        return mode;
    }
    var mode = old;
    var parts = std.mem.splitScalar(u8, s, ',');
    while (parts.next()) |part| {
        var i: usize = 0;
        var who: u32 = 0;
        while (i < part.len and std.mem.indexOfScalar(u8, "ugoa", part[i]) != null) : (i += 1) {
            who |= switch (part[i]) {
                'u' => 0o4700,
                'g' => 0o2070,
                'o' => 0o1007,
                else => 0o7777,
            };
        }
        if (who == 0) who = 0o7777;
        if (i >= part.len or std.mem.indexOfScalar(u8, "+-=", part[i]) == null) return null;
        const op = part[i];
        i += 1;
        var bits: u32 = 0;
        while (i < part.len) : (i += 1) {
            bits |= switch (part[i]) {
                'r' => 0o444,
                'w' => 0o222,
                'x' => 0o111,
                's' => 0o6000,
                't' => 0o1000,
                else => return null,
            };
        }
        bits &= who;
        switch (op) {
            '+' => mode |= bits,
            '-' => mode &= ~bits,
            else => mode = (mode & ~(who & 0o0777)) | bits,
        }
    }
    return mode;
}

/// The name of the ID `id` in `/etc/passwd` or `/etc/group`, or the
/// number when no line has it.
fn nameOf(it: *Interp, db: []const u8, id: u32) Error![]const u8 {
    var buf: [16]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable;
    if (it.fs.host) if (try field(it, db, 2, key, 0)) |n| return n;
    return it.alloc().dupe(u8, key);
}

/// The ID of `name` in `/etc/passwd` or `/etc/group`, or null.
fn idOf(it: *Interp, db: []const u8, name: []const u8) Error!?u32 {
    if (!it.fs.host) return null;
    const v = (try field(it, db, 0, name, 2)) orelse return null;
    return std.fmt.parseInt(u32, v, 10) catch null;
}

/// Field `want` of the first line of the file `db` whose field `at` is
/// `key`, with `:` between the fields.
fn field(it: *Interp, db: []const u8, at: usize, key: []const u8, want: usize) Error!?[]const u8 {
    const rel = (try fsroot.normal(it, db)) orelse return null;
    const fd = switch (try fsroot.openRel(it, rel, .{}, 0)) {
        .fd => |x| x,
        .err => return null,
    };
    defer sys.close(fd);
    var text: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (text.items.len < 1 << 22) {
        const n = switch (sys.readFile(fd, &buf)) {
            .n => |x| x,
            .err => return null,
        };
        if (n == 0) break;
        try text.appendSlice(it.alloc(), buf[0..n]);
    }
    var lines = std.mem.splitScalar(u8, text.items, '\n');
    while (lines.next()) |line| {
        var fields: [7][]const u8 = @splat("");
        var it_f = std.mem.splitScalar(u8, line, ':');
        var k: usize = 0;
        while (it_f.next()) |f| : (k += 1) {
            if (k < fields.len) fields[k] = f;
        }
        if (k <= @max(at, want) or !eql(fields[at], key)) continue;
        return try it.alloc().dupe(u8, fields[want]);
    }
    return null;
}

test "permissions reads the three forms of Tcl" {
    const t = std.testing;
    try t.expectEqual(@as(?u32, 0o600), permissions("0600", 0o644));
    try t.expectEqual(@as(?u32, 0o640), permissions("rw-r-----", 0o644));
    try t.expectEqual(@as(?u32, 0o744), permissions("u+x", 0o644));
    try t.expectEqual(@as(?u32, 0o600), permissions("go-r", 0o644));
    try t.expectEqual(@as(?u32, 0o755), permissions("a+x", 0o644));
    try t.expectEqual(@as(?u32, 0o455), permissions("u-w,go=rx", 0o644));
    try t.expectEqual(@as(?u32, null), permissions("zz", 0o644));
    try t.expectEqual(@as(?u32, null), permissions("u*x", 0o644));
}

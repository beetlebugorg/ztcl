//! The optional `file`, `glob`, `cd`, and `pwd` commands (capability
//! `file`). Each path goes through the jail of `fsroot.zig`. The commands
//! that make or read a link are errors, so a script has no way to make
//! a path that leaves the root.
//!
//! `file delete -force` and `file copy` walk a tree with a list of
//! folders on the heap, with no recursion. Each entry pays steps by the
//! rule of `cmds.chargeWork`, and the walk stops at `tree_depth_limit`
//! levels. `file copy` compares the device and inode of each folder of
//! the target path with the source, so a copy into the source fails.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const fsroot = @import("fsroot.zig");
const sys = @import("sys.zig");
const cmds = @import("cmds.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn splitPath(it: *Interp, p: []const u8) Error![]Value {
    const a = it.alloc();
    var out: std.ArrayList(Value) = .empty;
    if (p.len > 0 and p[0] == '/') try out.append(a, .{ .str = "/" });
    var iter = std.mem.tokenizeScalar(u8, p, '/');
    while (iter.next()) |w| try out.append(a, .{ .str = w });
    return out.items;
}

fn joinPath(it: *Interp, parts: []const Value) Error![]const u8 {
    const a = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    for (parts) |v| {
        const s = try it.str(v);
        if (s.len == 0) continue;
        if (s[0] == '/') out.clearRetainingCapacity();
        for (try splitPath(it, s)) |w| {
            const t = try it.str(w);
            if (eql(t, "/")) {
                try out.append(a, '/');
                continue;
            }
            if (out.items.len > 0 and out.items[out.items.len - 1] != '/') try out.append(a, '/');
            try out.appendSlice(a, t);
        }
    }
    return out.items;
}

fn dirname(p: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, p, "/");
    if (t.len == 0) return if (p.len > 0) "/" else ".";
    const k = std.mem.lastIndexOfScalar(u8, t, '/') orelse return ".";
    const d = std.mem.trimEnd(u8, t[0..k], "/");
    return if (d.len == 0) "/" else d;
}

fn tailOf(p: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, p, "/");
    if (t.len == 0) return "";
    const k = std.mem.lastIndexOfScalar(u8, t, '/') orelse return t;
    return t[k + 1 ..];
}

fn extOf(p: []const u8) []const u8 {
    const t = tailOf(p);
    const k = std.mem.lastIndexOfScalar(u8, t, '.') orelse return "";
    if (k == 0) return "";
    return t[k..];
}

fn statInfo(it: *Interp, p: []const u8) Error!?fsroot.Info {
    const rel = (try fsroot.normal(it, p)) orelse return null;
    return switch (try fsroot.stat(it, rel)) {
        .ok => |x| x,
        .err => null,
    };
}

fn needInfo(it: *Interp, p: []const u8, verb: []const u8) Error!fsroot.Info {
    const rel = try fsroot.need(it, p);
    return switch (try fsroot.stat(it, rel)) {
        .ok => |x| x,
        .err => |e| fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "could not {s} \"{s}\": ", .{ verb, p })),
    };
}

fn typeName(mode: u32) []const u8 {
    return switch (mode & 0o170000) {
        0o100000 => "file",
        0o040000 => "directory",
        0o120000 => "link",
        0o020000 => "characterSpecial",
        0o060000 => "blockSpecial",
        0o010000 => "fifo",
        0o140000 => "socket",
        else => "unknown",
    };
}

/// The most folder levels below the path that `file delete -force` and
/// `file copy` walk. A deeper tree gives an error. The tests lower it.
pub var tree_depth_limit: usize = 2048;

/// One folder of a tree walk: its path, its names, and the next name.
const Level = struct {
    rel: []const u8,
    to: []const u8 = "",
    names: []const []const u8,
    next: usize = 0,
};

fn tooDeep(it: *Interp, verb: []const u8, shown: []const u8) Error {
    return it.failCode("ZTCL TREE DEPTH", "error {s} \"{s}\": the tree is deeper than {d} levels", .{ verb, shown, tree_depth_limit });
}

/// Uses the steps of one entry of a tree walk: the units of one entry
/// and one unit for each byte of its path. Each entry is also a check
/// of the memory limit.
fn chargeEntry(it: *Interp, meter: *cmds.Meter, path_len: usize) Error!void {
    try meter.add(it, cmds.entry_units + path_len);
    try it.checkMem();
}

fn removeOne(it: *Interp, rel: []const u8, dir: bool, shown: []const u8) Error!void {
    const p = switch (try fsroot.parentOf(it, rel)) {
        .ok => |x| x,
        .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "error deleting \"{s}\": ", .{shown})),
    };
    defer sys.close(p.fd);
    if (fsroot.removeAt(p, dir)) |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "error deleting \"{s}\": ", .{shown}));
}

fn listOrFail(it: *Interp, rel: []const u8, what: []const u8) Error![]const []const u8 {
    return switch (try fsroot.listDir(it, rel)) {
        .ok => |x| x,
        .err => |e| fsroot.posixError(it, e, what),
    };
}

/// Deletes a file or a tree. The walk keeps its folders in a list on the
/// heap, so a deep tree uses no native stack, and the memory limit
/// counts the list.
fn deleteTree(it: *Interp, rel: []const u8, force: bool, shown: []const u8) Error!void {
    const a = it.alloc();
    const what = try std.fmt.allocPrint(a, "error deleting \"{s}\": ", .{shown});
    const st = switch (try fsroot.stat(it, rel)) {
        .ok => |x| x,
        .err => |e| {
            if (e == .NOENT) return;
            return fsroot.posixError(it, e, what);
        },
    };
    if (rel.len == 0) return it.failCode("POSIX EACCES {permission denied}", "error deleting \"{s}\": permission denied", .{shown});
    if (!fsroot.isDir(st.mode)) return removeOne(it, rel, false, shown);
    var meter: cmds.Meter = .{};
    try chargeEntry(it, &meter, rel.len);
    const names = try listOrFail(it, rel, what);
    if (names.len > 0 and !force) {
        return it.failCode("POSIX EEXIST {file already exists}", "error deleting \"{s}\": directory not empty", .{shown});
    }
    var stack: std.ArrayList(Level) = .empty;
    try stack.append(a, .{ .rel = rel, .names = names });
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.next == top.names.len) {
            try removeOne(it, top.rel, true, shown);
            stack.items.len -= 1;
            continue;
        }
        const child = try std.fmt.allocPrint(a, "{s}/{s}", .{ top.rel, top.names[top.next] });
        top.next += 1;
        try chargeEntry(it, &meter, child.len);
        const cst = switch (try fsroot.stat(it, child)) {
            .ok => |x| x,
            .err => |e| {
                if (e == .NOENT) continue;
                return fsroot.posixError(it, e, what);
            },
        };
        if (!fsroot.isDir(cst.mode)) {
            try removeOne(it, child, false, shown);
            continue;
        }
        if (stack.items.len >= tree_depth_limit) return tooDeep(it, "deleting", shown);
        try stack.append(a, .{ .rel = child, .names = try listOrFail(it, child, what) });
    }
}

fn mkdirAll(it: *Interp, rel: []const u8, shown: []const u8) Error!void {
    var at: usize = 0;
    while (at <= rel.len) {
        const stop = std.mem.indexOfScalarPos(u8, rel, at, '/') orelse rel.len;
        const part = rel[0..stop];
        at = stop + 1;
        if (part.len == 0) continue;
        switch (try fsroot.stat(it, part)) {
            .ok => |st| {
                if (!fsroot.isDir(st.mode)) return it.failCode("POSIX EEXIST {file already exists}", "can't create directory \"{s}\": file already exists", .{shown});
                continue;
            },
            .err => {},
        }
        const p = switch (try fsroot.parentOf(it, part)) {
            .ok => |x| x,
            .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "can't create directory \"{s}\": ", .{shown})),
        };
        defer sys.close(p.fd);
        if (fsroot.mkdirAt(p)) |e| {
            if (e != .EXIST) return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "can't create directory \"{s}\": ", .{shown}));
        }
    }
}

fn copyFile(it: *Interp, from: []const u8, to: []const u8, shown: []const u8) Error!void {
    const what = try std.fmt.allocPrint(it.alloc(), "error copying \"{s}\": ", .{shown});
    const src = switch (try fsroot.openRel(it, from, .{}, 0)) {
        .fd => |x| x,
        .err => |e| return fsroot.posixError(it, e, what),
    };
    defer sys.close(src);
    const dst = switch (try fsroot.openRel(it, to, .{ .access = .write, .create = true, .truncate = true }, 0o666)) {
        .fd => |x| x,
        .err => |e| return fsroot.posixError(it, e, what),
    };
    defer sys.close(dst);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = switch (sys.readFile(src, &buf)) {
            .n => |x| x,
            .err => |e| return fsroot.posixError(it, e, what),
        };
        if (n == 0) return;
        var at: usize = 0;
        while (at < n) {
            switch (sys.writeFile(dst, buf[at..n])) {
                .n => |w| at += w,
                .err => |e| return fsroot.posixError(it, e, what),
            }
        }
    }
}

fn mkdirOne(it: *Interp, rel: []const u8, shown: []const u8) Error!void {
    const p = switch (try fsroot.parentOf(it, rel)) {
        .ok => |x| x,
        .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "can't create directory \"{s}\": ", .{shown})),
    };
    defer sys.close(p.fd);
    const e = fsroot.mkdirAt(p) orelse return;
    if (e == .EXIST) {
        switch (try fsroot.stat(it, rel)) {
            .ok => |st| if (fsroot.isDir(st.mode)) return,
            .err => {},
        }
    }
    return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "can't create directory \"{s}\": ", .{shown}));
}

/// True when the folder `to` would be the folder `src` or a folder below
/// it. The check compares the device and inode of `src` with each
/// folder of the path `to`, so a second name of the same folder also
/// counts.
fn insideSource(it: *Interp, src: fsroot.Info, to: []const u8) Error!bool {
    var k: usize = 0;
    while (k <= to.len) : (k += 1) {
        if (k < to.len and to[k] != '/') continue;
        try cmds.chargeEntries(it, 1);
        switch (try fsroot.stat(it, to[0..k])) {
            .ok => |st| if (st.same(src)) return true,
            .err => return false,
        }
    }
    return false;
}

/// Copies a file or a tree. The walk keeps its folders in a list on the
/// heap, as `deleteTree` does.
fn copyTree(it: *Interp, from: []const u8, to: []const u8, shown: []const u8, target: []const u8) Error!void {
    const a = it.alloc();
    const what = try std.fmt.allocPrint(a, "error copying \"{s}\": ", .{shown});
    const st = switch (try fsroot.stat(it, from)) {
        .ok => |x| x,
        .err => |e| return fsroot.posixError(it, e, what),
    };
    if (!fsroot.isDir(st.mode)) {
        if (!fsroot.isFile(st.mode)) return it.failCode("POSIX EACCES {permission denied}", "error copying \"{s}\": permission denied", .{shown});
        return copyFile(it, from, to, shown);
    }
    // A copy into the source or below it does not end.
    if (try insideSource(it, st, to)) return it.failCode("POSIX EINVAL {invalid argument}", "error copying \"{s}\" to \"{s}\": trying to copy a directory into itself", .{ shown, target });
    try mkdirAll(it, to, shown);
    var meter: cmds.Meter = .{};
    try chargeEntry(it, &meter, from.len + to.len);
    var stack: std.ArrayList(Level) = .empty;
    try stack.append(a, .{ .rel = from, .to = to, .names = try listOrFail(it, from, "error copying: ") });
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.next == top.names.len) {
            stack.items.len -= 1;
            continue;
        }
        const name = top.names[top.next];
        top.next += 1;
        const cfrom = try std.fmt.allocPrint(a, "{s}/{s}", .{ top.rel, name });
        const cto = try std.fmt.allocPrint(a, "{s}/{s}", .{ top.to, name });
        try chargeEntry(it, &meter, cfrom.len + cto.len);
        const cst = switch (try fsroot.stat(it, cfrom)) {
            .ok => |x| x,
            .err => |e| return fsroot.posixError(it, e, what),
        };
        if (fsroot.isDir(cst.mode)) {
            if (stack.items.len >= tree_depth_limit) return tooDeep(it, "copying", shown);
            try mkdirOne(it, cto, shown);
            try stack.append(a, .{ .rel = cfrom, .to = cto, .names = try listOrFail(it, cfrom, "error copying: ") });
            continue;
        }
        if (!fsroot.isFile(cst.mode)) return it.failCode("POSIX EACCES {permission denied}", "error copying \"{s}\": permission denied", .{shown});
        try copyFile(it, cfrom, cto, shown);
    }
}

fn renameOrCopy(it: *Interp, args: []const Value, is_rename: bool) Error!Value {
    var rest = args;
    var force = false;
    while (rest.len > 0) {
        const o = try it.str(rest[0]);
        if (eql(o, "-force")) {
            force = true;
            rest = rest[1..];
        } else if (eql(o, "--")) {
            rest = rest[1..];
            break;
        } else if (o.len > 0 and o[0] == '-') {
            return it.fail("bad option \"{s}\": must be -force or --", .{o});
        } else break;
    }
    const verb = if (is_rename) "renaming" else "copying";
    if (rest.len < 2) return it.fail("wrong # args: should be \"file {s} ?-option value ...? source ?source ...? target\"", .{if (is_rename) "rename" else "copy"});
    const a = it.alloc();
    const target = try it.str(rest[rest.len - 1]);
    const trel = try fsroot.need(it, target);
    const tinfo: ?fsroot.Info = switch (try fsroot.stat(it, trel)) {
        .ok => |x| x,
        .err => null,
    };
    const into_dir = tinfo != null and fsroot.isDir(tinfo.?.mode);
    if (rest.len > 2 and !into_dir) return it.failCode("POSIX ENOTDIR {not a directory}", "error {s}: target \"{s}\" is not a directory", .{ verb, target });
    for (rest[0 .. rest.len - 1]) |v| {
        const src = try it.str(v);
        const srel = try fsroot.need(it, src);
        switch (try fsroot.stat(it, srel)) {
            .ok => {},
            .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(a, "error {s} \"{s}\": ", .{ verb, src })),
        }
        var drel = trel;
        if (into_dir) drel = if (trel.len == 0) tailOf(srel) else try std.fmt.allocPrint(a, "{s}/{s}", .{ trel, tailOf(srel) });
        const exists = switch (try fsroot.stat(it, drel)) {
            .ok => true,
            .err => false,
        };
        if (exists and !force) return it.failCode("POSIX EEXIST {file already exists}", "error {s} \"{s}\" to \"{s}\": target file exists", .{ verb, src, target });
        if (!is_rename) {
            try copyTree(it, srel, drel, src, target);
            continue;
        }
        const p = switch (try fsroot.parentOf(it, srel)) {
            .ok => |x| x,
            .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(a, "error renaming \"{s}\": ", .{src})),
        };
        defer sys.close(p.fd);
        const q = switch (try fsroot.parentOf(it, drel)) {
            .ok => |x| x,
            .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(a, "error renaming \"{s}\" to \"{s}\": ", .{ src, target })),
        };
        defer sys.close(q.fd);
        if (fsroot.renameAt(p, q)) |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(a, "error renaming \"{s}\" to \"{s}\": ", .{ src, target }));
    }
    return Value.empty;
}

fn statList(it: *Interp, st: fsroot.Info) Error!Value {
    const a = it.alloc();
    var out: std.ArrayList(Value) = .empty;
    const put = struct {
        fn f(x: std.mem.Allocator, o: *std.ArrayList(Value), k: []const u8, v: Value) !void {
            try o.append(x, .{ .str = k });
            try o.append(x, v);
        }
    }.f;
    try put(a, &out, "atime", .{ .int = st.atime });
    try put(a, &out, "ctime", .{ .int = st.ctime });
    try put(a, &out, "dev", .{ .int = 0 });
    try put(a, &out, "gid", .{ .int = st.gid });
    try put(a, &out, "ino", .{ .int = @intCast(st.ino) });
    try put(a, &out, "mode", .{ .int = st.mode });
    try put(a, &out, "mtime", .{ .int = st.mtime });
    try put(a, &out, "nlink", .{ .int = st.nlink });
    try put(a, &out, "size", .{ .int = @intCast(st.size) });
    try put(a, &out, "type", .{ .str = typeName(st.mode) });
    try put(a, &out, "uid", .{ .int = st.uid });
    return value.wrapList(a, out.items);
}

const file_subs = [_][]const u8{ "atime", "attributes", "channels", "copy", "delete", "dirname", "executable", "exists", "extension", "isdirectory", "isfile", "join", "link", "lstat", "mkdir", "mtime", "nativename", "normalize", "owned", "pathtype", "readable", "readlink", "rename", "rootname", "separator", "size", "split", "stat", "system", "tail", "tempfile", "type", "volumes", "writable" };

pub fn cmdFile(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("file subcommand ?arg ...?");
    const a = it.alloc();
    const word = try it.str(argv[1]);
    var sub: ?[]const u8 = null;
    var hits: usize = 0;
    for (file_subs) |n| {
        if (eql(n, word)) {
            sub = n;
            hits = 1;
            break;
        }
        if (word.len > 0 and std.mem.startsWith(u8, n, word)) {
            sub = n;
            hits += 1;
        }
    }
    if (hits != 1) {
        var m: std.ArrayList(u8) = .empty;
        try m.print(a, "unknown or ambiguous subcommand \"{s}\": must be ", .{word});
        for (file_subs, 0..) |n, k| {
            if (k > 0) try m.appendSlice(a, ", ");
            if (k == file_subs.len - 1) try m.appendSlice(a, "or ");
            try m.appendSlice(a, n);
        }
        it.result = .{ .str = m.items };
        it.error_code = .{ .str = "TCL LOOKUP INDEX subcommand" };
        return error.TclError;
    }
    const s = sub.?;
    const args = argv[2..];
    const one = struct {
        fn f(x: *Interp, n: []const u8, ar: []const Value) Error![]const u8 {
            if (ar.len != 1) return x.failCode("TCL WRONGARGS", "wrong # args: should be \"file {s} name\"", .{n});
            return x.str(ar[0]);
        }
    }.f;
    if (eql(s, "join")) {
        if (args.len < 1) return it.wrongArgs("file join name ?name ...?");
        return .{ .str = try joinPath(it, args) };
    }
    if (eql(s, "split")) return value.wrapList(a, try splitPath(it, try one(it, s, args)));
    if (eql(s, "dirname")) return .{ .str = dirname(try one(it, s, args)) };
    if (eql(s, "tail")) return .{ .str = tailOf(try one(it, s, args)) };
    if (eql(s, "extension")) return .{ .str = extOf(try one(it, s, args)) };
    if (eql(s, "rootname")) {
        const p = try one(it, s, args);
        return .{ .str = p[0 .. p.len - extOf(p).len] };
    }
    if (eql(s, "nativename")) return .{ .str = try one(it, s, args) };
    if (eql(s, "pathtype")) {
        const p = try one(it, s, args);
        return .{ .str = if (p.len > 0 and p[0] == '/') "absolute" else "relative" };
    }
    if (eql(s, "separator")) return .{ .str = "/" };
    if (eql(s, "volumes")) return .{ .str = "/" };
    if (eql(s, "system")) return value.newList(a, &.{ .{ .str = "native" }, .{ .str = "root" } });
    if (eql(s, "channels")) {
        var out: std.ArrayList(Value) = .empty;
        for (it.chans.table.keys()) |k| try out.append(a, .{ .str = k });
        return value.wrapList(a, out.items);
    }
    if (eql(s, "normalize")) {
        const rel = try fsroot.need(it, try one(it, s, args));
        return .{ .str = try std.fmt.allocPrint(a, "/{s}", .{rel}) };
    }
    if (eql(s, "link") or eql(s, "readlink")) {
        return it.failCode("POSIX EACCES {permission denied}", "could not {s}: links are not available in the root folder", .{s});
    }
    if (eql(s, "exists") or eql(s, "isfile") or eql(s, "isdirectory") or eql(s, "readable") or eql(s, "writable") or eql(s, "executable") or eql(s, "owned")) {
        const st = (try statInfo(it, try one(it, s, args))) orelse return .{ .int = 0 };
        const b = if (eql(s, "isfile")) fsroot.isFile(st.mode) else if (eql(s, "isdirectory")) fsroot.isDir(st.mode) else if (eql(s, "readable")) st.mode & 0o444 != 0 else if (eql(s, "writable")) st.mode & 0o222 != 0 else if (eql(s, "executable")) st.mode & 0o111 != 0 else true;
        return .{ .int = @intFromBool(b) };
    }
    if (eql(s, "size")) return .{ .int = @intCast((try needInfo(it, try one(it, s, args), "read")).size) };
    if (eql(s, "type")) return .{ .str = typeName((try needInfo(it, try one(it, s, args), "read")).mode) };
    if (eql(s, "mtime") or eql(s, "atime")) {
        if (args.len != 1) return it.fail("file {s} with a new time is not available", .{s});
        const st = try needInfo(it, try one(it, s, args), "read");
        return .{ .int = if (eql(s, "mtime")) st.mtime else st.atime };
    }
    if (eql(s, "stat") or eql(s, "lstat")) {
        if (args.len != 2) return it.fail("wrong # args: should be \"file {s} name varName\"", .{s});
        const st = try needInfo(it, try it.str(args[0]), "read");
        const name = try it.str(args[1]);
        const l = try it.list(try statList(it, st));
        var k: usize = 0;
        while (k < l.len) : (k += 2) try it.setVar(try std.fmt.allocPrint(a, "{s}({s})", .{ name, try it.str(l[k]) }), l[k + 1]);
        return Value.empty;
    }
    if (eql(s, "mkdir")) {
        for (args) |v| {
            const p = try it.str(v);
            try mkdirAll(it, try fsroot.need(it, p), p);
        }
        return Value.empty;
    }
    if (eql(s, "delete")) {
        var rest = args;
        var force = false;
        while (rest.len > 0) {
            const o = try it.str(rest[0]);
            if (eql(o, "-force")) {
                force = true;
                rest = rest[1..];
            } else if (eql(o, "--")) {
                rest = rest[1..];
                break;
            } else if (o.len > 0 and o[0] == '-') {
                return it.fail("bad option \"{s}\": must be -force or --", .{o});
            } else break;
        }
        for (rest) |v| {
            const p = try it.str(v);
            try deleteTree(it, try fsroot.need(it, p), force, p);
        }
        return Value.empty;
    }
    if (eql(s, "rename")) return renameOrCopy(it, args, true);
    if (eql(s, "copy")) return renameOrCopy(it, args, false);
    if (eql(s, "tempfile")) {
        var n: u32 = 0;
        while (n < 1000) : (n += 1) {
            const name = try std.fmt.allocPrint(a, "tcl_tmp{d}", .{it.temp_next});
            it.temp_next += 1;
            const rel = try fsroot.need(it, name);
            switch (try fsroot.openRel(it, rel, .{ .access = .read_write, .create = true, .exclusive = true }, 0o600)) {
                .fd => |fd| {
                    sys.close(fd);
                    const argv2 = [_]Value{ .{ .str = "open" }, .{ .str = name }, .{ .str = "r+" } };
                    const ch = try it.callWords(&argv2);
                    if (args.len >= 1) try it.setVar(try it.str(args[0]), .{ .str = try std.fmt.allocPrint(a, "/{s}", .{rel}) });
                    return ch;
                },
                .err => |e| if (e != .EXIST) return fsroot.posixError(it, e, "couldn't create temporary file: "),
            }
        }
        return it.fail("couldn't create temporary file", .{});
    }
    return it.fail("file {s} is not available", .{s});
}

fn cmdPwd(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("pwd");
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "/{s}", .{it.fs.cwd}) };
}

fn cmdCd(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len > 2) return it.wrongArgs("cd ?dirName?");
    const p = if (argv.len == 2) try it.str(argv[1]) else "/";
    const rel = (try fsroot.normal(it, p)) orelse return it.failCode("POSIX EACCES {permission denied}", "couldn't change working directory to \"{s}\": permission denied", .{p});
    const st = switch (try fsroot.stat(it, rel)) {
        .ok => |x| x,
        .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "couldn't change working directory to \"{s}\": ", .{p})),
    };
    if (!fsroot.isDir(st.mode)) return fsroot.posixError(it, .NOTDIR, try std.fmt.allocPrint(it.alloc(), "couldn't change working directory to \"{s}\": ", .{p}));
    it.fs.cwd = rel;
    return Value.empty;
}

/// Expands `{a,b}` in a glob pattern.
fn braces(it: *Interp, pat: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    const a = it.alloc();
    const open = std.mem.indexOfScalar(u8, pat, '{') orelse return out.append(a, pat);
    var depth: usize = 0;
    var close: ?usize = null;
    var k = open;
    while (k < pat.len) : (k += 1) {
        if (pat[k] == '{') depth += 1;
        if (pat[k] == '}') {
            depth -= 1;
            if (depth == 0) {
                close = k;
                break;
            }
        }
    }
    const c = close orelse return it.fail("unmatched open-brace in file name", .{});
    var start = open + 1;
    depth = 0;
    k = open + 1;
    while (k <= c) : (k += 1) {
        if (pat[k] == '{') depth += 1;
        if (pat[k] == '}' and k != c) depth -= 1;
        if ((pat[k] == ',' and depth == 0) or k == c) {
            try braces(it, try std.mem.concat(a, u8, &.{ pat[0..open], pat[start..k], pat[c + 1 ..] }), out);
            start = k + 1;
        }
    }
}

fn hasMeta(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "*?[\\") != null;
}

fn globWalk(it: *Interp, base: []const u8, shown: []const u8, parts: []const []const u8, out: *std.ArrayList([]const u8)) Error!void {
    const a = it.alloc();
    if (it.step_limit == 0) return it.fail("step limit reached", .{});
    it.step_limit -= 1;
    const join = struct {
        fn f(x: std.mem.Allocator, l: []const u8, r: []const u8) ![]const u8 {
            if (l.len == 0) return x.dupe(u8, r);
            if (l[l.len - 1] == '/') return std.mem.concat(x, u8, &.{ l, r });
            return std.mem.concat(x, u8, &.{ l, "/", r });
        }
    }.f;
    if (parts.len == 0) {
        try out.append(a, shown);
        return;
    }
    const p = parts[0];
    if (!hasMeta(p)) {
        const rel = try join(a, base, p);
        const norm = (try fsroot.normal(it, try std.fmt.allocPrint(a, "/{s}", .{rel}))) orelse return;
        switch (try fsroot.stat(it, norm)) {
            .ok => try globWalk(it, norm, try join(a, shown, p), parts[1..], out),
            .err => {},
        }
        return;
    }
    const names = switch (try fsroot.listDir(it, base)) {
        .ok => |x| x,
        .err => return,
    };
    for (names) |n| {
        if (n[0] == '.' and p[0] != '.') continue;
        if (!cmds.globMatch(p, n, false)) continue;
        try globWalk(it, try join(a, base, n), try join(a, shown, n), parts[1..], out);
    }
}

fn typeOk(mode: u32, types: []const []const u8) bool {
    if (types.len == 0) return true;
    for (types) |t| {
        const hit = switch (t[0]) {
            'f' => fsroot.isFile(mode),
            'd' => fsroot.isDir(mode),
            'l' => mode & 0o170000 == 0o120000,
            'r' => mode & 0o444 != 0,
            'w' => mode & 0o222 != 0,
            'x' => mode & 0o111 != 0,
            else => false,
        };
        if (hit) return true;
    }
    return false;
}

fn cmdGlob(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const a = it.alloc();
    var i: usize = 1;
    var nocomplain = false;
    var tails = false;
    var dir: ?[]const u8 = null;
    var prefix: []const u8 = "";
    var types: std.ArrayList([]const u8) = .empty;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (o.len == 0 or o[0] != '-') break;
        if (eql(o, "--")) {
            i += 1;
            break;
        } else if (eql(o, "-nocomplain")) {
            nocomplain = true;
        } else if (eql(o, "-tails")) {
            tails = true;
        } else if (eql(o, "-join")) {
            continue;
        } else if (eql(o, "-directory") or eql(o, "-path") or eql(o, "-types")) {
            i += 1;
            if (i >= argv.len) return it.fail("missing argument to \"{s}\"", .{o});
            if (eql(o, "-directory")) dir = try it.str(argv[i]);
            if (eql(o, "-path")) prefix = try it.str(argv[i]);
            if (eql(o, "-types")) for (try it.list(argv[i])) |t| try types.append(a, try it.str(t));
        } else return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -directory, -join, -nocomplain, -path, -tails, -types, or --", .{o});
    }
    if (i >= argv.len) return it.wrongArgs("glob ?switches? name ?name ...?");
    var results: std.ArrayList([]const u8) = .empty;
    for (argv[i..]) |v| {
        var pats: std.ArrayList([]const u8) = .empty;
        try braces(it, try std.mem.concat(a, u8, &.{ prefix, try it.str(v) }), &pats);
        for (pats.items) |pat| {
            var words: std.ArrayList([]const u8) = .empty;
            var iter = std.mem.tokenizeScalar(u8, pat, '/');
            while (iter.next()) |w| try words.append(a, w);
            const absolute = dir == null and pat.len > 0 and pat[0] == '/';
            const from = if (absolute) "/" else (dir orelse ".");
            const base = (try fsroot.normal(it, from)) orelse return it.failCode("POSIX EACCES {permission denied}", "couldn't read directory \"{s}\": permission denied", .{from});
            const shown: []const u8 = if (absolute) "/" else (dir orelse "");
            try globWalk(it, base, shown, words.items, &results);
        }
    }
    var out: std.ArrayList(Value) = .empty;
    for (results.items) |r| {
        if (types.items.len > 0) {
            const st = (try statInfo(it, r)) orelse continue;
            if (!typeOk(st.mode, types.items)) continue;
        }
        var shown = r;
        if (tails) {
            if (dir) |d| {
                shown = std.mem.trimStart(u8, r[@min(d.len, r.len)..], "/");
            } else shown = tailOf(r);
        }
        try out.append(a, .{ .str = shown });
    }
    if (out.items.len == 0 and !nocomplain) {
        return it.failCode("TCL OPERATION GLOB NOMATCH", "no files matched glob pattern \"{s}\"", .{try it.str(argv[i])});
    }
    return value.wrapList(a, out.items);
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("file", cmdFile);
    try it.register("glob", cmdGlob);
    try it.register("pwd", cmdPwd);
    try it.register("cd", cmdCd);
}

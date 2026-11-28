//! The optional `ztcl::watch` command: the changes below a folder of the
//! root folder (capability `file`). The plan is `docs/dev/watch.md`.
//!
//! Linux uses inotify. `add` opens the folder through the jail of
//! `fsroot.zig`, so a symlink cannot lead out of the root, and gives
//! inotify the path `/proc/self/fd/N` of that descriptor. Each watch
//! descriptor maps to the path of the script of its folder. With
//! `-recursive`, `add` watches each folder below, and a new folder gets
//! a watch when its create event arrives.
//!
//! `changes` reads the events with no block, merges the events of one
//! path into one pair, and keeps the order of the first event of each
//! path. More than 4,096 pairs give one pair `{overflow /}`.
//!
//! Windows uses `ReadDirectoryChangesW` on a completion port
//! (`watch_windows.zig`), with the same kinds, merges, and overflow.
//!
//! macOS uses an FSEvents stream with the events of each file
//! (`watch_macos.zig`), with the same kinds, merges, and overflow.
//!
//! On the other platforms, `add` gives an error. The designs are in the
//! plan.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const fsroot = @import("fsroot.zig");
const sys = @import("sys.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

/// True on the platforms where `add` watches a folder.
pub const supported = builtin.os.tag == .linux or on_win or on_mac;
const on_win = builtin.os.tag == .windows;
const on_mac = builtin.os.tag == .macos;
const ww = @import("watch_windows.zig");
const wm = @import("watch_macos.zig");

const max_changes = 4096;

const Kind = enum { created, modified, deleted, moved, overflow };

const Change = struct { kind: Kind, path: []const u8 };

const Watcher = struct {
    id: u32,
    fd: i32,
    recursive: bool,
    /// The normal path (`fsroot.normal`) of the folder of each watch
    /// descriptor.
    dirs: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,
    changes: std.ArrayList(Change) = .empty,
    overflow: bool = false,
    /// The folder of the watch on Windows, and its read.
    win: if (on_win) ww.Win else void = undefined,
    /// The stream of the watch on macOS.
    mac: if (on_mac) *wm.Mac else void = undefined,
    base: []const u8 = "",
};

pub const State = struct {
    list: std.ArrayList(*Watcher) = .empty,
    next: u32 = 1,
};

fn find(it: *Interp, v: Value) Error!*Watcher {
    const name = try it.str(v);
    if (std.mem.startsWith(u8, name, "watch")) {
        const id = std.fmt.parseInt(u32, name[5..], 10) catch 0;
        for (it.watches.list.items) |w| if (w.id == id) return w;
    }
    return it.failCode("ZTCL WATCH HANDLE", "can not find watcher named \"{s}\"", .{name});
}

/// The normal path of the entry `name` in the folder `dir`. In the jail
/// the root is the empty path, and in host mode it is `/`.
fn child(a: std.mem.Allocator, dir: []const u8, name: []const u8) Error![]const u8 {
    if (dir.len == 0) return a.dupe(u8, name);
    if (dir[dir.len - 1] == '/') return std.fmt.allocPrint(a, "{s}{s}", .{ dir, name });
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

fn addDir(it: *Interp, w: *Watcher, rel: []const u8) Error!void {
    const linux = std.os.linux;
    const fd = switch (try fsroot.openRel(it, rel, .{ .directory = true }, 0)) {
        .fd => |x| x,
        .err => |e| return fsroot.posixError(it, e, "couldn't watch the folder: "),
    };
    defer sys.close(fd);
    var buf: [40:0]u8 = undefined;
    const proc_path = std.fmt.bufPrintSentinel(&buf, "/proc/self/fd/{d}", .{fd}, 0) catch unreachable;
    const mask: u32 = linux.IN.CREATE | linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.ATTRIB | linux.IN.ONLYDIR;
    const rc = linux.inotify_add_watch(w.fd, proc_path, mask);
    if (linux.errno(rc) != .SUCCESS) return fsroot.posixError(it, linux.errno(rc), "couldn't watch the folder: ");
    const wd: i32 = @intCast(rc);
    try w.dirs.put(it.alloc(), wd, try it.alloc().dupe(u8, rel));
    if (!w.recursive) return;
    switch (try fsroot.listDir(it, rel)) {
        .ok => |names| for (names) |n| {
            const sub = try child(it.alloc(), rel, n);
            switch (try fsroot.stat(it, sub)) {
                .ok => |st| if (fsroot.isDir(st.mode)) try addDir(it, w, sub),
                else => {},
            }
        },
        .err => {},
    }
}

fn add(it: *Interp, argv: []const Value) Error!Value {
    if (comptime !supported) return it.failCode("ZTCL WATCH UNAVAILABLE", "ztcl::watch is not available on this platform yet", .{});
    const linux = std.os.linux;
    var recursive = false;
    var i: usize = 2;
    if (i < argv.len and std.mem.eql(u8, try it.str(argv[i]), "-recursive")) {
        recursive = true;
        i += 1;
    }
    if (i + 1 != argv.len) return it.wrongArgs("ztcl::watch add ?-recursive? path");
    const rel = try fsroot.need(it, try it.str(argv[i]));
    if (comptime on_mac) {
        const w = try it.alloc().create(Watcher);
        w.* = .{ .id = it.watches.next, .fd = -1, .recursive = recursive, .base = try it.alloc().dupe(u8, rel) };
        w.mac = try wm.open(it, rel, recursive);
        w.fd = w.mac.waitHandle();
        it.watches.next += 1;
        it.watches.list.append(it.alloc(), w) catch |e| {
            wm.close(w.mac);
            return e;
        };
        return .{ .str = try std.fmt.allocPrint(it.alloc(), "watch{d}", .{w.id}) };
    }
    if (comptime on_win) {
        const w = try it.alloc().create(Watcher);
        w.* = .{ .id = it.watches.next, .fd = -1, .recursive = recursive, .base = try it.alloc().dupe(u8, rel) };
        try ww.open(it, &w.win, rel, recursive);
        it.watches.next += 1;
        try it.watches.list.append(it.alloc(), w);
        return .{ .str = try std.fmt.allocPrint(it.alloc(), "watch{d}", .{w.id}) };
    }
    const rc = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
    if (linux.errno(rc) != .SUCCESS) return fsroot.posixError(it, linux.errno(rc), "couldn't start a watch: ");
    const w = try it.alloc().create(Watcher);
    w.* = .{ .id = it.watches.next, .fd = @intCast(rc), .recursive = recursive };
    addDir(it, w, rel) catch |e| {
        sys.close(w.fd);
        return e;
    };
    it.watches.next += 1;
    try it.watches.list.append(it.alloc(), w);
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "watch{d}", .{w.id}) };
}

fn note(it: *Interp, w: *Watcher, kind: Kind, path: []const u8) Error!void {
    if (w.overflow) return;
    for (w.changes.items) |*c| if (std.mem.eql(u8, c.path, path)) {
        // A create, then a change, stays a create. A later delete wins.
        if (kind == .deleted or kind == .moved or c.kind == .deleted) c.kind = kind;
        return;
    };
    if (w.changes.items.len >= max_changes) {
        w.overflow = true;
        w.changes.clearRetainingCapacity();
        try w.changes.append(it.alloc(), .{ .kind = .overflow, .path = "/" });
        return;
    }
    try w.changes.append(it.alloc(), .{ .kind = kind, .path = path });
}

/// Reads the events that wait on the descriptor.
fn drain(it: *Interp, w: *Watcher) Error!void {
    if (comptime on_win) return drainWin(it, w);
    if (comptime on_mac) return drainMac(it, w);
    const linux = std.os.linux;
    var buf: [8192]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const rc = linux.read(w.fd, &buf, buf.len);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return;
        var off: usize = 0;
        while (off + @sizeOf(linux.inotify_event) <= rc) {
            const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
            off += @sizeOf(linux.inotify_event) + ev.len;
            if (ev.mask & linux.IN.Q_OVERFLOW != 0) {
                w.overflow = false;
                try note(it, w, .overflow, "/");
                w.overflow = true;
                continue;
            }
            const dir = w.dirs.get(ev.wd) orelse continue;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf[off - ev.len])), 0);
            if (ev.len == 0 or name.len == 0) continue;
            const rel = try child(it.alloc(), dir, name);
            const path = try fsroot.shown(it, rel);
            const m = ev.mask;
            const kind: Kind = if (m & linux.IN.CREATE != 0 or m & linux.IN.MOVED_TO != 0)
                .created
            else if (m & linux.IN.DELETE != 0)
                .deleted
            else if (m & linux.IN.MOVED_FROM != 0)
                .moved
            else
                .modified;
            try note(it, w, kind, path);
            if (w.recursive and m & linux.IN.ISDIR != 0 and kind == .created) addDir(it, w, rel) catch {};
        }
    }
}

/// The changes of the read on Windows. A change of a folder is the
/// change of its time, which each change in the folder gives, so it is
/// no event, as on Linux.
fn drainWin(it: *Interp, w: *Watcher) Error!void {
    var got: std.ArrayList(ww.Event) = .empty;
    try ww.drain(it, &w.win, &got);
    for (got.items) |e| {
        if (e.kind == .overflow) {
            w.overflow = false;
            try note(it, w, .overflow, "/");
            w.overflow = true;
            continue;
        }
        const rel = try child(it.alloc(), w.base, e.name);
        if (e.kind == .modified) switch (try fsroot.stat(it, rel)) {
            .ok => |st| if (fsroot.isDir(st.mode)) continue,
            else => {},
        };
        const kind: Kind = switch (e.kind) {
            .created => .created,
            .modified => .modified,
            .deleted => .deleted,
            .moved => .moved,
            .overflow => unreachable,
        };
        try note(it, w, kind, try fsroot.shown(it, rel));
    }
}

/// The changes of the stream on macOS.
fn drainMac(it: *Interp, w: *Watcher) Error!void {
    var got: std.ArrayList(wm.Event) = .empty;
    try wm.drain(it, w.mac, &got);
    for (got.items) |e| {
        if (e.kind == .overflow) {
            w.overflow = false;
            try note(it, w, .overflow, "/");
            w.overflow = true;
            continue;
        }
        const kind: Kind = switch (e.kind) {
            .created => .created,
            .modified => .modified,
            .deleted => .deleted,
            .moved => .moved,
            .overflow => unreachable,
        };
        try note(it, w, kind, try fsroot.shown(it, try child(it.alloc(), w.base, e.name)));
    }
}

fn changes(it: *Interp, w: *Watcher) Error!Value {
    try drain(it, w);
    var out: std.ArrayList(Value) = .empty;
    for (w.changes.items) |c| {
        var pair = [2]Value{ .{ .str = @tagName(c.kind) }, .{ .str = c.path } };
        try out.append(it.alloc(), try value.wrapList(it.alloc(), try it.alloc().dupe(Value, &pair)));
    }
    w.changes.clearRetainingCapacity();
    w.overflow = false;
    return value.wrapList(it.alloc(), out.items);
}

fn cmdWatch(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("ztcl::watch add|changes|fd|remove ?arg ...?");
    const sub = try it.str(argv[1]);
    if (std.mem.eql(u8, sub, "add")) return add(it, argv);
    // The name of the subcommand is checked before the count and the
    // handle.
    const known = std.mem.eql(u8, sub, "changes") or std.mem.eql(u8, sub, "fd") or std.mem.eql(u8, sub, "remove");
    if (!known) return it.failWord("TCL LOOKUP SUBCOMMAND", sub, "unknown subcommand \"{s}\": must be add, changes, fd, or remove", .{sub});
    if (comptime !supported) return it.failCode("ZTCL WATCH HANDLE", "can not find watcher named \"{s}\"", .{if (argv.len > 2) try it.str(argv[2]) else ""});
    if (argv.len != 3) return it.wrongArgs("ztcl::watch changes|fd|remove watcher");
    const w = try find(it, argv[2]);
    if (std.mem.eql(u8, sub, "changes")) return changes(it, w);
    if (std.mem.eql(u8, sub, "fd")) return .{ .int = if (comptime on_win) @intCast(w.win.waitHandle()) else w.fd };
    if (std.mem.eql(u8, sub, "remove")) {
        closeOne(it, w);
        for (it.watches.list.items, 0..) |x, k| if (x == w) {
            _ = it.watches.list.orderedRemove(k);
            break;
        };
        return .{ .str = "" };
    }
    unreachable;
}

fn closeOne(it: *Interp, w: *Watcher) void {
    if (comptime on_win) {
        ww.close(it, &w.win);
    } else if (comptime on_mac) {
        wm.close(w.mac);
    } else sys.close(w.fd);
}

/// Closes each watcher when the interpreter ends or resets.
pub fn closeAll(it: *Interp) void {
    if (comptime !supported) return;
    for (it.watches.list.items) |w| closeOne(it, w);
    it.watches = .{};
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("ztcl::watch", cmdWatch);
}

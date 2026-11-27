//! The macOS form of `ztcl::watch` (`watch.zig`): one FSEvents stream
//! for each watcher, with the events of each file.
//!
//! `open` opens the folder through the jail of `fsroot.zig`, so the
//! checks of the root and of symlinks apply, and takes the real path of
//! that descriptor (`F_GETPATH`). The stream watches that path, and a
//! path of an event maps back to the path of the script by its part
//! below the real path. A stream watches each folder below, so a new
//! folder needs no watch of its own. With no `-recursive`, an event
//! below a subfolder is dropped.
//!
//! The stream delivers on a dispatch queue of its own. The callback
//! keeps the events in a list under a lock and writes a byte to a pipe,
//! whose read end is the `fd` of the watcher. `drain` asks the stream to
//! deliver the events that wait (`FSEventStreamFlushSync`), so a change
//! that a script made before `changes` is in the list, and then takes
//! the list.
//!
//! FSEvents merges the flags of the events of one path, so the kind
//! comes from the flags and from the file: a removed or renamed path
//! that is gone is `deleted` or `moved`, a renamed path that exists is
//! `created`, a created path that the watcher has not seen is `created`,
//! and the rest is `modified`. A change of a folder alone is no event,
//! as on Linux. A dropped event (`MustScanSubDirs`, `UserDropped`,
//! `KernelDropped`) is `overflow`.
//!
//! CoreServices and CoreFoundation load with `dlopen` on the first
//! `add`, so a program with no watch does not link them.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const fsroot = @import("fsroot.zig");
const Interp = interp.Interp;
const Error = interp.Error;
const c = std.c;
const Lock = @import("thread.zig").Lock;

pub const Kind = enum { created, modified, deleted, moved, overflow };

/// A change: its kind and the path below the folder of the watch, with
/// `/` between the names.
pub const Event = struct { kind: Kind, name: []u8 };

const Callback = *const fn (stream: ?*anyopaque, info: ?*anyopaque, n: usize, paths: *anyopaque, flags: [*]const u32, ids: [*]const u64) callconv(.c) void;
const Context = extern struct {
    version: isize = 0,
    info: ?*anyopaque,
    retain: ?*anyopaque = null,
    release: ?*anyopaque = null,
    copy_description: ?*anyopaque = null,
};

const Api = struct {
    create_string: *const fn (alloc: ?*anyopaque, s: [*:0]const u8, enc: u32) callconv(.c) ?*anyopaque,
    create_array: *const fn (alloc: ?*anyopaque, values: [*]const ?*anyopaque, n: isize, cb: ?*const anyopaque) callconv(.c) ?*anyopaque,
    release: *const fn (obj: *anyopaque) callconv(.c) void,
    array_callbacks: *const anyopaque,
    stream_create: *const fn (alloc: ?*anyopaque, cb: Callback, ctx: *const Context, paths: *anyopaque, since: u64, latency: f64, flags: u32) callconv(.c) ?*anyopaque,
    set_queue: *const fn (stream: *anyopaque, q: ?*anyopaque) callconv(.c) void,
    start: *const fn (stream: *anyopaque) callconv(.c) u8,
    flush_sync: *const fn (stream: *anyopaque) callconv(.c) void,
    stop: *const fn (stream: *anyopaque) callconv(.c) void,
    invalidate: *const fn (stream: *anyopaque) callconv(.c) void,
    stream_release: *const fn (stream: *anyopaque) callconv(.c) void,
};

extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_release(obj: *anyopaque) void;

var api: ?Api = null;
var api_lock: Lock = .{};

fn load() ?Api {
    api_lock.lock();
    defer api_lock.unlock();
    if (api) |x| return x;
    const cf = c.dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", .{ .LAZY = true }) orelse return null;
    const cs = c.dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", .{ .LAZY = true }) orelse return null;
    const x: Api = .{
        .create_string = @ptrCast(@alignCast(c.dlsym(cf, "CFStringCreateWithCString") orelse return null)),
        .create_array = @ptrCast(@alignCast(c.dlsym(cf, "CFArrayCreate") orelse return null)),
        .release = @ptrCast(@alignCast(c.dlsym(cf, "CFRelease") orelse return null)),
        .array_callbacks = @ptrCast(@alignCast(c.dlsym(cf, "kCFTypeArrayCallBacks") orelse return null)),
        .stream_create = @ptrCast(@alignCast(c.dlsym(cs, "FSEventStreamCreate") orelse return null)),
        .set_queue = @ptrCast(@alignCast(c.dlsym(cs, "FSEventStreamSetDispatchQueue") orelse return null)),
        .start = @ptrCast(@alignCast(c.dlsym(cs, "FSEventStreamStart") orelse return null)),
        .flush_sync = @ptrCast(@alignCast(c.dlsym(cs, "FSEventStreamFlushSync") orelse return null)),
        .stop = @ptrCast(@alignCast(c.dlsym(cs, "FSEventStreamStop") orelse return null)),
        .invalidate = @ptrCast(@alignCast(c.dlsym(cs, "FSEventStreamInvalidate") orelse return null)),
        .stream_release = @ptrCast(@alignCast(c.dlsym(cs, "FSEventStreamRelease") orelse return null)),
    };
    api = x;
    return x;
}

const utf8: u32 = 0x08000100;
const since_now: u64 = 0xFFFFFFFFFFFFFFFF;
const flag_no_defer: u32 = 0x2;
const flag_file_events: u32 = 0x10;

const ev_must_scan: u32 = 0x1;
const ev_user_dropped: u32 = 0x2;
const ev_kernel_dropped: u32 = 0x4;
const ev_created: u32 = 0x100;
const ev_removed: u32 = 0x200;
const ev_renamed: u32 = 0x800;
const ev_is_dir: u32 = 0x20000;

/// An event as the stream gave it, in the memory of the C allocator.
const Raw = struct { path: []u8, flags: u32 };

/// The state of a watcher. It lives in the C heap, since the callback
/// runs on another thread and can outlive no `close`.
pub const Mac = struct {
    stream: *anyopaque,
    queue: *anyopaque,
    /// The real path of the folder, with no `/` at the end.
    real: []u8,
    recursive: bool,
    pipe: [2]i32,
    lock: Lock = .{},
    raw: std.ArrayList(Raw) = .empty,
    /// The paths that the watcher gave as `created`.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// The time of `open`, in nanoseconds of the real clock. A path born
    /// before it was there before the watch.
    start: i128 = 0,

    pub fn waitHandle(m: *const Mac) i32 {
        return m.pipe[0];
    }
};

fn callback(_: ?*anyopaque, info: ?*anyopaque, n: usize, paths: *anyopaque, flags: [*]const u32, _: [*]const u64) callconv(.c) void {
    const m: *Mac = @ptrCast(@alignCast(info.?));
    const list: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths));
    const a = std.heap.c_allocator;
    m.lock.lock();
    defer m.lock.unlock();
    for (0..n) |i| {
        const p = a.dupe(u8, std.mem.sliceTo(list[i], 0)) catch continue;
        m.raw.append(a, .{ .path = p, .flags = flags[i] }) catch a.free(p);
    }
    const b = [1]u8{1};
    _ = c.write(m.pipe[1], &b, 1);
}

/// Starts the stream of the folder `rel` of the jail.
pub fn open(it: *Interp, rel: []const u8, recursive: bool) Error!*Mac {
    const x = load() orelse return it.failCode("ZTCL WATCH UNAVAILABLE", "ztcl::watch could not load FSEvents", .{});
    const fd = switch (try fsroot.openRel(it, rel, .{ .directory = true }, 0)) {
        .fd => |f| f,
        .err => |e| return fsroot.posixError(it, e, "couldn't watch the folder: "),
    };
    var buf: [1024]u8 = @splat(0);
    const got = c.fcntl(fd, c.F.GETPATH, &buf);
    _ = c.close(fd);
    if (got < 0) return it.fail("couldn't watch the folder: no path", .{});
    const a = std.heap.c_allocator;
    var real = std.mem.sliceTo(&buf, 0);
    while (real.len > 1 and real[real.len - 1] == '/') real = real[0 .. real.len - 1];
    const m = a.create(Mac) catch return error.OutOfMemory;
    m.* = .{ .stream = undefined, .queue = undefined, .real = a.dupe(u8, real) catch {
        a.destroy(m);
        return error.OutOfMemory;
    }, .recursive = recursive, .pipe = .{ -1, -1 } };
    errdefer {
        a.free(m.real);
        a.destroy(m);
    }
    if (c.pipe(&m.pipe) != 0) return it.fail("couldn't start a watch: no pipe", .{});
    for (m.pipe) |p| {
        _ = c.fcntl(p, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        _ = c.fcntl(p, c.F.SETFL, @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
    }
    errdefer for (m.pipe) |p| {
        _ = c.close(p);
    };
    const path_z = a.dupeSentinel(u8, m.real, 0) catch return error.OutOfMemory;
    defer a.free(path_z);
    const s = x.create_string(null, path_z, utf8) orelse return it.fail("couldn't start a watch", .{});
    defer x.release(s);
    const vals = [1]?*anyopaque{s};
    const arr = x.create_array(null, &vals, 1, x.array_callbacks) orelse return it.fail("couldn't start a watch", .{});
    defer x.release(arr);
    m.start = now();
    const ctx: Context = .{ .info = m };
    m.stream = x.stream_create(null, callback, &ctx, arr, since_now, 0.05, flag_no_defer | flag_file_events) orelse
        return it.fail("couldn't start a watch", .{});
    m.queue = dispatch_queue_create("ztcl.watch", null) orelse {
        x.stream_release(m.stream);
        return it.fail("couldn't start a watch", .{});
    };
    x.set_queue(m.stream, m.queue);
    if (x.start(m.stream) == 0) {
        x.invalidate(m.stream);
        x.stream_release(m.stream);
        dispatch_release(m.queue);
        return it.fail("couldn't start a watch", .{});
    }
    return m;
}

fn now() i128 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// The birth time of the file `path` in nanoseconds, or null when it
/// is gone. A symlink is the link itself.
fn born(path: []const u8) ?i128 {
    var buf: [1025]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var st: c.Stat = undefined;
    // AT_FDCWD and AT_SYMLINK_NOFOLLOW of macOS.
    if (c.fstatat(-2, @ptrCast(&buf), &st, 0x20) != 0) return null;
    const b = st.birthtime();
    return @as(i128, b.sec) * std.time.ns_per_s + b.nsec;
}

/// Takes the events that wait, as changes below the folder.
pub fn drain(it: *Interp, m: *Mac, out: *std.ArrayList(Event)) Error!void {
    const x = api.?;
    x.flush_sync(m.stream);
    var sink: [64]u8 = undefined;
    while (c.read(m.pipe[0], &sink, sink.len) > 0) {}
    m.lock.lock();
    var raw = m.raw;
    m.raw = .empty;
    m.lock.unlock();
    const ca = std.heap.c_allocator;
    defer {
        for (raw.items) |r| ca.free(r.path);
        raw.deinit(ca);
    }
    for (raw.items) |r| {
        if (r.flags & (ev_must_scan | ev_user_dropped | ev_kernel_dropped) != 0) {
            try out.append(it.alloc(), .{ .kind = .overflow, .name = &.{} });
            continue;
        }
        if (!std.mem.startsWith(u8, r.path, m.real)) continue;
        const rest = r.path[m.real.len..];
        if (rest.len < 2 or rest[0] != '/') continue;
        const name = rest[1..];
        if (!m.recursive and std.mem.indexOfScalar(u8, name, '/') != null) continue;
        const birth = born(r.path);
        const here = birth != null;
        // FSEvents keeps the created flag of a path for later events, and
        // gives the create of a path that came just before the watch.
        const new = here and birth.? >= m.start and !m.seen.contains(name);
        const kind: Kind = if (r.flags & ev_renamed != 0 and !here)
            .moved
        else if (r.flags & ev_removed != 0 and !here)
            .deleted
        else if (!here)
            continue
        else if (r.flags & ev_renamed != 0 and !m.seen.contains(name))
            .created
        else if (r.flags & ev_created != 0 and new)
            .created
        else if (r.flags & ev_is_dir != 0)
            continue
        else
            .modified;
        switch (kind) {
            .created => if (m.seen.fetchPut(ca, ca.dupe(u8, name) catch continue, {}) catch null) |old| ca.free(old.key),
            .moved, .deleted => if (m.seen.fetchRemove(name)) |old| ca.free(old.key),
            else => {},
        }
        try out.append(it.alloc(), .{ .kind = kind, .name = try it.alloc().dupe(u8, name) });
    }
}

/// Stops the stream and frees the watcher.
pub fn close(m: *Mac) void {
    const x = api.?;
    x.stop(m.stream);
    x.invalidate(m.stream);
    x.stream_release(m.stream);
    dispatch_release(m.queue);
    const a = std.heap.c_allocator;
    for (m.raw.items) |r| a.free(r.path);
    m.raw.deinit(a);
    var k = m.seen.keyIterator();
    while (k.next()) |key| a.free(key.*);
    m.seen.deinit(a);
    for (m.pipe) |p| _ = c.close(p);
    a.free(m.real);
    a.destroy(m);
}

//! The channel commands of the capability `thread`: `thread::detach`,
//! `thread::attach`, and `thread::transfer`.
//!
//! A detached channel is a record in the memory of the group: the
//! descriptors, the options, and the buffered input. The buffers of a
//! channel are in the heap of its thread, so `detach` copies them to
//! group memory and frees them, and `attach` copies them to the heap of
//! the new thread. The descriptors move with no copy: they belong to
//! the process.
//!
//! Buffered output goes out before the move. A server socket, a command
//! pipeline, and a standard channel stay with their thread. The move
//! removes the `fileevent` handlers of the channel, as in tclsh. A
//! socket with a connect in the background moves, and its new thread
//! sees the end of the connect.
//!
//! `transfer` detaches the channel and sends `thread::attach` to the
//! target, and waits for the reply. When the target fails, the channel
//! comes back to the sender. At the end of the group each detached
//! channel closes.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const thread = @import("thread.zig");
const chan = @import("chan.zig");
const sys = @import("sys.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Error = interp.Error;
const Group = thread.Group;
const Worker = thread.Worker;
const Channel = chan.Channel;
const Allocator = std.mem.Allocator;

/// The channel commands exist where the channel capability exists.
pub const supported = sys.supported and thread.supported;

/// A detached channel: a copy of the record whose slices are in group
/// memory.
const Detached = struct {
    c: Channel,
};

const Table = struct {
    lock: thread.Lock = .{},
    list: std.ArrayList(*Detached) = .empty,
};

fn finalize(g: *Group) void {
    const t: *Table = @ptrCast(@alignCast(g.chans orelse return));
    const a = g.alloc();
    for (t.list.items) |d| {
        closeFds(&d.c);
        freeDetached(a, d);
    }
    t.list.deinit(g.gpa);
    g.gpa.destroy(t);
    g.chans = null;
}

fn closeFds(c: *const Channel) void {
    if (!c.read_closed or c.wfd < 0) sys.close(c.fd);
    if (c.wfd >= 0 and !c.write_closed) sys.close(c.wfd);
}

fn freeDetached(a: Allocator, d: *Detached) void {
    a.free(d.c.name);
    var r = d.c.rbuf;
    r.deinit(a);
    a.free(d.c.buffering);
    a.free(d.c.peer_host);
    a.destroy(d);
}

fn table(it: *Interp, g: *Group) Error!*Table {
    g.lock.lock();
    defer g.lock.unlock();
    if (g.chans) |p| return @ptrCast(@alignCast(p));
    const t = try g.gpa.create(Table);
    t.* = .{};
    g.finalizers.append(g.gpa, finalize) catch {
        g.gpa.destroy(t);
        return it.fail("out of memory", .{});
    };
    g.chans = t;
    return t;
}

fn notFound(it: *Interp, name: []const u8) Error {
    return it.fail("can not find channel named \"{s}\"", .{name});
}

/// Checks that the channel `name` of `it` can move, and writes its
/// buffered output.
fn check(it: *Interp, name: []const u8) Error!*Channel {
    const c = chan.lookup(it, name) orelse return notFound(it, name);
    if (c.kind == .server) return it.fail("cannot move server socket \"{s}\"", .{name});
    if (c.pids.len > 0) return it.fail("cannot move command pipeline \"{s}\"", .{name});
    if (c.kind == .pipe) return it.fail("channel is shared", .{});
    if (c.draining) return notFound(it, name);
    try chan.flushChannel(it, c);
    if (c.wbuf.items.len > 0) return it.fail("cannot move channel \"{s}\" with output that waits", .{name});
    return c;
}

/// Moves the channel `name` of `it` to group memory.
fn detachChannel(it: *Interp, name: []const u8) Error!void {
    const w = it.worker orelse return it.fail("threads are off", .{});
    const g = w.group;
    const t = try table(it, g);
    const c = try check(it, name);
    const a = g.alloc();
    const full = thread.groupFull(it, error.GroupFull);
    const d = a.create(Detached) catch return full;
    d.c = c.*;
    d.c.name = a.dupe(u8, c.name) catch {
        a.destroy(d);
        return full;
    };
    d.c.rbuf = .empty;
    d.c.rbuf.appendSlice(a, c.rbuf.items[c.rpos..]) catch {
        a.free(d.c.name);
        a.destroy(d);
        return full;
    };
    d.c.rpos = 0;
    d.c.wbuf = .empty;
    // The scripts are in the heap of this thread.
    d.c.on_read = null;
    d.c.on_write = null;
    d.c.buffering = a.dupe(u8, c.buffering) catch &.{};
    d.c.peer_host = a.dupe(u8, c.peer_host) catch &.{};
    t.lock.lock();
    t.list.append(g.gpa, d) catch {
        t.lock.unlock();
        freeDetached(a, d);
        return error.OutOfMemory;
    };
    t.lock.unlock();
    _ = chan.release(it, name);
    c.rbuf.deinit(it.alloc());
    c.wbuf.deinit(it.alloc());
}

/// Adds the detached channel `name` to the table of `it`.
fn attachChannel(it: *Interp, name: []const u8) Error!void {
    const w = it.worker orelse return it.fail("threads are off", .{});
    const g = w.group;
    const t = try table(it, g);
    if (chan.lookup(it, name) != null) return it.fail("channel \"{s}\" already exists", .{name});
    t.lock.lock();
    var found: ?*Detached = null;
    for (t.list.items, 0..) |d, k| {
        if (std.mem.eql(u8, d.c.name, name)) {
            found = t.list.orderedRemove(k);
            break;
        }
    }
    t.lock.unlock();
    const d = found orelse return it.fail("channel not detached", .{});
    const ha = it.alloc();
    const c = ha.create(Channel) catch |e| return putBack(t, g, d, e);
    c.* = d.c;
    c.name = ha.dupe(u8, d.c.name) catch |e| return putBack(t, g, d, e);
    c.rbuf = .empty;
    c.rbuf.appendSlice(ha, d.c.rbuf.items) catch |e| return putBack(t, g, d, e);
    c.buffering = ha.dupe(u8, d.c.buffering) catch |e| return putBack(t, g, d, e);
    c.peer_host = ha.dupe(u8, d.c.peer_host) catch |e| return putBack(t, g, d, e);
    chan.install(it, c) catch |e| return putBack(t, g, d, e);
    freeDetached(g.alloc(), d);
}

/// Returns a detached channel to the list after a failed attach.
fn putBack(t: *Table, g: *Group, d: *Detached, e: Error) Error {
    t.lock.lock();
    defer t.lock.unlock();
    t.list.append(g.gpa, d) catch {
        closeFds(&d.c);
        freeDetached(g.alloc(), d);
    };
    return e;
}

pub fn detach(it: *Interp, name: []const u8) Error!Value {
    try detachChannel(it, name);
    return Value.empty;
}

pub fn attach(it: *Interp, name: []const u8) Error!Value {
    try attachChannel(it, name);
    return Value.empty;
}

/// `transfer` to a thread in another process: an isolated thread, or
/// from the child of one to a thread of its parent. The record and the
/// descriptors go in an `FD` frame, then the target runs
/// `thread::attach`. A channel whose attach fails stays detached there,
/// and closes at the end of the group.
fn transferAcross(it: *Interp, id: u64, name: []const u8) Error!Value {
    const iso = @import("isothread.zig");
    if (comptime !@import("isothread.zig").moves_channels)
        return it.failCode("ZTCL ISOLATION TRANSFER", "a channel cannot move to an isolated thread on this platform yet", .{});
    const me = it.worker.?;
    const a = me.group.gpa;
    // On Windows a socket waits for `WSADuplicateSocketW`: a file, a
    // pipe, or a console moves with `DuplicateHandle`.
    if (comptime @import("builtin").os.tag == .windows) {
        const c = try check(it, name);
        if (c.kind == .socket)
            return it.failCode("ZTCL ISOLATION TRANSFER", "a socket cannot move to an isolated thread on Windows yet", .{});
    }
    const s = try shipOut(it, a, name);
    defer a.free(s.bytes);
    if (!iso.sendChannel(me.group, id, s.bytes, s.fds[0..s.nfds])) {
        shipBack(it, &s);
        return it.fail("thread \"tid0x{x}\" does not exist", .{id});
    }
    s.closeFds();
    const words = [_][]const u8{ "::thread::attach", name };
    const script = try thread.buildScript(it.alloc(), &words);
    _ = try thread.sendWait(it, id, script, false);
    return Value.empty;
}

/// Moves the channel `name` to the thread `id`. The target runs
/// `thread::attach`, and the sender waits for it.
pub fn transfer(it: *Interp, id: u64, name: []const u8) Error!Value {
    const me = it.worker orelse return it.fail("threads are off", .{});
    if (id == me.id) {
        _ = try check(it, name);
        return Value.empty;
    }
    // A missing target gives its error before the channel moves.
    me.group.lock.lock();
    const target = me.group.find(id);
    const other_process = if (target) |t| t.bridge != null else me.group.remote != null;
    me.group.lock.unlock();
    if (target == null and !other_process) return it.fail("thread \"tid0x{x}\" does not exist", .{id});
    if (other_process) return transferAcross(it, id, name);
    try detachChannel(it, name);
    const words = [_][]const u8{ "::thread::attach", name };
    const script = try thread.buildScript(it.alloc(), &words);
    _ = thread.sendWait(it, id, script, false) catch |e| {
        // The channel comes back when it is still detached.
        const r = it.result;
        const code = it.error_code;
        attachChannel(it, name) catch {};
        it.result = r;
        it.error_code = code;
        return e;
    };
    return Value.empty;
}

// ---- Channels across processes (isolated threads, `isothread.zig`) ----

/// A channel on its way to another process: the record in bytes, and
/// its descriptors, which stay open until the frame goes.
pub const Ship = struct {
    bytes: []u8,
    fds: [2]i32 = .{ -1, -1 },
    nfds: usize = 0,

    pub fn closeFds(s: *const Ship) void {
        for (s.fds[0..s.nfds]) |f| sys.close(f);
    }
};

const bit_readable: u16 = 1 << 0;
const bit_writable: u16 = 1 << 1;
const bit_append: u16 = 1 << 2;
const bit_at_eof: u16 = 1 << 3;
const bit_hit_eof: u16 = 1 << 4;
const bit_binary: u16 = 1 << 5;
const bit_blocking: u16 = 1 << 6;
const bit_blocked: u16 = 1 << 7;
const bit_connecting: u16 = 1 << 8;
const bit_read_closed: u16 = 1 << 9;
const bit_write_closed: u16 = 1 << 10;
const bit_fd: u16 = 1 << 11;
const bit_wfd: u16 = 1 << 12;

fn putInt(a: Allocator, l: *std.ArrayList(u8), comptime T: type, v: T) !void {
    try l.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(T, v)));
}

fn putStr(a: Allocator, l: *std.ArrayList(u8), s: []const u8) !void {
    try putInt(a, l, u32, @intCast(s.len));
    try l.appendSlice(a, s);
}

/// Takes the channel `name` out of `it` for another process. Only a file
/// or a socket goes: a channel in memory, a terminal, or a channel with
/// a sibling stays.
pub fn shipOut(it: *Interp, a: Allocator, name: []const u8) Error!Ship {
    const c = try check(it, name);
    if (c.mem or c.pty or c.sibling != null or c.fail != null)
        return it.failCode("ZTCL ISOLATION TRANSFER", "channel \"{s}\" cannot move to another process", .{name});
    var s: Ship = .{ .bytes = &.{} };
    const has_fd = !c.read_closed or c.wfd < 0;
    const has_wfd = c.wfd >= 0 and !c.write_closed;
    if (has_fd) {
        s.fds[s.nfds] = c.fd;
        s.nfds += 1;
    }
    if (has_wfd) {
        s.fds[s.nfds] = c.wfd;
        s.nfds += 1;
    }
    var bits: u16 = 0;
    if (c.readable) bits |= bit_readable;
    if (c.writable) bits |= bit_writable;
    if (c.append) bits |= bit_append;
    if (c.at_eof) bits |= bit_at_eof;
    if (c.hit_eof) bits |= bit_hit_eof;
    if (c.binary) bits |= bit_binary;
    if (c.blocking) bits |= bit_blocking;
    if (c.blocked) bits |= bit_blocked;
    if (c.connecting) bits |= bit_connecting;
    if (c.read_closed) bits |= bit_read_closed;
    if (c.write_closed) bits |= bit_write_closed;
    if (has_fd) bits |= bit_fd;
    if (has_wfd) bits |= bit_wfd;
    var l: std.ArrayList(u8) = .empty;
    errdefer l.deinit(a);
    const oom = it.fail("out of memory", .{});
    putStr(a, &l, c.name) catch return oom;
    putInt(a, &l, u16, bits) catch return oom;
    l.append(a, @backingInt(c.input)) catch return oom;
    l.append(a, @backingInt(c.output)) catch return oom;
    l.append(a, @backingInt(c.kind)) catch return oom;
    putInt(a, &l, i64, c.buffersize) catch return oom;
    putStr(a, &l, c.buffering) catch return oom;
    putStr(a, &l, c.peer_host) catch return oom;
    putStr(a, &l, c.rbuf.items[c.rpos..]) catch return oom;
    s.bytes = l.toOwnedSlice(a) catch return oom;
    _ = chan.release(it, name);
    c.rbuf.deinit(it.alloc());
    c.wbuf.deinit(it.alloc());
    return s;
}

const Reader = struct {
    b: []const u8,
    i: usize = 0,

    fn take(r: *Reader, n: usize) ?[]const u8 {
        if (r.b.len - r.i < n) return null;
        defer r.i += n;
        return r.b[r.i..][0..n];
    }
    fn int(r: *Reader, comptime T: type) ?T {
        const s = r.take(@sizeOf(T)) orelse return null;
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }
    fn str(r: *Reader) ?[]const u8 {
        return r.take(r.int(u32) orelse return null);
    }
};

/// Puts a channel from another process in the detached list of `g`,
/// for a `thread::attach` in the group. It takes the descriptors `fds`:
/// on a bad record they close, and the result is false.
pub fn shipIn(g: *Group, bytes: []const u8, fds: []const i32) bool {
    if (!shipInOr(g, bytes, fds)) {
        for (fds) |f| sys.close(f);
        return false;
    }
    return true;
}

fn shipInOr(g: *Group, bytes: []const u8, fds: []const i32) bool {
    var r: Reader = .{ .b = bytes };
    const name = r.str() orelse return false;
    const bits = r.int(u16) orelse return false;
    const input = r.int(u8) orelse return false;
    const output = r.int(u8) orelse return false;
    const kind = r.int(u8) orelse return false;
    const buffersize = r.int(i64) orelse return false;
    const buffering = r.str() orelse return false;
    const peer_host = r.str() orelse return false;
    const rbuf = r.str() orelse return false;
    if (r.i != bytes.len or name.len == 0) return false;
    if (input > @backingInt(chan.Translation.binary) or output > @backingInt(chan.Translation.binary)) return false;
    // Only a file or a socket crosses.
    if (kind > 1) return false;
    const want: usize = @as(usize, @intFromBool(bits & bit_fd != 0)) + @intFromBool(bits & bit_wfd != 0);
    if (want != fds.len or want == 0) return false;
    var k: usize = 0;
    var c: Channel = .{ .name = name, .fd = -1, .readable = bits & bit_readable != 0, .writable = bits & bit_writable != 0 };
    if (bits & bit_fd != 0) {
        c.fd = fds[k];
        k += 1;
    }
    if (bits & bit_wfd != 0) c.wfd = fds[k];
    c.append = bits & bit_append != 0;
    c.at_eof = bits & bit_at_eof != 0;
    c.hit_eof = bits & bit_hit_eof != 0;
    c.binary = bits & bit_binary != 0;
    c.blocking = bits & bit_blocking != 0;
    c.blocked = bits & bit_blocked != 0;
    c.connecting = bits & bit_connecting != 0;
    c.read_closed = bits & bit_read_closed != 0;
    c.write_closed = bits & bit_write_closed != 0;
    c.input = @fromBackingInt(@intCast(input));
    c.output = @fromBackingInt(@intCast(output));
    c.kind = if (kind == 0) .file else .socket;
    c.buffersize = buffersize;
    const a = g.alloc();
    const t: *Table = blk: {
        g.lock.lock();
        defer g.lock.unlock();
        if (g.chans) |p| break :blk @ptrCast(@alignCast(p));
        const nt = g.gpa.create(Table) catch return false;
        nt.* = .{};
        g.finalizers.append(g.gpa, finalize) catch {
            g.gpa.destroy(nt);
            return false;
        };
        g.chans = nt;
        break :blk nt;
    };
    const d = a.create(Detached) catch return false;
    d.c = c;
    d.c.name = a.dupe(u8, name) catch {
        a.destroy(d);
        return false;
    };
    d.c.rbuf = .empty;
    d.c.buffering = a.dupe(u8, buffering) catch &.{};
    d.c.peer_host = a.dupe(u8, peer_host) catch &.{};
    d.c.rbuf.appendSlice(a, rbuf) catch {
        a.free(d.c.buffering);
        a.free(d.c.peer_host);
        a.free(d.c.name);
        a.destroy(d);
        return false;
    };
    t.lock.lock();
    defer t.lock.unlock();
    // A detached channel of the same name gives way to none: the new one
    // is refused.
    for (t.list.items) |o| if (std.mem.eql(u8, o.c.name, name)) {
        freeDetached(a, d);
        return false;
    };
    t.list.append(g.gpa, d) catch {
        freeDetached(a, d);
        return false;
    };
    return true;
}

/// Gives a channel of `shipOut` back to `it` after a failed send.
pub fn shipBack(it: *Interp, s: *const Ship) void {
    const w = it.worker orelse return s.closeFds();
    var r: Reader = .{ .b = s.bytes };
    const name = r.str() orelse return s.closeFds();
    if (!shipIn(w.group, s.bytes, s.fds[0..s.nfds])) return;
    attachChannel(it, name) catch {};
}

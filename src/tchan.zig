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
    const live = me.group.find(id) != null;
    me.group.lock.unlock();
    if (!live) return it.fail("thread \"tid0x{x}\" does not exist", .{id});
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

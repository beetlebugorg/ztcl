//! The mutexes and the conditions of the capability `thread`:
//! `thread::mutex`, `thread::rwmutex`, and `thread::cond`.
//!
//! A handle is a name in a table of the group (`mid0`, `wid1`, `cid2`),
//! so a bad name is an error and never a bad pointer. Each object has a
//! small internal lock and a wake-up counter. The lock of a script is a
//! state under the internal lock: the owner thread and a depth, or the
//! readers of a read-write mutex. A wait for it is a loop of slices of
//! 50 ms, and after each slice the thread checks its stop flag.
//!
//! A thread that uses an object counts in `users`. `destroy` locks the
//! table lock first, and a user counts itself under the same lock, so
//! no object goes away while a thread waits on it. At the end of a
//! thread, `releaseOwned` frees each lock that the thread holds.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const thread = @import("thread.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;
const Group = thread.Group;
const Worker = thread.Worker;

const Kind = enum { exclusive, recursive, rw, cond };

pub const Obj = struct {
    kind: Kind,
    lock: thread.Lock = .{},
    ev: thread.Event = .{},
    /// The thread that holds the lock, or 0. For a read-write mutex, the
    /// writer.
    owner: u64 = 0,
    depth: u32 = 0,
    /// The readers of a read-write mutex: one id for each read lock.
    readers: std.ArrayList(u64) = .empty,
    /// The threads that use the object now.
    users: u32 = 0,
    /// The count of `notify` calls of a condition.
    gen: u64 = 0,
};

const Table = struct {
    lock: thread.Lock = .{},
    objs: std.StringArrayHashMapUnmanaged(*Obj) = .empty,
    next: u64 = 0,
    /// The mutex of `thread::eval` with no `-lock`.
    eval_obj: Obj = .{ .kind = .recursive },
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn finalize(g: *Group) void {
    const t: *Table = @ptrCast(@alignCast(g.sync orelse return));
    const a = g.alloc();
    var iter = t.objs.iterator();
    while (iter.next()) |e| {
        e.value_ptr.*.readers.deinit(a);
        a.destroy(e.value_ptr.*);
        a.free(e.key_ptr.*);
    }
    t.objs.deinit(a);
    t.eval_obj.readers.deinit(a);
    g.gpa.destroy(t);
    g.sync = null;
}

fn table(it: *Interp, g: *Group) Error!*Table {
    g.lock.lock();
    defer g.lock.unlock();
    if (g.sync) |p| return @ptrCast(@alignCast(p));
    const t = try g.gpa.create(Table);
    t.* = .{};
    g.finalizers.append(g.gpa, finalize) catch {
        g.gpa.destroy(t);
        return it.fail("out of memory", .{});
    };
    g.sync = t;
    return t;
}

fn me(it: *Interp) Error!*Worker {
    return it.worker orelse it.fail("threads are off", .{});
}

/// Finds an object of a kind and counts the caller as a user. Call
/// `done` after the use.
fn take(it: *Interp, t: *Table, name: []const u8, kinds: []const Kind, what: []const u8) Error!*Obj {
    t.lock.lock();
    defer t.lock.unlock();
    const o = t.objs.get(name) orelse return it.fail("no such {s} \"{s}\"", .{ what, name });
    if (std.mem.indexOfScalar(Kind, kinds, o.kind) == null) return it.fail("no such {s} \"{s}\"", .{ what, name });
    o.lock.lock();
    o.users += 1;
    o.lock.unlock();
    return o;
}

fn done(o: *Obj) void {
    o.lock.lock();
    o.users -= 1;
    o.lock.unlock();
}

fn make(it: *Interp, t: *Table, g: *Group, kind: Kind, prefix: []const u8) Error!Value {
    const a = g.alloc();
    const o = a.create(Obj) catch return thread.groupFull(it, error.GroupFull);
    o.* = .{ .kind = kind };
    t.lock.lock();
    defer t.lock.unlock();
    const name = std.fmt.allocPrint(a, "{s}{d}", .{ prefix, t.next }) catch {
        a.destroy(o);
        return thread.groupFull(it, error.GroupFull);
    };
    t.next += 1;
    t.objs.put(a, name, o) catch {
        a.free(name);
        a.destroy(o);
        return thread.groupFull(it, error.GroupFull);
    };
    return .{ .str = try it.alloc().dupe(u8, name) };
}

fn destroy(it: *Interp, t: *Table, g: *Group, name: []const u8, kinds: []const Kind, what: []const u8) Error!Value {
    t.lock.lock();
    defer t.lock.unlock();
    const o = t.objs.get(name) orelse return it.fail("no such {s} \"{s}\"", .{ what, name });
    if (std.mem.indexOfScalar(Kind, kinds, o.kind) == null) return it.fail("no such {s} \"{s}\"", .{ what, name });
    o.lock.lock();
    const busy = o.users > 0 or o.owner != 0 or o.readers.items.len > 0;
    o.lock.unlock();
    if (busy) return it.fail("{s} is in use", .{what});
    const k = t.objs.getIndex(name).?;
    const key = t.objs.keys()[k];
    t.objs.swapRemoveAt(k);
    const a = g.alloc();
    a.free(key);
    o.readers.deinit(a);
    a.destroy(o);
    return Value.empty;
}

/// Waits on `o` for one slice. The caller holds `o.lock`. A flag of the
/// thread ends the wait with an error, and the caller then holds no lock.
fn waitSlice(it: *Interp, w: *Worker, o: *Obj) Error!void {
    if (w.flags.load(.acquire) != 0) {
        o.lock.unlock();
        try thread.checkFlags(it, w);
        o.lock.lock();
        return;
    }
    o.ev.wait(&o.lock, thread.slice_ns);
}

/// Takes the exclusive lock of `o` for the thread `w`.
fn lockExclusive(it: *Interp, w: *Worker, o: *Obj) Error!void {
    o.lock.lock();
    if (o.owner == w.id) {
        if (o.kind == .exclusive) {
            o.lock.unlock();
            return it.fail("locking the same exclusive mutex twice from the same thread", .{});
        }
        o.depth += 1;
        o.lock.unlock();
        return;
    }
    while (o.owner != 0) try waitSlice(it, w, o);
    o.owner = w.id;
    o.depth = 1;
    o.lock.unlock();
}

fn unlockExclusive(it: *Interp, w: *Worker, o: *Obj) Error!void {
    o.lock.lock();
    defer o.lock.unlock();
    if (o.owner != w.id) return it.fail("mutex is not locked", .{});
    o.depth -= 1;
    if (o.depth == 0) {
        o.owner = 0;
        o.ev.signal();
    }
}

fn readLock(it: *Interp, w: *Worker, o: *Obj, g: *Group) Error!void {
    o.lock.lock();
    if (o.owner == w.id) {
        o.lock.unlock();
        return it.fail("read-locking already write-locked mutex from the same thread", .{});
    }
    while (o.owner != 0) try waitSlice(it, w, o);
    o.readers.append(g.alloc(), w.id) catch {
        o.lock.unlock();
        return thread.groupFull(it, error.GroupFull);
    };
    o.lock.unlock();
}

fn writeLock(it: *Interp, w: *Worker, o: *Obj) Error!void {
    o.lock.lock();
    if (o.owner == w.id) {
        o.lock.unlock();
        return it.fail("write-locking the same read-write mutex twice from the same thread", .{});
    }
    if (std.mem.indexOfScalar(u64, o.readers.items, w.id) != null) {
        o.lock.unlock();
        return it.fail("write-locking a read-locked mutex", .{});
    }
    while (o.owner != 0 or o.readers.items.len > 0) try waitSlice(it, w, o);
    o.owner = w.id;
    o.depth = 1;
    o.lock.unlock();
}

fn rwUnlock(it: *Interp, w: *Worker, o: *Obj) Error!void {
    o.lock.lock();
    defer o.lock.unlock();
    if (o.owner == w.id) {
        o.owner = 0;
        o.depth = 0;
    } else if (std.mem.indexOfScalar(u64, o.readers.items, w.id)) |k| {
        _ = o.readers.swapRemove(k);
    } else return it.fail("mutex is not locked", .{});
    o.ev.signal();
}

const mutex_kinds = [_]Kind{ .exclusive, .recursive };

fn cmdMutex(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("thread::mutex option ?args?");
    const w = try me(it);
    const g = w.group;
    const t = try table(it, g);
    const sub = try it.str(argv[1]);
    if (eql(sub, "create")) {
        if (argv.len > 3) return it.wrongArgs("thread::mutex create ?-recursive?");
        var kind: Kind = .exclusive;
        if (argv.len == 3) {
            if (!eql(try it.str(argv[2]), "-recursive")) return it.wrongArgs("thread::mutex create ?-recursive?");
            kind = .recursive;
        }
        return make(it, t, g, kind, "mid");
    }
    if (argv.len != 3) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"thread::mutex {s} mutexHandle\"", .{sub});
    const name = try it.str(argv[2]);
    if (eql(sub, "destroy")) return destroy(it, t, g, name, &mutex_kinds, "mutex");
    if (!eql(sub, "lock") and !eql(sub, "unlock")) return it.fail("bad option \"{s}\": must be create, destroy, lock, or unlock", .{sub});
    const o = try take(it, t, name, &mutex_kinds, "mutex");
    defer done(o);
    if (eql(sub, "lock")) try lockExclusive(it, w, o) else try unlockExclusive(it, w, o);
    return Value.empty;
}

fn cmdRwmutex(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("thread::rwmutex option ?args?");
    const w = try me(it);
    const g = w.group;
    const t = try table(it, g);
    const sub = try it.str(argv[1]);
    if (eql(sub, "create")) {
        if (argv.len != 2) return it.wrongArgs("thread::rwmutex create");
        return make(it, t, g, .rw, "wid");
    }
    if (argv.len != 3) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"thread::rwmutex {s} mutexHandle\"", .{sub});
    const name = try it.str(argv[2]);
    if (eql(sub, "destroy")) return destroy(it, t, g, name, &.{.rw}, "mutex");
    const o = try take(it, t, name, &.{.rw}, "mutex");
    defer done(o);
    if (eql(sub, "rlock")) {
        try readLock(it, w, o, g);
    } else if (eql(sub, "wlock")) {
        try writeLock(it, w, o);
    } else if (eql(sub, "unlock")) {
        try rwUnlock(it, w, o);
    } else return it.fail("bad option \"{s}\": must be create, destroy, rlock, wlock, or unlock", .{sub});
    return Value.empty;
}

fn cmdCond(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("thread::cond option ?args?");
    const w = try me(it);
    const g = w.group;
    const t = try table(it, g);
    const sub = try it.str(argv[1]);
    if (eql(sub, "create")) {
        if (argv.len != 2) return it.wrongArgs("thread::cond create");
        return make(it, t, g, .cond, "cid");
    }
    if (eql(sub, "destroy")) {
        if (argv.len != 3) return it.wrongArgs("thread::cond destroy condHandle");
        return destroy(it, t, g, try it.str(argv[2]), &.{.cond}, "condition variable");
    }
    if (eql(sub, "notify")) {
        if (argv.len != 3) return it.wrongArgs("thread::cond notify condHandle");
        const c = try take(it, t, try it.str(argv[2]), &.{.cond}, "condition variable");
        defer done(c);
        c.lock.lock();
        c.gen += 1;
        c.lock.unlock();
        c.ev.signal();
        return Value.empty;
    }
    if (!eql(sub, "wait")) return it.fail("bad option \"{s}\": must be create, destroy, notify, or wait", .{sub});
    if (argv.len < 4 or argv.len > 5) return it.wrongArgs("thread::cond wait condHandle mutexHandle ?timeout?");
    const ms: ?i64 = if (argv.len == 5) try it.int(argv[4]) else null;
    if (ms) |x| if (x < 0) return it.fail("timeout must be a positive integer", .{});
    const c = try take(it, t, try it.str(argv[2]), &.{.cond}, "condition variable");
    defer done(c);
    const m = try take(it, t, try it.str(argv[3]), &mutex_kinds, "mutex");
    defer done(m);
    m.lock.lock();
    if (m.owner != w.id) {
        m.lock.unlock();
        return it.fail("mutex not locked or wrong type", .{});
    }
    // The wait releases the mutex fully and locks it again with its depth.
    const depth = m.depth;
    c.lock.lock();
    const gen = c.gen;
    m.owner = 0;
    m.depth = 0;
    m.lock.unlock();
    m.ev.signal();
    const end: ?i96 = if (ms) |x| thread.nowNs() + @as(i96, x) * std.time.ns_per_ms else null;
    var failure: ?Error = null;
    while (c.gen == gen) {
        if (w.flags.load(.acquire) != 0) {
            c.lock.unlock();
            thread.checkFlags(it, w) catch |e| {
                failure = e;
            };
            c.lock.lock();
            if (failure != null) break;
            continue;
        }
        var part = thread.slice_ns;
        if (end) |e| {
            const now = thread.nowNs();
            if (now >= e) break;
            part = @intCast(@min(e - now, thread.slice_ns));
        }
        c.ev.wait(&c.lock, part);
    }
    c.lock.unlock();
    // The mutex comes back before the return, also after a cancel. A
    // thread that the group stops ends, and the holder of the mutex can
    // be the host that waits for that end. So after a stop the wait does
    // not lock the mutex again.
    if (w.hasFlag(thread.Flag.stop)) return stopError(it, w, failure);
    m.lock.lock();
    while (m.owner != 0) {
        m.ev.wait(&m.lock, thread.slice_ns);
        if (w.hasFlag(thread.Flag.stop)) {
            m.lock.unlock();
            return stopError(it, w, failure);
        }
    }
    m.owner = w.id;
    m.depth = depth;
    m.lock.unlock();
    if (failure) |e| return e;
    return Value.empty;
}

/// The error of a condition wait that a stop ended.
fn stopError(it: *Interp, w: *Worker, failure: ?Error) Error {
    if (failure) |e| return e;
    try thread.checkFlags(it, w);
    return error.TclError;
}

/// Frees each lock that the thread `id` holds at its end.
pub fn releaseOwned(g: *Group, id: u64) void {
    const t: *Table = @ptrCast(@alignCast(g.sync orelse return));
    t.lock.lock();
    defer t.lock.unlock();
    for (t.objs.values()) |o| freeFor(o, id);
    freeFor(&t.eval_obj, id);
}

fn freeFor(o: *Obj, id: u64) void {
    o.lock.lock();
    var changed = false;
    if (o.owner == id) {
        o.owner = 0;
        o.depth = 0;
        changed = true;
    }
    var k: usize = 0;
    while (k < o.readers.items.len) {
        if (o.readers.items[k] == id) {
            _ = o.readers.swapRemove(k);
            changed = true;
        } else k += 1;
    }
    o.lock.unlock();
    if (changed) o.ev.signal();
}

/// Takes the mutex of `thread::eval`: the named one, or the one of the
/// group. Gives the object for `unlockFor`.
pub fn lockFor(it: *Interp, name: ?[]const u8) Error!*Obj {
    const w = try me(it);
    const g = w.group;
    const t = try table(it, g);
    const o = if (name) |n| try take(it, t, n, &mutex_kinds, "mutex") else blk: {
        t.eval_obj.lock.lock();
        t.eval_obj.users += 1;
        t.eval_obj.lock.unlock();
        break :blk &t.eval_obj;
    };
    lockExclusive(it, w, o) catch |e| {
        done(o);
        return e;
    };
    return o;
}

pub fn unlockFor(it: *Interp, o: *Obj) void {
    if (it.worker) |w| unlockExclusive(it, w, o) catch {};
    done(o);
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("thread::mutex", cmdMutex);
    try it.register("thread::rwmutex", cmdRwmutex);
    try it.register("thread::cond", cmdCond);
}

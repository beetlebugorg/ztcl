//! The thread pools of the capability `thread`: `tpool::*`.
//!
//! A pool is a record in the memory of the group with a lock, a queue
//! of jobs, and a table of the jobs by id. A worker is a thread of the
//! group (`thread.createOpts`) that runs `poolMain` in place of a
//! script. It runs `-initcmd` one time and then keeps its interpreter
//! between jobs, so a proc of `-initcmd` compiles one time for each
//! worker.
//!
//! A worker waits for a job in slices of 50 ms on the event of the
//! pool. After each slice it checks the stop flag of its thread and the
//! end of the pool. A worker with no job for `-idletime` seconds ends,
//! down to `-minworkers`. It runs `-exitcmd` before its end, except
//! after a stop.
//!
//! A job result is a `thread.Shared` tree in the pool. `tpool::get`
//! gives it one time and frees it. The script of `tpool::wait` waits in
//! slices, runs the messages of its own thread between the slices, and
//! checks its stop flag. A wait on a suspended pool with no listed job
//! that runs or is done gives an error, so the wait cannot last forever.
//!
//! `tpool::release` to zero removes the pool from the table at once. The
//! workers end after their jobs, and the last one frees the pool.
//!
//! Locks: the table lock guards the list of the pools. The pool lock
//! guards one pool. Code locks the table first.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const thread = @import("thread.zig");
const cmds = @import("cmds.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;
const Group = thread.Group;
const Worker = thread.Worker;
const Shared = thread.Shared;
const Allocator = std.mem.Allocator;

const Job = struct {
    id: u64,
    script: []u8,
    detached: bool,
    state: enum { pending, running, done } = .pending,
    canceled: bool = false,
    code: i64 = 0,
    res: Shared = Shared.empty,
    info: []u8 = &.{},
    ecode: Shared = Shared.empty,

    fn destroy(j: *Job, a: Allocator) void {
        a.free(j.script);
        j.res.deinit(a);
        a.free(j.info);
        j.ecode.deinit(a);
        a.destroy(j);
    }
};

const Pool = struct {
    id: u64,
    group: *Group,
    lock: thread.Lock = .{},
    /// Wakes a worker for a job and a waiter for a done job.
    ev: thread.Event = .{},
    min: u32,
    max: u32,
    /// Seconds. Zero keeps an idle worker forever.
    idle_s: i64,
    initcmd: []u8,
    exitcmd: []u8,
    /// The jobs that wait for a worker, oldest first, from `head` on.
    queue: std.ArrayList(*Job) = .empty,
    head: usize = 0,
    /// Each job that a script can name: pending, running, or done.
    jobs: std.AutoHashMapUnmanaged(u64, *Job) = .empty,
    next_job: u64 = 1,
    /// The workers that run, and the idle ones among them.
    workers: u32 = 0,
    idle: u32 = 0,
    /// Workers whose `-initcmd` is done, and the first error of one.
    ready: u32 = 0,
    init_error: ?[]u8 = null,
    suspended: bool = false,
    refs: i32 = 0,
    /// True after the release to zero. The workers end.
    ending: bool = false,
    /// The commands that use the pool now. An ended pool goes when no
    /// worker and no command uses it.
    users: u32 = 0,

    fn alloc(p: *Pool) Allocator {
        return p.group.alloc();
    }

    /// The next job of the queue that a cancel did not remove.
    fn takeJob(p: *Pool) ?*Job {
        while (p.head < p.queue.items.len) {
            const j = p.queue.items[p.head];
            p.head += 1;
            if (p.head == p.queue.items.len) {
                p.queue.clearRetainingCapacity();
                p.head = 0;
            }
            if (j.canceled) {
                j.destroy(p.alloc());
                continue;
            }
            return j;
        }
        return null;
    }

    fn hasJob(p: *Pool) bool {
        for (p.queue.items[p.head..]) |j| if (!j.canceled) return true;
        return false;
    }

    /// Frees the pool. No worker runs.
    fn free(p: *Pool) void {
        const a = p.alloc();
        for (p.queue.items[p.head..]) |j| if (j.canceled or j.state == .pending) {
            if (!j.canceled) _ = p.jobs.remove(j.id);
            j.destroy(a);
        };
        p.queue.deinit(a);
        var iter = p.jobs.valueIterator();
        while (iter.next()) |j| j.*.destroy(a);
        p.jobs.deinit(a);
        a.free(p.initcmd);
        a.free(p.exitcmd);
        if (p.init_error) |e| a.free(e);
        a.destroy(p);
    }
};

const Table = struct {
    lock: thread.Lock = .{},
    pools: std.ArrayList(*Pool) = .empty,
    next: u64 = 1,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Frees each pool at the end of the group. `endGroup` stopped each
/// worker first.
fn finalize(g: *Group) void {
    const t: *Table = @ptrCast(@alignCast(g.pools orelse return));
    for (t.pools.items) |p| p.free();
    t.pools.deinit(g.gpa);
    g.gpa.destroy(t);
    g.pools = null;
}

fn table(it: *Interp, g: *Group) Error!*Table {
    g.lock.lock();
    defer g.lock.unlock();
    if (g.pools) |p| return @ptrCast(@alignCast(p));
    const t = try g.gpa.create(Table);
    t.* = .{};
    g.finalizers.append(g.gpa, finalize) catch {
        g.gpa.destroy(t);
        return it.fail("out of memory", .{});
    };
    g.pools = t;
    return t;
}

fn self(it: *Interp) Error!*Worker {
    return it.worker orelse it.fail("threads are off", .{});
}

fn poolName(it: *Interp, id: u64) Allocator.Error!Value {
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "tpool0x{x}", .{id}) };
}

/// The pool of a name, with a use that the caller ends with `unuse`.
/// A released pool is absent from the table.
fn find(it: *Interp, name: []const u8) Error!*Pool {
    const w = try self(it);
    const t = try table(it, w.group);
    const bad = it.fail("can not find threadpool \"{s}\"", .{name});
    if (!std.mem.startsWith(u8, name, "tpool0x")) return bad;
    const id = std.fmt.parseInt(u64, name[7..], 16) catch return bad;
    t.lock.lock();
    defer t.lock.unlock();
    for (t.pools.items) |p| if (p.id == id) {
        p.lock.lock();
        p.users += 1;
        p.lock.unlock();
        return p;
    };
    return bad;
}

/// Starts one worker of `p`. The caller holds no pool lock.
fn startWorker(it: *Interp, p: *Pool) Error!void {
    p.lock.lock();
    p.workers += 1;
    p.lock.unlock();
    _ = thread.createOpts(it, "", .{ .pool = p, .pool_main = poolMain }) catch |e| {
        p.lock.lock();
        p.workers -= 1;
        p.lock.unlock();
        p.ev.signal();
        return e;
    };
}

// ---- The worker ----

fn poolMain(w: *Worker, x: *Interp) void {
    const p: *Pool = @ptrCast(@alignCast(w.pool.?));
    var ok = true;
    if (p.initcmd.len > 0) {
        const c = runScript(x, p.initcmd) catch null;
        if (c == null or c.?.code == 1) {
            ok = false;
            const msg: []const u8 = if (c) |r| x.str(r.res) catch "error" else x.str(x.result) catch "error";
            p.lock.lock();
            if (p.init_error == null) p.init_error = p.alloc().dupe(u8, msg) catch null;
            p.lock.unlock();
        }
    }
    p.lock.lock();
    p.ready += 1;
    p.lock.unlock();
    p.ev.signal();
    if (ok) serveJobs(w, x, p) else leave(p, true);
}

/// Counts the end of a worker. The caller holds the pool lock when
/// `lock` is false. The last worker of an ended pool frees it.
fn leave(p: *Pool, lock: bool) void {
    if (lock) p.lock.lock();
    p.workers -= 1;
    const last = p.ending and p.workers == 0 and p.users == 0;
    p.lock.unlock();
    if (last) p.free() else p.ev.signal();
}

/// Ends the use of a pool by a command.
fn unuse(p: *Pool) void {
    p.lock.lock();
    p.users -= 1;
    const last = p.ending and p.workers == 0 and p.users == 0;
    p.lock.unlock();
    if (last) p.free();
}

/// The loop of a worker: runs jobs until the pool ends, a stop comes,
/// or the idle time ends.
fn serveJobs(w: *Worker, x: *Interp, p: *Pool) void {
    var idle_since = thread.nowNs();
    p.lock.lock();
    while (true) {
        if (w.hasFlag(thread.Flag.stop)) break;
        if (p.ending) break;
        const job = if (p.suspended) null else p.takeJob();
        if (job) |j| {
            j.state = .running;
            p.lock.unlock();
            runJob(x, p, j);
            idle_since = thread.nowNs();
            p.lock.lock();
            continue;
        }
        if (p.idle_s > 0 and p.workers > p.min) {
            const idle_ns = @as(i96, p.idle_s) * std.time.ns_per_s;
            if (thread.nowNs() - idle_since >= idle_ns) break;
        }
        p.idle += 1;
        p.ev.wait(&p.lock, thread.slice_ns);
        p.idle -= 1;
    }
    // The count goes down under the same lock as the check of the queue,
    // so a post sees the end and starts a new worker.
    const exitcmd = !w.hasFlag(thread.Flag.stop) and p.exitcmd.len > 0;
    const text: []u8 = if (exitcmd) x.alloc().dupe(u8, p.exitcmd) catch &.{} else &.{};
    leave(p, false);
    if (text.len > 0) _ = thread.atGlobal(x, runText, .{ x, text }) catch {};
}

fn runText(it: *Interp, text: []const u8) Error!cmds.Caught {
    return cmds.runCaught(it, it.compile(text));
}

fn runScript(x: *Interp, script: []const u8) Error!cmds.Caught {
    const text = try x.alloc().dupe(u8, script);
    return thread.atGlobal(x, runText, .{ x, text });
}

fn runJob(x: *Interp, p: *Pool, j: *Job) void {
    const a = p.alloc();
    var code: i64 = 1;
    var res: Shared = Shared.empty;
    var info: []u8 = &.{};
    var ecode: Shared = Shared.empty;
    if (runScript(x, j.script)) |c| {
        code = c.code;
        res = thread.share(a, x, c.res) catch .{ .str = a.dupe(u8, "the threads used too much memory") catch &.{} };
        if (c.code == 1) {
            info = a.dupe(u8, x.str(c.error_info) catch "") catch &.{};
            ecode = thread.share(a, x, c.error_code) catch Shared.empty;
        }
    } else |e| {
        // The step limit, the memory limit, or a stop ended the job.
        const msg: []const u8 = if (e == error.OutOfMemory) "out of memory" else x.str(x.result) catch "error";
        res = .{ .str = a.dupe(u8, msg) catch &.{} };
        info = a.dupe(u8, msg) catch &.{};
    }
    p.lock.lock();
    if (j.detached) {
        p.lock.unlock();
        res.deinit(a);
        a.free(info);
        ecode.deinit(a);
        j.destroy(a);
        return;
    }
    j.state = .done;
    j.code = code;
    j.res = res;
    j.info = info;
    j.ecode = ecode;
    p.lock.unlock();
    p.ev.signal();
}

// ---- The commands ----

fn cmdCreate(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const usage = "tpool::create ?-minworkers count? ?-maxworkers count? ?-initcmd script? ?-exitcmd script? ?-idletime seconds?";
    if (argv.len % 2 != 1) return it.wrongArgs(usage);
    var min: i64 = 0;
    var max: i64 = 4;
    var idle: i64 = 0;
    var initcmd: []const u8 = "";
    var exitcmd: []const u8 = "";
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        const o = try it.str(argv[i]);
        if (eql(o, "-minworkers")) {
            min = try it.int(argv[i + 1]);
        } else if (eql(o, "-maxworkers")) {
            max = try it.int(argv[i + 1]);
        } else if (eql(o, "-idletime")) {
            idle = try it.int(argv[i + 1]);
        } else if (eql(o, "-initcmd")) {
            initcmd = try it.str(argv[i + 1]);
        } else if (eql(o, "-exitcmd")) {
            exitcmd = try it.str(argv[i + 1]);
        } else return it.wrongArgs(usage);
    }
    min = std.math.clamp(min, 0, 1 << 16);
    max = std.math.clamp(max, 1, 1 << 16);
    if (min > max) max = min;
    const w = try self(it);
    const g = w.group;
    const t = try table(it, g);
    const a = g.alloc();
    const p = a.create(Pool) catch return thread.groupFull(it, error.GroupFull);
    p.* = .{ .id = 0, .group = g, .min = @intCast(min), .max = @intCast(max), .idle_s = @max(idle, 0), .initcmd = &.{}, .exitcmd = &.{} };
    p.initcmd = a.dupe(u8, initcmd) catch {
        p.free();
        return thread.groupFull(it, error.GroupFull);
    };
    p.exitcmd = a.dupe(u8, exitcmd) catch {
        p.free();
        return thread.groupFull(it, error.GroupFull);
    };
    var k: u32 = 0;
    while (k < p.min) : (k += 1) {
        startWorker(it, p) catch |e| {
            endPool(p);
            return e;
        };
    }
    // Each first worker runs `-initcmd` before the create returns, so an
    // error of it is the error of the create.
    p.lock.lock();
    while (p.ready < p.min and p.workers > 0) {
        p.ev.wait(&p.lock, thread.slice_ns);
        if (w.flags.load(.acquire) != 0) break;
    }
    const failed = p.init_error;
    p.init_error = null;
    p.lock.unlock();
    if (failed) |msg| {
        defer a.free(msg);
        endPool(p);
        return it.fail("{s}", .{msg});
    }
    try thread.checkFlags(it, w);
    t.lock.lock();
    p.id = t.next;
    t.next += 1;
    t.pools.append(g.gpa, p) catch {
        t.lock.unlock();
        endPool(p);
        return error.OutOfMemory;
    };
    t.lock.unlock();
    return poolName(it, p.id);
}

/// Ends a pool that is not in the table. Its workers end after their
/// jobs, and the last one frees the pool. A pool with no worker goes at
/// once.
fn endPool(p: *Pool) void {
    p.lock.lock();
    p.ending = true;
    const none = p.workers == 0 and p.users == 0;
    p.lock.unlock();
    if (none) p.free() else p.ev.signal();
}

fn cmdPost(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const usage = "tpool::post ?-detached? ?-nowait? tpoolId script";
    var detached = false;
    var nowait = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (eql(o, "-detached")) {
            detached = true;
        } else if (eql(o, "-nowait")) {
            nowait = true;
        } else break;
    }
    if (argv.len - i != 2) return it.wrongArgs(usage);
    const p = try find(it, try it.str(argv[i]));
    defer unuse(p);
    const a = p.alloc();
    const j = a.create(Job) catch return thread.groupFull(it, error.GroupFull);
    j.* = .{ .id = 0, .script = &.{}, .detached = detached };
    j.script = a.dupe(u8, try it.str(argv[i + 1])) catch {
        a.destroy(j);
        return thread.groupFull(it, error.GroupFull);
    };
    p.lock.lock();
    j.id = p.next_job;
    p.next_job += 1;
    p.queue.append(a, j) catch {
        p.lock.unlock();
        j.destroy(a);
        return thread.groupFull(it, error.GroupFull);
    };
    if (!detached) {
        p.jobs.put(a, j.id, j) catch {
            _ = p.queue.pop();
            p.lock.unlock();
            j.destroy(a);
            return thread.groupFull(it, error.GroupFull);
        };
    }
    const id = j.id;
    const want = p.idle == 0 and p.workers < p.max and !(nowait and p.workers > 0);
    const workers = p.workers;
    p.lock.unlock();
    p.ev.signal();
    if (want) {
        startWorker(it, p) catch |e| {
            // With a worker, the job waits for it. With no worker at
            // all, the post fails.
            if (workers == 0) {
                p.lock.lock();
                j.canceled = true;
                _ = p.jobs.remove(id);
                p.lock.unlock();
                return e;
            }
        };
    }
    if (detached) return Value.empty;
    return .{ .int = @intCast(id) };
}

fn jobIds(it: *Interp, v: Value) Error![]u64 {
    const items = try it.list(v);
    const out = try it.alloc().alloc(u64, items.len);
    for (items, out) |x, *o| o.* = @bitCast(try it.int(x));
    return out;
}

fn idList(it: *Interp, ids: []const u64) Error!Value {
    const out = try it.alloc().alloc(Value, ids.len);
    for (ids, out) |x, *o| o.* = .{ .int = @bitCast(x) };
    return value.wrapList(it.alloc(), out);
}

fn cmdWait(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 3 or argv.len > 4) return it.wrongArgs("tpool::wait tpoolId jobIdList ?listVar");
    const p = try find(it, try it.str(argv[1]));
    defer unuse(p);
    const w = try self(it);
    const ids = try jobIds(it, argv[2]);
    var done: std.ArrayList(u64) = .empty;
    var rest: std.ArrayList(u64) = .empty;
    while (true) {
        done.clearRetainingCapacity();
        rest.clearRetainingCapacity();
        var live = false;
        var need_worker = false;
        p.lock.lock();
        for (ids) |id| {
            const j = p.jobs.get(id) orelse continue;
            if (j.state == .done) {
                done.append(it.alloc(), id) catch {
                    p.lock.unlock();
                    return error.OutOfMemory;
                };
            } else {
                if (j.state == .running or (!p.suspended and p.workers > 0)) live = true;
                if (j.state == .pending and !p.suspended and p.workers == 0) need_worker = true;
                rest.append(it.alloc(), id) catch {
                    p.lock.unlock();
                    return error.OutOfMemory;
                };
            }
        }
        if (done.items.len > 0 or rest.items.len == 0) {
            p.lock.unlock();
            break;
        }
        if (need_worker) {
            // An idle worker ended at the time of a post. A new one runs
            // the jobs.
            p.lock.unlock();
            try startWorker(it, p);
            continue;
        }
        if (!live) {
            p.lock.unlock();
            return it.fail("the jobs of a suspended pool cannot end", .{});
        }
        p.ev.wait(&p.lock, thread.slice_ns);
        p.lock.unlock();
        try thread.checkFlags(it, w);
        _ = try thread.serve(it, 16);
    }
    if (argv.len == 4) try it.setVar(try it.str(argv[3]), try idList(it, rest.items));
    return idList(it, done.items);
}

fn cmdCancel(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 3 or argv.len > 4) return it.wrongArgs("tpool::cancel tpoolId jobIdList ?listVar");
    const p = try find(it, try it.str(argv[1]));
    defer unuse(p);
    const ids = try jobIds(it, argv[2]);
    var gone: std.ArrayList(u64) = .empty;
    var rest: std.ArrayList(u64) = .empty;
    p.lock.lock();
    defer p.lock.unlock();
    for (ids) |id| {
        const j = p.jobs.get(id) orelse continue;
        if (j.state == .pending) {
            j.canceled = true;
            _ = p.jobs.remove(id);
            try gone.append(it.alloc(), id);
        } else try rest.append(it.alloc(), id);
    }
    if (argv.len == 4) try it.setVar(try it.str(argv[3]), try idList(it, rest.items));
    return idList(it, gone.items);
}

fn cmdGet(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 3 or argv.len > 4) return it.wrongArgs("tpool::get tpoolId jobId ?result?");
    const p = try find(it, try it.str(argv[1]));
    defer unuse(p);
    const id: u64 = @bitCast(try it.int(argv[2]));
    p.lock.lock();
    const j = p.jobs.get(id) orelse {
        p.lock.unlock();
        return it.fail("no such job", .{});
    };
    if (j.state != .done) {
        p.lock.unlock();
        return it.fail("job not completed", .{});
    }
    _ = p.jobs.remove(id);
    p.lock.unlock();
    defer j.destroy(p.alloc());
    const v = try thread.unshare(it, j.res);
    if (argv.len == 4) {
        try it.setVar(try it.str(argv[3]), v);
        return .{ .int = j.code };
    }
    switch (j.code) {
        0, 2 => return v,
        1 => {
            it.result = v;
            it.error_code = try thread.unshare(it, j.ecode);
            if (j.info.len > 0) {
                it.in_error = true;
                it.error_info = .empty;
                try it.error_info.appendSlice(it.alloc(), j.info);
            }
            return error.TclError;
        },
        3 => return error.TclBreak,
        4 => return error.TclContinue,
        else => {
            it.result = v;
            it.custom_code = @intCast(@min(j.code, std.math.maxInt(u32)));
            return error.TclCustom;
        },
    }
}

fn cmdSuspend(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("tpool::suspend tpoolId");
    const p = try find(it, try it.str(argv[1]));
    defer unuse(p);
    p.lock.lock();
    p.suspended = true;
    p.lock.unlock();
    return Value.empty;
}

fn cmdResume(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("tpool::resume tpoolId");
    const p = try find(it, try it.str(argv[1]));
    defer unuse(p);
    p.lock.lock();
    p.suspended = false;
    p.lock.unlock();
    p.ev.signal();
    return Value.empty;
}

fn cmdPreserve(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("tpool::preserve tpoolId");
    const p = try find(it, try it.str(argv[1]));
    defer unuse(p);
    p.lock.lock();
    defer p.lock.unlock();
    p.refs += 1;
    return .{ .int = p.refs };
}

fn cmdRelease(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("tpool::release tpoolId");
    const p = try find(it, try it.str(argv[1]));
    defer unuse(p);
    p.lock.lock();
    if (p.refs > 0) p.refs -= 1;
    const refs = p.refs;
    p.lock.unlock();
    if (refs > 0) return .{ .int = refs };
    // The pool leaves the table at once. Its workers end after their
    // jobs, and the pool goes when the last one ends.
    const w = try self(it);
    const t = try table(it, w.group);
    t.lock.lock();
    if (std.mem.indexOfScalar(*Pool, t.pools.items, p)) |k| _ = t.pools.orderedRemove(k);
    t.lock.unlock();
    endPool(p);
    return .{ .int = 0 };
}

fn cmdNames(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("tpool::names");
    const w = try self(it);
    const t = try table(it, w.group);
    var out: std.ArrayList(Value) = .empty;
    t.lock.lock();
    defer t.lock.unlock();
    for (t.pools.items) |p| try out.append(it.alloc(), try poolName(it, p.id));
    return value.wrapList(it.alloc(), out.items);
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("tpool::create", cmdCreate);
    try it.register("tpool::post", cmdPost);
    try it.register("tpool::wait", cmdWait);
    try it.register("tpool::cancel", cmdCancel);
    try it.register("tpool::get", cmdGet);
    try it.register("tpool::suspend", cmdSuspend);
    try it.register("tpool::resume", cmdResume);
    try it.register("tpool::preserve", cmdPreserve);
    try it.register("tpool::release", cmdRelease);
    try it.register("tpool::names", cmdNames);
    _ = try it.internNs("tpool");
}

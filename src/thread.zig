//! The core of the capability `thread`: groups, threads, messages, and
//! the stop flag.
//!
//! A group belongs to one host interpreter. It has the registry of the
//! threads, the limits, and the shared tables of `tsv`, `tpool`, and the
//! mutexes. Each thread has one interpreter with its own heap. Only the
//! thread that owns a heap allocates from it, so no heap needs a lock.
//!
//! A value crosses threads as a `Shared` tree: an integer, a double, a
//! string, or a list of trees, in the memory of the group. `share` makes
//! the tree from a value, and `unshare` makes a value in the heap of the
//! receiver. The tree keeps the kind of each value.
//!
//! A message goes to the queue of the target. The target runs it at the
//! global level and sends a reply message to the queue of the sender
//! when the sender waits. A waiting sender runs the other messages of
//! its queue, so two threads that send to each other make progress.
//!
//! Locks: a group lock guards the registry and the counts, and a worker
//! lock guards one queue. Code locks the group lock first. Each wait is
//! a slice of at most 50 ms on a futex. After each slice the waiter
//! checks its flags, so a stop reaches a thread that waits.
//!
//! The stop flag: another thread sets a bit in `Worker.flags` and then
//! writes zero to `mem_limit` of the target interpreter, both under the
//! worker lock. The next safe point of the target sees the memory count
//! above the limit and calls `Interp.memPoint`, which calls `safePoint`.
//! The target reads the flags and restores the limit under the same
//! lock. So no flag is lost, and no zero store comes after the restore.
//! `Interp.overLimit` compares with the limit of the worker, so a memory
//! check between the two steps gives no false error.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const probe = @import("probe.zig");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const cmds = @import("cmds.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Error = interp.Error;
const Allocator = std.mem.Allocator;

/// True when the channels of a group share their name counters.
pub const chan_names_ok = @import("sys.zig").supported;

/// True in the WebAssembly build with one shared memory. Each thread
/// is a worker of the host there (`webthread.zig`).
pub const web = builtin.cpu.arch.isWasm() and !builtin.single_threaded;
const webthread = if (web) @import("webthread.zig") else struct {};

/// True when the target has threads.
pub const supported = web or (!builtin.single_threaded and !builtin.cpu.arch.isWasm() and builtin.os.tag != .freestanding);

/// The stack of a thread. A worker on the web uses the shared memory for
/// its stack, so it gets less. The interpreter uses 5 MiB at most.
const stack_size: usize = if (web) 8 << 20 else 32 << 20;

/// The thread of the system, or the worker of the host on the web.
const OsThread = if (web) webthread.Thread else std.Thread;

/// The limits of the threads of one host. The embedder sets them in
/// `Interp.thread_limits` before it turns the capability on.
pub const Limits = struct {
    /// The threads that run at one time, with the pool workers.
    max_threads: u32 = 8,
    /// The steps of one thread. Null gives the steps that the creator
    /// has left.
    compute_limit: ?u64 = null,
    /// The heap bytes of one thread.
    mem_limit: usize = 256 << 20,
    /// The steps of all threads together.
    total_compute: u64 = std.math.maxInt(u64),
    /// The bytes of all threads together, with the shared variables and
    /// the queues.
    total_mem: usize = 1 << 30,
    /// The messages that wait in the queue of one thread.
    max_queue: usize = 10_000,
};

// ---- Locks and waits ----

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Lock = if (web) webthread.Lock else if (!supported) NoLock else struct {
    m: std.Io.Mutex = .init,

    pub fn lock(l: *Lock) void {
        l.m.lockUncancelable(io());
    }

    pub fn unlock(l: *Lock) void {
        l.m.unlock(io());
    }
};

/// The lock of a build with one thread.
const NoLock = struct {
    pub fn lock(_: *NoLock) void {}
    pub fn unlock(_: *NoLock) void {}
};

/// A wake-up counter on a futex. A waiter holds `l`, reads the count,
/// releases `l`, and sleeps until the count changes or the time ends.
///
/// `waiters` counts the threads in a wait, so a signal with no waiter
/// makes no system call. A waiter adds itself before it reads the count,
/// and a signal adds to the count before it reads `waiters`. Both use
/// sequential consistency, so the signal sees the waiter, or the waiter
/// sees the new count and its futex wait returns at once.
pub const Event = struct {
    seq: std.atomic.Value(u32) = .init(0),
    waiters: std.atomic.Value(u32) = .init(0),

    /// Waits at most `ns` nanoseconds. The caller holds `l`, and holds it
    /// again at the return.
    pub fn wait(e: *Event, l: *Lock, ns: u64) void {
        const s = e.enter();
        l.unlock();
        e.sleep(s, ns);
        l.lock();
    }

    /// Adds a waiter and gives the count for `sleep`.
    pub fn enter(e: *Event) u32 {
        _ = e.waiters.fetchAdd(1, .seq_cst);
        return e.seq.load(.seq_cst);
    }

    /// Sleeps until the count is not `s` or `ns` nanoseconds end, and
    /// removes the waiter of `enter`.
    pub fn sleep(e: *Event, s: u32, ns: u64) void {
        if (web) webthread.futexWait(&e.seq.raw, s, @intCast(ns)) else if (!supported) {} else io().futexWaitTimeout(u32, &e.seq.raw, s, .{ .duration = .{ .raw = .fromNanoseconds(@intCast(ns)), .clock = .awake } }) catch {};
        _ = e.waiters.fetchSub(1, .release);
    }

    pub fn signal(e: *Event) void {
        _ = e.seq.fetchAdd(1, .seq_cst);
        if (e.waiters.load(.seq_cst) == 0) return;
        if (web) webthread.futexWake(&e.seq.raw, std.math.maxInt(u32)) else if (!supported) {} else io().futexWake(u32, &e.seq.raw, std.math.maxInt(u32));
    }
};

/// The length of one wait slice.
pub const slice_ns: u64 = 50 * std.time.ns_per_ms;

/// Nanoseconds on a clock that does not go back.
pub fn nowNs() i96 {
    return if (web) webthread.nowNs() else if (!supported) 0 else std.Io.Clock.awake.now(io()).nanoseconds;
}

// ---- The memory of a group ----

/// Counts the bytes of all threads of a group in one atomic counter, and
/// fails an allocation above `limit`.
const Budget = struct {
    gpa: Allocator,
    used: std.atomic.Value(usize) = .init(0),
    limit: usize,

    fn allocator(b: *Budget) Allocator {
        return .{ .ptr = b, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn take(b: *Budget, n: usize) bool {
        const old = b.used.fetchAdd(n, .monotonic);
        if (old +| n > b.limit) {
            _ = b.used.fetchSub(n, .monotonic);
            return false;
        }
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        if (!b.take(len)) return null;
        return b.gpa.rawAlloc(len, al, ra) orelse {
            _ = b.used.fetchSub(len, .monotonic);
            return null;
        };
    }

    fn resize(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        if (n > m.len and !b.take(n - m.len)) return false;
        if (!b.gpa.rawResize(m, al, n, ra)) {
            if (n > m.len) _ = b.used.fetchSub(n - m.len, .monotonic);
            return false;
        }
        if (n < m.len) _ = b.used.fetchSub(m.len - n, .monotonic);
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        if (n > m.len and !b.take(n - m.len)) return null;
        const p = b.gpa.rawRemap(m, al, n, ra) orelse {
            if (n > m.len) _ = b.used.fetchSub(n - m.len, .monotonic);
            return null;
        };
        if (n < m.len) _ = b.used.fetchSub(m.len - n, .monotonic);
        return p;
    }

    fn free(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        b.gpa.rawFree(m, al, ra);
        _ = b.used.fetchSub(m.len, .monotonic);
    }
};

// ---- Values across threads ----

/// A value in the memory of a group. It has no pointer into a heap.
pub const Shared = union(enum) {
    int: i64,
    double: f64,
    str: []u8,
    list: std.ArrayList(Shared),

    pub const empty: Shared = .{ .str = &.{} };

    pub fn deinit(s: *Shared, a: Allocator) void {
        switch (s.*) {
            .str => |t| a.free(t),
            .list => |*l| {
                for (l.items) |*x| x.deinit(a);
                l.deinit(a);
            },
            else => {},
        }
        s.* = empty;
    }

    pub fn clone(s: Shared, a: Allocator) Allocator.Error!Shared {
        return switch (s) {
            .int, .double => s,
            .str => |t| .{ .str = try a.dupe(u8, t) },
            .list => |l| blk: {
                var out: std.ArrayList(Shared) = try .initCapacity(a, l.items.len);
                errdefer {
                    var o: Shared = .{ .list = out };
                    o.deinit(a);
                }
                for (l.items) |x| out.appendAssumeCapacity(try x.clone(a));
                break :blk .{ .list = out };
            },
        };
    }
};

/// A list deeper than this crosses as its string form.
const max_share_depth = 200;

/// The error of a group allocation that passed the total limit.
pub const ShareError = error{ OutOfMemory, GroupFull };

/// Copies `v` to memory of the group allocator `a`. `it` makes the
/// string form of a deep list.
pub fn share(a: Allocator, it: *Interp, v: Value) ShareError!Shared {
    return shareDepth(a, it, v, 0);
}

fn shareDepth(a: Allocator, it: *Interp, v: Value, depth: u32) ShareError!Shared {
    switch (v) {
        .int => |i| return .{ .int = i },
        .double => |d| return .{ .double = d },
        .str => |s| return .{ .str = a.dupe(u8, s) catch return error.GroupFull },
        .list => |l| {
            if (depth >= max_share_depth) {
                const s = try it.str(v);
                return .{ .str = a.dupe(u8, s) catch return error.GroupFull };
            }
            const items = l.items();
            var out: std.ArrayList(Shared) = std.ArrayList(Shared).initCapacity(a, items.len) catch return error.GroupFull;
            errdefer {
                var o: Shared = .{ .list = out };
                o.deinit(a);
            }
            for (items) |x| out.appendAssumeCapacity(try shareDepth(a, it, x, depth + 1));
            return .{ .list = out };
        },
    }
}

/// Makes a value in the heap of `it` from a shared tree.
pub fn unshare(it: *Interp, s: Shared) Allocator.Error!Value {
    return switch (s) {
        .int => |i| .{ .int = i },
        .double => |d| .{ .double = d },
        .str => |t| .{ .str = try it.alloc().dupe(u8, t) },
        .list => |l| blk: {
            const buf = try it.alloc().alloc(Value, l.items.len);
            for (l.items, buf) |x, *b| b.* = try unshare(it, x);
            break :blk try value.wrapList(it.alloc(), buf);
        },
    };
}

/// The error of a command whose group allocation failed.
pub fn groupFull(it: *Interp, e: ShareError) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.GroupFull => it.failCode("THREAD MEMORY", "the threads used too much memory", .{}),
    };
}

// ---- Messages ----

pub const Msg = struct {
    kind: Kind,
    /// The id of the sender.
    from: u64 = 0,
    /// The number that matches a reply with its send.
    seq: u64 = 0,
    /// A script, or the name of the variable of an async result.
    text: []u8 = &.{},
    /// The result: the code, the value, the trace, and the error code.
    code: i64 = 0,
    res: Shared = Shared.empty,
    info: []u8 = &.{},
    ecode: Shared = Shared.empty,
    /// The variable of the sender that gets the result.
    var_name: []u8 = &.{},
    /// True for a send with `-head`. The proxy of an isolated thread
    /// passes it to the child.
    head: bool = false,

    pub const Kind = enum {
        /// A script. `seq` is zero for an async send.
        script,
        /// The reply to a send that waits.
        reply,
        /// The result of an async send with a variable.
        var_result,
    };

    pub fn destroy(m: *Msg, a: Allocator) void {
        a.free(m.text);
        m.res.deinit(a);
        a.free(m.info);
        m.ecode.deinit(a);
        a.free(m.var_name);
        a.destroy(m);
    }
};

// ---- Threads ----

pub const Flag = struct {
    pub const cancel: u32 = 1;
    pub const unwind: u32 = 2;
    /// The group ends or the thread must end. It stays set.
    pub const stop: u32 = 4;
};

pub const Worker = struct {
    group: *Group,
    id: u64,
    /// The interpreter of the thread. It is null before the start and
    /// after the end. Another thread reads it only under the group lock.
    it: ?*Interp = null,
    os: ?OsThread = null,
    is_main: bool = false,
    state: State = .starting,
    /// The queue and its lock. `ev` wakes a waiter of the queue.
    lock: Lock = .{},
    ev: Event = .{},
    queue: std.ArrayList(*Msg) = .empty,
    /// The bits of `Flag`.
    flags: std.atomic.Value(u32) = .init(0),
    /// The result text of a cancel, under the worker lock.
    cancel_text: ?[]u8 = null,
    /// The reference count of `thread::preserve` and `thread::release`.
    refs: i32 = 0,
    /// True when a release took the count to zero or below.
    released: std.atomic.Value(bool) = .init(false),
    joinable: bool = false,
    /// The exit status for `thread::join`.
    status: i64 = 0,
    /// True after `thread::exit`.
    exiting: bool = false,
    /// `thread::configure` options.
    eventmark: usize = 0,
    unwind_on_error: bool = false,
    /// The next number of a send that waits. Only the owner uses it.
    next_seq: u64 = 1,
    /// The memory limit of the interpreter, for `safePoint`.
    mem_limit: usize = std.math.maxInt(usize),
    /// The steps that the thread got from `total_compute`.
    steps: u64 = 0,
    /// A descriptor that a new message makes readable, for the poll of
    /// the event loop: an eventfd on Linux, and the read end of a pipe
    /// on macOS. It is -1 until the loop of the thread polls.
    wake_fd: std.atomic.Value(i32) = .init(-1),
    /// The write end of the pipe on macOS. It is set before `wake_fd`.
    wake_wr: std.atomic.Value(i32) = .init(-1),
    /// The text of the start script, in group memory.
    script: []u8 = &.{},
    /// A pool worker: the pool and its loop.
    pool: ?*anyopaque = null,
    pool_main: ?*const fn (w: *Worker, it: *Interp) void = null,
    /// The bridge of an isolated thread (`isothread.zig`): the worker has
    /// no interpreter, and its queue goes to a child process.
    bridge: ?*anyopaque = null,

    pub const State = enum { starting, running, failed, done };

    pub fn name(w: *const Worker, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "tid0x{x}", .{w.id}) catch unreachable;
    }

    pub fn isReleased(w: *const Worker) bool {
        return w.released.load(.acquire);
    }

    pub fn hasFlag(w: *const Worker, f: u32) bool {
        return w.flags.load(.acquire) & f != 0;
    }

    /// Wakes each wait of the worker.
    pub fn wake(w: *Worker) void {
        w.lock.lock();
        w.lock.unlock();
        w.ev.signal();
    }
};

/// What a new thread gets from its creator.
const Start = struct {
    caps: u32,
    tcl: interp.TclVersion,
    compute_limit: u64,
    mem_limit: usize,
    output: ?interp.Output,
    clock_host: ?@import("clock.zig").Host,
    event_host: ?@import("event.zig").Host,
    net: @import("sock.zig").Policy,
    exe_name: []const u8,
    noise_seed: u32,
    gc_on: bool,
    gc_stress: u32,
    jit: ?@import("jit.zig").Options,
    fs_fd: i32,
    fs_cwd: []const u8,
    fs_path: []const u8,
    /// The meter of `-meter`, and the units of its budget that the
    /// thread holds. The creator holds a reference until the start ends.
    meter: ?*meter_mod.Meter = null,
    meter_resv: u64 = 0,
};

/// The way of a child process to the group of its parent.
pub const Remote = struct {
    ctx: *anyopaque,
    /// Sends a script to the thread `to` of the parent.
    send: *const fn (ctx: *anyopaque, to: u64, script: []const u8, seq: u64, var_name: []const u8, head: bool) SendError!void,
    /// Gives a reply or an async result to the thread `to` of the parent.
    /// It takes `m`.
    deliver: *const fn (ctx: *anyopaque, to: u64, m: *Msg) void,
    /// Gives an error to `thread::errorproc` of the parent.
    bgerror: *const fn (ctx: *anyopaque, info: []const u8) void,
};

pub const Group = struct {
    gpa: Allocator,
    budget: Budget,
    lock: Lock = .{},
    /// Wakes a wait for a change of the registry.
    ev: Event = .{},
    /// Wakes a sender that waits for room in a queue.
    space_ev: Event = .{},
    /// The running threads, the main thread first.
    workers: std.ArrayList(*Worker) = .empty,
    /// Ended joinable threads that no join took yet.
    ended: std.ArrayList(*Worker) = .empty,
    /// Ended threads that wait for their OS join.
    zombies: std.ArrayList(*Worker) = .empty,
    next_id: u64 = 1,
    limits: Limits,
    /// The threads that run, the main thread not counted.
    running: u32 = 0,
    compute_left: u64,
    stopping: bool = false,
    main: *Worker,
    /// The thread and the procedure of `thread::errorproc`.
    errorproc_id: u64 = 0,
    errorproc: []u8 = &.{},
    /// The output of the host and its lock.
    out_lock: Lock = .{},
    output: ?interp.Output = null,
    /// The tables of `tsv`, `tpool`, and the mutexes.
    tsv: ?*anyopaque = null,
    pools: ?*anyopaque = null,
    /// The detached channels (`tchan.zig`).
    chans: ?*anyopaque = null,
    /// The name counters of the channels of each thread of the group.
    chan_names: if (chan_names_ok) @import("chan.zig").Counters else void = if (chan_names_ok) .{} else {},
    sync: ?*anyopaque = null,
    /// The meters of the group (`meter.zig`), made at the first use.
    meters: ?*anyopaque = null,
    /// The lock of `thread::eval` with no `-lock`.
    eval_lock: ?[]const u8 = null,
    /// Frees a table at the end of the group.
    finalizers: std.ArrayList(*const fn (g: *Group) void) = .empty,
    /// In the child process of an isolated thread: the way to the threads
    /// of the parent (`isothread.zig`). A thread id that the group does
    /// not have goes there.
    remote: ?Remote = null,

    pub fn alloc(g: *Group) Allocator {
        return g.budget.allocator();
    }

    /// The worker of an id that a script can name, or null. A released
    /// thread is gone for scripts, as in the Thread package. The caller
    /// holds the group lock.
    pub fn find(g: *Group, id: u64) ?*Worker {
        const w = g.findLive(id) orelse return null;
        return if (w.is_main or !w.isReleased()) w else null;
    }

    /// The running worker of an id, released or not, or null. Replies
    /// and error reports use it. The caller holds the group lock.
    pub fn findLive(g: *Group, id: u64) ?*Worker {
        for (g.workers.items) |w| if (w.id == id and w.state == .running) return w;
        return null;
    }

    pub fn memUsed(g: *const Group) usize {
        return g.budget.used.load(.monotonic);
    }
};

/// Parses a thread id. Gives 0 for a bad one.
pub fn parseId(text: []const u8) u64 {
    if (!std.mem.startsWith(u8, text, "tid0x")) return 0;
    return std.fmt.parseInt(u64, text[5..], 16) catch 0;
}

pub fn idValue(it: *Interp, id: u64) Allocator.Error!Value {
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "tid0x{x}", .{id}) };
}

/// The worker of the interpreter tree of `it`.
pub fn workerOf(it: *Interp) ?*Worker {
    var root = it;
    while (root.parent) |p| root = p;
    return root.worker;
}

fn lockedWrite(ctx: ?*anyopaque, bytes: []const u8) void {
    const g: *Group = @ptrCast(@alignCast(ctx.?));
    g.out_lock.lock();
    defer g.out_lock.unlock();
    if (g.output) |o| o.write(o.ctx, bytes);
}

/// The lock of the output of the group of a host, or null with no
/// group. The WebAssembly host holds it while it reads the output.
pub fn outLock(host: *Interp) ?*Lock {
    if (comptime !supported) return null;
    const w = host.worker orelse return null;
    return &w.group.out_lock;
}

/// Makes the group of a host. `allow` calls it for the capability.
pub fn startGroup(host: *Interp) Allocator.Error!void {
    if (host.worker != null) return;
    const gpa = host.counter.child;
    const lim = host.thread_limits;
    const g = try gpa.create(Group);
    errdefer gpa.destroy(g);
    const w = try gpa.create(Worker);
    errdefer gpa.destroy(w);
    g.* = .{ .gpa = gpa, .budget = .{ .gpa = gpa, .limit = lim.total_mem }, .limits = lim, .compute_left = lim.total_compute, .main = w };
    w.* = .{ .group = g, .id = g.next_id, .it = host, .is_main = true, .state = .running, .refs = 1 };
    g.next_id += 1;
    try g.workers.append(gpa, w);
    if (comptime chan_names_ok) {
        // The group goes on from the counters of the host.
        g.chan_names.next.store(host.chans.next, .monotonic);
        g.chan_names.next_sock.store(host.chans.next_sock, .monotonic);
        host.chans.shared = &g.chan_names;
    }
    g.output = host.output;
    host.output = .{ .ctx = g, .write = lockedWrite };
    host.worker = w;
}

/// Sets the limits of the threads of a host, also after the start of
/// its group. The totals apply to the threads that start later.
pub fn setLimits(host: *Interp, lim: Limits) void {
    host.thread_limits = lim;
    if (comptime !supported) return;
    const w = host.worker orelse return;
    const g = w.group;
    g.lock.lock();
    defer g.lock.unlock();
    const used = g.limits.total_compute -| g.compute_left;
    g.limits = lim;
    g.compute_left = lim.total_compute -| used;
    g.budget.limit = lim.total_mem;
}

/// Stops each thread of the group of the host and frees the group.
pub fn endGroup(host: *Interp) void {
    const w = host.worker orelse return;
    if (w != w.group.main) return;
    const g = w.group;
    g.lock.lock();
    g.stopping = true;
    g.lock.unlock();
    // The pools stop their workers through the finalizers below. Each
    // other thread gets the stop flag.
    while (true) {
        g.lock.lock();
        for (g.workers.items) |x| if (x != g.main) stopWorker(x, Flag.stop);
        const left = g.running;
        if (left == 0) {
            g.lock.unlock();
            break;
        }
        g.ev.wait(&g.lock, slice_ns);
        g.lock.unlock();
    }
    reapAll(g);
    for (g.finalizers.items) |f| f(g);
    g.finalizers.deinit(g.gpa);
    g.workers.deinit(g.gpa);
    g.ended.deinit(g.gpa);
    g.zombies.deinit(g.gpa);
    drainQueue(g, w);
    w.queue.deinit(g.alloc());
    closeWake(w);
    g.alloc().free(g.errorproc);
    host.output = g.output;
    if (comptime chan_names_ok) {
        host.chans.next = g.chan_names.next.load(.monotonic);
        host.chans.next_sock = g.chan_names.next_sock.load(.monotonic);
        host.chans.shared = null;
    }
    host.worker = null;
    g.gpa.destroy(w);
    g.gpa.destroy(g);
}

/// Joins each ended thread and frees its record.
fn reapAll(g: *Group) void {
    g.lock.lock();
    const zs = g.zombies.toOwnedSlice(g.gpa) catch &.{};
    const es = g.ended.toOwnedSlice(g.gpa) catch &.{};
    g.lock.unlock();
    for (zs) |z| freeWorker(g, z);
    for (es) |e| freeWorker(g, e);
    g.gpa.free(zs);
    g.gpa.free(es);
}

/// Joins the threads that ended with no join. The caller holds no lock.
pub fn reapZombies(g: *Group) void {
    g.lock.lock();
    if (g.zombies.items.len == 0) {
        g.lock.unlock();
        return;
    }
    const zs = g.zombies.toOwnedSlice(g.gpa) catch {
        g.lock.unlock();
        return;
    };
    g.lock.unlock();
    for (zs) |z| freeWorker(g, z);
    g.gpa.free(zs);
}

fn freeWorker(g: *Group, w: *Worker) void {
    if (w.os) |t| t.join();
    closeWake(w);
    g.alloc().free(w.script);
    if (w.cancel_text) |t| g.alloc().free(t);
    g.gpa.destroy(w);
}

/// Sets flag bits of `w` and makes its next safe point call
/// `safePoint`. The caller holds the group lock. The worker lock makes
/// the two stores one step for `checkFlags`: the target restores the
/// limit only under the same lock, so no zero store comes after it.
pub fn stopWorker(w: *Worker, bits: u32) void {
    w.lock.lock();
    _ = w.flags.fetchOr(bits, .acq_rel);
    if (w.it) |x| @atomicStore(usize, &x.mem_limit, 0, .release);
    w.lock.unlock();
    w.ev.signal();
    poke(w);
}

/// The memory check of `Interp.overLimit` for an interpreter whose
/// count is above its `mem_limit`. A thread interpreter compares with
/// the limit of its worker while a stop holds zero in `mem_limit`.
/// The memory limit of the root interpreter `root`: the limit of its
/// worker for a thread, because a stop can hold zero in `mem_limit`.
pub fn limitOf(root: *const Interp) usize {
    const w = root.worker orelse return root.mem_limit;
    if (w.is_main) return root.mem_limit;
    return w.mem_limit;
}

pub fn overLimit(it: *const Interp) bool {
    const w = it.worker orelse return true;
    if (w.is_main) return true;
    return it.counter.used > w.mem_limit;
}

/// The check of the flags at a safe point of `it`. `Interp.memPoint`
/// calls it for an interpreter of a thread.
pub fn safePoint(it: *Interp, w: *Worker) Error!void {
    if (w.is_main) return;
    // A zero in `mem_limit` comes only with a flag, and `checkFlags`
    // restores the limit when it reads the flag.
    try checkFlags(it, w);
}

/// Gives the error of a pending cancel or stop of `w`.
pub fn checkFlags(it: *Interp, w: *Worker) Error!void {
    if (w.flags.load(.acquire) == 0) return;
    // `stopWorker` sets the flags and stores zero in `mem_limit` under
    // the worker lock. So after this lock no zero store is pending.
    w.lock.lock();
    if (!w.is_main) {
        if (w.it) |x| @atomicStore(usize, &x.mem_limit, w.mem_limit, .release);
    }
    const f = w.flags.fetchAnd(Flag.stop, .acq_rel);
    const text = if (f & Flag.stop != 0) null else w.cancel_text;
    if (f & Flag.stop == 0) w.cancel_text = null;
    w.lock.unlock();
    if (f & Flag.stop != 0) {
        @import("meter.zig").sync(it);
        it.compute_limit = 0;
        it.meter_mark = 0;
        return it.failCode("TCL CANCEL UNWIND", "the thread was stopped", .{});
    }
    defer if (text) |t| w.group.alloc().free(t);
    const msg: []const u8 = text orelse if (f & Flag.unwind != 0) "eval unwound" else "eval canceled";
    if (f & Flag.unwind != 0) {
        @import("meter.zig").sync(it);
        it.compute_limit = 0;
        it.meter_mark = 0;
        return it.failCode("TCL CANCEL IUNWIND", "{s}", .{msg});
    }
    return it.failCode("TCL CANCEL EVAL", "{s}", .{msg});
}

/// True when the waits of `it` must end: a stop, a cancel, or an end
/// of the compute limit.
fn mustWake(w: *Worker) bool {
    return w.flags.load(.acquire) != 0;
}

/// Starts a thread. Gives its id.
pub fn create(it: *Interp, script: []const u8, joinable: bool, preserved: bool) Error!u64 {
    return createOpts(it, script, .{ .joinable = joinable, .preserved = preserved });
}

/// The options of a new thread.
pub const Opts = struct {
    joinable: bool = false,
    preserved: bool = false,
    /// A pool worker: the pool and the loop that the thread runs in
    /// place of a script (`tpool.zig`).
    pool: ?*anyopaque = null,
    pool_main: ?*const fn (w: *Worker, it: *Interp) void = null,
    /// The level of the thread (ztcl#209). A level past `interp` runs the
    /// thread in a child process through `isothread.zig`.
    isolation: Isolation = .interp,
    /// `-files host`: an isolated thread of a creator in host mode gets
    /// the files of the host (`isothread.prepare`).
    host_files: bool = false,
    /// `-caps`: the capabilities of the thread, a subset of the bits of
    /// its creator, or null for all of them.
    caps: ?u32 = null,
    /// `-meter`: the meter of the thread. The caller holds a reference
    /// for the call.
    meter: ?*meter_mod.Meter = null,
    /// `-compute`: the most compute units of the thread.
    compute: ?u64 = null,
};

pub const Isolation = enum { interp, process };

/// The platforms of isolated threads (`isothread.zig`).
const iso_ok = @import("isothread.zig").supported;
const meter_mod = @import("meter.zig");

/// Starts a thread with options. Gives its id.
pub fn createOpts(it: *Interp, script: []const u8, o: Opts) Error!u64 {
    const joinable = o.joinable;
    const preserved = o.preserved;
    const me = workerOf(it) orelse return it.fail("threads are off", .{});
    const g = me.group;
    reapZombies(g);
    const text = g.alloc().dupe(u8, script) catch return groupFull(it, error.GroupFull);
    var st = try startOf(it);
    if (o.caps) |c| st.caps &= c;
    const w = g.gpa.create(Worker) catch {
        g.alloc().free(text);
        return error.OutOfMemory;
    };
    g.lock.lock();
    if (g.stopping) {
        g.lock.unlock();
        g.alloc().free(text);
        g.gpa.destroy(w);
        return it.fail("the thread group ends", .{});
    }
    // A released thread holds its place until it ends. The create waits
    // for it for at most one second.
    var waited: u64 = 0;
    while (g.running >= g.limits.max_threads and waited < std.time.ns_per_s and releasedRunning(g)) {
        g.ev.wait(&g.lock, slice_ns);
        waited += slice_ns;
        if (me.flags.load(.acquire) != 0) break;
    }
    if (g.running >= g.limits.max_threads) {
        g.lock.unlock();
        g.alloc().free(text);
        g.gpa.destroy(w);
        return it.failCode("THREAD LIMIT", "too many threads: the limit is {d}", .{g.limits.max_threads});
    }
    const want = @min(g.limits.compute_limit orelse it.compute_limit, o.compute orelse std.math.maxInt(u64));
    var steps = @min(want, g.compute_left);
    // A meter with a budget holds the units of the thread until its end.
    if (o.meter) |m| {
        steps = m.reserve(steps);
        st.meter = m;
        st.meter_resv = steps;
    }
    var resv_back = o.meter != null;
    defer if (resv_back) o.meter.?.unreserve(st.meter_resv);
    if (g.limits.total_compute != std.math.maxInt(u64)) g.compute_left -= steps;
    st.compute_limit = steps;
    w.* = .{ .group = g, .id = g.next_id, .joinable = joinable, .refs = if (preserved) 1 else 0, .script = text, .steps = steps, .mem_limit = st.mem_limit, .pool = o.pool, .pool_main = o.pool_main };
    if (o.isolation != .interp and comptime !iso_ok) {
        if (g.limits.total_compute != std.math.maxInt(u64)) g.compute_left += steps;
        g.lock.unlock();
        g.alloc().free(text);
        g.gpa.destroy(w);
        if (comptime fd_os) {
            if (st.fs_fd >= 0) closeFd(st.fs_fd);
        }
        return it.failCode("ZTCL ISOLATION LEVEL", "the level process is not available on this platform yet", .{});
    }
    const iso = if (comptime iso_ok) (if (o.isolation != .interp) @import("isothread.zig").prepare(it, w, st, o.host_files) catch |e| {
        if (g.limits.total_compute != std.math.maxInt(u64)) g.compute_left += steps;
        g.lock.unlock();
        g.alloc().free(text);
        g.gpa.destroy(w);
        if (comptime fd_os) {
            if (st.fs_fd >= 0) closeFd(st.fs_fd);
        }
        return e;
    } else null) else null;
    g.next_id += 1;
    g.running += 1;
    g.workers.append(g.gpa, w) catch {
        g.running -= 1;
        g.lock.unlock();
        g.alloc().free(text);
        g.gpa.destroy(w);
        return error.OutOfMemory;
    };
    // The lock stays held across the spawn, so the new thread finds its
    // handle in `w.os` when it ends.
    const spawned = if (comptime !iso_ok) OsThread.spawn(.{ .stack_size = stack_size, .allocator = g.gpa }, threadMain, .{ w, st }) else if (iso) |b| OsThread.spawn(.{ .stack_size = stack_size, .allocator = g.gpa }, @import("isothread.zig").bridgeMain, .{ w, b, st }) else OsThread.spawn(.{ .stack_size = stack_size, .allocator = g.gpa }, threadMain, .{ w, st });
    w.os = spawned catch {
        if (comptime iso_ok) if (iso) |b| @import("isothread.zig").unprepare(b);
        _ = g.workers.pop();
        g.running -= 1;
        if (g.limits.total_compute != std.math.maxInt(u64)) g.compute_left += steps;
        g.lock.unlock();
        g.alloc().free(text);
        g.gpa.destroy(w);
        return it.failCode("THREAD CREATE", "the system refused a new thread", .{});
    };
    while (w.state == .starting) g.ev.wait(&g.lock, slice_ns);
    const ok = w.state != .failed;
    // The thread or the bridge took the reservation.
    if (ok) resv_back = false;
    const id = w.id;
    g.lock.unlock();
    if (!ok) {
        if (comptime iso_ok) if (iso) |b| return @import("isothread.zig").startError(it, b);
        return it.failCode("THREAD CREATE", "the new thread could not start its interpreter", .{});
    }
    return id;
}

/// True when a released thread still runs. The caller holds the group
/// lock.
fn releasedRunning(g: *Group) bool {
    for (g.workers.items) |w| if (!w.is_main and w.isReleased()) return true;
    return false;
}

fn startOf(it: *Interp) Error!Start {
    var root = it;
    while (root.parent) |p| root = p;
    const me = root.worker.?;
    const g = me.group;
    var st: Start = .{
        .caps = root.capabilities,
        .tcl = it.tcl,
        .compute_limit = 0,
        .mem_limit = g.limits.mem_limit,
        .output = .{ .ctx = g, .write = lockedWrite },
        .clock_host = root.clock_host,
        .event_host = root.event_host,
        .net = root.net,
        .exe_name = root.exe_name,
        .noise_seed = root.noise_seed,
        .gc_on = root.gc_on,
        .gc_stress = root.heap.stress,
        .jit = if (root.jit) |s| s.options else null,
        .fs_fd = -1,
        .fs_cwd = "",
        .fs_path = "",
    };
    if (comptime fd_os) {
        if (root.fs.fd >= 0) {
            st.fs_cwd = root.fs.cwd;
            st.fs_path = root.fs.path;
            st.fs_fd = dupFd(root.fs.fd);
        }
    } else if (comptime builtin.os.tag == .windows) {
        // The path of the root for an isolated child, which opens it
        // in its own process. A thread of the process shares no jail.
        if (root.fs.fd >= 0 and !root.fs.host) {
            st.fs_cwd = root.fs.cwd;
            st.fs_path = root.fs.path;
        }
    }
    return st;
}

/// Removes the commands of the capability `thread` from the child of an
/// isolated thread that has no such capability, so the child has no
/// `thread::send` to its parent. The broker of the group stays.
pub fn dropThreadCommands(x: *Interp) Allocator.Error!void {
    var gone: std.ArrayList([]const u8) = .empty;
    defer gone.deinit(x.alloc());
    var iter = x.commands.iterator();
    while (iter.next()) |e| {
        const k = std.mem.trimStart(u8, e.key_ptr.*, ":");
        for ([_][]const u8{ "thread::", "tsv::", "tpool::" }) |p| {
            if (std.mem.startsWith(u8, k, p)) try gone.append(x.alloc(), e.key_ptr.*);
        }
    }
    for (gone.items) |k| _ = x.commands.remove(k);
    x.epoch += 1;
}

fn setup(w: *Worker, x: *Interp, st: Start) Allocator.Error!void {
    x.output = st.output;
    x.compute_limit = st.compute_limit;
    x.mem_limit = st.mem_limit;
    x.clock_host = st.clock_host;
    x.event_host = st.event_host;
    x.net = st.net;
    x.exe_name = st.exe_name;
    x.noise_seed = st.noise_seed;
    x.gc_on = st.gc_on;
    if (st.gc_stress != 0) x.setGcStress(st.gc_stress);
    if (st.jit) |o| {
        _ = x.enableJit(o);
    } else x.disableJit();
    if (comptime fd_os) {
        if (st.fs_fd >= 0) {
            x.fs.fd = st.fs_fd;
            x.fs.cwd = try x.alloc().dupe(u8, st.fs_cwd);
            x.fs.path = try x.alloc().dupe(u8, st.fs_path);
        }
    }
    x.worker = w;
    if (comptime chan_names_ok) x.chans.shared = &w.group.chan_names;
    try x.allow(st.caps);
    try x.setTclVersion(st.tcl);
    if (st.meter) |m| {
        meter_mod.attach(x, m, st.meter_resv);
        // The units of the setup, such as `package provide`, count too.
        x.meter_mark = st.compute_limit;
        m.acquire();
        m.counts.threads_interp += 1;
        m.unlock();
    }
}

fn threadMain(w: *Worker, st: Start) void {
    const g = w.group;
    const x = g.gpa.create(Interp) catch return failStart(w, st);
    x.init(g.alloc()) catch {
        g.gpa.destroy(x);
        return failStart(w, st);
    };
    setup(w, x, st) catch {
        x.worker = null;
        x.deinit();
        g.gpa.destroy(x);
        return failStart(w, st);
    };
    g.lock.lock();
    w.it = x;
    w.state = .running;
    g.lock.unlock();
    g.ev.signal();

    // The debugger (`dap.zig`) gets each new interpreter.
    if (comptime probe.enabled) if (probe.threads) |h| h.start(h.ctx, x, w.id, w.script);
    if (w.pool_main != null) {
        topScope(x, runPool, .{ w, x });
    } else {
        const r = if (w.script.len > 0) probe.evalDebug(x, w.script) else topScope(x, waitLoop, .{x});
        if (r) |_| {} else |e| endError(w, x, e);
    }
    finish(w, x);
}

fn runPool(w: *Worker, x: *Interp) void {
    w.pool_main.?(w, x);
}

/// The margin above the frame of an entry, as in `Interp.evalTop`.
const host_margin: usize = 128;

/// Runs `f` as the top entry of the interpreter `x`, as `Interp.evalTop`
/// does for a script. The collector then scans the native stack from
/// here, so the wait loop and the loop of a pool worker collect between
/// their scripts.
pub fn topScope(x: *Interp, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    const outer = x.heap.scopes == 0;
    x.heap.scopes += 1;
    defer x.heap.scopes -= 1;
    if (outer) {
        x.native_base = @frameAddress() + host_margin;
        x.gc_scope = 1;
    }
    defer if (outer) {
        x.gc_scope = 0;
    };
    return @call(.never_inline, f, args);
}

pub fn failStart(w: *Worker, st: Start) void {
    if (comptime fd_os) {
        if (st.fs_fd >= 0) closeFd(st.fs_fd);
    }
    const g = w.group;
    g.lock.lock();
    w.state = .failed;
    if (std.mem.indexOfScalar(*Worker, g.workers.items, w)) |i| _ = g.workers.orderedRemove(i);
    g.running -= 1;
    if (g.limits.total_compute != std.math.maxInt(u64)) g.compute_left += w.steps;
    // The creator frees nothing: the record goes to the zombies, and a
    // later reap joins the thread.
    g.zombies.append(g.gpa, w) catch {};
    g.lock.unlock();
    g.ev.signal();
}

/// Reports the error that ended the script of a thread.
pub fn endError(w: *Worker, x: *Interp, e: Error) void {
    if (w.exiting) return;
    if (w.hasFlag(Flag.stop)) return;
    w.status = 1;
    const text: []const u8 = switch (e) {
        error.OutOfMemory => "out of memory",
        error.TclError => blk: {
            x.finishError() catch {};
            const info = x.getVarPlain("::errorInfo") catch x.result;
            break :blk x.str(info) catch "error";
        },
        else => x.str(x.result) catch "error",
    };
    reportError(w, x, text);
}

/// Sends an error text to the procedure of `thread::errorproc`, or
/// writes it to the output.
pub fn reportError(w: *Worker, x: *Interp, info: []const u8) void {
    const g = w.group;
    var buf: [32]u8 = undefined;
    const id = w.name(&buf);
    if (g.remote) |r| return r.bgerror(r.ctx, info);
    g.lock.lock();
    const target = if (g.errorproc.len > 0) g.findLive(g.errorproc_id) else null;
    if (target) |t| {
        const a = g.alloc();
        const script = buildScript(a, &.{ g.errorproc, id, info }) catch null;
        if (script) |s| {
            const m = a.create(Msg) catch null;
            if (m) |msg| {
                msg.* = .{ .kind = .script, .from = w.id, .text = s };
                pushMsg(t, msg, false);
                g.lock.unlock();
                return;
            }
            a.free(s);
        }
    }
    g.lock.unlock();
    const text = std.fmt.allocPrint(x.alloc(), "Error from thread {s}\n{s}\n", .{ id, info }) catch return;
    if (x.output) |o| o.write(o.ctx, text);
}

/// A script of words, each one a list element.
pub fn buildScript(a: Allocator, words: []const []const u8) Allocator.Error![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    for (words, 0..) |word, i| {
        if (i > 0) try text.append(a, ' ');
        try value.appendElement(a, &text, word, i == 0);
    }
    return text.toOwnedSlice(a);
}

/// Ends a thread: the queue gets its replies, the interpreter goes, and
/// the record waits for a join.
fn finish(w: *Worker, x: *Interp) void {
    const g = w.group;
    // The record stays in the registry until the end, so a join waits
    // for it. A thread in the state `done` gets no message.
    g.lock.lock();
    w.state = .done;
    g.lock.unlock();
    // No new message reaches the queue now. Each waiting sender gets
    // an error.
    failQueue(w);
    if (g.sync) |_| @import("tsync.zig").releaseOwned(g, w.id);
    if (g.tsv) |_| @import("tsv.zig").releaseOwned(g, w.id);
    const left = x.compute_limit;
    if (comptime probe.enabled) if (probe.threads) |h| h.end(h.ctx, x);
    g.lock.lock();
    w.it = null;
    g.lock.unlock();
    x.worker = null;
    x.deinit();
    g.gpa.destroy(x);
    retireLocked(w, left);
}

/// The end of the record of an isolated thread (`isothread.zig`), after
/// its queue got its replies.
pub fn retire(w: *Worker, left: u64) void {
    const g = w.group;
    if (g.sync) |_| @import("tsync.zig").releaseOwned(g, w.id);
    if (g.tsv) |_| @import("tsv.zig").releaseOwned(g, w.id);
    retireLocked(w, left);
}

fn retireLocked(w: *Worker, left: u64) void {
    const g = w.group;
    g.lock.lock();
    if (std.mem.indexOfScalar(*Worker, g.workers.items, w)) |i| _ = g.workers.orderedRemove(i);
    if (g.limits.total_compute != std.math.maxInt(u64)) g.compute_left += @min(left, w.steps);
    g.running -= 1;
    if (w.joinable and !g.stopping) {
        g.ended.append(g.gpa, w) catch g.zombies.append(g.gpa, w) catch {};
    } else {
        g.zombies.append(g.gpa, w) catch {};
    }
    g.lock.unlock();
    g.ev.signal();
}

/// Answers each send that waits in the queue of an ended thread, and
/// frees the queue.
pub fn failQueue(w: *Worker) void {
    const g = w.group;
    w.lock.lock();
    const items = w.queue.toOwnedSlice(g.alloc()) catch &.{};
    w.lock.unlock();
    defer g.alloc().free(items);
    for (items) |m| {
        if (m.kind == .script and m.seq != 0) {
            replyText(g, m.from, m.seq, 1, "target thread died", "THREAD DIED");
        }
        m.destroy(g.alloc());
    }
}

fn drainQueue(g: *Group, w: *Worker) void {
    for (w.queue.items) |m| m.destroy(g.alloc());
    w.queue.clearRetainingCapacity();
}

/// Adds a message to a queue. The caller holds the group lock, so `w`
/// stays alive.
pub fn pushMsg(w: *Worker, m: *Msg, head: bool) void {
    m.head = head;
    w.lock.lock();
    const ok = if (head) w.queue.insert(w.group.alloc(), 0, m) else w.queue.append(w.group.alloc(), m);
    w.lock.unlock();
    if (ok) |_| {
        w.ev.signal();
        poke(w);
    } else |_| m.destroy(w.group.alloc());
}

/// Linux and macOS give a thread the root folder and a wake descriptor.
const fd_os = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

/// A copy of `fd` at 3 or above that closes on exec, or -1.
fn dupFd(fd: i32) i32 {
    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.fcntl(fd, std.os.linux.F.DUPFD_CLOEXEC, 3);
        return if (std.os.linux.errno(rc) == .SUCCESS) @intCast(rc) else -1;
    }
    const rc = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    return if (rc >= 0) rc else -1;
}

pub fn closeFd(fd: i32) void {
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.close(fd);
    } else if (comptime builtin.os.tag == .windows) {
        @import("sys.zig").close(fd);
    } else _ = std.c.close(fd);
}

/// Wakes the thread of `w` from a wait in its event loop or in blocked
/// I/O, for a cancel of `Interp.cancelEval`. The caller does not hold
/// the group lock.
pub fn wakeWorker(w: *Worker) void {
    const g = w.group;
    g.lock.lock();
    defer g.lock.unlock();
    w.ev.signal();
    poke(w);
}

/// Makes the wake descriptor of `w` readable. The caller holds the
/// group lock, so the descriptor stays open.
fn poke(w: *Worker) void {
    if (comptime !fd_os) return;
    const fd = w.wake_fd.load(.acquire);
    if (fd < 0) return;
    if (comptime builtin.os.tag == .linux) {
        const one: u64 = 1;
        _ = std.os.linux.write(fd, std.mem.asBytes(&one), 8);
    } else {
        // A full pipe is readable already, so a failed write is fine.
        const one: u8 = 1;
        _ = std.c.write(w.wake_wr.load(.acquire), @ptrCast(&one), 1);
    }
}

/// The wake descriptor of the thread of `it`, or -1. The event loop
/// polls it with the channels, so a message ends the poll at once.
pub fn wakeFd(it: *Interp) i32 {
    if (comptime !fd_os) return -1;
    const w = it.worker orelse return -1;
    const fd = w.wake_fd.load(.acquire);
    if (fd >= 0) return fd;
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return -1;
        const new: i32 = @intCast(rc);
        w.wake_fd.store(new, .release);
        return new;
    }
    // macOS has no eventfd: a pipe with both ends nonblocking.
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return -1;
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    for (fds) |f| {
        _ = std.c.fcntl(f, std.c.F.SETFL, nonblock);
        _ = std.c.fcntl(f, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    }
    w.wake_wr.store(fds[1], .release);
    w.wake_fd.store(fds[0], .release);
    return fds[0];
}

/// Reads the count of the wake descriptor of the thread of `it`.
pub fn drainWake(it: *Interp) void {
    if (comptime !fd_os) return;
    const w = it.worker orelse return;
    const fd = w.wake_fd.load(.acquire);
    if (fd < 0) return;
    if (comptime builtin.os.tag == .linux) {
        var n: u64 = 0;
        _ = std.os.linux.read(fd, std.mem.asBytes(&n), 8);
        return;
    }
    var buf: [64]u8 = undefined;
    while (std.c.read(fd, &buf, buf.len) == buf.len) {}
}

/// Closes the wake descriptor of `w`. No other thread holds `w`.
fn closeWake(w: *Worker) void {
    if (comptime !fd_os) return;
    const fd = w.wake_fd.load(.acquire);
    if (fd >= 0) closeFd(fd);
    w.wake_fd.store(-1, .release);
    const wr = w.wake_wr.load(.acquire);
    if (wr >= 0) closeFd(wr);
    w.wake_wr.store(-1, .release);
}

/// Sends an error reply to a sender, when it still runs.
fn replyText(g: *Group, to: u64, seq: u64, code: i64, text: []const u8, ecode: []const u8) void {
    const a = g.alloc();
    const m = a.create(Msg) catch return;
    m.* = .{ .kind = .reply, .seq = seq, .code = code };
    m.res = .{ .str = a.dupe(u8, text) catch {
        a.destroy(m);
        return;
    } };
    m.ecode = .{ .str = a.dupe(u8, ecode) catch &.{} };
    m.info = a.dupe(u8, text) catch &.{};
    g.lock.lock();
    defer g.lock.unlock();
    if (g.findLive(to)) |t| pushMsg(t, m, false) else if (g.remote) |r| r.deliver(r.ctx, to, m) else m.destroy(a);
}

/// The reply "target thread died" to a send that waits.
pub fn replyFailed(g: *Group, to: u64, seq: u64) void {
    replyText(g, to, seq, 1, "target thread died", "THREAD DIED");
}

pub const SendError = error{ NoThread, QueueFull, GroupFull, OutOfMemory };

/// Queues a script at the thread `to`. `seq` is nonzero for a send that
/// waits for its reply.
pub fn sendScript(me: *Worker, to: u64, script: []const u8, seq: u64, var_name: []const u8, head: bool) SendError!void {
    const g = me.group;
    const a = g.alloc();
    const m = a.create(Msg) catch return error.GroupFull;
    m.* = .{ .kind = .script, .from = me.id, .seq = seq };
    m.text = a.dupe(u8, script) catch {
        m.destroy(a);
        return error.GroupFull;
    };
    m.var_name = a.dupe(u8, var_name) catch {
        m.destroy(a);
        return error.GroupFull;
    };
    g.lock.lock();
    defer g.lock.unlock();
    const t = g.find(to) orelse {
        m.destroy(a);
        if (g.remote) |r| return r.send(r.ctx, to, script, seq, var_name, head);
        return error.NoThread;
    };
    t.lock.lock();
    const full = t.queue.items.len >= g.limits.max_queue;
    t.lock.unlock();
    if (full) {
        m.destroy(a);
        return error.QueueFull;
    }
    pushMsg(t, m, head);
}

/// The length of the queue of a thread, or null for no thread.
pub fn queueLen(g: *Group, id: u64) ?usize {
    g.lock.lock();
    defer g.lock.unlock();
    const t = g.find(id) orelse return null;
    t.lock.lock();
    defer t.lock.unlock();
    return t.queue.items.len;
}

/// Takes the first message of the queue that is not a reply.
fn takeEvent(w: *Worker) ?*Msg {
    w.lock.lock();
    const m = for (w.queue.items, 0..) |m, i| {
        if (m.kind != .reply) break w.queue.orderedRemove(i);
    } else null;
    w.lock.unlock();
    // A sender that waits for room in this queue (`-eventmark`) wakes.
    if (m != null) w.group.space_ev.signal();
    return m;
}

/// Waits until the queue of the thread `id` has fewer than its
/// `-eventmark` messages. The wait is in slices, and the thread checks
/// its flags after each slice. The main thread runs the messages of its
/// own queue between the slices, so a thread that sends to it and waits
/// cannot stop the host. Another thread runs none: a script of its queue
/// could send to the same full queue again.
pub fn waitRoom(it: *Interp, id: u64) Error!void {
    const me = it.worker orelse return;
    const g = me.group;
    while (true) {
        const seq = g.space_ev.enter();
        g.lock.lock();
        const t = g.find(id) orelse {
            g.lock.unlock();
            _ = g.space_ev.waiters.fetchSub(1, .release);
            return;
        };
        t.lock.lock();
        const full = t.eventmark > 0 and t.queue.items.len >= t.eventmark;
        t.lock.unlock();
        g.lock.unlock();
        if (!full) {
            _ = g.space_ev.waiters.fetchSub(1, .release);
            return;
        }
        g.space_ev.sleep(seq, if (me.is_main) std.time.ns_per_ms else slice_ns);
        try checkFlags(it, me);
        if (me.is_main) _ = try serve(it, 16);
    }
}

/// Takes the reply `seq` from the queue of the thread of `it`. The
/// async results that came before the reply run first, so a sync send
/// after an async send to the same thread sees the variable of the async
/// send set.
fn takeReplyInOrder(it: *Interp, w: *Worker, seq: u64) Error!?*Msg {
    while (true) {
        w.lock.lock();
        var early: ?*Msg = null;
        const at = for (w.queue.items, 0..) |m, i| {
            if (m.kind == .reply and m.seq == seq) break i;
        } else null;
        if (at) |end| {
            for (w.queue.items[0..end], 0..) |m, i| if (m.kind == .var_result) {
                early = w.queue.orderedRemove(i);
                break;
            };
        }
        const r = if (at != null and early == null) w.queue.orderedRemove(at.?) else null;
        w.lock.unlock();
        const m = early orelse return r;
        w.group.space_ev.signal();
        try runMsg(w, it, m);
    }
}

/// Runs the scripts of the queue of `it`, at most `max` of them. Gives
/// true when one ran. A script runs only in the interpreter of the
/// thread, and only when the thread is at its own level.
pub fn serve(it: *Interp, max: usize) Error!bool {
    const w = it.worker orelse return false;
    var ran = false;
    var n: usize = 0;
    while (n < max) : (n += 1) {
        try checkFlags(it, w);
        const m = takeEvent(w) orelse break;
        ran = true;
        try runMsg(w, it, m);
    }
    return ran;
}

/// Blocks until a message comes, a flag is set, or `ns` ends.
pub fn block(it: *Interp, ns: u64) Error!void {
    const w = it.worker orelse return;
    var left = ns;
    w.lock.lock();
    while (true) {
        var has_event = false;
        for (w.queue.items) |m| if (m.kind != .reply) {
            has_event = true;
        };
        if (has_event or mustWake(w)) break;
        if (!w.is_main and w.isReleased()) break;
        if (left == 0) break;
        const part = @min(left, slice_ns);
        w.ev.wait(&w.lock, part);
        left -= part;
    }
    w.lock.unlock();
    try checkFlags(it, w);
}

/// Sleeps `ns` nanoseconds. A flag of the thread ends the sleep with
/// its error. Messages wait in the queue.
pub fn nap(it: *Interp, ns: u64) Error!void {
    const w = it.worker orelse return;
    const end = nowNs() + ns;
    w.lock.lock();
    while (!mustWake(w)) {
        const now = nowNs();
        if (now >= end) break;
        w.ev.wait(&w.lock, @intCast(@min(end - now, slice_ns)));
    }
    w.lock.unlock();
    try checkFlags(it, w);
}

/// True when another thread can still send to `it`: a wait of its event
/// loop with no timer and no channel can end.
pub fn canWake(it: *Interp) bool {
    const w = it.worker orelse return false;
    if (!w.is_main) return !w.isReleased();
    const g = w.group;
    g.lock.lock();
    defer g.lock.unlock();
    return g.running > 0;
}

/// Runs one message in the interpreter of its thread and frees it.
fn runMsg(w: *Worker, it: *Interp, m: *Msg) Error!void {
    const g = w.group;
    const a = g.alloc();
    defer m.destroy(a);
    switch (m.kind) {
        .reply => {},
        .var_result => {
            const v = try unshare(it, m.res);
            const name = try it.alloc().dupe(u8, m.text);
            try atGlobal(it, setGlobal, .{ it, name, v });
        },
        .script => {
            const text = try it.alloc().dupe(u8, m.text);
            const c = atGlobal(it, runText, .{ it, text }) catch |e| {
                // A stop, the compute limit, or the memory limit ended the
                // script. The sender gets the error, and the thread ends.
                if (m.seq != 0) {
                    const msg = if (e == error.OutOfMemory) "out of memory" else it.str(it.result) catch "error";
                    replyText(g, m.from, m.seq, 1, msg, "THREAD STOPPED");
                }
                return e;
            };
            // The sender of a reply sees the counts of this script.
            if (it.meter != null) meter_mod.sync(it);
            if (m.seq != 0 or m.var_name.len > 0) {
                try sendResult(w, it, m, c);
            } else if (c.code == 1) {
                reportError(w, it, it.str(c.error_info) catch "error");
            }
            if (c.code != 0 and w.unwind_on_error and !w.is_main) {
                w.released.store(true, .release);
            }
        },
    }
}

fn runText(it: *Interp, text: []const u8) Error!cmds.Caught {
    return cmds.runCaught(it, it.compile(text));
}

fn setGlobal(it: *Interp, name: []const u8, v: Value) Error!void {
    try it.setVar(name, v);
}

/// Runs `f` at the global level of `it`.
pub fn atGlobal(it: *Interp, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    const frame = it.frame;
    const ns = it.ns;
    it.frame = &it.global;
    it.ns = "";
    defer {
        it.frame = frame;
        it.ns = ns;
    }
    return @call(.auto, f, args);
}

fn sendResult(w: *Worker, it: *Interp, m: *Msg, c: cmds.Caught) Error!void {
    const g = w.group;
    const a = g.alloc();
    const r = a.create(Msg) catch return groupFull(it, error.GroupFull);
    r.* = .{ .kind = if (m.seq != 0) .reply else .var_result, .seq = m.seq, .code = c.code };
    var ok = false;
    defer if (!ok) r.destroy(a);
    r.res = share(a, it, c.res) catch |e| return groupFull(it, e);
    if (c.code == 1) {
        r.info = a.dupe(u8, try it.str(c.error_info)) catch return groupFull(it, error.GroupFull);
        r.ecode = share(a, it, c.error_code) catch |e| return groupFull(it, e);
    }
    if (m.var_name.len > 0 and m.seq == 0) r.text = a.dupe(u8, m.var_name) catch return groupFull(it, error.GroupFull);
    g.lock.lock();
    defer g.lock.unlock();
    ok = true;
    if (g.findLive(m.from)) |t| pushMsg(t, r, false) else if (g.remote) |rem| rem.deliver(rem.ctx, m.from, r) else r.destroy(a);
}

/// Waits for the reply `seq` of the thread `to` and runs the other
/// messages of the queue meanwhile. Gives the reply. The caller frees it.
/// When `to` ends with no reply, the wait gives an error.
pub fn awaitReply(it: *Interp, to: u64, seq: u64) Error!*Msg {
    const w = it.worker.?;
    const g = w.group;
    while (true) {
        if (try takeReplyInOrder(it, w, seq)) |r| return r;
        // A thread pushes its reply before it leaves the registry. So a
        // check of the queue after the end of `to` finds each reply.
        g.lock.lock();
        var live = false;
        for (g.workers.items) |x| if (x.id == to) {
            live = true;
        };
        g.lock.unlock();
        // A thread of the parent of a child process answers through the
        // remote, and an error comes back when it ended.
        if (!live and g.remote == null) {
            const r = try takeReplyInOrder(it, w, seq);
            return r orelse it.failCode("THREAD DIED", "target thread died", .{});
        }
        if (!try serve(it, 1)) {
            w.lock.lock();
            var wait = true;
            for (w.queue.items) |m| {
                if (m.kind != .reply or m.seq == seq) wait = false;
            }
            if (wait and !mustWake(w)) w.ev.wait(&w.lock, slice_ns);
            w.lock.unlock();
            try checkFlags(it, w);
        }
    }
}

/// Runs the event loop of the thread of `it` until a release ends it.
/// The main thread returns when no other thread runs. A thread without
/// the capability `event` runs only its queue.
pub fn waitLoop(it: *Interp) Error!Value {
    const me = it.worker orelse return it.fail("threads are off", .{});
    const events = it.capabilities & @backingInt(interp.Capability.event) != 0 and it.event_host != null;
    while (true) {
        loopPass(it, me, events) catch |e| {
            if (e == error.TclError and idleCancel(it, me)) continue;
            return e;
        };
        if (me.is_main) {
            if (!canWake(it)) return Value.empty;
        } else if (me.isReleased()) return Value.empty;
    }
}

fn loopPass(it: *Interp, me: *Worker, events: bool) Error!void {
    try checkFlags(it, me);
    if (events) {
        _ = try @import("event.zig").doOne(it, true, false);
    } else if (!try serve(it, 64)) {
        try block(it, slice_ns);
    }
}

/// True when the error of a pass of the wait loop is a plain cancel
/// that reached the loop between two scripts. The loop drops it, so the
/// thread keeps its loop. A stop and `-unwind` end the loop.
fn idleCancel(it: *Interp, me: *Worker) bool {
    if (it.compute_limit == 0 or me.hasFlag(Flag.stop)) return false;
    const code = it.error_code;
    return code == .str and std.mem.eql(u8, code.str, "TCL CANCEL EVAL");
}

/// Sends `script` to the thread `id`, waits for the reply, and gives
/// its result or its error.
pub fn sendWait(it: *Interp, id: u64, script: []const u8, head: bool) Error!Value {
    const me = it.worker orelse return it.fail("threads are off", .{});
    const seq = me.next_seq;
    me.next_seq += 1;
    sendScript(me, id, script, seq, "", head) catch |e| return sendError(it, e, id);
    const r = try awaitReply(it, id, seq);
    defer r.destroy(me.group.alloc());
    return applyReply(it, r);
}

/// The error of a failed send.
pub fn sendError(it: *Interp, e: SendError, id: u64) Error {
    return switch (e) {
        error.NoThread => it.fail("thread \"tid0x{x}\" does not exist", .{id}),
        error.QueueFull => it.failCode("THREAD QUEUE", "the queue of thread \"tid0x{x}\" is full", .{id}),
        error.GroupFull => groupFull(it, error.GroupFull),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Turns a reply into the result of the command that waited for it.
pub fn applyReply(it: *Interp, r: *Msg) Error!Value {
    const v = try unshare(it, r.res);
    switch (r.code) {
        0 => return v,
        1 => {
            it.result = v;
            it.error_code = try unshare(it, r.ecode);
            if (r.info.len > 0) {
                // The local trace adds the send command after the trace
                // of the target.
                it.in_error = true;
                it.error_info = .empty;
                try it.error_info.appendSlice(it.alloc(), r.info);
            }
            return error.TclError;
        },
        2 => {
            it.result = v;
            it.ret_code = .ok;
            it.ret_level = 1;
            it.ret_opts = &.{};
            return error.TclReturn;
        },
        3 => {
            it.result = v;
            return error.TclBreak;
        },
        4 => {
            it.result = v;
            return error.TclContinue;
        },
        else => {
            it.result = v;
            it.custom_code = @intCast(@min(r.code, std.math.maxInt(u32)));
            return error.TclCustom;
        },
    }
}

/// The capability: the commands, and the group of a host.
pub fn register(it: *Interp) Allocator.Error!void {
    if (comptime !supported) return;
    if (it.parent != null) return;
    if (it.worker == null) try startGroup(it);
    try @import("threadcmd.zig").register(it);
    try @import("tsv.zig").register(it);
    try @import("tsync.zig").register(it);
    try @import("tpool.zig").register(it);
    if (it.capabilities & @backingInt(interp.Capability.event) != 0) try @import("event.zig").setSource(it);
    if (it.findCommand("package") != null) _ = it.eval("package provide Thread 2.8.11") catch {};
}

/// The source of the event loop: runs the queue and blocks on it.
pub fn eventServe(it: *Interp) Error!bool {
    return serve(it, 64);
}

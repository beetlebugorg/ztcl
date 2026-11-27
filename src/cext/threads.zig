//! The thread slots of the native path, after the manual pages
//! `Thread.3`, `Tcl_GetThreadData`, `Tcl_ExitThread`, and `GetTime.3`
//! of Tcl 8.6: mutexes, conditions, thread data, threads, the exit
//! handlers of a thread, `Tcl_GetTime`, and `Tcl_Sleep`. Servers such as
//! AOLserver and the test commands of Tcl use them.
//!
//! A `Tcl_Mutex` and a `Tcl_Condition` are pointers that start as null.
//! The first lock or wait makes the pthread object under one global
//! lock. A `Tcl_ThreadDataKey` starts as null, and the first call gives
//! it a number. Each thread has its own block for each number, filled
//! with zeros. `Tcl_FinalizeThread` runs the exit handlers of the thread,
//! last in first, and frees its blocks.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const obj = @import("obj.zig");

pub const slots = @This();

const c = std.c;
const gpa = std.heap.c_allocator;
const panicText = obj.panicText;
const OK: c_int = 0;
const ERROR: c_int = 1;

/// Guards the first use of each mutex, condition, and data key.
var init_lock: c.pthread_mutex_t = .{};

const Mutex = c.pthread_mutex_t;
const Cond = c.pthread_cond_t;

fn mutexOf(p: *?*Mutex) *Mutex {
    if (@atomicLoad(?*Mutex, p, .acquire)) |m| return m;
    _ = c.pthread_mutex_lock(&init_lock);
    defer _ = c.pthread_mutex_unlock(&init_lock);
    if (p.*) |m| return m;
    const m = gpa.create(Mutex) catch panicText("out of memory");
    m.* = .{};
    @atomicStore(?*Mutex, p, m, .release);
    return m;
}

pub fn Tcl_MutexLock(p: *?*Mutex) callconv(.c) void {
    _ = c.pthread_mutex_lock(mutexOf(p));
}

pub fn Tcl_MutexUnlock(p: *?*Mutex) callconv(.c) void {
    _ = c.pthread_mutex_unlock(mutexOf(p));
}

pub fn Tcl_MutexFinalize(p: *?*Mutex) callconv(.c) void {
    _ = c.pthread_mutex_lock(&init_lock);
    defer _ = c.pthread_mutex_unlock(&init_lock);
    if (p.*) |m| {
        _ = c.pthread_mutex_destroy(m);
        gpa.destroy(m);
        p.* = null;
    }
}

fn condOf(p: *?*Cond) *Cond {
    if (@atomicLoad(?*Cond, p, .acquire)) |k| return k;
    _ = c.pthread_mutex_lock(&init_lock);
    defer _ = c.pthread_mutex_unlock(&init_lock);
    if (p.*) |k| return k;
    const k = gpa.create(Cond) catch panicText("out of memory");
    k.* = .{};
    @atomicStore(?*Cond, p, k, .release);
    return k;
}

/// `Tcl_Time` of tcl.h.
pub const Time = extern struct { sec: c_long, usec: c_long };

/// Waits on the condition with the mutex locked. A time is the longest
/// wait; null waits until a notify.
pub fn Tcl_ConditionWait(cp: *?*Cond, mp: *?*Mutex, t: ?*const Time) callconv(.c) void {
    const k = condOf(cp);
    const m = mutexOf(mp);
    const limit = t orelse {
        _ = c.pthread_cond_wait(k, m);
        return;
    };
    var now: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &now);
    var ns: i64 = @as(i64, now.nsec) + @as(i64, limit.usec) * 1000;
    var s: i64 = @as(i64, now.sec) + limit.sec + @divFloor(ns, std.time.ns_per_s);
    ns = @mod(ns, std.time.ns_per_s);
    if (s < now.sec) s = now.sec;
    const abs: c.timespec = .{ .sec = @intCast(s), .nsec = @intCast(ns) };
    _ = c.pthread_cond_timedwait(k, m, &abs);
}

/// Wakes each thread that waits on the condition.
pub fn Tcl_ConditionNotify(cp: *?*Cond) callconv(.c) void {
    _ = c.pthread_cond_broadcast(condOf(cp));
}

pub fn Tcl_ConditionFinalize(cp: *?*Cond) callconv(.c) void {
    _ = c.pthread_mutex_lock(&init_lock);
    defer _ = c.pthread_mutex_unlock(&init_lock);
    if (cp.*) |k| {
        _ = c.pthread_cond_destroy(k);
        gpa.destroy(k);
        cp.* = null;
    }
}

var key_count: usize = 0;
threadlocal var blocks: std.ArrayList(?[*]u8) = .empty;

/// The block of `key` for this thread, `size` bytes of zeros on the
/// first call. The key holds its number plus 1.
pub fn Tcl_GetThreadData(key: *usize, size: c_int) callconv(.c) ?*anyopaque {
    var n = @atomicLoad(usize, key, .acquire);
    if (n == 0) {
        _ = c.pthread_mutex_lock(&init_lock);
        if (key.* == 0) {
            key_count += 1;
            @atomicStore(usize, key, key_count, .release);
        }
        n = key.*;
        _ = c.pthread_mutex_unlock(&init_lock);
    }
    const i = n - 1;
    if (blocks.items.len <= i) blocks.appendNTimes(gpa, null, i + 1 - blocks.items.len) catch panicText("out of memory");
    if (blocks.items[i] == null) {
        const p: [*]u8 = @ptrCast(c.calloc(1, @intCast(@max(size, 1))) orelse panicText("out of memory"));
        blocks.items[i] = p;
    }
    return blocks.items[i];
}

pub const ExitProc = *const fn (?*anyopaque) callconv(.c) void;
const Handler = struct { proc: ExitProc, cd: ?*anyopaque };
threadlocal var exit_handlers: std.ArrayList(Handler) = .empty;

pub fn Tcl_CreateThreadExitHandler(proc: ExitProc, cd: ?*anyopaque) callconv(.c) void {
    exit_handlers.append(gpa, .{ .proc = proc, .cd = cd }) catch panicText("out of memory");
}

pub fn Tcl_DeleteThreadExitHandler(proc: ExitProc, cd: ?*anyopaque) callconv(.c) void {
    for (exit_handlers.items, 0..) |h, i| {
        if (h.proc == proc and h.cd == cd) {
            _ = exit_handlers.orderedRemove(i);
            return;
        }
    }
}

/// Runs the exit handlers of this thread, last in first, and frees its
/// thread data.
pub fn Tcl_FinalizeThread() callconv(.c) void {
    while (exit_handlers.pop()) |h| h.proc(h.cd);
    exit_handlers.deinit(gpa);
    for (blocks.items) |b| if (b) |p| c.free(p);
    blocks.deinit(gpa);
}

pub fn Tcl_GetCurrentThread() callconv(.c) ?*anyopaque {
    return @ptrFromInt(@as(usize, @intFromPtr(c.pthread_self())));
}

pub const ThreadProc = *const fn (?*anyopaque) callconv(.c) void;
const Start = struct { proc: ThreadProc, cd: ?*anyopaque };

fn startThread(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const s: *Start = @ptrCast(@alignCast(arg.?));
    const proc = s.proc;
    const cd = s.cd;
    gpa.destroy(s);
    proc(cd);
    return null;
}

const TCL_THREAD_JOINABLE: c_int = 1;

pub fn Tcl_CreateThread(id: *?*anyopaque, proc: ThreadProc, cd: ?*anyopaque, stack: c_int, flags: c_int) callconv(.c) c_int {
    const s = gpa.create(Start) catch return ERROR;
    s.* = .{ .proc = proc, .cd = cd };
    var attr: c.pthread_attr_t = undefined;
    _ = c.pthread_attr_init(&attr);
    if (stack > 0) _ = c.pthread_attr_setstacksize(&attr, @intCast(stack));
    var t: c.pthread_t = undefined;
    if (c.pthread_create(&t, &attr, &startThread, s) != .SUCCESS) {
        gpa.destroy(s);
        return ERROR;
    }
    if (flags & TCL_THREAD_JOINABLE == 0) _ = c.pthread_detach(t);
    id.* = @ptrFromInt(@as(usize, @intFromPtr(t)));
    return OK;
}

pub fn Tcl_JoinThread(id: ?*anyopaque, result: ?*c_int) callconv(.c) c_int {
    const t: c.pthread_t = @ptrFromInt(@intFromPtr(id));
    var v: ?*anyopaque = null;
    if (c.pthread_join(t, &v) != .SUCCESS) return ERROR;
    if (result) |r| r.* = @truncate(@as(isize, @bitCast(@intFromPtr(v))));
    return OK;
}

/// Ends this thread with `status`, the result of Tcl_JoinThread, after
/// Tcl_FinalizeThread.
pub fn Tcl_ExitThread(status: c_int) callconv(.c) noreturn {
    Tcl_FinalizeThread();
    c.pthread_exit(@ptrFromInt(@as(usize, @bitCast(@as(isize, status)))));
}

pub fn Tcl_GetTime(t: *Time) callconv(.c) void {
    var now: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &now);
    t.* = .{ .sec = @intCast(now.sec), .usec = @intCast(@divTrunc(now.nsec, 1000)) };
}

pub fn Tcl_Sleep(ms: c_int) callconv(.c) void {
    if (ms <= 0) return;
    const ts: c.timespec = .{ .sec = @divTrunc(ms, 1000), .nsec = @rem(ms, 1000) * std.time.ns_per_ms };
    _ = c.nanosleep(&ts, null);
}

/// An async handler of `Tcl_AsyncCreate`. `Tcl_AsyncMark` is safe in a
/// signal handler: it sets a flag. `Tcl_AsyncInvoke` runs the handlers
/// with a flag. ztcl does not call `Tcl_AsyncInvoke` between commands
/// yet, so a program that needs the handlers calls it.
pub const AsyncProc = *const fn (?*anyopaque, ?*anyopaque, c_int) callconv(.c) c_int;
const Async = struct {
    proc: AsyncProc,
    cd: ?*anyopaque,
    ready: std.atomic.Value(bool) = .init(false),
    next: ?*Async = null,
};
var async_list: ?*Async = null;
var async_any: std.atomic.Value(bool) = .init(false);

pub fn Tcl_AsyncCreate(proc: AsyncProc, cd: ?*anyopaque) callconv(.c) ?*Async {
    const a = gpa.create(Async) catch return null;
    a.* = .{ .proc = proc, .cd = cd };
    _ = c.pthread_mutex_lock(&init_lock);
    defer _ = c.pthread_mutex_unlock(&init_lock);
    a.next = async_list;
    async_list = a;
    return a;
}

pub fn Tcl_AsyncMark(a: *Async) callconv(.c) void {
    a.ready.store(true, .release);
    async_any.store(true, .release);
}

pub fn Tcl_AsyncReady() callconv(.c) c_int {
    return @intFromBool(async_any.load(.acquire));
}

pub fn Tcl_AsyncInvoke(ip: ?*anyopaque, code: c_int) callconv(.c) c_int {
    if (!async_any.swap(false, .acq_rel)) return code;
    var r = code;
    _ = c.pthread_mutex_lock(&init_lock);
    var it = async_list;
    _ = c.pthread_mutex_unlock(&init_lock);
    while (it) |a| : (it = a.next) {
        if (a.ready.swap(false, .acq_rel)) r = a.proc(a.cd, ip, r);
    }
    return r;
}

pub fn Tcl_AsyncDelete(a: *Async) callconv(.c) void {
    _ = c.pthread_mutex_lock(&init_lock);
    defer _ = c.pthread_mutex_unlock(&init_lock);
    var p = &async_list;
    while (p.*) |x| : (p = &x.next) {
        if (x == a) {
            p.* = a.next;
            gpa.destroy(a);
            return;
        }
    }
}

/// The notifier of a thread. ztcl runs its own event loop in each
/// interp, so the notifier data is a token with no state.
var notifier_token: u8 = 0;

pub fn Tcl_InitNotifier() callconv(.c) ?*anyopaque {
    return &notifier_token;
}

pub fn Tcl_FinalizeNotifier(_: ?*anyopaque) callconv(.c) void {}

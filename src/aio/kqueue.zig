//! The kqueue backend of `aio.zig`, for macOS (task 09).
//!
//! The model is the one of `epoll.zig`. `submit` tries the system call
//! at once on the non-blocking descriptor. A result other than EAGAIN
//! goes to the ready list, and the callback runs in the next `run`. On
//! EAGAIN the completion waits in the table of its descriptor, on the
//! read side (read, accept) or the write side (write, connect), and the
//! loop adds a one-shot EVFILT_READ or EVFILT_WRITE filter. When kqueue
//! gives the event, the call runs again, and EAGAIN adds the filter
//! again. A connect in progress waits for the write side and then reads
//! SO_ERROR.
//!
//! The changes of the filters go into a list, and the next `kevent` of
//! `run` gives the list and waits in one system call. A full list goes
//! to the kernel at once. A change that fails comes back as an event
//! with EV_ERROR, and the completion of that side ends with the errno.
//! A delete of a one-shot filter that already fired gives ENOENT, and
//! the loop skips it.
//!
//! Timers are a list sorted by deadline on the monotonic clock. The
//! wait of `run` ends at the first deadline. `wake` triggers an
//! EVFILT_USER event.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const c = std.c;
const aio = @import("aio.zig");
const sys = @import("sys.zig");
const Completion = aio.Completion;

pub const max_events = 64;
const max_changes = 64;

const Sides = struct {
    reader: ?*Completion = null,
    writer: ?*Completion = null,
};

pub const Queue = struct {
    gpa: std.mem.Allocator,
    kq: aio.fd_t,
    fds: std.AutoHashMapUnmanaged(aio.fd_t, Sides) = .empty,
    changes: [max_changes]c.Kevent = undefined,
    n_changes: usize = 0,
    ready: ?*Completion = null,
    ready_tail: ?*Completion = null,
    timers: ?*Completion = null,

    pub fn init(gpa: std.mem.Allocator) !Queue {
        const kq = c.kqueue();
        if (kq < 0) return error.SystemResources;
        errdefer _ = c.close(kq);
        _ = c.fcntl(kq, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        var q: Queue = .{ .gpa = gpa, .kq = kq };
        q.change(0, c.EVFILT.USER, c.EV.ADD | c.EV.CLEAR, 0);
        if (q.flush() < 0) return error.SystemResources;
        return q;
    }

    pub fn deinit(q: *Queue) void {
        q.fds.deinit(q.gpa);
        _ = c.close(q.kq);
    }

    /// Ends a wait of `run` from another thread.
    pub fn wake(q: *Queue) void {
        const ev: c.Kevent = .{ .ident = 0, .filter = c.EVFILT.USER, .flags = 0, .fflags = c.NOTE.TRIGGER, .data = 0, .udata = 0 };
        var none: [1]c.Kevent = undefined;
        _ = c.kevent(q.kq, @ptrCast(&ev), 1, &none, 0, null);
    }

    fn change(q: *Queue, ident: usize, filter: i32, flags: u32, fflags: u32) void {
        if (q.n_changes == max_changes) _ = q.flush();
        q.changes[q.n_changes] = .{ .ident = ident, .filter = @intCast(filter), .flags = @intCast(flags), .fflags = fflags, .data = 0, .udata = 0 };
        q.n_changes += 1;
    }

    /// Gives the list of changes to the kernel with no wait. An error of
    /// a change comes back as an event, and `handle` reads it.
    fn flush(q: *Queue) i32 {
        if (q.n_changes == 0) return 0;
        var events: [max_changes]c.Kevent = undefined;
        const n = c.kevent(q.kq, &q.changes, @intCast(q.n_changes), &events, max_changes, &.{ .sec = 0, .nsec = 0 });
        q.n_changes = 0;
        if (n < 0) return -@as(i32, @intCast(c._errno().*));
        for (events[0..@intCast(n)]) |e| q.handle(e);
        return 0;
    }

    fn pushReady(q: *Queue, comp: *Completion, res: i32) void {
        comp.result = res;
        comp.next = null;
        if (q.ready_tail) |t| t.next = comp else q.ready = comp;
        q.ready_tail = comp;
    }

    /// The system call of `comp`, or null for EAGAIN.
    fn attempt(comp: *Completion) ?i32 {
        const again = sys.neg(.AGAIN);
        const res: i32 = switch (comp.op) {
            .accept => |o| sys.accept(o.fd),
            .read => |o| sys.read(o.fd, o.buf),
            .write => |o| sys.write(o.fd, o.buf),
            .connect => |o| blk: {
                // deadline 1: the connect is in progress, and its result
                // is SO_ERROR.
                if (comp.deadline == 1) break :blk sys.sockError(o.fd);
                const r = sys.connect(o.fd, o.addr, o.len);
                if (r == sys.neg(.INPROGRESS)) {
                    comp.deadline = 1;
                    return null;
                }
                break :blk r;
            },
            .timer => unreachable,
        };
        if (res == again) return null;
        return res;
    }

    fn fdOf(comp: *const Completion) aio.fd_t {
        return switch (comp.op) {
            inline .accept, .read, .write, .connect => |o| o.fd,
            .timer => unreachable,
        };
    }

    fn isRead(comp: *const Completion) bool {
        return comp.op == .accept or comp.op == .read;
    }

    fn arm(q: *Queue, fd: aio.fd_t, read_side: bool) void {
        q.change(@intCast(fd), if (read_side) c.EVFILT.READ else c.EVFILT.WRITE, c.EV.ADD | c.EV.ONESHOT, 0);
    }

    pub fn submit(q: *Queue, comp: *Completion) !void {
        switch (comp.op) {
            .timer => |o| {
                comp.deadline = aio.now() + o.ns;
                var at = &q.timers;
                while (at.*) |t| : (at = &t.next) {
                    if (t.deadline > comp.deadline) break;
                }
                comp.next = at.*;
                at.* = comp;
                return;
            },
            .connect => comp.deadline = 0,
            else => {},
        }
        const fd = fdOf(comp);
        const read_side = isRead(comp);
        const gop = try q.fds.getOrPut(q.gpa, fd);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const s = gop.value_ptr;
        const slot = if (read_side) &s.reader else &s.writer;
        if (slot.* != null) return error.Busy;
        if (attempt(comp)) |res| {
            q.pushReady(comp, res);
            if (s.reader == null and s.writer == null) _ = q.fds.remove(fd);
            return;
        }
        slot.* = comp;
        q.arm(fd, read_side);
    }

    pub fn cancel(q: *Queue, comp: *Completion) !void {
        const canceled = sys.neg(.CANCELED);
        if (comp.op == .timer) {
            var at = &q.timers;
            while (at.*) |t| : (at = &t.next) {
                if (t == comp) {
                    at.* = comp.next;
                    q.pushReady(comp, canceled);
                    return;
                }
            }
            return;
        }
        const fd = fdOf(comp);
        const s = q.fds.getPtr(fd) orelse return;
        const read_side = if (s.reader == comp) true else if (s.writer == comp) false else return;
        if (read_side) s.reader = null else s.writer = null;
        q.change(@intCast(fd), if (read_side) c.EVFILT.READ else c.EVFILT.WRITE, c.EV.DELETE, 0);
        if (s.reader == null and s.writer == null) _ = q.fds.remove(fd);
        q.pushReady(comp, canceled);
    }

    /// One event of `kevent`: a filter that fired, or the error of a
    /// change.
    fn handle(q: *Queue, e: c.Kevent) void {
        if (e.filter == c.EVFILT.USER) return;
        const fd: aio.fd_t = @intCast(e.ident);
        const read_side = e.filter == c.EVFILT.READ;
        const s = q.fds.getPtr(fd) orelse return;
        const slot = if (read_side) &s.reader else &s.writer;
        const comp = slot.* orelse return;
        if (e.flags & c.EV.ERROR != 0) {
            if (e.data == 0 or e.data == @backingInt(sys.E.NOENT)) return;
            slot.* = null;
            q.pushReady(comp, -@as(i32, @intCast(e.data)));
        } else if (attempt(comp)) |res| {
            slot.* = null;
            q.pushReady(comp, res);
        } else {
            q.arm(fd, read_side);
        }
        if (s.reader == null and s.writer == null) _ = q.fds.remove(fd);
    }

    pub fn run(q: *Queue, l: *aio.Loop, timeout_ns: ?u64) !usize {
        var wait: ?u64 = timeout_ns;
        if (q.timers) |t| {
            const n = aio.now();
            const left = if (t.deadline > n) t.deadline - n else 0;
            if (wait == null or left < wait.?) wait = left;
        }
        if (q.ready != null) wait = 0;
        const end = if (wait) |w| aio.now() + w else 0;
        var events: [max_events]c.Kevent = undefined;
        while (true) {
            var ts: c.timespec = undefined;
            var tsp: ?*const c.timespec = null;
            if (wait != null) {
                const t = aio.now();
                const left = if (t >= end) 0 else end - t;
                ts = .{ .sec = @intCast(left / std.time.ns_per_s), .nsec = @intCast(left % std.time.ns_per_s) };
                tsp = &ts;
            }
            const n = c.kevent(q.kq, &q.changes, @intCast(q.n_changes), &events, max_events, tsp);
            if (n < 0) {
                // A signal ends the wait early with EINTR: wait again for
                // the rest of the time. The changes go again: an add again
                // changes the filter to the same one, and a delete again
                // gives ENOENT, which `handle` skips.
                if (c._errno().* == @backingInt(sys.E.INTR)) continue;
                return error.SystemResources;
            }
            q.n_changes = 0;
            for (events[0..@intCast(n)]) |e| q.handle(e);
            break;
        }
        const t_now = aio.now();
        while (q.timers) |t| {
            if (t.deadline > t_now) break;
            q.timers = t.next;
            q.pushReady(t, 0);
        }
        // The callbacks can submit new operations, so the list is taken
        // first.
        var comp = q.ready;
        q.ready = null;
        q.ready_tail = null;
        var count: usize = 0;
        while (comp) |x| {
            comp = x.next;
            l.finish(x, x.result);
            count += 1;
        }
        return count;
    }
};

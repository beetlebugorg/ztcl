//! The epoll backend of `aio.zig`.
//!
//! `submit` tries the system call at once on the non-blocking
//! descriptor. A result other than EAGAIN goes to the ready list, and
//! the callback runs in the next `run`. On EAGAIN the completion waits
//! in the table of its descriptor: the read side (read, accept) or the
//! write side (write, connect). The epoll interest of a descriptor is
//! the sides that wait, level-triggered. When epoll gives an event, the
//! call runs again. A connect in progress waits for the write side and
//! then reads SO_ERROR.
//!
//! Timers are a list sorted by deadline on the monotonic clock. The
//! wait of `run` ends at the first deadline. `wake` writes an eventfd
//! in the epoll set.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;
const aio = @import("aio.zig");
const Completion = aio.Completion;

pub const max_events = 64;

const Sides = struct {
    reader: ?*Completion = null,
    writer: ?*Completion = null,
    /// The interest that epoll has now.
    events: u32 = 0,
};

pub const Poll = struct {
    gpa: std.mem.Allocator,
    epfd: aio.fd_t,
    wake_fd: aio.fd_t,
    fds: std.AutoHashMapUnmanaged(aio.fd_t, Sides) = .empty,
    ready: ?*Completion = null,
    ready_tail: ?*Completion = null,
    timers: ?*Completion = null,

    pub fn init(gpa: std.mem.Allocator) !Poll {
        const ep = aio.result(linux.epoll_create1(linux.EPOLL.CLOEXEC));
        if (ep < 0) return error.SystemResources;
        errdefer _ = linux.close(ep);
        const ev = aio.result(linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
        if (ev < 0) return error.SystemResources;
        var e: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .fd = ev } };
        if (aio.result(linux.epoll_ctl(ep, linux.EPOLL.CTL_ADD, ev, &e)) < 0) return error.SystemResources;
        return .{ .gpa = gpa, .epfd = ep, .wake_fd = ev };
    }

    /// Ends a wait of `run` from another thread.
    pub fn wake(x: *Poll) void {
        const one: u64 = 1;
        _ = linux.write(x.wake_fd, std.mem.asBytes(&one), 8);
    }

    pub fn deinit(p: *Poll) void {
        p.fds.deinit(p.gpa);
        _ = linux.close(p.wake_fd);
        _ = linux.close(p.epfd);
    }

    fn pushReady(p: *Poll, c: *Completion, res: i32) void {
        c.result = res;
        c.next = null;
        if (p.ready_tail) |t| t.next = c else p.ready = c;
        p.ready_tail = c;
    }

    /// The system call of `c`, or null for EAGAIN.
    fn attempt(c: *Completion) ?i32 {
        const again = -@as(i32, @backingInt(linux.E.AGAIN));
        const res: i32 = switch (c.op) {
            .accept => |o| aio.result(linux.accept4(o.fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC)),
            .read => |o| aio.result(linux.read(o.fd, o.buf.ptr, o.buf.len)),
            .write => |o| aio.result(linux.write(o.fd, o.buf.ptr, o.buf.len)),
            .writev => |o| aio.result(linux.writev(o.fd, o.iov.ptr, o.iov.len)),
            .connect => |o| blk: {
                if (c.deadline == 1) {
                    // The connect is in progress: its result is SO_ERROR.
                    var err: i32 = 0;
                    var len: linux.socklen_t = @sizeOf(i32);
                    _ = linux.getsockopt(o.fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&err), &len);
                    break :blk -err;
                }
                const r = aio.result(linux.connect(o.fd, o.addr, o.len));
                if (r == -@as(i32, @backingInt(linux.E.INPROGRESS))) {
                    c.deadline = 1;
                    return null;
                }
                break :blk r;
            },
            .timer => unreachable,
        };
        if (res == again) return null;
        return res;
    }

    fn update(p: *Poll, fd: aio.fd_t, s: *Sides) !void {
        var want: u32 = 0;
        if (s.reader != null) want |= linux.EPOLL.IN;
        if (s.writer != null) want |= linux.EPOLL.OUT;
        if (want == s.events) return;
        var e: linux.epoll_event = .{ .events = want, .data = .{ .fd = fd } };
        const op: u32 = if (s.events == 0) linux.EPOLL.CTL_ADD else if (want == 0) linux.EPOLL.CTL_DEL else linux.EPOLL.CTL_MOD;
        const rc = aio.result(linux.epoll_ctl(p.epfd, op, fd, &e));
        if (rc < 0) return error.SystemResources;
        s.events = want;
    }

    pub fn submit(p: *Poll, c: *Completion) !void {
        switch (c.op) {
            .timer => |o| {
                c.deadline = aio.now() + o.ns;
                var at = &p.timers;
                while (at.*) |t| : (at = &t.next) {
                    if (t.deadline > c.deadline) break;
                }
                c.next = at.*;
                at.* = c;
                return;
            },
            .connect => c.deadline = 0,
            else => {},
        }
        const fd = switch (c.op) {
            inline .accept, .read, .write, .writev, .connect => |o| o.fd,
            .timer => unreachable,
        };
        const read_side = c.op == .accept or c.op == .read;
        const gop = try p.fds.getOrPut(p.gpa, fd);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const s = gop.value_ptr;
        const slot = if (read_side) &s.reader else &s.writer;
        if (slot.* != null) return error.Busy;
        if (attempt(c)) |res| {
            p.pushReady(c, res);
            if (s.events == 0 and s.reader == null and s.writer == null) _ = p.fds.remove(fd);
            return;
        }
        slot.* = c;
        try p.update(fd, s);
    }

    pub fn cancel(p: *Poll, c: *Completion) !void {
        const canceled = -@as(i32, @backingInt(linux.E.CANCELED));
        if (c.op == .timer) {
            var at = &p.timers;
            while (at.*) |t| : (at = &t.next) {
                if (t == c) {
                    at.* = c.next;
                    p.pushReady(c, canceled);
                    return;
                }
            }
            return;
        }
        const fd = switch (c.op) {
            inline .accept, .read, .write, .writev, .connect => |o| o.fd,
            .timer => unreachable,
        };
        const s = p.fds.getPtr(fd) orelse return;
        if (s.reader == c) s.reader = null else if (s.writer == c) s.writer = null else return;
        try p.update(fd, s);
        if (s.events == 0) _ = p.fds.remove(fd);
        p.pushReady(c, canceled);
    }

    pub fn run(p: *Poll, l: *aio.Loop, timeout_ns: ?u64) !usize {
        var wait_ms: i32 = -1;
        if (timeout_ns) |ns| wait_ms = @intCast(@min(ns / std.time.ns_per_ms + @intFromBool(ns % std.time.ns_per_ms != 0), std.math.maxInt(i32)));
        if (p.timers) |t| {
            const n = aio.now();
            const left = if (t.deadline > n) t.deadline - n else 0;
            const ms: i32 = @intCast(@min(left / std.time.ns_per_ms + @intFromBool(left % std.time.ns_per_ms != 0), std.math.maxInt(i32)));
            if (wait_ms < 0 or ms < wait_ms) wait_ms = ms;
        }
        if (p.ready != null) wait_ms = 0;
        var events: [max_events]linux.epoll_event = undefined;
        const end = if (wait_ms >= 0) aio.now() + @as(u64, @intCast(wait_ms)) * std.time.ns_per_ms else 0;
        var rc = aio.result(linux.epoll_wait(p.epfd, &events, max_events, wait_ms));
        // A signal ends the wait early with EINTR: wait again for the
        // rest of the time.
        while (rc == -@as(i32, @backingInt(linux.E.INTR))) {
            var ms: i32 = -1;
            if (wait_ms >= 0) {
                const t = aio.now();
                ms = if (t >= end) 0 else @intCast((end - t + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
            }
            rc = aio.result(linux.epoll_wait(p.epfd, &events, max_events, ms));
        }
        const n: usize = if (rc < 0) 0 else @intCast(rc);
        for (events[0..n]) |e| {
            const fd = e.data.fd;
            if (fd == p.wake_fd) {
                var buf: u64 = 0;
                _ = linux.read(p.wake_fd, std.mem.asBytes(&buf), 8);
                continue;
            }
            const s = p.fds.getPtr(fd) orelse continue;
            const err = e.events & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0;
            if (s.reader) |c| if (err or e.events & linux.EPOLL.IN != 0) if (attempt(c)) |res| {
                s.reader = null;
                p.pushReady(c, res);
            };
            if (s.writer) |c| if (err or e.events & linux.EPOLL.OUT != 0) if (attempt(c)) |res| {
                s.writer = null;
                p.pushReady(c, res);
            };
            try p.update(fd, s);
            if (s.events == 0) _ = p.fds.remove(fd);
        }
        const t_now = aio.now();
        while (p.timers) |t| {
            if (t.deadline > t_now) break;
            p.timers = t.next;
            p.pushReady(t, 0);
        }
        // The callbacks can submit new operations, so the list is taken
        // first.
        var c = p.ready;
        p.ready = null;
        p.ready_tail = null;
        var count: usize = 0;
        while (c) |x| {
            c = x.next;
            l.finish(x, x.result);
            count += 1;
        }
        return count;
    }
};

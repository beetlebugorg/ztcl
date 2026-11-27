//! The io_uring backend of `aio.zig`, on `std.os.linux.IoUring`.
//!
//! Each operation is one SQE with the address of its completion as the
//! user data. A timer is an IORING_OP_TIMEOUT with the time span in the
//! completion. A wait with a time limit adds a timeout with a count of
//! one, so it ends at the first other CQE or at the limit, and leaves no
//! timeout in the ring. `wake` writes the eventfd that a read of the
//! ring waits on.
//!
//! When the submission queue is full and the kernel takes no more
//! entries (EBUSY while the completion queue has an overflow), the
//! completion waits in `backlog`. `run` puts the backlog in the ring
//! after it reads the CQEs. A canceled completion of the backlog ends
//! in the next `run`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;
const aio = @import("aio.zig");
const Completion = aio.Completion;
const IoUring = linux.IoUring;

/// The user data of the CQEs of the loop itself.
const ignore: u64 = 0;
const wake_tag: u64 = 1;
const limit_tag: u64 = 2;

pub const Ring = struct {
    ring: IoUring,
    wake_fd: aio.fd_t,
    wake_buf: u64 = 0,
    limit_ts: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    wake_armed: bool = false,
    backlog: ?*Completion = null,
    backlog_tail: ?*Completion = null,
    canceled: ?*Completion = null,

    pub fn init(entries: u16) !Ring {
        var ring = try IoUring.init(entries, 0);
        errdefer ring.deinit();
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC);
        if (aio.result(rc) < 0) return error.SystemResources;
        var r: Ring = .{ .ring = ring, .wake_fd = @intCast(rc) };
        try r.armWake();
        _ = try r.ring.submit();
        return r;
    }

    pub fn deinit(r: *Ring) void {
        r.ring.deinit();
        _ = linux.close(r.wake_fd);
    }

    /// A free SQE, or null when the kernel takes no more entries now.
    fn sqe(r: *Ring) !?*linux.io_uring_sqe {
        return r.ring.get_sqe() catch {
            _ = r.ring.submit() catch |e| switch (e) {
                error.CompletionQueueOvercommitted, error.SystemResources => return null,
                else => return e,
            };
            return r.ring.get_sqe() catch null;
        };
    }

    /// Puts the read of the eventfd in the ring. With no free SQE, the
    /// next `run` tries again.
    fn armWake(r: *Ring) !void {
        const s = (try r.sqe()) orelse {
            r.wake_armed = false;
            return;
        };
        s.prep_read(r.wake_fd, std.mem.asBytes(&r.wake_buf), 0);
        s.user_data = wake_tag;
        r.wake_armed = true;
    }

    pub fn submit(r: *Ring, c: *Completion) !void {
        if (r.backlog != null) return r.queue(c);
        const s = (try r.sqe()) orelse return r.queue(c);
        prep(s, c);
    }

    fn queue(r: *Ring, c: *Completion) void {
        c.next = null;
        if (r.backlog_tail) |t| t.next = c else r.backlog = c;
        r.backlog_tail = c;
    }

    fn prep(s: *linux.io_uring_sqe, c: *Completion) void {
        switch (c.op) {
            .accept => |o| s.prep_accept(o.fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC),
            .connect => |o| s.prep_connect(o.fd, o.addr, o.len),
            .read => |o| s.prep_read(o.fd, o.buf, std.math.maxInt(u64)),
            .write => |o| s.prep_write(o.fd, o.buf, std.math.maxInt(u64)),
            .timer => |o| {
                c.ts = .{ .sec = @intCast(o.ns / std.time.ns_per_s), .nsec = @intCast(o.ns % std.time.ns_per_s) };
                s.prep_timeout(&c.ts, 0, 0);
            },
        }
        s.user_data = @intFromPtr(c);
    }

    pub fn cancel(r: *Ring, c: *Completion) !void {
        var at = &r.backlog;
        var prev: ?*Completion = null;
        while (at.*) |x| : ({
            prev = x;
            at = &x.next;
        }) {
            if (x == c) {
                at.* = c.next;
                if (r.backlog_tail == c) r.backlog_tail = prev;
                c.next = r.canceled;
                r.canceled = c;
                return;
            }
        }
        const s = (try r.sqe()) orelse return error.SubmissionQueueFull;
        if (c.op == .timer) s.prep_timeout_remove(@intFromPtr(c), 0) else s.prep_cancel(@intFromPtr(c), 0);
        s.user_data = ignore;
    }

    pub fn run(r: *Ring, l: *aio.Loop, timeout_ns: ?u64) !usize {
        if (!r.wake_armed) try r.armWake();
        // With no free SQE for the limit, the run does not wait.
        var limit_ok = true;
        if (timeout_ns) |ns| {
            r.limit_ts = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
            if (try r.sqe()) |s| {
                s.prep_timeout(&r.limit_ts, 1, 0);
                s.user_data = limit_tag;
            } else limit_ok = false;
        }
        // A signal ends the wait early: wait again. The timeout of the
        // limit is still in the ring.
        while (true) {
            const wait: u32 = if (r.canceled != null or !limit_ok) 0 else 1;
            _ = r.ring.submit_and_wait(wait) catch |e| switch (e) {
                error.SignalInterrupt => continue,
                // The completion queue has an overflow: read it first.
                error.CompletionQueueOvercommitted => 0,
                else => return e,
            };
            break;
        }
        var cqes: [64]linux.io_uring_cqe = undefined;
        var count: usize = 0;
        // The callbacks submit new operations, and a full submission
        // queue submits them at once, so CQEs can keep coming. One run
        // reads at most the size of the completion queue.
        var seen: usize = 0;
        while (seen < r.ring.cq.cqes.len) {
            const n = try r.ring.copy_cqes(&cqes, 0);
            if (n == 0) break;
            seen += n;
            for (cqes[0..n]) |cqe| switch (cqe.user_data) {
                ignore, limit_tag => {},
                wake_tag => try r.armWake(),
                else => {
                    const c: *Completion = @ptrFromInt(cqe.user_data);
                    // A timer that ran out ends with -ETIME.
                    const res = if (c.op == .timer and cqe.res == -@as(i32, @backingInt(linux.E.TIME))) 0 else cqe.res;
                    l.finish(c, res);
                    count += 1;
                },
            };
        }
        while (r.canceled) |c| {
            r.canceled = c.next;
            l.finish(c, -@as(i32, @backingInt(linux.E.CANCELED)));
            count += 1;
        }
        while (r.backlog) |c| {
            const s = (try r.sqe()) orelse break;
            prep(s, c);
            r.backlog = c.next;
            if (r.backlog == null) r.backlog_tail = null;
        }
        return count;
    }
};

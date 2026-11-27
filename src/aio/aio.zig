//! The completion API of `aio`: the I/O loop of one thread, for the
//! sockets, the timers, and the waits of the HTTP and TLS code.
//!
//! The caller fills a `Completion` with an operation and a callback, and
//! gives it to `Loop.submit`. The loop runs the callback once, from
//! `Loop.run`, when the operation ends. `result` is the count of bytes,
//! the new descriptor of an accept, or 0, and a negative errno for an
//! error. A canceled operation ends with `-ECANCELED`. The caller owns
//! each completion and each buffer until the callback runs. A callback
//! can submit new operations, also on the same completion.
//!
//! Each descriptor must be non-blocking. An accept gives a non-blocking
//! descriptor with close-on-exec.
//!
//! Backends (`Backend`):
//!
//! - `uring`: io_uring through `std.os.linux.IoUring` (`uring.zig`).
//! - `epoll`: readiness through epoll, then the system call
//!   (`epoll.zig`). The epoll backend allows one read side and one
//!   write side operation at a time on a descriptor.
//! - `auto`: `uring`, or `epoll` when the kernel refuses io_uring (an
//!   old kernel, a seccomp filter, or `kernel.io_uring_disabled`). On
//!   macOS: `kqueue`.
//! - `kqueue`: readiness through kqueue, then the system call
//!   (`kqueue.zig`, macOS). The same rule of one operation on each side.
//!
//! The loop has no interpreter, so the compute limit and the memory
//! limit of a script do not apply. Each buffer of the loop has a fixed
//! size: the ring has `entries` slots, and epoll reads `max_events`
//! events in each wait.
//!
//! Linux and macOS. IOCP (task 10) comes with the same API.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
pub const sys = @import("sys.zig");
pub const uring = @import("uring.zig");
pub const epoll = @import("epoll.zig");
pub const kqueue = @import("kqueue.zig");

pub const fd_t = sys.fd_t;

/// True on the systems with a backend.
pub const supported = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

pub const Op = union(enum) {
    /// Gives a new connection of the listening socket `fd`.
    accept: struct { fd: fd_t },
    /// Connects `fd` to `addr`. The caller keeps `addr` alive.
    connect: struct { fd: fd_t, addr: *const sys.sockaddr, len: sys.socklen_t },
    /// Reads up to `buf.len` bytes. 0 is the end of the stream.
    read: struct { fd: fd_t, buf: []u8 },
    /// Writes a part of `buf`, at least one byte.
    write: struct { fd: fd_t, buf: []const u8 },
    /// Ends after `ns` nanoseconds with the result 0.
    timer: struct { ns: u64 },
};

pub const Callback = *const fn (loop: *Loop, c: *Completion) void;

pub const Completion = struct {
    op: Op,
    callback: Callback,
    ctx: ?*anyopaque = null,
    result: i32 = 0,
    /// Set by the loop.
    state: enum { idle, pending } = .idle,
    /// The links and the fields of the backends.
    next: ?*Completion = null,
    deadline: u64 = 0,
    ts: if (sys.is_linux) linux.kernel_timespec else void = if (sys.is_linux) .{ .sec = 0, .nsec = 0 } else {},
};

pub const Backend = enum { auto, uring, epoll, kqueue };

pub const Options = struct {
    backend: Backend = .auto,
    /// The slots of the ring of io_uring.
    entries: u16 = 256,
};

pub const Loop = struct {
    impl: if (sys.is_linux) union(enum) { uring: uring.Ring, epoll: epoll.Poll } else union(enum) { kqueue: kqueue.Queue },
    /// The count of submitted operations whose callback has not run.
    pending: usize = 0,

    pub fn init(gpa: std.mem.Allocator, opts: Options) !Loop {
        if (!sys.is_linux) return switch (opts.backend) {
            .auto, .kqueue => .{ .impl = .{ .kqueue = try kqueue.Queue.init(gpa) } },
            .uring, .epoll => error.Unsupported,
        };
        switch (opts.backend) {
            .uring => return .{ .impl = .{ .uring = try uring.Ring.init(opts.entries) } },
            .epoll => return .{ .impl = .{ .epoll = try epoll.Poll.init(gpa) } },
            .kqueue => return error.Unsupported,
            .auto => {
                if (uring.Ring.init(opts.entries)) |r| return .{ .impl = .{ .uring = r } } else |_| {}
                return .{ .impl = .{ .epoll = try epoll.Poll.init(gpa) } };
            },
        }
    }

    pub fn deinit(l: *Loop) void {
        switch (l.impl) {
            inline else => |*b| b.deinit(),
        }
    }

    pub fn backend(l: *const Loop) Backend {
        return switch (l.impl) {
            inline else => |_, tag| @field(Backend, @tagName(tag)),
        };
    }

    pub fn submit(l: *Loop, c: *Completion) !void {
        std.debug.assert(c.state == .idle);
        c.state = .pending;
        c.next = null;
        switch (l.impl) {
            inline else => |*b| b.submit(c) catch |e| {
                c.state = .idle;
                return e;
            },
        }
        l.pending += 1;
    }

    /// Ends a pending operation with `-ECANCELED`. An operation that
    /// already ended keeps its result. The callback runs once in both
    /// cases.
    pub fn cancel(l: *Loop, c: *Completion) !void {
        if (c.state != .pending) return;
        switch (l.impl) {
            inline else => |*b| try b.cancel(c),
        }
    }

    /// Ends a wait of `run` from another thread.
    pub fn wake(l: *Loop) void {
        switch (l.impl) {
            inline else => |*b| b.wake(),
        }
    }

    /// Waits for at least one completion, a `wake`, or the end of
    /// `timeout_ns` (null waits with no end), and runs the callbacks.
    /// Gives the count of callbacks.
    pub fn run(l: *Loop, timeout_ns: ?u64) !usize {
        return switch (l.impl) {
            inline else => |*b| b.run(l, timeout_ns),
        };
    }

    /// Runs until no operation is pending.
    pub fn runAll(l: *Loop) !void {
        while (l.pending > 0) _ = try l.run(null);
    }

    /// Called by a backend for each ended operation.
    pub fn finish(l: *Loop, c: *Completion, res: i32) void {
        c.result = res;
        c.state = .idle;
        l.pending -= 1;
        c.callback(l, c);
    }
};

pub fn now() u64 {
    return sys.now();
}

/// The negative errno of a raw system call result, or the value.
pub fn result(rc: usize) i32 {
    const e = linux.errno(rc);
    if (e != .SUCCESS) return -@as(i32, @intCast(@backingInt(e)));
    return @intCast(@as(isize, @bitCast(rc)));
}

test {
    _ = @import("tests.zig");
}

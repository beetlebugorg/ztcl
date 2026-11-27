//! `exec -vm VM` and `open "|-vm VM ..."` (ztcl#577): the programs of a
//! pipeline run in one guest of `ztcl::vm`, through its agent
//! (`docs/dev/vm-agent.md`).
//!
//! The agent runs one program for each connection, so a pipeline of N
//! programs has N connections to port 1024 of the same guest. `start`
//! sends an `EXEC` on each and waits for `STARTED`. A bare program name
//! goes through the `PATH` of the guest: `start` tries each folder of
//! `PATH` in order, and an `ERROR` with ENOENT tries the next folder.
//!
//! Then `loop` relays the frames with one `poll`:
//!
//! - the `STDOUT` of program k goes to the `STDIN` of program k + 1, and
//!   the `STDOUT` of the last program goes to the output target;
//! - the `STDERR` of each program goes to the error target, or to the
//!   `STDIN` of the next program after `|&`;
//! - the bytes of the input target go to the `STDIN` of the first
//!   program.
//!
//! A target is a host descriptor that `proc.zig` opened (a redirection,
//! under the file policy of the interpreter, or a channel), or a buffer
//! of this file. So a program in the guest reads and writes only the
//! bytes that the host copies. It gets no path of the host.
//!
//! The `EXIT` of program k closes the `STDIN` of program k + 1. An
//! `EXIT` of program k + 1 before program k ends sends `SIGNAL` 13
//! (SIGPIPE) to program k, as a pipe of the host does. Each write to a
//! connection goes in a queue and leaves when `poll` says the socket can
//! take it. A program does not get more output for the next program
//! while the queue of the next program has more than 256 KiB, so a slow
//! reader slows the writer and the host keeps a bounded copy.
//!
//! A kill (the time limit, `close` of a channel that does not wait, the
//! end of the interpreter) closes each connection. The agent kills the
//! program of a connection that closes (`SIGKILL`).
//!
//! `exec` runs `loop` on the thread of the interpreter. `exec ... &` and
//! `open "|..."` run it on a thread of their own, and the wait of
//! `close` or of the sweep of `proc.zig` joins that thread.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const proc = @import("proc.zig");
const vmagent = @import("vmagent.zig");
const sys = @import("sys.zig");
const linux = sys.os;
const Interp = interp.Interp;
const Error = interp.Error;
const pa = std.heap.page_allocator;

/// The `PATH` of the guest when the script gives no `PATH=` in `-env`.
pub const default_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

const t_signal = 0x24;
/// The most bytes that a buffer target keeps before the kill.
const max_capture = 64 << 20;
/// The queue of one connection above which its source waits.
const high_water = 256 << 10;
/// The most bytes of one `STDIN` frame.
const chunk = 65536;

/// The connection of one program.
const Link = struct {
    fd: i32,
    pid: i32 = 0,
    /// The bytes read and not yet parsed.
    rbuf: std.ArrayList(u8) = .empty,
    /// The frames that wait for the socket.
    wbuf: std.ArrayList(u8) = .empty,
    wpos: usize = 0,
    /// True when the program has an input to close.
    stdin_open: bool,
    exited: bool = false,
    code: i32 = 0,
    /// True when the connection closed.
    gone: bool = false,
    /// True when the error output goes to the next program (`|&`).
    err_too: bool = false,

    fn queued(l: *const Link) usize {
        return l.wbuf.items.len - l.wpos;
    }

    fn put(l: *Link, kind: u8, payload: []const u8) void {
        if (l.gone or l.exited) return;
        var head: [5]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], @intCast(payload.len + 1), .little);
        head[4] = kind;
        l.wbuf.appendSlice(pa, &head) catch return;
        l.wbuf.appendSlice(pa, payload) catch return;
    }

    /// Sends `STDIN` bytes, in frames of at most 64 KiB.
    fn stdin(l: *Link, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = @min(chunk, bytes.len - off);
            l.put(vmagent.t_stdin, bytes[off..][0..n]);
            off += n;
        }
    }

    fn closeStdin(l: *Link) void {
        if (!l.stdin_open) return;
        l.stdin_open = false;
        l.put(vmagent.t_stdin, "");
    }

    fn drop(l: *Link) void {
        if (l.fd >= 0) _ = linux.close(l.fd);
        l.fd = -1;
        l.gone = true;
        if (!l.exited) {
            l.exited = true;
            l.code = -9;
        }
    }
};

const Sink = struct {
    fd: i32 = -1,
    buf: std.ArrayList(u8) = .empty,

    fn write(s: *Sink, j: *Job, bytes: []const u8) void {
        if (s.fd >= 0) {
            var off: usize = 0;
            while (off < bytes.len) {
                switch (sys.write(s.fd, bytes[off..])) {
                    .n => |n| off += n,
                    .again => {
                        var w = [1]linux.pollfd{.{ .fd = s.fd, .events = linux.POLL.OUT, .revents = 0 }};
                        _ = linux.poll(&w, 1, 100);
                    },
                    .err => {
                        // The reader went away: drop the rest, and the
                        // last program gets SIGPIPE.
                        _ = linux.close(s.fd);
                        s.fd = -2;
                        j.broken = true;
                        return;
                    },
                }
            }
            return;
        }
        if (s.fd == -2) return;
        if (s.buf.items.len + bytes.len > max_capture) {
            j.kill_now = true;
            return;
        }
        s.buf.appendSlice(pa, bytes) catch {
            j.kill_now = true;
        };
    }
};

pub const Job = struct {
    links: []Link,
    pids: []i32,
    in_fd: i32 = -1,
    out: Sink = .{},
    err: Sink = .{},
    err_to_out: bool = false,
    deadline: ?i64 = null,
    /// The read end of the pipe that `kill` writes, to wake the loop.
    wake_r: i32 = -1,
    wake_w: i32 = -1,
    kill_now: bool = false,
    /// True when the reader of the output went away.
    broken: bool = false,
    timed_out: bool = false,
    thread: ?std.Thread = null,
    ran: bool = false,
    done: std.atomic.Value(bool) = .init(false),
    end: proc.End = .{},
    timeout_ms: u32 = 0,
    fresh: ?Fresh = null,

    fn errSink(j: *Job) *Sink {
        return if (j.err_to_out) &j.out else &j.err;
    }

    fn runLoop(j: *Job) void {
        loop(j);
        const codes: []i32 = pa.alloc(i32, j.links.len) catch @constCast(&[0]i32{});
        for (j.links, 0..) |*l, k| {
            if (k < codes.len) codes[k] = l.code;
            l.drop();
            l.rbuf.deinit(pa);
            l.wbuf.deinit(pa);
        }
        for ([_]*Sink{ &j.out, &j.err }) |s| {
            if (s.fd >= 0) _ = linux.close(s.fd);
        }
        if (j.in_fd >= 0) _ = linux.close(j.in_fd);
        j.in_fd = -1;
        j.end = .{ .codes = codes, .pids = j.pids, .out = j.out.buf.items, .err = j.err.buf.items, .timed_out = j.timed_out, .timeout_ms = j.timeout_ms };
        j.ran = true;
        j.done.store(true, .release);
    }

    fn threadMain(j: *Job) void {
        j.runLoop();
    }
};

fn setNonblock(fd: i32) void {
    const fl = linux.fcntl(fd, linux.F.GETFL, 0);
    const nb: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, linux.F.SETFL, fl | nb);
}

fn nowMs() i64 {
    return proc.nowMs();
}

/// Parses each whole frame of `links[k].rbuf` and relays it.
fn takeFrames(j: *Job, k: usize) void {
    const l = &j.links[k];
    var pos: usize = 0;
    const b = l.rbuf.items;
    while (b.len - pos >= 5) {
        const len = std.mem.readInt(u32, b[pos..][0..4], .little);
        if (len == 0 or len > vmagent.max_payload + 1) {
            l.drop();
            return;
        }
        if (b.len - pos < 4 + len) break;
        const kind = b[pos + 4];
        const p = b[pos + 5 .. pos + 4 + len];
        pos += 4 + len;
        const next: ?*Link = if (k + 1 < j.links.len) &j.links[k + 1] else null;
        switch (kind) {
            vmagent.t_stdout => if (next) |n| n.stdin(p) else j.out.write(j, p),
            vmagent.t_stderr => if (next != null and l.err_too) next.?.stdin(p) else j.errSink().write(j, p),
            vmagent.t_exit => if (p.len >= 4) {
                l.exited = true;
                l.code = std.mem.readInt(i32, p[0..4], .little);
                if (next) |n| n.closeStdin();
            },
            else => {},
        }
    }
    std.mem.copyForwards(u8, l.rbuf.items[0 .. b.len - pos], b[pos..]);
    l.rbuf.shrinkRetainingCapacity(b.len - pos);
}

fn killAll(j: *Job) void {
    for (j.links) |*l| if (!l.exited) l.drop();
}

/// Relays the frames of the pipeline until each program ended.
fn loop(j: *Job) void {
    const n = j.links.len;
    var fds: [64 + 2]linux.pollfd = undefined;
    var buf: [chunk]u8 = undefined;
    while (true) {
        if (j.kill_now) killAll(j);
        if (j.broken) {
            j.broken = false;
            j.links[n - 1].put(t_signal, &[1]u8{13});
        }
        // The end: each program ended and each queue is empty.
        var all = true;
        for (j.links) |*l| {
            if (!l.exited) all = false;
            if (!l.gone and l.queued() > 0) all = false;
        }
        if (all) return;
        var count: usize = 0;
        for (j.links, 0..) |*l, k| {
            var ev: i16 = 0;
            if (!l.gone) {
                // The source of a full queue waits.
                const full = k + 1 < n and j.links[k + 1].queued() > high_water;
                if (!full) ev |= linux.POLL.IN;
                if (l.queued() > 0) ev |= linux.POLL.OUT;
            }
            fds[k] = .{ .fd = if (ev != 0) l.fd else -1, .events = ev, .revents = 0 };
        }
        count = n;
        const in_ix = count;
        const first = &j.links[0];
        const want_in = j.in_fd >= 0 and !first.gone and !first.exited and first.queued() <= high_water;
        fds[count] = .{ .fd = if (want_in) j.in_fd else -1, .events = linux.POLL.IN, .revents = 0 };
        count += 1;
        const wake_ix = count;
        fds[count] = .{ .fd = j.wake_r, .events = linux.POLL.IN, .revents = 0 };
        count += 1;
        var wait_ms: i32 = -1;
        if (j.deadline) |d| {
            const left = d - nowMs();
            if (left <= 0) {
                j.timed_out = true;
                killAll(j);
                continue;
            }
            wait_ms = @intCast(@min(left, 1000));
        }
        const rc = linux.poll(&fds, count, wait_ms);
        if (linux.errno(rc) != .SUCCESS) continue;
        if (fds[wake_ix].revents != 0) {
            killAll(j);
            continue;
        }
        if (fds[in_ix].revents != 0) {
            switch (sys.read(j.in_fd, &buf)) {
                .n => |m| if (m == 0) {
                    _ = linux.close(j.in_fd);
                    j.in_fd = -1;
                    first.closeStdin();
                } else first.stdin(buf[0..m]),
                .again => {},
                .err => {
                    _ = linux.close(j.in_fd);
                    j.in_fd = -1;
                    first.closeStdin();
                },
            }
        }
        for (j.links, 0..) |*l, k| {
            const re = fds[k].revents;
            if (re == 0 or l.gone) continue;
            if (re & linux.POLL.OUT != 0) {
                switch (sys.write(l.fd, l.wbuf.items[l.wpos..])) {
                    .n => |m| {
                        l.wpos += m;
                        if (l.wpos == l.wbuf.items.len) {
                            l.wbuf.clearRetainingCapacity();
                            l.wpos = 0;
                        }
                    },
                    .again => {},
                    .err => l.drop(),
                }
            }
            if (l.gone) continue;
            if (re & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) {
                switch (sys.read(l.fd, &buf)) {
                    .n => |m| if (m == 0) {
                        const was = l.exited;
                        l.gone = true;
                        _ = linux.close(l.fd);
                        l.fd = -1;
                        if (!was) {
                            l.exited = true;
                            l.code = -9;
                        }
                    } else {
                        l.rbuf.appendSlice(pa, buf[0..m]) catch l.drop();
                        takeFrames(j, k);
                    },
                    .again => {},
                    .err => l.drop(),
                }
            }
            // A reader that ended before its writer: SIGPIPE to the writer.
            if (l.exited and k > 0) {
                const prev = &j.links[k - 1];
                if (!prev.exited and !prev.gone) {
                    prev.put(t_signal, &[1]u8{13});
                }
            }
        }
        // After an EXIT the queue to that program is useless.
        for (j.links) |*l| if (l.exited and !l.gone and l.queued() > 0) {
            l.wbuf.clearRetainingCapacity();
            l.wpos = 0;
        };
    }
}

/// Reads one frame of a link that is still starting, with a time limit.
fn readStart(l: *Link, timeout_ms: u32) ?struct { kind: u8, payload: []const u8, size: usize } {
    const until = nowMs() + timeout_ms;
    while (true) {
        const b = l.rbuf.items;
        if (b.len >= 5) {
            const len = std.mem.readInt(u32, b[0..4], .little);
            if (len == 0 or len > vmagent.max_payload + 1) return null;
            if (b.len >= 4 + len) return .{ .kind = b[4], .payload = b[5 .. 4 + len], .size = 4 + len };
        }
        const left = until - nowMs();
        if (left <= 0) return null;
        var w = [1]linux.pollfd{.{ .fd = l.fd, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&w, 1, @intCast(@min(left, 1000)));
        if (w[0].revents == 0) continue;
        var buf: [4096]u8 = undefined;
        switch (sys.read(l.fd, &buf)) {
            .n => |m| {
                if (m == 0) return null;
                l.rbuf.appendSlice(pa, buf[0..m]) catch return null;
            },
            .again => {},
            .err => return null,
        }
    }
}

fn putStr(l: *std.ArrayList(u8), s: []const u8) !void {
    try l.appendSlice(pa, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(s.len))));
    try l.appendSlice(pa, s);
}

fn putList(l: *std.ArrayList(u8), items: []const []const u8) !void {
    try l.appendSlice(pa, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(items.len))));
    for (items) |s| try putStr(l, s);
}

/// The connector of a guest: a connection to the agent after `HELLO`.
pub const Connect = *const fn (it: *Interp, vm: []const u8, timeout_ms: u32) Error!vmagent.Conn;

/// Starts one program: tries each folder of `PATH` for a bare name.
fn startOne(it: *Interp, connect: Connect, vm: []const u8, r: *const proc.Remote, s: proc.Stage, stdin_open: bool, timeout_ms: u32) Error!Link {
    const a = it.alloc();
    const word = s.argv[0];
    var path_v: []const u8 = default_path;
    for (r.env) |e| if (std.mem.startsWith(u8, e, "PATH=")) {
        path_v = e[5..];
    };
    var tries: std.ArrayList([]const u8) = .empty;
    if (std.mem.indexOfScalar(u8, word, '/') != null) {
        try tries.append(a, word);
    } else {
        var dirs = std.mem.tokenizeScalar(u8, path_v, ':');
        while (dirs.next()) |d| try tries.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ d, word }));
    }
    var env = r.env;
    var has_path = false;
    for (r.env) |e| if (std.mem.startsWith(u8, e, "PATH=")) {
        has_path = true;
    };
    if (!has_path) {
        const e2 = try a.alloc([]const u8, r.env.len + 1);
        @memcpy(e2[0..r.env.len], r.env);
        e2[r.env.len] = "PATH=" ++ default_path;
        env = e2;
    }
    var last_errno: u32 = 2;
    for (tries.items) |prog| {
        var c = try connect(it, vm, timeout_ms);
        var l: Link = .{ .fd = c.fd, .stdin_open = stdin_open, .err_too = s.err_too };
        // The bytes that the read of `HELLO` took ahead.
        l.rbuf.appendSlice(pa, c.rbuf[c.rpos..c.rend]) catch {};
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(pa);
        const argv = try a.dupe([]const u8, s.argv);
        argv[0] = prog;
        putList(&req, argv) catch return error.OutOfMemory;
        putList(&req, env) catch return error.OutOfMemory;
        putStr(&req, r.cwd) catch return error.OutOfMemory;
        req.append(pa, if (stdin_open) 1 else 0) catch return error.OutOfMemory;
        c.send(vmagent.t_exec, req.items) catch {
            l.drop();
            return it.failCode("ZTCL VM AGENT", "the connection to the agent of the guest {s} failed", .{vm});
        };
        const f = readStart(&l, timeout_ms) orelse {
            l.drop();
            l.rbuf.deinit(pa);
            return it.failCode("ZTCL VM TIMEOUT", "the guest {s} gave no answer in time", .{vm});
        };
        if (f.kind == vmagent.t_started and f.payload.len >= 4) {
            l.pid = @intCast(std.mem.readInt(u32, f.payload[0..4], .little));
            const size = f.size;
            const rest = l.rbuf.items.len - size;
            std.mem.copyForwards(u8, l.rbuf.items[0..rest], l.rbuf.items[size..]);
            l.rbuf.shrinkRetainingCapacity(rest);
            setNonblock(l.fd);
            return l;
        }
        if (f.kind == vmagent.t_error and f.payload.len >= 8) {
            last_errno = std.mem.readInt(u32, f.payload[0..4], .little);
        }
        l.drop();
        l.rbuf.deinit(pa);
        if (last_errno != 2) break;
    }
    const e: linux.E = @fromBackingInt(@intCast(@as(u16, @intCast(@min(last_errno, 4095)))));
    return proc.cannotRun(it, word, e);
}

/// Starts the programs of `r` in the guest `vm` and gives the job. Each
/// error before the last `STARTED` is a Tcl error, and the programs that
/// started end.
/// A guest of `-isolation vm`: the free of the job deletes it, on the
/// thread of the interpreter.
pub const Fresh = struct {
    it: *Interp,
    /// The name of the guest, in the page allocator.
    name: []u8,
    drop: *const fn (it: *Interp, name: []const u8) void,
};

pub fn start(it: *Interp, connect: Connect, vm: []const u8, r: *const proc.Remote) Error!proc.Job {
    return startFresh(it, connect, vm, r, null);
}

/// As `start`, and the job owns the guest `fresh`.
pub fn startFresh(it: *Interp, connect: Connect, vm: []const u8, r: *const proc.Remote, fresh: ?Fresh) Error!proc.Job {
    const n = r.stages.len;
    if (n > 64) return it.fail("too many programs in one pipeline of a guest", .{});
    const j = try pa.create(Job);
    j.* = .{ .links = try pa.alloc(Link, n), .pids = try pa.alloc(i32, n), .err_to_out = r.err_to_out, .timeout_ms = r.timeout_ms, .fresh = fresh };
    var made: usize = 0;
    errdefer {
        for (j.links[0..made]) |*l| {
            l.drop();
            l.rbuf.deinit(pa);
        }
        pa.free(j.links);
        pa.free(j.pids);
        pa.destroy(j);
    }
    const t: u32 = if (r.timeout_ms == 0) 30000 else @min(r.timeout_ms, 30000);
    for (r.stages, 0..) |s, k| {
        const prev_err = k > 0 and r.stages[k - 1].err_too;
        const stdin_open = k > 0 or r.in_fd >= 0 or prev_err;
        j.links[k] = try startOne(it, connect, vm, r, s, stdin_open, t);
        j.pids[k] = j.links[k].pid;
        made = k + 1;
    }
    j.in_fd = try dupFd(it, r.in_fd);
    j.out.fd = try dupFd(it, r.out_fd);
    j.err.fd = if (r.err_to_out) -1 else try dupFd(it, r.err_fd);
    var p: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&p, .{ .CLOEXEC = true })) != .SUCCESS) return it.fail("couldn't create pipe", .{});
    j.wake_r = p[0];
    j.wake_w = p[1];
    if (r.timeout_ms > 0) j.deadline = proc.nowMs() + r.timeout_ms;
    // Data of the first frames after STARTED.
    for (0..n) |k| takeFrames(j, k);
    return .{ .ctx = j, .pids = j.pids, .vt = &vtable };
}

fn dupFd(it: *Interp, fd: i32) Error!i32 {
    if (fd < 0) return -1;
    const rc = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 3);
    if (linux.errno(rc) != .SUCCESS) return it.fail("couldn't duplicate a descriptor", .{});
    return @intCast(rc);
}

const vtable: proc.Job.VTable = .{ .detach = detach, .wait = wait, .kill = kill, .done = isDone, .free = free };

fn job(ctx: *anyopaque) *Job {
    return @ptrCast(@alignCast(ctx));
}

fn detach(ctx: *anyopaque) bool {
    const j = job(ctx);
    j.thread = std.Thread.spawn(.{ .stack_size = 256 << 10 }, Job.threadMain, .{j}) catch return false;
    return true;
}

fn wait(ctx: *anyopaque) *const proc.End {
    const j = job(ctx);
    if (j.thread) |t| {
        t.join();
        j.thread = null;
    } else if (!j.ran) j.runLoop();
    return &j.end;
}

fn kill(ctx: *anyopaque) void {
    const j = job(ctx);
    if (j.thread != null) {
        _ = linux.write(j.wake_w, "k", 1);
    } else j.kill_now = true;
}

fn isDone(ctx: *anyopaque) bool {
    return job(ctx).done.load(.acquire);
}

fn free(ctx: *anyopaque) void {
    const j = job(ctx);
    _ = wait(ctx);
    _ = linux.close(j.wake_r);
    _ = linux.close(j.wake_w);
    j.out.buf.deinit(pa);
    j.err.buf.deinit(pa);
    pa.free(j.end.codes);
    if (j.fresh) |f| {
        f.drop(f.it, f.name);
        pa.free(f.name);
    }
    pa.free(j.links);
    pa.free(j.pids);
    pa.destroy(j);
}

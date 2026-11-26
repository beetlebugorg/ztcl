//! Isolated threads (ztcl#209), step 3 of `docs/dev/isolation.md`: the
//! proxy worker in the parent and the child process, on the frames of
//! `isoproto.zig`.
//!
//! In the parent, an isolated thread is a worker of the group with no
//! interpreter. Its OS thread (`bridgeMain`) starts the child process,
//! makes the handshake, sends `START`, and waits for `READY`. Then it
//! forwards the messages of the queue of the worker to the child, and a
//! reader thread turns the frames of the child into messages of the
//! group. So a send, a wait, an error, and a join see a normal worker.
//!
//! In the child (`childMain`), the runtime makes an interpreter with a
//! group of one thread. Its worker acts as a thread, with the id that
//! the parent gave it, and the remote of the group sends each message
//! for another id to the parent.
//!
//! The payloads, after the header of the frame (strings are a 4-byte
//! length and the bytes, numbers are little-endian, and a value is the
//! byte form of `isoproto.zig` over the shared form of `thread.zig`):
//!
//!   START   id u64, caps u32, compute u64, memory u64, hosts u8, script
//!   SEND    from u64, to u64, flags u8 (1 reply, 2 head), var name, script
//!   RESULT  kind u8 (0 reply, 1 async result), to u64, code i64, value,
//!           error info, error code value, var name
//!   CANCEL  bits u32 (thread.Flag), text
//!   OUTPUT  bytes;  BGERROR  error info;  EXIT  status i64
//!
//! A `SEND` with the flag `reply` has its stream id as the number of the
//! send, and its `RESULT` comes on the same stream.
//!
//! Not in this step: `tsv`, the mutexes, and the conditions (the broker
//! of the plan), `thread::transfer`, a thread that an isolated thread
//! creates, and the sandbox of each platform. A script of the child that
//! uses them gets an error.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const thread = @import("thread.zig");
const iso = @import("isoproto.zig");
const Interp = interp.Interp;
const Error = interp.Error;
const Worker = thread.Worker;
const Group = thread.Group;
const Msg = thread.Msg;
const Shared = thread.Shared;
const Allocator = std.mem.Allocator;
const on_win = builtin.os.tag == .windows;

pub const supported = thread.supported and !thread.web and (builtin.os.tag == .linux or builtin.os.tag == .macos);
/// The platforms where the bridge starts the runner itself. The Linux
/// and Windows sandboxes (`isolate_*.zig`) bring their own start.
pub const spawns_runner = builtin.os.tag == .macos;

/// The hook of a test or an embedder: starts a child and gives the
/// parent end of its transport.
pub const Spawner = struct {
    ctx: ?*anyopaque = null,
    spawn: *const fn (ctx: ?*anyopaque) ?i32,
};

const flag_reply: u8 = 1;
const flag_head: u8 = 2;
const hosts_clock: u8 = 1;
const hosts_event: u8 = 2;

// ---- Payloads ----

const Out = struct {
    a: Allocator,
    list: std.ArrayList(u8) = .empty,

    fn int(o: *Out, comptime T: type, v: T) !void {
        try o.list.appendSlice(o.a, &std.mem.toBytes(std.mem.nativeToLittle(T, v)));
    }
    fn str(o: *Out, s: []const u8) !void {
        try o.int(u32, @intCast(s.len));
        try o.list.appendSlice(o.a, s);
    }
    fn shared(o: *Out, s: Shared, depth: u32) !void {
        switch (s) {
            .int => |i| {
                try o.list.append(o.a, 'i');
                try o.int(i64, i);
            },
            .double => |d| {
                try o.list.append(o.a, 'd');
                try o.int(u64, @bitCast(d));
            },
            .str => |t| {
                try o.list.append(o.a, 's');
                try o.str(t);
            },
            .list => |l| {
                // `share` already made a deep list its string form.
                try o.list.append(o.a, 'l');
                try o.int(u32, @intCast(l.items.len));
                for (l.items) |x| try o.shared(x, depth + 1);
            },
        }
    }
    fn deinit(o: *Out) void {
        o.list.deinit(o.a);
    }
};

fn readStr(r: *iso.Reader) iso.Error![]const u8 {
    return r.take(try r.int(u32));
}

/// Reads a value of the byte form as a shared tree in `a`.
fn readShared(a: Allocator, r: *iso.Reader, depth: u32) iso.Error!Shared {
    if (depth > iso.max_depth) return error.Protocol;
    switch ((try r.take(1))[0]) {
        'i' => return .{ .int = try r.int(i64) },
        'd' => return .{ .double = @bitCast(try r.int(u64)) },
        's' => return .{ .str = try a.dupe(u8, try readStr(r)) },
        'l' => {
            const n = try r.int(u32);
            if (n > r.b.len - r.i) return error.Protocol;
            var l: std.ArrayList(Shared) = try .initCapacity(a, n);
            errdefer {
                var s: Shared = .{ .list = l };
                s.deinit(a);
            }
            for (0..n) |_| l.appendAssumeCapacity(try readShared(a, r, depth + 1));
            return .{ .list = l };
        },
        else => return error.Protocol,
    }
}

/// The payload of a `RESULT` for the message `m` (a reply or an async
/// result) to the thread `to`.
fn resultPayload(a: Allocator, to: u64, m: *const Msg) ![]u8 {
    var o: Out = .{ .a = a };
    errdefer o.deinit();
    try o.list.append(a, if (m.kind == .reply) 0 else 1);
    try o.int(u64, to);
    try o.int(i64, m.code);
    try o.shared(m.res, 0);
    try o.str(m.info);
    try o.shared(m.ecode, 0);
    try o.str(if (m.kind == .var_result) m.text else "");
    return o.list.toOwnedSlice(a);
}

const Result = struct { to: u64, msg: *Msg };

/// A message of the group from a `RESULT` payload. The stream of the
/// frame is the number of a reply.
fn readResult(g: *Group, stream: u32, payload: []const u8) iso.Error!Result {
    const a = g.alloc();
    var r: iso.Reader = .{ .b = payload };
    const kind = (try r.take(1))[0];
    if (kind > 1) return error.Protocol;
    const to = try r.int(u64);
    const m = try a.create(Msg);
    m.* = .{ .kind = if (kind == 0) .reply else .var_result, .seq = if (kind == 0) stream else 0 };
    errdefer m.destroy(a);
    m.code = try r.int(i64);
    m.res = try readShared(a, &r, 0);
    m.info = try a.dupe(u8, try readStr(&r));
    m.ecode = try readShared(a, &r, 0);
    m.text = try a.dupe(u8, try readStr(&r));
    try r.done();
    return .{ .to = to, .msg = m };
}

fn sendPayload(a: Allocator, from: u64, to: u64, flags: u8, var_name: []const u8, script: []const u8) ![]u8 {
    var o: Out = .{ .a = a };
    errdefer o.deinit();
    try o.int(u64, from);
    try o.int(u64, to);
    try o.list.append(a, flags);
    try o.str(var_name);
    try o.str(script);
    return o.list.toOwnedSlice(a);
}

const SendIn = struct { from: u64, to: u64, flags: u8, var_name: []const u8, script: []const u8 };

fn readSend(payload: []const u8) iso.Error!SendIn {
    var r: iso.Reader = .{ .b = payload };
    const s: SendIn = .{
        .from = try r.int(u64),
        .to = try r.int(u64),
        .flags = (try r.take(1))[0],
        .var_name = try readStr(&r),
        .script = try readStr(&r),
    };
    try r.done();
    return s;
}

/// One end of a connection with a lock for the writers.
const Link = struct {
    t: iso.Transport,
    conn: iso.Conn = undefined,
    wlock: thread.Lock = .{},

    fn write(l: *Link, a: Allocator, kind: iso.Kind, stream: u32, payload: []const u8) bool {
        l.wlock.lock();
        defer l.wlock.unlock();
        l.conn.writeMessage(a, kind, stream, payload) catch return false;
        return true;
    }
};

/// Reads a whole message: the frames of one stream with the flag `more`
/// make one payload. A frame of another stream between them is an
/// error of the protocol in this version.
fn readMessage(l: *Link, a: Allocator) iso.Error!iso.Frame {
    var f = try l.conn.readFrame(a);
    if (f.flags & iso.flag_more == 0) return f;
    var all: std.ArrayList(u8) = .fromOwnedSlice(f.payload);
    errdefer all.deinit(a);
    while (true) {
        const next = try l.conn.readFrame(a);
        defer a.free(next.payload);
        if (next.kind != f.kind or next.stream != f.stream) return error.Protocol;
        if (all.items.len + next.payload.len > 1 << 30) return error.Protocol;
        try all.appendSlice(a, next.payload);
        if (next.flags & iso.flag_more == 0) break;
    }
    f.payload = try all.toOwnedSlice(a);
    return f;
}

// ---- The parent ----

const Pending = struct { from: u64, seq: u64 };

pub const Bridge = struct {
    gpa: Allocator,
    w: *Worker,
    runner: ?[]const u8,
    spawner: ?Spawner,
    hosts: u8,
    caps: u32,
    link: Link = undefined,
    pid: i32 = -1,
    /// The error of a failed start, for `startError`.
    err: []const u8 = "",
    err_code: []const u8 = "ZTCL ISOLATION START",
    plock: thread.Lock = .{},
    pending: std.AutoHashMapUnmanaged(u32, Pending) = .empty,
    next_stream: u32 = 2,
    ended: std.atomic.Value(bool) = .init(false),
    status: i64 = 0,
    exited: bool = false,
};

fn rootOf(it: *Interp) *Interp {
    var root = it;
    while (root.parent) |p| root = p;
    return root;
}

/// Makes the bridge of a new isolated thread. The caller holds the
/// group lock, so this only allocates.
pub fn prepare(it: *Interp, w: *Worker, st: anytype) Error!*Bridge {
    if (comptime !supported) return it.failCode("ZTCL ISOLATION LEVEL", "the level process is not available on this platform yet", .{});
    const root = rootOf(it);
    if (root.iso_spawn == null and !spawns_runner)
        return it.failCode("ZTCL ISOLATION LEVEL", "the level process is not available on this platform yet", .{});
    if (root.iso_runner == null and root.iso_spawn == null)
        return it.failCode("ZTCL ISOLATION RUNNER", "the embedder gives no runner for isolated threads", .{});
    const g = w.group;
    const b = try g.gpa.create(Bridge);
    b.* = .{
        .gpa = g.gpa,
        .w = w,
        .runner = root.iso_runner,
        .spawner = root.iso_spawn,
        .hosts = (if (st.clock_host != null) hosts_clock else 0) | (if (st.event_host != null) hosts_event else 0),
        .caps = st.caps,
    };
    return b;
}

pub fn unprepare(b: *Bridge) void {
    b.gpa.destroy(b);
}

/// The error of a failed start. It frees the bridge.
pub fn startError(it: *Interp, b: *Bridge) Error {
    defer unprepare(b);
    return it.failCode(b.err_code, "{s}", .{b.err});
}

fn spawnChild(b: *Bridge) ?i32 {
    if (b.spawner) |s| return s.spawn(s.ctx);
    const runner = b.runner orelse return null;
    return spawnRunner(b, runner);
}

/// Starts `runner --iso-fd 3` with one end of a socket pair as its
/// descriptor 3. Gives the other end.
fn spawnRunner(b: *Bridge, runner: []const u8) ?i32 {
    if (comptime !spawns_runner) return null;
    const c = std.c;
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return null;
    _ = c.fcntl(fds[0], c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return null;
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    _ = c.posix_spawn_file_actions_adddup2(&actions, fds[1], 3);
    const path = b.gpa.dupeSentinel(u8, runner, 0) catch return null;
    defer b.gpa.free(path);
    const argv = [_:null]?[*:0]const u8{ path.ptr, "--iso-fd", "3" };
    var pid: c.pid_t = 0;
    const rc = c.posix_spawn(&pid, path.ptr, &actions, null, @ptrCast(&argv), @ptrCast(c.environ));
    _ = c.close(fds[1]);
    if (rc != 0) {
        _ = c.close(fds[0]);
        return null;
    }
    b.pid = pid;
    return fds[0];
}

fn killChild(b: *Bridge) void {
    if (comptime !spawns_runner) return;
    if (b.pid > 0) _ = std.c.kill(b.pid, std.c.SIG.KILL);
}

/// Waits up to `ms` for the child to end.
fn reapChild(b: *Bridge, ms: u32) bool {
    if (comptime !spawns_runner) return true;
    if (b.pid <= 0) return true;
    var waited: u32 = 0;
    while (true) : (waited += 10) {
        var status: c_int = 0;
        const r = std.c.waitpid(b.pid, &status, std.c.W.NOHANG);
        if (r == b.pid or r < 0) {
            b.pid = -1;
            return true;
        }
        if (waited >= ms) return false;
        std.Io.sleep(threadIo(), .fromMilliseconds(10), .awake) catch {};
    }
}

fn threadIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn failBridge(w: *Worker, b: *Bridge, st: anytype, text: []const u8) void {
    b.err = text;
    killChild(b);
    _ = reapChild(b, 2000);
    thread.failStart(w, st);
}

/// The OS thread of an isolated thread in the parent.
pub fn bridgeMain(w: *Worker, b: *Bridge, st: anytype) void {
    const g = w.group;
    const a = b.gpa;
    const fd = spawnChild(b) orelse return failBridge(w, b, st, "the system could not start the child process");
    b.link = .{ .t = iso.Transport.init(fd) catch {
        _ = @import("sys.zig").os.close(fd);
        return failBridge(w, b, st, "no transport for the child process");
    } };
    b.link.conn = iso.Conn.init(&b.link.t);
    const wel = iso.parentHandshake(&b.link.conn, a, null, &.{"thread"}, false) catch {
        b.link.t.deinit();
        return failBridge(w, b, st, "the handshake with the child process failed");
    };
    a.free(wel.service);
    if (!sendStart(b, st)) {
        b.link.t.deinit();
        return failBridge(w, b, st, "the child process did not take the start");
    }
    const ready = readMessage(&b.link, a) catch {
        b.link.t.deinit();
        return failBridge(w, b, st, "the child process ended before its interpreter was ready");
    };
    a.free(ready.payload);
    if (ready.kind != .ready) {
        b.link.t.deinit();
        return failBridge(w, b, st, "the child process could not start its interpreter");
    }
    if (st.fs_fd >= 0) thread.closeFd(st.fs_fd);

    g.lock.lock();
    w.bridge = b;
    w.state = .running;
    g.lock.unlock();
    g.ev.signal();

    const reader = std.Thread.spawn(.{}, readerMain, .{b}) catch {
        b.ended.store(true, .release);
        return endBridge(w, b, null);
    };
    forward(w, b);
    endBridge(w, b, reader);
}

fn sendStart(b: *Bridge, st: anytype) bool {
    const a = b.gpa;
    var o: Out = .{ .a = a };
    defer o.deinit();
    o.int(u64, b.w.id) catch return false;
    o.int(u32, st.caps) catch return false;
    o.int(u64, st.compute_limit) catch return false;
    o.int(u64, st.mem_limit) catch return false;
    o.list.append(a, b.hosts) catch return false;
    o.str(b.w.script) catch return false;
    return b.link.write(a, .start, 0, o.list.items);
}

/// Forwards the queue of the worker to the child until the child ends.
fn forward(w: *Worker, b: *Bridge) void {
    const g = w.group;
    const a = b.gpa;
    var released_sent = false;
    var stop_at: ?i96 = null;
    while (!b.ended.load(.acquire)) {
        w.lock.lock();
        while (w.queue.items.len == 0 and w.flags.load(.acquire) == 0 and !(w.isReleased() and !released_sent) and !b.ended.load(.acquire)) {
            w.ev.wait(&w.lock, thread.slice_ns);
            if (stop_at) |t| if (thread.nowNs() >= t) break;
        }
        const items = w.queue.toOwnedSlice(g.alloc()) catch &.{};
        const flags = w.flags.fetchAnd(thread.Flag.stop, .acq_rel);
        const text = w.cancel_text;
        w.cancel_text = null;
        w.lock.unlock();
        defer g.alloc().free(items);
        if (items.len > 0) g.space_ev.signal();
        for (items) |m| {
            forwardMsg(b, m);
            m.destroy(g.alloc());
        }
        if (flags != 0) {
            var o: Out = .{ .a = a };
            defer o.deinit();
            o.int(u32, flags) catch {};
            o.str(text orelse "") catch {};
            _ = b.link.write(a, .cancel, 0, o.list.items);
            if (flags & thread.Flag.stop != 0 and stop_at == null) stop_at = thread.nowNs() + 2 * std.time.ns_per_s;
        }
        if (text) |t| g.alloc().free(t);
        if (w.isReleased() and !released_sent) {
            released_sent = true;
            _ = b.link.write(a, .release, 0, "");
        }
        if (stop_at) |t| if (thread.nowNs() >= t) {
            // The child did not end within 2 seconds of the stop.
            killChild(b);
            b.link.t.cancel();
            break;
        };
    }
}

fn forwardMsg(b: *Bridge, m: *Msg) void {
    const a = b.gpa;
    switch (m.kind) {
        .script => {
            var stream: u32 = 0;
            if (m.seq != 0) {
                b.plock.lock();
                stream = b.next_stream;
                b.next_stream +%= 2;
                if (b.next_stream == 0) b.next_stream = 2;
                b.pending.put(a, stream, .{ .from = m.from, .seq = m.seq }) catch {};
                b.plock.unlock();
            }
            const p = sendPayload(a, m.from, b.w.id, if (m.seq != 0) flag_reply else 0, m.var_name, m.text) catch return;
            defer a.free(p);
            _ = b.link.write(a, .send, stream, p);
        },
        // A reply or an async result of a send of the child: the number of
        // the reply is the stream of the child.
        .reply, .var_result => {
            const p = resultPayload(a, b.w.id, m) catch return;
            defer a.free(p);
            _ = b.link.write(a, .result, if (m.kind == .reply) @intCast(m.seq) else 0, p);
        },
    }
}

/// Reads the frames of the child until it ends.
fn readerMain(b: *Bridge) void {
    const w = b.w;
    const g = w.group;
    const a = b.gpa;
    while (true) {
        const f = readMessage(&b.link, a) catch break;
        defer a.free(f.payload);
        switch (f.kind) {
            .send => {
                const s = readSend(f.payload) catch break;
                const seq: u64 = if (s.flags & flag_reply != 0) f.stream else 0;
                thread.sendScript(w, s.to, s.script, seq, s.var_name, s.flags & flag_head != 0) catch |e| {
                    if (seq != 0) replyError(b, f.stream, s.to, e);
                };
            },
            .result => {
                const r = readResult(g, f.stream, f.payload) catch break;
                var to = r.to;
                if (r.msg.kind == .reply) {
                    b.plock.lock();
                    const p = b.pending.fetchRemove(f.stream);
                    b.plock.unlock();
                    const pend = p orelse {
                        r.msg.destroy(g.alloc());
                        continue;
                    };
                    to = pend.value.from;
                    r.msg.seq = pend.value.seq;
                }
                g.lock.lock();
                if (g.findLive(to)) |t| thread.pushMsg(t, r.msg, false) else r.msg.destroy(g.alloc());
                g.lock.unlock();
            },
            .output => {
                g.out_lock.lock();
                if (g.output) |o| o.write(o.ctx, f.payload);
                g.out_lock.unlock();
            },
            .bgerror => bgReport(w, f.payload),
            .exit => {
                var r: iso.Reader = .{ .b = f.payload };
                b.status = r.int(i64) catch 1;
                b.exited = true;
                break;
            },
            else => {},
        }
    }
    b.ended.store(true, .release);
    w.wake();
}

fn replyError(b: *Bridge, stream: u32, to: u64, e: thread.SendError) void {
    const a = b.gpa;
    var name: [32]u8 = undefined;
    const id = std.fmt.bufPrint(&name, "tid0x{x}", .{to}) catch "";
    var text_buf: [96]u8 = undefined;
    const text = switch (e) {
        error.NoThread => std.fmt.bufPrint(&text_buf, "thread \"{s}\" does not exist", .{id}) catch "no thread",
        error.QueueFull => "the queue of the thread is full",
        else => "the thread group is full",
    };
    var m: Msg = .{ .kind = .reply, .seq = stream, .code = 1, .res = .{ .str = @constCast(text) }, .info = @constCast(text), .ecode = .{ .str = @constCast("THREAD SEND") } };
    const p = resultPayload(a, b.w.id, &m) catch return;
    defer a.free(p);
    _ = b.link.write(a, .result, stream, p);
}

/// An error of the child for `thread::errorproc`, or the output.
fn bgReport(w: *Worker, info: []const u8) void {
    const g = w.group;
    var buf: [32]u8 = undefined;
    const id = w.name(&buf);
    g.lock.lock();
    const target = if (g.errorproc.len > 0) g.findLive(g.errorproc_id) else null;
    if (target) |t| {
        const a = g.alloc();
        if (thread.buildScript(a, &.{ g.errorproc, id, info })) |s| {
            if (a.create(Msg)) |m| {
                m.* = .{ .kind = .script, .from = w.id, .text = s };
                thread.pushMsg(t, m, false);
                g.lock.unlock();
                return;
            } else |_| a.free(s);
        } else |_| {}
    }
    g.lock.unlock();
    var tbuf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&tbuf, "Error from thread {s}\n{s}\n", .{ id, info }) catch return;
    g.out_lock.lock();
    defer g.out_lock.unlock();
    if (g.output) |o| o.write(o.ctx, text);
}

/// Ends an isolated thread in the parent, as `finish` ends a thread.
fn endBridge(w: *Worker, b: *Bridge, reader: ?std.Thread) void {
    const g = w.group;
    const a = b.gpa;
    if (!b.exited and !w.hasFlag(thread.Flag.stop)) bgReport(w, "the child process of the isolated thread ended with no exit");
    _ = b.link.write(a, .goodbye, 0, "");
    if (!reapChild(b, 2000)) {
        killChild(b);
        _ = reapChild(b, 2000);
    }
    b.link.t.cancel();
    if (reader) |r| r.join();
    b.link.t.deinit();
    g.lock.lock();
    w.state = .done;
    w.bridge = null;
    w.status = if (b.exited) b.status else 1;
    g.lock.unlock();
    thread.failQueue(w);
    // Each send of the parent that waits for the child gets an error.
    var it = b.pending.iterator();
    while (it.next()) |e| thread.replyFailed(g, e.value_ptr.from, e.value_ptr.seq);
    b.pending.deinit(a);
    a.destroy(b);
    thread.retire(w, 0);
}

// ---- The child ----

/// The clock and the event loop of the runner, for a child whose parent
/// thread had them.
pub const Hosts = struct {
    clock: ?@import("clock.zig").Host = null,
    event: ?@import("event.zig").Host = null,
};

const Child = struct {
    a: Allocator,
    link: *Link,
    w: *Worker = undefined,

    fn remote(c: *Child) thread.Remote {
        return .{ .ctx = c, .send = rSend, .deliver = rDeliver, .bgerror = rBgerror };
    }

    fn rSend(ctx: *anyopaque, to: u64, script: []const u8, seq: u64, var_name: []const u8, head: bool) thread.SendError!void {
        const c: *Child = @ptrCast(@alignCast(ctx));
        const flags: u8 = (if (seq != 0) flag_reply else 0) | (if (head) flag_head else 0);
        const p = sendPayload(c.a, c.w.id, to, flags, var_name, script) catch return error.OutOfMemory;
        defer c.a.free(p);
        if (!c.link.write(c.a, .send, @truncate(seq), p)) return error.NoThread;
    }

    fn rDeliver(ctx: *anyopaque, to: u64, m: *Msg) void {
        const c: *Child = @ptrCast(@alignCast(ctx));
        defer m.destroy(c.w.group.alloc());
        const p = resultPayload(c.a, to, m) catch return;
        defer c.a.free(p);
        _ = c.link.write(c.a, .result, if (m.kind == .reply) @truncate(m.seq) else 0, p);
    }

    fn rBgerror(ctx: *anyopaque, info: []const u8) void {
        const c: *Child = @ptrCast(@alignCast(ctx));
        _ = c.link.write(c.a, .bgerror, 0, info);
    }

    fn outWrite(ctx: ?*anyopaque, bytes: []const u8) void {
        const c: *Child = @ptrCast(@alignCast(ctx.?));
        _ = c.link.write(c.a, .output, 0, bytes);
    }
};

fn childReader(c: *Child) void {
    const w = c.w;
    const g = w.group;
    while (true) {
        const f = readMessage(c.link, c.a) catch break;
        defer c.a.free(f.payload);
        switch (f.kind) {
            .send => {
                const s = readSend(f.payload) catch break;
                const a = g.alloc();
                const m = a.create(Msg) catch continue;
                m.* = .{ .kind = .script, .from = s.from, .seq = if (s.flags & flag_reply != 0) f.stream else 0 };
                m.text = a.dupe(u8, s.script) catch &.{};
                m.var_name = a.dupe(u8, s.var_name) catch &.{};
                g.lock.lock();
                thread.pushMsg(w, m, s.flags & flag_head != 0);
                g.lock.unlock();
            },
            .result => {
                const r = readResult(g, f.stream, f.payload) catch break;
                g.lock.lock();
                thread.pushMsg(w, r.msg, false);
                g.lock.unlock();
            },
            .cancel => {
                var r: iso.Reader = .{ .b = f.payload };
                const bits = r.int(u32) catch break;
                const text = readStr(&r) catch break;
                g.lock.lock();
                w.lock.lock();
                if (text.len > 0) {
                    if (w.cancel_text) |t| g.alloc().free(t);
                    w.cancel_text = g.alloc().dupe(u8, text) catch null;
                }
                w.lock.unlock();
                thread.stopWorker(w, bits & (thread.Flag.cancel | thread.Flag.unwind | thread.Flag.stop));
                g.lock.unlock();
            },
            .release => {
                w.released.store(true, .release);
                w.wake();
            },
            .goodbye => break,
            else => {},
        }
    }
    // The parent is gone or said goodbye: the thread stops.
    g.lock.lock();
    thread.stopWorker(w, thread.Flag.stop);
    g.lock.unlock();
}

const StartIn = struct { id: u64, caps: u32, compute: u64, mem: u64, hosts: u8, script: []const u8 };

fn readStart(payload: []const u8) iso.Error!StartIn {
    var r: iso.Reader = .{ .b = payload };
    const s: StartIn = .{
        .id = try r.int(u64),
        .caps = try r.int(u32),
        .compute = try r.int(u64),
        .mem = try r.int(u64),
        .hosts = (try r.take(1))[0],
        .script = try readStr(&r),
    };
    try r.done();
    return s;
}

/// The child of an isolated thread on the transport `t`: runs the
/// thread and gives its exit status.
pub fn childMain(a: Allocator, t: iso.Transport, hosts: Hosts) u8 {
    var link: Link = .{ .t = t };
    defer link.t.deinit();
    link.conn = iso.Conn.init(&link.t);
    iso.childHandshake(&link.conn, a, null, "thread", 0) catch return 2;
    const f = readMessage(&link, a) catch return 2;
    defer a.free(f.payload);
    if (f.kind != .start) return 2;
    const st = readStart(f.payload) catch return 2;

    var c: Child = .{ .a = a, .link = &link };
    var x: Interp = undefined;
    x.init(a) catch return 2;
    defer x.deinit();
    x.compute_limit = st.compute;
    x.mem_limit = @intCast(@min(st.mem, std.math.maxInt(usize)));
    x.output = .{ .ctx = &c, .write = Child.outWrite };
    if (st.hosts & hosts_clock != 0) x.clock_host = hosts.clock;
    if (st.hosts & hosts_event != 0) x.event_host = hosts.event;
    // The thread of the child makes no thread of its own in this version.
    x.thread_limits.max_threads = 0;
    const thread_bit = @backingInt(interp.Capability.thread);
    x.allow(st.caps | thread_bit) catch return 2;
    const w = x.worker orelse return 2;
    w.id = st.id;
    w.is_main = false;
    w.mem_limit = x.mem_limit;
    w.group.next_id = st.id + 1;
    c.w = w;
    w.group.remote = c.remote();
    if (!link.write(a, .ready, 0, "")) return 2;

    const reader = std.Thread.spawn(.{}, childReader, .{&c}) catch return 2;
    const r = if (st.script.len > 0) x.eval(st.script) else thread.topScope(&x, thread.waitLoop, .{&x});
    if (r) |_| {} else |e| thread.endError(w, &x, e);
    var o: Out = .{ .a = a };
    o.int(i64, w.status) catch {};
    _ = link.write(a, .exit, 0, o.list.items);
    o.deinit();
    // The parent answers with goodbye, or closes.
    reader.join();
    w.group.remote = null;
    return 0;
}

/// The entry of the runner for `--iso-fd N`.
pub fn childProcess(a: Allocator, fd: i32, hosts: Hosts) u8 {
    if (comptime !supported) return 2;
    const t = iso.Transport.init(fd) catch return 2;
    return childMain(a, t, hosts);
}

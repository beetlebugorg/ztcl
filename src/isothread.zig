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
//!   START   id u64, caps u32, compute u64, memory u64, hosts u8, script,
//!           root path, current folder, files u8 (1: host mode),
//!           jit u8 (1: the JIT on, when the platform allows it)
//!   SEND    from u64, to u64, flags u8 (1 reply, 2 head), var name, script
//!   RESULT  kind u8 (0 reply, 1 async result), to u64, code i64, value,
//!           error info, error code value, var name
//!   CANCEL  bits u32 (thread.Flag), text
//!   OUTPUT  bytes;  BGERROR  error info;  EXIT  status i64
//!
//! A `SEND` with the flag `reply` has its stream id as the number of the
//! send, and its `RESULT` comes on the same stream.
//!
//! `tsv`, the mutexes, and the conditions of the child go through the
//! broker of the parent (`isobroker.zig`), with the frames `TSV`, `LOCK`,
//! `UNLOCK`, and `CANCEL`.
//!
//! Not in this step: `thread::transfer` and a thread that an isolated
//! thread creates. A script of the child that uses them gets an error.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const meter_mod = @import("meter.zig");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const thread = @import("thread.zig");
const iso = @import("isoproto.zig");
const isobroker = @import("isobroker.zig");
const probe = @import("probe.zig");
const dap = @import("dap.zig");
const Interp = interp.Interp;
const Error = interp.Error;
const Worker = thread.Worker;
const Group = thread.Group;
const Msg = thread.Msg;
const Shared = thread.Shared;
const Allocator = std.mem.Allocator;
const on_win = builtin.os.tag == .windows;

pub const supported = thread.supported and !thread.web and (builtin.os.tag == .linux or builtin.os.tag == .macos or (on_win and isow.supported));
/// The platforms where the bridge starts the runner itself. On Windows
/// the runner starts in the sandbox of `isolate_windows.zig`, and on
/// Linux in the namespaces of `isolate_linux.zig`.
pub const spawns_runner = builtin.os.tag == .macos or on_win or (on_linux and isol.supported);
const isow = @import("isolate_windows.zig");
const isol = @import("isolate_linux.zig");
const on_linux = builtin.os.tag == .linux;
const isouk = if (on_linux and builtin.cpu.arch == .x86_64) @import("isouk.zig") else struct {
    pub const supported = false;
};

/// The parent end of a transport: a descriptor, or a pipe handle on
/// Windows.
pub const Fd = if (on_win) *anyopaque else i32;

/// The hook of a test or an embedder: starts a child and gives the
/// parent end of its transport.
pub const Spawner = struct {
    ctx: ?*anyopaque = null,
    spawn: *const fn (ctx: ?*anyopaque) ?Fd,
};

/// The capabilities that a thread of the level vm does not get.
const vm_masked: u32 = blk: {
    var m: u32 = 0;
    for (.{ .channels, .file, .socket, .exec, .env, .sqlite, .launch, .registry, .keychain, .defaults, .notify, .vm }) |c| m |= @backingInt(@as(interp.Capability, c));
    break :blk m;
};

const flag_reply: u8 = 1;
const flag_head: u8 = 2;
const hosts_clock: u8 = 1;
const hosts_event: u8 = 2;
/// The debugger of the parent debugs the child: a DEBUG frame follows
/// START, before READY. An older child ignores the bit and the frame.
const hosts_debug: u8 = 4;
/// The parent follows Tcl 9.1, so the child does too. Without the bit,
/// the child follows 8.6.
const hosts_tcl91: u8 = 8;

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
    /// The messages and the payload bytes in both directions, for the
    /// meter of the thread (`meter.zig`).
    frames: std.atomic.Value(u64) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),

    fn write(l: *Link, a: Allocator, kind: iso.Kind, stream: u32, payload: []const u8) bool {
        l.wlock.lock();
        defer l.wlock.unlock();
        l.conn.writeMessage(a, kind, stream, payload) catch return false;
        l.count(payload.len);
        return true;
    }

    fn count(l: *Link, n: usize) void {
        _ = l.frames.fetchAdd(1, .monotonic);
        _ = l.bytes.fetchAdd(n, .monotonic);
    }

    fn writeFds(l: *Link, a: Allocator, kind: iso.Kind, payload: []const u8, fds: []const i32) bool {
        if (comptime !iso.passes_fds) return false;
        l.wlock.lock();
        defer l.wlock.unlock();
        l.conn.writeFrameFds(a, kind, 0, payload, fds) catch return false;
        return true;
    }
};

// ---- Channels (`thread::transfer`) ----

/// The payload of `FD`: to u64, the count of descriptors u8, and the
/// record of `tchan.shipOut`. The descriptors come with the frame.
fn fdPayload(a: Allocator, to: u64, n: usize, bytes: []const u8) ?[]u8 {
    const p = a.alloc(u8, 9 + bytes.len) catch return null;
    std.mem.writeInt(u64, p[0..8], to, .little);
    p[8] = @intCast(n);
    @memcpy(p[9..], bytes);
    return p;
}

/// True where a channel moves between the processes of isolated
/// threads: descriptors with `SCM_RIGHTS` on Linux and macOS, and
/// handles that the parent duplicates on Windows.
pub const moves_channels = iso.passes_fds or on_win;

const winh = struct {
    const HANDLE = *anyopaque;
    extern "kernel32" fn DuplicateHandle(src_proc: HANDLE, src: HANDLE, dst_proc: HANDLE, dst: *?HANDLE, access: u32, inherit: i32, opts: u32) callconv(.winapi) i32;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn GetFileType(h: HANDLE) callconv(.winapi) u32;
    extern "ws2_32" fn getsockopt(s: usize, level: i32, opt: i32, value: [*]u8, len: *i32) callconv(.winapi) i32;
    const close_source: u32 = 1;

    /// True when the handle `h` from a child is of `kind`: a file, a pipe,
    /// or a character device for a file (0), and a stream socket for a
    /// socket (1). Each other object, such as a process or a thread, has
    /// no file type.
    fn kindOk(h: HANDLE, kind: u8) bool {
        const file_type = GetFileType(h);
        if (kind == 0) return file_type >= 1 and file_type <= 3; // disk, char, pipe
        if (kind != 1) return false;
        var t: i32 = 0;
        var len: i32 = @sizeOf(i32);
        // SOL_SOCKET, SO_TYPE: SOCK_STREAM.
        return getsockopt(@intFromPtr(h), 0xffff, 0x1008, std.mem.asBytes(&t), &len) == 0 and t == 1;
    }
    const same_access: u32 = 2;
    const sysw = @import("sys_windows.zig");

    /// The process of the child of a bridge, or this process for a child
    /// of the spawner of a test, which is a thread here.
    fn childOf(b: *const Bridge) HANDLE {
        if (b.win) |c| return c.process;
        return GetCurrentProcess();
    }

    /// The payload of `FD` on Windows: to u64, the count u8, then for each
    /// handle its kind u8 (0 a file, 1 a socket) and its value u64 in the
    /// process `target`, then the record of `tchan.shipOut`. The handles
    /// of `fds` stay open here.
    ///
    /// A socket for a child goes as the WSAPROTOCOL_INFOW of
    /// `WSADuplicateSocketW` for the pid of the child (`pid`), since the
    /// documentation of `DuplicateHandle` gives that call for a socket:
    /// the entry is the kind 2 and the 628 bytes of the structure. A child
    /// in an AppContainer cannot open its parent for that call, so a
    /// socket from a child (`pid` null) goes as its handle of kind 1,
    /// which the parent takes and checks with `getsockopt`.
    fn payload(a: Allocator, to: u64, fds: []const i32, target: HANDLE, pid: ?u32, bytes: []const u8) ?[]u8 {
        var p: std.ArrayList(u8) = .empty;
        errdefer p.deinit(a);
        p.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, to))) catch return null;
        p.append(a, @intCast(fds.len)) catch return null;
        for (fds) |fd| {
            const h = sysw.handleOfFd(fd);
            if (h.kind == 1) {
                if (pid) |child| {
                    var info: [sysw.socket_info_len]u8 = undefined;
                    if (!sysw.socketInfoFor(fd, child, &info)) {
                        p.deinit(a);
                        return null;
                    }
                    p.append(a, 2) catch return null;
                    p.appendSlice(a, &info) catch return null;
                    continue;
                }
            }
            var out: ?HANDLE = null;
            if (DuplicateHandle(GetCurrentProcess(), @ptrFromInt(h.value), target, &out, 0, 0, same_access) == 0 or out == null) {
                p.deinit(a);
                return null;
            }
            p.append(a, h.kind) catch return null;
            p.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, @intFromPtr(out.?)))) catch return null;
        }
        p.appendSlice(a, bytes) catch return null;
        return p.toOwnedSlice(a) catch null;
    }

    /// The pid of the child of a bridge, or of this process for a child
    /// of the spawner of a test.
    fn pidOf(b: *const Bridge) u32 {
        if (b.win) |c| return c.pid;
        return GetCurrentProcessId();
    }
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

    fn send(g: *Group, to: u64, bytes: []const u8, fds: []const i32) bool {
        const a = g.gpa;
        g.lock.lock();
        defer g.lock.unlock();
        if (g.find(to)) |t| {
            const b: *Bridge = @ptrCast(@alignCast(t.bridge orelse return false));
            const p = payload(a, to, fds, childOf(b), pidOf(b), bytes) orelse return false;
            defer a.free(p);
            return b.link.write(a, .fd, 0, p);
        }
        // From a child to the parent: copies in this process, which the
        // parent takes with DUPLICATE_CLOSE_SOURCE. A child in an
        // AppContainer cannot open its parent.
        const r = g.remote orelse return false;
        if (r.send != Child.rSend) return false;
        const c: *Child = @ptrCast(@alignCast(r.ctx));
        const p = payload(c.a, to, fds, GetCurrentProcess(), null, bytes) orelse return false;
        defer c.a.free(p);
        return c.link.write(c.a, .fd, 0, p);
    }

    /// Takes an `FD` frame of Windows. `from` is the process of the child
    /// that sent it, or null in a child, where the parent made each handle
    /// already.
    fn take(g: *Group, payload_: []const u8, from: ?HANDLE) void {
        if (payload_.len < 9) return;
        const to = std.mem.readInt(u64, payload_[0..8], .little);
        const n: usize = payload_[8];
        if (n > iso.max_fds) return;
        var fds: [iso.max_fds]i32 = undefined;
        var k: usize = 0;
        var good = true;
        var at: usize = 9;
        while (k < n) : (k += 1) {
            if (at >= payload_.len) {
                good = false;
                break;
            }
            const kind = payload_[at];
            if (kind == 2) {
                // The information of a socket, which only the parent
                // makes, for this process.
                if (from != null or payload_.len < at + 1 + sysw.socket_info_len) {
                    good = false;
                    break;
                }
                fds[k] = sysw.socketOfInfo(payload_[at + 1 ..][0..sysw.socket_info_len]) orelse {
                    good = false;
                    break;
                };
                at += 1 + sysw.socket_info_len;
                continue;
            }
            if (payload_.len < at + 9) {
                good = false;
                break;
            }
            var v: usize = @intCast(std.mem.readInt(u64, payload_[at + 1 ..][0..8], .little));
            at += 9;
            if (from) |src| {
                var out: ?HANDLE = null;
                if (DuplicateHandle(src, @ptrFromInt(v), GetCurrentProcess(), &out, 0, 0, same_access | close_source) == 0 or out == null) {
                    good = false;
                    break;
                }
                v = @intFromPtr(out.?);
                // A child can name each handle of its own table: the
                // object must be of the kind that the frame says.
                if (!kindOk(out.?, kind)) {
                    _ = CloseHandle(out.?);
                    good = false;
                    break;
                }
            }
            fds[k] = sysw.fdOfKind(kind, v) orelse {
                good = false;
                break;
            };
        }
        if (!good) {
            for (fds[0..k]) |f| @import("sys.zig").close(f);
            return;
        }
        const bytes = payload_[at..];
        if (from != null) {
            // From one isolated thread to another: on to its child.
            g.lock.lock();
            const other = if (g.find(to)) |t| t.bridge else null;
            if (other) |ob| {
                const b: *Bridge = @ptrCast(@alignCast(ob));
                if (payload(g.gpa, to, fds[0..k], childOf(b), pidOf(b), bytes)) |p| {
                    _ = b.link.write(g.gpa, .fd, 0, p);
                    g.gpa.free(p);
                }
                g.lock.unlock();
                for (fds[0..k]) |f| @import("sys.zig").close(f);
                return;
            }
            g.lock.unlock();
        }
        _ = @import("tchan.zig").shipIn(g, bytes, fds[0..k]);
    }
};

/// Sends a channel of `tchan.shipOut` toward the thread `to`: to its
/// child when `to` is an isolated thread, or to the parent from a child.
/// The descriptors stay open here.
pub fn sendChannel(g: *Group, to: u64, bytes: []const u8, fds: []const i32) bool {
    if (comptime on_win) return winh.send(g, to, bytes, fds);
    if (comptime !iso.passes_fds) return false;
    const a = g.gpa;
    const p = fdPayload(a, to, fds.len, bytes) orelse return false;
    defer a.free(p);
    g.lock.lock();
    defer g.lock.unlock();
    if (g.find(to)) |t| {
        const b: *Bridge = @ptrCast(@alignCast(t.bridge orelse return false));
        return b.link.writeFds(a, .fd, p, fds);
    }
    const r = g.remote orelse return false;
    if (r.send != Child.rSend) return false;
    const c: *Child = @ptrCast(@alignCast(r.ctx));
    return c.link.writeFds(c.a, .fd, p, fds);
}

/// Takes an `FD` frame: its descriptors from the transport, then the
/// channel goes to the detached list of `g`, or on to another isolated
/// thread of the parent.
fn takeChannel(g: *Group, l: *Link, payload: []const u8, from_child: bool) void {
    if (comptime !iso.passes_fds) return;
    if (payload.len < 9) return;
    const to = std.mem.readInt(u64, payload[0..8], .little);
    const n = @min(payload[8], iso.max_fds);
    var fds: [iso.max_fds]i32 = undefined;
    var k: usize = 0;
    while (k < n) : (k += 1) fds[k] = l.t.takeFd() orelse break;
    if (k != payload[8]) {
        for (fds[0..k]) |f| _ = @import("sys.zig").os.close(f);
        return;
    }
    if (from_child) {
        // From one isolated thread to another: on to its child.
        g.lock.lock();
        const other = if (g.find(to)) |t| t.bridge else null;
        if (other) |ob| {
            const b: *Bridge = @ptrCast(@alignCast(ob));
            _ = b.link.writeFds(g.gpa, .fd, payload, fds[0..k]);
            g.lock.unlock();
            for (fds[0..k]) |f| _ = @import("sys.zig").os.close(f);
            return;
        }
        g.lock.unlock();
    }
    _ = @import("tchan.zig").shipIn(g, payload[9..], fds[0..k]);
}

/// Reads a whole message: the frames of one stream with the flag `more`
/// make one payload. A frame of another stream between them is an
/// error of the protocol in this version.
fn readMessage(l: *Link, a: Allocator) iso.Error!iso.Frame {
    const f = try readWhole(l, a);
    l.count(f.payload.len);
    return f;
}

fn readWhole(l: *Link, a: Allocator) iso.Error!iso.Frame {
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
    /// The handle of the debugger for this thread (`probe.ThreadHook`).
    dbg: ?*anyopaque = null,
    runner: ?[]const u8,
    spawner: ?Spawner,
    hosts: u8,
    caps: u32,
    /// The root folder of the creator and its current folder, or host
    /// mode, for the jail of the child.
    root: []const u8 = "",
    cwd: []const u8 = "",
    host_files: bool = false,
    /// True when the creator has the JIT on, so the child turns it on.
    jit: bool = false,
    /// The memory limit of the thread, for the watch of the parent.
    mem_limit: u64 = 0,
    mem_killed: bool = false,
    link: Link = undefined,
    pid: i32 = -1,
    /// The sandbox of the child on Windows.
    win: if (on_win) ?isow.Child else void = if (on_win) null else {},
    /// The sandbox of the child on Linux, and the real path of the root
    /// folder that `bridgeMain` allocates.
    lin: if (on_linux) ?isol.Child else void = if (on_linux) null else {},
    real_root: ?[]u8 = null,
    /// The level vm: the path of the unikernel image, and its guest.
    unikernel: ?[]u8 = null,
    guest: if (isouk.supported) ?*isouk.Guest else void = if (isouk.supported) null else {},
    /// The memory limit of the thread, for the limit of the system.
    mem: usize = std.math.maxInt(usize),
    /// The error of a failed start, for `startError`.
    err: []const u8 = "",
    err_code: []const u8 = "ZTCL ISOLATION START",
    plock: thread.Lock = .{},
    pending: std.AutoHashMapUnmanaged(u32, Pending) = .empty,
    next_stream: u32 = 2,
    ended: std.atomic.Value(bool) = .init(false),
    status: i64 = 0,
    /// The meter of the thread (`thread::create -meter`), its units of
    /// the budget, the counts that the child reports in `USAGE`, the
    /// counts of the system, and the times of the start.
    meter: ?*meter_mod.Meter = null,
    meter_resv: u64 = 0,
    child_counts: meter_mod.Counts = .{},
    os_cpu_ns: u64 = 0,
    os_peak: u64 = 0,
    t0: u64 = 0,
    start_ns: u64 = 0,
    exited: bool = false,
    broker: isobroker.Broker = undefined,
};

fn bridgeWrite(ctx: *anyopaque, kind: iso.Kind, stream: u32, payload: []const u8) bool {
    const b: *Bridge = @ptrCast(@alignCast(ctx));
    return b.link.write(b.gpa, kind, stream, payload);
}

/// Gives a frame of the child to a broker, with a copy of its payload.
fn toBroker(a: Allocator, f: iso.Frame, post: anytype) void {
    var g = f;
    g.payload = a.dupe(u8, f.payload) catch return;
    post.post(g);
}

fn rootOf(it: *Interp) *Interp {
    var root = it;
    while (root.parent) |p| root = p;
    return root;
}

/// Makes the bridge of a new isolated thread. The caller holds the
/// group lock, so this only allocates.
/// With `vm`, the child is the runner in a guest of `ztcl::vm`
/// (`isovm.zig`, Linux with KVM): the thread gets no capability that
/// reaches the host (`vm_masked`), since the guest has no files, sockets,
/// or processes of the host. With `guest` unikernel, the child is the
/// ztcl unikernel (`isouk.zig`).
pub fn prepare(it: *Interp, w: *Worker, st: anytype, host_files: bool, vm: bool, guest: thread.Guest) Error!*Bridge {
    if (comptime !supported) return it.failCode("ZTCL ISOLATION LEVEL", "the level process is not available on this platform yet", .{});
    const root = rootOf(it);
    var vm_spawner: ?Spawner = null;
    if (vm) {
        if (it.capabilities & @backingInt(interp.Capability.vm) == 0)
            return it.failCode("ZTCL ISOLATION LEVEL", "the level vm needs the vm capability", .{});
        if (guest == .unikernel) return prepareVm(it, w, st);
        vm_spawner = @import("microvm.zig").isoSpawner(root) orelse
            return it.failCode("ZTCL ISOLATION LEVEL", "the level vm needs ztcl::vm on Linux with KVM and a guest of the runner (Host.iso_kernel and iso_initrd)", .{});
    }
    if (!vm and root.iso_spawn == null and !spawns_runner)
        return it.failCode("ZTCL ISOLATION LEVEL", "the level process is not available on this platform yet", .{});
    if (!vm and root.iso_runner == null and root.iso_spawn == null)
        return it.failCode("ZTCL ISOLATION RUNNER", "the embedder gives no runner for isolated threads", .{});
    // The sandbox of a child gives it no folder of the user, so host mode
    // with no `-files host` gives it only errors of access later. A
    // creator with a root folder has no files of the host to give.
    const file_bits = @backingInt(interp.Capability.file) | @backingInt(interp.Capability.channels);
    if (!vm and root.fs.host and st.caps & file_bits != 0 and !host_files)
        return it.failCode("ZTCL ISOLATION HOSTFILES", "host file mode is not available in an isolated thread: give the thread a root folder, or pass -files host", .{});
    if (host_files and !root.fs.host)
        return it.failCode("ZTCL ISOLATION HOSTFILES", "-files host needs a creator in host mode", .{});
    const g = w.group;
    const b = try g.gpa.create(Bridge);
    b.* = .{
        .gpa = g.gpa,
        .w = w,
        .runner = root.iso_runner,
        .spawner = if (vm) vm_spawner else root.iso_spawn,
        .hosts = (if (st.clock_host != null) hosts_clock else 0) | (if (st.event_host != null) hosts_event else 0) | (if (st.tcl == .v9_1) hosts_tcl91 else 0),
        .caps = if (vm) st.caps & ~vm_masked else st.caps,
        .root = if (vm) "" else st.fs_path,
        .cwd = if (vm) "" else st.fs_cwd,
        .host_files = host_files and st.caps & file_bits != 0,
        .jit = st.jit != null,
        .mem_limit = st.mem_limit,
    };
    return b;
}

/// The bridge of a thread at the level vm: the ztcl unikernel next to
/// the runner, on KVM (`isouk.zig`). The guest has no files and no
/// sockets, so the child gets only the capabilities of `uk_caps`.
fn prepareVm(it: *Interp, w: *Worker, st: anytype) Error!*Bridge {
    if (comptime !isouk.supported) return it.failCode("ZTCL ISOLATION LEVEL", "the level vm is not available on this platform yet", .{});
    const root = rootOf(it);
    const runner = root.iso_runner orelse return it.failCode("ZTCL ISOLATION RUNNER", "the embedder gives no runner for isolated threads", .{});
    const g = w.group;
    const dir = std.fs.path.dirname(runner) orelse ".";
    const path = std.fs.path.join(g.gpa, &.{ dir, "ztcl-unikernel" }) catch return error.OutOfMemory;
    errdefer g.gpa.free(path);
    const b = try g.gpa.create(Bridge);
    b.* = .{
        .gpa = g.gpa,
        .w = w,
        .runner = null,
        .spawner = null,
        .hosts = (if (st.clock_host != null) hosts_clock else 0) | (if (st.event_host != null) hosts_event else 0),
        .caps = st.caps & uk_caps,
        .jit = st.jit != null,
        .mem_limit = st.mem_limit,
        .unikernel = path,
    };
    return b;
}

pub fn unprepare(b: *Bridge) void {
    if (b.unikernel) |p| b.gpa.free(p);
    if (b.real_root) |r| b.gpa.free(r);
    b.gpa.destroy(b);
}

/// The error of a failed start. It frees the bridge.
pub fn startError(it: *Interp, b: *Bridge) Error {
    defer unprepare(b);
    return it.failCode(b.err_code, "{s}", .{b.err});
}

fn spawnChild(b: *Bridge) ?Fd {
    if (b.spawner) |s| return s.spawn(s.ctx);
    if (comptime isouk.supported) if (b.unikernel) |path| {
        const g = isouk.start(b.gpa, path, b.mem) orelse {
            b.err = isouk.why;
            return null;
        };
        b.guest = g;
        return g.fd;
    };
    const runner = b.runner orelse return null;
    return spawnRunner(b, runner);
}

/// Starts `runner --iso-fd 3` with one end of a socket pair as its
/// descriptor 3. Gives the other end.
fn spawnRunner(b: *Bridge, runner: []const u8) ?Fd {
    if (comptime !spawns_runner) return null;
    if (comptime on_win) return spawnSandbox(b, runner);
    if (comptime on_linux) return spawnLinux(b, runner);
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

/// Starts `runner --iso-handle 0x...` in the sandbox of Windows: an
/// AppContainer with no folder of the user and a Job Object. The child
/// gets the network only with the capability `socket`, and its job ends
/// it past `sandboxMem` of the memory limit of the thread. With the
/// capability `file` or `channels`, the AppContainer can read and write
/// the root folder of the creator, which the child opens as its jail.
/// With `-files host` the child runs with no AppContainer
/// (`Spawn.host_files`). Gives the pipe, which the transport then owns.
fn spawnSandbox(b: *Bridge, runner: []const u8) ?Fd {
    if (comptime !on_win) return null;
    const net = b.caps & @backingInt(interp.Capability.socket) != 0;
    const file_bits = @backingInt(interp.Capability.file) | @backingInt(interp.Capability.channels);
    const files = b.caps & file_bits != 0 and !b.host_files and b.root.len > 0;
    var c = isow.spawn(b.gpa, runner, .{
        .args = &.{},
        .root = if (files) b.root else null,
        .host_files = b.host_files,
        .net = net,
        .limits = .{ .mem_bytes = sandboxMem(b.mem) },
    }) catch return null;
    const h = c.takePipe();
    b.win = c;
    return h;
}

/// Starts `runner --iso-fd 3` in the namespaces, the cgroup, and the
/// new root of `isolate_linux.zig`. A kernel with no such feature gives
/// ZTCL ISOLATION LEVEL with the name of the feature.
fn spawnLinux(b: *Bridge, runner: []const u8) ?Fd {
    if (comptime !on_linux) return null;
    const file_bits = @backingInt(interp.Capability.file) | @backingInt(interp.Capability.channels);
    const files = b.caps & file_bits != 0;
    var c = isol.spawn(b.gpa, runner, .{
        .root = if (files and !b.host_files) b.real_root else null,
        .host_files = files and b.host_files,
        .net = b.caps & @backingInt(interp.Capability.socket) != 0,
        .zones = b.caps & @backingInt(interp.Capability.clock) != 0,
        .limits = .{ .mem_bytes = sandboxMem(b.mem) },
    }) catch |e| {
        b.err = isol.message(e);
        if (e != error.OutOfMemory and e != error.SpawnFailed) b.err_code = "ZTCL ISOLATION LEVEL";
        return null;
    };
    b.pid = c.pid;
    const fd = c.takeFd();
    b.lin = c;
    return fd;
}

/// The memory of the runtime of a child past the limit of its thread:
/// the runner, its stacks, and the free space of its heap.
pub const runtime_mem: u64 = 64 << 20;

/// The memory limit of the system for a child: the limit of the thread
/// plus `runtime_mem`, or 0 (no limit) for a thread with no limit.
pub fn sandboxMem(mem_limit: usize) u64 {
    if (mem_limit == std.math.maxInt(usize)) return 0;
    return std.math.add(u64, mem_limit, runtime_mem) catch 0;
}

/// The real path of the open folder `fd` (`/proc/self/fd`), or null.
fn realPathFd(a: Allocator, fd: i32) ?[]u8 {
    if (comptime !on_linux) return null;
    const linux = std.os.linux;
    var name: [32]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&name, "/proc/self/fd/{d}", .{fd}, 0) catch return null;
    var buf: [4096]u8 = undefined;
    const r = linux.readlinkat(linux.AT.FDCWD, p.ptr, &buf, buf.len);
    if (linux.errno(r) != .SUCCESS or r == 0 or r >= buf.len or buf[0] != '/') return null;
    return a.dupe(u8, buf[0..r]) catch null;
}

fn closeFd(fd: Fd) void {
    if (comptime on_win) {
        _ = CloseHandle(fd);
    } else _ = @import("sys.zig").os.close(fd);
}
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) i32;

fn killChild(b: *Bridge) void {
    if (comptime isouk.supported) if (b.guest) |g| {
        g.stop(b.gpa);
        b.guest = null;
        return;
    };
    if (comptime !spawns_runner) return;
    if (comptime on_win) {
        if (b.win) |*c| c.kill();
        return;
    }
    if (comptime on_linux) {
        if (b.lin) |*c| c.kill();
        return;
    }
    if (b.pid > 0) _ = std.c.kill(b.pid, std.c.SIG.KILL);
}

/// Waits up to `ms` for the child to end.
fn reapChild(b: *Bridge, ms: u32) bool {
    if (comptime isouk.supported) if (b.guest) |g| {
        // The unikernel stops itself after GOODBYE.
        var waited: u32 = 0;
        while (g.m.getState() == .running and waited < ms) : (waited += 1) {
            var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
            _ = std.os.linux.nanosleep(&ts, null);
        }
        if (g.m.getState() == .running) return false;
        g.stop(b.gpa);
        b.guest = null;
        return true;
    };
    if (comptime !spawns_runner) return true;
    if (comptime on_win) {
        const c = if (b.win) |*c| c else return true;
        if (c.wait(ms) == null) return false;
        const u = c.usage();
        b.os_cpu_ns = u.cpu_ns;
        b.os_peak = u.peak_bytes;
        c.deinit();
        b.win = null;
        return true;
    }
    if (comptime on_linux) {
        const c = if (b.lin) |*c| c else return true;
        if (c.wait(ms) == null) return false;
        const u = c.usage();
        b.os_cpu_ns = u.cpu_ns;
        b.os_peak = u.peak_bytes;
        c.deinit();
        b.lin = null;
        b.pid = -1;
        return true;
    }
    if (b.pid <= 0) return true;
    var waited: u32 = 0;
    while (true) : (waited += 10) {
        var status: c_int = 0;
        var ru: std.c.rusage = undefined;
        const r = std.c.wait4(b.pid, &status, std.c.W.NOHANG, &ru);
        if (r == b.pid) {
            const tv = struct {
                fn ns(t: std.c.timeval) u64 {
                    return @as(u64, @intCast(t.sec)) * std.time.ns_per_s + @as(u64, @intCast(t.usec)) * std.time.ns_per_us;
                }
            };
            b.os_cpu_ns = tv.ns(ru.utime) + tv.ns(ru.stime);
            // macOS gives ru_maxrss in bytes.
            b.os_peak = @intCast(ru.maxrss);
        }
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
    dbgGone(b);
    b.err = text;
    if (b.meter) |m| m.release();
    b.meter = null;
    killChild(b);
    _ = reapChild(b, 2000);
    thread.failStart(w, st);
}

fn dbgWrite(ctx: ?*anyopaque, body: []const u8) bool {
    const b: *Bridge = @ptrCast(@alignCast(ctx.?));
    return b.link.write(b.gpa, .debug, 0, body);
}

/// The debugger sends its first DEBUG frame to the child, after START.
/// With no debugger, an empty frame lets the child go on.
fn dbgStart(b: *Bridge) bool {
    if (comptime !probe.enabled) return true;
    const h = probe.threads orelse return b.link.write(b.gpa, .debug, 0, "");
    b.dbg = h.remote(h.ctx, b.w.id, .{ .ctx = b, .write = dbgWrite });
    return b.dbg != null or b.link.write(b.gpa, .debug, 0, "");
}

/// The debugger forgets the child.
fn dbgGone(b: *Bridge) void {
    if (comptime !probe.enabled) return;
    const d = b.dbg orelse return;
    b.dbg = null;
    if (probe.threads) |h| h.gone(h.ctx, d);
}

/// The OS thread of an isolated thread in the parent.
pub fn bridgeMain(w: *Worker, b: *Bridge, st: anytype) void {
    const g = w.group;
    const a = b.gpa;
    b.mem = st.mem_limit;
    if (st.meter) |m| {
        m.retain();
        b.meter = m;
        b.meter_resv = st.meter_resv;
        b.t0 = meter_mod.monoNs();
    }
    if (comptime on_linux) {
        // The child sees the root folder at its real path.
        if (st.fs_fd >= 0) b.real_root = realPathFd(a, st.fs_fd);
        if (b.real_root == null and b.root.len > 0) b.real_root = std.fs.path.resolve(a, &.{b.root}) catch null;
        if (b.real_root) |r| b.root = r;
    }
    const fd = spawnChild(b) orelse return failBridge(w, b, st, if (b.err.len > 0) b.err else "the system could not start the child process");
    b.link = .{ .t = iso.Transport.init(fd) catch {
        closeFd(fd);
        return failBridge(w, b, st, "no transport for the child process");
    } };
    b.link.conn = iso.Conn.init(&b.link.t);
    const secret: ?[32]u8 = if (comptime isouk.supported) (if (b.guest) |gu| gu.secret else null) else null;
    const wel = iso.parentHandshake(&b.link.conn, a, secret, &.{"thread"}, false) catch {
        b.link.t.deinit();
        return failBridge(w, b, st, "the handshake with the child process failed");
    };
    a.free(wel.service);
    const debugged = probe.enabled and probe.threads != null;
    if (debugged) b.hosts |= hosts_debug;
    if (!sendStart(b, st) or (debugged and !dbgStart(b))) {
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
    b.broker = .init(a, w, .{ .ctx = b, .write = bridgeWrite });

    if (b.meter != null) b.start_ns = meter_mod.monoNs() -| b.t0;
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
    dbgGone(b);
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
    startTail(&o, b.root, b.cwd, b.host_files, b.jit) catch return false;
    return b.link.write(a, .start, 0, o.list.items);
}

/// The fields of `START` after the script: the root folder, the current
/// folder, `files`, and `jit`.
fn startTail(o: *Out, root: []const u8, cwd: []const u8, host_files: bool, jit_on: bool) !void {
    try o.str(root);
    try o.str(cwd);
    try o.list.append(o.a, if (host_files) 1 else 0);
    try o.list.append(o.a, if (jit_on) 1 else 0);
}

/// Forwards the queue of the worker to the child until the child ends.
fn forward(w: *Worker, b: *Bridge) void {
    const g = w.group;
    const a = b.gpa;
    var released_sent = false;
    var stop_at: ?i96 = null;
    var next_watch: i96 = 0;
    while (!b.ended.load(.acquire)) {
        if (comptime spawns_runner) {
            if (b.pid > 0 and thread.nowNs() >= next_watch) {
                next_watch = thread.nowNs() + 100 * std.time.ns_per_ms;
                if (overMemory(b)) {
                    b.mem_killed = true;
                    killChild(b);
                    b.link.t.cancel();
                    break;
                }
            }
        }
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

/// The memory of the runtime of a child, above the limit of its thread.
const runtime_margin: u64 = 128 << 20;

/// True when the child uses more memory than its thread may, with the
/// margin of the runtime.
fn overMemory(b: *Bridge) bool {
    if (comptime builtin.os.tag != .macos) return false;
    if (b.mem_limit == 0 or b.mem_limit >= std.math.maxInt(u64) - runtime_margin) return false;
    const f = @import("isolate_mac.zig").footprint(b.pid) orelse return false;
    return f > b.mem_limit + runtime_margin;
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
            const flags: u8 = (if (m.seq != 0) flag_reply else 0) | (if (m.head) flag_head else 0);
            const p = sendPayload(a, m.from, b.w.id, flags, m.var_name, m.text) catch return;
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
                // `-unwindonerror`: a script with an error ends the thread,
                // as in `thread.zig`. The configure went to the proxy.
                if (r.msg.code != 0 and w.unwind_on_error) w.released.store(true, .release);
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
            .bgerror => {
                bgReport(w, f.payload);
                if (w.unwind_on_error) w.released.store(true, .release);
            },
            .tsv, .lock, .unlock, .cancel => toBroker(a, f, &b.broker),
            .fd => if (comptime on_win) winh.take(g, f.payload, winh.childOf(b)) else takeChannel(g, &b.link, f.payload, true),
            .usage => if (meter_mod.Counts.decode(f.payload)) |c| {
                b.child_counts = c;
            },
            .debug => if (comptime probe.enabled) if (b.dbg) |d| if (probe.threads) |h| h.child(h.ctx, d, f.payload),
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
    if (b.mem_killed) {
        bgReport(w, "the child process of the isolated thread passed its memory limit");
    } else if (!b.exited and !w.hasFlag(thread.Flag.stop)) bgReport(w, "the child process of the isolated thread ended with no exit");
    _ = b.link.write(a, .goodbye, 0, "");
    if (!reapChild(b, 2000)) {
        killChild(b);
        _ = reapChild(b, 2000);
    }
    b.link.t.cancel();
    if (reader) |r| r.join();
    // The locks of the child go free before the end of the worker.
    b.broker.deinit();
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
    if (b.real_root) |r| a.free(r);
    if (b.unikernel) |p| a.free(p);
    if (b.meter) |m| {
        var c = b.child_counts;
        // The parent measures the time and the transport. The other
        // counts come from the child.
        c.wall_ns = meter_mod.monoNs() -| b.t0;
        c.threads_interp = 0;
        c.threads_process = 1;
        c.process_messages = b.link.frames.load(.monotonic);
        c.process_bytes = b.link.bytes.load(.monotonic);
        c.process_start_ns = b.start_ns;
        c.os_cpu_ns = b.os_cpu_ns;
        c.os_mem_peak = b.os_peak;
        m.merge(c);
        m.unreserve(b.meter_resv -| c.units);
        m.release();
    }
    a.destroy(b);
    thread.retire(w, 0);
}

// ---- The child ----

/// The clock and the event loop of the runner, for a child whose parent
/// thread had them.
pub const Hosts = struct {
    clock: ?@import("clock.zig").Host = null,
    event: ?@import("event.zig").Host = null,
    /// Enter the sandbox of the platform before the first script. The
    /// runner sets it; a test child in the same process does not.
    sandbox: bool = false,
};

const Child = struct {
    a: Allocator,
    link: *Link,
    /// The debugger of the parent reaches this child (`dap.zig`).
    dbg: ?*dap.Server = null,
    w: *Worker = undefined,
    caller: isobroker.Caller = undefined,
    /// True after the end of the connection.
    done: bool = false,

    fn write(ctx: *anyopaque, kind: iso.Kind, stream: u32, payload: []const u8) bool {
        const c: *Child = @ptrCast(@alignCast(ctx));
        return c.link.write(c.a, kind, stream, payload);
    }

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

    fn dbgWrite(ctx: ?*anyopaque, body: []const u8) bool {
        const c: *Child = @ptrCast(@alignCast(ctx.?));
        return c.link.write(c.a, .debug, 0, body);
    }
};

fn childReader(c: *Child) void {
    while (childFrame(c)) {}
    childEnd(c);
}

/// Reads one message of the parent and acts on it. Gives false at the
/// end of the connection.
fn childFrame(c: *Child) bool {
    const w = c.w;
    const g = w.group;
    {
        const f = readMessage(c.link, c.a) catch return false;
        defer c.a.free(f.payload);
        switch (f.kind) {
            .send => {
                const s = readSend(f.payload) catch return false;
                const a = g.alloc();
                const m = a.create(Msg) catch return true;
                m.* = .{ .kind = .script, .from = s.from, .seq = if (s.flags & flag_reply != 0) f.stream else 0 };
                m.text = a.dupe(u8, s.script) catch &.{};
                m.var_name = a.dupe(u8, s.var_name) catch &.{};
                g.lock.lock();
                thread.pushMsg(w, m, s.flags & flag_head != 0);
                g.lock.unlock();
            },
            .result => {
                const r = readResult(g, f.stream, f.payload) catch return false;
                g.lock.lock();
                thread.pushMsg(w, r.msg, false);
                g.lock.unlock();
            },
            .cancel => {
                var r: iso.Reader = .{ .b = f.payload };
                const bits = r.int(u32) catch return false;
                const text = readStr(&r) catch return false;
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
            .tsv => {
                const p = c.a.dupe(u8, f.payload) catch return true;
                c.caller.deliver(f.stream, p);
            },
            .fd => if (comptime on_win) winh.take(g, f.payload, null) else takeChannel(g, c.link, f.payload, false),
            .debug => if (comptime probe.enabled) if (c.dbg) |d| dap.deliver(d, c.a.dupe(u8, f.payload) catch return true),
            .goodbye => return false,
            else => {},
        }
    }
    return true;
}

/// The parent is gone or said goodbye: the thread stops.
fn childEnd(c: *Child) void {
    c.done = true;
    const g = c.w.group;
    c.caller.end();
    g.lock.lock();
    thread.stopWorker(c.w, thread.Flag.stop);
    g.lock.unlock();
}

const StartIn = struct { id: u64, caps: u32, compute: u64, mem: u64, hosts: u8, script: []const u8, root: []const u8, cwd: []const u8, files: u8, jit: u8 };

fn readStart(payload: []const u8) iso.Error!StartIn {
    var r: iso.Reader = .{ .b = payload };
    const s: StartIn = .{
        .id = try r.int(u64),
        .caps = try r.int(u32),
        .compute = try r.int(u64),
        .mem = try r.int(u64),
        .hosts = (try r.take(1))[0],
        .script = try readStr(&r),
        .root = try readStr(&r),
        .cwd = try readStr(&r),
        .files = (try r.take(1))[0],
        .jit = (try r.take(1))[0],
    };
    try r.done();
    return s;
}

/// Sets the jail of the child as the creator had it, then enters the
/// sandbox of the platform when `hosts.sandbox`.
fn jail(a: Allocator, x: *Interp, st: StartIn, hosts: Hosts) bool {
    const fsroot = @import("fsroot.zig");
    const file_bits = @backingInt(interp.Capability.file) | @backingInt(interp.Capability.channels);
    const files = st.caps & file_bits != 0;
    var real: ?[]u8 = null;
    defer if (real) |p| a.free(p);
    if (files and st.files == 1) {
        fsroot.setHost(x) catch return false;
    } else if (files and st.root.len > 0) {
        fsroot.setRoot(x, st.root) catch return false;
        x.fs.cwd = x.alloc().dupe(u8, st.cwd) catch return false;
        if (comptime builtin.os.tag == .macos) real = @import("isolate_mac.zig").realPath(a, x.fs.fd);
    }
    if (!hosts.sandbox) return true;
    // On Windows the parent starts the child in its AppContainer
    // (`isolate_windows.zig`), so the child has no step of its own.
    if (comptime builtin.os.tag == .windows) return true;
    if (comptime builtin.os.tag == .macos) {
        @import("isolate_mac.zig").enter(a, .{
            .root = real,
            .host_files = files and st.files == 1,
            .net = st.caps & @backingInt(interp.Capability.socket) != 0,
            .zones = st.caps & @backingInt(interp.Capability.clock) != 0,
        }) catch return false;
        return true;
    }
    if (comptime on_linux and isol.supported) {
        // The parent started the child in its namespaces and its new
        // root (`isolate_linux.zig`). Landlock and seccomp follow here.
        isol.enter(.{
            .root = if (files and st.files != 1 and st.root.len > 0) st.root else null,
            .host_files = files and st.files == 1,
            .net = st.caps & @backingInt(interp.Capability.socket) != 0,
            .zones = st.caps & @backingInt(interp.Capability.clock) != 0,
        }) catch return false;
        return true;
    }
    return false;
}

/// The child of an isolated thread on the transport `t`: runs the
/// thread and gives its exit status.
pub fn childMain(a: Allocator, t: iso.Transport, hosts: Hosts) u8 {
    var link: Link = .{ .t = t };
    defer link.t.deinit();
    link.conn = iso.Conn.init(&link.t);
    iso.childHandshake(&link.conn, a, if (comptime thread.uk) ukSecret() else null, "thread", 0) catch return 2;
    const f = readMessage(&link, a) catch return 2;
    defer a.free(f.payload);
    if (f.kind != .start) return 2;
    const st = readStart(f.payload) catch return 2;
    // The first DEBUG frame: the state of the debugger of the parent.
    var attach: ?iso.Frame = null;
    defer if (attach) |d| a.free(d.payload);
    if (st.hosts & hosts_debug != 0) {
        attach = readMessage(&link, a) catch return 2;
        if (attach.?.kind != .debug) return 2;
    }

    var c: Child = .{ .a = a, .link = &link };
    var x: Interp = undefined;
    x.init(a) catch return 2;
    defer x.deinit();
    // `Interp.init` turns the JIT on. The jit byte of START turns it on
    // again after the sandbox.
    x.disableJit();
    if (st.hosts & hosts_tcl91 != 0) x.setTclVersion(.v9_1) catch return 2;
    x.compute_limit = st.compute;
    x.mem_limit = @intCast(@min(st.mem, std.math.maxInt(usize)));
    x.output = .{ .ctx = &c, .write = Child.outWrite };
    if (st.hosts & hosts_clock != 0) x.clock_host = hosts.clock;
    if (st.hosts & hosts_event != 0) x.event_host = hosts.event;
    // The thread of the child makes no thread of its own in this version.
    x.thread_limits.max_threads = 0;
    const thread_bit = @backingInt(interp.Capability.thread);
    // The unikernel has no files, sockets, or processes: only the
    // capabilities of `uk_caps`.
    const caps = if (comptime thread.uk) st.caps & uk_caps else st.caps;
    x.allow(caps | thread_bit) catch return 2;
    const w = x.worker orelse return 2;
    w.id = st.id;
    w.is_main = false;
    w.mem_limit = x.mem_limit;
    w.group.next_id = st.id + 1;
    // The channel names of the child start in a range of its own, so a
    // channel that `thread::transfer` moves keeps a name that no other
    // process of the group has.
    if (comptime thread.chan_names_ok) {
        const base: u32 = @truncate(st.id << 16);
        w.group.chan_names.next.store(base, .monotonic);
        w.group.chan_names.next_sock.store(base, .monotonic);
    }
    c.w = w;
    c.caller = .{ .a = a, .out = .{ .ctx = &c, .write = Child.write }, .w = w };
    isobroker.install(&x, &c.caller) catch return 2;
    // `-caps` with no `thread`: the child has no `thread::send` to the
    // parent and no `tsv`.
    if (caps & thread_bit == 0) thread.dropThreadCommands(&x) catch return 2;
    w.group.remote = c.remote();
    if (comptime !thread.uk) {
        if (!jail(a, &x, st, hosts)) return 2;
    }
    // After the sandbox, so a sandbox that refuses executable memory
    // leaves the interpreter with no JIT.
    if (st.jit == 1) _ = x.enableJit(.{});
    // The child counts its own use, and sends it in `USAGE` at its end.
    // A parent with no meter drops the frame.
    var child_meter: meter_mod.Meter = .{ .gpa = a, .name = &.{} };
    child_meter.refs.store(2, .monotonic);
    meter_mod.attach(&x, &child_meter, 0);
    x.meter_mark = st.compute;
    defer {
        x.meter = null;
        for (child_meter.net.keys()) |k| a.free(k);
        child_meter.net.deinit(a);
    }
    if (comptime probe.enabled) if (attach) |d| if (d.payload.len > 0) {
        c.dbg = dap.startChild(a, &x, d.payload, st.script, .{ .ctx = &c, .write = Child.dbgWrite }) catch null;
    };
    defer if (comptime probe.enabled) if (c.dbg) |d| dap.endChild(d);
    if (!link.write(a, .ready, 0, "")) return 2;

    // The unikernel has no threads: each wait of the interpreter reads
    // one frame (`uk/wait.zig`).
    const reader = if (comptime thread.uk) ukPumpOn(&c) else std.Thread.spawn(.{}, childReader, .{&c}) catch return 2;
    const r = if (st.script.len > 0) probe.evalDebug(&x, st.script) else thread.topScope(&x, thread.waitLoop, .{&x});
    if (r) |_| {} else |e| thread.endError(w, &x, e);
    // The counts of the child for the meter of the parent.
    meter_mod.sync(&x);
    var counts: [meter_mod.Counts.frame_len]u8 = undefined;
    child_meter.counts.encode(&counts);
    _ = link.write(a, .usage, 0, &counts);
    var o: Out = .{ .a = a };
    o.int(i64, w.status) catch {};
    _ = link.write(a, .exit, 0, o.list.items);
    o.deinit();
    // The parent answers with goodbye, or closes.
    if (comptime thread.uk) {
        while (!c.done) ukPump();
    } else reader.join();
    w.group.remote = null;
    return 0;
}

/// The capabilities of a thread in the unikernel: `thread`, whose calls
/// go to the parent, child interps, and the clock and the event loop of
/// `uk/hosts.zig`.
pub const uk_caps: u32 = @backingInt(interp.Capability.thread) | @backingInt(interp.Capability.interp) |
    @backingInt(interp.Capability.clock) | @backingInt(interp.Capability.event);

/// The bootstrap secret of the command line of the guest.
fn ukSecret() ?[32]u8 {
    const hex = @import("uk/uk.zig").param("ztcl.secret") orelse return null;
    var out: [32]u8 = undefined;
    const got = std.fmt.hexToBytes(&out, hex) catch return null;
    if (got.len != 32) return null;
    return out;
}

var uk_child: ?*Child = null;

fn ukPumpOn(c: *Child) void {
    uk_child = c;
    const wt = @import("uk/wait.zig");
    wt.pump = ukPump;
    wt.poll_fn = ukPoll;
    wt.ready_fn = ukReady;
    if (c.w.it) |x| @import("uk/cpu.zig").uk_limit_word = @intFromPtr(&x.mem_limit);
}

fn ukReady() bool {
    const c = uk_child orelse return false;
    return !c.done and (c.link.conn.buffered() or @import("uk/vsock.zig").readable());
}

/// Runs each whole frame that waits, with no sleep.
fn ukPoll() void {
    const c = uk_child orelse return;
    while (ukReady()) {
        if (!childFrame(c)) childEnd(c);
    }
}

/// One step of the reader of the unikernel: a frame when one waits, or
/// a sleep to the next interrupt.
fn ukPump() void {
    const c = uk_child orelse return;
    if (c.done) return;
    const vs = @import("uk/vsock.zig");
    // The connection can hold whole frames that an earlier read took.
    if (!c.link.conn.buffered() and !vs.readable()) {
        vs.waitWork();
        if (!vs.readable()) return;
    }
    if (!childFrame(c)) childEnd(c);
}

/// The entry of the runner for `--iso-fd N`, or `--iso-handle 0x...` on
/// Windows.
pub fn childProcess(a: Allocator, fd: Fd, hosts: Hosts) u8 {
    if (comptime !supported) return 2;
    const t = iso.Transport.init(fd) catch return 2;
    return childMain(a, t, hosts);
}

test "START gives the jit byte after files" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |on| {
        var o: Out = .{ .a = a };
        defer o.deinit();
        try o.int(u64, 7);
        try o.int(u32, 0);
        try o.int(u64, 100);
        try o.int(u64, 1 << 20);
        try o.list.append(a, 0);
        try o.str("thread::wait");
        try startTail(&o, "/root", "src", true, on);
        const st = try readStart(o.list.items);
        try std.testing.expectEqual(@as(u64, 7), st.id);
        try std.testing.expectEqualStrings("/root", st.root);
        try std.testing.expectEqualStrings("src", st.cwd);
        try std.testing.expectEqual(@as(u8, 1), st.files);
        try std.testing.expectEqual(@as(u8, @intFromBool(on)), st.jit);
    }
}

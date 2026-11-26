//! The broker of isolated threads (ztcl#209, `docs/dev/isolation.md`):
//! `tsv`, the mutexes, and the conditions of a child process.
//!
//! The parent keeps the group. A child has no copy of its arrays and its
//! locks, so each of its commands on them is a request to the parent:
//!
//!   TSV     child: the words of the command, as one list value.
//!           parent: code i64, result value, error info, error code
//!           value, on the stream of the request.
//!   LOCK    child: what u8 (0 an array of `tsv`, 1 a mutex, 2 the mutex
//!           of `thread::eval`), name. The parent answers as for `TSV`.
//!   UNLOCK  child: no payload. It frees the last lock of `LOCK`, with
//!           no answer.
//!   CANCEL  child: no payload, on the stream of a request that waits.
//!           The wait of the broker ends with the error of a cancel.
//!
//! In the parent, a broker thread of each isolated thread runs the
//! requests in order, in an interpreter with only the commands of `tsv`
//! and of the locks. Its worker has the id of the isolated thread, so a
//! lock of the child is a lock of that thread, and the end of the thread
//! frees it as for any thread. A request runs only a command of a fixed
//! list, with its words as values: no substitution and no script.
//!
//! In the child, `install` puts commands of the same names in place of
//! the commands of the group of one thread. `tsv::lock` and
//! `thread::eval` run their script in the child between `LOCK` and
//! `UNLOCK`, and `tsv::object` makes a command of the child.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const interp = @import("interp.zig");
const thread = @import("thread.zig");
const tsv = @import("tsv.zig");
const tsync = @import("tsync.zig");
const iso = @import("isoproto.zig");
const value = @import("value.zig");
const Interp = interp.Interp;
const Error = interp.Error;
const Value = interp.Value;
const Cmd = interp.Cmd;
const Command = interp.Command;
const Worker = thread.Worker;
const Shared = thread.Shared;
const Allocator = std.mem.Allocator;

/// Writes a frame to the other side.
pub const Writer = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, kind: iso.Kind, stream: u32, payload: []const u8) bool,

    fn send(wr: Writer, kind: iso.Kind, stream: u32, payload: []const u8) bool {
        return wr.write(wr.ctx, kind, stream, payload);
    }
};

const what_array: u8 = 0;
const what_mutex: u8 = 1;
const what_eval: u8 = 2;

/// The commands that a request may run.
fn allowed(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "tsv::")) {
        const op = name[5..];
        for (tsv.ops) |o| if (std.mem.eql(u8, o.name, op)) return true;
        for ([_][]const u8{ "unset", "names", "array" }) |n| if (std.mem.eql(u8, n, op)) return true;
        return false;
    }
    for ([_][]const u8{ "thread::mutex", "thread::rwmutex", "thread::cond" }) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

// ---- Payloads ----

fn putInt(a: Allocator, l: *std.ArrayList(u8), comptime T: type, v: T) !void {
    try l.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(T, v)));
}

fn putStr(a: Allocator, l: *std.ArrayList(u8), s: []const u8) !void {
    try putInt(a, l, u32, @intCast(s.len));
    try l.appendSlice(a, s);
}

fn putShared(a: Allocator, l: *std.ArrayList(u8), s: Shared) !void {
    switch (s) {
        .int => |i| {
            try l.append(a, 'i');
            try putInt(a, l, i64, i);
        },
        .double => |d| {
            try l.append(a, 'd');
            try putInt(a, l, u64, @bitCast(d));
        },
        .str => |t| {
            try l.append(a, 's');
            try putStr(a, l, t);
        },
        .list => |x| {
            try l.append(a, 'l');
            try putInt(a, l, u32, @intCast(x.items.len));
            for (x.items) |e| try putShared(a, l, e);
        },
    }
}

fn readStr(r: *iso.Reader) iso.Error![]const u8 {
    return r.take(try r.int(u32));
}

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

/// The answer of a request: code, result, error info, error code.
fn answer(a: Allocator, code: i64, res: Shared, info: []const u8, ecode: Shared) ![]u8 {
    var l: std.ArrayList(u8) = .empty;
    errdefer l.deinit(a);
    try putInt(a, &l, i64, code);
    try putShared(a, &l, res);
    try putStr(a, &l, info);
    try putShared(a, &l, ecode);
    return l.toOwnedSlice(a);
}

// ---- The parent ----

const Lockd = union(enum) { array: tsv.Held, obj: *tsync.Obj };

pub const Broker = struct {
    gpa: Allocator,
    /// The proxy worker of the isolated thread.
    w: *Worker,
    out: Writer,
    lock: thread.Lock = .{},
    ev: thread.Event = .{},
    queue: std.ArrayList(iso.Frame) = .empty,
    os: ?std.Thread = null,
    ended: bool = false,
    /// The worker of the interpreter of the broker, with the id of `w`.
    bw: Worker = undefined,
    bx: ?*Interp = null,
    held: std.ArrayList(Lockd) = .empty,
    /// The stream of the last `CANCEL` of the child.
    cancel_for: std.atomic.Value(u32) = .init(0),

    pub fn init(gpa: Allocator, w: *Worker, out: Writer) Broker {
        return .{ .gpa = gpa, .w = w, .out = out };
    }

    /// Takes a frame of the child for the broker: `TSV`, `LOCK`,
    /// `UNLOCK`, or `CANCEL`. It owns `f.payload` from then on.
    pub fn post(b: *Broker, f: iso.Frame) void {
        if (f.kind == .cancel) {
            defer b.gpa.free(f.payload);
            b.cancel_for.store(f.stream, .seq_cst);
            if (b.bx != null) cancelWait(b);
            return;
        }
        b.lock.lock();
        if (b.ended) {
            b.lock.unlock();
            b.gpa.free(f.payload);
            return;
        }
        if (b.os == null) {
            b.bw = .{ .id = b.w.id, .group = b.w.group };
            b.os = std.Thread.spawn(.{}, main, .{b}) catch null;
            if (b.os == null) {
                b.lock.unlock();
                defer b.gpa.free(f.payload);
                if (f.kind != .unlock) fail(b, f.stream, "the broker of the thread did not start");
                return;
            }
        }
        b.queue.append(b.gpa, f) catch {
            b.lock.unlock();
            defer b.gpa.free(f.payload);
            if (f.kind != .unlock) fail(b, f.stream, "out of memory");
            return;
        };
        b.lock.unlock();
        b.ev.signal();
    }

    /// Ends the broker: a wait ends, the thread stops, and each lock of
    /// the child is free. Call it before the end of the worker.
    pub fn deinit(b: *Broker) void {
        b.lock.lock();
        b.ended = true;
        const os = b.os;
        b.lock.unlock();
        b.ev.signal();
        if (os) |t| {
            thread.stopWorker(&b.bw, thread.Flag.stop);
            t.join();
        }
        for (b.queue.items) |f| b.gpa.free(f.payload);
        b.queue.deinit(b.gpa);
    }
};

fn cancelWait(b: *Broker) void {
    b.bw.lock.lock();
    _ = b.bw.flags.fetchOr(thread.Flag.cancel, .acq_rel);
    b.bw.lock.unlock();
    b.bw.wake();
}

fn fail(b: *Broker, stream: u32, text: []const u8) void {
    const p = answer(b.gpa, 1, .{ .str = @constCast(text) }, text, .{ .str = @constCast("ZTCL ISOLATION BROKER") }) catch return;
    defer b.gpa.free(p);
    _ = b.out.send(.tsv, stream, p);
}

fn main(b: *Broker) void {
    while (true) {
        b.lock.lock();
        while (b.queue.items.len == 0 and !b.ended) b.ev.wait(&b.lock, thread.slice_ns);
        if (b.ended) {
            b.lock.unlock();
            break;
        }
        const f = b.queue.orderedRemove(0);
        b.lock.unlock();
        defer b.gpa.free(f.payload);
        handle(b, f);
    }
    // The locks of the child go free with the thread of the broker.
    while (b.held.pop()) |h| release(b, h);
    b.held.deinit(b.gpa);
    dropInterp(b);
}

fn release(b: *Broker, h: Lockd) void {
    switch (h) {
        .array => |x| x.release(),
        .obj => |o| tsync.unlockFor(b.bx.?, o),
    }
}

fn interpOf(b: *Broker) ?*Interp {
    if (b.bx) |x| return x;
    const x = b.gpa.create(Interp) catch return null;
    x.init(b.gpa) catch {
        b.gpa.destroy(x);
        return null;
    };
    x.worker = &b.bw;
    b.bw.it = x;
    tsv.register(x) catch {};
    tsync.register(x) catch {};
    b.bx = x;
    return x;
}

fn handle(b: *Broker, f: iso.Frame) void {
    if (f.kind == .unlock) {
        if (b.held.pop()) |h| release(b, h);
        return;
    }
    if (f.kind != .tsv and f.kind != .lock) return;
    const x = interpOf(b) orelse return fail(b, f.stream, "out of memory");
    // A cancel of an earlier request does not end this one, and a cancel
    // of this one that came before it does.
    _ = b.bw.flags.fetchAnd(thread.Flag.stop, .acq_rel);
    if (b.cancel_for.load(.seq_cst) == f.stream) cancelWait(b);
    x.result = Value.empty;
    const r = if (f.kind == .tsv) runWords(b, x, f.payload) else runLock(b, x, f.payload);
    var code: i64 = 0;
    var res = Value.empty;
    if (r) |v| {
        res = v;
    } else |e| {
        code = switch (e) {
            error.OutOfMemory => return fail(b, f.stream, "out of memory"),
            error.TclError => 1,
            error.TclReturn => 2,
            error.TclBreak => 3,
            error.TclContinue => 4,
            error.TclCustom => x.custom_code,
        };
        res = if (code == 3 or code == 4) Value.empty else x.result;
    }
    const a = b.gpa;
    var rs = thread.share(a, x, res) catch return fail(b, f.stream, "out of memory");
    defer rs.deinit(a);
    var es: Shared = .{ .str = @constCast("NONE") };
    var own_es = false;
    defer if (own_es) es.deinit(a);
    if (code == 1) {
        es = thread.share(a, x, x.error_code) catch return fail(b, f.stream, "out of memory");
        own_es = true;
    }
    const p = answer(a, code, rs, "", es) catch return;
    defer a.free(p);
    _ = b.out.send(.tsv, f.stream, p);
    // The arena of the interpreter grows with each request, so a large
    // one starts again when the child holds no lock.
    if (x.memUsed() > 1 << 20 and b.held.items.len == 0) dropInterp(b);
}

fn dropInterp(b: *Broker) void {
    const x = b.bx orelse return;
    x.worker = null;
    b.bw.it = null;
    x.deinit();
    b.gpa.destroy(x);
    b.bx = null;
}

fn runWords(b: *Broker, x: *Interp, payload: []const u8) Error!Value {
    const a = b.gpa;
    var r: iso.Reader = .{ .b = payload };
    var s = readShared(a, &r, 0) catch return x.fail("bad request of the child", .{});
    defer s.deinit(a);
    const items = switch (s) {
        .list => |l| l.items,
        else => return x.fail("bad request of the child", .{}),
    };
    if (items.len == 0) return x.fail("bad request of the child", .{});
    const head = switch (items[0]) {
        .str => |t| t,
        else => return x.fail("bad request of the child", .{}),
    };
    if (!allowed(head)) return x.failCode("ZTCL ISOLATION BROKER", "the broker does not run \"{s}\"", .{head});
    const ws = try x.alloc().alloc(Value, items.len);
    for (items, ws) |s_item, *v| v.* = try thread.unshare(x, s_item);
    return x.evalWords(ws);
}

fn runLock(b: *Broker, x: *Interp, payload: []const u8) Error!Value {
    var r: iso.Reader = .{ .b = payload };
    const what = (r.take(1) catch return x.fail("bad request of the child", .{}))[0];
    const name = readStr(&r) catch return x.fail("bad request of the child", .{});
    try b.held.ensureUnusedCapacity(b.gpa, 1);
    switch (what) {
        what_array => b.held.appendAssumeCapacity(.{ .array = try tsv.hold(x, name) }),
        what_mutex => b.held.appendAssumeCapacity(.{ .obj = try tsync.lockFor(x, name) }),
        what_eval => b.held.appendAssumeCapacity(.{ .obj = try tsync.lockFor(x, null) }),
        else => return x.fail("bad request of the child", .{}),
    }
    return Value.empty;
}

// ---- The child ----

/// The side of the child: one request at a time from its thread, and
/// the answers from its reader.
pub const Caller = struct {
    a: Allocator,
    out: Writer,
    w: *Worker,
    lock: thread.Lock = .{},
    ev: thread.Event = .{},
    next: u32 = 1,
    want: u32 = 0,
    got: ?[]u8 = null,
    gone: bool = false,

    /// An answer of the parent (a `TSV` frame). It owns `payload` from then on.
    pub fn deliver(c: *Caller, stream: u32, payload: []u8) void {
        c.lock.lock();
        if (stream == c.want and c.got == null) {
            c.got = payload;
            c.lock.unlock();
            c.ev.signal();
            return;
        }
        c.lock.unlock();
        c.a.free(payload);
    }

    /// The parent is gone: a wait ends.
    pub fn end(c: *Caller) void {
        c.lock.lock();
        c.gone = true;
        c.lock.unlock();
        c.ev.signal();
    }
};

/// Sends a request and waits for its answer. A cancel or a stop of the
/// thread during the wait sends `CANCEL`, and the thread gets its own
/// error after the answer.
fn request(it: *Interp, c: *Caller, kind: iso.Kind, payload: []const u8) Error!Value {
    c.lock.lock();
    const stream = c.next;
    c.next +%= 1;
    if (c.next == 0) c.next = 1;
    c.want = stream;
    c.got = null;
    const gone = c.gone;
    c.lock.unlock();
    if (gone or !c.out.send(kind, stream, payload)) return it.failCode("ZTCL ISOLATION BROKER", "the parent of the thread is gone", .{});
    var canceled = false;
    c.lock.lock();
    while (c.got == null and !c.gone) {
        if (!canceled and c.w.flags.load(.acquire) != 0) {
            canceled = true;
            c.lock.unlock();
            _ = c.out.send(.cancel, stream, "");
            c.lock.lock();
            continue;
        }
        c.ev.wait(&c.lock, thread.slice_ns);
    }
    const got = c.got;
    c.got = null;
    c.want = 0;
    c.lock.unlock();
    const p = got orelse return it.failCode("ZTCL ISOLATION BROKER", "the parent of the thread is gone", .{});
    defer c.a.free(p);
    if (canceled) try thread.checkFlags(it, c.w);
    return takeAnswer(it, c.a, p);
}

fn takeAnswer(it: *Interp, a: Allocator, p: []const u8) Error!Value {
    var r: iso.Reader = .{ .b = p };
    const bad = "bad answer of the parent";
    const code = r.int(i64) catch return it.fail(bad, .{});
    var res = readShared(a, &r, 0) catch return it.fail(bad, .{});
    defer res.deinit(a);
    _ = readStr(&r) catch return it.fail(bad, .{});
    var ecode = readShared(a, &r, 0) catch return it.fail(bad, .{});
    defer ecode.deinit(a);
    const v = try thread.unshare(it, res);
    switch (code) {
        0 => return v,
        1 => {
            it.result = v;
            it.error_code = try thread.unshare(it, ecode);
            return error.TclError;
        },
        2 => {
            it.result = v;
            it.ret_code = .ok;
            it.ret_level = 1;
            return error.TclReturn;
        },
        3 => return error.TclBreak,
        4 => return error.TclContinue,
        else => {
            it.result = v;
            it.custom_code = @intCast(@min(@max(code, 0), std.math.maxInt(u32)));
            return error.TclCustom;
        },
    }
}

/// The data of the command `argv[0]`.
fn dataOf(it: *Interp, argv: []const Value) Error!*anyopaque {
    const k = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name", .{});
    return k.ctx orelse it.fail("invalid command name", .{});
}

fn callerOf(it: *Interp, argv: []const Value) Error!*Caller {
    return @ptrCast(@alignCast(try dataOf(it, argv)));
}

/// Sends the words `argv` as a `TSV` request.
fn words(it: *Interp, c: *Caller, argv: []const Value) Error!Value {
    var list: std.ArrayList(Shared) = .empty;
    var s: Shared = .{ .list = list };
    defer s.deinit(c.a);
    for (argv) |v| {
        const x = thread.share(c.a, it, v) catch return it.fail("out of memory", .{});
        list.append(c.a, x) catch {
            var y = x;
            y.deinit(c.a);
            return it.fail("out of memory", .{});
        };
        s = .{ .list = list };
    }
    var p: std.ArrayList(u8) = .empty;
    defer p.deinit(c.a);
    putShared(c.a, &p, s) catch return it.fail("out of memory", .{});
    return request(it, c, .tsv, p.items);
}

fn lockReq(it: *Interp, c: *Caller, what: u8, name: []const u8) Error!void {
    var p: std.ArrayList(u8) = .empty;
    defer p.deinit(c.a);
    p.append(c.a, what) catch return it.fail("out of memory", .{});
    putStr(c.a, &p, name) catch return it.fail("out of memory", .{});
    _ = try request(it, c, .lock, p.items);
}

fn unlockReq(c: *Caller) void {
    _ = c.out.send(.unlock, 0, "");
}

fn cmdForward(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    return words(it, try callerOf(it, argv), argv);
}

fn runScript(it: *Interp, argv: []const Value) Error!Value {
    const text = if (argv.len == 1) try it.str(argv[0]) else try @import("cmds.zig").concat(it, argv);
    const s = try it.compile(try it.alloc().dupe(u8, text));
    return it.evalScript(s);
}

fn cmdLock(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 3) return it.wrongArgs("tsv::lock array arg ?arg...?");
    const c = try callerOf(it, argv);
    try lockReq(it, c, what_array, try it.str(argv[1]));
    defer unlockReq(c);
    return runScript(it, argv[2..]);
}

fn cmdEval(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var i: usize = 1;
    var name: ?[]const u8 = null;
    if (argv.len > 2 and std.mem.eql(u8, try it.str(argv[1]), "-lock")) {
        name = try it.str(argv[2]);
        i = 3;
    }
    if (i >= argv.len) return it.wrongArgs("thread::eval ?-lock <mutexHandle>? arg ?arg...?");
    const c = try callerOf(it, argv);
    if (name) |n| try lockReq(it, c, what_mutex, n) else try lockReq(it, c, what_eval, "");
    defer unlockReq(c);
    return runScript(it, argv[i..]);
}

/// The data of a command of `tsv::object` in the child.
const ObjData = struct { c: *Caller, arr: []const u8, key: []const u8 };

fn objCmd(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const d: *ObjData = @ptrCast(@alignCast(try dataOf(it, argv)));
    if (argv.len < 2) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} args\"", .{try it.str(argv[0])});
    const m = try it.str(argv[1]);
    const full = try std.fmt.allocPrint(it.alloc(), "tsv::{s}", .{m});
    if (!allowed(full) or std.mem.eql(u8, m, "names") or std.mem.eql(u8, m, "array")) return it.fail("invalid command name \"{s}\"", .{m});
    const w = try it.alloc().alloc(Value, argv.len + 1);
    w[0] = .{ .str = full };
    w[1] = .{ .str = d.arr };
    w[2] = .{ .str = d.key };
    @memcpy(w[3..], argv[2..]);
    return words(it, d.c, w);
}

fn cmdObject(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3) return it.wrongArgs("tsv::object array key ?args?");
    const c = try callerOf(it, argv);
    const a = it.alloc();
    const d = try a.create(ObjData);
    d.* = .{ .c = c, .arr = try a.dupe(u8, try it.str(argv[1])), .key = try a.dupe(u8, try it.str(argv[2])) };
    const name = try std.fmt.allocPrint(a, "::tsv::obj0x{x}", .{@intFromPtr(d)});
    const k = try a.create(Command);
    k.* = .{ .name = name[2..], .impl = .{ .native = objCmd }, .ctx = d };
    try it.commands.put(a, name[2..], k);
    it.epoch += 1;
    return .{ .str = name };
}

fn put(it: *Interp, c: *Caller, name: []const u8, f: interp.NativeFn) Allocator.Error!void {
    try it.register(name, f);
    const k = it.commands.get(name).?;
    k.ctx = c;
}

/// Puts the commands of the broker in the interpreter of the child.
pub fn install(it: *Interp, c: *Caller) Allocator.Error!void {
    inline for (tsv.ops) |o| {
        try put(it, c, "tsv::" ++ o.name, cmdForward);
        it.commands.get("tsv::" ++ o.name).?.tsv_op = true;
    }
    it.commands.counted = false;
    for ([_][]const u8{ "tsv::unset", "tsv::names", "tsv::array", "thread::mutex", "thread::rwmutex", "thread::cond" }) |n| try put(it, c, n, cmdForward);
    try put(it, c, "tsv::lock", cmdLock);
    try put(it, c, "tsv::object", cmdObject);
    try put(it, c, "thread::eval", cmdEval);
}

test "isobroker: the list of commands" {
    try std.testing.expect(allowed("tsv::set"));
    try std.testing.expect(allowed("tsv::keylget"));
    try std.testing.expect(allowed("thread::cond"));
    try std.testing.expect(!allowed("tsv::lock"));
    try std.testing.expect(!allowed("tsv::object"));
    try std.testing.expect(!allowed("exec"));
    try std.testing.expect(!allowed("set"));
}

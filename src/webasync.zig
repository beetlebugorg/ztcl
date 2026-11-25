//! The capability `thread` in the WebAssembly build with a memory in
//! each worker (ztcl-async.wasm). A page without cross-origin isolation
//! has no `SharedArrayBuffer`, so no thread can wait for another.
//!
//! Each thread is a worker of the host (web/ztcl-threads.mjs) with its
//! own instance and one interpreter. The main interpreter runs in a
//! worker too. A message is a script. A reply is the result in the
//! byte form below. The host routes both with `postMessage`, and the
//! worker runs one message at a time between the turns of its event
//! loop. So `thread::send -async` with a variable sets the variable
//! after the current script ends, when the reply comes.
//!
//! The main interpreter keeps the registry of the threads and the
//! thread pools. A pool job goes to an idle worker of the pool as a
//! message, and the reply marks the job done. Each command that waits
//! gives an error that names the missing cross-origin isolation.
//!
//! The byte form of a value keeps its kind: `i` and 8 bytes of an
//! integer, `d` and 8 bytes of a double, `s` with a 4-byte length and
//! the bytes of a string, or `l` with a 4-byte count and the items of a
//! list. Numbers are little-endian.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const cmds = @import("cmds.zig");
const thread = @import("thread.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Error = interp.Error;
const Cmd = interp.Cmd;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

extern "ztcl" fn now_ms() f64;
/// Makes a worker for thread `id` that runs `script`.
extern "ztcl" fn thread_create(id: u32, ptr: [*]const u8, len: usize) void;
/// Sends a script to thread `id`, or to each other thread for 0. A
/// token that is not 0 asks for a reply.
extern "ztcl" fn thread_send(id: u32, ptr: [*]const u8, len: usize, token: u32) void;
/// Ends the worker after the current message.
extern "ztcl" fn thread_end() void;

pub fn nowMicros(_: ?*anyopaque) i64 {
    return @intFromFloat(now_ms() * 1000);
}

const gpa = std.heap.wasm_allocator;

const Token = union(enum) {
    /// A variable of this interpreter gets the result.
    variable: []u8,
    /// A job of a pool is done.
    job: u32,
};

const Job = struct {
    id: u32,
    pool: u32,
    script: []u8,
    detached: bool,
    /// The worker that runs the job, or 0.
    worker: u32 = 0,
    done: bool = false,
    code: i32 = 0,
    /// The result in the byte form.
    res: []u8 = &.{},
};

const PoolWorker = struct { id: u32, busy: bool };

const Pool = struct {
    id: u32,
    max: u32,
    init: []u8,
    refs: i32 = 0,
    workers: std.ArrayList(PoolWorker) = .empty,
    /// The jobs that wait for a worker, oldest first.
    queue: std.ArrayList(u32) = .empty,
};

/// The state of the one interpreter with the capability in this
/// instance.
const State = struct {
    self_id: u32 = 1,
    is_main: bool = true,
    next_id: u32 = 2,
    /// The main interpreter: the ids of the threads that run.
    alive: std.ArrayList(u32) = .empty,
    /// `thread::wait` ran in this thread.
    waiting: bool = false,
    refs: i32 = 0,
    next_token: u32 = 1,
    tokens: std.AutoHashMapUnmanaged(u32, Token) = .empty,
    next_pool: u32 = 1,
    pools: std.ArrayList(Pool) = .empty,
    next_job: u32 = 1,
    jobs: std.ArrayList(Job) = .empty,
    /// The reply of the last message in the byte form.
    msg: std.ArrayList(u8) = .empty,
};

var st: State = .{};

/// Sets the id of this thread. The host calls it after `ztcl_new`.
pub fn init(id: u32, is_main: bool) void {
    st.self_id = id;
    st.is_main = is_main;
}

pub fn waiting() bool {
    return st.waiting;
}

pub fn msgBytes() []const u8 {
    return st.msg.items;
}

// ---- The byte form ----

fn encode(it: *Interp, out: *std.ArrayList(u8), v: Value, depth: u32) Error!void {
    switch (v) {
        .int => |i| {
            try out.append(gpa, 'i');
            try out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(i64, i)));
        },
        .double => |d| {
            try out.append(gpa, 'd');
            try out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u64, @bitCast(d))));
        },
        .str => |s| try encodeStr(out, s),
        .list => |l| {
            // A deep list goes as its string form, as in thread.zig.
            if (depth >= 200) return encodeStr(out, try it.str(v));
            const items = l.items();
            try out.append(gpa, 'l');
            try out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(items.len))));
            for (items) |x| try encode(it, out, x, depth + 1);
        },
    }
}

fn encodeStr(out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(gpa, 's');
    try out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(s.len))));
    try out.appendSlice(gpa, s);
}

const Reader = struct {
    b: []const u8,
    i: usize = 0,

    fn take(r: *Reader, n: usize) ?[]const u8 {
        if (r.b.len - r.i < n) return null;
        defer r.i += n;
        return r.b[r.i..][0..n];
    }

    fn int(r: *Reader, comptime T: type) ?T {
        const s = r.take(@sizeOf(T)) orelse return null;
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }
};

/// Makes a value from the byte form. Bad bytes give an empty string.
fn decode(it: *Interp, r: *Reader) Allocator.Error!Value {
    const tag = (r.take(1) orelse return Value.empty)[0];
    switch (tag) {
        'i' => return .{ .int = r.int(i64) orelse return Value.empty },
        'd' => return .{ .double = @bitCast(r.int(u64) orelse return Value.empty) },
        's' => {
            const n = r.int(u32) orelse return Value.empty;
            const s = r.take(n) orelse return Value.empty;
            return .{ .str = try it.alloc().dupe(u8, s) };
        },
        'l' => {
            const n = r.int(u32) orelse return Value.empty;
            // Each item has at least one byte.
            if (n > r.b.len - r.i) return Value.empty;
            const buf = try it.alloc().alloc(Value, n);
            for (buf) |*x| x.* = try decode(it, r);
            return value.wrapList(it.alloc(), buf);
        },
        else => return Value.empty,
    }
}

fn decodeBytes(it: *Interp, b: []const u8) Allocator.Error!Value {
    var r: Reader = .{ .b = b };
    return decode(it, &r);
}

// ---- Messages ----

fn runScript(it: *Interp, script: []const u8) cmds.Caught {
    // `catch` cannot catch the errors of the limits, so they come here.
    // A thread that passes a limit ends after the reply, as on the
    // native platforms.
    return thread.atGlobal(it, cmds.runCaught, .{ it, it.compile(script) }) catch |e| {
        if (!st.is_main) thread_end();
        return .{ .code = 1, .res = if (e == error.TclError) it.result else .{ .str = @errorName(e) } };
    };
}

/// Runs a script of another thread at the global level. The reply is
/// in `msgBytes`. An error with no token goes to the output.
pub fn recv(it: *Interp, token: u32, script: []const u8) i32 {
    const c = runScript(it, script);
    st.msg.clearRetainingCapacity();
    encode(it, &st.msg, c.res, 0) catch {
        st.msg.clearRetainingCapacity();
        encodeStr(&st.msg, "out of memory") catch {};
    };
    if (c.code == 1 and token == 0) if (it.output) |out| {
        const info = it.str(c.error_info) catch "";
        var buf: [64]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "Error from thread tid0x{x}\n", .{st.self_id}) catch "";
        out.write(out.ctx, head);
        out.write(out.ctx, if (info.len > 0) info else it.str(c.res) catch "");
        out.write(out.ctx, "\n");
    };
    return @intCast(std.math.clamp(c.code, 0, std.math.maxInt(i32)));
}

/// A reply to a token of this thread.
pub fn reply(it: *Interp, token: u32, code: i32, bytes: []const u8) void {
    const t = st.tokens.fetchRemove(token) orelse return;
    switch (t.value) {
        .variable => |name| {
            defer gpa.free(name);
            const v = decodeBytes(it, bytes) catch return;
            _ = thread.atGlobal(it, Interp.setVar, .{ it, name, v }) catch {};
        },
        .job => |id| {
            const j = findJob(id) orelse return;
            j.done = true;
            j.code = code;
            j.res = gpa.dupe(u8, bytes) catch &.{};
            const p = findPool(j.pool) orelse return;
            for (p.workers.items) |*w| {
                if (w.id == j.worker) w.busy = false;
            }
            if (j.detached) dropJob(id);
            dispatch(p) catch {};
        },
    }
}

/// Thread `id` ended.
pub fn gone(id: u32) void {
    for (st.alive.items, 0..) |x, i| if (x == id) {
        _ = st.alive.swapRemove(i);
        break;
    };
    for (st.pools.items) |*p| for (p.workers.items, 0..) |w, i| if (w.id == id) {
        _ = p.workers.swapRemove(i);
        break;
    };
}

fn addToken(t: Token) Allocator.Error!u32 {
    const n = st.next_token;
    st.next_token +%= 1;
    if (st.next_token == 0) st.next_token = 1;
    try st.tokens.put(gpa, n, t);
    return n;
}

fn send(id: u32, script: []const u8, token: u32) void {
    thread_send(id, script.ptr, script.len, token);
}

// ---- The commands ----

fn isolation(it: *Interp, what: []const u8) Error {
    return it.failCode("THREAD ISOLATION", "{s} needs a cross-origin isolated page (COOP and COEP headers)", .{what});
}

fn waits(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    return isolation(it, try it.str(argv[0]));
}

fn idText(it: *Interp, id: u32) Error!Value {
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "tid0x{x}", .{id}) };
}

fn parseId(it: *Interp, v: Value) Error!u32 {
    const text = try it.str(v);
    const id = thread.parseId(text);
    if (id == 0 or id > std.math.maxInt(u32)) return it.fail("invalid thread handle \"{s}\"", .{text});
    return @intCast(id);
}

fn isAlive(id: u32) bool {
    if (id == st.self_id) return true;
    for (st.alive.items) |x| if (x == id) return true;
    return false;
}

/// Gives a new thread id and starts its worker.
fn startThread(script: []const u8) Allocator.Error!u32 {
    const id = st.next_id;
    st.next_id += 1;
    try st.alive.append(gpa, id);
    thread_create(id, script.ptr, script.len);
    return id;
}

fn cmdCreate(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var preserved = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (eql(u8, o, "-joinable")) return isolation(it, "thread::create -joinable");
        if (eql(u8, o, "-preserved")) {
            preserved = true;
        } else if (eql(u8, o, "--")) {
            i += 1;
            break;
        } else break;
    }
    if (argv.len - i > 1) return it.wrongArgs("thread::create ?-joinable? ?-preserved? ?script?");
    if (!st.is_main) return isolation(it, "thread::create in a thread");
    const max = it.thread_limits.max_threads;
    if (st.alive.items.len >= max) return it.failCode("THREAD LIMIT", "too many threads: the limit is {d}", .{max});
    const body = if (i < argv.len) try it.str(argv[i]) else "thread::wait";
    const script = try std.fmt.allocPrint(it.alloc(), "{s}{s}", .{ if (preserved) "thread::preserve\n" else "", body });
    return idText(it, try startThread(script));
}

fn cmdId(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("thread::id");
    return idText(it, st.self_id);
}

fn cmdNames(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("thread::names");
    if (!st.is_main) return isolation(it, "thread::names in a thread");
    const buf = try it.alloc().alloc(Value, st.alive.items.len + 1);
    for (st.alive.items, 0..) |x, i| buf[i] = try idText(it, x);
    buf[buf.len - 1] = try idText(it, st.self_id);
    return value.wrapList(it.alloc(), buf);
}

fn cmdExists(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("thread::exists id");
    if (!st.is_main) return isolation(it, "thread::exists in a thread");
    const id = parseId(it, argv[1]) catch return .{ .int = 0 };
    return .{ .int = @intFromBool(isAlive(id)) };
}

fn cmdSend(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var i: usize = 1;
    var async_send = false;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (eql(u8, o, "-async")) {
            async_send = true;
        } else if (eql(u8, o, "-head")) {
            // The host runs the messages in order, so -head has no effect.
        } else if (eql(u8, o, "--")) {
            i += 1;
            break;
        } else break;
    }
    const n = argv.len - i;
    if (n < 2 or n > 3) return it.wrongArgs("thread::send ?-async? ?-head? id script ?varName?");
    if (!async_send) return isolation(it, "thread::send without -async");
    const id = try parseId(it, argv[i]);
    if (st.is_main and !isAlive(id)) return it.fail("thread \"tid0x{x}\" does not exist", .{id});
    const script = try it.str(argv[i + 1]);
    var token: u32 = 0;
    if (n == 3) token = try addToken(.{ .variable = try gpa.dupe(u8, try it.str(argv[i + 2])) });
    send(id, script, token);
    return Value.empty;
}

fn cmdBroadcast(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("thread::broadcast script");
    send(0, try it.str(argv[1]), 0);
    return Value.empty;
}

fn cmdWait(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("thread::wait");
    if (st.is_main) return isolation(it, "thread::wait in the main thread");
    // The worker stays after its script and runs the messages that come.
    st.waiting = true;
    return Value.empty;
}

fn cmdPreserve(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len > 2) return it.wrongArgs("thread::preserve ?id?");
    if (argv.len == 2) {
        const id = try parseId(it, argv[1]);
        if (id != st.self_id) {
            send(id, "thread::preserve", 0);
            return Value.empty;
        }
    }
    st.refs += 1;
    return .{ .int = st.refs };
}

fn cmdRelease(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var i: usize = 1;
    if (i < argv.len and eql(u8, try it.str(argv[i]), "-wait")) return isolation(it, "thread::release -wait");
    if (argv.len - i > 1) return it.wrongArgs("thread::release ?-wait? ?id?");
    if (i < argv.len) {
        const id = try parseId(it, argv[i]);
        if (id != st.self_id) {
            if (st.is_main and !isAlive(id)) return it.fail("thread \"tid0x{x}\" does not exist", .{id});
            send(id, "thread::release", 0);
            return .{ .int = 0 };
        }
        i += 1;
    }
    st.refs -= 1;
    if (st.refs <= 0 and !st.is_main) thread_end();
    return .{ .int = @max(st.refs, 0) };
}

// ---- The thread pools ----

fn findPool(id: u32) ?*Pool {
    for (st.pools.items) |*p| if (p.id == id) return p;
    return null;
}

fn findJob(id: u32) ?*Job {
    for (st.jobs.items) |*j| if (j.id == id) return j;
    return null;
}

fn dropJob(id: u32) void {
    for (st.jobs.items, 0..) |j, i| if (j.id == id) {
        gpa.free(j.script);
        gpa.free(j.res);
        _ = st.jobs.swapRemove(i);
        return;
    };
}

fn poolOf(it: *Interp, v: Value) Error!*Pool {
    const name = try it.str(v);
    if (std.mem.startsWith(u8, name, "tpool0x")) {
        if (std.fmt.parseInt(u32, name[7..], 16)) |id| {
            if (findPool(id)) |p| return p;
        } else |_| {}
    }
    return it.fail("can not find threadpool \"{s}\"", .{name});
}

/// Gives each waiting job of `p` to an idle worker, and starts workers
/// up to the maximum.
fn dispatch(p: *Pool) Allocator.Error!void {
    while (p.queue.items.len > 0) {
        var w: ?*PoolWorker = null;
        for (p.workers.items) |*x| if (!x.busy) {
            w = x;
            break;
        };
        if (w == null) {
            if (p.workers.items.len >= p.max) return;
            const script = try std.fmt.allocPrint(gpa, "{s}\nthread::wait", .{p.init});
            defer gpa.free(script);
            const id = try startThread(script);
            try p.workers.append(gpa, .{ .id = id, .busy = false });
            w = &p.workers.items[p.workers.items.len - 1];
        }
        const jid = p.queue.orderedRemove(0);
        const j = findJob(jid) orelse continue;
        w.?.busy = true;
        j.worker = w.?.id;
        send(w.?.id, j.script, try addToken(.{ .job = jid }));
    }
}

fn cmdPoolCreate(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const usage = "tpool::create ?-minworkers count? ?-maxworkers count? ?-initcmd script? ?-exitcmd script? ?-idletime seconds?";
    if (argv.len % 2 != 1) return it.wrongArgs(usage);
    if (!st.is_main) return isolation(it, "tpool::create in a thread");
    var max: u32 = 4;
    var init_cmd: []const u8 = "";
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        const o = try it.str(argv[i]);
        if (eql(u8, o, "-maxworkers")) {
            const n = try it.int(argv[i + 1]);
            max = @intCast(std.math.clamp(n, 1, 1 << 16));
        } else if (eql(u8, o, "-initcmd")) {
            init_cmd = try it.str(argv[i + 1]);
        } else if (eql(u8, o, "-minworkers") or eql(u8, o, "-exitcmd") or eql(u8, o, "-idletime")) {
            // The workers start on demand and stay until the release.
        } else return it.wrongArgs(usage);
    }
    const id = st.next_pool;
    st.next_pool += 1;
    try st.pools.append(gpa, .{ .id = id, .max = max, .init = try gpa.dupe(u8, init_cmd) });
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "tpool0x{x}", .{id}) };
}

fn cmdPoolPost(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var detached = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (eql(u8, o, "-detached")) {
            detached = true;
        } else if (!eql(u8, o, "-nowait")) break;
    }
    if (argv.len - i != 2) return it.wrongArgs("tpool::post ?-detached? ?-nowait? tpoolId script");
    if (!st.is_main) return isolation(it, "tpool::post in a thread");
    const p = try poolOf(it, argv[i]);
    const id = st.next_job;
    st.next_job += 1;
    try st.jobs.append(gpa, .{ .id = id, .pool = p.id, .script = try gpa.dupe(u8, try it.str(argv[i + 1])), .detached = detached });
    try p.queue.append(gpa, id);
    try dispatch(p);
    return if (detached) Value.empty else .{ .int = id };
}

fn cmdPoolGet(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3) return it.wrongArgs("tpool::get tpoolId jobId");
    const p = try poolOf(it, argv[1]);
    const id = try it.int(argv[2]);
    const j = (if (id > 0 and id <= std.math.maxInt(u32)) findJob(@intCast(id)) else null) orelse return it.fail("no such job \"{d}\"", .{id});
    if (j.pool != p.id) return it.fail("no such job \"{d}\"", .{id});
    if (!j.done) return isolation(it, "tpool::get of a job that runs");
    const v = try decodeBytes(it, j.res);
    const code = j.code;
    dropJob(j.id);
    if (code == 1) {
        it.result = v;
        return error.TclError;
    }
    return v;
}

fn cmdPoolNames(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("tpool::names");
    const buf = try it.alloc().alloc(Value, st.pools.items.len);
    for (st.pools.items, buf) |p, *b| b.* = .{ .str = try std.fmt.allocPrint(it.alloc(), "tpool0x{x}", .{p.id}) };
    return value.wrapList(it.alloc(), buf);
}

fn cmdPoolPreserve(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("tpool::preserve tpoolId");
    const p = try poolOf(it, argv[1]);
    p.refs += 1;
    return .{ .int = p.refs };
}

fn cmdPoolRelease(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("tpool::release tpoolId");
    const p = try poolOf(it, argv[1]);
    p.refs -= 1;
    if (p.refs > 0) return .{ .int = p.refs };
    for (p.workers.items) |w| send(w.id, "thread::release", 0);
    var k: usize = 0;
    while (k < st.jobs.items.len) {
        if (st.jobs.items[k].pool == p.id) dropJob(st.jobs.items[k].id) else k += 1;
    }
    const id = p.id;
    gpa.free(p.init);
    p.workers.deinit(gpa);
    p.queue.deinit(gpa);
    for (st.pools.items, 0..) |x, i| if (x.id == id) {
        _ = st.pools.orderedRemove(i);
        break;
    };
    return .{ .int = 0 };
}

/// The commands that wait. Each gives the error of the isolation.
const waiting_cmds = [_][]const u8{
    "thread::join",      "thread::cancel",    "thread::eval", "thread::mutex",
    "thread::rwmutex",   "thread::cond",      "thread::exit", "thread::unwind",
    "thread::errorproc", "thread::configure", "tpool::wait",  "tpool::cancel",
    "tpool::suspend",    "tpool::resume",     "tsv::set",     "tsv::get",
    "tsv::unset",        "tsv::exists",       "tsv::pop",     "tsv::move",
    "tsv::names",        "tsv::incr",         "tsv::append",  "tsv::lappend",
    "tsv::linsert",      "tsv::lreplace",     "tsv::llength", "tsv::lindex",
    "tsv::lrange",       "tsv::lsearch",      "tsv::lset",    "tsv::lpop",
    "tsv::lpush",        "tsv::array",        "tsv::lock",    "tsv::object",
    "tsv::handlers",     "tsv::keylset",      "tsv::keylget", "tsv::keylkeys",
    "tsv::keyldel",
};

pub fn register(it: *Interp) Allocator.Error!void {
    if (it.parent != null) return;
    const list = .{
        .{ "thread::create", cmdCreate },
        .{ "thread::id", cmdId },
        .{ "thread::names", cmdNames },
        .{ "thread::exists", cmdExists },
        .{ "thread::send", cmdSend },
        .{ "thread::broadcast", cmdBroadcast },
        .{ "thread::wait", cmdWait },
        .{ "thread::preserve", cmdPreserve },
        .{ "thread::release", cmdRelease },
        .{ "tpool::create", cmdPoolCreate },
        .{ "tpool::post", cmdPoolPost },
        .{ "tpool::get", cmdPoolGet },
        .{ "tpool::names", cmdPoolNames },
        .{ "tpool::preserve", cmdPoolPreserve },
        .{ "tpool::release", cmdPoolRelease },
    };
    inline for (list) |e| try it.register(e[0], e[1]);
    for (waiting_cmds) |name| try it.register(name, waits);
}

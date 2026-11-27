//! `ztcl debug --dap`: a debugger over the Debug Adapter Protocol on
//! stdin and stdout, for editors such as VS Code.
//!
//! A message has the header `Content-Length: N`, an empty line, and N
//! bytes of JSON. The server answers `initialize`, `launch`,
//! `setBreakpoints`, `setFunctionBreakpoints`,
//! `setExceptionBreakpoints`, `configurationDone`, `threads`,
//! `stackTrace`, `scopes`, `variables`, `continue`, `next`, `stepIn`,
//! `stepOut`, `pause`, `evaluate`, `disconnect`, and `terminate`. The
//! custom request `ztclReload` defines the procs of the program file
//! again.
//!
//! The run starts at `configurationDone`. The debugger uses the line
//! hook of `probe.zig`: each line of a proc and each command of the top
//! level of the program file calls `onLine`. At a stop, `onLine` sends
//! the event `stopped` and reads requests until a request continues the
//! run. A stop is a breakpoint, a function breakpoint at the entry of a
//! proc, the next line of a step, an error with the exception filter
//! `error`, or a `pause`. A body of the top level, such as the body of a
//! `while`, has a stop at each line too. While the program runs, `poll`
//! tells when a request waits: `onLine` then reads it, so `pause` and
//! `setBreakpoints` work in a run. The output of `puts` goes to the
//! event `output`, because stdout has the protocol.
//!
//! Threads: each interpreter of `thread::create` gets the line hook
//! (`probe.threads`), and a `Target` with a queue. With `reader`, a
//! thread of the server reads stdin: a request for a thread goes to its
//! queue, and the others run in the reader. A thread checks its queue
//! at each line, and waits on it at a stop, so each thread stops on its
//! own. An isolated thread has a server of its own in the child
//! (`startChild`), over DEBUG frames: the parent sends the requests of
//! the thread there and passes the answers and events on.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const probe = @import("probe.zig");
const thread = @import("thread.zig");

const Interp = interp.Interp;
const Value = value.Value;
const Allocator = std.mem.Allocator;
const json = std.json;
const Lock = thread.Lock;

pub const ReadFn = *const fn (ctx: ?*anyopaque, path: []const u8, a: Allocator) anyerror![]u8;
pub const Sink = probe.MsgSink;

const Mode = enum { run, step_in, next, step_out };

const LineBreak = struct { line: u32, cond: []const u8 };

/// The place of a frame at its last line: the line of the file, or the
/// line of the body of a proc that is in no file.
const Place = struct { line: u32, in_file: bool };

/// A frame id is the number of the thread and the index of the frame
/// in the stack of its stop. A reference of variables is twice the
/// frame id, and 1 for the locals or 2 for the globals.
const frame_bits = 12;
const max_frames = 1 << frame_bits;

/// A thread of the program: an interpreter of this process, or the
/// child of an isolated thread, which has a server of its own.
pub const Target = struct {
    s: *Server,
    /// The thread id of DAP: the id of `thread::id`, or 1.
    id: u64,
    /// The number of the thread in its frame ids.
    num: u64,
    it: ?*Interp = null,
    /// The DEBUG frames to the child of an isolated thread.
    remote: ?Sink = null,
    /// The requests for this thread, in `s.gpa`. `s.lock` guards it.
    queue: std.ArrayList([]u8) = .empty,
    /// The length of `queue`, for a check with no lock at each line.
    mail: std.atomic.Value(u32) = .init(0),
    ev: thread.Event = .{},
    mode: Mode = .run,
    /// The level of the frame at the start of a step.
    depth: u32 = 0,
    /// The last line of each frame of the stack.
    places: std.AutoHashMapUnmanaged(*interp.Frame, Place) = .empty,
    /// The frames at the stop, from the innermost.
    frames: std.ArrayList(*interp.Frame) = .empty,
    /// A `pause` came while the thread ran: the next line stops.
    pause: std.atomic.Value(bool) = .init(false),
    /// The thread runs a script, so a `disconnect` cancels it.
    running: std.atomic.Value(bool) = .init(false),
    stopped: bool = false,
    /// The lines since the last call of `poll`.
    ticks: u32 = 0,
    /// The line of the program file before line 1 of the script of the
    /// thread, or null when the script is not in the file.
    line_off: ?u32 = 0,

    fn deinit(t: *Target, gpa: Allocator) void {
        for (t.queue.items) |b| gpa.free(b);
        t.queue.deinit(gpa);
        t.places.deinit(gpa);
        t.frames.deinit(gpa);
    }
};

pub const Server = struct {
    it: *Interp,
    gpa: Allocator,
    /// The requests, when no other thread calls `deliver`.
    in: ?*std.Io.Reader = null,
    /// The answers and events, when `sink` is null.
    out: ?*std.Io.Writer = null,
    read: ReadFn = noRead,
    read_ctx: ?*anyopaque = null,
    /// The program of `launch`, or of the command line.
    program: ?[]const u8 = null,
    text: []const u8 = "",
    /// The copy of the program of `launch`, in `gpa`.
    program_buf: ?[]u8 = null,
    /// `text` is in `gpa`.
    text_owned: bool = false,
    stop_on_entry: bool = false,
    seq: u64 = 1,
    breaks: std.ArrayList(LineBreak) = .empty,
    funcs: std.ArrayList([]const u8) = .empty,
    /// The client sent `disconnect` or `terminate`, or stdin closed.
    done: std.atomic.Value(bool) = .init(false),
    /// Stop at the start of each error (the exception filter `error`).
    break_errors: std.atomic.Value(bool) = .init(false),
    /// Stop at the start of an error that no `catch` or `try` catches
    /// (the exception filter `uncaught`).
    break_uncaught: std.atomic.Value(bool) = .init(false),
    /// True when a request waits on `in`. Null: the server reads
    /// requests only at a stop.
    poll: ?*const fn (ctx: ?*anyopaque) bool = null,
    poll_ctx: ?*anyopaque = null,
    /// The lines between two calls of `poll`: a poll is a system call.
    poll_every: u32 = 256,
    exit_code: i64 = 0,
    /// A thread of the server reads `in` and routes each request to its
    /// thread, so a request reaches a thread that runs, and each thread
    /// can stop. False: a thread that waits for a request reads `in`.
    reader: bool = false,
    /// The messages go to `sink` instead of `out`.
    sink: ?Sink = null,
    /// The server of the child of an isolated thread: another thread
    /// calls `deliver`, and the parent has the other threads.
    child: bool = false,
    /// Guards `seq`, `out`, `breaks`, `funcs`, the targets, and their
    /// queues.
    lock: Lock = .{},
    /// One thread at a time reads `in`.
    in_lock: Lock = .{},
    main: Target = undefined,
    targets: std.ArrayList(*Target) = .empty,
    next_num: u64 = 1,
};

fn noRead(_: ?*anyopaque, _: []const u8, _: Allocator) anyerror![]u8 {
    return error.FileNotFound;
}

// ---- The wire ----

/// The body of the next message, in `a`, or null at the end of stdin.
fn readMessage(in: *std.Io.Reader, a: Allocator) !?[]u8 {
    var len: ?usize = null;
    while (true) {
        const line = in.takeDelimiterExclusive('\n') catch return null;
        _ = in.take(1) catch {};
        const t = std.mem.trimEnd(u8, line, "\r");
        if (t.len == 0) {
            if (len != null) break;
            continue;
        }
        const key = "Content-Length:";
        if (std.ascii.startsWithIgnoreCase(t, key)) {
            len = std.fmt.parseInt(usize, std.mem.trim(u8, t[key.len..], " "), 10) catch return error.BadHeader;
        }
    }
    const body = try a.alloc(u8, len.?);
    in.readSliceAll(body) catch {
        a.free(body);
        return null;
    };
    return body;
}

/// Writes one message. The caller holds `s.lock`.
fn writeBody(s: *Server, body: []const u8) !void {
    if (s.sink) |k| {
        _ = k.write(k.ctx, body);
        return;
    }
    const out = s.out orelse return;
    try out.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try out.writeAll(body);
    try out.flush();
}

/// Sends `msg` with the next number of the server in front.
fn sendMsg(s: *Server, a: Allocator, msg: anytype) !void {
    s.lock.lock();
    defer s.lock.unlock();
    const seq = s.seq;
    s.seq += 1;
    const body = try json.Stringify.valueAlloc(a, msg, .{ .emit_null_optional_fields = false });
    // Each message has `seq` first, so the number goes in as text.
    const full = try std.fmt.allocPrint(a, "{{\"seq\":{d},{s}", .{ seq, body[1..] });
    try writeBody(s, full);
}

fn respond(s: *Server, a: Allocator, req: json.ObjectMap, ok: bool, msg: ?[]const u8, body: anytype) !void {
    const rseq = intOf(req, "seq") orelse 0;
    // A request of the parent of a child with no number needs no answer.
    if (rseq == 0) return;
    try sendMsg(s, a, .{
        .type = "response",
        .request_seq = rseq,
        .success = ok,
        .command = strOf(req, "command") orelse "",
        .message = msg,
        .body = body,
    });
}

fn event(s: *Server, a: Allocator, name: []const u8, body: anytype) !void {
    try sendMsg(s, a, .{ .type = "event", .event = name, .body = body });
}

fn strOf(o: ?json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = (o orelse return null).get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn intOf(o: ?json.ObjectMap, key: []const u8) ?i64 {
    const v = (o orelse return null).get(key) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn objOf(o: ?json.ObjectMap, key: []const u8) ?json.ObjectMap {
    const v = (o orelse return null).get(key) orelse return null;
    return if (v == .object) v.object else null;
}

fn args(req: json.ObjectMap) ?json.ObjectMap {
    return objOf(req, "arguments");
}

fn listOf(o: ?json.ObjectMap, key: []const u8) []const json.Value {
    const v = (o orelse return &.{}).get(key) orelse return &.{};
    return if (v == .array) v.array.items else &.{};
}

// ---- The loop ----

fn output(ctx: ?*anyopaque, bytes: []const u8) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    event(s, arena.allocator(), "output", .{ .category = "stdout", .output = bytes }) catch {};
}

fn mainId(it: *Interp) u64 {
    if (comptime !thread.supported) return 1;
    return if (thread.workerOf(it)) |w| w.id else 1;
}

/// Makes the target of the main thread. A thread that calls `deliver`
/// while `serve` starts reads `main` after this, under the lock.
fn begin(s: *Server) !void {
    s.lock.lock();
    defer s.lock.unlock();
    s.main = .{ .s = s, .id = mainId(s.it), .num = 0, .it = s.it };
    try s.targets.append(s.gpa, &s.main);
}

/// True once `serve` has made the target of the main thread. A request
/// from another thread before then reads a `main` with no value.
pub fn started(s: *Server) bool {
    s.lock.lock();
    defer s.lock.unlock();
    return s.targets.items.len > 0;
}

fn end(s: *Server) void {
    if (s.text_owned) s.gpa.free(s.text);
    if (s.program_buf) |b| s.gpa.free(b);
    for (s.breaks.items) |b| s.gpa.free(b.cond);
    for (s.funcs.items) |f| s.gpa.free(f);
    s.breaks.deinit(s.gpa);
    s.funcs.deinit(s.gpa);
    for (s.targets.items) |t| {
        t.deinit(s.gpa);
        if (t != &s.main) s.gpa.destroy(t);
    }
    s.targets.deinit(s.gpa);
}

/// Serves requests until `disconnect` or the end of stdin.
pub fn serve(s: *Server) !void {
    try begin(s);
    defer end(s);
    // In a group of threads, each thread writes through the output of
    // the group.
    const group = thread.workerOf(s.it);
    const prev = if (group) |w| w.group.output else s.it.output;
    if (group) |w| {
        w.group.out_lock.lock();
        w.group.output = .{ .ctx = s, .write = output };
        w.group.out_lock.unlock();
    } else s.it.output = .{ .ctx = s, .write = output };
    // A thread that runs on after the end writes to the output of before.
    defer if (group) |w| {
        w.group.out_lock.lock();
        w.group.output = prev;
        w.group.out_lock.unlock();
    } else {
        s.it.output = prev;
    };
    if (comptime builtin.single_threaded) s.reader = false;
    var box: ?*Box = null;
    if (comptime !builtin.single_threaded) if (s.reader) if (s.in) |in| {
        const b = try s.gpa.create(Box);
        b.* = .{ .s = s, .in = in, .gpa = s.gpa };
        const r = std.Thread.spawn(.{}, readLoop, .{b}) catch |e| {
            s.gpa.destroy(b);
            return e;
        };
        // The reader waits on stdin, maybe after the end of the server.
        r.detach();
        box = b;
    };
    defer if (box) |b| b.leave(true);
    while (take(&s.main)) |body| {
        defer s.gpa.free(body);
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const req = (json.parseFromSliceLeaky(json.Value, a, body, .{}) catch continue);
        if (req != .object) continue;
        const cmd = strOf(req.object, "command") orelse continue;
        if (eql(cmd, "configurationDone")) {
            try respond(s, a, req.object, true, null, null);
            try runProgram(s, a);
            continue;
        }
        _ = try local(&s.main, a, req.object, false);
    }
}

/// The part of the server that the reader thread holds. The reader can
/// outlive the server, so the server leaves the box at its end, and the
/// last of the two frees it.
const Box = struct {
    s: ?*Server,
    in: *std.Io.Reader,
    gpa: Allocator,
    lock: Lock = .{},
    refs: std.atomic.Value(u8) = .init(2),

    fn leave(b: *Box, server: bool) void {
        if (server) {
            b.lock.lock();
            b.s = null;
            b.lock.unlock();
        }
        if (b.refs.fetchSub(1, .acq_rel) == 1) b.gpa.destroy(b);
    }
};

/// The thread of `reader`: reads stdin and routes each request.
fn readLoop(b: *Box) void {
    defer b.leave(false);
    while (true) {
        const body = (readMessage(b.in, b.gpa) catch null) orelse break;
        b.lock.lock();
        defer b.lock.unlock();
        const s = b.s orelse {
            b.gpa.free(body);
            return;
        };
        deliver(s, body);
    }
    b.lock.lock();
    defer b.lock.unlock();
    if (b.s) |s| stopAll(s);
}

/// Ends the run of each thread: the client is gone.
fn stopAll(s: *Server) void {
    s.done.store(true, .release);
    s.lock.lock();
    defer s.lock.unlock();
    for (s.targets.items) |t| {
        if (t.it) |x| if (t.running.load(.acquire) and !t.stopped) {
            x.cancelEval(true, "the debugger ended the run") catch {};
        };
        if (t.remote) |k| _ = k.write(k.ctx, "{\"seq\":0,\"type\":\"request\",\"command\":\"disconnect\"}");
        t.ev.signal();
    }
}

/// Reads one request from `in` and routes it. False at the end of
/// stdin.
fn pump(s: *Server) bool {
    const in = s.in orelse return false;
    s.in_lock.lock();
    const body = readMessage(in, s.gpa) catch null;
    s.in_lock.unlock();
    deliver(s, body orelse {
        stopAll(s);
        return false;
    });
    return true;
}

/// The next request of `t`, in `s.gpa`, or null after `disconnect`.
fn take(t: *Target) ?[]u8 {
    const s = t.s;
    while (true) {
        s.lock.lock();
        if (t.queue.items.len > 0) {
            const b = t.queue.orderedRemove(0);
            _ = t.mail.fetchSub(1, .release);
            s.lock.unlock();
            return b;
        }
        if (s.done.load(.acquire)) {
            s.lock.unlock();
            return null;
        }
        if (s.reader or s.child) {
            t.ev.wait(&s.lock, thread.slice_ns);
            s.lock.unlock();
            continue;
        }
        s.lock.unlock();
        if (!pump(s)) return null;
    }
}

/// The next request of `t` with no wait, or null.
fn takeNow(t: *Target) ?[]u8 {
    if (t.mail.load(.acquire) == 0) return null;
    const s = t.s;
    s.lock.lock();
    defer s.lock.unlock();
    if (t.queue.items.len == 0) return null;
    _ = t.mail.fetchSub(1, .release);
    return t.queue.orderedRemove(0);
}

const Route = union(enum) { global, none, to: *Target };

fn byId(s: *Server, id: ?i64) Route {
    const n = id orelse return .{ .to = &s.main };
    for (s.targets.items) |t| if (t.id == n) return .{ .to = t };
    return .none;
}

fn byNum(s: *Server, num: i64) Route {
    for (s.targets.items) |t| if (t.num == num) return .{ .to = t };
    return .none;
}

fn routeOf(s: *Server, cmd: []const u8, ar: ?json.ObjectMap) Route {
    const threaded = [_][]const u8{ "stackTrace", "continue", "next", "stepIn", "stepOut" };
    for (threaded) |c| if (eql(cmd, c)) return byId(s, intOf(ar, "threadId"));
    if (eql(cmd, "pause")) return if (intOf(ar, "threadId")) |id| byId(s, id) else .global;
    if (eql(cmd, "scopes") or eql(cmd, "evaluate")) {
        if (intOf(ar, "frameId")) |f| return byNum(s, f >> frame_bits);
        return .{ .to = &s.main };
    }
    if (eql(cmd, "variables")) {
        const r = intOf(ar, "variablesReference") orelse 0;
        return if (r > 0) byNum(s, @divTrunc(r - 1, 2) >> frame_bits) else .{ .to = &s.main };
    }
    if (eql(cmd, "configurationDone") or eql(cmd, "ztclReload")) return .{ .to = &s.main };
    return .global;
}

/// A request of the client, or of the parent of a child, in `s.gpa`.
/// The server owns it. A request for a thread goes to the queue of the
/// thread, or to its child. The other requests run here.
pub fn deliver(s: *Server, body: []u8) void {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var keep = false;
    defer if (!keep) s.gpa.free(body);
    const req = json.parseFromSliceLeaky(json.Value, a, body, .{}) catch return;
    if (req != .object) return;
    const cmd = strOf(req.object, "command") orelse return;
    s.lock.lock();
    const r = routeOf(s, cmd, args(req.object));
    switch (r) {
        .to => |t| if (t.remote) |k| {
            _ = k.write(k.ctx, body);
            s.lock.unlock();
            return;
        } else if (eql(cmd, "pause")) {
            if (!t.stopped) t.pause.store(true, .release);
            s.lock.unlock();
            respond(s, a, req.object, true, null, null) catch {};
            return;
        } else {
            t.queue.append(s.gpa, body) catch {
                s.lock.unlock();
                return;
            };
            keep = true;
            _ = t.mail.fetchAdd(1, .release);
            s.lock.unlock();
            t.ev.signal();
            return;
        },
        .none => {
            s.lock.unlock();
            _ = fail(s, a, req.object, "no such thread") catch {};
            return;
        },
        .global => s.lock.unlock(),
    }
    global(s, a, req.object) catch {};
    // The children get the change too, with no answer.
    const shared = [_][]const u8{ "setFunctionBreakpoints", "setExceptionBreakpoints", "pause" };
    var share = false;
    for (shared) |c| share = share or eql(cmd, c);
    if (eql(cmd, "setBreakpoints")) share = samePath(strOf(objOf(args(req.object), "source"), "path") orelse "", s.program orelse "");
    if (share) forward(s, a, req.object);
}

/// Sends a copy of `req` with no number to each child.
fn forward(s: *Server, a: Allocator, req: json.ObjectMap) void {
    var copy = req;
    copy.put(a, "seq", .{ .integer = 0 }) catch return;
    const text = json.Stringify.valueAlloc(a, json.Value{ .object = copy }, .{}) catch return;
    s.lock.lock();
    defer s.lock.unlock();
    for (s.targets.items) |t| if (t.remote) |k| {
        _ = k.write(k.ctx, text);
    };
}

/// A request that needs no interpreter.
fn global(s: *Server, a: Allocator, req: json.ObjectMap) !void {
    const cmd = strOf(req, "command") orelse "";
    const ar = args(req);
    if (eql(cmd, "initialize")) {
        try respond(s, a, req, true, null, .{
            .supportsConfigurationDoneRequest = true,
            .supportsFunctionBreakpoints = true,
            .supportsConditionalBreakpoints = true,
            .supportsEvaluateForHovers = true,
            .supportsTerminateRequest = true,
            .exceptionBreakpointFilters = &[_]struct { filter: []const u8, label: []const u8, description: []const u8, default: bool }{
                .{ .filter = "error", .label = "Errors", .description = "Stop at the start of each error, also an error that catch or try catches.", .default = false },
                .{ .filter = "uncaught", .label = "Uncaught errors", .description = "Stop at the start of an error that no catch, and no try with a trap or an on error handler, catches.", .default = false },
            },
        });
        try event(s, a, "initialized", null);
    } else if (eql(cmd, "launch")) {
        const given = strOf(ar, "program");
        if (given) |p| s.program = try a.dupe(u8, p);
        if (ar) |m| if (m.get("stopOnEntry")) |v| {
            s.stop_on_entry = v == .bool and v.bool;
        };
        const path = s.program orelse return failGlobal(s, a, req, "launch needs the argument program");
        if (given != null or s.text.len == 0) {
            const text = s.read(s.read_ctx, path, s.gpa) catch |e| return failGlobal(s, a, req, try std.fmt.allocPrint(a, "{s}: {s}", .{ path, @errorName(e) }));
            setText(s, text);
            if (s.program_buf) |b| s.gpa.free(b);
            s.program_buf = try s.gpa.dupe(u8, path);
            s.program = s.program_buf;
        }
        try respond(s, a, req, true, null, null);
    } else if (eql(cmd, "setBreakpoints")) {
        // The program is the one file, so the breakpoints of each other
        // source are not verified.
        const src = objOf(ar, "source");
        const mine = samePath(strOf(src, "path") orelse "", s.program orelse "");
        var shown: std.ArrayList(struct { verified: bool, line: i64 }) = .empty;
        {
            s.lock.lock();
            defer s.lock.unlock();
            if (mine) {
                for (s.breaks.items) |b| s.gpa.free(b.cond);
                s.breaks.clearRetainingCapacity();
            }
            for (listOf(ar, "breakpoints")) |b| {
                if (b != .object) continue;
                const line = intOf(b.object, "line") orelse continue;
                if (mine) try s.breaks.append(s.gpa, .{ .line = @intCast(line), .cond = try s.gpa.dupe(u8, strOf(b.object, "condition") orelse "") });
                try shown.append(a, .{ .verified = mine, .line = line });
            }
        }
        try respond(s, a, req, true, null, .{ .breakpoints = shown.items });
    } else if (eql(cmd, "setFunctionBreakpoints")) {
        var shown: std.ArrayList(struct { verified: bool }) = .empty;
        s.lock.lock();
        for (s.funcs.items) |f| s.gpa.free(f);
        s.funcs.clearRetainingCapacity();
        for (listOf(ar, "breakpoints")) |b| {
            if (b != .object) continue;
            const name = strOf(b.object, "name") orelse continue;
            const copy = s.gpa.dupe(u8, std.mem.trimStart(u8, name, ":")) catch break;
            s.funcs.append(s.gpa, copy) catch {
                s.gpa.free(copy);
                break;
            };
            try shown.append(a, .{ .verified = true });
        }
        s.lock.unlock();
        try respond(s, a, req, true, null, .{ .breakpoints = shown.items });
    } else if (eql(cmd, "setExceptionBreakpoints")) {
        var on = false;
        var uncaught = false;
        for (listOf(ar, "filters")) |f| {
            if (f == .string and eql(f.string, "error")) on = true;
            if (f == .string and eql(f.string, "uncaught")) uncaught = true;
        }
        s.break_errors.store(on, .release);
        s.break_uncaught.store(uncaught, .release);
        try respond(s, a, req, true, null, null);
    } else if (eql(cmd, "pause")) {
        // A pause with no thread pauses each thread that runs.
        s.lock.lock();
        for (s.targets.items) |t| if (t.remote == null and !t.stopped) t.pause.store(true, .release);
        s.lock.unlock();
        try respond(s, a, req, true, null, null);
    } else if (eql(cmd, "threads")) {
        const T = struct { id: u64, name: []const u8 };
        var list: std.ArrayList(T) = .empty;
        s.lock.lock();
        for (s.targets.items) |t| {
            const name = if (t == &s.main and !s.child) "main" else std.fmt.allocPrint(a, "tid0x{x}", .{t.id}) catch "thread";
            list.append(a, .{ .id = t.id, .name = name }) catch {};
        }
        s.lock.unlock();
        try respond(s, a, req, true, null, .{ .threads = list.items });
    } else if (eql(cmd, "disconnect") or eql(cmd, "terminate")) {
        try respond(s, a, req, true, null, null);
        stopAll(s);
    } else if (eql(cmd, "ztclAttach")) {
        try attach(s, a, ar);
    } else _ = try fail(s, a, req, try std.fmt.allocPrint(a, "unknown request {s}", .{cmd}));
}

fn failGlobal(s: *Server, a: Allocator, req: json.ObjectMap, msg: []const u8) !void {
    _ = try fail(s, a, req, msg);
}

/// Answers one request of the thread `t`. True when the request
/// continues a stopped run.
fn local(t: *Target, a: Allocator, req: json.ObjectMap, stopped: bool) !bool {
    const s = t.s;
    const cmd = strOf(req, "command") orelse "";
    const ar = args(req);
    if (eql(cmd, "stackTrace")) {
        try stackTrace(t, a, req);
    } else if (eql(cmd, "scopes")) {
        const id = intOf(ar, "frameId") orelse 0;
        try respond(s, a, req, true, null, .{ .scopes = &[_]struct { name: []const u8, variablesReference: i64, expensive: bool }{
            .{ .name = "Locals", .variablesReference = id * 2 + 1, .expensive = false },
            .{ .name = "Globals", .variablesReference = id * 2 + 2, .expensive = false },
        } });
    } else if (eql(cmd, "variables")) {
        try variables(t, a, req);
    } else if (eql(cmd, "evaluate")) {
        try evaluate(t, a, req);
    } else if (eql(cmd, "ztclReload")) {
        try reload(t, a, req);
    } else if (eql(cmd, "continue") or eql(cmd, "next") or eql(cmd, "stepIn") or eql(cmd, "stepOut")) {
        if (!stopped) return fail(s, a, req, "the thread is not stopped");
        t.mode = if (eql(cmd, "continue")) .run else if (eql(cmd, "next")) .next else if (eql(cmd, "stepIn")) .step_in else .step_out;
        t.depth = t.it.?.frame.level;
        if (eql(cmd, "continue")) {
            try respond(s, a, req, true, null, .{ .allThreadsContinued = onlyThread(s) });
        } else try respond(s, a, req, true, null, null);
        return true;
    } else return fail(s, a, req, try std.fmt.allocPrint(a, "unknown request {s}", .{cmd}));
    return false;
}

/// True when the program has one thread, so a stop stops all.
fn onlyThread(s: *Server) bool {
    if (s.child) return false;
    s.lock.lock();
    defer s.lock.unlock();
    return s.targets.items.len == 1;
}

fn setText(s: *Server, text: []u8) void {
    if (s.text_owned) s.gpa.free(s.text);
    s.text = text;
    s.text_owned = true;
}

fn fail(s: *Server, a: Allocator, req: json.ObjectMap, msg: []const u8) !bool {
    try respond(s, a, req, false, msg, null);
    return false;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

/// True when both paths name the program: equal, or one is the other
/// with a folder in front.
fn samePath(x: []const u8, y: []const u8) bool {
    if (x.len == 0 or y.len == 0) return false;
    if (eql(x, y)) return true;
    const long, const short = if (x.len > y.len) .{ x, y } else .{ y, x };
    const tail = std.mem.trimStart(u8, short, "./");
    return std.mem.endsWith(u8, long, tail) and long.len > tail.len and long[long.len - tail.len - 1] == '/';
}

fn runProgram(s: *Server, a: Allocator) !void {
    const it = s.it;
    const st = try probe.state(it);
    st.line_hook = .{ .ctx = &s.main, .f = onLine, .err = onError };
    defer st.line_hook = null;
    probe.threads = .{ .ctx = s, .start = threadStart, .end = threadEnd, .remote = remoteStart, .child = remoteFrame, .gone = remoteGone };
    defer probe.threads = null;
    if (s.stop_on_entry) s.main.mode = .step_in;
    const script = it.compile(s.text) catch {
        try event(s, a, "output", .{ .category = "stderr", .output = try std.fmt.allocPrint(a, "{s}\n", .{try it.str(it.result)}) });
        s.exit_code = 1;
        return finish(s, a);
    };
    st.top = script;
    st.top_text = s.text;
    defer {
        st.top = null;
        st.top_text = "";
    }
    const prev = it.script_name;
    it.script_name = s.program orelse "";
    defer it.script_name = prev;
    s.main.running.store(true, .release);
    defer s.main.running.store(false, .release);
    _ = it.evalTop(script) catch |e| {
        if (e == error.OutOfMemory) return e;
        if (!s.done.load(.acquire)) {
            const info = it.str(it.getVar("::errorInfo") catch it.result) catch "";
            try event(s, a, "output", .{ .category = "stderr", .output = try std.fmt.allocPrint(a, "{s}\n", .{info}) });
        }
        s.exit_code = 1;
    };
    try finish(s, a);
}

fn finish(s: *Server, a: Allocator) !void {
    if (s.done.load(.acquire)) return;
    try event(s, a, "exited", .{ .exitCode = s.exit_code });
    try event(s, a, "terminated", null);
}

// ---- Threads ----

/// The line of the program file before the script of a thread, when the
/// script is a part of the file, as the body of `thread::create` is.
fn lineOff(text: []const u8, script: []const u8) ?u32 {
    if (script.len == 0) return null;
    const at = std.mem.indexOf(u8, text, script) orelse return null;
    return @intCast(std.mem.count(u8, text[0..at], "\n"));
}

fn addTarget(s: *Server, t: *Target) !void {
    s.lock.lock();
    defer s.lock.unlock();
    t.num = s.next_num;
    s.next_num += 1;
    try s.targets.append(s.gpa, t);
}

/// Removes `t` from the list. False when it is not in the list.
fn dropTarget(s: *Server, t: *Target) bool {
    s.lock.lock();
    defer s.lock.unlock();
    const at = std.mem.indexOfScalar(*Target, s.targets.items, t) orelse return false;
    _ = s.targets.orderedRemove(at);
    return true;
}

fn threadEvent(s: *Server, id: u64, reason: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    event(s, arena.allocator(), "thread", .{ .reason = reason, .threadId = id }) catch {};
}

fn threadStart(ctx: ?*anyopaque, x: *Interp, id: u64, script: []const u8) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    const t = s.gpa.create(Target) catch return;
    t.* = .{ .s = s, .id = id, .num = 0, .it = x, .line_off = lineOff(s.text, script) };
    t.running.store(true, .release);
    const st = probe.state(x) catch {
        s.gpa.destroy(t);
        return;
    };
    addTarget(s, t) catch {
        s.gpa.destroy(t);
        return;
    };
    st.line_hook = .{ .ctx = t, .f = onLine, .err = onError };
    threadEvent(s, id, "started");
}

fn threadEnd(ctx: ?*anyopaque, x: *Interp) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    const st = x.probes orelse return;
    const h = st.line_hook orelse return;
    st.line_hook = null;
    const t: *Target = @ptrCast(@alignCast(h.ctx.?));
    if (!dropTarget(s, t)) return;
    threadEvent(s, t.id, "exited");
    t.deinit(s.gpa);
    s.gpa.destroy(t);
}

fn remoteStart(ctx: ?*anyopaque, id: u64, out: Sink) ?*anyopaque {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    const t = s.gpa.create(Target) catch return null;
    t.* = .{ .s = s, .id = id, .num = 0, .remote = out };
    addTarget(s, t) catch {
        s.gpa.destroy(t);
        return null;
    };
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const body = attachBody(s, arena.allocator(), t) catch "";
    if (body.len == 0 or !out.write(out.ctx, body)) {
        _ = dropTarget(s, t);
        s.gpa.destroy(t);
        return null;
    }
    threadEvent(s, id, "started");
    return t;
}

/// The first DEBUG frame of a child: its thread, its frame ids, the
/// program, and the breakpoints.
fn attachBody(s: *Server, a: Allocator, t: *Target) ![]const u8 {
    const B = struct { line: u32, condition: []const u8 };
    var bs: std.ArrayList(B) = .empty;
    var fs: std.ArrayList([]const u8) = .empty;
    s.lock.lock();
    defer s.lock.unlock();
    for (s.breaks.items) |b| try bs.append(a, .{ .line = b.line, .condition = try a.dupe(u8, b.cond) });
    for (s.funcs.items) |f| try fs.append(a, try a.dupe(u8, f));
    return json.Stringify.valueAlloc(a, .{
        .seq = 0,
        .type = "request",
        .command = "ztclAttach",
        .arguments = .{
            .threadId = t.id,
            .frameBase = t.num,
            .program = s.program orelse "",
            .text = s.text,
            .breakpoints = bs.items,
            .functions = fs.items,
            .errors = s.break_errors.load(.acquire),
            .uncaught = s.break_uncaught.load(.acquire),
        },
    }, .{});
}

/// A message of a child: the number of the server replaces its number.
fn remoteFrame(ctx: ?*anyopaque, handle: *anyopaque, body: []const u8) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    const t: *Target = @ptrCast(@alignCast(handle));
    s.lock.lock();
    defer s.lock.unlock();
    if (std.mem.indexOfScalar(*Target, s.targets.items, t) == null) return;
    const head = "{\"seq\":";
    if (!std.mem.startsWith(u8, body, head)) return;
    const comma = std.mem.indexOfScalar(u8, body, ',') orelse return;
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const full = std.fmt.allocPrint(arena.allocator(), "{{\"seq\":{d}{s}", .{ s.seq, body[comma..] }) catch return;
    s.seq += 1;
    writeBody(s, full) catch {};
}

fn remoteGone(ctx: ?*anyopaque, handle: *anyopaque) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    const t: *Target = @ptrCast(@alignCast(handle));
    if (!dropTarget(s, t)) return;
    threadEvent(s, t.id, "exited");
    t.deinit(s.gpa);
    s.gpa.destroy(t);
}

// ---- The child of an isolated thread ----

/// The server of a child: `attach_body` is the first DEBUG frame of the
/// parent, and `out` sends DEBUG frames to it. Each later DEBUG frame
/// goes to `deliver`.
pub fn startChild(gpa: Allocator, x: *Interp, attach_body: []const u8, script: []const u8, out: Sink) !*Server {
    const s = try gpa.create(Server);
    errdefer gpa.destroy(s);
    s.* = .{ .it = x, .gpa = gpa, .sink = out, .child = true };
    try begin(s);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const req = try json.parseFromSliceLeaky(json.Value, a, attach_body, .{});
    if (req != .object) return error.BadAttach;
    try attach(s, a, args(req.object));
    s.main.line_off = lineOff(s.text, script);
    const st = try probe.state(x);
    st.line_hook = .{ .ctx = &s.main, .f = onLine, .err = onError };
    s.main.running.store(true, .release);
    return s;
}

pub fn endChild(s: *Server) void {
    if (s.it.probes) |st| st.line_hook = null;
    const gpa = s.gpa;
    end(s);
    gpa.destroy(s);
}

/// The request `ztclAttach` of the parent: the state of its debugger.
fn attach(s: *Server, a: Allocator, ar: ?json.ObjectMap) !void {
    if (!s.child) return;
    _ = a;
    s.main.id = @intCast(@max(intOf(ar, "threadId") orelse 1, 0));
    s.main.num = @intCast(@max(intOf(ar, "frameBase") orelse 0, 0));
    if (strOf(ar, "program")) |p| {
        s.program_buf = try s.gpa.dupe(u8, p);
        s.program = s.program_buf;
    }
    const text = try s.gpa.dupe(u8, strOf(ar, "text") orelse "");
    setText(s, text);
    s.lock.lock();
    defer s.lock.unlock();
    for (listOf(ar, "breakpoints")) |b| {
        if (b != .object) continue;
        const line = intOf(b.object, "line") orelse continue;
        try s.breaks.append(s.gpa, .{ .line = @intCast(line), .cond = try s.gpa.dupe(u8, strOf(b.object, "condition") orelse "") });
    }
    for (listOf(ar, "functions")) |f| if (f == .string) try s.funcs.append(s.gpa, try s.gpa.dupe(u8, f.string));
    if (ar) |m| if (m.get("errors")) |v| s.break_errors.store(v == .bool and v.bool, .release);
    if (ar) |m| if (m.get("uncaught")) |v| s.break_uncaught.store(v == .bool and v.bool, .release);
}

// ---- Stops ----

/// The line hook: line `line` of the body of `p`, or of the top level
/// of the program file when `p` is null. Line 0 is the entry of `p`.
fn onLine(ctx: ?*anyopaque, it: *Interp, p: ?*interp.Proc, line: u32) void {
    const t: *Target = @ptrCast(@alignCast(ctx.?));
    const s = t.s;
    if (s.done.load(.acquire)) return;
    const st = it.probes orelse return;
    readWaiting(t);
    const place = placeOf(t, st, p, line);
    const reason: ?[]const u8 = why(t, it, p, line, place) catch null;
    if (line != 0) t.places.put(s.gpa, it.frame, place) catch {};
    const r = reason orelse return;
    if (line == 0) t.places.put(s.gpa, it.frame, place) catch {};
    stop(t, it, st, r) catch stopAll(s);
}

/// The line of the program file of line `line` of `p`, or of the top
/// level of the script of the thread.
fn placeOf(t: *Target, st: *probe.State, p: ?*interp.Proc, line: u32) Place {
    const off = t.line_off orelse {
        return .{ .line = line, .in_file = false };
    };
    const pp = p orelse return .{ .line = off + line, .in_file = true };
    if (st.bases.get(pp)) |b| return .{ .line = off + b + @max(line, 1) - 1, .in_file = true };
    return .{ .line = line, .in_file = false };
}

/// Answers the requests that wait while the thread runs.
fn readWaiting(t: *Target) void {
    const s = t.s;
    if (!s.reader and !s.child) if (s.poll) |poll| {
        t.ticks += 1;
        if (t.ticks >= s.poll_every) {
            t.ticks = 0;
            while (!s.done.load(.acquire) and poll(s.poll_ctx)) {
                if (!pump(s)) return;
            }
        }
    };
    while (takeNow(t)) |body| {
        defer s.gpa.free(body);
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const req = json.parseFromSliceLeaky(json.Value, a, body, .{}) catch continue;
        if (req != .object) continue;
        _ = local(t, a, req.object, false) catch {
            stopAll(s);
            return;
        };
    }
}

/// The error hook: an error starts. With the filter `error`, the run
/// stops in the frame of the error.
fn onError(ctx: ?*anyopaque, it: *Interp, cmd: []const u8) void {
    const t: *Target = @ptrCast(@alignCast(ctx.?));
    const s = t.s;
    if (s.done.load(.acquire)) return;
    const st = it.probes orelse return;
    const all = s.break_errors.load(.acquire);
    if (!all and !(s.break_uncaught.load(.acquire) and st.catching == 0)) return;
    var buf: [400]u8 = undefined;
    var msg_buf: [200]u8 = undefined;
    const full = it.str(it.result) catch "";
    const msg = msg_buf[0..@min(full.len, msg_buf.len)];
    @memcpy(msg, full[0..msg.len]);
    const text = std.fmt.bufPrint(&buf, "{s}\n    while executing \"{s}\"", .{ msg, cmd[0..@min(cmd.len, 150)] }) catch msg;
    // The error goes on after the stop: the requests of the stop must
    // not change its message, its trace, or its code.
    const saved = probe.Saved.take(it);
    defer saved.back(it);
    stopWith(t, it, st, "exception", msg, text) catch stopAll(s);
}

fn why(t: *Target, it: *Interp, p: ?*interp.Proc, line: u32, place: Place) !?[]const u8 {
    const s = t.s;
    const level = it.frame.level;
    if (line != 0 and t.pause.load(.acquire)) {
        t.pause.store(false, .release);
        return "pause";
    }
    if (line == 0) {
        if (p == null or it.frame.argv.len == 0) return null;
        const name = std.mem.trimStart(u8, try it.str(it.frame.argv[0]), ":");
        s.lock.lock();
        defer s.lock.unlock();
        for (s.funcs.items) |f| if (eql(name, f)) return "function breakpoint";
        return null;
    }
    switch (t.mode) {
        .step_in => return "step",
        .next => if (level <= t.depth) return "step",
        .step_out => if (level < t.depth) return "step",
        .run => {},
    }
    if (!place.in_file) return null;
    // The conditions run with no lock: a copy of each.
    var conds: [8][]const u8 = undefined;
    var n: usize = 0;
    {
        s.lock.lock();
        defer s.lock.unlock();
        for (s.breaks.items) |b| {
            if (b.line != place.line) continue;
            if (b.cond.len == 0) return "breakpoint";
            if (n < conds.len) {
                conds[n] = try it.alloc().dupe(u8, b.cond);
                n += 1;
            }
        }
    }
    for (conds[0..n]) |c| {
        const v = try quiet(it, c);
        if (v) |x| if (eql(x, "1")) return "breakpoint";
    }
    return null;
}

fn stop(t: *Target, it: *Interp, st: *probe.State, reason: []const u8) !void {
    return stopWith(t, it, st, reason, null, null);
}

/// A stop. `description` and `text` are for an exception: the message,
/// and the message with the command.
fn stopWith(t: *Target, it: *Interp, st: *probe.State, reason: []const u8, description: ?[]const u8, text: ?[]const u8) !void {
    const s = t.s;
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    t.mode = .run;
    t.pause.store(false, .release);
    t.frames.clearRetainingCapacity();
    var f: ?*interp.Frame = it.frame;
    while (f) |fr| : (f = fr.parent) {
        if (t.frames.items.len == max_frames - 1 and fr.parent != null) continue;
        try t.frames.append(s.gpa, fr);
    }
    s.lock.lock();
    t.stopped = true;
    s.lock.unlock();
    defer {
        s.lock.lock();
        t.stopped = false;
        s.lock.unlock();
    }
    try event(s, arena.allocator(), "stopped", .{ .reason = reason, .threadId = t.id, .allThreadsStopped = onlyThread(s), .description = description, .text = text });
    // A line of an evaluation in the stop does not stop.
    const busy = st.busy;
    st.busy = true;
    defer st.busy = busy;
    while (true) {
        const body = take(t) orelse {
            try it.cancelEval(true, "the debugger ended the run");
            return;
        };
        defer s.gpa.free(body);
        var ra: std.heap.ArenaAllocator = .init(s.gpa);
        defer ra.deinit();
        const a = ra.allocator();
        const req = json.parseFromSliceLeaky(json.Value, a, body, .{}) catch continue;
        if (req != .object) continue;
        if (try local(t, a, req.object, true)) return;
    }
}

fn frameAt(t: *Target, id: i64) ?*interp.Frame {
    if (id < 0 or @as(u64, @intCast(id)) >> frame_bits != t.num) return null;
    const i: usize = @intCast(id & (max_frames - 1));
    if (i >= t.frames.items.len) return null;
    return t.frames.items[i];
}

fn frameId(t: *Target, i: usize) u64 {
    return (t.num << frame_bits) | i;
}

fn stackTrace(t: *Target, a: Allocator, req: json.ObjectMap) !void {
    const s = t.s;
    const Src = struct { name: []const u8, path: []const u8 };
    const F = struct { id: u64, name: []const u8, line: u32, column: u32 = 1, source: ?Src = null };
    var out: std.ArrayList(F) = .empty;
    const name = std.fs.path.basename(s.program orelse "");
    for (t.frames.items, 0..) |fr, i| {
        const place = t.places.get(fr) orelse Place{ .line = 0, .in_file = false };
        const words = if (fr.parent == null) "<top>" else try value.listToString(a, fr.argv);
        try out.append(a, .{
            .id = frameId(t, i),
            .name = words,
            .line = place.line,
            .source = if (place.in_file) .{ .name = name, .path = s.program orelse "" } else null,
        });
    }
    try respond(s, a, req, true, null, .{ .stackFrames = out.items, .totalFrames = out.items.len });
}

fn variables(t: *Target, a: Allocator, req: json.ObjectMap) !void {
    const s = t.s;
    const it = t.it.?;
    const ref = intOf(args(req), "variablesReference") orelse 0;
    const V = struct { name: []const u8, value: []const u8, variablesReference: u32 = 0 };
    var out: std.ArrayList(V) = .empty;
    const fr: ?*interp.Frame = if (ref <= 0 or t.frames.items.len == 0) null else if (@rem(ref, 2) == 0) t.frames.items[t.frames.items.len - 1] else frameAt(t, @divTrunc(ref - 1, 2));
    if (fr) |f| {
        const d = try probe.localsOf(it, f, 4096);
        const items = try it.list(d);
        var k: usize = 0;
        while (k + 1 < items.len) : (k += 2) try out.append(a, .{ .name = try it.str(items[k]), .value = try it.str(items[k + 1]) });
    }
    try respond(s, a, req, true, null, .{ .variables = out.items });
}

/// The truth of the condition `code` in the current frame, as `1` or
/// `0`, or null after an error. The result of the interpreter stays as
/// it was.
fn quiet(it: *Interp, code: []const u8) !?[]const u8 {
    const res = it.result;
    const ec = it.error_code;
    defer {
        it.result = res;
        it.error_code = ec;
    }
    const text = try std.fmt.allocPrint(it.alloc(), "expr {{!!({s})}}", .{code});
    const v = it.eval(text) catch |e| {
        if (e == error.OutOfMemory) return e;
        return null;
    };
    return try it.str(v);
}

fn evaluate(t: *Target, a: Allocator, req: json.ObjectMap) !void {
    const s = t.s;
    const ar = args(req);
    const code = strOf(ar, "expression") orelse "";
    const it = t.it.?;
    const saved = it.frame;
    defer it.frame = saved;
    if (intOf(ar, "frameId")) |id| if (frameAt(t, id)) |f| {
        it.frame = f;
    };
    const res = it.result;
    const ec = it.error_code;
    defer {
        it.result = res;
        it.error_code = ec;
    }
    const v = it.eval(code) catch |e| {
        if (e == error.OutOfMemory) return e;
        _ = try fail(s, a, req, try it.str(it.result));
        return;
    };
    try respond(s, a, req, true, null, .{ .result = try it.str(v), .variablesReference = 0 });
}

/// Hot reload: reads the program file again and runs each `proc`
/// command of its top level, in the global namespace. A frame that runs
/// keeps the old body until it returns.
fn reload(t: *Target, a: Allocator, req: json.ObjectMap) !void {
    const s = t.s;
    const it = t.it.?;
    const path = strOf(args(req), "path") orelse s.program orelse {
        _ = try fail(s, a, req, "no program");
        return;
    };
    const text = s.read(s.read_ctx, path, s.gpa) catch |e| {
        _ = try fail(s, a, req, @errorName(e));
        return;
    };
    const script = it.compile(text) catch {
        _ = try fail(s, a, req, try it.str(it.result));
        return;
    };
    const st = try probe.state(it);
    const top = st.top;
    st.top = script;
    defer st.top = top;
    const saved = it.frame;
    defer it.frame = saved;
    var root = it.frame;
    while (root.parent) |p| root = p;
    it.frame = root;
    var n: usize = 0;
    for (script.cmds) |*c| {
        if (c.words.len != 4 or c.words[0].kind != .lit) continue;
        if (!eql(try it.str(c.words[0].kind.lit), "proc")) continue;
        st.top_cmd = c;
        _ = it.evalCmd(c) catch |e| {
            if (e == error.OutOfMemory) return e;
            _ = try fail(s, a, req, try it.str(it.result));
            return;
        };
        n += 1;
    }
    setText(s, text);
    try respond(s, a, req, true, null, .{ .procs = n });
}

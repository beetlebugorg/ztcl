//! `ztcl debug --dap`: a debugger over the Debug Adapter Protocol on
//! stdin and stdout, for editors such as VS Code.
//!
//! A message has the header `Content-Length: N`, an empty line, and N
//! bytes of JSON. The server answers `initialize`, `launch`,
//! `setBreakpoints`, `setFunctionBreakpoints`,
//! `setExceptionBreakpoints`, `configurationDone`, `threads`,
//! `stackTrace`, `scopes`, `variables`, `continue`, `next`, `stepIn`,
//! `stepOut`, `evaluate`, `disconnect`, and `terminate`. The custom
//! request `ztclReload` defines the procs of the program file again.
//!
//! The run starts at `configurationDone`. The debugger uses the line
//! hook of `probe.zig`: each line of a proc and each command of the top
//! level of the program file calls `onLine`. At a stop, `onLine` sends
//! the event `stopped` and reads requests until a request continues the
//! run. A stop is a breakpoint, a function breakpoint at the entry of a
//! proc, or the next line of a step. The output of `puts` goes to the
//! event `output`, because stdout has the protocol.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const probe = @import("probe.zig");

const Interp = interp.Interp;
const Value = value.Value;
const Allocator = std.mem.Allocator;
const json = std.json;

pub const ReadFn = *const fn (ctx: ?*anyopaque, path: []const u8, a: Allocator) anyerror![]u8;

const Mode = enum { run, step_in, next, step_out };

const LineBreak = struct { line: u32, cond: []const u8 };

/// The place of a frame at its last line: the line of the file, or the
/// line of the body of a proc that is in no file.
const Place = struct { line: u32, in_file: bool };

pub const Server = struct {
    it: *Interp,
    gpa: Allocator,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    read: ReadFn,
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
    mode: Mode = .run,
    /// The level of the frame at the start of a step.
    depth: u32 = 0,
    /// The last line of each frame of the stack.
    places: std.AutoHashMapUnmanaged(*interp.Frame, Place) = .empty,
    /// The frames at the stop, from the innermost.
    frames: std.ArrayList(*interp.Frame) = .empty,
    /// The client sent `disconnect` or `terminate`, or stdin closed.
    done: bool = false,
    exit_code: i64 = 0,
};

// ---- The wire ----

/// The body of the next message, in `a`, or null at the end of stdin.
fn readMessage(s: *Server, a: Allocator) !?[]const u8 {
    var len: ?usize = null;
    while (true) {
        const line = s.in.takeDelimiterExclusive('\n') catch return null;
        _ = s.in.take(1) catch {};
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
    s.in.readSliceAll(body) catch return null;
    return body;
}

fn send(s: *Server, body: []const u8) !void {
    try s.out.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try s.out.writeAll(body);
    try s.out.flush();
}

fn respond(s: *Server, a: Allocator, req: json.ObjectMap, ok: bool, msg: ?[]const u8, body: anytype) !void {
    const seq = s.seq;
    s.seq += 1;
    const cmd = strOf(req, "command") orelse "";
    const rseq = intOf(req, "seq") orelse 0;
    try send(s, try json.Stringify.valueAlloc(a, .{
        .seq = seq,
        .type = "response",
        .request_seq = rseq,
        .success = ok,
        .command = cmd,
        .message = msg,
        .body = body,
    }, .{ .emit_null_optional_fields = false }));
}

fn event(s: *Server, a: Allocator, name: []const u8, body: anytype) !void {
    const seq = s.seq;
    s.seq += 1;
    try send(s, try json.Stringify.valueAlloc(a, .{ .seq = seq, .type = "event", .event = name, .body = body }, .{ .emit_null_optional_fields = false }));
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

/// Serves requests until `disconnect` or the end of stdin.
pub fn serve(s: *Server) !void {
    defer {
        if (s.text_owned) s.gpa.free(s.text);
        if (s.program_buf) |b| s.gpa.free(b);
        for (s.breaks.items) |b| s.gpa.free(b.cond);
        for (s.funcs.items) |f| s.gpa.free(f);
        s.breaks.deinit(s.gpa);
        s.funcs.deinit(s.gpa);
        s.places.deinit(s.gpa);
        s.frames.deinit(s.gpa);
    }
    s.it.output = .{ .ctx = s, .write = output };
    while (!s.done) {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const body = try readMessage(s, a) orelse break;
        const req = (json.parseFromSliceLeaky(json.Value, a, body, .{}) catch continue);
        if (req != .object) continue;
        const cmd = strOf(req.object, "command") orelse continue;
        if (std.mem.eql(u8, cmd, "configurationDone")) {
            try respond(s, a, req.object, true, null, null);
            try runProgram(s, a);
            continue;
        }
        _ = try handle(s, a, req.object, false);
    }
}

/// Answers one request. True when the request continues a stopped run.
fn handle(s: *Server, a: Allocator, req: json.ObjectMap, stopped: bool) !bool {
    const cmd = strOf(req, "command") orelse "";
    const ar = args(req);
    if (eql(cmd, "initialize")) {
        try respond(s, a, req, true, null, .{
            .supportsConfigurationDoneRequest = true,
            .supportsFunctionBreakpoints = true,
            .supportsConditionalBreakpoints = true,
            .supportsEvaluateForHovers = true,
            .supportsTerminateRequest = true,
        });
        try event(s, a, "initialized", null);
    } else if (eql(cmd, "launch")) {
        const given = strOf(ar, "program");
        if (given) |p| s.program = try a.dupe(u8, p);
        if (ar) |m| if (m.get("stopOnEntry")) |v| {
            s.stop_on_entry = v == .bool and v.bool;
        };
        const path = s.program orelse return fail(s, a, req, "launch needs the argument program");
        if (given != null or s.text.len == 0) {
            const text = s.read(s.read_ctx, path, s.gpa) catch |e| return fail(s, a, req, try std.fmt.allocPrint(a, "{s}: {s}", .{ path, @errorName(e) }));
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
        if (mine) {
            for (s.breaks.items) |b| s.gpa.free(b.cond);
            s.breaks.clearRetainingCapacity();
        }
        var shown: std.ArrayList(struct { verified: bool, line: i64 }) = .empty;
        for (listOf(ar, "breakpoints")) |b| {
            if (b != .object) continue;
            const line = intOf(b.object, "line") orelse continue;
            if (mine) try s.breaks.append(s.gpa, .{ .line = @intCast(line), .cond = try s.gpa.dupe(u8, strOf(b.object, "condition") orelse "") });
            try shown.append(a, .{ .verified = mine, .line = line });
        }
        try respond(s, a, req, true, null, .{ .breakpoints = shown.items });
    } else if (eql(cmd, "setFunctionBreakpoints")) {
        for (s.funcs.items) |f| s.gpa.free(f);
        s.funcs.clearRetainingCapacity();
        var shown: std.ArrayList(struct { verified: bool }) = .empty;
        for (listOf(ar, "breakpoints")) |b| {
            if (b != .object) continue;
            const name = strOf(b.object, "name") orelse continue;
            try s.funcs.append(s.gpa, try s.gpa.dupe(u8, std.mem.trimStart(u8, name, ":")));
            try shown.append(a, .{ .verified = true });
        }
        try respond(s, a, req, true, null, .{ .breakpoints = shown.items });
    } else if (eql(cmd, "setExceptionBreakpoints")) {
        try respond(s, a, req, true, null, .{ .breakpoints = &[_]u8{} });
    } else if (eql(cmd, "threads")) {
        try respond(s, a, req, true, null, .{ .threads = &[_]struct { id: u32, name: []const u8 }{.{ .id = 1, .name = "main" }} });
    } else if (eql(cmd, "stackTrace")) {
        try stackTrace(s, a, req);
    } else if (eql(cmd, "scopes")) {
        const id = intOf(ar, "frameId") orelse 0;
        try respond(s, a, req, true, null, .{ .scopes = &[_]struct { name: []const u8, variablesReference: i64, expensive: bool }{
            .{ .name = "Locals", .variablesReference = id * 2 + 1, .expensive = false },
            .{ .name = "Globals", .variablesReference = id * 2 + 2, .expensive = false },
        } });
    } else if (eql(cmd, "variables")) {
        try variables(s, a, req);
    } else if (eql(cmd, "evaluate")) {
        try evaluate(s, a, req);
    } else if (eql(cmd, "ztclReload")) {
        try reload(s, a, req);
    } else if (eql(cmd, "continue") or eql(cmd, "next") or eql(cmd, "stepIn") or eql(cmd, "stepOut")) {
        if (!stopped) return fail(s, a, req, "the program is not stopped");
        s.mode = if (eql(cmd, "continue")) .run else if (eql(cmd, "next")) .next else if (eql(cmd, "stepIn")) .step_in else .step_out;
        s.depth = s.it.frame.level;
        if (eql(cmd, "continue")) {
            try respond(s, a, req, true, null, .{ .allThreadsContinued = true });
        } else try respond(s, a, req, true, null, null);
        return true;
    } else if (eql(cmd, "disconnect") or eql(cmd, "terminate")) {
        s.done = true;
        if (stopped) try s.it.cancelEval(true, "the debugger ended the run");
        try respond(s, a, req, true, null, null);
        return true;
    } else return fail(s, a, req, try std.fmt.allocPrint(a, "unknown request {s}", .{cmd}));
    return false;
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
    st.line_hook = .{ .ctx = s, .f = onLine };
    defer st.line_hook = null;
    if (s.stop_on_entry) s.mode = .step_in;
    const script = it.compile(s.text) catch {
        try event(s, a, "output", .{ .category = "stderr", .output = try std.fmt.allocPrint(a, "{s}\n", .{try it.str(it.result)}) });
        s.exit_code = 1;
        return finish(s, a);
    };
    st.top = script;
    defer st.top = null;
    const prev = it.script_name;
    it.script_name = s.program orelse "";
    defer it.script_name = prev;
    _ = it.evalTop(script) catch |e| {
        if (e == error.OutOfMemory) return e;
        if (!s.done) {
            const info = it.str(it.getVar("::errorInfo") catch it.result) catch "";
            try event(s, a, "output", .{ .category = "stderr", .output = try std.fmt.allocPrint(a, "{s}\n", .{info}) });
        }
        s.exit_code = 1;
    };
    try finish(s, a);
}

fn finish(s: *Server, a: Allocator) !void {
    if (s.done) return;
    try event(s, a, "exited", .{ .exitCode = s.exit_code });
    try event(s, a, "terminated", null);
}

// ---- Stops ----

/// The line hook: line `line` of the body of `p`, or of the top level
/// of the program file when `p` is null. Line 0 is the entry of `p`.
fn onLine(ctx: ?*anyopaque, it: *Interp, p: ?*interp.Proc, line: u32) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    if (s.done) return;
    const st = it.probes orelse return;
    const place: Place = if (p) |pp| (if (st.bases.get(pp)) |b| .{ .line = b + @max(line, 1) - 1, .in_file = true } else .{ .line = line, .in_file = false }) else .{ .line = line, .in_file = true };
    const reason: ?[]const u8 = why(s, it, p, line, place) catch null;
    if (line != 0) s.places.put(s.gpa, it.frame, place) catch {};
    const r = reason orelse return;
    if (line == 0) s.places.put(s.gpa, it.frame, place) catch {};
    stop(s, it, st, r) catch {
        s.done = true;
    };
}

fn why(s: *Server, it: *Interp, p: ?*interp.Proc, line: u32, place: Place) !?[]const u8 {
    const level = it.frame.level;
    if (line == 0) {
        if (p == null or it.frame.argv.len == 0) return null;
        const name = std.mem.trimStart(u8, try it.str(it.frame.argv[0]), ":");
        for (s.funcs.items) |f| if (eql(name, f)) return "function breakpoint";
        return null;
    }
    switch (s.mode) {
        .step_in => return "step",
        .next => if (level <= s.depth) return "step",
        .step_out => if (level < s.depth) return "step",
        .run => {},
    }
    if (!place.in_file) return null;
    for (s.breaks.items) |b| {
        if (b.line != place.line) continue;
        if (b.cond.len == 0) return "breakpoint";
        const v = try quiet(it, b.cond);
        if (v) |t| if (eql(t, "1")) return "breakpoint";
    }
    return null;
}

fn stop(s: *Server, it: *Interp, st: *probe.State, reason: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    s.mode = .run;
    s.frames.clearRetainingCapacity();
    var f: ?*interp.Frame = it.frame;
    while (f) |fr| : (f = fr.parent) try s.frames.append(s.gpa, fr);
    try event(s, arena.allocator(), "stopped", .{ .reason = reason, .threadId = 1, .allThreadsStopped = true });
    // A line of an evaluation in the stop does not stop.
    const busy = st.busy;
    st.busy = true;
    defer st.busy = busy;
    while (!s.done) {
        var ra: std.heap.ArenaAllocator = .init(s.gpa);
        defer ra.deinit();
        const a = ra.allocator();
        const body = try readMessage(s, a) orelse {
            s.done = true;
            try it.cancelEval(true, "the debugger ended the run");
            return;
        };
        const req = json.parseFromSliceLeaky(json.Value, a, body, .{}) catch continue;
        if (req != .object) continue;
        if (try handle(s, a, req.object, true)) return;
    }
}

fn frameAt(s: *Server, id: i64) ?*interp.Frame {
    if (id < 0 or id >= s.frames.items.len) return null;
    return s.frames.items[@intCast(id)];
}

fn stackTrace(s: *Server, a: Allocator, req: json.ObjectMap) !void {
    const Src = struct { name: []const u8, path: []const u8 };
    const F = struct { id: usize, name: []const u8, line: u32, column: u32 = 1, source: ?Src = null };
    var out: std.ArrayList(F) = .empty;
    const name = std.fs.path.basename(s.program orelse "");
    for (s.frames.items, 0..) |fr, i| {
        const place = s.places.get(fr) orelse Place{ .line = 0, .in_file = false };
        const words = if (fr.parent == null) "<top>" else try value.listToString(a, fr.argv);
        try out.append(a, .{
            .id = i,
            .name = words,
            .line = place.line,
            .source = if (place.in_file) .{ .name = name, .path = s.program orelse "" } else null,
        });
    }
    try respond(s, a, req, true, null, .{ .stackFrames = out.items, .totalFrames = out.items.len });
}

fn variables(s: *Server, a: Allocator, req: json.ObjectMap) !void {
    const ref = intOf(args(req), "variablesReference") orelse 0;
    const V = struct { name: []const u8, value: []const u8, variablesReference: u32 = 0 };
    var out: std.ArrayList(V) = .empty;
    const fr: ?*interp.Frame = if (ref <= 0) null else if (@rem(ref, 2) == 0) s.frames.items[s.frames.items.len - 1] else frameAt(s, @divTrunc(ref - 1, 2));
    if (fr) |f| {
        const d = try probe.localsOf(s.it, f, 4096);
        const items = try s.it.list(d);
        var k: usize = 0;
        while (k + 1 < items.len) : (k += 2) try out.append(a, .{ .name = try s.it.str(items[k]), .value = try s.it.str(items[k + 1]) });
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

fn evaluate(s: *Server, a: Allocator, req: json.ObjectMap) !void {
    const ar = args(req);
    const code = strOf(ar, "expression") orelse "";
    const it = s.it;
    const saved = it.frame;
    defer it.frame = saved;
    if (intOf(ar, "frameId")) |id| if (frameAt(s, id)) |f| {
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
fn reload(s: *Server, a: Allocator, req: json.ObjectMap) !void {
    const it = s.it;
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
    it.frame = s.frames.items[s.frames.items.len - 1];
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

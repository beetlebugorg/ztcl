//! The optional event loop (capability `event`): `after`, `vwait`,
//! `update`, and `fileevent`.
//!
//! One loop serves an interpreter and its children. The state has a
//! list of timers, a list of idle scripts, and a list of channels with
//! a handler. One pass of the loop (`doOne`) does these steps:
//!
//! 1. It waits until a timer is due or a descriptor is ready. The wait
//!    is 0 when a caller does not wait or when an idle script exists.
//! 2. It runs the timers that are due, oldest due time first. A timer
//!    that a script makes during the pass runs in a later pass.
//! 3. It runs the handlers of the channels that are ready.
//! 4. When steps 2 and 3 ran no script, it runs the idle scripts that
//!    existed at the start of the step.
//!
//! Each script runs at the global level of its interpreter. An error
//! goes to the background error handler as an idle script. The time
//! comes from `Interp.event_host`, a callback of the embedder.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const cmds = @import("cmds.zig");
const child = @import("child.zig");
const trace = @import("trace.zig");
const sys = @import("sys.zig");
const thread = @import("thread.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// Microseconds on a clock that does not go back.
    now: *const fn (ctx: ?*anyopaque) i64,
    /// Blocks for a count of microseconds.
    sleep: *const fn (ctx: ?*anyopaque, micros: i64) void,
};

const BgError = struct { msg: []const u8, opts: []const u8, info: []const u8, ecode: []const u8, code: i64 };

const Timer = struct {
    id: u64,
    it: *Interp,
    script: []const u8,
    at: i64 = 0,
    idle: bool = false,
    /// A pending background error. It is an idle entry with no script.
    bg: ?BgError = null,
};

/// A channel with a handler: the interpreter and the channel name.
pub const Watch = struct { it: *Interp, name: []const u8 };

pub const State = struct {
    timers: std.ArrayList(*Timer) = .empty,
    idles: std.ArrayList(*Timer) = .empty,
    watches: std.ArrayList(Watch) = .empty,
    next_id: u64 = 0,
    a: std.mem.Allocator,
    /// The interpreter of a thread whose message queue is a source of
    /// the loop (capability `thread`).
    thread_it: ?*Interp = null,
};

/// Makes the message queue of the thread of `it` a source of the loop.
pub fn setSource(it: *Interp) std.mem.Allocator.Error!void {
    const s = state(it) catch return error.OutOfMemory;
    s.thread_it = it;
}

/// The thread interpreter whose queue a pass of `it` serves, or null.
fn source(s: *State, it: *Interp) ?*Interp {
    if (comptime !thread.supported) return null;
    const x = s.thread_it orelse return null;
    return if (x == it) x else null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn state(it: *Interp) Error!*State {
    if (it.events) |s| return s;
    var root = it;
    while (root.parent) |p| root = p;
    if (root.events == null) {
        const s = try root.alloc().create(State);
        s.* = .{ .a = root.alloc() };
        root.events = s;
    }
    it.events = root.events;
    return it.events.?;
}

fn now(it: *Interp) Error!i64 {
    const h = it.event_host orelse return it.fail("the embedder gave no event clock", .{});
    return h.now(h.ctx);
}

/// Removes the events of an interpreter that ends.
pub fn forget(it: *Interp) void {
    const s = it.events orelse return;
    inline for (.{ &s.timers, &s.idles }) |l| {
        var i: usize = 0;
        while (i < l.items.len) {
            if (l.items[i].it == it) _ = l.orderedRemove(i) else i += 1;
        }
    }
    var i: usize = 0;
    while (i < s.watches.items.len) {
        if (s.watches.items[i].it == it) _ = s.watches.orderedRemove(i) else i += 1;
    }
    it.events = null;
}

/// Adds a channel to the loop. The call does nothing for a known one.
pub fn watch(it: *Interp, name: []const u8) Error!void {
    const s = try state(it);
    for (s.watches.items) |w| if (w.it == it and eql(w.name, name)) return;
    try s.watches.append(s.a, .{ .it = it, .name = name });
}

pub fn unwatch(it: *Interp, name: []const u8) void {
    const s = it.events orelse return;
    for (s.watches.items, 0..) |w, i| {
        if (w.it == it and eql(w.name, name)) {
            _ = s.watches.orderedRemove(i);
            return;
        }
    }
}

/// Runs a script at the global level of `x`. `cur` is the interpreter
/// that runs the loop. Gives null when the script deleted `x`: the
/// memory of `x` is free then, and the result is gone with it.
fn runGlobal(cur: *Interp, x: *Interp, text: []const u8) Error!?cmds.Caught {
    const frame = x.frame;
    const ns = x.ns;
    x.frame = &x.global;
    x.ns = "";
    if (x == cur) {
        defer {
            x.frame = frame;
            x.ns = ns;
        }
        return try cmds.runCaught(x, x.compile(text));
    }
    const s = child.enter(cur, x);
    const r = cmds.runCaught(x, x.compile(text));
    x.frame = frame;
    x.ns = ns;
    // `leave` frees a deleted interpreter when its last call ends.
    var gone = false;
    var up: ?*Interp = x;
    while (up) |u| : (up = u.parent) {
        if (u.doomed) gone = true;
    }
    const failure: ?Error = if (r) |_| null else |e| child.passError(cur, x, e);
    child.leave(cur, x, s);
    if (failure) |e| return e;
    if (gone) return null;
    return r catch unreachable;
}

/// Queues a background error of `x`: the end of an event script with a
/// code that is not `ok`.
pub fn background(x: *Interp, c: cmds.Caught) Error!void {
    const s = try state(x);
    const t = try s.a.create(Timer);
    const opts = try x.str(try c.options(x));
    t.* = .{ .id = 0, .it = x, .script = "", .idle = true, .bg = .{
        .msg = try s.a.dupe(u8, try x.str(c.res)),
        .opts = try s.a.dupe(u8, opts),
        .info = try s.a.dupe(u8, if (c.code == 1) try x.str(c.error_info) else try x.str(c.res)),
        .ecode = try s.a.dupe(u8, try x.str(c.error_code)),
        .code = c.code,
    } };
    try s.idles.append(s.a, t);
}

fn runEvent(cur: *Interp, x: *Interp, text: []const u8) Error!void {
    var c = (try runGlobal(cur, x, text)) orelse return;
    if (c.code == 1) c.error_info = .{ .str = try std.fmt.allocPrint(x.alloc(), "{s}\n    (\"after\" script)", .{try x.str(c.error_info)}) };
    if (c.code != 0) try background(x, c);
}

fn errOut(x: *Interp, text: []const u8) void {
    if (x.output) |out| out.write(out.ctx, text);
}

fn quoted(x: *Interp, words: []const []const u8) Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (words, 0..) |w, i| {
        if (i > 0) try text.append(x.alloc(), ' ');
        try value.appendElement(x.alloc(), &text, w, true);
    }
    return text.items;
}

fn dropBackground(s: *State, x: *Interp) void {
    var i: usize = 0;
    while (i < s.idles.items.len) {
        const t = s.idles.items[i];
        if (t.it == x and t.bg != null) _ = s.idles.orderedRemove(i) else i += 1;
    }
}

/// Reports one background error through the handler of `interp
/// bgerror`. The default handler is `::tcl::Bgerror`.
fn report(cur: *Interp, s: *State, x: *Interp, b: BgError) Error!void {
    const a = x.alloc();
    const h = x.bg_handler orelse "::tcl::Bgerror";
    const text = try std.fmt.allocPrint(a, "{s} {s}", .{ h, try quoted(x, &.{ b.msg, b.opts }) });
    const c = (try runGlobal(cur, x, text)) orelse return;
    if (c.code == 3) dropBackground(s, x);
    if (c.code == 1) errOut(x, try std.fmt.allocPrint(a, "{s}\n", .{try x.str(c.res)}));
}

fn option(it: *Interp, pairs: []const Value, key: []const u8) Error!?Value {
    var i: usize = 0;
    var hit: ?Value = null;
    while (i + 1 < pairs.len) : (i += 2) {
        if (eql(try it.str(pairs[i]), key)) hit = pairs[i + 1];
    }
    return hit;
}

/// `::tcl::Bgerror msg options`: the default background error handler.
/// It calls the command `bgerror` with the message. With no such
/// command, it writes the error trace to the error output.
fn cmdBgerror(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3) return it.wrongArgs("::tcl::Bgerror msg options");
    const a = it.alloc();
    const pairs = try it.list(argv[2]);
    if (pairs.len % 2 != 0) return it.fail("missing value to go with key", .{});
    const level = (try option(it, pairs, "-level")) orelse return it.fail("missing return option \"-level\"", .{});
    if (level.asInt() == null) return it.fail("expected integer but got \"{s}\"", .{try it.str(level)});
    const code_v = (try option(it, pairs, "-code")) orelse return it.fail("missing return option \"-code\"", .{});
    const code = code_v.asInt() orelse return it.fail("expected integer but got \"{s}\"", .{try it.str(code_v)});
    var msg = try it.str(argv[1]);
    switch (code) {
        0 => return Value.empty,
        1 => {},
        3 => msg = "invoked \"break\" outside of a loop",
        4 => msg = "invoked \"continue\" outside of a loop",
        else => msg = try std.fmt.allocPrint(a, "command returned bad code: {d}", .{code}),
    }
    const info = (try option(it, pairs, "-errorinfo")) orelse Value{ .str = msg };
    const ecode = (try option(it, pairs, "-errorcode")) orelse Value{ .str = "NONE" };
    const frame = it.frame;
    const ns = it.ns;
    it.frame = &it.global;
    it.ns = "";
    defer {
        it.frame = frame;
        it.ns = ns;
    }
    try it.setVar("errorInfo", info);
    try it.setVar("errorCode", ecode);
    const words = try a.dupe(Value, &.{ .{ .str = "bgerror" }, .{ .str = msg } });
    var c: cmds.Caught = .{ .code = 1 };
    var tried = false;
    if (it.findCommand("bgerror")) |_| {
        tried = true;
        c = try cmds.runCaught(it, it.compile(try std.fmt.allocPrint(a, "bgerror {s}", .{try quoted(it, &.{msg})})));
    }
    if (c.code == 1) {
        // A hidden `bgerror` of a safe interpreter is the next choice.
        if (it.hidden.get("bgerror")) |hidden| {
            tried = true;
            if (it.call(hidden, words, null)) |_| {
                c = .{};
            } else |e| {
                if (e == error.OutOfMemory) return e;
                c = .{ .code = if (e == error.TclBreak) 3 else 1, .res = it.result };
            }
        }
    }
    if (c.code == 3) return error.TclBreak;
    if (c.code != 1) return Value.empty;
    if (!tried) {
        errOut(it, try std.fmt.allocPrint(a, "{s}\n", .{try it.str(info)}));
    } else {
        errOut(it, try std.fmt.allocPrint(a, "bgerror failed to handle background error.\n    Original error: {s}\n    Error in bgerror: {s}\n", .{ msg, try it.str(c.res) }));
    }
    return Value.empty;
}

fn has(list: []const *Timer, t: *Timer) ?usize {
    return std.mem.indexOfScalar(*Timer, list, t);
}

const chan_ok = sys.supported;

/// One pass of the loop. Gives true when a script ran. With `wait`, it
/// blocks until a script can run, and gives false only when no timer
/// and no channel handler exists.
pub fn doOne(it: *Interp, wait: bool, idle_only: bool) Error!bool {
    const s = try state(it);
    const a = it.alloc();
    const src = source(s, it);
    while (true) {
        var ran = false;
        if (src) |x| {
            if (!idle_only and try thread.serve(x, 64)) ran = true;
        }
        if (!idle_only) {
            var t_now = try now(it);
            var timeout: i64 = if (wait and s.idles.items.len == 0 and !ran) -1 else 0;
            for (s.timers.items) |t| {
                const left = @max(t.at - t_now, 0);
                if (timeout < 0 or left < timeout) timeout = left;
            }
            var wants: std.ArrayList(sys.Want) = .empty;
            var owners: std.ArrayList(Watch) = .empty;
            if (comptime chan_ok) {
                const chan = @import("chan.zig");
                for (s.watches.items) |w| {
                    const want = chan.wanted(w.it, w.name) orelse continue;
                    if (want.ready) timeout = 0;
                    if (want.wfd != want.fd and want.write) {
                        // A pipeline has one descriptor for each direction.
                        try wants.append(a, .{ .fd = want.wfd, .write = true });
                        try owners.append(a, w);
                        if (!want.read and !want.ready) continue;
                        try wants.append(a, .{ .fd = want.fd, .read = want.read, .can_read = want.ready });
                        try owners.append(a, w);
                        continue;
                    }
                    try wants.append(a, .{ .fd = want.fd, .read = want.read, .write = want.write, .can_read = want.ready });
                    try owners.append(a, w);
                }
            }
            if (wait and timeout < 0 and wants.items.len == 0) {
                // A thread waits for a message while another thread can
                // send one.
                if (src) |x| if (thread.canWake(x)) {
                    try thread.block(x, thread.slice_ns);
                    continue;
                };
                return false;
            }
            if (wants.items.len > 0) {
                // A message of another thread ends the poll at once.
                const wake: i32 = if (src) |x| thread.wakeFd(x) else -1;
                if (wake >= 0) try wants.append(a, .{ .fd = wake, .read = true });
                const ready_now = try a.alloc(bool, wants.items.len);
                for (wants.items, ready_now) |w, *r| r.* = w.can_read;
                var ms: i32 = if (timeout < 0) -1 else @intCast(@min(@divFloor(timeout + 999, 1000), 3_600_000));
                // The queue of a thread needs a check between polls.
                if (src != null and (ms < 0 or ms > 10)) ms = 10;
                sys.poll(a, wants.items, ms);
                for (wants.items, ready_now) |*w, r| w.can_read = w.can_read or r;
                if (wake >= 0) {
                    _ = wants.pop();
                    thread.drainWake(src.?);
                }
            } else if (timeout > 0) {
                if (src) |x| {
                    try thread.block(x, @intCast(@min(timeout, 1 << 40) * 1000));
                } else {
                    const h = it.event_host.?;
                    h.sleep(h.ctx, timeout);
                }
            }
            t_now = try now(it);
            // The timers that are due, oldest due time first.
            var due: std.ArrayList(*Timer) = .empty;
            for (s.timers.items) |t| {
                if (t.at <= t_now) try due.append(a, t);
            }
            std.mem.sort(*Timer, due.items, {}, struct {
                fn f(_: void, x: *Timer, y: *Timer) bool {
                    return if (x.at != y.at) x.at < y.at else x.id < y.id;
                }
            }.f);
            for (due.items) |t| {
                const k = has(s.timers.items, t) orelse continue;
                _ = s.timers.orderedRemove(k);
                ran = true;
                try runEvent(it, t.it, t.script);
            }
            if (comptime chan_ok) {
                const chan = @import("chan.zig");
                for (wants.items, owners.items) |w, o| {
                    if (!w.can_read and !w.can_write) continue;
                    // An earlier handler can close the channel.
                    var live = false;
                    for (s.watches.items) |x| {
                        if (x.it == o.it and eql(x.name, o.name)) live = true;
                    }
                    if (!live) continue;
                    if (try chan.serve(it, o.it, o.name, w.can_read, w.can_write)) ran = true;
                }
            }
        }
        if (!ran and s.idles.items.len > 0) {
            const snapshot = try a.dupe(*Timer, s.idles.items);
            for (snapshot) |t| {
                const k = has(s.idles.items, t) orelse continue;
                _ = s.idles.orderedRemove(k);
                ran = true;
                if (t.bg) |b| try report(it, s, t.it, b) else try runEvent(it, t.it, t.script);
            }
        }
        if (ran or !wait or idle_only) return ran;
    }
}

pub const Ran = enum { ok, failed, gone };

/// Runs a script of a channel handler for `chan.zig`. `gone` means
/// that the script deleted the interpreter: its memory is free.
pub fn runHandler(cur: *Interp, x: *Interp, text: []const u8) Error!Ran {
    const c = (try runGlobal(cur, x, text)) orelse return .gone;
    if (c.code != 0) try background(x, c);
    return if (c.code == 0) .ok else .failed;
}

fn idText(a: std.mem.Allocator, id: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "after#{d}", .{id});
}

fn findById(s: *State, it: *Interp, text: []const u8) ?*Timer {
    if (!std.mem.startsWith(u8, text, "after#")) return null;
    const id = std.fmt.parseInt(u64, text[6..], 10) catch return null;
    inline for (.{ &s.timers, &s.idles }) |l| {
        for (l.items) |t| {
            if (t.it == it and t.bg == null and t.id == id) return t;
        }
    }
    return null;
}

fn remove(s: *State, t: *Timer) void {
    inline for (.{ &s.timers, &s.idles }) |l| {
        if (has(l.items, t)) |k| _ = l.orderedRemove(k);
    }
}

fn joined(it: *Interp, words: []const Value) Error![]const u8 {
    if (words.len == 1) return it.str(words[0]);
    return cmds.concat(it, words);
}

fn cmdAfter(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("after option ?arg ...?");
    const s = try state(it);
    const a = it.alloc();
    const first = try it.str(argv[1]);
    if (argv[1].asInt()) |ms_in| {
        const ms = @max(ms_in, 0);
        const h = it.event_host orelse return it.fail("the embedder gave no event clock", .{});
        if (argv.len == 2) {
            // A plain sleep. Each second of it uses one step.
            var left: i64 = @as(i64, @min(ms, 1 << 40)) * 1000;
            while (left > 0) {
                const part = @min(left, 1_000_000);
                if (thread.supported and it.worker != null and !it.worker.?.is_main) {
                    try thread.nap(it, @intCast(part * 1000));
                } else h.sleep(h.ctx, part);
                left -= part;
                if (it.step_limit == 0) return it.fail("step limit reached", .{});
                it.step_limit -= 1;
            }
            return Value.empty;
        }
        const t = try s.a.create(Timer);
        t.* = .{ .id = s.next_id, .it = it, .script = try a.dupe(u8, try joined(it, argv[2..])), .at = h.now(h.ctx) + @as(i64, @min(ms, 1 << 40)) * 1000 };
        s.next_id += 1;
        try s.timers.append(s.a, t);
        return .{ .str = try idText(a, t.id) };
    }
    const subs = [_][]const u8{ "cancel", "idle", "info" };
    var sub: ?[]const u8 = null;
    for (subs) |n| {
        if (first.len > 0 and std.mem.startsWith(u8, n, first)) {
            if (sub != null) sub = "";
            sub = sub orelse n;
        }
    }
    if (sub == null or sub.?.len == 0) return it.failCode("TCL LOOKUP INDEX argument", "bad argument \"{s}\": must be cancel, idle, info, or an integer", .{first});
    if (eql(sub.?, "idle")) {
        if (argv.len < 3) return it.wrongArgs("after idle script ?script ...?");
        const t = try s.a.create(Timer);
        t.* = .{ .id = s.next_id, .it = it, .script = try a.dupe(u8, try joined(it, argv[2..])), .idle = true };
        s.next_id += 1;
        try s.idles.append(s.a, t);
        return .{ .str = try idText(a, t.id) };
    }
    if (eql(sub.?, "cancel")) {
        if (argv.len < 3) return it.wrongArgs("after cancel id|command");
        const text = try joined(it, argv[2..]);
        var hit: ?*Timer = null;
        // The script form matches first, as in Tcl.
        inline for (.{ &s.timers, &s.idles }) |l| {
            for (l.items) |t| {
                if (hit == null and t.it == it and t.bg == null and eql(t.script, text)) hit = t;
            }
        }
        if (hit == null) hit = findById(s, it, text);
        if (hit) |t| remove(s, t);
        return Value.empty;
    }
    // info
    if (argv.len == 2) {
        var out: std.ArrayList(Value) = .empty;
        inline for (.{ &s.idles, &s.timers }) |l| {
            var k = l.items.len;
            while (k > 0) {
                k -= 1;
                const t = l.items[k];
                if (t.it == it and t.bg == null) try out.append(a, .{ .str = try idText(a, t.id) });
            }
        }
        return value.wrapList(a, out.items);
    }
    if (argv.len != 3) return it.wrongArgs("after info ?id?");
    const id = try it.str(argv[2]);
    const t = findById(s, it, id) orelse return it.failCode(try std.fmt.allocPrint(a, "TCL LOOKUP EVENT {s}", .{id}), "event \"{s}\" doesn't exist", .{id});
    return value.newList(a, &.{ .{ .str = t.script }, .{ .str = if (t.idle) "idle" else "timer" } });
}

fn cmdVwait(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("vwait name");
    const name = try it.str(argv[1]);
    var done = false;
    const frame = it.frame;
    const ns = it.ns;
    it.frame = &it.global;
    it.ns = "";
    const added = trace.addFlag(it, name, &done);
    it.frame = frame;
    it.ns = ns;
    try added;
    defer {
        const f = it.frame;
        const n = it.ns;
        it.frame = &it.global;
        it.ns = "";
        trace.removeFlag(it, name, &done);
        it.frame = f;
        it.ns = n;
    }
    while (!done) {
        if (it.step_limit == 0) return it.fail("step limit reached", .{});
        if (!try doOne(it, true, false)) return it.fail("can't wait for variable \"{s}\": would wait forever", .{name});
    }
    return Value.empty;
}

fn cmdUpdate(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var idle_only = false;
    if (argv.len == 2) {
        const o = try it.str(argv[1]);
        if (o.len == 0 or !std.mem.startsWith(u8, "idletasks", o)) return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be idletasks", .{o});
        idle_only = true;
    } else if (argv.len != 1) return it.wrongArgs("update ?idletasks?");
    while (try doOne(it, false, idle_only)) {
        if (it.step_limit == 0) return it.fail("step limit reached", .{});
    }
    return Value.empty;
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("after", cmdAfter);
    try it.register("vwait", cmdVwait);
    try it.register("update", cmdUpdate);
    try it.register("tcl::Bgerror", cmdBgerror);
    if (comptime chan_ok) try it.register("fileevent", @import("chan.zig").cmdFileevent);
}

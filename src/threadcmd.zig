//! The `thread::*` commands of the capability `thread`.
//!
//! Each command works on the group of the calling thread (`thread.zig`).
//! A thread id is a name of the group, so a bad id gives an error and
//! never reaches another group. A command that waits runs the messages
//! of its own queue and checks the stop flag after each wait slice.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const thread = @import("thread.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;
const Worker = thread.Worker;
const Group = thread.Group;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn self(it: *Interp) Error!*Worker {
    return it.worker orelse it.fail("threads are off", .{});
}

/// The id of a thread handle, with the errors of the Thread package.
fn handle(it: *Interp, v: Value) Error!u64 {
    const text = try it.str(v);
    const id = thread.parseId(text);
    if (id == 0) return it.fail("invalid thread handle \"{s}\"", .{text});
    return id;
}

fn noThread(it: *Interp, id: u64) Error {
    return it.fail("thread \"tid0x{x}\" does not exist", .{id});
}

fn cmdCreate(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var joinable = false;
    var preserved = false;
    var level: thread.Isolation = .interp;
    var files_host = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (eql(o, "-joinable")) {
            joinable = true;
        } else if (eql(o, "-preserved")) {
            preserved = true;
        } else if (eql(o, "-isolation") and i + 1 < argv.len) {
            i += 1;
            const l = try it.str(argv[i]);
            level = std.meta.stringToEnum(thread.Isolation, l) orelse {
                if (eql(l, "wasm") or eql(l, "vm") or eql(l, "vm-confidential"))
                    return it.failCode("ZTCL ISOLATION LEVEL", "the isolation level {s} is not available yet", .{l});
                return it.fail("bad isolation level \"{s}\": must be interp or process", .{l});
            };
        } else if (eql(o, "-files") and i + 1 < argv.len) {
            i += 1;
            const f = try it.str(argv[i]);
            if (!eql(f, "host")) return it.fail("bad files \"{s}\": must be host", .{f});
            files_host = true;
        } else if (eql(o, "--")) {
            i += 1;
            break;
        } else break;
    }
    if (argv.len - i > 1) return it.wrongArgs("thread::create ?-joinable? ?script?");
    const script = if (i < argv.len) try it.str(argv[i]) else "";
    if (files_host and level == .interp) return it.fail("-files host needs -isolation process", .{});
    const id = try thread.createOpts(it, script, .{ .joinable = joinable, .preserved = preserved, .isolation = level, .files_host = files_host });
    return thread.idValue(it, id);
}

/// The worker of an optional id argument. The caller holds the group
/// lock while it uses the worker.
fn target(it: *Interp, g: *Group, me: *Worker, argv: []const Value, at: usize) Error!*Worker {
    if (at >= argv.len) return me;
    const id = try handle(it, argv[at]);
    return g.find(id) orelse noThread(it, id);
}

fn cmdPreserve(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len > 2) return it.wrongArgs("thread::preserve ?threadId?");
    const me = try self(it);
    const g = me.group;
    if (argv.len == 2) _ = try handle(it, argv[1]);
    g.lock.lock();
    defer g.lock.unlock();
    const w = try target(it, g, me, argv, 1);
    w.refs += 1;
    return .{ .int = w.refs };
}

fn release(it: *Interp, me: *Worker, argv: []const Value, at: usize, wait: bool) Error!Value {
    const g = me.group;
    if (at < argv.len) _ = try handle(it, argv[at]);
    g.lock.lock();
    const w = target(it, g, me, argv, at) catch |e| {
        g.lock.unlock();
        return e;
    };
    // The count does not go below zero, as in the Thread package.
    if (w.refs > 0) w.refs -= 1;
    const refs = w.refs;
    const id = w.id;
    if (refs <= 0 and !w.is_main) {
        w.released.store(true, .release);
        g.lock.unlock();
        w.wake();
    } else g.lock.unlock();
    if (wait and refs <= 0 and id != me.id) try waitGone(it, me, id);
    return .{ .int = refs };
}

/// Waits until the thread `id` ends.
fn waitGone(it: *Interp, me: *Worker, id: u64) Error!void {
    const g = me.group;
    while (true) {
        g.lock.lock();
        var live = false;
        for (g.workers.items) |w| if (w.id == id) {
            live = true;
        };
        if (!live) {
            g.lock.unlock();
            return;
        }
        g.ev.wait(&g.lock, thread.slice_ns);
        g.lock.unlock();
        _ = try thread.serve(it, 16);
    }
}

fn cmdRelease(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var i: usize = 1;
    var wait = false;
    if (i < argv.len and eql(try it.str(argv[i]), "-wait")) {
        wait = true;
        i += 1;
    }
    if (argv.len - i > 1) return it.wrongArgs("thread::release ?-wait? ?threadId?");
    return release(it, try self(it), argv, i, wait);
}

fn cmdUnwind(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("thread::unwind");
    _ = try release(it, try self(it), argv, 1, false);
    return Value.empty;
}

fn cmdId(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("thread::id");
    return thread.idValue(it, (try self(it)).id);
}

fn cmdNames(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("thread::names");
    const g = (try self(it)).group;
    var ids: std.ArrayList(u64) = .empty;
    g.lock.lock();
    for (g.workers.items) |w| if (w.state == .running and w.pool == null and (w.is_main or !w.isReleased())) {
        ids.append(it.alloc(), w.id) catch {
            g.lock.unlock();
            return error.OutOfMemory;
        };
    };
    g.lock.unlock();
    const out = try it.alloc().alloc(Value, ids.items.len);
    // The newest thread comes first, as in the Thread package.
    for (ids.items, 0..) |id, k| out[ids.items.len - 1 - k] = try thread.idValue(it, id);
    return value.wrapList(it.alloc(), out);
}

fn cmdExists(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("thread::exists id");
    const g = (try self(it)).group;
    const id = try handle(it, argv[1]);
    g.lock.lock();
    defer g.lock.unlock();
    return .{ .int = @intFromBool(g.find(id) != null) };
}

fn cmdExit(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len > 2) return it.wrongArgs("thread::exit ?status?");
    const me = try self(it);
    if (me.is_main) return it.fail("the main thread cannot exit with thread::exit", .{});
    const status = if (argv.len == 2) try it.int(argv[1]) else 666;
    me.status = status;
    me.exiting = true;
    // A script cannot catch the end of its compute limit, so the exit goes
    // up to the top of the thread.
    it.compute_limit = 0;
    return it.failCode("THREAD EXIT", "thread::exit", .{});
}

fn cmdCancel(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var i: usize = 1;
    var unwind = false;
    if (i < argv.len and eql(try it.str(argv[i]), "-unwind")) {
        unwind = true;
        i += 1;
    }
    if (argv.len - i < 1 or argv.len - i > 2) return it.wrongArgs("thread::cancel ?-unwind? id ?result?");
    const me = try self(it);
    const g = me.group;
    const id = try handle(it, argv[i]);
    const text: ?[]u8 = if (i + 1 < argv.len) g.alloc().dupe(u8, try it.str(argv[i + 1])) catch return thread.groupFull(it, error.GroupFull) else null;
    g.lock.lock();
    const w = g.find(id) orelse {
        g.lock.unlock();
        if (text) |t| g.alloc().free(t);
        return noThread(it, id);
    };
    if (w.is_main) {
        g.lock.unlock();
        if (text) |t| g.alloc().free(t);
        return it.fail("the main thread cannot be canceled", .{});
    }
    w.lock.lock();
    if (w.cancel_text) |old| g.alloc().free(old);
    w.cancel_text = text;
    w.lock.unlock();
    thread.stopWorker(w, if (unwind) thread.Flag.unwind else thread.Flag.cancel);
    g.lock.unlock();
    return Value.empty;
}

fn cmdErrorproc(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len > 2) return it.wrongArgs("thread::errorproc ?proc?");
    const me = try self(it);
    const g = me.group;
    g.lock.lock();
    defer g.lock.unlock();
    if (argv.len == 1) {
        if (g.errorproc_id != me.id) return Value.empty;
        return .{ .str = try it.alloc().dupe(u8, g.errorproc) };
    }
    const name = g.alloc().dupe(u8, try it.str(argv[1])) catch return thread.groupFull(it, error.GroupFull);
    g.alloc().free(g.errorproc);
    g.errorproc = name;
    g.errorproc_id = me.id;
    return Value.empty;
}

fn cmdSend(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var i: usize = 1;
    var async_send = false;
    var head = false;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (eql(o, "-async")) {
            async_send = true;
        } else if (eql(o, "-head")) {
            head = true;
        } else if (eql(o, "--")) {
            i += 1;
            break;
        } else break;
    }
    const n = argv.len - i;
    if (n < 2 or n > 3) return it.wrongArgs("thread::send ?-async? ?-head? id script ?varName?");
    const me = try self(it);
    const id = try handle(it, argv[i]);
    const script = try it.str(argv[i + 1]);
    const var_name: []const u8 = if (n == 3) try it.str(argv[i + 2]) else "";
    if (id == me.id and !async_send) {
        // A send to the own thread runs the script at once.
        const text = try it.alloc().dupe(u8, script);
        const c = try thread.atGlobal(it, runOwn, .{ it, text });
        if (var_name.len > 0) {
            try it.setVar(var_name, c.res);
            return .{ .int = c.code };
        }
        return finishOwn(it, c);
    }
    if (async_send) {
        try thread.waitRoom(it, id);
        thread.sendScript(me, id, script, 0, var_name, head) catch |e| return thread.sendError(it, e, id);
        return Value.empty;
    }
    const seq = me.next_seq;
    me.next_seq += 1;
    thread.sendScript(me, id, script, seq, "", head) catch |e| return thread.sendError(it, e, id);
    const r = try thread.awaitReply(it, id, seq);
    defer r.destroy(me.group.alloc());
    if (var_name.len > 0) {
        const v = try thread.unshare(it, r.res);
        try it.setVar(var_name, v);
        if (r.code == 1) {
            it.error_code = try thread.unshare(it, r.ecode);
            try it.setVar("::errorCode", it.error_code);
            try it.setVar("::errorInfo", .{ .str = try it.alloc().dupe(u8, r.info) });
        }
        return .{ .int = r.code };
    }
    return thread.applyReply(it, r);
}

fn runOwn(it: *Interp, text: []const u8) Error!@import("cmds.zig").Caught {
    return @import("cmds.zig").runCaught(it, it.compile(text));
}

fn finishOwn(it: *Interp, c: @import("cmds.zig").Caught) Error!Value {
    switch (c.code) {
        0 => return c.res,
        1 => {
            it.result = c.res;
            it.error_code = c.error_code;
            it.in_error = true;
            it.error_info = .empty;
            try it.error_info.appendSlice(it.alloc(), try it.str(c.error_info));
            it.skip_info = true;
            return error.TclError;
        },
        2 => {
            it.result = c.res;
            it.ret_code = .ok;
            it.ret_level = 1;
            return error.TclReturn;
        },
        3 => return error.TclBreak,
        4 => return error.TclContinue,
        else => {
            it.result = c.res;
            it.custom_code = @intCast(@min(c.code, std.math.maxInt(u32)));
            return error.TclCustom;
        },
    }
}

fn cmdBroadcast(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("thread::broadcast script");
    const me = try self(it);
    const g = me.group;
    const script = try it.str(argv[1]);
    var ids: std.ArrayList(u64) = .empty;
    g.lock.lock();
    for (g.workers.items) |w| if (w.id != me.id and w.state == .running and w.pool == null) {
        ids.append(it.alloc(), w.id) catch {
            g.lock.unlock();
            return error.OutOfMemory;
        };
    };
    g.lock.unlock();
    for (ids.items) |id| {
        thread.sendScript(me, id, script, 0, "", false) catch |e| switch (e) {
            error.NoThread => {},
            else => return thread.sendError(it, e, id),
        };
    }
    return Value.empty;
}

fn cmdWait(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("thread::wait");
    return thread.waitLoop(it);
}

fn cmdJoin(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("thread::join id");
    const me = try self(it);
    const g = me.group;
    const id = try handle(it, argv[1]);
    if (id == me.id) return it.fail("cannot join thread tid0x{x}", .{id});
    while (true) {
        g.lock.lock();
        for (g.ended.items, 0..) |w, k| {
            if (w.id != id) continue;
            _ = g.ended.orderedRemove(k);
            g.lock.unlock();
            const status = w.status;
            if (w.os) |t| t.join();
            w.os = null;
            g.lock.lock();
            g.zombies.append(g.gpa, w) catch {};
            g.lock.unlock();
            thread.reapZombies(g);
            return .{ .int = status };
        }
        var live: ?*Worker = null;
        for (g.workers.items) |w| if (w.id == id) {
            live = w;
        };
        const w = live orelse {
            g.lock.unlock();
            return it.fail("cannot join thread tid0x{x}", .{id});
        };
        if (!w.joinable) {
            g.lock.unlock();
            return it.fail("cannot join thread tid0x{x}", .{id});
        }
        g.ev.wait(&g.lock, thread.slice_ns);
        g.lock.unlock();
        _ = try thread.serve(it, 16);
    }
}

fn cmdConfigure(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("thread::configure threadlId ?optionName? ?value? ?optionName value?...");
    const me = try self(it);
    const g = me.group;
    const id = try handle(it, argv[1]);
    const bad = "bad option \"{s}\", should be one of -eventmark, -unwindonerror or -errorstate";
    for (argv[2..]) |o| _ = try it.str(o);
    var ints: [16]i64 = undefined;
    // Parse each value before the lock: an error leaves the thread as it was.
    if (argv.len > 3) {
        if (argv.len % 2 != 0) return it.wrongArgs("thread::configure threadlId ?optionName? ?value? ?optionName value?...");
        var k: usize = 2;
        while (k + 1 < argv.len) : (k += 2) {
            const o = try it.str(argv[k]);
            if (eql(o, "-eventmark")) {
                ints[(k / 2) % 16] = try it.int(argv[k + 1]);
                if (ints[(k / 2) % 16] < 0) return it.fail("expected a count but got \"{s}\"", .{try it.str(argv[k + 1])});
            } else if (eql(o, "-unwindonerror") or eql(o, "-errorstate")) {
                ints[(k / 2) % 16] = @intFromBool(try @import("expr.zig").truthy(it, argv[k + 1]));
            } else return it.fail(bad, .{o});
        }
    } else if (argv.len == 3) {
        const o = try it.str(argv[2]);
        if (!eql(o, "-eventmark") and !eql(o, "-unwindonerror") and !eql(o, "-errorstate")) return it.fail(bad, .{o});
    }
    g.lock.lock();
    defer g.lock.unlock();
    const w = g.find(id) orelse return noThread(it, id);
    if (argv.len == 2) {
        return .{ .str = try std.fmt.allocPrint(it.alloc(), "-eventmark {d} -unwindonerror {d} -errorstate 0", .{ w.eventmark, @intFromBool(w.unwind_on_error) }) };
    }
    if (argv.len == 3) {
        const o = try it.str(argv[2]);
        if (eql(o, "-eventmark")) return .{ .int = @intCast(w.eventmark) };
        if (eql(o, "-unwindonerror")) return .{ .int = @intFromBool(w.unwind_on_error) };
        return .{ .int = 0 };
    }
    var k: usize = 2;
    while (k + 1 < argv.len) : (k += 2) {
        const o = try it.str(argv[k]);
        const x = ints[(k / 2) % 16];
        if (eql(o, "-eventmark")) w.eventmark = @intCast(x) else if (eql(o, "-unwindonerror")) w.unwind_on_error = x != 0;
    }
    return Value.empty;
}

fn cmdEval(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var i: usize = 1;
    var name: ?[]const u8 = null;
    if (argv.len > 2 and eql(try it.str(argv[1]), "-lock")) {
        name = try it.str(argv[2]);
        i = 3;
    }
    if (i >= argv.len) return it.wrongArgs("thread::eval ?-lock <mutexHandle>? arg ?arg...?");
    const tsync = @import("tsync.zig");
    const key = try tsync.lockFor(it, name);
    defer tsync.unlockFor(it, key);
    const text = if (argv.len - i == 1) try it.str(argv[i]) else try @import("cmds.zig").concat(it, argv[i..]);
    const s = try it.compile(try it.alloc().dupe(u8, text));
    return it.evalScript(s);
}

fn cmdTransfer(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3) return it.wrongArgs("thread::transfer id channel");
    const id = try handle(it, argv[1]);
    return @import("tchan.zig").transfer(it, id, try it.str(argv[2]));
}

fn cmdDetach(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("thread::detach channel");
    return @import("tchan.zig").detach(it, try it.str(argv[1]));
}

fn cmdAttach(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("thread::attach channel");
    return @import("tchan.zig").attach(it, try it.str(argv[1]));
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    const list = .{
        .{ "thread::create", cmdCreate },
        .{ "thread::preserve", cmdPreserve },
        .{ "thread::release", cmdRelease },
        .{ "thread::unwind", cmdUnwind },
        .{ "thread::id", cmdId },
        .{ "thread::names", cmdNames },
        .{ "thread::exists", cmdExists },
        .{ "thread::exit", cmdExit },
        .{ "thread::cancel", cmdCancel },
        .{ "thread::errorproc", cmdErrorproc },
        .{ "thread::send", cmdSend },
        .{ "thread::broadcast", cmdBroadcast },
        .{ "thread::wait", cmdWait },
        .{ "thread::join", cmdJoin },
        .{ "thread::configure", cmdConfigure },
        .{ "thread::eval", cmdEval },
    };
    inline for (list) |e| try it.register(e[0], e[1]);
    if (comptime @import("tchan.zig").supported) {
        if (it.capabilities & @backingInt(interp.Capability.channels) != 0) {
            try it.register("thread::transfer", cmdTransfer);
            try it.register("thread::detach", cmdDetach);
            try it.register("thread::attach", cmdAttach);
        }
    }
    _ = try it.internNs("thread");
}

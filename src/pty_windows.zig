//! The optional `ztcl::pty` command on Windows: a program on a pseudo
//! console (ConPTY), with the commands of `pty.zig`. The plans are
//! `docs/dev/pty.md` and `docs/dev/exec-windows.md`.
//!
//! WARNING: a program on a pseudo console is outside the root folder of
//! `file` and outside each limit of the interpreter, as with `exec`. It
//! has the full power of the user that runs the embedder. It is not
//! sandboxed.
//!
//! `spawn` makes two pipes and `CreatePseudoConsole` with the size,
//! and closes the sides that the console keeps. The program starts as
//! in `proc_windows.zig` (the path of `resolve`, the environment block,
//! the Job Object), with the attribute
//! `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` and empty standard handles, so
//! the console of the program is the pseudo console and no handle of the
//! parent goes to it. The channel reads the output pipe and writes the
//! input pipe, in binary. The console sends the text of the program with
//! the escape sequences of a VT terminal.
//!
//! `resize` calls `ResizePseudoConsole`. `status` reads the exit code of
//! the process with no wait: `{exit code}`, or `{signal KILL}` after a
//! kill. `kill` with `INT` writes Ctrl-C (byte 3) to the input, as a
//! key press of a terminal, and each other signal ends the Job Object,
//! because Windows has no signals. `close` closes the pipes and the
//! pseudo console, which sends the close event to the program, and after
//! 500 ms the job ends with each process in it.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const chan = @import("chan.zig");
const fsroot = @import("fsroot.zig");
const sys = @import("sys.zig");
const pw = @import("proc_windows.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

pub const supported = pw.supported;

const HANDLE = *anyopaque;
const COORD = extern struct { x: i16, y: i16 };

extern "kernel32" fn CreatePseudoConsole(size: COORD, in: HANDLE, out: HANDLE, flags: u32, pc: *HANDLE) callconv(.winapi) i32;
extern "kernel32" fn ResizePseudoConsole(pc: HANDLE, size: COORD) callconv(.winapi) i32;
pub extern "kernel32" fn ClosePseudoConsole(pc: HANDLE) callconv(.winapi) void;

const usage = "ztcl::pty spawn|resize|size|status|kill ?arg ...?";

fn ptyChan(it: *Interp, v: Value) Error!*chan.Channel {
    const name = try it.str(v);
    const c = chan.lookup(it, name) orelse return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP CHANNEL {s}", .{name}), "can not find channel named \"{s}\"", .{name});
    if (!c.pty) return it.fail("channel \"{s}\" is not a pty", .{name});
    return c;
}

fn dim(it: *Interp, v: Value, what: []const u8) Error!u16 {
    const n = try it.int(v);
    if (n < 1 or n > 32767) return it.fail("bad {s} \"{d}\": must be from 1 to 32767", .{ what, n });
    return @intCast(n);
}

fn hasName(env: []const []const u8, name: []const u8) bool {
    for (env) |e| {
        if (e.len > name.len and e[name.len] == '=' and std.ascii.eqlIgnoreCase(e[0..name.len], name)) return true;
    }
    return false;
}

fn spawn(it: *Interp, argv: []const Value) Error!Value {
    const a = it.alloc();
    var cols: u16 = 80;
    var rows: u16 = 24;
    var cwd: ?[]const u8 = null;
    var extra: std.ArrayList([]const u8) = .empty;
    var i: usize = 2;
    while (i < argv.len) {
        const w = try it.str(argv[i]);
        if (w.len == 0 or w[0] != '-') break;
        if (std.mem.eql(u8, w, "--")) {
            i += 1;
            break;
        }
        if (i + 1 >= argv.len) return it.fail("value for \"{s}\" missing", .{w});
        if (std.mem.eql(u8, w, "-size")) {
            const l = try it.list(argv[i + 1]);
            if (l.len != 2) return it.fail("bad size \"{s}\": must be {{cols rows}}", .{try it.str(argv[i + 1])});
            cols = try dim(it, l[0], "column count");
            rows = try dim(it, l[1], "row count");
        } else if (std.mem.eql(u8, w, "-cwd")) {
            if (it.capabilities & @backingInt(interp.Capability.file) == 0 or !it.fs_ok()) return it.fail("-cwd needs the file capability", .{});
            cwd = try it.str(argv[i + 1]);
        } else if (std.mem.eql(u8, w, "-env")) {
            const l = try it.list(argv[i + 1]);
            if (l.len % 2 != 0) return it.fail("-env needs a list of names and values", .{});
            var k: usize = 0;
            while (k < l.len) : (k += 2) {
                const name = try it.str(l[k]);
                if (name.len == 0 or std.mem.indexOfScalar(u8, name, '=') != null) return it.fail("bad environment name \"{s}\"", .{name});
                try extra.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ name, try it.str(l[k + 1]) }));
            }
        } else return it.fail("bad option \"{s}\": must be -cwd, -env, or -size", .{w});
        i += 2;
    }
    if (i >= argv.len) return it.wrongArgs("ztcl::pty spawn ?-size {{cols rows}}? ?-cwd dir? ?-env list? program ?arg ...?");
    const word = try it.str(argv[i]);
    try pw.noTilde(it, word);
    const prog = try pw.resolve(it, word);
    const words = try a.alloc([]const u8, argv.len - i);
    for (argv[i..], words) |v, *w| w.* = try it.str(v);

    // The environment: the embedder's list, then `-env`, then TERM.
    var env: std.ArrayList([:0]const u8) = .empty;
    for (it.exec_host.env) |e| try env.append(a, e);
    for (extra.items) |e| try env.append(a, try a.dupeSentinel(u8, e, 0));
    var names: std.ArrayList([]const u8) = .empty;
    for (env.items) |e| try names.append(a, e);
    if (!hasName(names.items, "TERM")) try env.append(a, "TERM=xterm-256color");

    var cwd_path: ?[]const u8 = null;
    if (it.fs_ok()) {
        const rel = if (cwd) |p| try fsroot.need(it, p) else it.fs.cwd;
        cwd_path = try pw.folderPath(it, rel);
    }

    const in_pipe = try pw.pipe(it);
    const out_pipe = pw.pipe(it) catch |e| {
        sys.close(in_pipe[0]);
        sys.close(in_pipe[1]);
        return e;
    };
    var pc: HANDLE = undefined;
    const hr = CreatePseudoConsole(.{ .x = @intCast(cols), .y = @intCast(rows) }, pw.handleOf(in_pipe[0]), pw.handleOf(out_pipe[1]), 0, &pc);
    // The console keeps its own copies of its two sides.
    sys.close(in_pipe[0]);
    sys.close(out_pipe[1]);
    if (hr < 0) {
        sys.close(in_pipe[1]);
        sys.close(out_pipe[0]);
        return it.failCode("ZTCL PTY UNAVAILABLE", "couldn't create a pseudo console: error 0x{x}", .{@as(u32, @bitCast(hr))});
    }
    var tree = pw.treeOpen();
    tree.pty = pc;
    tree.cols = cols;
    tree.rows = rows;
    const pi = pw.spawnConsole(it, tree.job orelse {
        pw.treeClose(&tree);
        sys.close(in_pipe[1]);
        sys.close(out_pipe[0]);
        return it.fail("couldn't create a job object", .{});
    }, prog, words, try pw.envBlockOf(a, env.items), cwd_path, pc) catch |e| {
        pw.treeClose(&tree);
        sys.close(in_pipe[1]);
        sys.close(out_pipe[0]);
        return e;
    };
    const procs = try a.alloc(HANDLE, 1);
    procs[0] = pi.hProcess;
    tree.procs = procs;
    const c = try chan.adopt(it, "pty", out_pipe[0], true, true);
    c.wfd = in_pipe[1];
    c.kind = .pipe;
    c.pty = true;
    c.input = .binary;
    c.output = .binary;
    c.binary = true;
    c.buffering = "none";
    const pids = try a.alloc(i32, 1);
    pids[0] = @intCast(pi.dwProcessId);
    c.pids = pids;
    c.started = pw.nowMs();
    c.tree = tree;
    return .{ .str = c.name };
}

/// The exit code of the program of `c` when it ended.
fn poll(it: *Interp, c: *chan.Channel) void {
    if (c.pty_status != null or c.tree.procs.len == 0) return;
    if (it.exec_host.timeout_ms != 0 and pw.nowMs() >= c.started + it.exec_host.timeout_ms) {
        pw.treeKill(&c.tree, c.pids);
        c.pty_status = pw.waitProc(c.tree.procs[0], 0xffffffff);
        return;
    }
    c.pty_status = pw.waitProc(c.tree.procs[0], 0);
}

fn statusValue(it: *Interp, c: *chan.Channel) Error!Value {
    const s = c.pty_status orelse return .{ .str = "running" };
    var out: [2]Value = if (c.tree.killed and s == pw.kill_code)
        .{ .{ .str = "signal" }, .{ .str = "KILL" } }
    else
        .{ .{ .str = "exit" }, .{ .int = s } };
    return value.wrapList(it.alloc(), try it.alloc().dupe(Value, &out));
}

fn cmdPty(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs(usage);
    const sub = try it.str(argv[1]);
    if (std.mem.eql(u8, sub, "spawn")) return spawn(it, argv);
    if (std.mem.eql(u8, sub, "resize")) {
        if (argv.len != 5) return it.wrongArgs("ztcl::pty resize channel cols rows");
        const c = try ptyChan(it, argv[2]);
        const cols = try dim(it, argv[3], "column count");
        const rows = try dim(it, argv[4], "row count");
        const pc = c.tree.pty orelse return it.fail("channel \"{s}\" has no pseudo console", .{c.name});
        const hr = ResizePseudoConsole(pc, .{ .x = @intCast(cols), .y = @intCast(rows) });
        if (hr < 0) return it.fail("couldn't set the pty size: error 0x{x}", .{@as(u32, @bitCast(hr))});
        c.tree.cols = cols;
        c.tree.rows = rows;
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "size")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::pty size channel");
        const c = try ptyChan(it, argv[2]);
        var out = [2]Value{ .{ .int = c.tree.cols }, .{ .int = c.tree.rows } };
        return value.wrapList(it.alloc(), try it.alloc().dupe(Value, &out));
    }
    if (std.mem.eql(u8, sub, "status")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::pty status channel");
        const c = try ptyChan(it, argv[2]);
        poll(it, c);
        return statusValue(it, c);
    }
    if (std.mem.eql(u8, sub, "kill")) {
        if (argv.len != 3 and argv.len != 4) return it.wrongArgs("ztcl::pty kill channel ?signal?");
        const c = try ptyChan(it, argv[2]);
        const sig = if (argv.len == 4) try it.str(argv[3]) else "HUP";
        const name = if (std.mem.startsWith(u8, sig, "SIG")) sig[3..] else sig;
        const names = [_][]const u8{ "HUP", "INT", "QUIT", "KILL", "TERM", "CONT", "STOP", "WINCH", "1", "2", "3", "9", "15" };
        for (names) |n| {
            if (std.mem.eql(u8, n, name)) break;
        } else return it.fail("bad signal \"{s}\": must be HUP, INT, QUIT, KILL, TERM, CONT, STOP, WINCH, or a number", .{sig});
        poll(it, c);
        if (c.pty_status != null) return .{ .str = "" };
        if (std.mem.eql(u8, name, "INT") or std.mem.eql(u8, name, "2")) {
            _ = sys.write(c.wfd, "\x03");
        } else if (!std.mem.eql(u8, name, "CONT") and !std.mem.eql(u8, name, "STOP") and !std.mem.eql(u8, name, "WINCH")) {
            pw.treeKill(&c.tree, c.pids);
        }
        return .{ .str = "" };
    }
    return it.fail("bad option \"{s}\": must be kill, resize, size, spawn, or status", .{sub});
}

/// Ends the program of a PTY channel that closed. The close of the
/// pseudo console sends the close event to the program, and a tree that
/// still runs after 500 ms ends.
pub fn hangup(it: *Interp, c: *chan.Channel) void {
    if (c.tree.pty) |pc| ClosePseudoConsole(pc);
    c.tree.pty = null;
    var waited: i32 = 0;
    while (c.pty_status == null and waited < 500) : (waited += 10) {
        poll(it, c);
        if (c.pty_status != null) break;
        pw.sleepMs(10);
    }
    pw.treeKill(&c.tree, c.pids);
    if (c.pty_status == null and c.tree.procs.len > 0) c.pty_status = pw.waitProc(c.tree.procs[0], 0xffffffff);
    pw.treeClose(&c.tree);
    c.pids = &.{};
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("ztcl::pty", cmdPty);
}

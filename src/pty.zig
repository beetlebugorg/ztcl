//! The optional `ztcl::pty` command: a program on a pseudo-terminal
//! (capability `exec`). The plan is `docs/dev/pty.md`.
//!
//! WARNING: a program on a PTY is outside the root folder of `file` and
//! outside each limit of the interpreter, as with `exec`. It has the
//! full power of the user that runs the embedder. It is not sandboxed.
//!
//! `spawn` opens `/dev/ptmx`, unlocks it, and gets the other side with
//! TIOCGPTPEER (or TIOCGPTN and an open of `/dev/pts/N` on a kernel
//! before 4.13). The child joins the process tree of `exec`, calls
//! `setsid`, sets the PTY as its controlling terminal with TIOCSCTTY,
//! puts it on descriptors 0, 1, and 2, and runs `execve`. The parent
//! keeps the master side as a binary channel. A report pipe gives the
//! error of a failed `execve` to the parent, as in `exec`.
//!
//! `resize` writes the window size with TIOCSWINSZ, and the kernel
//! sends SIGWINCH to the foreground process group. `status` collects
//! the exit status with a wait that does not block. `close` closes the
//! master side, so the kernel sends SIGHUP to the session. After a wait
//! of 500 ms, `hangup` kills each process of the tree that still runs.
//!
//! macOS has the PTY of `pty_mac.zig`: `posix_openpt` and `posix_spawn`
//! with a new session, as the plan has it. On Windows, `spawn` gives an
//! error. The design of ConPTY is in the plan.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const chan = @import("chan.zig");
const fsroot = @import("fsroot.zig");
const proc = @import("proc.zig");
const sys = @import("sys.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;
const linux = sys.os;
const on_mac = builtin.os.tag == .macos;
const mac = @import("pty_mac.zig");

/// True on the platforms where `spawn` starts a program.
/// The same targets as `exec`, because the PTY uses its process tree:
/// Linux and arm64 macOS. x86-64 macOS has no `exec`, so it has no PTY.
pub const supported = proc.supported and (builtin.os.tag == .linux or on_mac);

const usage = "ztcl::pty spawn|resize|size|status|kill ?arg ...?";

fn unavailable(it: *Interp) Error {
    const name = switch (builtin.os.tag) {
        .macos => "macOS",
        .windows => "Windows",
        else => "this platform",
    };
    return it.failCode("ZTCL PTY UNAVAILABLE", "ztcl::pty is not available on {s} yet", .{name});
}

fn ptyChan(it: *Interp, v: Value) Error!*chan.Channel {
    const name = try it.str(v);
    const c = chan.lookup(it, name) orelse return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP CHANNEL {s}", .{name}), "can not find channel named \"{s}\"", .{name});
    if (!c.pty) return it.fail("channel \"{s}\" is not a pty", .{name});
    return c;
}

fn dim(it: *Interp, v: Value, what: []const u8) Error!u16 {
    const n = try it.int(v);
    if (n < 1 or n > 10000) return it.fail("bad {s} \"{d}\": must be from 1 to 10000", .{ what, n });
    return @intCast(n);
}

fn setSize(fd: i32, cols: u16, rows: u16) linux.E {
    if (comptime !supported) return .NOSYS;
    if (comptime on_mac) return mac.setSize(fd, cols, rows);
    var ws: std.posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    return linux.errno(linux.ioctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&ws)));
}

/// Opens a PTY pair. Gives the master and the other side.
fn openPair(it: *Interp) Error![2]i32 {
    const mrc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
    if (linux.errno(mrc) != .SUCCESS) return proc.posix(it, linux.errno(mrc), "couldn't open a pty: ");
    const m: i32 = @intCast(mrc);
    errdefer sys.close(m);
    var unlock: c_int = 0;
    const urc = linux.ioctl(m, linux.T.IOCSPTLCK, @intFromPtr(&unlock));
    if (linux.errno(urc) != .SUCCESS) return proc.posix(it, linux.errno(urc), "couldn't unlock the pty: ");
    const flags: u32 = @bitCast(linux.O{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
    const prc = linux.ioctl(m, linux.T.IOCGPTPEER, flags);
    if (linux.errno(prc) == .SUCCESS) return .{ m, @intCast(prc) };
    // A kernel before 4.13: open the other side by its number.
    var n: c_uint = 0;
    const nrc = linux.ioctl(m, linux.T.IOCGPTN, @intFromPtr(&n));
    if (linux.errno(nrc) != .SUCCESS) return proc.posix(it, linux.errno(nrc), "couldn't find the pty: ");
    var buf: [32:0]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "/dev/pts/{d}", .{n}, 0) catch unreachable;
    const src = linux.open(path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
    if (linux.errno(src) != .SUCCESS) return proc.posix(it, linux.errno(src), "couldn't open the pty: ");
    return .{ m, @intCast(src) };
}

fn hasName(env: []const []const u8, name: []const u8) bool {
    for (env) |e| {
        if (e.len > name.len and e[name.len] == '=' and std.mem.eql(u8, e[0..name.len], name)) return true;
    }
    return false;
}

fn spawn(it: *Interp, argv: []const Value) Error!Value {
    if (comptime !supported) return unavailable(it);
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
    try proc.noTilde(it, word);
    const prog = try proc.resolve(it, word);
    const av = try a.allocSentinel(?[*:0]const u8, argv.len - i, null);
    for (argv[i..], 0..) |v, j| av[j] = (try a.dupeSentinel(u8, try it.str(v), 0)).ptr;

    // The environment: the embedder's list, then `-env`, then TERM.
    var env: std.ArrayList([]const u8) = .empty;
    for (it.exec_host.env) |e| try env.append(a, e);
    for (extra.items) |e| try env.append(a, e);
    if (!hasName(env.items, "TERM")) try env.append(a, "TERM=xterm-256color");
    const envp = try a.allocSentinel(?[*:0]const u8, env.items.len, null);
    for (env.items, 0..) |e, j| envp[j] = (try a.dupeSentinel(u8, e, 0)).ptr;

    var cwd_fd: i32 = -1;
    if (it.fs_ok()) {
        const rel = if (cwd) |p| try fsroot.need(it, p) else it.fs.cwd;
        cwd_fd = switch (try fsroot.openRel(it, rel, .{ .directory = true }, 0)) {
            .fd => |x| x,
            .err => |e| return proc.posix(it, e, "couldn't open the working folder: "),
        };
    }
    defer if (cwd_fd >= 0) sys.close(cwd_fd);

    if (comptime on_mac) return spawnMac(it, word, prog, av, envp, cwd_fd, cols, rows);
    const pair = try openPair(it);
    const m = pair[0];
    const s = pair[1];
    var keep_m = false;
    defer if (!keep_m) sys.close(m);
    defer sys.close(s);
    const se = setSize(m, cols, rows);
    if (se != .SUCCESS) return proc.posix(it, se, "couldn't set the pty size: ");

    const report = try proc.pipe(it);
    var tree = proc.treeOpen();
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        sys.close(report[0]);
        sys.close(report[1]);
        proc.treeClose(&tree);
        return proc.posix(it, linux.errno(rc), "couldn't fork child process: ");
    }
    if (rc == 0) {
        // The child. It uses only system calls from here.
        var msg: u32 = 0;
        if (tree.procs >= 0) {
            const e = linux.errno(linux.write(tree.procs, "0", 1));
            if (e != .SUCCESS) {
                msg = @backingInt(e);
                _ = linux.write(report[1], std.mem.asBytes(&msg), 4);
                linux.exit(127);
            }
        }
        _ = linux.setsid();
        _ = linux.ioctl(s, linux.T.IOCSCTTY, 0);
        const s0: i32 = @intCast(linux.fcntl(s, linux.F.DUPFD_CLOEXEC, 10));
        _ = linux.dup2(s0, 0);
        _ = linux.dup2(s0, 1);
        _ = linux.dup2(s0, 2);
        if (cwd_fd >= 0) _ = linux.fchdir(cwd_fd);
        msg = @backingInt(linux.errno(linux.execve(prog.ptr, av.ptr, envp.ptr)));
        _ = linux.write(report[1], std.mem.asBytes(&msg), 4);
        linux.exit(127);
    }
    const pid: i32 = @intCast(rc);
    tree.pgid = pid;
    sys.close(report[1]);
    var msg: u32 = 0;
    const got = switch (sys.read(report[0], std.mem.asBytes(&msg))) {
        .n => |n| n == 4,
        else => false,
    };
    sys.close(report[0]);
    if (got) {
        _ = proc.waitPid(pid, true);
        proc.treeClose(&tree);
        return proc.cannotRun(it, word, @fromBackingInt(@intCast(msg)));
    }
    const c = try adopt(it, m, pid, tree);
    keep_m = true;
    return .{ .str = c.name };
}

/// The channel of the master side of a PTY with its program.
fn adopt(it: *Interp, m: i32, pid: i32, tree: proc.Tree) Error!*chan.Channel {
    const a = it.alloc();
    const c = try chan.adopt(it, "pty", m, true, true);
    c.kind = .pipe;
    c.pty = true;
    c.input = .binary;
    c.output = .binary;
    c.binary = true;
    c.buffering = "none";
    const pids = try a.alloc(i32, 1);
    pids[0] = pid;
    c.pids = pids;
    c.started = proc.nowMs();
    c.tree = tree;
    return c;
}

/// `spawn` on macOS: the master side, the size, and `posix_spawn` of the
/// program on the other side in a new session.
fn spawnMac(it: *Interp, word: []const u8, prog: [:0]const u8, av: [*:null]?[*:0]const u8, envp: [*:null]?[*:0]const u8, cwd_fd: i32, cols: u16, rows: u16) Error!Value {
    var name: [128]u8 = undefined;
    const m = switch (mac.openMaster(&name)) {
        .fd => |x| x,
        .err => |e| return proc.posix(it, e, "couldn't open a pty: "),
    };
    var keep_m = false;
    defer if (!keep_m) sys.close(m);
    // macOS answers EIO to a size on the master side while the other side
    // has no open. The parent opens it, with no controlling terminal, for
    // the size and until the program has it.
    const s = switch (mac.openOther(@ptrCast(&name))) {
        .fd => |x| x,
        .err => |e| return proc.posix(it, e, "couldn't open the pty: "),
    };
    defer sys.close(s);
    const se = mac.setSize(s, cols, rows);
    if (se != .SUCCESS) return proc.posix(it, se, "couldn't set the pty size: ");
    var tree = proc.treeOpen();
    const pid = switch (mac.start(prog.ptr, av, envp, @ptrCast(&name), cwd_fd)) {
        .pid => |x| x,
        .err => |e| {
            proc.treeClose(&tree);
            return proc.cannotRun(it, word, e);
        },
    };
    // The child leads a new session, so its group has its pid.
    tree.pgid = pid;
    const c = try adopt(it, m, pid, tree);
    keep_m = true;
    return .{ .str = c.name };
}

/// Collects the exit status of the program of `c` when it ended.
fn poll(it: *Interp, c: *chan.Channel) void {
    if (c.pty_status != null or c.pids.len == 0) return;
    if (it.exec_host.timeout_ms != 0 and proc.nowMs() >= c.started + it.exec_host.timeout_ms) {
        proc.treeKill(&c.tree, c.pids);
        c.pty_status = proc.waitPid(c.pids[0], true);
        return;
    }
    c.pty_status = proc.waitPid(c.pids[0], false);
}

fn statusValue(it: *Interp, st: ?u32) Error!Value {
    const s = st orelse return .{ .str = "running" };
    var out: [2]Value = undefined;
    if (s & 0x7f == 0) {
        out = .{ .{ .str = "exit" }, .{ .int = (s >> 8) & 0xff } };
    } else {
        const full = proc.signalName(s & 0x7f)[0];
        const name: Value = if (std.mem.startsWith(u8, full, "SIG")) .{ .str = full[3..] } else .{ .int = s & 0x7f };
        out = .{ .{ .str = "signal" }, name };
    }
    return value.wrapList(it.alloc(), try it.alloc().dupe(Value, &out));
}

fn signalOf(it: *Interp, v: Value) Error!u32 {
    const w = try it.str(v);
    const name = if (std.mem.startsWith(u8, w, "SIG")) w[3..] else w;
    const names = [_]struct { []const u8, u32 }{ .{ "HUP", 1 }, .{ "INT", 2 }, .{ "QUIT", 3 }, .{ "KILL", 9 }, .{ "TERM", 15 }, .{ "CONT", if (on_mac) 19 else 18 }, .{ "STOP", if (on_mac) 17 else 19 }, .{ "WINCH", 28 } };
    for (names) |n| if (std.mem.eql(u8, n[0], name)) return n[1];
    const k = std.fmt.parseInt(u32, w, 10) catch return it.fail("bad signal \"{s}\": must be HUP, INT, QUIT, KILL, TERM, CONT, STOP, WINCH, or a number", .{w});
    if (k == 0 or k > 64) return it.fail("bad signal \"{s}\"", .{w});
    return k;
}

fn cmdPty(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs(usage);
    const sub = try it.str(argv[1]);
    if (std.mem.eql(u8, sub, "spawn")) return spawn(it, argv);
    if (comptime !supported) return unavailable(it);
    if (std.mem.eql(u8, sub, "resize")) {
        if (argv.len != 5) return it.wrongArgs("ztcl::pty resize channel cols rows");
        const c = try ptyChan(it, argv[2]);
        const e = setSize(c.fd, try dim(it, argv[3], "column count"), try dim(it, argv[4], "row count"));
        if (e != .SUCCESS) return proc.posix(it, e, "couldn't set the pty size: ");
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "size")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::pty size channel");
        const c = try ptyChan(it, argv[2]);
        var ws: std.posix.winsize = undefined;
        const e = if (comptime on_mac) mac.getSize(c.fd, &ws) else linux.errno(linux.ioctl(c.fd, linux.T.IOCGWINSZ, @intFromPtr(&ws)));
        if (e != .SUCCESS) return proc.posix(it, e, "couldn't read the pty size: ");
        var out = [2]Value{ .{ .int = ws.col }, .{ .int = ws.row } };
        return value.wrapList(it.alloc(), try it.alloc().dupe(Value, &out));
    }
    if (std.mem.eql(u8, sub, "status")) {
        if (argv.len != 3) return it.wrongArgs("ztcl::pty status channel");
        const c = try ptyChan(it, argv[2]);
        poll(it, c);
        return statusValue(it, c.pty_status);
    }
    if (std.mem.eql(u8, sub, "kill")) {
        if (argv.len != 3 and argv.len != 4) return it.wrongArgs("ztcl::pty kill channel ?signal?");
        const c = try ptyChan(it, argv[2]);
        const sig: u32 = if (argv.len == 4) try signalOf(it, argv[3]) else 1;
        poll(it, c);
        if (c.pty_status == null and c.tree.pgid > 0) _ = linux.kill(-c.tree.pgid, @fromBackingInt(@intCast(sig)));
        return .{ .str = "" };
    }
    return it.fail("bad option \"{s}\": must be kill, resize, size, spawn, or status", .{sub});
}

/// Ends the program of a PTY channel that closed. The kernel sent
/// SIGHUP when the master side closed. A tree that still runs after
/// 500 ms gets SIGKILL.
pub fn hangup(it: *Interp, c: *chan.Channel) void {
    if (comptime !supported) return;
    var waited: i32 = 0;
    while (c.pty_status == null and waited < 500) : (waited += 10) {
        poll(it, c);
        if (c.pty_status != null) break;
        proc.sleepMs(10);
    }
    proc.treeKill(&c.tree, c.pids);
    if (c.pty_status == null and c.pids.len > 0) c.pty_status = proc.waitPid(c.pids[0], true);
    proc.treeClose(&c.tree);
    c.pids = &.{};
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("ztcl::pty", cmdPty);
}

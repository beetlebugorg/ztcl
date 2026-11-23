//! The optional `exec` command, `pid`, and command pipelines
//! (capability `exec`).
//!
//! WARNING: a process is outside the root folder of `file` and outside
//! each limit of the interpreter. A script with `exec` has the full
//! power of the user that runs the embedder. This capability is not
//! sandboxed.
//!
//! `exec` runs each program directly from its argument list. It uses no
//! shell. The words follow the rules of Tcl: `|` and `|&` separate the
//! programs of a pipeline, and the `<`, `<<`, `<@`, `>`, `>>`, `2>`,
//! `>&`, `>@`, `2>@`, and `2>@1` forms redirect. A last word `&` runs
//! the pipeline in the background.
//!
//! The embedder sets `Interp.exec_host`:
//! - `allow` is a list of programs. With a list, each other program is
//!   an error before any process starts.
//! - `timeout_ms` is the longest run time of a pipeline. At the end of
//!   that time the process group gets SIGKILL.
//! - `env` is the whole environment of each program.
//!
//! Each pipeline is one process group. `abandonAll` sends SIGKILL to
//! each group that still runs when the interpreter ends, so no process
//! stays behind.
//!
//! The error output and the text of `<<` use an anonymous memory file,
//! so the parent waits on one descriptor only. macOS has no memory file,
//! so it uses a temporary file with its name removed at once.
//!
//! Linux starts each program with fork and execve. macOS uses posix_spawn
//! with POSIX_SPAWN_CLOEXEC_DEFAULT, so a program gets descriptors 0, 1,
//! and 2 and no other, and with POSIX_SPAWN_SETPGROUP for the group.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const chan = @import("chan.zig");
const fsroot = @import("fsroot.zig");
const sys = @import("sys.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;
const linux = sys.os;

const builtin = @import("builtin");
const on_mac = builtin.os.tag == .macos;
pub const supported = builtin.os.tag == .linux or (on_mac and builtin.cpu.arch == .aarch64);

pub const Host = struct {
    /// The programs that a script can run, as the word of the script
    /// or as a full path. Null allows each program.
    allow: ?[]const []const u8 = null,
    /// The longest run time of a pipeline in milliseconds. 0 is no limit.
    timeout_ms: u32 = 0,
    /// The environment of each program: `NAME=value` strings.
    env: []const [:0]const u8 = &.{},
};

pub const State = struct {
    /// The process groups of the background pipelines.
    groups: std.ArrayList(Group) = .empty,
};

const Group = struct { pgid: i32, pids: []const i32, start: i64 };

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
}

fn posix(it: *Interp, e: linux.E, what: []const u8) Error {
    const f = sys.failOf(e);
    const code = try std.fmt.allocPrint(it.alloc(), "POSIX {s} {{{s}}}", .{ f.name, f.text });
    return it.failCode(code, "{s}{s}", .{ what, f.text });
}

const One = struct {
    words: std.ArrayList([]const u8) = .empty,
    /// True when the error output goes to the next program too.
    err_too: bool = false,
};

const Target = union(enum) {
    none,
    /// A descriptor that the parent keeps.
    fd: i32,
    /// A descriptor that the parent closes after the start.
    owned: i32,
    /// The standard output of the same program (`2>@1`).
    to_out,
};

const Plan = struct {
    cmds: std.ArrayList(One) = .empty,
    in: Target = .none,
    out: Target = .none,
    err: Target = .none,
    background: bool = false,
    ignore_err: bool = false,
    keep_newline: bool = false,
};

fn closeTarget(t: Target) void {
    if (t == .owned) sys.close(t.owned);
}

fn closePlan(p: *Plan) void {
    closeTarget(p.in);
    closeTarget(p.out);
    closeTarget(p.err);
    p.in = .none;
    p.out = .none;
    p.err = .none;
}

/// A read and write file with no name, on macOS: in the root folder, or
/// in /tmp when the root has no room for it or there is no root.
fn namelessFile(it: *Interp) Error!i32 {
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true };
    var tmp: i32 = -1;
    defer if (tmp >= 0) sys.close(tmp);
    var last: linux.E = .NOENT;
    for (0..2) |place| {
        var dir = it.fs.fd;
        if (place == 1 or !it.fs_ok()) {
            const rc = linux.open("/tmp", .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
            if (linux.errno(rc) != .SUCCESS) return posix(it, linux.errno(rc), "couldn't create a temporary file: ");
            tmp = @intCast(rc);
            dir = tmp;
        }
        for (0..64) |_| {
            var name: [40:0]u8 = undefined;
            const z = std.fmt.bufPrintZ(&name, ".ztcl-{d}-{x}", .{ linux.getpid(), arc4random() }) catch unreachable;
            const rc = linux.openat(dir, z, flags, 0o600);
            const e = linux.errno(rc);
            if (e == .EXIST) continue;
            last = e;
            if (e != .SUCCESS) break;
            _ = linux.unlinkat(dir, z, 0);
            return @intCast(rc);
        }
        if (tmp >= 0) break;
    }
    return posix(it, last, "couldn't create a temporary file: ");
}

/// Starts one program on macOS. Tries each path. Gives the pid, or an
/// error in the form of `linux.errno`.
fn spawnMac(paths: []const [:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, in_fd: i32, out_fd: i32, err_fd: i32, cwd_fd: i32, pgid: i32) usize {
    const fail = struct {
        fn of(e: linux.E) usize {
            return @bitCast(-@as(isize, @intFromEnum(e)));
        }
    }.of;
    const c = std.c;
    const set_pgroup: c_short = 0x0002;
    const cloexec_default: c_short = 0x4000;
    // Copies above 2, so one dup2 cannot overwrite the source of the next.
    var copies: [3]i32 = .{ -1, -1, -1 };
    defer for (copies) |x| {
        if (x >= 0) sys.close(x);
    };
    for ([_]i32{ in_fd, out_fd, err_fd }, 0..) |fd, k| {
        const rc = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 10);
        if (linux.errno(rc) != .SUCCESS) return fail(linux.errno(rc));
        copies[k] = @intCast(rc);
    }
    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return fail(.NOMEM);
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    var attr: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attr) != 0) return fail(.NOMEM);
    defer _ = c.posix_spawnattr_destroy(&attr);
    for (copies, 0..) |x, k| {
        const rc = c.posix_spawn_file_actions_adddup2(&actions, x, @intCast(k));
        if (rc != 0) return fail(@enumFromInt(rc));
    }
    if (cwd_fd >= 0) {
        const rc = c.posix_spawn_file_actions_addfchdir_np(&actions, cwd_fd);
        if (rc != 0) return fail(@enumFromInt(rc));
    }
    if (c.posix_spawnattr_setflags(&attr, @bitCast(set_pgroup | cloexec_default)) != 0) return fail(.INVAL);
    if (posix_spawnattr_setpgroup(&attr, pgid) != 0) return fail(.INVAL);
    var last: linux.E = .NOENT;
    for (paths) |p| {
        var pid: c.pid_t = 0;
        const rc = c.posix_spawn(&pid, p.ptr, &actions, &attr, @ptrCast(argv), @ptrCast(envp));
        if (rc == 0) return @intCast(pid);
        const e: linux.E = @enumFromInt(rc);
        if (e != .NOENT and e != .NOTDIR) last = e;
    }
    return fail(last);
}

extern "c" fn arc4random() u32;
extern "c" fn posix_spawnattr_setpgroup(attr: *std.c.posix_spawnattr_t, pgroup: std.c.pid_t) c_int;

fn memFile(it: *Interp, text: []const u8) Error!i32 {
    const fd: i32 = if (comptime on_mac) try namelessFile(it) else blk: {
        const rc = linux.memfd_create("ztcl", linux.MFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return posix(it, linux.errno(rc), "couldn't create a memory file: ");
        break :blk @intCast(rc);
    };
    var at: usize = 0;
    while (at < text.len) {
        switch (sys.write(fd, text[at..])) {
            .n => |n| at += n,
            else => break,
        }
    }
    _ = linux.lseek(fd, 0, 0);
    return fd;
}

/// A path of the form `~user` is an error: no user lookup exists.
fn noTilde(it: *Interp, path: []const u8) Error!void {
    if (path.len < 2 or path[0] != '~' or path[1] == '/') return;
    const end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    return it.fail("user \"{s}\" doesn't exist", .{path[1..end]});
}

fn openFile(it: *Interp, path: []const u8, flags: sys.OpenFlags, what: []const u8) Error!i32 {
    const a = it.alloc();
    try noTilde(it, path);
    if (it.fs_ok()) {
        const rel = (try fsroot.normal(it, path)) orelse return it.failCode("POSIX EACCES {permission denied}", "couldn't {s} file \"{s}\": permission denied", .{ what, path });
        return switch (try fsroot.openRel(it, rel, flags, 0o666)) {
            .fd => |x| x,
            .err => |e| posix(it, e, try std.fmt.allocPrint(a, "couldn't {s} file \"{s}\": ", .{ what, path })),
        };
    }
    const rc = linux.open(try a.dupeZ(u8, path), fsroot.hostFlags(flags), 0o666);
    if (linux.errno(rc) != .SUCCESS) return posix(it, linux.errno(rc), try std.fmt.allocPrint(a, "couldn't {s} file \"{s}\": ", .{ what, path }));
    return @intCast(rc);
}

fn chanFd(it: *Interp, name: []const u8, write: bool) Error!i32 {
    const c = chan.lookup(it, name) orelse return it.fail("can not find channel named \"{s}\"", .{name});
    if (write) {
        if (!c.writable) return it.fail("channel \"{s}\" wasn't opened for writing", .{name});
        try chan.flushChannel(it, c);
        return if (c.wfd >= 0) c.wfd else c.fd;
    }
    if (!c.readable) return it.fail("channel \"{s}\" wasn't opened for reading", .{name});
    return c.fd;
}

/// Reads the words of `exec` into a plan. Each redirection opens here.
fn parse(it: *Interp, words: []const []const u8, plan: *Plan) Error!void {
    const a = it.alloc();
    var cur: One = .{};
    var i: usize = 0;
    var n = words.len;
    if (n > 0 and eql(words[n - 1], "&")) {
        plan.background = true;
        n -= 1;
    }
    while (i < n) : (i += 1) {
        const w = words[i];
        if (eql(w, "|") or eql(w, "|&")) {
            if (cur.words.items.len == 0 or i + 1 >= n) return it.fail("illegal use of | or |& in command", .{});
            cur.err_too = w.len == 2;
            try plan.cmds.append(a, cur);
            cur = .{};
            continue;
        }
        // The redirection forms, longest first.
        const forms = [_][]const u8{ "2>@1", "<<", "<@", "<", ">>&", ">&@", "2>>", "2>@", ">>", ">&", ">@", "2>", ">" };
        var form: ?[]const u8 = null;
        for (forms) |f| {
            if (std.mem.startsWith(u8, w, f)) {
                form = f;
                break;
            }
        }
        const f = form orelse {
            try cur.words.append(a, w);
            continue;
        };
        if (eql(f, "2>@1")) {
            if (w.len != 4) return it.fail("must specify \"2>@1\" as last word in command", .{});
            closeTarget(plan.err);
            plan.err = .to_out;
            continue;
        }
        var arg = w[f.len..];
        if (arg.len == 0) {
            i += 1;
            if (i >= n) return it.fail("can't specify \"{s}\" as last word in command", .{w});
            arg = words[i];
        }
        const is_in = f[0] == '<';
        const to_err = f[0] == '2';
        const both = std.mem.indexOfScalar(u8, f, '&') != null;
        var t: Target = undefined;
        if (eql(f, "<<")) {
            t = .{ .owned = try memFile(it, arg) };
        } else if (f[f.len - 1] == '@') {
            t = .{ .fd = try chanFd(it, arg, !is_in) };
        } else if (is_in) {
            t = .{ .owned = try openFile(it, arg, .{}, "read") };
        } else {
            var flags: sys.OpenFlags = .{ .access = .write, .create = true };
            if (std.mem.indexOf(u8, f, ">>") != null) flags.append = true else flags.truncate = true;
            t = .{ .owned = try openFile(it, arg, flags, "write") };
        }
        if (is_in) {
            closeTarget(plan.in);
            plan.in = t;
        } else if (to_err) {
            closeTarget(plan.err);
            plan.err = t;
        } else {
            closeTarget(plan.out);
            plan.out = t;
            if (both) {
                closeTarget(plan.err);
                plan.err = .{ .fd = switch (t) {
                    .fd, .owned => |x| x,
                    else => unreachable,
                } };
            }
        }
    }
    if (cur.words.items.len == 0) return it.fail("illegal use of | or |& in command", .{});
    try plan.cmds.append(a, cur);
}

/// The paths to try for a program word.
fn candidates(it: *Interp, word: []const u8) Error![]const [:0]const u8 {
    const a = it.alloc();
    var out: std.ArrayList([:0]const u8) = .empty;
    if (std.mem.indexOfScalar(u8, word, '/') != null) {
        // A path names a file below the root first, as each path of a
        // script does. The host path is the second choice.
        if (it.fs_ok() and it.fs.path.len > 0) {
            if (try fsroot.normal(it, word)) |rel| try out.append(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ it.fs.path, rel }, 0));
        }
        if (word[0] == '/') try out.append(a, try a.dupeZ(u8, word));
        return out.items;
    }
    var path: []const u8 = "/usr/bin:/bin";
    for (it.exec_host.env) |e| {
        if (std.mem.startsWith(u8, e, "PATH=")) path = e[5..];
    }
    var iter = std.mem.tokenizeScalar(u8, path, ':');
    while (iter.next()) |dir| try out.append(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, word }, 0));
    return out.items;
}

fn runnable(p: [:0]const u8) bool {
    return linux.errno(linux.access(p.ptr, 1)) == .SUCCESS;
}

/// True when the embedder allows the program. An entry of the list is
/// the word of the script, or the full path that the word gives.
fn allowed(it: *Interp, word: []const u8, paths: []const [:0]const u8) bool {
    const list = it.exec_host.allow orelse return true;
    var found: ?[]const u8 = null;
    for (paths) |p| {
        if (runnable(p)) {
            found = p;
            break;
        }
    }
    // A word with no file to run gives the error of the system.
    if (found == null) return true;
    for (list) |ok| {
        if (eql(ok, word)) return true;
        if (found) |p| if (eql(ok, p)) return true;
    }
    return false;
}

const Started = struct {
    pids: []i32,
    /// The read side of the output of the last program, or -1.
    out: i32 = -1,
    /// The write side of the input of the first program, or -1.
    in: i32 = -1,
    /// The memory file of the error output, or -1.
    err: i32 = -1,
    start: i64,
    /// True when the time limit ended the pipeline.
    timed_out: bool = false,
};

fn pipe(it: *Interp) Error![2]i32 {
    var p: [2]i32 = undefined;
    const rc = linux.pipe2(&p, .{ .CLOEXEC = true });
    if (linux.errno(rc) != .SUCCESS) return posix(it, linux.errno(rc), "couldn't create pipe: ");
    return p;
}

/// Starts the programs of a plan. `want_out` and `want_in` ask for a
/// pipe to the parent when the plan has no redirection.
fn start(it: *Interp, plan: *Plan, want_out: bool, want_in: bool) Error!Started {
    const a = it.alloc();
    const count = plan.cmds.items.len;
    // The checks and the paths come before the first process.
    const paths = try a.alloc([]const [:0]const u8, count);
    const argvs = try a.alloc([:null]?[*:0]const u8, count);
    for (plan.cmds.items, 0..) |c, k| {
        const word = c.words.items[0];
        try noTilde(it, word);
        paths[k] = try candidates(it, word);
        if (!allowed(it, word, paths[k])) return it.failCode("ZTCL EXEC DENIED", "couldn't execute \"{s}\": the embedder does not allow this program", .{word});
        const av = try a.allocSentinel(?[*:0]const u8, c.words.items.len, null);
        for (c.words.items, 0..) |w, j| av[j] = (try a.dupeZ(u8, w)).ptr;
        argvs[k] = av;
    }
    const envp = try a.allocSentinel(?[*:0]const u8, it.exec_host.env.len, null);
    for (it.exec_host.env, 0..) |e, j| envp[j] = e.ptr;
    // The working folder: the current folder below the root.
    var cwd_fd: i32 = -1;
    if (it.fs_ok()) {
        cwd_fd = switch (try fsroot.openRel(it, it.fs.cwd, .{ .directory = true }, 0)) {
            .fd => |x| x,
            .err => |e| return posix(it, e, "couldn't open the working folder: "),
        };
    }
    defer if (cwd_fd >= 0) sys.close(cwd_fd);

    const null_rc = linux.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(null_rc) != .SUCCESS) return posix(it, linux.errno(null_rc), "couldn't open /dev/null: ");
    const null_fd: i32 = @intCast(null_rc);
    defer sys.close(null_fd);

    var st: Started = .{ .pids = try a.alloc(i32, count), .start = nowMs() };
    var made: usize = 0;
    var first_in: i32 = null_fd;
    var in_pipe: ?[2]i32 = null;
    switch (plan.in) {
        .fd, .owned => |x| first_in = x,
        else => if (want_in) {
            in_pipe = try pipe(it);
            first_in = in_pipe.?[0];
            st.in = in_pipe.?[1];
        },
    }
    var last_out: i32 = 1;
    var out_pipe: ?[2]i32 = null;
    switch (plan.out) {
        .fd, .owned => |x| last_out = x,
        else => if (want_out) {
            out_pipe = try pipe(it);
            last_out = out_pipe.?[1];
            st.out = out_pipe.?[0];
        },
    }
    var err_fd: i32 = 2;
    switch (plan.err) {
        .fd, .owned => |x| err_fd = x,
        .to_out => {},
        .none => if (!plan.background) {
            st.err = try memFile(it, "");
            err_fd = st.err;
        },
    }
    // A pipe that reports a failed start of a program.
    const report = try pipe(it);
    var prev_read: i32 = -1;
    var failure: ?Error = null;
    var pgid: i32 = 0;
    // A program that macOS did not start: its error, as the report pipe
    // gives it on Linux.
    var spawn_err: ?u32 = null;
    for (0..count) |k| {
        var next: ?[2]i32 = null;
        if (k + 1 < count) next = pipe(it) catch |e| {
            failure = e;
            break;
        };
        const in_fd = if (k == 0) first_in else prev_read;
        const out_fd = if (next) |p| p[1] else last_out;
        var this_err = err_fd;
        if (plan.err == .to_out and k + 1 == count) this_err = out_fd;
        if (plan.cmds.items[k].err_too) this_err = out_fd;
        const rc = if (comptime on_mac) spawnMac(paths[k], argvs[k].ptr, envp.ptr, in_fd, out_fd, this_err, cwd_fd, pgid) else linux.fork();
        if (linux.errno(rc) != .SUCCESS) {
            if (comptime on_mac) {
                spawn_err = @intFromEnum(linux.errno(rc));
            } else failure = posix(it, linux.errno(rc), "couldn't fork child process: ");
            if (next) |p| {
                sys.close(p[0]);
                sys.close(p[1]);
            }
            break;
        }
        if (!on_mac and rc == 0) {
            // The child. It uses only system calls from here.
            _ = linux.setpgid(0, pgid);
            // Copy the three descriptors above 2 first, so that one
            // `dup2` cannot overwrite the source of the next.
            const in0: i32 = @intCast(linux.fcntl(in_fd, linux.F.DUPFD_CLOEXEC, 10));
            const out0: i32 = @intCast(linux.fcntl(out_fd, linux.F.DUPFD_CLOEXEC, 10));
            const err0: i32 = @intCast(linux.fcntl(this_err, linux.F.DUPFD_CLOEXEC, 10));
            _ = linux.dup2(in0, 0);
            _ = linux.dup2(out0, 1);
            _ = linux.dup2(err0, 2);
            if (cwd_fd >= 0) _ = linux.fchdir(cwd_fd);
            var last: linux.E = .NOENT;
            for (paths[k]) |p| {
                const e = linux.errno(linux.execve(p.ptr, argvs[k].ptr, envp.ptr));
                if (e != .NOENT and e != .NOTDIR) last = e;
            }
            const code: u32 = @intFromEnum(last);
            _ = linux.write(report[1], std.mem.asBytes(&code), 4);
            linux.exit(127);
        }
        const pid: i32 = @intCast(rc);
        if (pgid == 0) pgid = pid;
        _ = linux.setpgid(pid, pgid);
        st.pids[made] = pid;
        made += 1;
        if (prev_read >= 0) sys.close(prev_read);
        prev_read = -1;
        if (next) |p| {
            sys.close(p[1]);
            prev_read = p[0];
        }
    }
    if (prev_read >= 0) sys.close(prev_read);
    if (in_pipe) |p| sys.close(p[0]);
    if (out_pipe) |p| sys.close(p[1]);
    closePlan(plan);
    st.pids = st.pids[0..made];
    sys.close(report[1]);
    // The report pipe closes at each successful exec.
    var code: u32 = 0;
    var got = false;
    while (true) {
        switch (sys.read(report[0], std.mem.asBytes(&code))) {
            .n => |n| if (n == 4) {
                got = true;
                continue;
            },
            else => {},
        }
        break;
    }
    sys.close(report[0]);
    if (spawn_err) |e| {
        code = e;
        got = true;
    }
    if (failure == null and got) {
        // The message names the first program with no file to run.
        var word = plan.cmds.items[0].words.items[0];
        for (plan.cmds.items, 0..) |c, k| {
            var found = false;
            for (paths[k]) |p| {
                if (runnable(p)) found = true;
            }
            if (!found) {
                word = c.words.items[0];
                break;
            }
        }
        failure = posix(it, @enumFromInt(code), try std.fmt.allocPrint(a, "couldn't execute \"{s}\": ", .{word}));
    }
    if (failure) |e| {
        const saved = it.result;
        const saved_code = it.error_code;
        killGroup(pgid);
        for (st.pids) |p| _ = waitPid(p, true);
        if (st.out >= 0) sys.close(st.out);
        if (st.in >= 0) sys.close(st.in);
        if (st.err >= 0) sys.close(st.err);
        it.result = saved;
        it.error_code = saved_code;
        return e;
    }
    return st;
}

fn killGroup(pgid: i32) void {
    if (pgid > 0) _ = linux.kill(-pgid, linux.SIG.KILL);
}

/// The wait status of a process, or null while it runs.
fn waitPid(pid: i32, block: bool) ?u32 {
    var status: u32 = 0;
    while (true) {
        const rc = linux.wait4(pid, &status, if (block) @as(u32, 0) else @as(u32, linux.W.NOHANG), null);
        switch (linux.errno(rc)) {
            .SUCCESS => return if (rc == 0) null else status,
            .INTR => continue,
            else => return 0,
        }
    }
}

fn deadline(it: *Interp, start_ms: i64) ?i64 {
    if (it.exec_host.timeout_ms == 0) return null;
    return start_ms + it.exec_host.timeout_ms;
}

fn signalName(sig: u32) struct { []const u8, []const u8 } {
    return switch (sig) {
        1 => .{ "SIGHUP", "hangup" },
        2 => .{ "SIGINT", "interrupt" },
        3 => .{ "SIGQUIT", "quit signal" },
        6 => .{ "SIGABRT", "SIGABRT" },
        9 => .{ "SIGKILL", "kill signal" },
        11 => .{ "SIGSEGV", "segmentation violation" },
        13 => .{ "SIGPIPE", "write on pipe with no readers" },
        15 => .{ "SIGTERM", "software termination signal" },
        else => .{ "unknown signal", "unknown signal" },
    };
}

/// Waits for the processes and builds the error text of Tcl. Gives
/// true when the pipeline failed. `text` gets the error output.
fn finish(it: *Interp, st: Started, text: *std.ArrayList(u8), ignore_err: bool) Error!bool {
    const a = it.alloc();
    const limit = deadline(it, st.start);
    var failed = false;
    var timed_out = st.timed_out;
    var any_info = false;
    var code: ?[]const u8 = null;
    for (st.pids) |pid| {
        var status: ?u32 = null;
        while (true) {
            status = waitPid(pid, limit == null);
            if (status != null) break;
            if (nowMs() >= limit.?) {
                timed_out = true;
                killGroup(st.pids[0]);
                status = waitPid(pid, true);
                break;
            }
            var none: [0]sys.Want = .{};
            sys.poll(a, &none, 2);
        }
        const s = status.?;
        if (s & 0x7f == 0) {
            const exit_code = (s >> 8) & 0xff;
            if (exit_code != 0) {
                failed = true;
                code = try std.fmt.allocPrint(a, "CHILDSTATUS {d} {d}", .{ pid, exit_code });
            }
        } else {
            failed = true;
            const name, const msg = signalName(s & 0x7f);
            code = try std.fmt.allocPrint(a, "CHILDKILLED {d} {s} {{{s}}}", .{ pid, name, msg });
            if (timed_out) {
                try text.print(a, "child killed: the time limit of {d} ms ended\n", .{it.exec_host.timeout_ms});
            } else try text.print(a, "child killed: {s}\n", .{msg});
            any_info = true;
        }
    }
    if (st.err >= 0) {
        _ = linux.lseek(st.err, 0, 0);
        var buf: [4096]u8 = undefined;
        const before = text.items.len;
        while (true) {
            switch (sys.read(st.err, &buf)) {
                .n => |n| if (n > 0) {
                    if (!ignore_err) try text.appendSlice(a, buf[0..n]);
                    continue;
                },
                else => {},
            }
            break;
        }
        sys.close(st.err);
        if (text.items.len > before) {
            any_info = true;
            failed = true;
        }
    }
    if (failed and !any_info) try text.appendSlice(a, "child process exited abnormally\n");
    if (failed) it.error_code = .{ .str = code orelse "NONE" };
    return failed;
}

fn stripNewline(text: []const u8) []const u8 {
    return if (text.len > 0 and text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
}

fn cmdExec(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const a = it.alloc();
    sweep(it);
    var plan: Plan = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (o.len == 0 or o[0] != '-') break;
        if (eql(o, "-ignorestderr")) {
            plan.ignore_err = true;
        } else if (eql(o, "-keepnewline")) {
            plan.keep_newline = true;
        } else if (eql(o, "--")) {
            i += 1;
            break;
        } else return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -ignorestderr, -keepnewline, or --", .{o});
    }
    if (i >= argv.len) return it.wrongArgs("exec ?-option ...? arg ?arg ...?");
    const words = try a.alloc([]const u8, argv.len - i);
    for (argv[i..], words) |v, *w| w.* = try it.str(v);
    parse(it, words, &plan) catch |e| {
        closePlan(&plan);
        return e;
    };
    errdefer closePlan(&plan);
    if (plan.background) {
        const st = try start(it, &plan, false, false);
        try it.execs.groups.append(a, .{ .pgid = st.pids[0], .pids = st.pids, .start = st.start });
        var out: std.ArrayList(Value) = .empty;
        for (st.pids) |p| try out.append(a, .{ .int = p });
        return value.wrapList(a, out.items);
    }
    var st = try start(it, &plan, true, false);
    var text: std.ArrayList(u8) = .empty;
    if (st.out >= 0) {
        // The output of the last program, until its end or the limit.
        const limit = deadline(it, st.start);
        var buf: [16384]u8 = undefined;
        while (true) {
            if (limit) |l| {
                const left = l - nowMs();
                if (left <= 0) {
                    killGroup(st.pids[0]);
                    st.timed_out = true;
                    break;
                }
                var w = [_]sys.Want{.{ .fd = st.out, .read = true }};
                sys.poll(a, &w, @intCast(@min(left, 1000)));
                if (!w[0].can_read) continue;
            }
            switch (sys.read(st.out, &buf)) {
                .n => |n| if (n > 0) {
                    try text.appendSlice(a, buf[0..n]);
                    if (!it.overLimit()) continue;
                    killGroup(st.pids[0]);
                },
                else => {},
            }
            break;
        }
        sys.close(st.out);
    }
    const failed = try finish(it, st, &text, plan.ignore_err);
    const res = if (plan.keep_newline) text.items else stripNewline(text.items);
    if (failed) {
        it.result = .{ .str = res };
        return error.TclError;
    }
    return .{ .str = res };
}

/// `open "|command"`: a channel on a pipeline.
pub fn openPipeline(it: *Interp, command: []const u8, readable: bool, writable: bool) Error!Value {
    const a = it.alloc();
    sweep(it);
    const list = try it.list(.{ .str = command });
    if (list.len == 0) return it.fail("illegal use of | or |& in command", .{});
    const words = try a.alloc([]const u8, list.len);
    for (list, words) |v, *w| w.* = try it.str(v);
    var plan: Plan = .{};
    parse(it, words, &plan) catch |e| {
        closePlan(&plan);
        return e;
    };
    errdefer closePlan(&plan);
    if (plan.background) return it.fail("illegal use of & in a command pipeline", .{});
    if (readable and plan.out != .none) return it.fail("can't read output from command: standard output was redirected", .{});
    if (writable and plan.in != .none) return it.fail("can't write input to command: standard input was redirected", .{});
    const st = try start(it, &plan, readable, writable);
    const c = try chan.adopt(it, "file", if (readable) st.out else st.in, readable, writable);
    c.kind = .pipe;
    if (readable and writable) c.wfd = st.in;
    c.pids = st.pids;
    c.err_fd = st.err;
    c.started = st.start;
    return .{ .str = c.name };
}

/// Waits for the processes of a pipeline channel that closed.
pub fn reap(it: *Interp, c: *chan.Channel) Error!void {
    var text: std.ArrayList(u8) = .empty;
    const st: Started = .{ .pids = @constCast(c.pids), .err = c.err_fd, .start = c.started };
    // A channel that does not block does not wait for its processes.
    if (!c.blocking) {
        try it.execs.groups.append(it.alloc(), .{ .pgid = c.pids[0], .pids = c.pids, .start = c.started });
        if (c.err_fd >= 0) sys.close(c.err_fd);
        return;
    }
    if (try finish(it, st, &text, false)) {
        it.result = .{ .str = stripNewline(text.items) };
        return error.TclError;
    }
}

/// Ends the processes of a pipeline channel with no wait for output.
pub fn abandon(c: *chan.Channel) void {
    killGroup(c.pids[0]);
    for (c.pids) |p| _ = waitPid(p, true);
    if (c.err_fd >= 0) sys.close(c.err_fd);
}

/// Collects the background processes that ended, and stops each group
/// that is past the time limit.
pub fn sweep(it: *Interp) void {
    var i: usize = 0;
    while (i < it.execs.groups.items.len) {
        const g = it.execs.groups.items[i];
        var live = false;
        const late = if (deadline(it, g.start)) |l| nowMs() >= l else false;
        if (late) killGroup(g.pgid);
        for (g.pids) |p| {
            // The group stays live while a wait gives no status. A pid
            // that was collected before gives an error, which counts
            // as ended.
            if (waitPid(p, late) == null) live = true;
        }
        if (live) i += 1 else _ = it.execs.groups.orderedRemove(i);
    }
}

/// Stops each background process when the interpreter ends.
pub fn abandonAll(it: *Interp) void {
    for (it.execs.groups.items) |g| {
        killGroup(g.pgid);
        for (g.pids) |p| _ = waitPid(p, true);
    }
    it.execs.groups = .empty;
}

fn cmdPid(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len > 2) return it.wrongArgs("pid ?channelId?");
    if (argv.len == 1) return .{ .int = linux.getpid() };
    const name = try it.str(argv[1]);
    const c = chan.lookup(it, name) orelse return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP CHANNEL {s}", .{name}), "can not find channel named \"{s}\"", .{name});
    var out: std.ArrayList(Value) = .empty;
    for (c.pids) |p| try out.append(it.alloc(), .{ .int = p });
    return value.wrapList(it.alloc(), out.items);
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("exec", cmdExec);
    try it.register("pid", cmdPid);
}

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
//! - `allow` is a list of host programs. With a list, each other
//!   program is an error before any process starts.
//! - `allow_root` is a list of files below the root folder that a
//!   script can run.
//! - `timeout_ms` is the longest run time of a pipeline. At the end of
//!   that time each process of the pipeline tree gets SIGKILL.
//! - `env` is the whole environment of each program.
//!
//! `resolve` changes the first word of each program to one full host
//! path before any process starts. A bare name goes through the `PATH`
//! of `env`, and each entry of that `PATH` must be a full path. Each
//! symlink, `.`, and `..` of the path is resolved. The allowlist check
//! compares that path, and the child runs only that path. A file below
//! the root folder runs only when `allow_root` names it.
//!
//! Each pipeline is one process tree. On Linux the tree is a cgroup
//! below the cgroup of the embedder when the embedder can make one.
//! Each child joins it before `execve`, so each descendant is in it,
//! also after `setsid` or a double fork. The kill writes `cgroup.kill`.
//! With no cgroup, the kill stops the process group and each process
//! that a scan of /proc finds below the pipeline, and then kills them.
//! `abandonAll` kills each tree that still runs when the interpreter
//! ends.
//!
//! The error output and the text of `<<` use an anonymous memory file,
//! so the parent waits on one descriptor only.
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
const linux = std.os.linux;

pub const supported = @import("builtin").os.tag == .linux;

pub const Host = struct {
    /// The host programs that a script can run. An entry with no `/` is
    /// a bare name: the word of the script must be that name, and the
    /// program is the first match in the `PATH` of `env`. An entry with
    /// a `/` is a full host path. It matches each word that resolves to
    /// the same file. Null allows each host program. No entry matches a
    /// file below the root folder.
    allow: ?[]const []const u8 = null,
    /// The files below the root folder that a script can run, as full
    /// paths of the script, for example `/tool`. A script with `file`
    /// can write these files, so each entry lets the script run its own
    /// code.
    allow_root: []const []const u8 = &.{},
    /// The longest run time of a pipeline in milliseconds. 0 is no limit.
    timeout_ms: u32 = 0,
    /// The environment of each program: `NAME=value` strings.
    env: []const [:0]const u8 = &.{},
};

pub const State = struct {
    /// The trees of the pipelines that can still have a process.
    groups: std.ArrayList(Group) = .empty,
};

const Group = struct { tree: Tree, pids: []const i32, start: i64 };

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

fn memFile(it: *Interp, text: []const u8) Error!i32 {
    const rc = linux.memfd_create("ztcl", linux.MFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return posix(it, linux.errno(rc), "couldn't create a memory file: ");
    const fd: i32 = @intCast(rc);
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

fn openFile(it: *Interp, path: []const u8, flags: linux.O, what: []const u8) Error!i32 {
    const a = it.alloc();
    try noTilde(it, path);
    if (it.fs_ok()) {
        const rel = (try fsroot.normal(it, path)) orelse return it.failCode("POSIX EACCES {permission denied}", "couldn't {s} file \"{s}\": permission denied", .{ what, path });
        return switch (try fsroot.openRel(it, rel, flags, 0o666)) {
            .fd => |x| x,
            .err => |e| posix(it, e, try std.fmt.allocPrint(a, "couldn't {s} file \"{s}\": ", .{ what, path })),
        };
    }
    var f = flags;
    f.CLOEXEC = true;
    const rc = linux.open(try a.dupeZ(u8, path), f, 0o666);
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
            var flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true };
            if (std.mem.indexOf(u8, f, ">>") != null) flags.APPEND = true else flags.TRUNC = true;
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

const statx_mask = linux.STATX.BASIC_STATS;
const max_links = 40;

fn hostStat(path: [:0]const u8, st: *linux.Statx) linux.E {
    return linux.errno(linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, statx_mask, st));
}

/// The host path with each symlink, `.`, and `..` resolved, or the
/// error of the first part that does not resolve. `path` is a full
/// path.
fn canonical(a: std.mem.Allocator, path: []const u8) Error!union(enum) { ok: [:0]const u8, err: linux.E } {
    var out: std.ArrayList(u8) = .empty;
    var rest: []const u8 = path;
    var links: usize = 0;
    var buf: [4096]u8 = undefined;
    while (true) {
        rest = std.mem.trimStart(u8, rest, "/");
        if (rest.len == 0) break;
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const name = rest[0..end];
        rest = rest[end..];
        if (eql(name, ".")) continue;
        if (eql(name, "..")) {
            // Each part of `out` is a folder with no symlink, so `..`
            // removes the last part.
            out.shrinkRetainingCapacity(std.mem.lastIndexOfScalar(u8, out.items, '/') orelse 0);
            continue;
        }
        const mark = out.items.len;
        try out.append(a, '/');
        try out.appendSlice(a, name);
        const z = try a.dupeZ(u8, out.items);
        var st: linux.Statx = undefined;
        const e = hostStat(z, &st);
        if (e != .SUCCESS) return .{ .err = e };
        if (st.mode & 0o170000 != 0o120000) continue;
        links += 1;
        if (links > max_links) return .{ .err = .LOOP };
        const n = linux.readlinkat(linux.AT.FDCWD, z, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return .{ .err = linux.errno(n) };
        if (n >= buf.len) return .{ .err = .NAMETOOLONG };
        const target = buf[0..n];
        out.shrinkRetainingCapacity(if (target.len > 0 and target[0] == '/') 0 else mark);
        rest = try std.mem.concat(a, u8, &.{ target, "/", rest });
    }
    if (out.items.len == 0) try out.append(a, '/');
    return .{ .ok = try a.dupeZ(u8, out.items) };
}

fn sameFile(x: linux.Statx, y: linux.Statx) bool {
    return x.ino == y.ino and x.dev_major == y.dev_major and x.dev_minor == y.dev_minor;
}

/// True when a canonical host path is the root folder or a path below
/// it. The check compares the device and inode of each folder of the
/// path with the root, so a bind mount of the root also counts. An
/// error counts as below the root.
fn belowRoot(it: *Interp, path: []const u8) Error!bool {
    if (it.fs.fd < 0) return false;
    var root: linux.Statx = undefined;
    if (linux.errno(linux.statx(it.fs.fd, "", 0x1000, statx_mask, &root)) != .SUCCESS) return true;
    var k: usize = 0;
    while (k <= path.len) : (k += 1) {
        if (k < path.len and path[k] != '/') continue;
        const z = try it.alloc().dupeZ(u8, if (k == 0) "/" else path[0..k]);
        var st: linux.Statx = undefined;
        if (hostStat(z, &st) != .SUCCESS) return true;
        if (sameFile(st, root)) return true;
    }
    return false;
}

fn denied(it: *Interp, word: []const u8, why: []const u8) Error {
    return it.failCode("ZTCL EXEC DENIED", "couldn't execute \"{s}\": {s}", .{ word, why });
}

fn cannotRun(it: *Interp, word: []const u8, e: linux.E) Error {
    return posix(it, e, try std.fmt.allocPrint(it.alloc(), "couldn't execute \"{s}\": ", .{word}));
}

/// The full host path of the root folder. It must still name the
/// folder of the root descriptor.
fn rootPath(it: *Interp, word: []const u8) Error![:0]const u8 {
    const a = it.alloc();
    var full: []const u8 = it.fs.path;
    if (full.len == 0 or full[0] != '/') {
        var buf: [4096]u8 = undefined;
        const n = linux.getcwd(&buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return cannotRun(it, word, linux.errno(n));
        const cwd = std.mem.sliceTo(&buf, 0);
        full = try std.fmt.allocPrint(a, "{s}/{s}", .{ cwd, full });
    }
    const p = switch (try canonical(a, full)) {
        .ok => |x| x,
        .err => |e| return cannotRun(it, word, e),
    };
    var root: linux.Statx = undefined;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(it.fs.fd, "", 0x1000, statx_mask, &root)) != .SUCCESS or
        hostStat(p, &st) != .SUCCESS or !sameFile(st, root))
        return denied(it, word, "the host path of the root folder changed");
    return p;
}

/// The host path of a file below the root folder that `allow_root`
/// names, or null.
fn rootProgram(it: *Interp, word: []const u8) Error!?[:0]const u8 {
    if (it.exec_host.allow_root.len == 0 or it.fs.fd < 0) return null;
    const rel = (try fsroot.normal(it, word)) orelse return null;
    for (it.exec_host.allow_root) |entry| {
        if (entry.len == 0 or entry[0] != '/') continue;
        const want = (try fsroot.normal(it, entry)) orelse continue;
        if (want.len == 0 or !eql(rel, want)) continue;
        return try std.fmt.allocPrintSentinel(it.alloc(), "{s}/{s}", .{ try rootPath(it, word), rel }, 0);
    }
    return null;
}

/// Checks a resolved host program against the root folder and the
/// allowlist.
fn checked(it: *Interp, word: []const u8, path: [:0]const u8) Error![:0]const u8 {
    if (try belowRoot(it, path)) return denied(it, word, "the program is in the root folder");
    const list = it.exec_host.allow orelse return path;
    for (list) |ok| {
        if (std.mem.indexOfScalar(u8, ok, '/') == null) {
            if (eql(ok, word)) return path;
            continue;
        }
        if (ok[0] != '/') continue;
        switch (try canonical(it.alloc(), ok)) {
            .ok => |p| if (eql(p, path)) return path,
            .err => {},
        }
    }
    return denied(it, word, "the embedder does not allow this program");
}

/// The one full host path that a program word runs. A word with a `/`
/// is a host path, or a file of `allow_root`. A bare name goes through
/// the `PATH` of the embedder.
fn resolve(it: *Interp, word: []const u8) Error![:0]const u8 {
    const a = it.alloc();
    if (std.mem.indexOfScalar(u8, word, '/') != null) {
        if (try rootProgram(it, word)) |p| return p;
        if (word[0] != '/') return denied(it, word, "a program path must be a full path or a bare name");
        return switch (try canonical(a, word)) {
            .ok => |p| checked(it, word, p),
            .err => |e| cannotRun(it, word, e),
        };
    }
    var path: []const u8 = "/usr/bin:/bin";
    for (it.exec_host.env) |e| {
        if (std.mem.startsWith(u8, e, "PATH=")) path = e[5..];
    }
    var iter = std.mem.splitScalar(u8, path, ':');
    while (iter.next()) |dir| {
        // An empty or relative entry depends on the working folder.
        if (dir.len == 0 or dir[0] != '/') return it.failCode("ZTCL EXEC PATH", "couldn't execute \"{s}\": the PATH entry \"{s}\" is not a full path", .{ word, dir });
    }
    iter.reset();
    while (iter.next()) |dir| {
        const p = switch (try canonical(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, word }))) {
            .ok => |x| x,
            .err => continue,
        };
        var st: linux.Statx = undefined;
        if (hostStat(p, &st) != .SUCCESS or st.mode & 0o170000 != 0o100000) continue;
        if (linux.errno(linux.access(p.ptr, 1)) != .SUCCESS) continue;
        return checked(it, word, p);
    }
    return cannotRun(it, word, .NOENT);
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
    tree: Tree = .{},
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
    const progs = try a.alloc([:0]const u8, count);
    const argvs = try a.alloc([:null]?[*:0]const u8, count);
    for (plan.cmds.items, 0..) |c, k| {
        const word = c.words.items[0];
        try noTilde(it, word);
        progs[k] = try resolve(it, word);
        const av = try a.allocSentinel(?[*:0]const u8, c.words.items.len, null);
        for (c.words.items, 0..) |w, j| av[j] = (try a.dupeZ(u8, w)).ptr;
        argvs[k] = av;
    }
    const envp = try a.allocSentinel(?[*:0]const u8, it.exec_host.env.len, null);
    for (it.exec_host.env, 0..) |e, j| envp[j] = e.ptr;
    // The working folder: the current folder below the root.
    var cwd_fd: i32 = -1;
    if (it.fs_ok()) {
        cwd_fd = switch (try fsroot.openRel(it, it.fs.cwd, .{ .DIRECTORY = true }, 0)) {
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
    // A pipe that reports a failed start of a program: the index of
    // the program and the error.
    const report = try pipe(it);
    st.tree = treeOpen();
    var prev_read: i32 = -1;
    var failure: ?Error = null;
    var pgid: i32 = 0;
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
        const rc = linux.fork();
        if (linux.errno(rc) != .SUCCESS) {
            failure = posix(it, linux.errno(rc), "couldn't fork child process: ");
            if (next) |p| {
                sys.close(p[0]);
                sys.close(p[1]);
            }
            break;
        }
        if (rc == 0) {
            // The child. It uses only system calls from here. It joins
            // the cgroup first, so each process that it starts is in it.
            if (st.tree.procs >= 0) {
                const e = linux.errno(linux.write(st.tree.procs, "0", 1));
                if (e != .SUCCESS) {
                    const msg = [2]u32{ @intCast(k), @intFromEnum(e) };
                    _ = linux.write(report[1], std.mem.asBytes(&msg), 8);
                    linux.exit(127);
                }
            }
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
            const e = linux.errno(linux.execve(progs[k].ptr, argvs[k].ptr, envp.ptr));
            const msg = [2]u32{ @intCast(k), @intFromEnum(e) };
            _ = linux.write(report[1], std.mem.asBytes(&msg), 8);
            linux.exit(127);
        }
        const pid: i32 = @intCast(rc);
        if (pgid == 0) {
            pgid = pid;
            st.tree.pgid = pid;
        }
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
    // The report pipe closes at each successful exec. The message
    // names the first program that did not start.
    var msg = [2]u32{ 0, 0 };
    var got: ?[2]u32 = null;
    while (true) {
        switch (sys.read(report[0], std.mem.asBytes(&msg))) {
            .n => |n| if (n == 8) {
                if (got == null or msg[0] < got.?[0]) got = msg;
                continue;
            },
            else => {},
        }
        break;
    }
    sys.close(report[0]);
    if (failure == null) if (got) |g| {
        failure = cannotRun(it, plan.cmds.items[@min(g[0], count - 1)].words.items[0], @enumFromInt(g[1]));
    };
    if (failure) |e| {
        const saved = it.result;
        const saved_code = it.error_code;
        treeKill(&st.tree, st.pids);
        for (st.pids) |p| _ = waitPid(p, true);
        treeClose(&st.tree);
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

/// The process tree of one pipeline. With a cgroup, `dir` is its
/// folder. With no cgroup, the kill uses the process group and a scan
/// of /proc.
pub const Tree = struct {
    /// The folder of the cgroup, or -1.
    dir: i32 = -1,
    /// The folder that has `dir`, for the removal.
    parent: i32 = -1,
    /// `cgroup.procs` of the cgroup, for each child to join, or -1.
    procs: i32 = -1,
    name: [40:0]u8 = undefined,
    /// The process group of the pipeline.
    pgid: i32 = 0,
};

/// True turns off the cgroup, so a test can check the kill with no
/// cgroup.
pub var test_no_cgroup = false;
var tree_count = std.atomic.Value(u32).init(0);

fn sleepMs(ms: i32) void {
    _ = linux.poll(@ptrFromInt(8), 0, ms);
}

/// Reads a small file into `buf`. Gives the text, or null.
fn readSmall(dir: i32, name: [*:0]const u8, buf: []u8) ?[]const u8 {
    const rc = linux.openat(dir, name, .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer sys.close(fd);
    var at: usize = 0;
    while (at < buf.len) {
        switch (sys.read(fd, buf[at..])) {
            .n => |n| if (n > 0) {
                at += n;
                continue;
            },
            else => {},
        }
        break;
    }
    return buf[0..at];
}

fn writeAt(dir: i32, name: [*:0]const u8, text: []const u8) bool {
    const rc = linux.openat(dir, name, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    defer sys.close(fd);
    return linux.errno(linux.write(fd, text.ptr, text.len)) == .SUCCESS;
}

/// Makes a cgroup for a new pipeline below the cgroup of this process.
/// Gives a tree with no cgroup when the process cannot make one.
fn treeOpen() Tree {
    var t: Tree = .{};
    if (test_no_cgroup) return t;
    var buf: [4096]u8 = undefined;
    const text = readSmall(linux.AT.FDCWD, "/proc/self/cgroup", &buf) orelse return t;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    const own = while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "0::/")) break l[3..];
    } else return t;
    var pbuf: [4200:0]u8 = undefined;
    const full = std.fmt.bufPrintZ(&pbuf, "/sys/fs/cgroup{s}", .{own}) catch return t;
    const prc = linux.openat(linux.AT.FDCWD, full, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(prc) != .SUCCESS) return t;
    const parent: i32 = @intCast(prc);
    _ = std.fmt.bufPrintZ(&t.name, "ztcl-{d}-{d}", .{ linux.getpid(), tree_count.fetchAdd(1, .monotonic) }) catch unreachable;
    if (linux.errno(linux.mkdirat(parent, &t.name, 0o755)) != .SUCCESS) {
        sys.close(parent);
        return t;
    }
    const drc = linux.openat(parent, &t.name, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    const jrc = if (linux.errno(drc) == .SUCCESS) linux.openat(@intCast(drc), "cgroup.procs", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0) else drc;
    if (linux.errno(drc) != .SUCCESS or linux.errno(jrc) != .SUCCESS) {
        if (linux.errno(drc) == .SUCCESS) sys.close(@intCast(drc));
        _ = linux.unlinkat(parent, &t.name, linux.AT.REMOVEDIR);
        sys.close(parent);
        return t;
    }
    t.parent = parent;
    t.dir = @intCast(drc);
    t.procs = @intCast(jrc);
    return t;
}

/// True when this process can make a cgroup for a pipeline.
pub fn treeAvailable() bool {
    var t = treeOpen();
    const ok = t.dir >= 0;
    treeClose(&t);
    return ok;
}

/// True while a process of the cgroup runs. A tree with no cgroup
/// gives false.
fn treeLive(t: *const Tree) bool {
    if (t.dir < 0) return false;
    var buf: [256]u8 = undefined;
    const text = readSmall(t.dir, "cgroup.events", &buf) orelse return false;
    return std.mem.indexOf(u8, text, "populated 1") != null;
}

/// Kills each process of the tree. `pids` are the programs of the
/// pipeline.
fn treeKill(t: *const Tree, pids: []const i32) void {
    if (t.dir >= 0) {
        if (!writeAt(t.dir, "cgroup.kill", "1")) {
            // A kernel before 5.14 has no `cgroup.kill`. The freeze
            // stops each fork, and the loop kills each listed process.
            _ = writeAt(t.dir, "cgroup.freeze", "1");
            var round: usize = 0;
            while (round < 1000) : (round += 1) {
                var buf: [4096]u8 = undefined;
                const text = readSmall(t.dir, "cgroup.procs", &buf) orelse break;
                var any = false;
                var iter = std.mem.tokenizeScalar(u8, text, '\n');
                while (iter.next()) |w| {
                    const pid = std.fmt.parseInt(i32, w, 10) catch continue;
                    _ = linux.kill(pid, linux.SIG.KILL);
                    any = true;
                }
                if (!any) break;
            }
            _ = writeAt(t.dir, "cgroup.freeze", "0");
        }
    }
    if (t.dir < 0) killScan(t.pgid, pids);
    killGroup(t.pgid);
}

/// The kill with no cgroup. SIGSTOP stops the group, each program, and
/// each process below them that a scan of /proc finds, until a scan
/// finds no new process. Then each one gets SIGKILL. A process whose
/// parent ended before the scan is no longer below the pipeline, so
/// this kill does not find it.
fn killScan(pgid: i32, pids: []const i32) void {
    const pa = std.heap.page_allocator;
    var found: std.ArrayList(i32) = .empty;
    defer found.deinit(pa);
    found.appendSlice(pa, pids) catch {};
    if (pgid > 0) _ = linux.kill(-pgid, linux.SIG.STOP);
    for (pids) |p| _ = linux.kill(p, linux.SIG.STOP);
    var round: usize = 0;
    while (round < 64) : (round += 1) {
        const before = found.items.len;
        scanChildren(pa, &found);
        if (found.items.len == before) break;
    }
    for (found.items) |p| _ = linux.kill(p, linux.SIG.KILL);
}

/// Adds each process of /proc whose parent is in `found`, and stops it.
fn scanChildren(pa: std.mem.Allocator, found: *std.ArrayList(i32)) void {
    const rc = linux.open("/proc", .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer sys.close(fd);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf[off + 19])), 0);
            off += reclen;
            const pid = std.fmt.parseInt(i32, name, 10) catch continue;
            if (std.mem.indexOfScalar(i32, found.items, pid) != null) continue;
            var sb: [512]u8 = undefined;
            var path: [32:0]u8 = undefined;
            const z = std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{pid}) catch continue;
            const text = readSmall(linux.AT.FDCWD, z, &sb) orelse continue;
            // The name of the program is in parentheses and can have
            // spaces, so the fields start after the last `)`.
            const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse continue;
            var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
            _ = fields.next();
            const ppid = std.fmt.parseInt(i32, fields.next() orelse continue, 10) catch continue;
            if (std.mem.indexOfScalar(i32, found.items, ppid) == null) continue;
            _ = linux.kill(pid, linux.SIG.STOP);
            found.append(pa, pid) catch return;
        }
    }
}

/// Removes the cgroup of a tree and closes its descriptors. After a
/// kill, it waits up to one second for the processes to end.
fn treeClose(t: *Tree) void {
    if (t.dir < 0) return;
    var waited: usize = 0;
    while (treeLive(t) and waited < 500) : (waited += 1) sleepMs(2);
    sys.close(t.procs);
    sys.close(t.dir);
    _ = linux.unlinkat(t.parent, &t.name, linux.AT.REMOVEDIR);
    sys.close(t.parent);
    t.* = .{ .pgid = t.pgid };
}

/// Ends a pipeline whose programs ended. A tree that still has a
/// process goes to the list, so the time limit and `abandonAll` still
/// reach it.
fn settle(it: *Interp, tree: Tree, start_ms: i64) Error!void {
    var t = tree;
    if (treeLive(&t)) return it.execs.groups.append(it.alloc(), .{ .tree = t, .pids = &.{}, .start = start_ms });
    treeClose(&t);
}

/// The wait status of a process, or null while it runs.
fn waitPid(pid: i32, block: bool) ?u32 {
    var status: u32 = 0;
    while (true) {
        const rc = linux.wait4(pid, &status, if (block) 0 else linux.W.NOHANG, null);
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
                treeKill(&st.tree, st.pids);
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
        try it.execs.groups.append(a, .{ .tree = st.tree, .pids = st.pids, .start = st.start });
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
                    treeKill(&st.tree, st.pids);
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
                    treeKill(&st.tree, st.pids);
                },
                else => {},
            }
            break;
        }
        sys.close(st.out);
    }
    const failed = finish(it, st, &text, plan.ignore_err) catch |e| {
        try settle(it, st.tree, st.start);
        return e;
    };
    try settle(it, st.tree, st.start);
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
    c.tree = st.tree;
    return .{ .str = c.name };
}

/// Waits for the processes of a pipeline channel that closed.
pub fn reap(it: *Interp, c: *chan.Channel) Error!void {
    var text: std.ArrayList(u8) = .empty;
    const st: Started = .{ .pids = @constCast(c.pids), .err = c.err_fd, .start = c.started, .tree = c.tree };
    // A channel that does not block does not wait for its processes.
    if (!c.blocking) {
        try it.execs.groups.append(it.alloc(), .{ .tree = c.tree, .pids = c.pids, .start = c.started });
        if (c.err_fd >= 0) sys.close(c.err_fd);
        return;
    }
    const failed = finish(it, st, &text, false) catch |e| {
        try settle(it, st.tree, st.start);
        return e;
    };
    try settle(it, st.tree, st.start);
    if (failed) {
        it.result = .{ .str = stripNewline(text.items) };
        return error.TclError;
    }
}

/// Ends the processes of a pipeline channel with no wait for output.
pub fn abandon(c: *chan.Channel) void {
    treeKill(&c.tree, c.pids);
    for (c.pids) |p| _ = waitPid(p, true);
    treeClose(&c.tree);
    if (c.err_fd >= 0) sys.close(c.err_fd);
}

/// Collects the trees that ended, and kills each tree that is past the
/// time limit.
pub fn sweep(it: *Interp) void {
    var i: usize = 0;
    while (i < it.execs.groups.items.len) {
        const g = &it.execs.groups.items[i];
        var live = false;
        const late = if (deadline(it, g.start)) |l| nowMs() >= l else false;
        if (late) treeKill(&g.tree, g.pids);
        for (g.pids) |p| {
            // The group stays live while a wait gives no status. A pid
            // that was collected before gives an error, which counts
            // as ended.
            if (waitPid(p, late) == null) live = true;
        }
        // A process below the programs keeps the tree live.
        if (!late and treeLive(&g.tree)) live = true;
        if (live) {
            i += 1;
        } else {
            treeClose(&g.tree);
            _ = it.execs.groups.orderedRemove(i);
        }
    }
}

/// Kills each tree when the interpreter ends.
pub fn abandonAll(it: *Interp) void {
    for (it.execs.groups.items) |*g| {
        treeKill(&g.tree, g.pids);
        for (g.pids) |p| _ = waitPid(p, true);
        treeClose(&g.tree);
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

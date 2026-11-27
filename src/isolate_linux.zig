//! The sandbox of the `process` level of isolated threads on Linux
//! (ztcl#209, `docs/dev/isolation.md`). The macOS sandbox is
//! `isolate_mac.zig` and the Windows sandbox is `isolate_windows.zig`.
//!
//! `spawn` starts the ztcl runner with `clone3` in new namespaces
//! (`namespaces(7)`): user, PID, mount, IPC, UTS, cgroup, and network
//! (without the `socket` capability). The flag `CLONE_INTO_CGROUP`
//! puts the child in a cgroup v2 group of its own (`cgroups(7)`) at its
//! start, so no code of it runs outside the group. Before it starts the
//! runner, the child uses raw system calls only:
//!
//! 1. It maps its user and group ids to the same ids in the new user
//!    namespace (`user_namespaces(7)`).
//! 2. It makes each mount private, mounts a tmpfs on `/tmp`, and builds
//!    the new root there: `/proc` (a new proc for the PID namespace),
//!    the root folder of the thread at its real path, the zone data for
//!    `clock`, and `/etc/hosts` and `/etc/resolv.conf` for `socket`.
//!    The source of each bind is a descriptor that the parent opened.
//! 3. `pivot_root` makes the tmpfs the root, and the old root goes.
//!    The tmpfs is then read-only.
//! 4. It sets `PR_SET_NO_NEW_PRIVS` and `PR_SET_PDEATHSIG` (a parent
//!    that ends kills the child), puts the socket of the transport at
//!    descriptor 3, and runs the runner with `execveat` on a descriptor.
//!    A runner with no `PT_INTERP` needs no file in the new root.
//!
//! A failed step writes its number and its errno on a pipe with
//! `O_CLOEXEC`, so `spawn` gives an error that names the missing
//! feature. A pipe with no bytes at its end means that `execveat` ran.
//!
//! The runner calls `enter` after the start frame and before the first
//! script. It adds Landlock rules (`landlock(7)`): files only in the
//! root folder, read access to the zone data and the files of the
//! network, TCP only with `socket`, and no signal or abstract socket out
//! of the sandbox. Then it adds a seccomp filter (`seccomp(2)`) with the
//! flag `TSYNC`: an allow list of the system calls of the runner, made
//! at compile time. `clone` needs `CLONE_THREAD`, `clone3` gives
//! `ENOSYS`, `socket` needs the `socket` capability, and each other
//! call gives `EPERM`. So the child cannot start a program, mount a
//! file system, or make a namespace.
//!
//! The group of a child is under the delegated cgroup of the user: the
//! highest ancestor of the group of the parent that the user owns (the
//! systemd user manager on most systems), in `ztcl-iso/`. Its limits
//! are `memory.max` (and `memory.swap.max` 0), `pids.max`, `cpu.max`,
//! `cpu.weight`, and optional `io.max`. `usage` reads `cpu.stat` and
//! `memory.peak`, so the counts do not depend on what the child says.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const SYS = linux.SYS;

pub const supported = builtin.os.tag == .linux and (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64);

/// The exit code of a child that `kill` or a limit ended.
pub const killed_code: u32 = 137;

pub const Limits = struct {
    /// `memory.max`, or 0 for no limit.
    mem_bytes: u64 = 0,
    /// `cpu.max` in percent of one CPU, or 0 for no limit.
    cpu_pct: u32 = 100,
    /// `cpu.weight`, from 1 to 10,000.
    cpu_weight: u32 = 100,
    /// `pids.max`: the runner and its threads.
    pids: u32 = 32,
    /// `io.max`: a block device as `MAJ:MIN`, and the bytes per second
    /// of its reads and writes. Needs the `io` controller.
    io_dev: ?[]const u8 = null,
    io_bps: u64 = 0,
};

pub const Spawn = struct {
    /// The real path of the root folder of the file jail, or null.
    root: ?[]const u8 = null,
    /// `-files host`: the mount namespace keeps the files of the host,
    /// with a new `/proc`.
    host_files: bool = false,
    /// The `socket` capability: the network of the host.
    net: bool = false,
    /// The `clock` capability: the zone data.
    zones: bool = false,
    limits: Limits = .{},
    /// For a test: a function that runs in the child after the new root
    /// in place of the runner. Its result is the exit code.
    entry: ?*const fn () u8 = null,
};

pub const ExitStatus = struct {
    code: u32,
    /// True when `kill`, a limit, or a signal ended it.
    killed: bool,
};

pub const Usage = struct { cpu_ns: u64, peak_bytes: u64, oom_kills: u64 };

pub const SpawnError = error{
    OutOfMemory,
    Unsupported,
    SpawnFailed,
    /// No unprivileged user namespace (`clone3` or the id maps).
    UserNamespace,
    /// No mount in the user namespace, for example with the AppArmor
    /// limit of unprivileged user namespaces.
    Mount,
    /// No proc mount in the PID namespace.
    Proc,
    /// No cgroup v2 group with the cpu, memory, and pids controllers
    /// that the user can write.
    Cgroup,
    /// No `io` controller for `io.max`.
    CgroupIo,
    /// No Landlock (Linux 5.13 or later, with `landlock` in the LSMs).
    Landlock,
    /// No seccomp filter.
    Seccomp,
};

/// The text of an error of `spawn`, with the missing feature.
pub fn message(e: SpawnError) []const u8 {
    return switch (e) {
        error.UserNamespace => "the kernel does not allow unprivileged user namespaces",
        error.Mount => "the kernel does not allow mounts in an unprivileged user namespace",
        error.Proc => "the kernel does not allow a proc mount in a new PID namespace",
        error.Cgroup => "no delegated cgroup v2 group with the cpu, memory, and pids controllers",
        error.CgroupIo => "the delegated cgroup has no io controller",
        error.Landlock => "the kernel has no Landlock (Linux 5.13 or later, landlock in the LSM list)",
        error.Seccomp => "the kernel has no seccomp filter",
        error.Unsupported => "the level process needs Linux on x86_64 or aarch64",
        error.OutOfMemory => "out of memory",
        error.SpawnFailed => "the system could not start the child process",
    };
}

/// The last errno of a failed step of `spawn` in this thread.
pub threadlocal var last_errno: u16 = 0;
/// The step of the child of the last failed `spawn` of this thread.
pub threadlocal var last_step: u8 = 0;

pub const Child = struct {
    a: std.mem.Allocator,
    pid: i32,
    pidfd: i32,
    /// The parent end of the transport.
    fd: i32,
    fd_owned: bool = true,
    /// The folder of the cgroup of the child.
    group: [:0]u8,
    killed: bool = false,
    status: ?ExitStatus = null,

    /// The status of the end, or null while the child runs after
    /// `timeout_ms`.
    pub fn wait(c: *Child, timeout_ms: u32) ?ExitStatus {
        if (c.status) |s| return s;
        var p = [_]linux.pollfd{.{ .fd = c.pidfd, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&p, 1, @intCast(@min(timeout_ms, std.math.maxInt(i32))));
        var st: u32 = 0;
        const r = linux.syscall4(.wait4, @bitCast(@as(isize, c.pid)), @intFromPtr(&st), linux.W.NOHANG, 0);
        if (linux.errno(r) != .SUCCESS or r == 0) return null;
        const sig = st & 0x7f;
        c.status = if (sig == 0)
            .{ .code = (st >> 8) & 0xff, .killed = c.killed }
        else
            .{ .code = 128 + sig, .killed = true };
        return c.status;
    }

    /// Gives the transport to the caller, who then closes it.
    pub fn takeFd(c: *Child) i32 {
        c.fd_owned = false;
        return c.fd;
    }

    /// Ends the child and each process of its group at once.
    pub fn kill(c: *Child) void {
        if (c.status != null) return;
        c.killed = true;
        _ = linux.pidfd_send_signal(c.pidfd, .KILL, null, 0);
        writeIn(c.group, "cgroup.kill", "1") catch {};
    }

    /// The counts of the cgroup of the child, for `total_compute` and
    /// `total_mem` (ztcl#243).
    pub fn usage(c: *Child) Usage {
        var buf: [1024]u8 = undefined;
        var u: Usage = .{ .cpu_ns = 0, .peak_bytes = 0, .oom_kills = 0 };
        if (readIn(c.group, "cpu.stat", &buf)) |s| u.cpu_ns = (field(s, "usage_usec") orelse 0) * 1000;
        if (readIn(c.group, "memory.peak", &buf) orelse readIn(c.group, "memory.current", &buf)) |s|
            u.peak_bytes = std.fmt.parseInt(u64, std.mem.trim(u8, s, " \n"), 10) catch 0;
        if (readIn(c.group, "memory.events", &buf)) |s| u.oom_kills = field(s, "oom_kill") orelse 0;
        return u;
    }

    /// Ends the child if it runs, closes its descriptors, and removes
    /// its cgroup.
    pub fn deinit(c: *Child) void {
        if (c.wait(0) == null) {
            c.kill();
            _ = c.wait(5000);
        }
        if (c.fd_owned) _ = linux.close(c.fd);
        _ = linux.close(c.pidfd);
        // The kernel frees a group a short time after its last process.
        var n: u32 = 0;
        while (n < 100) : (n += 1) {
            if (linux.errno(linux.rmdir(c.group.ptr)) != .BUSY) break;
            sleepMs(10);
        }
        c.a.free(c.group);
        c.* = undefined;
    }
};

fn sleepMs(ms: u64) void {
    const ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = linux.syscall2(.nanosleep, @intFromPtr(&ts), 0);
}

/// The number after `name ` on a line of a cgroup file.
fn field(s: []const u8, name: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |l| {
        if (l.len > name.len and std.mem.startsWith(u8, l, name) and l[name.len] == ' ')
            return std.fmt.parseInt(u64, l[name.len + 1 ..], 10) catch null;
    }
    return null;
}

// ---- Files with raw system calls ----

fn openZ(path: [*:0]const u8, flags: u32) ?i32 {
    const r = linux.syscall4(.openat, @bitCast(@as(isize, linux.AT.FDCWD)), @intFromPtr(path), flags, 0o644);
    if (linux.errno(r) != .SUCCESS) return null;
    return @intCast(r);
}

const o_rdonly: u32 = 0;
const o_wronly: u32 = 1;
const o_cloexec: u32 = 0o2000000;
const o_creat: u32 = 0o100;
const o_directory: u32 = if (builtin.cpu.arch == .aarch64) 0o40000 else 0o200000;
const o_path: u32 = 0o10000000;

fn pathIn(buf: []u8, dir: []const u8, name: []const u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir, name }, 0) catch null;
}

fn writeIn(dir: []const u8, name: []const u8, text: []const u8) !void {
    var pb: [4096]u8 = undefined;
    const p = pathIn(&pb, dir, name) orelse return error.Name;
    const fd = openZ(p.ptr, o_wronly | o_cloexec) orelse return error.Open;
    defer _ = linux.close(fd);
    const r = linux.write(fd, text.ptr, text.len);
    if (linux.errno(r) != .SUCCESS) return error.Write;
}

fn readIn(dir: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    var pb: [4096]u8 = undefined;
    const p = pathIn(&pb, dir, name) orelse return null;
    return readFile(p.ptr, buf);
}

fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd = openZ(path, o_rdonly | o_cloexec) orelse return null;
    defer _ = linux.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = linux.read(fd, buf[n..].ptr, buf.len - n);
        if (linux.errno(r) != .SUCCESS) return null;
        if (r == 0) break;
        n += r;
    }
    return buf[0..n];
}

/// Moves `fd` to a descriptor of 64 or more, so a `dup3` to 3 in the
/// child cannot close a descriptor of the plan.
fn high(fd: i32) ?i32 {
    const r = linux.syscall3(.fcntl, @bitCast(@as(isize, fd)), 1030, 64);
    _ = linux.close(fd);
    if (linux.errno(r) != .SUCCESS) return null;
    return @intCast(r);
}

// ---- The cgroup ----

var counter = std.atomic.Value(u32).init(0);

fn ownerOf(path: [*:0]const u8) ?u32 {
    var sx: linux.Statx = undefined;
    const r = linux.statx(linux.AT.FDCWD, path, 0, .{ .UID = true }, &sx);
    if (linux.errno(r) != .SUCCESS) return null;
    return sx.uid;
}

/// Makes `ztcl-iso` under the highest group that the user owns, with
/// the cpu, memory, and pids controllers. Gives its path.
fn groupBase(a: std.mem.Allocator) SpawnError![:0]u8 {
    var buf: [4096]u8 = undefined;
    const s = readFile("/proc/self/cgroup", &buf) orelse return error.Cgroup;
    var lines = std.mem.splitScalar(u8, s, '\n');
    const rel = while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "0::/")) break l[3..];
    } else return error.Cgroup;
    const uid = linux.getuid();
    const full = try std.fmt.allocPrintSentinel(a, "/sys/fs/cgroup{s}", .{std.mem.trimEnd(u8, rel, "/")}, 0);
    defer a.free(full);
    var top = full;
    if (ownerOf(top.ptr) != uid) return error.Cgroup;
    while (true) {
        const cut = std.mem.lastIndexOfScalar(u8, top, '/') orelse break;
        if (cut <= "/sys/fs/cgroup".len) break;
        top[cut] = 0;
        const mine = ownerOf(@ptrCast(top.ptr)) == uid;
        if (!mine) {
            top[cut] = '/';
            break;
        }
        top = top[0..cut :0];
    }
    const base = try std.fmt.allocPrintSentinel(a, "{s}/ztcl-iso", .{top}, 0);
    errdefer a.free(base);
    const r = linux.mkdirat(linux.AT.FDCWD, base.ptr, 0o755);
    if (linux.errno(r) != .SUCCESS and linux.errno(r) != .EXIST) return error.Cgroup;
    var cb: [512]u8 = undefined;
    const have = readIn(base, "cgroup.controllers", &cb) orelse return error.Cgroup;
    inline for (.{ "cpu", "memory", "pids" }) |name| {
        if (!hasWord(have, name)) return error.Cgroup;
    }
    var sb: [512]u8 = undefined;
    const on = readIn(base, "cgroup.subtree_control", &sb) orelse return error.Cgroup;
    inline for (.{ "cpu", "memory", "pids", "io" }) |name| {
        if (!hasWord(on, name) and hasWord(have, name)) writeIn(base, "cgroup.subtree_control", "+" ++ name) catch return error.Cgroup;
    }
    return base;
}

fn hasWord(s: []const u8, w: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, s, " \n");
    while (it.next()) |x| if (std.mem.eql(u8, x, w)) return true;
    return false;
}

/// Makes the group of a new child with the limits `l`.
fn makeGroup(a: std.mem.Allocator, l: Limits) SpawnError![:0]u8 {
    const base = try groupBase(a);
    defer a.free(base);
    const g = try std.fmt.allocPrintSentinel(a, "{s}/{d}-{d}", .{ base, linux.getpid(), counter.fetchAdd(1, .monotonic) }, 0);
    errdefer a.free(g);
    if (linux.errno(linux.mkdirat(linux.AT.FDCWD, g.ptr, 0o755)) != .SUCCESS) return error.Cgroup;
    errdefer _ = linux.rmdir(g.ptr);
    var nb: [96]u8 = undefined;
    if (l.mem_bytes > 0) {
        writeIn(g, "memory.max", std.fmt.bufPrint(&nb, "{d}", .{l.mem_bytes}) catch unreachable) catch return error.Cgroup;
        writeIn(g, "memory.swap.max", "0") catch {};
    }
    writeIn(g, "pids.max", std.fmt.bufPrint(&nb, "{d}", .{l.pids}) catch unreachable) catch return error.Cgroup;
    if (l.cpu_pct > 0) writeIn(g, "cpu.max", std.fmt.bufPrint(&nb, "{d} 100000", .{@as(u64, l.cpu_pct) * 1000}) catch unreachable) catch return error.Cgroup;
    writeIn(g, "cpu.weight", std.fmt.bufPrint(&nb, "{d}", .{std.math.clamp(l.cpu_weight, 1, 10000)}) catch unreachable) catch return error.Cgroup;
    if (l.io_dev) |dev| {
        writeIn(g, "io.max", std.fmt.bufPrint(&nb, "{s} rbps={d} wbps={d}", .{ dev, l.io_bps, l.io_bps }) catch return error.CgroupIo) catch return error.CgroupIo;
    }
    return g;
}

// ---- The start ----

const max_binds = 4;

const Bind = struct {
    /// The source path. The child opens it in its own mount namespace:
    /// a bind of a mount of another namespace gives EINVAL.
    src: [:0]const u8,
    /// The path in the new root, after `/tmp`.
    dst: [:0]u8,
    file: bool,
    ro: bool,
};

/// Each string and descriptor of the child, made before `clone3`: the
/// child makes no allocation.
const Plan = struct {
    uid_map: []const u8,
    gid_map: []const u8,
    binds: [max_binds]Bind = undefined,
    n_binds: usize = 0,
    host_files: bool,
    sock: i32,
    exe: i32,
    err: i32,
    entry: ?*const fn () u8,
};

const step_map: u8 = 1;
const step_mount: u8 = 2;
const step_proc: u8 = 3;
const step_pivot: u8 = 4;
const step_fds: u8 = 5;
const step_exec: u8 = 6;

const ms_rdonly = 1;
const ms_nosuid = 2;
const ms_nodev = 4;
const ms_noexec = 8;
const ms_bind = 4096;
const ms_rec = 16384;
const ms_private = 1 << 18;

const attr_rdonly: u64 = 1;
const attr_nosuid: u64 = 2;
const attr_nodev: u64 = 4;
const attr_noexec: u64 = 8;

fn ok(r: usize) bool {
    return linux.errno(r) == .SUCCESS;
}

fn fail(p: *const Plan, step: u8, r: usize) noreturn {
    const e: u16 = @backingInt(linux.errno(r));
    const b = [3]u8{ step, @truncate(e), @truncate(e >> 8) };
    _ = linux.write(p.err, &b, 3);
    linux.exit_group(127);
}

fn writeFileZ(path: [*:0]const u8, text: []const u8) usize {
    const r = linux.syscall4(.openat, @bitCast(@as(isize, linux.AT.FDCWD)), @intFromPtr(path), o_wronly | o_cloexec, 0);
    if (!ok(r)) return r;
    const fd: i32 = @intCast(r);
    const w = linux.write(fd, text.ptr, text.len);
    _ = linux.close(fd);
    return w;
}

/// `mkdir -p` of `path` in place: each `/` becomes a 0 for a moment.
fn mkdirs(path: [:0]u8) usize {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and path[i] != '/') continue;
        const keep = path[i];
        path[i] = 0;
        const r = linux.mkdirat(linux.AT.FDCWD, @ptrCast(path.ptr), 0o755);
        path[i] = keep;
        if (!ok(r) and linux.errno(r) != .EXIST) return r;
    }
    return 0;
}

fn setAttr(path: [*:0]const u8, set: u64) usize {
    const attr = [4]u64{ set, 0, 0, 0 };
    return linux.syscall5(.mount_setattr, @bitCast(@as(isize, linux.AT.FDCWD)), @intFromPtr(path), 0, @intFromPtr(&attr), @sizeOf(@TypeOf(attr)));
}

/// The child between `clone3` and `execveat`. It uses raw system calls
/// only, since another thread of the parent can hold a lock.
fn childRun(p: *const Plan) noreturn {
    var r = writeFileZ("/proc/self/setgroups", "deny");
    if (!ok(r)) fail(p, step_map, r);
    r = writeFileZ("/proc/self/uid_map", p.uid_map);
    if (!ok(r)) fail(p, step_map, r);
    r = writeFileZ("/proc/self/gid_map", p.gid_map);
    if (!ok(r)) fail(p, step_map, r);

    r = linux.mount(null, "/", null, ms_rec | ms_private, 0);
    if (!ok(r)) fail(p, step_mount + 0, r);
    if (p.host_files) {
        r = linux.mount("proc", "/proc", "proc", ms_nosuid | ms_nodev | ms_noexec, 0);
        if (!ok(r)) fail(p, step_proc, r);
    } else newRoot(p);
    finish(p);
}

/// Builds the new root on a tmpfs and enters it.
fn newRoot(p: *const Plan) void {
    var fds: [max_binds]i32 = undefined;
    for (p.binds[0..p.n_binds], 0..) |b, i| {
        const o = linux.syscall4(.openat, @bitCast(@as(isize, linux.AT.FDCWD)), @intFromPtr(b.src.ptr), o_path | o_cloexec, 0);
        if (!ok(o)) fail(p, step_mount, o);
        fds[i] = @intCast(o);
    }
    var r = linux.mount("tmpfs", "/tmp", "tmpfs", ms_nosuid | ms_nodev, @intFromPtr("mode=0755,size=1m"));
    if (!ok(r)) fail(p, step_mount + 16, r);
    r = linux.mkdirat(linux.AT.FDCWD, "/tmp/proc", 0o555);
    if (!ok(r)) fail(p, step_mount + 32, r);
    r = linux.mkdirat(linux.AT.FDCWD, "/tmp/.old", 0o700);
    if (!ok(r)) fail(p, step_mount + 48, r);
    for (p.binds[0..p.n_binds], fds[0..p.n_binds]) |b, bfd| {
        if (b.file) {
            const cut = std.mem.lastIndexOfScalar(u8, b.dst, '/').?;
            b.dst[cut] = 0;
            r = mkdirs(b.dst[0..cut :0]);
            b.dst[cut] = '/';
            if (!ok(r)) fail(p, step_mount + 64, r);
            r = linux.syscall4(.openat, @bitCast(@as(isize, linux.AT.FDCWD)), @intFromPtr(b.dst.ptr), o_wronly | o_creat | o_cloexec, 0o644);
            if (!ok(r)) fail(p, step_mount + 80, r);
            _ = linux.close(@intCast(r));
        } else {
            r = mkdirs(b.dst);
            if (!ok(r)) fail(p, step_mount + 96, r);
        }
        var src: [32]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&src, "/proc/self/fd/{d}", .{bfd}, 0) catch unreachable;
        r = linux.mount(s.ptr, b.dst.ptr, null, ms_bind | ms_rec, 0);
        if (!ok(r)) fail(p, step_mount + 112, r);
        r = setAttr(b.dst.ptr, attr_nosuid | attr_nodev | attr_noexec | (if (b.ro) attr_rdonly else 0));
        if (!ok(r)) fail(p, step_mount + 128, r);
    }
    r = linux.mount("proc", "/tmp/proc", "proc", ms_nosuid | ms_nodev | ms_noexec, 0);
    if (!ok(r)) fail(p, step_proc, r);
    r = linux.pivot_root("/tmp", "/tmp/.old");
    if (!ok(r)) fail(p, step_pivot, r);
    r = linux.chdir("/");
    if (!ok(r)) fail(p, step_pivot, r);
    r = linux.umount2("/.old", linux.MNT.DETACH);
    if (!ok(r)) fail(p, step_pivot, r);
    r = linux.rmdir("/.old");
    if (!ok(r)) fail(p, step_pivot, r);
    r = setAttr("/", attr_rdonly | attr_nosuid | attr_nodev);
    if (!ok(r)) fail(p, step_pivot, r);
}

/// Sets the flags of the process and the descriptors, and runs the
/// runner.
fn finish(p: *const Plan) noreturn {
    var r = linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    if (!ok(r)) fail(p, step_fds, r);
    r = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), 9, 0, 0, 0);
    if (!ok(r)) fail(p, step_fds, r);
    r = linux.dup3(p.sock, 3, 0);
    if (!ok(r)) fail(p, step_fds, r);
    r = linux.close_range(4, std.math.maxInt(i32), .{ .UNSHARE = false, .CLOEXEC = true });
    if (!ok(r)) fail(p, step_fds, r);

    if (p.entry) |f| {
        // A test function: an empty pipe tells the parent that the
        // sandbox is ready.
        _ = linux.close(p.err);
        linux.exit_group(f());
    }
    const argv = [_:null]?[*:0]const u8{ "ztcl", "--iso-fd", "3" };
    const envp = [_:null]?[*:0]const u8{};
    r = linux.execveat(p.exe, "", &argv, &envp, .{ .EMPTY_PATH = true, .SYMLINK_NOFOLLOW = false });
    fail(p, step_exec, r);
}

/// Opens `path` for a bind, with `O_PATH`, at a high descriptor.
fn openBind(a: std.mem.Allocator, path: []const u8, dir: bool) SpawnError!?i32 {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    const fd = openZ(z.ptr, o_path | o_cloexec | (if (dir) o_directory else 0)) orelse return null;
    return high(fd);
}

/// Starts the runner `self_exe` in a new sandbox with `s`.
pub fn spawn(a: std.mem.Allocator, self_exe: []const u8, s: Spawn) SpawnError!Child {
    if (comptime !supported) return error.Unsupported;
    if (landlockAbi() == 0) return error.Landlock;
    if (linux.errno(linux.prctl(21, 0, 0, 0, 0)) != .SUCCESS) return error.Seccomp;

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    var p: Plan = .{
        .uid_map = try std.fmt.allocPrint(ar, "{d} {d} 1\n", .{ linux.getuid(), linux.getuid() }),
        .gid_map = try std.fmt.allocPrint(ar, "{d} {d} 1\n", .{ linux.getgid(), linux.getgid() }),
        .host_files = s.host_files,
        .sock = -1,
        .exe = -1,
        .err = -1,
        .entry = s.entry,
    };
    var fds_to_close: [max_binds + 4]i32 = undefined;
    var n_close: usize = 0;
    defer for (fds_to_close[0..n_close]) |fd| {
        _ = linux.close(fd);
    };
    const addBind = struct {
        fn f(pl: *Plan, ar2: std.mem.Allocator, list: []i32, n: *usize, src: []const u8, dir: bool, ro: bool) SpawnError!void {
            const fd = (try openBind(ar2, src, dir)) orelse return;
            list[n.*] = fd;
            n.* += 1;
            pl.binds[pl.n_binds] = .{ .src = try ar2.dupeSentinel(u8, src, 0), .dst = try std.fmt.allocPrintSentinel(ar2, "/tmp{s}", .{src}, 0), .file = !dir, .ro = ro };
            pl.n_binds += 1;
        }
    }.f;
    if (s.root != null and s.host_files) return error.SpawnFailed;
    if (s.root) |root| {
        if (root.len == 0 or root[0] != '/') return error.SpawnFailed;
        const before = p.n_binds;
        try addBind(&p, ar, &fds_to_close, &n_close, root, true, false);
        if (p.n_binds == before) return error.SpawnFailed;
    }
    if (s.zones) try addBind(&p, ar, &fds_to_close, &n_close, "/usr/share/zoneinfo", true, true);
    if (s.net) {
        try addBind(&p, ar, &fds_to_close, &n_close, "/etc/hosts", false, true);
        try addBind(&p, ar, &fds_to_close, &n_close, "/etc/resolv.conf", false, true);
    }

    const exe_z = try ar.dupeSentinel(u8, self_exe, 0);
    p.exe = high(openZ(exe_z.ptr, o_path | o_cloexec) orelse return error.SpawnFailed) orelse return error.SpawnFailed;
    fds_to_close[n_close] = p.exe;
    n_close += 1;

    var sv: [2]i32 = undefined;
    if (!ok(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sv))) return error.SpawnFailed;
    p.sock = high(sv[1]) orelse {
        _ = linux.close(sv[0]);
        return error.SpawnFailed;
    };
    fds_to_close[n_close] = p.sock;
    n_close += 1;
    errdefer _ = linux.close(sv[0]);

    var ep: [2]i32 = undefined;
    if (!ok(linux.pipe2(&ep, .{ .CLOEXEC = true }))) return error.SpawnFailed;
    p.err = high(ep[1]) orelse {
        _ = linux.close(ep[0]);
        return error.SpawnFailed;
    };
    defer _ = linux.close(ep[0]);
    var err_open = true;
    defer if (err_open) {
        _ = linux.close(p.err);
    };

    const group = try makeGroup(a, s.limits);
    errdefer {
        _ = linux.rmdir(group.ptr);
        a.free(group);
    }
    const gfd = openZ(group.ptr, o_path | o_directory | o_cloexec) orelse return error.Cgroup;
    defer _ = linux.close(gfd);

    var pidfd: i32 = -1;
    const C = linux.CLONE;
    var flags: u64 = C.NEWUSER | C.NEWPID | C.NEWNS | C.NEWIPC | C.NEWUTS | C.NEWCGROUP | C.PIDFD | C.INTO_CGROUP;
    if (!s.net) flags |= C.NEWNET;
    // struct clone_args: flags, pidfd, child_tid, parent_tid,
    // exit_signal, stack, stack_size, tls, set_tid, set_tid_size, cgroup.
    var args = [11]u64{ flags, @intFromPtr(&pidfd), 0, 0, 17, 0, 0, 0, 0, 0, @intCast(gfd) };
    const r = linux.syscall2(.clone3, @intFromPtr(&args), @sizeOf(@TypeOf(args)));
    switch (linux.errno(r)) {
        .SUCCESS => {},
        .NOSYS => return error.Unsupported,
        .PERM, .NOSPC, .USERS => {
            last_errno = @backingInt(linux.errno(r));
            return error.UserNamespace;
        },
        .ACCES, .BUSY, .OPNOTSUPP => {
            last_errno = @backingInt(linux.errno(r));
            return error.Cgroup;
        },
        else => {
            last_errno = @backingInt(linux.errno(r));
            return error.SpawnFailed;
        },
    }
    if (r == 0) childRun(&p);

    _ = linux.close(p.err);
    err_open = false;
    var c: Child = .{ .a = a, .pid = @intCast(r), .pidfd = pidfd, .fd = sv[0], .group = group };
    var eb: [3]u8 = undefined;
    var got: usize = 0;
    while (got < 3) {
        const n = linux.read(ep[0], eb[got..].ptr, 3 - got);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        got += n;
    }
    if (got == 0) return c;
    // A step failed: the child exits with 127.
    _ = c.wait(5000);
    c.fd_owned = false;
    last_errno = if (got == 3) @as(u16, eb[1]) | @as(u16, eb[2]) << 8 else 0;
    _ = linux.close(pidfd);
    last_step = eb[0];
    return switch (eb[0] & 15) {
        step_map => error.UserNamespace,
        step_mount => error.Mount,
        step_proc => error.Proc,
        else => error.SpawnFailed,
    };
}

// ---- Landlock ----

const ll_create_version: u32 = 1;
const ll_rule_path_beneath: u32 = 1;

const fs_execute: u64 = 1 << 0;
const fs_write_file: u64 = 1 << 1;
const fs_read_file: u64 = 1 << 2;
const fs_read_dir: u64 = 1 << 3;
const fs_make_char: u64 = 1 << 6;
const fs_make_block: u64 = 1 << 11;
const fs_refer: u64 = 1 << 13;
const fs_truncate: u64 = 1 << 14;
const fs_ioctl_dev: u64 = 1 << 15;
const net_bind_tcp: u64 = 1 << 0;
const net_connect_tcp: u64 = 1 << 1;
const scope_abstract_unix: u64 = 1 << 0;
const scope_signal: u64 = 1 << 1;

/// The Landlock ABI of the kernel, or 0 when it has none.
pub fn landlockAbi() u32 {
    if (comptime !supported) return 0;
    const r = linux.syscall3(.landlock_create_ruleset, 0, 0, ll_create_version);
    if (!ok(r)) return 0;
    return @intCast(r);
}

/// Each file right of the ABI `abi`.
fn fsRights(abi: u32) u64 {
    var all: u64 = (1 << 13) - 1;
    if (abi >= 2) all |= fs_refer;
    if (abi >= 3) all |= fs_truncate;
    if (abi >= 5) all |= fs_ioctl_dev;
    return all;
}

const PathBeneath = extern struct { allowed: u64 align(4), parent_fd: i32 };

/// Adds a rule for `path`. A path that does not exist needs no rule.
fn addPath(ruleset: i32, path: [*:0]const u8, rights: u64, dir: bool) !void {
    const fd = openZ(path, o_path | o_cloexec | (if (dir) o_directory else 0)) orelse return;
    defer _ = linux.close(fd);
    const pb: PathBeneath = .{ .allowed = rights, .parent_fd = fd };
    if (!ok(linux.syscall4(.landlock_add_rule, @intCast(ruleset), ll_rule_path_beneath, @intFromPtr(&pb), 0))) return error.Landlock;
}

pub const Options = struct {
    /// The real path of the root folder, or null for no files.
    root: ?[]const u8 = null,
    /// `-files host`: no Landlock rule for files.
    host_files: bool = false,
    /// The `socket` capability.
    net: bool = false,
    /// The `clock` capability: the zone data.
    zones: bool = false,
};

/// Enters the Landlock domain and the seccomp filter of `o`. They
/// cannot be left. It makes no allocation.
pub fn enter(o: Options) !void {
    if (comptime !supported) return error.Unsupported;
    const abi = landlockAbi();
    if (abi == 0) return error.Landlock;
    const fs = fsRights(abi);
    var attr = [3]u64{ if (o.host_files) 0 else fs, 0, 0 };
    if (abi >= 4 and !o.net) attr[1] = net_bind_tcp | net_connect_tcp;
    if (abi >= 6) attr[2] = scope_abstract_unix | scope_signal;
    const size: usize = if (abi >= 6) 24 else if (abi >= 4) 16 else 8;
    // A ruleset needs one handled right: host files with no other limit
    // of this ABI have no Landlock domain, and seccomp still applies.
    if (attr[0] == 0 and attr[1] == 0 and attr[2] == 0) return filterOnly(o);
    const rr = linux.syscall3(.landlock_create_ruleset, @intFromPtr(&attr), size, 0);
    if (!ok(rr)) return error.Landlock;
    const ruleset: i32 = @intCast(rr);
    defer _ = linux.close(ruleset);
    if (o.root) |root| {
        var buf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{root}, 0) catch return error.Landlock;
        try addPath(ruleset, z.ptr, fs & ~(fs_execute | fs_make_char | fs_make_block), true);
    }
    if (o.zones) try addPath(ruleset, "/usr/share/zoneinfo", fs_read_file | fs_read_dir, true);
    if (o.net) {
        try addPath(ruleset, "/etc/hosts", fs_read_file, false);
        try addPath(ruleset, "/etc/resolv.conf", fs_read_file, false);
    }
    if (!ok(linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0))) return error.Landlock;
    if (!ok(linux.syscall2(.landlock_restrict_self, @intCast(ruleset), 0))) return error.Landlock;
    return filterOnly(o);
}

/// Enters the seccomp filter of `o`.
fn filterOnly(o: Options) !void {
    if (!ok(linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0))) return error.Seccomp;
    const prog = if (o.net) &filter_net else &filter_nonet;
    const fprog: Fprog = .{ .len = @intCast(prog.len), .filter = prog.ptr };
    const r = linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, linux.SECCOMP.FILTER_FLAG.TSYNC, &fprog);
    if (!ok(r) or r != 0) return error.Seccomp;
    const zero = [2]u64{ 0, 0 };
    _ = linux.syscall4(.prlimit64, 0, 4, @intFromPtr(&zero), 0); // RLIMIT_CORE
}

// ---- seccomp ----

const Insn = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
const Fprog = extern struct { len: u16, filter: [*]const Insn };

fn stmt(code: u16, k: u32) Insn {
    return .{ .code = code, .jt = 0, .jf = 0, .k = k };
}
fn jump(code: u16, k: u32, jt: u8, jf: u8) Insn {
    return .{ .code = code, .jt = jt, .jf = jf, .k = k };
}

const ld_abs: u16 = 0x20;
const jeq: u16 = 0x15;
const jge: u16 = 0x35;
const jset: u16 = 0x45;
const ret: u16 = 0x06;
const RET = linux.SECCOMP.RET;

/// The system calls of the runner after `enter`. A name that the
/// architecture does not have is left out.
const allowed = [_][]const u8{
    "read",            "write",           "readv",           "writev",      "pread64",           "pwrite64",
    "preadv",          "pwritev",         "preadv2",         "pwritev2",    "close",             "openat",
    "openat2",         "fadvise64",       "open",            "lseek",       "fstat",             "newfstatat",
    "stat",            "lstat",           "statx",           "getdents64",  "getdents",          "mkdirat",
    "mkdir",           "unlinkat",        "unlink",          "rmdir",       "renameat",          "renameat2",
    "rename",          "linkat",          "link",            "symlinkat",   "symlink",           "readlinkat",
    "readlink",        "faccessat",       "faccessat2",      "access",      "fchmod",            "fchmodat",
    "chmod",           "utimensat",       "ftruncate",       "truncate",    "fsync",             "fdatasync",
    "fallocate",       "fcntl",           "ioctl",           "flock",       "dup",               "dup2",
    "dup3",            "pipe2",           "pipe",            "statfs",      "fstatfs",           "getcwd",
    "chdir",           "fchdir",          "umask",           "mmap",        "munmap",            "mprotect",
    "mremap",          "madvise",         "brk",             "msync",       "mincore",           "futex",
    "futex_waitv",     "set_robust_list", "get_robust_list", "rseq",        "set_tid_address",   "exit",
    "exit_group",      "gettid",          "getpid",          "getppid",     "getuid",            "geteuid",
    "getgid",          "getegid",         "tgkill",          "tkill",       "kill",              "rt_sigaction",
    "rt_sigprocmask",  "rt_sigreturn",    "sigaltstack",     "nanosleep",   "clock_nanosleep",   "clock_gettime",
    "clock_getres",    "gettimeofday",    "time",            "sched_yield", "sched_getaffinity", "getrandom",
    "uname",           "sysinfo",         "prlimit64",       "getrlimit",   "getrusage",         "times",
    "prctl",           "arch_prctl",      "poll",            "ppoll",       "select",            "pselect6",
    "epoll_create1",   "epoll_ctl",       "epoll_wait",      "epoll_pwait", "epoll_pwait2",      "eventfd2",
    "restart_syscall", "membarrier",      "copy_file_range", "sendfile",    "sendmsg",           "recvmsg",
    "sendto",          "recvfrom",        "shutdown",        "getsockopt",  "setsockopt",        "getsockname",
    "getpeername",
};
/// Only with the `socket` capability.
const allowed_net = [_][]const u8{ "connect", "bind", "listen", "accept", "accept4" };

fn sysNr(comptime name: []const u8) ?u32 {
    if (!@hasField(SYS, name)) return null;
    return @intCast(@backingInt(@field(SYS, name)));
}

fn countAllowed(comptime list: []const []const u8) usize {
    var n: usize = 0;
    for (list) |name| {
        if (sysNr(name) != null) n += 1;
    }
    return n;
}

const audit_arch: u32 = if (builtin.cpu.arch == .aarch64) 0xc00000b7 else 0xc000003e;
const clone_thread: u32 = 0x00010000;

fn filterLen(comptime net: bool) usize {
    var n: usize = 4 + 2 * countAllowed(&allowed) + 5 + 2 + 1;
    if (builtin.cpu.arch == .x86_64) n += 2;
    if (net) n += 7 + 2 * countAllowed(&allowed_net);
    return n;
}

/// The filter of the runner, made at compile time.
fn makeFilter(comptime net: bool) [filterLen(net)]Insn {
    @setEvalBranchQuota(100_000);
    var f: [filterLen(net)]Insn = undefined;
    var i: usize = 0;
    const add = struct {
        fn x(ff: []Insn, ii: *usize, in: Insn) void {
            ff[ii.*] = in;
            ii.* += 1;
        }
    }.x;
    add(&f, &i, stmt(ld_abs, 4)); // arch
    add(&f, &i, jump(jeq, audit_arch, 1, 0));
    add(&f, &i, stmt(ret, RET.KILL_PROCESS));
    add(&f, &i, stmt(ld_abs, 0)); // nr
    if (builtin.cpu.arch == .x86_64) {
        // The x32 calls of x86_64.
        add(&f, &i, jump(jge, 0x40000000, 0, 1));
        add(&f, &i, stmt(ret, RET.KILL_PROCESS));
    }
    for (allowed ++ (if (net) allowed_net else [_][]const u8{})) |name| {
        const nr = sysNr(name) orelse continue;
        add(&f, &i, jump(jeq, nr, 0, 1));
        add(&f, &i, stmt(ret, RET.ALLOW));
    }
    // clone: a thread only.
    add(&f, &i, jump(jeq, sysNr("clone").?, 0, 4));
    add(&f, &i, stmt(ld_abs, 16));
    add(&f, &i, jump(jset, clone_thread, 0, 1));
    add(&f, &i, stmt(ret, RET.ALLOW));
    add(&f, &i, stmt(ret, RET.ERRNO | 1));
    // clone3: its flags are in memory, so a C library falls back to clone.
    add(&f, &i, jump(jeq, sysNr("clone3").?, 0, 1));
    add(&f, &i, stmt(ret, RET.ERRNO | 38));
    // socket: AF_UNIX, AF_INET, and AF_INET6 with the capability, and
    // the EPERM of the end without it.
    if (net) {
        add(&f, &i, jump(jeq, sysNr("socket").?, 0, 6));
        add(&f, &i, stmt(ld_abs, 16));
        add(&f, &i, jump(jeq, 1, 2, 0));
        add(&f, &i, jump(jeq, 2, 1, 0));
        add(&f, &i, jump(jeq, 10, 0, 1));
        add(&f, &i, stmt(ret, RET.ALLOW));
        add(&f, &i, stmt(ret, RET.ERRNO | 97));
    }
    add(&f, &i, stmt(ret, RET.ERRNO | 1));
    if (i != f.len) @compileError("the length of the seccomp filter");
    return f;
}

const filter_net = if (supported) makeFilter(true) else [0]Insn{};
const filter_nonet = if (supported) makeFilter(false) else [0]Insn{};

test "isolate_linux: the seccomp filter checks the architecture first and ends with EPERM" {
    if (comptime !supported) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u32, 4), filter_nonet[0].k);
    try std.testing.expectEqual(RET.ERRNO | 1, filter_nonet[filter_nonet.len - 1].k);
    try std.testing.expect(filter_net.len > filter_nonet.len);
    try std.testing.expect(filter_nonet.len < 4096);
}

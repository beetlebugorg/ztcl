//! The PTY of `ztcl::pty` on macOS (`docs/dev/pty.md`). `openMaster`
//! opens the master side with `posix_openpt`, `grantpt`, and `unlockpt`,
//! and gives the path of the other side from `ptsname_r`. `start` runs
//! the program with `posix_spawn` and no `fork`, as `exec` does on
//! macOS. POSIX_SPAWN_SETSID makes the child the leader of a new session,
//! and its first open of the terminal, with no O_NOCTTY, makes the PTY
//! its controlling terminal. The open goes on descriptor 0, and copies go
//! on 1 and 2. POSIX_SPAWN_CLOEXEC_DEFAULT closes each other descriptor
//! in the child.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const c = std.c;
const E = c.E;

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern "c" fn posix_spawn_file_actions_addfchdir_np(actions: *c.posix_spawn_file_actions_t, fd: c_int) c_int;

/// The window size requests of the terminal driver of macOS.
const tiocswinsz: c_int = @bitCast(@as(u32, 0x80087467));
const tiocgwinsz: c_int = 0x40087468;
const spawn_setsid: c_short = 0x0400;
const spawn_cloexec_default: c_short = 0x4000;

fn errno() E {
    return @fromBackingInt(@intCast(c._errno().*));
}

/// The master side of a new PTY, and the path of the other side in `name`.
pub fn openMaster(name: *[128]u8) union(enum) { fd: i32, err: E } {
    const m = posix_openpt(@bitCast(c.O{ .ACCMODE = .RDWR, .NOCTTY = true }));
    if (m < 0) return .{ .err = errno() };
    const fail = struct {
        fn of(fd: c_int) E {
            const e = errno();
            _ = c.close(fd);
            return e;
        }
    }.of;
    if (c.fcntl(m, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return .{ .err = fail(m) };
    if (grantpt(m) != 0 or unlockpt(m) != 0) return .{ .err = fail(m) };
    @memset(name, 0);
    const rc = ptsname_r(m, name, name.len - 1);
    if (rc != 0) {
        _ = c.close(m);
        return .{ .err = @fromBackingInt(@intCast(rc)) };
    }
    return .{ .fd = m };
}

/// The other side of the PTY, with no controlling terminal and closed in
/// a child.
pub fn openOther(tty: [*:0]const u8) union(enum) { fd: i32, err: E } {
    const fd = c.open(tty, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
    if (fd < 0) return .{ .err = errno() };
    return .{ .fd = fd };
}

pub fn setSize(fd: i32, cols: u16, rows: u16) E {
    var ws: std.posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    if (c.ioctl(fd, tiocswinsz, @intFromPtr(&ws)) < 0) return errno();
    return .SUCCESS;
}

pub fn getSize(fd: i32, ws: *std.posix.winsize) E {
    if (c.ioctl(fd, tiocgwinsz, @intFromPtr(ws)) < 0) return errno();
    return .SUCCESS;
}

/// Starts `path` on the terminal `tty`. Gives the pid, or the error of
/// the start (an `execve` error comes back from `posix_spawn` on macOS).
pub fn start(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, tty: [*:0]const u8, cwd_fd: i32) union(enum) { pid: i32, err: E } {
    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return .{ .err = .NOMEM };
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    var attr: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attr) != 0) return .{ .err = .NOMEM };
    defer _ = c.posix_spawnattr_destroy(&attr);
    var rc = c.posix_spawn_file_actions_addopen(&actions, 0, tty, @bitCast(c.O{ .ACCMODE = .RDWR }), 0);
    if (rc == 0) rc = c.posix_spawn_file_actions_adddup2(&actions, 0, 1);
    if (rc == 0) rc = c.posix_spawn_file_actions_adddup2(&actions, 0, 2);
    if (rc == 0 and cwd_fd >= 0) rc = posix_spawn_file_actions_addfchdir_np(&actions, cwd_fd);
    if (rc == 0) rc = c.posix_spawnattr_setflags(&attr, @bitCast(spawn_setsid | spawn_cloexec_default));
    if (rc != 0) return .{ .err = @fromBackingInt(@intCast(rc)) };
    var pid: c.pid_t = 0;
    rc = c.posix_spawn(&pid, path, &actions, &attr, @ptrCast(argv), @ptrCast(envp));
    if (rc != 0) return .{ .err = @fromBackingInt(@intCast(rc)) };
    return .{ .pid = pid };
}

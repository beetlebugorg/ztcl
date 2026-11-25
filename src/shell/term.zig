//! The terminal of the line editor: raw mode, the window size, input
//! with a timeout, and the resize signal.
//!
//! On Linux and macOS, raw mode is termios with no echo, no canonical
//! input, no signals from keys, and no translation of CR, so the editor
//! sees each key. Output keeps its translation. `restore` puts back the
//! mode of the start, also before the shell runs a command or an editor.
//! SIGWINCH sets a flag, and the next read returns so the editor draws
//! again. The window size comes from TIOCGWINSZ.
//!
//! On Windows, raw mode turns off line input and echo on the console,
//! and turns on the virtual terminal input and output modes, so the
//! console gives the same key sequences and reads the same escape
//! sequences as a terminal of Unix. The size comes from the screen
//! buffer of the console, and the shell reads it again before each draw.
//! This part was written without a Windows machine and has no test.
//!
//! The terminal is interactive when standard input and standard output
//! are a terminal and TERM is not "dumb". Each other case gets plain
//! line input in the shell.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const is_win = builtin.os.tag == .windows;

pub const Term = struct {
    in_fd: posix.fd_t,
    out_fd: posix.fd_t,
    saved: if (is_win) [2]u32 else ?posix.termios = if (is_win) .{ 0, 0 } else null,
    raw_on: bool = false,

    pub fn init() Term {
        return .{ .in_fd = if (is_win) std.os.windows.peb().ProcessParameters.hStdInput else 0, .out_fd = if (is_win) std.os.windows.peb().ProcessParameters.hStdOutput else 1 };
    }

    pub fn enableRaw(t: *Term) bool {
        if (t.raw_on) return true;
        if (comptime is_win) {
            var in_mode: u32 = 0;
            var out_mode: u32 = 0;
            if (GetConsoleMode(t.in_fd, &in_mode) == 0 or GetConsoleMode(t.out_fd, &out_mode) == 0) return false;
            t.saved = .{ in_mode, out_mode };
            // No line input, no echo, no processed input; VT input.
            const in_raw = (in_mode & ~@as(u32, 0x0002 | 0x0004 | 0x0001)) | 0x0200;
            // VT processing and no auto return.
            const out_raw = out_mode | 0x0004 | 0x0001;
            if (SetConsoleMode(t.in_fd, in_raw) == 0) return false;
            _ = SetConsoleMode(t.out_fd, out_raw);
            t.raw_on = true;
            return true;
        }
        const old = posix.tcgetattr(t.in_fd) catch return false;
        t.saved = old;
        var raw = old;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        posix.tcsetattr(t.in_fd, .FLUSH, raw) catch return false;
        t.raw_on = true;
        return true;
    }

    pub fn restore(t: *Term) void {
        if (!t.raw_on) return;
        t.raw_on = false;
        if (comptime is_win) {
            _ = SetConsoleMode(t.in_fd, t.saved[0]);
            _ = SetConsoleMode(t.out_fd, t.saved[1]);
            return;
        }
        if (t.saved) |s| posix.tcsetattr(t.in_fd, .FLUSH, s) catch {};
    }

    /// The width and the height of the window, or 80 by 24.
    pub fn size(t: *const Term) struct { cols: usize, rows: usize } {
        if (comptime is_win) {
            var info: ConsoleInfo = undefined;
            if (GetConsoleScreenBufferInfo(t.out_fd, &info) == 0) return .{ .cols = 80, .rows = 24 };
            return .{ .cols = @intCast(@max(1, info.window[2] - info.window[0] + 1)), .rows = @intCast(@max(1, info.window[3] - info.window[1] + 1)) };
        }
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(t.out_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (posix.errno(rc) != .SUCCESS or ws.col == 0) return .{ .cols = 80, .rows = 24 };
        return .{ .cols = ws.col, .rows = ws.row };
    }

    /// Reads input. Waits at most `timeout_ms` (-1: no limit). Gives 0
    /// bytes at the end of the time or after a resize, and null at the
    /// end of the input.
    pub fn read(t: *Term, buf: []u8, timeout_ms: i32) ?usize {
        if (comptime is_win) {
            if (timeout_ms >= 0 and WaitForSingleObject(t.in_fd, @intCast(timeout_ms)) != 0) return 0;
            var n: u32 = 0;
            if (ReadFile(t.in_fd, buf.ptr, @intCast(buf.len), &n, null) == 0) return null;
            if (n == 0) return null;
            return n;
        }
        var fds = [1]posix.pollfd{.{ .fd = t.in_fd, .events = posix.POLL.IN, .revents = 0 }};
        const r = posix.poll(&fds, timeout_ms) catch |err| switch (err) {
            else => return 0,
        };
        if (r == 0) return 0;
        const n = posix.read(t.in_fd, buf) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return null,
        };
        if (n == 0) return null;
        return n;
    }

    pub fn write(t: *Term, bytes: []const u8) void {
        var at: usize = 0;
        while (at < bytes.len) {
            if (comptime is_win) {
                var n: u32 = 0;
                if (WriteFile(t.out_fd, bytes[at..].ptr, @intCast(bytes.len - at), &n, null) == 0) return;
                at += n;
                continue;
            }
            const rc = posix.system.write(t.out_fd, bytes[at..].ptr, bytes.len - at);
            switch (posix.errno(rc)) {
                .SUCCESS => at += @intCast(rc),
                .INTR, .AGAIN => continue,
                else => return,
            }
        }
    }
};

/// Set by SIGWINCH. The shell reads and clears it.
pub var resized = std.atomic.Value(bool).init(false);

fn onWinch(_: posix.SIG) callconv(.c) void {
    resized.store(true, .release);
}

/// Installs the handler of SIGWINCH, with no SA_RESTART, so a wait for
/// input ends at a resize.
pub fn watchResize() void {
    if (comptime is_win) return;
    const act: posix.Sigaction = .{ .handler = .{ .handler = onWinch }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.WINCH, &act, null);
}

/// True when the shell can use the line editor.
pub fn interactive(io: std.Io, env_term: ?[]const u8) bool {
    if (env_term) |v| {
        if (std.mem.eql(u8, v, "dumb")) return false;
    }
    if (comptime is_win) {
        var m: u32 = 0;
        const t = Term.init();
        return GetConsoleMode(t.in_fd, &m) != 0 and GetConsoleMode(t.out_fd, &m) != 0;
    }
    const in_tty = std.Io.File.stdin().isTty(io) catch false;
    const out_tty = std.Io.File.stdout().isTty(io) catch false;
    return in_tty and out_tty;
}

// ---- kernel32 ----

const HANDLE = if (is_win) std.os.windows.HANDLE else *anyopaque;
const ConsoleInfo = extern struct { size: [2]i16, cursor: [2]i16, attr: u16, window: [4]i16, max: [2]i16 };
extern "kernel32" fn GetConsoleMode(h: HANDLE, mode: *u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleMode(h: HANDLE, mode: u32) callconv(.winapi) i32;
extern "kernel32" fn GetConsoleScreenBufferInfo(h: HANDLE, info: *ConsoleInfo) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, got: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, put: *u32, ov: ?*anyopaque) callconv(.winapi) i32;

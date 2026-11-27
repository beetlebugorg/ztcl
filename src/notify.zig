//! The optional `ztcl::notify` command (capability `notify`): a
//! notification of the system with a title, and an optional subtitle and
//! body (ztk#53, ztcl#108).
//!
//!   ztcl::notify title ?-subtitle text? ?-body text?
//!
//! An embedder can give `Interp.notify_host`, which gets each
//! notification in place of the system: a ztk app in an app bundle uses
//! `UNUserNotificationCenter` there, and the tests record the calls.
//! With no host, macOS runs `osascript` with `display notification`. The
//! texts go to the script as its arguments (`on run argv`), so no text
//! of the caller is AppleScript code. Windows shows a toast of the
//! notification center (`notify_windows.zig`). Linux has no backend yet:
//! with no host, the command gives the error `ZTCL NOTIFY UNAVAILABLE`.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const on_mac = builtin.os.tag == .macos;
const on_win = builtin.os.tag == .windows;
/// The toasts of Windows.
pub const win = if (on_win) @import("notify_windows.zig") else struct {};

/// One notification. The texts are UTF-8 and valid during the call.
pub const Note = struct {
    title: []const u8,
    subtitle: []const u8 = "",
    body: []const u8 = "",
};

/// The callback of an embedder. It shows the notification and gives
/// false on a failure.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    show: *const fn (ctx: ?*anyopaque, note: *const Note) bool,
};

/// The longest title and subtitle, and the longest body, in bytes.
pub const max_title = 256;
pub const max_body = 4096;

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("ztcl::notify", cmdNotify);
}

fn checkText(it: *Interp, what: []const u8, t: []const u8, max: usize) Error!void {
    if (t.len > max) return it.failCode("ZTCL NOTIFY LENGTH", "the {s} of a notification has more than {d} bytes", .{ what, max });
    if (std.mem.indexOfScalar(u8, t, 0) != null) return it.failCode("ZTCL NOTIFY TEXT", "the {s} of a notification has a NUL byte", .{what});
    if (!std.unicode.utf8ValidateSlice(t)) return it.failCode("ZTCL NOTIFY TEXT", "the {s} of a notification is not UTF-8", .{what});
}

fn cmdNotify(it: *Interp, args: []const Value, _: ?*interp.Cmd) Error!Value {
    const usage = "ztcl::notify title ?-subtitle text? ?-body text?";
    if (args.len < 2 or args.len % 2 != 0) return it.wrongArgs(usage);
    var note: Note = .{ .title = try it.str(args[1]) };
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        const opt = try it.str(args[i]);
        const v = try it.str(args[i + 1]);
        if (std.mem.eql(u8, opt, "-subtitle")) {
            note.subtitle = v;
        } else if (std.mem.eql(u8, opt, "-body")) {
            note.body = v;
        } else return it.fail("bad option \"{s}\": must be -body or -subtitle", .{opt});
    }
    if (note.title.len == 0) return it.failCode("ZTCL NOTIFY TEXT", "a notification needs a title", .{});
    try checkText(it, "title", note.title, max_title);
    try checkText(it, "subtitle", note.subtitle, max_title);
    try checkText(it, "body", note.body, max_body);
    if (it.notify_host) |h| {
        if (!h.show(h.ctx, &note)) return failed(it);
        return .{ .str = "" };
    }
    if (comptime on_win) {
        if (!win.show(it.alloc(), &note)) return failed(it);
        return .{ .str = "" };
    }
    if (comptime !on_mac) return unavailable(it);
    if (!(try mac.show(it.alloc(), &note))) return failed(it);
    return .{ .str = "" };
}

fn failed(it: *Interp) Error {
    return it.failCode("ZTCL NOTIFY FAILED", "the system did not show the notification", .{});
}

fn unavailable(it: *Interp) Error {
    const name = switch (builtin.os.tag) {
        .linux => "Linux",
        .windows => "Windows",
        else => "this platform",
    };
    return it.failCode("ZTCL NOTIFY UNAVAILABLE", "ztcl::notify is not available on {s} yet", .{name});
}

/// The script of `osascript`. Its arguments are the title, the body, and
/// the subtitle, in that order.
pub const script = [_][]const u8{
    "on run argv",
    "display notification (item 2 of argv) with title (item 1 of argv) subtitle (item 3 of argv)",
    "end run",
};

/// The arguments of `osascript` for a notification: each line of the
/// script after `-e`, then the texts.
pub fn osascriptArgs(a: std.mem.Allocator, note: *const Note) ![:null]?[*:0]const u8 {
    const out = try a.allocSentinel(?[*:0]const u8, 1 + 2 * script.len + 3, null);
    out[0] = "/usr/bin/osascript";
    for (script, 0..) |line, k| {
        out[1 + 2 * k] = "-e";
        out[2 + 2 * k] = (try a.dupeSentinel(u8, line, 0)).ptr;
    }
    const base = 1 + 2 * script.len;
    out[base] = (try a.dupeSentinel(u8, note.title, 0)).ptr;
    out[base + 1] = (try a.dupeSentinel(u8, note.body, 0)).ptr;
    out[base + 2] = (try a.dupeSentinel(u8, note.subtitle, 0)).ptr;
    return out;
}

pub const mac = if (on_mac) struct {
    const c = std.c;

    /// Runs `osascript` and gives true for an exit status of 0. `a` is
    /// an arena of the call.
    pub fn show(a: std.mem.Allocator, note: *const Note) !bool {
        const argv = try osascriptArgs(a, note);
        const envp = [_:null]?[*:0]const u8{};
        var actions: c.posix_spawn_file_actions_t = undefined;
        if (c.posix_spawn_file_actions_init(&actions) != 0) return false;
        defer _ = c.posix_spawn_file_actions_destroy(&actions);
        const null_flags: c_int = @bitCast(c.O{ .ACCMODE = .RDWR });
        for ([_]c_int{ 0, 1, 2 }) |fd| {
            if (c.posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", null_flags, 0) != 0) return false;
        }
        var pid: c.pid_t = 0;
        if (c.posix_spawn(&pid, "/usr/bin/osascript", &actions, null, @ptrCast(argv.ptr), @ptrCast(&envp)) != 0) return false;
        var status: c_int = 0;
        while (c.waitpid(pid, &status, 0) < 0) {
            if (@as(c.E, @fromBackingInt(@intCast(c._errno().*))) != .INTR) return false;
        }
        return status == 0;
    }
} else struct {};

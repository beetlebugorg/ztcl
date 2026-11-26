//! Tests of `ztcl::pty` (`pty.zig`). The programs are small programs of
//! the system: `sh`, `stty`, `cat`, and `sleep`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const tcl = @import("ztcl.zig");
const cap = tcl.interp.Capability;

fn now(_: ?*anyopaque) i64 {
    return tcl.proc.nowMs() * 1000;
}

fn sleep(_: ?*anyopaque, micros: i64) void {
    tcl.proc.sleepMs(@intCast(@max(1, @divFloor(micros, 1000))));
}

fn ptyInterp(it: *tcl.Interp) !void {
    try it.init(std.testing.allocator);
    errdefer it.deinit();
    try it.allow(@backingInt(cap.channels) | @backingInt(cap.event) | @backingInt(cap.exec));
    it.event_host = .{ .now = now, .sleep = sleep };
    it.exec_host = .{ .allow = &.{ "sh", "cat" }, .timeout_ms = 0, .env = &.{"PATH=/usr/bin:/bin"} };
}

/// Reads the channel `$t` until the text has `want`, or 3 s pass.
const read_until =
    \\proc readUntil {t want} {
    \\    fconfigure $t -blocking 0
    \\    set ::got ""
    \\    set ::done 0
    \\    fileevent $t readable [list apply {{t want} {
    \\        append ::got [read $t]
    \\        if {[string first $want $::got] >= 0 || [eof $t]} {set ::done 1}
    \\    }} $t $want]
    \\    set id [after 3000 {set ::done 2}]
    \\    vwait ::done
    \\    after cancel $id
    \\    fileevent $t readable {}
    \\    return $::got
    \\}
;

/// Runs a script and prints the error text of Tcl when it fails.
fn ev(it: *tcl.Interp, script: []const u8) ![]const u8 {
    const v = it.eval(script) catch |e| {
        std.debug.print("error in {s}: {s}\n", .{ script, it.str(it.result) catch "" });
        return e;
    };
    return it.str(v);
}

fn has(it: *tcl.Interp, script: []const u8, want: []const u8) !void {
    const got = try ev(it, script);
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("want {s} in: {s}\n", .{ want, got });
        return error.TestExpectedEqual;
    }
}

test "ztcl::pty is absent without exec" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(cap.channels) | @backingInt(cap.file) | @backingInt(cap.event) | @backingInt(cap.interp));
    try std.testing.expect(it.findCommand("ztcl::pty") == null);
    try std.testing.expectEqualStrings("{}", try (ev(&it, "interp create c; list [c eval {info commands ztcl::pty}]")));
}

test "ztcl::pty gives an error on a platform with no pty yet" {
    if (tcl.pty.supported or !tcl.proc.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try ptyInterp(&it);
    defer it.deinit();
    try std.testing.expectEqualStrings("1 {ZTCL PTY UNAVAILABLE}", try (ev(&it, "list [catch {ztcl::pty spawn sh}] $::errorCode")));
}

test "ztcl::pty runs a program on a terminal" {
    if (!tcl.pty.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try ptyInterp(&it);
    defer it.deinit();
    _ = try ev(&it, read_until);
    try has(&it, "set t [ztcl::pty spawn sh -c {tty; echo END}]; readUntil $t END", if (builtin.os.tag == .macos) "/dev/ttys" else "/dev/pts/");
    _ = try ev(&it, "close $t");
    // The size of -size, and then the size of resize.
    try has(&it, "set t [ztcl::pty spawn -size {100 40} sh -c {stty size; read x; stty size; echo END}]; readUntil $t {40 100}", "40 100");
    try std.testing.expectEqualStrings("100 40", try (ev(&it, "ztcl::pty size $t")));
    try has(&it, "ztcl::pty resize $t 120 50; puts -nonewline $t \"\\n\"; flush $t; readUntil $t END", "50 120");
    try std.testing.expectEqualStrings("exit 0", try (ev(&it, "after 200; ztcl::pty status $t")));
    _ = try ev(&it, "close $t");
    // A write goes to the program, and the echo of the terminal comes back.
    try has(&it, "set t [ztcl::pty spawn cat]; puts $t hello; flush $t; readUntil $t hello", "hello");
    try std.testing.expectEqualStrings("running", try (ev(&it, "ztcl::pty status $t")));
    _ = try ev(&it, "close $t");
    // TERM is set, and -env adds a name.
    try has(&it, "set t [ztcl::pty spawn -env {GREETING hi} sh -c {echo $TERM-$GREETING}]; readUntil $t hi", "xterm-256color-hi");
    _ = try ev(&it, "close $t");
}

test "ztcl::pty gives the exit status" {
    if (!tcl.pty.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try ptyInterp(&it);
    defer it.deinit();
    _ = try ev(&it, read_until);
    // A read at the end gives the end of the file.
    try std.testing.expectEqualStrings("1", try (ev(&it, "set t [ztcl::pty spawn sh -c {exit 3}]; readUntil $t never; eof $t")));
    try std.testing.expectEqualStrings("exit 3", try (ev(&it, "after 100; ztcl::pty status $t")));
    _ = try ev(&it, "close $t");
    try std.testing.expectEqualStrings("signal KILL", try (ev(&it, "set t [ztcl::pty spawn cat]; ztcl::pty kill $t KILL; after 100; ztcl::pty status $t")));
    _ = try ev(&it, "close $t");
}

test "ztcl::pty close ends a program that ignores SIGHUP" {
    if (!tcl.pty.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const linux = tcl.sys.os;
    var it: tcl.Interp = undefined;
    try ptyInterp(&it);
    defer it.deinit();
    _ = try ev(&it, read_until);
    const pid = try std.fmt.parseInt(i32, try (ev(&it, "set t [ztcl::pty spawn sh -c {trap {} HUP; echo READY; while :; do :; done}]; readUntil $t READY; pid $t")), 10);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.kill(pid, @fromBackingInt(@intCast(0)))));
    const t0 = tcl.proc.nowMs();
    _ = try ev(&it, "close $t");
    try std.testing.expect(tcl.proc.nowMs() - t0 < 2000);
    try std.testing.expectEqual(linux.E.SRCH, linux.errno(linux.kill(pid, @fromBackingInt(@intCast(0)))));
}

test "ztcl::pty checks the program list of exec" {
    if (!tcl.pty.supported or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try ptyInterp(&it);
    defer it.deinit();
    try std.testing.expectEqualStrings("1 {couldn't execute \"ls\": the embedder does not allow this program}", try (ev(&it, "list [catch {ztcl::pty spawn ls} m] $m")));
    it.exec_host.allow = null;
    try std.testing.expectEqualStrings("1", try (ev(&it, "catch {ztcl::pty spawn /no/such}")));
}

//! Tests of `ztcl::pty` on Windows (`pty_windows.zig`): `cmd.exe` on a
//! pseudo console. A pseudo console has no window, so no test opens one.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const tcl = @import("ztcl.zig");
const pw = @import("proc_windows.zig");
const t = std.testing;

const on = builtin.os.tag == .windows and pw.supported;
const env = [_][:0]const u8{ "PATH=C:\\Windows\\System32", "SystemRoot=C:\\Windows" };

fn setup(it: *tcl.Interp) !void {
    try it.init(t.allocator);
    it.exec_host = .{ .env = &env };
    try it.allow(@backingInt(tcl.interp.Capability.exec) | @backingInt(tcl.interp.Capability.channels));
}

fn ev(it: *tcl.Interp, s: []const u8) ![]const u8 {
    return it.str(try it.eval(s));
}

/// Reads the channel `t` into `::out` until it has `want`, or 5 s pass.
fn readUntil(it: *tcl.Interp, want: []const u8) !bool {
    const script = try std.fmt.allocPrint(t.allocator, "append ::out [read $::t]; string first {{{s}}} $::out", .{want});
    defer t.allocator.free(script);
    const t0 = pw.nowMs();
    while (pw.nowMs() - t0 < 5000) {
        if (!std.mem.eql(u8, try ev(it, script), "-1")) return true;
        pw.sleepMs(10);
    }
    return false;
}

/// Waits 5 s at most for the program of `::t` to end.
fn waitEnd(it: *tcl.Interp) ![]const u8 {
    const t0 = pw.nowMs();
    while (pw.nowMs() - t0 < 5000) {
        const s = try ev(it, "read $::t; ztcl::pty status $::t");
        if (!std.mem.eql(u8, s, "running")) return s;
        pw.sleepMs(10);
    }
    return "running";
}

test "pty on Windows: a shell gets its input and gives its output, size, and status" {
    if (!on) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try setup(&it);
    defer it.deinit();
    _ = try ev(&it, "set ::t [ztcl::pty spawn -size {100 30} cmd.exe]; set ::out {}; fconfigure $::t -blocking 0");
    try t.expectEqualStrings("100 30", try ev(&it, "ztcl::pty size $::t"));
    try t.expectEqualStrings("running", try ev(&it, "ztcl::pty status $::t"));
    _ = try ev(&it, "puts -nonewline $::t \"echo pty-hello\\r\"; flush $::t");
    try t.expect(try readUntil(&it, "pty-hello\r\n"));
    _ = try ev(&it, "ztcl::pty resize $::t 120 40");
    try t.expectEqualStrings("120 40", try ev(&it, "ztcl::pty size $::t"));
    _ = try ev(&it, "puts -nonewline $::t \"exit 4\\r\"; flush $::t");
    try t.expectEqualStrings("exit 4", try waitEnd(&it));
    _ = try ev(&it, "close $::t");
}

test "pty on Windows: kill ends the job, and close ends a program that runs" {
    if (!on) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try setup(&it);
    defer it.deinit();
    // cmd.exe runs ping.exe, and the kill of the job ends both.
    _ = try ev(&it, "set ::t [ztcl::pty spawn cmd.exe /c ping -n 30 127.0.0.1]; fconfigure $::t -blocking 0");
    _ = try ev(&it, "ztcl::pty kill $::t KILL");
    try t.expectEqualStrings("signal KILL", try waitEnd(&it));
    _ = try ev(&it, "close $::t");
    _ = try ev(&it, "set ::t [ztcl::pty spawn cmd.exe /c ping -n 30 127.0.0.1]");
    const t0 = pw.nowMs();
    _ = try ev(&it, "close $::t");
    try t.expect(pw.nowMs() - t0 < 2000);
    // The errors of the arguments.
    try t.expectEqualStrings("bad signal \"BOOM\": must be HUP, INT, QUIT, KILL, TERM, CONT, STOP, WINCH, or a number", try ev(&it, "set ::t [ztcl::pty spawn cmd.exe]; catch {ztcl::pty kill $::t BOOM} m; close $::t; set m"));
    try t.expectEqualStrings("ZTCL EXEC DENIED", try ev(&it, "catch {ztcl::pty spawn relative/cmd.exe}; set ::errorCode"));
}

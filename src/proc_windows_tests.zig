//! Tests of `exec`, `pid`, and pipeline channels on Windows
//! (`proc_windows.zig`). The programs are `cmd.exe`, `findstr.exe`,
//! `whoami.exe`, and `ping.exe` of the system folder, and no test opens
//! a window or a network connection to another machine.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const tcl = @import("ztcl.zig");
const pw = @import("proc_windows.zig");
const t = std.testing;

const on = builtin.os.tag == .windows and pw.supported;
const env = [_][:0]const u8{ "PATH=C:\\Windows\\System32", "SystemRoot=C:\\Windows" };

fn setup(it: *tcl.Interp, allow: ?[]const []const u8) !void {
    try it.init(t.allocator);
    it.exec_host = .{ .env = &env, .allow = allow };
    try it.allow(@backingInt(tcl.interp.Capability.exec) | @backingInt(tcl.interp.Capability.channels));
}

fn ev(it: *tcl.Interp, s: []const u8) ![]const u8 {
    return it.str(try it.eval(s));
}

extern "shell32" fn CommandLineToArgvW(line: [*:0]const u16, n: *c_int) callconv(.winapi) ?[*][*:0]u16;
extern "kernel32" fn LocalFree(p: ?*anyopaque) callconv(.winapi) ?*anyopaque;

test "exec on Windows: the command line gives each argument back to CommandLineToArgvW" {
    if (!on) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const words = [_][]const u8{ "C:\\Program Files\\x.exe", "plain", "two words", "", "say \"hi\"", "end\\", "dir with\\", "a\\\\\"b", "tab\there" };
    const line = try pw.commandLine(a, &words);
    const w = try std.unicode.utf8ToUtf16LeAllocZ(a, line);
    var n: c_int = 0;
    const argv = CommandLineToArgvW(w.ptr, &n) orelse return error.NoArgv;
    defer _ = LocalFree(@ptrCast(argv));
    try t.expectEqual(@as(c_int, words.len), n);
    for (words, 0..) |want, i| {
        const got = try std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(argv[i]));
        try t.expectEqualStrings(want, got);
    }
}

test "exec on Windows: programs, a pipeline, redirections, and the status" {
    if (!on) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try setup(&it, null);
    defer it.deinit();
    try t.expectEqualStrings("hello", try ev(&it, "exec cmd.exe /c echo hello"));
    // A pipeline, and the text of << for the first program.
    try t.expectEqualStrings("a b", try ev(&it, "exec cmd.exe /c {echo a b} | findstr a"));
    try t.expectEqualStrings("two", try ev(&it, "exec findstr w << \"one\\ntwo\\n\""));
    // The status and the error output.
    try t.expectEqualStrings("1 CHILDSTATUS", try ev(&it, "list [catch {exec cmd.exe /c exit 3}] [lindex $::errorCode 0]"));
    try t.expectEqualStrings("3", try ev(&it, "lindex $::errorCode 2"));
    try t.expectEqualStrings("1 oops", try ev(&it, "list [catch {exec cmd.exe /c {echo oops 1>&2}} m] [string trim $m]"));
    try t.expectEqualStrings("0 oops", try ev(&it, "list [catch {exec cmd.exe /c {echo oops 1>&2} 2>@1} m] [string trim $m]"));
    try t.expectEqualStrings("0", try ev(&it, "catch {exec -ignorestderr cmd.exe /c {echo oops 1>&2}}"));
    // A background program gives its pid, and pid gives this process.
    try t.expectEqualStrings("1 1", try ev(&it, "list [llength [exec cmd.exe /c exit 0 &]] [string is integer [pid]]"));
    // A program that does not exist.
    try t.expectEqualStrings("ENOENT", try ev(&it, "catch {exec nosuchprogram}; lindex $::errorCode 1"));
}

test "exec on Windows: the allowlist, batch files, and the PATH" {
    if (!on) return error.SkipZigTest;
    const allow = [_][]const u8{ "whoami", "C:/Windows/System32/cmd.exe" };
    var it: tcl.Interp = undefined;
    try setup(&it, &allow);
    defer it.deinit();
    try t.expect((try ev(&it, "exec whoami")).len > 0);
    // A full path of the list matches the bare name of the same file.
    try t.expectEqualStrings("hi", try ev(&it, "exec C:/Windows/System32/cmd.exe /c echo hi"));
    try t.expectEqualStrings("ZTCL EXEC DENIED", try ev(&it, "catch {exec findstr x << x}; set ::errorCode"));
    try t.expectEqualStrings("ZTCL EXEC DENIED", try ev(&it, "catch {exec relative/cmd.exe}; set ::errorCode"));
    it.exec_host.allow = null;
    // A batch file is refused before any process starts.
    const dir = ".zig-cache/ztcl-exec-test";
    std.Io.Dir.cwd().createDirPath(t.io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = dir ++ "/x.bat", .data = "@echo hi\r\n" });
    defer std.Io.Dir.cwd().deleteTree(t.io, dir) catch {};
    const full = try std.process.currentPathAlloc(t.io, t.allocator);
    defer t.allocator.free(full);
    const script = try std.fmt.allocPrint(t.allocator, "catch {{exec {{{s}/{s}/x.bat}}}} m; list $::errorCode $m", .{ full, dir });
    defer t.allocator.free(script);
    const got = try ev(&it, script);
    try t.expect(std.mem.startsWith(u8, got, "{ZTCL EXEC DENIED}"));
    try t.expect(std.mem.indexOf(u8, got, "cmd.exe") != null);
    // A relative entry of PATH is an error.
    const bad = [_][:0]const u8{"PATH=bin;C:\\Windows\\System32"};
    it.exec_host.env = &bad;
    try t.expectEqualStrings("ZTCL EXEC PATH", try ev(&it, "catch {exec whoami}; set ::errorCode"));
}

test "exec on Windows: the time limit ends the job with each process in it" {
    if (!on) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try setup(&it, null);
    defer it.deinit();
    it.exec_host.timeout_ms = 500;
    const t0 = pw.nowMs();
    // cmd.exe starts ping.exe, and the kill of the job ends both.
    try t.expectEqualStrings("1 CHILDKILLED SIGKILL", try ev(&it, "list [catch {exec cmd.exe /c ping -n 30 127.0.0.1}] [lindex $::errorCode 0] [lindex $::errorCode 2]"));
    try t.expect(pw.nowMs() - t0 < 10_000);
    try t.expectEqual(@as(usize, 0), it.execs.groups.items.len);
}

test "exec on Windows: a pipeline channel reads the output and gives the status at close" {
    if (!on) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try setup(&it, null);
    defer it.deinit();
    try t.expectEqualStrings("first second 1", try ev(&it,
        \\set f [open "|cmd.exe /c {echo first& echo second}" r]
        \\set a [string trim [gets $f]]
        \\set b [string trim [gets $f]]
        \\set n [llength [pid $f]]
        \\close $f
        \\list $a $b $n
    ));
    try t.expectEqualStrings("1 CHILDSTATUS", try ev(&it, "set f [open {|cmd.exe /c exit 2} r]; read $f; list [catch {close $f}] [lindex $::errorCode 0]"));
}

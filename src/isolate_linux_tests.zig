//! Tests of the sandbox of the `process` level on Linux
//! (`isolate_linux.zig`). The tests of the sandbox itself run a function
//! of this file in the child in place of the runner. The tests of
//! `thread::create -isolation process` start the ztcl runner of
//! `zig-out/bin/ztcl` (or `ZTCL_RUNNER`), and skip when it is not built.
//! A kernel or a system with no unprivileged user namespace, no
//! delegated cgroup, or no Landlock skips each test with the name of the
//! missing feature. The files of a test are in `.zig-cache`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const tcl = @import("ztcl.zig");
const iso = @import("isolate_linux.zig");
const linux = std.os.linux;
const t = std.testing;

const on = builtin.os.tag == .linux and iso.supported;

fn ev(it: *tcl.Interp, s: []const u8) ![]const u8 {
    const v = it.eval(s) catch |e| {
        if (e == error.TclError) std.debug.print("tcl error: {s}\n", .{it.str(it.result) catch ""});
        return e;
    };
    return it.str(v);
}

/// An interpreter with the files of the host, for the files of a test.
fn hostInterp(it: *tcl.Interp) !void {
    try it.init(t.allocator);
    try it.allow(@backingInt(tcl.interp.Capability.channels) | @backingInt(tcl.interp.Capability.file));
    try tcl.fsroot.setHost(it);
}

/// `iso.spawn`, or a skip that names the missing feature.
fn start(s: iso.Spawn) !iso.Child {
    return iso.spawn(t.allocator, "/proc/self/exe", s) catch |e| {
        if (e == error.OutOfMemory or e == error.SpawnFailed) return e;
        std.debug.print("skip: {s} (step {d}, errno {d})\n", .{ iso.message(e), iso.last_step, iso.last_errno });
        return skip();
    };
}

/// A skip, or a failure when `ZTCL_TEST_ISO_LINUX=1` is in the
/// environment: CI sets it after it allows each feature.
fn skip() error{ SkipZigTest, TestUnexpectedResult } {
    var buf: [65536]u8 = undefined;
    const fd = linux.syscall4(.openat, @bitCast(@as(isize, linux.AT.FDCWD)), @intFromPtr("/proc/self/environ"), 0o2000000, 0);
    if (linux.errno(fd) != .SUCCESS) return error.SkipZigTest;
    defer _ = linux.close(@intCast(fd));
    const n = linux.read(@intCast(fd), &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return error.SkipZigTest;
    var it = std.mem.splitScalar(u8, buf[0..n], 0);
    while (it.next()) |e| if (std.mem.eql(u8, e, "ZTCL_TEST_ISO_LINUX=1")) return error.TestUnexpectedResult;
    return error.SkipZigTest;
}

// The state of a child function: the child gets a copy of this memory.
var root_buf: [1024]u8 = undefined;
var root_len: usize = 0;
var root_z: [:0]const u8 = "";

fn rootPath() []const u8 {
    return root_buf[0..root_len];
}

fn openR(path: [*:0]const u8) bool {
    const r = linux.syscall4(.openat, @bitCast(@as(isize, linux.AT.FDCWD)), @intFromPtr(path), 0o2000000, 0);
    if (linux.errno(r) != .SUCCESS) return false;
    _ = linux.close(@intCast(r));
    return true;
}

/// Each check of the sandbox has its own exit code.
fn jailedChild() u8 {
    iso.enter(.{ .root = rootPath() }) catch return 10;
    var pb: [1100]u8 = undefined;
    const inside = std.fmt.bufPrintSentinel(&pb, "{s}/in.txt", .{rootPath()}, 0) catch return 11;
    const fd = linux.syscall4(.openat, @bitCast(@as(isize, linux.AT.FDCWD)), @intFromPtr(inside.ptr), 0o2000000 | 0o100 | 2, 0o600);
    if (linux.errno(fd) != .SUCCESS) return 12;
    _ = linux.write(@intCast(fd), "made", 4);
    var ob: [1100]u8 = undefined;
    const outside = std.fmt.bufPrintSentinel(&ob, "{s}/../outside/secret.txt", .{rootPath()}, 0) catch return 13;
    if (openR(outside.ptr)) return 14;
    if (openR("/etc/passwd")) return 15;
    // No socket without the capability.
    if (linux.errno(linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0)) == .SUCCESS) return 16;
    if (linux.errno(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0)) == .SUCCESS) return 17;
    // No program.
    const argv = [_:null]?[*:0]const u8{"/bin/true"};
    const envp = [_:null]?[*:0]const u8{};
    if (linux.errno(linux.execve("/bin/true", &argv, &envp)) == .SUCCESS) return 18;
    // No process but this one.
    if (linux.getpid() != 1) return 19;
    return 0;
}

/// Counts the processes in `/proc` before `enter`, and checks that the
/// child is the only one.
fn pidChild() u8 {
    if (linux.getpid() != 1) return 20;
    const fd = linux.syscall4(.openat, @bitCast(@as(isize, linux.AT.FDCWD)), @intFromPtr("/proc"), 0o2000000 | 0o200000, 0);
    if (linux.errno(fd) != .SUCCESS) return 21;
    var buf: [8192]u8 align(8) = undefined;
    var procs: u32 = 0;
    while (true) {
        const n = linux.getdents64(@intCast(fd), &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return 22;
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf[off + 19])), 0);
            if (name.len > 0 and std.ascii.isDigit(name[0])) procs += 1;
            off += reclen;
        }
    }
    return if (procs == 1) 0 else 23;
}

fn hogChild() u8 {
    iso.enter(.{}) catch return 30;
    const size: usize = 256 << 20;
    const r = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(r) != .SUCCESS) return 31;
    const p: [*]u8 = @ptrFromInt(r);
    var i: usize = 0;
    while (i < size) : (i += 4096) p[i] = 1;
    return 32;
}

fn sleepChild() u8 {
    var none: [1]linux.pollfd = undefined;
    const r = linux.poll(&none, 0, 60_000);
    return 40 + @as(u8, @truncate(@backingInt(linux.errno(r))));
}

/// Makes a root folder and a folder next to it with a secret file.
fn makeRoot(it: *tcl.Interp, name: []const u8) !void {
    const p = try ev(it, try std.fmt.allocPrint(it.alloc(),
        \\set base [file normalize .zig-cache/ztcl-iso-test/{s}]
        \\file delete -force $base
        \\file mkdir $base/root $base/outside
        \\set fh [open $base/outside/secret.txt w]; puts -nonewline $fh secret; close $fh
        \\string cat $base/root
    , .{name}));
    @memcpy(root_buf[0..p.len], p);
    root_len = p.len;
}

test "isolate on Linux: the child reaches its root folder only, opens no socket, and starts no program" {
    if (!on) return error.SkipZigTest;
    var h: tcl.Interp = undefined;
    try hostInterp(&h);
    defer h.deinit();
    try makeRoot(&h, "jail");
    var c = try start(.{ .root = rootPath(), .entry = jailedChild });
    defer c.deinit();
    const s = c.wait(10_000) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(u32, 0), s.code);
    try t.expectEqualStrings("made", try ev(&h, "set fh [open $base/root/in.txt]; set d [read $fh]; close $fh; set d"));
}

test "isolate on Linux: the child sees no other process" {
    if (!on) return error.SkipZigTest;
    var c = try start(.{ .entry = pidChild });
    defer c.deinit();
    const s = c.wait(10_000) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(u32, 0), s.code);
}

test "isolate on Linux: memory.max ends the child" {
    if (!on) return error.SkipZigTest;
    var c = try start(.{ .entry = hogChild, .limits = .{ .mem_bytes = 32 << 20 } });
    defer c.deinit();
    const s = c.wait(20_000) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(u32, 137), s.code);
    try t.expect(c.usage().oom_kills >= 1);
}

test "isolate on Linux: kill ends the child with the code 137, and the group counts its CPU time" {
    if (!on) return error.SkipZigTest;
    var c = try start(.{ .entry = sleepChild });
    defer c.deinit();
    if (c.wait(50)) |early| std.debug.print("early end: {d}\n", .{early.code});
    try t.expect(c.status == null);
    c.kill();
    const s = c.wait(5000) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(u32, 137), s.code);
    try t.expect(s.killed);
    try t.expect(c.usage().cpu_ns > 0);
}

/// The full path of the runner, or null when it is not built.
fn runner(it: *tcl.Interp) !?[]const u8 {
    const v = try ev(it, "expr {[info exists ::env(ZTCL_RUNNER)] ? $::env(ZTCL_RUNNER) : [file normalize zig-out/bin/ztcl]}");
    if (!std.mem.eql(u8, try ev(it, try std.fmt.allocPrint(it.alloc(), "file exists {{{s}}}", .{v})), "1")) return null;
    return try it.alloc().dupe(u8, v);
}

/// An error of a missing feature of the kernel skips the test.
fn skipLevel(it: *tcl.Interp, script: []const u8) !void {
    if (it.eval(script)) |_| {} else |e| {
        if (e == error.TclError and std.mem.eql(u8, try ev(it, "set ::errorCode"), "ZTCL ISOLATION LEVEL")) {
            std.debug.print("skip: {s}\n", .{it.str(it.result) catch ""});
            return skip();
        }
        if (e == error.TclError) std.debug.print("tcl error: {s}\n", .{it.str(it.result) catch ""});
        return e;
    }
}

test "isolate on Linux: thread::create -isolation process: send, async, errors, cancel, exit, and join" {
    if (!on or comptime !tcl.isothread.supported) return error.SkipZigTest;
    var h: tcl.Interp = undefined;
    try hostInterp(&h);
    defer h.deinit();
    const exe = (try runner(&h)) orelse return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(t.allocator);
    defer it.deinit();
    it.iso_runner = exe;
    try it.allow(@backingInt(tcl.interp.Capability.thread));
    try skipLevel(&it, "set t [thread::create -isolation process -joinable {proc sq x {expr {$x*$x}}; thread::wait}]");
    try t.expectEqualStrings("144", try ev(&it, "thread::send $t {sq 12}"));
    try t.expectEqualStrings("boom {MY CODE}", try ev(&it, "catch {thread::send $t {error boom {} {MY CODE}}} m o; list $m [dict get $o -errorcode]"));
    try t.expectEqualStrings("49", try ev(&it, "thread::send -async $t {sq 7} ::r; thread::send $t {}; set ::r"));
    try t.expectEqualStrings("42", try ev(&it, "thread::send $t [list thread::send [thread::id] {set ::back 42}]; set ::back"));
    // The child has no file capability, so the sandbox gives it no file.
    try t.expectEqualStrings("1", try ev(&it, "thread::send $t {catch {open /etc/passwd}}"));
    _ = try ev(&it, "thread::release $t");
    try t.expectEqualStrings("0", try ev(&it, "thread::join $t"));
    try t.expectEqualStrings("3", try ev(&it, "thread::join [thread::create -isolation process -joinable {thread::exit 3}]"));
    // A cancel stops a loop of the child.
    _ = try ev(&it, "set c [thread::create -isolation process -joinable {while 1 {}}]; thread::cancel $c");
    try t.expectEqualStrings("1", try ev(&it, "thread::join $c"));
}

test "isolate on Linux: an isolated thread of a jailed creator reaches only the root folder" {
    if (!on or comptime !tcl.isothread.supported) return error.SkipZigTest;
    var h: tcl.Interp = undefined;
    try hostInterp(&h);
    defer h.deinit();
    const exe = (try runner(&h)) orelse return error.SkipZigTest;
    try makeRoot(&h, "thread");
    var it: tcl.Interp = undefined;
    try it.init(t.allocator);
    defer it.deinit();
    it.iso_runner = exe;
    try it.allow(@backingInt(tcl.interp.Capability.thread) | @backingInt(tcl.interp.Capability.channels) | @backingInt(tcl.interp.Capability.file));
    try tcl.fsroot.setRoot(&it, rootPath());
    try skipLevel(&it, "set t [thread::create -isolation process -joinable {thread::wait}]");
    _ = try ev(&it, "thread::send $t {set fh [open /made.txt w]; puts -nonewline $fh hi; close $fh}");
    try t.expectEqualStrings("hi", try ev(&it, "set fh [open /made.txt]; set d [read $fh]; close $fh; set d"));
    try t.expectEqualStrings("1", try ev(&it, "thread::send $t {catch {open ../outside/secret.txt}}"));
    _ = try ev(&it, "thread::release $t");
    try t.expectEqualStrings("0", try ev(&it, "thread::join $t"));
}

test "isolate on Linux: a creator in host mode needs -files host" {
    if (!on or comptime !tcl.isothread.supported) return error.SkipZigTest;
    var h: tcl.Interp = undefined;
    try hostInterp(&h);
    defer h.deinit();
    const exe = (try runner(&h)) orelse return error.SkipZigTest;
    h.iso_runner = exe;
    try h.allow(@backingInt(tcl.interp.Capability.thread));
    try t.expectEqualStrings("ZTCL ISOLATION HOSTFILES", try ev(&h, "catch {thread::create -isolation process {}}; set ::errorCode"));
    try skipLevel(&h, "set t [thread::create -isolation process -files host -joinable {thread::wait}]");
    try t.expectEqualStrings("1", try ev(&h, "thread::send $t {file exists /etc/passwd}"));
    // The other parts stay: no other process.
    try t.expectEqualStrings("1", try ev(&h, "thread::send $t {llength [glob -directory /proc -types d {[0-9]*}]}"));
    _ = try ev(&h, "thread::release $t");
    try t.expectEqualStrings("0", try ev(&h, "thread::join $t"));
}

test "isolate on Linux: -files host needs a creator in host mode" {
    if (comptime !tcl.isothread.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(t.allocator);
    defer it.deinit();
    it.iso_runner = "/nonexistent";
    try it.allow(@backingInt(tcl.interp.Capability.thread));
    try t.expectEqualStrings("ZTCL ISOLATION HOSTFILES", try ev(&it, "catch {thread::create -isolation process -files host {}}; set ::errorCode"));
}

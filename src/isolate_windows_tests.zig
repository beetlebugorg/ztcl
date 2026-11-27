//! Tests of the sandbox of the `process` level on Windows
//! (`isolate_windows.zig`). Each test starts the ztcl runner of
//! `zig-out/bin/ztcl.exe` (or `ZTCL_RUNNER`) in an AppContainer and a
//! Job Object, and skips when the runner is not built. The files of a
//! test are in `.zig-cache`, and no test opens a window or a network
//! connection.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const tcl = @import("ztcl.zig");
const iso = @import("isolate_windows.zig");
const t = std.testing;

const on = builtin.os.tag == .windows and iso.supported;

/// An interpreter with the files of the host, for the files of a test.
fn hostInterp(it: *tcl.Interp) !void {
    try it.init(t.allocator);
    try it.allow(@backingInt(tcl.interp.Capability.channels) | @backingInt(tcl.interp.Capability.file));
    try tcl.fsroot.setHost(it);
}

fn ev(it: *tcl.Interp, s: []const u8) ![]const u8 {
    const v = it.eval(s) catch |e| {
        if (e == error.TclError) std.debug.print("tcl error: {s}\n", .{it.str(it.result) catch ""});
        return e;
    };
    return it.str(v);
}

/// `iso.spawn` that prints the error of Windows of a failure.
fn start(exe: []const u8, s: iso.Spawn) !iso.Child {
    return iso.spawn(t.allocator, exe, s) catch |e| {
        std.debug.print("spawn: {t}, Windows error {d}\n", .{ e, iso.last_error });
        return e;
    };
}

/// The full path of the runner, or null when it is not built.
fn runner(it: *tcl.Interp) !?[]const u8 {
    const v = try ev(it, "expr {[info exists ::env(ZTCL_RUNNER)] ? $::env(ZTCL_RUNNER) : [file normalize zig-out/bin/ztcl.exe]}");
    if (!std.mem.eql(u8, try ev(it, try std.fmt.allocPrint(it.alloc(), "file exists {{{s}}}", .{v})), "1")) return null;
    return try it.alloc().dupe(u8, v);
}

fn windowsPath(a: std.mem.Allocator, p: []const u8) ![]u8 {
    const out = try a.dupe(u8, p);
    for (out) |*c| if (c.* == '/') {
        c.* = '\\';
    };
    return out;
}

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*const SA, disp: u32, flags: u32, tmpl: ?*anyopaque) callconv(.winapi) *anyopaque;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) i32;
const SA = extern struct { nLength: u32 = @sizeOf(SA), lpSecurityDescriptor: ?*anyopaque = null, bInheritHandle: i32 = 1 };

/// An inheritable handle of a new file, for the output of a child.
fn logFile(a: std.mem.Allocator, path: []const u8) !*anyopaque {
    const w = try std.unicode.wtf8ToWtf16LeAllocZ(a, path);
    defer a.free(w);
    const sa: SA = .{};
    const h = CreateFileW(w.ptr, 0x40000000, 0x7, &sa, 2, 0x80, null);
    if (@intFromPtr(h) == std.math.maxInt(usize)) return error.NoLog;
    return h;
}

const Fixture = struct {
    it: tcl.Interp,
    exe: []const u8,
    /// The root folder of the child, with `/`.
    root: []const u8,
    root_w: []const u8,
    log: *anyopaque,

    /// Makes the folders of a test: the root of the child, and a folder
    /// next to it with a file that the child must not read.
    fn init(f: *Fixture, name: []const u8) !bool {
        try hostInterp(&f.it);
        f.exe = (try runner(&f.it)) orelse {
            f.it.deinit();
            return false;
        };
        errdefer f.it.deinit();
        const a = f.it.alloc();
        f.root = try a.dupe(u8, try ev(&f.it, try std.fmt.allocPrint(a,
            \\set base [file normalize .zig-cache/ztcl-iso-test/{s}]
            \\file delete -force $base
            \\file mkdir $base/root $base/outside
            \\set fh [open $base/outside/secret.txt w]; puts -nonewline $fh secret; close $fh
            \\string cat $base/root
        , .{name})));
        f.root_w = try windowsPath(a, f.root);
        f.log = try logFile(a, try std.fmt.allocPrint(a, "{s}\\log.txt", .{f.root_w}));
        return true;
    }

    fn deinit(f: *Fixture) void {
        _ = CloseHandle(f.log);
        _ = f.it.eval("file delete -force [file dirname $base]") catch {};
        f.it.deinit();
    }

    fn writeScript(f: *Fixture, text: []const u8) ![]const u8 {
        const a = f.it.alloc();
        try f.it.setVar("script_text", .{ .str = text });
        _ = try ev(&f.it, "set fh [open $base/root/s.tcl w]; puts -nonewline $fh $script_text; close $fh");
        return try std.fmt.allocPrint(a, "{s}\\s.tcl", .{f.root_w});
    }

    fn readRoot(f: *Fixture, file: []const u8) ![]const u8 {
        return ev(&f.it, try std.fmt.allocPrint(f.it.alloc(), "set fh [open $base/root/{s}]; set d [read $fh]; close $fh; string trim $d", .{file}));
    }
};

test "isolate on Windows: the child reaches its root folder and no other folder, and starts no process" {
    if (!on) return error.SkipZigTest;
    var f: Fixture = undefined;
    if (!try f.init("files")) return error.SkipZigTest;
    defer f.deinit();
    const script = try f.writeScript(
        \\set root [pwd]
        \\set r {}
        \\set fh [open $root/inside.txt w]; puts -nonewline $fh inside; close $fh
        \\set fh [open $root/inside.txt]; lappend r [read $fh]; close $fh
        \\lappend r [catch {open [file dirname $root]/outside/secret.txt} m]
        \\lappend r [catch {open [file dirname $root]/outside/new.txt w} m]
        \\lappend r [catch {exec cmd.exe /c echo hi} m]
        \\set fh [open $root/result.txt w]; puts -nonewline $fh $r; close $fh
    );
    var c = try start(f.exe, .{
        .args = &.{ "--allow", "file,channels,exec", script },
        .root = f.root_w,
        .limits = .{ .mem_bytes = 512 << 20 },
        .stdout = f.log,
    });
    defer c.deinit();
    const st = c.wait(20_000) orelse return error.Timeout;
    if (st.code != 0) std.debug.print("log: {s}\n", .{f.readRoot("log.txt") catch ""});
    try t.expectEqual(@as(u32, 0), st.code);
    // The child wrote and read inside its root, could not read or write
    // the folder next to it, and could not start a process.
    try t.expectEqualStrings("inside 1 1 1", try f.readRoot("result.txt"));
    try t.expectEqualStrings("0", try ev(&f.it, "file exists $base/outside/new.txt"));
}

test "isolate on Windows: kill ends the child with the code 137, and the job counts its CPU time" {
    if (!on) return error.SkipZigTest;
    var f: Fixture = undefined;
    if (!try f.init("kill")) return error.SkipZigTest;
    defer f.deinit();
    const script = try f.writeScript("while 1 {}");
    var c = try start(f.exe, .{ .args = &.{script}, .root = f.root_w, .stdout = f.log });
    defer c.deinit();
    try t.expect(c.wait(500) == null);
    c.kill();
    const st = c.wait(5000) orelse return error.Timeout;
    try t.expectEqual(iso.killed_code, st.code);
    try t.expect(st.killed);
    try t.expect(c.usage().cpu_ns > 0);
}

test "isolate on Windows: the CPU limit and the memory limit of the job end the child" {
    if (!on) return error.SkipZigTest;
    var f: Fixture = undefined;
    if (!try f.init("limits")) return error.SkipZigTest;
    defer f.deinit();
    {
        const script = try f.writeScript("while 1 {}");
        var c = try start(f.exe, .{ .args = &.{script}, .root = f.root_w, .limits = .{ .cpu_seconds = 1 }, .stdout = f.log });
        defer c.deinit();
        const st = c.wait(15_000) orelse return error.Timeout;
        try t.expect(st.killed);
    }
    {
        const script = try f.writeScript("set s x; while 1 {append s $s}");
        var c = try start(f.exe, .{ .args = &.{script}, .root = f.root_w, .limits = .{ .mem_bytes = 64 << 20 }, .stdout = f.log });
        defer c.deinit();
        const st = c.wait(15_000) orelse return error.Timeout;
        try t.expect(st.code != 0);
        try t.expect(c.usage().peak_bytes <= 64 << 20);
    }
}

test "isolate on Windows: thread::create -isolation process runs the runner in the sandbox" {
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
    _ = try ev(&it, "set t [thread::create -isolation process -joinable {proc sq x {expr {$x*$x}}; thread::wait}]");
    try t.expectEqualStrings("42", try ev(&it, "thread::send $t {expr {6*7}}"));
    try t.expectEqualStrings("144", try ev(&it, "thread::send $t {sq 12}"));
    try t.expectEqualStrings("boom", try ev(&it, "catch {thread::send $t {error boom}} m; set m"));
    // The child has no file and no exec: the capabilities stay off.
    try t.expectEqualStrings("1", try ev(&it, "thread::send $t {catch {open C:/Windows/win.ini}}"));
    _ = try ev(&it, "thread::release $t");
    try t.expectEqualStrings("0", try ev(&it, "thread::join $t"));
    try t.expectEqualStrings("3", try ev(&it, "thread::join [thread::create -isolation process -joinable {thread::exit 3}]"));
}

test "isolate on Windows: the job of a child gets the memory limit of the thread plus the runtime" {
    const it = tcl.isothread;
    try t.expectEqual(@as(u64, 0), it.sandboxMem(std.math.maxInt(usize)));
    try t.expectEqual(@as(u64, (256 << 20) + it.runtime_mem), it.sandboxMem(256 << 20));
    try t.expectEqual(it.runtime_mem, it.sandboxMem(0));
}

test "isolate on Windows: an isolated thread opens the root folder of its creator" {
    if (!on or comptime !tcl.isothread.supported) return error.SkipZigTest;
    var f: Fixture = undefined;
    if (!try f.init("thread-root")) return error.SkipZigTest;
    defer f.deinit();
    var it: tcl.Interp = undefined;
    try it.init(t.allocator);
    defer it.deinit();
    it.iso_runner = f.exe;
    try it.allow(@backingInt(tcl.interp.Capability.thread) | @backingInt(tcl.interp.Capability.file) | @backingInt(tcl.interp.Capability.channels));
    try tcl.fsroot.setRoot(&it, f.root_w);
    _ = try ev(&it, "set t [thread::create -isolation process -joinable {thread::wait}]");
    // The child writes in the root, and its creator reads the file.
    _ = try ev(&it, "thread::send $t {set fh [open /made.txt w]; puts -nonewline $fh made; close $fh}");
    try t.expectEqualStrings("made", try f.readRoot("made.txt"));
    try t.expectEqualStrings("1", try ev(&it, "thread::send $t {file exists made.txt}"));
    // The jail of the child stops a path out of the root.
    try t.expectEqualStrings("1", try ev(&it, "thread::send $t {catch {open ../outside/secret.txt}}"));
    _ = try ev(&it, "thread::release $t");
    try t.expectEqualStrings("0", try ev(&it, "thread::join $t"));
}

test "isolate on Windows: thread::transfer moves a channel into the sandbox and back" {
    if (!on or comptime !tcl.isothread.supported) return error.SkipZigTest;
    var f: Fixture = undefined;
    if (!try f.init("thread-transfer")) return error.SkipZigTest;
    defer f.deinit();
    var it: tcl.Interp = undefined;
    try it.init(t.allocator);
    defer it.deinit();
    it.iso_runner = f.exe;
    try it.allow(@backingInt(tcl.interp.Capability.thread) | @backingInt(tcl.interp.Capability.file) | @backingInt(tcl.interp.Capability.channels));
    try tcl.fsroot.setRoot(&it, f.root_w);
    _ = try ev(&it, "set w [open /lines.txt w]; puts $w one\\ntwo\\nthree; close $w");
    _ = try ev(&it, "set t [thread::create -isolation process -joinable {thread::wait}]; set fh [open /lines.txt]; gets $fh");
    // The parent duplicates the handle into the child, with the buffered
    // input of the channel.
    try t.expectEqualStrings("0 two", try ev(&it, "thread::transfer $t $fh; list [expr {$fh in [file channels]}] [thread::send $t \"gets $fh\"]"));
    // The child sends it back: the parent takes the handle out of the child.
    try t.expectEqualStrings("three", try ev(&it, "thread::send $t \"thread::transfer [thread::id] $fh\"; gets $fh"));
    // A socket waits for WSADuplicateSocketW, and stays.
    try it.allow(@backingInt(tcl.interp.Capability.socket));
    _ = try ev(&it, "set srv [socket -server {apply {{c a p} {}}} -myaddr 127.0.0.1 0]; set cs [socket 127.0.0.1 [lindex [fconfigure $srv -sockname] 2]]");
    try t.expectEqualStrings("ZTCL ISOLATION TRANSFER 1", try ev(&it, "catch {thread::transfer $t $cs}; list {*}$::errorCode [expr {$cs in [file channels]}]"));
    _ = try ev(&it, "close $cs; close $srv");
    _ = try ev(&it, "close $fh; thread::release $t");
    try t.expectEqualStrings("0", try ev(&it, "thread::join $t"));
}

test "isolate on Windows: -files host gives an isolated thread the files of the host" {
    if (!on or comptime !tcl.isothread.supported) return error.SkipZigTest;
    var f: Fixture = undefined;
    if (!try f.init("thread-host")) return error.SkipZigTest;
    defer f.deinit();
    var it: tcl.Interp = undefined;
    try hostInterp(&it);
    defer it.deinit();
    it.iso_runner = f.exe;
    try it.allow(@backingInt(tcl.interp.Capability.thread) | @backingInt(tcl.interp.Capability.exec));
    try it.setVar("base", .{ .str = try ev(&f.it, "set base") });
    _ = try ev(&it, "set t [thread::create -isolation process -files host -joinable {thread::wait}]");
    // The folder next to the root is under the folder of the user, which
    // an AppContainer cannot read.
    try t.expectEqualStrings("secret", try ev(&it, "thread::send $t [list apply {f {set fh [open $f]; set d [read $fh]; close $fh; set d}} $base/outside/secret.txt]"));
    // The job still allows one process only, so exec fails in the child.
    try t.expectEqualStrings("couldn't execute \"cmd\": I/O error", try ev(&it, "thread::send $t {catch {exec cmd /c echo hi} m; set m}"));
    _ = try ev(&it, "thread::release $t");
    try t.expectEqualStrings("0", try ev(&it, "thread::join $t"));
}

test "isolate on Windows: the JIT runs in an AppContainer" {
    if (!on or comptime !tcl.jit.built) return error.SkipZigTest;
    var f: Fixture = undefined;
    if (!try f.init("jit")) return error.SkipZigTest;
    defer f.deinit();
    const script = try f.writeScript("proc sq x {expr {$x * $x}}; puts [sq 12]");
    var c = try start(f.exe, .{
        .args = &.{ "--jit-threshold", "0", "--jit-stats", script },
        .root = f.root_w,
        .limits = .{ .mem_bytes = 512 << 20 },
        .stdout = f.log,
    });
    defer c.deinit();
    const st = c.wait(20_000) orelse return error.Timeout;
    const log = try f.readRoot("log.txt");
    if (st.code != 0) std.debug.print("log: {s}\n", .{log});
    try t.expectEqual(@as(u32, 0), st.code);
    try t.expect(std.mem.indexOf(u8, log, "144") != null);
    try t.expect(std.mem.indexOf(u8, log, "jit compiled=1") != null);
}

const StartupInfo = extern struct {
    cb: u32 = @sizeOf(StartupInfoEx),
    reserved: ?*anyopaque = null,
    desktop: ?*anyopaque = null,
    title: ?*anyopaque = null,
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    cols: u32 = 0,
    rows: u32 = 0,
    fill: u32 = 0,
    flags: u32 = 0,
    show: u16 = 0,
    reserved2: u16 = 0,
    reserved3: ?*anyopaque = null,
    stdin: ?*anyopaque = null,
    stdout: ?*anyopaque = null,
    stderr: ?*anyopaque = null,
};
const StartupInfoEx = extern struct { info: StartupInfo = .{}, attrs: ?*anyopaque = null };
const ProcessInfo = extern struct { process: *anyopaque, thread: *anyopaque, pid: u32, tid: u32 };
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: ?[*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: i32, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *StartupInfoEx, pi: *ProcessInfo) callconv(.winapi) i32;
extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: u32, flags: u32, size: *usize) callconv(.winapi) i32;
extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: u32, attr: usize, value: *const anyopaque, size: usize, prev: ?*anyopaque, ret: ?*usize) callconv(.winapi) i32;
extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn WaitForSingleObject(h: *anyopaque, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(h: *anyopaque, code: *u32) callconv(.winapi) i32;

test "the JIT falls back to the interpreter under Arbitrary Code Guard" {
    if (!on or comptime !tcl.jit.built) return error.SkipZigTest;
    var f: Fixture = undefined;
    if (!try f.init("jit-acg")) return error.SkipZigTest;
    defer f.deinit();
    const a = f.it.alloc();
    // The runner, with the policy of Windows that refuses each page of
    // new code (PROCESS_CREATION_MITIGATION_POLICY_PROHIBIT_DYNAMIC_CODE_ALWAYS_ON).
    const policy: u64 = 1 << 36;
    var size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &size);
    const attrs = try a.alignedAlloc(u8, .of(usize), size);
    try t.expect(InitializeProcThreadAttributeList(attrs.ptr, 1, 0, &size) != 0);
    defer DeleteProcThreadAttributeList(attrs.ptr);
    try t.expect(UpdateProcThreadAttribute(attrs.ptr, 0, 0x20007, &policy, @sizeOf(u64), null, null) != 0);
    const script = try ev(&f.it, "file normalize bench/fib.tcl");
    const line = try std.fmt.allocPrint(a, "\"{s}\" --jit-threshold 0 --jit-stats \"{s}\"", .{ f.exe, script });
    const line_w = try std.unicode.wtf8ToWtf16LeAllocZ(a, line);
    var si: StartupInfoEx = .{ .attrs = attrs.ptr };
    si.info.flags = 0x100; // STARTF_USESTDHANDLES
    si.info.stdout = f.log;
    si.info.stderr = f.log;
    var pi: ProcessInfo = undefined;
    // EXTENDED_STARTUPINFO_PRESENT and CREATE_NO_WINDOW.
    try t.expect(CreateProcessW(null, line_w.ptr, null, null, 1, 0x00080000 | 0x08000000, null, null, &si, &pi) != 0);
    defer _ = CloseHandle(pi.process);
    defer _ = CloseHandle(pi.thread);
    try t.expectEqual(@as(u32, 0), WaitForSingleObject(pi.process, 60_000));
    var code: u32 = 1;
    _ = GetExitCodeProcess(pi.process, &code);
    try t.expectEqual(@as(u32, 0), code);
    // The script runs in the interpreter, and no function compiles.
    const out = try f.readRoot("log.txt");
    try t.expect(std.mem.indexOf(u8, out, "75025") != null);
    try t.expect(std.mem.indexOf(u8, out, "jit compiled=1") == null);
}

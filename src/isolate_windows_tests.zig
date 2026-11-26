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

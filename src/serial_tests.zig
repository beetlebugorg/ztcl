//! Tests of the serial ports of `serial.zig` against a pseudo-terminal.
//! The other side of a PTY is a terminal, so `open` and `fconfigure` take
//! it as a serial port. The test writes to the master side and reads it
//! back on the port, and the other way.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const tcl = @import("ztcl.zig");
const cap = tcl.interp.Capability;

const on_linux = builtin.os.tag == .linux;
const on_mac = builtin.os.tag == .macos;

fn ev(it: *tcl.Interp, script: []const u8) ![]const u8 {
    const v = it.eval(script) catch |e| {
        std.debug.print("error in {s}: {s}\n", .{ script, it.str(it.result) catch "" });
        return e;
    };
    return it.str(v);
}

/// Opens the master side of a new PTY and puts the path of the other
/// side in `name`.
fn openMaster(name: *[128]u8) !i32 {
    if (on_mac) {
        return switch (@import("pty_mac.zig").openMaster(name)) {
            .fd => |fd| fd,
            .err => error.SkipZigTest,
        };
    }
    const linux = std.os.linux;
    const rc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
    const m: i32 = @intCast(rc);
    var unlock: c_int = 0;
    _ = linux.ioctl(m, linux.T.IOCSPTLCK, @intFromPtr(&unlock));
    var n: c_uint = 0;
    if (linux.errno(linux.ioctl(m, linux.T.IOCGPTN, @intFromPtr(&n))) != .SUCCESS) return error.SkipZigTest;
    @memset(name, 0);
    _ = try std.fmt.bufPrint(name, "/dev/pts/{d}", .{n});
    return m;
}

test "a PTY as a serial port: -mode, -handshake, -xchar, and the bytes" {
    if (!on_linux and !on_mac) return error.SkipZigTest;
    var name: [128]u8 = undefined;
    const m = try openMaster(&name);
    defer tcl.sys.close(m);
    const path = std.mem.sliceTo(&name, 0);

    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try tcl.fsroot.setHost(&it);
    try it.allow(@backingInt(cap.channels) | @backingInt(cap.file));
    var buf: [256]u8 = undefined;
    _ = try ev(&it, try std.fmt.bufPrint(&buf, "set f [open {{{s}}} r+]", .{path}));

    // The PTY of Linux keeps 8 data bits and no parity for each set, so
    // the test reads back the baud and the stop bits. A rate out of the
    // table of termios goes in with BOTHER on Linux.
    const mode = if (on_mac) "115200,n,8,2" else "250000,n,8,2";
    _ = try ev(&it, try std.fmt.bufPrint(&buf, "fconfigure $f -mode {s}", .{mode}));
    try std.testing.expectEqualStrings(mode, try ev(&it, "fconfigure $f -mode"));
    _ = try ev(&it, "fconfigure $f -mode 9600,n,8,1 -handshake rtscts -xchar {a b}");
    try std.testing.expectEqualStrings("9600,n,8,1", try ev(&it, "fconfigure $f -mode"));
    try std.testing.expectEqualStrings("a b", try ev(&it, "fconfigure $f -xchar"));
    _ = try ev(&it, "fconfigure $f -handshake none -xchar [list \\x11 \\x13]");
    try std.testing.expectEqualStrings("1", try ev(&it, "expr {[lsearch [fconfigure $f] -mode] >= 0}"));
    try std.testing.expectEqualStrings("0 0", try ev(&it, "fconfigure $f -queue"));

    // Errors of the values.
    try std.testing.expectEqualStrings("bad value for -mode data: should be 5, 6, 7, or 8", try ev(&it, "catch {fconfigure $f -mode 9600,n,9,1} m; set m"));
    try std.testing.expectEqualStrings("bad value for -handshake: must be one of xonxoff, rtscts, dtrdsr, or none", try ev(&it, "catch {fconfigure $f -handshake odd} m; set m"));
    try std.testing.expectEqualStrings("bad signal \"CTS\" for -ttycontrol: must be DTR, RTS or BREAK", try ev(&it, "catch {fconfigure $f -ttycontrol {CTS 1}} m; set m"));

    // The bytes in raw mode: the master writes a line and the port reads
    // it with no echo and no change, and the other way.
    try std.testing.expect(tcl.sys.write(m, "M115\r\n") == .n);
    try std.testing.expectEqualStrings("M115\r", try ev(&it, "fconfigure $f -translation lf; gets $f"));
    _ = try ev(&it, "puts -nonewline $f ok; flush $f");
    var got: [8]u8 = undefined;
    const r = tcl.sys.read(m, &got);
    try std.testing.expect(r == .n and std.mem.eql(u8, got[0..r.n], "ok"));
    _ = try ev(&it, "close $f");

    // A file is not a serial port.
    _ = try ev(&it, "set g [open /dev/null r]");
    try std.testing.expectEqualStrings("1", try ev(&it, "catch {fconfigure $g -mode}"));
    try std.testing.expectEqualStrings("-1", try ev(&it, "lsearch [fconfigure $g] -mode"));
    _ = try ev(&it, "close $g");
}

fn now(_: ?*anyopaque) i64 {
    return tcl.proc.nowMs() * 1000;
}

fn sleep(_: ?*anyopaque, micros: i64) void {
    tcl.proc.sleepMs(@intCast(@max(1, @divFloor(micros, 1000))));
}

test "the M115 script of tools/web-api.mjs against a PTY" {
    if (!on_linux and !on_mac) return error.SkipZigTest;
    var name: [128]u8 = undefined;
    const m = try openMaster(&name);
    defer tcl.sys.close(m);
    const path = std.mem.sliceTo(&name, 0);

    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try tcl.fsroot.setHost(&it);
    try it.allow(@backingInt(cap.channels) | @backingInt(cap.file) | @backingInt(cap.event));
    it.event_host = .{ .now = now, .sleep = sleep };
    _ = try ev(&it, @embedFile("serial_testdata/m115.tcl"));
    var buf: [256]u8 = undefined;
    _ = try ev(&it, try std.fmt.bufPrint(&buf, "set f [open {{{s}}} r+]", .{path}));
    // The reply of the printer waits in the PTY before the script runs.
    // The write comes after `open`, which turns off the change of \r to \n.
    try std.testing.expect(tcl.sys.write(m, "FIRMWARE_NAME:Marlin 2.1.2\r\nok\r\n") == .n);
    _ = try ev(&it, "m115 $f; after 3000 {set ::done 3}; vwait ::done; close $f");
    try std.testing.expectEqualStrings("1", try ev(&it, "set ::done"));
    try std.testing.expectEqualStrings("{FIRMWARE_NAME:Marlin 2.1.2} ok", try ev(&it, "set ::reply"));
    var got: [16]u8 = undefined;
    const r = tcl.sys.read(m, &got);
    try std.testing.expect(r == .n and std.mem.eql(u8, got[0..r.n], "M115\n"));
}

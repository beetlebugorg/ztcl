//! Tests of the zip mounts (`vfs.zig`) and the `embedded` capability.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl.zig");
const cap = tcl.interp.Capability;

const deflate_zip = @embedFile("testdata/zip/python-deflate.zip");
const stored_zip = @embedFile("testdata/zip/python-stored.zip");

fn ev(it: *tcl.Interp, script: []const u8) ![]const u8 {
    const v = it.eval(script) catch |e| {
        std.debug.print("error in {s}: {s}\n", .{ script, it.str(it.result) catch "" });
        return e;
    };
    return it.str(v);
}

fn expectEv(it: *tcl.Interp, script: []const u8, want: []const u8) !void {
    try std.testing.expectEqualStrings(want, try ev(it, script));
}

/// The error message of a script that must fail.
fn evErr(it: *tcl.Interp, script: []const u8) ![]const u8 {
    if (it.eval(script)) |_| {
        std.debug.print("no error in {s}\n", .{script});
        return error.TestUnexpectedResult;
    } else |_| return it.str(it.result);
}

fn embedded(it: *tcl.Interp) !void {
    try it.init(std.testing.allocator);
    try it.allow(@backingInt(cap.embedded));
    try tcl.vfs.mountBytes(it, "app", "", deflate_zip);
}

test "vfs: zipfs is absent by default" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    for ([_][]const u8{ "zipfs", "open", "source", "file", "glob" }) |name| try std.testing.expect(it.findCommand(name) == null);
    try it.allow(@backingInt(cap.clock) | @backingInt(cap.event));
    try std.testing.expect(it.findCommand("zipfs") == null);
}

test "vfs: source, open, and file on an embedded mount" {
    var it: tcl.Interp = undefined;
    try embedded(&it);
    defer it.deinit();
    try expectEv(&it, "source //zipfs:/app/lib/util.tcl; hello", "hello from zip");
    try expectEv(&it, "set f [open //zipfs:/app/data/big.txt]; gets $f", "line 0 of the text");
    try expectEv(&it, "gets $f", "line 1 of the text");
    try expectEv(&it, "tell $f", "38");
    try expectEv(&it, "seek $f -21 end; gets $f", "line 499 of the text");
    try expectEv(&it, "eof $f", "0");
    try expectEv(&it, "gets $f; eof $f", "1");
    try expectEv(&it, "seek $f 0; string length [read $f]", "10390");
    try expectEv(&it, "close $f", "");
    try expectEv(&it, "file exists //zipfs:/app/lib/util.tcl", "1");
    try expectEv(&it, "file exists //zipfs:/app/lib/nope.tcl", "0");
    try expectEv(&it, "file isfile //zipfs:/app/lib/util.tcl", "1");
    try expectEv(&it, "file isdirectory //zipfs:/app/lib", "1");
    try expectEv(&it, "file isdirectory //zipfs:/app", "1");
    try expectEv(&it, "file isdirectory //zipfs:/", "1");
    try expectEv(&it, "file size //zipfs:/app/data/big.txt", "10390");
    try expectEv(&it, "file type //zipfs:/app/data", "directory");
    try expectEv(&it, "file readable //zipfs:/app/empty.txt", "1");
    try expectEv(&it, "file writable //zipfs:/app/empty.txt", "0");
    try expectEv(&it, "file normalize //zipfs:/app/lib/../data/./big.txt", "//zipfs:/app/data/big.txt");
    try expectEv(&it, "file stat //zipfs:/app/lib/util.tcl s; set s(size)", "40");
    try expectEv(&it, "file dirname //zipfs:/app/lib/util.tcl", "//zipfs:/app/lib");
    try expectEv(&it, "file join //zipfs:/app lib util.tcl", "//zipfs:/app/lib/util.tcl");
    try expectEv(&it, "glob //zipfs:/app/*", "//zipfs:/app/data //zipfs:/app/empty.txt //zipfs:/app/lib");
    try expectEv(&it, "glob -directory //zipfs:/app/lib -tails *.tcl", "util.tcl");
    try expectEv(&it, "glob -types d //zipfs:/app/*", "//zipfs:/app/data //zipfs:/app/lib");
    try expectEv(&it, "glob //zipfs:/*", "//zipfs:/app");
    try tcl.vfs.mountBytes(&it, "dot", "", @embedFile("testdata/zip/python-stored.zip"));
    try expectEv(&it, "glob -directory //zipfs:/ -tails .* d*", "dot");
    try expectEv(&it, "glob -nocomplain //zipfs:/app/*.none", "");
}

test "vfs: the zipfs command" {
    var it: tcl.Interp = undefined;
    try embedded(&it);
    defer it.deinit();
    try expectEv(&it, "zipfs root", "//zipfs:/");
    try expectEv(&it, "zipfs mount", "//zipfs:/app {}");
    try expectEv(&it, "zipfs exists //zipfs:/app/lib/util.tcl", "1");
    try expectEv(&it, "zipfs exists //zipfs:/app/x", "0");
    try expectEv(&it, "lindex [zipfs info //zipfs:/app/data/big.txt] 1", "10390");
    try expectEv(&it, "zipfs list *.tcl", "//zipfs:/app/lib/util.tcl");
    try expectEv(&it, "llength [zipfs list]", "4");
    try std.testing.expect(std.mem.indexOf(u8, try evErr(&it, "zipfs mount a.zip x"), "file capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, try evErr(&it, "zipfs unmount app"), "mount of the program") != null);
}

test "vfs: embedded gives no host access and the mounts are read-only" {
    var it: tcl.Interp = undefined;
    try embedded(&it);
    defer it.deinit();
    try std.testing.expectEqualStrings("couldn't open \"/etc/hostname\": permission denied", try evErr(&it, "open /etc/hostname"));
    try std.testing.expectEqualStrings("couldn't read file \"/etc/hostname\": permission denied", try evErr(&it, "source /etc/hostname"));
    _ = try evErr(&it, "file exists /etc/hostname");
    _ = try evErr(&it, "glob /etc/*");
    _ = try evErr(&it, "file mkdir /x");
    _ = try evErr(&it, "file delete /etc/x");
    try std.testing.expectEqualStrings("couldn't open \"//zipfs:/app/new\": read-only file system", try evErr(&it, "open //zipfs:/app/new w"));
    try std.testing.expectEqualStrings("can't delete \"//zipfs:/app/empty.txt\": read-only file system", try evErr(&it, "file delete //zipfs:/app/empty.txt"));
    _ = try evErr(&it, "file mkdir //zipfs:/app/d");
    _ = try evErr(&it, "open //zipfs:/app/lib");
    _ = try evErr(&it, "source //zipfs:/app/none.tcl");
    // A `..` above the root stays at the root.
    try expectEv(&it, "file exists //zipfs:/../../app/lib/util.tcl", "1");
}

test "vfs: a zip bomb stops at the memory limit" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(cap.embedded));
    // The central header of data/big.txt gives a size of 1 GiB.
    var buf: [deflate_zip.len]u8 = deflate_zip.*;
    var at = std.mem.indexOf(u8, &buf, "PK\x01\x02").?;
    while (!std.mem.eql(u8, buf[at + 46 ..][0..12], "data/big.txt")) at = std.mem.indexOfPos(u8, &buf, at + 1, "PK\x01\x02").?;
    std.mem.writeInt(u32, buf[at + 24 ..][0..4], 1 << 30, .little);
    try tcl.vfs.mountBytes(&it, "bomb", "", &buf);
    it.mem_limit = 64 << 20;
    _ = try evErr(&it, "open //zipfs:/bomb/data/big.txt");
    try expectEv(&it, "file size //zipfs:/bomb/data/big.txt", "1073741824");
    try expectEv(&it, "set f [open //zipfs:/bomb/lib/util.tcl]; read $f", "proc hello {} {return \"hello from zip\"}\n");
}

test "vfs: zipfs mount of a file in the jail" {
    if (!tcl.fsroot.supported or @import("builtin").os.tag != .linux) return error.SkipZigTest;
    const linux = tcl.sys.os;
    var buf: [64:0]u8 = undefined;
    const root = try std.fmt.bufPrintSentinel(&buf, "/tmp/ztcl-vfs-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdirat(linux.AT.FDCWD, root, 0o700);
    var pbuf: [80:0]u8 = undefined;
    const zpath = try std.fmt.bufPrintSentinel(&pbuf, "{s}/a.zip", .{root}, 0);
    const fd: i32 = @intCast(linux.openat(linux.AT.FDCWD, zpath, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600));
    _ = linux.write(fd, stored_zip.ptr, stored_zip.len);
    _ = linux.close(fd);
    defer {
        _ = linux.unlinkat(linux.AT.FDCWD, zpath, 0);
        _ = linux.unlinkat(linux.AT.FDCWD, root, linux.AT.REMOVEDIR);
    }
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try tcl.fsroot.setRoot(&it, root);
    try it.allow(@backingInt(cap.channels) | @backingInt(cap.file));
    try expectEv(&it, "zipfs mount /a.zip data", "");
    try expectEv(&it, "zipfs mount data", "/a.zip");
    try expectEv(&it, "source //zipfs:/data/lib/util.tcl; hello", "hello from zip");
    try expectEv(&it, "file exists /a.zip", "1");
    try std.testing.expect(std.mem.indexOf(u8, try evErr(&it, "zipfs mount /a.zip data"), "already mounted") != null);
    try std.testing.expect(std.mem.indexOf(u8, try evErr(&it, "zipfs mount /none.zip other"), "no such file") != null);
    try expectEv(&it, "zipfs unmount data; file exists //zipfs:/data/lib/util.tcl", "0");
}

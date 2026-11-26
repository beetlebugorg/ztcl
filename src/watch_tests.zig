//! Tests of `ztcl::watch` (`watch.zig`) in a root folder below /tmp.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl.zig");
const cap = tcl.interp.Capability;

fn ev(it: *tcl.Interp, script: []const u8) ![]const u8 {
    const v = it.eval(script) catch |e| {
        std.debug.print("error in {s}: {s}\n", .{ script, it.str(it.result) catch "" });
        return e;
    };
    return it.str(v);
}

/// Makes a fresh root folder. The caller removes it with `rm -rf`.
fn jail(it: *tcl.Interp, buf: *[64:0]u8) ![:0]const u8 {
    const linux = tcl.sys.os;
    const root = try std.fmt.bufPrintZ(buf, "/tmp/ztcl-watch-{d}", .{linux.getpid()});
    _ = linux.mkdirat(linux.AT.FDCWD, root, 0o700);
    try it.init(std.testing.allocator);
    try tcl.fsroot.setRoot(it, root);
    try it.allow(@intFromEnum(cap.channels) | @intFromEnum(cap.file));
    return root;
}

test "ztcl::watch is absent without file" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@intFromEnum(cap.channels) | @intFromEnum(cap.event));
    try std.testing.expect(it.findCommand("ztcl::watch") == null);
}

test "ztcl::watch reports the changes of a folder" {
    if (!tcl.watch.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    var buf: [64:0]u8 = undefined;
    _ = try jail(&it, &buf);
    defer {
        _ = it.eval("file delete -force /src /a.tcl /b.tcl /c.tcl") catch {};
        it.deinit();
        _ = tcl.sys.os.unlinkat(tcl.sys.os.AT.FDCWD, &buf, tcl.sys.os.AT.REMOVEDIR);
    }
    _ = try ev(&it, "file mkdir /src; set w [ztcl::watch add -recursive /]");
    try std.testing.expectEqualStrings("", try ev(&it, "ztcl::watch changes $w"));
    _ = try ev(&it, "set f [open /a.tcl w]; puts $f x; close $f; set f [open /src/b.tcl w]; close $f");
    try std.testing.expectEqualStrings("{created /a.tcl} {created /src/b.tcl}", try ev(&it, "ztcl::watch changes $w"));
    _ = try ev(&it, "set f [open /a.tcl a]; puts $f y; close $f");
    try std.testing.expectEqualStrings("{modified /a.tcl}", try ev(&it, "ztcl::watch changes $w"));
    _ = try ev(&it, "file rename /a.tcl /c.tcl; file delete /src/b.tcl");
    try std.testing.expectEqualStrings("{moved /a.tcl} {created /c.tcl} {deleted /src/b.tcl}", try ev(&it, "ztcl::watch changes $w"));
    // A new folder gets a watch.
    _ = try ev(&it, "file mkdir /src/new; ztcl::watch changes $w; set f [open /src/new/d.tcl w]; close $f");
    try std.testing.expectEqualStrings("{created /src/new/d.tcl}", try ev(&it, "ztcl::watch changes $w"));
    // A path outside the root and a bad name are errors.
    try std.testing.expectEqualStrings("1", try ev(&it, "catch {ztcl::watch add /../..}"));
    try std.testing.expectEqualStrings("can not find watcher named \"watch99\"", try ev(&it, "catch {ztcl::watch changes watch99} m; set m"));
    _ = try ev(&it, "ztcl::watch remove $w");
    try std.testing.expectEqualStrings("1", try ev(&it, "catch {ztcl::watch changes $w}"));
}

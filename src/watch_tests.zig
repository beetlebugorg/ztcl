//! Tests of `ztcl::watch` (`watch.zig`) in a root folder below
//! `.zig-cache`, on each platform of `watch.supported`.
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

/// Runs `script` in an interpreter with the files of the host, and
/// copies its result to `buf`.
fn host(script: []const u8, buf: []u8) ![]const u8 {
    var h: tcl.Interp = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();
    try tcl.fsroot.setHost(&h);
    try h.allow(@backingInt(cap.channels) | @backingInt(cap.file));
    const r = try ev(&h, script);
    @memcpy(buf[0..r.len], r);
    return buf[0..r.len];
}

/// Makes the empty folder `.zig-cache/<name>` and gives its full path.
fn fresh(name: []const u8, buf: []u8) ![]const u8 {
    var script: [160]u8 = undefined;
    return host(try std.fmt.bufPrint(&script, "set d [file normalize .zig-cache/{s}]; file delete -force $d; file mkdir $d; set d", .{name}), buf);
}

fn remove(dir: []const u8) void {
    var script: [400]u8 = undefined;
    var out: [8]u8 = undefined;
    _ = host(std.fmt.bufPrint(&script, "file delete -force {{{s}}}", .{dir}) catch return, &out) catch {};
}

/// An interpreter with the root folder `.zig-cache/ztcl-watch`.
fn jail(it: *tcl.Interp, buf: []u8) ![]const u8 {
    const root = try fresh("ztcl-watch", buf);
    try it.init(std.testing.allocator);
    try tcl.fsroot.setRoot(it, root);
    try it.allow(@backingInt(cap.channels) | @backingInt(cap.file));
    return root;
}

test "ztcl::watch is absent without file" {
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try it.allow(@backingInt(cap.channels) | @backingInt(cap.event));
    try std.testing.expect(it.findCommand("ztcl::watch") == null);
}

test "ztcl::watch reports the changes of a folder" {
    if (!tcl.watch.supported) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    var buf: [400]u8 = undefined;
    const root = try jail(&it, &buf);
    defer {
        _ = it.eval("file delete -force /src /a.tcl /b.tcl /c.tcl") catch {};
        it.deinit();
        remove(root);
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

test "ztcl::watch gives host paths in host mode" {
    if (!tcl.watch.supported) return error.SkipZigTest;
    var buf: [400]u8 = undefined;
    const dir = try fresh("ztcl-watch-host", &buf);
    defer remove(dir);
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer {
        _ = it.eval("file delete -force $d") catch {};
        it.deinit();
    }
    try tcl.fsroot.setHost(&it);
    try it.allow(@backingInt(cap.channels) | @backingInt(cap.file));
    var script: [600]u8 = undefined;
    _ = try ev(&it, try std.fmt.bufPrint(&script, "set d {{{s}}}; file mkdir $d/src; set w [ztcl::watch add -recursive $d]", .{dir}));
    _ = try ev(&it, "set f [open $d/a.tcl w]; close $f; set f [open $d/src/b.tcl w]; close $f");
    try std.testing.expectEqualStrings("1", try ev(&it, "expr {[ztcl::watch changes $w] eq [list [list created $d/a.tcl] [list created $d/src/b.tcl]]}"));
    _ = try ev(&it, "file mkdir $d/src/new; ztcl::watch changes $w; set f [open $d/src/new/c.tcl w]; close $f");
    try std.testing.expectEqualStrings("1", try ev(&it, "expr {[ztcl::watch changes $w] eq [list [list created $d/src/new/c.tcl]]}"));
    _ = try ev(&it, "ztcl::watch remove $w");
}

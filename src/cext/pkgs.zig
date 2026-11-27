//! The startup slots of an application for the native path:
//! `Tcl_Init`, `Tcl_StaticPackage`, and `Tcl_FindExecutable`. The
//! package slots are in `host.zig`, and `Tcl_GetVersion` is in
//! `obj.zig`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const cext = @import("cext.zig");
const Shadow = cext.Shadow;

pub const slots = struct {
    /// ztcl has its own startup, so `Tcl_Init` has no script to run.
    pub fn Tcl_Init(_: *Shadow) callconv(.c) c_int {
        return cext.TCL_OK;
    }

    pub fn Tcl_SourceRCFile(_: *Shadow) callconv(.c) void {}

    /// Adds a package that is linked into the program. `load {} Name`
    /// then calls its init function. A null interp only records it.
    pub fn Tcl_StaticPackage(sh: ?*Shadow, name: [*:0]const u8, init: ?cext.InitFn, safe_init: ?cext.InitFn) callconv(.c) void {
        _ = safe_init;
        const prefix = cext.gpa.dupe(u8, std.mem.span(name)) catch return;
        for (prefix, 0..) |*c, j| c.* = if (j == 0) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
        cext.lockPkgs();
        cext.pkgs.append(cext.gpa, .{ .path = "", .prefix = prefix, .handle = null, .init = init }) catch {};
        cext.pkgs_lock.unlock();
        // A package of an interp is in that interp already.
        if (sh) |s| s.state.loaded.put(cext.gpa, cext.gpa.dupe(u8, prefix) catch return, {}) catch {};
    }

    /// Keeps the absolute path of the program, as Tcl does: a name with a
    /// `/` is taken from the current folder, and a name with none is
    /// looked up in `PATH`.
    pub fn Tcl_FindExecutable(argv0: ?[*:0]const u8) callconv(.c) void {
        const a = std.mem.span(argv0 orelse {
            exe_name = null;
            return;
        });
        var buf: [4096]u8 = undefined;
        exe_name = cext.keep(findExe(a, &buf) orelse a) catch null;
    }

    pub fn Tcl_GetNameOfExecutable() callconv(.c) ?[*:0]const u8 {
        return exe_name;
    }
};

pub var exe_name: ?[*:0]const u8 = null;

fn findExe(a: []const u8, buf: *[4096]u8) ?[]const u8 {
    if (a.len == 0) return null;
    if (std.mem.indexOfScalar(u8, a, '/') != null) {
        var z: [4096]u8 = undefined;
        if (a.len >= z.len) return null;
        @memcpy(z[0..a.len], a);
        z[a.len] = 0;
        const r = std.c.realpath(@ptrCast(&z), buf) orelse return null;
        return std.mem.span(@as([*:0]u8, @ptrCast(r)));
    }
    var dirs = std.mem.tokenizeScalar(u8, std.mem.span(std.c.getenv("PATH") orelse return null), ':');
    while (dirs.next()) |d| {
        var z: [4096]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&z, "{s}/{s}", .{ d, a }, 0) catch continue;
        if (std.c.access(p.ptr, 1) == 0) {
            const r = std.c.realpath(p.ptr, buf) orelse continue;
            return std.mem.span(@as([*:0]u8, @ptrCast(r)));
        }
    }
    return null;
}

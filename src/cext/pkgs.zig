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

    pub fn Tcl_FindExecutable(argv0: ?[*:0]const u8) callconv(.c) void {
        exe_name = if (argv0) |a| (cext.keep(std.mem.span(a)) catch null) else null;
    }

    pub fn Tcl_GetNameOfExecutable() callconv(.c) ?[*:0]const u8 {
        return exe_name;
    }
};

var exe_name: ?[*:0]const u8 = null;

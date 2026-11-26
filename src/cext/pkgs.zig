//! The package slots of the stubs table: `Tcl_PkgProvideEx`,
//! `Tcl_PkgRequireEx`, and their forms, `Tcl_GetVersion`, and the
//! startup slots of an application.
//!
//! The package `Tcl` is ztcl itself at version 8.6.16. Its client data
//! is the public stubs table, so `Tcl_InitStubs` of a package gets the
//! table from `Tcl_PkgRequireEx`. Each other package goes to the
//! `package` command of the interpreter, when it has one. The client
//! data of `Tcl_PkgProvideEx` stays in the state of the shadow.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const cext = @import("cext.zig");
const stubs = @import("stubs.zig");
const Value = @import("../value.zig").Value;
const Interp = @import("../interp.zig").Interp;
const Shadow = cext.Shadow;

const tcl_version = "8.6.16";
const tcl_parts = [_]u32{ 8, 6, 16 };

/// The parts of a version such as "8.6.16". Null when the text is not a
/// version.
fn parse(text: []const u8, out: *[8]u32) ?[]u32 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |p| {
        if (n == out.len or p.len == 0) return null;
        out[n] = std.fmt.parseInt(u32, p, 10) catch return null;
        n += 1;
    }
    return out[0..n];
}

fn order(a: []const u32, b: []const u32) std.math.Order {
    for (0..@max(a.len, b.len)) |i| {
        const x = if (i < a.len) a[i] else 0;
        const y = if (i < b.len) b[i] else 0;
        if (x != y) return std.math.order(x, y);
    }
    return .eq;
}

/// True when Tcl 8.6.16 satisfies `want`: the same major version and no
/// lower, or the same version with `exact`.
fn tclOk(want: []const u8, exact: bool) bool {
    var buf: [8]u32 = undefined;
    const w = parse(want, &buf) orelse return false;
    if (exact) return order(&tcl_parts, w) == .eq;
    return w[0] == tcl_parts[0] and order(&tcl_parts, w) != .lt;
}

fn span(p: ?[*:0]const u8) []const u8 {
    return if (p) |q| std.mem.span(q) else "";
}

/// Runs `package` with the words of `args`. Null after an error: the
/// result of the interpreter has the message.
fn package(it: *Interp, args: []const []const u8) ?Value {
    if (it.findCommand("package") == null) return null;
    var words: [6]Value = undefined;
    words[0] = .{ .str = "package" };
    for (args, 1..) |a, i| words[i] = .{ .str = a };
    return it.evalWords(words[0 .. args.len + 1]) catch null;
}

fn require(sh: *Shadow, name: []const u8, version: []const u8, exact: bool, data: ?*?*anyopaque, present: bool) ?[*:0]const u8 {
    const it = sh.it;
    if (std.mem.eql(u8, name, "Tcl")) {
        if (version.len != 0 and !tclOk(version, exact)) {
            _ = it.failCode("TCL PACKAGE VERSIONCONFLICT", "version conflict for package \"Tcl\": have {s}, need {s}{s}", .{ tcl_version, if (exact) "exactly " else "", version }) catch {};
            return null;
        }
        if (data) |d| d.* = @ptrCast(@constCast(&stubs.public));
        return tcl_version;
    }
    var args: [4][]const u8 = undefined;
    var n: usize = 0;
    args[n] = if (present) "present" else "require";
    n += 1;
    if (exact) {
        args[n] = "-exact";
        n += 1;
    }
    args[n] = name;
    n += 1;
    if (version.len != 0) {
        args[n] = version;
        n += 1;
    }
    const got = package(it, args[0..n]) orelse {
        if (it.findCommand("package") == null) {
            _ = it.failCode("TCL PACKAGE UNFOUND", "can't find package {s}", .{name}) catch {};
        }
        return null;
    };
    const text = it.str(got) catch return null;
    if (data) |d| d.* = sh.state.pkg_data.get(name) orelse null;
    return cext.keep(text) catch null;
}

pub const slots = struct {
    pub fn Tcl_PkgProvideEx(sh: *Shadow, name: [*:0]const u8, version: [*:0]const u8, data: ?*anyopaque) callconv(.c) c_int {
        const n = std.mem.span(name);
        const v = std.mem.span(version);
        if (std.mem.eql(u8, n, "Tcl")) return if (std.mem.eql(u8, v, tcl_version)) cext.TCL_OK else cext.TCL_ERROR;
        if (sh.it.findCommand("package") != null and package(sh.it, &.{ "provide", n, v }) == null) return cext.TCL_ERROR;
        const gop = sh.state.pkg_data.getOrPut(cext.gpa, n) catch return cext.TCL_ERROR;
        if (!gop.found_existing) gop.key_ptr.* = cext.gpa.dupe(u8, n) catch {
            sh.state.pkg_data.removeByPtr(gop.key_ptr);
            return cext.TCL_ERROR;
        };
        gop.value_ptr.* = data;
        return cext.TCL_OK;
    }

    pub fn Tcl_PkgProvide(sh: *Shadow, name: [*:0]const u8, version: [*:0]const u8) callconv(.c) c_int {
        return Tcl_PkgProvideEx(sh, name, version, null);
    }

    pub fn Tcl_PkgRequireEx(sh: *Shadow, name: [*:0]const u8, version: ?[*:0]const u8, exact: c_int, data: ?*?*anyopaque) callconv(.c) ?[*:0]const u8 {
        return require(sh, std.mem.span(name), span(version), exact != 0, data, false);
    }

    pub fn Tcl_PkgRequire(sh: *Shadow, name: [*:0]const u8, version: ?[*:0]const u8, exact: c_int) callconv(.c) ?[*:0]const u8 {
        return require(sh, std.mem.span(name), span(version), exact != 0, null, false);
    }

    pub fn Tcl_PkgPresentEx(sh: *Shadow, name: [*:0]const u8, version: ?[*:0]const u8, exact: c_int, data: ?*?*anyopaque) callconv(.c) ?[*:0]const u8 {
        return require(sh, std.mem.span(name), span(version), exact != 0, data, true);
    }

    pub fn Tcl_PkgPresent(sh: *Shadow, name: [*:0]const u8, version: ?[*:0]const u8, exact: c_int) callconv(.c) ?[*:0]const u8 {
        return require(sh, std.mem.span(name), span(version), exact != 0, null, true);
    }

    /// `TCL_FINAL_RELEASE` is 2.
    pub fn Tcl_GetVersion(major: ?*c_int, minor: ?*c_int, patch: ?*c_int, kind: ?*c_int) callconv(.c) void {
        if (major) |p| p.* = tcl_parts[0];
        if (minor) |p| p.* = tcl_parts[1];
        if (patch) |p| p.* = tcl_parts[2];
        if (kind) |p| p.* = 2;
    }

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

test "cext: the version rule of Tcl_PkgRequireEx" {
    try std.testing.expect(tclOk("8.6", false));
    try std.testing.expect(tclOk("8.4", false));
    try std.testing.expect(!tclOk("9.0", false));
    try std.testing.expect(!tclOk("8.6", true));
    try std.testing.expect(tclOk("8.6.16", true));
}

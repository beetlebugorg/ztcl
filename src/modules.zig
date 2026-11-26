//! The table of built-in modules.
//!
//! A module is Zig code in the binary with an optional Tcl script. The
//! build puts a module in the table when its flag is on (`-Dbatteries`
//! and `-Dmod-NAME` in build.zig). `package require NAME` finds the
//! module by its name or by an alias, and `load` installs it in the
//! interpreter: the native commands first, then the embedded script.
//! The script is text in the binary, so no file is read. A module
//! installs once for each interpreter. An alias installs the module and
//! then runs its own script once, for the compatible commands.
//!
//! The script runs through `evalScript` at the global level, so the step
//! limit, the memory limit, and the nesting limits apply to it.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const options = @import("build_options");
const interp = @import("interp.zig");
const Interp = interp.Interp;
const Error = interp.Error;

pub const Alias = struct {
    name: []const u8,
    version: []const u8,
    /// The Tcl code of the compatible commands, or empty.
    script: []const u8 = "",
};

/// The script of the old name `zt::NAME` of the module `ztcl::NAME`. It
/// imports the exported commands of `::ztcl::NAME` into `::zt::NAME`
/// and makes an ensemble of them, so each old call works. The old names
/// stay until v0.4.0-beta.
pub fn oldNamespace(comptime name: []const u8) []const u8 {
    return "namespace eval ::zt::" ++ name ++ " {\n" ++
        "    namespace import ::ztcl::" ++ name ++ "::*\n" ++
        "    namespace export *\n" ++
        "    namespace ensemble create\n" ++
        "}\n";
}

pub const Module = struct {
    name: []const u8,
    version: []const u8,
    aliases: []const Alias = &.{},
    /// The bits of `interp.Capability` that the module needs.
    needs: u32 = 0,
    /// Registers the native commands.
    install: ?*const fn (it: *Interp) Error!void = null,
    /// The Tcl code of the module, or empty.
    script: []const u8 = "",
};

/// The modules of the build, in a fixed order.
pub const table: []const Module = blk: {
    var list: []const Module = &.{};
    if (options.mod_hello) list = list ++ @import("hello.zig").modules;
    if (options.mod_json) list = list ++ @import("json/cmd.zig").modules;
    break :blk list;
};

comptime {
    // `pkg.State.installed` has one bit for each module, and
    // `pkg.State.forgotten` one bit for each name.
    std.debug.assert(nameCount() <= 64);
}

pub const Found = struct {
    index: usize,
    /// The index in `aliases`, or null for the name of the module.
    alias: ?usize,
    mod: *const Module,
    /// The place of the name among all names: each module and each alias.
    ordinal: usize,

    pub fn module(f: Found) *const Module {
        return f.mod;
    }

    pub fn version(f: Found) []const u8 {
        return if (f.alias) |a| f.mod.aliases[a].version else f.mod.version;
    }
};

/// The module of a name or an alias.
pub fn find(name: []const u8) ?Found {
    comptime var ord: usize = 0;
    inline for (table, 0..) |*m, i| {
        if (std.mem.eql(u8, m.name, name)) return .{ .index = i, .alias = null, .mod = m, .ordinal = ord };
        ord += 1;
        inline for (m.aliases, 0..) |al, j| {
            if (std.mem.eql(u8, al.name, name)) return .{ .index = i, .alias = j, .mod = m, .ordinal = ord };
            ord += 1;
        }
    }
    return null;
}

/// The count of names: each module and each alias.
pub fn nameCount() usize {
    var n: usize = 0;
    inline for (table) |m| n += 1 + m.aliases.len;
    return n;
}

/// Calls `f(ctx, name)` for each name, in the order of the table.
pub fn eachName(ctx: anytype, comptime f: anytype) !void {
    inline for (table) |m| {
        try f(ctx, m.name);
        inline for (m.aliases) |al| try f(ctx, al.name);
    }
}

/// Installs the module of `found` in `it`, once, and runs the script of
/// the alias. The caller provides the name after this.
pub fn load(it: *Interp, found: Found, installed: *u64) Error!void {
    const m = found.module();
    const missing = m.needs & ~it.capabilities;
    if (missing != 0) {
        const bit: u32 = @as(u32, 1) << @intCast(@ctz(missing));
        const cap = std.enums.tagName(interp.Capability, @fromBackingInt(@intCast(bit))) orelse "unknown";
        const name = if (found.alias) |a| m.aliases[a].name else m.name;
        return it.failCode(try std.fmt.allocPrint(it.alloc(), "ZT PACKAGE CAPABILITY {s}", .{cap}), "module \"{s}\" needs the capability {s}", .{ name, cap });
    }
    const bit = @as(u64, 1) << @intCast(found.index);
    if (installed.* & bit == 0) {
        // The bit is on while the script runs, so a `package require` of
        // the same module inside it installs nothing.
        installed.* |= bit;
        errdefer installed.* &= ~bit;
        if (m.install) |f| try f(it);
        try runScript(it, m.script);
    }
    if (found.alias) |a| try runScript(it, m.aliases[a].script);
}

fn runScript(it: *Interp, text: []const u8) Error!void {
    if (text.len == 0) return;
    const script = try it.compile(try it.alloc().dupe(u8, text));
    const saved = it.frame;
    it.frame = &it.global;
    defer it.frame = saved;
    _ = it.evalScript(script) catch |e| switch (e) {
        error.TclReturn => {
            it.ret_code = .ok;
            it.ret_level = 1;
        },
        else => return e,
    };
}

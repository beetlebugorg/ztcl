//! The features of the build, from `-Ddrop` (see `features_table.zig`).
//!
//! `on(name)` is comptime, so a gate `if (comptime features.on("regexp"))`
//! leaves the code of a dropped feature out of the binary: the compiler
//! analyzes no function that only a dropped branch calls. A feature that
//! a feature in the build needs stays in the build.
//!
//! A dropped command is not registered. The default `unknown` gives the
//! error of `strippedCommand` for its name, so a call of a dropped
//! command names the command and the flag that keeps it. A dropped
//! option of a command in the build gives the error of `fail`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const options = @import("build_options");
pub const table = @import("features_table.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");

/// The comma list of `-Ddrop`, or empty.
pub const drop_list: []const u8 = if (@hasDecl(options, "drop")) options.drop else "";

/// The flag of each feature after the rule of `needs`.
const flags: [table.table.len]bool = blk: {
    @setEvalBranchQuota(100_000);
    var v: [table.table.len]bool = undefined;
    for (table.table, 0..) |f, i| v[i] = !table.listHas(drop_list, f.name);
    _ = table.closeNeeds(&v);
    break :blk v;
};

/// True when the feature `name` is in the build.
pub fn on(comptime name: []const u8) bool {
    const i = comptime table.index(name) orelse @compileError("no feature " ++ name);
    return flags[i];
}

/// True when no feature is dropped.
pub const full = blk: {
    for (flags) |f| if (!f) break :blk false;
    break :blk true;
};

/// The dropped feature of an embedder, such as a widget class of ztk,
/// for the name of a command with no leading `::`, or null. The embedder
/// sets it once at the start.
pub var embedder_stripped: ?*const fn (name: []const u8) ?[]const u8 = null;

/// The dropped feature of the command `name`, or null. `name` may have
/// a leading `::`.
/// The command of a dropped capability feature gets the usual error
/// when `it` does not have the capability, as in a build with the
/// feature.
pub fn strippedCommand(it: *const interp.Interp, name: []const u8) ?[]const u8 {
    if (embedder_stripped) |f| if (f(std.mem.trimStart(u8, name, ":"))) |feature| return feature;
    if (comptime full) return null;
    const n = std.mem.trimStart(u8, name, ":");
    const i = table.ofCommand(n) orelse return null;
    if (flags[i]) return null;
    const f = table.table[i];
    if (f.kind == .capability) {
        const bits = interp.Capability.parse(f.capability) orelse 0;
        if (it.capabilities & bits == 0) return null;
    }
    return f.name;
}

/// The error of a call of the command `name` of the dropped feature
/// `feature`. The error code is `ZTCL STRIPPED feature name`.
pub fn commandError(it: *interp.Interp, name: []const u8, feature: []const u8) interp.Error {
    const a = it.alloc();
    it.result = .{ .str = try std.fmt.allocPrint(a, "command \"{s}\" is not in this build: the build left out the feature {s} (rebuild with --keep {s})", .{ name, feature, feature }) };
    it.error_code = try value.newList(a, &.{ .{ .str = "ZTCL" }, .{ .str = "STRIPPED" }, .{ .str = feature }, .{ .str = name } });
    return error.TclError;
}

/// The error of a use of `what` (a command and an option, such as
/// "switch -regexp") of the dropped feature `feature`.
pub fn fail(it: *interp.Interp, comptime feature: []const u8, what: []const u8) interp.Error {
    const a = it.alloc();
    it.result = .{ .str = try std.fmt.allocPrint(a, "\"{s}\" is not in this build: the build left out the feature {s} (rebuild with --keep {s})", .{ what, feature, feature }) };
    it.error_code = try value.newList(a, &.{ .{ .str = "ZTCL" }, .{ .str = "STRIPPED" }, .{ .str = feature }, .{ .str = what } });
    return error.TclError;
}

test "a default build has each feature" {
    try std.testing.expect(full or drop_list.len > 0);
    if (drop_list.len == 0) try std.testing.expect(strippedCommand(undefined, "regexp") == null);
}

test "the table maps commands to features" {
    try std.testing.expectEqualStrings("regexp", table.table[table.ofCommand("regsub").?].name);
    try std.testing.expectEqualStrings("oo", table.table[table.ofCommand("oo::class").?].name);
    try std.testing.expect(table.ofCommand("oo::") == null);
    try std.testing.expect(table.ofCommand("set") == null);
    try std.testing.expect(table.listHas("a,regexp,b", "regexp"));
    try std.testing.expect(!table.listHas("a,regexps", "regexp"));
}

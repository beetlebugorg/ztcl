//! The test modules of the module table: `ztcl::hello` and `ztcl::hellonet`.
//!
//! `ztcl::hello` has one native command and a script that counts its
//! installs in `::ztcl::hello::installs`. The alias `hello` adds the
//! command `hello` in its own script. `ztcl::hellonet` needs the
//! capability `socket` and has no commands. The tests of the module
//! system use them, and the flag `-Dmod-hello` leaves them out.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const mods = @import("modules.zig");
const Interp = interp.Interp;
const Value = @import("value.zig").Value;

pub const modules_list = [_]mods.Module{
    .{
        .name = "ztcl::hello",
        .version = "1.0",
        .aliases = &.{
            .{ .name = "hello", .version = "0.9", .script = "proc ::hello {name} {::ztcl::hello greet $name}" },
            // The old name, until v0.4.0-beta.
            .{ .name = "zt::hello", .version = "1.0", .script = mods.oldNamespace("hello") },
        },
        .install = install,
        .script =
        \\namespace eval ::ztcl::hello {
        \\    variable installs
        \\    incr installs
        \\    namespace export greet
        \\    namespace ensemble create
        \\}
        ,
    },
    .{
        .name = "ztcl::hellonet",
        .version = "1.0",
        .aliases = &.{.{ .name = "zt::hellonet", .version = "1.0", .script = "" }},
        .needs = @intFromEnum(interp.Capability.socket),
    },
};

pub const modules: []const mods.Module = &modules_list;

/// The data of `-Dsize-plant`, for the test of the size check.
const plant: [@import("build_options").size_plant]u8 = @splat(0xa5);

fn install(it: *Interp) interp.Error!void {
    if (plant.len > 0) std.mem.doNotOptimizeAway(&plant);
    try it.register("ztcl::hello::greet", greet);
}

fn greet(it: *Interp, argv: []const Value, _: ?*interp.Cmd) interp.Error!Value {
    if (argv.len != 2) return it.wrongArgs("ztcl::hello greet name");
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "hello, {s}", .{try it.str(argv[1])}) };
}

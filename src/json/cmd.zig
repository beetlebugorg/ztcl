//! The module `zt::json`: the commands over the parser of `build.zig`.
//!
//!   zt::json parse ?-null VALUE? ?--? TEXT
//!   zt::json valid TEXT
//!   zt::json get TEXT ?STEP ...?
//!   zt::json exists TEXT ?STEP ...?
//!
//! `get` and `exists` walk the path on the structural index and make only
//! the value at its end.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("../interp.zig");
const value = @import("../value.zig");
const mods = @import("../modules.zig");
const build = @import("build.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const Cmd = interp.Cmd;

const modules_list = [_]mods.Module{.{
    .name = "zt::json",
    .version = "1.0",
    .install = install,
    .script =
    \\namespace eval ::zt::json {
    \\    namespace export parse valid get exists
    \\    namespace ensemble create
    \\}
    ,
}};

pub const modules: []const mods.Module = &modules_list;

fn install(it: *Interp) Error!void {
    try it.register("zt::json::parse", cmdParse);
    try it.register("zt::json::valid", cmdValid);
    try it.register("zt::json::get", cmdGet);
    try it.register("zt::json::exists", cmdExists);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn cmdParse(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var opts: build.Options = .{};
    var i: usize = 1;
    while (i + 1 < argv.len) {
        const w = try it.str(argv[i]);
        if (eql(w, "--")) {
            i += 1;
            break;
        }
        if (eql(w, "-null") and i + 2 < argv.len) {
            opts.null_value = argv[i + 1];
            i += 2;
        } else if (w.len > 0 and w[0] == '-') {
            return it.failCode("ZT JSON OPTION", "bad option \"{s}\": must be -null or --", .{w});
        } else break;
    }
    if (i + 1 != argv.len) return it.wrongArgs("zt::json parse ?-null value? ?--? text");
    return build.parse(it, try it.str(argv[i]), opts);
}

fn cmdValid(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("zt::json valid text");
    build.validate(it, try it.str(argv[1]), .{}) catch |e| switch (e) {
        error.TclError => {
            // The step limit and the memory limit stay errors.
            if (it.step_limit == 0 or it.overLimit()) return e;
            return .{ .int = 0 };
        },
        else => return e,
    };
    return .{ .int = 1 };
}

fn steps(it: *Interp, argv: []const Value) Error![]const []const u8 {
    const out = try it.alloc().alloc([]const u8, argv.len);
    for (argv, out) |v, *o| o.* = try it.str(v);
    return out;
}

fn cmdGet(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("zt::json get text ?step ...?");
    const path = try steps(it, argv[2..]);
    return (try build.get(it, try it.str(argv[1]), path, .{})) orelse
        it.failCode("ZT JSON PATH", "json path \"{s}\" has no value", .{try it.str(try value.newList(it.alloc(), argv[2..]))});
}

fn cmdExists(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("zt::json exists text ?step ...?");
    const path = try steps(it, argv[2..]);
    const v = build.get(it, try it.str(argv[1]), path, .{ .null_value = Value.empty }) catch |e| switch (e) {
        error.TclError => {
            if (it.step_limit == 0 or it.overLimit()) return e;
            return .{ .int = 0 };
        },
        else => return e,
    };
    return .{ .int = @intFromBool(v != null) };
}

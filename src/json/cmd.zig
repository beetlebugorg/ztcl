//! The module `ztcl::json` and the tcllib names `json` and `json::write`.
//!
//!   ztcl::json parse ?-null VALUE? ?-typed? ?--? TEXT
//!   ztcl::json valid TEXT
//!   ztcl::json get ?-null VALUE? TEXT ?STEP ...?
//!   ztcl::json exists TEXT ?STEP ...?
//!   ztcl::json encode -schema SCHEMA VALUE | -typed TREE | -auto VALUE
//!   ztcl::json object ?KEY JSON ...?    ztcl::json array ?JSON ...?
//!   ztcl::json string S   ztcl::json number N   ztcl::json bool B
//!   ztcl::json null       ztcl::json raw JSON
//!   ztcl::json pretty ?-indent N? TEXT
//!
//! The parser is in `build.zig` (a Zig implementation of the simdjson
//! algorithm) and the writer in `encode.zig`. `get` and `exists` walk the
//! path on the structural index and make only the value at its end. The
//! builders give JSON text, so a handler writes a response with no
//! schema. The tcllib names are Tcl procs in `compat.tcl` over these
//! commands and three hidden helpers.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("../interp.zig");
const value = @import("../value.zig");
const mods = @import("../modules.zig");
const build = @import("build.zig");
const encode = @import("encode.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const Cmd = interp.Cmd;

const compat = @embedFile("compat.tcl");

const modules_list = [_]mods.Module{.{
    .name = "ztcl::json",
    .version = "1.0",
    .aliases = &.{
        .{ .name = "json", .version = "1.3.6", .script = compat },
        .{ .name = "json::write", .version = "1.0.5", .script = compat },
        // The old name, until v0.4.0-beta.
        .{ .name = "zt::json", .version = "1.0", .script = mods.oldNamespace("json") },
    },
    .install = install,
    .script =
    \\namespace eval ::ztcl::json {
    \\    namespace export parse valid get exists encode object array string number bool null raw pretty
    \\    namespace ensemble create
    \\}
    ,
}};

pub const modules: []const mods.Module = &modules_list;

fn install(it: *Interp) Error!void {
    const table = .{
        .{ "ztcl::json::parse", cmdParse },   .{ "ztcl::json::valid", cmdValid },
        .{ "ztcl::json::get", cmdGet },       .{ "ztcl::json::exists", cmdExists },
        .{ "ztcl::json::encode", cmdEncode }, .{ "ztcl::json::object", cmdObject },
        .{ "ztcl::json::array", cmdArray },   .{ "ztcl::json::string", cmdString },
        .{ "ztcl::json::number", cmdNumber }, .{ "ztcl::json::bool", cmdBool },
        .{ "ztcl::json::null", cmdNull },     .{ "ztcl::json::raw", cmdRaw },
        .{ "ztcl::json::pretty", cmdPretty }, .{ "ztcl::json::_compat", cmdCompat },
        .{ "ztcl::json::_many", cmdMany },    .{ "ztcl::json::_wobject", cmdWobject },
    };
    inline for (table) |t| try it.register(t[0], t[1]);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The options before the positional words. Gives the index of the
/// first positional word.
fn options(it: *Interp, argv: []const Value, opts: *build.Options, comptime allowed: []const []const u8, comptime usage: []const u8) Error!usize {
    var i: usize = 1;
    while (i < argv.len) {
        const w = try it.str(argv[i]);
        if (w.len == 0 or w[0] != '-') break;
        if (eql(w, "--")) return i + 1;
        var ok = false;
        inline for (allowed) |name| {
            if (eql(w, name)) {
                ok = true;
                if (comptime eql(name, "-null")) {
                    if (i + 1 >= argv.len) return it.wrongArgs(usage);
                    opts.null_value = argv[i + 1];
                    i += 1;
                } else if (comptime eql(name, "-typed")) {
                    opts.typed = true;
                }
            }
        }
        if (!ok) {
            // A text that starts with "-" and is not an option: a number.
            if (w.len > 1 and std.ascii.isDigit(w[1])) break;
            return it.failCode("ZT JSON OPTION", "bad option \"{s}\": must be " ++ comptime join(allowed), .{w});
        }
        i += 1;
    }
    return i;
}

fn join(comptime names: []const []const u8) []const u8 {
    const all = names ++ &[_][]const u8{"--"};
    comptime var s: []const u8 = "";
    inline for (all, 0..) |n, i| {
        s = s ++ (if (i == 0) "" else if (i + 1 == all.len) (if (all.len == 2) " or " else ", or ") else ", ") ++ n;
    }
    return s;
}

fn cmdParse(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const usage = "ztcl::json parse ?-null value? ?-typed? ?--? text";
    var opts: build.Options = .{};
    const i = try options(it, argv, &opts, &.{ "-null", "-typed" }, usage);
    if (i + 1 != argv.len) return it.wrongArgs(usage);
    return build.parse(it, try it.str(argv[i]), opts);
}

/// The error of a limit stays an error. Other errors give `ok = false`.
fn limitOrFalse(it: *Interp, e: Error) Error!void {
    if (e != error.TclError or it.step_limit == 0 or it.overLimit()) return e;
}

fn cmdValid(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("ztcl::json valid text");
    build.validate(it, try it.str(argv[1]), .{}) catch |e| {
        try limitOrFalse(it, e);
        return .{ .int = 0 };
    };
    return .{ .int = 1 };
}

fn steps(it: *Interp, argv: []const Value) Error![]const []const u8 {
    const out = try it.alloc().alloc([]const u8, argv.len);
    for (argv, out) |v, *o| o.* = try it.str(v);
    return out;
}

fn cmdGet(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const usage = "ztcl::json get ?-null value? ?--? text ?step ...?";
    var opts: build.Options = .{};
    const i = try options(it, argv, &opts, &.{"-null"}, usage);
    if (i >= argv.len) return it.wrongArgs(usage);
    const path = try steps(it, argv[i + 1 ..]);
    return (try build.get(it, try it.str(argv[i]), path, opts)) orelse
        it.failCode("ZT JSON PATH", "json path \"{s}\" has no value", .{try it.str(try value.newList(it.alloc(), argv[i + 1 ..]))});
}

fn cmdExists(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("ztcl::json exists text ?step ...?");
    const path = try steps(it, argv[2..]);
    const v = build.get(it, try it.str(argv[1]), path, .{ .null_value = Value.empty }) catch |e| {
        try limitOrFalse(it, e);
        return .{ .int = 0 };
    };
    return .{ .int = @intFromBool(v != null) };
}

fn cmdEncode(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const usage = "ztcl::json encode -schema schema value | -typed tree | -auto value";
    var w: encode.Writer = .{ .it = it };
    if (argv.len == 4 and eql(try it.str(argv[1]), "-schema")) {
        try w.schema(argv[3], argv[2]);
    } else if (argv.len == 3 and eql(try it.str(argv[1]), "-typed")) {
        try w.typed(argv[2]);
    } else if (argv.len == 3 and eql(try it.str(argv[1]), "-auto")) {
        try w.schema(argv[2], .{ .str = "object" });
    } else return it.wrongArgs(usage);
    return w.result();
}

fn cmdObject(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len % 2 != 1) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"ztcl::json object ?key json ...?\"", .{});
    var w: encode.Writer = .{ .it = it };
    try w.byte('{');
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i > 1) try w.byte(',');
        try w.string(try it.str(argv[i]));
        try w.byte(':');
        try w.bytes(try it.str(argv[i + 1]));
        try w.tick();
    }
    try w.byte('}');
    return w.result();
}

fn cmdArray(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var w: encode.Writer = .{ .it = it };
    try w.byte('[');
    for (argv[1..], 0..) |v, i| {
        if (i > 0) try w.byte(',');
        try w.bytes(try it.str(v));
        try w.tick();
    }
    try w.byte(']');
    return w.result();
}

fn cmdString(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("ztcl::json string s");
    var w: encode.Writer = .{ .it = it };
    try w.string(try it.str(argv[1]));
    return w.result();
}

fn cmdNumber(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("ztcl::json number n");
    var w: encode.Writer = .{ .it = it };
    try w.number(argv[1]);
    return w.result();
}

fn cmdBool(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("ztcl::json bool b");
    var w: encode.Writer = .{ .it = it };
    try w.boolean(argv[1]);
    return w.result();
}

fn cmdNull(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("ztcl::json null");
    return .{ .str = "null" };
}

fn cmdRaw(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("ztcl::json raw json");
    const text = try it.str(argv[1]);
    try build.validate(it, text, .{});
    return argv[1];
}

fn cmdPretty(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const usage = "ztcl::json pretty ?-indent n? text";
    var indent: usize = 2;
    var i: usize = 1;
    if (argv.len == 4 and eql(try it.str(argv[1]), "-indent")) {
        const n = argv[2].asInt() orelse return it.failCode("ZT JSON OPTION", "expected an integer but got \"{s}\"", .{try it.str(argv[2])});
        if (n < 0 or n > 16) return it.failCode("ZT JSON OPTION", "-indent must be 0 to 16", .{});
        indent = @intCast(n);
        i = 3;
    }
    if (i + 1 != argv.len) return it.wrongArgs(usage);
    const text = try it.str(argv[i]);
    try build.validate(it, text, .{});
    var w: encode.Writer = .{ .it = it };
    try encode.pretty(&w, text, indent);
    return w.result();
}

/// `json::json2dict`: null is "null" and each number keeps its text.
fn cmdCompat(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("json::json2dict jsonText");
    return build.parse(it, try it.str(argv[1]), compat_opts);
}

/// The parse of the tcllib names: null is "null", a number keeps its
/// text, and `1.` and `.1` are numbers.
const compat_opts: build.Options = .{ .null_value = .{ .str = "null" }, .number_text = true, .lenient = true };

/// `json::many-json2dict`: the values of a sequence of JSON texts.
fn cmdMany(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("json::many-json2dict jsonText ?max?");
    return build.parseMany(it, try it.str(argv[1]), compat_opts);
}

/// `json::write object` with the layout of tcllib: with `indented`, one
/// key on each line with four spaces, and the lines of a value one level
/// in. With `aligned`, the keys have the width of the longest key.
fn cmdWobject(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 4) return it.wrongArgs("ztcl::json::_wobject indented aligned pairs");
    const indented = (argv[1].asInt() orelse 0) != 0 or eql(try it.str(argv[1]), "true");
    const aligned = (argv[2].asInt() orelse 0) != 0 or eql(try it.str(argv[2]), "true");
    const pairs = try it.list(argv[3]);
    if (pairs.len == 0) return .{ .str = "{}" };
    const keys = try it.alloc().alloc([]const u8, pairs.len / 2);
    var width: usize = 0;
    for (keys, 0..) |*k, j| {
        var kw: encode.Writer = .{ .it = it };
        try kw.string(try it.str(pairs[j * 2]));
        k.* = kw.out.items;
        width = @max(width, std.unicode.utf8CountCodepoints(k.*) catch k.len);
    }
    var w: encode.Writer = .{ .it = it };
    try w.byte('{');
    for (keys, 0..) |k, j| {
        if (j > 0) try w.byte(',');
        const v = try it.str(pairs[j * 2 + 1]);
        if (!indented) {
            try w.bytes(k);
            try w.byte(':');
            try w.bytes(v);
            continue;
        }
        try w.bytes("\n    ");
        try w.bytes(k);
        if (aligned) {
            const n = std.unicode.utf8CountCodepoints(k) catch k.len;
            try w.out.appendNTimes(it.alloc(), ' ', width - n);
        }
        try w.bytes(" : ");
        var lines = std.mem.splitScalar(u8, v, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try w.bytes("\n    ");
            first = false;
            try w.bytes(line);
        }
        try w.tick();
    }
    if (indented) try w.byte('\n');
    try w.byte('}');
    return w.result();
}

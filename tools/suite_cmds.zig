//! The suite runner: the ztcl runner with stand-ins for some `test*`
//! commands of the Tcl test binary.
//!
//! Only `zig build suite-runner` builds this file. The library, the
//! default runner, and the WebAssembly build do not have these commands.
//! Each command calls the real code of ztcl and returns its result. A
//! command that inspects C internals of Tcl has no stand-in.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl");
const runner = @import("runner");
const regex = tcl.regex;
const Interp = tcl.Interp;
const Value = tcl.Value;
const Cmd = tcl.interp.Cmd;
const Error = tcl.Error;

pub fn main(init: std.process.Init) !void {
    return runner.runWith(init, setup);
}

fn setup(it: *Interp) anyerror!void {
    try it.register("testregexp", cmdTestRegexp);
    try it.register("testevalex", cmdTestEvalEx);
    try it.register("testlsetdrop", cmdTestLsetDrop);
    try it.register("testnativedepth", cmdTestNativeDepth);
    try it.register("testjitmaps", cmdTestJitMaps);
    try it.register("testexprlong", exprCmd(.long));
    try it.register("testexprdouble", exprCmd(.double));
    try it.register("testexprstring", exprCmd(.string));
    try it.register("testexprlongobj", exprCmd(.long_obj));
    try it.register("testexprdoubleobj", exprCmd(.double_obj));
    try it.register("memory", cmdMemory);
}

/// The most live bytes that `memory info` saw.
var max_live: usize = 0;

/// `memory option ?arg ...?`: the command of a Tcl build with
/// TCL_MEM_DEBUG, over the heap of ztcl. `memory info` runs a collection
/// and gives the live bytes of the heap as "current bytes allocated".
/// The heap does not count each allocation and each free, so the counts
/// of mallocs, frees, and packets are 0. The other options check their
/// words and change nothing: the heap has no guard zones, tags, or
/// trace of each allocation.
fn cmdMemory(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("memory option [args..]");
    const opt = try it.str(argv[1]);
    if (eql(opt, "info")) {
        if (argv.len != 2) return it.wrongArgs("memory info");
        it.collect();
        const live = it.heap.live_bytes;
        max_live = @max(max_live, live);
        const text = try std.fmt.allocPrint(it.alloc(), "{s:<25} {d:>10}\n{s:<25} {d:>10}\n{s:<25} {d:>10}\n{s:<25} {d:>10}\n{s:<25} {d:>10}\n{s:<25} {d:>10}\n", .{
            "total mallocs",             0,
            "total frees",               0,
            "current packets allocated", 0,
            "current bytes allocated",   live,
            "maximum packets allocated", 0,
            "maximum bytes allocated",   max_live,
        });
        return .{ .str = text };
    }
    const one_word = [_][]const u8{ "active", "onexit", "tag", "break_on_malloc", "trace_on_at_malloc", "objs" };
    const on_off = [_][]const u8{ "trace", "validate", "init" };
    for (one_word) |name| if (eql(opt, name)) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"memory {s} arg\"", .{name});
        return Value.empty;
    };
    for (on_off) |name| if (eql(opt, name)) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"memory {s} on|off\"", .{name});
        _ = try tcl.expr.truthy(it, argv[2]);
        return Value.empty;
    };
    return it.fail("bad option \"{s}\": should be active, break_on_malloc, info, init, objs, onexit, tag, trace, trace_on_at_malloc, or validate", .{opt});
}

/// `testnativedepth`: the bytes of native stack between the outermost
/// script and this command. The JIT tests compare it with and without
/// the JIT.
fn cmdTestNativeDepth(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("testnativedepth");
    return .{ .int = @intCast(it.native_base -| @frameAddress()) };
}

/// `testjitmaps`: the count of the lines of /proc/self/maps with a
/// mapping that is writable and executable. `tools/jit-scan.sh` runs it
/// after a test file with the JIT. It is -1 when the file cannot be read.
fn cmdTestJitMaps(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("testjitmaps");
    if (comptime @import("builtin").os.tag != .linux) return .{ .int = -1 };
    const linux = std.os.linux;
    const rc = linux.open("/proc/self/maps", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return .{ .int = -1 };
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var count: i64 = 0;
    var buf: [8192]u8 = undefined;
    var line: [512]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return .{ .int = -1 };
        if (n == 0) break;
        for (buf[0..n]) |c| {
            if (c != '\n') {
                if (len < line.len) line[len] = c;
                len += 1;
                continue;
            }
            count += @intFromBool(wx(line[0..@min(len, line.len)]));
            len = 0;
        }
    }
    return .{ .int = count };
}

/// True when the rights field of a maps line has `w` and `x`.
fn wx(line: []const u8) bool {
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return false;
    const perms = line[sp + 1 ..];
    return perms.len >= 3 and perms[1] == 'w' and perms[2] == 'x';
}

/// `testlsetdrop name index value`: the dropped form of `lset`. It writes
/// in place when the variable owns its list and returns the empty string.
fn cmdTestLsetDrop(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 4) return it.wrongArgs("testlsetdrop name index value");
    const cell = (try it.findVar(it.frame, try it.str(argv[1]), false)) orelse return it.fail("can't read \"{s}\": no such variable", .{try it.str(argv[1])});
    if (!try tcl.more.lsetOwned(it, cell, argv[2], argv[3])) return it.fail("testlsetdrop: not a plain case", .{});
    return Value.empty;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `testregexp ?switches? exp ?string? ?matchVar? ?subMatchVar ...?`.
/// It compiles and matches with `regex.zig`.
fn cmdTestRegexp(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var opts: regex.Options = .{};
    var indices = false;
    var about = false;
    var partial = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (o.len == 0 or o[0] != '-') break;
        if (eql(o, "--")) {
            i += 1;
            break;
        } else if (eql(o, "-indices")) {
            indices = true;
        } else if (eql(o, "-nocase")) {
            opts.nocase = true;
        } else if (eql(o, "-about")) {
            about = true;
        } else if (eql(o, "-expanded")) {
            opts.expanded = true;
        } else if (eql(o, "-line")) {
            opts.linestop = true;
            opts.lineanchor = true;
        } else if (eql(o, "-linestop")) {
            opts.linestop = true;
        } else if (eql(o, "-lineanchor")) {
            opts.lineanchor = true;
        } else if (eql(o, "-xflags")) {
            i += 1;
            if (i >= argv.len) return it.fail("missing value for -xflags", .{});
            for (try it.str(argv[i])) |f| switch (f) {
                'b' => opts.syntax = .bre,
                'e' => opts.syntax = .ere,
                'q' => opts.syntax = .literal,
                'o' => opts.nosub = true,
                '^' => opts.notbol = true,
                '$' => opts.noteol = true,
                't' => partial = true,
                else => {},
            };
        } else break;
    }
    if (i >= argv.len) return it.wrongArgs("testregexp ?-switch ...? exp string ?matchVar? ?subMatchVar ...?");
    const re = try regex.compile(it, try it.str(argv[i]), opts);
    if (about) return regex.aboutValue(it, re);
    if (i + 1 >= argv.len) return it.wrongArgs("testregexp ?-switch ...? exp string ?matchVar? ?subMatchVar ...?");
    // The partial-match report of REG_EXPECT is internal to the C engine.
    if (partial) return it.fail("testregexp: REG_EXPECT has no stand-in", .{});
    const s = try it.str(argv[i + 1]);
    var m = try regex.Matcher.init(it, re, s);
    if (!try m.search(0)) return .{ .int = 0 };
    for (argv[i + 2 ..], 0..) |v, k| {
        try it.setVar(try it.str(v), try regex.capValue(it, &m, k, indices));
    }
    return .{ .int = 1 };
}

/// `testevalex script ?global?`: runs a script with the evaluator.
fn cmdTestEvalEx(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2 and argv.len != 3) return it.wrongArgs("testevalex script ?global?");
    const script = try it.compile(try it.str(argv[1]));
    if (argv.len == 3) {
        const saved = it.frame;
        it.frame = &it.global;
        defer it.frame = saved;
        return it.evalScript(script);
    }
    return it.evalScript(script);
}

const ExprKind = enum { long, double, string, long_obj, double_obj };

/// The `testexpr*` commands: `expr`, then the conversion of the C call.
fn exprCmd(comptime kind: ExprKind) tcl.interp.NativeFn {
    return struct {
        fn call(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len != 2) return it.fail("wrong # args: should be \"{s} expression\"", .{try it.str(argv[0])});
            const n = try tcl.expr.compile(it, try it.str(argv[1]));
            const v = try tcl.expr.numberForm(it, try tcl.expr.eval(it, n));
            switch (kind) {
                .string => return v,
                .long, .long_obj => {
                    const x: i64 = switch (v) {
                        .int => |x| x,
                        .double => |d| @intFromFloat(d),
                        else => return it.fail("expected integer but got \"{s}\"", .{try it.str(v)}),
                    };
                    if (kind == .long_obj) return .{ .int = x };
                    return .{ .str = try std.fmt.allocPrint(it.alloc(), "This is a result: {d}", .{x}) };
                },
                .double, .double_obj => {
                    const d: f64 = switch (v) {
                        .int => |x| @floatFromInt(x),
                        .double => |x| x,
                        else => return it.fail("expected floating-point number but got \"{s}\"", .{try it.str(v)}),
                    };
                    if (kind == .double_obj) return .{ .double = d };
                    return .{ .str = try std.fmt.allocPrint(it.alloc(), "This is a result: {s}", .{try tcl.value.formatDouble(it.alloc(), d)}) };
                },
            }
        }
    }.call;
}

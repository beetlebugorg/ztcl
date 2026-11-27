//! The module `ztcl::disasm` (docs/modules/disasm.md): the bytecode of a
//! proc or a script, with the source line of each command. Read-only.
//! It also gives `::tcl::unsupported::disassemble`, in the shape of the
//! output of Tcl where it can. The bytecode changes with any release.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const vm = @import("vm.zig");
const mods = @import("modules.zig");

const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const Allocator = std.mem.Allocator;

pub const enabled = @import("build_options").mod_disasm;

pub const modules_list = [_]mods.Module{.{
    .name = "ztcl::disasm",
    .version = "1.0",
    .install = install,
}};

pub const modules: []const mods.Module = &modules_list;

fn install(it: *Interp) Error!void {
    try it.register("ztcl::disasm", cmd);
    _ = try it.eval("namespace eval ::tcl::unsupported {}");
    try it.register("tcl::unsupported::disassemble", cmdTcl);
}

const usage = "ztcl::disasm proc|script|lambda arg";

/// The longest text of a literal or a command in a listing.
const max_text = 40;

/// The code to list: the bytecode, the name for the title, and the
/// source text.
const Target = struct { code: *vm.Code, title: []const u8, source: []const u8, proc: ?*interp.Proc = null };

fn target(it: *Interp, kind: []const u8, arg: Value, cmd_name: []const u8) Error!Target {
    if (std.mem.eql(u8, kind, "proc")) {
        const name = try it.str(arg);
        const c = it.findCommand(name) orelse return it.fail("\"{s}\" isn't a procedure", .{name});
        const p = switch (c.impl) {
            .proc => |p| p,
            .native => return it.fail("\"{s}\" isn't a procedure", .{name}),
        };
        return .{ .code = try procCode(it, p), .title = name, .source = try it.str(p.body), .proc = p };
    }
    if (std.mem.eql(u8, kind, "script")) {
        const text = try it.str(arg);
        const s = try it.compile(try it.alloc().dupe(u8, text));
        return .{ .code = try vm.compileNamed(it, s), .title = "script", .source = text };
    }
    if (std.mem.eql(u8, kind, "lambda")) {
        const items = arg.asList(it.alloc()) catch return it.fail("can't interpret \"{s}\" as a lambda expression", .{try it.str(arg)});
        if (items.len < 2 or items.len > 3) return it.fail("can't interpret \"{s}\" as a lambda expression", .{try it.str(arg)});
        // A lambda compiles as a proc with its parameters.
        const text = try std.fmt.allocPrint(it.alloc(), "proc ::ztcl::priv::disasm_lambda {{{s}}} {{{s}}}", .{ try it.str(items[0]), try it.str(items[1]) });
        _ = try it.eval(text);
        defer _ = it.eval("rename ::ztcl::priv::disasm_lambda {}") catch {};
        const c = it.findCommand("::ztcl::priv::disasm_lambda").?;
        return .{ .code = try procCode(it, c.impl.proc), .title = "lambda", .source = try it.str(items[1]), .proc = c.impl.proc };
    }
    return it.fail("bad type \"{s}\": must be lambda, proc, or script ({s})", .{ kind, cmd_name });
}

/// The bytecode of a proc. A proc that did not run yet compiles now, as
/// at its first call.
fn procCode(it: *Interp, p: *interp.Proc) Error!*vm.Code {
    if (p.code) |c| return c;
    if (p.script == null) p.script = try it.compile(try it.str(p.body));
    p.code = try vm.compileProc(it, p, p.script.?);
    return p.code.?;
}

fn cmd(it: *Interp, argv: []const Value, _: ?*interp.Cmd) Error!Value {
    if (argv.len != 3) return it.wrongArgs(usage);
    const t = try target(it, try it.str(argv[1]), argv[2], "ztcl::disasm");
    var out: std.ArrayList(u8) = .empty;
    try list(it, &out, t);
    return .{ .str = out.items };
}

/// One line for a text: the first `max_text` bytes on one line, in quotes.
fn short(a: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try out.append(a, '"');
    for (text[0..@min(text.len, max_text)]) |ch| switch (ch) {
        '\n' => try out.appendSlice(a, "\\n"),
        '\t' => try out.appendSlice(a, "\\t"),
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        else => try out.append(a, ch),
    };
    if (text.len > max_text) try out.appendSlice(a, "...");
    try out.append(a, '"');
}

/// The command ranges that start at `pc`, the outermost first. The
/// `guard` in front of a command checks its command before the range,
/// so a range that starts after a `guard` belongs to the guard.
fn rangesAt(code: *const vm.Code, pc: u32, buf: []*const vm.Range) []*const vm.Range {
    const after_guard = pc > 0 and code.ins[pc - 1].op == .guard;
    const guard = code.ins[pc].op == .guard and pc + 1 < code.ins.len;
    var n: usize = 0;
    // The inner ranges come first in `ranges`, so the outer ones are at the end.
    var k = code.ranges.len;
    while (k > 0) {
        k -= 1;
        const r = &code.ranges[k];
        const here = (r.start == pc and !after_guard) or (guard and r.start == pc + 1);
        if (!here or r.cmd == null or n == buf.len) continue;
        buf[n] = r;
        n += 1;
    }
    return buf[0..n];
}

/// The `ztcl::disasm` listing: a head line, the slots, and each
/// instruction under the line of its command.
fn list(it: *Interp, out: *std.ArrayList(u8), t: Target) Error!void {
    const a = it.alloc();
    const code = t.code;
    try out.print(a, "{s}: instructions {d}, literals {d}, slots {d}, stack {d}, jit {s}\n", .{
        t.title, code.ins.len, code.lits.len, code.names.len, code.max_stack, jitState(it, code),
    });
    for (code.names, 0..) |n, k| {
        try out.print(a, "  slot {d} {s}{s}\n", .{ k, n, if (k < code.params) " (parameter)" else "" });
    }
    var buf: [16]*const vm.Range = undefined;
    for (code.ins, 0..) |*ins, pc| {
        for (rangesAt(code, @intCast(pc), &buf)) |r| {
            try out.print(a, "  # line {d}: ", .{r.cmd.?.line});
            try short(a, out, r.cmd.?.text);
            try out.append(a, '\n');
        }
        try out.print(a, "  {d:>4} ", .{pc});
        try instruction(it, out, code, ins);
        try out.append(a, '\n');
    }
}

fn jitState(it: *Interp, code: *const vm.Code) []const u8 {
    if (comptime !@import("build_options").jit) return "none in this build";
    if (code.probed != null or code.probe_top) return "off (probes)";
    if (code.jit != null) if (it.jit) |j| if (code.jit_gen == j.gen) return "compiled";
    return switch (code.jit_state) {
        .failed => "not compiled",
        else => if (code.named) "not compiled" else "after more calls",
    };
}

/// One instruction: the op, its nonzero operands, and a note on its
/// operand: a literal, a slot, a command, or a jump target.
fn instruction(it: *Interp, out: *std.ArrayList(u8), code: *const vm.Code, i: *const vm.Ins) Error!void {
    const a = it.alloc();
    try out.appendSlice(a, @tagName(i.op));
    if (i.x != 0) try out.print(a, " x={d}", .{i.x});
    try out.print(a, " {d} {d} {d}", .{ i.a, i.b, i.c });
    switch (i.op) {
        .push => if (i.a < code.lits.len) {
            try out.appendSlice(a, "  # ");
            try short(a, out, try it.str(code.lits[i.a]));
        },
        .load, .store, .store_pop, .incr, .incr_drop, .append, .lappend, .store_elem => if (i.a < code.names.len) {
            try out.print(a, "  # ${s}", .{code.names[i.a]});
        },
        .invoke, .eval_cmd => if (i.a < code.sites.len) {
            try out.appendSlice(a, "  # ");
            try short(a, out, code.sites[i.a].text);
        },
        .jump, .jump_false, .jump_true => try out.print(a, "  # to {d}", .{i.a}),
        .str_eq_jump => try out.print(a, "  # to {d}", .{i.b}),
        .jf_vv, .jf_vi => try out.print(a, "  # to {d}", .{i.c}),
        .probe => try out.print(a, "  # line {d}", .{i.a}),
        else => {},
    }
}

// ---- ::tcl::unsupported::disassemble ----

/// The listing in the shape of Tcl: a head, the slots, the table of the
/// commands with their ranges of instructions and of source, and the
/// instructions under each command. The instructions are the ones of
/// ztcl, so a script that reads the names of Tcl instructions gets other
/// names. Tcl gives no stable form of this output either.
fn cmdTcl(it: *Interp, argv: []const Value, _: ?*interp.Cmd) Error!Value {
    if (argv.len != 3) return it.wrongArgs("::tcl::unsupported::disassemble lambda|proc|script arg");
    const t = try target(it, try it.str(argv[1]), argv[2], "::tcl::unsupported::disassemble");
    const a = it.alloc();
    const code = t.code;
    var out: std.ArrayList(u8) = .empty;
    var cmds: std.ArrayList(*const vm.Range) = .empty;
    for (code.ranges) |*r| if (r.cmd != null) try cmds.append(a, r);
    // The outer commands first, in the order of their start, as Tcl does.
    std.mem.sort(*const vm.Range, cmds.items, {}, struct {
        fn lt(_: void, x: *const vm.Range, y: *const vm.Range) bool {
            return x.start < y.start or (x.start == y.start and x.end > y.end);
        }
    }.lt);
    try out.print(a, "ByteCode 0x{x}, refCt 1, epoch 0, interp 0x{x} (epoch 0)\n", .{ @intFromPtr(code), @intFromPtr(it) });
    try out.appendSlice(a, "  Source ");
    try short(a, &out, t.source);
    try out.print(a, "\n  Cmds {d}, src {d}, inst {d}, litObjs {d}, aux 0, stkDepth {d}, code/src 0.00\n", .{ cmds.items.len, t.source.len, code.ins.len, code.lits.len, code.max_stack });
    if (t.proc) |p| {
        try out.print(a, "  Proc 0x{x}, refCt 1, args {d}, compiled locals {d}\n", .{ @intFromPtr(p), code.params, code.names.len });
        for (code.names, 0..) |n, k| {
            try out.print(a, "      slot {d}, scalar{s}, \"{s}\"\n", .{ k, if (k < code.params) ", arg" else "", n });
        }
    }
    try out.print(a, "  Commands {d}:\n", .{cmds.items.len});
    for (cmds.items, 1..) |r, k| {
        const lo, const hi = srcRange(t.source, r.cmd.?.text);
        try out.print(a, "      {d}: pc {d}-{d}, src {d}-{d}        ", .{ k, r.start, r.end -| 1, lo, hi });
        try short(a, &out, r.cmd.?.text);
        try out.append(a, '\n');
    }
    for (code.ins, 0..) |*ins, pc| {
        const after_guard = pc > 0 and code.ins[pc - 1].op == .guard;
        const guard = ins.op == .guard and pc + 1 < code.ins.len;
        for (cmds.items, 1..) |r, k| {
            if (!((r.start == pc and !after_guard) or (guard and r.start == pc + 1))) continue;
            try out.print(a, "  Command {d}: ", .{k});
            try short(a, &out, r.cmd.?.text);
            try out.append(a, '\n');
        }
        try out.print(a, "    ({d}) ", .{pc});
        try instruction(it, &out, code, ins);
        try out.append(a, '\n');
    }
    return .{ .str = out.items };
}

/// The first and the last byte of `text` in `source`, or 0 and the
/// length of `text` when it is not a slice of `source`.
fn srcRange(source: []const u8, text: []const u8) struct { usize, usize } {
    const s0 = @intFromPtr(source.ptr);
    const t0 = @intFromPtr(text.ptr);
    if (t0 >= s0 and t0 + text.len <= s0 + source.len) return .{ t0 - s0, t0 - s0 + text.len -| 1 };
    if (std.mem.indexOf(u8, source, text)) |at| return .{ at, at + text.len -| 1 };
    return .{ 0, text.len -| 1 };
}

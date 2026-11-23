//! The commands of `tcl::mathop` and `tcl::mathfunc`.
//!
//! Each operator of `expr` is also a command. The commands call the
//! operator functions of `expr.zig`, so a command and its operator give
//! the same result. The arithmetic commands fold over their arguments.
//! `**` folds from the right, as the operator does. A comparison is
//! true when each adjacent pair of arguments compares true.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const expr = @import("expr.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;
const BinOp = expr.BinOp;

fn usage(it: *Interp, argv: []const Value, rest: []const u8) Error {
    return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} {s}\"", .{ try it.str(argv[0]), rest });
}

/// `+`, `*`, `&`, `|`, and `^`: a fold from the identity of the operator.
fn foldCmd(comptime op: BinOp, comptime identity: i64) interp.NativeFn {
    return struct {
        fn call(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            var acc: Value = .{ .int = identity };
            for (argv[1..]) |v| acc = try expr.binaryOp(it, op, acc, v);
            return acc;
        }
    }.call;
}

/// `-` and `/`: one argument gives the negative or the reciprocal.
fn leftCmd(comptime op: BinOp) interp.NativeFn {
    return struct {
        fn call(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len < 2) return usage(it, argv, "value ?value ...?");
            if (argv.len == 2) {
                if (op == .sub) return expr.unaryOp(it, .neg, argv[1]);
                return expr.binaryOp(it, .div, .{ .double = 1.0 }, argv[1]);
            }
            var acc = argv[1];
            for (argv[2..]) |v| acc = try expr.binaryOp(it, op, acc, v);
            return acc;
        }
    }.call;
}

fn powCmd(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return .{ .int = 1 };
    for (argv[1..]) |v| _ = try expr.operand(it, v, "**");
    var acc = try expr.operand(it, argv[argv.len - 1], "**");
    var i = argv.len - 2;
    while (i >= 1) : (i -= 1) acc = try expr.binaryOp(it, .pow, argv[i], acc);
    return acc;
}

/// An operator with exactly two arguments.
fn twoCmd(comptime op: BinOp, comptime words: []const u8) interp.NativeFn {
    return struct {
        fn call(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len != 3) return usage(it, argv, words);
            return expr.binaryOp(it, op, argv[1], argv[2]);
        }
    }.call;
}

/// A comparison of each adjacent pair of arguments.
fn chainCmd(comptime op: BinOp) interp.NativeFn {
    return struct {
        fn call(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len < 3) return .{ .int = 1 };
            var i: usize = 1;
            while (i + 1 < argv.len) : (i += 1) {
                const r = try expr.binaryOp(it, op, argv[i], argv[i + 1]);
                if (r.int == 0) return .{ .int = 0 };
            }
            return .{ .int = 1 };
        }
    }.call;
}

fn notCmd(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return usage(it, argv, "boolean");
    return expr.unaryOp(it, .not, argv[1]);
}

fn bitNotCmd(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return usage(it, argv, "integer");
    return expr.unaryOp(it, .bitnot, argv[1]);
}

/// The command of one math function.
fn funcCmd(comptime f: expr.Func) interp.NativeFn {
    return struct {
        fn call(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            const n = argv.len - 1;
            try expr.checkArity(it, f, n);
            const a = it.alloc();
            const nodes = try a.alloc(expr.Node, n);
            const ptrs = try a.alloc(*expr.Node, n);
            for (argv[1..], nodes, ptrs) |v, *node, *p| {
                node.* = .{ .constant = v };
                p.* = node;
            }
            return expr.callFunc(it, f, ptrs);
        }
    }.call;
}

/// True when a command is the built-in form of its math function.
pub fn isBuiltinFunc(command: *const interp.Command, f: expr.Func) bool {
    if (command.impl != .native) return false;
    switch (f) {
        inline else => |tag| return command.impl.native == funcCmd(tag),
    }
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    const ops = .{
        .{ "+", foldCmd(.add, 0) },        .{ "*", foldCmd(.mul, 1) },
        .{ "&", foldCmd(.bitand, -1) },    .{ "|", foldCmd(.bitor, 0) },
        .{ "^", foldCmd(.bitxor, 0) },     .{ "-", leftCmd(.sub) },
        .{ "/", leftCmd(.div) },           .{ "**", &powCmd },
        .{ "%", twoCmd(.mod, "integer integer") },
        .{ "<<", twoCmd(.shl, "integer shift") },
        .{ ">>", twoCmd(.shr, "integer shift") },
        .{ "!=", twoCmd(.ne, "value value") },
        .{ "ne", twoCmd(.strne, "value value") },
        .{ "in", twoCmd(.in, "value list") },
        .{ "ni", twoCmd(.ni, "value list") },
        .{ "==", chainCmd(.eq) },          .{ "eq", chainCmd(.streq) },
        .{ "<", chainCmd(.lt) },           .{ "<=", chainCmd(.le) },
        .{ ">", chainCmd(.gt) },           .{ ">=", chainCmd(.ge) },
        .{ "!", &notCmd },                 .{ "~", &bitNotCmd },
    };
    inline for (ops) |o| try it.register("tcl::mathop::" ++ o[0], o[1]);
    inline for (@typeInfo(expr.Func).@"enum".fields) |field| {
        const tag: expr.Func = @enumFromInt(field.value);
        if (tag == .clamp or tag == .lerp or tag == .noise2 or tag == .noise3) continue;
        try it.register("tcl::mathfunc::" ++ field.name, funcCmd(tag));
    }
    _ = try it.internNs("tcl::mathop");
    _ = try it.internNs("tcl::mathfunc");
    var pats: std.ArrayList([]const u8) = .empty;
    try pats.append(it.alloc(), "*");
    try it.exports.put(it.alloc(), "tcl::mathop", pats);
}

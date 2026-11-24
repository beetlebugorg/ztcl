//! The differential fuzzer of the JIT.
//!
//!   zig build jit-fuzz -- [--seed N] [--count N] [--seconds N] [--tier2]
//!                         [--stress N] [--expect-diff] [--out DIR]
//!                         [--corpus DIR ...]
//!
//! A seed gives one random Tcl program. A small generator of
//! pseudo-random numbers (splitmix64) gives the choices, so the same seed
//! gives the same program on each run and with each Zig version. The
//! grammar has procs, loops with a bound, `expr` with each operator,
//! lists, dicts, strings, `switch`, errors, `upvar`, `uplevel`, `rename`,
//! traces, coroutines, `apply`, and namespaces. Each loop has at most 50
//! passes, and a proc calls only procs with a lower number, so each
//! program ends. The step limit also bounds each run.
//!
//! Each program runs in a new interpreter for each mode of `modes`: the
//! interpreter (the reference), the JIT at threshold 0, and the JIT at
//! the default threshold. `--tier2` adds the tier 2 modes: one of them
//! calls `tier_up` at the first pass of each loop. The summary gives
//! the count of loops that compiled to tier 2. Then the program runs
//! again in the interpreter and in one JIT mode with a step limit of a
//! random part of the full count, and with a random memory limit. Each
//! run has the collector off, so the memory count is exact. The tool
//! compares the output, the result or the error, `errorInfo`,
//! `errorCode`, the steps used, and the memory count. A difference
//! writes the seed, the modes, and the program to a file in `--out` and
//! ends with code 1. `--expect-diff` turns this around for the test of
//! the planted bug: a difference ends with code 0, and no difference
//! ends with code 1.
//!
//! `--corpus DIR` runs each `.tcl` file of DIR in the same way, with
//! eight random limits for each file, in place of the random programs.
//! The step limit of this mode is 200 000. `tests/jit/corpus/` has
//! scripts of the review of milestone 1, and `tests/jit/found/` has each
//! program that found a bug.
//!
//! `--asm FILE` reads rows of `tools/jit-asm-golden.sh --random N`. Each
//! row has an instruction form, its operands, and the bytes of `zig cc`.
//! The tool encodes each row with `src/jit/x64.zig` and compares.
//! `--asm-a64 FILE` does the same for the rows of `--arch aarch64` and
//! `src/jit/a64.zig`.
//!
//! `--verify` makes `Code` values in two ways: random instructions with
//! the side tables of a real proc, and the `Code` of a proc of a random
//! program with 1 to 4 random changes of an opcode or an operand. The
//! verifier checks each one. When it accepts one, the JIT compiles it,
//! and the proc runs with that code in two interpreters with the same
//! history: one with the JIT and one without it. The step limit is
//! 10 000, or below 64 in one run of four. One run of four has a memory
//! limit a little above the count before the run. The result,
//! `errorInfo`, the steps used, the memory count, and the output must be
//! equal, and the run of the JIT must end in one second. The process
//! must not crash, and no safety check may fail. The collector is off
//! in this mode, because a changed `Code` lives outside the heap.
//! `--tier2` and `--stress N` set the same options of the JIT here: with
//! `--tier2`, each loop calls `tier_up` at its first pass.
//!
//! The values of a multiplication never flow back into an operand of a
//! multiplication, so the size of each integer grows at most linearly
//! with the steps.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Interp = tcl.Interp;
const Value = tcl.Value;

// ---- The random numbers ----

/// splitmix64: a fixed function of the seed, so a program does not
/// depend on the version of the standard library.
const Rng = struct {
    s: u64,

    fn init(seed: u64, stream: u64) Rng {
        return .{ .s = seed *% 0x9E3779B97F4A7C15 +% stream *% 0xD1B54A32D192ED03 +% 1 };
    }

    fn next(r: *Rng) u64 {
        r.s +%= 0x9E3779B97F4A7C15;
        var z = r.s;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// A number in 0 .. n-1. n is at least 1.
    fn below(r: *Rng, n: u64) u64 {
        return r.next() % n;
    }

    fn chance(r: *Rng, percent: u64) bool {
        return r.below(100) < percent;
    }

    fn pick(r: *Rng, comptime T: type, items: []const T) T {
        return items[@intCast(r.below(items.len))];
    }
};

// ---- The grammar ----

/// The items of the grammar. The share of programs that run each item is
/// in the report.
const Item = enum {
    set,
    incr,
    expr,
    @"if",
    @"while",
    @"for",
    foreach,
    @"break",
    @"continue",
    @"return",
    return_code,
    lappend,
    lindex,
    llength,
    lset,
    lassign,
    list,
    dict_set,
    dict_incr,
    dict_get,
    append,
    string_length,
    string_index,
    @"switch",
    @"catch",
    @"try",
    @"error",
    upvar,
    uplevel,
    global,
    eval,
    rename_core,
    rename_proc,
    trace,
    unset,
    coroutine,
    yield,
    apply,
    namespace,
    puts,
    call,
};

const n_items = @typeInfo(Item).@"enum".fields.len;

const vars = [_][]const u8{ "a", "b", "c", "d", "e", "f" };
const keys = [_][]const u8{ "k0", "k1", "k2", "{k 3}" };
const core = [_][]const u8{ "set", "incr", "expr", "llength", "lindex", "lappend", "append", "string", "dict", "lset", "lassign", "list", "foreach" };

const ints = [_][]const u8{
    "0",                    "1",                    "-1",          "2",           "-2",          "7",
    "2147483647",           "-2147483648",          "2147483648",  "-2147483649", "4294967295",  "4294967296",
    "9223372036854775807",  "-9223372036854775808", "9223372036854775806",        "-9223372036854775807",
    "9223372036854775808",  "-9223372036854775809", "4611686018427387904",        "3037000500",
};

const doubles = [_][]const u8{ "1.5", "-0.0", "0.1", "2.0", "1e300", "-1e-5", "3.0e2", "1e308" };

/// Words that need no quotes in a command and in `expr`.
const strings = [_][]const u8{ "{}", "abc", "{a b}", "{1 2 3}", "0x10", "{ 12 }", "1e3", "007", "{a {b c}}", "-0", "true", "no", "{x y z w}", "0b101", "+5" };

/// The same texts as strings of `expr`.
const expr_strings = [_][]const u8{ "\"\"", "\"abc\"", "\"a b\"", "\"0x10\"", "\" 12 \"", "\"1e3\"", "\"007\"", "\"true\"", "\"no\"", "\"+5\"", "\"10\"" };

const compare_ops = [_][]const u8{ "<", "<=", ">", ">=", "==", "!=" };
const arith_ops = [_][]const u8{ "+", "-", "+", "-", "/", "%", "&", "|", "^", "<", "<=", ">", ">=", "==", "!=", "eq", "ne", "&&", "||" };

const Gen = struct {
    r: Rng,
    a: Allocator,
    out: std.ArrayList(u8) = .empty,
    /// True: each item has a call of `_hit` before it, for the report.
    mark: bool,
    /// The number of procs and the parameters of each.
    nprocs: u32 = 0,
    params: [6]u32 = @splat(0),
    /// The proc that the generator writes, or null at the top level.
    cur: ?u32 = null,
    /// The loops around the statement.
    loops: u32 = 0,
    /// The blocks around the statement.
    depth: u32 = 0,
    /// The counter for unique names.
    uid: u32 = 0,
    /// The loop variables that the statement can read.
    lvars: [8][]const u8 = undefined,
    nlvars: usize = 0,
    /// True inside a lambda of `apply` or a proc of a namespace.
    inner: bool = false,
    /// The variable that a command writes. Its value is not a word of
    /// the same command, so no value holds itself and doubles in size.
    avoid: []const u8 = "",

    const E = Allocator.Error;

    fn w(g: *Gen, s: []const u8) E!void {
        try g.out.appendSlice(g.a, s);
    }

    fn p(g: *Gen, comptime fmt: []const u8, args: anytype) E!void {
        try g.out.print(g.a, fmt, args);
    }

    fn hit(g: *Gen, which: Item) E!void {
        if (g.mark) try g.p("_hit {d}; ", .{@intFromEnum(which)});
    }

    fn v(g: *Gen) []const u8 {
        return g.r.pick([]const u8, &vars);
    }

    fn int(g: *Gen) E!void {
        if (g.r.chance(70)) return g.w(g.r.pick([]const u8, &ints));
        try g.p("{d}", .{@as(i64, @intCast(g.r.below(41))) - 20});
    }

    /// A literal word of a command.
    fn lit(g: *Gen) E!void {
        const k = g.r.below(100);
        if (k < 50) return g.int();
        if (k < 62) return g.w(g.r.pick([]const u8, &doubles));
        return g.w(g.r.pick([]const u8, &strings));
    }

    /// A word of a command: a literal, a variable, or a small command.
    fn word(g: *Gen) E!void {
        const k = g.r.below(100);
        if (k < 40) return g.lit();
        if (k < 75) return g.p("${s}", .{g.operandVar()});
        if (k < 85) {
            try g.w("[expr {");
            try g.expr(1, false);
            return g.w("}]");
        }
        if (k < 93) {
            try g.w("[list ");
            try g.lit();
            try g.w(" ");
            try g.lit();
            return g.w("]");
        }
        return g.p("[llength ${s}]", .{g.v()});
    }

    /// A variable to read: a loop variable or one of `vars`.
    fn operandVar(g: *Gen) []const u8 {
        if (g.nlvars > 0 and g.r.chance(30)) return g.lvars[@intCast(g.r.below(g.nlvars))];
        const x = g.v();
        return if (std.mem.eql(u8, x, g.avoid)) "g0" else x;
    }

    /// A word for a command that writes `dst`.
    fn wordFor(g: *Gen, dst: []const u8) E!void {
        g.avoid = dst;
        defer g.avoid = "";
        try g.word();
    }

    fn operand(g: *Gen) E!void {
        const k = g.r.below(100);
        if (k < 55) return g.p("${s}", .{g.operandVar()});
        if (k < 85) return g.int();
        if (k < 92) return g.w(g.r.pick([]const u8, &doubles));
        return g.w(g.r.pick([]const u8, &expr_strings));
    }

    /// An expression. `mul` allows `*`, `**`, and `<<`: their results
    /// go only to `p` and `q`, to `puts`, and to conditions.
    fn expr(g: *Gen, d: u32, mul: bool) E!void {
        if (d >= 3 or g.r.chance(35)) return g.operand();
        const k = g.r.below(100);
        if (k < 70) {
            try g.w("(");
            try g.expr(d + 1, mul);
            if (mul and g.r.chance(25)) {
                const m = g.r.below(3);
                if (m == 0) {
                    try g.w(" * ");
                    try g.expr(d + 1, false);
                } else if (m == 1) {
                    try g.p(" ** {d}", .{g.r.below(5)});
                } else {
                    try g.p(" << {d}", .{g.r.below(70)});
                }
            } else {
                try g.p(" {s} ", .{g.r.pick([]const u8, &arith_ops)});
                try g.expr(d + 1, mul);
            }
            return g.w(")");
        }
        if (k < 80) {
            try g.w(g.r.pick([]const u8, &.{ "-", "!", "~", "+" }));
            return g.expr(d + 1, mul);
        }
        if (k < 88) {
            try g.w("(");
            try g.cond();
            try g.w(" ? ");
            try g.expr(d + 1, mul);
            try g.w(" : ");
            try g.expr(d + 1, mul);
            return g.w(")");
        }
        try g.w(g.r.pick([]const u8, &.{ "abs(", "int(", "double(", "bool(", "wide(" }));
        try g.expr(d + 1, mul);
        try g.w(")");
    }

    /// A condition. Most have the forms of `jf_vv` and `jf_vi`.
    fn cond(g: *Gen) E!void {
        const k = g.r.below(100);
        if (k < 40) return g.p("${s} {s} ${s}", .{ g.operandVar(), g.r.pick([]const u8, &compare_ops), g.operandVar() });
        if (k < 70) {
            try g.p("${s} {s} ", .{ g.operandVar(), g.r.pick([]const u8, &compare_ops) });
            return g.int();
        }
        if (k < 80) return g.p("[string length ${s}] > {d}", .{ g.v(), g.r.below(4) });
        return g.expr(1, true);
    }

    fn indent(g: *Gen) E!void {
        for (0..g.depth + 1) |_| try g.w("  ");
    }

    /// A block of 1 to n statements in braces.
    fn block(g: *Gen, n: u64) E!void {
        try g.w("{\n");
        g.depth += 1;
        const count = 1 + g.r.below(n);
        for (0..count) |_| try g.stmt();
        g.depth -= 1;
        try g.indent();
        try g.w("}");
    }

    fn loopBlock(g: *Gen, lv: ?[]const u8) E!void {
        g.loops += 1;
        defer g.loops -= 1;
        if (lv) |n| {
            g.lvars[g.nlvars] = n;
            g.nlvars += 1;
        }
        defer if (lv != null) {
            g.nlvars -= 1;
        };
        try g.block(4);
    }

    /// The pass count of a loop: at most 50, and smaller inside a loop.
    fn passes(g: *Gen) u64 {
        return if (g.loops == 0) g.r.below(51) else g.r.below(7);
    }

    fn name(g: *Gen, prefix: []const u8) E![]const u8 {
        g.uid += 1;
        return std.fmt.allocPrint(g.a, "{s}{d}", .{ prefix, g.uid });
    }

    fn printErr(g: *Gen, tag: []const u8) E!void {
        try g.p("if {{$rc == 1}} {{puts \"{s}ec $::errorCode\"; puts \"{s}ei [lindex [split $::errorInfo \\n] 0]\"}}", .{ tag, tag });
    }

    /// Calls proc `k` with random arguments.
    fn callText(g: *Gen, k: u32) E!void {
        try g.p("p{d}", .{k});
        for (0..g.params[k]) |_| {
            try g.w(" ");
            try g.word();
        }
    }

    fn pickItem(g: *Gen) Item {
        // The weights: common statements first.
        const table = [_]struct { Item, u8 }{
            .{ .set, 10 },          .{ .incr, 8 },            .{ .expr, 12 },         .{ .@"if", 6 },
            .{ .@"while", 3 },      .{ .@"for", 4 },          .{ .foreach, 4 },       .{ .@"break", 5 },
            .{ .@"continue", 4 },   .{ .@"return", 2 },       .{ .return_code, 2 },   .{ .lappend, 5 },
            .{ .lindex, 3 },        .{ .llength, 2 },         .{ .lset, 3 },          .{ .lassign, 3 },
            .{ .list, 2 },          .{ .dict_set, 3 },        .{ .dict_incr, 3 },     .{ .dict_get, 2 },
            .{ .append, 4 },        .{ .string_length, 2 },   .{ .string_index, 2 },  .{ .@"switch", 3 },
            .{ .@"catch", 3 },      .{ .@"try", 2 },          .{ .@"error", 2 },      .{ .upvar, 2 },
            .{ .uplevel, 2 },       .{ .global, 2 },          .{ .eval, 2 },          .{ .rename_core, 1 },
            .{ .rename_proc, 1 },   .{ .trace, 1 },           .{ .unset, 2 },         .{ .coroutine, 1 },
            .{ .yield, 1 },         .{ .apply, 2 },           .{ .namespace, 1 },     .{ .puts, 4 },
            .{ .call, 4 },
        };
        comptime var total: u64 = 0;
        inline for (table) |t| total += t[1];
        var k = g.r.below(total);
        for (table) |t| {
            if (k < t[1]) return t[0];
            k -= t[1];
        }
        unreachable;
    }

    /// One statement on its own line.
    fn stmt(g: *Gen) E!void {
        try g.indent();
        var choice = g.pickItem();
        // Items that need a context fall back to `set`.
        switch (choice) {
            .@"break", .@"continue" => if (g.loops == 0) {
                choice = .set;
            },
            .@"return", .return_code, .upvar, .yield => if (g.cur == null and !g.inner) {
                choice = .set;
            },
            .coroutine, .namespace => if (g.cur != null or g.inner or g.depth > 1) {
                choice = .incr;
            },
            .call => if ((g.cur orelse g.nprocs) == 0) {
                choice = .expr;
            },
            .@"while", .@"for", .foreach, .@"if", .@"switch", .@"catch", .@"try", .apply, .rename_core, .rename_proc => if (g.depth >= 3) {
                choice = .incr;
            },
            else => {},
        }
        try g.hit(choice);
        try g.item(choice);
        try g.w("\n");
    }

    fn item(g: *Gen, it: Item) E!void {
        const r = &g.r;
        switch (it) {
            .set => {
                if (r.chance(30)) {
                    try g.p("set {s} [expr {{", .{r.pick([]const u8, &.{ "p", "q" })});
                    try g.expr(0, true);
                    return g.w("}]");
                }
                const dst = g.v();
                try g.p("set {s} ", .{dst});
                try g.wordFor(dst);
            },
            .incr => {
                const k = r.below(4);
                if (k == 0) return g.p("incr {s}", .{g.v()});
                if (k == 1) {
                    try g.p("incr {s} ", .{g.v()});
                    return g.int();
                }
                if (k == 2) return g.p("incr {s} ${s}", .{ g.v(), g.operandVar() });
                try g.p("set {s} [incr {s} ", .{ g.v(), g.v() });
                try g.int();
                try g.w("]");
            },
            .expr => {
                const k = r.below(4);
                if (k == 0) return g.p("set {s} [expr {{${s} {s} ${s}}}]", .{ g.v(), g.v(), r.pick([]const u8, &arith_ops), g.operandVar() });
                if (k == 1) {
                    try g.p("set {s} [expr {{${s} {s} ", .{ g.v(), g.operandVar(), r.pick([]const u8, &arith_ops) });
                    try g.int();
                    return g.w("}]");
                }
                if (k == 2) {
                    try g.w("puts [expr {");
                    try g.expr(0, true);
                    return g.w("}]");
                }
                try g.p("set {s} [expr {{", .{g.v()});
                try g.expr(0, false);
                try g.w("}]");
            },
            .@"if" => {
                try g.w("if {");
                try g.cond();
                try g.w("} ");
                try g.block(3);
                if (r.chance(30)) {
                    try g.w(" elseif {");
                    try g.cond();
                    try g.w("} ");
                    try g.block(2);
                }
                if (r.chance(40)) {
                    try g.w(" else ");
                    try g.block(2);
                }
            },
            .@"while" => {
                const n = try g.name("w");
                try g.p("set {s} 0; while {{${s} < {d}}} {{incr {s}; ", .{ n, n, g.passes(), n });
                try g.loopBlock(n);
                try g.w("}");
            },
            .@"for" => {
                const n = try g.name("i");
                const k = g.passes();
                if (r.chance(70)) {
                    try g.p("for {{set {s} 0}} {{${s} < {d}}} {{incr {s}}} ", .{ n, n, k, n });
                } else {
                    try g.p("for {{set {s} {d}}} {{${s} > 0}} {{incr {s} -1}} ", .{ n, k, n, n });
                }
                try g.loopBlock(n);
            },
            .foreach => {
                const nv = 1 + r.below(3);
                try g.w("foreach {");
                for (0..nv) |k| {
                    if (k > 0) try g.w(" ");
                    try g.w(g.v());
                }
                try g.w("} ");
                if (r.chance(50)) {
                    try g.w("{");
                    for (0..g.passes() / 2) |k| {
                        if (k > 0) try g.w(" ");
                        try g.lit();
                    }
                    try g.w("}");
                } else try g.p("${s}", .{g.v()});
                try g.w(" ");
                try g.loopBlock(null);
            },
            .@"break" => {
                if (r.chance(30)) return g.w("break");
                try g.w("if {");
                try g.cond();
                try g.w("} break");
            },
            .@"continue" => {
                if (r.chance(20)) return g.w("continue");
                try g.w("if {");
                try g.cond();
                try g.w("} continue");
            },
            .@"return" => {
                try g.w("if {");
                try g.cond();
                try g.w("} {return ");
                try g.word();
                try g.w("}");
            },
            .return_code => {
                try g.w("if {");
                try g.cond();
                try g.w("} {return -code ");
                try g.w(r.pick([]const u8, &.{ "error bad", "break", "continue", "7 seven", "ok fine", "return up", "1 one", "error -errorcode {MY CODE} coded" }));
                try g.w("}");
            },
            .lappend => {
                const dst = r.pick([]const u8, &.{ "l", "l", "a", "b", "c" });
                try g.p("lappend {s} ", .{dst});
                try g.wordFor(dst);
                if (r.chance(30)) {
                    try g.w(" ");
                    try g.wordFor(dst);
                }
            },
            .lindex => {
                try g.p("set {s} [lindex ${s} ", .{ g.v(), r.pick([]const u8, &.{ "l", "a", "b", "c", "d" }) });
                try g.index();
                try g.w("]");
            },
            .llength => try g.p("set {s} [llength ${s}]", .{ g.v(), r.pick([]const u8, &.{ "l", "a", "b", "c" }) }),
            .lset => {
                const k = r.below(3);
                const dst = if (k == 0) "l" else r.pick([]const u8, &.{ "l", "l", "a", "b" });
                if (k == 0) try g.p("set {s} [lset l ", .{g.v()}) else try g.p("lset {s} ", .{dst});
                try g.index();
                try g.w(" ");
                try g.wordFor(dst);
                if (k == 0) try g.w("]");
            },
            .lassign => {
                const keep = r.chance(50);
                if (keep) try g.p("set {s} [", .{g.v()});
                try g.p("lassign ${s} {s} {s}", .{ r.pick([]const u8, &.{ "l", "a", "b" }), g.v(), g.v() });
                if (r.chance(40)) try g.p(" {s}", .{g.v()});
                if (keep) try g.w("]");
            },
            .list => {
                const dst = r.pick([]const u8, &.{ "l", "a", "b", "c" });
                try g.p("set {s} [list", .{dst});
                for (0..r.below(5)) |_| {
                    try g.w(" ");
                    try g.wordFor(dst);
                }
                try g.w("]");
            },
            .dict_set => {
                const dst = r.pick([]const u8, &.{ "dd", "dd", "a" });
                try g.p("dict set {s} {s} ", .{ dst, r.pick([]const u8, &keys) });
                try g.wordFor(dst);
            },
            .dict_incr => {
                try g.p("dict incr {s} {s}", .{ r.pick([]const u8, &.{ "dd", "dd", "b" }), r.pick([]const u8, &keys) });
                if (r.chance(50)) {
                    try g.w(" ");
                    try g.int();
                }
            },
            .dict_get => try g.p("set {s} [dict get ${s} {s}]", .{ g.v(), r.pick([]const u8, &.{ "dd", "dd", "a" }), r.pick([]const u8, &keys) }),
            .append => {
                const dst = r.pick([]const u8, &.{ "s", "s", "a", "c" });
                const keep = r.chance(30);
                if (keep) try g.p("set {s} [", .{g.v()});
                try g.p("append {s}", .{dst});
                for (0..1 + r.below(3)) |_| {
                    try g.w(" ");
                    try g.wordFor(dst);
                }
                if (keep) try g.w("]");
            },
            .string_length => try g.p("set {s} [string length ${s}]", .{ g.v(), g.operandVar() }),
            .string_index => {
                try g.p("set {s} [string index ${s} ", .{ g.v(), g.v() });
                try g.index();
                try g.w("]");
            },
            .@"switch" => {
                try g.p("switch {s}${s} {{\n", .{ r.pick([]const u8, &.{ "", "-exact -- " }), g.operandVar() });
                g.depth += 1;
                for (0..1 + r.below(3)) |_| {
                    try g.indent();
                    try g.lit();
                    try g.w(" ");
                    try g.block(2);
                    try g.w("\n");
                }
                if (r.chance(60)) {
                    try g.indent();
                    try g.w("default ");
                    try g.block(2);
                    try g.w("\n");
                }
                g.depth -= 1;
                try g.indent();
                try g.w("}");
            },
            .@"catch" => {
                const tag = try g.name("c");
                try g.w("set rc [catch ");
                try g.block(3);
                try g.p(" m]; puts \"{s} $rc $m\"; ", .{tag});
                try g.printErr(tag);
            },
            .@"try" => {
                try g.w("try ");
                try g.block(3);
                const tag = try g.name("t");
                try g.p(" on error {{m o}} {{puts \"{s}e $m [dict get $o -errorcode]\"}} on 3 {{}} {{puts {s}b}} on 4 {{}} {{puts {s}c}}", .{ tag, tag, tag });
                if (r.chance(50)) try g.p(" finally {{puts {s}f}}", .{tag});
            },
            .@"error" => {
                try g.w("if {");
                try g.cond();
                try g.w("} {error ");
                try g.w(r.pick([]const u8, &.{ "oops", "{two words}", "msg {} {MY ERR}", "x {custom info} {A B C}" }));
                try g.w("}");
            },
            .upvar => try g.p("upvar {s} {s} u; set {s} [info exists u]", .{ r.pick([]const u8, &.{ "1", "1", "#0" }), r.pick([]const u8, &.{ "g0", "g1", "a", "l", "s" }), g.v() }),
            .uplevel => {
                const k = r.below(3);
                if (k == 0) return g.w("uplevel #0 {incr ::tc}");
                if (k == 1) return g.p("uplevel 1 {{set g0 [expr {{$g0 + 1}}]}}", .{});
                try g.p("uplevel 1 [list set g1 ${s}]", .{g.operandVar()});
            },
            .global => {
                try g.p("global g0 g1; incr g0; set {s} $g1", .{g.v()});
            },
            .eval => {
                const k = r.below(3);
                if (k == 0) {
                    const dst = g.v();
                    try g.p("eval [list set {s} ", .{dst});
                    try g.wordFor(dst);
                    return g.w("]");
                }
                if (k == 1) return g.p("eval {{incr {s}}}", .{g.v()});
                try g.p("eval \"set {s} ${s}\"", .{ g.v(), g.v() });
            },
            .rename_core => {
                const c = r.pick([]const u8, &core);
                try g.p("rename {s} _{s}_s; proc {s} args {{tailcall _{s}_s {{*}}$args}}\n", .{ c, c, c, c });
                g.depth += 1;
                for (0..1 + r.below(3)) |_| try g.stmt();
                g.depth -= 1;
                try g.indent();
                try g.p("rename {s} {{}}; rename _{s}_s {s}", .{ c, c, c });
            },
            .rename_proc => {
                if (g.nprocs == 0) return g.w("incr b");
                const k = r.below(g.nprocs);
                try g.p("rename p{d} p{d}_r; set {s} [info commands p{d}*]; rename p{d}_r p{d}", .{ k, k, g.v(), k, k, k });
            },
            .trace => {
                const k = r.below(3);
                const vn = g.v();
                if (k == 0) return g.p("trace add variable {s} write {{apply {{{{n1 n2 op}} {{incr ::tc}}}}}}", .{vn});
                if (k == 1) return g.p("trace add variable {s} read {{apply {{{{n1 n2 op}} {{upvar 1 $n1 x; set x 1000}}}}}}", .{vn});
                try g.p("trace add variable {s} unset {{apply {{{{n1 n2 op}} {{incr ::tc 100}}}}}}", .{vn});
            },
            .unset => try g.p("unset {s}{s}", .{ r.pick([]const u8, &.{ "", "-nocomplain " }), g.v() }),
            .coroutine => {
                const n = try g.name("co");
                if (g.nprocs > 0 and r.chance(50)) {
                    const k = r.below(g.nprocs);
                    try g.p("set rc [catch {{coroutine {s} ", .{n});
                    try g.callText(@intCast(k));
                    try g.w("} m]; puts \"");
                    try g.p("{s} $rc $m\"; ", .{n});
                } else {
                    try g.p("coroutine {s} apply {{{{n}} {{set s 0; for {{set i 0}} {{$i < $n}} {{incr i}} {{incr s [yield $s]}}; return $s}}}} {d}; ", .{ n, r.below(6) });
                }
                try g.p("for {{set j 0}} {{$j < {d}}} {{incr j}} {{set rc [catch {{{s} $j}} m]; puts \"{s} $rc $m\"; if {{$rc}} break}}", .{ r.below(8), n, n });
            },
            .yield => try g.p("set {s} [yield ${s}]", .{ g.v(), g.v() }),
            .apply => {
                try g.p("set {s} [apply {{{{a {{b 2}}}} ", .{g.v()});
                const saved = .{ g.inner, g.loops, g.nlvars };
                g.inner = true;
                g.loops = 0;
                g.nlvars = 0;
                try g.block(3);
                g.inner, g.loops, g.nlvars = saved;
                try g.w("} ");
                try g.word();
                try g.w("]");
            },
            .namespace => {
                const n = try g.name("ns");
                const c = r.pick([]const u8, &core);
                try g.p("namespace eval {s} {{proc {s} args {{return ns-{s}}}; proc t {{a}} ", .{ n, c, c });
                const saved = .{ g.inner, g.loops, g.nlvars };
                g.inner = true;
                g.loops = 0;
                g.nlvars = 0;
                try g.block(4);
                g.inner, g.loops, g.nlvars = saved;
                try g.p("}}; set rc [catch {{{s}::t ", .{n});
                try g.word();
                try g.p("}} m]; puts \"{s} $rc $m\"", .{n});
            },
            .puts => {
                if (r.chance(50)) return g.p("puts \"v ${s}\"", .{g.operandVar()});
                try g.p("puts [list ${s} ${s}]", .{ g.v(), r.pick([]const u8, &.{ "l", "s", "dd", "p" }) });
            },
            .call => {
                const top = g.cur orelse g.nprocs;
                const k: u32 = @intCast(r.below(top));
                try g.p("set {s} [", .{g.v()});
                try g.callText(k);
                try g.w("]");
            },
        }
    }

    fn index(g: *Gen) E!void {
        const k = g.r.below(10);
        if (k < 4) return g.p("{d}", .{g.r.below(5)});
        if (k < 6) return g.w(g.r.pick([]const u8, &.{ "end", "end-1", "end+1", "-1" }));
        if (k < 8) return g.p("${s}", .{g.operandVar()});
        return g.int();
    }

    /// Sets the variables after the first `from` of `vars`. Most get an
    /// integer.
    fn initVars(g: *Gen, from: usize) E!void {
        try g.w("  ");
        for (vars[from..]) |vn| {
            if (g.r.chance(15)) continue;
            try g.p("set {s} ", .{vn});
            if (g.r.chance(75)) try g.int() else try g.lit();
            try g.w("; ");
        }
        try g.w("\n");
    }

    /// The whole program.
    fn program(g: *Gen) E!void {
        try g.w("set ::tc 0; set g0 0; set g1 x; set l {1 2 3}; set s {}; set dd {k0 1}\n");
        try g.initVars(0);
        const n: u32 = @intCast(1 + g.r.below(6));
        for (0..n) |k| {
            const np: u32 = @intCast(g.r.below(5));
            g.params[k] = np;
            g.cur = @intCast(k);
            try g.p("proc p{d} {{", .{k});
            for (0..np) |j| {
                if (j > 0) try g.w(" ");
                try g.w(vars[j]);
            }
            try g.w("} {\n");
            try g.w("  set l {1 2 3}; set s {}; set dd {k0 1}\n");
            try g.initVars(np);
            for (0..2 + g.r.below(8)) |_| try g.stmt();
            if (g.r.chance(70)) {
                try g.w("  return [list $l $s ");
                try g.word();
                try g.w("]\n");
            }
            try g.w("}\n");
            g.nprocs += 1;
        }
        g.cur = null;
        // Statements at the top level, each one in a catch.
        for (0..g.r.below(4)) |_| {
            try g.w("set rc [catch {\n");
            g.depth += 1;
            try g.stmt();
            g.depth -= 1;
            try g.w("} m]; puts \"top $rc $m\"; ");
            try g.printErr("top");
            try g.w("\n");
        }
        // Two calls of each proc: the default threshold compiles at the
        // second.
        for (0..2) |_| {
            for (0..n) |k| {
                try g.w("set rc [catch {");
                try g.callText(@intCast(k));
                try g.p("}} m]; puts \"r{d} $rc $m\"; ", .{k});
                try g.printErr("r");
                try g.w("\n");
            }
        }
        try g.w("puts \"tc $::tc g0 $g0\"\n");
        if (g.r.chance(25)) {
            try g.callText(@intCast(g.r.below(n)));
            try g.w("\n");
        }
    }
};

/// The program of `seed`. `mark` adds the calls of `_hit`, with no other
/// change.
fn makeProgram(a: Allocator, seed: u64, mark: bool) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var g: Gen = .{ .r = Rng.init(seed, 0), .a = arena.allocator(), .mark = mark };
    try g.program();
    return a.dupe(u8, g.out.items);
}

// ---- The runs ----

/// One way to run a program.
const Mode = struct {
    name: []const u8,
    jit: bool,
    threshold: u32 = 0,
    tier2: bool = false,
    tier2_count: u32 = 1000,
};

/// The reference is the first mode. A new tier adds rows here.
const tier1_modes = [_]Mode{
    .{ .name = "interp", .jit = false },
    .{ .name = "jit-t0", .jit = true, .threshold = 0 },
    .{ .name = "jit-default", .jit = true, .threshold = 2 },
};

const tier2_modes = tier1_modes ++ [_]Mode{
    .{ .name = "tier2-entry", .jit = true, .threshold = 0, .tier2 = true, .tier2_count = 1 },
    .{ .name = "tier2-default", .jit = true, .threshold = 2, .tier2 = true },
};

const Config = struct {
    steps: u64 = 2_000_000,
    mem: usize = 64 << 20,
    stress: u32 = 0,
    /// Stress mode 1: the allocation that the first compile fails.
    fail_from: u32 = 1,
};

/// The counts of one run that are not compared.
const Extra = struct {
    peak: usize = 0,
    steps: u64 = 0,
    ins: u64 = 0,
    compiled: u64 = 0,
    /// The loops that compiled to tier 2, and the exits of tier 2 code.
    tier2: u64 = 0,
    exits: u64 = 0,
    /// True when the run reached the cap of `Cap`.
    capped: bool = false,
};

/// An allocator with a cap on the bytes in use. The memory limit of a
/// script is checked at the safe points of the step, so one command can
/// allocate far more than the limit before the check. The cap keeps
/// such a program from using all memory of the machine. A run that
/// reaches the cap is not compared.
const Cap = struct {
    child: Allocator,
    used: usize = 0,
    cap: usize,
    hit: bool = false,

    fn allocator(c: *Cap) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn room(c: *Cap, n: usize) bool {
        if (n > c.cap -| c.used) {
            c.hit = true;
            return false;
        }
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Cap = @ptrCast(@alignCast(ctx));
        if (!c.room(len)) return null;
        const p = c.child.rawAlloc(len, al, ra) orelse return null;
        c.used += len;
        return p;
    }

    fn resize(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
        const c: *Cap = @ptrCast(@alignCast(ctx));
        if (n > m.len and !c.room(n - m.len)) return false;
        if (!c.child.rawResize(m, al, n, ra)) return false;
        c.used = c.used - m.len + n;
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const c: *Cap = @ptrCast(@alignCast(ctx));
        if (n > m.len and !c.room(n - m.len)) return null;
        const p = c.child.rawRemap(m, al, n, ra) orelse return null;
        c.used = c.used - m.len + n;
        return p;
    }

    fn free(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const c: *Cap = @ptrCast(@alignCast(ctx));
        c.child.rawFree(m, al, ra);
        c.used -= m.len;
    }
};

var hits: [n_items]bool = @splat(false);

fn cmdHit(it: *Interp, argv: []const Value, _: ?*tcl.interp.Cmd) tcl.Error!Value {
    const k = argv[1].asInt() orelse 0;
    if (k >= 0 and k < n_items) hits[@intCast(k)] = true;
    _ = it;
    return Value.empty;
}

fn collect(ctx: ?*anyopaque, bytes: []const u8) void {
    const s: *Sink = @ptrCast(@alignCast(ctx.?));
    s.buf.appendSlice(s.a, bytes) catch {};
}

const Sink = struct { buf: std.ArrayList(u8), a: Allocator };

/// Runs `text` in a new interpreter and writes each compared field to
/// `out`.
fn runOnce(a: Allocator, text: []const u8, mode: Mode, cfg: Config, out: *std.ArrayList(u8), extra: *Extra, coverage: bool) !void {
    out.clearRetainingCapacity();
    var cap: Cap = .{ .child = a, .cap = 256 << 20 };
    var it: Interp = undefined;
    try it.init(cap.allocator());
    defer it.deinit();
    var sink: Sink = .{ .buf = .empty, .a = cap.allocator() };
    defer sink.buf.deinit(sink.a);
    it.output = .{ .ctx = &sink, .write = collect };
    it.gc_on = false;
    it.mem_limit = cfg.mem;
    it.step_limit = cfg.steps;
    if (coverage) try it.register("_hit", cmdHit);
    if (mode.jit) {
        const opts: tcl.jit.Options = .{ .threshold = mode.threshold, .tier2 = mode.tier2, .tier2_count = mode.tier2_count, .stress = cfg.stress, .fail_from = cfg.fail_from };
        if (!it.enableJit(opts)) return error.NoJit;
    }
    if (it.eval(text)) |v| {
        try out.print(a, "result: {s}\n", .{it.str(v) catch "?"});
    } else |e| {
        try out.print(a, "error {t}: {s}\n", .{ e, it.str(it.result) catch "" });
        if (e == error.TclError) it.finishError() catch {};
    }
    const info = it.getVarPlain("::errorInfo") catch Value.empty;
    const code = it.getVarPlain("::errorCode") catch Value.empty;
    try out.print(a, "errorInfo: {s}\nerrorCode: {s}\nsteps: {d}\nmem: {d}\noutput:\n{s}", .{
        it.str(info) catch "?", it.str(code) catch "?", cfg.steps - it.step_limit, it.memUsed(), sink.buf.items,
    });
    extra.* = .{ .peak = it.counter.mem_peak, .steps = cfg.steps - it.step_limit, .capped = cap.hit };
    if (it.jit) |s| {
        extra.ins = s.stats.ins;
        extra.compiled = s.stats.compiled;
        extra.tier2 = s.stats.tier2;
        extra.exits = s.stats.exits;
    }
}

const Fuzz = struct {
    a: Allocator,
    io: Io,
    modes: []const Mode,
    cfg: Config,
    out_dir: []const u8,
    expect_diff: bool,
    ref: std.ArrayList(u8) = .empty,
    got: std.ArrayList(u8) = .empty,
    programs: u64 = 0,
    runs: u64 = 0,
    ins: u64 = 0,
    compiled: u64 = 0,
    marked: u64 = 0,
    reached: [n_items]u64 = @splat(0),
    stopped_steps: u64 = 0,
    stopped_mem: u64 = 0,
    diffs: u64 = 0,
    /// Programs that reached the nesting limit. They are not compared.
    deep: u64 = 0,
    /// Runs that reached the cap of the allocator. They are not compared.
    capped: u64 = 0,
    /// The runs of the tier 2 modes with the full limits, the runs of
    /// them with at least one loop in tier 2, the loops that compiled to
    /// tier 2, and the exits of tier 2 code.
    t2_runs: u64 = 0,
    t2_hit: u64 = 0,
    t2_loops: u64 = 0,
    t2_exits: u64 = 0,

    /// Runs `text` in `mode` and in the reference with the same config,
    /// and compares. True when both are equal.
    fn pair(f: *Fuzz, text: []const u8, mode: Mode, cfg: Config) !bool {
        var x: Extra = .{};
        try runOnce(f.a, text, f.modes[0], cfg, &f.ref, &x, false);
        if (x.capped) {
            f.capped += 1;
            return true;
        }
        return f.against(text, mode, cfg);
    }

    /// Compares a run of `mode` with the reference in `f.ref`.
    fn against(f: *Fuzz, text: []const u8, mode: Mode, cfg: Config) !bool {
        var x: Extra = .{};
        try runOnce(f.a, text, mode, cfg, &f.got, &x, false);
        f.runs += 1;
        if (x.capped) {
            f.capped += 1;
            return true;
        }
        if (mode.jit and mode.threshold == 0 and cfg.steps == f.cfg.steps and cfg.mem == f.cfg.mem) {
            f.ins += x.ins;
            f.compiled += x.compiled;
        }
        if (mode.tier2 and cfg.steps == f.cfg.steps and cfg.mem == f.cfg.mem) {
            f.t2_runs += 1;
            f.t2_loops += x.tier2;
            f.t2_exits += x.exits;
            if (x.tier2 > 0) f.t2_hit += 1;
        }
        return std.mem.eql(u8, f.ref.items, f.got.items);
    }

    /// Runs one program in each mode and with random limits. Returns
    /// false after a difference.
    fn one(f: *Fuzz, text: []const u8, seed: u64, label: []const u8) !bool {
        // Stress mode 1: a random first allocation to fail, so most
        // compiles of a small program pass and the other modes also run.
        var fr = Rng.init(seed, 3);
        f.cfg.fail_from = @intCast(1 + fr.below(40));
        var x: Extra = .{};
        try runOnce(f.a, text, f.modes[0], f.cfg, &f.ref, &x, false);
        f.programs += 1;
        if (x.capped) {
            f.capped += 1;
            return true;
        }
        if (std.mem.indexOf(u8, f.ref.items, "step limit reached") != null) f.stopped_steps += 1;
        if (std.mem.indexOf(u8, f.ref.items, "too much memory") != null) f.stopped_mem += 1;
        // A recursion with no end stops at the native stack limit, and
        // the JIT uses less native stack for a call level, so it can go
        // deeper. The tool checks only that each mode stops at the limit.
        if (std.mem.indexOf(u8, f.ref.items, "too many nested evaluations") != null) {
            f.deep += 1;
            for (f.modes[1..]) |m| {
                var y: Extra = .{};
                try runOnce(f.a, text, m, f.cfg, &f.got, &y, false);
                f.runs += 1;
                if (std.mem.indexOf(u8, f.got.items, "too many nested evaluations") == null) return f.report(text, seed, label, m, f.cfg);
            }
            return true;
        }
        for (f.modes[1..]) |m| {
            if (!try f.against(text, m, f.cfg)) return f.report(text, seed, label, m, f.cfg);
        }
        var r = Rng.init(seed, 1);
        // A step limit inside the run, and a memory limit inside the peak.
        const jm = f.modes[1 + @as(usize, @intCast(r.below(f.modes.len - 1)))];
        var c = f.cfg;
        c.steps = r.below(x.steps + 1);
        if (!try f.pair(text, jm, c)) return f.report(text, seed, label, jm, c);
        c = f.cfg;
        const base: usize = 64 << 10;
        c.mem = base + @as(usize, @intCast(r.below(@max(x.peak, base) - base + 1)));
        if (!try f.pair(text, jm, c)) return f.report(text, seed, label, jm, c);
        return true;
    }

    fn report(f: *Fuzz, text: []const u8, seed: u64, label: []const u8, m: Mode, c: Config) !bool {
        f.diffs += 1;
        Io.Dir.cwd().createDirPath(f.io, f.out_dir) catch {};
        const path = try std.fmt.allocPrint(f.a, "{s}/diff-{s}.tcl", .{ f.out_dir, label });
        defer f.a.free(path);
        var file: std.ArrayList(u8) = .empty;
        defer file.deinit(f.a);
        try file.print(f.a, "# jit-fuzz: seed {d}, mode {s}, step limit {d}, memory limit {d}, stress {d}, first failed allocation {d}\n", .{ seed, m.name, c.steps, c.mem, c.stress, c.fail_from });
        try file.appendSlice(f.a, text);
        try file.appendSlice(f.a, "\n# The reference:\n");
        try comment(f.a, &file, f.ref.items);
        try file.appendSlice(f.a, "# The mode:\n");
        try comment(f.a, &file, f.got.items);
        Io.Dir.cwd().writeFile(f.io, .{ .sub_path = path, .data = file.items }) catch |e| {
            std.debug.print("cannot write {s}: {t}\n", .{ path, e });
        };
        std.debug.print("DIFF {s}: mode {s}, step limit {d}, memory limit {d}: {s}\n", .{ label, m.name, c.steps, c.mem, path });
        return false;
    }

    fn cover(f: *Fuzz, seed: u64) !void {
        const text = try makeProgram(f.a, seed, true);
        defer f.a.free(text);
        hits = @splat(false);
        var x: Extra = .{};
        try runOnce(f.a, text, f.modes[0], f.cfg, &f.got, &x, true);
        f.marked += 1;
        for (hits, 0..) |h, k| f.reached[k] += @intFromBool(h);
    }

    fn summary(f: *Fuzz) void {
        std.debug.print("programs: {d}, runs: {d}, differences: {d}\n", .{ f.programs, f.runs + f.programs, f.diffs });
        if (f.programs == 0) return;
        const pf: f64 = @floatFromInt(f.programs);
        std.debug.print("mean bytecode instructions compiled at threshold 0: {d:.1} in {d:.2} functions\n", .{ @as(f64, @floatFromInt(f.ins)) / pf, @as(f64, @floatFromInt(f.compiled)) / pf });
        std.debug.print("programs that reached the step limit: {d}, the memory limit: {d}, the nesting limit (depth not compared): {d}\n", .{ f.stopped_steps, f.stopped_mem, f.deep });
        std.debug.print("runs that reached the cap of 256 MiB (not compared): {d}\n", .{f.capped});
        if (f.t2_runs > 0) std.debug.print("tier 2: {d} loops compiled in {d} of {d} runs of the tier 2 modes, {d} exits\n", .{ f.t2_loops, f.t2_hit, f.t2_runs, f.t2_exits });
        if (f.marked == 0) return;
        std.debug.print("share of {d} sampled programs that ran each item:\n", .{f.marked});
        const mf: f64 = @floatFromInt(f.marked);
        for (f.reached, 0..) |n, k| {
            std.debug.print("  {s}: {d:.1} %\n", .{ @tagName(@as(Item, @enumFromInt(k))), 100.0 * @as(f64, @floatFromInt(n)) / mf });
        }
    }
};

fn comment(a: Allocator, file: *std.ArrayList(u8), text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try file.appendSlice(a, "#   ");
        try file.appendSlice(a, line);
        try file.append(a, '\n');
    }
}

const usage =
    \\usage: jit-fuzz [--seed N] [--count N] [--seconds N] [--tier2] [--stress N]
    \\                [--expect-diff] [--out DIR] [--print N] [--verbose]
    \\                [--asm FILE] [--asm-a64 FILE] [--verify]
    \\                [--corpus DIR ...]
    \\
;

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var seed: u64 = 1;
    var count: u64 = 1000;
    var seconds: ?u64 = null;
    var tier2 = false;
    var stress: u32 = 0;
    var expect_diff = false;
    var out_dir: []const u8 = "zig-out/jit-fuzz";
    var corpus: std.ArrayList([]const u8) = .empty;
    defer corpus.deinit(a);
    var print_seed: ?u64 = null;
    var verbose = false;
    var asm_file: ?[]const u8 = null;
    var asm_a64_file: ?[]const u8 = null;
    var verify_mode = false;
    var k: usize = 1;
    while (k < args.len) : (k += 1) {
        const arg: []const u8 = args[k];
        const has_value = k + 1 < args.len;
        if (std.mem.eql(u8, arg, "--seed") and has_value) {
            k += 1;
            seed = try std.fmt.parseInt(u64, args[k], 10);
        } else if (std.mem.eql(u8, arg, "--count") and has_value) {
            k += 1;
            count = try std.fmt.parseInt(u64, args[k], 10);
        } else if (std.mem.eql(u8, arg, "--seconds") and has_value) {
            k += 1;
            seconds = try std.fmt.parseInt(u64, args[k], 10);
            count = std.math.maxInt(u64);
        } else if (std.mem.eql(u8, arg, "--stress") and has_value) {
            k += 1;
            stress = try std.fmt.parseInt(u32, args[k], 10);
        } else if (std.mem.eql(u8, arg, "--out") and has_value) {
            k += 1;
            out_dir = args[k];
        } else if (std.mem.eql(u8, arg, "--corpus") and has_value) {
            k += 1;
            try corpus.append(a, args[k]);
        } else if (std.mem.eql(u8, arg, "--print") and has_value) {
            k += 1;
            print_seed = try std.fmt.parseInt(u64, args[k], 10);
        } else if (std.mem.eql(u8, arg, "--tier2")) {
            tier2 = true;
        } else if (std.mem.eql(u8, arg, "--asm") and has_value) {
            k += 1;
            asm_file = args[k];
        } else if (std.mem.eql(u8, arg, "--asm-a64") and has_value) {
            k += 1;
            asm_a64_file = args[k];
        } else if (std.mem.eql(u8, arg, "--verify")) {
            verify_mode = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--expect-diff")) {
            expect_diff = true;
        } else {
            std.debug.print("{s}", .{usage});
            std.process.exit(2);
        }
    }
    if (print_seed) |s| {
        const text = try makeProgram(a, s, false);
        defer a.free(text);
        std.debug.print("{s}", .{text});
        return;
    }
    if (asm_file) |path| return asmCheck(a, io, path);
    if (asm_a64_file) |path| return asmCheckA64(a, io, path);
    if (!tcl.jit.built) {
        std.debug.print("this build has no JIT\n", .{});
        std.process.exit(2);
    }
    var f: Fuzz = .{
        .a = a,
        .io = io,
        .modes = if (tier2) &tier2_modes else &tier1_modes,
        .cfg = .{ .stress = stress },
        .out_dir = out_dir,
        .expect_diff = expect_diff,
    };
    defer f.ref.deinit(a);
    defer f.got.deinit(a);
    const start = Io.Clock.awake.now(io);
    if (verify_mode) {
        const opts: tcl.jit.Options = .{ .threshold = 0, .tier2 = tier2, .tier2_count = 1, .stress = stress };
        return verifyFuzz(a, io, seed, count, seconds, start, verbose, opts);
    }
    var ok = true;
    if (corpus.items.len > 0) {
        f.cfg.steps = 200_000;
        ok = try runCorpus(&f, corpus.items);
    } else {
        var n: u64 = 0;
        while (n < count) : (n += 1) {
            const s = seed +% n;
            const text = try makeProgram(a, s, false);
            defer a.free(text);
            var label_buf: [32]u8 = undefined;
            const label = try std.fmt.bufPrint(&label_buf, "{d}", .{s});
            if (verbose) std.debug.print("seed {d}\n", .{s});
            if (!try f.one(text, s, label)) {
                ok = false;
                break;
            }
            if (n % 8 == 0) try f.cover(s);
            if (n % 1000 == 999) {
                const secs = @divFloor(start.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_s);
                std.debug.print("{d} programs, {d} s\n", .{ n + 1, secs });
                if (seconds) |limit| if (secs >= limit) break;
            } else if (seconds) |limit| {
                if (n % 50 == 0 and @divFloor(start.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_s) >= limit) break;
            }
        }
    }
    f.summary();
    const secs = @divFloor(start.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_s);
    std.debug.print("seconds: {d}\n", .{secs});
    if (expect_diff) {
        std.debug.print("{s}\n", .{if (ok) "FAIL: the planted bug gave no difference" else "the planted bug gave a difference"});
        std.process.exit(if (ok) 1 else 0);
    }
    if (!ok) std.process.exit(1);
}

/// Runs each `.tcl` file of each folder with eight random limits.
fn runCorpus(f: *Fuzz, dirs: []const []const u8) !bool {
    var ok = true;
    for (dirs) |path| {
        var dir = Io.Dir.cwd().openDir(f.io, path, .{ .iterate = true }) catch |e| {
            std.debug.print("cannot open {s}: {t}\n", .{ path, e });
            return false;
        };
        defer dir.close(f.io);
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| f.a.free(n);
            names.deinit(f.a);
        }
        var iter = dir.iterate();
        while (try iter.next(f.io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".tcl")) continue;
            try names.append(f.a, try f.a.dupe(u8, e.name));
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn lt(_: void, x: []u8, y: []u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (names.items) |n| {
            const text = try dir.readFileAlloc(f.io, n, f.a, .limited(1 << 20));
            defer f.a.free(text);
            std.debug.print("{s}/{s}\n", .{ path, n });
            const h = std.hash.Wyhash.hash(0, n);
            for (0..8) |s| {
                if (!try f.one(text, h +% s, n)) {
                    ok = false;
                    break;
                }
            }
        }
    }
    return ok;
}

// ---- The assembler check ----

const x64 = tcl.jit.parts.x64;

/// Encodes each row of `path` and compares the bytes. A row is
/// `form a b d i k hex`.
fn asmCheck(a: Allocator, io: Io, path: []const u8) !void {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 30));
    defer a.free(text);
    var rows: u64 = 0;
    var bad: u64 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(a);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const form = std.meta.stringToEnum(x64.Form, f.next() orelse return error.BadRow) orelse return error.BadRow;
        const ra = try std.fmt.parseInt(u8, f.next() orelse return error.BadRow, 10);
        const rb = try std.fmt.parseInt(u8, f.next() orelse return error.BadRow, 10);
        const d = try std.fmt.parseInt(i32, f.next() orelse return error.BadRow, 10);
        const i = try std.fmt.parseInt(i32, f.next() orelse return error.BadRow, 10);
        const kk = try std.fmt.parseInt(u8, f.next() orelse return error.BadRow, 10);
        const hex = f.next() orelse return error.BadRow;
        want.clearRetainingCapacity();
        var h: usize = 0;
        while (h + 1 < hex.len) : (h += 2) try want.append(a, try std.fmt.parseInt(u8, hex[h .. h + 2], 16));
        const row: x64.Row = .{ .f = form, .a = ra, .b = rb, .d = d, .i = i, .k = kk, .bytes = want.items };
        var s = x64.Asm.init(a);
        defer s.deinit();
        try x64.encodeRow(&s, row);
        try s.finish();
        rows += 1;
        if (!std.mem.eql(u8, want.items, s.bytes())) {
            if (bad < 20) std.debug.print("{t} a={d} b={d} d={d} i={d} k={d}: want {x} got {x}\n", .{ form, ra, rb, d, i, kk, want.items, s.bytes() });
            bad += 1;
        }
    }
    std.debug.print("rows: {d}, differences: {d}\n", .{ rows, bad });
    if (bad > 0 or rows == 0) std.process.exit(1);
}

const a64 = tcl.jit.parts.a64;

/// `asmCheck` for the rows of `--arch aarch64`: `form a b c i j k hex`.
fn asmCheckA64(a: Allocator, io: Io, path: []const u8) !void {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 30));
    defer a.free(text);
    var rows: u64 = 0;
    var bad: u64 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(a);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const form = std.meta.stringToEnum(a64.Form, f.next() orelse return error.BadRow) orelse return error.BadRow;
        var row: a64.Row = .{ .f = form, .bytes = &.{} };
        row.a = try std.fmt.parseInt(u8, f.next() orelse return error.BadRow, 10);
        row.b = try std.fmt.parseInt(u8, f.next() orelse return error.BadRow, 10);
        row.c = try std.fmt.parseInt(u8, f.next() orelse return error.BadRow, 10);
        row.i = try std.fmt.parseInt(i64, f.next() orelse return error.BadRow, 10);
        row.j = try std.fmt.parseInt(u8, f.next() orelse return error.BadRow, 10);
        row.k = try std.fmt.parseInt(u8, f.next() orelse return error.BadRow, 10);
        const hex = f.next() orelse return error.BadRow;
        want.clearRetainingCapacity();
        var h: usize = 0;
        while (h + 1 < hex.len) : (h += 2) try want.append(a, try std.fmt.parseInt(u8, hex[h .. h + 2], 16));
        var s = a64.Asm.init(a);
        defer s.deinit();
        try a64.encodeRow(&s, row);
        try s.finish();
        rows += 1;
        if (!std.mem.eql(u8, want.items, s.bytes())) {
            if (bad < 20) std.debug.print("{t} a={d} b={d} c={d} i={d} j={d} k={d}: want {x} got {x}\n", .{ form, row.a, row.b, row.c, row.i, row.j, row.k, want.items, s.bytes() });
            bad += 1;
        }
    }
    std.debug.print("rows: {d}, differences: {d}\n", .{ rows, bad });
    if (bad > 0 or rows == 0) std.process.exit(1);
}

// ---- The verifier fuzzer ----

const vm = tcl.jit.parts.vm;
const verifier = tcl.jit.parts.verify;
const Range = std.meta.Child(@FieldType(vm.Code, "ranges"));
const n_ops = @typeInfo(vm.Op).@"enum".fields.len;

const VerifyStats = struct {
    codes: u64 = 0,
    random: u64 = 0,
    accepted: u64 = 0,
    accepted_random: u64 = 0,
    compiled: u64 = 0,
    ran: u64 = 0,
    fallbacks: u64 = 0,
    programs: u64 = 0,
    /// The loops that compiled to tier 2.
    tier2: u64 = 0,
    /// The runs that reached the nesting limit. They are not compared.
    deep: u64 = 0,
};

/// A random operand: small numbers, neighbors of the old value, and
/// numbers at the bounds.
fn operandValue(r: *Rng, old: u32, len: usize) u32 {
    return switch (r.below(8)) {
        0 => 0,
        1 => @intCast(r.below(4)),
        2 => old +% 1,
        3 => old -% 1,
        4, 5 => @intCast(r.below(len + 4)),
        6 => @intCast(r.below(70000)),
        else => r.pick(u32, &.{ std.math.maxInt(u32), std.math.maxInt(u16), 65536, 2048, 2049, 32768 }),
    };
}

/// Writes an opcode byte. 3 % of the bytes are no member of `Op`.
fn setOp(r: *Rng, ins: *vm.Ins) void {
    const b: u8 = if (r.chance(3)) @intCast(n_ops + r.below(256 - n_ops)) else @intCast(r.below(n_ops));
    std.mem.asBytes(ins)[0] = b;
}

/// The procs of `text`, defined with no other command run.
fn defineProcs(it: *Interp, text: []const u8) !void {
    const sc = try it.compile(text);
    for (sc.cmds) |*c| {
        if (c.words.len != 4 or c.words[0].kind != .lit) continue;
        if (!std.mem.eql(u8, try it.str(c.words[0].kind.lit), "proc")) continue;
        _ = it.evalCmd(c) catch {};
    }
}

/// Prints each instruction with its opcode byte.
fn printIns(ins: []const vm.Ins) void {
    for (ins, 0..) |*i, pc| {
        // An instruction that no path reaches can have a byte that is no
        // member of `Op`.
        const b = std.mem.asBytes(i)[0];
        const name = if (std.enums.fromInt(vm.Op, b)) |op| @tagName(op) else "(no opcode)";
        std.debug.print("  {d}: {s} ({d}) x={d} a={d} b={d} c={d}\n", .{ pc, name, b, i.x, i.a, i.b, i.c });
    }
}

/// One interpreter of the verifier fuzzer and its output.
const VSide = struct {
    it: Interp,
    sink: Sink,

    fn init(vs: *VSide, a: Allocator) !void {
        vs.sink = .{ .buf = .empty, .a = a };
        try vs.it.init(a);
        vs.it.gc_on = false;
        vs.it.output = .{ .ctx = &vs.sink, .write = collect };
    }

    fn deinit(vs: *VSide) void {
        vs.it.deinit();
        vs.sink.buf.deinit(vs.sink.a);
    }

    /// The proc `name` and the Code of its body, or null.
    fn body(vs: *VSide, name: []const u8) ?struct { *tcl.interp.Proc, *vm.Code } {
        const it = &vs.it;
        const cmd = it.commands.get(name) orelse return null;
        // A changed code can rename a native command to this name.
        if (cmd.impl != .proc) return null;
        const p = cmd.impl.proc;
        if (p.script == null) p.script = it.compile(it.str(p.body) catch return null) catch return null;
        const base = vm.compileProc(it, p, p.script.?) catch return null;
        return .{ p, base };
    }

    /// Runs `call` with `code` as the body of `p`, and writes each
    /// compared field to `out`.
    fn run(vs: *VSide, a: Allocator, p: *tcl.interp.Proc, code: *vm.Code, call: []const u8, steps: u64, mem: usize, out: *std.ArrayList(u8)) !void {
        const it = &vs.it;
        const saved = p.code;
        defer p.code = saved;
        p.code = code;
        out.clearRetainingCapacity();
        vs.sink.buf.clearRetainingCapacity();
        it.step_limit = steps;
        it.mem_limit = mem;
        if (it.eval(call)) |v| {
            try out.print(a, "result: {s}\n", .{it.str(v) catch "?"});
        } else |e| {
            try out.print(a, "error {t}: {s}\n", .{ e, it.str(it.result) catch "" });
            if (e == error.TclError) it.finishError() catch {};
        }
        const used = steps -% it.step_limit;
        it.step_limit = std.math.maxInt(u64);
        it.mem_limit = std.math.maxInt(usize);
        const info = it.getVarPlain("::errorInfo") catch Value.empty;
        try out.print(a, "errorInfo: {s}\nsteps: {d}\nmem: {d}\noutput:\n{s}", .{ it.str(info) catch "?", used, it.memUsed(), vs.sink.buf.items });
    }
};

/// Each `Code` that the verifier accepts runs in two interpreters with
/// the same history: one with the JIT and one without it. The result,
/// `errorInfo`, the steps used, the memory count, and the output must be
/// equal. So the tool finds a wrong result and a pass of the step limit
/// or the memory limit, and a crash or a failed safety check stops the
/// process. A run of the JIT that runs longer than one second is a hang:
/// the step limit of each run is at most 10 000.
fn verifyFuzz(a: Allocator, io: Io, seed: u64, count: u64, seconds: ?u64, start: Io.Timestamp, verbose: bool, opts: tcl.jit.Options) !void {
    var st: VerifyStats = .{};
    var n: u64 = 0;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(a);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(a);
    outer: while (n < count) {
        const ps = seed +% st.programs;
        st.programs += 1;
        const text = try makeProgram(a, ps, false);
        defer a.free(text);
        var arena_state = std.heap.ArenaAllocator.init(a);
        defer arena_state.deinit();
        const ar = arena_state.allocator();
        const jit_side = try a.create(VSide);
        defer a.destroy(jit_side);
        try jit_side.init(a);
        defer jit_side.deinit();
        const ref = try a.create(VSide);
        defer a.destroy(ref);
        try ref.init(a);
        defer ref.deinit();
        if (!jit_side.it.enableJit(opts)) return error.NoJit;
        defineProcs(&jit_side.it, text) catch continue;
        defineProcs(&ref.it, text) catch continue;
        var r = Rng.init(ps, 2);
        for (0..32) |_| {
            if (n >= count) break :outer;
            const k = r.below(6);
            if (verbose) std.debug.print("program {d} code {d}\n", .{ ps, st.codes });
            var name_buf: [8]u8 = undefined;
            const pname = try std.fmt.bufPrint(&name_buf, "p{d}", .{k});
            const jb = jit_side.body(pname) orelse continue;
            const rb = ref.body(pname) orelse continue;
            const p = jb[0];
            const base = jb[1];
            // The changes go to both Code values, so their tables must
            // have the same sizes.
            if (base.ins.len != rb[1].ins.len or base.ranges.len != rb[1].ranges.len) continue;
            n += 1;
            st.codes += 1;
            var code = base.*;
            const random = r.chance(30);
            var ins: []vm.Ins = undefined;
            if (random) {
                st.random += 1;
                ins = try ar.alloc(vm.Ins, 1 + r.below(48));
                for (ins) |*i| {
                    i.* = .{ .op = .pop };
                    setOp(&r, i);
                    i.x = @intCast(r.below(4));
                    i.a = operandValue(&r, 0, ins.len);
                    i.b = operandValue(&r, 0, ins.len);
                    i.c = operandValue(&r, 0, ins.len);
                }
                if (r.chance(70)) ins[ins.len - 1] = .{ .op = .ret };
                code.ranges = &.{};
            } else {
                ins = try ar.dupe(vm.Ins, base.ins);
                for (0..1 + r.below(4)) |_| {
                    const i = &ins[@intCast(r.below(ins.len))];
                    switch (r.below(6)) {
                        0 => setOp(&r, i),
                        1 => i.x = @intCast(r.below(8)),
                        2 => i.a = operandValue(&r, i.a, ins.len),
                        3 => i.b = operandValue(&r, i.b, ins.len),
                        4 => i.c = operandValue(&r, i.c, ins.len),
                        else => {
                            const ranges = try ar.dupe(Range, code.ranges);
                            if (ranges.len > 0) {
                                const rg = &ranges[@intCast(r.below(ranges.len))];
                                switch (r.below(4)) {
                                    0 => rg.brk = operandValue(&r, rg.brk, ins.len),
                                    1 => rg.cont = operandValue(&r, rg.cont, ins.len),
                                    2 => rg.depth = operandValue(&r, rg.depth, 4),
                                    else => rg.end = operandValue(&r, rg.end, ins.len),
                                }
                            }
                            code.ranges = ranges;
                        },
                    }
                }
            }
            code.ins = ins;
            code.jit = null;
            code.jit_gen = 0;
            code.jit_calls = 0;
            code.jit_state = .untried;
            // Most runs have the step limit of 10 000. One in four has a
            // step limit below the steps of a few passes of a loop, and
            // one in four has a memory limit a little above the count now.
            const steps: u64 = if (r.chance(25)) r.below(64) else 10_000;
            const mem_room: ?usize = if (r.chance(25)) @intCast(r.below(256 << 10)) else null;
            var info = (try verifier.verify(a, &code)) orelse continue;
            info.deinit(a);
            st.accepted += 1;
            if (random) st.accepted_random += 1;
            const held = try ar.create(vm.Code);
            held.* = code;
            if (tcl.jit.prepare(&jit_side.it, held) == null) continue;
            st.compiled += 1;
            // The same instructions and ranges with the tables of the
            // reference interpreter. It has no JIT.
            const held_ref = try ar.create(vm.Code);
            held_ref.* = rb[1].*;
            held_ref.ins = code.ins;
            held_ref.ranges = code.ranges;
            var call: std.ArrayList(u8) = .empty;
            try call.appendSlice(ar, pname);
            for (0..p.params.len) |_| try call.appendSlice(ar, " 1");
            const before = jit_side.it.jit.?.stats.fallbacks;
            const t2_before = jit_side.it.jit.?.stats.tier2;
            if (verbose) {
                std.debug.print("run {s} steps {d}\n", .{ pname, steps });
                printIns(held.ins);
            }
            const mem = if (mem_room) |m| ref.it.memUsed() +| m else std.math.maxInt(usize);
            try ref.run(a, rb[0], held_ref, call.items, steps, mem, &want);
            const t0 = Io.Clock.awake.now(io);
            try jit_side.run(a, p, held, call.items, steps, mem, &got);
            const ms = @divFloor(t0.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_ms);
            st.fallbacks += jit_side.it.jit.?.stats.fallbacks - before;
            st.ran += 1;
            st.tier2 += jit_side.it.jit.?.stats.tier2 - t2_before;
            const deep = std.mem.indexOf(u8, want.items, "too many nested evaluations") != null;
            if (deep) st.deep += 1;
            if (ms > 1000 or (!deep and !std.mem.eql(u8, want.items, got.items))) {
                std.debug.print("DIFFERENCE: program {d}, code {d}, proc {s}, steps {d}, memory room {?d}, {d} ms\n", .{ ps, st.codes - 1, pname, steps, mem_room, ms });
                printIns(held.ins);
                std.debug.print("ranges: {any}\n--- interpreter\n{s}\n--- jit\n{s}\n", .{ held.ranges, want.items, got.items });
                std.process.exit(1);
            }
        }
        if (st.programs % 2000 == 0) {
            const secs = @divFloor(start.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_s);
            std.debug.print("{d} codes, {d} accepted, {d} s\n", .{ st.codes, st.accepted, secs });
            if (seconds) |limit| if (secs >= limit) break;
        }
    }
    const pct = struct {
        fn f(x: u64, y: u64) f64 {
            return if (y == 0) 0 else 100.0 * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(y));
        }
    }.f;
    std.debug.print("codes: {d} ({d} random, {d} changed), programs: {d}\n", .{ st.codes, st.random, st.codes - st.random, st.programs });
    std.debug.print("accepted: {d} ({d:.2} %): random {d} ({d:.2} %), changed {d} ({d:.2} %)\n", .{
        st.accepted,                       pct(st.accepted, st.codes),                                 st.accepted_random,
        pct(st.accepted_random, st.random), st.accepted - st.accepted_random, pct(st.accepted - st.accepted_random, st.codes - st.random),
    });
    std.debug.print("compiled: {d}, ran: {d}, entries that fell back to exec: {d}\n", .{ st.compiled, st.ran, st.fallbacks });
    std.debug.print("loops in tier 2: {d}, runs at the nesting limit (not compared): {d}\n", .{ st.tier2, st.deep });
    const secs = @divFloor(start.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_s);
    std.debug.print("seconds: {d}\n", .{secs});
}

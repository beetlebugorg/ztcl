//! The expression language of `expr`, `if`, `while`, and `for`.
//!
//! `compile` parses the text once into a tree of nodes. `eval` runs the
//! tree. The interpreter caches the tree of a braced expression, so a
//! loop does not parse its condition again.
//!
//! An integer that does not fit in 64 bits continues in `bigint.zig`,
//! as in Tcl. The operators check for overflow and take the slow path
//! only when it happens.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const noise = @import("noise.zig");
const bigint = @import("bigint.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Error = interp.Error;
const mathns = @import("mathns.zig");
const diag = @import("expr_diag.zig");

pub const UnOp = enum { neg, pos, not, bitnot };

pub const BinOp = enum {
    pow,
    mul,
    div,
    mod,
    add,
    sub,
    shl,
    shr,
    lt,
    gt,
    le,
    ge,
    eq,
    ne,
    streq,
    strne,
    in,
    ni,
    bitand,
    bitxor,
    bitor,
    land,
    lor,

    pub fn text(op: BinOp) []const u8 {
        return switch (op) {
            .pow => "**",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .add => "+",
            .sub => "-",
            .shl => "<<",
            .shr => ">>",
            .lt => "<",
            .gt => ">",
            .le => "<=",
            .ge => ">=",
            .eq => "==",
            .ne => "!=",
            .streq => "eq",
            .strne => "ne",
            .in => "in",
            .ni => "ni",
            .bitand => "&",
            .bitxor => "^",
            .bitor => "|",
            .land => "&&",
            .lor => "||",
        };
    }

    fn prec(op: BinOp) u8 {
        return switch (op) {
            .pow => 13,
            .mul, .div, .mod => 12,
            .add, .sub => 11,
            .shl, .shr => 10,
            .lt, .gt, .le, .ge => 9,
            .eq, .ne => 8,
            .streq, .strne => 7,
            .in, .ni => 6,
            .bitand => 5,
            .bitxor => 4,
            .bitor => 3,
            .land => 2,
            .lor => 1,
        };
    }
};

/// The smaller of two doubles with a fixed result on each target. A NaN
/// operand gives the other operand. For equal operands, as for -0 and
/// +0, the result is `a`. `@min` leaves the sign of a zero result to
/// the target, so `clamp` and the limits of point procs use this.
pub fn minF(a: f64, b: f64) f64 {
    if (std.math.isNan(a)) return b;
    return if (b < a) b else a;
}

/// The larger of two doubles with the rules of `minF`.
pub fn maxF(a: f64, b: f64) f64 {
    if (std.math.isNan(a)) return b;
    return if (b > a) b else a;
}

/// `clamp(x, lo, hi)` of `expr` and of point procs.
pub fn clamp(x: f64, lo: f64, hi: f64) f64 {
    return minF(maxF(x, lo), hi);
}

pub const Func = enum {
    abs,
    acos,
    asin,
    atan,
    atan2,
    bool,
    ceil,
    cos,
    cosh,
    double,
    entier,
    exp,
    floor,
    fmod,
    hypot,
    int,
    isqrt,
    log,
    log10,
    max,
    min,
    pow,
    rand,
    round,
    sin,
    sinh,
    sqrt,
    srand,
    tan,
    tanh,
    wide,
    // Additions for zslice.
    clamp,
    lerp,
    noise2,
    noise3,

    /// The least and the most arguments.
    pub fn arity(f: Func) [2]usize {
        return switch (f) {
            .rand => .{ 0, 0 },
            .atan2, .fmod, .hypot, .pow, .noise2 => .{ 2, 2 },
            .clamp, .lerp, .noise3 => .{ 3, 3 },
            .max, .min => .{ 1, 255 },
            else => .{ 1, 1 },
        };
    }
};

pub const Node = union(enum) {
    constant: Value,
    variable: interp.VarRef,
    script: *interp.Script,
    parts: []const interp.Part,
    unary: struct { op: UnOp, a: *Node },
    binary: struct { op: BinOp, a: *Node, b: *Node },
    ternary: [3]*Node,
    func: struct { f: Func, args: []const *Node },
    /// A call of a command in `tcl::mathfunc`.
    call: struct { name: []const u8, args: []const *Node },
};

// ---- The parser ----

const ExprParser = struct {
    it: *Interp,
    p: interp.Parser,
    /// The count of nodes. The evaluator recurses once for each level
    /// of the tree, so a limit on the nodes is a limit on its depth.
    nodes: u32 = 0,
    depth: u32 = 0,

    const max_nodes = 2000;
    const max_depth = 200;

    fn fail(e: *ExprParser, comptime fmt: []const u8, args: anytype) Error {
        return e.it.fail(fmt ++ "\nin expression \"{s}\"", args ++ .{e.p.src});
    }

    fn skip(e: *ExprParser) void {
        while (e.p.pos < e.p.src.len and (e.p.src[e.p.pos] == ' ' or (e.p.src[e.p.pos] >= 9 and e.p.src[e.p.pos] <= 13))) e.p.pos += 1;
    }

    fn node(e: *ExprParser, n: Node) Error!*Node {
        e.nodes += 1;
        if (e.nodes > max_nodes) return e.it.fail("the expression is too large", .{});
        const out = try e.it.alloc().create(Node);
        out.* = n;
        return out;
    }

    fn peekBinOp(e: *ExprParser) ?struct { BinOp, usize } {
        const s = e.p.src[e.p.pos..];
        if (s.len == 0) return null;
        const two = if (s.len >= 2) s[0..2] else "";
        const table2 = [_]struct { []const u8, BinOp }{
            .{ "**", .pow },   .{ "<<", .shl }, .{ ">>", .shr },  .{ "<=", .le },  .{ ">=", .ge },
            .{ "==", .eq },    .{ "!=", .ne },  .{ "&&", .land }, .{ "||", .lor }, .{ "eq", .streq },
            .{ "ne", .strne }, .{ "in", .in },  .{ "ni", .ni },
        };
        for (table2) |t| if (std.mem.eql(u8, two, t[0])) {
            return .{ t[1], 2 };
        };
        const op: BinOp = switch (s[0]) {
            '*' => .mul,
            '/' => .div,
            '%' => .mod,
            '+' => .add,
            '-' => .sub,
            '<' => .lt,
            '>' => .gt,
            '&' => .bitand,
            '^' => .bitxor,
            '|' => .bitor,
            else => return null,
        };
        return .{ op, 1 };
    }

    fn ternary(e: *ExprParser) Error!*Node {
        const c = try e.binary(1);
        e.skip();
        if (e.p.pos < e.p.src.len and e.p.src[e.p.pos] == '?') {
            e.p.pos += 1;
            const a = try e.ternary();
            e.skip();
            if (e.p.pos >= e.p.src.len or e.p.src[e.p.pos] != ':') return e.fail("missing operator \":\"", .{});
            e.p.pos += 1;
            const b = try e.ternary();
            return e.node(.{ .ternary = .{ c, a, b } });
        }
        return c;
    }

    fn binary(e: *ExprParser, min_prec: u8) Error!*Node {
        var left = try e.unary();
        while (true) {
            e.skip();
            const op, const len = e.peekBinOp() orelse break;
            const pr = op.prec();
            if (pr < min_prec) break;
            e.p.pos += len;
            // ** groups from right to left.
            const right = try e.binary(if (op == .pow) pr else pr + 1);
            left = try e.node(.{ .binary = .{ .op = op, .a = left, .b = right } });
        }
        return left;
    }

    fn unary(e: *ExprParser) Error!*Node {
        if (e.depth >= max_depth) return e.it.fail("the expression is nested too deep", .{});
        e.depth += 1;
        defer e.depth -= 1;
        e.skip();
        if (e.p.pos >= e.p.src.len) return e.it.fail("missing operand at _@_\nin expression \"{s}_@_\"", .{e.p.src});
        const c = e.p.src[e.p.pos];
        const op: ?UnOp = switch (c) {
            '-' => .neg,
            '+' => .pos,
            '!' => .not,
            '~' => .bitnot,
            else => null,
        };
        if (op) |o| {
            e.p.pos += 1;
            const a = try e.unary();
            // Fold a sign into a number literal.
            if (a.* == .constant) {
                switch (a.constant) {
                    .int => |i| if (o == .neg) {
                        a.constant = .{ .int = 0 -% i };
                        return a;
                    } else if (o == .pos) return a,
                    .double => |d| if (o == .neg) {
                        a.constant = .{ .double = -d };
                        return a;
                    } else if (o == .pos) return a,
                    else => {},
                }
            }
            return e.node(.{ .unary = .{ .op = o, .a = a } });
        }
        return e.primary();
    }

    fn pfail(e: *ExprParser, err: anyerror) Error {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return e.fail("{s}", .{e.p.message});
    }

    fn primary(e: *ExprParser) Error!*Node {
        const s = e.p.src;
        const c = s[e.p.pos];
        switch (c) {
            '(' => {
                e.p.pos += 1;
                const n = try e.ternary();
                e.skip();
                if (e.p.pos >= s.len or s[e.p.pos] != ')') return e.fail("unbalanced open paren", .{});
                e.p.pos += 1;
                return n;
            },
            '$' => {
                const v = (e.p.parseVar() catch |err| return e.pfail(err)) orelse
                    return e.fail("invalid character \"$\"", .{});
                return e.node(.{ .variable = v });
            },
            '[' => {
                e.p.pos += 1;
                const sc = e.p.parseScript(true) catch |err| return e.pfail(err);
                return e.node(.{ .script = sc });
            },
            '"' => {
                e.p.pos += 1;
                var parts: interp.Parts = .{ .a = e.it.alloc() };
                e.p.parseParts(&parts, .quote) catch |err| return e.pfail(err);
                if (e.p.pos >= s.len) return e.fail("missing \"", .{});
                e.p.pos += 1;
                const list = try parts.finish();
                if (list.len == 0) return e.node(.{ .constant = Value.empty });
                if (list.len == 1 and list[0] == .lit) return e.node(.{ .constant = .{ .str = list[0].lit } });
                return e.node(.{ .parts = list });
            },
            '{' => {
                const text = e.p.parseBraced() catch |err| return e.pfail(err);
                return e.node(.{ .constant = .{ .str = text } });
            },
            else => {},
        }
        if (std.ascii.isDigit(c) or c == '.') {
            var i = e.p.pos;
            var is_int = true;
            if (c == '0' and i + 1 < s.len and (s[i + 1] == 'x' or s[i + 1] == 'X' or s[i + 1] == 'b' or s[i + 1] == 'B' or s[i + 1] == 'o' or s[i + 1] == 'O')) {
                i += 2;
                while (i < s.len and std.ascii.isHex(s[i])) i += 1;
            } else {
                while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
                if (i < s.len and s[i] == '.') {
                    is_int = false;
                    i += 1;
                    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
                }
                if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
                    var j = i + 1;
                    if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
                    if (j < s.len and std.ascii.isDigit(s[j])) {
                        is_int = false;
                        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
                        i = j;
                    }
                }
            }
            const text = s[e.p.pos..i];
            e.p.pos = i;
            if (is_int) {
                if (value.parseIntStrict(text)) |n| return e.node(.{ .constant = .{ .int = n } });
                if (try bigint.canonical(e.it, text)) |v| return e.node(.{ .constant = v });
                // An integer such as 08 is a bad octal number in Tcl 8.6.
                return e.fail("invalid number \"{s}\"", .{text});
            }
            if (value.parseDouble(text)) |d| return e.node(.{ .constant = .{ .double = d } });
            return e.fail("invalid number \"{s}\"", .{text});
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            var i = e.p.pos;
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
            const name = s[e.p.pos..i];
            var j = i;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\n')) j += 1;
            if (j < s.len and s[j] == '(') {
                e.p.pos = j + 1;
                var args: std.ArrayList(*Node) = .empty;
                e.skip();
                if (e.p.pos < s.len and s[e.p.pos] == ')') {
                    e.p.pos += 1;
                } else while (true) {
                    try args.append(e.it.alloc(), try e.ternary());
                    e.skip();
                    if (e.p.pos >= s.len) return e.fail("missing close paren", .{});
                    if (s[e.p.pos] == ',') {
                        e.p.pos += 1;
                    } else if (s[e.p.pos] == ')') {
                        e.p.pos += 1;
                        break;
                    } else return e.fail("missing close paren", .{});
                }
                // A function that a script defined or replaced is a command.
                const full = try std.fmt.allocPrint(e.it.alloc(), "tcl::mathfunc::{s}", .{name});
                const f = std.meta.stringToEnum(Func, name) orelse
                    return e.node(.{ .call = .{ .name = full, .args = args.items } });
                if (f != .clamp and f != .lerp and f != .noise2 and f != .noise3) {
                    const known = e.it.findCommand(full);
                    if (known == null or !mathns.isBuiltinFunc(known.?, f)) {
                        return e.node(.{ .call = .{ .name = full, .args = args.items } });
                    }
                }
                try checkArity(e.it, f, args.items.len);
                return e.node(.{ .func = .{ .f = f, .args = args.items } });
            }
            e.p.pos = i;
            if (boolWord(name) != null) return e.node(.{ .constant = .{ .str = name } });
            if (value.parseDouble(name)) |d| return e.node(.{ .constant = .{ .double = d } });
            return e.fail("invalid bareword \"{s}\"", .{name});
        }
        return e.fail("invalid character \"{c}\"", .{c});
    }
};

/// A boolean word of Tcl: a unique prefix of true, yes, false, no, on,
/// or off, in any case. "o" alone is ambiguous.
fn boolWord(s: []const u8) ?bool {
    if (s.len == 0) return null;
    const yes = [_][]const u8{ "true", "yes" };
    const no = [_][]const u8{ "false", "no" };
    for (yes) |w| if (s.len <= w.len and std.ascii.eqlIgnoreCase(s, w[0..s.len])) return true;
    for (no) |w| if (s.len <= w.len and std.ascii.eqlIgnoreCase(s, w[0..s.len])) return false;
    if (std.ascii.eqlIgnoreCase(s, "on")) return true;
    if (s.len >= 2 and s.len <= 3 and std.ascii.eqlIgnoreCase(s, "off"[0..s.len])) return false;
    return null;
}

/// Parses an expression. The tree lives in the arena of the interpreter.
pub fn compile(it: *Interp, text: []const u8) Error!*Node {
    return parse(it, text) catch |e| {
        if (e != error.TclError) return e;
        const r = try it.str(it.result);
        if (std.mem.startsWith(u8, r, "the expression is")) return e;
        const d = (try diag.diagnose(it, text, isBoolWord)) orelse return e;
        const msg = try diag.message(it, text, d);
        const code = d.code orelse return it.fail("{s}", .{msg});
        return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL PARSE EXPR {s}", .{code}), "{s}", .{msg});
    };
}

/// The line that Tcl adds to the errorInfo after a syntax error of an
/// expression.
pub const parseInfo = diag.infoLine;

fn isBoolWord(s: []const u8) bool {
    return boolWord(s) != null;
}

fn parse(it: *Interp, text: []const u8) Error!*Node {
    var e: ExprParser = .{ .it = it, .p = .{ .a = it.alloc(), .src = text } };
    e.skip();
    if (e.p.pos >= text.len) return it.fail("empty expression\nin expression \"{s}\"", .{text});
    const n = try e.ternary();
    e.skip();
    if (e.p.pos < text.len) return e.fail("invalid character \"{c}\"", .{text[e.p.pos]});
    return n;
}

// ---- The evaluator ----

/// The truth of a value: a number, or a word such as "true" or "off".
pub fn truthy(it: *Interp, v: Value) Error!bool {
    switch (v) {
        .int => |i| return i != 0,
        .double => |d| return d != 0,
        else => {
            const s = try it.str(v);
            if (value.parseIntStrict(s)) |i| return i != 0;
            if (bigint.isIntegerText(s)) return true;
            if (value.parseDouble(s)) |d| return d != 0;
            if (boolWord(s)) |b| return b;
            return it.fail("expected boolean value but got \"{s}\"", .{s});
        },
    }
}

/// The number of a value: an `int`, a `double`, or big integer text.
/// Null when the value is not a number.
pub fn numberOf(it: *Interp, v: Value) Error!?Value {
    var cur = v;
    while (cur == .list) {
        if (cur.list.len != 1) return null;
        cur = cur.list.items()[0];
    }
    switch (cur) {
        .int, .double => return cur,
        .str => |s| {
            if (value.parseIntStrict(s)) |i| return .{ .int = i };
            if (bigint.isIntegerText(s)) {
                if (try bigint.canonical(it, s)) |n| return n;
            }
            return cur.asNumber();
        },
        .list => unreachable,
    }
}

/// The result form of `expr`: a string that is a number is the number,
/// so `expr {"0x10"}` gives 16.
pub fn numberForm(it: *Interp, v: Value) Error!Value {
    if (v != .str) return v;
    return (try numberOf(it, v)) orelse v;
}

/// An integer argument of a command: an `int` or big integer text.
pub fn intArg(it: *Interp, v: Value) Error!Value {
    if (v == .int) return v;
    if (try numberOf(it, v)) |n| if (n != .double) return n;
    return it.fail("expected integer but got \"{s}\"", .{try it.str(v)});
}

/// The sum of two integer arguments.
pub fn addInts(it: *Interp, x: Value, y: Value) Error!Value {
    if (x == .int and y == .int) return intOp(it, .add, x.int, y.int);
    return bigint.binary(it, .add, x, y);
}

/// The low 64 bits of an integer argument.
pub fn low64Arg(it: *Interp, v: Value) Error!i64 {
    return bigint.low64(it, try intArg(it, v));
}

fn num(it: *Interp, v: Value, op: []const u8) Error!Value {
    switch (v) {
        .int => return v,
        .double => |d| {
            if (std.math.isNan(d)) return nanOperand(it, op);
            return v;
        },
        else => {
            if (try numberOf(it, v)) |n| {
                if (n == .double and std.math.isNan(n.double)) return nanOperand(it, op);
                return n;
            }
            const s = try it.str(v);
            if (s.len == 0) return it.failCode("ARITH DOMAIN {empty string}", "can't use empty string as operand of \"{s}\"", .{op});
            if (badOctal(s)) return it.failCode("ARITH DOMAIN {invalid octal number}", "can't use invalid octal number as operand of \"{s}\"", .{op});
            return it.failCode("ARITH DOMAIN {non-numeric string}", "can't use non-numeric string as operand of \"{s}\"", .{op});
        },
    }
}

fn nanOperand(it: *Interp, op: []const u8) Error {
    return it.failCode("ARITH DOMAIN {non-numeric floating-point value}", "can't use non-numeric floating-point value as operand of \"{s}\"", .{op});
}

/// True for text in the form of an octal integer with a digit 8 or 9.
fn badOctal(text: []const u8) bool {
    var s = value.trimSpace(text);
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) s = s[1..];
    if (s.len < 2 or s[0] != '0') return false;
    s = s[1..];
    if (s[0] == 'o' or s[0] == 'O') s = s[1..];
    if (s.len == 0) return false;
    var bad = false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
        if (c >= '8') bad = true;
    }
    return bad;
}

/// A numeric operand of the operator `op`, or the error of `expr`.
pub fn operand(it: *Interp, v: Value, op: []const u8) Error!Value {
    return num(it, v, op);
}

/// Checks the count of arguments of a math function.
pub fn checkArity(it: *Interp, f: Func, n: usize) Error!void {
    const ar = f.arity();
    if (n < ar[0]) {
        if (f == .max or f == .min) return it.fail("not enough arguments to math function \"{s}\"", .{@tagName(f)});
        return it.failCode("TCL WRONGARGS", "not enough arguments for math function \"{s}\"", .{@tagName(f)});
    }
    if (n > ar[1]) return it.failCode("TCL WRONGARGS", "too many arguments for math function \"{s}\"", .{@tagName(f)});
}

fn domainError(it: *Interp) Error {
    return it.failCode("ARITH DOMAIN {domain error: argument not in valid range}", "domain error: argument not in valid range", .{});
}

fn toF(v: Value) f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .double => |d| d,
        .str => |s| std.fmt.parseFloat(f64, s) catch std.math.inf(f64),
        else => unreachable,
    };
}

/// An operand of an integer operator: an `int` or big integer text.
fn intOnly(it: *Interp, v: Value, op: []const u8) Error!Value {
    const n = try num(it, v, op);
    if (n == .double) return it.failCode("ARITH DOMAIN {floating-point value}", "can't use floating-point value as operand of \"{s}\"", .{op});
    return n;
}

fn b2v(b: bool) Value {
    return .{ .int = @intFromBool(b) };
}

/// The integer of a constant or of a plain variable that holds an int,
/// with no copy of a value. Null for all other operands.
inline fn intOperand(it: *Interp, n: *const Node) ?i64 {
    switch (n.*) {
        .constant => |*v| return if (v.* == .int) v.int else null,
        .variable => |*r| {
            if (r.index != null) return null;
            const c = it.slotCell(r.name, &@constCast(r).hint) orelse return null;
            return if (c.v == .val and c.v.val == .int) c.v.val.int else null;
        },
        else => return null,
    }
}

pub fn eval(it: *Interp, n: *const Node) Error!Value {
    switch (n.*) {
        .constant => |v| return v,
        .variable => |*r| {
            if (r.index == null) {
                if (it.slotCell(r.name, &@constCast(r).hint)) |c| {
                    if (c.v == .val) return c.v.val;
                }
            }
            return it.readRef(r);
        },
        .script => |s| return it.evalScript(s),
        .parts => |parts| return .{ .str = try it.concatParts(parts) },
        .unary => |*u| {
            return unaryOp(it, u.op, try eval(it, u.a));
        },
        .ternary => |*t| {
            return if (try truthy(it, try eval(it, t[0]))) eval(it, t[1]) else eval(it, t[2]);
        },
        .binary => |*b| {
            if (b.op == .land) {
                if (!try truthy(it, try eval(it, b.a))) return b2v(false);
                return b2v(try truthy(it, try eval(it, b.b)));
            }
            if (b.op == .lor) {
                if (try truthy(it, try eval(it, b.a))) return b2v(true);
                return b2v(try truthy(it, try eval(it, b.b)));
            }
            if (intOperand(it, b.a)) |xi| {
                if (intOperand(it, b.b)) |yi| return intOp(it, b.op, xi, yi);
            }
            const x = try eval(it, b.a);
            const y = try eval(it, b.b);
            // The fast path: two integers.
            if (x == .int and y == .int) return intOp(it, b.op, x.int, y.int);
            return binaryOp(it, b.op, x, y);
        },
        .func => |*f| return callFunc(it, f.f, f.args),
        .call => |*f| {
            const argv = try it.alloc().alloc(Value, f.args.len + 1);
            argv[0] = .{ .str = f.name };
            for (f.args, argv[1..]) |arg, *out| out.* = try eval(it, arg);
            return it.callWords(argv);
        },
    }
}

/// Applies a unary operator to a value.
pub fn unaryOp(it: *Interp, op: UnOp, v: Value) Error!Value {
    switch (op) {
        .not => {
            if (try numberOf(it, v)) |n| {
                if (n == .double and std.math.isNan(n.double)) return nanOperand(it, "!");
            }
            const t = truthy(it, v) catch |err| {
                if (err != error.TclError) return err;
                _ = try num(it, v, "!");
                return err;
            };
            return b2v(!t);
        },
        .bitnot => {
            const x = try intOnly(it, v, "~");
            return if (x == .int) .{ .int = ~x.int } else bigint.bitNot(it, x);
        },
        .neg => {
            const x = try num(it, v, "-");
            return switch (x) {
                .int => |i| if (i == std.math.minInt(i64)) bigint.negate(it, x) else .{ .int = -i },
                .double => |d| .{ .double = -d },
                else => bigint.negate(it, x),
            };
        },
        .pos => return num(it, v, "+"),
    }
}

/// The slow path of an integer operator that overflowed.
pub noinline fn overflowOp(it: *Interp, op: BinOp, x: i64, y: i64) Error!Value {
    @branchHint(.cold);
    return bigint.binary(it, op, .{ .int = x }, .{ .int = y });
}

pub fn intOp(it: *Interp, op: BinOp, x: i64, y: i64) Error!Value {
    switch (op) {
        .add => {
            const r = @addWithOverflow(x, y);
            if (r[1] != 0) return overflowOp(it, op, x, y);
            return .{ .int = r[0] };
        },
        .sub => {
            const r = @subWithOverflow(x, y);
            if (r[1] != 0) return overflowOp(it, op, x, y);
            return .{ .int = r[0] };
        },
        .mul => {
            const r = @mulWithOverflow(x, y);
            if (r[1] != 0) return overflowOp(it, op, x, y);
            return .{ .int = r[0] };
        },
        .div => {
            if (y == 0) return it.failCode("ARITH DIVZERO {divide by zero}", "divide by zero", .{});
            if (y == -1) return if (x == std.math.minInt(i64)) bigint.negate(it, .{ .int = x }) else .{ .int = -x };
            return .{ .int = @divFloor(x, y) };
        },
        .mod => {
            if (y == 0) return it.failCode("ARITH DIVZERO {divide by zero}", "divide by zero", .{});
            if (y == -1) return .{ .int = 0 };
            // The sign of the result is the sign of the divisor.
            // The product of a floored quotient can overflow, so this
            // uses the remainder.
            const rem = @rem(x, y);
            return .{ .int = if (rem != 0 and (rem < 0) != (y < 0)) rem + y else rem };
        },
        .pow => {
            if (y < 0) {
                if (x == 0) return it.failCode("ARITH DOMAIN {exponentiation of zero by negative power}", "exponentiation of zero by negative power", .{});
                if (x == 1) return .{ .int = 1 };
                if (x == -1) return .{ .int = if (@mod(y, 2) == 0) 1 else -1 };
                return .{ .int = 0 };
            }
            var r: i64 = 1;
            var base = x;
            var e: u64 = @intCast(y);
            while (e != 0) {
                if (e & 1 != 0) {
                    const m = @mulWithOverflow(r, base);
                    if (m[1] != 0) return overflowOp(it, op, x, y);
                    r = m[0];
                }
                e >>= 1;
                if (e == 0) break;
                const sq = @mulWithOverflow(base, base);
                if (sq[1] != 0) return overflowOp(it, op, x, y);
                base = sq[0];
            }
            return .{ .int = r };
        },
        .shl => {
            if (y < 0) return it.fail("negative shift argument", .{});
            if (x == 0) return .{ .int = 0 };
            if (y < 64) {
                const r = x << @intCast(y);
                if (r >> @intCast(y) == x) return .{ .int = r };
            }
            return overflowOp(it, op, x, y);
        },
        .shr => {
            if (y < 0) return it.fail("negative shift argument", .{});
            return .{ .int = if (y >= 64) (if (x < 0) -1 else 0) else x >> @intCast(y) };
        },
        .lt => return b2v(x < y),
        .gt => return b2v(x > y),
        .le => return b2v(x <= y),
        .ge => return b2v(x >= y),
        .eq => return b2v(x == y),
        .ne => return b2v(x != y),
        .bitand => return .{ .int = x & y },
        .bitxor => return .{ .int = x ^ y },
        .bitor => return .{ .int = x | y },
        .streq => return b2v(x == y),
        .strne => return b2v(x != y),
        .in, .ni => return binaryOp(it, op, .{ .int = x }, .{ .int = y }),
        .land, .lor => unreachable,
    }
}

pub fn binaryOp(it: *Interp, op: BinOp, x: Value, y: Value) Error!Value {
    switch (op) {
        .streq, .strne => {
            const same = std.mem.eql(u8, try it.str(x), try it.str(y));
            return b2v(same == (op == .streq));
        },
        .in, .ni => {
            const sx = try it.str(x);
            var found = false;
            for (try it.list(y)) |el| {
                if (std.mem.eql(u8, sx, try it.str(el))) {
                    found = true;
                    break;
                }
            }
            return b2v(found == (op == .in));
        },
        .lt, .gt, .le, .ge, .eq, .ne => {
            const nx = try numberOf(it, x);
            const ny = try numberOf(it, y);
            var order: std.math.Order = undefined;
            if (nx != null and ny != null) {
                if (nx.? == .int and ny.? == .int) return intOp(it, op, nx.?.int, ny.?.int);
                if (nx.? == .str or ny.? == .str) {
                    order = try bigint.compare(it, nx.?, ny.?) orelse return b2v(op == .ne);
                } else {
                    const fx = toF(nx.?);
                    const fy = toF(ny.?);
                    if (std.math.isNan(fx) or std.math.isNan(fy)) return b2v(op == .ne);
                    order = std.math.order(fx, fy);
                }
            } else {
                order = std.mem.order(u8, try it.str(x), try it.str(y));
            }
            return b2v(switch (op) {
                .lt => order == .lt,
                .gt => order == .gt,
                .le => order != .gt,
                .ge => order != .lt,
                .eq => order == .eq,
                else => order != .eq,
            });
        },
        .shl, .shr, .bitand, .bitxor, .bitor, .mod => {
            const name = op.text();
            const nx = try intOnly(it, x, name);
            const ny = try intOnly(it, y, name);
            if (nx == .int and ny == .int) return intOp(it, op, nx.int, ny.int);
            return bigint.binary(it, op, nx, ny);
        },
        .add, .sub, .mul, .div, .pow => {
            const name = op.text();
            const nx = try num(it, x, name);
            const ny = try num(it, y, name);
            if (nx == .int and ny == .int) return intOp(it, op, nx.int, ny.int);
            if (nx != .double and ny != .double) return bigint.binary(it, op, nx, ny);
            const fx = toF(nx);
            const fy = toF(ny);
            return .{ .double = switch (op) {
                .add => fx + fy,
                .sub => fx - fy,
                .mul => fx * fy,
                .div => fx / fy,
                else => blk: {
                    if (fx == 0 and fy < 0) return it.failCode("ARITH DOMAIN {exponentiation of zero by negative power}", "exponentiation of zero by negative power", .{});
                    const r = std.math.pow(f64, fx, fy);
                    if (std.math.isNan(r)) return domainError(it);
                    break :blk r;
                },
            } };
        },
        .land, .lor => unreachable,
    }
}

/// The whole part of a number as an integer of any size.
fn toEntier(it: *Interp, x: Value) Error!Value {
    if (x != .double) return x;
    const d = x.double;
    if (std.math.isNan(d) or std.math.isInf(d)) return it.fail("integer value too large to represent", .{});
    return bigint.fromDouble(it, d);
}

/// The order of two numbers, or null when one is NaN.
fn orderOf(it: *Interp, x: Value, y: Value) Error!?std.math.Order {
    if (x == .int and y == .int) return std.math.order(x.int, y.int);
    if (x == .str or y == .str) return bigint.compare(it, x, y);
    const fx = toF(x);
    const fy = toF(y);
    if (std.math.isNan(fx) or std.math.isNan(fy)) return null;
    return std.math.order(fx, fy);
}

/// One step of the seeded generator of `rand()`.
pub fn nextRand(it: *Interp) f64 {
    var s = it.rand_state;
    s ^= s << 13;
    s ^= s >> 7;
    s ^= s << 17;
    it.rand_state = s;
    return @as(f64, @floatFromInt(s >> 11)) / 9007199254740992.0;
}

pub fn callFunc(it: *Interp, f: Func, args: []const *Node) Error!Value {
    var buf: [3]Value = undefined;
    const name = @tagName(f);
    if (f == .max or f == .min) {
        var best = try num(it, try eval(it, args[0]), name);
        for (args[1..]) |a| {
            const v = try num(it, try eval(it, a), name);
            const o = try orderOf(it, v, best) orelse continue;
            if (o == (if (f == .min) std.math.Order.lt else std.math.Order.gt)) best = v;
        }
        return best;
    }
    if (f == .bool) return b2v(try truthy(it, try eval(it, args[0])));
    for (args, 0..) |a, i| buf[i] = try num(it, try eval(it, a), name);
    const x = if (args.len > 0) buf[0] else Value{ .int = 0 };
    const fx = toF(x);
    const d: f64 = switch (f) {
        .abs => return switch (x) {
            .int => |i| if (i == std.math.minInt(i64)) bigint.negate(it, x) else .{ .int = if (i < 0) -i else i },
            .double => .{ .double = @abs(fx) },
            else => bigint.abs(it, x),
        },
        .int, .wide => return .{ .int = try bigint.low64(it, try toEntier(it, x)) },
        .entier => return toEntier(it, x),
        .round => {
            if (x != .double) return x;
            return toEntier(it, .{ .double = @round(fx) });
        },
        .isqrt => {
            if (fx < 0) return it.fail("square root of negative argument", .{});
            return bigint.isqrt(it, try toEntier(it, x));
        },
        .srand => {
            it.rand_state = @as(u64, @bitCast(try bigint.low64(it, try toEntier(it, x)))) *% 0x9e3779b97f4a7c15 | 1;
            return .{ .double = nextRand(it) };
        },
        .rand => nextRand(it),
        .double => blk: {
            if (x == .str and std.math.isInf(fx)) return it.fail("floating-point value too large to represent", .{});
            break :blk fx;
        },
        .acos => std.math.acos(fx),
        .asin => std.math.asin(fx),
        .atan => std.math.atan(fx),
        .atan2 => std.math.atan2(fx, toF(buf[1])),
        .ceil => @ceil(fx),
        .floor => @floor(fx),
        .cos => @cos(fx),
        .cosh => std.math.cosh(fx),
        .exp => @exp(fx),
        .fmod => @rem(fx, toF(buf[1])),
        .hypot => std.math.hypot(fx, toF(buf[1])),
        .log => @log(fx),
        .log10 => @log10(fx),
        .pow => std.math.pow(f64, fx, toF(buf[1])),
        .sin => @sin(fx),
        .sinh => std.math.sinh(fx),
        .sqrt => @sqrt(fx),
        .tan => @tan(fx),
        .tanh => std.math.tanh(fx),
        .clamp => clamp(fx, toF(buf[1]), toF(buf[2])),
        .lerp => fx + (toF(buf[1]) - fx) * toF(buf[2]),
        .noise2 => noise.noise3Seed(it.noise_seed, fx, toF(buf[1]), 0),
        .noise3 => noise.noise3Seed(it.noise_seed, fx, toF(buf[1]), toF(buf[2])),
        .max, .min, .bool => unreachable,
    };
    if (std.math.isNan(d)) return domainError(it);
    return .{ .double = d };
}

test "minF, maxF, and clamp give a fixed result for zeros and NaN" {
    const bits = struct {
        fn of(x: f64) u64 {
            return @bitCast(x);
        }
    }.of;
    const nan = std.math.nan(f64);
    try std.testing.expectEqual(bits(-0.0), bits(maxF(-0.0, 0.0)));
    try std.testing.expectEqual(bits(0.0), bits(minF(0.0, -0.0)));
    try std.testing.expectEqual(bits(-0.0), bits(clamp(-0.0, 0.0, 1.0)));
    try std.testing.expectEqual(bits(0.0), bits(clamp(0.0, -2e9, -0.0)));
    try std.testing.expectEqual(bits(2.0), bits(maxF(nan, 2.0)));
    try std.testing.expectEqual(bits(2.0), bits(maxF(2.0, nan)));
    try std.testing.expectEqual(bits(0.5), bits(clamp(nan, 0.5, 1.0)));
}

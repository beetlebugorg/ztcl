//! The expression language of `expr`, `if`, `while`, and `for`.
//!
//! `compile` parses the text once into a tree of nodes. `eval` runs the
//! tree. The interpreter caches the tree of a braced expression, so a
//! loop does not parse its condition again.
//!
//! Integers are 64 bits and wrap. Tcl itself continues with big
//! integers; this interpreter does not.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const noise = @import("noise.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Error = interp.Error;

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
            .{ "**", .pow }, .{ "<<", .shl },   .{ ">>", .shr },   .{ "<=", .le },  .{ ">=", .ge },
            .{ "==", .eq },  .{ "!=", .ne },    .{ "&&", .land },  .{ "||", .lor },
            .{ "eq", .streq }, .{ "ne", .strne }, .{ "in", .in }, .{ "ni", .ni },
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
                if (value.parseInt(text)) |n| return e.node(.{ .constant = .{ .int = n } });
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
                const f = std.meta.stringToEnum(Func, name) orelse
                    return e.it.fail("invalid command name \"tcl::mathfunc::{s}\"", .{name});
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
                const ar = f.arity();
                if (args.items.len < ar[0]) return e.it.fail("too few arguments for math function \"{s}\"", .{name});
                if (args.items.len > ar[1]) return e.it.fail("too many arguments for math function \"{s}\"", .{name});
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

fn boolWord(s: []const u8) ?bool {
    const yes = [_][]const u8{ "true", "yes", "on" };
    const no = [_][]const u8{ "false", "no", "off" };
    for (yes) |w| if (std.ascii.eqlIgnoreCase(s, w)) return true;
    for (no) |w| if (std.ascii.eqlIgnoreCase(s, w)) return false;
    return null;
}

/// Parses an expression. The tree lives in the arena of the interpreter.
pub fn compile(it: *Interp, text: []const u8) Error!*Node {
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
            if (value.parseInt(s)) |i| return i != 0;
            if (value.parseDouble(s)) |d| return d != 0;
            if (boolWord(value.trimSpace(s))) |b| return b;
            return it.fail("expected boolean value but got \"{s}\"", .{s});
        },
    }
}

fn num(it: *Interp, v: Value, op: []const u8) Error!Value {
    switch (v) {
        .int, .double => return v,
        else => {
            if (v.asNumber()) |n| return n;
            const s = try it.str(v);
            if (s.len == 0) return it.fail("can't use empty string as operand of \"{s}\"", .{op});
            return it.fail("can't use non-numeric string as operand of \"{s}\"", .{op});
        },
    }
}

fn toF(v: Value) f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .double => |d| d,
        else => unreachable,
    };
}

fn intOnly(it: *Interp, v: Value, op: []const u8) Error!i64 {
    const n = try num(it, v, op);
    if (n == .double) return it.fail("can't use floating-point value as operand of \"{s}\"", .{op});
    return n.int;
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
    }
}

/// Applies a unary operator to a value.
pub fn unaryOp(it: *Interp, op: UnOp, v: Value) Error!Value {
    switch (op) {
        .not => {
            const t = truthy(it, v) catch |err| {
                if (err != error.TclError) return err;
                return it.fail("can't use non-numeric string as operand of \"!\"", .{});
            };
            return b2v(!t);
        },
        .bitnot => return .{ .int = ~try intOnly(it, v, "~") },
        .neg => {
            const x = try num(it, v, "-");
            return if (x == .int) .{ .int = 0 -% x.int } else .{ .double = -x.double };
        },
        .pos => return num(it, v, "+"),
    }
}

pub fn intOp(it: *Interp, op: BinOp, x: i64, y: i64) Error!Value {
    switch (op) {
        .add => return .{ .int = x +% y },
        .sub => return .{ .int = x -% y },
        .mul => return .{ .int = x *% y },
        .div => {
            if (y == 0) return it.fail("divide by zero", .{});
            if (y == -1) return .{ .int = 0 -% x };
            return .{ .int = @divFloor(x, y) };
        },
        .mod => {
            if (y == 0) return it.fail("divide by zero", .{});
            if (y == -1) return .{ .int = 0 };
            // The sign of the result is the sign of the divisor.
            return .{ .int = x - @divFloor(x, y) * y };
        },
        .pow => {
            if (y < 0) {
                if (x == 0) return it.fail("exponentiation of zero by negative power", .{});
                if (x == 1) return .{ .int = 1 };
                if (x == -1) return .{ .int = if (@mod(y, 2) == 0) 1 else -1 };
                return .{ .int = 0 };
            }
            var r: i64 = 1;
            var base = x;
            var e: u64 = @intCast(y);
            while (e != 0) : (e >>= 1) {
                if (e & 1 != 0) r *%= base;
                base *%= base;
            }
            return .{ .int = r };
        },
        .shl => {
            if (y < 0) return it.fail("negative shift argument", .{});
            return .{ .int = if (y >= 64) 0 else x << @intCast(y) };
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
            const nx = x.asNumber();
            const ny = y.asNumber();
            var order: std.math.Order = undefined;
            if (nx != null and ny != null) {
                if (nx.? == .int and ny.? == .int) return intOp(it, op, nx.?.int, ny.?.int);
                const fx = toF(nx.?);
                const fy = toF(ny.?);
                if (std.math.isNan(fx) or std.math.isNan(fy)) return b2v(op == .ne);
                order = std.math.order(fx, fy);
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
            return intOp(it, op, try intOnly(it, x, name), try intOnly(it, y, name));
        },
        .add, .sub, .mul, .div, .pow => {
            const name = op.text();
            const nx = try num(it, x, name);
            const ny = try num(it, y, name);
            if (nx == .int and ny == .int) return intOp(it, op, nx.int, ny.int);
            const fx = toF(nx);
            const fy = toF(ny);
            return .{ .double = switch (op) {
                .add => fx + fy,
                .sub => fx - fy,
                .mul => fx * fy,
                .div => fx / fy,
                else => blk: {
                    if (fx == 0 and fy < 0) return it.fail("exponentiation of zero by negative power", .{});
                    break :blk std.math.pow(f64, fx, fy);
                },
            } };
        },
        .land, .lor => unreachable,
    }
}

fn toInt(it: *Interp, x: Value) Error!i64 {
    switch (x) {
        .int => |i| return i,
        .double => |d| {
            if (std.math.isNan(d) or std.math.isInf(d)) return it.fail("integer value too large to represent", .{});
            const t = @trunc(d);
            if (t >= 9.2233720368547758e18 or t < -9.2233720368547758e18) return it.fail("integer value too large to represent", .{});
            return @intFromFloat(t);
        },
        else => unreachable,
    }
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

fn callFunc(it: *Interp, f: Func, args: []const *Node) Error!Value {
    var buf: [3]Value = undefined;
    const name = @tagName(f);
    if (f == .max or f == .min) {
        var best = try num(it, try eval(it, args[0]), name);
        for (args[1..]) |a| {
            const v = try num(it, try eval(it, a), name);
            const less = if (v == .int and best == .int) v.int < best.int else toF(v) < toF(best);
            if (less == (f == .min) and (less or toF(v) != toF(best))) best = v;
        }
        return best;
    }
    if (f == .bool) return b2v(try truthy(it, try eval(it, args[0])));
    for (args, 0..) |a, i| buf[i] = try num(it, try eval(it, a), name);
    const x = if (args.len > 0) buf[0] else Value{ .int = 0 };
    const fx = toF(x);
    const d: f64 = switch (f) {
        .abs => return if (x == .int) .{ .int = if (x.int < 0) 0 -% x.int else x.int } else .{ .double = @abs(fx) },
        .int, .wide, .entier => return .{ .int = try toInt(it, x) },
        .round => {
            if (x == .int) return x;
            return .{ .int = try toInt(it, .{ .double = @round(fx) }) };
        },
        .isqrt => {
            if (fx < 0) return it.fail("square root of negative argument", .{});
            return .{ .int = @intFromFloat(@floor(@sqrt(fx))) };
        },
        .srand => {
            it.rand_state = @as(u64, @bitCast(try toInt(it, x))) *% 0x9e3779b97f4a7c15 | 1;
            return .{ .double = nextRand(it) };
        },
        .rand => nextRand(it),
        .double => fx,
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
        .clamp => @min(@max(fx, toF(buf[1])), toF(buf[2])),
        .lerp => fx + (toF(buf[1]) - fx) * toF(buf[2]),
        .noise2 => noise.noise3Seed(it.noise_seed, fx, toF(buf[1]), 0),
        .noise3 => noise.noise3Seed(it.noise_seed, fx, toF(buf[1]), toF(buf[2])),
        .max, .min, .bool => unreachable,
    };
    return .{ .double = d };
}

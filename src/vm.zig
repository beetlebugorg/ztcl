//! The bytecode of the Tcl interpreter.
//!
//! `compileProc` turns the parsed body of a proc into a flat list of
//! instructions, one time. `run` executes the list on a small stack of
//! values. A local variable has a slot: its index in the frame.
//!
//! A command with an inline form starts with a `guard`. The guard checks
//! that the core commands are the original commands. When a script
//! renames or replaces one, the guard jumps to `eval_cmd`, and the
//! general path of the interpreter runs the command.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const expr = @import("expr.zig");
const value = @import("value.zig");
const cmds = @import("cmds.zig");
const dict = @import("dict.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
const Interp = interp.Interp;
const Error = interp.Error;
const Cmd = interp.Cmd;
const Frame = interp.Frame;
const Var = interp.Var;
const Word = interp.Word;
const Part = interp.Part;
const Node = expr.Node;

pub const Op = enum(u8) {
    /// Pushes literal `a`.
    push,
    push_empty,
    pop,
    /// Pushes the value of slot `a`.
    load,
    /// Writes the top of the stack to slot `a`. The value stays.
    store,
    /// Runs the read form `x` (`Access`) on the top values of the stack.
    access,
    /// Jumps to `a` when a core command changed. Uses one step of the step limit.
    guard,
    /// Uses one step of the step limit. A loop pass runs this.
    step,
    jump,
    /// Pops a condition. Jumps to `a` when it is false.
    jump_false,
    /// Pops a condition. Jumps to `a` when it is true.
    jump_true,
    /// Replaces the top of the stack with 0 or 1.
    to_bool,
    /// Calls command site `a` with the top `b` values as its words.
    invoke,
    /// Runs command site `a` on the general path.
    eval_cmd,
    /// Evaluates word `a` on the general path.
    word,
    /// Evaluates expression node `a` on the general path.
    node,
    /// Replaces the top `a` values with their joined string.
    concat,
    /// A binary operator. `x` is the operator.
    binary,
    /// A unary operator. `x` is the operator.
    unary,
    /// Makes the result of `expr`: a numeric string becomes a number.
    number_form,
    /// Adds the signed number `b` to slot `a`.
    incr,
    /// Adds the top of the stack to slot `a`. The sum replaces the top.
    incr_value,
    /// Appends the top of the stack to the list in slot `a`.
    lappend,
    /// Ends the proc with the top of the stack.
    ret,
    /// Makes the top of the stack a list and pushes the index 0.
    foreach_init,
    /// Writes the next values to the slots of table `a`, or jumps to `b`.
    foreach_next,
    /// `store`, then `pop`.
    store_pop,
    /// `incr`, with no result on the stack.
    incr_drop,
    /// Pushes operator `x` of slot `a` and slot `b`.
    bin_vv,
    /// Pushes operator `x` of slot `a` and the integer literal `b`.
    bin_vi,
    /// Jumps to `c` when compare `x` of slot `a` and slot `b` is false.
    jf_vv,
    /// Jumps to `c` when compare `x` of slot `a` and literal `b` is false.
    jf_vi,
    /// `dict incr` (`x` 0) or `dict set` (`x` 1) on slot `a`, for command
    /// site `b`. The key, and the value of `dict set`, are on the stack.
    dict_update,
    /// `dict_update` with no result. The cell can then own the dict.
    dict_update_drop,
    /// Appends the top `b` values to the string in slot `a`.
    append,
};

pub const Ins = extern struct {
    op: Op,
    x: u8 = 0,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
};

const no_target = std.math.maxInt(u32);

/// A part of the instructions that belongs to a command or a loop.
const Range = struct {
    start: u32,
    end: u32,
    /// The command for the error trace, or null for a loop body.
    cmd: ?*Cmd = null,
    brk: u32 = no_target,
    cont: u32 = no_target,
    depth: u32 = 0,
};

pub const Code = struct {
    ins: []const Ins,
    lits: []const Value,
    sites: []const *Cmd,
    words: []const *const Word,
    nodes: []const *const Node,
    tables: []const []const u32,
    /// Inner ranges come first.
    ranges: []const Range,
    /// The name of each slot. The parameters come first.
    names: []const []const u8,
    max_stack: u32,
    /// The slots that the call makes before the body runs.
    params: u32,
    /// True for a script outside a proc body. Its slots are names, and
    /// each name has a hint for the search in the current frame.
    named: bool = false,
    hints: []u32 = &.{},
};

// ---- The guard ----

const inline_names = [_][]const u8{
    "set",     "incr",   "expr",    "if",       "while",   "for",
    "foreach", "return", "break",   "continue", "lappend", "dict",
    "append",  "lindex", "llength", "string",
};

/// The read forms of the `access` instruction.
const Access = enum(u8) { llength, lindex, string_length, string_index };

/// True when each inlined name is the original core command, in the
/// global namespace, and no namespace has a command of the same name.
/// Runs one time for each change of the epoch.
fn recheck(it: *Interp) bool {
    if (it.unsafe_epoch == it.epoch) return false;
    if (it.var_traces != 0) {
        it.unsafe_epoch = it.epoch;
        return false;
    }
    var found: usize = 0;
    var iter = it.commands.iterator();
    while (iter.next()) |e| {
        const key = e.key_ptr.*;
        const tail = if (std.mem.lastIndexOf(u8, key, "::")) |i| key[i + 2 ..] else key;
        if (!isInlineName(tail)) continue;
        const original = e.value_ptr.*.impl == .native and e.value_ptr.*.impl.native == cmds.coreFn(tail);
        if (tail.len != key.len or !original) {
            it.unsafe_epoch = it.epoch;
            return false;
        }
        found += 1;
    }
    if (found != inline_names.len) {
        it.unsafe_epoch = it.epoch;
        return false;
    }
    it.safe_epoch = it.epoch;
    return true;
}

fn isInlineName(s: []const u8) bool {
    if (s.len < 2 or s.len > 8) return false;
    for (inline_names) |n| if (std.mem.eql(u8, n, s)) return true;
    return false;
}

// ---- The compiler ----

const max_nest = 64;
/// The most parts of a word that `append` joins with no temporary.
const max_append = 8;

const Loop = struct {
    body_depth: u32,
    breaks: std.ArrayList(u32) = .empty,
    conts: std.ArrayList(u32) = .empty,
    /// In the `next` script of `for`, `continue` leaves the loop.
    in_next: bool = false,
};

/// The general path of an inline form. It goes after the end of the
/// code, so the hot path has no jump over it.
const Cold = struct {
    guard: u32,
    site: u32,
    back: u32,
    /// The hot path dropped the result, so the cold block drops it too.
    drop: bool = false,
};

const Compiler = struct {
    it: *Interp,
    a: Allocator,
    ins: std.ArrayList(Ins) = .empty,
    lits: std.ArrayList(Value) = .empty,
    sites: std.ArrayList(*Cmd) = .empty,
    words: std.ArrayList(*const Word) = .empty,
    nodes: std.ArrayList(*const Node) = .empty,
    tables: std.ArrayList([]const u32) = .empty,
    ranges: std.ArrayList(Range) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    loops: std.ArrayList(*Loop) = .empty,
    depth: u32 = 0,
    max: u32 = 1,
    nest: u32 = 0,
    /// The code runs in a frame that the compiler does not know.
    named: bool = false,
    colds: std.ArrayList(Cold) = .empty,
    /// The last address that a jump goes to.
    label: u32 = no_target,

    fn here(c: *Compiler) u32 {
        return @intCast(c.ins.items.len);
    }

    fn emit(c: *Compiler, i: Ins) Allocator.Error!u32 {
        const at = c.here();
        try c.ins.append(c.a, i);
        return at;
    }

    fn push(c: *Compiler, n: u32) void {
        c.depth += n;
        c.max = @max(c.max, c.depth);
    }

    fn patch(c: *Compiler, at: u32) void {
        const i = &c.ins.items[at];
        if (i.op == .jf_vv or i.op == .jf_vi) i.c = c.here() else i.a = c.here();
        c.label = c.here();
    }

    /// Drops the top of the stack. A `set` or an `incr` just before it
    /// becomes the form with no result.
    fn emitPop(c: *Compiler) Allocator.Error!void {
        c.depth -= 1;
        const n = c.ins.items.len;
        if (n > 0 and c.label != c.here() and c.colds.items.len > 0) {
            const cold = &c.colds.items[c.colds.items.len - 1];
            const last = &c.ins.items[n - 1];
            if (cold.back == c.here() and (last.op == .store or last.op == .incr or last.op == .dict_update)) {
                last.op = switch (last.op) {
                    .store => .store_pop,
                    .incr => .incr_drop,
                    else => .dict_update_drop,
                };
                cold.drop = true;
                return;
            }
        }
        _ = try c.emit(.{ .op = .pop });
    }

    /// Adds the cold blocks after the last instruction.
    fn finish(c: *Compiler) Allocator.Error!void {
        for (c.colds.items) |cold| {
            c.ins.items[cold.guard].a = c.here();
            _ = try c.emit(.{ .op = .eval_cmd, .x = 1, .a = cold.site, .b = cold.guard });
            if (cold.drop) _ = try c.emit(.{ .op = .pop });
            _ = try c.emit(.{ .op = .jump, .a = cold.back });
        }
    }

    /// The slot of a plain variable node, or null.
    fn varNode(c: *Compiler, n: *const Node) Allocator.Error!?u32 {
        if (n.* != .variable or n.variable.index != null or !plain(n.variable.name)) return null;
        return try c.slot(n.variable.name);
    }

    fn isVarNode(n: *const Node) bool {
        return n.* == .variable and n.variable.index == null and plain(n.variable.name);
    }

    fn isIntNode(n: *const Node) bool {
        return n.* == .constant and n.constant == .int;
    }

    fn intLit(c: *Compiler, n: *const Node) Allocator.Error!u32 {
        try c.lits.append(c.a, n.constant);
        return @intCast(c.lits.items.len - 1);
    }

    /// Emits a binary operator on a variable and a variable or an
    /// integer literal. Returns false for other operands.
    fn fusedBinary(c: *Compiler, op: expr.BinOp, x: *const Node, y: *const Node) Allocator.Error!bool {
        if (!isVarNode(x) or !(isVarNode(y) or isIntNode(y))) return false;
        const a = (try c.varNode(x)).?;
        if (isVarNode(y)) {
            _ = try c.emit(.{ .op = .bin_vv, .x = @intFromEnum(op), .a = a, .b = (try c.varNode(y)).? });
        } else {
            _ = try c.emit(.{ .op = .bin_vi, .x = @intFromEnum(op), .a = a, .b = try c.intLit(y) });
        }
        c.push(1);
        return true;
    }

    /// Compiles a condition and a jump for the false case. Returns the
    /// address of the jump for `patch`. The stack depth stays the same.
    fn jumpFalse(c: *Compiler, n: *const Node) Error!u32 {
        if (n.* == .binary) {
            const b = n.binary;
            const compare = switch (b.op) {
                .lt, .gt, .le, .ge, .eq, .ne => true,
                else => false,
            };
            if (compare and isVarNode(b.a) and (isVarNode(b.b) or isIntNode(b.b))) {
                const a = (try c.varNode(b.a)).?;
                if (isVarNode(b.b)) {
                    return c.emit(.{ .op = .jf_vv, .x = @intFromEnum(b.op), .a = a, .b = (try c.varNode(b.b)).? });
                }
                return c.emit(.{ .op = .jf_vi, .x = @intFromEnum(b.op), .a = a, .b = try c.intLit(b.b) });
            }
        }
        try c.compileNode(n);
        const at = try c.emit(.{ .op = .jump_false });
        c.depth -= 1;
        return at;
    }

    fn site(c: *Compiler, cmd: *Cmd) Allocator.Error!u32 {
        try c.sites.append(c.a, cmd);
        return @intCast(c.sites.items.len - 1);
    }

    fn lit(c: *Compiler, v: Value) Allocator.Error!void {
        try c.lits.append(c.a, v);
        _ = try c.emit(.{ .op = .push, .a = @intCast(c.lits.items.len - 1) });
        c.push(1);
    }

    fn slot(c: *Compiler, name: []const u8) Allocator.Error!u32 {
        for (c.names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
        try c.names.append(c.a, name);
        return @intCast(c.names.items.len - 1);
    }

    fn plain(name: []const u8) bool {
        return name.len > 0 and std.mem.indexOfAny(u8, name, "(:") == null;
    }

    fn fallbackWord(c: *Compiler, w: *const Word) Allocator.Error!void {
        try c.words.append(c.a, w);
        _ = try c.emit(.{ .op = .word, .a = @intCast(c.words.items.len - 1) });
        c.push(1);
    }

    fn simplePart(p: *const Part) bool {
        return switch (p.*) {
            .lit, .script => true,
            .variable => |*v| v.index == null and plain(v.name),
        };
    }

    fn allSimple(parts: []const Part) bool {
        for (parts) |*p| if (!simplePart(p)) return false;
        return true;
    }

    fn compilePart(c: *Compiler, p: *const Part) Error!void {
        switch (p.*) {
            .lit => |s| try c.lit(.{ .str = s }),
            .variable => |*v| {
                _ = try c.emit(.{ .op = .load, .a = try c.slot(v.name) });
                c.push(1);
            },
            .script => |s| try c.compileScript(s),
        }
    }

    fn compileWord(c: *Compiler, w: *const Word) Error!void {
        if (c.nest >= max_nest) return c.fallbackWord(w);
        switch (w.kind) {
            .lit => |v| try c.lit(v),
            .single => |*p| {
                if (!simplePart(p)) return c.fallbackWord(w);
                try c.compilePart(p);
            },
            .multi => |parts| {
                for (parts) |*p| if (!simplePart(p)) return c.fallbackWord(w);
                for (parts) |*p| try c.compilePart(p);
                _ = try c.emit(.{ .op = .concat, .a = @intCast(parts.len) });
                c.depth -= @intCast(parts.len);
                c.push(1);
            },
        }
    }

    fn compileScript(c: *Compiler, s: *interp.Script) Error!void {
        c.nest += 1;
        defer c.nest -= 1;
        if (s.cmds.len == 0) {
            _ = try c.emit(.{ .op = .push_empty });
            c.push(1);
            return;
        }
        for (s.cmds, 0..) |*cmd, i| {
            if (i > 0) try c.emitPop();
            try c.compileCmd(cmd);
        }
    }

    fn compileNode(c: *Compiler, n: *const Node) Error!void {
        if (c.nest >= max_nest) return c.fallbackNode(n);
        c.nest += 1;
        defer c.nest -= 1;
        switch (n.*) {
            .constant => |v| try c.lit(v),
            .variable => |*r| {
                if (r.index != null or !plain(r.name)) return c.fallbackNode(n);
                _ = try c.emit(.{ .op = .load, .a = try c.slot(r.name) });
                c.push(1);
            },
            .script => |s| try c.compileScript(s),
            .unary => |*u| {
                try c.compileNode(u.a);
                _ = try c.emit(.{ .op = .unary, .x = @intFromEnum(u.op) });
            },
            .binary => |*b| switch (b.op) {
                .land, .lor => {
                    try c.compileNode(b.a);
                    const short = try c.emit(.{ .op = if (b.op == .land) .jump_false else .jump_true });
                    c.depth -= 1;
                    try c.compileNode(b.b);
                    _ = try c.emit(.{ .op = .to_bool });
                    const end = try c.emit(.{ .op = .jump });
                    c.patch(short);
                    c.depth -= 1;
                    try c.lit(.{ .int = @intFromBool(b.op == .lor) });
                    c.patch(end);
                },
                else => {
                    if (try c.fusedBinary(b.op, b.a, b.b)) return;
                    try c.compileNode(b.a);
                    try c.compileNode(b.b);
                    _ = try c.emit(.{ .op = .binary, .x = @intFromEnum(b.op) });
                    c.depth -= 1;
                },
            },
            .ternary => |*t| {
                try c.compileNode(t[0]);
                const other = try c.emit(.{ .op = .jump_false });
                c.depth -= 1;
                try c.compileNode(t[1]);
                const end = try c.emit(.{ .op = .jump });
                c.patch(other);
                c.depth -= 1;
                try c.compileNode(t[2]);
                c.patch(end);
            },
            .parts, .func, .call => try c.fallbackNode(n),
        }
    }

    fn fallbackNode(c: *Compiler, n: *const Node) Allocator.Error!void {
        try c.nodes.append(c.a, n);
        _ = try c.emit(.{ .op = .node, .a = @intCast(c.nodes.items.len - 1) });
        c.push(1);
    }

    /// The parsed expression of a literal word, or null when it does not
    /// parse. The error then comes from the general path, at run time.
    fn exprNode(c: *Compiler, cmd: *Cmd, i: usize) Error!?*Node {
        if (cmd.cache[i].expr) |n| return n;
        const it = c.it;
        const r, const code, const line = .{ it.result, it.error_code, it.error_line };
        const text = try it.str(cmd.words[i].kind.lit);
        const n = expr.compile(it, text) catch |e| {
            if (e == error.OutOfMemory) return e;
            it.result, it.error_code, it.error_line = .{ r, code, line };
            return null;
        };
        cmd.cache[i].expr = n;
        return n;
    }

    fn bodyScript(c: *Compiler, cmd: *Cmd, i: usize) Error!?*interp.Script {
        if (cmd.cache[i].script) |s| return s;
        const it = c.it;
        const r, const code, const line = .{ it.result, it.error_code, it.error_line };
        const text = try it.str(cmd.words[i].kind.lit);
        const s = it.compile(text) catch |e| {
            if (e == error.OutOfMemory) return e;
            it.result, it.error_code, it.error_line = .{ r, code, line };
            return null;
        };
        cmd.cache[i].script = s;
        return s;
    }

    fn compileCmd(c: *Compiler, cmd: *Cmd) Error!void {
        if (cmd.has_expand) {
            _ = try c.emit(.{ .op = .eval_cmd, .a = try c.site(cmd) });
            c.push(1);
            return;
        }
        if (c.nest < max_nest and cmd.words.len > 0 and cmd.words[0].kind == .lit and cmd.words[0].kind.lit == .str) {
            if (try c.compileInline(cmd, cmd.words[0].kind.lit.str)) return;
        }
        const start = c.here();
        const base = c.depth;
        for (cmd.words) |*w| try c.compileWord(w);
        _ = try c.emit(.{ .op = .invoke, .a = try c.site(cmd), .b = @intCast(cmd.words.len) });
        c.depth = base;
        c.push(1);
        try c.ranges.append(c.a, .{ .start = start, .end = c.here(), .cmd = cmd });
    }

    /// The word is one literal plain variable name.
    fn nameWord(cmd: *Cmd, i: usize) ?[]const u8 {
        const w = &cmd.words[i];
        if (w.kind != .lit or w.kind.lit != .str or !plain(w.kind.lit.str)) return null;
        return w.kind.lit.str;
    }

    fn allLiteral(cmd: *Cmd) bool {
        for (cmd.words) |w| if (w.kind != .lit) return false;
        return true;
    }

    /// `llength list`, `lindex list index`, `string length s`, and
    /// `string index s i`. Other forms use the general path.
    fn compileAccess(c: *Compiler, cmd: *Cmd, name: []const u8) Error!bool {
        const n = cmd.words.len;
        const eql = std.mem.eql;
        var kind: Access = undefined;
        var first: usize = 1;
        if (eql(u8, name, "llength") and n == 2) {
            kind = .llength;
        } else if (eql(u8, name, "lindex") and n == 3) {
            kind = .lindex;
        } else if (eql(u8, name, "string") and n >= 3 and isWord(cmd.words[1], "length") and n == 3) {
            kind = .string_length;
            first = 2;
        } else if (eql(u8, name, "string") and n == 4 and isWord(cmd.words[1], "index")) {
            kind = .string_index;
            first = 2;
        } else return false;
        const base = c.depth;
        const g = try c.emit(.{ .op = .guard });
        const start = c.here();
        for (cmd.words[first..]) |*w| try c.compileWord(w);
        _ = try c.emit(.{ .op = .access, .x = @intFromEnum(kind) });
        try c.closeGuard(cmd, base, g, start);
        return true;
    }

    fn compileInline(c: *Compiler, cmd: *Cmd, name: []const u8) Error!bool {
        if (try c.compileAccess(cmd, name)) return true;
        const n = cmd.words.len;
        const eql = std.mem.eql;
        if (eql(u8, name, "set")) {
            if ((n != 2 and n != 3) or nameWord(cmd, 1) == null) return false;
        } else if (eql(u8, name, "incr")) {
            if ((n != 2 and n != 3) or nameWord(cmd, 1) == null) return false;
        } else if (eql(u8, name, "lappend")) {
            if (n != 3 or nameWord(cmd, 1) == null) return false;
        } else if (eql(u8, name, "append")) {
            if (n != 3 or nameWord(cmd, 1) == null) return false;
        } else if (eql(u8, name, "expr")) {
            if (n != 2 or cmd.words[1].kind != .lit) return false;
            if (try c.exprNode(cmd, 1) == null) return false;
        } else if (eql(u8, name, "return")) {
            // Outside a proc, the general path gives the return code.
            if (n > 2 or c.named) return false;
        } else if (eql(u8, name, "break") or eql(u8, name, "continue")) {
            if (n != 1 or c.loops.items.len == 0) return false;
            const loop = c.loops.items[c.loops.items.len - 1];
            if (c.depth != loop.body_depth) return false;
            if (name[0] == 'c' and loop.in_next) return false;
        } else if (eql(u8, name, "dict")) {
            // Slots of a proc only: a named cell has no owned form.
            if (c.named or n < 4 or cmd.words[1].kind != .lit or cmd.words[1].kind.lit != .str) return false;
            const sub = cmd.words[1].kind.lit.str;
            if (!((eql(u8, sub, "incr") and n == 4) or (eql(u8, sub, "set") and n == 5))) return false;
            if (nameWord(cmd, 2) == null) return false;
        } else if (eql(u8, name, "if")) {
            return c.compileIf(cmd);
        } else if (eql(u8, name, "while")) {
            return c.compileWhile(cmd);
        } else if (eql(u8, name, "for")) {
            return c.compileFor(cmd);
        } else if (eql(u8, name, "foreach")) {
            return c.compileForeach(cmd);
        } else return false;

        const base = c.depth;
        const g = try c.emit(.{ .op = .guard });
        const start = c.here();
        switch (name[0]) {
            's' => {
                const s = try c.slot(nameWord(cmd, 1).?);
                if (n == 3) {
                    try c.compileWord(&cmd.words[2]);
                    _ = try c.emit(.{ .op = .store, .a = s });
                } else {
                    _ = try c.emit(.{ .op = .load, .a = s });
                    c.push(1);
                }
            },
            'i' => {
                const s = try c.slot(nameWord(cmd, 1).?);
                var imm: ?i32 = if (n == 2) 1 else null;
                if (n == 3 and cmd.words[2].kind == .lit and cmd.words[2].kind.lit == .int) {
                    imm = std.math.cast(i32, cmd.words[2].kind.lit.int);
                }
                if (imm) |by| {
                    _ = try c.emit(.{ .op = .incr, .a = s, .b = @bitCast(by) });
                    c.push(1);
                } else {
                    try c.compileWord(&cmd.words[2]);
                    _ = try c.emit(.{ .op = .incr_value, .a = s });
                }
            },
            'l' => {
                const s = try c.slot(nameWord(cmd, 1).?);
                try c.compileWord(&cmd.words[2]);
                _ = try c.emit(.{ .op = .lappend, .a = s });
            },
            'a' => {
                const s = try c.slot(nameWord(cmd, 1).?);
                const w = &cmd.words[2];
                var count: u32 = 1;
                if (w.kind == .multi and w.kind.multi.len <= max_append and allSimple(w.kind.multi)) {
                    for (w.kind.multi) |*p| try c.compilePart(p);
                    count = @intCast(w.kind.multi.len);
                } else try c.compileWord(w);
                _ = try c.emit(.{ .op = .append, .a = s, .b = count });
                c.depth = base;
                c.push(1);
            },
            'd' => {
                const s = try c.slot(nameWord(cmd, 2).?);
                for (cmd.words[3..]) |*w| try c.compileWord(w);
                _ = try c.emit(.{ .op = .dict_update, .x = @intFromBool(n == 5), .a = s, .b = try c.site(cmd) });
                c.depth = base;
                c.push(1);
            },
            'e' => {
                const node = (try c.exprNode(cmd, 1)).?;
                try c.compileNode(node);
                // A binary operator always gives a number.
                if (node.* != .binary) _ = try c.emit(.{ .op = .number_form });
            },
            'r' => {
                if (n == 2) {
                    try c.compileWord(&cmd.words[1]);
                } else {
                    _ = try c.emit(.{ .op = .push_empty });
                    c.push(1);
                }
                _ = try c.emit(.{ .op = .ret });
            },
            'b', 'c' => {
                const loop = c.loops.items[c.loops.items.len - 1];
                const j = try c.emit(.{ .op = .jump });
                if (name[0] == 'b') try loop.breaks.append(c.a, j) else try loop.conts.append(c.a, j);
                c.push(1);
            },
            else => unreachable,
        }
        try c.closeGuard(cmd, base, g, start);
        return true;
    }

    /// Ends an inline form: adds its range and its general path.
    fn closeGuard(c: *Compiler, cmd: *Cmd, base: u32, g: u32, start: u32) Error!void {
        try c.ranges.append(c.a, .{ .start = start, .end = c.here(), .cmd = cmd });
        try c.colds.append(c.a, .{ .guard = g, .site = try c.site(cmd), .back = c.here() });
        c.depth = base;
        c.push(1);
    }

    fn compileIf(c: *Compiler, cmd: *Cmd) Error!bool {
        if (!allLiteral(cmd)) return false;
        const w = cmd.words;
        const Clause = struct { cond: *Node, body: *interp.Script };
        var clauses: std.ArrayList(Clause) = .empty;
        var other: ?*interp.Script = null;
        var i: usize = 1;
        while (true) {
            if (i >= w.len) return false;
            const cond = try c.exprNode(cmd, i) orelse return false;
            i += 1;
            if (i < w.len and isWord(w[i], "then")) i += 1;
            if (i >= w.len) return false;
            const body = try c.bodyScript(cmd, i) orelse return false;
            try clauses.append(c.a, .{ .cond = cond, .body = body });
            i += 1;
            if (i >= w.len) break;
            if (isWord(w[i], "elseif")) {
                i += 1;
                continue;
            }
            if (isWord(w[i], "else")) {
                i += 1;
                if (i >= w.len) return false;
            }
            if (i != w.len - 1) return false;
            other = try c.bodyScript(cmd, i) orelse return false;
            break;
        }
        const base = c.depth;
        const g = try c.emit(.{ .op = .guard });
        const start = c.here();
        var ends: std.ArrayList(u32) = .empty;
        for (clauses.items) |cl| {
            const next = try c.jumpFalse(cl.cond);
            c.depth = base;
            try c.compileScript(cl.body);
            try ends.append(c.a, try c.emit(.{ .op = .jump }));
            c.patch(next);
            c.depth = base;
        }
        if (other) |s| {
            try c.compileScript(s);
        } else {
            _ = try c.emit(.{ .op = .push_empty });
            c.push(1);
        }
        for (ends.items) |e| c.patch(e);
        try c.closeGuard(cmd, base, g, start);
        return true;
    }

    fn isWord(w: Word, s: []const u8) bool {
        return w.kind == .lit and w.kind.lit == .str and std.mem.eql(u8, w.kind.lit.str, s);
    }

    /// Compiles a loop body with its range. Inner jumps go in `loop`.
    fn loopBody(c: *Compiler, loop: *Loop, s: *interp.Script) Error!void {
        try c.loops.append(c.a, loop);
        defer _ = c.loops.pop();
        try c.compileScript(s);
        try c.emitPop();
    }

    fn compileWhile(c: *Compiler, cmd: *Cmd) Error!bool {
        if (cmd.words.len != 3 or !allLiteral(cmd)) return false;
        const cond = try c.exprNode(cmd, 1) orelse return false;
        const body = try c.bodyScript(cmd, 2) orelse return false;
        const base = c.depth;
        const g = try c.emit(.{ .op = .guard });
        const start = c.here();
        const top = c.here();
        c.label = top;
        const exit = try c.jumpFalse(cond);
        c.depth = base;
        _ = try c.emit(.{ .op = .step });
        var loop: Loop = .{ .body_depth = base };
        const body_start = c.here();
        try c.loopBody(&loop, body);
        const body_end = c.here();
        _ = try c.emit(.{ .op = .jump, .a = top });
        c.patch(exit);
        const end = c.here();
        for (loop.breaks.items) |j| c.ins.items[j].a = end;
        for (loop.conts.items) |j| c.ins.items[j].a = top;
        try c.ranges.append(c.a, .{ .start = body_start, .end = body_end, .brk = end, .cont = top, .depth = base });
        _ = try c.emit(.{ .op = .push_empty });
        c.push(1);
        try c.closeGuard(cmd, base, g, start);
        return true;
    }

    fn compileFor(c: *Compiler, cmd: *Cmd) Error!bool {
        if (cmd.words.len != 5 or !allLiteral(cmd)) return false;
        const first = try c.bodyScript(cmd, 1) orelse return false;
        const cond = try c.exprNode(cmd, 2) orelse return false;
        const next = try c.bodyScript(cmd, 3) orelse return false;
        const body = try c.bodyScript(cmd, 4) orelse return false;
        const base = c.depth;
        const g = try c.emit(.{ .op = .guard });
        const start = c.here();
        try c.compileScript(first);
        try c.emitPop();
        c.depth = base;
        const top = c.here();
        c.label = top;
        const exit = try c.jumpFalse(cond);
        c.depth = base;
        _ = try c.emit(.{ .op = .step });
        var loop: Loop = .{ .body_depth = base };
        const body_start = c.here();
        try c.loopBody(&loop, body);
        const body_end = c.here();
        const next_at = c.here();
        c.label = next_at;
        loop.in_next = true;
        try c.loopBody(&loop, next);
        const next_end = c.here();
        _ = try c.emit(.{ .op = .jump, .a = top });
        c.patch(exit);
        const end = c.here();
        for (loop.breaks.items) |j| c.ins.items[j].a = end;
        for (loop.conts.items) |j| c.ins.items[j].a = next_at;
        try c.ranges.append(c.a, .{ .start = body_start, .end = body_end, .brk = end, .cont = next_at, .depth = base });
        try c.ranges.append(c.a, .{ .start = next_at, .end = next_end, .brk = end, .depth = base });
        _ = try c.emit(.{ .op = .push_empty });
        c.push(1);
        try c.closeGuard(cmd, base, g, start);
        return true;
    }

    fn compileForeach(c: *Compiler, cmd: *Cmd) Error!bool {
        if (cmd.words.len != 4 or cmd.words[1].kind != .lit or cmd.words[3].kind != .lit) return false;
        const it = c.it;
        const r, const code = .{ it.result, it.error_code };
        const names = it.list(cmd.words[1].kind.lit) catch |e| {
            if (e == error.OutOfMemory) return e;
            it.result, it.error_code = .{ r, code };
            return false;
        };
        if (names.len == 0) return false;
        for (names) |v| if (v != .str or !plain(v.str) or std.mem.eql(u8, v.str, "tcl_precision")) return false;
        const body = try c.bodyScript(cmd, 3) orelse return false;
        const table = try c.a.alloc(u32, names.len);
        for (names, table) |v, *t| t.* = try c.slot(v.str);
        try c.tables.append(c.a, table);
        const base = c.depth;
        const g = try c.emit(.{ .op = .guard });
        const start = c.here();
        try c.compileWord(&cmd.words[2]);
        _ = try c.emit(.{ .op = .foreach_init });
        c.push(1);
        c.label = c.here();
        const top = try c.emit(.{ .op = .foreach_next, .a = @intCast(c.tables.items.len - 1) });
        var loop: Loop = .{ .body_depth = base + 2 };
        const body_start = c.here();
        try c.loopBody(&loop, body);
        const body_end = c.here();
        _ = try c.emit(.{ .op = .jump, .a = top });
        const end = c.here();
        c.label = end;
        c.ins.items[top].b = end;
        for (loop.breaks.items) |j| c.ins.items[j].a = end;
        for (loop.conts.items) |j| c.ins.items[j].a = top;
        try c.ranges.append(c.a, .{ .start = body_start, .end = body_end, .brk = end, .cont = top, .depth = base + 2 });
        _ = try c.emit(.{ .op = .pop });
        _ = try c.emit(.{ .op = .pop });
        c.depth = base;
        _ = try c.emit(.{ .op = .push_empty });
        c.push(1);
        try c.closeGuard(cmd, base, g, start);
        return true;
    }
};

/// Compiles the body of a proc. The slots of the parameters come first.
pub fn compileProc(it: *Interp, p: *interp.Proc, s: *interp.Script) Error!*Code {
    const a = it.alloc();
    var c: Compiler = .{ .it = it, .a = a };
    for (p.params) |prm| try c.names.append(a, prm.name);
    if (p.has_args) try c.names.append(a, "args");
    const params: u32 = @intCast(c.names.items.len);
    try c.compileScript(s);
    _ = try c.emit(.{ .op = .ret });
    try c.finish();
    const code = try a.create(Code);
    code.* = .{
        .ins = c.ins.items,
        .lits = c.lits.items,
        .sites = c.sites.items,
        .words = c.words.items,
        .nodes = c.nodes.items,
        .tables = c.tables.items,
        .ranges = c.ranges.items,
        .names = c.names.items,
        .max_stack = c.max + 1,
        .params = params,
    };
    return code;
}

/// Compiles a script that runs in any frame. Its variables use names.
pub fn compileNamed(it: *Interp, s: *interp.Script) Error!*Code {
    const a = it.alloc();
    var c: Compiler = .{ .it = it, .a = a, .named = true };
    try c.compileScript(s);
    _ = try c.emit(.{ .op = .ret });
    try c.finish();
    const hints = try a.alloc(u32, c.names.items.len);
    @memset(hints, 0);
    const code = try a.create(Code);
    code.* = .{
        .ins = c.ins.items,
        .lits = c.lits.items,
        .sites = c.sites.items,
        .words = c.words.items,
        .nodes = c.nodes.items,
        .tables = c.tables.items,
        .ranges = c.ranges.items,
        .names = c.names.items,
        .max_stack = c.max + 1,
        .params = 0,
        .named = true,
        .hints = hints,
    };
    return code;
}

// ---- The executor ----

inline fn cellAt(f: *Frame, slot: u32) *Var {
    return f.vars.items[slot].cell.settle();
}

/// Runs `dict incr` or `dict set` with the general command.
fn dictSlow(it: *Interp, cmd: *Cmd, args: []const Value) Error!Value {
    var argv: [5]Value = undefined;
    for (cmd.words[0..3], 0..) |w, k| argv[k] = w.kind.lit;
    @memcpy(argv[3..][0..args.len], args);
    return dict.cmdDict(it, argv[0 .. 3 + args.len], cmd);
}

/// The cell of a slot for a read, or null when the name has no cell.
inline fn readCell(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, slot: u32) ?*Var {
    if (named) return it.slotCell(code.names[slot], &code.hints[slot]);
    return cellAt(f, slot);
}

/// The cell of a slot for a write. A name with no cell gets one.
inline fn writeCell(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, slot: u32) Allocator.Error!*Var {
    if (named) return it.cellOf(code.names[slot], &code.hints[slot]);
    return cellAt(f, slot);
}

/// A store to a cell that is an array, has traces, or links to an
/// element. It stays out of line to keep the registers of the loop.
noinline fn slowStore(it: *Interp, name: []const u8, v: *const Value) Error!void {
    @branchHint(.cold);
    return it.setVar(name, v.*);
}

/// The stores of one `foreach` pass from the first cell that is not plain.
noinline fn slowForeach(it: *Interp, code: *const Code, table: []const u32, items: []const Value, at: usize, from: usize) Error!void {
    @branchHint(.cold);
    for (table[from..], from..) |slot, k| {
        try it.setVar(code.names[slot], if (at + k < items.len) items[at + k] else Value.empty);
    }
}

fn step(it: *Interp) Error!void {
    if (it.step_limit == 0) return it.fail("step limit reached", .{});
    it.step_limit -= 1;
    if (it.counter.used > it.mem_limit) return it.fail("the script used too much memory", .{});
}

/// The integer of a slot, or null for any other content.
inline fn intSlot(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, slot: u32) ?i64 {
    const cell = readCell(named, it, f, code, slot) orelse return null;
    if (cell.v == .val and cell.v.val == .int) return cell.v.val.int;
    return null;
}

/// Reads a slot on the slow path. An unset variable is an error.
fn readSlot(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, slot: u32) Error!Value {
    if (readCell(named, it, f, code, slot)) |cell| {
        if (cell.v == .val) return cell.v.val;
    }
    const r: interp.VarRef = .{ .name = code.names[slot] };
    return it.readRef(&r);
}

/// The result of a common operator on two integers, or null for an
/// overflow or another operator. The integer needs no 32-byte value on
/// the way, so the common path stays short.
inline fn intFast(op: expr.BinOp, a: i64, b: i64) ?i64 {
    const r = switch (op) {
        .add => @addWithOverflow(a, b),
        .sub => @subWithOverflow(a, b),
        .mul => @mulWithOverflow(a, b),
        .lt => return @intFromBool(a < b),
        .le => return @intFromBool(a <= b),
        .gt => return @intFromBool(a > b),
        .ge => return @intFromBool(a >= b),
        .eq => return @intFromBool(a == b),
        .ne => return @intFromBool(a != b),
        else => return null,
    };
    if (r[1] != 0) {
        @branchHint(.cold);
        return null;
    }
    return r[0];
}

/// True when `a + b` fits in 64 bits.
inline fn addFits(a: i64, b: i64) bool {
    if (@addWithOverflow(a, b)[1] != 0) {
        @branchHint(.cold);
        return false;
    }
    return true;
}

inline fn intCompare(op: expr.BinOp, a: i64, b: i64) bool {
    return switch (op) {
        .lt => a < b,
        .le => a <= b,
        .gt => a > b,
        .ge => a >= b,
        .eq => a == b,
        else => a != b,
    };
}

/// The operator on two values that are not both integers.
fn slowBinary(it: *Interp, op: expr.BinOp, x: Value, y: Value) Error!Value {
    if (x == .int and y == .int) return expr.intOp(it, op, x.int, y.int);
    return expr.binaryOp(it, op, x, y);
}

fn slowIncr(it: *Interp, name: []const u8, by: Value) Error!Value {
    const argv = [_]Value{ .{ .str = "incr" }, .{ .str = name }, by };
    return cmds.cmdIncr(it, &argv, null);
}

fn slowLappend(it: *Interp, name: []const u8, v: Value) Error!Value {
    const argv = [_]Value{ .{ .str = "lappend" }, .{ .str = name }, v };
    return cmds.cmdLappend(it, &argv, null);
}

/// Appends values to a slot. A string in the cell grows in place, and
/// an integer part makes no string of its own.
fn appendValues(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, slot: u32, vals: []const Value) Error!Value {
    const found = readCell(named, it, f, code, slot);
    if (found == null or found.?.v != .val or found.?.v.val != .str) {
        const argv = [_]Value{ .{ .str = "append" }, .{ .str = code.names[slot] }, try concatValues(it, vals) };
        return cmds.cmdAppend(it, &argv, null);
    }
    var nums: [max_append][24]u8 = undefined;
    var texts: [max_append][]const u8 = undefined;
    for (vals, 0..) |v, k| {
        texts[k] = if (v == .int) value.writeInt(&nums[k], v.int) else try it.str(v);
    }
    const out: Value = .{ .str = try it.appendStr(found.?.v.val.str, texts[0..vals.len]) };
    found.?.v = .{ .val = out };
    return out;
}

fn concatValues(it: *Interp, vals: []const Value) Error!Value {
    // An integer formats in a small buffer, so it makes no string of
    // its own in the arena.
    var nums: [8][24]u8 = undefined;
    var small: [8][]const u8 = undefined;
    const texts = if (vals.len <= small.len) small[0..vals.len] else try it.alloc().alloc([]const u8, vals.len);
    var total: usize = 0;
    for (vals, texts, 0..) |v, *t, k| {
        if (v == .int and k < nums.len) {
            t.* = value.writeInt(&nums[k], v.int);
        } else t.* = try it.str(v);
        total += t.len;
    }
    const out = try it.alloc().alloc(u8, total);
    var at: usize = 0;
    for (texts) |t| {
        @memcpy(out[at .. at + t.len], t);
        at += t.len;
    }
    return .{ .str = out };
}

/// Runs the code of a proc in the current frame.
pub fn run(it: *Interp, code: *const Code) Error!Value {
    try it.checkNative();
    if (it.nest >= it.max_nest) return it.fail("too many nested evaluations (infinite loop?)", .{});
    it.nest += 1;
    defer it.nest -= 1;
    const mark = it.stackMark();
    defer it.stackRelease(mark);
    const stack = try it.stackAllocPub(code.max_stack);
    var pc: u32 = 0;
    var sp: u32 = 0;
    while (true) {
        const out = if (code.named)
            exec(true, it, code, stack.ptr, &pc, &sp)
        else
            exec(false, it, code, stack.ptr, &pc, &sp);
        return out catch |e| {
            // A cold block counts as the place of its guard.
            if (code.ins[pc].op == .eval_cmd and code.ins[pc].x == 1) pc = code.ins[pc].b;
            switch (e) {
                error.TclError => {
                    for (code.ranges) |r| {
                        if (pc < r.start or pc >= r.end) continue;
                        if (r.cmd) |cmd| _ = it.noteLine(cmd, e) catch {};
                    }
                    return e;
                },
                error.TclBreak, error.TclContinue => {
                    const target = for (code.ranges) |r| {
                        if (pc < r.start or pc >= r.end or r.cmd != null) continue;
                        const t = if (e == error.TclBreak) r.brk else r.cont;
                        if (t == no_target) continue;
                        sp = r.depth;
                        break t;
                    } else return e;
                    pc = target;
                    continue;
                },
                else => return e,
            }
        };
    }
}

fn exec(comptime named: bool, it: *Interp, code: *const Code, stack: [*]Value, pc_out: *u32, sp_out: *u32) Error!Value {
    var pc = pc_out.*;
    var sp = sp_out.*;
    errdefer {
        pc_out.* = pc;
        sp_out.* = sp;
    }
    const ins = code.ins.ptr;
    const f = it.frame;
    while (true) {
        var i = &ins[pc];
        sw: switch (i.op) {
            .push => {
                stack[sp] = code.lits[i.a];
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .push_empty => {
                stack[sp] = Value.empty;
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .pop => {
                sp -= 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .load => {
                const cell = readCell(named, it, f, code, i.a);
                if (cell != null and cell.?.v == .val) {
                    stack[sp] = cell.?.v.val;
                } else {
                    const r: interp.VarRef = .{ .name = code.names[i.a] };
                    stack[sp] = try it.readRef(&r);
                }
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .store => {
                const cell = try writeCell(named, it, f, code, i.a);
                if (cell.v == .val) {
                    cell.v.val = stack[sp - 1];
                    pc += 1;
                    i = &ins[pc];
                    continue :sw i.op;
                }
                if (!cell.plainStore()) {
                    @branchHint(.cold);
                    try slowStore(it, code.names[i.a], &stack[sp - 1]);
                    pc += 1;
                    i = &ins[pc];
                    continue :sw i.op;
                }
                cell.v = .{ .val = stack[sp - 1] };
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .access => switch (@as(Access, @enumFromInt(i.x))) {
                .llength => {
                    const v = stack[sp - 1];
                    const n = if (v == .list) v.list.len else (try it.readList(v)).len;
                    stack[sp - 1] = .{ .int = @intCast(n) };
                },
                .lindex => {
                    const l = stack[sp - 2];
                    const at = stack[sp - 1];
                    if (at == .int) {
                        const items = try it.readList(l);
                        stack[sp - 2] = if (at.int >= 0 and at.int < items.len) items[@intCast(at.int)] else Value.empty;
                    } else {
                        const argv = [_]Value{ .{ .str = "lindex" }, l, at };
                        stack[sp - 2] = try cmds.cmdLindex(it, &argv, null);
                    }
                    sp -= 1;
                },
                .string_length => {
                    // A copy first: the new union overlaps the old one.
                    const v = stack[sp - 1];
                    const n = cmds.charCount(try it.str(v));
                    stack[sp - 1] = .{ .int = @intCast(n) };
                },
                .string_index => {
                    const argv = [_]Value{ .{ .str = "string" }, .{ .str = "index" }, stack[sp - 2], stack[sp - 1] };
                    stack[sp - 2] = try cmds.cmdString(it, &argv, null);
                    sp -= 1;
                },
            },
            .guard => {
                if (it.epoch != it.safe_epoch and !recheck(it)) {
                    pc = i.a;
                    continue;
                }
                try step(it);
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .step => try step(it),
            .jump => {
                pc = i.a;
                continue;
            },
            .jump_false => {
                sp -= 1;
                const v = stack[sp];
                const t = if (v == .int) v.int != 0 else try expr.truthy(it, v);
                if (!t) {
                    pc = i.a;
                    continue;
                }
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .jump_true => {
                sp -= 1;
                const v = stack[sp];
                const t = if (v == .int) v.int != 0 else try expr.truthy(it, v);
                if (t) {
                    pc = i.a;
                    continue;
                }
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .to_bool => {
                const v = stack[sp - 1];
                const t = if (v == .int) v.int != 0 else try expr.truthy(it, v);
                stack[sp - 1] = .{ .int = @intFromBool(t) };
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .invoke => {
                try step(it);
                const c = code.sites[i.a];
                const argv = stack[sp - i.b .. sp];
                const command = try it.resolve(c, argv);
                const r = try it.call(command, argv, c);
                sp -= i.b;
                stack[sp] = r;
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .eval_cmd => {
                stack[sp] = try it.evalCmd(code.sites[i.a]);
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .word => {
                stack[sp] = try it.evalWord(code.words[i.a]);
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .node => {
                stack[sp] = try expr.eval(it, code.nodes[i.a]);
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .concat => {
                const r = try concatValues(it, stack[sp - i.a .. sp]);
                sp -= i.a;
                stack[sp] = r;
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .binary => {
                const op: expr.BinOp = @enumFromInt(i.x);
                const x = &stack[sp - 2];
                const y = &stack[sp - 1];
                if (x.* == .int and y.* == .int) {
                    const a = x.int;
                    const b = y.int;
                    x.* = if (intFast(op, a, b)) |r| .{ .int = r } else try expr.intOp(it, op, a, b);
                } else {
                    x.* = try expr.binaryOp(it, op, x.*, y.*);
                }
                sp -= 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .unary => stack[sp - 1] = try expr.unaryOp(it, @enumFromInt(i.x), stack[sp - 1]),
            .number_form => {
                const v = stack[sp - 1];
                if (v == .str) stack[sp - 1] = try expr.numberForm(it, v);
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .incr => {
                const found = readCell(named, it, f, code, i.a);
                const by: i32 = @bitCast(i.b);
                if (found != null and found.?.v == .val and found.?.v.val == .int and addFits(found.?.v.val.int, by)) {
                    const cell = found.?;
                    const out: Value = .{ .int = cell.v.val.int + by };
                    cell.v = .{ .val = out };
                    stack[sp] = out;
                } else {
                    stack[sp] = try slowIncr(it, code.names[i.a], .{ .int = by });
                }
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .incr_value => {
                const found = readCell(named, it, f, code, i.a);
                const by = stack[sp - 1];
                if (by == .int and found != null and found.?.v == .val and found.?.v.val == .int and addFits(found.?.v.val.int, by.int)) {
                    const cell = found.?;
                    const out: Value = .{ .int = cell.v.val.int + by.int };
                    cell.v = .{ .val = out };
                    stack[sp - 1] = out;
                } else {
                    stack[sp - 1] = try slowIncr(it, code.names[i.a], by);
                }
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .lappend => {
                const found = readCell(named, it, f, code, i.a);
                if (found != null and found.?.v == .val and found.?.v.val == .list) {
                    const cell = found.?;
                    const out: Value = .{ .list = try cell.v.val.list.append(it.alloc(), stack[sp - 1]) };
                    cell.v = .{ .val = out };
                    stack[sp - 1] = out;
                } else {
                    stack[sp - 1] = try slowLappend(it, code.names[i.a], stack[sp - 1]);
                }
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .store_pop => {
                const cell = try writeCell(named, it, f, code, i.a);
                sp -= 1;
                if (cell.v == .val) {
                    cell.v.val = stack[sp];
                    pc += 1;
                    i = &ins[pc];
                    continue :sw i.op;
                }
                if (!cell.plainStore()) {
                    @branchHint(.cold);
                    try slowStore(it, code.names[i.a], &stack[sp]);
                    pc += 1;
                    i = &ins[pc];
                    continue :sw i.op;
                }
                cell.v = .{ .val = stack[sp] };
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .incr_drop => {
                const found = readCell(named, it, f, code, i.a);
                const by: i32 = @bitCast(i.b);
                if (found != null and found.?.v == .val and found.?.v.val == .int and addFits(found.?.v.val.int, by)) {
                    const cell = found.?;
                    const out: Value = .{ .int = cell.v.val.int + by };
                    cell.v = .{ .val = out };
                } else {
                    _ = try slowIncr(it, code.names[i.a], .{ .int = by });
                }
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .bin_vv => {
                const op: expr.BinOp = @enumFromInt(i.x);
                const x = intSlot(named, it, f, code, i.a);
                const y = intSlot(named, it, f, code, i.b);
                if (x != null and y != null) {
                    stack[sp] = if (intFast(op, x.?, y.?)) |r| .{ .int = r } else try expr.intOp(it, op, x.?, y.?);
                } else {
                    const vx = try readSlot(named, it, f, code, i.a);
                    const vy = try readSlot(named, it, f, code, i.b);
                    stack[sp] = try slowBinary(it, op, vx, vy);
                }
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .bin_vi => {
                const op: expr.BinOp = @enumFromInt(i.x);
                const y = code.lits[i.b].int;
                if (intSlot(named, it, f, code, i.a)) |x| {
                    stack[sp] = if (intFast(op, x, y)) |r| .{ .int = r } else try expr.intOp(it, op, x, y);
                } else {
                    const vx = try readSlot(named, it, f, code, i.a);
                    stack[sp] = try slowBinary(it, op, vx, .{ .int = y });
                }
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .jf_vv => {
                const op: expr.BinOp = @enumFromInt(i.x);
                const x = intSlot(named, it, f, code, i.a);
                const y = intSlot(named, it, f, code, i.b);
                var t: bool = undefined;
                if (x != null and y != null) {
                    t = intCompare(op, x.?, y.?);
                } else {
                    const vx = try readSlot(named, it, f, code, i.a);
                    const vy = try readSlot(named, it, f, code, i.b);
                    t = try expr.truthy(it, try slowBinary(it, op, vx, vy));
                }
                if (!t) {
                    pc = i.c;
                    continue;
                }
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .jf_vi => {
                const op: expr.BinOp = @enumFromInt(i.x);
                const y = code.lits[i.b].int;
                var t: bool = undefined;
                if (intSlot(named, it, f, code, i.a)) |x| {
                    t = intCompare(op, x, y);
                } else {
                    const vx = try readSlot(named, it, f, code, i.a);
                    t = try expr.truthy(it, try slowBinary(it, op, vx, .{ .int = y }));
                }
                if (!t) {
                    pc = i.c;
                    continue;
                }
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .dict_update => {
                const nv: u32 = 1 + @as(u32, i.x);
                const r = try dictSlow(it, code.sites[i.b], stack[sp - nv .. sp]);
                sp -= nv;
                stack[sp] = r;
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .dict_update_drop => {
                const nv: u32 = 1 + @as(u32, i.x);
                const cell = f.vars.items[i.a].cell.target();
                const new: ?Value = if (i.x == 1) stack[sp - 1] else null;
                if (cell.v != .owned or !try dict.updateOwned(it, cell.v.owned, stack[sp - nv], 1, new)) {
                    const old: ?*value.ListObj = switch (cell.v) {
                        .owned => |v| v.list.obj,
                        .val => |v| if (v == .list) v.list.obj else null,
                        else => null,
                    };
                    const was_owned = cell.v == .owned;
                    if (was_owned) {
                        const v = cell.v.owned;
                        cell.v = .{ .val = v };
                    }
                    _ = try dictSlow(it, code.sites[i.b], stack[sp - nv .. sp]);
                    // A new buffer has only this cell as a holder. An
                    // owned buffer that got a new key also has only
                    // this cell.
                    const now = f.vars.items[i.a].cell.target();
                    if (now.v == .val and dict.isMarked(now.v.val) and (was_owned or now.v.val.list.obj != old)) {
                        const v = now.v.val;
                        now.v = .{ .owned = v };
                    }
                }
                sp -= nv;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .append => {
                const r = try appendValues(named, it, f, code, i.a, stack[sp - i.b .. sp]);
                sp -= i.b;
                stack[sp] = r;
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .ret => return stack[sp - 1],
            .foreach_init => {
                const items = try it.list(stack[sp - 1]);
                if (stack[sp - 1] != .list) stack[sp - 1] = try value.newList(it.alloc(), items);
                stack[sp] = .{ .int = 0 };
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .foreach_next => {
                const table = code.tables[i.a];
                const items = stack[sp - 2].list.items();
                const at: usize = @intCast(stack[sp - 1].int);
                if (at >= items.len) {
                    pc = i.b;
                    continue;
                }
                try step(it);
                for (table, 0..) |slot, k| {
                    const cell = try writeCell(named, it, f, code, slot);
                    const src: *const Value = if (at + k < items.len) &items[at + k] else &Value.empty;
                    // A cell with a value needs no new tag.
                    if (cell.v == .val) {
                        cell.v.val = src.*;
                        continue;
                    }
                    // An array, a traced cell, or an element link.
                    if (!cell.plainStore()) {
                        @branchHint(.cold);
                        try slowForeach(it, code, table, items, at, k);
                        stack[sp - 1] = .{ .int = @intCast(at + table.len) };
                        pc += 1;
                        i = &ins[pc];
                        continue :sw i.op;
                    }
                    cell.v = .{ .val = src.* };
                }
                stack[sp - 1] = .{ .int = @intCast(at + table.len) };
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
        }
        pc += 1;
    }
}

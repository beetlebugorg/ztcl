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
const gc = @import("gc.zig");
const expr = @import("expr.zig");
const value = @import("value.zig");
const cmds = @import("cmds.zig");
const dict = @import("dict.zig");
const more = @import("more.zig");
const jit = @import("jit.zig");
const aot = @import("wasm_aot/rt.zig");

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
    /// Pushes the value of slot `a`. With `x` 1, a list that the cell
    /// owns stays owned: an `access` reads the value at once, and no
    /// instruction between can run a script or write a cell.
    load,
    /// Writes the top of the stack to slot `a`. The value stays.
    store,
    /// Runs the read form `x` (`Access`) on the top values of the stack.
    access,
    /// Jumps to `a` when a core command changed. Uses one step of the compute limit.
    guard,
    /// Uses one step of the compute limit. A loop pass runs this.
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
    /// Jumps to `b` when the string form of the top of the stack equals
    /// literal `a`. The value stays on the stack.
    str_eq_jump,
    /// Takes the list on the top of the stack and writes its items to the
    /// slots of table `a`. The top becomes the list of the items left.
    lassign,
    /// `lassign` with no result: the list leaves the stack.
    lassign_drop,
    /// `lset` on slot `a` with the index and the value on the stack, for
    /// command site `b`. The result is the new list.
    lset,
    /// `lset` with no result. The cell then owns the list.
    lset_drop,
    /// Pops a value and appends it to the list of `lmap` below the
    /// `foreach` state.
    lmap_add,
    /// `set name(index) value` on the array in slot `a`, with the index
    /// and the value on the stack. The value replaces the index.
    store_elem,
    /// Runs the probes of line `a` of the proc body (`probe.zig`). Line
    /// 0 is the entry. Uses no compute unit and changes no value.
    probe,
    /// `info exists name` of slot `a`: pushes 1 when the variable is
    /// there, 0 when it is not. Reads no trace.
    var_exists,
    /// The built-in function `x` (`expr.Func`) of `expr` on the `a`
    /// values on the stack: pops them and pushes the result. The parser
    /// made the call a built-in only when no script replaced the
    /// function, as for the `func` node.
    mathfunc,
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
pub const Range = struct {
    start: u32,
    end: u32,
    /// The command for the error trace, or null for a loop body.
    cmd: ?*Cmd = null,
    brk: u32 = no_target,
    cont: u32 = no_target,
    depth: u32 = 0,
    /// The loop of a body that Tcl does not compile outside a proc. An
    /// error that leaves the body gets the context line of that loop.
    ctx: enum(u8) { none, foreach, lmap } = .none,
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
    /// The compiled function (`jit.Fn`), valid only when `jit_gen` equals
    /// the generation of the JIT state of the interpreter.
    jit: ?*anyopaque = null,
    jit_gen: u64 = 0,
    /// The calls of the code before the JIT compiles it.
    jit_calls: u32 = 0,
    jit_state: enum(u8) { untried, failed, ready } = .untried,
    /// The proc of a body with `probe` instructions. The JIT does not
    /// compile such a body.
    probed: ?*interp.Proc = null,
    /// A body of the top level of the program of the debugger, with a
    /// `probe` instruction at each line (`probe.topBase`).
    probe_top: bool = false,
    /// The code of the same script for a caller that drops its result,
    /// such as the body of a loop (`compileDropped`).
    dropped: ?*Code = null,
};

// ---- The guard ----

const inline_names = [_][]const u8{
    "set",     "incr",   "expr",    "if",       "while",   "for",
    "foreach", "return", "break",   "continue", "lappend", "dict",
    "append",  "lindex", "llength", "string",   "switch",  "lassign",
    "lset",    "lmap",
};

/// The read forms of the `access` instruction.
const Access = enum(u8) { llength, lindex, string_length, string_index, dict_get, dict_exists, dict_size };

/// True when each inlined name is the original core command, in the
/// global namespace, and no namespace has a command of the same name.
/// Runs one time for each change of the epoch. The command table counts
/// the keys in a namespace with an inlined name, so the check does one
/// lookup for each inlined name. Its cost does not grow with the count
/// of commands, except at the first check, which counts the keys.
fn recheck(it: *Interp) bool {
    if (it.unsafe_epoch == it.epoch) return false;
    if (it.var_traces != 0 or it.exec_strict != 0 or it.commands.shadowCount() != 0) {
        it.unsafe_epoch = it.epoch;
        return false;
    }
    inline for (inline_names) |name| {
        const c = it.commands.get(name);
        const original = c != null and c.?.impl == .native and c.?.impl.native == comptime cmds.coreFn(name).?;
        if (!original) {
            it.unsafe_epoch = it.epoch;
            return false;
        }
    }
    it.safe_epoch = it.epoch;
    return true;
}

/// The inlined names as a table that compares only the names of the
/// same length.
const inline_table = blk: {
    var pairs: [inline_names.len]struct { []const u8 } = undefined;
    for (inline_names, 0..) |n, k| pairs[k] = .{n};
    break :blk std.StaticStringMap(void).initComptime(pairs);
};

/// For each byte, a bit for each length of an inlined name that ends
/// with the byte.
pub const inline_lens: [256]u16 = blk: {
    var t: [256]u16 = @splat(0);
    for (inline_names) |n| t[n[n.len - 1]] |= 1 << n.len;
    break :blk t;
};

pub fn isInlineName(s: []const u8) bool {
    return inline_table.has(s);
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
    /// The command that compiles now is the last command of an arm of
    /// an `if` or a `switch` whose result no code reads. An inline
    /// `lset` or `lassign` then drops its result itself.
    arm_drop: bool = false,
    /// The result of the command that compiles now is dropped.
    dropped: bool = false,
    /// The lines of the body with a probe, and the line in the body of
    /// line 1 of the script that compiles now. `bases` has that line for
    /// each nested script that an inline form compiles.
    probe_lines: []const u32 = &.{},
    line_base: u32 = 1,
    /// The line of the command that compiles now. A command in it on
    /// the same line gets no second probe.
    outer_line: u32 = 0,
    bases: std.AutoHashMapUnmanaged(*interp.Script, u32) = .empty,

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
            if (cold.back == c.here() and (last.op == .store or last.op == .incr or last.op == .dict_update or last.op == .lassign or last.op == .lset)) {
                last.op = switch (last.op) {
                    .store => .store_pop,
                    .incr => .incr_drop,
                    .lassign => .lassign_drop,
                    .lset => .lset_drop,
                    else => .dict_update_drop,
                };
                cold.drop = true;
                return;
            }
        }
        // The command of an `invoke` just before the pop can keep the
        // ownership of the variable that it writes.
        if (n > 0 and c.label != c.here() and c.ins.items[n - 1].op == .invoke) c.ins.items[n - 1].x = 1;
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
            _ = try c.emit(.{ .op = .bin_vv, .x = @backingInt(op), .a = a, .b = (try c.varNode(y)).? });
        } else {
            _ = try c.emit(.{ .op = .bin_vi, .x = @backingInt(op), .a = a, .b = try c.intLit(y) });
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
                    return c.emit(.{ .op = .jf_vv, .x = @backingInt(b.op), .a = a, .b = (try c.varNode(b.b)).? });
                }
                return c.emit(.{ .op = .jf_vi, .x = @backingInt(b.op), .a = a, .b = try c.intLit(b.b) });
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
        return c.compileScriptAs(s, .used);
    }

    /// `used`: the code reads the result of the script. `pop`: a `pop`
    /// follows the script. `arm`: the script is an arm of a command
    /// whose result is dropped.
    const ScriptUse = enum { used, pop, arm };

    fn compileScriptAs(c: *Compiler, s: *interp.Script, use: ScriptUse) Error!void {
        c.nest += 1;
        defer c.nest -= 1;
        const base = c.line_base;
        defer c.line_base = base;
        if (probe_on and c.probe_lines.len != 0) {
            if (c.bases.get(s)) |b| c.line_base = b;
        }
        if (s.cmds.len == 0) {
            _ = try c.emit(.{ .op = .push_empty });
            c.push(1);
            return;
        }
        for (s.cmds, 0..) |*cmd, i| {
            if (i > 0) try c.emitPop();
            const last = i + 1 == s.cmds.len;
            c.dropped = !last or use != .used;
            c.arm_drop = last and use == .arm;
            try c.compileCmd(cmd);
        }
    }

    /// The use of the arms of the command that compiles now.
    fn armUse(c: *Compiler) ScriptUse {
        return if (c.dropped) .arm else .used;
    }

    /// Ends an inline `lset` or `lassign` that dropped its result: the
    /// cold block drops the result of the general command too, and an
    /// empty string stands for the result.
    fn armDropped(c: *Compiler) Allocator.Error!void {
        c.colds.items[c.colds.items.len - 1].drop = true;
        _ = try c.emit(.{ .op = .push_empty });
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
                _ = try c.emit(.{ .op = .unary, .x = @backingInt(u.op) });
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
                    _ = try c.emit(.{ .op = .binary, .x = @backingInt(b.op) });
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
            .func => |*fc| {
                // The arguments as bytecode and one instruction for the
                // function: no tree walk for each run, and the JIT sees
                // the call.
                if (fc.args.len == 0 or fc.args.len > 64) return c.fallbackNode(n);
                for (fc.args) |arg| try c.compileNode(arg);
                _ = try c.emit(.{ .op = .mathfunc, .a = @intCast(fc.args.len), .x = @intCast(@backingInt(fc.f)) });
                c.depth -= @intCast(fc.args.len);
                c.push(1);
            },
            .parts, .call => try c.fallbackNode(n),
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
        const s = try c.bodyScriptOf(cmd, i) orelse return null;
        if (probe_on and c.probe_lines.len != 0) {
            const at = c.line_base + cmd.line - 1;
            try c.bases.put(@import("probe.zig").embedderAlloc(c.it), s, at + cmd.words[i].line - cmd.line);
        }
        return s;
    }

    /// Parses each literal word with a space, a semicolon, or a newline
    /// as a script, and the scripts in it, so that each gets its line in
    /// the body (`bases`). A general command such as `catch` runs such a
    /// script with `evalScript`, and `compileNamed` then puts the probes
    /// in it. A word that is not a script gets a parsed form that no
    /// code runs.
    fn walk(c: *Compiler, s: *interp.Script, depth: u32) Error!void {
        if (depth > 64) return;
        const base = c.line_base;
        defer c.line_base = base;
        if (c.bases.get(s)) |b| c.line_base = b;
        for (s.cmds) |*cmd| {
            for (cmd.words, 0..) |w, i| {
                if (i == 0 or w.kind != .lit or w.kind.lit != .str) continue;
                if (std.mem.indexOfAny(u8, w.kind.lit.str, " \n;") == null) continue;
                const inner = try c.bodyScript(cmd, i) orelse continue;
                try c.walk(inner, depth + 1);
            }
        }
    }

    fn bodyScriptOf(c: *Compiler, cmd: *Cmd, i: usize) Error!?*interp.Script {
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
        const outer = c.outer_line;
        defer c.outer_line = outer;
        if (probe_on and c.probe_lines.len != 0) {
            const line = c.line_base + cmd.line - 1;
            if (line != outer and @import("probe.zig").wantsLine(c.probe_lines, line)) _ = try c.emit(.{ .op = .probe, .a = line });
            c.outer_line = line;
        }
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

    /// `set name(index) value`, where the word of the name starts with a
    /// literal plain name and "(", and ends with ")". The index is the
    /// text between, as `Interp.splitName` cuts it from the full name.
    fn compileSetElem(c: *Compiler, cmd: *Cmd) Error!bool {
        const w = &cmd.words[1];
        if (w.expand or c.nest >= max_nest) return false;
        var parts: []const Part = undefined;
        var one: [1]Part = undefined;
        switch (w.kind) {
            .lit => |v| {
                if (v != .str) return false;
                one[0] = .{ .lit = v.str };
                parts = &one;
            },
            .multi => |m| parts = m,
            .single => return false,
        }
        const first = parts[0];
        const last = parts[parts.len - 1];
        if (first != .lit or last != .lit) return false;
        const open = std.mem.indexOfScalar(u8, first.lit, '(') orelse return false;
        if (!plain(first.lit[0..open])) return false;
        if (last.lit.len == 0 or last.lit[last.lit.len - 1] != ')') return false;
        if (parts.len == 1 and last.lit.len < open + 2) return false;
        for (parts) |*p| if (!simplePart(p)) return false;
        const base = c.depth;
        const g = try c.emit(.{ .op = .guard });
        const start = c.here();
        // The pieces of the index: the rest of the first literal, the
        // parts between, and the last literal with no ")".
        var count: u32 = 0;
        if (parts.len == 1) {
            const text = first.lit[open + 1 .. first.lit.len - 1];
            if (text.len > 0) {
                try c.lit(.{ .str = text });
                count += 1;
            }
        } else {
            if (first.lit.len > open + 1) {
                try c.lit(.{ .str = first.lit[open + 1 ..] });
                count += 1;
            }
            for (parts[1 .. parts.len - 1]) |*p| {
                try c.compilePart(p);
                count += 1;
            }
            if (last.lit.len > 1) {
                try c.lit(.{ .str = last.lit[0 .. last.lit.len - 1] });
                count += 1;
            }
        }
        if (count == 0) {
            _ = try c.emit(.{ .op = .push_empty });
            c.push(1);
        } else if (count > 1) {
            _ = try c.emit(.{ .op = .concat, .a = count });
            c.depth -= count;
            c.push(1);
        }
        try c.compileWord(&cmd.words[2]);
        _ = try c.emit(.{ .op = .store_elem, .a = try c.slot(first.lit[0..open]) });
        try c.closeGuard(cmd, base, g, start);
        return true;
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
        } else if (eql(u8, name, "dict") and n == 4 and isWord(cmd.words[1], "get")) {
            kind = .dict_get;
            first = 2;
        } else if (eql(u8, name, "dict") and n == 4 and isWord(cmd.words[1], "exists")) {
            kind = .dict_exists;
            first = 2;
        } else if (eql(u8, name, "dict") and n == 3 and isWord(cmd.words[1], "size")) {
            kind = .dict_size;
            first = 2;
        } else return false;
        const base = c.depth;
        const g = try c.emit(.{ .op = .guard });
        const start = c.here();
        const keeps = switch (kind) {
            .string_length, .string_index => false,
            else => true,
        };
        if (!c.named and keeps and peekable(cmd, first)) {
            // The list in an owned cell stays owned: the guard turns
            // the inline forms off while a variable has a trace, so the
            // load of a plain index or key runs no script.
            const v = cmd.words[first].kind.single.variable;
            _ = try c.emit(.{ .op = .load, .x = 1, .a = try c.slot(v.name) });
            c.push(1);
            for (cmd.words[first + 1 ..]) |*w| try c.compileWord(w);
        } else {
            for (cmd.words[first..]) |*w| try c.compileWord(w);
        }
        _ = try c.emit(.{ .op = .access, .x = @backingInt(kind) });
        try c.closeGuard(cmd, base, g, start);
        return true;
    }

    /// `info exists name` with a literal plain name in a proc: a test of
    /// the slot. The guard runs the general command when `info` changed.
    fn compileInfoExists(c: *Compiler, cmd: *Cmd, name: []const u8) Error!bool {
        if (c.named or cmd.words.len != 3 or !std.mem.eql(u8, name, "info")) return false;
        if (!isWord(cmd.words[1], "exists") or cmd.words[2].kind != .lit or cmd.words[2].kind.lit != .str) return false;
        const v = cmd.words[2].kind.lit.str;
        if (!plain(v)) return false;
        const base = c.depth;
        const g = try c.emit(.{ .op = .guard });
        const start = c.here();
        _ = try c.emit(.{ .op = .var_exists, .a = try c.slot(v) });
        try c.closeGuard(cmd, base, g, start);
        return true;
    }

    /// The list or dict word `at` is one plain variable, and the word
    /// after it (the index of `lindex`, the key of `dict get` and `dict
    /// exists`) has only literal text and plain variables, such as
    /// `$x,$y`. So the loads between the peek and the access run no
    /// script.
    fn peekable(cmd: *Cmd, at: usize) bool {
        const w = cmd.words[at];
        if (w.kind != .single or w.kind.single != .variable) return false;
        const v = w.kind.single.variable;
        if (v.index != null or !plain(v.name)) return false;
        if (cmd.words.len == at + 1) return true;
        return switch (cmd.words[at + 1].kind) {
            .lit => true,
            .single => |*p| loadPart(p),
            .multi => |parts| for (parts) |*p| {
                if (!loadPart(p)) break false;
            } else true,
        };
    }

    /// A literal part, or a plain variable with no index.
    fn loadPart(p: *const Part) bool {
        return switch (p.*) {
            .lit => true,
            .variable => |*v| v.index == null and plain(v.name),
            .script => false,
        };
    }

    fn compileInline(c: *Compiler, cmd: *Cmd, name: []const u8) Error!bool {
        if (try c.compileAccess(cmd, name)) return true;
        if (try c.compileInfoExists(cmd, name)) return true;
        const n = cmd.words.len;
        const eql = std.mem.eql;
        if (eql(u8, name, "set")) {
            if (n == 3 and nameWord(cmd, 1) == null) return c.compileSetElem(cmd);
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
        } else if (eql(u8, name, "dict") and n == 5 and isWord(cmd.words[1], "for")) {
            return c.compileForeach(cmd, false, true);
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
            return c.compileForeach(cmd, false, false);
        } else if (eql(u8, name, "lmap")) {
            return c.compileForeach(cmd, true, false);
        } else if (eql(u8, name, "switch")) {
            if (try c.compileSwitch(cmd)) return true;
            try c.listSwitchBody(cmd);
            return false;
        } else if (eql(u8, name, "lassign")) {
            return c.compileLassign(cmd);
        } else if (eql(u8, name, "lset")) {
            // Slots of a proc only: a named cell has no owned form.
            if (c.named or n != 4 or nameWord(cmd, 1) == null) return false;
            const drop = c.arm_drop;
            const base = c.depth;
            const g = try c.emit(.{ .op = .guard });
            const start = c.here();
            const s = try c.slot(nameWord(cmd, 1).?);
            try c.compileWord(&cmd.words[2]);
            try c.compileWord(&cmd.words[3]);
            _ = try c.emit(.{ .op = if (drop) .lset_drop else .lset, .a = s, .b = try c.site(cmd) });
            try c.closeGuard(cmd, base, g, start);
            if (drop) try c.armDropped();
            return true;
        } else return false;

        // A nested script in a word sets `arm_drop` again.
        const arm_drop = c.arm_drop;
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
                // In an arm whose result is dropped, the cell can own
                // the dict, as for a statement.
                _ = try c.emit(.{ .op = if (arm_drop) .dict_update_drop else .dict_update, .x = @intFromBool(n == 5), .a = s, .b = try c.site(cmd) });
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
        if (name[0] == 'd' and arm_drop) try c.armDropped();
        return true;
    }

    /// Ends an inline form: adds its range and its general path.
    fn closeGuard(c: *Compiler, cmd: *Cmd, base: u32, g: u32, start: u32) Error!void {
        try c.ranges.append(c.a, .{ .start = start, .end = c.here(), .cmd = cmd });
        try c.colds.append(c.a, .{ .guard = g, .site = try c.site(cmd), .back = c.here() });
        c.depth = base;
        c.push(1);
    }

    /// The script of the text of a body, or null when it does not compile.
    fn textScript(c: *Compiler, text: []const u8) Error!?*interp.Script {
        const it = c.it;
        const r, const code, const line = .{ it.result, it.error_code, it.error_line };
        return it.compile(text) catch |e| {
            if (e == error.OutOfMemory) return e;
            it.result, it.error_code, it.error_line = .{ r, code, line };
            return null;
        };
    }

    /// A `switch` that the compiler does not compile, such as one with
    /// `-regexp`, runs the command. When its patterns and bodies are one
    /// literal word, that word becomes a list value here, so the command
    /// does not parse the list at each call. Tcl keeps the list form of
    /// the literal in the same way.
    fn listSwitchBody(c: *Compiler, cmd: *Cmd) Error!void {
        const w = cmd.words;
        var i: usize = 1;
        while (i < w.len) : (i += 1) {
            if (w[i].kind != .lit or w[i].kind.lit != .str) return;
            const opt = w[i].kind.lit.str;
            if (opt.len == 0 or opt[0] != '-') break;
            if (std.mem.eql(u8, opt, "--")) {
                i += 1;
                break;
            }
            const known = [_][]const u8{ "-exact", "-glob", "-regexp", "-nocase" };
            const takes_arg = std.mem.eql(u8, opt, "-matchvar") or std.mem.eql(u8, opt, "-indexvar");
            if (takes_arg) {
                i += 1;
                continue;
            }
            for (known) |k| {
                if (std.mem.eql(u8, opt, k)) break;
            } else return;
        }
        // The subject and one word of patterns and bodies.
        if (w.len != i + 2 or w[i + 1].expand or w[i + 1].kind != .lit or w[i + 1].kind.lit != .str) return;
        const items = w[i + 1].kind.lit.asList(c.it.alloc()) catch return;
        if (items.len < 2 or items.len % 2 != 0) return;
        w[i + 1].kind = .{ .lit = try value.newList(c.it.alloc(), items) };
    }

    /// `switch ?-exact|-glob? ?--? string {pattern body ...}`, also with the
    /// patterns and bodies as separate literal words. Each pattern and
    /// each body is literal. Without `--`, the string must be a literal
    /// that does not start with "-", because the general command reads
    /// such a value as an option. The code tests each pattern with
    /// `str_eq_jump` (with `x` = 1 for `-glob`), and each body ends with
    /// a jump to the end.
    fn compileSwitch(c: *Compiler, cmd: *Cmd) Error!bool {
        const it = c.it;
        const w = cmd.words;
        var i: usize = 1;
        var glob = false;
        if (i < w.len and isWord(w[i], "-exact")) {
            i += 1;
        } else if (i < w.len and isWord(w[i], "-glob")) {
            glob = true;
            i += 1;
        }
        const dashes = i < w.len and isWord(w[i], "--");
        if (dashes) i += 1;
        if (i + 1 >= w.len) return false;
        const subject = i;
        if (!dashes) {
            if (w[subject].kind != .lit) return false;
            const s = try it.str(w[subject].kind.lit);
            if (s.len > 0 and s[0] == '-') return false;
        }
        i += 1;
        const Arm = struct { pat: []const u8, body: ?*interp.Script };
        var arms: std.ArrayList(Arm) = .empty;
        if (w.len - i == 1) {
            if (w[i].kind != .lit) return false;
            const items = try it.list(w[i].kind.lit);
            if (items.len == 0 or items.len % 2 != 0) return false;
            var k: usize = 0;
            while (k < items.len) : (k += 2) {
                const body = try it.str(items[k + 1]);
                const s: ?*interp.Script = if (std.mem.eql(u8, body, "-")) null else try c.textScript(body) orelse return false;
                try arms.append(c.a, .{ .pat = try it.str(items[k]), .body = s });
            }
        } else {
            // Tcl compiles arms in separate words only after "--". Each
            // other form adds the line of the arm to an error trace.
            if (!dashes) return false;
            if ((w.len - i) % 2 != 0) return false;
            if (!allLiteral(cmd)) return false;
            var k = i;
            while (k < w.len) : (k += 2) {
                const body = try it.str(w[k + 1].kind.lit);
                const s: ?*interp.Script = if (std.mem.eql(u8, body, "-")) null else try c.bodyScript(cmd, k + 1) orelse return false;
                try arms.append(c.a, .{ .pat = try it.str(w[k].kind.lit), .body = s });
            }
        }
        const last = arms.items.len - 1;
        if (arms.items[last].body == null) return false;
        const has_default = std.mem.eql(u8, arms.items[last].pat, "default");

        const use = c.armUse();
        const base = c.depth;
        const g = try c.emit(.{ .op = .guard });
        const start = c.here();
        try c.compileWord(&w[subject]);
        // The tests. The jump targets are set after the bodies.
        const tests = try c.a.alloc(u32, arms.items.len);
        for (arms.items, 0..) |arm, k| {
            if (has_default and k == last) {
                tests[k] = no_target;
                continue;
            }
            try c.lits.append(c.a, .{ .str = arm.pat });
            tests[k] = try c.emit(.{ .op = .str_eq_jump, .x = @intFromBool(glob), .a = @intCast(c.lits.items.len - 1) });
        }
        var ends: std.ArrayList(u32) = .empty;
        var default_jump: u32 = no_target;
        if (has_default) {
            default_jump = try c.emit(.{ .op = .jump });
        } else {
            _ = try c.emit(.{ .op = .pop });
            _ = try c.emit(.{ .op = .push_empty });
            try ends.append(c.a, try c.emit(.{ .op = .jump }));
        }
        // The bodies. A "-" body shares the body of the next arm.
        const labels = try c.a.alloc(u32, arms.items.len);
        for (arms.items, 0..) |arm, k| {
            const body = arm.body orelse {
                labels[k] = no_target;
                continue;
            };
            labels[k] = c.here();
            c.label = c.here();
            _ = try c.emit(.{ .op = .pop });
            c.depth = base;
            try c.compileScriptAs(body, use);
            if (k != last) try ends.append(c.a, try c.emit(.{ .op = .jump }));
        }
        var next: u32 = no_target;
        var k = arms.items.len;
        while (k > 0) {
            k -= 1;
            if (labels[k] != no_target) next = labels[k] else labels[k] = next;
        }
        for (tests, 0..) |t, n| {
            if (t != no_target) c.ins.items[t].b = labels[n];
        }
        if (default_jump != no_target) c.ins.items[default_jump].a = labels[last];
        const end = c.here();
        c.label = end;
        for (ends.items) |e| c.ins.items[e].a = end;
        try c.closeGuard(cmd, base, g, start);
        return true;
    }

    /// `lassign list name ...` with 1 to 8 literal plain names.
    fn compileLassign(c: *Compiler, cmd: *Cmd) Error!bool {
        const n = cmd.words.len;
        if (n < 3 or n > 10) return false;
        for (1..n) |k| {
            if (k > 1 and (nameWord(cmd, k) == null or std.mem.eql(u8, nameWord(cmd, k).?, "tcl_precision"))) return false;
        }
        const table = try c.a.alloc(u32, n - 2);
        for (table, 2..) |*t, k| t.* = try c.slot(nameWord(cmd, k).?);
        try c.tables.append(c.a, table);
        const drop = c.arm_drop;
        const base = c.depth;
        const g = try c.emit(.{ .op = .guard });
        const start = c.here();
        try c.compileWord(&cmd.words[1]);
        _ = try c.emit(.{ .op = if (drop) .lassign_drop else .lassign, .a = @intCast(c.tables.items.len - 1) });
        try c.closeGuard(cmd, base, g, start);
        if (drop) try c.armDropped();
        return true;
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
        const use = c.armUse();
        const base = c.depth;
        const g = try c.emit(.{ .op = .guard });
        const start = c.here();
        var ends: std.ArrayList(u32) = .empty;
        for (clauses.items) |cl| {
            const next = try c.jumpFalse(cl.cond);
            c.depth = base;
            try c.compileScriptAs(cl.body, use);
            try ends.append(c.a, try c.emit(.{ .op = .jump }));
            c.patch(next);
            c.depth = base;
        }
        if (other) |s| {
            try c.compileScriptAs(s, use);
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
        try c.compileScriptAs(s, .pop);
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

    /// `foreach`, or `lmap` with `collect`, or `dict for` with `pairs`.
    /// The list of `lmap` is on the stack below the state of the loop,
    /// and `lmap_add` appends the result of each pass that ends with no
    /// `continue`. `dict for {k v} d body` is `foreach {k v}` on the pairs
    /// of the dict (`dict.forPairs`): the same passes, compute units,
    /// break, continue, and empty result.
    fn compileForeach(c: *Compiler, cmd: *Cmd, collect: bool, comptime pairs: bool) Error!bool {
        const w0: usize = if (pairs) 2 else 1;
        if (cmd.words.len != w0 + 3 or cmd.words[w0].kind != .lit or cmd.words[w0 + 2].kind != .lit) return false;
        const it = c.it;
        const r, const code = .{ it.result, it.error_code };
        const names = it.list(cmd.words[w0].kind.lit) catch |e| {
            if (e == error.OutOfMemory) return e;
            it.result, it.error_code = .{ r, code };
            return false;
        };
        if (names.len == 0 or (pairs and names.len != 2)) return false;
        for (names) |v| if (v != .str or !plain(v.str) or std.mem.eql(u8, v.str, "tcl_precision")) return false;
        const body = try c.bodyScript(cmd, w0 + 2) orelse return false;
        const table = try c.a.alloc(u32, names.len);
        for (names, table) |v, *t| t.* = try c.slot(v.str);
        try c.tables.append(c.a, table);
        const base = c.depth;
        const g = try c.emit(.{ .op = .guard });
        const start = c.here();
        const state: u32 = if (collect) base + 3 else base + 2;
        if (collect) {
            _ = try c.emit(.{ .op = .push_empty });
            c.push(1);
        }
        try c.compileWord(&cmd.words[w0 + 1]);
        _ = try c.emit(.{ .op = .foreach_init, .b = @intFromBool(pairs) });
        c.push(1);
        c.label = c.here();
        const top = try c.emit(.{ .op = .foreach_next, .a = @intCast(c.tables.items.len - 1) });
        var loop: Loop = .{ .body_depth = state };
        const body_start = c.here();
        if (collect) {
            try c.loops.append(c.a, &loop);
            defer _ = c.loops.pop();
            try c.compileScriptAs(body, .used);
            _ = try c.emit(.{ .op = .lmap_add });
            c.depth -= 1;
        } else try c.loopBody(&loop, body);
        const body_end = c.here();
        _ = try c.emit(.{ .op = .jump, .a = top });
        const end = c.here();
        c.label = end;
        c.ins.items[top].b = end;
        for (loop.breaks.items) |j| c.ins.items[j].a = end;
        for (loop.conts.items) |j| c.ins.items[j].a = top;
        try c.ranges.append(c.a, .{ .start = body_start, .end = body_end, .brk = end, .cont = top, .depth = state, .ctx = if (!c.named) .none else if (collect) .lmap else .foreach });
        _ = try c.emit(.{ .op = .pop });
        _ = try c.emit(.{ .op = .pop });
        c.depth = base;
        if (!collect) _ = try c.emit(.{ .op = .push_empty });
        c.push(1);
        try c.closeGuard(cmd, base, g, start);
        return true;
    }
};

/// Compiles the body of a proc. The slots of the parameters come first.
/// A build without the module `ztcl::probe` compiles no probe code.
const probe_on = @import("probe.zig").enabled;

pub fn compileProc(it: *Interp, p: *interp.Proc, s: *interp.Script) Error!*Code {
    const a = it.alloc();
    var c: Compiler = .{ .it = it, .a = a };
    for (p.params) |prm| try c.names.append(a, prm.name);
    if (p.has_args) try c.names.append(a, "args");
    const params: u32 = @intCast(c.names.items.len);
    const lines = if (probe_on and it.probes != null) try @import("probe.zig").linesFor(it, p) else null;
    defer if (lines) |l| {
        @import("probe.zig").embedderAlloc(it).free(l);
        c.bases.deinit(@import("probe.zig").embedderAlloc(it));
    };
    if (lines) |l| {
        c.probe_lines = l;
        try c.walk(s, 0);
        if (@import("probe.zig").wantsLine(l, 0)) _ = try c.emit(.{ .op = .probe, .a = 0 });
    }
    try c.compileScript(s);
    _ = try c.emit(.{ .op = .ret });
    try c.finish();
    if (lines != null) try @import("probe.zig").noteScripts(it, p, &c.bases);
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
        .probed = if (lines != null) p else null,
    };
    // Test builds only: the JIT verifier checks each proc body.
    if (@import("builtin").is_test) @import("jit/verify.zig").testHook(code);
    return code;
}

/// Compiles a script that runs in any frame. Its variables use names.
pub fn compileNamed(it: *Interp, s: *interp.Script) Error!*Code {
    return compileNamedAs(it, s, false);
}

/// `compileNamed` for a caller that drops the result of the script. The
/// last command then drops its result too, so a `dict` or `lset` on a
/// variable can keep the ownership of its value and write it in place,
/// as in the loop of a proc body. The result of the code is empty.
pub fn compileDropped(it: *Interp, s: *interp.Script) Error!*Code {
    return compileNamedAs(it, s, true);
}

fn compileNamedAs(it: *Interp, s: *interp.Script, drop: bool) Error!*Code {
    const a = it.alloc();
    var c: Compiler = .{ .it = it, .a = a, .named = true };
    // A script of a proc body with probes gets the probes of its lines.
    const of = if (probe_on and it.probes != null) @import("probe.zig").scriptOf(it, s) else null;
    const lines = if (of) |e| try @import("probe.zig").linesFor(it, e.proc) else null;
    // A body of the top level of the program of the debugger.
    const top_base = if (probe_on and of == null and it.probes != null) @import("probe.zig").topBase(it, s) else null;
    defer if (lines != null or top_base != null) {
        if (lines) |l| @import("probe.zig").embedderAlloc(it).free(l);
        c.bases.deinit(@import("probe.zig").embedderAlloc(it));
    };
    if (lines) |l| {
        c.probe_lines = l;
        c.line_base = of.?.base;
        // The command of the body, such as `catch`, is on the first line.
        c.outer_line = of.?.base;
    } else if (top_base) |b| {
        c.probe_lines = &top_lines;
        c.line_base = b;
        c.outer_line = b;
    }
    if (drop) {
        try c.compileScriptAs(s, .pop);
        try c.emitPop();
        _ = try c.emit(.{ .op = .push_empty });
        c.push(1);
    } else try c.compileScript(s);
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
        .probed = if (lines != null) of.?.proc else null,
        .probe_top = top_base != null,
    };
    return code;
}

/// The lines of a body of the top level: each line.
const top_lines = [_]u32{std.math.maxInt(u32)};

// ---- The executor ----

inline fn cellAt(f: *Frame, slot: u32) *Var {
    return f.vars.items[slot].cell.settle();
}

/// Runs `dict incr` or `dict set` with the general command.
/// Inline: the JIT helpers also call it, and a call from `exec` made
/// bench/dictgrow.tcl 2 % longer.
inline fn dictSlow(it: *Interp, cmd: *Cmd, args: []const Value) Error!Value {
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

pub inline fn step(it: *Interp) Error!void {
    if (it.compute_limit == 0) return it.fail("compute limit reached", .{});
    it.compute_limit -= 1;
    // Each value of this run is on the value stack or in a cell here.
    if (it.counter.trip >= it.mem_limit) try it.memPoint(true);
}

/// The integer of a slot, or null for any other content.
inline fn intSlot(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, slot: u32) ?i64 {
    const cell = readCell(named, it, f, code, slot) orelse return null;
    if (cell.v == .val and cell.v.val == .int) return cell.v.val.int;
    return null;
}

/// A plain cell that holds the text of an integer in its canonical form
/// gets the integer. The string form stays the same, and the next read
/// of the cell needs no parse.
fn shimmer(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, slot: u32) void {
    const cell = readCell(named, it, f, code, slot) orelse return;
    if (cell.v != .val or cell.v.val != .str) return;
    const text = cell.v.val.str;
    if (text.len == 0 or text.len > 20) return;
    const n = value.parseInt(text) orelse return;
    var buf: [24]u8 = undefined;
    if (!std.mem.eql(u8, value.writeInt(&buf, n), text)) return;
    cell.v = .{ .val = .{ .int = n } };
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
/// Inline: the JIT helpers also call it, and a call from `exec` made
/// bench/strbuild.tcl 3.5 % longer.
inline fn appendValues(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, slot: u32, vals: []const Value) Error!Value {
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
pub fn run(it: *Interp, code: *Code) Error!Value {
    return runInline(it, code);
}

/// `run` inline, for the fast proc call.
pub inline fn runInline(it: *Interp, code: *Code) Error!Value {
    // A call from a script with machine code that is ready takes the
    // short entry. A host entry (nest 0) takes the full path.
    if (jit.built and !gc.precise and it.jit != null and it.nest != 0 and code.jit_state == .ready) {
        if (jit.readyFn(it, code)) |f| return runReady(it, code, f, false);
    }
    return runFull(it, code);
}

/// `runInline` for a proc body in a new frame that has each name of the
/// body: the machine code starts at address 0 with no check of the
/// entry table.
pub inline fn runStart(it: *Interp, code: *Code) Error!Value {
    if (jit.built and !gc.precise and it.jit != null and it.nest != 0 and code.jit_state == .ready) {
        if (jit.readyFn(it, code)) |f| return runReady(it, code, f, true);
    }
    return runFull(it, code);
}

/// `run` for machine code that is ready, not at a host entry. The
/// checks and the limits are those of `runFull`.
inline fn runReady(it: *Interp, code: *Code, f: *jit.Fn, comptime start: bool) Error!Value {
    try it.checkNative();
    if (it.nest >= it.max_nest) return it.fail("too many nested evaluations (infinite loop?)", .{});
    it.nest += 1;
    defer it.nest -= 1;
    const mark = it.stackMark();
    defer it.stackRelease(mark);
    const stack = try it.stackAllocPub(code.max_stack);
    var pc: u32 = 0;
    var sp: u32 = 0;
    const st = if (start) jit.enterStart(it, f, code, stack.ptr, &pc, &sp) else @call(.always_inline, jit.enter, .{ it, f, code, stack.ptr, &pc, &sp });
    if (st == .done) return stack[sp - 1];
    return runRest(it, code, f, stack.ptr, pc, sp, st);
}

fn runFull(it: *Interp, code: *Code) Error!Value {
    const host = it.nest == 0 and it.heap.scopes == 0;
    if (host) it.heap.scopes = 1;
    defer if (host) {
        it.heap.scopes = 0;
    };
    // Each path into this function that does not set the token ends the
    // clean chain, so a new caller is safe with no change.
    const clean = gc.precise and it.gc_token;
    if (gc.precise) it.gc_token = false;
    try it.checkNative();
    if (it.nest >= it.max_nest) return it.fail("too many nested evaluations (infinite loop?)", .{});
    it.nest += 1;
    defer it.nest -= 1;
    const outer_clean = it.gc_clean_nest;
    const pin_mark = if (gc.precise) it.pins.items.len else 0;
    defer if (clean) {
        it.gc_clean_nest = outer_clean;
        it.pins.items.len = pin_mark;
    };
    if (clean) {
        try it.pin(@intFromPtr(code));
        it.gc_clean_nest = it.nest;
    }
    const mark = it.stackMark();
    defer it.stackRelease(mark);
    const stack = try it.stackAllocPub(code.max_stack);
    // The machine code of the JIT, when it has a function for the code.
    const jf: ?*jit.Fn = if (jit.built and it.jit != null) jit.prepare(it, code) else null;
    // The function of a module from `ztcl compile --wasm`.
    const af: ?u32 = if (aot.built) aot.prepare(it, code) else null;
    return runLoop(it, code, jf, af, stack.ptr, 0, 0, null);
}

/// `runLoop` after a short entry that did not end with a result.
pub noinline fn runRest(it: *Interp, code: *Code, f: *jit.Fn, stack: [*]Value, pc: u32, sp: u32, st: jit.Status) Error!Value {
    return runLoop(it, code, f, null, stack, pc, sp, st);
}

/// The loop of `run`: the machine code or `exec`, then the error trace,
/// `break`, and `continue` of the ranges. `first` is the status of an
/// entry that already ran.
inline fn runLoop(it: *Interp, code: *Code, jf: ?*jit.Fn, af: ?u32, stack: [*]Value, pc_in: u32, sp_in: u32, first: ?jit.Status) Error!Value {
    var pc = pc_in;
    var sp = sp_in;
    var status = first;
    while (true) {
        const out: Error!Value = blk: {
            if (jit.built) if (jf) |f| {
                const st = status orelse jit.enter(it, f, code, stack, &pc, &sp);
                status = null;
                switch (st) {
                    .done => break :blk stack[sp - 1],
                    .failed => break :blk jit.lastError(it),
                    .fallback => {},
                }
            };
            if (aot.built) if (af) |f| {
                switch (aot.enter(it, f, code, stack, &pc, &sp)) {
                    .done => break :blk stack[sp - 1],
                    .failed => break :blk aot.lastError(),
                    .fallback => {},
                }
            };
            break :blk if (code.named)
                exec(true, it, code, stack, &pc, &sp)
            else
                exec(false, it, code, stack, &pc, &sp);
        };
        return out catch |e| {
            // A cold block counts as the place of its guard.
            if (code.ins[pc].op == .eval_cmd and code.ins[pc].x == 1) pc = code.ins[pc].b;
            switch (e) {
                error.TclError, error.OutOfMemory => {
                    const err = it.limitError(e);
                    if (err != error.TclError) return err;
                    for (code.ranges) |r| {
                        if (pc < r.start or pc >= r.end) continue;
                        if (r.cmd) |cmd| {
                            _ = it.noteLine(cmd, err) catch {};
                        } else switch (r.ctx) {
                            .none => {},
                            .foreach => it.addContext("\n    (\"foreach\" body line {d})", .{it.proc_line}),
                            .lmap => it.addContext("\n    (\"lmap\" body line {d})", .{it.proc_line}),
                        }
                    }
                    return err;
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

// ---- The instructions ----
//
// Each function runs one instruction. It reads and writes the value
// stack at the offsets of `sp`, and it changes neither `sp` nor `pc`.
// `exec` applies the stack effect and the jump. The helpers of the JIT
// call the same functions, so each instruction has one implementation.
// A function for an instruction with two successors returns true for the
// jump. `ret` has no function: `exec` returns the top of the stack.

pub inline fn opPush(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, it, f };
    stack[sp] = code.lits[i.a];
}

pub inline fn opPushEmpty(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, it, f, code, i };
    stack[sp] = Value.empty;
}

pub inline fn opPop(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, it, f, code, stack, sp, i };
}

pub inline fn opLoad(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    if (!named) {
        const raw = f.vars.items[i.a].cell;
        if (raw.v == .val) {
            stack[sp] = raw.v.val;
            return;
        }
        return loadSlow(it, f, code, stack, sp, i);
    }
    const cell = readCell(named, it, f, code, i.a);
    if (cell != null and cell.?.v == .val) {
        stack[sp] = cell.?.v.val;
    } else {
        const r: interp.VarRef = .{ .name = code.names[i.a] };
        stack[sp] = try it.readRef(&r);
    }
}

/// `load` of a slot of a proc with no plain value in the cell: a link,
/// an owned list, or another form.
noinline fn loadSlow(it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    const raw = f.vars.items[i.a].cell;
    if (i.x == 1) {
        const t = raw.target();
        if (t.v == .owned) {
            stack[sp] = t.v.owned;
            return;
        }
    }
    const cell = raw.settle();
    if (cell.v == .val) {
        stack[sp] = cell.v.val;
    } else {
        const r: interp.VarRef = .{ .name = code.names[i.a] };
        stack[sp] = try it.readRef(&r);
    }
}

/// Writes `stack[sp - 1]` to slot `i.a`.
inline fn storeTop(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    const cell = try writeCell(named, it, f, code, i.a);
    if (cell.v == .val) {
        cell.v.val = stack[sp - 1];
    } else try storeOther(it, cell, code.names[i.a], &stack[sp - 1]);
}

/// A store to a cell with no value: a plain store gives the cell its
/// value, and each other form goes to `setVar`.
noinline fn storeOther(it: *Interp, cell: *Var, name: []const u8, v: *const Value) Error!void {
    if (!cell.plainStore()) return slowStore(it, name, v);
    cell.v = .{ .val = v.* };
}

pub inline fn opStore(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    return storeTop(named, it, f, code, stack, sp, i);
}

pub inline fn opStorePop(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    return storeTop(named, it, f, code, stack, sp, i);
}

pub inline fn opLlength(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code, i };
    const v = stack[sp - 1];
    const n = if (v == .list) v.list.len else (try it.list(v)).len;
    stack[sp - 1] = .{ .int = @intCast(n) };
}

pub inline fn opLindex(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code, i };
    const l = stack[sp - 2];
    const at = stack[sp - 1];
    if (at == .int) {
        const items = try it.list(l);
        stack[sp - 2] = if (at.int >= 0 and at.int < items.len) items[@intCast(at.int)] else Value.empty;
    } else {
        const argv = [_]Value{ .{ .str = "lindex" }, l, at };
        stack[sp - 2] = try cmds.cmdLindex(it, &argv, null);
    }
    // The item now has a second holder.
    value.dropStamp(stack[sp - 2]);
}

pub inline fn opStringLength(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code, i };
    // A copy first: the new union overlaps the old one.
    const v = stack[sp - 1];
    const n = cmds.charCountOf(it, try it.str(v));
    stack[sp - 1] = .{ .int = @intCast(n) };
}

pub inline fn opStringIndex(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code, i };
    const argv = [_]Value{ .{ .str = "string" }, .{ .str = "index" }, stack[sp - 2], stack[sp - 1] };
    stack[sp - 2] = try cmds.cmdString(it, &argv, null);
}

/// `dict get $d $key`: the result, the error text, and the error code
/// of `cmdDict`. The result is a copy of an item, so it holds no part of
/// the buffer of an owned dict.
pub inline fn opDictGet(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code, i };
    stack[sp - 2] = try dict.getOne(it, stack[sp - 2], stack[sp - 1]);
    // The item now has a second holder.
    value.dropStamp(stack[sp - 2]);
}

pub inline fn opDictExists(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code, i };
    stack[sp - 2] = try dict.existsOne(it, stack[sp - 2], stack[sp - 1]);
}

pub inline fn opDictSize(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code, i };
    stack[sp - 1] = try dict.sizeOf(it, stack[sp - 1]);
}

/// True when a core command changed: the guard then jumps to the
/// general path, and uses no step.
pub inline fn guardJumps(it: *Interp) bool {
    return it.epoch != it.safe_epoch and !recheck(it);
}

/// True: a core command changed, so the general path runs. `exec` runs
/// the two parts, `guardJumps` and `step`, as two calls, because the
/// joined form made the loop of the interpreter longer.
pub inline fn opGuard(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!bool {
    _ = .{ named, f, code, stack, sp, i };
    if (guardJumps(it)) return true;
    try step(it);
    return false;
}

pub inline fn opProbe(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, stack, sp };
    if (code.probed) |p| @import("probe.zig").fireLine(it, p, i.a) else @import("probe.zig").fireTopLine(it, i.a);
}

pub inline fn opStep(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code, stack, sp, i };
    try step(it);
}

pub inline fn opJump(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, it, f, code, stack, sp, i };
}

inline fn lassignOp(comptime named: bool, comptime drop: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    const table = code.tables[i.a];
    const items = try it.list(stack[sp - 1]);
    for (table, 0..) |slot, k| {
        const v = if (k < items.len) &items[k] else &Value.empty;
        const cell = try writeCell(named, it, f, code, slot);
        if (cell.v == .val) {
            cell.v.val = v.*;
        } else if (cell.plainStore()) {
            cell.v = .{ .val = v.* };
        } else {
            try slowStore(it, code.names[slot], v);
        }
    }
    if (!drop) stack[sp - 1] = try value.newList(it.alloc(), items[@min(items.len, table.len)..]);
}

pub inline fn opLassign(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    return lassignOp(named, false, it, f, code, stack, sp, i);
}

pub inline fn opLassignDrop(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    return lassignOp(named, true, it, f, code, stack, sp, i);
}

inline fn lsetOp(comptime drop: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    const cell = f.vars.items[i.a].cell.target();
    if (try more.lsetOwned(it, cell, stack[sp - 2], stack[sp - 1])) {
        if (!drop) {
            const out = cell.v.owned;
            cell.v = .{ .val = out };
            stack[sp - 2] = out;
        }
    } else {
        const site = code.sites[i.b];
        const argv = [4]Value{ site.words[0].kind.lit, site.words[1].kind.lit, stack[sp - 2], stack[sp - 1] };
        const r = try more.cmdLset(it, &argv, site);
        if (!drop) stack[sp - 2] = r;
    }
}

pub inline fn opVarExists(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, it, code };
    stack[sp] = .{ .int = @intFromBool(f.vars.items[i.a].cell.target().exists()) };
}

/// A write to an element of a plain array, or of an unset variable,
/// needs no full name. Other cells go through `Interp.setVar`.
pub inline fn opStoreElem(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    it.dropElem();
    const v = stack[sp - 1];
    const idx = try it.str(stack[sp - 2]);
    const cell = try writeCell(named, it, f, code, i.a);
    switch (cell.v) {
        .undef => {
            const m = try interp.newArray(it.alloc());
            cell.v = .{ .arr = m };
        },
        .arr => {},
        else => return storeElemSlow(it, code.names[i.a], idx, stack, sp),
    }
    const gop = try cell.v.arr.getOrPut(it.alloc(), idx);
    if (!gop.found_existing) gop.key_ptr.* = try it.alloc().dupe(u8, idx);
    gop.value_ptr.* = v;
    stack[sp - 2] = v;
}

/// `store_elem` on a cell with traces, a link to an element, or a
/// scalar value: the general write of the full name.
noinline fn storeElemSlow(it: *Interp, name: []const u8, idx: []const u8, stack: [*]Value, sp: u32) Error!void {
    @branchHint(.cold);
    const full = try std.fmt.allocPrint(it.alloc(), "{s}({s})", .{ name, idx });
    try it.setVar(full, stack[sp - 1]);
    stack[sp - 2] = stack[sp - 1];
}

pub inline fn opLset(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = named;
    return lsetOp(false, it, f, code, stack, sp, i);
}

pub inline fn opLsetDrop(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = named;
    return lsetOp(true, it, f, code, stack, sp, i);
}

/// True: the string form of the top equals literal `i.a`.
pub inline fn opStrEqJump(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!bool {
    _ = .{ named, f };
    const top = stack[sp - 1];
    const lit = code.lits[i.a].str;
    if (i.x == 0 and top == .str) return sameText(top.str, lit);
    var buf: [24]u8 = undefined;
    const s: []const u8 = if (top == .int) value.writeInt(&buf, top.int) else try it.str(top);
    // `switch -glob`: the match of the command, with its compute units.
    if (i.x != 0) return @import("cmds.zig").globSteps(it, lit, s, false);
    return sameText(s, lit);
}

/// True when the two strings have the same bytes. A pattern of `switch`
/// is short, so the bytes compare inline.
inline fn sameText(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// True: the top of the stack is false.
pub inline fn opJumpFalse(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!bool {
    _ = .{ named, f, code, i };
    const v = stack[sp - 1];
    const t = if (v == .int) v.int != 0 else try expr.truthy(it, v);
    return !t;
}

/// True: the top of the stack is true.
pub inline fn opJumpTrue(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!bool {
    _ = .{ named, f, code, i };
    const v = stack[sp - 1];
    return if (v == .int) v.int != 0 else try expr.truthy(it, v);
}

pub inline fn opToBool(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code, i };
    const v = stack[sp - 1];
    const t = if (v == .int) v.int != 0 else try expr.truthy(it, v);
    stack[sp - 1] = .{ .int = @intFromBool(t) };
}

pub inline fn opInvoke(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f };
    try step(it);
    const c = code.sites[i.a];
    const argv = stack[sp - i.b .. sp];
    const command = try it.resolve(c, argv);
    // A proc call keeps its values in the frame and the word
    // stack. A native command can hold values in locals.
    if (gc.precise) it.markDirect(command, argv.ptr);
    dropHint(it, command, argv, i);
    const called = it.call(command, argv, c);
    it.drop_argv = 0;
    if (gc.precise) it.clearDirect();
    stack[sp - i.b] = try called;
}

/// Tells `dict` and `lset` that the bytecode drops the result of the
/// call (`x` 1 on `invoke`). A command with traces gets no hint, because
/// a trace runs a script before the command.
inline fn dropHint(it: *Interp, command: *const interp.Command, argv: []const Value, i: *const Ins) void {
    if (i.x != 1 or command.traces != null or command.impl != .native) return;
    const f = command.impl.native;
    if (f == &dict.cmdDict or f == &more.cmdLset) it.drop_argv = @intFromPtr(argv.ptr);
}

/// `opInvoke` for a site whose cached command is valid: the JIT checks
/// `resolved`, `epoch`, and `ns` of the site inline, as `resolve` does.
/// The JIT never runs with the precise roots, and that build takes the
/// full path. A shared inline part made `exec` longer: 1.3 % more
/// instructions for bench/foreach.tcl.
pub fn opInvokeCached(it: *Interp, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    if (gc.precise) return opInvoke(false, it, it.frame, code, stack, sp, i);
    try step(it);
    const c = code.sites[i.a];
    const argv = stack[sp - i.b .. sp];
    // Machine code runs at a nest above 0, so a native command needs no
    // host wrapper of `Interp.call`.
    dropHint(it, c.resolved.?, argv, i);
    const called = switch (c.resolved.?.impl) {
        .proc => |p| it.callProcFast(p, argv),
        .native => |f| f(it, argv, c),
    };
    it.drop_argv = 0;
    stack[sp - i.b] = try called;
}

pub inline fn opEvalCmd(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f };
    if (gc.precise) it.gc_from_exec = gc.isClean(it);
    stack[sp] = try it.evalCmd(code.sites[i.a]);
}

pub inline fn opWord(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f };
    stack[sp] = try it.evalWord(code.words[i.a]);
}

pub inline fn opNode(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f };
    stack[sp] = try expr.eval(it, code.nodes[i.a]);
}

pub inline fn opMathFunc(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code };
    stack[sp - i.a] = try expr.applyFunc(it, @fromBackingInt(@intCast(i.x)), stack[sp - i.a .. sp]);
}

pub inline fn opConcat(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code };
    stack[sp - i.a] = try concatValues(it, stack[sp - i.a .. sp]);
}

pub inline fn opBinary(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code };
    const op: expr.BinOp = @fromBackingInt(@intCast(i.x));
    const x = &stack[sp - 2];
    const y = &stack[sp - 1];
    if (x.* == .int and y.* == .int) {
        const a = x.int;
        const b = y.int;
        x.* = if (intFast(op, a, b)) |r| .{ .int = r } else try expr.intOp(it, op, a, b);
    } else {
        x.* = try expr.binaryOp(it, op, x.*, y.*);
    }
}

pub inline fn opUnary(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code };
    stack[sp - 1] = try expr.unaryOp(it, @fromBackingInt(@intCast(i.x)), stack[sp - 1]);
}

pub inline fn opNumberForm(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code, i };
    const v = stack[sp - 1];
    if (v == .str) stack[sp - 1] = try expr.numberForm(it, v);
}

/// Adds `i.b` to slot `i.a` and gives the sum.
inline fn incrBy(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, i: *const Ins) Error!Value {
    const found = readCell(named, it, f, code, i.a);
    const by: i32 = @bitCast(i.b);
    if (found != null and found.?.v == .val and found.?.v.val == .int and addFits(found.?.v.val.int, by)) {
        const cell = found.?;
        const out: Value = .{ .int = cell.v.val.int + by };
        cell.v = .{ .val = out };
        return out;
    }
    return slowIncr(it, code.names[i.a], .{ .int = by });
}

pub inline fn opIncr(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    stack[sp] = try incrBy(named, it, f, code, i);
}

pub inline fn opIncrDrop(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ stack, sp };
    _ = try incrBy(named, it, f, code, i);
}

pub inline fn opIncrValue(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    const found = readCell(named, it, f, code, i.a);
    // A string step, such as an item of `split`, gets its integer here
    // with the parse of `cmdIncr`, so a plain cell needs no lookup by
    // name. `cmdIncr` reads the step first too, so an error is the same.
    const by = if (stack[sp - 1] == .str) try expr.incrArg(it, stack[sp - 1]) else stack[sp - 1];
    if (by == .int and found != null and found.?.v == .val and found.?.v.val == .int and addFits(found.?.v.val.int, by.int)) {
        const cell = found.?;
        const out: Value = .{ .int = cell.v.val.int + by.int };
        cell.v = .{ .val = out };
        stack[sp - 1] = out;
    } else {
        stack[sp - 1] = try slowIncr(it, code.names[i.a], by);
    }
}

pub inline fn opLappend(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    const found = readCell(named, it, f, code, i.a);
    if (found != null and found.?.v == .val and found.?.v.val == .list) {
        const cell = found.?;
        const out: Value = .{ .list = try cell.v.val.list.append(it.alloc(), stack[sp - 1]) };
        cell.v = .{ .val = out };
        stack[sp - 1] = out;
    } else {
        stack[sp - 1] = try slowLappend(it, code.names[i.a], stack[sp - 1]);
    }
}

/// The stack has the list of `lmap`, the list and the index of the loop,
/// and the result of the pass. The list starts as the empty string, and
/// only this instruction sees it, so it grows in place.
pub inline fn opLmapAdd(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code, i };
    const acc = &stack[sp - 4];
    if (acc.* != .list) {
        var l = try value.allocList(it.alloc(), 8);
        l.obj.used = 0;
        l.len = 0;
        acc.* = .{ .list = l };
    }
    acc.* = .{ .list = try acc.list.append(it.alloc(), stack[sp - 1]) };
}

pub inline fn opBinVv(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    const op: expr.BinOp = @fromBackingInt(@intCast(i.x));
    const x = intSlot(named, it, f, code, i.a);
    const y = intSlot(named, it, f, code, i.b);
    if (x != null and y != null) {
        stack[sp] = if (intFast(op, x.?, y.?)) |r| .{ .int = r } else try expr.intOp(it, op, x.?, y.?);
    } else {
        shimmer(named, it, f, code, i.a);
        shimmer(named, it, f, code, i.b);
        const vx = try readSlot(named, it, f, code, i.a);
        const vy = try readSlot(named, it, f, code, i.b);
        stack[sp] = try slowBinary(it, op, vx, vy);
    }
}

pub inline fn opBinVi(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    const op: expr.BinOp = @fromBackingInt(@intCast(i.x));
    const y = code.lits[i.b].int;
    if (intSlot(named, it, f, code, i.a)) |x| {
        stack[sp] = if (intFast(op, x, y)) |r| .{ .int = r } else try expr.intOp(it, op, x, y);
    } else {
        shimmer(named, it, f, code, i.a);
        const vx = try readSlot(named, it, f, code, i.a);
        stack[sp] = try slowBinary(it, op, vx, .{ .int = y });
    }
}

/// True: compare `i.x` of slot `i.a` and slot `i.b` is false.
pub inline fn opJfVv(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!bool {
    _ = .{ stack, sp };
    const op: expr.BinOp = @fromBackingInt(@intCast(i.x));
    const x = intSlot(named, it, f, code, i.a);
    const y = intSlot(named, it, f, code, i.b);
    if (x != null and y != null) return !intCompare(op, x.?, y.?);
    shimmer(named, it, f, code, i.a);
    shimmer(named, it, f, code, i.b);
    const vx = try readSlot(named, it, f, code, i.a);
    const vy = try readSlot(named, it, f, code, i.b);
    return !try expr.truthy(it, try slowBinary(it, op, vx, vy));
}

/// True: compare `i.x` of slot `i.a` and literal `i.b` is false.
pub inline fn opJfVi(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!bool {
    _ = .{ stack, sp };
    const op: expr.BinOp = @fromBackingInt(@intCast(i.x));
    const y = code.lits[i.b].int;
    if (intSlot(named, it, f, code, i.a)) |x| return !intCompare(op, x, y);
    shimmer(named, it, f, code, i.a);
    const vx = try readSlot(named, it, f, code, i.a);
    return !try expr.truthy(it, try slowBinary(it, op, vx, .{ .int = y }));
}

pub inline fn opDictUpdate(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f };
    const nv: u32 = 1 + @as(u32, i.x);
    stack[sp - nv] = try dictSlow(it, code.sites[i.b], stack[sp - nv .. sp]);
}

pub inline fn opDictUpdateDrop(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = named;
    const nv: u32 = 1 + @as(u32, i.x);
    const cell = f.vars.items[i.a].cell.target();
    const new: ?Value = if (i.x == 1) stack[sp - 1] else null;
    if (cell.v != .owned or !dict.isMarked(cell.v.owned) or !try dict.updateOwned(it, cell.v.owned, stack[sp - nv], 1, new)) {
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
            // The general write can give an inner buffer to another
            // place, so the stamps of the inner buffers end.
            v.list.obj.own_stamp = value.newOwnStamp();
            now.v = .{ .owned = v };
        }
    }
}

pub inline fn opAppend(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    stack[sp - i.b] = try appendValues(named, it, f, code, i.a, stack[sp - i.b .. sp]);
}

pub inline fn opForeachInit(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!void {
    _ = .{ named, f, code };
    if (i.b != 0) {
        // `dict for`: the pairs of the dict, each key one time.
        stack[sp - 1] = try @import("dict.zig").forPairs(it, stack[sp - 1]);
    } else {
        const items = try it.list(stack[sp - 1]);
        if (stack[sp - 1] != .list) stack[sp - 1] = try value.newList(it.alloc(), items);
    }
    stack[sp] = .{ .int = 0 };
}

/// The error of a `foreach` state that is not a list and an index. The
/// verifier makes this case unreachable.
noinline fn badLoopState(it: *Interp) Error {
    @branchHint(.cold);
    return it.fail("internal error: bad loop state", .{});
}

/// True: the loop is done. The function checks the kinds of the list
/// and the index first.
pub inline fn opForeachNext(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!bool {
    if (stack[sp - 2] != .list or stack[sp - 1] != .int) return badLoopState(it);
    return foreachAdvance(named, it, f, code, stack, sp, i);
}

/// `opForeachNext` with no check of the kinds. `exec` calls it
/// directly: the check costs 5 % of the instructions of
/// bench/foreach.tcl, and the compiler of this file emits
/// `foreach_next` only on the two places of `foreach_init`.
pub inline fn foreachAdvance(comptime named: bool, it: *Interp, f: *Frame, code: *const Code, stack: [*]Value, sp: u32, i: *const Ins) Error!bool {
    const table = code.tables[i.a];
    const items = stack[sp - 2].list.items();
    const at: usize = @intCast(stack[sp - 1].int);
    if (at >= items.len) return true;
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
            return false;
        }
        cell.v = .{ .val = src.* };
    }
    stack[sp - 1] = .{ .int = @intCast(at + table.len) };
    return false;
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
                try opPush(named, it, f, code, stack, sp, i);
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .push_empty => {
                try opPushEmpty(named, it, f, code, stack, sp, i);
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
                try opLoad(named, it, f, code, stack, sp, i);
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .store => {
                try opStore(named, it, f, code, stack, sp, i);
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .access => switch (@as(Access, @fromBackingInt(@intCast(i.x)))) {
                .llength => try opLlength(named, it, f, code, stack, sp, i),
                .lindex => {
                    try opLindex(named, it, f, code, stack, sp, i);
                    sp -= 1;
                },
                .string_length => try opStringLength(named, it, f, code, stack, sp, i),
                .string_index => {
                    try opStringIndex(named, it, f, code, stack, sp, i);
                    sp -= 1;
                },
                .dict_get => {
                    try opDictGet(named, it, f, code, stack, sp, i);
                    sp -= 1;
                },
                .dict_exists => {
                    try opDictExists(named, it, f, code, stack, sp, i);
                    sp -= 1;
                },
                .dict_size => try opDictSize(named, it, f, code, stack, sp, i),
            },
            .guard => {
                // The two parts of `opGuard`.
                if (guardJumps(it)) {
                    pc = i.a;
                    continue;
                }
                try opStep(named, it, f, code, stack, sp, i);
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .step => try opStep(named, it, f, code, stack, sp, i),
            .probe => if (code.probed) |p| @import("probe.zig").fireLine(it, p, i.a) else @import("probe.zig").fireTopLine(it, i.a),
            .jump => {
                pc = i.a;
                continue;
            },
            .lassign => {
                try opLassign(named, it, f, code, stack, sp, i);
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .lassign_drop => {
                try opLassignDrop(named, it, f, code, stack, sp, i);
                sp -= 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .lset => {
                try opLset(named, it, f, code, stack, sp, i);
                sp -= 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .var_exists => {
                try opVarExists(named, it, f, code, stack, sp, i);
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .store_elem => {
                try opStoreElem(named, it, f, code, stack, sp, i);
                sp -= 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .lset_drop => {
                try opLsetDrop(named, it, f, code, stack, sp, i);
                sp -= 2;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .str_eq_jump => {
                if (try opStrEqJump(named, it, f, code, stack, sp, i)) {
                    pc = i.b;
                } else pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .jump_false => {
                const jump = try opJumpFalse(named, it, f, code, stack, sp, i);
                sp -= 1;
                if (jump) {
                    pc = i.a;
                    continue;
                }
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .jump_true => {
                const jump = try opJumpTrue(named, it, f, code, stack, sp, i);
                sp -= 1;
                if (jump) {
                    pc = i.a;
                    continue;
                }
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .to_bool => {
                try opToBool(named, it, f, code, stack, sp, i);
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .invoke => {
                try opInvoke(named, it, f, code, stack, sp, i);
                sp = sp - i.b + 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .eval_cmd => {
                try opEvalCmd(named, it, f, code, stack, sp, i);
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .word => {
                try opWord(named, it, f, code, stack, sp, i);
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .node => {
                try opNode(named, it, f, code, stack, sp, i);
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .mathfunc => {
                try opMathFunc(named, it, f, code, stack, sp, i);
                sp = sp - i.a + 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .concat => {
                try opConcat(named, it, f, code, stack, sp, i);
                sp = sp - i.a + 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .binary => {
                try opBinary(named, it, f, code, stack, sp, i);
                sp -= 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .unary => try opUnary(named, it, f, code, stack, sp, i),
            .number_form => {
                try opNumberForm(named, it, f, code, stack, sp, i);
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .incr => {
                try opIncr(named, it, f, code, stack, sp, i);
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .incr_value => {
                try opIncrValue(named, it, f, code, stack, sp, i);
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .lappend => {
                try opLappend(named, it, f, code, stack, sp, i);
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .lmap_add => {
                try opLmapAdd(named, it, f, code, stack, sp, i);
                sp -= 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .store_pop => {
                try opStorePop(named, it, f, code, stack, sp, i);
                sp -= 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .incr_drop => {
                try opIncrDrop(named, it, f, code, stack, sp, i);
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .bin_vv => {
                try opBinVv(named, it, f, code, stack, sp, i);
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .bin_vi => {
                try opBinVi(named, it, f, code, stack, sp, i);
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .jf_vv => {
                if (try opJfVv(named, it, f, code, stack, sp, i)) {
                    pc = i.c;
                    continue;
                }
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .jf_vi => {
                if (try opJfVi(named, it, f, code, stack, sp, i)) {
                    pc = i.c;
                    continue;
                }
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .dict_update => {
                try opDictUpdate(named, it, f, code, stack, sp, i);
                sp = sp - (1 + @as(u32, i.x)) + 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .dict_update_drop => {
                try opDictUpdateDrop(named, it, f, code, stack, sp, i);
                sp -= 1 + @as(u32, i.x);
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .append => {
                try opAppend(named, it, f, code, stack, sp, i);
                sp = sp - i.b + 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .ret => return stack[sp - 1],
            .foreach_init => {
                try opForeachInit(named, it, f, code, stack, sp, i);
                sp += 1;
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
            .foreach_next => {
                // `opForeachNext` with no check of the kinds.
                if (try foreachAdvance(named, it, f, code, stack, sp, i)) {
                    pc = i.b;
                    continue;
                }
                pc += 1;
                i = &ins[pc];
                continue :sw i.op;
            },
        }
        pc += 1;
    }
}

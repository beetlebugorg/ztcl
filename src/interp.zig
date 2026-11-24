//! The Tcl parser and interpreter.
//!
//! `Parser` reads a script by the 12 rules of the Tcl language (Tcl.n)
//! and makes a `Script`: a list of commands, each a list of words, each
//! a literal, a substitution, or a sequence of both. A script is parsed
//! once. Each word of a command has a cache slot for the compiled script
//! or the compiled expression of its literal text, so a loop body or a
//! braced `expr` is not parsed again.
//!
//! `Interp` runs a script. All memory comes from one arena on the given
//! allocator, and `deinit` frees it in one step. A step limit stops a
//! script that runs too long. Commands that reach the outside world do
//! not exist; `puts` writes to a callback.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const expr = @import("expr.zig");
const cmds = @import("cmds.zig");
const vm = @import("vm.zig");
const jit_mod = @import("jit.zig");
const thread_mod = @import("thread.zig");
const trace = @import("trace.zig");
const ns_mod = @import("ns.zig");
const coro = @import("coro.zig");
const Heap = @import("heap.zig").Heap;
const gc = @import("gc.zig");
pub const Value = value.Value;

/// The return codes of Tcl other than "ok". The result of the
/// interpreter holds the error message or the returned value.
pub const Error = error{ OutOfMemory, TclError, TclReturn, TclBreak, TclContinue, TclCustom };

// ---- The compiled form ----

pub const VarRef = struct {
    name: []const u8,
    /// The index of an array element, or null for a scalar.
    index: ?[]const Part = null,
    /// The slot of the name in the frame at the last read. A guess: the
    /// reader checks the name of the slot before it uses the slot.
    hint: u32 = 0,
};

pub const Part = union(enum) {
    lit: []const u8,
    variable: VarRef,
    script: *Script,
};

pub const Word = struct {
    expand: bool = false,
    /// The line of the script where the word starts.
    line: u32 = 0,
    kind: union(enum) {
        lit: Value,
        single: Part,
        multi: []const Part,
    },
};

/// The compiled forms of the literal text of one word.
pub const Cache = struct {
    script: ?*Script = null,
    expr: ?*expr.Node = null,
};

pub const Cmd = struct {
    words: []Word,
    cache: []Cache,
    line: u32,
    has_expand: bool,
    /// The source text of the command, for the error trace.
    text: []const u8 = "",
    resolved: ?*Command = null,
    epoch: u32 = 0,
    /// The namespace of the lookup: the address of its name.
    ns: [*]const u8 = "",
    /// The direct form of the command, valid for the same epoch.
    fast: Fast = .none,
    /// The slot of the variable of a direct `set` or `incr`.
    hint: u32 = 0,
    /// The step of a direct `incr`.
    by: i64 = 1,
};

/// The commands that run with no word stack. `evalCmd` selects the
/// form when it looks the name up, and reads the literal words directly.
pub const Fast = enum { none, set, incr, expr, if_then, if_else };

pub const Script = struct {
    cmds: []Cmd,
    /// The bytecode of a script that ran more than one time.
    code: ?*vm.Code = null,
    runs: u8 = 0,
};

// ---- The parser ----

pub const Parser = struct {
    a: Allocator,
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    /// What is wrong, after error.TclError.
    message: []const u8 = "",
    /// The nesting of command substitutions. A limit keeps the parser
    /// off the end of the native stack.
    depth: u32 = 0,
    /// The commands before a syntax error in the outermost script.
    partial: []Cmd = &.{},

    pub const max_depth = 200;

    const PError = error{ OutOfMemory, TclError };

    fn fail(p: *Parser, msg: []const u8) PError {
        p.message = msg;
        return error.TclError;
    }

    fn isWordSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r' or c == 11 or c == 12;
    }

    fn atBsNewline(p: *Parser) bool {
        return p.pos + 1 < p.src.len and p.src[p.pos] == '\\' and p.src[p.pos + 1] == '\n';
    }

    fn skipSpace(p: *Parser) void {
        while (p.pos < p.src.len) {
            if (isWordSpace(p.src[p.pos])) {
                p.pos += 1;
            } else if (p.atBsNewline()) {
                p.pos += 2;
                p.line += 1;
            } else break;
        }
    }

    /// Parses commands to the end of the text, or to the `]` that closes
    /// a command substitution when `bracket` is true.
    pub fn parseScript(p: *Parser, bracket: bool) PError!*Script {
        if (p.depth >= max_depth) return p.fail("too many nested command substitutions");
        const outermost = p.depth == 0;
        p.depth += 1;
        defer p.depth -= 1;
        var list: std.ArrayList(Cmd) = .empty;
        errdefer if (outermost) {
            p.partial = list.items;
        };
        while (true) {
            // Rule 1: commands end at a newline or a semicolon.
            while (p.pos < p.src.len) {
                const c = p.src[p.pos];
                if (c == '\n') {
                    p.line += 1;
                    p.pos += 1;
                } else if (c == ';' or isWordSpace(c)) {
                    p.pos += 1;
                } else if (p.atBsNewline()) {
                    p.pos += 2;
                    p.line += 1;
                } else break;
            }
            if (p.pos >= p.src.len) {
                if (bracket) return p.fail("missing close-bracket");
                break;
            }
            if (bracket and p.src[p.pos] == ']') {
                p.pos += 1;
                break;
            }
            // Rule 10: a comment starts where a command starts.
            if (p.src[p.pos] == '#') {
                while (p.pos < p.src.len and p.src[p.pos] != '\n') {
                    if (p.src[p.pos] == '\\' and p.pos + 1 < p.src.len) {
                        if (p.src[p.pos + 1] == '\n') p.line += 1;
                        p.pos += 1;
                    }
                    p.pos += 1;
                }
                continue;
            }
            const line = p.line;
            var words: std.ArrayList(Word) = .empty;
            var has_expand = false;
            const text_start = p.pos;
            var text_end = p.pos;
            while (true) {
                p.skipSpace();
                if (p.pos >= p.src.len) break;
                const c = p.src[p.pos];
                if (c == '\n' or c == ';') {
                    p.pos += 1;
                    if (c == '\n') p.line += 1;
                    break;
                }
                if (bracket and c == ']') break;
                const word_line = p.line;
                var w = try p.parseWord(bracket);
                w.line = word_line;
                text_end = p.pos;
                has_expand = has_expand or w.expand;
                try words.append(p.a, w);
            }
            if (words.items.len == 0) continue;
            const cache = try p.a.alloc(Cache, words.items.len);
            @memset(cache, .{});
            try list.append(p.a, .{ .words = words.items, .cache = cache, .line = line, .has_expand = has_expand, .text = p.src[text_start..text_end] });
        }
        const s = try p.a.create(Script);
        s.* = .{ .cmds = list.items };
        return s;
    }

    fn wordEnd(p: *Parser, bracket: bool) bool {
        if (p.pos >= p.src.len) return true;
        const c = p.src[p.pos];
        return isWordSpace(c) or c == '\n' or c == ';' or (bracket and c == ']') or p.atBsNewline();
    }

    fn parseWord(p: *Parser, bracket: bool) PError!Word {
        var expand = false;
        // Rule 5: {*} in front of a word expands it as a list.
        if (std.mem.startsWith(u8, p.src[p.pos..], "{*}") and p.pos + 3 < p.src.len) {
            const c = p.src[p.pos + 3];
            if (!isWordSpace(c) and c != '\n' and c != ';') {
                expand = true;
                p.pos += 3;
            }
        }
        const c = p.src[p.pos];
        if (c == '{') {
            // Rule 6: braces quote with no substitution.
            const text = try p.parseBraced();
            if (!p.wordEnd(bracket)) return p.fail("extra characters after close-brace");
            return .{ .expand = expand, .kind = .{ .lit = literal(text) } };
        }
        var parts: Parts = .{ .a = p.a };
        if (c == '"') {
            // Rule 4: double quotes group, with substitution.
            p.pos += 1;
            try p.parseParts(&parts, .quote);
            if (p.pos >= p.src.len) return p.fail("missing \"");
            p.pos += 1;
            if (!p.wordEnd(bracket)) return p.fail("extra characters after close-quote");
        } else {
            try p.parseParts(&parts, if (bracket) .bare_bracket else .bare);
        }
        const list = try parts.finish();
        if (list.len == 0) return .{ .expand = expand, .kind = .{ .lit = Value.empty } };
        if (list.len == 1) {
            if (list[0] == .lit) return .{ .expand = expand, .kind = .{ .lit = literal(list[0].lit) } };
            return .{ .expand = expand, .kind = .{ .single = list[0] } };
        }
        return .{ .expand = expand, .kind = .{ .multi = list } };
    }

    /// A literal word. A canonical decimal integer becomes an int value;
    /// its string form is the same text.
    fn literal(text: []const u8) Value {
        if (text.len == 0 or text.len > 18) return .{ .str = text };
        var digits = text;
        if (digits[0] == '-') digits = digits[1..];
        if (digits.len == 0 or (digits[0] == '0' and text.len > 1)) return .{ .str = text };
        for (digits) |d| if (d < '0' or d > '9') return .{ .str = text };
        return .{ .int = std.fmt.parseInt(i64, text, 10) catch return .{ .str = text } };
    }

    /// Reads a braced word. `pos` is at the open brace.
    pub fn parseBraced(p: *Parser) PError![]const u8 {
        const start = p.pos + 1;
        var depth: usize = 1;
        var has_cont = false;
        p.pos += 1;
        while (p.pos < p.src.len) : (p.pos += 1) {
            const c = p.src[p.pos];
            if (c == '\\') {
                if (p.pos + 1 < p.src.len and p.src[p.pos + 1] == '\n') {
                    has_cont = true;
                    p.line += 1;
                }
                p.pos += 1;
            } else if (c == '\n') {
                p.line += 1;
            } else if (c == '{') {
                depth += 1;
            } else if (c == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (p.pos >= p.src.len) {
            p.pos = p.src.len;
            return p.fail("missing close-brace");
        }
        const text = p.src[start..p.pos];
        p.pos += 1;
        if (!has_cont) return text;
        // A backslash-newline in braces becomes one space.
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == '\n') {
                i += 2;
                while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
                try out.append(p.a, ' ');
            } else if (text[i] == '\\' and i + 1 < text.len) {
                try out.appendSlice(p.a, text[i .. i + 2]);
                i += 2;
            } else {
                try out.append(p.a, text[i]);
                i += 1;
            }
        }
        return out.items;
    }

    pub const Mode = enum { bare, bare_bracket, quote, index, all };

    /// Reads text with substitutions (rules 7, 8, and 9) until the end
    /// for the mode. `all` reads to the end of the text (`subst`).
    pub fn parseParts(p: *Parser, parts: *Parts, mode: Mode) PError!void {
        while (p.pos < p.src.len) {
            const c = p.src[p.pos];
            switch (mode) {
                .bare => if (isWordSpace(c) or c == '\n' or c == ';') return,
                .bare_bracket => if (isWordSpace(c) or c == '\n' or c == ';' or c == ']') return,
                .quote => if (c == '"') return,
                .index => if (c == ')') return,
                .all => {},
            }
            if (c == '\\') {
                if (mode != .quote and mode != .all and mode != .index and p.atBsNewline()) return;
                if (p.pos + 1 < p.src.len and p.src[p.pos + 1] == '\n') p.line += 1;
                p.pos = try value.backslash(p.a, p.src, p.pos, &parts.buf);
            } else if (c == '$') {
                if (try p.parseVar()) |v| {
                    try parts.add(.{ .variable = v });
                } else {
                    try parts.buf.append(p.a, '$');
                    p.pos += 1;
                }
            } else if (c == '[') {
                p.pos += 1;
                const s = try p.parseScript(true);
                try parts.add(.{ .script = s });
            } else {
                if (c == '\n') p.line += 1;
                try parts.buf.append(p.a, c);
                p.pos += 1;
            }
        }
    }

    /// Reads a variable substitution. `pos` is at the `$`. Returns null
    /// when no name follows, so the `$` is a plain character.
    pub fn parseVar(p: *Parser) PError!?VarRef {
        var i = p.pos + 1;
        if (i < p.src.len and p.src[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, p.src, i, '}') orelse
                return p.fail("missing close-brace for variable name");
            const name = p.src[i + 1 .. end];
            p.pos = end + 1;
            // ${a(i)} names an element with a literal index.
            if (name.len > 0 and name[name.len - 1] == ')') {
                if (std.mem.indexOfScalar(u8, name, '(')) |open| {
                    const idx = try p.a.alloc(Part, 1);
                    idx[0] = .{ .lit = name[open + 1 .. name.len - 1] };
                    return .{ .name = name[0..open], .index = idx };
                }
            }
            return .{ .name = name };
        }
        const start = i;
        while (i < p.src.len) {
            const c = p.src[i];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                i += 1;
            } else if (c == ':' and i + 1 < p.src.len and p.src[i + 1] == ':') {
                while (i < p.src.len and p.src[i] == ':') i += 1;
            } else break;
        }
        if (i < p.src.len and p.src[i] == '(') {
            p.pos = i + 1;
            var parts: Parts = .{ .a = p.a };
            try p.parseParts(&parts, .index);
            if (p.pos >= p.src.len) return p.fail("missing )");
            p.pos += 1;
            return .{ .name = p.src[start..i], .index = try parts.finish() };
        }
        if (i == start) return null;
        p.pos = i;
        return .{ .name = p.src[start..i] };
    }
};

/// Collects the parts of a word. Literal bytes join into one part.
pub const Parts = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,
    list: std.ArrayList(Part) = .empty,

    fn flush(s: *Parts) !void {
        if (s.buf.items.len > 0) {
            try s.list.append(s.a, .{ .lit = s.buf.items });
            s.buf = .empty;
        }
    }

    pub fn add(s: *Parts, part: Part) !void {
        try s.flush();
        try s.list.append(s.a, part);
    }

    pub fn finish(s: *Parts) ![]const Part {
        try s.flush();
        return s.list.items;
    }
};

// ---- Variables and frames ----

pub const ArrayMap = std.StringArrayHashMapUnmanaged(Value);

pub const Var = struct {
    v: union(enum) {
        undef,
        val: Value,
        /// A dict that only this cell can see. The bytecode updates it
        /// in place. Each general read makes it a plain value first.
        owned: Value,
        // The forms above take a plain store (`plainStore`).
        arr: *ArrayMap,
        link: *Var,
        /// A variable with traces. Only the general path reads it.
        traced: *trace.Traced,
        /// A link to one element of an array (`upvar a(i) x`).
        elem: *ElemLink,
    } = .undef,
    next_free: ?*Var = null,

    /// True when a store can overwrite the cell. One compare of the tag
    /// covers the three plain forms.
    pub inline fn plainStore(cell: *const Var) bool {
        const Tag = std.meta.Tag(@TypeOf(cell.v));
        const tag: Tag = cell.v;
        return @intFromEnum(tag) <= @intFromEnum(Tag.owned);
    }

    /// The cell at the end of the links, with a plain value.
    pub inline fn settle(cell: *Var) *Var {
        if (cell.v == .val) return cell;
        return settleSlow(cell);
    }

    fn settleSlow(cell: *Var) *Var {
        var c = cell;
        while (c.v == .link) c = c.v.link;
        if (c.v == .owned) {
            // A copy first: the new union overlaps the old one.
            const v = c.v.owned;
            c.v = .{ .val = v };
        }
        return c;
    }

    /// The cell at the end of the links. An owned dict stays owned.
    pub inline fn target(cell: *Var) *Var {
        var c = cell;
        while (c.v == .link) c = c.v.link;
        return c;
    }
};

pub const ElemLink = struct {
    /// The cell of the array and its name.
    array: *Var,
    name: []const u8,
    index: []const u8,
};

pub const VarEntry = struct { name: []const u8, cell: *Var };

pub const Frame = struct {
    vars: std.ArrayList(VarEntry) = .empty,
    /// A hash index of `vars` for a frame with many variables: the
    /// position of the first entry of each name. It covers the first
    /// `indexed` entries. A frame with few variables has no index.
    index: std.StringHashMapUnmanaged(u32) = .empty,
    indexed: u32 = 0,
    /// The words of the call, for `info level`.
    argv: []const Value = &.{},
    parent: ?*Frame = null,
    level: u32 = 0,
    /// The namespace of a `namespace eval` frame, or null. A name that
    /// is not in such a frame is a variable of the namespace.
    ns: ?[]const u8 = null,
    /// The namespace where the code of the frame runs.
    space: []const u8 = "",

    /// The frames with at least this many variables use the index.
    const index_from = 32;

    /// The position of the first entry of a name, or null. A frame with
    /// many variables first adds its new entries to the index, so the
    /// cost of a search does not grow with the count of variables. If
    /// the index cannot grow, the search reads each entry.
    pub inline fn find(f: *Frame, a: Allocator, name: []const u8) ?usize {
        if (f.vars.items.len >= index_from) return f.findIndexed(a, name);
        return linear(f.vars.items, name);
    }

    fn linear(items: []const VarEntry, name: []const u8) ?usize {
        for (items, 0..) |e, i| if (Interp.sameName(e.name, name)) return i;
        return null;
    }

    noinline fn findIndexed(f: *Frame, a: Allocator, name: []const u8) ?usize {
        const items = f.vars.items;
        while (f.indexed < items.len) : (f.indexed += 1) {
            const gop = f.index.getOrPut(a, items[f.indexed].name) catch return linear(items, name);
            if (!gop.found_existing) gop.value_ptr.* = f.indexed;
        }
        return if (f.index.get(name)) |i| i else null;
    }

    /// Removes each entry, and keeps the capacity.
    pub inline fn clear(f: *Frame) void {
        f.vars.clearRetainingCapacity();
        if (f.indexed != 0) f.dropIndex();
    }

    noinline fn dropIndex(f: *Frame) void {
        @branchHint(.cold);
        f.index.clearRetainingCapacity();
        f.indexed = 0;
    }
};

// ---- Commands ----

pub const NativeFn = *const fn (it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value;

pub const Param = struct { name: []const u8, default: ?Value = null };

pub const Proc = struct {
    params: []const Param,
    has_args: bool,
    body: Value,
    /// The namespace where the proc runs.
    ns: []const u8 = "",
    script: ?*Script = null,
    /// The bytecode of the body. The first call makes it.
    code: ?*vm.Code = null,
    params_text: Value,
};

pub const Command = struct {
    name: []const u8,
    impl: union(enum) { native: NativeFn, proc: *Proc },
    /// Data of the embedder for a native command.
    ctx: ?*anyopaque = null,
    /// The command and execution traces.
    traces: ?*trace.CmdTraces = null,
    /// A command of `tsv.zig` such as `tsv::set`. While its key is in
    /// the namespace `tsv`, the count of shadows of `Commands` does not
    /// count it.
    tsv_op: bool = false,
};

/// The command table: a hash map from the full name to the command. It
/// also counts the keys in a namespace whose last part is an inlined
/// name of the bytecode. With the count, the guard of the bytecode
/// checks the table with a fixed number of lookups (`vm.recheck`).
/// The first check counts the keys one time. Each later change of the
/// table then updates the count, so the start of an interpreter does
/// not test each new key.
pub const Commands = struct {
    pub const Map = std.StringHashMapUnmanaged(*Command);
    map: Map = .empty,
    /// The keys with "::" whose last part is an inlined name. It is
    /// valid only when `counted` is true.
    shadows: u32 = 0,
    counted: bool = false,

    pub const empty: Commands = .{};

    /// True for a key with "::" whose last part is an inlined name. The
    /// test reads only the end of the key: for each length of an
    /// inlined name that ends with the last byte, it checks for "::"
    /// before that many bytes.
    fn shadow(key: []const u8) bool {
        var lens = vm.inline_lens[if (key.len > 0) key[key.len - 1] else 0];
        while (lens != 0) : (lens &= lens - 1) {
            const k = @ctz(lens);
            if (key.len < k + 2) break;
            const at = key.len - k;
            if (key[at - 1] == ':' and key[at - 2] == ':') return vm.isInlineName(key[at..]);
        }
        return false;
    }

    /// `shadow` for a key and its command. A command of `tsv.zig` such
    /// as `tsv::set` is no shadow while its key is in the namespace
    /// `tsv`, so the inline forms stay on. Compiled code in the
    /// namespace `tsv` runs the core command.
    fn shadowOf(key: []const u8, c: *const Command) bool {
        if (!shadow(key)) return false;
        return !(c.tsv_op and std.mem.startsWith(u8, key, "tsv::"));
    }

    /// The count of shadows. The first call reads each key.
    pub fn shadowCount(t: *Commands) u32 {
        if (!t.counted) {
            var n: u32 = 0;
            var iter = t.map.iterator();
            while (iter.next()) |e| {
                if (shadowOf(e.key_ptr.*, e.value_ptr.*)) n += 1;
            }
            t.shadows = n;
            t.counted = true;
        }
        return t.shadows;
    }

    pub fn count(t: *const Commands) u32 {
        return t.map.count();
    }

    pub fn get(t: *const Commands, key: []const u8) ?*Command {
        return t.map.get(key);
    }

    pub fn getKey(t: *const Commands, key: []const u8) ?[]const u8 {
        return t.map.getKey(key);
    }

    pub fn contains(t: *const Commands, key: []const u8) bool {
        return t.map.contains(key);
    }

    pub fn iterator(t: *const Commands) Map.Iterator {
        return t.map.iterator();
    }

    pub fn keyIterator(t: *const Commands) Map.KeyIterator {
        return t.map.keyIterator();
    }

    pub fn put(t: *Commands, a: Allocator, key: []const u8, c: *Command) Allocator.Error!void {
        const gop = try t.map.getOrPut(a, key);
        if (t.counted) {
            const was = gop.found_existing and shadowOf(key, gop.value_ptr.*);
            const now = shadowOf(key, c);
            if (now and !was) t.shadows += 1;
            if (was and !now) t.shadows -= 1;
        }
        gop.value_ptr.* = c;
    }

    pub fn remove(t: *Commands, key: []const u8) bool {
        return t.fetchRemove(key) != null;
    }

    pub fn fetchRemove(t: *Commands, key: []const u8) ?Map.KV {
        const kv = t.map.fetchRemove(key) orelse return null;
        if (t.counted and shadowOf(kv.key, kv.value)) t.shadows -= 1;
        return kv;
    }

    pub fn ensureTotalCapacity(t: *Commands, a: Allocator, n: u32) Allocator.Error!void {
        return t.map.ensureTotalCapacity(a, n);
    }

    pub fn getOrPutAssumeCapacity(t: *Commands, key: []const u8) Map.GetOrPutResult {
        const gop = t.map.getOrPutAssumeCapacity(key);
        if (t.counted and !gop.found_existing and shadow(key)) t.shadows += 1;
        return gop;
    }
};

/// Where `puts` writes.
pub const Output = struct {
    ctx: ?*anyopaque = null,
    write: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,
};

/// Counts the bytes that the arena holds from the allocator of the
/// embedder. The memory limit of the interpreter reads the count.
pub const Counting = struct {
    child: Allocator,
    used: usize = 0,
    /// The highest value that `used` had.
    mem_peak: usize = 0,
    /// The value that a limit check reads: `used`, or the largest number
    /// when a collection is due. One compare serves both checks.
    trip: usize = 0,
    /// The value of `used` at which a collection is due.
    gc_at: usize = @import("heap.zig").min_threshold,
    /// The counters of the child interpreters. A child shares the heap
    /// of its root, so its `used` follows the count of the root. This
    /// keeps the check of the memory limit one load in each interpreter.
    followers: ?*Counting = null,
    next_follower: ?*Counting = null,
    /// True after the counter refused a request above the hard cap. The
    /// next limit check then stops the script, and `catch` cannot catch
    /// the error. `evalTop` clears the flag.
    refused: bool = false,
    /// True while a top-level eval runs that started with live data
    /// above the memory limit. Only the hard cap then applies, so the
    /// script can free the data. A collection that brings `used` below
    /// the limit clears the flag.
    over_start: bool = false,

    fn sync(c: *Counting) void {
        c.mem_peak = @max(c.mem_peak, c.used);
        c.trip = if (c.used >= c.gc_at or c.refused)
            std.math.maxInt(usize)
        else if (c.over_start)
            0
        else
            c.used;
        var f = c.followers;
        while (f) |x| : (f = x.next_follower) {
            x.used = c.used;
            x.trip = c.trip;
            x.refused = c.refused;
            x.over_start = c.over_start;
        }
    }

    /// True when `more` bytes fit below the hard cap: twice the memory
    /// limit of the root interpreter. Each growth step of a builder,
    /// such as the string form of a large list, gets its memory through
    /// this check. So the cap holds inside one command, before the next
    /// limit check. A request above the cap sets `refused` and fails.
    fn fits(c: *Counting, more: usize) bool {
        const root: *const Interp = @alignCast(@fieldParentPtr("counter", c));
        if (c.used +| more <= root.mem_limit +| root.mem_limit) return true;
        // A stop of a thread stores zero in `mem_limit` for a moment. The
        // cap then comes from the limit of its worker.
        if (comptime thread_mod.supported) {
            const lim = thread_mod.limitOf(root);
            if (c.used +| more <= lim +| lim) return true;
        }
        c.refused = true;
        c.sync();
        return false;
    }

    /// Clears `refused` after the error reached the top level.
    pub fn clearRefused(c: *Counting) void {
        if (!c.refused) return;
        c.refused = false;
        c.sync();
    }

    pub fn setOverStart(c: *Counting, on: bool) void {
        if (c.over_start == on) return;
        c.over_start = on;
        c.sync();
    }

    /// Sets the value of `used` at which the next collection is due.
    pub fn rearm(c: *Counting, at: usize) void {
        c.gc_at = at;
        c.sync();
    }

    pub fn follow(c: *Counting, x: *Counting) void {
        x.used = c.used;
        x.trip = c.trip;
        x.next_follower = c.followers;
        c.followers = x;
    }

    pub fn unfollow(c: *Counting, x: *Counting) void {
        var link = &c.followers;
        while (link.*) |f| : (link = &f.next_follower) {
            if (f == x) {
                link.* = f.next_follower;
                return;
            }
        }
    }

    const Alignment = std.mem.Alignment;

    pub fn allocator(c: *Counting) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (!c.fits(len)) return null;
        const p = c.child.rawAlloc(len, alignment, ra) orelse return null;
        c.used += len;
        c.sync();
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !c.fits(new_len - memory.len)) return false;
        if (!c.child.rawResize(memory, alignment, new_len, ra)) return false;
        c.used = c.used - memory.len + new_len;
        c.sync();
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !c.fits(new_len - memory.len)) return null;
        const p = c.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        c.used = c.used - memory.len + new_len;
        c.sync();
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.child.rawFree(memory, alignment, ra);
        c.used -= memory.len;
        c.sync();
    }
};

/// An optional group of commands. The default interpreter has none.
/// The embedder turns one on with `Interp.allow`.
pub const Capability = enum(u32) {
    package = 1,
    interp = 2,
    clock = 4,
    channels = 8,
    file = 16,
    /// The event loop: `after`, `vwait`, `update`, and `fileevent`.
    event = 32,
    /// `socket`, for loopback addresses only.
    socket = 64,
    /// `exec`, `pid`, and command pipelines. A process is outside the
    /// root folder and outside each limit: this capability gives a
    /// script the full power of the user. It is not sandboxed.
    exec = 128,
    /// Entropy from the system: `zt::crypto random`, `uuid`, and keys.
    random = 256,
    /// `zt::sys env`: a read of the environment.
    env = 512,
    /// The `sqlite3` command. A file also needs `file`.
    sqlite = 1024,
    /// The commands of the Thread package: `thread::*`, `tsv::*`, and
    /// `tpool::*`. Each thread has its own interpreter (`thread.zig`).
    thread = 2048,

    /// The bits of a list of names such as "package,interp".
    pub fn parse(text: []const u8) ?u32 {
        var bits: u32 = 0;
        var iter = std.mem.tokenizeScalar(u8, text, ',');
        while (iter.next()) |w| {
            const c = std.meta.stringToEnum(Capability, w) orelse return null;
            bits |= @intFromEnum(c);
        }
        return bits;
    }
};

const fs_supported = @import("builtin").os.tag == .linux;
const FsState = if (fs_supported) @import("fsroot.zig").State else struct { fd: i32 = -1 };
const ProcHost = if (fs_supported) @import("proc.zig").Host else struct {};
const ProcState = if (fs_supported) @import("proc.zig").State else struct {};
const ChanState = if (fs_supported) @import("chan.zig").State else struct {};

pub const ReturnCode = enum(u32) { ok = 0, @"error" = 1, @"return" = 2, @"break" = 3, @"continue" = 4, _ };

const list_cache_bits = 4;
const list_cache_size = 1 << list_cache_bits;
/// A shorter string parses in about the time of a cache lookup.
const list_cache_min = 32;

const ListCacheEntry = struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
    text: []const u8 = &.{},
    items: ?[]const Value = null,
};

/// The bytes above the frame address that the stack scan also reads. A
/// target can keep locals of a frame above its frame record.
const host_margin: usize = 128;

pub const Interp = struct {
    counter: Counting,
    /// The heap of this interpreter when it is the root of a tree.
    own_heap: Heap,
    /// The heap that holds the values of this interpreter. A child
    /// shares the heap of its parent, so a pointer between the two
    /// interpreters keeps its target alive.
    heap: *Heap,
    /// The most bytes that the arena can hold. Above the limit, the
    /// next command or loop pass stops the script with an error, and
    /// `catch` cannot catch this error. Call `reset` to free the memory.
    mem_limit: usize = std.math.maxInt(usize),
    commands: Commands = .empty,
    /// Changes when a command is added, renamed, or deleted. A command
    /// site keeps its looked-up command only for the same epoch.
    epoch: u32 = 1,
    /// The last epoch where the inlined core commands were original.
    safe_epoch: u32 = 0,
    /// The last epoch where a check found a changed core command.
    unsafe_epoch: u32 = 0,
    global: Frame = .{},
    frame: *Frame = undefined,
    free_vars: ?*Var = null,
    free_frames: std.ArrayList(*Frame) = .empty,
    /// The result of the last command, or the error message.
    result: Value = Value.empty,
    /// The code and the level of a pending `return`.
    ret_code: ReturnCode = .ok,
    ret_level: u32 = 1,
    /// The code of error.TclCustom: a return code above 4.
    custom_code: u32 = 5,
    /// The line of the command that failed last.
    error_line: u32 = 0,
    /// The trace of the current error: the value of `errorInfo`.
    error_info: std.ArrayList(u8) = .empty,
    in_error: bool = false,
    /// The code of the current error: the value of `errorCode`.
    error_code: Value = .{ .str = "NONE" },
    /// True after `error msg info`: the trace starts with the given
    /// text, and the `error` command adds no line of its own.
    skip_info: bool = false,
    /// The line of the last failed command in its own script.
    proc_line: u32 = 0,
    /// Steps left. Each command and each loop pass uses one step.
    step_limit: u64 = std.math.maxInt(u64),
    depth: u32 = 0,
    max_depth: u32 = 600,
    /// The nesting of scripts in scripts, and its limit.
    nest: u32 = 0,
    max_nest: u32 = 2000,
    /// The native stack that nested scripts can use, in bytes. A frame
    /// of the bytecode loop is large in a debug build, so the count of
    /// `max_nest` alone does not keep the stack safe.
    max_native: usize = 5 << 20,
    /// The address of the stack at the outermost script.
    native_base: usize = 0,
    output: ?Output = null,
    /// The scripts and expressions of strings that are not literal words.
    /// The tables of the two caches live outside the heap. The collector
    /// keeps an entry while its text is live (see `gc.zig`).
    script_cache: std.AutoHashMapUnmanaged(SliceKey, *Script) = .empty,
    expr_cache: std.AutoHashMapUnmanaged(SliceKey, *expr.Node) = .empty,
    /// The parsed form of strings that a read command sees again.
    list_cache: [list_cache_size]ListCacheEntry = @splat(.{}),
    /// The stack of command words.
    chunks: std.ArrayList([]Value) = .empty,
    chunk: usize = 0,
    top: usize = 0,
    rand_state: u64 = 0x9e3779b97f4a7c15,
    /// The seed of `noise2` and `noise3`. The embedder sets it.
    noise_seed: u32 = @import("noise.zig").default_seed,
    /// Data of the embedder (for example the point of a point proc).
    user: ?*anyopaque = null,
    /// The point procs. `point.install` sets it.
    points: ?*@import("point.zig").State = null,
    /// The current namespace: its full name with no leading "::". The
    /// global namespace is "". Each name has one address (`internNs`).
    ns: []const u8 = "",
    namespaces: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// The export patterns of each namespace.
    exports: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    /// The `namespace path` of each namespace: full names with no
    /// leading "::".
    ns_paths: std.StringHashMapUnmanaged([]const []const u8) = .empty,

    /// The running coroutine, the count of live ones, and free stacks.
    coro: ?*coro.Coro = null,
    coro_count: u32 = 0,
    coro_stacks: std.ArrayList([]u8) = .empty,
    /// The size of a new chunk of the word stack, in values.
    word_chunk: usize = chunk_size,
    /// The command of a pending `tailcall`.
    tail_words: ?[]const Value = null,
    /// The bits of the capabilities that are on.
    capabilities: u32 = 0,
    /// The time and zone callbacks of the `clock` capability.
    clock_host: ?@import("clock.zig").Host = null,
    clock: @import("clock.zig").State = .{},
    /// The clock and the sleep of the event loop, from the embedder.
    event_host: ?@import("event.zig").Host = null,
    /// The event loop that this interpreter shares with its parent.
    events: ?*@import("event.zig").State = null,
    /// The network policy of `socket`. The embedder sets it.
    net: @import("sock.zig").Policy = .loopback,
    /// The value of `encoding system` and of `encoding dirs`.
    sys_encoding: []const u8 = "utf-8",
    enc_dirs: Value = Value.empty,
    /// The command prefix of `interp bgerror`, or null for the default.
    bg_handler: ?[]const u8 = null,
    /// The program list, the time limit, and the environment of `exec`.
    exec_host: ProcHost = .{},
    execs: ProcState = .{},
    /// The root folder and the channels of the file capabilities.
    fs: FsState = .{},
    chans: ChanState = .{},
    temp_next: u32 = 0,
    /// The state of the `package` command.
    pkg: @import("pkg.zig").State = .{},
    /// The child interpreters of the `interp` command.
    children: std.StringHashMapUnmanaged(*@import("child.zig").Child) = .empty,
    /// Each interpreter under this one, also a deleted one that still
    /// runs. Only the root has the list. It lives outside the heap.
    kids: std.ArrayList(*Interp) = .empty,
    /// False turns the collector off. The memory limit is then exact.
    gc_on: bool = true,
    /// Ranges of embedder memory that can hold values. Each range is a
    /// root of the collector.
    gc_roots: std.ArrayList([]const u8) = .empty,
    /// The values that `hold` keeps. The list lives outside the heap.
    held: std.ArrayList(Value) = .empty,
    /// True while `collect` runs, so a collection can run outside a script.
    gc_manual: bool = false,
    /// Above zero, `native_base` is valid and a collection can scan the
    /// native stack. Only `evalTop` and `enterHost` set it. A host call
    /// of `evalCmd`, `call`, or `callWords` at nest 0 leaves it at zero,
    /// so the frames of the host stay safe and no collection runs.
    gc_scope: u32 = 0,
    /// Precise builds: the `nest` of the innermost clean `vm.run`. The
    /// chain is clean only when this equals `nest`, so a frame of any
    /// other kind between two runs ends it. Zero means no clean run.
    gc_clean_nest: u32 = 0,
    /// Precise builds: the next `vm.run` continues a clean chain.
    gc_token: bool = false,
    /// Precise builds: the address of the words of a body command that
    /// `vm.exec` called directly. Zero means no such call.
    gc_direct: usize = 0,
    /// Precise builds: the next `evalCmd` comes from `vm.exec`.
    gc_from_exec: bool = false,
    /// Precise builds: the current safe point is in `vm.exec`.
    gc_vm_point: bool = false,
    /// Precise builds: addresses that only a clean native frame holds.
    pins: std.ArrayList(usize) = .empty,
    parent: ?*Interp = null,
    is_safe: bool = false,
    /// The count of calls into this interpreter that are running.
    active: u32 = 0,
    /// Deleted while it ran. The last call out of it frees it.
    doomed: bool = false,
    hidden: std.StringHashMapUnmanaged(*Command) = .empty,
    /// The handler of `namespace unknown` for each namespace.
    ns_unknown: std.StringHashMapUnmanaged(Value) = .empty,
    unknown_depth: u32 = 0,
    /// The command that runs for a name with no command.
    missing: Command = .{ .name = "unknown", .impl = .{ .native = ns_mod.dispatchUnknown } },
    /// The `-during` options of an error that `try` raises again.
    pending_during: ?Value = null,
    /// The trace of the error that `finishError` ended.
    last_info: Value = Value.empty,
    /// The `-during` options of the error that `finishError` ended.
    last_during: ?Value = null,
    /// The value of `info script`. The runner does not set it.
    script_name: []const u8 = "",
    /// The state of TclOO. The first use of an `oo::` command makes it.
    oo: ?*anyopaque = null,
    /// The result of `info nameofexecutable`, from the embedder.
    exe_name: []const u8 = "",
    /// The value of `tcl_precision`.
    precision: u8 = 0,
    /// The count of variables with traces. Above zero, the inline
    /// forms of the bytecode and the direct forms are off.
    var_traces: u32 = 0,
    /// The local name of an element link while its trace runs. A trace
    /// callback gets this name with an empty index, as in Tcl.
    trace_shown: ?[]const u8 = null,
    /// The active searches of `array startsearch`.
    searches: std.ArrayList(@import("extra.zig").Search) = .empty,
    /// The last compiled regular expressions.
    regex_cache: [@import("regex.zig").cache_size]@import("regex.zig").CacheEntry = @splat(.{}),
    /// The failed spans of the current regular expression search.
    re_memo: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The strings that `append` can extend in place.
    tails: [4]StrTail = @splat(.{}),
    next_tail: u8 = 0,
    /// The state of the JIT, or null when it is off (`enableJit`).
    jit: ?*jit_mod.State = null,
    /// The thread of this interpreter when the capability `thread` is
    /// on. Only the top interpreter of a thread has it.
    worker: ?*thread_mod.Worker = null,
    /// The limits of the threads. The embedder sets them before it turns
    /// the capability `thread` on.
    thread_limits: thread_mod.Limits = .{},

    const StrTail = struct { end: usize = 0, limit: usize = 0 };
    const SliceKey = struct { ptr: usize, len: usize };
    const chunk_size = 16 * 1024;

    /// Makes an interpreter with the core commands. Call `deinit` to
    /// free all its memory. The interpreter must not move after `init`.
    pub fn init(it: *Interp, gpa: Allocator) Allocator.Error!void {
        it.* = .{ .counter = .{ .child = gpa }, .own_heap = undefined, .heap = undefined };
        it.own_heap = Heap.init(it.counter.allocator());
        it.heap = &it.own_heap;
        it.setRoots();
        try it.start();
    }

    /// Makes a child interpreter that uses the heap of `parent`.
    pub fn initChild(it: *Interp, parent: *Interp) Allocator.Error!void {
        const backing = parent.heap.backing;
        it.* = .{ .counter = .{ .child = backing }, .own_heap = Heap.init(backing), .heap = parent.heap };
        // The family list makes the child a root of the collector. The
        // child joins it before its first allocation.
        // The collector finds the root through this field, also while
        // the child runs its startup script.
        it.parent = parent;
        var root = parent;
        while (root.parent) |p| root = p;
        try root.kids.append(backing, it);
        root.counter.follow(&it.counter);
        errdefer {
            _ = root.kids.pop();
            root.counter.unfollow(&it.counter);
        }
        try it.start();
    }

    /// Starts a collection at each Nth allocation. Zero turns the mode off.
    pub fn setGcStress(it: *Interp, n: u32) void {
        it.heap.stress = n;
        it.heap.stress_left = 0;
        it.heap.stress_alloc = n != 0 and gc.native_scan;
        var root = it;
        while (root.parent) |p| root = p;
        root.counter.rearm(if (n != 0) 0 else @import("heap.zig").min_threshold);
    }

    /// The count of collections that the heap ran.
    pub fn gcCount(it: *const Interp) u64 {
        return it.heap.collections;
    }

    /// Runs a collection now. Only the roots of the collector keep a
    /// value: use `hold` for a value of the embedder.
    pub fn collect(it: *Interp) void {
        it.gc_manual = true;
        defer it.gc_manual = false;
        it.heap.roots_ctx = it;
        if (gc.allowed(it)) @import("heap.zig").collect(it.heap);
    }

    /// The limit check of a safe point. `trip` is at or above the limit:
    /// the memory limit is reached, or a collection is due. `vm_point`
    /// is true only in `vm.exec`, where each live value is in memory
    /// that the collector reads.
    pub noinline fn memPoint(it: *Interp, vm_point: bool) Error!void {
        @branchHint(.cold);
        const heap_mod = @import("heap.zig");
        const h = it.heap;
        var root = it;
        while (root.parent) |p| root = p;
        if (comptime thread_mod.supported) {
            if (root.worker) |w| try thread_mod.safePoint(it, w);
        }
        const c = &root.counter;
        var want = c.used >= c.gc_at or it.counter.used > it.mem_limit;
        const stress = h.stress != 0;
        if (stress) want = (!gc.precise or vm_point) and h.stressDue() or it.counter.used > it.mem_limit;
        var next = c.used +| (1 << 20);
        var collected = false;
        if (want) {
            it.gc_vm_point = vm_point;
            defer it.gc_vm_point = false;
            h.roots_ctx = it;
            if (gc.allowed(it)) {
                heap_mod.collect(h);
                collected = h.mark_ok;
                if (collected) next = @max(h.threshold, c.used +| (1 << 20));
                if (collected and c.used <= root.mem_limit) c.over_start = false;
            }
        }
        // A precise build that waits for a clean safe point keeps `trip`
        // high, so the next clean point of `vm.exec` collects.
        const waiting = gc.precise and !collected and root.gc_on and it.gc_scope != 0;
        if (stress) c.rearm(0) else if (!waiting) c.rearm(next);
        if (it.overLimit()) return it.memError();
    }

    /// The error at the memory limit. Its message is static, so the
    /// error needs no allocation. The trace has only the message.
    pub fn memError(it: *Interp) Error {
        it.result = .{ .str = "the script used too much memory" };
        it.error_code = .{ .str = "NONE" };
        it.in_error = false;
        return error.TclError;
    }

    /// Precise builds: records a call from `vm.exec`. A proc continues
    /// the clean chain. A native command continues it only when
    /// `cmds.isBodyCommand` lists it.
    pub inline fn markDirect(it: *Interp, command: *const Command, words: [*]const Value) void {
        if (!gc.isClean(it)) return;
        switch (command.impl) {
            .proc => it.gc_token = true,
            .native => |f| if (cmds.isBodyCommand(f)) {
                it.gc_direct = @intFromPtr(words);
            },
        }
    }

    /// Precise builds: ends the record of `markDirect`.
    pub inline fn clearDirect(it: *Interp) void {
        it.gc_token = false;
        it.gc_direct = 0;
    }

    /// True once for the direct call with the words `argv`. The caller
    /// then pins each value that only its frame holds.
    fn takeDirect(it: *Interp, argv: []const Value) bool {
        if (!gc.precise or argv.len == 0) return false;
        if (it.gc_direct != @intFromPtr(argv.ptr) or !gc.isClean(it)) return false;
        it.gc_direct = 0;
        return true;
    }

    /// Runs the body script of a command. In a direct call of a precise
    /// build, the body stays in the clean chain. `keep` has each address
    /// that only the frame of the command holds across the body.
    pub fn evalBody(it: *Interp, s: *Script, argv: []const Value, keep: []const usize) Error!Value {
        if (!it.takeDirect(argv)) return it.evalScript(s);
        const mark = it.pins.items.len;
        defer {
            it.pins.items.len = mark;
            it.gc_token = false;
        }
        try it.pins.append(it.heap.backing, @intFromPtr(argv.ptr));
        try it.pins.appendSlice(it.heap.backing, keep);
        s.runs = @max(s.runs, 1);
        it.gc_token = true;
        return it.evalScript(s);
    }

    /// Prepares a proc call from a body command, as `evalBody` does.
    /// Returns the mark for `endProcBody`, or null.
    pub fn beginProcBody(it: *Interp, argv: []const Value, keep: []const usize) Allocator.Error!?usize {
        if (!it.takeDirect(argv)) return null;
        const mark = it.pins.items.len;
        try it.pins.append(it.heap.backing, @intFromPtr(argv.ptr));
        try it.pins.appendSlice(it.heap.backing, keep);
        it.gc_token = true;
        return mark;
    }

    pub fn endProcBody(it: *Interp, mark: ?usize) void {
        const m = mark orelse return;
        it.pins.items.len = m;
        it.gc_token = false;
    }

    /// The limit check of each safe point outside `vm.exec`.
    pub inline fn checkMem(it: *Interp) Error!void {
        if (it.counter.trip >= it.mem_limit) try it.memPoint(false);
    }

    /// Keeps `v` and each block that it reaches until `release(v)`. A
    /// value from `eval` is valid until the next call into the
    /// interpreter. `hold` keeps it longer.
    pub fn hold(it: *Interp, v: Value) Allocator.Error!void {
        try it.held.append(it.heap.backing, v);
    }

    /// Ends one `hold` of `v`.
    pub fn release(it: *Interp, v: Value) void {
        var i = it.held.items.len;
        while (i > 0) {
            i -= 1;
            if (std.meta.eql(it.held.items[i], v)) {
                _ = it.held.swapRemove(i);
                return;
            }
        }
    }

    /// Adds a range of embedder memory that can hold values. Each
    /// aligned word of the range is a possible pointer.
    pub fn addRoot(it: *Interp, bytes: []const u8) Allocator.Error!void {
        try it.gc_roots.append(it.heap.backing, bytes);
    }

    /// Ends `addRoot` for the same range.
    pub fn removeRoot(it: *Interp, bytes: []const u8) void {
        for (it.gc_roots.items, 0..) |r, i| {
            if (r.ptr == bytes.ptr and r.len == bytes.len) {
                _ = it.gc_roots.swapRemove(i);
                return;
            }
        }
    }

    /// Frees the tables of the caches that key a value by its address.
    pub fn freeCaches(it: *Interp) void {
        it.script_cache.deinit(it.heap.backing);
        it.expr_cache.deinit(it.heap.backing);
        it.script_cache = .empty;
        it.expr_cache = .empty;
    }

    /// True when this interpreter owns its heap.
    pub fn isRoot(it: *const Interp) bool {
        return it.heap == &it.own_heap;
    }

    /// Tells the heap how to find the roots of a collection.
    pub fn setRoots(it: *Interp) void {
        it.own_heap.roots_ctx = it;
        it.own_heap.roots_fn = gc.markRoots;
    }

    /// Makes the interpreter new again: all commands, variables, and
    /// values of scripts go away, and the arena frees its memory. The
    /// limits, the output, and the data of the embedder stay.
    pub fn reset(it: *Interp) Allocator.Error!void {
        if (comptime thread_mod.supported) thread_mod.endGroup(it);
        @import("child.zig").destroyAll(it);
        @import("event.zig").forget(it);
        if (comptime fs_supported) {
            @import("chan.zig").closeAll(it);
            @import("proc.zig").abandonAll(it);
        }
        const fs_keep = it.fs;
        defer it.fs = fs_keep;
        const caps = it.capabilities;
        defer it.capabilities = caps;
        if (it.points) |s| s.programs = .empty;
        it.freeCaches();
        it.tail_words = null;
        if (it.isRoot()) it.own_heap.reset();
        const counter = it.counter;
        const own = it.own_heap;
        const heap = it.heap;
        const keep = it.*;
        // No code of the old heap stays, so the machine code goes too.
        jit_mod.flush(it);
        it.* = .{ .counter = counter, .own_heap = own, .heap = heap, .kids = keep.kids, .gc_on = keep.gc_on, .gc_roots = keep.gc_roots, .held = keep.held, .pins = keep.pins, .jit = keep.jit };
        it.held.clearRetainingCapacity();
        it.pins.clearRetainingCapacity();
        it.counter.refused = false;
        it.counter.over_start = false;
        if (it.isRoot()) it.counter.rearm(if (it.heap.stress != 0) 0 else @import("heap.zig").min_threshold);
        it.mem_limit = keep.mem_limit;
        it.step_limit = keep.step_limit;
        it.max_depth = keep.max_depth;
        it.max_nest = keep.max_nest;
        it.max_native = keep.max_native;
        it.output = keep.output;
        it.user = keep.user;
        it.noise_seed = keep.noise_seed;
        it.clock_host = keep.clock_host;
        it.event_host = keep.event_host;
        it.exec_host = keep.exec_host;
        it.net = keep.net;
        it.thread_limits = keep.thread_limits;
        it.parent = keep.parent;
        it.is_safe = keep.is_safe;
        try it.start();
        try it.allow(caps);
    }

    /// Frees the memory of past evaluations and keeps the commands, the
    /// procs, the namespaces, and the point programs. Call it between
    /// evaluations. Each value in `roots` stays valid at a new address.
    /// All other values from before the call are invalid after it.
    pub fn compact(it: *Interp, roots: []Value, opts: @import("compact.zig").Options) @import("compact.zig").Error!void {
        return @import("compact.zig").run(it, roots, opts);
    }

    /// The bytes that the arena holds now.
    pub fn memUsed(it: *const Interp) usize {
        return it.counter.used;
    }

    /// True above the memory limit, or after the counter refused a
    /// request above the hard cap. In a top-level eval that started
    /// above the limit, only the hard cap applies.
    pub fn overLimit(it: *const Interp) bool {
        if (it.counter.refused) return true;
        if (it.counter.used <= it.mem_limit or it.counter.over_start) return false;
        // A stop of a thread stores zero in `mem_limit` for a moment.
        if (comptime thread_mod.supported) return thread_mod.overLimit(it);
        return true;
    }

    fn start(it: *Interp) Allocator.Error!void {
        it.frame = &it.global;
        try cmds.register(it);
        try @import("oo.zig").register(it);
        try it.startVars();
    }

    /// Sets the variables that each interpreter has. They have fixed
    /// values on all platforms, so a script gives the same result
    /// everywhere.
    pub fn startVars(it: *Interp) Allocator.Error!void {
        trace.installPrecision(it) catch return error.OutOfMemory;
        _ = it.eval("array set tcl_platform {platform unix os ztcl osVersion 0 machine generic user {} byteOrder littleEndian wordSize 8 pointerSize 8 engine ztcl}; set tcl_version 8.6; set tcl_patchLevel 8.6.16; set errorInfo {}; set errorCode NONE") catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
    }

    /// Turns on capabilities: the bits of `Capability`. A capability
    /// adds its commands. The default interpreter has none.
    pub fn allow(it: *Interp, bits: u32) Allocator.Error!void {
        const new = bits & ~it.capabilities;
        it.capabilities |= bits;
        if (new & @intFromEnum(Capability.package) != 0) {
            try it.register("package", @import("pkg.zig").cmdPackage);
            _ = it.eval("package provide TclOO 1.1.0") catch {};
        }
        if (new & @intFromEnum(Capability.interp) != 0) try it.register("interp", @import("child.zig").cmdInterp);
        if (new & @intFromEnum(Capability.clock) != 0) try @import("clock.zig").register(it);
        if (new & @intFromEnum(Capability.event) != 0) try @import("event.zig").register(it);
        // The file commands exist on Linux, where `openat2` is the jail.
        if (comptime fs_supported) {
            if (new & @intFromEnum(Capability.channels) != 0) try @import("chan.zig").register(it);
            if (new & @intFromEnum(Capability.file) != 0) try @import("filecmd.zig").register(it);
            if (new & @intFromEnum(Capability.exec) != 0) try @import("proc.zig").register(it);
            if (new & @intFromEnum(Capability.socket) != 0) try it.register("socket", @import("sock.zig").cmdSocket);
        }
        if (comptime thread_mod.supported) {
            if (new & @intFromEnum(Capability.thread) != 0) try thread_mod.register(it);
        }
    }

    /// True when the file capabilities have a root folder.
    pub fn fs_ok(it: *const Interp) bool {
        return it.fs.fd >= 0;
    }

    pub fn deinit(it: *Interp) void {
        if (comptime thread_mod.supported) thread_mod.endGroup(it);
        if (!it.isRoot()) {
            var root = it.parent.?;
            while (root.parent) |p| root = p;
            root.counter.unfollow(&it.counter);
        }
        @import("child.zig").destroyAll(it);
        if (comptime fs_supported) {
            @import("chan.zig").closeAll(it);
            @import("proc.zig").abandonAll(it);
            if (it.fs.fd >= 0) _ = std.os.linux.close(it.fs.fd);
        }
        it.freeCaches();
        it.gc_roots.deinit(it.heap.backing);
        it.held.deinit(it.heap.backing);
        it.pins.deinit(it.heap.backing);
        if (it.isRoot()) {
            it.kids.deinit(it.heap.backing);
            it.own_heap.deinit();
        }
        jit_mod.destroy(it);
    }

    /// Turns the JIT on. Returns false when the build or the system has
    /// no JIT. Only the embedder calls it: a script cannot turn it on.
    pub fn enableJit(it: *Interp, options: jit_mod.Options) bool {
        return jit_mod.enable(it, options);
    }

    pub fn alloc(it: *Interp) Allocator {
        return it.heap.allocator();
    }

    pub fn register(it: *Interp, name: []const u8, f: NativeFn) Allocator.Error!void {
        const c = try it.alloc().create(Command);
        c.* = .{ .name = name, .impl = .{ .native = f } };
        try it.commands.put(it.alloc(), name, c);
        it.epoch += 1;
    }

    // ---- Errors ----

    pub fn fail(it: *Interp, comptime fmt: []const u8, args: anytype) Error {
        it.result = .{ .str = try std.fmt.allocPrint(it.alloc(), fmt, args) };
        it.error_code = .{ .str = "NONE" };
        return error.TclError;
    }

    /// An error with the given `errorCode` (a list in text form).
    pub fn failCode(it: *Interp, code: []const u8, comptime fmt: []const u8, args: anytype) Error {
        it.result = .{ .str = try std.fmt.allocPrint(it.alloc(), fmt, args) };
        it.error_code = .{ .str = code };
        return error.TclError;
    }

    pub fn wrongArgs(it: *Interp, comptime usage: []const u8) Error {
        return it.failCode("TCL WRONGARGS", "wrong # args: should be \"" ++ usage ++ "\"", .{});
    }

    pub fn str(it: *Interp, v: Value) Allocator.Error![]const u8 {
        return v.toStr(it.alloc());
    }

    pub fn list(it: *Interp, v: Value) Error![]const Value {
        return v.asList(it.alloc()) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadList => return it.listError(v),
        };
    }

    /// The error of a value that is not a list.
    pub fn listError(it: *Interp, v: Value) Error {
        const f = value.listFault(try it.str(v)) orelse return it.fail("unmatched open brace or quote in list", .{});
        return switch (f.kind) {
            .brace => it.failCode("TCL VALUE LIST BRACE", "unmatched open brace in list", .{}),
            .quote => it.failCode("TCL VALUE LIST QUOTE", "unmatched open quote in list", .{}),
            .after_brace => it.failCode("TCL VALUE LIST JUNK", "list element in braces followed by \"{s}\" instead of space", .{f.rest}),
            .after_quote => it.failCode("TCL VALUE LIST JUNK", "list element in quotes followed by \"{s}\" instead of space", .{f.rest}),
        };
    }

    /// The elements of `v` for a command that only reads them. A string
    /// that comes again at the same address has a cached parse. The
    /// entry has its own copy of the text, and a compare with that copy
    /// guards each hit. The first use of a string makes no copy.
    pub fn readList(it: *Interp, v: Value) Error![]const Value {
        if (v == .list) return v.list.items();
        if (v != .str or v.str.len < list_cache_min) return it.list(v);
        const s = v.str;
        const h = (@as(u64, @intFromPtr(s.ptr)) >> 3 ^ s.len) *% 0x9e3779b97f4a7c15;
        const e = &it.list_cache[@intCast(h >> (64 - list_cache_bits))];
        if (e.ptr != s.ptr or e.len != s.len) {
            e.* = .{ .ptr = s.ptr, .len = s.len };
            return it.list(v);
        }
        if (e.items) |items| {
            if (std.mem.eql(u8, e.text, s)) return items;
            e.items = null;
            return it.list(v);
        }
        const text = try it.alloc().dupe(u8, s);
        const items = try it.list(.{ .str = text });
        e.text = text;
        e.items = items;
        return items;
    }

    pub fn int(it: *Interp, v: Value) Error!i64 {
        return v.asInt() orelse it.fail("expected integer but got \"{s}\"", .{try it.str(v)});
    }

    // ---- Evaluation ----

    /// Runs a script text. Returns the result of the last command.
    /// After error.TclError, `result` is the message.
    pub fn eval(it: *Interp, text: []const u8) Error!Value {
        const s = try it.compile(try it.alloc().dupe(u8, text));
        return it.evalTop(s);
    }

    /// Runs a script at the top level: a `return` ends it with a value.
    pub fn evalTop(it: *Interp, s: *Script) Error!Value {
        value.precision = it.precision;
        // Inside any other entry of the tree, the frames above this one
        // can hold values. This call then adds no scan range.
        const outer = it.heap.scopes == 0;
        if (outer) try it.startTop(s);
        it.heap.scopes += 1;
        defer it.heap.scopes -= 1;
        if (outer) {
            it.native_base = @frameAddress() + host_margin;
            it.gc_scope = 1;
            if (gc.precise) {
                // The top level runs as bytecode, so a long loop reaches
                // the safe points of `vm.exec`.
                s.runs = @max(s.runs, 1);
                it.gc_token = true;
            }
        }
        defer if (outer) {
            it.gc_scope = 0;
            if (gc.precise) it.gc_token = false;
            it.rootCounter().setOverStart(false);
        };
        if (outer) it.rootCounter().clearRefused();
        var r = it.evalTopInner(s);
        // A refused request becomes the error of the memory limit, also
        // when a command did not pass the allocation error on.
        if (it.counter.refused) {
            r = it.memError();
            if (outer) it.rootCounter().clearRefused();
        }
        return r catch |e| {
            if (e == error.TclError) try it.finishError();
            return e;
        };
    }

    /// Prepares the memory limit of a top-level eval. A memory error can
    /// leave live data above the limit, up to the hard cap. When `used`
    /// is above the limit, a collection runs first. When the live data
    /// stays above the limit, the eval runs with the hard cap only, so
    /// the script can free the data. The script `s` is a pin during the
    /// collection, because no other root holds it.
    fn startTop(it: *Interp, s: *Script) Allocator.Error!void {
        var root = it;
        while (root.parent) |p| root = p;
        const c = &root.counter;
        c.setOverStart(false);
        if (c.used <= root.mem_limit) return;
        try it.pins.append(it.heap.backing, @intFromPtr(s));
        it.collect();
        it.pins.items.len -= 1;
        c.setOverStart(c.used > root.mem_limit);
    }

    /// The counter of the root interpreter. Only it counts allocations.
    fn rootCounter(it: *Interp) *Counting {
        var root = it;
        while (root.parent) |p| root = p;
        return &root.counter;
    }

    fn evalTopInner(it: *Interp, s: *Script) Error!Value {
        return it.evalScript(s) catch |e| switch (e) {
            error.TclReturn => {
                if (it.ret_code == .ok) return it.result;
                if (it.ret_code == .@"error") return error.TclError;
                if (it.ret_code == .@"break" or it.ret_code == .@"continue")
                    return it.fail("invoked \"{s}\" outside of a loop", .{@tagName(it.ret_code)});
                return it.fail("command returned bad code: {d}", .{@intFromEnum(it.ret_code)});
            },
            error.TclCustom => it.fail("command returned bad code: {d}", .{it.custom_code}),
            error.TclBreak => it.fail("invoked \"break\" outside of a loop", .{}),
            error.TclContinue => it.fail("invoked \"continue\" outside of a loop", .{}),
            else => e,
        };
    }

    pub fn compile(it: *Interp, text: []const u8) Error!*Script {
        var p: Parser = .{ .a = it.alloc(), .src = text };
        return p.parseScript(false) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TclError => {
                it.error_line = p.line;
                return it.fail("{s}", .{p.message});
            },
        };
    }

    /// The compiled script of argument `i` of a command. A literal word
    /// keeps its script in the cache slot of the command.
    pub fn scriptOf(it: *Interp, argv: []const Value, i: usize, cmd: ?*Cmd) Error!*Script {
        return it.scriptOfValue(argv[i], if (cmd) |c| slotOf(c, i) else null);
    }

    fn slotOf(c: *Cmd, i: usize) ?*Cache {
        if (c.has_expand or i >= c.words.len or c.words[i].kind != .lit) return null;
        return &c.cache[i];
    }

    pub fn scriptOfValue(it: *Interp, v: Value, slot: ?*Cache) Error!*Script {
        if (slot) |s| if (s.script) |sc| return sc;
        const text = try it.str(v);
        const key: SliceKey = .{ .ptr = @intFromPtr(text.ptr), .len = text.len };
        if (slot == null and v == .str) {
            if (it.script_cache.get(key)) |sc| return sc;
        }
        const sc = try it.compile(text);
        if (slot) |s| {
            s.script = sc;
        } else if (v == .str) {
            // Strings live in the arena and do not change, so the address
            // and the length name the text.
            try it.script_cache.put(it.heap.backing, key, sc);
        }
        return sc;
    }

    /// The compiled expression of argument `i` of a command.
    pub fn exprOf(it: *Interp, argv: []const Value, i: usize, cmd: ?*Cmd) Error!*expr.Node {
        const slot = if (cmd) |c| slotOf(c, i) else null;
        if (slot) |s| if (s.expr) |n| return n;
        const v = argv[i];
        const text = try it.str(v);
        const key: SliceKey = .{ .ptr = @intFromPtr(text.ptr), .len = text.len };
        if (slot == null and v == .str) {
            if (it.expr_cache.get(key)) |n| return n;
        }
        const n = try expr.compile(it, text);
        if (slot) |s| {
            s.expr = n;
        } else if (v == .str) {
            try it.expr_cache.put(it.heap.backing, key, n);
        }
        return n;
    }

    /// Fails when the nested scripts use too much native stack. The
    /// stack grows down. The outermost script sets the base.
    pub inline fn checkNative(it: *Interp) Error!void {
        const here = @frameAddress();
        if (it.nest == 0 and it.gc_scope == 0) it.native_base = here;
        if (it.native_base -| here > it.max_native) {
            return it.fail("too many nested evaluations (infinite loop?)", .{});
        }
    }

    pub fn evalScript(it: *Interp, s: *Script) Error!Value {
        const host = it.nest == 0 and it.heap.scopes == 0;
        if (host) it.heap.scopes = 1;
        defer if (host) {
            it.heap.scopes = 0;
        };
        try it.checkNative();
        if (s.code) |bc| return vm.run(it, bc);
        // A script that runs one time stays on the general path.
        if (s.runs > 0) {
            s.code = try vm.compileNamed(it, s);
            return vm.run(it, s.code.?);
        }
        s.runs = 1;
        // Each script in a script is one level: `eval`, a loop body, a
        // command substitution. The limit keeps the native stack safe.
        if (it.nest >= it.max_nest) return it.fail("too many nested evaluations (infinite loop?)", .{});
        it.nest += 1;
        defer it.nest -= 1;
        var res: Value = Value.empty;
        for (s.cmds) |*c| res = try it.evalCmd(c);
        return res;
    }

    pub const StackMark = struct { chunk: usize, top: usize };

    pub fn stackMark(it: *Interp) StackMark {
        return .{ .chunk = it.chunk, .top = it.top };
    }

    pub fn stackRelease(it: *Interp, m: StackMark) void {
        it.chunk = m.chunk;
        it.top = m.top;
    }

    pub inline fn stackAllocPub(it: *Interp, n: usize) Allocator.Error![]Value {
        return it.stackAlloc(n);
    }

    inline fn stackAlloc(it: *Interp, n: usize) Allocator.Error![]Value {
        if (it.chunks.items.len != 0) {
            const c = it.chunks.items[it.chunk];
            if (it.top + n <= c.len) {
                const out = c[it.top .. it.top + n];
                it.top += n;
                return out;
            }
        }
        return it.stackGrow(n);
    }

    fn stackGrow(it: *Interp, n: usize) Allocator.Error![]Value {
        if (it.chunks.items.len == 0 or it.top + n > it.chunks.items[it.chunk].len) {
            if (it.chunks.items.len != 0) it.chunk += 1;
            if (it.chunk >= it.chunks.items.len) {
                try it.chunks.append(it.alloc(), try it.alloc().alloc(Value, @max(it.word_chunk, n)));
            } else if (it.chunks.items[it.chunk].len < n) {
                it.chunks.items[it.chunk] = try it.alloc().alloc(Value, n);
            }
            it.top = 0;
        }
        const out = it.chunks.items[it.chunk][it.top .. it.top + n];
        it.top += n;
        return out;
    }

    pub fn evalCmd(it: *Interp, c: *Cmd) Error!Value {
        if (it.nest == 0) return it.hostCmd(c);
        const from_exec = gc.precise and it.gc_from_exec;
        if (gc.precise) it.gc_from_exec = false;
        if (it.step_limit == 0) return it.fail("step limit reached", .{});
        it.step_limit -= 1;
        try it.checkMem();
        if (c.fast != .none and c.epoch == it.epoch and c.ns == it.ns.ptr) {
            if (it.evalFast(c) catch |e| return it.noteLine(c, e)) |v| return v;
        }
        const mark_chunk = it.chunk;
        const mark_top = it.top;
        defer {
            it.chunk = mark_chunk;
            it.top = mark_top;
        }
        var argv: []Value = undefined;
        if (!c.has_expand) {
            argv = try it.stackAlloc(c.words.len);
            for (c.words, 0..) |*w, i| {
                argv[i] = it.evalWord(w) catch |e| return it.noteLine(c, e);
            }
        } else {
            var tmp: std.ArrayList(Value) = .empty;
            for (c.words) |*w| {
                const v = it.evalWord(w) catch |e| return it.noteLine(c, e);
                if (w.expand) {
                    try tmp.appendSlice(it.alloc(), try it.list(v));
                } else try tmp.append(it.alloc(), v);
            }
            if (tmp.items.len == 0) return Value.empty;
            argv = tmp.items;
        }
        const command = it.resolve(c, argv) catch |e| return it.noteLine(c, e);
        if (from_exec) it.markDirect(command, argv.ptr);
        defer if (from_exec) it.clearDirect();
        return it.call(command, argv, c) catch |e| it.noteLine(c, e);
    }

    /// The command of a site. A literal name stays in the site for the
    /// same epoch and namespace.
    pub fn resolve(it: *Interp, c: *Cmd, argv: []const Value) Error!*Command {
        if (c.resolved != null and c.epoch == it.epoch and c.ns == it.ns.ptr) return c.resolved.?;
        const name = try it.str(argv[0]);
        const command = it.findCommand(name) orelse return &it.missing;
        if (c.words[0].kind == .lit and !c.has_expand) {
            c.resolved = command;
            c.epoch = it.epoch;
            c.ns = it.ns.ptr;
            c.fast = if (it.var_traces != 0) .none else cmds.classify(command, c);
        }
        return command;
    }

    /// Runs a command in its direct form. Returns null when the case
    /// needs the general path (an array, a link to an array, a cache
    /// slot that is still empty).
    fn evalFast(it: *Interp, c: *Cmd) Error!?Value {
        switch (c.fast) {
            .none => return null,
            .set => {
                const v = try it.evalWord(&c.words[2]);
                const cell = try it.cellOf(c.words[1].kind.lit.str, &c.hint);
                if (cell.v == .val) {
                    cell.v.val = v;
                    return v;
                }
                if (!cell.plainStore()) {
                    @branchHint(.cold);
                    try it.setVar(c.words[1].kind.lit.str, v);
                    return v;
                }
                cell.v = .{ .val = v };
                return v;
            },
            .incr => {
                const cell = try it.cellOf(c.words[1].kind.lit.str, &c.hint);
                switch (cell.v) {
                    .val => |v| {
                        if (v != .int) return null;
                        const sum = @addWithOverflow(v.int, c.by);
                        if (sum[1] != 0) return null;
                        const out: Value = .{ .int = sum[0] };
                        cell.v = .{ .val = out };
                        return out;
                    },
                    else => return null,
                }
            },
            .expr => {
                const n = c.cache[1].expr orelse return null;
                const v = try expr.eval(it, n);
                return try expr.numberForm(it, v);
            },
            .if_then, .if_else => {
                const n = c.cache[1].expr orelse return null;
                if (try expr.truthy(it, try expr.eval(it, n))) {
                    return try it.evalScript(try it.scriptOfValue(c.words[2].kind.lit, &c.cache[2]));
                }
                if (c.fast == .if_then) return Value.empty;
                return try it.evalScript(try it.scriptOfValue(c.words[4].kind.lit, &c.cache[4]));
            },
        }
    }

    /// The cell of a plain local name, made when it is not there. The
    /// hint is the slot of the name at the last call.
    pub fn cellOf(it: *Interp, name: []const u8, hint: *u32) Allocator.Error!*Var {
        if (it.slotCell(name, hint)) |c| return c;
        hint.* = @intCast(it.frame.vars.items.len);
        return (try it.findVar(it.frame, name, true)).?;
    }

    fn sameName(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        if (a.ptr == b.ptr) return true;
        for (a, b) |x, y| if (x != y) return false;
        return true;
    }

    /// The cell of a name in the current frame, or null. Tries the slot
    /// of the hint first, then searches and updates the hint.
    pub inline fn slotCell(it: *Interp, name: []const u8, hint: *u32) ?*Var {
        const vars = it.frame.vars.items;
        const h = hint.*;
        var cell: *Var = undefined;
        if (h < vars.len and sameName(vars[h].name, name)) {
            cell = vars[h].cell;
        } else {
            const i = it.frame.find(it.alloc(), name) orelse return null;
            hint.* = @intCast(i);
            cell = vars[i].cell;
        }
        return cell.settle();
    }

    /// The command of a name. A leading "::" is allowed.
    pub fn findCommand(it: *Interp, name: []const u8) ?*Command {
        const key = it.commandKey(name) orelse return null;
        return it.commands.get(key);
    }

    /// The key of a command name in the table: the name in the current
    /// namespace, or else the name in the global namespace.
    pub fn commandKey(it: *Interp, name: []const u8) ?[]const u8 {
        if (name.len >= 2 and name[0] == ':' and name[1] == ':') {
            const full = std.mem.trimStart(u8, name, ":");
            return if (it.commands.getKey(full)) |k| k else null;
        }
        if (it.ns.len > 0) {
            var buf: [256]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{s}::{s}", .{ it.ns, name })) |full| {
                if (it.commands.getKey(full)) |k| return k;
            } else |_| {}
        }
        if (it.ns_paths.count() != 0) {
            if (it.ns_paths.get(it.ns)) |path| {
                var buf: [256]u8 = undefined;
                for (path) |space| {
                    const full = if (space.len == 0) name else std.fmt.bufPrint(&buf, "{s}::{s}", .{ space, name }) catch continue;
                    if (it.commands.getKey(full)) |k| return k;
                }
            }
        }
        return if (it.commands.getKey(name)) |k| k else null;
    }

    /// The one copy of a namespace name. Adds the namespace and its
    /// parents when they are new.
    pub fn internNs(it: *Interp, name: []const u8) Allocator.Error![]const u8 {
        if (name.len == 0) return "";
        if (it.namespaces.getKey(name)) |k| return k;
        const copy = try it.alloc().dupe(u8, name);
        try it.namespaces.put(it.alloc(), copy, {});
        if (std.mem.lastIndexOf(u8, copy, "::")) |i| _ = try it.internNs(copy[0..i]);
        return copy;
    }

    /// The full name of a new command or variable of the current
    /// namespace, with no leading "::".
    pub fn qualify(it: *Interp, name: []const u8) Allocator.Error![]const u8 {
        if (name.len >= 2 and name[0] == ':' and name[1] == ':') return it.alloc().dupe(u8, std.mem.trimStart(u8, name, ":"));
        if (it.ns.len == 0) return it.alloc().dupe(u8, name);
        return std.fmt.allocPrint(it.alloc(), "{s}::{s}", .{ it.ns, name });
    }

    /// The error of the memory limit in place of an allocation error
    /// after a refused request. Each other error stays.
    pub inline fn limitError(it: *Interp, e: Error) Error {
        if (e == error.OutOfMemory and it.counter.refused) return it.memError();
        return e;
    }

    pub fn noteLine(it: *Interp, c: *Cmd, raw: Error) Error {
        const e = it.limitError(raw);
        if (e != error.TclError) return e;
        if (it.error_line == 0) it.error_line = c.line;
        it.proc_line = c.line;
        // The end of the step limit leaves no trace: the unwind stays cheap.
        if (it.step_limit != 0 and !it.overLimit()) it.addErrorInfo(c) catch {};
        return e;
    }

    /// Adds one command to the trace of the current error.
    fn addErrorInfo(it: *Interp, c: *Cmd) Allocator.Error!void {
        const a = it.alloc();
        if (it.skip_info) {
            it.skip_info = false;
            return;
        }
        if (!it.in_error) {
            it.in_error = true;
            it.error_info = .empty;
            try it.error_info.appendSlice(a, try it.str(it.result));
            try it.error_info.appendSlice(a, "\n    while executing\n\"");
        } else try it.error_info.appendSlice(a, "\n    invoked from within\n\"");
        if (c.text.len > 150) {
            try it.error_info.appendSlice(a, c.text[0..150]);
            try it.error_info.appendSlice(a, "...");
        } else try it.error_info.appendSlice(a, c.text);
        try it.error_info.append(a, '"');
    }

    /// Ends the current error: stores the trace in the global variables
    /// `errorInfo` and `errorCode`. `catch` and the top level call it.
    pub fn finishError(it: *Interp) Allocator.Error!void {
        it.last_during = it.pending_during;
        it.pending_during = null;
        const info: Value = .{ .str = if (it.in_error) it.error_info.items else try it.str(it.result) };
        it.in_error = false;
        it.error_info = .empty;
        it.last_info = info;
        const code = it.error_code;
        try it.storeGlobal("errorInfo", info);
        it.skip_info = false;
        try it.storeGlobal("errorCode", code);
        it.error_code = code;
    }

    /// Writes a global variable of the error state. A trace on it runs,
    /// and the error of a trace does not replace the current error.
    fn storeGlobal(it: *Interp, name: []const u8, v: Value) Allocator.Error!void {
        const cell = (try it.findVar(&it.global, name, true)).?;
        if (cell.v != .traced) {
            cell.v = .{ .val = v };
            return;
        }
        const saved = it.result;
        trace.write(it, cell, name, null, v) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
        };
        it.result = saved;
    }

    /// Runs a command with its words. `argv[0]` is the name.
    pub fn call(it: *Interp, command: *Command, argv: []const Value, c: ?*Cmd) Error!Value {
        switch (command.impl) {
            .native => |f| {
                if (it.nest == 0) return it.hostNative(f, argv, c);
                return f(it, argv, c);
            },
            .proc => |p| return it.callProc(p, argv),
        }
    }

    /// Lets the collector run during host calls of `evalCmd`,
    /// `callWords`, or `call`, and scans the frame of the calling
    /// function. Call `leaveHost` before the function returns. With no
    /// `enterHost`, such a call runs with no collection: the frames of
    /// the host stay safe, and the memory limit stops a long script.
    /// `eval` needs neither call. The function is inline, so it records
    /// the frame of the host function.
    pub inline fn enterHost(it: *Interp) void {
        if (it.heap.scopes == 0) {
            it.native_base = @frameAddress() + host_margin;
            it.gc_scope = 1;
        }
        it.heap.scopes += 1;
        it.nest += 1;
    }

    pub fn leaveHost(it: *Interp) void {
        it.nest -= 1;
        it.heap.scopes -= 1;
        if (it.heap.scopes == 0) it.gc_scope = 0;
    }

    /// Runs a native command that a host calls at nest 0. The frames of
    /// the host are not scanned, so `gc_scope` stays zero and no
    /// collection runs. The count stops a nested `eval` from starting a
    /// scan range below the host frames. A proc call needs no wrapper:
    /// `vm.run` and `evalScript` count the entry.
    noinline fn hostNative(it: *Interp, f: NativeFn, argv: []const Value, c: ?*Cmd) Error!Value {
        @branchHint(.unlikely);
        it.native_base = @frameAddress();
        it.heap.scopes += 1;
        it.nest += 1;
        defer {
            it.nest -= 1;
            it.heap.scopes -= 1;
        }
        return f(it, argv, c);
    }

    /// Runs `evalCmd` for a host at nest 0, as `hostNative` does.
    noinline fn hostCmd(it: *Interp, c: *Cmd) Error!Value {
        @branchHint(.cold);
        it.native_base = @frameAddress();
        it.heap.scopes += 1;
        it.nest += 1;
        defer {
            it.nest -= 1;
            it.heap.scopes -= 1;
        }
        return it.evalCmd(c);
    }

    /// Precise builds: adds one address to the pin list.
    pub inline fn pin(it: *Interp, w: usize) Allocator.Error!void {
        if (it.pins.items.len < it.pins.capacity) {
            it.pins.items.ptr[it.pins.items.len] = w;
            it.pins.items.len += 1;
            return;
        }
        try it.pins.append(it.heap.backing, w);
    }

    /// The items of the list in a plain cell, as a buffer that only the
    /// cell holds. A cell that does not own its list gets a copy and
    /// takes the form `.owned`. Returns null for a cell that is not plain.
    /// A write to the items changes the list of the cell and no other
    /// value. Each general read of the cell ends the ownership.
    pub fn ownList(it: *Interp, cell: *Var) Error!?[]Value {
        const cur = switch (cell.v) {
            .owned => |x| if (x == .list) return @constCast(x.list.items()) else x,
            .val => |x| x,
            else => return null,
        };
        const items = try it.list(cur);
        const copy = try it.alloc().dupe(Value, items);
        cell.v = .{ .owned = try value.wrapList(it.alloc(), copy) };
        return copy;
    }

    /// Runs a command given as a list of words.
    pub fn callWords(it: *Interp, argv: []const Value) Error!Value {
        if (argv.len == 0) return Value.empty;
        if (it.step_limit == 0) return it.fail("step limit reached", .{});
        it.step_limit -= 1;
        const name = try it.str(argv[0]);
        const command = it.findCommand(name) orelse &it.missing;
        return it.call(command, argv, null);
    }

    pub fn pushFrame(it: *Interp, argv: []const Value) Error!*Frame {
        if (it.depth >= it.max_depth) return it.fail("too many nested evaluations (infinite loop?)", .{});
        it.depth += 1;
        const f = it.free_frames.pop() orelse try it.newFrame();
        f.clear();
        f.argv = argv;
        f.parent = it.frame;
        f.ns = null;
        f.level = it.frame.level + 1;
        it.frame = f;
        return f;
    }

    fn newFrame(it: *Interp) Allocator.Error!*Frame {
        const n = try it.alloc().create(Frame);
        n.* = .{};
        return n;
    }

    pub fn popFrame(it: *Interp) void {
        const f = it.frame;
        if (it.var_traces != 0) {
            @branchHint(.cold);
            trace.frameGone(it, f);
        }
        for (f.vars.items) |e| {
            e.cell.next_free = it.free_vars;
            it.free_vars = e.cell;
        }
        it.frame = f.parent.?;
        it.depth -= 1;
        it.free_frames.append(it.alloc(), f) catch {};
    }

    fn callProc(it: *Interp, p: *Proc, argv: []const Value) Error!Value {
        return it.runProc(p, argv, argv[1..], null) catch |e| {
            if (e == error.TclCustom and it.custom_code == coro.tail_code and it.tail_words != null) return it.runTail();
            return e;
        };
    }

    /// Runs pending tail calls in a loop, in the frame of the caller.
    noinline fn runTail(it: *Interp) Error!Value {
        while (true) {
            // A script can forge the tail code with `return -code`.
            const words = it.tail_words orelse return error.TclCustom;
            it.tail_words = null;
            if (it.step_limit == 0) return it.fail("step limit reached", .{});
            it.step_limit -= 1;
            const name = try it.str(words[0]);
            const command = it.findCommand(name) orelse &it.missing;
            const r = switch (command.impl) {
                .proc => |p| it.runProc(p, words, words[1..], null),
                .native => it.call(command, words, null),
            };
            if (r) |v| {
                return v;
            } else |e| {
                if (e == error.TclCustom and it.custom_code == coro.tail_code and it.tail_words != null) continue;
                return e;
            }
        }
    }

    /// Runs the body of a method. The arguments start at `argv[skip]`.
    pub fn callMethod(it: *Interp, p: *Proc, argv: []const Value, skip: usize) Error!Value {
        return it.runProc(p, argv, argv[skip..], null) catch |e| {
            if (e == error.TclCustom and it.custom_code == coro.tail_code and it.tail_words != null) return it.runTail();
            return e;
        };
    }

    /// Runs a lambda of `apply`. The frame has all the words of the call.
    pub fn callLambda(it: *Interp, p: *Proc, argv: []const Value) Error!Value {
        return it.runProc(p, argv, argv[2..], argv[1]) catch |e| {
            if (e == error.TclCustom and it.custom_code == coro.tail_code and it.tail_words != null) return it.runTail();
            return e;
        };
    }

    inline fn runProc(it: *Interp, p: *Proc, argv: []const Value, args: []const Value, lambda: ?Value) Error!Value {
        const np = p.params.len;
        if (args.len > np and !p.has_args) return it.usageOf(p, argv, lambda);
        _ = try it.pushFrame(argv);
        defer it.popFrame();
        const saved_ns = it.ns;
        it.ns = p.ns;
        it.frame.space = p.ns;
        defer it.ns = saved_ns;
        // A clean frame holds the name of the old namespace only here.
        const pinned = gc.precise and it.gc_token;
        const pin_mark = if (gc.precise) it.pins.items.len else 0;
        defer if (pinned) {
            it.pins.items.len = pin_mark;
        };
        if (pinned) try it.pin(@intFromPtr(saved_ns.ptr));
        for (p.params, 0..) |prm, i| {
            if (i < args.len) {
                try it.newLocal(prm.name, args[i]);
            } else if (prm.default) |d| {
                try it.newLocal(prm.name, d);
            } else {
                const e = it.usageOf(p, argv, lambda);
                return e;
            }
        }
        if (p.has_args) {
            const rest = if (args.len > np) args[np..] else &[_]Value{};
            try it.newLocal("args", try value.newList(it.alloc(), rest));
        }
        if (p.script == null) p.script = try it.compile(try it.str(p.body));
        if (p.code == null) p.code = try vm.compileProc(it, p, p.script.?);
        const bc = p.code.?;
        // The other locals of the body start with no value.
        for (bc.names[it.frame.vars.items.len..]) |name| {
            const cell = try it.newCell();
            try it.addEntry(.{ .name = name, .cell = cell });
        }
        return vm.run(it, bc) catch |e| switch (e) {
            error.TclReturn => {
                if (it.ret_level > 1) {
                    it.ret_level -= 1;
                    return error.TclReturn;
                }
                const code = it.ret_code;
                it.ret_code = .ok;
                return switch (code) {
                    .ok => it.result,
                    .@"error" => error.TclError,
                    .@"return" => error.TclReturn,
                    .@"break" => error.TclBreak,
                    .@"continue" => error.TclContinue,
                    _ => blk: {
                        it.custom_code = @intFromEnum(code);
                        break :blk error.TclCustom;
                    },
                };
            },
            error.TclBreak => it.fail("invoked \"break\" outside of a loop", .{}),
            error.TclContinue => it.fail("invoked \"continue\" outside of a loop", .{}),
            error.TclError => {
                if (it.in_error) {
                    if (lambda) |l| {
                        it.error_info.print(it.alloc(), "\n    (lambda term \"{s}\" line {d})", .{ try it.str(l), it.proc_line }) catch {};
                    } else it.error_info.print(it.alloc(), "\n    (procedure \"{s}\" line {d})", .{ try it.str(argv[0]), it.proc_line }) catch {};
                }
                return e;
            },
            else => e,
        };
    }

    fn usageOf(it: *Interp, p: *Proc, argv: []const Value, lambda: ?Value) Error {
        if (lambda == null) return it.procUsage(p, argv[0]);
        const a = it.alloc();
        var out: std.ArrayList(u8) = .empty;
        try out.print(a, "wrong # args: should be \"{s} lambdaExpr", .{try it.str(argv[0])});
        for (p.params) |prm| {
            if (prm.default != null) try out.print(a, " ?{s}?", .{prm.name}) else try out.print(a, " {s}", .{prm.name});
        }
        if (p.has_args) try out.appendSlice(a, " ?arg ...?");
        try out.append(a, '"');
        it.result = .{ .str = out.items };
        it.error_code = .{ .str = "TCL WRONGARGS" };
        return error.TclError;
    }

    fn procUsage(it: *Interp, p: *Proc, name: Value) Error {
        var out: std.ArrayList(u8) = .empty;
        const a = it.alloc();
        try out.appendSlice(a, "wrong # args: should be \"");
        try value.appendElement(a, &out, try it.str(name), false);
        for (p.params) |prm| {
            if (prm.default != null) try out.print(a, " ?{s}?", .{prm.name}) else try out.print(a, " {s}", .{prm.name});
        }
        if (p.has_args) try out.appendSlice(a, " ?arg ...?");
        try out.append(a, '"');
        it.result = .{ .str = out.items };
        it.error_code = .{ .str = "TCL WRONGARGS" };
        return error.TclError;
    }

    pub fn evalWord(it: *Interp, w: *const Word) Error!Value {
        switch (w.kind) {
            .lit => |v| return v,
            .single => |*p| return it.evalPart(p),
            .multi => |parts| return .{ .str = try it.concatParts(parts) },
        }
    }

    pub fn evalPart(it: *Interp, p: *const Part) Error!Value {
        switch (p.*) {
            .lit => |s| return .{ .str = s },
            .variable => |*v| return it.readRef(v),
            .script => |s| return it.evalScript(s),
        }
    }

    pub fn concatParts(it: *Interp, parts: []const Part) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (parts) |*p| {
            const v = try it.evalPart(p);
            try out.appendSlice(it.alloc(), try it.str(v));
        }
        return out.items;
    }

    /// The string `cur` with the parts after it. When `cur` ends at the
    /// used part of a growth buffer, the parts go after it, so a loop of
    /// `append` is linear. Other views of the buffer stay correct,
    /// because the bytes that they see do not change.
    pub fn appendStr(it: *Interp, cur: []const u8, parts: []const []const u8) Allocator.Error![]const u8 {
        var extra: usize = 0;
        for (parts) |s| extra += s.len;
        const cur_end = @intFromPtr(cur.ptr) + cur.len;
        var buf: [*]u8 = undefined;
        var tail: *StrTail = undefined;
        for (&it.tails) |*t| {
            if (cur.len > 0 and t.end == cur_end and t.limit - t.end >= extra) {
                buf = @constCast(cur.ptr);
                tail = t;
                break;
            }
        } else {
            const cap = @max(64, (cur.len + extra) * 2);
            const fresh = try it.alloc().alloc(u8, cap);
            @memcpy(fresh[0..cur.len], cur);
            buf = fresh.ptr;
            tail = &it.tails[it.next_tail];
            it.next_tail = @intCast((it.next_tail + 1) % it.tails.len);
            tail.limit = @intFromPtr(fresh.ptr) + cap;
        }
        var at = cur.len;
        for (parts) |s| {
            @memcpy(buf[at .. at + s.len], s);
            at += s.len;
        }
        tail.end = @intFromPtr(buf) + at;
        return buf[0..at];
    }

    // ---- Variables ----

    fn newCell(it: *Interp) Allocator.Error!*Var {
        if (it.free_vars) |c| {
            it.free_vars = c.next_free;
            c.v = .undef;
            return c;
        }
        const c = try it.alloc().create(Var);
        c.* = .{};
        return c;
    }

    /// Adds an entry to the current frame. A frame from the free list
    /// has the capacity of its last call, so the check almost always
    /// passes.
    inline fn addEntry(it: *Interp, e: VarEntry) Allocator.Error!void {
        const vars = &it.frame.vars;
        if (vars.items.len < vars.capacity) {
            vars.appendAssumeCapacity(e);
        } else try vars.append(it.alloc(), e);
    }

    fn newLocal(it: *Interp, name: []const u8, v: Value) Allocator.Error!void {
        const cell = try it.newCell();
        cell.v = .{ .val = v };
        try it.addEntry(.{ .name = name, .cell = cell });
    }

    /// Finds the cell of a name in a frame. Follows links.
    pub fn findVar(it: *Interp, frame: *Frame, name_in: []const u8, create: bool) Allocator.Error!?*Var {
        var f = frame;
        var name = name_in;
        if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
            if (std.mem.startsWith(u8, name, "::")) {
                f = &it.global;
                name = std.mem.trimStart(u8, name, ":");
            } else if (colon + 1 < name.len and name[colon + 1] == ':' and colon < (std.mem.indexOfScalar(u8, name, '(') orelse name.len)) {
                // A relative name with a namespace: first the current
                // namespace, then the global namespace.
                f = &it.global;
                if (it.ns.len > 0) {
                    const full = try it.qualify(name);
                    if (it.lookup(f, full)) |c| return c;
                    if (it.lookup(f, name)) |c| return c;
                    name = full;
                }
            }
        }
        if (it.lookup(f, name)) |c| return c;
        if (f.ns) |space| {
            // A frame of `namespace eval`: the variable of the namespace,
            // then the global variable.
            const full = try std.fmt.allocPrint(it.alloc(), "{s}::{s}", .{ space, name });
            var target = it.lookup(&it.global, full);
            if (target == null) target = it.lookup(&it.global, name);
            if (target == null and !create) return null;
            if (target == null) {
                target = try it.newCell();
                try it.global.vars.append(it.alloc(), .{ .name = full, .cell = target.? });
            }
            const link = try it.newCell();
            link.v = .{ .link = target.? };
            try f.vars.append(it.alloc(), .{ .name = try it.alloc().dupe(u8, name), .cell = link });
            return target;
        }
        if (!create) return null;
        const cell = try it.newCell();
        try f.vars.append(it.alloc(), .{ .name = try it.alloc().dupe(u8, name), .cell = cell });
        return cell;
    }

    /// The global cell with exactly this full name, made when it is
    /// not there.
    pub fn globalVar(it: *Interp, full: []const u8) Allocator.Error!*Var {
        if (it.lookup(&it.global, full)) |c| return c;
        const cell = try it.newCell();
        try it.global.vars.append(it.alloc(), .{ .name = try it.alloc().dupe(u8, full), .cell = cell });
        return cell;
    }

    inline fn lookup(it: *Interp, f: *Frame, name: []const u8) ?*Var {
        const i = f.find(it.alloc(), name) orelse return null;
        return f.vars.items[i].cell.settle();
    }

    /// Makes `name` in the current frame a link to `target`.
    pub fn linkVar(it: *Interp, name: []const u8, target: *Var) Error!void {
        if (it.frame.find(it.alloc(), name)) |i| {
            const e = it.frame.vars.items[i];
            if (e.cell == target) return;
            if (e.cell.v == .link or e.cell.v == .undef) {
                e.cell.v = .{ .link = target };
                return;
            }
            return it.fail("variable \"{s}\" already exists", .{name});
        }
        const cell = try it.newCell();
        cell.v = .{ .link = target };
        try it.frame.vars.append(it.alloc(), .{ .name = try it.alloc().dupe(u8, name), .cell = cell });
    }

    /// Splits "a(i)" into the array name and the index.
    pub fn splitName(name: []const u8) struct { []const u8, ?[]const u8 } {
        if (name.len > 0 and name[name.len - 1] == ')') {
            if (std.mem.indexOfScalar(u8, name, '(')) |open| {
                return .{ name[0..open], name[open + 1 .. name.len - 1] };
            }
        }
        return .{ name, null };
    }

    pub fn readRef(it: *Interp, r: *const VarRef) Error!Value {
        if (r.index) |parts| {
            const idx = if (parts.len == 1 and parts[0] == .lit) parts[0].lit else try it.concatParts(parts);
            return it.getElem(r.name, idx);
        }
        if (it.slotCell(r.name, &@constCast(r).hint)) |c| {
            if (c.v == .val) return c.v.val;
        }
        const cell = try it.findVar(it.frame, r.name, false);
        if (cell) |c| switch (c.v) {
            .val => |v| return v,
            .arr => return it.fail("can't read \"{s}\": variable is array", .{r.name}),
            .traced => return trace.read(it, c, r.name, null),
            .elem => |e| return it.readElemLink(e, r.name),
            else => {},
        };
        return it.fail("can't read \"{s}\": no such variable", .{r.name});
    }

    fn getElem(it: *Interp, name: []const u8, idx: []const u8) Error!Value {
        const cell = try it.findVar(it.frame, name, false);
        if (cell) |c| switch (c.v) {
            .arr => |m| {
                if (m.get(idx)) |v| return v;
                return it.fail("can't read \"{s}({s})\": no such element in array", .{ name, idx });
            },
            .val => return it.fail("can't read \"{s}({s})\": variable isn't array", .{ name, idx }),
            .traced => return trace.read(it, c, name, idx),
            else => {},
        };
        return it.fail("can't read \"{s}({s})\": no such variable", .{ name, idx });
    }

    /// Reads a variable by its full name ("a" or "a(i)").
    pub fn getVar(it: *Interp, full: []const u8) Error!Value {
        const name, const idx = splitName(full);
        if (idx) |i| return it.getElem(name, i);
        const r: VarRef = .{ .name = name };
        return it.readRef(&r);
    }

    /// Reads a variable and runs no read trace.
    pub fn getVarPlain(it: *Interp, full: []const u8) Error!Value {
        const name, const idx = splitName(full);
        const cell = try it.findVar(it.frame, name, false);
        if (cell != null and cell.?.v == .traced) return trace.after(it, cell.?, name, idx);
        if (idx == null and cell != null and cell.?.v == .elem) {
            const e = cell.?.v.elem;
            if (e.array.v == .traced) return trace.after(it, e.array, e.name, e.index);
        }
        return it.getVar(full);
    }

    /// As `getVarOpt`, with no read trace.
    pub fn getVarQuiet(it: *Interp, full: []const u8) Error!?Value {
        const name, const idx = splitName(full);
        const cell = try it.findVar(it.frame, name, false) orelse return null;
        if (cell.v == .traced) {
            return switch (cell.v.traced.inner) {
                .val => |v| if (idx == null) v else null,
                .arr => |m| if (idx) |i| m.get(i) else null,
                .undef => null,
            };
        }
        if (idx == null and cell.v == .elem) return it.elemValue(cell.v.elem);
        return it.getVarOpt(full);
    }

    pub fn getVarOpt(it: *Interp, full: []const u8) Error!?Value {
        const name, const idx = splitName(full);
        const cell = try it.findVar(it.frame, name, false) orelse return null;
        if (idx == null and cell.v == .val) return cell.v.val;
        if (cell.v == .traced) return trace.readOpt(it, cell, name, idx);
        if (cell.v == .elem and idx == null) {
            const e = cell.v.elem;
            if (e.array.v == .traced) {
                it.trace_shown = name;
                defer it.trace_shown = null;
                return trace.readOpt(it, e.array, e.name, e.index);
            }
            return it.elemValue(e);
        }
        if (idx) |i| return if (cell.v == .arr) cell.v.arr.get(i) else null;
        return if (cell.v == .val) cell.v.val else null;
    }

    /// Writes a variable by its full name ("a" or "a(i)").
    pub fn setVar(it: *Interp, full: []const u8, v: Value) Error!void {
        const name, const idx = splitName(full);
        const cell = (try it.findVar(it.frame, name, true)).?;
        if (idx == null and cell.plainStore()) {
            cell.v = .{ .val = v };
            return;
        }
        if (cell.v == .traced) return trace.write(it, cell, name, idx, v);
        if (cell.v == .elem) {
            if (idx != null) return it.fail("can't set \"{s}\": variable isn't array", .{full});
            return it.writeElemLink(cell.v.elem, v, name);
        }
        if (idx) |i| {
            switch (cell.v) {
                .undef => {
                    const m = try it.alloc().create(ArrayMap);
                    m.* = .empty;
                    cell.v = .{ .arr = m };
                },
                .arr => {},
                else => return it.fail("can't set \"{s}\": variable isn't array", .{full}),
            }
            const gop = try cell.v.arr.getOrPut(it.alloc(), i);
            if (!gop.found_existing) gop.key_ptr.* = try it.alloc().dupe(u8, i);
            gop.value_ptr.* = v;
            return;
        }
        if (cell.v == .arr) return it.fail("can't set \"{s}\": variable is array", .{full});
        cell.v = .{ .val = v };
    }

    /// Removes a variable. Returns false when there is none.
    pub fn unsetVar(it: *Interp, full: []const u8) Error!bool {
        const name, const idx = splitName(full);
        const cell = try it.findVar(it.frame, name, false) orelse return false;
        if (cell.v == .traced) return trace.unset(it, cell, name, idx);
        if (cell.v == .elem) {
            const e = cell.v.elem;
            if (e.array.v == .traced) {
                it.trace_shown = name;
                defer it.trace_shown = null;
                return trace.unset(it, e.array, e.name, e.index);
            }
            return e.array.v == .arr and e.array.v.arr.orderedRemove(e.index);
        }
        if (idx) |i| {
            if (cell.v != .arr) return false;
            return cell.v.arr.orderedRemove(i);
        }
        if (cell.v == .undef) return false;
        cell.v = .undef;
        return true;
    }

    fn elemValue(it: *Interp, e: *ElemLink) Error!?Value {
        _ = it;
        return switch (e.array.v) {
            .arr => |m| m.get(e.index),
            .traced => |t| if (t.inner == .arr) t.inner.arr.get(e.index) else null,
            else => null,
        };
    }

    fn readElemLink(it: *Interp, e: *ElemLink, local: []const u8) Error!Value {
        if (e.array.v == .traced) {
            it.trace_shown = local;
            defer it.trace_shown = null;
            return trace.read(it, e.array, e.name, e.index);
        }
        if (e.array.v == .arr) {
            if (e.array.v.arr.get(e.index)) |v| return v;
            return it.fail("can't read \"{s}({s})\": no such element in array", .{ e.name, e.index });
        }
        return it.fail("can't read \"{s}({s})\": no such variable", .{ e.name, e.index });
    }

    fn writeElemLink(it: *Interp, e: *ElemLink, v: Value, local: []const u8) Error!void {
        const cell = e.array;
        if (cell.v == .traced) {
            it.trace_shown = local;
            defer it.trace_shown = null;
            return trace.write(it, cell, e.name, e.index, v);
        }
        if (cell.v == .undef) {
            const m = try it.alloc().create(ArrayMap);
            m.* = .empty;
            cell.v = .{ .arr = m };
        }
        if (cell.v != .arr) return it.fail("can't set \"{s}({s})\": variable isn't array", .{ e.name, e.index });
        const gop = try cell.v.arr.getOrPut(it.alloc(), e.index);
        if (!gop.found_existing) gop.key_ptr.* = try it.alloc().dupe(u8, e.index);
        gop.value_ptr.* = v;
    }

    /// Makes a cell that links to an element of an array.
    pub fn elemCell(it: *Interp, array: *Var, name: []const u8, index: []const u8) Allocator.Error!*Var {
        const e = try it.alloc().create(ElemLink);
        e.* = .{ .array = array, .name = try it.alloc().dupe(u8, name), .index = try it.alloc().dupe(u8, index) };
        const c = try it.newCell();
        c.v = .{ .elem = e };
        // The count also turns the inline stores off for element links.
        it.var_traces += 1;
        it.epoch += 1;
        return c;
    }

    /// The frame at a level word of `uplevel` and `upvar` ("1", "#0").
    /// Returns null when the word is not a level.
    pub fn frameAt(it: *Interp, spec: []const u8) Error!?*Frame {
        var target: u32 = undefined;
        if (spec.len > 0 and spec[0] == '#') {
            target = std.fmt.parseInt(u32, spec[1..], 10) catch return it.fail("bad level \"{s}\"", .{spec});
            if (target > it.frame.level) return it.fail("bad level \"{s}\"", .{spec});
        } else if (spec.len > 0 and std.ascii.isDigit(spec[0])) {
            const up = std.fmt.parseInt(u32, spec, 10) catch return it.fail("bad level \"{s}\"", .{spec});
            if (up > it.frame.level) return it.fail("bad level \"{s}\"", .{spec});
            target = it.frame.level - up;
        } else return null;
        var f = it.frame;
        while (f.level > target) f = f.parent.?;
        return f;
    }
};

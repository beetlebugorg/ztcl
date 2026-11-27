//! Regular expressions: `regexp`, `regsub`, and the `-regexp` options.
//!
//! The syntax is that of re_syntax.n: advanced (ARE), extended (ERE),
//! basic (BRE), and literal patterns, with the embedded options.
//!
//! A pattern parses to a tree. The tree compiles to a program for a
//! Thompson simulation, which finds the leftmost match and its longest
//! end (or its shortest end, when the first quantifier of the pattern
//! is non-greedy). Its time is the program size times the text length.
//! A second pass then splits the known span over the tree to find the
//! capture groups. Each part of a concatenation takes the longest (or
//! shortest) length that leaves a match for the rest. A pattern with a
//! back reference has no simulation and searches with the second pass
//! alone. The compute limit bounds each pass.
//!
//! Before the first match, a program with no assert and no lookahead
//! runs as a lazy DFA over the thread lists of the simulation. Each
//! transition keeps the ticks of its step, so the step count is that of
//! the simulation.
//!
//! Positions in the matcher count characters. `Matcher.caps` has byte
//! offsets, for the callers that slice the subject.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const ucd = @import("ucd.zig");
const cmds = @import("cmds.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

const inf = std.math.maxInt(u32);
const max_prog = 40000;
const max_memo = 1 << 20;
/// The most bits of the bit table of the failed spans. The count of
/// entries of the table stays under `max_memo`, so the table and the
/// hash map keep the same spans.
const max_memo_bits = 1 << 18;

pub const Syntax = enum { are, ere, bre, literal };

pub const Options = struct {
    nocase: bool = false,
    /// `.` and `[^x]` do not match a newline.
    linestop: bool = false,
    /// `^` and `$` also match at a newline.
    lineanchor: bool = false,
    expanded: bool = false,
    syntax: Syntax = .are,
    /// The text start is not a line start, or the text end not a line end.
    notbol: bool = false,
    noteol: bool = false,
    /// Tcl has no captures for this pattern (`REG_NOSUB`).
    nosub: bool = false,
};

/// The bits of `regex_info`, in the order of `re_info` in the Tcl tests.
pub const Info = struct {
    pub const backref: u16 = 1;
    pub const lookahead: u16 = 2;
    pub const bounds: u16 = 4;
    pub const braces: u16 = 8;
    pub const bsalnum: u16 = 16;
    pub const pbotch: u16 = 32;
    pub const bbs: u16 = 64;
    pub const nonposix: u16 = 128;
    pub const unspec: u16 = 256;
    pub const unport: u16 = 512;
    pub const locale: u16 = 1024;
    pub const emptymatch: u16 = 2048;
    pub const impossible: u16 = 4096;
    pub const shortest: u16 = 8192;
};

const Range = struct { lo: u21, hi: u21 };

const Class = enum(u4) { alpha, upper, lower, digit, xdigit, alnum, print, blank, space, punct, graph, cntrl };

fn classHas(cl: Class, c: u21) bool {
    return switch (cl) {
        .alpha => ucd.isAlpha(c),
        .upper => ucd.isUpper(c),
        .lower => ucd.isLower(c),
        .digit => ucd.isDigit(c),
        .xdigit => c < 128 and std.ascii.isHex(@intCast(c)),
        .alnum => ucd.isAlpha(c) or ucd.isDigit(c),
        .print => ucd.isPrint(c),
        .blank => c == ' ' or c == '\t' or c == 0xA0 or c == 0x3000 or (c >= 0x2000 and c <= 0x200A),
        .space => ucd.isSpace(c),
        .punct => ucd.isPunct(c),
        .graph => ucd.isGraph(c),
        .cntrl => ucd.isControl(c),
    };
}

const Set = struct {
    bits: [4]u64 = @splat(0),
    ranges: std.ArrayList(Range) = .empty,
    classes: u16 = 0,
    word: bool = false,
    negate: bool = false,
    no_nl: bool = false,
    nocase: bool = false,

    fn rawHas(s: *const Set, c: u21) bool {
        if (c < 256) return s.bits[c >> 6] & (@as(u64, 1) << @intCast(c & 63)) != 0;
        for (s.ranges.items) |r| if (c >= r.lo and c <= r.hi) return true;
        if (s.word and ucd.isWordChar(c)) return true;
        var m = s.classes;
        var i: u4 = 0;
        while (m != 0) : (i +%= 1) {
            if (m & 1 != 0 and classHas(@fromBackingInt(@intCast(i)), c)) return true;
            m >>= 1;
        }
        return false;
    }

    fn has(s: *const Set, c: u21) bool {
        if (s.no_nl and c == '\n') return false;
        var hit = s.rawHas(c);
        if (!hit and s.nocase) hit = s.rawHas(ucd.toLower(c)) or s.rawHas(ucd.toUpper(c));
        return hit != s.negate;
    }

    fn addRange(s: *Set, a: std.mem.Allocator, lo: u21, hi: u21) !void {
        var c = lo;
        while (c <= hi and c < 256) : (c += 1) s.bits[c >> 6] |= @as(u64, 1) << @intCast(c & 63);
        if (hi >= 256) try s.ranges.append(a, .{ .lo = @max(lo, 256), .hi = hi });
    }

    fn addClass(s: *Set, cl: Class) void {
        s.classes |= @as(u16, 1) << @backingInt(cl);
        for (0..256) |i| {
            if (classHas(cl, @intCast(i))) s.bits[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
        }
    }

    fn addWord(s: *Set) void {
        s.word = true;
        for (0..256) |i| {
            if (ucd.isWordChar(@intCast(i))) s.bits[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
        }
    }
};

const Assert = enum { bol, eol, line_bol, line_eol, text_start, text_end, word_start, word_end, word_b, not_word_b };

const Pref = enum { none, greedy, lazy };

const Node = struct {
    kind: union(enum) {
        empty,
        char: u21,
        set: *const Set,
        assert: Assert,
        look: struct { negate: bool, sub: *Node, start: u32 = 0 },
        group: struct { cap: ?u16, sub: *Node },
        cat: []const *Node,
        alt: []const *Node,
        repeat: struct { sub: *Node, min: u32, max: u32, greedy: bool },
        backref: u16,
    },
    id: u32 = 0,
    pref: Pref = .none,
    /// The capture groups inside the node: first and one past the last.
    cap_lo: u16 = 0,
    cap_hi: u16 = 0,
    /// The least and the most characters that the node can match.
    min_len: u32 = 0,
    max_len: u32 = inf,
};

/// Sets `min_len` and `max_len` of a node and of the nodes under it.
fn measure(n: *Node) void {
    switch (n.kind) {
        .empty, .assert => {
            n.min_len = 0;
            n.max_len = 0;
        },
        .look => |l| {
            measure(l.sub);
            n.min_len = 0;
            n.max_len = 0;
        },
        .char, .set => {
            n.min_len = 1;
            n.max_len = 1;
        },
        .backref => {
            n.min_len = 0;
            n.max_len = inf;
        },
        .group => |g| {
            measure(g.sub);
            n.min_len = g.sub.min_len;
            n.max_len = g.sub.max_len;
        },
        .cat => |items| {
            var lo: u32 = 0;
            var hi: u32 = 0;
            for (items) |x| {
                measure(x);
                lo +|= x.min_len;
                hi = if (hi == inf or x.max_len == inf) inf else hi +| x.max_len;
            }
            n.min_len = lo;
            n.max_len = hi;
        },
        .alt => |items| {
            var lo: u32 = inf;
            var hi: u32 = 0;
            for (items) |x| {
                measure(x);
                lo = @min(lo, x.min_len);
                hi = @max(hi, x.max_len);
            }
            n.min_len = lo;
            n.max_len = hi;
        },
        .repeat => |r| {
            measure(r.sub);
            n.min_len = r.sub.min_len *| r.min;
            n.max_len = if (r.max == inf) (if (r.sub.max_len == 0) 0 else inf) else if (r.sub.max_len == inf) inf else r.sub.max_len *| r.max;
        },
    }
}

const Inst = union(enum) {
    char: u21,
    set: *const Set,
    assert: Assert,
    /// A lookahead: the program at `start`, ended by `match`.
    look: struct { negate: bool, start: u32 },
    split: struct { first: u32, second: u32 },
    jmp: u32,
    match,
};

pub const Regex = struct {
    prog: []const Inst,
    root: *Node,
    ncap: usize,
    nodes: u32,
    opts: Options,
    shortest: bool,
    has_backref: bool,
    info: u16,
    /// The characters that can start a match, or null.
    start: ?*const Start = null,
    /// True when the program has no lookahead and only the asserts of
    /// the start and the end of the text, so the simulation can use a
    /// DFA (`Dfa`).
    dfa: bool = false,
    /// True when the program has an assert of the end of the text. Then
    /// the step on the last character has its own transitions.
    dfa_end: bool = false,
    /// True when the pattern can match the empty string (`canBeEmpty`).
    empty: bool = true,
    /// The states of the lazy DFA, made on the first search. They stay
    /// with the pattern, so each later search uses them again. A state
    /// depends on its thread list alone, and a transition keeps its
    /// ticks, so a search counts the same ticks with a new DFA and with
    /// a kept one.
    states: ?*Dfa = null,
};

/// True when no instruction of the program depends on the position,
/// other than the asserts of the start and the end of the text. After
/// the first position of a search, the asserts of the start are false,
/// and the asserts of the end are true only after the last character.
fn dfaOk(prog: []const Inst) bool {
    for (prog) |i| switch (i) {
        .assert => |a| switch (a) {
            .bol, .eol, .text_start, .text_end => {},
            else => return false,
        },
        .look => return false,
        else => {},
    };
    return true;
}

/// True when the program has an assert of the end of the text.
fn hasEndAssert(prog: []const Inst) bool {
    for (prog) |i| switch (i) {
        .assert => |a| if (a == .eol or a == .text_end) return true,
        else => {},
    };
    return false;
}

/// The first step of a match. The threads from instruction 0 do not
/// depend on the position: no assert, no lookahead, and no empty match.
/// So a position whose character no first thread accepts adds the same
/// work at each place, and the simulation skips it.
const Start = struct {
    /// The characters below 256 that a first thread accepts.
    bytes: [256]bool,
    /// True when a first thread can accept a character above 255.
    high: bool,
    /// The ticks of one skipped position: one for each instruction of
    /// the closure of instruction 0, and one for the step of each
    /// thread.
    cost: u32,
};

/// The `Start` of a program, or null when the first threads depend on
/// the position or can match the empty string.
fn startOf(a: std.mem.Allocator, prog: []const Inst) std.mem.Allocator.Error!?*const Start {
    const seen = try a.alloc(bool, prog.len);
    @memset(seen, false);
    var work: std.ArrayList(u32) = .empty;
    try work.append(a, 0);
    var st: Start = .{ .bytes = @splat(false), .high = false, .cost = 0 };
    while (work.pop()) |pc| {
        if (seen[pc]) continue;
        seen[pc] = true;
        st.cost += 1;
        switch (prog[pc]) {
            .jmp => |t| try work.append(a, t),
            .split => |sp| {
                try work.append(a, sp.second);
                try work.append(a, sp.first);
            },
            .assert, .look, .match => return null,
            .char => |c| {
                st.cost += 1;
                if (c < 256) st.bytes[c] = true else st.high = true;
            },
            .set => |set| {
                st.cost += 1;
                st.high = true;
                for (&st.bytes, 0..) |*b, c| {
                    if (set.has(@intCast(c))) b.* = true;
                }
            },
        }
    }
    const out = try a.create(Start);
    out.* = st;
    return out;
}

const Fault = struct {
    const paren = "REG_EPAREN";
    const brace = "REG_EBRACE";
    const brack = "REG_EBRACK";
    const badrpt = "REG_BADRPT";
    const badbr = "REG_BADBR";
    const escape = "REG_EESCAPE";
    const subreg = "REG_ESUBREG";
    const range = "REG_ERANGE";
    const ctype = "REG_ECTYPE";
    const collate = "REG_ECOLLATE";
    const badopt = "REG_BADOPT";
    const toobig = "REG_ETOOBIG";
    const badpat = "REG_BADPAT";
};

fn faultText(code: []const u8) []const u8 {
    const eql_ = std.mem.eql;
    if (eql_(u8, code, Fault.paren)) return "parentheses () not balanced";
    if (eql_(u8, code, Fault.brace)) return "braces {} not balanced";
    if (eql_(u8, code, Fault.brack)) return "brackets [] not balanced";
    if (eql_(u8, code, Fault.badrpt)) return "quantifier operand invalid";
    if (eql_(u8, code, Fault.badbr)) return "invalid repetition count(s)";
    if (eql_(u8, code, Fault.escape)) return "invalid escape \\ sequence";
    if (eql_(u8, code, Fault.subreg)) return "invalid backreference number";
    if (eql_(u8, code, Fault.range)) return "invalid character range";
    if (eql_(u8, code, Fault.ctype)) return "invalid character class";
    if (eql_(u8, code, Fault.collate)) return "invalid collating element";
    if (eql_(u8, code, Fault.badopt)) return "invalid embedded option";
    if (eql_(u8, code, Fault.toobig)) return "regular expression is too big";
    return "invalid regular expression";
}

const Parser = struct {
    it: *Interp,
    src: []const u21,
    pos: usize = 0,
    opts: Options,
    ncap: u16 = 1,
    /// A capture group is closed when its bit is set.
    closed: std.StaticBitSet(1024) = .empty,
    nodes: u32 = 0,
    depth: u32 = 0,
    info: u16 = 0,
    has_backref: bool = false,

    fn fail(p: *Parser, code: []const u8) Error {
        const a = p.it.alloc();
        const text = faultText(code);
        p.it.result = .{ .str = try std.fmt.allocPrint(a, "couldn't compile regular expression pattern: {s}", .{text}) };
        p.it.error_code = try value.newList(a, &.{ .{ .str = "REGEXP" }, .{ .str = code }, .{ .str = text } });
        return error.TclError;
    }

    fn node(p: *Parser, n: Node) Error!*Node {
        const out = try p.it.alloc().create(Node);
        out.* = n;
        out.id = p.nodes;
        p.nodes += 1;
        if (p.nodes > max_prog) return p.fail(Fault.toobig);
        return out;
    }

    fn more(p: *const Parser) bool {
        return p.pos < p.src.len;
    }

    fn peek(p: *const Parser) u21 {
        return p.src[p.pos];
    }

    fn at(p: *const Parser, k: usize) ?u21 {
        return if (p.pos + k < p.src.len) p.src[p.pos + k] else null;
    }

    fn are(p: *const Parser) bool {
        return p.opts.syntax == .are;
    }

    fn bre(p: *const Parser) bool {
        return p.opts.syntax == .bre;
    }

    /// Skips white space and comments in expanded mode.
    fn skip(p: *Parser) void {
        if (!p.opts.expanded) return;
        while (p.more()) {
            const c = p.peek();
            if (c == ' ' or (c >= 9 and c <= 13)) {
                p.pos += 1;
            } else if (c == '#') {
                while (p.more() and p.peek() != '\n') p.pos += 1;
            } else break;
        }
    }

    fn charNode(p: *Parser, c: u21) Error!*Node {
        if (p.opts.nocase and (ucd.toLower(c) != c or ucd.toUpper(c) != c)) {
            const a = p.it.alloc();
            const s = try a.create(Set);
            s.* = .{};
            try s.addRange(a, c, c);
            try s.addRange(a, ucd.toLower(c), ucd.toLower(c));
            try s.addRange(a, ucd.toUpper(c), ucd.toUpper(c));
            return p.node(.{ .kind = .{ .set = s } });
        }
        return p.node(.{ .kind = .{ .char = c } });
    }

    fn atClose(p: *const Parser, depth_open: bool) bool {
        if (!p.more()) return true;
        if (p.bre()) return p.peek() == '\\' and p.at(1) == ')';
        if (p.peek() == ')') return depth_open or p.opts.syntax != .ere;
        return p.peek() == '|';
    }

    fn parseAlt(p: *Parser, depth_open: bool) Error!*Node {
        if (p.depth > 100) return p.fail(Fault.toobig);
        p.depth += 1;
        defer p.depth -= 1;
        const first_cap = p.ncap;
        var alts: std.ArrayList(*Node) = .empty;
        while (true) {
            try alts.append(p.it.alloc(), try p.parseBranch(depth_open));
            if (!p.bre() and p.more() and p.peek() == '|') {
                p.pos += 1;
            } else break;
        }
        if (alts.items.len == 1) return alts.items[0];
        const n = try p.node(.{ .kind = .{ .alt = alts.items }, .pref = .greedy });
        n.cap_lo = first_cap;
        n.cap_hi = p.ncap;
        return n;
    }

    fn parseBranch(p: *Parser, depth_open: bool) Error!*Node {
        const first_cap = p.ncap;
        var items: std.ArrayList(*Node) = .empty;
        var pref: Pref = .none;
        var first = true;
        while (true) {
            p.skip();
            if (p.atClose(depth_open)) break;
            var a = try p.parseAtom(first, depth_open);
            // In a BRE, a `*` after a leading `^` is a plain character.
            first = p.bre() and first and a.kind == .assert;
            p.skip();
            a = try p.quantify(a);
            if (pref == .none) pref = a.pref;
            try items.append(p.it.alloc(), a);
        }
        if (items.items.len == 0) {
            if (!p.bre() and p.more() and p.peek() == '|' and p.opts.syntax == .ere) return p.fail(Fault.badpat);
            if (p.opts.syntax == .ere and (!p.more() or p.peek() == ')')) return p.fail(Fault.badpat);
            p.info |= Info.unspec;
            return p.node(.{ .kind = .empty });
        }
        if (items.items.len == 1) return items.items[0];
        const n = try p.node(.{ .kind = .{ .cat = items.items }, .pref = pref });
        n.cap_lo = first_cap;
        n.cap_hi = p.ncap;
        return n;
    }

    fn number(p: *Parser) ?u32 {
        if (!p.more() or p.peek() < '0' or p.peek() > '9') return null;
        var n: u32 = 0;
        while (p.more() and p.peek() >= '0' and p.peek() <= '9') : (p.pos += 1) n = n *| 10 +| (p.peek() - '0');
        return n;
    }

    fn quantify(p: *Parser, atom: *Node) Error!*Node {
        if (!p.more()) return atom;
        const q = p.peek();
        var min: u32 = 0;
        var max: u32 = inf;
        var is_bound = false;
        if (p.bre()) {
            if (q == '*') {
                p.pos += 1;
            } else if (q == '\\' and p.at(1) == '{') {
                p.pos += 2;
                is_bound = true;
                min = p.number() orelse return p.fail(Fault.badbr);
                max = min;
                if (p.more() and p.peek() == ',') {
                    p.pos += 1;
                    max = p.number() orelse inf;
                }
                if (!p.more()) return p.fail(Fault.brace);
                if (!(p.peek() == '\\' and p.at(1) == '}')) return p.fail(Fault.badbr);
                p.pos += 2;
            } else return atom;
        } else if (q == '*') {
            p.pos += 1;
        } else if (q == '+') {
            min = 1;
            p.pos += 1;
        } else if (q == '?') {
            max = 1;
            p.pos += 1;
        } else if (q == '{' and p.at(1) != null and p.at(1).? >= '0' and p.at(1).? <= '9') {
            p.pos += 1;
            is_bound = true;
            min = p.number().?;
            max = min;
            if (p.more() and p.peek() == ',') {
                p.pos += 1;
                max = p.number() orelse inf;
            }
            if (!p.more()) return p.fail(Fault.brace);
            if (p.peek() != '}') return p.fail(Fault.badbr);
            p.pos += 1;
        } else return atom;
        if (is_bound) {
            p.info |= Info.bounds;
            if (min > 255 or (max != inf and (max > 255 or max < min))) return p.fail(Fault.badbr);
        }
        var greedy = true;
        if (p.are() and p.more() and p.peek() == '?') {
            greedy = false;
            p.pos += 1;
            p.info |= Info.nonposix;
        }
        if (atom.kind == .assert or atom.kind == .look) return p.fail(Fault.badrpt);
        p.skip();
        if (p.more() and !p.bre()) {
            const c = p.peek();
            if (c == '*' or c == '+' or c == '?' or (c == '{' and p.at(1) != null and p.at(1).? >= '0' and p.at(1).? <= '9')) return p.fail(Fault.badrpt);
        }
        // A fixed count keeps the preference of the atom.
        const fixed = min == max;
        const pref: Pref = if (fixed) atom.pref else if (greedy) .greedy else .lazy;
        const n = try p.node(.{ .kind = .{ .repeat = .{ .sub = atom, .min = min, .max = max, .greedy = greedy } }, .pref = pref });
        n.cap_lo = atom.cap_lo;
        n.cap_hi = atom.cap_hi;
        return n;
    }

    fn classNode(p: *Parser, which: u8) Error!*Node {
        const a = p.it.alloc();
        const s = try a.create(Set);
        s.* = .{};
        switch (which | 32) {
            'd' => s.addClass(.digit),
            's' => s.addClass(.space),
            else => s.addWord(),
        }
        if (which < 'a') {
            s.negate = true;
            s.no_nl = p.opts.linestop;
        }
        return p.node(.{ .kind = .{ .set = s } });
    }

    fn anyNode(p: *Parser) Error!*Node {
        const a = p.it.alloc();
        const s = try a.create(Set);
        s.* = .{ .negate = true, .no_nl = p.opts.linestop };
        return p.node(.{ .kind = .{ .set = s } });
    }

    fn assertNode(p: *Parser, as: Assert) Error!*Node {
        return p.node(.{ .kind = .{ .assert = as } });
    }

    fn parseGroup(p: *Parser, cap: ?u16) Error!*Node {
        const sub = try p.parseAlt(true);
        if (p.bre()) {
            if (!(p.more() and p.peek() == '\\' and p.at(1) == ')')) return p.fail(Fault.paren);
            p.pos += 2;
        } else {
            if (!p.more() or p.peek() != ')') return p.fail(Fault.paren);
            p.pos += 1;
        }
        if (cap) |k| {
            if (k < 1024) p.closed.set(k);
        }
        const n = try p.node(.{ .kind = .{ .group = .{ .cap = cap, .sub = sub } }, .pref = sub.pref });
        n.cap_lo = if (cap) |k| k else sub.cap_lo;
        n.cap_hi = p.ncap;
        return n;
    }

    fn parseAtom(p: *Parser, first: bool, depth_open: bool) Error!*Node {
        const c = p.peek();
        if (p.opts.syntax == .bre) return p.parseBreAtom(c, first);
        p.pos += 1;
        switch (c) {
            '(' => {
                if (p.are() and p.more() and p.peek() == '?') {
                    const k = p.at(1) orelse return p.fail(Fault.badrpt);
                    if (k == ':') {
                        p.pos += 2;
                        p.info |= Info.nonposix;
                        return p.parseGroup(null);
                    }
                    if (k == '=' or k == '!') {
                        p.pos += 2;
                        p.info |= Info.lookahead | Info.nonposix;
                        const saved = p.ncap;
                        const sub = try p.parseAlt(true);
                        if (!p.more() or p.peek() != ')') return p.fail(Fault.paren);
                        p.pos += 1;
                        // A group in a lookahead has no capture.
                        _ = saved;
                        return p.node(.{ .kind = .{ .look = .{ .negate = k == '!', .sub = sub } } });
                    }
                    return p.fail(Fault.badrpt);
                }
                const cap = if (p.opts.nosub) null else blk: {
                    const k = p.ncap;
                    p.ncap += 1;
                    break :blk @as(?u16, k);
                };
                return p.parseGroup(cap);
            },
            '*', '+', '?' => return p.fail(Fault.badrpt),
            '{' => {
                if (p.more() and p.peek() >= '0' and p.peek() <= '9') return p.fail(Fault.badrpt);
                p.info |= Info.braces | Info.unspec;
                return p.charNode('{');
            },
            '.' => return p.anyNode(),
            '^' => return p.assertNode(if (p.opts.lineanchor) .line_bol else .bol),
            '$' => return p.assertNode(if (p.opts.lineanchor) .line_eol else .eol),
            '[' => return p.parseBracket(),
            '\\' => return p.parseEscape(),
            ')' => {
                if (p.opts.syntax == .ere and !depth_open) {
                    p.info |= Info.pbotch;
                    return p.charNode(')');
                }
                return p.fail(Fault.paren);
            },
            else => return p.charNode(c),
        }
    }

    fn parseBreAtom(p: *Parser, c: u21, first: bool) Error!*Node {
        p.pos += 1;
        switch (c) {
            '*' => {
                if (first) return p.charNode('*');
                return p.fail(Fault.badrpt);
            },
            '.' => return p.anyNode(),
            '[' => return p.parseBracket(),
            '^' => {
                if (first) {
                    if (p.depth > 1) p.info |= Info.unspec;
                    return p.assertNode(if (p.opts.lineanchor) .line_bol else .bol);
                }
                return p.charNode('^');
            },
            '$' => {
                if (!p.more() or (p.peek() == '\\' and p.at(1) == ')')) {
                    if (p.more()) p.info |= Info.unspec;
                    return p.assertNode(if (p.opts.lineanchor) .line_eol else .eol);
                }
                return p.charNode('$');
            },
            '\\' => {
                if (!p.more()) return p.fail(Fault.escape);
                const e = p.peek();
                p.pos += 1;
                switch (e) {
                    '(' => {
                        const cap = if (p.opts.nosub) null else blk: {
                            const k = p.ncap;
                            p.ncap += 1;
                            break :blk @as(?u16, k);
                        };
                        return p.parseGroup(cap);
                    },
                    ')' => return p.fail(Fault.paren),
                    '{' => return p.fail(Fault.badrpt),
                    '<', '>' => {
                        p.info |= Info.nonposix | Info.locale;
                        return p.assertNode(if (e == '<') .word_start else .word_end);
                    },
                    '1'...'9' => return p.backref(e - '0'),
                    else => {
                        if (e < 128 and std.ascii.isAlphanumeric(@intCast(e))) p.info |= Info.bsalnum | Info.unspec;
                        return p.charNode(e);
                    },
                }
            },
            else => return p.charNode(c),
        }
    }

    fn backref(p: *Parser, k: u32) Error!*Node {
        if (k >= p.ncap or k >= 1024 or !p.closed.isSet(k)) return p.fail(Fault.subreg);
        p.has_backref = true;
        p.info |= Info.backref;
        return p.node(.{ .kind = .{ .backref = @intCast(k) } });
    }

    fn hexDigits(p: *Parser, maxn: usize) ?u32 {
        var n: u32 = 0;
        var k: usize = 0;
        while (k < maxn and p.more()) : (k += 1) {
            const c = p.peek();
            if (c >= 128 or !std.ascii.isHex(@intCast(c))) break;
            n = n *% 16 +% (std.fmt.charToDigit(@intCast(c), 16) catch 0);
            p.pos += 1;
        }
        return if (k == 0) null else n;
    }

    /// The character of a character escape, or null.
    fn charEscape(p: *Parser, e: u21) Error!?u21 {
        switch (e) {
            'a' => return 7,
            'b' => return 8,
            'B' => return '\\',
            'e' => return 27,
            'f' => return 12,
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'v' => return 11,
            'c' => {
                if (!p.more()) return p.fail(Fault.escape);
                const x = p.peek();
                p.pos += 1;
                return x & 31;
            },
            'u' => {
                const n = p.hexDigits(4) orelse return p.fail(Fault.escape);
                return @intCast(n);
            },
            'U' => {
                const n = p.hexDigits(8) orelse return p.fail(Fault.escape);
                if (n > 0x10FFFF) return 0xFFFD;
                return @intCast(n);
            },
            'x' => {
                // All hex digits count, and the last two give the value.
                var n: u32 = 0;
                var k: usize = 0;
                while (p.more() and p.peek() < 128 and std.ascii.isHex(@intCast(p.peek()))) : (k += 1) {
                    n = (n *% 16 +% (std.fmt.charToDigit(@intCast(p.peek()), 16) catch 0)) & 0xFFFF;
                    p.pos += 1;
                }
                if (k == 0) return p.fail(Fault.escape);
                return @intCast(n);
            },
            '0' => {
                var n: u32 = 0;
                var k: usize = 0;
                while (k < 2 and p.more() and p.peek() >= '0' and p.peek() <= '7') : (k += 1) {
                    n = n * 8 + (p.peek() - '0');
                    p.pos += 1;
                }
                return @intCast(n);
            },
            else => return null,
        }
    }

    fn parseEscape(p: *Parser) Error!*Node {
        if (!p.more()) return p.fail(Fault.escape);
        const e = p.peek();
        p.pos += 1;
        if (p.opts.syntax == .ere) {
            if (e < 128 and std.ascii.isAlphanumeric(@intCast(e))) p.info |= Info.bsalnum | Info.unspec;
            return p.charNode(e);
        }
        if (e < 128 and std.ascii.isAlphanumeric(@intCast(e))) p.info |= Info.nonposix;
        switch (e) {
            'd', 'D', 's', 'S', 'w', 'W' => {
                p.info |= Info.locale;
                return p.classNode(@intCast(e));
            },
            'A' => return p.assertNode(.text_start),
            'Z' => return p.assertNode(.text_end),
            'm', 'M', 'y', 'Y' => {
                p.info |= Info.locale;
                return p.assertNode(switch (e) {
                    'm' => .word_start,
                    'M' => .word_end,
                    'y' => .word_b,
                    else => .not_word_b,
                });
            },
            '1'...'9' => {
                // More digits are a back reference when a group has that
                // number, and otherwise an octal value.
                var k: usize = p.pos;
                var n: u32 = e - '0';
                while (k < p.src.len and p.src[k] >= '0' and p.src[k] <= '9') : (k += 1) n = n *| 10 +| (p.src[k] - '0');
                if (k == p.pos or n < p.ncap) {
                    p.pos = k;
                    return p.backref(n);
                }
                p.info |= Info.unport;
                var o: u32 = e - '0';
                if (e > '7') return p.fail(Fault.subreg);
                var used: usize = 0;
                while (used < 2 and p.more() and p.peek() >= '0' and p.peek() <= '7') : (used += 1) {
                    o = o * 8 + (p.peek() - '0');
                    p.pos += 1;
                }
                return p.charNode(@intCast(o));
            },
            else => {},
        }
        if (e == 'c' or e == 'x' or e == '0') p.info |= Info.unport;
        if (e == 'e') p.info |= Info.unport | Info.locale;
        if (try p.charEscape(e)) |c| return p.charNode(c);
        if (e < 128 and std.ascii.isAlphanumeric(@intCast(e))) return p.fail(Fault.escape);
        return p.charNode(e);
    }

    /// One character of a bracket, or a collating element.
    fn bracketChar(p: *Parser) Error!u21 {
        if (!p.more()) return p.fail(Fault.brack);
        var c = p.peek();
        p.pos += 1;
        if (c == '[' and p.more() and (p.peek() == '.' or p.peek() == '=')) {
            const kind = p.peek();
            p.pos += 1;
            const start = p.pos;
            while (p.pos + 1 < p.src.len and !(p.src[p.pos] == kind and p.src[p.pos + 1] == ']')) p.pos += 1;
            if (p.pos + 1 >= p.src.len) return p.fail(Fault.brack);
            const name = p.src[start..p.pos];
            p.pos += 2;
            if (name.len == 0) return p.fail(Fault.collate);
            if (name.len == 1) return name[0];
            return collateName(name) orelse p.fail(Fault.collate);
        }
        if (c == '\\') p.info |= Info.bbs;
        if (c == '\\' and p.are()) {
            if (!p.more()) return p.fail(Fault.brack);
            const e = p.peek();
            p.pos += 1;
            p.info |= Info.nonposix;
            if (e == 'x' or e == 'c' or e == '0') p.info |= Info.unport;
            if (try p.charEscape(e)) |x| return x;
            if (e < 128 and std.ascii.isAlphanumeric(@intCast(e))) return p.fail(Fault.escape);
            c = e;
        }
        return c;
    }

    fn parseBracket(p: *Parser) Error!*Node {
        const a = p.it.alloc();
        // [[:<:]] and [[:>:]] are the word boundaries.
        if (p.pos + 5 < p.src.len + 1 and p.pos + 4 < p.src.len and p.src[p.pos] == '[' and p.src[p.pos + 1] == ':' and (p.src[p.pos + 2] == '<' or p.src[p.pos + 2] == '>') and p.src[p.pos + 3] == ':' and p.src[p.pos + 4] == ']' and p.pos + 5 < p.src.len and p.src[p.pos + 5] == ']') {
            const start = p.src[p.pos + 2] == '<';
            p.pos += 6;
            p.info |= Info.nonposix;
            return p.assertNode(if (start) .word_start else .word_end);
        }
        const s = try a.create(Set);
        s.* = .{ .nocase = p.opts.nocase };
        if (p.more() and p.peek() == '^') {
            s.negate = true;
            s.no_nl = p.opts.linestop;
            p.pos += 1;
        }
        var first = true;
        while (true) : (first = false) {
            if (!p.more()) return p.fail(Fault.brack);
            const c = p.peek();
            if (c == ']' and !first) {
                p.pos += 1;
                break;
            }
            if (c == '[' and p.at(1) == ':') {
                var k = p.pos + 2;
                while (k + 1 < p.src.len and !(p.src[k] == ':' and p.src[k + 1] == ']')) k += 1;
                if (k + 1 >= p.src.len) return p.fail(Fault.brack);
                var buf: [16]u8 = undefined;
                const name = p.src[p.pos + 2 .. k];
                if (name.len >= buf.len) return p.fail(Fault.ctype);
                for (name, 0..) |x, i| buf[i] = if (x < 128) @intCast(x) else '?';
                const cl = std.meta.stringToEnum(Class, buf[0..name.len]) orelse return p.fail(Fault.ctype);
                s.addClass(cl);
                p.pos = k + 2;
                continue;
            }
            if (c == '\\' and p.are() and p.at(1) != null) {
                const e = p.at(1).?;
                if (e == 'd' or e == 's' or e == 'w') {
                    p.info |= Info.bbs | Info.nonposix | Info.locale;
                    p.pos += 2;
                    switch (e) {
                        'd' => s.addClass(.digit),
                        's' => s.addClass(.space),
                        else => s.addWord(),
                    }
                    continue;
                }
                if (e == 'D' or e == 'S' or e == 'W') return p.fail(Fault.range);
            }
            const lo = try p.bracketChar();
            var hi = lo;
            if (p.more() and p.peek() == '-' and p.at(1) != null and p.at(1).? != ']') {
                p.pos += 1;
                hi = try p.bracketChar();
                if (hi < lo) return p.fail(Fault.range);
            }
            try s.addRange(a, lo, hi);
        }
        return p.node(.{ .kind = .{ .set = s } });
    }
};

/// The names of collating elements of the POSIX locale that patterns use.
fn collateName(name: []const u21) ?u21 {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, 0..) |x, i| {
        if (x >= 128) return null;
        buf[i] = @intCast(x);
    }
    const table = [_]struct { []const u8, u21 }{
        .{ "NUL", 0 },                   .{ "tab", 9 },                    .{ "newline", 10 },     .{ "space", ' ' },
        .{ "hyphen", '-' },              .{ "hyphen-minus", '-' },         .{ "period", '.' },     .{ "full-stop", '.' },
        .{ "slash", '/' },               .{ "solidus", '/' },              .{ "comma", ',' },      .{ "colon", ':' },
        .{ "semicolon", ';' },           .{ "equals-sign", '=' },          .{ "asterisk", '*' },   .{ "plus-sign", '+' },
        .{ "left-square-bracket", '[' }, .{ "right-square-bracket", ']' }, .{ "backslash", '\\' }, .{ "circumflex", '^' },
        .{ "underscore", '_' },          .{ "tilde", '~' },
    };
    for (table) |t| if (std.mem.eql(u8, t[0], buf[0..name.len])) return t[1];
    return null;
}

// ---- The program ----

const Emitter = struct {
    p: *Parser,
    prog: std.ArrayList(Inst) = .empty,

    fn add(e: *Emitter, i: Inst) Error!u32 {
        if (e.prog.items.len >= max_prog) return e.p.fail(Fault.toobig);
        try e.prog.append(e.p.it.alloc(), i);
        return @intCast(e.prog.items.len - 1);
    }

    fn here(e: *const Emitter) u32 {
        return @intCast(e.prog.items.len);
    }

    fn emit(e: *Emitter, n: *Node) Error!void {
        switch (n.kind) {
            .empty, .backref => {},
            .char => |c| _ = try e.add(.{ .char = c }),
            .set => |s| _ = try e.add(.{ .set = s }),
            .assert => |a| _ = try e.add(.{ .assert = a }),
            .look => |l| {
                const at = try e.add(.{ .look = .{ .negate = l.negate, .start = 0 } });
                const over = try e.add(.{ .jmp = 0 });
                e.prog.items[at].look.start = e.here();
                n.kind.look.start = e.here();
                try e.emit(l.sub);
                _ = try e.add(.match);
                e.prog.items[over].jmp = e.here();
            },
            .group => |g| try e.emit(g.sub),
            .cat => |items| for (items) |x| try e.emit(x),
            .alt => |alts| {
                var jumps: std.ArrayList(u32) = .empty;
                for (alts, 0..) |x, i| {
                    if (i + 1 < alts.len) {
                        const sp = try e.add(.{ .split = .{ .first = 0, .second = 0 } });
                        try e.emit(x);
                        try jumps.append(e.p.it.alloc(), try e.add(.{ .jmp = 0 }));
                        e.prog.items[sp].split = .{ .first = sp + 1, .second = e.here() };
                    } else try e.emit(x);
                }
                for (jumps.items) |j| e.prog.items[j].jmp = e.here();
            },
            .repeat => |r| {
                for (0..r.min) |_| try e.emit(r.sub);
                if (r.max == inf) {
                    const sp = try e.add(.{ .split = .{ .first = 0, .second = 0 } });
                    try e.emit(r.sub);
                    _ = try e.add(.{ .jmp = sp });
                    e.prog.items[sp].split = .{ .first = sp + 1, .second = e.here() };
                } else {
                    var splits: std.ArrayList(u32) = .empty;
                    for (r.min..r.max) |_| {
                        try splits.append(e.p.it.alloc(), try e.add(.{ .split = .{ .first = 0, .second = 0 } }));
                        try e.emit(r.sub);
                    }
                    for (splits.items) |sp| e.prog.items[sp].split = .{ .first = sp + 1, .second = e.here() };
                }
            },
        }
    }
};

/// True when two neighbors of a concatenation can never both match:
/// a text start after a character, a text end before one, or a word
/// boundary next to a character that rules it out.
fn impossible(n: *const Node, opts: Options) bool {
    const items = switch (n.kind) {
        .cat => |x| x,
        .group => |g| return impossible(g.sub, opts),
        else => return false,
    };
    var k: usize = 0;
    while (k + 1 < items.len) : (k += 1) {
        const x = items[k];
        const y = items[k + 1];
        const x_char = x.kind == .char or x.kind == .set;
        const y_char = y.kind == .char or y.kind == .set;
        if (x_char and y.kind == .assert) {
            if (y.kind.assert == .bol or y.kind.assert == .text_start) return true;
            if (y.kind.assert == .word_start and x.kind == .char and ucd.isWordChar(x.kind.char)) return true;
        }
        if (y_char and x.kind == .assert) {
            if (x.kind.assert == .eol or x.kind.assert == .text_end) return true;
            if (x.kind.assert == .word_end and y.kind == .char and ucd.isWordChar(y.kind.char)) return true;
        }
    }
    return false;
}

fn canBeEmpty(n: *const Node) bool {
    return switch (n.kind) {
        .empty, .assert, .look, .backref => true,
        .char, .set => false,
        .group => |g| canBeEmpty(g.sub),
        .cat => |items| for (items) |x| {
            if (!canBeEmpty(x)) break false;
        } else true,
        .alt => |items| for (items) |x| {
            if (canBeEmpty(x)) break true;
        } else false,
        .repeat => |r| r.min == 0 or canBeEmpty(r.sub),
    };
}

/// One entry of the cache of compiled patterns.
pub const CacheEntry = struct {
    pat: []const u8 = "",
    opts: Options = .{},
    re: ?*Regex = null,
};

pub const cache_size = 64;

/// The compiled form of a pattern. A cache with one place for each hash
/// keeps the last patterns, so a loop does not compile its pattern again.
pub fn compile(it: *Interp, pat: []const u8, opts: Options) Error!*Regex {
    const slot = &it.regex_cache[@intCast(std.hash.Wyhash.hash(0, pat) % cache_size)];
    if (slot.re) |re| {
        if (std.meta.eql(slot.opts, opts) and std.mem.eql(u8, slot.pat, pat)) return re;
    }
    const re = try compileNew(it, pat, opts);
    slot.* = .{ .pat = try it.alloc().dupe(u8, pat), .opts = opts, .re = re };
    return re;
}

fn decodeAll(it: *Interp, s: []const u8) Error![]u21 {
    var out: std.ArrayList(u21) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const d = ucd.next(s, i);
        try out.append(it.alloc(), d.cp);
        i += d.len;
    }
    return out.items;
}

/// Reads the director and the embedded options at the start.
fn readDirector(p: *Parser) Error!void {
    const src = p.src;
    if (p.opts.syntax == .are and src.len >= 4 and src[0] == '*' and src[1] == '*' and src[2] == '*') {
        if (src[3] == '=') {
            p.opts.syntax = .literal;
            p.pos = 4;
            return;
        }
        if (src[3] != ':') return p.fail(Fault.badrpt);
        p.pos = 4;
    } else if (p.opts.syntax == .are and src.len >= 3 and src[0] == '*' and src[1] == '*' and src[2] == '*') {
        return p.fail(Fault.badrpt);
    }
    if (p.pos > 0) p.info |= Info.nonposix;
    if (p.opts.syntax != .are) return;
    if (p.pos + 2 < src.len and src[p.pos] == '(' and src[p.pos + 1] == '?' and src[p.pos + 2] < 128 and std.ascii.isAlphabetic(@intCast(src[p.pos + 2]))) {
        var k = p.pos + 2;
        while (k < src.len and src[k] != ')') : (k += 1) {
            switch (src[k]) {
                'b' => p.opts.syntax = .bre,
                'e' => p.opts.syntax = .ere,
                'q' => p.opts.syntax = .literal,
                'c' => p.opts.nocase = false,
                'i' => p.opts.nocase = true,
                'x' => p.opts.expanded = true,
                't' => p.opts.expanded = false,
                'n', 'm' => {
                    p.opts.linestop = true;
                    p.opts.lineanchor = true;
                },
                'p' => {
                    p.opts.linestop = true;
                    p.opts.lineanchor = false;
                },
                'w' => {
                    p.opts.linestop = false;
                    p.opts.lineanchor = true;
                },
                's' => {
                    p.opts.linestop = false;
                    p.opts.lineanchor = false;
                },
                else => return p.fail(Fault.badopt),
            }
        }
        if (k >= src.len) return p.fail(Fault.badopt);
        p.info |= Info.nonposix;
        p.pos = k + 1;
    }
}

fn compileNew(it: *Interp, pat: []const u8, opts: Options) Error!*Regex {
    const src = try decodeAll(it, pat);
    var p: Parser = .{ .it = it, .src = src, .opts = opts };
    try readDirector(&p);
    var root: *Node = undefined;
    if (p.opts.syntax == .literal) {
        var items: std.ArrayList(*Node) = .empty;
        while (p.more()) : (p.pos += 1) try items.append(it.alloc(), try p.charNode(p.peek()));
        root = try p.node(.{ .kind = .{ .cat = items.items } });
        if (items.items.len == 0) root.kind = .empty;
    } else {
        root = try p.parseAlt(false);
        if (p.more()) return p.fail(Fault.paren);
    }
    measure(root);
    var e: Emitter = .{ .p = &p };
    try e.emit(root);
    _ = try e.add(.match);
    var info = p.info;
    if (p.opts.expanded) info |= Info.nonposix;
    if (impossible(root, p.opts)) info |= Info.impossible;
    if (root.pref == .lazy) info |= Info.shortest;
    if (canBeEmpty(root)) info |= Info.emptymatch;
    const re = try it.alloc().create(Regex);
    re.* = .{ .prog = e.prog.items, .root = root, .ncap = p.ncap, .nodes = p.nodes, .opts = p.opts, .shortest = root.pref == .lazy, .has_backref = p.has_backref, .info = info, .start = try startOf(it.alloc(), e.prog.items), .dfa = dfaOk(e.prog.items), .dfa_end = hasEndAssert(e.prog.items), .empty = canBeEmpty(root) };
    return re;
}

// ---- The matcher ----

const Thread = struct { pc: u32, start: u32 };

/// A lazy DFA over the thread lists of the simulation, before the first
/// match. A state is the list of the thread instructions at a position,
/// after the threads of the new start, with the rank of the start of
/// each thread: 0 for the first start of the list, 1 for the next one,
/// and so on. The ticks of one step depend only on the instructions and
/// the character. So each transition keeps its ticks, and the step
/// count stays the same as that of the simulation. A transition also
/// keeps the source of the start of each rank: a rank of the old state,
/// or `fresh` for the start at the next position. A step that reaches
/// a match has the mark `matches`, and the simulation goes on from it.
const Dfa = struct {
    states: std.ArrayList(State) = .empty,
    /// The state of each list, by the bytes of its instructions and ranks.
    index: std.StringHashMapUnmanaged(u32) = .empty,
    /// For each state, 256 transitions by character, `none`, or `matches`.
    /// A program with an assert of the end has 256 more for the step on
    /// the last character of the text.
    next: std.ArrayList(u32) = .empty,
    /// The count of transitions of each state: 256 or 512.
    stride: u32 = 256,
    trans: std.ArrayList(Trans) = .empty,
    /// The start position of each rank, for the current and the next state.
    starts: [2][]u32,
    /// The key of one list, before a lookup.
    buf: []u32,

    const State = struct { pcs: []const u32, ranks: []const u32, nranks: u32 };
    const Trans = struct { to: u32, ticks: u32, from: []const u32 };
    const none = std.math.maxInt(u32);
    /// The transition reaches a match.
    const matches = std.math.maxInt(u32) - 1;
    const fresh = std.math.maxInt(u32);
    /// The most states of one matcher. A search that needs more goes on
    /// with the simulation.
    const max_states = 64;
};

/// The state of one search. `caps` has two byte offsets for each group,
/// or null. `spans` has the same positions in characters.
pub const Matcher = struct {
    it: *Interp,
    re: *Regex,
    s: []const u8,
    /// The characters of a text that is not ASCII. Null for ASCII.
    text: ?[]const u21,
    /// The byte offset of each character of `text`.
    offs: []const usize = &.{},
    n: usize,
    caps: []?usize,
    spans: []?usize,
    cur: []Thread,
    nxt: []Thread,
    mark: []u32,
    gen: u32 = 0,
    work: std.ArrayList(u32) = .empty,
    steps: u32 = 0,
    run_node: u32 = inf,
    run_lo: usize = 0,
    run_end: usize = 0,
    frames: std.ArrayList(RepFrame) = .empty,
    /// The position where the current search started.
    from: usize = 0,
    /// With `bits_w` set, the failed spans of `dissect` are in the bit
    /// table `it.re_bits`: the bit of node `id`, `lo`, and `hi` is
    /// `(id * bits_w + lo - bits_lo) * bits_w + hi - bits_lo`.
    bits_lo: usize = 0,
    bits_w: usize = 0,
    const RepFrame = struct { pos: usize, next: usize };

    pub fn init(it: *Interp, re: *Regex, s: []const u8) Error!Matcher {
        const a = it.alloc();
        var ascii = true;
        for (s) |c| {
            if (c >= 0x80) {
                ascii = false;
                break;
            }
        }
        var text: ?[]const u21 = null;
        var offs: []usize = &.{};
        var n = s.len;
        if (!ascii) {
            var t: std.ArrayList(u21) = .empty;
            var o: std.ArrayList(usize) = .empty;
            var i: usize = 0;
            while (i < s.len) {
                const d = ucd.next(s, i);
                try t.append(a, d.cp);
                try o.append(a, i);
                i += d.len;
            }
            try o.append(a, s.len);
            text = t.items;
            offs = o.items;
            n = t.items.len;
        }
        const size = re.prog.len + 1;
        const mark = try a.alloc(u32, size);
        @memset(mark, 0);
        return .{
            .it = it,
            .re = re,
            .s = s,
            .text = text,
            .offs = offs,
            .n = n,
            .caps = try a.alloc(?usize, 2 * re.ncap),
            .spans = try a.alloc(?usize, 2 * re.ncap),
            .cur = try a.alloc(Thread, size),
            .nxt = try a.alloc(Thread, size),
            .mark = mark,
        };
    }

    inline fn ch(m: *const Matcher, i: usize) u21 {
        return if (m.text) |t| t[i] else m.s[i];
    }

    fn byteAt(m: *const Matcher, i: usize) usize {
        return if (m.text != null) m.offs[i] else i;
    }

    fn charAt(m: *const Matcher, byte: usize) usize {
        if (m.text == null) return byte;
        var lo: usize = 0;
        var hi: usize = m.n;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (m.offs[mid] < byte) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn tick(m: *Matcher) Error!void {
        m.steps += 1;
        if (m.steps >= 32) {
            m.steps = 0;
            if (m.it.compute_limit == 0) return m.it.fail("compute limit reached", .{});
            m.it.compute_limit -= 1;
        }
    }

    /// `n` calls of `tick`.
    fn ticks(m: *Matcher, n: u64) Error!void {
        const total = m.steps + n;
        const cost = total / 32;
        m.steps = @intCast(total % 32);
        if (cost > m.it.compute_limit) {
            m.it.compute_limit = 0;
            return m.it.fail("compute limit reached", .{});
        }
        m.it.compute_limit -= @intCast(cost);
    }

    /// The first position at or after `i` whose character a first thread
    /// accepts, or `m.n`.
    fn nextStart(m: *const Matcher, st: *const Start, i: usize) usize {
        var k = i;
        if (m.text) |t| {
            while (k < m.n) : (k += 1) {
                const c = t[k];
                if (if (c < 256) st.bytes[c] else st.high) break;
            }
        } else {
            while (k < m.n and !st.bytes[m.s[k]]) k += 1;
        }
        return k;
    }

    fn wordAt(m: *const Matcher, i: usize) bool {
        return i < m.n and ucd.isWordChar(m.ch(i));
    }

    fn assertOk(m: *const Matcher, a: Assert, i: usize) bool {
        const before = i > 0 and ucd.isWordChar(m.ch(i - 1));
        const after = m.wordAt(i);
        const opts = m.re.opts;
        return switch (a) {
            .bol => i == 0 and !opts.notbol,
            .eol => i == m.n and !opts.noteol,
            .line_bol => (i == 0 and !opts.notbol) or (i > 0 and m.ch(i - 1) == '\n'),
            .line_eol => (i == m.n and !opts.noteol) or (i < m.n and m.ch(i) == '\n'),
            .text_start => i == m.from,
            .text_end => i == m.n,
            .word_start => !before and after,
            .word_end => before and !after,
            .word_b => before != after,
            .not_word_b => before == after,
        };
    }

    /// Runs the program of a lookahead from `pos`.
    fn lookRun(m: *Matcher, start: u32, pos: usize) Error!bool {
        const a = m.it.alloc();
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        var todo: std.ArrayList(u64) = .empty;
        const key = struct {
            fn f(pc: u32, at: usize) u64 {
                return @as(u64, pc) << 40 | at;
            }
        }.f;
        try todo.append(a, key(start, pos));
        while (todo.pop()) |k| {
            if ((try seen.getOrPut(a, k)).found_existing) continue;
            try m.tick();
            const pc: u32 = @intCast(k >> 40);
            const at: usize = @intCast(k & ((1 << 40) - 1));
            switch (m.re.prog[pc]) {
                .match => return true,
                .jmp => |t| try todo.append(a, key(t, at)),
                .split => |sp| {
                    try todo.append(a, key(sp.second, at));
                    try todo.append(a, key(sp.first, at));
                },
                .char => |c| if (at < m.n and m.ch(at) == c) try todo.append(a, key(pc + 1, at + 1)),
                .set => |s| if (at < m.n and s.has(m.ch(at))) try todo.append(a, key(pc + 1, at + 1)),
                .assert => |as| if (m.assertOk(as, at)) try todo.append(a, key(pc + 1, at)),
                .look => |l| if ((try m.lookRun(l.start, at)) != l.negate) try todo.append(a, key(pc + 2, at)),
            }
        }
        return false;
    }

    /// Adds a state and the states that it reaches with no input. Gives
    /// true when the state `match` is reached.
    fn addThread(m: *Matcher, list: []Thread, count: *usize, pc0: u32, start: u32, pos: usize) Error!bool {
        return m.addThreadAs(false, list, count, pc0, start, pos, undefined);
    }

    /// `addThread`. With `dry`, the ticks go to `visits` and not to the
    /// compute limit. A program of the DFA has no lookahead, and its
    /// asserts depend only on the position (see `dfaOk`).
    inline fn addThreadAs(m: *Matcher, comptime dry: bool, list: []Thread, count: *usize, pc0: u32, start: u32, pos: usize, visits: *u32) Error!bool {
        var matched = false;
        m.work.clearRetainingCapacity();
        const a = m.it.alloc();
        try m.work.append(a, pc0);
        while (m.work.pop()) |pc| {
            if (m.mark[pc] == m.gen) continue;
            m.mark[pc] = m.gen;
            if (dry) visits.* += 1 else try m.tick();
            switch (m.re.prog[pc]) {
                .jmp => |t| try m.work.append(a, t),
                .split => |sp| {
                    try m.work.append(a, sp.second);
                    try m.work.append(a, sp.first);
                },
                .assert => |as| if (m.assertOk(as, pos)) try m.work.append(a, pc + 1),
                .look => |l| if (dry) unreachable else if ((try m.lookRun(l.start, pos)) != l.negate) try m.work.append(a, pc + 2),
                .match => matched = true,
                else => {
                    list[count.*] = .{ .pc = pc, .start = start };
                    count.* += 1;
                },
            }
        }
        return matched;
    }

    fn nextGen(m: *Matcher) void {
        m.gen +%= 1;
        if (m.gen == 0) {
            @memset(m.mark, 0);
            m.gen = 1;
        }
    }

    /// The state of a thread list, made when it is new, or null when the
    /// DFA has `Dfa.max_states`. Writes the start of each rank to `starts`.
    fn intern(m: *Matcher, d: *Dfa, list: []const Thread, starts: []u32) Error!?u32 {
        const key = d.buf[0 .. 2 * list.len];
        var nr: u32 = 0;
        for (list, 0..) |t, k| {
            const r = std.mem.indexOfScalar(u32, starts[0..nr], t.start) orelse blk: {
                starts[nr] = t.start;
                nr += 1;
                break :blk nr - 1;
            };
            key[k] = t.pc;
            key[list.len + k] = @intCast(r);
        }
        if (d.index.get(std.mem.sliceAsBytes(key))) |id| return id;
        if (d.states.items.len >= Dfa.max_states) return null;
        const a = m.it.alloc();
        const own = try a.dupe(u32, key);
        const id: u32 = @intCast(d.states.items.len);
        // The DFA stays with the pattern, so an error of the memory must
        // leave it whole: each allocation comes before the first change.
        try d.states.ensureUnusedCapacity(a, 1);
        try d.next.ensureUnusedCapacity(a, d.stride);
        try d.index.ensureUnusedCapacity(a, 1);
        d.states.appendAssumeCapacity(.{ .pcs = own[0..list.len], .ranks = own[list.len..], .nranks = nr });
        d.index.putAssumeCapacityNoClobber(std.mem.sliceAsBytes(own), id);
        d.next.appendNTimesAssumeCapacity(Dfa.none, d.stride);
        return id;
    }

    const Hand = struct { i: usize, n: usize };

    /// Runs the DFA from `from` to the first step that reaches a match.
    /// Gives null when the text ends with no match. Else `m.cur` has the
    /// threads of the returned position, with the threads of the new
    /// start, and the simulation goes on from there. The caller makes
    /// sure that the threads of a new start do not reach `match`: the
    /// program has a `Start`, or the pattern cannot match the empty
    /// string.
    fn runDfa(m: *Matcher, from: usize) Error!?Hand {
        const a = m.it.alloc();
        const d = m.re.states orelse blk: {
            const size = m.re.prog.len + 1;
            const nd = try a.create(Dfa);
            nd.* = .{ .starts = .{ try a.alloc(u32, size), try a.alloc(u32, size) }, .buf = try a.alloc(u32, 2 * size), .stride = if (m.re.dfa_end) 512 else 256 };
            m.re.states = nd;
            break :blk nd;
        };
        // With a `Start`, state 0 is the list of a new start alone, and
        // a search skips to the next start candidate from it. With no
        // `Start`, the first list depends on the asserts at `from`, so it
        // gets its state by its threads.
        const start = m.re.start;
        var i = from;
        m.nextGen();
        // The first threads, as in `simulate`.
        if (start) |st| {
            const k0 = m.nextStart(st, i);
            if (k0 > i) {
                try m.ticks(@as(u64, k0 - i) * st.cost);
                i = k0;
                m.nextGen();
            }
        }
        var n: usize = 0;
        _ = try m.addThread(m.cur, &n, 0, @intCast(i), i);
        var starts = d.starts[0];
        var nstarts = d.starts[1];
        var s: u32 = 0;
        if (start == null) {
            s = (try m.intern(d, m.cur[0..n], starts)) orelse return .{ .i = i, .n = n };
        } else if (d.states.items.len == 0) {
            _ = (try m.intern(d, m.cur[0..n], starts)) orelse return .{ .i = i, .n = n };
        } else starts[0] = @intCast(i);
        while (true) {
            if (s == 0) if (start) |st| {
                // The threads of one start alone: each position up to the
                // next start candidate adds `st.cost` ticks, as in `simulate`.
                const k = m.nextStart(st, i);
                if (k > i) {
                    try m.ticks(@as(u64, k - i) * st.cost);
                    i = k;
                    starts[0] = @intCast(k);
                }
            };
            if (i >= m.n) return null;
            const c = m.ch(i);
            // The step on the last character has its own transitions when
            // an assert of the end can be true after it.
            const at: usize = if (m.re.dfa_end and i + 1 == m.n) 256 else 0;
            if (c < 256) {
                const t = d.next.items[s * d.stride + at + c];
                if (t == Dfa.matches) {
                    const state = d.states.items[s];
                    for (state.pcs, state.ranks, m.cur[0..state.pcs.len]) |pc, r, *th| th.* = .{ .pc = pc, .start = starts[r] };
                    return .{ .i = i, .n = state.pcs.len };
                }
                if (t != Dfa.none) {
                    const tr = d.trans.items[t];
                    try m.ticks(tr.ticks);
                    for (tr.from, nstarts[0..tr.from.len]) |r, *v| v.* = if (r == Dfa.fresh) @intCast(i + 1) else starts[r];
                    std.mem.swap([]u32, &starts, &nstarts);
                    s = tr.to;
                    i += 1;
                    continue;
                }
            }
            // A new transition: a dry step from the threads of the state.
            const state = d.states.items[s];
            for (state.pcs, state.ranks, m.cur[0..state.pcs.len]) |pc, r, *t| t.* = .{ .pc = pc, .start = starts[r] };
            const ncur = state.pcs.len;
            m.nextGen();
            var visits: u32 = 0;
            var nn: usize = 0;
            for (m.cur[0..ncur]) |t| {
                visits += 1;
                const ok = switch (m.re.prog[t.pc]) {
                    .char => |x| x == c,
                    .set => |set| set.has(c),
                    else => false,
                };
                if (!ok) continue;
                if (try m.addThreadAs(true, m.nxt, &nn, t.pc + 1, t.start, i + 1, &visits)) {
                    if (c < 256) d.next.items[s * d.stride + at + c] = Dfa.matches;
                    return .{ .i = i, .n = ncur };
                }
            }
            if (try m.addThreadAs(true, m.nxt, &nn, 0, @intCast(i + 1), i + 1, &visits)) {
                // Only a pattern that can match the empty string gets
                // here, and `simulate` gives it no DFA. The simulation
                // makes the same step again.
                return .{ .i = i, .n = ncur };
            }
            try m.ticks(visits);
            const ns = (try m.intern(d, m.nxt[0..nn], nstarts)) orelse {
                std.mem.swap([]Thread, &m.cur, &m.nxt);
                return .{ .i = i + 1, .n = nn };
            };
            if (c < 256) {
                const from_ranks = try a.alloc(u32, d.states.items[ns].nranks);
                for (from_ranks, nstarts[0..from_ranks.len]) |*f, v| {
                    f.* = if (v == i + 1) Dfa.fresh else @intCast(std.mem.indexOfScalar(u32, starts[0..state.nranks], v).?);
                }
                try d.trans.ensureUnusedCapacity(a, 1);
                d.trans.appendAssumeCapacity(.{ .to = ns, .ticks = visits, .from = from_ranks });
                d.next.items[s * d.stride + at + c] = @intCast(d.trans.items.len - 1);
            }
            std.mem.swap([]u32, &starts, &nstarts);
            s = ns;
            i += 1;
        }
    }

    /// The leftmost match from `from`, with the longest or shortest end.
    fn simulate(m: *Matcher, from: usize) Error!?[2]usize {
        const shortest = m.re.shortest;
        var best: ?[2]usize = null;
        var ncur: usize = 0;
        var i = from;
        // True when `cur` has the threads of the new start at `i`.
        var added = false;
        if (m.re.dfa and (m.re.start != null or !m.re.empty)) {
            const h = (try m.runDfa(from)) orelse return null;
            i = h.i;
            ncur = h.n;
            added = true;
        }
        var cur = m.cur;
        var nxt = m.nxt;
        while (true) : (i += 1) {
            // The threads that step into position `i` are in `cur`. Add
            // a new start until a match exists.
            if (best == null and !added) {
                if (i == from) m.nextGen();
                if (ncur == 0) if (m.re.start) |st| {
                    // No thread is live, so each position up to the next
                    // start candidate adds `st.cost` ticks and no thread.
                    const k = m.nextStart(st, i);
                    if (k > i) {
                        try m.ticks(@as(u64, k - i) * st.cost);
                        i = k;
                        m.nextGen();
                    }
                };
                if (try m.addThread(cur, &ncur, 0, @intCast(i), i)) {
                    best = .{ i, i };
                }
            }
            added = false;
            if (ncur == 0 and (best != null or i >= m.n)) break;
            if (i >= m.n) break;
            const c = m.ch(i);
            m.nextGen();
            var nn: usize = 0;
            for (cur[0..ncur]) |t| {
                if (best) |b| {
                    if (t.start > b[0] or (shortest and t.start == b[0])) continue;
                }
                try m.tick();
                const ok = switch (m.re.prog[t.pc]) {
                    .char => |x| x == c,
                    .set => |s| s.has(c),
                    else => false,
                };
                if (!ok) continue;
                if (try m.addThread(nxt, &nn, t.pc + 1, t.start, i + 1)) {
                    if (best == null or t.start < best.?[0] or (t.start == best.?[0] and !shortest)) {
                        best = .{ t.start, i + 1 };
                    }
                }
            }
            const tmp = cur;
            cur = nxt;
            nxt = tmp;
            ncur = nn;
        }
        return best;
    }

    fn clearCaps(m: *Matcher, n: *const Node) void {
        var k = n.cap_lo;
        while (k < n.cap_hi) : (k += 1) {
            m.spans[2 * @as(usize, k)] = null;
            m.spans[2 * @as(usize, k) + 1] = null;
        }
    }

    fn single(n: *const Node) bool {
        return n.kind == .char or n.kind == .set;
    }

    fn oneMatches(m: *const Matcher, n: *const Node, i: usize) bool {
        return switch (n.kind) {
            .char => |c| m.ch(i) == c,
            .set => |s| s.has(m.ch(i)),
            else => false,
        };
    }

    /// The end of the run of characters from `lo` that the node matches.
    fn runEnd(m: *Matcher, n: *const Node, lo: usize) Error!usize {
        if (m.run_node == n.id and m.run_lo == lo) return m.run_end;
        var e = lo;
        while (e < m.n and m.oneMatches(n, e)) : (e += 1) try m.tick();
        m.run_node = n.id;
        m.run_lo = lo;
        m.run_end = e;
        return e;
    }

    /// True when the node matches exactly the span, and sets its groups.
    fn dissect(m: *Matcher, n: *const Node, lo: usize, hi: usize) Error!bool {
        try m.tick();
        switch (n.kind) {
            .empty => return lo == hi,
            .char, .set => return hi == lo + 1 and m.oneMatches(n, lo),
            .assert => |a| return lo == hi and m.assertOk(a, lo),
            .look => |l| {
                if (lo != hi) return false;
                return (try m.lookRun(l.start, lo)) != l.negate;
            },
            .backref => |k| {
                const a = m.spans[2 * @as(usize, k)] orelse return false;
                const b = m.spans[2 * @as(usize, k) + 1] orelse return false;
                if (hi - lo != b - a) return false;
                for (0..b - a) |x| {
                    var p = m.ch(a + x);
                    var q = m.ch(lo + x);
                    if (m.re.opts.nocase) {
                        p = ucd.toLower(p);
                        q = ucd.toLower(q);
                    }
                    if (p != q) return false;
                }
                return true;
            },
            else => {},
        }
        const memo = !m.re.has_backref;
        const key = @as(u64, n.id) << 44 | @as(u64, lo) << 22 | hi;
        if (memo and hi < 1 << 22 and m.memoHas(n.id, lo, hi, key)) return false;
        const ok = switch (n.kind) {
            .group => |g| blk: {
                if (!try m.dissect(g.sub, lo, hi)) break :blk false;
                if (g.cap) |k| {
                    m.spans[2 * @as(usize, k)] = lo;
                    m.spans[2 * @as(usize, k) + 1] = hi;
                }
                break :blk true;
            },
            .cat => |items| try m.catFrom(items, lo, hi),
            .alt => |items| blk: {
                for (items) |x| {
                    m.clearCaps(x);
                    if (try m.dissect(x, lo, hi)) break :blk true;
                }
                break :blk false;
            },
            .repeat => |r| try m.repeat(n, r.sub, r.min, r.max, r.greedy, lo, hi),
            else => unreachable,
        };
        if (!ok and memo and hi < 1 << 22) try m.memoAdd(n.id, lo, hi, key);
        return ok;
    }

    fn memoBit(m: *const Matcher, id: u32, lo: usize, hi: usize) usize {
        return (@as(usize, id) * m.bits_w + lo - m.bits_lo) * m.bits_w + hi - m.bits_lo;
    }

    fn memoHas(m: *const Matcher, id: u32, lo: usize, hi: usize, key: u64) bool {
        if (m.bits_w == 0) return m.it.re_memo.contains(key);
        const b = m.memoBit(id, lo, hi);
        return m.it.re_bits.items[b >> 6] >> @intCast(b & 63) & 1 != 0;
    }

    fn memoAdd(m: *Matcher, id: u32, lo: usize, hi: usize, key: u64) Error!void {
        if (m.bits_w == 0) {
            if (m.it.re_memo.count() < max_memo) try m.it.re_memo.put(m.it.alloc(), key, {});
            return;
        }
        const b = m.memoBit(id, lo, hi);
        const w = &m.it.re_bits.items[b >> 6];
        if (w.* == 0) try m.it.re_dirty.append(m.it.alloc(), @intCast(b >> 6));
        w.* |= @as(u64, 1) << @intCast(b & 63);
    }

    /// Uses the bit table for the failed spans of the match `b` when the
    /// table of each node and each pair of positions in `b` is small.
    /// Else the spans go in the hash map `it.re_memo`.
    fn memoBits(m: *Matcher, b: [2]usize) Error!void {
        m.bits_w = 0;
        for (m.it.re_dirty.items) |w| m.it.re_bits.items[w] = 0;
        m.it.re_dirty.clearRetainingCapacity();
        const w = b[1] - b[0] + 1;
        const need = @as(u64, m.re.nodes) * w * w;
        if (need > max_memo_bits) return;
        const words: usize = @intCast((need + 63) / 64);
        if (m.it.re_bits.items.len < words) {
            const old = m.it.re_bits.items.len;
            try m.it.re_bits.resize(m.it.alloc(), words);
            @memset(m.it.re_bits.items[old..], 0);
        }
        m.bits_lo = b[0];
        m.bits_w = w;
    }

    fn catFrom(m: *Matcher, items: []const *Node, lo: usize, hi: usize) Error!bool {
        if (items.len == 1) return m.dissect(items[0], lo, hi);
        const h = items[0];
        if (single(h)) {
            if (lo >= hi or !m.oneMatches(h, lo)) return false;
            return m.catFrom(items[1..], lo + 1, hi);
        }
        if (h.kind == .assert or h.kind == .look or h.kind == .empty) {
            if (!try m.dissect(h, lo, lo)) return false;
            return m.catFrom(items[1..], lo, hi);
        }
        // The lengths of the parts bound the end of the first part.
        var rest_min: usize = 0;
        var rest_max: usize = 0;
        for (items[1..]) |x| {
            rest_min +|= x.min_len;
            rest_max = if (x.max_len == inf or rest_max == inf) inf else rest_max +| x.max_len;
        }
        if (hi - lo < h.min_len +| rest_min) return false;
        var first = lo + h.min_len;
        if (rest_max != inf and hi >= rest_max and hi - rest_max > first) first = hi - rest_max;
        var last = hi - rest_min;
        if (h.max_len != inf) last = @min(last, lo + h.max_len);
        if (first > last) return false;
        const lazy = h.pref == .lazy;
        var e: usize = if (lazy) first else last;
        while (true) {
            if (try m.dissect(h, lo, e)) {
                if (try m.catFrom(items[1..], e, hi)) return true;
            }
            m.clearCaps(h);
            if (lazy) {
                if (e == last) return false;
                e += 1;
            } else {
                if (e == first) return false;
                e -= 1;
            }
        }
    }

    fn repeat(m: *Matcher, n: *const Node, sub: *const Node, min: u32, max: u32, greedy: bool, lo: usize, hi: usize) Error!bool {
        _ = n;
        if (single(sub)) {
            const count = hi - lo;
            if (count < min or (max != inf and count > max)) return false;
            return (try m.runEnd(sub, lo)) >= hi;
        }
        if (lo == hi) {
            if (min == 0) {
                if (!try m.dissect(sub, lo, lo)) m.clearCaps(sub);
                return true;
            }
            return m.dissect(sub, lo, lo);
        }
        if (max == 0) return false;
        // Each frame is one pass of the body from `pos`.
        const base = m.frames.items.len;
        defer m.frames.shrinkRetainingCapacity(base);
        const a = m.it.alloc();
        // A pass takes at least one character and at most `longest`.
        const longest: usize = if (sub.max_len == inf) m.n else sub.max_len;
        try m.frames.append(a, .{ .pos = lo, .next = if (greedy) @min(hi, lo +| longest) else lo + 1 });
        while (m.frames.items.len > base) {
            try m.tick();
            const f = &m.frames.items[m.frames.items.len - 1];
            const count = m.frames.items.len - base;
            const pos = f.pos;
            const e = f.next;
            if (greedy) {
                if (e <= pos) {
                    m.frames.items.len -= 1;
                    continue;
                }
                f.next = e - 1;
            } else {
                if (e > hi or e - pos > longest) {
                    m.frames.items.len -= 1;
                    continue;
                }
                f.next = e + 1;
            }
            if (!try m.dissect(sub, pos, e)) continue;
            if (e == hi) {
                if (count >= min) return true;
                // The other passes of the minimum match the empty text.
                if (try m.dissect(sub, hi, hi)) return true;
                continue;
            }
            if (max != inf and count >= max) continue;
            try m.frames.append(a, .{ .pos = e, .next = if (greedy) @min(hi, e +| longest) else e + 1 });
        }
        return false;
    }

    /// Finds the first match that starts at byte offset `from` or later.
    pub fn search(m: *Matcher, from_byte: usize) Error!bool {
        const from = m.charAt(from_byte);
        m.from = from;
        @memset(m.spans, null);
        @memset(m.caps, null);
        m.run_node = inf;
        m.it.re_memo.clearRetainingCapacity();
        var span: ?[2]usize = null;
        if (!m.re.has_backref) {
            span = try m.simulate(from);
            if (span) |b| {
                if (m.re.ncap > 1) {
                    try m.memoBits(b);
                    if (!try m.dissect(m.re.root, b[0], b[1])) @memset(m.spans, null);
                }
            }
        } else {
            outer: for (from..m.n + 1) |lo| {
                var e: usize = if (m.re.shortest) lo else m.n;
                while (true) {
                    @memset(m.spans, null);
                    if (try m.dissect(m.re.root, lo, e)) {
                        span = .{ lo, e };
                        break :outer;
                    }
                    if (m.re.shortest) {
                        if (e == m.n) break;
                        e += 1;
                    } else {
                        if (e == lo) break;
                        e -= 1;
                    }
                }
            }
        }
        const b = span orelse return false;
        m.spans[0] = b[0];
        m.spans[1] = b[1];
        for (m.spans, m.caps) |x, *y| y.* = if (x) |v| m.byteAt(v) else null;
        return true;
    }
};

/// True when the pattern matches a part of the string.
pub fn matches(it: *Interp, pat: []const u8, s: []const u8, nocase: bool) Error!bool {
    const re = try compile(it, pat, .{ .nocase = nocase });
    var m = try Matcher.init(it, re, s);
    return m.search(0);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn capValue(it: *Interp, m: *const Matcher, k: usize, indices: bool) Error!Value {
    const lo = if (k < m.re.ncap) m.spans[2 * k] else null;
    const hi = if (k < m.re.ncap) m.spans[2 * k + 1] else null;
    if (lo == null or hi == null) {
        if (!indices) return Value.empty;
        return value.newList(it.alloc(), &.{ .{ .int = -1 }, .{ .int = -1 } });
    }
    if (!indices) return .{ .str = m.s[m.byteAt(lo.?)..m.byteAt(hi.?)] };
    return value.newList(it.alloc(), &.{ .{ .int = @intCast(lo.?) }, .{ .int = @as(i64, @intCast(hi.?)) - 1 } });
}

/// The list that `regexp -about` gives: the group count and the names
/// of the properties of the pattern.
pub fn aboutValue(it: *Interp, re: *const Regex) Error!Value {
    const a = it.alloc();
    const names = [_]struct { u16, []const u8 }{
        .{ Info.backref, "REG_UBACKREF" },       .{ Info.lookahead, "REG_ULOOKAHEAD" },
        .{ Info.bounds, "REG_UBOUNDS" },         .{ Info.braces, "REG_UBRACES" },
        .{ Info.bsalnum, "REG_UBSALNUM" },       .{ Info.pbotch, "REG_UPBOTCH" },
        .{ Info.bbs, "REG_UBBS" },               .{ Info.nonposix, "REG_UNONPOSIX" },
        .{ Info.unspec, "REG_UUNSPEC" },         .{ Info.unport, "REG_UUNPORT" },
        .{ Info.locale, "REG_ULOCALE" },         .{ Info.emptymatch, "REG_UEMPTYMATCH" },
        .{ Info.impossible, "REG_UIMPOSSIBLE" }, .{ Info.shortest, "REG_USHORTEST" },
    };
    var flags: std.ArrayList(Value) = .empty;
    for (names) |x| if (re.info & x[0] != 0) try flags.append(a, .{ .str = x[1] });
    return value.newList(a, &.{ .{ .int = @intCast(re.ncap - 1) }, try value.wrapList(a, flags.items) });
}

const regexp_options = [_][]const u8{ "-all", "-about", "-indices", "-inline", "-expanded", "-line", "-linestop", "-lineanchor", "-nocase", "-start" };
const regsub_options = [_][]const u8{ "-all", "-nocase", "-expanded", "-line", "-linestop", "-lineanchor", "-start" };

/// The option that a word names: an exact name or a unique prefix.
fn optionName(word: []const u8, table: []const []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var count: usize = 0;
    for (table) |n| {
        if (eql(n, word)) return n;
        if (word.len > 1 and std.mem.startsWith(u8, n, word)) {
            found = n;
            count += 1;
        }
    }
    return if (count == 1) found else null;
}

fn applyOption(o: []const u8, opts: *Options) bool {
    if (eql(o, "-nocase")) {
        opts.nocase = true;
    } else if (eql(o, "-expanded")) {
        opts.expanded = true;
    } else if (eql(o, "-line")) {
        opts.linestop = true;
        opts.lineanchor = true;
    } else if (eql(o, "-linestop")) {
        opts.linestop = true;
    } else if (eql(o, "-lineanchor")) {
        opts.lineanchor = true;
    } else return false;
    return true;
}

/// The byte offset of the index of `-start`, or null past the text.
/// `end` is the position after the last character.
fn startOffset(it: *Interp, v: Value, s: []const u8) Error!?usize {
    const n = cmds.charCount(s);
    const k = try cmds.index(it, v, n + 1);
    if (k <= 0) return 0;
    if (k > n) return null;
    if (k == n) return s.len;
    return cmds.byteOf(s, n, @intCast(k));
}

pub fn cmdRegexp(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var opts: Options = .{};
    var all = false;
    var inl = false;
    var indices = false;
    var about = false;
    var start_word: ?Value = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const w = try it.str(argv[i]);
        if (w.len == 0 or w[0] != '-') break;
        if (eql(w, "--")) {
            i += 1;
            break;
        }
        const o = optionName(w, &regexp_options) orelse
            return it.failCode("TCL LOOKUP INDEX switch", "bad option \"{s}\": must be -all, -about, -indices, -inline, -expanded, -line, -linestop, -lineanchor, -nocase, -start, or --", .{w});
        if (applyOption(o, &opts)) {
            continue;
        } else if (eql(o, "-all")) {
            all = true;
        } else if (eql(o, "-inline")) {
            inl = true;
        } else if (eql(o, "-indices")) {
            indices = true;
        } else if (eql(o, "-about")) {
            about = true;
        } else {
            i += 1;
            if (i >= argv.len) break;
            start_word = argv[i];
        }
    }
    if (about) {
        if (argv.len != i + 1) return it.wrongArgs("regexp ?-option ...? exp string ?matchVar? ?subMatchVar ...?");
        return aboutValue(it, try compile(it, try it.str(argv[i]), opts));
    }
    if (argv.len < i + 2) return it.wrongArgs("regexp ?-option ...? exp string ?matchVar? ?subMatchVar ...?");
    const vars = argv[i + 2 ..];
    if (inl and vars.len > 0) return it.fail("regexp match variables not allowed when using -inline", .{});
    const re = try compile(it, try it.str(argv[i]), opts);
    const s = try it.str(argv[i + 1]);
    var m = try Matcher.init(it, re, s);
    var out: std.ArrayList(Value) = .empty;
    var count: i64 = 0;
    var at: usize = 0;
    if (start_word) |w| at = try startOffset(it, w, s) orelse s.len + 1;
    while (at <= s.len) {
        if (!try m.search(at)) break;
        count += 1;
        if (inl) {
            for (0..re.ncap) |k| try out.append(it.alloc(), try capValue(it, &m, k, indices));
        } else for (vars, 0..) |v, k| {
            try it.setVar(try it.str(v), try capValue(it, &m, k, indices));
        }
        if (!all) break;
        const lo = m.caps[0].?;
        const hi = m.caps[1].?;
        at = if (hi == lo) (if (hi < s.len) hi + ucd.next(s, hi).len else hi + 1) else hi;
        // An empty match at the end of the text does not count again.
        if (at >= s.len) break;
    }
    if (inl) return value.wrapList(it.alloc(), out.items);
    return .{ .int = count };
}

pub fn cmdRegsub(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var opts: Options = .{};
    var all = false;
    var start_word: ?Value = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const w = try it.str(argv[i]);
        if (w.len == 0 or w[0] != '-') break;
        if (eql(w, "--")) {
            i += 1;
            break;
        }
        const o = optionName(w, &regsub_options) orelse
            return it.failCode("TCL LOOKUP INDEX switch", "bad option \"{s}\": must be -all, -nocase, -expanded, -line, -linestop, -lineanchor, -start, or --", .{w});
        if (applyOption(o, &opts)) {
            continue;
        } else if (eql(o, "-all")) {
            all = true;
        } else {
            i += 1;
            if (i >= argv.len) break;
            start_word = argv[i];
        }
    }
    if (argv.len != i + 3 and argv.len != i + 4) return it.wrongArgs("regsub ?-option ...? exp string subSpec ?varName?");
    const a = it.alloc();
    const re = try compile(it, try it.str(argv[i]), opts);
    const s = try it.str(argv[i + 1]);
    const spec = try it.str(argv[i + 2]);
    var m = try Matcher.init(it, re, s);
    var out: std.ArrayList(u8) = .empty;
    var count: i64 = 0;
    var at: usize = 0;
    if (start_word) |w| at = try startOffset(it, w, s) orelse s.len + 1;
    var copied: usize = 0;
    while (at <= s.len) {
        if (!try m.search(at)) break;
        count += 1;
        const lo = m.caps[0].?;
        const hi = m.caps[1].?;
        try out.appendSlice(a, s[copied..lo]);
        var k: usize = 0;
        while (k < spec.len) : (k += 1) {
            const c = spec[k];
            var group: ?usize = null;
            if (c == '&') {
                group = 0;
            } else if (c == '\\' and k + 1 < spec.len) {
                const nx = spec[k + 1];
                if (std.ascii.isDigit(nx)) {
                    group = nx - '0';
                    k += 1;
                } else if (nx == '&' or nx == '\\') {
                    try out.append(a, nx);
                    k += 1;
                    continue;
                }
            }
            if (group) |g| {
                try out.appendSlice(a, try it.str(try capValue(it, &m, g, false)));
            } else try out.append(a, c);
        }
        copied = hi;
        if (hi == lo) {
            if (lo < s.len) {
                const step = ucd.next(s, lo).len;
                try out.appendSlice(a, s[lo .. lo + step]);
                copied = lo + step;
                at = lo + step;
            } else {
                copied = s.len;
                at = s.len + 1;
            }
        } else at = hi;
        if (!all) break;
    }
    if (copied < s.len) try out.appendSlice(a, s[copied..]);
    const res: Value = .{ .str = out.items };
    if (argv.len == i + 4) {
        try it.setVar(try it.str(argv[i + 3]), res);
        return .{ .int = count };
    }
    return res;
}

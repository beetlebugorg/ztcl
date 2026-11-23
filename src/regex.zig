//! Regular expressions: `regexp`, `regsub`, and the `-regexp` options.
//!
//! The pattern compiles to a small program. A backtracking matcher runs
//! the program. Each 32 steps of the matcher use one step of the fuel,
//! and the backtrack stack has a fixed limit, so a pattern cannot run
//! without end.
//!
//! The syntax is the common part of the advanced regular expressions of
//! Tcl (re_syntax.n): `. [ ] ( ) (?: ) | * + ? {m,n}`, the non-greedy
//! forms, `^ $`, back references, the class names, and the escapes
//! `\d \w \s \D \W \S \m \M \y \Y \A \Z`.
//!
//! Known differences from Tcl: the first alternative that matches wins
//! (Tcl prefers the longest match), and a position is a byte offset.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

const Set = [32]u8;

const Assert = enum { bol, eol, word_start, word_end, word_b, not_word_b, text_start, text_end };

const Node = union(enum) {
    empty,
    char: u8,
    any,
    set: *const Set,
    assert: Assert,
    group: struct { cap: ?u16, sub: *Node },
    cat: []const *Node,
    alt: []const *Node,
    repeat: struct { sub: *Node, min: u32, max: u32, greedy: bool },
    backref: u8,
};

const Inst = union(enum) {
    char: u8,
    any,
    set: *const Set,
    assert: Assert,
    save: u16,
    split: struct { first: u32, second: u32 },
    jmp: u32,
    mark: u16,
    check: u16,
    backref: u8,
    match,
};

const inf = std.math.maxInt(u32);
const max_prog = 20000;
const max_stack = 1 << 20;

pub const Options = struct { nocase: bool = false, line: bool = false };

pub const Regex = struct {
    prog: []const Inst,
    ncap: usize,
    nloop: usize,
    opts: Options,
};

fn setBit(s: *Set, c: u8) void {
    s[c >> 3] |= @as(u8, 1) << @intCast(c & 7);
}

fn hasBit(s: *const Set, c: u8) bool {
    return s[c >> 3] & (@as(u8, 1) << @intCast(c & 7)) != 0;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn addClass(s: *Set, name: []const u8) bool {
    const eq = std.mem.eql;
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        const in = if (eq(u8, name, "alpha")) std.ascii.isAlphabetic(c) //
            else if (eq(u8, name, "digit")) std.ascii.isDigit(c) //
            else if (eq(u8, name, "alnum")) std.ascii.isAlphanumeric(c) //
            else if (eq(u8, name, "upper")) std.ascii.isUpper(c) //
            else if (eq(u8, name, "lower")) std.ascii.isLower(c) //
            else if (eq(u8, name, "space")) std.ascii.isWhitespace(c) //
            else if (eq(u8, name, "blank")) (c == ' ' or c == '\t') //
            else if (eq(u8, name, "punct")) std.ascii.isPunctuation(c) //
            else if (eq(u8, name, "xdigit")) std.ascii.isHex(c) //
            else if (eq(u8, name, "print")) std.ascii.isPrint(c) //
            else if (eq(u8, name, "graph")) (std.ascii.isPrint(c) and c != ' ') //
            else if (eq(u8, name, "cntrl")) std.ascii.isControl(c) //
            else if (eq(u8, name, "word")) isWord(c) //
            else return false;
        if (in) setBit(s, c);
    }
    return true;
}

const Compiler = struct {
    it: *Interp,
    src: []const u8,
    pos: usize = 0,
    ncap: u16 = 1,
    nloop: u16 = 0,
    opts: Options,
    prog: std.ArrayList(Inst) = .empty,
    depth: u32 = 0,

    fn fail(c: *Compiler, msg: []const u8) Error {
        return c.it.fail("couldn't compile regular expression pattern: {s}", .{msg});
    }

    fn node(c: *Compiler, n: Node) Error!*Node {
        const p = try c.it.alloc().create(Node);
        p.* = n;
        return p;
    }

    fn more(c: *Compiler) bool {
        return c.pos < c.src.len;
    }

    fn parseAlt(c: *Compiler) Error!*Node {
        if (c.depth > 100) return c.fail("nesting too deep");
        c.depth += 1;
        defer c.depth -= 1;
        var alts: std.ArrayList(*Node) = .empty;
        while (true) {
            try alts.append(c.it.alloc(), try c.parseCat());
            if (c.more() and c.src[c.pos] == '|') {
                c.pos += 1;
            } else break;
        }
        if (alts.items.len == 1) return alts.items[0];
        return c.node(.{ .alt = alts.items });
    }

    fn parseCat(c: *Compiler) Error!*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (c.more() and c.src[c.pos] != '|' and c.src[c.pos] != ')') {
            var atom = try c.parseAtom();
            // The quantifiers of the atom.
            while (c.more()) {
                const q = c.src[c.pos];
                var min: u32 = 0;
                var max: u32 = inf;
                if (q == '*') {
                    c.pos += 1;
                } else if (q == '+') {
                    min = 1;
                    c.pos += 1;
                } else if (q == '?') {
                    max = 1;
                    c.pos += 1;
                } else if (q == '{' and c.pos + 1 < c.src.len and std.ascii.isDigit(c.src[c.pos + 1])) {
                    c.pos += 1;
                    min = c.number();
                    max = min;
                    if (c.more() and c.src[c.pos] == ',') {
                        c.pos += 1;
                        max = if (c.more() and std.ascii.isDigit(c.src[c.pos])) c.number() else inf;
                    }
                    if (!c.more() or c.src[c.pos] != '}') return c.fail("braces {} not balanced");
                    c.pos += 1;
                    if (min > 255 or (max != inf and (max > 255 or max < min))) return c.fail("invalid repetition count(s)");
                } else break;
                var greedy = true;
                if (c.more() and c.src[c.pos] == '?') {
                    greedy = false;
                    c.pos += 1;
                }
                if (atom.* == .assert) return c.fail("quantifier operand invalid");
                atom = try c.node(.{ .repeat = .{ .sub = atom, .min = min, .max = max, .greedy = greedy } });
            }
            try items.append(c.it.alloc(), atom);
        }
        if (items.items.len == 0) return c.node(.empty);
        if (items.items.len == 1) return items.items[0];
        return c.node(.{ .cat = items.items });
    }

    fn number(c: *Compiler) u32 {
        var n: u32 = 0;
        while (c.more() and std.ascii.isDigit(c.src[c.pos])) : (c.pos += 1) n = n *| 10 +| (c.src[c.pos] - '0');
        return n;
    }

    fn charNode(c: *Compiler, ch: u8) Error!*Node {
        if (c.opts.nocase and std.ascii.isAlphabetic(ch)) {
            const s = try c.it.alloc().create(Set);
            s.* = @splat(0);
            setBit(s, std.ascii.toLower(ch));
            setBit(s, std.ascii.toUpper(ch));
            return c.node(.{ .set = s });
        }
        return c.node(.{ .char = ch });
    }

    fn classNode(c: *Compiler, name: []const u8, negate: bool) Error!*Node {
        const s = try c.it.alloc().create(Set);
        s.* = @splat(0);
        _ = addClass(s, name);
        if (negate) for (s) |*b| {
            b.* = ~b.*;
        };
        return c.node(.{ .set = s });
    }

    fn parseAtom(c: *Compiler) Error!*Node {
        const ch = c.src[c.pos];
        c.pos += 1;
        switch (ch) {
            '(' => {
                var cap: ?u16 = null;
                if (std.mem.startsWith(u8, c.src[c.pos..], "?:")) {
                    c.pos += 2;
                } else {
                    cap = c.ncap;
                    c.ncap += 1;
                }
                const sub = try c.parseAlt();
                if (!c.more() or c.src[c.pos] != ')') return c.fail("parentheses () not balanced");
                c.pos += 1;
                return c.node(.{ .group = .{ .cap = cap, .sub = sub } });
            },
            ')' => return c.fail("parentheses () not balanced"),
            '*', '+', '?' => return c.fail("quantifier operand invalid"),
            '.' => {
                if (!c.opts.line) return c.node(.any);
                const s = try c.it.alloc().create(Set);
                s.* = @splat(0xff);
                s['\n' >> 3] &= ~(@as(u8, 1) << ('\n' & 7));
                return c.node(.{ .set = s });
            },
            '^' => return c.node(.{ .assert = .bol }),
            '$' => return c.node(.{ .assert = .eol }),
            '[' => return c.parseSet(),
            '\\' => return c.parseEscape(),
            else => {
                // The bytes of one character stay together.
                if (ch >= 0xC0) {
                    var bytes: std.ArrayList(*Node) = .empty;
                    try bytes.append(c.it.alloc(), try c.node(.{ .char = ch }));
                    while (c.more() and c.src[c.pos] & 0xC0 == 0x80) : (c.pos += 1) {
                        try bytes.append(c.it.alloc(), try c.node(.{ .char = c.src[c.pos] }));
                    }
                    return c.node(.{ .cat = bytes.items });
                }
                return c.charNode(ch);
            },
        }
    }

    /// The byte of a character escape, or null for a class escape.
    fn escapeByte(c: *Compiler, e: u8) ?u8 {
        return switch (e) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'f' => 12,
            'v' => 11,
            'a' => 7,
            'e' => 27,
            'B' => '\\',
            '0' => 0,
            'x' => blk: {
                var n: u8 = 0;
                var k: usize = 0;
                while (k < 2 and c.more() and std.ascii.isHex(c.src[c.pos])) : (k += 1) {
                    n = n *% 16 +% (std.fmt.charToDigit(c.src[c.pos], 16) catch 0);
                    c.pos += 1;
                }
                break :blk n;
            },
            else => null,
        };
    }

    fn parseEscape(c: *Compiler) Error!*Node {
        if (!c.more()) return c.fail("invalid escape \\ sequence");
        const e = c.src[c.pos];
        c.pos += 1;
        switch (e) {
            'd' => return c.classNode("digit", false),
            'D' => return c.classNode("digit", true),
            'w' => return c.classNode("word", false),
            'W' => return c.classNode("word", true),
            's' => return c.classNode("space", false),
            'S' => return c.classNode("space", true),
            'm' => return c.node(.{ .assert = .word_start }),
            'M' => return c.node(.{ .assert = .word_end }),
            'y' => return c.node(.{ .assert = .word_b }),
            'Y' => return c.node(.{ .assert = .not_word_b }),
            'A' => return c.node(.{ .assert = .text_start }),
            'Z' => return c.node(.{ .assert = .text_end }),
            '1'...'9' => {
                if (e - '0' >= c.ncap) return c.fail("invalid backreference number");
                return c.node(.{ .backref = e - '0' });
            },
            else => {
                if (c.escapeByte(e)) |b| return c.charNode(b);
                if (std.ascii.isAlphanumeric(e)) return c.fail("invalid escape \\ sequence");
                return c.node(.{ .char = e });
            },
        }
    }

    fn parseSet(c: *Compiler) Error!*Node {
        const s = try c.it.alloc().create(Set);
        s.* = @splat(0);
        var negate = false;
        if (c.more() and c.src[c.pos] == '^') {
            negate = true;
            c.pos += 1;
        }
        var first = true;
        while (true) : (first = false) {
            if (!c.more()) return c.fail("brackets [] not balanced");
            var ch = c.src[c.pos];
            if (ch == ']' and !first) {
                c.pos += 1;
                break;
            }
            if (ch == '[' and c.pos + 1 < c.src.len and c.src[c.pos + 1] == ':') {
                const end = std.mem.indexOfPos(u8, c.src, c.pos + 2, ":]") orelse return c.fail("brackets [] not balanced");
                if (!addClass(s, c.src[c.pos + 2 .. end])) return c.fail("invalid character class");
                c.pos = end + 2;
                continue;
            }
            c.pos += 1;
            if (ch == '\\' and c.more()) {
                const e = c.src[c.pos];
                c.pos += 1;
                if (e == 'd' or e == 'w' or e == 's') {
                    _ = addClass(s, switch (e) {
                        'd' => "digit",
                        'w' => "word",
                        else => "space",
                    });
                    continue;
                }
                ch = c.escapeByte(e) orelse e;
            }
            var hi = ch;
            if (c.pos + 1 < c.src.len and c.src[c.pos] == '-' and c.src[c.pos + 1] != ']') {
                hi = c.src[c.pos + 1];
                c.pos += 2;
                if (hi == '\\' and c.more()) {
                    hi = c.escapeByte(c.src[c.pos]) orelse c.src[c.pos];
                    c.pos += 1;
                }
                if (hi < ch) return c.fail("invalid character range");
            }
            var x: usize = ch;
            while (x <= hi) : (x += 1) {
                const b: u8 = @intCast(x);
                setBit(s, b);
                if (c.opts.nocase) {
                    setBit(s, std.ascii.toLower(b));
                    setBit(s, std.ascii.toUpper(b));
                }
            }
        }
        if (negate) {
            for (s) |*b| b.* = ~b.*;
            if (c.opts.line) s['\n' >> 3] &= ~(@as(u8, 1) << ('\n' & 7));
        }
        return c.node(.{ .set = s });
    }

    fn add(c: *Compiler, i: Inst) Error!u32 {
        if (c.prog.items.len >= max_prog) return c.fail("regular expression is too big");
        try c.prog.append(c.it.alloc(), i);
        return @intCast(c.prog.items.len - 1);
    }

    fn here(c: *Compiler) u32 {
        return @intCast(c.prog.items.len);
    }

    fn emit(c: *Compiler, n: *const Node) Error!void {
        switch (n.*) {
            .empty => {},
            .char => |ch| _ = try c.add(.{ .char = ch }),
            .any => _ = try c.add(.any),
            .set => |s| _ = try c.add(.{ .set = s }),
            .assert => |a| _ = try c.add(.{ .assert = a }),
            .backref => |k| _ = try c.add(.{ .backref = k }),
            .group => |g| {
                if (g.cap) |k| _ = try c.add(.{ .save = 2 * k });
                try c.emit(g.sub);
                if (g.cap) |k| _ = try c.add(.{ .save = 2 * k + 1 });
            },
            .cat => |items| for (items) |x| try c.emit(x),
            .alt => |alts| {
                var jumps: std.ArrayList(u32) = .empty;
                for (alts, 0..) |x, i| {
                    if (i + 1 < alts.len) {
                        const sp = try c.add(.{ .split = .{ .first = 0, .second = 0 } });
                        try c.emit(x);
                        try jumps.append(c.it.alloc(), try c.add(.{ .jmp = 0 }));
                        c.prog.items[sp].split = .{ .first = sp + 1, .second = c.here() };
                    } else try c.emit(x);
                }
                for (jumps.items) |j| c.prog.items[j].jmp = c.here();
            },
            .repeat => |r| {
                for (0..r.min) |_| try c.emit(r.sub);
                if (r.max == inf) {
                    const sp = try c.add(.{ .split = .{ .first = 0, .second = 0 } });
                    const k = c.nloop;
                    c.nloop += 1;
                    _ = try c.add(.{ .mark = k });
                    try c.emit(r.sub);
                    _ = try c.add(.{ .check = k });
                    _ = try c.add(.{ .jmp = sp });
                    c.setSplit(sp, sp + 1, c.here(), r.greedy);
                } else {
                    var splits: std.ArrayList(u32) = .empty;
                    for (r.min..r.max) |_| {
                        try splits.append(c.it.alloc(), try c.add(.{ .split = .{ .first = 0, .second = 0 } }));
                        try c.emit(r.sub);
                    }
                    for (splits.items) |sp| c.setSplit(sp, sp + 1, c.here(), r.greedy);
                }
            },
        }
    }

    fn setSplit(c: *Compiler, at: u32, body: u32, exit: u32, greedy: bool) void {
        c.prog.items[at].split = if (greedy) .{ .first = body, .second = exit } else .{ .first = exit, .second = body };
    }
};

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

fn compileNew(it: *Interp, pat: []const u8, opts: Options) Error!*Regex {
    var c: Compiler = .{ .it = it, .src = pat, .opts = opts };
    // (?i) and its relatives at the start set options.
    if (std.mem.startsWith(u8, pat, "(?") and pat.len > 3) {
        if (std.mem.indexOfScalar(u8, pat, ')')) |end| {
            var ok = true;
            for (pat[2..end]) |f| ok = ok and std.ascii.isAlphabetic(f);
            if (ok) {
                for (pat[2..end]) |f| switch (f) {
                    'i' => c.opts.nocase = true,
                    'n' => c.opts.line = true,
                    else => {},
                };
                c.pos = end + 1;
            }
        }
    }
    const tree = try c.parseAlt();
    if (c.more()) return c.fail("parentheses () not balanced");
    _ = try c.add(.{ .save = 0 });
    try c.emit(tree);
    _ = try c.add(.{ .save = 1 });
    _ = try c.add(.match);
    const re = try it.alloc().create(Regex);
    re.* = .{ .prog = c.prog.items, .ncap = c.ncap, .nloop = c.nloop, .opts = c.opts };
    return re;
}

const Back = union(enum) {
    branch: struct { pc: u32, sp: usize },
    cap: struct { slot: u16, old: ?usize },
    loop: struct { slot: u16, old: usize },
};

/// The state of one search. `caps` has two entries for each group:
/// the start and the end, or null.
pub const Matcher = struct {
    it: *Interp,
    re: *const Regex,
    s: []const u8,
    caps: []?usize,
    loops: []usize,
    stack: std.ArrayList(Back) = .empty,
    steps: u32 = 0,

    pub fn init(it: *Interp, re: *const Regex, s: []const u8) Error!Matcher {
        return .{
            .it = it,
            .re = re,
            .s = s,
            .caps = try it.alloc().alloc(?usize, 2 * re.ncap),
            .loops = try it.alloc().alloc(usize, re.nloop),
        };
    }

    /// Finds the first match that starts at `from` or later.
    pub fn search(m: *Matcher, from: usize) Error!bool {
        var at = from;
        while (at <= m.s.len) : (at += 1) {
            if (try m.matchAt(at)) return true;
        }
        return false;
    }

    fn assertOk(m: *Matcher, a: Assert, sp: usize) bool {
        const s = m.s;
        const before = sp > 0 and isWord(s[sp - 1]);
        const after = sp < s.len and isWord(s[sp]);
        return switch (a) {
            .bol => sp == 0 or (m.re.opts.line and s[sp - 1] == '\n'),
            .eol => sp == s.len or (m.re.opts.line and s[sp] == '\n'),
            .text_start => sp == 0,
            .text_end => sp == s.len,
            .word_start => !before and after,
            .word_end => before and !after,
            .word_b => before != after,
            .not_word_b => before == after,
        };
    }

    fn matchAt(m: *Matcher, start: usize) Error!bool {
        const prog = m.re.prog;
        const s = m.s;
        const a = m.it.alloc();
        @memset(m.caps, null);
        m.stack.clearRetainingCapacity();
        var pc: u32 = 0;
        var sp = start;
        while (true) {
            m.steps += 1;
            if (m.steps >= 32) {
                m.steps = 0;
                if (m.it.fuel == 0) return m.it.fail("the script ran out of fuel", .{});
                m.it.fuel -= 1;
            }
            var ok = true;
            switch (prog[pc]) {
                .char => |ch| {
                    ok = sp < s.len and s[sp] == ch;
                    if (ok) sp += 1;
                },
                .any => {
                    ok = sp < s.len;
                    if (ok) sp = charEnd(s, sp);
                },
                .set => |set| {
                    ok = sp < s.len and hasBit(set, s[sp]);
                    if (ok) sp = charEnd(s, sp);
                },
                .assert => |as| ok = m.assertOk(as, sp),
                .save => |slot| {
                    try m.stack.append(a, .{ .cap = .{ .slot = slot, .old = m.caps[slot] } });
                    m.caps[slot] = sp;
                },
                .mark => |slot| {
                    try m.stack.append(a, .{ .loop = .{ .slot = slot, .old = m.loops[slot] } });
                    m.loops[slot] = sp;
                },
                .check => |slot| ok = m.loops[slot] != sp,
                .backref => |k| {
                    const lo = m.caps[2 * @as(usize, k)];
                    const hi = m.caps[2 * @as(usize, k) + 1];
                    if (lo != null and hi != null) {
                        const text = s[lo.?..hi.?];
                        ok = std.mem.startsWith(u8, s[sp..], text);
                        if (ok) sp += text.len;
                    } else ok = false;
                },
                .jmp => |to| {
                    pc = to;
                    continue;
                },
                .split => |sp2| {
                    if (m.stack.items.len >= max_stack) return m.it.fail("the regular expression needs too much memory", .{});
                    try m.stack.append(a, .{ .branch = .{ .pc = sp2.second, .sp = sp } });
                    pc = sp2.first;
                    continue;
                },
                .match => return true,
            }
            if (ok) {
                pc += 1;
                continue;
            }
            // Go back to the last branch, and undo the saves on the way.
            while (true) {
                const b = m.stack.pop() orelse return false;
                switch (b) {
                    .cap => |c| m.caps[c.slot] = c.old,
                    .loop => |l| m.loops[l.slot] = l.old,
                    .branch => |br| {
                        pc = br.pc;
                        sp = br.sp;
                        break;
                    },
                }
            }
        }
    }
};

/// The end of the character that starts at `i`.
fn charEnd(s: []const u8, i: usize) usize {
    var e = i + 1;
    if (s[i] >= 0xC0) {
        while (e < s.len and s[e] & 0xC0 == 0x80) e += 1;
    }
    return e;
}

/// True when the pattern matches a part of the string.
pub fn matches(it: *Interp, pat: []const u8, s: []const u8, nocase: bool) Error!bool {
    const re = try compile(it, pat, .{ .nocase = nocase });
    var m = try Matcher.init(it, re, s);
    return m.search(0);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn capValue(it: *Interp, m: *const Matcher, k: usize, indices: bool) Error!Value {
    const lo = if (k < m.re.ncap) m.caps[2 * k] else null;
    const hi = if (k < m.re.ncap) m.caps[2 * k + 1] else null;
    if (lo == null or hi == null) {
        if (!indices) return Value.empty;
        return value.newList(it.alloc(), &.{ .{ .int = -1 }, .{ .int = -1 } });
    }
    if (!indices) return .{ .str = m.s[lo.?..hi.?] };
    return value.newList(it.alloc(), &.{ .{ .int = @intCast(lo.?) }, .{ .int = @as(i64, @intCast(hi.?)) - 1 } });
}

pub fn cmdRegexp(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var opts: Options = .{};
    var all = false;
    var inl = false;
    var indices = false;
    var start: usize = 0;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (o.len == 0 or o[0] != '-') break;
        if (eql(o, "--")) {
            i += 1;
            break;
        } else if (eql(o, "-nocase")) {
            opts.nocase = true;
        } else if (eql(o, "-line") or eql(o, "-lineanchor") or eql(o, "-linestop")) {
            opts.line = true;
        } else if (eql(o, "-all")) {
            all = true;
        } else if (eql(o, "-inline")) {
            inl = true;
        } else if (eql(o, "-indices")) {
            indices = true;
        } else if (eql(o, "-expanded") or eql(o, "-about")) {
            return it.fail("the option \"{s}\" of regexp is not supported", .{o});
        } else if (eql(o, "-start")) {
            i += 1;
            if (i >= argv.len) return it.fail("missing starting index", .{});
            const n = try it.int(argv[i]);
            start = if (n < 0) 0 else @intCast(n);
        } else return it.fail("bad option \"{s}\": must be -all, -about, -indices, -inline, -expanded, -line, -linestop, -lineanchor, -nocase, -start, or --", .{o});
    }
    if (argv.len < i + 2) return it.wrongArgs("regexp ?-option ...? exp string ?matchVar? ?subMatchVar ...?");
    const vars = argv[i + 2 ..];
    if (inl and vars.len > 0) return it.fail("regexp match variables not allowed when using -inline", .{});
    const re = try compile(it, try it.str(argv[i]), opts);
    const s = try it.str(argv[i + 1]);
    var m = try Matcher.init(it, re, s);
    var out: std.ArrayList(Value) = .empty;
    var count: i64 = 0;
    var at = @min(start, s.len);
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
        at = if (hi == lo) hi + 1 else hi;
    }
    if (inl) return value.wrapList(it.alloc(), out.items);
    return .{ .int = count };
}

pub fn cmdRegsub(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var opts: Options = .{};
    var all = false;
    var start: usize = 0;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (o.len == 0 or o[0] != '-') break;
        if (eql(o, "--")) {
            i += 1;
            break;
        } else if (eql(o, "-nocase")) {
            opts.nocase = true;
        } else if (eql(o, "-line") or eql(o, "-lineanchor") or eql(o, "-linestop")) {
            opts.line = true;
        } else if (eql(o, "-all")) {
            all = true;
        } else if (eql(o, "-start")) {
            i += 1;
            if (i >= argv.len) return it.fail("missing starting index", .{});
            const n = try it.int(argv[i]);
            start = if (n < 0) 0 else @intCast(n);
        } else return it.fail("bad option \"{s}\": must be -all, -nocase, -expanded, -line, -linestop, -lineanchor, -start, or --", .{o});
    }
    if (argv.len != i + 3 and argv.len != i + 4) return it.wrongArgs("regsub ?-option ...? exp string subSpec ?varName?");
    const a = it.alloc();
    const re = try compile(it, try it.str(argv[i]), opts);
    const s = try it.str(argv[i + 1]);
    const spec = try it.str(argv[i + 2]);
    var m = try Matcher.init(it, re, s);
    var out: std.ArrayList(u8) = .empty;
    var count: i64 = 0;
    var at = @min(start, s.len);
    var copied: usize = 0;
    while (at <= s.len) {
        if (!try m.search(at)) break;
        count += 1;
        const lo = m.caps[0].?;
        const hi = m.caps[1].?;
        try out.appendSlice(a, s[copied..lo]);
        var k: usize = 0;
        while (k < spec.len) : (k += 1) {
            const ch = spec[k];
            var group: ?usize = null;
            if (ch == '&') {
                group = 0;
            } else if (ch == '\\' and k + 1 < spec.len) {
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
            } else try out.append(a, ch);
        }
        copied = hi;
        if (hi == lo) {
            if (lo < s.len) try out.append(a, s[lo]);
            copied = @min(lo + 1, s.len);
            at = lo + 1;
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

//! Stage 2 of the JSON parser: Tcl values from the structural index.
//!
//! The JSON parser of ztcl implements the simdjson algorithm in Zig
//! (https://github.com/simdjson/simdjson, see docs/references/stdlib.md).
//! Stage 1 (`index.zig`) gives the positions of the operators and of the
//! first byte of each scalar. This stage walks the positions with a loop
//! and a stack of open containers, so the depth of the input uses no
//! native stack. It checks the grammar at each position:
//!
//! - An object is a dict: a list of keys and values with the mark of a
//!   valid dict. A key that comes again keeps its first place and gets
//!   the last value, as `dict create` does. A small object compares the
//!   keys directly, and a larger one uses a hash table of the keys.
//! - An array is a list. Each container gets one buffer of its final
//!   size when it closes.
//! - A string with no escape is a slice of the input, so it has no copy.
//!   A string with escapes is a new string. A lone surrogate of `\u`
//!   becomes U+FFFD.
//! - A number follows the rules of `expr`: an integer that fits in 64
//!   bits is an int, a larger integer is its decimal text (a big
//!   integer), and other numbers are doubles. A double with at most 19
//!   digits and a small exponent is exact with one multiply or divide of
//!   a power of ten. Other doubles with at most 19 digits use the
//!   Eisel-Lemire step of `number.zig` on the parsed mantissa. The rest
//!   use `std.fmt.parseFloat`, which has an exact fallback.
//! - `true` and `false` are strings. `null` is an error unless the
//!   caller gives a value for it.
//!
//! The same walk with `mode = .validate` makes no value, and the path
//! walk of `get` skips each value that is not on the path with a count
//! of the brackets.
//!
//! Limits: the depth (512 by default), the bytes of a number (1 MiB),
//! and the step limit and the memory limit of the interpreter. Stage 1
//! runs in chunks of 64 KiB. After each chunk, the parse pays one step
//! for each 4096 bytes and one step for each value that it made, and it
//! checks the memory limit.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const index = @import("index.zig");
const number_mod = @import("number.zig");
const interp = @import("../interp.zig");
const value = @import("../value.zig");
const Interp = interp.Interp;
const Error = interp.Error;
const Value = value.Value;

pub const Options = struct {
    /// The value of `null`, or null for an error.
    null_value: ?Value = null,
    max_depth: u32 = 512,
    max_number: usize = 1 << 20,
    /// Use the scalar form of stage 1.
    scalar: bool = false,
    /// Make the typed tree of `parse -typed`.
    typed: bool = false,
    /// Keep the text of each number, as tcllib does.
    number_text: bool = false,
    /// Accept the numbers `1.` and `.1`, as tcllib does.
    lenient: bool = false,
};

const Kind = enum { build, validate };

/// The bytes that end a scalar: white space and the operators.
const ends = blk: {
    var t: [256]bool = @splat(false);
    for (" \t\r\n{}[]:,") |c| t[c] = true;
    break :blk t;
};

/// Stage 1 in chunks, with a safe point after each chunk.
pub const Stream = struct {
    it: *Interp,
    input: []const u8,
    vec: index.Indexer,
    sca: index.Scalar,
    scalar: bool,
    buf: []u32,
    n: usize = 0,
    i: usize = 0,
    /// The values made since the last safe point.
    made: usize = 0,
    /// The quote and backslash masks of the chunk of the vector form.
    masks: *[2][index.chunk_blocks]u64,
    /// The bytes that the masks cover.
    mask_start: usize = 0,
    mask_end: usize = 0,

    pub fn init(it: *Interp, input: []const u8, scalar: bool) Error!Stream {
        return .{
            .it = it,
            .input = input,
            .vec = index.Indexer.init(input),
            .sca = index.Scalar.init(input),
            .scalar = scalar,
            .buf = try it.alloc().alloc(u32, index.buf_len),
            .masks = try it.alloc().create([2][index.chunk_blocks]u64),
        };
    }

    /// Starts stage 1 again at the first byte of a value.
    pub fn restartAt(s: *Stream, at: u32) void {
        s.vec = index.Indexer.init(s.input);
        s.vec.pos = at;
        s.sca = index.Scalar.init(s.input);
        s.sca.pos = at;
        s.n = 0;
        s.i = 0;
        s.mask_end = 0;
    }

    /// The closing quote of the string that starts at `at`, when the masks
    /// of the chunk have it and no backslash comes before it. Else null.
    pub inline fn plainString(s: *const Stream, at: usize) ?usize {
        const from = at + 1;
        if (from < s.mask_start or from >= s.mask_end) return null;
        var k = (from - s.mask_start) / 64;
        const shift: u6 = @intCast((from - s.mask_start) % 64);
        var q = s.masks[0][k] & (~@as(u64, 0) << shift);
        var b = s.masks[1][k] & (~@as(u64, 0) << shift);
        const blocks = (s.mask_end - s.mask_start + 63) / 64;
        while (q == 0) {
            if (b != 0) return null;
            k += 1;
            if (k >= blocks) return null;
            q = s.masks[0][k];
            b = s.masks[1][k];
        }
        const end_bit = @ctz(q);
        // A backslash before the quote.
        if (b & ((@as(u64, 1) << @intCast(end_bit)) -% 1) != 0) return null;
        return s.mask_start + k * 64 + end_bit;
    }

    /// The next structural position, or null at the end of the input.
    pub inline fn next(s: *Stream) Error!?u32 {
        if (s.i < s.n) {
            const p = s.buf[s.i];
            s.i += 1;
            return p;
        }
        return s.refill();
    }

    fn refill(s: *Stream) Error!?u32 {
        while (true) {
            const done = if (s.scalar) s.sca.done() else s.vec.done();
            const fault = if (s.scalar) s.sca.fault else s.vec.fault;
            if (fault != .none) return s.faultError(fault);
            if (done) return null;
            const before = if (s.scalar) s.sca.pos else s.vec.pos;
            if (!s.scalar) {
                s.vec.quote_masks = &s.masks[0];
                s.vec.bs_masks = &s.masks[1];
            }
            s.n = if (s.scalar) s.sca.next(s.buf) else s.vec.next(s.buf);
            s.i = 0;
            const after = if (s.scalar) s.sca.pos else s.vec.pos;
            if (!s.scalar) {
                s.mask_start = before;
                s.mask_end = after;
            }
            try s.pay(after - before);
            const f2 = if (s.scalar) s.sca.fault else s.vec.fault;
            if (f2 != .none) return s.faultError(f2);
            if (s.n > 0) {
                s.i = 1;
                return s.buf[0];
            }
        }
    }

    /// The safe point: steps for the bytes and the values, and the
    /// memory limit.
    pub fn pay(s: *Stream, bytes: usize) Error!void {
        const it = s.it;
        const cost = bytes / 4096 + s.made + 1;
        s.made = 0;
        if (cost > it.step_limit) {
            it.step_limit = 0;
            return it.fail("step limit reached", .{});
        }
        it.step_limit -= cost;
        if (it.overLimit()) return it.memError();
    }

    fn faultError(s: *Stream, f: index.Fault) Error {
        const at = if (s.scalar) s.sca.fault_at else s.vec.fault_at;
        return syntax(s.it, s.input, at, switch (f) {
            .utf8 => "invalid UTF-8",
            .control => "control character in a string",
            .unclosed => "unclosed string",
            .too_large => "input of 4 GiB or more",
            .escape => "bad escape",
            .none => unreachable,
        });
    }
};

/// A syntax error with its line and column.
pub fn syntax(it: *Interp, input: []const u8, at_in: usize, msg: []const u8) Error {
    const at = @min(at_in, input.len);
    var line: usize = 1;
    var col: usize = 1;
    for (input[0..at]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else if (c & 0xC0 != 0x80) col += 1;
    }
    const code = try std.fmt.allocPrint(it.alloc(), "ZT JSON SYNTAX {d} {d}", .{ line, col });
    return it.failCode(code, "json syntax error at line {d}, column {d}: {s}", .{ line, col, msg });
}

const Frame = struct { start: u32, object: bool };

pub fn Parser(comptime kind: Kind) type {
    return struct {
        const Self = @This();
        it: *Interp,
        input: []const u8,
        s: Stream,
        opts: Options,
        vals: std.ArrayList(Value) = .empty,
        /// The stack of open containers, `max_depth` long.
        frames: []Frame,
        depth: usize = 0,
        /// The hash table of the keys of one large object.
        table: []u32 = &.{},

        pub fn init(it: *Interp, input: []const u8, opts: Options) Error!Self {
            return .{ .it = it, .input = input, .s = try Stream.init(it, input, opts.scalar), .opts = opts, .frames = try it.alloc().alloc(Frame, opts.max_depth) };
        }

        fn err(p: *Self, at: usize, msg: []const u8) Error {
            return syntax(p.it, p.input, at, msg);
        }

        /// The whole input as one value.
        pub fn document(p: *Self) Error!Value {
            const first = (try p.s.next()) orelse return p.err(p.input.len, "no value");
            const v = try p.valueAt(first);
            if (try p.s.next()) |extra| return p.err(extra, "text after the value");
            return v;
        }

        /// The value that starts at the position `first`. The walk ends
        /// after the value, so the caller can go on with the stream.
        pub fn valueAt(p: *Self, first: u32) Error!Value {
            p.vals.clearRetainingCapacity();
            p.depth = 0;
            var at: u32 = first;
            // The loop has two states: `value` reads a value at `at`, and
            // `after` reads what follows a value in its container.
            state: switch (@as(enum { value, after }, .value)) {
                .value => {
                    const c = p.input[at];
                    switch (c) {
                        '{', '[' => {
                            if (p.depth >= p.opts.max_depth) {
                                return p.it.failCode("ZT JSON DEPTH", "json nesting is deeper than {d}", .{p.opts.max_depth});
                            }
                            const object = c == '{';
                            p.frames[p.depth] = .{ .start = @intCast(p.vals.items.len), .object = object };
                            p.depth += 1;
                            const n = (try p.s.next()) orelse return p.err(p.input.len, "unclosed container");
                            if (p.input[n] == (if (object) @as(u8, '}') else ']')) {
                                try p.close();
                                continue :state .after;
                            }
                            if (object) {
                                try p.key(n);
                                at = (try p.s.next()) orelse return p.err(p.input.len, "unclosed object");
                            } else at = n;
                            continue :state .value;
                        },
                        '"' => try p.push(try p.tag("string", try p.string(at))),
                        't' => try p.push(try p.tag("bool", try p.literal(at, "true", .{ .str = "true" }))),
                        'f' => try p.push(try p.tag("bool", try p.literal(at, "false", .{ .str = "false" }))),
                        'n' => {
                            _ = try p.literal(at, "null", Value.empty);
                            const nv = p.opts.null_value orelse if (p.opts.typed) Value.empty else {
                                const e = p.err(at, "null needs the option -null");
                                p.it.error_code = .{ .str = "ZT JSON NULL" };
                                return e;
                            };
                            try p.push(if (p.opts.typed) Value{ .str = "null" } else nv);
                        },
                        '-', '0'...'9' => try p.push(try p.tag("number", try p.number(at))),
                        '.' => {
                            if (!p.opts.lenient) return p.err(at, "unexpected character");
                            try p.push(try p.tag("number", try p.number(at)));
                        },
                        else => return p.err(at, "unexpected character"),
                    }
                    continue :state .after;
                },
                .after => {
                    if (p.depth == 0) {
                        if (kind == .build) return p.vals.items[0];
                        return Value.empty;
                    }
                    const n = (try p.s.next()) orelse return p.err(p.input.len, "unclosed container");
                    const f = p.frames[p.depth - 1];
                    switch (p.input[n]) {
                        ',' => {
                            const n2 = (try p.s.next()) orelse return p.err(p.input.len, "value expected");
                            if (f.object) {
                                try p.key(n2);
                                at = (try p.s.next()) orelse return p.err(p.input.len, "value expected");
                            } else at = n2;
                            continue :state .value;
                        },
                        '}' => {
                            if (!f.object) return p.err(n, "\"]\" expected");
                            try p.close();
                            continue :state .after;
                        },
                        ']' => {
                            if (f.object) return p.err(n, "\"}\" expected");
                            try p.close();
                            continue :state .after;
                        },
                        else => return p.err(n, if (f.object) "\",\" or \"}\" expected" else "\",\" or \"]\" expected"),
                    }
                },
            }
        }

        /// The pair {TAG VALUE} of the typed tree, or the value.
        inline fn tag(p: *Self, comptime name: []const u8, v: Value) Error!Value {
            if (kind == .validate or !p.opts.typed) return v;
            const buf = try p.it.alloc().alloc(Value, 2);
            buf[0] = .{ .str = name };
            buf[1] = if (std.mem.eql(u8, name, "number")) try numberText(p.it, v) else v;
            return value.wrapList(p.it.alloc(), buf);
        }

        inline fn push(p: *Self, v: Value) Error!void {
            if (kind == .build) {
                if (p.vals.items.len == p.vals.capacity) try p.grow();
                p.vals.appendAssumeCapacity(v);
            }
            p.s.made += 1;
        }

        /// The value stack grows as an ArrayList grows.
        noinline fn grow(p: *Self) Error!void {
            @branchHint(.cold);
            try p.vals.ensureUnusedCapacity(p.it.alloc(), 1);
        }

        /// A key and its colon.
        fn key(p: *Self, at: u32) Error!void {
            if (p.input[at] != '"') return p.err(at, "a string key expected");
            try p.push(try p.string(at));
            const c = (try p.s.next()) orelse return p.err(p.input.len, "\":\" expected");
            if (p.input[c] != ':') return p.err(c, "\":\" expected");
        }

        fn close(p: *Self) Error!void {
            p.depth -= 1;
            const f = p.frames[p.depth];
            if (kind == .validate) {
                return;
            }
            const a = p.it.alloc();
            const items = p.vals.items[f.start..];
            var v = if (f.object) try p.makeDict(items) else blk: {
                const buf = try a.alloc(Value, items.len);
                @memcpy(buf, items);
                break :blk try value.wrapList(a, buf);
            };
            if (p.opts.typed) {
                const buf = try a.alloc(Value, 2);
                buf[0] = .{ .str = if (f.object) "object" else "array" };
                buf[1] = v;
                v = try value.wrapList(a, buf);
            }
            p.vals.items.len = f.start;
            if (p.vals.items.len == p.vals.capacity) try p.grow();
            p.vals.appendAssumeCapacity(v);
            p.s.made += 1;
        }

        /// A dict from pairs. A key that comes again keeps its first place
        /// and gets the last value.
        fn makeDict(p: *Self, pairs: []const Value) Error!Value {
            const a = p.it.alloc();
            const out = try a.alloc(Value, pairs.len);
            var m: usize = 0;
            const n = pairs.len / 2;
            if (n <= 8) {
                var i: usize = 0;
                outer: while (i < pairs.len) : (i += 2) {
                    const k = pairs[i].str;
                    var j: usize = 0;
                    while (j < m) : (j += 2) {
                        if (std.mem.eql(u8, out[j].str, k)) {
                            out[j + 1] = pairs[i + 1];
                            continue :outer;
                        }
                    }
                    out[m] = pairs[i];
                    out[m + 1] = pairs[i + 1];
                    m += 2;
                }
            } else {
                var size: usize = 16;
                while (size < n * 2) size *= 2;
                if (p.table.len < size) p.table = try a.alloc(u32, size);
                const t = p.table[0..size];
                @memset(t, 0);
                var probes: usize = 0;
                var i: usize = 0;
                outer: while (i < pairs.len) : (i += 2) {
                    const k = pairs[i].str;
                    var h = hashKey(k) & (size - 1);
                    while (t[h] != 0) {
                        const j = t[h] - 1;
                        if (std.mem.eql(u8, out[j].str, k)) {
                            out[j + 1] = pairs[i + 1];
                            continue :outer;
                        }
                        h = (h + 1) & (size - 1);
                        probes += 1;
                    }
                    t[h] = @intCast(m + 1);
                    out[m] = pairs[i];
                    out[m + 1] = pairs[i + 1];
                    m += 2;
                }
                // A long probe pays steps, as each table entry does.
                p.s.made += probes / 16;
            }
            const obj = try a.create(value.ListObj);
            obj.* = .{ .buf = out, .used = m, .dict_len = m };
            return .{ .list = .{ .obj = obj, .len = m } };
        }

        fn hashKey(k: []const u8) usize {
            // A short key reads its bytes as a number. A longer key uses
            // Wyhash.
            if (k.len <= 8) {
                var w: u64 = 0;
                @memcpy(std.mem.asBytes(&w)[0..k.len], k);
                const x = (w ^ k.len) *% 0x9E37_79B9_7F4A_7C15;
                return @truncate(x >> 29);
            }
            return @truncate(std.hash.Wyhash.hash(0x6a736f6e, k));
        }

        fn literal(p: *Self, at: u32, word: []const u8, v: Value) Error!Value {
            const end = at + word.len;
            if (end > p.input.len or !std.mem.eql(u8, p.input[at..end], word)) return p.err(at, "unexpected word");
            if (end < p.input.len and !ends[p.input[end]]) return p.err(end, "unexpected character after a word");
            return v;
        }

        /// The string of the quote at `at`.
        pub fn string(p: *Self, at: u32) Error!Value {
            const in = p.input;
            const start = at + 1;
            // The vector form of stage 1 checked the escapes, so a check
            // needs no walk of the string.
            if (kind == .validate and !p.s.scalar) return Value.empty;
            if (p.s.plainString(at)) |end| {
                if (kind == .validate) return Value.empty;
                return .{ .str = in[start..end] };
            }
            var i = findQuoteOrBackslash(in, start);
            if (i >= in.len) return p.err(in.len, "unclosed string");
            if (in[i] == '"') return .{ .str = in[start..i] };
            // A string with escapes.
            var out: std.ArrayList(u8) = .empty;
            const a = p.it.alloc();
            if (kind == .build) try out.ensureTotalCapacity(a, (i - start) + 16);
            var from: usize = start;
            while (true) {
                if (kind == .build) try out.appendSlice(a, in[from..i]);
                if (in[i] == '"') break;
                // in[i] is a backslash.
                if (i + 1 >= in.len) return p.err(in.len, "unclosed string");
                const e = in[i + 1];
                var adv: usize = 2;
                const ch: u8 = switch (e) {
                    '"' => '"',
                    '\\' => '\\',
                    '/' => '/',
                    'b' => 8,
                    'f' => 12,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'u' => 0,
                    else => return p.err(i, "bad escape"),
                };
                if (e == 'u') {
                    var cp: u21 = try p.hex4(i + 2);
                    adv = 6;
                    if (cp >= 0xD800 and cp <= 0xDBFF) {
                        if (i + 12 <= in.len and in[i + 6] == '\\' and in[i + 7] == 'u') {
                            const lo = try p.hex4(i + 8);
                            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                adv = 12;
                            } else cp = 0xFFFD;
                        } else cp = 0xFFFD;
                    } else if (cp >= 0xDC00 and cp <= 0xDFFF) cp = 0xFFFD;
                    if (kind == .build) {
                        var b: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &b) catch unreachable;
                        try out.appendSlice(a, b[0..len]);
                    }
                } else if (kind == .build) try out.append(a, ch);
                from = i + adv;
                i = findQuoteOrBackslash(in, from);
                if (i >= in.len) return p.err(in.len, "unclosed string");
            }
            if (kind == .validate) return Value.empty;
            return .{ .str = out.items };
        }

        fn hex4(p: *Self, at: usize) Error!u21 {
            if (at + 4 > p.input.len) return p.err(at, "bad \\u escape");
            var v: u21 = 0;
            for (p.input[at .. at + 4]) |c| {
                const d: u21 = switch (c) {
                    '0'...'9' => c - '0',
                    'a'...'f' => c - 'a' + 10,
                    'A'...'F' => c - 'A' + 10,
                    else => return p.err(at, "bad \\u escape"),
                };
                v = v * 16 + d;
            }
            return v;
        }

        /// The number at `at`.
        pub fn number(p: *Self, at: u32) Error!Value {
            const in = p.input;
            var i: usize = at;
            const neg = in[i] == '-';
            if (neg) i += 1;
            const lenient_dot = p.opts.lenient and i < in.len and in[i] == '.';
            if (!lenient_dot and (i >= in.len or !isDigit(in[i]))) return p.err(i, "a digit expected");
            var mant: u64 = 0;
            var digits: usize = 0;
            if (lenient_dot) {} else if (in[i] == '0') {
                i += 1;
            } else {
                while (i < in.len and isDigit(in[i])) : (i += 1) {
                    if (digits < 19) mant = mant * 10 + (in[i] - '0');
                    digits += 1;
                }
            }
            const int_digits = digits;
            var float = false;
            var frac: usize = 0;
            if (i < in.len and in[i] == '.') {
                float = true;
                i += 1;
                if (!p.opts.lenient and (i >= in.len or !isDigit(in[i]))) return p.err(i, "a digit expected after \".\"");
                while (i < in.len and isDigit(in[i])) : (i += 1) {
                    if (digits < 19) {
                        mant = mant * 10 + (in[i] - '0');
                        frac += 1;
                    }
                    // Zeros at the start of the fraction do not count as
                    // digits of the mantissa.
                    if (mant != 0) digits += 1;
                }
            }
            var exp: i64 = 0;
            if (i < in.len and (in[i] == 'e' or in[i] == 'E')) {
                float = true;
                i += 1;
                var eneg = false;
                if (i < in.len and (in[i] == '+' or in[i] == '-')) {
                    eneg = in[i] == '-';
                    i += 1;
                }
                if (i >= in.len or !isDigit(in[i])) return p.err(i, "a digit expected in the exponent");
                while (i < in.len and isDigit(in[i])) : (i += 1) {
                    if (exp < 100_000) exp = exp * 10 + (in[i] - '0');
                }
                if (eneg) exp = -exp;
            }
            if (i < in.len and !ends[in[i]]) return p.err(i, "unexpected character after a number");
            if (i - at > p.opts.max_number) {
                return p.it.failCode("ZT JSON NUMBER", "json number has more than {d} bytes", .{p.opts.max_number});
            }
            if (kind == .validate) return Value.empty;
            const text = in[at..i];
            if (p.opts.number_text or p.opts.typed) return .{ .str = text };
            if (!float) {
                if (int_digits <= 19) {
                    if (neg) {
                        if (mant <= @as(u64, 1) << 63) return .{ .int = @bitCast(0 -% mant) };
                    } else if (mant <= std.math.maxInt(i64)) return .{ .int = @intCast(mant) };
                }
                // A big integer: the decimal text, which is canonical.
                return .{ .str = text };
            }
            const e10 = exp - @as(i64, @intCast(frac));
            if (digits <= 19 and mant <= (1 << 53) and e10 >= -22 and e10 <= 22) {
                var d: f64 = @floatFromInt(mant);
                if (e10 < 0) d /= pow10[@intCast(-e10)] else d *= pow10[@intCast(e10)];
                return .{ .double = if (neg) -d else d };
            }
            // The mantissa has each digit, so the Eisel-Lemire step needs no
            // second read of the text.
            if (digits <= 19 and mant != 0) {
                if (number_mod.eiselLemire(mant, e10, neg)) |d| return .{ .double = d };
            }
            const d = std.fmt.parseFloat(f64, text) catch return p.err(at, "bad number");
            return .{ .double = d };
        }
    };
}

const pow10 = blk: {
    var t: [23]f64 = undefined;
    var x: f64 = 1;
    for (&t) |*e| {
        e.* = x;
        x *= 10;
    }
    break :blk t;
};

inline fn isDigit(c: u8) bool {
    return c -% '0' < 10;
}

/// The place of the next quote or backslash at or after `from`, or the
/// length of the input.
fn findQuoteOrBackslash(in: []const u8, from: usize) usize {
    const W = @Vector(32, u8);
    var i = from;
    while (i + 32 <= in.len) : (i += 32) {
        const v: W = in[i..][0..32].*;
        const m: u32 = @bitCast((v == @as(W, @splat('"'))) | (v == @as(W, @splat('\\'))));
        if (m != 0) return i + @ctz(m);
    }
    while (i < in.len) : (i += 1) {
        if (in[i] == '"' or in[i] == '\\') return i;
    }
    return in.len;
}

fn numberText(it: *Interp, v: Value) Error!Value {
    return .{ .str = try it.str(v) };
}

/// Parses a sequence of JSON texts, as `json::many-json2dict` does.
pub fn parseMany(it: *Interp, input: []const u8, opts: Options) Error!Value {
    var p = try Parser(.build).init(it, input, opts);
    var out: std.ArrayList(Value) = .empty;
    while (try p.s.next()) |first| {
        try out.append(it.alloc(), try p.valueAt(first));
    }
    try p.s.pay(0);
    return value.wrapList(it.alloc(), out.items);
}

/// Parses a JSON text to a Tcl value.
pub fn parse(it: *Interp, input: []const u8, opts: Options) Error!Value {
    var p = try Parser(.build).init(it, input, opts);
    const v = try p.document();
    try p.s.pay(0);
    return v;
}

/// Checks a JSON text. Gives null when it is valid, or the error.
pub fn validate(it: *Interp, input: []const u8, opts: Options) Error!void {
    var o = opts;
    if (o.null_value == null) o.null_value = Value.empty;
    var p = try Parser(.validate).init(it, input, o);
    _ = try p.document();
    try p.s.pay(0);
}

/// The value at a path, with no build of the other values. A step is a
/// key in an object and a decimal index in an array. Gives null when the
/// path has no value. The walk checks only the brackets of the values
/// that it skips.
pub fn get(it: *Interp, input: []const u8, path: []const []const u8, opts: Options) Error!?Value {
    var p = try Parser(.build).init(it, input, opts);
    var at: u32 = (try p.s.next()) orelse return p.err(input.len, "no value");
    for (path) |step| {
        const c = input[at];
        if (c == '{') {
            const k = step;
            {
                var found: ?u32 = null;
                var n = (try p.s.next()) orelse return p.err(input.len, "unclosed object");
                if (input[n] == '}') return null;
                while (true) {
                    if (input[n] != '"') return p.err(n, "a string key expected");
                    const kv = try p.string(n);
                    const colon = (try p.s.next()) orelse return p.err(input.len, "\":\" expected");
                    if (input[colon] != ':') return p.err(colon, "\":\" expected");
                    const v = (try p.s.next()) orelse return p.err(input.len, "value expected");
                    const hit = std.mem.eql(u8, kv.str, k);
                    if (hit) found = v;
                    // The last value of a key wins, as in a dict, so the
                    // walk reads each key of the object.
                    try skip(&p, v);
                    const sep = (try p.s.next()) orelse return p.err(input.len, "unclosed object");
                    if (input[sep] == '}') break;
                    if (input[sep] != ',') return p.err(sep, "\",\" or \"}\" expected");
                    n = (try p.s.next()) orelse return p.err(input.len, "unclosed object");
                }
                at = found orelse return null;
                // Stage 1 starts again at the found value. Before a value
                // the state is known: no string, no escape, no scalar.
                p.s.restartAt(at);
                _ = try p.s.next();
            }
        } else if (c == '[') {
            const want = std.fmt.parseInt(usize, step, 10) catch return null;
            {
                var n = (try p.s.next()) orelse return p.err(input.len, "unclosed array");
                if (input[n] == ']') return null;
                var k: usize = 0;
                while (k < want) : (k += 1) {
                    try skip(&p, n);
                    const sep = (try p.s.next()) orelse return p.err(input.len, "unclosed array");
                    if (input[sep] == ']') return null;
                    if (input[sep] != ',') return p.err(sep, "\",\" or \"]\" expected");
                    n = (try p.s.next()) orelse return p.err(input.len, "unclosed array");
                }
                at = n;
            }
        } else return null;
    }
    const v = try p.valueAt(at);
    try p.s.pay(0);
    return v;
}

/// Skips the value at `at`: a scalar is one position, and a container
/// ends at its closing bracket.
fn skip(p: *Parser(.build), at: u32) Error!void {
    const c = p.input[at];
    if (c != '{' and c != '[') return;
    var depth: usize = 1;
    while (depth > 0) {
        const q = (try p.s.next()) orelse return p.err(p.input.len, "unclosed container");
        switch (p.input[q]) {
            '{', '[' => depth += 1,
            '}', ']' => depth -= 1,
            else => {},
        }
    }
}

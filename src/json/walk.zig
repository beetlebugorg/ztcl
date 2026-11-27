//! The four hot functions of the JSON walk of `build.zig`: `valueAt`,
//! `key`, `string`, and `number`. Native builds give each one a start
//! that is a multiple of `hot_align` bytes. A shift of 16 bytes in the
//! start of `valueAt` made the validate of canada.json 13 % slower with
//! the same instruction count (issue 67).
//!
//! WebAssembly has no function alignment, and Zig gives an error for an
//! `align` on a function of a wasm target. `walk_wasm.zig` is this file
//! without the `align(hot_align)` of each function, and the wasm builds
//! use it. Edit this file only, then make the copy again with
//! `tools/json-walk-wasm.sh`. A unit test checks that the two files
//! agree.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const value = @import("../value.zig");
const number_mod = @import("number.zig");
const build = @import("build.zig");
const Error = @import("../interp.zig").Error;
const Value = value.Value;
const Frame = build.Frame;
const ends = build.ends;
const pow10 = build.pow10;
const isDigit = build.isDigit;
const findQuoteOrBackslash = build.findQuoteOrBackslash;
const numberText = build.numberText;

/// The start alignment of the hot functions on native targets.
const hot_align = 32;

pub fn Walk(comptime kind: build.Kind, comptime Self: type) type {
    return struct {
        /// The value that starts at the position `first`. The walk ends
        /// after the value, so the caller can go on with the stream.
        pub fn valueAt(p: *Self, first: u32) align(hot_align) Error!Value {
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

        /// A key and its colon.
        pub fn key(p: *Self, at: u32) align(hot_align) Error!void {
            if (p.input[at] != '"') return p.err(at, "a string key expected");
            try p.push(try p.string(at));
            const c = (try p.s.next()) orelse return p.err(p.input.len, "\":\" expected");
            if (p.input[c] != ':') return p.err(c, "\":\" expected");
        }

        /// The string of the quote at `at`.
        pub fn string(p: *Self, at: u32) align(hot_align) Error!Value {
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

        /// The number at `at`.
        pub fn number(p: *Self, at: u32) align(hot_align) Error!Value {
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

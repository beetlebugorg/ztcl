//! Values of the Tcl interpreter.
//!
//! A value is an integer, a double, a string, or a list. Each kind has
//! one exact string form, and `toStr` makes that string only on demand.
//! A script cannot see the kind: `toStr` of a value, parsed again, gives
//! an equal value.
//!
//! A literal keeps its text. `0x10` stays the string "0x10" until a
//! command reads it as a number. Only a computed number is an int or a
//! double, and its string form is the canonical one.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    int: i64,
    double: f64,
    str: []const u8,
    list: List,

    pub const empty: Value = .{ .str = "" };

    /// The string form. An int, a double, or a list allocates in `a`.
    pub inline fn toStr(v: Value, a: Allocator) Allocator.Error![]const u8 {
        if (v == .str) return v.str;
        return v.toStrSlow(a);
    }

    fn toStrSlow(v: Value, a: Allocator) Allocator.Error![]const u8 {
        return switch (v) {
            .str => |s| s,
            .int => |i| blk: {
                var buf: [24]u8 = undefined;
                break :blk a.dupe(u8, writeInt(&buf, i));
            },
            .double => |d| formatDouble(a, d),
            .list => |l| listToString(a, l.items()),
        };
    }

    /// The integer value, or null if the string form is not an integer.
    pub fn asInt(v: Value) ?i64 {
        return switch (v) {
            .int => |i| i,
            .double => null,
            .str => |s| parseInt(s),
            .list => |l| if (l.len == 1) l.items()[0].asInt() else null,
        };
    }

    /// The number value (an int or a double), or null.
    pub fn asNumber(v: Value) ?Value {
        switch (v) {
            .int, .double => return v,
            .str => |s| {
                if (parseInt(s)) |i| return .{ .int = i };
                if (parseDouble(s)) |d| return .{ .double = d };
                return null;
            },
            .list => |l| return if (l.len == 1) l.items()[0].asNumber() else null,
        }
    }

    /// The elements of the value as a list. A string is parsed.
    pub fn asList(v: Value, a: Allocator) ListError![]const Value {
        switch (v) {
            .list => |l| return l.items(),
            .int, .double => {
                const one = try a.alloc(Value, 1);
                one[0] = v;
                return one;
            },
            .str => |s| return parseList(a, s),
        }
    }

    /// The value as a list value with room to grow.
    pub fn toList(v: Value, a: Allocator) ListError!List {
        if (v == .list) return v.list;
        const items = try v.asList(a);
        const obj = try a.create(ListObj);
        obj.* = .{ .buf = @constCast(items), .used = items.len };
        return .{ .obj = obj, .len = items.len };
    }

    pub fn isEmpty(v: Value) bool {
        return switch (v) {
            .str => |s| s.len == 0,
            .list => |l| l.len == 0,
            else => false,
        };
    }
};

/// The decimal text of an integer. It writes two digits at each step.
pub fn writeInt(buf: *[24]u8, i: i64) []const u8 {
    const pairs = "00010203040506070809" ++ "10111213141516171819" ++
        "20212223242526272829" ++ "30313233343536373839" ++
        "40414243444546474849" ++ "50515253545556575859" ++
        "60616263646566676869" ++ "70717273747576777879" ++
        "80818283848586878889" ++ "90919293949596979899";
    var w: usize = buf.len;
    var u: u64 = @abs(i);
    while (u >= 100) {
        const r: usize = @intCast(u % 100);
        u /= 100;
        w -= 2;
        buf[w..][0..2].* = pairs[r * 2 ..][0..2].*;
    }
    if (u >= 10) {
        w -= 2;
        buf[w..][0..2].* = pairs[@as(usize, @intCast(u)) * 2 ..][0..2].*;
    } else {
        w -= 1;
        buf[w] = '0' + @as(u8, @intCast(u));
    }
    if (i < 0) {
        w -= 1;
        buf[w] = '-';
    }
    return buf[w..];
}

test "writeInt equals the standard format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(3);
    const rng = prng.random();
    var buf: [24]u8 = undefined;
    const edge = [_]i64{ 0, 1, -1, 9, 10, -10, 99, 100, -100, 101, 999, 1000, std.math.maxInt(i64), std.math.minInt(i64), std.math.minInt(i64) + 1 };
    for (edge) |v| try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{d}", .{v}), writeInt(&buf, v));
    for (0..5000) |_| {
        const v = rng.int(i64) >> rng.uintLessThan(u6, 63);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{d}", .{v}), writeInt(&buf, v));
    }
}

/// A list value: a view of the first `len` elements of a shared buffer.
/// An append writes after the view when the view ends at the used part
/// of the buffer. Other views of the buffer stay correct.
pub const List = struct {
    obj: *ListObj,
    len: usize,

    pub fn items(l: List) []const Value {
        return l.obj.buf[0..l.len];
    }

    /// The list with `v` at the end. Amortized constant time.
    pub fn append(l: List, a: Allocator, v: Value) Allocator.Error!List {
        const o = l.obj;
        if (o.used == l.len and o.used < o.buf.len) {
            o.buf[o.used] = v;
            o.used += 1;
            return .{ .obj = o, .len = l.len + 1 };
        }
        const cap = @max(8, l.len * 2);
        const n = try allocList(a, cap);
        const buf = n.obj.buf;
        @memcpy(buf[0..l.len], l.items());
        buf[l.len] = v;
        n.obj.used = l.len + 1;
        return .{ .obj = n.obj, .len = l.len + 1 };
    }
};

pub const ListObj = struct {
    buf: []Value,
    used: usize,
    /// The length of the longest view that is a valid dict with unique
    /// keys. Each shorter view of even length is also a valid dict.
    /// Zero means that no view has this mark.
    dict_len: usize = 0,
    /// The hash table of the keys in `buf[0..dict_len]`, made at the
    /// first lookup in a large dict.
    index: ?*DictIndex = null,
};

/// One place of a dict hash table: the hash of a key and the position
/// of the key in the buffer.
pub const DictSlot = struct {
    hash: u32,
    pos: u32,

    pub const empty_pos = std.math.maxInt(u32);
};

/// An open-addressing table with linear probing. The size is a power of
/// two. A dict that loses a key gets a new buffer, so there are no
/// deleted places.
pub const DictIndex = struct {
    slots: []DictSlot,
    count: usize,
};

/// A new list value that owns a copy of `items`.
pub fn newList(a: Allocator, items: []const Value) Allocator.Error!Value {
    const l = try allocList(a, items.len);
    @memcpy(l.obj.buf, items);
    return .{ .list = l };
}

/// The places of the list object at the start of one block. The buffer
/// follows it, so a new list is one allocation.
const head_places = (@sizeOf(ListObj) + @sizeOf(Value) - 1) / @sizeOf(Value);

/// A list of `n` items in one block: the list object, then the buffer.
/// The items have no value yet.
pub fn allocList(a: Allocator, n: usize) Allocator.Error!List {
    const block = try a.alloc(Value, head_places + n);
    const obj: *ListObj = @ptrCast(block.ptr);
    obj.* = .{ .buf = block[head_places..], .used = n };
    return .{ .obj = obj, .len = n };
}

/// A new list value that owns `buf` (no copy).
pub fn wrapList(a: Allocator, buf: []Value) Allocator.Error!Value {
    const obj = try a.create(ListObj);
    obj.* = .{ .buf = buf, .used = buf.len };
    return .{ .list = .{ .obj = obj, .len = buf.len } };
}

pub const ListError = error{ OutOfMemory, BadList };

// ---- Numbers ----

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= 9 and c <= 13);
}

pub fn trimSpace(s: []const u8) []const u8 {
    var b: usize = 0;
    var e: usize = s.len;
    while (b < e and isSpace(s[b])) b += 1;
    while (e > b and isSpace(s[e - 1])) e -= 1;
    return s[b..e];
}

/// An integer in the forms of Tcl 8.6: decimal, 0x, 0o, 0b, and a
/// leading 0 for octal. Spaces around it are allowed.
pub fn parseInt(text: []const u8) ?i64 {
    return parseIntMode(text, true);
}

/// As `parseInt`, but a value that does not fit in a signed 64-bit
/// integer gives null for all bases.
pub fn parseIntStrict(text: []const u8) ?i64 {
    return parseIntMode(text, false);
}

fn parseIntMode(text: []const u8, wrap: bool) ?i64 {
    var s = trimSpace(text);
    if (s.len == 0) return null;
    var neg = false;
    if (s[0] == '-' or s[0] == '+') {
        neg = s[0] == '-';
        s = s[1..];
        if (s.len == 0) return null;
    }
    var base: u8 = 10;
    if (s.len >= 2 and s[0] == '0') {
        switch (s[1]) {
            'x', 'X' => base = 16,
            'o', 'O' => base = 8,
            'b', 'B' => base = 2,
            else => {},
        }
        if (base != 10) {
            s = s[2..];
            if (s.len == 0) return null;
        } else {
            // A leading zero means octal when all digits are octal.
            base = 8;
            s = s[1..];
        }
    }
    var acc: u64 = 0;
    for (s) |c| {
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        if (d >= base) return null;
        acc = std.math.mul(u64, acc, base) catch return null;
        acc = std.math.add(u64, acc, d) catch return null;
    }
    if (neg) {
        if (acc > @as(u64, 1) << 63) return null;
        return @bitCast(0 -% acc);
    }
    if (base == 10 or !wrap) {
        if (acc > std.math.maxInt(i64)) return null;
        return @intCast(acc);
    }
    // A hex, octal, or binary literal wraps to 64 bits.
    return @bitCast(acc);
}

pub fn parseDouble(text: []const u8) ?f64 {
    var s = trimSpace(text);
    if (s.len == 0) return null;
    var t = s;
    if (t[0] == '-' or t[0] == '+') t = t[1..];
    if (std.ascii.eqlIgnoreCase(t, "inf") or std.ascii.eqlIgnoreCase(t, "infinity")) {
        return if (s[0] == '-') -std.math.inf(f64) else std.math.inf(f64);
    }
    if (std.ascii.eqlIgnoreCase(t, "nan")) return std.math.nan(f64);
    var digits = false;
    for (t) |c| switch (c) {
        '0'...'9' => digits = true,
        '.', 'e', 'E', '+', '-' => {},
        else => return null,
    };
    if (!digits) return null;
    // Digits alone with a leading zero are an octal integer, as in Tcl:
    // "08" is an invalid octal number and not the double 8.0.
    if (t.len > 1 and t[0] == '0' and std.mem.indexOfAny(u8, t, ".eE") == null) return null;
    if (s[0] == '+') s = s[1..];
    return std.fmt.parseFloat(f64, s) catch null;
}

/// The value of `tcl_precision` of the running interpreter. Zero is
/// the shortest form. The interpreter sets it at each top-level eval.
pub threadlocal var precision: u8 = 0;

/// Writes the first `p` significant digits of the exact decimal value
/// of a finite positive double, rounded half to even. Returns the
/// decimal exponent of the first digit.
///
/// The double is m * 2^e. For e >= 0 the integer m * 2^e is exact. For
/// e < 0 the integer m * 5^-e has the same digits as m * 2^e, with the
/// decimal point -e places from the right.
fn exactDigits(x: f64, p: usize, out: []u8) i32 {
    const bits: u64 = @bitCast(x);
    const raw_exp: i32 = @intCast((bits >> 52) & 0x7ff);
    var m: u64 = bits & ((@as(u64, 1) << 52) - 1);
    var e: i32 = raw_exp - 1075;
    if (raw_exp == 0) e = -1074 else m |= @as(u64, 1) << 52;
    // The limbs hold base 10^9, least significant first.
    var limbs: [140]u32 = undefined;
    var n: usize = 0;
    var rest = m;
    while (rest != 0) : (rest /= 1_000_000_000) {
        limbs[n] = @intCast(rest % 1_000_000_000);
        n += 1;
    }
    var times: u32 = @intCast(@abs(e));
    const factor: u64 = if (e >= 0) 2 else 5;
    const chunk: u32 = if (e >= 0) 29 else 13;
    const chunk_mul: u64 = std.math.powi(u64, factor, chunk) catch unreachable;
    while (times > 0) {
        const k = @min(times, chunk);
        const mul: u64 = if (k == chunk) chunk_mul else std.math.powi(u64, factor, k) catch unreachable;
        var carry: u64 = 0;
        for (limbs[0..n]) |*l| {
            const v = @as(u64, l.*) * mul + carry;
            l.* = @intCast(v % 1_000_000_000);
            carry = v / 1_000_000_000;
        }
        while (carry != 0) : (carry /= 1_000_000_000) {
            limbs[n] = @intCast(carry % 1_000_000_000);
            n += 1;
        }
        times -= k;
    }
    // The decimal text, most significant digit first.
    var text: [1300]u8 = undefined;
    var len: usize = 0;
    var i = n;
    while (i > 0) {
        i -= 1;
        var chunk_buf: [9]u8 = undefined;
        var v = limbs[i];
        var d: usize = 9;
        while (d > 0) {
            d -= 1;
            chunk_buf[d] = @intCast('0' + v % 10);
            v /= 10;
        }
        var from: usize = 0;
        if (len == 0) {
            while (from < 8 and chunk_buf[from] == '0') from += 1;
        }
        @memcpy(text[len..][0 .. 9 - from], chunk_buf[from..]);
        len += 9 - from;
    }
    var exp: i32 = @as(i32, @intCast(len)) - 1;
    if (e < 0) exp += e;
    // Copy `p` digits and round on the exact tail.
    for (0..p) |k| out[k] = if (k < len) text[k] else '0';
    if (p < len) {
        const next = text[p];
        var tail_zero = true;
        for (text[p + 1 .. len]) |c| {
            if (c != '0') {
                tail_zero = false;
                break;
            }
        }
        const odd = (out[p - 1] - '0') % 2 == 1;
        if (next > '5' or (next == '5' and (!tail_zero or odd))) {
            var k = p;
            while (k > 0) {
                k -= 1;
                if (out[k] == '9') {
                    out[k] = '0';
                } else {
                    out[k] += 1;
                    break;
                }
            } else {
                out[0] = '1';
                exp += 1;
            }
        }
    }
    return exp;
}

/// The string form of a double as Tcl prints it: the shortest digits
/// that read back to the same double, with ".0" on a whole number.
pub fn formatDouble(a: Allocator, x: f64) Allocator.Error![]const u8 {
    if (std.math.isNan(x)) return "NaN";
    if (std.math.isInf(x)) return if (x < 0) "-Inf" else "Inf";
    var buf: [64]u8 = undefined;
    var digs: [32]u8 = undefined;
    var n: usize = 0;
    var exp: i32 = 0;
    var neg = false;
    if (precision != 0 and x != 0) {
        neg = x < 0;
        exp = exactDigits(@abs(x), precision, &digs);
        n = precision;
        while (n > 1 and digs[n - 1] == '0') n -= 1;
    } else {
        const sci = std.fmt.bufPrint(&buf, "{e}", .{x}) catch unreachable;
        // sci is "[-]d[.ddd]e[-]x".
        const epos = std.mem.indexOfScalar(u8, sci, 'e').?;
        exp = std.fmt.parseInt(i32, sci[epos + 1 ..], 10) catch unreachable;
        var mant = sci[0..epos];
        neg = mant[0] == '-';
        if (neg) mant = mant[1..];
        for (mant) |c| if (c != '.') {
            digs[n] = c;
            n += 1;
        };
    }
    var out: std.ArrayList(u8) = .empty;
    if (neg) try out.append(a, '-');
    if (exp < -4 or exp >= 17) {
        try out.append(a, digs[0]);
        if (n > 1) {
            try out.append(a, '.');
            try out.appendSlice(a, digs[1..n]);
        }
        const ae: u32 = @abs(exp);
        const pad: []const u8 = if (precision != 0 and ae < 10) "0" else "";
        try out.print(a, "e{c}{s}{d}", .{ @as(u8, if (exp < 0) 0x2d else 0x2b), pad, ae });
    } else if (exp < 0) {
        try out.appendSlice(a, "0.");
        try out.appendNTimes(a, '0', @intCast(-exp - 1));
        try out.appendSlice(a, digs[0..n]);
    } else {
        const int_len: usize = @intCast(exp + 1);
        if (n <= int_len) {
            try out.appendSlice(a, digs[0..n]);
            try out.appendNTimes(a, '0', int_len - n);
            try out.appendSlice(a, ".0");
        } else {
            try out.appendSlice(a, digs[0..int_len]);
            try out.append(a, '.');
            try out.appendSlice(a, digs[int_len..n]);
        }
    }
    return out.items;
}

// ---- Lists ----

/// Reads one backslash sequence at `s[i]` (the backslash). Appends the
/// result to `out` and returns the index after the sequence.
pub fn backslash(a: Allocator, s: []const u8, i: usize, out: *std.ArrayList(u8)) Allocator.Error!usize {
    if (i + 1 >= s.len) {
        try out.append(a, '\\');
        return i + 1;
    }
    const c = s[i + 1];
    var j = i + 2;
    switch (c) {
        'a' => try out.append(a, 7),
        'b' => try out.append(a, 8),
        'f' => try out.append(a, 12),
        'n' => try out.append(a, '\n'),
        'r' => try out.append(a, '\r'),
        't' => try out.append(a, '\t'),
        'v' => try out.append(a, 11),
        '\n' => {
            while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
            try out.append(a, ' ');
        },
        '0'...'7' => {
            var v: u32 = c - '0';
            var k: usize = 1;
            while (k < 3 and j < s.len and s[j] >= '0' and s[j] <= '7') : (k += 1) {
                v = v * 8 + (s[j] - '0');
                j += 1;
            }
            try appendCodepoint(a, out, v & 0xff);
        },
        'x', 'u', 'U' => {
            const max: usize = if (c == 'x') 2 else if (c == 'u') 4 else 8;
            var v: u32 = 0;
            var k: usize = 0;
            while (k < max and j < s.len and std.ascii.isHex(s[j])) : (k += 1) {
                v = v *% 16 + (std.fmt.charToDigit(s[j], 16) catch unreachable);
                j += 1;
            }
            if (k == 0) try out.append(a, c) else try appendCodepoint(a, out, v);
        },
        else => try out.append(a, c),
    }
    return j;
}

fn appendCodepoint(a: Allocator, out: *std.ArrayList(u8), cp: u32) Allocator.Error!void {
    var b: [4]u8 = undefined;
    const c: u21 = if (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) 0xfffd else @intCast(cp);
    const n = std.unicode.utf8Encode(c, &b) catch unreachable;
    try out.appendSlice(a, b[0..n]);
}

/// Splits a string into list elements by the rules of Tcl lists.
pub fn parseList(a: Allocator, s: []const u8) ListError![]const Value {
    var out: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < s.len and isSpace(s[i])) i += 1;
        if (i >= s.len) break;
        if (s[i] == '{') {
            var depth: usize = 1;
            const start = i + 1;
            i += 1;
            while (i < s.len) : (i += 1) {
                const c = s[i];
                if (c == '\\') {
                    i += 1;
                } else if (c == '{') {
                    depth += 1;
                } else if (c == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (i >= s.len) return error.BadList;
            try out.append(a, .{ .str = s[start..i] });
            i += 1;
            if (i < s.len and !isSpace(s[i])) return error.BadList;
        } else if (s[i] == '"') {
            var buf: std.ArrayList(u8) = .empty;
            i += 1;
            while (i < s.len and s[i] != '"') {
                if (s[i] == '\\') {
                    i = try backslash(a, s, i, &buf);
                } else {
                    try buf.append(a, s[i]);
                    i += 1;
                }
            }
            if (i >= s.len) return error.BadList;
            i += 1;
            if (i < s.len and !isSpace(s[i])) return error.BadList;
            try out.append(a, .{ .str = buf.items });
        } else {
            const start = i;
            var has_bs = false;
            while (i < s.len and !isSpace(s[i])) : (i += 1) {
                if (s[i] == '\\') {
                    has_bs = true;
                    i += 1;
                }
            }
            if (i > s.len) i = s.len;
            if (!has_bs) {
                try out.append(a, .{ .str = s[start..i] });
            } else {
                var buf: std.ArrayList(u8) = .empty;
                var k = start;
                while (k < i) {
                    if (s[k] == '\\') {
                        k = try backslash(a, s, k, &buf);
                    } else {
                        try buf.append(a, s[k]);
                        k += 1;
                    }
                }
                try out.append(a, .{ .str = buf.items });
            }
        }
    }
    return out.items;
}

pub const ListFault = struct { kind: enum { brace, quote, after_brace, after_quote }, rest: []const u8 };

/// The first syntax fault of the text of a list, or null.
pub fn listFault(s: []const u8) ?ListFault {
    var i: usize = 0;
    while (true) {
        while (i < s.len and isSpace(s[i])) i += 1;
        if (i >= s.len) return null;
        if (s[i] == '{') {
            var depth: usize = 1;
            i += 1;
            while (i < s.len) : (i += 1) {
                if (s[i] == '\\') {
                    i += 1;
                } else if (s[i] == '{') {
                    depth += 1;
                } else if (s[i] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (i >= s.len) return .{ .kind = .brace, .rest = "" };
            i += 1;
            if (i < s.len and !isSpace(s[i])) return .{ .kind = .after_brace, .rest = junk(s[i..]) };
        } else if (s[i] == '"') {
            i += 1;
            while (i < s.len and s[i] != '"') : (i += 1) {
                if (s[i] == '\\') i += 1;
            }
            if (i >= s.len) return .{ .kind = .quote, .rest = "" };
            i += 1;
            if (i < s.len and !isSpace(s[i])) return .{ .kind = .after_quote, .rest = junk(s[i..]) };
        } else {
            while (i < s.len and !isSpace(s[i])) : (i += 1) {
                if (s[i] == '\\') i += 1;
            }
        }
    }
}

/// The text after a closed element, up to a space or 20 bytes.
fn junk(s: []const u8) []const u8 {
    var n: usize = 0;
    while (n < s.len and n < 20 and !isSpace(s[n])) n += 1;
    return s[0..n];
}

/// The string form of a list: each element quoted so that `parseList`
/// gives the same elements back.
pub fn listToString(a: Allocator, items: []const Value) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |it, n| {
        if (n > 0) try out.append(a, ' ');
        switch (it) {
            .int => |i| try out.print(a, "{d}", .{i}),
            .double => |d| try out.appendSlice(a, try formatDouble(a, d)),
            else => try appendElement(a, &out, try it.toStr(a), n == 0),
        }
    }
    return out.items;
}

/// Appends one list element with the quotes that it needs.
pub fn appendElement(a: Allocator, out: *std.ArrayList(u8), s: []const u8, first: bool) Allocator.Error!void {
    if (s.len == 0) return out.appendSlice(a, "{}");
    // Tcl braces an element when a character asks for braces, and uses
    // backslashes when only `]` or an inner `"` needs a quote, or when
    // braces cannot hold the element.
    var want_brace = (first and s[0] == '#') or s[0] == '{' or s[0] == '"';
    var want_escape = false;
    var depth: isize = 0;
    var balanced = true;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth < 0) balanced = false;
            },
            '\\' => {
                want_brace = true;
                if (i + 1 >= s.len or s[i + 1] == '\n') balanced = false;
                i += 1;
            },
            ' ', '\t', '\n', '\r', 11, 12, ';', '$', '[' => want_brace = true,
            ']', '"' => want_escape = true,
            else => {},
        }
    }
    if (depth != 0) balanced = false;
    if (!want_brace and !want_escape and balanced) return out.appendSlice(a, s);
    if (balanced and (want_brace or !want_escape)) {
        try out.append(a, '{');
        try out.appendSlice(a, s);
        return out.append(a, '}');
    }
    for (s) |c| {
        switch (c) {
            '{', '}' => {
                if (!balanced) try out.append(a, '\\');
                try out.append(a, c);
            },
            '\\', ' ', ';', '"', '$', '[', ']' => {
                try out.append(a, '\\');
                try out.append(a, c);
            },
            '\t' => try out.appendSlice(a, "\\t"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            11 => try out.appendSlice(a, "\\v"),
            12 => try out.appendSlice(a, "\\f"),
            else => try out.append(a, c),
        }
    }
}

test "numbers keep the forms of Tcl" {
    try std.testing.expectEqual(@as(?i64, 16), parseInt("0x10"));
    try std.testing.expectEqual(@as(?i64, 8), parseInt("010"));
    try std.testing.expectEqual(@as(?i64, -5), parseInt(" -5 "));
    try std.testing.expectEqual(@as(?i64, null), parseInt("1.0"));
    try std.testing.expectEqual(@as(?i64, null), parseInt("08"));
    try std.testing.expectEqual(@as(?f64, 1.5), parseDouble("1.5"));
    try std.testing.expectEqual(@as(?f64, null), parseDouble("abc"));
}

test "a double prints with the shortest digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { f64, []const u8 }{
        .{ 1.0, "1.0" },                      .{ 0.1, "0.1" },                  .{ -2.5, "-2.5" },
        .{ 1e20, "1e+20" },                   .{ 1.5e-7, "1.5e-7" },            .{ 123456.789, "123456.789" },
        .{ 0.0001, "0.0001" },                .{ 1e16, "10000000000000000.0" }, .{ 3.0e15, "3000000000000000.0" },
        .{ 1.0 / 3.0, "0.3333333333333333" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c[1], try formatDouble(a, c[0]));
    }
}

test "a list round-trips through its string form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]Value{ .{ .str = "a b" }, .{ .str = "" }, .{ .str = "{" }, .{ .int = 3 }, .{ .str = "x\\" }, .{ .str = "$v" } };
    const s = try listToString(a, &items);
    try std.testing.expectEqualStrings("{a b} {} \\{ 3 x\\\\ {$v}", s);
    const back = try parseList(a, s);
    try std.testing.expectEqual(items.len, back.len);
    for (items, back) |x, y| try std.testing.expectEqualStrings(try x.toStr(a), try y.toStr(a));
    try std.testing.expectError(error.BadList, parseList(a, "{a b"));
    try std.testing.expectError(error.BadList, parseList(a, "{a}b"));
}

//! The JSON writer: strings, numbers, the schema encoder, the typed tree,
//! and the layout of `pretty`.
//!
//! A Tcl value has no visible type, so a value goes to JSON text with a
//! schema or as a typed tree. The schema words are `string`, `int`,
//! `number`, `bool`, `null`, `raw` (JSON text), `object` (a dict with
//! each value guessed), `{object SCHEMA}` (a dict of keys and schemas),
//! `{list WORD}`, and `{optional WORD}` for a key that can be absent. A
//! guess makes a number of a canonical integer or double, a bool of
//! `true` or `false`, and a string of each other value.
//!
//! A typed tree is the form of `parse -typed`: `{object {KEY TREE ...}}`,
//! `{array {TREE ...}}`, `{string S}`, `{number N}`, `{bool B}`, `null`,
//! and `{raw TEXT}`.
//!
//! A string escapes `"`, `\`, the bytes below 0x20, and 0x7F. Each other
//! byte stays, so the text of a valid UTF-8 string stays valid. A scan
//! of 32 bytes at a time finds the next byte to escape.
//!
//! The writer pays one step for each 4096 bytes of output and one step
//! for each value, and checks the memory limit, at least each 64 KiB.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("../interp.zig");
const value = @import("../value.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;

pub const Writer = struct {
    it: *Interp,
    out: std.ArrayList(u8) = .empty,
    /// The output length at the last safe point.
    paid_at: usize = 0,
    made: usize = 0,
    depth: u32 = 0,

    pub fn bytes(w: *Writer, s: []const u8) Error!void {
        try w.out.appendSlice(w.it.alloc(), s);
    }

    pub inline fn byte(w: *Writer, c: u8) Error!void {
        if (w.out.items.len < w.out.capacity) {
            w.out.appendAssumeCapacity(c);
            return;
        }
        try w.out.append(w.it.alloc(), c);
    }

    /// The safe point: the steps of the output and the values, and the
    /// memory limit.
    pub fn tick(w: *Writer) Error!void {
        w.made += 1;
        if (w.out.items.len - w.paid_at < 64 * 1024 and w.made < 1024) return;
        try w.pay();
    }

    pub fn pay(w: *Writer) Error!void {
        const it = w.it;
        const cost = (w.out.items.len - w.paid_at) / 4096 + w.made;
        w.paid_at = w.out.items.len;
        w.made = 0;
        if (cost > it.compute_limit) {
            it.compute_limit = 0;
            return it.fail("compute limit reached", .{});
        }
        it.compute_limit -= cost;
        if (it.overLimit()) return it.memError();
    }

    pub fn string(w: *Writer, s: []const u8) Error!void {
        try w.out.ensureUnusedCapacity(w.it.alloc(), s.len + 2);
        var from: usize = 0;
        const first = findEscape(s, 0);
        if (first == s.len) {
            // No byte to escape: one copy.
            w.out.appendAssumeCapacity('"');
            w.out.appendSliceAssumeCapacity(s);
            w.out.appendAssumeCapacity('"');
            return;
        }
        w.out.appendAssumeCapacity('"');
        while (true) {
            const i = findEscape(s, from);
            try w.bytes(s[from..i]);
            if (i >= s.len) break;
            const c = s[i];
            switch (c) {
                '"' => try w.bytes("\\\""),
                '\\' => try w.bytes("\\\\"),
                8 => try w.bytes("\\b"),
                12 => try w.bytes("\\f"),
                '\n' => try w.bytes("\\n"),
                '\r' => try w.bytes("\\r"),
                '\t' => try w.bytes("\\t"),
                else => {
                    const hex = "0123456789abcdef";
                    try w.bytes(&.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] });
                },
            }
            from = i + 1;
        }
        try w.byte('"');
    }

    /// A number in JSON form: an int, a big integer, or a finite double.
    pub fn number(w: *Writer, v: Value) Error!void {
        const it = w.it;
        // JSON number text, as `parse -typed` keeps it, goes out as it is.
        if (v == .str and isJsonNumber(v.str)) return w.bytes(v.str);
        const n = v.asNumber() orelse blk: {
            // A big integer is canonical decimal text.
            const s = try it.str(v);
            if (isBigInt(s)) {
                try w.bytes(s);
                return;
            }
            break :blk null;
        } orelse return it.failCode("ZT JSON VALUE", "expected a number but got \"{s}\"", .{try it.str(v)});
        switch (n) {
            .int => |i| {
                var b: [24]u8 = undefined;
                try w.bytes(value.writeInt(&b, i));
            },
            .double => |d| {
                if (!std.math.isFinite(d)) return it.failCode("ZT JSON VALUE", "json has no number \"{s}\"", .{try it.str(v)});
                const s = try value.formatDouble(it.alloc(), d);
                try w.bytes(s);
            },
            else => unreachable,
        }
    }

    pub fn boolean(w: *Writer, v: Value) Error!void {
        const it = w.it;
        if (v == .str and (eql(v.str, "true") or eql(v.str, "false"))) return w.bytes(v.str);
        const b = parseBool(try it.str(v)) orelse return it.failCode("ZT JSON VALUE", "expected a boolean but got \"{s}\"", .{try it.str(v)});
        try w.bytes(if (b) "true" else "false");
    }

    /// A value by the guess: a number, a bool, or a string.
    pub fn guess(w: *Writer, v: Value) Error!void {
        switch (v) {
            .int, .double => return w.number(v),
            else => {},
        }
        const s = try w.it.str(v);
        if (isCanonicalNumber(s)) return w.bytes(s);
        if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return w.bytes(s);
        return w.string(s);
    }

    fn enter(w: *Writer) Error!void {
        w.depth += 1;
        if (w.depth > 512) return w.it.failCode("ZT JSON DEPTH", "json nesting is deeper than 512", .{});
    }

    /// A value by a schema.
    pub fn schema(w: *Writer, v: Value, s: Value) Error!void {
        const it = w.it;
        try w.tick();
        const words = try it.list(s);
        if (words.len == 0) return it.failCode("ZT JSON SCHEMA", "empty schema", .{});
        const head = try it.str(words[0]);
        if (words.len == 1) {
            if (eql(head, "string")) return w.string(try it.str(v));
            if (eql(head, "int")) {
                if (v.asInt() == null and !isBigInt(try it.str(v))) return it.failCode("ZT JSON VALUE", "expected an integer but got \"{s}\"", .{try it.str(v)});
                return w.number(v);
            }
            if (eql(head, "number")) return w.number(v);
            if (eql(head, "bool")) return w.boolean(v);
            if (eql(head, "null")) return w.bytes("null");
            if (eql(head, "raw")) return w.bytes(try it.str(v));
            if (eql(head, "object")) {
                try w.enter();
                defer w.depth -= 1;
                const items = try dictItems(it, v);
                try w.byte('{');
                var i: usize = 0;
                while (i < items.len) : (i += 2) {
                    if (i > 0) try w.byte(',');
                    try w.string(try it.str(items[i]));
                    try w.byte(':');
                    try w.guess(items[i + 1]);
                    try w.tick();
                }
                return w.byte('}');
            }
        } else if (words.len == 2) {
            if (eql(head, "list")) {
                try w.enter();
                defer w.depth -= 1;
                try w.byte('[');
                for (try it.list(v), 0..) |e, i| {
                    if (i > 0) try w.byte(',');
                    try w.schema(e, words[1]);
                }
                return w.byte(']');
            }
            if (eql(head, "optional")) return w.schema(v, words[1]);
            if (eql(head, "object")) {
                try w.enter();
                defer w.depth -= 1;
                const items = try dictItems(it, v);
                const fields = try dictItems(it, words[1]);
                try w.byte('{');
                var first = true;
                var k: usize = 0;
                while (k < fields.len) : (k += 2) {
                    const key = try it.str(fields[k]);
                    const at = find(it, items, key) catch |e| return e;
                    if (at == null) {
                        const fw = try it.list(fields[k + 1]);
                        if (fw.len == 2 and eql(try it.str(fw[0]), "optional")) continue;
                        return it.failCode("ZT JSON SCHEMA", "missing key \"{s}\"", .{key});
                    }
                    if (!first) try w.byte(',');
                    first = false;
                    try w.string(key);
                    try w.byte(':');
                    try w.schema(items[at.? + 1], fields[k + 1]);
                }
                // A key that the schema does not name is an error.
                var i: usize = 0;
                while (i < items.len) : (i += 2) {
                    const key = try it.str(items[i]);
                    if (try find(it, fields, key) == null) return it.failCode("ZT JSON SCHEMA", "key \"{s}\" is not in the schema", .{key});
                }
                return w.byte('}');
            }
        }
        return it.failCode("ZT JSON SCHEMA", "bad schema \"{s}\"", .{try it.str(s)});
    }

    /// A typed tree.
    pub fn typed(w: *Writer, t: Value) Error!void {
        const it = w.it;
        try w.tick();
        const words = if (t == .list) t.list.items() else try it.list(t);
        if (words.len == 1 and eql(try it.str(words[0]), "null")) return w.bytes("null");
        if (words.len != 2) return it.failCode("ZT JSON TYPED", "bad typed value \"{s}\"", .{try it.str(t)});
        const tag = try it.str(words[0]);
        const v = words[1];
        // One compare of the first byte selects the tag to check.
        if (tag.len > 0) switch (tag[0]) {
            's' => if (eql(tag, "string")) return w.string(try it.str(v)),
            'n' => if (eql(tag, "number")) return w.number(v),
            'b' => if (eql(tag, "bool")) return w.boolean(v),
            'r' => if (eql(tag, "raw")) return w.bytes(try it.str(v)),
            else => {},
        };
        if (eql(tag, "array")) {
            try w.enter();
            defer w.depth -= 1;
            try w.byte('[');
            for (if (v == .list) v.list.items() else try it.list(v), 0..) |e, i| {
                if (i > 0) try w.byte(',');
                try w.typed(e);
            }
            return w.byte(']');
        }
        if (eql(tag, "object")) {
            try w.enter();
            defer w.depth -= 1;
            const items = if (v == .list) v.list.items() else try it.list(v);
            if (items.len % 2 != 0) return it.failCode("ZT JSON TYPED", "bad typed object \"{s}\"", .{try it.str(v)});
            try w.byte('{');
            var i: usize = 0;
            while (i < items.len) : (i += 2) {
                if (i > 0) try w.byte(',');
                try w.string(try it.str(items[i]));
                try w.byte(':');
                try w.typed(items[i + 1]);
            }
            return w.byte('}');
        }
        return it.failCode("ZT JSON TYPED", "bad typed value \"{s}\"", .{try it.str(t)});
    }

    pub fn result(w: *Writer) Error!Value {
        try w.pay();
        return .{ .str = w.out.items };
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn find(it: *Interp, items: []const Value, key: []const u8) Error!?usize {
    var i: usize = 0;
    var hit: ?usize = null;
    while (i < items.len) : (i += 2) {
        if (eql(try it.str(items[i]), key)) hit = i;
    }
    return hit;
}

fn dictItems(it: *Interp, v: Value) Error![]const Value {
    const items = try it.list(v);
    if (items.len % 2 != 0) return it.failCode("TCL VALUE DICTIONARY", "missing value to go with key", .{});
    return items;
}

/// The bytes that need an escape: '"', '\', below 0x20, and 0x7F.
fn findEscape(s: []const u8, from: usize) usize {
    const W = @Vector(32, u8);
    var i = from;
    while (i + 32 <= s.len) : (i += 32) {
        const v: W = s[i..][0..32].*;
        const m: u32 = @bitCast((v == @as(W, @splat('"'))) | (v == @as(W, @splat('\\'))) |
            (v < @as(W, @splat(0x20))) | (v == @as(W, @splat(0x7F))));
        if (m != 0) return i + @ctz(m);
    }
    // Eight bytes at a time: a zero byte of each XOR is a match.
    const ones: u64 = 0x0101_0101_0101_0101;
    const highs: u64 = 0x8080_8080_8080_8080;
    while (i + 8 <= s.len) : (i += 8) {
        const x = std.mem.readInt(u64, s[i..][0..8], .little);
        const q = x ^ (ones * '"');
        const b = x ^ (ones * '\\');
        const d = x ^ (ones * 0x7F);
        const m = ((q -% ones) & ~q) | ((b -% ones) & ~b) | ((d -% ones) & ~d) | ((x -% ones * 0x20) & ~x);
        if (m & highs != 0) break;
    }
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' or c == '\\' or c < 0x20 or c == 0x7F) return i;
    }
    return s.len;
}

/// True for the grammar of a JSON number (RFC 8259).
fn isJsonNumber(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    if (i >= s.len) return false;
    if (s[i] == '0') {
        i += 1;
    } else if (s[i] >= '1' and s[i] <= '9') {
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    } else return false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const d = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == d) return false;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const d = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == d) return false;
    }
    return i == s.len;
}

fn isBigInt(s: []const u8) bool {
    var t = s;
    if (t.len > 0 and t[0] == '-') t = t[1..];
    if (t.len == 0 or (t[0] == '0' and t.len > 1)) return false;
    for (t) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// True for the canonical text of an int or a double: JSON number text
/// that reads back to the same text.
fn isCanonicalNumber(s: []const u8) bool {
    if (isBigInt(s)) return true;
    const d = value.parseDouble(s) orelse return false;
    if (!std.math.isFinite(d)) return false;
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const t = value.formatDouble(fba.allocator(), d) catch return false;
    return eql(s, t);
}

fn parseBool(s: []const u8) ?bool {
    const t = [_][]const u8{ "1", "true", "yes", "on" };
    const f = [_][]const u8{ "0", "false", "no", "off" };
    for (t) |x| if (std.ascii.eqlIgnoreCase(s, x)) return true;
    for (f) |x| if (std.ascii.eqlIgnoreCase(s, x)) return false;
    return null;
}

/// The text with a new layout: each member of a container on its own
/// line, `indent` spaces for each level, and ": " after a key. The text
/// must be valid JSON.
pub fn pretty(w: *Writer, text: []const u8, indent: usize) Error!void {
    var level: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            ' ', '\t', '\n', '\r' => {
                i += 1;
                continue;
            },
            '"' => {
                var j = i + 1;
                while (text[j] != '"') : (j += 1) {
                    if (text[j] == '\\') j += 1;
                }
                try w.bytes(text[i .. j + 1]);
                i = j + 1;
                continue;
            },
            '{', '[' => {
                // An empty container stays on one line.
                var j = i + 1;
                while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) j += 1;
                if (j < text.len and (text[j] == '}' or text[j] == ']')) {
                    try w.bytes(&.{ c, text[j] });
                    i = j + 1;
                    continue;
                }
                level += 1;
                try w.byte(c);
                try newline(w, level * indent);
            },
            '}', ']' => {
                level -= 1;
                try newline(w, level * indent);
                try w.byte(c);
            },
            ',' => {
                try w.byte(',');
                try newline(w, level * indent);
                try w.tick();
            },
            ':' => try w.bytes(": "),
            else => try w.byte(c),
        }
        i += 1;
    }
}

fn newline(w: *Writer, n: usize) Error!void {
    try w.byte('\n');
    try w.out.appendNTimes(w.it.alloc(), ' ', n);
}

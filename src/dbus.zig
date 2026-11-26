//! The wire format of D-Bus (task 01 of docs/dev/linux-tasks/README.md),
//! in little endian, from the D-Bus specification, section "Type
//! System" and "Marshaling (Wire Format)".
//!
//! `marshal` writes the Tcl values of a signature into a buffer, and
//! `unmarshal` reads them back as Tcl values. Each value starts at a
//! multiple of the alignment of its type, from the start of the message:
//! 1 for `y` and `g`, 2 for `n q`, 4 for `b i u h s o a`, and 8 for
//! `x t d`, a struct, and a dict entry. An array is a u32 length in
//! bytes, the padding to the alignment of its element, and the elements.
//! The length does not count that padding.
//!
//! The type rules: an integer and a double are Tcl numbers, `b` is 0 or
//! 1, `s o g` are strings, an array is a list, an array of dict entries
//! (`a{..}`) is a dict, a struct is a list, and a variant is a list of
//! its signature and its value.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;

/// The longest signature of the specification.
pub const max_signature = 255;
/// The deepest nesting of arrays and of structs, each.
const max_depth = 32;

fn alignOf(c: u8) usize {
    return switch (c) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
        else => 8, // x t d ( {
    };
}

/// The end of the one complete type at the start of `sig`, or null.
pub fn typeEnd(sig: []const u8) ?usize {
    return typeEndDepth(sig, 0);
}

fn typeEndDepth(sig: []const u8, depth: usize) ?usize {
    if (sig.len == 0 or depth > 2 * max_depth) return null;
    switch (sig[0]) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 'h', 's', 'o', 'g', 'v' => return 1,
        'a' => return 1 + (typeEndDepth(sig[1..], depth + 1) orelse return null),
        '(' => {
            var i: usize = 1;
            while (i < sig.len and sig[i] != ')') i += typeEndDepth(sig[i..], depth + 1) orelse return null;
            if (i == 1 or i >= sig.len) return null;
            return i + 1;
        },
        '{' => {
            // A dict entry: a basic key type and one complete value type.
            if (sig.len < 4 or std.mem.indexOfScalar(u8, "ybnqiuxtdhsog", sig[1]) == null) return null;
            const v = 2 + (typeEndDepth(sig[2..], depth + 1) orelse return null);
            if (v >= sig.len or sig[v] != '}') return null;
            return v + 1;
        },
        else => return null,
    }
}

/// A buffer of a message. Offsets count from its start.
pub const Writer = struct {
    buf: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,

    fn pad(w: *Writer, n: usize) !void {
        while (w.buf.items.len % n != 0) try w.buf.append(w.a, 0);
    }

    fn int(w: *Writer, comptime T: type, x: T) !void {
        try w.pad(@sizeOf(T));
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, x, .little);
        try w.buf.appendSlice(w.a, &b);
    }

    fn string(w: *Writer, s: []const u8, short: bool) !void {
        if (short) try w.buf.append(w.a, @intCast(s.len)) else try w.int(u32, @intCast(s.len));
        try w.buf.appendSlice(w.a, s);
        try w.buf.append(w.a, 0);
    }
};

fn number(it: *Interp, v: Value) Error!f64 {
    return switch (v) {
        .int => |n| @floatFromInt(n),
        .double => |d| d,
        else => blk: {
            const s = try it.str(v);
            break :blk std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch return it.fail("expected floating-point number but got \"{s}\"", .{s});
        },
    };
}

fn intIn(it: *Interp, v: Value, comptime T: type) Error!T {
    const n = try it.int(v);
    return std.math.cast(T, n) orelse it.fail("integer value {d} is out of range for D-Bus type {s}", .{ n, @typeName(T) });
}

/// Writes `v` as the one complete type at the start of `sig`.
pub fn marshal(it: *Interp, w: *Writer, sig: []const u8, v: Value) Error!void {
    return marshalOne(it, w, sig, v);
}

fn marshalOne(it: *Interp, w: *Writer, sig: []const u8, v: Value) Error!void {
    const end = typeEnd(sig) orelse return it.fail("bad D-Bus signature \"{s}\"", .{sig});
    const t = sig[0..end];
    switch (t[0]) {
        'y' => try w.buf.append(w.a, try intIn(it, v, u8)),
        'b' => try w.int(u32, if (try it.int(v) != 0) 1 else 0),
        'n' => try w.int(i16, try intIn(it, v, i16)),
        'q' => try w.int(u16, try intIn(it, v, u16)),
        'i' => try w.int(i32, try intIn(it, v, i32)),
        'u', 'h' => try w.int(u32, try intIn(it, v, u32)),
        'x' => try w.int(i64, try it.int(v)),
        't' => try w.int(u64, @bitCast(try it.int(v))),
        'd' => try w.int(u64, @bitCast(try number(it, v))),
        's', 'o' => {
            const s = try it.str(v);
            if (std.mem.indexOfScalar(u8, s, 0) != null) return it.fail("a D-Bus string has no NUL byte", .{});
            try w.string(s, false);
        },
        'g' => {
            const s = try it.str(v);
            if (s.len > max_signature) return it.fail("a D-Bus signature is at most 255 bytes", .{});
            try w.string(s, true);
        },
        'v' => {
            const pair = try it.list(v);
            if (pair.len != 2) return it.fail("a D-Bus variant is a list of a signature and a value", .{});
            const inner = try it.str(pair[0]);
            if ((typeEnd(inner) orelse 0) != inner.len) return it.fail("bad D-Bus signature \"{s}\"", .{inner});
            try w.string(inner, true);
            try marshalOne(it, w, inner, pair[1]);
        },
        '(' => {
            const items = try it.list(v);
            try w.pad(8);
            var i: usize = 1;
            var k: usize = 0;
            while (t[i] != ')') : (k += 1) {
                if (k >= items.len) return it.fail("a D-Bus struct of \"{s}\" needs more values", .{t});
                try marshalOne(it, w, t[i..], items[k]);
                i += typeEnd(t[i..]).?;
            }
            if (k != items.len) return it.fail("a D-Bus struct of \"{s}\" has too many values", .{t});
        },
        'a' => {
            const elem = t[1..];
            const items = try it.list(v);
            try w.pad(4);
            const at = w.buf.items.len;
            try w.int(u32, 0);
            try w.pad(alignOf(elem[0]));
            const start = w.buf.items.len;
            if (elem[0] == '{') {
                // A dict: key and value pairs.
                if (items.len % 2 != 0) return it.fail("missing value to go with key", .{});
                const key = elem[1..2];
                const val = elem[2 .. elem.len - 1];
                var k: usize = 0;
                while (k < items.len) : (k += 2) {
                    try w.pad(8);
                    try marshalOne(it, w, key, items[k]);
                    try marshalOne(it, w, val, items[k + 1]);
                }
            } else for (items) |x| try marshalOne(it, w, elem, x);
            const len = w.buf.items.len - start;
            if (len > 64 << 20) return it.fail("a D-Bus array is at most 64 MiB", .{});
            std.mem.writeInt(u32, w.buf.items[at..][0..4], @intCast(len), .little);
        },
        else => unreachable,
    }
}

/// A reader of a message. `pos` counts from the start of the message.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn pad(r: *Reader, n: usize) !void {
        const to = std.mem.alignForward(usize, r.pos, n);
        if (to > r.data.len) return error.Truncated;
        r.pos = to;
    }

    fn bytes(r: *Reader, n: usize) ![]const u8 {
        if (n > r.data.len - r.pos) return error.Truncated;
        defer r.pos += n;
        return r.data[r.pos..][0..n];
    }

    fn int(r: *Reader, comptime T: type) !T {
        try r.pad(@sizeOf(T));
        return std.mem.readInt(T, (try r.bytes(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    fn string(r: *Reader, short: bool) ![]const u8 {
        const n: usize = if (short) (try r.bytes(1))[0] else try r.int(u32);
        const s = try r.bytes(n);
        if ((try r.bytes(1))[0] != 0) return error.BadString;
        return s;
    }
};

fn bad(it: *Interp, e: anyerror) Error {
    return it.fail("bad D-Bus message: {s}", .{switch (e) {
        error.Truncated => "it ends early",
        error.BadString => "a string has no NUL at its end",
        error.TooDeep => "it nests too deep",
        else => @errorName(e),
    }});
}

/// Reads the one complete type at the start of `sig` as a Tcl value.
pub fn unmarshal(it: *Interp, r: *Reader, sig: []const u8) Error!Value {
    return readOne(it, r, sig, 0) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.TclError => error.TclError,
        else => bad(it, e),
    };
}

fn readOne(it: *Interp, r: *Reader, sig: []const u8, depth: usize) anyerror!Value {
    if (depth > 2 * max_depth) return error.TooDeep;
    const end = typeEnd(sig) orelse return it.fail("bad D-Bus signature \"{s}\"", .{sig});
    const t = sig[0..end];
    const a = it.alloc();
    return switch (t[0]) {
        'y' => .{ .int = (try r.bytes(1))[0] },
        'b' => .{ .int = @intFromBool(try r.int(u32) != 0) },
        'n' => .{ .int = try r.int(i16) },
        'q' => .{ .int = try r.int(u16) },
        'i' => .{ .int = try r.int(i32) },
        'u', 'h' => .{ .int = try r.int(u32) },
        'x' => .{ .int = try r.int(i64) },
        't' => .{ .int = @bitCast(try r.int(u64)) },
        'd' => .{ .double = @bitCast(try r.int(u64)) },
        's', 'o' => .{ .str = try a.dupe(u8, try r.string(false)) },
        'g' => .{ .str = try a.dupe(u8, try r.string(true)) },
        'v' => blk: {
            const inner = try r.string(true);
            if ((typeEnd(inner) orelse 0) != inner.len) return error.BadSignature;
            const x = try readOne(it, r, inner, depth + 1);
            const pair = try a.dupe(Value, &.{ .{ .str = try a.dupe(u8, inner) }, x });
            break :blk try value.wrapList(a, pair);
        },
        '(' => blk: {
            try r.pad(8);
            var items: std.ArrayList(Value) = .empty;
            var i: usize = 1;
            while (t[i] != ')') : (i += typeEnd(t[i..]).?) try items.append(a, try readOne(it, r, t[i..], depth + 1));
            break :blk try value.wrapList(a, items.items);
        },
        'a' => blk: {
            const elem = t[1..];
            const len = try r.int(u32);
            try r.pad(alignOf(elem[0]));
            if (len > r.data.len - r.pos) return error.Truncated;
            const stop = r.pos + len;
            var items: std.ArrayList(Value) = .empty;
            while (r.pos < stop) {
                if (elem[0] == '{') {
                    try r.pad(8);
                    try items.append(a, try readOne(it, r, elem[1..2], depth + 1));
                    try items.append(a, try readOne(it, r, elem[2 .. elem.len - 1], depth + 1));
                } else try items.append(a, try readOne(it, r, elem, depth + 1));
            }
            if (r.pos != stop) return error.Truncated;
            break :blk try value.wrapList(a, items.items);
        },
        else => unreachable,
    };
}

const testing = std.testing;

fn roundTrip(it: *Interp, sig: []const u8, script: []const u8, want: []const u8) !void {
    var w: Writer = .{ .a = it.alloc() };
    try marshal(it, &w, sig, try it.eval(script));
    try testing.expectEqualSlices(u8, want, w.buf.items);
    var r: Reader = .{ .data = w.buf.items };
    const back = try unmarshal(it, &r, sig);
    try testing.expectEqual(w.buf.items.len, r.pos);
    try testing.expectEqualStrings(try it.str(try it.eval(script)), try it.str(back));
}

test "dbus: the wire format of the basic types" {
    var it: Interp = undefined;
    try it.init(testing.allocator);
    defer it.deinit();
    try roundTrip(&it, "y", "set _ 7", &.{7});
    try roundTrip(&it, "b", "set _ 1", &.{ 1, 0, 0, 0 });
    try roundTrip(&it, "n", "set _ -2", &.{ 0xfe, 0xff });
    try roundTrip(&it, "i", "set _ 258", &.{ 2, 1, 0, 0 });
    try roundTrip(&it, "x", "set _ -1", &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    // The string "foo": its length, its bytes, and a NUL.
    try roundTrip(&it, "s", "set _ foo", &.{ 3, 0, 0, 0, 'f', 'o', 'o', 0 });
    try roundTrip(&it, "g", "set _ as", &.{ 2, 'a', 's', 0 });
    try roundTrip(&it, "d", "set _ 1.0", &.{ 0, 0, 0, 0, 0, 0, 0xf0, 0x3f });
}

test "dbus: arrays, structs, dicts, and variants" {
    var it: Interp = undefined;
    try it.init(testing.allocator);
    defer it.deinit();
    try roundTrip(&it, "ai", "list 1 2", &.{ 8, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0 });
    // An array of int64: the length does not count the padding to 8.
    try roundTrip(&it, "ax", "list 5", &.{ 8, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0 });
    try roundTrip(&it, "(yu)", "list 1 2", &.{ 1, 0, 0, 0, 2, 0, 0, 0 });
    // A dict of a string and a variant of a uint32.
    try roundTrip(&it, "a{sv}", "list k {u 9}", &.{ 16, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 'k', 0, 1, 'u', 0, 0, 0, 0, 9, 0, 0, 0 });
    try roundTrip(&it, "v", "list as {a b}", &.{ 2, 'a', 's', 0, 14, 0, 0, 0, 1, 0, 0, 0, 'a', 0, 0, 0, 1, 0, 0, 0, 'b', 0 });
}

test "dbus: bad signatures and bad messages are errors" {
    var it: Interp = undefined;
    try it.init(testing.allocator);
    defer it.deinit();
    try testing.expect(typeEnd("a") == null);
    try testing.expect(typeEnd("()") == null);
    try testing.expect(typeEnd("{vs}") == null);
    try testing.expect(typeEnd("(i") == null);
    try testing.expectEqual(@as(?usize, 5), typeEnd("a{sv}i"));
    var w: Writer = .{ .a = it.alloc() };
    try testing.expectError(error.TclError, marshal(&it, &w, "y", .{ .int = 300 }));
    try testing.expectError(error.TclError, marshal(&it, &w, "(ii)", try it.eval("list 1")));
    var r: Reader = .{ .data = &.{ 9, 0, 0, 0, 'a' } };
    try testing.expectError(error.TclError, unmarshal(&it, &r, "s"));
    try testing.expectEqualStrings("bad D-Bus message: it ends early", try it.str(it.result));
}

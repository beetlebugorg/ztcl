//! The `encoding` command. It is part of the channel capability.
//!
//! A string of ztcl is UTF-8 text. A byte string is text where each
//! character is below 256. `convertto` makes a byte string from text,
//! and `convertfrom` makes text from a byte string. The encodings are
//! the ones with no table: `utf-8`, `iso8859-1`, `ascii`, `binary`,
//! `identity`, and `unicode` (UTF-16, little endian).
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

pub const names = [_][]const u8{ "ascii", "binary", "identity", "iso8859-1", "unicode", "utf-8" };

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn known(name: []const u8) bool {
    for (names) |n| if (eql(n, name)) return true;
    return false;
}

fn need(it: *Interp, name: []const u8) Error!void {
    if (!known(name)) return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP ENCODING {s}", .{name}), "unknown encoding \"{s}\"", .{name});
}

/// Appends one character as UTF-8.
fn put(a: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch blk: {
        // A surrogate half has the three-byte form.
        buf[0] = 0xE0 | @as(u8, @intCast(cp >> 12));
        buf[1] = 0x80 | @as(u8, @intCast((cp >> 6) & 63));
        buf[2] = 0x80 | @as(u8, @intCast(cp & 63));
        break :blk 3;
    };
    try out.appendSlice(a, buf[0..n]);
}

/// The characters of a text. A byte that starts no valid sequence is
/// one character with the value of the byte.
const Chars = struct {
    text: []const u8,
    at: usize = 0,

    fn next(c: *Chars) ?u21 {
        if (c.at >= c.text.len) return null;
        const b = c.text[c.at];
        const n = std.unicode.utf8ByteSequenceLength(b) catch 1;
        if (n > 1 and c.at + n <= c.text.len) {
            if (std.unicode.utf8Decode(c.text[c.at .. c.at + n])) |cp| {
                c.at += n;
                return cp;
            } else |_| {}
        }
        c.at += 1;
        return b;
    }
};

/// The byte string of a text in an encoding.
pub fn encode(it: *Interp, name: []const u8, text: []const u8) Error![]const u8 {
    const a = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    if (eql(name, "utf-8") or eql(name, "identity")) {
        for (text) |b| try put(a, &out, b);
        return out.items;
    }
    var chars: Chars = .{ .text = text };
    const limit: u21 = if (eql(name, "ascii")) 0x7f else 0xff;
    while (chars.next()) |cp| {
        if (eql(name, "unicode")) {
            if (cp >= 0x10000) {
                const v = cp - 0x10000;
                const hi: u21 = 0xD800 + (v >> 10);
                const lo: u21 = 0xDC00 + (v & 0x3ff);
                for ([_]u21{ hi & 0xff, hi >> 8, lo & 0xff, lo >> 8 }) |b| try put(a, &out, b);
            } else {
                try put(a, &out, cp & 0xff);
                try put(a, &out, cp >> 8);
            }
        } else if (eql(name, "binary")) {
            try put(a, &out, cp & 0xff);
        } else try put(a, &out, if (cp > limit) '?' else cp);
    }
    return out.items;
}

/// The text of a byte string in an encoding.
pub fn decode(it: *Interp, name: []const u8, bytes_text: []const u8) Error![]const u8 {
    const a = it.alloc();
    // The bytes of the string: each character is one byte.
    var raw: std.ArrayList(u8) = .empty;
    var chars: Chars = .{ .text = bytes_text };
    while (chars.next()) |cp| try raw.append(a, @truncate(cp));
    var out: std.ArrayList(u8) = .empty;
    if (eql(name, "utf-8") or eql(name, "identity")) {
        var bytes: Chars = .{ .text = raw.items };
        while (bytes.next()) |cp| try put(a, &out, cp);
        return out.items;
    }
    if (eql(name, "unicode")) {
        var i: usize = 0;
        while (i + 1 < raw.items.len) : (i += 2) {
            var cp: u21 = @as(u21, raw.items[i]) | (@as(u21, raw.items[i + 1]) << 8);
            if (cp >= 0xD800 and cp < 0xDC00 and i + 3 < raw.items.len) {
                const lo: u21 = @as(u21, raw.items[i + 2]) | (@as(u21, raw.items[i + 3]) << 8);
                if (lo >= 0xDC00 and lo < 0xE000) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    i += 2;
                }
            }
            try put(a, &out, cp);
        }
        return out.items;
    }
    for (raw.items) |b| try put(a, &out, if (eql(name, "ascii") and b > 0x7f) '?' else b);
    return out.items;
}

pub fn cmdEncoding(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("encoding option ?arg ...?");
    const a = it.alloc();
    const word = try it.str(argv[1]);
    const subs = [_][]const u8{ "convertfrom", "convertto", "dirs", "names", "system" };
    var sub: ?[]const u8 = null;
    var hits: usize = 0;
    for (subs) |s| {
        if (eql(s, word)) {
            sub = s;
            hits = 1;
            break;
        }
        if (word.len > 0 and std.mem.startsWith(u8, s, word)) {
            sub = s;
            hits += 1;
        }
    }
    if (hits != 1) return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be convertfrom, convertto, dirs, names, or system", .{word});
    const s = sub.?;
    const args = argv[2..];
    if (eql(s, "names")) {
        if (args.len != 0) return it.wrongArgs("encoding names");
        var out: std.ArrayList(Value) = .empty;
        for (names) |n| try out.append(a, .{ .str = n });
        return value.wrapList(a, out.items);
    }
    if (eql(s, "system")) {
        if (args.len > 1) return it.wrongArgs("encoding system ?encoding?");
        if (args.len == 1) {
            const name = try it.str(args[0]);
            try need(it, name);
            it.sys_encoding = try a.dupe(u8, name);
            return Value.empty;
        }
        return .{ .str = it.sys_encoding };
    }
    if (eql(s, "dirs")) {
        if (args.len > 1) return it.wrongArgs("encoding dirs ?dirList?");
        if (args.len == 1) {
            _ = it.list(args[0]) catch return it.fail("expected directory list but got \"{s}\"", .{try it.str(args[0])});
            it.enc_dirs = args[0];
        }
        return it.enc_dirs;
    }
    if (args.len < 1 or args.len > 2) {
        if (eql(s, "convertto")) return it.wrongArgs("encoding convertto ?encoding? data");
        return it.wrongArgs("encoding convertfrom ?encoding? data");
    }
    const name = if (args.len == 2) try it.str(args[0]) else it.sys_encoding;
    try need(it, name);
    const data = try it.str(args[args.len - 1]);
    if (eql(s, "convertto")) return .{ .str = try encode(it, name, data) };
    return .{ .str = try decode(it, name, data) };
}

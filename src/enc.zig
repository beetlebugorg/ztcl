//! The `encoding` command. It is part of the channel capability.
//!
//! A string of ztcl is UTF-8 text. A surrogate half with no pair has the
//! three-byte form (ED A0 80 to ED BF BF), as in Tcl. A byte string is text where each
//! character is below 256. `convertto` makes a byte string from text,
//! and `convertfrom` makes text from a byte string. The encodings are
//! the ones with no table: `utf-8`, `iso8859-1`, `ascii`, `binary`,
//! `identity`, and `unicode` (UTF-16, little endian).
//!
//! The other encodings come from the `.enc` files of Tcl, on demand. The
//! files are in the folders of `encoding dirs`, then in the `encoding`
//! folder of `$tcl_library`. The binary has no tables: a script that
//! uses no table encoding reads no file. A file has one of four types:
//!
//! - `S` (single-byte) and `M` (multi-byte): a lead byte has a page of
//!   its own, and the other bytes are characters of page 0.
//! - `D` (double-byte): each character has two bytes.
//! - `E` (escape-driven): an escape sequence selects one of the other
//!   tables, as in `iso2022-jp`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;
const fsroot = @import("fsroot.zig");
const vfs = @import("vfs.zig");
const sys = @import("sys.zig");

pub const names = [_][]const u8{ "ascii", "binary", "identity", "iso8859-1", "unicode", "utf-8" };

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn known(name: []const u8) bool {
    for (names) |n| if (eql(n, name)) return true;
    return false;
}

fn need(it: *Interp, name: []const u8) Error!void {
    if (!known(name) and try lookup(it, name) == null) return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP ENCODING {s}", .{name}), "unknown encoding \"{s}\"", .{name});
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

/// The characters of a text. A surrogate half in the three-byte form is
/// one character. A byte that starts no valid sequence is one character
/// with the value of the byte.
const Chars = struct {
    text: []const u8,
    at: usize = 0,

    fn next(c: *Chars) ?u21 {
        if (c.at >= c.text.len) return null;
        const b = c.text[c.at];
        const n = std.unicode.utf8ByteSequenceLength(b) catch 1;
        if (n > 1 and c.at + n <= c.text.len) {
            if (std.unicode.wtf8Decode(c.text[c.at .. c.at + n])) |cp| {
                c.at += n;
                return cp;
            } else |_| {}
        }
        c.at += 1;
        return b;
    }
};

/// What a conversion does with a byte or a character that the encoding
/// has no form for. `strict` stops the conversion with an error, as Tcl
/// 9.1 does by default. `replace` puts U+FFFD (or `?` in a byte
/// encoding). `tcl8` is the behavior of Tcl 8.6: a bad byte is the
/// character of the same value.
pub const Profile = enum { replace, strict, tcl8 };

/// The profile of a conversion with no `-profile` option.
pub fn defaultProfile(it: *const Interp) Profile {
    return if (it.tcl9()) .strict else .tcl8;
}

pub fn parseProfile(it: *Interp, v: Value) Error!Profile {
    const t = try it.str(v);
    return std.meta.stringToEnum(Profile, t) orelse
        it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL ENCODING PROFILE {s}", .{t}), "bad profile name \"{s}\": must be replace, strict, or tcl8", .{t});
}

/// The output of a conversion, and the index of the first byte or
/// character that `strict` stopped at.
pub const Result = struct { text: []const u8, fail: ?usize = null };

/// The byte string of a text in an encoding.
pub fn encode(it: *Interp, name: []const u8, text: []const u8, profile: Profile) Error!Result {
    const a = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    if (eql(name, "utf-8") or eql(name, "identity")) {
        for (text) |b| try put(a, &out, b);
        return .{ .text = out.items };
    }
    if (!known(name)) {
        const e = (try lookup(it, name)) orelse {
            try need(it, name);
            unreachable;
        };
        var st: State = .{};
        var raw: std.ArrayList(u8) = .empty;
        try fromUtf(it, e, &st, text, true, &raw);
        for (raw.items) |b| try put(a, &out, b);
        return .{ .text = out.items };
    }
    var chars: Chars = .{ .text = text };
    const limit: u21 = if (eql(name, "ascii")) 0x7f else 0xff;
    var at: usize = 0;
    while (chars.next()) |cp| : (at += 1) {
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
        } else if (cp > limit and profile == .strict) {
            return .{ .text = out.items, .fail = at };
        } else try put(a, &out, if (cp > limit) '?' else cp);
    }
    return .{ .text = out.items };
}

/// The text of a byte string in an encoding.
pub fn decode(it: *Interp, name: []const u8, bytes_text: []const u8, profile: Profile) Error!Result {
    const a = it.alloc();
    // The bytes of the string: each character is one byte.
    var raw: std.ArrayList(u8) = .empty;
    var chars: Chars = .{ .text = bytes_text };
    while (chars.next()) |cp| try raw.append(a, @truncate(cp));
    var out: std.ArrayList(u8) = .empty;
    if (eql(name, "utf-8") or eql(name, "identity")) {
        if (profile == .tcl8) {
            // As in Tcl 8.6: a high and a low surrogate half in a row are
            // one character, and C0 80 is NUL.
            var bytes: Chars = .{ .text = raw.items };
            while (true) {
                const start = bytes.at;
                const cp = bytes.next() orelse break;
                if (raw.items[start] == 0xC0 and bytes.at == start + 1 and bytes.at < raw.items.len and raw.items[bytes.at] == 0x80) {
                    bytes.at += 1;
                    try put(a, &out, 0);
                    continue;
                }
                if (cp >= 0xD800 and cp < 0xDC00) {
                    const at = bytes.at;
                    if (bytes.next()) |lo| {
                        if (lo >= 0xDC00 and lo < 0xE000 and bytes.at - at == 3) {
                            try put(a, &out, 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00));
                            continue;
                        }
                    }
                    bytes.at = at;
                }
                try put(a, &out, cp);
            }
            return .{ .text = out.items };
        }
        const r = raw.items;
        var i: usize = 0;
        while (i < r.len) {
            const n = std.unicode.utf8ByteSequenceLength(r[i]) catch 0;
            if (n > 0 and i + n <= r.len) {
                if (std.unicode.utf8Decode(r[i .. i + n])) |cp| {
                    try put(a, &out, cp);
                    i += n;
                    continue;
                } else |_| {}
            }
            if (profile == .strict) return .{ .text = out.items, .fail = i };
            try put(a, &out, 0xFFFD);
            i += 1;
        }
        return .{ .text = out.items };
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
        if (raw.items.len % 2 == 1) {
            if (profile == .strict) return .{ .text = out.items, .fail = raw.items.len - 1 };
            try put(a, &out, 0xFFFD);
        }
        return .{ .text = out.items };
    }
    if (!known(name)) {
        const e = (try lookup(it, name)) orelse {
            try need(it, name);
            unreachable;
        };
        var st: State = .{};
        _ = try toUtf(it, e, &st, raw.items, true, std.math.maxInt(usize), &out);
        return .{ .text = out.items };
    }
    const ascii = eql(name, "ascii");
    for (raw.items, 0..) |b, i| {
        if (ascii and b > 0x7f) {
            if (profile == .strict) return .{ .text = out.items, .fail = i };
            // With `tcl8`, the byte stays as the character of the byte,
            // as in Tcl 8.6.
            try put(a, &out, if (profile == .replace) 0xFFFD else b);
        } else try put(a, &out, b);
    }
    return .{ .text = out.items };
}

pub fn cmdEncoding(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("encoding option ?arg ...?");
    const a = it.alloc();
    const word = try it.str(argv[1]);
    const Sub = enum { convertfrom, convertto, dirs, names, profiles, system, user };
    // tclsh 8.6.16 and 9.0.4 both give the message and the code of an
    // unknown subcommand.
    const which = try @import("tcl9.zig").pick(it, Sub, word, .{ .v9_1 = &.{ .profiles, .user }, .code = "TCL LOOKUP SUBCOMMAND" });
    const args = argv[2..];
    switch (which) {
        .names => {
            if (args.len != 0) return it.wrongArgs("encoding names");
            var out: std.ArrayList(Value) = .empty;
            // Tcl does not list `binary`.
            for (names) |n| {
                if (!eql(n, "binary")) try out.append(a, .{ .str = n });
            }
            // The encoding files of the folders, and the loaded encodings.
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            for (names) |n| try seen.put(a, n, {});
            for (try folders(it)) |d| {
                const rel = (fsroot.normal(it, d) catch continue) orelse continue;
                const files = switch (fsroot.listDir(it, rel) catch continue) {
                    .ok => |x| x,
                    .err => continue,
                };
                for (files) |f| {
                    if (!std.mem.endsWith(u8, f, ".enc") or f.len == 4) continue;
                    const n = f[0 .. f.len - 4];
                    if ((try seen.getOrPut(a, n)).found_existing) continue;
                    try out.append(a, .{ .str = n });
                }
            }
            var loaded = it.enc_tables.keyIterator();
            while (loaded.next()) |n| {
                if ((try seen.getOrPut(a, n.*)).found_existing) continue;
                try out.append(a, .{ .str = n.* });
            }
            return value.wrapList(a, out.items);
        },
        .profiles => {
            if (args.len != 0) return it.wrongArgs("encoding profiles");
            return .{ .str = "replace strict tcl8" };
        },
        .user => {
            if (args.len != 0) return it.wrongArgs("encoding user");
            return .{ .str = it.sys_encoding };
        },
        .system => {
            if (args.len > 1) return it.wrongArgs("encoding system ?encoding?");
            if (args.len == 1) {
                const name = try it.str(args[0]);
                try need(it, name);
                it.sys_encoding = try a.dupe(u8, name);
                return Value.empty;
            }
            return .{ .str = it.sys_encoding };
        },
        .dirs => {
            if (args.len > 1) return it.wrongArgs("encoding dirs ?dirList?");
            if (args.len == 1) {
                _ = it.list(args[0]) catch return it.fail("expected directory list but got \"{s}\"", .{try it.str(args[0])});
                it.enc_dirs = args[0];
                it.enc_dirs_set = true;
                return args[0];
            }
            if (it.enc_dirs_set) return it.enc_dirs;
            var out: std.ArrayList(Value) = .empty;
            for (try folders(it)) |d| try out.append(a, .{ .str = d });
            return value.wrapList(a, out.items);
        },
        .convertfrom, .convertto => return convert(it, which == .convertto, args),
    }
}

fn convert(it: *Interp, to: bool, args_in: []const Value) Error!Value {
    var args = args_in;
    var profile = defaultProfile(it);
    var fail_var: ?[]const u8 = null;
    // The options of Tcl 9.1: -profile and -failindex, before the
    // encoding and the data.
    if (it.tcl9()) {
        while (args.len > 2) {
            const o = try it.str(args[0]);
            if (eql(o, "-profile")) {
                profile = try parseProfile(it, args[1]);
            } else if (eql(o, "-failindex")) {
                fail_var = try it.str(args[1]);
            } else if (o.len > 0 and o[0] == '-') {
                return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP INDEX option {s}", .{o}), "bad option \"{s}\": must be -profile or -failindex", .{o});
            } else break;
            args = args[2..];
        }
    }
    if (args.len < 1 or args.len > 2) {
        if (it.tcl9()) {
            if (to) return it.wrongArgs("encoding convertto ?-profile profile? ?-failindex var? encoding data\" or \"encoding convertto data");
            return it.wrongArgs("encoding convertfrom ?-profile profile? ?-failindex var? encoding data\" or \"encoding convertfrom data");
        }
        if (to) return it.wrongArgs("encoding convertto ?encoding? data");
        return it.wrongArgs("encoding convertfrom ?encoding? data");
    }
    const name = if (args.len == 2) try it.str(args[0]) else it.sys_encoding;
    try need(it, name);
    const data = try it.str(args[args.len - 1]);
    const r = if (to) try encode(it, name, data, profile) else try decode(it, name, data, profile);
    if (fail_var) |fv| {
        try it.setVar(fv, .{ .int = if (r.fail) |f| @intCast(f) else -1 });
        return .{ .str = r.text };
    }
    if (r.fail) |f| {
        const code = try std.fmt.allocPrint(it.alloc(), "TCL ENCODING ILLEGALSEQUENCE {d}", .{f});
        if (to) {
            var c: Chars = .{ .text = data };
            var k: usize = 0;
            var cp: u21 = 0;
            while (c.next()) |x| : (k += 1) if (k == f) {
                cp = x;
                break;
            };
            return it.failCode(code, "unexpected character at index {d}: 'U+{X:0>6}'", .{ f, cp });
        }
        var c: Chars = .{ .text = data };
        var k: usize = 0;
        var b: u21 = 0;
        while (c.next()) |x| : (k += 1) if (k == f) {
            b = x;
            break;
        };
        return it.failCode(code, "unexpected byte sequence starting at index {d}: '\\x{X:0>2}'", .{ f, b & 0xff });
    }
    return .{ .str = r.text };
}

// The table encodings.

const Page = [256]u16;

/// A table of an `.enc` file of type S, D, or M. A null page has no
/// characters.
pub const Table = struct {
    to: [256]?*Page = @splat(null),
    from: [256]?*Page = @splat(null),
    /// True for the first byte of a character of two bytes.
    lead: [256]bool = @splat(false),
    /// The bytes of a character with no code in the table.
    fallback: u16 = '?',

    fn toChar(t: *const Table, hi: u8, lo: u8) u16 {
        return if (t.to[hi]) |p| p[lo] else 0;
    }

    fn fromChar(t: *const Table, cp: u21) u16 {
        if (cp > 0xffff) return 0;
        return if (t.from[cp >> 8]) |p| p[cp & 0xff] else 0;
    }
};

/// An escape-driven encoding: a list of tables, each with the escape
/// sequence that selects it.
pub const Escape = struct {
    init: []const u8 = "",
    final: []const u8 = "",
    subs: []Sub = &.{},
    /// True for the first byte of a sequence.
    lead: [256]bool = @splat(false),

    const Sub = struct { name: []const u8, seq: []const u8, table: ?*const Table = null };
};

/// `utf16` is the `unicode` encoding of a channel: UTF-16, little endian.
pub const Encoding = union(enum) { table: *const Table, escape: *Escape, utf16 };

/// The state of a conversion that continues: the current table of an
/// escape-driven encoding, and true after the output of `init`.
pub const State = struct { sub: usize = 0, started: bool = false };

/// The encoding `name` of an `.enc` file. It is null when no folder has
/// the file or the file is not an encoding file. A loaded encoding stays
/// in the interpreter.
pub fn lookup(it: *Interp, name: []const u8) Error!?Encoding {
    if (it.enc_tables.get(name)) |e| return e;
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\\x00") != null or eql(name, ".") or eql(name, "..")) return null;
    const text = (try findFile(it, name)) orelse return null;
    const e = (try parse(it, text)) orelse return null;
    try it.enc_tables.put(it.alloc(), try it.alloc().dupe(u8, name), e);
    return e;
}

/// The folders of the encoding files: the list of `encoding dirs`, or
/// `$tcl_library/encoding` before a script sets that list.
fn folders(it: *Interp) Error![]const []const u8 {
    const a = it.alloc();
    var dirs: std.ArrayList([]const u8) = .empty;
    if (it.enc_dirs_set) {
        for (it.list(it.enc_dirs) catch &.{}) |d| try dirs.append(a, try it.str(d));
    } else if (it.getVarOpt("::tcl_library") catch null) |lib| try dirs.append(a, try std.fmt.allocPrint(a, "{s}/encoding", .{try it.str(lib)}));
    return dirs.items;
}

fn findFile(it: *Interp, name: []const u8) Error!?[]const u8 {
    for (try folders(it)) |d| {
        const path = try std.fmt.allocPrint(it.alloc(), "{s}/{s}.enc", .{ d, name });
        if (try readFile(it, path)) |t| return t;
    }
    return null;
}

/// The bytes of a file, or null when the file cannot be read.
fn readFile(it: *Interp, path: []const u8) Error!?[]const u8 {
    const a = it.alloc();
    if (vfs.gate(it, path, .channels, "couldn't read file") catch return null) |h| return vfs.read(it, h, "couldn't read file", path) catch null;
    const rel = (fsroot.normal(it, path) catch return null) orelse return null;
    const fd = switch (fsroot.openRel(it, rel, .{}, 0) catch return null) {
        .fd => |x| x,
        .err => return null,
    };
    defer sys.close(fd);
    var text: std.ArrayList(u8) = .empty;
    while (true) {
        try text.ensureUnusedCapacity(a, 16384);
        const got = switch (sys.readFile(fd, text.unusedCapacitySlice())) {
            .n => |x| x,
            .err => return null,
        };
        if (got == 0) break;
        text.items.len += got;
        try it.checkMem();
    }
    return text.items;
}

/// The hexadecimal digits of a text, with white space between them.
const Hex = struct {
    text: []const u8,
    at: usize = 0,

    fn digits(h: *Hex, n: usize) ?u16 {
        var v: u16 = 0;
        var k: usize = 0;
        while (k < n) {
            if (h.at >= h.text.len) return null;
            const c = h.text[h.at];
            h.at += 1;
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                if (k == 0) continue;
                return null;
            }
            v = (v << 4) | (std.fmt.charToDigit(c, 16) catch return null);
            k += 1;
        }
        return v;
    }
};

fn parse(it: *Interp, text: []const u8) Error!?Encoding {
    const a = it.alloc();
    var lines = std.mem.splitScalar(u8, text, '\n');
    var kind: u8 = 0;
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        kind = l[0];
        break;
    }
    if (kind == 'E') return try parseEscape(it, &lines);
    if (kind != 'S' and kind != 'D' and kind != 'M') return null;
    var head = std.mem.tokenizeAny(u8, lines.next() orelse return null, " \t\r");
    const fallback = std.fmt.parseInt(u16, head.next() orelse return null, 16) catch return null;
    const symbol = !eql(head.next() orelse "0", "0");
    const count = std.fmt.parseInt(usize, head.next() orelse return null, 10) catch return null;
    const t = try a.create(Table);
    t.* = .{ .fallback = fallback };
    var hex: Hex = .{ .text = lines.rest() };
    for (0..@min(count, 256)) |_| {
        const hi = hex.digits(2) orelse return null;
        const p = try a.create(Page);
        for (p) |*v| v.* = hex.digits(4) orelse return null;
        t.to[@as(u8, @truncate(hi))] = p;
    }
    for (1..256) |hi| t.lead[hi] = kind == 'D' or t.to[hi] != null;
    if (kind == 'D') t.lead[0] = true;
    // The inverse table. A later code of a character replaces an
    // earlier one.
    for (0..256) |hi| {
        const p = t.to[hi] orelse continue;
        for (p, 0..) |cp, lo| {
            if (cp == 0) continue;
            (try fromPage(a, t, cp >> 8))[cp & 0xff] = @intCast((hi << 8) | lo);
        }
    }
    if (kind == 'M') {
        if (t.from[0]) |p| {
            if (p['\\'] == 0) p['\\'] = '\\';
        }
    }
    if (symbol) {
        // A symbol font shows the characters of page 0 as they are.
        const p = try fromPage(a, t, 0);
        for (0..256) |lo| {
            if (t.toChar(0, @intCast(lo)) != 0) p[lo] = @intCast(lo);
        }
    }
    // An `R` section gives more codes for the inverse table: each line
    // has the code, then the characters that take it.
    const rest = text[@min(hex.at + (text.len - lines.rest().len), text.len)..];
    var more = std.mem.splitScalar(u8, rest, '\n');
    var in_r = false;
    while (more.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0) continue;
        if (!in_r) {
            if (l[0] != 'R') break;
            in_r = true;
            continue;
        }
        var words = std.mem.tokenizeAny(u8, l, " \t");
        const to = std.fmt.parseInt(u16, words.next() orelse continue, 16) catch continue;
        if (to == 0) continue;
        while (words.next()) |w| {
            const from = std.fmt.parseInt(u16, w, 16) catch continue;
            if (from != 0) (try fromPage(a, t, from >> 8))[from & 0xff] = to;
        }
    }
    return .{ .table = t };
}

fn fromPage(a: std.mem.Allocator, t: *Table, hi: usize) !*Page {
    if (t.from[hi]) |p| return p;
    const p = try a.create(Page);
    p.* = @splat(0);
    t.from[hi] = p;
    return p;
}

/// The words of a line of an escape-driven file, as a Tcl list: a word
/// in braces is as it is, and a backslash starts an escape.
fn escapeWords(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and std.ascii.isWhitespace(line[i])) i += 1;
        if (i >= line.len) break;
        if (line[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, line, i, '}') orelse line.len;
            try words.append(a, line[i + 1 .. end]);
            i = end + 1;
            continue;
        }
        var w: std.ArrayList(u8) = .empty;
        while (i < line.len and !std.ascii.isWhitespace(line[i])) {
            if (line[i] == '\\' and i + 1 < line.len) {
                i += 1;
                if (line[i] == 'x') {
                    var v: u8 = 0;
                    var k: usize = 0;
                    i += 1;
                    while (k < 2 and i < line.len) : (k += 1) {
                        const d = std.fmt.charToDigit(line[i], 16) catch break;
                        v = (v << 4) | d;
                        i += 1;
                    }
                    try w.append(a, v);
                    continue;
                }
            }
            try w.append(a, line[i]);
            i += 1;
        }
        try words.append(a, w.items);
    }
    return words.items;
}

fn parseEscape(it: *Interp, lines: *std.mem.SplitIterator(u8, .scalar)) Error!?Encoding {
    const a = it.alloc();
    const x = try a.create(Escape);
    x.* = .{};
    var subs: std.ArrayList(Escape.Sub) = .empty;
    while (lines.next()) |raw| {
        const w = try escapeWords(a, std.mem.trim(u8, raw, " \t\r"));
        if (w.len < 2) continue;
        if (eql(w[0], "name")) continue;
        if (eql(w[0], "init")) {
            x.init = w[1];
        } else if (eql(w[0], "final")) {
            x.final = w[1];
        } else try subs.append(a, .{ .name = w[0], .seq = w[1] });
    }
    x.subs = subs.items;
    for (x.subs) |s| {
        if (s.seq.len > 0) x.lead[s.seq[0]] = true;
    }
    if (x.init.len > 0) x.lead[x.init[0]] = true;
    if (x.final.len > 0) x.lead[x.final[0]] = true;
    if (x.subs.len == 0) return null;
    return .{ .escape = x };
}

/// The table of the encoding `ascii` or `iso8859-1`, for the escape
/// encodings that select them.
fn latinTable(a: std.mem.Allocator, ascii: bool) !*const Table {
    const t = try a.create(Table);
    t.* = .{};
    const to = try a.create(Page);
    const from = try a.create(Page);
    for (0..256) |i| {
        const v: u16 = if (ascii and i >= 0x80) 0 else @intCast(i);
        to[i] = v;
        from[i] = v;
    }
    t.to[0] = to;
    t.from[0] = from;
    return t;
}

/// The table of sub-encoding `k`. It loads the table on first use.
fn subTable(it: *Interp, x: *Escape, k: usize) Error!*const Table {
    const s = &x.subs[k];
    if (s.table) |t| return t;
    if (eql(s.name, "ascii") or eql(s.name, "iso8859-1")) {
        s.table = try latinTable(it.alloc(), eql(s.name, "ascii"));
    } else if (try lookup(it, s.name)) |e| switch (e) {
        .table => |t| s.table = t,
        .escape, .utf16 => {},
    };
    return s.table orelse it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP ENCODING {s}", .{s.name}), "unknown encoding \"{s}\"", .{s.name});
}

/// The encoding `name` for a channel. It is null for an encoding that
/// a channel converts with no table: `utf-8`, `identity`, `binary`, and
/// `iso8859-1`. `unicode` is `utf16`.
pub fn forChannel(it: *Interp, name: []const u8) Error!?Encoding {
    if (eql(name, "unicode")) return .utf16;
    if (eql(name, "ascii")) {
        if (it.enc_tables.get(name)) |e| return e;
        const e: Encoding = .{ .table = try latinTable(it.alloc(), true) };
        try it.enc_tables.put(it.alloc(), "ascii", e);
        return e;
    }
    return lookup(it, name);
}

pub const Got = struct { used: usize, chars: usize };

/// Appends the text of the bytes `src` to `out`, at most `limit`
/// characters. The first bytes of a character with no end stay: `used`
/// stops before them, unless `end` is true.
pub fn toUtf(it: *Interp, e: Encoding, st: *State, src: []const u8, end: bool, limit: usize, out: *std.ArrayList(u8)) Error!Got {
    const a = it.alloc();
    var i: usize = 0;
    var n: usize = 0;
    switch (e) {
        .utf16 => while (i + 1 < src.len and n < limit) : (n += 1) {
            var cp: u21 = @as(u21, src[i]) | (@as(u21, src[i + 1]) << 8);
            if (cp >= 0xD800 and cp < 0xDC00) {
                // The second half of a pair is not here yet.
                if (i + 3 >= src.len and !end) break;
                if (i + 3 < src.len) {
                    const lo: u21 = @as(u21, src[i + 2]) | (@as(u21, src[i + 3]) << 8);
                    if (lo >= 0xDC00 and lo < 0xE000) {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        i += 2;
                    }
                }
            }
            try put(a, out, cp);
            i += 2;
        } else if (end and i < src.len and n < limit) {
            try put(a, out, 0xFFFD);
            i += 1;
            n += 1;
        },
        .table => |t| while (i < src.len and n < limit) : (n += 1) {
            const b = src[i];
            var two = false;
            var ch: u16 = undefined;
            if (t.lead[b]) {
                if (i + 1 >= src.len) {
                    if (!end) break;
                    ch = b;
                } else {
                    ch = t.toChar(b, src[i + 1]);
                    two = true;
                }
            } else ch = t.toChar(0, b);
            // A code with no character is the character of its byte.
            if (ch == 0 and b != 0) {
                ch = b;
                two = false;
            }
            try put(a, out, ch);
            i += if (two) 2 else 1;
        },
        .escape => |x| {
            var tab: ?*const Table = null;
            while (i < src.len and n < limit) {
                const b = src[i];
                if (x.lead[b]) {
                    const left = src.len - i;
                    const at = src[i..];
                    var longest = @max(x.init.len, x.final.len);
                    var checked: usize = 0;
                    if (x.init.len <= left) checked += 1;
                    if (x.init.len > 0 and std.mem.startsWith(u8, at, x.init)) {
                        i += x.init.len;
                        continue;
                    }
                    if (x.final.len <= left) checked += 1;
                    if (x.final.len > 0 and std.mem.startsWith(u8, at, x.final)) {
                        i += x.final.len;
                        continue;
                    }
                    var hit: ?usize = null;
                    for (x.subs, 0..) |s, k| {
                        longest = @max(longest, s.seq.len);
                        if (s.seq.len > left) continue;
                        checked += 1;
                        if (s.seq.len > 0 and std.mem.startsWith(u8, at, s.seq)) {
                            hit = k;
                            break;
                        }
                    }
                    if (hit) |k| {
                        st.sub = k;
                        tab = null;
                        i += x.subs[k].seq.len;
                        continue;
                    }
                    // An unknown sequence is dropped. A sequence that
                    // can continue in the next bytes waits for them.
                    if (checked == x.subs.len + 2 or end) {
                        i = @min(src.len, i + longest);
                        continue;
                    }
                    break;
                }
                const t = tab orelse try subTable(it, x, st.sub);
                tab = t;
                var hi: u8 = 0;
                var lo = b;
                if (t.lead[b]) {
                    if (i + 1 >= src.len) break;
                    hi = b;
                    lo = src[i + 1];
                    i += 1;
                }
                try put(a, out, t.toChar(hi, lo));
                i += 1;
                n += 1;
            }
        },
    }
    return .{ .used = i, .chars = n };
}

fn putWord(a: std.mem.Allocator, out: *std.ArrayList(u8), t: *const Table, word: u16) !void {
    if (t.lead[word >> 8]) try out.append(a, @intCast(word >> 8));
    try out.append(a, @truncate(word));
}

/// Appends the bytes of the text `text` to `out`. With `end`, an
/// escape-driven encoding goes back to its first table and adds its
/// `final` bytes.
pub fn fromUtf(it: *Interp, e: Encoding, st: *State, text: []const u8, end: bool, out: *std.ArrayList(u8)) Error!void {
    const a = it.alloc();
    var chars: Chars = .{ .text = text };
    switch (e) {
        .utf16 => while (chars.next()) |cp| {
            if (cp >= 0x10000) {
                const v = cp - 0x10000;
                const hi: u21 = 0xD800 + (v >> 10);
                const lo: u21 = 0xDC00 + (v & 0x3ff);
                try out.appendSlice(a, &.{ @truncate(hi), @truncate(hi >> 8), @truncate(lo), @truncate(lo >> 8) });
            } else try out.appendSlice(a, &.{ @truncate(cp), @truncate(cp >> 8) });
        },
        .table => |t| while (chars.next()) |cp| {
            var word = t.fromChar(cp);
            if (word == 0 and cp != 0) word = t.fallback;
            try putWord(a, out, t, word);
        },
        .escape => |x| {
            if (!st.started) {
                st.started = true;
                st.sub = 0;
                try out.appendSlice(a, x.init);
            }
            var t = try subTable(it, x, st.sub);
            while (chars.next()) |cp| {
                var word = t.fromChar(cp);
                if (word == 0 and cp != 0) {
                    const old = st.sub;
                    var hit: ?usize = null;
                    for (0..x.subs.len) |k| {
                        const tk = try subTable(it, x, k);
                        word = tk.fromChar(cp);
                        if (word != 0) {
                            hit = k;
                            t = tk;
                            break;
                        }
                    }
                    if (hit) |k| {
                        st.sub = k;
                    } else {
                        t = try subTable(it, x, old);
                        word = t.fallback;
                    }
                    if (st.sub != old) try out.appendSlice(a, x.subs[st.sub].seq);
                }
                try putWord(a, out, t, word);
            }
            if (end) {
                if (st.sub != 0) try out.appendSlice(a, x.subs[0].seq);
                try out.appendSlice(a, x.final);
                st.* = .{};
            }
        },
    }
}

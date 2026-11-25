//! The key decoder of the line editor.
//!
//! A terminal sends bytes. `Decoder.feed` keeps them, and `next` gives
//! one key at a time, or null while a sequence is not complete:
//!
//! - A printable byte or a UTF-8 sequence is a character.
//! - A byte below 0x20 is a control key. Enter is CR or LF, Tab is 0x09,
//!   and Backspace is 0x7F or 0x08.
//! - `ESC [` starts a CSI sequence: parameters, then a final byte. The
//!   arrows, Home, End, Insert, Delete, Page Up, Page Down, and Shift-Tab
//!   come this way, with the modifier parameter of xterm (`1;5C` is
//!   Ctrl-Right). `ESC O` is the same in the application cursor mode.
//! - `ESC [200~` starts a bracketed paste, and `ESC [201~` ends it. The
//!   bytes between them are one `paste` key, with no decoding.
//! - `ESC` and another key is that key with Alt.
//! - A lone `ESC` is ambiguous until the next byte comes. The caller
//!   waits a short time, then calls `next` with `flush` true, and the
//!   decoder gives the Escape key.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Special = enum {
    enter,
    tab,
    shift_tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    insert,
    delete,
    page_up,
    page_down,
};

pub const Code = union(enum) {
    /// A printable code point.
    char: u21,
    /// A control key: the lower-case letter, or one of `@ [ \ ] ^ _`.
    ctrl: u8,
    special: Special,
    /// The bytes of a bracketed paste.
    paste: []const u8,
};

pub const Key = struct {
    code: Code,
    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,

    pub fn ch(c: u21) Key {
        return .{ .code = .{ .char = c } };
    }

    pub fn ctl(c: u8) Key {
        return .{ .code = .{ .ctrl = c } };
    }

    pub fn sp(s: Special) Key {
        return .{ .code = .{ .special = s } };
    }

    pub fn eql(a: Key, b: Key) bool {
        if (a.alt != b.alt or a.ctrl != b.ctrl or a.shift != b.shift) return false;
        return switch (a.code) {
            .char => |c| b.code == .char and b.code.char == c,
            .ctrl => |c| b.code == .ctrl and b.code.ctrl == c,
            .special => |s| b.code == .special and b.code.special == s,
            .paste => false,
        };
    }
};

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";

pub const Decoder = struct {
    a: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// The bytes of the last paste. A `paste` key points into it, and the
    /// next call of `next` reuses it.
    paste: std.ArrayList(u8) = .empty,

    pub fn init(a: std.mem.Allocator) Decoder {
        return .{ .a = a };
    }

    pub fn deinit(d: *Decoder) void {
        d.buf.deinit(d.a);
        d.paste.deinit(d.a);
    }

    pub fn feed(d: *Decoder, bytes: []const u8) std.mem.Allocator.Error!void {
        try d.buf.appendSlice(d.a, bytes);
    }

    /// True when bytes wait for decoding.
    pub fn pending(d: *const Decoder) bool {
        return d.buf.items.len > 0;
    }

    fn drop(d: *Decoder, n: usize) void {
        std.mem.copyForwards(u8, d.buf.items, d.buf.items[n..]);
        d.buf.items.len -= n;
    }

    /// The next key, or null when the bytes are not a complete key yet.
    /// With `flush`, an incomplete escape sequence gives what it has: a
    /// lone ESC is the Escape key.
    pub fn next(d: *Decoder, flush: bool) std.mem.Allocator.Error!?Key {
        const b = d.buf.items;
        if (b.len == 0) return null;
        if (std.mem.startsWith(u8, b, paste_start)) {
            const end = std.mem.indexOf(u8, b, paste_end) orelse return null;
            d.paste.clearRetainingCapacity();
            try d.paste.appendSlice(d.a, b[paste_start.len..end]);
            d.drop(end + paste_end.len);
            return .{ .code = .{ .paste = d.paste.items } };
        }
        if (b[0] != 0x1B) {
            const r = single(b) orelse return null;
            d.drop(r.len);
            return r.key;
        }
        // An escape sequence.
        if (b.len == 1) {
            if (!flush) return null;
            d.drop(1);
            return Key.sp(.escape);
        }
        if (b[1] == '[' or b[1] == 'O') {
            const r = csi(b) orelse {
                if (std.mem.startsWith(u8, paste_start, b) and !flush) return null;
                if (!flush) return null;
                d.drop(b.len);
                return Key.sp(.escape);
            };
            d.drop(r.len);
            return r.key;
        }
        if (b[1] == 0x1B) {
            d.drop(1);
            return Key.sp(.escape);
        }
        // Alt and a key.
        const r = single(b[1..]) orelse {
            if (!flush) return null;
            d.drop(1);
            return Key.sp(.escape);
        };
        d.drop(1 + r.len);
        var k = r.key;
        k.alt = true;
        return k;
    }

    const One = struct { key: Key, len: usize };

    fn single(b: []const u8) ?One {
        const c = b[0];
        switch (c) {
            '\r', '\n' => return .{ .key = Key.sp(.enter), .len = 1 },
            '\t' => return .{ .key = Key.sp(.tab), .len = 1 },
            0x7F, 0x08 => return .{ .key = Key.sp(.backspace), .len = 1 },
            0x00 => return .{ .key = Key.ctl('@'), .len = 1 },
            0x01...0x07, 0x0B, 0x0C, 0x0E...0x1A => return .{ .key = Key.ctl(c - 1 + 'a'), .len = 1 },
            0x1C...0x1F => return .{ .key = Key.ctl(c - 0x1C + '\\'), .len = 1 },
            0x1B => return .{ .key = Key.sp(.escape), .len = 1 },
            else => {},
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch return .{ .key = Key.ch(c), .len = 1 };
        if (b.len < n) return null;
        const cp = std.unicode.utf8Decode(b[0..n]) catch return .{ .key = Key.ch(c), .len = 1 };
        return .{ .key = Key.ch(cp), .len = n };
    }

    /// A CSI or SS3 sequence at the start of `b`: `ESC [ params final` or
    /// `ESC O final`. Null when it is not complete.
    fn csi(b: []const u8) ?One {
        var j: usize = 2;
        while (j < b.len and (b[j] < 0x40 or b[j] > 0x7E)) j += 1;
        if (j >= b.len) return null;
        const final = b[j];
        const params = b[2..j];
        // The first number and the modifier (the second number).
        var it = std.mem.splitScalar(u8, params, ';');
        const p1 = std.fmt.parseInt(u16, it.next() orelse "", 10) catch 1;
        const p2 = std.fmt.parseInt(u16, it.next() orelse "", 10) catch 1;
        var key: Key = switch (final) {
            'A' => Key.sp(.up),
            'B' => Key.sp(.down),
            'C' => Key.sp(.right),
            'D' => Key.sp(.left),
            'H' => Key.sp(.home),
            'F' => Key.sp(.end),
            'Z' => Key.sp(.shift_tab),
            '~' => switch (p1) {
                1, 7 => Key.sp(.home),
                2 => Key.sp(.insert),
                3 => Key.sp(.delete),
                4, 8 => Key.sp(.end),
                5 => Key.sp(.page_up),
                6 => Key.sp(.page_down),
                else => return .{ .key = Key.sp(.escape), .len = j + 1 },
            },
            // An unknown key: no key, so the caller drops it.
            else => return .{ .key = Key.sp(.escape), .len = j + 1 },
        };
        // xterm modifiers: 1 + (shift 1, alt 2, ctrl 4).
        if (p2 > 1) {
            const m = p2 - 1;
            key.shift = m & 1 != 0;
            key.alt = m & 2 != 0;
            key.ctrl = m & 4 != 0;
        }
        return .{ .key = key, .len = j + 1 };
    }
};

test "the decoder" {
    const t = std.testing;
    var d = Decoder.init(t.allocator);
    defer d.deinit();
    try d.feed("a\x01\x1b[A\x1b[1;5C\x1bb\xc3\xa9\x7f\x1b[3~\r");
    try t.expect((try d.next(false)).?.eql(Key.ch('a')));
    try t.expect((try d.next(false)).?.eql(Key.ctl('a')));
    try t.expect((try d.next(false)).?.eql(Key.sp(.up)));
    const cr = (try d.next(false)).?;
    try t.expect(cr.ctrl and cr.code.special == .right);
    const ab = (try d.next(false)).?;
    try t.expect(ab.alt and ab.code.char == 'b');
    try t.expect((try d.next(false)).?.eql(Key.ch(0xE9)));
    try t.expect((try d.next(false)).?.eql(Key.sp(.backspace)));
    try t.expect((try d.next(false)).?.eql(Key.sp(.delete)));
    try t.expect((try d.next(false)).?.eql(Key.sp(.enter)));
    try t.expectEqual(@as(?Key, null), try d.next(false));
    // A lone ESC waits, then flushes.
    try d.feed("\x1b");
    try t.expectEqual(@as(?Key, null), try d.next(false));
    try t.expect((try d.next(true)).?.eql(Key.sp(.escape)));
    // A paste is one key, and a split sequence waits.
    try d.feed("\x1b[200~a\nb");
    try t.expectEqual(@as(?Key, null), try d.next(false));
    try d.feed("\x1b[201~x");
    const p = (try d.next(false)).?;
    try t.expectEqualStrings("a\nb", p.code.paste);
    try t.expect((try d.next(false)).?.eql(Key.ch('x')));
    // A split UTF-8 sequence waits.
    try d.feed("\xe4\xb8");
    try t.expectEqual(@as(?Key, null), try d.next(false));
    try d.feed("\xad");
    try t.expect((try d.next(false)).?.eql(Key.ch(0x4E2D)));
}

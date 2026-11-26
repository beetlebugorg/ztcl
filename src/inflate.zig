//! A deflate decoder (RFC 1951) into a buffer of a fixed size, for the
//! zip entries of `zipread.zig`.
//!
//! The decoder follows the method of puff.c by Mark Adler: each Huffman
//! code is canonical, so a table of the count of codes of each length
//! and the symbols in code order is enough. The decode reads one bit at
//! a time, and at each length compares the code with the first code of
//! that length. The decoder checks each input read, each code table
//! (no over-subscribed lengths), each distance against the output so
//! far, and each write against the end of the buffer. Bad input is an
//! error and never a crash. A deflate stream from an untrusted zip
//! goes here, because the decoder of the Zig standard library ends
//! with an integer overflow panic on some bad input.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Error = error{ BadData, TooLong };

const max_bits = 15;

const Huffman = struct {
    count: [max_bits + 1]u16,
    symbol: []u16,
};

const State = struct {
    in: []const u8,
    pos: usize = 0,
    bitbuf: u32 = 0,
    bitcnt: u5 = 0,
    out: []u8,
    n: usize = 0,

    fn bits(s: *State, need: u5) Error!u32 {
        var val: u32 = s.bitbuf;
        var cnt: u32 = s.bitcnt;
        while (cnt < need) {
            if (s.pos >= s.in.len) return error.BadData;
            val |= @as(u32, s.in[s.pos]) << @intCast(cnt);
            s.pos += 1;
            cnt += 8;
        }
        s.bitbuf = val >> need;
        s.bitcnt = @intCast(cnt - need);
        return val & ((@as(u32, 1) << need) - 1);
    }

    fn decode(s: *State, h: *const Huffman) Error!u16 {
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        var len: usize = 1;
        while (len <= max_bits) : (len += 1) {
            code |= @intCast(try s.bits(1));
            const count: i32 = h.count[len];
            if (code - count < first) return h.symbol[@intCast(index + (code - first))];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return error.BadData;
    }

    fn put(s: *State, b: u8) Error!void {
        if (s.n >= s.out.len) return error.TooLong;
        s.out[s.n] = b;
        s.n += 1;
    }
};

/// Fills `h` from the code lengths. Gives the count of missing codes
/// (0 for a complete code). Over-subscribed lengths are an error.
fn build(h: *Huffman, lengths: []const u8) Error!i32 {
    @memset(&h.count, 0);
    for (lengths) |l| h.count[l] += 1;
    if (h.count[0] == lengths.len) return 0;
    var left: i32 = 1;
    for (1..max_bits + 1) |len| {
        left <<= 1;
        left -= h.count[len];
        if (left < 0) return error.BadData;
    }
    var offs: [max_bits + 1]u16 = undefined;
    offs[1] = 0;
    for (1..max_bits) |len| offs[len + 1] = offs[len] + h.count[len];
    for (lengths, 0..) |l, sym| {
        if (l != 0) {
            h.symbol[offs[l]] = @intCast(sym);
            offs[l] += 1;
        }
    }
    return left;
}

const len_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [29]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

fn codes(s: *State, lencode: *const Huffman, distcode: *const Huffman) Error!void {
    while (true) {
        const sym = try s.decode(lencode);
        if (sym < 256) {
            try s.put(@intCast(sym));
        } else if (sym == 256) {
            return;
        } else {
            const li = sym - 257;
            if (li >= 29) return error.BadData;
            const len = len_base[li] + try s.bits(len_extra[li]);
            const di = try s.decode(distcode);
            if (di >= 30) return error.BadData;
            const dist = dist_base[di] + try s.bits(dist_extra[di]);
            if (dist > s.n) return error.BadData;
            if (s.out.len - s.n < len) return error.TooLong;
            // The copy can overlap its source, so it goes byte by byte.
            for (0..len) |_| {
                s.out[s.n] = s.out[s.n - dist];
                s.n += 1;
            }
        }
    }
}

fn stored(s: *State) Error!void {
    s.bitbuf = 0;
    s.bitcnt = 0;
    if (s.in.len - s.pos < 4) return error.BadData;
    const len = std.mem.readInt(u16, s.in[s.pos..][0..2], .little);
    const nlen = std.mem.readInt(u16, s.in[s.pos + 2 ..][0..2], .little);
    if (len != ~nlen) return error.BadData;
    s.pos += 4;
    if (s.in.len - s.pos < len) return error.BadData;
    if (s.out.len - s.n < len) return error.TooLong;
    @memcpy(s.out[s.n..][0..len], s.in[s.pos..][0..len]);
    s.pos += len;
    s.n += len;
}

fn fixed(s: *State) Error!void {
    var lsym: [288]u16 = undefined;
    var dsym: [30]u16 = undefined;
    var lencode: Huffman = .{ .count = undefined, .symbol = &lsym };
    var distcode: Huffman = .{ .count = undefined, .symbol = &dsym };
    var lengths: [288]u8 = undefined;
    @memset(lengths[0..144], 8);
    @memset(lengths[144..256], 9);
    @memset(lengths[256..280], 7);
    @memset(lengths[280..288], 8);
    _ = try build(&lencode, &lengths);
    @memset(lengths[0..30], 5);
    _ = try build(&distcode, lengths[0..30]);
    try codes(s, &lencode, &distcode);
}

const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

fn dynamic(s: *State) Error!void {
    const nlen = try s.bits(5) + 257;
    const ndist = try s.bits(5) + 1;
    const ncode = try s.bits(4) + 4;
    if (nlen > 286 or ndist > 30) return error.BadData;
    var lengths: [320]u8 = @splat(0);
    for (0..ncode) |i| lengths[order[i]] = @intCast(try s.bits(3));
    var lsym: [288]u16 = undefined;
    var dsym: [30]u16 = undefined;
    var lencode: Huffman = .{ .count = undefined, .symbol = &lsym };
    var distcode: Huffman = .{ .count = undefined, .symbol = &dsym };
    if (try build(&lencode, lengths[0..19]) != 0) return error.BadData;
    lengths = @splat(0);
    var index: usize = 0;
    while (index < nlen + ndist) {
        var sym = try s.decode(&lencode);
        if (sym < 16) {
            lengths[index] = @intCast(sym);
            index += 1;
            continue;
        }
        var len: u8 = 0;
        if (sym == 16) {
            if (index == 0) return error.BadData;
            len = lengths[index - 1];
            sym = @intCast(3 + try s.bits(2));
        } else if (sym == 17) {
            sym = @intCast(3 + try s.bits(3));
        } else {
            sym = @intCast(11 + try s.bits(7));
        }
        if (index + sym > nlen + ndist) return error.BadData;
        @memset(lengths[index..][0..sym], len);
        index += sym;
    }
    if (lengths[256] == 0) return error.BadData;
    // An incomplete code is allowed only for a single code.
    const lleft = try build(&lencode, lengths[0..nlen]);
    if (lleft != 0 and nlen - lencode.count[0] != 1) return error.BadData;
    const dleft = try build(&distcode, lengths[nlen..][0..ndist]);
    if (dleft != 0 and ndist - distcode.count[0] != 1) return error.BadData;
    try codes(s, &lencode, &distcode);
}

/// Decodes the raw deflate stream `in` into `out`. Gives the count of
/// bytes written. More output than `out` holds is `error.TooLong`.
pub fn inflate(out: []u8, in: []const u8) Error!usize {
    var s: State = .{ .in = in, .out = out };
    while (true) {
        const last = try s.bits(1);
        switch (try s.bits(2)) {
            0 => try stored(&s),
            1 => try fixed(&s),
            2 => try dynamic(&s),
            else => return error.BadData,
        }
        if (last == 1) return s.n;
    }
}

test "inflate: the output of the Zig compressor" {
    const a = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    for (0..2000) |i| try text.print(a, "line {d} of {d}\n", .{ i, i % 7 });
    var cw: std.Io.Writer.Allocating = try .initCapacity(a, 1 << 16);
    defer cw.deinit();
    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var c = try std.compress.flate.Compress.init(&cw.writer, &buf, .raw, .default);
    try c.writer.writeAll(text.items);
    try c.finish();
    const out = try a.alloc(u8, text.items.len);
    defer a.free(out);
    try std.testing.expectEqual(text.items.len, try inflate(out, cw.written()));
    try std.testing.expectEqualSlices(u8, text.items, out);
    try std.testing.expectError(error.TooLong, inflate(out[0 .. out.len - 1], cw.written()));
}

test "inflate: a stored block and bad input" {
    var out: [8]u8 = undefined;
    // A last stored block of 3 bytes.
    try std.testing.expectEqual(@as(usize, 3), try inflate(&out, &.{ 1, 3, 0, 0xfc, 0xff, 'a', 'b', 'c' }));
    try std.testing.expectEqualStrings("abc", out[0..3]);
    try std.testing.expectError(error.BadData, inflate(&out, &.{ 1, 3, 0, 0xfc, 0xfe, 'a', 'b', 'c' }));
    try std.testing.expectError(error.BadData, inflate(&out, &.{0x07}));
    try std.testing.expectError(error.BadData, inflate(&out, &.{}));
    // Random input gives an error or output, and never a crash.
    var prng = std.Random.DefaultPrng.init(40);
    var in: [64]u8 = undefined;
    var big: [4096]u8 = undefined;
    for (0..20000) |_| {
        prng.random().bytes(&in);
        _ = inflate(&big, &in) catch {};
    }
}

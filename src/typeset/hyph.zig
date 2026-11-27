//! Hyphenation with the patterns of Liang ("Word Hy-phen-a-tion by
//! Com-put-er", Stanford, 1983).
//!
//! A pattern is a string of letters with a digit between some of them,
//! such as `.ach4` or `a1b`. The dot marks the start or the end of a
//! word. To hyphenate a word, put a dot at each end, find each pattern
//! that matches a part of it, and keep the largest digit at each place
//! between two letters. An odd digit is a place where a hyphen can go.
//! A list of exceptions gives the places for single words.
//!
//! The patterns go in a trie: each node has its first child and its next
//! sibling, and the digits of a pattern that ends at the node. The walk
//! from each letter of the word visits at most one node for each letter
//! of the longest pattern, with a scan of the siblings at each level.
//! The patterns of American English (`data/hyph-en-us.pat.txt`) are in
//! the binary; docs/references/typeset.md has their license.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const en_us_patterns = @embedFile("data/hyph-en-us.pat.txt");
pub const en_us_exceptions = @embedFile("data/hyph-en-us.hyp.txt");

const max_word = 64;
const none: u32 = std.math.maxInt(u32);

const Node = struct {
    ch: u8,
    child: u32 = none,
    sibling: u32 = none,
    /// The offset of the digits in `Hyphenator.digits`, or `none`.
    digits: u32 = none,
    len: u8 = 0,
};

pub const Hyphenator = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    digits: std.ArrayList(u8) = .empty,
    exceptions: std.StringHashMapUnmanaged([]u8) = .empty,
    /// The fewest letters before and after a hyphen.
    left_min: u8 = 2,
    right_min: u8 = 3,

    pub fn init(gpa: std.mem.Allocator, patterns: []const u8, exceptions: []const u8) !Hyphenator {
        var h: Hyphenator = .{ .gpa = gpa };
        errdefer h.deinit();
        try h.nodes.append(gpa, .{ .ch = 0 });
        var it = std.mem.tokenizeAny(u8, patterns, " \t\r\n");
        while (it.next()) |p| try h.addPattern(p);
        var ex = std.mem.tokenizeAny(u8, exceptions, " \t\r\n");
        while (ex.next()) |w| try h.addException(w);
        return h;
    }

    pub fn deinit(h: *Hyphenator) void {
        h.nodes.deinit(h.gpa);
        h.digits.deinit(h.gpa);
        var it = h.exceptions.iterator();
        while (it.next()) |e| {
            h.gpa.free(e.key_ptr.*);
            h.gpa.free(e.value_ptr.*);
        }
        h.exceptions.deinit(h.gpa);
    }

    fn addPattern(h: *Hyphenator, p: []const u8) !void {
        var letters: [max_word]u8 = undefined;
        var vals: [max_word + 1]u8 = @splat(0);
        var n: usize = 0;
        for (p) |c| {
            if (c >= '0' and c <= '9') {
                vals[n] = c - '0';
            } else {
                if (n == max_word) return;
                letters[n] = std.ascii.toLower(c);
                n += 1;
            }
        }
        if (n == 0) return;
        var node: u32 = 0;
        for (letters[0..n]) |c| node = try h.childOf(node, c, true);
        const off: u32 = @intCast(h.digits.items.len);
        try h.digits.appendSlice(h.gpa, vals[0 .. n + 1]);
        h.nodes.items[node].digits = off;
        h.nodes.items[node].len = @intCast(n + 1);
    }

    fn childOf(h: *Hyphenator, node: u32, c: u8, make: bool) !u32 {
        var k = h.nodes.items[node].child;
        while (k != none) : (k = h.nodes.items[k].sibling) {
            if (h.nodes.items[k].ch == c) return k;
        }
        if (!make) return none;
        const id: u32 = @intCast(h.nodes.items.len);
        try h.nodes.append(h.gpa, .{ .ch = c, .sibling = h.nodes.items[node].child });
        h.nodes.items[node].child = id;
        return id;
    }

    fn find(h: *const Hyphenator, node: u32, c: u8) u32 {
        var k = h.nodes.items[node].child;
        while (k != none) : (k = h.nodes.items[k].sibling) {
            if (h.nodes.items[k].ch == c) return k;
        }
        return none;
    }

    fn addException(h: *Hyphenator, w: []const u8) !void {
        if (w.len > max_word) return;
        var word: [max_word]u8 = undefined;
        var marks: [max_word]u8 = @splat(0);
        var n: usize = 0;
        for (w) |c| {
            if (c == '-') {
                if (n > 0) marks[n - 1] = 1;
            } else {
                word[n] = std.ascii.toLower(c);
                n += 1;
            }
        }
        const key = try h.gpa.dupe(u8, word[0..n]);
        errdefer h.gpa.free(key);
        const val = try h.gpa.dupe(u8, marks[0..n]);
        errdefer h.gpa.free(val);
        const gop = try h.exceptions.getOrPut(h.gpa, key);
        if (gop.found_existing) {
            h.gpa.free(key);
            h.gpa.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = val;
    }

    /// Sets `out[i]` to true when a hyphen can go after letter `i` of
    /// `word`. A word with a character that is not an ASCII letter, or
    /// with more than 64 letters, gets no hyphen. Returns the count of
    /// hyphens.
    pub fn hyphenate(h: *const Hyphenator, word: []const u8, out: []bool) usize {
        @memset(out, false);
        const n = word.len;
        if (n < @as(usize, h.left_min) + h.right_min or n > max_word or out.len < n) return 0;
        var buf: [max_word + 2]u8 = undefined;
        buf[0] = '.';
        for (word, 0..) |c, i| {
            if (!std.ascii.isAlphabetic(c)) return 0;
            buf[i + 1] = std.ascii.toLower(c);
        }
        buf[n + 1] = '.';
        if (h.exceptions.get(buf[1 .. n + 1])) |marks| {
            var count: usize = 0;
            for (marks, 0..) |m, i| if (m != 0 and i + 1 >= h.left_min and n - (i + 1) >= h.right_min) {
                out[i] = true;
                count += 1;
            };
            return count;
        }
        const w = buf[0 .. n + 2];
        var vals: [max_word + 3]u8 = @splat(0);
        for (0..w.len) |start| {
            var node: u32 = 0;
            for (w[start..], 0..) |c, k| {
                node = h.find(node, c);
                if (node == none) break;
                const nd = h.nodes.items[node];
                if (nd.digits != none) {
                    // The digits are at the places before, between, and after
                    // letters start..start+k.
                    for (h.digits.items[nd.digits..][0..nd.len], 0..) |v, j| {
                        if (v > vals[start + j]) vals[start + j] = v;
                    }
                }
                _ = k;
            }
        }
        // vals[j] is the place before letter j of `w`. A hyphen after
        // letter i of the word is the place before w[i + 2].
        var count: usize = 0;
        for (0..n - 1) |i| {
            if (vals[i + 2] % 2 == 1 and i + 1 >= h.left_min and n - (i + 1) >= h.right_min) {
                out[i] = true;
                count += 1;
            }
        }
        return count;
    }
};

test "hyph: words of the paper and the exceptions" {
    const gpa = std.testing.allocator;
    var h = try Hyphenator.init(gpa, en_us_patterns, en_us_exceptions);
    defer h.deinit();
    const cases = [_][2][]const u8{
        .{ "hyphenation", "hy-phen-ation" },
        .{ "computer", "com-puter" },
        .{ "table", "ta-ble" },
        .{ "project", "project" },
        .{ "typesetting", "type-set-ting" },
        .{ "the", "the" },
    };
    for (cases) |c| {
        var marks: [64]bool = undefined;
        _ = h.hyphenate(c[0], &marks);
        var got: [80]u8 = undefined;
        var n: usize = 0;
        for (c[0], 0..) |ch, i| {
            got[n] = ch;
            n += 1;
            if (marks[i]) {
                got[n] = '-';
                n += 1;
            }
        }
        try std.testing.expectEqualStrings(c[1], got[0..n]);
    }
}

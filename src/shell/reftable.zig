//! The command table of the reference (docs/reference/*.txt) for the
//! shell: the synopsis, the subcommands, and the options of each
//! command, with the first sentence of each description.
//!
//! `python3 -I tools/reference.py shell-table` writes `reference.txt`,
//! and CI checks that the file is current. An entry starts with a line
//! `== NAME ALIAS...`. The lines after it are `syn: TEXT`,
//! `sub: SYNTAX | TEXT`, and `opt: OPTION ARGS | TEXT`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

const table = @embedFile("reference.txt");

/// The lines of the entry of the command `name`, or null. A leading
/// `::` of the name does not count.
pub fn entry(name: []const u8) ?[]const u8 {
    const want = if (std.mem.startsWith(u8, name, "::")) name[2..] else name;
    if (want.len == 0) return null;
    // Each entry starts at a line `== `, after the line of the comment.
    var at = std.mem.indexOf(u8, table, "\n== ") orelse return null;
    while (at < table.len) {
        const h = at + 4;
        const eol = std.mem.indexOfScalarPos(u8, table, h, '\n') orelse table.len;
        const next = std.mem.indexOfPos(u8, table, eol, "\n== ") orelse table.len;
        // A checkout with CRLF line ends, as Git gives on Windows, ends
        // each line with `\r`.
        var names = std.mem.tokenizeAny(u8, table[h..eol], " \r");
        while (names.next()) |n| {
            if (std.mem.eql(u8, n, want)) return table[@min(eol + 1, next)..next];
        }
        at = next;
    }
    return null;
}

/// The lines of an entry with the key `key`: "syn", "sub", or "opt".
pub const Lines = struct {
    rest: std.mem.SplitIterator(u8, .scalar),
    key: []const u8,

    pub fn next(l: *Lines) ?[]const u8 {
        while (l.rest.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len > l.key.len + 2 and std.mem.startsWith(u8, line, l.key) and std.mem.startsWith(u8, line[l.key.len..], ": ")) return line[l.key.len + 2 ..];
        }
        return null;
    }
};

pub fn lines(body: []const u8, key: []const u8) Lines {
    return .{ .rest = std.mem.splitScalar(u8, body, '\n'), .key = key };
}

/// The syntax part of a `sub` or `opt` line: the text before ` | `.
pub fn syntax(line: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, line, " | ")) |k| line[0..k] else line;
}

/// The name of a subcommand of a `sub` line: its second word.
pub fn subName(line: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeScalar(u8, syntax(line), ' ');
    _ = words.next() orelse return null;
    return words.next();
}

/// The option of an `opt` line: its first word.
pub fn optName(line: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeScalar(u8, syntax(line), ' ');
    return words.next();
}

/// The `sub` line of the subcommand `sub` of `body`, or null.
pub fn findSub(body: []const u8, sub: []const u8) ?[]const u8 {
    var l = lines(body, "sub");
    while (l.next()) |line| {
        if (subName(line)) |n| if (std.mem.eql(u8, n, sub)) return line;
    }
    return null;
}

/// The `opt` line of the option `opt` of `body`, or null.
pub fn findOpt(body: []const u8, opt: []const u8) ?[]const u8 {
    var l = lines(body, "opt");
    while (l.next()) |line| {
        if (optName(line)) |o| if (std.mem.eql(u8, o, opt)) return line;
    }
    return null;
}

test "the table has lsort with its options" {
    const body = entry("lsort").?;
    var syn = lines(body, "syn");
    try std.testing.expect(std.mem.startsWith(u8, syn.next().?, "lsort "));
    try std.testing.expect(findOpt(body, "-integer") != null);
    try std.testing.expect(findOpt(body, "-nope") == null);
    try std.testing.expect(entry("::lsort") != null);
    try std.testing.expect(entry("no-such-command") == null);
}

test "the table has the subcommands of string" {
    const body = entry("string").?;
    const line = findSub(body, "range").?;
    try std.testing.expectEqualStrings("string range STRING FIRST LAST", syntax(line));
}

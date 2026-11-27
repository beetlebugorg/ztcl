//! Counts the words of a text and writes the 20 most frequent.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

const Entry = struct { word: []const u8, n: u32 };

fn byCount(_: void, x: Entry, y: Entry) bool {
    if (x.n != y.n) return x.n > y.n;
    return std.mem.lessThan(u8, x.word, y.word);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const path = try std.fs.path.join(a, &.{ args[1], "words.txt" });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    _ = std.ascii.lowerString(text, text);
    var counts = std.StringHashMap(u32).init(a);
    var tokens: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !std.ascii.isLower(text[i])) i += 1;
        const start = i;
        while (i < text.len and std.ascii.isLower(text[i])) i += 1;
        if (i == start) break;
        tokens += 1;
        (try counts.getOrPutValue(text[start..i], 0)).value_ptr.* += 1;
    }
    var list: std.ArrayList(Entry) = .empty;
    var it = counts.iterator();
    while (it.next()) |e| try list.append(a, .{ .word = e.key_ptr.*, .n = e.value_ptr.* });
    std.mem.sort(Entry, list.items, {}, byCount);
    var buf: [65536]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    try out.print("tokens {d} distinct {d}\n", .{ tokens, counts.count() });
    for (list.items[0..@min(20, list.items.len)]) |e| try out.print("{d} {s}\n", .{ e.n, e.word });
    try out.flush();
}

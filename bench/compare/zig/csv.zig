//! Reads a CSV file of sales and writes the quantity and the revenue for
//! each region and product. The Zig standard library has no CSV parser,
//! so the fields come from a small parser of quoted fields.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

const Sum = struct { qty: i64 = 0, rev: f64 = 0 };

/// Splits one line into fields. A quoted field can have commas; this
/// file has no doubled quotes.
fn fields(line: []const u8, out: *[5][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i <= line.len and n < out.len) {
        if (i < line.len and line[i] == '"') {
            const end = std.mem.indexOfScalarPos(u8, line, i + 1, '"') orelse line.len;
            out[n] = line[i + 1 .. end];
            i = end + 2;
        } else {
            const end = std.mem.indexOfScalarPos(u8, line, i, ',') orelse line.len;
            out[n] = line[i..end];
            i = end + 1;
        }
        n += 1;
    }
    return n;
}

fn lessKey(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const path = try std.fs.path.join(a, &.{ args[1], "sales.csv" });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    var sums = std.StringHashMap(Sum).init(a);
    var total: Sum = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next();
    var f: [5][]const u8 = undefined;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (fields(line, &f) != 5) return error.BadRow;
        const q = try std.fmt.parseInt(i64, f[3], 10);
        const v = @as(f64, @floatFromInt(q)) * try std.fmt.parseFloat(f64, f[4]);
        const key = try std.mem.concat(a, u8, &.{ f[1], "|", f[2] });
        const e = try sums.getOrPut(key);
        if (!e.found_existing) e.value_ptr.* = .{};
        e.value_ptr.qty += q;
        e.value_ptr.rev += v;
        total.qty += q;
        total.rev += v;
    }
    var keys: std.ArrayList([]const u8) = .empty;
    var it = sums.keyIterator();
    while (it.next()) |k| try keys.append(a, k.*);
    std.mem.sort([]const u8, keys.items, {}, lessKey);
    var buf: [65536]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    for (keys.items) |k| {
        const s = sums.get(k).?;
        try out.print("{s}|{d}|{d:.2}\n", .{ k, s.qty, s.rev });
    }
    try out.print("TOTAL|{d}|{d:.2}\n", .{ total.qty, total.rev });
    try out.flush();
}

//! Parses a web server log and counts the requests by status and by
//! path. The Zig standard library has no regular expressions, so the
//! fields come from a hand-written scan of each line.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

const Entry = struct { key: []const u8, n: u32 };

fn byCount(_: void, x: Entry, y: Entry) bool {
    if (x.n != y.n) return x.n > y.n;
    return std.mem.lessThan(u8, x.key, y.key);
}

fn byKey(_: void, x: Entry, y: Entry) bool {
    return std.mem.lessThan(u8, x.key, y.key);
}

/// Gives the path and the status of a line, or null for a line of another form.
fn parse(line: []const u8) ?struct { path: []const u8, status: []const u8 } {
    const q1 = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const q2 = std.mem.indexOfScalarPos(u8, line, q1 + 1, '"') orelse return null;
    var req = std.mem.splitScalar(u8, line[q1 + 1 .. q2], ' ');
    _ = req.next() orelse return null;
    const target = req.next() orelse return null;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    var rest = std.mem.tokenizeScalar(u8, line[q2 + 1 ..], ' ');
    const status = rest.next() orelse return null;
    if (status.len != 3) return null;
    return .{ .path = path, .status = status };
}

fn sorted(a: std.mem.Allocator, m: std.StringHashMap(u32), comptime less: anytype) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    var it = m.iterator();
    while (it.next()) |e| try list.append(a, .{ .key = e.key_ptr.*, .n = e.value_ptr.* });
    std.mem.sort(Entry, list.items, {}, less);
    return list.items;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const path = try std.fs.path.join(a, &.{ args[1], "access.log" });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    var by_status = std.StringHashMap(u32).init(a);
    var by_path = std.StringHashMap(u32).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const r = parse(line) orelse continue;
        (try by_status.getOrPutValue(r.status, 0)).value_ptr.* += 1;
        (try by_path.getOrPutValue(r.path, 0)).value_ptr.* += 1;
    }
    var buf: [65536]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    for (try sorted(a, by_status, byKey)) |e| try out.print("{s} {d}\n", .{ e.key, e.n });
    const paths = try sorted(a, by_path, byCount);
    for (paths[0..@min(20, paths.len)]) |e| try out.print("{d} {s}\n", .{ e.n, e.key });
    try out.flush();
}

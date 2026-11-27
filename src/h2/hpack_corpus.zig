//! The run of `hpack.zig` on the hpack-test-case corpus
//! (github.com/http2jp/hpack-test-case, MIT, test data only).
//!
//!   zig build hpack-corpus -- DIR
//!
//! Each folder of DIR holds the stories of one encoder: JSON files with
//! cases of a "wire" (hex) and the "headers" it must give. The run
//! decodes each wire with one decoder for each story and compares the
//! fields in order. The folder `raw-data` has no wires: the run encodes
//! its headers with `Encoder` in each Huffman mode, decodes the blocks,
//! and compares them. It prints the bytes of each folder, so the size of
//! our blocks stands next to those of the other encoders.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const hpack = @import("hpack.zig");

const Story = struct {
    cases: []const Case,
};

const Case = struct {
    wire: []const u8,
    headers: []const hpack.Field,
    table_size: ?usize,
};

fn parse(a: std.mem.Allocator, text: []const u8) !Story {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    const cases = root.object.get("cases") orelse return error.BadStory;
    var out: std.ArrayList(Case) = .empty;
    for (cases.array.items) |c| {
        var fields: std.ArrayList(hpack.Field) = .empty;
        for (c.object.get("headers").?.array.items) |h| {
            var it = h.object.iterator();
            const kv = it.next() orelse return error.BadStory;
            try fields.append(a, .{ .name = kv.key_ptr.*, .value = kv.value_ptr.string });
        }
        var wire: []const u8 = "";
        if (c.object.get("wire")) |w| {
            const buf = try a.alloc(u8, w.string.len / 2);
            wire = try std.fmt.hexToBytes(buf, w.string);
        }
        const ts: ?usize = if (c.object.get("header_table_size")) |t| switch (t) {
            .integer => |v| @intCast(v),
            else => null,
        } else null;
        try out.append(a, .{ .wire = wire, .headers = fields.items, .table_size = ts });
    }
    return .{ .cases = out.items };
}

/// Decodes a block and compares its fields with `want`.
fn check(d: *hpack.Decoder, wire: []const u8, want: []const hpack.Field, scratch: []u8) !void {
    var b = d.block(wire, scratch);
    var i: usize = 0;
    while (try b.next()) |f| : (i += 1) {
        if (i >= want.len) return error.ExtraField;
        if (!std.mem.eql(u8, f.name, want[i].name) or !std.mem.eql(u8, f.value, want[i].value)) return error.WrongField;
    }
    if (i != want.len) return error.MissingField;
}

fn maxTable(s: Story) usize {
    var m: usize = 4096;
    for (s.cases) |c| m = @max(m, c.table_size orelse 0);
    return m;
}

const Tally = struct { stories: usize = 0, cases: usize = 0, failed: usize = 0, bytes: usize = 0 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);

    var paths: std.ArrayList([]const u8) = .empty;
    var walk = try dir.walk(a);
    defer walk.deinit();
    while (try walk.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".json")) continue;
        if (std.mem.indexOfScalar(u8, e.path, '/') == null) continue;
        try paths.append(a, try a.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);

    const scratch = try a.alloc(u8, 1 << 16);
    const out = try a.alloc(u8, 1 << 20);
    var tallies: std.StringArrayHashMapUnmanaged(Tally) = .empty;
    var total_failed: usize = 0;
    for (paths.items) |path| {
        const folder = path[0..std.mem.indexOfScalar(u8, path, '/').?];
        const raw = std.mem.eql(u8, folder, "raw-data");
        const modes: []const hpack.Huffman = if (raw) &.{ .never, .always, .shorter } else &.{.never};
        const story = try parse(a, try dir.readFileAlloc(io, path, a, .limited(64 << 20)));
        for (modes) |mode| {
            const label = if (raw) try std.fmt.allocPrint(a, "ztcl, Huffman {t}", .{mode}) else folder;
            const g = try tallies.getOrPut(a, label);
            if (!g.found_existing) g.value_ptr.* = .{};
            const t = g.value_ptr;
            t.stories += 1;
            const cap = maxTable(story);
            var dec = try hpack.Decoder.init(gpa, cap, 1 << 24);
            defer dec.deinit(gpa);
            dec.table.setMax(4096);
            var enc = try hpack.Encoder.init(gpa, 4096);
            defer enc.deinit(gpa);
            enc.huffman = mode;
            for (story.cases, 0..) |c, ci| {
                t.cases += 1;
                var wire = c.wire;
                if (raw) {
                    const n = try enc.encode(out, c.headers);
                    wire = out[0..n];
                }
                t.bytes += wire.len;
                check(&dec, wire, c.headers, scratch) catch |e| {
                    t.failed += 1;
                    std.debug.print("{s} case {d}: {t}\n", .{ path, ci, e });
                };
            }
        }
    }
    std.debug.print("| Encoder | Stories | Cases | Failed | Block bytes |\n|---|---:|---:|---:|---:|\n", .{});
    for (tallies.keys(), tallies.values()) |n, t| {
        total_failed += t.failed;
        std.debug.print("| {s} | {d} | {d} | {d} | {d} |\n", .{ n, t.stories, t.cases, t.failed, t.bytes });
    }
    if (total_failed != 0) return error.CorpusFailed;
}

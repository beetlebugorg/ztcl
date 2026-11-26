//! A writer of zip archives in memory, for the payload of `ztcl build`.
//!
//! Each entry has a local header, the data, and a central header, and
//! the archive ends with the end of central directory record. The
//! writer puts the fixed time 1980-01-01 00:00 in each header and adds
//! no extra field, so the same entries give the same bytes on each
//! host. A deflate entry uses `std.compress.flate.Compress` and is
//! stored when deflate gives no smaller data. There is no zip64 form:
//! an archive of 4 GiB or more is `error.TooLarge`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct { name: []const u8, data: []const u8 };

pub const Error = error{TooLarge} || Allocator.Error;

/// The archive of `entries`, in the order given. With `compress`,
/// each entry is deflate when that is smaller.
pub fn write(a: Allocator, entries: []const Entry, compress: bool) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var central: std.ArrayList(u8) = .empty;
    defer central.deinit(a);
    for (entries) |e| {
        const crc = std.hash.Crc32.hash(e.data);
        var method: u16 = 0;
        var body = e.data;
        var packed_buf: ?[]u8 = null;
        defer if (packed_buf) |p| a.free(p);
        if (compress and e.data.len > 0) {
            const p = try deflate(a, e.data);
            if (p.len < e.data.len) {
                method = 8;
                body = p;
                packed_buf = p;
            } else a.free(p);
        }
        if (out.items.len > 0xfffffffe or body.len > 0xfffffffe or e.data.len > 0xfffffffe or e.name.len > 0xffff) return error.TooLarge;
        const at: u32 = @intCast(out.items.len);
        try header(a, &out, 0x04034b50, method, crc, body.len, e.data.len, e.name, null);
        try out.appendSlice(a, body);
        try header(a, &central, 0x02014b50, method, crc, body.len, e.data.len, e.name, at);
    }
    if (out.items.len > 0xfffffffe or entries.len > 0xfffe) return error.TooLarge;
    const cd_off: u32 = @intCast(out.items.len);
    try out.appendSlice(a, central.items);
    var end: [22]u8 = @splat(0);
    std.mem.writeInt(u32, end[0..4], 0x06054b50, .little);
    std.mem.writeInt(u16, end[8..10], @intCast(entries.len), .little);
    std.mem.writeInt(u16, end[10..12], @intCast(entries.len), .little);
    std.mem.writeInt(u32, end[12..16], @intCast(central.items.len), .little);
    std.mem.writeInt(u32, end[16..20], cd_off, .little);
    try out.appendSlice(a, &end);
    return out.toOwnedSlice(a);
}

/// A local header (with `at` null) or a central header.
fn header(a: Allocator, out: *std.ArrayList(u8), sig: u32, method: u16, crc: u32, csize: usize, size: usize, name: []const u8, at: ?u32) Allocator.Error!void {
    var h: [46]u8 = @splat(0);
    std.mem.writeInt(u32, h[0..4], sig, .little);
    var p: usize = 4;
    if (at != null) {
        // Made by: Unix (3), version 2.0.
        std.mem.writeInt(u16, h[4..6], 0x0314, .little);
        p = 6;
    }
    std.mem.writeInt(u16, h[p..][0..2], 20, .little);
    // Flags: bit 11, the name is UTF-8.
    std.mem.writeInt(u16, h[p + 2 ..][0..2], 0x0800, .little);
    std.mem.writeInt(u16, h[p + 4 ..][0..2], method, .little);
    // Time 00:00, date 1980-01-01.
    std.mem.writeInt(u16, h[p + 6 ..][0..2], 0, .little);
    std.mem.writeInt(u16, h[p + 8 ..][0..2], 0x0021, .little);
    std.mem.writeInt(u32, h[p + 10 ..][0..4], crc, .little);
    std.mem.writeInt(u32, h[p + 14 ..][0..4], @intCast(csize), .little);
    std.mem.writeInt(u32, h[p + 18 ..][0..4], @intCast(size), .little);
    std.mem.writeInt(u16, h[p + 22 ..][0..2], @intCast(name.len), .little);
    if (at) |off| {
        // External attributes: a regular file, mode 0644.
        std.mem.writeInt(u32, h[38..42], 0o100644 << 16, .little);
        std.mem.writeInt(u32, h[42..46], off, .little);
        try out.appendSlice(a, &h);
    } else try out.appendSlice(a, h[0..30]);
    try out.appendSlice(a, name);
}

fn deflate(a: Allocator, data: []const u8) Allocator.Error![]u8 {
    var w: std.Io.Writer.Allocating = try .initCapacity(a, data.len / 2 + 64);
    errdefer w.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var c = std.compress.flate.Compress.init(&w.writer, &window, .raw, .default) catch return error.OutOfMemory;
    c.writer.writeAll(data) catch return error.OutOfMemory;
    c.finish() catch return error.OutOfMemory;
    return w.toOwnedSlice();
}

test "zipwrite: the reader reads the archive" {
    const zr = @import("zipread.zig");
    const a = std.testing.allocator;
    var big: [5000]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast('a' + i % 7);
    const entries = [_]Entry{ .{ .name = "main.tcl", .data = "puts hi\n" }, .{ .name = "lib/big.txt", .data = &big }, .{ .name = "empty", .data = "" } };
    for ([_]bool{ false, true }) |compress| {
        const bytes = try write(a, &entries, compress);
        defer a.free(bytes);
        var z = try zr.Archive.parse(a, bytes);
        defer z.deinit(a);
        for (entries) |e| {
            const got = z.find(e.name).?;
            const data = try z.extract(a, got);
            defer if (got.method == .deflate) a.free(data);
            try std.testing.expectEqualSlices(u8, e.data, data);
        }
        try std.testing.expectEqual(compress, z.find("lib/big.txt").?.method == .deflate);
        // The same entries give the same bytes.
        const again = try write(a, &entries, compress);
        defer a.free(again);
        try std.testing.expectEqualSlices(u8, bytes, again);
    }
}

//! The speed of `hpack.zig`.
//!
//!   zig build hpack-bench
//!
//! It prints MB/s of the Huffman decoder and encoder on header text,
//! and the header blocks per second of the decoder and the encoder for
//! a browser request of 12 fields: the first block of a connection (all
//! literals) and a later block (the fields in the dynamic table). The
//! clock is the CPU time of the thread, the best of 5 runs.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const hpack = @import("hpack.zig");

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.THREAD_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const request = [_]hpack.Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":authority", .value = "www.example.com" },
    .{ .name = ":path", .value = "/static/js/app.4f2a9c1e.js?v=20261127" },
    .{ .name = "user-agent", .value = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0" },
    .{ .name = "accept", .value = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" },
    .{ .name = "accept-language", .value = "en-US,en;q=0.5" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br, zstd" },
    .{ .name = "referer", .value = "https://www.example.com/docs/getting-started/index.html" },
    .{ .name = "cookie", .value = "session=8f14e45fceea167a5a36dedd4bea2543; theme=dark; lang=en" },
    .{ .name = "sec-fetch-mode", .value = "navigate" },
    .{ .name = "priority", .value = "u=0, i" },
};

fn best(comptime f: anytype, args: anytype, comptime per: usize) f64 {
    var b: f64 = 0;
    for (0..5) |_| {
        var n: usize = 0;
        const t0 = nowNs();
        var t: u64 = 0;
        while (t < 200 * std.time.ns_per_ms) : (n += per) {
            for (0..per) |_| @call(.auto, f, args);
            t = nowNs() - t0;
        }
        b = @max(b, @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(t)) * 1e9);
    }
    return b;
}

var text: [4096]u8 = undefined;
var text_len: usize = 0;
var huff: [4096]u8 = undefined;
var huff_len: usize = 0;
var out: [4096]u8 = undefined;

fn decodeText() void {
    const got = hpack.huffmanDecode(&out, huff[0..huff_len]) catch unreachable;
    std.mem.doNotOptimizeAway(got.len);
}

fn encodeText() void {
    std.mem.doNotOptimizeAway(hpack.huffmanEncode(&out, text[0..text_len]));
}

fn decodeBlock(d: *hpack.Decoder, blk: []const u8, reset: bool) void {
    if (reset) d.table.setMax(0);
    if (reset) d.table.setMax(d.table.cap);
    var scratch: [512]u8 = undefined;
    var b = d.block(blk, &scratch);
    while (b.next() catch unreachable) |f| std.mem.doNotOptimizeAway(f.value.len);
}

fn encodeBlock(e: *hpack.Encoder, reset: bool) void {
    if (reset) e.table.setMax(0);
    if (reset) e.table.setMax(e.table.cap);
    var o: [2048]u8 = undefined;
    std.mem.doNotOptimizeAway(e.encode(&o, &request) catch unreachable);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    for (request) |f| {
        @memcpy(text[text_len..][0..f.value.len], f.value);
        text_len += f.value.len;
    }
    huff_len = hpack.huffmanEncode(&huff, text[0..text_len]);
    const tb: f64 = @floatFromInt(text_len);
    std.debug.print("Huffman decode\t{d:.0} MB/s of text\n", .{best(decodeText, .{}, 64) * tb / 1e6});
    std.debug.print("Huffman encode\t{d:.0} MB/s of text\n", .{best(encodeText, .{}, 64) * tb / 1e6});

    var e = try hpack.Encoder.init(gpa, 4096);
    defer e.deinit(gpa);
    var first: [2048]u8 = undefined;
    const n1 = try e.encode(&first, &request);
    var later: [2048]u8 = undefined;
    const n2 = try e.encode(&later, &request);
    var d = try hpack.Decoder.init(gpa, 4096, 1 << 16);
    defer d.deinit(gpa);
    std.debug.print("block sizes\tfirst {d} bytes, later {d} bytes, {d} bytes of fields\n", .{ n1, n2, text_len });
    std.debug.print("decode first\t{d:.0} blocks/s\n", .{best(decodeBlock, .{ &d, first[0..n1], true }, 64)});
    decodeBlock(&d, first[0..n1], true);
    std.debug.print("decode later\t{d:.0} blocks/s\n", .{best(decodeBlock, .{ &d, later[0..n2], false }, 64)});
    std.debug.print("encode first\t{d:.0} blocks/s\n", .{best(encodeBlock, .{ &e, true }, 64)});
    std.debug.print("encode later\t{d:.0} blocks/s\n", .{best(encodeBlock, .{ &e, false }, 64)});
}

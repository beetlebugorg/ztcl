//! Encodes 16 MB of bytes to base64 and decodes them again.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const path = try std.fs.path.join(a, &.{ args[1], "bytes.bin" });
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    const b64 = std.base64.standard;
    const enc = try a.alloc(u8, b64.Encoder.calcSize(data.len));
    _ = b64.Encoder.encode(enc, data);
    const dec = try a.alloc(u8, try b64.Decoder.calcSizeForSlice(enc));
    try b64.Decoder.decode(dec, enc);
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("{d} {s} {s} {s}\n", .{ enc.len, enc[0..16], enc[enc.len - 16 ..], if (std.mem.eql(u8, dec, data)) "ok" else "bad" });
    try w.interface.flush();
}

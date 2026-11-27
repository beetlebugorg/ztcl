// SPDX-License-Identifier: BSD-2-Clause
// A WASI program in Zig for the tests of ztcl::wasm.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    try out.print("zig args {d}\n", .{args.len});
    var h: u64 = 14695981039346656037;
    for (0..100_000) |i| {
        h ^= i;
        h *%= 1099511628211;
    }
    try out.print("hash {x}\n", .{h});
    try out.flush();
}

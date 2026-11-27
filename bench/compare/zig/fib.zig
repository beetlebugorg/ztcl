//! Micro benchmark: recursive Fibonacci.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

fn fib(n: u64) u64 {
    return if (n < 2) n else fib(n - 1) + fib(n - 2);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const n = try std.fmt.parseInt(u64, args[1], 10);
    var buf: [64]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d}\n", .{fib(n)});
    try w.interface.flush();
}

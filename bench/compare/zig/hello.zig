//! Prints one line, for the start time of the process.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var w = std.Io.File.stdout().writer(init.io, &.{});
    try w.interface.writeAll("hello world\n");
}

//! The terminal of the line editor in a WebAssembly build with no host:
//! the same interface as `term.zig`, with no raw mode and no input.
//!
//! The embedder sets `out` to a function that gets the bytes of the
//! shell, and sets `cols` and `rows` to the size of its terminal. The
//! embedder gives the key bytes to `Shell.feed`, so `read` gives no input.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Out = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) void,
};

pub const Term = struct {
    out: ?Out = null,
    cols: usize = 80,
    rows: usize = 24,

    pub fn init() Term {
        return .{};
    }

    pub fn enableRaw(_: *Term) bool {
        return true;
    }

    pub fn restore(_: *Term) void {}

    pub fn size(t: *const Term) struct { cols: usize, rows: usize } {
        return .{ .cols = t.cols, .rows = t.rows };
    }

    pub fn read(_: *Term, _: []u8, _: i32) ?usize {
        return null;
    }

    pub fn write(t: *Term, bytes: []const u8) void {
        if (t.out) |o| o.write(o.ctx, bytes);
    }
};

/// The embedder calls `Shell.resize`, so this flag stays false.
pub var resized = std.atomic.Value(bool).init(false);

pub fn watchResize() void {}

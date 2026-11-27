//! The check of the generated bindings (src/wasi/p3.zig). This core
//! module imports each function of p3.zig: a table holds the address of
//! each function of `@extern`, so the linker keeps each import. `zig build
//! wasi-bindings` makes a component of it with the world
//! `ztcl:cli/command`, and `wasm-tools component new` then compares each
//! core import with the type of its WIT function. The module also runs
//! the comptime layout checks of each type.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const p3 = @import("p3");

/// An import of p3.zig is a pointer to a function from `@extern`.
fn isFn(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and @typeInfo(info.pointer.child) == .@"fn";
}

fn count(comptime T: type) usize {
    var n: usize = 0;
    for (@typeInfo(T).@"struct".decl_names) |d| {
        const v = @field(T, d);
        if (@TypeOf(v) == type) {
            if (@typeInfo(v) == .@"struct") n += count(v);
        } else if (isFn(@TypeOf(v))) n += 1;
    }
    return n;
}

fn fill(comptime T: type, out: []*const anyopaque, i: *usize) void {
    for (@typeInfo(T).@"struct".decl_names) |d| {
        const v = @field(T, d);
        if (@TypeOf(v) == type) {
            if (@typeInfo(v) == .@"struct") fill(v, out, i);
        } else if (isFn(@TypeOf(v))) {
            out[i.*] = @ptrCast(v);
            i.* += 1;
        }
    }
}

const table = blk: {
    @setEvalBranchQuota(100_000);
    var out: [count(p3)]*const anyopaque = undefined;
    var i: usize = 0;
    fill(p3, &out, &i);
    const final = out;
    break :blk final;
};

/// Gives the address of the table, so the table stays in the module.
fn run() callconv(.c) u32 {
    return @intCast(@intFromPtr(&table));
}

fn cabiRealloc(_: ?*anyopaque, _: usize, _: usize, _: usize) callconv(.c) ?*anyopaque {
    return null;
}

comptime {
    @export(&run, .{ .name = "wasi:cli/run@0.3.2#run" });
    @export(&cabiRealloc, .{ .name = "cabi_realloc" });
}

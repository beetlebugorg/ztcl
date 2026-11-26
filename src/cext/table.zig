//! The builder of the stubs tables of Tcl 8.6, for the native path
//! (`stubs.zig`) and the WebAssembly path (`wasm_stubs.zig`).
//!
//! A table is the magic number, the hooks, and one pointer for each slot
//! of `slots.zig`. A slot gets the function of the same name from the
//! first group of a list that declares it as a public function. A slot
//! with no function gets the function of `missing` for its number, and
//! a reserved slot is null. Each path has its own list of groups, and
//! the groups of `obj.zig` and `mem.zig` are in both lists.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const slots = @import("slots.zig");

/// The value of `TCL_STUB_MAGIC` of `tcl.h`.
pub const magic: c_int = @bitCast(@as(u32, 0xFCA3BACF));

pub const Kind = enum {
    public,
    internal,
    plat,
    int_plat,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .public => "public",
            .internal => "internal",
            .plat => "platform",
            .int_plat => "internal platform",
        };
    }
};

/// `TclStubs` of `tclDecls.h` and the other three tables.
pub fn Table(comptime n: usize) type {
    return extern struct {
        magic: c_int,
        hooks: ?*const anyopaque,
        slots: [n]?*const anyopaque,
    };
}

/// The name of slot `i` of table `k`, or null for a reserved slot.
pub fn name(k: Kind, i: usize) ?[]const u8 {
    return switch (k) {
        .public => if (slots.public[i]) |s| s.name else null,
        .internal => slots.internal[i],
        .plat => if (comptime slots.plat.len == 0) null else slots.plat[i],
        .int_plat => slots.int_plat[i],
    };
}

pub fn len(k: Kind) usize {
    return switch (k) {
        .public => slots.public.len,
        .internal => slots.internal.len,
        .plat => slots.plat.len,
        .int_plat => slots.int_plat.len,
    };
}

/// The function of a slot name in `groups`, or null when no group has it.
pub fn find(comptime groups: anytype, comptime nm: []const u8) ?*const anyopaque {
    inline for (groups) |g| {
        if (@hasDecl(g, nm)) return @ptrCast(&@field(g, nm));
    }
    return null;
}

/// The slots of table `k`. `missing(k, i)` gives the function of slot
/// `i` when no group has it.
pub fn fill(comptime groups: anytype, comptime k: Kind, comptime missing: anytype) [len(k)]?*const anyopaque {
    @setEvalBranchQuota(400_000);
    var out: [len(k)]?*const anyopaque = undefined;
    for (0..len(k)) |i| {
        out[i] = if (name(k, i)) |nm| (find(groups, nm) orelse missing(k, i)) else null;
    }
    return out;
}

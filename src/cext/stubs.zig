//! The stubs tables of Tcl 8.6 for a C package.
//!
//! A package built with `USE_TCL_STUBS` calls each function of the Tcl
//! C API through a pointer in a table. `Tcl_InitStubs`, in the stub
//! library of the package, reads the public table from the interp and
//! the three other tables from its hooks. This file builds the four
//! tables at compile time from the slot lists of `slots.zig`. A slot
//! gets the function of the same name from the first group of `groups`
//! that declares it. A slot with no function gets its own small function
//! that records the call (`cext.missing`) and returns 0.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const slots = @import("slots.zig");
const cext = @import("cext.zig");

const table = @import("table.zig");

pub const magic = table.magic;
pub const Kind = table.Kind;
pub const name = table.name;
pub const len = table.len;
const Table = table.Table;

/// The groups of the native path. Each one is a struct of C functions
/// with the names of the slots.
const groups = .{
    @import("mem.zig").slots,
    @import("pkgs.zig").slots,
    @import("obj.zig").slots,
    @import("chan.zig").slots,
    @import("host.zig").slots,
    @import("hash.zig").slots,
    @import("parse.zig").slots,
    @import("errors.zig").slots,
};

/// `TclStubHooks` of `tclDecls.h`.
pub const Hooks = extern struct {
    plat: *const Table(slots.plat.len),
    internal: *const Table(slots.internal.len),
    int_plat: *const Table(slots.int_plat.len),
};

fn find(comptime nm: []const u8) ?*const anyopaque {
    return table.find(groups, nm);
}

/// True when a group has the function of slot `i` of table `k`.
pub fn done(comptime k: Kind, comptime i: usize) bool {
    const nm = comptime name(k, i) orelse return false;
    return comptime find(nm) != null;
}

fn missingFn(comptime k: Kind, comptime i: usize) *const anyopaque {
    const S = struct {
        fn f() callconv(.c) usize {
            cext.missing(k, i);
            return 0;
        }
    };
    return @ptrCast(&S.f);
}

fn fill(comptime k: Kind) [len(k)]?*const anyopaque {
    return table.fill(groups, k, missingFn);
}

const plat_table: Table(slots.plat.len) = .{ .magic = magic, .hooks = null, .slots = fill(.plat) };
const int_table: Table(slots.internal.len) = .{ .magic = magic, .hooks = null, .slots = fill(.internal) };
const int_plat_table: Table(slots.int_plat.len) = .{ .magic = magic, .hooks = null, .slots = fill(.int_plat) };
const hooks: Hooks = .{ .plat = &plat_table, .internal = &int_table, .int_plat = &int_plat_table };

/// The public table: `tclStubsPtr` of a package after `Tcl_InitStubs`.
pub const public: Table(slots.public.len) = .{ .magic = magic, .hooks = &hooks, .slots = fill(.public) };

/// The count of the slots with a function, and of all named slots, of
/// table `k`. `area` limits the count of the public table to one area.
pub fn coverage(comptime k: Kind, comptime area: ?slots.Area) struct { done: usize, all: usize } {
    @setEvalBranchQuota(200_000);
    comptime var d: usize = 0;
    comptime var a: usize = 0;
    inline for (0..len(k)) |i| {
        const in_area = comptime if (area) |ar| (k == .public and slots.public[i] != null and slots.public[i].?.area == ar) else true;
        if (comptime name(k, i) != null and in_area) {
            a += 1;
            if (comptime done(k, i)) d += 1;
        }
    }
    return .{ .done = d, .all = a };
}

//! The exports of libztcl for a library that is built on it, such as the
//! libtk8.6 of ztk (ztk#223). Such a library has ztcl and its own code in
//! one shared object, so a program that links libtcl8.6 and libtk8.6
//! gets one copy of ztcl.
//!
//! `exportAll(first, last)` exports each named slot of the public,
//! internal, and internal platform stubs tables with the name of Tcl, as
//! `src/libztcl.zig` does. A slot gets the function of the first group of
//! `first` that has it, then of `cext/stubs.zig`, then of `last`, then a
//! function that writes the slot name to the standard error and aborts.
//! The groups of `last` give the slots that ztcl does not have yet, so a
//! slot of ztcl comes first when it exists. The library exports its
//! functions outside the tables (such as `Tk_Init`) itself.
//!
//! The module of ztcl has this file only in a build with `-Dcext=true`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
pub const stubs = @import("cext/stubs.zig");
pub const table = @import("cext/table.zig");
pub const app = @import("cext/app.zig");
pub const cext = @import("cext/cext.zig");
pub const obj = @import("cext/obj.zig");

fn missingFn(comptime k: table.Kind, comptime i: usize) *const fn () callconv(.c) noreturn {
    const S = struct {
        fn f() callconv(.c) noreturn {
            const nm = comptime table.name(k, i).?;
            const msg = comptime std.fmt.comptimePrint("libztcl: the program called {s} (slot {d} of the {s} stubs table), which ztcl does not have\n", .{ nm, i, k.label() });
            _ = std.c.write(2, msg.ptr, msg.len);
            std.c.abort();
        }
    };
    return &S.f;
}

const kinds = [_]table.Kind{ .public, .internal, .int_plat };

/// True when slot `i` of table `k` has the name of an earlier slot.
fn seen(comptime k: table.Kind, comptime i: usize, comptime nm: []const u8) bool {
    for (kinds) |kk| {
        const n = if (kk == k) i else table.len(kk);
        for (0..n) |j| {
            if (table.name(kk, j)) |o| if (std.mem.eql(u8, o, nm)) return true;
        }
        if (kk == k) return false;
    }
    return false;
}

fn exportTable(comptime k: table.Kind, comptime first: anytype, comptime last: anytype) void {
    @setEvalBranchQuota(8_000_000);
    inline for (0..table.len(k)) |i| {
        const nm = comptime table.name(k, i) orelse continue;
        if (comptime seen(k, i, nm)) continue;
        comptime var found = false;
        inline for (first ++ stubs.groups ++ last) |g| {
            if (!found and @hasDecl(g, nm)) {
                @export(&@field(g, nm), .{ .name = nm });
                found = true;
            }
        }
        if (!found) @export(missingFn(k, i), .{ .name = nm });
    }
}

/// Exports the three tables and the functions of `tcl.h` outside them.
/// `first` and `last` are tuples of structs of `callconv(.c)` functions.
/// A slot gets the function of `first`, then of ztcl, then of `last`.
pub fn exportAll(comptime first: anytype, comptime last: anytype) void {
    exportTable(.public, first, last);
    exportTable(.internal, first, last);
    exportTable(.int_plat, first, last);
    for (.{ "Tcl_Main", "Tcl_MainEx", "Tcl_PkgInitStubsCheck", "Tcl_GetMemoryInfo" }) |nm| {
        @export(&@field(app.extra, nm), .{ .name = nm });
    }
}

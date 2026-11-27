//! libztcl: a shared library with the C API of Tcl 8.6, so a program
//! that links libtcl8.6 runs on ztcl with no change (ztcl#246).
//!
//! Each named slot of the public, internal, and internal platform stubs
//! tables of `src/cext/slots.zig` is an exported symbol with the name of
//! Tcl. A slot gets the function of the first group of
//! `src/cext/stubs.zig` that has it, the same function that a C package
//! reaches through the stubs table. A slot with no function gets a
//! function that writes the slot name to the standard error and aborts,
//! so a program stops at its first call of a missing function. The
//! functions of `tcl.h` outside the table (`Tcl_Main`, `Tcl_MainEx`,
//! `Tcl_PkgInitStubsCheck`, `Tcl_GetMemoryInfo`) come from `app.zig`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const stubs = @import("cext/stubs.zig");
const table = @import("cext/table.zig");
const app = @import("cext/app.zig");

pub const std_options: std.Options = .{ .logFn = @import("vt.zig").noLog };

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

/// True when slot `i` of table `k` has the name of an earlier slot.
fn seen(comptime k: table.Kind, comptime i: usize, comptime nm: []const u8) bool {
    const kinds = [_]table.Kind{ .public, .internal, .int_plat };
    for (kinds) |kk| {
        const n = if (kk == k) i else table.len(kk);
        for (0..n) |j| {
            if (table.name(kk, j)) |o| if (std.mem.eql(u8, o, nm)) return true;
        }
        if (kk == k) return false;
    }
    return false;
}

fn exportTable(comptime k: table.Kind) void {
    @setEvalBranchQuota(4_000_000);
    inline for (0..table.len(k)) |i| {
        const nm = comptime table.name(k, i) orelse continue;
        if (comptime seen(k, i, nm)) continue;
        // The platform tables of other systems list names such as
        // `Tcl_WinUtfToTChar`, and the slots file has the list of the
        // target, so each name here is a function of this target.
        comptime var found = false;
        inline for (stubs.groups) |g| {
            if (!found and @hasDecl(g, nm)) {
                @export(&@field(g, nm), .{ .name = nm });
                found = true;
            }
        }
        if (!found) @export(missingFn(k, i), .{ .name = nm });
    }
}

comptime {
    exportTable(.public);
    exportTable(.internal);
    exportTable(.int_plat);
    for (.{ "Tcl_Main", "Tcl_MainEx", "Tcl_PkgInitStubsCheck", "Tcl_GetMemoryInfo" }) |nm| {
        @export(&@field(app.extra, nm), .{ .name = nm });
    }
}

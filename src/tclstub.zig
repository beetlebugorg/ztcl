//! libtclstub8.6.a: the stub library that an extension built with
//! `-DUSE_TCL_STUBS` links. It has `Tcl_InitStubs`, which reads the stubs
//! table of the interp and sets `tclStubsPtr` and the pointers of the
//! other tables, so each call of a Tcl function in the extension goes
//! through the table of the interp that loads it (ztcl#246).
//!
//! The function follows the manual page `Tcl_InitStubs.3` of Tcl 8.6:
//! the interp starts with the fields `result`, `freeProc`, `errorLine`,
//! and the stubs table. The table starts with a magic number and the
//! hooks to the platform, internal, and internal platform tables. Slot 1
//! of the table is `Tcl_PkgRequireEx`, which gives the version of Tcl
//! and the table as the client data of the package `Tcl`.
//!
//! The symbols have hidden visibility, so each extension has its own
//! pointers and two extensions in one process do not share them.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

const magic: c_int = @bitCast(@as(u32, 0xFCA3BACF));
const TCL_STATIC: usize = 0;

const Hooks = extern struct {
    plat: ?*const anyopaque,
    internal: ?*const anyopaque,
    int_plat: ?*const anyopaque,
};

const PkgRequireEx = *const fn (*Interp, [*:0]const u8, ?[*:0]const u8, c_int, ?*?*anyopaque) callconv(.c) ?[*:0]const u8;
const SetResult = *const fn (*Interp, ?[*:0]const u8, usize) callconv(.c) void;

/// The start of the public stubs table: the magic number, the hooks, and
/// the first slots. Slot 0 is `Tcl_PkgProvideEx`, slot 1 is
/// `Tcl_PkgRequireEx`.
const Table = extern struct {
    magic: c_int,
    hooks: ?*const Hooks,
    pkg_provide_ex: ?*const anyopaque,
    pkg_require_ex: PkgRequireEx,
};

/// The start of `struct Interp` of Tcl 8.6.
const Interp = extern struct {
    result: [*:0]const u8,
    free_proc: usize,
    error_line: c_int,
    stub_table: ?*const Table,
};

var tclStubsPtr: ?*const Table = null;
var tclPlatStubsPtr: ?*const anyopaque = null;
var tclIntStubsPtr: ?*const anyopaque = null;
var tclIntPlatStubsPtr: ?*const anyopaque = null;
var tclTomMathStubsPtr: ?*const anyopaque = null;

/// True when `actual` is the version `want` or a patch level of it, such
/// as 8.6.16 for 8.6.
fn samePrefix(actual: []const u8, want: []const u8) bool {
    if (!std.mem.startsWith(u8, actual, want)) return false;
    return actual.len == want.len or actual[want.len] == '.';
}

fn initStubs(ip: *Interp, version: ?[*:0]const u8, exact: c_int) callconv(.c) ?[*:0]const u8 {
    const t = ip.stub_table orelse return incompatible(ip);
    if (t.magic != magic) return incompatible(ip);
    var data: ?*anyopaque = null;
    var actual = t.pkg_require_ex(ip, "Tcl", version, 0, &data) orelse return null;
    if (exact != 0) if (version) |v| {
        const want = std.mem.span(v);
        // A version of two parts with exact asks for that minor
        // version at any patch level.
        if (std.mem.count(u8, want, ".") == 1) {
            if (!samePrefix(std.mem.span(actual), want)) {
                _ = t.pkg_require_ex(ip, "Tcl", version, 1, null);
                return null;
            }
        } else {
            actual = t.pkg_require_ex(ip, "Tcl", version, 1, null) orelse return null;
        }
    };
    const table: *const Table = if (data) |d| @ptrCast(@alignCast(d)) else t;
    tclStubsPtr = table;
    if (table.hooks) |h| {
        tclPlatStubsPtr = h.plat;
        tclIntStubsPtr = h.internal;
        tclIntPlatStubsPtr = h.int_plat;
    } else {
        tclPlatStubsPtr = null;
        tclIntStubsPtr = null;
        tclIntPlatStubsPtr = null;
    }
    return actual;
}

fn incompatible(ip: *Interp) ?[*:0]const u8 {
    ip.result = "interpreter uses an incompatible stubs mechanism";
    ip.free_proc = TCL_STATIC;
    return null;
}

/// The table of the bignum functions comes as the client data of the
/// package `tcl::tommath`. Slots 0 and 1 give its epoch and revision.
fn initTomMath(ip: *Interp, version: ?[*:0]const u8, epoch: c_int, revision: c_int) callconv(.c) ?[*:0]const u8 {
    const t = tclStubsPtr orelse ip.stub_table orelse return incompatible(ip);
    var data: ?*anyopaque = null;
    const actual = t.pkg_require_ex(ip, "tcl::tommath", version, 0, &data) orelse return null;
    const TomMath = extern struct {
        magic: c_int,
        hooks: ?*const anyopaque,
        epoch: *const fn () callconv(.c) c_int,
        revision: *const fn () callconv(.c) c_int,
    };
    const tm: *const TomMath = @ptrCast(@alignCast(data orelse return tomMathError(ip)));
    if (tm.epoch() != epoch or tm.revision() < revision) return tomMathError(ip);
    tclTomMathStubsPtr = tm;
    return actual;
}

fn tomMathError(ip: *Interp) ?[*:0]const u8 {
    ip.result = "this extension needs the tcl::tommath stubs table of another version";
    ip.free_proc = TCL_STATIC;
    return null;
}

comptime {
    const hidden: std.builtin.SymbolVisibility = .hidden;
    @export(&initStubs, .{ .name = "Tcl_InitStubs", .visibility = hidden });
    @export(&initTomMath, .{ .name = "TclTomMathInitializeStubs", .visibility = hidden });
    @export(&tclStubsPtr, .{ .name = "tclStubsPtr", .visibility = hidden });
    @export(&tclPlatStubsPtr, .{ .name = "tclPlatStubsPtr", .visibility = hidden });
    @export(&tclIntStubsPtr, .{ .name = "tclIntStubsPtr", .visibility = hidden });
    @export(&tclIntPlatStubsPtr, .{ .name = "tclIntPlatStubsPtr", .visibility = hidden });
    @export(&tclTomMathStubsPtr, .{ .name = "tclTomMathStubsPtr", .visibility = hidden });
}

test "samePrefix" {
    try std.testing.expect(samePrefix("8.6.16", "8.6"));
    try std.testing.expect(samePrefix("8.6", "8.6"));
    try std.testing.expect(!samePrefix("8.61", "8.6"));
    try std.testing.expect(!samePrefix("8.5.1", "8.6"));
}

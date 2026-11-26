//! The channel slots of the stubs table, for the native path and the
//! WebAssembly path: a channel record of a package, its name, and its
//! close at the last unregister.
//!
//! A channel of a package is not a channel of ztcl yet: `read`, `puts`,
//! `seek`, and `close` of a script do not reach it. The area channels
//! adds that.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const obj = @import("obj.zig");
const Interp = obj.Interp;
const OK = obj.OK;
const panicText = obj.panicText;

const gpa = std.heap.c_allocator;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();

/// The first fields of `Tcl_ChannelType` of Tcl 8.6, up to `close2Proc`.
pub const ChannelType = extern struct {
    name: ?[*:0]const u8,
    version: ?*const anyopaque,
    close: ?*const fn (?*anyopaque, ?*Interp) callconv(.c) c_int,
    input: ?*const anyopaque,
    output: ?*const anyopaque,
    seek: ?*const anyopaque,
    set_option: ?*const anyopaque,
    get_option: ?*const anyopaque,
    watch: ?*const anyopaque,
    get_handle: ?*const anyopaque,
    close2: ?*const fn (?*anyopaque, ?*Interp, c_int) callconv(.c) c_int,
};

/// The `closeProc` value that tells Tcl to call `close2Proc`.
const TCL_CLOSE2PROC: usize = 1;

/// A channel of the package. Scripts do not see it yet: `read`, `puts`,
/// `seek`, and `close` of ztcl do not reach it. The package can name it,
/// and the last unregister closes it with the close procedure of its type.
pub const Channel = struct {
    type: *const ChannelType,
    name: [:0]u8,
    data: ?*anyopaque,
    mask: c_int,
    refs: c_int = 0,
};

pub fn Tcl_CreateChannel(t: *const ChannelType, name: ?[*:0]const u8, data: ?*anyopaque, mask: c_int) callconv(.c) *Channel {
    const c = gpa.create(Channel) catch panicText("out of memory");
    const n = if (name) |p| std.mem.span(p) else "";
    c.* = .{ .type = t, .name = gpa.dupeSentinel(u8, n, 0) catch panicText("out of memory"), .data = data, .mask = mask };
    return c;
}

pub fn Tcl_GetChannelName(c: *Channel) callconv(.c) [*:0]const u8 {
    return c.name.ptr;
}

pub fn Tcl_RegisterChannel(_: ?*Interp, c: ?*Channel) callconv(.c) void {
    if (c) |ch| ch.refs += 1;
}

/// Removes one reference. The last one closes the channel and frees it.
pub fn Tcl_UnregisterChannel(ip: ?*Interp, c: *Channel) callconv(.c) c_int {
    c.refs -= 1;
    if (c.refs > 0) return OK;
    const t = c.type;
    const rc: c_int = if (t.close != null and @intFromPtr(t.close.?) != TCL_CLOSE2PROC)
        t.close.?(c.data, ip)
    else if (t.close2) |f| f(c.data, ip, 0) else OK;
    gpa.free(c.name);
    gpa.destroy(c);
    return rc;
}

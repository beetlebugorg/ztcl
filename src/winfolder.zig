//! The optional `ztcl::win::folder` command: the known folders of the
//! user and of the system on Windows (capability `env`, part of
//! ztcl#111).
//!
//!     ztcl::win::folder name
//!
//! The names are `desktop`, `documents`, `downloads`, `music`,
//! `pictures`, `videos`, `appdata` (the roaming one), `localappdata`,
//! `programdata`, `profile`, and `programfiles`. The path comes from
//! `SHGetKnownFolderPath`, so a folder that the user moved gives its new
//! place, with `/` between the parts as the file commands of ztcl use. The
//! command reads the path and makes no change. On another platform it
//! gives `ZTCL WIN UNAVAILABLE`.
//!
//! The IDs follow `KnownFolders.h` of the Windows SDK 10.0.26100.0.
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const on_win = builtin.os.tag == .windows;

const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

/// The names of the command and their FOLDERID.
pub const folders = [_]struct { name: []const u8, id: GUID }{
    .{ .name = "appdata", .id = .{ .a = 0x3EB685DB, .b = 0x65F9, .c = 0x4CF6, .d = .{ 0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D } } },
    .{ .name = "desktop", .id = .{ .a = 0xB4BFCC3A, .b = 0xDB2C, .c = 0x424C, .d = .{ 0xB0, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41 } } },
    .{ .name = "documents", .id = .{ .a = 0xFDD39AD0, .b = 0x238F, .c = 0x46AF, .d = .{ 0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7 } } },
    .{ .name = "downloads", .id = .{ .a = 0x374de290, .b = 0x123f, .c = 0x4565, .d = .{ 0x91, 0x64, 0x39, 0xc4, 0x92, 0x5e, 0x46, 0x7b } } },
    .{ .name = "localappdata", .id = .{ .a = 0xF1B32785, .b = 0x6FBA, .c = 0x4FCF, .d = .{ 0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91 } } },
    .{ .name = "music", .id = .{ .a = 0x4BD8D571, .b = 0x6D19, .c = 0x48D3, .d = .{ 0xBE, 0x97, 0x42, 0x22, 0x20, 0x08, 0x0E, 0x43 } } },
    .{ .name = "pictures", .id = .{ .a = 0x33E28130, .b = 0x4E1E, .c = 0x4676, .d = .{ 0x83, 0x5A, 0x98, 0x39, 0x5C, 0x3B, 0xC3, 0xBB } } },
    .{ .name = "profile", .id = .{ .a = 0x5E6C858F, .b = 0x0E22, .c = 0x4760, .d = .{ 0x9A, 0xFE, 0xEA, 0x33, 0x17, 0xB6, 0x71, 0x73 } } },
    .{ .name = "programdata", .id = .{ .a = 0x62AB5D82, .b = 0xFDC1, .c = 0x4DC3, .d = .{ 0xA9, 0xDD, 0x07, 0x0D, 0x1D, 0x49, 0x5D, 0x97 } } },
    .{ .name = "programfiles", .id = .{ .a = 0x905e63b6, .b = 0xc1bf, .c = 0x494e, .d = .{ 0xb2, 0x9c, 0x65, 0xb7, 0x32, 0xd3, 0xd2, 0x1a } } },
    .{ .name = "videos", .id = .{ .a = 0x18989B1D, .b = 0x99B5, .c = 0x455B, .d = .{ 0x84, 0x1C, 0xAB, 0x7C, 0x74, 0xE4, 0xDD, 0xFC } } },
};

extern "shell32" fn SHGetKnownFolderPath(id: *const GUID, flags: u32, token: ?*anyopaque, out: *?[*:0]u16) callconv(.winapi) i32;
extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("ztcl::win::folder", cmdFolder);
}

/// The names for the error of a bad name.
const names = blk: {
    var s: []const u8 = "";
    for (folders, 0..) |f, i| {
        s = s ++ (if (i == 0) "" else if (i == folders.len - 1) ", or " else ", ") ++ f.name;
    }
    break :blk s;
};

fn cmdFolder(it: *Interp, args: []const Value, _: ?*interp.Cmd) Error!Value {
    if (args.len != 2) return it.wrongArgs("ztcl::win::folder name");
    const name = try it.str(args[1]);
    const f = for (folders) |f| {
        if (std.mem.eql(u8, f.name, name)) break f;
    } else return it.fail("bad folder \"{s}\": must be {s}", .{ name, names });
    if (comptime !on_win) return it.failCode("ZTCL WIN UNAVAILABLE", "ztcl::win::folder is only on Windows", .{});
    var p: ?[*:0]u16 = null;
    const hr = SHGetKnownFolderPath(&f.id, 0, null, &p);
    defer CoTaskMemFree(p);
    if (hr < 0 or p == null) return it.failCode("ZTCL WIN FOLDER", "Windows has no folder \"{s}\" for this user", .{name});
    const path = std.unicode.utf16LeToUtf8Alloc(it.alloc(), std.mem.span(p.?)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return it.failCode("ZTCL WIN FOLDER", "the path of \"{s}\" is not valid Unicode", .{name}),
    };
    std.mem.replaceScalar(u8, path, '\\', '/');
    return .{ .str = path };
}

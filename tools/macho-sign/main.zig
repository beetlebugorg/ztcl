//! `macho-sign IN OUT IDENT [ENTITLEMENT ...]`: writes OUT, a copy of
//! the Mach-O file IN with a new ad hoc signature and the entitlements,
//! each with the value true (`src/macho.zig`). `zig build` signs the
//! macOS `ztcl` with it, so `ztcl::vm` runs with no `codesign` step.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const macho = @import("macho");

pub fn main(init: std.process.Init) !u8 {
    const a = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) {
        std.debug.print("usage: macho-sign IN OUT IDENT [ENTITLEMENT ...]\n", .{});
        return 2;
    }
    const cwd = std.Io.Dir.cwd();
    const bin = try cwd.readFileAlloc(io, args[1], a, .limited(1 << 30));
    defer a.free(bin);
    const out = try macho.sign(a, bin, args[3], args[4..]);
    defer a.free(out);
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out, .flags = .{ .permissions = .executable_file } });
    return 0;
}

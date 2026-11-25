//! Prints the state of the executable memory of the JIT on this system:
//! the self test, and on arm64 macOS the reason of a failed region and
//! its errno. On arm64 macOS it also tries the page form of a region: a
//! `MAP_JIT` mapping with read and write rights, then `mprotect` to read
//! and execute. CI runs it on each runner, so a log shows why the JIT is
//! off on a runner.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const tcl = @import("ztcl");
const c = std.c;

extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

fn errno() c_int {
    return @intFromEnum(c.errno(-1));
}

/// The page form: map read and write with MAP_JIT, write `mov w0, #42;
/// ret`, mprotect to read and execute, and call it.
fn pageForm() void {
    const page = std.heap.pageSize();
    const p = c.mmap(null, page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true }, -1, 0);
    if (p == c.MAP_FAILED) return std.debug.print("page form: mmap rw MAP_JIT failed, errno={d}\n", .{errno()});
    const a: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(p));
    @memcpy(a[0..8], &[_]u8{ 0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6 });
    if (c.mprotect(a, page, .{ .READ = true, .EXEC = true }) != 0) return std.debug.print("page form: mprotect rx failed, errno={d}\n", .{errno()});
    sys_icache_invalidate(a, 8);
    const f: *const fn () callconv(.c) u32 = @ptrCast(a);
    std.debug.print("page form: call gives {d}\n", .{f()});
    const back = c.mprotect(a, page, .{ .READ = true, .WRITE = true });
    std.debug.print("page form: mprotect back to rw gives {d}, errno={d}\n", .{ back, if (back != 0) errno() else 0 });
}

pub fn main() void {
    const mem = tcl.jit.parts.mem;
    const ok = mem.selfTest();
    std.debug.print("jit-probe: built={} selfTest={} failure={t} errno={d}\n", .{ tcl.jit.built, ok, mem.last_failure, mem.last_errno });
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) pageForm();
    if (tcl.jit.built and !ok) std.process.exit(1);
}

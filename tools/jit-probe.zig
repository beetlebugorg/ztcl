//! Prints the state of the executable memory of the JIT on this system:
//! the self test, the form of the region on arm64 macOS, and the reason
//! and the errno of a failed region. CI runs it on each runner, so a log
//! shows which form the JIT uses there, or why it is off.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl");

pub fn main() void {
    const mem = tcl.jit.parts.mem;
    const ok = mem.selfTest();
    var form: []const u8 = "none";
    if (mem.Region.init(std.heap.pageSize())) |r| {
        var region = r;
        // Linux has only the page form.
        form = if (region.pages or @import("builtin").os.tag == .linux) "pages" else "packed";
        region.deinit();
    }
    std.debug.print("jit-probe: built={} selfTest={} region={s} failure={t} errno={d}\n", .{ tcl.jit.built, ok, form, mem.last_failure, mem.last_errno });
    if (tcl.jit.built and !ok) std.process.exit(1);
}

//! Prints the state of the executable memory of the JIT on this system:
//! the self test, and on arm64 macOS the reason of a failed region and
//! its errno. CI runs it on each runner, so a log shows why the JIT is
//! off on a runner.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl");

pub fn main() void {
    const mem = tcl.jit.parts.mem;
    const ok = mem.selfTest();
    std.debug.print("jit-probe: built={} selfTest={} failure={t} errno={d}\n", .{ tcl.jit.built, ok, mem.last_failure, mem.last_errno });
    if (tcl.jit.built and !ok) std.process.exit(1);
}

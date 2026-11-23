//! ztcl: a Tcl interpreter in Zig.
//!
//! The module stands alone: it uses only the standard library. See
//! docs/design.md for the design.
//!
//! ```zig
//! var it: ztcl.Interp = undefined;
//! try it.init(gpa);
//! defer it.deinit();
//! it.step_limit = 1_000_000;
//! const v = try it.eval("expr {6 * 7}");
//! ```
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const value = @import("value.zig");
pub const interp = @import("interp.zig");
pub const expr = @import("expr.zig");
pub const noise = @import("noise.zig");
pub const point = @import("point.zig");
pub const compact = @import("compact.zig");
pub const heap = @import("heap.zig");
pub const gc = @import("gc.zig");
pub const coro = @import("coro.zig");
pub const more = @import("more.zig");
pub const regex = @import("regex.zig");
pub const fsroot = @import("fsroot.zig");
pub const sys = @import("sys.zig");
pub const thread = @import("thread.zig");
pub const proc = @import("proc.zig");
pub const chan = @import("chan.zig");
pub const event = @import("event.zig");
pub const sock = @import("sock.zig");
pub const jit = @import("jit.zig");
/// The bytecode and the verifier of the JIT, for the tools of the JIT.
pub const vm = @import("vm.zig");
pub const jit_verify = @import("jit/verify.zig");
pub const jit_tier2 = @import("jit/tier2.zig");

pub const Value = value.Value;
pub const Interp = interp.Interp;
pub const Error = interp.Error;
pub const Output = interp.Output;

test {
    _ = value;
    _ = interp;
    _ = expr;
    _ = noise;
    _ = point;
    _ = compact;
    _ = heap;
    _ = @import("tests.zig");
    _ = @import("jit/tests.zig");
}

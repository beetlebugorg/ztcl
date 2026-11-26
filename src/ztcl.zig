//! ztcl: a Tcl interpreter in Zig.
//!
//! The module stands alone: it uses only the standard library. See
//! docs/dev/design.md for the design.
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
/// The writer of WebAssembly modules, for `ztcl compile`.
pub const wasm_out = @import("wasm_out.zig");
pub const wasm_link = @import("wasm_link.zig");
pub const point_wasm = @import("point_wasm.zig");
pub const point_fuzz = @import("point_fuzz.zig");
pub const compact = @import("compact.zig");
pub const heap = @import("heap.zig");
pub const gc = @import("gc.zig");
pub const coro = @import("coro.zig");
pub const more = @import("more.zig");
pub const regex = @import("regex.zig");
pub const fsroot = @import("fsroot.zig");
pub const proc = @import("proc.zig");
pub const pty = @import("pty.zig");
pub const watch = @import("watch.zig");
pub const vfs = @import("vfs.zig");
pub const zipread = @import("zipread.zig");
pub const filecmd = @import("filecmd.zig");
pub const sys = @import("sys.zig");
pub const thread = @import("thread.zig");
pub const chan = @import("chan.zig");
pub const event = @import("event.zig");
pub const sock = @import("sock.zig");
pub const jit = @import("jit.zig");
/// The compiler of procs to WebAssembly: `ztcl compile --wasm`.
pub const wasm_aot = @import("wasm_aot/aot.zig");
/// The bytecode and the verifier of the JIT, for the tools of the JIT.
pub const vm = @import("vm.zig");
pub const jit_verify = @import("jit/verify.zig");
pub const jit_tier2 = @import("jit/tier2.zig");
/// The bundle of `ztcl build --wasm`.
pub const wasmbundle = @import("wasmbundle.zig");
/// The JSON parser, for the tools of the JSON module.
pub const json = struct {
    pub const index = @import("json/index.zig");
    pub const build = @import("json/build.zig");
};

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
    _ = wasm_out;
    _ = wasm_link;
    _ = point_wasm;
    _ = point_fuzz;
    _ = compact;
    _ = heap;
    _ = @import("tests.zig");
    _ = @import("pty_tests.zig");
    _ = @import("watch_tests.zig");
    _ = @import("zipread.zig");
    _ = @import("inflate.zig");
    _ = @import("vfs_tests.zig");
    _ = wasmbundle;
    _ = @import("wasmfiles.zig");
    _ = @import("jit/tests.zig");
}

//! ztcl: a Tcl interpreter in Zig.
//!
//! The module stands alone: it uses only the standard library. See
//! docs/dev/design.md for the design.
//!
//! ```zig
//! var it: ztcl.Interp = undefined;
//! try it.init(gpa);
//! defer it.deinit();
//! it.compute_limit = 1_000_000;
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
pub const launch = @import("launch.zig");
pub const winreg = @import("winreg.zig");
pub const mac = @import("mac.zig");
pub const proc = if (@import("builtin").os.tag == .windows) @import("proc_windows.zig") else @import("proc.zig");
pub const pty = if (@import("builtin").os.tag == .windows) @import("pty_windows.zig") else @import("pty.zig");
/// The terminal state of the module `ztcl::vt`, on libghostty-vt.
pub const vt = @import("vt.zig");
pub const notify = @import("notify.zig");
pub const watch = @import("watch.zig");
pub const probe = @import("probe.zig");
pub const debug = @import("debug.zig");
pub const debugmcp = @import("debugmcp.zig");
pub const dap = @import("dap.zig");
pub const tape = @import("tape.zig");
pub const vfs = @import("vfs.zig");
pub const zipread = @import("zipread.zig");
pub const zipwrite = @import("zipwrite.zig");
pub const buildnative = @import("buildnative.zig");
pub const dbus = @import("dbus.zig");
pub const macho = @import("macho.zig");
pub const isoproto = @import("isoproto.zig");
pub const isothread = @import("isothread.zig");
pub const isolate_mac = @import("isolate_mac.zig");
pub const isobroker = @import("isobroker.zig");
pub const vmimage = @import("vmimage.zig");
pub const vmstore = @import("vmstore.zig");
pub const microvm = @import("microvm.zig");
pub const isolate_linux = @import("isolate_linux.zig");
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
/// The interactive shell of the runner and its terminal, for the runner
/// and for the WebAssembly builds with a shell.
pub const shell = @import("shell/shell.zig");
pub const shell_term = if (@import("builtin").os.tag == .freestanding) @import("shell/term_web.zig") else @import("shell/term.zig");
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
    _ = @import("notify_windows.zig");
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
    if ((@hasDecl(@import("build_options"), "cext") and @import("build_options").cext)) {
        _ = @import("cext/cext.zig");
        _ = @import("cext/pkgs.zig");
    }
    _ = @import("pty_tests.zig");
    _ = @import("proc_windows_tests.zig");
    _ = @import("isolate_windows_tests.zig");
    _ = @import("pty_windows_tests.zig");
    _ = @import("watch_tests.zig");
    _ = @import("probe_tests.zig");
    _ = @import("debug_tests.zig");
    _ = @import("meter_tests.zig");
    _ = @import("meter.zig");
    _ = @import("zipread.zig");
    _ = @import("inflate.zig");
    _ = @import("vfs_tests.zig");
    _ = @import("tcl9_tests.zig");
    _ = @import("math9.zig");
    _ = @import("wasmweb.zig");
    if (@import("builtin").os.tag == .linux) _ = @import("kvm.zig");
    if (@import("builtin").os.tag == .linux) _ = @import("vm/share_linux.zig");
    _ = @import("vm/virtio/mmio.zig");
    _ = @import("vm/virtio/vsock.zig");
    _ = @import("vm/boot.zig");
    if (@import("builtin").os.tag == .windows) _ = @import("whp.zig");
    _ = @import("vm/virtio/ninep.zig");
    _ = @import("vm/virtio/fuse.zig");
    _ = @import("vm/nat/nat.zig");
    _ = zipwrite;
    _ = buildnative;
    _ = dbus;
    _ = macho;
    _ = isoproto;
    _ = isobroker;
    _ = vmimage;
    _ = vmstore;
    if (@import("builtin").os.tag == .macos) _ = isolate_mac;
    if (@import("builtin").os.tag == .linux) _ = @import("isolate_linux_tests.zig");
    _ = wasmbundle;
    _ = @import("wasmfiles.zig");
    _ = @import("jit/tests.zig");
}

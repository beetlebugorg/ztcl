//! The entry of the `ztcl` command component of WASI 0.3.2
//! (docs/dev/wasi-tasks/06-native.md). The module exports
//! `wasi:cli/run@0.3.2#run` with a synchronous lift and imports only WASI
//! 0.3.2 functions: the declaration `ztcl_wasi_p3` makes `sys.zig` use
//! `sys_wasi3.zig`, and the panic handler and the debug `Io` of the
//! standard library use no preview 1 function.
//!
//! `run` reads the script file of the first argument through the
//! preopened folders, sets `argv`, `argc`, and `argv0` as tclsh does, and
//! evaluates the script. `puts` writes to the `stdout` stream. An error
//! writes `errorInfo` to the `stderr` stream and gives the exit code 1.
//! The command `exit` ends the program with its code through
//! `wasi:cli/exit`. No capability is on.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl");
const host = tcl.sys.wasi3;

pub const ztcl_wasi_p3 = true;

fn panicFn(_: []const u8, _: ?usize) noreturn {
    @trap();
}

pub const panic = std.debug.FullPanic(panicFn);
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;
pub const std_options_debug_io: std.Io = std.Io.failing;

const gpa = std.heap.wasm_allocator;

fn out(_: ?*anyopaque, bytes: []const u8) void {
    _ = tcl.sys.write(1, bytes);
}

fn err(bytes: []const u8) void {
    _ = tcl.sys.write(2, bytes);
}

fn cmdExit(it: *tcl.Interp, argv: []const tcl.Value, _: ?*tcl.interp.Cmd) tcl.Error!tcl.Value {
    if (argv.len > 2) return it.wrongArgs("exit ?returnCode?");
    var code: i64 = 0;
    if (argv.len == 2) code = argv[1].asInt() orelse return it.fail("expected integer but got \"{s}\"", .{try it.str(argv[1])});
    host.exit(@truncate(@as(u64, @bitCast(code))));
}

fn start(it: *tcl.Interp, args: []const []const u8) !u8 {
    if (args.len < 2) {
        err("usage: ztcl.component.wasm script.tcl ?arg ...?\n");
        return 2;
    }
    const text = host.readScript(gpa, args[1]) catch {
        err("ztcl: cannot read ");
        err(args[1]);
        err("\n");
        return 1;
    };
    try it.register("exit", cmdExit);
    const a = it.alloc();
    var list: std.ArrayList(tcl.Value) = .empty;
    for (args[2..]) |w| try list.append(a, .{ .str = w });
    try it.setVar("argv", try tcl.value.wrapList(a, list.items));
    try it.setVar("argc", .{ .int = @intCast(list.items.len) });
    try it.setVar("argv0", .{ .str = args[1] });
    try it.setVar("tcl_interactive", .{ .int = 0 });
    it.script_name = args[1];
    _ = it.eval(text) catch |e| {
        if (e != error.TclError) return 1;
        it.finishError() catch {};
        const info = it.getVarPlain("::errorInfo") catch it.result;
        err(it.str(info) catch "error");
        err("\n");
        return 1;
    };
    return 0;
}

/// Gives 0 for `ok` and 1 for `err` of the `result` of `run`.
fn run() callconv(.c) u32 {
    var it: tcl.Interp = undefined;
    it.init(gpa) catch return 1;
    it.output = .{ .write = out };
    const code = start(&it, host.args()) catch 1;
    it.deinit();
    if (code > 1) host.exit(code);
    host.flush();
    return code;
}

/// The allocator of the canonical ABI: the host calls it to put lists and
/// texts into the memory of the module.
fn cabiRealloc(old: ?[*]u8, old_len: usize, alignment: usize, len: usize) callconv(.c) ?[*]u8 {
    const al = std.mem.Alignment.fromByteUnits(alignment);
    if (old) |p| {
        if (gpa.rawResize(p[0..old_len], al, len, 0)) return p;
        const n = gpa.rawAlloc(len, al, 0) orelse return null;
        @memcpy(n[0..@min(old_len, len)], p[0..@min(old_len, len)]);
        gpa.rawFree(p[0..old_len], al, 0);
        return n;
    }
    return gpa.rawAlloc(len, al, 0);
}

comptime {
    @export(&run, .{ .name = "wasi:cli/run@0.3.2#run" });
    @export(&cabiRealloc, .{ .name = "cabi_realloc" });
}

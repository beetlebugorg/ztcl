//! The entry of the `ztcl` command component of WASI 0.3.2
//! (docs/dev/wasi-tasks/06-native.md). The module exports
//! `wasi:cli/run@0.3.2#run` with a synchronous lift and imports only WASI
//! 0.3.2 functions: the declaration `ztcl_wasi_p3` makes `sys.zig` use
//! `sys_wasi3.zig`, and the panic handler and the debug `Io` of the
//! standard library use no preview 1 function.
//!
//! `run` gives the arguments of `wasi:cli/environment` to `runHost` of
//! `src/main.zig`, the runner of the native `ztcl`, with a `Host` of
//! WASI 0.3.2 functions: the output and the input on the streams of
//! `wasi:cli`, script files through the preopened folders, the clocks of
//! `wasi:clocks`, and the exit code through `wasi:cli/exit`. So the
//! component reads the flags of `ztcl` (`--allow`, `--root`, the limits,
//! `--tclsh`), and `file`, channels, `clock`, and the event loop work on
//! the WASI 0.3.2 forms of `sys.zig` and `fsroot.zig`. With no flag, no
//! capability is on.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl");
const host = tcl.sys.wasi3;
const runner = @import("runner");

pub const ztcl_wasi_p3 = true;

fn panicFn(_: []const u8, _: ?usize) noreturn {
    @trap();
}

pub const panic = std.debug.FullPanic(panicFn);
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;
pub const std_options_debug_io: std.Io = std.Io.failing;

const gpa = std.heap.wasm_allocator;

/// The writer of standard output: each drain writes to descriptor 1.
fn drainOut(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    if (w.end > 0) {
        _ = tcl.sys.write(1, w.buffer[0..w.end]);
        w.end = 0;
    }
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |d| {
        _ = tcl.sys.write(1, d);
        n += d.len;
    }
    const last = data[data.len - 1];
    for (0..splat) |_| _ = tcl.sys.write(1, last);
    return n + last.len * splat;
}

/// The reader of standard input: each fill reads descriptor 0.
fn streamIn(_: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const room = limit.slice(try w.writableSliceGreedy(1));
    const n = switch (tcl.sys.read(0, room)) {
        .n => |n| n,
        else => 0,
    };
    if (n == 0) return error.EndOfStream;
    w.advance(n);
    return n;
}

fn noEnv(_: []const u8) ?[]const u8 {
    // The component has no JIT, the variable `ZTCL_JIT` of the runner.
    return null;
}

fn readFile(path: []const u8, a: std.mem.Allocator) anyerror![]u8 {
    return host.readScript(a, path);
}

fn exitWith(code: u8) noreturn {
    host.exit(code);
}

fn nanos() i96 {
    return host.monoNanos();
}

fn clockNow(_: ?*anyopaque) i64 {
    return host.wallMicros();
}

fn ticks(_: ?*anyopaque) i64 {
    return @intCast(host.monoNanos() / 1000);
}

fn sleep(_: ?*anyopaque, micros: i64) void {
    if (micros > 0) host.sleepNanos(@as(u64, @intCast(micros)) * 1000);
}

/// The TZif file of a zone, through the preopened folders.
fn zone(_: ?*anyopaque, name: []const u8, a: std.mem.Allocator) ?[]const u8 {
    const path = std.fmt.allocPrint(a, "/usr/share/zoneinfo/{s}", .{name}) catch return null;
    return host.readScript(a, path) catch null;
}

/// Gives 0 for `ok` and 1 for `err` of the `result` of `run`.
fn run() callconv(.c) u32 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    var out_buf: [1 << 16]u8 = undefined;
    var out: std.Io.Writer = .{ .vtable = &.{ .drain = drainOut }, .buffer = &out_buf };
    var in_buf: [1 << 16]u8 = undefined;
    var in: std.Io.Reader = .{ .vtable = &.{ .stream = streamIn }, .buffer = &in_buf, .seek = 0, .end = 0 };
    const h: runner.Host = .{
        .io = null,
        .gpa = gpa,
        .arena = arena.allocator(),
        .args = host.args(),
        .out = &out,
        .in = &in,
        .env = noEnv,
        .read = readFile,
        .exit = exitWith,
        .nanos = nanos,
        .clock = .{ .now = clockNow, .zone = zone },
        .event = .{ .now = ticks, .sleep = sleep },
    };
    runner.runHost(&h, null) catch {
        out.flush() catch {};
        host.flush();
        return 1;
    };
    out.flush() catch {};
    host.flush();
    return 0;
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

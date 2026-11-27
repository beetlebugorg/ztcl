//! The WASI 0.3.2 form of the platform interface of `sys.zig`, on the
//! generated imports of `src/wasi/p3.zig` and the async layer of
//! `src/wasi/async.zig` (docs/dev/wasi-tasks/06-native.md).
//!
//! Standard input, output, and error are `stream<u8>` values of
//! `wasi:cli`. The first write to descriptor 1 or 2 makes a stream, gives
//! its readable end to `write-via-stream`, and keeps the writable end and
//! the future of the result. Each write copies the bytes into the stream
//! and blocks the task in a waitable set until the host has taken them.
//! `flush` drops the writable ends and waits for each future, so the host
//! has all the output before the program ends. The first read of
//! descriptor 0 gets the stream of `wasi:cli/stdin`; a read that finds
//! the stream dropped is the end of the input.
//!
//! The host part has the arguments and the environment of
//! `wasi:cli/environment`, the read of a script file through the
//! preopened folders of `wasi:filesystem`, and the exit code of
//! `wasi:cli/exit`. Each list or text that the host gives comes into the
//! memory of the module through the export `cabi_realloc` of the entry
//! file (`src/wasi/run.zig`).
//!
//! This first form has no other descriptor: files and sockets give
//! EBADF or ENOTSUP, and `poll` marks each wanted read and write as
//! ready, so the next call blocks until it ends.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const sys = @import("sys.zig");
const p3 = @import("wasi/p3.zig");
const abi = @import("wasi/async.zig");

pub const E = std.os.wasi.errno_t;

const Out = struct {
    writable: u32 = 0,
    future: u32 = 0,
    open: bool = false,
    broken: bool = false,
};

var outs: [2]Out = .{ .{}, .{} };
var in_stream: u32 = 0;
var in_future: u32 = 0;
var in_state: enum { closed, open, done } = .closed;
var wait_set: ?abi.WaitSet = null;

fn set() abi.WaitSet {
    if (wait_set == null) wait_set = abi.WaitSet.init();
    return wait_set.?;
}

const ebadf: sys.Fail = .{ .name = "EBADF", .text = "bad file number" };
const epipe: sys.Fail = .{ .name = "EPIPE", .text = "broken pipe" };

fn openOut(i: usize) *Out {
    const o = &outs[i];
    if (o.open) return o;
    o.open = true;
    if (i == 0) {
        const pair = p3.cli_stdout.write_via_stream.stream0.new();
        o.writable = @truncate(pair >> 32);
        o.future = p3.cli_stdout.write_via_stream.call(@truncate(pair));
    } else {
        const pair = p3.cli_stderr.write_via_stream.stream0.new();
        o.writable = @truncate(pair >> 32);
        o.future = p3.cli_stderr.write_via_stream.call(@truncate(pair));
    }
    return o;
}

fn writeOut(i: usize, buf: []const u8) sys.IoResult {
    const o = openOut(i);
    if (o.broken) return .{ .err = epipe };
    var done: usize = 0;
    while (done < buf.len) {
        const rest = buf[done..];
        const raw = if (i == 0)
            p3.cli_stdout.write_via_stream.stream0.write(o.writable, @intFromPtr(rest.ptr), @intCast(rest.len))
        else
            p3.cli_stderr.write_via_stream.stream0.write(o.writable, @intFromPtr(rest.ptr), @intCast(rest.len));
        const c = abi.finish(set(), o.writable, raw);
        done += c.count;
        if (c.state != .completed) {
            o.broken = true;
            break;
        }
    }
    if (done == 0 and buf.len > 0) return .{ .err = epipe };
    return .{ .n = done };
}

/// Drops the writable ends of standard output and error, and waits for
/// the host to take the rest of each stream.
pub fn flush() void {
    for (&outs, 0..) |*o, i| {
        if (!o.open) continue;
        var res: p3.cli_stdout.write_via_stream.future1.Elem = undefined;
        if (i == 0) {
            p3.cli_stdout.write_via_stream.stream0.drop_writable(o.writable);
            _ = abi.finish(set(), o.future, p3.cli_stdout.write_via_stream.future1.read(o.future, @intFromPtr(&res)));
            p3.cli_stdout.write_via_stream.future1.drop_readable(o.future);
        } else {
            p3.cli_stderr.write_via_stream.stream0.drop_writable(o.writable);
            _ = abi.finish(set(), o.future, p3.cli_stderr.write_via_stream.future1.read(o.future, @intFromPtr(&res)));
            p3.cli_stderr.write_via_stream.future1.drop_readable(o.future);
        }
        o.* = .{};
    }
}

fn readIn(buf: []u8) sys.IoResult {
    if (in_state == .closed) {
        var ret: p3.cli_stdin.read_via_stream.Ret = undefined;
        p3.cli_stdin.read_via_stream.call(@intFromPtr(&ret));
        in_stream = ret.@"0";
        in_future = ret.@"1";
        in_state = .open;
    }
    if (in_state == .done or buf.len == 0) return .{ .n = 0 };
    const c = abi.finish(set(), in_stream, p3.cli_stdin.read_via_stream.stream0.read(in_stream, @intFromPtr(buf.ptr), @intCast(buf.len)));
    if (c.state != .completed) {
        in_state = .done;
        p3.cli_stdin.read_via_stream.stream0.drop_readable(in_stream);
        p3.cli_stdin.read_via_stream.future1.drop_readable(in_future);
    }
    return .{ .n = c.count };
}

pub fn read(fd: i32, buf: []u8) sys.IoResult {
    if (fd == 0) return readIn(buf);
    return .{ .err = ebadf };
}

pub fn readFile(fd: i32, buf: []u8) sys.FileRead {
    if (fd == 0) return switch (readIn(buf)) {
        .n => |n| .{ .n = n },
        else => .{ .err = .IO },
    };
    return .{ .err = .BADF };
}

pub fn writeFile(fd: i32, buf: []const u8) sys.FileRead {
    if (fd == 1 or fd == 2) return switch (writeOut(@intCast(fd - 1), buf)) {
        .n => |n| .{ .n = n },
        else => .{ .err = .PIPE },
    };
    return .{ .err = .BADF };
}

pub fn write(fd: i32, buf: []const u8) sys.IoResult {
    if (fd == 1 or fd == 2) return writeOut(@intCast(fd - 1), buf);
    return .{ .err = ebadf };
}

pub fn close(_: i32) void {}

pub fn setBlocking(_: i32, _: bool) void {}

/// Each read and write of standard input and output blocks the task
/// until it ends, so each want is ready.
pub fn poll(_: std.mem.Allocator, wants: []sys.Want, _: i32) void {
    for (wants) |*w| {
        if (w.read) w.can_read = true;
        if (w.write) w.can_write = true;
    }
}

pub fn seek(_: i32, _: i64, _: u8) sys.SeekResult {
    return .{ .err = .SPIPE };
}

const notsup: sys.Fail = .{ .name = "ENOTSUP", .text = "operation not supported" };

pub fn listenAt(_: sys.Addr, _: bool) sys.SockResult {
    return .{ .err = notsup };
}

pub fn connectTo(_: sys.Addr, _: ?sys.Addr, _: bool) sys.SockResult {
    return .{ .err = notsup };
}

pub fn resolve(_: std.mem.Allocator, _: []const u8, _: *std.ArrayList(sys.Addr)) std.mem.Allocator.Error!void {}

pub fn connectError(_: i32) ?sys.Fail {
    return notsup;
}

pub fn accept(_: i32) ?sys.Accepted {
    return null;
}

pub fn sockName(_: i32) ?sys.Addr {
    return null;
}

pub fn peerName(_: i32) ?sys.Addr {
    return null;
}

pub fn shutdown(_: i32, _: i32) void {}

// The host part for the entry file.

fn text(s: p3.String) []const u8 {
    if (s.len == 0) return "";
    return @as([*]const u8, @ptrFromInt(s.ptr))[0..s.len];
}

/// The arguments of the program. The host puts the list in memory from
/// `cabi_realloc`.
pub fn args() []const []const u8 {
    var ret: p3.cli_environment.get_arguments.Ret = undefined;
    p3.cli_environment.get_arguments.call(@intFromPtr(&ret));
    if (ret.len == 0) return &.{};
    const items = @as([*]const p3.String, @ptrFromInt(ret.ptr))[0..ret.len];
    const out = std.heap.wasm_allocator.alloc([]const u8, items.len) catch return &.{};
    for (items, out) |s, *o| o.* = text(s);
    return out;
}

pub const ReadError = error{ NotFound, Io, OutOfMemory };

/// Reads the file at `path` through the preopened folders. A relative
/// path is relative to the first preopen. An absolute path goes to the
/// preopen with the longest name that is a prefix of the path at a `/`.
pub fn readScript(a: std.mem.Allocator, path: []const u8) ReadError![]u8 {
    var dirs: p3.filesystem_preopens.get_directories.Ret = undefined;
    p3.filesystem_preopens.get_directories.call(@intFromPtr(&dirs));
    const Entry = p3.filesystem_preopens.get_directories.Ret.Elem;
    const list = if (dirs.len == 0) &[_]Entry{} else @as([*]const Entry, @ptrFromInt(dirs.ptr))[0..dirs.len];
    if (list.len == 0) return error.NotFound;
    var dir = list[0].@"0";
    var rest = path;
    if (path.len > 0 and path[0] == '/') {
        var best: ?usize = null;
        for (list) |e| {
            const name = std.mem.trimEnd(u8, text(e.@"1"), "/");
            if (!std.mem.startsWith(u8, path, name)) continue;
            if (path.len > name.len and path[name.len] != '/') continue;
            if (best != null and name.len < best.?) continue;
            best = name.len;
            dir = e.@"0";
            rest = std.mem.trimStart(u8, path[name.len..], "/");
        }
        if (best == null) return error.NotFound;
    }
    const s = set();
    const T = p3.filesystem_types;
    var params: T.descriptor_open_at.Params = .{
        .self = dir,
        .path_flags = .{ .symlink_follow = true },
        .path = .{ .ptr = @intFromPtr(rest.ptr), .len = @intCast(rest.len) },
        .open_flags = .{},
        .flags = .{ .read = true },
    };
    var opened: T.descriptor_open_at.Ret = undefined;
    if (!abi.call(s, T.descriptor_open_at.call(@intFromPtr(&params), @intFromPtr(&opened)))) return error.Io;
    if (opened.tag != 0) return error.NotFound;
    const file = opened.payload.ok;
    defer T.drop_descriptor(file);
    var pair: T.descriptor_read_via_stream.Ret = undefined;
    T.descriptor_read_via_stream.call(file, 0, @intFromPtr(&pair));
    const st = pair.@"0";
    const fut = pair.@"1";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    while (true) {
        try out.ensureUnusedCapacity(a, 16 << 10);
        const room = out.unusedCapacitySlice();
        const c = abi.finish(s, st, T.descriptor_read_via_stream.stream0.read(st, @intFromPtr(room.ptr), @intCast(room.len)));
        out.items.len += c.count;
        if (c.state != .completed) break;
    }
    T.descriptor_read_via_stream.stream0.drop_readable(st);
    var res: T.descriptor_read_via_stream.future1.Elem = undefined;
    _ = abi.finish(s, fut, T.descriptor_read_via_stream.future1.read(fut, @intFromPtr(&res)));
    T.descriptor_read_via_stream.future1.drop_readable(fut);
    if (res.tag != 0) return error.Io;
    return out.toOwnedSlice(a);
}

/// Ends the program with `code` after the rest of the output.
pub fn exit(code: u8) noreturn {
    flush();
    p3.cli_exit.exit_with_code.call(code);
    unreachable;
}

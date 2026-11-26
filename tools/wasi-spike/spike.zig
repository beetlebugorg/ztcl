//! The check of task 04 (docs/dev/wasi-tasks/04-async-abi.md): a core
//! module of WASI 0.3.2 with no preview 1 import. It makes a stream,
//! gives its readable end to `write-via-stream` of `wasi:cli/stdout`,
//! writes a text, and waits for the future of the result. The export
//! `run` has a synchronous lift. `zig build wasi-spike` makes the
//! component.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const async_abi = @import("async");

const stdout = struct {
    extern "wasi:cli/stdout@0.3.2" fn @"write-via-stream"(readable: u32) u32;
    extern "wasi:cli/stdout@0.3.2" fn @"[stream-new-0]write-via-stream"() u64;
    extern "wasi:cli/stdout@0.3.2" fn @"[async-lower][stream-write-0]write-via-stream"(w: u32, ptr: [*]const u8, len: u32) u32;
    extern "wasi:cli/stdout@0.3.2" fn @"[stream-drop-writable-0]write-via-stream"(w: u32) void;
    extern "wasi:cli/stdout@0.3.2" fn @"[async-lower][future-read-1]write-via-stream"(f: u32, ptr: [*]u8) u32;
    extern "wasi:cli/stdout@0.3.2" fn @"[future-drop-readable-1]write-via-stream"(f: u32) void;
};

const text = "ztcl: a WASI 0.3.2 stream\n";

/// Gives 0 for `ok` and 1 for `err` of the `result` of `run`.
fn run() callconv(.c) u32 {
    const set = async_abi.WaitSet.init();
    defer set.deinit();
    // `stream.new` gives the readable end in the low 32 bits.
    const pair = stdout.@"[stream-new-0]write-via-stream"();
    const r: u32 = @truncate(pair);
    const w: u32 = @truncate(pair >> 32);
    const fut = stdout.@"write-via-stream"(r);
    var done: usize = 0;
    while (done < text.len) {
        const rest = text[done..];
        const c = async_abi.finish(set, w, stdout.@"[async-lower][stream-write-0]write-via-stream"(w, rest.ptr, rest.len));
        done += c.count;
        if (c.state != .completed) break;
    }
    stdout.@"[stream-drop-writable-0]write-via-stream"(w);
    // The value of `result<_, error-code>`: the case byte, then the code.
    var res: [2]u8 align(4) = .{ 1, 0 };
    _ = async_abi.finish(set, fut, stdout.@"[async-lower][future-read-1]write-via-stream"(fut, &res));
    stdout.@"[future-drop-readable-1]write-via-stream"(fut);
    return if (done == text.len and res[0] == 0) 0 else 1;
}

/// The module has no memory allocator. No call of this check gives the
/// module a list or a string.
fn cabiRealloc(_: ?*anyopaque, _: usize, _: usize, _: usize) callconv(.c) ?*anyopaque {
    return null;
}

comptime {
    @export(&run, .{ .name = "wasi:cli/run@0.3.2#run" });
    @export(&cabiRealloc, .{ .name = "cabi_realloc" });
}

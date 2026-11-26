//! The check of task 04 with the async lift with a callback: the same
//! work as `spike.zig`, as a state machine. The task never blocks. Each
//! step gives the code `wait` with the waitable set, and the runtime
//! calls the callback with the next event. `zig build wasi-spike
//! -Dwasi-lift=callback` makes the component.
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
const run_export = struct {
    extern "[export]wasi:cli/run@0.3.2" fn @"[task-return]run"(is_err: u32) void;
};

/// The codes that a lift with a callback gives to the runtime.
const exit: u32 = 0;
const wait: u32 = 2;

const text = "ztcl: a WASI 0.3.2 stream (callback)\n";

var set: async_abi.WaitSet = undefined;
var w: u32 = 0;
var fut: u32 = 0;
var done: usize = 0;
var res: [2]u8 align(4) = .{ 1, 0 };

/// Writes the rest of the text. Gives `wait` when a copy did not end.
fn writeRest() u32 {
    while (done < text.len) {
        const rest = text[done..];
        const raw = stdout.@"[async-lower][stream-write-0]write-via-stream"(w, rest.ptr, rest.len);
        if (raw == async_abi.blocked) {
            set.join(w);
            return wait | (set.handle << 4);
        }
        const c = async_abi.Copy.of(raw);
        done += c.count;
        if (c.state != .completed) break;
    }
    return readResult();
}

/// Ends the stream and reads the future of the result.
fn readResult() u32 {
    stdout.@"[stream-drop-writable-0]write-via-stream"(w);
    const raw = stdout.@"[async-lower][future-read-1]write-via-stream"(fut, &res);
    if (raw == async_abi.blocked) {
        set.join(fut);
        return wait | (set.handle << 4);
    }
    return finish();
}

fn finish() u32 {
    stdout.@"[future-drop-readable-1]write-via-stream"(fut);
    run_export.@"[task-return]run"(if (done == text.len and res[0] == 0) 0 else 1);
    set.deinit();
    return exit;
}

fn start() callconv(.c) u32 {
    set = async_abi.WaitSet.init();
    const pair = stdout.@"[stream-new-0]write-via-stream"();
    fut = stdout.@"write-via-stream"(@truncate(pair));
    w = @truncate(pair >> 32);
    return writeRest();
}

fn callback(event: u32, waitable: u32, payload: u32) callconv(.c) u32 {
    async_abi.WaitSet.leave(waitable);
    const e: async_abi.Event = @fromBackingInt(@intCast(event));
    if (e == .stream_write and waitable == w) {
        const c = async_abi.Copy.of(payload);
        done += c.count;
        if (c.state != .completed) return readResult();
        return writeRest();
    }
    if (e == .future_read and waitable == fut) return finish();
    return wait | (set.handle << 4);
}

fn cabiRealloc(_: ?*anyopaque, _: usize, _: usize, _: usize) callconv(.c) ?*anyopaque {
    return null;
}

comptime {
    @export(&start, .{ .name = "[async-lift]wasi:cli/run@0.3.2#run" });
    @export(&callback, .{ .name = "[callback][async-lift]wasi:cli/run@0.3.2#run" });
    @export(&cabiRealloc, .{ .name = "cabi_realloc" });
}

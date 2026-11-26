//! The WebAssembly interface of ztcl: a small C ABI over `Interp`.
//!
//! The host calls `ztcl_alloc`, writes the script into the memory, and
//! calls `ztcl_eval`. See docs/embedding.md for an example.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl.zig");
const build_options = @import("build_options");
const thread = @import("thread.zig");

/// The thread model of this build: `none`, `shared`, or `async`. See
/// docs/webassembly.md.
const web_threads = if (@hasDecl(build_options, "web_threads")) build_options.web_threads else .none;
const shared = web_threads == .shared;

const gpa = if (shared) @import("webthread.zig").heap_allocator else std.heap.wasm_allocator;

const Handle = struct {
    it: ztcl.Interp,
    out: std.ArrayList(u8) = .empty,
    /// With threads, the output that `ztcl_output_take` moved out of
    /// `out`. Other threads add to `out` under the lock of the group.
    taken: std.ArrayList(u8) = .empty,
    result: []const u8 = "",
    /// The files of the bundle, for `ztcl_allow` with `file`.
    files: wasmfiles.State = .{},
};

const wasmbundle = @import("wasmbundle.zig");
const wasmfiles = @import("wasmfiles.zig");

/// The slot of a bundle. `ztcl build --wasm` writes the address and the
/// length of the payload into the last two words. See
/// src/wasmbundle.zig.
export var ztcl_bundle_slot: [4]u32 = wasmbundle.slot_words;

/// The payload of the bundle, or an empty slice.
fn payload() []const u8 {
    const slot: *volatile [4]u32 = &ztcl_bundle_slot;
    const ptr = slot[2];
    if (ptr == 0xffffffff) return &.{};
    return @as([*]const u8, @ptrFromInt(ptr))[0..slot[3]];
}

fn write(ctx: ?*anyopaque, bytes: []const u8) void {
    const h: *Handle = @ptrCast(@alignCast(ctx.?));
    h.out.appendSlice(gpa, bytes) catch {};
}

export fn ztcl_alloc(len: usize) ?[*]u8 {
    const s = gpa.alloc(u8, len) catch return null;
    return s.ptr;
}

export fn ztcl_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// Makes an interpreter with a memory limit of 2 GiB and no step limit.
export fn ztcl_new() ?*Handle {
    const h = gpa.create(Handle) catch return null;
    h.* = .{ .it = undefined };
    h.it.init(gpa) catch {
        gpa.destroy(h);
        return null;
    };
    h.it.output = .{ .ctx = h, .write = write };
    h.it.mem_limit = 2 << 30;
    return h;
}

export fn ztcl_delete(h: *Handle) void {
    h.files.deinit(gpa);
    h.out.deinit(gpa);
    h.taken.deinit(gpa);
    h.it.deinit();
    gpa.destroy(h);
}

/// Sets the steps that the next scripts can use.
export fn ztcl_set_step_limit(h: *Handle, step_limit: u64) void {
    h.it.step_limit = step_limit;
}

/// The steps that are left of the count of `ztcl_set_step_limit`.
export fn ztcl_steps_left(h: *Handle) u64 {
    return h.it.step_limit;
}

export fn ztcl_set_mem_limit(h: *Handle, bytes: usize) void {
    h.it.mem_limit = bytes;
}

/// Starts a collection at each Nth safe point. Zero turns the mode off.
/// A test uses it to find a missed root.
export fn ztcl_set_gc_stress(h: *Handle, n: u32) void {
    h.it.setGcStress(n);
}

/// Runs a script. Returns 0 on success and 1 on an error. The result
/// or the error message stays valid until the next call.
export fn ztcl_eval(h: *Handle, ptr: [*]const u8, len: usize) i32 {
    if (h.it.eval(ptr[0..len])) |v| {
        h.result = h.it.str(v) catch "out of memory";
        return 0;
    } else |e| {
        h.result = if (e == error.TclError) h.it.str(h.it.result) catch "out of memory" else @errorName(e);
        return 1;
    }
}

export fn ztcl_result_ptr(h: *Handle) [*]const u8 {
    return h.result.ptr;
}

export fn ztcl_result_len(h: *Handle) usize {
    return h.result.len;
}

export fn ztcl_output_ptr(h: *Handle) [*]const u8 {
    return if (web_threads == .none) h.out.items.ptr else h.taken.items.ptr;
}

export fn ztcl_output_len(h: *Handle) usize {
    return if (web_threads == .none) h.out.items.len else h.taken.items.len;
}

export fn ztcl_output_clear(h: *Handle) void {
    if (web_threads == .none) h.out.clearRetainingCapacity() else h.taken.clearRetainingCapacity();
}

// The exports of the build with no threads for a bundle. See
// web/ztcl.mjs.
comptime {
    if (web_threads == .none) {
        @export(&ztcl_bundle_size, .{ .name = "ztcl_bundle_size" });
        @export(&ztcl_bundle_run, .{ .name = "ztcl_bundle_run" });
        @export(&ztcl_allow_plain, .{ .name = "ztcl_allow" });
    }
}

/// The size of the payload of the bundle. Zero for a module with no
/// bundle.
fn ztcl_bundle_size() callconv(.c) usize {
    return payload().len;
}

/// Runs the scripts of the bundle in order, as `ztcl a.tcl b.tcl` runs
/// them. Returns 0 on success and 1 on an error. On an error, the
/// result is "name:line: message" and the next scripts do not run.
fn ztcl_bundle_run(h: *Handle) callconv(.c) i32 {
    var r: wasmbundle.Reader = .init(payload());
    h.result = "";
    while (r.next()) |e| {
        if (e.kind != .script) continue;
        h.it.error_line = 0;
        if (h.it.eval(e.data)) |v| {
            h.result = h.it.str(v) catch "out of memory";
        } else |err| {
            const msg = if (err == error.TclError) h.it.str(h.it.result) catch "out of memory" else @errorName(err);
            h.result = std.fmt.allocPrint(h.it.alloc(), "{s}:{d}: {s}", .{ e.name, h.it.error_line, msg }) catch msg;
            return 1;
        }
    }
    return 0;
}

fn filesOf(it: *ztcl.Interp) *wasmfiles.State {
    const h: *Handle = @fieldParentPtr("it", it);
    return &h.files;
}

/// Turns on capabilities. This build has only `file`: the commands
/// `source`, `open`, `read`, `gets`, `eof`, and `close` on the files of
/// the bundle. Gives 0 on success, 1 when the memory ends, and 2 for
/// another bit.
fn ztcl_allow_plain(h: *Handle, bits: u32) callconv(.c) i32 {
    const file = @backingInt(Capability.file);
    if (bits & ~file != 0) return 2;
    if (bits == 0 or h.files.on) return 0;
    h.files = .{ .payload = payload(), .on = true };
    wasmfiles.Commands(filesOf, gpa).register(&h.it) catch return 1;
    return 0;
}

// The exports of the builds with threads. See web/ztcl-threads.mjs.
comptime {
    if (web_threads != .none) {
        @export(&ztcl_output_take, .{ .name = "ztcl_output_take" });
        @export(&ztcl_set_thread_limits, .{ .name = "ztcl_set_thread_limits" });
        @export(&ztcl_allow, .{ .name = "ztcl_allow" });
    }
    if (web_threads == .async) {
        @export(&ztcl_web_init, .{ .name = "ztcl_web_init" });
        @export(&ztcl_web_waiting, .{ .name = "ztcl_web_waiting" });
        @export(&ztcl_web_recv, .{ .name = "ztcl_web_recv" });
        @export(&ztcl_web_msg_ptr, .{ .name = "ztcl_web_msg_ptr" });
        @export(&ztcl_web_msg_len, .{ .name = "ztcl_web_msg_len" });
        @export(&ztcl_web_reply, .{ .name = "ztcl_web_reply" });
        @export(&ztcl_web_gone, .{ .name = "ztcl_web_gone" });
    }
}

// The exports of ztcl-async.wasm for web/ztcl-thread-worker.mjs. See
// src/webasync.zig.
const webasync = if (web_threads == .async) @import("webasync.zig") else struct {};

/// Sets the thread id of the interpreter. `main` is 1 for the main
/// interpreter.
fn ztcl_web_init(_: *Handle, id: u32, main: u32) callconv(.c) void {
    webasync.init(id, main != 0);
}

/// 1 when the script of the thread ran `thread::wait`.
fn ztcl_web_waiting(_: *Handle) callconv(.c) i32 {
    return @intFromBool(webasync.waiting());
}

/// Runs a script of another thread. Gives the return code. The result
/// is at `ztcl_web_msg_ptr` in the byte form.
fn ztcl_web_recv(h: *Handle, from: u32, token: u32, ptr: [*]const u8, len: usize) callconv(.c) i32 {
    _ = from;
    return webasync.recv(&h.it, token, ptr[0..len]);
}

fn ztcl_web_msg_ptr(_: *Handle) callconv(.c) [*]const u8 {
    return webasync.msgBytes().ptr;
}

fn ztcl_web_msg_len(_: *Handle) callconv(.c) usize {
    return webasync.msgBytes().len;
}

/// A reply in the byte form to a token of this interpreter.
fn ztcl_web_reply(h: *Handle, token: u32, code: i32, ptr: [*]const u8, len: usize) callconv(.c) void {
    webasync.reply(&h.it, token, code, ptr[0..len]);
}

/// Thread `id` ended.
fn ztcl_web_gone(_: *Handle, id: u32) callconv(.c) void {
    webasync.gone(id);
}

/// Moves the output of all threads to the buffer of
/// `ztcl_output_ptr`. Call it before the read of the output.
fn ztcl_output_take(h: *Handle) callconv(.c) void {
    if (shared) if (thread.outLock(&h.it)) |l| {
        l.lock();
        defer l.unlock();
        return take(h);
    };
    take(h);
}

fn take(h: *Handle) void {
    h.taken.clearRetainingCapacity();
    std.mem.swap(std.ArrayList(u8), &h.out, &h.taken);
}

/// Sets the limits of the threads. Zero in a field keeps its default.
/// Call it before `ztcl_allow`.
fn ztcl_set_thread_limits(h: *Handle, max_threads: u32, step_limit: u64, mem_limit: usize, total_steps: u64, total_mem: usize, max_queue: usize) callconv(.c) void {
    var lim: thread.Limits = .{};
    if (max_threads != 0) lim.max_threads = max_threads;
    if (step_limit != 0) lim.step_limit = step_limit;
    if (mem_limit != 0) lim.mem_limit = mem_limit;
    if (total_steps != 0) lim.total_steps = total_steps;
    if (total_mem != 0) lim.total_mem = total_mem;
    if (max_queue != 0) lim.max_queue = max_queue;
    thread.setLimits(&h.it, lim);
}

const Capability = @import("interp.zig").Capability;

/// The capabilities that a build with threads can turn on.
const web_caps = if (shared)
    [_]Capability{ .thread, .event, .clock, .package, .interp }
else
    [_]Capability{ .thread, .clock, .package, .interp };

/// Turns on capabilities: a mask of the bits of `Capability`. The mask
/// can have only `thread`, `clock`, `package`, `interp`, and in the
/// build with one shared memory, `event`. Gives 0 on success, 1 when
/// the memory ends, and 2 for another bit.
fn ztcl_allow(h: *Handle, bits: u32) callconv(.c) i32 {
    var ok: u32 = 0;
    for (web_caps) |c| ok |= @backingInt(c);
    if (bits & ~ok != 0) return 2;
    if (shared) {
        const wt = @import("webthread.zig");
        h.it.clock_host = .{ .now = wt.nowMicros };
        h.it.event_host = .{ .now = wt.nowMicros, .sleep = wt.sleepMicros };
        h.it.allow(bits) catch return 1;
    } else {
        const t = @backingInt(Capability.thread);
        h.it.clock_host = .{ .now = webasync.nowMicros };
        h.it.allow(bits & ~t) catch return 1;
        if (bits & t != 0) webasync.register(&h.it) catch return 1;
    }
    return 0;
}

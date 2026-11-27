//! The async canonical ABI of the component model, as WASI 0.3 uses it
//! (docs/dev/wasi-tasks/04-async-abi.md). The core module imports the
//! built-ins with the legacy names of docs/dev/wasi.md ("The names of the
//! core module").
//!
//! The built-ins with no type are in the module `$root`, and this file
//! declares them. A built-in of a stream or a future has the name of the
//! function that has the type, so the bindings of each interface declare
//! it. They use the `[async-lower]` form of `stream-write`,
//! `stream-read`, `future-read`, and `future-write`: a copy that cannot
//! end at once gives `blocked`, and `wait` blocks the task until its
//! event. Wasmtime 50.0.0 rejects the synchronous form of `stream.write`
//! with no extra feature.
//!
//! SPDX-License-Identifier: BSD-2-Clause

/// The result of a copy that did not end at once.
pub const blocked: u32 = 0xffff_ffff;

/// The code of an event of `waitable-set.wait`.
pub const Event = enum(u32) {
    none = 0,
    subtask = 1,
    stream_read = 2,
    stream_write = 3,
    future_read = 4,
    future_write = 5,
    task_cancelled = 6,
    _,
};

/// The state of a copy, in the low 4 bits of its result.
pub const CopyState = enum(u4) {
    completed = 0,
    dropped = 1,
    cancelled = 2,
    _,
};

/// The result of a copy of a stream or a future.
pub const Copy = struct {
    state: CopyState,
    /// The count of elements that the copy moved.
    count: u32,

    pub fn of(raw: u32) Copy {
        return .{ .state = @fromBackingInt(@intCast(@as(u4, @truncate(raw)))), .count = raw >> 4 };
    }
};

const root = struct {
    extern "$root" fn @"[waitable-set-new]"() u32;
    extern "$root" fn @"[waitable-set-wait]"(set: u32, out: *[2]u32) u32;
    extern "$root" fn @"[waitable-set-drop]"(set: u32) void;
    extern "$root" fn @"[waitable-join]"(waitable: u32, set: u32) void;
};

/// A set of waitables. The task waits on the set for the next event of
/// one of its members.
pub const WaitSet = struct {
    handle: u32,

    pub fn init() WaitSet {
        return .{ .handle = root.@"[waitable-set-new]"() };
    }

    pub fn deinit(s: WaitSet) void {
        root.@"[waitable-set-drop]"(s.handle);
    }

    pub fn join(s: WaitSet, waitable: u32) void {
        root.@"[waitable-join]"(waitable, s.handle);
    }

    /// Takes `waitable` out of its set.
    pub fn leave(waitable: u32) void {
        root.@"[waitable-join]"(waitable, 0);
    }

    /// Blocks the task until the next event. Gives the event, the
    /// waitable, and the payload.
    pub fn wait(s: WaitSet) struct { event: Event, waitable: u32, payload: u32 } {
        var out: [2]u32 = .{ 0, 0 };
        const code = root.@"[waitable-set-wait]"(s.handle, &out);
        return .{ .event = @fromBackingInt(@intCast(code)), .waitable = out[0], .payload = out[1] };
    }
};

/// The result of a copy of `waitable` that gave `raw`. If the copy did
/// not end at once, the task waits in `set` for its event.
pub fn finish(set: WaitSet, waitable: u32, raw: u32) Copy {
    if (raw != blocked) return Copy.of(raw);
    set.join(waitable);
    defer WaitSet.leave(waitable);
    while (true) {
        const e = set.wait();
        if (e.waitable == waitable) return Copy.of(e.payload);
    }
}

/// The state of a subtask, in the low 4 bits of the status of an
/// `[async-lower]` call and in the payload of its `subtask` event.
pub const SubtaskState = enum(u4) {
    starting = 0,
    started = 1,
    returned = 2,
    cancelled_before_started = 3,
    cancelled_before_returned = 4,
    _,
};

const subtask_abi = struct {
    extern "$root" fn @"[subtask-drop]"(subtask: u32) void;
};

/// Waits for the end of an `[async-lower]` call that gave `status`. The
/// callee has then written its result to the return area. Gives false
/// for a call that was cancelled.
pub fn call(set: WaitSet, status: u32) bool {
    var state: SubtaskState = @fromBackingInt(@as(u4, @truncate(status)));
    const sub = status >> 4;
    if (sub == 0) return state == .returned;
    set.join(sub);
    while (state == .starting or state == .started) {
        const e = set.wait();
        if (e.event == .subtask and e.waitable == sub) state = @fromBackingInt(@as(u4, @truncate(e.payload)));
    }
    WaitSet.leave(sub);
    subtask_abi.@"[subtask-drop]"(sub);
    return state == .returned;
}

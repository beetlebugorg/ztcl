//! The waits of the capability `thread` in the ztcl unikernel
//! (ztcl#471). The guest has one CPU and one interpreter, and no other
//! thread can change a futex word. So a wait of `thread.zig` runs
//! `pump`: the child of `isothread.zig` reads one frame of the host, or
//! sleeps until the next interrupt when no frame waits. The caller of a
//! wait checks its condition again after each return, as after the end
//! of a wait slice on a host.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const cpu = @import("cpu.zig");

pub var pump: ?*const fn () void = null;
/// Runs the frames that wait, with no sleep.
pub var poll_fn: ?*const fn () void = null;
/// True when a frame of the host waits.
pub var ready_fn: ?*const fn () bool = null;

pub fn ready() bool {
    return if (ready_fn) |f| f() else false;
}
/// The rate of the time stamp counter in kHz, from the command line of
/// the monitor (`ztcl.tsc_khz=`).
pub var tsc_khz: u64 = 0;

/// Waits for a frame of the host, at most `ns` nanoseconds: the TSC
/// deadline timer ends the sleep of the pump.
pub fn wait(ns: u64) void {
    if (tsc_khz != 0 and ns < std.math.maxInt(u64) / tsc_khz) _ = cpu.timerAt(cpu.rdtsc() + ns * tsc_khz / 1_000_000);
    if (pump) |p| p() else cpu.stiHlt();
}

pub fn poll() void {
    if (poll_fn) |p| p();
}

/// Nanoseconds since the start of the guest, from the time stamp
/// counter.
pub fn nowNs() i96 {
    if (tsc_khz == 0) return 0;
    return @intCast(@as(u128, cpu.rdtsc()) * 1_000_000 / tsc_khz);
}

/// A thread of the system: the guest has none, so each spawn fails.
pub const Thread = struct {
    pub const SpawnConfig = struct { stack_size: usize = 0, allocator: ?std.mem.Allocator = null };
    pub fn spawn(_: SpawnConfig, comptime f: anytype, args: anytype) error{SystemResources}!Thread {
        _ = f;
        _ = args;
        return error.SystemResources;
    }
    pub fn join(_: Thread) void {}
    pub fn detach(_: Thread) void {}
};

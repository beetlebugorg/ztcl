//! The clock and the event loop of the ztcl unikernel (ztcl#471), for
//! the capabilities `clock` and `event` that the parent gives.
//!
//! The time comes from the time stamp counter. The monitor gives the
//! rate of the counter and one pair of the time of the host and the
//! counter at that time on the command line (`ztcl.tsc_khz=` and
//! `ztcl.epoch=MICROS@TSC`), so the guest needs no clock device. A
//! sleep of the event loop halts the CPU until the TSC deadline timer of
//! the local APIC or a frame of the host, and runs that frame.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const uk = @import("uk.zig");
const cpu = @import("cpu.zig");
const wait = @import("wait.zig");

var epoch_us: i64 = 0;
var epoch_tsc: u64 = 0;

pub fn init() void {
    const e = uk.param("ztcl.epoch") orelse return;
    const at = std.mem.indexOfScalar(u8, e, '@') orelse return;
    epoch_us = std.fmt.parseInt(i64, e[0..at], 10) catch return;
    epoch_tsc = std.fmt.parseInt(u64, e[at + 1 ..], 10) catch return;
}

fn sinceUs(tsc: u64) i64 {
    if (wait.tsc_khz == 0) return 0;
    const d: i128 = @as(i128, cpu.rdtsc()) - tsc;
    return @intCast(@divTrunc(d * 1000, wait.tsc_khz));
}

fn wallNow(_: ?*anyopaque) i64 {
    return epoch_us + sinceUs(epoch_tsc);
}

fn monoNow(_: ?*anyopaque) i64 {
    return sinceUs(0);
}

fn sleep(_: ?*anyopaque, micros: i64) void {
    // A frame of the host ends the sleep, so the loop can run a send
    // that came.
    const end = monoNow(null) + micros;
    const deadline = cpu.rdtsc() + @as(u64, @intCast(@max(micros, 0))) * wait.tsc_khz / 1000;
    while (monoNow(null) < end) {
        if (wait.ready()) return wait.poll();
        if (!cpu.timerAt(deadline)) {
            std.atomic.spinLoopHint();
            continue;
        }
        cpu.cli();
        if (wait.ready() or cpu.timerDue()) {
            cpu.sti();
            continue;
        }
        cpu.stiHlt();
    }
}

pub const clock: @import("../clock.zig").Host = .{ .now = wallNow };
pub const event: @import("../event.zig").Host = .{ .now = monoNow, .sleep = sleep };

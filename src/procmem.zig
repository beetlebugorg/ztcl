//! The memory of the process that the system counts: the resident set
//! (the pages in RAM now) and its peak, for `ztcl::gc stats`. The heap
//! counts its own bytes; these counts also show the memory that a heap
//! freed and the system still holds, and the memory of the rest of the
//! process.
//!
//! - Windows: `K32GetProcessMemoryInfo`, the working set and its peak.
//! - Linux: `VmRSS` and `VmHWM` of `/proc/self/status`.
//! - macOS: `task_info` with `MACH_TASK_BASIC_INFO`, the resident size
//!   and its peak.
//!
//! Another target gives 0 for each count.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");

pub const Counts = struct { rss: u64 = 0, peak: u64 = 0 };

/// The resident set of the process and its peak, in bytes, or zeros.
pub fn counts() Counts {
    return switch (builtin.os.tag) {
        .windows => windows(),
        .linux => linux(),
        .macos => macos(),
        else => .{},
    };
}

const ProcessMemoryCounters = extern struct {
    cb: u32,
    page_fault_count: u32,
    peak_working_set_size: usize,
    working_set_size: usize,
    quota_peak_paged_pool_usage: usize,
    quota_paged_pool_usage: usize,
    quota_peak_non_paged_pool_usage: usize,
    quota_non_paged_pool_usage: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
};

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn K32GetProcessMemoryInfo(process: *anyopaque, out: *ProcessMemoryCounters, size: u32) callconv(.winapi) i32;

fn windows() Counts {
    var c: ProcessMemoryCounters = std.mem.zeroes(ProcessMemoryCounters);
    c.cb = @sizeOf(ProcessMemoryCounters);
    if (K32GetProcessMemoryInfo(GetCurrentProcess(), &c, c.cb) == 0) return .{};
    return .{ .rss = c.working_set_size, .peak = c.peak_working_set_size };
}

fn linux() Counts {
    const l = std.os.linux;
    const fd = l.open("/proc/self/status", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (l.errno(fd) != .SUCCESS) return .{};
    defer _ = l.close(@intCast(fd));
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const r = l.read(@intCast(fd), buf[n..].ptr, buf.len - n);
        if (l.errno(r) != .SUCCESS or r == 0) break;
        n += r;
    }
    return parseStatus(buf[0..n]);
}

/// The counts of the text of `/proc/self/status`: the lines `VmRSS:` and
/// `VmHWM:`, in kB.
pub fn parseStatus(text: []const u8) Counts {
    var out: Counts = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const field: *u64 = if (std.mem.startsWith(u8, line, "VmRSS:")) &out.rss else if (std.mem.startsWith(u8, line, "VmHWM:")) &out.peak else continue;
        var words = std.mem.tokenizeAny(u8, line[6..], " \t");
        const kb = std.fmt.parseInt(u64, words.next() orelse continue, 10) catch continue;
        field.* = kb * 1024;
    }
    return out;
}

/// `struct mach_task_basic_info` of `<mach/task_info.h>`: 48 bytes, 12
/// words of 4 bytes for its count. The struct of the standard library
/// of Zig has no `resident_size_max`.
const MachTaskBasicInfo = extern struct {
    virtual_size: u64,
    resident_size: u64,
    resident_size_max: u64,
    user_time: [2]i32,
    system_time: [2]i32,
    policy: i32,
    suspend_count: i32,
};

fn macos() Counts {
    if (comptime builtin.os.tag != .macos) return .{};
    const c = std.c;
    var info: MachTaskBasicInfo = undefined;
    var count: c.mach_msg_type_number_t = @sizeOf(MachTaskBasicInfo) / 4;
    if (c.task_info(c.mach_task_self(), c.MACH.TASK.BASIC.INFO, @ptrCast(&info), &count) != 0) return .{};
    return .{ .rss = info.resident_size, .peak = info.resident_size_max };
}

comptime {
    std.debug.assert(@sizeOf(MachTaskBasicInfo) == 48);
}

test "procmem: the counts of /proc/self/status" {
    const c = parseStatus("Name:\tztcl\nVmHWM:\t  2048 kB\nVmRSS:\t   1024 kB\nThreads:\t1\n");
    try std.testing.expectEqual(@as(u64, 1024 * 1024), c.rss);
    try std.testing.expectEqual(@as(u64, 2048 * 1024), c.peak);
}

test "procmem: this process has a resident set" {
    const c = counts();
    if (builtin.os.tag != .windows and builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expect(c.rss > 0);
    try std.testing.expect(c.peak >= c.rss);
}

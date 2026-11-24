//! Tests of the JIT: the state, the executable memory, the assembler,
//! the layout probe, the verifier, and the compiled code.
//!
//! A test of compiled code runs a script two times, in the interpreter
//! and with the JIT at threshold 0, and compares the result, the error
//! text, `errorInfo`, and the steps used.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("../ztcl.zig");
const jit = @import("../jit.zig");

const Interp = tcl.Interp;
const testing = std.testing;

fn newInterp() !*Interp {
    const it = try testing.allocator.create(Interp);
    errdefer testing.allocator.destroy(it);
    try it.init(testing.allocator);
    return it;
}

fn freeInterp(it: *Interp) void {
    it.deinit();
    testing.allocator.destroy(it);
}

test "the default interpreter has no JIT state" {
    const it = try newInterp();
    defer freeInterp(it);
    try testing.expect(it.jit == null);
    _ = try it.eval("proc f {x} {expr {$x + 1}}; f 1; f 2");
    try testing.expect(it.jit == null);
}

test "enableJit follows the build, and reset keeps the state" {
    const it = try newInterp();
    defer freeInterp(it);
    const on = it.enableJit(.{});
    try testing.expectEqual(jit.built, on);
    if (!on) {
        try testing.expect(it.jit == null);
        return;
    }
    const s = it.jit.?;
    try it.reset();
    try testing.expectEqual(s, it.jit.?);
    const v = try it.eval("proc f {x} {expr {$x + 1}}; f 41");
    try testing.expectEqual(@as(i64, 42), v.asInt().?);
}

test "a child has the JIT only when its parent has it" {
    for ([_]bool{ false, true }) |want| {
        const it = try newInterp();
        defer freeInterp(it);
        try it.allow(@intFromEnum(tcl.interp.Capability.interp));
        if (want and !it.enableJit(.{})) return error.SkipZigTest;
        _ = try it.eval("interp create c");
        const c = it.children.get("c").?;
        try testing.expectEqual(want, c.it.jit != null);
        const v = try it.eval("c eval {proc f {} {return 7}; f}");
        try testing.expectEqualStrings("7", try it.str(v));
    }
}

test "compact works with the JIT on" {
    const it = try newInterp();
    defer freeInterp(it);
    if (!it.enableJit(.{ .threshold = 0 })) return error.SkipZigTest;
    _ = try it.eval("proc f {n} {set s 0; for {set i 0} {$i < $n} {incr i} {incr s $i}; return $s}; f 10");
    try it.compact(&.{}, .{});
    const v = try it.eval("f 100");
    try testing.expectEqual(@as(i64, 4950), v.asInt().?);
}

test "memUsed is equal with the JIT on and off" {
    const script =
        \\proc f {n} {set l {}; for {set i 0} {$i < $n} {incr i} {lappend l [expr {$i * 2}]}; return [llength $l]}
        \\f 1000; f 1000
    ;
    var used: [2]usize = undefined;
    for (0..2) |k| {
        const it = try newInterp();
        defer freeInterp(it);
        it.gc_on = false;
        if (k == 1) _ = it.enableJit(.{ .threshold = 0 });
        _ = try it.eval(script);
        used[k] = it.memUsed();
    }
    try testing.expectEqual(used[0], used[1]);
}

// ---- Executable memory ----

const mem = @import("mem.zig");
const linux = std.os.linux;

/// The text of /proc/self/maps.
fn readMaps(a: std.mem.Allocator) ![]u8 {
    const rc = linux.open("/proc/self/maps", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.NoMaps;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.NoMaps;
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

/// Checks each line of the maps text: no line is writable and
/// executable, and each part of the region has the expected rights.
fn checkMaps(text: []const u8, r: *const mem.Region) !void {
    const lo = @intFromPtr(r.base) - r.page;
    const hi = @intFromPtr(r.base) + r.limit + r.page;
    const used_hi = @intFromPtr(r.base) + r.used;
    var seen: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const range = f.next() orelse continue;
        const perms = f.next() orelse continue;
        try testing.expect(!(perms[1] == 'w' and perms[2] == 'x'));
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const start = try std.fmt.parseInt(usize, range[0..dash], 16);
        const end = try std.fmt.parseInt(usize, range[dash + 1 ..], 16);
        if (end <= lo or start >= hi) continue;
        const s = @max(start, lo);
        const e = @min(end, hi);
        seen += e - s;
        if (s >= @intFromPtr(r.base) and e <= used_hi) {
            try testing.expectEqualStrings("r-xp", perms);
        } else {
            // A part outside the used pages has no access.
            try testing.expect(e <= @intFromPtr(r.base) or s >= used_hi);
            try testing.expectEqualStrings("---p", perms);
        }
    }
    try testing.expectEqual(hi - lo, seen);
}

test "selfTest runs a function from the region" {
    if (!jit.built) return error.SkipZigTest;
    try testing.expect(mem.selfTest());
}

test "the region has no page that is writable and executable" {
    if (!jit.built) return error.SkipZigTest;
    const page = std.heap.pageSize();
    var r = mem.Region.init(8 * page) orelse return error.NoRegion;
    defer r.deinit();
    const ret42 = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    const ret7 = [_]u8{ 0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3 };
    const f1 = r.append(&ret42).?;
    var big: [5000]u8 = undefined;
    @memset(&big, 0x90);
    @memcpy(big[big.len - ret7.len ..], &ret7);
    const f2 = r.append(&big).?;
    try testing.expectEqual(3 * page, r.usedBytes());
    const text = try readMaps(testing.allocator);
    defer testing.allocator.free(text);
    try checkMaps(text, &r);
    // The rest of the last page of each function is `int3`.
    for (f1.ptr[f1.len..page]) |b| try testing.expectEqual(mem.trap_byte, b);
    for (f2.ptr[f2.len .. 2 * page]) |b| try testing.expectEqual(mem.trap_byte, b);
    const c1: *const fn () callconv(.c) u32 = @ptrCast(f1.ptr);
    const c2: *const fn () callconv(.c) u32 = @ptrCast(f2.ptr);
    try testing.expectEqual(@as(u32, 42), c1());
    try testing.expectEqual(@as(u32, 7), c2());
}

test "a full region returns null and keeps its functions" {
    if (!jit.built) return error.SkipZigTest;
    const page = std.heap.pageSize();
    var r = mem.Region.init(2 * page) orelse return error.NoRegion;
    defer r.deinit();
    const ret42 = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    const f1 = r.append(&ret42).?;
    var big: [5000]u8 = undefined;
    @memset(&big, 0x90);
    try testing.expect(r.append(&big) == null);
    _ = r.append(&ret42).?;
    try testing.expect(r.append(&ret42) == null);
    const c1: *const fn () callconv(.c) u32 = @ptrCast(f1.ptr);
    try testing.expectEqual(@as(u32, 42), c1());
}

test "selfTest is false under PR_SET_MDWE" {
    if (!jit.built) return error.SkipZigTest;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.SkipZigTest;
    if (pid == 0) {
        // PR_SET_MDWE is 65, PR_MDWE_REFUSE_EXEC_GAIN is 1.
        const rc = linux.prctl(65, 1, 0, 0, 0);
        if (linux.errno(rc) != .SUCCESS) linux.exit_group(77);
        linux.exit_group(if (mem.selfTest()) 1 else 0);
    }
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    // A crash gives a signal status, which is not an exit code.
    try testing.expect(linux.W.IFEXITED(status));
    const code = linux.W.EXITSTATUS(status);
    if (code == 77) return error.SkipZigTest;
    try testing.expectEqual(@as(u32, 0), code);
}

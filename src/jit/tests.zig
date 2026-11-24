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
const builtin = @import("builtin");

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

test "the JIT data of a child is outside the memory count" {
    if (!jit.built) return error.SkipZigTest;
    const script =
        \\interp create c
        \\c eval {proc f {n} {set s 0; for {set i 0} {$i < $n} {incr i} {incr s $i}; return $s}; f 10}
        \\for {set k 0} {$k < 40} {incr k} { c eval [list proc g$k {} [list return $k]]; c eval g$k }
        \\interp delete c
    ;
    var peak: [2]usize = undefined;
    var used: [2]usize = undefined;
    for (0..2) |k| {
        const it = try newInterp();
        defer freeInterp(it);
        it.gc_on = false;
        try it.allow(@intFromEnum(tcl.interp.Capability.interp));
        if (k == 1 and !it.enableJit(.{ .threshold = 0 })) return error.SkipZigTest;
        _ = try it.eval(script);
        used[k] = it.memUsed();
        peak[k] = it.counter.mem_peak;
    }
    try testing.expectEqual(used[0], used[1]);
    try testing.expectEqual(peak[0], peak[1]);
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

/// Reads one byte at `addr` in a child process. True when the read
/// ends the child with SIGSEGV.
fn readFaults(addr: usize) !bool {
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.SkipZigTest;
    if (pid == 0) {
        // The test runner has a handler for SIGSEGV. The child needs the
        // default action, so the status shows the signal.
        const dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
        _ = linux.sigaction(.SEGV, &dfl, null);
        const p: *volatile u8 = @ptrFromInt(addr);
        const b = p.*;
        linux.exit_group(@as(i32, b) & 1);
    }
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    return linux.W.IFSIGNALED(status) and linux.W.TERMSIG(status) == .SEGV;
}

test "a read of a guard page of the region faults" {
    if (!jit.built) return error.SkipZigTest;
    const page = std.heap.pageSize();
    var r = mem.Region.init(4 * page) orelse return error.NoRegion;
    defer r.deinit();
    const ret42 = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    const f = r.append(&ret42).?;
    const base = @intFromPtr(r.base);
    // The page before the region, a page after the used part, and the
    // page after the region.
    try testing.expect(try readFaults(base - page));
    try testing.expect(try readFaults(base + page));
    try testing.expect(try readFaults(base + r.limit));
    // The code and its fill bytes are readable.
    try testing.expect(!try readFaults(@intFromPtr(f.ptr) + page - 1));
}

// ---- The assembler ----

const x64 = @import("x64.zig");

test "the assembler gives the bytes of zig cc for each golden row" {
    const rows = @import("x64_golden.zig").rows;
    var bad: usize = 0;
    for (rows) |row| {
        var s = x64.Asm.init(testing.allocator);
        defer s.deinit();
        try x64.encodeRow(&s, row);
        try s.finish();
        if (!std.mem.eql(u8, row.bytes, s.bytes())) {
            if (bad < 20) std.debug.print("{t} a={d} b={d} d={d} i={d} k={d}: want {x} got {x}\n", .{ row.f, row.a, row.b, row.d, row.i, row.k, row.bytes, s.bytes() });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
    try testing.expect(rows.len > 8000);
}

test "a forward and a backward branch get the correct rel32" {
    var s = x64.Asm.init(testing.allocator);
    defer s.deinit();
    const back = try s.newLabel();
    const fwd = try s.newLabel();
    s.bind(back);
    try s.nop();
    try s.jcc(.ne, fwd); // at 1: 0f 85 rel32, ends at 7
    try s.jmp(back); // at 7: e9 rel32, ends at 12
    try s.nop();
    s.bind(fwd); // at 13
    try s.jmp(fwd); // at 13: ends at 18
    try s.finish();
    const b = s.bytes();
    try testing.expectEqual(@as(i32, 13 - 7), std.mem.readInt(i32, b[3..7], .little));
    try testing.expectEqual(@as(i32, 0 - 12), std.mem.readInt(i32, b[8..12], .little));
    try testing.expectEqual(@as(i32, 13 - 18), std.mem.readInt(i32, b[14..18], .little));
}

test "an unbound label is an error" {
    var s = x64.Asm.init(testing.allocator);
    defer s.deinit();
    const l = try s.newLabel();
    try s.jmp(l);
    try testing.expectError(error.UnboundLabel, s.finish());
    // A label that no branch uses is not an error.
    var t = x64.Asm.init(testing.allocator);
    defer t.deinit();
    _ = try t.newLabel();
    try t.finish();
}

test "a displacement out of range is an error" {
    try testing.expectError(error.Range, x64.at(.rax, 1 << 31));
    try testing.expectError(error.Range, x64.at(.rax, -(1 << 31) - 1));
    try testing.expectError(error.Range, x64.imm32(1 << 40));
    _ = try x64.at(.rax, -(1 << 31));
}

test "the selfTest function from the assembler returns 42" {
    if (!jit.built) return error.SkipZigTest;
    var s = x64.Asm.init(testing.allocator);
    defer s.deinit();
    try s.movRI32(.rax, 42);
    try s.ret();
    try s.finish();
    try testing.expect(mem.runConst(s.bytes(), 42));
}

test "checkError reads only eax after a helper call" {
    if (!jit.built) return error.SkipZigTest;
    const t1 = @import("tier1_x64.zig");
    var s = x64.Asm.init(testing.allocator);
    defer s.deinit();
    var stubs = [_]?x64.Label{null};
    var e: t1.Emitter = .{ .s = &s, .code = undefined, .info = undefined, .l = undefined, .labels = &.{}, .stubs = &stubs, .epilogue = try s.newLabel(), .a = testing.allocator, .slows = &.{} };
    // rax = 0xFFFFFFFF_00000001: result 1 with a high half that a u32
    // return value leaves undefined.
    try s.movRI32(.rax, -1);
    try s.neg(.rax);
    try e.checkError(0);
    try s.movRI32(.rax, 42);
    try s.ret();
    s.bind(stubs[0].?);
    try s.movRI32(.rax, 7);
    try s.ret();
    try s.finish();
    try testing.expect(mem.runConst(s.bytes(), 42));
}

// ---- The AArch64 assembler ----

const a64 = @import("a64.zig");

test "a64: the assembler gives the words of zig cc for each golden row" {
    const rows = @import("a64_golden.zig").rows;
    var bad: usize = 0;
    for (rows) |row| {
        var s = a64.Asm.init(testing.allocator);
        defer s.deinit();
        try a64.encodeRow(&s, row);
        try s.finish();
        if (!std.mem.eql(u8, row.bytes, s.bytes())) {
            if (bad < 20) std.debug.print("{t} a={d} b={d} c={d} i={d} j={d} k={d}: want {x} got {x}\n", .{ row.f, row.a, row.b, row.c, row.i, row.j, row.k, row.bytes, s.bytes() });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
    try testing.expect(rows.len > 3000);
}

test "a64: x18 is an error in each register place" {
    var s = a64.Asm.init(testing.allocator);
    defer s.deinit();
    try testing.expectError(error.Reg, s.movRR(.x18, .x1));
    try testing.expectError(error.Reg, s.movRR(.x1, .x18));
    try testing.expectError(error.Reg, s.load(.x, .{ .r = .x18 }, .x1, 8));
    try testing.expectError(error.Reg, s.load(.x, .{ .r = .x1 }, .x18, 8));
    try testing.expectError(error.Reg, s.ldrR(.x, .{ .r = .x1 }, .x2, .x18));
    try testing.expectError(error.Reg, s.stpPre(.x18, .x1, .sp, -16));
    try testing.expectError(error.Reg, s.opR(.add, .x1, .x2, .x18, .lsl, 0));
    try testing.expectError(error.Reg, s.addI(.x1, .x18, 1, false));
    try testing.expectError(error.Reg, s.blr(.x18));
    try testing.expectError(error.Reg, s.fmovDX(.d0, .x18));
    // sp and the zero register only where the form can encode them.
    try testing.expectError(error.Reg, s.opR(.add, .sp, .x1, .x2, .lsl, 0));
    try testing.expectError(error.Reg, s.load(.x, .{ .r = .x1 }, .zr, 0));
    try testing.expectError(error.Reg, s.mul(.x1, .sp, .x2));
    try testing.expectEqual(@as(usize, 0), s.bytes().len);
}

test "a64: a value that does not fit its field is an error" {
    var s = a64.Asm.init(testing.allocator);
    defer s.deinit();
    try testing.expectError(error.Range, s.ldrU(.x, .{ .r = .x0 }, .x1, 4));
    try testing.expectError(error.Range, s.ldrU(.x, .{ .r = .x0 }, .x1, 8 * 4096));
    try testing.expectError(error.Range, s.ldrU(.w, .{ .r = .x0 }, .x1, -4));
    try testing.expectError(error.Range, s.ldur(.x, .{ .r = .x0 }, .x1, 256));
    try testing.expectError(error.Range, s.ldur(.x, .{ .r = .x0 }, .x1, -257));
    try testing.expectError(error.Range, s.movz(.x0, 65536, 0));
    try testing.expectError(error.Range, s.movz(.x0, -1, 0));
    try testing.expectError(error.Range, s.movk(.x0, 1, 8));
    try testing.expectError(error.Range, s.addI(.x0, .x1, 4096, false));
    try testing.expectError(error.Range, s.cmpI(.x0, -1));
    try testing.expectError(error.Range, s.stpPre(.x29, .x30, .sp, -520));
    try testing.expectError(error.Range, s.stpPre(.x29, .x30, .sp, -12));
    try testing.expectError(error.Range, s.lslI(.x0, .x1, 0));
    try testing.expectError(error.Range, s.asrI(.x0, .x1, 64));
    try testing.expectError(error.Range, s.opR(.add, .x0, .x1, .x2, .lsl, 64));
    try testing.expectError(error.Range, s.andI(.x0, .x1, 0x5));
    try testing.expectError(error.Range, s.tstI(.x0, 0));
    try testing.expectError(error.Range, s.brk(65536));
    try testing.expectEqual(@as(usize, 0), s.bytes().len);
}

test "a64: branches get their offsets, and a b.cond reaches 1 MiB" {
    var s = a64.Asm.init(testing.allocator);
    defer s.deinit();
    const back = try s.newLabel();
    const fwd = try s.newLabel();
    s.bind(back);
    try s.nop(); // 0
    try s.bcond(.ne, fwd); // 4
    try s.b(back); // 8
    try s.cbz(.x3, back); // 12
    try s.nop(); // 16
    s.bind(fwd); // 20
    try s.cbnzW(.x0, fwd); // 20
    try s.finish();
    const w = s.bytes();
    const word = struct {
        fn at(bs: []const u8, k: usize) u32 {
            return std.mem.readInt(u32, bs[k..][0..4], .little);
        }
    }.at;
    try testing.expectEqual(@as(u32, 0x54000000 | 4 << 5 | 1), word(w, 4));
    try testing.expectEqual(@as(u32, 0x14000000 | (0x4000000 - 2)), word(w, 8));
    try testing.expectEqual(@as(u32, 0xB4000000 | (0x80000 - 3) << 5 | 3), word(w, 12));
    try testing.expectEqual(@as(u32, 0x35000000), word(w, 20));

    // The last reach of a b.cond is 1 MiB minus one word ahead.
    var t = a64.Asm.init(testing.allocator);
    defer t.deinit();
    const far = try t.newLabel();
    try t.bcond(.eq, far);
    for (0..(1 << 18) - 2) |_| try t.nop();
    t.bind(far);
    try t.finish();
    var u = a64.Asm.init(testing.allocator);
    defer u.deinit();
    const too_far = try u.newLabel();
    try u.bcond(.eq, too_far);
    for (0..(1 << 18) - 1) |_| try u.nop();
    u.bind(too_far);
    try testing.expectError(error.Range, u.finish());
    // A b reaches further.
    var v = a64.Asm.init(testing.allocator);
    defer v.deinit();
    const l = try v.newLabel();
    try v.b(l);
    for (0..1 << 18) |_| try v.nop();
    v.bind(l);
    try v.finish();
}

test "a64: an unbound label is an error" {
    var s = a64.Asm.init(testing.allocator);
    defer s.deinit();
    const l = try s.newLabel();
    try s.cbz(.x0, l);
    try testing.expectError(error.UnboundLabel, s.finish());
}

test "a64: a large offset uses x16, or x17 with the base x16" {
    var s = a64.Asm.init(testing.allocator);
    defer s.deinit();
    try s.load(.x, .{ .r = .x0 }, .x1, 8 * 4096);
    try s.load(.b, .{ .r = .x0 }, .x16, -300);
    try s.store(.d, .{ .d = .d3 }, .x2, 1 << 20);
    var t = a64.Asm.init(testing.allocator);
    defer t.deinit();
    try t.movz(.x16, 8 * 4096, 0);
    try t.ldrR(.x, .{ .r = .x0 }, .x1, .x16);
    try t.movn(.x17, 299, 0);
    try t.ldrR(.b, .{ .r = .x0 }, .x16, .x17);
    try t.movz(.x16, 16, 16);
    try t.strR(.d, .{ .d = .d3 }, .x2, .x16);
    try testing.expectEqualSlices(u8, t.bytes(), s.bytes());
    // The short forms when they fit.
    var u = a64.Asm.init(testing.allocator);
    defer u.deinit();
    try u.load(.x, .{ .r = .x0 }, .x1, 8 * 4095);
    try u.load(.x, .{ .r = .x0 }, .x1, -8);
    try u.load(.w, .{ .r = .x0 }, .x1, 6);
    try testing.expectEqual(@as(usize, 12), u.bytes().len);
    // A store from the temporary register is an error.
    try testing.expectError(error.Reg, u.store(.x, .{ .r = .x16 }, .x1, 1 << 20));
}

/// Runs code that returns a 64-bit value, on arm64 with executable memory.
fn runA64(code: []const u8) ?u64 {
    if (builtin.cpu.arch != .aarch64) return null;
    var r = mem.Region.init(std.heap.pageSize()) orelse return null;
    defer r.deinit();
    const f = r.append(code) orelse return null;
    const func: *const fn () callconv(.c) u64 = @ptrCast(@alignCast(f.ptr));
    return func();
}

test "a64: movImm and addImm give each value" {
    if (builtin.cpu.arch != .aarch64 or !mem.selfTest()) return error.SkipZigTest;
    const vals = [_]i64{ 0, 1, -1, 42, 0xFFFF, 0x10000, -0x10000, 0x12345678, -0x12345678, std.math.maxInt(i64), std.math.minInt(i64), 0x0000FFFF00000000, -4096, 4095, 4096, 0x123000, -0x123000, 0x1001 };
    for (vals) |v| {
        var s = a64.Asm.init(testing.allocator);
        defer s.deinit();
        try s.movImm(.x0, v);
        try s.ret();
        try testing.expectEqual(@as(u64, @bitCast(v)), runA64(s.bytes()).?);
        var t = a64.Asm.init(testing.allocator);
        defer t.deinit();
        try t.movz(.x1, 1000, 0);
        try t.addImm(.x0, .x1, v);
        try t.ret();
        try testing.expectEqual(@as(u64, @bitCast(v +% 1000)), runA64(t.bytes()).?);
    }
}

// ---- The layout probe ----

const layout = @import("layout.zig");
const Value = tcl.Value;

/// A Value made byte by byte from the layout: the payload words and the
/// full tag byte.
fn makeValue(l: layout.Layout, tag: u8, w0: u64, w1: u64) Value {
    var v: Value = undefined;
    const b = std.mem.asBytes(&v);
    @memset(b, 0);
    std.mem.writeInt(u64, b[l.value_payload..][0..8], w0, .little);
    std.mem.writeInt(u64, b[l.value_len..][0..8], w1, .little);
    b[l.value_tag] = tag;
    return v;
}

test "the layout probe finds each fact" {
    if (!jit.built) return error.SkipZigTest;
    const l = layout.probe() orelse return error.NoLayout;
    // Each kind of Value reads back through Zig code.
    const n = makeValue(l, l.tag_int, @bitCast(@as(i64, -77)), 0);
    try testing.expectEqual(@as(i64, -77), n.int);
    const d = makeValue(l, l.tag_double, @bitCast(@as(f64, 2.25)), 0);
    try testing.expectEqual(@as(f64, 2.25), d.double);
    const text = "hello";
    const s = makeValue(l, l.tag_str, @intFromPtr(text), 4);
    try testing.expectEqualStrings("hell", s.str);
    var obj: tcl.value.ListObj = .{ .buf = &.{}, .used = 0 };
    const li = makeValue(l, l.tag_list, @intFromPtr(&obj), 0);
    try testing.expectEqual(&obj, li.list.obj);
    try testing.expectEqual(@as(usize, 0), li.list.len);
    // A cell with a value, and a cell with a link.
    var cell: tcl.interp.Var = undefined;
    const cb = std.mem.asBytes(&cell);
    @memset(cb, 0);
    @memcpy(cb[l.var_payload..][0..l.value_size], std.mem.asBytes(&n));
    cb[l.var_tag] = l.var_val;
    try testing.expect(cell.v == .val);
    try testing.expectEqual(@as(i64, -77), cell.v.val.int);
    var link: tcl.interp.Var = undefined;
    const lb = std.mem.asBytes(&link);
    @memset(lb, 0);
    std.mem.writeInt(u64, lb[l.var_payload..][0..8], @intFromPtr(&cell), .little);
    lb[l.var_tag] = l.var_link;
    try testing.expect(link.v == .link);
    try testing.expectEqual(&cell, link.v.link);
    try testing.expect(link.target() == &cell);
}

// ---- The verifier ----

const verify = @import("verify.zig");
const vm = @import("../vm.zig");
const Range = std.meta.Child(@FieldType(vm.Code, "ranges"));

/// The Code of the body of proc `name`.
fn procCode(it: *Interp, name: []const u8) !*vm.Code {
    const cmd = it.commands.get(name) orelse return error.NoProc;
    const p = cmd.impl.proc;
    if (p.script == null) p.script = try it.compile(try it.str(p.body));
    return vm.compileProc(it, p, p.script.?);
}

/// The text of a file of the repository, from the root folder.
fn readRepoFile(a: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    // The portable file API, so the test also runs on Windows.
    return std.Io.Dir.cwd().readFileAlloc(testing.io, std.mem.span(path), a, .limited(64 << 20)) catch error.NoFile;
}

/// Defines the procs of a script and runs no other command.
fn defineProcs(it: *Interp, text: []const u8) !void {
    const s = try it.compile(text);
    for (s.cmds) |*c| {
        if (c.words.len == 4 and c.words[0].kind == .lit and std.mem.eql(u8, try it.str(c.words[0].kind.lit), "proc")) {
            _ = try it.evalCmd(c);
        }
    }
}

fn verifies(code: *const vm.Code) !bool {
    var info = (try verify.verify(testing.allocator, code)) orelse return false;
    info.deinit(testing.allocator);
    return true;
}

test "the verifier passes each proc of the benchmarks" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const names = [_][*:0]const u8{ "bench/sum.tcl", "bench/fib.tcl", "bench/nested.tcl", "bench/strbuild.tcl", "bench/foreach.tcl", "bench/dict.tcl", "bench/dictgrow.tcl", "bench/readloop.tcl" };
    var foreach_seen: usize = 0;
    for (names) |path| {
        const it = try newInterp();
        defer freeInterp(it);
        const text = try readRepoFile(testing.allocator, path);
        defer testing.allocator.free(text);
        try defineProcs(it, text);
        var iter = it.commands.iterator();
        while (iter.next()) |e| {
            if (e.value_ptr.*.impl != .proc) continue;
            const code = try procCode(it, e.key_ptr.*);
            var info = (try verify.verify(testing.allocator, code)) orelse {
                std.debug.print("{s}: proc {s} fails\n", .{ path, e.key_ptr.* });
                return error.VerifyFailed;
            };
            defer info.deinit(testing.allocator);
            // The depth of each foreach_next equals the depth of its loop.
            for (code.ins, 0..) |ins, pc| {
                if (ins.op != .foreach_next) continue;
                foreach_seen += 1;
                const r = for (code.ranges) |r| {
                    if (r.cont == pc) break r;
                } else return error.NoRange;
                try testing.expectEqual(r.depth, info.depth[pc]);
            }
        }
    }
    try testing.expect(foreach_seen > 0);
}

const base_proc =
    \\proc f {n} {
    \\    set s 0
    \\    set l {1 2 3}
    \\    for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $i}]; if {$i > 2} break }
    \\    foreach x $l { incr s $x }
    \\    dict set d k [llength $l]
    \\    lset l 0 5
    \\    append t "a$s,b"
    \\    while {$s > 100} { incr s -1 }
    \\    set y [expr {$s * 2 + $n}]
    \\    return [list $s $y $t]
    \\}
;

/// A copy of a Code with its own instructions, literals, and tables.
const Mutable = struct {
    code: vm.Code,
    ins: []vm.Ins,
    lits: []tcl.Value,
    tables: [][]const u32,
    ranges: []Range,

    fn init(a: std.mem.Allocator, c: *const vm.Code) !Mutable {
        var m: Mutable = .{ .code = c.*, .ins = try a.dupe(vm.Ins, c.ins), .lits = try a.dupe(tcl.Value, c.lits), .tables = try a.dupe([]const u32, c.tables), .ranges = try a.dupe(Range, c.ranges) };
        m.code.ins = m.ins;
        m.code.lits = m.lits;
        m.code.tables = m.tables;
        m.code.ranges = m.ranges;
        return m;
    }

    fn find(m: *const Mutable, op: vm.Op) usize {
        for (m.ins, 0..) |i, k| if (i.op == op) return k;
        std.debug.print("no {t} in the base proc\n", .{op});
        unreachable;
    }
};

test "the verifier fails a Code that breaks one check" {
    const it = try newInterp();
    defer freeInterp(it);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try defineProcs(it, base_proc);
    const code = try procCode(it, "f");
    try testing.expect(try verifies(code));
    const ops = [_]vm.Op{ .guard, .step, .jump, .push, .load, .store_pop, .bin_vv, .bin_vi, .jf_vv, .jf_vi, .incr_drop, .foreach_init, .foreach_next, .dict_update_drop, .lset_drop, .append, .invoke, .access, .binary, .ret, .eval_cmd };
    for (ops) |op| {
        var m = try Mutable.init(a, code);
        _ = m.find(op);
    }

    const Case = struct { name: []const u8, f: *const fn (*Mutable, std.mem.Allocator) anyerror!void };
    const cases = [_]Case{
        // 1. Opcodes and operators.
        .{ .name = "opcode", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                std.mem.asBytes(&m.ins[m.find(.load)])[0] = 250;
            }
        }.f },
        .{ .name = "access form", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.ins[m.find(.access)].x = 4;
            }
        }.f },
        .{ .name = "binary operator", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.ins[m.find(.binary)].x = 200;
            }
        }.f },
        .{ .name = "jf compare", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.ins[m.find(.jf_vv)].x = @intFromEnum(tcl.expr.BinOp.add);
            }
        }.f },
        .{ .name = "dict form", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.ins[m.find(.dict_update_drop)].x = 2;
            }
        }.f },
        // 2. Indexes.
        .{ .name = "slot", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.ins[m.find(.load)].a = @intCast(m.code.names.len);
            }
        }.f },
        .{ .name = "literal", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.ins[m.find(.push)].a = @intCast(m.lits.len);
            }
        }.f },
        .{ .name = "site", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.ins[m.find(.invoke)].a = @intCast(m.code.sites.len);
            }
        }.f },
        .{ .name = "table slot", .f = struct {
            fn f(m: *Mutable, al: std.mem.Allocator) !void {
                const t = m.ins[m.find(.foreach_next)].a;
                const bad = try al.dupe(u32, m.tables[t]);
                bad[0] = @intCast(m.code.names.len);
                m.tables[t] = bad;
            }
        }.f },
        .{ .name = "empty table", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.tables[m.ins[m.find(.foreach_next)].a] = &.{};
            }
        }.f },
        // 3. The literal of bin_vi and jf_vi.
        .{ .name = "bin_vi literal", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.lits[m.ins[m.find(.bin_vi)].b] = .{ .str = "7" };
            }
        }.f },
        .{ .name = "jf_vi literal", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.lits[m.ins[m.find(.jf_vi)].b] = .{ .double = 7 };
            }
        }.f },
        // 4. Counts.
        .{ .name = "invoke count", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.ins[m.find(.invoke)].b = 0;
            }
        }.f },
        .{ .name = "append count", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.ins[m.find(.append)].b = 9;
            }
        }.f },
        // 5. Guards and cold blocks.
        .{ .name = "guard target", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                const g = m.find(.guard);
                m.ins[g].a = @intCast(g + 1);
            }
        }.f },
        .{ .name = "cold block guard", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                const g = m.find(.guard);
                m.ins[m.ins[g].a].b = @intCast(g + 1);
            }
        }.f },
        // 6. The site of dict_update.
        .{ .name = "dict site", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                // The site of `llength $l` has two words.
                m.ins[m.find(.dict_update_drop)].b = m.ins[m.find(.access) + 1].a;
            }
        }.f },
        // 7. Depths.
        .{ .name = "depth above max_stack", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.code.max_stack = 2;
            }
        }.f },
        .{ .name = "depth below need", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.ins[m.find(.binary)].op = .concat;
                m.ins[m.find(.concat)].a = 60;
            }
        }.f },
        .{ .name = "two depths", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                // A jump to the instruction after a push.
                const p = m.find(.push);
                const j = m.find(.jump);
                m.ins[j].a = @intCast(p + 1);
            }
        }.f },
        // 8. The marks of foreach.
        .{ .name = "foreach mark", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.ins[m.find(.foreach_init)] = .{ .op = .incr, .a = 0, .b = 1 };
            }
        }.f },
        // 9. A path past the end.
        .{ .name = "past the end", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.ins[m.ins.len - 1] = .{ .op = .step };
            }
        }.f },
        // 10. break and continue targets.
        .{ .name = "range depth", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                for (m.ranges) |*r| {
                    if (r.brk != std.math.maxInt(u32)) {
                        r.depth += 1;
                        return;
                    }
                }
                unreachable;
            }
        }.f },
        .{ .name = "range target", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                for (m.ranges) |*r| {
                    if (r.brk != std.math.maxInt(u32)) {
                        r.brk = @intCast(m.ins.len);
                        return;
                    }
                }
                unreachable;
            }
        }.f },
        // 11. Named code with `dict_update_drop` and `lset_drop`: they
        // read a cell of the frame by its slot.
        .{ .name = "named", .f = struct {
            fn f(m: *Mutable, al: std.mem.Allocator) !void {
                m.code.named = true;
                const hints = try al.alloc(u32, m.code.names.len);
                @memset(hints, 0);
                m.code.hints = hints;
                // The `ret` of `return` goes to the last `ret`, so only
                // the two instructions break a rule of named code.
                for (m.ins[0 .. m.ins.len - 1], 0..) |*i, k| {
                    if (i.op == .ret and m.ins[k + 1].op == .ret) i.* = .{ .op = .jump, .a = @intCast(k + 1) };
                }
            }
        }.f },
    };
    for (cases) |c| {
        var m = try Mutable.init(a, code);
        try testing.expect(try verifies(&m.code));
        try c.f(&m, a);
        if (try verifies(&m.code)) {
            std.debug.print("check {s}: the verifier passes the bad Code\n", .{c.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "the verifier fails a loop that counts no step" {
    const it = try newInterp();
    defer freeInterp(it);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try defineProcs(it, base_proc);
    const code = try procCode(it, "f");
    // A jump to itself.
    var m = try Mutable.init(a, code);
    const j = m.find(.jump);
    m.ins[j].a = @intCast(j);
    try testing.expect(!try verifies(&m.code));
    // The back jump of the `for` loop goes to the `incr_drop` before it.
    // The two instructions are then a loop that counts no step.
    m = try Mutable.init(a, code);
    const inc = m.find(.incr_drop);
    try testing.expect(m.ins[inc + 1].op == .jump and m.ins[inc + 1].a < inc);
    m.ins[inc + 1].a = @intCast(inc);
    try testing.expect(!try verifies(&m.code));
    try testing.expect(try verifies(code));
}

test "each proc of the unit tests passes the verifier" {
    // The hook in vm.compileProc counts the runs of the other tests.
    const it = try newInterp();
    defer freeInterp(it);
    try defineProcs(it, base_proc);
    _ = try procCode(it, "f");
    try testing.expect(verify.hook_runs > 0);
    try testing.expectEqual(@as(usize, 0), verify.hook_failures);
}

// ---- The helpers ----

const helpers = @import("helpers.zig");

test "the helpers run the instruction functions" {
    const it = try newInterp();
    defer freeInterp(it);
    try defineProcs(it, "proc g {a b} {set c [expr {$a + $b}]; return $c}");
    const code = try procCode(it, "g");
    // A frame with the slots of g.
    var frame: tcl.interp.Frame = .{};
    for (code.names, 0..) |name, k| {
        const cell = try it.alloc().create(tcl.interp.Var);
        cell.* = .{};
        if (k < 2) cell.v = .{ .val = .{ .int = @intCast(k + 20) } };
        try frame.vars.append(it.alloc(), .{ .name = name, .cell = cell });
    }
    var stack: [8]tcl.Value = undefined;
    var ctx: jit.EnterCtx = .{ .it = it, .code = code, .frame = &frame, .stack = &stack, .helpers = &helpers.table, .target = 0, .pc = 0, .sp = 0, .err = 0, .empty = &tcl.Value.empty, .counters = undefined, .func = undefined };
    // bin_vv: 20 + 21 at depth 0.
    const pc: u32 = for (code.ins, 0..) |ins, k| {
        if (ins.op == .bin_vv) break @intCast(k);
    } else return error.NoBinVv;
    const h: helpers.Fn = @ptrCast(@alignCast(helpers.table[@intFromEnum(helpers.Helper.bin_vv)]));
    try testing.expectEqual(helpers.done, h(&ctx, pc, 0));
    try testing.expectEqual(@as(i64, 41), stack[0].int);
    // load of a slot with no value: an error with the text of the interpreter.
    const load: helpers.Fn = @ptrCast(@alignCast(helpers.table[@intFromEnum(helpers.Helper.load)]));
    var bad = code.ins[pc];
    bad = .{ .op = .load, .a = 2 };
    var ins = try testing.allocator.dupe(vm.Ins, code.ins);
    defer testing.allocator.free(ins);
    ins[0] = bad;
    var c2 = code.*;
    c2.ins = ins;
    ctx.code = &c2;
    try testing.expectEqual(helpers.failed, load(&ctx, 0, 1));
    try testing.expectEqual(error.TclError, helpers.errorOf(&ctx));
    try testing.expectEqualStrings("can't read \"c\": no such variable", try it.str(it.result));
}

// ---- Compiled code against the interpreter ----

const Outcome = struct {
    text: []u8,
    fn deinit(o: Outcome) void {
        testing.allocator.free(o.text);
    }
};

fn collect(ctx: ?*anyopaque, bytes: []const u8) void {
    const out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx.?));
    out.appendSlice(testing.allocator, bytes) catch {};
}

/// Runs `script` in a new interpreter, with the JIT at threshold 0 when
/// `on`, and gives the output, the result, errorInfo, errorCode, and
/// the steps used as one text.
fn runMode(script: []const u8, on: bool, limit: u64, min_compiled: u64) !Outcome {
    return runModeGc(script, on, limit, min_compiled, 0);
}

/// `runMode` with the collector off, or with a collection at each
/// `stress`th allocation. With the stress mode, the text has no memory
/// count.
fn runModeGc(script: []const u8, on: bool, limit: u64, min_compiled: u64, stress: u32) !Outcome {
    return runModeOpts(script, if (on) .{ .threshold = 0, .tier2 = test_tier2, .tier2_count = 2, .stress = test_stress } else null, limit, min_compiled, stress);
}

/// `runModeGc` with the options of the JIT, or null for no JIT.
fn runModeOpts(script: []const u8, opts: ?jit.Options, limit: u64, min_compiled: u64, stress: u32) !Outcome {
    const on = opts != null;
    const it = try newInterp();
    defer freeInterp(it);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    it.output = .{ .ctx = &out, .write = collect };
    if (stress == 0) it.gc_on = false else it.setGcStress(stress);
    it.step_limit = limit;
    if (allow_interp) try it.allow(@intFromEnum(tcl.interp.Capability.interp));
    if (test_mem_limit) |m| it.mem_limit = m;
    if (test_native) |n| try it.register(n[0], n[1]);
    if (on and !it.enableJit(opts.?)) return error.SkipZigTest;
    var w: std.ArrayList(u8) = .empty;
    errdefer w.deinit(testing.allocator);
    const a = testing.allocator;
    if (it.eval(script)) |v| {
        try w.print(a, "result: {s}\n", .{try it.str(v)});
    } else |e| {
        try w.print(a, "error {t}: {s}\n", .{ e, it.str(it.result) catch "" });
        if (e == error.TclError) try it.finishError();
    }
    const info = it.getVarPlain("::errorInfo") catch Value.empty;
    const code = it.getVarPlain("::errorCode") catch Value.empty;
    try w.print(a, "output: {s}\nerrorInfo: {s}\nerrorCode: {s}\nsteps: {d}\n", .{ out.items, try it.str(info), try it.str(code), limit - it.step_limit });
    if (stress == 0) try w.print(a, "mem: {d}\n", .{it.memUsed()});
    last_peak = it.counter.mem_peak;
    if (on) {
        const st = it.jit.?.stats;
        last_tier2 = st.tier2;
        last_exits = st.exits;
        if (st.compiled < min_compiled) {
            std.debug.print("compiled {d} < {d} for:\n{s}\n", .{ st.compiled, min_compiled, script });
            return error.TooFewCompiled;
        }
    }
    return .{ .text = try w.toOwnedSlice(a) };
}

/// True while a test runs scripts with the capability `interp`.
var allow_interp = false;
/// True while a test runs the JIT with tier 2, at a loop count of 2.
var test_tier2 = false;
/// The memory limit of the scripts of a test, when not null.
var test_mem_limit: ?usize = null;
/// The highest byte count of the last run.
var last_peak: usize = 0;
/// The tier 2 loops and the exits of the last run with the JIT.
var last_tier2: u64 = 0;
var last_exits: u64 = 0;
/// The stress modes of the JIT in a test.
var test_stress: u32 = 0;
/// A native command for the scripts of a test.
var test_native: ?struct { []const u8, tcl.interp.NativeFn } = null;

/// Runs `script` in the interpreter and with the JIT and compares each
/// field. `min_compiled` is the least count of compiled functions.
fn same(script: []const u8, min_compiled: u64) !void {
    return sameLimit(script, std.math.maxInt(u64), min_compiled);
}

fn sameLimit(script: []const u8, limit: u64, min_compiled: u64) !void {
    if (!jit.built) return error.SkipZigTest;
    const ref = try runMode(script, false, limit, 0);
    defer ref.deinit();
    const got = try runMode(script, true, limit, min_compiled);
    defer got.deinit();
    testing.expectEqualStrings(ref.text, got.text) catch |e| {
        std.debug.print("script:\n{s}\n", .{script});
        return e;
    };
}

test "jit: an error in a proc gives the full errorInfo" {
    try same(
        \\proc inner {x} { set y [expr {$x * 2}]; error "bad $y" }
        \\proc outer {} { set a 1; incr a; inner $a }
        \\outer
    , 2);
    try same(
        \\proc f {} { set l {1 2}; for {set i 0} {$i < 3} {incr i} { set x [lindex $l $i]; expr {$x + 1} } }
        \\f
    , 1);
    try same("proc f {} {set u}; f", 1);
}

test "jit: break and continue from eval in a compiled loop" {
    try same(
        \\proc f {} {
        \\    set s {}
        \\    for {set i 0} {$i < 10} {incr i} {
        \\        if {$i == 2} { eval continue }
        \\        if {$i == 6} { eval break }
        \\        lappend s $i
        \\    }
        \\    foreach x {a b c d} { if {$x eq "b"} {eval continue}; if {$x eq "d"} {eval {break}}; lappend s $x }
        \\    set k 0
        \\    while {1} { incr k; if {$k > 3} {eval break}; lappend s w$k }
        \\    return $s
        \\}
        \\f
    , 1);
}

test "jit: return -code of each code" {
    try same(
        \\proc r {c} { return -code $c "v$c" }
        \\set out {}
        \\foreach c {ok error return break continue 5 7} { lappend out [catch {r $c} m] $m }
        \\proc loop {} { set s {}; foreach c {1 2 3} { lappend s [catch {return -code break} m] } ; return $s }
        \\lappend out [loop]
        \\proc lev {} { return -level 2 -code ok deep }
        \\proc call {} { lev; return shallow }
        \\lappend out [call]
    , 3);
}

test "jit: catch around a compiled proc" {
    try same(
        \\proc boom {n} { if {$n > 2} { error "n is $n" "my info" {MY CODE} }; return $n }
        \\set r {}
        \\for {set i 0} {$i < 5} {incr i} { lappend r [catch {boom $i} m opts] $m [dict get $opts -code] }
        \\lappend r $::errorCode
    , 1);
}

test "jit: a step limit inside a compiled loop leaves the same steps" {
    const script =
        \\proc spin {} { set s 0; for {set i 0} {$i < 1000} {incr i} { incr s $i; set t [expr {$s % 7}] }; return $s }
        \\spin
    ;
    for ([_]u64{ 1, 2, 5, 17, 100, 333, 1000, 2500 }) |limit| try sameLimit(script, limit, 0);
    try sameLimit(script, std.math.maxInt(u64), 1);
}

test "jit: a coroutine yields from a compiled proc and resumes" {
    try same(
        \\proc gen {n} { yield; for {set i 0} {$i < $n} {incr i} { yield [expr {$i * $i}] }; return done }
        \\coroutine c gen 4
        \\set r {}
        \\for {set k 0} {$k < 5} {incr k} { lappend r [c] }
        \\set r
    , 1);
}

test "jit: rename set inside a running compiled proc" {
    try same(
        \\proc f {} {
        \\    set a 1
        \\    rename set foo
        \\    proc set {args} { return "custom $args" }
        \\    set r [set a]
        \\    rename set {}
        \\    rename foo set
        \\    set b [expr {$a + 1}]
        \\    return [list $r $b]
        \\}
        \\f
    , 1);
}

test "jit: a variable trace added while a compiled loop runs" {
    try same(
        \\proc f {} {
        \\    set log {}
        \\    for {set i 0} {$i < 6} {incr i} {
        \\        if {$i == 2} { trace add variable i write [list apply {{args} { upvar log log; lappend log t }}] }
        \\        set x [expr {$i * 2}]
        \\    }
        \\    return [list $x $log]
        \\}
        \\f
    , 1);
}

test "jit: upvar and uplevel change a local of a compiled proc" {
    try same(
        \\proc bump {name} { upvar 1 $name v; incr v 10 }
        \\proc setit {} { uplevel 1 {set y 99} }
        \\proc f {} {
        \\    set x 1
        \\    for {set i 0} {$i < 3} {incr i} { bump x; set z [expr {$x + $i}] }
        \\    setit
        \\    return [list $x $y $z]
        \\}
        \\f
    , 1);
}

test "jit: a proc that redefines itself" {
    try same(
        \\proc f {} { proc f {} { return second }; return first }
        \\list [f] [f] [f]
    , 1);
}

test "jit: tailcall" {
    try same(
        \\proc g {x} { return [expr {$x * 3}] }
        \\proc f {x} { set y [expr {$x + 1}]; tailcall g $y }
        \\proc count {n acc} { if {$n == 0} { return $acc }; tailcall count [expr {$n - 1}] [expr {$acc + $n}] }
        \\list [f 4] [count 100 0]
    , 2);
}

test "jit: a TclOO method" {
    try same(
        \\oo::class create Acc {
        \\    variable total
        \\    constructor {} { set total 0 }
        \\    method add {n} { for {set i 0} {$i < $n} {incr i} { incr total $i }; return $total }
        \\    method get {} { my add 0 }
        \\}
        \\set a [Acc new]
        \\list [$a add 5] [$a add 3] [$a get]
    , 1);
}

test "jit: the code bytes of the benchmarks" {
    if (!jit.built) return error.SkipZigTest;
    const names = [_][*:0]const u8{ "bench/sum.tcl", "bench/fib.tcl", "bench/nested.tcl", "bench/strbuild.tcl", "bench/foreach.tcl", "bench/dict.tcl", "bench/dictgrow.tcl", "bench/readloop.tcl" };
    var bytes: usize = 0;
    var ins: usize = 0;
    for (names) |path| {
        const it = try newInterp();
        defer freeInterp(it);
        const text = try readRepoFile(testing.allocator, path);
        defer testing.allocator.free(text);
        try defineProcs(it, text);
        var iter = it.commands.iterator();
        while (iter.next()) |e| {
            if (e.value_ptr.*.impl != .proc) continue;
            const code = try procCode(it, e.key_ptr.*);
            var info = (try verify.verify(testing.allocator, code)).?;
            defer info.deinit(testing.allocator);
            var s = x64.Asm.init(testing.allocator);
            defer s.deinit();
            const entries = try testing.allocator.alloc(u32, code.ins.len);
            defer testing.allocator.free(entries);
            try @import("tier1_x64.zig").assemble(testing.allocator, &s, code, &info, layout.probe().?, entries, false);
            bytes += s.bytes().len;
            ins += code.ins.len;
        }
    }
    try testing.expect(bytes <= 96 * ins);
}

test "jit: overflow at both ends gives a big integer" {
    try same(
        \\proc ops {a b} {
        \\    set r {}
        \\    lappend r [expr {$a + $b}] [expr {$a - $b}] [expr {$a * $b}]
        \\    set c $a; incr c $b; lappend r $c
        \\    set d $a; incr d; lappend r $d
        \\    set e $a; incr e -1; lappend r $e
        \\    lappend r [expr {$a + 1}] [expr {$a - 1}] [expr {$a * 2}]
        \\    set x [expr {$a + 0}]; set y [expr {$b + 0}]
        \\    lappend r [expr {$x + $y}] [expr {$x - $y}] [expr {$x * $y}]
        \\    return $r
        \\}
        \\list [ops 9223372036854775807 1] [ops -9223372036854775808 1] [ops 9223372036854775807 -1] [ops -9223372036854775808 -1] [ops 4611686018427387904 2] [ops -9223372036854775808 9223372036854775807]
    , 1);
}

test "jit: string, double, and unset operands" {
    try same(
        \\proc f {a b} {
        \\    set r {}
        \\    lappend r [expr {$a + $b}] [expr {$a < $b}] [expr {$a * 2}]
        \\    if {$a < $b} { lappend r lt } else { lappend r ge }
        \\    if {$a} { lappend r true }
        \\    set c $a; incr c 5; lappend r $c
        \\    return $r
        \\}
        \\list [f "10" "20"] [f 1.5 2] [f 7 2.25] [f " 12 " 3] [catch {f abc 1} m] $m [catch {f 1.5 x} m] $m
    , 1);
    try same("proc g {} { set x [expr {$u + 1}] }; list [catch g m] $m $::errorInfo", 1);
    try same("proc g {} { incr nope; set q [expr {$nope * 2}] }; g", 1);
    try same("proc g {} { set z $missing }; g", 1);
}

test "jit: a slot that links to a global, two links deep" {
    try same(
        \\set gx 5
        \\proc inner {} { upvar 1 y yy; for {set i 0} {$i < 4} {incr i} { incr yy $i; set t [expr {$yy * 2}] }; return [list $yy $t] }
        \\proc outer {} { upvar #0 gx y; set y [expr {$y + 1}]; set r [inner]; lappend r $y; return $r }
        \\list [outer] $gx
    , 2);
}

test "jit: a traced cell and an array name used as a scalar" {
    try same(
        \\proc f {} {
        \\    set log {}
        \\    set v 1
        \\    trace add variable v {read write} [list apply {{args} { upvar log log; lappend log [lindex $args end] }}]
        \\    for {set i 0} {$i < 3} {incr i} { set v [expr {$v + $i}]; incr v }
        \\    return [list $v $log]
        \\}
        \\f
    , 1);
    try same(
        \\proc g {} { array set a {x 1}; set r [catch {set q [expr {$a + 1}]} m]; lappend r $m [catch {incr a} m] $m [catch {set a 5} m] $m; return $r }
        \\g
    , 1);
}

test "jit: compares of the smallest and the largest integer" {
    try same(
        \\proc cmp {a b} {
        \\    set r {}
        \\    foreach op {< <= > >= == !=} { lappend r [expr "\$a $op \$b"] }
        \\    lappend r [expr {$a < $b}] [expr {$a <= $b}] [expr {$a > $b}] [expr {$a >= $b}] [expr {$a == $b}] [expr {$a != $b}]
        \\    if {$a < $b} { lappend r y } else { lappend r n }
        \\    if {$a >= 9223372036854775807} { lappend r big }
        \\    if {$a <= -9223372036854775808} { lappend r small }
        \\    return $r
        \\}
        \\list [cmp -9223372036854775808 9223372036854775807] [cmp 9223372036854775807 -9223372036854775808] [cmp 5 5]
    , 1);
}

test "jit: compiled code with a collection at each allocation" {
    if (!jit.built) return error.SkipZigTest;
    const scripts = [_][]const u8{
        \\proc f {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l [string repeat x $i] [expr {$i * $i}] }; set s 0; foreach x $l { incr s [string length $x] }; return [list $s [llength $l]] }
        \\list [f 40] [f 40]
        ,
        \\proc g {d} { dict set d k[expr {[dict size $d] % 5}] [list a b]; return $d }
        \\proc f {} { set d {}; for {set i 0} {$i < 30} {incr i} { set d [g $d]; append s "$i," }; return [list $d $s] }
        \\f
        ,
        \\proc gen {n} { yield; for {set i 0} {$i < $n} {incr i} { yield [string repeat y $i] } }
        \\coroutine c gen 20
        \\set r {}; for {set k 0} {$k < 20} {incr k} { lappend r [string length [c]] }; set r
        ,
        \\oo::class create A { variable t; constructor {} { set t {} }; method add {x} { lappend t [string repeat $x 3]; return [llength $t] } }
        \\set o [A new]; set r {}; for {set i 0} {$i < 25} {incr i} { lappend r [$o add $i] }; set r
    };
    for (scripts) |script| {
        const ref = try runModeGc(script, false, std.math.maxInt(u64), 0, 0);
        defer ref.deinit();
        const got = try runModeGc(script, true, std.math.maxInt(u64), 1, 1);
        defer got.deinit();
        // The reference has the memory count: compare the lines before it.
        const want = ref.text[0 .. std.mem.lastIndexOf(u8, ref.text, "mem: ").?];
        testing.expectEqualStrings(want, got.text) catch |e| {
            std.debug.print("script:\n{s}\n", .{script});
            return e;
        };
    }
}

test "jit: a child interp deleted while its compiled code runs" {
    allow_interp = true;
    defer allow_interp = false;
    try same(
        \\interp create c
        \\interp alias c kill {} apply {{} { interp delete c; return killed }}
        \\c eval {
        \\  proc p {} { set s 0; for {set i 0} {$i < 50} {incr i} { incr s $i; if {$i == 25} { lappend s [kill] }; set t [list $i $s] }; return $s }
        \\  proc q {} { p }
        \\}
        \\catch {c eval q} m; puts "1: $m [interp exists c]"
        \\interp create d
        \\interp alias d kill {} interp delete d
        \\catch {d eval { proc z {} { for {set i 0} {$i < 3} {incr i} {}; kill; set x 0; for {set i 0} {$i < 50} {incr i} {incr x}; return $x }; z }} m
        \\puts "2: $m [interp exists d]"
        \\for {set k 0} {$k < 20} {incr k} { interp create e$k; e$k eval { proc p {} { set s 0; for {set i 0} {$i < 10} {incr i} {incr s}; return $s }; p; p }; interp delete e$k }
    , 0);
}


test "jit: / and % for each sign pair, 0, and -1" {
    try same(
        \\proc d {a b} { list [expr {$a / $b}] [expr {$a % $b}] }
        \\proc dv {a} { set b -1; set z 0; list [expr {$a / $b}] [expr {$a % $b}] [catch {expr {$a / $z}} m] $m [catch {expr {$a % $z}} m] $m $::errorCode }
        \\proc lit {a} { list [expr {$a / 7}] [expr {$a % 7}] [expr {$a / -7}] [expr {$a % -7}] }
        \\proc st {a b} { list [expr {($a + 0) / ($b + 0)}] [expr {($a + 0) % ($b + 0)}] }
        \\set r {}
        \\foreach {a b} {7 2 -7 2 7 -2 -7 -2 6 3 -6 3 6 -3 0 5 0 -5 9223372036854775807 2 -9223372036854775808 2 -9223372036854775808 7 1 9223372036854775807} {
        \\  lappend r [d $a $b] [st $a $b] [lit $a]
        \\}
        \\lappend r [dv -9223372036854775808] [dv 5] [dv -5] [dv 0]
        \\set r
    , 4);
}

test "jit: lindex and llength on lists" {
    try same(
        \\proc f {l} { set r {}; foreach i {-1 0 1 2 3 4 9223372036854775807 -9223372036854775808 end 1.0} { lappend r [lindex $l $i] }; lappend r [llength $l] [llength {}] [llength "a b"]; set r }
        \\list [f {a b c}] [f {}] [f [list x {y z}]] [f "p q"]
    , 1);
}

test "jit: lappend to a shared list and to a list at its capacity" {
    try same(
        \\proc f {} {
        \\  set a {}; for {set i 0} {$i < 20} {incr i} { lappend a $i }
        \\  set b $a; lappend a x; lappend b y; lappend a z
        \\  set c [lrange $a 0 2]; lappend c w
        \\  set e {}; for {set i 0} {$i < 8} {incr i} { lappend e $i }; set g $e; lappend e 8; lappend g 9
        \\  list $a $b $c $e $g [llength $a]
        \\}
        \\f
    , 1);
}

test "jit: foreach over a list that the body changes" {
    try same(
        \\proc f {} {
        \\  set l {1 2 3}; set r {}
        \\  foreach x $l { lappend l [expr {$x * 10}]; lappend r $x }
        \\  foreach {x y} $l { set l {}; lappend r $x $y }
        \\  foreach {a b c d} {1 2 3 4 5 6} { lappend r $a $b $c $d }
        \\  foreach {a b c d e} {1 2 3 4 5 6} { lappend r $a $b $c $d $e }
        \\  list $l $r
        \\}
        \\f
    , 1);
}

test "jit: foreach with a traced loop variable" {
    try same(
        \\proc f {} {
        \\  set n 0
        \\  trace add variable x write [list apply {{args} { incr ::cnt }}]
        \\  foreach x {a b c d} { incr n }
        \\  upvar #0 g y
        \\  foreach y {1 2 3} {}
        \\  list $n $x $y
        \\}
        \\set cnt 0; list [f] $cnt $g
    , 1);
}

test "jit: lset on an owned list and switch on strings" {
    try same(
        \\proc f {} {
        \\  set t [lrepeat 10 0]; set p 0
        \\  for {set i 0} {$i < 40} {incr i} { lset t $p [expr {[lindex $t $p] + 1}]; set p [expr {($p + 3) % 10}] }
        \\  set d [dict create a 1 b 2]; lset d 1 9; dict set d c 3
        \\  set u $t; lset t 0 x; lset t 10 y
        \\  set r {}
        \\  foreach w {abc ab abd {} 12 x} { switch -exact -- $w { abc { lappend r 1 } ab { lappend r 2 } 12 { lappend r 3 } default { lappend r d } } }
        \\  list $t $u $d $r [catch {lset t -1 z} m] $m
        \\}
        \\f
    , 1);
}

test "jit: direct calls of procs" {
    try same(
        \\proc two {a b} { list $a $b }
        \\proc dflt {a {b 5} args} { list $a $b $args }
        \\proc site {k} { set r {}; for {set i 0} {$i < 3} {incr i} { lappend r [catch {two $k} m] $m [catch {two 1 2 3} m] $m [dflt $k] [dflt $k 1 2 3] }; set r }
        \\set out [site x]
        \\proc callg {} { set r {}; for {set i 0} {$i < 4} {incr i} { lappend r [g] }; set r }
        \\proc g {} { return first }
        \\lappend out [callg]
        \\proc callren {} { set r {}; for {set i 0} {$i < 4} {incr i} { lappend r [h]; if {$i == 1} { rename h h0; proc h {} { return second } } }; set r }
        \\proc h {} { return first }
        \\lappend out [callren]
        \\namespace eval a { proc f {} { return a } }
        \\namespace eval b { proc f {} { return b } }
        \\proc f {} { return global }
        \\proc inns {} { set r {}; foreach ns {a b :: a} { lappend r [namespace eval $ns {f}] [namespace eval $ns [list ::callf]] }; set r }
        \\proc callf {} { f }
        \\lappend out [inns]
        \\proc traced {x} { expr {$x * 2} }
        \\set log {}
        \\trace add execution traced enter [list apply {{args} { lappend ::log [lindex $args 0] }}]
        \\proc calltr {} { set r 0; for {set i 0} {$i < 3} {incr i} { incr r [traced $i] }; set r }
        \\lappend out [calltr] $log
        \\proc gone {} { rename gone {}; return bye }
        \\proc callgone {} { list [gone] [catch {gone} m] $m }
        \\lappend out [callgone]
        \\proc tc {n} { if {$n <= 0} { return done }; tailcall tc [expr {$n - 1}] }
        \\proc calltc {} { list [tc 5] [tc 0] }
        \\lappend out [calltc]
        \\set out
    , 4);
}

test "jit: recursion to the depth limit" {
    // A limit of 100 levels binds before the native stack limit of a
    // debug build in both modes.
    allow_interp = true;
    defer allow_interp = false;
    try same(
        \\interp recursionlimit {} 100
        \\proc r {n} { r [expr {$n + 1}] }
        \\list [catch {r 0} m] $m
    , 1);
}

// ---- Tier 2 ----

const tier2 = @import("tier2.zig");

/// The plan of the first loop of proc `name` with the kinds of `entry`
/// for each slot by name, and `.any` for each other slot.
fn planOf(it: *Interp, name: []const u8, entry: []const struct { []const u8, tier2.Kind }) !?tier2.LoopPlan {
    const code = try procCode(it, name);
    var info = (try verify.verify(testing.allocator, code)) orelse return error.NotVerified;
    defer info.deinit(testing.allocator);
    const kinds = try testing.allocator.alloc(tier2.Kind, code.names.len);
    defer testing.allocator.free(kinds);
    @memset(kinds, .any);
    for (entry) |e| for (code.names, 0..) |n, k| if (std.mem.eql(u8, n, e[0])) {
        kinds[k] = e[1];
    };
    if (info.loop_heads.len == 0) return error.NoLoop;
    return tier2.plan(testing.allocator, code, &info, info.loop_heads[0], kinds);
}

fn slotKind(p: *const tier2.LoopPlan, code_names: []const []const u8, name: []const u8) ?tier2.Kind {
    for (p.slots) |u| if (std.mem.eql(u8, code_names[u.slot], name)) return u.entry;
    return null;
}

test "tier 2: the plan of the loop of sum.tcl" {
    const it = try newInterp();
    defer freeInterp(it);
    const text = try readRepoFile(testing.allocator, "bench/sum.tcl");
    defer testing.allocator.free(text);
    try defineProcs(it, text);
    var p = (try planOf(it, "sum", &.{ .{ "i", .int }, .{ "s", .int }, .{ "n", .int } })).?;
    defer p.deinit();
    const names = (try procCode(it, "sum")).names;
    for ([_][]const u8{ "i", "s", "n" }) |n| try testing.expectEqual(tier2.Kind.int, slotKind(&p, names, n).?);
    try testing.expect(!p.calls);
    var with_steps: usize = 0;
    var steps: u32 = 0;
    for (p.parts) |part| if (part.steps > 0) {
        with_steps += 1;
        steps = part.steps;
    };
    try testing.expectEqual(@as(usize, 1), with_steps);
    try testing.expectEqual(@as(u32, 4), steps);
    const code = try procCode(it, "sum");
    var ops: [2]vm.Op = undefined;
    try testing.expectEqual(@as(usize, 2), p.exits.len);
    for (p.exits, 0..) |x, k| ops[k] = code.ins[x].op;
    try testing.expectEqual(vm.Op.bin_vv, ops[0]);
    try testing.expectEqual(vm.Op.incr_drop, ops[1]);
}

test "tier 2: plans with a string slot, a changed kind, and a call" {
    const it = try newInterp();
    defer freeInterp(it);
    const text = try readRepoFile(testing.allocator, "bench/strbuild.tcl");
    defer testing.allocator.free(text);
    try defineProcs(it, text);
    try defineProcs(it,
        \\proc chg {n} { set x 0; for {set i 0} {$i < $n} {incr i} { set x [expr {$x + 1}]; set x abc } }
        \\proc up {n} { set x 0; for {set i 0} {$i < $n} {incr i} { upvar 0 x y; incr x } }
    );
    var iter = it.commands.iterator();
    var sb: ?[]const u8 = null;
    while (iter.next()) |e| if (e.value_ptr.*.impl == .proc and !std.mem.eql(u8, e.key_ptr.*, "chg") and !std.mem.eql(u8, e.key_ptr.*, "up")) {
        sb = e.key_ptr.*;
    };
    var p1 = (try planOf(it, sb.?, &.{ .{ "i", .int }, .{ "n", .int } })).?;
    defer p1.deinit();
    try testing.expectEqual(tier2.Kind.any, slotKind(&p1, (try procCode(it, sb.?)).names, "s").?);
    var p2 = (try planOf(it, "chg", &.{ .{ "i", .int }, .{ "n", .int }, .{ "x", .int } })).?;
    defer p2.deinit();
    try testing.expectEqual(tier2.Kind.any, slotKind(&p2, (try procCode(it, "chg")).names, "x").?);
    try testing.expectEqual(tier2.Kind.int, slotKind(&p2, (try procCode(it, "chg")).names, "i").?);
    var p3 = (try planOf(it, "up", &.{ .{ "i", .int }, .{ "n", .int }, .{ "x", .int } })).?;
    defer p3.deinit();
    try testing.expect(p3.calls);
}

/// `same` with tier 2 on. Fails when fewer than `min_tier2` loops
/// compiled to tier 2.
fn sameT2(script: []const u8, min_tier2: u64) !void {
    test_tier2 = true;
    defer test_tier2 = false;
    try same(script, 1);
    if (last_tier2 < min_tier2) {
        std.debug.print("tier2 {d} < {d} for:\n{s}\n", .{ last_tier2, min_tier2, script });
        return error.TooFewTier2;
    }
}

const sum_script =
    \\proc sum {n} { set s 0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $i}] }; return $s }
    \\sum 30
;

test "tier 2: sum, and the step limit at each step of the loop" {
    if (!jit.built) return error.SkipZigTest;
    try sameT2(sum_script, 1);
    const ref = try runMode(sum_script, false, std.math.maxInt(u64), 0);
    defer ref.deinit();
    const at = std.mem.indexOf(u8, ref.text, "steps: ").?;
    const full = try std.fmt.parseInt(u64, std.mem.sliceTo(ref.text[at + 7 ..], '\n'), 10);
    test_tier2 = true;
    defer test_tier2 = false;
    var limit: u64 = 0;
    while (limit <= full) : (limit += 1) try sameLimit(sum_script, limit, 0);
}

test "tier 2: an overflow in pass 1000 gives a big integer" {
    try sameT2(
        \\proc f {} { set s 9223372036854774807; for {set i 0} {$i < 1500} {incr i} { set s [expr {$s + 1}] }; list $s $i }
        \\proc g {} { set s 3; for {set i 0} {$i < 70} {incr i} { set s [expr {$s * 3}] }; set s }
        \\proc h {} { set i 9223372036854775800; for {set k 0} {$k < 20} {incr k} { incr i 1 }; set i }
        \\list [f] [g] [h]
    , 3);
}

test "tier 2: a memory limit that a script passes before the loop" {
    test_mem_limit = 4 << 20;
    defer test_mem_limit = null;
    try sameT2(
        \\proc f {} { set l {}; set s x; for {set i 0} {$i < 30} {incr i} { append s $s }; set k 0; for {set i 0} {$i < 100} {incr i} { incr k }; list [string length $s] $k }
        \\f
    , 0);
}

/// Scripts in which one command builds a result far above a memory
/// limit of 8 MiB: 64 MiB or more without the hard cap of the counter.
const builder_scripts = [_][]const u8{
    // The string form of a list that holds itself twice at each level.
    "proc f {} {set l {a b}; for {set i 0} {$i < 18} {incr i} {set l [list $l $l]}; string length $l}; f",
    // The issue case: 40 levels.
    "proc f {} {set l {a b}; for {set i 0} {$i < 40} {incr i} {set l [list $l $l]}; string length $l}; f",
    "proc f {} {set d {a b}; for {set i 0} {$i < 18} {incr i} {set d [dict create x $d y $d]}; string length $d}; f",
    "proc f {} {set l {a b}; for {set i 0} {$i < 18} {incr i} {set l [list $l $l]}; llength [lsort [list $l x]]}; f",
    "proc f {} {string length [string repeat x 64000000]}; f",
    "proc f {} {llength [lrepeat 8000000 x]}; f",
    "proc f {} {set s [string repeat x 65536]; string length [join [lrepeat 1000 $s] {}]}; f",
    "proc f {} {string length [format [string repeat %1000000s 64] {*}[lrepeat 64 x]]}; f",
    "proc f {} {set s [string repeat x 65536]; set t {}; append t {*}[lrepeat 1000 $s]; string length $t}; f",
    "proc f {} {string length [binary format a16000000a16000000a16000000a16000000 x x x x]}; f",
    "proc f {} {set s [string repeat x 2000000]; llength [split $s {}]}; f",
    "proc f {} {set s [string repeat x 2000000]; llength [regexp -all -inline x $s]}; f",
    "proc f {} {set s [string repeat x 2000000]; string length [regsub -all x $s [string repeat & 32]]}; f",
    "proc f {} {set s [string repeat x 2000000]; string length [subst [string repeat {$s} 64]]}; f",
    "proc f {} {set s [string repeat x 2000000]; string length [string map [list x [string repeat x 32]] $s]}; f",
    "proc f {} {set s [string repeat x 2000000]; string length [concat {*}[lrepeat 64 $s]]}; f",
};

test "one command that builds a large result stops below twice the memory limit" {
    const limit: usize = 8 << 20;
    test_mem_limit = limit;
    defer test_mem_limit = null;
    const want = "error TclError: the script used too much memory\noutput: \nerrorInfo: the script used too much memory\nerrorCode: NONE\n";
    for (builder_scripts) |script| {
        const ref = try runMode(script, false, std.math.maxInt(u64), 0);
        defer ref.deinit();
        errdefer std.debug.print("script:\n{s}\npeak: {d}\n{s}\n", .{ script, last_peak, ref.text });
        try testing.expect(std.mem.startsWith(u8, ref.text, want));
        try testing.expect(last_peak <= 2 * limit);
        if (!jit.built) continue;
        for ([_]bool{ false, true }) |t2| {
            test_tier2 = t2;
            defer test_tier2 = false;
            const got = try runMode(script, true, std.math.maxInt(u64), 1);
            defer got.deinit();
            try testing.expectEqualStrings(ref.text, got.text);
            try testing.expect(last_peak <= 2 * limit);
        }
    }
}

/// Scripts in which one step did work that grew without a bound: with
/// a count of procs, of global variables, of table entries, or with the
/// size of a value. Each one has a step limit. With the work charged to
/// the step limit, each one stops at the limit in well under a second.
/// Before the charges, each one used many seconds of CPU time.
const step_cost_scripts = [_]struct { limit: u64, script: []const u8 }{
    // The issue case: the guard scanned each command after each new proc.
    .{ .limit = 60_000, .script = "proc f {} {for {set i 0} {1} {incr i} {proc p$i {} {}}}; f" },
    // The search of a frame read each variable.
    .{ .limit = 300_000, .script = "proc f {} {for {set i 0} {1} {incr i} {set ::v$i 1}}; f" },
    // A scan of the command table, a namespace delete, a delete of a
    // command, and the destroy of an object, each with 5000 procs.
    .{ .limit = 40_000, .script = "proc f {} {for {set i 0} {$i < 5000} {incr i} {proc p$i {} {}}; while 1 {info commands q*}}; f" },
    .{ .limit = 40_000, .script = "proc f {} {for {set i 0} {$i < 5000} {incr i} {proc p$i {} {}}; for {set i 0} {1} {incr i} {namespace eval n$i {}; namespace delete n$i}}; f" },
    .{ .limit = 40_000, .script = "proc f {} {for {set i 0} {$i < 5000} {incr i} {proc p$i {} {}}; for {set i 0} {1} {incr i} {proc q$i {} {}; rename q$i {}}}; f" },
    .{ .limit = 40_000, .script = "proc f {} {for {set i 0} {$i < 5000} {incr i} {proc p$i {} {}}; oo::class create C; while 1 {[C new] destroy}}; f" },
    // The scans of an array.
    .{ .limit = 40_000, .script = "proc f {} {for {set i 0} {$i < 5000} {incr i} {set a($i) 1}; while 1 {array names a q*}}; f" },
    .{ .limit = 150_100, .script = "proc f {} {for {set i 0} {$i < 50000} {incr i} {set a($i) 1}; array unset a {*[13579]}}; f" },
    // A sort, and builders with a result far larger than their words.
    .{ .limit = 50_000, .script = "proc f {} {set l [lrepeat 3000000 x]; lsort $l}; f" },
    .{ .limit = 20_000, .script = "proc f {} {while 1 {string repeat x 4000000}}; f" },
    .{ .limit = 20_000, .script = "proc f {} {while 1 {lrepeat 250000 x}}; f" },
    // A search where each position compares the full needle.
    .{ .limit = 20_000, .script = "proc f {} {set h [string repeat a 4000000]; set n [string repeat a 40000]b; while 1 {string first $n $h}}; f" },
    .{ .limit = 20_000, .script = "proc f {} {set h [string repeat a 4000000]; set n b[string repeat a 40000]; while 1 {string last $n $h}}; f" },
    .{ .limit = 20_000, .script = "proc f {} {set h [string repeat a 200000]; set m {}; for {set i 0} {$i < 400} {incr i} {lappend m [string repeat a 2000]$i x}; while 1 {string map $m $h}}; f" },
    // A long list of traces: each add moved the list, and each run
    // of a trace searched the list.
    .{ .limit = 200_000, .script = "proc f {} {for {set i 0} {$i < 20000} {incr i} {trace add variable ::x write [list list $i]}; while 1 {set ::x 1}}; f" },
};

/// The CPU time of the thread, in nanoseconds.
fn cpuNow() i96 {
    return std.Io.Clock.cpu_thread.now(testing.io).toNanoseconds();
}

test "the step limit bounds the CPU time of each step" {
    // A generous bound: each script stops in under 0.5 s in a Debug
    // build. Before the charges, each script used far more.
    const bound: i96 = 4 * std.time.ns_per_s;
    const want = "error TclError: step limit reached\n";
    for (step_cost_scripts) |s| {
        errdefer std.debug.print("script:\n{s}\n", .{s.script});
        const t0 = cpuNow();
        const ref = try runMode(s.script, false, s.limit, 0);
        defer ref.deinit();
        const used = cpuNow() - t0;
        errdefer std.debug.print("{s}\ncpu: {d} ms\n", .{ ref.text, @divTrunc(used, std.time.ns_per_ms) });
        try testing.expect(std.mem.startsWith(u8, ref.text, want));
        try testing.expect(used <= bound);
        if (!jit.built) continue;
        for ([_]bool{ false, true }) |t2| {
            test_tier2 = t2;
            defer test_tier2 = false;
            const t1 = cpuNow();
            const got = try runMode(s.script, true, s.limit, 1);
            defer got.deinit();
            const used_jit = cpuNow() - t1;
            try testing.expectEqualStrings(ref.text, got.text);
            try testing.expect(used_jit <= bound);
        }
    }
}

test "tier 2: links, a string bound, break, and continue" {
    try sameT2(
        \\proc up {} { upvar 1 g y; for {set i 0} {$i < 50} {incr i} { incr y } }
        \\proc two {} { set a 0; upvar 0 a b; for {set i 0} {$i < 50} {incr i} { incr a; incr b 2 }; list $a $b }
        \\proc str {} { set n "10"; set s 0; for {set i 0} {$i < $n} {incr i} { incr s $i }; list $s $n }
        \\proc bc {} { set s 0; for {set i 0} {$i < 100} {incr i} { if {$i > 90} { break }; if {$i % 2 == 0} { continue }; incr s $i }; list $s $i }
        \\proc wh {} { set i 0; set s 0; while {$i < 60} { incr i; if {$i == 50} { break }; set s [expr {$s + $i * 2 - 1}] }; list $i $s }
        \\proc lk {mode} { if {$mode} { upvar 1 g x } else { set x 0 }; for {set i 0} {$i < 50} {incr i} { incr x }; return $x }
        \\set g 5; list [up] $g [two] [str] [bc] [wh] [lk 0] [lk 1] [lk 0] [lk 1] $g
    , 1);
}

test "tier 2: a loop that exits in each pass is dropped after 8 exits" {
    try sameT2(
        \\proc f {} { set m 9223372036854775806; incr m; set s $m; set k 0; for {set i 0} {$i < 100} {incr i} { set s [expr {$s + 1}]; incr k; set s $m }; list $s $k }
        \\f
    , 1);
    try testing.expectEqual(@as(u64, jit.max_exits), last_exits);
}

test "tier 2: forced exits at each guard write each register and stack place" {
    test_stress = jit.stress_guards;
    defer test_stress = 0;
    try sameT2(
        \\proc regs {} {
        \\  set a 1; set b 2; set c 3; set d 4
        \\  for {set i 0} {$i < 200} {incr i} {
        \\    set a [expr {$a + $b * $c}]
        \\    set c [expr {$c - $d}]
        \\    incr b; incr c 2; incr d -1
        \\    if {$a > 1000000} { set a [expr {$a - 999999}] }
        \\  }
        \\  list $a $b $c $d $i
        \\}
        \\proc places {} {
        \\  set a 1; set b 2; set c 3
        \\  for {set i 0} {$i < 200} {incr i} {
        \\    set a [expr {$a + ($b * ($c - $i))}]
        \\    incr b; incr c 2
        \\    if {$a > 1000000} { set a [expr {$a - 999999}] }
        \\  }
        \\  list $a $b $c $i
        \\}
        \\list [regs] [places]
    , 2);
    try sameT2(sum_script, 1);
}

test "tier 2: a callee changes a local of the loop through upvar in pass 500" {
    try sameT2(
        \\proc poke {} { upvar 1 s s n n; incr s 1000; set n 700 }
        \\proc f {} { set s 0; set n 900; for {set i 0} {$i < $n} {incr i} { incr s $i; if {$i == 500} { poke } }; list $s $n $i }
        \\f
    , 1);
}

test "tier 2: a callee adds a trace to a loop variable" {
    try sameT2(
        \\proc tr {args} { global hits; incr hits }
        \\proc add {} { uplevel 1 { trace add variable s write tr } }
        \\proc f {} { set s 0; for {set i 0} {$i < 300} {incr i} { incr s $i; if {$i == 100} { add } }; list $s $i }
        \\set hits 0; list [f] $hits
    , 1);
}

test "tier 2: a callee renames incr" {
    try sameT2(
        \\proc ren {} { rename incr real_incr; proc incr {v {by 1}} { upvar 1 $v x; set x [expr {$x + $by + 1}] } }
        \\proc f {} { set s 0; for {set i 0} {$i < 300} {incr i} { incr s; if {$i == 100} { ren } }; list $s $i }
        \\f
    , 1);
}

test "tier 2: a callee makes a loop variable an array" {
    try sameT2(
        \\proc arr {} { uplevel 1 { unset s; array set s {a 1} } }
        \\proc f {} { set s 0; set r {}; for {set i 0} {$i < 300} {incr i} { if {$i == 150} { arr; break }; incr s $i }; list [array get s] $i }
        \\proc g {} { set s 0; for {set i 0} {$i < 300} {incr i} { if {$i == 150} { arr }; incr s $i } }
        \\list [f] [catch g msg] $msg
    , 1);
}

test "tier 2: a callee links two loop variables with upvar 0" {
    try sameT2(
        \\proc link {} { uplevel 1 { unset b; upvar 0 a b } }
        \\proc f {} { set a 0; set b 0; for {set i 0} {$i < 300} {incr i} { incr a; incr b 2; if {$i == 120} { link } }; list $a $b $i }
        \\f
    , 1);
}

test "tier 2: a callee raises an error and errorInfo is equal" {
    try sameT2(
        \\proc bad {i} { if {$i == 250} { error "bad pass $i" } }
        \\proc f {} { set s 0; for {set i 0} {$i < 300} {incr i} { incr s $i; bad $i }; set s }
        \\proc g {} { set s 0; for {set i 0} {$i < 300} {incr i} { incr s $i; if {[catch {bad $i} m]} { lappend r $m } }; list $s $r }
        \\list [catch f msg] $msg [g]
    , 1);
}

test "tier 2: foreach over integers with one string in the middle" {
    try sameT2(
        \\proc f {} { set l {}; for {set i 0} {$i < 400} {incr i} { lappend l $i }; lset l 200 abc; set s 0; set t {}; foreach x $l { if {[string is integer $x]} { incr s $x } else { lappend t $x } }; list $s $t }
        \\proc g {} { set l {}; for {set i 0} {$i < 400} {incr i} { lappend l $i }; lset l 200 abc; set s 0; foreach x $l { incr s [string length $x] }; set s }
        \\proc h {} { set l {}; for {set i 0} {$i < 400} {incr i} { lappend l $i }; lset l 200 7.5; set s 0; foreach {x y} $l { set s [expr {$s + $x - $y}] }; set s }
        \\list [f] [g] [h]
    , 3);
}

/// `stalelink name`: makes the variable `name` of the caller a link to
/// the global `g`, and writes the tag and the payload of the integer 7
/// to the bytes of the cell after the link. Only a check of the tag of
/// the cell finds the link.
fn staleLink(it: *Interp, argv: []const Value, _: ?*tcl.interp.Cmd) tcl.interp.Error!Value {
    const l = layout.probe().?;
    const name = try it.str(argv[1]);
    const target = try it.globalVar("g");
    for (it.frame.vars.items) |e| if (std.mem.eql(u8, e.name, name)) {
        e.cell.v = .{ .link = target };
        const bytes: [*]u8 = @ptrCast(e.cell);
        bytes[l.var_payload + l.value_tag] = l.tag_int;
        if (l.value_payload != 0) std.mem.writeInt(i64, bytes[l.var_payload + l.value_payload ..][0..8], 7, .little);
        return Value.empty;
    };
    return it.fail("no variable", .{});
}

test "tier 2: the entry checks that a slot is not a link" {
    // The loop compiles with `x` as a plain cell. In the later calls,
    // `x` is a link whose bytes after the pointer look like an integer.
    test_native = .{ "stalelink", staleLink };
    defer test_native = null;
    try sameT2(
        \\proc lk {mode} { set x 5; if {$mode} { unset x; stalelink x }; for {set i 0} {$i < 50} {incr i} { incr x }; return $x }
        \\set g 1000; list [lk 0] [lk 1] [lk 1] [lk 0] [lk 1] $g
    , 1);
}

test "tier 2: the loops of nested.tcl and foreach.tcl compile" {
    for ([_][*:0]const u8{ "bench/nested.tcl", "bench/foreach.tcl" }) |path| {
        const text = try readRepoFile(testing.allocator, path);
        defer testing.allocator.free(text);
        try sameT2(text, 1);
    }
}

test "tier 2: loops of doubles give the bits of the interpreter" {
    try sameT2(
        \\proc dsum {n} { set s 0.0; set x [expr {1.5}]; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $x * 0.5}] }; return $s }
        \\proc mix {} { set s [expr {0.1}]; set t [expr {-0.0}]; for {set i 0} {$i < 200} {incr i} { set s [expr {$s * 1.1 + $i / 3.0 - 0.1}]; set t [expr {$t * 1.0}] }; list $s $t [expr {1.0 / $t}] }
        \\proc div {} { set z [expr {0.0}]; set r {}; for {set i -2} {$i < 3} {incr i} { set q [expr {$i / $z}]; lappend r $q }; return $r }
        \\proc cmp {} { set a [expr {0.5}]; set n 0; for {set i 0} {$i < 100} {incr i} { if {$a < $i} { incr n }; if {$i == $a * 2} { incr n 100 }; set a [expr {$a + 0.25}] }; list $n $a }
        \\proc big {} { set s [expr {1e300}]; for {set i 0} {$i < 50} {incr i} { set s [expr {$s * 10.0}] }; set s }
        \\proc prec {} { set s [expr {0.1}]; for {set i 0} {$i < 30} {incr i} { set s [expr {$s + 0.1}] }; set ::tcl_precision 6; set r [list $s]; set ::tcl_precision 0; lappend r $s }
        \\list [dsum 300] [mix] [div] [cmp] [big] [prec] [expr {5e-324 * 1.0}]
    , 6);
}

test "tier 2: a NaN result exits, and its use as an operand is the error of the interpreter" {
    try sameT2(
        \\proc infs {} { set a [expr {1e290}]; set s [expr {0.0}]; for {set i 0} {$i < 100} {incr i} { set a [expr {$a * 10.0}]; set s [expr {$a - $a}] }; set s }
        \\proc nan2 {} { set a [expr {1e290}]; set s [expr {0.0}]; set k 0; for {set i 0} {$i < 100} {incr i} { set a [expr {$a * 10.0}]; set s [expr {$a - $a}]; set s [expr {$s + 1.0}]; incr k }; list $s $k }
        \\proc zz {} { set z [expr {0.0}]; set q 1; for {set i 0} {$i < 50} {incr i} { set q [expr {$z / $z}] }; set q }
        \\list [catch infs m] $m [catch nan2 m] $m $::errorCode [catch zz m] $m
    , 3);
}

test "tier 2: forced exits with doubles in registers and places" {
    test_stress = jit.stress_guards;
    defer test_stress = 0;
    try sameT2(
        \\proc f {} {
        \\  set a [expr {1.0}]; set b [expr {2.5}]; set c [expr {-3.25}]; set n 0
        \\  for {set i 0} {$i < 300} {incr i} {
        \\    set a [expr {$a + ($b - $c) * ($a - $i)}]
        \\    set b [expr {$b * 0.999 + $i}]
        \\    if {$a > 1e6 || $a < -1e6} { set a [expr {$a / 1000.0}] }
        \\    set c [expr {$c - $a / ($b + 1.5)}]
        \\    incr n
        \\  }
        \\  list $a $b $c $n
        \\}
        \\f
    , 1);
}

test "tier 2: a double slot that a callee changes to a string" {
    try sameT2(
        \\proc poke {} { upvar 1 s s; set s abc }
        \\proc f {} { set s [expr {1.0}]; for {set i 0} {$i < 300} {incr i} { if {$i == 100} { poke; set s [expr {2.0}] }; set s [expr {$s * 1.5 - $i}] }; set s }
        \\f
    , 1);
}

test "tier 2: the entry checks that a double slot is not a NaN" {
    // The loop compiles with a finite `s`. The second call enters the
    // compiled loop with a NaN in `s`, and its use is an error.
    try sameT2(
        \\proc f {s} { set t [expr {0.0}]; for {set i 0} {$i < 20} {incr i} { set t [expr {$s * 2.0}] }; return $t }
        \\set inf [expr {1e300 * 1e300}]
        \\list [f [expr {1.5}]] [catch {f [expr {$inf - $inf}]} m] $m
    , 1);
}

test "tier 2: incr and jumps on values from helpers check the tag" {
    // Item 200 is the string "12", and item 150 makes the sum pass the
    // largest integer. A flag "no" is a string that is false.
    try sameT2(
        \\proc f {} { set l {}; for {set i 0} {$i < 300} {incr i} { lappend l $i }; lset l 150 9223372036854775000; lset l 200 [string range x12 1 end]; set s 0; for {set i 0} {$i < 300} {incr i} { incr s [lindex $l $i] }; set s }
        \\proc g {} { set f {}; for {set i 0} {$i < 300} {incr i} { lappend f [expr {$i % 3 == 0 ? "no" : ($i % 3 == 1 ? 0 : 1)}] }; set n 0; for {set i 0} {$i < 300} {incr i} { if {[lindex $f $i]} { incr n } }; set n }
        \\list [f] [g]
    , 2);
}

test "tier 2: an exit after a helper that runs no script writes the slots" {
    // concat runs no script, so the slot registers stay on the native
    // stack across it. Each forced exit after it must write `i` and `n`.
    test_stress = jit.stress_guards;
    defer test_stress = 0;
    try sameT2(
        \\proc f {} { set n 0; set r {}; for {set i 0} {$i < 200} {incr i} { set k key$i; incr n 3; if {$i % 50 == 0} { lappend r $k } }; list $n $i $r }
        \\f
    , 1);
}

// ---- The shared layer of tier 2: no machine code ----

const lower = @import("tier2_lower.zig");

/// The plan of loop `nth` of proc `name`, with the kinds of `entry` by
/// slot name and `.any` for each other slot. Checks `eligible` with the
/// budgets of x86-64 and arm64 against `want`.
fn lowerCheck(it: *Interp, name: []const u8, nth: usize, entry: []const struct { []const u8, tier2.Kind }, want: bool) !void {
    const code = try procCode(it, name);
    var info = (try verify.verify(testing.allocator, code)) orelse return error.NotVerified;
    defer info.deinit(testing.allocator);
    const kinds = try testing.allocator.alloc(tier2.Kind, code.names.len);
    defer testing.allocator.free(kinds);
    @memset(kinds, .any);
    for (entry) |e| for (code.names, 0..) |n, k| if (std.mem.eql(u8, n, e[0])) {
        kinds[k] = e[1];
    };
    if (nth >= info.loop_heads.len) {
        std.debug.print("{s}: {d} instructions, loop heads {any}\n", .{ name, code.ins.len, info.loop_heads });
        return error.NoLoop;
    }
    var p = (try tier2.plan(testing.allocator, code, &info, info.loop_heads[nth], kinds)) orelse return error.NoPlan;
    defer p.deinit();
    try testing.expectEqual(want, lower.eligible(code, &info, &p, lower.x64_budget));
    try testing.expectEqual(want, lower.eligible(code, &info, &p, lower.a64_budget));
}

test "tier 2 layer: the loops of the benchmarks fit both budgets" {
    const it = try newInterp();
    defer freeInterp(it);
    // A proc body points into its text, so each text lives to the end.
    var texts: [4][]u8 = undefined;
    for ([_][*:0]const u8{ "bench/sum.tcl", "bench/nested.tcl", "bench/foreach.tcl", "bench/dsum.tcl" }, &texts) |path, *t| {
        t.* = try readRepoFile(testing.allocator, path);
        try defineProcs(it, t.*);
    }
    defer for (texts) |t| testing.allocator.free(t);
    try lowerCheck(it, "sum", 0, &.{ .{ "i", .int }, .{ "s", .int }, .{ "n", .int } }, true);
    try lowerCheck(it, "nested", 1, &.{ .{ "i", .int }, .{ "j", .int }, .{ "m", .int }, .{ "n", .int } }, true);
    try lowerCheck(it, "go", 2, &.{ .{ "x", .int }, .{ "s", .int } }, true);
    try lowerCheck(it, "dsum", 0, &.{ .{ "i", .int }, .{ "n", .int }, .{ "s", .double }, .{ "x", .double } }, true);
    // Six integer slots do not fit five registers.
    try defineProcs(it,
        \\proc six {} { set a 0; set b 0; set c 0; set d 0; set e 0; for {set i 0} {$i < 9} {incr i} { incr a; incr b; incr c; incr d; incr e } }
        \\proc five {} { set a 0; set b 0; set c 0; set d 0; set e 0; for {set i 0} {$i < 9} {incr i} { incr a; incr b; incr c; incr d } }
        \\proc dbl {} { for {set i 0} {$i < 9} {incr i} { set a [expr {$a + $b * $c - $d / $e}] } }
    );
    try lowerCheck(it, "six", 0, &.{ .{ "a", .int }, .{ "b", .int }, .{ "c", .int }, .{ "d", .int }, .{ "e", .int }, .{ "i", .int } }, false);
    try lowerCheck(it, "five", 0, &.{ .{ "a", .int }, .{ "b", .int }, .{ "c", .int }, .{ "d", .int }, .{ "e", .int }, .{ "i", .int } }, true);
    // Five double slots do not fit four registers.
    try lowerCheck(it, "dbl", 0, &.{ .{ "a", .double }, .{ "b", .double }, .{ "c", .double }, .{ "d", .double }, .{ "e", .double }, .{ "i", .int } }, false);
}

test "tier 2 layer: the step checks and the steps that an exit gives back" {
    const it = try newInterp();
    defer freeInterp(it);
    const text = try readRepoFile(testing.allocator, "bench/sum.tcl");
    defer testing.allocator.free(text);
    try defineProcs(it, text);
    var p = (try planOf(it, "sum", &.{ .{ "i", .int }, .{ "s", .int }, .{ "n", .int } })).?;
    defer p.deinit();
    const code = try procCode(it, "sum");
    const left = try lower.stepsLeft(testing.allocator, code, &p);
    defer testing.allocator.free(left);
    // The loop: jf_vv | step guard guard bin_vv store_pop guard incr_drop jump.
    try testing.expectEqualSlices(u32, &.{ 0, 4, 3, 2, 1, 1, 1, 0, 0 }, left);
    try testing.expectEqual(p.head + 1, lower.checkAt(code, p.parts[1]));
    try testing.expectEqual(lower.SlotClass.int, lower.slotClass(p.slots[0]));
}

test "tier 2 layer: an if with no else writes its place to the value stack" {
    const it = try newInterp();
    defer freeInterp(it);
    try defineProcs(it,
        \\proc f {} { set a 0; for {set i 0} {$i < 9} {incr i} { if {$i > 4} { set a $i } } }
    );
    var p = (try planOf(it, "f", &.{ .{ "a", .int }, .{ "i", .int } })).?;
    defer p.deinit();
    const code = try procCode(it, "f");
    var fixes: usize = 0;
    for (p.head..p.back + 1) |pc| {
        const k = pc - p.head;
        if (!p.seen[k]) continue;
        const i = code.ins[pc];
        if (lower.falls(i.op) and pc < p.back and lower.needsFix(&p, @intCast(pc), @intCast(pc + 1))) fixes += 1;
        if (tier2.targetOf(i)) |t| if (i.op != .guard and t > pc and t <= p.back and lower.needsFix(&p, @intCast(pc), t)) {
            fixes += 1;
        };
    }
    try testing.expectEqual(@as(usize, 1), fixes);
}

test "tier 2 layer: the results of doubles that need no NaN check" {
    const lit = lower.knownOf(0.5);
    const zero = lower.knownOf(0.0);
    const inf = lower.knownOf(std.math.inf(f64));
    const int: lower.Known = .{ .finite = true };
    const reg: lower.Known = .{};
    try testing.expect(lower.nanFree(.add, reg, int));
    try testing.expect(lower.nanFree(.sub, lit, reg));
    try testing.expect(!lower.nanFree(.add, reg, reg));
    try testing.expect(!lower.nanFree(.add, reg, inf));
    try testing.expect(lower.nanFree(.mul, reg, lit));
    try testing.expect(lower.nanFree(.div, lit, reg));
    try testing.expect(!lower.nanFree(.mul, reg, int));
    try testing.expect(!lower.nanFree(.mul, reg, zero));
    try testing.expect(!lower.nanFree(.div, reg, zero));
    try testing.expect(!lower.nanFree(.div, reg, reg));
    // Each case that the rule calls free gives no NaN for any operand
    // that is not a NaN.
    const xs = [_]f64{ 0.0, -0.0, 1.5, -2.0, 1e308, -1e308, std.math.inf(f64), -std.math.inf(f64), 5e-324 };
    for ([_]expr_mod.BinOp{ .add, .sub, .mul, .div }) |op| for (xs) |x| for (xs) |y| {
        const kx: lower.Known = .{};
        const ky = lower.knownOf(y);
        if (!lower.nanFree(op, kx, ky)) continue;
        const r = switch (op) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
            else => x / y,
        };
        try testing.expect(!std.math.isNan(r));
    };
}

const expr_mod = @import("../expr.zig");

test "tier 2: to_bool of a value from a helper goes to its register" {
    // `||` of two string compares: the second compare is a helper call,
    // and to_bool of its result feeds a jump.
    try sameT2(
        \\proc cut {line limit cutoff} { set r {}; while {[string length $line] > $limit} { for {set c [expr {$limit-1}]} {$c >= $cutoff} {incr c -1} { set char [string index $line $c]; if {$char == " " || $char == "\t"} { break } }; lappend r $c; incr c; set line [string range $line $c end] }; return $r }
        \\set s "so we hope to have only a single beta release and to go final in early October, 1996. and more words here to cut again"
        \\list [cut $s 56 50] [cut $s 56 50] [cut $s 56 50] [cut $s 30 20]
    , 1);
}
test "jit: each stress mode gives the output of the interpreter" {
    if (!jit.built) return error.SkipZigTest;
    const scripts = [_][]const u8{
        \\proc f {n} { set s 0; for {set i 0} {$i < $n} {incr i} { if {$i % 3 == 0} continue; incr s $i; if {$s > 400} break }; return $s }
        \\proc g {l} { set r {}; foreach {a b} $l { lappend r [expr {$a * $b}] }; return $r }
        \\proc h {} { catch {error boom} m; set d {}; dict set d k [f 30]; return [list $m $d [g {1 2 3 4 5}]] }
        \\list [f 50] [g {1 2 3 4}] [h] [f 10]
        ,
        \\proc e {x} { if {$x > 2} { error "big $x" }; return [expr {$x + 1}] }
        \\proc c {} { set r {}; for {set i 0} {$i < 5} {incr i} { lappend r [catch {e $i} m] $m }; return $r }
        \\c; c
    };
    const modes = [_]u32{ jit.stress_alloc, jit.stress_region, jit.stress_sum, jit.stress_entry, jit.stress_small, jit.stress_all };
    for (scripts) |script| {
        const ref = try runModeOpts(script, null, std.math.maxInt(u64), 0, 0);
        defer ref.deinit();
        for (modes) |m| {
            for ([_]u32{ 0, 2 }) |threshold| for ([_]bool{ false, true }) |t2| {
                const got = try runModeOpts(script, .{ .threshold = threshold, .stress = m, .tier2 = t2, .tier2_count = 2 }, std.math.maxInt(u64), 0, 0);
                defer got.deinit();
                testing.expectEqualStrings(ref.text, got.text) catch |e| {
                    std.debug.print("stress {d}, threshold {d}, tier 2 {}, script:\n{s}\n", .{ m, threshold, t2, script });
                    return e;
                };
            };
        }
    }
}

test "jit: stress mode 1 fails each allocation of the compiler in turn" {
    if (!jit.built) return error.SkipZigTest;
    const it = try newInterp();
    defer freeInterp(it);
    if (!it.enableJit(.{ .threshold = 0, .stress = jit.stress_alloc })) return error.SkipZigTest;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..40) |k| try text.print(testing.allocator, "proc p{d} {{x}} {{ set s 0; for {{set i 0}} {{$i < $x}} {{incr i}} {{ incr s $i }}; return $s }}; p{d} 5\n", .{ k, k });
    _ = try it.eval(text.items);
    const st = it.jit.?.stats;
    // The first compiles fail, then one passes, and the count starts again.
    try testing.expect(st.failed > 0);
    try testing.expect(st.compiled > 0);
    try testing.expectEqual(@as(u64, 40), st.failed + st.compiled);
}

test "jit: stress mode 1 fails the allocations of tier 2 compiles in turn" {
    if (!jit.built) return error.SkipZigTest;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..40) |k| try text.print(testing.allocator, "proc p{d} {{x}} {{ set s 0; for {{set i 0}} {{$i < $x}} {{incr i}} {{ incr s $i }}; return $s }}; lappend r [p{d} 5]\n", .{ k, k });
    try text.appendSlice(testing.allocator, "set r");
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);
    for (0..40) |k| try want.appendSlice(testing.allocator, if (k == 0) "10" else " 10");
    // Each loop of a function that compiled can compile to tier 2, so
    // a loop that stays in tier 1 had a failed allocation.
    var compiled: u64 = 0;
    var tier2_loops: u64 = 0;
    for (1..64) |from| {
        const it = try newInterp();
        defer freeInterp(it);
        if (!it.enableJit(.{ .threshold = 0, .tier2 = true, .tier2_count = 1, .stress = jit.stress_alloc, .fail_from = @intCast(from) })) return error.SkipZigTest;
        const v = try it.eval(text.items);
        try testing.expectEqualStrings(want.items, try it.str(v));
        compiled += it.jit.?.stats.compiled;
        tier2_loops += it.jit.?.stats.tier2;
    }
    try testing.expect(tier2_loops > 0);
    try testing.expect(tier2_loops < compiled);
}

test "jit: stress mode 4 keeps a checksum of the code of tier 2" {
    if (!jit.built) return error.SkipZigTest;
    const it = try newInterp();
    defer freeInterp(it);
    if (!it.enableJit(.{ .threshold = 0, .tier2 = true, .tier2_count = 1, .stress = jit.stress_sum })) return error.SkipZigTest;
    const v = try it.eval("proc f {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s $i }; return $s }; f 10; f 20");
    try testing.expectEqual(@as(i64, 190), v.asInt().?);
    const code = it.commands.get("f").?.impl.proc.code orelse return error.NoCode;
    const f: *tier1.Fn = @ptrCast(@alignCast(code.jit orelse return error.NotCompiled));
    try testing.expectEqual(@as(usize, 1), f.loops.len);
    const rec = f.loops[0];
    const c = rec.code orelse return error.NoTier2;
    try testing.expect(rec.len > 0);
    try testing.expectEqual(std.hash.Wyhash.hash(0, c[0..rec.len]), rec.sum);
}

test "jit: stress mode 8 enters at each address of a loop" {
    if (!jit.built) return error.SkipZigTest;
    try sameStress(
        \\proc f {n} { set s {}; for {set i 0} {$i < $n} {incr i} { lappend s [expr {$i * 2}]; if {$i == 3} continue }; foreach x $s { incr t $x }; return [list $s $t] }
        \\f 8
    , jit.stress_entry);
}

fn sameStress(script: []const u8, stress: u32) !void {
    const ref = try runModeOpts(script, null, std.math.maxInt(u64), 0, 0);
    defer ref.deinit();
    const got = try runModeOpts(script, .{ .threshold = 0, .stress = stress }, std.math.maxInt(u64), 1, 0);
    defer got.deinit();
    try testing.expectEqualStrings(ref.text, got.text);
}

// ---- The hardening tests ----

const abi = @import("abi.zig");
const tier1 = @import("tier1.zig");

test "hardening: enter runs exec for each entry that fails a check" {
    if (!jit.built) return error.SkipZigTest;
    const it = try newInterp();
    defer freeInterp(it);
    it.gc_on = false;
    if (!it.enableJit(.{ .threshold = 0 })) return error.SkipZigTest;
    try defineProcs(it, base_proc);
    // A copy with one more instruction after the last `ret`. No path
    // reaches it, so it has no code.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const orig = try procCode(it, "f");
    var m = try Mutable.init(arena.allocator(), orig);
    const ins = try arena.allocator().alloc(vm.Ins, m.ins.len + 1);
    @memcpy(ins[0..m.ins.len], m.ins);
    ins[m.ins.len] = .{ .op = .push_empty };
    m.code.ins = ins;
    const code = &m.code;
    try testing.expect(code.names.len > 0);
    const f = jit.prepare(it, code) orelse return error.NoCompile;
    const stack = try testing.allocator.alloc(Value, code.max_stack);
    defer testing.allocator.free(stack);
    // An instruction with no code.
    const dead: u32 = for (f.entries, 0..) |e, k| {
        if (e == tier1.no_entry) break @intCast(k);
    } else return error.NoDeadInstruction;
    const Case = struct { pc: u32, sp: u32 };
    const cases = [_]Case{
        .{ .pc = @intCast(code.ins.len), .sp = 0 },
        .{ .pc = std.math.maxInt(u32), .sp = 0 },
        .{ .pc = dead, .sp = f.depth[dead] },
        .{ .pc = 0, .sp = 1 },
        // The global frame has fewer cells than the names of `f`.
        .{ .pc = 0, .sp = 0 },
    };
    try testing.expect(it.frame.vars.items.len < code.names.len);
    for (cases) |c| {
        var pc = c.pc;
        var sp = c.sp;
        const before = it.jit.?.stats.fallbacks;
        try testing.expectEqual(jit.Status.fallback, jit.enter(it, f, code, stack.ptr, &pc, &sp));
        try testing.expectEqual(before + 1, it.jit.?.stats.fallbacks);
        try testing.expectEqual(c.pc, pc);
        try testing.expectEqual(c.sp, sp);
    }
}

test "hardening: one proc in two regions gives the same bytes" {
    if (!jit.built) return error.SkipZigTest;
    const it = try newInterp();
    defer freeInterp(it);
    try defineProcs(it, base_proc);
    const code = try procCode(it, "f");
    const l = layout.probe() orelse return error.SkipZigTest;
    var r1 = mem.Region.init(1 << 20) orelse return error.SkipZigTest;
    defer r1.deinit();
    var r2 = mem.Region.init(1 << 20) orelse return error.SkipZigTest;
    defer r2.deinit();
    // The second region has a function before this one.
    _ = r2.append(&[_]u8{0xC3}) orelse return error.NoAppend;
    const f1 = switch (tier1.compile(testing.allocator, &r1, l, code, 1 << 20, 0)) {
        .ok => |f| f,
        else => return error.NoCompile,
    };
    defer f1.free(testing.allocator);
    const f2 = switch (tier1.compile(testing.allocator, &r2, l, code, 1 << 20, 0)) {
        .ok => |f| f,
        else => return error.NoCompile,
    };
    defer f2.free(testing.allocator);
    try testing.expect(f1.base != f2.base);
    try testing.expectEqualSlices(u8, f1.base[0..f1.len], f2.base[0..f2.len]);
}

test "hardening: the JIT frame is at most 64 bytes" {
    if (!jit.built) return error.SkipZigTest;
    try testing.expect(abi.frame_bytes <= 64);
    // The prologue: push rbp, mov rbp rsp, five pushes of the pinned
    // registers, and the push of the context. With the return address
    // that is `frame_bytes`, and the stack pointer is 16-byte aligned
    // at each call.
    const it = try newInterp();
    defer freeInterp(it);
    if (!it.enableJit(.{ .threshold = 0 })) return error.SkipZigTest;
    try defineProcs(it, base_proc);
    const code = try procCode(it, "f");
    const f = jit.prepare(it, code) orelse return error.NoCompile;
    const want = [_]u8{ 0x55, 0x48, 0x89, 0xE5, 0x53, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x57 };
    try testing.expectEqualSlices(u8, &want, f.base[0..want.len]);
    const pushes = 1 + abi.saved.len + 1;
    try testing.expectEqual(abi.frame_bytes, 8 + 8 * pushes);
    try testing.expectEqual(@as(usize, 0), abi.frame_bytes % 16);
    try testing.expectEqual(@as(i32, -8 * (1 + @as(i32, abi.saved.len))), abi.ctx_slot);
}

/// True when an address is inside a mapping of /proc/self/maps.
fn mapped(addr: usize) !bool {
    const text = try readMaps(testing.allocator);
    defer testing.allocator.free(text);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const range = line[0..sp];
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const start = try std.fmt.parseInt(usize, range[0..dash], 16);
        const end = try std.fmt.parseInt(usize, range[dash + 1 ..], 16);
        if (addr >= start and addr < end) return true;
    }
    return false;
}

test "hardening: reset, compact, and deinit free the region" {
    if (!jit.built or builtin.os.tag != .linux) return error.SkipZigTest;
    for (0..3) |k| {
        const it = try newInterp();
        var freed = false;
        defer if (!freed) freeInterp(it);
        if (!it.enableJit(.{ .threshold = 0 })) return error.SkipZigTest;
        _ = try it.eval("proc f {n} {set s 0; for {set i 0} {$i < $n} {incr i} {incr s $i}; return $s}; f 10");
        const base = @intFromPtr(it.jit.?.region.?.base);
        try testing.expect(try mapped(base));
        switch (k) {
            0 => try it.reset(),
            1 => try it.compact(&.{}, .{}),
            else => {
                freeInterp(it);
                freed = true;
            },
        }
        try testing.expect(!try mapped(base));
    }
}

test "the verifier checks the rules of a named Code" {
    const it = try newInterp();
    defer freeInterp(it);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sc = try it.compile("set s 0; for {set i 0} {$i < 3} {incr i} { incr s $i }; set s");
    const code = try vm.compileNamed(it, sc);
    try testing.expect(code.named);
    try testing.expect(try verifies(code));
    // One more `ret` at the end: the `ret` of the compiler is then not
    // the last one. The same change passes in a proc body.
    var m = try Mutable.init(a, code);
    const ins = try a.alloc(vm.Ins, m.ins.len + 1);
    @memcpy(ins[0..m.ins.len], m.ins);
    ins[m.ins.len] = .{ .op = .ret };
    m.code.ins = ins;
    try testing.expect(!try verifies(&m.code));
    m.code.named = false;
    try testing.expect(try verifies(&m.code));
    m.code.named = true;
    m.code.ins = m.ins;
    try testing.expect(try verifies(&m.code));
    // Hints of another length.
    m = try Mutable.init(a, code);
    m.code.hints = &.{};
    try testing.expect(!try verifies(&m.code));
}

test "jit: named code compiles and gives the output of the interpreter" {
    try same(
        \\set s 0
        \\for {set i 0} {$i < 20} {incr i} { incr s $i; if {$i == 7} continue; append t $i, }
        \\foreach {a b} {1 2 3 4 5} { lappend l [expr {$a * 2}] $b }
        \\proc up {} { uplevel 1 { for {set k 0} {$k < 4} {incr k} { incr s 100 } } }
        \\up
        \\namespace eval ns { variable v 0; for {set j 0} {$j < 5} {incr j} { incr v $j } }
        \\apply {{} { set w 0; while {$w < 6} { incr w } ; return $w }}
        \\set e {}; for {set r 0} {$r < 50} {incr r} { eval {incr e2; lappend e $r} }
        \\list $s $t $l $ns::v $e2 [llength $e] [catch {for {set x 0} {$x < 3} {incr x} { error boom$x }} m] $m
    , 2);
}

test "jit: named code stays in tier 1 with tier 2 on" {
    // Tier 2 reads each slot from its cell in the frame. A named Code
    // reads each variable by its name, and runs in any frame. Its slot
    // numbers name other cells in the frame of `p`. The loop of `p`
    // itself can compile to tier 2.
    test_tier2 = true;
    defer test_tier2 = false;
    const script =
        \\proc p {} {
        \\    set a 5; set b 7; set c 9
        \\    set body { set s 0; for {set i 0} {$i < 400} {incr i} { incr s $i } }
        \\    for {set r 0} {$r < 20} {incr r} { uplevel 0 $body }
        \\    list $a $b $c $s $i
        \\}
        \\set body2 { set t 0; for {set j 0} {$j < 400} {incr j} { incr t 2 } }
        \\for {set r 0} {$r < 20} {incr r} { eval $body2 }
        \\list [p] $t $j
    ;
    try same(script, 2);
    test_stress = jit.stress_guards | jit.stress_entry;
    defer test_stress = 0;
    try same(script, 2);
}

var event_ticks: i64 = 0;

fn eventNow(_: ?*anyopaque) i64 {
    return event_ticks;
}

fn eventSleep(_: ?*anyopaque, micros: i64) void {
    event_ticks += micros;
}

test "jit: named code of events stays in its part of the JIT memory" {
    if (!jit.built) return error.SkipZigTest;
    const it = try newInterp();
    defer freeInterp(it);
    it.gc_on = false;
    try it.allow(@intFromEnum(tcl.interp.Capability.event));
    event_ticks = 0;
    it.event_host = .{ .now = eventNow, .sleep = eventSleep };
    if (!it.enableJit(.{})) return error.SkipZigTest;
    // Each event parses its script again, so the body and the step of
    // the loop are new named Code values that each run three times.
    _ = try it.eval(
        \\set n 0
        \\set script {incr n; for {set i 0} {$i < 3} {incr i} {incr t}; if {$n < 10000} { after 0 $script } else { set done 1 }}
        \\after 0 $script
        \\vwait done
    );
    const s = it.jit.?;
    try testing.expect(s.stats.named_bytes > 0);
    try testing.expect(s.stats.named_stops > 0);
    try testing.expect(s.named_used <= s.options.mem_limit / 4);
    try testing.expect(s.used < s.options.mem_limit / 2);
    // A proc defined after the events still compiles.
    const before = s.stats.compiled;
    const v = try it.eval("proc f {n} {set t 0; for {set i 0} {$i < $n} {incr i} {incr t $i}; return $t}; f 10");
    try testing.expectEqual(@as(i64, 45), v.asInt().?);
    try testing.expectEqual(before + 1, s.stats.compiled);
}

test "tier 2: a conditional jump back stays in tier 1" {
    if (!jit.built) return error.SkipZigTest;
    // The jit-fuzz --verify mode found it: `store_pop` changed to
    // `jump_false` makes a loop with no `jump` back. Tier 2 then ran
    // into the trap after the last instruction of the loop.
    const it = try newInterp();
    defer freeInterp(it);
    it.gc_on = false;
    if (!it.enableJit(.{ .threshold = 0, .tier2 = true, .tier2_count = 1 })) return error.SkipZigTest;
    _ = try it.eval("proc q {} { set a 1; set b 2; set c 0; return $c }");
    const code = try procCode(it, "q");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var m = try Mutable.init(arena.allocator(), code);
    // The `push` of `set b 2`, and the `store_pop` of `set c 0`.
    var stores: [3]usize = undefined;
    var n: usize = 0;
    for (m.ins, 0..) |i, k| if (i.op == .store_pop and n < 3) {
        stores[n] = k;
        n += 1;
    };
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(vm.Op.push, m.ins[stores[0] + 2].op);
    m.ins[stores[2]] = .{ .op = .jump_false, .a = @intCast(stores[0] + 2) };
    try testing.expect(try verifies(&m.code));
    var info = (try verify.verify(testing.allocator, &m.code)).?;
    defer info.deinit(testing.allocator);
    const kinds = try testing.allocator.alloc(tier2.Kind, m.code.names.len);
    defer testing.allocator.free(kinds);
    @memset(kinds, .int);
    try testing.expectEqual(@as(usize, 1), info.loop_heads.len);
    try testing.expect((try tier2.plan(testing.allocator, &m.code, &info, info.loop_heads[0], kinds)) == null);
    // The changed Code runs in tier 1 until the step limit.
    const held = try arena.allocator().create(vm.Code);
    held.* = m.code;
    _ = jit.prepare(it, held) orelse return error.NotCompiled;
    const p = it.commands.get("q").?.impl.proc;
    const saved = p.code;
    p.code = held;
    defer p.code = saved;
    it.step_limit = 2000;
    try testing.expectError(error.TclError, it.eval("q"));
    try testing.expectEqual(@as(u64, 0), it.jit.?.stats.tier2);
}

test "tier 2: an exit at the loop head lets tier 1 take a step" {
    if (!jit.built) return error.SkipZigTest;
    // The jit-fuzz --verify mode found it: a changed Code with the loop
    // `guard; jump` at address 0. With the step limit below the steps
    // of a pass, tier 2 exits to the loop head. The pass counter of
    // tier 1 then called `tier_up` before the step check of the head,
    // and the two tiers went back and forth with no step.
    const it = try newInterp();
    defer freeInterp(it);
    it.gc_on = false;
    if (!it.enableJit(.{ .threshold = 0, .tier2 = true, .tier2_count = 1 })) return error.SkipZigTest;
    _ = try it.eval("proc q {} { set a 1; set b 2; return $a }");
    // A first call runs the guard, so the epoch of the guard is current.
    _ = try it.eval("q");
    const code = try procCode(it, "q");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var m = try Mutable.init(arena.allocator(), code);
    try testing.expectEqual(vm.Op.guard, m.ins[0].op);
    m.ins[1] = .{ .op = .jump, .a = 0 };
    try testing.expect(try verifies(&m.code));
    const held = try arena.allocator().create(vm.Code);
    held.* = m.code;
    _ = jit.prepare(it, held) orelse return error.NotCompiled;
    const p = it.commands.get("q").?.impl.proc;
    const saved = p.code;
    p.code = held;
    defer p.code = saved;
    it.step_limit = 2000;
    try testing.expectError(error.TclError, it.eval("q"));
    try testing.expectEqualStrings("step limit reached", try it.str(it.result));
    try testing.expectEqual(@as(u64, 1), it.jit.?.stats.tier2);
}

const dead_part_proc = "proc f {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s; continue; incr s 5 }; return $s }";

test "tier 2 layer: a part that no path from the head reaches has no step check" {
    // The commands after `continue` run only on the cold path of the
    // guard of `continue`, and tier 2 has no such path. Their part has
    // no kinds, so it must not count steps or have a step check.
    const it = try newInterp();
    defer freeInterp(it);
    try defineProcs(it, dead_part_proc);
    var p = (try planOf(it, "f", &.{ .{ "i", .int }, .{ "s", .int }, .{ "n", .int } })).?;
    defer p.deinit();
    const code = try procCode(it, "f");
    const left = try lower.stepsLeft(testing.allocator, code, &p);
    defer testing.allocator.free(left);
    var dead: usize = 0;
    for (p.parts) |pt| {
        if (p.seen[pt.first - p.head]) continue;
        dead += 1;
        try testing.expectEqual(@as(u32, 0), pt.steps);
        for (pt.first..pt.last + 1) |pc| {
            try testing.expectEqual(@as(u32, 0), left[pc - p.head]);
            try testing.expectEqual(@as(usize, 0), p.kinds[pc - p.head].len);
        }
    }
    try testing.expect(dead > 0);
}

test "tier 2: a part that the verifier does not reach compiles and stops at the step limit" {
    if (!jit.built) return error.SkipZigTest;
    // The jit-fuzz --verify --tier2 mode found it. A change made the
    // commands after `continue` unreachable, so the verifier gave them
    // no depth. Tier 2 put a step check on their part, and the exit of
    // that check read the kinds of 65 535 stack places from undefined
    // memory. The compiler then stopped with a general protection fault.
    const it = try newInterp();
    defer freeInterp(it);
    it.gc_on = false;
    if (!it.enableJit(.{ .threshold = 0, .tier2 = true, .tier2_count = 1 })) return error.SkipZigTest;
    _ = try it.eval(dead_part_proc);
    _ = try it.eval("f 3");
    const code = try procCode(it, "f");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var m = try Mutable.init(arena.allocator(), code);
    // The guard of `continue`, before its jump forward.
    const k = for (m.ins, 0..) |i, k| {
        if (k > 0 and i.op == .jump and i.a > k and m.ins[k - 1].op == .guard) break k;
    } else return error.NoContinue;
    m.ins[k - 1] = .{ .op = .step };
    var info = (try verify.verify(testing.allocator, &m.code)).?;
    defer info.deinit(testing.allocator);
    try testing.expect(!info.reachable[k + 2]);
    const held = try arena.allocator().create(vm.Code);
    held.* = m.code;
    _ = jit.prepare(it, held) orelse return error.NotCompiled;
    const p = it.commands.get("f").?.impl.proc;
    const saved = p.code;
    p.code = held;
    defer p.code = saved;
    const before = it.jit.?.stats.tier2;
    it.step_limit = 2000;
    try testing.expectError(error.TclError, it.eval("f 100000"));
    try testing.expectEqualStrings("step limit reached", try it.str(it.result));
    try testing.expectEqual(before + 1, it.jit.?.stats.tier2);
}

test "tier 2: a loop that pops a place below the depth of its head stays in tier 1" {
    if (!jit.built) return error.SkipZigTest;
    // The jit-fuzz --verify --tier2 mode found it: a changed jump made a
    // loop whose head is a `pop` at depth 1. The `pop` drops a place
    // below the depth of the head, and the code generation of tier 2
    // computed a negative place index.
    const it = try newInterp();
    defer freeInterp(it);
    it.gc_on = false;
    if (!it.enableJit(.{ .threshold = 0, .tier2 = true, .tier2_count = 1 })) return error.SkipZigTest;
    _ = try it.eval("proc q {} { list x; set b 1; list y; return $b }");
    _ = try it.eval("q");
    const code = try procCode(it, "q");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var m = try Mutable.init(arena.allocator(), code);
    // The `pop` of `list x`, and the `push` of `y`.
    const k = m.find(.pop);
    var j: usize = k + 1;
    while (m.ins[j].op != .invoke) j += 1;
    j -= 1;
    try testing.expectEqual(vm.Op.push, m.ins[j].op);
    m.ins[j] = .{ .op = .jump, .a = @intCast(k) };
    var info = (try verify.verify(testing.allocator, &m.code)).?;
    defer info.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), info.loop_heads.len);
    try testing.expectEqual(@as(u16, 1), info.depth[k]);
    const kinds = try testing.allocator.alloc(tier2.Kind, m.code.names.len);
    defer testing.allocator.free(kinds);
    @memset(kinds, .int);
    try testing.expect((try tier2.plan(testing.allocator, &m.code, &info, info.loop_heads[0], kinds)) == null);
    const held = try arena.allocator().create(vm.Code);
    held.* = m.code;
    _ = jit.prepare(it, held) orelse return error.NotCompiled;
    const p = it.commands.get("q").?.impl.proc;
    const saved = p.code;
    p.code = held;
    defer p.code = saved;
    const before = it.jit.?.stats.tier2;
    it.step_limit = 2000;
    try testing.expectError(error.TclError, it.eval("q"));
    try testing.expectEqualStrings("step limit reached", try it.str(it.result));
    try testing.expectEqual(before, it.jit.?.stats.tier2);
}

test "tier 2: a loop condition with a guard stops at each small step limit" {
    if (!jit.built) return error.SkipZigTest;
    // The condition `[incr i] <= $n` puts a guard in the part of the
    // loop head, so tier 2 checks steps at the head. With a step limit
    // below the steps of that part, tier 2 exited at the head with no
    // step, and before the counter rule of resume_at tier 1 called
    // tier_up at once. The script then looped with no step. This test
    // shows that a script of real Tcl reaches the case.
    const script = "proc f {n} { set s 0; set i 0; while {[incr i] <= $n} { incr s $i }; return $s }; f 1200";
    var tier2_runs: usize = 0;
    for (0..64) |limit| {
        const ref = try runModeOpts(script, null, limit, 0, 0);
        defer ref.deinit();
        const got = try runModeOpts(script, .{ .threshold = 0, .tier2 = true, .tier2_count = 1 }, limit, 0, 0);
        defer got.deinit();
        testing.expectEqualStrings(ref.text, got.text) catch |e| {
            std.debug.print("step limit {d}\n", .{limit});
            return e;
        };
        if (last_tier2 > 0) tier2_runs += 1;
    }
    try testing.expect(tier2_runs > 0);
}

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
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.NoFile;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.NoFile;
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
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
        // 11. Named code.
        .{ .name = "named", .f = struct {
            fn f(m: *Mutable, _: std.mem.Allocator) !void {
                m.code.named = true;
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
    var ctx: jit.EnterCtx = .{ .it = it, .code = code, .frame = &frame, .stack = &stack, .helpers = &helpers.table, .target = 0, .pc = 0, .sp = 0, .err = 0, .empty = &tcl.Value.empty };
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
    const it = try newInterp();
    defer freeInterp(it);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    it.output = .{ .ctx = &out, .write = collect };
    if (stress == 0) it.gc_on = false else it.setGcStress(stress);
    it.step_limit = limit;
    if (allow_interp) try it.allow(@intFromEnum(tcl.interp.Capability.interp));
    if (on and !it.enableJit(.{ .threshold = 0 })) return error.SkipZigTest;
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
    if (on) {
        const st = it.jit.?.stats;
        if (st.compiled < min_compiled) {
            std.debug.print("compiled {d} < {d} for:\n{s}\n", .{ st.compiled, min_compiled, script });
            return error.TooFewCompiled;
        }
    }
    return .{ .text = try w.toOwnedSlice(a) };
}

/// True while a test runs scripts with the capability `interp`.
var allow_interp = false;

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
            try @import("tier1_x64.zig").assemble(testing.allocator, &s, code, &info, layout.probe().?, entries);
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

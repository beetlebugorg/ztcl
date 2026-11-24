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
    var ctx: jit.EnterCtx = .{ .it = it, .code = code, .frame = &frame, .stack = &stack, .helpers = &helpers.table, .target = 0, .pc = 0, .sp = 0, .err = 0 };
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

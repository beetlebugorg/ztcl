//! The runtime side of procs compiled to WebAssembly.
//!
//! A build with the option `aot` (`zig build wasm-aot`) exports each
//! helper of the JIT, and the variable `ztcl_aot_dir`. `ztcl compile
//! --wasm` adds functions to the module and writes the address of a
//! directory to that variable. The first run of a `Code` looks for its
//! function in the directory: the hash of the bytecode, then the bytes,
//! then the verifier of the JIT and its depths. `vm.runLoop` then calls
//! the function through the table, as it calls the machine code of the
//! JIT. Each failed check leaves the `Code` in the interpreter.
//!
//! The directory is a list of 32-bit little-endian words: the magic
//! `ZAOT`, the version, the count of records, then 8 words for each
//! record, sorted by hash: the hash (two words), the address of the
//! bytecode, the count of instructions, the address of the depths, the
//! table index of the function, the flags (bit 0: named code), and 0.
//!
//! The record mode writes the arguments and the body of each proc that
//! compiles to bytecode, so a test can compile each proc of a run.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const vm = @import("../vm.zig");
const interp = @import("../interp.zig");
const jit = @import("../jit.zig");
const helpers = @import("../jit/helpers.zig");
const verify = @import("../jit/verify.zig");
const gen = @import("gen.zig");
const layout = @import("../jit/layout.zig");
const Value = @import("../value.zig").Value;

const Interp = interp.Interp;

/// True in a WebAssembly build with the option `aot`.
pub const built = builtin.cpu.arch.isWasm() and @hasDecl(options, "aot") and options.aot;

pub const magic: u32 = 0x544f415a;
pub const version: u32 = 1;
pub const record_words = 8;

/// The address of the directory. The linker writes it with a data
/// segment.
var dir_addr: u32 = 0;

/// The error of the last call that gave status 1.
var last_err: u16 = 0;

/// The counts of the lookups: functions found and not found.
var found: u32 = 0;
var missed: u32 = 0;
var missed_named: u32 = 0;

var recording = false;
var record: std.ArrayList(u8) = .empty;
var record_seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
const record_alloc = std.heap.wasm_allocator;

comptime {
    if (built) {
        for (.{ "it", "code", "frame", "stack", "helpers", "target", "pc", "sp", "err", "empty", "counters", "func" }) |f| {
            if (@offsetOf(jit.EnterCtx, f) != @offsetOf(gen.Ctx32, f)) @compileError("the layout of EnterCtx differs from gen.Ctx32");
        }
        @export(&dir_addr, .{ .name = "ztcl_aot_dir" });
        for (gen.exported) |h| {
            @export(helpers.wrap(h, false), .{ .name = gen.exportName(h, false) });
            @export(helpers.wrap(h, true), .{ .name = gen.exportName(h, true) });
        }
        @export(&aotRecord, .{ .name = "ztcl_aot_record" });
        @export(&aotRecordPtr, .{ .name = "ztcl_aot_record_ptr" });
        @export(&aotRecordLen, .{ .name = "ztcl_aot_record_len" });
        @export(&aotStat, .{ .name = "ztcl_aot_stat" });
        @export(&aotLayout, .{ .name = "ztcl_aot_layout" });
        @export(&layout_data, .{ .name = "ztcl_aot_layout_data" });
    }
}

/// Turns the record mode on (1) or off (0). On clears the record.
fn aotRecord(on: u32) callconv(.c) void {
    recording = on != 0;
    if (recording) {
        record.clearRetainingCapacity();
        record_seen.clearRetainingCapacity();
    }
}

fn aotRecordPtr() callconv(.c) [*]const u8 {
    return record.items.ptr;
}

fn aotRecordLen() callconv(.c) usize {
    return record.items.len;
}

/// 0: the count of functions found. 1: the count of proc bodies with no
/// function. 2: 1 when the module has a directory. 3: the count of named
/// `Code` values with no function. 4: 1 when the layout of the build
/// equals the layout in the module.
fn aotStat(which: u32) callconv(.c) u32 {
    return switch (which) {
        0 => found,
        1 => missed,
        2 => @intFromBool(dir_addr != 0),
        3 => missed_named,
        4 => @intFromBool(layoutOk()),
        else => 0,
    };
}

/// Writes the fields of `layout.probe()` in their order to `out` and
/// returns their count, or 0 when the probe fails.
fn aotLayout(out: [*]u32) callconv(.c) u32 {
    const l = layout.probe() orelse return 0;
    const names = comptime std.meta.fieldNames(layout.Layout);
    inline for (names, 0..) |name, k| out[k] = @field(l, name);
    return names.len;
}

/// The layout that the compiler reads from the module: each field of
/// `layout.Layout` as a word, in order. The offsets of the fields of
/// structs come from `@offsetOf`. The places in the two tagged unions
/// come from `gen.union32`: Zig gives no way to read them at compile
/// time, so the first lookup compares the whole layout with the probe.
const layout_words = std.meta.fieldNames(layout.Layout).len;
const layout_data: [layout_words]u32 = blk: {
    @setEvalBranchQuota(10000);
    const l = staticLayout();
    var out: [layout_words]u32 = undefined;
    for (std.meta.fieldNames(layout.Layout), 0..) |name, k| out[k] = @field(l, name);
    break :blk out;
};

fn staticLayout() layout.Layout {
    const interp_ = interp;
    const value = @import("../value.zig");
    const VTag = std.meta.Tag(Value);
    const CTag = std.meta.Tag(@FieldType(interp_.Var, "v"));
    const u = gen.union32;
    const List = @FieldType(Value, "list");
    var l: layout.Layout = undefined;
    l.slice_ptr = u.slice_ptr;
    l.slice_len = u.slice_len;
    l.value_size = @sizeOf(Value);
    l.value_tag = u.value_tag;
    l.value_mask = (1 << @bitSizeOf(VTag)) - 1;
    l.tag_int = @backingInt(VTag.int);
    l.tag_double = @backingInt(VTag.double);
    l.tag_str = @backingInt(VTag.str);
    l.tag_list = @backingInt(VTag.list);
    l.value_payload = u.value_payload;
    l.value_len = u.value_len;
    l.list_obj = @offsetOf(List, "obj");
    l.list_len = @offsetOf(List, "len");
    l.var_tag = u.var_tag;
    l.var_mask = (1 << @bitSizeOf(CTag)) - 1;
    l.var_payload = u.var_payload;
    l.var_undef = @backingInt(CTag.undef);
    l.var_val = @backingInt(CTag.val);
    l.var_owned = @backingInt(CTag.owned);
    l.var_link = @backingInt(CTag.link);
    l.entry_size = @sizeOf(interp_.VarEntry);
    l.entry_cell = @offsetOf(interp_.VarEntry, "cell");
    const vars = @offsetOf(interp_.Frame, "vars") + @offsetOf(std.ArrayList(interp_.VarEntry), "items");
    l.frame_items = vars + l.slice_ptr;
    l.frame_len = vars + l.slice_len;
    l.obj_buf = @offsetOf(value.ListObj, "buf") + l.slice_ptr;
    l.obj_buf_len = @offsetOf(value.ListObj, "buf") + l.slice_len;
    l.obj_used = @offsetOf(value.ListObj, "used");
    l.obj_dict_len = @offsetOf(value.ListObj, "dict_len");
    l.obj_index = @offsetOf(value.ListObj, "index");
    l.it_epoch = @offsetOf(Interp, "epoch");
    l.it_safe_epoch = @offsetOf(Interp, "safe_epoch");
    l.it_compute_limit = @offsetOf(Interp, "compute_limit");
    const counter = @offsetOf(Interp, "counter");
    l.it_mem_used = counter + @offsetOf(interp_.Counting, "used");
    l.it_mem_trip = counter + @offsetOf(interp_.Counting, "trip");
    l.it_mem_limit = @offsetOf(Interp, "mem_limit");
    l.it_ns = @offsetOf(Interp, "ns") + l.slice_ptr;
    l.cmd_resolved = @offsetOf(interp_.Cmd, "resolved");
    l.cmd_epoch = @offsetOf(interp_.Cmd, "epoch");
    l.cmd_ns = @offsetOf(interp_.Cmd, "ns");
    l.code_sites = @offsetOf(vm.Code, "sites") + l.slice_ptr;
    l.code_lits = @offsetOf(vm.Code, "lits") + l.slice_ptr;
    l.code_ins = @offsetOf(vm.Code, "ins") + l.slice_ptr;
    l.ins_size = @sizeOf(vm.Ins);
    return l;
}

/// 0: not checked, 1: the probe equals `layout_data`, 2: it differs.
var layout_state: u8 = 0;

/// True when the layout of this build equals `layout_data`. When it
/// differs, the directory is off, and each `Code` runs in `exec`.
fn layoutOk() bool {
    if (layout_state == 0) {
        layout_state = 2;
        if (layout.probe()) |l| {
            var same = true;
            inline for (comptime std.meta.fieldNames(layout.Layout), 0..) |name, k| {
                if (@as(u32, @field(l, name)) != layout_data[k]) same = false;
            }
            if (same) layout_state = 1;
        }
    }
    return layout_state == 1;
}

fn word(addr: u32) u32 {
    const p: *align(1) const u32 = @ptrFromInt(addr);
    return std.mem.littleToNative(u32, p.*);
}

/// The table index of the function of `code`, or null. The result of
/// the first call stays in the `Code`.
pub fn prepare(it: *Interp, code: *vm.Code) ?u32 {
    switch (code.jit_state) {
        .ready => return @intCast(@intFromPtr(code.jit.?)),
        .failed => return null,
        .untried => {},
    }
    code.jit_state = .failed;
    if (dir_addr == 0 or !layoutOk()) return null;
    const idx = find(it, code) orelse {
        if (code.named) missed_named += 1 else missed += 1;
        return null;
    };
    found += 1;
    code.jit = @ptrFromInt(idx);
    code.jit_state = .ready;
    return idx;
}

fn find(it: *Interp, code: *const vm.Code) ?u32 {
    const d = dir_addr;
    if (word(d) != magic or word(d + 4) != version) return null;
    const n = word(d + 8);
    const hash = gen.hashCode(code);
    const rec0 = d + 12;
    // The first record with a hash at or above `hash`.
    var lo: u32 = 0;
    var hi: u32 = n;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (hashAt(rec0 + mid * record_words * 4) < hash) lo = mid + 1 else hi = mid;
    }
    while (lo < n) : (lo += 1) {
        const r = rec0 + lo * record_words * 4;
        if (hashAt(r) != hash) return null;
        if (matches(it, code, r)) return word(r + 20);
    }
    return null;
}

fn hashAt(r: u32) u64 {
    return @as(u64, word(r + 4)) << 32 | word(r);
}

fn matches(it: *Interp, code: *const vm.Code, r: u32) bool {
    if ((word(r + 24) & 1 != 0) != code.named) return false;
    if (word(r + 12) != code.ins.len) return false;
    const ins: [*]const u8 = @ptrFromInt(word(r + 8));
    for (code.ins, 0..) |*i, k| {
        if (!std.mem.eql(u8, &gen.insBytes(i), ins[k * 16 ..][0..16])) return false;
    }
    var root = it;
    while (root.parent) |q| root = q;
    const a = root.counter.child;
    var info = (verify.verify(a, code) catch return false) orelse return false;
    defer info.deinit(a);
    const depths: [*]align(1) const u16 = @ptrFromInt(word(r + 16));
    for (0..code.ins.len) |k| {
        if (std.mem.littleToNative(u16, depths[k]) != gen.depthOf(&info, k)) return false;
    }
    return true;
}

/// Runs the function `idx` of `code` from `pc.*` with depth `sp.*`, as
/// `jit.enter` runs machine code.
pub fn enter(it: *Interp, idx: u32, code: *vm.Code, stack: [*]Value, pc: *u32, sp: *u32) jit.Status {
    if (!code.named and it.frame.vars.items.len < code.names.len) return .fallback;
    var ctx: jit.EnterCtx = .{
        .it = it,
        .code = code,
        .frame = it.frame,
        .stack = stack,
        .helpers = undefined,
        .target = 0,
        .pc = pc.*,
        .sp = sp.*,
        .err = 0,
        .empty = &Value.empty,
        .counters = undefined,
        .func = undefined,
    };
    const f: *const fn (*jit.EnterCtx) callconv(.c) u32 = @ptrFromInt(idx);
    const status = f(&ctx);
    pc.* = ctx.pc;
    sp.* = ctx.sp;
    return switch (status) {
        gen.status_done => .done,
        gen.status_error => blk: {
            last_err = ctx.err;
            break :blk .failed;
        },
        else => .fallback,
    };
}

pub fn lastError() interp.Error {
    return @errorCast(@errorFromInt(last_err));
}

/// The record mode: notes the arguments and the body of a proc whose
/// body compiled to bytecode. Each record is the length and the bytes
/// of the arguments, then of the body, as 32-bit little-endian lengths.
pub fn noteProc(it: *Interp, p: *const interp.Proc) void {
    if (!recording) return;
    const args = it.str(p.params_text) catch return;
    const body = it.str(p.body) catch return;
    var h = std.hash.Wyhash.init(0);
    h.update(args);
    h.update(&.{0});
    h.update(body);
    const g = record_seen.getOrPut(record_alloc, h.final()) catch return;
    if (g.found_existing) return;
    var len: [4]u8 = undefined;
    for ([_][]const u8{ args, body }) |s| {
        std.mem.writeInt(u32, &len, @intCast(s.len), .little);
        record.appendSlice(record_alloc, &len) catch return;
        record.appendSlice(record_alloc, s) catch return;
    }
}

//! The code generator: one bytecode `Code` to one WebAssembly function.
//!
//! The design is tier 1 of the JIT (docs/jit.md): each instruction
//! gives one fixed piece of code, and the state at each instruction
//! boundary equals the state of the interpreter. The function has the
//! signature `(ctx) -> status`, where `ctx` is a `jit.EnterCtx` in
//! linear memory. The value stack stays in linear memory, and the depth
//! of each instruction is the static depth of the verifier, so each
//! instruction passes a constant `sp` to its helper.
//!
//! Control flow. Each jump target and each entry starts a block. The
//! blocks are nested in one `loop`:
//!
//!     block $fallback
//!       block $go   (the entry checks)   end
//!       loop $top
//!         block $B(m-1) ... block $B0
//!           local.get $blk  br_table $B0 ... $B(m-1) $fallback
//!         end  code of block 0
//!         ...
//!         end  code of block m-1
//!       end
//!     end
//!     status 2
//!
//! The end of `$Bk` is the start of the code of block k. A forward jump
//! is a `br` to the end of the block before its target. A backward jump
//! writes the target block to `$blk` and goes to `$top`.
//!
//! The directory form of a `Code` is here too: the bytecode as 16 bytes
//! for each instruction (`insBytes`) and its hash. The runtime and the
//! compiler use the same functions.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vm = @import("../vm.zig");
const verify = @import("../jit/verify.zig");
const helpers = @import("../jit/helpers.zig");
const w = @import("../wasm_out.zig");
const expr = @import("../expr.zig");
const Layout = @import("../jit/layout.zig").Layout;

/// The places in the tagged unions and in a slice on wasm32, from
/// `layout.probe()` in the runtime. `rt.zig` checks them.
pub const union32 = .{
    .slice_ptr = 0,
    .slice_len = 4,
    .value_tag = 8,
    .value_payload = 0,
    .value_len = 4,
    .var_tag = 16,
    .var_payload = 0,
};

/// The facts of the layout that the inline paths need: a `Value` of
/// whole 8-byte words with the tag after the 8 bytes of the integer.
pub fn layoutUsable(l: *const Layout) bool {
    return l.value_size % 8 == 0 and l.value_payload + 8 <= l.value_tag and l.value_tag < l.value_size;
}

const Allocator = std.mem.Allocator;
const Helper = helpers.Helper;

/// The writer of `wasm_out.zig`, which checks the type of each
/// instruction, with the names of the generator and a count of the open
/// blocks, so a branch can compute its depth.
const Body = struct {
    w: w.Body,
    open: u32 = 0,

    pub const I32 = enum { eqz, eq, ne, @"and", ge_u };
    pub const I64 = enum { eqz, eq, ne, lt_s, gt_s, le_s, ge_s, le_u, ge_u, add, sub, mul, div_s, rem_s, @"and", xor, extend_i32_u };

    fn block(b: *Body) w.Error!void {
        try b.w.block(null);
        b.open += 1;
    }
    fn loop(b: *Body) w.Error!void {
        try b.w.loop(null);
        b.open += 1;
    }
    fn if_(b: *Body) w.Error!void {
        try b.w.@"if"(null);
        b.open += 1;
    }
    fn end(b: *Body) w.Error!void {
        try b.w.end();
        b.open -= 1;
    }
    fn br(b: *Body, d: u32) w.Error!void {
        return b.w.br(d);
    }
    fn brIf(b: *Body, d: u32) w.Error!void {
        return b.w.brIf(d);
    }
    fn brTable(b: *Body, ds: []const u32, default: u32) w.Error!void {
        return b.w.brTable(ds, default);
    }
    fn ret(b: *Body) w.Error!void {
        return b.w.ret();
    }
    fn unreachable_(b: *Body) w.Error!void {
        return b.w.@"unreachable"();
    }
    fn call(b: *Body, f: u32) w.Error!void {
        return b.w.call(f);
    }
    fn drop(b: *Body) w.Error!void {
        return b.w.drop(.i32);
    }
    fn localGet(b: *Body, i: u32) w.Error!void {
        return b.w.localGet(i);
    }
    fn localSet(b: *Body, i: u32) w.Error!void {
        return b.w.localSet(i);
    }
    fn localTee(b: *Body, i: u32) w.Error!void {
        return b.w.localTee(i);
    }
    fn i32Const(b: *Body, v: i32) w.Error!void {
        return b.w.i32Const(v);
    }
    fn i64Const(b: *Body, v: i64) w.Error!void {
        return b.w.i64Const(v);
    }
    fn i32Load(b: *Body, off: u32) w.Error!void {
        return b.w.load(.i32, .{ .align_log2 = 2, .offset = off });
    }
    fn i64Load(b: *Body, off: u32) w.Error!void {
        return b.w.load(.i64, .{ .align_log2 = 3, .offset = off });
    }
    fn i32Load8u(b: *Body, off: u32) w.Error!void {
        return b.w.load(.i32_8u, .{ .align_log2 = 0, .offset = off });
    }
    fn i32Store(b: *Body, off: u32) w.Error!void {
        return b.w.store(.i32, .{ .align_log2 = 2, .offset = off });
    }
    fn i64Store(b: *Body, off: u32) w.Error!void {
        return b.w.store(.i64, .{ .align_log2 = 3, .offset = off });
    }
    fn i32Store8(b: *Body, off: u32) w.Error!void {
        return b.w.store(.i32_8, .{ .align_log2 = 0, .offset = off });
    }
    fn i32Op(b: *Body, o: I32) w.Error!void {
        return switch (o) {
            inline else => |t| b.w.num(@field(w.Body.Num, "i32_" ++ @tagName(t))),
        };
    }
    fn i64Op(b: *Body, o: I64) w.Error!void {
        return switch (o) {
            inline else => |t| b.w.num(@field(w.Body.Num, "i64_" ++ @tagName(t))),
        };
    }
};

/// The layout of `jit.EnterCtx` on wasm32. `rt.zig` checks it against
/// the real struct at compile time.
pub const Ctx32 = extern struct {
    it: u32,
    code: u32,
    frame: u32,
    stack: u32,
    helpers: u32,
    target: u32,
    pc: u32,
    sp: u32,
    err: u16,
    empty: u32,
    counters: u32,
    func: u32,
};

pub const status_done = 0;
pub const status_error = 1;
pub const status_exit = 2;

/// The helpers that the runtime exports, and their export names.
pub const exported = blk: {
    var list: []const Helper = &.{};
    for (std.enums.values(Helper)) |h| {
        switch (h) {
            .tier_up, .resume_at => {},
            else => list = list ++ .{h},
        }
    }
    break :blk list;
};

pub fn exportName(comptime h: Helper, comptime named: bool) []const u8 {
    return (if (named) "ztcl_hn_" else "ztcl_h_") ++ @tagName(h);
}

/// The function index of each helper in the module, for a proc body
/// and for named code. `none` for a helper that the module lacks.
pub const Helpers = struct {
    proc: [helpers.count]u32 = @splat(none),
    named: [helpers.count]u32 = @splat(none),

    pub const none = std.math.maxInt(u32);
};

/// The 16 bytes of one instruction: `op`, `x`, two zero bytes, then
/// `a`, `b`, and `c` in little endian.
pub fn insBytes(i: *const vm.Ins) [16]u8 {
    var out: [16]u8 = @splat(0);
    out[0] = @intFromEnum(i.op);
    out[1] = i.x;
    std.mem.writeInt(u32, out[4..8], i.a, .little);
    std.mem.writeInt(u32, out[8..12], i.b, .little);
    std.mem.writeInt(u32, out[12..16], i.c, .little);
    return out;
}

/// The hash of the directory form of `code`.
pub fn hashCode(code: *const vm.Code) u64 {
    var h = std.hash.Wyhash.init(@intFromBool(code.named));
    for (code.ins) |*i| h.update(&insBytes(i));
    return h.final();
}

/// The depth form of the directory: the depth of each instruction, or
/// `unreachable_depth`.
pub const unreachable_depth: u16 = std.math.maxInt(u16);

pub fn depthOf(info: *const verify.Info, pc: usize) u16 {
    return if (info.reachable[pc]) info.depth[pc] else unreachable_depth;
}

/// The target of the jump of instruction `i`, or null.
fn targetOf(i: *const vm.Ins) ?u32 {
    return switch (i.op) {
        .jump, .guard, .jump_false, .jump_true => i.a,
        .str_eq_jump, .foreach_next => i.b,
        .jf_vv, .jf_vi => i.c,
        else => null,
    };
}

/// The entries of `code`: pc 0 and each target of `break` and
/// `continue`, in order and without repeats.
pub fn entries(a: Allocator, code: *const vm.Code, info: *const verify.Info) Allocator.Error![]u32 {
    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(a);
    try list.append(a, 0);
    for (code.ranges) |r| {
        for ([_]u32{ r.brk, r.cont }) |t| {
            if (t >= code.ins.len or !info.reachable[t]) continue;
            if (std.mem.indexOfScalar(u32, list.items, t) == null) try list.append(a, t);
        }
    }
    std.mem.sort(u32, list.items, {}, std.sort.asc(u32));
    return list.toOwnedSlice(a);
}

pub const Error = w.Error || error{MissingHelper};

const local_ctx = 0;
const local_blk = 1;
const local_r = 2;
/// Cell addresses.
const local_c1 = 3;
const local_c2 = 4;
/// The fields of the context, loaded once at the entry.
const local_it = 5;
const local_stack = 6;
const local_frame = 7;
const local_code = 8;
const i32_locals = 8;
/// Integers of the inline paths.
const local_x = 9;
const local_y = 10;
const local_z = 11;
const i64_locals = 3;

const Gen = struct {
    a: Allocator,
    b: Body,
    code: *const vm.Code,
    info: *const verify.Info,
    h: *const [helpers.count]u32,
    l: *const Layout,
    /// False: each instruction calls its helper.
    inline_paths: bool,
    /// The block of each instruction that starts one, or `no_block`.
    block_of: []u32,
    /// The nesting level of the label of each block, and of `$top`.
    level: []u32,
    top_level: u32,
    /// The block of the code that the generator writes now.
    cur: u32 = 0,

    const no_block = std.math.maxInt(u32);

    /// A branch to the start of the code of the block of `t`.
    fn jumpTo(g: *Gen, t: u32) Error!void {
        const k = g.block_of[t];
        std.debug.assert(k != no_block);
        if (k > g.cur) return g.b.br(g.b.open - g.level[k]);
        try g.b.i32Const(@intCast(k));
        try g.b.localSet(local_blk);
        try g.b.br(g.b.open - g.top_level);
    }

    /// Writes `pc` and `sp` to the context and returns `status`.
    fn exit(g: *Gen, pc: u32, sp: u32, status: i32) Error!void {
        try g.b.localGet(local_ctx);
        try g.b.i32Const(@bitCast(pc));
        try g.b.i32Store(@offsetOf(Ctx32, "pc"));
        try g.b.localGet(local_ctx);
        try g.b.i32Const(@bitCast(sp));
        try g.b.i32Store(@offsetOf(Ctx32, "sp"));
        try g.b.i32Const(status);
        try g.b.ret();
    }

    /// Calls helper `h` of instruction `pc`. The result is on the stack.
    fn callHelper(g: *Gen, h: Helper, pc: u32, sp: u32) Error!void {
        const f = g.h[@intFromEnum(h)];
        if (f == Helpers.none) return error.MissingHelper;
        try g.b.localGet(local_ctx);
        try g.b.i32Const(@bitCast(pc));
        try g.b.i32Const(@bitCast(sp));
        try g.b.call(f);
    }

    fn instruction(g: *Gen, pc: u32) Error!void {
        const i = &g.code.ins[pc];
        const sp: u32 = g.info.depth[pc];
        switch (i.op) {
            .pop => {},
            .jump => try g.jumpTo(i.a),
            .ret => try g.exit(pc, sp, status_done),
            else => {
                if (g.inline_paths and try g.fast(pc)) return;
                try g.whole(pc);
            },
        }
    }

    /// The helper of the whole instruction, and its result: the error
    /// exit, and the jump of a branch.
    fn whole(g: *Gen, pc: u32) Error!void {
        const i = &g.code.ins[pc];
        const sp: u32 = g.info.depth[pc];
        const h = helpers.forIns(i).?;
        try g.callHelper(h, pc, sp);
        if (helpers.isBranch(h)) {
            try g.b.localTee(local_r);
            try g.b.i32Const(helpers.failed);
            try g.b.i32Op(.eq);
            try g.b.if_();
            try g.exit(pc, sp, status_error);
            try g.b.end();
            try g.b.localGet(local_r);
            try g.b.if_();
            try g.jumpTo(targetOf(i).?);
            try g.b.end();
        } else {
            try g.b.if_();
            try g.exit(pc, sp, status_error);
            try g.b.end();
        }
    }

    // ---- The inline paths ----
    //
    // Each inline path is `block $done block $slow <fast> br $done end
    // <whole> end`. A check that fails goes to `$slow`, where the helper
    // runs the whole instruction, as `exec` does. The fast part has the
    // effect of the instruction only when each check passed, so the
    // helper always starts from the state before the instruction.

    const Fast = struct { done: u32, slow: u32 };

    fn openFast(g: *Gen) Error!Fast {
        try g.b.block();
        const done = g.b.open;
        try g.b.block();
        return .{ .done = done, .slow = g.b.open };
    }

    fn closeFast(g: *Gen, f: Fast, pc: u32) Error!void {
        try g.b.br(g.b.open - f.done);
        try g.b.end();
        try g.whole(pc);
        try g.b.end();
    }

    fn toSlow(g: *Gen, f: Fast) Error!void {
        try g.b.brIf(g.b.open - f.slow);
    }

    fn vs(g: *Gen) u32 {
        return g.l.value_size;
    }

    /// The address of a field of the stack value `k` is the local `stack`
    /// with the offset of this function.
    fn stackOff(g: *Gen, k: u32, field: u32) u32 {
        return k * g.vs() + field;
    }

    /// Copies one `Value` from `src + so` to `dst + do`.
    fn copy(g: *Gen, dst: u32, do: u32, src: u32, so: u32) Error!void {
        var word: u32 = 0;
        while (word < g.vs()) : (word += 8) {
            try g.b.localGet(dst);
            try g.b.localGet(src);
            try g.b.i64Load(so + word);
            try g.b.i64Store(do + word);
        }
    }

    /// The raw cell of slot `slot` in `local`. A cell with no tag in
    /// `want` goes to the slow path.
    fn cell(g: *Gen, f: Fast, slot: u32, local: u32, want: []const u8) Error!void {
        const l = g.l;
        try g.b.localGet(local_frame);
        try g.b.i32Load(l.frame_items);
        try g.b.i32Load(slot * l.entry_size + l.entry_cell);
        try g.b.localTee(local);
        try g.b.i32Load8u(l.var_tag);
        try g.b.i32Const(l.var_mask);
        try g.b.i32Op(.@"and");
        try g.b.localSet(local_r);
        for (want, 0..) |t, k| {
            try g.b.localGet(local_r);
            try g.b.i32Const(t);
            try g.b.i32Op(.ne);
            if (k > 0) try g.b.i32Op(.@"and");
        }
        try g.toSlow(f);
    }

    /// The integer of the value of cell `c` into `x`.
    fn cellInt(g: *Gen, f: Fast, c: u32, x: u32) Error!void {
        const l = g.l;
        try g.tagIs(c, l.var_payload + l.value_tag, l.tag_int, f);
        try g.b.localGet(c);
        try g.b.i64Load(l.var_payload + l.value_payload);
        try g.b.localSet(x);
    }

    /// Goes to the slow path unless the tag byte at `base + off` is `tag`.
    fn tagIs(g: *Gen, base: u32, off: u32, tag: u8, f: Fast) Error!void {
        try g.b.localGet(base);
        try g.b.i32Load8u(off);
        try g.b.i32Const(g.l.value_mask);
        try g.b.i32Op(.@"and");
        try g.b.i32Const(tag);
        try g.b.i32Op(.ne);
        try g.toSlow(f);
    }

    fn stackInt(g: *Gen, f: Fast, k: u32, x: u32) Error!void {
        const l = g.l;
        try g.tagIs(local_stack, g.stackOff(k, l.value_tag), l.tag_int, f);
        try g.b.localGet(local_stack);
        try g.b.i64Load(g.stackOff(k, l.value_payload));
        try g.b.localSet(x);
    }

    /// The integer literal `index` into `x`. The verifier proved that it
    /// is an integer.
    fn litInt(g: *Gen, index: u32, x: u32) Error!void {
        try g.b.localGet(local_code);
        try g.b.i32Load(g.l.code_lits);
        try g.b.i64Load(index * g.vs() + g.l.value_payload);
        try g.b.localSet(x);
    }

    /// Writes the integer `x` as stack value `k`.
    fn putInt(g: *Gen, k: u32, x: u32) Error!void {
        try g.b.localGet(local_stack);
        try g.b.localGet(x);
        try g.b.i64Store(g.stackOff(k, g.l.value_payload));
        try g.b.localGet(local_stack);
        try g.b.i32Const(g.l.tag_int);
        try g.b.i32Store8(g.stackOff(k, g.l.value_tag));
    }

    /// The step check of `step`: the steps left are not 0, and the memory
    /// count is below the limit. Then one step is used.
    fn stepCheck(g: *Gen, f: Fast) Error!void {
        const l = g.l;
        try g.b.localGet(local_it);
        try g.b.i64Load(l.it_step_limit);
        try g.b.i64Op(.eqz);
        try g.toSlow(f);
        try g.b.localGet(local_it);
        try g.b.i32Load(l.it_mem_trip);
        try g.b.localGet(local_it);
        try g.b.i32Load(l.it_mem_limit);
        try g.b.i32Op(.ge_u);
        try g.toSlow(f);
        try g.b.localGet(local_it);
        try g.b.localGet(local_it);
        try g.b.i64Load(l.it_step_limit);
        try g.b.i64Const(1);
        try g.b.i64Op(.sub);
        try g.b.i64Store(l.it_step_limit);
    }

    fn fastOp(op: expr.BinOp) bool {
        return switch (op) {
            .add, .sub, .mul, .div, .mod, .lt, .gt, .le, .ge, .eq, .ne => true,
            else => false,
        };
    }

    fn compareOp(op: expr.BinOp) ?Body.I64 {
        return switch (op) {
            .lt => .lt_s,
            .gt => .gt_s,
            .le => .le_s,
            .ge => .ge_s,
            .eq => .eq,
            .ne => .ne,
            else => null,
        };
    }

    /// Goes to the slow path unless `x` is in the range of i32.
    fn smallInt(g: *Gen, f: Fast, x: u32) Error!void {
        try g.b.localGet(x);
        try g.b.i64Const(0x8000_0000);
        try g.b.i64Op(.add);
        try g.b.i64Const(0x1_0000_0000);
        try g.b.i64Op(.ge_u);
        try g.toSlow(f);
    }

    /// `x = x op y`, or 0 or 1 for a compare. An overflow goes to the
    /// slow path. `*` goes there unless both operands fit in 32 bits.
    /// `/` and `%` send a divisor of 0 or -1 there, and round the
    /// quotient down as Tcl does.
    fn arith(g: *Gen, f: Fast, op: expr.BinOp) Error!void {
        const b = &g.b;
        if (compareOp(op)) |c| {
            try b.localGet(local_x);
            try b.localGet(local_y);
            try b.i64Op(c);
            try b.i64Op(.extend_i32_u);
            try b.localSet(local_x);
            return;
        }
        switch (op) {
            .add, .sub => {
                try b.localGet(local_x);
                try b.localGet(local_y);
                try b.i64Op(if (op == .add) .add else .sub);
                try b.localSet(local_z);
                // add: ((x ^ z) & (y ^ z)) < 0. sub: ((x ^ y) & (x ^ z)) < 0.
                try b.localGet(local_x);
                try b.localGet(if (op == .add) local_z else local_y);
                try b.i64Op(.xor);
                try b.localGet(if (op == .add) local_y else local_x);
                try b.localGet(local_z);
                try b.i64Op(.xor);
                try b.i64Op(.@"and");
                try b.i64Const(0);
                try b.i64Op(.lt_s);
                try g.toSlow(f);
                try b.localGet(local_z);
                try b.localSet(local_x);
            },
            .mul => {
                try g.smallInt(f, local_x);
                try g.smallInt(f, local_y);
                try b.localGet(local_x);
                try b.localGet(local_y);
                try b.i64Op(.mul);
                try b.localSet(local_x);
            },
            .div, .mod => {
                // y + 1 <= 1 unsigned: y is 0 or -1.
                try b.localGet(local_y);
                try b.i64Const(1);
                try b.i64Op(.add);
                try b.i64Const(1);
                try b.i64Op(.le_u);
                try g.toSlow(f);
                // z = x % y, x = x / y.
                try b.localGet(local_x);
                try b.localGet(local_y);
                try b.i64Op(.rem_s);
                try b.localSet(local_z);
                try b.localGet(local_x);
                try b.localGet(local_y);
                try b.i64Op(.div_s);
                try b.localSet(local_x);
                // A remainder with the sign opposite to the divisor.
                try b.localGet(local_z);
                try b.localGet(local_y);
                try b.i64Op(.xor);
                try b.i64Const(0);
                try b.i64Op(.lt_s);
                try b.localGet(local_z);
                try b.i64Op(.eqz);
                try b.i32Op(.eqz);
                try b.i32Op(.@"and");
                try b.if_();
                try b.localGet(local_x);
                try b.i64Const(1);
                try b.i64Op(.sub);
                try b.localSet(local_x);
                try b.localGet(local_z);
                try b.localGet(local_y);
                try b.i64Op(.add);
                try b.localSet(local_z);
                try b.end();
                if (op == .mod) {
                    try b.localGet(local_z);
                    try b.localSet(local_x);
                }
            },
            else => unreachable,
        }
    }

    /// The two operands of `bin_vv`, `bin_vi`, `jf_vv`, and `jf_vi` into
    /// `x` and `y`.
    fn slotOperands(g: *Gen, f: Fast, i: *const vm.Ins) Error!void {
        try g.cell(f, i.a, local_c1, &.{g.l.var_val});
        try g.cellInt(f, local_c1, local_x);
        if (i.op == .bin_vv or i.op == .jf_vv) {
            try g.cell(f, i.b, local_c2, &.{g.l.var_val});
            try g.cellInt(f, local_c2, local_y);
        } else try g.litInt(i.b, local_y);
    }

    /// Writes the inline path of instruction `pc`, or returns false.
    fn fast(g: *Gen, pc: u32) Error!bool {
        const i = &g.code.ins[pc];
        const sp: u32 = g.info.depth[pc];
        const l = g.l;
        const b = &g.b;
        // Named code reads each variable by its name: the helper.
        if (g.code.named) switch (i.op) {
            .load, .store, .store_pop, .incr, .incr_drop, .incr_value, .bin_vv, .bin_vi, .jf_vv, .jf_vi => return false,
            else => {},
        };
        switch (i.op) {
            .step, .guard => {
                const f = try g.openFast();
                if (i.op == .guard) {
                    try b.localGet(local_it);
                    try b.i32Load(l.it_epoch);
                    try b.localGet(local_it);
                    try b.i32Load(l.it_safe_epoch);
                    try b.i32Op(.ne);
                    try g.toSlow(f);
                }
                try g.stepCheck(f);
                try g.closeFast(f, pc);
            },
            .push => {
                try b.localGet(local_code);
                try b.i32Load(l.code_lits);
                try b.localSet(local_c1);
                try g.copy(local_stack, g.stackOff(sp, 0), local_c1, i.a * g.vs());
            },
            .push_empty => {
                try b.localGet(local_ctx);
                try b.i32Load(@offsetOf(Ctx32, "empty"));
                try b.localSet(local_c1);
                try g.copy(local_stack, g.stackOff(sp, 0), local_c1, 0);
            },
            .load => {
                const f = try g.openFast();
                if (i.x == 1) try g.cell(f, i.a, local_c1, &.{ l.var_val, l.var_owned }) else try g.cell(f, i.a, local_c1, &.{l.var_val});
                try g.copy(local_stack, g.stackOff(sp, 0), local_c1, l.var_payload);
                try g.closeFast(f, pc);
            },
            .store, .store_pop => {
                const f = try g.openFast();
                try g.cell(f, i.a, local_c1, &.{l.var_val});
                try g.copy(local_c1, l.var_payload, local_stack, g.stackOff(sp - 1, 0));
                try g.closeFast(f, pc);
            },
            .jump_false, .jump_true, .to_bool => {
                const f = try g.openFast();
                try g.stackInt(f, sp - 1, local_x);
                if (i.op == .to_bool) {
                    try b.localGet(local_stack);
                    try b.localGet(local_x);
                    try b.i64Op(.eqz);
                    try b.i32Op(.eqz);
                    try b.i64Op(.extend_i32_u);
                    try b.i64Store(g.stackOff(sp - 1, l.value_payload));
                } else {
                    try b.localGet(local_x);
                    try b.i64Op(.eqz);
                    if (i.op == .jump_true) try b.i32Op(.eqz);
                    try b.if_();
                    try g.jumpTo(i.a);
                    try b.end();
                }
                try g.closeFast(f, pc);
            },
            .bin_vv, .bin_vi => {
                const op: expr.BinOp = @enumFromInt(i.x);
                if (!fastOp(op)) return false;
                const f = try g.openFast();
                try g.slotOperands(f, i);
                try g.arith(f, op);
                try g.putInt(sp, local_x);
                try g.closeFast(f, pc);
            },
            .binary => {
                const op: expr.BinOp = @enumFromInt(i.x);
                if (!fastOp(op)) return false;
                const f = try g.openFast();
                try g.stackInt(f, sp - 2, local_x);
                try g.stackInt(f, sp - 1, local_y);
                try g.arith(f, op);
                try b.localGet(local_stack);
                try b.localGet(local_x);
                try b.i64Store(g.stackOff(sp - 2, l.value_payload));
                try g.closeFast(f, pc);
            },
            .jf_vv, .jf_vi => {
                const op: expr.BinOp = @enumFromInt(i.x);
                const c = compareOp(op) orelse return false;
                const f = try g.openFast();
                try g.slotOperands(f, i);
                try b.localGet(local_x);
                try b.localGet(local_y);
                try b.i64Op(c);
                try b.i32Op(.eqz);
                try b.if_();
                try g.jumpTo(i.c);
                try b.end();
                try g.closeFast(f, pc);
            },
            .incr, .incr_drop, .incr_value => {
                const f = try g.openFast();
                try g.cell(f, i.a, local_c1, &.{l.var_val});
                try g.cellInt(f, local_c1, local_x);
                if (i.op == .incr_value) {
                    try g.stackInt(f, sp - 1, local_y);
                } else {
                    try b.i64Const(@as(i32, @bitCast(i.b)));
                    try b.localSet(local_y);
                }
                try g.arith(f, .add);
                try b.localGet(local_c1);
                try b.localGet(local_x);
                try b.i64Store(l.var_payload + l.value_payload);
                switch (i.op) {
                    .incr => try g.putInt(sp, local_x),
                    .incr_value => {
                        try b.localGet(local_stack);
                        try b.localGet(local_x);
                        try b.i64Store(g.stackOff(sp - 1, l.value_payload));
                    },
                    else => {},
                }
                try g.closeFast(f, pc);
            },
            else => return false,
        }
        return true;
    }
};

/// The code entry of the function of `code`. `h` is the helper index
/// table for the kind of `code`.
/// The type of each function of the module: `funcs[k]` is the type of
/// function k. A call of a helper checks its type against it.
pub const fn_type: w.FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };

pub fn function(a: Allocator, code: *const vm.Code, info: *const verify.Info, h: *const [helpers.count]u32, l: *const Layout, inline_paths: bool, funcs: []const w.FuncType) Error![]u8 {
    // The writer of wasm_out.zig frees nothing, so it uses an arena.
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const out = try functionIn(arena_state.allocator(), code, info, h, l, inline_paths, funcs);
    return a.dupe(u8, out);
}

fn functionIn(a: Allocator, code: *const vm.Code, info: *const verify.Info, h: *const [helpers.count]u32, l: *const Layout, inline_paths: bool, funcs: []const w.FuncType) Error![]u8 {
    const n = code.ins.len;
    const ents = try entries(a, code, info);
    defer a.free(ents);
    const block_of = try a.alloc(u32, n);
    defer a.free(block_of);
    @memset(block_of, Gen.no_block);
    // The starts of the blocks, in order.
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(a);
    {
        const mark = try a.alloc(bool, n);
        defer a.free(mark);
        @memset(mark, false);
        for (ents) |e| mark[e] = true;
        for (code.ins, 0..) |*i, pc| {
            if (!info.reachable[pc]) continue;
            if (targetOf(i)) |t| mark[t] = true;
        }
        for (mark, 0..) |m, pc| {
            if (!m or !info.reachable[pc]) continue;
            block_of[pc] = @intCast(starts.items.len);
            try starts.append(a, @intCast(pc));
        }
    }
    const m: u32 = @intCast(starts.items.len);
    const level = try a.alloc(u32, m);
    defer a.free(level);

    var g: Gen = .{ .a = a, .b = .{ .w = try w.Body.init(a, fn_type, funcs, &.{}) }, .code = code, .info = info, .h = h, .l = l, .inline_paths = inline_paths and layoutUsable(l), .block_of = block_of, .level = level, .top_level = 0 };
    const b = &g.b;
    for (0..i32_locals) |_| _ = try b.w.local(.i32);
    for (0..i64_locals) |_| _ = try b.w.local(.i64);
    // The fields of the context that each inline path reads.
    for ([_][2]u32{ .{ local_it, @offsetOf(Ctx32, "it") }, .{ local_stack, @offsetOf(Ctx32, "stack") }, .{ local_frame, @offsetOf(Ctx32, "frame") }, .{ local_code, @offsetOf(Ctx32, "code") } }) |p| {
        try b.localGet(local_ctx);
        try b.i32Load(p[1]);
        try b.localSet(p[0]);
    }

    try b.block(); // $fallback
    const fallback_level = b.open;
    try b.block(); // $go
    const go_level = b.open;
    for (ents) |e| {
        try b.localGet(local_ctx);
        try b.i32Load(@offsetOf(Ctx32, "pc"));
        try b.i32Const(@bitCast(e));
        try b.i32Op(.eq);
        try b.localGet(local_ctx);
        try b.i32Load(@offsetOf(Ctx32, "sp"));
        try b.i32Const(info.depth[e]);
        try b.i32Op(.eq);
        try b.i32Op(.@"and");
        try b.if_();
        try b.i32Const(@intCast(block_of[e]));
        try b.localSet(local_blk);
        try b.br(b.open - go_level);
        try b.end();
    }
    try b.br(b.open - fallback_level);
    try b.end(); // $go
    try b.loop(); // $top
    g.top_level = b.open;
    var k = m;
    while (k > 0) {
        k -= 1;
        try b.block();
        level[k] = b.open;
    }
    {
        const depths = try a.alloc(u32, m);
        defer a.free(depths);
        for (depths, 0..) |*d, j| d.* = b.open - level[j];
        try b.localGet(local_blk);
        try b.brTable(depths, b.open - fallback_level);
    }
    for (starts.items, 0..) |start, j| {
        try b.end(); // $Bj: the code of block j starts here.
        g.cur = @intCast(j);
        const stop = if (j + 1 < m) starts.items[j + 1] else n;
        for (start..stop) |pc| {
            if (!info.reachable[pc]) continue;
            try g.instruction(@intCast(pc));
        }
    }
    try b.end(); // $top
    try b.unreachable_();
    try b.end(); // $fallback
    try b.i32Const(status_exit);
    std.debug.assert(b.open == 0);
    return b.w.finish();
}

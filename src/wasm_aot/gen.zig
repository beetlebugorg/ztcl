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
const wasm = @import("wasm.zig");

const Allocator = std.mem.Allocator;
const Helper = helpers.Helper;
const Body = wasm.Body;

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

pub const Error = Allocator.Error || error{MissingHelper};

const local_ctx = 0;
const local_blk = 1;
const local_r = 2;

const Gen = struct {
    a: Allocator,
    b: Body,
    code: *const vm.Code,
    info: *const verify.Info,
    h: *const [helpers.count]u32,
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
            },
        }
    }
};

/// The code entry of the function of `code`. `h` is the helper index
/// table for the kind of `code`.
pub fn function(a: Allocator, code: *const vm.Code, info: *const verify.Info, h: *const [helpers.count]u32) Error![]u8 {
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

    var g: Gen = .{ .a = a, .b = .{ .a = a }, .code = code, .info = info, .h = h, .block_of = block_of, .level = level, .top_level = 0 };
    defer g.b.deinit();
    const b = &g.b;

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
    return b.entry(a, 2, 0);
}

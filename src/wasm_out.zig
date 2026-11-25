//! A writer and a reader of WebAssembly binary modules.
//!
//! The writer encodes a module from its parts: the type, function,
//! memory, global, export, code, and custom sections, in the order of
//! the specification. Numbers are LEB128: unsigned for counts and
//! indices, signed for the constants of `i32.const` and `i64.const`.
//!
//! `Body` builds the code of one function. Each instruction method
//! checks its operand types against a small stack of value types, as
//! the validation algorithm of the specification does, and returns
//! `error.InvalidBody` before it writes a bad instruction. A control
//! frame records the stack height at its start, so `end` can check the
//! result of a block, and code after `br` or `return` is unreachable
//! with a polymorphic stack.
//!
//! The reader splits a module into its sections, for the linker of
//! `wasm_link.zig`.
//!
//! The source is the WebAssembly Core Specification 2.0, chapters 2
//! (structure), 3 (validation), and 5 (binary format). See
//! `docs/references/wasm-compile.md`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const magic = "\x00asm\x01\x00\x00\x00";

pub const ValType = enum(u8) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
    v128 = 0x7b,
};

pub const Error = Allocator.Error || error{InvalidBody};

pub fn uleb(list: *std.ArrayList(u8), a: Allocator, v: u64) Allocator.Error!void {
    var x = v;
    while (true) {
        const byte: u8 = @truncate(x & 0x7f);
        x >>= 7;
        if (x == 0) return list.append(a, byte);
        try list.append(a, byte | 0x80);
    }
}

pub fn sleb(list: *std.ArrayList(u8), a: Allocator, v: i64) Allocator.Error!void {
    var x = v;
    while (true) {
        const byte: u8 = @truncate(@as(u64, @bitCast(x)) & 0x7f);
        x >>= 7;
        const done = (x == 0 and byte & 0x40 == 0) or (x == -1 and byte & 0x40 != 0);
        if (done) return list.append(a, byte);
        try list.append(a, byte | 0x80);
    }
}

pub fn name(list: *std.ArrayList(u8), a: Allocator, s: []const u8) Allocator.Error!void {
    try uleb(list, a, s.len);
    try list.appendSlice(a, s);
}

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,

    pub fn encode(t: FuncType, list: *std.ArrayList(u8), a: Allocator) Allocator.Error!void {
        try list.append(a, 0x60);
        try uleb(list, a, t.params.len);
        for (t.params) |p| try list.append(a, @intFromEnum(p));
        try uleb(list, a, t.results.len);
        for (t.results) |r| try list.append(a, @intFromEnum(r));
    }
};

pub const Limits = struct {
    min: u32,
    max: ?u32 = null,

    pub fn encode(l: Limits, list: *std.ArrayList(u8), a: Allocator) Allocator.Error!void {
        try list.append(a, if (l.max == null) 0x00 else 0x01);
        try uleb(list, a, l.min);
        if (l.max) |m| try uleb(list, a, m);
    }
};

pub const Global = struct {
    t: ValType,
    mutable: bool = false,
    /// The bits of the constant of the init expression.
    init: u64,

    pub fn encode(g: Global, list: *std.ArrayList(u8), a: Allocator) Allocator.Error!void {
        try list.append(a, @intFromEnum(g.t));
        try list.append(a, @intFromBool(g.mutable));
        switch (g.t) {
            .i32 => {
                try list.append(a, 0x41);
                try sleb(list, a, @as(i32, @bitCast(@as(u32, @truncate(g.init)))));
            },
            .i64 => {
                try list.append(a, 0x42);
                try sleb(list, a, @bitCast(g.init));
            },
            .f64 => {
                try list.append(a, 0x44);
                try list.appendSlice(a, std.mem.asBytes(&std.mem.nativeToLittle(u64, g.init)));
            },
            else => unreachable,
        }
        try list.append(a, 0x0b);
    }
};

pub const ExportKind = enum(u8) { func = 0, table = 1, memory = 2, global = 3 };

pub const Export = struct {
    name: []const u8,
    kind: ExportKind,
    index: u32,

    pub fn encode(e: Export, list: *std.ArrayList(u8), a: Allocator) Allocator.Error!void {
        try name(list, a, e.name);
        try list.append(a, @intFromEnum(e.kind));
        try uleb(list, a, e.index);
    }
};

pub const Custom = struct { name: []const u8, data: []const u8 };

/// A module with no imports. `codes` holds the encoded bodies from
/// `Body.finish`, one for each entry of `funcs`.
pub const Module = struct {
    types: []const FuncType = &.{},
    funcs: []const u32 = &.{},
    memories: []const Limits = &.{},
    globals: []const Global = &.{},
    exports: []const Export = &.{},
    codes: []const []const u8 = &.{},
    customs: []const Custom = &.{},

    pub fn write(m: Module, a: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, magic);
        var sec: std.ArrayList(u8) = .empty;
        defer sec.deinit(a);
        inline for (.{
            .{ 1, "types" }, .{ 3, "funcs" }, .{ 5, "memories" }, .{ 6, "globals" }, .{ 7, "exports" }, .{ 10, "codes" },
        }) |s| {
            const items = @field(m, s[1]);
            if (items.len > 0) {
                sec.clearRetainingCapacity();
                try uleb(&sec, a, items.len);
                for (items) |it| switch (@TypeOf(it)) {
                    u32 => try uleb(&sec, a, it),
                    []const u8 => try sec.appendSlice(a, it),
                    else => try it.encode(&sec, a),
                };
                try section(&out, a, s[0], sec.items);
            }
        }
        for (m.customs) |c| {
            sec.clearRetainingCapacity();
            try name(&sec, a, c.name);
            try sec.appendSlice(a, c.data);
            try section(&out, a, 0, sec.items);
        }
        return out.toOwnedSlice(a);
    }
};

pub fn section(out: *std.ArrayList(u8), a: Allocator, id: u8, body: []const u8) Allocator.Error!void {
    try out.append(a, id);
    try uleb(out, a, body.len);
    try out.appendSlice(a, body);
}

// ---- The function body builder ----

const Frame = struct {
    kind: enum { block, loop, @"if", @"else", func },
    height: usize,
    result: ?ValType,
    dead: bool = false,
};

/// A memory argument: the alignment as a power of 2, and the offset.
pub const Mem = struct { align_log2: u32, offset: u32 = 0 };

pub const Body = struct {
    a: Allocator,
    code: std.ArrayList(u8) = .empty,
    locals: std.ArrayList(ValType) = .empty,
    params: usize,
    stack: std.ArrayList(ValType) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    /// The types of the functions that `call` can name.
    funcs: []const FuncType,
    /// The value types of the globals.
    globals: []const ValType,

    pub fn init(a: Allocator, t: FuncType, funcs: []const FuncType, globals: []const ValType) Error!Body {
        var b: Body = .{ .a = a, .params = t.params.len, .funcs = funcs, .globals = globals };
        try b.locals.appendSlice(a, t.params);
        if (t.results.len > 1) return error.InvalidBody;
        try b.frames.append(a, .{ .kind = .func, .height = 0, .result = if (t.results.len == 1) t.results[0] else null });
        return b;
    }

    /// Adds a local and returns its index.
    pub fn local(b: *Body, t: ValType) Error!u32 {
        try b.locals.append(b.a, t);
        return @intCast(b.locals.items.len - 1);
    }

    fn top(b: *Body) *Frame {
        return &b.frames.items[b.frames.items.len - 1];
    }

    fn push(b: *Body, t: ValType) Error!void {
        try b.stack.append(b.a, t);
    }

    fn pop(b: *Body, want: ValType) Error!void {
        const f = b.top();
        if (b.stack.items.len == f.height) {
            if (f.dead) return;
            return error.InvalidBody;
        }
        if (b.stack.pop().? != want) return error.InvalidBody;
    }

    fn op(b: *Body, byte: u8) Error!void {
        try b.code.append(b.a, byte);
    }

    fn simd(b: *Body, sub: u32) Error!void {
        try b.code.append(b.a, 0xfd);
        try uleb(&b.code, b.a, sub);
    }

    /// The code after this point is unreachable.
    fn kill(b: *Body) void {
        const f = b.top();
        b.stack.shrinkRetainingCapacity(f.height);
        f.dead = true;
    }

    fn blockType(b: *Body, result: ?ValType) Error!void {
        try b.op(if (result) |r| @intFromEnum(r) else 0x40);
    }

    pub fn block(b: *Body, result: ?ValType) Error!void {
        try b.op(0x02);
        try b.blockType(result);
        try b.frames.append(b.a, .{ .kind = .block, .height = b.stack.items.len, .result = result });
    }

    pub fn loop(b: *Body, result: ?ValType) Error!void {
        try b.op(0x03);
        try b.blockType(result);
        try b.frames.append(b.a, .{ .kind = .loop, .height = b.stack.items.len, .result = result });
    }

    pub fn @"if"(b: *Body, result: ?ValType) Error!void {
        try b.pop(.i32);
        try b.op(0x04);
        try b.blockType(result);
        try b.frames.append(b.a, .{ .kind = .@"if", .height = b.stack.items.len, .result = result });
    }

    fn closeCheck(b: *Body) Error!Frame {
        const f = b.top().*;
        if (f.result) |r| try b.pop(r);
        if (b.stack.items.len != f.height) return error.InvalidBody;
        return f;
    }

    pub fn @"else"(b: *Body) Error!void {
        const f = try b.closeCheck();
        if (f.kind != .@"if") return error.InvalidBody;
        try b.op(0x05);
        b.top().* = .{ .kind = .@"else", .height = f.height, .result = f.result };
    }

    pub fn end(b: *Body) Error!void {
        const f = try b.closeCheck();
        // An `if` with a result needs an `else`.
        if (f.kind == .@"if" and f.result != null) return error.InvalidBody;
        if (f.kind == .func) return error.InvalidBody;
        try b.op(0x0b);
        _ = b.frames.pop();
        if (f.result) |r| try b.push(r);
    }

    /// The label types of a branch to the frame `depth` levels out.
    fn labelType(b: *Body, depth: u32) Error!?ValType {
        if (depth >= b.frames.items.len) return error.InvalidBody;
        const f = b.frames.items[b.frames.items.len - 1 - depth];
        return if (f.kind == .loop) null else f.result;
    }

    pub fn br(b: *Body, depth: u32) Error!void {
        if (try b.labelType(depth)) |t| try b.pop(t);
        try b.op(0x0c);
        try uleb(&b.code, b.a, depth);
        b.kill();
    }

    pub fn brIf(b: *Body, depth: u32) Error!void {
        try b.pop(.i32);
        const t = try b.labelType(depth);
        if (t) |v| try b.pop(v);
        try b.op(0x0d);
        try uleb(&b.code, b.a, depth);
        if (t) |v| try b.push(v);
    }

    pub fn ret(b: *Body) Error!void {
        if (b.frames.items[0].result) |r| try b.pop(r);
        try b.op(0x0f);
        b.kill();
    }

    pub fn call(b: *Body, func: u32) Error!void {
        if (func >= b.funcs.len) return error.InvalidBody;
        const t = b.funcs[func];
        var i = t.params.len;
        while (i > 0) {
            i -= 1;
            try b.pop(t.params[i]);
        }
        try b.op(0x10);
        try uleb(&b.code, b.a, func);
        for (t.results) |r| try b.push(r);
    }

    pub fn drop(b: *Body, t: ValType) Error!void {
        try b.pop(t);
        try b.op(0x1a);
    }

    /// `select` for a number type. A v128 select needs the typed form.
    pub fn select(b: *Body, t: ValType) Error!void {
        try b.pop(.i32);
        try b.pop(t);
        try b.pop(t);
        if (t == .v128) {
            try b.op(0x1c);
            try uleb(&b.code, b.a, 1);
            try b.op(@intFromEnum(t));
        } else try b.op(0x1b);
        try b.push(t);
    }

    fn localType(b: *Body, i: u32) Error!ValType {
        if (i >= b.locals.items.len) return error.InvalidBody;
        return b.locals.items[i];
    }

    pub fn localGet(b: *Body, i: u32) Error!void {
        const t = try b.localType(i);
        try b.op(0x20);
        try uleb(&b.code, b.a, i);
        try b.push(t);
    }

    pub fn localSet(b: *Body, i: u32) Error!void {
        try b.pop(try b.localType(i));
        try b.op(0x21);
        try uleb(&b.code, b.a, i);
    }

    pub fn localTee(b: *Body, i: u32) Error!void {
        const t = try b.localType(i);
        try b.pop(t);
        try b.op(0x22);
        try uleb(&b.code, b.a, i);
        try b.push(t);
    }

    pub fn globalGet(b: *Body, i: u32) Error!void {
        if (i >= b.globals.len) return error.InvalidBody;
        try b.op(0x23);
        try uleb(&b.code, b.a, i);
        try b.push(b.globals[i]);
    }

    fn memarg(b: *Body, m: Mem) Error!void {
        try uleb(&b.code, b.a, m.align_log2);
        try uleb(&b.code, b.a, m.offset);
    }

    pub const Load = enum(u8) { i32 = 0x28, i64 = 0x29, f64 = 0x2b, i32_8u = 0x2d };
    pub const Store = enum(u8) { i32 = 0x36, i64 = 0x37, f64 = 0x39, i32_8 = 0x3a };

    fn loadType(l: Load) ValType {
        return switch (l) {
            .i32, .i32_8u => .i32,
            .i64 => .i64,
            .f64 => .f64,
        };
    }

    pub fn load(b: *Body, l: Load, m: Mem) Error!void {
        try b.pop(.i32);
        try b.op(@intFromEnum(l));
        try b.memarg(m);
        try b.push(loadType(l));
    }

    pub fn store(b: *Body, s: Store, m: Mem) Error!void {
        try b.pop(switch (s) {
            .i32, .i32_8 => .i32,
            .i64 => .i64,
            .f64 => .f64,
        });
        try b.pop(.i32);
        try b.op(@intFromEnum(s));
        try b.memarg(m);
    }

    pub fn v128Load(b: *Body, m: Mem) Error!void {
        try b.pop(.i32);
        try b.simd(0x00);
        try b.memarg(m);
        try b.push(.v128);
    }

    pub fn v128Store(b: *Body, m: Mem) Error!void {
        try b.pop(.v128);
        try b.pop(.i32);
        try b.simd(0x0b);
        try b.memarg(m);
    }

    /// `memory.fill` of memory 0: dest, value, length.
    pub fn memoryFill(b: *Body) Error!void {
        try b.pop(.i32);
        try b.pop(.i32);
        try b.pop(.i32);
        try b.op(0xfc);
        try uleb(&b.code, b.a, 11);
        try b.op(0x00);
    }

    pub fn i32Const(b: *Body, v: i32) Error!void {
        try b.op(0x41);
        try sleb(&b.code, b.a, v);
        try b.push(.i32);
    }

    pub fn i64Const(b: *Body, v: i64) Error!void {
        try b.op(0x42);
        try sleb(&b.code, b.a, v);
        try b.push(.i64);
    }

    pub fn f64Const(b: *Body, v: f64) Error!void {
        try b.op(0x44);
        try b.code.appendSlice(b.a, std.mem.asBytes(&std.mem.nativeToLittle(u64, @bitCast(v))));
        try b.push(.f64);
    }

    pub fn v128Const(b: *Body, bytes: [16]u8) Error!void {
        try b.simd(0x0c);
        try b.code.appendSlice(b.a, &bytes);
        try b.push(.v128);
    }

    /// The scalar instructions with their opcodes and types.
    pub const Num = enum(u8) {
        i32_eqz = 0x45,
        i32_eq = 0x46,
        i32_ne = 0x47,
        i32_lt_s = 0x48,
        i32_lt_u = 0x49,
        i32_gt_s = 0x4a,
        i32_gt_u = 0x4b,
        i32_le_u = 0x4d,
        i32_ge_u = 0x4f,
        i64_eqz = 0x50,
        i64_lt_s = 0x53,
        i64_ge_s = 0x59,
        f64_eq = 0x61,
        f64_ne = 0x62,
        f64_lt = 0x63,
        f64_gt = 0x64,
        f64_le = 0x65,
        f64_ge = 0x66,
        i32_add = 0x6a,
        i32_sub = 0x6b,
        i32_mul = 0x6c,
        i32_and = 0x71,
        i32_or = 0x72,
        i32_xor = 0x73,
        i32_shl = 0x74,
        i32_shr_u = 0x76,
        i64_add = 0x7c,
        i64_sub = 0x7d,
        i64_mul = 0x7e,
        f64_abs = 0x99,
        f64_neg = 0x9a,
        f64_ceil = 0x9b,
        f64_floor = 0x9c,
        f64_trunc = 0x9d,
        f64_sqrt = 0x9f,
        f64_add = 0xa0,
        f64_sub = 0xa1,
        f64_mul = 0xa2,
        f64_div = 0xa3,
        i64_extend_i32_u = 0xad,
        f64_convert_i32_u = 0xb8,

        fn sig(n: Num) struct { []const ValType, ValType } {
            return switch (n) {
                .i32_eqz => .{ &.{.i32}, .i32 },
                .i32_eq, .i32_ne, .i32_lt_s, .i32_lt_u, .i32_gt_s, .i32_gt_u, .i32_le_u, .i32_ge_u, .i32_add, .i32_sub, .i32_mul, .i32_and, .i32_or, .i32_xor, .i32_shl, .i32_shr_u => .{ &.{ .i32, .i32 }, .i32 },
                .i64_eqz => .{ &.{.i64}, .i32 },
                .i64_lt_s, .i64_ge_s => .{ &.{ .i64, .i64 }, .i32 },
                .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge => .{ &.{ .f64, .f64 }, .i32 },
                .i64_add, .i64_sub, .i64_mul => .{ &.{ .i64, .i64 }, .i64 },
                .f64_abs, .f64_neg, .f64_ceil, .f64_floor, .f64_trunc, .f64_sqrt => .{ &.{.f64}, .f64 },
                .f64_add, .f64_sub, .f64_mul, .f64_div => .{ &.{ .f64, .f64 }, .f64 },
                .i64_extend_i32_u => .{ &.{.i32}, .i64 },
                .f64_convert_i32_u => .{ &.{.i32}, .f64 },
            };
        }
    };

    pub fn num(b: *Body, n: Num) Error!void {
        const s = n.sig();
        var i = s[0].len;
        while (i > 0) {
            i -= 1;
            try b.pop(s[0][i]);
        }
        try b.op(@intFromEnum(n));
        try b.push(s[1]);
    }

    /// The SIMD instructions of the subset, with their opcodes after the
    /// prefix 0xfd.
    pub const Vec = enum(u32) {
        f64x2_eq = 71,
        f64x2_ne = 72,
        f64x2_lt = 73,
        f64x2_gt = 74,
        f64x2_le = 75,
        f64x2_ge = 76,
        v128_not = 77,
        v128_and = 78,
        v128_andnot = 79,
        v128_or = 80,
        v128_xor = 81,
        v128_bitselect = 82,
        v128_any_true = 83,
        f64x2_ceil = 116,
        f64x2_floor = 117,
        f64x2_trunc = 122,
        f64x2_abs = 236,
        f64x2_neg = 237,
        f64x2_sqrt = 239,
        f64x2_add = 240,
        f64x2_sub = 241,
        f64x2_mul = 242,
        f64x2_div = 243,

        fn arity(v: Vec) usize {
            return switch (v) {
                .v128_not, .v128_any_true, .f64x2_ceil, .f64x2_floor, .f64x2_trunc, .f64x2_abs, .f64x2_neg, .f64x2_sqrt => 1,
                .v128_bitselect => 3,
                else => 2,
            };
        }
    };

    pub fn vec(b: *Body, v: Vec) Error!void {
        for (0..v.arity()) |_| try b.pop(.v128);
        try b.simd(@intFromEnum(v));
        try b.push(if (v == .v128_any_true) .i32 else .v128);
    }

    pub fn f64x2Splat(b: *Body) Error!void {
        try b.pop(.f64);
        try b.simd(20);
        try b.push(.v128);
    }

    pub fn f64x2ExtractLane(b: *Body, lane: u8) Error!void {
        if (lane > 1) return error.InvalidBody;
        try b.pop(.v128);
        try b.simd(33);
        try b.op(lane);
        try b.push(.f64);
    }

    pub fn f64x2ReplaceLane(b: *Body, lane: u8) Error!void {
        if (lane > 1) return error.InvalidBody;
        try b.pop(.f64);
        try b.pop(.v128);
        try b.simd(34);
        try b.op(lane);
        try b.push(.v128);
    }

    /// Ends the function and returns the entry of the code section: the
    /// size, the runs of locals after the parameters, and the code.
    pub fn finish(b: *Body) Error![]u8 {
        if (b.frames.items.len != 1) return error.InvalidBody;
        _ = try b.closeCheck();
        try b.op(0x0b);
        const a = b.a;
        var entry: std.ArrayList(u8) = .empty;
        const extra = b.locals.items[b.params..];
        var runs: usize = 0;
        var i: usize = 0;
        while (i < extra.len) : (runs += 1) {
            const t = extra[i];
            while (i < extra.len and extra[i] == t) i += 1;
        }
        try uleb(&entry, a, runs);
        i = 0;
        while (i < extra.len) {
            const t = extra[i];
            const start = i;
            while (i < extra.len and extra[i] == t) i += 1;
            try uleb(&entry, a, i - start);
            try entry.append(a, @intFromEnum(t));
        }
        try entry.appendSlice(a, b.code.items);
        var out: std.ArrayList(u8) = .empty;
        try uleb(&out, a, entry.items.len);
        try out.appendSlice(a, entry.items);
        entry.deinit(a);
        return out.toOwnedSlice(a);
    }
};

// ---- The reader ----

pub const Section = struct { id: u8, body: []const u8 };

pub const ReadError = Allocator.Error || error{BadModule};

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn byte(r: *Reader) ReadError!u8 {
        if (r.pos >= r.bytes.len) return error.BadModule;
        r.pos += 1;
        return r.bytes[r.pos - 1];
    }

    pub fn uleb32(r: *Reader) ReadError!u32 {
        var v: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try r.byte();
            v |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            if (shift >= 28) return error.BadModule;
            shift += 7;
        }
        return std.math.cast(u32, v) orelse error.BadModule;
    }

    pub fn take(r: *Reader, n: usize) ReadError![]const u8 {
        if (n > r.bytes.len - r.pos) return error.BadModule;
        r.pos += n;
        return r.bytes[r.pos - n .. r.pos];
    }

    pub fn str(r: *Reader) ReadError![]const u8 {
        return r.take(try r.uleb32());
    }

    pub fn done(r: *const Reader) bool {
        return r.pos == r.bytes.len;
    }
};

/// Splits a module into its sections. The bodies point into `bytes`.
pub fn readSections(a: Allocator, bytes: []const u8) ReadError![]Section {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], magic)) return error.BadModule;
    var r: Reader = .{ .bytes = bytes, .pos = 8 };
    var out: std.ArrayList(Section) = .empty;
    while (!r.done()) {
        const id = try r.byte();
        if (id > 12) return error.BadModule;
        try out.append(a, .{ .id = id, .body = try r.take(try r.uleb32()) });
    }
    return out.toOwnedSlice(a);
}

// ---- Tests ----

const testing = std.testing;

test "LEB128 encodes known values" {
    const a = testing.allocator;
    var l: std.ArrayList(u8) = .empty;
    defer l.deinit(a);
    try uleb(&l, a, 624485);
    try testing.expectEqualSlices(u8, &.{ 0xe5, 0x8e, 0x26 }, l.items);
    l.clearRetainingCapacity();
    try sleb(&l, a, -123456);
    try testing.expectEqualSlices(u8, &.{ 0xc0, 0xbb, 0x78 }, l.items);
    l.clearRetainingCapacity();
    try sleb(&l, a, 64);
    try testing.expectEqualSlices(u8, &.{ 0xc0, 0x00 }, l.items);
    l.clearRetainingCapacity();
    try sleb(&l, a, -64);
    try testing.expectEqualSlices(u8, &.{0x40}, l.items);
}

/// The module of `answer`: one function `() -> i32` that returns 42.
fn answerModule(a: Allocator) ![]u8 {
    const t: FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var b = try Body.init(a, t, &.{t}, &.{});
    try b.i32Const(42);
    const code = try b.finish();
    const m: Module = .{ .types = &.{t}, .funcs = &.{0}, .exports = &.{.{ .name = "f", .kind = .func, .index = 0 }}, .codes = &.{code} };
    return m.write(a);
}

test "a function that returns 42 has the bytes of the specification" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try answerModule(arena.allocator());
    try testing.expectEqualSlices(u8, magic ++ [_]u8{
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: () -> i32
        0x03, 0x02, 0x01, 0x00, // func: type 0
        0x07, 0x05, 0x01, 0x01, 'f', 0x00, 0x00, // export "f" func 0
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b, // code: i32.const 42
    }, bytes);
    try writeTestModule("answer", bytes);
}

test "the writer rejects a body with a wrong operand type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: FuncType = .{ .params = &.{.f64}, .results = &.{.i32} };
    var b = try Body.init(a, t, &.{}, &.{});
    try b.localGet(0);
    try testing.expectError(error.InvalidBody, b.num(.i32_eqz));
    var c = try Body.init(a, t, &.{}, &.{});
    try c.localGet(0);
    try testing.expectError(error.InvalidBody, c.finish());
    var d = try Body.init(a, t, &.{}, &.{});
    try d.block(.i32);
    try testing.expectError(error.InvalidBody, d.end());
    // Code after `br` is unreachable, so `end` accepts an empty stack.
    var e = try Body.init(a, t, &.{}, &.{});
    try e.block(.i32);
    try e.i32Const(1);
    try e.br(0);
    try e.end();
    _ = try e.finish();
}

test "a SIMD module and a module with memory, globals, and loops validate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // simd(p: i32) -> f64: the sum of the two lanes of max(v, 0) for
    // the v128 at p, with a select of the compare.
    const t: FuncType = .{ .params = &.{.i32}, .results = &.{.f64} };
    var b = try Body.init(a, t, &.{t}, &.{.i32});
    const v = try b.local(.v128);
    try b.localGet(0);
    try b.v128Load(.{ .align_log2 = 3 });
    try b.localSet(v);
    try b.localGet(v);
    try b.f64Const(0);
    try b.f64x2Splat();
    try b.localGet(v);
    try b.f64Const(0);
    try b.f64x2Splat();
    try b.vec(.f64x2_gt);
    try b.vec(.v128_bitselect);
    try b.localTee(v);
    try b.f64x2ExtractLane(0);
    try b.localGet(v);
    try b.f64x2ExtractLane(1);
    try b.num(.f64_add);
    const simd_code = try b.finish();
    // loop(n: i32) -> f64: the sum of n doubles from the global base,
    // with a loop, br_if, and loads.
    var l = try Body.init(a, t, &.{t}, &.{.i32});
    const i = try l.local(.i32);
    const acc = try l.local(.f64);
    try l.block(null);
    try l.loop(null);
    try l.localGet(i);
    try l.localGet(0);
    try l.num(.i32_ge_u);
    try l.brIf(1);
    try l.localGet(acc);
    try l.globalGet(0);
    try l.localGet(i);
    try l.i32Const(3);
    try l.num(.i32_shl);
    try l.num(.i32_add);
    try l.load(.f64, .{ .align_log2 = 3 });
    try l.num(.f64_add);
    try l.localSet(acc);
    try l.localGet(i);
    try l.i32Const(1);
    try l.num(.i32_add);
    try l.localSet(i);
    try l.br(0);
    try l.end();
    try l.end();
    try l.localGet(acc);
    const loop_code = try l.finish();
    const m: Module = .{
        .types = &.{t},
        .funcs = &.{ 0, 0 },
        .memories = &.{.{ .min = 1, .max = 1 }},
        .globals = &.{.{ .t = .i32, .init = 64 }},
        .exports = &.{
            .{ .name = "simd", .kind = .func, .index = 0 },
            .{ .name = "sum", .kind = .func, .index = 1 },
            .{ .name = "memory", .kind = .memory, .index = 0 },
            .{ .name = "base", .kind = .global, .index = 0 },
        },
        .codes = &.{ simd_code, loop_code },
        .customs = &.{.{ .name = "ztcl.test", .data = "{}" }},
    };
    const bytes = try m.write(a);
    const secs = try readSections(a, bytes);
    const ids = [_]u8{ 1, 3, 5, 6, 7, 10, 0 };
    try testing.expectEqual(ids.len, secs.len);
    for (secs, ids) |s, id| try testing.expectEqual(id, s.id);
    try writeTestModule("simd", bytes);
}

/// Writes a module of a test to `zig-out/wasm-out/` for
/// `tools/wasm-validate.sh`.
fn writeTestModule(base: []const u8, bytes: []const u8) !void {
    const io = testing.io;
    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "zig-out/wasm-out") catch return;
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "zig-out/wasm-out/{s}.wasm", .{base});
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

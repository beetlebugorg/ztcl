//! A small writer and reader of WebAssembly binary modules.
//!
//! `Body` writes the code of one function: LEB128 numbers and the
//! instructions that the code generator of `gen.zig` uses. `Module`
//! splits a module into its sections, and `link` appends functions, a
//! table segment, and data segments to a module. The format is the
//! binary format of the WebAssembly 2.0 specification. A section is an
//! id byte, a LEB128 size, and the bytes. Each change below is an
//! append, so the indices of the functions, the types, and the table
//! entries of the input stay the same.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{ BadModule, Unsupported };

pub fn uleb(a: Allocator, out: *std.ArrayList(u8), v: u64) Allocator.Error!void {
    var x = v;
    while (true) {
        const b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x == 0) return out.append(a, b);
        try out.append(a, b | 0x80);
    }
}

pub fn sleb(a: Allocator, out: *std.ArrayList(u8), v: i64) Allocator.Error!void {
    var x = v;
    while (true) {
        const b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        const done = (x == 0 and b & 0x40 == 0) or (x == -1 and b & 0x40 != 0);
        if (done) return out.append(a, b);
        try out.append(a, b | 0x80);
    }
}

/// A cursor over the bytes of a module.
pub const Reader = struct {
    b: []const u8,
    pos: usize = 0,

    pub fn byte(r: *Reader) Error!u8 {
        if (r.pos >= r.b.len) return error.BadModule;
        r.pos += 1;
        return r.b[r.pos - 1];
    }

    pub fn uleb(r: *Reader) Error!u64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try r.byte();
            if (shift >= 64) return error.BadModule;
            v |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return v;
            shift += 7;
        }
    }

    pub fn u32_(r: *Reader) Error!u32 {
        return std.math.cast(u32, try r.uleb()) orelse error.BadModule;
    }

    pub fn sleb(r: *Reader) Error!i64 {
        var v: i64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try r.byte();
            if (shift >= 64) return error.BadModule;
            v |= @as(i64, b & 0x7f) << @intCast(shift);
            shift += 7;
            if (b & 0x80 == 0) {
                if (shift < 64 and b & 0x40 != 0) v |= @as(i64, -1) << @intCast(shift);
                return v;
            }
        }
    }

    pub fn bytes(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.b.len - r.pos) return error.BadModule;
        r.pos += n;
        return r.b[r.pos - n .. r.pos];
    }

    pub fn name(r: *Reader) Error![]const u8 {
        return r.bytes(try r.u32_());
    }

    /// A constant expression `i32.const N end`. Other forms give
    /// `Unsupported`.
    pub fn constI32(r: *Reader) Error!i32 {
        if (try r.byte() != 0x41) return error.Unsupported;
        const v = try r.sleb();
        if (try r.byte() != 0x0b) return error.Unsupported;
        return std.math.cast(i32, v) orelse error.BadModule;
    }

    pub fn limits(r: *Reader) Error!Limits {
        const flag = try r.byte();
        if (flag > 1) return error.Unsupported;
        const min = try r.u32_();
        return .{ .min = min, .max = if (flag == 1) try r.u32_() else null };
    }
};

pub const Limits = struct { min: u32, max: ?u32 };

fn writeLimits(a: Allocator, out: *std.ArrayList(u8), l: Limits) Allocator.Error!void {
    try out.append(a, if (l.max == null) 0 else 1);
    try uleb(a, out, l.min);
    if (l.max) |m| try uleb(a, out, m);
}

pub const ValType = enum(u8) { i32 = 0x7f, i64 = 0x7e, f32 = 0x7d, f64 = 0x7c };

/// The code of one function. `label` counts the open blocks, so a
/// caller can compute the depth of a branch.
pub const Body = struct {
    a: Allocator,
    out: std.ArrayList(u8) = .empty,
    open: u32 = 0,

    pub fn deinit(b: *Body) void {
        b.out.deinit(b.a);
    }

    fn op(b: *Body, o: u8) Allocator.Error!void {
        try b.out.append(b.a, o);
    }

    fn opU(b: *Body, o: u8, v: u64) Allocator.Error!void {
        try b.out.append(b.a, o);
        try uleb(b.a, &b.out, v);
    }

    pub fn block(b: *Body) Allocator.Error!void {
        try b.out.appendSlice(b.a, &.{ 0x02, 0x40 });
        b.open += 1;
    }

    pub fn loop(b: *Body) Allocator.Error!void {
        try b.out.appendSlice(b.a, &.{ 0x03, 0x40 });
        b.open += 1;
    }

    /// `if` with no result.
    pub fn if_(b: *Body) Allocator.Error!void {
        try b.out.appendSlice(b.a, &.{ 0x04, 0x40 });
        b.open += 1;
    }

    pub fn else_(b: *Body) Allocator.Error!void {
        try b.op(0x05);
    }

    pub fn end(b: *Body) Allocator.Error!void {
        try b.op(0x0b);
        b.open -= 1;
    }

    pub fn br(b: *Body, depth: u32) Allocator.Error!void {
        try b.opU(0x0c, depth);
    }

    pub fn brIf(b: *Body, depth: u32) Allocator.Error!void {
        try b.opU(0x0d, depth);
    }

    pub fn brTable(b: *Body, depths: []const u32, default: u32) Allocator.Error!void {
        try b.opU(0x0e, depths.len);
        for (depths) |d| try uleb(b.a, &b.out, d);
        try uleb(b.a, &b.out, default);
    }

    pub fn ret(b: *Body) Allocator.Error!void {
        try b.op(0x0f);
    }

    pub fn unreachable_(b: *Body) Allocator.Error!void {
        try b.op(0x00);
    }

    pub fn call(b: *Body, func: u32) Allocator.Error!void {
        try b.opU(0x10, func);
    }

    pub fn drop(b: *Body) Allocator.Error!void {
        try b.op(0x1a);
    }

    pub fn select(b: *Body) Allocator.Error!void {
        try b.op(0x1b);
    }

    pub fn localGet(b: *Body, i: u32) Allocator.Error!void {
        try b.opU(0x20, i);
    }

    pub fn localSet(b: *Body, i: u32) Allocator.Error!void {
        try b.opU(0x21, i);
    }

    pub fn localTee(b: *Body, i: u32) Allocator.Error!void {
        try b.opU(0x22, i);
    }

    pub fn i32Const(b: *Body, v: i32) Allocator.Error!void {
        try b.op(0x41);
        try sleb(b.a, &b.out, v);
    }

    pub fn i64Const(b: *Body, v: i64) Allocator.Error!void {
        try b.op(0x42);
        try sleb(b.a, &b.out, v);
    }

    /// A load or a store: the opcode, the log2 of the alignment, and the
    /// offset.
    fn mem(b: *Body, o: u8, align_log2: u32, offset: u32) Allocator.Error!void {
        try b.op(o);
        try uleb(b.a, &b.out, align_log2);
        try uleb(b.a, &b.out, offset);
    }

    pub fn i32Load(b: *Body, offset: u32) Allocator.Error!void {
        try b.mem(0x28, 2, offset);
    }
    pub fn i64Load(b: *Body, offset: u32) Allocator.Error!void {
        try b.mem(0x29, 3, offset);
    }
    pub fn i32Load8u(b: *Body, offset: u32) Allocator.Error!void {
        try b.mem(0x2d, 0, offset);
    }
    pub fn i32Load16u(b: *Body, offset: u32) Allocator.Error!void {
        try b.mem(0x2f, 1, offset);
    }
    pub fn i32Store(b: *Body, offset: u32) Allocator.Error!void {
        try b.mem(0x36, 2, offset);
    }
    pub fn i64Store(b: *Body, offset: u32) Allocator.Error!void {
        try b.mem(0x37, 3, offset);
    }
    pub fn i32Store8(b: *Body, offset: u32) Allocator.Error!void {
        try b.mem(0x3a, 0, offset);
    }

    pub const I32 = enum(u8) { eqz = 0x45, eq = 0x46, ne = 0x47, lt_s = 0x48, lt_u = 0x49, gt_s = 0x4a, gt_u = 0x4b, le_s = 0x4c, le_u = 0x4d, ge_s = 0x4e, ge_u = 0x4f, add = 0x6a, sub = 0x6b, mul = 0x6c, @"and" = 0x71, @"or" = 0x72, xor = 0x73, shl = 0x74, shr_u = 0x76 };
    pub const I64 = enum(u8) { eqz = 0x50, eq = 0x51, ne = 0x52, lt_s = 0x53, lt_u = 0x54, gt_s = 0x55, gt_u = 0x56, le_s = 0x57, le_u = 0x58, ge_s = 0x59, ge_u = 0x5a, add = 0x7c, sub = 0x7d, mul = 0x7e, div_s = 0x7f, rem_s = 0x81, @"and" = 0x83, @"or" = 0x84, xor = 0x85, shl = 0x86, shr_s = 0x87, shr_u = 0x88, extend_i32_u = 0xad, extend_i32_s = 0xac, wrap = 0xa7 };

    pub fn i32Op(b: *Body, o: I32) Allocator.Error!void {
        try b.op(@intFromEnum(o));
    }

    pub fn i64Op(b: *Body, o: I64) Allocator.Error!void {
        try b.op(@intFromEnum(o));
    }

    /// The code entry: the vector of local groups, the body, and `end`.
    /// `locals` is one group of i32 locals and one of i64 locals.
    pub fn entry(b: *Body, a: Allocator, i32s: u32, i64s: u32) Allocator.Error![]u8 {
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(a);
        const groups: u32 = @as(u32, @intFromBool(i32s > 0)) + @intFromBool(i64s > 0);
        try uleb(a, &head, groups);
        if (i32s > 0) {
            try uleb(a, &head, i32s);
            try head.append(a, @intFromEnum(ValType.i32));
        }
        if (i64s > 0) {
            try uleb(a, &head, i64s);
            try head.append(a, @intFromEnum(ValType.i64));
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try uleb(a, &out, head.items.len + b.out.items.len + 1);
        try out.appendSlice(a, head.items);
        try out.appendSlice(a, b.out.items);
        try out.append(a, 0x0b);
        return out.toOwnedSlice(a);
    }
};

pub const Section = struct { id: u8, body: []const u8 };

/// A module split into its sections. The bodies point into the input.
pub const Module = struct {
    sections: std.ArrayList(Section) = .empty,

    pub fn parse(a: Allocator, bytes: []const u8) Error!Module {
        if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &.{ 0, 'a', 's', 'm', 1, 0, 0, 0 })) return error.BadModule;
        var m: Module = .{};
        errdefer m.sections.deinit(a);
        var r: Reader = .{ .b = bytes, .pos = 8 };
        while (r.pos < bytes.len) {
            const id = try r.byte();
            const n = try r.u32_();
            try m.sections.append(a, .{ .id = id, .body = try r.bytes(n) });
        }
        return m;
    }

    pub fn deinit(m: *Module, a: Allocator) void {
        m.sections.deinit(a);
    }

    pub fn find(m: *const Module, id: u8) ?[]const u8 {
        for (m.sections.items) |s| if (s.id == id) return s.body;
        return null;
    }

    /// The count of imports of `kind` (0 function, 1 table, 2 memory,
    /// 3 global).
    pub fn importCount(m: *const Module, kind: u8) Error!u32 {
        const body = m.find(2) orelse return 0;
        var r: Reader = .{ .b = body };
        var n: u32 = 0;
        var k = try r.u32_();
        while (k > 0) : (k -= 1) {
            _ = try r.name();
            _ = try r.name();
            const kd = try r.byte();
            switch (kd) {
                0 => _ = try r.u32_(),
                1 => {
                    _ = try r.byte();
                    _ = try r.limits();
                },
                2 => _ = try r.limits(),
                3 => _ = try r.bytes(2),
                else => return error.BadModule,
            }
            if (kd == kind) n += 1;
        }
        return n;
    }

    /// The count of entries of a section that starts with a vector.
    pub fn count(m: *const Module, id: u8) Error!u32 {
        const body = m.find(id) orelse return 0;
        var r: Reader = .{ .b = body };
        return r.u32_();
    }

    /// The index of export `name` of `kind`, or null.
    pub fn exportOf(m: *const Module, name: []const u8, kind: u8) Error!?u32 {
        const body = m.find(7) orelse return null;
        var r: Reader = .{ .b = body };
        var k = try r.u32_();
        while (k > 0) : (k -= 1) {
            const nm = try r.name();
            const kd = try r.byte();
            const idx = try r.u32_();
            if (kd == kind and std.mem.eql(u8, nm, name)) return idx;
        }
        return null;
    }

    /// The value of the immutable global `index`, defined in the module
    /// with `i32.const`.
    pub fn globalI32(m: *const Module, index: u32) Error!i32 {
        const imported = try m.importCount(3);
        if (index < imported) return error.Unsupported;
        const body = m.find(6) orelse return error.BadModule;
        var r: Reader = .{ .b = body };
        const n = try r.u32_();
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            _ = try r.byte();
            const mut = try r.byte();
            if (k + imported == index) {
                if (mut != 0) return error.Unsupported;
                return r.constI32();
            }
            _ = try r.constI32();
        }
        return error.BadModule;
    }

    /// The address that the exported data variable `name` names.
    pub fn dataAddress(m: *const Module, name: []const u8) Error!?u32 {
        const g = try m.exportOf(name, 3) orelse return null;
        return @bitCast(try m.globalI32(g));
    }

    /// The bytes of the active data segments at `addr`, `len` bytes.
    pub fn readData(m: *const Module, addr: u32, out: []u8) Error!void {
        @memset(out, 0);
        const body = m.find(11) orelse return error.BadModule;
        var r: Reader = .{ .b = body };
        var k = try r.u32_();
        var found: usize = 0;
        while (k > 0) : (k -= 1) {
            const flag = try r.u32_();
            const base: ?u32 = switch (flag) {
                0 => @bitCast(try r.constI32()),
                1 => null,
                2 => blk: {
                    if (try r.u32_() != 0) return error.Unsupported;
                    break :blk @bitCast(try r.constI32());
                },
                else => return error.BadModule,
            };
            const data = try r.name();
            const b = base orelse continue;
            // The overlap of [b, b + len) and [addr, addr + out.len).
            const lo = @max(b, addr);
            const hi = @min(@as(u64, b) + data.len, @as(u64, addr) + out.len);
            if (hi <= lo) continue;
            @memcpy(out[lo - addr .. @as(usize, @intCast(hi)) - addr], data[lo - b .. @as(usize, @intCast(hi)) - b]);
            found += @as(usize, @intCast(hi)) - lo;
        }
        if (found < out.len) return error.BadModule;
    }

    /// The facts that `link` changes.
    pub fn layout(m: *const Module) Error!Layout {
        const tb = m.find(4) orelse return error.Unsupported;
        var tr: Reader = .{ .b = tb };
        if (try tr.u32_() != 1) return error.Unsupported;
        if (try tr.byte() != 0x70) return error.Unsupported;
        const table = try tr.limits();
        const mb = m.find(5) orelse return error.Unsupported;
        var mr: Reader = .{ .b = mb };
        if (try mr.u32_() != 1) return error.Unsupported;
        const memory = try mr.limits();
        return .{
            .funcs = try m.importCount(0) + try m.count(3),
            .types = try m.count(1),
            .table = table,
            .memory = memory,
        };
    }
};

pub const Layout = struct {
    /// The count of functions, with the imports: the index of the next one.
    funcs: u32,
    types: u32,
    table: Limits,
    memory: Limits,

    /// The address of the first page that `link` adds.
    pub fn freeAddress(l: Layout) u32 {
        return l.memory.min * page;
    }
};

pub const page: u32 = 65536;

/// What `link` adds to a module.
pub const Addition = struct {
    /// New function types, each in its encoded form (`0x60` ...).
    types: []const []const u8 = &.{},
    /// The type index of each new function.
    funcs: []const u32 = &.{},
    /// The code entry of each new function, from `Body.entry`.
    code: []const []const u8 = &.{},
    /// The new functions that go in the table, after its current entries.
    table_funcs: []const u32 = &.{},
    /// Active data segments, written after the segments of the module.
    data: []const Segment = &.{},
    /// Pages added to the least size of the memory.
    pages: u32 = 0,
};

pub const Segment = struct { addr: u32, bytes: []const u8 };

/// Writes `m` with `add`. The sections keep their order.
pub fn link(a: Allocator, m: *const Module, add: Addition) Error![]u8 {
    const lay = try m.layout();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &.{ 0, 'a', 's', 'm', 1, 0, 0, 0 });
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    var have_elem = false;
    var have_data = false;
    for (m.sections.items) |s| {
        body.clearRetainingCapacity();
        switch (s.id) {
            1 => try appendVec(a, &body, s.body, add.types),
            3 => {
                var r: Reader = .{ .b = s.body };
                const n = try r.u32_();
                try uleb(a, &body, n + add.funcs.len);
                try body.appendSlice(a, s.body[r.pos..]);
                for (add.funcs) |t| try uleb(a, &body, t);
            },
            4 => {
                const grow: u32 = @intCast(add.table_funcs.len);
                try body.appendSlice(a, &.{ 1, 0x70 });
                try writeLimits(a, &body, .{ .min = lay.table.min + grow, .max = if (lay.table.max) |x| x + grow else null });
            },
            5 => {
                try uleb(a, &body, 1);
                const min = lay.memory.min + add.pages;
                if (lay.memory.max) |x| if (x < min) return error.Unsupported;
                try writeLimits(a, &body, .{ .min = min, .max = lay.memory.max });
            },
            9 => {
                have_elem = true;
                try appendElem(a, &body, s.body, lay, add);
            },
            10 => try appendVec(a, &body, s.body, add.code),
            11 => {
                have_data = true;
                try appendData(a, &body, s.body, add.data);
            },
            12 => {
                var r: Reader = .{ .b = s.body };
                try uleb(a, &body, try r.u32_() + add.data.len);
            },
            else => try body.appendSlice(a, s.body),
        }
        // A missing element section goes before the code section.
        if (s.id == 10 and !have_elem and add.table_funcs.len > 0) return error.Unsupported;
        try section(a, &out, s.id, body.items);
    }
    if (!have_data and add.data.len > 0) return error.Unsupported;
    return out.toOwnedSlice(a);
}

fn section(a: Allocator, out: *std.ArrayList(u8), id: u8, body: []const u8) Allocator.Error!void {
    try out.append(a, id);
    try uleb(a, out, body.len);
    try out.appendSlice(a, body);
}

/// A vector section with `more` entries at its end.
fn appendVec(a: Allocator, body: *std.ArrayList(u8), old: []const u8, more: []const []const u8) Error!void {
    var r: Reader = .{ .b = old };
    const n = try r.u32_();
    try uleb(a, body, n + more.len);
    try body.appendSlice(a, old[r.pos..]);
    for (more) |e| try body.appendSlice(a, e);
}

fn appendElem(a: Allocator, body: *std.ArrayList(u8), old: []const u8, lay: Layout, add: Addition) Error!void {
    if (add.table_funcs.len == 0) return body.appendSlice(a, old);
    var r: Reader = .{ .b = old };
    const n = try r.u32_();
    try uleb(a, body, n + 1);
    try body.appendSlice(a, old[r.pos..]);
    // Flag 0: an active segment of table 0 with function indices.
    try body.append(a, 0);
    try body.append(a, 0x41);
    try sleb(a, body, @as(i32, @bitCast(lay.table.min)));
    try body.append(a, 0x0b);
    try uleb(a, body, add.table_funcs.len);
    for (add.table_funcs) |f| try uleb(a, body, f);
}

fn appendData(a: Allocator, body: *std.ArrayList(u8), old: []const u8, segs: []const Segment) Error!void {
    var r: Reader = .{ .b = old };
    const n = try r.u32_();
    try uleb(a, body, n + segs.len);
    try body.appendSlice(a, old[r.pos..]);
    for (segs) |s| {
        try body.append(a, 0);
        try body.append(a, 0x41);
        try sleb(a, body, @as(i32, @bitCast(s.addr)));
        try body.append(a, 0x0b);
        try uleb(a, body, s.bytes.len);
        try body.appendSlice(a, s.bytes);
    }
}

/// The encoded function type `(params) -> (results)`.
pub fn funcType(a: Allocator, params: []const ValType, results: []const ValType) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.append(a, 0x60);
    try uleb(a, &out, params.len);
    for (params) |p| try out.append(a, @intFromEnum(p));
    try uleb(a, &out, results.len);
    for (results) |p| try out.append(a, @intFromEnum(p));
    return out.toOwnedSlice(a);
}

// ---- Tests ----

const testing = std.testing;

test "wasm: LEB128 round trips" {
    const a = testing.allocator;
    const us = [_]u64{ 0, 1, 63, 64, 127, 128, 300, 624485, 0xffff_ffff, std.math.maxInt(u64) };
    for (us) |v| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try uleb(a, &out, v);
        var r: Reader = .{ .b = out.items };
        try testing.expectEqual(v, try r.uleb());
        try testing.expectEqual(out.items.len, r.pos);
    }
    const ss = [_]i64{ 0, 1, -1, 63, 64, -64, -65, 127, -128, 8388608, -123456, std.math.minInt(i64), std.math.maxInt(i64) };
    for (ss) |v| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try sleb(a, &out, v);
        var r: Reader = .{ .b = out.items };
        try testing.expectEqual(v, try r.sleb());
    }
    // Examples of the specification.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try uleb(a, &out, 624485);
    try testing.expectEqualSlices(u8, &.{ 0xe5, 0x8e, 0x26 }, out.items);
    out.clearRetainingCapacity();
    try sleb(a, &out, -123456);
    try testing.expectEqualSlices(u8, &.{ 0xc0, 0xbb, 0x78 }, out.items);
}

/// A module with one table of 2 entries, a memory of 1 page, one data
/// segment, an exported data global, and one function `f` that returns
/// the i32 at address 16.
fn testModule(a: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &.{ 0, 'a', 's', 'm', 1, 0, 0, 0 });
    const t = try funcType(a, &.{}, &.{.i32});
    defer a.free(t);
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(a);
    try uleb(a, &s, 1);
    try s.appendSlice(a, t);
    try section(a, &out, 1, s.items);
    try section(a, &out, 3, &.{ 1, 0 });
    try section(a, &out, 4, &.{ 1, 0x70, 1, 2, 2 });
    try section(a, &out, 5, &.{ 1, 0, 1 });
    try section(a, &out, 6, &.{ 1, 0x7f, 0, 0x41, 16, 0x0b });
    try section(a, &out, 7, &.{ 2, 1, 'f', 0, 0, 1, 'v', 3, 0 });
    try section(a, &out, 9, &.{ 1, 0, 0x41, 1, 0x0b, 1, 0 });
    var b: Body = .{ .a = a };
    defer b.deinit();
    try b.i32Const(16);
    try b.i32Load(0);
    const e = try b.entry(a, 0, 0);
    defer a.free(e);
    s.clearRetainingCapacity();
    try uleb(a, &s, 1);
    try s.appendSlice(a, e);
    try section(a, &out, 10, s.items);
    try section(a, &out, 11, &.{ 1, 0, 0x41, 16, 0x0b, 4, 7, 0, 0, 0 });
    return out.toOwnedSlice(a);
}

test "wasm: read a module and append to it" {
    const a = testing.allocator;
    const bytes = try testModule(a);
    defer a.free(bytes);
    var m = try Module.parse(a, bytes);
    defer m.deinit(a);
    const lay = try m.layout();
    try testing.expectEqual(@as(u32, 1), lay.funcs);
    try testing.expectEqual(@as(u32, 2), lay.table.min);
    try testing.expectEqual(@as(u32, 1), lay.memory.min);
    try testing.expectEqual(@as(?u32, 0), try m.exportOf("f", 0));
    try testing.expectEqual(@as(?u32, 16), try m.dataAddress("v"));
    var word: [4]u8 = undefined;
    try m.readData(16, &word);
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, &word, .little));

    // Add a function that returns 42, put it in the table, and write a
    // new value at address 16 and a word in the new page.
    const t = try funcType(a, &.{}, &.{.i32});
    defer a.free(t);
    var b: Body = .{ .a = a };
    defer b.deinit();
    try b.i32Const(42);
    const e = try b.entry(a, 1, 0);
    defer a.free(e);
    const out = try link(a, &m, .{
        .types = &.{t},
        .funcs = &.{1},
        .code = &.{e},
        .table_funcs = &.{lay.funcs},
        .data = &.{ .{ .addr = 16, .bytes = &.{ 9, 0, 0, 0 } }, .{ .addr = lay.freeAddress(), .bytes = "dir" } },
        .pages = 1,
    });
    defer a.free(out);
    var m2 = try Module.parse(a, out);
    defer m2.deinit(a);
    const lay2 = try m2.layout();
    try testing.expectEqual(@as(u32, 2), lay2.funcs);
    try testing.expectEqual(@as(u32, 2), lay2.types);
    try testing.expectEqual(Limits{ .min = 3, .max = 3 }, lay2.table);
    try testing.expectEqual(@as(u32, 2), lay2.memory.min);
    try m2.readData(16, &word);
    try testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, &word, .little));
    var dir: [3]u8 = undefined;
    try m2.readData(page, &dir);
    try testing.expectEqualStrings("dir", &dir);
    try testing.expectEqual(@as(u32, 2), try m2.count(9));
}

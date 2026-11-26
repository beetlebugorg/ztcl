//! Appends functions to a copy of a WebAssembly module.
//!
//! The input is the runtime of point procs (`point_rt.zig` built for
//! wasm32): a module with no imports, one memory, and its own data and
//! stack. `read` decodes the parts that the generator needs: the type
//! of each function, the type of each global, the function index of
//! each export, and the first free byte of the memory (the end of the
//! data and of the stack).
//!
//! `link` writes a new module. The sections of the runtime keep their
//! entries, so the runtime functions and globals keep their indices,
//! and the new types, functions, and globals go after them. The memory
//! section is replaced by one memory with the new limits. The export
//! section is replaced by the new exports. The custom sections of the
//! runtime (names and producers) are dropped, and the new custom
//! sections go at the end.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const w = @import("wasm_out.zig");

pub const Error = w.ReadError || error{Unsupported};

pub const Runtime = struct {
    sections: []const w.Section,
    /// The type of each function, by function index.
    func_types: []const w.FuncType,
    type_count: u32,
    /// The value type of each global, by global index.
    global_types: []const w.ValType,
    exports: []const w.Export,
    /// The first byte of the memory after the data and the stack, with
    /// an alignment of 16.
    free: u32,

    pub fn func(rt: *const Runtime, export_name: []const u8) ?u32 {
        for (rt.exports) |e| {
            if (e.kind == .func and std.mem.eql(u8, e.name, export_name)) return e.index;
        }
        return null;
    }
};

fn valType(b: u8) Error!w.ValType {
    return switch (b) {
        0x7f, 0x7e, 0x7d, 0x7c, 0x7b => @fromBackingInt(@intCast(b)),
        else => error.Unsupported,
    };
}

/// Reads a constant expression `i32.const v; end` and returns v.
/// Returns null for another expression and skips it.
fn constExpr(r: *w.Reader) Error!?i64 {
    const op = try r.byte();
    var v: ?i64 = null;
    switch (op) {
        0x41 => v = try sleb(r),
        0x42 => _ = try sleb(r),
        0x44 => _ = try r.take(8),
        0x23 => _ = try r.uleb32(),
        else => return error.Unsupported,
    }
    if (try r.byte() != 0x0b) return error.Unsupported;
    return v;
}

fn sleb(r: *w.Reader) Error!i64 {
    var v: i64 = 0;
    var shift: u7 = 0;
    while (true) {
        const b = try r.byte();
        v |= @as(i64, b & 0x7f) << @intCast(shift);
        shift += 7;
        if (b & 0x80 == 0) {
            if (shift < 64 and b & 0x40 != 0) v |= @as(i64, -1) << @intCast(shift);
            return v;
        }
        if (shift >= 63) return error.BadModule;
    }
}

pub fn read(a: Allocator, bytes: []const u8) Error!Runtime {
    const secs = try w.readSections(a, bytes);
    var types: std.ArrayList(w.FuncType) = .empty;
    var func_types: std.ArrayList(w.FuncType) = .empty;
    var globals: std.ArrayList(w.ValType) = .empty;
    var exports: std.ArrayList(w.Export) = .empty;
    var free: i64 = 0;
    for (secs) |s| {
        var r: w.Reader = .{ .bytes = s.body };
        switch (s.id) {
            0 => continue,
            2, 8 => return error.Unsupported,
            1 => for (0..try r.uleb32()) |_| {
                if (try r.byte() != 0x60) return error.Unsupported;
                var parts: [2][]w.ValType = undefined;
                for (&parts) |*p| {
                    p.* = try a.alloc(w.ValType, try r.uleb32());
                    for (p.*) |*v| v.* = try valType(try r.byte());
                }
                try types.append(a, .{ .params = parts[0], .results = parts[1] });
            },
            3 => for (0..try r.uleb32()) |_| {
                const t = try r.uleb32();
                if (t >= types.items.len) return error.BadModule;
                try func_types.append(a, types.items[t]);
            },
            5 => if (try r.uleb32() != 1) return error.Unsupported,
            6 => for (0..try r.uleb32()) |_| {
                const t = try valType(try r.byte());
                _ = try r.byte();
                const init = try constExpr(&r);
                try globals.append(a, t);
                // The stack pointer starts at the top of the stack.
                if (init) |v| free = @max(free, v);
            },
            7 => for (0..try r.uleb32()) |_| {
                const n = try r.str();
                const kind = try r.byte();
                if (kind > 3) return error.BadModule;
                try exports.append(a, .{ .name = n, .kind = @fromBackingInt(@intCast(kind)), .index = try r.uleb32() });
            },
            11 => for (0..try r.uleb32()) |_| {
                const flags = try r.uleb32();
                var offset: i64 = 0;
                switch (flags) {
                    0 => offset = (try constExpr(&r)) orelse return error.Unsupported,
                    1 => {},
                    2 => {
                        _ = try r.uleb32();
                        offset = (try constExpr(&r)) orelse return error.Unsupported;
                    },
                    else => return error.BadModule,
                }
                const data = try r.str();
                if (flags != 1) free = @max(free, offset + @as(i64, @intCast(data.len)));
            },
            else => {},
        }
    }
    if (free < 0 or free > std.math.maxInt(u32) - 16) return error.BadModule;
    return .{
        .sections = secs,
        .func_types = func_types.items,
        .type_count = @intCast(types.items.len),
        .global_types = globals.items,
        .exports = exports.items,
        .free = @intCast(std.mem.alignForward(i64, free, 16)),
    };
}

pub const Func = struct { t: w.FuncType, code: []const u8 };

pub const Data = struct { offset: u32, bytes: []const u8 };

pub const Extra = struct {
    funcs: []const Func = &.{},
    globals: []const w.Global = &.{},
    exports: []const w.Export = &.{},
    memory: w.Limits,
    /// Active data segments of memory 0.
    datas: []const Data = &.{},
    customs: []const w.Custom = &.{},
};

/// The body of a vector section of the runtime with new entries after
/// the old ones.
fn extend(out: *std.ArrayList(u8), a: Allocator, old: ?[]const u8, count: usize, new: []const u8) Error!void {
    var old_count: u32 = 0;
    var rest: []const u8 = &.{};
    if (old) |o| {
        var r: w.Reader = .{ .bytes = o };
        old_count = try r.uleb32();
        rest = o[r.pos..];
    }
    try w.uleb(out, a, old_count + count);
    try out.appendSlice(a, rest);
    try out.appendSlice(a, new);
}

fn find(rt: *const Runtime, id: u8) ?[]const u8 {
    for (rt.sections) |s| if (s.id == id) return s.body;
    return null;
}

/// The index of the first new function, global, or type.
pub fn nextFunc(rt: *const Runtime) u32 {
    return @intCast(rt.func_types.len);
}

pub fn nextGlobal(rt: *const Runtime) u32 {
    return @intCast(rt.global_types.len);
}

pub fn link(a: Allocator, rt: *const Runtime, x: Extra) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, w.magic);
    var body: std.ArrayList(u8) = .empty;
    var items: std.ArrayList(u8) = .empty;
    // The order of the specification: type, function, table, memory,
    // global, export, element, data count, code, data.
    for ([_]u8{ 1, 3, 4, 5, 6, 7, 9, 12, 10, 11 }) |id| {
        body.clearRetainingCapacity();
        items.clearRetainingCapacity();
        switch (id) {
            1 => {
                for (x.funcs) |f| try f.t.encode(&items, a);
                try extend(&body, a, find(rt, 1), x.funcs.len, items.items);
            },
            3 => {
                for (x.funcs, 0..) |_, i| try w.uleb(&items, a, rt.type_count + i);
                try extend(&body, a, find(rt, 3), x.funcs.len, items.items);
            },
            5 => {
                try w.uleb(&body, a, 1);
                try x.memory.encode(&body, a);
            },
            6 => {
                for (x.globals) |g| try g.encode(&items, a);
                try extend(&body, a, find(rt, 6), x.globals.len, items.items);
            },
            7 => {
                try w.uleb(&body, a, x.exports.len);
                for (x.exports) |e| try e.encode(&body, a);
            },
            11 => {
                for (x.datas) |d| {
                    try items.append(a, 0);
                    try items.append(a, 0x41);
                    try w.sleb(&items, a, @as(i32, @bitCast(d.offset)));
                    try items.append(a, 0x0b);
                    try w.uleb(&items, a, d.bytes.len);
                    try items.appendSlice(a, d.bytes);
                }
                if (find(rt, 11) == null and x.datas.len == 0) continue;
                try extend(&body, a, find(rt, 11), x.datas.len, items.items);
            },
            12 => {
                const s = find(rt, 12) orelse continue;
                var r: w.Reader = .{ .bytes = s };
                try w.uleb(&body, a, (try r.uleb32()) + x.datas.len);
            },
            10 => {
                for (x.funcs) |f| try items.appendSlice(a, f.code);
                try extend(&body, a, find(rt, 10), x.funcs.len, items.items);
            },
            else => {
                const s = find(rt, id) orelse continue;
                try body.appendSlice(a, s);
            },
        }
        try w.section(&out, a, id, body.items);
    }
    for (x.customs) |c| {
        body.clearRetainingCapacity();
        try w.name(&body, a, c.name);
        try body.appendSlice(a, c.data);
        try w.section(&out, a, 0, body.items);
    }
    return out.toOwnedSlice(a);
}

/// The types of all functions after `link`, for `wasm_out.Body`.
pub fn allFuncTypes(a: Allocator, rt: *const Runtime, new: []const w.FuncType) Allocator.Error![]w.FuncType {
    const all = try a.alloc(w.FuncType, rt.func_types.len + new.len);
    @memcpy(all[0..rt.func_types.len], rt.func_types);
    @memcpy(all[rt.func_types.len..], new);
    return all;
}

// ---- Tests ----

pub const runtime_simd = @embedFile("point_rt.wasm");
pub const runtime_scalar = @embedFile("point_rt_scalar.wasm");

test "a function appended to the runtime calls the noise of the runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ runtime_simd, runtime_scalar }, [_][]const u8{ "linked", "linked-scalar" }) |bytes, base| {
        const rt = try read(a, bytes);
        try std.testing.expect(rt.free > 0);
        const noise_fn = rt.func("rt_noise3").?;
        // f(x, y, z) -> f64: noise3 with the seed 7.
        const t: w.FuncType = .{ .params = &.{ .f64, .f64, .f64 }, .results = &.{.f64} };
        const funcs = try allFuncTypes(a, &rt, &.{t});
        var b = try w.Body.init(a, t, funcs, rt.global_types);
        try b.i32Const(7);
        try b.localGet(0);
        try b.localGet(1);
        try b.localGet(2);
        try b.call(noise_fn);
        const code = try b.finish();
        const g = nextGlobal(&rt);
        const out = try link(a, &rt, .{
            .funcs = &.{.{ .t = t, .code = code }},
            .globals = &.{.{ .t = .i32, .init = rt.free }},
            .exports = &.{
                .{ .name = "memory", .kind = .memory, .index = 0 },
                .{ .name = "f", .kind = .func, .index = nextFunc(&rt) },
                .{ .name = "free", .kind = .global, .index = g },
            },
            .memory = .{ .min = 4, .max = 4 },
            .customs = &.{.{ .name = "ztcl.test", .data = "{}" }},
        });
        const again = try read(a, out);
        try std.testing.expectEqual(rt.func_types.len + 1, again.func_types.len);
        try std.testing.expectEqual(@as(usize, 3), again.exports.len);
        try writeTestModule(base, out);
    }
}

fn writeTestModule(base: []const u8, bytes: []const u8) !void {
    const io = std.testing.io;
    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "zig-out/wasm-out") catch return;
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "zig-out/wasm-out/{s}.wasm", .{base});
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

// ---- The append form ----
//
// `ztcl compile --wasm` (src/wasm_aot/aot.zig) keeps each section of
// the runtime and its exports, and appends to them: new types, new
// functions in the table after its entries, pages at the end of the
// memory, and data segments after the segments of the runtime. A later
// data segment writes over an earlier one, so a new segment can set an
// exported variable of the runtime.

/// The facts that `append` changes.
pub const Shape = struct {
    /// The count of functions, with the imports: the index of the next one.
    funcs: u32,
    types: u32,
    table: w.Limits,
    memory: w.Limits,

    /// The address of the first page that `append` adds.
    pub fn freeAddress(s: Shape) u32 {
        return s.memory.min * page;
    }
};

pub const page: u32 = 65536;

fn findIn(secs: []const w.Section, id: u8) ?[]const u8 {
    for (secs) |s| if (s.id == id) return s.body;
    return null;
}

fn limits(r: *w.Reader) Error!w.Limits {
    const flag = try r.byte();
    if (flag > 1) return error.Unsupported;
    const min = try r.uleb32();
    return .{ .min = min, .max = if (flag == 1) try r.uleb32() else null };
}

pub fn shape(rt: *const Runtime) Error!Shape {
    const tb = findIn(rt.sections, 4) orelse return error.Unsupported;
    var tr: w.Reader = .{ .bytes = tb };
    if (try tr.uleb32() != 1 or try tr.byte() != 0x70) return error.Unsupported;
    const mb = findIn(rt.sections, 5) orelse return error.Unsupported;
    var mr: w.Reader = .{ .bytes = mb };
    if (try mr.uleb32() != 1) return error.Unsupported;
    return .{ .funcs = nextFunc(rt), .types = rt.type_count, .table = try limits(&tr), .memory = try limits(&mr) };
}

/// The address that the exported data variable `name` names: the value
/// of its immutable global.
pub fn dataAddress(rt: *const Runtime, name: []const u8) Error!?u32 {
    const g = for (rt.exports) |e| {
        if (e.kind == .global and std.mem.eql(u8, e.name, name)) break e.index;
    } else return null;
    const body = findIn(rt.sections, 6) orelse return error.BadModule;
    var r: w.Reader = .{ .bytes = body };
    const n = try r.uleb32();
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        _ = try r.byte();
        const mutable = try r.byte();
        const v = try constExpr(&r);
        if (k != g) continue;
        if (mutable != 0) return error.Unsupported;
        const x = v orelse return error.Unsupported;
        return std.math.cast(u32, x) orelse error.BadModule;
    }
    return error.BadModule;
}

/// The bytes of the active data segments at `addr`. A later segment
/// writes over an earlier one, as at instantiation.
pub fn readData(rt: *const Runtime, addr: u32, out: []u8) Error!void {
    @memset(out, 0);
    const body = findIn(rt.sections, 11) orelse return error.BadModule;
    var r: w.Reader = .{ .bytes = body };
    var k = try r.uleb32();
    var found: usize = 0;
    while (k > 0) : (k -= 1) {
        const flag = try r.uleb32();
        const base: ?i64 = switch (flag) {
            0 => (try constExpr(&r)) orelse return error.Unsupported,
            1 => null,
            2 => blk: {
                if (try r.uleb32() != 0) return error.Unsupported;
                break :blk (try constExpr(&r)) orelse return error.Unsupported;
            },
            else => return error.BadModule,
        };
        const data = try r.str();
        const b: u64 = @intCast(base orelse continue);
        const lo = @max(b, addr);
        const hi = @min(b + data.len, @as(u64, addr) + out.len);
        if (hi <= lo) continue;
        @memcpy(out[@intCast(lo - addr)..@intCast(hi - addr)], data[@intCast(lo - b)..@intCast(hi - b)]);
        found += @intCast(hi - lo);
    }
    if (found < out.len) return error.BadModule;
}

/// What `append` adds to a module.
pub const Addition = struct {
    types: []const w.FuncType = &.{},
    /// The type index of each new function.
    funcs: []const u32 = &.{},
    /// The code entry of each new function, from `Body.finish`.
    code: []const []const u8 = &.{},
    /// The new functions that go in the table, after its entries.
    table_funcs: []const u32 = &.{},
    /// Active data segments, after the segments of the module.
    data: []const Data = &.{},
    /// Pages added to the least size of the memory.
    pages: u32 = 0,
};

/// Writes the runtime with `add`. The sections keep their order.
pub fn append(a: Allocator, rt: *const Runtime, add: Addition) Error![]u8 {
    const sh = try shape(rt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, w.magic);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    var new: std.ArrayList(u8) = .empty;
    defer new.deinit(a);
    var have_elem = false;
    var have_data = false;
    for (rt.sections) |s| {
        body.clearRetainingCapacity();
        new.clearRetainingCapacity();
        switch (s.id) {
            1 => {
                for (add.types) |t| try t.encode(&new, a);
                try extend(&body, a, s.body, add.types.len, new.items);
            },
            3 => {
                for (add.funcs) |t| try w.uleb(&new, a, t);
                try extend(&body, a, s.body, add.funcs.len, new.items);
            },
            4 => {
                const grow: u32 = @intCast(add.table_funcs.len);
                try body.appendSlice(a, &.{ 1, 0x70 });
                try (w.Limits{ .min = sh.table.min + grow, .max = if (sh.table.max) |x| x + grow else null }).encode(&body, a);
            },
            5 => {
                try w.uleb(&body, a, 1);
                const min = sh.memory.min + add.pages;
                if (sh.memory.max) |x| if (x < min) return error.Unsupported;
                try (w.Limits{ .min = min, .max = sh.memory.max }).encode(&body, a);
            },
            9 => {
                have_elem = true;
                if (add.table_funcs.len == 0) {
                    try body.appendSlice(a, s.body);
                } else {
                    // Flag 0: an active segment of table 0.
                    try new.appendSlice(a, &.{ 0, 0x41 });
                    try w.sleb(&new, a, @as(i32, @bitCast(sh.table.min)));
                    try new.append(a, 0x0b);
                    try w.uleb(&new, a, add.table_funcs.len);
                    for (add.table_funcs) |f| try w.uleb(&new, a, f);
                    try extend(&body, a, s.body, 1, new.items);
                }
            },
            10 => {
                if (!have_elem and add.table_funcs.len > 0) return error.Unsupported;
                for (add.code) |c| try new.appendSlice(a, c);
                try extend(&body, a, s.body, add.code.len, new.items);
            },
            11 => {
                have_data = true;
                for (add.data) |d| {
                    try new.appendSlice(a, &.{ 0, 0x41 });
                    try w.sleb(&new, a, @as(i32, @bitCast(d.offset)));
                    try new.append(a, 0x0b);
                    try w.uleb(&new, a, d.bytes.len);
                    try new.appendSlice(a, d.bytes);
                }
                try extend(&body, a, s.body, add.data.len, new.items);
            },
            12 => {
                var r: w.Reader = .{ .bytes = s.body };
                try w.uleb(&body, a, try r.uleb32() + add.data.len);
            },
            else => try body.appendSlice(a, s.body),
        }
        try w.section(&out, a, s.id, body.items);
    }
    if (!have_data and add.data.len > 0) return error.Unsupported;
    return out.toOwnedSlice(a);
}

/// A module with one table of 2 entries, a memory of 1 page, one data
/// segment, an exported data global, and one function `f` that returns
/// the i32 at address 16.
fn appendTestModule(a: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, w.magic);
    try w.section(&out, a, 1, &.{ 1, 0x60, 0, 1, 0x7f });
    try w.section(&out, a, 3, &.{ 1, 0 });
    try w.section(&out, a, 4, &.{ 1, 0x70, 1, 2, 2 });
    try w.section(&out, a, 5, &.{ 1, 0, 1 });
    try w.section(&out, a, 6, &.{ 1, 0x7f, 0, 0x41, 16, 0x0b });
    try w.section(&out, a, 7, &.{ 2, 1, 'f', 0, 0, 1, 'v', 3, 0 });
    try w.section(&out, a, 9, &.{ 1, 0, 0x41, 1, 0x0b, 1, 0 });
    try w.section(&out, a, 10, &.{ 1, 7, 0, 0x41, 16, 0x28, 2, 0, 0x0b });
    try w.section(&out, a, 11, &.{ 1, 0, 0x41, 16, 0x0b, 4, 7, 0, 0, 0 });
    return out.toOwnedSlice(a);
}

test "append: functions, a table segment, pages, and data" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rt = try read(a, try appendTestModule(a));
    const sh = try shape(&rt);
    try std.testing.expectEqual(@as(u32, 1), sh.funcs);
    try std.testing.expectEqual(@as(u32, 2), sh.table.min);
    try std.testing.expectEqual(@as(?u32, 16), try dataAddress(&rt, "v"));
    var word: [4]u8 = undefined;
    try readData(&rt, 16, &word);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, &word, .little));
    // A function that returns 42, in the table, a new value at address
    // 16, and a word in the new page.
    var b = try w.Body.init(a, .{ .params = &.{}, .results = &.{.i32} }, &.{}, &.{});
    try b.i32Const(42);
    const out = try append(a, &rt, .{
        .types = &.{.{ .params = &.{}, .results = &.{.i32} }},
        .funcs = &.{1},
        .code = &.{try b.finish()},
        .table_funcs = &.{sh.funcs},
        .data = &.{ .{ .offset = 16, .bytes = &.{ 9, 0, 0, 0 } }, .{ .offset = sh.freeAddress(), .bytes = "dir" } },
        .pages = 1,
    });
    const rt2 = try read(a, out);
    const sh2 = try shape(&rt2);
    try std.testing.expectEqual(@as(u32, 2), sh2.funcs);
    try std.testing.expectEqual(@as(u32, 2), sh2.types);
    try std.testing.expectEqual(w.Limits{ .min = 3, .max = 3 }, sh2.table);
    try std.testing.expectEqual(@as(u32, 2), sh2.memory.min);
    try readData(&rt2, 16, &word);
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, &word, .little));
    var dir: [3]u8 = undefined;
    try readData(&rt2, page, &dir);
    try std.testing.expectEqualStrings("dir", &dir);
}

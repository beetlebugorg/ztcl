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
        0x7f, 0x7e, 0x7d, 0x7c, 0x7b => @enumFromInt(b),
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
                try exports.append(a, .{ .name = n, .kind = @enumFromInt(kind), .index = try r.uleb32() });
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

//! The compiler of `ztcl compile --wasm`: proc sources to a module.
//!
//! A source is the argument list and the body of a proc. The compiler
//! defines each one as a proc in a scratch interpreter, so the
//! parameters and the bytecode are those of the runtime. It runs the
//! verifier of the JIT, makes one function for each distinct bytecode
//! with `gen.zig`, and links the functions and a directory into the
//! runtime module (see `rt.zig` for the directory).
//!
//! `scan` finds the sources in a script: each `proc`, `method`,
//! `constructor`, and `destructor` with literal words, in the script
//! and in each literal word that parses as a script. A body that the
//! scan misses runs in the interpreter.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("../interp.zig");
const vm = @import("../vm.zig");
const value = @import("../value.zig");
const verify = @import("../jit/verify.zig");
const helpers = @import("../jit/helpers.zig");
const gen = @import("gen.zig");
const rt = @import("rt.zig");
const wasm = @import("wasm.zig");
const Layout = @import("../jit/layout.zig").Layout;

const Allocator = std.mem.Allocator;
const Interp = interp.Interp;
const Value = value.Value;

pub const Source = struct { args: []const u8, body: []const u8 };

pub const Error = gen.Error || wasm.Error || interp.Error || error{ NoDirectoryVariable, BadRecord };

/// The results of `compile`.
pub const Result = struct {
    bytes: []u8,
    /// The sources that compiled to a function.
    compiled: usize,
    /// The sources that did not define a proc, or that the verifier
    /// refused.
    skipped: usize,
    /// The functions in the module: sources with equal bytecode share one.
    functions: usize,
};

/// The records of the record mode of `rt.zig`.
pub fn readRecord(a: Allocator, bytes: []const u8, list: *std.ArrayList(Source)) Error!void {
    var at: usize = 0;
    while (at < bytes.len) {
        var two: [2][]const u8 = undefined;
        for (&two) |*s| {
            if (bytes.len - at < 4) return error.BadRecord;
            const n = std.mem.readInt(u32, bytes[at..][0..4], .little);
            at += 4;
            if (bytes.len - at < n) return error.BadRecord;
            s.* = bytes[at .. at + n];
            at += n;
        }
        try list.append(a, .{ .args = two[0], .body = two[1] });
    }
}

fn litText(w: *const interp.Word) ?[]const u8 {
    if (w.expand) return null;
    return switch (w.kind) {
        .lit => |v| if (v == .str) v.str else null,
        else => null,
    };
}

/// Adds the sources of `text` to `list`. `depth` bounds the nesting.
pub fn scan(a: Allocator, it: *Interp, text: []const u8, list: *std.ArrayList(Source), depth: u32) Allocator.Error!void {
    if (depth > 64) return;
    const s = it.compile(text) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return;
    };
    for (s.cmds) |*c| {
        const w = c.words;
        if (w.len == 0) continue;
        const name = litText(&w[0]) orelse "";
        const cmd = std.mem.trimStart(u8, name, ":");
        const src: ?Source = if (std.mem.eql(u8, cmd, "proc") and w.len == 4)
            pair(&w[2], &w[3])
        else if (std.mem.eql(u8, cmd, "method") and w.len == 4)
            pair(&w[2], &w[3])
        else if (std.mem.eql(u8, cmd, "constructor") and w.len == 3)
            pair(&w[1], &w[2])
        else if (std.mem.eql(u8, cmd, "destructor") and w.len == 2)
            if (litText(&w[1])) |b| .{ .args = "", .body = b } else null
        else
            null;
        if (src) |x| try list.append(a, .{ .args = try a.dupe(u8, x.args), .body = try a.dupe(u8, x.body) });
        for (w[1..]) |*word| {
            const t = litText(word) orelse continue;
            if (std.mem.indexOfAny(u8, t, " \t\n;") == null) continue;
            try scan(a, it, t, list, depth + 1);
        }
    }
}

fn pair(args: *const interp.Word, body: *const interp.Word) ?Source {
    return .{ .args = litText(args) orelse return null, .body = litText(body) orelse return null };
}

const Fn = struct {
    hash: u64,
    named: bool,
    ins: []const vm.Ins,
    depth: []u16,
    entry: []u8,
};

/// The bytecode of the proc of `src`, or null when it does not define a
/// proc.
fn codeOf(it: *Interp, src: Source) Error!?*vm.Code {
    const words = [_]Value{ .{ .str = "proc" }, .{ .str = "::__ztcl_aot" }, .{ .str = src.args }, .{ .str = src.body } };
    const list = try value.newList(it.alloc(), &words);
    _ = it.eval(try it.str(list)) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
    const c = it.findCommand("::__ztcl_aot") orelse return null;
    const p = switch (c.impl) {
        .proc => |p| p,
        else => return null,
    };
    if (p.script == null) p.script = it.compile(try it.str(p.body)) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
    return vm.compileProc(it, p, p.script.?) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
}

/// Compiles `sources` into a copy of the runtime module `runtime`.
/// `it` is a scratch interpreter.
pub const Options = struct {
    /// False: each instruction calls its helper.
    inline_paths: bool = true,
};

pub fn compile(a: Allocator, it: *Interp, runtime: []const u8, sources: []const Source, opts: Options) Error!Result {
    var m = try wasm.Module.parse(a, runtime);
    defer m.deinit(a);
    var hs: gen.Helpers = .{};
    inline for (gen.exported) |h| {
        if (try m.exportOf(gen.exportName(h, false), 0)) |f| hs.proc[@intFromEnum(h)] = f;
        if (try m.exportOf(gen.exportName(h, true), 0)) |f| hs.named[@intFromEnum(h)] = f;
    }
    const dir_var = try m.dataAddress("ztcl_aot_dir") orelse return error.NoDirectoryVariable;
    // The layout of the runtime. A module with no layout gets the helper
    // form only.
    var lay: Layout = undefined;
    var inline_paths = false;
    if (try m.dataAddress("ztcl_aot_layout_data")) |at| {
        const fields = std.meta.fields(Layout);
        var words: [fields.len * 4]u8 = undefined;
        try m.readData(at, &words);
        inline for (fields, 0..) |f, k| @field(lay, f.name) = @intCast(std.mem.readInt(u32, words[k * 4 ..][0..4], .little));
        inline_paths = opts.inline_paths;
    }

    var fns: std.ArrayList(Fn) = .empty;
    defer {
        for (fns.items) |f| {
            a.free(f.depth);
            a.free(f.entry);
            a.free(f.ins);
        }
        fns.deinit(a);
    }
    var res: Result = .{ .bytes = &.{}, .compiled = 0, .skipped = 0, .functions = 0 };
    for (sources) |src| {
        const code = try codeOf(it, src) orelse {
            res.skipped += 1;
            continue;
        };
        const hash = gen.hashCode(code);
        const same = for (fns.items) |f| {
            if (f.hash == hash and f.named == code.named and sameIns(f.ins, code.ins)) break true;
        } else false;
        if (same) {
            res.compiled += 1;
            continue;
        }
        var info = try verify.verify(a, code) orelse {
            res.skipped += 1;
            continue;
        };
        defer info.deinit(a);
        const entry = try gen.function(a, code, &info, if (code.named) &hs.named else &hs.proc, &lay, inline_paths);
        errdefer a.free(entry);
        const depth = try a.alloc(u16, code.ins.len);
        errdefer a.free(depth);
        for (depth, 0..) |*d, k| d.* = gen.depthOf(&info, k);
        const ins = try a.dupe(vm.Ins, code.ins);
        errdefer a.free(ins);
        try fns.append(a, .{ .hash = hash, .named = code.named, .ins = ins, .depth = depth, .entry = entry });
        res.compiled += 1;
    }
    std.mem.sort(Fn, fns.items, {}, struct {
        fn lt(_: void, x: Fn, y: Fn) bool {
            return x.hash < y.hash;
        }
    }.lt);
    res.functions = fns.items.len;

    const ml = try m.layout();
    const base = ml.freeAddress();
    // The directory: the header, the records, then the bytecode and the
    // depths of each function.
    var dir: std.ArrayList(u8) = .empty;
    defer dir.deinit(a);
    const head = 12 + fns.items.len * rt.record_words * 4;
    try dir.appendNTimes(a, 0, head);
    putWord(dir.items, 0, rt.magic);
    putWord(dir.items, 4, rt.version);
    putWord(dir.items, 8, @intCast(fns.items.len));
    for (fns.items, 0..) |f, k| {
        const r = 12 + k * rt.record_words * 4;
        const ins_at = base + @as(u32, @intCast(dir.items.len));
        for (f.ins) |*i| try dir.appendSlice(a, &gen.insBytes(i));
        const depth_at = base + @as(u32, @intCast(dir.items.len));
        for (f.depth) |d| {
            var two: [2]u8 = undefined;
            std.mem.writeInt(u16, &two, d, .little);
            try dir.appendSlice(a, &two);
        }
        while (dir.items.len % 4 != 0) try dir.append(a, 0);
        putWord(dir.items, r, @truncate(f.hash));
        putWord(dir.items, r + 4, @truncate(f.hash >> 32));
        putWord(dir.items, r + 8, ins_at);
        putWord(dir.items, r + 12, @intCast(f.ins.len));
        putWord(dir.items, r + 16, depth_at);
        putWord(dir.items, r + 20, ml.table.min + @as(u32, @intCast(k)));
        putWord(dir.items, r + 24, @intFromBool(f.named));
    }
    const fn_type = try wasm.funcType(a, &.{.i32}, &.{.i32});
    defer a.free(fn_type);
    const types = try a.alloc(u32, fns.items.len);
    defer a.free(types);
    @memset(types, ml.types);
    const code = try a.alloc([]const u8, fns.items.len);
    defer a.free(code);
    const table = try a.alloc(u32, fns.items.len);
    defer a.free(table);
    for (fns.items, 0..) |f, k| {
        code[k] = f.entry;
        table[k] = ml.funcs + @as(u32, @intCast(k));
    }
    var addr: [4]u8 = undefined;
    std.mem.writeInt(u32, &addr, base, .little);
    res.bytes = try wasm.link(a, &m, .{
        .types = &.{fn_type},
        .funcs = types,
        .code = code,
        .table_funcs = table,
        .data = &.{ .{ .addr = base, .bytes = dir.items }, .{ .addr = dir_var, .bytes = &addr } },
        .pages = @intCast((dir.items.len + wasm.page - 1) / wasm.page),
    });
    return res;
}

fn putWord(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

fn sameIns(x: []const vm.Ins, y: []const vm.Ins) bool {
    if (x.len != y.len) return false;
    for (x, y) |*p, *q| if (!std.mem.eql(u8, &gen.insBytes(p), &gen.insBytes(q))) return false;
    return true;
}

//! The runner of the WebAssembly spec tests for the engine.
//!
//! `wasm-tools json-from-wast` turns each `.wast` file of the spec tests
//! into a JSON file of commands and the `.wasm` files of its modules.
//! This program reads one such JSON file for each argument, runs each
//! command against the engine, and prints the count of passed and
//! failed commands. A text module of `assert_malformed` is skipped: the
//! engine reads only the binary format. The module `spectest` has the
//! imports that the tests expect.
//!
//! Usage: wasm-spec FILE.json...
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const mod = @import("module.zig");
const exec = @import("exec.zig");

const Runner = struct {
    a: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    store: *exec.Store,
    modules: std.ArrayList(*mod.Module) = .empty,
    named: std.StringHashMapUnmanaged(*exec.Instance) = .empty,
    registered: std.StringHashMapUnmanaged(*exec.Instance) = .empty,
    current: ?*exec.Instance = null,
    spectest: std.StringHashMapUnmanaged(exec.Extern) = .empty,
    pass: usize = 0,
    fail: usize = 0,
    skip: usize = 0,
    verbose: bool = false,
    file: []const u8 = "",
};

fn noop(_: ?*anyopaque, _: *exec.Store, _: []const u64, _: []u64) exec.Error!void {}

fn setupSpectest(r: *Runner) !void {
    const s = r.store;
    const a = r.a;
    const V = mod.ValType;
    const sigs = [_]struct { []const u8, []const V }{
        .{ "print", &.{} },
        .{ "print_i32", &.{.i32} },
        .{ "print_i64", &.{.i64} },
        .{ "print_f32", &.{.f32} },
        .{ "print_f64", &.{.f64} },
        .{ "print_i32_f32", &.{ .i32, .f32 } },
        .{ "print_f64_f64", &.{ .f64, .f64 } },
    };
    for (sigs) |x| {
        const addr = try s.addHost(.{ .params = x[1], .results = &.{} }, .{ .ctx = null, .call = noop });
        try r.spectest.put(a, x[0], .{ .func = addr });
    }
    const g = struct {
        fn mk(al: std.mem.Allocator, t: V, v: u64) !*exec.Global {
            const p = try al.create(exec.Global);
            p.* = .{ .type = .{ .val = t, .mutable = false }, .val = v };
            return p;
        }
    };
    try r.spectest.put(a, "global_i32", .{ .global = try g.mk(a, .i32, 666) });
    try r.spectest.put(a, "global_i64", .{ .global = try g.mk(a, .i64, 666) });
    try r.spectest.put(a, "global_f32", .{ .global = try g.mk(a, .f32, @as(u32, @bitCast(@as(f32, 666.6)))) });
    try r.spectest.put(a, "global_f64", .{ .global = try g.mk(a, .f64, @bitCast(@as(f64, 666.6))) });
    const t = try a.create(exec.Table);
    t.* = .{ .elem = .funcref, .max = 20 };
    try t.refs.appendNTimes(s.gpa, 0, 10);
    try r.spectest.put(a, "table", .{ .table = t });
    const m = try a.create(exec.Memory);
    m.* = .{ .max = 2, .bytes = try s.gpa.alloc(u8, exec.page) };
    @memset(m.bytes, 0);
    try r.spectest.put(a, "memory", .{ .mem = m });
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn loadModule(r: *Runner, file: []const u8, diag: *mod.Diag) !*mod.Module {
    const bytes = try r.dir.readFileAlloc(r.io, file, r.a, .limited(64 << 20));
    defer r.a.free(bytes);
    const m = try mod.decode(r.a, bytes, diag);
    try r.modules.append(r.a, m);
    return m;
}

fn resolveImports(r: *Runner, m: *const mod.Module) ![]exec.Extern {
    const out = try r.a.alloc(exec.Extern, m.imports.len);
    for (m.imports, out) |imp, *e| {
        if (std.mem.eql(u8, imp.module, "spectest")) {
            e.* = r.spectest.get(imp.name) orelse return error.LinkFailed;
            continue;
        }
        const inst = r.registered.get(imp.module) orelse return error.LinkFailed;
        e.* = inst.exportOf(imp.name) orelse return error.LinkFailed;
    }
    return out;
}

fn instantiate(r: *Runner, m: *const mod.Module) !*exec.Instance {
    const imports = try resolveImports(r, m);
    defer r.a.free(imports);
    return r.store.instantiate(m, imports);
}

fn parseValue(v: std.json.Value) !u64 {
    const t = str(v, "type").?;
    const text = str(v, "value") orelse return error.Unsupported;
    if (std.mem.eql(u8, text, "null")) return 0;
    if (std.mem.eql(u8, t, "externref")) return (try std.fmt.parseInt(u64, text, 10)) + 1;
    if (std.mem.eql(u8, t, "funcref")) return error.Unsupported;
    const n = try std.fmt.parseInt(i128, text, 10);
    const u: u64 = @truncate(@as(u128, @bitCast(n)));
    if (std.mem.eql(u8, t, "i32") or std.mem.eql(u8, t, "f32")) return u & 0xffff_ffff;
    return u;
}

fn matches(v: std.json.Value, got: u64) bool {
    const t = str(v, "type").?;
    const text = str(v, "value") orelse return true;
    if (std.mem.startsWith(u8, text, "nan:")) {
        const canonical = std.mem.eql(u8, text, "nan:canonical");
        if (std.mem.eql(u8, t, "f32")) {
            const b: u32 = @truncate(got);
            if (b & 0x7f80_0000 != 0x7f80_0000 or b & 0x007f_ffff == 0) return false;
            return if (canonical) b & 0x7fff_ffff == 0x7fc0_0000 else b & 0x0040_0000 != 0;
        }
        if (got & 0x7ff0_0000_0000_0000 != 0x7ff0_0000_0000_0000 or got & 0x000f_ffff_ffff_ffff == 0) return false;
        return if (canonical) got & 0x7fff_ffff_ffff_ffff == 0x7ff8_0000_0000_0000 else got & 0x0008_0000_0000_0000 != 0;
    }
    if (std.mem.eql(u8, t, "funcref") and !std.mem.eql(u8, text, "null")) return got != 0;
    const want = parseValue(v) catch return false;
    return want == got;
}

fn instanceOf(r: *Runner, action: std.json.Value) ?*exec.Instance {
    if (str(action, "module")) |name| return r.named.get(name);
    return r.current;
}

/// Runs an action. Gives the results, or an error.
fn doAction(r: *Runner, action: std.json.Value, results: *std.ArrayList(u64)) !void {
    const inst = instanceOf(r, action) orelse return error.SkippedModule;
    const field = str(action, "field").?;
    const kind = str(action, "type").?;
    const ext = inst.exportOf(field) orelse return error.NoExport;
    results.clearRetainingCapacity();
    if (std.mem.eql(u8, kind, "get")) {
        try results.append(r.a, ext.global.val);
        return;
    }
    const addr = ext.func;
    const ft = r.store.funcs.items[addr].type;
    const args_json = action.object.get("args").?.array.items;
    const args = try r.a.alloc(u64, args_json.len);
    defer r.a.free(args);
    for (args_json, args) |x, *y| y.* = try parseValue(x);
    try results.resize(r.a, ft.results.len);
    r.store.own_units = 100_000_000;
    try r.store.invoke(addr, args, results.items);
}

fn note(r: *Runner, ok: bool, line: i64, what: []const u8, detail: []const u8) void {
    if (std.mem.eql(u8, detail, "SkippedModule")) {
        r.skip += 1;
    } else if (ok) {
        r.pass += 1;
    } else {
        r.fail += 1;
        if (r.verbose) std.debug.print("FAIL {s}:{d} {s} {s}\n", .{ r.file, line, what, detail });
    }
}

fn runFile(r: *Runner, text: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, r.a, text, .{});
    defer parsed.deinit();
    var results: std.ArrayList(u64) = .empty;
    defer results.deinit(r.a);
    for (parsed.value.object.get("commands").?.array.items) |c| {
        const kind = str(c, "type").?;
        const line = c.object.get("line").?.integer;
        var diag: mod.Diag = .{};
        if (std.mem.eql(u8, kind, "module")) {
            r.current = null;
            if (std.mem.eql(u8, str(c, "module_type") orelse "binary", "text")) {
                r.skip += 1;
                continue;
            }
            const m = loadModule(r, str(c, "filename").?, &diag) catch |e| {
                note(r, false, line, "module", if (e == error.Malformed or e == error.Invalid) diag.msg else @errorName(e));
                continue;
            };
            const inst = instantiate(r, m) catch |e| {
                note(r, false, line, "instantiate", if (e == error.LinkFailed) r.store.link_msg else @errorName(e));
                continue;
            };
            r.current = inst;
            if (str(c, "name")) |n| try r.named.put(r.a, n, inst);
            r.pass += 1;
        } else if (std.mem.eql(u8, kind, "register")) {
            const inst = if (str(c, "name")) |n| r.named.get(n) else r.current;
            if (inst) |i| try r.registered.put(r.a, str(c, "as").?, i);
        } else if (std.mem.eql(u8, kind, "action")) {
            doAction(r, c.object.get("action").?, &results) catch |e| {
                note(r, false, line, "action", @errorName(e));
                continue;
            };
            r.pass += 1;
        } else if (std.mem.eql(u8, kind, "assert_return")) {
            doAction(r, c.object.get("action").?, &results) catch |e| {
                note(r, false, line, "assert_return", @errorName(e));
                continue;
            };
            const exp = c.object.get("expected").?.array.items;
            var ok = exp.len == results.items.len;
            if (ok) for (exp, results.items) |x, y| {
                if (!matches(x, y)) ok = false;
            };
            var buf: [64]u8 = undefined;
            note(r, ok, line, "assert_return", if (results.items.len > 0) std.fmt.bufPrint(&buf, "got {x}", .{results.items[0]}) catch "" else "");
        } else if (std.mem.eql(u8, kind, "assert_trap") or std.mem.eql(u8, kind, "assert_exhaustion")) {
            const want = str(c, "text").?;
            if (doAction(r, c.object.get("action").?, &results)) |_| {
                note(r, false, line, kind, "no trap");
            } else |e| {
                const got = exec.trapText(e);
                note(r, std.mem.startsWith(u8, want, got) or std.mem.startsWith(u8, got, want), line, kind, got);
            }
        } else if (std.mem.eql(u8, kind, "assert_invalid") or std.mem.eql(u8, kind, "assert_malformed")) {
            if (!std.mem.eql(u8, str(c, "module_type") orelse "binary", "binary")) {
                r.skip += 1;
                continue;
            }
            const want: anyerror = if (kind[7] == 'i') error.Invalid else error.Malformed;
            if (loadModule(r, str(c, "filename").?, &diag)) |_| {
                note(r, false, line, kind, str(c, "text").?);
            } else |e| {
                note(r, e == want, line, kind, diag.msg);
            }
        } else if (std.mem.eql(u8, kind, "assert_unlinkable") or std.mem.eql(u8, kind, "assert_uninstantiable")) {
            const m = loadModule(r, str(c, "filename").?, &diag) catch |e| {
                note(r, false, line, kind, @errorName(e));
                continue;
            };
            if (instantiate(r, m)) |_| {
                note(r, false, line, kind, "instantiated");
            } else |e| {
                const link = e == error.LinkFailed;
                note(r, link == (kind[7] == 'u' and kind[8] == 'n' and kind[9] == 'l'), line, kind, @errorName(e));
            }
        } else {
            r.skip += 1;
        }
    }
}

pub fn main(init: std.process.Init) !u8 {
    const a = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var total_pass: usize = 0;
    var total_fail: usize = 0;
    var verbose = false;
    for (args[1..]) |path| {
        if (std.mem.eql(u8, path, "-v")) {
            verbose = true;
            continue;
        }
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        const dir_path = std.fs.path.dirname(path) orelse ".";
        var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);
        const text = try Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(256 << 20));
        var store = exec.Store.init(a);
        store.fixUnits();
        defer store.deinit();
        var r: Runner = .{ .a = aa, .io = io, .dir = dir, .store = &store, .verbose = verbose, .file = std.fs.path.basename(path) };
        try setupSpectest(&r);
        runFile(&r, text) catch |e| std.debug.print("{s}: stopped: {s}\n", .{ path, @errorName(e) });
        for (r.modules.items) |m| m.deinit();
        if (r.spectest.get("memory")) |m| a.free(m.mem.bytes);
        if (r.spectest.get("table")) |t| t.table.refs.deinit(a);
        std.debug.print("{s}: {d} pass, {d} fail, {d} skip\n", .{ r.file, r.pass, r.fail, r.skip });
        total_pass += r.pass;
        total_fail += r.fail;
    }
    std.debug.print("total: {d} pass, {d} fail\n", .{ total_pass, total_fail });
    return if (total_fail == 0) 0 else 1;
}

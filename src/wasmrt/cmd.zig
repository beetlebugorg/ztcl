//! The command `ztcl::wasm`: modules of WebAssembly in a Tcl script.
//!
//! `load` and `new` decode and validate a module (`module.zig`), and
//! give a handle `wasmmodN`. `instantiate` links the imports and gives an
//! instance handle `wasmN`. An import is a Tcl command prefix, an export
//! of another instance (`-link`), or a function of WASI preview 1
//! (`-wasi`, `wasi.zig`). `call` converts the Tcl values to the types of
//! the function, runs the interpreter of `exec.zig`, and converts the
//! results back. A host function calls its command prefix with the
//! arguments as Tcl values, so wasm code can call Tcl code, and that
//! code can call wasm again.
//!
//! Each interpreter has one store. Its memory comes from the counting
//! allocator, so the bytes of the modules, the linear memories, and the
//! value stack count toward the memory limit, and `memory.grow` gives -1
//! above it. The interpreter of wasm uses the compute units of the
//! interpreter: one for each call and each pass of a loop.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("../interp.zig");
const Interp = interp.Interp;
const Error = interp.Error;
const value = @import("../value.zig");
const Value = value.Value;
const mods = @import("../modules.zig");
const more = @import("../more.zig");
const fsroot = @import("../fsroot.zig");
const sys = @import("../sys.zig");
const mod = @import("module.zig");
const exec = @import("exec.zig");
const wasi = @import("wasi.zig");
const cext = @import("cext.zig");

pub const modules_list = [_]mods.Module{.{
    .name = "ztcl::wasm",
    .version = "0.1",
    .install = install,
}};

pub const modules: []const mods.Module = &modules_list;

fn install(it: *Interp) Error!void {
    try it.register("ztcl::wasm", cmd);
}

const TclHost = struct {
    st: *State,
    it: *Interp,
    /// The text of the command prefix, in the memory of the store, so
    /// a collection of the heap does not free it.
    prefix: []u8,
    type: mod.FuncType,
};

const Rec = struct {
    inst: *exec.Instance,
    inst_set: bool = false,
    wasi: ?*wasi.Wasi = null,
    hosts: std.ArrayList(*TclHost) = .empty,
};

const ModRec = struct {
    m: *mod.Module,
    /// The count of instances of the module, alive or deleted.
    uses: u32 = 0,
    deleted: bool = false,
};

pub const State = struct {
    store: exec.Store,
    modules: std.ArrayList(?*ModRec) = .empty,
    insts: std.ArrayList(?*Rec) = .empty,
    /// The Tcl error of a host function, until the call of the store ends.
    pending: ?Error = null,
    /// The records of deleted instances. Their host functions can still
    /// be in the tables of other instances, so they stay until the end.
    zombies: std.ArrayList(*Rec) = .empty,
    /// The C packages of `ztcl::wasm package`.
    pkgs: std.ArrayList(*cext.Pkg) = .empty,
};

fn fits(ctx: ?*anyopaque, more_bytes: usize) bool {
    const it: *Interp = @ptrCast(@alignCast(ctx.?));
    return it.memUsed() +| more_bytes <= it.mem_limit;
}

fn state(it: *Interp) Error!*State {
    if (it.wasm_state) |p| return @ptrCast(@alignCast(p));
    const gpa = it.heap.backing;
    const s = try gpa.create(State);
    s.* = .{ .store = exec.Store.init(gpa) };
    s.store.units = &it.compute_limit;
    s.store.grow_hook = .{ .ctx = it, .fits = fits };
    it.wasm_state = s;
    return s;
}

/// Frees the store of `it`. `Interp.deinit` calls it.
pub fn closeAll(it: *Interp) void {
    const s: *State = @ptrCast(@alignCast(it.wasm_state orelse return));
    const gpa = it.heap.backing;
    for (s.insts.items) |r| if (r) |x| freeRec(gpa, x);
    s.insts.deinit(gpa);
    for (s.zombies.items) |x| freeRec(gpa, x);
    s.zombies.deinit(gpa);
    for (s.pkgs.items) |p| p.deinit(gpa);
    s.pkgs.deinit(gpa);
    s.store.deinit();
    for (s.modules.items) |r| if (r) |x| {
        x.m.deinit();
        gpa.destroy(x);
    };
    s.modules.deinit(gpa);
    gpa.destroy(s);
    it.wasm_state = null;
}

/// Releases the instance of a record and keeps the record until the end.
fn retire(st: *State, gpa: std.mem.Allocator, r: *Rec) Error!void {
    if (r.wasi) |w| w.closeFds();
    if (r.inst_set) st.store.release(r.inst);
    try st.zombies.append(gpa, r);
}

fn freeRec(gpa: std.mem.Allocator, r: *Rec) void {
    for (r.hosts.items) |h| {
        gpa.free(h.prefix);
        gpa.destroy(h);
    }
    r.hosts.deinit(gpa);
    if (r.wasi) |w| w.deinit();
    gpa.destroy(r);
}

const usage = "ztcl::wasm call|delete|exports|global|imports|info|instantiate|load|memory|new|package|run ?arg ...?";

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn cmd(it: *Interp, argv: []const Value, _: ?*interp.Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs(usage);
    const sub = try it.str(argv[1]);
    if (eql(sub, "load")) return cmdLoad(it, argv);
    if (eql(sub, "new")) return cmdNew(it, argv);
    if (eql(sub, "instantiate")) return cmdInstantiate(it, argv);
    if (eql(sub, "call")) return cmdCall(it, argv);
    if (eql(sub, "memory")) return cmdMemory(it, argv);
    if (eql(sub, "global")) return cmdGlobal(it, argv);
    if (eql(sub, "exports")) return cmdExports(it, argv);
    if (eql(sub, "imports")) return cmdImports(it, argv);
    if (eql(sub, "info")) return cmdInfo(it, argv);
    if (eql(sub, "run")) return cmdRun(it, argv);
    if (eql(sub, "delete")) return cmdDelete(it, argv);
    if (eql(sub, "package")) return cmdPackage(it, argv);
    return it.failCode("TCL LOOKUP INDEX subcommand", "unknown subcommand \"{s}\": must be call, delete, exports, global, imports, info, instantiate, load, memory, new, package, or run", .{sub});
}

// ---- Modules ----

fn hasCap(it: *const Interp, c: interp.Capability) bool {
    return it.capabilities & @backingInt(c) != 0;
}

fn readFile(it: *Interp, path: []const u8) Error![]const u8 {
    if (!hasCap(it, .file)) return it.failCode("ZTCL WASM CAPABILITY file", "ztcl::wasm load needs the capability file", .{});
    const a = it.alloc();
    const rel = (try fsroot.normal(it, path)) orelse return it.failCode("POSIX EACCES {permission denied}", "couldn't read file \"{s}\": permission denied", .{path});
    const fd = switch (try fsroot.openRel(it, rel, .{}, 0)) {
        .fd => |x| x,
        .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(a, "couldn't read file \"{s}\": ", .{path})),
    };
    defer sys.close(fd);
    var data: std.ArrayList(u8) = .empty;
    while (true) {
        try data.ensureUnusedCapacity(a, 65536);
        const got = switch (sys.readFile(fd, data.unusedCapacitySlice())) {
            .n => |x| x,
            .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(a, "couldn't read file \"{s}\": ", .{path})),
        };
        if (got == 0) break;
        data.items.len += got;
        try it.checkMem();
    }
    return data.items;
}

fn addModule(it: *Interp, bytes: []const u8) Error!Value {
    const st = try state(it);
    const gpa = it.heap.backing;
    var diag: mod.Diag = .{};
    const m = mod.decode(gpa, bytes, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => return it.failCode("ZTCL WASM MALFORMED", "malformed module: {s} at byte {d}", .{ diag.msg, diag.offset }),
        error.Invalid => return it.failCode("ZTCL WASM INVALID", "invalid module: {s} at byte {d}", .{ diag.msg, diag.offset }),
    };
    errdefer m.deinit();
    const r = try gpa.create(ModRec);
    r.* = .{ .m = m };
    errdefer gpa.destroy(r);
    try st.modules.append(gpa, r);
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "wasmmod{d}", .{st.modules.items.len - 1}) };
}

fn cmdLoad(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len != 3) return it.wrongArgs("ztcl::wasm load fileName");
    return addModule(it, try readFile(it, try it.str(argv[2])));
}

fn cmdNew(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len != 3) return it.wrongArgs("ztcl::wasm new bytes");
    return addModule(it, try more.toBytes(it, try it.str(argv[2])));
}

fn findModule(it: *Interp, v: Value) Error!*ModRec {
    const name = try it.str(v);
    const st = try state(it);
    if (std.mem.startsWith(u8, name, "wasmmod")) {
        if (std.fmt.parseInt(usize, name[7..], 10)) |i| {
            if (i < st.modules.items.len) if (st.modules.items[i]) |r| if (!r.deleted) return r;
        } else |_| {}
    }
    return it.failCode("ZTCL WASM HANDLE", "can not find wasm module \"{s}\"", .{name});
}

fn findInst(it: *Interp, v: Value) Error!*Rec {
    const name = try it.str(v);
    const st = try state(it);
    if (std.mem.startsWith(u8, name, "wasm") and !std.mem.startsWith(u8, name, "wasmmod")) {
        if (std.fmt.parseInt(usize, name[4..], 10)) |i| {
            if (i < st.insts.items.len) if (st.insts.items[i]) |r| return r;
        } else |_| {}
    }
    return it.failCode("ZTCL WASM HANDLE", "can not find wasm instance \"{s}\"", .{name});
}

// ---- Values ----

fn typeList(it: *Interp, ts: []const mod.ValType) Error!Value {
    const out = try it.alloc().alloc(Value, ts.len);
    for (ts, out) |t, *o| o.* = .{ .str = t.name() };
    return value.wrapList(it.alloc(), out);
}

fn funcTypeValue(it: *Interp, t: mod.FuncType) Error!Value {
    const out = try it.alloc().alloc(Value, 2);
    out[0] = try typeList(it, t.params);
    out[1] = try typeList(it, t.results);
    return value.wrapList(it.alloc(), out);
}

fn limitsValue(it: *Interp, l: mod.Limits) Error!Value {
    const out = try it.alloc().alloc(Value, 2);
    out[0] = .{ .int = @intCast(l.min) };
    out[1] = if (l.max) |m| .{ .int = @intCast(m) } else Value.empty;
    return value.wrapList(it.alloc(), out);
}

fn toWasm(it: *Interp, t: mod.ValType, v: Value, raw: bool) Error!u64 {
    if (raw) {
        const s = try it.str(v);
        if (std.fmt.parseInt(u64, s, 0)) |n| return if (t == .i32 or t == .f32) n & 0xffff_ffff else n else |_| {}
        const n: u64 = @bitCast(try it.int(v));
        return if (t == .i32 or t == .f32) n & 0xffff_ffff else n;
    }
    switch (t) {
        .i32 => {
            const n = try it.int(v);
            if (n < std.math.minInt(i32) or n > std.math.maxInt(u32)) return it.failCode("ZTCL WASM VALUE", "expected i32 but got \"{s}\"", .{try it.str(v)});
            return @as(u32, @truncate(@as(u64, @bitCast(n))));
        },
        .i64 => return @bitCast(try it.int(v)),
        .f32, .f64 => {
            const n = v.asNumber() orelse return it.failCode("ZTCL WASM VALUE", "expected floating-point number but got \"{s}\"", .{try it.str(v)});
            const d: f64 = switch (n) {
                .int => |x| @floatFromInt(x),
                .double => |x| x,
                else => unreachable,
            };
            return if (t == .f32) @as(u32, @bitCast(@as(f32, @floatCast(d)))) else @bitCast(d);
        },
        .funcref, .externref => {
            const s = try it.str(v);
            if (s.len == 0 or eql(s, "null")) return 0;
            const n = try it.int(v);
            if (n < 0) return it.failCode("ZTCL WASM VALUE", "expected a reference but got \"{s}\"", .{s});
            return @as(u64, @intCast(n)) + 1;
        },
        else => return it.failCode("ZTCL WASM VALUE", "the type {s} has no Tcl form", .{t.name()}),
    }
}

fn fromWasm(it: *Interp, t: mod.ValType, x: u64, raw: bool) Error!Value {
    if (raw) {
        const n = if (t == .i32 or t == .f32) x & 0xffff_ffff else x;
        if (n <= std.math.maxInt(i64)) return .{ .int = @intCast(n) };
        return .{ .str = try std.fmt.allocPrint(it.alloc(), "{d}", .{n}) };
    }
    return switch (t) {
        .i32 => .{ .int = @as(i32, @bitCast(@as(u32, @truncate(x)))) },
        .i64 => .{ .int = @bitCast(x) },
        .f32 => .{ .double = @as(f32, @bitCast(@as(u32, @truncate(x)))) },
        .f64 => .{ .double = @bitCast(x) },
        .funcref, .externref => if (x == 0) Value.empty else .{ .int = @intCast(x - 1) },
        else => Value.empty,
    };
}

fn resultsValue(it: *Interp, ts: []const mod.ValType, xs: []const u64, raw: bool) Error!Value {
    if (ts.len == 0) return Value.empty;
    if (ts.len == 1) return fromWasm(it, ts[0], xs[0], raw);
    const out = try it.alloc().alloc(Value, ts.len);
    for (ts, xs, out) |t, x, *o| o.* = try fromWasm(it, t, x, raw);
    return value.wrapList(it.alloc(), out);
}

// ---- Errors of the engine ----

/// The Tcl error of an error of the store, for the commands of a C package.
pub fn engineErrorOf(it: *Interp, e: anyerror) Error {
    return engineError(it, try state(it), e, false);
}

/// The Tcl error of an error of the store.
fn engineError(it: *Interp, st: *State, e: anyerror, capped: bool) Error {
    switch (e) {
        error.HostError => {
            const p = st.pending orelse error.TclError;
            st.pending = null;
            return p;
        },
        error.OutOfMemory => return error.OutOfMemory,
        error.ComputeLimit => {
            if (!capped) return it.fail("compute limit reached", .{});
            return it.failCode("ZTCL WASM LIMIT", "wasm trap: compute limit reached", .{});
        },
        else => {
            const text = exec.trapText(e);
            return it.failCode(try std.fmt.allocPrint(it.alloc(), "ZTCL WASM TRAP {{{s}}}", .{text}), "wasm trap: {s}", .{text});
        },
    }
}

/// Runs `f` with the compute limit of `-limit`. A limit below the units
/// left caps the call: the call then stops with a catchable error, and
/// the units of the call leave the limit of the interpreter.
fn withLimit(comptime T: type, it: *Interp, st: *State, limit: ?u64, ctx: anytype, comptime f: anytype) Error!T {
    const saved = it.compute_limit;
    const capped = if (limit) |n| n < saved else false;
    if (capped) it.compute_limit = limit.?;
    defer if (capped) {
        const used = limit.? - it.compute_limit;
        it.compute_limit = saved - used;
    };
    return f(ctx) catch |e| return engineError(it, st, e, capped);
}

// ---- Instantiation ----

fn hostCall(ctx: ?*anyopaque, s: *exec.Store, args: []const u64, results: []u64) exec.Error!void {
    _ = s;
    const h: *TclHost = @ptrCast(@alignCast(ctx.?));
    const it = h.it;
    return hostRun(it, h, h.type, args, results) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        h.st.pending = e;
        return error.HostError;
    };
}

fn hostRun(it: *Interp, h: *TclHost, ft: mod.FuncType, args: []const u64, results: []u64) Error!void {
    const a = it.alloc();
    const prefix = try it.list(.{ .str = try a.dupe(u8, h.prefix) });
    const words = try a.alloc(Value, prefix.len + args.len);
    @memcpy(words[0..prefix.len], prefix);
    for (ft.params, args, words[prefix.len..]) |t, x, *w| w.* = try fromWasm(it, t, x, false);
    const r = try it.evalWords(words);
    if (ft.results.len == 0) return;
    if (ft.results.len == 1) {
        results[0] = try toWasm(it, ft.results[0], r, false);
        return;
    }
    const items = try it.list(r);
    if (items.len != ft.results.len) return it.failCode("ZTCL WASM VALUE", "the command gave {d} values for {d} results", .{ items.len, ft.results.len });
    for (ft.results, items, results) |t, v, *o| o.* = try toWasm(it, t, v, false);
}

const InstOpts = struct {
    imports: ?Value = null,
    link: ?Value = null,
    wasi: ?wasi.Options = null,
    command: ?[]const u8 = null,
    limit: ?u64 = null,
    /// The bridge of a C package, for the imports of the module `ztcl`.
    pkg: ?*cext.Pkg = null,
};

fn dictPairs(it: *Interp, v: Value) Error![]const Value {
    const items = try it.list(v);
    if (items.len % 2 != 0) return it.failCode("TCL VALUE DICTIONARY", "missing value to go with key", .{});
    return items;
}

fn lookupPair(it: *Interp, pairs: []const Value, key: []const u8) Error!?Value {
    var i: usize = pairs.len;
    while (i >= 2) {
        i -= 2;
        if (eql(try it.str(pairs[i]), key)) return pairs[i + 1];
    }
    return null;
}

/// Reads the WASI options from a dict: args, env, dirs, and stdin.
fn wasiOptions(it: *Interp, v: Value) Error!wasi.Options {
    const a = it.alloc();
    const pairs = try dictPairs(it, v);
    var o: wasi.Options = .{};
    var i: usize = 0;
    while (i < pairs.len) : (i += 2) {
        const k = try it.str(pairs[i]);
        const x = pairs[i + 1];
        if (eql(k, "args")) {
            const l = try it.list(x);
            const out = try a.alloc([]const u8, l.len);
            for (l, out) |e, *o2| o2.* = try it.str(e);
            o.args = out;
        } else if (eql(k, "env")) {
            const l = try dictPairs(it, x);
            const out = try a.alloc([]const u8, l.len / 2);
            for (out, 0..) |*o2, j| o2.* = try std.fmt.allocPrint(a, "{s}={s}", .{ try it.str(l[2 * j]), try it.str(l[2 * j + 1]) });
            o.env = out;
        } else if (eql(k, "dirs")) {
            const l = try dictPairs(it, x);
            if (l.len > 0 and !hasCap(it, .file)) return it.failCode("ZTCL WASM CAPABILITY file", "the WASI option dirs needs the capability file", .{});
            const out = try a.alloc([2][]const u8, l.len / 2);
            for (out, 0..) |*o2, j| {
                const path = try it.str(l[2 * j + 1]);
                const rel = (try fsroot.normal(it, path)) orelse return it.failCode("POSIX EACCES {permission denied}", "the folder \"{s}\" is outside the root folder", .{path});
                switch (try fsroot.stat(it, rel)) {
                    .ok => |info| if (!fsroot.isDir(info.mode)) return it.failCode("ZTCL WASM DIR", "\"{s}\" is not a folder", .{path}),
                    .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(a, "couldn't open folder \"{s}\": ", .{path})),
                }
                o2.* = .{ try it.str(l[2 * j]), rel };
            }
            o.dirs = out;
        } else if (eql(k, "stdin")) {
            o.stdin = try more.toBytes(it, try it.str(x));
        } else return it.failCode("TCL LOOKUP INDEX option", "bad WASI option \"{s}\": must be args, dirs, env, or stdin", .{k});
    }
    return o;
}

fn parseInstOpts(it: *Interp, argv: []const Value, o: *InstOpts) Error!void {
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        const k = try it.str(argv[i]);
        if (i + 1 >= argv.len) return it.fail("missing value for option \"{s}\"", .{k});
        const v = argv[i + 1];
        if (eql(k, "-imports")) {
            o.imports = v;
        } else if (eql(k, "-link")) {
            o.link = v;
        } else if (eql(k, "-wasi")) {
            o.wasi = try wasiOptions(it, v);
        } else if (eql(k, "-command")) {
            o.command = try it.str(v);
        } else if (eql(k, "-limit")) {
            const n = try it.int(v);
            if (n < 0) return it.failCode("ZTCL WASM LIMIT", "the limit must be 0 or more", .{});
            o.limit = @intCast(n);
        } else return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -command, -imports, -limit, -link, or -wasi", .{k});
    }
}

const InstCtx = struct {
    st: *State,
    m: *const mod.Module,
    imports: []const exec.Extern,
    fn run(c: *InstCtx) !*exec.Instance {
        return c.st.store.instantiate(c.m, c.imports);
    }
};

const CallCtx = struct {
    st: *State,
    addr: u32,
    args: []const u64,
    results: []u64,
    /// True after `proc_exit` of WASI.
    exited: bool = false,
    fn run(c: *CallCtx) !void {
        c.st.store.invoke(c.addr, c.args, c.results) catch |e| {
            if (e != error.Exit) return e;
            c.exited = true;
        };
    }
};

/// Instantiates a module. Gives the record and its handle.
fn instantiate(it: *Interp, mr: *ModRec, o: InstOpts) Error!struct { rec: *Rec, name: []const u8 } {
    const st = try state(it);
    const gpa = it.heap.backing;
    const m = mr.m;
    const rec = try gpa.create(Rec);
    rec.* = .{ .inst = undefined };
    var done = false;
    // A host function of the record can be in the store from here on.
    errdefer if (!done) retire(st, gpa, rec) catch freeRec(gpa, rec);
    if (o.wasi) |wo| rec.wasi = try wasi.create(it, gpa, wo, &st.pending);
    const imports = try it.alloc().alloc(exec.Extern, m.imports.len);
    const user = if (o.imports) |v| try dictPairs(it, v) else &.{};
    const links = if (o.link) |v| try dictPairs(it, v) else &.{};
    for (m.imports, imports) |imp, *out| {
        if (rec.wasi != null and eql(imp.module, wasi.module_name)) {
            if (imp.desc != .func) return it.failCode("ZTCL WASM LINK", "the WASI import \"{s}\" is not a function", .{imp.name});
            const addr = (try wasi.link(rec.wasi.?, &st.store, imp.name)) orelse return it.failCode("ZTCL WASM LINK", "unknown WASI import \"{s}\"", .{imp.name});
            out.* = .{ .func = addr };
            continue;
        }
        if (o.pkg != null and eql(imp.module, "ztcl")) {
            if (imp.desc != .func) return it.failCode("ZTCL WASM LINK", "the import \"ztcl\" \"{s}\" is not a function", .{imp.name});
            const addr = (try cext.link(o.pkg.?, imp.name)) orelse return it.failCode("ZTCL WASM LINK", "unknown import \"ztcl\" \"{s}\" of a C package", .{imp.name});
            out.* = .{ .func = addr };
            continue;
        }
        if (try lookupPair(it, links, imp.module)) |iv| {
            const other = try findInst(it, iv);
            out.* = other.inst.exportOf(imp.name) orelse return it.failCode("ZTCL WASM LINK", "the instance {s} has no export \"{s}\" for the import \"{s}\" \"{s}\"", .{ try it.str(iv), imp.name, imp.module, imp.name });
            continue;
        }
        if (try lookupPair(it, user, imp.module)) |fv| {
            const fns = try dictPairs(it, fv);
            if (try lookupPair(it, fns, imp.name)) |prefix| {
                if (imp.desc != .func) return it.failCode("ZTCL WASM LINK", "the import \"{s}\" \"{s}\" is a {s}: only a function import can be a command", .{ imp.module, imp.name, @tagName(imp.desc) });
                const h = try gpa.create(TclHost);
                h.* = .{ .st = st, .it = it, .type = m.types[imp.desc.func], .prefix = gpa.dupe(u8, try it.str(prefix)) catch |e| {
                    gpa.destroy(h);
                    return e;
                } };
                rec.hosts.append(gpa, h) catch |e| {
                    gpa.free(h.prefix);
                    gpa.destroy(h);
                    return e;
                };
                out.* = .{ .func = try st.store.addHost(m.types[imp.desc.func], .{ .ctx = h, .call = hostCall }) };
                continue;
            }
        }
        return it.failCode("ZTCL WASM LINK", "missing import \"{s}\" \"{s}\"", .{ imp.module, imp.name });
    }
    st.store.checkImports(m, imports) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LinkFailed => {
            const imp = m.imports[st.store.link_index];
            return it.failCode("ZTCL WASM LINK", "{s}: \"{s}\" \"{s}\"", .{ st.store.link_msg, imp.module, imp.name });
        },
    };
    var ictx: InstCtx = .{ .st = st, .m = m, .imports = imports };
    // The instance counts as a use of the module from here on: after a
    // trap of a segment, its functions can stay in a table.
    mr.uses += 1;
    rec.inst = try withLimit(*exec.Instance, it, st, o.limit, &ictx, InstCtx.run);
    rec.inst_set = true;
    if (o.pkg) |p| p.inst = rec.inst;
    if (rec.wasi) |w| w.mem = rec.inst.memory();
    try st.insts.append(gpa, rec);
    done = true;
    const name = try std.fmt.allocPrint(it.alloc(), "wasm{d}", .{st.insts.items.len - 1});
    // A WASI reactor exports `_initialize`, to run before the other exports.
    if (rec.wasi != null) if (rec.inst.exportOf("_initialize")) |e| if (e == .func) {
        var cctx: CallCtx = .{ .st = st, .addr = e.func, .args = &.{}, .results = &.{} };
        try withLimit(void, it, st, o.limit, &cctx, CallCtx.run);
    };
    if (o.command) |c| {
        const script = try std.fmt.allocPrint(it.alloc(), "proc {{{s}}} {{func args}} {{::ztcl::wasm call {s} $func {{*}}$args}}", .{ c, name });
        _ = try it.eval(script);
    }
    return .{ .rec = rec, .name = name };
}

fn cmdInstantiate(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len < 3 or argv.len % 2 != 1) return it.wrongArgs("ztcl::wasm instantiate module ?-imports dict? ?-link dict? ?-wasi dict? ?-command name? ?-limit units?");
    const mr = try findModule(it, argv[2]);
    var o: InstOpts = .{};
    try parseInstOpts(it, argv[3..], &o);
    const r = try instantiate(it, mr, o);
    return .{ .str = r.name };
}

// ---- Calls ----

fn exportFunc(it: *Interp, rec: *Rec, name: []const u8) Error!u32 {
    const e = rec.inst.exportOf(name) orelse return it.failCode("ZTCL WASM EXPORT", "the instance has no export \"{s}\"", .{name});
    if (e != .func) return it.failCode("ZTCL WASM EXPORT", "the export \"{s}\" is not a function", .{name});
    return e.func;
}

fn cmdCall(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len < 4) return it.wrongArgs("ztcl::wasm call instance function ?-limit units? ?-raw? ?--? ?arg ...?");
    const rec = try findInst(it, argv[2]);
    if (rec.inst.dead) return it.failCode("ZTCL WASM HANDLE", "the instance is deleted", .{});
    const st = try state(it);
    const addr = try exportFunc(it, rec, try it.str(argv[3]));
    var i: usize = 4;
    var limit: ?u64 = null;
    var raw = false;
    while (i < argv.len) {
        const s = try it.str(argv[i]);
        if (eql(s, "-raw")) {
            raw = true;
            i += 1;
        } else if (eql(s, "-limit")) {
            if (i + 1 >= argv.len) return it.fail("missing value for option \"-limit\"", .{});
            const n = try it.int(argv[i + 1]);
            if (n < 0) return it.failCode("ZTCL WASM LIMIT", "the limit must be 0 or more", .{});
            limit = @intCast(n);
            i += 2;
        } else if (eql(s, "--")) {
            i += 1;
            break;
        } else break;
    }
    const ft = st.store.funcs.items[addr].type;
    const args = argv[i..];
    if (args.len != ft.params.len) return it.failCode("ZTCL WASM ARGS", "the function \"{s}\" has {d} parameters and got {d} arguments", .{ try it.str(argv[3]), ft.params.len, args.len });
    const a = it.alloc();
    const xs = try a.alloc(u64, args.len);
    for (ft.params, args, xs) |t, v, *x| x.* = try toWasm(it, t, v, raw);
    const rs = try a.alloc(u64, ft.results.len);
    var ctx: CallCtx = .{ .st = st, .addr = addr, .args = xs, .results = rs };
    try withLimit(void, it, st, limit, &ctx, CallCtx.run);
    if (ctx.exited) {
        const code = if (rec.wasi) |w| w.exit_code else 0;
        return it.failCode(try std.fmt.allocPrint(a, "ZTCL WASM EXIT {d}", .{code}), "wasm exit {d}", .{code});
    }
    return resultsValue(it, ft.results, rs, raw);
}

fn cmdRun(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len < 3 or argv.len % 2 != 1) return it.wrongArgs("ztcl::wasm run module|fileName ?-args list? ?-env dict? ?-dirs dict? ?-stdin text? ?-imports dict? ?-limit units?");
    const st = try state(it);
    const gpa = it.heap.backing;
    const name = try it.str(argv[2]);
    const mr = findModule(it, argv[2]) catch blk: {
        _ = try addModule(it, try readFile(it, name));
        break :blk st.modules.items[st.modules.items.len - 1].?;
    };
    var wd: std.ArrayList(Value) = .empty;
    var o: InstOpts = .{};
    var i: usize = 3;
    while (i < argv.len) : (i += 2) {
        const k = try it.str(argv[i]);
        if (eql(k, "-args") or eql(k, "-env") or eql(k, "-dirs") or eql(k, "-stdin")) {
            try wd.append(it.alloc(), .{ .str = k[1..] });
            try wd.append(it.alloc(), argv[i + 1]);
        } else if (eql(k, "-imports")) {
            o.imports = argv[i + 1];
        } else if (eql(k, "-limit")) {
            const n = try it.int(argv[i + 1]);
            if (n < 0) return it.failCode("ZTCL WASM LIMIT", "the limit must be 0 or more", .{});
            o.limit = @intCast(n);
        } else return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -args, -dirs, -env, -imports, -limit, or -stdin", .{k});
    }
    // The first argument is the name of the program.
    var have_args = false;
    for (0..wd.items.len / 2) |j| {
        if (eql(try it.str(wd.items[2 * j]), "args")) {
            have_args = true;
            const l = try it.list(wd.items[2 * j + 1]);
            const out = try it.alloc().alloc(Value, l.len + 1);
            out[0] = .{ .str = name };
            @memcpy(out[1..], l);
            wd.items[2 * j + 1] = try value.wrapList(it.alloc(), out);
        }
    }
    if (!have_args) {
        try wd.append(it.alloc(), .{ .str = "args" });
        try wd.append(it.alloc(), try value.wrapList(it.alloc(), try it.alloc().dupe(Value, &.{.{ .str = name }})));
    }
    o.wasi = try wasiOptions(it, try value.wrapList(it.alloc(), wd.items));
    const r = try instantiate(it, mr, o);
    defer {
        const idx = st.insts.items.len - 1;
        if (st.insts.items[idx] == r.rec) st.insts.items[idx] = null;
        retire(st, gpa, r.rec) catch {};
    }
    const addr = try exportFunc(it, r.rec, "_start");
    var ctx: CallCtx = .{ .st = st, .addr = addr, .args = &.{}, .results = &.{} };
    try withLimit(void, it, st, o.limit, &ctx, CallCtx.run);
    return .{ .int = if (ctx.exited) r.rec.wasi.?.exit_code else 0 };
}

// ---- Memory and globals ----

fn memOf(it: *Interp, rec: *Rec) Error!*exec.Memory {
    if (rec.inst.dead) return it.failCode("ZTCL WASM HANDLE", "the instance is deleted", .{});
    if (rec.inst.exportOf("memory")) |e| if (e == .mem) return e.mem;
    return rec.inst.memory() orelse it.failCode("ZTCL WASM MEMORY", "the instance has no memory", .{});
}

fn range(it: *Interp, m: *const exec.Memory, addr_v: Value, len: u64) Error!usize {
    const addr = try it.int(addr_v);
    if (addr < 0 or @as(u64, @intCast(addr)) + len > m.bytes.len) return it.failCode("ZTCL WASM MEMORY", "the range {d} to {d} is outside the memory of {d} bytes", .{ addr, @as(u64, @intCast(@max(addr, 0))) + len, m.bytes.len });
    return @intCast(addr);
}

fn cmdMemory(it: *Interp, argv: []const Value) Error!Value {
    const use = "ztcl::wasm memory instance size|read|write|string|grow ?arg ...?";
    if (argv.len < 4) return it.wrongArgs(use);
    const rec = try findInst(it, argv[2]);
    const m = try memOf(it, rec);
    const sub = try it.str(argv[3]);
    const st = try state(it);
    if (eql(sub, "size")) {
        if (argv.len != 4) return it.wrongArgs("ztcl::wasm memory instance size");
        return .{ .int = m.pages() };
    }
    if (eql(sub, "grow")) {
        if (argv.len != 5) return it.wrongArgs("ztcl::wasm memory instance grow pages");
        const n = try it.int(argv[4]);
        if (n < 0) return it.failCode("ZTCL WASM MEMORY", "the count of pages must be 0 or more", .{});
        return .{ .int = if (st.store.growMemory(m, @intCast(n))) |old| old else -1 };
    }
    if (eql(sub, "read")) {
        if (argv.len != 6) return it.wrongArgs("ztcl::wasm memory instance read address length");
        const len = try it.int(argv[5]);
        if (len < 0) return it.failCode("ZTCL WASM MEMORY", "the length must be 0 or more", .{});
        const at = try range(it, m, argv[4], @intCast(len));
        try chargeBytes(it, @intCast(len));
        return .{ .str = try more.fromBytes(it, try it.alloc().dupe(u8, m.bytes[at .. at + @as(usize, @intCast(len))])) };
    }
    if (eql(sub, "string")) {
        if (argv.len != 5 and argv.len != 6) return it.wrongArgs("ztcl::wasm memory instance string address ?length?");
        const start = try range(it, m, argv[4], 0);
        var end: usize = undefined;
        if (argv.len == 6) {
            const len = try it.int(argv[5]);
            if (len < 0) return it.failCode("ZTCL WASM MEMORY", "the length must be 0 or more", .{});
            _ = try range(it, m, argv[4], @intCast(len));
            end = start + @as(usize, @intCast(len));
        } else {
            end = std.mem.indexOfScalarPos(u8, m.bytes, start, 0) orelse m.bytes.len;
        }
        try chargeBytes(it, end - start);
        return .{ .str = try it.alloc().dupe(u8, m.bytes[start..end]) };
    }
    if (eql(sub, "write")) {
        if (argv.len != 6 and argv.len != 7) return it.wrongArgs("ztcl::wasm memory instance write address bytes ?-text?");
        var text = false;
        if (argv.len == 7) {
            const o = try it.str(argv[6]);
            if (!eql(o, "-text")) return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -text", .{o});
            text = true;
        }
        const s = try it.str(argv[5]);
        const data = if (text) s else try more.toBytes(it, s);
        const at = try range(it, m, argv[4], data.len);
        try chargeBytes(it, data.len);
        @memcpy(m.bytes[at .. at + data.len], data);
        return .{ .int = @intCast(data.len) };
    }
    return it.failCode("TCL LOOKUP INDEX subcommand", "unknown subcommand \"{s}\": must be grow, read, size, string, or write", .{sub});
}

/// Uses one compute unit for each 4,096 bytes of a copy.
fn chargeBytes(it: *Interp, n: usize) Error!void {
    const units = n / 4096;
    if (units == 0) return;
    if (it.compute_limit < units) {
        it.compute_limit = 0;
        return it.fail("compute limit reached", .{});
    }
    it.compute_limit -= units;
}

fn cmdGlobal(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len != 4 and argv.len != 5) return it.wrongArgs("ztcl::wasm global instance name ?value?");
    const rec = try findInst(it, argv[2]);
    const name = try it.str(argv[3]);
    const e = rec.inst.exportOf(name) orelse return it.failCode("ZTCL WASM EXPORT", "the instance has no export \"{s}\"", .{name});
    if (e != .global) return it.failCode("ZTCL WASM EXPORT", "the export \"{s}\" is not a global", .{name});
    const g = e.global;
    if (argv.len == 5) {
        if (!g.type.mutable) return it.failCode("ZTCL WASM GLOBAL", "the global \"{s}\" is immutable", .{name});
        g.val = try toWasm(it, g.type.val, argv[4], false);
    }
    return fromWasm(it, g.type.val, g.val, false);
}

// ---- Introspection ----

fn cmdExports(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len != 3) return it.wrongArgs("ztcl::wasm exports module|instance");
    const name = try it.str(argv[2]);
    const m = if (std.mem.startsWith(u8, name, "wasmmod")) (try findModule(it, argv[2])).m else (try findInst(it, argv[2])).inst.module;
    const a = it.alloc();
    var out: std.ArrayList(Value) = .empty;
    for (m.exports) |e| {
        try out.append(a, .{ .str = e.name });
        try out.append(a, .{ .str = @tagName(e.kind) });
        try out.append(a, switch (e.kind) {
            .func => try funcTypeValue(it, m.funcType(e.index)),
            .table => try limitsValue(it, m.tables[e.index].limits),
            .mem => try limitsValue(it, m.mems[e.index]),
            .global => .{ .str = m.globals[e.index].val.name() },
        });
    }
    return value.wrapList(a, out.items);
}

fn cmdImports(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len != 3) return it.wrongArgs("ztcl::wasm imports module");
    const m = (try findModule(it, argv[2])).m;
    const a = it.alloc();
    var out: std.ArrayList(Value) = .empty;
    for (m.imports) |imp| {
        try out.append(a, .{ .str = imp.module });
        try out.append(a, .{ .str = imp.name });
        try out.append(a, .{ .str = @tagName(imp.desc) });
        try out.append(a, switch (imp.desc) {
            .func => |t| try funcTypeValue(it, m.types[t]),
            .table => |t| try limitsValue(it, t.limits),
            .mem => |l| try limitsValue(it, l),
            .global => |g| .{ .str = g.val.name() },
        });
    }
    return value.wrapList(a, out.items);
}

fn cmdInfo(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len != 3) return it.wrongArgs("ztcl::wasm info module");
    const m = (try findModule(it, argv[2])).m;
    const a = it.alloc();
    var feats: std.ArrayList(Value) = .empty;
    const names = [_][]const u8{ "bulk_memory", "sign_ext", "multi_value", "reference_types", "sat_trunc", "extended_const" };
    inline for (names) |n| {
        if (@field(m.features, n)) try feats.append(a, .{ .str = n });
    }
    var code: usize = 0;
    for (m.funcs) |f| code += f.code.len;
    const out = try a.alloc(Value, 14);
    out[0] = .{ .str = "functions" };
    out[1] = .{ .int = @intCast(m.func_types.len) };
    out[2] = .{ .str = "imports" };
    out[3] = .{ .int = @intCast(m.imports.len) };
    out[4] = .{ .str = "exports" };
    out[5] = .{ .int = @intCast(m.exports.len) };
    out[6] = .{ .str = "memories" };
    out[7] = .{ .int = @intCast(m.mems.len) };
    out[8] = .{ .str = "tables" };
    out[9] = .{ .int = @intCast(m.tables.len) };
    out[10] = .{ .str = "instructions" };
    out[11] = .{ .int = @intCast(code) };
    out[12] = .{ .str = "features" };
    out[13] = try value.wrapList(a, feats.items);
    return value.wrapList(a, out);
}

fn cmdDelete(it: *Interp, argv: []const Value) Error!Value {
    const st = try state(it);
    const gpa = it.heap.backing;
    for (argv[2..]) |v| {
        const name = try it.str(v);
        if (std.mem.startsWith(u8, name, "wasmmod")) {
            const r = try findModule(it, v);
            const idx = std.fmt.parseInt(usize, name[7..], 10) catch unreachable;
            // The code of a module with instances stays until the end of
            // the interpreter, because a table can hold its functions.
            if (r.uses == 0) {
                r.m.deinit();
                gpa.destroy(r);
                st.modules.items[idx] = null;
            } else r.deleted = true;
        } else {
            const r = try findInst(it, v);
            const idx = std.fmt.parseInt(usize, name[4..], 10) catch unreachable;
            st.insts.items[idx] = null;
            try retire(st, gpa, r);
        }
    }
    return Value.empty;
}

// ---- C packages ----

/// The name of the init function: the prefix, or the name of the file
/// with no folder, no `lib`, and no extension, with a capital first letter.
fn initName(it: *Interp, file: []const u8, prefix: []const u8) Error![]const u8 {
    var p = prefix;
    if (p.len == 0) {
        p = std.fs.path.basename(file);
        if (std.mem.startsWith(u8, p, "lib")) p = p[3..];
        if (std.mem.indexOfScalar(u8, p, '.')) |dot| p = p[0..dot];
    }
    if (p.len == 0) return it.failCode("ZTCL WASM PACKAGE", "no init function for the file \"{s}\"", .{file});
    const out = try std.fmt.allocPrint(it.alloc(), "{s}_Init", .{p});
    out[0] = std.ascii.toUpper(out[0]);
    for (out[1 .. out.len - 5]) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn cmdPackage(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len < 3) return it.wrongArgs("ztcl::wasm package fileName ?prefix? ?-wasi dict?");
    const st = try state(it);
    const gpa = it.heap.backing;
    const file = try it.str(argv[2]);
    var i: usize = 3;
    var prefix: []const u8 = "";
    if (i < argv.len and !std.mem.startsWith(u8, try it.str(argv[i]), "-")) {
        prefix = try it.str(argv[i]);
        i += 1;
    }
    var o: InstOpts = .{ .wasi = .{} };
    while (i < argv.len) : (i += 2) {
        const k = try it.str(argv[i]);
        if (!eql(k, "-wasi") or i + 1 >= argv.len) return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -wasi", .{k});
        o.wasi = try wasiOptions(it, argv[i + 1]);
    }
    const name = try initName(it, file, prefix);
    _ = try addModule(it, try readFile(it, file));
    const mr = st.modules.items[st.modules.items.len - 1].?;
    const p = try gpa.create(cext.Pkg);
    p.* = .{ .it = it, .store = &st.store, .pending = &st.pending };
    st.pkgs.append(gpa, p) catch |e| {
        gpa.destroy(p);
        return e;
    };
    o.pkg = p;
    _ = try instantiate(it, mr, o);
    if (cext.bind(p)) |missing| return it.failCode("ZTCL WASM PACKAGE", "the module \"{s}\" has no export \"{s}\" of a C package", .{ file, missing });
    var ctx: InitCtx = .{ .p = p, .name = name };
    const r = (try withLimit(?cext.InitResult, it, st, null, &ctx, InitCtx.run)) orelse return it.failCode("ZTCL WASM PACKAGE", "the module \"{s}\" has no export \"{s}\"", .{ file, name });
    if (r.code != 0) return it.failCode("ZTCL WASM PACKAGE", "{s}", .{r.text});
    return .{ .str = r.text };
}

const InitCtx = struct {
    p: *cext.Pkg,
    name: []const u8,
    fn run(c: *InitCtx) !?cext.InitResult {
        return cext.init(c.p, c.name);
    }
};

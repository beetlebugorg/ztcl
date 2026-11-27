//! C packages in WebAssembly in native ztcl (docs/dev/cext-tasks/04e-wasm-engine.md).
//!
//! A package is a module that `zig cc -target wasm32-wasi` builds from
//! the C sources of a Tcl package and `libztclstubs.a`. It imports the
//! functions of the module `ztcl` (`src/cext/host.zig`) and exports the
//! functions `ztcl_cext_*` of `src/cext/wasm_stubs.zig`. This file gives
//! the imports as host functions of the engine. Each one reads its
//! arguments from the linear memory of the package, calls the code of
//! `src/cext/zside.zig` that the JavaScript glue of `web/ztcl.mjs` and
//! the native path also use, and writes the reply record of the package.
//!
//! An `Arg` has the same layout on both sides: a kind, a length, and 64
//! bits. In the package, the bits of text and of a list are an address of
//! its memory. A copy into the package goes to the exchange buffer of
//! `ztcl_cext_buf`, which can grow the memory, so each access reads the
//! memory again.
//!
//! A command of the package is a native command of ztcl. Its call copies
//! the arguments into the array of `ztcl_cext_args` and calls
//! `ztcl_cext_dispatch`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("../interp.zig");
const Interp = interp.Interp;
const Error = interp.Error;
const Value = @import("../value.zig").Value;
const zside = @import("../cext/zside.zig");
const Arg = zside.Arg;
const mod = @import("module.zig");
const exec = @import("exec.zig");

pub const Pkg = struct {
    it: *Interp,
    store: *exec.Store,
    inst: *exec.Instance = undefined,
    /// The Tcl error of a call inside the package.
    pending: *?Error,
    reply: u32 = 0,
    buf: u32 = 0,
    buf_cap: u32 = 0,
    args: u32 = 0,
    args_cap: u32 = 0,
    prec: u32 = std.math.maxInt(u32),
    f_buf: u32 = 0,
    f_args: u32 = 0,
    f_dispatch: u32 = 0,
    f_precision: ?u32 = null,
    hosts: [9]Host = undefined,
    targets: std.ArrayList(*Target) = .empty,
    /// The child interps that the package has handles of. The handle of
    /// the interp of the package is 1, and the handle of kid `i` is i + 2.
    kids: std.ArrayList(Kid) = .empty,

    fn mem(p: *Pkg) []u8 {
        return p.inst.mems[0].bytes;
    }

    fn call(p: *Pkg, f: u32, args: []const u64) exec.Error!u64 {
        var r: [1]u64 = .{0};
        const ft = p.store.funcs.items[f].type;
        try p.store.invoke(f, args, r[0..ft.results.len]);
        return r[0];
    }

    /// The address of an exchange buffer of at least `len` bytes.
    fn xbuf(p: *Pkg, len: usize) exec.Error!u32 {
        if (len > p.buf_cap or p.buf == 0) {
            const want: u32 = @intCast(@max(len, 2 * @as(usize, p.buf_cap), 256));
            const addr: u32 = @truncate(try p.call(p.f_buf, &.{want}));
            if (addr == 0) return error.OutOfMemory;
            p.buf = addr;
            p.buf_cap = want;
        }
        return p.buf;
    }

    pub fn deinit(p: *Pkg, gpa: std.mem.Allocator) void {
        for (p.kids.items) |k| gpa.free(k.name);
        p.kids.deinit(gpa);
        for (p.targets.items) |t| gpa.destroy(t);
        p.targets.deinit(gpa);
        gpa.destroy(p);
    }
};

const Target = struct { pkg: *Pkg, id: u32 };

const Kid = struct { it: *Interp, parent: u32, name: []const u8 };

/// The package of the running import, for `Handles`.
threadlocal var cur: ?*Pkg = null;

/// The handles of interps for `zside.interpOp`.
const Handles = struct {
    pub fn handleOf(it: *Interp) Error!u32 {
        const p = cur.?;
        if (it == p.it) return 1;
        for (p.kids.items, 0..) |k, i| if (k.it == it) return @intCast(i + 2);
        const parent = it.parent orelse return error.OutOfMemory;
        var iter = parent.children.iterator();
        const name = while (iter.next()) |e| {
            if (e.value_ptr.*.it == it) break e.key_ptr.*;
        } else return error.OutOfMemory;
        const ph = try handleOf(parent);
        const gpa = p.it.heap.backing;
        const n = try gpa.dupe(u8, name);
        p.kids.append(gpa, .{ .it = it, .parent = ph, .name = n }) catch |e| {
            gpa.free(n);
            return e;
        };
        return @intCast(p.kids.items.len + 1);
    }

    pub fn interpOf(handle: u32) ?*Interp {
        return itOf(cur.?, handle);
    }
};

/// The interp of a handle. A child must still be in its parent.
fn itOf(p: *Pkg, handle: u64) ?*Interp {
    if (handle == 1) return p.it;
    if (handle < 2 or handle - 2 >= p.kids.items.len) return null;
    const k = p.kids.items[@intCast(handle - 2)];
    const parent = itOf(p, k.parent) orelse return null;
    const c = parent.children.get(k.name) orelse return null;
    return if (c.it == k.it) k.it else null;
}

const Which = enum { cmd_create, cmd_delete, eval, var_get, var_set, pkg_provide, err_get, err_set, interp_op };

const Host = struct { pkg: *Pkg, which: Which };

const I = mod.ValType.i32;
const sigs = struct {
    const r1 = [_]mod.ValType{I};
    const p1 = [_]mod.ValType{I};
    const p2 = [_]mod.ValType{ I, I };
    const p3 = [_]mod.ValType{ I, I, I };
    const p4 = [_]mod.ValType{ I, I, I, I };
    const p5 = [_]mod.ValType{ I, I, I, I, I };
};

fn typeOf(w: Which) mod.FuncType {
    const params: []const mod.ValType = switch (w) {
        .cmd_create, .eval, .var_get => &sigs.p4,
        .cmd_delete => &sigs.p3,
        .var_set, .pkg_provide => &sigs.p5,
        .err_get => &sigs.p1,
        .err_set => &sigs.p2,
        .interp_op => &sigs.p3,
    };
    return .{ .params = params, .results = &sigs.r1 };
}

/// Gives the host function of the import `ztcl.name`, or null.
pub fn link(p: *Pkg, name: []const u8) !?u32 {
    const names = [_][]const u8{ "cmd_create", "cmd_delete", "eval", "var_get", "var_set", "pkg_provide", "err_get", "err_set", "interp_op" };
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) {
            const w: Which = @fromBackingInt(@intCast(i));
            p.hosts[i] = .{ .pkg = p, .which = w };
            return try p.store.addHost(typeOf(w), .{ .ctx = &p.hosts[i], .call = hostCall });
        }
    }
    return null;
}

/// Finds the exports of the bridge after the instantiation.
pub fn bind(p: *Pkg) ?[]const u8 {
    const names = [_][]const u8{ "ztcl_cext_reply", "ztcl_cext_buf", "ztcl_cext_args", "ztcl_cext_dispatch" };
    var addrs: [4]u32 = undefined;
    for (names, &addrs) |n, *a| {
        const e = p.inst.exportOf(n) orelse return n;
        if (e != .func) return n;
        a.* = e.func;
    }
    if (p.inst.mems.len == 0) return "memory";
    p.f_buf = addrs[1];
    p.f_args = addrs[2];
    p.f_dispatch = addrs[3];
    if (p.inst.exportOf("ztcl_cext_precision")) |e| if (e == .func) {
        p.f_precision = e.func;
    };
    p.reply = @truncate(p.call(addrs[0], &.{}) catch return "ztcl_cext_reply");
    return null;
}

fn text(p: *Pkg, ptr: u64, len: u64) exec.Error![]const u8 {
    const m = p.mem();
    if (ptr + len > m.len) return error.OutOfBoundsMemory;
    return m[@intCast(ptr)..@intCast(ptr + len)];
}

/// A native copy of the `Arg` at `addr` of the package.
fn fromPkg(p: *Pkg, addr: u64, depth: u32) exec.Error!Arg {
    const m = p.mem();
    if (addr + 16 > m.len) return error.OutOfBoundsMemory;
    const rec = m[@intCast(addr)..][0..16];
    var a: Arg = .{ .kind = std.mem.readInt(u32, rec[0..4], .little), .len = std.mem.readInt(u32, rec[4..8], .little), .bits = std.mem.readInt(u64, rec[8..16], .little) };
    const al = p.it.alloc();
    switch (a.kind) {
        0 => {
            const t = try al.dupe(u8, try text(p, a.bits & 0xffff_ffff, a.len));
            a.bits = @intFromPtr(t.ptr);
        },
        3 => {
            if (depth > 64) return error.OutOfBoundsMemory;
            const out = try al.alloc(Arg, a.len);
            const base = a.bits & 0xffff_ffff;
            for (out, 0..) |*o, i| o.* = try fromPkg(p, base + 16 * i, depth + 1);
            a.bits = @intFromPtr(out.ptr);
        },
        else => {},
    }
    return a;
}

/// The bytes of the data of `a` in the package: the records of a list
/// and the text.
fn extra(a: Arg) usize {
    return switch (a.kind) {
        0 => a.len,
        3 => blk: {
            const items: [*]const Arg = @ptrFromInt(@as(usize, @intCast(a.bits)));
            var n: usize = 16 * a.len;
            for (items[0..a.len]) |e| n += extra(e);
            break :blk n;
        },
        else => 0,
    };
}

/// Writes the record of `a` at `at` and its data at `off`. Gives the
/// offset after the data.
fn writeArg(m: []u8, at: usize, a: Arg, off_in: usize) usize {
    var off = off_in;
    var bits = a.bits;
    switch (a.kind) {
        0 => {
            const src: [*]const u8 = @ptrFromInt(@as(usize, @intCast(a.bits)));
            if (a.len > 0) @memcpy(m[off .. off + a.len], src[0..a.len]);
            bits = off;
            off += a.len;
        },
        3 => {
            const items: [*]const Arg = @ptrFromInt(@as(usize, @intCast(a.bits)));
            const recs = off;
            off += 16 * a.len;
            for (items[0..a.len], 0..) |e, i| off = writeArg(m, recs + 16 * i, e, off);
            bits = recs;
        },
        else => {},
    }
    std.mem.writeInt(u32, m[at..][0..4], a.kind, .little);
    std.mem.writeInt(u32, m[at + 4 ..][0..4], a.len, .little);
    std.mem.writeInt(u64, m[at + 8 ..][0..8], bits, .little);
    return off;
}

/// Writes `a` into the reply record of the package.
fn toReply(p: *Pkg, a: Arg) exec.Error!void {
    const n = extra(a);
    const base = if (n > 0) try p.xbuf(n) else 0;
    const m = p.mem();
    if (p.reply + 16 > m.len or base + n > m.len) return error.OutOfBoundsMemory;
    _ = writeArg(m, p.reply, a, base);
}

fn hostCall(ctx: ?*anyopaque, _: *exec.Store, a: []const u64, results: []u64) exec.Error!void {
    const h: *Host = @ptrCast(@alignCast(ctx.?));
    const p = h.pkg;
    if (p.it.compute_limit == 0) return error.ComputeLimit;
    p.it.compute_limit -= 1;
    const it = itOf(p, a[0] & 0xffff_ffff) orelse {
        results[0] = 1;
        return;
    };
    const saved = cur;
    cur = p;
    defer cur = saved;
    var out: Arg = .{ .kind = 0, .len = 0, .bits = 0 };
    const rc: i32 = switch (h.which) {
        .cmd_create => blk: {
            const name = try text(p, a[2], a[3]);
            const t = try it.heap.backing.create(Target);
            t.* = .{ .pkg = p, .id = @truncate(a[1]) };
            p.targets.append(it.heap.backing, t) catch {
                it.heap.backing.destroy(t);
                return error.OutOfMemory;
            };
            _ = zside.command(it, name, pkgCommand, t) catch |e| return pend(p, e);
            break :blk 0;
        },
        .cmd_delete => blk: {
            const rc = zside.delete(it, try text(p, a[1], a[2]), &out);
            if (rc != 0) try toReply(p, out);
            break :blk rc;
        },
        .eval => blk: {
            const rc = zside.eval(it, try text(p, a[1], a[2]), @truncate(@as(i64, @bitCast(a[3]))), &out);
            try toReply(p, out);
            break :blk rc;
        },
        .var_get => blk: {
            const rc = zside.varGet(it, try text(p, a[1], a[2]), &out);
            try toReply(p, out);
            break :blk rc;
        },
        .var_set => blk: {
            const name = try it.alloc().dupe(u8, try text(p, a[1], a[2]));
            const v = try fromPkg(p, a[3] & 0xffff_ffff, 0);
            const rc = zside.varSet(it, name, &v, &out);
            if (rc != 0) try toReply(p, out);
            break :blk rc;
        },
        .pkg_provide => blk: {
            const name = try it.alloc().dupe(u8, try text(p, a[1], a[2]));
            const ver = try it.alloc().dupe(u8, try text(p, a[3], a[4]));
            const rc = zside.provide(it, name, ver, &out);
            if (rc != 0) try toReply(p, out);
            break :blk rc;
        },
        .err_get => blk: {
            const rc = zside.errGet(it, &out);
            if (rc == 0) try toReply(p, out);
            break :blk rc;
        },
        .err_set => blk: {
            const v = try fromPkg(p, a[1] & 0xffff_ffff, 0);
            break :blk zside.errSet(it, &v);
        },
        .interp_op => blk: {
            const v = try fromPkg(p, a[2] & 0xffff_ffff, 0);
            const rc = zside.interpOp(it, @truncate(a[1]), &v, &out, Handles);
            try toReply(p, out);
            break :blk rc;
        },
    };
    results[0] = @as(u32, @bitCast(rc));
}

fn pend(p: *Pkg, e: Error) exec.Error {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    p.pending.* = e;
    return error.HostError;
}

/// A command of a package: copies the arguments into the package and
/// calls `ztcl_cext_dispatch`.
fn pkgCommand(it: *Interp, argv: []const Value, _: ?*interp.Cmd) Error!Value {
    const self = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name", .{});
    const t: *const Target = @ptrCast(@alignCast(self.ctx.?));
    const p = t.pkg;
    const args = try it.alloc().alloc(Arg, argv.len);
    for (argv, args) |v, *x| x.* = try zside.argOf(it, v);
    const r = run(p, t.id, args) catch |e| return @import("cmd.zig").engineErrorOf(it, e);
    return zside.resultOf(it, r.code, try zside.valueOf(it, r.reply));
}

fn run(p: *Pkg, id: u32, args: []const Arg) exec.Error!struct { code: i32, reply: Arg } {
    const it = p.it;
    if (p.f_precision) |f| if (p.prec != it.precision) {
        _ = try p.call(f, &.{it.precision});
        p.prec = it.precision;
    };
    if (args.len > p.args_cap or p.args == 0) {
        const cap: u32 = @intCast(@max(args.len, 16));
        p.args = @truncate(try p.call(p.f_args, &.{cap}));
        if (p.args == 0) return error.OutOfMemory;
        p.args_cap = cap;
    }
    var total: usize = 0;
    for (args) |a| total += extra(a);
    const base = if (total > 0) try p.xbuf(total) else 0;
    const m = p.mem();
    if (p.args + 16 * args.len > m.len or base + total > m.len) return error.OutOfBoundsMemory;
    var off: usize = base;
    for (args, 0..) |a, i| off = writeArg(m, p.args + 16 * i, a, off);
    const code: i32 = @bitCast(@as(u32, @truncate(try p.call(p.f_dispatch, &.{ id, args.len }))));
    return .{ .code = code, .reply = try fromPkg(p, p.reply, 0) };
}

/// Runs the init function of a package. Gives the code and the result text.
pub const InitResult = struct { code: i32, text: []const u8 };

pub fn init(p: *Pkg, name: []const u8) exec.Error!?InitResult {
    const ie = p.inst.exportOf("ztcl_cext_interp") orelse return null;
    const re = p.inst.exportOf("ztcl_cext_result") orelse return null;
    const fe = p.inst.exportOf(name) orelse return null;
    if (ie != .func or re != .func or fe != .func) return null;
    // Handle 1 is the interp of the package; 0 is no interp.
    const ip = try p.call(ie.func, &.{1});
    const code: i32 = @bitCast(@as(u32, @truncate(try p.call(fe.func, &.{ip}))));
    const r = try p.call(re.func, &.{ip});
    const a = try fromPkg(p, r & 0xffff_ffff, 0);
    const v = zside.valueOf(p.it, a) catch return error.OutOfMemory;
    return .{ .code = code, .text = p.it.str(v) catch return error.OutOfMemory };
}

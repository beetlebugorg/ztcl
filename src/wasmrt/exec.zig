//! The store, the instances, and the interpreter of the wasm engine.
//!
//! A `Store` holds the functions, tables, memories, and globals of its
//! instances, as in the abstract machine of the specification. A
//! function has an address: its index in `Store.funcs`. A reference of
//! a function is the address plus 1, and 0 is the null reference. An
//! external reference is the value of the host plus 1.
//!
//! The interpreter runs the internal code of `module.zig`. It keeps
//! the values of all frames on one stack of 64-bit slots: the locals of
//! a frame first, then its operands. A call to a wasm function puts no
//! frame on the native stack. A call has the arguments on top of the
//! stack, and they become the first locals of the new frame. A return
//! moves the results to the start of the frame. A call of a host
//! function copies the arguments out, so the host function can call
//! into the store again, and the stack can grow.
//!
//! Limits: each call and each pass of a loop uses one compute unit from
//! `Store.units`, and the work of a bulk instruction uses one unit for
//! each 4,096 bytes or elements. A memory grows only when `grow_hook`
//! accepts the new bytes. The count of frames and the count of stack
//! slots have a maximum, and a deeper call traps.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const mod = @import("module.zig");
const Module = mod.Module;
const ValType = mod.ValType;
const FuncType = mod.FuncType;
const Ins = mod.Ins;
const op = mod.op;
const jit = @import("jit_x64.zig");

pub const Trap = error{
    Unreachable,
    DivByZero,
    IntOverflow,
    InvalidConversion,
    OutOfBoundsMemory,
    OutOfBoundsTable,
    UndefinedElement,
    UninitializedElement,
    IndirectCallMismatch,
    StackExhausted,
    ComputeLimit,
    InstanceDeleted,
    /// A WASI program called `proc_exit`; `Store.exit_code` has the code.
    Exit,
};

pub const Error = Trap || error{
    OutOfMemory,
    /// A host function failed. The host keeps its own error.
    HostError,
};

/// The text of a trap, as the spec tests write it.
pub fn trapText(e: anyerror) []const u8 {
    return switch (e) {
        error.Unreachable => "unreachable",
        error.DivByZero => "integer divide by zero",
        error.IntOverflow => "integer overflow",
        error.InvalidConversion => "invalid conversion to integer",
        error.OutOfBoundsMemory => "out of bounds memory access",
        error.OutOfBoundsTable => "out of bounds table access",
        error.UndefinedElement => "undefined element",
        error.UninitializedElement => "uninitialized element",
        error.IndirectCallMismatch => "indirect call type mismatch",
        error.StackExhausted => "call stack exhausted",
        error.ComputeLimit => "compute limit reached",
        error.InstanceDeleted => "the instance of the function is deleted",
        error.Exit => "exit",
        error.OutOfMemory => "out of memory",
        else => "host error",
    };
}

pub const page = 65536;

pub const Host = struct {
    ctx: ?*anyopaque,
    call: *const fn (ctx: ?*anyopaque, s: *Store, args: []const u64, results: []u64) Error!void,
};

pub const FuncInst = struct {
    type: FuncType,
    kind: union(enum) {
        wasm: struct { inst: *Instance, func: *const mod.Func },
        host: Host,
    },
};

pub const Table = struct {
    elem: ValType,
    refs: std.ArrayList(u64) = .empty,
    max: ?u64,
};

pub const Memory = struct {
    bytes: []u8 = &.{},
    max: u64,

    pub fn pages(m: *const Memory) u32 {
        return @intCast(m.bytes.len / page);
    }
};

pub const Global = struct { type: mod.GlobalType, val: u64 };

pub const Extern = union(mod.ExternKind) {
    func: u32,
    table: *Table,
    mem: *Memory,
    global: *Global,
};

pub const Instance = struct {
    module: *const Module,
    funcs: []u32,
    tables: []*Table,
    mems: []*Memory,
    globals: []*Global,
    /// The references of each element segment. A drop makes it empty.
    elems: [][]const u64,
    datas: [][]const u8,
    /// True after `Store.release`.
    dead: bool = false,
    /// The count of other instances that import a part of this one.
    users: u32 = 0,
    /// The instances that this one imports from.
    deps: []*Instance = &.{},
    /// The tables, memories, and globals of this instance (not imported).
    own_tables: []*Table = &.{},
    own_mems: []*Memory = &.{},
    own_globals: []*Global = &.{},
    freed: bool = false,
    /// A value for the host, such as the WASI state.
    host_data: ?*anyopaque = null,

    pub fn exportOf(inst: *const Instance, name: []const u8) ?Extern {
        const e = inst.module.findExport(name) orelse return null;
        return switch (e.kind) {
            .func => .{ .func = inst.funcs[e.index] },
            .table => .{ .table = inst.tables[e.index] },
            .mem => .{ .mem = inst.mems[e.index] },
            .global => .{ .global = inst.globals[e.index] },
        };
    }

    pub fn memory(inst: *const Instance) ?*Memory {
        return if (inst.mems.len > 0) inst.mems[0] else null;
    }
};

const Frame = struct { func: *const mod.Func, pc: u32, fp: usize, inst: *Instance };

pub const GrowHook = struct {
    ctx: ?*anyopaque,
    /// True when the store can take `more` bytes.
    fits: *const fn (ctx: ?*anyopaque, more: usize) bool,
};

pub const Store = struct {
    gpa: Allocator,
    funcs: std.ArrayList(FuncInst) = .empty,
    instances: std.ArrayList(*Instance) = .empty,
    stack: []u64 = &.{},
    sp: usize = 0,
    frames: std.ArrayList(Frame) = .empty,
    /// The compute units left.
    units: *u64,
    own_units: u64 = std.math.maxInt(u64),
    grow_hook: ?GrowHook = null,
    exit_code: u32 = 0,
    max_frames: usize = 20_000,
    max_slots: usize = 1 << 20,
    /// The count of nested runs of the interpreter (host calls inside).
    nest: u32 = 0,
    max_nest: u32 = 100,
    /// True when calls run in the JIT code of `jit_x64.zig`. The default is
    /// on where the JIT is supported.
    jit_on: bool = jit.supported,
    /// The lowest native stack address of the JIT frames of the outermost run.
    jit_rsp_limit: usize = 0,
    /// The reason of the last link error.
    link_msg: []const u8 = "",
    link_index: usize = 0,

    pub fn init(gpa: Allocator) Store {
        var s: Store = .{ .gpa = gpa, .units = undefined };
        s.units = &s.own_units;
        return s;
    }

    /// Fixes `units` after the store moves, when it uses its own count.
    pub fn fixUnits(s: *Store) void {
        s.units = &s.own_units;
    }

    pub fn deinit(s: *Store) void {
        for (s.instances.items) |inst| {
            s.freeParts(inst);
            s.gpa.destroy(inst);
        }
        s.instances.deinit(s.gpa);
        s.funcs.deinit(s.gpa);
        s.gpa.free(s.stack);
        s.frames.deinit(s.gpa);
    }

    fn freeParts(s: *Store, inst: *Instance) void {
        if (inst.freed) return;
        inst.freed = true;
        for (inst.own_tables) |t| {
            t.refs.deinit(s.gpa);
            s.gpa.destroy(t);
        }
        for (inst.own_mems) |m| {
            s.gpa.free(m.bytes);
            s.gpa.destroy(m);
        }
        for (inst.own_globals) |g| s.gpa.destroy(g);
        for (inst.elems) |e| s.gpa.free(e);
        s.gpa.free(inst.elems);
        s.gpa.free(inst.datas);
        s.gpa.free(inst.funcs);
        s.gpa.free(inst.tables);
        s.gpa.free(inst.mems);
        s.gpa.free(inst.globals);
        s.gpa.free(inst.own_tables);
        s.gpa.free(inst.own_mems);
        s.gpa.free(inst.own_globals);
        s.gpa.free(inst.deps);
        inst.funcs = &.{};
        inst.tables = &.{};
        inst.mems = &.{};
        inst.globals = &.{};
        inst.elems = &.{};
        inst.datas = &.{};
    }

    /// Marks an instance dead. Its memory goes back when no other
    /// instance imports from it. A call of one of its functions then traps.
    pub fn release(s: *Store, inst: *Instance) void {
        if (inst.dead) return;
        inst.dead = true;
        s.collect(inst);
    }

    fn collect(s: *Store, inst: *Instance) void {
        if (!inst.dead or inst.users > 0 or inst.freed) return;
        const deps = inst.deps;
        inst.deps = &.{};
        defer s.gpa.free(deps);
        s.freeParts(inst);
        for (deps) |d| {
            d.users -= 1;
            s.collect(d);
        }
    }

    pub fn addHost(s: *Store, t: FuncType, h: Host) Allocator.Error!u32 {
        try s.funcs.append(s.gpa, .{ .type = t, .kind = .{ .host = h } });
        return @intCast(s.funcs.items.len - 1);
    }

    fn fits(s: *Store, more: usize) bool {
        const h = s.grow_hook orelse return true;
        return h.fits(h.ctx, more);
    }

    pub fn tickPub(s: *Store) Trap!void {
        return s.tick();
    }

    fn tick(s: *Store) Trap!void {
        if (s.units.* == 0) return error.ComputeLimit;
        s.units.* -= 1;
    }

    /// Uses one compute unit for each 4,096 items of a bulk instruction.
    fn bulk(s: *Store, n: u64) Trap!void {
        const units = n / 4096;
        if (units == 0) return;
        if (s.units.* < units) {
            s.units.* = 0;
            return error.ComputeLimit;
        }
        s.units.* -= units;
    }

    pub fn ensureStack(s: *Store, need: usize) Error!void {
        if (need <= s.stack.len) return;
        if (need > s.max_slots) return error.StackExhausted;
        var n = @max(s.stack.len * 2, 4096);
        while (n < need) n *= 2;
        n = @min(n, s.max_slots);
        if (!s.fits((n - s.stack.len) * 8)) return error.StackExhausted;
        s.stack = try s.gpa.realloc(s.stack, n);
    }

    /// Grows a memory by `delta` pages. Gives the old count or null.
    pub fn growMemory(s: *Store, m: *Memory, delta: u64) ?u32 {
        const old = m.pages();
        const want = @as(u64, old) + delta;
        if (want > m.max) return null;
        if (delta == 0) return old;
        const bytes: usize = @intCast(want * page);
        if (!s.fits(bytes - m.bytes.len)) return null;
        const nb = s.gpa.realloc(m.bytes, bytes) catch return null;
        @memset(nb[m.bytes.len..], 0);
        m.bytes = nb;
        return old;
    }

    pub fn growTable(s: *Store, t: *Table, delta: u64, fill: u64) ?u32 {
        const old: u32 = @intCast(t.refs.items.len);
        const want = @as(u64, old) + delta;
        if (want > (t.max orelse mod.max_table) or want > mod.max_table) return null;
        if (!s.fits(@intCast(delta * 8))) return null;
        t.refs.appendNTimes(s.gpa, fill, @intCast(delta)) catch return null;
        return old;
    }

    // ---- Instantiation ----

    pub const LinkError = error{ LinkFailed, OutOfMemory };

    fn linkFail(s: *Store, i: usize, msg: []const u8) LinkError {
        s.link_msg = msg;
        s.link_index = i;
        return error.LinkFailed;
    }

    /// Checks the imports against the module. `imports` has one entry
    /// for each import of the module, in order.
    pub fn checkImports(s: *Store, m: *const Module, imports: []const Extern) LinkError!void {
        if (imports.len != m.imports.len) return s.linkFail(0, "wrong count of imports");
        for (m.imports, imports, 0..) |want, got, i| {
            if (@as(mod.ExternKind, want.desc) != @as(mod.ExternKind, got)) return s.linkFail(i, "incompatible import type");
            switch (want.desc) {
                .func => |ti| {
                    if (!m.types[ti].eql(s.funcs.items[got.func].type)) return s.linkFail(i, "incompatible import type");
                },
                .table => |t| {
                    const g = got.table;
                    if (g.elem != t.elem) return s.linkFail(i, "incompatible import type");
                    if (!limitsMatch(g.refs.items.len, g.max, t.limits)) return s.linkFail(i, "incompatible import type");
                },
                .mem => |l| {
                    const g = got.mem;
                    if (!limitsMatch(g.pages(), if (g.max == mod.max_pages and !memHasMax(g)) null else g.max, l)) return s.linkFail(i, "incompatible import type");
                },
                .global => |t| {
                    const g = got.global;
                    if (g.type.val != t.val or g.type.mutable != t.mutable) return s.linkFail(i, "incompatible import type");
                },
            }
        }
    }

    pub fn instantiate(s: *Store, m: *const Module, imports: []const Extern) (LinkError || Error)!*Instance {
        try s.checkImports(m, imports);
        const a = s.gpa;
        const inst = try a.create(Instance);
        inst.* = .{
            .module = m,
            .funcs = try a.alloc(u32, m.func_types.len),
            .tables = try a.alloc(*Table, m.tables.len),
            .mems = try a.alloc(*Memory, m.mems.len),
            .globals = try a.alloc(*Global, m.globals.len),
            .elems = try a.alloc([]const u64, m.elems.len),
            .datas = try a.alloc([]const u8, m.datas.len),
            .own_tables = try a.alloc(*Table, m.tables.len - m.import_tables),
            .own_mems = try a.alloc(*Memory, m.mems.len - m.import_mems),
            .own_globals = try a.alloc(*Global, m.globals.len - m.import_globals),
        };
        for (inst.elems) |*e| e.* = &.{};
        try s.instances.append(a, inst);
        var made_tables: usize = 0;
        var made_mems: usize = 0;
        var made_globals: usize = 0;
        // After the first segment, a function of the instance can be in a
        // table of another instance, so the instance stays alive.
        var segments = false;
        errdefer if (!segments) {
            inst.own_tables = inst.own_tables[0..made_tables];
            inst.own_mems = inst.own_mems[0..made_mems];
            inst.own_globals = inst.own_globals[0..made_globals];
            inst.dead = true;
            s.collect(inst);
        };
        // The instances of the imports.
        var deps: std.ArrayList(*Instance) = .empty;
        defer deps.deinit(a);
        var fi: usize = 0;
        var ti: usize = 0;
        var mi: usize = 0;
        var gi: usize = 0;
        for (imports) |e| switch (e) {
            .func => |f| {
                inst.funcs[fi] = f;
                fi += 1;
                if (s.funcs.items[f].kind == .wasm) {
                    const d = s.funcs.items[f].kind.wasm.inst;
                    if (std.mem.indexOfScalar(*Instance, deps.items, d) == null) try deps.append(a, d);
                }
            },
            .table => |t| {
                inst.tables[ti] = t;
                ti += 1;
            },
            .mem => |x| {
                inst.mems[mi] = x;
                mi += 1;
            },
            .global => |g| {
                inst.globals[gi] = g;
                gi += 1;
            },
        };
        // Owners of imported tables, memories, and globals.
        for (imports) |e| {
            const owner: ?*Instance = switch (e) {
                .func => null,
                .table => |t| s.ownerOf(.table, t),
                .mem => |x| s.ownerOf(.mem, x),
                .global => |g| s.ownerOf(.global, g),
            };
            if (owner) |d| if (std.mem.indexOfScalar(*Instance, deps.items, d) == null) try deps.append(a, d);
        }
        inst.deps = try deps.toOwnedSlice(a);
        for (inst.deps) |d| d.users += 1;

        for (m.funcs, 0..) |*f, i| {
            try s.funcs.append(a, .{ .type = m.types[f.type], .kind = .{ .wasm = .{ .inst = inst, .func = f } } });
            inst.funcs[fi + i] = @intCast(s.funcs.items.len - 1);
        }
        for (m.tables[m.import_tables..], 0..) |t, i| {
            const tab = try a.create(Table);
            tab.* = .{ .elem = t.elem, .max = t.limits.max };
            inst.own_tables[i] = tab;
            made_tables += 1;
            if (t.limits.min > mod.max_table) return error.OutOfMemory;
            try tab.refs.appendNTimes(a, 0, @intCast(t.limits.min));
            inst.tables[ti + i] = tab;
        }
        for (m.mems[m.import_mems..], 0..) |l, i| {
            const mem = try a.create(Memory);
            mem.* = .{ .max = l.max orelse mod.max_pages };
            inst.own_mems[i] = mem;
            made_mems += 1;
            if (l.min > 0) {
                const bytes: usize = @intCast(l.min * page);
                if (!s.fits(bytes)) return error.OutOfMemory;
                mem.bytes = try a.alloc(u8, bytes);
                @memset(mem.bytes, 0);
            }
            inst.mems[mi + i] = mem;
        }
        for (m.global_inits, 0..) |gexpr, i| {
            const g = try a.create(Global);
            g.* = .{ .type = m.globals[gi + i], .val = s.evalConst(inst, gexpr) };
            inst.own_globals[i] = g;
            made_globals += 1;
            inst.globals[gi + i] = g;
        }
        for (m.elems, 0..) |e, i| {
            const refs = try a.alloc(u64, e.init.len);
            for (e.init, refs) |x, *r| r.* = s.evalConst(inst, x);
            inst.elems[i] = refs;
        }
        for (m.datas, 0..) |d, i| inst.datas[i] = d.bytes;
        // The active segments, in order.
        segments = true;
        for (m.elems, 0..) |e, i| switch (e.mode) {
            .active => |act| {
                const off: u32 = @truncate(s.evalConst(inst, act.offset));
                try tableInit(s, inst, act.table, @intCast(i), off, 0, @intCast(inst.elems[i].len));
                s.dropElem(inst, @intCast(i));
            },
            .declarative => s.dropElem(inst, @intCast(i)),
            .passive => {},
        };
        for (m.datas, 0..) |d, i| switch (d.mode) {
            .active => |act| {
                const off: u32 = @truncate(s.evalConst(inst, act.offset));
                try memoryInit(inst, @intCast(i), off, 0, @intCast(d.bytes.len));
                inst.datas[i] = &.{};
            },
            .passive => {},
        };
        if (m.start) |st| try s.invoke(inst.funcs[st], &.{}, &.{});
        return inst;
    }

    fn ownerOf(s: *Store, comptime kind: mod.ExternKind, p: anytype) ?*Instance {
        for (s.instances.items) |inst| {
            const list = switch (kind) {
                .table => inst.own_tables,
                .mem => inst.own_mems,
                .global => inst.own_globals,
                .func => unreachable,
            };
            for (list) |x| if (x == p) return inst;
        }
        return null;
    }

    fn dropElem(s: *Store, inst: *Instance, i: u32) void {
        s.gpa.free(inst.elems[i]);
        inst.elems[i] = &.{};
    }

    pub fn evalConst(s: *Store, inst: *const Instance, e: mod.ConstExpr) u64 {
        _ = s;
        switch (e) {
            .func => |f| return @as(u64, inst.funcs[f]) + 1,
            .code => |code| {
                var stack: [64]u64 = undefined;
                var n: usize = 0;
                var r: mod.ConstReader = .{ .bytes = code };
                while (r.next()) |x| {
                    switch (x.op) {
                        0x0b => break,
                        0x41, 0x42, 0x43, 0x44 => {
                            stack[n] = x.imm;
                            n += 1;
                        },
                        0xd0 => {
                            stack[n] = 0;
                            n += 1;
                        },
                        0xd2 => {
                            stack[n] = @as(u64, inst.funcs[@intCast(x.imm)]) + 1;
                            n += 1;
                        },
                        0x23 => {
                            stack[n] = inst.globals[@intCast(x.imm)].val;
                            n += 1;
                        },
                        0x6a, 0x6b, 0x6c => {
                            const b: u32 = @truncate(stack[n - 1]);
                            const av: u32 = @truncate(stack[n - 2]);
                            n -= 1;
                            stack[n - 1] = switch (x.op) {
                                0x6a => av +% b,
                                0x6b => av -% b,
                                else => av *% b,
                            };
                        },
                        0x7c, 0x7d, 0x7e => {
                            const b = stack[n - 1];
                            const av = stack[n - 2];
                            n -= 1;
                            stack[n - 1] = switch (x.op) {
                                0x7c => av +% b,
                                0x7d => av -% b,
                                else => av *% b,
                            };
                        },
                        else => unreachable,
                    }
                }
                return stack[0];
            },
        }
    }

    // ---- Calls ----

    /// Calls the function at `addr` with `args`, and writes `results`.
    pub fn invoke(s: *Store, addr: u32, args: []const u64, results: []u64) Error!void {
        const f = &s.funcs.items[addr];
        std.debug.assert(args.len == f.type.params.len and results.len == f.type.results.len);
        switch (f.kind) {
            .host => |h| return h.call(h.ctx, s, args, results),
            .wasm => {},
        }
        if (s.nest >= s.max_nest) return error.StackExhausted;
        s.nest += 1;
        defer s.nest -= 1;
        const sp0 = s.sp;
        const frames0 = s.frames.items.len;
        defer {
            s.sp = sp0;
            s.frames.items.len = frames0;
        }
        try s.ensureStack(s.sp + args.len + 1);
        @memcpy(s.stack[s.sp .. s.sp + args.len], args);
        s.sp += args.len;
        try run(s, addr);
        @memcpy(results, s.stack[s.sp - results.len .. s.sp]);
    }
};

fn memHasMax(m: *const Memory) bool {
    _ = m;
    return true;
}

fn limitsMatch(size: u64, max: ?u64, want: mod.Limits) bool {
    if (size < want.min) return false;
    if (want.max) |wm| {
        const gm = max orelse return false;
        if (gm > wm) return false;
    }
    return true;
}

fn tableInit(s: *Store, inst: *Instance, table: u32, elem: u32, d: u32, src: u32, n: u32) Error!void {
    const t = inst.tables[table];
    const e = inst.elems[elem];
    if (@as(u64, src) + n > e.len or @as(u64, d) + n > t.refs.items.len) return error.OutOfBoundsTable;
    try s.bulk(n);
    @memcpy(t.refs.items[d .. d + n], e[src .. src + n]);
}

fn memoryInit(inst: *Instance, data: u32, d: u32, src: u32, n: u32) Error!void {
    const m = inst.mems[0];
    const bytes = inst.datas[data];
    if (@as(u64, src) + n > bytes.len or @as(u64, d) + n > m.bytes.len) return error.OutOfBoundsMemory;
    @memcpy(m.bytes[d .. d + n], bytes[src .. src + n]);
}

// ---- Numbers ----

inline fn f32of(x: u64) f32 {
    return @bitCast(@as(u32, @truncate(x)));
}
inline fn f64of(x: u64) f64 {
    return @bitCast(x);
}
inline fn bits32(x: f32) u64 {
    return @as(u32, @bitCast(x));
}
inline fn bits64(x: f64) u64 {
    return @bitCast(x);
}
inline fn u32of(x: u64) u32 {
    return @truncate(x);
}
inline fn i32of(x: u64) i32 {
    return @bitCast(@as(u32, @truncate(x)));
}
inline fn i64of(x: u64) i64 {
    return @bitCast(x);
}
inline fn ofI32(x: i32) u64 {
    return @as(u32, @bitCast(x));
}
inline fn ofI64(x: i64) u64 {
    return @bitCast(x);
}
inline fn ofBool(b: bool) u64 {
    return @intFromBool(b);
}

fn Bits(comptime T: type) type {
    return if (T == f32) u32 else u64;
}

fn fmin(comptime T: type, x: T, y: T) T {
    if (std.math.isNan(x) or std.math.isNan(y)) return std.math.nan(T);
    if (x == y) return @bitCast(@as(Bits(T), @bitCast(x)) | @as(Bits(T), @bitCast(y)));
    return if (x < y) x else y;
}

fn fmax(comptime T: type, x: T, y: T) T {
    if (std.math.isNan(x) or std.math.isNan(y)) return std.math.nan(T);
    if (x == y) return @bitCast(@as(Bits(T), @bitCast(x)) & @as(Bits(T), @bitCast(y)));
    return if (x > y) x else y;
}

/// Rounds to the nearest integer, with ties to even.
fn nearest(comptime T: type, x: T) T {
    if (std.math.isNan(x)) return x + x;
    if (std.math.isInf(x)) return x;
    const r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5) {
        const h = @round(x / 2) * 2;
        return std.math.copysign(h, x);
    }
    return std.math.copysign(r, x);
}

fn copysign(comptime T: type, x: T, y: T) T {
    const B = Bits(T);
    const sign: B = @as(B, 1) << (@bitSizeOf(B) - 1);
    return @bitCast((@as(B, @bitCast(x)) & ~sign) | (@as(B, @bitCast(y)) & sign));
}

fn fabs(comptime T: type, x: T) T {
    const B = Bits(T);
    const sign: B = @as(B, 1) << (@bitSizeOf(B) - 1);
    return @bitCast(@as(B, @bitCast(x)) & ~sign);
}

fn fneg(comptime T: type, x: T) T {
    const B = Bits(T);
    const sign: B = @as(B, 1) << (@bitSizeOf(B) - 1);
    return @bitCast(@as(B, @bitCast(x)) ^ sign);
}

fn truncLimits(comptime F: type, comptime I: type) [2]F {
    const n = @bitSizeOf(I);
    const signed = @typeInfo(I).int.signedness == .signed;
    const hi: F = @floatFromInt(@as(u128, 1) << (if (signed) n - 1 else n));
    return .{ if (signed) -hi else 0, hi };
}

fn truncTrap(comptime I: type, x: anytype) Trap!I {
    const F = @TypeOf(x);
    if (std.math.isNan(x)) return error.InvalidConversion;
    const t = @trunc(x);
    const lim = comptime truncLimits(F, I);
    if (!(t >= lim[0] and t < lim[1])) return error.IntOverflow;
    return @intFromFloat(t);
}

fn truncSat(comptime I: type, x: anytype) I {
    const F = @TypeOf(x);
    if (std.math.isNan(x)) return 0;
    const t = @trunc(x);
    const lim = comptime truncLimits(F, I);
    if (t < lim[0]) return std.math.minInt(I);
    if (t >= lim[1]) return std.math.maxInt(I);
    return @intFromFloat(t);
}

fn divS(comptime T: type, x: T, y: T) Trap!T {
    if (y == 0) return error.DivByZero;
    if (x == std.math.minInt(T) and y == -1) return error.IntOverflow;
    return @divTrunc(x, y);
}

fn remS(comptime T: type, x: T, y: T) Trap!T {
    if (y == 0) return error.DivByZero;
    if (y == -1) return 0;
    return @rem(x, y);
}

fn intOp32(comptime o: u16, x: u32, y: u32) Trap!u32 {
    const sx: i32 = @bitCast(x);
    const sy: i32 = @bitCast(y);
    return switch (o) {
        0x6a => x +% y,
        0x6b => x -% y,
        0x6c => x *% y,
        0x6d => @bitCast(try divS(i32, sx, sy)),
        0x6e => if (y == 0) error.DivByZero else x / y,
        0x6f => @bitCast(try remS(i32, sx, sy)),
        0x70 => if (y == 0) error.DivByZero else x % y,
        0x71 => x & y,
        0x72 => x | y,
        0x73 => x ^ y,
        0x74 => x << @truncate(y),
        0x75 => @bitCast(sx >> @truncate(y)),
        0x76 => x >> @truncate(y),
        0x77 => std.math.rotl(u32, x, y),
        0x78 => std.math.rotr(u32, x, y),
        else => unreachable,
    };
}

fn intOp64(comptime o: u16, x: u64, y: u64) Trap!u64 {
    const sx: i64 = @bitCast(x);
    const sy: i64 = @bitCast(y);
    return switch (o) {
        0x7c => x +% y,
        0x7d => x -% y,
        0x7e => x *% y,
        0x7f => @bitCast(try divS(i64, sx, sy)),
        0x80 => if (y == 0) error.DivByZero else x / y,
        0x81 => @bitCast(try remS(i64, sx, sy)),
        0x82 => if (y == 0) error.DivByZero else x % y,
        0x83 => x & y,
        0x84 => x | y,
        0x85 => x ^ y,
        0x86 => x << @truncate(y),
        0x87 => @bitCast(sx >> @truncate(y)),
        0x88 => x >> @truncate(y),
        0x89 => std.math.rotl(u64, x, y),
        0x8a => std.math.rotr(u64, x, y),
        else => unreachable,
    };
}

fn cmp32(comptime o: u16, x: u32, y: u32) bool {
    const sx: i32 = @bitCast(x);
    const sy: i32 = @bitCast(y);
    return switch (o) {
        0x46 => x == y,
        0x47 => x != y,
        0x48 => sx < sy,
        0x49 => x < y,
        0x4a => sx > sy,
        0x4b => x > y,
        0x4c => sx <= sy,
        0x4d => x <= y,
        0x4e => sx >= sy,
        0x4f => x >= y,
        else => unreachable,
    };
}

fn cmp64(comptime o: u16, x: u64, y: u64) bool {
    const sx: i64 = @bitCast(x);
    const sy: i64 = @bitCast(y);
    return switch (o) {
        0x51 => x == y,
        0x52 => x != y,
        0x53 => sx < sy,
        0x54 => x < y,
        0x55 => sx > sy,
        0x56 => x > y,
        0x57 => sx <= sy,
        0x58 => x <= y,
        0x59 => sx >= sy,
        0x5a => x >= y,
        else => unreachable,
    };
}

fn fcmp(comptime T: type, comptime k: u16, x: T, y: T) bool {
    return switch (k) {
        0 => x == y,
        1 => x != y,
        2 => x < y,
        3 => x > y,
        4 => x <= y,
        5 => x >= y,
        else => unreachable,
    };
}

fn funary(comptime T: type, comptime k: u16, x: T) T {
    return switch (k) {
        0 => fabs(T, x),
        1 => fneg(T, x),
        2 => @ceil(x),
        3 => @floor(x),
        4 => @trunc(x),
        5 => nearest(T, x),
        6 => @sqrt(x),
        else => unreachable,
    };
}

fn fbinary(comptime T: type, comptime k: u16, x: T, y: T) T {
    return switch (k) {
        0 => x + y,
        1 => x - y,
        2 => x * y,
        3 => x / y,
        4 => fmin(T, x, y),
        5 => fmax(T, x, y),
        6 => copysign(T, x, y),
        else => unreachable,
    };
}

/// The conversions 0xA7 to 0xC4 and the saturating truncations.
fn convert(comptime o: u16, x: u64) Trap!u64 {
    return switch (o) {
        0xa7 => @as(u32, @truncate(x)),
        0xa8 => ofI32(try truncTrap(i32, f32of(x))),
        0xa9 => @as(u32, try truncTrap(u32, f32of(x))),
        0xaa => ofI32(try truncTrap(i32, f64of(x))),
        0xab => @as(u32, try truncTrap(u32, f64of(x))),
        0xac => ofI64(i32of(x)),
        0xad => @as(u32, @truncate(x)),
        0xae => ofI64(try truncTrap(i64, f32of(x))),
        0xaf => try truncTrap(u64, f32of(x)),
        0xb0 => ofI64(try truncTrap(i64, f64of(x))),
        0xb1 => try truncTrap(u64, f64of(x)),
        0xb2 => bits32(@floatFromInt(i32of(x))),
        0xb3 => bits32(@floatFromInt(u32of(x))),
        0xb4 => bits32(@floatFromInt(i64of(x))),
        0xb5 => bits32(@floatFromInt(x)),
        0xb6 => bits32(@floatCast(f64of(x))),
        0xb7 => bits64(@floatFromInt(i32of(x))),
        0xb8 => bits64(@floatFromInt(u32of(x))),
        0xb9 => bits64(@floatFromInt(i64of(x))),
        0xba => bits64(@floatFromInt(x)),
        0xbb => bits64(@floatCast(f32of(x))),
        0xbc, 0xbe => x & 0xffff_ffff,
        0xbd, 0xbf => x,
        0xc0 => ofI32(@as(i8, @truncate(@as(i32, i32of(x))))),
        0xc1 => ofI32(@as(i16, @truncate(@as(i32, i32of(x))))),
        0xc2 => ofI64(@as(i8, @truncate(i64of(x)))),
        0xc3 => ofI64(@as(i16, @truncate(i64of(x)))),
        0xc4 => ofI64(@as(i32, @truncate(i64of(x)))),
        op.fc + 0 => ofI32(truncSat(i32, f32of(x))),
        op.fc + 1 => @as(u32, truncSat(u32, f32of(x))),
        op.fc + 2 => ofI32(truncSat(i32, f64of(x))),
        op.fc + 3 => @as(u32, truncSat(u32, f64of(x))),
        op.fc + 4 => ofI64(truncSat(i64, f32of(x))),
        op.fc + 5 => truncSat(u64, f32of(x)),
        op.fc + 6 => ofI64(truncSat(i64, f64of(x))),
        op.fc + 7 => truncSat(u64, f64of(x)),
        else => unreachable,
    };
}

inline fn effAddr(m: *const Memory, base: u64, off: u32, comptime n: usize) Trap![*]u8 {
    const ea = (base & 0xffff_ffff) + off;
    if (ea + n > m.bytes.len) return error.OutOfBoundsMemory;
    return m.bytes.ptr + @as(usize, @intCast(ea));
}

fn load(comptime o: u16, m: *const Memory, base: u64, off: u32) Trap!u64 {
    const n: usize = switch (o) {
        0x28, 0x2a, 0x34, 0x35 => 4,
        0x29, 0x2b => 8,
        0x2c, 0x2d, 0x30, 0x31 => 1,
        0x2e, 0x2f, 0x32, 0x33 => 2,
        else => unreachable,
    };
    const p = try effAddr(m, base, off, n);
    return switch (o) {
        0x28, 0x2a, 0x35 => std.mem.readInt(u32, p[0..4], .little),
        0x29, 0x2b => std.mem.readInt(u64, p[0..8], .little),
        0x2c => ofI32(@as(i8, @bitCast(p[0]))),
        0x2d, 0x31 => p[0],
        0x2e => ofI32(std.mem.readInt(i16, p[0..2], .little)),
        0x2f, 0x33 => std.mem.readInt(u16, p[0..2], .little),
        0x30 => ofI64(@as(i8, @bitCast(p[0]))),
        0x32 => ofI64(std.mem.readInt(i16, p[0..2], .little)),
        0x34 => ofI64(std.mem.readInt(i32, p[0..4], .little)),
        else => unreachable,
    };
}

fn store(comptime o: u16, m: *Memory, base: u64, off: u32, v: u64) Trap!void {
    switch (o) {
        0x36, 0x38, 0x3e => std.mem.writeInt(u32, (try effAddr(m, base, off, 4))[0..4], @truncate(v), .little),
        0x37, 0x39 => std.mem.writeInt(u64, (try effAddr(m, base, off, 8))[0..8], v, .little),
        0x3a, 0x3c => (try effAddr(m, base, off, 1))[0] = @truncate(v),
        0x3b, 0x3d => std.mem.writeInt(u16, (try effAddr(m, base, off, 2))[0..2], @truncate(v), .little),
        else => unreachable,
    }
}

// ---- The interpreter ----

/// The JIT code of a module: compiled at the first call, or null when the
/// JIT cannot compile it.
fn jitCode(m: *const Module) Error!?*const jit.Code {
    const mm = @constCast(m);
    if (mm.jit) |c| return @ptrCast(@alignCast(c));
    if (mm.jit_failed) return null;
    jit.lock();
    defer jit.unlock();
    const c = jit.compile(mm.arena.child_allocator, m) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            mm.jit_failed = true;
            return null;
        },
    } orelse {
        mm.jit_failed = true;
        return null;
    };
    mm.jit = c;
    return c;
}

/// Runs the wasm function `addr`. Its arguments are on top of the stack.
/// At the end its results are on top of the stack.
fn run(s: *Store, addr: u32) Error!void {
    const base_frames = s.frames.items.len;
    var func: *const mod.Func = undefined;
    var inst: *Instance = undefined;
    var st: [*]u64 = undefined;
    var fp: usize = 0;
    var sp: usize = s.sp;
    var code: [*]const Ins = undefined;
    var pc: usize = 0;

    // Enters the first function.
    {
        const fi = &s.funcs.items[addr];
        const w = fi.kind.wasm;
        if (w.inst.dead) return error.InstanceDeleted;
        if (jit.supported and s.jit_on) {
            if (try jitCode(w.inst.module)) |c| {
                const idx = (@intFromPtr(w.func) - @intFromPtr(w.inst.module.funcs.ptr)) / @sizeOf(mod.Func);
                return jit.run(s, c, w.inst, idx);
            }
        }
        try s.tick();
        func = w.func;
        inst = w.inst;
        fp = sp - func.nparams;
        try s.ensureStack(fp + func.max_height);
        st = s.stack.ptr;
        @memset(st[fp + func.nparams .. fp + func.nlocals], 0);
        sp = fp + func.nlocals;
        code = func.code.ptr;
        pc = 0;
    }

    while (true) {
        const ins = code[pc];
        pc += 1;
        switch (ins.op) {
            0x00 => return error.Unreachable,
            op.tick => try s.tick(),
            op.br => {
                const arity: usize = @intCast(ins.b >> 32);
                const dst = fp + @as(u32, @truncate(ins.b));
                if (dst != sp - arity) std.mem.copyForwards(u64, st[dst .. dst + arity], st[sp - arity .. sp]);
                sp = dst + arity;
                pc = ins.a;
            },
            op.br_if => {
                sp -= 1;
                if (u32of(st[sp]) != 0) {
                    const arity: usize = @intCast(ins.b >> 32);
                    const dst = fp + @as(u32, @truncate(ins.b));
                    if (dst != sp - arity) std.mem.copyForwards(u64, st[dst .. dst + arity], st[sp - arity .. sp]);
                    sp = dst + arity;
                    pc = ins.a;
                }
            },
            op.br_table => {
                sp -= 1;
                const i = u32of(st[sp]);
                const n: u32 = @intCast(ins.b);
                const t = func.targets[ins.a + @min(i, n - 1)];
                const dst = fp + t.height;
                if (dst != sp - t.arity) std.mem.copyForwards(u64, st[dst .. dst + t.arity], st[sp - t.arity .. sp]);
                sp = dst + t.arity;
                pc = t.pc;
            },
            op.jz => {
                sp -= 1;
                if (u32of(st[sp]) == 0) pc = ins.a;
            },
            op.jmp => pc = ins.a,
            op.ret => {
                const n = func.nresults;
                if (fp != sp - n) std.mem.copyForwards(u64, st[fp .. fp + n], st[sp - n .. sp]);
                sp = fp + n;
                if (s.frames.items.len == base_frames) {
                    s.sp = sp;
                    return;
                }
                const f = s.frames.pop().?;
                func = f.func;
                inst = f.inst;
                fp = f.fp;
                code = func.code.ptr;
                pc = f.pc;
            },
            0x10, 0x11 => {
                var callee: u32 = undefined;
                if (ins.op == 0x10) {
                    callee = inst.funcs[ins.a];
                } else {
                    sp -= 1;
                    const i = u32of(st[sp]);
                    const tab = inst.tables[@intCast(ins.b)];
                    if (i >= tab.refs.items.len) return error.UndefinedElement;
                    const r = tab.refs.items[i];
                    if (r == 0) return error.UninitializedElement;
                    callee = @intCast(r - 1);
                    if (!s.funcs.items[callee].type.eql(inst.module.types[ins.a])) return error.IndirectCallMismatch;
                }
                const fi = &s.funcs.items[callee];
                switch (fi.kind) {
                    .host => |h| {
                        const np = fi.type.params.len;
                        const nr = fi.type.results.len;
                        var abuf: [16]u64 = undefined;
                        var rbuf: [16]u64 = undefined;
                        const args = if (np <= 16) abuf[0..np] else try s.gpa.alloc(u64, np);
                        defer if (np > 16) s.gpa.free(args);
                        const res = if (nr <= 16) rbuf[0..nr] else try s.gpa.alloc(u64, nr);
                        defer if (nr > 16) s.gpa.free(res);
                        @memcpy(args, st[sp - np .. sp]);
                        sp -= np;
                        s.sp = sp;
                        try s.tick();
                        try s.frames.append(s.gpa, .{ .func = func, .pc = @intCast(pc), .fp = fp, .inst = inst });
                        h.call(h.ctx, s, args, res) catch |e| return e;
                        _ = s.frames.pop();
                        try s.ensureStack(sp + nr);
                        st = s.stack.ptr;
                        @memcpy(st[sp .. sp + nr], res);
                        sp += nr;
                    },
                    .wasm => |w| {
                        if (w.inst.dead) return error.InstanceDeleted;
                        try s.tick();
                        if (s.frames.items.len - base_frames >= s.max_frames) return error.StackExhausted;
                        try s.frames.append(s.gpa, .{ .func = func, .pc = @intCast(pc), .fp = fp, .inst = inst });
                        func = w.func;
                        inst = w.inst;
                        fp = sp - func.nparams;
                        try s.ensureStack(fp + func.max_height);
                        st = s.stack.ptr;
                        @memset(st[fp + func.nparams .. fp + func.nlocals], 0);
                        sp = fp + func.nlocals;
                        code = func.code.ptr;
                        pc = 0;
                    },
                }
            },
            else => sp = try simple(s, inst, st, fp, sp, ins),
        }
    }
}

/// The instructions with no control flow: each one changes the values at
/// the top of the stack `st[fp..sp]` and gives the new `sp`. The
/// interpreter inlines it, and the JIT calls `simpleOp` for the
/// instructions that it does not compile itself, so both run one code.
pub inline fn simple(s: *Store, inst: *Instance, st: [*]u64, fp: usize, sp_in: usize, ins: Ins) Error!usize {
    var sp = sp_in;
    switch (ins.op) {
        0x1a => sp -= 1,
        0x1b => {
            sp -= 2;
            if (u32of(st[sp + 1]) == 0) st[sp - 1] = st[sp];
        },
        0x20 => {
            st[sp] = st[fp + ins.a];
            sp += 1;
        },
        0x21 => {
            sp -= 1;
            st[fp + ins.a] = st[sp];
        },
        0x22 => st[fp + ins.a] = st[sp - 1],
        0x23 => {
            st[sp] = inst.globals[ins.a].val;
            sp += 1;
        },
        0x24 => {
            sp -= 1;
            inst.globals[ins.a].val = st[sp];
        },
        0x25 => {
            const t = inst.tables[ins.a];
            const i = u32of(st[sp - 1]);
            if (i >= t.refs.items.len) return error.OutOfBoundsTable;
            st[sp - 1] = t.refs.items[i];
        },
        0x26 => {
            sp -= 2;
            const t = inst.tables[ins.a];
            const i = u32of(st[sp]);
            if (i >= t.refs.items.len) return error.OutOfBoundsTable;
            t.refs.items[i] = st[sp + 1];
        },
        inline 0x28...0x35 => |o| st[sp - 1] = try load(o, inst.mems[0], st[sp - 1], ins.a),
        inline 0x36...0x3e => |o| {
            sp -= 2;
            try store(o, inst.mems[0], st[sp], ins.a, st[sp + 1]);
        },
        0x3f => {
            st[sp] = inst.mems[0].pages();
            sp += 1;
        },
        0x40 => {
            const d = u32of(st[sp - 1]);
            st[sp - 1] = if (s.growMemory(inst.mems[0], d)) |old| old else 0xffff_ffff;
        },
        0x41, 0x42, 0x43, 0x44 => {
            st[sp] = ins.b;
            sp += 1;
        },
        0x45 => st[sp - 1] = ofBool(u32of(st[sp - 1]) == 0),
        inline 0x46...0x4f => |o| {
            sp -= 1;
            st[sp - 1] = ofBool(cmp32(o, u32of(st[sp - 1]), u32of(st[sp])));
        },
        0x50 => st[sp - 1] = ofBool(st[sp - 1] == 0),
        inline 0x51...0x5a => |o| {
            sp -= 1;
            st[sp - 1] = ofBool(cmp64(o, st[sp - 1], st[sp]));
        },
        inline 0x5b...0x60 => |o| {
            sp -= 1;
            st[sp - 1] = ofBool(fcmp(f32, o - 0x5b, f32of(st[sp - 1]), f32of(st[sp])));
        },
        inline 0x61...0x66 => |o| {
            sp -= 1;
            st[sp - 1] = ofBool(fcmp(f64, o - 0x61, f64of(st[sp - 1]), f64of(st[sp])));
        },
        0x67 => st[sp - 1] = @clz(u32of(st[sp - 1])),
        0x68 => st[sp - 1] = @ctz(u32of(st[sp - 1])),
        0x69 => st[sp - 1] = @popCount(u32of(st[sp - 1])),
        inline 0x6a...0x78 => |o| {
            sp -= 1;
            st[sp - 1] = try intOp32(o, u32of(st[sp - 1]), u32of(st[sp]));
        },
        0x79 => st[sp - 1] = @clz(st[sp - 1]),
        0x7a => st[sp - 1] = @ctz(st[sp - 1]),
        0x7b => st[sp - 1] = @popCount(st[sp - 1]),
        inline 0x7c...0x8a => |o| {
            sp -= 1;
            st[sp - 1] = try intOp64(o, st[sp - 1], st[sp]);
        },
        inline 0x8b...0x91 => |o| st[sp - 1] = bits32(funary(f32, o - 0x8b, f32of(st[sp - 1]))),
        inline 0x92...0x98 => |o| {
            sp -= 1;
            st[sp - 1] = bits32(fbinary(f32, o - 0x92, f32of(st[sp - 1]), f32of(st[sp])));
        },
        inline 0x99...0x9f => |o| st[sp - 1] = bits64(funary(f64, o - 0x99, f64of(st[sp - 1]))),
        inline 0xa0...0xa6 => |o| {
            sp -= 1;
            st[sp - 1] = bits64(fbinary(f64, o - 0xa0, f64of(st[sp - 1]), f64of(st[sp])));
        },
        inline 0xa7...0xc4, op.fc + 0...op.fc + 7 => |o| st[sp - 1] = try convert(o, st[sp - 1]),
        0xd0 => {
            st[sp] = 0;
            sp += 1;
        },
        0xd1 => st[sp - 1] = ofBool(st[sp - 1] == 0),
        0xd2 => {
            st[sp] = @as(u64, inst.funcs[ins.a]) + 1;
            sp += 1;
        },
        op.fc + 8 => {
            sp -= 3;
            try memoryInit(inst, ins.a, u32of(st[sp]), u32of(st[sp + 1]), u32of(st[sp + 2]));
            try s.bulk(u32of(st[sp + 2]));
        },
        op.fc + 9 => inst.datas[ins.a] = &.{},
        op.fc + 10 => {
            sp -= 3;
            const m = inst.mems[0];
            const d = u32of(st[sp]);
            const src = u32of(st[sp + 1]);
            const n = u32of(st[sp + 2]);
            if (@as(u64, src) + n > m.bytes.len or @as(u64, d) + n > m.bytes.len) return error.OutOfBoundsMemory;
            try s.bulk(n);
            if (d <= src) std.mem.copyForwards(u8, m.bytes[d .. d + n], m.bytes[src .. src + n]) else std.mem.copyBackwards(u8, m.bytes[d .. d + n], m.bytes[src .. src + n]);
        },
        op.fc + 11 => {
            sp -= 3;
            const m = inst.mems[0];
            const d = u32of(st[sp]);
            const v: u8 = @truncate(st[sp + 1]);
            const n = u32of(st[sp + 2]);
            if (@as(u64, d) + n > m.bytes.len) return error.OutOfBoundsMemory;
            try s.bulk(n);
            @memset(m.bytes[d .. d + n], v);
        },
        op.fc + 12 => {
            sp -= 3;
            try tableInit(s, inst, @intCast(ins.b), ins.a, u32of(st[sp]), u32of(st[sp + 1]), u32of(st[sp + 2]));
        },
        op.fc + 13 => s.dropElem(inst, ins.a),
        op.fc + 14 => {
            sp -= 3;
            const td = inst.tables[ins.a];
            const ts = inst.tables[@intCast(ins.b)];
            const d = u32of(st[sp]);
            const src = u32of(st[sp + 1]);
            const n = u32of(st[sp + 2]);
            if (@as(u64, src) + n > ts.refs.items.len or @as(u64, d) + n > td.refs.items.len) return error.OutOfBoundsTable;
            try s.bulk(n);
            if (d <= src) std.mem.copyForwards(u64, td.refs.items[d .. d + n], ts.refs.items[src .. src + n]) else std.mem.copyBackwards(u64, td.refs.items[d .. d + n], ts.refs.items[src .. src + n]);
        },
        op.fc + 15 => {
            sp -= 1;
            const n = u32of(st[sp]);
            const t = inst.tables[ins.a];
            st[sp - 1] = if (s.growTable(t, n, st[sp - 1])) |old| old else 0xffff_ffff;
        },
        op.fc + 16 => {
            st[sp] = inst.tables[ins.a].refs.items.len;
            sp += 1;
        },
        op.fc + 17 => {
            sp -= 3;
            const t = inst.tables[ins.a];
            const d = u32of(st[sp]);
            const n = u32of(st[sp + 2]);
            if (@as(u64, d) + n > t.refs.items.len) return error.OutOfBoundsTable;
            try s.bulk(n);
            @memset(t.refs.items[d .. d + n], st[sp + 1]);
        },
        else => unreachable,
    }
    return sp;
}

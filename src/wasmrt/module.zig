//! The decoder and the validator of the WebAssembly binary format.
//!
//! `decode` reads the sections of a module in the order of the
//! specification (core 2.0 with the bulk memory, sign extension,
//! multi-value, reference type, and extended constant features). It
//! checks each LEB128 number, each name, and each section size. The
//! code of each function goes through the validation algorithm of the
//! appendix of the specification: a stack of operand types and a stack
//! of control frames. The same pass writes the internal code of the
//! function for `exec.zig`.
//!
//! The internal code is an array of `Ins`. A numeric instruction keeps
//! its opcode (an opcode after the prefix 0xFC is 0x100 plus the second
//! opcode). `block`, `loop`, and `end` give no instruction. A branch
//! has the index of its target instruction and the height of the target
//! label, so the interpreter moves the values of the branch with no
//! search. The height of a frame counts the locals first: a slot index
//! is the index of a local or of an operand, from the start of the frame.
//! A `loop` gives a `tick` instruction: each pass of a loop and each call
//! uses one compute unit.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ValType = enum(u8) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
    v128 = 0x7b,
    funcref = 0x70,
    externref = 0x6f,
    _,

    pub fn isRef(t: ValType) bool {
        return t == .funcref or t == .externref;
    }

    pub fn name(t: ValType) []const u8 {
        return switch (t) {
            .i32 => "i32",
            .i64 => "i64",
            .f32 => "f32",
            .f64 => "f64",
            .v128 => "v128",
            .funcref => "funcref",
            .externref => "externref",
            _ => "unknown",
        };
    }
};

/// The type of an operand during validation: a value type or 0 for the
/// unknown type of unreachable code.
const Unknown: u8 = 0;

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,

    pub fn eql(x: FuncType, y: FuncType) bool {
        return std.mem.eql(ValType, x.params, y.params) and std.mem.eql(ValType, x.results, y.results);
    }
};

pub const Limits = struct { min: u64, max: ?u64 };
pub const TableType = struct { elem: ValType, limits: Limits };
pub const GlobalType = struct { val: ValType, mutable: bool };

pub const ExternKind = enum(u8) { func = 0, table = 1, mem = 2, global = 3 };

pub const ImportDesc = union(ExternKind) {
    func: u32,
    table: TableType,
    mem: Limits,
    global: GlobalType,
};

pub const Import = struct { module: []const u8, name: []const u8, desc: ImportDesc };
pub const Export = struct { name: []const u8, kind: ExternKind, index: u32 };

/// A constant expression: its bytes up to and with the final `end`,
/// or the reference of a function index in an element segment.
pub const ConstExpr = union(enum) {
    code: []const u8,
    func: u32,
};

pub const Global = struct { type: GlobalType, init: ConstExpr };

pub const ElemMode = union(enum) {
    passive,
    declarative,
    active: struct { table: u32, offset: ConstExpr },
};

pub const Elem = struct { type: ValType, mode: ElemMode, init: []const ConstExpr };

pub const DataMode = union(enum) {
    passive,
    active: struct { mem: u32, offset: ConstExpr },
};

pub const Data = struct { mode: DataMode, bytes: []const u8 };

/// One instruction of the internal code.
pub const Ins = struct {
    op: u16,
    a: u32 = 0,
    b: u64 = 0,
};

/// The target of an entry of `br_table`.
pub const Target = struct { pc: u32, arity: u32, height: u32 };

pub const Func = struct {
    type: u32,
    /// The count of the params and the declared locals.
    nlocals: u32 = 0,
    nparams: u32 = 0,
    nresults: u32 = 0,
    /// The most slots of a frame: the locals and the operands.
    max_height: u32 = 0,
    code: []Ins = &.{},
    targets: []Target = &.{},
    /// The height of the frame before each instruction of `code`, for the
    /// JIT: the slot of the top operand is `heights[i] - 1`.
    heights: []u32 = &.{},
};

/// The internal opcodes after the opcodes of WebAssembly.
pub const op = struct {
    pub const br: u16 = 0x200;
    pub const br_if: u16 = 0x201;
    pub const br_table: u16 = 0x202;
    /// Jumps to `a` when the popped i32 is zero (the `if` instruction).
    pub const jz: u16 = 0x203;
    pub const jmp: u16 = 0x204;
    pub const ret: u16 = 0x205;
    pub const tick: u16 = 0x206;
    pub const fc: u16 = 0x100;
};

pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    types: []const FuncType = &.{},
    imports: []const Import = &.{},
    /// The type index of each function, imports first.
    func_types: []const u32 = &.{},
    /// The defined functions, after the imported ones.
    funcs: []Func = &.{},
    tables: []const TableType = &.{},
    mems: []const Limits = &.{},
    globals: []const GlobalType = &.{},
    /// The init expression of each defined global.
    global_inits: []const ConstExpr = &.{},
    exports: []const Export = &.{},
    start: ?u32 = null,
    elems: []const Elem = &.{},
    datas: []const Data = &.{},
    import_funcs: u32 = 0,
    import_tables: u32 = 0,
    import_mems: u32 = 0,
    import_globals: u32 = 0,
    /// The features that the code uses, for `ztcl::wasm info`.
    features: Features = .{},
    /// The machine code of `jit_x64.zig`, after the first call, or null.
    jit: ?*anyopaque = null,
    /// True when the JIT could not compile the module.
    jit_failed: bool = false,

    /// Frees the module and its arena.
    pub fn deinit(m: *Module) void {
        const gpa = m.arena.child_allocator;
        if (m.jit) |c| @import("jit_x64.zig").freeCode(gpa, @ptrCast(@alignCast(c)));
        m.arena.deinit();
        gpa.destroy(m);
    }

    pub fn funcType(m: *const Module, idx: u32) FuncType {
        return m.types[m.func_types[idx]];
    }

    pub fn findExport(m: *const Module, name: []const u8) ?Export {
        for (m.exports) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }
};

pub const Features = struct {
    bulk_memory: bool = false,
    sign_ext: bool = false,
    multi_value: bool = false,
    reference_types: bool = false,
    sat_trunc: bool = false,
    extended_const: bool = false,
};

pub const DecodeError = error{ Malformed, Invalid, OutOfMemory };

/// The text of the last error and the offset in the bytes.
pub const Diag = struct {
    msg: []const u8 = "",
    offset: usize = 0,
};

/// The limits of the engine, below the limits of the specification.
pub const max_funcs = 1_000_000;
pub const max_locals = 50_000;
pub const max_pages = 65536;
pub const max_table = 10_000_000;
pub const max_params = 1000;

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    diag: *Diag,
    base: usize = 0,

    fn fail(r: *Reader, msg: []const u8) DecodeError {
        r.diag.* = .{ .msg = msg, .offset = r.base + r.pos };
        return error.Malformed;
    }

    fn eof(r: *const Reader) bool {
        return r.pos >= r.bytes.len;
    }

    fn byte(r: *Reader) DecodeError!u8 {
        if (r.pos >= r.bytes.len) return r.fail("unexpected end");
        const b = r.bytes[r.pos];
        r.pos += 1;
        return b;
    }

    fn take(r: *Reader, n: usize) DecodeError![]const u8 {
        if (n > r.bytes.len - r.pos) return r.fail("unexpected end");
        const s = r.bytes[r.pos .. r.pos + n];
        r.pos += n;
        return s;
    }

    fn unsigned(r: *Reader, comptime bits: u7) DecodeError!u64 {
        const max_bytes = (bits + 6) / 7;
        var result: u64 = 0;
        var i: u7 = 0;
        while (i < max_bytes) : (i += 1) {
            const b = try r.byte();
            const shift: u6 = @intCast(@as(u32, i) * 7);
            if (i == max_bytes - 1) {
                const used = bits - @as(u7, i) * 7;
                if (b & 0x80 != 0) return r.fail("integer representation too long");
                if (used < 7 and (b >> @intCast(used)) != 0) return r.fail("integer too large");
            }
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) return result;
        }
        unreachable;
    }

    fn signed(r: *Reader, comptime bits: u7) DecodeError!i64 {
        const max_bytes = (bits + 6) / 7;
        var result: u64 = 0;
        var i: u7 = 0;
        while (i < max_bytes) : (i += 1) {
            const b = try r.byte();
            const shift: u7 = i * 7;
            if (i == max_bytes - 1) {
                if (b & 0x80 != 0) return r.fail("integer representation too long");
                const used = bits - shift;
                if (used < 7) {
                    // The unused bits must repeat the sign bit.
                    const sign = (b >> @intCast(used - 1)) & 1;
                    const rest = b >> @intCast(used);
                    const want: u8 = if (sign == 1) @as(u8, 0x7f) >> @intCast(used) else 0;
                    if (rest != want) return r.fail("integer too large");
                }
            }
            if (shift < 64) result |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) {
                const total = shift + 7;
                if (total < 64 and b & 0x40 != 0) result |= ~@as(u64, 0) << @intCast(total);
                return @bitCast(result);
            }
        }
        unreachable;
    }

    fn u32_(r: *Reader) DecodeError!u32 {
        return @intCast(try r.unsigned(32));
    }

    fn name(r: *Reader) DecodeError![]const u8 {
        const n = try r.u32_();
        const s = try r.take(n);
        if (!std.unicode.utf8ValidateSlice(s)) return r.fail("malformed UTF-8 encoding");
        return s;
    }

    fn valType(r: *Reader) DecodeError!ValType {
        const b = try r.byte();
        return switch (b) {
            0x7f, 0x7e, 0x7d, 0x7c, 0x70, 0x6f => @fromBackingInt(@intCast(b)),
            0x7b => r.fail("the engine has no SIMD"),
            else => r.fail("malformed value type"),
        };
    }

    fn refType(r: *Reader) DecodeError!ValType {
        const b = try r.byte();
        return switch (b) {
            0x70, 0x6f => @fromBackingInt(@intCast(b)),
            else => r.fail("malformed reference type"),
        };
    }

    fn limits(r: *Reader, comptime bits: u7) DecodeError!Limits {
        const flag = try r.byte();
        return switch (flag) {
            0 => .{ .min = try r.unsigned(bits), .max = null },
            1 => .{ .min = try r.unsigned(bits), .max = try r.unsigned(bits) },
            else => r.fail("integer too large"),
        };
    }
};

const Ctx = struct {
    a: Allocator,
    m: *Module,
    diag: *Diag,
    /// The functions that `ref.func` can name.
    refs: std.DynamicBitSetUnmanaged = .{},
    data_count: ?u32 = null,

    fn invalid(c: *Ctx, offset: usize, msg: []const u8) DecodeError {
        c.diag.* = .{ .msg = msg, .offset = offset };
        return error.Invalid;
    }

    fn funcCount(c: *const Ctx) usize {
        return c.m.func_types.len;
    }

    fn markRef(c: *Ctx, idx: u32, count: usize) DecodeError!void {
        if (c.refs.bit_length < count) try c.refs.resize(c.a, count, false);
        c.refs.set(idx);
    }
};

/// Decodes and validates a module. The module has its own arena, and its
/// slices stay valid until `deinit`. The bytes are copied.
pub fn decode(gpa: Allocator, input: []const u8, diag: *Diag) DecodeError!*Module {
    const m = try gpa.create(Module);
    m.* = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer {
        m.arena.deinit();
        gpa.destroy(m);
    }
    const a = m.arena.allocator();
    const bytes = try a.dupe(u8, input);
    var r: Reader = .{ .bytes = bytes, .diag = diag };
    var c: Ctx = .{ .a = a, .m = m, .diag = diag };
    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "\x00asm")) return r.fail("magic header not detected");
    r.pos = 4;
    if (bytes.len < 8) return r.fail("unexpected end");
    if (!std.mem.eql(u8, bytes[4..8], "\x01\x00\x00\x00")) return r.fail("unknown binary version");
    r.pos = 8;

    var func_decls: []const u32 = &.{};
    var last_rank: u8 = 0;
    var saw_code = false;
    var types: std.ArrayList(FuncType) = .empty;
    var imports: std.ArrayList(Import) = .empty;
    var ftypes: std.ArrayList(u32) = .empty;
    var tables: std.ArrayList(TableType) = .empty;
    var mems: std.ArrayList(Limits) = .empty;
    var globals: std.ArrayList(GlobalType) = .empty;

    while (!r.eof()) {
        const id = try r.byte();
        const size = try r.u32_();
        const start = r.pos;
        if (size > bytes.len - start) return r.fail("section size mismatch: unexpected end");
        var s: Reader = .{ .bytes = bytes[start .. start + size], .diag = diag, .base = start };
        if (id != 0) {
            const rank: u8 = switch (id) {
                1...9 => id,
                12 => 10,
                10 => 11,
                11 => 12,
                else => return r.fail("malformed section id"),
            };
            if (rank <= last_rank) return r.fail("unexpected content after last section");
            last_rank = rank;
        }
        switch (id) {
            0 => {
                _ = try s.name();
                s.pos = s.bytes.len;
            },
            1 => {
                const n = try s.u32_();
                for (0..n) |_| {
                    if (try s.byte() != 0x60) return s.fail("integer representation too long");
                    const np = try s.u32_();
                    if (np > max_params) return s.fail("too many params");
                    const ps = try a.alloc(ValType, np);
                    for (ps) |*p| p.* = try s.valType();
                    const nr = try s.u32_();
                    if (nr > max_params) return s.fail("too many results");
                    const rs = try a.alloc(ValType, nr);
                    for (rs) |*p| p.* = try s.valType();
                    if (nr > 1) m.features.multi_value = true;
                    try types.append(a, .{ .params = ps, .results = rs });
                }
                m.types = types.items;
            },
            2 => {
                const n = try s.u32_();
                for (0..n) |_| {
                    const mod = try s.name();
                    const nm = try s.name();
                    const kind = try s.byte();
                    const desc: ImportDesc = switch (kind) {
                        0 => blk: {
                            const t = try s.u32_();
                            if (t >= m.types.len) return c.invalid(start + s.pos, "unknown type");
                            try ftypes.append(a, t);
                            m.import_funcs += 1;
                            break :blk .{ .func = t };
                        },
                        1 => blk: {
                            const t = try tableType(&s);
                            try tables.append(a, t);
                            m.import_tables += 1;
                            break :blk .{ .table = t };
                        },
                        2 => blk: {
                            const l = try memType(&s, &c);
                            try mems.append(a, l);
                            m.import_mems += 1;
                            break :blk .{ .mem = l };
                        },
                        3 => blk: {
                            const g = try globalType(&s);
                            try globals.append(a, g);
                            m.import_globals += 1;
                            break :blk .{ .global = g };
                        },
                        else => return s.fail("malformed import kind"),
                    };
                    try imports.append(a, .{ .module = mod, .name = nm, .desc = desc });
                }
                m.imports = imports.items;
            },
            3 => {
                const n = try s.u32_();
                if (n > max_funcs) return s.fail("too many functions");
                const d = try a.alloc(u32, n);
                for (d) |*t| {
                    t.* = try s.u32_();
                    if (t.* >= m.types.len) return c.invalid(start + s.pos, "unknown type");
                }
                func_decls = d;
                try ftypes.appendSlice(a, d);
            },
            4 => {
                const n = try s.u32_();
                for (0..n) |_| try tables.append(a, try tableType(&s));
            },
            5 => {
                const n = try s.u32_();
                for (0..n) |_| try mems.append(a, try memType(&s, &c));
            },
            6 => {
                m.tables = tables.items;
                m.mems = mems.items;
                m.func_types = ftypes.items;
                const n = try s.u32_();
                const inits = try a.alloc(ConstExpr, n);
                for (inits) |*e| {
                    const g = try globalType(&s);
                    m.globals = globals.items;
                    e.* = try constExpr(&s, &c, g.val, @intCast(globals.items.len));
                    try globals.append(a, g);
                }
                m.global_inits = inits;
            },
            7 => {
                m.tables = tables.items;
                m.mems = mems.items;
                m.globals = globals.items;
                m.func_types = ftypes.items;
                const n = try s.u32_();
                const ex = try a.alloc(Export, n);
                for (ex, 0..) |*e, i| {
                    const nm = try s.name();
                    const kind = try s.byte();
                    if (kind > 3) return s.fail("malformed export kind");
                    const idx = try s.u32_();
                    const count: usize = switch (kind) {
                        0 => ftypes.items.len,
                        1 => tables.items.len,
                        2 => mems.items.len,
                        else => globals.items.len,
                    };
                    if (idx >= count) return c.invalid(start + s.pos, switch (kind) {
                        0 => "unknown function",
                        1 => "unknown table",
                        2 => "unknown memory",
                        else => "unknown global",
                    });
                    for (ex[0..i]) |prev| if (std.mem.eql(u8, prev.name, nm)) return c.invalid(start + s.pos, "duplicate export name");
                    e.* = .{ .name = nm, .kind = @fromBackingInt(@intCast(kind)), .index = idx };
                    if (kind == 0) try c.markRef(idx, ftypes.items.len);
                }
                m.exports = ex;
            },
            8 => {
                const idx = try s.u32_();
                if (idx >= ftypes.items.len) return c.invalid(start + s.pos, "unknown function");
                const t = m.types[ftypes.items[idx]];
                if (t.params.len != 0 or t.results.len != 0) return c.invalid(start + s.pos, "start function");
                m.start = idx;
            },
            9 => {
                m.tables = tables.items;
                m.mems = mems.items;
                m.globals = globals.items;
                m.func_types = ftypes.items;
                m.elems = try elemSection(&s, &c);
            },
            12 => {
                c.data_count = try s.u32_();
            },
            10 => {
                saw_code = true;
                m.tables = tables.items;
                m.mems = mems.items;
                m.globals = globals.items;
                m.func_types = ftypes.items;
                const n = try s.u32_();
                if (n != func_decls.len) return s.fail("function and code section have inconsistent lengths");
                const funcs = try a.alloc(Func, n);
                for (funcs, 0..) |*f, i| {
                    const body_size = try s.u32_();
                    const body_start = s.pos;
                    if (body_size > s.bytes.len - body_start) return s.fail("unexpected end");
                    var b: Reader = .{ .bytes = s.bytes[body_start .. body_start + body_size], .diag = diag, .base = s.base + body_start };
                    f.* = .{ .type = func_decls[i] };
                    try compileBody(&b, &c, f);
                    s.pos = body_start + body_size;
                }
                m.funcs = funcs;
            },
            11 => {
                m.mems = mems.items;
                m.globals = globals.items;
                m.func_types = ftypes.items;
                const n = try s.u32_();
                if (c.data_count) |dc| if (dc != n) return s.fail("data count and data section have inconsistent lengths");
                const ds = try a.alloc(Data, n);
                for (ds) |*d| {
                    const flag = try s.u32_();
                    switch (flag) {
                        0, 2 => {
                            const mem: u32 = if (flag == 2) try s.u32_() else 0;
                            if (mem >= mems.items.len) return c.invalid(start + s.pos, "unknown memory");
                            const off = try constExpr(&s, &c, .i32, @intCast(globals.items.len));
                            const len = try s.u32_();
                            d.* = .{ .mode = .{ .active = .{ .mem = mem, .offset = off } }, .bytes = try s.take(len) };
                        },
                        1 => {
                            const len = try s.u32_();
                            d.* = .{ .mode = .passive, .bytes = try s.take(len) };
                        },
                        else => return s.fail("malformed data segment kind"),
                    }
                }
                m.datas = ds;
            },
            else => unreachable,
        }
        if (s.pos != s.bytes.len) return s.fail("section size mismatch");
        r.pos = start + size;
    }
    if (func_decls.len != 0 and !saw_code) return r.fail("function and code section have inconsistent lengths");
    if (c.data_count) |dc| if (dc != 0 and m.datas.len == 0) return r.fail("data count and data section have inconsistent lengths");
    m.types = types.items;
    m.imports = imports.items;
    m.func_types = ftypes.items;
    m.tables = tables.items;
    m.mems = mems.items;
    m.globals = globals.items;
    if (mems.items.len > 1) return c.invalid(r.pos, "multiple memories");
    return m;
}

fn tableType(s: *Reader) DecodeError!TableType {
    const t = try s.refType();
    const l = try s.limits(32);
    if (l.max) |mx| if (mx < l.min) {
        s.diag.* = .{ .msg = "size minimum must not be greater than maximum", .offset = s.base + s.pos };
        return error.Invalid;
    };
    return .{ .elem = t, .limits = l };
}

fn memType(s: *Reader, c: *Ctx) DecodeError!Limits {
    const flag = try s.byte();
    if (flag > 1) return s.fail("integer too large");
    const min = try s.unsigned(32);
    const max: ?u64 = if (flag == 1) try s.unsigned(32) else null;
    if (min > max_pages) return c.invalid(s.base + s.pos, "memory size must be at most 65536 pages (4GiB)");
    if (max) |mx| {
        if (mx > max_pages) return c.invalid(s.base + s.pos, "memory size must be at most 65536 pages (4GiB)");
        if (mx < min) return c.invalid(s.base + s.pos, "size minimum must not be greater than maximum");
    }
    return .{ .min = min, .max = max };
}

fn globalType(s: *Reader) DecodeError!GlobalType {
    const t = try s.valType();
    const mut = try s.byte();
    if (mut > 1) return s.fail("malformed mutability");
    return .{ .val = t, .mutable = mut == 1 };
}

/// Reads and checks a constant expression of type `want`. `nglobals` is
/// the count of globals that it can read.
fn constExpr(s: *Reader, c: *Ctx, want: ValType, nglobals: u32) DecodeError!ConstExpr {
    const begin = s.pos;
    var stack: [64]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const at = s.base + s.pos;
        const b = try s.byte();
        switch (b) {
            0x0b => break,
            0x41 => {
                _ = try s.signed(32);
                if (n == stack.len) return c.invalid(at, "constant expression too deep");
                stack[n] = @backingInt(ValType.i32);
                n += 1;
            },
            0x42 => {
                _ = try s.signed(64);
                if (n == stack.len) return c.invalid(at, "constant expression too deep");
                stack[n] = @backingInt(ValType.i64);
                n += 1;
            },
            0x43, 0x44 => {
                _ = try s.take(if (b == 0x43) 4 else 8);
                if (n == stack.len) return c.invalid(at, "constant expression too deep");
                stack[n] = @backingInt(if (b == 0x43) ValType.f32 else ValType.f64);
                n += 1;
            },
            0xd0 => {
                const t = try s.refType();
                if (n == stack.len) return c.invalid(at, "constant expression too deep");
                stack[n] = @backingInt(t);
                n += 1;
            },
            0xd2 => {
                const f = try s.u32_();
                if (f >= c.funcCount()) return c.invalid(at, "unknown function");
                try c.markRef(f, c.funcCount());
                if (n == stack.len) return c.invalid(at, "constant expression too deep");
                stack[n] = @backingInt(ValType.funcref);
                n += 1;
            },
            0x23 => {
                const g = try s.u32_();
                // Core 2.0 reads only imported globals in a constant expression.
                if (g >= nglobals or g >= c.m.import_globals) return c.invalid(at, "unknown global");
                if (c.m.globals[g].mutable) return c.invalid(at, "constant expression required");
                if (n == stack.len) return c.invalid(at, "constant expression too deep");
                stack[n] = @backingInt(c.m.globals[g].val);
                n += 1;
            },
            0x6a, 0x6b, 0x6c, 0x7c, 0x7d, 0x7e => {
                const t: ValType = if (b < 0x70) .i32 else .i64;
                if (n < 2 or stack[n - 1] != @backingInt(t) or stack[n - 2] != @backingInt(t)) return c.invalid(at, "type mismatch");
                n -= 1;
                c.m.features.extended_const = true;
            },
            else => {
                if (!isOpcode(b)) return s.fail("illegal opcode");
                return c.invalid(at, "constant expression required");
            },
        }
    }
    if (n != 1 or stack[0] != @backingInt(want)) return c.invalid(s.base + s.pos, "type mismatch");
    return .{ .code = s.bytes[begin..s.pos] };
}

/// True for a first byte of an instruction of the engine.
fn isOpcode(b: u8) bool {
    return switch (b) {
        0x00...0x05, 0x0b...0x11, 0x1a...0x1c, 0x20...0x26, 0x28...0xc4, 0xd0...0xd2, 0xfc => true,
        else => false,
    };
}

fn elemSection(s: *Reader, c: *Ctx) DecodeError![]const Elem {
    const a = c.a;
    const n = try s.u32_();
    const out = try a.alloc(Elem, n);
    for (out) |*e| {
        const at = s.base + s.pos;
        const flag = try s.u32_();
        if (flag > 7) return s.fail("malformed elements segment kind");
        const passive_or_decl = flag & 1 != 0;
        const explicit_table = flag & 2 != 0;
        const exprs = flag & 4 != 0;
        var mode: ElemMode = undefined;
        if (!passive_or_decl) {
            const table: u32 = if (explicit_table) try s.u32_() else 0;
            if (table >= c.m.tables.len) return c.invalid(at, "unknown table");
            const off = try constExpr(s, c, .i32, @intCast(c.m.globals.len));
            mode = .{ .active = .{ .table = table, .offset = off } };
        } else {
            mode = if (explicit_table) .declarative else .passive;
        }
        var t: ValType = .funcref;
        if (passive_or_decl or explicit_table) {
            if (exprs) {
                t = try s.refType();
            } else {
                if (try s.byte() != 0) return s.fail("malformed element kind");
            }
        }
        const count = try s.u32_();
        const init = try a.alloc(ConstExpr, count);
        for (init) |*x| {
            if (exprs) {
                x.* = try constExpr(s, c, t, @intCast(c.m.globals.len));
            } else {
                const f = try s.u32_();
                if (f >= c.funcCount()) return c.invalid(s.base + s.pos, "unknown function");
                try c.markRef(f, c.funcCount());
                x.* = .{ .func = f };
            }
        }
        if (mode == .active) {
            const tt = c.m.tables[mode.active.table].elem;
            if (tt != t) return c.invalid(at, "type mismatch");
        }
        e.* = .{ .type = t, .mode = mode, .init = init };
    }
    return out;
}

// ---- Function bodies ----

const CtrlKind = enum { block, loop, @"if", @"else", func };
const none: u32 = std.math.maxInt(u32);

const Ctrl = struct {
    kind: CtrlKind,
    params: []const ValType,
    results: []const ValType,
    height: u32,
    unreachable_: bool = false,
    /// The pc of a loop start.
    start: u32 = 0,
    /// The first patch of the branches to the end, or `none`.
    patch: u32 = none,
    /// The `jz` of an `if`, until its `else`.
    jz: u32 = none,

    fn labelTypes(f: Ctrl) []const ValType {
        return if (f.kind == .loop) f.params else f.results;
    }
};

const Patch = struct { next: u32, at: u32, target: bool };

const Compiler = struct {
    c: *Ctx,
    r: *Reader,
    f: *Func,
    locals: []const ValType,
    vals: std.ArrayList(u8) = .empty,
    ctrls: std.ArrayList(Ctrl) = .empty,
    code: std.ArrayList(Ins) = .empty,
    targets: std.ArrayList(Target) = .empty,
    patches: std.ArrayList(Patch) = .empty,
    max_vals: usize = 0,
    at: usize = 0,
    heights: std.ArrayList(u32) = .empty,
    /// The height before the instruction that the loop reads now.
    cur_h: u32 = 0,

    fn err(k: *Compiler, msg: []const u8) DecodeError {
        return k.c.invalid(k.at, msg);
    }

    fn push(k: *Compiler, t: u8) DecodeError!void {
        try k.vals.append(k.c.a, t);
        if (k.vals.items.len > k.max_vals) k.max_vals = k.vals.items.len;
    }

    fn pushT(k: *Compiler, t: ValType) DecodeError!void {
        return k.push(@backingInt(t));
    }

    fn popAny(k: *Compiler) DecodeError!u8 {
        const top = &k.ctrls.items[k.ctrls.items.len - 1];
        if (k.vals.items.len == top.height) {
            if (top.unreachable_) return Unknown;
            return k.err("type mismatch");
        }
        return k.vals.pop().?;
    }

    fn pop(k: *Compiler, want: ValType) DecodeError!void {
        const t = try k.popAny();
        if (t != Unknown and t != @backingInt(want)) return k.err("type mismatch");
    }

    fn pops(k: *Compiler, ts: []const ValType) DecodeError!void {
        var i = ts.len;
        while (i > 0) {
            i -= 1;
            try k.pop(ts[i]);
        }
    }

    fn pushes(k: *Compiler, ts: []const ValType) DecodeError!void {
        for (ts) |t| try k.pushT(t);
    }

    fn pushCtrl(k: *Compiler, kind: CtrlKind, params: []const ValType, results: []const ValType) DecodeError!void {
        try k.ctrls.append(k.c.a, .{ .kind = kind, .params = params, .results = results, .height = @intCast(k.vals.items.len), .start = @intCast(k.code.items.len) });
        try k.pushes(params);
    }

    fn popCtrl(k: *Compiler) DecodeError!Ctrl {
        if (k.ctrls.items.len == 0) return k.err("type mismatch");
        const top = k.ctrls.items[k.ctrls.items.len - 1];
        try k.pops(top.results);
        if (k.vals.items.len != top.height) return k.err("type mismatch");
        k.ctrls.items.len -= 1;
        return top;
    }

    fn setUnreachable(k: *Compiler) void {
        const top = &k.ctrls.items[k.ctrls.items.len - 1];
        k.vals.items.len = top.height;
        top.unreachable_ = true;
    }

    fn emit(k: *Compiler, ins: Ins) DecodeError!void {
        try k.code.append(k.c.a, ins);
        try k.heights.append(k.c.a, k.cur_h);
    }

    fn pc(k: *const Compiler) u32 {
        return @intCast(k.code.items.len);
    }

    /// The height of the frame now, with the locals.
    fn height(k: *const Compiler, n: usize) u32 {
        return @intCast(k.locals.len + n);
    }

    fn label(k: *Compiler, depth: u32) DecodeError!*Ctrl {
        if (depth >= k.ctrls.items.len) return k.err("unknown label");
        return &k.ctrls.items[k.ctrls.items.len - 1 - depth];
    }

    /// The target fields of a branch to `depth`. A branch to a block end
    /// adds a patch.
    fn branchTo(k: *Compiler, depth: u32, at: u32, target: bool) DecodeError!Target {
        const l = try k.label(depth);
        const arity: u32 = @intCast(l.labelTypes().len);
        const h = k.height(l.height);
        if (l.kind == .loop) return .{ .pc = l.start, .arity = arity, .height = h };
        try k.patches.append(k.c.a, .{ .next = l.patch, .at = at, .target = target });
        l.patch = @intCast(k.patches.items.len - 1);
        return .{ .pc = none, .arity = arity, .height = h };
    }

    fn resolve(k: *Compiler, f: Ctrl, end_pc: u32) void {
        var p = f.patch;
        while (p != none) {
            const e = k.patches.items[p];
            if (e.target) k.targets.items[e.at].pc = end_pc else k.code.items[e.at].a = end_pc;
            p = e.next;
        }
    }

    fn blockType(k: *Compiler) DecodeError!FuncType {
        const r = k.r;
        const b = if (r.pos < r.bytes.len) r.bytes[r.pos] else return r.fail("unexpected end");
        if (b == 0x40) {
            r.pos += 1;
            return .{ .params = &.{}, .results = &.{} };
        }
        if (b == 0x7f or b == 0x7e or b == 0x7d or b == 0x7c or b == 0x70 or b == 0x6f) {
            r.pos += 1;
            const one = try k.c.a.alloc(ValType, 1);
            one[0] = @fromBackingInt(@intCast(b));
            return .{ .params = &.{}, .results = one };
        }
        const idx = try r.signed(33);
        if (idx < 0 or idx >= k.c.m.types.len) return k.err("unknown type");
        k.c.m.features.multi_value = true;
        return k.c.m.types[@intCast(idx)];
    }

    fn memarg(k: *Compiler, natural: u32) DecodeError!u32 {
        const r = k.r;
        const align_ = try r.u32_();
        const offset = try r.u32_();
        if (k.c.m.mems.len == 0) return k.err("unknown memory 0");
        if (align_ >= 32) return r.fail("malformed memop flags");
        if (align_ > natural) return k.err("alignment must not be larger than natural");
        return offset;
    }

    fn needMem(k: *Compiler) DecodeError!void {
        if (k.c.m.mems.len == 0) return k.err("unknown memory 0");
    }

    fn table(k: *Compiler, idx: u32) DecodeError!ValType {
        if (idx >= k.c.m.tables.len) return k.err("unknown table");
        return k.c.m.tables[idx].elem;
    }
};

const I = ValType.i32;
const L = ValType.i64;
const F = ValType.f32;
const D = ValType.f64;

/// The operand types and the result type of a plain numeric opcode.
const Sig = struct { in: [2]ValType = undefined, n: u8 = 0, out: ValType = I, ok: bool = false };

fn sigOf(code: u8) Sig {
    const un = struct {
        fn f(x: ValType, o: ValType) Sig {
            return .{ .in = .{ x, x }, .n = 1, .out = o, .ok = true };
        }
        fn g(x: ValType, o: ValType) Sig {
            return .{ .in = .{ x, x }, .n = 2, .out = o, .ok = true };
        }
    };
    return switch (code) {
        0x45 => un.f(I, I),
        0x46...0x4f => un.g(I, I),
        0x50 => un.f(L, I),
        0x51...0x5a => un.g(L, I),
        0x5b...0x60 => un.g(F, I),
        0x61...0x66 => un.g(D, I),
        0x67...0x69 => un.f(I, I),
        0x6a...0x78 => un.g(I, I),
        0x79...0x7b => un.f(L, L),
        0x7c...0x8a => un.g(L, L),
        0x8b...0x91 => un.f(F, F),
        0x92...0x98 => un.g(F, F),
        0x99...0x9f => un.f(D, D),
        0xa0...0xa6 => un.g(D, D),
        0xa7 => un.f(L, I),
        0xa8, 0xa9 => un.f(F, I),
        0xaa, 0xab => un.f(D, I),
        0xac, 0xad => un.f(I, L),
        0xae, 0xaf => un.f(F, L),
        0xb0, 0xb1 => un.f(D, L),
        0xb2, 0xb3 => un.f(I, F),
        0xb4, 0xb5 => un.f(L, F),
        0xb6 => un.f(D, F),
        0xb7, 0xb8 => un.f(I, D),
        0xb9, 0xba => un.f(L, D),
        0xbb => un.f(F, D),
        0xbc => un.f(F, I),
        0xbd => un.f(D, L),
        0xbe => un.f(I, F),
        0xbf => un.f(L, D),
        0xc0, 0xc1 => un.f(I, I),
        0xc2...0xc4 => un.f(L, L),
        else => .{},
    };
}

const load_types = [_]ValType{ I, L, F, D, I, I, I, I, L, L, L, L, L, L };
const load_align = [_]u32{ 2, 3, 2, 3, 0, 0, 1, 1, 0, 0, 1, 1, 2, 2 };
const store_types = [_]ValType{ I, L, F, D, I, I, L, L, L };
const store_align = [_]u32{ 2, 3, 2, 3, 0, 1, 0, 1, 2 };

fn compileBody(r: *Reader, c: *Ctx, f: *Func) DecodeError!void {
    const a = c.a;
    const ft = c.m.types[f.type];
    // The locals.
    var locals: std.ArrayList(ValType) = .empty;
    try locals.appendSlice(a, ft.params);
    const groups = try r.u32_();
    var total: u64 = ft.params.len;
    var too_many = false;
    for (0..groups) |_| {
        const n = try r.u32_();
        total += n;
        if (total > std.math.maxInt(u32)) return r.fail("too many locals");
        const t = try r.valType();
        if (total > max_locals) too_many = true;
        if (!too_many) try locals.appendNTimes(a, t, n);
    }
    if (too_many) return c.invalid(r.base + r.pos, "too many locals for the engine");
    var k: Compiler = .{ .c = c, .r = r, .f = f, .locals = locals.items };
    f.nlocals = @intCast(locals.items.len);
    f.nparams = @intCast(ft.params.len);
    f.nresults = @intCast(ft.results.len);
    try k.ctrls.append(a, .{ .kind = .func, .params = &.{}, .results = ft.results, .height = 0 });

    while (k.ctrls.items.len > 0) {
        k.at = r.base + r.pos;
        k.cur_h = k.height(k.vals.items.len);
        if (r.eof()) return r.fail("unexpected end of section or function");
        const b = try r.byte();
        switch (b) {
            0x00 => {
                try k.emit(.{ .op = 0x00 });
                k.setUnreachable();
            },
            0x01 => {},
            0x02, 0x03 => {
                const bt = try k.blockType();
                try k.pops(bt.params);
                try k.pushCtrl(if (b == 0x02) .block else .loop, bt.params, bt.results);
                if (b == 0x03) try k.emit(.{ .op = op.tick });
            },
            0x04 => {
                const bt = try k.blockType();
                try k.pop(I);
                try k.pops(bt.params);
                try k.pushCtrl(.@"if", bt.params, bt.results);
                k.ctrls.items[k.ctrls.items.len - 1].jz = k.pc();
                try k.emit(.{ .op = op.jz });
            },
            0x05 => {
                const top = k.ctrls.items[k.ctrls.items.len - 1];
                if (top.kind != .@"if") return r.fail("else without if");
                var fr = try k.popCtrl();
                // The end of the `then` part jumps to the end.
                const j = k.pc();
                try k.emit(.{ .op = op.jmp, .a = none });
                try k.patches.append(a, .{ .next = fr.patch, .at = j, .target = false });
                fr.patch = @intCast(k.patches.items.len - 1);
                k.code.items[fr.jz].a = k.pc();
                fr.jz = none;
                fr.kind = .@"else";
                fr.unreachable_ = false;
                fr.height = @intCast(k.vals.items.len);
                try k.ctrls.append(a, fr);
                try k.pushes(fr.params);
            },
            0x0b => {
                const fr = try k.popCtrl();
                if (fr.kind == .@"if") {
                    // An `if` with no `else` passes its params on.
                    if (!std.mem.eql(ValType, fr.params, fr.results)) return k.err("type mismatch");
                    k.code.items[fr.jz].a = k.pc();
                }
                if (fr.kind == .func) {
                    k.resolve(fr, k.pc());
                    // A branch to the end leaves the results at the label.
                    k.cur_h = k.height(fr.height + fr.results.len);
                    try k.emit(.{ .op = op.ret });
                } else {
                    k.resolve(fr, k.pc());
                    try k.pushes(fr.results);
                }
            },
            0x0c => {
                const d = try r.u32_();
                const at = k.pc();
                const t = try k.branchTo(d, at, false);
                try k.pops((try k.label(d)).labelTypes());
                try k.emit(.{ .op = op.br, .a = t.pc, .b = (@as(u64, t.arity) << 32) | t.height });
                k.setUnreachable();
            },
            0x0d => {
                const d = try r.u32_();
                try k.pop(I);
                const at = k.pc();
                const t = try k.branchTo(d, at, false);
                const lt = (try k.label(d)).labelTypes();
                try k.pops(lt);
                try k.pushes(lt);
                try k.emit(.{ .op = op.br_if, .a = t.pc, .b = (@as(u64, t.arity) << 32) | t.height });
            },
            0x0e => {
                const n = try r.u32_();
                if (n > 100_000) return r.fail("br_table too long");
                const first: u32 = @intCast(k.targets.items.len);
                const depths = try a.alloc(u32, n + 1);
                for (depths) |*d| d.* = try r.u32_();
                try k.pop(I);
                const arity = (try k.label(depths[n])).labelTypes().len;
                var popped: std.ArrayList(u8) = .empty;
                for (depths) |d| {
                    const lt = (try k.label(d)).labelTypes();
                    if (lt.len != arity) return k.err("type mismatch");
                    // Pop the label types, then push the popped types again.
                    popped.clearRetainingCapacity();
                    var i = lt.len;
                    while (i > 0) {
                        i -= 1;
                        const t = try k.popAny();
                        if (t != Unknown and t != @backingInt(lt[i])) return k.err("type mismatch");
                        try popped.append(a, t);
                    }
                    i = popped.items.len;
                    while (i > 0) {
                        i -= 1;
                        try k.push(popped.items[i]);
                    }
                    const idx: u32 = @intCast(k.targets.items.len);
                    try k.targets.append(a, undefined);
                    k.targets.items[idx] = try k.branchTo(d, idx, true);
                }
                try k.pops((try k.label(depths[n])).labelTypes());
                try k.emit(.{ .op = op.br_table, .a = first, .b = n + 1 });
                k.setUnreachable();
            },
            0x0f => {
                try k.pops(ft.results);
                try k.emit(.{ .op = op.ret });
                k.setUnreachable();
            },
            0x10 => {
                const idx = try r.u32_();
                if (idx >= c.funcCount()) return k.err("unknown function");
                const t = c.m.types[c.m.func_types[idx]];
                try k.pops(t.params);
                try k.pushes(t.results);
                try k.emit(.{ .op = 0x10, .a = idx });
            },
            0x11 => {
                const ti = try r.u32_();
                const tab = try r.u32_();
                if ((try k.table(tab)) != .funcref) return k.err("type mismatch");
                if (ti >= c.m.types.len) return k.err("unknown type");
                if (tab != 0) c.m.features.reference_types = true;
                try k.pop(I);
                const t = c.m.types[ti];
                try k.pops(t.params);
                try k.pushes(t.results);
                try k.emit(.{ .op = 0x11, .a = ti, .b = tab });
            },
            0x1a => {
                _ = try k.popAny();
                try k.emit(.{ .op = 0x1a });
            },
            0x1b => {
                try k.pop(I);
                const t1 = try k.popAny();
                const t2 = try k.popAny();
                const num1 = t1 == Unknown or !(@as(ValType, @fromBackingInt(@intCast(t1)))).isRef();
                const num2 = t2 == Unknown or !(@as(ValType, @fromBackingInt(@intCast(t2)))).isRef();
                if (!num1 or !num2) return k.err("type mismatch");
                if (t1 != t2 and t1 != Unknown and t2 != Unknown) return k.err("type mismatch");
                try k.push(if (t1 == Unknown) t2 else t1);
                try k.emit(.{ .op = 0x1b });
            },
            0x1c => {
                const n = try r.u32_();
                if (n != 1) return k.err("invalid result arity");
                const t = try r.valType();
                try k.pop(I);
                try k.pop(t);
                try k.pop(t);
                try k.pushT(t);
                c.m.features.reference_types = true;
                try k.emit(.{ .op = 0x1b });
            },
            0x20, 0x21, 0x22 => {
                const idx = try r.u32_();
                if (idx >= k.locals.len) return k.err("unknown local");
                const t = k.locals[idx];
                switch (b) {
                    0x20 => try k.pushT(t),
                    0x21 => try k.pop(t),
                    else => {
                        try k.pop(t);
                        try k.pushT(t);
                    },
                }
                try k.emit(.{ .op = b, .a = idx });
            },
            0x23, 0x24 => {
                const idx = try r.u32_();
                if (idx >= c.m.globals.len) return k.err("unknown global");
                const g = c.m.globals[idx];
                if (b == 0x23) {
                    try k.pushT(g.val);
                } else {
                    if (!g.mutable) return k.err("global is immutable");
                    try k.pop(g.val);
                }
                try k.emit(.{ .op = b, .a = idx });
            },
            0x25, 0x26 => {
                const tab = try r.u32_();
                const t = try k.table(tab);
                c.m.features.reference_types = true;
                if (b == 0x25) {
                    try k.pop(I);
                    try k.pushT(t);
                } else {
                    try k.pop(t);
                    try k.pop(I);
                }
                try k.emit(.{ .op = b, .a = tab });
            },
            0x28...0x35 => {
                const i = b - 0x28;
                const off = try k.memarg(load_align[i]);
                try k.pop(I);
                try k.pushT(load_types[i]);
                try k.emit(.{ .op = b, .a = off });
            },
            0x36...0x3e => {
                const i = b - 0x36;
                const off = try k.memarg(store_align[i]);
                try k.pop(store_types[i]);
                try k.pop(I);
                try k.emit(.{ .op = b, .a = off });
            },
            0x3f, 0x40 => {
                if (try r.byte() != 0) return r.fail("zero byte expected");
                try k.needMem();
                if (b == 0x40) try k.pop(I);
                try k.pushT(I);
                try k.emit(.{ .op = b });
            },
            0x41 => {
                const v = try r.signed(32);
                try k.pushT(I);
                try k.emit(.{ .op = b, .b = @as(u32, @bitCast(@as(i32, @intCast(v)))) });
            },
            0x42 => {
                const v = try r.signed(64);
                try k.pushT(L);
                try k.emit(.{ .op = b, .b = @bitCast(v) });
            },
            0x43 => {
                const bits = std.mem.readInt(u32, (try r.take(4))[0..4], .little);
                try k.pushT(F);
                try k.emit(.{ .op = b, .b = bits });
            },
            0x44 => {
                const bits = std.mem.readInt(u64, (try r.take(8))[0..8], .little);
                try k.pushT(D);
                try k.emit(.{ .op = b, .b = bits });
            },
            0x45...0xc4 => {
                const s = sigOf(b);
                if (!s.ok) return r.fail("illegal opcode");
                if (b >= 0xc0) c.m.features.sign_ext = true;
                if (s.n == 2) try k.pop(s.in[1]);
                try k.pop(s.in[0]);
                try k.pushT(s.out);
                try k.emit(.{ .op = b });
            },
            0xd0 => {
                const t = try r.refType();
                try k.pushT(t);
                c.m.features.reference_types = true;
                try k.emit(.{ .op = b });
            },
            0xd1 => {
                const t = try k.popAny();
                if (t != Unknown and !(@as(ValType, @fromBackingInt(@intCast(t)))).isRef()) return k.err("type mismatch");
                try k.pushT(I);
                try k.emit(.{ .op = b });
            },
            0xd2 => {
                const idx = try r.u32_();
                if (idx >= c.funcCount()) return k.err("unknown function");
                if (idx >= c.refs.bit_length or !c.refs.isSet(idx)) return k.err("undeclared function reference");
                try k.pushT(.funcref);
                try k.emit(.{ .op = b, .a = idx });
            },
            0xfc => try compileFc(&k),
            else => return r.fail("illegal opcode"),
        }
    }
    if (!r.eof()) return r.fail("section size mismatch");
    f.code = k.code.items;
    f.targets = k.targets.items;
    f.heights = k.heights.items;
    f.max_height = @intCast(locals.items.len + k.max_vals + 1);
}

fn compileFc(k: *Compiler) DecodeError!void {
    const r = k.r;
    const c = k.c;
    const sub = try r.u32_();
    const code: u16 = @intCast(op.fc + @min(sub, 0xff));
    switch (sub) {
        0...7 => {
            const in: ValType = if (sub & 2 == 0) F else D;
            const out: ValType = if (sub < 4) I else L;
            try k.pop(in);
            try k.pushT(out);
            c.m.features.sat_trunc = true;
            try k.emit(.{ .op = code });
        },
        8 => {
            const d = try r.u32_();
            if (try r.byte() != 0) return r.fail("zero byte expected");
            try k.needMem();
            const dc = c.data_count orelse return r.fail("data count section required");
            if (d >= dc) return k.err("unknown data segment");
            try k.pop(I);
            try k.pop(I);
            try k.pop(I);
            c.m.features.bulk_memory = true;
            try k.emit(.{ .op = code, .a = d });
        },
        9 => {
            const d = try r.u32_();
            const dc = c.data_count orelse return r.fail("data count section required");
            if (d >= dc) return k.err("unknown data segment");
            c.m.features.bulk_memory = true;
            try k.emit(.{ .op = code, .a = d });
        },
        10, 11 => {
            if (try r.byte() != 0) return r.fail("zero byte expected");
            if (sub == 10 and try r.byte() != 0) return r.fail("zero byte expected");
            try k.needMem();
            try k.pop(I);
            try k.pop(I);
            try k.pop(I);
            c.m.features.bulk_memory = true;
            try k.emit(.{ .op = code });
        },
        12 => {
            const e = try r.u32_();
            const tab = try r.u32_();
            const tt = try k.table(tab);
            if (e >= c.m.elems.len) return k.err("unknown elem segment");
            if (c.m.elems[e].type != tt) return k.err("type mismatch");
            try k.pop(I);
            try k.pop(I);
            try k.pop(I);
            c.m.features.bulk_memory = true;
            try k.emit(.{ .op = code, .a = e, .b = tab });
        },
        13 => {
            const e = try r.u32_();
            if (e >= c.m.elems.len) return k.err("unknown elem segment");
            c.m.features.bulk_memory = true;
            try k.emit(.{ .op = code, .a = e });
        },
        14 => {
            const dst = try r.u32_();
            const src = try r.u32_();
            const td = try k.table(dst);
            const ts = try k.table(src);
            if (td != ts) return k.err("type mismatch");
            try k.pop(I);
            try k.pop(I);
            try k.pop(I);
            c.m.features.bulk_memory = true;
            try k.emit(.{ .op = code, .a = dst, .b = src });
        },
        15 => {
            const tab = try r.u32_();
            const t = try k.table(tab);
            try k.pop(I);
            try k.pop(t);
            try k.pushT(I);
            c.m.features.reference_types = true;
            try k.emit(.{ .op = code, .a = tab });
        },
        16 => {
            const tab = try r.u32_();
            _ = try k.table(tab);
            try k.pushT(I);
            c.m.features.reference_types = true;
            try k.emit(.{ .op = code, .a = tab });
        },
        17 => {
            const tab = try r.u32_();
            const t = try k.table(tab);
            try k.pop(I);
            try k.pop(t);
            try k.pop(I);
            c.m.features.reference_types = true;
            try k.emit(.{ .op = code, .a = tab });
        },
        else => return r.fail("illegal opcode"),
    }
}

/// Reads one constant expression of `code` for `exec.zig`. The module
/// validated it, so each read succeeds.
pub const ConstReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn next(cr: *ConstReader) ?struct { op: u8, imm: u64 } {
        var diag: Diag = .{};
        var r: Reader = .{ .bytes = cr.bytes, .pos = cr.pos, .diag = &diag };
        const b = r.byte() catch return null;
        const imm: u64 = switch (b) {
            0x41 => @as(u32, @bitCast(@as(i32, @intCast(r.signed(32) catch unreachable)))),
            0x42 => @bitCast(r.signed(64) catch unreachable),
            0x43 => std.mem.readInt(u32, (r.take(4) catch unreachable)[0..4], .little),
            0x44 => std.mem.readInt(u64, (r.take(8) catch unreachable)[0..8], .little),
            0xd0 => (r.byte() catch unreachable),
            0xd2, 0x23 => r.unsigned(32) catch unreachable,
            else => 0,
        };
        cr.pos = r.pos;
        return .{ .op = b, .imm = imm };
    }
};

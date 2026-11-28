//! The module `ztcl::fhe`: the Tcl commands of the library `fhe.zig`.
//!
//! A context, a key set, and a ciphertext are objects of the
//! interpreter with the names fhe0, fhe1, and so on. `ztcl::fhe free`
//! frees an object, and the end of the interpreter frees each object
//! that is left. A key set counts as a user of its context, and a
//! ciphertext as a user of its key set. An object with users stays.
//!
//! The memory of the objects is from the backing allocator of the heap.
//! Each allocation fails when the memory of the interpreter and the
//! memory of the objects together go above the memory limit. Each
//! operation uses compute units before it starts: one unit for each
//! 4,096 bytes that one pass of the operation reads.
//!
//! The random data is ChaCha with a key from the entropy of the host.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("../interp.zig");
const mods = @import("../modules.zig");
const value = @import("../value.zig");
const fhe = @import("fhe.zig");
const ckks = fhe.ckks;
const tfhe = fhe.tfhe;
const Interp = interp.Interp;
const Error = interp.Error;
const Value = value.Value;

pub const modules_list = [_]mods.Module{
    .{ .name = "ztcl::fhe", .version = "0.1", .install = install },
};

pub const modules: []const mods.Module = &modules_list;

fn install(it: *Interp) Error!void {
    try it.register("ztcl::fhe", fheCmd);
}

/// An allocator on the backing allocator that keeps the memory of the
/// interpreter and of the FHE objects below the memory limit.
const Limited = struct {
    it: *Interp,
    live: usize = 0,

    fn allocator(l: *Limited) std.mem.Allocator {
        return .{ .ptr = l, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn fits(l: *const Limited, more: usize) bool {
        return l.it.memUsed() +| l.live +| more <= l.it.mem_limit;
    }
    fn alloc(p: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const l: *Limited = @ptrCast(@alignCast(p));
        if (!l.fits(len)) return null;
        const r = l.it.heap.backing.rawAlloc(len, a, ra) orelse return null;
        l.live += len;
        return r;
    }
    fn resize(p: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const l: *Limited = @ptrCast(@alignCast(p));
        if (new_len > m.len and !l.fits(new_len - m.len)) return false;
        if (!l.it.heap.backing.rawResize(m, a, new_len, ra)) return false;
        l.live = l.live - m.len + new_len;
        return true;
    }
    fn remap(p: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const l: *Limited = @ptrCast(@alignCast(p));
        if (new_len > m.len and !l.fits(new_len - m.len)) return null;
        const r = l.it.heap.backing.rawRemap(m, a, new_len, ra) orelse return null;
        l.live = l.live - m.len + new_len;
        return r;
    }
    fn free(p: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const l: *Limited = @ptrCast(@alignCast(p));
        l.it.heap.backing.rawFree(m, a, ra);
        l.live -= m.len;
    }
};

const Obj = union(enum) {
    ckks_ctx: struct { ctx: *ckks.Context, uses: u32 = 0 },
    ckks_keys: struct { keys: ckks.Keys, ctx: usize, uses: u32 = 0 },
    ckks_ct: struct { ct: ckks.Ciphertext, keys: usize },
    tfhe_ctx: struct { ctx: *tfhe.Context, uses: u32 = 0 },
    tfhe_keys: struct { sk: tfhe.SecretKey, ck: tfhe.CloudKey, ctx: usize, uses: u32 = 0 },
    tfhe_ct: struct { words: []u32, keys: usize },
};

const State = struct {
    limited: Limited,
    objs: std.ArrayList(?Obj) = .empty,
    csprng: std.Random.DefaultCsprng,

    fn gpa(s: *State) std.mem.Allocator {
        return s.limited.allocator();
    }

    fn ckksCtx(s: *State, i: usize) *ckks.Context {
        return s.objs.items[i].?.ckks_ctx.ctx;
    }

    fn tfheCtx(s: *State, i: usize) *tfhe.Context {
        return s.objs.items[i].?.tfhe_ctx.ctx;
    }
};

fn state(it: *Interp) Error!*State {
    if (it.fhe_state) |p| return @ptrCast(@alignCast(p));
    const s = try it.heap.backing.create(State);
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    @import("../isoproto.zig").entropy(&seed);
    s.* = .{ .limited = .{ .it = it }, .csprng = std.Random.DefaultCsprng.init(seed) };
    it.fhe_state = s;
    return s;
}

fn freeObj(s: *State, i: usize) void {
    const gpa = s.gpa();
    const o = s.objs.items[i] orelse return;
    switch (o) {
        .ckks_ctx => |c| c.ctx.deinit(),
        .ckks_keys => |k| {
            var keys = k.keys;
            keys.deinit(s.ckksCtx(k.ctx));
            s.objs.items[k.ctx].?.ckks_ctx.uses -= 1;
        },
        .ckks_ct => |c| {
            const keys = &s.objs.items[c.keys].?.ckks_keys;
            c.ct.deinit(s.ckksCtx(keys.ctx));
            keys.uses -= 1;
        },
        .tfhe_ctx => |c| c.ctx.deinit(),
        .tfhe_keys => |k| {
            k.sk.deinit(gpa);
            k.ck.deinit(gpa);
            s.objs.items[k.ctx].?.tfhe_ctx.uses -= 1;
        },
        .tfhe_ct => |c| {
            gpa.free(c.words);
            s.objs.items[c.keys].?.tfhe_keys.uses -= 1;
        },
    }
    s.objs.items[i] = null;
}

/// Frees each object of `it`. `Interp.deinit` calls it.
pub fn closeAll(it: *Interp) void {
    const s: *State = @ptrCast(@alignCast(it.fhe_state orelse return));
    // An object is after the object that it uses, so the reverse order
    // frees each user first.
    var i = s.objs.items.len;
    while (i > 0) : (i -= 1) freeObj(s, i - 1);
    s.objs.deinit(it.heap.backing);
    it.heap.backing.destroy(s);
    it.fhe_state = null;
}

fn charge(it: *Interp, units: u64) Error!void {
    if (it.compute_limit < units) {
        it.compute_limit = 0;
        return it.fail("compute limit reached", .{});
    }
    it.compute_limit -= units;
}

/// The compute units of `passes` passes over a polynomial of n words.
fn passUnits(n: usize, passes: usize) u64 {
    return @max(1, @as(u64, n) * 8 * passes / 4096);
}

/// The units of one key switch at a level: about (level + 2)^2
/// transforms of log2(n) passes each.
fn switchUnits(ctx: *const ckks.Context, level: usize) u64 {
    return passUnits(ctx.n, (level + 2) * (level + 2) * ctx.params.log_n);
}

fn libError(it: *Interp, e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.TclError => error.TclError,
        error.NoLevel => it.failCode("ZTCL FHE NOLEVEL", "the ciphertext has no level left for a multiplication", .{}),
        error.NoGaloisKey => it.failCode("ZTCL FHE NOKEY", "the keys have no Galois key for this rotation", .{}),
        error.TooManyValues => it.failCode("ZTCL FHE VALUES", "more values than slots", .{}),
        error.ValueTooLarge => it.failCode("ZTCL FHE VALUES", "a value is too large or is not a number", .{}),
        error.BadCount => it.failCode("ZTCL FHE COUNT", "the count must be a power of two and at most the count of slots", .{}),
        error.BadParams => it.failCode("ZTCL FHE PARAMS", "the parameters are out of range", .{}),
        else => it.failCode("ZTCL FHE", "fhe: {t}", .{e}),
    };
}

fn handleIndex(s: *State, name: []const u8) ?usize {
    if (!std.mem.startsWith(u8, name, "fhe")) return null;
    const i = std.fmt.parseInt(usize, name[3..], 10) catch return null;
    if (i >= s.objs.items.len or s.objs.items[i] == null) return null;
    return i;
}

fn lookup(it: *Interp, s: *State, v: Value) Error!usize {
    const name = try it.str(v);
    return handleIndex(s, name) orelse it.failCode("ZTCL FHE HANDLE", "no fhe object \"{s}\"", .{name});
}

fn newHandle(it: *Interp, s: *State, o: Obj) Error!Value {
    try s.objs.append(it.heap.backing, o);
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "fhe{d}", .{s.objs.items.len - 1}) };
}

fn double(it: *Interp, v: Value) Error!f64 {
    const n = v.asNumber() orelse return it.fail("expected number but got \"{s}\"", .{try it.str(v)});
    return switch (n) {
        .int => |i| @floatFromInt(i),
        .double => |x| x,
        else => unreachable,
    };
}

fn doubles(it: *Interp, v: Value) Error![]f64 {
    const items = v.asList(it.alloc()) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return it.listError(v),
    };
    const out = try it.alloc().alloc(f64, items.len);
    for (out, items) |*o, x| o.* = try double(it, x);
    return out;
}

fn int(it: *Interp, v: Value) Error!i64 {
    return v.asInt() orelse it.fail("expected integer but got \"{s}\"", .{try it.str(v)});
}

fn isOpt(it: *Interp, v: Value, name: []const u8) Error!bool {
    return std.mem.eql(u8, try it.str(v), name);
}

const usage = "ztcl::fhe context|keys|encrypt|decrypt|add|mul|rotate|dot|gate|not|info|free ?arg ...?";

fn fheCmd(it: *Interp, argv: []const Value, _: ?*interp.Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs(usage);
    const sub = try it.str(argv[1]);
    const s = try state(it);
    const subs = .{
        .{ "context", contextCmd }, .{ "keys", keysCmd }, .{ "encrypt", encryptCmd },
        .{ "decrypt", decryptCmd }, .{ "add", addCmd },   .{ "mul", mulCmd },
        .{ "rotate", rotateCmd },   .{ "dot", dotCmd },   .{ "gate", gateCmd },
        .{ "not", notCmd },         .{ "info", infoCmd }, .{ "free", freeCmd },
    };
    inline for (subs) |e| {
        if (std.mem.eql(u8, sub, e[0])) return e[1](it, s, argv[2..]);
    }
    return it.fail("unknown subcommand \"{s}\": must be context, keys, encrypt, decrypt, add, mul, rotate, dot, gate, not, info, or free", .{sub});
}

fn contextCmd(it: *Interp, s: *State, args: []const Value) Error!Value {
    const use = "ztcl::fhe context ckks|tfhe ?-n size? ?-levels count?";
    if (args.len < 1 or args.len % 2 != 1) return it.wrongArgs(use);
    const scheme = try it.str(args[0]);
    if (std.mem.eql(u8, scheme, "tfhe")) {
        if (args.len != 1) return it.wrongArgs(use);
        const ctx = tfhe.Context.init(s.gpa(), tfhe.lib_128) catch |e| return libError(it, e);
        errdefer ctx.deinit();
        return newHandle(it, s, .{ .tfhe_ctx = .{ .ctx = ctx } });
    }
    if (!std.mem.eql(u8, scheme, "ckks")) return it.fail("unknown scheme \"{s}\": must be ckks or tfhe", .{scheme});
    var n: i64 = 8192;
    var levels: ?i64 = null;
    var k: usize = 1;
    while (k < args.len) : (k += 2) {
        if (try isOpt(it, args[k], "-n")) n = try int(it, args[k + 1]) else if (try isOpt(it, args[k], "-levels")) levels = try int(it, args[k + 1]) else return it.wrongArgs(use);
    }
    var params: ckks.Params = switch (n) {
        8192 => ckks.set_13,
        16384 => ckks.set_14,
        32768 => ckks.set_15,
        65536 => ckks.set_16,
        else => return it.failCode("ZTCL FHE PARAMS", "the size must be 8192, 16384, 32768, or 65536", .{}),
    };
    if (levels) |l| {
        if (l < 0 or l + 1 > ckks.max_primes) return libError(it, error.BadParams);
        params.levels = @intCast(l);
    }
    // The size of QP stays in the limit of the standard for 128 bits.
    const limit = ckks.Params.maxBits(params.log_n).?;
    if (params.totalBits() > limit) return it.failCode("ZTCL FHE PARAMS", "{d} levels give a modulus of {d} bits: the limit for 128-bit security at this size is {d} bits", .{ params.levels, params.totalBits(), limit });
    try charge(it, passUnits(@as(usize, 1) << params.log_n, @as(usize, params.levels) + 2));
    const ctx = ckks.Context.init(s.gpa(), params) catch |e| return libError(it, e);
    errdefer ctx.deinit();
    return newHandle(it, s, .{ .ckks_ctx = .{ .ctx = ctx } });
}

fn keysCmd(it: *Interp, s: *State, args: []const Value) Error!Value {
    const use = "ztcl::fhe keys context ?-rotations list? ?-sum count?";
    if (args.len < 1 or args.len % 2 != 1) return it.wrongArgs(use);
    const ci = try lookup(it, s, args[0]);
    const rng = s.csprng.random();
    switch (s.objs.items[ci].?) {
        .tfhe_ctx => |c| {
            if (args.len != 1) return it.wrongArgs(use);
            const p = c.ctx.params;
            // The bootstrap key has 4 * l transforms for each key bit.
            try charge(it, passUnits(p.big_n, p.n * 4 * p.bk_l * std.math.log2_int(u32, p.big_n)) + passUnits(p.n, p.big_n * p.ks_t * 3));
            const sk, const ck = tfhe.keygen(c.ctx, rng) catch |e| return libError(it, e);
            errdefer {
                sk.deinit(s.gpa());
                ck.deinit(s.gpa());
            }
            const h = try newHandle(it, s, .{ .tfhe_keys = .{ .sk = sk, .ck = ck, .ctx = ci } });
            s.objs.items[ci].?.tfhe_ctx.uses += 1;
            return h;
        },
        .ckks_ctx => |c| {
            const ctx = c.ctx;
            var rot: std.ArrayList(i64) = .empty;
            var k: usize = 1;
            while (k < args.len) : (k += 2) {
                if (try isOpt(it, args[k], "-rotations")) {
                    const items = args[k + 1].asList(it.alloc()) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return it.listError(args[k + 1]),
                    };
                    for (items) |x| try rot.append(it.alloc(), try int(it, x));
                } else if (try isOpt(it, args[k], "-sum")) {
                    const count = try int(it, args[k + 1]);
                    if (count < 1 or count > ctx.slots or !std.math.isPowerOfTwo(@as(u64, @intCast(count)))) return libError(it, error.BadCount);
                    var buf: [16]i64 = undefined;
                    try rot.appendSlice(it.alloc(), ckks.sumRotations(@intCast(count), &buf));
                } else return it.wrongArgs(use);
            }
            try charge(it, switchUnits(ctx, ctx.top()) * (rot.items.len + 2));
            var keys = ckks.keygen(ctx, rng, rot.items) catch |e| return libError(it, e);
            errdefer keys.deinit(ctx);
            const h = try newHandle(it, s, .{ .ckks_keys = .{ .keys = keys, .ctx = ci } });
            s.objs.items[ci].?.ckks_ctx.uses += 1;
            return h;
        },
        else => return it.fail("\"{s}\" is not a context", .{try it.str(args[0])}),
    }
}

fn newCt(it: *Interp, s: *State, keys: usize, ct: ckks.Ciphertext) Error!Value {
    const kobj = &s.objs.items[keys].?.ckks_keys;
    errdefer ct.deinit(s.ckksCtx(kobj.ctx));
    const h = try newHandle(it, s, .{ .ckks_ct = .{ .ct = ct, .keys = keys } });
    s.objs.items[keys].?.ckks_keys.uses += 1;
    return h;
}

fn newBit(it: *Interp, s: *State, keys: usize, words: []u32) Error!Value {
    errdefer s.gpa().free(words);
    const h = try newHandle(it, s, .{ .tfhe_ct = .{ .words = words, .keys = keys } });
    s.objs.items[keys].?.tfhe_keys.uses += 1;
    return h;
}

fn encryptCmd(it: *Interp, s: *State, args: []const Value) Error!Value {
    if (args.len != 2) return it.wrongArgs("ztcl::fhe encrypt keys values");
    const ki = try lookup(it, s, args[0]);
    const rng = s.csprng.random();
    switch (s.objs.items[ki].?) {
        .tfhe_keys => |*k| {
            const ctx = s.tfheCtx(k.ctx);
            const on = (try int(it, args[1])) != 0;
            const words = try s.gpa().alloc(u32, ctx.lweLen());
            tfhe.encryptBit(ctx, &k.sk, rng, on, words);
            return newBit(it, s, ki, words);
        },
        .ckks_keys => |*k| {
            const ctx = s.ckksCtx(k.ctx);
            const vals = try doubles(it, args[1]);
            try charge(it, passUnits(ctx.n, 4 * ctx.nq * ctx.params.log_n));
            const ct = ckks.encryptValues(ctx, &k.keys, rng, vals) catch |e| return libError(it, e);
            return newCt(it, s, ki, ct);
        },
        else => return it.fail("\"{s}\" is not a key set", .{try it.str(args[0])}),
    }
}

fn decryptCmd(it: *Interp, s: *State, args: []const Value) Error!Value {
    if (args.len < 2 or args.len > 3) return it.wrongArgs("ztcl::fhe decrypt keys ciphertext ?count?");
    const ki = try lookup(it, s, args[0]);
    const ci = try lookup(it, s, args[1]);
    switch (s.objs.items[ci].?) {
        .tfhe_ct => |c| {
            if (c.keys != ki) return it.fail("the ciphertext is not of these keys", .{});
            return .{ .int = @intFromBool(tfhe.decryptBit(&s.objs.items[ki].?.tfhe_keys.sk, c.words)) };
        },
        .ckks_ct => |c| {
            if (c.keys != ki) return it.fail("the ciphertext is not of these keys", .{});
            const k = &s.objs.items[ki].?.ckks_keys;
            const ctx = s.ckksCtx(k.ctx);
            var count: usize = ctx.slots;
            if (args.len == 3) {
                const want = try int(it, args[2]);
                if (want < 0 or want > ctx.slots) return libError(it, error.TooManyValues);
                count = @intCast(want);
            }
            try charge(it, passUnits(ctx.n, (c.ct.level + 1) * (ctx.params.log_n + c.ct.level + 2)));
            const vals = ckks.decrypt(ctx, &k.keys, c.ct) catch |e| return libError(it, e);
            defer s.gpa().free(vals);
            const list = try value.allocList(it.alloc(), count);
            for (list.obj.buf, vals[0..count]) |*o, x| o.* = .{ .double = x };
            return .{ .list = list };
        },
        else => return it.fail("\"{s}\" is not a ciphertext", .{try it.str(args[1])}),
    }
}

/// The second operand of add, mul, and dot: a ciphertext, one number,
/// or a list of numbers.
const Operand = union(enum) { ct: ckks.Ciphertext, scalar: f64, list: []f64 };

const Pair = struct { keys: usize, k: *const ckks.Keys, ctx: *ckks.Context, a: ckks.Ciphertext, b: Operand };

fn pair(it: *Interp, s: *State, av: Value, bv: Value) Error!Pair {
    const ai = try lookup(it, s, av);
    const a = switch (s.objs.items[ai].?) {
        .ckks_ct => |c| c,
        else => return it.fail("\"{s}\" is not a CKKS ciphertext", .{try it.str(av)}),
    };
    const kobj = &s.objs.items[a.keys].?.ckks_keys;
    var b: Operand = undefined;
    if (handleIndex(s, try it.str(bv))) |bi| {
        const c = switch (s.objs.items[bi].?) {
            .ckks_ct => |c| c,
            else => return it.fail("\"{s}\" is not a CKKS ciphertext", .{try it.str(bv)}),
        };
        if (c.keys != a.keys) return it.fail("the two ciphertexts have different keys", .{});
        b = .{ .ct = c.ct };
    } else if (bv.asNumber() != null) {
        b = .{ .scalar = try double(it, bv) };
    } else b = .{ .list = try doubles(it, bv) };
    return .{ .keys = a.keys, .k = &kobj.keys, .ctx = s.ckksCtx(kobj.ctx), .a = a.ct, .b = b };
}

fn addCmd(it: *Interp, s: *State, args: []const Value) Error!Value {
    if (args.len != 2) return it.wrongArgs("ztcl::fhe add ciphertext ciphertextOrValues");
    const p = try pair(it, s, args[0], args[1]);
    try charge(it, passUnits(p.ctx.n, 2 * (p.a.level + 1) * p.ctx.params.log_n));
    const r = switch (p.b) {
        .ct => |b| ckks.add(p.ctx, p.a, b),
        .scalar => |c| ckks.addScalar(p.ctx, p.a, c),
        .list => |l| ckks.addPlain(p.ctx, p.a, l),
    } catch |e| return libError(it, e);
    return newCt(it, s, p.keys, r);
}

fn mulCmd(it: *Interp, s: *State, args: []const Value) Error!Value {
    if (args.len != 2) return it.wrongArgs("ztcl::fhe mul ciphertext ciphertextOrValues");
    const p = try pair(it, s, args[0], args[1]);
    try charge(it, switch (p.b) {
        .ct => switchUnits(p.ctx, p.a.level),
        else => passUnits(p.ctx.n, 4 * (p.a.level + 1) * p.ctx.params.log_n),
    });
    const r = switch (p.b) {
        .ct => |b| ckks.mul(p.ctx, p.k, p.a, b),
        .scalar => |c| ckks.mulScalar(p.ctx, p.a, c),
        .list => |l| ckks.mulPlain(p.ctx, p.a, l),
    } catch |e| return libError(it, e);
    return newCt(it, s, p.keys, r);
}

fn rotateCmd(it: *Interp, s: *State, args: []const Value) Error!Value {
    if (args.len != 2) return it.wrongArgs("ztcl::fhe rotate ciphertext steps");
    const p = try pair(it, s, args[0], .{ .int = 0 });
    const steps = try int(it, args[1]);
    try charge(it, switchUnits(p.ctx, p.a.level));
    const r = ckks.rotate(p.ctx, p.k, p.a, steps) catch |e| return libError(it, e);
    return newCt(it, s, p.keys, r);
}

fn dotCmd(it: *Interp, s: *State, args: []const Value) Error!Value {
    if (args.len < 2 or args.len > 3) return it.wrongArgs("ztcl::fhe dot ciphertext ciphertextOrValues ?count?");
    const p = try pair(it, s, args[0], args[1]);
    var count: usize = switch (p.b) {
        .list => |l| std.math.ceilPowerOfTwo(usize, @max(l.len, 1)) catch return libError(it, error.BadCount),
        else => p.ctx.slots,
    };
    if (args.len == 3) {
        const want = try int(it, args[2]);
        if (want < 1) return libError(it, error.BadCount);
        count = @intCast(want);
    }
    if (!std.math.isPowerOfTwo(count) or count > p.ctx.slots) return libError(it, error.BadCount);
    try charge(it, switchUnits(p.ctx, p.a.level) * (1 + std.math.log2_int(usize, count)));
    const prod = switch (p.b) {
        .ct => |b| ckks.mul(p.ctx, p.k, p.a, b),
        .scalar => |c| ckks.mulScalar(p.ctx, p.a, c),
        .list => |l| ckks.mulPlain(p.ctx, p.a, l),
    } catch |e| return libError(it, e);
    defer prod.deinit(p.ctx);
    const r = ckks.sumSlots(p.ctx, p.k, prod, count) catch |e| return libError(it, e);
    return newCt(it, s, p.keys, r);
}

fn bit(it: *Interp, s: *State, v: Value) Error!@FieldType(Obj, "tfhe_ct") {
    const i = try lookup(it, s, v);
    return switch (s.objs.items[i].?) {
        .tfhe_ct => |c| c,
        else => it.fail("\"{s}\" is not a TFHE ciphertext", .{try it.str(v)}),
    };
}

fn gateCmd(it: *Interp, s: *State, args: []const Value) Error!Value {
    if (args.len != 3) return it.wrongArgs("ztcl::fhe gate nand|and|or|xor|nor|xnor a b");
    const op = std.meta.stringToEnum(tfhe.Gate, try it.str(args[0])) orelse return it.fail("unknown gate \"{s}\": must be nand, and, or, xor, nor, or xnor", .{try it.str(args[0])});
    const a = try bit(it, s, args[1]);
    const b = try bit(it, s, args[2]);
    if (a.keys != b.keys) return it.fail("the two ciphertexts have different keys", .{});
    const k = &s.objs.items[a.keys].?.tfhe_keys;
    const ctx = s.tfheCtx(k.ctx);
    const p = ctx.params;
    // Each key bit has 2 * l + 2 transforms of log2(N) passes.
    try charge(it, passUnits(p.big_n, p.n * (2 * p.bk_l + 2) * std.math.log2_int(u32, p.big_n)));
    const words = try s.gpa().alloc(u32, ctx.lweLen());
    tfhe.gate(ctx, &k.ck, op, a.words, b.words, words) catch |e| {
        s.gpa().free(words);
        return libError(it, e);
    };
    return newBit(it, s, a.keys, words);
}

fn notCmd(it: *Interp, s: *State, args: []const Value) Error!Value {
    if (args.len != 1) return it.wrongArgs("ztcl::fhe not a");
    const a = try bit(it, s, args[0]);
    const words = try s.gpa().alloc(u32, a.words.len);
    tfhe.not(a.words, words);
    return newBit(it, s, a.keys, words);
}

fn infoCmd(it: *Interp, s: *State, args: []const Value) Error!Value {
    if (args.len != 1) return it.wrongArgs("ztcl::fhe info object");
    const i = try lookup(it, s, args[0]);
    const a = it.alloc();
    const text = switch (s.objs.items[i].?) {
        .ckks_ctx => |c| try std.fmt.allocPrint(a, "kind context scheme ckks n {d} slots {d} levels {d} bits {d}", .{ c.ctx.n, c.ctx.slots, c.ctx.params.levels, c.ctx.params.totalBits() }),
        .ckks_keys => |k| try std.fmt.allocPrint(a, "kind keys scheme ckks secret {d} public {d} relin {d} galois {d} rotations {d}", .{ k.keys.secretBytes(), k.keys.publicBytes(), k.keys.relin.bytes(), k.keys.galoisBytes(), k.keys.galois.count() }),
        .ckks_ct => |c| try std.fmt.allocPrint(a, "kind ciphertext scheme ckks level {d} bytes {d}", .{ c.ct.level, c.ct.bytes() }),
        .tfhe_ctx => |c| try std.fmt.allocPrint(a, "kind context scheme tfhe n {d} N {d}", .{ c.ctx.params.n, c.ctx.params.big_n }),
        .tfhe_keys => |k| try std.fmt.allocPrint(a, "kind keys scheme tfhe secret {d} cloud {d}", .{ k.sk.lwe.len + k.sk.ring.len, k.ck.bytes() }),
        .tfhe_ct => |c| try std.fmt.allocPrint(a, "kind ciphertext scheme tfhe bytes {d}", .{c.words.len * 4}),
    };
    return .{ .str = text };
}

fn freeCmd(it: *Interp, s: *State, args: []const Value) Error!Value {
    for (args) |v| {
        const i = try lookup(it, s, v);
        const uses = switch (s.objs.items[i].?) {
            .ckks_ctx => |c| c.uses,
            .ckks_keys => |k| k.uses,
            .tfhe_ctx => |c| c.uses,
            .tfhe_keys => |k| k.uses,
            else => 0,
        };
        if (uses != 0) return it.failCode("ZTCL FHE INUSE", "\"{s}\" has {d} objects that use it", .{ try it.str(v), uses });
        freeObj(s, i);
    }
    return Value.empty;
}

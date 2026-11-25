//! The JIT compiler: the state of one interpreter, its options, and its
//! counts.
//!
//! The JIT is off by default. An embedder turns it on with
//! `Interp.enableJit`. A script cannot turn it on or see it. Each
//! interpreter has its own state, and a child gets a state only when its
//! parent has one.
//!
//! All memory of the JIT comes from the allocator of the embedder
//! (`counter.child`), outside the heap of the scripts. So `memUsed` and
//! the memory limit of a script do not change when the JIT is on.
//!
//! A `Code` points to its compiled function only through a generation
//! number. `flush` gets a new number, so a `Code` that outlives a flush
//! runs in the interpreter and is never compiled with stale data.
//!
//! The stress modes (`Options.stress`) force the rare paths. Each one
//! keeps the output of a script:
//!
//! - 1: the allocations of the compiler fail in turn. Compile k fails
//!   its allocation `fail_from + k - 1`. After a compile with no failure,
//!   the count starts again. A compile of tier 2 counts as a compile.
//! - 2: each second copy to the executable region fails.
//! - 4: a checksum of each function is taken after the copy and checked
//!   at each `enter` and at `flush`. A difference ends the process. The
//!   code of a tier 2 loop has its own checksum, and `tier_up` and
//!   `flush` check it.
//! - 8: each `enter` runs one instruction with its helper first, then
//!   enters the machine code at the next address. So each reachable
//!   address is an entry. An entry check that fails there ends the
//!   process, because the depth of the verifier and of the compiler
//!   then differ.
//! - 16: the JIT memory limit is 64 KiB.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const interp = @import("interp.zig");

const Allocator = std.mem.Allocator;
const Interp = interp.Interp;
const vm = @import("vm.zig");
const Value = @import("value.zig").Value;

/// The context of one entry into machine code. It lives on the native
/// stack of `enter`. The machine code reads its inputs and writes `pc`,
/// `sp`, and `err` on an error or an exit.
pub const EnterCtx = extern struct {
    it: *Interp,
    code: *const vm.Code,
    frame: *interp.Frame,
    stack: [*]Value,
    helpers: [*]const *const anyopaque,
    /// The address to jump to.
    target: usize,
    pc: u32,
    sp: u32,
    /// `@intFromError` of the error of status 1.
    err: u16,
    /// `Value.empty`, for the code of `push_empty`.
    empty: *const Value,
    /// The pass counters of the loop heads of the function.
    counters: [*]u32,
    /// The function (`Fn`).
    func: *anyopaque,
};

/// True when this target has a backend: x86-64 Linux and arm64 macOS.
/// Each backend has tier 1 and tier 2.
pub const backend = (builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux) or
    (builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos);
const t2_arm = builtin.cpu.arch == .aarch64;
const tier2_be = if (t2_arm) @import("jit/tier2_a64.zig") else tier2_x64;

/// True when the build has the JIT and the target has a backend.
pub const built = options.jit and backend;

pub const Options = struct {
    /// Calls of a Code before it compiles. 0 compiles before the first run.
    threshold: u32 = 2,
    /// The most bytes for the executable region and all JIT data.
    mem_limit: usize = 16 << 20,
    tier2: bool = false,
    /// The passes of a loop in tier 1 before tier 2 compiles it.
    tier2_count: u32 = 1000,
    /// A set of the `stress_` bits.
    stress: u32 = 0,
    /// Stress mode 1: the allocation that the first compile fails.
    fail_from: u32 = 1,
    /// Gets the bytes of each new function, for a test of the code. The
    /// library does no file I/O: the runner writes the files.
    on_code: ?*const fn (ctx: ?*anyopaque, bytes: []const u8) void = null,
    on_code_ctx: ?*anyopaque = null,
};

pub const stress_alloc: u32 = 1;
pub const stress_region: u32 = 2;
pub const stress_sum: u32 = 4;
pub const stress_entry: u32 = 8;
pub const stress_small: u32 = 16;
pub const stress_all: u32 = 31;

pub const Stats = struct {
    compiled: u64 = 0,
    failed: u64 = 0,
    code_bytes: u64 = 0,
    data_bytes: u64 = 0,
    fallbacks: u64 = 0,
    tier2: u64 = 0,
    exits: u64 = 0,
    /// The bytecode instructions of the compiled functions.
    ins: u64 = 0,
    /// The bytes of the functions of named code: pages and records.
    named_bytes: u64 = 0,
    /// The named Code values that stayed in the interpreter because the
    /// part of named code was full.
    named_stops: u64 = 0,
};

pub const State = struct {
    options: Options,
    stats: Stats = .{},
    /// The allocator of the embedder.
    backing: Allocator,
    /// The generation of the compiled functions. Each flush and each new
    /// state gets a new number from `next_gen`.
    gen: u64,
    /// The facts of the layout probe.
    layout: layout_mod.Layout,
    /// The executable region. The first compile reserves it.
    region: ?mem.Region = null,
    /// Each compiled function, for `flush`.
    fns: std.ArrayList(*tier1.Fn) = .empty,
    /// The state of the parent interpreter. The JIT memory limit holds
    /// for an interpreter and its children together.
    parent: ?*State = null,
    /// The bytes of the pages and the records of this state.
    used: usize = 0,
    /// The bytes of this state and of each child state.
    family: usize = 0,
    /// The bytes of the named code of this state, and of this state and
    /// each child state. Named code has a quarter of the JIT memory
    /// limit, so the procs always have the rest.
    named_used: usize = 0,
    named_family: usize = 0,
    /// True after a named Code did not fit in the part of named code.
    named_full: bool = false,
    /// True after a system call of the region failed.
    stopped: bool = false,
    /// The error of the last entry that failed.
    err: u16 = 0,
    /// Stress mode 1: the allocation of the next compile that fails.
    fail_next: u32 = 0,

    /// The JIT memory limit of this state.
    fn limit(s: *const State) usize {
        return if (s.options.stress & stress_small != 0) 64 << 10 else s.options.mem_limit;
    }

    fn root(s: *State) *State {
        var r = s;
        while (r.parent) |p| r = p;
        return r;
    }

    fn charge(s: *State, n: usize, named: bool) void {
        s.used += n;
        s.root().family += n;
        if (!named) return;
        s.named_used += n;
        s.root().named_family += n;
    }

    fn uncharge(s: *State) void {
        s.root().family -= s.used;
        s.used = 0;
        s.root().named_family -= s.named_used;
        s.named_used = 0;
        s.named_full = false;
    }

    /// The bytes left in the part of named code.
    fn namedBudget(s: *State) usize {
        return @min(s.budget(), (s.limit() / 4) -| s.root().named_family);
    }

    fn budget(s: *State) usize {
        return s.limit() -| s.root().family;
    }
};

const layout_mod = @import("jit/layout.zig");
const mem = @import("jit/mem.zig");
const tier1 = @import("jit/tier1.zig");
const helpers = @import("jit/helpers.zig");
const gc = @import("gc.zig");

pub const Fn = tier1.Fn;

/// The parts of the JIT for the tests and the fuzzers of
/// `tools/jit-fuzz.zig`. An embedder does not use them.
pub const parts = struct {
    pub const vm = @import("vm.zig");
    pub const verify = @import("jit/verify.zig");
    pub const x64 = @import("jit/x64.zig");
    pub const a64 = @import("jit/a64.zig");
    pub const mem = @import("jit/mem.zig");
    pub const tier1 = @import("jit/tier1.zig");
};

/// The result of the checks of `usable`, for the whole process.
var usable_state = std.atomic.Value(u8).init(0);

/// True when the layout probe passes and a function in executable
/// memory returns its constant. The result stays for the process.
fn usable() ?layout_mod.Layout {
    const l = layout_mod.probe() orelse return null;
    switch (usable_state.load(.acquire)) {
        1 => return l,
        2 => return null,
        else => {},
    }
    const ok = mem.selfTest();
    usable_state.store(if (ok) 1 else 2, .release);
    return if (ok) l else null;
}

/// The source of generation numbers. Zero is never used, so a `Code`
/// with generation zero has no function.
var next_gen = std.atomic.Value(u64).init(1);

fn newGen() u64 {
    return next_gen.fetchAdd(1, .monotonic);
}

/// Turns the JIT on for `it`. Returns false and changes no state when
/// the build has no JIT, the layout probe fails, or the system has no
/// executable memory. A build with the precise roots of WebAssembly
/// (`-Dgc-precise`) has no JIT.
pub fn enable(it: *Interp, opts: Options) bool {
    // The counter of a child wraps the counted allocator of its root. So
    // the JIT data of each interpreter comes from the allocator of the
    // embedder under the root, outside the memory count of the scripts.
    var root: *Interp = it;
    while (root.parent) |p| root = p;
    return enableWith(it, opts, root.counter.child);
}

fn enableWith(it: *Interp, opts: Options, a: Allocator) bool {
    if (!built or gc.precise) return false;
    if (it.jit) |s| {
        s.options = opts;
        return true;
    }
    const l = usable() orelse return false;
    const s = a.create(State) catch return false;
    s.* = .{ .options = opts, .backing = a, .gen = newGen(), .layout = l };
    it.jit = s;
    return true;
}

/// Turns the JIT on for a new child when its parent has it.
pub fn inherit(child: *Interp, parent: *const Interp) void {
    if (!built) return;
    const p = parent.jit orelse return;
    if (!enable(child, p.options)) return;
    child.jit.?.parent = p;
}

/// Frees each compiled function of `it` and its executable region. The
/// state and its options stay. Call it only when no script of `it`
/// runs, and when no `Code` of the old generation can run again.
pub fn flush(it: *Interp) void {
    if (!built) return;
    const s = it.jit orelse return;
    for (s.fns.items) |f| {
        if (s.options.stress & stress_sum != 0) {
            checkSum(f);
            for (f.loops) |*rec| checkLoopSum(rec);
        }
        f.free(s.backing);
    }
    s.fns.clearAndFree(s.backing);
    if (s.region) |*r| r.deinit();
    s.region = null;
    s.uncharge();
    s.gen = newGen();
}

/// Frees the state of `it`.
pub fn destroy(it: *Interp) void {
    if (!built) return;
    const s = it.jit orelse return;
    flush(it);
    it.jit = null;
    s.backing.destroy(s);
}

/// True when `code` has a loop. Each loop of the bytecode compiler has a
/// `step` or a `foreach_next`. A jump back from a cold block is no loop.
fn hasLoop(code: *const vm.Code) bool {
    for (code.ins) |i| {
        if (i.op == .step or i.op == .foreach_next) return true;
    }
    return false;
}

/// The function of a Code whose state is `ready`, when it is of the
/// current generation. `prepare` gives the same function for it.
pub inline fn readyFn(it: *Interp, code: *vm.Code) ?*Fn {
    if (code.jit_gen != it.jit.?.gen) return null;
    return @ptrCast(@alignCast(code.jit.?));
}

/// The function of `code`, after a compile when the count of calls
/// reaches the threshold. Null runs the interpreter. No failure is an
/// error of a script.
pub fn prepare(it: *Interp, code: *vm.Code) ?*Fn {
    const s = it.jit.?;
    switch (code.jit_state) {
        .ready => {
            // A function of another generation or another state is never
            // read. The code then stays in the interpreter.
            if (code.jit_gen != s.gen) return null;
            return @ptrCast(@alignCast(code.jit.?));
        },
        .failed => return null,
        .untried => {},
    }
    code.jit_calls +|= 1;
    // A body with a loop compiles at its first call, so a later call
    // needs no scan.
    if (code.jit_calls < s.options.threshold and (code.jit_calls > 1 or !hasLoop(code))) return null;
    return compileCode(s, code);
}

/// An allocator that fails allocation number `at` of the compiler, for
/// stress mode 1. A larger resize counts as an allocation.
const FailAlloc = struct {
    child: Allocator,
    n: u32 = 0,
    at: u32,
    failed: bool = false,

    fn allocator(fa: *FailAlloc) Allocator {
        return .{ .ptr = fa, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn fails(fa: *FailAlloc) bool {
        fa.n += 1;
        if (fa.n != fa.at) return false;
        fa.failed = true;
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const fa: *FailAlloc = @ptrCast(@alignCast(ctx));
        if (fa.fails()) return null;
        return fa.child.rawAlloc(len, al, ra);
    }

    fn resize(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
        const fa: *FailAlloc = @ptrCast(@alignCast(ctx));
        if (n > m.len and fa.fails()) return false;
        return fa.child.rawResize(m, al, n, ra);
    }

    fn remap(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const fa: *FailAlloc = @ptrCast(@alignCast(ctx));
        if (n > m.len and fa.fails()) return null;
        return fa.child.rawRemap(m, al, n, ra);
    }

    fn free(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const fa: *FailAlloc = @ptrCast(@alignCast(ctx));
        fa.child.rawFree(m, al, ra);
    }
};

/// The checksum of the bytes of a function.
fn sumOf(f: *const Fn) u64 {
    return std.hash.Wyhash.hash(0, f.base[0..f.len]);
}

/// Ends the process when the bytes of `f` changed after the copy.
fn checkSum(f: *const Fn) void {
    if (sumOf(f) != f.sum) @panic("the bytes of a JIT function changed");
}

/// The bytes of the tier 2 code of a loop.
fn loopBytes(rec: *const tier1.Loop) []const u8 {
    const c = rec.code orelse return &.{};
    return c[0..rec.len];
}

/// Ends the process when the bytes of the tier 2 code of a loop changed
/// after the copy.
fn checkLoopSum(rec: *const tier1.Loop) void {
    if (rec.code == null) return;
    if (std.hash.Wyhash.hash(0, loopBytes(rec)) != rec.sum) @panic("the bytes of a tier 2 loop changed");
}

/// The allocator of one compile. In stress mode 1 it fails one
/// allocation of the schedule.
fn compileAlloc(s: *State, fa: *FailAlloc) Allocator {
    if (s.options.stress & stress_alloc == 0) return s.backing;
    if (s.fail_next == 0) s.fail_next = s.options.fail_from;
    fa.* = .{ .child = s.backing, .at = s.fail_next };
    return fa.allocator();
}

/// Moves the schedule of stress mode 1 after one compile.
fn compileDone(s: *State, fa: *const FailAlloc) void {
    if (s.options.stress & stress_alloc == 0) return;
    s.fail_next = if (fa.failed) s.fail_next + 1 else s.options.fail_from;
}

fn compileCode(s: *State, code: *vm.Code) ?*Fn {
    code.jit_state = .failed;
    if (s.stopped) return null;
    // An event script parses its script again at each event, so the
    // bodies of its loops are new named Code values at each event. They
    // have their own part of the JIT memory.
    if (code.named and s.named_full) {
        s.stats.named_stops += 1;
        return null;
    }
    if (s.region == null) {
        s.region = mem.Region.init(s.limit()) orelse {
            s.stopped = true;
            return null;
        };
    }
    const r = &s.region.?;
    r.fail_second = s.options.stress & stress_region != 0;
    var fa: FailAlloc = .{ .child = s.backing, .at = 0 };
    const a = compileAlloc(s, &fa);
    defer compileDone(s, &fa);
    s.fns.ensureUnusedCapacity(a, 1) catch {
        s.stats.failed += 1;
        return null;
    };
    // A named Code stays in tier 1. Tier 2 reads each slot from its cell
    // in the frame, and a named Code reads each variable by its name.
    const tier2_count: u32 = if (s.options.tier2 and !code.named) @max(s.options.tier2_count, 1) else 0;
    const bud = if (code.named) s.namedBudget() else s.budget();
    switch (tier1.compile(a, r, s.layout, code, bud, tier2_count)) {
        .ok => |f| {
            if (s.options.stress & stress_sum != 0) f.sum = sumOf(f);
            f.enter_stress = s.options.stress & (stress_sum | stress_entry) != 0;
            if (s.options.on_code) |cb| cb(s.options.on_code_ctx, f.base[0..f.len]);
            s.fns.appendAssumeCapacity(f);
            const n = f.pages(r.page) + f.bytes();
            s.charge(n, code.named);
            if (code.named) s.stats.named_bytes += n;
            s.stats.compiled += 1;
            s.stats.code_bytes += f.len;
            s.stats.data_bytes += f.bytes();
            s.stats.ins += code.ins.len;
            code.jit = f;
            code.jit_gen = s.gen;
            code.jit_state = .ready;
            return f;
        },
        .stopped => s.stopped = true,
        .full => if (code.named) {
            s.named_full = true;
            s.stats.named_stops += 1;
        },
        .failed => {},
    }
    s.stats.failed += 1;
    return null;
}

const Error = interp.Error;

/// The result of `enter`.
pub const Status = enum { done, failed, fallback };

/// Runs the function `f` of `code` from `pc.*` with depth `sp.*`.
/// `.done`: the result is at `stack[sp.* - 1]`. `.failed`: `lastError`
/// gives the error, and `pc.*` and `sp.*` are its place, as with `exec`.
/// `.fallback`: the entry is not valid, or the code exits, and `exec`
/// runs at `pc.*` and `sp.*`.
pub fn enter(it: *Interp, f: *Fn, code: *vm.Code, stack: [*]Value, pc: *u32, sp: *u32) Status {
    // One byte of the record keeps the stress checks off the path of
    // each proc call.
    if (f.enter_stress) {
        if (enterStress(it, f, code, stack, pc, sp)) |st| return st;
    }
    const p = pc.*;
    const frame = it.frame;
    if (p >= code.ins.len or p >= f.entries.len) return fallback(it);
    const off = f.entries[p];
    if (off == tier1.no_entry or off >= f.len) return fallback(it);
    if (sp.* != f.depth[p]) return fallback(it);
    // A named Code runs in any frame: its variables go by name, so its
    // record has no least frame size.
    if (frame.vars.items.len < f.min_vars) return fallback(it);
    var ctx: EnterCtx = .{
        .it = it,
        .code = code,
        .frame = frame,
        .stack = stack,
        .helpers = f.helpers,
        .target = @intFromPtr(f.base) + off,
        .pc = p,
        .sp = sp.*,
        .err = 0,
        .empty = &Value.empty,
        .counters = f.counters.ptr,
        .func = f,
    };
    const func: *const fn (*EnterCtx) callconv(.c) u32 = @ptrCast(@alignCast(f.base));
    mem.checkClosed();
    const status = func(&ctx);
    pc.* = ctx.pc;
    sp.* = ctx.sp;
    if (status == tier1.status_done) return .done;
    if (status == tier1.status_error) {
        it.jit.?.err = ctx.err;
        return .failed;
    }
    return fallback(it);
}

/// Stress modes 4 and 8 at an entry. A status ends the entry.
noinline fn enterStress(it: *Interp, f: *Fn, code: *vm.Code, stack: [*]Value, pc: *u32, sp: *u32) ?Status {
    const stress = it.jit.?.options.stress;
    if (stress & stress_sum != 0) checkSum(f);
    if (stress & stress_entry != 0) return stepOne(it, f, code, stack, pc, sp);
    return null;
}

/// Stress mode 8: runs instruction `pc.*` with its helper, as `exec`
/// does, and moves `pc.*` and `sp.*` to the next instruction. A status
/// ends the entry: `ret`, an error, or an entry check that fails.
fn stepOne(it: *Interp, f: *Fn, code: *vm.Code, stack: [*]Value, pc: *u32, sp: *u32) ?Status {
    const p = pc.*;
    if (p >= code.ins.len or p >= f.entries.len or f.entries[p] == tier1.no_entry) return null;
    if (sp.* != f.depth[p] or (!code.named and it.frame.vars.items.len < code.names.len)) return null;
    const i = &code.ins[p];
    const h = helpers.forIns(i) orelse return .done;
    var ctx: EnterCtx = .{
        .it = it,
        .code = code,
        .frame = it.frame,
        .stack = stack,
        .helpers = helpers.tableFor(code),
        .target = 0,
        .pc = p,
        .sp = sp.*,
        .err = 0,
        .empty = &Value.empty,
        .counters = f.counters.ptr,
        .func = f,
    };
    const func: helpers.Fn = @ptrCast(@alignCast(helpers.tableFor(code)[@intFromEnum(h)]));
    const r = func(&ctx, p, sp.*);
    if (r == helpers.failed) {
        it.jit.?.err = ctx.err;
        return .failed;
    }
    const n = helpers.next(i, p, r);
    if (n >= f.entries.len or f.entries[n] == tier1.no_entry) @panic("stress mode 8: the next address has no entry");
    pc.* = n;
    sp.* = f.depth[n];
    return null;
}

// ---- Tier 2 ----

const tier2 = @import("jit/tier2.zig");
const tier2_x64 = @import("jit/tier2_x64.zig");
const verify = @import("jit/verify.zig");

/// The helper `tier_up`: the counter of the loop head `pc` reached zero.
/// The first call compiles the loop. The result is the address of its
/// tier 2 code, or 0. The address comes from the record of the loop in
/// the function of the context, so it is the entry of a tier 2 function
/// of this loop.
pub fn tierUp(ctx: *EnterCtx, pc: u32, sp: u32) callconv(.c) usize {
    _ = sp;
    const s = ctx.it.jit orelse return 0;
    const f: *Fn = @ptrCast(@alignCast(ctx.func));
    const k = std.mem.indexOfScalar(u32, f.heads, pc) orelse return 0;
    const rec = &f.loops[k];
    if (rec.exits >= max_exits) {
        f.counters[k] = std.math.maxInt(u32);
        return 0;
    }
    if (!rec.tried) {
        rec.tried = true;
        if (compileLoop(s, ctx.code, ctx.frame, pc, @intCast(k), @intCast(f.heads.len), &rec.counts)) |placed| {
            rec.code = placed.ptr;
            rec.len = @intCast(placed.len);
            if (s.options.stress & stress_sum != 0) rec.sum = std.hash.Wyhash.hash(0, placed);
        }
    }
    if (s.options.stress & stress_sum != 0) checkLoopSum(rec);
    // A loop with calls that runs few passes for each entry uses more
    // instructions in tier 2 than in tier 1: the entry block, the exit,
    // and the calls of `tier_up` and `resume_at`. After `probe_entries`
    // entries, such a loop runs in tier 1 only.
    if (rec.code != null and rec.counts) {
        rec.entries +|= 1;
        if (rec.entries == probe_entries and f.counters.len == 2 * f.loops.len + 1 and
            f.counters[f.loops.len + 1 + k] < probe_entries * min_passes)
        {
            rec.code = null;
        }
    }
    // A compiled loop runs in tier 2 again at the next pass of its head
    // in tier 1. A loop that does not compile runs in tier 1 only.
    const c = rec.code orelse {
        f.counters[k] = std.math.maxInt(u32);
        return 0;
    };
    mem.checkClosed();
    f.counters[k] = 1;
    return @intFromPtr(c);
}

/// The stress mode of tier 2: each guard fails on a schedule.
pub const stress_guards: u32 = 32;

/// The failed guards of one loop before the loop runs in tier 1 only.
pub const max_exits = 8;

/// The entries of a loop with calls before the check of its passes, and
/// the least mean count of passes for each entry that keeps it in tier 2.
pub const probe_entries = 64;
pub const min_passes = 16;

/// The helper `resume_at`: the address of the tier 1 code of `pc` when
/// the entry checks of `enter` pass. Else it writes `pc` and `sp` to the
/// context and gives 0, and the code returns status 2. `kind` has the
/// number of the loop in its low bits and the kind of the exit in its
/// high bits. After `max_exits` failed guards that the stress mode did
/// not force, the loop is dropped: tier 1 no longer counts its passes.
/// After an exit at a loop head, tier 1 runs one pass of that loop
/// before it calls `tier_up` again.
pub fn resumeAt(ctx: *EnterCtx, pc: u32, sp: u32, kind: u32) callconv(.c) usize {
    const f: *Fn = @ptrCast(@alignCast(ctx.func));
    const k = kind & 0xFFFF;
    if (kind & (tier2_x64.exit_guard | tier2_x64.exit_forced) != 0) {
        if (ctx.it.jit) |s| s.stats.exits += 1;
    }
    if (k < f.loops.len and f.counters.len == 2 * f.loops.len + 1) {
        if (kind & tier2_x64.exit_forced != 0) {
            f.stress_at = @intCast((f.stress_at + 1) % tier1.stress_counts.len);
            f.counters[f.loops.len] = tier1.stress_counts[f.stress_at];
        } else if (kind & tier2_x64.exit_guard != 0) {
            const rec = &f.loops[k];
            rec.exits +|= 1;
            if (rec.exits >= max_exits) {
                rec.code = null;
                f.counters[k] = std.math.maxInt(u32);
            }
        }
        // An exit at a loop head resumes at the pass counter of tier 1,
        // which comes before the step check of the head. With a counter
        // of 1, tier 1 calls `tier_up` at once, and a step check that
        // failed in tier 2 fails again with no step taken. A counter of
        // 2 makes tier 1 run one pass with its own step checks first.
        if (std.mem.indexOfScalar(u32, f.heads, pc)) |j| {
            if (f.counters[j] < 2) f.counters[j] = 2;
        }
    }
    if (pc < f.entries.len and pc < f.depth.len and f.depth[pc] == sp) {
        const off = f.entries[pc];
        if (off != tier1.no_entry and off < f.len) return @intFromPtr(f.base) + off;
    }
    ctx.pc = pc;
    ctx.sp = sp;
    return 0;
}

/// Compiles the loop at `head` with the kinds of the cells of `frame`
/// now. Null when the loop is not eligible or a step fails.
fn compileLoop(s: *State, code: *const vm.Code, frame: *interp.Frame, head: u32, loop: u32, heads: u32, counts: *bool) ?[]const u8 {
    if (s.stopped or code.named) return null;
    var fa: FailAlloc = .{ .child = s.backing, .at = 0 };
    const a = compileAlloc(s, &fa);
    defer compileDone(s, &fa);
    var info = (verify.verify(a, code) catch return null) orelse return null;
    defer info.deinit(a);
    const kinds = a.alloc(tier2.Kind, code.names.len) catch return null;
    defer a.free(kinds);
    for (kinds, 0..) |*kd, slot| {
        kd.* = .any;
        if (slot >= frame.vars.items.len) continue;
        const cell = frame.vars.items[slot].cell;
        if (cell.v != .val) continue;
        kd.* = switch (cell.v.val) {
            .int => .int,
            .double => .double,
            else => .any,
        };
    }
    var p = (tier2.plan(a, code, &info, head, kinds) catch return null) orelse return null;
    defer p.deinit();
    if (!tier2_be.eligible(code, &info, &p)) return null;
    counts.* = p.calls;
    // The region flushes the instruction cache of the new code on arm64.
    var buf = if (t2_arm) @import("jit/a64.zig").Asm.init(a) else @import("jit/x64.zig").Asm.init(a);
    defer buf.deinit();
    tier2_be.assemble(a, &buf, code, &info, &p, s.layout, loop, heads, s.options.stress & stress_guards != 0) catch return null;
    const r = &(s.region orelse return null);
    const pages = std.mem.alignForward(usize, buf.bytes().len, r.page);
    // Tier 2 code counts in the part of named code as tier 1 code does.
    // A named Code does not get here now, but the count stays right.
    if (pages > (if (code.named) s.namedBudget() else s.budget())) return null;
    const placed = r.append(buf.bytes()) orelse {
        if (r.stopped) s.stopped = true;
        return null;
    };
    if (s.options.on_code) |cb| cb(s.options.on_code_ctx, placed);
    s.charge(pages, code.named);
    if (code.named) s.stats.named_bytes += pages;
    s.stats.tier2 += 1;
    s.stats.code_bytes += placed.len;
    return placed;
}

/// The error of the last `enter` with the result `.failed`.
pub fn lastError(it: *const Interp) Error {
    return @errorCast(@errorFromInt(it.jit.?.err));
}

fn fallback(it: *Interp) Status {
    it.jit.?.stats.fallbacks += 1;
    return .fallback;
}

/// Writes the counts to stderr in the form of `--jit-stats`.
pub fn printStats(it: *const Interp) void {
    const st: Stats = if (it.jit) |s| s.stats else .{};
    std.debug.print("jit compiled={d} failed={d} code_bytes={d} data_bytes={d} fallbacks={d} tier2={d} exits={d} named_bytes={d} named_stops={d}\n", .{
        st.compiled, st.failed, st.code_bytes, st.data_bytes, st.fallbacks, st.tier2, st.exits, st.named_bytes, st.named_stops,
    });
}

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
};

/// True when this target has a backend.
pub const backend = builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;

/// True when the build has the JIT and the target has a backend.
pub const built = options.jit and backend;

pub const Options = struct {
    /// Calls of a Code before it compiles. 0 compiles before the first run.
    threshold: u32 = 2,
    /// The most bytes for the executable region and all JIT data.
    mem_limit: usize = 16 << 20,
    tier2: bool = false,
    stress: u32 = 0,
};

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
    /// True after a system call of the region failed.
    stopped: bool = false,
    /// The error of the last entry that failed.
    err: u16 = 0,

    fn root(s: *State) *State {
        var r = s;
        while (r.parent) |p| r = p;
        return r;
    }

    fn charge(s: *State, n: usize) void {
        s.used += n;
        s.root().family += n;
    }

    fn uncharge(s: *State) void {
        s.root().family -= s.used;
        s.used = 0;
    }

    fn budget(s: *State) usize {
        return s.options.mem_limit -| s.root().family;
    }
};

const layout_mod = @import("jit/layout.zig");
const mem = @import("jit/mem.zig");
const tier1 = @import("jit/tier1.zig");
const helpers = @import("jit/helpers.zig");
const gc = @import("gc.zig");

pub const Fn = tier1.Fn;

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
    for (s.fns.items) |f| f.free(s.backing);
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
    if (code.named) {
        code.jit_state = .failed;
        return null;
    }
    code.jit_calls +|= 1;
    // A body with a loop compiles at its first call, so a later call
    // needs no scan.
    if (code.jit_calls < s.options.threshold and (code.jit_calls > 1 or !hasLoop(code))) return null;
    return compileCode(s, code);
}

fn compileCode(s: *State, code: *vm.Code) ?*Fn {
    code.jit_state = .failed;
    if (s.stopped) return null;
    if (s.region == null) {
        s.region = mem.Region.init(s.options.mem_limit) orelse {
            s.stopped = true;
            return null;
        };
    }
    const r = &s.region.?;
    s.fns.ensureUnusedCapacity(s.backing, 1) catch return null;
    switch (tier1.compile(s.backing, r, s.layout, code, s.budget())) {
        .ok => |f| {
            s.fns.appendAssumeCapacity(f);
            s.charge(f.pages(r.page) + f.bytes());
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
        .failed, .full => {},
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
    const p = pc.*;
    const frame = it.frame;
    if (p >= code.ins.len or p >= f.entries.len) return fallback(it);
    const off = f.entries[p];
    if (off == tier1.no_entry or off >= f.len) return fallback(it);
    if (sp.* != f.depth[p]) return fallback(it);
    if (frame.vars.items.len < code.names.len) return fallback(it);
    var ctx: EnterCtx = .{
        .it = it,
        .code = code,
        .frame = frame,
        .stack = stack,
        .helpers = &helpers.table,
        .target = @intFromPtr(f.base) + off,
        .pc = p,
        .sp = sp.*,
        .err = 0,
        .empty = &Value.empty,
    };
    const func: *const fn (*EnterCtx) callconv(.c) u32 = @ptrCast(@alignCast(f.base));
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
    std.debug.print("jit compiled={d} failed={d} code_bytes={d} data_bytes={d} fallbacks={d} tier2={d} exits={d}\n", .{
        st.compiled, st.failed, st.code_bytes, st.data_bytes, st.fallbacks, st.tier2, st.exits,
    });
}

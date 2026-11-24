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
//! number. `flush` takes a new number, so a `Code` that outlives a flush
//! runs in the interpreter and is never compiled with stale data.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const interp = @import("interp.zig");

const Allocator = std.mem.Allocator;
const Interp = interp.Interp;

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
    /// state takes a new number from `next_gen`.
    gen: u64,
};

/// The source of generation numbers. Zero is never used, so a `Code`
/// with generation zero has no function.
var next_gen = std.atomic.Value(u64).init(1);

fn newGen() u64 {
    return next_gen.fetchAdd(1, .monotonic);
}

/// Turns the JIT on for `it`. Returns false and changes no state when
/// the build has no JIT or the system has no executable memory.
pub fn enable(it: *Interp, opts: Options) bool {
    if (!built) return false;
    if (it.jit) |s| {
        s.options = opts;
        return true;
    }
    const a = it.counter.child;
    const s = a.create(State) catch return false;
    s.* = .{ .options = opts, .backing = a, .gen = newGen() };
    it.jit = s;
    return true;
}

/// Turns the JIT on for a new child when its parent has it.
pub fn inherit(child: *Interp, parent: *const Interp) void {
    if (!built) return;
    const p = parent.jit orelse return;
    _ = enable(child, p.options);
}

/// Frees each compiled function of `it`. The state and its options
/// stay. Call it only when no script of `it` runs.
pub fn flush(it: *Interp) void {
    if (!built) return;
    const s = it.jit orelse return;
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

/// Writes the counts to stderr in the form of `--jit-stats`.
pub fn printStats(it: *const Interp) void {
    const st: Stats = if (it.jit) |s| s.stats else .{};
    std.debug.print("jit compiled={d} failed={d} code_bytes={d} data_bytes={d} fallbacks={d} tier2={d} exits={d}\n", .{
        st.compiled, st.failed, st.code_bytes, st.data_bytes, st.fallbacks, st.tier2, st.exits,
    });
}

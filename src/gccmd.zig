//! The command `ztcl::gc` (capability `meter`, ztcl#526): the counts of
//! the collector of the heap of the interpreter tree, and a collection on
//! demand. The counts of time and of the resident set depend on the host,
//! so the command comes with `meter`, as `ztcl::meter` does.
//!
//!   ztcl::gc stats
//!   ztcl::gc collect
//!   ztcl::gc reset
//!
//! `stats` gives a dict. The times are in ns, from a clock that does not
//! go back. The pause percentiles come from the last 1,024 collections.
//!
//! - collections: the collections since the start of the counts.
//! - majors: the major collections. Where the heap has the generational
//!   mode, a minor collection marks only the new blocks.
//! - gc_ns, mark_ns, sweep_ns: the time of the collections, of their marks,
//!   and of their sweeps.
//! - pause_p50_ns, pause_p99_ns, pause_max_ns: the pauses of the
//!   collections.
//! - heap_bytes, heap_peak: the bytes of the pages of the heap now, and
//!   their peak.
//! - live_bytes: the bytes of the blocks that the last collection kept.
//! - used_bytes: the bytes of the blocks in use now, live or not.
//! - threshold: the heap bytes at which the next collection starts.
//! - allocated, freed: the bytes that the program allocated and that the
//!   collections freed.
//! - alloc_rate: allocated bytes a second since the start of the counts.
//! - uptime_ns: the time since the start of the counts.
//! - rss, rss_peak: the resident set of the process and its peak, from
//!   the system (`procmem.zig`), or 0 where the system gives none.
//! - returned: the bytes of free pages that the heap gave back to the
//!   system (`pagepool.zig`), and retained: the bytes of free pages that
//!   it keeps for its next spans. 0 with no page pool.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const heap_mod = @import("heap.zig");
const procmem = @import("procmem.zig");
const meter = @import("meter.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const Cmd = interp.Cmd;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn int(v: u64) Value {
    return .{ .int = @intCast(@min(v, std.math.maxInt(i64))) };
}

pub fn cmdGc(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("ztcl::gc stats|collect|reset");
    const sub = try it.str(argv[1]);
    const h = it.heap;
    if (eql(sub, "collect")) {
        it.collect();
        return Value.empty;
    }
    if (eql(sub, "reset")) {
        h.resetStats(meter.monoNs());
        return Value.empty;
    }
    if (!eql(sub, "stats")) return it.fail("bad option \"{s}\": must be collect, reset, or stats", .{sub});
    const st = &h.stats;
    var scratch: [heap_mod.Heap.Stats.pause_ring]u32 = undefined;
    const now = meter.monoNs();
    const up = if (st.start_ns == 0) 0 else now -| st.start_ns;
    const allocated = h.allocatedBytes();
    const rate: u64 = if (up == 0) 0 else @intFromFloat(@as(f64, @floatFromInt(allocated)) * 1e9 / @as(f64, @floatFromInt(up)));
    const pm = procmem.counts();
    const kv = [_]struct { []const u8, u64 }{
        .{ "collections", st.npauses },
        .{ "majors", if (h.gen) st.majors else st.npauses },
        .{ "gc_ns", st.gc_ns },
        .{ "mark_ns", st.mark_ns },
        .{ "sweep_ns", st.sweep_ns },
        .{ "pause_p50_ns", st.percentile(0.5, &scratch) },
        .{ "pause_p99_ns", st.percentile(0.99, &scratch) },
        .{ "pause_max_ns", st.max_pause_ns },
        .{ "heap_bytes", h.bytes },
        .{ "heap_peak", st.peak_bytes },
        .{ "live_bytes", h.live_bytes },
        .{ "used_bytes", h.usedBytes() },
        .{ "threshold", h.threshold },
        .{ "allocated", allocated },
        .{ "freed", st.freed },
        .{ "alloc_rate", rate },
        .{ "uptime_ns", up },
        .{ "rss", pm.rss },
        .{ "rss_peak", pm.peak },
        .{ "returned", (if (h.pool) |p| p.returned else 0) + (if (h.wpool) |p| p.returned else 0) },
        .{ "retained", (if (h.pool) |p| p.free_committed else 0) + (if (h.wpool) |p| p.free_committed else 0) },
    };
    const a = it.alloc();
    const out = try a.alloc(Value, kv.len * 2);
    for (kv, 0..) |p, i| {
        out[2 * i] = .{ .str = p[0] };
        out[2 * i + 1] = int(p[1]);
    }
    return value.wrapList(a, out);
}

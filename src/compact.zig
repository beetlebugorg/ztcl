//! A reset that keeps the commands: a copying collection of the arena.
//!
//! `run` copies all state that a script can reach to a new arena, and
//! then frees the old arena. The state is the commands, the procs, the
//! namespaces, the point programs, the global and namespace variables,
//! and the values of the embedder in `roots`. The caches and the
//! compiled forms stay behind. A proc compiles again at its next call.
//!
//! The walk uses a work list, so a deep list uses no native stack. A map
//! from each old list object to its copy keeps shared lists shared.
//! Strings copy last: the walk records each string field, sorts the
//! byte ranges, and merges the ranges that overlap. Each merged range
//! copies once, so the copy of the strings is never larger than the
//! original bytes.
//!
//! The copy goes to a new arena before any state changes. After an
//! error, the interpreter and the roots stay as they were.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const ns = @import("ns.zig");
const point = @import("point.zig");
const Allocator = std.mem.Allocator;
const Heap = @import("heap.zig").Heap;
const Value = value.Value;
const Interp = interp.Interp;
const Var = interp.Var;

pub const Error = error{
    OutOfMemory,
    /// A script is running. Call `compact` between evaluations.
    InterpBusy,
};

pub const Options = struct {
    /// What happens to the global and namespace variables.
    vars: enum { keep, clear } = .keep,
};

/// Copies reachable state to the arena `a`. `temp` holds the work lists.
pub const Copier = struct {
    a: Allocator,
    temp: Allocator,
    /// The element links that the copy has.
    elem_links: u32 = 0,
    lists: std.AutoHashMapUnmanaged(*value.ListObj, *value.ListObj) = .empty,
    cells: std.AutoHashMapUnmanaged(*Var, *Var) = .empty,
    commands: std.AutoHashMapUnmanaged(*interp.Command, *interp.Command) = .empty,
    list_work: std.ArrayList(*value.ListObj) = .empty,
    cell_work: std.ArrayList(CellJob) = .empty,
    fixups: std.ArrayList(*[]const u8) = .empty,

    const CellJob = struct { old: *Var, new: *Var };

    /// Records a string field. `finish` points it at the new bytes.
    pub fn text(c: *Copier, p: *[]const u8) Allocator.Error!void {
        try c.fixups.append(c.temp, p);
    }

    /// Makes the value at `p` refer to copies in the new arena.
    pub fn val(c: *Copier, p: *Value) Allocator.Error!void {
        switch (p.*) {
            .str => try c.text(&p.str),
            .list => |l| p.* = .{ .list = .{ .obj = try c.listObj(l.obj), .len = l.len } },
            .int, .double => {},
        }
    }

    /// A copy of a slice of values, with each value copied.
    pub fn vals(c: *Copier, items: []const Value) Allocator.Error![]const Value {
        const out = try c.a.dupe(Value, items);
        for (out) |*v| try c.val(v);
        return out;
    }

    fn listObj(c: *Copier, old: *value.ListObj) Allocator.Error!*value.ListObj {
        const gop = try c.lists.getOrPut(c.temp, old);
        if (gop.found_existing) return gop.value_ptr.*;
        const obj = try c.a.create(value.ListObj);
        obj.* = .{
            .buf = try c.a.dupe(Value, old.buf[0..old.used]),
            .used = old.used,
            .dict_len = old.dict_len,
        };
        gop.value_ptr.* = obj;
        try c.list_work.append(c.temp, obj);
        return obj;
    }

    fn cell(c: *Copier, old: *Var) Allocator.Error!*Var {
        const gop = try c.cells.getOrPut(c.temp, old);
        if (gop.found_existing) return gop.value_ptr.*;
        const new = try c.a.create(Var);
        new.* = .{};
        gop.value_ptr.* = new;
        try c.cell_work.append(c.temp, .{ .old = old, .new = new });
        return new;
    }

    fn copyCell(c: *Copier, job: CellJob) Allocator.Error!void {
        switch (job.old.v) {
            .undef => {},
            .val => |v| {
                job.new.v = .{ .val = v };
                try c.val(&job.new.v.val);
            },
            .owned => |v| {
                job.new.v = .{ .val = v };
                try c.val(&job.new.v.val);
            },
            .link => |t| job.new.v = .{ .link = try c.cell(t) },
            .elem => |e| {
                const link = try c.a.create(interp.ElemLink);
                link.* = e.*;
                link.array = try c.cell(e.array);
                try c.text(&link.name);
                try c.text(&link.index);
                job.new.v = .{ .elem = link };
                c.elem_links += 1;
            },
            // A compact drops the traces and keeps the value.
            .traced => |t| if (t.precision) {
                const copy = try c.a.create(@import("trace.zig").Traced);
                copy.* = .{ .inner = t.inner, .precision = true };
                job.new.v = .{ .traced = copy };
            } else switch (t.inner) {
                .undef => {},
                .val => |v| {
                    job.new.v = .{ .val = v };
                    try c.val(&job.new.v.val);
                },
                .arr => |m| {
                    const map = try c.a.create(interp.ArrayMap);
                    map.* = .empty;
                    try map.ensureTotalCapacity(c.a, m.count());
                    for (m.keys(), m.values()) |k, v| map.putAssumeCapacity(k, v);
                    for (map.keys()) |*k| try c.text(k);
                    for (map.values()) |*v| try c.val(v);
                    job.new.v = .{ .arr = map };
                },
            },
            .arr => |m| {
                const map = try c.a.create(interp.ArrayMap);
                map.* = .empty;
                try map.ensureTotalCapacity(c.a, m.count());
                for (m.keys(), m.values()) |k, v| map.putAssumeCapacity(k, v);
                for (map.keys()) |*k| try c.text(k);
                for (map.values()) |*v| try c.val(v);
                job.new.v = .{ .arr = map };
            },
        }
    }

    fn command(c: *Copier, old: *interp.Command) Allocator.Error!*interp.Command {
        const gop = try c.commands.getOrPut(c.temp, old);
        if (gop.found_existing) return gop.value_ptr.*;
        const new = try c.a.create(interp.Command);
        gop.value_ptr.* = new;
        new.* = old.*;
        // A compact drops the traces, so the wrapper goes away.
        new.traces = null;
        if (old.traces) |t| if (t.orig) |orig| {
            new.impl = orig;
        };
        try c.text(&new.name);
        switch (new.impl) {
            .proc => |p| new.impl = .{ .proc = try c.proc(p) },
            .native => |f| if (ns.isEnsemble(f)) {
                new.ctx = try ns.copyEnsemble(c, old.ctx.?);
            },
        }
        return new;
    }

    fn proc(c: *Copier, old: *interp.Proc) Allocator.Error!*interp.Proc {
        const new = try c.a.create(interp.Proc);
        new.* = old.*;
        new.script = null;
        new.code = null;
        const params = try c.a.dupe(interp.Param, old.params);
        for (params) |*p| {
            try c.text(&p.name);
            if (p.default != null) try c.val(&p.default.?);
        }
        new.params = params;
        try c.val(&new.body);
        try c.val(&new.params_text);
        try c.text(&new.ns);
        return new;
    }

    /// Runs the work lists until they are empty.
    fn drain(c: *Copier) Allocator.Error!void {
        while (true) {
            if (c.list_work.pop()) |obj| {
                for (obj.buf) |*v| try c.val(v);
            } else if (c.cell_work.pop()) |job| {
                try c.copyCell(job);
            } else return;
        }
    }

    const Span = struct {
        start: usize,
        end: usize,
        base: [*]u8 = undefined,

        fn less(_: void, x: Span, y: Span) bool {
            return x.start < y.start;
        }
    };

    /// Copies the bytes of all recorded strings, one time for each
    /// merged range, and updates the fields.
    fn finish(c: *Copier) Allocator.Error!void {
        var spans = try c.temp.alloc(Span, c.fixups.items.len);
        var n: usize = 0;
        for (c.fixups.items) |p| {
            if (p.len == 0) continue;
            const start = @intFromPtr(p.ptr);
            spans[n] = .{ .start = start, .end = start + p.len };
            n += 1;
        }
        spans = spans[0..n];
        std.mem.sort(Span, spans, {}, Span.less);
        var m: usize = 0;
        for (spans) |s| {
            if (m > 0 and s.start <= spans[m - 1].end) {
                spans[m - 1].end = @max(spans[m - 1].end, s.end);
            } else {
                spans[m] = s;
                m += 1;
            }
        }
        spans = spans[0..m];
        for (spans) |*s| {
            const src: [*]const u8 = @ptrFromInt(s.start);
            const bytes = try c.a.dupe(u8, src[0 .. s.end - s.start]);
            s.base = bytes.ptr;
        }
        for (c.fixups.items) |p| {
            if (p.len == 0) {
                p.* = "";
                continue;
            }
            const start = @intFromPtr(p.ptr);
            var lo: usize = 0;
            var hi: usize = spans.len;
            while (hi - lo > 1) {
                const mid = lo + (hi - lo) / 2;
                if (spans[mid].start <= start) lo = mid else hi = mid;
            }
            p.* = spans[lo].base[start - spans[lo].start..][0..p.len];
        }
    }
};

/// See the comment at the top of the file. `roots` are values of the
/// embedder that stay valid: each gets its new address. Any other value
/// from before the call is invalid after it. `it.result` becomes empty.
pub fn run(it: *Interp, roots: []Value, opts: Options) Error!void {
    // A suspended coroutine has pointers on its native stack.
    if (it.frame != &it.global or it.nest != 0 or it.depth != 0 or it.coro_count != 0 or it.children.count() != 0 or it.capabilities != 0) return error.InterpBusy;

    var next = Heap.init(it.heap.backing);
    errdefer next.deinit();
    var temp_arena = std.heap.ArenaAllocator.init(it.counter.child);
    defer temp_arena.deinit();
    const a = next.allocator();
    const temp = temp_arena.allocator();
    var c: Copier = .{ .a = a, .temp = temp };

    var commands: @TypeOf(it.commands) = .empty;
    try commands.ensureTotalCapacity(a, it.commands.count());
    var cit = it.commands.iterator();
    while (cit.next()) |e| {
        const gop = commands.getOrPutAssumeCapacity(e.key_ptr.*);
        gop.value_ptr.* = try c.command(e.value_ptr.*);
        try c.text(@constCast(gop.key_ptr));
    }

    var namespaces: @TypeOf(it.namespaces) = .empty;
    try namespaces.ensureTotalCapacity(a, it.namespaces.count());
    for (it.namespaces.keys()) |k| namespaces.putAssumeCapacity(k, {});
    for (namespaces.keys()) |*k| try c.text(k);

    var exports: @TypeOf(it.exports) = .empty;
    try exports.ensureTotalCapacity(a, it.exports.count());
    var eit = it.exports.iterator();
    while (eit.next()) |e| {
        const items = try a.dupe([]const u8, e.value_ptr.items);
        const gop = exports.getOrPutAssumeCapacity(e.key_ptr.*);
        gop.value_ptr.* = .fromOwnedSlice(items);
        try c.text(@constCast(gop.key_ptr));
        for (gop.value_ptr.items) |*s| try c.text(s);
    }

    var ns_paths: @TypeOf(it.ns_paths) = .empty;
    try ns_paths.ensureTotalCapacity(a, it.ns_paths.count());
    var pit = it.ns_paths.iterator();
    while (pit.next()) |e| {
        const items = try a.dupe([]const u8, e.value_ptr.*);
        for (items) |*s| try c.text(s);
        const gop = ns_paths.getOrPutAssumeCapacity(e.key_ptr.*);
        gop.value_ptr.* = items;
        try c.text(@constCast(gop.key_ptr));
    }

    var ns_unknown: @TypeOf(it.ns_unknown) = .empty;
    try ns_unknown.ensureTotalCapacity(a, it.ns_unknown.count());
    var uit = it.ns_unknown.iterator();
    while (uit.next()) |e| {
        const gop = ns_unknown.getOrPutAssumeCapacity(e.key_ptr.*);
        gop.value_ptr.* = e.value_ptr.*;
        try c.val(gop.value_ptr);
        try c.text(@constCast(gop.key_ptr));
    }

    var globals: @TypeOf(it.global.vars) = .empty;
    if (opts.vars == .keep) {
        try globals.ensureTotalCapacity(a, it.global.vars.items.len);
        for (it.global.vars.items) |e| globals.appendAssumeCapacity(.{ .name = e.name, .cell = try c.cell(e.cell) });
        for (globals.items) |*e| try c.text(&e.name);
    }

    var error_code = it.error_code;
    try c.val(&error_code);

    const new_roots = try temp.dupe(Value, roots);
    for (new_roots) |*v| try c.val(v);

    var programs: @TypeOf(@as(point.State, undefined).programs) = .empty;
    if (it.points) |s| programs = try point.copyPrograms(s, &c);

    try c.drain();
    try c.finish();

    // The copy is complete. No step below can fail before the swap.
    @memcpy(roots, new_roots);
    if (it.points) |s| s.programs = programs;
    it.commands = commands;
    it.namespaces = namespaces;
    it.exports = exports;
    it.ns_paths = ns_paths;
    it.script_name = "";
    it.re_memo = .empty;
    it.coro_stacks = .empty;
    it.pending_during = null;
    it.last_during = null;
    it.last_info = Value.empty;
    it.ns_unknown = ns_unknown;
    it.searches = .empty;
    it.var_traces = c.elem_links;
    if (opts.vars != .keep) {
        it.precision = 0;
        value.precision = 0;
    }
    it.global.vars = globals;
    it.error_code = error_code;
    it.result = Value.empty;
    it.error_info = .empty;
    it.in_error = false;
    it.skip_info = false;
    it.ns = "";
    it.global.argv = &.{};
    it.free_vars = null;
    it.free_frames = .empty;
    it.script_cache = .empty;
    it.expr_cache = .empty;
    it.list_cache = @splat(.{});
    it.chunks = .empty;
    it.chunk = 0;
    it.top = 0;
    it.regex_cache = @splat(.{});
    it.tails = @splat(.{});
    it.next_tail = 0;
    it.epoch +%= 1;
    const old = it.own_heap;
    next.stress = old.stress;
    next.stress_alloc = old.stress_alloc;
    next.collections = old.collections;
    it.own_heap = next;
    it.setRoots();
    var dead = old;
    dead.deinit();

    if (opts.vars == .clear) {
        const steps = it.step_limit;
        defer it.step_limit = steps;
        try it.startVars();
    }
}

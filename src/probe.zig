//! Probes: records of a running script with no change to its text
//! (`ztcl::probe`).
//!
//! A probe has a target and an optional condition and capture list.
//! Each time the target runs and the condition is true, the probe adds
//! a record to a ring buffer of the interpreter. The targets and their
//! hooks:
//!
//! - A proc or a line of a proc body. The body compiles again with a
//!   `probe` instruction before each command of the line (line 0 is the
//!   entry of the body). `jit.prepare` does not compile a `Code` with a
//!   probe instruction, so only that body leaves the machine code.
//! - A command that is not a proc. The wrapper of the execution traces
//!   (`trace.execCall`) runs the probe.
//! - A variable. The cell gets the form `.traced` with a probe entry.
//!   The entry does not count in `Interp.var_traces`, so the inline
//!   forms of other code stay on.
//! - An error. `Interp.addErrorText` runs the probe at the first line of
//!   each error trace.
//!
//! With no probe, no hook runs: the compiled code has no probe
//! instruction, no cell and no command has a probe entry, and the error
//! hook is on the error path only.
//!
//! The condition and the captures run with their own budget of compute
//! units, and the interpreter gets its count back after them. So a
//! probe does not change the compute units of the script, and an error
//! of a probe goes in the record and not to the script. The state of
//! the error trace and the result also come back after a probe.
//!
//! The probes are in the heap, so the collector keeps the procs and
//! the scripts that they point to. The records live in the allocator of
//! the embedder, outside the heap of the script and outside `mem_limit`. A record has copies of its
//! strings and no pointer into the heap. The time of a record is the
//! count of compute units that the interpreter used, so a run gives the
//! same records each time.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const expr = @import("expr.zig");
const trace = @import("trace.zig");
const mods = @import("modules.zig");

/// The probes are in a build with the module `ztcl::probe`. In another
/// build, such as `ztcl.wasm`, each hook is empty and the compiler
/// leaves the engine out.
pub const enabled = @import("build_options").mod_probe;

const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const Allocator = std.mem.Allocator;

pub const Kind = enum { proc, line, command, variable, @"error" };

/// The fields of a new probe. The strings are copied.
pub const Spec = struct {
    kind: Kind,
    /// The name of the proc, the command, or the variable. Empty for an
    /// error probe.
    target: []const u8 = "",
    /// The line of the proc body for a line probe. Line 1 is the text
    /// after the open brace, as in the error trace.
    line: u32 = 0,
    /// The operations of a variable probe: the bits of `trace.op_read`,
    /// `trace.op_write`, and `trace.op_unset`.
    ops: u8 = trace.op_write,
    /// A command probe records at the return of the command.
    leave: bool = false,
    /// An expression. The probe records only when it is true.
    cond: []const u8 = "",
    /// A Tcl list. A plain name is a variable, and each other word is
    /// text for `subst`, such as `[llength $toks]`.
    capture: []const u8 = "",
    /// The record has the call stack.
    stack: bool = false,
    /// Each frame of the stack has its local variables.
    locals: bool = false,
    /// The most records of the probe.
    count: u64 = std.math.maxInt(u64),
    /// The probe records each Nth hit.
    every: u64 = 1,
    /// At most `rate_n` records in each window of `rate_units` compute
    /// units. Zero turns the rate limit off.
    rate_n: u64 = 0,
    rate_units: u64 = 0,
};

const Capture = struct {
    /// The word of the capture list: the key of the value in a record.
    name: []const u8,
    plain: bool,
};

pub const Probe = struct {
    id: u32,
    spec: Spec,
    captures: []Capture,
    /// The proc of a proc or line probe. Null while no proc has the name.
    proc: ?*interp.Proc = null,
    /// The command of a command probe.
    command: ?*interp.Command = null,
    /// A variable probe has its entry on a cell.
    attached: bool = false,
    /// The text of the condition and of each capture. The caches of the
    /// interpreter key a compiled form by the address of its text, and
    /// the probe keeps the text alive.
    cond_text: ?Value = null,
    capture_texts: []Value = &.{},
    hits: u64 = 0,
    records: u64 = 0,
    /// The hits that a limit did not record.
    dropped: u64 = 0,
    /// The errors of the condition or of a capture.
    errors: u64 = 0,
    window_start: u64 = 0,
    window_n: u64 = 0,
};

pub const Field = struct { key: []const u8, val: []const u8 };

pub const Record = struct {
    seq: u64,
    /// The compute units that the interpreter used before the record.
    units: u64,
    /// The id of the thread, or 0 outside a thread of `thread::create`.
    thread: u64,
    probe: u32,
    kind: Kind,
    /// The fixed fields of the kind, such as `proc`, `line`, and `cmd`.
    fields: []Field,
    /// The captured values, in the order of the capture list.
    values: []Field,
};

/// A function of the embedder that gets each new record. The record
/// and its strings are valid only during the call.
pub const Sink = struct {
    ctx: ?*anyopaque = null,
    f: *const fn (ctx: ?*anyopaque, r: *const Record) void,
};

/// The state and the probes are in the heap of the interpreter, so the
/// collector keeps each proc, script, and text that a probe points to.
/// `Interp.probes` is a root. The records are in `gpa`, the allocator of
/// the embedder, and hold no pointer into the heap.
pub const State = struct {
    gpa: Allocator,
    probes: std.ArrayList(*Probe) = .empty,
    next_id: u32 = 1,
    ring: std.ArrayList(Record) = .empty,
    /// The position of the oldest record when the ring is full.
    head: usize = 0,
    size: usize = 1000,
    seq: u64 = 0,
    units: u64 = 0,
    last_left: u64 = 0,
    /// The compute units of one condition with its captures.
    budget: u64 = 100_000,
    /// The most bytes of a captured value. A longer value keeps its
    /// first bytes and gets the count of all its bytes.
    maxlen: usize = 256,
    /// True while a probe runs, so a probe does not run in a probe.
    busy: bool = false,
    sink: ?Sink = null,
    /// The scripts in the bodies of procs with probes, with the line in
    /// the body of their line 1. `compileNamed` reads it.
    scripts: std.ArrayList(ScriptEntry) = .empty,
    /// The debugger (`dap.zig`). With a hook, each line of each proc
    /// has a `probe` instruction, and each command of `top` calls it.
    line_hook: ?LineHook = null,
    /// The script of the program file, and its command that runs now.
    top: ?*interp.Script = null,
    top_cmd: ?*interp.Cmd = null,
    /// The line of the program file of line 1 of the body of each proc
    /// that a command of `top` defined.
    bases: std.AutoHashMapUnmanaged(*interp.Proc, u32) = .empty,
};

/// A function of the debugger at a line. `p` is null for a command of
/// the top level of the program file, and `line` is then the line of
/// the file. Line 0 is the entry of `p`.
pub const LineHook = struct {
    ctx: ?*anyopaque = null,
    f: *const fn (ctx: ?*anyopaque, it: *Interp, p: ?*interp.Proc, line: u32) void,
};

/// The mark at the start of the result of `linesFor` for a proc that
/// gets a `probe` instruction at each line.
pub const all_lines = std.math.maxInt(u32);

/// True when the compiler puts a `probe` instruction at `line`.
pub fn wantsLine(lines: []const u32, line: u32) bool {
    if (lines.len != 0 and lines[0] == all_lines) return true;
    return std.mem.indexOfScalar(u32, lines, line) != null;
}

pub const ScriptEntry = struct { script: *interp.Script, proc: *interp.Proc, base: u32 };

/// The compiler of `p` with probes found these scripts. Each compiles
/// again at its next run, with the probes of its lines.
pub fn noteScripts(it: *Interp, p: *interp.Proc, bases: *const std.AutoHashMapUnmanaged(*interp.Script, u32)) Allocator.Error!void {
    const s = it.probes orelse return;
    forgetScripts(s, p);
    var iter = bases.iterator();
    while (iter.next()) |e| {
        try s.scripts.append(it.alloc(), .{ .script = e.key_ptr.*, .proc = p, .base = e.value_ptr.* });
        e.key_ptr.*.code = null;
        e.key_ptr.*.runs = 1;
    }
}

pub fn scriptOf(it: *Interp, script: *interp.Script) ?ScriptEntry {
    if (comptime !enabled) return null;
    const s = it.probes orelse return null;
    for (s.scripts.items) |e| if (e.script == script) return e;
    return null;
}

/// The scripts of `p` lose their probes: each compiles again.
fn forgetScripts(s: *State, p: *interp.Proc) void {
    var k: usize = 0;
    for (s.scripts.items) |e| {
        if (e.proc == p) {
            e.script.code = null;
            continue;
        }
        s.scripts.items[k] = e;
        k += 1;
    }
    s.scripts.shrinkRetainingCapacity(k);
}

/// The allocator that the embedder gave to the root interpreter. It
/// does not count toward `mem_limit`, and it stays valid after the
/// interpreter ends.
pub fn embedderAlloc(it: *const Interp) Allocator {
    var r = it;
    while (r.parent) |p| r = p;
    return r.counter.child;
}

/// The state of `it`. The first call makes it.
pub fn state(it: *Interp) Allocator.Error!*State {
    if (it.probes) |s| return s;
    const s = try it.alloc().create(State);
    s.* = .{ .gpa = embedderAlloc(it), .last_left = it.compute_limit };
    it.probes = s;
    return s;
}

/// The compute units that the interpreter used, as a count that only
/// goes up. A new limit of the embedder starts a new part of the count.
fn unitsNow(it: *Interp, s: *State) u64 {
    const left = it.compute_limit;
    if (left <= s.last_left) s.units += s.last_left - left;
    s.last_left = left;
    return s.units;
}

// ---- Add and remove ----

/// Adds a probe and gives its id.
pub fn add(it: *Interp, spec: Spec) Error!u32 {
    const s = try state(it);
    const g = it.alloc();
    var sp = spec;
    sp.target = try g.dupe(u8, spec.target);
    sp.cond = try g.dupe(u8, spec.cond);
    sp.capture = try g.dupe(u8, spec.capture);
    if (sp.every == 0) sp.every = 1;
    const words = try captureWords(it, sp.capture);
    const caps = try g.alloc(Capture, words.len);
    const texts = try g.alloc(Value, words.len);
    for (words, 0..) |t, i| {
        caps[i] = .{ .name = try g.dupe(u8, t), .plain = isPlain(t) };
        texts[i] = .{ .str = caps[i].name };
    }
    const p = try g.create(Probe);
    p.* = .{ .id = s.next_id, .spec = sp, .captures = caps, .capture_texts = texts };
    if (sp.cond.len > 0) p.cond_text = .{ .str = sp.cond };
    switch (sp.kind) {
        .proc, .line => {
            if (it.findCommand(sp.target)) |c| {
                if (c.impl == .proc) p.proc = c.impl.proc;
            }
        },
        .command => {
            const c = it.findCommand(sp.target) orelse return it.fail("unknown command \"{s}\"", .{sp.target});
            if (c.impl == .proc) {
                // A proc gets an entry probe, with the words of the call.
                p.spec.kind = .proc;
                p.proc = c.impl.proc;
            } else {
                try trace.addProbeCommand(it, c);
                p.command = c;
            }
        },
        .variable => {
            try trace.addProbeVar(it, sp.target, sp.ops, p);
            p.attached = true;
        },
        .@"error" => {},
    }
    try s.probes.append(g, p);
    s.next_id += 1;
    if (p.proc) |proc| {
        proc.code = null;
        forgetScripts(s, proc);
    }
    return p.id;
}

/// The words of a capture list, split as the words of a command: a
/// space inside brackets, braces, or quotes does not end a word. Braces
/// around a whole word go away, as in a list.
fn captureWords(it: *Interp, text: []const u8) Error![]const []const u8 {
    const a = it.alloc();
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len) break;
        const start = i;
        var brackets: u32 = 0;
        var braces: u32 = 0;
        var quoted = false;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (ch == '\\') {
                i += 1;
                continue;
            }
            if (ch == '[' and braces == 0) brackets += 1;
            if (ch == ']' and braces == 0 and brackets > 0) brackets -= 1;
            if (ch == '{') braces += 1;
            if (ch == '}' and braces > 0) braces -= 1;
            if (ch == '"' and braces == 0 and brackets == 0) quoted = !quoted;
            if (std.ascii.isWhitespace(ch) and brackets == 0 and braces == 0 and !quoted) break;
        }
        if (brackets != 0 or braces != 0 or quoted) return it.fail("-capture has an open bracket, brace, or quote: {s}", .{text});
        var w = text[start..@min(i, text.len)];
        if (w.len >= 2 and w[0] == '{' and w[w.len - 1] == '}') w = w[1 .. w.len - 1];
        try out.append(a, w);
    }
    return out.items;
}

fn isPlain(t: []const u8) bool {
    if (t.len == 0) return false;
    for (t) |ch| switch (ch) {
        '$', '[', '\\', ' ', '\t', '\n', '"', '{', '}' => return false,
        else => {},
    };
    return true;
}

/// Removes the probe `id`. Gives false when no probe has the id.
pub fn remove(it: *Interp, id: u32) bool {
    const s = it.probes orelse return false;
    for (s.probes.items, 0..) |p, i| {
        if (p.id != id) continue;
        _ = s.probes.orderedRemove(i);
        detach(it, p);
        return true;
    }
    return false;
}

fn detach(it: *Interp, p: *Probe) void {
    if (p.proc) |proc| {
        proc.code = null;
        if (it.probes) |s| forgetScripts(s, proc);
    }
    if (p.command) |c| trace.removeProbeCommand(it, c);
    if (p.attached) trace.removeProbeVar(it, p.spec.target, p);
}

fn freeRecord(g: Allocator, r: Record) void {
    for (r.fields) |f| g.free(f.val);
    g.free(r.fields);
    for (r.values) |f| {
        g.free(f.key);
        g.free(f.val);
    }
    g.free(r.values);
}

/// Removes each record.
pub fn clear(s: *State) void {
    for (s.ring.items) |r| freeRecord(s.gpa, r);
    s.ring.clearRetainingCapacity();
    s.head = 0;
}

/// Sets the count of records that the ring keeps. Older records go.
pub fn setSize(s: *State, n: usize) Allocator.Error!void {
    const keep = try s.gpa.alloc(Record, @min(n, s.ring.items.len));
    defer s.gpa.free(keep);
    const total = s.ring.items.len;
    var k: usize = 0;
    for (0..total) |j| {
        const r = s.ring.items[(s.head + j) % total];
        if (j + keep.len < total) {
            freeRecord(s.gpa, r);
        } else {
            keep[k] = r;
            k += 1;
        }
    }
    s.ring.clearRetainingCapacity();
    try s.ring.appendSlice(s.gpa, keep);
    s.head = 0;
    s.size = n;
}

/// Ends each probe and frees the state. `reset`, `compact`, and
/// `deinit` call it, because the probes point to procs of the heap.
pub fn dropAll(it: *Interp) void {
    if (comptime !enabled) return;
    const s = it.probes orelse return;
    for (s.probes.items) |p| detach(it, p);
    clear(s);
    s.ring.deinit(s.gpa);
    s.bases.deinit(s.gpa);
    it.probes = null;
}

/// `proc` calls this for a new proc. A proc or line probe with the name
/// moves to the new proc.
pub fn procDefined(it: *Interp, name: []const u8, p: *interp.Proc) void {
    if (comptime !enabled) return;
    const s = it.probes orelse return;
    if (s.top_cmd) |c| if (it.frame.parent == null and c.words.len == 4 and c.words[0].kind == .lit) {
        const word = it.str(c.words[0].kind.lit) catch "";
        if (std.mem.eql(u8, word, "proc")) s.bases.put(s.gpa, p, c.words[3].line) catch {};
    };
    for (s.probes.items) |pr| {
        if (pr.spec.kind != .proc and pr.spec.kind != .line) continue;
        if (!sameName(pr.spec.target, name)) continue;
        if (pr.proc) |old| forgetScripts(s, old);
        pr.proc = p;
    }
}

fn sameName(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimStart(u8, a, ":"), std.mem.trimStart(u8, b, ":"));
}

/// The lines of the probes on `p` for the compiler, or null. The
/// caller frees the slice with `embedderAlloc(it)`.
pub fn linesFor(it: *Interp, p: *interp.Proc) Allocator.Error!?[]u32 {
    if (comptime !enabled) return null;
    const s = it.probes orelse return null;
    var out: std.ArrayList(u32) = .empty;
    if (s.line_hook != null) try out.append(s.gpa, all_lines);
    for (s.probes.items) |pr| {
        if (pr.proc != p) continue;
        const line: u32 = if (pr.spec.kind == .line) pr.spec.line else 0;
        if (std.mem.indexOfScalar(u32, out.items, line) == null) try out.append(s.gpa, line);
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(s.gpa);
}

// ---- The hooks ----

/// The `probe` instruction: line `line` of the body of `p` starts.
pub fn fireLine(it: *Interp, p: *interp.Proc, line: u32) void {
    if (comptime !enabled) return;
    const s = it.probes orelse return;
    if (s.busy) return;
    if (s.line_hook) |h| h.f(h.ctx, it, p, line);
    for (s.probes.items) |pr| {
        if (pr.proc != p) continue;
        const at: u32 = if (pr.spec.kind == .line) pr.spec.line else 0;
        if (at != line) continue;
        var fields: [2]Field = undefined;
        var n: usize = 0;
        fields[n] = .{ .key = "proc", .val = frameName(it) };
        n += 1;
        var buf: [16]u8 = undefined;
        if (pr.spec.kind == .line) {
            fields[n] = .{ .key = "line", .val = std.fmt.bufPrint(&buf, "{d}", .{line}) catch "" };
            n += 1;
        } else {
            fields[n] = .{ .key = "words", .val = wordsText(it, it.frame.argv) };
            n += 1;
        }
        fire(it, s, pr, fields[0..n]);
    }
}

/// A command of the top level of the program file starts.
pub fn fireTop(it: *Interp, c: *interp.Cmd) void {
    if (comptime !enabled) return;
    const s = it.probes orelse return;
    s.top_cmd = c;
    if (s.busy) return;
    if (s.line_hook) |h| h.f(h.ctx, it, null, c.line);
}

/// A command with a probe ran. `result` is null at the entry.
pub fn fireCommand(it: *Interp, c: *interp.Command, argv: []const Value, leave: ?struct { code: i64, result: Value }) void {
    if (comptime !enabled) return;
    const s = it.probes orelse return;
    if (s.busy) return;
    for (s.probes.items) |pr| {
        if (pr.command != c) continue;
        if (pr.spec.leave != (leave != null)) continue;
        var fields: [4]Field = undefined;
        var n: usize = 0;
        fields[n] = .{ .key = "proc", .val = frameName(it) };
        n += 1;
        fields[n] = .{ .key = "words", .val = wordsText(it, argv) };
        n += 1;
        var buf: [24]u8 = undefined;
        if (leave) |l| {
            fields[n] = .{ .key = "code", .val = std.fmt.bufPrint(&buf, "{d}", .{l.code}) catch "" };
            n += 1;
            fields[n] = .{ .key = "result", .val = it.str(l.result) catch "" };
            n += 1;
        }
        fire(it, s, pr, fields[0..n]);
    }
}

/// A variable with a probe entry was read, written, or unset.
pub fn fireVar(it: *Interp, ptr: *anyopaque, name: []const u8, idx: ?[]const u8, op: u8, v: ?Value) void {
    if (comptime !enabled) return;
    const s = it.probes orelse return;
    const pr: *Probe = @ptrCast(@alignCast(ptr));
    if (op == trace.op_unset) pr.attached = false;
    if (pr.spec.ops & op == 0) return;
    if (s.busy) return;
    const full = if (idx) |i| std.fmt.allocPrint(it.alloc(), "{s}({s})", .{ name, i }) catch name else name;
    var fields: [4]Field = .{
        .{ .key = "proc", .val = frameName(it) },
        .{ .key = "var", .val = full },
        .{ .key = "op", .val = switch (op) {
            trace.op_read => "read",
            trace.op_write => "write",
            else => "unset",
        } },
        .{ .key = "value", .val = if (v) |x| it.str(x) catch "" else "" },
    };
    fire(it, s, pr, fields[0..if (v != null) 4 else 3]);
}

/// The first line of an error trace: the command `text` failed.
pub fn fireError(it: *Interp, text: []const u8) void {
    if (comptime !enabled) return;
    const s = it.probes orelse return;
    if (s.busy) return;
    for (s.probes.items) |pr| {
        if (pr.spec.kind != .@"error") continue;
        var fields: [4]Field = .{
            .{ .key = "proc", .val = frameName(it) },
            .{ .key = "cmd", .val = text },
            .{ .key = "message", .val = it.str(it.result) catch "" },
            .{ .key = "errorcode", .val = it.str(it.error_code) catch "" },
        };
        fire(it, s, pr, &fields);
    }
}

fn frameName(it: *Interp) []const u8 {
    if (it.frame.argv.len == 0) return "";
    return it.str(it.frame.argv[0]) catch "";
}

fn wordsText(it: *Interp, argv: []const Value) []const u8 {
    return value.listToString(it.alloc(), argv) catch "";
}

/// The state of the interpreter that a probe must not change.
const Saved = struct {
    result: Value,
    ret_code: interp.ReturnCode,
    ret_level: u32,
    custom_code: u32,
    error_line: u32,
    error_info: std.ArrayList(u8),
    in_error: bool,
    error_code: Value,
    skip_info: bool,
    proc_line: u32,
    compute_limit: u64,
    last_info: Value,
    pending_during: ?Value,
    tail_words: ?[]const Value,

    fn take(it: *Interp) Saved {
        const sv: Saved = .{
            .result = it.result,
            .ret_code = it.ret_code,
            .ret_level = it.ret_level,
            .custom_code = it.custom_code,
            .error_line = it.error_line,
            .error_info = it.error_info,
            .in_error = it.in_error,
            .error_code = it.error_code,
            .skip_info = it.skip_info,
            .proc_line = it.proc_line,
            .compute_limit = it.compute_limit,
            .last_info = it.last_info,
            .pending_during = it.pending_during,
            .tail_words = it.tail_words,
        };
        it.in_error = false;
        it.error_info = .empty;
        it.skip_info = false;
        it.error_line = 0;
        return sv;
    }

    fn back(sv: Saved, it: *Interp) void {
        it.result = sv.result;
        it.ret_code = sv.ret_code;
        it.ret_level = sv.ret_level;
        it.custom_code = sv.custom_code;
        it.error_line = sv.error_line;
        it.error_info = sv.error_info;
        it.in_error = sv.in_error;
        it.error_code = sv.error_code;
        it.skip_info = sv.skip_info;
        it.proc_line = sv.proc_line;
        it.compute_limit = sv.compute_limit;
        it.last_info = sv.last_info;
        it.pending_during = sv.pending_during;
        it.tail_words = sv.tail_words;
    }
};

/// The hit of a probe: the limits, the condition, the captures, and
/// the record. No error leaves this function.
fn fire(it: *Interp, s: *State, pr: *Probe, fields: []const Field) void {
    const now = unitsNow(it, s);
    pr.hits += 1;
    if ((pr.hits - 1) % pr.spec.every != 0) return;
    if (pr.records >= pr.spec.count) {
        pr.dropped += 1;
        return;
    }
    if (pr.spec.rate_n != 0) {
        if (now - pr.window_start >= pr.spec.rate_units) {
            pr.window_start = now;
            pr.window_n = 0;
        }
        if (pr.window_n >= pr.spec.rate_n) {
            pr.dropped += 1;
            return;
        }
    }
    s.busy = true;
    defer s.busy = false;
    const sv = Saved.take(it);
    defer sv.back(it);
    it.compute_limit = @min(sv.compute_limit, s.budget);
    var failed: ?[]const u8 = null;
    if (pr.cond_text) |t| {
        const ok = condition(it, t) catch |e| blk: {
            if (e == error.OutOfMemory or it.overLimit()) return;
            failed = it.str(it.result) catch "";
            break :blk true;
        };
        if (!ok) return;
    }
    const g = s.gpa;
    const vals = g.alloc(Field, pr.captures.len) catch return;
    var made: usize = 0;
    var ok = false;
    defer if (!ok) {
        for (vals[0..made]) |f| {
            g.free(f.key);
            g.free(f.val);
        }
        g.free(vals);
    };
    for (pr.captures, pr.capture_texts) |c, t| {
        const text = captureOne(it, c, t) catch |e| blk: {
            if (e == error.OutOfMemory or it.overLimit()) return;
            pr.errors += 1;
            break :blk std.fmt.allocPrint(it.alloc(), "<error: {s}>", .{it.str(it.result) catch ""}) catch "";
        };
        const key = g.dupe(u8, c.name) catch return;
        const val = clip(g, text, s.maxlen) catch {
            g.free(key);
            return;
        };
        vals[made] = .{ .key = key, .val = val };
        made += 1;
    }
    var extra: [2]Field = undefined;
    var nx: usize = 0;
    if (failed) |m| {
        pr.errors += 1;
        extra[nx] = .{ .key = "probe_error", .val = m };
        nx += 1;
    }
    if (pr.spec.stack) {
        extra[nx] = .{ .key = "stack", .val = stackText(it, pr.spec.locals, s.maxlen) };
        nx += 1;
    }
    const all = g.alloc(Field, fields.len + nx) catch return;
    var filled: usize = 0;
    const r_ok = blk: {
        for (fields) |f| {
            all[filled] = .{ .key = f.key, .val = clip(g, f.val, s.maxlen * 4) catch break :blk false };
            filled += 1;
        }
        for (extra[0..nx]) |f| {
            all[filled] = .{ .key = f.key, .val = clip(g, f.val, s.maxlen * 16) catch break :blk false };
            filled += 1;
        }
        break :blk true;
    };
    if (!r_ok) {
        for (all[0..filled]) |f| g.free(f.val);
        g.free(all);
        return;
    }
    const rec: Record = .{
        .seq = s.seq,
        .units = now,
        .thread = if (it.worker) |w| w.id else 0,
        .probe = pr.id,
        .kind = pr.spec.kind,
        .fields = all,
        .values = vals,
    };
    s.seq += 1;
    pr.records += 1;
    pr.window_n += 1;
    ok = true;
    if (s.sink) |k| k.f(k.ctx, &rec);
    push(s, rec);
}

fn push(s: *State, rec: Record) void {
    if (s.size == 0) return freeRecord(s.gpa, rec);
    if (s.ring.items.len < s.size) {
        s.ring.append(s.gpa, rec) catch return freeRecord(s.gpa, rec);
        return;
    }
    freeRecord(s.gpa, s.ring.items[s.head]);
    s.ring.items[s.head] = rec;
    s.head = (s.head + 1) % s.ring.items.len;
}

fn condition(it: *Interp, t: Value) Error!bool {
    const n = try expr.compile(it, try it.str(t));
    return expr.truthy(it, try expr.eval(it, n));
}

fn captureOne(it: *Interp, c: Capture, t: Value) Error![]const u8 {
    if (c.plain) {
        const v = try it.getVarQuiet(c.name) orelse return "<no value>";
        return it.str(v);
    }
    return it.str(try it.callWords(&.{ .{ .str = "subst" }, t }));
}

/// A copy of `text` of at most `max` bytes, cut at a character start,
/// with the count of all bytes after a cut.
fn clip(g: Allocator, text: []const u8, max: usize) Allocator.Error![]u8 {
    if (text.len <= max) return g.dupe(u8, text);
    var end = max;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return std.fmt.allocPrint(g, "{s}... ({d} bytes)", .{ text[0..end], text.len });
}

/// The call stack: a list with one item for each frame, innermost
/// first. An item is the list of the words of the call. With `locals`,
/// an item is a list of two: the words, and a dict of the locals with
/// values of at most `max` bytes.
fn stackText(it: *Interp, locals: bool, max: usize) []const u8 {
    const a = it.alloc();
    var items: std.ArrayList(Value) = .empty;
    var f: ?*interp.Frame = it.frame;
    while (f) |fr| : (f = fr.parent) {
        if (fr.parent == null) break;
        const words: Value = .{ .str = value.listToString(a, fr.argv) catch return "" };
        if (!locals) {
            items.append(a, words) catch return "";
            continue;
        }
        const vars = localsOf(it, fr, max) catch return "";
        items.append(a, value.newList(a, &.{ words, vars }) catch return "") catch return "";
    }
    return value.listToString(a, items.items) catch "";
}

/// The locals of a frame with a value, as a dict. An array shows the
/// count of its elements.
pub fn localsOf(it: *Interp, fr: *interp.Frame, max: usize) Error!Value {
    const a = it.alloc();
    var out: std.ArrayList(Value) = .empty;
    for (fr.vars.items) |e| {
        const text: []const u8 = switch (e.cell.target().v) {
            .val, .owned => |v| try it.str(v),
            .arr => |m| try std.fmt.allocPrint(a, "<array of {d}>", .{m.count()}),
            .traced => |t| switch (t.inner) {
                .val => |v| try it.str(v),
                .arr => |m| try std.fmt.allocPrint(a, "<array of {d}>", .{m.count()}),
                .undef => continue,
            },
            else => continue,
        };
        try out.append(a, .{ .str = e.name });
        try out.append(a, .{ .str = try clip(a, text, max) });
    }
    return value.wrapList(a, out.items);
}

// ---- Queries ----

pub const Query = struct {
    probe: ?u32 = null,
    since: ?u64 = null,
    last: ?usize = null,
    first: ?usize = null,
    /// An expression over the fields and the captured values.
    where: ?*expr.Node = null,
};

/// The records in order that match `q`. The slice is in `it.alloc()`.
pub fn select(it: *Interp, q: Query) Error![]const *const Record {
    const s = it.probes orelse return &.{};
    const a = it.alloc();
    var out: std.ArrayList(*const Record) = .empty;
    const total = s.ring.items.len;
    for (0..total) |j| {
        const r = &s.ring.items[(s.head + j) % total];
        if (q.probe) |id| if (r.probe != id) continue;
        if (q.since) |n| if (r.seq < n) continue;
        if (q.where) |w| if (!try whereTrue(it, r, w)) continue;
        try out.append(a, r);
        if (q.first) |n| if (out.items.len >= n) break;
    }
    if (q.last) |n| if (out.items.len > n) return out.items[out.items.len - n ..];
    return out.items;
}

fn whereTrue(it: *Interp, r: *const Record, w: *const expr.Node) Error!bool {
    _ = try it.pushFrame(&.{.{ .str = "ztcl::probe" }});
    defer it.popFrame();
    try it.setVar("seq", .{ .int = @intCast(r.seq) });
    try it.setVar("units", .{ .int = @intCast(r.units) });
    try it.setVar("thread", .{ .int = @intCast(r.thread) });
    try it.setVar("probe", .{ .str = try std.fmt.allocPrint(it.alloc(), "p{d}", .{r.probe}) });
    try it.setVar("kind", .{ .str = @tagName(r.kind) });
    for (r.fields) |f| try it.setVar(f.key, .{ .str = try it.alloc().dupe(u8, f.val) });
    for (r.values) |f| {
        if (!isPlain(f.key)) continue;
        try it.setVar(f.key, .{ .str = try it.alloc().dupe(u8, f.val) });
    }
    const v = expr.eval(it, w) catch |e| {
        // A record with no such field does not match.
        if (e == error.TclError and !it.overLimit() and it.compute_limit != 0) return false;
        return e;
    };
    return expr.truthy(it, v);
}

/// The text of a `-where` expression with a `$` before each bare name,
/// so `n > 10` reads the field `n`. A name before `(` is a function, and
/// the text in quotes and braces stays.
fn whereText(it: *Interp, text: []const u8) Error![]const u8 {
    const a = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    const words = [_][]const u8{ "eq", "ne", "in", "ni", "true", "false", "yes", "no", "on", "off", "lt", "le", "gt", "ge" };
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '"' or ch == '{') {
            const close: u8 = if (ch == '"') '"' else '}';
            var j = i + 1;
            var depth: u32 = 1;
            while (j < text.len) : (j += 1) {
                if (text[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (ch == '{' and text[j] == '{') depth += 1;
                if (text[j] == close) {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            const end = @min(j + 1, text.len);
            try out.appendSlice(a, text[i..end]);
            i = end;
            continue;
        }
        if (ch == '$' or ch == '[') {
            // A variable or a command: copy the name with it.
            try out.append(a, ch);
            i += 1;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_' or text[i] == ':')) : (i += 1) try out.append(a, text[i]);
            continue;
        }
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            var j = i;
            while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) j += 1;
            const name = text[i..j];
            var k = j;
            while (k < text.len and text[k] == ' ') k += 1;
            const call = k < text.len and text[k] == '(';
            var keyword = false;
            for (words) |w| if (std.mem.eql(u8, w, name)) {
                keyword = true;
            };
            if (!call and !keyword) try out.append(a, '$');
            try out.appendSlice(a, name);
            i = j;
            continue;
        }
        if (std.ascii.isDigit(ch)) {
            // A number such as 1e5 or 0x1f keeps its letters.
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '.')) : (i += 1) try out.append(a, text[i]);
            continue;
        }
        try out.append(a, ch);
        i += 1;
    }
    return out.items;
}

/// A record as a Tcl dict.
pub fn toDict(it: *Interp, r: *const Record) Error!Value {
    const a = it.alloc();
    var items: std.ArrayList(Value) = .empty;
    try items.appendSlice(a, &.{ .{ .str = "seq" }, .{ .int = @intCast(r.seq) } });
    try items.appendSlice(a, &.{ .{ .str = "units" }, .{ .int = @intCast(r.units) } });
    try items.appendSlice(a, &.{ .{ .str = "thread" }, .{ .int = @intCast(r.thread) } });
    try items.appendSlice(a, &.{ .{ .str = "probe" }, .{ .str = try std.fmt.allocPrint(a, "p{d}", .{r.probe}) } });
    try items.appendSlice(a, &.{ .{ .str = "kind" }, .{ .str = @tagName(r.kind) } });
    for (r.fields) |f| try items.appendSlice(a, &.{ .{ .str = f.key }, .{ .str = try a.dupe(u8, f.val) } });
    var vals: std.ArrayList(Value) = .empty;
    for (r.values) |f| try vals.appendSlice(a, &.{ .{ .str = try a.dupe(u8, f.key) }, .{ .str = try a.dupe(u8, f.val) } });
    try items.appendSlice(a, &.{ .{ .str = "values" }, try value.wrapList(a, vals.items) });
    return value.wrapList(a, items.items);
}

/// Writes a record as one line of JSON, with no newline.
pub fn writeJson(a: Allocator, out: *std.ArrayList(u8), r: *const Record) Allocator.Error!void {
    try out.print(a, "{{\"seq\":{d},\"units\":{d},\"thread\":{d},\"probe\":\"p{d}\",\"kind\":\"{s}\"", .{ r.seq, r.units, r.thread, r.probe, @tagName(r.kind) });
    for (r.fields) |f| {
        try out.append(a, ',');
        try jsonString(a, out, f.key);
        try out.append(a, ':');
        if (std.mem.eql(u8, f.key, "line") or std.mem.eql(u8, f.key, "code")) {
            try out.appendSlice(a, f.val);
        } else try jsonString(a, out, f.val);
    }
    try out.appendSlice(a, ",\"values\":{");
    for (r.values, 0..) |f, i| {
        if (i > 0) try out.append(a, ',');
        try jsonString(a, out, f.key);
        try out.append(a, ':');
        try jsonString(a, out, f.val);
    }
    try out.appendSlice(a, "}}");
}

pub fn jsonString(a: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try out.append(a, '"');
    for (text) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try out.print(a, "\\u{x:0>4}", .{ch}),
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
}

// ---- The Tcl command ----

pub const modules_list = [_]mods.Module{.{
    .name = "ztcl::probe",
    .version = "1.0",
    .install = install,
}};

pub const modules: []const mods.Module = &modules_list;

fn install(it: *Interp) Error!void {
    try it.register("ztcl::probe", cmd);
}

const usage = "ztcl::probe add|configure|clear|list|records|remove ?arg ...?";

fn cmd(it: *Interp, argv: []const Value, _: ?*interp.Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs(usage);
    const sub = try it.str(argv[1]);
    const Sub = enum { add, configure, clear, list, records, remove };
    const k = std.meta.stringToEnum(Sub, sub) orelse
        return it.failCode("TCL LOOKUP SUBCOMMAND", "unknown subcommand \"{s}\": must be add, clear, configure, list, records, or remove", .{sub});
    return switch (k) {
        .add => cmdAdd(it, argv[2..]),
        .remove => cmdRemove(it, argv[2..]),
        .list => cmdList(it, argv[2..]),
        .records => cmdRecords(it, argv[2..]),
        .clear => {
            if (argv.len != 2) return it.wrongArgs("ztcl::probe clear");
            if (it.probes) |s| clear(s);
            return Value.empty;
        },
        .configure => cmdConfigure(it, argv[2..]),
    };
}

fn count(it: *Interp, v: Value, what: []const u8) Error!u64 {
    const n = try it.int(v);
    if (n < 0) return it.fail("{s} must be 0 or more", .{what});
    return @intCast(n);
}

fn cmdAdd(it: *Interp, args: []const Value) Error!Value {
    var spec: Spec = .{ .kind = .@"error" };
    var have = false;
    var have_line = false;
    var ops_set = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const opt = try it.str(args[i]);
        if (std.mem.eql(u8, opt, "-error")) {
            spec.kind = .@"error";
            have = true;
            continue;
        }
        if (std.mem.eql(u8, opt, "-stack")) {
            spec.stack = true;
            continue;
        }
        if (std.mem.eql(u8, opt, "-locals")) {
            spec.stack = true;
            spec.locals = true;
            continue;
        }
        if (std.mem.eql(u8, opt, "-leave")) {
            spec.leave = true;
            continue;
        }
        if (i + 1 >= args.len) return it.fail("option \"{s}\" needs a value", .{opt});
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, opt, "-proc")) {
            spec.kind = if (have_line) .line else .proc;
            spec.target = try it.str(v);
            have = true;
        } else if (std.mem.eql(u8, opt, "-line")) {
            spec.line = @intCast(try count(it, v, "-line"));
            have_line = true;
            if (spec.kind == .proc) spec.kind = .line;
        } else if (std.mem.eql(u8, opt, "-command")) {
            spec.kind = .command;
            spec.target = try it.str(v);
            have = true;
        } else if (std.mem.eql(u8, opt, "-var")) {
            spec.kind = .variable;
            spec.target = try it.str(v);
            have = true;
        } else if (std.mem.eql(u8, opt, "-ops")) {
            spec.ops = 0;
            ops_set = true;
            for (try it.list(v)) |w| {
                const t = try it.str(w);
                if (std.mem.eql(u8, t, "read")) spec.ops |= trace.op_read else if (std.mem.eql(u8, t, "write")) spec.ops |= trace.op_write else if (std.mem.eql(u8, t, "unset")) spec.ops |= trace.op_unset else return it.fail("bad operation \"{s}\": must be read, unset, or write", .{t});
            }
        } else if (std.mem.eql(u8, opt, "-if")) {
            spec.cond = try it.str(v);
        } else if (std.mem.eql(u8, opt, "-capture")) {
            spec.capture = try it.str(v);
        } else if (std.mem.eql(u8, opt, "-count")) {
            spec.count = try count(it, v, "-count");
        } else if (std.mem.eql(u8, opt, "-every")) {
            spec.every = try count(it, v, "-every");
        } else if (std.mem.eql(u8, opt, "-rate")) {
            const w = try it.list(v);
            if (w.len != 2) return it.fail("-rate needs a list of two numbers: records and compute units", .{});
            spec.rate_n = try count(it, w[0], "-rate");
            spec.rate_units = try count(it, w[1], "-rate");
        } else return it.fail("bad option \"{s}\": must be -capture, -command, -count, -error, -every, -if, -leave, -line, -locals, -ops, -proc, -rate, -stack, or -var", .{opt});
    }
    if (!have) return it.wrongArgs("ztcl::probe add -proc name ?-line n? | -command name | -var name | -error ?option value ...?");
    if (have_line and spec.kind != .line) return it.fail("-line needs -proc", .{});
    if (ops_set and spec.kind != .variable) return it.fail("-ops needs -var", .{});
    if (spec.leave and spec.kind != .command) return it.fail("-leave needs -command", .{});
    if (spec.kind == .variable and !std.mem.startsWith(u8, spec.target, "::")) {
        // A probe outlives the frame of the caller, so a local name is
        // not allowed. The full name finds the same cell from each frame.
        if (it.frame.parent != null and it.frame.ns == null) return it.fail("-var needs a global or namespace variable: use ::{s}", .{spec.target});
        spec.target = try std.fmt.allocPrint(it.alloc(), "::{s}", .{try it.qualify(spec.target)});
    }
    if ((spec.kind == .proc or spec.kind == .line) and spec.target.len > 0) {
        spec.target = try it.qualify(spec.target);
    }
    const id = try add(it, spec);
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "p{d}", .{id}) };
}

fn parseId(it: *Interp, v: Value) Error!u32 {
    const t = try it.str(v);
    const digits = if (t.len > 1 and t[0] == 'p') t[1..] else t;
    return std.fmt.parseInt(u32, digits, 10) catch it.fail("bad probe id \"{s}\"", .{t});
}

fn cmdRemove(it: *Interp, args: []const Value) Error!Value {
    if (args.len != 1) return it.wrongArgs("ztcl::probe remove id|all");
    if (std.mem.eql(u8, try it.str(args[0]), "all")) {
        const s = it.probes orelse return Value.empty;
        while (s.probes.items.len > 0) _ = remove(it, s.probes.items[0].id);
        return Value.empty;
    }
    const id = try parseId(it, args[0]);
    if (!remove(it, id)) return it.fail("no probe \"{s}\"", .{try it.str(args[0])});
    return Value.empty;
}

fn cmdList(it: *Interp, args: []const Value) Error!Value {
    if (args.len != 0) return it.wrongArgs("ztcl::probe list");
    const s = it.probes orelse return Value.empty;
    const a = it.alloc();
    var out: std.ArrayList(Value) = .empty;
    for (s.probes.items) |p| {
        var d: std.ArrayList(Value) = .empty;
        try d.appendSlice(a, &.{ .{ .str = "id" }, .{ .str = try std.fmt.allocPrint(a, "p{d}", .{p.id}) } });
        try d.appendSlice(a, &.{ .{ .str = "kind" }, .{ .str = @tagName(p.spec.kind) } });
        try d.appendSlice(a, &.{ .{ .str = "target" }, .{ .str = try a.dupe(u8, p.spec.target) } });
        if (p.spec.kind == .line) try d.appendSlice(a, &.{ .{ .str = "line" }, .{ .int = p.spec.line } });
        const live = switch (p.spec.kind) {
            .proc, .line => p.proc != null,
            .variable => p.attached,
            else => true,
        };
        try d.appendSlice(a, &.{ .{ .str = "state" }, .{ .str = if (live) "active" else "waiting" } });
        try d.appendSlice(a, &.{ .{ .str = "hits" }, .{ .int = @intCast(p.hits) } });
        try d.appendSlice(a, &.{ .{ .str = "records" }, .{ .int = @intCast(p.records) } });
        try d.appendSlice(a, &.{ .{ .str = "dropped" }, .{ .int = @intCast(p.dropped) } });
        try d.appendSlice(a, &.{ .{ .str = "errors" }, .{ .int = @intCast(p.errors) } });
        try out.append(a, try value.wrapList(a, d.items));
    }
    return value.wrapList(a, out.items);
}

fn cmdRecords(it: *Interp, args: []const Value) Error!Value {
    var q: Query = .{};
    var json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const opt = try it.str(args[i]);
        if (std.mem.eql(u8, opt, "-json")) {
            json = true;
            continue;
        }
        if (i + 1 >= args.len) return it.fail("option \"{s}\" needs a value", .{opt});
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, opt, "-probe")) {
            q.probe = try parseId(it, v);
        } else if (std.mem.eql(u8, opt, "-since")) {
            q.since = try count(it, v, "-since");
        } else if (std.mem.eql(u8, opt, "-last")) {
            q.last = @intCast(try count(it, v, "-last"));
        } else if (std.mem.eql(u8, opt, "-first")) {
            q.first = @intCast(try count(it, v, "-first"));
        } else if (std.mem.eql(u8, opt, "-where")) {
            q.where = try expr.compile(it, try whereText(it, try it.str(v)));
        } else return it.fail("bad option \"{s}\": must be -first, -json, -last, -probe, -since, or -where", .{opt});
    }
    const rs = try select(it, q);
    const a = it.alloc();
    try @import("cmds.zig").chargeEntries(it, rs.len);
    if (json) {
        var out: std.ArrayList(u8) = .empty;
        for (rs) |r| {
            try writeJson(a, &out, r);
            try out.append(a, '\n');
        }
        return .{ .str = out.items };
    }
    const items = try a.alloc(Value, rs.len);
    for (rs, 0..) |r, k| items[k] = try toDict(it, r);
    return value.wrapList(a, items);
}

fn cmdConfigure(it: *Interp, args: []const Value) Error!Value {
    const s = try state(it);
    if (args.len == 0) {
        const a = it.alloc();
        return value.newList(a, &.{
            .{ .str = "-size" },   .{ .int = @intCast(s.size) },
            .{ .str = "-budget" }, .{ .int = @intCast(s.budget) },
            .{ .str = "-maxlen" }, .{ .int = @intCast(s.maxlen) },
        });
    }
    if (args.len % 2 != 0) return it.wrongArgs("ztcl::probe configure ?-size n? ?-budget n? ?-maxlen n?");
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const opt = try it.str(args[i]);
        const n = try count(it, args[i + 1], opt);
        if (std.mem.eql(u8, opt, "-size")) {
            if (n > 1_000_000) return it.fail("-size must be at most 1000000", .{});
            try setSize(s, @intCast(n));
        } else if (std.mem.eql(u8, opt, "-budget")) {
            if (n == 0) return it.fail("-budget must be 1 or more", .{});
            s.budget = n;
        } else if (std.mem.eql(u8, opt, "-maxlen")) {
            if (n < 16) return it.fail("-maxlen must be 16 or more", .{});
            s.maxlen = @intCast(n);
        } else return it.fail("bad option \"{s}\": must be -budget, -maxlen, or -size", .{opt});
    }
    return Value.empty;
}

//! `ztcl debug`: runs a script with probes and writes a short report,
//! for people and for agents. The MCP server (`debugmcp.zig`) and an
//! embedder use the same functions.
//!
//! A run adds the probes of the options and one error probe with the
//! locals of each frame. At the end, the report has the status, the
//! error, the stack with values at the start of the error, the counts of
//! each probe, and the last records. The report starts with the summary
//! and stops at a byte budget, with a line that tells how to get more.
//!
//! `explain` runs the script a second time after an error, with a probe
//! on each line of the innermost proc of the error. The probes capture
//! the variables of the failed command and the locals of that frame, so
//! the report can give the last changes of each one and the line of the
//! command that made each change. With no capability, a script is
//! deterministic, so the second run is equal to the first. With a
//! capability, the second run can differ, and the report says so.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const probe = @import("probe.zig");
const tape = @import("tape.zig");

const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const Allocator = std.mem.Allocator;

pub const Detail = enum { summary, stack, changes, records, all };

pub const Options = struct {
    explain: bool = false,
    /// The words of `ztcl::probe add` for each probe, as Tcl text.
    probes: []const []const u8 = &.{},
    json: bool = false,
    /// The most bytes of the report.
    budget: usize = 4000,
    detail: Detail = .summary,
    /// The count of records in the report.
    last: usize = 10,
    /// Serve the tools over MCP on stdin and stdout.
    mcp: bool = false,
    /// Serve the debugger over the Debug Adapter Protocol (`dap.zig`).
    dap: bool = false,
    /// The file of `--record` or `--replay`. The runner reads and
    /// writes it, and gives the tape in `tape`.
    record_path: ?[]const u8 = null,
    replay_path: ?[]const u8 = null,
    /// The tape of the run: it records the inputs, or replays them.
    tape: ?*tape.Tape = null,
    /// Questions over the run: who last set a variable, and when a
    /// variable first got a value.
    questions: []const Question = &.{},
};

/// One change of a variable: the value before, the value after, and the
/// lines of the two records. A command at the first line, or the loop
/// head between the two lines, made the change.
pub const Change = struct { name: []const u8, from: []const u8, to: []const u8, line: []const u8, next: []const u8 };

pub const Question = struct {
    kind: enum { who_set, when },
    /// A global or namespace variable.
    name: []const u8,
    value: []const u8 = "",
};

pub const FrameInfo = struct { words: []const u8, locals: []const probe.Field };

pub const ProbeInfo = struct {
    id: u32,
    kind: probe.Kind,
    target: []const u8,
    line: u32,
    hits: u64,
    records: u64,
    dropped: u64,
    errors: u64,
};

/// The result of a run. Each string is in `arena`, outside the heap of
/// the interpreter, so a report stays valid after `reset` and after the
/// interpreter ends. Call `deinit` to free it.
pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    ok: bool = true,
    result: []const u8 = "",
    message: []const u8 = "",
    errorcode: []const u8 = "",
    /// The failed command, from the start of the error.
    cmd: []const u8 = "",
    /// The stack at the start of the error, innermost first.
    frames: []const FrameInfo = &.{},
    probes: []const ProbeInfo = &.{},
    /// The records of the probes of the options, oldest first.
    records: []const probe.Record = &.{},
    changes: []const Change = &.{},
    /// A note on the second run of `explain`.
    note: []const u8 = "",
    /// A line on the tape: the count of entries, or the first difference
    /// of a replay.
    tape_note: []const u8 = "",
    /// One line for each question of the options.
    answers: []const []const u8 = &.{},
    /// The first error of the run, when it is not the last error.
    first_error: []const u8 = "",

    pub fn deinit(r: *Report) void {
        r.arena.deinit();
    }
};

/// Loads `ztcl::probe` and adds the probes of `opts`. Gives the id of
/// the error probe. An error of a probe spec is a script error, and
/// `it.result` has the message.
pub fn prepare(it: *Interp, opts: Options) Error!u32 {
    _ = try it.eval("package require ztcl::probe");
    const id = try probe.add(it, .{ .kind = .@"error", .stack = true, .locals = true });
    for (opts.questions) |q| {
        const full = if (std.mem.startsWith(u8, q.name, "::")) q.name else try std.fmt.allocPrint(it.alloc(), "::{s}", .{q.name});
        const cond = if (q.kind == .when) try std.fmt.allocPrint(it.alloc(), "[set {{{s}}}] eq {{{s}}}", .{ full, q.value }) else "";
        _ = try probe.add(it, .{ .kind = .variable, .target = full, .ops = probe_write, .cond = cond, .stack = true, .count = if (q.kind == .when) 1 else std.math.maxInt(u64) });
    }
    for (opts.probes) |spec| {
        const text = try std.fmt.allocPrint(it.alloc(), "ztcl::probe add {s}", .{spec});
        _ = try it.eval(text);
    }
    return id;
}

const probe_write = @import("trace.zig").op_write;

/// The answer to each question from the records of its probe. The probe
/// of question k has the id `err_id + 1 + k`.
fn answer(it: *Interp, rep: *Report, err_id: u32, qs: []const Question) Error!void {
    const ra = rep.arena.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    for (qs, 0..) |q, k| {
        const id: u32 = err_id + 1 + @as(u32, @intCast(k));
        const rs = try probe.select(it, .{ .probe = id });
        if (rs.len == 0) {
            try out.append(ra, try std.fmt.allocPrint(ra, "{s}: {s}", .{ q.name, if (q.kind == .when) "never got the value" else "no write" }));
            continue;
        }
        const r = if (q.kind == .when) rs[0] else rs[rs.len - 1];
        const where = field(r, "stack");
        try out.append(ra, try std.fmt.allocPrint(ra, "{s}: {s} {s} at unit {d} (record #{d}), stack: {s}", .{
            q.name,
            if (q.kind == .when) "got the value" else "was last set to",
            field(r, "value"),
            r.units,
            r.seq,
            if (where.len > 0) where else "the global level",
        }));
    }
    rep.answers = out.items;
}

/// Runs `text` and gives the report. The output of the script goes to
/// the output of `it`. With `explain`, `it` has the state of the second
/// run at the end.
pub fn run(it: *Interp, text: []const u8, opts: Options) Error!Report {
    var rep: Report = .{ .arena = .init(probe.embedderAlloc(it)) };
    errdefer rep.deinit();
    const ra = rep.arena.allocator();
    const err_id = try prepare(it, opts);
    const units = it.compute_limit;
    it.error_line = 0;
    // `explain` replays the inputs of the first run in the second run, so
    // a script with capabilities gets a tape of its own.
    var own: tape.Tape = .{ .gpa = probe.embedderAlloc(it), .mode = .record };
    defer own.deinit();
    const tp: ?*tape.Tape = opts.tape orelse if (opts.explain and it.capabilities != 0) &own else null;
    if (tp) |t| tape.start(it, t);
    const res = it.eval(text);
    if (tp != null) tape.stop(it);
    if (opts.tape) |t| {
        rep.tape_note = switch (t.mode) {
            .record => try std.fmt.allocPrint(ra, "recorded {d} inputs", .{t.entries.items.len}),
            .replay => if (t.diverged) |d|
                try std.fmt.allocPrint(ra, "the replay left the tape: {s}", .{d})
            else
                try std.fmt.allocPrint(ra, "replayed {d} of {d} inputs", .{ t.pos, t.entries.items.len }),
        };
    }
    if (res) |v| {
        rep.result = try ra.dupe(u8, try it.str(v));
    } else |e| {
        if (e == error.OutOfMemory) return e;
        rep.ok = false;
        rep.message = try ra.dupe(u8, try it.str(it.result));
        rep.errorcode = try ra.dupe(u8, try it.str(it.error_code));
        try findOrigin(it, &rep, err_id);
    }
    try answer(it, &rep, err_id, opts.questions);
    if (!rep.ok) {
        const errs = try probe.select(it, .{ .probe = err_id, .first = 1 });
        if (errs.len > 0 and !std.mem.eql(u8, field(errs[0], "message"), rep.message)) {
            rep.first_error = try std.fmt.allocPrint(ra, "{s} (at {s}, unit {d})", .{ field(errs[0], "message"), field(errs[0], "cmd"), errs[0].units });
        }
    }
    try copyProbes(it, &rep, err_id);
    if (!rep.ok and opts.explain) try explain(it, text, &rep, units, tp);
    return rep;
}

fn copyProbes(it: *Interp, rep: *Report, err_id: u32) Error!void {
    const ra = rep.arena.allocator();
    const s = it.probes orelse return;
    var ps: std.ArrayList(ProbeInfo) = .empty;
    for (s.probes.items) |p| {
        if (p.id == err_id) continue;
        try ps.append(ra, .{ .id = p.id, .kind = p.spec.kind, .target = try ra.dupe(u8, p.spec.target), .line = p.spec.line, .hits = p.hits, .records = p.records, .dropped = p.dropped, .errors = p.errors });
    }
    rep.probes = ps.items;
    var rs: std.ArrayList(probe.Record) = .empty;
    for (try probe.select(it, .{})) |r| {
        if (r.probe == err_id) continue;
        try rs.append(ra, .{ .seq = r.seq, .units = r.units, .thread = r.thread, .probe = r.probe, .kind = r.kind, .fields = try copyFields(ra, r.fields), .values = try copyFields(ra, r.values) });
    }
    rep.records = rs.items;
}

fn copyFields(ra: Allocator, fs: []const probe.Field) Allocator.Error![]probe.Field {
    const out = try ra.alloc(probe.Field, fs.len);
    for (fs, 0..) |f, i| out[i] = .{ .key = try ra.dupe(u8, f.key), .val = try ra.dupe(u8, f.val) };
    return out;
}

/// The last record of the error probe with the message of the error:
/// the start of the error, with its stack.
fn findOrigin(it: *Interp, rep: *Report, err_id: u32) Error!void {
    const ra = rep.arena.allocator();
    const rs = try probe.select(it, .{ .probe = err_id });
    var k = rs.len;
    while (k > 0) {
        k -= 1;
        const r = rs[k];
        if (!std.mem.eql(u8, field(r, "message"), rep.message)) continue;
        rep.cmd = try ra.dupe(u8, field(r, "cmd"));
        var frames: std.ArrayList(FrameInfo) = .empty;
        for (try it.list(.{ .str = field(r, "stack") })) |fr| {
            const parts = try it.list(fr);
            if (parts.len == 0) continue;
            var locals: std.ArrayList(probe.Field) = .empty;
            if (parts.len > 1) {
                const vars = try it.list(parts[1]);
                var j: usize = 0;
                while (j + 1 < vars.len) : (j += 2) try locals.append(ra, .{ .key = try ra.dupe(u8, try it.str(vars[j])), .val = try ra.dupe(u8, try it.str(vars[j + 1])) });
            }
            try frames.append(ra, .{ .words = try ra.dupe(u8, try it.str(parts[0])), .locals = locals.items });
        }
        rep.frames = frames.items;
        return;
    }
}

fn field(r: *const probe.Record, key: []const u8) []const u8 {
    for (r.fields) |f| if (std.mem.eql(u8, f.key, key)) return f.val;
    return "";
}

/// The names after `$` in a command, at most 8.
fn varNames(a: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '$') continue;
        var j = i + 1;
        if (j < text.len and text[j] == '{') {
            const end = std.mem.indexOfScalarPos(u8, text, j, '}') orelse continue;
            try addName(a, out, text[j + 1 .. end]);
            i = end;
            continue;
        }
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_' or text[j] == ':')) j += 1;
        if (j > i + 1) try addName(a, out, text[i + 1 .. j]);
        i = j - 1;
    }
}

fn addName(a: Allocator, out: *std.ArrayList([]const u8), name: []const u8) Allocator.Error!void {
    if (name.len == 0 or out.items.len >= 8) return;
    for (out.items) |n| if (std.mem.eql(u8, n, name)) return;
    try out.append(a, name);
}

/// The second run of `explain`: a probe on each line of the proc of the
/// error, with the variables of the failed command and the locals.
fn explain(it: *Interp, text: []const u8, rep: *Report, units: u64, tp: ?*tape.Tape) Error!void {
    const ra = rep.arena.allocator();
    if (rep.frames.len == 0) {
        rep.note = "the error is at the global level, so no proc has lines to probe";
        return;
    }
    const top = rep.frames[0];
    const words = try it.list(.{ .str = top.words });
    if (words.len == 0) return;
    const name = try ra.dupe(u8, try it.str(words[0]));
    var names: std.ArrayList([]const u8) = .empty;
    try varNames(ra, rep.cmd, &names);
    for (top.locals) |l| try addName(ra, &names, l.key);
    if (names.items.len == 0) return;
    const body_v = it.eval(try std.fmt.allocPrint(it.alloc(), "info body {{{s}}}", .{name})) catch {
        rep.note = "the proc of the error is not a proc of the global level, so explain made no second run";
        return;
    };
    const lines = std.mem.count(u8, try it.str(body_v), "\n") + 1;
    if (lines > 2000) {
        rep.note = "the proc has more than 2000 lines, so explain made no second run";
        return;
    }
    const caps = it.capabilities;
    try it.reset();
    _ = try it.eval("package require ztcl::probe");
    try probe.setSize(try probe.state(it), 100_000);
    var capture: std.ArrayList(u8) = .empty;
    for (names.items) |n| {
        try capture.appendSlice(ra, n);
        try capture.append(ra, ' ');
    }
    // Line 0 is the entry: it starts the changes of a new call.
    for (0..lines + 1) |line| {
        _ = try probe.add(it, .{ .kind = if (line == 0) .proc else .line, .target = name, .line = @intCast(line), .capture = if (line == 0) "" else capture.items });
    }
    const out = it.output;
    it.output = .{ .write = discard };
    defer it.output = out;
    it.compute_limit = units;
    // The second run gets the inputs of the first run from the tape.
    const mode = if (tp) |t| t.mode else .record;
    if (tp) |t| {
        t.mode = .replay;
        tape.start(it, t);
    }
    const res = it.eval(text);
    if (tp) |t| {
        tape.stop(it);
        t.mode = mode;
    }
    const same = if (res) |_| false else |e| blk: {
        if (e == error.OutOfMemory) return e;
        break :blk std.mem.eql(u8, it.str(it.result) catch "", rep.message);
    };
    if (!same) {
        rep.note = "the second run did not end with the same error, so the changes can be wrong";
    } else if (caps != 0 and tp == null) {
        rep.note = "the script has capabilities, so the second run can differ from the first";
    }
    rep.changes = try changesOf(it, ra, names.items);
}

fn discard(_: ?*anyopaque, _: []const u8) void {}

/// The changes of each name in the last call, between two records in
/// order, the last 5 of each name.
fn changesOf(it: *Interp, ra: Allocator, names: []const []const u8) Error![]const Change {
    const all = try probe.select(it, .{});
    var start: usize = 0;
    for (all, 0..) |r, i| if (r.kind == .proc) {
        start = i + 1;
    };
    const rs = all[start..];
    var out: std.ArrayList(Change) = .empty;
    for (names) |n| {
        var last: ?[]const u8 = null;
        var last_line: []const u8 = "";
        var mine: std.ArrayList(Change) = .empty;
        for (rs) |r| {
            const v = for (r.values) |f| {
                if (std.mem.eql(u8, f.key, n)) break f.val;
            } else continue;
            if (last) |l| if (!std.mem.eql(u8, l, v)) {
                try mine.append(ra, .{ .name = n, .from = try ra.dupe(u8, l), .to = try ra.dupe(u8, v), .line = try ra.dupe(u8, last_line), .next = try ra.dupe(u8, field(r, "line")) });
            };
            last = v;
            last_line = field(r, "line");
        }
        const from = if (mine.items.len > 5) mine.items.len - 5 else 0;
        try out.appendSlice(ra, mine.items[from..]);
    }
    return out.items;
}

// ---- The text of a report ----

/// A writer that stops at a byte budget and counts the bytes it left out.
const Budget = struct {
    a: Allocator,
    out: std.ArrayList(u8) = .empty,
    max: usize,
    cut: usize = 0,

    fn line(b: *Budget, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const text = try std.fmt.allocPrint(b.a, fmt ++ "\n", args);
        if (b.cut > 0 or b.out.items.len + text.len > b.max) {
            b.cut += text.len;
            return;
        }
        try b.out.appendSlice(b.a, text);
    }
};

fn short(a: Allocator, text: []const u8, max: usize) Allocator.Error![]const u8 {
    const one = try std.mem.replaceOwned(u8, a, text, "\n", "\\n");
    if (one.len <= max) return one;
    var end = max;
    while (end > 0 and one[end] & 0xC0 == 0x80) end -= 1;
    return std.fmt.allocPrint(a, "{s}... ({d} bytes)", .{ one[0..end], one.len });
}

/// The report as text in `a`: the summary first, then the parts of
/// `detail`, up to the byte budget.
pub fn writeText(a: Allocator, rep: *const Report, opts: Options) Allocator.Error![]const u8 {
    var b: Budget = .{ .a = a, .max = opts.budget };
    const all = opts.detail == .all;
    if (rep.ok) {
        try b.line("status: ok", .{});
        if (rep.result.len > 0) try b.line("result: {s}", .{try short(a, rep.result, 200)});
    } else {
        try b.line("status: error", .{});
        try b.line("error: {s}", .{try short(a, rep.message, 300)});
        try b.line("code: {s}", .{try short(a, rep.errorcode, 200)});
        if (rep.cmd.len > 0) try b.line("at: {s}", .{try short(a, rep.cmd, 200)});
        if (rep.frames.len > 0) {
            try b.line("stack, innermost first ({d} frames):", .{rep.frames.len});
            const show = if (all or opts.detail == .stack) rep.frames.len else @min(rep.frames.len, 3);
            for (rep.frames[0..show]) |fr| {
                try b.line("  {s}", .{try short(a, fr.words, 160)});
                for (fr.locals) |l| try b.line("    {s} = {s}", .{ l.key, try short(a, l.val, 120) });
            }
            if (show < rep.frames.len) try b.line("  ... {d} more frames: --detail stack", .{rep.frames.len - show});
        }
    }
    if (rep.changes.len > 0) {
        try b.line("changes in the last call (second run; each change is between the two lines):", .{});
        for (rep.changes) |c| {
            try b.line("  {s}: {s} -> {s} (line {s} to {s})", .{ c.name, try short(a, c.from, 60), try short(a, c.to, 60), c.line, c.next });
        }
    }
    if (rep.note.len > 0) try b.line("note: {s}", .{rep.note});
    if (rep.tape_note.len > 0) try b.line("tape: {s}", .{rep.tape_note});
    if (rep.first_error.len > 0) try b.line("first error: {s}", .{try short(a, rep.first_error, 300)});
    for (rep.answers) |l| try b.line("answer: {s}", .{try short(a, l, 400)});
    if (rep.probes.len > 0) try b.line("probes:", .{});
    for (rep.probes) |p| {
        const at = if (p.kind == .line) try std.fmt.allocPrint(a, " line {d}", .{p.line}) else "";
        try b.line("  p{d} {s} {s}{s}: {d} hits, {d} records, {d} dropped, {d} errors", .{ p.id, @tagName(p.kind), p.target, at, p.hits, p.records, p.dropped, p.errors });
    }
    const n = rep.records.len;
    const from = if (all or opts.detail == .records or n <= opts.last) 0 else n - opts.last;
    if (n > 0) try b.line("records{s}, oldest first:", .{if (from > 0) try std.fmt.allocPrint(a, " (the last {d} of {d}; --detail records)", .{ n - from, n }) else ""});
    for (rep.records[from..]) |*r| {
        var line: std.ArrayList(u8) = .empty;
        try line.print(a, "  #{d} p{d}", .{ r.seq, r.probe });
        for (r.fields) |f| {
            if (std.mem.eql(u8, f.key, "stack")) continue;
            try line.print(a, " {s}={s}", .{ f.key, try short(a, f.val, 60) });
        }
        for (r.values) |f| try line.print(a, " {s}={s}", .{ f.key, try short(a, f.val, 60) });
        try b.line("{s}", .{line.items});
    }
    if (b.cut > 0) {
        try b.out.print(a, "... {d} bytes left out: use --budget {d}\n", .{ b.cut, opts.budget + b.cut });
    }
    return b.out.items;
}

/// The report as one JSON object in `a`, with the records of `last`.
pub fn writeJson(a: Allocator, rep: *const Report, opts: Options) Allocator.Error![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    const js = probe.jsonString;
    try o.appendSlice(a, "{\"status\":");
    try js(a, &o, if (rep.ok) "ok" else "error");
    if (rep.ok) {
        try o.appendSlice(a, ",\"result\":");
        try js(a, &o, rep.result);
    } else {
        try o.appendSlice(a, ",\"error\":");
        try js(a, &o, rep.message);
        try o.appendSlice(a, ",\"errorcode\":");
        try js(a, &o, rep.errorcode);
        try o.appendSlice(a, ",\"cmd\":");
        try js(a, &o, rep.cmd);
        try o.appendSlice(a, ",\"stack\":[");
        for (rep.frames, 0..) |fr, i| {
            if (i > 0) try o.append(a, ',');
            try o.appendSlice(a, "{\"words\":");
            try js(a, &o, fr.words);
            try o.appendSlice(a, ",\"locals\":{");
            for (fr.locals, 0..) |l, k| {
                if (k > 0) try o.append(a, ',');
                try js(a, &o, l.key);
                try o.append(a, ':');
                try js(a, &o, l.val);
            }
            try o.appendSlice(a, "}}");
        }
        try o.append(a, ']');
    }
    try o.appendSlice(a, ",\"changes\":[");
    for (rep.changes, 0..) |c, i| {
        if (i > 0) try o.append(a, ',');
        try o.appendSlice(a, "{\"var\":");
        try js(a, &o, c.name);
        try o.appendSlice(a, ",\"from\":");
        try js(a, &o, c.from);
        try o.appendSlice(a, ",\"to\":");
        try js(a, &o, c.to);
        try o.appendSlice(a, ",\"line\":");
        try o.appendSlice(a, if (c.line.len > 0) c.line else "null");
        try o.appendSlice(a, ",\"next\":");
        try o.appendSlice(a, if (c.next.len > 0) c.next else "null");
        try o.append(a, '}');
    }
    try o.appendSlice(a, "],\"note\":");
    try js(a, &o, rep.note);
    try o.appendSlice(a, ",\"tape\":");
    try js(a, &o, rep.tape_note);
    try o.appendSlice(a, ",\"first_error\":");
    try js(a, &o, rep.first_error);
    try o.appendSlice(a, ",\"answers\":[");
    for (rep.answers, 0..) |l, i| {
        if (i > 0) try o.append(a, ',');
        try js(a, &o, l);
    }
    try o.append(a, ']');
    try o.appendSlice(a, ",\"probes\":[");
    for (rep.probes, 0..) |p, i| {
        if (i > 0) try o.append(a, ',');
        try o.print(a, "{{\"id\":\"p{d}\",\"kind\":\"{s}\",\"target\":", .{ p.id, @tagName(p.kind) });
        try js(a, &o, p.target);
        try o.print(a, ",\"line\":{d},\"hits\":{d},\"records\":{d},\"dropped\":{d},\"errors\":{d}}}", .{ p.line, p.hits, p.records, p.dropped, p.errors });
    }
    try o.appendSlice(a, "],\"records\":[");
    const n = rep.records.len;
    const from = if (opts.detail == .all or opts.detail == .records or n <= opts.last) 0 else n - opts.last;
    for (rep.records[from..], 0..) |*r, i| {
        if (i > 0) try o.append(a, ',');
        try probe.writeJson(a, &o, r);
    }
    try o.appendSlice(a, "]}\n");
    return o.items;
}

/// Parses the options of `ztcl debug` from `args`. `rest` gets the index
/// of each word that is not an option of `ztcl debug`, for the runner.
pub fn parseArgs(a: Allocator, args: anytype, opts: *Options, rest: *std.ArrayList(usize)) (Allocator.Error || error{BadOption})!void {
    var probes: std.ArrayList([]const u8) = .empty;
    var qs: std.ArrayList(Question) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const has = i + 1 < args.len;
        if (std.mem.eql(u8, arg, "--explain")) {
            opts.explain = true;
        } else if (std.mem.eql(u8, arg, "--mcp")) {
            opts.mcp = true;
        } else if (std.mem.eql(u8, arg, "--dap")) {
            opts.dap = true;
        } else if (std.mem.eql(u8, arg, "--who-set") and has) {
            i += 1;
            try qs.append(a, .{ .kind = .who_set, .name = args[i] });
        } else if (std.mem.eql(u8, arg, "--when") and i + 2 < args.len) {
            try qs.append(a, .{ .kind = .when, .name = args[i + 1], .value = args[i + 2] });
            i += 2;
        } else if (std.mem.eql(u8, arg, "--record") and has) {
            i += 1;
            opts.record_path = args[i];
        } else if (std.mem.eql(u8, arg, "--replay") and has) {
            i += 1;
            opts.replay_path = args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if ((std.mem.eql(u8, arg, "--probe") or std.mem.eql(u8, arg, "-p")) and has) {
            i += 1;
            try probes.append(a, args[i]);
        } else if (std.mem.eql(u8, arg, "--budget") and has) {
            i += 1;
            opts.budget = std.fmt.parseInt(usize, args[i], 10) catch return error.BadOption;
        } else if (std.mem.eql(u8, arg, "--last") and has) {
            i += 1;
            opts.last = std.fmt.parseInt(usize, args[i], 10) catch return error.BadOption;
        } else if (std.mem.eql(u8, arg, "--detail") and has) {
            i += 1;
            opts.detail = std.meta.stringToEnum(Detail, args[i]) orelse return error.BadOption;
        } else try rest.append(a, i);
    }
    opts.probes = probes.items;
    opts.questions = qs.items;
}

pub const help =
    \\Use: ztcl debug [options] [runner options] script.tcl
    \\     ztcl debug --mcp [runner options]
    \\     ztcl debug --dap [runner options] [script.tcl]
    \\
    \\Runs the script with probes and writes a report: the status, the
    \\error with the stack and the locals, the probes, and the records.
    \\
    \\  --probe SPEC, -p SPEC  adds a probe: the words of ztcl::probe add,
    \\                         such as "-proc parse -line 4 -capture i"
    \\  --explain              after an error, runs the script again with a
    \\                         probe on each line of the proc of the error,
    \\                         and gives the last changes of its variables
    \\  --json                 writes the report as one JSON object
    \\  --budget N             the most bytes of the report (default 4000)
    \\  --detail PART          summary, stack, changes, records, or all
    \\  --last N               the count of records (default 10)
    \\  --record FILE          writes the inputs of the run to FILE: the
    \\                         clock, the event loop, and each read of a
    \\                         channel
    \\  --replay FILE          runs again with the inputs of FILE, also
    \\                         with new probes
    \\  --who-set VAR          gives the last write of a global variable,
    \\                         with its value, its time, and the stack
    \\  --when VAR VALUE       gives the first write of VALUE to VAR
    \\  --mcp                  serves the tools on stdin and stdout (MCP)
    \\  --dap                  serves a debugger on stdin and stdout (DAP),
    \\                         with breakpoints, steps, and the stack
    \\
;

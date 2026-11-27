//! Record and replay: the inputs of a run from the host, in order, so a
//! second run gets the same inputs (`ztcl debug --record` and
//! `--replay`).
//!
//! With no capability, a script is deterministic. Each other input
//! comes from the host through a few calls, and the tape keeps each one:
//!
//! - `clock`: the time of the `clock` command (`clock.zig`).
//! - `ticks`: the clock of the event loop (`event.zig`).
//! - `poll`: the channels that the event loop found ready.
//! - `read`: the bytes of each read of a channel: a file, a socket, or a
//!   pipe (`chan.zig`).
//! - `stat`: the data of a path: `file exists`, `file mtime`, `file
//!   stat`, and each other query of a path (`fsroot.zig`).
//! - `list`: the names in a folder, for `glob` (`fsroot.zig`).
//! - `command`: the result of a command that runs outside the
//!   interpreter: `exec` and `pid` (`proc.zig`). A replay does not run
//!   the programs.
//! - `random` and `env`: bytes of entropy and a read of the environment,
//!   through `bytes`.
//!
//! An entry has its kind, the compute units that the interpreter used
//! before it, and its data. A replay gives the entries back in order and
//! does not call the host for them. A probe uses no compute units, so a
//! replay with new probes sees the inputs at the same compute units.
//! When the kind or the compute units of the next input differ from the
//! tape, the replay stops with an error that names the entry.
//!
//! A replay opens the same files and sockets as the run, and only their
//! data comes from the tape. A sleep of the event loop does not run.
//!
//! The file is text: the line `ztcl-tape 1`, then one line for each
//! entry: `KIND UNITS NUMBER BASE64`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const sys = @import("sys.zig");
const fsroot = @import("fsroot.zig");

const Interp = interp.Interp;
const Error = interp.Error;
const Allocator = std.mem.Allocator;

/// The tape is a part of `ztcl debug`. A build with no `ztcl::probe` has
/// no tape, and each hook calls the host.
pub const enabled = @import("probe.zig").enabled;

pub const Kind = enum { clock, ticks, poll, read, stat, list, command, random, env };

pub const Entry = struct {
    kind: Kind,
    units: u64,
    /// The time, the count of bytes, or -1 for no data now and -2 for an
    /// error (the name of the error is `data`).
    num: i64,
    data: []const u8 = "",
};

pub const Mode = enum { record, replay };

pub const Tape = struct {
    gpa: Allocator,
    mode: Mode,
    entries: std.ArrayList(Entry) = .empty,
    pos: usize = 0,
    /// The compute units at the start of the run.
    start: u64 = 0,
    /// The first difference of a replay, in `gpa`.
    diverged: ?[]const u8 = null,

    pub fn deinit(t: *Tape) void {
        for (t.entries.items) |e| t.gpa.free(e.data);
        t.entries.deinit(t.gpa);
        if (t.diverged) |d| t.gpa.free(d);
    }
};

/// Starts a record or a replay on `it`. The tape must stay valid until
/// `stop`.
pub fn start(it: *Interp, t: *Tape) void {
    t.start = it.compute_limit;
    t.pos = 0;
    it.tape = t;
}

pub fn stop(it: *Interp) void {
    it.tape = null;
}

fn units(it: *Interp, t: *Tape) u64 {
    return t.start -| it.compute_limit;
}

/// The next entry of a replay, or null after an error that `diverged`
/// names. The interpreter error says where the replay left the tape.
fn next(it: *Interp, t: *Tape, kind: Kind) Error!Entry {
    const u = units(it, t);
    if (t.pos >= t.entries.items.len) return diverge(it, t, "the tape ends, and the run asks for {s} at unit {d}", .{ @tagName(kind), u });
    const e = t.entries.items[t.pos];
    if (e.kind != kind or e.units != u) {
        return diverge(it, t, "entry {d} of the tape is {s} at unit {d}, and the run asks for {s} at unit {d}", .{ t.pos + 1, @tagName(e.kind), e.units, @tagName(kind), u });
    }
    t.pos += 1;
    return e;
}

fn diverge(it: *Interp, t: *Tape, comptime fmt: []const u8, args: anytype) Error {
    if (t.diverged == null) t.diverged = std.fmt.allocPrint(t.gpa, fmt, args) catch null;
    return it.failCode("ZTCL TAPE DIVERGED", "replay: " ++ fmt, args);
}

fn add(it: *Interp, t: *Tape, kind: Kind, num: i64, data: []const u8) Allocator.Error!void {
    const copy = try t.gpa.dupe(u8, data);
    errdefer t.gpa.free(copy);
    try t.entries.append(t.gpa, .{ .kind = kind, .units = units(it, t), .num = num, .data = copy });
}

/// A time from the host: `clock` or `ticks`.
pub fn time(it: *Interp, kind: Kind, ctx: ?*anyopaque, f: *const fn (?*anyopaque) i64) Error!i64 {
    if (!enabled) return f(ctx);
    const t = it.tape orelse return f(ctx);
    if (t.mode == .replay) return (try next(it, t, kind)).num;
    const v = f(ctx);
    try add(it, t, kind, v, "");
    return v;
}

/// True when a replay does not run the sleep of the event loop.
pub fn skipSleep(it: *Interp) bool {
    if (!enabled) return false;
    const t = it.tape orelse return false;
    return t.mode == .replay;
}

/// The poll of the event loop. In a replay, the answers come from the
/// tape and the host is not asked.
pub fn poll(it: *Interp, a: Allocator, wants: []sys.Want, ms: i32) Error!void {
    if (!enabled) return sys.poll(a, wants, ms);
    const t = it.tape orelse return sys.poll(a, wants, ms);
    if (t.mode == .record) {
        sys.poll(a, wants, ms);
        const bits = try a.alloc(u8, wants.len);
        for (wants, bits) |w, *b| b.* = '0' + @as(u8, @intFromBool(w.can_read)) + 2 * @as(u8, @intFromBool(w.can_write));
        return add(it, t, .poll, @intCast(wants.len), bits);
    }
    const e = try next(it, t, .poll);
    if (e.num != wants.len) return diverge(it, t, "entry {d} of the tape is a poll of {d} channels, and the run polls {d}", .{ t.pos, e.num, wants.len });
    for (wants, e.data) |*w, b| {
        w.can_read = (b - '0') & 1 != 0;
        w.can_write = (b - '0') & 2 != 0;
    }
}

/// A read of a channel into `room`.
pub fn read(it: *Interp, fd: sys.Fd, room: []u8) Error!sys.IoResult {
    if (!enabled) return sys.read(fd, room);
    const t = it.tape orelse return sys.read(fd, room);
    if (t.mode == .record) {
        const r = sys.read(fd, room);
        switch (r) {
            .n => |n| try add(it, t, .read, @intCast(n), room[0..n]),
            .again => try add(it, t, .read, -1, ""),
            .err => |f| try add(it, t, .read, -2, f.name),
        }
        return r;
    }
    const e = try next(it, t, .read);
    if (e.num == -1) return .again;
    if (e.num == -2) return .{ .err = .{ .name = e.data, .text = "error from the tape" } };
    if (e.data.len > room.len) return diverge(it, t, "entry {d} of the tape has {d} bytes, and the read has room for {d}", .{ t.pos, e.data.len, room.len });
    @memcpy(room[0..e.data.len], e.data);
    return .{ .n = e.data.len };
}

fn errnoNum(e: sys.Errno) i64 {
    return if (@typeInfo(sys.Errno) == .@"enum") @backingInt(e) else e;
}

fn errnoOf(n: i64) sys.Errno {
    return if (@typeInfo(sys.Errno) == .@"enum") @fromBackingInt(@intCast(n)) else @intCast(n);
}

/// The data of a path. `num` is -1 for a found path, or the errno.
pub fn stat(it: *Interp, rel: []const u8, f: *const fn (*Interp, []const u8) Error!fsroot.StatResult) Error!fsroot.StatResult {
    if (!enabled) return f(it, rel);
    const t = it.tape orelse return f(it, rel);
    if (t.mode == .record) {
        const r = try f(it, rel);
        switch (r) {
            .ok => |x| {
                var buf: [256]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d} {d} {d} {d} {d} {d} {d} {d} {d} {d}", .{ x.mode, x.size, x.mtime, x.atime, x.ctime, x.ino, x.nlink, x.uid, x.gid, x.dev }) catch unreachable;
                try add(it, t, .stat, -1, text);
            },
            .err => |e| try add(it, t, .stat, errnoNum(e), ""),
        }
        return r;
    }
    const e = try next(it, t, .stat);
    if (e.num != -1) return .{ .err = errnoOf(e.num) };
    var parts = std.mem.splitScalar(u8, e.data, ' ');
    var v: [10]i64 = undefined;
    for (&v) |*x| {
        x.* = std.fmt.parseInt(i64, parts.next() orelse "", 10) catch return diverge(it, t, "entry {d} of the tape has bad stat data", .{t.pos});
    }
    return .{ .ok = .{ .mode = @intCast(v[0]), .size = @intCast(v[1]), .mtime = v[2], .atime = v[3], .ctime = v[4], .ino = @bitCast(v[5]), .nlink = @intCast(v[6]), .uid = @intCast(v[7]), .gid = @intCast(v[8]), .dev = @bitCast(v[9]) } };
}

/// The names in a folder. `num` is the count of names, or -1 for an
/// error (the errno is in `data`). A zero byte ends each name.
pub fn list(it: *Interp, rel: []const u8, f: *const fn (*Interp, []const u8) Error!fsroot.ListResult) Error!fsroot.ListResult {
    if (!enabled) return f(it, rel);
    const t = it.tape orelse return f(it, rel);
    const a = it.alloc();
    if (t.mode == .record) {
        const r = try f(it, rel);
        switch (r) {
            .ok => |names| {
                var text: std.ArrayList(u8) = .empty;
                for (names) |n| {
                    try text.appendSlice(a, n);
                    try text.append(a, 0);
                }
                try add(it, t, .list, @intCast(names.len), text.items);
            },
            .err => |e| try add(it, t, .list, -1, try std.fmt.allocPrint(a, "{d}", .{errnoNum(e)})),
        }
        return r;
    }
    const e = try next(it, t, .list);
    if (e.num == -1) return .{ .err = errnoOf(std.fmt.parseInt(i64, e.data, 10) catch 0) };
    const names = try a.alloc([]const u8, @intCast(e.num));
    var parts = std.mem.splitScalar(u8, e.data, 0);
    for (names) |*n| n.* = try a.dupe(u8, parts.next() orelse "");
    return .{ .ok = names };
}

/// Records the result of the command `f`, or gives it back in a replay
/// with no call of `f`. `num` is the compute units of the command. The
/// data is `o` and the result, or `e`, the error code, a zero byte, and
/// the message.
pub fn command(comptime f: interp.NativeFn) interp.NativeFn {
    if (!enabled) return f;
    return struct {
        fn run(it: *Interp, argv: []const interp.Value, c: ?*interp.Cmd) Error!interp.Value {
            const t = it.tape orelse return f(it, argv, c);
            const a = it.alloc();
            if (t.mode == .record) {
                const before = it.compute_limit;
                const at = units(it, t);
                const r = f(it, argv, c);
                const used: i64 = @intCast(before -| it.compute_limit);
                const data = if (r) |v|
                    try std.mem.concat(a, u8, &.{ "o", try it.str(v) })
                else |err| switch (err) {
                    error.TclError => try std.mem.concat(a, u8, &.{ "e", try it.str(it.error_code), "\x00", try it.str(it.result) }),
                    else => return err,
                };
                {
                    const copy = try t.gpa.dupe(u8, data);
                    errdefer t.gpa.free(copy);
                    try t.entries.append(t.gpa, .{ .kind = .command, .units = at, .num = used, .data = copy });
                }
                return r;
            }
            const e = try next(it, t, .command);
            it.compute_limit -|= @intCast(@max(e.num, 0));
            if (e.data.len == 0) return diverge(it, t, "entry {d} of the tape has no result", .{t.pos});
            const body = try a.dupe(u8, e.data[1..]);
            if (e.data[0] == 'o') return .{ .str = body };
            const k = std.mem.indexOfScalar(u8, body, 0) orelse body.len;
            it.error_code = .{ .str = body[0..k] };
            it.result = .{ .str = if (k < body.len) body[k + 1 ..] else "" };
            return error.TclError;
        }
    }.run;
}

/// Bytes from the host: entropy (`random`) or the value of an
/// environment variable (`env`). `fill` gives the bytes, or null for no
/// value. The result is in the allocator of `it`.
pub fn bytes(it: *Interp, kind: Kind, ctx: ?*anyopaque, fill: *const fn (?*anyopaque, Allocator) Allocator.Error!?[]const u8) Error!?[]const u8 {
    const a = it.alloc();
    if (!enabled) return fill(ctx, a);
    const t = it.tape orelse return fill(ctx, a);
    if (t.mode == .record) {
        const r = try fill(ctx, a);
        try add(it, t, kind, if (r) |b| @intCast(b.len) else -1, r orelse "");
        return r;
    }
    const e = try next(it, t, kind);
    if (e.num == -1) return null;
    return try a.dupe(u8, e.data);
}

// ---- The file ----

pub fn write(t: *const Tape, a: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
    try out.appendSlice(a, "ztcl-tape 1\n");
    const enc = std.base64.standard.Encoder;
    for (t.entries.items) |e| {
        try out.print(a, "{s} {d} {d} ", .{ @tagName(e.kind), e.units, e.num });
        const start_len = out.items.len;
        try out.resize(a, start_len + enc.calcSize(e.data.len));
        _ = enc.encode(out.items[start_len..], e.data);
        try out.append(a, '\n');
    }
}

pub const ParseError = Allocator.Error || error{BadTape};

/// Parses the text of a tape file into `t`.
pub fn parse(t: *Tape, text: []const u8) ParseError!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const head = lines.next() orelse return error.BadTape;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, head, "\r"), "ztcl-tape 1")) return error.BadTape;
    const dec = std.base64.standard.Decoder;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, ' ');
        const kind = std.meta.stringToEnum(Kind, parts.next() orelse return error.BadTape) orelse return error.BadTape;
        const u = std.fmt.parseInt(u64, parts.next() orelse return error.BadTape, 10) catch return error.BadTape;
        const num = std.fmt.parseInt(i64, parts.next() orelse return error.BadTape, 10) catch return error.BadTape;
        const b64 = parts.next() orelse "";
        const n = dec.calcSizeForSlice(b64) catch return error.BadTape;
        const data = try t.gpa.alloc(u8, n);
        errdefer t.gpa.free(data);
        dec.decode(data, b64) catch return error.BadTape;
        try t.entries.append(t.gpa, .{ .kind = kind, .units = u, .num = num, .data = data });
    }
}

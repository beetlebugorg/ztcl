//! Reflected channels: `chan create mode cmdprefix` and
//! `chan postevent channel eventspec`.
//!
//! A reflected channel is a channel of `chan.zig` with no descriptor
//! (`mem` true, `fd` -1) and a `Filter` whose read and write call the
//! command prefix of the script: `{*}prefix read rcN count` and
//! `{*}prefix write rcN bytes`. So the buffers, the encodings, the
//! translations, `gets`, `read`, `fcopy`, and `eof` of a reflected
//! channel are the ones of each other channel. The other methods are
//! calls from the commands of `chan.zig`: `finalize` from `close`,
//! `seek` from `seek` and `tell`, `configure`, `cget`, `cgetall`, and
//! `blocking` from `fconfigure`, and `watch` from `chan event`.
//!
//! The event loop has no descriptor to poll for such a channel. The
//! script posts an event with `chan postevent`, and `ready` and `serve`
//! (from `chan.extReady` and `chan.extServe`) run the handlers of the
//! posted events in the next pass of the loop.
//!
//! The checks and the messages follow tclsh 8.6.16: the method list of
//! `initialize`, the required methods, a `read` that gives more than the
//! count, a `write` that writes no byte, and a `finalize` that fails.
//! A `read` that fails with `EAGAIN` is an error here: tclsh treats it
//! as a channel with no data yet.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const chan = @import("chan.zig");
const more = @import("more.zig");
const event = @import("event.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Error = interp.Error;
const Channel = chan.Channel;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The methods of a handler, in the order of the message of Tcl.
pub const Method = enum { blocking, cget, cgetall, configure, finalize, initialize, read, seek, watch, write };

fn bit(m: Method) u16 {
    return @as(u16, 1) << @intFromEnum(m);
}

pub const Refl = struct {
    filter: chan.Filter = .{ .read = fRead, .write = fWrite, .closeWrite = fCloseWrite, .deinit = fDeinit },
    it: *Interp,
    c: *Channel,
    /// The words of the command prefix.
    prefix: []const Value,
    methods: u16,
    /// The events of the last `watch`: 1 read, 2 write.
    watching: u8 = 0,
    /// The events of `chan postevent` that wait for the event loop.
    posted: u8 = 0,
    finalized: bool = false,
    /// The error of `finalize` in a close, for `close` to give.
    fin_error: ?struct { result: Value, code: Value } = null,

    pub fn has(r: *const Refl, m: Method) bool {
        return r.methods & bit(m) != 0;
    }

    /// Calls the method `m` with the channel name and `args`.
    pub fn call(r: *Refl, m: Method, args: []const Value) Error!Value {
        const it = r.it;
        const words = try it.alloc().alloc(Value, r.prefix.len + 2 + args.len);
        @memcpy(words[0..r.prefix.len], r.prefix);
        words[r.prefix.len] = .{ .str = @tagName(m) };
        words[r.prefix.len + 1] = .{ .str = r.c.name };
        @memcpy(words[r.prefix.len + 2 ..], args);
        return it.callWords(words);
    }
};

fn of(f: *chan.Filter) *Refl {
    return @fieldParentPtr("filter", f);
}

fn fRead(f: *chan.Filter, it: *Interp, _: i32, buf: []u8) Error!usize {
    const r = of(f);
    const want: usize = @min(buf.len, @as(usize, @intCast(@max(r.c.buffersize, 1))));
    const got = try r.call(.read, &.{.{ .int = @intCast(want) }});
    const bytes = try more.toBytes(it, try it.str(got));
    if (bytes.len > want) return it.fail("read delivered more than requested", .{});
    @memcpy(buf[0..bytes.len], bytes);
    return bytes.len;
}

fn fWrite(f: *chan.Filter, it: *Interp, _: i32, data: []const u8) Error!void {
    const r = of(f);
    var at: usize = 0;
    while (at < data.len) {
        const rest = data[at..];
        // The text is a copy: the write buffer of the channel changes
        // after the call, and the script can keep the value.
        const text = try more.fromBytes(it, rest);
        const own = if (text.ptr == rest.ptr) try it.alloc().dupe(u8, text) else text;
        const n = try it.int(try r.call(.write, &.{.{ .str = own }}));
        if (n <= 0) return it.fail("write wrote nothing", .{});
        if (n > rest.len) return it.fail("write wrote more than requested", .{});
        at += @intCast(n);
    }
}

fn fCloseWrite(_: *chan.Filter, _: *Interp, _: i32) void {}

/// The end of the channel: `finalize`. An error of `finalize` stays in
/// `fin_error` for `close`.
fn fDeinit(f: *chan.Filter, it: *Interp) void {
    const r = of(f);
    if (r.finalized) return;
    r.finalized = true;
    _ = r.call(.finalize, &.{}) catch |e| {
        if (e == error.TclError) r.fin_error = .{ .result = it.result, .code = it.error_code };
    };
}

/// `chan create mode cmdprefix`.
pub fn create(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len != 4) return it.wrongArgs("chan create mode cmdprefix");
    var readable = false;
    var writable = false;
    for (try it.list(argv[2])) |w| {
        const m = try it.str(w);
        if (m.len > 0 and std.mem.startsWith(u8, "read", m)) {
            readable = true;
        } else if (m.len > 0 and std.mem.startsWith(u8, "write", m)) {
            writable = true;
        } else return it.failWord("TCL LOOKUP INDEX mode", m, "bad mode \"{s}\": must be read or write", .{m});
    }
    const prefix = try it.alloc().dupe(Value, try it.list(argv[3]));
    const text = try it.str(argv[3]);
    const name = try std.fmt.allocPrint(it.alloc(), "rc{d}", .{it.chans.next_rc});
    it.chans.next_rc += 1;

    var mode: std.ArrayList(Value) = .empty;
    if (readable) try mode.append(it.alloc(), .{ .str = "read" });
    if (writable) try mode.append(it.alloc(), .{ .str = "write" });
    const words = try it.alloc().alloc(Value, prefix.len + 3);
    @memcpy(words[0..prefix.len], prefix);
    words[prefix.len] = .{ .str = "initialize" };
    words[prefix.len + 1] = .{ .str = name };
    words[prefix.len + 2] = try value.wrapList(it.alloc(), mode.items);
    const got = try it.callWords(words);

    var methods: u16 = 0;
    for (try it.list(got)) |w| {
        const m = try it.str(w);
        const k = std.meta.stringToEnum(Method, m) orelse
            return it.failWord("TCL LOOKUP INDEX method", m, "chan handler \"{s} initialize\" returned bad method \"{s}\": must be blocking, cget, cgetall, configure, finalize, initialize, read, seek, watch, or write", .{ text, m });
        methods |= bit(k);
    }
    const need = bit(.initialize) | bit(.finalize) | bit(.watch);
    if (methods & need != need) return it.fail("chan handler \"{s}\" does not support all required methods", .{text});
    if (readable and methods & bit(.read) == 0) return it.fail("chan handler \"{s}\" lacks a \"read\" method", .{text});
    if (writable and methods & bit(.write) == 0) return it.fail("chan handler \"{s}\" lacks a \"write\" method", .{text});
    if (methods & bit(.cget) != 0 and methods & bit(.cgetall) == 0) return it.fail("chan handler \"{s}\" supports \"cget\" but not \"cgetall\"", .{text});
    if (methods & bit(.cgetall) != 0 and methods & bit(.cget) == 0) return it.fail("chan handler \"{s}\" supports \"cgetall\" but not \"cget\"", .{text});

    const a = it.alloc();
    const c = try a.create(Channel);
    c.* = .{ .name = name, .fd = -1, .readable = readable, .writable = writable, .mem = true };
    const r = try a.create(Refl);
    r.* = .{ .it = it, .c = c, .prefix = prefix, .methods = methods };
    c.refl = r;
    c.filter = &r.filter;
    try it.chans.table.put(a, name, c);
    return .{ .str = name };
}

/// Calls `watch` when the events with a handler change.
pub fn rewatch(r: *Refl) Error!void {
    const c = r.c;
    const now: u8 = @as(u8, @intFromBool(c.on_read != null)) | @as(u8, @intFromBool(c.on_write != null)) << 1;
    if (now == r.watching) return;
    r.watching = now;
    var evs: std.ArrayList(Value) = .empty;
    if (now & 1 != 0) try evs.append(r.it.alloc(), .{ .str = "read" });
    if (now & 2 != 0) try evs.append(r.it.alloc(), .{ .str = "write" });
    _ = try r.call(.watch, &.{try value.wrapList(r.it.alloc(), evs.items)});
}

/// `chan postevent channel eventspec`.
pub fn postevent(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len != 4) return it.wrongArgs("chan postevent channel eventspec");
    const name = try it.str(argv[2]);
    const c = it.chans.table.get(name) orelse
        return it.failWord("TCL LOOKUP CHANNEL", name, "can not find reflected channel named \"{s}\"", .{name});
    const r = c.refl orelse
        return it.failWord("TCL LOOKUP CHANNEL", name, "can not find reflected channel named \"{s}\"", .{name});
    const evs = try it.list(argv[3]);
    if (evs.len == 0) return it.fail("bad event list: is empty", .{});
    var mask: u8 = 0;
    for (evs) |w| {
        const e = try it.str(w);
        if (eql(e, "read")) mask |= 1 else if (eql(e, "write")) mask |= 2 else return it.failWord("TCL LOOKUP INDEX event", e, "bad event \"{s}\": must be read or write", .{e});
    }
    if (mask & ~r.watching != 0) return it.fail("tried to post events channel \"{s}\" is not interested in", .{name});
    r.posted |= mask;
    try event.watch(it, name);
    return Value.empty;
}

/// True when a posted event has a handler to run.
pub fn ready(r: *const Refl) bool {
    const c = r.c;
    const buffered = c.on_read != null and c.rpos < c.rbuf.items.len and !c.blocked;
    return (r.posted & 1 != 0 and c.on_read != null) or (r.posted & 2 != 0 and c.on_write != null) or buffered;
}

/// Runs the handlers of the posted events.
pub fn serve(cur: *Interp, it: *Interp, r: *Refl) Error!bool {
    const c = r.c;
    const buffered = c.on_read != null and c.rpos < c.rbuf.items.len and !c.blocked;
    const rd = r.posted & 1 != 0 or buffered;
    const wr = r.posted & 2 != 0;
    r.posted = 0;
    return chan.serve(cur, it, c.name, rd, wr);
}

/// `seek` of a reflected channel: `whence` is 0, 1, or 2. Gives the new
/// place, or null for a handler with no `seek`.
pub fn seek(it: *Interp, r: *Refl, off: i64, whence: usize) Error!?i64 {
    if (!r.has(.seek)) return null;
    const base: []const u8 = switch (whence) {
        0 => "start",
        1 => "current",
        else => "end",
    };
    const got = try it.int(try r.call(.seek, &.{ .{ .int = off }, .{ .str = base } }));
    if (got < 0) return it.fail("Huh, seek returned negative location", .{});
    return got;
}

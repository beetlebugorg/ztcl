//! The channel slots of the stubs table, for the native path and the
//! WebAssembly path: the generic layer of the channels of a package.
//!
//! A channel of a package has a `Tcl_ChannelType` of C. This file has
//! the buffers, the translation of line ends, the encodings `utf-8`,
//! `iso8859-1`, and `binary`, the options, the stacks of transforms, the
//! channel handlers, and the close handlers, as in Tcl 8.6. The text of
//! the slots is in the modified UTF-8 of Tcl, where U+0000 is the two
//! bytes C0 80.
//!
//! A channel of ztcl (`stdout`, a channel of `open`) is a channel of the
//! type `ztcl_type` here. Its operations run as scripts in the interp of ztcl
//! (`read`, `puts`, `fconfigure`), so the generic layer of ztcl applies
//! to them. A transform that a package stacks on a channel of ztcl reads
//! and writes the bytes of that channel with `-translation binary`.
//!
//! In the native path, `Tcl_RegisterChannel` also makes the channel a
//! channel of the interp of ztcl, and the channel commands of a script
//! call this layer (`native.zig`). The WebAssembly library has no
//! channel commands, so there only C code reaches a channel of a package.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const obj = @import("obj.zig");
const host = @import("host.zig");
const Interp = obj.Interp;
const Obj = obj.Obj;
const DString = obj.DString;
const OK = obj.OK;
const ERROR = obj.ERROR;
const panicText = obj.panicText;

const gpa = std.heap.c_allocator;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();

const TCL_READABLE: c_int = 1 << 1;
const TCL_WRITABLE: c_int = 1 << 2;
const TCL_STDIN: c_int = 1 << 1;
const TCL_STDOUT: c_int = 1 << 2;
const TCL_STDERR: c_int = 1 << 3;
const TCL_CLOSE_WRITE: c_int = 1 << 2;
const TCL_MODE_BLOCKING: c_int = 0;
const TCL_MODE_NONBLOCKING: c_int = 1;
const EAGAIN: c_int = if (builtin.os.tag == .macos) 35 else if (builtin.os.tag == .wasi) 6 else 11;
const EINVAL: c_int = if (builtin.os.tag == .wasi) 28 else 22;
const EIO: c_int = if (builtin.os.tag == .wasi) 29 else 5;
const EACCES: c_int = if (builtin.os.tag == .wasi) 2 else 13;

/// The largest value of `-buffersize`.
const max_buffer: c_int = 1 << 20;

pub const CloseFn = *const fn (?*anyopaque, ?*Interp) callconv(.c) c_int;
pub const InputFn = *const fn (?*anyopaque, [*]u8, c_int, *c_int) callconv(.c) c_int;
pub const OutputFn = *const fn (?*anyopaque, [*]const u8, c_int, *c_int) callconv(.c) c_int;
pub const SeekFn = *const fn (?*anyopaque, c_long, c_int, *c_int) callconv(.c) c_int;
pub const SetOptionFn = *const fn (?*anyopaque, ?*Interp, [*:0]const u8, [*:0]const u8) callconv(.c) c_int;
pub const GetOptionFn = *const fn (?*anyopaque, ?*Interp, ?[*:0]const u8, *DString) callconv(.c) c_int;
pub const WatchFn = *const fn (?*anyopaque, c_int) callconv(.c) void;
pub const GetHandleFn = *const fn (?*anyopaque, c_int, *?*anyopaque) callconv(.c) c_int;
pub const Close2Fn = *const fn (?*anyopaque, ?*Interp, c_int) callconv(.c) c_int;
pub const BlockModeFn = *const fn (?*anyopaque, c_int) callconv(.c) c_int;
pub const FlushFn = *const fn (?*anyopaque) callconv(.c) c_int;
pub const HandlerFn = *const fn (?*anyopaque, c_int) callconv(.c) c_int;
pub const WideSeekFn = *const fn (?*anyopaque, i64, c_int, *c_int) callconv(.c) i64;
pub const ThreadActionFn = *const fn (?*anyopaque, c_int) callconv(.c) void;
pub const TruncateFn = *const fn (?*anyopaque, i64) callconv(.c) c_int;

/// `Tcl_ChannelType` of Tcl 8.6. The fields after `close2` are in a type
/// of version 2 or more, and each later version adds one field.
pub const ChannelType = extern struct {
    name: ?[*:0]const u8,
    version: ?*const anyopaque,
    close: ?CloseFn,
    input: ?InputFn,
    output: ?OutputFn,
    seek: ?SeekFn,
    set_option: ?SetOptionFn,
    get_option: ?GetOptionFn,
    watch: ?WatchFn,
    get_handle: ?GetHandleFn,
    close2: ?Close2Fn,
    block_mode: ?BlockModeFn = null,
    flush: ?FlushFn = null,
    handler: ?HandlerFn = null,
    wide_seek: ?WideSeekFn = null,
    thread_action: ?ThreadActionFn = null,
    truncate: ?TruncateFn = null,
};

/// The `closeProc` value that tells Tcl to call `close2Proc`.
const TCL_CLOSE2PROC: usize = 1;

/// The version of a channel type: 1 for a type of the layout of Tcl 8.3,
/// where the second field is the block mode proc.
fn version(t: *const ChannelType) usize {
    const v = @intFromPtr(t.version);
    return if (v >= 2 and v <= 5) v else 1;
}

pub const Translation = enum { auto, lf, cr, crlf };
pub const Encoding = enum { utf8, latin1, binary };
pub const Buffering = enum { full, line, none };

/// One channel of a stack. `Tcl_Channel` is a pointer to it.
pub const Channel = struct {
    type: *const ChannelType,
    data: ?*anyopaque,
    mask: c_int,
    state: *State,
    /// The channel below this one in the stack, and the one above.
    down: ?*Channel = null,
    up: ?*Channel = null,
};

const HandlerProc = *const fn (?*anyopaque, c_int) callconv(.c) void;
const CloseProc = *const fn (?*anyopaque) callconv(.c) void;
const Handler = struct { mask: c_int, proc: HandlerProc, cd: ?*anyopaque };
const CloseHandler = struct { proc: CloseProc, cd: ?*anyopaque };

/// The state that the channels of one stack share: the name, the
/// options, and the buffers.
pub const State = struct {
    name: [:0]u8,
    top: *Channel,
    mask: c_int,
    refs: c_int = 0,
    in_tr: Translation = .auto,
    out_tr: Translation = .lf,
    enc: Encoding = .utf8,
    buffering: Buffering = .full,
    buffer_size: c_int = 4096,
    blocking: bool = true,
    eof_in: u8 = 0,
    eof_out: u8 = 0,
    /// The raw input bytes, read from `rpos`.
    rbuf: std.ArrayList(u8) = .empty,
    rpos: usize = 0,
    /// The output bytes after the translation and the encoding.
    wbuf: std.ArrayList(u8) = .empty,
    /// True when the input proc gave the end of the data.
    hit_eof: bool = false,
    /// True when the last read ended at the end of the data.
    eof: bool = false,
    /// True when the last read found no data in a channel that blocks.
    blocked: bool = false,
    /// True after a CR of `-translation auto` that ended the input of a
    /// read. A LF that comes first in the next input goes.
    saw_cr: bool = false,
    handlers: std.ArrayList(Handler) = .empty,
    close_handlers: std.ArrayList(CloseHandler) = .empty,
    /// The interps that registered the channel.
    interps: std.ArrayList(*Interp) = .empty,
    err: ?*Obj = null,
    /// True when the interp of ztcl has the channel (`native.zig`).
    in_ztcl: bool = false,
    /// The interp of ztcl and its channel record while a script of
    /// `fileevent` waits on the channel (`native.zig`).
    ev_it: ?*anyopaque = null,
    ev_chan: ?*anyopaque = null,
};

/// A channel of ztcl: its name in the interp of ztcl `handle`.
const Link = struct { handle: u32, name: [:0]u8 };

/// The state of the channels of one interp of a package.
const PerInterp = struct {
    chans: std.ArrayList(*State) = .empty,
    err: ?*Obj = null,
};

/// The open channels of the thread, and the channels of ztcl that the
/// package has.
threadlocal var all: std.ArrayList(*State) = .empty;
/// The standard channels that `Tcl_SetStdChannel` set.
threadlocal var std_set: [3]?*Channel = .{ null, null, null };
threadlocal var std_isset: [3]bool = .{ false, false, false };
/// A byte whose address is the id of the thread.
threadlocal var thread_mark: u8 = 0;

/// The interp of the last command of the package. A slot with no
/// interp argument uses it to reach ztcl.
pub threadlocal var last: ?*Interp = null;

/// The hooks of the native path for the channels of the interp of ztcl.
/// The WebAssembly path has none.
pub const Hooks = struct {
    /// Makes channel `name` of the package a channel of ztcl.
    register: *const fn (handle: u32, name: []const u8, st: *State) void,
    /// Removes channel `name` of the package from ztcl.
    unregister: *const fn (handle: u32, name: []const u8) void,
    /// Moves channel `name` of ztcl to a hidden name, and makes `name`
    /// a channel of ztcl that reaches `st`. Gives the hidden name.
    stack: *const fn (handle: u32, name: []const u8, st: *State) ?[]const u8,
    /// Moves channel `hidden` of ztcl back to `name`.
    unstack: *const fn (handle: u32, name: []const u8, hidden: []const u8) void,
    /// Makes a channel of ztcl on descriptor `fd`. Gives its name.
    adopt: *const fn (handle: u32, fd: c_int, mask: c_int, sock: bool) ?[]const u8,
};

pub var hooks: ?Hooks = null;

fn oom() noreturn {
    panicText("out of memory");
}

fn setErrno(e: c_int) void {
    if (comptime @TypeOf(std.c._errno) != void) std.c._errno().* = e;
}

fn getErrno() c_int {
    if (comptime @TypeOf(std.c._errno) != void) return std.c._errno().*;
    return 0;
}

fn perInterp(ip: *Interp) *PerInterp {
    if (ip.chans) |p| return @ptrCast(@alignCast(p));
    const p = gpa.create(PerInterp) catch oom();
    p.* = .{};
    ip.chans = p;
    return p;
}

fn newState(t: *const ChannelType, name: []const u8, data: ?*anyopaque, mask: c_int) *Channel {
    const c = gpa.create(Channel) catch oom();
    const st = gpa.create(State) catch oom();
    st.* = .{ .name = gpa.dupeSentinel(u8, name, 0) catch oom(), .top = c, .mask = mask };
    c.* = .{ .type = t, .data = data, .mask = mask, .state = st };
    all.append(gpa, st) catch oom();
    return c;
}

fn freeState(st: *State) void {
    if (std.mem.indexOfScalar(*State, all.items, st)) |i| _ = all.swapRemove(i);
    for (&std_set) |*s| if (s.* != null and s.*.?.state == st) {
        s.* = null;
    };
    st.rbuf.deinit(gpa);
    st.wbuf.deinit(gpa);
    st.handlers.deinit(gpa);
    st.close_handlers.deinit(gpa);
    st.interps.deinit(gpa);
    if (st.err) |e| obj.decr(e);
    gpa.free(st.name);
    gpa.destroy(st);
}

// ---- The channels of ztcl ----

fn linkOf(c: *Channel) ?*Link {
    return if (c.type == &ztcl_type) @ptrCast(@alignCast(c.data)) else null;
}

/// Runs a script of the words `words` in the interp of ztcl `handle`.
/// Gives the code, with the result in `host.reply`.
fn run(handle: u32, words: []const []const u8) c_int {
    var ds: DString = undefined;
    obj.Tcl_DStringInit(&ds);
    defer obj.Tcl_DStringFree(&ds);
    for (words) |w| {
        const z = gpa.dupeSentinel(u8, w, 0) catch oom();
        defer gpa.free(z);
        _ = obj.Tcl_DStringAppendElement(&ds, z);
    }
    return host.host.eval(handle, ds.string, @intCast(ds.length), 0);
}

/// The text of the reply of the last call to ztcl, in C memory.
fn replyText() []u8 {
    const o = host.objOf(host.reply);
    obj.incr(o);
    defer obj.decr(o);
    return gpa.dupe(u8, obj.text(o)) catch oom();
}

fn replyInt() i64 {
    const t = replyText();
    defer gpa.free(t);
    return std.fmt.parseInt(i64, t, 10) catch -1;
}

/// The bytes of text where each character is one byte (`binary`).
fn bytesOfText(t: []const u8) []u8 {
    const out = gpa.alloc(u8, t.len) catch oom();
    var n: usize = 0;
    var i: usize = 0;
    while (i < t.len) {
        const cp = decodeOne(t[i..]);
        out[n] = @truncate(cp.cp);
        n += 1;
        i += cp.len;
    }
    return out[0..n];
}

/// The text with one character for each byte.
fn textOfBytes(b: []const u8) std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(gpa, b.len * 2) catch oom();
    for (b) |x| appendCp(&out, x);
    return out;
}

fn ztclInput(d: ?*anyopaque, buf: [*]u8, n: c_int, err: *c_int) callconv(.c) c_int {
    const l: *Link = @ptrCast(@alignCast(d));
    var nb: [24]u8 = undefined;
    const ns = std.fmt.bufPrint(&nb, "{d}", .{n}) catch unreachable;
    if (run(l.handle, &.{ "read", l.name, ns }) != OK) {
        err.* = EIO;
        return -1;
    }
    const t = replyText();
    defer gpa.free(t);
    const b = bytesOfText(t);
    defer gpa.free(b);
    @memcpy(buf[0..b.len], b);
    if (b.len == 0 and run(l.handle, &.{ "fblocked", l.name }) == OK and replyInt() == 1) {
        err.* = EAGAIN;
        return -1;
    }
    return @intCast(b.len);
}

fn ztclOutput(d: ?*anyopaque, buf: [*]const u8, n: c_int, err: *c_int) callconv(.c) c_int {
    const l: *Link = @ptrCast(@alignCast(d));
    var t = textOfBytes(buf[0..@intCast(n)]);
    defer t.deinit(gpa);
    if (run(l.handle, &.{ "puts", "-nonewline", l.name, t.items }) != OK) {
        err.* = EIO;
        return -1;
    }
    return n;
}

fn ztclClose(d: ?*anyopaque, _: ?*Interp) callconv(.c) c_int {
    const l: *Link = @ptrCast(@alignCast(d));
    const rc = run(l.handle, &.{ "close", l.name });
    gpa.free(l.name);
    gpa.destroy(l);
    return rc;
}

fn ztclBlock(_: ?*anyopaque, _: c_int) callconv(.c) c_int {
    return 0;
}

/// The type of a channel of ztcl. Its name is the name of the type of a
/// file channel of Tcl.
const ztcl_type: ChannelType = .{
    .name = "file",
    .version = @ptrFromInt(5),
    .close = &ztclClose,
    .input = &ztclInput,
    .output = &ztclOutput,
    .seek = null,
    .set_option = null,
    .get_option = null,
    .watch = null,
    .get_handle = null,
    .close2 = null,
    .block_mode = &ztclBlock,
    .flush = null,
    .handler = null,
    .wide_seek = null,
    .thread_action = null,
    .truncate = null,
};

/// The channel of the package for channel `name` of ztcl. Each name has
/// one record, so two lookups give the same channel.
fn ztclChannel(handle: u32, name: []const u8, mask: c_int) *Channel {
    for (all.items) |st| {
        var c: *Channel = st.top;
        while (c.down) |d| c = d;
        if (linkOf(c)) |l| if (l.handle == handle and std.mem.eql(u8, st.name, name)) return st.top;
    }
    const l = gpa.create(Link) catch oom();
    l.* = .{ .handle = handle, .name = gpa.dupeSentinel(u8, name, 0) catch oom() };
    return newState(&ztcl_type, name, l, mask);
}

/// The link of a channel whose top is a channel of ztcl: its operations
/// are scripts of ztcl.
fn direct(st: *State) ?*Link {
    return linkOf(st.top);
}

// ---- Text ----

const Cp = struct { cp: u21, len: usize };

/// The first character of `s`. A byte that starts no valid sequence is
/// the character of the same number, as in Tcl. C0 80 is U+0000.
fn decodeOne(s: []const u8) Cp {
    const b = s[0];
    if (b < 0x80) return .{ .cp = b, .len = 1 };
    const n = std.unicode.utf8ByteSequenceLength(b) catch return .{ .cp = b, .len = 1 };
    if (n > s.len) return .{ .cp = b, .len = 1 };
    if (n == 2 and b == 0xC0 and s[1] == 0x80) return .{ .cp = 0, .len = 2 };
    const cp = std.unicode.utf8Decode(s[0..n]) catch return .{ .cp = b, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// Appends character `cp` in modified UTF-8.
fn appendCp(out: *std.ArrayList(u8), cp: u21) void {
    if (cp == 0) {
        out.appendSlice(gpa, "\xC0\x80") catch oom();
        return;
    }
    var b: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &b) catch {
        out.appendSlice(gpa, "\xEF\xBF\xBD") catch oom();
        return;
    };
    out.appendSlice(gpa, b[0..n]) catch oom();
}

// ---- Input ----

const Fill = enum { data, eof, again, err };

/// Reads more raw bytes from the top channel: at most the buffer size.
fn fill(st: *State) Fill {
    if (st.hit_eof) return .eof;
    const c = st.top;
    const input = c.type.input orelse {
        setErrno(EINVAL);
        return .err;
    };
    const n: usize = @intCast(st.buffer_size);
    st.rbuf.ensureUnusedCapacity(gpa, n) catch oom();
    var err: c_int = 0;
    const got = input(c.data, st.rbuf.unusedCapacitySlice().ptr, @intCast(n), &err);
    if (got < 0) {
        if (err == EAGAIN) {
            st.blocked = true;
            return .again;
        }
        setErrno(err);
        return .err;
    }
    if (got == 0) {
        st.hit_eof = true;
        return .eof;
    }
    const old = st.rbuf.items.len;
    st.rbuf.items.len += @intCast(got);
    if (st.eof_in != 0) {
        if (std.mem.indexOfScalarPos(u8, st.rbuf.items, old, st.eof_in)) |k| {
            st.rbuf.items.len = k;
            st.hit_eof = true;
            if (k == old) return .eof;
        }
    }
    return .data;
}

/// Drops the bytes before `rpos`.
fn compact(st: *State) void {
    if (st.rpos == 0) return;
    const rest = st.rbuf.items.len - st.rpos;
    std.mem.copyForwards(u8, st.rbuf.items[0..rest], st.rbuf.items[st.rpos..]);
    st.rbuf.items.len = rest;
    st.rpos = 0;
}

/// The result of `cook`: a byte, or why there is none.
const Next = union(enum) { byte: u8, eof, again, err };

/// The next input byte after the translation of line ends.
fn cook(st: *State) Next {
    while (true) {
        if (st.rpos >= st.rbuf.items.len) {
            switch (fill(st)) {
                .data => {},
                .eof => return .eof,
                .again => return .again,
                .err => return .err,
            }
            continue;
        }
        var b = st.rbuf.items[st.rpos];
        st.rpos += 1;
        if (st.saw_cr) {
            st.saw_cr = false;
            if (b == '\n') continue;
        }
        switch (st.in_tr) {
            .lf => {},
            .cr => if (b == '\r') {
                b = '\n';
            },
            .crlf => if (b == '\r') {
                if (st.rpos >= st.rbuf.items.len) _ = fill(st);
                if (st.rpos < st.rbuf.items.len and st.rbuf.items[st.rpos] == '\n') {
                    st.rpos += 1;
                    b = '\n';
                }
            },
            .auto => if (b == '\r') {
                b = '\n';
                if (st.rpos < st.rbuf.items.len) {
                    if (st.rbuf.items[st.rpos] == '\n') st.rpos += 1;
                } else st.saw_cr = true;
            },
        }
        return .{ .byte = b };
    }
}

/// Reads at most `max` bytes after the translation (all for null) into
/// `out`. Gives false on an error.
fn readBytes(st: *State, out: *std.ArrayList(u8), max: ?usize) bool {
    var n: usize = 0;
    while (max == null or n < max.?) : (n += 1) {
        switch (cook(st)) {
            .byte => |b| out.append(gpa, b) catch oom(),
            .err => return false,
            .eof => {
                st.eof = true;
                return true;
            },
            .again => return true,
        }
    }
    return true;
}

/// The text of input bytes in the encoding of the channel.
fn decode(st: *const State, raw: []const u8, out: *std.ArrayList(u8)) void {
    switch (st.enc) {
        .latin1, .binary => for (raw) |b| appendCp(out, b),
        .utf8 => {
            var i: usize = 0;
            while (i < raw.len) {
                if (raw[i] != 0 and raw[i] < 0x80) {
                    out.append(gpa, raw[i]) catch oom();
                    i += 1;
                    continue;
                }
                const cp = decodeOne(raw[i..]);
                appendCp(out, cp.cp);
                i += cp.len;
            }
        },
    }
}

/// Reads `n` characters (all for null) and appends their text to `out`.
/// Gives the count of characters, or null on an error.
fn readChars(st: *State, out: *std.ArrayList(u8), n: ?usize) ?usize {
    if (st.enc != .utf8) {
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(gpa);
        if (!readBytes(st, &raw, n)) return null;
        decode(st, raw.items, out);
        return raw.items.len;
    }
    var count: usize = 0;
    var seq: [4]u8 = undefined;
    while (n == null or count < n.?) : (count += 1) {
        const first = switch (cook(st)) {
            .byte => |b| b,
            .err => return null,
            .eof => {
                st.eof = true;
                break;
            },
            .again => break,
        };
        seq[0] = first;
        var k: usize = 1;
        const want = std.unicode.utf8ByteSequenceLength(first) catch 1;
        while (k < want) : (k += 1) {
            // A byte that is not a continuation stays for the next one.
            if (st.rpos >= st.rbuf.items.len) {
                if (fill(st) != .data) break;
            }
            const b = st.rbuf.items[st.rpos];
            if (b & 0xC0 != 0x80) break;
            seq[k] = b;
            st.rpos += 1;
        }
        decode(st, seq[0..k], out);
    }
    return count;
}

/// What `getLine` found.
const Line = enum { line, partial, none, err };

/// Reads one line of bytes after the translation into `out`, with no
/// line end. With no whole line in a channel that blocks, the input
/// stays for the next read.
fn getLine(st: *State, out: *std.ArrayList(u8)) Line {
    compact(st);
    const pos = st.rpos;
    const cr = st.saw_cr;
    const start = out.items.len;
    while (true) {
        switch (cook(st)) {
            .byte => |b| {
                if (b == '\n') return .line;
                out.append(gpa, b) catch oom();
            },
            .err => return .err,
            .eof => {
                st.eof = true;
                return if (out.items.len > start) .partial else .none;
            },
            .again => {
                st.rpos = pos;
                st.saw_cr = cr;
                out.items.len = start;
                return .none;
            },
        }
    }
}

/// Starts a read: clears the flags of the last one.
fn startRead(st: *State) void {
    st.blocked = false;
    st.eof = false;
    if (st.rpos >= st.rbuf.items.len) {
        st.rbuf.items.len = 0;
        st.rpos = 0;
    }
}

fn canRead(st: *State) bool {
    if (st.mask & TCL_READABLE != 0) return true;
    setErrno(EACCES);
    return false;
}

fn canWrite(st: *State) bool {
    if (st.mask & TCL_WRITABLE != 0) return true;
    setErrno(EACCES);
    return false;
}

// ---- Output ----

/// Writes the output buffer with the output proc of the top channel.
fn flushOut(st: *State) c_int {
    if (st.wbuf.items.len == 0) return OK;
    const c = st.top;
    const output = c.type.output orelse {
        setErrno(EINVAL);
        return ERROR;
    };
    var at: usize = 0;
    while (at < st.wbuf.items.len) {
        var err: c_int = 0;
        const n = output(c.data, st.wbuf.items[at..].ptr, @intCast(st.wbuf.items.len - at), &err);
        if (n < 0) {
            st.wbuf.items.len = 0;
            setErrno(err);
            return ERROR;
        }
        if (n == 0) break;
        at += @intCast(n);
    }
    st.wbuf.items.len = 0;
    return OK;
}

/// Puts bytes in the output buffer with the translation of line ends.
/// Gives the count of bytes after the translation.
fn put(st: *State, bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |b| {
        if (b == '\n') switch (st.out_tr) {
            .cr => {
                st.wbuf.append(gpa, '\r') catch oom();
                n += 1;
                continue;
            },
            .crlf => {
                st.wbuf.appendSlice(gpa, "\r\n") catch oom();
                n += 2;
                continue;
            },
            else => {},
        };
        st.wbuf.append(gpa, b) catch oom();
        n += 1;
    }
    return n;
}

/// Flushes after a write as the buffering of the channel asks.
fn afterWrite(st: *State, bytes: []const u8) c_int {
    const flush = switch (st.buffering) {
        .none => true,
        .line => std.mem.indexOfScalar(u8, bytes, '\n') != null,
        .full => st.wbuf.items.len >= @as(usize, @intCast(st.buffer_size)),
    };
    return if (flush) flushOut(st) else OK;
}

/// The bytes of text in the encoding of the channel.
fn encode(st: *const State, t: []const u8, out: *std.ArrayList(u8)) void {
    var i: usize = 0;
    while (i < t.len) {
        const cp = decodeOne(t[i..]);
        switch (st.enc) {
            .utf8 => if (cp.cp == 0) out.append(gpa, 0) catch oom() else out.appendSlice(gpa, t[i..][0..cp.len]) catch oom(),
            .latin1, .binary => out.append(gpa, if (cp.cp < 256) @intCast(cp.cp) else '?') catch oom(),
        }
        i += cp.len;
    }
}

fn writeBytes(st: *State, bytes: []const u8) c_int {
    if (!canWrite(st)) return -1;
    const n = put(st, bytes);
    if (afterWrite(st, bytes) != OK) return -1;
    return @intCast(n);
}

fn writeText(st: *State, t: []const u8) c_int {
    if (!canWrite(st)) return -1;
    if (direct(st)) |l| {
        if (run(l.handle, &.{ "puts", "-nonewline", l.name, t }) != OK) {
            setErrno(EIO);
            return -1;
        }
        return @intCast(t.len);
    }
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    encode(st, t, &b);
    return writeBytes(st, b.items);
}

fn span(p: [*]const u8, len: c_int) []const u8 {
    return if (len < 0) std.mem.span(@as([*:0]const u8, @ptrCast(p))) else p[0..@intCast(len)];
}

// ---- The slots ----

pub fn Tcl_CreateChannel(t: *const ChannelType, name: ?[*:0]const u8, data: ?*anyopaque, mask: c_int) callconv(.c) *Channel {
    return newState(t, if (name) |p| std.mem.span(p) else "", data, mask);
}

pub fn Tcl_GetChannelName(c: *Channel) callconv(.c) [*:0]const u8 {
    return c.state.name.ptr;
}

pub fn Tcl_GetChannelType(c: *Channel) callconv(.c) *const ChannelType {
    return c.type;
}

pub fn Tcl_GetChannelInstanceData(c: *Channel) callconv(.c) ?*anyopaque {
    return c.data;
}

pub fn Tcl_GetChannelMode(c: *Channel) callconv(.c) c_int {
    return c.state.mask;
}

pub fn Tcl_GetChannelBufferSize(c: *Channel) callconv(.c) c_int {
    return c.state.buffer_size;
}

pub fn Tcl_SetChannelBufferSize(c: *Channel, n: c_int) callconv(.c) void {
    c.state.buffer_size = std.math.clamp(n, 1, max_buffer);
}

pub fn Tcl_GetChannelHandle(c: *Channel, dir: c_int, out: *?*anyopaque) callconv(.c) c_int {
    const f = c.type.get_handle orelse return ERROR;
    return f(c.data, dir, out);
}

pub fn Tcl_GetChannelThread(_: *Channel) callconv(.c) ?*anyopaque {
    return &thread_mark;
}

pub fn Tcl_GetStackedChannel(c: *Channel) callconv(.c) ?*Channel {
    return c.down;
}

pub fn Tcl_GetTopChannel(c: *Channel) callconv(.c) *Channel {
    return c.state.top;
}

pub fn Tcl_IsChannelShared(c: *Channel) callconv(.c) c_int {
    return @intFromBool(c.state.refs > 1);
}

pub fn Tcl_IsChannelRegistered(ip: *Interp, c: *Channel) callconv(.c) c_int {
    return @intFromBool(std.mem.indexOfScalar(*Interp, c.state.interps.items, ip) != null);
}

pub fn Tcl_IsChannelExisting(name: [*:0]const u8) callconv(.c) c_int {
    const n = std.mem.span(name);
    for (all.items) |st| if (std.mem.eql(u8, st.name, n) and direct(st) == null) return 1;
    const ip = last orelse return 0;
    return @intFromBool(ztclMode(ip.handle, n) != null);
}

pub fn Tcl_IsStandardChannel(c: *Channel) callconv(.c) c_int {
    for (0..3) |i| if (stdChannel(i) == c.state.top) return 1;
    return 0;
}

pub fn Tcl_RegisterChannel(ip: ?*Interp, c: ?*Channel) callconv(.c) void {
    const ch = c orelse return;
    const st = ch.state;
    st.refs += 1;
    const i = ip orelse return;
    st.interps.append(gpa, i) catch oom();
    perInterp(i).chans.append(gpa, st) catch oom();
    if (hooks) |h| if (direct(st) == null and !st.in_ztcl) {
        st.in_ztcl = true;
        h.register(i.handle, st.name, st);
    };
}

/// Removes `st` from the channels of `ip`. Gives false when `ip` did
/// not register it.
fn forget(ip: *Interp, st: *State) bool {
    const p = perInterp(ip);
    const k = std.mem.indexOfScalar(*State, p.chans.items, st) orelse return false;
    _ = p.chans.orderedRemove(k);
    if (std.mem.indexOfScalar(*Interp, st.interps.items, ip)) |j| _ = st.interps.orderedRemove(j);
    if (st.in_ztcl and st.interps.items.len == 0 and direct(st) == null) {
        st.in_ztcl = false;
        if (hooks) |h| h.unregister(ip.handle, st.name);
    }
    return true;
}

/// Removes one reference. The last one closes the channel.
pub fn Tcl_UnregisterChannel(ip: ?*Interp, c: *Channel) callconv(.c) c_int {
    const st = c.state;
    if (ip) |i| {
        if (!forget(i, st) and direct(st) == null) {
            obj.setResultText(i, "Tcl_UnregisterChannel: channel not found");
            return ERROR;
        }
    }
    st.refs -= 1;
    if (st.refs > 0) return flushOut(st);
    return closeAll(ip, st);
}

pub fn Tcl_DetachChannel(ip: ?*Interp, c: *Channel) callconv(.c) c_int {
    const i = ip orelse return ERROR;
    if (!forget(i, c.state)) return ERROR;
    c.state.refs -= 1;
    return OK;
}

/// Closes one channel of a stack with its type.
fn closeOne(ip: ?*Interp, c: *Channel) c_int {
    const t = c.type;
    const rc: c_int = if (t.close != null and @intFromPtr(t.close.?) != TCL_CLOSE2PROC)
        t.close.?(c.data, ip)
    else if (version(t) >= 2 and t.close2 != null) t.close2.?(c.data, ip, 0) else OK;
    gpa.destroy(c);
    return rc;
}

/// Flushes and closes the whole stack of `st`, and frees it.
fn closeAll(ip: ?*Interp, st: *State) c_int {
    var rc = flushOut(st);
    const handlers = st.close_handlers.toOwnedSlice(gpa) catch oom();
    defer gpa.free(handlers);
    for (handlers) |h| h.proc(h.cd);
    if (st.in_ztcl) if (hooks) |h| {
        const handle = if (st.interps.items.len > 0) st.interps.items[0].handle else if (ip) |i| i.handle else 0;
        // A stack on a channel of ztcl closes that channel below.
        if (handle != 0 and direct(st) == null) {
            var bottom = st.top;
            while (bottom.down) |d| bottom = d;
            if (linkOf(bottom) == null) h.unregister(handle, st.name) else if (linkOf(bottom)) |l| h.unstack(handle, st.name, l.name);
        }
    };
    for (st.interps.items) |i| {
        const p = perInterp(i);
        if (std.mem.indexOfScalar(*State, p.chans.items, st)) |k| _ = p.chans.orderedRemove(k);
    }
    // The channel of ztcl at the bottom has its own name again.
    var bottom = st.top;
    while (bottom.down) |d| bottom = d;
    if (linkOf(bottom)) |l| if (bottom != st.top) {
        gpa.free(l.name);
        l.name = gpa.dupeSentinel(u8, st.name, 0) catch oom();
    };
    var c: ?*Channel = st.top;
    while (c) |ch| {
        c = ch.down;
        const r = closeOne(ip, ch);
        if (rc == OK) rc = r;
    }
    freeState(st);
    return rc;
}

pub fn Tcl_Close(ip: ?*Interp, c: ?*Channel) callconv(.c) c_int {
    const ch = c orelse return OK;
    // The channel goes from each interp that has it.
    return closeAll(ip, ch.state);
}

pub fn Tcl_CloseEx(ip: ?*Interp, c: *Channel, flags: c_int) callconv(.c) c_int {
    if (flags == 0) return Tcl_Close(ip, c);
    const st = c.state;
    if (flags & TCL_CLOSE_WRITE != 0) _ = flushOut(st);
    const t = st.top.type;
    if (version(t) >= 2) if (t.close2) |f| {
        const rc = f(st.top.data, ip, flags);
        if (rc == OK) st.mask &= ~flags;
        return rc;
    };
    if (ip) |i| obj.setResultText(i, "the channel does not support a half close");
    return ERROR;
}

pub fn Tcl_Write(c: *Channel, bytes: [*]const u8, len: c_int) callconv(.c) c_int {
    const st = c.state;
    if (direct(st) != null) return writeText(st, span(bytes, len));
    return writeBytes(st, span(bytes, len));
}

pub fn Tcl_WriteChars(c: *Channel, t: [*]const u8, len: c_int) callconv(.c) c_int {
    return writeText(c.state, span(t, len));
}

pub fn Tcl_WriteObj(c: *Channel, o: *Obj) callconv(.c) c_int {
    return writeText(c.state, obj.text(o));
}

/// Writes bytes with the output proc of channel `c`, below the buffers.
pub fn Tcl_WriteRaw(c: *Channel, bytes: [*]const u8, len: c_int) callconv(.c) c_int {
    const output = c.type.output orelse return -1;
    var err: c_int = 0;
    const b = span(bytes, len);
    const n = output(c.data, b.ptr, @intCast(b.len), &err);
    if (n < 0) setErrno(err);
    return n;
}

/// Reads bytes with the input proc of channel `c`, below the buffers.
pub fn Tcl_ReadRaw(c: *Channel, buf: [*]u8, len: c_int) callconv(.c) c_int {
    const st = c.state;
    // Input in the buffer of the stack goes first, for the top only.
    if (c == st.top and st.rpos < st.rbuf.items.len) {
        const k = @min(st.rbuf.items.len - st.rpos, @as(usize, @intCast(len)));
        @memcpy(buf[0..k], st.rbuf.items[st.rpos..][0..k]);
        st.rpos += k;
        return @intCast(k);
    }
    const input = c.type.input orelse return -1;
    var err: c_int = 0;
    const n = input(c.data, buf, len, &err);
    if (n < 0) {
        if (err == EAGAIN and c == st.top) st.blocked = true;
        setErrno(err);
    }
    return n;
}

pub fn Tcl_Read(c: *Channel, buf: [*]u8, len: c_int) callconv(.c) c_int {
    const st = c.state;
    if (!canRead(st)) return -1;
    if (direct(st) != null) {
        const o = obj.Tcl_NewObj();
        obj.incr(o);
        defer obj.decr(o);
        if (Tcl_ReadChars(c, o, len, 0) < 0) return -1;
        const t = obj.text(o);
        const k = @min(t.len, @as(usize, @intCast(len)));
        @memcpy(buf[0..k], t[0..k]);
        return @intCast(k);
    }
    startRead(st);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (!readBytes(st, &out, @intCast(len))) return -1;
    @memcpy(buf[0..out.items.len], out.items);
    return @intCast(out.items.len);
}

pub fn Tcl_ReadChars(c: *Channel, o: *Obj, n: c_int, append: c_int) callconv(.c) c_int {
    const st = c.state;
    if (!canRead(st)) return -1;
    if (direct(st)) |l| {
        var nb: [24]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{n}) catch unreachable;
        const rc = if (n < 0) run(l.handle, &.{ "read", l.name }) else run(l.handle, &.{ "read", l.name, ns });
        if (rc != OK) {
            setErrno(EIO);
            return -1;
        }
        const t = replyText();
        defer gpa.free(t);
        obj.freeIntRep(o);
        if (append == 0) obj.setText(o, t) else obj.appendText(o, t);
        return @intCast(obj.charCount(t));
    }
    startRead(st);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const got = readChars(st, &out, if (n < 0) null else @intCast(n)) orelse return -1;
    obj.freeIntRep(o);
    if (append == 0) obj.setText(o, out.items) else obj.appendText(o, out.items);
    return @intCast(got);
}

/// Reads a line into `out`. Gives the count of characters, or -1.
fn gets(c: *Channel, out: *std.ArrayList(u8)) c_int {
    const st = c.state;
    if (!canRead(st)) return -1;
    if (direct(st)) |l| {
        if (run(l.handle, &.{ "::apply", "c {list [gets $c l] $l}", l.name }) != OK) {
            setErrno(EIO);
            return -1;
        }
        const r = host.objOf(host.reply);
        obj.incr(r);
        defer obj.decr(r);
        var items: [*]*Obj = undefined;
        var k: c_int = 0;
        if (obj.Tcl_ListObjGetElements(null, r, &k, &items) != OK or k != 2) return -1;
        var count: c_long = 0;
        _ = obj.Tcl_GetLongFromObj(null, items[0], &count);
        if (count >= 0) out.appendSlice(gpa, obj.text(items[1])) catch oom();
        return @intCast(count);
    }
    startRead(st);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    switch (getLine(st, &raw)) {
        .err, .none => return -1,
        .line, .partial => {},
    }
    const start = out.items.len;
    decode(st, raw.items, out);
    return @intCast(obj.charCount(out.items[start..]));
}

pub fn Tcl_Gets(c: *Channel, ds: *DString) callconv(.c) c_int {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const n = gets(c, &out);
    if (n >= 0) obj.dsAppend(ds, out.items);
    return n;
}

pub fn Tcl_GetsObj(c: *Channel, o: *Obj) callconv(.c) c_int {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const n = gets(c, &out);
    if (n >= 0) {
        obj.freeIntRep(o);
        obj.appendText(o, out.items);
    }
    return n;
}

pub fn Tcl_Ungets(c: *Channel, s: [*]const u8, len: c_int, at_end: c_int) callconv(.c) c_int {
    const st = c.state;
    if (!canRead(st)) return -1;
    const b = span(s, len);
    compact(st);
    if (at_end != 0) st.rbuf.appendSlice(gpa, b) catch oom() else st.rbuf.insertSlice(gpa, 0, b) catch oom();
    st.eof = false;
    st.hit_eof = false;
    return @intCast(b.len);
}

pub fn Tcl_Flush(c: *Channel) callconv(.c) c_int {
    const st = c.state;
    if (direct(st)) |l| {
        if (st.mask & TCL_WRITABLE == 0) return OK;
        // A library with no `flush` writes each `puts` at once.
        _ = run(l.handle, &.{ "::apply", "c {if {[info commands flush] ne {}} {flush $c}}", l.name });
        return OK;
    }
    if (!canWrite(st)) return ERROR;
    const rc = flushOut(st);
    if (rc == OK and version(st.top.type) >= 2) if (st.top.type.flush) |f| {
        _ = f(st.top.data);
    };
    return rc;
}

/// The position of the driver of channel `c`, or -1.
fn driverSeek(c: *Channel, off: i64, whence: c_int) i64 {
    const t = c.type;
    var err: c_int = 0;
    const r: i64 = if (version(t) >= 3 and t.wide_seek != null)
        t.wide_seek.?(c.data, off, whence, &err)
    else if (t.seek) |f| blk: {
        if (off > std.math.maxInt(c_long) or off < std.math.minInt(c_long)) {
            err = EINVAL;
            break :blk -1;
        }
        break :blk f(c.data, @intCast(off), whence, &err);
    } else blk: {
        err = EINVAL;
        break :blk -1;
    };
    if (r < 0) setErrno(err);
    return r;
}

fn canSeek(t: *const ChannelType) bool {
    return t.seek != null or (version(t) >= 3 and t.wide_seek != null);
}

pub fn Tcl_Seek(c: *Channel, off: i64, whence: c_int) callconv(.c) i64 {
    const st = c.state;
    if (direct(st)) |l| {
        var nb: [24]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{off}) catch unreachable;
        const w: []const u8 = switch (whence) {
            1 => "current",
            2 => "end",
            else => "start",
        };
        if (run(l.handle, &.{ "seek", l.name, ns, w }) != OK) {
            setErrno(EINVAL);
            return -1;
        }
        return Tcl_Tell(c);
    }
    if (!canSeek(st.top.type)) {
        setErrno(EINVAL);
        return -1;
    }
    if (flushOut(st) != OK) return -1;
    var o = off;
    // The input in the buffer is ahead of the position of the reader.
    if (whence == 1) o -= @intCast(st.rbuf.items.len - st.rpos);
    st.rbuf.items.len = 0;
    st.rpos = 0;
    st.eof = false;
    st.hit_eof = false;
    st.blocked = false;
    st.saw_cr = false;
    return driverSeek(st.top, o, whence);
}

pub fn Tcl_Tell(c: *Channel) callconv(.c) i64 {
    const st = c.state;
    if (direct(st)) |l| {
        if (run(l.handle, &.{ "tell", l.name }) != OK) return -1;
        return replyInt();
    }
    if (!canSeek(st.top.type)) return -1;
    const p = driverSeek(st.top, 0, 1);
    if (p < 0) return -1;
    return p - @as(i64, @intCast(st.rbuf.items.len - st.rpos)) + @as(i64, @intCast(st.wbuf.items.len));
}

pub fn Tcl_SeekOld(c: *Channel, off: c_int, whence: c_int) callconv(.c) c_int {
    return @truncate(Tcl_Seek(c, off, whence));
}

pub fn Tcl_TellOld(c: *Channel) callconv(.c) c_int {
    return @truncate(Tcl_Tell(c));
}

pub fn Tcl_TruncateChannel(c: *Channel, len: i64) callconv(.c) c_int {
    const st = c.state;
    if (!canWrite(st)) return ERROR;
    const t = st.top.type;
    if (version(t) < 5 or t.truncate == null) {
        setErrno(EINVAL);
        return ERROR;
    }
    if (flushOut(st) != OK) return ERROR;
    st.rbuf.items.len = 0;
    st.rpos = 0;
    return t.truncate.?(st.top.data, len);
}

pub fn Tcl_Eof(c: *Channel) callconv(.c) c_int {
    const st = c.state;
    if (direct(st)) |l| return if (run(l.handle, &.{ "eof", l.name }) == OK) @intCast(replyInt()) else 0;
    return @intFromBool(st.eof);
}

pub fn Tcl_InputBlocked(c: *Channel) callconv(.c) c_int {
    const st = c.state;
    if (direct(st)) |l| return if (run(l.handle, &.{ "fblocked", l.name }) == OK) @intCast(replyInt()) else 0;
    return @intFromBool(st.blocked);
}

fn pending(l: *Link, dir: []const u8) c_int {
    if (run(l.handle, &.{ "chan", "pending", dir, l.name }) != OK) return 0;
    return @intCast(@max(replyInt(), 0));
}

pub fn Tcl_InputBuffered(c: *Channel) callconv(.c) c_int {
    const st = c.state;
    if (direct(st)) |l| return pending(l, "input");
    return @intCast(st.rbuf.items.len - st.rpos);
}

pub fn Tcl_OutputBuffered(c: *Channel) callconv(.c) c_int {
    const st = c.state;
    if (direct(st)) |l| return pending(l, "output");
    return @intCast(st.wbuf.items.len);
}

pub fn Tcl_ChannelBuffered(c: *Channel) callconv(.c) c_int {
    return if (c == c.state.top) Tcl_InputBuffered(c) else 0;
}

// ---- Options ----

const generic_options = [_][]const u8{ "blocking", "buffering", "buffersize", "encoding", "eofchar", "translation" };

pub fn Tcl_BadChannelOption(ip: ?*Interp, name: [*:0]const u8, extra: ?[*:0]const u8) callconv(.c) c_int {
    setErrno(EINVAL);
    const i = ip orelse return ERROR;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    names.appendSlice(gpa, &generic_options) catch oom();
    if (extra) |e| {
        var words = std.mem.tokenizeAny(u8, std.mem.span(e), " \t\n");
        while (words.next()) |w| names.append(gpa, w) catch oom();
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.print(gpa, "bad option \"{s}\": should be one of ", .{std.mem.span(name)}) catch oom();
    for (names.items, 0..) |n, k| {
        if (k > 0) out.appendSlice(gpa, if (k + 1 == names.items.len) ", or " else ", ") catch oom();
        out.print(gpa, "-{s}", .{n}) catch oom();
    }
    obj.setResultText(i, out.items);
    return ERROR;
}

fn encName(e: Encoding) [:0]const u8 {
    return switch (e) {
        .utf8 => "utf-8",
        .latin1 => "iso8859-1",
        .binary => "binary",
    };
}

fn eofName(b: u8, out: *[2]u8) [:0]const u8 {
    if (b == 0) return "";
    out[0] = b;
    out[1] = 0;
    return out[0..1 :0];
}

fn addValue(ds: *DString, s: [:0]const u8, element: bool) void {
    if (element) _ = obj.Tcl_DStringAppendElement(ds, s) else obj.dsAppend(ds, s);
}

/// Appends two values, as a list, or as a sublist for `element`.
fn addPair(ds: *DString, a: [:0]const u8, b: [:0]const u8, element: bool) void {
    if (element) obj.Tcl_DStringStartSublist(ds);
    _ = obj.Tcl_DStringAppendElement(ds, a);
    _ = obj.Tcl_DStringAppendElement(ds, b);
    if (element) obj.Tcl_DStringEndSublist(ds);
}

/// Appends the value of generic option `name` to `ds`. Gives false for
/// an option that is not generic.
fn genericOption(st: *State, name: []const u8, ds: *DString, element: bool) bool {
    var buf: [32]u8 = undefined;
    const rd = st.mask & TCL_READABLE != 0;
    const rw = rd and st.mask & TCL_WRITABLE != 0;
    if (std.mem.eql(u8, name, "-blocking")) {
        addValue(ds, if (st.blocking) "1" else "0", element);
    } else if (std.mem.eql(u8, name, "-buffering")) {
        addValue(ds, @tagName(st.buffering), element);
    } else if (std.mem.eql(u8, name, "-buffersize")) {
        addValue(ds, std.fmt.bufPrintSentinel(&buf, "{d}", .{st.buffer_size}, 0) catch unreachable, element);
    } else if (std.mem.eql(u8, name, "-encoding")) {
        addValue(ds, encName(st.enc), element);
    } else if (std.mem.eql(u8, name, "-eofchar")) {
        var a: [2]u8 = undefined;
        var b: [2]u8 = undefined;
        if (rw) addPair(ds, eofName(st.eof_in, &a), eofName(st.eof_out, &b), element) else addValue(ds, eofName(if (rd) st.eof_in else st.eof_out, &a), element);
    } else if (std.mem.eql(u8, name, "-translation")) {
        const in: [:0]const u8 = @tagName(st.in_tr);
        const out: [:0]const u8 = @tagName(st.out_tr);
        if (rw) addPair(ds, in, out, element) else addValue(ds, if (rd) in else out, element);
    } else return false;
    return true;
}

pub fn Tcl_GetChannelOption(ip: ?*Interp, c: *Channel, name: ?[*:0]const u8, ds: *DString) callconv(.c) c_int {
    const st = c.state;
    if (direct(st)) |l| {
        const rc = if (name) |n| run(l.handle, &.{ "fconfigure", l.name, std.mem.span(n) }) else run(l.handle, &.{ "fconfigure", l.name });
        if (rc != OK) {
            if (ip) |i| host.takeReply(i);
            return ERROR;
        }
        const t = replyText();
        defer gpa.free(t);
        obj.dsAppend(ds, t);
        return OK;
    }
    const top = st.top;
    const get = top.type.get_option;
    if (name) |n| {
        if (genericOption(st, std.mem.span(n), ds, false)) return OK;
        const f = get orelse return Tcl_BadChannelOption(ip, n, null);
        return f(top.data, ip, n, ds);
    }
    for (generic_options) |o| {
        var nb: [16]u8 = undefined;
        const opt = std.fmt.bufPrintSentinel(&nb, "-{s}", .{o}, 0) catch unreachable;
        _ = obj.Tcl_DStringAppendElement(ds, opt);
        _ = genericOption(st, opt, ds, true);
    }
    if (get) |f| return f(top.data, ip, null, ds);
    return OK;
}

fn badValue(ip: ?*Interp, comptime msg: []const u8) c_int {
    if (ip) |i| obj.setResultText(i, msg);
    setErrno(EINVAL);
    return ERROR;
}

fn parseTr(s: []const u8) ?Translation {
    if (std.mem.eql(u8, s, "platform")) return .lf;
    return std.meta.stringToEnum(Translation, s);
}

/// Splits the list `s` into at most 2 elements. Gives the count, or
/// null for a list of more. The caller frees the elements.
fn twoWords(s: [*:0]const u8, out: *[2][]const u8) ?usize {
    const o = obj.Tcl_NewStringObj(s, -1);
    obj.incr(o);
    defer obj.decr(o);
    var items: [*]*Obj = undefined;
    var k: c_int = 0;
    if (obj.Tcl_ListObjGetElements(null, o, &k, &items) != OK or k > 2) return null;
    for (0..@intCast(k)) |i| out[i] = gpa.dupe(u8, obj.text(items[i])) catch oom();
    return @intCast(k);
}

fn setTranslation(ip: ?*Interp, st: *State, v: [*:0]const u8) c_int {
    var w: [2][]const u8 = undefined;
    const n = twoWords(v, &w) orelse return badValue(ip, "bad value for -translation: must be a one or two element list");
    defer for (w[0..n]) |x| gpa.free(x);
    if (n == 0) return OK;
    const rw = st.mask & TCL_READABLE != 0 and st.mask & TCL_WRITABLE != 0;
    var tr: [2]Translation = .{ .lf, .lf };
    var bin: [2]bool = .{ false, false };
    for (w[0..n], 0..) |x, i| {
        if (std.mem.eql(u8, x, "binary")) {
            bin[i] = true;
        } else tr[i] = parseTr(x) orelse return badValue(ip, "bad value for -translation: must be one of auto, binary, cr, lf, crlf, or platform");
    }
    const out_i: usize = if (n == 1 or !rw) 0 else 1;
    st.in_tr = tr[0];
    st.saw_cr = false;
    st.out_tr = if (tr[out_i] == .auto) .lf else tr[out_i];
    if (bin[0] or bin[out_i]) {
        st.enc = .binary;
        st.eof_in = 0;
        st.eof_out = 0;
    }
    return OK;
}

fn setEofchar(ip: ?*Interp, st: *State, v: [*:0]const u8) c_int {
    var w: [2][]const u8 = undefined;
    const n = twoWords(v, &w) orelse return badValue(ip, "bad value for -eofchar: should be a list of zero, one, or two elements");
    defer for (w[0..n]) |x| gpa.free(x);
    var ch: [2]u8 = .{ 0, 0 };
    for (w[0..n], 0..) |x, i| {
        if (x.len > 1 or (x.len == 1 and x[0] >= 0x80)) return badValue(ip, "bad value for -eofchar: must be non-NUL ASCII character");
        ch[i] = if (x.len == 1) x[0] else 0;
    }
    const rw = st.mask & TCL_READABLE != 0 and st.mask & TCL_WRITABLE != 0;
    st.eof_in = ch[0];
    st.eof_out = if (n == 2 and rw) ch[1] else ch[0];
    return OK;
}

pub fn Tcl_SetChannelOption(ip: ?*Interp, c: *Channel, name: [*:0]const u8, v: [*:0]const u8) callconv(.c) c_int {
    const st = c.state;
    const n = std.mem.span(name);
    if (direct(st)) |l| {
        if (run(l.handle, &.{ "fconfigure", l.name, n, std.mem.span(v) }) != OK) {
            if (ip) |i| host.takeReply(i);
            return ERROR;
        }
        return OK;
    }
    const vs = std.mem.span(v);
    if (std.mem.eql(u8, n, "-blocking")) {
        var b: c_int = 0;
        if (obj.Tcl_GetBoolean(ip, v, &b) != OK) return ERROR;
        const t = st.top.type;
        const f: ?BlockModeFn = if (version(t) == 1) @ptrCast(@alignCast(t.version)) else t.block_mode;
        if (f) |bm| {
            const e = bm(st.top.data, if (b != 0) TCL_MODE_BLOCKING else TCL_MODE_NONBLOCKING);
            if (e != 0) {
                setErrno(e);
                return ERROR;
            }
        }
        st.blocking = b != 0;
        return OK;
    }
    if (std.mem.eql(u8, n, "-buffering")) {
        st.buffering = std.meta.stringToEnum(Buffering, vs) orelse return badValue(ip, "bad value for -buffering: must be one of full, line, or none");
        return OK;
    }
    if (std.mem.eql(u8, n, "-buffersize")) {
        var k: c_int = 0;
        if (obj.Tcl_GetInt(ip, v, &k) != OK) return ERROR;
        Tcl_SetChannelBufferSize(c, k);
        return OK;
    }
    if (std.mem.eql(u8, n, "-encoding")) {
        st.enc = if (vs.len == 0 or std.mem.eql(u8, vs, "binary"))
            .binary
        else if (std.mem.eql(u8, vs, "utf-8") or std.mem.eql(u8, vs, "identity"))
            .utf8
        else if (std.mem.eql(u8, vs, "iso8859-1"))
            .latin1
        else {
            if (ip) |i| {
                var b: [300]u8 = undefined;
                obj.setResultText(i, std.fmt.bufPrint(&b, "unknown encoding \"{s}\"", .{vs[0..@min(vs.len, 200)]}) catch "unknown encoding");
            }
            setErrno(EINVAL);
            return ERROR;
        };
        return OK;
    }
    if (std.mem.eql(u8, n, "-eofchar")) return setEofchar(ip, st, v);
    if (std.mem.eql(u8, n, "-translation")) return setTranslation(ip, st, v);
    const f = st.top.type.set_option orelse return Tcl_BadChannelOption(ip, name, null);
    return f(st.top.data, ip, name, v);
}

// ---- Stacks ----

pub fn Tcl_StackChannel(ip: ?*Interp, t: *const ChannelType, data: ?*anyopaque, mask: c_int, prev: *Channel) callconv(.c) ?*Channel {
    const st = prev.state;
    const below = st.top;
    if (mask & ~below.mask != 0) {
        if (ip) |i| obj.setResultText(i, "reading and writing both disallowed for channel");
        return null;
    }
    if (direct(st)) |l| {
        // The bytes of the channel of ztcl reach the transform raw.
        if (hooks) |h| if (ip) |i| if (h.stack(i.handle, st.name, st)) |hidden| {
            gpa.free(l.name);
            l.name = gpa.dupeSentinel(u8, hidden, 0) catch oom();
            st.in_ztcl = true;
        };
        _ = run(l.handle, &.{ "fconfigure", l.name, "-translation", "binary", "-blocking", "1" });
    } else if (flushOut(st) != OK) return null;
    const c = gpa.create(Channel) catch oom();
    c.* = .{ .type = t, .data = data, .mask = mask, .state = st, .down = below };
    below.up = c;
    st.top = c;
    st.mask = mask;
    return c;
}

pub fn Tcl_UnstackChannel(ip: ?*Interp, c: *Channel) callconv(.c) c_int {
    const st = c.state;
    const below = c.down orelse return Tcl_Close(ip, c);
    var rc = flushOut(st);
    st.rbuf.items.len = 0;
    st.rpos = 0;
    st.eof = false;
    st.hit_eof = false;
    st.top = below;
    below.up = null;
    st.mask = below.mask;
    const r = closeOne(ip, c);
    if (rc == OK) rc = r;
    if (linkOf(below)) |l| if (hooks) |h| if (st.in_ztcl) {
        h.unstack(l.handle, st.name, l.name);
        st.in_ztcl = false;
        gpa.free(l.name);
        l.name = gpa.dupeSentinel(u8, st.name, 0) catch oom();
    };
    return rc;
}

// ---- Handlers ----

fn updateInterest(st: *State) void {
    var mask: c_int = 0;
    for (st.handlers.items) |h| mask |= h.mask;
    if (st.top.type.watch) |w| w(st.top.data, mask);
}

pub fn Tcl_CreateChannelHandler(c: *Channel, mask: c_int, proc: HandlerProc, cd: ?*anyopaque) callconv(.c) void {
    const st = c.state;
    for (st.handlers.items) |*h| if (h.proc == proc and h.cd == cd) {
        h.mask = mask;
        updateInterest(st);
        return;
    };
    st.handlers.insert(gpa, 0, .{ .mask = mask, .proc = proc, .cd = cd }) catch oom();
    updateInterest(st);
}

pub fn Tcl_DeleteChannelHandler(c: *Channel, proc: HandlerProc, cd: ?*anyopaque) callconv(.c) void {
    const st = c.state;
    for (st.handlers.items, 0..) |h, i| if (h.proc == proc and h.cd == cd) {
        _ = st.handlers.orderedRemove(i);
        updateInterest(st);
        return;
    };
}

pub fn Tcl_ClearChannelHandlers(c: *Channel) callconv(.c) void {
    c.state.handlers.clearRetainingCapacity();
}

fn hasHandler(st: *State, h: Handler) bool {
    for (st.handlers.items) |x| if (x.proc == h.proc and x.cd == h.cd) return true;
    return false;
}

/// Runs the handlers of `c` whose mask has a bit of `mask`.
pub fn Tcl_NotifyChannel(c: *Channel, mask: c_int) callconv(.c) void {
    const st = c.state;
    const list = gpa.dupe(Handler, st.handlers.items) catch oom();
    defer gpa.free(list);
    // A handler can delete a later one.
    for (list) |h| if (h.mask & mask != 0 and hasHandler(st, h)) h.proc(h.cd, h.mask & mask);
}

pub fn Tcl_CreateCloseHandler(c: *Channel, proc: CloseProc, cd: ?*anyopaque) callconv(.c) void {
    c.state.close_handlers.append(gpa, .{ .proc = proc, .cd = cd }) catch oom();
}

pub fn Tcl_DeleteCloseHandler(c: *Channel, proc: CloseProc, cd: ?*anyopaque) callconv(.c) void {
    const st = c.state;
    for (st.close_handlers.items, 0..) |h, i| if (h.proc == proc and h.cd == cd) {
        _ = st.close_handlers.orderedRemove(i);
        return;
    };
}

// ---- Errors ----

fn swapErr(slot: *?*Obj, o: ?*Obj) void {
    if (o) |x| obj.incr(x);
    if (slot.*) |old| obj.decr(old);
    slot.* = o;
}

/// Gives the error of the channel to the caller with its reference.
pub fn Tcl_SetChannelError(c: *Channel, o: ?*Obj) callconv(.c) void {
    swapErr(&c.state.err, o);
}

pub fn Tcl_GetChannelError(c: *Channel, out: *?*Obj) callconv(.c) void {
    out.* = c.state.err;
    c.state.err = null;
}

pub fn Tcl_SetChannelErrorInterp(ip: *Interp, o: ?*Obj) callconv(.c) void {
    swapErr(&perInterp(ip).err, o);
}

pub fn Tcl_GetChannelErrorInterp(ip: *Interp, out: *?*Obj) callconv(.c) void {
    const p = perInterp(ip);
    out.* = p.err;
    p.err = null;
}

pub fn Tcl_GetErrno() callconv(.c) c_int {
    return getErrno();
}

pub fn Tcl_SetErrno(e: c_int) callconv(.c) void {
    setErrno(e);
}

threadlocal var errno_text: [128]u8 = undefined;

extern "c" fn strerror(c_int) [*:0]const u8;

pub fn Tcl_ErrnoMsg(e: c_int) callconv(.c) [*:0]const u8 {
    if (comptime !builtin.link_libc) return "unknown error";
    const m = std.mem.span(strerror(e));
    const n = @min(m.len, errno_text.len - 1);
    @memcpy(errno_text[0..n], m[0..n]);
    errno_text[n] = 0;
    // Tcl gives the text of an error number in lower case.
    if (n > 1 and std.ascii.isUpper(errno_text[0]) and std.ascii.isLower(errno_text[1])) errno_text[0] = std.ascii.toLower(errno_text[0]);
    return errno_text[0..n :0];
}

// ---- Names ----

/// The channel `name` of the package in `ip`, or null.
fn find(ip: *Interp, name: []const u8) ?*Channel {
    for (perInterp(ip).chans.items) |st| if (std.mem.eql(u8, st.name, name)) return st.top;
    return null;
}

const std_names = [_][:0]const u8{ "stdin", "stdout", "stderr" };

fn stdChannel(i: usize) ?*Channel {
    if (std_isset[i]) return std_set[i];
    const ip = last orelse return null;
    return ztclChannel(ip.handle, std_names[i], if (i == 0) TCL_READABLE else TCL_WRITABLE);
}

pub fn Tcl_GetStdChannel(kind: c_int) callconv(.c) ?*Channel {
    return switch (kind) {
        TCL_STDIN => stdChannel(0),
        TCL_STDOUT => stdChannel(1),
        TCL_STDERR => stdChannel(2),
        else => null,
    };
}

pub fn Tcl_SetStdChannel(c: ?*Channel, kind: c_int) callconv(.c) void {
    const i: usize = switch (kind) {
        TCL_STDIN => 0,
        TCL_STDOUT => 1,
        TCL_STDERR => 2,
        else => return,
    };
    std_set[i] = c;
    std_isset[i] = true;
}

/// The mode of channel `name` of ztcl, or null when ztcl has no channel
/// of that name.
fn ztclMode(handle: u32, name: []const u8) ?c_int {
    for (std_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return if (i == 0) TCL_READABLE else TCL_WRITABLE;
    if (run(handle, &.{ "::apply", "c {list [catch {fconfigure $c -blocking}] [chan pending input $c] [chan pending output $c]}", name }) != OK) return null;
    const t = replyText();
    defer gpa.free(t);
    if (t.len == 0 or t[0] != '0') return null;
    // `chan pending` gives -1 for a direction the channel does not have.
    var mask: c_int = 0;
    var words = std.mem.tokenizeScalar(u8, t, ' ');
    _ = words.next();
    if (!std.mem.eql(u8, words.next() orelse "-1", "-1")) mask |= TCL_READABLE;
    if (!std.mem.eql(u8, words.next() orelse "-1", "-1")) mask |= TCL_WRITABLE;
    return if (mask == 0) TCL_READABLE | TCL_WRITABLE else mask;
}

pub fn Tcl_GetChannel(ip: *Interp, name: [*:0]const u8, mode: ?*c_int) callconv(.c) ?*Channel {
    const n = std.mem.span(name);
    const c = find(ip, n) orelse blk: {
        for (std_names, 0..) |s, i| if (std.mem.eql(u8, s, n)) if (stdChannel(i)) |x| break :blk x;
        const m = ztclMode(ip.handle, n) orelse {
            var b: [300]u8 = undefined;
            obj.setResultText(ip, std.fmt.bufPrint(&b, "can not find channel named \"{s}\"", .{n[0..@min(n.len, 200)]}) catch "can not find channel");
            return null;
        };
        break :blk ztclChannel(ip.handle, n, m);
    };
    if (mode) |p| p.* = c.state.mask;
    return c;
}

/// True when `s` matches the glob pattern `p` of `string match`.
fn glob(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;
    switch (p[0]) {
        '*' => {
            var i: usize = 0;
            while (i <= s.len) : (i += 1) if (glob(p[1..], s[i..])) return true;
            return false;
        },
        '?' => return s.len > 0 and glob(p[1..], s[1..]),
        '\\' => return p.len > 1 and s.len > 0 and s[0] == p[1] and glob(p[2..], s[1..]),
        else => return s.len > 0 and s[0] == p[0] and glob(p[1..], s[1..]),
    }
}

pub fn Tcl_GetChannelNamesEx(ip: *Interp, pattern: ?[*:0]const u8) callconv(.c) c_int {
    const l = obj.Tcl_NewListObj(0, null);
    const pat = if (pattern) |p| std.mem.span(p) else "*";
    // The channels of ztcl first, then the others of the package.
    if (run(ip.handle, &.{ "chan", "names", pat }) == OK) {
        const r = host.objOf(host.reply);
        obj.incr(r);
        defer obj.decr(r);
        _ = obj.Tcl_ListObjAppendList(null, l, r);
    }
    for (perInterp(ip).chans.items) |st| {
        if (!glob(pat, st.name) or st.in_ztcl) continue;
        _ = obj.Tcl_ListObjAppendElement(null, l, obj.Tcl_NewStringObj(st.name.ptr, @intCast(st.name.len)));
    }
    obj.Tcl_SetObjResult(ip, l);
    return OK;
}

pub fn Tcl_GetChannelNames(ip: *Interp) callconv(.c) c_int {
    return Tcl_GetChannelNamesEx(ip, null);
}

pub fn Tcl_CutChannel(c: *Channel) callconv(.c) void {
    if (std.mem.indexOfScalar(*State, all.items, c.state)) |i| _ = all.swapRemove(i);
}

pub fn Tcl_SpliceChannel(c: *Channel) callconv(.c) void {
    if (std.mem.indexOfScalar(*State, all.items, c.state) == null) all.append(gpa, c.state) catch oom();
}

// ---- Channels of ztcl from C ----

/// The channel of ztcl that the script `words` gives the name of.
fn opened(ip: *Interp, words: []const []const u8) ?*Channel {
    if (run(ip.handle, words) != OK) {
        host.takeReply(ip);
        return null;
    }
    const name = replyText();
    defer gpa.free(name);
    const mode = ztclMode(ip.handle, name) orelse TCL_READABLE | TCL_WRITABLE;
    return ztclChannel(ip.handle, name, mode);
}

pub fn Tcl_OpenFileChannel(ip: ?*Interp, path: [*:0]const u8, mode: [*:0]const u8, perms: c_int) callconv(.c) ?*Channel {
    const i = ip orelse last orelse return null;
    var pb: [24]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "0{o}", .{perms}) catch unreachable;
    return opened(i, &.{ "open", std.mem.span(path), std.mem.span(mode), p });
}

pub fn Tcl_FSOpenFileChannel(ip: ?*Interp, path: *Obj, mode: [*:0]const u8, perms: c_int) callconv(.c) ?*Channel {
    return Tcl_OpenFileChannel(ip, obj.Tcl_GetString(path), mode, perms);
}

pub fn Tcl_OpenTcpClient(ip: *Interp, port: c_int, h: [*:0]const u8, my_addr: ?[*:0]const u8, my_port: c_int, async_: c_int) callconv(.c) ?*Channel {
    var pb: [16]u8 = undefined;
    var mb: [16]u8 = undefined;
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(gpa);
    words.append(gpa, "socket") catch oom();
    if (my_addr) |a| words.appendSlice(gpa, &.{ "-myaddr", std.mem.span(a) }) catch oom();
    if (my_port != 0) words.appendSlice(gpa, &.{ "-myport", std.fmt.bufPrint(&mb, "{d}", .{my_port}) catch unreachable }) catch oom();
    if (async_ != 0) words.append(gpa, "-async") catch oom();
    words.appendSlice(gpa, &.{ std.mem.span(h), std.fmt.bufPrint(&pb, "{d}", .{port}) catch unreachable }) catch oom();
    return opened(ip, words.items);
}

pub fn Tcl_OpenCommandChannel(ip: *Interp, argc: c_int, argv: [*]const [*:0]const u8, flags: c_int) callconv(.c) ?*Channel {
    var cmd: DString = undefined;
    obj.Tcl_DStringInit(&cmd);
    defer obj.Tcl_DStringFree(&cmd);
    for (argv[0..@intCast(argc)]) |a| _ = obj.Tcl_DStringAppendElement(&cmd, a);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    line.print(gpa, "|{s}", .{cmd.string[0..@intCast(cmd.length)]}) catch oom();
    const mode: []const u8 = if (flags & TCL_READABLE != 0 and flags & TCL_WRITABLE != 0) "r+" else if (flags & TCL_WRITABLE != 0) "w" else "r";
    return opened(ip, &.{ "open", line.items, mode });
}

pub fn Tcl_CreatePipe(ip: *Interp, rd: *?*Channel, wr: *?*Channel, _: c_int) callconv(.c) c_int {
    if (run(ip.handle, &.{ "chan", "pipe" }) != OK) {
        host.takeReply(ip);
        return ERROR;
    }
    const t = replyText();
    defer gpa.free(t);
    var words = std.mem.tokenizeScalar(u8, t, ' ');
    rd.* = ztclChannel(ip.handle, words.next() orelse return ERROR, TCL_READABLE);
    wr.* = ztclChannel(ip.handle, words.next() orelse return ERROR, TCL_WRITABLE);
    return OK;
}

fn adopt(fd: ?*anyopaque, mask: c_int, sock: bool) ?*Channel {
    const h = hooks orelse return null;
    const ip = last orelse return null;
    const name = h.adopt(ip.handle, @intCast(@intFromPtr(fd)), mask, sock) orelse return null;
    return ztclChannel(ip.handle, name, mask);
}

pub fn Tcl_MakeFileChannel(fd: ?*anyopaque, mask: c_int) callconv(.c) ?*Channel {
    return adopt(fd, mask, false);
}

pub fn Tcl_MakeTcpClientChannel(fd: ?*anyopaque) callconv(.c) ?*Channel {
    return adopt(fd, TCL_READABLE | TCL_WRITABLE, true);
}

const AcceptProc = *const fn (?*anyopaque, *Channel, [*:0]const u8, c_int) callconv(.c) void;
const Server = struct { proc: AcceptProc, cd: ?*anyopaque };
threadlocal var servers: u32 = 0;

/// The command of a server socket of `Tcl_OpenTcpServer`: ztcl runs it
/// with the channel, the address, and the port of each connection.
fn acceptCmd(cd: ?*anyopaque, ip: *Interp, objc: c_int, objv: [*]const *Obj) callconv(.c) c_int {
    const sv: *Server = @ptrCast(@alignCast(cd));
    if (objc != 4) return ERROR;
    var port: c_long = 0;
    if (obj.Tcl_GetLongFromObj(ip, objv[3], &port) != OK) return ERROR;
    const name = obj.text(objv[1]);
    const c = ztclChannel(ip.handle, name, TCL_READABLE | TCL_WRITABLE);
    sv.proc(sv.cd, c, obj.Tcl_GetString(objv[2]), @intCast(port));
    return OK;
}

pub fn Tcl_OpenTcpServer(ip: *Interp, port: c_int, h: ?[*:0]const u8, proc: AcceptProc, cd: ?*anyopaque) callconv(.c) ?*Channel {
    const sv = gpa.create(Server) catch oom();
    sv.* = .{ .proc = proc, .cd = cd };
    var nb: [48]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&nb, "::tcl::cext::accept{d}", .{servers}, 0) catch unreachable;
    servers += 1;
    _ = host.createCommand(ip, cmd.ptr, &acceptCmd, null, sv, null);
    var pb: [16]u8 = undefined;
    const ps = std.fmt.bufPrint(&pb, "{d}", .{port}) catch unreachable;
    if (h) |a| return opened(ip, &.{ "socket", "-server", cmd, "-myaddr", std.mem.span(a), ps });
    return opened(ip, &.{ "socket", "-server", cmd, ps });
}

/// The file of `chan` for C stdio. A channel of ztcl has no `FILE`, so
/// the call gives an error.
pub fn Tcl_GetOpenFile(ip: *Interp, name: [*:0]const u8, _: c_int, _: c_int, out: *?*anyopaque) callconv(.c) c_int {
    out.* = null;
    var b: [300]u8 = undefined;
    const n = std.mem.span(name);
    obj.setResultText(ip, std.fmt.bufPrint(&b, "\"{s}\" cannot be used to get a FILE *", .{n[0..@min(n.len, 200)]}) catch "no FILE");
    return ERROR;
}

// ---- Processes ----

const can_wait = builtin.os.tag == .linux or builtin.os.tag == .macos;

/// The processes of `Tcl_DetachPids` that no call has reaped yet.
threadlocal var detached: std.ArrayList(c_int) = .empty;

pub fn Tcl_DetachPids(n: c_int, pids: [*]const c_int) callconv(.c) void {
    detached.appendSlice(gpa, pids[0..@intCast(n)]) catch oom();
}

pub fn Tcl_ReapDetachedProcs() callconv(.c) void {
    if (comptime !can_wait) return;
    var i: usize = 0;
    while (i < detached.items.len) {
        var status: c_int = 0;
        if (std.c.waitpid(detached.items[i], &status, std.c.W.NOHANG) == 0) {
            i += 1;
            continue;
        }
        _ = detached.swapRemove(i);
    }
}

pub fn Tcl_WaitPid(pid: c_int, status: *c_int, options: c_int) callconv(.c) c_int {
    if (comptime !can_wait) {
        setErrno(EINVAL);
        return -1;
    }
    while (true) {
        const r = std.c.waitpid(pid, status, options);
        if (r >= 0 or getErrno() != @backingInt(std.c.E.INTR)) return r;
    }
}

// ---- The accessors of a channel type ----

pub fn Tcl_ChannelName(t: *const ChannelType) callconv(.c) ?[*:0]const u8 {
    return t.name;
}

pub fn Tcl_ChannelVersion(t: *const ChannelType) callconv(.c) ?*const anyopaque {
    return @ptrFromInt(version(t));
}

pub fn Tcl_ChannelBlockModeProc(t: *const ChannelType) callconv(.c) ?*const anyopaque {
    return if (version(t) == 1) t.version else @ptrCast(t.block_mode);
}

pub fn Tcl_ChannelCloseProc(t: *const ChannelType) callconv(.c) ?CloseFn {
    return t.close;
}

pub fn Tcl_ChannelClose2Proc(t: *const ChannelType) callconv(.c) ?Close2Fn {
    return t.close2;
}

pub fn Tcl_ChannelInputProc(t: *const ChannelType) callconv(.c) ?InputFn {
    return t.input;
}

pub fn Tcl_ChannelOutputProc(t: *const ChannelType) callconv(.c) ?OutputFn {
    return t.output;
}

pub fn Tcl_ChannelSeekProc(t: *const ChannelType) callconv(.c) ?SeekFn {
    return t.seek;
}

pub fn Tcl_ChannelSetOptionProc(t: *const ChannelType) callconv(.c) ?SetOptionFn {
    return t.set_option;
}

pub fn Tcl_ChannelGetOptionProc(t: *const ChannelType) callconv(.c) ?GetOptionFn {
    return t.get_option;
}

pub fn Tcl_ChannelWatchProc(t: *const ChannelType) callconv(.c) ?WatchFn {
    return t.watch;
}

pub fn Tcl_ChannelGetHandleProc(t: *const ChannelType) callconv(.c) ?GetHandleFn {
    return t.get_handle;
}

pub fn Tcl_ChannelFlushProc(t: *const ChannelType) callconv(.c) ?FlushFn {
    return if (version(t) >= 2) t.flush else null;
}

pub fn Tcl_ChannelHandlerProc(t: *const ChannelType) callconv(.c) ?HandlerFn {
    return if (version(t) >= 2) t.handler else null;
}

pub fn Tcl_ChannelWideSeekProc(t: *const ChannelType) callconv(.c) ?WideSeekFn {
    return if (version(t) >= 3) t.wide_seek else null;
}

pub fn Tcl_ChannelThreadActionProc(t: *const ChannelType) callconv(.c) ?ThreadActionFn {
    return if (version(t) >= 4) t.thread_action else null;
}

pub fn Tcl_ChannelTruncateProc(t: *const ChannelType) callconv(.c) ?TruncateFn {
    return if (version(t) >= 5) t.truncate else null;
}

/// Closes the channels that `ip` registered. The interp of the package
/// goes after this call.
pub fn dropInterp(ip: *Interp) void {
    const p: *PerInterp = @ptrCast(@alignCast(ip.chans orelse return));
    while (p.chans.items.len > 0) _ = Tcl_UnregisterChannel(ip, p.chans.items[p.chans.items.len - 1].top);
    p.chans.deinit(gpa);
    if (p.err) |e| obj.decr(e);
    gpa.destroy(p);
    ip.chans = null;
    if (last == ip) last = null;
}

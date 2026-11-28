//! The optional channel commands (capability `channels`).
//!
//! A channel is a file below the root of `fsroot.zig`. Each channel has
//! a read buffer and a write buffer. The translation of line ends and
//! the encoding apply at these buffers. `utf-8` and `binary` need no
//! table; the other encodings are the tables of `enc.zig`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const enc = @import("enc.zig");
/// The process code of the target: `proc_windows.zig` on Windows.
const proc_mod = if (@import("builtin").os.tag == .windows) @import("proc_windows.zig") else @import("proc.zig");
const pty_mod = if (@import("builtin").os.tag == .windows) @import("pty_windows.zig") else @import("pty.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");
const fsroot = @import("fsroot.zig");
const vfs = @import("vfs.zig");
const cmds = @import("cmds.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;
const sys = @import("sys.zig");
const serial = @import("serial.zig");
const builtin = @import("builtin");
const proc_ok = proc_mod.supported;
const ProcTree = if (proc_ok) proc_mod.Tree else struct {};
const ProcJob = if (proc_ok and @hasDecl(proc_mod, "Job")) proc_mod.Job else void;
const event = @import("event.zig");
const refl_mod = @import("chanrefl.zig");
const xform_mod = @import("chanxform.zig");

pub const Translation = enum { auto, lf, cr, crlf, binary };
/// The line end of the output of a file of the platform, as in Tcl:
/// crlf on Windows, lf elsewhere. `-translation auto` and `platform`
/// give it for the output side.
pub const platform_eol: Translation = if (builtin.os.tag == .windows) .crlf else .lf;

/// A layer between the buffers of a channel and its descriptor, such as
/// TLS (`src/tls/cmd.zig`). A channel with a filter blocks. `read` fills
/// `buf` with data for the channel and gives 0 at the end. `write`
/// gives all of `data` to the layer. `closeWrite` ends the output of
/// the layer, and `deinit` frees the layer before the descriptor
/// closes.
pub const Filter = struct {
    read: *const fn (f: *Filter, it: *Interp, fd: i32, buf: []u8) Error!usize,
    write: *const fn (f: *Filter, it: *Interp, fd: i32, data: []const u8) Error!void,
    closeWrite: *const fn (f: *Filter, it: *Interp, fd: i32) void,
    deinit: *const fn (f: *Filter, it: *Interp) void,
};

pub const Channel = struct {
    name: []const u8,
    fd: i32,
    readable: bool,
    writable: bool,
    append: bool = false,
    rbuf: std.ArrayList(u8) = .empty,
    rpos: usize = 0,
    wbuf: std.ArrayList(u8) = .empty,
    at_eof: bool = false,
    hit_eof: bool = false,
    input: Translation = .auto,
    output: Translation = .lf,
    binary: bool = false,
    /// The `-profile` of the channel. Null is the default of the
    /// release: `strict` in Tcl 9.1, `tcl8` in Tcl 8.6.
    profile: ?enc.Profile = null,
    /// The table encoding, or null for `utf-8` and `binary`.
    enc: ?enc.Encoding = null,
    /// The name of `-encoding`, or "" for `utf-8` or `binary`.
    enc_name: []const u8 = "",
    /// True for stdout and stderr until a write or `-encoding`: the
    /// first write takes the encoding of `encoding system`.
    lazy_enc: bool = false,
    /// The state of the escape-driven encodings, for input and output.
    in_state: enc.State = .{},
    out_state: enc.State = .{},
    buffering: []const u8 = "full",
    buffersize: i64 = 4096,
    blocking: bool = true,
    /// True after a read that found no whole line or no data on a
    /// channel that does not block.
    blocked: bool = false,
    /// The scripts of `fileevent`.
    on_read: ?[]const u8 = null,
    on_write: ?[]const u8 = null,
    kind: enum { file, socket, server, pipe } = .file,
    /// A file of `vfs.zig`: the read buffer has all of the data, and
    /// `fd` is -1.
    mem: bool = false,
    /// The command of a server socket. It gets each new connection.
    accept: []const u8 = "",
    /// A connect that continues in the background.
    connecting: bool = false,
    /// The error of a background connect, for `fconfigure -error`.
    fail: ?sys.Fail = null,
    /// The descriptor of the write side, when it differs from `fd`.
    wfd: i32 = -1,
    /// The processes of a command pipeline.
    pids: []const i32 = &.{},
    /// The memory file of the error output of the pipeline, or -1.
    err_fd: i32 = -1,
    /// The start time of the pipeline, for the time limit.
    started: i64 = 0,
    /// The process tree of the pipeline.
    tree: ProcTree = .{},
    /// The job of a pipeline outside the host (`open "|-vm ..."`).
    job: ?ProcJob = null,
    /// True for the master side of a PTY of `ztcl::pty`.
    pty: bool = false,
    /// The end-of-file characters of `-eofchar`, or 0 for none. Input
    /// stops at `eof_in`, and `close` writes `eof_out`.
    eof_in: u8 = 0,
    eof_out: u8 = 0,
    /// The count of read bytes after `eof_in` that the read buffer
    /// dropped, for `tell` and `seek`.
    eof_drop: usize = 0,
    /// The wait status of the program of a PTY after it ended.
    pty_status: ?u32 = null,
    /// True for a closed channel that still has output to write. The
    /// event loop writes the rest and then closes the descriptor.
    draining: bool = false,
    /// The second listening channel of a server on both loopback
    /// addresses. It has a name that no script can give.
    sibling: ?*Channel = null,
    /// The host word of a client socket, for the network policy.
    peer_host: []const u8 = "",
    read_closed: bool = false,
    write_closed: bool = false,
    /// The channel of a C package (`cext/chan.zig`), or null. The
    /// commands of a script on it go to `ext_op`.
    ext: ?*anyopaque = null,
    filter: ?*Filter = null,
    /// The handler of a reflected channel of `chan create`
    /// (`chanrefl.zig`), or null.
    refl: ?*refl_mod.Refl = null,
    /// The top transform of `chan push` (`chanxform.zig`), or null.
    /// The top transform is also `filter`.
    xform: ?*xform_mod.Xform = null,
};

/// Runs the command `op` of a script on a channel of a C package, with
/// the words after the channel name. `cext/native.zig` sets it.
pub var ext_op: ?*const fn (it: *Interp, c: *Channel, op: []const u8, args: []const Value) Error!Value = null;

/// The events of a channel of a C package. `ready` is true when the
/// loop must call `serve` at once. `cext/native.zig` sets them.
pub const ExtEvents = struct {
    ready: *const fn (it: *Interp, c: *Channel) bool,
    serve: *const fn (cur: *Interp, it: *Interp, c: *Channel) Error!bool,
};
pub var ext_events: ?ExtEvents = null;

/// True when the channel `name` of a C package has an event to serve.
pub fn extReady(it: *Interp, name: []const u8) bool {
    const c = it.chans.table.get(name) orelse return false;
    if (c.refl) |r| return refl_mod.ready(r);
    if (c.ext == null) return false;
    const e = ext_events orelse return false;
    return e.ready(it, c);
}

/// Serves the events of the channel `name` of a C package.
pub fn extServe(cur: *Interp, it: *Interp, name: []const u8) Error!bool {
    const c = it.chans.table.get(name) orelse return false;
    if (c.refl) |r| return refl_mod.serve(cur, it, r);
    if (c.ext == null) return false;
    const e = ext_events orelse return false;
    return e.serve(cur, it, c);
}

fn extCall(it: *Interp, c: *Channel, op: []const u8, args: []const Value) Error!Value {
    const f = ext_op orelse return it.fail("channel \"{s}\" belongs to a C package", .{c.name});
    return f(it, c, op, args);
}

pub const State = struct {
    table: std.StringArrayHashMapUnmanaged(*Channel) = .empty,
    next: u32 = 3,
    next_sock: u32 = 0,
    /// The number of the next name `rcN` of `chan create`.
    next_rc: u32 = 0,
    /// The number of the next handle `rtN` of `chan push`.
    next_rt: u32 = 0,
    /// The counters of the names of a thread group. With them, each
    /// channel of the group has its own name, so a channel can move to
    /// another thread (`tchan.zig`).
    shared: ?*Counters = null,

    /// The number of the next name with `prefix`.
    fn number(s: *State, sock: bool) u32 {
        if (s.shared) |c| return (if (sock) &c.next_sock else &c.next).fetchAdd(1, .monotonic);
        const n = if (sock) &s.next_sock else &s.next;
        defer n.* += 1;
        return n.*;
    }
};

/// The name counters of a thread group.
pub const Counters = struct {
    next: std.atomic.Value(u32) = .init(3),
    next_sock: std.atomic.Value(u32) = .init(0),
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn findChannel(it: *Interp, v: Value) Error!*Channel {
    return find(it, v);
}

/// The descriptor of the output of `c`, for the filters.
pub fn writeFd(c: *const Channel) i32 {
    return outFd(c);
}

/// Reads the descriptor of `c` with no filter, for a transform. A
/// channel that does not block waits here for data.
pub fn rawRead(it: *Interp, c: *Channel, buf: []u8) Error!usize {
    while (true) {
        switch (try @import("tape.zig").read(it, c.fd, buf)) {
            .n => |n| {
                meterIo(it, c, true, n);
                return n;
            },
            .again => {
                var w = [_]sys.Want{.{ .fd = c.fd, .read = true }};
                sys.poll(it.alloc(), &w, -1);
            },
            .err => |f| {
                if ((c.kind != .file and eql(f.name, "ECONNRESET")) or (c.pty and eql(f.name, "EIO"))) return 0;
                return sysError(it, f, try std.fmt.allocPrint(it.alloc(), "error reading \"{s}\": ", .{c.name}));
            },
        }
    }
}

/// Writes all of `data` to the descriptor of `c` with no filter, for
/// a transform.
pub fn rawWrite(it: *Interp, c: *Channel, data: []const u8) Error!void {
    var at: usize = 0;
    while (at < data.len) {
        switch (sys.write(outFd(c), data[at..])) {
            .n => |n| {
                at += n;
                meterIo(it, c, false, n);
            },
            .again => {
                var w = [_]sys.Want{.{ .fd = outFd(c), .write = true }};
                sys.poll(it.alloc(), &w, -1);
            },
            .err => |f| return sysError(it, f, try std.fmt.allocPrint(it.alloc(), "error writing \"{s}\": ", .{c.name})),
        }
    }
}

/// True for a TLS channel: a filter under the transforms that is not
/// a reflected channel.
fn isTls(c: *const Channel) bool {
    if (c.refl != null) return false;
    var f = c.filter;
    var x = c.xform;
    while (x) |t| : (x = t.under) f = t.below;
    return f != null;
}

fn find(it: *Interp, v: Value) Error!*Channel {
    const name = try it.str(v);
    return it.chans.table.get(name) orelse it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP CHANNEL {s}", .{name}), "can not find channel named \"{s}\"", .{name});
}

fn sysError(it: *Interp, f: sys.Fail, what: []const u8) Error {
    const code = try std.fmt.allocPrint(it.alloc(), "POSIX {s} {{{s}}}", .{ f.name, f.text });
    return it.failCode(code, "{s}{s}", .{ what, f.text });
}

fn outFd(c: *const Channel) i32 {
    return if (c.wfd >= 0) c.wfd else c.fd;
}

/// Waits for the end of a background connect.
fn settle(it: *Interp, c: *Channel) void {
    if (!c.connecting or !c.blocking) return;
    var w = [_]sys.Want{.{ .fd = c.fd, .write = true }};
    sys.poll(it.alloc(), &w, -1);
    connected(c);
}

fn connected(c: *Channel) void {
    c.connecting = false;
    c.fail = sys.connectError(c.fd);
    if (c.blocking) sys.setBlocking(c.fd, true);
}

/// Counts the bytes of a system read or write in the meter of `it`.
fn meterIo(it: *Interp, c: *Channel, read: bool, n: usize) void {
    if (n == 0) return;
    const m = @import("meter.zig");
    const kind: m.IoKind = switch (c.kind) {
        .socket, .server => .socket,
        .pipe => .pipe,
        .file => .file,
    };
    m.countIo(it, kind, read, n, c.peer_host);
}

fn flushOut(it: *Interp, c: *Channel) Error!void {
    if (c.wbuf.items.len == 0) return;
    settle(it, c);
    if (c.connecting) {
        // The data waits for the end of the connect.
        try event.watch(it, c.name);
        return;
    }
    if (c.fail != null) {
        c.wbuf.clearRetainingCapacity();
        return sysError(it, .{ .name = "ENOTCONN", .text = "socket is not connected" }, try std.fmt.allocPrint(it.alloc(), "error writing \"{s}\": ", .{c.name}));
    }
    if (c.filter) |f| {
        defer c.wbuf.clearRetainingCapacity();
        return f.write(f, it, outFd(c), c.wbuf.items);
    }
    var at: usize = 0;
    while (at < c.wbuf.items.len) {
        switch (sys.write(outFd(c), c.wbuf.items[at..])) {
            .n => |n| {
                at += n;
                meterIo(it, c, false, n);
            },
            .again => {
                if (!c.blocking) {
                    // The rest stays in the buffer. The event loop
                    // writes it when the peer has room.
                    std.mem.copyForwards(u8, c.wbuf.items[0 .. c.wbuf.items.len - at], c.wbuf.items[at..]);
                    c.wbuf.items.len -= at;
                    try event.watch(it, c.name);
                    return;
                }
                var w = [_]sys.Want{.{ .fd = outFd(c), .write = true }};
                sys.poll(it.alloc(), &w, -1);
            },
            .err => |f| {
                c.wbuf.clearRetainingCapacity();
                return sysError(it, f, try std.fmt.allocPrint(it.alloc(), "error writing \"{s}\": ", .{c.name}));
            },
        }
    }
    c.wbuf.clearRetainingCapacity();
}

pub fn flushChannel(it: *Interp, c: *Channel) Error!void {
    return flushOut(it, c);
}

const Fill = enum { data, eof, again };

/// Reads more bytes.
fn fillMore(it: *Interp, c: *Channel) Error!Fill {
    if (c.hit_eof) return .eof;
    if (c.rpos > 0) {
        const rest = c.rbuf.items.len - c.rpos;
        std.mem.copyForwards(u8, c.rbuf.items[0..rest], c.rbuf.items[c.rpos..]);
        c.rbuf.items.len = rest;
        c.rpos = 0;
    }
    settle(it, c);
    if (c.connecting) return .again;
    if (c.fail != null) return sysError(it, .{ .name = "ENOTCONN", .text = "socket is not connected" }, try std.fmt.allocPrint(it.alloc(), "error reading \"{s}\": ", .{c.name}));
    try c.rbuf.ensureUnusedCapacity(it.alloc(), 16384);
    const room = c.rbuf.unusedCapacitySlice();
    const got: sys.IoResult = if (c.filter) |f| .{ .n = try f.read(f, it, c.fd, room) } else try @import("tape.zig").read(it, c.fd, room);
    switch (got) {
        .n => |n| {
            meterIo(it, c, true, n);
            if (n == 0) {
                c.hit_eof = true;
                return .eof;
            }
            const old = c.rbuf.items.len;
            c.rbuf.items.len += n;
            cutAtEof(c, old);
            if (c.rbuf.items.len == old) return .eof;
            return .data;
        },
        .again => return .again,
        .err => |f| {
            // A reset connection reads as the end of the data.
            // A PTY whose other side closed reads EIO on Linux.
            if ((c.kind != .file and eql(f.name, "ECONNRESET")) or (c.pty and eql(f.name, "EIO"))) {
                c.hit_eof = true;
                return .eof;
            }
            return sysError(it, f, try std.fmt.allocPrint(it.alloc(), "error reading \"{s}\": ", .{c.name}));
        },
    }
}

/// Ends the input at the first `eof_in` character at or after `from`
/// in the read buffer.
fn cutAtEof(c: *Channel, from: usize) void {
    if (c.eof_in == 0 or c.mem or from >= c.rbuf.items.len) return;
    const k = std.mem.indexOfScalarPos(u8, c.rbuf.items, from, c.eof_in) orelse return;
    c.eof_drop += c.rbuf.items.len - k;
    c.rbuf.items.len = k;
    c.hit_eof = true;
}

/// Reads more bytes. Gives false at the end of the file and when a
/// channel that does not block has no data.
fn fill(it: *Interp, c: *Channel) Error!bool {
    switch (try fillMore(it, c)) {
        .data => return true,
        .eof => return false,
        .again => {
            c.blocked = true;
            return false;
        },
    }
}

/// The text of input bytes after the translation and the encoding.
fn decode(it: *Interp, c: *Channel, raw: []const u8) Error![]const u8 {
    if (c.enc) |e| return (try decodeTable(it, c, e, raw, true, std.math.maxInt(usize))).text;
    return translate(it, c, raw, c.binary);
}

/// The text of input bytes in a table encoding, at most `limit`
/// characters. `used` is the count of bytes of the text.
fn decodeTable(it: *Interp, c: *Channel, e: enc.Encoding, raw: []const u8, end: bool, limit: usize) Error!struct { text: []const u8, used: usize } {
    var out: std.ArrayList(u8) = .empty;
    const got = try enc.toUtf(it, e, &c.in_state, raw, end, limit, &out);
    return .{ .text = try translate(it, c, out.items, false), .used = got.used };
}

/// Reserves room in the read buffer for the rest of a regular file, so
/// that a `read` to the end of the file grows the buffer one time and
/// reads it with one system call. A channel whose `seek` fails, such as
/// a FIFO, keeps the reads of 16 KiB.
fn reserveRest(it: *Interp, c: *Channel) Error!void {
    if (c.kind != .file or c.mem or c.filter != null or c.pty or c.hit_eof) return;
    if (it.tape != null) return;
    const cur = switch (sys.seek(c.fd, 0, 1)) {
        .at => |p| p,
        .err => return,
    };
    const end = switch (sys.seek(c.fd, 0, 2)) {
        .at => |p| p,
        .err => return,
    };
    _ = sys.seek(c.fd, cur, 0);
    if (end <= cur) return;
    const rest: usize = @intCast(@min(end - cur, 1 << 30));
    // The extra 16 KiB is the room of the read that finds the end.
    try c.rbuf.ensureUnusedCapacity(it.alloc(), rest + 16384);
}

/// The UTF-8 text of bytes with one character for each byte (the
/// `binary` encoding with the translation `lf`). A first pass counts the
/// bytes of 0x80 or more, 32 at a time, for the exact size of the
/// output. A block of 32 bytes below 0x80 goes to the output as it is.
/// The other bytes go through a loop with no branch on the byte.
fn latin1ToUtf8(a: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    const V = @Vector(32, u8);
    const top: V = @splat(0x80);
    var high: usize = 0;
    var i: usize = 0;
    while (i + 32 <= raw.len) : (i += 32) {
        const v: V = raw[i..][0..32].*;
        high += @popCount(@as(u32, @bitCast(v >= top)));
    }
    for (raw[i..]) |b| high += b >> 7;
    // One byte more: the loop writes the second byte of each input byte.
    const out = try a.alloc(u8, raw.len + high + 1);
    if (high == 0) {
        @memcpy(out[0..raw.len], raw);
        return out[0..raw.len];
    }
    var o: usize = 0;
    i = 0;
    while (i < raw.len) {
        const n = @min(32, raw.len - i);
        if (n == 32) {
            const v: V = raw[i..][0..32].*;
            if (@reduce(.Max, v) < 0x80) {
                @memcpy(out[o..][0..32], raw[i..][0..32]);
                o += 32;
                i += 32;
                continue;
            }
        }
        for (raw[i .. i + n]) |b| {
            const h: usize = b >> 7;
            out[o] = if (h != 0) 0xC0 | (b >> 6) else b;
            out[o + 1] = 0x80 | (b & 63);
            o += 1 + h;
        }
        i += n;
    }
    return out[0..o];
}

/// The text of input bytes after the translation of line ends. With
/// `binary`, each byte is one character.
fn translate(it: *Interp, c: *const Channel, raw: []const u8, binary: bool) Error![]const u8 {
    const a = it.alloc();
    if (binary and c.input == .lf) return latin1ToUtf8(a, raw);
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        // A run of bytes with no CR, and no high byte in binary mode,
        // goes to the output as it is.
        var j = i;
        if (binary) {
            while (j < raw.len and raw[j] != '\r' and raw[j] < 0x80) j += 1;
        } else j = std.mem.indexOfScalarPos(u8, raw, i, '\r') orelse raw.len;
        try out.appendSlice(a, raw[i..j]);
        i = j;
        if (i == raw.len) break;
        var ch = raw[i];
        switch (c.input) {
            .auto, .crlf => if (ch == '\r' and i + 1 < raw.len and raw[i + 1] == '\n') {
                i += 1;
                ch = '\n';
            } else if (ch == '\r' and c.input == .auto) {
                ch = '\n';
            },
            .cr => if (ch == '\r') {
                ch = '\n';
            },
            else => {},
        }
        if (binary and ch >= 0x80) {
            try out.append(a, 0xC0 | (ch >> 6));
            try out.append(a, 0x80 | (ch & 63));
        } else try out.append(a, ch);
    }
    if (!binary and c.enc == null) {
        const p = c.profile orelse enc.defaultProfile(it);
        if (p != .tcl8) return checkUtf8(it, c, out.items, p);
    }
    return out.items;
}

/// The text of UTF-8 input under the profile `strict` or `replace`. A
/// byte that starts no valid sequence is an error with `strict` and
/// U+FFFD with `replace`. A sequence that the end of the input cuts
/// stays as it is.
fn checkUtf8(it: *Interp, c: *const Channel, text: []u8, p: enc.Profile) Error![]const u8 {
    var i: usize = 0;
    var out: ?std.ArrayList(u8) = null;
    var copied: usize = 0;
    while (i < text.len) {
        if (text[i] < 0x80) {
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        if (n > 0 and i + n > text.len) {
            // A cut sequence at the end: the start of a valid one.
            const tail = text[i..];
            var ok = true;
            for (tail[1..]) |b| ok = ok and b & 0xC0 == 0x80;
            if (ok) break;
        }
        if (n > 0 and i + n <= text.len) {
            if (std.unicode.utf8Decode(text[i .. i + n])) |_| {
                i += n;
                continue;
            } else |_| {}
        }
        if (p == .strict) {
            const msg = "invalid or incomplete multibyte or wide character";
            return it.failCode("POSIX EILSEQ {" ++ msg ++ "}", "error reading \"{s}\": " ++ msg, .{c.name});
        }
        const a = it.alloc();
        if (out == null) out = .empty;
        try out.?.appendSlice(a, text[copied..i]);
        try out.?.appendSlice(a, "\u{FFFD}");
        i += 1;
        copied = i;
    }
    if (out) |*o| {
        try o.appendSlice(it.alloc(), text[copied..]);
        return o.items;
    }
    return text;
}

/// Sets the encoding of a channel, as `-encoding` does.
fn setEncoding(it: *Interp, c: *Channel, e: []const u8) Error!void {
    const a = it.alloc();
    var table: ?enc.Encoding = null;
    var bin = false;
    if (eql(e, "binary") or eql(e, "iso8859-1") or e.len == 0) {
        bin = true;
    } else if (!eql(e, "utf-8") and !eql(e, "identity")) {
        table = (try enc.forChannel(it, e)) orelse return it.failCode(try std.fmt.allocPrint(a, "TCL LOOKUP ENCODING {s}", .{e}), "unknown encoding \"{s}\"", .{e});
    }
    try endEncoding(it, c);
    c.binary = bin;
    c.enc = table;
    c.enc_name = if (e.len == 0) "" else try a.dupe(u8, e);
    c.in_state = .{};
    c.out_state = .{};
}

/// Gives a standard channel the system encoding at its first write, as
/// Tcl makes the standard channels at their first use.
fn settleEncoding(it: *Interp, c: *Channel) Error!void {
    c.lazy_enc = false;
    if (eql(it.sys_encoding, "utf-8")) return;
    try setEncoding(it, c, it.sys_encoding);
}

fn writeText(it: *Interp, c: *Channel, text: []const u8) Error!void {
    if (!c.writable) return it.fail("channel \"{s}\" wasn't opened for writing", .{c.name});
    if (c.lazy_enc) try settleEncoding(it, c);
    const a = it.alloc();
    if (c.enc) |e| {
        var lines: std.ArrayList(u8) = .empty;
        for (text) |ch| switch (ch) {
            '\n' => switch (c.output) {
                .cr => try lines.append(a, '\r'),
                .crlf => try lines.appendSlice(a, "\r\n"),
                else => try lines.append(a, ch),
            },
            else => try lines.append(a, ch),
        };
        try enc.fromUtf(it, e, &c.out_state, lines.items, false, &c.wbuf);
    } else try writeBytes(it, c, text);
    const line = eql(c.buffering, "line") and std.mem.indexOfScalar(u8, text, '\n') != null;
    if (eql(c.buffering, "none") or c.wbuf.items.len >= 65536 or line) try flushOut(it, c);
}

fn writeBytes(it: *Interp, c: *Channel, text: []const u8) Error!void {
    const a = it.alloc();
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        var ch = text[i];
        if (c.binary and ch >= 0xC0 and i + 1 < text.len) {
            ch = (ch << 6) | (text[i + 1] & 63);
            i += 1;
            try c.wbuf.append(a, ch);
            continue;
        }
        if (ch == '\n') switch (c.output) {
            .cr => ch = '\r',
            .crlf => try c.wbuf.append(a, '\r'),
            else => {},
        };
        try c.wbuf.append(a, ch);
    }
}

/// `puts` on a channel of this module. Gives false for an unknown name.
pub fn putsTo(it: *Interp, name: []const u8, text: []const u8, newline: bool) Error!bool {
    const c = it.chans.table.get(name) orelse return false;
    if (c.ext != null) {
        _ = try extCall(it, c, if (newline) "putsnl" else "puts", &.{.{ .str = text }});
        return true;
    }
    try writeText(it, c, text);
    if (newline) try writeText(it, c, "\n");
    return true;
}

fn parseMode(it: *Interp, text: []const u8) Error!struct { flags: sys.OpenFlags, read: bool, write: bool, append: bool, binary: bool = false } {
    var f: sys.OpenFlags = .{};
    // The flag b and BINARY give a channel with -translation binary.
    var bin = false;
    var r = false;
    var w = false;
    var ap = false;
    if (text.len > 0 and std.ascii.isUpper(text[0])) {
        for (try it.list(.{ .str = text })) |v| {
            const m = try it.str(v);
            if (eql(m, "RDONLY")) {
                r = true;
            } else if (eql(m, "WRONLY")) {
                w = true;
            } else if (eql(m, "RDWR")) {
                r = true;
                w = true;
            } else if (eql(m, "APPEND")) {
                ap = true;
                f.append = true;
            } else if (eql(m, "CREAT")) {
                f.create = true;
            } else if (eql(m, "EXCL")) {
                f.exclusive = true;
            } else if (eql(m, "TRUNC")) {
                f.truncate = true;
            } else if (eql(m, "BINARY")) {
                bin = true;
            } else if (!eql(m, "NOCTTY") and !eql(m, "NONBLOCK")) {
                return it.failCode("TCL LOOKUP INDEX flag", "invalid access mode \"{s}\": must be APPEND, BINARY, CREAT, EXCL, NOCTTY, NONBLOCK, RDONLY, RDWR, TRUNC, or WRONLY", .{m});
            }
        }
        if (!r and !w) return it.fail("access mode must include either RDONLY, WRONLY, or RDWR", .{});
    } else {
        var body = text;
        if (std.mem.indexOfScalar(u8, body, 'b')) |k| {
            bin = true;
            body = try std.mem.concat(it.alloc(), u8, &.{ body[0..k], body[k + 1 ..] });
        }
        if (eql(body, "r")) {
            r = true;
        } else if (eql(body, "r+")) {
            r = true;
            w = true;
        } else if (eql(body, "w")) {
            w = true;
            f.create = true;
            f.truncate = true;
        } else if (eql(body, "w+")) {
            r = true;
            w = true;
            f.create = true;
            f.truncate = true;
        } else if (eql(body, "a")) {
            w = true;
            ap = true;
            f.create = true;
            f.append = true;
        } else if (eql(body, "a+")) {
            r = true;
            w = true;
            ap = true;
            f.create = true;
            f.append = true;
        } else return it.fail("illegal access mode \"{s}\"", .{text});
    }
    f.access = if (r and w) .read_write else if (w) .write else .read;
    return .{ .flags = f, .read = r, .write = w, .append = ap, .binary = bin };
}

fn cmdOpen(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2 or argv.len > 4) return it.wrongArgs("open fileName ?access? ?permissions?");
    const a = it.alloc();
    const path = try it.str(argv[1]);
    // `exec` is absent, so a command pipeline is an error.
    const m = try parseMode(it, if (argv.len >= 3) try it.str(argv[2]) else "r");
    if (path.len > 0 and path[0] == '|') {
        // A command pipeline needs the capability `exec`.
        if (it.capabilities & @backingInt(interp.Capability.exec) == 0) return it.fail("couldn't open \"{s}\": command pipelines are not available", .{path});
        if (comptime !proc_ok) return it.fail("couldn't open \"{s}\": exec is not available on this target", .{path});
        return proc_mod.openPipeline(it, path[1..], m.read, m.write);
    }
    if (try vfs.gate(it, path, .channels, "couldn't open")) |h| {
        if (m.write) return vfs.readOnly(it, "couldn't open", path);
        const data = try vfs.read(it, h, "couldn't open", path);
        const c = try a.create(Channel);
        const name = try std.fmt.allocPrint(a, "file{d}", .{it.chans.number(false)});
        c.* = .{ .name = name, .fd = -1, .readable = true, .writable = false, .mem = true, .hit_eof = true };
        try c.rbuf.appendSlice(a, data);
        try it.chans.table.put(a, name, c);
        return .{ .str = name };
    }
    var perm: u32 = 0o666;
    if (argv.len == 4) perm = @intCast((try it.int(argv[3])) & 0o777);
    // A Windows serial port, `COM3`, is a device of the system, so it
    // needs host mode.
    const win_port = if (comptime builtin.os.tag == .windows) serial.winPortPath(path) else null;
    if (win_port != null and !it.fs.host) return it.failCode("POSIX EACCES {permission denied}", "couldn't open \"{s}\": permission denied", .{path});
    const fd = if (win_port) |p| try serial.openWin(it, p, m.read, m.write) else blk: {
        const rel = (try fsroot.normal(it, path)) orelse return it.failCode("POSIX EACCES {permission denied}", "couldn't open \"{s}\": permission denied", .{path});
        break :blk switch (try fsroot.openRel(it, rel, m.flags, perm)) {
            .fd => |x| x,
            .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(a, "couldn't open \"{s}\": ", .{path})),
        };
    };
    // A serial port goes into raw mode, as in Tcl.
    if (comptime serial.supported) {
        if (win_port == null and serial.isPort(fd)) serial.init(fd);
    }
    const c = try a.create(Channel);
    const name = try std.fmt.allocPrint(a, "file{d}", .{it.chans.number(false)});
    // A file writes the line end of the platform, as in Tcl: crlf on
    // Windows.
    c.* = .{ .name = name, .fd = fd, .readable = m.read, .writable = m.write, .append = m.append, .output = platform_eol };
    if (m.binary) {
        c.binary = true;
        // Tcl reports the translation of a binary channel as lf.
        if (c.readable) c.input = .lf;
        c.output = .lf;
    }
    try it.chans.table.put(a, name, c);
    return .{ .str = name };
}

fn closeFds(it: *Interp, c: *Channel) void {
    if (c.filter) |f| {
        if (!c.write_closed) f.closeWrite(f, it, outFd(c));
        f.deinit(f, it);
        c.filter = null;
    }
    if (c.mem) return;
    if (!c.read_closed or c.wfd < 0) sys.close(c.fd);
    if (c.wfd >= 0 and !c.write_closed) sys.close(c.wfd);
}

pub fn closeChan(it: *Interp, c: *Channel) Error!void {
    if (c.writable and !c.draining) try endEncoding(it, c);
    if (c.writable and c.eof_out != 0 and !c.draining) {
        try c.wbuf.append(it.alloc(), c.eof_out);
        c.eof_out = 0;
    }
    const r = flushOut(it, c);
    if (c.wbuf.items.len > 0 and !c.blocking and !c.draining) {
        // The channel leaves the table of the script under a name that
        // no script can give, and the event loop ends the write.
        event.unwatch(it, c.name);
        _ = it.chans.table.orderedRemove(c.name);
        c.name = try std.fmt.allocPrint(it.alloc(), "\x00drain{d}", .{it.chans.next});
        it.chans.next += 1;
        c.draining = true;
        c.on_read = null;
        c.on_write = null;
        try it.chans.table.put(it.alloc(), c.name, c);
        try event.watch(it, c.name);
        return;
    }
    closeFds(it, c);
    event.unwatch(it, c.name);
    _ = it.chans.table.orderedRemove(c.name);
    var next_sib = c.sibling;
    while (next_sib) |sib| {
        sys.close(sib.fd);
        event.unwatch(it, sib.name);
        _ = it.chans.table.orderedRemove(sib.name);
        next_sib = sib.sibling;
    }
    if (c.draining) return;
    try r;
    if (comptime proc_ok) {
        if (c.pty) {
            pty_mod.hangup(it, c);
        } else if (c.pids.len > 0) try proc_mod.reap(it, c);
    }
}

/// Closes all channels when the interpreter ends.
pub fn closeAll(it: *Interp) void {
    for (it.chans.table.values()) |c| {
        flushOut(it, c) catch {};
        // The descriptors 0, 1, and 2 of `useStdio` belong to the process,
        // which writes to them after the interp: the report of the leak
        // check of a Debug build goes to stderr at the exit. In a sandbox
        // child of Windows, stdout and stderr are one handle, so a close of
        // stdout here made that write raise STATUS_INVALID_HANDLE. A close
        // of `stdout` by a script still closes it.
        if (!c.mem and c.filter == null and c.wfd < 0 and c.fd >= 0 and c.fd <= 2) continue;
        closeFds(it, c);
        if (comptime proc_ok) {
            if (c.pids.len > 0) proc_mod.abandon(c);
        }
    }
    it.chans.table = .empty;
}

/// Adds a channel on an open descriptor. `prefix` starts its name.
pub fn adopt(it: *Interp, prefix: []const u8, fd: i32, readable: bool, writable: bool) Error!*Channel {
    const a = it.alloc();
    const c = try a.create(Channel);
    const n = it.chans.number(eql(prefix, "sock"));
    const name = try std.fmt.allocPrint(a, "{s}{d}", .{ prefix, n });
    c.* = .{ .name = name, .fd = fd, .readable = readable, .writable = writable };
    try it.chans.table.put(a, name, c);
    return c;
}

/// Makes `stdin`, `stdout`, and `stderr` channels on the descriptors 0,
/// 1, and 2 of the process. A runner that acts as `tclsh` calls it.
/// Without this call the three names are not channels, and `puts`
/// writes to the callback of the embedder.
pub fn useStdio(it: *Interp) Error!void {
    const a = it.alloc();
    const specs = [_]struct { []const u8, i32, bool }{ .{ "stdin", 0, true }, .{ "stdout", 1, false }, .{ "stderr", 2, false } };
    for (specs) |sp| {
        const c = try a.create(Channel);
        c.* = .{ .name = sp[0], .fd = sp[1], .readable = sp[2], .writable = !sp[2], .kind = .pipe };
        c.lazy_enc = sp[1] != 0;
        if (sp[1] == 1) c.buffering = "line";
        if (sp[1] == 2) c.buffering = "none";
        try it.chans.table.put(a, sp[0], c);
    }
}

/// Adds a channel that no script can name.
pub fn adoptHidden(it: *Interp, fd: i32) Error!*Channel {
    const a = it.alloc();
    const c = try a.create(Channel);
    const name = try std.fmt.allocPrint(a, "\x00sib{d}", .{it.chans.next});
    it.chans.next += 1;
    c.* = .{ .name = name, .fd = fd, .readable = false, .writable = false };
    try it.chans.table.put(a, name, c);
    return c;
}

/// Checks the end of a background connect with no wait.
pub fn progress(it: *Interp, c: *Channel) void {
    var w = [_]sys.Want{.{ .fd = c.fd, .write = true }};
    sys.poll(it.alloc(), &w, 0);
    if (w[0].can_write) connected(c);
}

/// Removes the channel `name` from the table of `it` and from the event
/// loop with no close. Gives the record, or null. `thread::detach` uses
/// it.
pub fn release(it: *Interp, name: []const u8) ?*Channel {
    const c = it.chans.table.get(name) orelse return null;
    event.unwatch(it, name);
    _ = it.chans.table.orderedRemove(name);
    return c;
}

/// Adds a channel record to the table of `it` under its name.
/// `thread::attach` uses it.
pub fn install(it: *Interp, c: *Channel) Error!void {
    try it.chans.table.put(it.alloc(), c.name, c);
}

pub fn lookup(it: *Interp, name: []const u8) ?*Channel {
    return it.chans.table.get(name);
}

/// What the event loop waits for on a channel, or null.
pub fn wanted(it: *Interp, name: []const u8) ?struct { fd: i32, wfd: i32, read: bool, write: bool, ready: bool } {
    const c = it.chans.table.get(name) orelse return null;
    // A channel of a C package or a reflected channel has no
    // descriptor: see `extReady`.
    if (c.ext != null or c.refl != null) return null;
    if (c.kind == .server) return .{ .fd = c.fd, .wfd = c.fd, .read = true, .write = false, .ready = false };
    const r = c.on_read != null;
    const pending = c.wbuf.items.len > 0 and !c.blocking;
    const w = c.on_write != null or c.connecting or pending;
    if (!r and !w) return null;
    const has_data = c.rpos < c.rbuf.items.len and !c.blocked;
    return .{ .fd = c.fd, .wfd = outFd(c), .read = r and !c.hit_eof, .write = w, .ready = r and (has_data or c.hit_eof) };
}

/// Runs the handlers of a channel that is ready. `cur` runs the loop.
pub fn serve(cur: *Interp, it: *Interp, name: []const u8, can_read: bool, can_write: bool) Error!bool {
    const c = it.chans.table.get(name) orelse return false;
    var ran = false;
    if (c.kind == .server) {
        while (sys.accept(c.fd)) |conn| {
            if (c.accept.len == 0 or !@import("sock.zig").acceptable(it, c, conn)) {
                sys.close(conn.fd);
                continue;
            }
            const n = try adopt(it, "sock", conn.fd, true, true);
            n.kind = .socket;
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(it.alloc(), c.accept);
            try text.print(it.alloc(), " {s} {s} {d}", .{ n.name, try @import("sock.zig").addrText(it, conn.peer), conn.peer.port });
            ran = true;
            switch (try event.runHandler(cur, it, text.items)) {
                .ok => {},
                .gone => return true,
                // A failed accept command closes the connection.
                .failed => if (it.chans.table.get(n.name) == n) closeChan(it, n) catch {},
            }
            if (it.chans.table.get(name) != c) break;
        }
        return ran;
    }
    if (can_write and c.connecting) {
        connected(c);
        if (c.fail == null and !@import("sock.zig").checkPeer(it, c)) {
            // The policy does not allow the address of the connection.
            sys.shutdown(c.fd, 0);
            sys.shutdown(c.fd, 1);
            c.fail = .{ .name = "EACCES", .text = "permission denied" };
        }
    }
    if (can_write and c.wbuf.items.len > 0 and !c.blocking) {
        flushOut(it, c) catch {};
        if (c.draining and c.wbuf.items.len == 0) {
            c.draining = false;
            closeChan(it, c) catch {};
            return true;
        }
        if (c.wbuf.items.len == 0 and c.on_read == null and c.on_write == null) event.unwatch(it, c.name);
        ran = true;
    }
    if (can_read) if (c.on_read) |script| {
        ran = true;
        switch (try event.runHandler(cur, it, script)) {
            .ok => {},
            .gone => return true,
            .failed => if (it.chans.table.get(name) == c) {
                c.on_read = null;
            },
        }
        if (it.chans.table.get(name) != c) return ran;
    };
    if (can_write) if (c.on_write) |script| {
        ran = true;
        switch (try event.runHandler(cur, it, script)) {
            .ok => {},
            .gone => return true,
            .failed => if (it.chans.table.get(name) == c) {
                c.on_write = null;
            },
        }
    };
    return ran;
}

pub fn cmdFileevent(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3 and argv.len != 4) {
        // `chan event` calls this with the word "event" first.
        if (eql(try it.str(argv[0]), "event")) return it.wrongArgs("chan event channelId event ?script?");
        return it.wrongArgs("fileevent channelId event ?script?");
    }
    const ev = try it.str(argv[2]);
    const readable = eql(ev, "readable");
    if (!readable and !eql(ev, "writable")) return it.failCode("TCL LOOKUP INDEX {event name}", "bad event name \"{s}\": must be readable or writable", .{ev});
    const c = try find(it, argv[1]);
    if (c.ext != null) return extCall(it, c, "fileevent", argv[2..]);
    if (readable and !c.readable) return it.fail("channel is not readable", .{});
    if (!readable and !c.writable) return it.fail("channel is not writable", .{});
    const slot = if (readable) &c.on_read else &c.on_write;
    if (argv.len == 3) return .{ .str = slot.* orelse "" };
    const script = try it.str(argv[3]);
    if (script.len == 0) {
        slot.* = null;
        if (c.on_read == null and c.on_write == null and !c.connecting) event.unwatch(it, c.name);
    } else {
        slot.* = try it.alloc().dupe(u8, script);
        try event.watch(it, c.name);
    }
    if (c.refl) |r| try refl_mod.rewatch(r);
    return Value.empty;
}

fn cmdFblocked(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("fblocked channelId");
    const c = try find(it, argv[1]);
    if (c.ext != null) return extCall(it, c, "fblocked", argv[2..]);
    if (!c.readable) return it.fail("channel \"{s}\" wasn't opened for reading", .{c.name});
    return .{ .int = @intFromBool(c.blocked) };
}

fn cmdClose(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2 and argv.len != 3) return it.wrongArgs("close channelId ?direction?");
    const c = try find(it, argv[1]);
    if (c.ext != null) return extCall(it, c, "close", argv[2..]);
    if (argv.len == 3) {
        const dir = try it.str(argv[2]);
        const rd = dir.len > 0 and std.mem.startsWith(u8, "read", dir);
        if (!rd and !(dir.len > 0 and std.mem.startsWith(u8, "write", dir))) return it.failCode("TCL LOOKUP INDEX direction", "bad direction \"{s}\": must be read or write", .{dir});
        if (rd and !c.readable) return it.fail("Half-close of read-side not possible, side not opened or already closed", .{});
        if (!rd and !c.writable) return it.fail("Half-close of write-side not possible, side not opened or already closed", .{});
        if (c.readable and c.writable) {
            if (rd) {
                c.readable = false;
                c.read_closed = true;
                c.on_read = null;
                if (c.kind == .socket) sys.shutdown(c.fd, 0) else if (c.wfd >= 0) sys.close(c.fd);
            } else {
                try flushOut(it, c);
                if (c.filter) |f| f.closeWrite(f, it, outFd(c));
                c.writable = false;
                c.write_closed = true;
                c.on_write = null;
                if (c.kind == .socket) sys.shutdown(c.fd, 1) else if (c.wfd >= 0) sys.close(c.wfd);
            }
            return Value.empty;
        }
    }
    const r = c.refl;
    try closeChan(it, c);
    // An error of `finalize` is the error of `close`.
    if (r) |x| if (x.fin_error) |fe| {
        it.result = fe.result;
        it.error_code = fe.code;
        return error.TclError;
    };
    return Value.empty;
}

fn cmdFlush(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("flush channelId");
    const name = try it.str(argv[1]);
    if (it.chans.table.get(name) == null and (eql(name, "stdout") or eql(name, "stderr"))) return Value.empty;
    const c = try find(it, argv[1]);
    if (c.ext != null) return extCall(it, c, "flush", argv[2..]);
    if (!c.writable) return it.fail("channel \"{s}\" wasn't opened for writing", .{name});
    try flushOut(it, c);
    return Value.empty;
}

fn cmdEof(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("eof channelId");
    const c = try find(it, argv[1]);
    if (c.ext != null) return extCall(it, c, "eof", argv[2..]);
    return .{ .int = @intFromBool(c.at_eof) };
}

fn cmdGets(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2 and argv.len != 3) return it.wrongArgs("gets channelId ?varName?");
    const c = try find(it, argv[1]);
    if (c.ext != null) return extCall(it, c, "gets", argv[2..]);
    if (!c.readable) return it.fail("channel \"{s}\" wasn't opened for reading", .{c.name});
    try flushOut(it, c);
    c.blocked = false;
    var scan: usize = c.rpos;
    var end: ?usize = null;
    // In `unicode` (UTF-16), a line end is a unit of two bytes, at an
    // even offset from the read position.
    const unit: usize = if (c.enc != null and c.enc.? == .utf16) 2 else 1;
    while (true) {
        var k = scan;
        while (k + unit <= c.rbuf.items.len) : (k += unit) {
            const ch = c.rbuf.items[k];
            if (unit == 2 and c.rbuf.items[k + 1] != 0) continue;
            if (ch == '\n' or (ch == '\r' and (c.input == .cr or c.input == .auto))) {
                end = k;
                break;
            }
            if (ch == '\r' and c.input == .crlf and k + unit < c.rbuf.items.len and c.rbuf.items[k + unit] == '\n') {
                end = k;
                break;
            }
        }
        if (end != null) break;
        scan = k - c.rpos;
        if (!try fill(it, c)) break;
    }
    var line: []const u8 = undefined;
    var got_any = true;
    if (end) |e| {
        line = try decode(it, c, c.rbuf.items[c.rpos..e]);
        var next = e + unit;
        if (c.rbuf.items[e] == '\r' and next < c.rbuf.items.len and c.rbuf.items[next] == '\n' and c.input != .cr) next += unit;
        c.rpos = next;
    } else if (c.blocked) {
        // A partial line stays in the buffer for the next call.
        got_any = false;
        line = "";
    } else {
        got_any = c.rpos < c.rbuf.items.len;
        line = try decode(it, c, c.rbuf.items[c.rpos..]);
        c.rpos = c.rbuf.items.len;
        c.at_eof = true;
    }
    if (argv.len == 3) {
        try it.setVar(try it.str(argv[2]), .{ .str = line });
        return .{ .int = if (got_any) @intCast(cmds.charCount(line)) else -1 };
    }
    return .{ .str = line };
}

/// The count of bytes at the end that start a UTF-8 character and do
/// not complete it.
fn partialTail(raw: []const u8) usize {
    var back: usize = 1;
    while (back <= 3 and back <= raw.len) : (back += 1) {
        const ch = raw[raw.len - back];
        if (ch < 0x80) return 0;
        if (ch >= 0xC0) {
            const need: usize = if (ch >= 0xF0) 4 else if (ch >= 0xE0) 3 else 2;
            return if (need > back) back else 0;
        }
    }
    return 0;
}

fn cmdRead(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var args = argv[1..];
    var nonl = false;
    if (args.len > 0 and eql(try it.str(args[0]), "-nonewline")) {
        nonl = true;
        args = args[1..];
    }
    if (args.len < 1 or args.len > 2) return it.wrongArgs("read channelId ?numChars?\" or \"read ?-nonewline? channelId");
    const c = try find(it, args[0]);
    if (c.ext != null) return extCall(it, c, if (nonl) "read-nonewline" else "read", args[1..]);
    if (!c.readable) return it.fail("channel \"{s}\" wasn't opened for reading", .{c.name});
    try flushOut(it, c);
    c.blocked = false;
    var want: ?usize = null;
    if (args.len == 2) {
        const n = it.int(args[1]) catch return it.fail("expected non-negative integer but got \"{s}\"", .{try it.str(args[1])});
        if (n < 0) return it.fail("expected non-negative integer but got \"{s}\"", .{try it.str(args[1])});
        want = @intCast(n);
    }
    if (want == null and c.blocking) try reserveRest(it, c);
    while (want == null or c.rbuf.items.len - c.rpos < want.?) {
        if (!try fill(it, c)) break;
        // A channel that does not block stops at a short read, as Tcl
        // does: a read that left free space in the buffer. The end of
        // the file shows at the next read.
        if (!c.blocking and c.rbuf.items.len < c.rbuf.capacity) break;
    }
    if (c.enc) |e| return readTable(it, c, e, want, nonl);
    var raw = c.rbuf.items[c.rpos..];
    if (want) |n| {
        if (raw.len > n) raw = raw[0..n] else c.at_eof = c.hit_eof;
    } else c.at_eof = c.hit_eof;
    if (!c.binary and !c.hit_eof) {
        // The first bytes of a character with no end yet stay in the
        // buffer until more data arrives.
        const cut = partialTail(raw);
        if (cut > 0) {
            raw = raw[0 .. raw.len - cut];
            c.blocked = true;
        }
    }
    c.rpos += raw.len;
    var text = try translate(it, c, raw, c.binary);
    if (nonl and text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
    return .{ .str = text };
}

/// `read` on a channel with a table encoding: `want` counts characters.
fn readTable(it: *Interp, c: *Channel, e: enc.Encoding, want: ?usize, nonl: bool) Error!Value {
    while (true) {
        if (want) |n| {
            var st = c.in_state;
            var tmp: std.ArrayList(u8) = .empty;
            const got = try enc.toUtf(it, e, &st, c.rbuf.items[c.rpos..], c.hit_eof, n, &tmp);
            if (got.chars >= n) break;
        }
        if (!try fill(it, c)) break;
        if (!c.blocking and c.rbuf.items.len < c.rbuf.capacity) break;
    }
    const raw = c.rbuf.items[c.rpos..];
    const r = try decodeTable(it, c, e, raw, c.hit_eof, want orelse std.math.maxInt(usize));
    c.rpos += r.used;
    if (c.rpos >= c.rbuf.items.len) c.at_eof = c.hit_eof;
    if (r.used < raw.len and !c.hit_eof and want == null) c.blocked = true;
    var text = r.text;
    if (nonl and text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
    return .{ .str = text };
}

/// Ends the output of an escape-driven encoding: the bytes that select
/// the first table, and the `final` bytes.
fn endEncoding(it: *Interp, c: *Channel) Error!void {
    const e = c.enc orelse return;
    if (e != .escape or !c.out_state.started) return;
    try enc.fromUtf(it, e, &c.out_state, "", true, &c.wbuf);
}

fn cmdSeek(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3 and argv.len != 4) return it.wrongArgs("seek channelId offset ?origin?");
    const c = try find(it, argv[1]);
    if (c.ext != null) return extCall(it, c, "seek", argv[2..]);
    const off = try it.int(argv[2]);
    var whence: usize = 0;
    var adjust: i64 = 0;
    if (argv.len == 4) {
        const o = try it.str(argv[3]);
        if (eql(o, "current")) {
            whence = 1;
            adjust = -@as(i64, @intCast(c.rbuf.items.len - c.rpos + c.eof_drop));
        } else if (eql(o, "end")) {
            whence = 2;
        } else if (!eql(o, "start")) {
            return it.failCode("TCL LOOKUP INDEX origin", "bad origin \"{s}\": must be start, current, or end", .{o});
        }
    }
    if (c.refl) |r| {
        try flushOut(it, c);
        try xform_mod.clearAll(c);
        _ = try refl_mod.seek(it, r, off + adjust, whence) orelse
            return it.failCode("POSIX EINVAL {invalid argument}", "error during seek on \"{s}\": invalid argument", .{c.name});
        c.rbuf.clearRetainingCapacity();
        c.rpos = 0;
        c.at_eof = false;
        c.hit_eof = false;
        c.eof_drop = 0;
        return Value.empty;
    }
    if (c.mem) return memSeek(it, c, off, whence);
    try flushOut(it, c);
    try xform_mod.clearAll(c);
    switch (sys.seek(c.fd, off + adjust, @intCast(whence))) {
        .at => {},
        .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "error during seek on \"{s}\": ", .{c.name})),
    }
    c.rbuf.clearRetainingCapacity();
    c.rpos = 0;
    c.at_eof = false;
    c.hit_eof = false;
    c.eof_drop = 0;
    return Value.empty;
}

/// `seek` on a channel of `vfs.zig`: the position in the read buffer.
fn memSeek(it: *Interp, c: *Channel, off: i64, whence: usize) Error!Value {
    const len: i64 = @intCast(c.rbuf.items.len);
    const from: i64 = switch (whence) {
        0 => 0,
        1 => @intCast(c.rpos),
        else => len,
    };
    const to = from + off;
    if (to < 0) return it.failCode("POSIX EINVAL {invalid argument}", "error during seek on \"{s}\": invalid argument", .{c.name});
    c.rpos = @intCast(@min(to, len));
    c.at_eof = false;
    return Value.empty;
}

fn cmdTell(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("tell channelId");
    const c = try find(it, argv[1]);
    if (c.ext != null) return extCall(it, c, "tell", argv[2..]);
    if (c.refl) |r| {
        const at = try refl_mod.seek(it, r, 0, 1) orelse return .{ .int = -1 };
        return .{ .int = at - @as(i64, @intCast(c.rbuf.items.len - c.rpos)) + @as(i64, @intCast(c.wbuf.items.len)) };
    }
    if (c.mem) return .{ .int = @intCast(c.rpos) };
    const at: i64 = switch (sys.seek(c.fd, 0, 1)) {
        .at => |x| x,
        .err => return .{ .int = -1 },
    };
    return .{ .int = at - @as(i64, @intCast(c.rbuf.items.len - c.rpos + c.eof_drop)) + @as(i64, @intCast(c.wbuf.items.len)) };
}

fn parseTranslation(it: *Interp, v: Value) Error!Translation {
    const s = try it.str(v);
    if (eql(s, "platform")) return platform_eol;
    return std.meta.stringToEnum(Translation, s) orelse it.fail("bad value for -translation: must be one of auto, binary, cr, lf, crlf, or platform", .{});
}

fn cmdConfigure(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("fconfigure channelId ?-option value ...?");
    const a = it.alloc();
    const name = try it.str(argv[1]);
    if (it.chans.table.get(name) == null and (eql(name, "stdout") or eql(name, "stderr") or eql(name, "stdin"))) return Value.empty;
    const c = try find(it, argv[1]);
    if (c.ext != null) return extCall(it, c, "fconfigure", argv[2..]);
    const opts = argv[2..];
    const get = struct {
        fn f(x: *Interp, ch: *Channel, o: []const u8) Error!?Value {
            if (eql(o, "-blocking")) return .{ .int = @intFromBool(ch.blocking) };
            if (eql(o, "-buffering")) return .{ .str = ch.buffering };
            if (eql(o, "-buffersize")) return .{ .int = ch.buffersize };
            if (eql(o, "-encoding")) {
                if (ch.lazy_enc) return .{ .str = x.sys_encoding };
                return .{ .str = if (ch.enc_name.len > 0) ch.enc_name else if (ch.binary) "binary" else "utf-8" };
            }
            if (eql(o, "-eofchar")) {
                const in: Value = .{ .str = if (ch.eof_in == 0) "" else try x.alloc().dupe(u8, &.{ch.eof_in}) };
                const out: Value = .{ .str = if (ch.eof_out == 0) "" else try x.alloc().dupe(u8, &.{ch.eof_out}) };
                if (ch.readable and ch.writable) return try value.newList(x.alloc(), &.{ in, out });
                return if (ch.readable) in else out;
            }
            if (x.tcl9() and eql(o, "-profile")) return .{ .str = @tagName(ch.profile orelse enc.defaultProfile(x)) };
            if (ch.kind == .file and !ch.mem) {
                if (try serial.get(x, ch.fd, o)) |v| return v;
            }
            if (ch.kind != .file and ch.kind != .pipe) {
                if (try @import("sock.zig").option(x, ch, o)) |v| return v;
            }
            if (eql(o, "-translation")) {
                if (ch.readable and ch.writable) return try value.newList(x.alloc(), &.{ .{ .str = @tagName(ch.input) }, .{ .str = @tagName(ch.output) } });
                return .{ .str = @tagName(if (ch.readable) ch.input else ch.output) };
            }
            return null;
        }
    }.f;
    const known = if (it.tcl9()) "-blocking, -buffering, -buffersize, -encoding, -eofchar, -profile, or -translation" else "-blocking, -buffering, -buffersize, -encoding, -eofchar, or -translation";
    if (opts.len == 0) {
        var out: std.ArrayList(Value) = .empty;
        const base: []const []const u8 = if (it.tcl9()) &.{ "-blocking", "-buffering", "-buffersize", "-encoding", "-eofchar", "-profile", "-translation" } else &.{ "-blocking", "-buffering", "-buffersize", "-encoding", "-eofchar", "-translation" };
        for (base) |o| {
            try out.append(a, .{ .str = o });
            try out.append(a, (try get(it, c, o)).?);
        }
        if (c.kind == .socket or c.kind == .server) try @import("sock.zig").options(it, c, &out);
        if (c.kind == .file and !c.mem) try serial.options(it, c.fd, &out);
        if (c.refl) |r| if (r.has(.cgetall)) {
            // The options of the handler come after -translation.
            try out.appendSlice(a, try it.list(try r.call(.cgetall, &.{})));
            return value.wrapList(a, out.items);
        };
        // The list is in the order of Tcl: -translation is last.
        const n = out.items.len;
        const t = 2 * (base.len - 1);
        if (n > t + 2) {
            const tr = [2]Value{ out.items[t], out.items[t + 1] };
            std.mem.copyForwards(Value, out.items[t .. n - 2], out.items[t + 2 .. n]);
            out.items[n - 2] = tr[0];
            out.items[n - 1] = tr[1];
        }
        return value.wrapList(a, out.items);
    }
    const names = [_][]const u8{ "-blocking", "-buffering", "-buffersize", "-encoding", "-eofchar", "-translation", "-peername", "-sockname", "-error", "-connecting", "-profile" };
    const full = struct {
        fn f(x: *Interp, v: Value, table: []const []const u8) Error![]const u8 {
            const o = try x.str(v);
            var hit: ?[]const u8 = null;
            if (o.len < 2) return o;
            for (table) |n| {
                if (eql(n, o)) return n;
                if (std.mem.startsWith(u8, n, o)) {
                    if (hit != null) return o;
                    hit = n;
                }
            }
            return hit orelse o;
        }
    }.f;
    if (opts.len == 1) {
        const o = try full(it, opts[0], &names);
        if (try get(it, c, o)) |v| return v;
        if (c.refl) |r| if (r.has(.cget)) return r.call(.cget, &.{.{ .str = o }});
        return it.fail("bad option \"{s}\": should be one of {s}", .{ o, known });
    }
    if (opts.len % 2 != 0) return it.wrongArgs("fconfigure channelId ?-option value ...?");
    var i: usize = 0;
    while (i < opts.len) : (i += 2) {
        const o = try full(it, opts[i], if (it.tcl9()) &.{ "-blocking", "-buffering", "-buffersize", "-encoding", "-eofchar", "-translation", "-profile" } else names[0..6]);
        const v = opts[i + 1];
        if (eql(o, "-blocking")) {
            const b = try @import("expr.zig").truthy(it, v);
            if (c.refl) |r| {
                if (r.has(.blocking)) _ = try r.call(.blocking, &.{.{ .int = @intFromBool(b) }});
                c.blocking = b;
                continue;
            }
            if (!b and isTls(c)) return it.fail("-blocking 0 is not supported on a TLS channel", .{});
            c.blocking = b;
            if (!c.connecting) {
                sys.setBlocking(c.fd, c.blocking);
                if (c.kind == .file and !c.mem) serial.setBlocking(c.fd, c.blocking);
                if (c.wfd >= 0) sys.setBlocking(c.wfd, c.blocking);
            }
        } else if (eql(o, "-buffering")) {
            const b = try it.str(v);
            if (!eql(b, "full") and !eql(b, "line") and !eql(b, "none")) return it.fail("bad value for -buffering: must be one of full, line, or none", .{});
            c.buffering = try a.dupe(u8, b);
        } else if (eql(o, "-buffersize")) {
            c.buffersize = std.math.clamp(try it.int(v), 1, 1 << 20);
        } else if (eql(o, "-encoding")) {
            c.blocked = false;
            c.lazy_enc = false;
            try setEncoding(it, c, try it.str(v));
        } else if (eql(o, "-translation")) {
            const l = try it.list(v);
            if (l.len == 0 or l.len > 2) return it.fail("bad value for -translation: must be a one or two element list", .{});
            const x = try parseTranslation(it, l[0]);
            const y = if (l.len == 2) try parseTranslation(it, l[1]) else x;
            if (c.readable) c.input = x;
            if (c.writable) c.output = if (y == .auto) platform_eol else y;
            if (x == .binary) {
                c.lazy_enc = false;
                try endEncoding(it, c);
                c.binary = true;
                c.enc = null;
                c.enc_name = "";
                c.eof_in = 0;
                c.eof_out = 0;
            }
            // Tcl reports each side of a binary channel as lf.
            if (c.readable and c.input == .binary) c.input = .lf;
            if (c.writable and c.output == .binary) c.output = .lf;
        } else if (eql(o, "-eofchar")) {
            const l = try it.list(v);
            if (l.len > 2) return it.fail("bad value for -eofchar: should be a list of zero, one, or two elements", .{});
            var ch = [2]u8{ 0, 0 };
            for (l, 0..) |e, k| {
                const t = try it.str(e);
                if (t.len > 0 and (t[0] == 0 or t[0] >= 0x80)) return it.fail("bad value for -eofchar: must be non-NUL ASCII character", .{});
                ch[k] = if (t.len > 0) t[0] else 0;
            }
            if (l.len == 1) ch[1] = ch[0];
            c.eof_in = ch[0];
            c.eof_out = ch[1];
            cutAtEof(c, c.rpos);
        } else if (it.tcl9() and eql(o, "-profile")) {
            c.profile = try enc.parseProfile(it, v);
        } else if (c.kind == .file and !c.mem and try serial.set(it, c.fd, o, v)) {
            // An option of a serial port.
        } else if (c.refl != null and c.refl.?.has(.configure)) {
            _ = try c.refl.?.call(.configure, &.{ .{ .str = o }, v });
        } else {
            return it.fail("bad option \"{s}\": should be one of {s}", .{ o, known });
        }
    }
    return Value.empty;
}

fn cmdFcopy(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 3) return it.wrongArgs("fcopy input output ?-size size? ?-command callback?");
    const from = try find(it, argv[1]);
    const to = try find(it, argv[2]);
    var limit: ?usize = null;
    var command: ?Value = null;
    var i: usize = 3;
    while (i + 1 < argv.len) : (i += 2) {
        const o = try it.str(argv[i]);
        if (eql(o, "-size")) {
            const n = try it.int(argv[i + 1]);
            if (n >= 0) limit = @intCast(n);
        } else if (eql(o, "-command")) {
            command = argv[i + 1];
        } else return it.fail("bad option \"{s}\": should be -size or -command", .{o});
    }
    if (command) |cb| {
        // A background copy: each step copies the data that is ready
        // and does not block, then the callback runs with the count.
        const task = try it.alloc().create(Fcopy);
        task.* = .{ .from = from.name, .to = to.name, .limit = limit, .command = cb };
        try event.later(it, 0, fcopyStep, task);
        return Value.empty;
    }
    if (from.ext != null or to.ext != null) return copyChars(it, from, to, limit);
    var total: usize = 0;
    try copyData(it, from, to, limit, &total);
    return .{ .int = @intCast(total) };
}

/// Copies input to output until the end of the input, `limit` bytes,
/// or no data without a block.
fn copyData(it: *Interp, from: *Channel, to: *Channel, limit: ?usize, total: *usize) Error!void {
    while (limit == null or total.* < limit.?) {
        if (from.rpos >= from.rbuf.items.len and !try fill(it, from)) break;
        var chunk = from.rbuf.items[from.rpos..];
        if (limit) |n| chunk = chunk[0..@min(chunk.len, n - total.*)];
        if (from.enc) |e| {
            const r = try decodeTable(it, from, e, chunk, from.hit_eof, std.math.maxInt(usize));
            try writeText(it, to, r.text);
            from.rpos += r.used;
            total.* += r.used;
            // The first bytes of a character wait for the rest.
            if (r.used < chunk.len and !from.hit_eof and !try fill(it, from)) break;
            continue;
        }
        try writeText(it, to, try decode(it, from, chunk));
        from.rpos += chunk.len;
        total.* += chunk.len;
    }
    if (from.hit_eof and from.rpos >= from.rbuf.items.len) from.at_eof = true;
}

/// A background `fcopy`.
const Fcopy = struct {
    from: []const u8,
    to: []const u8,
    limit: ?usize,
    command: Value,
    total: usize = 0,
};

fn fcopyStep(it: *Interp, ctx: *anyopaque) Error!void {
    const task: *Fcopy = @ptrCast(@alignCast(ctx));
    const a = it.alloc();
    const from = it.chans.table.get(task.from) orelse return;
    const to = it.chans.table.get(task.to) orelse return;
    var err: ?[]const u8 = null;
    // The step reads only the data that is ready.
    const was = from.blocking;
    if (was and !from.mem) sys.setBlocking(from.fd, false);
    from.blocking = false;
    copyData(it, from, to, task.limit, &task.total) catch |e| {
        if (e != error.TclError or it.uncatchable()) return e;
        err = try it.str(it.result);
    };
    from.blocking = was;
    if (was and !from.mem) sys.setBlocking(from.fd, true);
    const done = err != null or from.at_eof or (task.limit != null and task.total >= task.limit.?);
    if (!done) {
        from.blocked = false;
        return event.later(it, 5, fcopyStep, task);
    }
    flushOut(it, to) catch {};
    var words: std.ArrayList(Value) = .empty;
    try words.appendSlice(a, try it.list(task.command));
    try words.append(a, .{ .int = @intCast(task.total) });
    if (err) |m| try words.append(a, .{ .str = m });
    try event.runEvent(it, it, try it.str(try value.wrapList(a, words.items)));
}

/// `fcopy` with a channel of a C package on one side. The copy goes
/// through characters: `read` of the input with its encoding, and
/// `puts` of the output with its encoding. The limit and the count are
/// in characters.
fn copyChars(it: *Interp, from: *Channel, to: *Channel, limit: ?usize) Error!Value {
    if (to.ext == null and !to.writable) return it.fail("channel \"{s}\" wasn't opened for writing", .{to.name});
    var total: usize = 0;
    while (limit == null or total < limit.?) {
        const want: usize = if (limit) |n| @min(n - total, 4096) else 4096;
        const got = try cmdRead(it, &.{ .{ .str = "read" }, .{ .str = from.name }, .{ .int = @intCast(want) } }, null);
        const text = try it.str(got);
        if (text.len == 0) break;
        // The channel can go in `read` and `puts`; `find` gives the error.
        _ = try putsTo(it, to.name, text, false);
        total += std.unicode.utf8CountCodepoints(text) catch text.len;
        if (lookup(it, from.name) != from) break;
    }
    return .{ .int = @intCast(total) };
}

pub fn cmdSource(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2 and argv.len != 4) return it.wrongArgs("source ?-encoding name? fileName");
    const a = it.alloc();
    var e_name: []const u8 = "utf-8";
    if (argv.len == 4) {
        const o = try it.str(argv[1]);
        if (!eql(o, "-encoding")) return it.fail("bad option \"{s}\": must be -encoding", .{o});
        e_name = try it.str(argv[2]);
    }
    const path = try it.str(argv[argv.len - 1]);
    if (try vfs.gate(it, path, .channels, "couldn't read file")) |h| return sourceText(it, argv, path, try sourceDecode(it, e_name, try vfs.read(it, h, "couldn't read file", path)));
    const rel = (try fsroot.normal(it, path)) orelse return it.failCode("POSIX EACCES {permission denied}", "couldn't read file \"{s}\": permission denied", .{path});
    const fd = switch (try fsroot.openRel(it, rel, .{}, 0)) {
        .fd => |x| x,
        .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(a, "couldn't read file \"{s}\": ", .{path})),
    };
    defer sys.close(fd);
    var text: std.ArrayList(u8) = .empty;
    while (true) {
        try text.ensureUnusedCapacity(a, 16384);
        const room = text.unusedCapacitySlice();
        const got = switch (sys.readFile(fd, room)) {
            .n => |x| x,
            .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(a, "couldn't read file \"{s}\": ", .{path})),
        };
        if (got == 0) break;
        text.items.len += got;
        try it.checkMem();
    }
    return sourceText(it, argv, path, try sourceDecode(it, e_name, text.items));
}

/// The text of the bytes of a script file in the encoding `name`.
fn sourceDecode(it: *Interp, name: []const u8, raw: []const u8) Error![]const u8 {
    if (eql(name, "utf-8") or eql(name, "identity")) return raw;
    const a = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    if (eql(name, "binary") or eql(name, "iso8859-1")) {
        for (raw) |b| try value.appendCodepoint(a, &out, b);
        return out.items;
    }
    const e = (try enc.forChannel(it, name)) orelse return it.failCode(try std.fmt.allocPrint(a, "TCL LOOKUP ENCODING {s}", .{name}), "unknown encoding \"{s}\"", .{name});
    var st: enc.State = .{};
    _ = try enc.toUtf(it, e, &st, raw, true, std.math.maxInt(usize), &out);
    return out.items;
}

/// Runs the text of the file `path` as `source` does. In a direct call of
/// a precise build the script runs in the clean chain (`Interp.evalBody`):
/// the frame keeps the text, the compiled script, and the old script name
/// across the run, so each of them goes in the `keep` list.
fn sourceText(it: *Interp, argv: []const Value, path: []const u8, text: []const u8) Error!Value {
    const a = it.alloc();
    // The ^Z character ends a script, and a byte order mark at the start
    // is not part of it.
    var body = text;
    if (std.mem.startsWith(u8, body, "\xEF\xBB\xBF")) body = body[3..];
    if (std.mem.indexOfScalar(u8, body, 26)) |k| body = body[0..k];
    const saved = it.script_name;
    it.script_name = try a.dupe(u8, path);
    defer it.script_name = saved;
    const script = try it.compile(body);
    const keep = [_]usize{ @intFromPtr(script), @intFromPtr(text.ptr), @intFromPtr(saved.ptr) };
    return it.evalBody(script, argv, &keep) catch |e| {
        if (e == error.TclReturn and it.ret_level <= 1 and it.ret_code == .ok) return it.result;
        if (e == error.TclError and it.in_error) {
            it.error_info.print(a, "\n    (file \"{s}\" line {d})", .{ path, it.proc_line }) catch {};
        }
        return e;
    };
}

/// Puts `chan SUB` in place of the command name in a usage message of a
/// command that `chan SUB` runs, as in Tcl.
fn usageOfChan(it: *Interp, sub: []const u8) Error!void {
    const head = "wrong # args: should be \"";
    const msg = try it.str(it.result);
    if (!std.mem.startsWith(u8, msg, head)) return;
    const rest = msg[head.len..];
    if (std.mem.startsWith(u8, rest, "chan ")) return;
    const end = std.mem.indexOfAny(u8, rest, " \"") orelse return;
    if (end == 0) return;
    // Each form of the usage starts with the name, as in `"read ..." or
    // "read ..."`.
    const a = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, msg, i, rest[0..end])) |k| {
        const after = k + end;
        if (k > 0 and msg[k - 1] == '"' and after < msg.len and (msg[after] == ' ' or msg[after] == '"')) {
            try out.appendSlice(a, msg[i..k]);
            try out.print(a, "chan {s}", .{sub});
        } else try out.appendSlice(a, msg[i..after]);
        i = after;
    }
    try out.appendSlice(a, msg[i..]);
    it.result = .{ .str = out.items };
}

/// The subcommands of `chan`. `isbinary` is in Tcl 9.1 only. A unique
/// prefix names a subcommand, as in an ensemble of Tcl.
/// `create` and `postevent` are in `chanrefl.zig`, and `push` and
/// `pop` in `chanxform.zig`.
const ChanSub = enum { blocked, close, configure, copy, create, eof, event, flush, gets, isbinary, names, pending, pipe, pop, postevent, push, puts, read, seek, tell, truncate };

fn cmdChan(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    return chanSub(it, argv, cmd) catch |e| {
        // Tcl 9 names the argument `channel` in each usage of `chan`.
        if (e == error.TclError and it.tcl9()) {
            const msg = try it.str(it.result);
            if (std.mem.startsWith(u8, msg, "wrong # args: should be \"chan ")) {
                it.result = .{ .str = try std.mem.replaceOwned(u8, it.alloc(), msg, "channelId", "channel") };
            }
        }
        return e;
    };
}

fn chanSub(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("chan subcommand ?arg ...?");
    const word = try it.str(argv[1]);
    const picked = @import("tcl9.zig").pick(it, ChanSub, word, .{ .v9_1 = &.{.isbinary}, .code = "TCL LOOKUP SUBCOMMAND" }) catch |e| {
        if (e == error.TclError) it.error_code = try value.newList(it.alloc(), &.{ .{ .str = "TCL" }, .{ .str = "LOOKUP" }, .{ .str = "SUBCOMMAND" }, .{ .str = word } });
        return e;
    };
    const sub = @tagName(picked);
    const forward = struct {
        fn f(x: *Interp, g: interp.NativeFn, v: []const Value, c: ?*Cmd, name: []const u8) Error!Value {
            return g(x, v[1..], c) catch |e| {
                if (e == error.TclError) try usageOfChan(x, name);
                return e;
            };
        }
    }.f;
    if (eql(sub, "truncate")) return chanTruncate(it, argv);
    if (eql(sub, "create")) return refl_mod.create(it, argv);
    if (eql(sub, "postevent")) return refl_mod.postevent(it, argv);
    if (eql(sub, "push")) return xform_mod.push(it, argv);
    if (eql(sub, "pop")) return xform_mod.pop(it, argv);
    if (eql(sub, "isbinary")) {
        if (argv.len != 3) return it.wrongArgs("chan isbinary channelId");
        const c = try find(it, argv[2]);
        return .{ .int = @intFromBool(c.ext == null and isBinary(c)) };
    }
    if (eql(sub, "close")) return forward(it, cmdClose, argv, cmd, sub);
    if (eql(sub, "configure")) return forward(it, cmdConfigure, argv, cmd, sub);
    if (eql(sub, "copy")) return forward(it, cmdFcopy, argv, cmd, sub);
    if (eql(sub, "eof")) return forward(it, cmdEof, argv, cmd, sub);
    if (eql(sub, "event")) return forward(it, cmdFileevent, argv, cmd, sub);
    if (eql(sub, "blocked")) return forward(it, cmdFblocked, argv, cmd, sub);
    if (eql(sub, "pending")) {
        if (argv.len != 4) return it.wrongArgs("chan pending mode channelId");
        const mode = try it.str(argv[2]);
        const c = try find(it, argv[3]);
        if (c.ext != null) return extCall(it, c, "pending", argv[2..3]);
        if (eql(mode, "input")) return .{ .int = if (c.readable) @intCast(c.rbuf.items.len - c.rpos) else -1 };
        if (eql(mode, "output")) return .{ .int = if (c.writable) @intCast(c.wbuf.items.len) else -1 };
        return it.failCode("TCL LOOKUP INDEX mode", "bad mode \"{s}\": must be input or output", .{mode});
    }
    if (eql(sub, "pipe")) {
        // The space at the end is in the message of Tcl too.
        if (argv.len != 2) return it.wrongArgs("chan pipe ");
        const fds = sys.pipe() orelse return it.fail("couldn't create pipe: chan pipe is not available on this system", .{});
        const r = try adopt(it, "file", fds[0], true, false);
        r.kind = .pipe;
        const w = try adopt(it, "file", fds[1], false, true);
        w.kind = .pipe;
        return value.newList(it.alloc(), &.{ .{ .str = r.name }, .{ .str = w.name } });
    }
    if (eql(sub, "flush")) return forward(it, cmdFlush, argv, cmd, sub);
    if (eql(sub, "gets")) return forward(it, cmdGets, argv, cmd, sub);
    if (eql(sub, "read")) return forward(it, cmdRead, argv, cmd, sub);
    if (eql(sub, "seek")) return forward(it, cmdSeek, argv, cmd, sub);
    if (eql(sub, "tell")) return forward(it, cmdTell, argv, cmd, sub);
    // `chan puts` runs the built-in puts, also when a script replaced the
    // command `puts`, as in Tcl.
    if (eql(sub, "puts")) return forward(it, cmds.cmdPuts, argv, cmd, sub);
    if (eql(sub, "names")) {
        if (argv.len > 3) return it.wrongArgs("chan names ?pattern?");
        var out: std.ArrayList(Value) = .empty;
        for ([_][]const u8{ "stderr", "stdin", "stdout" }) |n| {
            if (it.chans.table.get(n) == null) try out.append(it.alloc(), .{ .str = n });
        }
        for (it.chans.table.keys()) |k| {
            if (k.len > 0 and k[0] == 0) continue;
            if (argv.len == 3 and !cmds.globMatch(try it.str(argv[2]), k, false)) continue;
            try out.append(it.alloc(), .{ .str = k });
        }
        return value.wrapList(it.alloc(), out.items);
    }
    unreachable;
}

/// A channel with no change of its bytes: the binary encoding, the
/// translation `lf` on each open side, and no `-eofchar`.
fn isBinary(c: *const Channel) bool {
    const lf_in = !c.readable or c.input == .lf;
    const lf_out = !c.writable or c.output == .lf;
    return c.binary and c.enc == null and lf_in and lf_out and c.eof_in == 0 and c.eof_out == 0;
}

/// `chan truncate channelId ?length?`: writes the buffered output, then
/// sets the size of the file to `length`, or to the current position.
fn chanTruncate(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len != 3 and argv.len != 4) return it.wrongArgs("chan truncate channelId ?length?");
    const c = try find(it, argv[2]);
    var len: i64 = 0;
    if (argv.len == 4) {
        len = try it.int(argv[3]);
        if (len < 0) return it.fail("cannot truncate to negative length of file", .{});
    }
    const prefix = try std.fmt.allocPrint(it.alloc(), "error during truncate on \"{s}\": ", .{c.name});
    if (c.ext != null or c.mem or c.kind != .file) return fsroot.posixError(it, .INVAL, prefix);
    try flushOut(it, c);
    if (argv.len == 3) len = (try cmdTell(it, &.{ .{ .str = "tell" }, argv[2] }, null)).int;
    return switch (sys.truncate(c.fd, len)) {
        .at => Value.empty,
        .err => |e| fsroot.posixError(it, e, prefix),
    };
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("open", cmdOpen);
    try it.register("close", cmdClose);
    try it.register("read", cmdRead);
    try it.register("gets", cmdGets);
    try it.register("seek", cmdSeek);
    try it.register("tell", cmdTell);
    try it.register("eof", cmdEof);
    try it.register("flush", cmdFlush);
    try it.register("fconfigure", cmdConfigure);
    try it.register("fblocked", cmdFblocked);
    try it.register("fcopy", cmdFcopy);
    try it.register("chan", cmdChan);
    try it.register("source", cmdSource);
    try it.register("encoding", @import("enc.zig").cmdEncoding);
}

test "latin1ToUtf8 gives the UTF-8 of each byte at each length and offset" {
    const a = std.testing.allocator;
    var raw: [300]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(696);
    for (&raw, 0..) |*b, k| b.* = if (k < 100) @intCast(k % 128) else prng.random().int(u8);
    var len: usize = 0;
    while (len <= raw.len) : (len += 7) {
        const got = try latin1ToUtf8(a, raw[0..len]);
        defer a.free(got.ptr[0 .. got.len + 1]);
        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(a);
        for (raw[0..len]) |b| {
            var buf: [2]u8 = undefined;
            const n = try std.unicode.utf8Encode(b, &buf);
            try want.appendSlice(a, buf[0..n]);
        }
        try std.testing.expectEqualSlices(u8, want.items, got);
    }
}

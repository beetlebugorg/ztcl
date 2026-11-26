//! The optional channel commands (capability `channels`).
//!
//! A channel is a file below the root of `fsroot.zig`. Each channel has
//! a read buffer and a write buffer. The translation of line ends and
//! the encoding (`utf-8` or `binary`) apply at these buffers.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const fsroot = @import("fsroot.zig");
const cmds = @import("cmds.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;
const sys = @import("sys.zig");
const proc_ok = @import("proc.zig").supported;
const ProcTree = if (proc_ok) @import("proc.zig").Tree else struct {};
const event = @import("event.zig");

pub const Translation = enum { auto, lf, cr, crlf, binary };

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
    /// True for the master side of a PTY of `ztcl::pty`.
    pty: bool = false,
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
};

pub const State = struct {
    table: std.StringArrayHashMapUnmanaged(*Channel) = .empty,
    next: u32 = 3,
    next_sock: u32 = 0,
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
    var at: usize = 0;
    while (at < c.wbuf.items.len) {
        switch (sys.write(outFd(c), c.wbuf.items[at..])) {
            .n => |n| at += n,
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
    switch (sys.read(c.fd, room)) {
        .n => |n| {
            if (n == 0) {
                c.hit_eof = true;
                return .eof;
            }
            c.rbuf.items.len += n;
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
fn decode(it: *Interp, c: *const Channel, raw: []const u8) Error![]const u8 {
    const a = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        // A run of bytes with no CR, and no high byte in binary mode,
        // goes to the output as it is.
        var j = i;
        if (c.binary) {
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
        if (c.binary and ch >= 0x80) {
            try out.append(a, 0xC0 | (ch >> 6));
            try out.append(a, 0x80 | (ch & 63));
        } else try out.append(a, ch);
    }
    return out.items;
}

fn writeText(it: *Interp, c: *Channel, text: []const u8) Error!void {
    if (!c.writable) return it.fail("channel \"{s}\" wasn't opened for writing", .{c.name});
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
    const line = eql(c.buffering, "line") and std.mem.indexOfScalar(u8, text, '\n') != null;
    if (eql(c.buffering, "none") or c.wbuf.items.len >= 65536 or line) try flushOut(it, c);
}

/// `puts` on a channel of this module. Gives false for an unknown name.
pub fn putsTo(it: *Interp, name: []const u8, text: []const u8, newline: bool) Error!bool {
    const c = it.chans.table.get(name) orelse return false;
    try writeText(it, c, text);
    if (newline) try writeText(it, c, "\n");
    return true;
}

fn parseMode(it: *Interp, text: []const u8) Error!struct { flags: sys.OpenFlags, read: bool, write: bool, append: bool } {
    var f: sys.OpenFlags = .{};
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
            } else if (!eql(m, "NOCTTY") and !eql(m, "NONBLOCK") and !eql(m, "BINARY")) {
                return it.failCode("TCL LOOKUP INDEX flag", "invalid access mode \"{s}\": must be APPEND, BINARY, CREAT, EXCL, NOCTTY, NONBLOCK, RDONLY, RDWR, TRUNC, or WRONLY", .{m});
            }
        }
        if (!r and !w) return it.fail("access mode must include either RDONLY, WRONLY, or RDWR", .{});
    } else {
        var body = text;
        if (std.mem.indexOfScalar(u8, body, 'b')) |k| {
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
    return .{ .flags = f, .read = r, .write = w, .append = ap };
}

fn cmdOpen(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2 or argv.len > 4) return it.wrongArgs("open fileName ?access? ?permissions?");
    const a = it.alloc();
    const path = try it.str(argv[1]);
    // `exec` is absent, so a command pipeline is an error.
    const m = try parseMode(it, if (argv.len >= 3) try it.str(argv[2]) else "r");
    if (path.len > 0 and path[0] == '|') {
        // A command pipeline needs the capability `exec`.
        if (it.capabilities & @intFromEnum(interp.Capability.exec) == 0) return it.fail("couldn't open \"{s}\": command pipelines are not available", .{path});
        if (comptime !proc_ok) return it.fail("couldn't open \"{s}\": exec is not available on this target", .{path});
        return @import("proc.zig").openPipeline(it, path[1..], m.read, m.write);
    }
    var perm: u32 = 0o666;
    if (argv.len == 4) perm = @intCast((try it.int(argv[3])) & 0o777);
    const rel = (try fsroot.normal(it, path)) orelse return it.failCode("POSIX EACCES {permission denied}", "couldn't open \"{s}\": permission denied", .{path});
    const fd = switch (try fsroot.openRel(it, rel, m.flags, perm)) {
        .fd => |x| x,
        .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(a, "couldn't open \"{s}\": ", .{path})),
    };
    const c = try a.create(Channel);
    const name = try std.fmt.allocPrint(a, "file{d}", .{it.chans.number(false)});
    c.* = .{ .name = name, .fd = fd, .readable = m.read, .writable = m.write, .append = m.append };
    try it.chans.table.put(a, name, c);
    return .{ .str = name };
}

fn closeFds(c: *Channel) void {
    if (!c.read_closed or c.wfd < 0) sys.close(c.fd);
    if (c.wfd >= 0 and !c.write_closed) sys.close(c.wfd);
}

fn closeChan(it: *Interp, c: *Channel) Error!void {
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
    closeFds(c);
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
            @import("pty.zig").hangup(it, c);
        } else if (c.pids.len > 0) try @import("proc.zig").reap(it, c);
    }
}

/// Closes all channels when the interpreter ends.
pub fn closeAll(it: *Interp) void {
    for (it.chans.table.values()) |c| {
        flushOut(it, c) catch {};
        closeFds(c);
        if (comptime proc_ok) {
            if (c.pids.len > 0) @import("proc.zig").abandon(c);
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
    if (argv.len != 3 and argv.len != 4) return it.wrongArgs("fileevent channelId event ?script?");
    const ev = try it.str(argv[2]);
    const readable = eql(ev, "readable");
    if (!readable and !eql(ev, "writable")) return it.failCode("TCL LOOKUP INDEX {event name}", "bad event name \"{s}\": must be readable or writable", .{ev});
    const c = try find(it, argv[1]);
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
    return Value.empty;
}

fn cmdFblocked(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("fblocked channelId");
    const c = try find(it, argv[1]);
    if (!c.readable) return it.fail("channel \"{s}\" wasn't opened for reading", .{c.name});
    return .{ .int = @intFromBool(c.blocked) };
}

fn cmdClose(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2 and argv.len != 3) return it.wrongArgs("close channelId ?direction?");
    const c = try find(it, argv[1]);
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
                c.writable = false;
                c.write_closed = true;
                c.on_write = null;
                if (c.kind == .socket) sys.shutdown(c.fd, 1) else if (c.wfd >= 0) sys.close(c.wfd);
            }
            return Value.empty;
        }
    }
    try closeChan(it, c);
    return Value.empty;
}

fn cmdFlush(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("flush channelId");
    const name = try it.str(argv[1]);
    if (it.chans.table.get(name) == null and (eql(name, "stdout") or eql(name, "stderr"))) return Value.empty;
    const c = try find(it, argv[1]);
    if (!c.writable) return it.fail("channel \"{s}\" wasn't opened for writing", .{name});
    try flushOut(it, c);
    return Value.empty;
}

fn cmdEof(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("eof channelId");
    const c = try find(it, argv[1]);
    return .{ .int = @intFromBool(c.at_eof) };
}

fn cmdGets(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2 and argv.len != 3) return it.wrongArgs("gets channelId ?varName?");
    const c = try find(it, argv[1]);
    if (!c.readable) return it.fail("channel \"{s}\" wasn't opened for reading", .{c.name});
    try flushOut(it, c);
    c.blocked = false;
    var scan: usize = c.rpos;
    var end: ?usize = null;
    while (true) {
        var k = scan;
        while (k < c.rbuf.items.len) : (k += 1) {
            const ch = c.rbuf.items[k];
            if (ch == '\n' or (ch == '\r' and (c.input == .cr or c.input == .auto))) {
                end = k;
                break;
            }
            if (ch == '\r' and c.input == .crlf and k + 1 < c.rbuf.items.len and c.rbuf.items[k + 1] == '\n') {
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
        var next = e + 1;
        if (c.rbuf.items[e] == '\r' and next < c.rbuf.items.len and c.rbuf.items[next] == '\n' and c.input != .cr) next += 1;
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
    if (!c.readable) return it.fail("channel \"{s}\" wasn't opened for reading", .{c.name});
    try flushOut(it, c);
    c.blocked = false;
    var want: ?usize = null;
    if (args.len == 2) {
        const n = it.int(args[1]) catch return it.fail("expected non-negative integer but got \"{s}\"", .{try it.str(args[1])});
        if (n < 0) return it.fail("expected non-negative integer but got \"{s}\"", .{try it.str(args[1])});
        want = @intCast(n);
    }
    while (want == null or c.rbuf.items.len - c.rpos < want.?) {
        if (!try fill(it, c)) break;
    }
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
    var text = try decode(it, c, raw);
    if (nonl and text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
    return .{ .str = text };
}

fn cmdSeek(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3 and argv.len != 4) return it.wrongArgs("seek channelId offset ?origin?");
    const c = try find(it, argv[1]);
    const off = try it.int(argv[2]);
    var whence: usize = 0;
    var adjust: i64 = 0;
    if (argv.len == 4) {
        const o = try it.str(argv[3]);
        if (eql(o, "current")) {
            whence = 1;
            adjust = -@as(i64, @intCast(c.rbuf.items.len - c.rpos));
        } else if (eql(o, "end")) {
            whence = 2;
        } else if (!eql(o, "start")) {
            return it.failCode("TCL LOOKUP INDEX origin", "bad origin \"{s}\": must be start, current, or end", .{o});
        }
    }
    try flushOut(it, c);
    switch (sys.seek(c.fd, off + adjust, @intCast(whence))) {
        .at => {},
        .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "error during seek on \"{s}\": ", .{c.name})),
    }
    c.rbuf.clearRetainingCapacity();
    c.rpos = 0;
    c.at_eof = false;
    c.hit_eof = false;
    return Value.empty;
}

fn cmdTell(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("tell channelId");
    const c = try find(it, argv[1]);
    const at: i64 = switch (sys.seek(c.fd, 0, 1)) {
        .at => |x| x,
        .err => return .{ .int = -1 },
    };
    return .{ .int = at - @as(i64, @intCast(c.rbuf.items.len - c.rpos)) + @as(i64, @intCast(c.wbuf.items.len)) };
}

fn parseTranslation(it: *Interp, v: Value) Error!Translation {
    const s = try it.str(v);
    return std.meta.stringToEnum(Translation, s) orelse it.fail("bad value for -translation: must be one of auto, binary, cr, lf, crlf, or platform", .{});
}

fn cmdConfigure(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("fconfigure channelId ?-option value ...?");
    const a = it.alloc();
    const name = try it.str(argv[1]);
    if (it.chans.table.get(name) == null and (eql(name, "stdout") or eql(name, "stderr") or eql(name, "stdin"))) return Value.empty;
    const c = try find(it, argv[1]);
    const opts = argv[2..];
    const get = struct {
        fn f(x: *Interp, ch: *Channel, o: []const u8) Error!?Value {
            if (eql(o, "-blocking")) return .{ .int = @intFromBool(ch.blocking) };
            if (eql(o, "-buffering")) return .{ .str = ch.buffering };
            if (eql(o, "-buffersize")) return .{ .int = ch.buffersize };
            if (eql(o, "-encoding")) return .{ .str = if (ch.binary) "binary" else "utf-8" };
            if (eql(o, "-eofchar")) return Value.empty;
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
    const known = "-blocking, -buffering, -buffersize, -encoding, -eofchar, or -translation";
    if (opts.len == 0) {
        var out: std.ArrayList(Value) = .empty;
        for ([_][]const u8{ "-blocking", "-buffering", "-buffersize", "-encoding", "-eofchar", "-translation" }) |o| {
            try out.append(a, .{ .str = o });
            try out.append(a, (try get(it, c, o)).?);
        }
        if (c.kind == .socket or c.kind == .server) try @import("sock.zig").options(it, c, &out);
        // The list is in the order of Tcl: -translation is last.
        const n = out.items.len;
        if (n > 12) {
            const tr = [2]Value{ out.items[10], out.items[11] };
            std.mem.copyForwards(Value, out.items[10 .. n - 2], out.items[12..n]);
            out.items[n - 2] = tr[0];
            out.items[n - 1] = tr[1];
        }
        return value.wrapList(a, out.items);
    }
    const names = [_][]const u8{ "-blocking", "-buffering", "-buffersize", "-encoding", "-eofchar", "-translation", "-peername", "-sockname", "-error", "-connecting" };
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
        return (try get(it, c, o)) orelse it.fail("bad option \"{s}\": should be one of {s}", .{ o, known });
    }
    if (opts.len % 2 != 0) return it.wrongArgs("fconfigure channelId ?-option value ...?");
    var i: usize = 0;
    while (i < opts.len) : (i += 2) {
        const o = try full(it, opts[i], names[0..6]);
        const v = opts[i + 1];
        if (eql(o, "-blocking")) {
            c.blocking = try @import("expr.zig").truthy(it, v);
            if (!c.connecting) {
                sys.setBlocking(c.fd, c.blocking);
                if (c.wfd >= 0) sys.setBlocking(c.wfd, c.blocking);
            }
        } else if (eql(o, "-buffering")) {
            const b = try it.str(v);
            if (!eql(b, "full") and !eql(b, "line") and !eql(b, "none")) return it.fail("bad value for -buffering: must be one of full, line, or none", .{});
            c.buffering = try a.dupe(u8, b);
        } else if (eql(o, "-buffersize")) {
            c.buffersize = std.math.clamp(try it.int(v), 1, 1 << 20);
        } else if (eql(o, "-encoding")) {
            const e = try it.str(v);
            c.blocked = false;
            if (eql(e, "binary") or eql(e, "iso8859-1")) {
                c.binary = true;
            } else if (eql(e, "utf-8") or eql(e, "identity") or e.len == 0) {
                c.binary = false;
            } else return it.failCode("TCL LOOKUP ENCODING", "unknown encoding \"{s}\"", .{e});
        } else if (eql(o, "-translation")) {
            const l = try it.list(v);
            if (l.len == 0 or l.len > 2) return it.fail("bad value for -translation: must be a one or two element list", .{});
            const x = try parseTranslation(it, l[0]);
            const y = if (l.len == 2) try parseTranslation(it, l[1]) else x;
            if (c.readable) c.input = x;
            if (c.writable) c.output = if (y == .auto) .lf else y;
            if (x == .binary) c.binary = true;
        } else if (!eql(o, "-eofchar")) {
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
    var i: usize = 3;
    while (i + 1 < argv.len) : (i += 2) {
        if (eql(try it.str(argv[i]), "-size")) {
            const n = try it.int(argv[i + 1]);
            if (n >= 0) limit = @intCast(n);
        } else return it.fail("fcopy -command is not available", .{});
    }
    var total: usize = 0;
    while (limit == null or total < limit.?) {
        if (from.rpos >= from.rbuf.items.len and !try fill(it, from)) break;
        var chunk = from.rbuf.items[from.rpos..];
        if (limit) |n| chunk = chunk[0..@min(chunk.len, n - total)];
        try writeText(it, to, try decode(it, from, chunk));
        from.rpos += chunk.len;
        total += chunk.len;
    }
    if (from.hit_eof and from.rpos >= from.rbuf.items.len) from.at_eof = true;
    return .{ .int = @intCast(total) };
}

fn cmdSource(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2 and argv.len != 4) return it.wrongArgs("source ?-encoding name? fileName");
    const a = it.alloc();
    const path = try it.str(argv[argv.len - 1]);
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
    // The ^Z character ends a script.
    var body = text.items;
    if (std.mem.indexOfScalar(u8, body, 26)) |k| body = body[0..k];
    const saved = it.script_name;
    it.script_name = try a.dupe(u8, path);
    defer it.script_name = saved;
    const script = try it.compile(body);
    return it.evalScript(script) catch |e| {
        if (e == error.TclReturn and it.ret_level <= 1 and it.ret_code == .ok) return it.result;
        if (e == error.TclError and it.in_error) {
            it.error_info.print(a, "\n    (file \"{s}\" line {d})", .{ path, it.proc_line }) catch {};
        }
        return e;
    };
}

fn cmdChan(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("chan subcommand ?arg ...?");
    const sub = try it.str(argv[1]);
    const forward = struct {
        fn f(x: *Interp, g: interp.NativeFn, v: []const Value, c: ?*Cmd) Error!Value {
            return g(x, v[1..], c);
        }
    }.f;
    if (eql(sub, "close")) return forward(it, cmdClose, argv, cmd);
    if (eql(sub, "configure")) return forward(it, cmdConfigure, argv, cmd);
    if (eql(sub, "copy")) return forward(it, cmdFcopy, argv, cmd);
    if (eql(sub, "eof")) return forward(it, cmdEof, argv, cmd);
    if (eql(sub, "event")) return forward(it, cmdFileevent, argv, cmd);
    if (eql(sub, "blocked")) return forward(it, cmdFblocked, argv, cmd);
    if (eql(sub, "pending")) {
        if (argv.len != 4) return it.wrongArgs("chan pending mode channelId");
        const mode = try it.str(argv[2]);
        const c = try find(it, argv[3]);
        if (eql(mode, "input")) return .{ .int = if (c.readable) @intCast(c.rbuf.items.len - c.rpos) else -1 };
        if (eql(mode, "output")) return .{ .int = if (c.writable) @intCast(c.wbuf.items.len) else -1 };
        return it.failCode("TCL LOOKUP INDEX mode", "bad mode \"{s}\": must be input or output", .{mode});
    }
    if (eql(sub, "flush")) return forward(it, cmdFlush, argv, cmd);
    if (eql(sub, "gets")) return forward(it, cmdGets, argv, cmd);
    if (eql(sub, "read")) return forward(it, cmdRead, argv, cmd);
    if (eql(sub, "seek")) return forward(it, cmdSeek, argv, cmd);
    if (eql(sub, "tell")) return forward(it, cmdTell, argv, cmd);
    if (eql(sub, "puts")) {
        const words = try it.alloc().dupe(Value, argv[1..]);
        words[0] = .{ .str = "puts" };
        return it.callWords(words);
    }
    if (eql(sub, "names")) {
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
    return it.failCode("TCL LOOKUP INDEX subcommand", "unknown or ambiguous subcommand \"{s}\": must be close, configure, copy, eof, flush, gets, names, puts, read, seek, or tell", .{sub});
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

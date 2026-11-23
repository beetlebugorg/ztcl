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
const linux = std.os.linux;

const Translation = enum { auto, lf, cr, crlf, binary };

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
};

pub const State = struct {
    table: std.StringArrayHashMapUnmanaged(*Channel) = .empty,
    next: u32 = 3,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn find(it: *Interp, v: Value) Error!*Channel {
    const name = try it.str(v);
    return it.chans.table.get(name) orelse it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP CHANNEL {s}", .{name}), "can not find channel named \"{s}\"", .{name});
}

fn flushOut(it: *Interp, c: *Channel) Error!void {
    var at: usize = 0;
    while (at < c.wbuf.items.len) {
        const rc = linux.write(c.fd, c.wbuf.items[at..].ptr, c.wbuf.items.len - at);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) {
            c.wbuf.clearRetainingCapacity();
            return fsroot.posixError(it, e, "error flushing channel: ");
        }
        at += rc;
    }
    c.wbuf.clearRetainingCapacity();
}

/// Reads more bytes. Gives false at the end of the file.
fn fill(it: *Interp, c: *Channel) Error!bool {
    if (c.rpos > 0) {
        const rest = c.rbuf.items.len - c.rpos;
        std.mem.copyForwards(u8, c.rbuf.items[0..rest], c.rbuf.items[c.rpos..]);
        c.rbuf.items.len = rest;
        c.rpos = 0;
    }
    try c.rbuf.ensureUnusedCapacity(it.alloc(), 16384);
    const room = c.rbuf.unusedCapacitySlice();
    while (true) {
        const rc = linux.read(c.fd, room.ptr, room.len);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return fsroot.posixError(it, e, "error reading: ");
        if (rc == 0) {
            c.hit_eof = true;
            return false;
        }
        c.rbuf.items.len += rc;
        return true;
    }
}

/// The text of input bytes after the translation and the encoding.
fn decode(it: *Interp, c: *const Channel, raw: []const u8) Error![]const u8 {
    const a = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
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

fn parseMode(it: *Interp, text: []const u8) Error!struct { flags: linux.O, read: bool, write: bool, append: bool } {
    var f: linux.O = .{};
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
                f.APPEND = true;
            } else if (eql(m, "CREAT")) {
                f.CREAT = true;
            } else if (eql(m, "EXCL")) {
                f.EXCL = true;
            } else if (eql(m, "TRUNC")) {
                f.TRUNC = true;
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
            f.CREAT = true;
            f.TRUNC = true;
        } else if (eql(body, "w+")) {
            r = true;
            w = true;
            f.CREAT = true;
            f.TRUNC = true;
        } else if (eql(body, "a")) {
            w = true;
            ap = true;
            f.CREAT = true;
            f.APPEND = true;
        } else if (eql(body, "a+")) {
            r = true;
            w = true;
            ap = true;
            f.CREAT = true;
            f.APPEND = true;
        } else return it.fail("illegal access mode \"{s}\"", .{text});
    }
    f.ACCMODE = if (r and w) .RDWR else if (w) .WRONLY else .RDONLY;
    return .{ .flags = f, .read = r, .write = w, .append = ap };
}

fn cmdOpen(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2 or argv.len > 4) return it.wrongArgs("open fileName ?access? ?permissions?");
    const a = it.alloc();
    const path = try it.str(argv[1]);
    // `exec` is absent, so a command pipeline is an error.
    if (path.len > 0 and path[0] == '|') return it.fail("couldn't open \"{s}\": command pipelines are not available", .{path});
    const m = try parseMode(it, if (argv.len >= 3) try it.str(argv[2]) else "r");
    var perm: u32 = 0o666;
    if (argv.len == 4) perm = @intCast((try it.int(argv[3])) & 0o777);
    const rel = (try fsroot.normal(it, path)) orelse return it.failCode("POSIX EACCES {permission denied}", "couldn't open \"{s}\": permission denied", .{path});
    const fd = switch (try fsroot.openRel(it, rel, m.flags, perm)) {
        .fd => |x| x,
        .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(a, "couldn't open \"{s}\": ", .{path})),
    };
    const c = try a.create(Channel);
    const name = try std.fmt.allocPrint(a, "file{d}", .{it.chans.next});
    it.chans.next += 1;
    c.* = .{ .name = name, .fd = fd, .readable = m.read, .writable = m.write, .append = m.append };
    try it.chans.table.put(a, name, c);
    return .{ .str = name };
}

fn closeChan(it: *Interp, c: *Channel) Error!void {
    const r = flushOut(it, c);
    _ = linux.close(c.fd);
    _ = it.chans.table.orderedRemove(c.name);
    return r;
}

/// Closes all channels when the interpreter ends.
pub fn closeAll(it: *Interp) void {
    for (it.chans.table.values()) |c| {
        flushOut(it, c) catch {};
        _ = linux.close(c.fd);
    }
    it.chans.table = .empty;
}

fn cmdClose(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2 and argv.len != 3) return it.wrongArgs("close channelId ?direction?");
    try closeChan(it, try find(it, argv[1]));
    return Value.empty;
}

fn cmdFlush(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("flush channelId");
    const name = try it.str(argv[1]);
    if (eql(name, "stdout") or eql(name, "stderr")) return Value.empty;
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
    } else c.at_eof = true;
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
    const rc = linux.lseek(c.fd, off + adjust, whence);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "error during seek on \"{s}\": ", .{c.name}));
    c.rbuf.clearRetainingCapacity();
    c.rpos = 0;
    c.at_eof = false;
    c.hit_eof = false;
    return Value.empty;
}

fn cmdTell(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 2) return it.wrongArgs("tell channelId");
    const c = try find(it, argv[1]);
    const rc = linux.lseek(c.fd, 0, 1);
    if (linux.errno(rc) != .SUCCESS) return .{ .int = -1 };
    const at: i64 = @intCast(rc);
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
    if (eql(name, "stdout") or eql(name, "stderr") or eql(name, "stdin")) return Value.empty;
    const c = try find(it, argv[1]);
    const opts = argv[2..];
    const get = struct {
        fn f(x: *Interp, ch: *Channel, o: []const u8) Error!?Value {
            if (eql(o, "-blocking")) return .{ .int = @intFromBool(ch.blocking) };
            if (eql(o, "-buffering")) return .{ .str = ch.buffering };
            if (eql(o, "-buffersize")) return .{ .int = ch.buffersize };
            if (eql(o, "-encoding")) return .{ .str = if (ch.binary) "binary" else "utf-8" };
            if (eql(o, "-eofchar")) return Value.empty;
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
        return value.wrapList(a, out.items);
    }
    if (opts.len == 1) {
        const o = try it.str(opts[0]);
        return (try get(it, c, o)) orelse it.fail("bad option \"{s}\": should be one of {s}", .{ o, known });
    }
    if (opts.len % 2 != 0) return it.wrongArgs("fconfigure channelId ?-option value ...?");
    var i: usize = 0;
    while (i < opts.len) : (i += 2) {
        const o = try it.str(opts[i]);
        const v = opts[i + 1];
        if (eql(o, "-blocking")) {
            c.blocking = try @import("expr.zig").truthy(it, v);
        } else if (eql(o, "-buffering")) {
            const b = try it.str(v);
            if (!eql(b, "full") and !eql(b, "line") and !eql(b, "none")) return it.fail("bad value for -buffering: must be one of full, line, or none", .{});
            c.buffering = try a.dupe(u8, b);
        } else if (eql(o, "-buffersize")) {
            c.buffersize = std.math.clamp(try it.int(v), 1, 1 << 20);
        } else if (eql(o, "-encoding")) {
            const e = try it.str(v);
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
    defer _ = linux.close(fd);
    var text: std.ArrayList(u8) = .empty;
    while (true) {
        try text.ensureUnusedCapacity(a, 16384);
        const room = text.unusedCapacitySlice();
        const rc = linux.read(fd, room.ptr, room.len);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return fsroot.posixError(it, e, try std.fmt.allocPrint(a, "couldn't read file \"{s}\": ", .{path}));
        if (rc == 0) break;
        text.items.len += rc;
        if (it.overLimit()) return it.fail("the script used too much memory", .{});
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
        for ([_][]const u8{ "stderr", "stdin", "stdout" }) |n| try out.append(it.alloc(), .{ .str = n });
        for (it.chans.table.keys()) |k| {
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
    try it.register("fcopy", cmdFcopy);
    try it.register("chan", cmdChan);
    try it.register("source", cmdSource);
}

//! The module `ztcl::tls`: `ztcl::tls socket`, a TLS 1.3 client
//! channel on a TCP connection of `socket`.
//!
//! The command opens the TCP connection with the code of the `socket`
//! command, so the network policy of the embedder applies to it. Then it
//! runs the handshake of `client.zig` on the descriptor, and puts a
//! `chan.Filter` on the channel. The filter reads whole records into
//! `raw`, opens them with the client, and gives the plaintext to the
//! read buffer of the channel. A write of the channel goes out in
//! sealed records. `close` sends close_notify.
//!
//! The channel blocks. The trust anchors are the store of the system
//! (`roots.zig`), which loads once for each process, or the PEM text of
//! `-cadata`. The dates of the certificates are checked against the
//! clock of the host.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("../interp.zig");
const value = @import("../value.zig");
const mods = @import("../modules.zig");
const chan = @import("../chan.zig");
const sock = @import("../sock.zig");
const sys = @import("../sys.zig");
const client = @import("client.zig");
const record = @import("record.zig");
const roots = @import("roots.zig");
const x509 = @import("x509.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const Cmd = interp.Cmd;

const modules_list = [_]mods.Module{.{
    .name = "ztcl::tls",
    .version = "0.1",
    .needs = @backingInt(interp.Capability.socket) | @backingInt(interp.Capability.channels),
    .install = install,
    .script =
    \\namespace eval ::ztcl::tls {
    \\    namespace export socket
    \\    namespace ensemble create
    \\}
    ,
}};

pub const modules: []const mods.Module = &modules_list;

fn install(it: *Interp) Error!void {
    try it.register("ztcl::tls::socket", cmdSocket);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// The store of the system, loaded at the first use.
var system_lock: std.atomic.Mutex = .unlocked;
var system: ?roots.Roots = null;

fn systemRoots() []const x509.Cert {
    while (!system_lock.tryLock()) {}
    defer system_lock.unlock();
    if (system == null) {
        system = roots.Roots.init(std.heap.page_allocator);
        _ = system.?.addSystem(io()) catch 0;
    }
    return system.?.slice();
}

/// The state of one TLS channel.
const Tls = struct {
    filter: chan.Filter = .{ .read = read, .write = write, .closeWrite = closeWrite, .deinit = deinit },
    c: client.Client,
    /// The bytes from the peer that are not a whole record yet.
    raw: [record.max_record]u8 = undefined,
    raw_len: usize = 0,
    /// Plaintext that did not fit in the read buffer of the channel.
    pending: []const u8 = "",
    out: [2 * record.max_record]u8 = undefined,
    /// The memory of the options: the host and the roots of `-cadata`.
    arena: std.heap.ArenaAllocator,
    alpn: [8][]const u8 = undefined,
    eof: bool = false,

    fn of(f: *chan.Filter) *Tls {
        return @alignCast(@fieldParentPtr("filter", f));
    }

    fn ioError(it: *Interp, what: []const u8, f: sys.Fail) Error {
        return it.failCode(try std.fmt.allocPrint(it.alloc(), "POSIX {s} {{{s}}}", .{ f.name, f.text }), "{s}{s}", .{ what, f.text });
    }

    fn sendAll(it: *Interp, fd: i32, bytes: []const u8) Error!void {
        var at: usize = 0;
        while (at < bytes.len) {
            switch (sys.write(fd, bytes[at..])) {
                .n => |n| at += n,
                .again => {
                    var w = [_]sys.Want{.{ .fd = fd, .write = true }};
                    sys.poll(it.alloc(), &w, -1);
                },
                .err => |f| return ioError(it, "error writing TLS channel: ", f),
            }
        }
    }

    /// The error of a failed TLS step. The error code is `ZTCL TLS
    /// CERTIFICATE reason`, `ZTCL TLS ALERT name` for an alert of the
    /// server, or `ZTCL TLS error alert` for an error of the client.
    fn tlsError(t: *Tls, it: *Interp, e: anyerror) Error {
        const a = it.alloc();
        if (t.c.chain_error) |ce| {
            const why = switch (ce) {
                error.UnknownIssuer => "no trust anchor signs the chain",
                error.Expired => "a certificate of the chain is expired or not valid yet",
                error.HostName => "the certificate is not for the host name",
                error.BadUsage => "the certificate is not for a TLS server",
                else => "the chain does not pass the checks",
            };
            return it.failCode(try std.fmt.allocPrint(a, "ZTCL TLS CERTIFICATE {t}", .{ce}), "TLS handshake failed: {s} ({t})", .{ why, ce });
        }
        if (t.c.got_alert) |code| {
            const name = if (std.enums.fromInt(record.Alert, code)) |al| @tagName(al) else "unknown";
            return it.failCode(try std.fmt.allocPrint(a, "ZTCL TLS ALERT {s}", .{name}), "TLS error: the server sent the alert {s} ({d})", .{ name, code });
        }
        const alert = if (t.c.sent_alert) |al| @tagName(al) else "none";
        return it.failCode(try std.fmt.allocPrint(a, "ZTCL TLS {t} {s}", .{ e, alert }), "TLS error: {t} (alert {s})", .{ e, alert });
    }

    /// Reads to one whole record in `raw`. Gives false at the end of
    /// the TCP stream.
    fn fillRecord(t: *Tls, it: *Interp, fd: i32) Error!bool {
        while (true) {
            if (t.raw_len >= record.header_len) {
                const len = std.mem.readInt(u16, t.raw[3..5], .big);
                if (len > record.max_ciphertext) return t.tlsError(it, error.RecordOverflow);
                if (t.raw_len >= record.header_len + len) return true;
            }
            switch (sys.read(fd, t.raw[t.raw_len..])) {
                .n => |n| {
                    if (n == 0) return false;
                    t.raw_len += n;
                },
                .again => {
                    var w = [_]sys.Want{.{ .fd = fd, .read = true }};
                    sys.poll(it.alloc(), &w, -1);
                },
                .err => |f| {
                    if (eql(f.name, "ECONNRESET")) return false;
                    return ioError(it, "error reading TLS channel: ", f);
                },
            }
        }
    }

    /// Handles the record at the start of `raw`, sends the answer, and
    /// drops the record.
    fn step(t: *Tls, it: *Interp, fd: i32) Error!client.Event {
        const len = record.header_len + std.mem.readInt(u16, t.raw[3..5], .big);
        var w: std.Io.Writer = .fixed(&t.out);
        const ev = t.c.handleRecord(&w, t.raw[0..len]);
        try sendAll(it, fd, w.buffered());
        const got = ev catch |e| return t.tlsError(it, e);
        // The data of the event is in the client, so the record bytes
        // can move.
        std.mem.copyForwards(u8, t.raw[0 .. t.raw_len - len], t.raw[len..t.raw_len]);
        t.raw_len -= len;
        return got;
    }

    fn handshake(t: *Tls, it: *Interp, fd: i32) Error!void {
        var w: std.Io.Writer = .fixed(&t.out);
        t.c.hello(&w) catch |e| return t.tlsError(it, e);
        try sendAll(it, fd, w.buffered());
        while (true) {
            if (!try t.fillRecord(it, fd)) return t.tlsError(it, error.EndOfStream);
            switch (try t.step(it, fd)) {
                .handshake_done => return,
                .closed => return t.tlsError(it, error.EndOfStream),
                .data => |d| t.pending = d,
                .none => {},
            }
        }
    }

    fn read(f: *chan.Filter, it: *Interp, fd: i32, buf: []u8) Error!usize {
        const t = of(f);
        while (t.pending.len == 0) {
            if (t.eof) return 0;
            if (!try t.fillRecord(it, fd)) {
                // A TCP end with no close_notify reads as the end too,
                // as many servers close with no alert.
                t.eof = true;
                return 0;
            }
            switch (try t.step(it, fd)) {
                .data => |d| t.pending = d,
                .closed => t.eof = true,
                else => {},
            }
        }
        const n = @min(buf.len, t.pending.len);
        @memcpy(buf[0..n], t.pending[0..n]);
        t.pending = t.pending[n..];
        return n;
    }

    fn write(f: *chan.Filter, it: *Interp, fd: i32, data: []const u8) Error!void {
        const t = of(f);
        var rest = data;
        while (rest.len > 0) {
            const n = @min(rest.len, record.max_plaintext);
            var w: std.Io.Writer = .fixed(&t.out);
            t.c.write(&w, rest[0..n]) catch |e| return t.tlsError(it, e);
            try sendAll(it, fd, w.buffered());
            rest = rest[n..];
        }
    }

    fn closeWrite(f: *chan.Filter, it: *Interp, fd: i32) void {
        const t = of(f);
        var w: std.Io.Writer = .fixed(&t.out);
        t.c.close(&w) catch return;
        sendAll(it, fd, w.buffered()) catch {};
    }

    fn deinit(f: *chan.Filter, it: *Interp) void {
        const t = of(f);
        t.arena.deinit();
        it.alloc().destroy(t);
    }
};

const usage = "ztcl::tls socket ?-servername name? ?-alpn protocols? ?-cadata pem? ?-verify boolean? host port";

fn cmdSocket(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var servername: ?[]const u8 = null;
    var alpn: []const Value = &.{};
    var cadata: ?[]const u8 = null;
    var verify = true;
    var i: usize = 1;
    while (i + 2 < argv.len) : (i += 2) {
        const o = try it.str(argv[i]);
        const v = argv[i + 1];
        if (eql(o, "-servername")) {
            servername = try it.str(v);
        } else if (eql(o, "-alpn")) {
            alpn = try it.list(v);
        } else if (eql(o, "-cadata")) {
            cadata = try it.str(v);
        } else if (eql(o, "-verify")) {
            verify = try @import("../expr.zig").truthy(it, v);
        } else return it.fail("bad option \"{s}\": must be -alpn, -cadata, -servername, or -verify", .{o});
    }
    if (argv.len - i != 2) return it.wrongArgs(usage);
    const t0 = try it.alloc().create(Tls);
    t0.* = .{ .c = undefined, .arena = .init(std.heap.page_allocator) };
    var owned = true;
    defer if (owned) Tls.deinit(&t0.filter, it);
    const a = t0.arena.allocator();
    const host = try a.dupe(u8, servername orelse try it.str(argv[i]));
    if (alpn.len > t0.alpn.len) return it.fail("-alpn has more than {d} protocols", .{t0.alpn.len});
    for (alpn, 0..) |p, k| {
        const s = try it.str(p);
        if (s.len == 0 or s.len > 255) return it.fail("bad ALPN protocol \"{s}\"", .{s});
        t0.alpn[k] = try a.dupe(u8, s);
    }
    var anchors: []const x509.Cert = &.{};
    if (cadata) |text| {
        var store = roots.Roots.init(a);
        const n = store.addPem(text) catch 0;
        if (n == 0) return it.fail("-cadata has no certificate", .{});
        anchors = store.slice();
    } else if (verify) anchors = systemRoots();
    const opts: client.Options = .{
        .host = host,
        .roots = anchors,
        .now = std.Io.Clock.real.now(io()).toSeconds(),
        .verify_chain = verify,
        .alpn = t0.alpn[0..alpn.len],
    };
    t0.c.init(opts, .fill(io()));
    const tcp = [_]Value{ .{ .str = "socket" }, argv[i], argv[i + 1] };
    const name = try it.str(try sock.cmdSocket(it, &tcp, null));
    const c = chan.lookup(it, name).?;
    t0.handshake(it, c.fd) catch |e| {
        chan.closeChan(it, c) catch {};
        return e;
    };
    c.filter = &t0.filter;
    owned = false;
    return .{ .str = c.name };
}

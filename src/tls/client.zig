//! The TLS 1.3 client handshake (RFC 8446 sections 4 and 6), with no
//! I/O of its own.
//!
//! `hello` writes the ClientHello record. `handleRecord` reads each
//! whole record from the server, writes the records of the answer, and
//! gives an `Event`. `write` seals application data, and `close` sends
//! `close_notify`. `Conn` runs the same steps on a `std.Io.Reader` and
//! a `std.Io.Writer`.
//!
//! The client offers the groups, the suites, and the signature schemes
//! of `Options`, a key share for each group of `key_shares`, and ALPN.
//! It handles one HelloRetryRequest. It checks the chain and the host
//! name with `chain.verify`, the CertificateVerify with `crypto.verify`,
//! and the Finished with `std.crypto.timing_safe.eql`. A request for a
//! client certificate gets an empty Certificate message. PSK and 0-RTT
//! are later work (task 20), and a NewSessionTicket is read and left.
//!
//! In the middlebox compatibility mode of section D.4 (`compat`, on by
//! default), the ClientHello has a session ID of 32 random bytes, and
//! the client sends one change_cipher_spec record before its second
//! flight. The client skips a change_cipher_spec record of the server
//! from the ServerHello to the Finished.
//!
//! Each error of the server ends the connection with the alert of the
//! RFC. The alert goes out before `handleRecord` gives the error.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const record = @import("record.zig");
const schedule = @import("schedule.zig");
const tcrypto = @import("crypto.zig");
const msg = @import("messages.zig");
const x509 = @import("x509.zig");
const chain = @import("chain.zig");

const Writer = std.Io.Writer;
const Suite = record.Suite;
const Group = tcrypto.Group;
const Scheme = tcrypto.Scheme;
const Alert = record.Alert;
const Ext = msg.ExtType;

pub const Error = error{
    /// The connection ended with an alert of the client.
    AlertSent,
    /// The server sent a fatal alert.
    AlertReceived,
    /// The output writer failed.
    WriteFailed,
    /// The state of the client does not allow the call.
    BadState,
    NoSpace,
};

/// The extensions of the ClientHello, in the order of the list.
pub const HelloExt = union(enum) {
    server_name,
    supported_groups,
    signature_algorithms,
    key_share,
    supported_versions,
    psk_key_exchange_modes,
    alpn,
    /// The cookie of a HelloRetryRequest. A layout with no `cookie` puts
    /// it at the end.
    cookie,
    /// The padding of RFC 7685, last in the layout: a ClientHello of 256
    /// to 511 bytes grows to 512 bytes.
    padding,
    /// An extension with fixed contents, for the RFC 8448 tests.
    raw: struct { type: u16, body: []const u8 },
};

pub const default_layout = [_]HelloExt{ .server_name, .supported_versions, .supported_groups, .key_share, .signature_algorithms, .psk_key_exchange_modes, .alpn };

pub const default_suites = [_]Suite{ .aes_128_gcm_sha256, .aes_256_gcm_sha384, .chacha20_poly1305_sha256 };

pub const default_schemes = [_]Scheme{
    .ecdsa_secp256r1_sha256,
    .ecdsa_secp384r1_sha384,
    .ed25519,
    .rsa_pss_rsae_sha256,
    .rsa_pss_rsae_sha384,
    .rsa_pss_rsae_sha512,
    .rsa_pkcs1_sha256,
    .rsa_pkcs1_sha384,
    .rsa_pkcs1_sha512,
};

pub const Options = struct {
    /// The DNS name for SNI and for the check of the leaf, or an IP
    /// address in text for the check only.
    host: ?[]const u8 = null,
    roots: []const x509.Cert = &.{},
    /// Seconds since 1970, for the dates of the certificates.
    now: i64 = 0,
    /// Check the chain and the host name. The CertificateVerify is
    /// checked always.
    verify_chain: bool = true,
    alpn: []const []const u8 = &.{},
    suites: []const Suite = &default_suites,
    groups: []const Group = &.{ .x25519, .secp256r1, .secp384r1 },
    /// The groups of the first key shares, a subset of `groups`.
    key_shares: []const Group = &.{.x25519},
    schemes: []const Scheme = &default_schemes,
    layout: []const HelloExt = &default_layout,
    compat: bool = true,
    /// The tests of RFC 8448 skip the chain and the signature, because
    /// the key of the RFC has 1024 bits. Only a test build reads it.
    test_skip_signature: bool = false,
};

/// The random bytes of a connection.
pub const Entropy = struct {
    random: [32]u8,
    session_id: [32]u8,
    x25519: [32]u8,
    p256: [32]u8,
    p384: [48]u8,

    pub fn fill(io: std.Io) Entropy {
        var e: Entropy = undefined;
        io.random(std.mem.asBytes(&e));
        return e;
    }
};

pub const Event = union(enum) {
    none,
    handshake_done,
    /// Application data, valid to the next call.
    data: []const u8,
    /// The server sent close_notify.
    closed,
};

const State = enum { start, wait_sh, wait_sh2, wait_ee, wait_cert_cr, wait_cert, wait_cv, wait_finished, connected, closed, failed };

pub const Kind = enum { sha256, sha384 };

pub fn Sched(comptime k: Kind) type {
    return if (k == .sha256) schedule.Sha256 else schedule.Sha384;
}

pub const Secret = struct {
    b: [48]u8 = @splat(0),
    n: usize = 0,

    pub fn slice(s: *const Secret) []const u8 {
        return s.b[0..s.n];
    }

    pub fn of(a: anytype) Secret {
        var s: Secret = .{ .n = a.len };
        @memcpy(s.b[0..a.len], &a);
        return s;
    }

    pub fn arr(s: *const Secret, comptime n: usize) [n]u8 {
        return s.b[0..n].*;
    }
};

pub const Transcript = union(enum) {
    none,
    sha256: std.crypto.hash.sha2.Sha256,
    sha384: std.crypto.hash.sha2.Sha384,

    pub fn add(t: *Transcript, b: []const u8) void {
        switch (t.*) {
            .none => unreachable,
            inline else => |*h| h.update(b),
        }
    }

    pub fn current(t: *const Transcript) Secret {
        switch (t.*) {
            .none => unreachable,
            inline else => |h| {
                var c = h;
                return Secret.of(c.finalResult());
            },
        }
    }
};

pub const hrr_random = blk: {
    @setEvalBranchQuota(10_000);
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("HelloRetryRequest", &h, .{});
    break :blk h;
};

pub const Client = struct {
    opts: Options,
    ent: Entropy,
    state: State = .start,
    hrr_done: bool = false,
    ccs_sent: bool = false,
    write_closed: bool = false,
    /// The alert of the last error of the client.
    sent_alert: ?Alert = null,
    /// The fatal alert of the server, as its code.
    got_alert: ?u8 = null,
    /// The error of `chain.verify`, for the error text of a caller.
    chain_error: ?chain.Error = null,
    /// The group of the HelloRetryRequest.
    hrr_group: ?Group = null,
    suite: Suite = .aes_128_gcm_sha256,
    kind: Kind = .sha256,
    transcript: Transcript = .none,
    /// The first ClientHello, kept to the ServerHello.
    ch1: [2048]u8 = undefined,
    ch1_len: usize = 0,
    cookie: [512]u8 = undefined,
    cookie_len: usize = 0,
    hs_secret: Secret = .{},
    c_hs: Secret = .{},
    s_hs: Secret = .{},
    res_master: Secret = .{},
    read: ?record.Protection = null,
    write_p: ?record.Protection = null,
    /// The protection of the next flight of the client.
    cert_requested: bool = false,
    cr_context: [255]u8 = undefined,
    cr_context_len: u8 = 0,
    leaf_kind: tcrypto.KeyKind = .rsa,
    leaf_key: [600]u8 = undefined,
    leaf_key_len: usize = 0,
    alpn: [255]u8 = undefined,
    alpn_len: u8 = 0,
    asm_: msg.Assembler = .{},
    plain: [record.max_ciphertext]u8 = undefined,
    out: [record.max_record]u8 = undefined,

    pub fn init(c: *Client, opts: Options, ent: Entropy) void {
        c.* = .{ .opts = opts, .ent = ent };
    }

    /// The protocol of ALPN, or null.
    pub fn protocol(c: *const Client) ?[]const u8 {
        return if (c.alpn_len > 0) c.alpn[0..c.alpn_len] else null;
    }

    pub fn negotiatedSuite(c: *const Client) Suite {
        return c.suite;
    }

    /// Writes the ClientHello record.
    pub fn hello(c: *Client, w: *Writer) Error!void {
        if (c.state != .start) return error.BadState;
        const ch = try c.buildHello(&c.ch1, null);
        c.ch1_len = ch.len;
        try c.sendPlain(w, .handshake, 0x0301, ch);
        c.state = .wait_sh;
    }

    fn privateOf(c: *const Client, g: Group) []const u8 {
        return switch (g) {
            .x25519 => &c.ent.x25519,
            .secp256r1 => &c.ent.p256,
            .secp384r1 => &c.ent.p384,
            _ => "",
        };
    }

    fn buildHello(c: *Client, buf: []u8, only: ?Group) Error![]const u8 {
        var b = msg.Builder.init(buf);
        b.int(u8, 1) catch return error.NoSpace;
        b.begin(3) catch return error.NoSpace;
        b.int(u16, 0x0303) catch return error.NoSpace;
        b.put(&c.ent.random) catch return error.NoSpace;
        b.vec(1, if (c.opts.compat) &c.ent.session_id else "") catch return error.NoSpace;
        b.begin(2) catch return error.NoSpace;
        for (c.opts.suites) |s| b.int(u16, @backingInt(s)) catch return error.NoSpace;
        b.finish() catch return error.NoSpace;
        b.vec(1, &.{0}) catch return error.NoSpace;
        b.begin(2) catch return error.NoSpace;
        var has_cookie = false;
        for (c.opts.layout) |e| {
            if (e == .cookie) has_cookie = true;
            c.helloExt(&b, e, only) catch return error.NoSpace;
        }
        if (!has_cookie) c.helloExt(&b, .cookie, only) catch return error.NoSpace;
        if (c.opts.layout.len > 0 and c.opts.layout[c.opts.layout.len - 1] == .padding and b.len + 4 >= 256 and b.len + 4 < 512) {
            b.int(u16, 21) catch return error.NoSpace;
            b.begin(2) catch return error.NoSpace;
            while (b.len < 512) b.int(u8, 0) catch return error.NoSpace;
            b.finish() catch return error.NoSpace;
        }
        b.finish() catch return error.NoSpace;
        b.finish() catch return error.NoSpace;
        return b.slice();
    }

    fn helloExt(c: *Client, b: *msg.Builder, e: HelloExt, only: ?Group) msg.Error!void {
        switch (e) {
            .server_name => {
                const h = c.opts.host orelse return;
                if (isIp(h)) return;
                try b.int(u16, Ext.server_name);
                try b.begin(2);
                try b.begin(2);
                try b.int(u8, 0);
                try b.vec(2, h);
                try b.finish();
                try b.finish();
            },
            .supported_groups => {
                try b.int(u16, Ext.supported_groups);
                try b.begin(2);
                try b.begin(2);
                for (c.opts.groups) |g| try b.int(u16, @backingInt(g));
                try b.finish();
                try b.finish();
            },
            .signature_algorithms => {
                try b.int(u16, Ext.signature_algorithms);
                try b.begin(2);
                try b.begin(2);
                for (c.opts.schemes) |s| try b.int(u16, @backingInt(s));
                try b.finish();
                try b.finish();
            },
            .key_share => {
                try b.int(u16, Ext.key_share);
                try b.begin(2);
                try b.begin(2);
                const list: []const Group = if (only) |g| &.{g} else c.opts.key_shares;
                for (list) |g| {
                    var pk: [97]u8 = undefined;
                    const p = tcrypto.publicKey(g, c.privateOf(g), &pk) catch continue;
                    try b.int(u16, @backingInt(g));
                    try b.vec(2, p);
                }
                try b.finish();
                try b.finish();
            },
            .supported_versions => {
                try b.int(u16, Ext.supported_versions);
                try b.vec(2, &.{ 2, 3, 4 });
            },
            .psk_key_exchange_modes => {
                try b.int(u16, Ext.psk_key_exchange_modes);
                try b.vec(2, &.{ 1, 1 });
            },
            .alpn => {
                if (c.opts.alpn.len == 0) return;
                try b.int(u16, Ext.alpn);
                try b.begin(2);
                try b.begin(2);
                for (c.opts.alpn) |p| try b.vec(1, p);
                try b.finish();
                try b.finish();
            },
            .cookie => {
                if (c.cookie_len == 0) return;
                try b.int(u16, Ext.cookie);
                try b.begin(2);
                try b.vec(2, c.cookie[0..c.cookie_len]);
                try b.finish();
            },
            .padding => {},
            .raw => |r| {
                try b.int(u16, r.type);
                try b.vec(2, r.body);
            },
        }
    }

    fn sendPlain(c: *Client, w: *Writer, ct: record.ContentType, version: u16, data: []const u8) Error!void {
        const rec = record.writePlain(&c.out, ct, version, data) catch return error.NoSpace;
        w.writeAll(rec) catch return error.WriteFailed;
    }

    fn sendSealed(c: *Client, w: *Writer, ct: record.ContentType, data: []const u8) Error!void {
        const p = &(c.write_p orelse return error.BadState);
        const rec = p.seal(&c.out, ct, data, 0) catch return error.NoSpace;
        w.writeAll(rec) catch return error.WriteFailed;
    }

    fn sendCcs(c: *Client, w: *Writer) Error!void {
        if (!c.opts.compat or c.ccs_sent) return;
        c.ccs_sent = true;
        try c.sendPlain(w, .change_cipher_spec, 0x0303, &.{1});
    }

    /// Sends the alert and gives `error.AlertSent`.
    fn fail(c: *Client, w: *Writer, a: Alert) Error {
        c.sent_alert = a;
        const body = [2]u8{ 2, @backingInt(a) };
        if (c.write_p != null) c.sendSealed(w, .alert, &body) catch {} else c.sendPlain(w, .alert, 0x0303, &body) catch {};
        c.state = .failed;
        return error.AlertSent;
    }

    /// Sends the fatal alert `a` for a record that the caller found
    /// wrong before `handleRecord`, and gives `error.AlertSent`.
    pub fn reject(c: *Client, w: *Writer, a: Alert) Error {
        return c.fail(w, a);
    }

    /// Handles one whole record of the server.
    pub fn handleRecord(c: *Client, w: *Writer, rec: []const u8) Error!Event {
        switch (c.state) {
            .start, .closed, .failed => return error.BadState,
            else => {},
        }
        if (rec.len < record.header_len) return c.fail(w, .decode_error);
        const h = record.Header.parse(rec[0..record.header_len]);
        if (rec.len != record.header_len + h.len) return c.fail(w, .decode_error);
        const body = rec[record.header_len..];
        if (h.type == .change_cipher_spec) {
            // Section 5: a CCS of one byte 0x01 from the ServerHello to the
            // Finished, with no handshake message in parts.
            if (c.state == .wait_sh or c.state == .connected or body.len != 1 or body[0] != 1 or !c.asm_.empty())
                return c.fail(w, .unexpected_message);
            return .none;
        }
        var ct = h.type;
        var data: []const u8 = body;
        if (c.read) |*p| {
            const pl = p.open(&c.plain, rec) catch |e| return c.fail(w, record.alertOf(e));
            ct = pl.type;
            data = pl.data;
        } else {
            record.checkPlain(h) catch |e| return c.fail(w, record.alertOf(e));
            if (h.type == .application_data) return c.fail(w, .unexpected_message);
        }
        switch (ct) {
            .alert => {
                if (data.len != 2) return c.fail(w, .decode_error);
                if (data[1] == @backingInt(Alert.close_notify)) {
                    c.state = .closed;
                    return .closed;
                }
                c.state = .failed;
                c.got_alert = data[1];
                return error.AlertReceived;
            },
            .application_data => {
                if (c.state != .connected) return c.fail(w, .unexpected_message);
                if (!c.asm_.empty()) return c.fail(w, .unexpected_message);
                return .{ .data = data };
            },
            .handshake => {
                c.asm_.add(data) catch return c.fail(w, .decode_error);
                var ev: Event = .none;
                while (c.asm_.next() catch return c.fail(w, .decode_error)) |m| {
                    const e = try c.handshake(w, m);
                    if (e != .none) ev = e;
                }
                return ev;
            },
            else => return c.fail(w, .unexpected_message),
        }
    }

    fn handshake(c: *Client, w: *Writer, m: []const u8) Error!Event {
        const t: msg.Type = @fromBackingInt(@intCast(m[0]));
        const body = m[4..];
        switch (c.state) {
            .wait_sh, .wait_sh2 => {
                if (t != .server_hello) return c.fail(w, .unexpected_message);
                try c.serverHello(w, m, body);
                return .none;
            },
            .wait_ee => {
                if (t != .encrypted_extensions) return c.fail(w, .unexpected_message);
                try c.encryptedExtensions(w, body);
                c.transcript.add(m);
                c.state = .wait_cert_cr;
                return .none;
            },
            .wait_cert_cr, .wait_cert => {
                if (t == .certificate_request and c.state == .wait_cert_cr) {
                    try c.certificateRequest(w, body);
                    c.transcript.add(m);
                    c.state = .wait_cert;
                    return .none;
                }
                if (t != .certificate) return c.fail(w, .unexpected_message);
                try c.certificate(w, body);
                c.transcript.add(m);
                c.state = .wait_cv;
                return .none;
            },
            .wait_cv => {
                if (t != .certificate_verify) return c.fail(w, .unexpected_message);
                try c.certificateVerify(w, body);
                c.transcript.add(m);
                c.state = .wait_finished;
                return .none;
            },
            .wait_finished => {
                if (t != .finished) return c.fail(w, .unexpected_message);
                try c.finished(w, m, body);
                return .handshake_done;
            },
            .connected => {
                switch (t) {
                    .new_session_ticket => {
                        var r = msg.Reader.init(body);
                        _ = r.int(u32) catch return c.fail(w, .decode_error);
                        _ = r.int(u32) catch return c.fail(w, .decode_error);
                        _ = r.vec(u8, 0, 255) catch return c.fail(w, .decode_error);
                        _ = r.vec(u16, 1, 0xffff) catch return c.fail(w, .decode_error);
                        _ = r.vec(u16, 0, 0xfffe) catch return c.fail(w, .decode_error);
                        r.end() catch return c.fail(w, .decode_error);
                    },
                    .key_update => {
                        if (body.len != 1 or body[0] > 1) return c.fail(w, .decode_error);
                        if (!c.asm_.empty()) return c.fail(w, .unexpected_message);
                        c.read.?.update();
                        if (body[0] == 1) try c.sendKeyUpdate(w, false);
                    },
                    else => return c.fail(w, .unexpected_message),
                }
                return .none;
            },
            else => return c.fail(w, .unexpected_message),
        }
    }

    fn offeredSuite(c: *const Client, v: u16) ?Suite {
        for (c.opts.suites) |s| if (@backingInt(s) == v) return s;
        return null;
    }

    fn serverHello(c: *Client, w: *Writer, m: []const u8, body: []const u8) Error!void {
        var r = msg.Reader.init(body);
        const version = r.int(u16) catch return c.fail(w, .decode_error);
        const random = r.bytes(32) catch return c.fail(w, .decode_error);
        const sid = r.vec(u8, 0, 32) catch return c.fail(w, .decode_error);
        const suite_v = r.int(u16) catch return c.fail(w, .decode_error);
        const comp = r.int(u8) catch return c.fail(w, .decode_error);
        // A TLS 1.2 server can send a ServerHello with no extensions.
        var exts = if (r.done()) msg.Reader.init("") else r.sub(u16, 0, 0xffff) catch return c.fail(w, .decode_error);
        r.end() catch return c.fail(w, .decode_error);
        if (version != 0x0303) return c.fail(w, .protocol_version);
        const is_hrr = std.mem.eql(u8, random, &hrr_random);
        var sv: ?u16 = null;
        var share_group: ?u16 = null;
        var share: []const u8 = "";
        var cookie: ?[]const u8 = null;
        var seen: [8]u16 = undefined;
        var n_seen: usize = 0;
        while (!exts.done()) {
            const et = exts.int(u16) catch return c.fail(w, .decode_error);
            var eb = exts.sub(u16, 0, 0xffff) catch return c.fail(w, .decode_error);
            for (seen[0..n_seen]) |s| if (s == et) return c.fail(w, .illegal_parameter);
            if (n_seen == seen.len) return c.fail(w, .unsupported_extension);
            seen[n_seen] = et;
            n_seen += 1;
            switch (et) {
                Ext.supported_versions => sv = eb.int(u16) catch return c.fail(w, .decode_error),
                Ext.key_share => {
                    share_group = eb.int(u16) catch return c.fail(w, .decode_error);
                    if (!is_hrr) share = eb.vec(u16, 1, 0xffff) catch return c.fail(w, .decode_error);
                },
                Ext.cookie => {
                    if (!is_hrr) return c.fail(w, .unsupported_extension);
                    cookie = eb.vec(u16, 1, 0xffff) catch return c.fail(w, .decode_error);
                },
                // No PSK was offered.
                Ext.pre_shared_key => return c.fail(w, .illegal_parameter),
                else => return c.fail(w, .unsupported_extension),
            }
            eb.end() catch return c.fail(w, .decode_error);
        }
        if (sv == null) {
            // A server of TLS 1.2 or older.
            return c.fail(w, .protocol_version);
        }
        if (sv.? != 0x0304) return c.fail(w, .illegal_parameter);
        const sent_sid: []const u8 = if (c.opts.compat) &c.ent.session_id else "";
        if (!std.mem.eql(u8, sid, sent_sid) or comp != 0) return c.fail(w, .illegal_parameter);
        const suite = c.offeredSuite(suite_v) orelse return c.fail(w, .illegal_parameter);
        if (c.state == .wait_sh2 and suite != c.suite) return c.fail(w, .illegal_parameter);
        c.suite = suite;
        c.kind = if (suite.hashLen() == 48) .sha384 else .sha256;
        if (c.state == .wait_sh) {
            // Section 4.4.1: the transcript starts after the ServerHello
            // or the HelloRetryRequest gives the hash.
            c.transcript = if (c.kind == .sha256) .{ .sha256 = .init(.{}) } else .{ .sha384 = .init(.{}) };
            if (is_hrr) {
                const h1 = blk: {
                    c.transcript.add(c.ch1[0..c.ch1_len]);
                    break :blk c.transcript.current();
                };
                c.transcript = if (c.kind == .sha256) .{ .sha256 = .init(.{}) } else .{ .sha384 = .init(.{}) };
                c.transcript.add(&.{ @backingInt(msg.Type.message_hash), 0, 0, @intCast(h1.n) });
                c.transcript.add(h1.slice());
            } else c.transcript.add(c.ch1[0..c.ch1_len]);
        }
        if (is_hrr) {
            if (c.state != .wait_sh) return c.fail(w, .unexpected_message);
            const g: Group = @fromBackingInt(@intCast(share_group orelse return c.fail(w, .missing_extension)));
            // Section 4.1.4: a group of the list, with no key share yet.
            var offered = false;
            for (c.opts.groups) |x| offered = offered or x == g;
            for (c.opts.key_shares) |x| if (x == g) return c.fail(w, .illegal_parameter);
            if (!offered or g.shareLen() == 0) return c.fail(w, .illegal_parameter);
            c.hrr_group = g;
            if (cookie) |ck| {
                if (ck.len > c.cookie.len) return c.fail(w, .illegal_parameter);
                @memcpy(c.cookie[0..ck.len], ck);
                c.cookie_len = ck.len;
            }
            c.transcript.add(m);
            var buf: [2048]u8 = undefined;
            const ch2 = try c.buildHello(&buf, g);
            c.transcript.add(ch2);
            try c.sendCcs(w);
            try c.sendPlain(w, .handshake, 0x0303, ch2);
            c.state = .wait_sh2;
            return;
        }
        c.transcript.add(m);
        const g: Group = @fromBackingInt(@intCast(share_group orelse return c.fail(w, .missing_extension)));
        const allowed = if (c.hrr_group) |hg| g == hg else blk: {
            var ok = false;
            for (c.opts.key_shares) |x| ok = ok or x == g;
            break :blk ok;
        };
        if (!allowed) return c.fail(w, .illegal_parameter);
        var shared_buf: [tcrypto.max_secret]u8 = undefined;
        const shared = tcrypto.sharedSecret(g, c.privateOf(g), share, &shared_buf) catch return c.fail(w, .illegal_parameter);
        const th = c.transcript.current();
        switch (c.kind) {
            inline else => |k| {
                const S = Sched(k);
                const hs = S.next(S.early(null), shared);
                c.hs_secret = Secret.of(hs);
                c.c_hs = Secret.of(S.deriveSecret(hs, "c hs traffic", th.slice()));
                c.s_hs = Secret.of(S.deriveSecret(hs, "s hs traffic", th.slice()));
            },
        }
        std.crypto.secureZero(u8, &shared_buf);
        if (!c.asm_.empty()) return c.fail(w, .unexpected_message);
        c.read = record.Protection.init(suite, c.s_hs.slice());
        c.state = .wait_ee;
    }

    fn encryptedExtensions(c: *Client, w: *Writer, body: []const u8) Error!void {
        var r = msg.Reader.init(body);
        var exts = r.sub(u16, 0, 0xffff) catch return c.fail(w, .decode_error);
        r.end() catch return c.fail(w, .decode_error);
        var seen: [16]u16 = undefined;
        var n_seen: usize = 0;
        while (!exts.done()) {
            const et = exts.int(u16) catch return c.fail(w, .decode_error);
            var eb = exts.sub(u16, 0, 0xffff) catch return c.fail(w, .decode_error);
            for (seen[0..n_seen]) |s| if (s == et) return c.fail(w, .illegal_parameter);
            if (n_seen == seen.len) return c.fail(w, .unsupported_extension);
            seen[n_seen] = et;
            n_seen += 1;
            switch (et) {
                Ext.server_name => if (!eb.done()) return c.fail(w, .decode_error),
                Ext.supported_groups => _ = eb.bytes(eb.left()) catch unreachable,
                Ext.alpn => {
                    if (c.opts.alpn.len == 0) return c.fail(w, .unsupported_extension);
                    var list = eb.sub(u16, 2, 0xffff) catch return c.fail(w, .decode_error);
                    const p = list.vec(u8, 1, 255) catch return c.fail(w, .decode_error);
                    list.end() catch return c.fail(w, .illegal_parameter);
                    var ok = false;
                    for (c.opts.alpn) |x| ok = ok or std.mem.eql(u8, x, p);
                    if (!ok) return c.fail(w, .illegal_parameter);
                    @memcpy(c.alpn[0..p.len], p);
                    c.alpn_len = @intCast(p.len);
                },
                // record_size_limit (RFC 8449), when the layout has it.
                28 => _ = eb.bytes(eb.left()) catch unreachable,
                Ext.key_share, Ext.supported_versions, Ext.pre_shared_key, Ext.cookie, Ext.signature_algorithms, Ext.psk_key_exchange_modes => return c.fail(w, .illegal_parameter),
                else => return c.fail(w, .unsupported_extension),
            }
            eb.end() catch return c.fail(w, .decode_error);
        }
    }

    fn certificateRequest(c: *Client, w: *Writer, body: []const u8) Error!void {
        var r = msg.Reader.init(body);
        const ctx = r.vec(u8, 0, 255) catch return c.fail(w, .decode_error);
        _ = r.vec(u16, 2, 0xffff) catch return c.fail(w, .decode_error);
        r.end() catch return c.fail(w, .decode_error);
        @memcpy(c.cr_context[0..ctx.len], ctx);
        c.cr_context_len = @intCast(ctx.len);
        c.cert_requested = true;
    }

    fn certificate(c: *Client, w: *Writer, body: []const u8) Error!void {
        var r = msg.Reader.init(body);
        const ctx = r.vec(u8, 0, 255) catch return c.fail(w, .decode_error);
        if (ctx.len != 0) return c.fail(w, .illegal_parameter);
        var list = r.sub(u24, 0, 0xffffff) catch return c.fail(w, .decode_error);
        r.end() catch return c.fail(w, .decode_error);
        if (list.done()) return c.fail(w, .decode_error);
        var certs: [11]x509.Cert = undefined;
        var n: usize = 0;
        while (!list.done()) {
            const data = list.vec(u24, 1, 0xffffff) catch return c.fail(w, .decode_error);
            const ext = list.vec(u16, 0, 0xffff) catch return c.fail(w, .decode_error);
            // The client asked for no extension of an entry.
            if (ext.len != 0) return c.fail(w, .unsupported_extension);
            if (n == certs.len) return c.fail(w, .bad_certificate);
            certs[n] = x509.parse(data) catch |e| {
                // A peer cert that does not parse ends the handshake; an
                // extra certificate that does not parse is left out.
                if (n == 0) return c.fail(w, if (e == error.Unsupported) .unsupported_certificate else .bad_certificate);
                continue;
            };
            n += 1;
        }
        const leaf = &certs[0];
        const skip = builtin.is_test and c.opts.test_skip_signature;
        if (c.opts.verify_chain and !skip) {
            chain.verify(leaf, certs[1..n], c.opts.roots, .{ .now = c.opts.now, .host = c.opts.host }) catch |e| {
                c.chain_error = e;
                return c.fail(w, switch (e) {
                    error.UnknownIssuer => .unknown_ca,
                    error.Expired => .certificate_expired,
                    error.Unsupported => .unsupported_certificate,
                    error.HostName, error.BadUsage, error.NameConstraint => .certificate_unknown,
                    else => .bad_certificate,
                });
            };
        }
        c.leaf_kind = leaf.key_kind orelse return c.fail(w, .unsupported_certificate);
        if (leaf.key.len > c.leaf_key.len) return c.fail(w, .unsupported_certificate);
        @memcpy(c.leaf_key[0..leaf.key.len], leaf.key);
        c.leaf_key_len = leaf.key.len;
    }

    fn certificateVerify(c: *Client, w: *Writer, body: []const u8) Error!void {
        var r = msg.Reader.init(body);
        const sv = r.int(u16) catch return c.fail(w, .decode_error);
        const sig = r.vec(u16, 1, 0xffff) catch return c.fail(w, .decode_error);
        r.end() catch return c.fail(w, .decode_error);
        const scheme: Scheme = @fromBackingInt(@intCast(sv));
        var offered = false;
        for (c.opts.schemes) |s| offered = offered or s == scheme;
        // Section 4.4.3: RSASSA-PKCS1-v1_5 is for certificates only.
        const fits = switch (scheme) {
            .ecdsa_secp256r1_sha256 => c.leaf_kind == .p256,
            .ecdsa_secp384r1_sha384 => c.leaf_kind == .p384,
            .ed25519 => c.leaf_kind == .ed25519,
            .rsa_pss_rsae_sha256, .rsa_pss_rsae_sha384, .rsa_pss_rsae_sha512 => c.leaf_kind == .rsa,
            else => false,
        };
        if (!offered or !fits) return c.fail(w, .illegal_parameter);
        if (builtin.is_test and c.opts.test_skip_signature) return;
        var content: [64 + 34 + 48]u8 = undefined;
        @memset(content[0..64], 0x20);
        const label = "TLS 1.3, server CertificateVerify\x00";
        @memcpy(content[64..][0..label.len], label);
        const th = c.transcript.current();
        @memcpy(content[64 + label.len ..][0..th.n], th.slice());
        tcrypto.verify(scheme, c.leaf_key[0..c.leaf_key_len], content[0 .. 64 + label.len + th.n], sig) catch return c.fail(w, .decrypt_error);
    }

    fn finished(c: *Client, w: *Writer, m: []const u8, body: []const u8) Error!void {
        const th = c.transcript.current();
        var want: Secret = .{};
        var c_ap: Secret = .{};
        var s_ap: Secret = .{};
        var master: Secret = .{};
        switch (c.kind) {
            inline else => |k| {
                const S = Sched(k);
                want = Secret.of(S.finished(c.s_hs.arr(S.hash_len), th.slice()));
            },
        }
        if (body.len != want.n or !std.crypto.timing_safe.eql([48]u8, padded(body), want.b)) return c.fail(w, .decrypt_error);
        // Section 5.1: the Finished ends the record.
        if (!c.asm_.empty()) return c.fail(w, .unexpected_message);
        c.transcript.add(m);
        const th_sf = c.transcript.current();
        switch (c.kind) {
            inline else => |k| {
                const S = Sched(k);
                const ms = S.next(c.hs_secret.arr(S.hash_len), null);
                master = Secret.of(ms);
                c_ap = Secret.of(S.deriveSecret(ms, "c ap traffic", th_sf.slice()));
                s_ap = Secret.of(S.deriveSecret(ms, "s ap traffic", th_sf.slice()));
            },
        }
        try c.sendCcs(w);
        c.write_p = record.Protection.init(c.suite, c.c_hs.slice());
        if (c.cert_requested) {
            var buf: [264]u8 = undefined;
            var b = msg.Builder.init(&buf);
            b.int(u8, @backingInt(msg.Type.certificate)) catch unreachable;
            b.begin(3) catch unreachable;
            b.vec(1, c.cr_context[0..c.cr_context_len]) catch unreachable;
            b.vec(3, "") catch unreachable;
            b.finish() catch unreachable;
            c.transcript.add(b.slice());
            try c.sendSealed(w, .handshake, b.slice());
        }
        var fin: [52]u8 = undefined;
        switch (c.kind) {
            inline else => |k| {
                const S = Sched(k);
                const th2 = c.transcript.current();
                const vd = S.finished(c.c_hs.arr(S.hash_len), th2.slice());
                fin[0] = @backingInt(msg.Type.finished);
                std.mem.writeInt(u24, fin[1..4], S.hash_len, .big);
                @memcpy(fin[4..][0..S.hash_len], &vd);
            },
        }
        const fin_msg = fin[0 .. 4 + want.n];
        try c.sendSealed(w, .handshake, fin_msg);
        c.transcript.add(fin_msg);
        switch (c.kind) {
            inline else => |k| {
                const S = Sched(k);
                c.res_master = Secret.of(S.deriveSecret(master.arr(S.hash_len), "res master", c.transcript.current().slice()));
            },
        }
        c.read = record.Protection.init(c.suite, s_ap.slice());
        c.write_p = record.Protection.init(c.suite, c_ap.slice());
        std.crypto.secureZero(u8, &c.c_hs.b);
        std.crypto.secureZero(u8, &c.s_hs.b);
        std.crypto.secureZero(u8, &c.hs_secret.b);
        c.state = .connected;
    }

    fn padded(b: []const u8) [48]u8 {
        var out: [48]u8 = @splat(0);
        @memcpy(out[0..@min(b.len, 48)], b[0..@min(b.len, 48)]);
        return out;
    }

    fn sendKeyUpdate(c: *Client, w: *Writer, request: bool) Error!void {
        try c.sendSealed(w, .handshake, &.{ @backingInt(msg.Type.key_update), 0, 0, 1, @intFromBool(request) });
        c.write_p.?.update();
    }

    /// Seals application data in records of at most 2^14 bytes.
    pub fn write(c: *Client, w: *Writer, data: []const u8) Error!void {
        if (c.state != .connected or c.write_closed) return error.BadState;
        var rest = data;
        while (true) {
            if (c.write_p.?.needsUpdate()) try c.sendKeyUpdate(w, false);
            const n = @min(rest.len, record.max_plaintext);
            try c.sendSealed(w, .application_data, rest[0..n]);
            rest = rest[n..];
            if (rest.len == 0) break;
        }
    }

    /// Sends close_notify. The client can still read to the
    /// close_notify of the server.
    pub fn close(c: *Client, w: *Writer) Error!void {
        if (c.write_p == null or c.write_closed) return;
        try c.sendSealed(w, .alert, &.{ 1, 0 });
        c.write_closed = true;
    }
};

fn isIp(h: []const u8) bool {
    if (std.mem.indexOfScalar(u8, h, ':') != null) return true;
    _ = std.Io.net.Ip4Address.parse(h, 0) catch return false;
    return true;
}

/// Reads one whole record from `r`: the header, then the fragment of
/// the length of the header, at most `record.max_ciphertext` bytes.
pub fn readRecord(r: *std.Io.Reader) ![]const u8 {
    const hdr = try r.peek(record.header_len);
    const len = std.mem.readInt(u16, hdr[3..5], .big);
    if (len > record.max_ciphertext) return error.RecordOverflow;
    return r.take(record.header_len + len);
}

/// A client on a reader and a writer, such as the two sides of a TCP
/// stream. The reader needs a buffer of at least `record.max_record`
/// bytes.
pub const Conn = struct {
    c: Client,
    r: *std.Io.Reader,
    w: *Writer,

    pub fn init(conn: *Conn, r: *std.Io.Reader, w: *Writer, opts: Options, ent: Entropy) void {
        conn.r = r;
        conn.w = w;
        conn.c.init(opts, ent);
    }

    pub fn handshake(conn: *Conn) !void {
        try conn.c.hello(conn.w);
        try conn.w.flush();
        while (true) {
            const rec = try readRecord(conn.r);
            const ev = try conn.c.handleRecord(conn.w, rec);
            try conn.w.flush();
            switch (ev) {
                .handshake_done => return,
                .closed => return error.EndOfStream,
                else => {},
            }
        }
    }

    /// The next application data, or null after close_notify.
    pub fn read(conn: *Conn) !?[]const u8 {
        while (true) {
            const rec = try readRecord(conn.r);
            const ev = try conn.c.handleRecord(conn.w, rec);
            try conn.w.flush();
            switch (ev) {
                .data => |d| if (d.len > 0) return d,
                .closed => return null,
                else => {},
            }
        }
    }

    pub fn writeAll(conn: *Conn, data: []const u8) !void {
        try conn.c.write(conn.w, data);
        try conn.w.flush();
    }

    pub fn close(conn: *Conn) !void {
        try conn.c.close(conn.w);
        try conn.w.flush();
    }
};

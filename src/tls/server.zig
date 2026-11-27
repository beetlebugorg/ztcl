//! The TLS 1.3 server handshake (RFC 8446 sections 4 and 6), with no
//! I/O of its own.
//!
//! `handleRecord` reads each whole record from the client, writes the
//! records of the answer, and gives a `client.Event`. `write` seals
//! application data, and `close` sends `close_notify`.
//!
//! The server reads the ClientHello and picks, in the order of its own
//! `Options`: the suite, the group of a key share, and the protocol of
//! ALPN. When the client has no key share of a group that both sides
//! support, the server sends one HelloRetryRequest for its first such
//! group. A ClientHello with no `supported_versions` that lists TLS 1.3
//! gets the `protocol_version` alert.
//!
//! The first flight after the ServerHello (EncryptedExtensions,
//! Certificate, CertificateVerify, and Finished) goes out in as few
//! records as fit, as in RFC 8448. The server signs with the key of
//! `Options.key`: ECDSA on P-256 or P-384 (the deterministic nonce of
//! `std.crypto.sign.ecdsa` with no noise), or
//! Ed25519. The scheme must be in the `signature_algorithms` of the
//! client. The server asks for no client certificate, offers no PSK,
//! and skips 0-RTT data (section 4.2.10): it drops records that do not
//! open, up to `max_early` bytes, before the Finished of the client.
//!
//! In the middlebox compatibility mode (section D.4), a ClientHello
//! with a session ID gets the ID back and one change_cipher_spec record
//! after the first ServerHello or HelloRetryRequest.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const record = @import("record.zig");
const tcrypto = @import("crypto.zig");
const msg = @import("messages.zig");
const pem = @import("pem.zig");
const client = @import("client.zig");

const Writer = std.Io.Writer;
const Suite = record.Suite;
const Group = tcrypto.Group;
const Scheme = tcrypto.Scheme;
const Alert = record.Alert;
const Ext = msg.ExtType;
const Secret = client.Secret;
const Transcript = client.Transcript;
const Kind = client.Kind;
const Sched = client.Sched;
pub const Error = client.Error;
pub const Event = client.Event;

/// The bytes of 0-RTT data that the server skips at most.
pub const max_early = 1 << 16;

pub const Options = struct {
    /// The DER certificates, the leaf first.
    chain: []const []const u8,
    key: pem.PrivateKey,
    /// The protocols of ALPN in the order of preference. With none, the
    /// server leaves out ALPN.
    alpn: []const []const u8 = &.{},
    suites: []const Suite = &client.default_suites,
    groups: []const Group = &.{ .x25519, .secp256r1, .secp384r1 },
    /// The RFC 8448 tests give the CertificateVerify message of the
    /// trace, because the key of the RFC is RSA. Only a test build
    /// reads it.
    test_cert_verify: ?[]const u8 = null,
    /// The extensions of the EncryptedExtensions of the trace. Only a
    /// test build reads it.
    test_ee: ?[]const u8 = null,
    /// The cookie extension data of the HelloRetryRequest of the trace,
    /// and the
    /// NewSessionTicket message of the trace. Only a test build reads
    /// them.
    test_hrr_cookie: ?[]const u8 = null,
    test_ticket: ?[]const u8 = null,
};

/// The random bytes of a connection.
pub const Entropy = struct {
    random: [32]u8,
    x25519: [32]u8,
    p256: [32]u8,
    p384: [48]u8,

    pub fn fill(io: std.Io) Entropy {
        var e: Entropy = undefined;
        io.random(std.mem.asBytes(&e));
        return e;
    }
};

const State = enum { wait_ch, wait_ch2, wait_finished, connected, closed, failed };

/// The fields of a ClientHello that the server uses.
const Hello = struct {
    session_id: []const u8 = "",
    suites: []const u8 = "",
    versions: ?[]const u8 = null,
    groups: []const u8 = "",
    schemes: []const u8 = "",
    shares: ?[]const u8 = null,
    alpn: ?[]const u8 = null,
    host: ?[]const u8 = null,
    early: bool = false,
};

fn hasU16(list: []const u8, v: u16) bool {
    var i: usize = 0;
    while (i + 1 < list.len) : (i += 2) {
        if (std.mem.readInt(u16, list[i..][0..2], .big) == v) return true;
    }
    return false;
}

pub const Server = struct {
    opts: Options,
    ent: Entropy,
    state: State = .wait_ch,
    sent_alert: ?Alert = null,
    got_alert: ?u8 = null,
    ccs_sent: bool = false,
    write_closed: bool = false,
    hrr_group: ?Group = null,
    suite: Suite = .aes_128_gcm_sha256,
    kind: Kind = .sha256,
    scheme: Scheme = .ed25519,
    transcript: Transcript = .none,
    session_id: [32]u8 = undefined,
    session_id_len: u8 = 0,
    c_hs: Secret = .{},
    c_ap: Secret = .{},
    res_secret: Secret = .{},
    early_left: usize = 0,
    read: ?record.Protection = null,
    write_p: ?record.Protection = null,
    host: [255]u8 = undefined,
    host_len: u8 = 0,
    alpn: [255]u8 = undefined,
    alpn_len: u8 = 0,
    asm_: msg.Assembler = .{},
    plain: [record.max_ciphertext]u8 = undefined,
    out: [record.max_record]u8 = undefined,
    flight: [msg.max_message]u8 = undefined,

    pub fn init(s: *Server, opts: Options, ent: Entropy) void {
        s.* = .{ .opts = opts, .ent = ent };
    }

    /// The protocol of ALPN, or null.
    pub fn protocol(s: *const Server) ?[]const u8 {
        return if (s.alpn_len > 0) s.alpn[0..s.alpn_len] else null;
    }

    /// The DNS name of SNI, or null.
    pub fn serverName(s: *const Server) ?[]const u8 {
        return if (s.host_len > 0) s.host[0..s.host_len] else null;
    }

    pub fn negotiatedSuite(s: *const Server) Suite {
        return s.suite;
    }

    fn sendPlain(s: *Server, w: *Writer, ct: record.ContentType, data: []const u8) Error!void {
        const rec = record.writePlain(&s.out, ct, 0x0303, data) catch return error.NoSpace;
        w.writeAll(rec) catch return error.WriteFailed;
    }

    fn sendSealed(s: *Server, w: *Writer, ct: record.ContentType, data: []const u8) Error!void {
        const p = &(s.write_p orelse return error.BadState);
        var rest = data;
        while (true) {
            const n = @min(rest.len, record.max_plaintext);
            const rec = p.seal(&s.out, ct, rest[0..n], 0) catch return error.NoSpace;
            w.writeAll(rec) catch return error.WriteFailed;
            rest = rest[n..];
            if (rest.len == 0) break;
        }
    }

    fn sendCcs(s: *Server, w: *Writer) Error!void {
        if (s.session_id_len == 0 or s.ccs_sent) return;
        s.ccs_sent = true;
        try s.sendPlain(w, .change_cipher_spec, &.{1});
    }

    /// Sends the alert and gives `error.AlertSent`.
    fn fail(s: *Server, w: *Writer, a: Alert) Error {
        s.sent_alert = a;
        const body = [2]u8{ 2, @backingInt(a) };
        if (s.write_p != null) s.sendSealed(w, .alert, &body) catch {} else s.sendPlain(w, .alert, &body) catch {};
        s.state = .failed;
        return error.AlertSent;
    }

    /// Handles one whole record of the client.
    pub fn handleRecord(s: *Server, w: *Writer, rec: []const u8) Error!Event {
        switch (s.state) {
            .closed, .failed => return error.BadState,
            else => {},
        }
        if (rec.len < record.header_len) return s.fail(w, .decode_error);
        const h = record.Header.parse(rec[0..record.header_len]);
        if (rec.len != record.header_len + h.len) return s.fail(w, .decode_error);
        const body = rec[record.header_len..];
        if (h.type == .change_cipher_spec) {
            // Section 5: a CCS of one byte 0x01 after the first
            // ClientHello and before the Finished.
            if (s.state == .wait_ch or s.state == .connected or body.len != 1 or body[0] != 1 or !s.asm_.empty())
                return s.fail(w, .unexpected_message);
            return .none;
        }
        var ct = h.type;
        var data: []const u8 = body;
        if (s.read) |*p| {
            const pl = p.open(&s.plain, rec) catch |e| {
                // Section 4.2.10: 0-RTT data that the server skips.
                if (s.state == .wait_finished and s.early_left >= rec.len and h.type == .application_data) {
                    s.early_left -= rec.len;
                    return .none;
                }
                return s.fail(w, record.alertOf(e));
            };
            s.early_left = 0;
            ct = pl.type;
            data = pl.data;
        } else {
            record.checkPlain(h) catch |e| return s.fail(w, record.alertOf(e));
            if (h.type == .application_data) {
                if (s.state == .wait_ch2 and s.early_left >= rec.len) {
                    s.early_left -= rec.len;
                    return .none;
                }
                return s.fail(w, .unexpected_message);
            }
        }
        switch (ct) {
            .alert => {
                if (data.len != 2) return s.fail(w, .decode_error);
                if (data[1] == @backingInt(Alert.close_notify)) {
                    s.state = .closed;
                    return .closed;
                }
                s.state = .failed;
                s.got_alert = data[1];
                return error.AlertReceived;
            },
            .application_data => {
                if (s.state != .connected or !s.asm_.empty()) return s.fail(w, .unexpected_message);
                return .{ .data = data };
            },
            .handshake => {
                s.asm_.add(data) catch return s.fail(w, .decode_error);
                var ev: Event = .none;
                while (s.asm_.next() catch return s.fail(w, .decode_error)) |m| {
                    const e = try s.handshake(w, m);
                    if (e != .none) ev = e;
                }
                return ev;
            },
            else => return s.fail(w, .unexpected_message),
        }
    }

    fn handshake(s: *Server, w: *Writer, m: []const u8) Error!Event {
        const t: msg.Type = @fromBackingInt(@intCast(m[0]));
        const body = m[4..];
        switch (s.state) {
            .wait_ch, .wait_ch2 => {
                if (t != .client_hello) return s.fail(w, .unexpected_message);
                try s.clientHello(w, m, body);
                return .none;
            },
            .wait_finished => {
                if (t != .finished) return s.fail(w, .unexpected_message);
                try s.finished(w, m, body);
                return .handshake_done;
            },
            .connected => {
                if (t != .key_update) return s.fail(w, .unexpected_message);
                if (body.len != 1 or body[0] > 1) return s.fail(w, .decode_error);
                if (!s.asm_.empty()) return s.fail(w, .unexpected_message);
                s.read.?.update();
                if (body[0] == 1) try s.sendKeyUpdate(w);
                return .none;
            },
            else => return s.fail(w, .unexpected_message),
        }
    }

    fn parseHello(s: *Server, w: *Writer, body: []const u8) Error!Hello {
        var hello: Hello = .{};
        var r = msg.Reader.init(body);
        _ = r.int(u16) catch return s.fail(w, .decode_error);
        _ = r.bytes(32) catch return s.fail(w, .decode_error);
        hello.session_id = r.vec(u8, 0, 32) catch return s.fail(w, .decode_error);
        hello.suites = r.vec(u16, 2, 0xfffe) catch return s.fail(w, .decode_error);
        const comp = r.vec(u8, 1, 255) catch return s.fail(w, .decode_error);
        // A TLS 1.2 ClientHello can end here.
        var exts = if (r.done()) msg.Reader.init("") else r.sub(u16, 0, 0xffff) catch return s.fail(w, .decode_error);
        r.end() catch return s.fail(w, .decode_error);
        var seen: [32]u16 = undefined;
        var n_seen: usize = 0;
        while (!exts.done()) {
            const et = exts.int(u16) catch return s.fail(w, .decode_error);
            var eb = exts.sub(u16, 0, 0xffff) catch return s.fail(w, .decode_error);
            for (seen[0..n_seen]) |x| if (x == et) return s.fail(w, .illegal_parameter);
            if (n_seen < seen.len) {
                seen[n_seen] = et;
                n_seen += 1;
            }
            switch (et) {
                Ext.supported_versions => hello.versions = eb.vec(u8, 2, 254) catch return s.fail(w, .decode_error),
                Ext.supported_groups => hello.groups = eb.vec(u16, 2, 0xfffe) catch return s.fail(w, .decode_error),
                Ext.signature_algorithms => hello.schemes = eb.vec(u16, 2, 0xfffe) catch return s.fail(w, .decode_error),
                Ext.key_share => hello.shares = eb.vec(u16, 0, 0xffff) catch return s.fail(w, .decode_error),
                Ext.alpn => hello.alpn = eb.vec(u16, 2, 0xffff) catch return s.fail(w, .decode_error),
                Ext.server_name => {
                    var list = eb.sub(u16, 1, 0xffff) catch return s.fail(w, .decode_error);
                    while (!list.done()) {
                        const nt = list.int(u8) catch return s.fail(w, .decode_error);
                        const name = list.vec(u16, 1, 0xffff) catch return s.fail(w, .decode_error);
                        if (nt == 0 and hello.host == null) hello.host = name;
                    }
                },
                Ext.early_data => {
                    hello.early = true;
                    _ = eb.bytes(eb.left()) catch unreachable;
                },
                else => _ = eb.bytes(eb.left()) catch unreachable,
            }
            eb.end() catch return s.fail(w, .decode_error);
        }
        const v13 = if (hello.versions) |v| blk: {
            var i: usize = 0;
            while (i + 1 < v.len) : (i += 2) {
                if (v[i] == 3 and v[i + 1] == 4) break :blk true;
            }
            break :blk false;
        } else false;
        if (!v13) return s.fail(w, .protocol_version);
        if (comp.len != 1 or comp[0] != 0) return s.fail(w, .illegal_parameter);
        return hello;
    }

    fn privateOf(s: *const Server, g: Group) []const u8 {
        return switch (g) {
            .x25519 => &s.ent.x25519,
            .secp256r1 => &s.ent.p256,
            .secp384r1 => &s.ent.p384,
            _ => "",
        };
    }

    /// The key share of the client for `g`, or null.
    fn shareOf(shares: []const u8, g: Group) Error!?[]const u8 {
        var r = msg.Reader.init(shares);
        while (!r.done()) {
            const sg = r.int(u16) catch return error.AlertSent;
            const k = r.vec(u16, 1, 0xffff) catch return error.AlertSent;
            if (sg == @backingInt(g)) return k;
        }
        return null;
    }

    fn schemeOf(key: pem.PrivateKey) Scheme {
        return switch (key) {
            .p256 => .ecdsa_secp256r1_sha256,
            .p384 => .ecdsa_secp384r1_sha384,
            .ed25519 => .ed25519,
        };
    }

    fn clientHello(s: *Server, w: *Writer, m: []const u8, body: []const u8) Error!void {
        const hello = try s.parseHello(w, body);
        const shares = hello.shares orelse return s.fail(w, .missing_extension);
        if (s.state == .wait_ch) {
            const suite = for (s.opts.suites) |x| {
                if (hasU16(hello.suites, @backingInt(x))) break x;
            } else return s.fail(w, .handshake_failure);
            s.suite = suite;
            s.kind = if (suite.hashLen() == 48) .sha384 else .sha256;
            s.scheme = schemeOf(s.opts.key);
            if (!(builtin.is_test and s.opts.test_cert_verify != null) and !hasU16(hello.schemes, @backingInt(s.scheme)))
                return s.fail(w, .handshake_failure);
            @memcpy(s.session_id[0..hello.session_id.len], hello.session_id);
            s.session_id_len = @intCast(hello.session_id.len);
            if (hello.host) |hn| {
                if (hn.len <= s.host.len) {
                    @memcpy(s.host[0..hn.len], hn);
                    s.host_len = @intCast(hn.len);
                }
            }
            if (hello.alpn) |list| if (s.opts.alpn.len > 0) {
                const pick = for (s.opts.alpn) |p| {
                    var r = msg.Reader.init(list);
                    const found = while (!r.done()) {
                        const cp = r.vec(u8, 1, 255) catch return s.fail(w, .decode_error);
                        if (std.mem.eql(u8, cp, p)) break true;
                    } else false;
                    if (found) break p;
                } else return s.fail(w, .no_application_protocol);
                @memcpy(s.alpn[0..pick.len], pick);
                s.alpn_len = @intCast(pick.len);
            };
            s.transcript = if (s.kind == .sha256) .{ .sha256 = .init(.{}) } else .{ .sha384 = .init(.{}) };
            s.early_left = if (hello.early) max_early else 0;
        } else {
            // Section 4.1.2: the second ClientHello keeps the suite, and
            // has one share of the group of the HelloRetryRequest.
            if (!hasU16(hello.suites, @backingInt(s.suite))) return s.fail(w, .illegal_parameter);
            if (!std.mem.eql(u8, hello.session_id, s.session_id[0..s.session_id_len])) return s.fail(w, .illegal_parameter);
            if (hello.early) return s.fail(w, .illegal_parameter);
            s.early_left = 0;
        }
        var group: ?Group = null;
        var peer: []const u8 = "";
        if (s.hrr_group) |g| {
            peer = (shareOf(shares, g) catch return s.fail(w, .decode_error)) orelse return s.fail(w, .illegal_parameter);
            group = g;
        } else for (s.opts.groups) |g| {
            if (!hasU16(hello.groups, @backingInt(g))) continue;
            if (shareOf(shares, g) catch return s.fail(w, .decode_error)) |k| {
                group = g;
                peer = k;
                break;
            }
        }
        if (group == null) {
            if (s.state == .wait_ch2) return s.fail(w, .illegal_parameter);
            const g = for (s.opts.groups) |x| {
                if (hasU16(hello.groups, @backingInt(x))) break x;
            } else return s.fail(w, .handshake_failure);
            return s.retry(w, m, g);
        }
        s.transcript.add(m);
        const g = group.?;
        var shared_buf: [tcrypto.max_secret]u8 = undefined;
        const shared = tcrypto.sharedSecret(g, s.privateOf(g), peer, &shared_buf) catch return s.fail(w, .illegal_parameter);
        var pub_buf: [97]u8 = undefined;
        const mine = tcrypto.publicKey(g, s.privateOf(g), &pub_buf) catch return s.fail(w, .internal_error);
        var sh_buf: [256]u8 = undefined;
        const sh = s.buildServerHello(&sh_buf, &s.ent.random, g, mine) catch return s.fail(w, .internal_error);
        s.transcript.add(sh);
        try s.sendPlain(w, .handshake, sh);
        try s.sendCcs(w);
        const th = s.transcript.current();
        var hs: Secret = .{};
        var s_hs: Secret = .{};
        switch (s.kind) {
            inline else => |k| {
                const S = Sched(k);
                const x = S.next(S.early(null), shared);
                hs = Secret.of(x);
                s.c_hs = Secret.of(S.deriveSecret(x, "c hs traffic", th.slice()));
                s_hs = Secret.of(S.deriveSecret(x, "s hs traffic", th.slice()));
            },
        }
        std.crypto.secureZero(u8, &shared_buf);
        if (!s.asm_.empty()) return s.fail(w, .unexpected_message);
        s.write_p = record.Protection.init(s.suite, s_hs.slice());
        try s.firstFlight(w, s_hs);
        // The secrets of the application: the transcript to the
        // Finished of the server.
        const th_sf = s.transcript.current();
        switch (s.kind) {
            inline else => |k| {
                const S = Sched(k);
                const ms = S.next(hs.arr(S.hash_len), null);
                s.c_ap = Secret.of(S.deriveSecret(ms, "c ap traffic", th_sf.slice()));
                const s_ap = S.deriveSecret(ms, "s ap traffic", th_sf.slice());
                s.res_secret = Secret.of(ms);
                s.write_p = record.Protection.init(s.suite, &s_ap);
            },
        }
        std.crypto.secureZero(u8, &hs.b);
        std.crypto.secureZero(u8, &s_hs.b);
        s.read = record.Protection.init(s.suite, s.c_hs.slice());
        s.state = .wait_finished;
    }

    fn retry(s: *Server, w: *Writer, m: []const u8, g: Group) Error!void {
        // Section 4.4.1: the transcript starts with the hash of the
        // first ClientHello in a message_hash message.
        s.transcript.add(m);
        const h1 = s.transcript.current();
        s.transcript = if (s.kind == .sha256) .{ .sha256 = .init(.{}) } else .{ .sha384 = .init(.{}) };
        s.transcript.add(&.{ @backingInt(msg.Type.message_hash), 0, 0, @intCast(h1.n) });
        s.transcript.add(h1.slice());
        var buf: [256]u8 = undefined;
        const hrr = s.buildServerHello(&buf, &client.hrr_random, g, null) catch return s.fail(w, .internal_error);
        s.transcript.add(hrr);
        try s.sendPlain(w, .handshake, hrr);
        try s.sendCcs(w);
        s.hrr_group = g;
        s.state = .wait_ch2;
    }

    /// A ServerHello, or a HelloRetryRequest when `share` is null.
    fn buildServerHello(s: *Server, buf: []u8, random: *const [32]u8, g: Group, share: ?[]const u8) msg.Error![]const u8 {
        var b = msg.Builder.init(buf);
        try b.int(u8, @backingInt(msg.Type.server_hello));
        try b.begin(3);
        try b.int(u16, 0x0303);
        try b.put(random);
        try b.vec(1, s.session_id[0..s.session_id_len]);
        try b.int(u16, @backingInt(s.suite));
        try b.int(u8, 0);
        try b.begin(2);
        try b.int(u16, Ext.key_share);
        try b.begin(2);
        try b.int(u16, @backingInt(g));
        if (share) |k| try b.vec(2, k);
        try b.finish();
        if (builtin.is_test and share == null) if (s.opts.test_hrr_cookie) |ck| {
            try b.int(u16, Ext.cookie);
            try b.vec(2, ck);
        };
        try b.int(u16, Ext.supported_versions);
        try b.vec(2, &.{ 3, 4 });
        try b.finish();
        try b.finish();
        return b.slice();
    }

    /// EncryptedExtensions, Certificate, CertificateVerify, and
    /// Finished, sealed with the handshake key of the server.
    fn firstFlight(s: *Server, w: *Writer, s_hs: Secret) Error!void {
        var b = msg.Builder.init(&s.flight);
        const start_ee = b.len;
        b.int(u8, @backingInt(msg.Type.encrypted_extensions)) catch return s.fail(w, .internal_error);
        b.begin(3) catch return s.fail(w, .internal_error);
        if (builtin.is_test and s.opts.test_ee != null) {
            b.put(s.opts.test_ee.?) catch return s.fail(w, .internal_error);
        } else {
            b.begin(2) catch return s.fail(w, .internal_error);
            s.eeExtensions(&b) catch return s.fail(w, .internal_error);
            b.finish() catch return s.fail(w, .internal_error);
        }
        b.finish() catch return s.fail(w, .internal_error);
        s.transcript.add(b.slice()[start_ee..]);
        const start_cert = b.len;
        s.certificate(&b) catch return s.fail(w, .internal_error);
        s.transcript.add(b.slice()[start_cert..]);
        const start_cv = b.len;
        if (builtin.is_test and s.opts.test_cert_verify != null) {
            b.put(s.opts.test_cert_verify.?) catch return s.fail(w, .internal_error);
        } else {
            var content: [64 + 34 + 48]u8 = undefined;
            @memset(content[0..64], 0x20);
            const label = "TLS 1.3, server CertificateVerify\x00";
            @memcpy(content[64..][0..label.len], label);
            const th = s.transcript.current();
            @memcpy(content[64 + label.len ..][0..th.n], th.slice());
            var sig_buf: [128]u8 = undefined;
            const sig = sign(s.opts.key, content[0 .. 64 + label.len + th.n], &sig_buf) catch return s.fail(w, .internal_error);
            b.int(u8, @backingInt(msg.Type.certificate_verify)) catch return s.fail(w, .internal_error);
            b.begin(3) catch return s.fail(w, .internal_error);
            b.int(u16, @backingInt(s.scheme)) catch return s.fail(w, .internal_error);
            b.vec(2, sig) catch return s.fail(w, .internal_error);
            b.finish() catch return s.fail(w, .internal_error);
        }
        s.transcript.add(b.slice()[start_cv..]);
        const start_fin = b.len;
        const th = s.transcript.current();
        switch (s.kind) {
            inline else => |k| {
                const S = Sched(k);
                const vd = S.finished(s_hs.arr(S.hash_len), th.slice());
                b.int(u8, @backingInt(msg.Type.finished)) catch return s.fail(w, .internal_error);
                b.vec(3, &vd) catch return s.fail(w, .internal_error);
            },
        }
        s.transcript.add(b.slice()[start_fin..]);
        try s.sendSealed(w, .handshake, b.slice());
    }

    fn eeExtensions(s: *Server, b: *msg.Builder) msg.Error!void {
        if (s.host_len > 0) {
            // Section 3 of RFC 6066: an empty server_name.
            try b.int(u16, Ext.server_name);
            try b.int(u16, 0);
        }
        if (s.alpn_len > 0) {
            try b.int(u16, Ext.alpn);
            try b.begin(2);
            try b.begin(2);
            try b.vec(1, s.alpn[0..s.alpn_len]);
            try b.finish();
            try b.finish();
        }
    }

    fn certificate(s: *Server, b: *msg.Builder) msg.Error!void {
        try b.int(u8, @backingInt(msg.Type.certificate));
        try b.begin(3);
        try b.vec(1, "");
        try b.begin(3);
        for (s.opts.chain) |c| {
            try b.vec(3, c);
            try b.vec(2, "");
        }
        try b.finish();
        try b.finish();
    }

    fn finished(s: *Server, w: *Writer, m: []const u8, body: []const u8) Error!void {
        const th = s.transcript.current();
        var want: Secret = .{};
        switch (s.kind) {
            inline else => |k| {
                const S = Sched(k);
                want = Secret.of(S.finished(s.c_hs.arr(S.hash_len), th.slice()));
            },
        }
        if (body.len != want.n or !std.crypto.timing_safe.eql([48]u8, padded(body), want.b)) return s.fail(w, .decrypt_error);
        if (!s.asm_.empty()) return s.fail(w, .unexpected_message);
        s.transcript.add(m);
        switch (s.kind) {
            inline else => |k| {
                const S = Sched(k);
                const ms = s.res_secret;
                s.res_secret = Secret.of(S.deriveSecret(ms.arr(S.hash_len), "res master", s.transcript.current().slice()));
            },
        }
        s.read = record.Protection.init(s.suite, s.c_ap.slice());
        std.crypto.secureZero(u8, &s.c_hs.b);
        std.crypto.secureZero(u8, &s.c_ap.b);
        s.state = .connected;
        if (builtin.is_test) if (s.opts.test_ticket) |t| try s.sendSealed(w, .handshake, t);
    }

    fn sendKeyUpdate(s: *Server, w: *Writer) Error!void {
        try s.sendSealed(w, .handshake, &.{ @backingInt(msg.Type.key_update), 0, 0, 1, 0 });
        s.write_p.?.update();
    }

    /// Seals application data in records of at most 2^14 bytes. The
    /// server can write after its first flight, before the Finished of
    /// the client (section 4.4.4: 0.5-RTT data).
    pub fn write(s: *Server, w: *Writer, data: []const u8) Error!void {
        if ((s.state != .connected and s.state != .wait_finished) or s.write_closed) return error.BadState;
        var rest = data;
        while (true) {
            if (s.write_p.?.needsUpdate()) try s.sendKeyUpdate(w);
            const n = @min(rest.len, record.max_plaintext);
            try s.sendSealed(w, .application_data, rest[0..n]);
            rest = rest[n..];
            if (rest.len == 0) break;
        }
    }

    /// Sends close_notify.
    pub fn close(s: *Server, w: *Writer) Error!void {
        if (s.write_p == null or s.write_closed) return;
        try s.sendSealed(w, .alert, &.{ 1, 0 });
        s.write_closed = true;
    }
};

fn padded(b: []const u8) [48]u8 {
    var out: [48]u8 = @splat(0);
    @memcpy(out[0..@min(b.len, 48)], b[0..@min(b.len, 48)]);
    return out;
}

/// The signature of `content` with `key`, in the form of TLS: DER for
/// ECDSA, 64 bytes for Ed25519.
pub fn sign(key: pem.PrivateKey, content: []const u8, out: *[128]u8) ![]const u8 {
    switch (key) {
        inline .p256, .p384 => |k, tag| {
            const E = if (tag == .p256) std.crypto.sign.ecdsa.EcdsaP256Sha256 else std.crypto.sign.ecdsa.EcdsaP384Sha384;
            const kp = try E.KeyPair.fromSecretKey(try E.SecretKey.fromBytes(k));
            const sig = try kp.sign(content, null);
            var der: [E.Signature.der_encoded_length_max]u8 = undefined;
            const d = sig.toDer(&der);
            @memcpy(out[0..d.len], d);
            return out[0..d.len];
        },
        .ed25519 => |seed| {
            const Ed = std.crypto.sign.Ed25519;
            const kp = try Ed.KeyPair.generateDeterministic(seed);
            const sig = try kp.sign(content, null);
            out[0..64].* = sig.toBytes();
            return out[0..64];
        },
    }
}

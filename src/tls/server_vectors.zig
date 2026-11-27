//! The server side of the RFC 8448 traces of section 3 (a simple 1-RTT
//! handshake), section 5 (a HelloRetryRequest), and section 7 (the
//! compatibility mode).
//!
//! The random and the private key of the server come from the trace,
//! and so do the suite and the group of the ServerHello. The server gets
//! each record of the client, and each record that it writes must match
//! the next record of the server in the trace, byte for byte.
//!
//! The trace has parts that the server does not make itself, so the test
//! gives them as test options: the extensions of the EncryptedExtensions
//! (NSS sends supported_groups and record_size_limit), the
//! CertificateVerify (the key of the RFC is RSA 1024), the cookie of the
//! HelloRetryRequest, and the NewSessionTicket of section 3.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const server = @import("server.zig");
const msg = @import("messages.zig");
const tcrypto = @import("crypto.zig");
const record = @import("record.zig");

const data = @embedFile("testdata/rfc8448.txt");

const Step = struct {
    client: bool,
    what: []const u8,
    rec: []const u8,
    payload: []const u8,
};

fn hexAlloc(a: std.mem.Allocator, h: []const u8) ![]u8 {
    const out = try a.alloc(u8, h.len / 2);
    _ = try std.fmt.hexToBytes(out, h);
    return out;
}

fn replay(a: std.mem.Allocator, section: []const u8) !void {
    var steps: std.ArrayList(Step) = .empty;
    var ent: server.Entropy = std.mem.zeroes(server.Entropy);
    var sh: ?[]const u8 = null;
    var hrr: ?[]const u8 = null;
    var ee: []const u8 = "";
    var cert: []const u8 = "";
    var cv: []const u8 = "";
    var ticket: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var in_section = false;
    var side_client = false;
    var what: []const u8 = "";
    var payload: []const u8 = "";
    var key_kind: enum { none, x25519, p256 } = .none;
    while (lines.next()) |line| {
        if (line.len < 2) continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const tag = f.next().?;
        if (tag[0] == 'S') {
            in_section = std.mem.eql(u8, f.next().?, section);
            side_client = std.mem.eql(u8, f.next().?, "client");
            what = f.rest();
            key_kind = if (std.mem.indexOf(u8, what, "x25519 key pair") != null) .x25519 else if (std.mem.indexOf(u8, what, "P-256 key pair") != null) .p256 else .none;
            continue;
        }
        if (!in_section) continue;
        const name = f.next().?;
        const val = f.next() orelse "";
        if (!side_client) {
            if (std.mem.eql(u8, name, "private_key")) switch (key_kind) {
                .x25519 => _ = try std.fmt.hexToBytes(&ent.x25519, val),
                .p256 => _ = try std.fmt.hexToBytes(&ent.p256, val),
                .none => {},
            };
            if (std.mem.eql(u8, name, "ServerHello")) {
                const m = try hexAlloc(a, val);
                // The random of a HelloRetryRequest is the fixed value.
                if (std.mem.eql(u8, m[6..38], &@import("client.zig").hrr_random)) hrr = m else sh = m;
            }
            if (std.mem.eql(u8, name, "EncryptedExtensions")) ee = try hexAlloc(a, val);
            if (std.mem.eql(u8, name, "Certificate")) cert = try hexAlloc(a, val);
            if (std.mem.eql(u8, name, "CertificateVerify")) cv = try hexAlloc(a, val);
            if (std.mem.eql(u8, name, "NewSessionTicket")) ticket = try hexAlloc(a, val);
        }
        if (std.mem.eql(u8, name, "payload")) payload = try hexAlloc(a, val);
        if (std.mem.eql(u8, name, "complete_record")) {
            try steps.append(a, .{ .client = side_client, .what = what, .rec = try hexAlloc(a, val), .payload = payload });
        }
    }
    // The ServerHello: type and length (4), version (2), random (32),
    // session ID, suite, compression, and extensions.
    const shm = sh.?;
    @memcpy(&ent.random, shm[6..38]);
    var r = msg.Reader.init(shm[4..]);
    _ = try r.bytes(34);
    _ = try r.vec(u8, 0, 32);
    const suite: record.Suite = @fromBackingInt(@intCast(try r.int(u16)));
    _ = try r.int(u8);
    var exts = try r.sub(u16, 0, 0xffff);
    var group: tcrypto.Group = .x25519;
    while (!exts.done()) {
        const et = try exts.int(u16);
        var b = try exts.sub(u16, 0, 0xffff);
        if (et == msg.ExtType.key_share) group = @fromBackingInt(@intCast(try b.int(u16)));
    }
    var cookie: ?[]const u8 = null;
    if (hrr) |m| {
        var hr = msg.Reader.init(m[4..]);
        _ = try hr.bytes(34);
        _ = try hr.vec(u8, 0, 32);
        _ = try hr.bytes(3);
        var he = try hr.sub(u16, 0, 0xffff);
        while (!he.done()) {
            const et = try he.int(u16);
            const body = try he.vec(u16, 0, 0xffff);
            if (et == msg.ExtType.cookie) cookie = body;
        }
    }
    // The certificate of the Certificate message: the context (1), the
    // length of the list (3), and the length of the entry (3).
    var cr = msg.Reader.init(cert[4..]);
    _ = try cr.vec(u8, 0, 255);
    var list = try cr.sub(u24, 1, 0xffffff);
    const leaf = try list.vec(u24, 1, 0xffffff);
    const chain = [_][]const u8{leaf};
    const s = try a.create(server.Server);
    s.init(.{
        .chain = &chain,
        .key = .{ .ed25519 = @splat(0) },
        .suites = &.{suite},
        .groups = &.{group},
        .test_cert_verify = cv,
        .test_ee = ee[4..],
        .test_hrr_cookie = cookie,
        .test_ticket = ticket,
    }, ent);
    var out: std.Io.Writer.Allocating = .init(a);
    var events: usize = 0;
    var data_seen = false;
    for (steps.items) |st| {
        if (st.client) {
            const ev = try s.handleRecord(&out.writer, st.rec);
            switch (ev) {
                .none => {},
                .handshake_done, .closed => events += 1,
                .data => |d| {
                    try std.testing.expectEqualSlices(u8, st.payload, d);
                    data_seen = true;
                },
            }
        } else {
            if (std.mem.indexOf(u8, st.what, "application_data") != null) {
                try s.write(&out.writer, st.payload);
            } else if (std.mem.indexOf(u8, st.what, "alert") != null) {
                try s.close(&out.writer);
            }
            const got = out.written();
            if (!std.mem.startsWith(u8, got, st.rec)) {
                std.debug.print("section {s}: the record of '{s}' differs\nwant {x}\ngot  {x}\n", .{ section, st.what, st.rec, got });
                return error.TestUnexpectedResult;
            }
            const rest = try a.dupe(u8, got[st.rec.len..]);
            out.clearRetainingCapacity();
            try out.writer.writeAll(rest);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expectEqual(@as(usize, 2), events);
    var want_data = false;
    for (steps.items) |st| want_data = want_data or (st.client and std.mem.indexOf(u8, st.what, "application_data") != null);
    try std.testing.expectEqual(want_data, data_seen);
}

test "RFC 8448 section 3 from the server side" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try replay(arena.allocator(), "3");
}

test "RFC 8448 section 5 (HelloRetryRequest) from the server side" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try replay(arena.allocator(), "5");
}

test "RFC 8448 section 7 (compatibility mode) from the server side" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try replay(arena.allocator(), "7");
}

/// A ClientHello record with the given extensions block, a random of
/// zeros, no session ID, and the suite TLS_AES_128_GCM_SHA256.
fn helloRecord(buf: []u8, exts: []const u8) ![]const u8 {
    var b = msg.Builder.init(buf[record.header_len..]);
    try b.int(u8, 1);
    try b.begin(3);
    try b.int(u16, 0x0303);
    try b.put(&@as([32]u8, @splat(0)));
    try b.vec(1, "");
    try b.vec(2, &.{ 0x13, 0x01 });
    try b.vec(1, &.{0});
    try b.vec(2, exts);
    try b.finish();
    const n = b.slice().len;
    buf[0..5].* = .{ 22, 3, 1, @intCast(n >> 8), @intCast(n & 0xff) };
    return buf[0 .. record.header_len + n];
}

test "a TLS 1.2 ClientHello gets protocol_version" {
    var s: server.Server = undefined;
    s.init(.{ .chain = &.{}, .key = .{ .ed25519 = @splat(0) } }, std.mem.zeroes(server.Entropy));
    var buf: [256]u8 = undefined;
    // Only supported_groups: no supported_versions.
    const rec = try helloRecord(&buf, &.{ 0, 10, 0, 4, 0, 2, 0, 29 });
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.AlertSent, s.handleRecord(&out.writer, rec));
    try std.testing.expectEqual(record.Alert.protocol_version, s.sent_alert.?);
    try std.testing.expectEqualSlices(u8, &.{ 21, 3, 3, 0, 2, 2, 70 }, out.written());
}

const client = @import("client.zig");
const pem = @import("pem.zig");
const roots = @import("roots.zig");

/// Runs a client of `client.zig` against the server in memory, with a
/// key and a self-signed certificate of `testdata/server/`. The leaf is
/// not a CA, so the client skips the chain check. It still checks the
/// CertificateVerify with the key of the leaf.
fn loopback(a: std.mem.Allocator, pem_text: []const u8, suite: record.Suite, server_groups: []const tcrypto.Group, alpn: bool) !void {
    var it = pem.Iterator.init(pem_text);
    const cert = (try it.next(a)).?;
    const key = try pem.privateKey((try it.next(a)).?);
    var store = roots.Roots.init(a);
    _ = try store.addPem(pem_text);
    const chain = [_][]const u8{cert.der};
    const protos = [_][]const u8{ "h2", "http/1.1" };
    var s_ent: server.Entropy = undefined;
    var c_ent: client.Entropy = undefined;
    std.testing.io.random(std.mem.asBytes(&s_ent));
    std.testing.io.random(std.mem.asBytes(&c_ent));
    const s = try a.create(server.Server);
    s.init(.{ .chain = &chain, .key = key, .groups = server_groups, .alpn = if (alpn) protos[1..] else &.{} }, s_ent);
    const c = try a.create(client.Client);
    c.init(.{ .host = "localhost.test", .roots = store.slice(), .now = 1_800_000_000, .verify_chain = false, .suites = &.{suite}, .alpn = if (alpn) &protos else &.{} }, c_ent);
    var to_s: std.Io.Writer.Allocating = .init(a);
    var to_c: std.Io.Writer.Allocating = .init(a);
    try c.hello(&to_s.writer);
    var c_done = false;
    var s_done = false;
    var got_c: std.ArrayList(u8) = .empty;
    var got_s: std.ArrayList(u8) = .empty;
    var rounds: usize = 0;
    while (rounds < 20) : (rounds += 1) {
        // Each side reads all whole records that the other side wrote.
        const for_s = try a.dupe(u8, to_s.written());
        to_s.clearRetainingCapacity();
        var rest: []const u8 = for_s;
        while (rest.len >= 5) {
            const n = 5 + @as(usize, std.mem.readInt(u16, rest[3..5], .big));
            switch (try s.handleRecord(&to_c.writer, rest[0..n])) {
                .handshake_done => s_done = true,
                .data => |d| try got_s.appendSlice(a, d),
                else => {},
            }
            rest = rest[n..];
        }
        const for_c = try a.dupe(u8, to_c.written());
        to_c.clearRetainingCapacity();
        rest = for_c;
        while (rest.len >= 5) {
            const n = 5 + @as(usize, std.mem.readInt(u16, rest[3..5], .big));
            switch (try c.handleRecord(&to_s.writer, rest[0..n])) {
                .handshake_done => {
                    c_done = true;
                    try c.write(&to_s.writer, "ping");
                },
                .data => |d| try got_c.appendSlice(a, d),
                else => {},
            }
            rest = rest[n..];
        }
        if (s_done and got_s.items.len == 4 and got_c.items.len == 0) {
            const big: [20000]u8 = @splat(0x70);
            try s.write(&to_c.writer, &big);
        }
        if (got_c.items.len == 20000) break;
    }
    try std.testing.expect(c_done and s_done);
    try std.testing.expectEqualStrings("ping", got_s.items);
    try std.testing.expectEqual(@as(usize, 20000), got_c.items.len);
    try std.testing.expectEqual(suite, c.negotiatedSuite());
    if (alpn) {
        try std.testing.expectEqualStrings("http/1.1", c.protocol().?);
        try std.testing.expectEqualStrings("http/1.1", s.protocol().?);
    }
    try std.testing.expectEqualStrings("localhost.test", s.serverName().?);
}

test "the client of client.zig and the server, for each key, suite, and group" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = [_][]const u8{ @embedFile("testdata/server/p256.pem"), @embedFile("testdata/server/p384.pem"), @embedFile("testdata/server/ed25519.pem") };
    for (keys) |k| {
        for (client.default_suites) |suite| try loopback(a, k, suite, &.{.x25519}, false);
    }
    // The client sends an X25519 share only, so P-256 and P-384 need a
    // HelloRetryRequest.
    try loopback(a, keys[0], .aes_128_gcm_sha256, &.{.secp256r1}, false);
    try loopback(a, keys[0], .aes_256_gcm_sha384, &.{.secp384r1}, true);
}

//! The client side of the RFC 8448 traces of section 3 (a simple 1-RTT
//! handshake), section 5 (a HelloRetryRequest), and section 7 (the
//! compatibility mode).
//!
//! The test reads the first ClientHello of the trace, and gets the
//! session ID, the suites, the groups, the signature schemes, and the order of the
//! extensions from it. The random and the private keys of the client
//! come from the trace. The client must write the same ClientHello. It
//! then gets each record of the server, and each record that it writes
//! must match the next record of the client in the trace: the second
//! ClientHello, the Finished, the application data, and the alert. NSS
//! wrote the traces, so the layout has the cookie after the signature
//! algorithms and the padding of RFC 7685 at the end.
//!
//! The certificate of the RFC has an RSA key of 1024 bits, and its
//! dates are past, so the test skips the chain and the signature.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const client = @import("client.zig");
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

/// A change of one byte of a record of the server, and the alert that
/// the client must send.
const Change = struct {
    /// The count of server records before the record.
    record: usize,
    /// The place of the byte. A negative place counts from the end.
    at: isize,
    /// The XOR of the byte.
    mask: u8,
    alert: record.Alert,
};

fn replay(a: std.mem.Allocator, section: []const u8) !void {
    return replayChanged(a, section, null);
}

fn replayChanged(a: std.mem.Allocator, section: []const u8, change: ?Change) !void {
    var steps: std.ArrayList(Step) = .empty;
    var ent: client.Entropy = std.mem.zeroes(client.Entropy);
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
        if (side_client and std.mem.eql(u8, name, "private_key")) {
            switch (key_kind) {
                .x25519 => _ = try std.fmt.hexToBytes(&ent.x25519, val),
                .p256 => _ = try std.fmt.hexToBytes(&ent.p256, val),
                .none => {},
            }
        }
        if (std.mem.eql(u8, name, "payload")) payload = try hexAlloc(a, val);
        if (std.mem.eql(u8, name, "complete_record")) {
            try steps.append(a, .{ .client = side_client, .what = what, .rec = try hexAlloc(a, val), .payload = payload });
        }
    }
    // The options from the first ClientHello of the trace.
    const ch = steps.items[0].rec[record.header_len..];
    var r = msg.Reader.init(ch[4..]);
    _ = try r.int(u16);
    @memcpy(&ent.random, try r.bytes(32));
    const sid = try r.vec(u8, 0, 32);
    if (sid.len == 32) @memcpy(&ent.session_id, sid);
    var suites: std.ArrayList(record.Suite) = .empty;
    var sr = try r.sub(u16, 2, 0xffff);
    while (!sr.done()) try suites.append(a, @fromBackingInt(@intCast(try sr.int(u16))));
    _ = try r.vec(u8, 1, 1);
    var exts = try r.sub(u16, 0, 0xffff);
    var layout: std.ArrayList(client.HelloExt) = .empty;
    var groups: std.ArrayList(tcrypto.Group) = .empty;
    var schemes: std.ArrayList(tcrypto.Scheme) = .empty;
    var shares: std.ArrayList(tcrypto.Group) = .empty;
    var host: ?[]const u8 = null;
    while (!exts.done()) {
        const et = try exts.int(u16);
        const body = try exts.vec(u16, 0, 0xffff);
        var b = msg.Reader.init(body);
        switch (et) {
            msg.ExtType.server_name => {
                var l = try b.sub(u16, 1, 0xffff);
                _ = try l.int(u8);
                host = try l.vec(u16, 1, 0xffff);
                try layout.append(a, .server_name);
            },
            msg.ExtType.supported_groups => {
                var l = try b.sub(u16, 2, 0xffff);
                while (!l.done()) try groups.append(a, @fromBackingInt(@intCast(try l.int(u16))));
                try layout.append(a, .supported_groups);
            },
            msg.ExtType.signature_algorithms => {
                var l = try b.sub(u16, 2, 0xffff);
                while (!l.done()) try schemes.append(a, @fromBackingInt(@intCast(try l.int(u16))));
                // NSS puts the cookie of a second ClientHello after the
                // signature algorithms, and pads the second ClientHello.
                try layout.append(a, .signature_algorithms);
                try layout.append(a, .cookie);
            },
            msg.ExtType.key_share => {
                var l = try b.sub(u16, 0, 0xffff);
                while (!l.done()) {
                    try shares.append(a, @fromBackingInt(@intCast(try l.int(u16))));
                    _ = try l.vec(u16, 1, 0xffff);
                }
                try layout.append(a, .key_share);
            },
            msg.ExtType.supported_versions => try layout.append(a, .supported_versions),
            msg.ExtType.psk_key_exchange_modes => try layout.append(a, .psk_key_exchange_modes),
            else => try layout.append(a, .{ .raw = .{ .type = et, .body = body } }),
        }
    }
    try layout.append(a, .padding);
    var c: client.Client = undefined;
    c.init(.{
        .host = host,
        .suites = suites.items,
        .groups = groups.items,
        .key_shares = shares.items,
        .schemes = schemes.items,
        .layout = layout.items,
        .compat = sid.len != 0,
        .test_skip_signature = true,
    }, ent);
    var out: std.Io.Writer.Allocating = .init(a);
    try c.hello(&out.writer);
    var want_i: usize = 0;
    var got_events: usize = 0;
    var data_seen = false;
    var server_i: usize = 0;
    for (steps.items) |s| {
        if (s.client) {
            if (std.mem.indexOf(u8, s.what, "application_data") != null) {
                try c.write(&out.writer, s.payload);
            } else if (std.mem.indexOf(u8, s.what, "alert") != null) {
                try c.close(&out.writer);
            }
            // Each record of the client, in order.
            const got = out.written();
            if (!std.mem.startsWith(u8, got, s.rec)) {
                std.debug.print("section {s}: the record of '{s}' differs\nwant {x}\ngot  {x}\n", .{ section, s.what, s.rec, got });
                return error.TestUnexpectedResult;
            }
            const rest = try a.dupe(u8, got[s.rec.len..]);
            out.clearRetainingCapacity();
            try out.writer.writeAll(rest);
            want_i += 1;
        } else {
            const rec = s.rec;
            if (change) |chg| if (chg.record == server_i) {
                const m = try a.dupe(u8, s.rec);
                const at: usize = if (chg.at < 0) m.len - @as(usize, @intCast(-chg.at)) else @intCast(chg.at);
                m[at] ^= chg.mask;
                try std.testing.expectError(error.AlertSent, c.handleRecord(&out.writer, m));
                try std.testing.expectEqual(chg.alert, c.sent_alert.?);
                return;
            };
            server_i += 1;
            const ev = try c.handleRecord(&out.writer, rec);
            switch (ev) {
                .none => {},
                .handshake_done => got_events += 1,
                .data => |d| {
                    try std.testing.expectEqualSlices(u8, s.payload, d);
                    data_seen = true;
                },
                .closed => got_events += 1,
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expectEqual(@as(usize, 2), got_events);
    var want_data = false;
    for (steps.items) |s| want_data = want_data or (!s.client and std.mem.indexOf(u8, s.what, "application_data") != null);
    try std.testing.expectEqual(want_data, data_seen);
}

test "RFC 8448 section 3 from the client side" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try replay(arena.allocator(), "3");
}

test "RFC 8448 section 5 (HelloRetryRequest) from the client side" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try replay(arena.allocator(), "5");
}

test "RFC 8448 section 7 (compatibility mode) from the client side" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try replay(arena.allocator(), "7");
}

test "changed records of the server give the alerts of the RFC" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The ServerHello: the header (5), the message header (4), the
    // version (2), the random (32), the session ID (1), and the suite.
    try replayChanged(a, "3", .{ .record = 0, .at = 45, .mask = 0x05, .alert = .illegal_parameter });
    try replayChanged(a, "3", .{ .record = 0, .at = 9, .mask = 0x01, .alert = .protocol_version });
    try replayChanged(a, "3", .{ .record = 0, .at = 0, .mask = 0x02, .alert = .unexpected_message });
    // The suite 0x1304, the version 0x0203, a record of type 20 (CCS).
    // The tag of the encrypted flight.
    try replayChanged(a, "3", .{ .record = 1, .at = -1, .mask = 0x01, .alert = .bad_record_mac });
    // The application data before the handshake ends: a plain record of
    // type 23 in place of the ServerHello.
    try replayChanged(a, "3", .{ .record = 0, .at = 0, .mask = 0x01, .alert = .unexpected_message });
}

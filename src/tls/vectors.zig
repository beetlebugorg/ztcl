//! The traces of RFC 8448 against the key schedule and the record layer.
//!
//! `testdata/rfc8448.txt` has each step of the five traces of the RFC:
//! the simple 1-RTT handshake (section 3), the resumed 0-RTT handshake
//! (4), the HelloRetryRequest (5), the client authentication (6), and
//! the compatibility mode (7). `tools/rfc8448-vectors.py` makes it from
//! the text of the RFC. The test replays each trace:
//!
//! - Each HKDF-Extract and each HKDF-Expand-Label: the `HkdfLabel`
//!   bytes, and the output.
//! - The transcript hash of each traffic secret and of each Finished:
//!   the hash of the handshake messages of the trace so far, with the
//!   `message_hash` of section 4.4.1 after a HelloRetryRequest.
//! - Each Finished and the PSK binder: the HMAC of the finished key.
//! - Each traffic key and IV.
//! - Each record: the plain framing, or the seal with the current key and
//!   sequence number of the sender. The open of each sealed record gives
//!   the payload again.
//! - The X25519 public key of each private key.
//!
//! The trace keys are known by the side that writes with them. A step
//! "derive read traffic keys" of one side gives the write keys of the
//! other side. A step "derive write traffic keys" makes the keys the
//! current keys of the side, with the sequence number zero.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const schedule = @import("schedule.zig");
const record = @import("record.zig");
const S = schedule.Sha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

const data = @embedFile("testdata/rfc8448.txt");

/// The random of a HelloRetryRequest: SHA-256 of "HelloRetryRequest".
const hrr_random = blk: {
    @setEvalBranchQuota(10_000);
    var h: [32]u8 = undefined;
    Sha256.hash("HelloRetryRequest", &h, .{});
    break :blk h;
};

const Side = enum { client, server };

const Step = struct {
    section: u8,
    side: Side,
    text: []const u8,
    names: [12][]const u8 = undefined,
    values: [12][]const u8 = undefined,
    n: usize = 0,

    fn get(s: *const Step, name: []const u8) ?[]const u8 {
        for (s.names[0..s.n], s.values[0..s.n]) |k, v| if (std.mem.eql(u8, k, name)) return v;
        return null;
    }

    fn must(s: *const Step, name: []const u8) []const u8 {
        return s.get(name) orelse std.debug.panic("section {d} {s} \"{s}\": no value {s}", .{ s.section, @tagName(s.side), s.text, name });
    }
};

const Epoch = enum { early, handshake, application };

fn epochOf(text: []const u8) Epoch {
    if (std.mem.indexOf(u8, text, "early application data") != null) return .early;
    if (std.mem.indexOf(u8, text, "handshake data") != null) return .handshake;
    if (std.mem.indexOf(u8, text, "application data") != null) return .application;
    std.debug.panic("no epoch in \"{s}\"", .{text});
}

const State = struct {
    a: std.mem.Allocator,
    transcript: std.ArrayList(u8) = .empty,
    /// The keys of each writer and epoch.
    keys: [2][3]?record.Protection = .{ .{ null, null, null }, .{ null, null, null } },
    current: [2]?record.Protection = .{ null, null },
    checks: usize = 0,
    /// The last message of the transcript.
    last: []const u8 = &.{},

    fn hash(st: *State) [32]u8 {
        var h: [32]u8 = undefined;
        Sha256.hash(st.transcript.items, &h, .{});
        return h;
    }
};

fn eq(st: *State, s: *const Step, what: []const u8, want: []const u8, got: []const u8) !void {
    st.checks += 1;
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("section {d} {s} \"{s}\": {s} differs\n  want {x}\n  got  {x}\n", .{ s.section, @tagName(s.side), s.text, what, want, got });
        return error.TestExpectedEqual;
    }
}

/// The label of a step, with no "tls13 " prefix.
fn labelOf(text: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, text, '"') orelse return null;
    const e = std.mem.indexOfScalarPos(u8, text, q + 1, '"') orelse return null;
    const l = text[q + 1 .. e];
    return if (std.mem.startsWith(u8, l, "tls13 ")) l[6..] else l;
}

/// The labels whose context is the transcript hash.
const transcript_labels = [_][]const u8{ "c hs traffic", "s hs traffic", "c ap traffic", "s ap traffic", "exp master", "res master", "c e traffic", "e exp master" };

fn run(st: *State, s: *const Step) !void {
    const t = s.text;
    const me = @backingInt(s.side);
    if (std.mem.startsWith(u8, t, "extract secret")) {
        if (s.n == 0) return;
        const salt = s.must("salt");
        const zeros: [32]u8 = @splat(0);
        const got = S.extract(if (std.mem.eql(u8, salt, "0")) &zeros else salt, s.must("IKM"));
        return eq(st, s, "secret", s.must("secret"), &got);
    }
    if (std.mem.startsWith(u8, t, "derive secret") or std.mem.startsWith(u8, t, "generate resumption secret") or
        std.mem.startsWith(u8, t, "calculate finished") or std.mem.startsWith(u8, t, "calculate PSK binder"))
    {
        if (s.n == 0) return;
        const label = if (std.mem.startsWith(u8, t, "calculate PSK binder")) "finished" else labelOf(t).?;
        const prk = s.must("PRK")[0..32].*;
        const ctx = s.must("hash");
        const want = s.must("expanded");
        var buf: [schedule.max_info]u8 = undefined;
        try eq(st, s, "info", s.must("info"), schedule.hkdfLabel(&buf, @intCast(want.len), label, ctx));
        var got: [64]u8 = undefined;
        S.expandLabel(got[0..want.len], prk, label, ctx);
        try eq(st, s, "expanded", want, got[0..want.len]);
        for (transcript_labels) |tl| {
            if (std.mem.eql(u8, tl, label)) try eq(st, s, "transcript hash", ctx, &st.hash());
        }
        if (s.get("finished")) |fin| {
            const th = if (s.get("binder_hash")) |bh| blk: {
                var h: [32]u8 = undefined;
                Sha256.hash(s.must("ClientHello_prefix"), &h, .{});
                try eq(st, s, "binder hash", bh, &h);
                break :blk h;
            } else st.hash();
            try eq(st, s, "finished", fin, &S.finished(prk, &th));
        }
        return;
    }
    if (std.mem.startsWith(u8, t, "derive write traffic keys") or std.mem.startsWith(u8, t, "derive read traffic keys")) {
        const write = std.mem.startsWith(u8, t, "derive write");
        const writer = if (write) me else 1 - me;
        const ep = @backingInt(epochOf(t));
        if (s.n != 0) {
            const p = record.Protection.init(.aes_128_gcm_sha256, s.must("PRK"));
            var buf: [schedule.max_info]u8 = undefined;
            try eq(st, s, "key info", s.must("key_info"), schedule.hkdfLabel(&buf, 16, "key", ""));
            try eq(st, s, "iv info", s.must("iv_info"), schedule.hkdfLabel(&buf, 12, "iv", ""));
            try eq(st, s, "key", s.must("key_expanded"), p.key[0..16]);
            try eq(st, s, "iv", s.must("iv_expanded"), &p.iv);
            st.keys[writer][ep] = p;
        }
        if (write) {
            st.current[me] = st.keys[me][ep] orelse std.debug.panic("section {d}: no keys yet for \"{s}\"", .{ s.section, t });
        }
        return;
    }
    if (std.mem.startsWith(u8, t, "send ")) {
        const payload = s.must("payload");
        const want = s.must("complete_record");
        const ct: record.ContentType = if (std.mem.startsWith(u8, t, "send handshake")) .handshake else if (std.mem.startsWith(u8, t, "send alert")) .alert else if (std.mem.startsWith(u8, t, "send application_data")) .application_data else if (std.mem.startsWith(u8, t, "send change_cipher_spec")) .change_cipher_spec else std.debug.panic("record type of \"{s}\"", .{t});
        var buf: [record.max_record]u8 = undefined;
        if (st.current[me] == null or ct == .change_cipher_spec) {
            const version = std.mem.readInt(u16, want[1..3], .big);
            try eq(st, s, "plain record", want, try record.writePlain(&buf, ct, version, payload));
            try record.checkPlain(record.Header.parse(want[0..5]));
            // Section 4 constructs the ClientHello up to its binders, the
            // prefix of the PSK binder. The record has the whole message.
            if (ct == .handshake and st.last.len < payload.len and std.mem.eql(u8, st.last, payload[0..st.last.len])) {
                try st.transcript.appendSlice(st.a, payload[st.last.len..]);
            }
            return;
        }
        const p = &st.current[me].?;
        var reader = p.*;
        try eq(st, s, "sealed record", want, try p.seal(&buf, ct, payload, 0));
        var out: [record.max_record]u8 = undefined;
        const got = try reader.open(&out, want);
        try eq(st, s, "opened payload", payload, got.data);
        if (got.type != ct) return error.TestExpectedEqual;
        return;
    }
    if (std.mem.startsWith(u8, t, "construct ")) {
        if (s.n == 0) return;
        const msg = s.values[0];
        if (std.mem.indexOf(u8, t, "NewSessionTicket") != null) return;
        if (std.mem.indexOf(u8, t, "ServerHello") != null and std.mem.eql(u8, msg[6..38], &hrr_random)) {
            // Section 4.4.1: the first ClientHello becomes message_hash.
            var h = st.hash();
            st.transcript.clearRetainingCapacity();
            try st.transcript.appendSlice(st.a, &.{ 0xfe, 0, 0, 32 });
            try st.transcript.appendSlice(st.a, &h);
            h = undefined;
        }
        try st.transcript.appendSlice(st.a, msg);
        st.last = msg;
        return;
    }
    if (std.mem.startsWith(u8, t, "create an ephemeral x25519")) {
        const pk = std.crypto.dh.X25519.recoverPublicKey(s.must("private_key")[0..32].*);
        return eq(st, s, "public key", s.must("public_key"), &pk);
    }
}

test "the traces of RFC 8448" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var steps: std.ArrayList(Step) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len < 2) continue;
        var f = std.mem.splitScalar(u8, line[2..], ' ');
        if (line[0] == 'S') {
            const sec = try std.fmt.parseInt(u8, f.next().?, 10);
            const side = std.meta.stringToEnum(Side, f.next().?).?;
            try steps.append(a, .{ .section = sec, .side = side, .text = f.rest() });
        } else if (line[0] == 'V') {
            const s = &steps.items[steps.items.len - 1];
            const name = f.next().?;
            const hex = f.rest();
            const v = if (std.mem.eql(u8, hex, "-")) &.{} else if (std.mem.eql(u8, hex, "0")) try a.dupe(u8, "0") else try std.fmt.hexToBytes(try a.alloc(u8, hex.len / 2), hex);
            s.names[s.n] = name;
            s.values[s.n] = v;
            s.n += 1;
        }
    }
    var section: u8 = 0;
    var st: State = .{ .a = a };
    // Each trace makes at least 50 checks.
    var checks: [8]usize = @splat(0);
    for (steps.items) |*s| {
        if (s.section != section) {
            st = .{ .a = a };
            section = s.section;
        }
        try run(&st, s);
        checks[section] = st.checks;
    }
    for (3..8) |i| try std.testing.expect(checks[i] >= 50);
}

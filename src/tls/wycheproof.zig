//! Runs the Wycheproof test sets of the primitives of TLS 1.3.
//!
//!   tools/fetch-wycheproof.sh DIR
//!   zig build tls-wycheproof -- DIR
//!
//! The sets and the functions under test:
//!
//! - AES-GCM and ChaCha20-Poly1305: the AEADs of `record.zig`. AES-GCM
//!   runs with `std.crypto` and with each code of `aead.zig` that runs
//!   on the CPU.
//! - HKDF and HMAC with SHA-256 and SHA-384: the types of `schedule.zig`.
//! - X25519, ECDH on P-256 and P-384, ECDSA, Ed25519, RSASSA-PSS, and
//!   RSASSA-PKCS1-v1_5: `crypto.sharedSecret` and `crypto.verify`.
//!
//! A "valid" case must pass and an "invalid" case must fail. An
//! "acceptable" case can do either, and the run counts each result.
//! Two rules of TLS change the expected result:
//!
//! - TLS uses AES-GCM with a nonce of 12 bytes and a tag of 16 bytes,
//!   and AES with keys of 128 and 256 bits only. A group of other sizes
//!   is skipped.
//! - RFC 8446 section 4.2.8.2 allows uncompressed points only. A case
//!   with a compressed point must fail.
//!
//! The run fails when a case has the wrong result.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const tcrypto = @import("crypto.zig");
const schedule = @import("schedule.zig");
const aead = std.crypto.aead;
const fast = @import("aead.zig");
const Value = std.json.Value;

const Expect = enum { valid, invalid, acceptable };

const Count = struct {
    pass: usize = 0,
    fail: usize = 0,
    acceptable_pass: usize = 0,
    acceptable_fail: usize = 0,
    skip: usize = 0,
};

const Run = struct {
    a: std.mem.Allocator,
    file: []const u8,
    count: Count = .{},
    skip_reason: ?[]const u8 = null,

    fn check(r: *Run, t: Value, expect: Expect, ok: bool) void {
        switch (expect) {
            .acceptable => if (ok) {
                r.count.acceptable_pass += 1;
            } else {
                r.count.acceptable_fail += 1;
            },
            .valid, .invalid => if (ok == (expect == .valid)) {
                r.count.pass += 1;
            } else {
                r.count.fail += 1;
                std.debug.print("FAIL {s} tcId {d}: expected {s} ({s})\n", .{ r.file, int(t, "tcId"), @tagName(expect), str(t, "comment") });
            },
        }
    }
};

fn field(v: Value, name: []const u8) ?Value {
    return v.object.get(name);
}

fn str(v: Value, name: []const u8) []const u8 {
    const f = field(v, name) orelse return "";
    return if (f == .string) f.string else "";
}

fn int(v: Value, name: []const u8) i64 {
    const f = field(v, name) orelse return -1;
    return if (f == .integer) f.integer else -1;
}

fn hex(a: std.mem.Allocator, v: Value, name: []const u8) ![]u8 {
    const s = str(v, name);
    const out = try a.alloc(u8, s.len / 2);
    _ = try std.fmt.hexToBytes(out, s);
    return out;
}

fn expectOf(t: Value) Expect {
    return std.meta.stringToEnum(Expect, str(t, "result")) orelse .invalid;
}

fn hasFlag(t: Value, flag: []const u8) bool {
    const f = field(t, "flags") orelse return false;
    for (f.array.items) |x| if (x == .string and std.mem.eql(u8, x.string, flag)) return true;
    return false;
}

fn aeadCase(comptime A: type, a: std.mem.Allocator, t: Value) !bool {
    const key = try hex(a, t, "key");
    const iv = try hex(a, t, "iv");
    const ad = try hex(a, t, "aad");
    const msg = try hex(a, t, "msg");
    const ct = try hex(a, t, "ct");
    const tag = try hex(a, t, "tag");
    if (key.len != A.key_length or iv.len != A.nonce_length or tag.len != A.tag_length) return false;
    if (ct.len != msg.len) return false;
    const out = try a.alloc(u8, msg.len);
    var t2: [A.tag_length]u8 = undefined;
    A.encrypt(out, &t2, msg, ad, iv[0..A.nonce_length].*, key[0..A.key_length].*);
    const sealed = std.mem.eql(u8, out, ct) and std.mem.eql(u8, &t2, tag);
    const opened = if (A.decrypt(out, ct, tag[0..A.tag_length].*, ad, iv[0..A.nonce_length].*, key[0..A.key_length].*)) |_| std.mem.eql(u8, out, msg) else |_| false;
    const ok = sealed and opened;
    if (A == aead.chacha_poly.ChaCha20Poly1305) return ok;
    // AES-GCM again with each code of aead.zig that runs on this CPU. A
    // result that differs from std.crypto inverts the result of the case.
    defer fast.force(.unknown);
    for (std.enums.values(fast.Impl)) |i| {
        if (i == .unknown or !fast.available(i)) continue;
        fast.force(i);
        const g = fast.Gcm.init(key);
        g.seal(out, &t2, msg, ad, iv[0..12]);
        const s2 = std.mem.eql(u8, out, ct) and std.mem.eql(u8, &t2, tag);
        const o2 = if (g.open(out, ct, tag[0..16], ad, iv[0..12])) |_| std.mem.eql(u8, out, msg) else |_| false;
        if (s2 != sealed or o2 != opened) return !ok;
    }
    return ok;
}

fn runAead(r: *Run, groups: []const Value, chacha: bool) !void {
    for (groups) |g| {
        const ks = int(g, "keySize");
        const tests = field(g, "tests").?.array.items;
        if (int(g, "ivSize") != 96 or int(g, "tagSize") != 128 or (ks != 128 and ks != 256)) {
            r.count.skip += tests.len;
            r.skip_reason = "groups of a nonce, tag, or key size that TLS does not use";
            continue;
        }
        for (tests) |t| {
            const ok = if (chacha)
                try aeadCase(aead.chacha_poly.ChaCha20Poly1305, r.a, t)
            else if (ks == 128)
                try aeadCase(aead.aes_gcm.Aes128Gcm, r.a, t)
            else
                try aeadCase(aead.aes_gcm.Aes256Gcm, r.a, t);
            r.check(t, expectOf(t), ok);
        }
    }
}

fn runHkdf(comptime S: type, r: *Run, groups: []const Value) !void {
    for (groups) |g| for (field(g, "tests").?.array.items) |t| {
        const size: usize = @intCast(int(t, "size"));
        // RFC 5869 section 2.3: at most 255 blocks of output.
        const ok = if (size > 255 * S.hash_len) false else blk: {
            const prk = S.Hkdf.extract(try hex(r.a, t, "salt"), try hex(r.a, t, "ikm"));
            const out = try r.a.alloc(u8, size);
            S.Hkdf.expand(out, try hex(r.a, t, "info"), prk);
            break :blk std.mem.eql(u8, out, try hex(r.a, t, "okm"));
        };
        r.check(t, expectOf(t), ok);
    };
}

fn runHmac(comptime S: type, r: *Run, groups: []const Value) !void {
    for (groups) |g| {
        const tag_len: usize = @intCast(@divExact(int(g, "tagSize"), 8));
        for (field(g, "tests").?.array.items) |t| {
            var mac: [S.Hmac.mac_length]u8 = undefined;
            S.Hmac.create(&mac, try hex(r.a, t, "msg"), try hex(r.a, t, "key"));
            const tag = try hex(r.a, t, "tag");
            r.check(t, expectOf(t), tag.len == tag_len and tag_len <= mac.len and std.mem.eql(u8, mac[0..tag_len], tag));
        }
    }
}

fn runEcdh(r: *Run, groups: []const Value, g: tcrypto.Group) !void {
    for (groups) |grp| for (field(grp, "tests").?.array.items) |t| {
        var private = try hex(r.a, t, "private");
        const n = g.secretLen();
        // The sets give a NIST scalar as a DER integer, with a zero byte
        // in front when the top bit is set, or with fewer bytes.
        while (private.len > n and private[0] == 0) private = private[1..];
        if (private.len < n) {
            const p = try r.a.alloc(u8, n);
            @memset(p, 0);
            @memcpy(p[n - private.len ..], private);
            private = p;
        }
        const public = try hex(r.a, t, "public");
        var out: [tcrypto.max_secret]u8 = undefined;
        const got = tcrypto.sharedSecret(g, private, public, &out);
        const ok = if (got) |s| std.mem.eql(u8, s, try hex(r.a, t, "shared")) else |_| false;
        var expect = expectOf(t);
        if (g != .x25519 and public.len > 0 and (public[0] == 2 or public[0] == 3)) expect = .invalid;
        r.check(t, expect, ok);
    };
}

fn runVerify(r: *Run, groups: []const Value, scheme: tcrypto.Scheme) !void {
    for (groups) |g| {
        const pk = field(g, "publicKey").?;
        const key = switch (scheme) {
            .ed25519 => try hex(r.a, pk, "pk"),
            .ecdsa_secp256r1_sha256, .ecdsa_secp384r1_sha384 => try hex(r.a, pk, "uncompressed"),
            else => try hex(r.a, g, "publicKeyAsn"),
        };
        for (field(g, "tests").?.array.items) |t| {
            const ok = if (tcrypto.verify(scheme, key, try hex(r.a, t, "msg"), try hex(r.a, t, "sig"))) true else |_| false;
            r.check(t, expectOf(t), ok);
        }
    }
}

const Set = struct { file: []const u8, kind: Kind };
const Kind = union(enum) {
    aes_gcm,
    chacha,
    hkdf256,
    hkdf384,
    hmac256,
    hmac384,
    ecdh: tcrypto.Group,
    verify: tcrypto.Scheme,
};

/// Each file of `tools/fetch-wycheproof.sh`.
const sets = [_]Set{
    .{ .file = "aes_gcm_test.json", .kind = .aes_gcm },
    .{ .file = "chacha20_poly1305_test.json", .kind = .chacha },
    .{ .file = "hkdf_sha256_test.json", .kind = .hkdf256 },
    .{ .file = "hkdf_sha384_test.json", .kind = .hkdf384 },
    .{ .file = "hmac_sha256_test.json", .kind = .hmac256 },
    .{ .file = "hmac_sha384_test.json", .kind = .hmac384 },
    .{ .file = "x25519_test.json", .kind = .{ .ecdh = .x25519 } },
    .{ .file = "ecdh_secp256r1_ecpoint_test.json", .kind = .{ .ecdh = .secp256r1 } },
    .{ .file = "ecdh_secp384r1_ecpoint_test.json", .kind = .{ .ecdh = .secp384r1 } },
    .{ .file = "ecdsa_secp256r1_sha256_test.json", .kind = .{ .verify = .ecdsa_secp256r1_sha256 } },
    .{ .file = "ecdsa_secp384r1_sha384_test.json", .kind = .{ .verify = .ecdsa_secp384r1_sha384 } },
    .{ .file = "ed25519_test.json", .kind = .{ .verify = .ed25519 } },
    .{ .file = "rsa_pss_2048_sha256_mgf1_32_test.json", .kind = .{ .verify = .rsa_pss_rsae_sha256 } },
    .{ .file = "rsa_pss_2048_sha384_mgf1_48_test.json", .kind = .{ .verify = .rsa_pss_rsae_sha384 } },
    .{ .file = "rsa_signature_2048_sha256_test.json", .kind = .{ .verify = .rsa_pkcs1_sha256 } },
    .{ .file = "rsa_signature_2048_sha384_test.json", .kind = .{ .verify = .rsa_pkcs1_sha384 } },
    .{ .file = "rsa_pss_3072_sha256_mgf1_32_test.json", .kind = .{ .verify = .rsa_pss_rsae_sha256 } },
    .{ .file = "rsa_pss_4096_sha512_mgf1_64_test.json", .kind = .{ .verify = .rsa_pss_rsae_sha512 } },
    .{ .file = "rsa_signature_3072_sha256_test.json", .kind = .{ .verify = .rsa_pkcs1_sha256 } },
    .{ .file = "rsa_signature_4096_sha512_test.json", .kind = .{ .verify = .rsa_pkcs1_sha512 } },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: tls-wycheproof DIR\n", .{});
        std.process.exit(2);
    }
    var dir = try Io.Dir.cwd().openDir(io, args[1], .{});
    defer dir.close(io);
    var failed: usize = 0;
    for (sets) |set| {
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = dir.readFileAlloc(io, set.file, a, .limited(64 << 20)) catch |e| {
            std.debug.print("cannot read {s}: {t}\n", .{ set.file, e });
            std.process.exit(1);
        };
        const doc = try std.json.parseFromSliceLeaky(Value, a, text, .{});
        const groups = field(doc, "testGroups").?.array.items;
        var r: Run = .{ .a = a, .file = set.file };
        switch (set.kind) {
            .aes_gcm => try runAead(&r, groups, false),
            .chacha => try runAead(&r, groups, true),
            .hkdf256 => try runHkdf(schedule.Sha256, &r, groups),
            .hkdf384 => try runHkdf(schedule.Sha384, &r, groups),
            .hmac256 => try runHmac(schedule.Sha256, &r, groups),
            .hmac384 => try runHmac(schedule.Sha384, &r, groups),
            .ecdh => |g| try runEcdh(&r, groups, g),
            .verify => |s| try runVerify(&r, groups, s),
        }
        const c = r.count;
        std.debug.print("{s}: {d} pass, {d} fail, acceptable {d} pass {d} fail, {d} skipped{s}{s}\n", .{
            set.file,                                c.pass,                  c.fail, c.acceptable_pass, c.acceptable_fail, c.skip,
            if (r.skip_reason != null) ": " else "", r.skip_reason orelse "",
        });
        failed += c.fail;
    }
    if (failed > 0) {
        std.debug.print("{d} cases have the wrong result\n", .{failed});
        std.process.exit(1);
    }
}

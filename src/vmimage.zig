//! Signed guest images of `ztcl::vm` (ztcl#312, `docs/dev/vm-image.md`):
//! the manifest of an image release and the check of its signature.
//!
//! The signature is an SSH signature (`ssh-keygen -Y sign -n
//! ztcl-vm-image manifest.json`, the SSHSIG form of OpenSSH's
//! PROTOCOL.sshsig): an armored blob with the magic `SSHSIG`, version 1,
//! the public key, the namespace, a reserved string, the hash algorithm,
//! and the signature. The signed data is the magic, the namespace, the
//! reserved string, the hash algorithm, and the hash of the manifest.
//! This file takes only Ed25519 keys and SHA-512, and the namespace must
//! be `ztcl-vm-image`.
//!
//! ztcl trusts two keys of the release (current and next, for rotation)
//! and, in a test build or a Debug build with `-Dvm-test-key`, the test
//! key of `tools/vm-guest/testkey`. Anyone can sign with the test key,
//! which is in the repository, so it signs only a manifest whose name
//! ends in `-test`, never the name of a release image, and a build that
//! trusts it says so (`test_key_warning`). An embedder can add keys of
//! its own (`Host.image_keys` of `microvm.zig`); a key with `test_only`
//! signs only a name that ends in `-test`, as the test key does. A
//! manifest has a counter, and `verify` refuses a counter below the
//! highest that the store has seen.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const namespace = "ztcl-vm-image";

/// A trusted key. `test_only`: the key signs only a manifest whose name
/// ends in `-test`.
pub const Key = struct { name: []const u8, key: [32]u8, test_only: bool = false };

/// The 32 bytes of an `ssh-ed25519` public key in the base64 form of an
/// `authorized_keys` line.
pub fn sshKey(comptime b64: []const u8) [32]u8 {
    @setEvalBranchQuota(100_000);
    const D = std.base64.standard.Decoder;
    var blob: [D.calcSizeForSlice(b64) catch unreachable]u8 = undefined;
    D.decode(&blob, b64) catch unreachable;
    // string "ssh-ed25519", string key (32 bytes).
    if (blob.len != 51 or !std.mem.eql(u8, blob[4..15], "ssh-ed25519")) @compileError("not an ssh-ed25519 key");
    return blob[19..51].*;
}

/// The keys of the release. The fingerprints are in docs/dev/vm-image.md.
pub const release_keys = [_]Key{
    // SHA256:UiBcvO9PN2dsGQx6x+Ua0+mvp1Y9EFJ/orEdoQ80OFE
    .{ .name = "current", .key = sshKey("AAAAC3NzaC1lZDI1NTE5AAAAIOXmjXPwM3MICS/d9Zh3EkyW8hvvXWXkpcudKf4W0lYE") },
    // SHA256:xAXpwepaYOIzgKdeDV37kkLIHXoiq1UcU6Va6MRIHVI
    .{ .name = "next", .key = sshKey("AAAAC3NzaC1lZDI1NTE5AAAAIPmxn0kk/UDhnUaTacm5Inih0XhaVDkvm2TMi6qgNgTy") },
};

/// The test key (tools/vm-guest/testkey/test_ed25519.pub), trusted only
/// by a test build. SHA256:0i6ppbGLTgfdCV7fHFHBcnyT2S3mnECDbJ3BMwSUJO4
pub const test_key: Key = .{ .name = "test", .test_only = true, .key = sshKey("AAAAC3NzaC1lZDI1NTE5AAAAIJQFXLYWn/RbHTrjfGv15N3QaFDqa9jjAxBdncu7cx29") };

const options = @import("build_options");
pub const trusts_test_key = builtin.is_test or (@hasDecl(options, "vm_test_key") and options.vm_test_key);

/// The line that a build that trusts the test key prints when
/// `ztcl::vm` starts, and with the result of a check.
pub const test_key_warning = "warning: this ztcl trusts the test key of the VM images (-Dvm-test-key): a manifest named *-test can be signed by anyone";

/// The suffix of the name of a manifest that the test key may sign.
pub const test_suffix = "-test";

pub const Error = error{ BadSignature, Untrusted, Namespace, BadManifest, Rollback, Hash } || Allocator.Error;

/// A parsed SSH signature.
pub const Sig = struct {
    public_key: [32]u8,
    namespace: []const u8,
    reserved: []const u8,
    hash_alg: []const u8,
    signature: [64]u8,
};

const Wire = struct {
    b: []const u8,
    i: usize = 0,

    fn str(w: *Wire) Error![]const u8 {
        if (w.b.len - w.i < 4) return error.BadSignature;
        const n = std.mem.readInt(u32, w.b[w.i..][0..4], .big);
        w.i += 4;
        if (w.b.len - w.i < n) return error.BadSignature;
        defer w.i += n;
        return w.b[w.i..][0..n];
    }
};

/// Decodes the armor of `text` into `a` memory.
fn unarmor(a: Allocator, text: []const u8) Error![]u8 {
    const begin = "-----BEGIN SSH SIGNATURE-----";
    const end = "-----END SSH SIGNATURE-----";
    const s = std.mem.indexOf(u8, text, begin) orelse return error.BadSignature;
    const e = std.mem.indexOfPos(u8, text, s, end) orelse return error.BadSignature;
    var b64: std.ArrayList(u8) = .empty;
    defer b64.deinit(a);
    for (text[s + begin.len .. e]) |c| if (c != '\n' and c != '\r' and c != ' ' and c != '\t') try b64.append(a, c);
    const D = std.base64.standard.Decoder;
    const n = D.calcSizeForSlice(b64.items) catch return error.BadSignature;
    const out = try a.alloc(u8, n);
    errdefer a.free(out);
    D.decode(out, b64.items) catch return error.BadSignature;
    return out;
}

/// Parses an armored SSH signature. The slices point into `blob`.
fn parse(blob: []const u8) Error!Sig {
    if (blob.len < 10 or !std.mem.eql(u8, blob[0..6], "SSHSIG")) return error.BadSignature;
    if (std.mem.readInt(u32, blob[6..10], .big) != 1) return error.BadSignature;
    var w: Wire = .{ .b = blob, .i = 10 };
    var pk: Wire = .{ .b = try w.str() };
    if (!std.mem.eql(u8, try pk.str(), "ssh-ed25519")) return error.Untrusted;
    const key = try pk.str();
    if (key.len != 32 or pk.i != pk.b.len) return error.BadSignature;
    const ns = try w.str();
    const reserved = try w.str();
    const hash_alg = try w.str();
    var sw: Wire = .{ .b = try w.str() };
    if (w.i != blob.len) return error.BadSignature;
    if (!std.mem.eql(u8, try sw.str(), "ssh-ed25519")) return error.BadSignature;
    const sig = try sw.str();
    if (sig.len != 64 or sw.i != sw.b.len) return error.BadSignature;
    return .{ .public_key = key[0..32].*, .namespace = ns, .reserved = reserved, .hash_alg = hash_alg, .signature = sig[0..64].* };
}

fn trusted(extra: []const Key, key: [32]u8) ?Key {
    for (release_keys) |k| if (std.mem.eql(u8, &k.key, &key)) return k;
    if (trusts_test_key and std.mem.eql(u8, &test_key.key, &key)) return test_key;
    for (extra) |k| if (std.mem.eql(u8, &k.key, &key)) return k;
    return null;
}

fn putStr(h: *Sha512, s: []const u8) void {
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(s.len), .big);
    h.update(&n);
    h.update(s);
}

/// Checks the SSH signature `sig_text` of `message`, and gives the key
/// that signed it. `extra` is the keys of the embedder.
pub fn verifySignature(a: Allocator, extra: []const Key, message: []const u8, sig_text: []const u8) Error!Key {
    const blob = try unarmor(a, sig_text);
    defer a.free(blob);
    const s = try parse(blob);
    if (!std.mem.eql(u8, s.namespace, namespace)) return error.Namespace;
    if (!std.mem.eql(u8, s.hash_alg, "sha512")) return error.BadSignature;
    const key = trusted(extra, s.public_key) orelse return error.Untrusted;
    var digest: [Sha512.digest_length]u8 = undefined;
    Sha512.hash(message, &digest, .{});
    // The signed data: the magic, then the strings of the namespace, the
    // reserved field, the hash algorithm, and the hash.
    var signed: std.ArrayList(u8) = .empty;
    defer signed.deinit(a);
    try signed.appendSlice(a, "SSHSIG");
    for ([_][]const u8{ s.namespace, s.reserved, s.hash_alg, &digest }) |f| {
        var n: [4]u8 = undefined;
        std.mem.writeInt(u32, &n, @intCast(f.len), .big);
        try signed.appendSlice(a, &n);
        try signed.appendSlice(a, f);
    }
    const pk = Ed25519.PublicKey.fromBytes(key.key) catch return error.BadSignature;
    const sg = Ed25519.Signature.fromBytes(s.signature);
    sg.verify(signed.items, pk) catch return error.BadSignature;
    return key;
}

// ---- The manifest ----

pub const File = struct { file: []const u8, sha256: []const u8 };

pub const Verity = struct {
    /// The root hash for `dm-verity`, in hex, which goes on the command
    /// line of the kernel.
    root_hash: []const u8,
    salt: []const u8 = "",
    data_block: u32 = 4096,
    hash_block: u32 = 4096,
    /// The offset of the hash tree in the file of the disk, in bytes.
    hash_offset: u64 = 0,
};

pub const Disk = struct {
    name: []const u8,
    file: []const u8,
    sha256: []const u8,
    size: u64 = 0,
    read_only: bool = true,
    verity: ?Verity = null,
};

pub const Arch = struct {
    kernel: File,
    initrd: ?File = null,
    cmdline: []const u8 = "",
    disks: []const Disk = &.{},
};

pub const Manifest = struct {
    format: u32,
    name: []const u8,
    version: []const u8,
    counter: u64,
    min_ztcl: []const u8,
    archs: std.json.ArrayHashMap(Arch),
};

pub const Checked = struct {
    parsed: std.json.Parsed(Manifest),
    key: Key,

    pub fn deinit(c: *Checked) void {
        c.parsed.deinit();
    }
};

/// Checks the signature of `manifest`, then parses it. A counter below
/// `seen` (the highest counter that the store accepted) is a rollback,
/// unless `allow_rollback`.
pub fn verify(a: Allocator, manifest: []const u8, sig_text: []const u8, seen: u64, allow_rollback: bool) Error!Checked {
    return verifyWith(a, &.{}, manifest, sig_text, seen, allow_rollback);
}

/// `verify`, with the keys of the embedder in `extra` too.
pub fn verifyWith(a: Allocator, extra: []const Key, manifest: []const u8, sig_text: []const u8, seen: u64, allow_rollback: bool) Error!Checked {
    const key = try verifySignature(a, extra, manifest, sig_text);
    const p = std.json.parseFromSlice(Manifest, a, manifest, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadManifest,
    };
    errdefer p.deinit();
    if (p.value.format != 1) return error.BadManifest;
    // A test key signs only a test image.
    if (key.test_only and !std.mem.endsWith(u8, p.value.name, test_suffix)) return error.Untrusted;
    if (p.value.counter < seen and !allow_rollback) return error.Rollback;
    for (p.value.archs.map.values()) |arch| {
        try checkHex(arch.kernel.sha256, 64);
        if (arch.initrd) |f| try checkHex(f.sha256, 64);
        for (arch.disks) |d| {
            try checkHex(d.sha256, 64);
            if (d.verity) |v| try checkHex(v.root_hash, 64);
            if (!d.read_only and d.verity != null) return error.BadManifest;
        }
    }
    return .{ .parsed = p, .key = key };
}

fn checkHex(s: []const u8, n: usize) Error!void {
    if (s.len != n) return error.BadManifest;
    for (s) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.BadManifest;
}

/// Checks that `data` has the SHA-256 `want` (lowercase hex).
pub fn checkHash(data: []const u8, want: []const u8) Error!void {
    var d: [32]u8 = undefined;
    Sha256.hash(data, &d, .{});
    const hex = std.fmt.bytesToHex(d, .lower);
    if (!std.mem.eql(u8, &hex, want)) return error.Hash;
}

// ---- Tests ----

const fixtures = struct {
    const manifest = @embedFile("vmimage_fixtures/manifest.json");
    const good = @embedFile("vmimage_fixtures/manifest.json.sig.good");
    const other_ns = @embedFile("vmimage_fixtures/manifest.json.sig.namespace");
    const untrusted = @embedFile("vmimage_fixtures/manifest.json.sig.untrusted");
};

test "vmimage: a manifest signed by the test key" {
    const a = std.testing.allocator;
    var c = try verify(a, fixtures.manifest, fixtures.good, 0, false);
    defer c.deinit();
    try std.testing.expectEqualStrings("test", c.key.name);
    try std.testing.expectEqual(@as(u64, 3), c.parsed.value.counter);
    const arm = c.parsed.value.archs.map.get("arm64").?;
    try std.testing.expectEqualStrings("Image", arm.kernel.file);
}

test "vmimage: a changed manifest, a wrong namespace, and an untrusted key" {
    const a = std.testing.allocator;
    const changed = try a.dupe(u8, fixtures.manifest);
    defer a.free(changed);
    changed[std.mem.indexOf(u8, changed, "\"counter\":3").? + 10] = '4';
    try std.testing.expectError(error.BadSignature, verify(a, changed, fixtures.good, 0, false));
    try std.testing.expectError(error.Namespace, verify(a, fixtures.manifest, fixtures.other_ns, 0, false));
    try std.testing.expectError(error.Untrusted, verify(a, fixtures.manifest, fixtures.untrusted, 0, false));
    try std.testing.expectError(error.BadSignature, verify(a, fixtures.manifest, "no signature", 0, false));
    // A flipped bit of the signature.
    const bad = try a.dupe(u8, fixtures.good);
    defer a.free(bad);
    const at = std.mem.indexOf(u8, bad, "\n").? + 1 + 40;
    bad[at] = if (bad[at] == 'A') 'B' else 'A';
    try std.testing.expect(std.meta.isError(verify(a, fixtures.manifest, bad, 0, false)));
}

test "vmimage: the test key signs only a test image" {
    const a = std.testing.allocator;
    // The fixture is named ztcl-guest-test. The same manifest under the
    // name of a release image, signed by the test key, is refused.
    const msg = @embedFile("vmimage_fixtures/release-name.json");
    const sig = @embedFile("vmimage_fixtures/release-name.json.sig");
    try std.testing.expectError(error.Untrusted, verify(a, msg, sig, 0, false));
}

test "vmimage: the keys of the embedder" {
    const a = std.testing.allocator;
    const msg = @embedFile("vmimage_fixtures/release-name.json");
    const sig = @embedFile("vmimage_fixtures/release-name.json.sig.embedder");
    const test_sig = @embedFile("vmimage_fixtures/manifest.json.sig.embedder");
    const k: Key = .{ .name = "embedder", .key = comptime sshKey("AAAAC3NzaC1lZDI1NTE5AAAAIGQf92kcJqfKrdN7I5lIAVR0BGHZ1bDFzhfuixa6cSru") };
    // Untrusted without the key, trusted with it.
    try std.testing.expectError(error.Untrusted, verify(a, msg, sig, 0, false));
    var c = try verifyWith(a, &.{k}, msg, sig, 0, false);
    c.deinit();
    try std.testing.expectEqualStrings("embedder", c.key.name);
    // A test key of the embedder signs a test image, and not a release image.
    var t: Key = k;
    t.test_only = true;
    try std.testing.expectError(error.Untrusted, verifyWith(a, &.{t}, msg, sig, 0, false));
    var c2 = try verifyWith(a, &.{t}, fixtures.manifest, test_sig, 0, false);
    c2.deinit();
}

test "vmimage: rollback" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.Rollback, verify(a, fixtures.manifest, fixtures.good, 4, false));
    var c = try verify(a, fixtures.manifest, fixtures.good, 4, true);
    c.deinit();
    var d = try verify(a, fixtures.manifest, fixtures.good, 3, false);
    d.deinit();
}

test "vmimage: a changed disk" {
    const disk = "the bytes of a disk";
    var h: [32]u8 = undefined;
    Sha256.hash(disk, &h, .{});
    const hex = std.fmt.bytesToHex(h, .lower);
    try checkHash(disk, &hex);
    try std.testing.expectError(error.Hash, checkHash("the bytes of a disk!", &hex));
}

test "vmimage: the release keys are the keys of the fingerprints" {
    // The SHA-256 of the key blob, as `ssh-keygen -l` prints it.
    const want = [_][]const u8{ "UiBcvO9PN2dsGQx6x+Ua0+mvp1Y9EFJ/orEdoQ80OFE", "xAXpwepaYOIzgKdeDV37kkLIHXoiq1UcU6Va6MRIHVI" };
    for (release_keys, want) |k, w| {
        var blob: [51]u8 = undefined;
        std.mem.writeInt(u32, blob[0..4], 11, .big);
        @memcpy(blob[4..15], "ssh-ed25519");
        std.mem.writeInt(u32, blob[15..19], 32, .big);
        @memcpy(blob[19..51], &k.key);
        var d: [32]u8 = undefined;
        Sha256.hash(&blob, &d, .{});
        var out: [44]u8 = undefined;
        const fp = std.base64.standard_no_pad.Encoder.encode(&out, &d);
        try std.testing.expectEqualStrings(w, fp);
    }
}

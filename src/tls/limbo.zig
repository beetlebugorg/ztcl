//! Runs the path validation cases of x509-limbo against `chain.zig`.
//!
//!   tools/fetch-x509-limbo.sh DIR
//!   zig build tls-x509-test -- DIR/limbo.json
//!
//! Each case has trusted certificates, untrusted intermediates, a peer
//! certificate, a time, a peer name, and the expected result. The run
//! parses the certificates with `x509.parse`, calls `chain.verify`, and
//! compares the result. An anchor or an intermediate that does not
//! parse is left out. A peer certificate that does not parse is a
//! failure of the case. `skip` lists the kinds of cases that the run
//! skips, and `differ` lists the cases where the checks can differ from
//! the expected result, each with the reason. The run fails when another
//! case has the wrong result.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const x509 = @import("x509.zig");
const chain = @import("chain.zig");
const pem = @import("pem.zig");
const Value = std.json.Value;

const Skip = struct { what: []const u8, why: []const u8 };

/// A feature or an id prefix, and the reason for the skip.
const skip = [_]Skip{
    .{ .what = "has-crl", .why = "no revocation checks (docs/tls.md)" },
    .{ .what = "online::", .why = "the cases need the network" },
    .{ .what = "has-mldsa", .why = "no ML-DSA signatures" },
    .{ .what = "has-policy-constraints", .why = "no certificate policy checks" },
    .{ .what = "CLIENT", .why = "client certificates are later work (task 18)" },
};

/// The cases where the chain checks differ from x509-limbo, by id or
/// id prefix, and the reason.
const differ = [_]Skip{
    .{ .what = "rfc5280::aki::", .why = "the path search uses names; the key identifiers are not read" },
    .{ .what = "rfc5280::ski::", .why = "the path search uses names; the key identifiers are not read" },
    .{ .what = "webpki::aki::", .why = "the path search uses names; the key identifiers are not read" },
    .{ .what = "webpki::cn::", .why = "the common name is not read" },
    .{ .what = "webpki::malformed-aia", .why = "the authority information access is not read" },
    .{ .what = "webpki::san::public-suffix-", .why = "no Public Suffix List" },
    .{ .what = "webpki::san::san-critical-with-nonempty-subject", .why = "a rule of the CA/Browser Forum for the issue of a certificate" },
    .{ .what = "webpki::eku::ee-without-eku", .why = "a leaf with no extended key usage has any purpose (RFC 5280 section 4.2.1.12)" },
    .{ .what = "webpki::eku::root-has-eku", .why = "the extended key usage of an anchor is not read" },
    .{ .what = "rfc5280::root-non-critical-basic-constraints", .why = "some roots in use have a basicConstraints that is not critical" },
    .{ .what = "pathlen::validation-ignores-pathlen-in-leaf", .why = "a CA certificate as the leaf is refused, as in webpki::ca-as-leaf" },
};

fn str(v: Value, name: []const u8) ?[]const u8 {
    const f = v.object.get(name) orelse return null;
    return if (f == .string) f.string else null;
}

fn differOf(id: []const u8) ?[]const u8 {
    for (differ) |s| if (std.mem.startsWith(u8, id, s.what)) return s.why;
    return null;
}

fn skipOf(t: Value) ?[]const u8 {
    const id = str(t, "id").?;
    if (std.mem.startsWith(u8, id, "rfc5280::") and t.object.get("conflicts_with").?.array.items.len > 0)
        return "the run follows the webpki case where the two profiles conflict";
    const kind = str(t, "validation_kind").?;
    const features = t.object.get("features").?.array.items;
    for (skip) |s| {
        if (std.mem.eql(u8, kind, s.what) or std.mem.startsWith(u8, id, s.what)) return s.why;
        for (features) |f| if (std.mem.eql(u8, f.string, s.what)) return s.why;
    }
    return null;
}

/// The certificates of a list of PEM texts, those that parse.
fn certs(a: std.mem.Allocator, list: []const Value) ![]x509.Cert {
    var out: std.ArrayList(x509.Cert) = .empty;
    for (list) |v| {
        var it = pem.Iterator.init(v.string);
        while (try it.next(a)) |b| {
            const c = x509.parse(b.der) catch continue;
            try out.append(a, c);
        }
    }
    return out.items;
}

/// "2024-01-01T00:00:00+00:00" or "...Z".
fn isoTime(s: []const u8) !i64 {
    if (s.len < 19) return error.BadTime;
    const n = struct {
        fn f(x: []const u8) !i64 {
            return std.fmt.parseInt(i64, x, 10);
        }
    }.f;
    const days = x509.daysFromCivil(try n(s[0..4]), try n(s[5..7]), try n(s[8..10]));
    return days * 86400 + try n(s[11..13]) * 3600 + try n(s[14..16]) * 60 + try n(s[17..19]);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: tls-x509-test limbo.json [-v]\n", .{});
        std.process.exit(2);
    }
    const verbose = args.len > 2 and std.mem.eql(u8, args[2], "-v");
    const ga = init.arena.allocator();
    const text = try Io.Dir.cwd().readFileAlloc(io, args[1], ga, .limited(256 << 20));
    const doc = try std.json.parseFromSliceLeaky(Value, ga, text, .{});
    const cases = doc.object.get("testcases").?.array.items;
    const now = Io.Clock.real.now(io).toSeconds();
    var pass: usize = 0;
    var fail: usize = 0;
    var skipped: usize = 0;
    var known: usize = 0;
    var reasons: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (cases) |t| {
        if (skipOf(t)) |why| {
            skipped += 1;
            const gop = try reasons.getOrPut(ga, why);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            continue;
        }
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const id = str(t, "id").?;
        const want_ok = std.mem.eql(u8, str(t, "expected_result").?, "SUCCESS");
        const anchors = try certs(a, t.object.get("trusted_certs").?.array.items);
        const inter = try certs(a, t.object.get("untrusted_intermediates").?.array.items);
        var opts: chain.Options = .{ .now = if (str(t, "validation_time")) |s| try isoTime(s) else now, .max_intermediates = 64 };
        if (t.object.get("expected_peer_name")) |pn| if (pn == .object) {
            opts.host = str(pn, "value");
        };
        if (t.object.get("max_chain_depth")) |d| if (d == .integer) {
            opts.max_depth = @intCast(d.integer);
        };
        var it = pem.Iterator.init(str(t, "peer_certificate").?);
        const result: anyerror!void = blk: {
            const b = (try it.next(a)) orelse break :blk error.NoPeer;
            const leaf = x509.parse(b.der) catch |e| break :blk e;
            break :blk chain.verify(&leaf, inter, anchors, opts);
        };
        const ok = if (result) true else |_| false;
        if (ok == want_ok) {
            pass += 1;
        } else if (differOf(id)) |why| {
            const gop = try reasons.getOrPut(ga, why);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            known += 1;
        } else {
            fail += 1;
            if (verbose) {
                const why: []const u8 = if (result) "accepted" else |e| @errorName(e);
                std.debug.print("FAIL {s}: want {s}, got {s}\n", .{ id, str(t, "expected_result").?, why });
            }
        }
    }
    std.debug.print("{d} pass, {d} fail, {d} known differences, {d} skipped\n", .{ pass, fail, known, skipped });
    for (reasons.keys(), reasons.values()) |k, v| std.debug.print("  {d}: {s}\n", .{ v, k });
    if (fail > 0) std.process.exit(1);
}

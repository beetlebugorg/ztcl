//! A mutation fuzzer of the DER, X.509, PEM, and chain code.
//!
//!   zig build x509-fuzz -- [--seconds N] [--seed N]
//!
//! Each round copies a certificate of `testdata/chain`, changes bytes
//! (a flip, a new value, a cut, a copy of a run, or a change of a
//! length byte), and gives the result to `x509.parse`. A certificate
//! that parses goes to `chain.verify` as the leaf and as the issuer of
//! the other test certificates. The PEM text of the bytes goes to
//! `pem.Iterator`. A build with safety checks stops at the first
//! out-of-bounds read or overflow.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const x509 = @import("x509.zig");
const chain = @import("chain.zig");
const pem = @import("pem.zig");

const seeds = [_][]const u8{
    @embedFile("testdata/chain/root.pem"),
    @embedFile("testdata/chain/leaf.pem"),
    @embedFile("testdata/chain/evil.pem"),
};

fn mutate(r: std.Random, buf: []u8, len: usize) usize {
    var n = len;
    const rounds = 1 + r.uintLessThan(usize, 4);
    for (0..rounds) |_| {
        if (n == 0) return 0;
        const i = r.uintLessThan(usize, n);
        switch (r.uintLessThan(u8, 5)) {
            0 => buf[i] ^= @as(u8, 1) << r.int(u3),
            1 => buf[i] = r.int(u8),
            2 => n = i,
            3 => {
                // Copy a run of bytes to another place.
                const j = r.uintLessThan(usize, n);
                const k = @min(r.uintLessThan(usize, 32) + 1, n - @max(i, j));
                var tmp: [32]u8 = undefined;
                @memcpy(tmp[0..k], buf[i..][0..k]);
                @memcpy(buf[j..][0..k], tmp[0..k]);
            },
            else => {
                // A length byte: the byte after a tag.
                if (i + 1 < n) buf[i + 1] = switch (r.uintLessThan(u8, 4)) {
                    0 => 0x80,
                    1 => 0x84,
                    2 => 0xff,
                    else => r.int(u8),
                };
            },
        }
    }
    return n;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var seconds: u64 = 10;
    var seed: u64 = 1;
    var k: usize = 1;
    while (k + 1 < args.len) : (k += 2) {
        const v = std.fmt.parseInt(u64, args[k + 1], 10) catch 0;
        if (std.mem.eql(u8, args[k], "--seconds")) seconds = v else if (std.mem.eql(u8, args[k], "--seed")) seed = v else {
            std.debug.print("usage: x509-fuzz [--seconds N] [--seed N]\n", .{});
            std.process.exit(2);
        }
    }
    var ders: [seeds.len][]u8 = undefined;
    var good: [seeds.len]x509.Cert = undefined;
    for (seeds, 0..) |s, i| {
        var it = pem.Iterator.init(s);
        ders[i] = (try it.next(a)).?.der;
        good[i] = try x509.parse(ders[i]);
    }
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const start = Io.Clock.awake.now(io);
    var buf: [4096]u8 = undefined;
    var text: [8192]u8 = undefined;
    var rounds: u64 = 0;
    var parsed: u64 = 0;
    const opts: chain.Options = .{ .now = 1798761600, .host = "leaf.test" };
    while (true) : (rounds += 1) {
        if (rounds % 4096 == 0) {
            const secs = @divFloor(start.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_s);
            if (secs >= seconds) break;
        }
        const src = ders[r.uintLessThan(usize, ders.len)];
        @memcpy(buf[0..src.len], src);
        const n = mutate(r, &buf, src.len);
        if (x509.parse(buf[0..n])) |c| {
            parsed += 1;
            _ = chain.verify(&c, good[1..2], good[0..1], opts) catch {};
            _ = chain.verify(&good[2], &.{c}, good[0..1], opts) catch {};
            _ = chain.verify(&good[1], &.{}, &.{c}, opts) catch {};
        } else |_| {}
        if (rounds % 16 == 0) {
            // The PEM form of the bytes, with a change in the text.
            const enc = std.base64.standard.Encoder;
            const head = "-----BEGIN CERTIFICATE-----\n";
            const tail = "\n-----END CERTIFICATE-----\n";
            @memcpy(text[0..head.len], head);
            const body = enc.encode(text[head.len..], buf[0..n]);
            var m = head.len + body.len;
            @memcpy(text[m..][0..tail.len], tail);
            m += tail.len;
            m = mutate(r, &text, m);
            var it = pem.Iterator.init(text[0..m]);
            while (it.next(a) catch null) |b| a.free(b.der);
        }
    }
    for (ders) |d| a.free(d);
    std.debug.print("{d} rounds, {d} parsed, {d} s\n", .{ rounds, parsed, seconds });
}

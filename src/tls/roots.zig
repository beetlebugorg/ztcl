//! A store of trust anchors for `chain.verify`.
//!
//! The anchors come from PEM text, from a PEM file, from DER bytes of
//! the embedder, or from the store of the system:
//!
//! - Linux: the first bundle file of the distribution that exists, read
//!   with `pem.zig`. Each certificate in the file is kept, also two with
//!   the same subject.
//! - macOS, Windows, the BSDs, and a Linux with no bundle file:
//!   `std.crypto.Certificate.Bundle.rescan`, which reads the keychain on
//!   macOS and the ROOT store on Windows. The bundle keeps one
//!   certificate for each subject, and leaves out the expired ones.
//!
//! A certificate that `x509.parse` refuses is left out.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const der = @import("der.zig");
const pem = @import("pem.zig");
const x509 = @import("x509.zig");

pub const Roots = struct {
    arena: std.heap.ArenaAllocator,
    certs: std.ArrayList(x509.Cert) = .empty,

    pub fn init(gpa: std.mem.Allocator) Roots {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(r: *Roots) void {
        r.arena.deinit();
    }

    pub fn slice(r: *const Roots) []const x509.Cert {
        return r.certs.items;
    }

    /// Adds a copy of one DER certificate. Gives false when it does not
    /// parse.
    pub fn addDer(r: *Roots, bytes: []const u8) !bool {
        const a = r.arena.allocator();
        const copy = try a.dupe(u8, bytes);
        const c = x509.parse(copy) catch return false;
        try r.certs.append(a, c);
        return true;
    }

    /// Adds each `CERTIFICATE` block of `text` that parses, and gives the
    /// count.
    pub fn addPem(r: *Roots, text: []const u8) !usize {
        const a = r.arena.allocator();
        var it = pem.Iterator.init(text);
        var n: usize = 0;
        while (it.next(a) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => null,
        }) |b| {
            if (!std.mem.eql(u8, b.label, "CERTIFICATE")) continue;
            const c = x509.parse(b.der) catch continue;
            try r.certs.append(a, c);
            n += 1;
        }
        return n;
    }

    /// Adds the certificates of a PEM file.
    pub fn addFile(r: *Roots, io: Io, dir: Io.Dir, path: []const u8) !usize {
        const a = r.arena.allocator();
        const text = try dir.readFileAlloc(io, path, a, .limited(16 << 20));
        return r.addPem(text);
    }

    /// The bundle files of Linux distributions: Debian, Ubuntu, Arch,
    /// and Gentoo; Fedora and RHEL 6; openSUSE; OpenELEC; CentOS and
    /// RHEL 7; Alpine.
    const linux_files = [_][]const u8{
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/ca-bundle.pem",
        "/etc/pki/tls/cacert.pem",
        "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
        "/etc/ssl/cert.pem",
    };

    /// Adds the trust anchors of the system, and gives the count.
    pub fn addSystem(r: *Roots, io: Io) !usize {
        if (builtin.os.tag == .linux) {
            for (linux_files) |f| {
                return r.addFile(io, Io.Dir.cwd(), f) catch |e| switch (e) {
                    error.FileNotFound => continue,
                    else => return e,
                };
            }
        }
        const gpa = r.arena.child_allocator;
        var b: std.crypto.Certificate.Bundle = .empty;
        defer b.deinit(gpa);
        try b.rescan(gpa, io, Io.Clock.real.now(io));
        var n: usize = 0;
        var it = b.map.valueIterator();
        while (it.next()) |off| {
            var rd = der.Reader.init(b.bytes.items[off.*..]);
            const e = rd.next() catch continue;
            if (try r.addDer(e.raw)) n += 1;
        }
        return n;
    }
};

test "PEM text and the system store" {
    var r = Roots.init(std.testing.allocator);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), try r.addPem(@embedFile("testdata/chain/root.pem")));
    try std.testing.expectEqual(@as(usize, 0), try r.addPem("no blocks"));
    try std.testing.expect(!try r.addDer("\x30\x00"));
    // The store of the host can be empty, so the test checks that the
    // read gives no error.
    _ = r.addSystem(std.testing.io) catch |e| switch (e) {
        error.FileNotFound => 0,
        else => return e,
    };
}

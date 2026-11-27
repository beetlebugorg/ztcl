//! `vm-image-verify DIR`: checks a guest image release in DIR with the
//! verifier of ztcl (`src/vmimage.zig`): the signature of manifest.json
//! in manifest.json.sig, then the SHA-256 of each file of the manifest
//! that DIR has. Prints the key, then each file, and exits with 1 on the
//! first failure. The CI of the image runs it before an upload.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const ztcl = @import("ztcl");
const vmimage = ztcl.vmimage;

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("vm-image-verify: " ++ fmt ++ "\n", args);
    return 1;
}

pub fn main(init: std.process.Init) !u8 {
    const a = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return fail("usage: vm-image-verify DIR", .{});
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer dir.close(io);
    const manifest = try dir.readFileAlloc(io, "manifest.json", a, .limited(1 << 20));
    defer a.free(manifest);
    const sig = try dir.readFileAlloc(io, "manifest.json.sig", a, .limited(1 << 16));
    defer a.free(sig);
    if (vmimage.trusts_test_key) std.debug.print("{s}\n", .{vmimage.test_key_warning});
    var c = vmimage.verify(a, manifest, sig, 0, false) catch |e| return fail("the signature: {s}", .{@errorName(e)});
    defer c.deinit();
    std.debug.print("signature: good, key {s}, {s} {s} counter {d}\n", .{ c.key.name, c.parsed.value.name, c.parsed.value.version, c.parsed.value.counter });
    var n: usize = 0;
    for (c.parsed.value.archs.map.keys(), c.parsed.value.archs.map.values()) |arch, x| {
        var files: [64]vmimage.File = undefined;
        var k: usize = 0;
        files[k] = x.kernel;
        k += 1;
        if (x.initrd) |f| {
            files[k] = f;
            k += 1;
        }
        for (x.disks) |d| {
            if (k == files.len) break;
            files[k] = .{ .file = d.file, .sha256 = d.sha256 };
            k += 1;
        }
        for (files[0..k]) |f| {
            const data = dir.readFileAlloc(io, f.file, a, .limited(4 << 30)) catch {
                std.debug.print("{s}: {s}: not here, not checked\n", .{ arch, f.file });
                continue;
            };
            defer a.free(data);
            vmimage.checkHash(data, f.sha256) catch return fail("{s}: {s}: the SHA-256 differs from the manifest", .{ arch, f.file });
            std.debug.print("{s}: {s}: good\n", .{ arch, f.file });
            n += 1;
        }
    }
    if (n == 0) return fail("no file of the manifest is in {s}", .{args[1]});
    return 0;
}

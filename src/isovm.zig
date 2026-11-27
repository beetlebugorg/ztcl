//! The guest side of `thread::create -isolation vm` (ztcl#468): the
//! `ztcl` runner as the first process of a guest of `ztcl::vm`, started
//! by the kernel with `rdinit=/sbin/ztcl -- --iso-vsock PORT`. There is
//! no shell and no other process.
//!
//! The runner listens on vsock port PORT. The host connects and sends a
//! prelude of 48 bytes: the magic `ZTISOVM1`, the time of the host in ns
//! since 1970 (u64, little-endian), and 32 random bytes of the host. The
//! runner sets the clock of the guest and adds the bytes to the random
//! pool of the kernel (RNDADDENTROPY, then RNDRESEEDCRNG), so two clones
//! of one snapshot differ. Then the connection is the transport of an
//! isolated thread (`isothread.childMain`), with the frames of
//! `isoproto.zig`. A connection that closes before its prelude is a
//! probe of the host and the runner waits for the next one.
//!
//! At the end of the thread the runner exits, and the kernel of the guest
//! then stops the guest (`panic=-1` and `reboot=k` of the KVM monitor).
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const isothread = @import("isothread.zig");
const linux = std.os.linux;

pub const supported = builtin.os.tag == .linux and isothread.supported;
pub const port: u32 = 1026;
pub const magic = "ZTISOVM1".*;
pub const prelude_len = 48;

const AF_VSOCK = 40;
const cid_any: u32 = 0xffff_ffff;
const SockaddrVm = extern struct { family: u16 = AF_VSOCK, reserved1: u16 = 0, port: u32, cid: u32, flags: u8 = 0, zero: [3]u8 = @splat(0) };
const rnd_add_entropy = linux.IOCTL.IOW('R', 0x03, [2]i32);
const rnd_reseed_crng = linux.IOCTL.IO('R', 0x07);

fn ok(rc: usize) ?usize {
    return if (linux.errno(rc) == .SUCCESS) rc else null;
}

/// The prelude of the host for a guest: `magic`, `realtime_ns`, `seed`.
pub fn prelude(realtime_ns: u64, seed: *const [32]u8) [prelude_len]u8 {
    var p: [prelude_len]u8 = undefined;
    p[0..8].* = magic;
    std.mem.writeInt(u64, p[8..16], realtime_ns, .little);
    p[16..48].* = seed.*;
    return p;
}

fn readFull(fd: i32, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf[off..].ptr, buf.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                off += rc;
            },
            .INTR => continue,
            else => return false,
        }
    }
    return true;
}

fn apply(p: *const [prelude_len]u8) void {
    const ns = std.mem.readInt(u64, p[8..16], .little);
    const ts: linux.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    _ = linux.clock_settime(.REALTIME, &ts);
    const fd = ok(linux.open("/dev/urandom", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0)) orelse return;
    defer _ = linux.close(@intCast(fd));
    var info: extern struct { count: i32 = 256, size: i32 = 32, buf: [32]u8 } = .{ .buf = p[16..48].* };
    if (ok(linux.ioctl(@intCast(fd), rnd_add_entropy, @intFromPtr(&info))) == null)
        _ = linux.write(@intCast(fd), p[16..].ptr, 32);
    _ = linux.ioctl(@intCast(fd), rnd_reseed_crng, 0);
}

/// Runs the isolated thread of the first host connection with a prelude
/// on vsock port `listen_port`. Gives the exit status of the thread.
pub fn guestMain(a: std.mem.Allocator, listen_port: u32, hosts: isothread.Hosts) u8 {
    if (comptime !supported) return 2;
    // As the first process, the runner has no /dev: devtmpfs gives it
    // /dev/urandom.
    if (linux.getpid() == 1) _ = linux.mount("dev", "/dev", "devtmpfs", 0, 0);
    const s = ok(linux.socket(AF_VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) orelse return 2;
    const sock: i32 = @intCast(s);
    var addr: SockaddrVm = .{ .port = listen_port, .cid = cid_any };
    if (ok(linux.bind(sock, @ptrCast(&addr), @sizeOf(SockaddrVm))) == null) return 2;
    if (ok(linux.listen(sock, 4)) == null) return 2;
    while (true) {
        const c = ok(linux.accept4(sock, null, null, linux.SOCK.CLOEXEC)) orelse continue;
        const fd: i32 = @intCast(c);
        var p: [prelude_len]u8 = undefined;
        if (!readFull(fd, &p) or !std.mem.eql(u8, p[0..8], &magic)) {
            _ = linux.close(fd);
            continue;
        }
        apply(&p);
        _ = linux.close(sock);
        return isothread.childProcess(a, fd, hosts);
    }
}

test "isovm: the prelude" {
    const seed: [32]u8 = @splat(7);
    const p = prelude(1234, &seed);
    try std.testing.expectEqualStrings("ZTISOVM1", p[0..8]);
    try std.testing.expectEqual(@as(u64, 1234), std.mem.readInt(u64, p[8..16], .little));
    try std.testing.expectEqual(@as(u8, 7), p[47]);
}

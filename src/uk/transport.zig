//! The transport of the isolation protocol (`isoproto.zig`) in the ztcl
//! unikernel (ztcl#471): the one vsock stream of `vsock.zig`. It passes
//! no descriptors.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const vsock = @import("vsock.zig");
const cpu = @import("cpu.zig");
const Error = @import("../isoproto.zig").Error;

pub const Transport = struct {
    pub fn init() Transport {
        return .{};
    }

    pub fn deinit(_: *Transport) void {
        vsock.shutdown();
    }

    pub fn cancel(_: *Transport) void {}

    /// Reads at least one byte. `error.Closed` at the end of the stream.
    pub fn read(_: *Transport, buf: []u8) Error!usize {
        const n = vsock.read(buf);
        return if (n == 0) error.Closed else n;
    }

    pub fn takeFd(_: *Transport) ?i32 {
        return null;
    }

    pub fn writeAllFds(_: *Transport, _: []const u8, _: []const i32) Error!void {
        return error.Io;
    }

    pub fn writeAll(_: *Transport, bytes: []const u8) Error!void {
        if (!vsock.write(bytes)) return error.Closed;
    }
};

/// The bytes of RDRAND. A CPU with no working RDRAND gets the SHA-256
/// of the time stamp counter and a counter: the keys of a connection
/// then depend on the bootstrap secret alone for their secrecy.
pub fn entropy(buf: []u8) void {
    if (cpu.random(buf)) return;
    const S = struct {
        var n: u64 = 0;
    };
    var off: usize = 0;
    while (off < buf.len) {
        S.n += 1;
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(std.mem.asBytes(&S.n));
        const t = cpu.rdtsc();
        h.update(std.mem.asBytes(&t));
        var d: [32]u8 = undefined;
        h.final(&d);
        const k = @min(32, buf.len - off);
        @memcpy(buf[off..][0..k], d[0..k]);
        off += k;
    }
}

//! The host side of the framed relay of `ztcl::vm listen -framed 1`
//! (docs/dev/vm-agent.md): a guest program that connects with
//! `/sbin/agent connect -framed PORT` sends the preamble `ZTRELAY1`, then
//! frames of a kind byte (0 data, 1 end) and a length (u32,
//! little-endian) in each direction. A thread of this file turns the
//! frames into a plain stream socket for the script: data frames become
//! bytes, an end frame of the guest becomes a shutdown of writes, which
//! the script reads as the end of the stream, and the end of the writes
//! of the script becomes an end frame. So a half-close works the same on
//! each hypervisor, with no shutdown of vsock, which
//! Virtualization.framework loses when its buffer to the host holds data.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const os = @import("sys.zig").os;

pub const preamble = "ZTRELAY1";
const kind_data = 0;
const kind_end = 1;
/// The largest data frame. A guest frame above it is an error.
const max_data = 65536;
const shut_wr = 1;

/// A relay of the vsock connection `vsock`: gives the end of a new socket
/// pair for the script, and a thread owns `vsock` and the other end until
/// both directions end. The thread reads the preamble first; a connection
/// without it closes, and the script reads the end of the stream at once.
pub fn start(vsock: i32) !i32 {
    var pair: [2]i32 = undefined;
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)) != .SUCCESS) return error.NoSocket;
    } else {
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair) != 0) return error.NoSocket;
        for (pair) |fd| _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    }
    const size: c_int = 1 << 20;
    for (pair) |fd| {
        _ = os.setsockopt(fd, os.SOL.SOCKET, os.SO.SNDBUF, std.mem.asBytes(&size), @sizeOf(c_int));
        _ = os.setsockopt(fd, os.SOL.SOCKET, os.SO.RCVBUF, std.mem.asBytes(&size), @sizeOf(c_int));
    }
    const t = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, run, .{ vsock, pair[1] }) catch {
        _ = os.close(pair[0]);
        _ = os.close(pair[1]);
        return error.NoThread;
    };
    t.detach();
    return pair[0];
}

fn writeAll(fd: i32, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = os.write(fd, bytes[off..].ptr, bytes.len - off);
        switch (os.errno(n)) {
            .SUCCESS => off += n,
            .INTR, .AGAIN => {},
            else => return false,
        }
    }
    return true;
}

fn readSome(fd: i32, buf: []u8) usize {
    while (true) {
        const n = os.read(fd, buf.ptr, buf.len);
        switch (os.errno(n)) {
            .SUCCESS => return n,
            .INTR, .AGAIN => {},
            else => return 0,
        }
    }
}

fn readExact(fd: i32, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = readSome(fd, buf[off..]);
        if (n == 0) return false;
        off += n;
    }
    return true;
}

const Relay = struct {
    vsock: i32,
    local: i32,
    /// The frames of the guest that wait: a header and the start of its data.
    in: [max_data + 5]u8 = undefined,
    have: usize = 0,
    /// A frame to the guest: the header, then the bytes of the script.
    out: [max_data + 5]u8 = undefined,
    guest_open: bool = true,
    local_open: bool = true,

    /// The frames of the guest in `in`. False: a bad frame.
    fn takeFrames(r: *Relay) bool {
        var at: usize = 0;
        while (r.have - at >= 5) {
            const len = std.mem.readInt(u32, r.in[at + 1 ..][0..4], .little);
            if (len > max_data) return false;
            if (r.have - at < 5 + len) break;
            switch (r.in[at]) {
                kind_data => if (r.guest_open) {
                    if (!writeAll(r.local, r.in[at + 5 ..][0..len])) r.guest_open = false;
                },
                kind_end => if (r.guest_open) {
                    r.guest_open = false;
                    _ = os.shutdown(r.local, shut_wr);
                },
                else => return false,
            }
            at += 5 + len;
        }
        std.mem.copyForwards(u8, r.in[0 .. r.have - at], r.in[at..r.have]);
        r.have -= at;
        return true;
    }

    fn sendFrame(r: *Relay, kind: u8, len: usize) bool {
        r.out[0] = kind;
        std.mem.writeInt(u32, r.out[1..5], @intCast(len), .little);
        return writeAll(r.vsock, r.out[0 .. 5 + len]);
    }
};

fn run(vsock: i32, local: i32) void {
    defer {
        _ = os.close(vsock);
        _ = os.close(local);
    }
    var head: [preamble.len]u8 = undefined;
    if (!readExact(vsock, &head) or !std.mem.eql(u8, &head, preamble)) return;
    const r = std.heap.page_allocator.create(Relay) catch return;
    defer std.heap.page_allocator.destroy(r);
    r.* = .{ .vsock = vsock, .local = local };
    while (r.guest_open or r.local_open) {
        var fds = [2]os.pollfd{
            .{ .fd = vsock, .events = os.POLL.IN, .revents = 0 },
            .{ .fd = if (r.local_open) local else -1, .events = os.POLL.IN, .revents = 0 },
        };
        const pr = os.poll(&fds, 2, -1);
        if (os.errno(pr) != .SUCCESS) continue;
        if (fds[0].revents != 0) {
            const n = readSome(vsock, r.in[r.have..]);
            // The guest closed the connection: nothing more goes either way.
            if (n == 0) {
                if (r.guest_open) _ = os.shutdown(local, shut_wr);
                return;
            }
            r.have += n;
            if (!r.takeFrames()) return;
        }
        if (fds[1].revents != 0) {
            const n = readSome(local, r.out[5..]);
            if (n == 0) {
                r.local_open = false;
                if (!r.sendFrame(kind_end, 0)) return;
            } else if (!r.sendFrame(kind_data, n)) return;
        }
    }
}

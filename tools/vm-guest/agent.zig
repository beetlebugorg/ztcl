//! The guest agent of the ztcl::vm spike (ztcl#203): a vsock server on
//! port 1024. Each connection first gets 16 bytes, the boot clock of the
//! guest in nanoseconds when `main` started and when the socket listened,
//! and then each byte that the host sends comes back. The full agent runs
//! `exec` for the host on the same socket.
//!
//! A first byte of 1 from the host asks for the kernel log instead.
//!
//! As the first process (`rdinit=/sbin/agent`), the agent mounts the
//! virtio-fs share with the tag `share` at /mnt/share, when the guest has
//! it, and writes a file there.
//!
//!   zig build-exe -target aarch64-linux-musl -O ReleaseSmall agent.zig
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const linux = std.os.linux;

const AF_VSOCK = 40;
const VMADDR_CID_ANY: u32 = 0xffff_ffff;
const port: u32 = 1024;

const SockaddrVm = extern struct {
    family: u16 = AF_VSOCK,
    reserved1: u16 = 0,
    port: u32,
    cid: u32,
    flags: u8 = 0,
    zero: [3]u8 = .{ 0, 0, 0 },
};

fn ok(rc: usize) ?usize {
    return if (linux.errno(rc) == .SUCCESS) rc else null;
}

fn say(text: []const u8) void {
    _ = linux.write(2, text.ptr, text.len);
}

fn bootNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.BOOTTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn share() void {
    _ = linux.mkdir("/mnt", 0o755);
    _ = linux.mkdir("/mnt/share", 0o755);
    _ = ok(linux.mount("share", "/mnt/share", "virtiofs", 0, 0)) orelse return;
    const fd: i32 = @intCast(ok(linux.open("/mnt/share/from-guest.txt", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644)) orelse return);
    const text = "written by the guest\n";
    _ = linux.write(fd, text, text.len);
    _ = linux.close(fd);
}

var log: [256 * 1024]u8 = undefined;

pub fn main() void {
    var times: [2]u64 = .{ bootNs(), 0 };
    if (linux.getpid() == 1) share();
    const fd: i32 = @intCast(ok(linux.socket(AF_VSOCK, linux.SOCK.STREAM, 0)) orelse return say("agent: no vsock\n"));
    var addr: SockaddrVm = .{ .port = port, .cid = VMADDR_CID_ANY };
    _ = ok(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrVm))) orelse return say("agent: bind failed\n");
    _ = ok(linux.listen(fd, 4)) orelse return say("agent: listen failed\n");
    times[1] = bootNs();
    while (true) {
        const c: i32 = @intCast(ok(linux.accept(fd, null, null)) orelse continue);
        const head = std.mem.asBytes(&times);
        _ = linux.write(c, head.ptr, head.len);
        var buf: [4096]u8 = undefined;
        var first = true;
        while (true) {
            const n = ok(linux.read(c, &buf, buf.len)) orelse break;
            if (n == 0) break;
            if (first and buf[0] == 1) {
                // A first byte of 1 asks for the kernel log (syslog(2),
                // SYSLOG_ACTION_READ_ALL), for the times of the boot.
                const len = ok(linux.syscall3(.syslog, 3, @intFromPtr(&log), log.len)) orelse 0;
                _ = linux.write(c, &log, len);
                break;
            }
            first = false;
            var off: usize = 0;
            while (off < n) off += ok(linux.write(c, buf[off..].ptr, n - off)) orelse break;
        }
        _ = linux.close(c);
    }
}

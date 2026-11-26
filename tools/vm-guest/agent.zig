//! The guest agent of the ztcl::vm spike (ztcl#203): a vsock server on
//! port 1024 that sends back each byte it reads. The full agent runs
//! `exec` for the host on the same socket.
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

pub fn main() void {
    const fd: i32 = @intCast(ok(linux.socket(AF_VSOCK, linux.SOCK.STREAM, 0)) orelse return say("agent: no vsock\n"));
    var addr: SockaddrVm = .{ .port = port, .cid = VMADDR_CID_ANY };
    _ = ok(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrVm))) orelse return say("agent: bind failed\n");
    _ = ok(linux.listen(fd, 4)) orelse return say("agent: listen failed\n");
    say("agent: listening on vsock port 1024\n");
    while (true) {
        const c: i32 = @intCast(ok(linux.accept(fd, null, null)) orelse continue);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = ok(linux.read(c, &buf, buf.len)) orelse break;
            if (n == 0) break;
            var off: usize = 0;
            while (off < n) off += ok(linux.write(c, buf[off..].ptr, n - off)) orelse break;
        }
        _ = linux.close(c);
    }
}

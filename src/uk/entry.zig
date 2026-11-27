//! The program of the ztcl unikernel (ztcl#471): the child of one
//! isolated thread (`isothread.childMain`) on the vsock stream of the
//! host.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const uk = @import("uk.zig");
const vsock = @import("vsock.zig");
const wait = @import("wait.zig");
const isothread = @import("../isothread.zig");
const Transport = @import("transport.zig").Transport;

pub fn run() void {
    if (uk.param("ztcl.tsc_khz")) |k| wait.tsc_khz = std.fmt.parseInt(u64, k, 10) catch 0;
    @import("hosts.zig").init();
    if (!vsock.init()) return uk.print("ztcl unikernel: no vsock device\n");
    uk.cpu.routeIrq(vsock.irq);
    vsock.accept();
    const code = isothread.childMain(uk.heap.allocator, Transport.init(), .{ .clock = @import("hosts.zig").clock, .event = @import("hosts.zig").event });
    if (code != 0) uk.printf("ztcl unikernel: the thread ended with {d}\n", .{code});
    vsock.shutdown();
}

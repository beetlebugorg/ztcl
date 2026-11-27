//! The virtio memory balloon (device ID 5) with free page reporting
//! only, from section 5.5 of the virtio 1.2 specification of OASIS. The
//! device offers VIRTIO_BALLOON_F_PAGE_REPORTING (bit 5), so its queues
//! are inflateq (0), deflateq (1), and reporting_vq (2): the queues of
//! the features that the device does not offer are absent, and the
//! index of each later queue moves down. `num_pages` of the
//! configuration stays 0, so the driver does not inflate the balloon.
//!
//! The driver puts ranges of free guest memory in reporting_vq. The
//! device gives each range to `Balloon.report`, and the monitor drops
//! the host pages of the range (`madvise` with `MADV_DONTNEED` on
//! Linux). Then the device puts the buffer in the used ring. The guest
//! keeps no data in a page that it reports, and a later touch of the
//! page gets a new page of the host. So a guest uses host memory only
//! for the pages that it holds, and a snapshot of the guest has no free
//! pages: they read as zero.
//!
//! Buffers of inflateq and deflateq go to the used ring with no action.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const queue = @import("queue.zig");
const Mem = queue.Mem;
const Queue = queue.Queue;
const Chain = queue.Chain;

pub const id = 5;
pub const f_page_reporting: u64 = 1 << 5;

pub const Balloon = struct {
    ctx: *anyopaque,
    /// A range of free guest memory, as host bytes.
    report: *const fn (ctx: *anyopaque, range: []u8) void,
};

/// Takes each chain of queue `q`. A chain of the reporting queue
/// (`reporting`) gives each of its buffers to `report`. Gives true when a
/// chain went to the used ring.
pub fn run(b: Balloon, q: *Queue, mem: Mem, reporting: bool) bool {
    var any = false;
    while (q.next(mem)) |head| {
        any = true;
        if (reporting) if (Chain.read(q, mem, head)) |c| {
            for (c.bufs[0..c.n]) |r| b.report(b.ctx, r);
        };
        q.putUsed(mem, head, 0);
    }
    return any;
}

const Fake = struct {
    bytes: u64 = 0,
    calls: u32 = 0,
    fn report(ctx: *anyopaque, r: []u8) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.bytes += r.len;
        f.calls += 1;
    }
};

test "balloon: the ranges of the reporting queue" {
    var buf: [1 << 16]u8 align(4096) = @splat(0);
    const mem: Mem = .{ .base = &buf, .size = buf.len };
    var q: Queue = .{ .num = 4, .ready = true, .desc = 0x100, .avail = 0x200, .used = 0x300 };
    // Two descriptors in one chain: 8 KB at 0x2000 and 4 KB at 0x8000,
    // device-writable as the driver of Linux makes them.
    mem.put(u64, 0x100, 0x2000);
    mem.put(u32, 0x108, 0x2000);
    mem.put(u16, 0x10c, 1 | 2);
    mem.put(u16, 0x10e, 1);
    mem.put(u64, 0x110, 0x8000);
    mem.put(u32, 0x118, 0x1000);
    mem.put(u16, 0x11c, 2);
    mem.put(u16, 0x204, 0);
    mem.put(u16, 0x202, 1);
    var f: Fake = .{};
    const b: Balloon = .{ .ctx = &f, .report = Fake.report };
    try std.testing.expect(run(b, &q, mem, true));
    try std.testing.expectEqual(@as(u64, 0x3000), f.bytes);
    try std.testing.expectEqual(@as(u32, 2), f.calls);
    try std.testing.expectEqual(@as(u16, 1), mem.ptr(u16, 0x302).?.*);
    try std.testing.expect(!run(b, &q, mem, true));
}

//! The virtio-net device of virtio 1.2 (section 5.1) for `ztcl::vm -net
//! nat`, on the virtio-mmio transport of `mmio.zig`. Queue 0 is the
//! receive queue and queue 1 is the transmit queue.
//!
//! Each frame on a queue starts with the 12-byte header of section
//! 5.1.6 (VIRTIO_F_VERSION_1 always gives the `num_buffers` field). The
//! device gives each frame of the transmit queue to a `Sink` as the
//! header and the slices of its descriptors in guest memory, with no
//! copy. `deliver` copies a frame for the guest into receive buffers:
//! with VIRTIO_NET_F_MRG_RXBUF, a frame can fill more than one chain,
//! and `num_buffers` gives the count.
//!
//! The device runs on the thread of its backend (the NAT thread), not
//! on the vCPU thread: a notify of the driver goes to `Net.kick`, which
//! on KVM is an ioeventfd that wakes that thread with no exit to user
//! space. The thread holds `Device.lock` while it runs a queue.
//!
//! With VIRTIO_F_RING_EVENT_IDX, the device asks for a notify only when
//! it read each chain of the transmit queue, and it raises an interrupt
//! only when the driver asked for one with `used_event`.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const mmio = @import("mmio.zig");
const queue = @import("queue.zig");
const Device = mmio.Device;
const Host = mmio.Host;
const Chain = queue.Chain;

pub const id = 1;
pub const rx_queue = 0;
pub const tx_queue = 1;

pub const f_csum: u64 = 1 << 0;
pub const f_guest_csum: u64 = 1 << 1;
pub const f_mtu: u64 = 1 << 3;
pub const f_mac: u64 = 1 << 5;
pub const f_guest_tso4: u64 = 1 << 7;
pub const f_guest_tso6: u64 = 1 << 8;
pub const f_host_tso4: u64 = 1 << 11;
pub const f_host_tso6: u64 = 1 << 12;
pub const f_mrg_rxbuf: u64 = 1 << 15;
pub const f_status: u64 = 1 << 16;
pub const f_event_idx: u64 = 1 << 29;

/// `Hdr.flags`.
pub const hdr_needs_csum = 1;
pub const hdr_data_valid = 2;
/// `Hdr.gso_type`.
pub const gso_none = 0;
pub const gso_tcpv4 = 1;
pub const gso_tcpv6 = 4;

pub const hdr_len = 12;
/// The most receive chains of one frame: a frame of 64 KB in buffers
/// of 1,500 bytes needs 44.
pub const max_bufs = 64;
/// The most writable buffers of the chains of one frame.
pub const max_wbufs = 256;

/// The most descriptors of one frame of the guest.
pub const max_parts = Chain.max;

/// The header of a frame (section 5.1.6).
pub const Hdr = struct {
    flags: u8 = 0,
    gso_type: u8 = gso_none,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
    num_buffers: u16 = 0,

    pub fn decode(b: *const [hdr_len]u8) Hdr {
        return .{
            .flags = b[0],
            .gso_type = b[1],
            .hdr_len = std.mem.readInt(u16, b[2..4], .little),
            .gso_size = std.mem.readInt(u16, b[4..6], .little),
            .csum_start = std.mem.readInt(u16, b[6..8], .little),
            .csum_offset = std.mem.readInt(u16, b[8..10], .little),
            .num_buffers = std.mem.readInt(u16, b[10..12], .little),
        };
    }

    pub fn encode(h: Hdr) [hdr_len]u8 {
        var b: [hdr_len]u8 = undefined;
        b[0] = h.flags;
        b[1] = h.gso_type;
        std.mem.writeInt(u16, b[2..4], h.hdr_len, .little);
        std.mem.writeInt(u16, b[4..6], h.gso_size, .little);
        std.mem.writeInt(u16, b[6..8], h.csum_start, .little);
        std.mem.writeInt(u16, b[8..10], h.csum_offset, .little);
        std.mem.writeInt(u16, b[10..12], h.num_buffers, .little);
        return b;
    }
};

/// The receiver of the frames of the guest. The slices are in guest
/// memory and are valid only during the call.
pub const Sink = struct {
    ctx: *anyopaque,
    frame: *const fn (ctx: *anyopaque, h: Hdr, parts: []const []const u8) void,
};

pub const Net = struct {
    mac: [6]u8,
    /// The offloads that the device offers, of `f_csum`, `f_guest_csum`,
    /// `f_host_tso4`, `f_guest_tso4`, and the others above.
    offloads: u64 = f_csum | f_guest_csum,
    /// A notify of the driver for queue `qi`: the backend wakes its
    /// thread, which calls `tx` or its pending `deliver`.
    ctx: *anyopaque,
    kick: *const fn (ctx: *anyopaque, qi: u32) void,
    /// The frames that the device dropped: a bad chain of the guest, or
    /// a frame larger than the receive buffers of the guest.
    dropped: u64 = 0,
    /// The receive chains that the last frame found, when they were too
    /// few for it: `rxArm` waits for one more.
    rx_short: u16 = 0,

    pub fn features(n: *const Net) u64 {
        return mmio.f_version_1 | f_mac | f_status | f_mrg_rxbuf | f_event_idx | n.offloads;
    }

    /// The configuration of section 5.1.4: the MAC address, and the
    /// status with VIRTIO_NET_S_LINK_UP.
    pub fn config(n: *const Net, out: []u8) u8 {
        @memcpy(out[0..6], &n.mac);
        std.mem.writeInt(u16, out[6..8], 1, .little);
        return 8;
    }

    /// Sets the event index of the queues from the features that the
    /// driver accepted. The device calls it at DRIVER_OK.
    pub fn start(_: *Net, d: *Device) void {
        const ev = d.driver_features & f_event_idx != 0;
        for (d.queues[0..2]) |*q| q.event_idx = ev;
    }

    /// Runs the transmit queue: gives each frame to `sink`, then puts the
    /// chains in the used ring. Gives the count of frames.
    pub fn tx(n: *Net, d: *Device, host: *const Host, sink: Sink) usize {
        const q = &d.queues[tx_queue];
        const m = host.mem;
        var count: usize = 0;
        while (true) {
            while (q.next(m)) |head| {
                n.txOne(q, m, head, sink);
                count += 1;
            }
            if (!q.arm(m)) break;
        }
        q.publish(m);
        if (count > 0 and q.needIrq(m)) d.raise(host);
        return count;
    }

    fn txOne(n: *Net, q: *queue.Queue, m: queue.Mem, head: u16, sink: Sink) void {
        defer q.addUsed(m, head, 0);
        const c = Chain.read(q, m, head) orelse return n.drop();
        var hb: [hdr_len]u8 = undefined;
        var got: usize = 0;
        var parts: [Chain.max][]const u8 = undefined;
        var np: usize = 0;
        for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
            if (w) return n.drop();
            var s: []const u8 = b;
            if (got < hdr_len) {
                const k = @min(s.len, hdr_len - got);
                @memcpy(hb[got..][0..k], s[0..k]);
                got += k;
                s = s[k..];
            }
            if (s.len > 0) {
                parts[np] = s;
                np += 1;
            }
        }
        if (got < hdr_len) return n.drop();
        sink.frame(sink.ctx, Hdr.decode(&hb), parts[0..np]);
    }

    fn drop(n: *Net) void {
        n.dropped += 1;
    }

    /// Copies one frame for the guest into receive buffers and makes it
    /// visible to the driver. Gives false when the receive queue has too
    /// few buffers: the frame did not go in, and the caller tries again
    /// after a notify of the receive queue. A frame larger than the
    /// buffers that the driver can give is dropped, with true. The
    /// caller calls `rxDone` after a batch of frames.
    pub fn deliver(n: *Net, d: *Device, host: *const Host, h: Hdr, parts: []const []const u8) bool {
        const q = &d.queues[rx_queue];
        const m = host.mem;
        if (!q.ready) return false;
        var total: usize = hdr_len;
        for (parts) |p| total += p.len;
        const mrg = d.driver_features & f_mrg_rxbuf != 0;
        var src: Gather = .{ .parts = parts };
        var hdr = h;
        // A flag that the driver did not accept goes out of the header.
        if (d.driver_features & f_guest_csum == 0) hdr.flags = 0;
        var hb: [hdr_len]u8 = undefined;
        var taken: u16 = 0;
        var heads: [max_bufs]u16 = undefined;
        var lens: [max_bufs]u32 = undefined;
        // The writable buffers of the chains, from one read of each
        // descriptor: the guest can change a descriptor at any time, so
        // the copy uses these slices and reads no descriptor again.
        var wbufs: [max_wbufs][]u8 = undefined;
        var nw: usize = 0;
        var ends: [max_bufs]usize = undefined;
        var room: usize = 0;
        // First count the chains that the frame needs, then copy, so
        // that a frame that does not fit leaves the ring as it was.
        while (room < total) {
            if (taken == max_bufs or (!mrg and taken == 1)) {
                q.unget(taken);
                // The driver gave buffers smaller than its own MTU:
                // the frame cannot go in, so it is dropped.
                n.drop();
                return true;
            }
            const head = q.next(m) orelse {
                q.unget(taken);
                n.rx_short = taken;
                return false;
            };
            const c = Chain.read(q, m, head) orelse {
                // A bad chain goes back to the driver empty.
                q.addUsed(m, head, 0);
                n.drop();
                continue;
            };
            for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
                if (!w or b.len == 0) continue;
                if (nw == max_wbufs) {
                    // Too many small buffers for one frame.
                    q.unget(taken + 1);
                    n.drop();
                    return true;
                }
                wbufs[nw] = b;
                nw += 1;
                room += b.len;
            }
            heads[taken] = head;
            ends[taken] = nw;
            taken += 1;
        }
        hdr.num_buffers = if (mrg) taken else 0;
        hb = hdr.encode();
        var hput: usize = 0;
        var wi: usize = 0;
        for (lens[0..taken], ends[0..taken]) |*len, e| {
            var put: u32 = 0;
            while (wi < e) : (wi += 1) {
                var dst = wbufs[wi];
                if (hput < hdr_len) {
                    // The header can span the first buffers of a chain.
                    const k = @min(dst.len, hdr_len - hput);
                    @memcpy(dst[0..k], hb[hput..][0..k]);
                    hput += k;
                    put += @intCast(k);
                    dst = dst[k..];
                }
                put += @intCast(src.copy(dst));
            }
            len.* = put;
        }
        for (heads[0..taken], lens[0..taken]) |hd, l| q.addUsed(m, hd, l);
        q.publish(m);
        return true;
    }

    /// The result of `deliverFill`.
    pub const Filled = union(enum) {
        /// The payload bytes of the frame that went to the guest.
        sent: usize,
        /// The receive queue has too few buffers: nothing went in.
        no_room,
        /// The fill gave this value (0, or a negative errno): nothing
        /// went in.
        fill: isize,
    };

    /// The calls of `deliverFill`. `fill` writes the payload into the
    /// receive buffers (for example `recvmsg` of a socket) and gives its
    /// count. `fix` then writes the headers in `head` for that count,
    /// and gives the virtio header.
    pub const Fill = struct {
        ctx: *anyopaque,
        fill: *const fn (ctx: *anyopaque, iov: []const std.posix.iovec) isize,
        fix: *const fn (ctx: *anyopaque, head: []u8, got: usize) Hdr,
    };

    /// One frame for the guest with its payload written in place: the
    /// headers `head` and up to `max` bytes from `f.fill`, straight into
    /// the receive buffers, with no copy in between. With fewer buffers
    /// than the whole frame needs, the frame is smaller, but at least
    /// `min` bytes of payload.
    pub fn deliverFill(n: *Net, d: *Device, host: *const Host, head: []u8, max: usize, min: usize, f: Fill) Filled {
        const q = &d.queues[rx_queue];
        const m = host.mem;
        if (!q.ready) return .no_room;
        const mrg = d.driver_features & f_mrg_rxbuf != 0;
        const pre = hdr_len + head.len;
        var heads: [max_bufs]u16 = undefined;
        var room: [max_bufs]usize = undefined;
        var taken: u16 = 0;
        var total: usize = 0;
        while (total < pre + max and taken < max_bufs and (mrg or taken == 0)) {
            const hd = q.next(m) orelse break;
            const c = Chain.read(q, m, hd) orelse {
                q.addUsed(m, hd, 0);
                n.drop();
                continue;
            };
            var r: usize = 0;
            for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
                if (w) r += b.len;
            }
            heads[taken] = hd;
            room[taken] = r;
            taken += 1;
            total += r;
        }
        if (total < pre + min) {
            q.unget(taken);
            n.rx_short = taken;
            return .no_room;
        }
        // The iovec of the payload: the writable buffers after `pre`.
        var iov: [max_bufs * 4]std.posix.iovec = undefined;
        var ni: usize = 0;
        var skip = pre;
        var want = @min(max, total - pre);
        for (heads[0..taken]) |hd| {
            if (want == 0) break;
            const c = Chain.read(q, m, hd).?;
            for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
                if (!w or want == 0) continue;
                if (skip >= b.len) {
                    skip -= b.len;
                    continue;
                }
                const k = @min(b.len - skip, want);
                if (ni == iov.len) break;
                iov[ni] = .{ .base = b[skip..].ptr, .len = k };
                ni += 1;
                want -= k;
                skip = 0;
            }
        }
        const r = f.fill(f.ctx, iov[0..ni]);
        if (r <= 0) {
            q.unget(taken);
            return .{ .fill = r };
        }
        const got: usize = @intCast(r);
        var hdr = f.fix(f.ctx, head, got);
        if (d.driver_features & f_guest_csum == 0) hdr.flags = 0;
        // The chains that the frame fills; the rest go back.
        var used: u16 = 0;
        var need = pre + got;
        var lens: [max_bufs]u32 = undefined;
        while (need > 0) : (used += 1) {
            const k = @min(need, room[used]);
            lens[used] = @intCast(k);
            need -= k;
        }
        q.unget(taken - used);
        hdr.num_buffers = if (mrg) used else 0;
        const hb = hdr.encode();
        var src: Gather = .{ .parts = &.{ &hb, head } };
        var put: usize = 0;
        for (heads[0..used]) |hd| {
            if (put == pre) break;
            const c = Chain.read(q, m, hd).?;
            for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
                if (!w or put == pre) continue;
                put += src.copy(b[0..@min(b.len, pre - put)]);
            }
        }
        for (heads[0..used], lens[0..used]) |hd, l| q.addUsed(m, hd, l);
        q.publish(m);
        return .{ .sent = got };
    }

    /// Raises the interrupt of the receive queue after a batch of
    /// `deliver`, when the driver asked for one.
    pub fn rxDone(_: *Net, d: *Device, host: *const Host) void {
        const q = &d.queues[rx_queue];
        if (q.needIrq(host.mem)) d.raise(host);
    }

    /// Asks the driver for a notify when it adds receive buffers, and
    /// gives true when it added some in the meantime. After a frame that
    /// found too few buffers, it waits for one more than the frame found,
    /// so that a caller that tries again does not spin.
    pub fn rxArm(n: *Net, d: *Device, host: *const Host) bool {
        return d.queues[rx_queue].armAt(host.mem, n.rx_short);
    }
};

/// A read position in the slices of a frame.
const Gather = struct {
    parts: []const []const u8,
    i: usize = 0,
    off: usize = 0,

    fn copy(g: *Gather, dst: []u8) usize {
        var n: usize = 0;
        while (n < dst.len and g.i < g.parts.len) {
            const p = g.parts[g.i][g.off..];
            const k = @min(p.len, dst.len - n);
            @memcpy(dst[n..][0..k], p[0..k]);
            n += k;
            g.off += k;
            if (g.off == g.parts[g.i].len) {
                g.i += 1;
                g.off = 0;
            }
        }
        return n;
    }
};

// ---------------------------------------------------------------------
// Tests: a fake driver in a fake guest memory, with the rings of the
// receive queue at 0x1000 and of the transmit queue at 0x5000.

const Fake = struct {
    mem: [128 * 1024]u8 align(8) = @splat(0),
    irqs: u32 = 0,
    frames: [4][2048]u8 = undefined,
    lens: [4]usize = @splat(0),
    hdrs: [4]Hdr = undefined,
    nf: usize = 0,

    fn host(f: *Fake) Host {
        return .{ .ctx = f, .mem = f.m(), .interrupt = interrupt };
    }
    fn m(f: *Fake) queue.Mem {
        return .{ .base = &f.mem, .size = f.mem.len };
    }
    fn interrupt(ctx: *anyopaque, _: u32) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.irqs += 1;
    }
    fn kick(_: *anyopaque, _: u32) void {}
    fn frame(ctx: *anyopaque, h: Hdr, parts: []const []const u8) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        var g: Gather = .{ .parts = parts };
        f.lens[f.nf] = g.copy(&f.frames[f.nf]);
        f.hdrs[f.nf] = h;
        f.nf += 1;
    }

    fn reg(d: *Device, h: *const Host, off: u64, v: u32) void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        d.write(h, off, &b);
    }

    /// Accepts `feat` and sets both queues ready, with 8 entries.
    fn setup(d: *Device, h: *const Host, feat: u64) void {
        reg(d, h, 0x024, 0);
        reg(d, h, 0x020, @truncate(feat));
        reg(d, h, 0x024, 1);
        reg(d, h, 0x020, @truncate(feat >> 32));
        for ([_]u32{ 0, 1 }) |qi| {
            const base: u32 = 0x1000 + 0x4000 * qi;
            reg(d, h, 0x030, qi);
            reg(d, h, 0x038, 8);
            reg(d, h, 0x080, base);
            reg(d, h, 0x090, base + 0x1000);
            reg(d, h, 0x0a0, base + 0x2000);
            reg(d, h, 0x044, 1);
        }
        reg(d, h, 0x070, 1 | 2 | 8 | mmio.status_driver_ok);
    }

    /// Makes a chain available on queue `qi`, with its descriptors at
    /// slot `slot` and on.
    fn offer(f: *Fake, qi: u32, slot: u16, bufs: []const struct { u64, u32, bool }) void {
        const mm = f.m();
        const base: u64 = 0x1000 + 0x4000 * @as(u64, qi);
        for (bufs, 0..) |b, i| {
            const at = base + 16 * (slot + i);
            mm.put(u64, at, b[0]);
            mm.put(u32, at + 8, b[1]);
            const more: u16 = if (i + 1 < bufs.len) queue.desc_f_next else 0;
            mm.put(u16, at + 12, more | (if (b[2]) @as(u16, queue.desc_f_write) else 0));
            mm.put(u16, at + 14, @intCast(slot + i + 1));
        }
        const av = base + 0x1000;
        const idx = std.mem.readInt(u16, f.mem[av + 2 ..][0..2], .little);
        mm.put(u16, av + 4 + 2 * @as(u64, idx % 8), slot);
        mm.put(u16, av + 2, idx +% 1);
    }

    fn usedIdx(f: *Fake, qi: u32) u16 {
        const at = 0x1000 + 0x4000 * qi + 0x2002;
        return std.mem.readInt(u16, f.mem[at..][0..2], .little);
    }
    fn usedLen(f: *Fake, qi: u32, i: u16) u32 {
        const at = 0x1000 + 0x4000 * qi + 0x2004 + 8 * @as(usize, i % 8) + 4;
        return std.mem.readInt(u32, f.mem[at..][0..4], .little);
    }
};

fn testDevice(n: *Net) Device {
    var d: Device = .{ .backend = .{ .net = n }, .irq = 5, .features = n.features(), .nqueues = 2 };
    d.config_len = n.config(&d.config);
    return d;
}

test "net: a frame of the guest in two descriptors, with no copy" {
    var f: Fake = .{};
    const h = f.host();
    var n: Net = .{ .mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 }, .ctx = &f, .kick = Fake.kick };
    var d = testDevice(&n);
    Fake.setup(&d, &h, mmio.f_version_1 | f_csum | f_event_idx);
    try std.testing.expect(d.queues[1].event_idx);
    // The header and the first 4 bytes in one descriptor, the rest in
    // another.
    const hb = (Hdr{ .flags = hdr_needs_csum, .csum_start = 34, .csum_offset = 6 }).encode();
    @memcpy(f.mem[0x9000..0x900c], &hb);
    @memcpy(f.mem[0x900c..0x9010], "abcd");
    @memcpy(f.mem[0xa000..0xa003], "efg");
    f.offer(1, 0, &.{ .{ 0x9000, 16, false }, .{ 0xa000, 3, false } });
    try std.testing.expectEqual(@as(usize, 1), n.tx(&d, &h, .{ .ctx = &f, .frame = Fake.frame }));
    try std.testing.expectEqualStrings("abcdefg", f.frames[0][0..f.lens[0]]);
    try std.testing.expectEqual(@as(u16, 34), f.hdrs[0].csum_start);
    try std.testing.expectEqual(@as(u16, 1), f.usedIdx(1));
    // With event index, the device asks for the next notify at chain 1,
    // and raises an interrupt only past used_event (0 here: the first).
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, f.mem[0x7000 + 4 + 8 * 8 ..][0..2], .little));
    try std.testing.expectEqual(@as(u32, 1), f.irqs);
    // used_event 5: no interrupt for the second frame.
    std.mem.writeInt(u16, f.mem[0x6000 + 4 + 2 * 8 ..][0..2], 5, .little);
    f.offer(1, 2, &.{.{ 0x9000, 13, false }});
    _ = n.tx(&d, &h, .{ .ctx = &f, .frame = Fake.frame });
    try std.testing.expectEqual(@as(u32, 1), f.irqs);
    // A chain shorter than the header is dropped and goes back.
    f.offer(1, 3, &.{.{ 0x9000, 5, false }});
    _ = n.tx(&d, &h, .{ .ctx = &f, .frame = Fake.frame });
    try std.testing.expectEqual(@as(u64, 1), n.dropped);
    try std.testing.expectEqual(@as(u16, 3), f.usedIdx(1));
}

test "net: a frame for the guest in mergeable receive buffers" {
    var f: Fake = .{};
    const h = f.host();
    var n: Net = .{ .mac = @splat(0), .ctx = &f, .kick = Fake.kick };
    var d = testDevice(&n);
    Fake.setup(&d, &h, mmio.f_version_1 | f_mrg_rxbuf | f_guest_csum);
    var data: [1500]u8 = undefined;
    for (&data, 0..) |*x, i| x.* = @truncate(i);
    // No buffer: the frame waits.
    try std.testing.expect(!n.deliver(&d, &h, .{}, &.{ data[0..100], data[100..] }));
    // Three buffers of 600 bytes: the frame of 1,512 bytes with its
    // header fills all three.
    f.offer(0, 0, &.{.{ 0x10000, 600, true }});
    f.offer(0, 1, &.{.{ 0x11000, 600, true }});
    try std.testing.expect(!n.deliver(&d, &h, .{}, &.{ data[0..100], data[100..] }));
    try std.testing.expectEqual(@as(u16, 0), f.usedIdx(0));
    f.offer(0, 2, &.{.{ 0x12000, 600, true }});
    try std.testing.expect(n.deliver(&d, &h, .{ .flags = hdr_data_valid }, &.{ data[0..100], data[100..] }));
    n.rxDone(&d, &h);
    try std.testing.expectEqual(@as(u16, 3), f.usedIdx(0));
    try std.testing.expectEqual(@as(u32, 600), f.usedLen(0, 0));
    try std.testing.expectEqual(@as(u32, 312), f.usedLen(0, 2));
    const got = Hdr.decode(f.mem[0x10000..][0..hdr_len]);
    try std.testing.expectEqual(@as(u16, 3), got.num_buffers);
    try std.testing.expectEqual(@as(u8, hdr_data_valid), got.flags);
    try std.testing.expectEqualSlices(u8, data[0..588], f.mem[0x1000c..][0..588]);
    try std.testing.expectEqualSlices(u8, data[588..1188], f.mem[0x11000..][0..600]);
    try std.testing.expectEqualSlices(u8, data[1188..], f.mem[0x12000..][0..312]);
    try std.testing.expectEqual(@as(u32, 1), f.irqs);
}

test "net: with no mergeable buffers, a frame needs one chain" {
    var f: Fake = .{};
    const h = f.host();
    var n: Net = .{ .mac = @splat(0), .ctx = &f, .kick = Fake.kick };
    var d = testDevice(&n);
    Fake.setup(&d, &h, mmio.f_version_1);
    f.offer(0, 0, &.{ .{ 0x10000, 12, true }, .{ 0x11000, 100, true } });
    try std.testing.expect(n.deliver(&d, &h, .{}, &.{"hello"}));
    try std.testing.expectEqual(@as(u32, 17), f.usedLen(0, 0));
    try std.testing.expectEqualStrings("hello", f.mem[0x11000..][0..5]);
    try std.testing.expectEqual(@as(u16, 0), Hdr.decode(f.mem[0x10000..][0..hdr_len]).num_buffers);
    // A frame larger than the chain is dropped, and the chain stays.
    f.offer(0, 2, &.{.{ 0x10000, 20, true }});
    var big: [100]u8 = @splat(1);
    try std.testing.expect(n.deliver(&d, &h, .{}, &.{&big}));
    try std.testing.expectEqual(@as(u64, 1), n.dropped);
    try std.testing.expectEqual(@as(u16, 1), f.usedIdx(0));
}

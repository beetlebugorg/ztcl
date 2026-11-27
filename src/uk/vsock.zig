//! The vsock driver of the ztcl unikernel (ztcl#471), on the virtio-mmio
//! transport (version 2) of the virtio 1.2 specification of OASIS:
//! section 4.2 for the transport, 2.7 for the split virtqueue, and 5.10
//! for the socket device.
//!
//! The monitor lists each device on the command line of the guest
//! (`virtio_mmio.device=4K@ADDR:IRQ`). `init` uses the first device
//! with the ID 19, sets it up (ACKNOWLEDGE, DRIVER, the feature
//! VIRTIO_F_VERSION_1, FEATURES_OK, the three queues, DRIVER_OK), and
//! fills the receive queue and the event queue with buffers.
//!
//! The guest is the server of one stream: the host connects to port
//! 1024, and the driver answers the first REQUEST with RESPONSE. It
//! answers each other REQUEST with RST. The guest reads its own CID from
//! the destination of the REQUEST, so a guest that a snapshot cloned
//! answers on the CID of the clone.
//!
//! Credit (5.10.6.3): the driver gives the host `buf_alloc` bytes of
//! room, the size of its receive ring, and `fwd_cnt`, the bytes that the
//! reader took from that ring. It sends CREDIT_UPDATE when the reader
//! took a quarter of the ring since the last count that the host got.
//! A send waits for the credit of the host: its `buf_alloc` less the
//! bytes in flight.
//!
//! The driver polls the used rings. A wait polls them for `spin_us`
//! first, then runs `sti; hlt`, so the vCPU sleeps until the interrupt
//! of a device or of the timer (`cpu.zig`). The
//! driver reads no InterruptStatus and writes no InterruptACK: the KVM
//! device raises an edge on each interrupt, and the rings tell the work.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const uk = @import("uk.zig");
const cpu = @import("cpu.zig");
const wait = @import("wait.zig");

/// The time that a wait polls the rings before it halts the CPU.
pub var spin_us: u64 = 50;

// The registers of virtio-mmio (4.2.2).
const r_magic = 0x000;
const r_version = 0x004;
const r_device_id = 0x008;
const r_dev_features = 0x010;
const r_dev_features_sel = 0x014;
const r_drv_features = 0x020;
const r_drv_features_sel = 0x024;
const r_queue_sel = 0x030;
const r_queue_num_max = 0x034;
const r_queue_num = 0x038;
const r_queue_ready = 0x044;
const r_queue_notify = 0x050;
const r_status = 0x070;
const r_queue_desc = 0x080;
const r_queue_avail = 0x090;
const r_queue_used = 0x0a0;
const r_config = 0x100;

const st_ack = 1;
const st_driver = 2;
const st_driver_ok = 4;
const st_features_ok = 8;
const st_failed = 128;

const desc_next: u16 = 1;
const desc_write: u16 = 2;

// The packet header of 5.10.6.
const Hdr = extern struct {
    src_cid: u64 align(1),
    dst_cid: u64 align(1),
    src_port: u32 align(1),
    dst_port: u32 align(1),
    len: u32 align(1),
    type: u16 align(1),
    op: u16 align(1),
    flags: u32 align(1),
    buf_alloc: u32 align(1),
    fwd_cnt: u32 align(1),
};
comptime {
    std.debug.assert(@sizeOf(Hdr) == 44);
}
const op_request = 1;
const op_response = 2;
const op_rst = 3;
const op_shutdown = 4;
const op_rw = 5;
const op_credit_update = 6;
const op_credit_request = 7;
const type_stream = 1;
const host_cid = 2;
pub const port: u32 = 1024;

const qsize = 64;
const rx_buf = 4096;

const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };
const UsedElem = extern struct { id: u32, len: u32 };

/// One split virtqueue in the memory of the image. The memory is
/// identity mapped, so a guest physical address is the address of the
/// variable.
const Avail = extern struct { flags: u16, idx: u16, ring: [qsize]u16, used_event: u16 };
const Used = extern struct { flags: u16, idx: u16, ring: [qsize]UsedElem, avail_event: u16 };

const Queue = struct {
    desc: [qsize]Desc align(16) = undefined,
    avail: Avail align(2) = std.mem.zeroes(Avail),
    used: Used align(4) = std.mem.zeroes(Used),
    last_used: u16 = 0,
    free_head: u16 = 0,
    free_count: u16 = 0,

    fn initFree(q: *Queue) void {
        for (0..qsize) |i| q.desc[i] = .{ .addr = 0, .len = 0, .flags = desc_next, .next = @intCast(i + 1) };
        q.free_head = 0;
        q.free_count = qsize;
    }

    fn take(q: *Queue) u16 {
        const d = q.free_head;
        q.free_head = q.desc[d].next;
        q.free_count -= 1;
        return d;
    }

    fn give(q: *Queue, head: u16) void {
        var d = head;
        while (true) {
            q.free_count += 1;
            const f = q.desc[d].flags;
            if (f & desc_next == 0) break;
            d = q.desc[d].next;
        }
        q.desc[d].next = q.free_head;
        q.desc[d].flags = desc_next;
        q.free_head = head;
    }

    fn publish(q: *Queue, head: u16) void {
        q.avail.ring[q.avail.idx % qsize] = head;
        // The ring entry before the index (2.7.13).
        asm volatile ("" ::: .{ .memory = true });
        @atomicStore(u16, &q.avail.idx, q.avail.idx +% 1, .release);
    }

    fn nextUsed(q: *Queue) ?UsedElem {
        const idx = @atomicLoad(u16, &q.used.idx, .acquire);
        if (idx == q.last_used) return null;
        const e = q.used.ring[q.last_used % qsize];
        q.last_used +%= 1;
        return e;
    }
};

var base: usize = 0;
var queues: [3]Queue = .{ .{}, .{}, .{} };
const rxq = &queues[0];
const txq = &queues[1];
const evq = &queues[2];
var rx_hdrs: [qsize / 2]Hdr = undefined;
var rx_data: [qsize / 2][rx_buf]u8 align(4096) = undefined;
var tx_hdrs: [qsize / 2]Hdr = undefined;
var tx_data: [qsize / 2][rx_buf]u8 align(4096) = undefined;
var tx_slot_used: [qsize / 2]bool = @splat(false);
var tx_slot_of: [qsize]u8 = undefined;
var rx_slot_of: [qsize]u8 = undefined;
var events: [4]u32 = undefined;
pub var irq: u8 = 0;

// The one stream.
const ring_size: usize = 256 << 10;
var ring: [ring_size]u8 = undefined;
var ring_head: usize = 0; // the bytes that the reader took
var ring_tail: usize = 0; // the bytes that came in
var fwd_sent: u32 = 0;
var my_cid: u64 = 3;
var peer_port: u32 = 0;
var peer_buf_alloc: u32 = 0;
var peer_fwd_cnt: u32 = 0;
var tx_cnt: u32 = 0;
pub var state: enum { listen, open, closed } = .listen;
var peer_shut_send = false;

fn rd(off: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(base + off)).*;
}

fn wr(off: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(base + off)).* = v;
}

fn parseHex(s: []const u8) ?usize {
    const t = if (std.mem.startsWith(u8, s, "0x")) s[2..] else s;
    return std.fmt.parseInt(usize, t, 16) catch null;
}

/// Finds the device and sets it up. Gives false when the guest has no
/// vsock device.
pub fn init() bool {
    var it = std.mem.tokenizeScalar(u8, uk.cmdline, ' ');
    while (it.next()) |w| {
        const pre = "virtio_mmio.device=4K@";
        if (!std.mem.startsWith(u8, w, pre)) continue;
        const rest = w[pre.len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
        const addr = parseHex(rest[0..colon]) orelse continue;
        base = addr;
        if (rd(r_magic) != 0x74726976 or rd(r_version) != 2 or rd(r_device_id) != 19) continue;
        irq = std.fmt.parseInt(u8, rest[colon + 1 ..], 10) catch continue;
        return setup();
    }
    base = 0;
    return false;
}

fn setup() bool {
    wr(r_status, 0);
    wr(r_status, st_ack);
    wr(r_status, st_ack | st_driver);
    wr(r_dev_features_sel, 1);
    const hi = rd(r_dev_features);
    if (hi & 1 == 0) {
        wr(r_status, st_failed);
        return false;
    }
    wr(r_drv_features_sel, 0);
    wr(r_drv_features, 0);
    wr(r_drv_features_sel, 1);
    wr(r_drv_features, 1); // VIRTIO_F_VERSION_1
    wr(r_status, st_ack | st_driver | st_features_ok);
    if (rd(r_status) & st_features_ok == 0) {
        wr(r_status, st_failed);
        return false;
    }
    for (&queues, 0..) |*q, i| {
        wr(r_queue_sel, @intCast(i));
        if (rd(r_queue_num_max) < qsize) {
            wr(r_status, st_failed);
            return false;
        }
        q.* = .{};
        q.initFree();
        wr(r_queue_num, qsize);
        setAddr(r_queue_desc, @intFromPtr(&q.desc));
        setAddr(r_queue_avail, @intFromPtr(&q.avail));
        setAddr(r_queue_used, @intFromPtr(&q.used));
        wr(r_queue_ready, 1);
    }
    my_cid = @as(u64, rd(r_config)) | (@as(u64, rd(r_config + 4)) << 32);
    for (0..qsize / 2) |i| postRx(@intCast(i));
    for (&events) |*e| {
        const d = evq.take();
        evq.desc[d] = .{ .addr = @intFromPtr(e), .len = 8, .flags = desc_write, .next = 0 };
        evq.publish(d);
    }
    wr(r_status, st_ack | st_driver | st_features_ok | st_driver_ok);
    wr(r_queue_notify, 0);
    wr(r_queue_notify, 2);
    return true;
}

fn setAddr(off: usize, a: usize) void {
    wr(off, @truncate(a));
    wr(off + 4, @truncate(a >> 32));
}

fn postRx(slot: u8) void {
    const h = rxq.take();
    const d = rxq.take();
    rxq.desc[h] = .{ .addr = @intFromPtr(&rx_hdrs[slot]), .len = @sizeOf(Hdr), .flags = desc_write | desc_next, .next = d };
    rxq.desc[d] = .{ .addr = @intFromPtr(&rx_data[slot]), .len = rx_buf, .flags = desc_write, .next = 0 };
    rx_slot_of[h] = slot;
    rxq.publish(h);
}

fn fwdCnt() u32 {
    return @truncate(ring_head);
}

/// Sends one packet: the header and up to `rx_buf` bytes. Gives false
/// when the transmit queue has no free slot.
fn sendPkt(op: u16, flags: u32, data: []const u8) bool {
    _ = reclaimTx();
    const slot = for (tx_slot_used, 0..) |u, i| {
        if (!u) break i;
    } else return false;
    if (txq.free_count < 2) return false;
    tx_slot_used[slot] = true;
    const hdr = &tx_hdrs[slot];
    hdr.* = .{
        .src_cid = my_cid,
        .dst_cid = host_cid,
        .src_port = port,
        .dst_port = peer_port,
        .len = @intCast(data.len),
        .type = type_stream,
        .op = op,
        .flags = flags,
        .buf_alloc = ring_size,
        .fwd_cnt = fwdCnt(),
    };
    fwd_sent = fwdCnt();
    const h = txq.take();
    tx_slot_of[h] = @intCast(slot);
    if (data.len == 0) {
        txq.desc[h] = .{ .addr = @intFromPtr(hdr), .len = @sizeOf(Hdr), .flags = 0, .next = 0 };
    } else {
        const d = txq.take();
        @memcpy(tx_data[slot][0..data.len], data);
        txq.desc[h] = .{ .addr = @intFromPtr(hdr), .len = @sizeOf(Hdr), .flags = desc_next, .next = d };
        txq.desc[d] = .{ .addr = @intFromPtr(&tx_data[slot]), .len = @intCast(data.len), .flags = 0, .next = 0 };
    }
    txq.publish(h);
    wr(r_queue_notify, 1);
    return true;
}

/// Takes back the sent packets. Gives true when one came back.
fn reclaimTx() bool {
    var any = false;
    while (txq.nextUsed()) |e| {
        any = true;
        const h: u16 = @intCast(e.id);
        tx_slot_used[tx_slot_of[h]] = false;
        txq.give(h);
    }
    return any;
}

/// Takes the packets of the receive queue and the event queue, and the
/// sent packets that came back. Gives true when one of them came.
pub fn poll() bool {
    // A packet that came back frees a slot that a send can wait for.
    var any = reclaimTx();
    var posted = false;
    while (rxq.nextUsed()) |e| {
        any = true;
        const h: u16 = @intCast(e.id);
        const slot = rx_slot_of[h];
        rxq.give(h);
        onPacket(&rx_hdrs[slot], &rx_data[slot]);
        postRx(slot);
        posted = true;
    }
    if (posted) wr(r_queue_notify, 0);
    while (evq.nextUsed()) |e| {
        any = true;
        const h: u16 = @intCast(e.id);
        // VIRTIO_VSOCK_EVENT_TRANSPORT_RESET: the stream ends, and the
        // CID can change (5.10.6.6).
        if (events[0] == 0) {
            my_cid = @as(u64, rd(r_config)) | (@as(u64, rd(r_config + 4)) << 32);
            if (state == .open) state = .closed;
        }
        evq.publish(h);
        wr(r_queue_notify, 2);
    }
    return any;
}

fn onPacket(h: *const Hdr, data: *const [rx_buf]u8) void {
    if (h.type != type_stream) return;
    const len = @min(h.len, rx_buf);
    switch (h.op) {
        op_request => {
            if (h.dst_port != port or state == .open) return reply(h, op_rst);
            my_cid = h.dst_cid;
            peer_port = h.src_port;
            peer_buf_alloc = h.buf_alloc;
            peer_fwd_cnt = h.fwd_cnt;
            tx_cnt = 0;
            ring_head = 0;
            ring_tail = 0;
            peer_shut_send = false;
            state = .open;
            _ = sendPkt(op_response, 0, "");
        },
        op_rw => {
            if (state != .open or h.src_port != peer_port) return;
            credit(h);
            // The host keeps to the credit, so the bytes fit.
            const room = ring_size - (ring_tail - ring_head);
            const n = @min(len, room);
            for (data[0..n]) |b| {
                ring[ring_tail % ring_size] = b;
                ring_tail += 1;
            }
        },
        op_credit_update => credit(h),
        op_credit_request => {
            credit(h);
            _ = sendPkt(op_credit_update, 0, "");
        },
        op_shutdown => {
            credit(h);
            if (h.flags & 2 != 0) peer_shut_send = true;
            if (h.flags & 3 == 3) {
                _ = sendPkt(op_rst, 0, "");
                state = .closed;
            }
        },
        op_rst => if (h.src_port == peer_port) {
            state = .closed;
        },
        else => {},
    }
}

fn credit(h: *const Hdr) void {
    peer_buf_alloc = h.buf_alloc;
    peer_fwd_cnt = h.fwd_cnt;
}

fn reply(h: *const Hdr, op: u16) void {
    const save = peer_port;
    peer_port = h.src_port;
    _ = sendPkt(op, 0, "");
    peer_port = save;
}

/// Waits for the host to connect.
pub fn accept() void {
    while (state != .open) waitWork();
}

/// Sleeps until an interrupt when no packet waits and the timer of
/// `cpu.timerAt` is not due.
pub fn waitWork() void {
    // The hot path: poll the rings for `spin_us` before a halt, so a
    // frame that comes soon costs no interrupt and no exit of `hlt`.
    if (wait.tsc_khz != 0) {
        const end = cpu.rdtsc() + spin_us * wait.tsc_khz / 1000;
        while (cpu.rdtsc() < end) {
            if (poll() or cpu.timerDue()) return;
            std.atomic.spinLoopHint();
        }
    }
    cpu.cli();
    if (poll() or cpu.timerDue()) {
        cpu.sti();
        return;
    }
    cpu.stiHlt();
}

/// Gives true when bytes wait to be read, after a poll.
pub fn readable() bool {
    _ = poll();
    return ring_tail != ring_head or state != .open or peer_shut_send;
}

/// Reads at least one byte, or gives 0 at the end of the stream.
pub fn read(buf: []u8) usize {
    while (ring_tail == ring_head) {
        if (state != .open or peer_shut_send) return 0;
        waitWork();
    }
    const n = @min(buf.len, ring_tail - ring_head);
    for (buf[0..n]) |*b| {
        b.* = ring[ring_head % ring_size];
        ring_head += 1;
    }
    if (fwdCnt() -% fwd_sent >= ring_size / 4) _ = sendPkt(op_credit_update, 0, "");
    return n;
}

/// Writes all bytes. Gives false when the stream ended.
pub fn write(bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        if (state != .open) return false;
        const in_flight = tx_cnt -% peer_fwd_cnt;
        const room = if (peer_buf_alloc > in_flight) peer_buf_alloc - in_flight else 0;
        const n = @min(bytes.len - off, rx_buf, room);
        if (n == 0 or !sendPkt(op_rw, 0, bytes[off..][0..n])) {
            if (n == 0) _ = sendPkt(op_credit_request, 0, "");
            waitWork();
            continue;
        }
        tx_cnt +%= @intCast(n);
        off += n;
    }
    return true;
}

/// Ends the stream.
pub fn shutdown() void {
    if (state != .open) return;
    _ = sendPkt(op_shutdown, 3, "");
    state = .closed;
}

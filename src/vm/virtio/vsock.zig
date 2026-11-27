//! The vsock device of virtio 1.2 (section 5.10) in ztcl, for a monitor
//! with no vsock of its host kernel (the Windows Hypervisor Platform;
//! KVM can use it in the place of vhost-vsock). The host is CID 2 and the
//! guest has the CID of the configuration.
//!
//! The device has three queues: receive (0), where the device puts its
//! packets in buffers of the driver, transmit (1), the packets of the
//! driver, and event (2), which this device never uses. A packet is a
//! header of 44 bytes and its data. Each stream is one `Conn`, from a
//! `connect` of the host to a port of the guest:
//!
//! 1. `connect` sends REQUEST. The guest answers RESPONSE (the stream
//!    opens) or RST (no program listens).
//! 2. RW packets carry the data. The host sends at most the credit of
//!    the guest: its `buf_alloc` less the bytes in flight (the bytes
//!    sent less its `fwd_cnt`). The host gives each byte of the guest to
//!    `Sink.data` at once, so its own `fwd_cnt` counts each byte that it
//!    gets, and it sends CREDIT_UPDATE when half its `buf_alloc` went by
//!    and on CREDIT_REQUEST.
//! 3. SHUTDOWN of the guest, or `close` of the host, ends the stream with
//!    RST.
//!
//! A packet that the device cannot send waits in its stream until the
//! driver gives receive buffers (`rxReady`). A REQUEST of the guest gets
//! RST: the host listens on no port yet. The guest is not trusted: each
//! header goes through the checks of `Chain` and the size of the data.
//!
//! The backend calls each function with `Device.lock` held.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const mmio = @import("mmio.zig");
const queue = @import("queue.zig");
const Device = mmio.Device;
const Host = mmio.Host;
const Chain = queue.Chain;
const Mem = queue.Mem;

pub const id = 19;
pub const host_cid: u64 = 2;
const hdr_len = 44;
const type_stream = 1;
/// The buffer of the host that each stream advertises.
pub const buf_alloc: u32 = 256 * 1024;
/// The most streams at once.
pub const max_conns = 64;
/// The most bytes of the host that wait in one stream for the credit of
/// the guest.
pub const tx_max = 256 * 1024;

pub const Op = enum(u16) { invalid = 0, request = 1, response = 2, rst = 3, shutdown = 4, rw = 5, credit_update = 6, credit_request = 7, _ };

/// What the device tells the host of a stream.
pub const Event = enum { connected, refused, closed };

/// The host side of the streams: the bytes of the guest, and the events.
pub const Sink = struct {
    ctx: *anyopaque,
    data: *const fn (ctx: *anyopaque, conn: u32, bytes: []const u8) void,
    event: *const fn (ctx: *anyopaque, conn: u32, e: Event) void,
};

const State = enum { free, connecting, open, closing };

const Conn = struct {
    state: State = .free,
    host_port: u32 = 0,
    guest_port: u32 = 0,
    /// The bytes of the host that wait for the credit of the guest.
    tx: std.ArrayList(u8) = .empty,
    /// The bytes that the host sent, and the credit of the guest.
    tx_cnt: u32 = 0,
    peer_buf_alloc: u32 = 0,
    peer_fwd_cnt: u32 = 0,
    /// The bytes of the guest that the host got, and the count that the
    /// last packet to the guest gave.
    fwd_cnt: u32 = 0,
    fwd_sent: u32 = 0,
    /// The control packet that waits for a receive buffer.
    pending: ?Op = null,

    fn credit(c: *const Conn) u32 {
        const in_flight = c.tx_cnt -% c.peer_fwd_cnt;
        return c.peer_buf_alloc -| in_flight;
    }
};

pub const Vsock = struct {
    gpa: std.mem.Allocator,
    guest_cid: u64,
    sink: Sink,
    conns: [max_conns]Conn = @splat(.{}),
    next_port: u32 = 0x40000000,
    /// The RST packets for the REQUEST packets of the guest, as their
    /// ports (host, guest), which wait for receive buffers.
    refusals: std.ArrayList([2]u32) = .empty,

    pub fn init(gpa: std.mem.Allocator, guest_cid: u64, sink: Sink) Vsock {
        return .{ .gpa = gpa, .guest_cid = guest_cid, .sink = sink };
    }

    pub fn deinit(v: *Vsock) void {
        for (&v.conns) |*c| c.tx.deinit(v.gpa);
        v.refusals.deinit(v.gpa);
    }

    /// Opens a stream to `port` of the guest. Gives its number, or null
    /// when the device has no free stream. `Sink.event` then gives
    /// `connected` or `refused`.
    pub fn connect(v: *Vsock, d: *Device, host: *const Host, port: u32) ?u32 {
        for (&v.conns, 0..) |*c, k| {
            if (c.state != .free) continue;
            c.tx.clearRetainingCapacity();
            const kept = c.tx;
            c.* = .{ .state = .connecting, .host_port = v.next_port, .guest_port = port, .tx = kept, .pending = .request };
            v.next_port +%= 1;
            if (v.next_port < 0x40000000) v.next_port = 0x40000000;
            v.flush(d, host);
            return @intCast(k);
        }
        return null;
    }

    /// Puts bytes for the guest in stream `conn`. Gives the count that
    /// went in: the rest waits for space (`tx_max`).
    pub fn send(v: *Vsock, d: *Device, host: *const Host, conn: u32, bytes: []const u8) usize {
        const c = &v.conns[conn];
        if (c.state != .open and c.state != .connecting) return 0;
        const k = @min(bytes.len, tx_max - @min(c.tx.items.len, tx_max));
        c.tx.appendSlice(v.gpa, bytes[0..k]) catch return 0;
        v.flush(d, host);
        return k;
    }

    /// Ends stream `conn` from the host side with RST.
    pub fn close(v: *Vsock, d: *Device, host: *const Host, conn: u32) void {
        const c = &v.conns[conn];
        if (c.state == .free) return;
        if (c.state == .connecting or c.state == .open) {
            c.state = .closing;
            c.pending = .rst;
            v.flush(d, host);
        }
    }

    /// The bytes of stream `conn` that wait for the credit of the guest.
    pub fn queued(v: *const Vsock, conn: u32) usize {
        return v.conns[conn].tx.items.len;
    }

    /// The notification of the transmit queue: the packets of the driver.
    pub fn tx(v: *Vsock, d: *Device, host: *const Host) void {
        const q = &d.queues[1];
        var any = false;
        while (q.next(host.mem)) |head| {
            any = true;
            if (Chain.read(q, host.mem, head)) |ch| v.packet(d, host, &ch);
            q.putUsed(host.mem, head, 0);
        }
        if (any) d.raise(host);
        v.flush(d, host);
    }

    /// The notification of the receive queue: new buffers of the driver.
    pub fn rxReady(v: *Vsock, d: *Device, host: *const Host) void {
        v.flush(d, host);
    }

    /// The reset of the device by the driver: each stream ends.
    pub fn reset(v: *Vsock) void {
        for (&v.conns, 0..) |*c, k| {
            if (c.state == .free) continue;
            const was = c.state;
            c.state = .free;
            c.tx.clearRetainingCapacity();
            v.sink.event(v.sink.ctx, @intCast(k), if (was == .connecting) .refused else .closed);
        }
        v.refusals.clearRetainingCapacity();
    }

    fn find(v: *Vsock, host_port: u32, guest_port: u32) ?u32 {
        for (&v.conns, 0..) |*c, k| {
            if (c.state != .free and c.host_port == host_port and c.guest_port == guest_port) return @intCast(k);
        }
        return null;
    }

    /// One packet of the driver: its header, then its data, which can
    /// span the next readable buffers.
    fn packet(v: *Vsock, d: *Device, host: *const Host, ch: *const Chain) void {
        _ = d;
        _ = host;
        var hdr: [hdr_len]u8 = undefined;
        var got: usize = 0;
        var first: usize = 0;
        var skip: usize = 0;
        while (first < ch.n and got < hdr_len) : (first += 1) {
            if (ch.writable[first]) return;
            const b = ch.bufs[first];
            const k = @min(b.len, hdr_len - got);
            @memcpy(hdr[got..][0..k], b[0..k]);
            got += k;
            skip = k;
        }
        if (got < hdr_len) return;
        const src_cid = std.mem.readInt(u64, hdr[0..8], .little);
        const dst_cid = std.mem.readInt(u64, hdr[8..16], .little);
        const src_port = std.mem.readInt(u32, hdr[16..20], .little);
        const dst_port = std.mem.readInt(u32, hdr[20..24], .little);
        const len = std.mem.readInt(u32, hdr[24..28], .little);
        const kind = std.mem.readInt(u16, hdr[28..30], .little);
        const op: Op = @fromBackingInt(@intCast(std.mem.readInt(u16, hdr[30..32], .little)));
        const peer_buf = std.mem.readInt(u32, hdr[36..40], .little);
        const peer_fwd = std.mem.readInt(u32, hdr[40..44], .little);
        if (src_cid != v.guest_cid or dst_cid != host_cid or kind != type_stream) return;
        const k = v.find(dst_port, src_port) orelse {
            // A packet of no stream: RST, unless it is RST.
            if (op != .rst) v.refusals.append(v.gpa, .{ dst_port, src_port }) catch {};
            return;
        };
        const c = &v.conns[k];
        c.peer_buf_alloc = peer_buf;
        c.peer_fwd_cnt = peer_fwd;
        switch (op) {
            .response => if (c.state == .connecting) {
                c.state = .open;
                v.sink.event(v.sink.ctx, k, .connected);
            },
            .rst => {
                const was = c.state;
                c.state = .free;
                c.pending = null;
                c.tx.clearRetainingCapacity();
                v.sink.event(v.sink.ctx, k, if (was == .connecting) .refused else .closed);
            },
            // The RST that ends the stream gives the event `closed`.
            .shutdown => {
                c.state = .closing;
                c.pending = .rst;
            },
            .rw => if (c.state == .open) {
                // The data: the rest of the buffer of the end of the
                // header, then the next readable buffers, at most `len`.
                var left: usize = len;
                var i = first - 1;
                var off = skip;
                while (i < ch.n and left > 0) : ({
                    i += 1;
                    off = 0;
                }) {
                    if (ch.writable[i]) break;
                    const b = ch.bufs[i][@min(off, ch.bufs[i].len)..];
                    const n = @min(b.len, left);
                    if (n > 0) v.sink.data(v.sink.ctx, k, b[0..n]);
                    c.fwd_cnt +%= @intCast(n);
                    left -= n;
                }
                if (c.fwd_cnt -% c.fwd_sent >= buf_alloc / 2 and c.pending == null) c.pending = .credit_update;
            },
            .credit_request => if (c.pending == null) {
                c.pending = .credit_update;
            },
            .credit_update, .request, .invalid => {},
            _ => {},
        }
    }

    /// Sends what waits: the refusals, the control packets, then the
    /// data that the credit of the guest allows.
    fn flush(v: *Vsock, d: *Device, host: *const Host) void {
        const q = &d.queues[0];
        var any = false;
        defer if (any) d.raise(host);
        while (v.refusals.items.len > 0) {
            const ports = v.refusals.items[0];
            if (!v.put(q, host.mem, .{ .src_port = ports[0], .dst_port = ports[1], .op = .rst }, &.{})) return;
            any = true;
            _ = v.refusals.orderedRemove(0);
        }
        for (&v.conns, 0..) |*c, k| {
            if (c.state == .free) continue;
            if (c.pending) |op| {
                if (!v.put(q, host.mem, v.header(c, op, 0), &.{})) return;
                any = true;
                c.pending = null;
                c.fwd_sent = c.fwd_cnt;
                if (op == .rst) {
                    c.state = .free;
                    c.tx.clearRetainingCapacity();
                    v.sink.event(v.sink.ctx, @intCast(k), .closed);
                    continue;
                }
            }
            while (c.state == .open and c.tx.items.len > 0) {
                const room = @min(c.credit(), @as(u32, @intCast(c.tx.items.len)));
                if (room == 0) break;
                const n = v.putData(q, host.mem, c, room) orelse return;
                any = true;
                c.tx.replaceRangeAssumeCapacity(0, n, &.{});
            }
        }
    }

    const Header = struct { src_port: u32, dst_port: u32, op: Op, len: u32 = 0, buf_alloc: u32 = buf_alloc, fwd_cnt: u32 = 0 };

    fn header(v: *const Vsock, c: *const Conn, op: Op, len: u32) Header {
        _ = v;
        return .{ .src_port = c.host_port, .dst_port = c.guest_port, .op = op, .len = len, .fwd_cnt = c.fwd_cnt };
    }

    fn writeHeader(v: *const Vsock, out: *[hdr_len]u8, h: Header) void {
        @memset(out, 0);
        std.mem.writeInt(u64, out[0..8], host_cid, .little);
        std.mem.writeInt(u64, out[8..16], v.guest_cid, .little);
        std.mem.writeInt(u32, out[16..20], h.src_port, .little);
        std.mem.writeInt(u32, out[20..24], h.dst_port, .little);
        std.mem.writeInt(u32, out[24..28], h.len, .little);
        std.mem.writeInt(u16, out[28..30], type_stream, .little);
        std.mem.writeInt(u16, out[30..32], @backingInt(h.op), .little);
        std.mem.writeInt(u32, out[36..40], h.buf_alloc, .little);
        std.mem.writeInt(u32, out[40..44], h.fwd_cnt, .little);
    }

    /// Puts one packet with `data` in a receive buffer. False when the
    /// driver has no buffer.
    fn put(v: *const Vsock, q: *queue.Queue, mem: Mem, h: Header, data: []const u8) bool {
        const head = q.next(mem) orelse return false;
        var hdr: [hdr_len]u8 = undefined;
        var hh = h;
        hh.len = @intCast(data.len);
        v.writeHeader(&hdr, hh);
        const written = fill(q, mem, head, &hdr, data);
        q.putUsed(mem, head, written);
        return true;
    }

    /// Puts at most `max` bytes of the queue of `c` in one receive
    /// buffer as RW. Gives the count, or null when the driver has no
    /// buffer.
    fn putData(v: *const Vsock, q: *queue.Queue, mem: Mem, c: *Conn, max: u32) ?usize {
        const head = q.next(mem) orelse return null;
        const ch = Chain.read(q, mem, head) orelse {
            q.putUsed(mem, head, 0);
            return 0;
        };
        var space: usize = 0;
        for (ch.bufs[0..ch.n], ch.writable[0..ch.n]) |b, w| {
            if (w) space += b.len;
        }
        if (space <= hdr_len) {
            q.putUsed(mem, head, 0);
            return 0;
        }
        const n = @min(max, space - hdr_len);
        var hdr: [hdr_len]u8 = undefined;
        v.writeHeader(&hdr, v.header(c, .rw, @intCast(n)));
        const written = fill(q, mem, head, &hdr, c.tx.items[0..n]);
        q.putUsed(mem, head, written);
        c.tx_cnt +%= @intCast(n);
        c.fwd_sent = c.fwd_cnt;
        return n;
    }

    /// Copies the header and the data to the writable buffers of the
    /// chain at `head`, and gives the count of bytes.
    fn fill(q: *queue.Queue, mem: Mem, head: u16, hdr: []const u8, data: []const u8) u32 {
        const ch = Chain.read(q, mem, head) orelse return 0;
        const srcs = [_][]const u8{ hdr, data };
        var si: usize = 0;
        var so: usize = 0;
        var total: u32 = 0;
        for (ch.bufs[0..ch.n], ch.writable[0..ch.n]) |b, w| {
            if (!w) continue;
            var bo: usize = 0;
            while (bo < b.len and si < srcs.len) {
                const s = srcs[si];
                const k = @min(b.len - bo, s.len - so);
                @memcpy(b[bo..][0..k], s[so..][0..k]);
                bo += k;
                so += k;
                total += @intCast(k);
                if (so == s.len) {
                    si += 1;
                    so = 0;
                }
            }
        }
        return total;
    }
};

// The tests run the device against a fake driver: the receive queue has
// its rings at 0x1000, 0x1800, and 0x1c00, and the transmit queue at
// 0x2000, 0x2800, and 0x2c00, with 8 entries each.

const Fake = struct {
    mem: [64 * 1024]u8 align(8) = @splat(0),
    irqs: u32 = 0,
    got: [256]u8 = undefined,
    got_len: usize = 0,
    events: [8]Event = undefined,
    nevents: usize = 0,
    /// The next free descriptor of each queue.
    desc: [2]u16 = .{ 0, 0 },
    /// The count of used entries of the receive queue that the driver read.
    seen: u16 = 0,

    const rings = [2][3]u64{ .{ 0x1000, 0x1800, 0x1c00 }, .{ 0x2000, 0x2800, 0x2c00 } };

    fn m(f: *Fake) Mem {
        return .{ .base = &f.mem, .size = f.mem.len };
    }
    fn host(f: *Fake) Host {
        return .{ .ctx = f, .mem = f.m(), .interrupt = interrupt };
    }
    fn interrupt(ctx: *anyopaque, _: u32) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.irqs += 1;
    }
    fn data(ctx: *anyopaque, _: u32, b: []const u8) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        @memcpy(f.got[f.got_len..][0..b.len], b);
        f.got_len += b.len;
    }
    fn event(ctx: *anyopaque, _: u32, e: Event) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.events[f.nevents] = e;
        f.nevents += 1;
    }
    fn sink(f: *Fake) Sink {
        return .{ .ctx = f, .data = data, .event = event };
    }

    fn reg(d: *Device, h: *const Host, off: u64, v: u32) void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        d.write(h, off, &b);
    }

    fn start(d: *Device, h: *const Host) void {
        for (0..2) |qi| {
            reg(d, h, 0x030, @intCast(qi));
            reg(d, h, 0x038, 8);
            reg(d, h, 0x080, @intCast(rings[qi][0]));
            reg(d, h, 0x090, @intCast(rings[qi][1]));
            reg(d, h, 0x0a0, @intCast(rings[qi][2]));
            reg(d, h, 0x044, 1);
        }
        reg(d, h, 0x070, mmio.status_driver_ok);
    }

    /// Makes one buffer at `addr` available in queue `qi`.
    fn offer(f: *Fake, qi: usize, addr: u64, len: u32, writable: bool) void {
        const mm = f.m();
        const i = f.desc[qi] % 8;
        f.desc[qi] +%= 1;
        const at = rings[qi][0] + 16 * @as(u64, i);
        mm.put(u64, at, addr);
        mm.put(u32, at + 8, len);
        mm.put(u16, at + 12, if (writable) queue.desc_f_write else 0);
        const avail = rings[qi][1];
        const idx = std.mem.readInt(u16, f.mem[@intCast(avail + 2)..][0..2], .little);
        mm.put(u16, avail + 4 + 2 * @as(u64, idx % 8), i);
        mm.put(u16, avail + 2, idx +% 1);
    }

    /// A receive buffer of the driver, and its notification.
    fn rxBuffer(f: *Fake, d: *Device, h: *const Host, addr: u64) void {
        f.offer(0, addr, 4096, true);
        reg(d, h, 0x050, 0);
    }

    const Got = struct { op: Op, src_port: u32, dst_port: u32, dst_cid: u64, buf_alloc: u32, data: []const u8 };

    /// The header and the data of the next used receive buffer.
    fn rxNext(f: *Fake) ?Got {
        const used = rings[0][2];
        const idx = std.mem.readInt(u16, f.mem[@intCast(used + 2)..][0..2], .little);
        if (idx == f.seen) return null;
        const elem = used + 4 + 8 * @as(u64, f.seen % 8);
        f.seen +%= 1;
        const desc_i = std.mem.readInt(u32, f.mem[@intCast(elem)..][0..4], .little);
        const len = std.mem.readInt(u32, f.mem[@intCast(elem + 4)..][0..4], .little);
        const addr = std.mem.readInt(u64, f.mem[@intCast(rings[0][0] + 16 * @as(u64, desc_i))..][0..8], .little);
        const p = f.mem[@intCast(addr)..][0..len];
        return .{
            .dst_cid = std.mem.readInt(u64, p[8..16], .little),
            .src_port = std.mem.readInt(u32, p[16..20], .little),
            .dst_port = std.mem.readInt(u32, p[20..24], .little),
            .op = @fromBackingInt(@intCast(std.mem.readInt(u16, p[30..32], .little))),
            .buf_alloc = std.mem.readInt(u32, p[36..40], .little),
            .data = p[hdr_len..],
        };
    }

    const Packet = struct { src_cid: u64 = 3, src_port: u32, dst_port: u32, op: Op, buf_alloc: u32 = 65536, fwd_cnt: u32 = 0, data: []const u8 = "" };

    /// A packet of the guest at `addr`, and its notification.
    fn txPacket(f: *Fake, d: *Device, h: *const Host, addr: u64, p: Packet) void {
        const mm = f.m();
        @memset(f.mem[@intCast(addr)..][0..hdr_len], 0);
        mm.put(u64, addr, p.src_cid);
        mm.put(u64, addr + 8, host_cid);
        mm.put(u32, addr + 16, p.src_port);
        mm.put(u32, addr + 20, p.dst_port);
        mm.put(u32, addr + 24, @intCast(p.data.len));
        mm.put(u16, addr + 28, type_stream);
        mm.put(u16, addr + 30, @backingInt(p.op));
        mm.put(u32, addr + 36, p.buf_alloc);
        mm.put(u32, addr + 40, p.fwd_cnt);
        @memcpy(f.mem[@intCast(addr + hdr_len)..][0..p.data.len], p.data);
        f.offer(1, addr, @intCast(hdr_len + p.data.len), false);
        reg(d, h, 0x050, 1);
    }
};

test "vsock: a stream from the host to a port of the guest" {
    var f: Fake = .{};
    const h = f.host();
    var v = Vsock.init(std.testing.allocator, 3, f.sink());
    defer v.deinit();
    var d = Device.vsock(7, &v);
    Fake.start(&d, &h);
    // The REQUEST waits for a receive buffer.
    const conn = v.connect(&d, &h, 1024).?;
    try std.testing.expect(f.rxNext() == null);
    f.rxBuffer(&d, &h, 0x8000);
    const req = f.rxNext().?;
    try std.testing.expectEqual(Op.request, req.op);
    try std.testing.expectEqual(@as(u32, 1024), req.dst_port);
    try std.testing.expectEqual(@as(u64, 3), req.dst_cid);
    try std.testing.expectEqual(buf_alloc, req.buf_alloc);
    // The guest accepts: the stream opens.
    f.txPacket(&d, &h, 0x6000, .{ .src_port = 1024, .dst_port = req.src_port, .op = .response });
    try std.testing.expectEqual(Event.connected, f.events[0]);
    // The host sends, and the guest gets RW with the data.
    try std.testing.expectEqual(@as(usize, 5), v.send(&d, &h, conn, "hello"));
    f.rxBuffer(&d, &h, 0x9000);
    const rw = f.rxNext().?;
    try std.testing.expectEqual(Op.rw, rw.op);
    try std.testing.expectEqualStrings("hello", rw.data);
    // The guest sends, and the host gets the data.
    f.txPacket(&d, &h, 0x6000, .{ .src_port = 1024, .dst_port = req.src_port, .op = .rw, .data = "world" });
    try std.testing.expectEqualStrings("world", f.got[0..f.got_len]);
    // The guest shuts the stream down: the host answers RST and closes it.
    f.txPacket(&d, &h, 0x6000, .{ .src_port = 1024, .dst_port = req.src_port, .op = .shutdown });
    f.rxBuffer(&d, &h, 0xa000);
    try std.testing.expectEqual(Op.rst, f.rxNext().?.op);
    try std.testing.expectEqual(@as(usize, 2), f.nevents);
    try std.testing.expectEqual(Event.closed, f.events[1]);
    try std.testing.expect(f.irqs > 0);
}

test "vsock: no program listens on the port" {
    var f: Fake = .{};
    const h = f.host();
    var v = Vsock.init(std.testing.allocator, 3, f.sink());
    defer v.deinit();
    var d = Device.vsock(7, &v);
    Fake.start(&d, &h);
    _ = v.connect(&d, &h, 2000).?;
    f.rxBuffer(&d, &h, 0x8000);
    const req = f.rxNext().?;
    f.txPacket(&d, &h, 0x6000, .{ .src_port = 2000, .dst_port = req.src_port, .op = .rst });
    try std.testing.expectEqual(Event.refused, f.events[0]);
    // A REQUEST of the guest to the host gets RST.
    f.txPacket(&d, &h, 0x6000, .{ .src_port = 5000, .dst_port = 80, .op = .request });
    f.rxBuffer(&d, &h, 0x9000);
    const rst = f.rxNext().?;
    try std.testing.expectEqual(Op.rst, rst.op);
    try std.testing.expectEqual(@as(u32, 5000), rst.dst_port);
    // A packet from another CID is dropped.
    f.txPacket(&d, &h, 0x6000, .{ .src_cid = 9, .src_port = 5001, .dst_port = 81, .op = .request });
    f.rxBuffer(&d, &h, 0xa000);
    try std.testing.expect(f.rxNext() == null);
}

test "vsock: the host sends no more than the credit of the guest" {
    var f: Fake = .{};
    const h = f.host();
    var v = Vsock.init(std.testing.allocator, 3, f.sink());
    defer v.deinit();
    var d = Device.vsock(7, &v);
    Fake.start(&d, &h);
    const conn = v.connect(&d, &h, 1024).?;
    f.rxBuffer(&d, &h, 0x8000);
    const req = f.rxNext().?;
    // The guest has a buffer of 4 bytes.
    f.txPacket(&d, &h, 0x6000, .{ .src_port = 1024, .dst_port = req.src_port, .op = .response, .buf_alloc = 4 });
    _ = v.send(&d, &h, conn, "abcdefgh");
    f.rxBuffer(&d, &h, 0x9000);
    f.rxBuffer(&d, &h, 0xa000);
    try std.testing.expectEqualStrings("abcd", f.rxNext().?.data);
    try std.testing.expect(f.rxNext() == null);
    try std.testing.expectEqual(@as(usize, 4), v.queued(conn));
    // The guest read the 4 bytes: the rest goes.
    f.txPacket(&d, &h, 0x6000, .{ .src_port = 1024, .dst_port = req.src_port, .op = .credit_update, .buf_alloc = 4, .fwd_cnt = 4 });
    try std.testing.expectEqualStrings("efgh", f.rxNext().?.data);
    try std.testing.expectEqual(@as(usize, 0), v.queued(conn));
}

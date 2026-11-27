//! TCP of the NAT (docs/dev/vm-net.md): each TCP connection of the guest
//! ends in the engine, and the engine joins it to a socket of the host.
//! The two halves are separate: the guest sees a TCP peer at the address
//! that it connected to, and the host sees an ordinary client socket.
//!
//! From the guest to the host: the payload of a segment goes to `sendmsg`
//! as an iovec over the descriptors in guest memory, with no copy. A
//! segment can be a TSO segment of up to 64 KB. Only when the host
//! socket is full do the bytes go to the `out` ring of the connection.
//! The window that the engine gives to the guest is the free space of
//! that ring, so the engine never drops bytes of the guest in sequence.
//!
//! From the host to the guest: the engine reads the host socket into the
//! `in` ring and keeps the bytes until the guest acknowledges them, for
//! a retransmission. A segment to the guest is one frame of up to 64 KB
//! (GSO, with VIRTIO_NET_F_GUEST_TSO4) or of one MSS. A full receive
//! queue of the guest stops the send until the driver adds buffers, so
//! the link itself loses no frame.
//!
//! The protocol: RFC 9293 (the state machine and the checks of a
//! segment), RFC 7323 (window scaling), RFC 2018 (SACK: the engine sends
//! SACK-permitted and uses the blocks of the guest to fill the first
//! hole on a fast retransmit), RFC 6298 (the retransmission timer, with
//! a lower bound of 200 ms in place of 1 s, because the link is guest
//! memory), and RFC 5681 (fast retransmit after 3 duplicate ACKs). The
//! engine keeps no congestion window: the link is the receive queue of
//! the guest, which has backpressure and no loss.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const nat = @import("nat.zig");
const engine = @import("engine.zig");
const vnet = @import("../virtio/net.zig");

const Ip4 = nat.Ip4;
const Nat = engine.Nat;
const os = engine.os;

pub const fin: u8 = 0x01;
pub const syn: u8 = 0x02;
pub const rst: u8 = 0x04;
pub const psh: u8 = 0x08;
pub const ack: u8 = 0x10;

pub const max_conns = 1024;
const table_len = 2 * max_conns;
const none: u16 = 0xffff;
/// The bytes of the host that the guest did not acknowledge yet.
pub const in_cap = 256 * 1024;
/// The bytes of the guest that the host socket did not take yet.
pub const out_cap = 256 * 1024;
/// The receive buffer of a host socket in peek mode.
const peek_rcvbuf = 4 << 20;
/// The window scale that the engine sends: windows of up to 1 MB.
const our_ws: u5 = 4;
/// The MSS that the engine sends: the MTU of the device is 1,500.
const our_mss: u16 = 1460;
/// The largest payload of one GSO frame to the guest.
const gso_max: u32 = 65535 - 20 - 20;
const rto_init: u64 = std.time.ns_per_s;
const rto_min: u64 = 200 * std.time.ns_per_ms;
const rto_max: u64 = 60 * std.time.ns_per_s;
/// The retransmissions with no progress before the engine resets.
const max_backoff = 10;
const eth_ip = 14 + 20;
const hdr_max = eth_ip + 20 + 20;

/// A segment of the guest, from its headers.
pub const Seg = struct {
    sport: u16,
    dst: Ip4,
    dport: u16,
    seq: u32,
    ack: u32,
    flags: u8,
    wnd: u16,
    /// The bytes of payload.
    len: u32,
    mss: u16 = 536,
    ws: ?u5 = null,
    sack_ok: bool = false,
    sacks: [4][2]u32 = undefined,
    nsack: u8 = 0,

    /// Reads the options of the TCP header (RFC 9293 3.2, RFC 7323,
    /// RFC 2018). A bad option ends the parse.
    pub fn options(s: *Seg, o: []const u8) void {
        var i: usize = 0;
        while (i < o.len) {
            const kind = o[i];
            if (kind == 0) return;
            if (kind == 1) {
                i += 1;
                continue;
            }
            if (i + 1 >= o.len) return;
            const l = o[i + 1];
            if (l < 2 or i + l > o.len) return;
            const v = o[i + 2 .. i + l];
            switch (kind) {
                2 => if (l == 4) {
                    s.mss = std.mem.readInt(u16, v[0..2], .big);
                },
                3 => if (l == 3) {
                    s.ws = @intCast(@min(v[0], 14));
                },
                4 => if (l == 2) {
                    s.sack_ok = true;
                },
                5 => {
                    var k: usize = 0;
                    while (k + 8 <= v.len and s.nsack < 4) : (k += 8) {
                        s.sacks[s.nsack] = .{ std.mem.readInt(u32, v[k..][0..4], .big), std.mem.readInt(u32, v[k + 4 ..][0..4], .big) };
                        s.nsack += 1;
                    }
                },
                else => {},
            }
            i += l;
        }
    }
};

fn lt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}
fn le(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) <= 0;
}

/// A ring of bytes. `head` is the index of the first byte.
const Ring = struct {
    buf: []u8 = &.{},
    head: usize = 0,
    len: usize = 0,

    fn free(r: *const Ring) usize {
        return r.buf.len - r.len;
    }

    /// The bytes from `off`, as at most two slices, up to `max`.
    fn slices(r: *const Ring, off: usize, max: usize) [2][]const u8 {
        const n = @min(r.len - off, max);
        const s = (r.head + off) % r.buf.len;
        const a = @min(n, r.buf.len - s);
        return .{ r.buf[s..][0..a], r.buf[0 .. n - a] };
    }

    /// The free space, as at most two slices.
    fn space(r: *Ring) [2][]u8 {
        const s = (r.head + r.len) % r.buf.len;
        const n = r.free();
        const a = @min(n, r.buf.len - s);
        return .{ r.buf[s..][0..a], r.buf[0 .. n - a] };
    }

    fn consume(r: *Ring, n: usize) void {
        r.head = (r.head + n) % r.buf.len;
        r.len -= n;
        if (r.len == 0) r.head = 0;
    }

    /// Copies bytes in, up to the free space. Gives the count.
    fn put(r: *Ring, b: []const u8) usize {
        var done: usize = 0;
        for (r.space()) |s| {
            const k = @min(s.len, b.len - done);
            @memcpy(s[0..k], b[done..][0..k]);
            done += k;
        }
        r.len += done;
        return done;
    }
};

const State = enum(u8) { free, connecting, syn_rcvd, open };

pub const Conn = struct {
    state: State = .free,
    fd: i32 = -1,
    sport: u16 = 0,
    dst: Ip4 = @splat(0),
    dport: u16 = 0,
    host: Ip4 = @splat(0),
    // The guest to the host.
    rcv_nxt: u32 = 0,
    out: Ring = .{},
    guest_fin: bool = false,
    shut_wr: bool = false,
    // The host to the guest. The byte at `snd_una` is `in.buf[in.head]`
    // once the connection is open.
    iss: u32 = 0,
    snd_una: u32 = 0,
    snd_nxt: u32 = 0,
    snd_max: u32 = 0,
    snd_wnd: u32 = 0,
    snd_wl1: u32 = 0,
    snd_wl2: u32 = 0,
    in: Ring = .{},
    /// Peek mode (Linux, in process): the bytes of the host stay in the
    /// socket until the guest acknowledges them, and each segment is a
    /// `recvmsg` with MSG_PEEK straight into the receive buffers of the
    /// guest. `peek_off` is the peek offset of the socket, from
    /// `snd_una`. `in` is not used.
    peek: bool = false,
    peek_off: u32 = 0,
    /// The end of the bytes of the host, once `host_eof`, in peek mode.
    eof_end: u32 = 0,
    host_eof: bool = false,
    fin_acked: bool = false,
    mss: u16 = 536,
    /// The shift of the window of the guest, and of the window of the
    /// engine. Both are 0 when the SYN of the guest had no scale.
    ws_guest: u5 = 0,
    ws_ours: u5 = 0,
    sack_ok: bool = false,
    /// The lowest left edge of a SACK block above `snd_una`.
    sack_left: u32 = 0,
    has_sack: bool = false,
    dupacks: u8 = 0,
    // RFC 6298.
    srtt: u64 = 0,
    rttvar: u64 = 0,
    rto: u64 = rto_init,
    rtt_seq: u32 = 0,
    rtt_t: u64 = 0,
    timing: bool = false,
    timer: u64 = 0,
    backoff: u8 = 0,
    // The lists of the end of a batch.
    ack_due: bool = false,
    blocked: bool = false,
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,

    fn dataEnd(c: *const Conn) u32 {
        if (c.peek) return if (c.host_eof) c.eof_end else c.snd_max;
        return c.snd_una +% @as(u32, @intCast(c.in.len));
    }

    fn rwnd(c: *const Conn) u32 {
        return @intCast(out_cap - c.out.len);
    }
};

pub const Tcp = struct {
    conns: []Conn,
    table: [table_len]u16 = @splat(none),
    free_list: [max_conns]u16 = undefined,
    nfree: usize = 0,
    acks: [max_conns]u16 = undefined,
    nacks: usize = 0,
    blocked: [max_conns]u16 = undefined,
    nblocked: usize = 0,
    timers: usize = 0,
    secret: u64 = 0,
    /// The headers of a frame to the guest; `frame` holds a whole frame
    /// when the payload needs a copy (socket mode, or no checksum
    /// offload).
    hdr: [hdr_max]u8 = undefined,
    frame: [nat.max_frame]u8 = undefined,

    pub fn init(t: *Tcp, alloc: std.mem.Allocator, secret: u64) !void {
        t.* = .{ .conns = try alloc.alloc(Conn, max_conns), .secret = secret };
        for (t.conns) |*c| c.* = .{};
        var i: usize = max_conns;
        while (i > 0) {
            i -= 1;
            t.free_list[t.nfree] = @intCast(i);
            t.nfree += 1;
        }
    }

    pub fn deinit(t: *Tcp, alloc: std.mem.Allocator) void {
        for (t.conns) |*c| if (c.state != .free) {
            if (c.fd >= 0) os.close(c.fd);
            freeBufs(c, alloc);
        };
        alloc.free(t.conns);
    }

    pub fn active(t: *const Tcp) usize {
        return max_conns - t.nfree;
    }

    fn hash(sport: u16, dst: Ip4, dport: u16) usize {
        const k: u64 = @as(u64, std.mem.readInt(u32, &dst, .big)) << 32 | @as(u64, sport) << 16 | dport;
        return @intCast((k *% 0x9e3779b97f4a7c15) >> (64 - 11));
    }

    fn find(t: *Tcp, sport: u16, dst: Ip4, dport: u16) ?u16 {
        var i = hash(sport, dst, dport);
        while (t.table[i] != none) : (i = (i + 1) % table_len) {
            const c = &t.conns[t.table[i]];
            if (c.sport == sport and c.dport == dport and std.mem.eql(u8, &c.dst, &dst)) return t.table[i];
        }
        return null;
    }

    fn insert(t: *Tcp, ci: u16) void {
        const c = &t.conns[ci];
        var i = hash(c.sport, c.dst, c.dport);
        while (t.table[i] != none) i = (i + 1) % table_len;
        t.table[i] = ci;
    }

    /// Deletion with linear probing: the later entries of the probe move
    /// back, so that each probe ends at an empty slot.
    fn remove(t: *Tcp, ci: u16) void {
        const c = &t.conns[ci];
        var i = hash(c.sport, c.dst, c.dport);
        while (t.table[i] != ci) i = (i + 1) % table_len;
        t.table[i] = none;
        var hole = i;
        var j = (i + 1) % table_len;
        while (t.table[j] != none) : (j = (j + 1) % table_len) {
            const g = &t.conns[t.table[j]];
            const home = hash(g.sport, g.dst, g.dport);
            if ((j + table_len - home) % table_len >= (j + table_len - hole) % table_len) {
                t.table[hole] = t.table[j];
                t.table[j] = none;
                hole = j;
            }
        }
    }
};

fn tcpOf(n: *Nat) *Tcp {
    return &n.tcp;
}

fn freeBufs(c: *Conn, alloc: std.mem.Allocator) void {
    if (c.in.buf.len > 0) alloc.free(c.in.buf);
    if (c.out.buf.len > 0) alloc.free(c.out.buf);
    c.in = .{};
    c.out = .{};
}

// ---------------------------------------------------------------------
// The frames of the guest

/// One TCP segment of the guest. `payload` is the slices of the payload
/// in guest memory, `s.len` bytes in all.
pub fn input(n: *Nat, s: *const Seg, payload: []const []const u8) void {
    const t = tcpOf(n);
    if (t.find(s.sport, s.dst, s.dport)) |ci| return segment(n, ci, s, payload);
    if (s.flags & rst != 0) return;
    if (s.flags & (syn | ack) != syn) return reset(n, s);
    open(n, s);
}

/// A RST for a segment with no connection (RFC 9293 3.10.7.1).
fn reset(n: *Nat, s: *const Seg) void {
    if (s.flags & ack != 0) {
        sendRaw(n, s.dst, s.dport, s.sport, s.ack, 0, rst, 0, &.{});
    } else {
        var l = s.len;
        if (s.flags & syn != 0) l += 1;
        if (s.flags & fin != 0) l += 1;
        sendRaw(n, s.dst, s.dport, s.sport, 0, s.seq +% l, rst | ack, 0, &.{});
    }
}

fn open(n: *Nat, s: *const Seg) void {
    const t = tcpOf(n);
    const host = n.hostAddr(s.dst, s.dport) orelse return reset(n, s);
    if (!n.allowed(.tcp, s.sport, s.dst, host, s.dport)) return reset(n, s);
    if (t.nfree == 0) return reset(n, s);
    var connected = false;
    const fd = os.tcpConnect(host, s.dport, &connected) orelse return reset(n, s);
    t.nfree -= 1;
    const ci = t.free_list[t.nfree];
    const c = &t.conns[ci];
    const now_ns = engine.now();
    // An ISS from a clock and a hash of the 4-tuple (RFC 6528).
    const h = (@as(u64, std.mem.readInt(u32, &s.dst, .big)) << 32 | @as(u64, s.sport) << 16 | s.dport) ^ t.secret;
    c.* = .{
        .state = .connecting,
        .fd = fd,
        .sport = s.sport,
        .dst = s.dst,
        .dport = s.dport,
        .host = host,
        .rcv_nxt = s.seq +% 1,
        .iss = @truncate((now_ns >> 12) +% (h *% 0x9e3779b97f4a7c15 >> 32)),
        .mss = @max(@min(s.mss, our_mss), 64),
        .sack_ok = s.sack_ok,
        .snd_wnd = s.wnd,
        .snd_wl1 = s.seq,
    };
    if (s.ws) |ws| {
        c.ws_guest = ws;
        c.ws_ours = our_ws;
    }
    os.addConn(n.poll, fd, engine.tag_conn | ci) catch {
        os.close(fd);
        c.* = .{};
        t.free_list[t.nfree] = ci;
        t.nfree += 1;
        return reset(n, s);
    };
    t.insert(ci);
    if (connected) connected_(n, ci);
}

/// The connect of the host socket ended well: SYN-ACK to the guest.
fn connected_(n: *Nat, ci: u16) void {
    const c = &tcpOf(n).conns[ci];
    if (n.canFill()) {
        c.peek = true;
        os.setPeekOff(c.fd, 0);
        // The bytes in flight to the guest stay in the socket, so its
        // receive buffer must hold them and still give the sender a
        // window: the default size of the system is too small for that.
        os.setRcvBuf(c.fd, peek_rcvbuf);
    } else c.in.buf = n.alloc.alloc(u8, in_cap) catch return abort(n, ci, true);
    c.state = .syn_rcvd;
    c.snd_una = c.iss;
    c.snd_nxt = c.iss +% 1;
    c.snd_max = c.snd_nxt;
    sendSynAck(n, c);
    setTimer(n, c, engine.now() + c.rto);
    n.event(.{ .kind = .connect, .proto = .tcp, .guest_port = c.sport, .addr = c.host, .port = c.dport });
}

fn sendSynAck(n: *Nat, c: *Conn) void {
    var o: [12]u8 = undefined;
    var k: usize = 0;
    o[0] = 2;
    o[1] = 4;
    std.mem.writeInt(u16, o[2..4], our_mss, .big);
    k = 4;
    if (c.ws_ours != 0) {
        o[k..][0..4].* = .{ 1, 3, 3, c.ws_ours };
        k += 4;
    }
    if (c.sack_ok) {
        o[k..][0..4].* = .{ 1, 1, 4, 2 };
        k += 4;
    }
    // The window of a SYN is never scaled (RFC 7323 2.2).
    sendRaw(n, c.dst, c.dport, c.sport, c.iss, c.rcv_nxt, syn | ack, @intCast(@min(c.rwnd(), 65535)), o[0..k]);
}

fn segment(n: *Nat, ci: u16, s: *const Seg, payload: []const []const u8) void {
    const c = &tcpOf(n).conns[ci];
    if (s.flags & rst != 0) {
        // A RST in the window ends the connection (RFC 5961 style: only
        // an exact sequence number, to resist a blind reset).
        if (s.seq == c.rcv_nxt or c.state == .connecting) abort(n, ci, false);
        return;
    }
    switch (c.state) {
        .free => return,
        // The SYN again, before the host answered: no answer yet.
        .connecting => return,
        .syn_rcvd => {
            if (s.flags & syn != 0) return sendSynAck(n, c);
            if (s.flags & ack == 0) return;
            if (s.ack != c.iss +% 1) return reset(n, s);
            c.state = .open;
            c.snd_una = s.ack;
            c.snd_wnd = @as(u32, s.wnd) << c.ws_guest;
            c.snd_wl1 = s.seq;
            c.snd_wl2 = s.ack;
            clearTimer(n, c);
            c.backoff = 0;
        },
        .open => {
            if (s.flags & syn != 0) {
                // A SYN in an open connection: an old duplicate. ACK it.
                return dueAck(n, ci);
            }
            if (s.flags & ack == 0) return;
            onAck(n, ci, s);
            if (c.state == .free) return;
        },
    }
    if (s.len > 0 or s.flags & fin != 0) onData(n, ci, s, payload);
    if (c.state == .free) return;
    readHost(n, ci);
    if (c.state == .free) return;
    push(n, ci);
    maybeFree(n, ci);
}

fn onAck(n: *Nat, ci: u16, s: *const Seg) void {
    const c = &tcpOf(n).conns[ci];
    if (lt(c.snd_max, s.ack)) return dueAck(n, ci);
    const wnd = @as(u32, s.wnd) << c.ws_guest;
    const end = c.dataEnd();
    if (lt(c.snd_una, s.ack)) {
        var acked: u32 = s.ack -% c.snd_una;
        if (c.host_eof and lt(end, s.ack)) {
            c.fin_acked = true;
            acked -= 1;
        }
        if (c.peek) {
            if (acked > 0 and os.discard(c.fd, acked) != @as(isize, acked)) return abort(n, ci, true);
            c.peek_off -|= acked;
            c.bytes_in += acked;
        } else c.in.consume(acked);
        c.snd_una = s.ack;
        if (lt(c.snd_nxt, c.snd_una)) c.snd_nxt = c.snd_una;
        if (c.timing and le(c.rtt_seq, s.ack)) {
            c.timing = false;
            sample(c, engine.now() - c.rtt_t);
        }
        c.backoff = 0;
        c.dupacks = 0;
        if (c.snd_una == c.snd_max) clearTimer(n, c) else setTimer(n, c, engine.now() + c.rto);
    } else if (s.ack == c.snd_una and s.len == 0 and s.flags & fin == 0 and wnd == c.snd_wnd and c.snd_una != c.snd_max) {
        c.dupacks += 1;
        if (c.dupacks == 3) {
            c.has_sack = false;
            for (s.sacks[0..s.nsack]) |b| if (lt(c.snd_una, b[0]) and (!c.has_sack or lt(b[0], c.sack_left))) {
                c.sack_left = b[0];
                c.has_sack = true;
            };
            retransmitOne(n, ci);
        }
    }
    // The window update rule of RFC 9293 3.10.7.4.
    if (lt(c.snd_wl1, s.seq) or (c.snd_wl1 == s.seq and le(c.snd_wl2, s.ack))) {
        c.snd_wnd = wnd;
        c.snd_wl1 = s.seq;
        c.snd_wl2 = s.ack;
    }
}

/// An RTT sample (RFC 6298 2.2 and 2.3), with a clock granularity of 1 us.
fn sample(c: *Conn, r: u64) void {
    if (c.srtt == 0) {
        c.srtt = @max(r, 1);
        c.rttvar = r / 2;
    } else {
        const d = if (c.srtt > r) c.srtt - r else r - c.srtt;
        c.rttvar = (3 * c.rttvar + d) / 4;
        c.srtt = (7 * c.srtt + r) / 8;
    }
    c.rto = std.math.clamp(c.srtt + @max(std.time.ns_per_us, 4 * c.rttvar), rto_min, rto_max);
}

fn onData(n: *Nat, ci: u16, s: *const Seg, payload: []const []const u8) void {
    const c = &tcpOf(n).conns[ci];
    if (c.guest_fin) return dueAck(n, ci);
    var skip: u32 = 0;
    if (s.seq != c.rcv_nxt) {
        // A gap: the engine keeps no bytes out of order, so a duplicate
        // ACK asks for the hole.
        if (lt(c.rcv_nxt, s.seq)) return dueAck(n, ci);
        skip = c.rcv_nxt -% s.seq;
        if (skip > s.len or (skip == s.len and s.flags & fin == 0)) return dueAck(n, ci);
    }
    const want = s.len - skip;
    var took: usize = 0;
    if (want > 0) {
        var iov: [vnet.max_parts]os.Iov = undefined;
        var k: usize = 0;
        var off: usize = skip;
        var left: usize = @min(want, c.rwnd());
        for (payload) |p| {
            if (left == 0) break;
            if (off >= p.len) {
                off -= p.len;
                continue;
            }
            const b = p[off..][0..@min(p.len - off, left)];
            off = 0;
            iov[k] = .{ .base = b.ptr, .len = b.len };
            k += 1;
            left -= b.len;
        }
        if (c.out.len == 0) {
            const r = os.sendv(c.fd, iov[0..k]);
            if (r < 0 and r != -@as(isize, @backingInt(std.posix.E.AGAIN))) return abort(n, ci, true);
            if (r > 0) took = @intCast(r);
        }
        // The rest waits in the out ring until the host socket has room.
        var skipped: usize = took;
        for (iov[0..k]) |v| {
            if (skipped >= v.len) {
                skipped -= v.len;
                continue;
            }
            const b = v.base[skipped..v.len];
            skipped = 0;
            if (c.out.buf.len == 0) c.out.buf = n.alloc.alloc(u8, out_cap) catch break;
            const put = c.out.put(b);
            took += put;
            if (put < b.len) break;
        }
        c.bytes_out += took;
    }
    c.rcv_nxt +%= @intCast(took);
    if (s.flags & fin != 0 and took == want) {
        c.rcv_nxt +%= 1;
        c.guest_fin = true;
        shutHost(c);
    }
    dueAck(n, ci);
}

fn shutHost(c: *Conn) void {
    if (c.guest_fin and c.out.len == 0 and !c.shut_wr) {
        c.shut_wr = true;
        os.shutdownWr(c.fd);
    }
}

fn dueAck(n: *Nat, ci: u16) void {
    const t = tcpOf(n);
    const c = &t.conns[ci];
    if (c.ack_due) return;
    c.ack_due = true;
    t.acks[t.nacks] = ci;
    t.nacks += 1;
}

// ---------------------------------------------------------------------
// The host sockets

/// The host socket of connection `ci` is ready: `in` for read, `out` for
/// write (or the end of a connect).
pub fn hostReady(n: *Nat, ci: u16, in: bool, out: bool) void {
    const c = &tcpOf(n).conns[ci];
    switch (c.state) {
        .free => return,
        .connecting => {
            if (!out and !in) return;
            if (os.sockError(c.fd) != 0) {
                n.event(.{ .kind = .refuse, .proto = .tcp, .guest_port = c.sport, .addr = c.host, .port = c.dport });
                return abort(n, ci, true);
            }
            return connected_(n, ci);
        },
        .syn_rcvd => return,
        .open => {},
    }
    if (out and c.out.len > 0) {
        flushOut(n, ci);
        if (c.state == .free) return;
    }
    if (in) readHost(n, ci);
    if (c.state == .free) return;
    push(n, ci);
    maybeFree(n, ci);
}

fn flushOut(n: *Nat, ci: u16) void {
    const c = &tcpOf(n).conns[ci];
    const sl = c.out.slices(0, c.out.len);
    const iov = [2]os.Iov{ .{ .base = sl[0].ptr, .len = sl[0].len }, .{ .base = sl[1].ptr, .len = sl[1].len } };
    const r = os.sendv(c.fd, iov[0..if (sl[1].len > 0) 2 else 1]);
    if (r < 0) {
        if (r == -@as(isize, @backingInt(std.posix.E.AGAIN))) return;
        return abort(n, ci, true);
    }
    const was_closed = c.rwnd() < c.mss;
    c.out.consume(@intCast(r));
    shutHost(c);
    // A window update when the window opens again.
    if (was_closed or c.out.len == 0) dueAck(n, ci);
}

fn readHost(n: *Nat, ci: u16) void {
    const c = &tcpOf(n).conns[ci];
    if (c.state != .open or c.host_eof or c.peek) return;
    while (c.in.free() > 0) {
        const sp = c.in.space();
        const iov = [2]os.IovMut{ .{ .base = sp[0].ptr, .len = sp[0].len }, .{ .base = sp[1].ptr, .len = sp[1].len } };
        const r = os.recvv(c.fd, iov[0..if (sp[1].len > 0) 2 else 1]);
        if (r == 0) {
            c.host_eof = true;
            return;
        }
        if (r < 0) {
            if (r == -@as(isize, @backingInt(std.posix.E.AGAIN))) return;
            return abort(n, ci, true);
        }
        c.in.len += @intCast(r);
        c.bytes_in += @intCast(r);
        if (@as(usize, @intCast(r)) < sp[0].len + sp[1].len) return;
    }
}

// ---------------------------------------------------------------------
// The segments to the guest

/// Sends what the window of the guest allows, then the FIN.
fn push(n: *Nat, ci: u16) void {
    const c = &tcpOf(n).conns[ci];
    if (c.state != .open or c.blocked) return;
    if (c.peek) return pushPeek(n, ci);
    const end = c.dataEnd();
    while (true) {
        const off: u32 = c.snd_nxt -% c.snd_una;
        if (off < c.in.len) {
            const room: i64 = @as(i64, @as(i32, @bitCast(c.snd_una +% c.snd_wnd -% c.snd_nxt)));
            if (room <= 0) {
                // A zero window: the timer sends a probe.
                if (c.timer == 0) setTimer(n, c, engine.now() + c.rto);
                return;
            }
            const len: u32 = @intCast(@min(@as(i64, @intCast(c.in.len - off)), room, segMax(n, c)));
            if (!sendData(n, ci, c.snd_nxt, len, false)) return;
            if (!c.timing and c.snd_nxt == c.snd_max) {
                c.timing = true;
                c.rtt_seq = c.snd_nxt +% len;
                c.rtt_t = engine.now();
            }
            c.snd_nxt +%= len;
        } else if (c.host_eof and c.snd_nxt == end and !c.fin_acked) {
            if (!sendData(n, ci, end, 0, true)) return;
            c.snd_nxt +%= 1;
        } else return;
        if (lt(c.snd_max, c.snd_nxt)) c.snd_max = c.snd_nxt;
        if (c.timer == 0) setTimer(n, c, engine.now() + c.rto);
    }
}

/// `push` in peek mode: the socket holds the bytes, so each segment is
/// a peek, and EOF shows as a peek of 0 bytes at the end.
fn pushPeek(n: *Nat, ci: u16) void {
    const c = &tcpOf(n).conns[ci];
    while (true) {
        if (c.host_eof and !lt(c.snd_nxt, c.eof_end)) {
            if (c.snd_nxt != c.eof_end or c.fin_acked) return;
            if (!sendData(n, ci, c.eof_end, 0, true)) return;
            c.snd_nxt +%= 1;
        } else {
            const room: i32 = @bitCast(c.snd_una +% c.snd_wnd -% c.snd_nxt);
            if (room <= 0) {
                if (c.timer == 0) setTimer(n, c, engine.now() + c.rto);
                return;
            }
            var max: u32 = @min(@as(u32, @intCast(room)), segMax(n, c));
            if (c.host_eof) max = @min(max, c.eof_end -% c.snd_nxt);
            const seq = c.snd_nxt;
            switch (sendPeek(n, ci, seq, max)) {
                .sent => |k| {
                    if (!c.timing and c.snd_nxt == c.snd_max) {
                        c.timing = true;
                        c.rtt_seq = seq +% @as(u32, @intCast(k));
                        c.rtt_t = engine.now();
                    }
                    c.snd_nxt +%= @intCast(k);
                },
                .no_room => return,
                .fill => |e| {
                    if (e == 0) {
                        // A peek at the end of a closed stream.
                        c.host_eof = true;
                        c.eof_end = c.snd_nxt;
                        continue;
                    }
                    if (e == -@as(isize, @backingInt(std.posix.E.AGAIN))) return;
                    return abort(n, ci, true);
                },
            }
        }
        if (lt(c.snd_max, c.snd_nxt)) c.snd_max = c.snd_nxt;
        if (c.timer == 0) setTimer(n, c, engine.now() + c.rto);
    }
}

/// One segment of up to `max` bytes from `seq`, peeked from the socket
/// into the receive buffers of the guest.
fn sendPeek(n: *Nat, ci: u16, seq: u32, max: u32) vnet.Net.Filled {
    const t = tcpOf(n);
    const c = &t.conns[ci];
    const off = seq -% c.snd_una;
    if (off != c.peek_off) {
        os.setPeekOff(c.fd, @intCast(off));
        c.peek_off = off;
    }
    const f: Nat.SegFill = .{ .fd = c.fd, .src = c.dst, .sport = c.dport, .dport = c.sport, .seq = seq, .ackn = c.rcv_nxt, .wnd = @intCast(@min(c.rwnd() >> c.ws_ours, 65535)), .mss = c.mss };
    const r = n.sendFill(&f, max);
    switch (r) {
        .sent => |k| {
            c.peek_off +%= @intCast(k);
            c.ack_due = false;
        },
        .no_room => if (!c.blocked) {
            c.blocked = true;
            t.blocked[t.nblocked] = ci;
            t.nblocked += 1;
        },
        .fill => {},
    }
    return r;
}

fn segMax(n: *Nat, c: *const Conn) u32 {
    if (n.guestTso()) return gso_max / c.mss * c.mss;
    return c.mss;
}

/// The first hole: from `snd_una` to the SACK block above it, or one
/// segment.
fn retransmitOne(n: *Nat, ci: u16) void {
    const c = &tcpOf(n).conns[ci];
    c.timing = false;
    if (c.peek) {
        var max = @min(c.dataEnd() -% c.snd_una, segMax(n, c));
        if (c.has_sack) max = @min(max, c.sack_left -% c.snd_una);
        if (max == 0) {
            if (c.host_eof and !c.fin_acked) _ = sendData(n, ci, c.eof_end, 0, true);
            return;
        }
        _ = sendPeek(n, ci, c.snd_una, max);
        return;
    }
    var len: u32 = @intCast(@min(c.in.len, segMax(n, c)));
    if (c.has_sack) len = @min(len, c.sack_left -% c.snd_una);
    if (len == 0) {
        if (c.host_eof and !c.fin_acked) _ = sendData(n, ci, c.dataEnd(), 0, true);
        return;
    }
    _ = sendData(n, ci, c.snd_una, len, false);
}

/// One segment from `seq`: `len` bytes of `in`, and a FIN when `f`. Gives
/// false when the receive queue of the guest is full: the connection
/// waits for `resume`.
fn sendData(n: *Nat, ci: u16, seq: u32, len: u32, f: bool) bool {
    const t = tcpOf(n);
    const c = &t.conns[ci];
    var flags: u8 = ack;
    if (f) flags |= fin;
    if (len > 0) flags |= psh;
    const wnd = c.rwnd() >> c.ws_ours;
    const sl: [2][]const u8 = if (len == 0) .{ &.{}, &.{} } else c.in.slices(seq -% c.snd_una, len);
    if (!n.sendSeg(c.dst, c.dport, c.sport, seq, c.rcv_nxt, flags, @intCast(@min(wnd, 65535)), &.{}, &sl, c.mss)) {
        if (!c.blocked) {
            c.blocked = true;
            t.blocked[t.nblocked] = ci;
            t.nblocked += 1;
        }
        return false;
    }
    c.ack_due = false;
    return true;
}

/// A segment with no connection state: a RST, an ACK, or a SYN-ACK.
fn sendRaw(n: *Nat, src: Ip4, sport: u16, dport: u16, seq: u32, ackn: u32, flags: u8, wnd: u16, opts: []const u8) void {
    _ = n.sendSeg(src, sport, dport, seq, ackn, flags, wnd, opts, &.{ &.{}, &.{} }, 0);
}

// ---------------------------------------------------------------------
// The end of a batch, timers, and the end of a connection

/// The ACKs that are due, one for each connection and batch.
pub fn flushAcks(n: *Nat) void {
    const t = tcpOf(n);
    var i: usize = 0;
    while (i < t.nacks) : (i += 1) {
        const c = &t.conns[t.acks[i]];
        if (!c.ack_due or c.state == .free) continue;
        c.ack_due = false;
        const wnd = c.rwnd() >> c.ws_ours;
        sendRaw(n, c.dst, c.dport, c.sport, c.snd_nxt, c.rcv_nxt, ack, @intCast(@min(wnd, 65535)), &.{});
    }
    t.nacks = 0;
}

/// The receive queue of the guest has room again.
pub fn resumeAll(n: *Nat) void {
    const t = tcpOf(n);
    // A connection can block again in the loop, and that adds it to
    // `t.blocked`: so the loop runs on a copy.
    const k = t.nblocked;
    var list: [max_conns]u16 = undefined;
    @memcpy(list[0..k], t.blocked[0..k]);
    t.nblocked = 0;
    for (list[0..k]) |ci| {
        const c = &t.conns[ci];
        if (!c.blocked) continue;
        c.blocked = false;
        if (c.state != .open) continue;
        // The receive ring has room for more of the host now.
        readHost(n, ci);
        if (c.state == .free) continue;
        push(n, ci);
        maybeFree(n, ci);
    }
}

fn setTimer(n: *Nat, c: *Conn, at: u64) void {
    if (c.timer == 0) tcpOf(n).timers += 1;
    c.timer = at;
}

fn clearTimer(n: *Nat, c: *Conn) void {
    if (c.timer != 0) tcpOf(n).timers -= 1;
    c.timer = 0;
}

/// The timers that are due at `now_ns` (RFC 6298 5.4 to 5.7).
pub fn tick(n: *Nat, now_ns: u64) void {
    const t = tcpOf(n);
    if (t.timers == 0) return;
    for (t.conns, 0..) |*c, i| {
        if (c.timer == 0 or c.timer > now_ns) continue;
        const ci: u16 = @intCast(i);
        clearTimer(n, c);
        c.backoff += 1;
        if (c.backoff > max_backoff) {
            abort(n, ci, true);
            continue;
        }
        c.rto = @min(c.rto * 2, rto_max);
        c.timing = false;
        switch (c.state) {
            .syn_rcvd => sendSynAck(n, c),
            .open => {
                if (c.peek and c.snd_una == c.snd_max and !c.host_eof) {
                    // A probe of a zero window, in peek mode.
                    switch (sendPeek(n, ci, c.snd_una, 1)) {
                        .sent => if (c.snd_max == c.snd_una) {
                            c.snd_max +%= 1;
                        },
                        else => {},
                    }
                } else if (!c.peek and c.snd_una == c.snd_max and c.in.len > 0) {
                    // A probe of a zero window: one byte past it.
                    _ = sendData(n, ci, c.snd_una, 1, false);
                    if (c.snd_max == c.snd_una) c.snd_max +%= 1;
                } else {
                    c.snd_nxt = c.snd_una;
                    c.has_sack = false;
                    push(n, ci);
                }
            },
            else => {},
        }
        if (c.state != .free and c.timer == 0 and (c.state == .syn_rcvd or c.snd_una != c.snd_max)) setTimer(n, c, now_ns + c.rto);
    }
}

/// The connection ends when both sides sent a FIN and each FIN has its
/// ACK.
fn maybeFree(n: *Nat, ci: u16) void {
    const c = &tcpOf(n).conns[ci];
    if (c.state == .open and c.guest_fin and c.fin_acked and c.out.len == 0) close(n, ci, false);
}

/// Ends the connection; `tell` sends a RST to the guest. A RST to the
/// guest also resets the host socket.
fn abort(n: *Nat, ci: u16, tell: bool) void {
    const c = &tcpOf(n).conns[ci];
    if (tell) {
        const seq = if (c.state == .connecting) 0 else c.snd_nxt;
        sendRaw(n, c.dst, c.dport, c.sport, seq, c.rcv_nxt, rst | ack, 0, &.{});
    }
    close(n, ci, true);
}

fn close(n: *Nat, ci: u16, hard: bool) void {
    const t = tcpOf(n);
    const c = &t.conns[ci];
    if (c.state == .free) return;
    // The ACK of the last FIN of the guest goes out before the end.
    if (!hard and c.ack_due) sendRaw(n, c.dst, c.dport, c.sport, c.snd_nxt, c.rcv_nxt, ack, @intCast(@min(c.rwnd() >> c.ws_ours, 65535)), &.{});
    if (c.state != .connecting) n.event(.{ .kind = .close, .proto = .tcp, .guest_port = c.sport, .addr = c.host, .port = c.dport, .bytes_in = c.bytes_in, .bytes_out = c.bytes_out });
    if (hard) os.lingerZero(c.fd);
    os.close(c.fd);
    clearTimer(n, c);
    freeBufs(c, n.alloc);
    t.remove(ci);
    c.* = .{};
    t.free_list[t.nfree] = ci;
    t.nfree += 1;
}

// ---------------------------------------------------------------------
// Tests

test "tcp: options of a SYN" {
    var s: Seg = .{ .sport = 1, .dst = @splat(0), .dport = 2, .seq = 0, .ack = 0, .flags = syn, .wnd = 0, .len = 0 };
    s.options(&.{ 2, 4, 0x05, 0xb4, 4, 2, 8, 10, 0, 0, 0, 1, 0, 0, 0, 0, 1, 3, 3, 7 });
    try std.testing.expectEqual(@as(u16, 1460), s.mss);
    try std.testing.expect(s.sack_ok);
    try std.testing.expectEqual(@as(?u5, 7), s.ws);
    var a: Seg = s;
    a.options(&.{ 1, 1, 5, 10, 0, 0, 0, 5, 0, 0, 0, 9 });
    try std.testing.expectEqual(@as(u8, 1), a.nsack);
    try std.testing.expectEqual([2]u32{ 5, 9 }, a.sacks[0]);
}

test "tcp: the ring" {
    var b: [8]u8 = undefined;
    var r: Ring = .{ .buf = &b };
    try std.testing.expectEqual(@as(usize, 6), r.put("abcdef"));
    r.consume(4);
    try std.testing.expectEqual(@as(usize, 6), r.put("ghijkl"));
    try std.testing.expectEqual(@as(usize, 0), r.put("m"));
    const s = r.slices(0, 100);
    try std.testing.expectEqualStrings("efgh", s[0]);
    try std.testing.expectEqualStrings("ijkl", s[1]);
    const t = r.slices(3, 2);
    try std.testing.expectEqualStrings("h", t[0]);
    try std.testing.expectEqualStrings("i", t[1]);
}

test "tcp: sequence comparison and the RTO" {
    try std.testing.expect(lt(0xffff_fff0, 5));
    try std.testing.expect(!lt(5, 0xffff_fff0));
    var c: Conn = .{};
    sample(&c, 100 * std.time.ns_per_us);
    try std.testing.expectEqual(rto_min, c.rto);
    sample(&c, 2 * std.time.ns_per_s);
    try std.testing.expect(c.rto > std.time.ns_per_s);
}

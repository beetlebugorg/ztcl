//! The engine of the NAT of `ztcl::vm -net nat` (docs/dev/vm.md, the NAT
//! engine): one thread that runs the protocol code of `nat.zig` (the
//! `Stack`) and the host sockets of the guest.
//!
//! The thread waits on one epoll set (kqueue on macOS) for its wake
//! event, the sockets of the UDP flows, the frame socket, and the
//! descriptors of `watch` (on KVM, the ioeventfds of the virtio-net
//! queues). Only this thread touches the stack, the flows, and the
//! queue of frames for the guest, so the fast path has no lock.
//!
//! The two attachments:
//!
//! - In process (KVM, WHP): `init` with a `Port`. The device of the
//!   backend calls `fromGuest` on this thread from a `watch` callback,
//!   and the engine gives each frame for the guest to `Port.deliver`.
//!   When `deliver` gives false, the frame waits in a ring, in order,
//!   until `rxSpace`.
//! - A frame socket (macOS): `initSocket` with one end of a
//!   `socketpair(AF_UNIX, SOCK_DGRAM)`. Each datagram is one Ethernet
//!   frame with no virtio header.
//!
//! A UDP flow is a connected socket of the host for each (guest port,
//! address, port), in a table with open addressing. The gateway
//! 10.0.2.2 maps to 127.0.0.1. The DNS address 10.0.2.3 maps to the
//! first IPv4 name server of /etc/resolv.conf when `Config.dns` is on.
//! A flow with no traffic for `flow_idle_ns` closes.
//!
//! DNS is part of the policy: a lookup through the name server of the
//! host is a way out of the guest, even for a guest with no other route
//! out (a tunnel in the names of the queries). So the engine reads each
//! query to 10.0.2.3, and the query goes to the server only when
//! `Config.dns_allow` permits its name and the query is in the rate
//! limit. Each other query gets a REFUSED answer from the engine. Each
//! query and each refusal is an event.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const nat = @import("nat.zig");
const tcp = @import("tcp.zig");
const vnet = @import("../virtio/net.zig");

pub const Ip4 = nat.Ip4;
pub const Hdr = vnet.Hdr;
const on_mac = builtin.os.tag == .macos;
const linux = std.os.linux;

pub const Proto = enum(u8) { tcp = 6, udp = 17 };

pub const Event = struct {
    pub const Kind = enum { connect, refuse, close, dns, forward };
    /// The `rule` of a refusal by the rate limit of DNS.
    pub const rule_rate = -2;
    /// The `rule` of a bad DNS query.
    pub const rule_bad = -3;
    kind: Kind,
    proto: Proto,
    guest_port: u16,
    /// The address and port of the host side.
    addr: Ip4,
    port: u16,
    /// The index of the rule that refused: into `allow` or `deny`, or
    /// -1 for the policy of the embedder.
    rule: i32 = -1,
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    /// The name of a DNS query, lower case, valid during the hook.
    name: []const u8 = "",
};

pub const Config = struct {
    /// The network policy of the embedder for each host address, before
    /// a socket opens. Null allows each address.
    policy: ?*const fn (ctx: ?*anyopaque, proto: Proto, addr: Ip4, port: u16) bool = null,
    policy_ctx: ?*anyopaque = null,
    dns: bool = true,
    /// The names that the DNS relay can look up, on the thread of the
    /// engine, with `policy_ctx`. Null permits no name.
    dns_allow: ?*const fn (ctx: ?*anyopaque, name: []const u8) bool = null,
    /// The DNS queries for each second, with a burst of twice as many.
    dns_rate: u32 = 50,
    /// The hook of `ztcl::vm netlog`, on the thread of the engine.
    event: ?*const fn (ctx: ?*anyopaque, ev: *const Event) void = null,
    event_ctx: ?*anyopaque = null,
};

/// The device side of the in-process attachment.
pub const Port = struct {
    ctx: *anyopaque,
    /// One frame for the guest. False: the receive queue has no room.
    deliver: *const fn (ctx: *anyopaque, h: Hdr, parts: []const []const u8) bool,
    /// The end of a batch of `deliver`: the device raises its interrupt.
    flush: *const fn (ctx: *anyopaque) void,
    /// The features that the driver accepted, for the offloads to the
    /// guest (`vnet.f_guest_csum`, `vnet.f_guest_tso4`).
    features: ?*const fn (ctx: *anyopaque) u64 = null,
};

pub const Stats = struct {
    dropped: u64 = 0,
    from_guest: u64 = 0,
    to_guest: u64 = 0,
};

const max_flows = 256;
const flow_idle_ns: u64 = 60 * std.time.ns_per_s;
const ring_len = 256;
const max_watch = 4;
const tag_wake: u64 = 0;
const tag_watch: u64 = 1 << 32;
const tag_flow: u64 = 2 << 32;
const tag_sock: u64 = 3 << 32;
pub const tag_conn: u64 = 4 << 32;
/// The period of the TCP timers while one is set.
const tick_ns: u64 = 5 * std.time.ns_per_ms;

const Flow = struct {
    fd: i32 = -1,
    /// The guest port, and the address and port as the guest sent them.
    sport: u16 = 0,
    dst: Ip4 = @splat(0),
    dport: u16 = 0,
    host: Ip4 = @splat(0),
    last: u64 = 0,
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
};

const Watch = struct {
    fd: i32 = -1,
    ctx: *anyopaque = undefined,
    call: *const fn (ctx: *anyopaque) void = undefined,
};

pub const Nat = struct {
    alloc: std.mem.Allocator,
    cfg: Config,
    port: ?Port = null,
    sock: i32 = -1,
    stack: nat.Stack,
    poll: i32 = -1,
    wake_fd: i32 = -1,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    rx_wanted: std.atomic.Value(bool) = .init(false),
    flows: [max_flows]Flow = @splat(.{}),
    tcp: tcp.Tcp = undefined,
    watches: [max_watch]Watch = @splat(.{}),
    dns_server: ?Ip4 = null,
    /// The token bucket of the DNS rate limit, in 1/1000 of a query.
    dns_tokens: u64 = 0,
    dns_last: u64 = 0,
    stats_: Stats = .{},
    /// The frames for the guest that wait for receive buffers.
    ring: *[ring_len][nat.max_frame]u8,
    ring_lens: [ring_len]u16 = undefined,
    ring_head: usize = 0,
    ring_n: usize = 0,
    delivered: bool = false,
    /// The bytes of a frame of the guest in more than one descriptor.
    scratch: [65536]u8 = undefined,

    /// An engine for a virtio-net device in process.
    pub fn init(alloc: std.mem.Allocator, cfg: Config, port: Port) !*Nat {
        const n = try create(alloc, cfg);
        n.port = port;
        return n;
    }

    /// An engine on a frame socket: one end of a
    /// `socketpair(AF_UNIX, SOCK_DGRAM)`. The engine owns `fd`.
    pub fn initSocket(alloc: std.mem.Allocator, cfg: Config, fd: i32) !*Nat {
        const n = try create(alloc, cfg);
        errdefer n.deinit();
        n.sock = fd;
        const size: c_int = 4 << 20;
        _ = os.setsockopt(fd, os.SOL_SOCKET, os.SO_SNDBUF, std.mem.asBytes(&size));
        _ = os.setsockopt(fd, os.SOL_SOCKET, os.SO_RCVBUF, std.mem.asBytes(&size));
        try os.nonblock(fd);
        try os.add(n.poll, fd, tag_sock);
        return n;
    }

    fn create(alloc: std.mem.Allocator, cfg: Config) !*Nat {
        const n = try alloc.create(Nat);
        errdefer alloc.destroy(n);
        const ring = try alloc.create([ring_len][nat.max_frame]u8);
        errdefer alloc.destroy(ring);
        n.* = .{ .alloc = alloc, .cfg = cfg, .ring = ring, .stack = .{ .host = .{ .ctx = n, .emit = emit, .udpSend = udpSend } } };
        try n.tcp.init(alloc, now() ^ @intFromPtr(n));
        errdefer n.tcp.deinit(alloc);
        n.poll = try os.pollCreate();
        errdefer os.close(n.poll);
        n.wake_fd = try os.wakeCreate(n.poll, tag_wake);
        if (cfg.dns) n.dns_server = readResolvConf();
        n.dns_tokens = @as(u64, cfg.dns_rate) * 2000;
        n.dns_last = now();
        return n;
    }

    /// Closes each socket and frees the engine. Stops the thread first.
    pub fn deinit(n: *Nat) void {
        n.stop();
        for (&n.flows) |*f| if (f.fd >= 0) os.close(f.fd);
        n.tcp.deinit(n.alloc);
        if (n.sock >= 0) os.close(n.sock);
        if (!on_mac and n.wake_fd >= 0) os.close(n.wake_fd);
        os.close(n.poll);
        n.alloc.destroy(n.ring);
        n.alloc.destroy(n);
    }

    pub fn stats(n: *const Nat) Stats {
        var s = n.stats_;
        s.dropped += n.stack.dropped;
        return s;
    }

    /// Calls `call(ctx)` on the thread of the engine each time `fd` (an
    /// eventfd, or an ioeventfd of KVM) is readable. Before `start`.
    pub fn watch(n: *Nat, fd: i32, ctx: *anyopaque, call: *const fn (ctx: *anyopaque) void) !void {
        for (&n.watches, 0..) |*w, i| if (w.fd < 0) {
            w.* = .{ .fd = fd, .ctx = ctx, .call = call };
            return os.add(n.poll, fd, tag_watch | i);
        };
        return error.TooManyWatches;
    }

    pub fn start(n: *Nat) !void {
        n.stopping.store(false, .release);
        n.thread = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, run, .{n});
    }

    pub fn stop(n: *Nat) void {
        const t = n.thread orelse return;
        n.stopping.store(true, .release);
        os.wake(n.wake_fd, n.poll);
        t.join();
        n.thread = null;
    }

    /// The driver added receive buffers. From any thread.
    pub fn rxSpace(n: *Nat) void {
        if (n.rx_wanted.swap(false, .acq_rel)) os.wake(n.wake_fd, n.poll);
    }

    /// One frame of the guest, as the slices of its descriptors. On the
    /// thread of the engine (a `watch` callback), or before `start`.
    pub fn fromGuest(n: *Nat, h: Hdr, parts: []const []const u8) void {
        n.stats_.from_guest += 1;
        if (n.tcpFrame(h, parts)) return;
        if (parts.len == 1) return n.stack.fromGuest(parts[0]);
        var len: usize = 0;
        for (parts) |p| {
            if (len + p.len > n.scratch.len) {
                n.stats_.dropped += 1;
                return;
            }
            @memcpy(n.scratch[len..][0..p.len], p);
            len += p.len;
        }
        n.stack.fromGuest(n.scratch[0..len]);
    }

    /// The `Sink` of `vnet.Net.tx` for this engine.
    pub fn sink(n: *Nat) vnet.Sink {
        return .{ .ctx = n, .frame = sinkFrame };
    }

    fn sinkFrame(ctx: *anyopaque, h: Hdr, parts: []const []const u8) void {
        const n: *Nat = @ptrCast(@alignCast(ctx));
        n.fromGuest(h, parts);
    }

    fn run(n: *Nat) void {
        var evs: [64]os.Ev = undefined;
        var last_sweep: u64 = now();
        var last_tick: u64 = last_sweep;
        while (!n.stopping.load(.acquire)) {
            const busy = n.tcp.timers > 0 or (n.sock >= 0 and n.tcp.nblocked > 0);
            const k = os.wait(n.poll, &evs, if (busy) 5 else 1000);
            for (evs[0..k]) |*e| n.dispatch(e);
            const t = now();
            if (n.tcp.timers > 0 and t - last_tick >= tick_ns) {
                last_tick = t;
                tcp.tick(n, t);
            }
            // A frame socket has no notify for room: a blocked
            // connection tries again on each turn.
            if (n.sock >= 0 and n.tcp.nblocked > 0) tcp.resumeAll(n);
            n.endBatch();
            if (t - last_sweep > std.time.ns_per_s) {
                last_sweep = t;
                n.sweep(t);
            }
        }
    }

    fn dispatch(n: *Nat, e: *const os.Ev) void {
        const tag = os.tag(e);
        const i: usize = @intCast(tag & 0xffffffff);
        switch (tag & ~@as(u64, 0xffffffff)) {
            tag_wake => {
                os.drain(n.wake_fd);
                n.flushRing();
                if (n.ring_n == 0) tcp.resumeAll(n);
            },
            tag_conn => tcp.hostReady(n, @intCast(i), os.isIn(e), os.isOut(e)),
            tag_watch => {
                const w = &n.watches[i];
                os.drain(w.fd);
                w.call(w.ctx);
            },
            tag_flow => n.flowReadable(i),
            tag_sock => n.sockReadable(),
            else => {},
        }
    }

    fn endBatch(n: *Nat) void {
        tcp.flushAcks(n);
        if (n.delivered) {
            n.delivered = false;
            if (n.port) |p| p.flush(p.ctx);
        }
    }

    // -- frames for the guest

    fn emit(ctx: *anyopaque, frame: []const u8) void {
        const n: *Nat = @ptrCast(@alignCast(ctx));
        n.stats_.to_guest += 1;
        if (n.sock >= 0) {
            // A full socket buffer drops the frame, as a full link does.
            if (os.send(n.sock, frame) < 0) n.stats_.dropped += 1;
            return;
        }
        const p = n.port orelse return;
        if (n.ring_n == 0 and n.deliverOne(p, frame)) return;
        if (n.ring_n == ring_len) {
            n.stats_.dropped += 1;
            return;
        }
        const slot = (n.ring_head + n.ring_n) % ring_len;
        @memcpy(n.ring[slot][0..frame.len], frame);
        n.ring_lens[slot] = @intCast(frame.len);
        n.ring_n += 1;
        n.rx_wanted.store(true, .release);
    }

    fn deliverOne(n: *Nat, p: Port, frame: []const u8) bool {
        // The NAT builds each frame with correct checksums, so the guest
        // can skip the check of the payload. The device clears the flag
        // when the driver did not accept VIRTIO_NET_F_GUEST_CSUM.
        const h: Hdr = .{ .flags = vnet.hdr_data_valid };
        if (!p.deliver(p.ctx, h, &.{frame})) return false;
        n.delivered = true;
        return true;
    }

    fn flushRing(n: *Nat) void {
        const p = n.port orelse return;
        while (n.ring_n > 0) {
            const slot = n.ring_head;
            if (!n.deliverOne(p, n.ring[slot][0..n.ring_lens[slot]])) {
                n.rx_wanted.store(true, .release);
                return;
            }
            n.ring_head = (slot + 1) % ring_len;
            n.ring_n -= 1;
        }
    }

    fn sockReadable(n: *Nat) void {
        var buf: [nat.max_frame + 2]u8 = undefined;
        // At most 64 frames for each wake, so the flows also get a turn.
        for (0..64) |_| {
            const r = os.recv(n.sock, &buf);
            if (r <= 0) return;
            if (r > nat.max_frame) {
                n.stats_.dropped += 1;
                continue;
            }
            n.fromGuest(.{}, &.{buf[0..@intCast(r)]});
        }
    }

    // -- UDP flows

    fn udpSend(ctx: *anyopaque, sport: u16, dst: Ip4, dport: u16, payload: []const u8) void {
        const n: *Nat = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, &dst, &nat.dns_ip) and !n.dnsQuery(sport, dport, payload)) return;
        const f = n.flowFor(sport, dst, dport) orelse {
            n.stats_.dropped += 1;
            return;
        };
        f.last = now();
        if (os.send(f.fd, payload) >= 0) f.bytes_out += payload.len else n.stats_.dropped += 1;
    }

    fn hash(sport: u16, dst: Ip4, dport: u16) usize {
        const k: u64 = @as(u64, std.mem.readInt(u32, &dst, .big)) << 32 | @as(u64, sport) << 16 | dport;
        return @intCast((k *% 0x9e3779b97f4a7c15) >> 56);
    }

    fn flowFor(n: *Nat, sport: u16, dst: Ip4, dport: u16) ?*Flow {
        const h = hash(sport, dst, dport);
        var free: ?usize = null;
        for (0..max_flows) |j| {
            const i = (h + j) % max_flows;
            const f = &n.flows[i];
            // `closeFlow` moves entries back, so the first empty slot
            // ends the probe.
            if (f.fd < 0) {
                free = i;
                break;
            }
            if (f.sport == sport and f.dport == dport and std.mem.eql(u8, &f.dst, &dst)) return f;
        }
        const i = free orelse n.evictOldest();
        return n.openFlow(i, sport, dst, dport);
    }

    fn evictOldest(n: *Nat) usize {
        var best: usize = 0;
        for (n.flows, 0..) |f, i| {
            if (f.last < n.flows[best].last) best = i;
        }
        n.closeFlow(best);
        return best;
    }

    /// The host address for an address of the guest: the gateway is the
    /// host loopback, and the DNS address is the name server of the host.
    pub fn hostAddr(n: *const Nat, dst: Ip4, dport: u16) ?Ip4 {
        if (std.mem.eql(u8, &dst, &nat.gateway_ip)) return .{ 127, 0, 0, 1 };
        if (std.mem.eql(u8, &dst, &nat.dns_ip)) return if (dport == 53) n.dns_server else null;
        return dst;
    }

    /// The policy for a new flow or connection. A refusal is an event.
    pub fn allowed(n: *Nat, proto: Proto, sport: u16, dst: Ip4, host: Ip4, dport: u16) bool {
        // A UDP flow to the DNS address carries only the queries that
        // passed `dnsQuery`. TCP to it has no relay, so no name passes
        // the check of the names there.
        if (std.mem.eql(u8, &dst, &nat.dns_ip)) return proto == .udp;
        const pol = n.cfg.policy orelse return true;
        if (pol(n.cfg.policy_ctx, proto, host, dport)) return true;
        n.event(.{ .kind = .refuse, .proto = proto, .guest_port = sport, .addr = host, .port = dport });
        return false;
    }

    fn openFlow(n: *Nat, i: usize, sport: u16, dst: Ip4, dport: u16) ?*Flow {
        const host = n.hostAddr(dst, dport) orelse return null;
        const is_dns = std.mem.eql(u8, &dst, &nat.dns_ip);
        if (!n.allowed(.udp, sport, dst, host, dport)) return null;
        const fd = os.udpConnect(host, dport) orelse return null;
        os.add(n.poll, fd, tag_flow | i) catch {
            os.close(fd);
            return null;
        };
        n.flows[i] = .{ .fd = fd, .sport = sport, .dst = dst, .dport = dport, .host = host, .last = now() };
        if (!is_dns) n.event(.{ .kind = .connect, .proto = .udp, .guest_port = sport, .addr = host, .port = dport });
        return &n.flows[i];
    }

    fn closeFlow(n: *Nat, i: usize) void {
        const f = &n.flows[i];
        if (f.fd < 0) return;
        n.event(.{ .kind = .close, .proto = .udp, .guest_port = f.sport, .addr = f.host, .port = f.dport, .bytes_in = f.bytes_in, .bytes_out = f.bytes_out });
        os.close(f.fd);
        f.* = .{};
        // Moves the later entries of the probe back (deletion in a table
        // with linear probing), so that each probe ends at an empty slot.
        var hole = i;
        var j = (i + 1) % max_flows;
        while (n.flows[j].fd >= 0) : (j = (j + 1) % max_flows) {
            const g = &n.flows[j];
            const home = hash(g.sport, g.dst, g.dport);
            // The entry can move to the hole when the hole is on its
            // probe path: from home to j, the hole comes first.
            if ((j + max_flows - home) % max_flows >= (j + max_flows - hole) % max_flows) {
                n.flows[hole] = g.*;
                os.retag(n.poll, g.fd, tag_flow | hole);
                g.* = .{};
                hole = j;
            }
        }
    }

    fn flowReadable(n: *Nat, i: usize) void {
        const f = &n.flows[i];
        if (f.fd < 0) return;
        var buf: [nat.max_frame]u8 = undefined;
        for (0..64) |_| {
            const r = os.recv(f.fd, &buf);
            if (r < 0) return;
            f.last = now();
            f.bytes_in += @intCast(r);
            n.stack.udpToGuest(f.dst, f.dport, f.sport, buf[0..@intCast(r)]);
        }
    }

    fn sweep(n: *Nat, t: u64) void {
        var i: usize = 0;
        while (i < max_flows) : (i += 1) {
            const f = &n.flows[i];
            if (f.fd >= 0 and t - f.last > flow_idle_ns) n.closeFlow(i);
        }
    }

    /// Checks a DNS query of the guest. True: the query goes to the
    /// server. False: the engine answered REFUSED, or dropped it.
    fn dnsQuery(n: *Nat, sport: u16, dport: u16, q: []const u8) bool {
        const server = n.dns_server orelse {
            n.stats_.dropped += 1;
            return false;
        };
        if (dport != 53) {
            n.stats_.dropped += 1;
            return false;
        }
        var nb: [256]u8 = undefined;
        var e: Event = .{ .kind = .refuse, .proto = .udp, .guest_port = sport, .addr = server, .port = 53, .bytes_out = q.len };
        const qd = parseQuery(q, &nb) orelse {
            e.rule = Event.rule_bad;
            n.event(e);
            // A query with a whole header gets an answer, with no
            // question.
            if (q.len >= 12) n.dnsRefuse(sport, q, 12);
            return false;
        };
        e.name = qd.name;
        // The bucket fills at `dns_rate` queries each second, up to
        // twice that.
        const t = now();
        const cap = @as(u64, n.cfg.dns_rate) * 2000;
        n.dns_tokens = @min(cap, n.dns_tokens +| (t - n.dns_last) / std.time.ns_per_us * n.cfg.dns_rate / 1000);
        n.dns_last = t;
        if (n.dns_tokens < 1000) {
            e.rule = Event.rule_rate;
            n.event(e);
            n.dnsRefuse(sport, q, qd.end);
            return false;
        }
        n.dns_tokens -= 1000;
        const ok = if (n.cfg.dns_allow) |f| f(n.cfg.policy_ctx, qd.name) else false;
        if (!ok) {
            n.event(e);
            n.dnsRefuse(sport, q, qd.end);
            return false;
        }
        e.kind = .dns;
        n.event(e);
        return true;
    }

    /// The answer REFUSED (RCODE 5, RFC 1035 4.1.1) to a query, with the
    /// header and the question: the first `qlen` bytes of `q`.
    fn dnsRefuse(n: *Nat, sport: u16, q: []const u8, qlen: usize) void {
        var r: [12 + 260]u8 = undefined;
        @memcpy(r[0..qlen], q[0..qlen]);
        r[2] = 0x80 | (q[2] & 0x79); // QR, the opcode, RD
        r[3] = 0x80 | 5; // RA, REFUSED
        std.mem.writeInt(u16, r[4..6], if (qlen > 12) 1 else 0, .big);
        @memset(r[6..12], 0);
        n.stack.udpToGuest(nat.dns_ip, 53, sport, r[0..qlen]);
    }

    pub fn event(n: *Nat, ev: Event) void {
        if (n.cfg.event) |hook| hook(n.cfg.event_ctx, &ev);
    }

    // -- TCP

    fn features(n: *const Nat) u64 {
        const p = n.port orelse return 0;
        const f = p.features orelse return 0;
        return f(p.ctx);
    }

    /// The guest takes GSO frames of TCP (and so a partial checksum).
    pub fn guestTso(n: *const Nat) bool {
        const want = vnet.f_guest_tso4 | vnet.f_guest_csum;
        return n.features() & want == want;
    }

    /// A TCP frame of the guest goes to `tcp.input` with its payload in
    /// place. Gives false for each other frame.
    fn tcpFrame(n: *Nat, h: Hdr, parts: []const []const u8) bool {
        _ = h;
        // The headers can span descriptors: at most 134 bytes of them
        // are copied.
        var hb: [14 + 60 + 60]u8 = undefined;
        var got: usize = 0;
        var total: usize = 0;
        for (parts) |p| {
            total += p.len;
            if (got < hb.len) {
                const k = @min(p.len, hb.len - got);
                @memcpy(hb[got..][0..k], p[0..k]);
                got += k;
            }
        }
        if (got < 54 or std.mem.readInt(u16, hb[12..14], .big) != 0x0800) return false;
        const ip = hb[14..];
        if (ip[0] >> 4 != 4 or ip[9] != 6) return false;
        const ihl = @as(usize, ip[0] & 0xf) * 4;
        const tot = std.mem.readInt(u16, ip[2..4], .big);
        if (ihl < 20 or 14 + ihl + 20 > got or std.mem.readInt(u16, ip[6..8], .big) & 0x3fff != 0 or
            !std.mem.eql(u8, ip[12..16], &nat.guest_ip))
        {
            n.stats_.dropped += 1;
            return true;
        }
        const dst: Ip4 = ip[16..20].*;
        if (dst[0] == 10 and dst[1] == 0 and dst[2] == 2 and !std.mem.eql(u8, &dst, &nat.gateway_ip) and !std.mem.eql(u8, &dst, &nat.dns_ip)) {
            n.stats_.dropped += 1;
            return true;
        }
        const th = hb[14 + ihl ..];
        const doff = @as(usize, th[12] >> 4) * 4;
        const hl = 14 + ihl + doff;
        if (doff < 20 or hl > got or tot < ihl + doff or 14 + @as(usize, tot) > total) {
            n.stats_.dropped += 1;
            return true;
        }
        var s: tcp.Seg = .{
            .sport = std.mem.readInt(u16, th[0..2], .big),
            .dst = dst,
            .dport = std.mem.readInt(u16, th[2..4], .big),
            .seq = std.mem.readInt(u32, th[4..8], .big),
            .ack = std.mem.readInt(u32, th[8..12], .big),
            .flags = th[13],
            .wnd = std.mem.readInt(u16, th[14..16], .big),
            .len = @intCast(tot - ihl - doff),
        };
        if (doff > 20) s.options(th[20..doff]);
        // The payload, as slices of the descriptors, past the headers.
        var pl: [vnet.max_parts][]const u8 = undefined;
        var np: usize = 0;
        var skip = hl;
        var left: usize = s.len;
        for (parts) |p| {
            if (left == 0) break;
            if (skip >= p.len) {
                skip -= p.len;
                continue;
            }
            const b = p[skip..][0..@min(p.len - skip, left)];
            skip = 0;
            pl[np] = b;
            np += 1;
            left -= b.len;
        }
        tcp.input(n, &s, pl[0..np]);
        return true;
    }

    /// A TCP segment to the guest: from `src:sport` to the guest port
    /// `dport`, with `opts` and the payload `pl`. A segment with no
    /// payload goes through `emit`; a segment with payload gives false
    /// when the guest has no room, and then nothing went out. A payload
    /// longer than `mss` goes as one GSO frame.
    pub fn sendSeg(n: *Nat, src: Ip4, sport: u16, dport: u16, seq: u32, ackn: u32, flags: u8, wnd: u16, opts: []const u8, pl: *const [2][]const u8, mss: u16) bool {
        const len = pl[0].len + pl[1].len;
        const th_len = 20 + opts.len;
        const hl = 34 + th_len;
        const o = &n.tcp.hdr;
        @memcpy(o[0..6], &nat.guest_mac);
        @memcpy(o[6..12], &nat.gateway_mac);
        std.mem.writeInt(u16, o[12..14], 0x0800, .big);
        const ip = o[14..34];
        ip[0] = 0x45;
        ip[1] = 0;
        std.mem.writeInt(u16, ip[2..4], @intCast(@min(20 + th_len + len, 65535)), .big);
        std.mem.writeInt(u16, ip[4..6], 0, .big);
        std.mem.writeInt(u16, ip[6..8], 0x4000, .big);
        ip[8] = 64;
        ip[9] = 6;
        std.mem.writeInt(u16, ip[10..12], 0, .big);
        @memcpy(ip[12..16], &src);
        @memcpy(ip[16..20], &nat.guest_ip);
        std.mem.writeInt(u16, ip[10..12], nat.checksum(ip, 0), .big);
        const th = o[34..hl];
        std.mem.writeInt(u16, th[0..2], sport, .big);
        std.mem.writeInt(u16, th[2..4], dport, .big);
        std.mem.writeInt(u32, th[4..8], seq, .big);
        std.mem.writeInt(u32, th[8..12], ackn, .big);
        th[12] = @intCast(th_len / 4 << 4);
        th[13] = flags;
        std.mem.writeInt(u16, th[14..16], wnd, .big);
        std.mem.writeInt(u32, th[16..20], 0, .big);
        @memcpy(th[20..], opts);
        const ps = nat.pseudo(src, nat.guest_ip, 6, th_len + len);
        if (len == 0) {
            std.mem.writeInt(u16, th[16..18], nat.checksum(th, ps), .big);
            emit(n, o[0..hl]);
            return true;
        }
        // Frames that wait in the ring go first, in order.
        if (n.ring_n > 0) n.flushRing();
        if (n.ring_n > 0) return false;
        if (n.port != null and n.features() & vnet.f_guest_csum != 0) {
            // A partial checksum: the field holds the sum of the
            // pseudo-header, and the guest takes the payload as valid.
            std.mem.writeInt(u16, th[16..18], ~nat.checksum(&.{}, ps), .big);
            var h: Hdr = .{ .flags = vnet.hdr_needs_csum, .csum_start = 34, .csum_offset = 16, .hdr_len = @intCast(hl) };
            if (len > mss) {
                h.gso_type = vnet.gso_tcpv4;
                h.gso_size = mss;
            }
            const p = n.port.?;
            if (!p.deliver(p.ctx, h, &.{ o[0..hl], pl[0], pl[1] })) {
                n.rx_wanted.store(true, .release);
                return false;
            }
            n.delivered = true;
            n.stats_.to_guest += 1;
            return true;
        }
        // No offload: one frame of at most one MSS, with its checksum.
        if (hl + len > nat.max_frame) return true;
        const f = &n.tcp.frame;
        @memcpy(f[0..hl], o[0..hl]);
        @memcpy(f[hl..][0..pl[0].len], pl[0]);
        @memcpy(f[hl + pl[0].len ..][0..pl[1].len], pl[1]);
        std.mem.writeInt(u16, f[50..52], nat.checksum(f[34 .. hl + len], ps), .big);
        const frame = f[0 .. hl + len];
        if (n.sock >= 0) {
            if (os.send(n.sock, frame) < 0) return false;
            n.stats_.to_guest += 1;
            return true;
        }
        const p = n.port orelse return true;
        if (!n.deliverOne(p, frame)) {
            n.rx_wanted.store(true, .release);
            return false;
        }
        n.stats_.to_guest += 1;
        return true;
    }
};

pub fn now() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub const Query = struct {
    /// The name in lower case, with dots and no last dot.
    name: []const u8,
    /// The end of the question in the query.
    end: usize,
};

/// Reads a standard query (RFC 1035 4.1) with one question. The name
/// goes to `buf`. Gives null for each other message: an answer, another
/// opcode, more than one question, a record other than one OPT of EDNS,
/// a compression pointer, or a bad label.
pub fn parseQuery(q: []const u8, buf: *[256]u8) ?Query {
    if (q.len < 12 + 5) return null;
    if (q[2] & 0xf8 != 0) return null; // QR 0, opcode 0 (QUERY)
    const qd = std.mem.readInt(u16, q[4..6], .big);
    const an = std.mem.readInt(u16, q[6..8], .big);
    const ns = std.mem.readInt(u16, q[8..10], .big);
    const ar = std.mem.readInt(u16, q[10..12], .big);
    if (qd != 1 or an != 0 or ns != 0 or ar > 1) return null;
    var i: usize = 12;
    var len: usize = 0;
    while (true) {
        if (i >= q.len) return null;
        const l = q[i];
        i += 1;
        if (l == 0) break;
        // A name is at most 253 characters (RFC 1035 3.1).
        if (l > 63 or i + l > q.len or len + l + 1 > 254) return null;
        if (len > 0) {
            buf[len] = '.';
            len += 1;
        }
        for (q[i..][0..l]) |ch| {
            // Letters, digits, '-', and '_' (of SRV and other labels).
            if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return null;
            buf[len] = std.ascii.toLower(ch);
            len += 1;
        }
        i += l;
    }
    if (len == 0 or i + 4 > q.len) return null;
    return .{ .name = buf[0..len], .end = i + 4 };
}

/// A name matches a host of an allow list: the same name, or a pattern
/// `*.SUFFIX` and a name below SUFFIX. Case does not matter.
pub fn nameMatch(pattern: []const u8, name: []const u8) bool {
    var p = pattern;
    if (p.len > 0 and p[p.len - 1] == '.') p = p[0 .. p.len - 1];
    if (std.mem.startsWith(u8, p, "*.")) {
        const suf = p[1..];
        return name.len > suf.len and std.ascii.endsWithIgnoreCase(name, suf);
    }
    return std.ascii.eqlIgnoreCase(p, name);
}

/// The first IPv4 `nameserver` of /etc/resolv.conf.
fn readResolvConf() ?Ip4 {
    var buf: [4096]u8 = undefined;
    const len = os.readFile("/etc/resolv.conf", &buf) orelse return null;
    var lines = std.mem.splitScalar(u8, buf[0..len], '\n');
    while (lines.next()) |line| {
        var w = std.mem.tokenizeAny(u8, line, " \t\r");
        const key = w.next() orelse continue;
        if (!std.mem.eql(u8, key, "nameserver")) continue;
        const v = w.next() orelse continue;
        if (parseIp4(v)) |a| return a;
    }
    return null;
}

pub fn parseIp4(s: []const u8) ?Ip4 {
    var a: Ip4 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    for (&a) |*x| x.* = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return a;
}

/// The system calls of the engine: Linux with direct calls, macOS with
/// libc and kqueue.
pub const os = if (on_mac) mac_os else linux_os;

const linux_os = struct {
    const Ev = linux.epoll_event;
    const SOL_SOCKET = linux.SOL.SOCKET;
    const SO_SNDBUF = linux.SO.SNDBUF;
    const SO_RCVBUF = linux.SO.RCVBUF;

    fn sres(rc: usize) isize {
        return @bitCast(rc);
    }
    fn pollCreate() !i32 {
        const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.NoPoll;
        return @intCast(rc);
    }
    fn wakeCreate(poll: i32, tag_: u64) !i32 {
        const rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.NoWake;
        const fd: i32 = @intCast(rc);
        add(poll, fd, tag_) catch |e| {
            close(fd);
            return e;
        };
        return fd;
    }
    fn add(poll: i32, fd: i32, tag_: u64) !void {
        var ev: Ev = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = tag_ } };
        if (linux.errno(linux.epoll_ctl(poll, linux.EPOLL.CTL_ADD, fd, &ev)) != .SUCCESS) return error.NoPoll;
    }
    fn retag(poll: i32, fd: i32, tag_: u64) void {
        var ev: Ev = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = tag_ } };
        _ = linux.epoll_ctl(poll, linux.EPOLL.CTL_MOD, fd, &ev);
    }
    fn wait(poll: i32, evs: []Ev, ms: i32) usize {
        const rc = linux.epoll_wait(poll, evs.ptr, @intCast(evs.len), ms);
        return if (linux.errno(rc) == .SUCCESS) rc else 0;
    }
    fn tag(e: *const Ev) u64 {
        return e.data.u64;
    }
    fn wake(fd: i32, _: i32) void {
        const one: u64 = 1;
        _ = linux.write(fd, std.mem.asBytes(&one), 8);
    }
    fn drain(fd: i32) void {
        var v: u64 = 0;
        _ = linux.read(fd, std.mem.asBytes(&v), 8);
    }
    pub fn close(fd: i32) void {
        _ = linux.close(fd);
    }
    fn nonblock(fd: i32) !void {
        const fl = linux.fcntl(fd, linux.F.GETFL, 0);
        if (linux.errno(fl) != .SUCCESS) return error.Fcntl;
        _ = linux.fcntl(fd, linux.F.SETFL, fl | @as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
    }
    fn setsockopt(fd: i32, level: i32, opt: u32, val: []const u8) usize {
        return linux.setsockopt(fd, level, opt, val.ptr, @intCast(val.len));
    }
    fn udpConnect(a: Ip4, port: u16) ?i32 {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const fd: i32 = @intCast(rc);
        var sa: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(a) };
        if (linux.errno(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
            close(fd);
            return null;
        }
        return fd;
    }
    pub fn send(fd: i32, b: []const u8) isize {
        return sres(linux.sendto(fd, b.ptr, b.len, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT, null, 0));
    }
    fn recv(fd: i32, b: []u8) isize {
        return sres(linux.recvfrom(fd, b.ptr, b.len, linux.MSG.DONTWAIT, null, null));
    }
    pub const Iov = std.posix.iovec_const;
    pub const IovMut = std.posix.iovec;
    pub fn isIn(e: *const Ev) bool {
        return e.events & (linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.HUP | linux.EPOLL.ERR) != 0;
    }
    pub fn isOut(e: *const Ev) bool {
        return e.events & (linux.EPOLL.OUT | linux.EPOLL.HUP | linux.EPOLL.ERR) != 0;
    }
    /// A TCP socket, edge-triggered for read and write.
    pub fn addConn(poll: i32, fd: i32, tag_: u64) !void {
        var ev: Ev = .{ .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.RDHUP | linux.EPOLL.ET, .data = .{ .u64 = tag_ } };
        if (linux.errno(linux.epoll_ctl(poll, linux.EPOLL.CTL_ADD, fd, &ev)) != .SUCCESS) return error.NoPoll;
    }
    /// A connect with no wait. `done` is true when it ended at once.
    pub fn tcpConnect(a: Ip4, port: u16, done: *bool) ?i32 {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const fd: i32 = @intCast(rc);
        const one: c_int = 1;
        _ = setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one));
        var sa: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(a) };
        switch (linux.errno(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)))) {
            .SUCCESS => done.* = true,
            .INPROGRESS => done.* = false,
            else => {
                close(fd);
                return null;
            },
        }
        return fd;
    }
    pub fn sendv(fd: i32, iov: []const Iov) isize {
        const m: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = iov.ptr, .iovlen = iov.len, .control = null, .controllen = 0, .flags = 0 };
        return sres(linux.sendmsg(fd, &m, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT));
    }
    pub fn recvv(fd: i32, iov: []const IovMut) isize {
        return sres(linux.readv(fd, iov.ptr, iov.len));
    }
    pub fn sockError(fd: i32) i32 {
        var v: i32 = 0;
        var l: linux.socklen_t = 4;
        if (linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, std.mem.asBytes(&v), &l)) != .SUCCESS) return -1;
        return v;
    }
    pub fn shutdownWr(fd: i32) void {
        _ = linux.shutdown(fd, linux.SHUT.WR);
    }
    /// The close of the socket then resets the connection of the host.
    pub fn lingerZero(fd: i32) void {
        const l = [2]i32{ 1, 0 };
        _ = setsockopt(fd, linux.SOL.SOCKET, linux.SO.LINGER, std.mem.asBytes(&l));
    }
    fn readFile(path: [*:0]const u8, buf: []u8) ?usize {
        const rc = linux.open(path, .{ .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const fd: i32 = @intCast(rc);
        defer close(fd);
        const r = linux.read(fd, buf.ptr, buf.len);
        return if (linux.errno(r) == .SUCCESS) r else null;
    }
};

const mac_os = struct {
    const c = std.c;
    const Ev = c.Kevent;
    const SOL_SOCKET = c.SOL.SOCKET;
    const SO_SNDBUF = c.SO.SNDBUF;
    const SO_RCVBUF = c.SO.RCVBUF;

    fn pollCreate() !i32 {
        const kq = c.kqueue();
        if (kq < 0) return error.NoPoll;
        _ = c.fcntl(kq, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        return kq;
    }
    fn change(kq: i32, ident: usize, filter: i16, flags: u16, fflags: u32, tag_: u64) bool {
        var ev: Ev = .{ .ident = ident, .filter = filter, .flags = flags, .fflags = fflags, .data = 0, .udata = @intCast(tag_) };
        return c.kevent(kq, @ptrCast(&ev), 1, @ptrCast(&ev), 0, null) >= 0;
    }
    /// The wake event is an EVFILT_USER event of the kqueue itself.
    fn wakeCreate(kq: i32, tag_: u64) !i32 {
        if (!change(kq, 0, c.EVFILT.USER, c.EV.ADD | c.EV.CLEAR, 0, tag_)) return error.NoWake;
        return -1;
    }
    fn add(kq: i32, fd: i32, tag_: u64) !void {
        if (!change(kq, @intCast(fd), c.EVFILT.READ, c.EV.ADD, 0, tag_)) return error.NoPoll;
    }
    fn retag(kq: i32, fd: i32, tag_: u64) void {
        _ = change(kq, @intCast(fd), c.EVFILT.READ, c.EV.ADD, 0, tag_);
    }
    fn wait(kq: i32, evs: []Ev, ms: i32) usize {
        const ts: c.timespec = .{ .sec = @divTrunc(ms, 1000), .nsec = @rem(ms, 1000) * std.time.ns_per_ms };
        const rc = c.kevent(kq, @ptrCast(evs.ptr), 0, @ptrCast(evs.ptr), @intCast(evs.len), &ts);
        return if (rc > 0) @intCast(rc) else 0;
    }
    fn tag(e: *const Ev) u64 {
        return @intCast(e.udata);
    }
    fn wake(_: i32, kq: i32) void {
        _ = change(kq, 0, c.EVFILT.USER, 0, c.NOTE.TRIGGER, 0);
    }
    fn drain(fd: i32) void {
        if (fd < 0) return;
        var b: [64]u8 = undefined;
        _ = c.read(fd, &b, b.len);
    }
    pub fn close(fd: i32) void {
        _ = c.close(fd);
    }
    fn nonblock(fd: i32) !void {
        const fl = c.fcntl(fd, c.F.GETFL);
        if (fl < 0) return error.Fcntl;
        _ = c.fcntl(fd, c.F.SETFL, fl | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
    }
    fn setsockopt(fd: i32, level: i32, opt: u32, val: []const u8) c_int {
        return c.setsockopt(fd, level, opt, val.ptr, @intCast(val.len));
    }
    fn udpConnect(a: Ip4, port: u16) ?i32 {
        const fd = c.socket(c.AF.INET, c.SOCK.DGRAM, 0);
        if (fd < 0) return null;
        _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        nonblock(fd) catch {
            close(fd);
            return null;
        };
        var sa: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(a) };
        if (c.connect(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in)) != 0) {
            close(fd);
            return null;
        }
        return fd;
    }
    pub fn send(fd: i32, b: []const u8) isize {
        return c.send(fd, b.ptr, b.len, 0);
    }
    fn recv(fd: i32, b: []u8) isize {
        return c.recv(fd, b.ptr, b.len, 0);
    }
    pub const Iov = std.posix.iovec_const;
    pub const IovMut = std.posix.iovec;
    pub fn isIn(e: *const Ev) bool {
        return e.filter == c.EVFILT.READ;
    }
    pub fn isOut(e: *const Ev) bool {
        return e.filter == c.EVFILT.WRITE;
    }
    pub fn addConn(kq: i32, fd: i32, tag_: u64) !void {
        if (!change(kq, @intCast(fd), c.EVFILT.READ, c.EV.ADD | c.EV.CLEAR, 0, tag_)) return error.NoPoll;
        if (!change(kq, @intCast(fd), c.EVFILT.WRITE, c.EV.ADD | c.EV.CLEAR, 0, tag_)) return error.NoPoll;
    }
    fn res(r: isize) isize {
        return if (r < 0) -@as(isize, @backingInt(std.posix.errno(r))) else r;
    }
    pub fn tcpConnect(a: Ip4, port: u16, done: *bool) ?i32 {
        const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (fd < 0) return null;
        _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        const one: c_int = 1;
        _ = setsockopt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, std.mem.asBytes(&one));
        _ = setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, std.mem.asBytes(&one));
        nonblock(fd) catch {
            close(fd);
            return null;
        };
        var sa: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(a) };
        if (c.connect(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in)) == 0) {
            done.* = true;
        } else if (std.posix.errno(@as(c_int, -1)) == .INPROGRESS) {
            done.* = false;
        } else {
            close(fd);
            return null;
        }
        return fd;
    }
    pub fn sendv(fd: i32, iov: []const Iov) isize {
        return res(c.writev(fd, iov.ptr, @intCast(iov.len)));
    }
    pub fn recvv(fd: i32, iov: []const IovMut) isize {
        return res(c.readv(fd, iov.ptr, @intCast(iov.len)));
    }
    pub fn sockError(fd: i32) i32 {
        var v: i32 = 0;
        var l: c.socklen_t = 4;
        if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, std.mem.asBytes(&v), &l) != 0) return -1;
        return v;
    }
    pub fn shutdownWr(fd: i32) void {
        _ = c.shutdown(fd, 1);
    }
    pub fn lingerZero(fd: i32) void {
        const l = [2]i32{ 1, 0 };
        _ = setsockopt(fd, c.SOL.SOCKET, c.SO.LINGER, std.mem.asBytes(&l));
    }
    fn readFile(path: [*:0]const u8, buf: []u8) ?usize {
        const fd = c.open(path, .{ .CLOEXEC = true });
        if (fd < 0) return null;
        defer close(fd);
        const r = c.read(fd, buf.ptr, buf.len);
        return if (r >= 0) @intCast(r) else null;
    }
};

// ---------------------------------------------------------------------
// Tests: the engine on a frame socket, with a UDP echo server on the
// host loopback.

fn udpFrame(buf: []u8, dst: Ip4, sport: u16, dport: u16, payload: []const u8) []u8 {
    @memcpy(buf[0..6], &nat.gateway_mac);
    @memcpy(buf[6..12], &nat.guest_mac);
    std.mem.writeInt(u16, buf[12..14], 0x0800, .big);
    const h = buf[14..34];
    @memset(h, 0);
    h[0] = 0x45;
    std.mem.writeInt(u16, h[2..4], @intCast(28 + payload.len), .big);
    h[8] = 64;
    h[9] = 17;
    @memcpy(h[12..16], &nat.guest_ip);
    @memcpy(h[16..20], &dst);
    std.mem.writeInt(u16, h[10..12], nat.checksum(h, 0), .big);
    const u = buf[34..];
    std.mem.writeInt(u16, u[0..2], sport, .big);
    std.mem.writeInt(u16, u[2..4], dport, .big);
    std.mem.writeInt(u16, u[4..6], @intCast(8 + payload.len), .big);
    std.mem.writeInt(u16, u[6..8], 0, .big);
    @memcpy(u[8..][0..payload.len], payload);
    return buf[0 .. 42 + payload.len];
}

test "nat engine: UDP to the gateway through a frame socket" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // The echo server on 127.0.0.1.
    const srv: i32 = @intCast(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0));
    defer _ = linux.close(srv);
    var sa: linux.sockaddr.in = .{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    try std.testing.expectEqual(@as(usize, 0), linux.bind(srv, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)));
    var sl: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = linux.getsockname(srv, @ptrCast(&sa), &sl);
    const port = std.mem.bigToNative(u16, sa.port);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0, &pair));
    defer _ = linux.close(pair[1]);
    const Log = struct {
        var refused: u32 = 0;
        fn ev(_: ?*anyopaque, e: *const Event) void {
            if (e.kind == .refuse) refused += 1;
        }
        fn pol(_: ?*anyopaque, _: Proto, a: Ip4, _: u16) bool {
            return a[0] == 127;
        }
    };
    const n = try Nat.initSocket(std.testing.allocator, .{ .dns = false, .policy = Log.pol, .event = Log.ev }, pair[0]);
    defer n.deinit();
    try n.start();

    var fb: [nat.max_frame]u8 = undefined;
    const f = udpFrame(&fb, nat.gateway_ip, 40000, port, "ping");
    try std.testing.expectEqual(@as(isize, @intCast(f.len)), linux_os.send(pair[1], f));
    var got: [64]u8 = undefined;
    var from: linux.sockaddr.in = undefined;
    var fl: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const r = linux.recvfrom(srv, &got, got.len, 0, @ptrCast(&from), &fl);
    try std.testing.expectEqualStrings("ping", got[0..r]);
    _ = linux.sendto(srv, "pong", 4, 0, @ptrCast(&from), fl);
    // The answer comes back as a frame from 10.0.2.2 to the guest port.
    var pfd = [_]linux.pollfd{.{ .fd = pair[1], .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), linux.poll(&pfd, 1, 2000));
    var out: [nat.max_frame]u8 = undefined;
    const k: usize = @intCast(linux_os.recv(pair[1], &out));
    try std.testing.expectEqual(@as(usize, 46), k);
    try std.testing.expectEqualSlices(u8, &nat.gateway_ip, out[26..30]);
    try std.testing.expectEqual(@as(u16, 40000), std.mem.readInt(u16, out[36..38], .big));
    try std.testing.expectEqualStrings("pong", out[42..46]);
    // The policy refuses an address outside the loopback.
    _ = linux_os.send(pair[1], udpFrame(&fb, .{ 192, 0, 2, 1 }, 40001, 9, "x"));
    var tries: u32 = 0;
    while (Log.refused == 0 and tries < 200) : (tries += 1) _ = linux.poll(&pfd, 0, 5);
    try std.testing.expectEqual(@as(u32, 1), Log.refused);
}

test "nat engine: the UDP flow table" {
    // Flows that share a home slot, then the deletion of the first: the
    // second is still found.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const n = try Nat.init(std.testing.allocator, .{ .dns = false }, undefined);
    defer n.deinit();
    var a: [3]*Flow = undefined;
    for (&a, 0..) |*x, i| x.* = n.flowFor(@intCast(5000 + i), nat.gateway_ip, 9).?;
    const fd1 = a[1].fd;
    const fd2 = a[2].fd;
    n.closeFlow(@intCast((@intFromPtr(a[0]) - @intFromPtr(&n.flows)) / @sizeOf(Flow)));
    try std.testing.expectEqual(fd1, n.flowFor(5001, nat.gateway_ip, 9).?.fd);
    try std.testing.expectEqual(fd2, n.flowFor(5002, nat.gateway_ip, 9).?.fd);
    try std.testing.expect(n.flowFor(1, nat.dns_ip, 53) == null);
}

test "nat engine: parseIp4" {
    try std.testing.expectEqual(@as(?Ip4, .{ 10, 0, 2, 3 }), parseIp4("10.0.2.3"));
    try std.testing.expectEqual(@as(?Ip4, null), parseIp4("10.0.2"));
    try std.testing.expectEqual(@as(?Ip4, null), parseIp4("::1"));
}

fn dnsQueryMsg(buf: []u8, id: u16, name: []const u8) []u8 {
    @memset(buf[0..12], 0);
    std.mem.writeInt(u16, buf[0..2], id, .big);
    buf[2] = 0x01; // RD
    std.mem.writeInt(u16, buf[4..6], 1, .big);
    var i: usize = 12;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |l| {
        buf[i] = @intCast(l.len);
        @memcpy(buf[i + 1 ..][0..l.len], l);
        i += 1 + l.len;
    }
    buf[i] = 0;
    std.mem.writeInt(u16, buf[i + 1 ..][0..2], 1, .big); // A
    std.mem.writeInt(u16, buf[i + 3 ..][0..2], 1, .big); // IN
    return buf[0 .. i + 5];
}

const DnsLog = struct {
    var asked: u32 = 0;
    var refused: u32 = 0;
    var last_rule: i32 = 0;
    var last_name: [256]u8 = undefined;
    var last_len: usize = 0;
    fn ev(_: ?*anyopaque, e: *const Event) void {
        if (e.kind == .dns) asked += 1;
        if (e.kind == .refuse) {
            refused += 1;
            last_rule = e.rule;
        }
        @memcpy(last_name[0..e.name.len], e.name);
        last_len = e.name.len;
    }
    fn allow(_: ?*anyopaque, name: []const u8) bool {
        return nameMatch("example.com", name) or nameMatch("*.ok.test", name);
    }
    fn reset() void {
        asked = 0;
        refused = 0;
        last_rule = 0;
    }
};

/// Sends one DNS query of the guest, and gives the RCODE of the answer
/// of the engine, or null when the query went to the server.
fn dnsAsk(fd: i32, id: u16, name: []const u8) !?u8 {
    var qb: [300]u8 = undefined;
    var fb: [nat.max_frame]u8 = undefined;
    const before = DnsLog.asked + DnsLog.refused;
    const refused_before = DnsLog.refused;
    _ = linux_os.send(fd, udpFrame(&fb, nat.dns_ip, 40053, 53, dnsQueryMsg(&qb, id, name)));
    var tries: u32 = 0;
    while (DnsLog.asked + DnsLog.refused == before and tries < 500) : (tries += 1) {
        var none_ = [0]linux.pollfd{};
        _ = linux.poll(&none_, 0, 1);
    }
    if (DnsLog.asked + DnsLog.refused == before) return error.Timeout;
    if (DnsLog.refused == refused_before) return null;
    // A refusal: the answer of the engine.
    var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    var out: [nat.max_frame]u8 = undefined;
    while (true) {
        if (linux.poll(&pfd, 1, 2000) != 1) return error.Timeout;
        const k: usize = @intCast(linux_os.recv(fd, &out));
        if (k < 42 + 12 or out[23] != 17) continue;
        const d = out[42..k];
        if (std.mem.readInt(u16, d[0..2], .big) != id) continue;
        try std.testing.expect(d[2] & 0x80 != 0);
        return d[3] & 0xf;
    }
}

test "nat engine: DNS is part of the policy" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    inline for (.{ false, true }) |with_list| {
        var pair: [2]i32 = undefined;
        try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0, &pair));
        defer _ = linux.close(pair[1]);
        DnsLog.reset();
        const n = try Nat.initSocket(std.testing.allocator, .{
            .dns = false,
            .event = DnsLog.ev,
            .dns_allow = if (with_list) DnsLog.allow else null,
            .dns_rate = 3,
        }, pair[0]);
        defer n.deinit();
        // A name server with no program on it: a query that passes goes
        // there, and the test sees its event.
        n.dns_server = .{ 127, 0, 0, 1 };
        n.dns_tokens = 6000;
        try n.start();
        if (!with_list) {
            // No allow list (the loopback policy): each name is refused.
            try std.testing.expectEqual(@as(?u8, 5), try dnsAsk(pair[1], 1, "example.com"));
            try std.testing.expectEqualStrings("example.com", DnsLog.last_name[0..DnsLog.last_len]);
            try std.testing.expectEqual(@as(u32, 0), DnsLog.asked);
        } else {
            try std.testing.expectEqual(@as(?u8, null), try dnsAsk(pair[1], 2, "Example.COM"));
            try std.testing.expectEqual(@as(u32, 1), DnsLog.asked);
            try std.testing.expectEqual(@as(?u8, null), try dnsAsk(pair[1], 3, "a.ok.test"));
            try std.testing.expectEqual(@as(?u8, 5), try dnsAsk(pair[1], 4, "evil.test"));
            try std.testing.expectEqual(@as(i32, -1), DnsLog.last_rule);
            // The shape of a tunnel: a long random label below a name
            // of the list. Only the name itself is on the list.
            try std.testing.expectEqual(@as(?u8, 5), try dnsAsk(pair[1], 5, "q2x9f0c1b7a6e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b0a9f8e7d6c5b4a3f2.example.com"));
            // The bucket had 6 queries: 4 are gone, and the next 2 go
            // through the list; then the limit refuses.
            try std.testing.expectEqual(@as(?u8, 5), try dnsAsk(pair[1], 6, "evil.test"));
            try std.testing.expectEqual(@as(?u8, 5), try dnsAsk(pair[1], 7, "evil.test"));
            try std.testing.expectEqual(@as(?u8, 5), try dnsAsk(pair[1], 8, "example.com"));
            try std.testing.expectEqual(Event.rule_rate, DnsLog.last_rule);
        }
    }
}

test "nat engine: a DNS query, and the match of a name" {
    var nb: [256]u8 = undefined;
    var qb: [300]u8 = undefined;
    const q = dnsQueryMsg(&qb, 9, "WWW.Example.com");
    const r = parseQuery(q, &nb).?;
    try std.testing.expectEqualStrings("www.example.com", r.name);
    try std.testing.expectEqual(q.len, r.end);
    // A compression pointer, an answer, and a bad character.
    var bad = qb;
    bad[12] = 0xc0;
    try std.testing.expect(parseQuery(bad[0..q.len], &nb) == null);
    bad = qb;
    bad[2] |= 0x80;
    try std.testing.expect(parseQuery(bad[0..q.len], &nb) == null);
    bad = qb;
    bad[13] = '/';
    try std.testing.expect(parseQuery(bad[0..q.len], &nb) == null);
    try std.testing.expect(nameMatch("*.ok.test", "a.b.ok.test"));
    try std.testing.expect(!nameMatch("*.ok.test", "ok.test"));
    try std.testing.expect(!nameMatch("*.ok.test", "evilok.test"));
    try std.testing.expect(nameMatch("example.com.", "example.com"));
    try std.testing.expect(!nameMatch("example.com", "x.example.com"));
}

fn tcpGuestFrame(buf: []u8, dport: u16, seq: u32, ackn: u32, flags: u8, opts: []const u8, payload: []const u8) []u8 {
    @memcpy(buf[0..6], &nat.gateway_mac);
    @memcpy(buf[6..12], &nat.guest_mac);
    std.mem.writeInt(u16, buf[12..14], 0x0800, .big);
    const tl = 20 + opts.len;
    const h = buf[14..34];
    @memset(h, 0);
    h[0] = 0x45;
    std.mem.writeInt(u16, h[2..4], @intCast(20 + tl + payload.len), .big);
    h[8] = 64;
    h[9] = 6;
    @memcpy(h[12..16], &nat.guest_ip);
    @memcpy(h[16..20], &nat.gateway_ip);
    std.mem.writeInt(u16, h[10..12], nat.checksum(h, 0), .big);
    const t = buf[34..];
    @memset(t[0..20], 0);
    std.mem.writeInt(u16, t[0..2], 41000, .big);
    std.mem.writeInt(u16, t[2..4], dport, .big);
    std.mem.writeInt(u32, t[4..8], seq, .big);
    std.mem.writeInt(u32, t[8..12], ackn, .big);
    t[12] = @intCast(tl / 4 << 4);
    t[13] = flags;
    std.mem.writeInt(u16, t[14..16], 65535, .big);
    @memcpy(t[20..][0..opts.len], opts);
    @memcpy(t[tl..][0..payload.len], payload);
    return buf[0 .. 34 + tl + payload.len];
}

/// The next TCP frame to the guest port 41000 on the frame socket.
fn tcpRecv(fd: i32, out: []u8) !struct { seq: u32, ack: u32, flags: u8, data: []u8 } {
    var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    while (true) {
        if (linux.poll(&pfd, 1, 2000) != 1) return error.Timeout;
        const k: usize = @intCast(linux_os.recv(fd, out));
        if (k < 54 or out[23] != 6) continue;
        const t = out[34..k];
        try std.testing.expectEqual(@as(u16, 41000), std.mem.readInt(u16, t[2..4], .big));
        // The checksum of each frame of a frame socket is whole.
        try std.testing.expectEqual(@as(u16, 0), nat.checksum(t, nat.pseudo(nat.gateway_ip, nat.guest_ip, 6, t.len)));
        const doff = @as(usize, t[12] >> 4) * 4;
        return .{ .seq = std.mem.readInt(u32, t[4..8], .big), .ack = std.mem.readInt(u32, t[8..12], .big), .flags = t[13], .data = t[doff..] };
    }
}

test "nat engine: a TCP connection to the gateway through a frame socket" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const T = tcp;
    const srv: i32 = @intCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    defer _ = linux.close(srv);
    var sa: linux.sockaddr.in = .{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    try std.testing.expectEqual(@as(usize, 0), linux.bind(srv, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)));
    _ = linux.listen(srv, 4);
    var sl: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = linux.getsockname(srv, @ptrCast(&sa), &sl);
    const port = std.mem.bigToNative(u16, sa.port);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0, &pair));
    defer _ = linux.close(pair[1]);
    const n = try Nat.initSocket(std.testing.allocator, .{ .dns = false }, pair[0]);
    defer n.deinit();
    try n.start();
    var fb: [nat.max_frame]u8 = undefined;
    var out: [nat.max_frame]u8 = undefined;

    // The handshake: MSS 1460, SACK-permitted, window scale 7.
    _ = linux_os.send(pair[1], tcpGuestFrame(&fb, port, 1000, 0, T.syn, &.{ 2, 4, 5, 0xb4, 1, 1, 4, 2, 1, 3, 3, 7 }, ""));
    const sa1 = try tcpRecv(pair[1], &out);
    try std.testing.expectEqual(T.syn | T.ack, sa1.flags);
    try std.testing.expectEqual(@as(u32, 1001), sa1.ack);
    const peer: i32 = @intCast(linux.accept(srv, null, null));
    defer _ = linux.close(peer);
    _ = linux_os.send(pair[1], tcpGuestFrame(&fb, port, 1001, sa1.seq +% 1, T.ack, "", "hello"));
    var got: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), linux.read(peer, &got, got.len));
    try std.testing.expectEqualStrings("hello", got[0..5]);
    const a1 = try tcpRecv(pair[1], &out);
    try std.testing.expectEqual(@as(u32, 1006), a1.ack);

    // The host answers, then closes.
    _ = linux.write(peer, "world", 5);
    const d = try tcpRecv(pair[1], &out);
    try std.testing.expectEqualStrings("world", d.data);
    try std.testing.expectEqual(sa1.seq +% 1, d.seq);
    _ = linux.shutdown(peer, linux.SHUT.WR);
    const f = try tcpRecv(pair[1], &out);
    try std.testing.expect(f.flags & T.fin != 0);
    try std.testing.expectEqual(d.seq +% 5, f.seq);
    // The guest acknowledges both, and sends its FIN.
    _ = linux_os.send(pair[1], tcpGuestFrame(&fb, port, 1006, f.seq +% 1, T.ack | T.fin, "", ""));
    try std.testing.expectEqual(@as(usize, 0), linux.read(peer, &got, got.len));
    const last = try tcpRecv(pair[1], &out);
    try std.testing.expectEqual(@as(u32, 1007), last.ack);
    var tries: u32 = 0;
    while (n.tcp.active() > 0 and tries < 200) : (tries += 1) {
        var none_ = [0]linux.pollfd{};
        _ = linux.poll(&none_, 0, 1);
    }
    try std.testing.expectEqual(@as(usize, 0), n.tcp.active());

    // A port with no listener: a RST.
    _ = linux_os.send(pair[1], tcpGuestFrame(&fb, 1, 5000, 0, T.syn, "", ""));
    const r = try tcpRecv(pair[1], &out);
    try std.testing.expect(r.flags & T.rst != 0);
    try std.testing.expectEqual(@as(u32, 5001), r.ack);
}

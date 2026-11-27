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
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const nat = @import("nat.zig");
const vnet = @import("../virtio/net.zig");

pub const Ip4 = nat.Ip4;
pub const Hdr = vnet.Hdr;
const on_mac = builtin.os.tag == .macos;
const linux = std.os.linux;

pub const Proto = enum(u8) { tcp = 6, udp = 17 };

pub const Event = struct {
    pub const Kind = enum { connect, refuse, close, dns, forward };
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
};

pub const Config = struct {
    /// The network policy of the embedder for each host address, before
    /// a socket opens. Null allows each address.
    policy: ?*const fn (ctx: ?*anyopaque, proto: Proto, addr: Ip4, port: u16) bool = null,
    policy_ctx: ?*anyopaque = null,
    dns: bool = true,
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
    watches: [max_watch]Watch = @splat(.{}),
    dns_server: ?Ip4 = null,
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
        n.poll = try os.pollCreate();
        errdefer os.close(n.poll);
        n.wake_fd = try os.wakeCreate(n.poll, tag_wake);
        if (cfg.dns) n.dns_server = readResolvConf();
        return n;
    }

    /// Closes each socket and frees the engine. Stops the thread first.
    pub fn deinit(n: *Nat) void {
        n.stop();
        for (&n.flows) |*f| if (f.fd >= 0) os.close(f.fd);
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
        _ = h;
        n.stats_.from_guest += 1;
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
        while (!n.stopping.load(.acquire)) {
            const k = os.wait(n.poll, &evs, 1000);
            for (evs[0..k]) |*e| n.dispatch(os.tag(e));
            n.endBatch();
            const t = now();
            if (t - last_sweep > std.time.ns_per_s) {
                last_sweep = t;
                n.sweep(t);
            }
        }
    }

    fn dispatch(n: *Nat, tag: u64) void {
        const i: usize = @intCast(tag & 0xffffffff);
        switch (tag & ~@as(u64, 0xffffffff)) {
            tag_wake => {
                os.drain(n.wake_fd);
                n.flushRing();
            },
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
            n.stats_.from_guest += 1;
            n.stack.fromGuest(buf[0..@intCast(r)]);
        }
    }

    // -- UDP flows

    fn udpSend(ctx: *anyopaque, sport: u16, dst: Ip4, dport: u16, payload: []const u8) void {
        const n: *Nat = @ptrCast(@alignCast(ctx));
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

    fn openFlow(n: *Nat, i: usize, sport: u16, dst: Ip4, dport: u16) ?*Flow {
        const host: Ip4 = if (std.mem.eql(u8, &dst, &nat.gateway_ip))
            .{ 127, 0, 0, 1 }
        else if (std.mem.eql(u8, &dst, &nat.dns_ip))
            (if (dport == 53) n.dns_server orelse return null else return null)
        else
            dst;
        const is_dns = std.mem.eql(u8, &dst, &nat.dns_ip);
        // The DNS server of the host is the lookup of the NAT itself, as
        // `sys.resolve` is for a script, so the policy does not apply.
        if (!is_dns) if (n.cfg.policy) |pol| if (!pol(n.cfg.policy_ctx, .udp, host, dport)) {
            n.event(.{ .kind = .refuse, .proto = .udp, .guest_port = sport, .addr = host, .port = dport });
            return null;
        };
        const fd = os.udpConnect(host, dport) orelse return null;
        os.add(n.poll, fd, tag_flow | i) catch {
            os.close(fd);
            return null;
        };
        n.flows[i] = .{ .fd = fd, .sport = sport, .dst = dst, .dport = dport, .host = host, .last = now() };
        n.event(.{ .kind = if (is_dns) .dns else .connect, .proto = .udp, .guest_port = sport, .addr = host, .port = dport });
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

    fn event(n: *Nat, ev: Event) void {
        if (n.cfg.event) |hook| hook(n.cfg.event_ctx, &ev);
    }
};

fn now() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
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
const os = if (on_mac) mac_os else linux_os;

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
    fn close(fd: i32) void {
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
    fn send(fd: i32, b: []const u8) isize {
        return sres(linux.sendto(fd, b.ptr, b.len, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT, null, 0));
    }
    fn recv(fd: i32, b: []u8) isize {
        return sres(linux.recvfrom(fd, b.ptr, b.len, linux.MSG.DONTWAIT, null, null));
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
    fn close(fd: i32) void {
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
    fn send(fd: i32, b: []const u8) isize {
        return c.send(fd, b.ptr, b.len, 0);
    }
    fn recv(fd: i32, b: []u8) isize {
        return c.recv(fd, b.ptr, b.len, 0);
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

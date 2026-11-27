//! A guest-side fuzzer of the virtio devices of `ztcl::vm`, in process.
//!
//!   zig build virtio-fuzz -- [--seconds N] [--seed N] [--race 0|1]
//!
//! A fake guest memory holds the rings and the buffers of the devices of
//! `mmio.zig`: the console, block, entropy, vsock, 9p, virtio-fs, net
//! (with the NAT stack of `nat/nat.zig` behind it), and the balloon. Each
//! round writes random registers, random descriptors (addresses in and
//! out of the memory, any length, loops, any flags), and random requests
//! with the headers of the protocols, then notifies a queue. With
//! `--race 1` a second thread changes bytes of the rings and the buffers
//! all the time, as a vCPU of a hostile guest does during a request.
//!
//! The fake share of the 9p and virtio-fs servers checks that each
//! handle it gets is one that it gave and did not close, and the balloon
//! checks that each range is in the guest memory. A build with safety
//! checks stops at the first out-of-bounds access, overflow, or failed
//! check.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const Io = std.Io;
const mmio = @import("virtio/mmio.zig");
const queue = @import("virtio/queue.zig");
const vsock = @import("virtio/vsock.zig");
const ninep = @import("virtio/ninep.zig");
const fuse = @import("virtio/fuse.zig");
const vnet = @import("virtio/net.zig");
const balloon = @import("virtio/balloon.zig");
const nat = @import("nat/nat.zig");

const Device = mmio.Device;
const Host = mmio.Host;
const Mem = queue.Mem;

const mem_len = 256 * 1024;
/// The rings of queue `qi` start at `qi * ring_span`, and the buffers at
/// `data_at`.
const ring_span = 0x3000;
const data_at = 0x10000;

var guest: [mem_len]u8 align(4096) = undefined;

fn mem() Mem {
    return .{ .base = &guest, .size = guest.len };
}

fn interrupt(_: *anyopaque, _: u32) void {}

// -- The fake share: each path is a file, a name that ends in "d" is a
// folder, and "" is the root folder.

const FakeFs = struct {
    handles: std.AutoHashMapUnmanaged(u64, void) = .empty,
    next: u64 = 100,

    fn of(ctx: *anyopaque) *FakeFs {
        return @ptrCast(@alignCast(ctx));
    }
    fn isDir(path: []const u8) bool {
        return path.len == 0 or path[path.len - 1] == 'd';
    }
    fn check(f: *FakeFs, h: u64) void {
        if (!f.handles.contains(h)) std.debug.panic("the share got a handle that it did not give: {d}", .{h});
    }
    fn give(f: *FakeFs, out: *u64) u32 {
        f.handles.put(std.heap.page_allocator, f.next, {}) catch return ninep.E.NOMEM;
        out.* = f.next;
        f.next += 1;
        return 0;
    }
    fn stat(_: *anyopaque, path: []const u8, out: *ninep.Attr) u32 {
        if (path.len > 64) return ninep.E.NOENT;
        out.* = .{ .mode = if (isDir(path)) 0o040755 else 0o100644, .size = path.len * 1000, .ino = std.hash.Wyhash.hash(0, path) };
        return 0;
    }
    fn open(ctx: *anyopaque, path: []const u8, _: u32, out: *u64) u32 {
        if (path.len > 64) return ninep.E.NOENT;
        return of(ctx).give(out);
    }
    fn create(ctx: *anyopaque, _: []const u8, _: []const u8, _: u32, _: u32, out: *u64) u32 {
        return of(ctx).give(out);
    }
    fn close(ctx: *anyopaque, h: u64) void {
        const f = of(ctx);
        f.check(h);
        _ = f.handles.remove(h);
    }
    fn read(ctx: *anyopaque, h: u64, _: u64, buf: []u8, n: *usize) u32 {
        of(ctx).check(h);
        @memset(buf, 'r');
        n.* = buf.len;
        return 0;
    }
    fn write(ctx: *anyopaque, h: u64, _: u64, data: []const u8, n: *usize) u32 {
        of(ctx).check(h);
        n.* = data.len;
        return 0;
    }
    fn readdir(ctx: *anyopaque, h: u64, off: u64, sink: ninep.DirSink) u32 {
        of(ctx).check(h);
        const all = [_]ninep.Dirent{ .{ .ino = 2, .next = 1, .kind = 8, .name = "a" }, .{ .ino = 3, .next = 2, .kind = 4, .name = "d" } };
        for (all[@intCast(@min(off, 2))..]) |e| if (!sink.put(sink.ctx, e)) break;
        return 0;
    }
    fn fsync(ctx: *anyopaque, h: u64, _: bool) u32 {
        of(ctx).check(h);
        return 0;
    }
    fn mkdir(_: *anyopaque, _: []const u8, _: []const u8, _: u32) u32 {
        return 0;
    }
    fn symlink(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) u32 {
        return 0;
    }
    fn link(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) u32 {
        return 0;
    }
    fn readlink(_: *anyopaque, _: []const u8, buf: []u8, n: *usize) u32 {
        const k = @min(buf.len, 3);
        @memcpy(buf[0..k], "abc"[0..k]);
        n.* = k;
        return 0;
    }
    fn unlink(_: *anyopaque, _: []const u8, _: []const u8, _: bool) u32 {
        return 0;
    }
    fn rename(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8) u32 {
        return 0;
    }
    fn setattr(_: *anyopaque, _: []const u8, _: ninep.SetAttr) u32 {
        return 0;
    }
    fn statfs(_: *anyopaque, out: *ninep.StatFs) u32 {
        out.* = .{};
        return 0;
    }
    const vt: ninep.Fs.VTable = .{ .stat = stat, .open = open, .create = create, .close = close, .read = read, .write = write, .readdir = readdir, .fsync = fsync, .mkdir = mkdir, .symlink = symlink, .link = link, .readlink = readlink, .unlink = unlink, .rename = rename, .setattr = setattr, .statfs = statfs };
};

// -- The backends of the other devices.

fn consoleWrite(_: *anyopaque, _: []const u8) void {}
fn noop(_: *anyopaque) void {}

var disk: [64 * 1024]u8 = undefined;
fn diskRead(_: *anyopaque, buf: []u8, off: u64) bool {
    if (off > disk.len or buf.len > disk.len - off) std.debug.panic("block read past the disk: {d}+{d}", .{ off, buf.len });
    @memcpy(buf, disk[@intCast(off)..][0..buf.len]);
    return true;
}
fn diskWrite(_: *anyopaque, buf: []const u8, off: u64) bool {
    if (off > disk.len or buf.len > disk.len - off) std.debug.panic("block write past the disk: {d}+{d}", .{ off, buf.len });
    @memcpy(disk[@intCast(off)..][0..buf.len], buf);
    return true;
}
fn diskFlush(_: *anyopaque) void {}

fn fill(buf: []u8) usize {
    @memset(buf, 0x5a);
    return buf.len;
}

fn vsData(_: *anyopaque, _: u32, _: []const u8) void {}
fn vsEvent(_: *anyopaque, _: u32, _: vsock.Event) void {}
fn vsAccept(_: *anyopaque, _: u32, port: u32) bool {
    return port % 2 == 0;
}

fn report(_: *anyopaque, r: []u8) void {
    const lo = @intFromPtr(&guest);
    const p = @intFromPtr(r.ptr);
    if (p < lo or p + r.len > lo + guest.len) std.debug.panic("a balloon range outside the guest memory", .{});
}

/// The net device and the NAT stack behind it: a frame of the guest goes
/// to the stack, and a frame of the stack goes to the receive queue.
const NetRig = struct {
    net: vnet.Net,
    stack: nat.Stack = undefined,
    dev: *Device = undefined,
    host: *const Host = undefined,

    fn kick(_: *anyopaque, _: u32) void {}
    fn frame(ctx: *anyopaque, _: vnet.Hdr, parts: []const []const u8) void {
        const r: *NetRig = @ptrCast(@alignCast(ctx));
        // The engine gives one part to the stack with no copy.
        if (parts.len == 1) r.stack.fromGuest(parts[0]);
    }
    fn emit(ctx: *anyopaque, f: []const u8) void {
        const r: *NetRig = @ptrCast(@alignCast(ctx));
        _ = r.net.deliver(r.dev, r.host, .{ .flags = vnet.hdr_data_valid }, &.{f});
    }
    fn udpSend(_: *anyopaque, _: u16, _: nat.Ip4, _: u16, _: []const u8) void {}
};

// -- The racing vCPU.

var race_stop: std.atomic.Value(bool) = .init(false);

fn racer(seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed ^ 0xace);
    const r = prng.random();
    while (!race_stop.load(.monotonic)) {
        // The descriptor tables and the start of the buffers.
        const i = if (r.boolean()) r.uintLessThan(usize, 3 * ring_span) else data_at + r.uintLessThan(usize, 0x2000);
        @atomicStore(u8, &guest[i], r.int(u8), .monotonic);
    }
}

// -- One round.

fn reg(d: *Device, h: *const Host, off: u64, v: u32) void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    d.write(h, off, &b);
}

/// Sets queue `qi` ready with `num` entries, its rings at their place,
/// or at times at a random address.
fn ready(r: std.Random, d: *Device, h: *const Host, qi: u32, num: u32) void {
    reg(d, h, 0x044, 0);
    reg(d, h, 0x030, qi);
    reg(d, h, 0x038, num);
    const base: u64 = qi * ring_span;
    const odd = r.uintLessThan(u8, 16) == 0;
    reg(d, h, 0x080, if (odd) r.int(u32) else @intCast(base));
    reg(d, h, 0x090, @intCast(base + 0x1000 + @as(u64, if (odd) r.uintLessThan(u32, 4) else 0)));
    reg(d, h, 0x0a0, @intCast(base + 0x2000));
    reg(d, h, 0x044, 1);
}

const ninep_kinds = [_]u8{ 8, 12, 14, 16, 18, 20, 22, 24, 26, 30, 40, 50, 52, 54, 70, 72, 74, 76, 100, 104, 108, 110, 116, 118, 120, 122 };
const fuse_ops = [_]u32{ fuse.op.lookup, fuse.op.forget, fuse.op.getattr, fuse.op.setattr, fuse.op.readlink, fuse.op.symlink, fuse.op.mknod, fuse.op.mkdir, fuse.op.unlink, fuse.op.rmdir, fuse.op.rename, fuse.op.link, fuse.op.open, fuse.op.read, fuse.op.write, fuse.op.statfs, fuse.op.release, fuse.op.fsync, fuse.op.init, fuse.op.opendir, fuse.op.readdir, fuse.op.releasedir, fuse.op.create, fuse.op.batch_forget, fuse.op.readdirplus, fuse.op.rename2, fuse.op.setupmapping, fuse.op.removemapping };

/// Writes a request of the protocol of device `kind` at `at`.
fn request(r: std.Random, kind: usize, at: usize, len: usize) void {
    const b = guest[at..][0..len];
    r.bytes(b);
    switch (kind) {
        // 9p: size, type, tag, then small fids.
        4 => if (len >= 11) {
            std.mem.writeInt(u32, b[0..4], r.uintLessThan(u32, @intCast(len + 4)), .little);
            b[4] = ninep_kinds[r.uintLessThan(usize, ninep_kinds.len)];
            std.mem.writeInt(u32, b[7..11], r.uintLessThan(u32, 4), .little);
        },
        // FUSE: length, opcode, unique, node, then a small fh.
        5 => if (len >= fuse.in_header_len + 8) {
            std.mem.writeInt(u32, b[0..4], r.uintLessThan(u32, @intCast(len + 4)), .little);
            std.mem.writeInt(u32, b[4..8], fuse_ops[r.uintLessThan(usize, fuse_ops.len)], .little);
            std.mem.writeInt(u64, b[16..24], r.uintLessThan(u64, 8), .little);
            if (r.boolean()) std.mem.writeInt(u64, b[fuse.in_header_len..][0..8], r.uintLessThan(u64, 120), .little);
            if (r.boolean()) @memcpy(b[fuse.in_header_len + 8 ..][0..@min(2, len - fuse.in_header_len - 8)], "a\x00"[0..@min(2, len - fuse.in_header_len - 8)]);
        },
        // vsock: the CIDs of the guest and the host, stream type.
        3 => if (len >= 44) {
            std.mem.writeInt(u64, b[0..8], 3, .little);
            std.mem.writeInt(u64, b[8..16], vsock.host_cid, .little);
            std.mem.writeInt(u32, b[20..24], r.uintLessThan(u32, 8), .little);
            std.mem.writeInt(u16, b[28..30], 1, .little);
            std.mem.writeInt(u16, b[30..32], r.uintLessThan(u16, 8), .little);
        },
        // net: the virtio header, then Ethernet with IPv4 or ARP.
        6 => if (len >= vnet.hdr_len + 34) {
            const f = b[vnet.hdr_len..];
            std.mem.writeInt(u16, f[12..14], if (r.boolean()) 0x0800 else 0x0806, .big);
            f[14] = 0x45;
            f[23] = if (r.boolean()) 17 else 1;
        },
        else => {},
    }
}

fn round(r: std.Random, devs: []Device, h: *const Host, rig: *NetRig) void {
    const k = r.uintLessThan(usize, devs.len);
    const d = &devs[k];
    rig.dev = &devs[6];
    // Random registers, at times, and a random read.
    if (r.uintLessThan(u8, 8) == 0) reg(d, h, r.uintLessThan(u64, 0x100) & ~@as(u64, 3), r.int(u32));
    var rb: [8]u8 = undefined;
    d.read(r.uintLessThan(u64, 0x140), rb[0 .. @as(usize, 1) << r.uintLessThan(u3, 4)]);
    if (r.uintLessThan(u8, 64) == 0) reg(d, h, 0x070, 0);
    if (r.uintLessThan(u8, 32) == 0) reg(d, h, 0x070, 0xf);

    const qi = r.uintLessThan(u32, d.nqueues);
    const num = @as(u32, 1) << r.uintLessThan(u5, 9);
    if (!d.queues[qi].ready or r.uintLessThan(u8, 8) == 0) ready(r, d, h, qi, if (r.uintLessThan(u8, 16) == 0) r.uintLessThan(u32, 300) else num);
    const q = &d.queues[qi];
    if (!q.ready) return;
    const m = mem();

    // Descriptors: mostly in the buffers, at times anywhere.
    const nd = 1 + r.uintLessThan(usize, @min(q.num, 8));
    var at: usize = data_at + r.uintLessThan(usize, 0x1000);
    for (0..nd) |i| {
        const di = if (r.uintLessThan(u8, 8) == 0) r.uintLessThan(usize, q.num) else i % q.num;
        const len: u32 = switch (r.uintLessThan(u8, 8)) {
            0 => r.int(u32),
            1 => 0,
            else => 1 + r.uintLessThan(u32, 600),
        };
        const addr: u64 = if (r.uintLessThan(u8, 16) == 0) r.int(u64) else at;
        if (addr == at and len < 0x4000 and at + len < mem_len) request(r, k, at, len);
        const dp = q.desc + 16 * di;
        if (m.slice(dp, 16) == null) break;
        m.put(u64, dp, addr);
        m.put(u32, dp + 8, len);
        var flags: u16 = if (i + 1 < nd) queue.desc_f_next else 0;
        if (r.boolean()) flags |= queue.desc_f_write;
        if (r.uintLessThan(u8, 16) == 0) flags = r.int(u16);
        m.put(u16, dp + 12, flags);
        m.put(u16, dp + 14, if (r.uintLessThan(u8, 16) == 0) r.int(u16) else @intCast((di + 1) % q.num));
        at = @min(at + (len & 0xfff) + 1, mem_len - 0x1000);
    }
    // The available ring: one to four chains, at times a random index.
    if (m.slice(q.avail, 4 + 2 * @as(u64, q.num)) == null) return;
    const idx = std.mem.readInt(u16, guest[@intCast(q.avail + 2)..][0..2], .little);
    const add: u16 = if (r.uintLessThan(u8, 32) == 0) r.int(u16) else 1 + r.uintLessThan(u16, 4);
    var j: u16 = 0;
    while (j < @min(add, 4)) : (j += 1) {
        const slot = q.avail + 4 + 2 * @as(u64, (idx +% j) % q.num);
        m.put(u16, slot, if (r.uintLessThan(u8, 16) == 0) r.int(u16) else 0);
    }
    m.put(u16, q.avail + 2, idx +% add);
    reg(d, h, 0x050, qi);

    switch (d.backend) {
        .net => |n| {
            if (qi == vnet.tx_queue) _ = n.tx(d, h, .{ .ctx = rig, .frame = NetRig.frame });
            // A frame of the host for the guest, in one to three parts.
            var fb: [1600]u8 = undefined;
            r.bytes(&fb);
            const a = r.uintLessThan(usize, fb.len);
            const b = a + r.uintLessThan(usize, fb.len - a);
            _ = n.deliver(d, h, .{}, &.{ fb[0..a], fb[a..b], fb[b..] });
            n.rxDone(d, h);
            _ = n.rxArm(d, h);
        },
        .vsock => |v| {
            if (r.uintLessThan(u8, 4) == 0) {
                if (v.connect(d, h, r.uintLessThan(u32, 8))) |c| {
                    var data: [512]u8 = undefined;
                    _ = v.send(d, h, c, data[0..r.uintLessThan(usize, data.len)]);
                    if (r.boolean()) v.close(d, h, c);
                }
            }
        },
        .console => _ = mmio.Console.push(d, h, "fuzz input"),
        else => {},
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var seconds: u64 = 10;
    var seed: u64 = 1;
    var race: u64 = 1;
    var k: usize = 1;
    while (k + 1 < args.len) : (k += 2) {
        const v = std.fmt.parseInt(u64, args[k + 1], 10) catch 0;
        if (std.mem.eql(u8, args[k], "--seconds")) seconds = v else if (std.mem.eql(u8, args[k], "--seed")) seed = v else if (std.mem.eql(u8, args[k], "--race")) race = v else {
            std.debug.print("usage: virtio-fuzz [--seconds N] [--seed N] [--race 0|1]\n", .{});
            return error.Usage;
        }
    }
    const a = std.heap.page_allocator;
    @memset(&guest, 0);
    var ctx: u8 = 0;
    const h: Host = .{ .ctx = &ctx, .mem = mem(), .interrupt = interrupt };

    var fs9: FakeFs = .{};
    var fsf: FakeFs = .{};
    var srv9 = ninep.Server.init(a, .{ .ctx = &fs9, .read_only = false, .vt = &FakeFs.vt });
    var srvf = fuse.Server.init(a, .{ .ctx = &fsf, .read_only = false, .vt = &FakeFs.vt });
    var vs = vsock.Vsock.init(a, 3, .{ .ctx = &ctx, .data = vsData, .event = vsEvent, .accept = vsAccept });
    var rig: NetRig = .{ .net = .{ .mac = nat.guest_mac, .ctx = &ctx, .kick = NetRig.kick } };
    rig.stack = .{ .host = .{ .ctx = &rig, .emit = NetRig.emit, .udpSend = NetRig.udpSend } };
    rig.host = &h;
    var devs = [_]Device{
        Device.console(1, .{ .ctx = &ctx, .write = consoleWrite, .rx_ready = noop }),
        Device.blk(2, .{ .ctx = &ctx, .size = disk.len, .read_only = false, .read = diskRead, .write = diskWrite, .flush = diskFlush }),
        Device.rng(3, fill),
        Device.vsock(4, &vs),
        Device.ninep(5, &srv9, "fuzz"),
        Device.virtiofs(6, &srvf, "fuzz"),
        Device.net(7, &rig.net),
        Device.balloon(8, .{ .ctx = &ctx, .report = report }),
    };
    // Each device accepts all its features and is at DRIVER_OK.
    for (&devs) |*d| {
        reg(d, &h, 0x024, 0);
        reg(d, &h, 0x020, @truncate(d.features));
        reg(d, &h, 0x024, 1);
        reg(d, &h, 0x020, @truncate(d.features >> 32));
        reg(d, &h, 0x070, 0xf);
    }

    var thread: ?std.Thread = null;
    if (race != 0) thread = try std.Thread.spawn(.{}, racer, .{seed});
    defer if (thread) |t| {
        race_stop.store(true, .monotonic);
        t.join();
    };
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const start = Io.Clock.awake.now(io);
    var rounds: u64 = 0;
    while (true) : (rounds += 1) {
        if (rounds % 4096 == 0) {
            const secs = @divFloor(start.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_s);
            if (secs >= seconds) break;
        }
        round(r, &devs, &h, &rig);
    }
    srv9.deinit();
    srvf.deinit();
    vs.deinit();
    std.debug.print("{d} rounds, {d} s, race {d}\n", .{ rounds, seconds, race });
}

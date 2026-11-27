//! The virtio-mmio transport of virtio 1.2 (section 4.2) and the devices
//! of `ztcl::vm` that run in ztcl: the console (5.3), block (5.2), and
//! entropy (5.4). A device that the hypervisor runs, such as vhost-vsock
//! on KVM, is an `External` device: the transport keeps its registers and
//! calls the hooks of the backend.
//!
//! A backend (src/kvm.zig, and the Windows Hypervisor Platform later)
//! gives each device a 4 KB window and an interrupt, and implements
//! `Host`:
//!
//! - `mem`: the guest memory as one host range from guest address 0.
//! - `interrupt(irq)`: an edge on the interrupt line of the device.
//!
//! The backend calls `Device.read` and `Device.write` for each access of
//! a vCPU to the window, with `Device.lock` held, and `Console.push` for
//! the input of the console. A write to QueueNotify runs the requests of
//! the queue on the thread of that vCPU, before the access returns.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const queue = @import("queue.zig");
pub const Mem = queue.Mem;
pub const Queue = queue.Queue;
pub const Chain = queue.Chain;

pub const window: u64 = 0x1000;
pub const f_version_1: u64 = 1 << 32;
pub const blk_f_ro: u64 = 1 << 5;
pub const status_driver_ok = 4;
pub const status_needs_reset = 0x40;
pub const int_vring = 1;

pub const Host = struct {
    ctx: *anyopaque,
    mem: Mem,
    interrupt: *const fn (ctx: *anyopaque, irq: u32) void,
};

/// A device that the hypervisor runs. `driverOk` gets the device when
/// the driver sets DRIVER_OK, and gives false when the device cannot
/// start. `reset` gets the device when the driver writes 0 to Status.
pub const External = struct {
    id: u32,
    ctx: *anyopaque,
    driverOk: *const fn (ctx: *anyopaque, d: *Device) bool,
    reset: *const fn (ctx: *anyopaque, d: *Device) void,
};

/// The output of the console, and the call that a new receive buffer
/// of the driver makes (so the backend can push its pending input).
pub const Console = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    rx_ready: *const fn (ctx: *anyopaque) void,

    /// Puts bytes of input in the receive queue. Gives the count that
    /// went in: the rest waits for `rx_ready`.
    pub fn push(d: *Device, host: *const Host, bytes: []const u8) usize {
        const q = &d.queues[0];
        var off: usize = 0;
        var any = false;
        while (off < bytes.len) {
            const head = q.next(host.mem) orelse break;
            any = true;
            var put: u32 = 0;
            if (Chain.read(q, host.mem, head)) |c| {
                for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
                    if (!w or off >= bytes.len) continue;
                    const k = @min(b.len, bytes.len - off);
                    @memcpy(b[0..k], bytes[off..][0..k]);
                    off += k;
                    put += @intCast(k);
                }
            }
            q.putUsed(host.mem, head, put);
        }
        if (any) d.raise(host);
        return off;
    }
};

/// A disk: reads and writes at a byte offset, each in full or false.
pub const Disk = struct {
    ctx: *anyopaque,
    size: u64,
    read_only: bool,
    read: *const fn (ctx: *anyopaque, buf: []u8, off: u64) bool,
    write: *const fn (ctx: *anyopaque, buf: []const u8, off: u64) bool,
    flush: *const fn (ctx: *anyopaque) void,
};

pub const Backend = union(enum) {
    console: Console,
    blk: Disk,
    rng: *const fn (buf: []u8) usize,
    external: External,
};

/// A spin lock for the registers of a device: the vCPU threads and the
/// console thread of the backend take it for a short time.
pub const Lock = struct {
    m: std.atomic.Mutex = .unlocked,
    pub fn lock(l: *Lock) void {
        while (!l.m.tryLock()) std.Thread.yield() catch {};
    }
    pub fn unlock(l: *Lock) void {
        l.m.unlock();
    }
};

pub const Device = struct {
    backend: Backend,
    irq: u32,
    features: u64,
    config: [16]u8 = @splat(0),
    config_len: u8 = 0,
    nqueues: u8,
    lock: Lock = .{},
    status: u32 = 0,
    dev_sel: u32 = 0,
    drv_sel: u32 = 0,
    driver_features: u64 = 0,
    queue_sel: u32 = 0,
    queues: [3]Queue = @splat(.{}),
    int_status: u32 = 0,

    pub fn console(irq: u32, c: Console) Device {
        return .{ .backend = .{ .console = c }, .irq = irq, .features = f_version_1, .nqueues = 2, .config_len = 12 };
    }

    pub fn blk(irq: u32, disk: Disk) Device {
        var d: Device = .{ .backend = .{ .blk = disk }, .irq = irq, .features = f_version_1 | (if (disk.read_only) blk_f_ro else 0), .nqueues = 1, .config_len = 8 };
        std.mem.writeInt(u64, d.config[0..8], disk.size / 512, .little);
        return d;
    }

    pub fn rng(irq: u32, fill: *const fn (buf: []u8) usize) Device {
        return .{ .backend = .{ .rng = fill }, .irq = irq, .features = f_version_1, .nqueues = 1 };
    }

    /// An external device with `features` (with VIRTIO_F_VERSION_1),
    /// `nqueues` queues, and the bytes of its configuration.
    pub fn external(irq: u32, e: External, features: u64, nqueues: u8, config: []const u8) Device {
        var d: Device = .{ .backend = .{ .external = e }, .irq = irq, .features = features, .nqueues = nqueues, .config_len = @intCast(config.len) };
        @memcpy(d.config[0..config.len], config);
        return d;
    }

    fn id(d: *const Device) u32 {
        return switch (d.backend) {
            .console => 3,
            .blk => 2,
            .rng => 4,
            .external => |e| e.id,
        };
    }

    /// Sets the bit of a used buffer and raises the interrupt.
    pub fn raise(d: *Device, host: *const Host) void {
        d.int_status |= int_vring;
        host.interrupt(host.ctx, d.irq);
    }

    pub fn read(d: *Device, off: u64, out: []u8) void {
        @memset(out, 0);
        if (off >= 0x100) {
            const c = off - 0x100;
            if (c < d.config_len and c + out.len <= d.config_len) @memcpy(out, d.config[@intCast(c)..][0..out.len]);
            return;
        }
        if (out.len != 4) return;
        const qok = d.queue_sel < d.nqueues;
        const q = &d.queues[@min(d.queue_sel, 2)];
        const v: u32 = switch (off) {
            0x000 => 0x74726976, // "virt"
            0x004 => 2,
            0x008 => d.id(),
            0x00c => 0x4c54375a,
            0x010 => if (d.dev_sel == 0) @truncate(d.features) else if (d.dev_sel == 1) @truncate(d.features >> 32) else 0,
            0x034 => if (qok) queue.max_queue else 0,
            0x044 => @intFromBool(qok and q.ready),
            // An external device raises its interrupts by itself (an
            // irqfd on KVM), so the status always has the bit of a used
            // buffer.
            0x060 => if (d.backend == .external) int_vring else d.int_status,
            0x070 => d.status,
            else => 0,
        };
        std.mem.writeInt(u32, out[0..4], v, .little);
    }

    pub fn write(d: *Device, host: *const Host, off: u64, data: []const u8) void {
        if (data.len != 4 or off >= 0x100) return;
        const v = std.mem.readInt(u32, data[0..4], .little);
        const qok = d.queue_sel < d.nqueues;
        const q = &d.queues[@min(d.queue_sel, 2)];
        switch (off) {
            0x014 => d.dev_sel = v,
            0x020 => {
                if (d.drv_sel == 0) d.driver_features = (d.driver_features & ~@as(u64, 0xffffffff)) | v;
                if (d.drv_sel == 1) d.driver_features = (d.driver_features & 0xffffffff) | (@as(u64, v) << 32);
                d.driver_features &= d.features;
            },
            0x024 => d.drv_sel = v,
            0x030 => d.queue_sel = v,
            0x038 => if (qok) {
                q.num = @min(v, queue.max_queue);
            },
            0x044 => if (qok) {
                q.ready = v == 1 and q.valid(host.mem);
                q.last_avail = 0;
            },
            0x050 => d.notify(host, v),
            0x064 => d.int_status &= ~v,
            0x070 => {
                if (v == 0) return d.reset();
                const was = d.status;
                d.status = v;
                if (v & status_driver_ok != 0 and was & status_driver_ok == 0) switch (d.backend) {
                    .external => |e| if (!e.driverOk(e.ctx, d)) {
                        d.status |= status_needs_reset;
                    },
                    else => {},
                };
            },
            0x080 => if (qok) setLow(&q.desc, v),
            0x084 => if (qok) setHigh(&q.desc, v),
            0x090 => if (qok) setLow(&q.avail, v),
            0x094 => if (qok) setHigh(&q.avail, v),
            0x0a0 => if (qok) setLow(&q.used, v),
            0x0a4 => if (qok) setHigh(&q.used, v),
            else => {},
        }
    }

    fn reset(d: *Device) void {
        if (d.backend == .external) d.backend.external.reset(d.backend.external.ctx, d);
        d.status = 0;
        d.dev_sel = 0;
        d.drv_sel = 0;
        d.driver_features = 0;
        d.queue_sel = 0;
        d.queues = @splat(.{});
        d.int_status = 0;
    }

    /// A notification of the driver for queue `qi`.
    fn notify(d: *Device, host: *const Host, qi: u32) void {
        switch (d.backend) {
            .console => |c| if (qi == 1) d.consoleTx(host, c) else if (qi == 0) c.rx_ready(c.ctx),
            .blk => |disk| if (qi == 0) d.blkRequests(host, disk),
            .rng => |fill| if (qi == 0) d.rngFill(host, fill),
            .external => {},
        }
    }

    fn consoleTx(d: *Device, host: *const Host, c: Console) void {
        const q = &d.queues[1];
        var any = false;
        while (q.next(host.mem)) |head| {
            any = true;
            if (Chain.read(q, host.mem, head)) |ch| {
                for (ch.bufs[0..ch.n], ch.writable[0..ch.n]) |b, w| if (!w) c.write(c.ctx, b);
            }
            q.putUsed(host.mem, head, 0);
        }
        if (any) d.raise(host);
    }

    fn rngFill(d: *Device, host: *const Host, fill: *const fn (buf: []u8) usize) void {
        const q = &d.queues[0];
        var any = false;
        while (q.next(host.mem)) |head| {
            any = true;
            var put: u32 = 0;
            if (Chain.read(q, host.mem, head)) |c| {
                for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
                    if (w) put += @intCast(fill(b));
                }
            }
            q.putUsed(host.mem, head, put);
        }
        if (any) d.raise(host);
    }

    fn blkRequests(d: *Device, host: *const Host, disk: Disk) void {
        const q = &d.queues[0];
        var any = false;
        while (q.next(host.mem)) |head| {
            any = true;
            q.putUsed(host.mem, head, blkOne(disk, q, host.mem, head));
        }
        if (any) d.raise(host);
    }
};

fn setLow(x: *u64, v: u32) void {
    x.* = (x.* & ~@as(u64, 0xffffffff)) | v;
}
fn setHigh(x: *u64, v: u32) void {
    x.* = (x.* & 0xffffffff) | (@as(u64, v) << 32);
}

const blk_in = 0;
const blk_out = 1;
const blk_flush = 4;
const blk_get_id = 8;
const blk_ok = 0;
const blk_ioerr = 1;
const blk_unsupp = 2;

/// Runs one block request and gives the count of bytes that it wrote to
/// the guest, with the status byte.
fn blkOne(disk: Disk, q: *Queue, mem: Mem, head: u16) u32 {
    const c = Chain.read(q, mem, head) orelse return 0;
    if (c.n < 2 or c.bufs[0].len < 16 or c.writable[0]) return 0;
    const last = c.bufs[c.n - 1];
    if (!c.writable[c.n - 1] or last.len < 1) return 0;
    const kind = std.mem.readInt(u32, c.bufs[0][0..4], .little);
    const sector = std.mem.readInt(u64, c.bufs[0][8..16], .little);
    var status: u8 = blk_ok;
    var written: u32 = 0;
    const data = c.bufs[1 .. c.n - 1];
    const data_w = c.writable[1 .. c.n - 1];
    switch (kind) {
        blk_in, blk_out => {
            if (sector > disk.size / 512) {
                status = blk_ioerr;
            } else {
                var pos: u64 = sector * 512;
                for (data, data_w) |b, w| {
                    if (b.len > disk.size - @min(pos, disk.size)) {
                        status = blk_ioerr;
                        break;
                    }
                    const good = if (kind == blk_in)
                        w and disk.read(disk.ctx, b, pos)
                    else
                        !w and !disk.read_only and disk.write(disk.ctx, b, pos);
                    if (!good) {
                        status = blk_ioerr;
                        break;
                    }
                    if (kind == blk_in) written += @intCast(b.len);
                    pos += b.len;
                }
            }
        },
        blk_flush => if (!disk.read_only) disk.flush(disk.ctx),
        blk_get_id => {
            if (data.len >= 1 and data_w[0]) {
                const name = "ztcl-vm-disk";
                const b = data[0];
                @memset(b[0..@min(b.len, 20)], 0);
                const k = @min(b.len, name.len);
                @memcpy(b[0..k], name[0..k]);
                written += @intCast(@min(b.len, 20));
            } else status = blk_ioerr;
        },
        else => status = blk_unsupp,
    }
    last[last.len - 1] = status;
    return written + 1;
}

// The tests run a device against a fake guest memory with one queue.

const Fake = struct {
    mem: [64 * 1024]u8 align(8) = @splat(0),
    irqs: u32 = 0,
    out: [256]u8 = undefined,
    out_len: usize = 0,

    fn host(f: *Fake) Host {
        return .{ .ctx = f, .mem = .{ .base = &f.mem, .size = f.mem.len }, .interrupt = interrupt };
    }
    fn interrupt(ctx: *anyopaque, _: u32) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.irqs += 1;
    }
    fn write(ctx: *anyopaque, b: []const u8) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        @memcpy(f.out[f.out_len..][0..b.len], b);
        f.out_len += b.len;
    }
    fn noop(_: *anyopaque) void {}

    fn reg(d: *Device, h: *const Host, off: u64, v: u32) void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        d.write(h, off, &b);
    }

    /// Sets queue `qi` ready with its rings at 0x1000 (descriptors),
    /// 0x2000 (available), and 0x3000 (used), 8 entries.
    fn ready(d: *Device, h: *const Host, qi: u32) void {
        reg(d, h, 0x030, qi);
        reg(d, h, 0x038, 8);
        reg(d, h, 0x080, 0x1000);
        reg(d, h, 0x090, 0x2000);
        reg(d, h, 0x0a0, 0x3000);
        reg(d, h, 0x044, 1);
    }

    /// Makes a chain of `bufs` (address, length, writable) available.
    fn offer(f: *Fake, bufs: []const struct { u64, u32, bool }) void {
        const m: Mem = .{ .base = &f.mem, .size = f.mem.len };
        for (bufs, 0..) |b, i| {
            const at = 0x1000 + 16 * i;
            m.put(u64, at, b[0]);
            m.put(u32, at + 8, b[1]);
            const more: u16 = if (i + 1 < bufs.len) queue.desc_f_next else 0;
            m.put(u16, at + 12, more | (if (b[2]) @as(u16, queue.desc_f_write) else 0));
            m.put(u16, at + 14, @intCast(i + 1));
        }
        const idx = std.mem.readInt(u16, f.mem[0x2002..0x2004], .little);
        m.put(u16, 0x2004 + 2 * @as(u64, idx % 8), 0);
        m.put(u16, 0x2002, idx +% 1);
    }
};

test "virtio: the registers of a device" {
    var f: Fake = .{};
    const h = f.host();
    var d = Device.console(5, .{ .ctx = &f, .write = Fake.write, .rx_ready = Fake.noop });
    var b: [4]u8 = undefined;
    d.read(0x000, &b);
    try std.testing.expectEqual(@as(u32, 0x74726976), std.mem.readInt(u32, &b, .little));
    d.read(0x008, &b);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, &b, .little));
    Fake.reg(&d, &h, 0x014, 1);
    d.read(0x010, &b);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, &b, .little));
    // A queue whose rings are outside the guest memory is not ready.
    Fake.reg(&d, &h, 0x038, 8);
    Fake.reg(&d, &h, 0x080, 0xfff0);
    Fake.reg(&d, &h, 0x044, 1);
    d.read(0x044, &b);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, &b, .little));
}

test "virtio: the console sends the bytes of the driver" {
    var f: Fake = .{};
    const h = f.host();
    var d = Device.console(5, .{ .ctx = &f, .write = Fake.write, .rx_ready = Fake.noop });
    Fake.ready(&d, &h, 1);
    @memcpy(f.mem[0x4000..0x4005], "hello");
    f.offer(&.{.{ 0x4000, 5, false }});
    Fake.reg(&d, &h, 0x050, 1);
    try std.testing.expectEqualStrings("hello", f.out[0..f.out_len]);
    try std.testing.expectEqual(@as(u32, 1), f.irqs);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, f.mem[0x3002..0x3004], .little));
}

test "virtio: a block read, and a write to a read-only disk" {
    const S = struct {
        var data: [4096]u8 = undefined;
        fn read(_: *anyopaque, buf: []u8, off: u64) bool {
            @memcpy(buf, data[@intCast(off)..][0..buf.len]);
            return true;
        }
        fn write(_: *anyopaque, _: []const u8, _: u64) bool {
            return true;
        }
        fn flush(_: *anyopaque) void {}
    };
    for (&S.data, 0..) |*x, i| x.* = @truncate(i / 512);
    var f: Fake = .{};
    const h = f.host();
    var d = Device.blk(6, .{ .ctx = &f, .size = S.data.len, .read_only = true, .read = S.read, .write = S.write, .flush = S.flush });
    Fake.ready(&d, &h, 0);
    const m = h.mem;
    m.put(u32, 0x4000, blk_in);
    m.put(u64, 0x4008, 3);
    f.offer(&.{ .{ 0x4000, 16, false }, .{ 0x5000, 512, true }, .{ 0x6000, 1, true } });
    Fake.reg(&d, &h, 0x050, 0);
    try std.testing.expectEqual(@as(u8, 3), f.mem[0x5000]);
    try std.testing.expectEqual(@as(u8, blk_ok), f.mem[0x6000]);
    m.put(u32, 0x4000, blk_out);
    f.offer(&.{ .{ 0x4000, 16, false }, .{ 0x5000, 512, false }, .{ 0x6000, 1, true } });
    Fake.reg(&d, &h, 0x050, 0);
    try std.testing.expectEqual(@as(u8, blk_ioerr), f.mem[0x6000]);
    // A read past the end of the disk.
    m.put(u32, 0x4000, blk_in);
    m.put(u64, 0x4008, 8);
    f.offer(&.{ .{ 0x4000, 16, false }, .{ 0x5000, 512, true }, .{ 0x6000, 1, true } });
    Fake.reg(&d, &h, 0x050, 0);
    try std.testing.expectEqual(@as(u8, blk_ioerr), f.mem[0x6000]);
}

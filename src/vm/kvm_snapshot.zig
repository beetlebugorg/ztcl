//! Snapshots, restores, and clones of a KVM machine of `kvm.zig`
//! (ztcl#468). The sources are the KVM API document of the kernel
//! (Documentation/virt/kvm/api.rst), the vhost ioctls of
//! include/uapi/linux/vhost.h as the vhost documentation gives them, and
//! the virtio 1.2 specification of OASIS (5.10.6.7: the transport reset
//! event of vsock).
//!
//! A snapshot is one file:
//!
//!   0          the header (`Header`, 4 KB)
//!   4096       the state: the VM, the devices, then each vCPU
//!   mem_off    the guest memory, on a 2 MB boundary of the file
//!
//! The state of the VM is the three interrupt controllers of KVM (the two
//! PICs and the IOAPIC), the PIT, the clock of KVM, the UART registers,
//! and the first available index of the two vsock queues of vhost. The
//! state of a device is its virtio-mmio registers and its queues. The
//! state of a vCPU is its registers, its special registers, its XSAVE
//! area, its XCRs, its local APIC, its pending events, its MP state, its
//! debug registers, and each MSR of `KVM_GET_MSR_INDEX_LIST` that it
//! reads.
//!
//! The snapshot writes only the memory pages that are not all zero, so
//! the memory part of the file is sparse, and the header has a bit for
//! each 2 MB chunk with data. A restore maps each run of chunks with data
//! from the file with `MAP_PRIVATE` and `MAP_FIXED`, over an anonymous
//! mapping with transparent huge pages: a page of the guest in a chunk
//! with data comes from the page cache on its first touch and is copied
//! on its first write, and the other chunks get 2 MB pages. Each restore of one file is a clone: the
//! clones share the pages that none of them writes.
//!
//! A clone gets a new vsock context ID in the configuration of its vsock
//! device and the event `VIRTIO_VSOCK_EVENT_TRANSPORT_RESET` on the
//! event queue. The driver of the guest then reads the configuration
//! again and resets its connections. A socket that listens stays.
//!
//! A machine with 9p shares has no snapshot: the server state of a share
//! (the open files of the guest) is outside the guest memory.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const kvm = @import("../kvm.zig");
const virtio = @import("virtio/mmio.zig");
const linux = std.os.linux;
const IOCTL = linux.IOCTL;
const Machine = kvm;
const Fail = kvm.Fail;
const ioctl = kvm.ioctl;
const check = kvm.check;
const ok = kvm.ok;

const KVMIO = kvm.KVMIO;
const KVM_GET_MSR_INDEX_LIST = IOCTL.IOWR(KVMIO, 0x02, u32);
const KVM_SET_USER_MEMORY_REGION = IOCTL.IOW(KVMIO, 0x46, MemoryRegion);
const KVM_GET_IRQCHIP = IOCTL.IOWR(KVMIO, 0x62, Irqchip);
const KVM_SET_IRQCHIP = IOCTL.IOR(KVMIO, 0x63, Irqchip);
const KVM_SET_CLOCK = IOCTL.IOW(KVMIO, 0x7b, Clock);
const KVM_GET_CLOCK = IOCTL.IOR(KVMIO, 0x7c, Clock);
const KVM_GET_REGS = IOCTL.IOR(KVMIO, 0x81, [144]u8);
const KVM_SET_REGS = IOCTL.IOW(KVMIO, 0x82, [144]u8);
const KVM_GET_SREGS = IOCTL.IOR(KVMIO, 0x83, [312]u8);
const KVM_SET_SREGS = IOCTL.IOW(KVMIO, 0x84, [312]u8);
const KVM_GET_MSRS = IOCTL.IOWR(KVMIO, 0x88, [8]u8);
const KVM_SET_MSRS = IOCTL.IOW(KVMIO, 0x89, [8]u8);
const KVM_GET_LAPIC = IOCTL.IOR(KVMIO, 0x8e, [1024]u8);
const KVM_SET_LAPIC = IOCTL.IOW(KVMIO, 0x8f, [1024]u8);
const KVM_GET_MP_STATE = IOCTL.IOR(KVMIO, 0x98, u32);
const KVM_SET_MP_STATE = IOCTL.IOW(KVMIO, 0x99, u32);
const KVM_GET_PIT2 = IOCTL.IOR(KVMIO, 0x9f, [112]u8);
const KVM_SET_PIT2 = IOCTL.IOW(KVMIO, 0xa0, [112]u8);
const KVM_GET_VCPU_EVENTS = IOCTL.IOR(KVMIO, 0x9f, [64]u8);
const KVM_SET_VCPU_EVENTS = IOCTL.IOW(KVMIO, 0xa0, [64]u8);
const KVM_GET_DEBUGREGS = IOCTL.IOR(KVMIO, 0xa1, [128]u8);
const KVM_SET_DEBUGREGS = IOCTL.IOW(KVMIO, 0xa2, [128]u8);
const KVM_GET_XSAVE = IOCTL.IOR(KVMIO, 0xa4, [4096]u8);
const KVM_SET_XSAVE = IOCTL.IOW(KVMIO, 0xa5, [4096]u8);
const KVM_GET_XCRS = IOCTL.IOR(KVMIO, 0xa6, [392]u8);
const KVM_SET_XCRS = IOCTL.IOW(KVMIO, 0xa7, [392]u8);
const KVM_KVMCLOCK_CTRL = IOCTL.IO(KVMIO, 0xad);
const madv_hugepage = 14;
const VHOST_VSOCK_SET_RUNNING = IOCTL.IOW(kvm.VHOST, 0x61, c_int);
const VHOST_GET_VRING_BASE = IOCTL.IOWR(kvm.VHOST, 0x12, kvm.VringState);

const MemoryRegion = extern struct { slot: u32, flags: u32, guest_phys_addr: u64, memory_size: u64, userspace_addr: u64 };
/// `struct kvm_irqchip`: the chip (0 and 1 the PICs, 2 the IOAPIC) and
/// its 512 bytes.
const Irqchip = extern struct { chip_id: u32, pad: u32 = 0, data: [512]u8 = @splat(0) };
/// `struct kvm_clock_data`.
const Clock = extern struct { clock: u64 = 0, flags: u32 = 0, pad0: u32 = 0, realtime: u64 = 0, host_tsc: u64 = 0, pad: [4]u32 = @splat(0) };
const MsrEntry = extern struct { index: u32, reserved: u32 = 0, data: u64 = 0 };

pub const magic = "ZTVMSNP1".*;
pub const version: u32 = 1;
const header_size = 4096;
/// The longest tag: the embedder data of a snapshot (`ztcl::vm` puts the
/// image name and its counter there).
pub const max_tag = 1024;

pub const Header = extern struct {
    magic: [8]u8 = magic,
    version: u32 = version,
    cpus: u32,
    memory_mb: u32,
    devices: u32,
    disks: u32,
    entropy: u32,
    balloon: u32,
    nmsrs: u32,
    tag_len: u32,
    state_len: u64,
    mem_off: u64,
    mem_size: u64,
    /// The bytes of the memory that the snapshot wrote (the pages that
    /// are not all zero).
    mem_written: u64,
    tag: [max_tag]u8 = @splat(0),
    /// A bit for each 2 MB chunk of the memory: 1 when the chunk has a
    /// page that is not all zero.
    chunks: [max_chunks / 8]u8 = @splat(0),
};

/// The 2 MB chunks of the most memory of a snapshot: 8 GB.
const max_chunks = 4096;

const QueueState = extern struct { num: u32, ready: u32, desc: u64, avail: u64, used: u64, last_avail: u32, pad: u32 = 0 };
const DeviceState = extern struct {
    kind: u32,
    status: u32,
    dev_sel: u32,
    drv_sel: u32,
    queue_sel: u32,
    int_status: u32,
    driver_features: u64,
    config: @FieldType(virtio.Device, "config"),
    queues: [3]QueueState,
};
const VmState = extern struct {
    irqchips: [3]Irqchip,
    pit: [112]u8,
    clock: Clock,
    uart: [8]u8,
    vs_base: [2]u32,
};
const VcpuState = extern struct {
    regs: [144]u8,
    sregs: [312]u8,
    xsave: [4096]u8,
    xcrs: [392]u8,
    lapic: [1024]u8,
    events: [64]u8,
    debugregs: [128]u8,
    mp_state: u32,
    nmsrs: u32,
};

/// The configuration that a snapshot needs from its restore, from the
/// header.
pub const Info = struct { cpus: u32, memory_mb: u32, disks: u32, entropy: bool, balloon: bool, tag: []const u8, mem_written: u64 };

/// The time of each part of the last restore, in ns.
/// `prepare` is the VM, its devices, and its vCPUs (0 when the machine
/// was ready), `memory` the mapping, `devices` their state, and
/// `state` the state of the vCPUs and of the VM with the start of vhost.
pub const Times = struct { prepare: u64 = 0, memory: u64 = 0, devices: u64 = 0, vcpus: u64 = 0, state: u64 = 0, total: u64 = 0 };
pub threadlocal var last_restore: Times = .{};
pub threadlocal var last_prepare: u64 = 0;

// ---------------------------------------------------------------------
// The MSRs

var msr_list_lock: virtio.Lock = .{};
var msr_list: [512]u32 = undefined;
var msr_count: usize = 0;
var msr_ready = std.atomic.Value(bool).init(false);

/// The MSRs that KVM saves and restores, from `KVM_GET_MSR_INDEX_LIST`,
/// once per process.
fn msrIndices(kvm_fd: i32) Fail![]const u32 {
    if (msr_ready.load(.acquire)) return msr_list[0..msr_count];
    msr_list_lock.lock();
    defer msr_list_lock.unlock();
    if (msr_ready.load(.acquire)) return msr_list[0..msr_count];
    var buf: extern struct { n: u32, idx: [512]u32 } = .{ .n = 512, .idx = undefined };
    _ = try check(ioctl(kvm_fd, KVM_GET_MSR_INDEX_LIST, @intFromPtr(&buf)), "KVM_GET_MSR_INDEX_LIST");
    msr_count = @min(buf.n, msr_list.len);
    @memcpy(msr_list[0..msr_count], buf.idx[0..msr_count]);
    msr_ready.store(true, .release);
    return msr_list[0..msr_count];
}

/// Reads each MSR of `indices` that the vCPU has into `out`, and gives
/// their count. `KVM_GET_MSRS` stops at the first MSR that it cannot
/// read, so the read goes on after it.
fn readMsrs(fd: i32, indices: []const u32, out: []MsrEntry) usize {
    var buf: extern struct { n: u32, pad: u32 = 0, e: [512]MsrEntry } = .{ .n = 0, .e = undefined };
    var n: usize = 0;
    var i: usize = 0;
    while (i < indices.len) {
        const k = indices.len - i;
        for (0..k) |j| buf.e[j] = .{ .index = indices[i + j] };
        buf.n = @intCast(k);
        const rc = ioctl(fd, KVM_GET_MSRS, @intFromPtr(&buf));
        const got = ok(rc) orelse 0;
        @memcpy(out[n..][0..got], buf.e[0..got]);
        n += got;
        i += got + 1;
    }
    return n;
}

/// Writes the MSRs of `in`. `KVM_SET_MSRS` stops at the first MSR that it
/// cannot write, so the write goes on after it.
fn writeMsrs(fd: i32, in: []const MsrEntry) void {
    var buf: extern struct { n: u32, pad: u32 = 0, e: [512]MsrEntry } = .{ .n = 0, .e = undefined };
    var i: usize = 0;
    while (i < in.len) {
        const k = @min(in.len - i, buf.e.len);
        @memcpy(buf.e[0..k], in[i..][0..k]);
        buf.n = @intCast(k);
        const got = ok(ioctl(fd, KVM_SET_MSRS, @intFromPtr(&buf))) orelse 0;
        i += got + 1;
    }
}

// ---------------------------------------------------------------------
// The snapshot

fn put(list: *std.ArrayList(u8), a: std.mem.Allocator, v: anytype) Fail!void {
    try list.appendSlice(a, std.mem.asBytes(v));
}

fn deviceKind(d: *const virtio.Device) u32 {
    return @backingInt(std.meta.activeTag(d.backend));
}

/// Stops vhost-vsock and gives the first available index of its two
/// queues.
fn vhostPause(m: *Machine) [2]u16 {
    var bases: [2]u16 = m.vs_base;
    if (!m.vs_running) return bases;
    var off: c_int = 0;
    _ = ioctl(m.vhost, VHOST_VSOCK_SET_RUNNING, @intFromPtr(&off));
    for (0..2) |q| {
        var st: kvm.VringState = .{ .index = @intCast(q), .num = 0 };
        if (ok(ioctl(m.vhost, VHOST_GET_VRING_BASE, @intFromPtr(&st))) != null) bases[q] = @truncate(st.num);
    }
    m.vs_running = false;
    return bases;
}

fn zeroPage(p: *const [4096]u8) bool {
    const V = @Vector(64, u8);
    var acc: V = @splat(0);
    var i: usize = 0;
    while (i < 4096) : (i += 64) acc |= @as(V, p[i..][0..64].*);
    return @reduce(.Or, acc) == 0;
}

fn pwriteAll(fd: i32, b: []const u8, pos: u64) Fail!void {
    var off: usize = 0;
    while (off < b.len) {
        const rc = linux.pwrite(fd, b[off..].ptr, b.len - off, @intCast(pos + off));
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            else => {
                kvm.why = "the write of the snapshot";
                return error.Setup;
            },
        }
    }
}

fn preadAll(fd: i32, b: []u8, pos: u64) Fail!void {
    var off: usize = 0;
    while (off < b.len) {
        const rc = linux.pread(fd, b[off..].ptr, b.len - off, @intCast(pos + off));
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) {
                    kvm.why = "the snapshot is too short";
                    return error.Setup;
                }
                off += rc;
            },
            .INTR => continue,
            else => {
                kvm.why = "the read of the snapshot";
                return error.Setup;
            },
        }
    }
}

/// Writes a snapshot of the machine to `fd` (a file open for writing),
/// with the embedder bytes `tag`. A running machine pauses for the
/// snapshot and runs again after it. Gives the size of the memory that
/// the snapshot wrote.
pub fn save(m: *Machine, fd: i32, tag: []const u8) Fail!u64 {
    const s0 = m.getState();
    if (s0 != .running and s0 != .paused) {
        kvm.why = "a snapshot of a machine that does not run";
        return error.Setup;
    }
    if (m.cfg.shares.len != 0) {
        kvm.why = "a snapshot of a machine with a 9p share";
        return error.Setup;
    }
    if (m.cfg.net != null) {
        kvm.why = "a snapshot of a machine with -net: the NAT state is outside the guest memory";
        return error.Setup;
    }
    if (tag.len > max_tag) {
        kvm.why = "a snapshot tag of more than 1024 bytes";
        return error.Setup;
    }
    if (m.mem.size > max_chunks * kvm.huge_page) {
        kvm.why = "a snapshot of a guest with more than 8 GB";
        return error.Setup;
    }
    if (s0 == .running) m.pause();
    defer if (s0 == .running) m.@"resume"();
    if (m.getState() != .paused) {
        kvm.why = "the machine stopped during the snapshot";
        return error.Setup;
    }
    const a = m.alloc;
    const bases = vhostPause(m);
    defer if (m.devices.len > 1 and m.devices[1].status & virtio.status_driver_ok != 0) {
        m.vs_base = bases;
        _ = kvm.vhostStart(m, &m.devices[1]);
    };

    var st: std.ArrayList(u8) = .empty;
    defer st.deinit(a);

    var vs: VmState = undefined;
    for (&vs.irqchips, 0..) |*c, i| {
        c.* = .{ .chip_id = @intCast(i) };
        _ = try check(ioctl(m.vm, KVM_GET_IRQCHIP, @intFromPtr(c)), "KVM_GET_IRQCHIP");
    }
    _ = try check(ioctl(m.vm, KVM_GET_PIT2, @intFromPtr(&vs.pit)), "KVM_GET_PIT2");
    vs.clock = .{};
    _ = try check(ioctl(m.vm, KVM_GET_CLOCK, @intFromPtr(&vs.clock)), "KVM_GET_CLOCK");
    vs.uart = m.uart;
    vs.vs_base = .{ bases[0], bases[1] };
    try put(&st, a, &vs);

    for (m.devices) |*d| {
        var ds: DeviceState = .{ .kind = deviceKind(d), .status = d.status, .dev_sel = d.dev_sel, .drv_sel = d.drv_sel, .queue_sel = d.queue_sel, .int_status = d.int_status, .driver_features = d.driver_features, .config = d.config, .queues = undefined };
        for (&ds.queues, d.queues) |*o, q| o.* = .{ .num = q.num, .ready = @intFromBool(q.ready), .desc = q.desc, .avail = q.avail, .used = q.used, .last_avail = q.last_avail };
        try put(&st, a, &ds);
    }

    const indices = try msrIndices(m.kvm);
    const msrs = try a.alloc(MsrEntry, indices.len);
    defer a.free(msrs);
    for (m.vcpus) |*v| {
        var cs: VcpuState = undefined;
        _ = try check(ioctl(v.fd, KVM_GET_MP_STATE, @intFromPtr(&cs.mp_state)), "KVM_GET_MP_STATE");
        _ = try check(ioctl(v.fd, KVM_GET_REGS, @intFromPtr(&cs.regs)), "KVM_GET_REGS");
        _ = try check(ioctl(v.fd, KVM_GET_SREGS, @intFromPtr(&cs.sregs)), "KVM_GET_SREGS");
        _ = try check(ioctl(v.fd, KVM_GET_XSAVE, @intFromPtr(&cs.xsave)), "KVM_GET_XSAVE");
        _ = try check(ioctl(v.fd, KVM_GET_XCRS, @intFromPtr(&cs.xcrs)), "KVM_GET_XCRS");
        _ = try check(ioctl(v.fd, KVM_GET_LAPIC, @intFromPtr(&cs.lapic)), "KVM_GET_LAPIC");
        _ = try check(ioctl(v.fd, KVM_GET_VCPU_EVENTS, @intFromPtr(&cs.events)), "KVM_GET_VCPU_EVENTS");
        _ = try check(ioctl(v.fd, KVM_GET_DEBUGREGS, @intFromPtr(&cs.debugregs)), "KVM_GET_DEBUGREGS");
        const n = readMsrs(v.fd, indices, msrs);
        cs.nmsrs = @intCast(n);
        try put(&st, a, &cs);
        try st.appendSlice(a, std.mem.sliceAsBytes(msrs[0..n]));
    }

    const size = m.mem.size;
    var h: Header = .{
        .cpus = @intCast(m.vcpus.len),
        .memory_mb = @intCast(size >> 20),
        .devices = @intCast(m.devices.len),
        .disks = @intCast(m.cfg.disks.len),
        .entropy = @intFromBool(m.cfg.entropy),
        .balloon = @intFromBool(m.cfg.balloon),
        .nmsrs = @intCast(indices.len),
        .tag_len = @intCast(tag.len),
        .state_len = st.items.len,
        .mem_off = std.mem.alignForward(u64, header_size + st.items.len, kvm.huge_page),
        .mem_size = size,
        .mem_written = 0,
    };
    @memcpy(h.tag[0..tag.len], tag);
    if (linux.errno(linux.ftruncate(fd, 0)) != .SUCCESS or linux.errno(linux.ftruncate(fd, @intCast(h.mem_off + size))) != .SUCCESS) {
        kvm.why = "the size of the snapshot file";
        return error.Setup;
    }
    try pwriteAll(fd, st.items, header_size);

    // The memory: each run of pages that are not all zero.
    const mem = m.mem.base[0..@intCast(size)];
    var p: usize = 0;
    while (p < mem.len) {
        if (zeroPage(mem[p..][0..4096])) {
            p += 4096;
            continue;
        }
        var e = p + 4096;
        while (e < mem.len and !zeroPage(mem[e..][0..4096])) e += 4096;
        try pwriteAll(fd, mem[p..e], h.mem_off + p);
        h.mem_written += e - p;
        var c = p / kvm.huge_page;
        while (c * kvm.huge_page < e) : (c += 1) h.chunks[c / 8] |= @as(u8, 1) << @intCast(c % 8);
        p = e;
    }
    try pwriteAll(fd, std.mem.asBytes(&h), 0);
    return h.mem_written;
}

// ---------------------------------------------------------------------
// The restore

/// Reads the header of a snapshot: the configuration that its restore
/// needs. The tag points into `buf`.
pub fn info(fd: i32, buf: *Header) Fail!Info {
    try preadAll(fd, std.mem.asBytes(buf), 0);
    if (!std.mem.eql(u8, &buf.magic, &magic) or buf.version != version or buf.tag_len > max_tag or buf.cpus == 0 or buf.mem_off % 4096 != 0) {
        kvm.why = "the file is not a snapshot of this version";
        return error.Setup;
    }
    return .{ .cpus = buf.cpus, .memory_mb = buf.memory_mb, .disks = buf.disks, .entropy = buf.entropy != 0, .balloon = buf.balloon != 0, .tag = buf.tag[0..buf.tag_len], .mem_written = buf.mem_written };
}

/// Makes the parts of a restore that need no snapshot: the VM, a memory
/// slot on an empty mapping of the size of `cfg.memory_mb`, the devices,
/// and the vCPUs with their threads, parked. These steps are most of the
/// time of a restore (`KVM_CREATE_VCPU` and `KVM_SET_USER_MEMORY_REGION`
/// are milliseconds each on a busy host), so a pool can prepare machines
/// before it needs them. The restore maps the file over the empty
/// mapping with `MAP_FIXED`, and the memory slot of KVM stays.
pub fn prepare(m: *Machine) Fail!void {
    const t0 = kvm.nowNs();
    m.teardown();
    m.want.store(kvm.want_pause, .seq_cst);
    m.parked.store(0, .seq_cst);
    errdefer m.teardown();
    try m.setupVm();
    const size: u64 = @as(u64, m.cfg.memory_mb) << 20;
    // As at a boot, the memory starts on a 2 MB boundary and asks for
    // transparent huge pages: the chunks of a snapshot with no data stay
    // in this mapping, so the new memory of a clone is in 2 MB pages.
    const map_len: usize = @intCast(size + kvm.huge_page);
    const raw = linux.mmap(null, map_len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
    if (ok(raw) == null) {
        kvm.why = "no host memory for the guest";
        return error.Memory;
    }
    m.mem_map = .{ .addr = raw, .len = map_len };
    const base = std.mem.alignForward(usize, raw, kvm.huge_page);
    _ = linux.madvise(@ptrFromInt(base), @intCast(size), madv_hugepage);
    m.mem = .{ .base = @ptrFromInt(base), .size = size };
    var region: MemoryRegion = .{ .slot = 0, .flags = 0, .guest_phys_addr = 0, .memory_size = size, .userspace_addr = base };
    _ = try check(ioctl(m.vm, KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region)), "KVM_SET_USER_MEMORY_REGION");
    try m.makeDevices();
    try m.makeVcpus();
    for (m.vcpus) |*v| v.thread = std.Thread.spawn(.{ .stack_size = kvm.thread_stack }, kvm.vcpuMain, .{v}) catch {
        kvm.why = "no thread for a vCPU";
        return error.Setup;
    };
    m.con_thread = std.Thread.spawn(.{ .stack_size = kvm.thread_stack }, kvm.consoleMain, .{m}) catch null;
    // Each vCPU thread parks before the restore sets its state.
    while (true) {
        const p = m.parked.load(.seq_cst);
        if (p >= m.vcpus.len) break;
        _ = linux.futex_4arg(&m.parked.raw, .{ .cmd = .WAIT, .private = true }, p, null);
    }
    m.snap_ready = true;
    last_prepare = kvm.nowNs() - t0;
}

/// Restores the snapshot of `fd` into the machine `m`, which `kvm.init`
/// made with the configuration of `info` (the CPU count, the memory, the
/// disks, the entropy device, and the balloon), and which `prepare` made
/// ready, or else the restore calls `prepare`. The machine is paused
/// after the restore, and `resume` runs it. The descriptor can close
/// after the restore: the mapping of the memory holds the file.
pub fn restore(m: *Machine, fd: i32) Fail!void {
    const t0 = kvm.nowNs();
    var h: Header = undefined;
    const in = try info(fd, &h);
    if (in.cpus != m.cfg.cpus or in.memory_mb != m.cfg.memory_mb or h.devices != m.deviceCount() or m.cfg.shares.len != 0) {
        kvm.why = "the configuration of the machine is not the one of the snapshot";
        return error.Setup;
    }
    const a = m.alloc;
    const st = try a.alloc(u8, @intCast(h.state_len));
    defer a.free(st);
    try preadAll(fd, st, header_size);
    const need = @sizeOf(VmState) + h.devices * @sizeOf(DeviceState) + h.cpus * @sizeOf(VcpuState);
    if (st.len < need) {
        kvm.why = "the state of the snapshot is too short";
        return error.Setup;
    }

    errdefer m.teardown();
    if (h.mem_size != @as(u64, m.cfg.memory_mb) << 20 or h.mem_size > max_chunks * kvm.huge_page) {
        kvm.why = "the memory size of the snapshot is not the one of its header";
        return error.Setup;
    }
    if (!m.snap_ready) try prepare(m);
    m.snap_ready = false;
    const t1 = kvm.nowNs();

    // Each chunk with data maps its part of the file; the others stay
    // in the empty mapping of `prepare`.
    const chunks: usize = @intCast(std.math.divCeil(u64, h.mem_size, kvm.huge_page) catch 0);
    var ci: usize = 0;
    while (ci < chunks) {
        if (h.chunks[ci / 8] & (@as(u8, 1) << @intCast(ci % 8)) == 0) {
            ci += 1;
            continue;
        }
        var e = ci + 1;
        while (e < chunks and h.chunks[e / 8] & (@as(u8, 1) << @intCast(e % 8)) != 0) e += 1;
        const off = ci * kvm.huge_page;
        const len = @min(e * kvm.huge_page, @as(usize, @intCast(h.mem_size))) - off;
        const raw = linux.mmap(m.mem.base + off, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .FIXED = true, .NORESERVE = true }, fd, @intCast(h.mem_off + off));
        if (ok(raw) == null) {
            kvm.why = "the mapping of the snapshot memory";
            return error.Memory;
        }
        ci = e;
    }
    const t2 = kvm.nowNs();

    // The devices of a boot get the state of the snapshot. The vsock
    // device keeps its new context ID.
    var off: usize = 0;
    var vs: VmState = undefined;
    @memcpy(std.mem.asBytes(&vs), st[off..][0..@sizeOf(VmState)]);
    off += @sizeOf(VmState);
    for (m.devices, 0..) |*d, i| {
        var ds: DeviceState = undefined;
        @memcpy(std.mem.asBytes(&ds), st[off..][0..@sizeOf(DeviceState)]);
        off += @sizeOf(DeviceState);
        if (ds.kind != deviceKind(d)) {
            kvm.why = "the devices of the machine are not the ones of the snapshot";
            return error.Setup;
        }
        d.status = ds.status;
        d.dev_sel = ds.dev_sel;
        d.drv_sel = ds.drv_sel;
        d.queue_sel = ds.queue_sel;
        d.int_status = ds.int_status;
        d.driver_features = ds.driver_features;
        if (i != 1) d.config = ds.config;
        // A queue of the file is ready only when its rings pass the
        // checks of a ready queue of the driver.
        for (&d.queues, ds.queues) |*q, o| {
            q.* = .{ .num = @min(o.num, @import("virtio/queue.zig").max_queue), .desc = o.desc, .avail = o.avail, .used = o.used, .last_avail = @truncate(o.last_avail) };
            q.ready = o.ready != 0 and q.valid(m.mem);
        }
    }
    m.uart = vs.uart;
    const t3 = kvm.nowNs();

    const t4 = kvm.nowNs();
    for (m.vcpus) |*v| {
        var cs: VcpuState = undefined;
        // The MSRs of the vCPUs before come between the states.
        if (off + @sizeOf(VcpuState) > st.len) {
            kvm.why = "the state of the snapshot is too short";
            return error.Setup;
        }
        @memcpy(std.mem.asBytes(&cs), st[off..][0..@sizeOf(VcpuState)]);
        off += @sizeOf(VcpuState);
        const nb = @as(usize, cs.nmsrs) * @sizeOf(MsrEntry);
        if (off + nb > st.len) {
            kvm.why = "the state of the snapshot is too short";
            return error.Setup;
        }
        const msrs = try a.alloc(MsrEntry, cs.nmsrs);
        defer a.free(msrs);
        @memcpy(std.mem.sliceAsBytes(msrs), st[off..][0..nb]);
        off += nb;
        _ = try check(ioctl(v.fd, KVM_SET_MP_STATE, @intFromPtr(&cs.mp_state)), "KVM_SET_MP_STATE");
        _ = try check(ioctl(v.fd, KVM_SET_REGS, @intFromPtr(&cs.regs)), "KVM_SET_REGS");
        _ = try check(ioctl(v.fd, KVM_SET_SREGS, @intFromPtr(&cs.sregs)), "KVM_SET_SREGS");
        _ = try check(ioctl(v.fd, KVM_SET_XSAVE, @intFromPtr(&cs.xsave)), "KVM_SET_XSAVE");
        _ = try check(ioctl(v.fd, KVM_SET_XCRS, @intFromPtr(&cs.xcrs)), "KVM_SET_XCRS");
        _ = try check(ioctl(v.fd, KVM_SET_DEBUGREGS, @intFromPtr(&cs.debugregs)), "KVM_SET_DEBUGREGS");
        _ = try check(ioctl(v.fd, KVM_SET_LAPIC, @intFromPtr(&cs.lapic)), "KVM_SET_LAPIC");
        writeMsrs(v.fd, msrs);
        _ = try check(ioctl(v.fd, KVM_SET_VCPU_EVENTS, @intFromPtr(&cs.events)), "KVM_SET_VCPU_EVENTS");
    }
    for (&vs.irqchips) |*c| _ = try check(ioctl(m.vm, KVM_SET_IRQCHIP, @intFromPtr(c)), "KVM_SET_IRQCHIP");
    _ = try check(ioctl(m.vm, KVM_SET_PIT2, @intFromPtr(&vs.pit)), "KVM_SET_PIT2");
    // The clock goes on from the time of the snapshot. KVM_SET_CLOCK
    // accepts no flag of KVM_GET_CLOCK but KVM_CLOCK_REALTIME.
    var clock: Clock = .{ .clock = vs.clock.clock };
    _ = try check(ioctl(m.vm, KVM_SET_CLOCK, @intFromPtr(&clock)), "KVM_SET_CLOCK");
    // The guest learns that it was paused, so its watchdog of soft
    // lockups does not count the time of the snapshot.
    for (m.vcpus) |*v| _ = ioctl(v.fd, KVM_KVMCLOCK_CTRL, 0);

    // vsock: vhost goes on from the saved indices, and the driver gets
    // the transport reset event.
    const d = &m.devices[1];
    if (d.status & virtio.status_driver_ok != 0) {
        m.vs_base = .{ @truncate(vs.vs_base[0]), @truncate(vs.vs_base[1]) };
        if (!kvm.vhostStart(m, d)) {
            kvm.why = "the start of vhost-vsock after the restore";
            return error.Setup;
        }
        transportReset(m, d);
    }
    const t5 = kvm.nowNs();

    m.state.store(.paused, .release);
    const t6 = kvm.nowNs();
    last_restore = .{ .prepare = t1 - t0, .memory = t2 - t1, .devices = t3 - t2, .vcpus = t4 - t3, .state = t5 - t4, .total = t6 - t0 };
}

/// Waits up to `timeout_us` for the guest to take the transport reset
/// of a restore: its driver puts a new buffer in the event queue after
/// it handles the event, and then it has its new context ID. A
/// connection of the host before that gets no answer. Gives true when
/// the guest took it.
pub fn waitReset(m: *Machine, timeout_us: u64) bool {
    if (m.devices.len < 2) return false;
    const q = &m.devices[1].queues[2];
    if (!q.ready) return false;
    const idx_p = m.mem.ptr(u16, q.avail + 2) orelse return false;
    const idx: *u16 = @ptrCast(@alignCast(idx_p));
    const end = kvm.nowNs() + timeout_us * 1000;
    while (@atomicLoad(u16, idx, .acquire) == m.vs_event_idx) {
        if (kvm.nowNs() >= end or m.getState() != .running) return false;
        var ts: linux.timespec = .{ .sec = 0, .nsec = 20_000 };
        _ = linux.nanosleep(&ts, null);
    }
    return true;
}

/// Puts the event VIRTIO_VSOCK_EVENT_TRANSPORT_RESET (id 0) in a buffer of
/// the event queue (queue 2) of the vsock device and raises its
/// interrupt.
fn transportReset(m: *Machine, d: *virtio.Device) void {
    const q = &d.queues[2];
    const mem = m.mem;
    if (mem.ptr(u16, q.avail + 2)) |p| m.vs_event_idx = p.*;
    const head = q.next(mem) orelse return;
    const c = virtio.Chain.read(q, mem, head) orelse return;
    for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
        if (!w or b.len < 4) continue;
        std.mem.writeInt(u32, b[0..4], 0, .little);
        q.putUsed(mem, head, 4);
        d.int_status |= virtio.int_vring;
        kvm.irqEdge(m, d.irq);
        return;
    }
}

test "kvm snapshot: the sizes of the KVM structs" {
    try std.testing.expectEqual(520, @sizeOf(Irqchip));
    try std.testing.expectEqual(48, @sizeOf(Clock));
    try std.testing.expectEqual(16, @sizeOf(MsrEntry));
    try std.testing.expect(@sizeOf(Header) <= header_size);
}

test "kvm snapshot: a zero page" {
    var p: [4096]u8 align(64) = @splat(0);
    try std.testing.expect(zeroPage(&p));
    p[4095] = 1;
    try std.testing.expect(!zeroPage(&p));
}

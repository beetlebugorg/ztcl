//! A small virtual machine monitor on the KVM ioctls of Linux, for
//! `ztcl::vm` (ztcl#203). It boots an x86-64 Linux guest and gives it
//! its devices on virtio-mmio. The sources are the KVM API document of
//! the kernel (Documentation/virt/kvm/api.rst) and the virtio 1.2
//! specification of OASIS.
//!
//! The guest memory is one anonymous mapping with `MAP_NORESERVE`, so the
//! host gives a page only when the guest touches it. `vm/boot.zig`, the
//! direct boot that the Windows Hypervisor Platform monitor uses too,
//! loads the kernel and the initramfs and writes the boot parameters, the
//! command line, the GDT, the page tables, and the MP table; its header
//! has the layout of the guest memory.
//!
//! The vCPUs start in 64-bit mode at the 64-bit entry point of the boot
//! protocol (the load address + 0x200 for a bzImage, the ELF entry for a
//! vmlinux), with RSI at the boot parameters.
//!
//! KVM has the interrupt controllers (`KVM_CREATE_IRQCHIP`) and the PIT.
//! Each virtio device is a 4 KB window at 0xd0000000 + 0x1000 * n with
//! ISA interrupt `irqs[n]`, given to the guest on the command line
//! (`virtio_mmio.device=`). The transport and the devices that run in
//! ztcl are the shared ones of `vm/virtio/mmio.zig`; this file is their
//! `Host` (the guest memory, and `KVM_IRQ_LINE` for an interrupt). The
//! devices:
//!
//! - The console (virtio ID 3): the transmit queue goes to the console
//!   descriptor, and a thread puts the bytes of that descriptor in the
//!   receive queue.
//! - vsock (ID 19): an external device, vhost-vsock of the host kernel
//!   through `/dev/vhost-vsock`. An ioeventfd on the notify register
//!   kicks vhost, and an irqfd gives its interrupts to the guest, so the
//!   data of a vsock connection does not pass through this process.
//! - Block devices (ID 2): `pread` and `pwrite` on the descriptor of the
//!   disk.
//! - 9p (ID 9), after the disks: a share with the tag `share<n>`, a
//!   server of 9P2000.L (`vm/virtio/ninep.zig`) on the files of its root
//!   folder (`vm/share_linux.zig`).
//! - Entropy (ID 4), last, with `-entropy 1`: bytes of `getrandom`.
//!
//! An access of a vCPU to a register of a device exits `KVM_RUN` on that
//! vCPU thread, and the thread runs the device code. The register
//! InterruptACK of vsock has no state, so a write of the guest to it goes
//! to an ioeventfd with no reader, and each vsock interrupt has one exit
//! to this process less.
//!
//! An 8250 UART at port 0x3f8 writes the output of the guest kernel
//! (`console=ttyS0`) to the console descriptor too. A write of 0xfe to
//! port 0x64 (the reset of the keyboard controller, `reboot=k`) or a
//! triple fault stops the guest.
//!
//! Pause: the host sets `want` to pause, sets `immediate_exit` of each
//! vCPU, and sends each vCPU thread the signal `kick_signal`, so that
//! `KVM_RUN` returns. Each thread waits on a futex until the host sets
//! `want` back.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

/// The stack of a vCPU thread and of the console thread. With glibc, the
/// stack of a new thread also holds the static TLS of the program, and
/// pthread_create gives EINVAL when the TLS does not fit. An embedder
/// with a large TLS (dockyard: 266 KB) needs more than 256 KB. The pages
/// that a thread does not touch take no memory.
pub const thread_stack = 2 * 1024 * 1024;
const builtin = @import("builtin");
const linux = std.os.linux;
const IOCTL = linux.IOCTL;

pub const supported = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64;

/// Snapshots, restores, and clones of a machine (ztcl#468).
pub const snapshot = @import("vm/kvm_snapshot.zig");

// The ioctls of /dev/kvm (KVMIO is 0xAE).
pub const KVMIO = 0xAE;
const KVM_GET_API_VERSION = IOCTL.IO(KVMIO, 0x00);
const KVM_CREATE_VM = IOCTL.IO(KVMIO, 0x01);
const KVM_GET_VCPU_MMAP_SIZE = IOCTL.IO(KVMIO, 0x04);
const KVM_GET_SUPPORTED_CPUID = IOCTL.IOWR(KVMIO, 0x05, Cpuid2);
const KVM_CREATE_VCPU = IOCTL.IO(KVMIO, 0x41);
const KVM_SET_USER_MEMORY_REGION = IOCTL.IOW(KVMIO, 0x46, MemoryRegion);
const KVM_SET_TSS_ADDR = IOCTL.IO(KVMIO, 0x47);
const KVM_CREATE_IRQCHIP = IOCTL.IO(KVMIO, 0x60);
const KVM_IRQ_LINE = IOCTL.IOW(KVMIO, 0x61, IrqLevel);
const KVM_IRQFD = IOCTL.IOW(KVMIO, 0x76, Irqfd);
const KVM_CREATE_PIT2 = IOCTL.IOW(KVMIO, 0x77, PitConfig);
const KVM_IOEVENTFD = IOCTL.IOW(KVMIO, 0x79, Ioeventfd);
const KVM_RUN = IOCTL.IO(KVMIO, 0x80);
const KVM_SET_REGS = IOCTL.IOW(KVMIO, 0x82, Regs);
const KVM_GET_SREGS = IOCTL.IOR(KVMIO, 0x83, Sregs);
const KVM_SET_SREGS = IOCTL.IOW(KVMIO, 0x84, Sregs);
const KVM_GET_MSRS = IOCTL.IOWR(KVMIO, 0x88, MsrsHead);
const KVM_SET_MSRS = IOCTL.IOW(KVMIO, 0x89, MsrsHead);
const KVM_SET_CPUID2 = IOCTL.IOW(KVMIO, 0x90, Cpuid2);

// The ioctls of /dev/vhost-vsock (VHOST_VIRTIO is 0xAF).
pub const VHOST = 0xAF;
const VHOST_GET_FEATURES = IOCTL.IOR(VHOST, 0x00, u64);
const VHOST_SET_FEATURES = IOCTL.IOW(VHOST, 0x00, u64);
const VHOST_SET_OWNER = IOCTL.IO(VHOST, 0x01);
const VHOST_SET_MEM_TABLE = IOCTL.IOW(VHOST, 0x03, VhostMemory);
const VHOST_SET_VRING_NUM = IOCTL.IOW(VHOST, 0x10, VringState);
const VHOST_SET_VRING_ADDR = IOCTL.IOW(VHOST, 0x11, VringAddr);
const VHOST_SET_VRING_BASE = IOCTL.IOW(VHOST, 0x12, VringState);
const VHOST_SET_VRING_KICK = IOCTL.IOW(VHOST, 0x20, VringFile);
const VHOST_SET_VRING_CALL = IOCTL.IOW(VHOST, 0x21, VringFile);
const VHOST_VSOCK_SET_GUEST_CID = IOCTL.IOW(VHOST, 0x60, u64);
const VHOST_VSOCK_SET_RUNNING = IOCTL.IOW(VHOST, 0x61, c_int);

const MemoryRegion = extern struct { slot: u32, flags: u32, guest_phys_addr: u64, memory_size: u64, userspace_addr: u64 };
const MsrsHead = extern struct { nmsrs: u32, pad: u32 = 0 };
/// `struct kvm_msrs` with one entry.
const Msr1 = extern struct { head: MsrsHead = .{ .nmsrs = 1 }, index: u32, reserved: u32 = 0, data: u64 = 0 };
/// IA32_MISC_ENABLE and its bit 0, fast strings: with it set, the guest
/// uses `rep movsb` and `rep stosb` for its copies.
const msr_misc_enable = 0x1a0;
const misc_fast_strings: u64 = 1;
pub const huge_page: usize = 2 << 20;
const madv_hugepage = 14;
const madv_dontneed = 4;
const IrqLevel = extern struct { irq: u32, level: u32 };
const Irqfd = extern struct { fd: u32, gsi: u32, flags: u32, resamplefd: u32, pad: [16]u8 = @splat(0) };
const PitConfig = extern struct { flags: u32, pad: [15]u32 = @splat(0) };
const Ioeventfd = extern struct { datamatch: u64, addr: u64, len: u32, fd: i32, flags: u32, pad: [36]u8 = @splat(0) };
const ioeventfd_datamatch: u32 = 1;
const Regs = extern struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    rsp: u64 = 0,
    rbp: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rip: u64 = 0,
    rflags: u64 = 0,
};
const Segment = extern struct { base: u64, limit: u32, selector: u16, type: u8, present: u8, dpl: u8, db: u8, s: u8, l: u8, g: u8, avl: u8, unusable: u8, padding: u8 };
const Dtable = extern struct { base: u64, limit: u16, padding: [3]u16 };
const Sregs = extern struct {
    cs: Segment,
    ds: Segment,
    es: Segment,
    fs: Segment,
    gs: Segment,
    ss: Segment,
    tr: Segment,
    ldt: Segment,
    gdt: Dtable,
    idt: Dtable,
    cr0: u64,
    cr2: u64,
    cr3: u64,
    cr4: u64,
    cr8: u64,
    efer: u64,
    apic_base: u64,
    interrupt_bitmap: [4]u64,
};
const CpuidEntry = extern struct { function: u32, index: u32, flags: u32, eax: u32, ebx: u32, ecx: u32, edx: u32, padding: [3]u32 };
const Cpuid2 = extern struct { nent: u32, padding: u32 };
const max_cpuid = 256;
const CpuidBuf = extern struct { head: Cpuid2, entries: [max_cpuid]CpuidEntry };

const VhostMemory = extern struct { nregions: u32, padding: u32 };
const VhostRegion = extern struct { guest_phys_addr: u64, memory_size: u64, userspace_addr: u64, flags_padding: u64 };
pub const VringState = extern struct { index: u32, num: u32 };
const VringAddr = extern struct { index: u32, flags: u32, desc_user_addr: u64, used_user_addr: u64, avail_user_addr: u64, log_guest_addr: u64 };
const VringFile = extern struct { index: u32, fd: i32 };

// The exits of KVM_RUN that this monitor handles.
const exit_io = 2;
const exit_hlt = 5;
const exit_mmio = 6;
const exit_shutdown = 8;
const exit_fail_entry = 9;
const exit_internal_error = 17;
const exit_system_event = 24;

// Offsets in the mapping of a vCPU (struct kvm_run).
pub const run_immediate_exit = 1;
const run_exit_reason = 8;
const run_union = 32;

// The guest physical layout.
const gdt_addr = boot.gdt_addr;
const zero_page = boot.zero_page;
const pml4_addr = boot.pml4_addr;
const cmdline_max = boot.cmdline_max;
pub const mmio_base: u64 = 0xd0000000;
const mmio_size: u64 = 0x1000;
/// The ISA interrupts of the virtio devices, in order. 3 and 4 are the
/// serial ports, 8 is the clock, and 13 is the FPU.
pub const irqs = [_]u8{ 5, 6, 7, 9, 10, 11, 12, 14, 15 };
pub const max_disks = irqs.len - 3;

/// The signal that kicks a vCPU thread out of `KVM_RUN`. Its handler
/// is empty.
const kick_signal: linux.SIG = @fromBackingInt(@intCast(40));

pub const Disk = struct {
    fd: i32,
    read_only: bool,
};

/// A 9p share: the descriptor of its root folder (`O_PATH`). Share n
/// has the tag `share<n>`.
pub const Share = struct {
    fd: i32,
    read_only: bool,
};

pub const Config = struct {
    cpus: u32 = 1,
    memory_mb: u32 = 256,
    /// The bytes of the kernel: a bzImage or an ELF vmlinux.
    kernel: []const u8,
    initrd: []const u8 = "",
    cmdline: []const u8,
    disks: []const Disk = &.{},
    /// The 9p shares, after the disks.
    shares: []const Share = &.{},
    /// A virtio entropy device, after the disks and the shares.
    entropy: bool = false,
    /// `-net nat`: a virtio-net device, before the balloon, on the NAT of
    /// `vm/nat/engine.zig` with this configuration.
    net: ?nat_engine.Config = null,
    /// The memory balloon with free page reporting, last
    /// (`vm/virtio/balloon.zig`): the host drops each page that the
    /// guest reports as free.
    balloon: bool = true,
    /// The descriptor of the console (a socket): the output of the
    /// guest goes to it, and its input goes to the guest.
    console: i32,
};

pub const Fail = error{ NoKvm, KvmAccess, NoVhost, VhostAccess, Setup, Kernel, Memory, OutOfMemory };

/// The text for an error of `init` or `start`, as the last setup step
/// that failed.
pub threadlocal var why: []const u8 = "";

pub fn ok(rc: usize) ?usize {
    return if (linux.errno(rc) == .SUCCESS) rc else null;
}

pub fn check(rc: usize, what: []const u8) Fail!usize {
    return ok(rc) orelse {
        why = what;
        return error.Setup;
    };
}

pub fn ioctl(fd: i32, req: u32, arg: usize) usize {
    return linux.ioctl(fd, req, arg);
}

fn openDev(path: [*:0]const u8) usize {
    return linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
}

var probed = std.atomic.Value(bool).init(false);

/// Checks that this host can run a guest: `/dev/kvm` and
/// `/dev/vhost-vsock` open for reading and writing.
pub fn probe() Fail!void {
    // The open and the close of the two devices cost time at each
    // create, so one good probe is enough for the process.
    if (probed.load(.acquire)) return;
    const k = openDev("/dev/kvm");
    switch (linux.errno(k)) {
        .SUCCESS => _ = linux.close(@intCast(k)),
        .ACCES, .PERM => return error.KvmAccess,
        else => return error.NoKvm,
    }
    const v = openDev("/dev/vhost-vsock");
    switch (linux.errno(v)) {
        .SUCCESS => _ = linux.close(@intCast(v)),
        .ACCES, .PERM => return error.VhostAccess,
        else => return error.NoVhost,
    }
    probed.store(true, .release);
}

pub fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const virtio = @import("vm/virtio/mmio.zig");
const boot = @import("vm/boot.zig");
const ninep = @import("vm/virtio/ninep.zig");
const share_linux = @import("vm/share_linux.zig");
const vnet = @import("vm/virtio/net.zig");
const nat_engine = @import("vm/nat/engine.zig");
const nat_stack = @import("vm/nat/nat.zig");

const NinepState = struct {
    share: share_linux.Share,
    server: ninep.Server,
};
const Mem = virtio.Mem;
const Device = virtio.Device;
const virtio_f_version_1 = virtio.f_version_1;

const Machine = @This();

// ---------------------------------------------------------------------
// The machine

pub const State = enum(u32) { created, running, paused, stopped, failed };
const want_run = 0;
pub const want_pause = 1;
const want_stop = 2;

pub const Vcpu = struct {
    fd: i32 = -1,
    run: [*]u8 = undefined,
    run_size: usize = 0,
    tid: std.atomic.Value(i32) = .init(0),
    thread: ?std.Thread = null,
    machine: *Machine = undefined,
    index: u32 = 0,
};

alloc: std.mem.Allocator,
cfg: Config,
kvm: i32 = -1,
vm: i32 = -1,
vhost: i32 = -1,
cid: u64 = 0,
mem: Mem = .{ .base = undefined, .size = 0 },
vcpus: []Vcpu = &.{},
devices: []Device = &.{},
/// The host mapping that holds the guest memory, with room for the
/// alignment to 2 MB.
mem_map: struct { addr: usize = 0, len: usize = 0 } = .{},
/// The 9p servers of the shares.
ninep_state: []NinepState = &.{},
want: std.atomic.Value(u32) = .init(want_run),
parked: std.atomic.Value(u32) = .init(0),
state: std.atomic.Value(State) = .init(.created),
/// The console thread: its stop eventfd, and an eventfd that the vCPU
/// threads write when the driver adds receive buffers.
con_thread: ?std.Thread = null,
con_stop: i32 = -1,
con_wake: i32 = -1,
con_pending: [4096]u8 = undefined,
con_pending_len: usize = 0,
/// The UART registers.
uart: [8]u8 = @splat(0),
uart_lock: virtio.Lock = .{},
/// The time of each phase of the last start, in ns.
times: struct { setup: u64 = 0, load: u64 = 0 } = .{},
/// vsock: the eventfds of the kick and the call of queues 0 and 1.
vs_kick: [2]i32 = .{ -1, -1 },
vs_call: [2]i32 = .{ -1, -1 },
vs_running: bool = false,
/// The first index of the available ring of vsock queues 0 and 1 for
/// vhost: 0 at a boot, and the saved index after a restore.
vs_base: [2]u16 = .{ 0, 0 },
/// The ioeventfd of InterruptACK of vsock.
vs_ack: i32 = -1,
/// `-net nat`: the device, its engine, and the ioeventfds of the
/// notify of its receive and transmit queues. The engine thread runs
/// both queues; `net_in_tx` is true while it holds the lock of the
/// device for the transmit queue, so a frame for the guest in that
/// time needs no second lock.
net: vnet.Net = undefined,
nat: ?*nat_engine.Nat = null,
net_kick: [2]i32 = .{ -1, -1 },
net_in_tx: bool = false,
/// The available index of the vsock event queue when a restore put the
/// transport reset in it (`snapshot.waitReset`).
vs_event_idx: u16 = 0,
/// A machine of `snapshot.prepare`, ready for a restore.
snap_ready: bool = false,
/// The bytes of the free page reports of the guest.
reported: std.atomic.Value(u64) = .init(0),
/// The text of a failure of a vCPU.
fail_text: []const u8 = "",
/// The guest address of the 64-bit entry point of the kernel.
entry: u64 = 0,

/// Makes a machine of the configuration. The machine uses the bytes of
/// `cfg` with no copy, so the caller keeps them until `deinit`.
pub fn init(alloc: std.mem.Allocator, cfg: Config) Fail!*Machine {
    try probe();
    if (cfg.disks.len + cfg.shares.len + @intFromBool(cfg.net != null) > max_disks) {
        why = "too many disks and shares";
        return error.Setup;
    }
    const m = try alloc.create(Machine);
    m.* = .{ .alloc = alloc, .cfg = cfg };
    // The balloon takes the last free interrupt, when one is free.
    if (m.deviceCount() > irqs.len) m.cfg.balloon = false;
    if (m.deviceCount() > irqs.len) {
        alloc.destroy(m);
        why = "too many devices for the interrupts of the guest";
        return error.Setup;
    }
    return m;
}

pub fn deinit(m: *Machine) void {
    m.stop();
    m.alloc.destroy(m);
}

pub fn getState(m: *Machine) State {
    return m.state.load(.acquire);
}

/// Boots the guest: makes the VM, maps the memory, loads the kernel,
/// makes the devices, and starts each vCPU thread.
pub fn start(m: *Machine) Fail!void {
    const s = m.getState();
    if (s == .running or s == .paused) return;
    m.teardown();
    m.want.store(want_run, .seq_cst);
    m.parked.store(0, .seq_cst);
    errdefer m.teardown();
    const t0 = nowNs();
    try m.setup();
    const t1 = nowNs();
    try m.load();
    try m.makeDevices();
    try m.makeVcpus();
    m.times = .{ .setup = t1 - t0, .load = nowNs() - t1 };
    m.state.store(.running, .release);
    for (m.vcpus) |*v| v.thread = std.Thread.spawn(.{ .stack_size = thread_stack }, vcpuMain, .{v}) catch {
        why = "no thread for a vCPU";
        return error.Setup;
    };
    m.con_thread = std.Thread.spawn(.{ .stack_size = thread_stack }, consoleMain, .{m}) catch null;
}

/// Stops each vCPU and frees the VM. The machine can start again.
pub fn stop(m: *Machine) void {
    m.teardown();
    if (m.getState() != .created) m.state.store(.stopped, .release);
}

pub fn pause(m: *Machine) void {
    if (m.getState() != .running) return;
    m.want.store(want_pause, .seq_cst);
    m.kickAll();
    const n: u32 = @intCast(m.vcpus.len);
    while (true) {
        const p = m.parked.load(.seq_cst);
        if (p >= n or m.getState() != .running) break;
        _ = linux.futex_4arg(&m.parked.raw, .{ .cmd = .WAIT, .private = true }, p, null);
    }
    if (m.getState() == .running) m.state.store(.paused, .release);
}

pub fn @"resume"(m: *Machine) void {
    if (m.getState() != .paused) return;
    m.state.store(.running, .release);
    m.want.store(want_run, .seq_cst);
    _ = linux.futex_3arg(&m.want.raw, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
}

fn kickAll(m: *Machine) void {
    for (m.vcpus) |*v| {
        if (v.run_size != 0) @atomicStore(u8, &v.run[run_immediate_exit], 1, .seq_cst);
        const tid = v.tid.load(.seq_cst);
        if (tid != 0) _ = linux.tgkill(linux.getpid(), tid, kick_signal);
    }
}

fn closeFd(fd: *i32) void {
    if (fd.* >= 0) _ = linux.close(fd.*);
    fd.* = -1;
}

pub fn teardown(m: *Machine) void {
    m.want.store(want_stop, .seq_cst);
    _ = linux.futex_3arg(&m.want.raw, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
    m.kickAll();
    for (m.vcpus) |*v| if (v.thread) |t| {
        t.join();
        v.thread = null;
    };
    if (m.con_thread) |t| {
        const one: u64 = 1;
        _ = linux.write(m.con_stop, std.mem.asBytes(&one), 8);
        t.join();
        m.con_thread = null;
    }
    if (m.nat) |n| n.deinit();
    m.nat = null;
    for (&m.net_kick) |*f| closeFd(f);
    for (m.vcpus) |*v| {
        if (v.run_size != 0) _ = linux.munmap(v.run, v.run_size);
        closeFd(&v.fd);
    }
    if (m.vcpus.len != 0) m.alloc.free(m.vcpus);
    m.vcpus = &.{};
    for (&m.vs_kick) |*f| closeFd(f);
    for (&m.vs_call) |*f| closeFd(f);
    closeFd(&m.vs_ack);
    m.vs_running = false;
    m.vs_base = .{ 0, 0 };
    if (m.devices.len != 0) m.alloc.free(m.devices);
    m.devices = &.{};
    for (m.ninep_state) |*n| n.server.deinit();
    if (m.ninep_state.len != 0) m.alloc.free(m.ninep_state);
    m.ninep_state = &.{};
    closeFd(&m.vhost);
    closeFd(&m.vm);
    closeFd(&m.kvm);
    closeFd(&m.con_stop);
    closeFd(&m.con_wake);
    m.con_pending_len = 0;
    if (m.mem_map.len != 0) _ = linux.munmap(@ptrFromInt(m.mem_map.addr), m.mem_map.len);
    m.mem_map = .{};
    m.mem = .{ .base = undefined, .size = 0 };
    m.snap_ready = false;
}

var kick_installed = std.atomic.Value(bool).init(false);

fn onKick(_: linux.SIG) callconv(.c) void {}

fn installKick() void {
    if (kick_installed.swap(true, .seq_cst)) return;
    var act: linux.Sigaction = .{ .handler = .{ .handler = onKick }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(kick_signal, &act, null);
}

/// Makes the VM with its interrupt controllers and its PIT, with no
/// memory.
pub fn setupVm(m: *Machine) Fail!void {
    installKick();
    const k = openDev("/dev/kvm");
    m.kvm = @intCast(ok(k) orelse return if (linux.errno(k) == .ACCES) error.KvmAccess else error.NoKvm);
    if (ioctl(m.kvm, KVM_GET_API_VERSION, 0) != 12) {
        why = "KVM_GET_API_VERSION is not 12";
        return error.Setup;
    }
    m.vm = @intCast(try check(ioctl(m.kvm, KVM_CREATE_VM, 0), "KVM_CREATE_VM"));
    _ = try check(ioctl(m.vm, KVM_SET_TSS_ADDR, 0xfffbd000), "KVM_SET_TSS_ADDR");
    _ = try check(ioctl(m.vm, KVM_CREATE_IRQCHIP, 0), "KVM_CREATE_IRQCHIP");
    var pit: PitConfig = .{ .flags = 0 };
    _ = try check(ioctl(m.vm, KVM_CREATE_PIT2, @intFromPtr(&pit)), "KVM_CREATE_PIT2");
}

fn setup(m: *Machine) Fail!void {
    try m.setupVm();
    const size: u64 = @as(u64, m.cfg.memory_mb) << 20;
    // The guest memory starts on a 2 MB boundary and asks for
    // transparent huge pages, so the first write to each 2 MB of the
    // guest is one fault of the host.
    const map_len: usize = @intCast(size + huge_page);
    const raw = linux.mmap(null, map_len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
    if (ok(raw) == null) {
        why = "no host memory for the guest";
        return error.Memory;
    }
    m.mem_map = .{ .addr = raw, .len = map_len };
    const p = std.mem.alignForward(usize, raw, huge_page);
    _ = linux.madvise(@ptrFromInt(p), @intCast(size), madv_hugepage);
    m.mem = .{ .base = @ptrFromInt(p), .size = size };
    var region: MemoryRegion = .{ .slot = 0, .flags = 0, .guest_phys_addr = 0, .memory_size = size, .userspace_addr = p };
    _ = try check(ioctl(m.vm, KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region)), "KVM_SET_USER_MEMORY_REGION");
}

// ---------------------------------------------------------------------
// The boot: the shared direct boot of `vm/boot.zig`

/// The command line of the guest: the one of the configuration, then the
/// options of this monitor and the list of the virtio-mmio devices.
fn cmdline(m: *Machine) []const u8 {
    const S = struct {
        threadlocal var buf: [cmdline_max + 512]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    // The words after " -- " are the arguments of the first process, so
    // the options of the monitor go before them.
    const cut = std.mem.indexOf(u8, m.cfg.cmdline, " -- ");
    const head = if (cut) |c| m.cfg.cmdline[0..c] else m.cfg.cmdline;
    w.print("{s} reboot=k panic=-1 nomodule", .{head}) catch return S.buf[0..0];
    for (0..m.deviceCount()) |i| w.print(" virtio_mmio.device=4K@0x{x}:{d}", .{ mmio_base + mmio_size * i, irqs[i] }) catch return w.buffered();
    if (cut) |c| w.print("{s}", .{m.cfg.cmdline[c..]}) catch return w.buffered();
    return w.buffered();
}

fn load(m: *Machine) Fail!void {
    m.entry = boot.load(m.mem, .{ .kernel = m.cfg.kernel, .initrd = m.cfg.initrd, .cmdline = m.cmdline(), .cpus = m.cfg.cpus }) catch {
        why = boot.why;
        return error.Kernel;
    };
}

pub fn makeVcpus(m: *Machine) Fail!void {
    const run_size = try check(ioctl(m.kvm, KVM_GET_VCPU_MMAP_SIZE, 0), "KVM_GET_VCPU_MMAP_SIZE");
    var cpuid: CpuidBuf = undefined;
    cpuid.head = .{ .nent = max_cpuid, .padding = 0 };
    _ = try check(ioctl(m.kvm, KVM_GET_SUPPORTED_CPUID, @intFromPtr(&cpuid)), "KVM_GET_SUPPORTED_CPUID");
    m.vcpus = try m.alloc.alloc(Vcpu, m.cfg.cpus);
    for (m.vcpus) |*v| v.* = .{};
    for (m.vcpus, 0..) |*v, i| {
        v.machine = m;
        v.index = @intCast(i);
        v.fd = @intCast(try check(ioctl(m.vm, KVM_CREATE_VCPU, i), "KVM_CREATE_VCPU"));
        const p = linux.mmap(null, run_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, v.fd, 0);
        v.run = @ptrFromInt(try check(p, "the mapping of a vCPU"));
        v.run_size = run_size;

        // CPUID: the leaves of KVM, with the APIC ID of this vCPU.
        var c = cpuid;
        for (c.entries[0..c.head.nent]) |*e| switch (e.function) {
            1 => {
                e.ebx = (e.ebx & 0x00ffffff) | (@as(u32, @intCast(i)) << 24);
                e.ecx |= 1 << 31; // a hypervisor
            },
            0xb, 0x1f => e.edx = @intCast(i),
            else => {},
        };
        _ = try check(ioctl(v.fd, KVM_SET_CPUID2, @intFromPtr(&c)), "KVM_SET_CPUID2");

        // KVM gives IA32_MISC_ENABLE with fast strings off.
        var msr: Msr1 = .{ .index = msr_misc_enable };
        if (ioctl(v.fd, KVM_GET_MSRS, @intFromPtr(&msr)) == 1) {
            msr.data |= misc_fast_strings;
            _ = ioctl(v.fd, KVM_SET_MSRS, @intFromPtr(&msr));
        }

        if (i != 0) continue;
        // The boot CPU starts in 64-bit mode; the others wait for the
        // startup IPI of the guest.
        var sregs: Sregs = undefined;
        _ = try check(ioctl(v.fd, KVM_GET_SREGS, @intFromPtr(&sregs)), "KVM_GET_SREGS");
        const code: Segment = .{ .base = 0, .limit = 0xffffffff, .selector = 0x10, .type = 11, .present = 1, .dpl = 0, .db = 0, .s = 1, .l = 1, .g = 1, .avl = 0, .unusable = 0, .padding = 0 };
        var data = code;
        data.selector = 0x18;
        data.type = 3;
        data.l = 0;
        data.db = 1;
        sregs.cs = code;
        sregs.ds = data;
        sregs.es = data;
        sregs.fs = data;
        sregs.gs = data;
        sregs.ss = data;
        sregs.gdt = .{ .base = gdt_addr, .limit = 31, .padding = @splat(0) };
        sregs.cr3 = pml4_addr;
        sregs.cr4 = 1 << 5; // PAE
        sregs.cr0 = (1 << 0) | (1 << 4) | (1 << 31); // PE, ET, PG
        sregs.efer = (1 << 8) | (1 << 10); // LME, LMA
        _ = try check(ioctl(v.fd, KVM_SET_SREGS, @intFromPtr(&sregs)), "KVM_SET_SREGS");
        var regs: Regs = .{ .rip = m.entry, .rsi = zero_page, .rflags = 2, .rsp = 0x8ff0 };
        _ = try check(ioctl(v.fd, KVM_SET_REGS, @intFromPtr(&regs)), "KVM_SET_REGS");
    }
}

// ---------------------------------------------------------------------
// The devices

fn eventfd() Fail!i32 {
    return @intCast(try check(linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK), "eventfd"));
}

pub fn deviceCount(m: *const Machine) usize {
    return 2 + m.cfg.disks.len + m.cfg.shares.len + @intFromBool(m.cfg.entropy) + @intFromBool(m.cfg.net != null) + @intFromBool(m.cfg.balloon);
}

fn entropyIndex(m: *const Machine) usize {
    return 2 + m.cfg.disks.len + m.cfg.shares.len;
}

pub fn makeDevices(m: *Machine) Fail!void {
    const n = m.deviceCount();
    m.devices = try m.alloc.alloc(Device, n);
    m.devices[0] = Device.console(irqs[0], .{ .ctx = m, .write = consoleWrite, .rx_ready = consoleReady });
    for (m.cfg.disks, 0..) |*d, i| {
        const size = linux.lseek(d.fd, 0, linux.SEEK.END);
        if (@as(i64, @bitCast(size)) < 0) {
            why = "the size of a disk";
            return error.Setup;
        }
        m.devices[2 + i] = Device.blk(irqs[2 + i], .{ .ctx = @constCast(d), .size = size, .read_only = d.read_only, .read = diskRead, .write = diskWrite, .flush = diskFlush });
    }
    // The 9p servers run on the vCPU threads, so they use an allocator
    // that is safe across threads.
    m.ninep_state = try m.alloc.alloc(NinepState, m.cfg.shares.len);
    for (m.cfg.shares, m.ninep_state, 0..) |sh, *st, i| {
        st.share = .{ .root = sh.fd, .read_only = sh.read_only };
        st.server = ninep.Server.init(std.heap.smp_allocator, st.share.fs());
        var tag_buf: [16]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "share{d}", .{i}) catch unreachable;
        const k = 2 + m.cfg.disks.len + i;
        m.devices[k] = Device.ninep(irqs[k], &st.server, tag);
    }
    if (m.cfg.entropy) m.devices[m.entropyIndex()] = Device.rng(irqs[m.entropyIndex()], fillRandom);
    if (m.cfg.net) |nc| try m.makeNet(n - 1 - @intFromBool(m.cfg.balloon), nc);
    if (m.cfg.balloon) m.devices[n - 1] = Device.balloon(irqs[n - 1], .{ .ctx = m, .report = dropPages });
    m.con_stop = try eventfd();
    m.con_wake = try eventfd();

    // vsock: vhost-vsock with a free context ID, and the eventfds of
    // its two queues.
    const v = openDev("/dev/vhost-vsock");
    m.vhost = @intCast(ok(v) orelse return if (linux.errno(v) == .ACCES) error.VhostAccess else error.NoVhost);
    _ = try check(ioctl(m.vhost, VHOST_SET_OWNER, 0), "VHOST_SET_OWNER");
    var feats: u64 = 0;
    _ = try check(ioctl(m.vhost, VHOST_GET_FEATURES, @intFromPtr(&feats)), "VHOST_GET_FEATURES");
    if (feats & virtio_f_version_1 == 0) {
        why = "vhost-vsock has no VIRTIO_F_VERSION_1";
        return error.Setup;
    }
    var seed: u32 = undefined;
    _ = linux.getrandom(std.mem.asBytes(&seed).ptr, 4, 0);
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        var cid: u64 = 3 + @as(u64, (seed +% tries *% 2654435761) % 0x7ffffff0);
        const rc = ioctl(m.vhost, VHOST_VSOCK_SET_GUEST_CID, @intFromPtr(&cid));
        if (ok(rc) != null) {
            m.cid = cid;
            break;
        }
        if (linux.errno(rc) != .ADDRINUSE or tries > 64) {
            why = "VHOST_VSOCK_SET_GUEST_CID";
            return error.Setup;
        }
    }
    var config: [8]u8 = undefined;
    std.mem.writeInt(u64, &config, m.cid, .little);
    m.devices[1] = Device.external(irqs[1], .{ .id = 19, .ctx = m, .driverOk = vhostStart, .reset = vhostStop }, virtio_f_version_1, 3, &config);
    for (0..2) |q| {
        m.vs_kick[q] = try eventfd();
        m.vs_call[q] = try eventfd();
        var io: Ioeventfd = .{ .datamatch = q, .addr = mmio_base + mmio_size * 1 + 0x50, .len = 4, .fd = m.vs_kick[q], .flags = ioeventfd_datamatch };
        _ = try check(ioctl(m.vm, KVM_IOEVENTFD, @intFromPtr(&io)), "KVM_IOEVENTFD");
        var irq: Irqfd = .{ .fd = @intCast(m.vs_call[q]), .gsi = irqs[1], .flags = 0, .resamplefd = 0 };
        _ = try check(ioctl(m.vm, KVM_IRQFD, @intFromPtr(&irq)), "KVM_IRQFD");
    }
    m.vs_ack = try eventfd();
    var ack: Ioeventfd = .{ .datamatch = 0, .addr = mmio_base + mmio_size * 1 + 0x64, .len = 4, .fd = m.vs_ack, .flags = 0 };
    _ = try check(ioctl(m.vm, KVM_IOEVENTFD, @intFromPtr(&ack)), "KVM_IOEVENTFD");
}

/// The virtio-net device at index `k` and its NAT engine. The notify of
/// each queue goes to an ioeventfd that the engine thread waits on, so
/// a notify of the guest costs no exit to user space.
fn makeNet(m: *Machine, k: usize, nc: nat_engine.Config) Fail!void {
    // TSO both ways: the guest sends TCP segments of up to 64 KB, and
    // the engine sends it frames of up to 64 KB.
    m.net = .{ .mac = nat_stack.guest_mac, .ctx = m, .kick = netKick, .offloads = vnet.f_csum | vnet.f_guest_csum | vnet.f_host_tso4 | vnet.f_guest_tso4 };
    m.devices[k] = Device.net(irqs[k], &m.net);
    m.nat = nat_engine.Nat.init(m.alloc, nc, .{ .ctx = m, .deliver = netDeliver, .flush = netFlush, .features = netFeatures }) catch {
        why = "no NAT engine";
        return error.Setup;
    };
    const calls = [2]*const fn (*anyopaque) void{ netRx, netTx };
    for (0..2) |q| {
        m.net_kick[q] = try eventfd();
        var io: Ioeventfd = .{ .datamatch = q, .addr = mmio_base + mmio_size * k + 0x50, .len = 4, .fd = m.net_kick[q], .flags = ioeventfd_datamatch };
        _ = try check(ioctl(m.vm, KVM_IOEVENTFD, @intFromPtr(&io)), "KVM_IOEVENTFD");
        m.nat.?.watch(m.net_kick[q], m, calls[q]) catch {
            why = "the NAT engine";
            return error.Setup;
        };
    }
    m.nat.?.start() catch {
        why = "no thread for the NAT";
        return error.Setup;
    };
}

/// The virtio-net device: last, or before the balloon.
fn netDev(m: *Machine) *Device {
    return &m.devices[m.devices.len - 1 - @intFromBool(m.cfg.balloon)];
}

/// A notify that did not go to an ioeventfd.
fn netKick(ctx: *anyopaque, qi: u32) void {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    if (qi < 2) {
        const one: u64 = 1;
        _ = linux.write(m.net_kick[qi], std.mem.asBytes(&one), 8);
    }
}

fn netTx(ctx: *anyopaque) void {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    const d = m.netDev();
    const h = m.host();
    d.lock.lock();
    defer d.lock.unlock();
    m.net_in_tx = true;
    defer m.net_in_tx = false;
    _ = m.net.tx(d, &h, m.nat.?.sink());
}

fn netRx(ctx: *anyopaque) void {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    m.nat.?.rxSpace();
}

fn netDeliver(ctx: *anyopaque, hdr: vnet.Hdr, parts: []const []const u8) bool {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    const d = m.netDev();
    const h = m.host();
    if (!m.net_in_tx) d.lock.lock();
    defer if (!m.net_in_tx) d.lock.unlock();
    while (true) {
        if (m.net.deliver(d, &h, hdr, parts)) return true;
        // No room: ask the driver for a notify when it adds buffers,
        // and try again when it added some in the meantime.
        if (!m.net.rxArm(d, &h)) return false;
    }
}

fn netFeatures(ctx: *anyopaque) u64 {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    return @atomicLoad(u64, &m.netDev().driver_features, .monotonic);
}

fn netFlush(ctx: *anyopaque) void {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    const d = m.netDev();
    const h = m.host();
    if (!m.net_in_tx) d.lock.lock();
    defer if (!m.net_in_tx) d.lock.unlock();
    m.net.rxDone(d, &h);
}

pub fn host(m: *Machine) virtio.Host {
    return .{ .ctx = m, .mem = m.mem, .interrupt = irqEdge };
}

/// An edge on an ISA interrupt line of the guest.
pub fn irqEdge(ctx: *anyopaque, irq: u32) void {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    var hi: IrqLevel = .{ .irq = irq, .level = 1 };
    _ = ioctl(m.vm, KVM_IRQ_LINE, @intFromPtr(&hi));
    var lo: IrqLevel = .{ .irq = irq, .level = 0 };
    _ = ioctl(m.vm, KVM_IRQ_LINE, @intFromPtr(&lo));
}

/// Gives vhost the memory and the two queues of vsock, and starts it.
pub fn vhostStart(ctx: *anyopaque, d: *Device) bool {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    const feats: u64 = d.driver_features & virtio_f_version_1;
    if (ok(ioctl(m.vhost, VHOST_SET_FEATURES, @intFromPtr(&feats))) == null) return false;
    var table: extern struct { head: VhostMemory, region: VhostRegion } = .{
        .head = .{ .nregions = 1, .padding = 0 },
        .region = .{ .guest_phys_addr = 0, .memory_size = m.mem.size, .userspace_addr = @intFromPtr(m.mem.base), .flags_padding = 0 },
    };
    if (ok(ioctl(m.vhost, VHOST_SET_MEM_TABLE, @intFromPtr(&table))) == null) return false;
    const base = @intFromPtr(m.mem.base);
    for (0..2) |i| {
        const q = &d.queues[i];
        if (!q.ready) return false;
        const idx: u32 = @intCast(i);
        var num: VringState = .{ .index = idx, .num = q.num };
        var start_at: VringState = .{ .index = idx, .num = m.vs_base[i] };
        var addr: VringAddr = .{ .index = idx, .flags = 0, .desc_user_addr = base + q.desc, .used_user_addr = base + q.used, .avail_user_addr = base + q.avail, .log_guest_addr = 0 };
        var kick: VringFile = .{ .index = idx, .fd = m.vs_kick[i] };
        var call: VringFile = .{ .index = idx, .fd = m.vs_call[i] };
        if (ok(ioctl(m.vhost, VHOST_SET_VRING_NUM, @intFromPtr(&num))) == null) return false;
        if (ok(ioctl(m.vhost, VHOST_SET_VRING_BASE, @intFromPtr(&start_at))) == null) return false;
        if (ok(ioctl(m.vhost, VHOST_SET_VRING_ADDR, @intFromPtr(&addr))) == null) return false;
        if (ok(ioctl(m.vhost, VHOST_SET_VRING_KICK, @intFromPtr(&kick))) == null) return false;
        if (ok(ioctl(m.vhost, VHOST_SET_VRING_CALL, @intFromPtr(&call))) == null) return false;
    }
    var on: c_int = 1;
    if (ok(ioctl(m.vhost, VHOST_VSOCK_SET_RUNNING, @intFromPtr(&on))) == null) return false;
    m.vs_running = true;
    return true;
}

fn vhostStop(ctx: *anyopaque, _: *Device) void {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    if (!m.vs_running) return;
    var off: c_int = 0;
    _ = ioctl(m.vhost, VHOST_VSOCK_SET_RUNNING, @intFromPtr(&off));
    m.vs_running = false;
}

fn consoleWrite(ctx: *anyopaque, bytes: []const u8) void {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    writeAll(m.cfg.console, bytes);
}

/// The driver added receive buffers: the console thread pushes its
/// pending input.
fn consoleReady(ctx: *anyopaque) void {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    const one: u64 = 1;
    _ = linux.write(m.con_wake, std.mem.asBytes(&one), 8);
}

fn writeAll(fd: i32, b: []const u8) void {
    var off: usize = 0;
    while (off < b.len) {
        const rc = linux.write(fd, b[off..].ptr, b.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            else => return,
        }
    }
}

/// Puts the pending input of the console in the receive queue.
fn consoleRx(m: *Machine) void {
    const d = &m.devices[0];
    const h = m.host();
    d.lock.lock();
    const took = virtio.Console.push(d, &h, m.con_pending[0..m.con_pending_len]);
    d.lock.unlock();
    std.mem.copyForwards(u8, m.con_pending[0 .. m.con_pending_len - took], m.con_pending[took..m.con_pending_len]);
    m.con_pending_len -= took;
}

/// The console thread: reads the console descriptor into the receive
/// queue of the console device.
pub fn consoleMain(m: *Machine) void {
    while (true) {
        var fds = [_]linux.pollfd{
            .{ .fd = m.con_stop, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = m.con_wake, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = if (m.con_pending_len == 0) m.cfg.console else -1, .events = linux.POLL.IN, .revents = 0 },
        };
        const rc = linux.poll(&fds, fds.len, -1);
        if (ok(rc) == null) continue;
        if (fds[0].revents != 0) return;
        var junk: u64 = 0;
        if (fds[1].revents != 0) _ = linux.read(m.con_wake, std.mem.asBytes(&junk), 8);
        if (fds[2].revents & linux.POLL.IN != 0) {
            const n = linux.read(m.cfg.console, &m.con_pending, m.con_pending.len);
            if (ok(n)) |k| {
                if (k == 0) return m.waitStop();
                m.con_pending_len = k;
            }
        } else if (fds[2].revents != 0) return m.waitStop();
        if (m.con_pending_len != 0 and m.devices[0].status & virtio.status_driver_ok != 0) m.consoleRx();
    }
}

/// The script closed its end of the console: waits only for the stop.
fn waitStop(m: *Machine) void {
    var stop_fd = [_]linux.pollfd{.{ .fd = m.con_stop, .events = linux.POLL.IN, .revents = 0 }};
    _ = linux.poll(&stop_fd, 1, -1);
}

/// A range of free memory that the guest reported: its host pages go
/// back to the host. The range of a guest is on 4 KB boundaries.
fn dropPages(ctx: *anyopaque, range: []u8) void {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    _ = m.reported.fetchAdd(range.len, .monotonic);
    const lo = std.mem.alignForward(usize, @intFromPtr(range.ptr), 4096);
    const hi = std.mem.alignBackward(usize, @intFromPtr(range.ptr) + range.len, 4096);
    if (hi > lo) _ = linux.madvise(@ptrFromInt(lo), hi - lo, madv_dontneed);
}

fn fillRandom(buf: []u8) usize {
    const rc = linux.getrandom(buf.ptr, buf.len, 0);
    return ok(rc) orelse 0;
}

fn diskRead(ctx: *anyopaque, buf: []u8, off: u64) bool {
    const d: *const Disk = @ptrCast(@alignCast(ctx));
    return fullIo(d.fd, buf, off, false);
}

fn diskWrite(ctx: *anyopaque, buf: []const u8, off: u64) bool {
    const d: *const Disk = @ptrCast(@alignCast(ctx));
    return fullIo(d.fd, @constCast(buf), off, true);
}

fn diskFlush(ctx: *anyopaque) void {
    const d: *const Disk = @ptrCast(@alignCast(ctx));
    _ = linux.fsync(d.fd);
}

fn fullIo(fd: i32, b: []u8, pos: u64, write: bool) bool {
    var off: usize = 0;
    while (off < b.len) {
        const at: i64 = @intCast(pos + off);
        const rc = if (write) linux.pwrite(fd, b[off..].ptr, b.len - off, at) else linux.pread(fd, b[off..].ptr, b.len - off, at);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) {
                    if (write) return false;
                    @memset(b[off..], 0);
                    return true;
                }
                off += rc;
            },
            .INTR => continue,
            else => return false,
        }
    }
    return true;
}

// ---------------------------------------------------------------------
// The vCPU threads

pub fn vcpuMain(v: *Vcpu) void {
    const m = v.machine;
    v.tid.store(linux.gettid(), .seq_cst);
    defer v.tid.store(0, .seq_cst);
    while (true) {
        const w = m.want.load(.seq_cst);
        if (w == want_stop) return;
        if (w == want_pause) {
            // KVM_RUN with immediate_exit completes the I/O of the last
            // exit and returns at once, so a snapshot of the parked vCPU
            // has no pending operation.
            @atomicStore(u8, &v.run[run_immediate_exit], 1, .seq_cst);
            _ = ioctl(v.fd, KVM_RUN, 0);
            _ = m.parked.fetchAdd(1, .seq_cst);
            _ = linux.futex_3arg(&m.parked.raw, .{ .cmd = .WAKE, .private = true }, 1);
            while (m.want.load(.seq_cst) == want_pause)
                _ = linux.futex_4arg(&m.want.raw, .{ .cmd = .WAIT, .private = true }, want_pause, null);
            _ = m.parked.fetchSub(1, .seq_cst);
            continue;
        }
        @atomicStore(u8, &v.run[run_immediate_exit], 0, .seq_cst);
        if (m.want.load(.seq_cst) != want_run) continue;
        const rc = ioctl(v.fd, KVM_RUN, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR, .AGAIN => continue,
            else => return m.guestEnd("KVM_RUN failed"),
        }
        const reason = std.mem.readInt(u32, v.run[run_exit_reason..][0..4], .little);
        switch (reason) {
            exit_io => m.portIo(v),
            exit_mmio => m.mmio(v),
            exit_hlt, exit_shutdown, exit_system_event => return m.guestEnd(""),
            exit_fail_entry => return m.guestEnd("the entry to the guest failed"),
            exit_internal_error => return m.guestEnd("an internal error of KVM"),
            else => {},
        }
    }
}

/// The guest stopped by itself (`text` is empty) or failed: each vCPU
/// thread ends.
fn guestEnd(m: *Machine, text: []const u8) void {
    if (m.want.cmpxchgStrong(want_run, want_stop, .seq_cst, .seq_cst) != null and
        m.want.cmpxchgStrong(want_pause, want_stop, .seq_cst, .seq_cst) != null) return;
    m.fail_text = text;
    m.state.store(if (text.len == 0) .stopped else .failed, .release);
    _ = linux.futex_3arg(&m.want.raw, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
    _ = linux.futex_3arg(&m.parked.raw, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
    m.kickAll();
}

fn portIo(m: *Machine, v: *Vcpu) void {
    const u = v.run[run_union..];
    const out = u[0] == 1;
    const size = u[1];
    const port = std.mem.readInt(u16, u[2..4], .little);
    const count = std.mem.readInt(u32, u[4..8], .little);
    const data_off = std.mem.readInt(u64, u[8..16], .little);
    const total = @as(u64, size) * count;
    if (data_off > v.run_size or total > v.run_size - data_off) return;
    const data = v.run[@intCast(data_off)..][0..@intCast(total)];
    if (port == 0x64 and out and size == 1 and data[0] == 0xfe) return m.guestEnd("");
    if (port >= 0x3f8 and port < 0x400 and size == 1) {
        m.uart_lock.lock();
        defer m.uart_lock.unlock();
        const r: usize = port - 0x3f8;
        for (data) |*b| m.uartIo(r, out, b);
        return;
    }
    if (!out) @memset(data, 0xff);
}

/// The 8250 UART: the output goes to the console, and the status says
/// that the transmitter is empty and no input waits.
fn uartIo(m: *Machine, r: usize, out: bool, b: *u8) void {
    const dlab = m.uart[3] & 0x80 != 0;
    if (out) {
        if (r == 0 and !dlab) return writeAll(m.cfg.console, b[0..1]);
        m.uart[r] = b.*;
        return;
    }
    b.* = switch (r) {
        0 => if (dlab) m.uart[0] else 0,
        2 => 0x01, // IIR: no interrupt
        5 => 0x60, // LSR: the transmitter is empty
        6 => 0xb0, // MSR: DCD, DSR, CTS
        else => m.uart[r],
    };
}

fn mmio(m: *Machine, v: *Vcpu) void {
    const u = v.run[run_union..];
    const addr = std.mem.readInt(u64, u[0..8], .little);
    const len = std.mem.readInt(u32, u[16..20], .little);
    const write = u[20] != 0;
    const data = u[8..16];
    if (len > 8) return;
    if (addr < mmio_base or addr >= mmio_base + mmio_size * m.devices.len) {
        if (!write) @memset(data[0..len], 0xff);
        return;
    }
    const d = &m.devices[@intCast((addr - mmio_base) / mmio_size)];
    const off = (addr - mmio_base) % mmio_size;
    const h = m.host();
    d.lock.lock();
    defer d.lock.unlock();
    if (write) d.write(&h, off, data[0..len]) else d.read(off, data[0..len]);
}

test "kvm: the arguments of the first process stay last" {
    if (comptime !supported) return;
    var m: Machine = .{ .alloc = std.testing.allocator, .cfg = .{ .kernel = "", .cmdline = "quiet rdinit=/sbin/ztcl -- --iso-vsock 1026", .console = -1, .balloon = false } };
    try std.testing.expectEqualStrings(
        "quiet rdinit=/sbin/ztcl reboot=k panic=-1 nomodule virtio_mmio.device=4K@0xd0000000:5 virtio_mmio.device=4K@0xd0001000:6 -- --iso-vsock 1026",
        m.cmdline(),
    );
}

test "kvm: the command line" {
    if (comptime !supported) return;
    var m: Machine = .{ .alloc = std.testing.allocator, .cfg = .{ .kernel = "", .cmdline = "console=hvc0", .console = -1, .cpus = 2, .disks = &.{.{ .fd = -1, .read_only = true }} } };
    try std.testing.expectEqualStrings(
        "console=hvc0 reboot=k panic=-1 nomodule virtio_mmio.device=4K@0xd0000000:5 virtio_mmio.device=4K@0xd0001000:6 virtio_mmio.device=4K@0xd0002000:7 virtio_mmio.device=4K@0xd0003000:9",
        m.cmdline(),
    );
}

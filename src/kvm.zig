//! A small virtual machine monitor on the KVM ioctls of Linux, for
//! `ztcl::vm` (ztcl#203). It boots an x86-64 Linux guest and gives it
//! its devices on virtio-mmio. The sources are the KVM API document of
//! the kernel (Documentation/virt/kvm/api.rst), the x86 boot protocol
//! (Documentation/arch/x86/boot.rst and zero-page.rst), the virtio 1.2
//! specification of OASIS, and the Intel MultiProcessor Specification 1.4.
//!
//! The guest memory is one anonymous mapping with `MAP_NORESERVE`, so the
//! host gives a page only when the guest touches it. The layout of the
//! guest physical memory:
//!
//!   0x0500   the GDT: a 64-bit code segment 0x10 and a data segment 0x18
//!   0x7000   the boot parameters (the "zero page")
//!   0x9000   the page tables: an identity map of the first 4 GB in 2 MB pages
//!   0x20000  the kernel command line
//!   0x9fc00  the MP table: the CPUs, the I/O APIC, and the ISA interrupts
//!   0x100000 the kernel: the protected-mode part of a bzImage, or the
//!            segments of an ELF vmlinux at their physical addresses
//!   the top  the initramfs
//!
//! The vCPUs start in 64-bit mode at the 64-bit entry point of the boot
//! protocol (the load address + 0x200 for a bzImage, the ELF entry for a
//! vmlinux), with RSI at the boot parameters.
//!
//! KVM has the interrupt controllers (`KVM_CREATE_IRQCHIP`) and the PIT.
//! Each virtio device is a 4 KB window at 0xd0000000 + 0x1000 * n with
//! ISA interrupt `irqs[n]`, given to the guest on the command line
//! (`virtio_mmio.device=`). The devices:
//!
//! - The console (virtio ID 3): the transmit queue goes to the console
//!   descriptor, and a thread puts the bytes of that descriptor in the
//!   receive queue.
//! - vsock (ID 19): vhost-vsock of the host kernel through
//!   `/dev/vhost-vsock`. An ioeventfd on the notify register kicks
//!   vhost, and an irqfd gives its interrupts to the guest, so the data
//!   of a vsock connection does not pass through this process.
//! - Block devices (ID 2): requests of the vCPU thread, with `pread` and
//!   `pwrite` on the descriptor of the disk.
//! - Entropy (ID 4), last, with `-entropy 1`: bytes of `getrandom`.
//!
//! An access of a vCPU to a register of a device exits `KVM_RUN` on that
//! vCPU thread, and the thread runs the device code. The guest is not
//! trusted: each address and length of the guest is checked against the
//! guest memory before use.
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
const builtin = @import("builtin");
const linux = std.os.linux;
const IOCTL = linux.IOCTL;

pub const supported = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64;

// The ioctls of /dev/kvm (KVMIO is 0xAE).
const KVMIO = 0xAE;
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
const KVM_SET_CPUID2 = IOCTL.IOW(KVMIO, 0x90, Cpuid2);

// The ioctls of /dev/vhost-vsock (VHOST_VIRTIO is 0xAF).
const VHOST = 0xAF;
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
const VringState = extern struct { index: u32, num: u32 };
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
const run_immediate_exit = 1;
const run_exit_reason = 8;
const run_union = 32;

// The guest physical layout.
const gdt_addr = 0x500;
const zero_page = 0x7000;
const pml4_addr = 0x9000;
const cmdline_addr = 0x20000;
const cmdline_max = 4096;
const mptable_addr = 0x9fc00;
const kernel_addr = 0x100000;
const low_ram_end = 0x9fc00;
pub const mmio_base: u64 = 0xd0000000;
const mmio_size: u64 = 0x1000;
/// The ISA interrupts of the virtio devices, in order. 3 and 4 are the
/// serial ports, 8 is the clock, and 13 is the FPU.
const irqs = [_]u8{ 5, 6, 7, 9, 10, 11, 12, 14, 15 };
pub const max_disks = irqs.len - 3;
const ioapic_addr = 0xfec00000;
const lapic_addr = 0xfee00000;

/// The signal that kicks a vCPU thread out of `KVM_RUN`. Its handler
/// is empty.
const kick_signal: linux.SIG = @fromBackingInt(@intCast(40));

pub const Disk = struct {
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
    /// A virtio entropy device, after the disks.
    entropy: bool = false,
    /// The descriptor of the console (a socket): the output of the
    /// guest goes to it, and its input goes to the guest.
    console: i32,
};

pub const Fail = error{ NoKvm, KvmAccess, NoVhost, VhostAccess, Setup, Kernel, Memory, OutOfMemory };

/// The text for an error of `init` or `start`, as the last setup step
/// that failed.
pub threadlocal var why: []const u8 = "";

fn ok(rc: usize) ?usize {
    return if (linux.errno(rc) == .SUCCESS) rc else null;
}

fn check(rc: usize, what: []const u8) Fail!usize {
    return ok(rc) orelse {
        why = what;
        return error.Setup;
    };
}

fn ioctl(fd: i32, req: u32, arg: usize) usize {
    return linux.ioctl(fd, req, arg);
}

fn openDev(path: [*:0]const u8) usize {
    return linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
}

/// Checks that this host can run a guest: `/dev/kvm` and
/// `/dev/vhost-vsock` open for reading and writing.
pub fn probe() Fail!void {
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
}

pub fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------------
// Guest memory

const Mem = struct {
    base: [*]u8,
    size: u64,

    /// The bytes at a guest address, or null if a byte is outside the
    /// memory.
    fn slice(m: Mem, gpa: u64, len: u64) ?[]u8 {
        if (gpa > m.size or len > m.size - gpa) return null;
        return m.base[@intCast(gpa)..@intCast(gpa + len)];
    }

    fn ptr(m: Mem, comptime T: type, gpa: u64) ?*align(1) T {
        const s = m.slice(gpa, @sizeOf(T)) orelse return null;
        return @ptrCast(s.ptr);
    }

    fn put(m: Mem, comptime T: type, gpa: u64, v: T) void {
        std.mem.writeInt(T, m.base[@intCast(gpa)..][0..@sizeOf(T)], v, .little);
    }
};

// ---------------------------------------------------------------------
// Split virtqueues (virtio 1.2, section 2.7)

const desc_f_next = 1;
const desc_f_write = 2;
const max_queue = 256;

const Queue = struct {
    num: u32 = 0,
    ready: bool = false,
    desc: u64 = 0,
    avail: u64 = 0,
    used: u64 = 0,
    last_avail: u16 = 0,

    const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };

    /// The index of the next chain that the driver made available, or
    /// null when there is none.
    fn next(q: *Queue, m: Mem) ?u16 {
        if (!q.ready or q.num == 0) return null;
        const idx_p = m.ptr(u16, q.avail + 2) orelse return null;
        const idx = @atomicLoad(u16, @as(*u16, @ptrCast(@alignCast(idx_p))), .acquire);
        if (idx == q.last_avail) return null;
        const slot = q.avail + 4 + 2 * @as(u64, q.last_avail % q.num);
        const head = (m.ptr(u16, slot) orelse return null).*;
        q.last_avail +%= 1;
        return head;
    }

    fn descAt(q: *Queue, m: Mem, i: u16) ?Desc {
        if (i >= q.num) return null;
        const d = m.ptr(Desc, q.desc + 16 * @as(u64, i)) orelse return null;
        return d.*;
    }

    /// Puts a chain in the used ring with `len` bytes written.
    fn putUsed(q: *Queue, m: Mem, head: u16, len: u32) void {
        const idx_p = m.ptr(u16, q.used + 2) orelse return;
        const idx: *u16 = @ptrCast(@alignCast(idx_p));
        const cur = idx.*;
        const elem = q.used + 4 + 8 * @as(u64, cur % q.num);
        if (m.slice(elem, 8) == null) return;
        m.put(u32, elem, head);
        m.put(u32, elem + 4, len);
        @atomicStore(u16, idx, cur +% 1, .release);
    }

    /// Checks that the rings fit in the guest memory, when the driver
    /// sets the queue ready.
    fn valid(q: *const Queue, m: Mem) bool {
        if (q.num == 0 or q.num > max_queue) return false;
        return m.slice(q.desc, 16 * @as(u64, q.num)) != null and
            m.slice(q.avail, 6 + 2 * @as(u64, q.num)) != null and
            m.slice(q.used, 6 + 8 * @as(u64, q.num)) != null;
    }
};

/// A chain of descriptors as host slices: the readable part, then the
/// writable part.
const Chain = struct {
    const max = 64;
    bufs: [max][]u8 = undefined,
    writable: [max]bool = undefined,
    n: usize = 0,

    fn read(q: *Queue, m: Mem, head: u16) ?Chain {
        var c: Chain = .{};
        var i = head;
        while (c.n < max) {
            const d = q.descAt(m, i) orelse return null;
            c.bufs[c.n] = m.slice(d.addr, d.len) orelse return null;
            c.writable[c.n] = d.flags & desc_f_write != 0;
            c.n += 1;
            if (d.flags & desc_f_next == 0) return c;
            i = d.next;
        }
        return null;
    }
};

// ---------------------------------------------------------------------
// virtio-mmio devices (virtio 1.2, section 4.2)

const virtio_f_version_1: u64 = 1 << 32;
const blk_f_ro: u64 = 1 << 5;
const status_driver_ok = 4;
const int_vring = 1;

const Kind = enum { console, vsock, blk, rng };

const Lock = struct {
    m: std.atomic.Mutex = .unlocked,
    fn lock(l: *Lock) void {
        while (!l.m.tryLock()) _ = linux.sched_yield();
    }
    fn unlock(l: *Lock) void {
        l.m.unlock();
    }
};

const Device = struct {
    kind: Kind,
    irq: u8,
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
    /// Block: the descriptor of the disk and its size in bytes.
    fd: i32 = -1,
    read_only: bool = true,
    size: u64 = 0,
    /// vsock: eventfds of the kick and the call of queues 0 and 1.
    kick: [2]i32 = .{ -1, -1 },
    call: [2]i32 = .{ -1, -1 },
    running: bool = false,
};

const Machine = @This();

// ---------------------------------------------------------------------
// The machine

pub const State = enum(u32) { created, running, paused, stopped, failed };
const want_run = 0;
const want_pause = 1;
const want_stop = 2;

const Vcpu = struct {
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
con_lock: Lock = .{},
/// The UART registers.
uart: [8]u8 = @splat(0),
uart_lock: Lock = .{},
/// The time of each phase of the last start, in ns.
times: struct { setup: u64 = 0, load: u64 = 0 } = .{},
/// The text of a failure of a vCPU.
fail_text: []const u8 = "",
/// The guest address of the 64-bit entry point of the kernel.
entry: u64 = 0,

/// Makes a machine of the configuration. The machine uses the bytes of
/// `cfg` with no copy, so the caller keeps them until `deinit`.
pub fn init(alloc: std.mem.Allocator, cfg: Config) Fail!*Machine {
    try probe();
    if (cfg.disks.len > max_disks) {
        why = "too many disks";
        return error.Setup;
    }
    const m = try alloc.create(Machine);
    m.* = .{ .alloc = alloc, .cfg = cfg };
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
    for (m.vcpus) |*v| v.thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, vcpuMain, .{v}) catch {
        why = "no thread for a vCPU";
        return error.Setup;
    };
    m.con_thread = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, consoleMain, .{m}) catch null;
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

fn teardown(m: *Machine) void {
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
    for (m.vcpus) |*v| {
        if (v.run_size != 0) _ = linux.munmap(v.run, v.run_size);
        closeFd(&v.fd);
    }
    if (m.vcpus.len != 0) m.alloc.free(m.vcpus);
    m.vcpus = &.{};
    for (m.devices) |*d| {
        for (&d.kick) |*f| closeFd(f);
        for (&d.call) |*f| closeFd(f);
    }
    if (m.devices.len != 0) m.alloc.free(m.devices);
    m.devices = &.{};
    closeFd(&m.vhost);
    closeFd(&m.vm);
    closeFd(&m.kvm);
    closeFd(&m.con_stop);
    closeFd(&m.con_wake);
    m.con_pending_len = 0;
    if (m.mem.size != 0) _ = linux.munmap(m.mem.base, @intCast(m.mem.size));
    m.mem = .{ .base = undefined, .size = 0 };
}

var kick_installed = std.atomic.Value(bool).init(false);

fn onKick(_: linux.SIG) callconv(.c) void {}

fn installKick() void {
    if (kick_installed.swap(true, .seq_cst)) return;
    var act: linux.Sigaction = .{ .handler = .{ .handler = onKick }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(kick_signal, &act, null);
}

fn setup(m: *Machine) Fail!void {
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

    const size: u64 = @as(u64, m.cfg.memory_mb) << 20;
    const p = linux.mmap(null, @intCast(size), .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
    if (ok(p) == null) {
        why = "no host memory for the guest";
        return error.Memory;
    }
    m.mem = .{ .base = @ptrFromInt(p), .size = size };
    var region: MemoryRegion = .{ .slot = 0, .flags = 0, .guest_phys_addr = 0, .memory_size = size, .userspace_addr = p };
    _ = try check(ioctl(m.vm, KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region)), "KVM_SET_USER_MEMORY_REGION");
}

// ---------------------------------------------------------------------
// The boot (Documentation/arch/x86/boot.rst, the 64-bit boot protocol)

fn kernelFail(text: []const u8) Fail {
    why = text;
    return error.Kernel;
}

fn le(comptime T: type, b: []const u8, off: usize) T {
    return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
}

/// Loads the kernel and the initramfs, and writes the boot parameters,
/// the command line, the GDT, the page tables, and the MP table.
/// Gives the guest address of the 64-bit entry point.
fn loadKernel(m: *Machine) Fail!u64 {
    const mem = m.mem;
    const k = m.cfg.kernel;
    const zp = mem.slice(zero_page, 4096).?;
    @memset(zp, 0);
    var entry: u64 = 0;
    var kernel_end: u64 = kernel_addr;
    var initrd_max: u64 = 0x37ffffff;
    if (k.len >= 64 and std.mem.eql(u8, k[0..4], "\x7fELF")) {
        // An ELF vmlinux: each PT_LOAD at its physical address.
        if (k[4] != 2 or le(u16, k, 0x12) != 0x3e) return kernelFail("the ELF kernel is not x86-64");
        const e_entry = le(u64, k, 0x18);
        const phoff = le(u64, k, 0x20);
        const phentsize = le(u16, k, 0x36);
        const phnum = le(u16, k, 0x38);
        var i: usize = 0;
        while (i < phnum) : (i += 1) {
            const off = phoff + i * phentsize;
            if (off + 56 > k.len) return kernelFail("the ELF kernel is cut short");
            if (le(u32, k, off) != 1) continue;
            const p_offset = le(u64, k, off + 0x08);
            const p_vaddr = le(u64, k, off + 0x10);
            const p_paddr = le(u64, k, off + 0x18);
            const p_filesz = le(u64, k, off + 0x20);
            const p_memsz = le(u64, k, off + 0x28);
            if (p_filesz > p_memsz or p_offset > k.len or p_filesz > k.len - p_offset)
                return kernelFail("a segment of the ELF kernel is outside the file");
            const dst = mem.slice(p_paddr, p_memsz) orelse return kernelFail("the kernel is larger than the guest memory");
            @memcpy(dst[0..@intCast(p_filesz)], k[@intCast(p_offset)..@intCast(p_offset + p_filesz)]);
            kernel_end = @max(kernel_end, p_paddr + p_memsz);
            if (e_entry >= p_vaddr and e_entry < p_vaddr + p_memsz) entry = e_entry - p_vaddr + p_paddr;
        }
        if (entry == 0) entry = e_entry;
        // The fields of the setup header that the kernel reads.
        mem.put(u16, zero_page + 0x1fe, 0xaa55);
        mem.put(u32, zero_page + 0x202, 0x53726448);
        mem.put(u32, zero_page + 0x230, 0x1000000);
    } else {
        // A bzImage: the setup header at 0x1f1, the protected-mode kernel
        // after the setup sectors.
        if (k.len < 0x264 or le(u32, k, 0x202) != 0x53726448) return kernelFail("the kernel is not a bzImage or an ELF vmlinux");
        if (le(u16, k, 0x206) < 0x020c or le(u16, k, 0x236) & 1 == 0) return kernelFail("the bzImage has no 64-bit entry point");
        var setup_sects: usize = k[0x1f1];
        if (setup_sects == 0) setup_sects = 4;
        const pm = (setup_sects + 1) * 512;
        if (pm >= k.len) return kernelFail("the bzImage is cut short");
        const hdr_end = 0x202 + @as(usize, k[0x201]);
        @memcpy(zp[0x1f1..hdr_end], k[0x1f1..hdr_end]);
        const body = k[pm..];
        const init_size = le(u32, k, 0x260);
        const dst = mem.slice(kernel_addr, @max(body.len, init_size)) orelse return kernelFail("the kernel is larger than the guest memory");
        @memcpy(dst[0..body.len], body);
        kernel_end = kernel_addr + @max(body.len, init_size);
        entry = kernel_addr + 0x200;
        initrd_max = le(u32, k, 0x22c);
    }
    mem.put(u16, zero_page + 0x1fa, 0xffff); // vid_mode: normal
    zp[0x210] = 0xff; // type_of_loader: undefined
    zp[0x211] |= 0x01 | 0x80; // loadflags: LOADED_HIGH, CAN_USE_HEAP
    mem.put(u16, zero_page + 0x224, 0xfe00); // heap_end_ptr

    // The command line.
    const cl = m.cmdline();
    if (cl.len + 1 > cmdline_max) return kernelFail("the command line is longer than 4,095 bytes");
    const cdst = mem.slice(cmdline_addr, cl.len + 1).?;
    @memcpy(cdst[0..cl.len], cl);
    cdst[cl.len] = 0;
    mem.put(u32, zero_page + 0x228, cmdline_addr);

    // The initramfs, at the top of the memory below its limit.
    if (m.cfg.initrd.len != 0) {
        const top = @min(mem.size, initrd_max + 1);
        const len: u64 = m.cfg.initrd.len;
        if (len + kernel_end > top) return kernelFail("the initramfs does not fit in the guest memory");
        const addr = (top - len) & ~@as(u64, 0xfff);
        if (addr < kernel_end) return kernelFail("the initramfs does not fit in the guest memory");
        @memcpy(mem.slice(addr, len).?, m.cfg.initrd);
        mem.put(u32, zero_page + 0x218, @intCast(addr));
        mem.put(u32, zero_page + 0x21c, @intCast(len));
    }

    // The memory map: the low 639 KB and the memory above 1 MB.
    const e820 = [_][2]u64{ .{ 0, low_ram_end }, .{ kernel_addr, mem.size - kernel_addr } };
    for (e820, 0..) |e, i| {
        const at = zero_page + 0x2d0 + 20 * i;
        mem.put(u64, at, e[0]);
        mem.put(u64, at + 8, e[1]);
        mem.put(u32, at + 16, 1);
    }
    zp[0x1e8] = e820.len;

    // The GDT: null, null, code 0x10, data 0x18.
    const gdt = [_]u64{ 0, 0, 0x00af9b000000ffff, 0x00cf93000000ffff };
    for (gdt, 0..) |g, i| mem.put(u64, gdt_addr + 8 * i, g);

    // The identity map of the first 4 GB: PML4, PDPT, and 4 PDs.
    const pdpt = pml4_addr + 0x1000;
    const pd = pml4_addr + 0x2000;
    @memset(mem.slice(pml4_addr, 0x6000).?, 0);
    mem.put(u64, pml4_addr, pdpt | 3);
    for (0..4) |i| {
        mem.put(u64, pdpt + 8 * i, (pd + 0x1000 * i) | 3);
        for (0..512) |j| mem.put(u64, pd + 0x1000 * i + 8 * j, ((i << 30) | (j << 21)) | 0x83);
    }
    m.writeMpTable();
    return entry;
}

/// The command line of the guest: the one of the configuration, then the
/// options of this monitor and the list of the virtio-mmio devices.
fn cmdline(m: *Machine) []const u8 {
    const S = struct {
        threadlocal var buf: [cmdline_max + 512]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    w.print("{s} reboot=k panic=-1 nomodule", .{m.cfg.cmdline}) catch return S.buf[0..0];
    for (0..m.deviceCount()) |i| w.print(" virtio_mmio.device=4K@0x{x}:{d}", .{ mmio_base + mmio_size * i, irqs[i] }) catch return w.buffered();
    return w.buffered();
}

/// The MP table of the MultiProcessor Specification 1.4: the floating
/// pointer, then the configuration table with the CPUs, the ISA bus, the
/// I/O APIC, an entry for each ISA interrupt, and the local interrupts.
fn writeMpTable(m: *Machine) void {
    const mem = m.mem;
    const n: u32 = @intCast(m.cfg.cpus);
    const ioapic_id: u8 = @intCast(n);
    const table = mptable_addr + 16;
    var at: u64 = table + 44;
    var count: u16 = 0;
    for (0..n) |i| {
        const e = mem.slice(at, 20).?;
        @memset(e, 0);
        e[0] = 0; // processor
        e[1] = @intCast(i);
        e[2] = 0x14;
        e[3] = if (i == 0) 3 else 1; // enabled, and the boot CPU
        std.mem.writeInt(u32, e[4..8], 0x600, .little);
        std.mem.writeInt(u32, e[8..12], 0x201, .little); // FPU, APIC
        at += 20;
        count += 1;
    }
    const bus = mem.slice(at, 8).?;
    bus[0] = 1;
    bus[1] = 0;
    @memcpy(bus[2..8], "ISA   ");
    at += 8;
    count += 1;
    const io = mem.slice(at, 8).?;
    io[0] = 2;
    io[1] = ioapic_id;
    io[2] = 0x11;
    io[3] = 1;
    std.mem.writeInt(u32, io[4..8], ioapic_addr, .little);
    at += 8;
    count += 1;
    for (0..16) |irq| {
        if (irq == 2) continue;
        const e = mem.slice(at, 8).?;
        e[0] = 3; // I/O interrupt
        e[1] = 0; // INT
        e[2] = 0;
        e[3] = 0; // flags: conforms to the bus
        e[4] = 0; // bus 0
        e[5] = @intCast(irq);
        e[6] = ioapic_id;
        e[7] = @intCast(irq);
        at += 8;
        count += 1;
    }
    for ([_]u8{ 3, 1 }, 0..) |kind, lint| {
        const e = mem.slice(at, 8).?;
        e[0] = 4; // local interrupt
        e[1] = kind; // ExtINT on LINT0, NMI on LINT1
        e[2] = 0;
        e[3] = 0;
        e[4] = 0;
        e[5] = 0;
        e[6] = 0xff; // each local APIC
        e[7] = @intCast(lint);
        at += 8;
        count += 1;
    }
    const len: u16 = @intCast(at - table);
    const h = mem.slice(table, 44).?;
    @memset(h, 0);
    @memcpy(h[0..4], "PCMP");
    std.mem.writeInt(u16, h[4..6], len, .little);
    h[6] = 4;
    @memcpy(h[8..16], "ZTCL    ");
    @memcpy(h[16..28], "ZTCLVM      ");
    std.mem.writeInt(u16, h[34..36], count, .little);
    std.mem.writeInt(u32, h[36..40], lapic_addr, .little);
    h[7] = checksum(mem.slice(table, len).?);
    const fp = mem.slice(mptable_addr, 16).?;
    @memset(fp, 0);
    @memcpy(fp[0..4], "_MP_");
    std.mem.writeInt(u32, fp[4..8], @intCast(table), .little);
    fp[8] = 1;
    fp[9] = 4;
    fp[10] = checksum(fp);
}

fn checksum(b: []const u8) u8 {
    var s: u8 = 0;
    for (b) |x| s +%= x;
    return 0 -% s;
}

fn load(m: *Machine) Fail!void {
    m.entry = try m.loadKernel();
}

fn makeVcpus(m: *Machine) Fail!void {
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

fn deviceCount(m: *const Machine) usize {
    return 2 + m.cfg.disks.len + @intFromBool(m.cfg.entropy);
}

fn makeDevices(m: *Machine) Fail!void {
    const n = m.deviceCount();
    m.devices = try m.alloc.alloc(Device, n);
    if (m.cfg.entropy) m.devices[n - 1] = .{ .kind = .rng, .irq = irqs[n - 1], .features = virtio_f_version_1, .nqueues = 1 };
    m.devices[0] = .{ .kind = .console, .irq = irqs[0], .features = virtio_f_version_1, .nqueues = 2, .config_len = 12 };
    m.devices[1] = .{ .kind = .vsock, .irq = irqs[1], .features = virtio_f_version_1, .nqueues = 3, .config_len = 8 };
    for (m.cfg.disks, 0..) |d, i| {
        const size = linux.lseek(d.fd, 0, linux.SEEK.END);
        if (@as(i64, @bitCast(size)) < 0) {
            why = "the size of a disk";
            return error.Setup;
        }
        var dev: Device = .{ .kind = .blk, .irq = irqs[2 + i], .features = virtio_f_version_1 | (if (d.read_only) blk_f_ro else 0), .nqueues = 1, .config_len = 8, .fd = d.fd, .read_only = d.read_only, .size = size };
        std.mem.writeInt(u64, dev.config[0..8], size / 512, .little);
        m.devices[2 + i] = dev;
    }
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
    const dev = &m.devices[1];
    std.mem.writeInt(u64, dev.config[0..8], m.cid, .little);
    for (0..2) |q| {
        dev.kick[q] = try eventfd();
        dev.call[q] = try eventfd();
        var io: Ioeventfd = .{ .datamatch = q, .addr = mmio_base + mmio_size * 1 + 0x50, .len = 4, .fd = dev.kick[q], .flags = ioeventfd_datamatch };
        _ = try check(ioctl(m.vm, KVM_IOEVENTFD, @intFromPtr(&io)), "KVM_IOEVENTFD");
        var irq: Irqfd = .{ .fd = @intCast(dev.call[q]), .gsi = dev.irq, .flags = 0, .resamplefd = 0 };
        _ = try check(ioctl(m.vm, KVM_IRQFD, @intFromPtr(&irq)), "KVM_IRQFD");
    }
}

/// Gives vhost the memory and the two queues of vsock, and starts it.
fn vhostStart(m: *Machine, d: *Device) bool {
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
        var start_at: VringState = .{ .index = idx, .num = 0 };
        var addr: VringAddr = .{ .index = idx, .flags = 0, .desc_user_addr = base + q.desc, .used_user_addr = base + q.used, .avail_user_addr = base + q.avail, .log_guest_addr = 0 };
        var kick: VringFile = .{ .index = idx, .fd = d.kick[i] };
        var call: VringFile = .{ .index = idx, .fd = d.call[i] };
        if (ok(ioctl(m.vhost, VHOST_SET_VRING_NUM, @intFromPtr(&num))) == null) return false;
        if (ok(ioctl(m.vhost, VHOST_SET_VRING_BASE, @intFromPtr(&start_at))) == null) return false;
        if (ok(ioctl(m.vhost, VHOST_SET_VRING_ADDR, @intFromPtr(&addr))) == null) return false;
        if (ok(ioctl(m.vhost, VHOST_SET_VRING_KICK, @intFromPtr(&kick))) == null) return false;
        if (ok(ioctl(m.vhost, VHOST_SET_VRING_CALL, @intFromPtr(&call))) == null) return false;
    }
    var on: c_int = 1;
    if (ok(ioctl(m.vhost, VHOST_VSOCK_SET_RUNNING, @intFromPtr(&on))) == null) return false;
    d.running = true;
    return true;
}

fn vhostStop(m: *Machine, d: *Device) void {
    if (!d.running) return;
    var off: c_int = 0;
    _ = ioctl(m.vhost, VHOST_VSOCK_SET_RUNNING, @intFromPtr(&off));
    d.running = false;
}

fn interrupt(m: *Machine, d: *Device) void {
    d.int_status |= int_vring;
    var hi: IrqLevel = .{ .irq = d.irq, .level = 1 };
    _ = ioctl(m.vm, KVM_IRQ_LINE, @intFromPtr(&hi));
    var lo: IrqLevel = .{ .irq = d.irq, .level = 0 };
    _ = ioctl(m.vm, KVM_IRQ_LINE, @intFromPtr(&lo));
}

fn mmioRead(m: *Machine, d: *Device, off: u64, out: []u8) void {
    @memset(out, 0);
    if (off >= 0x100) {
        const c = off - 0x100;
        if (c < d.config_len and c + out.len <= d.config_len) @memcpy(out, d.config[@intCast(c)..][0..out.len]);
        return;
    }
    if (out.len != 4) return;
    const q = &d.queues[@min(d.queue_sel, 2)];
    const qok = d.queue_sel < d.nqueues;
    const v: u32 = switch (off) {
        0x000 => 0x74726976, // "virt"
        0x004 => 2,
        0x008 => switch (d.kind) {
            .console => 3,
            .vsock => 19,
            .blk => 2,
            .rng => 4,
        },
        0x00c => 0x4c54375a, // "Z7TL"
        0x010 => if (d.dev_sel == 0) @truncate(d.features) else if (d.dev_sel == 1) @truncate(d.features >> 32) else 0,
        0x034 => if (qok) max_queue else 0,
        0x044 => @intFromBool(qok and q.ready),
        // vsock: the interrupts come from vhost through the irqfd, so
        // the status always has the bit of a used buffer.
        0x060 => if (d.kind == .vsock) int_vring else d.int_status,
        0x070 => d.status,
        0x0fc => 0,
        else => 0,
    };
    _ = m;
    std.mem.writeInt(u32, out[0..4], v, .little);
}

fn mmioWrite(m: *Machine, d: *Device, off: u64, data: []const u8) void {
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
            q.num = @min(v, max_queue);
        },
        0x044 => if (qok) {
            q.ready = v == 1 and q.valid(m.mem);
            q.last_avail = 0;
        },
        0x050 => m.notify(d, v),
        0x064 => d.int_status &= ~v,
        0x070 => {
            if (v == 0) {
                if (d.kind == .vsock) vhostStop(m, d);
                const keep = d.*;
                d.* = .{ .kind = keep.kind, .irq = keep.irq, .features = keep.features, .config = keep.config, .config_len = keep.config_len, .nqueues = keep.nqueues, .fd = keep.fd, .read_only = keep.read_only, .size = keep.size, .kick = keep.kick, .call = keep.call };
                return;
            }
            const was = d.status;
            d.status = v;
            if (d.kind == .vsock and v & status_driver_ok != 0 and was & status_driver_ok == 0) {
                if (!m.vhostStart(d)) d.status |= 0x40; // DEVICE_NEEDS_RESET
            }
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

fn setLow(x: *u64, v: u32) void {
    x.* = (x.* & ~@as(u64, 0xffffffff)) | v;
}
fn setHigh(x: *u64, v: u32) void {
    x.* = (x.* & 0xffffffff) | (@as(u64, v) << 32);
}

/// A notification of the driver for queue `qi` of a device (vsock goes
/// to vhost through the ioeventfd and does not get here).
fn notify(m: *Machine, d: *Device, qi: u32) void {
    switch (d.kind) {
        .console => if (qi == 1) m.consoleTx(d) else if (qi == 0) {
            const one: u64 = 1;
            _ = linux.write(m.con_wake, std.mem.asBytes(&one), 8);
        },
        .blk => if (qi == 0) m.blkRequests(d),
        .rng => if (qi == 0) m.rngFill(d),
        .vsock => {},
    }
}

fn consoleTx(m: *Machine, d: *Device) void {
    const q = &d.queues[1];
    var any = false;
    while (q.next(m.mem)) |head| {
        any = true;
        const c = Chain.read(q, m.mem, head) orelse {
            q.putUsed(m.mem, head, 0);
            continue;
        };
        for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| if (!w) writeAll(m.cfg.console, b);
        q.putUsed(m.mem, head, 0);
    }
    if (any) m.interrupt(d);
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

/// Puts the pending input of the console in the receive queue. Gives
/// true when the input all went in.
fn consoleRx(m: *Machine) bool {
    const d = &m.devices[0];
    d.lock.lock();
    defer d.lock.unlock();
    const q = &d.queues[0];
    var off: usize = 0;
    var any = false;
    while (off < m.con_pending_len) {
        const head = q.next(m.mem) orelse break;
        any = true;
        var put: u32 = 0;
        if (Chain.read(q, m.mem, head)) |c| {
            for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
                if (!w or off >= m.con_pending_len) continue;
                const k = @min(b.len, m.con_pending_len - off);
                @memcpy(b[0..k], m.con_pending[off..][0..k]);
                off += k;
                put += @intCast(k);
            }
        }
        q.putUsed(m.mem, head, put);
    }
    std.mem.copyForwards(u8, m.con_pending[0 .. m.con_pending_len - off], m.con_pending[off..m.con_pending_len]);
    m.con_pending_len -= off;
    if (any) m.interrupt(d);
    return m.con_pending_len == 0;
}

/// The console thread: reads the console descriptor into the receive
/// queue of the console device.
fn consoleMain(m: *Machine) void {
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
                if (k == 0) {
                    // The script closed its end: wait only for the stop.
                    var stop_fd = [_]linux.pollfd{.{ .fd = m.con_stop, .events = linux.POLL.IN, .revents = 0 }};
                    _ = linux.poll(&stop_fd, 1, -1);
                    return;
                }
                m.con_pending_len = k;
            }
        } else if (fds[2].revents != 0) {
            var stop_fd = [_]linux.pollfd{.{ .fd = m.con_stop, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&stop_fd, 1, -1);
            return;
        }
        if (m.con_pending_len != 0 and m.devices[0].status & status_driver_ok != 0) _ = m.consoleRx();
    }
}

/// virtio-rng (virtio 1.2, section 5.4): each writable buffer gets
/// bytes of `getrandom`.
fn rngFill(m: *Machine, d: *Device) void {
    const q = &d.queues[0];
    var any = false;
    while (q.next(m.mem)) |head| {
        any = true;
        var put: u32 = 0;
        if (Chain.read(q, m.mem, head)) |c| {
            for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
                if (!w) continue;
                const rc = linux.getrandom(b.ptr, b.len, 0);
                if (ok(rc)) |k| put += @intCast(k);
            }
        }
        q.putUsed(m.mem, head, put);
    }
    if (any) m.interrupt(d);
}

// virtio-blk (virtio 1.2, section 5.2)
const blk_in = 0;
const blk_out = 1;
const blk_flush = 4;
const blk_get_id = 8;
const blk_ok = 0;
const blk_ioerr = 1;
const blk_unsupp = 2;

fn blkRequests(m: *Machine, d: *Device) void {
    const q = &d.queues[0];
    var any = false;
    while (q.next(m.mem)) |head| {
        any = true;
        const written = m.blkOne(d, q, head);
        q.putUsed(m.mem, head, written);
    }
    if (any) m.interrupt(d);
}

/// Runs one request and gives the count of bytes that it wrote to the
/// guest, with the status byte.
fn blkOne(m: *Machine, d: *Device, q: *Queue, head: u16) u32 {
    const c = Chain.read(q, m.mem, head) orelse return 0;
    if (c.n < 2 or c.bufs[0].len < 16 or c.writable[0]) return 0;
    const last = c.bufs[c.n - 1];
    if (!c.writable[c.n - 1] or last.len < 1) return 0;
    const kind = std.mem.readInt(u32, c.bufs[0][0..4], .little);
    const sector = std.mem.readInt(u64, c.bufs[0][8..16], .little);
    var status: u8 = blk_ok;
    var written: u32 = 0;
    var pos: u64 = sector *% 512;
    const data = c.bufs[1 .. c.n - 1];
    const data_w = c.writable[1 .. c.n - 1];
    switch (kind) {
        blk_in, blk_out => for (data, data_w) |b, w| {
            if (sector > d.size / 512 or b.len > d.size - @min(pos, d.size)) {
                status = blk_ioerr;
                break;
            }
            if (kind == blk_in) {
                if (!w or !fullIo(d.fd, b, pos, false)) {
                    status = blk_ioerr;
                    break;
                }
                written += @intCast(b.len);
            } else {
                if (d.read_only or w) {
                    status = blk_ioerr;
                    break;
                }
                if (!fullIo(d.fd, b, pos, true)) {
                    status = blk_ioerr;
                    break;
                }
            }
            pos += b.len;
        },
        blk_flush => if (!d.read_only) {
            _ = linux.fsync(d.fd);
        },
        blk_get_id => {
            if (data.len >= 1 and data_w[0]) {
                const id = "ztcl-vm-disk";
                const b = data[0];
                @memset(b[0..@min(b.len, 20)], 0);
                const k = @min(b.len, id.len);
                @memcpy(b[0..k], id[0..k]);
                written += @intCast(@min(b.len, 20));
            } else status = blk_ioerr;
        },
        else => status = blk_unsupp,
    }
    last[last.len - 1] = status;
    return written + 1;
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

fn vcpuMain(v: *Vcpu) void {
    const m = v.machine;
    v.tid.store(linux.gettid(), .seq_cst);
    defer v.tid.store(0, .seq_cst);
    while (true) {
        const w = m.want.load(.seq_cst);
        if (w == want_stop) return;
        if (w == want_pause) {
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
    d.lock.lock();
    defer d.lock.unlock();
    if (write) m.mmioWrite(d, off, data[0..len]) else m.mmioRead(d, off, data[0..len]);
}

test "kvm: the MP table and the command line" {
    if (comptime !supported) return;
    var buf: [1 << 20]u8 align(4096) = undefined;
    var m: Machine = .{ .alloc = std.testing.allocator, .cfg = .{ .kernel = "", .cmdline = "console=hvc0", .console = -1, .cpus = 2, .disks = &.{.{ .fd = -1, .read_only = true }} } };
    m.mem = .{ .base = &buf, .size = buf.len };
    m.writeMpTable();
    try std.testing.expectEqualStrings("_MP_", buf[mptable_addr..][0..4]);
    var s: u8 = 0;
    for (buf[mptable_addr..][0..16]) |x| s +%= x;
    try std.testing.expectEqual(@as(u8, 0), s);
    const len = std.mem.readInt(u16, buf[mptable_addr + 16 + 4 ..][0..2], .little);
    s = 0;
    for (buf[mptable_addr + 16 ..][0..len]) |x| s +%= x;
    try std.testing.expectEqual(@as(u8, 0), s);
    try std.testing.expectEqualStrings(
        "console=hvc0 reboot=k panic=-1 nomodule virtio_mmio.device=4K@0xd0000000:5 virtio_mmio.device=4K@0xd0001000:6 virtio_mmio.device=4K@0xd0002000:7",
        m.cmdline(),
    );
}

test "kvm: a guest address outside the memory" {
    var buf: [4096]u8 = undefined;
    const mem: Mem = .{ .base = &buf, .size = buf.len };
    try std.testing.expect(mem.slice(4000, 96) != null);
    try std.testing.expect(mem.slice(4000, 97) == null);
    try std.testing.expect(mem.slice(std.math.maxInt(u64), 2) == null);
}

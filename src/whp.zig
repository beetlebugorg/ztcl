//! A small virtual machine monitor on the Windows Hypervisor Platform
//! (WinHvPlatform.dll), for `ztcl::vm` (ztcl#203). It boots an x86-64
//! Linux guest with `vm/boot.zig` and gives it its devices on
//! virtio-mmio: the shared ones of `vm/virtio/`, and the vsock device of
//! ztcl, since Windows has no vhost-vsock. The sources are the
//! documentation of the Windows Hypervisor Platform and of its
//! instruction emulator (WinHvEmulation.dll), the virtio 1.2
//! specification of OASIS, and the Intel MultiProcessor Specification.
//!
//! A user with no elevation runs it: the partition needs the hypervisor,
//! which runs when Virtualization-based Security is on, or with the
//! feature Windows Hypervisor Platform. `probe` checks it.
//!
//! The partition has the local APIC of the hypervisor (xAPIC emulation),
//! one CPU, and the guest memory from `VirtualAlloc` at guest address 0.
//! The host emulates the rest:
//!
//! - An I/O APIC at 0xfec00000 (`IoApic`), which the MP table of
//!   `boot.zig` gives the guest. A raise of an unmasked pin sends its
//!   vector to the local APIC with `WHvRequestInterrupt`. The ISA pins
//!   are edge triggered.
//! - Each virtio device in a 4 KB window at 0xd0000000 + 0x1000 * n with
//!   ISA interrupt `irqs[n]`, on the command line of the guest
//!   (`virtio_mmio.device=`): the console (`hvc0`), vsock, the disks, and
//!   entropy with `-entropy 1`.
//! - An 8250 UART at port 0x3f8 (`Uart`), whose output goes to the
//!   console too (`console=ttyS0`), with the interrupt of its empty
//!   transmitter on IRQ 4. It exits to the host for each byte.
//! - The ports of the i8042 read as 0xff, a bus with no device, so its
//!   probe ends at once. A write of 0xfe to port 0x64 (`reboot=k`) or a
//!   triple fault stops the guest. Each other port reads as 0.
//!
//! The emulator of WinHvEmulation.dll decodes each port and MMIO exit of
//! a vCPU and calls this file for the access, on the thread of that
//! vCPU. A pause or a stop cancels the run of each vCPU
//! (`WHvCancelRunVirtualProcessor`), and a paused thread waits with
//! `WaitOnAddress` until the host sets `want` back.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const boot = @import("vm/boot.zig");
const virtio = @import("vm/virtio/mmio.zig");
const vsock = @import("vm/virtio/vsock.zig");
const Mem = virtio.Mem;
const Device = virtio.Device;
const ninep = @import("vm/virtio/ninep.zig");
const share_windows = @import("vm/share_windows.zig");
const NinepState = struct { share: share_windows.Share, server: ninep.Server, fs: fuse.Server = undefined };
const fuse = @import("vm/virtio/fuse.zig");

pub const supported = builtin.os.tag == .windows and builtin.cpu.arch == .x86_64;

const HRESULT = i32;
const HANDLE = *anyopaque;
const Partition = *anyopaque;

pub const mmio_base: u64 = 0xd0000000;
const mmio_size: u64 = 0x1000;
/// The ISA interrupts of the virtio devices, in their order. IRQ 4 is the
/// UART.
const irqs = [_]u8{ 5, 6, 7, 9, 10, 11, 12, 14, 15 };
pub const max_disks = irqs.len - 3;
/// The CID of the guest on the vsock device.
pub const guest_cid: u64 = 3;

pub const Disk = struct {
    handle: HANDLE,
    read_only: bool,
};

/// A 9p share: the descriptor of ztcl of its root folder. Share n has the
/// tag `share<n>`.
pub const Share = struct {
    fd: i32,
    read_only: bool,
};

/// The output of the guest console: the virtio console and the UART.
pub const ConsoleOut = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) void,
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
    /// The shares are virtio-fs devices (`vm/virtio/fuse.zig`) in the place
    /// of 9p.
    virtiofs: bool = false,
    /// A virtio entropy device, after the disks and the shares.
    entropy: bool = false,
    console: ConsoleOut,
    /// The host side of the vsock streams.
    vsock: vsock.Sink,
};

pub const Fail = error{ NoHypervisor, Setup, Kernel, Memory, OutOfMemory };

/// The text for an error of `init` or `start`.
pub threadlocal var why: []const u8 = "";

pub const State = enum(u32) { created, running, paused, stopped, failed };
const want_run = 0;
const want_pause = 1;
const want_stop = 2;

const Machine = @This();

const Vcpu = struct {
    machine: *Machine,
    index: u32,
    emu: ?*anyopaque = null,
    thread: ?std.Thread = null,
};

alloc: std.mem.Allocator,
cfg: Config,
part: ?Partition = null,
mem: Mem = .{ .base = undefined, .size = 0 },
vcpus: []Vcpu = &.{},
devices: []Device = &.{},
/// The 9p servers of the shares, made with the devices.
ninep_state: []NinepState = &.{},
vs: vsock.Vsock,
want: std.atomic.Value(u32) = .init(want_run),
parked: std.atomic.Value(u32) = .init(0),
state: std.atomic.Value(State) = .init(.created),
ioapic: IoApic = .{},
ioapic_lock: virtio.Lock = .{},
uart: Uart = .{},
uart_lock: virtio.Lock = .{},
/// The input of the console that waits for receive buffers.
con_pending: std.ArrayList(u8) = .empty,
/// The text of a failure of a vCPU.
fail_text: []const u8 = "",
entry: u64 = 0,
times: struct { setup: u64 = 0, load: u64 = 0 } = .{},

// ---------------------------------------------------------------------
// The calls of Windows

extern "winhvplatform" fn WHvGetCapability(code: u32, buf: *anyopaque, size: u32, written: ?*u32) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvCreatePartition(p: *Partition) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvSetPartitionProperty(p: Partition, code: u32, value: *const anyopaque, size: u32) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvSetupPartition(p: Partition) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvDeletePartition(p: Partition) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvMapGpaRange(p: Partition, host: *anyopaque, gpa: u64, size: u64, flags: u32) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvCreateVirtualProcessor(p: Partition, index: u32, flags: u32) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvDeleteVirtualProcessor(p: Partition, index: u32) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvRunVirtualProcessor(p: Partition, index: u32, exit: *ExitContext, size: u32) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvCancelRunVirtualProcessor(p: Partition, index: u32, flags: u32) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvSetVirtualProcessorRegisters(p: Partition, index: u32, names: [*]const u32, count: u32, values: [*]const RegValue) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvGetVirtualProcessorRegisters(p: Partition, index: u32, names: [*]const u32, count: u32, values: [*]RegValue) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvTranslateGva(p: Partition, index: u32, gva: u64, flags: u32, result: *[2]u32, gpa: *u64) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvRequestInterrupt(p: Partition, ctl: *const InterruptControl, size: u32) callconv(.winapi) HRESULT;
extern "winhvemulation" fn WHvEmulatorCreateEmulator(callbacks: *const EmulatorCallbacks, emu: *?*anyopaque) callconv(.winapi) HRESULT;
extern "winhvemulation" fn WHvEmulatorDestroyEmulator(emu: *anyopaque) callconv(.winapi) HRESULT;
extern "winhvemulation" fn WHvEmulatorTryIoEmulation(emu: *anyopaque, ctx: ?*anyopaque, vp: *const [40]u8, io: *const [176]u8, status: *u32) callconv(.winapi) HRESULT;
extern "winhvemulation" fn WHvEmulatorTryMmioEmulation(emu: *anyopaque, ctx: ?*anyopaque, vp: *const [40]u8, mmio: *const [176]u8, status: *u32) callconv(.winapi) HRESULT;
extern "kernel32" fn VirtualAlloc(at: ?*anyopaque, size: usize, kind: u32, protect: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(at: *anyopaque, size: usize, kind: u32) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceCounter(t: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(f: *i64) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, got: *u32, ov: *Overlapped) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, put: *u32, ov: *Overlapped) callconv(.winapi) i32;
extern "kernel32" fn FlushFileBuffers(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetFileSizeEx(h: HANDLE, size: *i64) callconv(.winapi) i32;
extern "api-ms-win-core-synch-l1-2-0" fn WaitOnAddress(addr: *const anyopaque, compare: *const anyopaque, size: usize, ms: u32) callconv(.winapi) i32;
extern "api-ms-win-core-synch-l1-2-0" fn WakeByAddressAll(addr: *const anyopaque) callconv(.winapi) void;
extern "bcrypt" fn BCryptGenRandom(alg: ?*anyopaque, buf: [*]u8, len: u32, flags: u32) callconv(.winapi) i32;

const Overlapped = extern struct { internal: usize = 0, internal_high: usize = 0, offset: u32, offset_high: u32, event: ?HANDLE = null };

const cap_hypervisor_present: u32 = 0;
const prop_processor_count: u32 = 0x1fff;
const prop_local_apic_mode: u32 = 0x1005;
const map_rwx: u32 = 1 | 2 | 4;

const exit_memory: u32 = 1;
const exit_io: u32 = 2;
const exit_unrecoverable: u32 = 4;
const exit_invalid_registers: u32 = 5;
const exit_halt: u32 = 8;
const exit_canceled: u32 = 0x2001;

// The names of the registers of WHV_REGISTER_NAME.
const r = struct {
    const rsp: u32 = 0x04;
    const rsi: u32 = 0x06;
    const rip: u32 = 0x10;
    const rflags: u32 = 0x11;
    const es: u32 = 0x12;
    const cs: u32 = 0x13;
    const ss: u32 = 0x14;
    const ds: u32 = 0x15;
    const fs: u32 = 0x16;
    const gs: u32 = 0x17;
    const tr: u32 = 0x19;
    const gdtr: u32 = 0x1b;
    const cr0: u32 = 0x1c;
    const cr3: u32 = 0x1e;
    const cr4: u32 = 0x1f;
    const efer: u32 = 0x2001;
};

/// WHV_REGISTER_VALUE: 16 bytes with an alignment of 16. An array of a
/// smaller alignment fails inside `WHvSetVirtualProcessorRegisters`.
const RegValue = extern union {
    _align: u128 align(16),
    reg64: u64,
    seg: extern struct { base: u64, limit: u32, selector: u16, attributes: u16 },
    table: extern struct { pad: [3]u16, limit: u16, base: u64 },
};

/// WHV_RUN_VP_EXIT_CONTEXT: the reason at 0, the context of the CPU at
/// 8, and the data of the reason at 48.
const ExitContext = extern struct { reason: u32, reserved: u32, vp: [40]u8, data: [176]u8 };

/// WHV_INTERRUPT_CONTROL: the type in bits 0 to 7 and the destination
/// mode in bits 8 to 11.
const InterruptControl = extern struct { bits: u64, destination: u32, vector: u32 };

/// WHV_EMULATOR_IO_ACCESS_INFO and WHV_EMULATOR_MEMORY_ACCESS_INFO.
const IoAccess = extern struct { direction: u8, port: u16, size: u16, data: u32 };
const MemoryAccess = extern struct { gpa: u64, direction: u8, size: u8, data: [8]u8 };

const EmulatorCallbacks = extern struct {
    size: u32 = @sizeOf(EmulatorCallbacks),
    reserved: u32 = 0,
    io: *const fn (?*anyopaque, *IoAccess) callconv(.winapi) HRESULT,
    memory: *const fn (?*anyopaque, *MemoryAccess) callconv(.winapi) HRESULT,
    get: *const fn (?*anyopaque, [*]const u32, u32, [*]RegValue) callconv(.winapi) HRESULT,
    set: *const fn (?*anyopaque, [*]const u32, u32, [*]const RegValue) callconv(.winapi) HRESULT,
    translate: *const fn (?*anyopaque, u64, u32, *u32, *u64) callconv(.winapi) HRESULT,
};

const callbacks: EmulatorCallbacks = .{ .io = ioCallback, .memory = memoryCallback, .get = getRegs, .set = setRegs, .translate = translate };

// ---------------------------------------------------------------------
// The machine

/// Checks that this host can run a guest: the hypervisor runs, and a
/// partition can be made.
pub fn probe() Fail!void {
    var present: u32 = 0;
    if (WHvGetCapability(cap_hypervisor_present, &present, 4, null) < 0 or present == 0) return error.NoHypervisor;
}

pub fn nowNs() u64 {
    var f: i64 = 1;
    var c: i64 = 0;
    _ = QueryPerformanceFrequency(&f);
    _ = QueryPerformanceCounter(&c);
    return @intCast(@divTrunc(@as(i128, c) * std.time.ns_per_s, f));
}

/// Waits `us` microseconds. `Sleep` waits at least to the next tick of
/// the clock of the system, 15.6 ms unless a process asks for a faster
/// one, and so a wait of 1 ms there gave a vsock connection 15 ms. A
/// waitable timer of CREATE_WAITABLE_TIMER_HIGH_RESOLUTION (Windows 10
/// 1803) waits the time it gets and changes no setting of the system.
/// Each thread has its own timer, and a host with no such timer falls
/// back to `Sleep`.
pub fn sleepUs(us: u32) void {
    const S = struct {
        threadlocal var timer: ?HANDLE = null;
        threadlocal var tried = false;
    };
    if (!S.tried) {
        S.tried = true;
        // CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS.
        S.timer = CreateWaitableTimerExW(null, null, 0x2, 0x1f0003);
    }
    if (S.timer) |t| {
        // A negative due time is relative, in units of 100 ns.
        const due: i64 = -@as(i64, us) * 10;
        if (SetWaitableTimer(t, &due, 0, null, null, 0) != 0) {
            _ = WaitForSingleObject(t, 0xffffffff);
            return;
        }
    }
    Sleep(@max(1, us / 1000));
}

extern "kernel32" fn CreateWaitableTimerExW(attrs: ?*anyopaque, name: ?[*:0]const u16, flags: u32, access: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetWaitableTimer(t: HANDLE, due: *const i64, period: i32, routine: ?*anyopaque, arg: ?*anyopaque, resume_: i32) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

/// Makes a machine of the configuration. The machine uses the bytes of
/// `cfg` with no copy, so the caller keeps them until `deinit`.
pub fn init(alloc: std.mem.Allocator, cfg: Config) Fail!*Machine {
    try probe();
    if (cfg.disks.len + cfg.shares.len > max_disks) {
        why = "too many disks and shares";
        return error.Setup;
    }
    if (cfg.cpus != 1) {
        why = "a guest on the Windows Hypervisor Platform has one CPU yet";
        return error.Setup;
    }
    const m = try alloc.create(Machine);
    m.* = .{ .alloc = alloc, .cfg = cfg, .vs = vsock.Vsock.init(alloc, guest_cid, cfg.vsock) };
    return m;
}

pub fn deinit(m: *Machine) void {
    m.stop();
    m.vs.deinit();
    m.con_pending.deinit(m.alloc);
    m.alloc.destroy(m);
}

pub fn getState(m: *Machine) State {
    return m.state.load(.acquire);
}

/// Boots the guest: makes the partition, maps the memory, loads the
/// kernel, makes the devices, and starts the vCPU thread.
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
    try m.makeDevices();
    m.entry = boot.load(m.mem, .{ .kernel = m.cfg.kernel, .initrd = m.cfg.initrd, .cmdline = m.cmdline(), .cpus = m.cfg.cpus }) catch {
        why = boot.why;
        return error.Kernel;
    };
    try m.makeVcpus();
    m.times = .{ .setup = t1 - t0, .load = nowNs() - t1 };
    m.state.store(.running, .release);
    for (m.vcpus) |*v| v.thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, vcpuMain, .{v}) catch {
        why = "no thread for a vCPU";
        return error.Setup;
    };
}

/// Stops each vCPU and frees the partition. The machine can start again.
pub fn stop(m: *Machine) void {
    m.teardown();
    if (m.getState() != .created) m.state.store(.stopped, .release);
}

pub fn pause(m: *Machine) void {
    if (m.getState() != .running) return;
    m.want.store(want_pause, .seq_cst);
    m.cancelAll();
    const n: u32 = @intCast(m.vcpus.len);
    while (true) {
        const p = m.parked.load(.seq_cst);
        if (p >= n or m.getState() != .running) break;
        _ = WaitOnAddress(&m.parked.raw, &p, 4, 1000);
    }
    if (m.getState() == .running) m.state.store(.paused, .release);
}

pub fn @"resume"(m: *Machine) void {
    if (m.getState() != .paused) return;
    m.state.store(.running, .release);
    m.want.store(want_run, .seq_cst);
    WakeByAddressAll(&m.want.raw);
}

fn cancelAll(m: *Machine) void {
    const p = m.part orelse return;
    for (m.vcpus) |*v| _ = WHvCancelRunVirtualProcessor(p, v.index, 0);
}

fn teardown(m: *Machine) void {
    m.want.store(want_stop, .seq_cst);
    WakeByAddressAll(&m.want.raw);
    m.cancelAll();
    for (m.vcpus) |*v| if (v.thread) |t| {
        t.join();
        v.thread = null;
    };
    for (m.vcpus) |*v| {
        if (v.emu) |e| _ = WHvEmulatorDestroyEmulator(e);
        if (m.part) |p| _ = WHvDeleteVirtualProcessor(p, v.index);
    }
    if (m.vcpus.len != 0) m.alloc.free(m.vcpus);
    m.vcpus = &.{};
    if (m.devices.len != 0) {
        m.vs.reset();
        m.alloc.free(m.devices);
    }
    m.devices = &.{};
    for (m.ninep_state) |*n| {
        n.server.deinit();
        if (m.cfg.virtiofs) n.fs.deinit();
    }
    if (m.ninep_state.len != 0) m.alloc.free(m.ninep_state);
    m.ninep_state = &.{};
    if (m.part) |p| _ = WHvDeletePartition(p);
    m.part = null;
    if (m.mem.size != 0) _ = VirtualFree(m.mem.base, 0, 0x8000);
    m.mem = .{ .base = undefined, .size = 0 };
    m.con_pending.clearRetainingCapacity();
    m.ioapic = .{};
    m.uart = .{};
}

fn fail(what: []const u8, hr: HRESULT) Fail {
    _ = hr;
    why = what;
    return error.Setup;
}

fn setup(m: *Machine) Fail!void {
    var p: Partition = undefined;
    if (WHvCreatePartition(&p) < 0) return fail("WHvCreatePartition", 0);
    m.part = p;
    const cpus: u32 = m.cfg.cpus;
    if (WHvSetPartitionProperty(p, prop_processor_count, &cpus, 4) < 0) return fail("the processor count of the partition", 0);
    const xapic: u32 = 1;
    if (WHvSetPartitionProperty(p, prop_local_apic_mode, &xapic, 4) < 0) return fail("the local APIC of the partition", 0);
    if (WHvSetupPartition(p) < 0) return fail("WHvSetupPartition", 0);
    const size: u64 = @as(u64, m.cfg.memory_mb) << 20;
    // MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE: Windows gives a page on
    // the first touch.
    const base = VirtualAlloc(null, @intCast(size), 0x3000, 0x04) orelse {
        why = "no host memory for the guest";
        return error.Memory;
    };
    m.mem = .{ .base = @ptrCast(base), .size = size };
    if (WHvMapGpaRange(p, base, 0, size, map_rwx) < 0) return fail("WHvMapGpaRange", 0);
    populate(p, size);
}

/// The hypervisor fills its map of a guest page on the first touch of the
/// guest, with no exit to this monitor, and the decompressor of the kernel
/// and the first allocations of the kernel touch thousands of pages. A
/// guest of 256 MB on an Intel Core i7-1165G7 took 50 ms from its start
/// to its first exit with an lz4 kernel, and 4 ms when the two ends of its
/// memory had their map first. Here the advice of `WHvAdviseGpaRange`
/// fills 32 MB at each end: the kernel loads at 16 MB and unpacks above
/// it, and the initramfs and the first allocations of the kernel are at
/// the top. The call came after the rest of the API (Windows 10 2004), so
/// this monitor finds it at run time, and a host without it starts the
/// guest with no advice.
fn populate(p: Partition, size: u64) void {
    const Range = extern struct { gpa: u64, size: u64 };
    // WHV_ADVISE_GPA_RANGE_POPULATE: the flag Prefetch, and the access
    // WHvMemoryAccessWrite.
    const Advice = extern struct { flags: u32, access: u32 };
    const Fn = *const fn (Partition, [*]const Range, u32, u32, *const Advice, u32) callconv(.winapi) HRESULT;
    const lib = GetModuleHandleA("winhvplatform.dll") orelse return;
    const f: Fn = @ptrCast(GetProcAddress(lib, "WHvAdviseGpaRange") orelse return);
    const each: u64 = @min(size / 2, populate_end);
    const ranges = [2]Range{ .{ .gpa = 0, .size = each }, .{ .gpa = size - each, .size = each } };
    const advice: Advice = .{ .flags = 1, .access = 1 };
    // WHvAdviseGpaRangeCodePopulate. A failure leaves the map to the
    // first touch, as before.
    _ = f(p, &ranges, ranges.len, 0, &advice, @sizeOf(Advice));
}

/// The part at each end of the guest memory that `populate` fills.
const populate_end: u64 = 32 << 20;

extern "kernel32" fn GetModuleHandleA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(lib: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

/// The command line of the guest: the one of the configuration, then the
/// options of this monitor and the list of the virtio-mmio devices. The
/// guest has no ACPI and no PCI, and the rate of its TSC comes from the
/// host.
fn cmdline(m: *Machine) []const u8 {
    const S = struct {
        threadlocal var buf: [boot.cmdline_max + 512]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    w.print("{s} acpi=off pci=off reboot=k panic=-1 nomodule tsc_early_khz={d}", .{ m.cfg.cmdline, tscKhz() }) catch return S.buf[0..0];
    for (0..m.deviceCount()) |i| w.print(" virtio_mmio.device=4K@0x{x}:{d}", .{ mmio_base + mmio_size * i, irqs[i] }) catch return w.buffered();
    return w.buffered();
}

fn makeVcpus(m: *Machine) Fail!void {
    const p = m.part.?;
    m.vcpus = try m.alloc.alloc(Vcpu, m.cfg.cpus);
    for (m.vcpus, 0..) |*v, i| v.* = .{ .machine = m, .index = @intCast(i) };
    for (m.vcpus) |*v| {
        if (WHvCreateVirtualProcessor(p, v.index, 0) < 0) return fail("WHvCreateVirtualProcessor", 0);
        if (WHvEmulatorCreateEmulator(&callbacks, &v.emu) < 0) return fail("WHvEmulatorCreateEmulator", 0);
    }
    // The boot CPU in long mode at the 64-bit entry point.
    const code: RegValue = .{ .seg = .{ .base = 0, .limit = 0xffffffff, .selector = 0x10, .attributes = 0xa09b } };
    const data: RegValue = .{ .seg = .{ .base = 0, .limit = 0xffffffff, .selector = 0x18, .attributes = 0xc093 } };
    const names = [_]u32{ r.cs, r.ds, r.es, r.ss, r.fs, r.gs, r.tr, r.gdtr, r.cr0, r.cr3, r.cr4, r.efer, r.rip, r.rsi, r.rsp, r.rflags };
    const values = [_]RegValue{
        code,                                                                         data,                                                                       data, data, data, data,
        // The task register: a busy 64-bit TSS, which an entry in long
        // mode needs.
        .{ .seg = .{ .base = 0, .limit = 0x67, .selector = 0, .attributes = 0x8b } }, .{ .table = .{ .pad = .{ 0, 0, 0 }, .limit = 31, .base = boot.gdt_addr } },
        .{ .reg64 = 0x80000033 }, // PG, NE, ET, MP, PE
        .{ .reg64 = boot.pml4_addr },
        .{ .reg64 = 0x20 }, // PAE
        .{ .reg64 = 0x500 }, // LME, LMA
        .{ .reg64 = m.entry },
        .{ .reg64 = boot.zero_page },
        .{ .reg64 = 0x8ff0 },
        .{ .reg64 = 2 },
    };
    if (WHvSetVirtualProcessorRegisters(p, 0, &names, names.len, &values) < 0) return fail("the registers of the boot CPU", 0);
}

// ---------------------------------------------------------------------
// The devices

fn deviceCount(m: *const Machine) usize {
    return 2 + m.cfg.disks.len + m.cfg.shares.len + @intFromBool(m.cfg.entropy);
}

fn makeDevices(m: *Machine) Fail!void {
    const n = m.deviceCount();
    m.devices = try m.alloc.alloc(Device, n);
    m.devices[0] = Device.console(irqs[0], .{ .ctx = m, .write = consoleWrite, .rx_ready = consoleReady });
    m.devices[1] = Device.vsock(irqs[1], &m.vs);
    for (m.cfg.disks, 0..) |*d, i| {
        var size: i64 = 0;
        if (GetFileSizeEx(d.handle, &size) == 0 or size < 0) {
            why = "the size of a disk";
            return error.Setup;
        }
        m.devices[2 + i] = Device.blk(irqs[2 + i], .{ .ctx = @constCast(d), .size = @intCast(size), .read_only = d.read_only, .read = diskRead, .write = diskWrite, .flush = diskFlush });
    }
    // The 9p servers run on the vCPU thread, so they use an allocator
    // that is safe across threads.
    m.ninep_state = try m.alloc.alloc(NinepState, m.cfg.shares.len);
    for (m.cfg.shares, m.ninep_state, 0..) |sh, *st, i| {
        st.share = .{ .root = sh.fd, .read_only = sh.read_only };
        st.server = ninep.Server.init(std.heap.smp_allocator, st.share.fs());
        var tag_buf: [16]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "share{d}", .{i}) catch unreachable;
        const k = 2 + m.cfg.disks.len + i;
        if (m.cfg.virtiofs) {
            st.fs = fuse.Server.init(std.heap.smp_allocator, st.share.fs());
            m.devices[k] = Device.virtiofs(irqs[k], &st.fs, tag);
        } else m.devices[k] = Device.ninep(irqs[k], &st.server, tag);
    }
    if (m.cfg.entropy) m.devices[n - 1] = Device.rng(irqs[n - 1], fillRandom);
}

fn host(m: *Machine) virtio.Host {
    return .{ .ctx = m, .mem = m.mem, .interrupt = irqEdge };
}

/// An edge on an ISA interrupt line of the guest.
fn irqEdge(ctx: *anyopaque, irq: u32) void {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    m.ioapic_lock.lock();
    defer m.ioapic_lock.unlock();
    m.ioapic.raise(m.part orelse return, irq);
}

/// Puts bytes of input in the console of the guest. Gives the count that
/// went in now; the rest waits for receive buffers.
pub fn consoleInput(m: *Machine, bytes: []const u8) void {
    if (m.devices.len == 0) return;
    const d = &m.devices[0];
    d.lock.lock();
    defer d.lock.unlock();
    m.con_pending.appendSlice(m.alloc, bytes) catch return;
    m.consolePush(d);
}

fn consolePush(m: *Machine, d: *Device) void {
    if (m.con_pending.items.len == 0 or d.status & virtio.status_driver_ok == 0) return;
    const h = m.host();
    const took = virtio.Console.push(d, &h, m.con_pending.items);
    m.con_pending.replaceRangeAssumeCapacity(0, took, &.{});
}

fn consoleWrite(ctx: *anyopaque, bytes: []const u8) void {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    m.cfg.console.write(m.cfg.console.ctx, bytes);
}

/// The driver added receive buffers: the pending input goes in. The
/// device lock is held.
fn consoleReady(ctx: *anyopaque) void {
    const m: *Machine = @ptrCast(@alignCast(ctx));
    m.consolePush(&m.devices[0]);
}

/// Opens a vsock stream to `port` of the guest. Gives its number, or null
/// when the device has no free stream or the guest does not run.
pub fn connect(m: *Machine, port: u32) ?u32 {
    if (m.devices.len < 2) return null;
    const d = &m.devices[1];
    const h = m.host();
    d.lock.lock();
    defer d.lock.unlock();
    return m.vs.connect(d, &h, port);
}

/// Sends bytes on a vsock stream. Gives the count that went in.
pub fn send(m: *Machine, conn: u32, bytes: []const u8) usize {
    if (m.devices.len < 2) return 0;
    const d = &m.devices[1];
    const h = m.host();
    d.lock.lock();
    defer d.lock.unlock();
    return m.vs.send(d, &h, conn, bytes);
}

/// Ends a vsock stream.
pub fn close(m: *Machine, conn: u32) void {
    if (m.devices.len < 2) return;
    const d = &m.devices[1];
    const h = m.host();
    d.lock.lock();
    defer d.lock.unlock();
    m.vs.close(d, &h, conn);
}

fn fillRandom(buf: []u8) usize {
    // BCRYPT_USE_SYSTEM_PREFERRED_RNG
    if (BCryptGenRandom(null, buf.ptr, @intCast(buf.len), 2) != 0) return 0;
    return buf.len;
}

fn diskIo(d: *const Disk, b: []u8, pos: u64, write: bool) bool {
    var off: usize = 0;
    while (off < b.len) {
        const at = pos + off;
        var ov: Overlapped = .{ .offset = @truncate(at), .offset_high = @truncate(at >> 32) };
        const n: u32 = @intCast(@min(b.len - off, 1 << 30));
        var done: u32 = 0;
        const ok = if (write) WriteFile(d.handle, b[off..].ptr, n, &done, &ov) else ReadFile(d.handle, b[off..].ptr, n, &done, &ov);
        if (ok == 0) {
            // A read at the end of the file gives zeros.
            if (!write) {
                @memset(b[off..], 0);
                return true;
            }
            return false;
        }
        if (done == 0) {
            if (write) return false;
            @memset(b[off..], 0);
            return true;
        }
        off += done;
    }
    return true;
}

fn diskRead(ctx: *anyopaque, buf: []u8, off: u64) bool {
    return diskIo(@ptrCast(@alignCast(ctx)), buf, off, false);
}

fn diskWrite(ctx: *anyopaque, buf: []const u8, off: u64) bool {
    return diskIo(@ptrCast(@alignCast(ctx)), @constCast(buf), off, true);
}

fn diskFlush(ctx: *anyopaque) void {
    const d: *const Disk = @ptrCast(@alignCast(ctx));
    _ = FlushFileBuffers(d.handle);
}

// ---------------------------------------------------------------------
// The vCPU threads

fn vcpuMain(v: *Vcpu) void {
    const m = v.machine;
    const p = m.part.?;
    while (true) {
        const w = m.want.load(.seq_cst);
        if (w == want_stop) return;
        if (w == want_pause) {
            _ = m.parked.fetchAdd(1, .seq_cst);
            WakeByAddressAll(&m.parked.raw);
            const pause_v: u32 = want_pause;
            while (m.want.load(.seq_cst) == want_pause) _ = WaitOnAddress(&m.want.raw, &pause_v, 4, 1000);
            _ = m.parked.fetchSub(1, .seq_cst);
            continue;
        }
        var ctx: ExitContext = undefined;
        if (WHvRunVirtualProcessor(p, v.index, &ctx, @sizeOf(ExitContext)) < 0) return m.guestEnd("WHvRunVirtualProcessor failed");
        var status: u32 = 1;
        switch (ctx.reason) {
            exit_io => _ = WHvEmulatorTryIoEmulation(v.emu.?, v, &ctx.vp, &ctx.data, &status),
            exit_memory => _ = WHvEmulatorTryMmioEmulation(v.emu.?, v, &ctx.vp, &ctx.data, &status),
            exit_halt, exit_canceled => {},
            exit_unrecoverable => return m.guestEnd(""), // a triple fault: a reboot of the guest
            exit_invalid_registers => return m.guestEnd("the registers of a vCPU are not valid"),
            else => return m.guestEnd("an exit of the hypervisor with no handler"),
        }
        if (status & 1 == 0) return m.guestEnd("the emulator could not run an access of the guest");
        if (m.want.load(.seq_cst) == want_stop) return;
    }
}

/// The guest stopped by itself (`text` is empty) or failed: each vCPU
/// thread ends.
fn guestEnd(m: *Machine, text: []const u8) void {
    if (m.want.cmpxchgStrong(want_run, want_stop, .seq_cst, .seq_cst) != null and
        m.want.cmpxchgStrong(want_pause, want_stop, .seq_cst, .seq_cst) != null) return;
    m.fail_text = text;
    m.state.store(if (text.len == 0) .stopped else .failed, .release);
    WakeByAddressAll(&m.want.raw);
    WakeByAddressAll(&m.parked.raw);
    m.cancelAll();
}

fn vcpuOf(ctx: ?*anyopaque) *Vcpu {
    return @ptrCast(@alignCast(ctx.?));
}

fn ioCallback(ctx: ?*anyopaque, io: *IoAccess) callconv(.winapi) HRESULT {
    const v = vcpuOf(ctx);
    const m = v.machine;
    const write = io.direction == 1;
    if (io.port >= 0x3f8 and io.port < 0x400) {
        m.uart_lock.lock();
        const reg = io.port - 0x3f8;
        var out: ?u8 = null;
        if (write) {
            if (reg == 0 and !m.uart.dlab() and !m.uart.loop()) out = @truncate(io.data);
            m.uart.write(reg, @truncate(io.data));
        } else io.data = m.uart.read(reg);
        const raise = m.uart.pending();
        m.uart_lock.unlock();
        if (out) |b| m.cfg.console.write(m.cfg.console.ctx, &.{b});
        if (raise) irqEdge(m, 4);
        return 0;
    }
    if (io.port == 0x64 and write and io.data & 0xff == 0xfe) {
        m.guestEnd("");
        return 0;
    }
    if (!write) io.data = if (io.port == 0x60 or io.port == 0x64) 0xff else 0;
    return 0;
}

fn memoryCallback(ctx: ?*anyopaque, acc: *MemoryAccess) callconv(.winapi) HRESULT {
    const v = vcpuOf(ctx);
    const m = v.machine;
    const write = acc.direction == 1;
    const len: usize = @min(acc.size, 8);
    if (acc.gpa >= boot.ioapic_addr and acc.gpa < boot.ioapic_addr + 0x20) {
        const off: u32 = @intCast(acc.gpa - boot.ioapic_addr);
        m.ioapic_lock.lock();
        defer m.ioapic_lock.unlock();
        if (write) {
            m.ioapic.write(off, std.mem.readInt(u32, acc.data[0..4], .little));
        } else std.mem.writeInt(u32, acc.data[0..4], m.ioapic.read(off), .little);
        return 0;
    }
    if (acc.gpa >= mmio_base and acc.gpa < mmio_base + mmio_size * m.devices.len) {
        const d = &m.devices[@intCast((acc.gpa - mmio_base) / mmio_size)];
        const off = (acc.gpa - mmio_base) % mmio_size;
        const h = m.host();
        d.lock.lock();
        defer d.lock.unlock();
        if (write) d.write(&h, off, acc.data[0..len]) else d.read(off, acc.data[0..len]);
        return 0;
    }
    if (!write) @memset(&acc.data, 0xff);
    return 0;
}

fn getRegs(ctx: ?*anyopaque, names: [*]const u32, count: u32, values: [*]RegValue) callconv(.winapi) HRESULT {
    const v = vcpuOf(ctx);
    return WHvGetVirtualProcessorRegisters(v.machine.part.?, v.index, names, count, values);
}

fn setRegs(ctx: ?*anyopaque, names: [*]const u32, count: u32, values: [*]const RegValue) callconv(.winapi) HRESULT {
    const v = vcpuOf(ctx);
    return WHvSetVirtualProcessorRegisters(v.machine.part.?, v.index, names, count, values);
}

fn translate(ctx: ?*anyopaque, gva: u64, flags: u32, result: *u32, gpa: *u64) callconv(.winapi) HRESULT {
    const v = vcpuOf(ctx);
    var res: [2]u32 = .{ 0, 0 };
    const hr = WHvTranslateGva(v.machine.part.?, v.index, gva, flags, &res, gpa);
    result.* = res[0];
    return hr;
}

/// The rate of the TSC of the host in kHz, over 20 ms of the performance
/// counter. The guest has no PIT to measure it.
fn tscKhz() u64 {
    const S = struct {
        var khz = std.atomic.Value(u64).init(0);
    };
    const known = S.khz.load(.monotonic);
    if (known != 0) return known;
    var f: i64 = 0;
    var c0: i64 = 0;
    var c1: i64 = 0;
    _ = QueryPerformanceFrequency(&f);
    _ = QueryPerformanceCounter(&c0);
    const t0 = rdtsc();
    while (true) {
        _ = QueryPerformanceCounter(&c1);
        if (c1 - c0 >= @divTrunc(f, 50)) break;
    }
    const t1 = rdtsc();
    const us: u64 = @intCast(@divTrunc((c1 - c0) * 1_000_000, f));
    const khz = (t1 - t0) * 1000 / us;
    S.khz.store(khz, .monotonic);
    return khz;
}

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// An I/O APIC at 0xfec00000 with 24 pins: the select register at 0,
/// the window at 0x10, the ID (0), the version (1), and a redirection
/// entry of two words for each pin from 0x10. The ID is the one of the MP
/// table of `boot.zig`: the count of CPUs.
const IoApic = struct {
    sel: u32 = 0,
    id: u32 = 1 << 24,
    /// The redirection entries, masked at the start.
    redir: [24]u64 = @splat(1 << 16),

    fn read(io: *const IoApic, off: u32) u32 {
        if (off == 0) return io.sel;
        if (off != 0x10) return 0;
        return switch (io.sel) {
            0, 2 => io.id,
            1 => 0x00170011, // 24 entries, version 0x11
            0x10...0x3f => blk: {
                const e = io.redir[(io.sel - 0x10) / 2];
                break :blk if (io.sel & 1 == 0) @truncate(e) else @truncate(e >> 32);
            },
            else => 0,
        };
    }

    fn write(io: *IoApic, off: u32, v: u32) void {
        if (off == 0) {
            io.sel = v & 0xff;
            return;
        }
        if (off != 0x10) return;
        switch (io.sel) {
            0 => io.id = v & 0x0f000000,
            0x10...0x3f => {
                const k = (io.sel - 0x10) / 2;
                if (io.sel & 1 == 0) {
                    io.redir[k] = (io.redir[k] & 0xffffffff00000000) | v;
                } else io.redir[k] = (io.redir[k] & 0xffffffff) | (@as(u64, v) << 32);
            },
            else => {},
        }
    }

    fn raise(io: *const IoApic, p: Partition, pin: u32) void {
        if (pin >= io.redir.len) return;
        const e = io.redir[pin];
        if (e & (1 << 16) != 0) return;
        const ctl: InterruptControl = .{
            .bits = ((e >> 8) & 7) | (((e >> 11) & 1) << 8),
            .destination = @intCast(e >> 56),
            .vector = @intCast(e & 0xff),
        };
        _ = WHvRequestInterrupt(p, &ctl, @sizeOf(InterruptControl));
    }
};

/// A 16550A at 0x3f8 with the registers that the probe of the 8250
/// driver reads back, and the interrupt of its empty transmitter: a byte
/// goes out at once, so with that interrupt on, it waits until a read of
/// the interrupt ID gives it. In loopback the modem status gives the bits
/// of the modem control, as the probe tests.
const Uart = struct {
    ier: u8 = 0,
    lcr: u8 = 0,
    mcr: u8 = 0,
    scr: u8 = 0,
    dll: u8 = 0,
    dlm: u8 = 0,
    fifo: bool = false,
    thre: bool = false,

    fn dlab(u: *const Uart) bool {
        return u.lcr & 0x80 != 0;
    }

    fn loop(u: *const Uart) bool {
        return u.mcr & 0x10 != 0;
    }

    fn pending(u: *const Uart) bool {
        return u.ier & 0x02 != 0 and u.thre;
    }

    fn write(u: *Uart, reg: u16, v: u8) void {
        switch (reg) {
            0 => if (u.dlab()) {
                u.dll = v;
            } else {
                u.thre = true;
            },
            1 => if (u.dlab()) {
                u.dlm = v;
            } else {
                if (v & 0x02 != 0 and u.ier & 0x02 == 0) u.thre = true;
                u.ier = v & 0x0f;
            },
            2 => u.fifo = v & 1 != 0,
            3 => u.lcr = v,
            4 => u.mcr = v & 0x1f,
            7 => u.scr = v,
            else => {},
        }
    }

    fn read(u: *Uart, reg: u16) u8 {
        return switch (reg) {
            0 => if (u.dlab()) u.dll else 0,
            1 => if (u.dlab()) u.dlm else u.ier,
            2 => blk: {
                const fifo: u8 = if (u.fifo) 0xc0 else 0;
                if (u.pending()) {
                    u.thre = false;
                    break :blk fifo | 0x02;
                }
                break :blk fifo | 0x01;
            },
            3 => u.lcr,
            4 => u.mcr,
            5 => 0x60,
            6 => if (u.loop())
                ((u.mcr & 1) << 5) | ((u.mcr & 2) << 3) | ((u.mcr & 4) << 4) | ((u.mcr & 8) << 4)
            else
                0xb0,
            7 => u.scr,
            else => 0,
        };
    }
};

test "whp: the I/O APIC keeps its entries, and the UART its probe" {
    var io: IoApic = .{};
    io.write(0, 0x10 + 2 * 4);
    io.write(0x10, 0x31);
    io.write(0, 0x10 + 2 * 4 + 1);
    io.write(0x10, 0x01000000);
    io.write(0, 0x10 + 2 * 4);
    try std.testing.expectEqual(@as(u32, 0x31), io.read(0x10));
    io.write(0, 1);
    try std.testing.expectEqual(@as(u32, 0x00170011), io.read(0x10));
    var u: Uart = .{};
    u.write(7, 0x5a);
    try std.testing.expectEqual(@as(u8, 0x5a), u.read(7));
    u.write(4, 0x10 | 0x0a);
    try std.testing.expectEqual(@as(u8, 0x90), u.read(6) & 0xf0);
    u.write(4, 0);
    u.write(1, 0x02);
    try std.testing.expectEqual(@as(u8, 0x02), u.read(2));
    try std.testing.expectEqual(@as(u8, 0x01), u.read(2));
}

/// The host side of the boot test: the console and the vsock stream,
/// which the vCPU thread fills.
const TestHost = struct {
    lock: virtio.Lock = .{},
    console: [64 * 1024]u8 = undefined,
    console_len: usize = 0,
    got: [256]u8 = undefined,
    got_len: usize = 0,
    connected: bool = false,
    ended: bool = false,

    fn write(ctx: *anyopaque, bytes: []const u8) void {
        const t: *TestHost = @ptrCast(@alignCast(ctx));
        t.lock.lock();
        defer t.lock.unlock();
        const k = @min(bytes.len, t.console.len - t.console_len);
        @memcpy(t.console[t.console_len..][0..k], bytes[0..k]);
        t.console_len += k;
    }
    fn data(ctx: *anyopaque, _: u32, bytes: []const u8) void {
        const t: *TestHost = @ptrCast(@alignCast(ctx));
        t.lock.lock();
        defer t.lock.unlock();
        const k = @min(bytes.len, t.got.len - t.got_len);
        @memcpy(t.got[t.got_len..][0..k], bytes[0..k]);
        t.got_len += k;
    }
    fn event(ctx: *anyopaque, _: u32, e: vsock.Event) void {
        const t: *TestHost = @ptrCast(@alignCast(ctx));
        t.lock.lock();
        defer t.lock.unlock();
        if (e == .connected) t.connected = true else t.ended = true;
    }

    /// Waits up to `ms` for `cond`.
    fn wait(t: *TestHost, ms: u64, cond: *const fn (*TestHost) bool) bool {
        const end = nowNs() + ms * std.time.ns_per_ms;
        while (nowNs() < end) {
            t.lock.lock();
            const done = cond(t);
            t.lock.unlock();
            if (done) return true;
            std.Thread.yield() catch {};
        }
        return false;
    }
};

test "whp: the guest boots and its agent answers on vsock" {
    if (comptime !supported) return error.SkipZigTest;
    probe() catch return error.SkipZigTest;
    const a = std.testing.allocator;
    const dir = std.Io.Dir.cwd();
    // The x86-64 guest of tools/vm-guest (the artifact vm-guest-x86_64).
    const kernel = dir.readFileAlloc(std.testing.io, "zig-out/vm-guest/bzImage", a, .limited(64 << 20)) catch return error.SkipZigTest;
    defer a.free(kernel);
    const initrd = dir.readFileAlloc(std.testing.io, "zig-out/vm-guest/initramfs.cpio.gz", a, .limited(64 << 20)) catch return error.SkipZigTest;
    defer a.free(initrd);
    const t = try a.create(TestHost);
    defer a.destroy(t);
    t.* = .{};
    const m = try init(a, .{
        .kernel = kernel,
        .initrd = initrd,
        .cmdline = "console=hvc0 quiet",
        .memory_mb = 128,
        .console = .{ .ctx = t, .write = TestHost.write },
        .vsock = .{ .ctx = t, .data = TestHost.data, .event = TestHost.event },
    });
    defer m.deinit();
    try m.start();
    const ready = t.wait(10_000, struct {
        fn f(x: *TestHost) bool {
            return std.mem.indexOf(u8, x.console[0..x.console_len], "ztvm: ready") != null;
        }
    }.f);
    if (!ready) std.debug.print("console: {s}\n", .{t.console[0..t.console_len]});
    try std.testing.expect(ready);
    // The probe of the agent (port 1025, docs/dev/vm-agent.md) sends 16
    // bytes of its boot clock, then echoes each byte.
    // The init starts the agent after its ready line, so a refused stream
    // is tried again, as `ztcl::vm vsock` does.
    var conn: u32 = 0;
    var tries: usize = 0;
    while (true) : (tries += 1) {
        conn = m.connect(1025) orelse return error.NoStream;
        try std.testing.expect(t.wait(5000, struct {
            fn f(x: *TestHost) bool {
                return x.connected or x.ended;
            }
        }.f));
        if (t.connected or tries >= 100) break;
        t.lock.lock();
        t.ended = false;
        t.lock.unlock();
        // 50 ms before the next try.
        _ = t.wait(50, struct {
            fn f(_: *TestHost) bool {
                return false;
            }
        }.f);
    }
    if (!t.connected) std.debug.print("console: {s}\n", .{t.console[0..t.console_len]});
    try std.testing.expect(t.connected);
    try std.testing.expectEqual(@as(usize, 4), m.send(conn, "ping"));
    try std.testing.expect(t.wait(5000, struct {
        fn f(x: *TestHost) bool {
            return x.got_len >= 20;
        }
    }.f));
    try std.testing.expectEqualStrings("ping", t.got[16..20]);
    m.close(conn);
    m.stop();
    try std.testing.expectEqual(State.stopped, m.getState());
}

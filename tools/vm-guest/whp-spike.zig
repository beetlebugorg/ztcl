//! The spike of ztcl::vm on the Windows Hypervisor Platform (ztcl#203):
//! boots the x86-64 guest of `build.sh` in a partition of
//! WinHvPlatform.dll and prints its serial console until the init of the
//! guest prints its ready line.
//!
//!   whp-spike BZIMAGE BUSYBOX INIT ?MEMORY_MB?
//!
//! The host gives the guest one CPU, its memory at guest address 0, and
//! the local APIC of the hypervisor (xAPIC emulation). It boots the kernel
//! with the 64-bit boot protocol of Linux: the protected-mode part of the
//! bzImage at 1 MiB, a zero page with the setup header, the command line,
//! and an e820 table, page tables that map the first 1 GiB with 2 MiB
//! pages, a GDT with the code segment 0x10 and the data segment 0x18, and
//! the CPU in long mode at the 64-bit entry with RSI at the zero page.
//!
//! The guest has no ACPI and no PCI. An MP table at 0xf0000 gives the
//! kernel the CPU, the ISA bus, and an I/O APIC at 0xfec00000 (`IoApic`)
//! with the ISA IRQs on its pins. A raise of a pin goes to the local APIC
//! with `WHvRequestInterrupt`.
//!
//! The emulator of WinHvEmulation.dll decodes each port and MMIO exit
//! and calls `Machine` for the access. The console is a 16550A at port
//! 0x3f8 (`Uart`) with the registers that the probe of the 8250 driver
//! reads back and the interrupt of its empty transmitter on IRQ 4. A
//! write to its data register is a byte of the console. The ports of the
//! i8042 read as 0xff, a bus with no device, and each other port reads as
//! 0 and ignores writes, so the probes of the PIC, the PIT, the CMOS, and
//! the i8042 of the kernel find no device.
//!
//! The initramfs is an uncompressed cpio archive (newc) that the spike
//! makes in memory: /init, /bin/busybox, and /dev/console.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

const HRESULT = i32;
const Partition = *anyopaque;

extern "WinHvPlatform" fn WHvCreatePartition(p: *Partition) callconv(.winapi) HRESULT;
extern "WinHvPlatform" fn WHvSetPartitionProperty(p: Partition, code: u32, value: *const anyopaque, size: u32) callconv(.winapi) HRESULT;
extern "WinHvPlatform" fn WHvSetupPartition(p: Partition) callconv(.winapi) HRESULT;
extern "WinHvPlatform" fn WHvDeletePartition(p: Partition) callconv(.winapi) HRESULT;
extern "WinHvPlatform" fn WHvMapGpaRange(p: Partition, host: *anyopaque, gpa: u64, size: u64, flags: u32) callconv(.winapi) HRESULT;
extern "WinHvPlatform" fn WHvCreateVirtualProcessor(p: Partition, index: u32, flags: u32) callconv(.winapi) HRESULT;
extern "WinHvPlatform" fn WHvRunVirtualProcessor(p: Partition, index: u32, exit: *ExitContext, size: u32) callconv(.winapi) HRESULT;
extern "WinHvPlatform" fn WHvSetVirtualProcessorRegisters(p: Partition, index: u32, names: [*]const u32, count: u32, values: [*]const RegValue) callconv(.winapi) HRESULT;
extern "WinHvPlatform" fn WHvGetVirtualProcessorRegisters(p: Partition, index: u32, names: [*]const u32, count: u32, values: [*]RegValue) callconv(.winapi) HRESULT;
extern "kernel32" fn VirtualAlloc(at: ?*anyopaque, size: usize, kind: u32, protect: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn QueryPerformanceCounter(t: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(f: *i64) callconv(.winapi) i32;

const prop_processor_count: u32 = 0x1fff;
const prop_local_apic_mode: u32 = 0x1005;
const map_rwx: u32 = 1 | 2 | 4;

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
    const rax: u32 = 0x00;
};

/// WHV_REGISTER_VALUE: 16 bytes.
const RegValue = extern union {
    // WHV_REGISTER_VALUE is 16-byte aligned.
    _align: u128 align(16),
    reg64: u64,
    seg: extern struct { base: u64, limit: u32, selector: u16, attributes: u16 },
    table: extern struct { pad: [3]u16, limit: u16, base: u64 },
    raw: [16]u8,
};

/// WHV_RUN_VP_EXIT_CONTEXT: the reason at 0, the context of the CPU at 8
/// (its byte 2 has the length of the instruction in its low 4 bits),
/// and the data of the reason at 48.
const ExitContext = extern struct {
    reason: u32,
    reserved: u32,
    vp: [40]u8,
    data: [176]u8,
};

const exit_io: u32 = 2;
const exit_memory: u32 = 1;
const exit_halt: u32 = 8;

// The places in the memory of the guest.
const gdt_at: u64 = 0x500;
const zero_page_at: u64 = 0x7000;
const pml4_at: u64 = 0x9000;
const cmdline_at: u64 = 0x20000;
const kernel_at: u64 = 0x100000;
const initrd_at: u64 = 0x4000000;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("whp-spike: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn check(hr: HRESULT, what: []const u8) void {
    if (hr < 0) fail("{s}: 0x{x:0>8}", .{ what, @as(u32, @bitCast(hr)) });
}

/// Appends a newc entry: a header of 13 hex fields, the name with its
/// zero byte, and the data, each padded to 4 bytes.
fn cpioEntry(out: *std.ArrayList(u8), a: std.mem.Allocator, ino: u32, name: []const u8, mode: u32, data: []const u8) !void {
    return cpioNode(out, a, ino, name, mode, data, 0, 0);
}

/// An entry with the device numbers `major` and `minor` of a device node.
fn cpioNode(out: *std.ArrayList(u8), a: std.mem.Allocator, ino: u32, name: []const u8, mode: u32, data: []const u8, major: u32, minor: u32) !void {
    var hdr: [110]u8 = undefined;
    _ = try std.fmt.bufPrint(&hdr, "070701{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}", .{
        ino, mode, 0, 0, 1, 0, data.len, 0, 0, major, minor, name.len + 1, 0,
    });
    try out.appendSlice(a, &hdr);
    try out.appendSlice(a, name);
    try out.append(a, 0);
    while (out.items.len % 4 != 0) try out.append(a, 0);
    try out.appendSlice(a, data);
    while (out.items.len % 4 != 0) try out.append(a, 0);
}

fn initramfs(a: std.mem.Allocator, busybox: []const u8, init: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const dir = 0o040755;
    try cpioEntry(&out, a, 1, "bin", dir, "");
    try cpioEntry(&out, a, 2, "sbin", dir, "");
    try cpioEntry(&out, a, 3, "dev", dir, "");
    // The console of the first process, which the kernel opens before a
    // mount of devtmpfs.
    try cpioNode(&out, a, 10, "dev/console", 0o020600, "", 5, 1);
    try cpioEntry(&out, a, 4, "mnt", dir, "");
    try cpioEntry(&out, a, 5, "mnt/share", dir, "");
    try cpioEntry(&out, a, 6, "init", 0o100755, init);
    try cpioEntry(&out, a, 7, "bin/busybox", 0o100755, busybox);
    try cpioEntry(&out, a, 9, "TRAILER!!!", 0, "");
    return out.items;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 4) fail("usage: whp-spike BZIMAGE BUSYBOX INIT ?MEMORY_MB?", .{});
    const mem_mb: u64 = if (args.len > 4) try std.fmt.parseInt(u64, args[4], 10) else 256;
    const dir = std.Io.Dir.cwd();
    const kernel = try dir.readFileAlloc(init.io, args[1], a, .limited(64 << 20));
    const busybox = try dir.readFileAlloc(init.io, args[2], a, .limited(16 << 20));
    const init_text = try dir.readFileAlloc(init.io, args[3], a, .limited(1 << 20));
    // The init is a shell script, with LF line ends for the guest.
    var init_lf: std.ArrayList(u8) = .empty;
    for (init_text) |c| if (c != '\r') try init_lf.append(a, c);
    const rd = try initramfs(a, busybox, init_lf.items);

    // The setup header of the bzImage.
    if (kernel.len < 0x1000 or !std.mem.eql(u8, kernel[0x202..0x206], "HdrS")) fail("{s} is not a bzImage", .{args[1]});
    const version = std.mem.readInt(u16, kernel[0x206..0x208], .little);
    const xlf = std.mem.readInt(u16, kernel[0x236..0x238], .little);
    if (version < 0x020c or xlf & 1 == 0) fail("the kernel has no 64-bit entry (version 0x{x}, xloadflags 0x{x})", .{ version, xlf });
    const setup_sects: u64 = if (kernel[0x1f1] == 0) 4 else kernel[0x1f1];
    const pm_off = (setup_sects + 1) * 512;
    const hdr_end = 0x202 + @as(usize, kernel[0x201]);

    // The memory of the guest.
    const mem_size = mem_mb << 20;
    const mem_ptr = VirtualAlloc(null, mem_size, 0x3000, 0x04) orelse fail("no memory for the guest", .{});
    const mem: [*]u8 = @ptrCast(mem_ptr);
    if (kernel_at + kernel.len > initrd_at or initrd_at + rd.len > mem_size) fail("the guest needs more memory", .{});
    @memcpy(mem[kernel_at..][0 .. kernel.len - pm_off], kernel[pm_off..]);
    @memcpy(mem[initrd_at..][0..rd.len], rd);

    // The zero page: the setup header of the file, and the fields of the loader.
    const zp = mem[zero_page_at..][0..4096];
    @memset(zp, 0);
    @memcpy(zp[0x1f1..hdr_end], kernel[0x1f1..hdr_end]);
    zp[0x210] = 0xff; // type_of_loader: undefined
    zp[0x211] |= 0x01 | 0x80; // loadflags: LOADED_HIGH, CAN_USE_HEAP
    std.mem.writeInt(u16, zp[0x224..0x226], 0xfe00, .little); // heap_end_ptr
    std.mem.writeInt(u32, zp[0x218..0x21c], @intCast(initrd_at), .little); // ramdisk_image
    std.mem.writeInt(u32, zp[0x21c..0x220], @intCast(rd.len), .little); // ramdisk_size
    std.mem.writeInt(u32, zp[0x228..0x22c], @intCast(cmdline_at), .little); // cmd_line_ptr
    var freq: i64 = 0;
    _ = QueryPerformanceFrequency(&freq);
    const cmdline = try std.fmt.allocPrint(a, "console=ttyS0 earlyprintk=serial,ttyS0 acpi=off pci=off reboot=t panic=-1 tsc_early_khz={d} rdinit=/init\x00", .{tscKhz()});
    @memcpy(mem[cmdline_at..][0..cmdline.len], cmdline);
    // The e820 table: the low memory, and the memory from 1 MiB.
    const e820 = [_][3]u64{ .{ 0, 0x9fc00, 1 }, .{ 0x100000, mem_size - 0x100000, 1 } };
    zp[0x1e8] = e820.len;
    for (e820, 0..) |e, k| {
        const at = 0x2d0 + 20 * k;
        std.mem.writeInt(u64, zp[at..][0..8], e[0], .little);
        std.mem.writeInt(u64, zp[at + 8 ..][0..8], e[1], .little);
        std.mem.writeInt(u32, zp[at + 16 ..][0..4], @intCast(e[2]), .little);
    }

    writeMpTable(mem);

    // The page tables: 1 GiB with 2 MiB pages, the same address in the guest.
    const pml4: [*]u64 = @ptrCast(@alignCast(mem + pml4_at));
    @memset(pml4[0 .. 3 * 512], 0);
    pml4[0] = (pml4_at + 0x1000) | 3;
    pml4[512] = (pml4_at + 0x2000) | 3;
    for (0..512) |k| pml4[1024 + k] = (k << 21) | 0x83;
    // The GDT: null, null, code 0x10, data 0x18.
    const gdt: [*]u64 = @ptrCast(@alignCast(mem + gdt_at));
    gdt[0] = 0;
    gdt[1] = 0;
    gdt[2] = 0x00af9a000000ffff;
    gdt[3] = 0x00cf92000000ffff;

    // The partition.
    var p: Partition = undefined;
    check(WHvCreatePartition(&p), "WHvCreatePartition");
    defer _ = WHvDeletePartition(p);
    const cpus: u32 = 1;
    check(WHvSetPartitionProperty(p, prop_processor_count, &cpus, 4), "the processor count");
    const xapic: u32 = 1;
    check(WHvSetPartitionProperty(p, prop_local_apic_mode, &xapic, 4), "the local APIC mode");
    check(WHvSetupPartition(p), "WHvSetupPartition");
    check(WHvMapGpaRange(p, mem_ptr, 0, mem_size, map_rwx), "WHvMapGpaRange");
    check(WHvCreateVirtualProcessor(p, 0, 0), "WHvCreateVirtualProcessor");

    // The CPU in long mode at the 64-bit entry.
    const code_seg: RegValue = .{ .seg = .{ .base = 0, .limit = 0xffffffff, .selector = 0x10, .attributes = 0xa09b } };
    const data_seg: RegValue = .{ .seg = .{ .base = 0, .limit = 0xffffffff, .selector = 0x18, .attributes = 0xc093 } };
    const names = [_]u32{ r.cs, r.ds, r.es, r.ss, r.fs, r.gs, r.tr, r.gdtr, r.cr0, r.cr3, r.cr4, r.efer, r.rip, r.rsi, r.rsp, r.rflags };
    const values = [_]RegValue{
        code_seg,                                                                     data_seg,                                                            data_seg, data_seg, data_seg, data_seg,
        // The task register: a busy 64-bit TSS, which an entry in long mode needs.
        .{ .seg = .{ .base = 0, .limit = 0x67, .selector = 0, .attributes = 0x8b } }, .{ .table = .{ .pad = .{ 0, 0, 0 }, .limit = 31, .base = gdt_at } },
        .{ .reg64 = 0x80000033 }, // PG, NE, ET, MP, PE
        .{ .reg64 = pml4_at },
        .{ .reg64 = 0x20 }, // PAE
        .{ .reg64 = 0x500 }, // LME, LMA
        .{ .reg64 = kernel_at + 0x200 },
        .{ .reg64 = zero_page_at },
        .{ .reg64 = 0x8000 },
        .{ .reg64 = 2 },
    };
    check(WHvSetVirtualProcessorRegisters(p, 0, &names, names.len, &values), "the registers of the CPU");

    var m: Machine = .{ .p = p, .a = a };
    _ = QueryPerformanceCounter(&m.t0);
    m.freq = freq;
    const callbacks: EmulatorCallbacks = .{
        .io = Machine.ioCallback,
        .memory = Machine.memoryCallback,
        .get = Machine.getRegs,
        .set = Machine.setRegs,
        .translate = Machine.translate,
    };
    var emu: *anyopaque = undefined;
    check(WHvEmulatorCreateEmulator(&callbacks, &emu), "WHvEmulatorCreateEmulator");
    while (!m.done) {
        var ctx: ExitContext = undefined;
        check(WHvRunVirtualProcessor(p, 0, &ctx, @sizeOf(ExitContext)), "WHvRunVirtualProcessor");
        m.exits += 1;
        var status: u32 = 0;
        switch (ctx.reason) {
            exit_io => check(WHvEmulatorTryIoEmulation(emu, &m, &ctx.vp, &ctx.data, &status), "WHvEmulatorTryIoEmulation"),
            exit_memory => check(WHvEmulatorTryMmioEmulation(emu, &m, &ctx.vp, &ctx.data, &status), "WHvEmulatorTryMmioEmulation"),
            exit_halt => {},
            else => {
                const rip = std.mem.readInt(u64, ctx.vp[24..32], .little);
                fail("exit reason 0x{x} at rip 0x{x} after {d} exits", .{ ctx.reason, rip, m.exits });
            },
        }
        if ((ctx.reason == exit_io or ctx.reason == exit_memory) and status & 1 == 0) {
            const gpa = std.mem.readInt(u64, ctx.data[24..32], .little);
            fail("the emulation of exit 0x{x} failed (status 0x{x}, gpa 0x{x})", .{ ctx.reason, status, gpa });
        }
    }
}

/// The devices of the guest, which the callbacks of the emulator of
/// WinHvEmulation.dll reach through their context.
const Machine = struct {
    p: Partition,
    a: std.mem.Allocator,
    uart: Uart = .{},
    ioapic: IoApic = .{},
    line: std.ArrayList(u8) = .empty,
    exits: u64 = 0,
    t0: i64 = 0,
    freq: i64 = 1,
    done: bool = false,

    fn of(ctx: ?*anyopaque) *Machine {
        return @ptrCast(@alignCast(ctx.?));
    }

    /// A byte of the console. The ready line of init ends the spike.
    fn console(m: *Machine, ch: u8) void {
        std.debug.print("{c}", .{ch});
        if (ch != '\n') {
            m.line.append(m.a, ch) catch {};
            return;
        }
        if (std.mem.indexOf(u8, m.line.items, "ztvm: ready") != null) {
            var t1: i64 = 0;
            _ = QueryPerformanceCounter(&t1);
            std.debug.print("whp-spike: the ready line after {d} ms and {d} exits\n", .{ @divTrunc((t1 - m.t0) * 1000, m.freq), m.exits });
            m.done = true;
        }
        m.line.clearRetainingCapacity();
    }

    /// Raises the interrupt of the UART on pin 4 of the I/O APIC when it waits.
    fn uartIrq(m: *Machine) void {
        if (m.uart.pending()) m.ioapic.raise(m.p, 4);
    }

    fn ioCallback(ctx: ?*anyopaque, io: *IoAccess) callconv(.winapi) HRESULT {
        const m = of(ctx);
        const write = io.direction == 1;
        if (io.port >= 0x3f8 and io.port <= 0x3ff) {
            const reg = io.port - 0x3f8;
            if (write) {
                if (reg == 0 and !m.uart.dlab() and !m.uart.loop()) m.console(@truncate(io.data));
                m.uart.write(reg, @truncate(io.data));
                m.uartIrq();
            } else io.data = m.uart.read(reg);
        } else if (!write) {
            // The ports of the i8042 read as a bus with no device (0xff), so
            // its probe ends at once, with no wait for its timeouts of about
            // 570 ms. Each other port reads as 0.
            io.data = if (io.port == 0x60 or io.port == 0x64) 0xff else 0;
        }
        return 0;
    }

    fn memoryCallback(ctx: ?*anyopaque, acc: *MemoryAccess) callconv(.winapi) HRESULT {
        const m = of(ctx);
        const write = acc.direction == 1;
        if (acc.gpa >= ioapic_at and acc.gpa < ioapic_at + 0x20) {
            const off: u32 = @intCast(acc.gpa - ioapic_at);
            if (write) {
                m.ioapic.write(off, std.mem.readInt(u32, acc.data[0..4], .little));
            } else std.mem.writeInt(u32, acc.data[0..4], m.ioapic.read(off), .little);
        } else if (!write) @memset(&acc.data, 0xff);
        return 0;
    }

    fn getRegs(ctx: ?*anyopaque, names: [*]const u32, count: u32, values: [*]RegValue) callconv(.winapi) HRESULT {
        return WHvGetVirtualProcessorRegisters(of(ctx).p, 0, names, count, values);
    }

    fn setRegs(ctx: ?*anyopaque, names: [*]const u32, count: u32, values: [*]const RegValue) callconv(.winapi) HRESULT {
        return WHvSetVirtualProcessorRegisters(of(ctx).p, 0, names, count, values);
    }

    fn translate(ctx: ?*anyopaque, gva: u64, flags: u32, result: *u32, gpa: *u64) callconv(.winapi) HRESULT {
        var res: [2]u32 = .{ 0, 0 };
        const hr = WHvTranslateGva(of(ctx).p, 0, gva, flags, &res, gpa);
        result.* = res[0];
        return hr;
    }
};

const ioapic_at: u64 = 0xfec00000;
const mp_at: u64 = 0xf0000;

/// Writes the MP table of version 1.4 at `mp_at`, which the kernel finds
/// with no ACPI: the floating pointer "_MP_", then the table "PCMP" with
/// one CPU (APIC 0), the ISA bus, the I/O APIC 1 at `ioapic_at`, and the
/// ISA IRQs 1 to 15 on the pins of the same number. Each structure has a
/// checksum of zero.
fn writeMpTable(mem: [*]u8) void {
    const base = mem + mp_at;
    @memset(base[0..0x400], 0);
    const table = base + 16;
    var n: usize = 44;
    // The processor: APIC 0, version 0x14, enabled and the boot CPU.
    table[n] = 0;
    table[n + 2] = 0x14;
    table[n + 3] = 3;
    n += 20;
    // The bus 0: ISA.
    table[n] = 1;
    @memcpy(table[n + 2 ..][0..6], "ISA   ");
    n += 8;
    // The I/O APIC 1, version 0x11, enabled.
    table[n] = 2;
    table[n + 1] = 1;
    table[n + 2] = 0x11;
    table[n + 3] = 1;
    std.mem.writeInt(u32, table[n + 4 ..][0..4], @intCast(ioapic_at), .little);
    n += 8;
    var entries: u16 = 3;
    for (1..16) |irq| {
        // An interrupt of the bus: INT, the polarity and the trigger of ISA.
        table[n] = 3;
        table[n + 4] = 0;
        table[n + 5] = @intCast(irq);
        table[n + 6] = 1;
        table[n + 7] = @intCast(irq);
        n += 8;
        entries += 1;
    }
    @memcpy(table[0..4], "PCMP");
    std.mem.writeInt(u16, table[4..6], @intCast(n), .little);
    table[6] = 4;
    @memcpy(table[8..16], "ZTCL    ");
    @memcpy(table[16..28], "WHP SPIKE   ");
    std.mem.writeInt(u16, table[34..36], entries, .little);
    std.mem.writeInt(u32, table[36..40], 0xfee00000, .little);
    table[7] = checksum(table[0..n]);
    // The floating pointer: the address of the table, 1 unit of 16 bytes,
    // version 4, and no default configuration.
    @memcpy(base[0..4], "_MP_");
    std.mem.writeInt(u32, base[4..8], @intCast(mp_at + 16), .little);
    base[8] = 1;
    base[9] = 4;
    base[10] = checksum(base[0..16]);
}

/// The byte that makes the sum of `bytes` zero, with the byte of the
/// checksum at zero in `bytes`.
fn checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return 0 -% sum;
}

/// An I/O APIC at 0xfec00000 with 24 pins: the select register at 0,
/// the window at 0x10, the ID (0), the version (1), and a redirection
/// entry of two words for each pin from 0x10. A raise of an unmasked
/// pin sends its vector to the local APIC of its destination with
/// `WHvRequestInterrupt`. The pins of the ISA devices are edge
/// triggered, so the spike keeps no remote IRR.
const IoApic = struct {
    sel: u32 = 0,
    id: u32 = 1 << 24,
    /// The redirection entries, masked at the start.
    redir: [24]u64 = @splat(1 << 16),

    fn read(io: *const IoApic, off: u32) u32 {
        if (off == 0) return io.sel;
        if (off != 0x10) return 0;
        return switch (io.sel) {
            0 => io.id,
            1 => 0x00170011, // 24 entries, version 0x11
            2 => io.id,
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
        const e = io.redir[pin];
        if (e & (1 << 16) != 0) return;
        const mode: u64 = (e >> 8) & 7; // fixed 0, lowest priority 1
        var ctl: InterruptControl = .{
            .bits = mode | (((e >> 11) & 1) << 8), // the destination mode
            .destination = @intCast(e >> 56),
            .vector = @intCast(e & 0xff),
        };
        _ = WHvRequestInterrupt(p, &ctl, @sizeOf(InterruptControl));
    }
};

/// WHV_INTERRUPT_CONTROL: the type in bits 0 to 7, the destination mode
/// in bits 8 to 11, and the trigger mode in bits 12 to 15.
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

extern "WinHvEmulation" fn WHvEmulatorCreateEmulator(callbacks: *const EmulatorCallbacks, emu: **anyopaque) callconv(.winapi) HRESULT;
extern "WinHvEmulation" fn WHvEmulatorTryIoEmulation(emu: *anyopaque, ctx: ?*anyopaque, vp: *const [40]u8, io: *const [176]u8, status: *u32) callconv(.winapi) HRESULT;
extern "WinHvEmulation" fn WHvEmulatorTryMmioEmulation(emu: *anyopaque, ctx: ?*anyopaque, vp: *const [40]u8, mmio: *const [176]u8, status: *u32) callconv(.winapi) HRESULT;
extern "WinHvPlatform" fn WHvTranslateGva(p: Partition, index: u32, gva: u64, flags: u32, result: *[2]u32, gpa: *u64) callconv(.winapi) HRESULT;
extern "WinHvPlatform" fn WHvRequestInterrupt(p: Partition, ctl: *const InterruptControl, size: u32) callconv(.winapi) HRESULT;

/// The registers of a 16550A at 0x3f8 that the probe of the 8250 driver
/// reads back: the interrupt enable, the line control (with the divisor
/// latch bit), the modem control (with the loopback bit), the FIFO, and
/// the scratch register. The line status says that the transmitter is
/// empty, and the modem status that CTS, DSR, and DCD are on. In
/// loopback the modem status gives the bits of the modem control, as the
/// probe tests. A byte goes out at once, so the transmitter is empty
/// again after each write: with its interrupt on (IER bit 1), the
/// interrupt waits, until a read of the interrupt ID gives it (2).
const Uart = struct {
    ier: u8 = 0,
    lcr: u8 = 0,
    mcr: u8 = 0,
    scr: u8 = 0,
    dll: u8 = 0,
    dlm: u8 = 0,
    fifo: bool = false,
    /// The interrupt of the empty transmitter waits.
    thre: bool = false,

    fn dlab(u: *const Uart) bool {
        return u.lcr & 0x80 != 0;
    }

    fn loop(u: *const Uart) bool {
        return u.mcr & 0x10 != 0;
    }

    /// True when the UART asks for its interrupt.
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
            // A read gives the waiting interrupt of the transmitter, and ends it.
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
                // DTR to DSR, RTS to CTS, OUT1 to RI, OUT2 to DCD.
                ((u.mcr & 1) << 5) | ((u.mcr & 2) << 3) | ((u.mcr & 4) << 4) | ((u.mcr & 8) << 4)
            else
                0xb0,
            7 => u.scr,
            else => 0,
        };
    }
};

/// The rate of the TSC of the host in kHz: the TSC over 100 ms of the
/// performance counter.
fn tscKhz() u64 {
    var f: i64 = 0;
    var c0: i64 = 0;
    var c1: i64 = 0;
    _ = QueryPerformanceFrequency(&f);
    _ = QueryPerformanceCounter(&c0);
    const t0 = rdtsc();
    while (true) {
        _ = QueryPerformanceCounter(&c1);
        if (c1 - c0 >= @divTrunc(f, 10)) break;
    }
    const t1 = rdtsc();
    const secs_x1000: u64 = @intCast(@divTrunc((c1 - c0) * 1000, f));
    return (t1 - t0) / secs_x1000;
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

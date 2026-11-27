//! The direct boot of an x86-64 Linux guest of `ztcl::vm` (ztcl#203),
//! for each monitor that writes the guest memory itself: KVM
//! (`src/kvm.zig`) and the Windows Hypervisor Platform (`src/whp.zig`).
//! The sources are the x86 boot protocol of Linux
//! (Documentation/arch/x86/boot.rst and zero-page.rst) and the Intel
//! MultiProcessor Specification 1.4. It makes no system call.
//!
//! The layout of the guest physical memory:
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
//! The boot CPU starts in 64-bit mode at the entry point that `load`
//! gives, with RSI at `zero_page`, CR3 at `pml4_addr`, and the GDT at
//! `gdt_addr`.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const Mem = @import("virtio/queue.zig").Mem;

pub const gdt_addr = 0x500;
pub const zero_page = 0x7000;
pub const pml4_addr = 0x9000;
pub const cmdline_addr = 0x20000;
pub const cmdline_max = 4096;
pub const mptable_addr = 0x9fc00;
pub const kernel_addr = 0x100000;
pub const low_ram_end = 0x9fc00;
pub const ioapic_addr = 0xfec00000;
pub const lapic_addr = 0xfee00000;

pub const Image = struct {
    /// A bzImage or an ELF vmlinux.
    kernel: []const u8,
    initrd: []const u8 = "",
    /// The full command line, with the options of the monitor.
    cmdline: []const u8,
    cpus: u32 = 1,
};

/// The text of the last error of `load`.
pub threadlocal var why: []const u8 = "";

fn fail(text: []const u8) error{Kernel} {
    why = text;
    return error.Kernel;
}

fn le(comptime T: type, b: []const u8, off: usize) T {
    return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
}

/// Loads the kernel and the initramfs, and writes the boot parameters,
/// the command line, the GDT, the page tables, and the MP table. Gives
/// the guest address of the 64-bit entry point.
pub fn load(mem: Mem, img: Image) error{Kernel}!u64 {
    const k = img.kernel;
    const zp = mem.slice(zero_page, 4096) orelse return fail("the guest memory is too small");
    @memset(zp, 0);
    var entry: u64 = 0;
    var kernel_end: u64 = kernel_addr;
    var initrd_max: u64 = 0x37ffffff;
    if (k.len >= 64 and std.mem.eql(u8, k[0..4], "\x7fELF")) {
        // An ELF vmlinux: each PT_LOAD at its physical address.
        if (k[4] != 2 or le(u16, k, 0x12) != 0x3e) return fail("the ELF kernel is not x86-64");
        const e_entry = le(u64, k, 0x18);
        const phoff = le(u64, k, 0x20);
        const phentsize = le(u16, k, 0x36);
        const phnum = le(u16, k, 0x38);
        var i: usize = 0;
        while (i < phnum) : (i += 1) {
            const off = phoff + i * phentsize;
            if (off + 56 > k.len) return fail("the ELF kernel is cut short");
            if (le(u32, k, off) != 1) continue;
            const p_offset = le(u64, k, off + 0x08);
            const p_vaddr = le(u64, k, off + 0x10);
            const p_paddr = le(u64, k, off + 0x18);
            const p_filesz = le(u64, k, off + 0x20);
            const p_memsz = le(u64, k, off + 0x28);
            if (p_filesz > p_memsz or p_offset > k.len or p_filesz > k.len - p_offset)
                return fail("a segment of the ELF kernel is outside the file");
            const dst = mem.slice(p_paddr, p_memsz) orelse return fail("the kernel is larger than the guest memory");
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
        if (k.len < 0x264 or le(u32, k, 0x202) != 0x53726448) return fail("the kernel is not a bzImage or an ELF vmlinux");
        if (le(u16, k, 0x206) < 0x020c or le(u16, k, 0x236) & 1 == 0) return fail("the bzImage has no 64-bit entry point");
        var setup_sects: usize = k[0x1f1];
        if (setup_sects == 0) setup_sects = 4;
        const pm = (setup_sects + 1) * 512;
        if (pm >= k.len) return fail("the bzImage is cut short");
        const hdr_end = 0x202 + @as(usize, k[0x201]);
        @memcpy(zp[0x1f1..hdr_end], k[0x1f1..hdr_end]);
        const body = k[pm..];
        const init_size = le(u32, k, 0x260);
        const dst = mem.slice(kernel_addr, @max(body.len, init_size)) orelse return fail("the kernel is larger than the guest memory");
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
    const cl = img.cmdline;
    if (cl.len + 1 > cmdline_max) return fail("the command line is longer than 4,095 bytes");
    const cdst = mem.slice(cmdline_addr, cl.len + 1).?;
    @memcpy(cdst[0..cl.len], cl);
    cdst[cl.len] = 0;
    mem.put(u32, zero_page + 0x228, cmdline_addr);

    // The initramfs, at the top of the memory below its limit.
    if (img.initrd.len != 0) {
        const top = @min(mem.size, initrd_max + 1);
        const len: u64 = img.initrd.len;
        if (len + kernel_end > top) return fail("the initramfs does not fit in the guest memory");
        const addr = (top - len) & ~@as(u64, 0xfff);
        if (addr < kernel_end) return fail("the initramfs does not fit in the guest memory");
        @memcpy(mem.slice(addr, len).?, img.initrd);
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
    writeMpTable(mem, img.cpus);
    return entry;
}

/// The MP table of the MultiProcessor Specification 1.4: the floating
/// pointer, then the configuration table with the CPUs, the ISA bus, the
/// I/O APIC (ID `cpus`), an entry for each ISA interrupt, and the local
/// interrupts.
pub fn writeMpTable(mem: Mem, cpus: u32) void {
    const ioapic_id: u8 = @intCast(cpus);
    const table = mptable_addr + 16;
    var at: u64 = table + 44;
    var count: u16 = 0;
    for (0..cpus) |i| {
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

test "boot: the MP table has checksums of zero" {
    var buf: [1 << 20]u8 align(4096) = undefined;
    const mem: Mem = .{ .base = &buf, .size = buf.len };
    writeMpTable(mem, 2);
    try std.testing.expectEqualStrings("_MP_", buf[mptable_addr..][0..4]);
    var s: u8 = 0;
    for (buf[mptable_addr..][0..16]) |x| s +%= x;
    try std.testing.expectEqual(@as(u8, 0), s);
    const len = std.mem.readInt(u16, buf[mptable_addr + 16 + 4 ..][0..2], .little);
    s = 0;
    for (buf[mptable_addr + 16 ..][0..len]) |x| s +%= x;
    try std.testing.expectEqual(@as(u8, 0), s);
}

test "boot: a kernel that is no bzImage and no ELF" {
    var buf: [1 << 20]u8 align(4096) = @splat(0);
    const mem: Mem = .{ .base = &buf, .size = buf.len };
    try std.testing.expectError(error.Kernel, load(mem, .{ .kernel = "not a kernel at all, and too short", .cmdline = "" }));
}

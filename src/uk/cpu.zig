//! The CPU setup of the ztcl unikernel (ztcl#471). The sources are the
//! Intel 64 and IA-32 Architectures Software Developer's Manual (volume
//! 3: the IDT in 6.14, the local APIC in chapter 11, the page tables in
//! chapter 4) and the Intel 82093AA I/O APIC datasheet.
//!
//! - The IDT: a gate for each exception (vectors 0 to 31) that prints
//!   the vector, the error code, RIP, and CR2 on the console and stops
//!   the guest, a gate for the interrupts of the devices (`irq_vector`),
//!   and a gate for the spurious vector of the local APIC.
//! - The 8259 PICs get new vectors and a full mask, so only the I/O
//!   APIC gives interrupts. The local APIC is on, with no priority
//!   threshold. The I/O APIC sends the line of the vsock device to
//!   `irq_vector`, edge-triggered, to the boot CPU.
//! - The handler of a device interrupt stores zero in the word at
//!   `uk_limit_word`, writes the end of the interrupt to the local APIC,
//!   and returns. The driver finds the work on its rings.
//! - The GDT of the image replaces the GDT of the monitor, with the
//!   same segments, and the page tables of `paging.zig` replace its map.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const uk = @import("uk.zig");
const paging = @import("paging.zig");

pub const irq_vector = 0x30;
const spurious_vector = 0xff;
const lapic: usize = 0xfee00000;
const ioapic: usize = 0xfec00000;

pub var heap_start: usize = 0;
/// The address of `mem_limit` of the interpreter, or 0. The interrupt
/// of a device stores zero there, so the next safe point of the
/// interpreter reads the frames of the host (`thread.safePoint`).
pub export var uk_limit_word: usize = 0;

const Gate = extern struct {
    off_lo: u16,
    sel: u16,
    ist: u8,
    attr: u8,
    off_mid: u16,
    off_hi: u32,
    zero: u32,
};

var idt: [256]Gate align(16) = @splat(std.mem.zeroes(Gate));

fn setGate(v: usize, h: usize) void {
    idt[v] = .{
        .off_lo = @truncate(h),
        .sel = 0x10,
        .ist = 0,
        .attr = 0x8e, // present, ring 0, 64-bit interrupt gate
        .off_mid = @truncate(h >> 16),
        .off_hi = @truncate(h >> 32),
        .zero = 0,
    };
}

// The stubs of the exceptions: each pushes an error code of 0 when the
// CPU pushes none, then its vector.
comptime {
    var s: []const u8 = ".text\n";
    for (0..32) |v| {
        const has_code = switch (v) {
            8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
            else => false,
        };
        s = s ++ std.fmt.comptimePrint(".globl uk_exc{d}\nuk_exc{d}:\n{s}  push ${d}\n  jmp uk_exc_common\n", .{ v, v, if (has_code) "" else "  push $0\n", v });
    }
    s = s ++
        \\uk_exc_common:
        \\  mov %rsp, %rdi
        \\  and $-16, %rsp
        \\  call uk_exception
        \\.globl uk_irq
        \\uk_irq:
        \\  push %rax
        \\  mov uk_limit_word(%rip), %rax
        \\  test %rax, %rax
        \\  jz 1f
        \\  movq $0, (%rax)
        \\1:
        \\  mov $0xfee000b0, %rax
        \\  movl $0, (%rax)
        \\  pop %rax
        \\  iretq
        \\.globl uk_spurious
        \\uk_spurious:
        \\  iretq
        \\
    ;
    asm (s);
}

const Frame = extern struct { vector: u64, code: u64, rip: u64, cs: u64, rflags: u64, rsp: u64, ss: u64 };

export fn uk_exception(f: *const Frame) callconv(.c) noreturn {
    const cr2 = asm volatile ("mov %%cr2, %[r]"
        : [r] "=r" (-> u64),
    );
    uk.printf("ztcl unikernel: exception {d} code 0x{x} rip 0x{x} rsp 0x{x} cr2 0x{x}\n", .{ f.vector, f.code, f.rip, f.rsp, cr2 });
    uk.halt();
}

fn stubAddr(comptime name: []const u8) usize {
    return @intFromPtr(@extern(*const fn () callconv(.naked) void, .{ .name = name }));
}

fn lapicW(off: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(lapic + off)).* = v;
}

fn ioapicW(reg: u32, v: u32) void {
    @as(*volatile u32, @ptrFromInt(ioapic)).* = reg;
    @as(*volatile u32, @ptrFromInt(ioapic + 0x10)).* = v;
}

/// The GDT of `vm/boot.zig` (code 0x10, data 0x18), in the image: the
/// page of the GDT of the monitor, page 0, is absent in `paging.zig`.
var gdt: [4]u64 align(16) = .{ 0, 0, 0x00af9b000000ffff, 0x00cf93000000ffff };

pub fn init(image_end: usize, mem_end: usize) void {
    const Gdtr = extern struct { limit: u16 align(1), base: u64 align(1) };
    const gdtr: Gdtr = .{ .limit = @sizeOf(@TypeOf(gdt)) - 1, .base = @intFromPtr(&gdt) };
    asm volatile ("lgdt (%[p])"
        :
        : [p] "r" (&gdtr),
    );
    inline for (0..32) |v| setGate(v, stubAddr(std.fmt.comptimePrint("uk_exc{d}", .{v})));
    setGate(irq_vector, stubAddr("uk_irq"));
    setGate(spurious_vector, stubAddr("uk_spurious"));
    const Idtr = extern struct { limit: u16 align(1), base: u64 align(1) };
    const idtr: Idtr = .{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&idtr),
    );
    // The PICs: ICW1 to ICW4, the vectors 0x20 and 0x28, then a mask
    // of each line.
    for ([_][2]u16{ .{ 0x20, 0x11 }, .{ 0xa0, 0x11 }, .{ 0x21, 0x20 }, .{ 0xa1, 0x28 }, .{ 0x21, 4 }, .{ 0xa1, 2 }, .{ 0x21, 1 }, .{ 0xa1, 1 }, .{ 0x21, 0xff }, .{ 0xa1, 0xff } }) |p|
        uk.outb(p[0], @intCast(p[1]));
    lapicW(0x80, 0); // the task priority
    lapicW(0xf0, 0x100 | spurious_vector); // on, with the spurious vector
    heap_start = paging.init(image_end, mem_end);
}

/// Sends the interrupt line `line` of the I/O APIC to `irq_vector`.
pub fn routeIrq(line: u8) void {
    ioapicW(0x10 + 2 * @as(u32, line) + 1, 0); // the boot CPU
    ioapicW(0x10 + 2 * @as(u32, line), irq_vector);
}

var deadline_ok: ?bool = null;
/// The count of the last `timerAt`, or 0.
var armed: u64 = 0;

/// True when the time of the last `timerAt` passed: its interrupt can
/// have come before a `cli`, so a `hlt` then waits for no timer.
pub fn timerDue() bool {
    return armed != 0 and rdtsc() >= armed;
}

/// Arms the timer of the local APIC in TSC-deadline mode (SDM 11.5.4.1)
/// for the count `tsc`, on `irq_vector`. Gives false when the CPU has no
/// TSC-deadline mode (CPUID.1:ECX bit 24).
pub fn timerAt(tsc: u64) bool {
    if (deadline_ok == null) {
        var ecx: u32 = undefined;
        asm volatile ("cpuid"
            : [c] "={ecx}" (ecx),
            : [a] "{eax}" (@as(u32, 1)),
              [cc] "{ecx}" (@as(u32, 0)),
            : .{ .ebx = true, .edx = true });
        deadline_ok = ecx & (1 << 24) != 0;
        if (deadline_ok.?) lapicW(0x320, (2 << 17) | irq_vector);
    }
    if (!deadline_ok.?) return false;
    armed = tsc;
    asm volatile ("wrmsr"
        :
        : [c] "{ecx}" (@as(u32, 0x6e0)),
          [lo] "{eax}" (@as(u32, @truncate(tsc))),
          [hi] "{edx}" (@as(u32, @truncate(tsc >> 32))),
    );
    return true;
}

pub fn cli() void {
    asm volatile ("cli" ::: .{ .memory = true });
}

pub fn sti() void {
    asm volatile ("sti" ::: .{ .memory = true });
}

/// Turns interrupts on and sleeps until the next one. The instruction
/// after `sti` runs before an interrupt comes, so no interrupt comes
/// between the check of the caller and the `hlt`.
pub fn stiHlt() void {
    asm volatile ("sti; hlt" ::: .{ .memory = true });
}

pub fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Fills `buf` with the bytes of RDRAND. Gives false when RDRAND fails
/// 10 times in a row.
pub fn random(buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        var v: u64 = undefined;
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            if (tries == 10) return false;
            var ok: u8 = undefined;
            asm volatile ("rdrand %[v]; setc %[ok]"
                : [v] "=r" (v),
                  [ok] "=r" (ok),
            );
            if (ok != 0) break;
        }
        const n = @min(8, buf.len - off);
        @memcpy(buf[off..][0..n], std.mem.asBytes(&v)[0..n]);
        off += n;
    }
    return true;
}

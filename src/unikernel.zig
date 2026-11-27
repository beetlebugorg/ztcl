//! The ztcl unikernel (ztcl#471): the ztcl runtime as the only program
//! of a guest of the hypervisor, with no operating system.
//!
//! The monitor (`src/kvm.zig`) loads this image as an ELF kernel and
//! starts the boot CPU in 64-bit mode at `_start`, with an identity map
//! of the first 4 GB in 2 MB pages and RSI at the boot parameters of
//! `vm/boot.zig`. `_start` turns on SSE, moves to the stack of the
//! image, and calls `main`.
//!
//! `main` reads the command line of the boot parameters, builds the page
//! tables of `uk/cpu.zig` (the image and the JIT region in 4 KiB pages,
//! with no page both writable and executable), gives the memory above
//! the image to the heap of `uk/heap.zig`, and starts the vsock driver
//! of `uk/vsock.zig`. Then it runs the child of an isolated thread
//! (`isothread.childMain`) on the first connection of the host to port
//! 1024. At the end of the thread it stops the guest.
//!
//! The guest has no files, no sockets, no processes, and no clock: the
//! interpreter has the capabilities that the host gives in `START`, and
//! only `thread` and `tsv` reach the host, through the protocol.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
pub const uk = @import("uk/uk.zig");

pub const panic = std.debug.FullPanic(uk.panic);

pub const std_options: std.Options = .{
    .logFn = uk.log,
    .page_size_min = 4096,
    .page_size_max = 4096,
};

comptime {
    // The entry: the monitor gives no stack that the image can trust.
    // SSE needs CR0.MP on, CR0.EM off, and CR4.OSFXSR and OSXMMEXCPT on.
    // With XSAVE (CPUID.1:ECX bit 26), CR4.OSXSAVE and XCR0 turn on the
    // AVX and AVX-512 states that the CPU has (CPUID.0DH:EAX), since the
    // image is built for the CPU of the host.
    asm (
        \\.section .text.boot, "ax"
        \\.globl _start
        \\_start:
        \\  cli
        \\  mov %rsi, %rdi
        \\  lea uk_stack+0x800000(%rip), %rsp
        \\  mov %cr0, %rax
        \\  and $~4, %rax
        \\  or $2, %rax
        \\  mov %rax, %cr0
        \\  mov %cr4, %rax
        \\  or $0x600, %rax
        \\  mov %rax, %cr4
        \\  mov $1, %eax
        \\  cpuid
        \\  bt $26, %ecx
        \\  jnc 2f
        \\  mov %cr4, %rax
        \\  or $0x40000, %rax
        \\  mov %rax, %cr4
        \\  mov $0xd, %eax
        \\  xor %ecx, %ecx
        \\  cpuid
        \\  and $0xe7, %eax
        \\  xor %edx, %edx
        \\  xor %ecx, %ecx
        \\  xsetbv
        \\2:
        \\  call uk_main
        \\1:
        \\  hlt
        \\  jmp 1b
    );
}

export fn uk_main(boot_params: usize) callconv(.c) noreturn {
    uk.start(boot_params);
}

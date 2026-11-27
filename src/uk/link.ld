/* The layout of the ztcl unikernel (ztcl#471): one image at 2 MB of
   guest physical memory. The monitor of src/kvm.zig loads each PT_LOAD
   segment at its physical address and starts at _start in 64-bit mode.
   SPDX-License-Identifier: BSD-2-Clause */
ENTRY(_start)
SECTIONS
{
    . = 0x200000;
    __image_start = .;
    .text : { KEEP(*(.text.boot)) *(.text .text.*) }
    . = ALIGN(4096);
    __text_end = .;
    .rodata : { *(.rodata .rodata.*) }
    . = ALIGN(4096);
    uk_rodata_end = .;
    .data : { *(.data .data.*) }
    .bss (NOLOAD) : { *(.bss .bss.*) *(COMMON) }
    . = ALIGN(4096);
    __image_end = .;
    /DISCARD/ : { *(.eh_frame*) *(.comment) }
}

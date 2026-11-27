//! The machine layer of the ztcl unikernel (ztcl#471): the console, the
//! boot parameters, the stop of the guest, and the start sequence.
//!
//! The console is the 8250 UART at port 0x3f8 of the monitor: each byte
//! is one write to the transmit register, and the monitor sends it to
//! the console channel of the guest. It is for logs and panics only.
//!
//! The guest stops itself with the reset of the keyboard controller: a
//! write of 0xfe to port 0x64, and the monitor of `src/kvm.zig` treats it
//! as the end of the guest.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
pub const heap = @import("heap.zig");
pub const cpu = @import("cpu.zig");

/// The stack of the image. Its lowest page is absent (`paging.zig`), so
/// an overflow faults.
pub export var uk_stack: [8 << 20]u8 align(4096) linksection(".bss.stack") = undefined;

pub fn outb(port: u16, v: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (v),
          [p] "{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[v]"
        : [v] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}

/// Writes bytes to the console.
pub fn print(bytes: []const u8) void {
    for (bytes) |b| {
        if (b == '\n') outb(0x3f8, '\r');
        outb(0x3f8, b);
    }
}

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    print(std.fmt.bufPrint(&buf, fmt, args) catch &buf);
}

/// Stops the guest.
pub fn halt() noreturn {
    outb(0x64, 0xfe);
    while (true) asm volatile ("cli; hlt");
}

pub fn panic(msg: []const u8, ra: ?usize) noreturn {
    printf("ztcl unikernel: panic: {s} at 0x{x}\n", .{ msg, ra orelse @returnAddress() });
    halt();
}

pub fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    _ = scope;
    printf("[" ++ @tagName(level) ++ "] " ++ fmt ++ "\n", args);
}

/// The command line of the boot parameters.
pub var cmdline: []const u8 = "";
/// The end of the guest memory.
pub var mem_end: usize = 0;

extern const __image_end: u8;

fn bootParams(zp: usize) void {
    const p: [*]const u8 = @ptrFromInt(zp);
    const cl = std.mem.readInt(u32, p[0x228..][0..4], .little);
    if (cl != 0) cmdline = std.mem.sliceTo(@as([*:0]const u8, @ptrFromInt(cl)), 0);
    // The e820 table: the entry of type 1 with the highest end.
    const n = p[0x1e8];
    for (0..n) |i| {
        const e = p[0x2d0 + 20 * i ..][0..20];
        const base = std.mem.readInt(u64, e[0..8], .little);
        const len = std.mem.readInt(u64, e[8..16], .little);
        if (std.mem.readInt(u32, e[16..20], .little) == 1) mem_end = @max(mem_end, @as(usize, @intCast(base + len)));
    }
}

/// The value of `name=` on the command line, or null.
pub fn param(name: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, cmdline, ' ');
    while (it.next()) |w| {
        if (w.len > name.len and std.mem.startsWith(u8, w, name) and w[name.len] == '=') return w[name.len + 1 ..];
    }
    return null;
}

pub const entry = @import("entry.zig");

pub fn start(zp: usize) noreturn {
    bootParams(zp);
    const image_end = @intFromPtr(&__image_end);
    cpu.init(image_end, mem_end);
    heap.init(cpu.heap_start, mem_end);
    entry.run();
    halt();
}

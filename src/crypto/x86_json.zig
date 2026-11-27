//! Stage 1 of the JSON parser with AVX2 and PCLMULQDQ, for x86-64 CPUs
//! that have them, in a module that build.zig compiles with these
//! features (addCrypto). `Indexer.nextWith` of `src/json/index.zig` is
//! inline, so its body compiles here with the vector code, and a
//! release build for the baseline CPU still runs it on a CPU with AVX2.
//!
//! `available` reads CPUID once: AVX2 (leaf 7, EBX bit 5), PCLMULQDQ
//! (leaf 1, ECX bit 1), and the YMM state on in XCR0 (OSXSAVE, then
//! XGETBV bits 1 and 2).
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const index = @import("json_index");

const is_x86 = builtin.cpu.arch == .x86_64;

pub fn next(ix: *index.Indexer, out: []u32) usize {
    if (comptime !is_x86) return ix.nextWith(out, index.native);
    return ix.nextWith(out, .{ .avx2 = true, .pclmul = true });
}

const Regs = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf: u32, sub: u32) Regs {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );
    return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
}

fn xcr0() u32 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("xgetbv"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [n] "{ecx}" (@as(u32, 0)),
    );
    return lo;
}

fn detect() bool {
    if (comptime !is_x86) return false;
    if (cpuid(0, 0).eax < 7) return false;
    const l1 = cpuid(1, 0);
    if (l1.ecx & (1 << 1) == 0 or l1.ecx & (1 << 27) == 0) return false;
    if (xcr0() & 6 != 6) return false;
    return cpuid(7, 0).ebx & (1 << 5) != 0;
}

/// 0: not read yet, 1: no, 2: yes.
var state = std.atomic.Value(u8).init(0);

pub fn available() bool {
    var s = state.load(.monotonic);
    if (s == 0) {
        s = if (detect()) 2 else 1;
        state.store(s, .monotonic);
    }
    return s == 2;
}

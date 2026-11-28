//! The C variadic arguments of the slots of the C API (ztcl#616).
//!
//! Zig 0.17 has no C variadic functions and no `std.builtin.VaList` on
//! aarch64 Linux. There this file has its own `va_list` and its own
//! variadic entry points; elsewhere `VaList` is `std.builtin.VaList` and
//! `arg` is `@cVaArg`.
//!
//! The `va_list` of AAPCS64 (Procedure Call Standard for the Arm 64-bit
//! Architecture, appendix "Variable argument lists") is a struct of five
//! fields: `stack`, the next argument on the stack; `gr_top` and
//! `vr_top`, the ends of the save areas of the general registers x0 to
//! x7 and of the vector registers q0 to q7; and `gr_offs` and `vr_offs`,
//! the negative offsets of the next saved register from those ends. An
//! integer or a pointer comes from the general area while `gr_offs` is
//! below 0 and then from the stack, 8 bytes each. A double comes from
//! the vector area, 16 bytes each, while `vr_offs` is below 0, and then
//! from the stack.
//!
//! `Stub(nfixed, body)` is a variadic entry point: a naked function that
//! stores x0 to x7 and q0 to q7 in a save area on its stack, makes a
//! `va_list` there for the arguments after the `nfixed` fixed ones, and
//! calls `body` with the fixed arguments and the address of the
//! `va_list`. The fixed arguments stay in their registers, so the body
//! has the form of the `...VA` slot of Tcl, such as
//! `Tcl_AppendResultVA(interp, va_list)`. Each body has an exported
//! symbol with hidden visibility for the `bl` of the stub. The idea of a
//! variadic function with no compiler support comes from
//! suirad/zig-varargs (`docs/references/zig-varargs.md`); this code
//! follows the ABI document, not that code.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");

/// True where this file has its own `va_list` and variadic entry points.
pub const own = builtin.cpu.arch == .aarch64 and builtin.os.tag == .linux;

/// The `va_list` of AAPCS64.
pub const Aapcs64 = extern struct {
    stack: [*]u8,
    gr_top: [*]u8,
    vr_top: [*]u8,
    gr_offs: i32,
    vr_offs: i32,

    /// The next argument of the type `T`: an integer or a pointer of at
    /// most 8 bytes, or a float.
    pub fn arg(ap: *Aapcs64, comptime T: type) T {
        const float = @typeInfo(T) == .float;
        comptime std.debug.assert(@sizeOf(T) <= 8);
        if (float) {
            const offs = ap.vr_offs;
            if (offs < 0) {
                ap.vr_offs = offs + 16;
                if (ap.vr_offs <= 0) return fromBytes(T, ap.vr_top - @as(usize, @intCast(-offs)));
            }
        } else {
            const offs = ap.gr_offs;
            if (offs < 0) {
                ap.gr_offs = offs + 8;
                if (ap.gr_offs <= 0) return fromBytes(T, ap.gr_top - @as(usize, @intCast(-offs)));
            }
        }
        // On the stack: each argument has a slot of 8 bytes.
        const p = ap.stack;
        ap.stack += 8;
        return fromBytes(T, p);
    }
};

/// The value of the type `T` at the low bytes of a slot (little endian).
fn fromBytes(comptime T: type, p: [*]u8) T {
    var v: T = undefined;
    @memcpy(std.mem.asBytes(&v), p[0..@sizeOf(T)]);
    return v;
}

/// The `va_list` of the target.
pub const VaList = if (own) Aapcs64 else std.builtin.VaList;

/// The next argument of `ap`.
pub inline fn arg(ap: *VaList, comptime T: type) T {
    if (own) return ap.arg(T);
    return @cVaArg(ap, T);
}

/// A variadic entry point with `nfixed` fixed integer or pointer
/// arguments, which calls the exported function `body`. See the top of
/// the file. The frame: x29 and x30 at the old stack top, then 64 bytes
/// of x0 to x7, 128 bytes of q0 to q7, and the 32 bytes of the
/// `va_list`.
pub fn Stub(comptime nfixed: u3, comptime body: []const u8) type {
    if (!own) @compileError("va.Stub is for aarch64 Linux");
    const gr_offs = -@as(i32, 8 - @as(i32, nfixed)) * 8;
    const text = std.fmt.comptimePrint(
        \\stp x29, x30, [sp, #-16]!
        \\mov x29, sp
        \\sub sp, sp, #224
        \\stp x0, x1, [sp, #0]
        \\stp x2, x3, [sp, #16]
        \\stp x4, x5, [sp, #32]
        \\stp x6, x7, [sp, #48]
        \\stp q0, q1, [sp, #64]
        \\stp q2, q3, [sp, #96]
        \\stp q4, q5, [sp, #128]
        \\stp q6, q7, [sp, #160]
        \\add x9, x29, #16
        \\str x9, [sp, #192]
        \\add x9, sp, #64
        \\str x9, [sp, #200]
        \\add x9, sp, #192
        \\str x9, [sp, #208]
        \\mov w9, #{d}
        \\str w9, [sp, #216]
        \\mov w9, #-128
        \\str w9, [sp, #220]
        \\add x{d}, sp, #192
        \\bl {s}
        \\mov sp, x29
        \\ldp x29, x30, [sp], #16
        \\ret
    , .{ gr_offs, nfixed, body });
    return struct {
        pub fn f() callconv(.naked) noreturn {
            asm volatile (text);
        }
    };
}

/// Exports `f` under `name` with hidden visibility, for a `Stub`.
pub fn exportBody(comptime f: anytype, comptime name: []const u8) void {
    if (own) @export(f, .{ .name = name, .visibility = .hidden });
}

test "Aapcs64 reads the general area, the vector area, then the stack" {
    var gr: [8]u64 = .{ 0, 0, 0, 11, 12, 13, 14, 15 };
    var vr: [8][2]u64 = undefined;
    for (&vr, 0..) |*q, i| q.* = .{ @bitCast(@as(f64, @floatFromInt(i)) + 0.5), 0 };
    var stack: [3]u64 = .{ 16, @bitCast(@as(f64, 9.25)), 17 };
    var ap: Aapcs64 = .{
        .stack = @ptrCast(&stack),
        .gr_top = @as([*]u8, @ptrCast(&gr)) + 64,
        .vr_top = @as([*]u8, @ptrCast(&vr)) + 128,
        .gr_offs = -40,
        .vr_offs = -16,
    };
    for ([_]u64{ 11, 12, 13, 14, 15 }) |want| try std.testing.expectEqual(want, ap.arg(u64));
    try std.testing.expectEqual(@as(f64, 7.5), ap.arg(f64));
    try std.testing.expectEqual(@as(u64, 16), ap.arg(u64));
    try std.testing.expectEqual(@as(f64, 9.25), ap.arg(f64));
    try std.testing.expectEqual(@as(c_int, 17), ap.arg(c_int));
}

/// The body of the stub of the next test: the sum of `n` integers, and
/// `n` doubles after them, times 1,000.
fn testSum(n: usize, ap: *VaList) callconv(.c) i64 {
    var s: i64 = 0;
    for (0..n) |_| s += arg(ap, i64);
    var d: f64 = 0;
    for (0..n) |_| d += arg(ap, f64);
    return s + @as(i64, @intFromFloat(d * 1000));
}

comptime {
    if (own and builtin.is_test) exportBody(&testSum, "ztcl_va_test_sum");
}

test "a Stub reads the arguments of a C call in registers and on the stack" {
    if (!own) return error.SkipZigTest;
    // Twelve integers and twelve doubles: x1 to x7 and q0 to q7, then the
    // stack, as a C call of a variadic function passes them on Linux.
    const F = *const fn (usize, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, f64, f64, f64, f64, f64, f64, f64, f64, f64, f64, f64, f64) callconv(.c) i64;
    const f: F = @ptrCast(&Stub(1, "ztcl_va_test_sum").f);
    const got = f(12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5, 10.5, 11.5);
    // 78 + 72.0 * 1000
    try std.testing.expectEqual(@as(i64, 78 + 72_000), got);
}

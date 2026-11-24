//! The registers and the calling convention of the machine code of the
//! JIT on x86-64 with the System V ABI.
//!
//! Five callee-saved registers hold the values of one entry: the
//! interpreter, the `Code`, the value stack, the helper table, and the
//! frame. A helper call keeps them, so the code loads them one time in
//! the prologue. The scratch registers are caller-saved, so no value
//! stays in one across a helper call.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const x64 = @import("x64.zig");
const Reg = x64.Reg;

/// The interpreter.
pub const it: Reg = .r15;
/// The `Code`.
pub const code: Reg = .r14;
/// The value stack.
pub const stack: Reg = .r13;
/// The helper table.
pub const helpers: Reg = .r12;
/// The frame of the variables.
pub const frame: Reg = .rbx;
/// The frame pointer.
pub const fp: Reg = .rbp;

/// The registers that templates use between two helper calls.
pub const scratch = [_]Reg{ .rax, .rcx, .rdx, .r8, .r9, .r10, .r11 };

/// The argument registers of a helper call: the context, `pc`, and `sp`.
pub const arg0: Reg = .rdi;
pub const arg1: Reg = .rsi;
pub const arg2: Reg = .rdx;

/// The result register of a call.
pub const ret: Reg = .rax;

/// The offset of the context pointer from the frame pointer. The
/// prologue pushes five registers after `rbp`, then the context.
pub const ctx_slot: i32 = -48;

/// The registers that the prologue saves, in the order of the pushes.
pub const saved = [_]Reg{ .rbx, .r12, .r13, .r14, .r15 };

/// The native stack of one JIT frame: the return address, `rbp`, the
/// saved registers, and the context pointer.
pub const frame_bytes = 8 + 8 + 8 * saved.len + 8;

/// The registers and the calling convention of the machine code of the
/// JIT on arm64 with AAPCS64 and the rules of Apple. The pinned
/// registers are callee-saved, and the scratch registers `x9` to `x15`
/// are caller-saved. `x16` and `x17` are the temporaries of the
/// assembler and of the templates. No code uses `x18`.
pub const a64 = struct {
    const R = @import("a64.zig").Reg;
    pub const it: R = .x19;
    pub const code: R = .x20;
    pub const frame: R = .x21;
    pub const stack: R = .x22;
    pub const helpers: R = .x23;
    pub const fp: R = .x29;
    pub const lr: R = .x30;

    pub const arg0: R = .x0;
    pub const arg1: R = .x1;
    pub const arg2: R = .x2;
    pub const ret: R = .x0;

    /// The frame: `x29` and `x30` at `[sp]`, then the pairs `x19 x20`,
    /// `x21 x22`, and `x23` with the context pointer. 64 bytes, so the
    /// stack pointer stays 16-byte aligned.
    pub const frame_bytes: i64 = 64;
    /// The offset of the context pointer from `x29`.
    pub const ctx_slot: i64 = 56;
};

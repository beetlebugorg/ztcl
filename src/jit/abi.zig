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

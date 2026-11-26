# Task 40: the RV64 assembler

## Goal

An assembler for the RV64GC forms of tier 1 and tier 2, as `src/jit/a64.zig` is for arm64. It is pure encoding, so the task and its tests run on any host.

## Files

- `src/jit/rv64.zig` (new), `src/jit/rv64_golden.zig` (new, generated), `tools/jit-asm-golden.sh` (the option `--arch riscv64`).

## The forms

| Group | Forms |
|---|---|
| Moves | `addi`, `lui`, `auipc`, and the sequence for a 64-bit constant; `ld`, `sd`, `lw`, `sw`, `lbu` with a signed 12-bit offset |
| Arithmetic | `add`, `sub`, `addw`, `subw`, `and`, `or`, `xor`, `sll`, `srl`, `sra`, `slt`, `sltu`, and the forms with an immediate; `mul`, `mulh`, `div`, `rem` of the M extension |
| Control | `jal`, `jalr`, `beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu`, and the long form of a branch past 4 KiB |
| Other | `ebreak`, `fence.i` |
| Floating point (tier 2) | `fld`, `fsd`, `fmv.d`, `fmv.d.x`, `fmv.x.d`, `fadd.d`, `fsub.d`, `fmul.d`, `fdiv.d`, `feq.d`, `flt.d`, `fle.d`, `fcvt.d.l` |

The compressed forms of the C extension stay out. Each instruction is 4 bytes, so the layout of task 13 needs no change.

## Rules

- `gp` and `tp` are never written. An emit call with either one is an error.
- `t5` and `t6` are temporaries of the assembler for a large offset or constant.
- The overflow check of an add uses the sequence of the ISA manual (an add, a compare of the signs, and a branch), because RV64 has no flags.

## Acceptance

- The golden test: each form against the bytes that `zig cc -target riscv64-linux-musl` assembles, written by `tools/jit-asm-golden.sh --arch riscv64`.
- `zig build test` passes on x86-64 Linux.

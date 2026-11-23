# Task 26: the arm64 assembler

The user decides the order of milestones 3 and 4 before this task.

## Goal

An assembler for the arm64 forms of tier 1. It is pure encoding, so the task and its tests run on any host.

## Files

- `src/jit/a64.zig` (new), `src/jit/a64_golden.zig` (new, generated), `tools/jit-asm-golden.sh` (the option `--arch aarch64`).

## The forms

| Group | Forms |
|---|---|
| Moves | `mov x, x`; `mov w, w`; `movz`, `movk`, `movn` with a 16-bit value and a shift; `ldr` and `str` of `x` and `w` with a scaled unsigned 12-bit offset; `ldur` and `stur` with a signed 9-bit offset; `ldrb`, `strb`; `ldp` and `stp` of `x` with pre-index and post-index (the prologue) |
| Arithmetic | `add`, `sub` with a 12-bit immediate, with and without a shift of 12; `add`, `sub`, `adds`, `subs` of registers; `cmp` with a register and with an immediate; `and` and `tst` with the masks 0x3 and 0x7 and 0xff; `mul`, `smulh`, `sdiv`, `msub`; `asr` by an immediate; `cset` |
| Control | `b`; `b.cond` for the 14 conditions; `cbz`, `cbnz`; `br`; `blr`; `ret` |
| Other | `brk`; `udf`; `nop` |
| Floating point (tier 2) | `ldr` and `str` of `d`; `fmov d, d`; `fmov d, x`; `fmov x, d`; `fadd`, `fsub`, `fmul`, `fdiv`; `fcmp`; `scvtf` |

## Rules

- The assembler never emits a use of `x18`. An emit call with `x18` is an error. `x16` and `x17` are temporaries of the assembler for a large offset.
- An offset that does not fit the scaled form uses `movz` and `movk` into `x16` and a register offset form. Add that form.
- `b.cond`, `cbz`, and `cbnz` reach 1 MiB. A `Code` whose machine code is above 1 MiB stays in the interpreter on arm64. The compiler checks the size before it binds a label, and a fix-up that does not fit is an error, never a wrapped value.
- `tbz` and `tbnz` are not used.
- A value that does not fit its field is an error.

## Acceptance

```sh
CAP tools/jit-asm-golden.sh --arch aarch64 --check
CAP tools/jit-asm-golden.sh --arch aarch64 --random 1000000
CAP zig build test
```

The golden test runs on x86-64 Linux: it only compares bytes.

## Must not change

`src/jit/x64.zig` and its golden file.

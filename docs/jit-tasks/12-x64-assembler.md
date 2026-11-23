# Task 12: the x86-64 assembler

## Goal

An assembler for the instruction forms that tier 1 and tier 2 use. It writes to a growable buffer and resolves labels.

## Files

- `src/jit/x64.zig` (new), `src/jit/x64_golden.zig` (new, generated), `tools/jit-asm-golden.sh` (new).

## The forms

`r` is one of the 16 general registers. `m` is `[base + disp]` with a signed 32-bit displacement and any base register. No form has an index register.

| Group | Forms |
|---|---|
| Moves | `mov r64, r64`; `mov r32, r32`; `mov r64, m`; `mov m, r64`; `mov r32, m`; `mov m, r32`; `mov m, r8`; `movzx r32, byte m`; `movzx r32, r8`; `mov r32, imm32`; `mov qword m, imm32`; `mov dword m, imm32`; `mov byte m, imm8`; `lea r64, m` |
| Arithmetic | `add`, `sub`, `and`, `or`, `xor`, `cmp` as `r64, r64`; `r64, m`; `r64, imm32`; `qword m, imm32`; `dword m, imm32`; `r32, m`. Also `cmp byte m, imm8`; `test r32, r32`; `test byte m, imm8`; `and r32, imm32`; `imul r64, r64`; `imul r64, m`; `inc qword m`; `dec qword m`; `neg r64`; `cqo`; `idiv r64` |
| Flags | `setcc r8` and `jcc rel32` for the 16 conditions |
| Control | `jmp rel32`; `jmp r64`; `jmp m`; `call m`; `call r64`; `ret`; `push r64`; `pop r64` |
| Other | `int3`; `ud2`; `nop` |
| SSE2 (tier 2) | `movsd xmm, m`; `movsd m, xmm`; `movapd xmm, xmm`; `addsd`, `subsd`, `mulsd`, `divsd`, `ucomisd` as `xmm, xmm`; `cvtsi2sd xmm, r64`; `movq xmm, r64`; `movq r64, xmm` |

## Rules

- The encoder picks an 8-bit displacement when the value fits, and an 8-bit immediate for the arithmetic group when the value fits.
- The bases `rsp` and `r12` need a SIB byte. The bases `rbp` and `r13` need a displacement byte also for zero.
- A byte register `spl`, `bpl`, `sil`, or `dil` needs a REX prefix. Test them.
- A branch is always `rel32`. A label has a list of fix-ups. `bind` writes each one. An unbound label at the end is an error.
- Each emit function returns `Allocator.Error!void`. No function can write outside the buffer: the buffer is an `ArrayList`.
- A displacement or an immediate that does not fit its field is a compile error of the template (a `std.debug.assert` on a comptime value) or a returned error for a run-time value. It never wraps.

## The golden file

`tools/jit-asm-golden.sh` writes each form for each register (and for the displacements 0, 1, -1, 127, 128, -128, -129, and 0x7fffffff, and the immediates of the same set) to an assembly file, assembles it with `zig cc -c`, reads the bytes, and writes `src/jit/x64_golden.zig`: a table of the form, the operands, and the bytes. The unit test encodes each row and compares. `--check` builds the table again and fails when it differs from the file in the repository.

## Acceptance

```sh
CAP tools/jit-asm-golden.sh --check
CAP zig build test       # the golden test passes: each row, no skip
```

New tests: a forward and a backward branch give the correct `rel32`; an unbound label gives an error; the function of `mem.selfTest` built with this assembler returns 42.

## Must not change

No file outside `src/jit/` and `tools/`.

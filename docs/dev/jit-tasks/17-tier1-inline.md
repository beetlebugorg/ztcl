# Task 17: the inline fast paths

## Goal

The common case of the hot instructions runs with no call. The gates of milestone 1 pass.

## Files

- `src/jit/tier1_x64.zig`. `bench/jit-gates.tsv` (new).

## Rules for each template

1. No value is in a register across the boundary of two bytecode instructions.
2. A fast path checks each tag that it relies on. Each other case jumps to a slow stub of that instruction. The slow stub calls the helper of the whole instruction and jumps back to the next instruction.
3. A fast path has no effect before its last check. So the helper can run the whole instruction again.
4. A cell: load `vars.items` from the frame, load the cell pointer of the slot, read the tag byte with the mask. For the tag `.link`, a stub follows the link in a loop and jumps back. For each other tag that is not `.val`, use the slow stub.
5. A copy of a `Value` is two 8-byte moves and one byte move for the tag.
6. A literal is read from `code.lits`. No value of a script is an immediate operand.
7. Each offset comes from `Layout`.

## The templates

| Instruction | Fast path |
|---|---|
| `step` | If `step_limit` is 0: slow. Decrement it. If `counter.used > mem_limit`: slow, after an increment that restores the count. |
| `guard` | If `epoch != safe_epoch`: call `hRecheck`; on 1, jump to the cold block. Then the code of `step`. |
| `jump` | `jmp` |
| `push`, `push_empty`, `pop` | Copy the literal. `pop` has no code. |
| `load` | The cell has the tag `.val`: copy its value to the stack. |
| `store`, `store_pop` | The cell has the tag `.val`: copy the value to the cell. |
| `jump_false`, `jump_true`, `to_bool` | The value is an `.int`: compare with zero. |
| `bin_vv`, `bin_vi`, `binary` | Both operands are `.int` and the operator is `+`, `-`, `*`, or a compare: compute, check the overflow flag, write an `.int`. |
| `jf_vv`, `jf_vi` | Both operands are `.int`: compare and jump. |
| `incr`, `incr_drop`, `incr_value` | The cell holds an `.int` (and the top of the stack for `incr_value`): add, check the overflow flag, write. |

Each other instruction keeps the helper call of task 16.

The slow path of `step` must give the exact state of the interpreter: `opStep` fails before the decrement when the limit is 0, and fails after the decrement when the memory is above the limit. Write the template so that the helper sees the state before the instruction.

## Acceptance

```sh
CAP zig build test
CAP tools/suite.sh -j                 # pass 19877
CAP tools/jit-perf.sh --check jit
CAP tools/jit-perf.sh --check off
```

Gates in `bench/jit-gates.tsv` (instructions, `--jit`, default threshold):

| Script | At most |
|---|---|
| `sum.tcl` | 110 M |
| `fib.tcl` | 125 M |
| `nested.tcl` | 165 M |
| `strbuild.tcl` | 270 M |
| `foreach.tcl` | 110 M |
| `dict.tcl` | 230 M |
| `dictgrow.tcl` | 580 M |
| `readloop.tcl` | 165 M |

Milestones 0 and B change the counts of the interpreter. If the baseline of task 10 differs from the table "Instruction counts" of `docs/dev/jit.md` by more than 3 % for a script, scale the gate of that script by the same ratio and say so.

Also: `--jit --jit-stats` on the eight scripts gives a mean of at most 96 code bytes for one bytecode instruction. The compile uses at most 400 machine instructions for one bytecode instruction: measure `sum.tcl` with a step limit of 0 (the script stops at once) with and without `--jit --jit-threshold 0`.

New unit tests, each compared with the interpreter: an overflow of `+`, `-`, `*`, and `incr` at both ends of the 64-bit range (the result is a big integer); a string operand `"10"`; a double operand; an unset variable (the error text); a slot that is an `upvar` link to a global, two links deep; a traced cell; an array name used as a scalar; a compare of the smallest and the largest integer.

## Must not change

The step count of each script: `--report` gives the same `steps` with and without `--jit`.

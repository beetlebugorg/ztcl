# Task 24: more inline code

## Goal

The inline paths of milestone 2.

## Files

- `src/jit/tier1_x64.zig`, `bench/jit-gates.tsv`.

## The templates

| Instruction | Fast path |
|---|---|
| `foreach_next` | The two stack places hold a list and an integer (checked). The index is below the length: run the code of `step`, then for each slot of the table (at most 4 slots inline), store the item into a `.val` cell. A cell with another tag: slow stub for the whole instruction. |
| `lappend` | The cell holds a list, `obj.used == len`, and `used < buf.len`: write the value at `buf[used]`, add 1 to `used` and to the length in the cell, copy the list value to the stack. |
| `access` `llength` | The value is a `.list`: its length. |
| `access` `lindex` | The list is a `.list` and the index is an `.int`: an unsigned compare with the length, then a copy of the item, or the empty string. |
| `bin_vv`, `bin_vi`, `binary` with `/` and `%` | Both `.int`, the divisor is not 0 and not -1: `idiv`, then the floor rule of Tcl for operands of different signs. Each other case: slow stub. |
| new instructions of tasks 07 and 08 | `str_eq_jump` when both strings have equal length: a call of one compare helper with no error path. `lset_drop` on an owned list with an integer index in range. |

The rules of task 17 apply. For `lappend`, the fast path writes to the buffer before it changes `used`: no check comes after the first write.

## Acceptance

```sh
CAP zig build test
CAP tools/jit-diff.sh && CAP tools/jit-diff.sh --stress
CAP tools/suite.sh -j
CAP tools/jit-perf.sh --check jit
CAP zig build jit-fuzz -- --count 200000
```

New gates: `nested.tcl` 135 M, `foreach.tcl` 88 M, `readloop.tcl` 150 M, `dict.tcl` 215 M.

New unit tests: `%` and `/` for each sign pair, for a divisor of 0 (the error of Tcl) and of -1 with the smallest integer; `lindex` with a negative index, the length, and a huge index; `lappend` to a list that another variable shares, and to a list at its capacity; `foreach` over a list that the body changes with `lappend` and with `set`; `foreach` with a traced loop variable.

## Must not change

The step counts. `foreach_next` uses its step at the same place as the interpreter: after the bound check and before the first store.

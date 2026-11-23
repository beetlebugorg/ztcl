# Task 36: calls out of a loop

## Goal

A loop with helper calls compiles. `nested.tcl` and `foreach.tcl` reach their gates.

## Files

- `src/jit/tier2.zig`, `src/jit/tier2_types.zig`, `src/jit/tier2_x64.zig`.

## Rules

- Before a call of a helper, write each register that changed since its last write to its cell, and each virtual stack place below the call to the value stack. The state is then the state of tier 1 at that instruction.
- The call is the tier 1 helper call, with the same error stub.
- After a call that can run a script (`invoke`, `eval_cmd`, `word`, `node`, a store or a read on a cell that is not `.val`): check the epoch, and run the checks of the entry block for each slot in a register, then load each one. A failed check is an exit at the next instruction.
- After a call that cannot run a script (`lappend` on a plain cell, `llength`, `lindex`, `concat`, `append` on a plain cell): load only the registers that the call can change. The list of these helpers is a table in `tier2.zig`, and each entry has a comment with the reason. A helper that can run a trace is not in the list.
- `foreach_next` inline: the item is copied to its slot. If the plan has kind `int` for that slot, a guard checks the tag of the item and loads the payload. A failed guard is an exit before the store.
- A part ends at each call. The step check of a part is before its first instruction, as in task 34.
- The result of a helper has kind `any`, with one exception: `llength` gives `int`.

## Acceptance

```sh
CAP zig build test
CAP tools/jit-diff.sh --tier2 --stress
CAP tools/suite.sh -j2 -a -r zig-out/bin/ztcl-suite      # pass 37383, each file equal
CAP tools/jit-perf.sh --check jit2
CAP zig build jit-fuzz -- --tier2 --stress 32 --count 1000000
CAP tools/suite.sh -j2 -g 64                              # the collector stress: pass 19877
```

Gates: `nested.tcl` 100 M and `foreach.tcl` 45 M, or the numbers that task 32 set.

New unit tests, each compared with the interpreter: a callee changes a local of the loop through `upvar` in pass 500; a callee adds a trace to a loop variable; a callee renames `incr`; a callee makes a loop variable an array (`unset` then `array set`); a callee links two loop variables with `upvar 0`; a callee raises an error, and `errorInfo` is equal; a `foreach` over a list with one string item in the middle of integers.

## Must not change

The step counts. The rule: no pointer to a heap block is only in a register across a helper call.

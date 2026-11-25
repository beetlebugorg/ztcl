# Task 34: integer loops in registers

## Goal

Tier 2 compiles a loop with no call out. `sum.tcl` reaches its gate.

## Files

- `src/jit/tier2.zig`, `src/jit/tier2_x64.zig` (new), `src/jit/tier1_x64.zig` (the loop counter), `src/jit.zig` (`tierUp`, `deopt`), `src/jit/helpers.zig`.

## The entry

- Tier 1 code of a loop head with `Options.tier2` on: decrement a 32-bit counter in the JIT data of the loop (reached through the context, with no absolute address). At zero, call `hTierUp(ctx, pc)`.
- `hTierUp` makes the plan with the kinds of the cells now, compiles, and returns the address of the entry block, or 0. On 0, the counter gets its largest value and tier 1 continues. On an address, tier 1 jumps to it with `jmp rax`. `jit.tierUp` checks that the address is the start of a tier 2 function of this loop.
- The entry block: for each slot of the plan with kind `int` or `double`, load the cell pointer, check that the slot entry itself has the tag `.val` (not a link), check the value tag, and load the payload into its register. A slot of kind `any` has no check. Check the epoch. Check that `counter.used <= mem_limit`. A failed check jumps to an exit at the loop head with no state to write.

## The body

- At most 5 slots are in registers: `r8` to `r11` and `rdx`. The plan picks the slots with the most uses. Each other `int` slot stays in its cell and is read and written with no tag check.
- The value stack is virtual: the compiler knows for each place a register, a literal, or a slot. An integer literal is read from `code.lits` into a scratch register.
- A part with `k` steps: `cmp step_limit, k`, `jb` to the exit at the first instruction of the part, `sub step_limit, k`. `step_limit` is in memory.
- `+`, `-`, `*`, `incr`: the operation, then `jo` to the exit of that instruction. The operation writes a scratch register first, and the slot register changes only after the check.
- A `store` to a slot in a register is a register move.
- The back jump goes to the top of the body, after the entry block.
- The loop end (the false branch of the head compare) writes each changed register to its cell with the tag `.int`, and jumps to the tier 1 code of the address after the loop.

## The exits

- Each exit has a record in JIT data: the bytecode address, the stack depth, for each stack place and each slot in a register its register or literal and its kind, and the steps to give back.
- The exit code in the function saves the value registers to a save area in the JIT frame and calls `hDeopt(ctx, exit_id)`.
- `jit.deopt` checks `exit_id` against the count of records, writes each value to its cell or its stack place, adds the steps back, sets `ctx.pc` and `ctx.sp`, and returns status 2 through the epilogue. `run` then enters tier 1 at that address.
- An exit is at an instruction boundary. No effect of the instruction of the exit is done.

## Acceptance

```sh
CAP zig build test
CAP tools/jit-diff.sh --tier2 && CAP tools/jit-diff.sh --tier2 --stress
CAP tools/suite.sh -j2                # a new option: adds --jit-tier2 with a loop count of 2. pass 19877
CAP tools/jit-perf.sh --check jit2    # the tier 2 gates
CAP zig build jit-fuzz -- --tier2 --count 500000
```

Gate: `sum.tcl` at most 16 M instructions with `--jit --jit-tier2`, or the number that task 32 set.

New unit tests, each compared with the interpreter: the step limit ends at each of the four steps of one pass of the `sum.tcl` loop; an overflow in pass 1000 (the result is a big integer); a memory limit that is passed before the loop; a slot that is an `upvar` link (no tier 2, same result); two slots that link to one cell; a loop whose bound is a string `"10"`; `break` and `continue` in the loop.

## Must not change

Tier 1 with `tier2` off: each count and gate. The step counts.

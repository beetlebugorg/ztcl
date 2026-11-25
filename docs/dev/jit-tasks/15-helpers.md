# Task 15: one function for each bytecode instruction

## Goal

Each handler of `vm.exec` moves to a named function. The interpreter and the JIT helpers then run the same code for each instruction.

## Files

- `src/vm.zig`: the functions and the new body of `exec`.
- `src/jit/helpers.zig` (new): the table.

## The form

```zig
pub inline fn opLoad(comptime named: bool, it: *Interp, f: *Frame, code: *const Code,
                     stack: [*]Value, sp: u32, i: *const Ins) Error!void
```

- One function for each member of `Op`. `access` has one function for each of its four forms.
- The function reads and writes the value stack at the offsets of `sp`. It does not change `sp` or `pc`. `exec` applies the stack effect of the table in task 14 and the jump.
- A function for an instruction with two successors returns `Error!bool`: true for the jump. These are `opGuard` (true: go to the cold block), `opJumpFalse`, `opJumpTrue`, `opJfVv`, `opJfVi`, and `opForeachNext` (true: the loop is done).
- `exec` calls each function with `inline`. The dispatch (`continue :sw`) stays in `exec`.
- `src/jit/helpers.zig` has one wrapper for each function, for `named` false:

```zig
fn hLoad(ctx: *EnterCtx, pc: u32, sp: u32) callconv(.c) u32
```

  A wrapper returns 0 for done or false, 1 for true, and 2 for an error. For an error, it stores the Zig error in `ctx.err`.
- `pub const table: [count]*const anyopaque` lists the wrappers in the order of an enum `Helper`. The table is a constant.
- `opForeachNext` checks that the two stack places hold a list and an integer. A wrong kind is the error `TclError` with the message `internal error: bad loop state`. The verifier makes this case unreachable.

## Acceptance

```sh
CAP zig build test
CAP tools/suite.sh                    # pass 19877
CAP tools/jit-perf.sh --check off     # each count at most 1 % above the baseline
CAP zig build bench                   # same sum: true
```

If the 1 % gate fails for a script, find the handler whose code changed (`perf annotate`), and keep that handler inline in `exec` with a comment. Report each such handler: the JIT helper of that instruction then calls a copy, and task 18 must test it more.

## Must not change

The result of each script. The step counts. The order of the checks inside each instruction.

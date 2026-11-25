# Task 07: `switch` as bytecode

## Goal

`switch` with literal patterns and literal bodies runs inline. Today it is a general command: 2140 instructions and 128 bytes for one pass of a two-arm switch, against 660 instructions in `tclsh`.

## Files

- `src/vm.zig`: the compiler form and one new instruction.
- `src/tests.zig`.
- `docs/dev/design.md`: the instruction table.

## The form that compiles

- `switch ?-exact? ?--? string {pattern body ...}` and the form with the patterns and bodies as separate words.
- The option list is empty, `-exact`, or `-exact --`, or `--`. Each other option uses the general path.
- The pattern list is one literal word, or each pattern and each body is a literal word.
- A body of `-` falls through to the next body. `default` as the last pattern matches each string.
- The string word is any word.

## The code

- `name` is in `inline_names`, so the guard covers it.
- A new instruction `str_eq_jump`: it compares the string form of the top of the stack with literal `a` and jumps to `b` when they are equal. The value stays on the stack. Emit one for each pattern, then a `pop` and the body at each target. An integer on the stack compares by its string form with no allocation: format it in a 24-byte buffer.
- No match and no `default` gives the empty string.
- Add a `Range` for the command, so the error trace has the `switch` command. `break` and `continue` in a body go to the enclosing loop as today.

## Acceptance

```sh
CAP zig build test
CAP tools/suite.sh switch.test        # pass 106 or more, fail 7 or fewer
CAP tools/mem-flat.sh                 # switch.tcl: 0 bytes for each pass
CAP perf stat -e instructions:u zig-out/bin/ztcl tests/mem/switch.tcl 1000000
```

Gate: `tests/mem/switch.tcl` with one million passes uses at most the instruction count of `tclsh` 8.6.16 for the same script (665 M on 2026-11-23).

New tests: each form above, fall through, `default`, no match, an integer string, a pattern with a space, `rename switch`, a proc named `switch` in a namespace, and an error in a body with the `errorInfo` of `tclsh`.

## Must not change

The pass count of each suite file. The step count of a script with no `switch`. A `switch` uses one step for its guard, as each inline form does. Record the new step count of a script with `switch` in the PR body.

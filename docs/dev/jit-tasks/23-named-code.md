# Task 23: scripts outside a proc

## Goal

A `Code` with `named` true compiles. Its variables use names, so each variable instruction calls its helper.

## Files

- `src/jit/helpers.zig` (the wrappers for `named` true), `src/jit/tier1.zig`, `src/jit/verify.zig` (check 11 goes away).

## Rules

- A named `Code` uses the helper call of task 16 for `load`, `store`, `store_pop`, `incr`, `incr_drop`, `incr_value`, `lappend`, `append`, `bin_vv`, `bin_vi`, `jf_vv`, `jf_vi`, and `foreach_next`. The inline templates of task 17 serve `guard`, `step`, `jump`, `push`, `pop`, `jump_false`, `jump_true`, `to_bool`, and `binary`.
- The frame check of `enter` does not apply: a named `Code` runs in any frame.
- `code.hints` is data that the helpers change. The machine code does not read it.
- The verifier checks that a named `Code` has no `dict_update`, no `dict_update_drop`, and no `ret` that the bytecode compiler does not make for named code.

## Acceptance

```sh
CAP zig build test
CAP tools/jit-diff.sh && CAP tools/jit-diff.sh --stress
CAP tools/suite.sh -j -a -r zig-out/bin/ztcl-suite      # pass 37383, each file equal
CAP zig build jit-fuzz -- --count 200000
```

New scripts in `tests/jit/`: a loop at the global level that runs two times; `eval` of one string 1000 times; `uplevel` of a loop body; `namespace eval` with a loop; an event script (`after 0`) that runs 100 times; a `while` body in `apply`.

Report the instruction count of a global loop of one million passes of `incr i` with and without `--jit`. This task has no gate for it.

## Must not change

The gates of task 17.

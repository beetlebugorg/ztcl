# Task 35: the exit stress mode and the drop of a loop

## Goal

Force each exit path, and stop a loop that exits again and again.

## Files

- `src/jit/tier2.zig`, `src/jit/tier2_x64.zig`, `src/jit.zig`, `src/main.zig`.

## Rules

- `--jit-stress` gets bit 32: each guard of tier 2 has a counter, and each Nth check of a guard fails, for N from the seed 3, 7, 13 in turn. A forced exit is correct by design: the interpreter state at an exit is complete, so tier 1 continues with the same result.
- After 8 exits of one loop that were not forced, `jit.deopt` marks the loop as dropped. Tier 1 no longer calls `hTierUp` for it. The memory of the tier 2 function stays until `flush`.
- `--jit-stats` counts `tier2` (compiled loops) and `exits`.

## Acceptance

```sh
CAP tools/jit-diff.sh --tier2 --stress        # with bit 32: exit code 0
CAP zig build jit-fuzz -- --tier2 --stress 32 --count 500000
CAP tools/suite.sh -j2 -a -r zig-out/bin/ztcl-suite     # pass 37383, each file equal
```

New unit tests: a loop that overflows in each pass compiles one time, exits 8 times, and then runs in tier 1, with `exits=8` in the counts; with bit 32, each script of `bench/` gives its output and the same step count; an exit with 5 values in registers and 3 stack places writes each one to the right place (compare each cell with the interpreter after a forced exit at each exit of one loop).

## Must not change

The gate of task 34 with the stress mode off.

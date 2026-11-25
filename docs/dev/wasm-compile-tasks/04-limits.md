# Task 04: the step limit and the memory limit in the module

Platform: shared/web.

## Goal

`run` keeps the step limit and the memory limit of the design. The interpreter gives the same step count.

## Files

- `src/point.zig`: one new pure function `Program.steps(n)`: the setup count plus the count of `ops` for each block. No other change.
- `src/point_wasm.zig`: the step check before each block, and the results -1 and -2.
- `tools/point-wasm-diff.mjs`: checks the step count of each run against `Program.steps(n)`.

## Rules

- The module has no `memory.grow`. Its memory has the same minimum and maximum.
- `cap` is the most points whose columns fit in the memory after the fixed parts.

## Acceptance

```sh
CAP zig build test
CAP tools/point-wasm-diff.sh
node tools/point-wasm-limits.mjs     # a run with steps one short of a block stops with -1; n = cap + 1 gives -2; a grow from the host past the maximum fails
wasm-tools print zig-out/fuzzy.wasm | grep -c memory.grow      # 0
```

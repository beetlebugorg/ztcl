# Task 32: the model and the census for tier 2

The user decides after this task if tier 2 continues.

## Goal

Measure what tier 2 can give, before any compiler code. `docs/dev/jit.md` has one measured model (the loop of `sum.tcl`: 10.2 M instructions). The other tier 2 numbers are estimates.

## Files

- `tools/jit-model/` (new): hand-written assembly models and a small C or Zig driver. `tools/jit-census.zig` (new). `docs/dev/jit.md` (the tier 2 gates).

## The work

1. **Models.** Write the tier 2 form of the inner loop of `nested.tcl`, of `foreach.tcl`, and of a loop of doubles (`set s [expr {$s + $x * 0.5}]`) by hand, with the rules of "Tier 2" in `docs/dev/jit.md`: guards, the joined step check, the write of each changed register before a call, and the checks after it. Each model calls the real helper cost as a counted stub. Measure the instruction count of each.
2. **Census.** `tools/jit-census.zig` reads the `Code` of each proc that a script compiles and counts the loops by class: (a) only instructions of the integer set, (b) those plus calls out, (c) not eligible, with the first instruction that makes it so. Run it on `bench/`, on `tests/jit/`, on the outside programs, on the 37 core suite files, and on each zslice script that the user provides.
3. **Report.** For each benchmark: the tier 1 count, the model count, and the share of loop passes that run in eligible loops.

## Acceptance

```sh
CAP tools/jit-model/run.sh          # prints the table
CAP zig build jit-census -- bench/*.tcl
```

- The model of `sum.tcl` gives 10.2 M instructions within 5 %.
- The report sets the final tier 2 gates in `docs/dev/jit.md`. The provisional gates are: `sum.tcl` 16 M, `nested.tcl` 100 M, `foreach.tcl` 45 M.
- The user reads the report and decides: continue, or stop after tier 1.

## Must not change

No file of `src/`.

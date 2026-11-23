# Task 39: the condition for a default of on

## Goal

Check the six conditions of `docs/jit.md` for one target and record the result. This task changes a default only when the user says so.

## Files

- `docs/jit.md` (a table with the result of each condition for each target), `src/main.zig` (the default of `--jit`, only on the word of the user), `CHANGELOG.md`.

## The checks

1. `tools/suite.sh -a -r zig-out/bin/ztcl-suite` in four runs: no flag, `-j`, `-j` with the default threshold (a new option `-J`), and `-j2` with stress bit 32. Each file has the same counts in all four.
2. `zig build jit-fuzz` for 72 hours of processor time in total, in runs of at most 4 hours, with `--tier2 --stress 32` for half of them. `--verify` and the assembler fuzzer for 24 hours each. Record each seed range.
3. `zig build test` and `tools/suite.sh -j` with the runner in `Debug` and in `ReleaseSafe`.
4. The reviewer signs each item of `docs/jit-review.md`. No security finding is open.
5. `tools/jit-perf.sh --check jit`, `--check jit2`, and `tools/kostya.sh --jit`. No script of `bench/` and no outside program uses more instructions with the JIT than without.
6. The record of 30 days of use in zslice with the JIT as an opt-in: the count of runs and each bug.

Run the long jobs one at a time, each under the memory cap.

## Acceptance

The table in `docs/jit.md` has a result and a date for each condition. The user decides the default. The library option stays off in each case.

## Must not change

The default of `Interp.enableJit`: an explicit call of the embedder.

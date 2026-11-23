# Task 18: the differential tests, the suite mode, and the docs

## Goal

The proof that the JIT and the interpreter agree, as a tool that each later task runs. Milestone 1 can ship after this task.

## Files

- `tools/jit-diff.sh` (new), `tests/jit/*.tcl` (new).
- `docs/design.md` (a JIT section), `docs/testing.md`, `docs/embedding.md` (`enableJit`), `README.md` (one row in the command table and one paragraph), `SECURITY.md`, `CHANGELOG.md`, `AGENTS.md` (the commands and one rule: the JIT and the interpreter must agree).

## `tools/jit-diff.sh`

For each script of `tests/jit/`, `tests/mem/`, and `bench/`, the tool runs the runner in these modes with `--report --gc off` and compares stdout, stderr without the `jit` line, the exit code, and the `steps` and `mem` fields:

1. no flag (the reference)
2. `--jit --jit-threshold 0`
3. `--jit` (default threshold)

It then runs the step limit sweep on each script of `tests/jit/sweep/`: for each step limit from 0 to the full step count of the script (at most 3000 per script), modes 1 and 2 give equal output.

## The scripts of `tests/jit/`

At least one script for each row of the table "How the semantics of Tcl stay exact" in `docs/jit.md`, and one for each instruction of `Op`. Each script prints its results, and its expected output comes from `tclsh` 8.6.16 where `tclsh` has the command. Keep each script below 2 seconds.

## Acceptance

```sh
CAP tools/jit-diff.sh                               # exit code 0
CAP tools/suite.sh -j                               # pass 19877, each file equal to the run without -j
CAP tools/suite.sh -j -a -r zig-out/bin/ztcl-suite  # pass 37383, each file equal
CAP tools/jit-perf.sh --check jit && CAP tools/jit-perf.sh --check off
CAP tools/kostya.sh --jit                           # the outputs of tclsh. Report the ratios.
CAP zig build test && CAP zig build test -Djit=false && CAP zig build wasm
```

A test measures the native stack: a proc that calls itself 500 levels deep reports the stack distance (`native_base` minus the frame address at the deepest level, through a test command of `tools/suite_cmds.zig`). The distance with `--jit` is at most the distance without.

## Must not change

Each count. The default of the JIT: off in the library, off in the runner.

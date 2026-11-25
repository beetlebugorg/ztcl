# Task 25: direct calls of procs

## Goal

A call from compiled code to a compiled proc skips the general parts of the call path. This is the end of milestone 2.

## Files

- `src/jit/helpers.zig`, `src/jit/tier1_x64.zig`, `src/interp.zig` (one hunk: `runProc` becomes callable from the helper, with no change to its body), `bench/jit-gates.tsv`.

## Rules

- The template of `invoke` loads the site and checks inline: `site.resolved` is not null, `site.epoch == it.epoch`, and `site.ns == it.ns.ptr`. On a miss, it calls the helper of task 16.
- On a hit, it calls `hCallCached`. This helper runs the step check, reads the command, and for a proc with no traces calls the proc path directly. A native command calls its function.
- The semantics come from `runProc`, `callProc`, and `runTail` as today: the frame, the defaults, `args`, the return codes, and tail calls. The helper adds no second copy of that logic.
- `jit.enter` gets a short path for a `Code` with `.ready` state: no second read of the state.
- Measure first: `perf record` on `fib.tcl` with `--jit`. Report the share of each function, and remove only cost that the profile shows.

## Acceptance

```sh
CAP zig build test
CAP tools/jit-diff.sh && CAP tools/jit-diff.sh --stress
CAP tools/suite.sh -j -a -r zig-out/bin/ztcl-suite      # pass 37383, each file equal
CAP tools/jit-perf.sh --check jit
CAP tools/kostya.sh --jit
CAP zig build jit-fuzz -- --count 500000
```

New gate: `fib.tcl` 112 M. If the profile shows that the frame (`pushFrame`, `newLocal`, `popFrame`) is the rest of the cost, report it and stop: a cheaper frame is separate work on the interpreter.

The outside gate: `bf.tcl bench.b` and `bf_oo.tcl bench.b` with `--jit` have a ratio against `tclsh` at or below the number that the user set (provisional: 0.35), with equal output. `base64/test.tcl` stays at or below 1.0.

New unit tests: a call with too few and too many arguments; a proc with defaults and with `args`; a proc renamed between two calls of one site; a site that runs in two namespaces; a command with an execution trace; a call of a proc that deletes itself; `tailcall` to a compiled proc; a recursion to the depth limit (the error text and `errorInfo` of the interpreter).

## Must not change

The step counts. The frames that `info level` and `uplevel` see.

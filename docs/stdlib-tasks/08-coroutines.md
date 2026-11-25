# Task 08: The coroutine switch on arm64, macOS, and Windows

Platform: shared.

## Goal

The stack switch of `src/coro.zig` on arm64 Linux, arm64 macOS, x86-64 macOS, and x86-64 Windows.

## Files

- `src/coro.zig`: the switch for each target, after the register sets of `std.Io.fiber` and the ABI rules of each system (Windows: the TIB stack fields and the shadow space).
- The collector: the stack scan of a coroutine on each target (`src/gc.zig`).

## Test sources

- The core file `coroutine.test` on each target.
- The coroutine tests of `tests/` with `--gc-stress 1`.

## Acceptance

```sh
CAP tools/suite.sh coroutine.test     # on each of the four targets
CAP zig build test -Dgc-precise=true
```

Gates:

- The pass count of `coroutine.test` on each target equals the count on x86-64 Linux.
- No change on x86-64 Linux: `tools/jit-perf.sh --check off` passes.

The task runs on each target. The PR has the output of each one.

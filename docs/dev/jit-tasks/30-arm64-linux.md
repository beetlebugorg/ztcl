# Task 30: arm64 Linux

## Goal

Tier 1 on arm64 Linux, with the templates of task 27 and the memory calls of task 11.

## Files

- `src/jit/mem.zig`, `src/jit/abi.zig`, `src/gc.zig`, `src/jit.zig`.

## Rules

- The memory calls are those of x86-64 Linux. The fill is zero words. The page size comes from the system at run time: it can be 4, 16, or 64 KiB.
- After the pages are executable, flush the instruction cache for the exact range: `extern fn __clear_cache(start: usize, end: usize) callconv(.c) void`. The Zig runtime has this function. Check in the disassembly of the binary that it is present and not empty.
- `mmap` and `mprotect` do not use `PROT_BTI` or `PROT_MTE`.
- `x18` stays unused, as on macOS.
- The coroutine switch of `coro.zig` has no arm64 Linux form on `main`. The JIT does not need it: when `coro.supported` is false, `coroutine` gives its error as today.

## Acceptance

On an arm64 Linux machine, or under `qemu-aarch64` with a note that the cache flush is then not tested:

```sh
CAP zig build test && CAP zig build test -Djit=false
CAP tools/jit-diff.sh && CAP tools/jit-diff.sh --stress
CAP tools/suite.sh -j
CAP zig build jit-fuzz -- --count 200000
CAP tools/jit-perf.sh --record && CAP tools/jit-perf.sh --check jit    # on real hardware
```

The gates of x86-64 do not apply. Record the counts of this target and report the ratio of each script with and without `--jit`. No script uses more instructions with `--jit`.

## Must not change

The results of the other targets.

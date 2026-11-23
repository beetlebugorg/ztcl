# Task 38: tier 2 on arm64

## Goal

Tier 2 on arm64 macOS and arm64 Linux.

## Files

- `src/jit/tier2_a64.zig` (new), `src/jit/abi.zig`.

## Rules

- Value registers: `x9` to `x13` for integers, `d16` to `d19` for doubles. `x14`, `x15`, `d20`, and `d21` are scratch. They are caller-saved, so each call out writes and loads them as on x86-64.
- The overflow checks of task 27. `fadd`, `fsub`, `fmul`, `fdiv`, and `fcmp`. No `fmadd`.
- The exit code saves the value registers to the save area before the call of `hDeopt`.
- The same plan, exit records, and tests as x86-64.

## Acceptance

On each arm64 target:

```sh
zig build test
tools/jit-diff.sh --tier2 --stress
tools/suite.sh -j2
zig build jit-fuzz -- --tier2 --stress 32 --count 500000
zig build bench                            # same sum: true
```

No script of `bench/` is slower with tier 2 than with tier 1 (time, best of 11 runs, or the instruction count on Linux).

## Must not change

The results of x86-64.

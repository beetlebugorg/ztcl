# Task 42: tier 2 on RV64

## Goal

Tier 2 on RV64: the lowering of `src/jit/tier2_lower.zig` to RV64 in `src/jit/tier2_rv64.zig`, as task 38 did for arm64.

## Rules

- The exits, the guards, and the counts of compute units equal those of x86-64 for each script of `tests/jit/`.
- Doubles use the D extension. A target without D keeps tier 2 off.

## Acceptance

- `tools/jit-diff.sh -t` under qemu: 0 differ.
- `tools/suite.sh -J -t core-8-6-16` under qemu: the total equals the total without the JIT.

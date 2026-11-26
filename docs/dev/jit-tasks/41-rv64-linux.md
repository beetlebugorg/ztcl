# Task 41: tier 1 on RV64 Linux

## Goal

Tier 1 on `riscv64-linux`, with the templates of `src/jit/tier1_x64.zig` and `src/jit/tier1_a64.zig` written for RV64, under qemu.

## Files

- `src/jit/tier1_rv64.zig` (new), `src/jit/abi.zig`, `src/jit/mem.zig`, `src/jit.zig`, `src/jit/layout.zig`, `build.zig`.

## Rules

- The memory of the JIT follows task 11: no page is writable and executable at one time. After a write and before a run, the code runs `fence.i` through the `riscv_flush_icache` system call, because a write to the code of another hart needs it.
- The frame and the calls follow the LP64D calling convention.
- The JIT and the interpreter agree on each script, as AGENTS.md rule 10 says.

## Acceptance

Under `qemu-riscv64` (user mode), with the runner built for `riscv64-linux-musl`:

- `zig build test -Dtarget=riscv64-linux-musl` with the test runner under qemu.
- `tools/jit-diff.sh -r <runner under qemu>`: 0 differ.
- `tools/suite.sh -j -t core-8-6-16`: the total equals the total without the JIT.

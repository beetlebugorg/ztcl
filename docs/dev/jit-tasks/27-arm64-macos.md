# Task 27: arm64 macOS

## Goal

Tier 1 on Apple silicon. This task needs an Apple silicon Mac. Rebase on the port branch that has `coro.zig` and `sys.zig` for macOS first.

## Files

- `src/jit/mem.zig` (the macOS part), `src/jit/abi.zig`, `src/jit/tier1_a64.zig` (new), `src/gc.zig` (the register capture for arm64, if task 03 did not add it), `src/jit.zig` (`built` is true for this target), `docs/embedding.md`.

## Step 1: the memory calls, alone

Do this first and report the result before step 2.

- `mmap` with `PROT_READ | PROT_WRITE | PROT_EXEC` and `MAP_PRIVATE | MAP_ANON | MAP_JIT` for the whole region. On Apple silicon the system keeps `MAP_JIT` pages writable or executable for one thread, never both.
- `append`: `pthread_jit_write_protect_np(0)`, copy, `pthread_jit_write_protect_np(1)`, then `sys_icache_invalidate(start, len)`. Declare the three functions with `extern "c"`.
- Functions pack with 16-byte alignment. The fill is zero words.
- Check `pthread_jit_write_protect_supported_np()`. When it is false, `Region.init` returns null.
- The compile of a function runs on the thread of the interpreter. The write switch is off only around the one copy. No call of ztcl code is between the two switch calls except the copy.

Test `selfTest` in four programs: not signed; signed ad hoc; signed with the hardened runtime and the entitlement `com.apple.security.cs.allow-jit`; signed with the hardened runtime and no entitlement. The fourth must return false with no crash. Report each result. If a result differs from `docs/dev/jit.md`, stop and report.

## Step 2: the templates

- The pinned registers of `docs/dev/jit.md`. The prologue saves `x29`, `x30`, and `x19` to `x23` with `stp`, sets `x29`, and keeps the stack pointer 16-byte aligned. The frame is at most 96 bytes.
- Arguments of a helper: `x0`, `x1`, `x2`. The call is `ldr x16, [x23, #8 * helper]` and `blr x16`.
- The overflow of `+` and `-`: `adds` or `subs` and `b.vs`. The overflow of `*`: `mul`, `smulh`, and a compare of the high word with the sign of the low word.
- A tag byte: `ldrb`, `and` with the mask, `cmp`.
- No use of `x18`. No pointer authentication.
- The same driver (`tier1.zig`), verifier, helpers, and tests as x86-64.

## Acceptance

On the Mac:

```sh
zig build test && zig build test -Djit=false
tools/jit-diff.sh && tools/jit-diff.sh --stress
tools/suite.sh -j           # each file equal to the run without -j on the same machine
zig build jit-fuzz -- --count 200000
```

- A test reads the rights of the region with `mach_vm_region` (or the output of `vmmap`) after two compiles and reports them.
- Report the times of `tools/bench.py` with and without `--jit`. Instruction counts are not available with `perf` on macOS. This port has a time gate: no script of `bench/` is slower with `--jit`, as the best of 11 runs.
- Use `ulimit -v` or a small machine for the memory cap, because `systemd-run` does not exist on macOS. Report what you used.

## Must not change

The Linux results. `src/coro.zig`.

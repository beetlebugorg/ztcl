# Task 28: x86-64 macOS

## Goal

Tier 1 on an Intel Mac. The templates and the ABI are those of x86-64 Linux. Only the memory calls differ. This task needs an Intel Mac. A run under Rosetta is not a test of this port.

## Files

- `src/jit/mem.zig`, `src/jit.zig` (`built`).

## The memory calls

- On an Intel Mac, a `MAP_JIT` region with write and execute rights is writable and executable at once, and `pthread_jit_write_protect_np` does no work. So this port never asks for both rights.
- `init`: `mmap` with `PROT_NONE` and `MAP_PRIVATE | MAP_ANON | MAP_JIT`.
- `append`: `mprotect` new pages to read and write, copy, fill with 0xCC, `mprotect` to read and execute. Each function starts on a new page, as on Linux.
- If `mprotect` on a `MAP_JIT` region fails under the hardened runtime, try the same sequence with no `MAP_JIT` one time. If that also fails, `init` returns null. Report which form works in each of the four signing cases of task 27.

The author of the plan did not test these calls. If no form gives executable memory under the hardened runtime with only `allow-jit`, the JIT stays off there. Do not use the entitlements `allow-unsigned-executable-memory` or `disable-executable-page-protection`.

## Acceptance

On the Intel Mac: the commands of task 27. Also a test that reads the rights of each page of the region after two compiles: no page has write and execute.

## Must not change

The Linux and arm64 results.

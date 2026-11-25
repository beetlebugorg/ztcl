# Tasks for the memory work and the JIT

[The design](../jit.md) gives the reasons. [The review checklist](../jit-review.md) is for the reviewer. Do the tasks in the order of their numbers. One task is one branch and one review.

## Milestones

| Milestone | Tasks | Result |
|---|---|---|
| 0: memory | 01 to 06 | A long loop holds a flat memory size. The outside benchmarks end. |
| B: builtins | 07 to 09 | `switch`, `lassign`, `lset`, and base64 are at or below the cost of `tclsh`. |
| 1: tier 1 on x86-64 Linux, behind a flag | 10 to 18 | `ztcl --jit` runs proc bodies as machine code. It can ship. |
| 2: hardening and the rest of tier 1 | 19 to 25 | Fuzzers, stress modes, named scripts, more inline code, direct calls. |
| 3: ports | 26 to 31 | arm64 macOS, x86-64 macOS, x86-64 Windows, arm64 Linux. WebAssembly keeps the interpreter. |
| 4: tier 2 | 32 to 38 | Loops of numbers with values in registers. |
| 5: the default | 39 | The check of the condition for a default of on. |

The user decides three things before the work passes them: the collector (before task 02), the order of milestones 3 and 4 (before task 26), and tier 2 at all (at task 32).

## Rules for each task

1. Read AGENTS.md, WRITING.md, `docs/dev/design.md`, and `docs/dev/jit.md` first.
2. Run each build, test, and benchmark under the memory cap, one at a time. `CAP` in each task means this prefix:

   ```sh
   systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 --
   ```

3. A task is done when each command of its acceptance list passes. Put the output of each command in the PR body.
4. The common acceptance commands apply to each task, also when the task does not list them:

   ```sh
   CAP zig build
   CAP zig build test
   CAP tools/suite.sh                       # total: pass 19877
   CAP tools/jit-perf.sh --check off        # from task 10 on
   CAP zig build test -Djit=false           # from task 10 on
   ```

   The pass count of each suite file must not drop. Run `tools/suite.sh -a -r zig-out/bin/ztcl-suite` (all 152 files, pass 37 383) at the last task of each milestone.
5. Timing is noisy on a shared machine. Each performance check is an instruction count: `perf stat -e instructions:u`.
6. Each new source file starts with a `//!` comment that explains its algorithm, and an SPDX line for BSD-2-Clause.
7. Write fresh code. Copy no code from another project. Read no source of a GPL or AGPL project for this work. When a task uses an idea from a source that `docs/references/jit.md` does not list, add the source there.
8. Use only the Zig 0.16.0 standard library. On macOS, the functions of `libSystem` are available. On Windows, declare each `kernel32` function in the JIT file that calls it.
9. Do not change `src/coro.zig`, `src/sys.zig`, `src/sys_windows.zig`, `src/fsroot.zig`, or `src/proc.zig`. The ports on `ports3` own them. A change to `src/interp.zig`, `src/main.zig`, or `src/ztcl.zig` stays inside the hunks that the task names.
10. Use the words "step limit" for the limit on steps. Name no AI model or vendor in the repository. Add no attribution line.
11. If a gate fails, do not change the gate. Report the measured number and the cause.
12. If a fact in a task is wrong, stop and report it. Do not guess.

## The tasks

| Task | Title |
|---|---|
| [01](01-memory-tests.md) | Memory tests and the outside benchmark tool |
| [02](02-heap.md) | The heap in place of the arena |
| [03](03-collector.md) | The roots, the mark, the sweep, and the stress mode |
| [04](04-collector-policy.md) | The trigger, the limits, and the embedder calls |
| [05](05-owned-lists.md) | `lset` in place on an owned list |
| [06](06-memory-gates.md) | The gates of milestone 0 |
| [07](07-switch.md) | `switch` as bytecode |
| [08](08-lassign-lset.md) | `lassign` and `lset` as bytecode |
| [09](09-base64.md) | The base64 codec |
| [10](10-plumbing.md) | The build option, the embedder option, and the baseline |
| [11](11-exec-memory.md) | Executable memory on Linux |
| [12](12-x64-assembler.md) | The x86-64 assembler |
| [13](13-layout.md) | The layout probe |
| [14](14-verifier.md) | The bytecode verifier |
| [15](15-helpers.md) | One function for each bytecode instruction |
| [16](16-tier1-calls.md) | Tier 1 with a helper call for each instruction |
| [17](17-tier1-inline.md) | The inline fast paths |
| [18](18-differential.md) | The differential tests, the suite mode, and the docs |
| [19](19-fuzzer.md) | The random program fuzzer |
| [20](20-asm-verifier-fuzz.md) | The assembler and verifier fuzzers |
| [21](21-stress.md) | The stress modes and the safety builds |
| [22](22-hardening.md) | The hardening tests |
| [23](23-named-code.md) | Scripts outside a proc |
| [24](24-more-inline.md) | More inline code |
| [25](25-direct-calls.md) | Direct calls of procs |
| [26](26-a64-assembler.md) | The arm64 assembler |
| [27](27-arm64-macos.md) | arm64 macOS |
| [28](28-x64-macos.md) | x86-64 macOS |
| [29](29-x64-windows.md) | x86-64 Windows |
| [30](30-arm64-linux.md) | arm64 Linux |
| [31](31-wasm-and-docs.md) | WebAssembly and the port docs |
| [32](32-tier2-model.md) | The model and the census for tier 2 |
| [33](33-tier2-types.md) | The loops and the type pass |
| [34](34-tier2-int-loops.md) | Integer loops in registers |
| [35](35-tier2-exits.md) | The exit stress mode and the drop of a loop |
| [36](36-tier2-calls.md) | Calls out of a loop |
| [37](37-tier2-doubles.md) | Doubles |
| [38](38-tier2-arm64.md) | Tier 2 on arm64 |
| [39](39-default.md) | The condition for a default of on |

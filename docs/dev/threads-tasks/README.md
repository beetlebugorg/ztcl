# Tasks for threads

[The design](../../threads.md) gives the model and the choices. Issue 10 has the goal. Do the tasks in the order of their numbers. One task is one branch and one review.

## Milestones

| Milestone | Tasks | Result |
|---|---|---|
| 1: one thread for each interpreter | 01 to 02 | `thread::*` works on Linux. `thread.test` passes 17 tests. |
| 2: shared data | 03 to 05 | `tsv`, the mutexes and the conditions, and `tpool`. |
| 3: channels and sockets | 06 to 07 | `thread::transfer` and the thread tests of `socket.test` and `unixNotfy.test`. |
| 4: proof | 08 to 10 | The tests of the limits, the races, the teardown, ThreadSanitizer, and the benchmarks. |
| 5: ports | 11 to 12 | macOS and Windows. |
| 6: docs | 13 | The counts and the pages for the embedder. |
| 7: web | 14 | Threads in WebAssembly with Web Workers, after tasks 01 to 05 and 08. |

The user decides the three points of "Decisions for the user" in the design before task 01 merges.

## Platforms

| Mark | Where the task runs |
|---|---|
| Linux | Linux. |
| macOS | macOS. |
| Windows | Windows. |
| shared | Any platform. The code is the same on each platform, and the tests run on Linux first. |
| shared/web | The WebAssembly build in Node.js and in a browser. |

## Rules for each task

1. Read AGENTS.md, WRITING.md, `docs/dev/design.md`, `docs/embedding.md`, `docs/dev/jit.md`, and `docs/threads.md` first.
2. Run each build, test, and benchmark under the memory cap. `CAP` in each task means this prefix:

   ```sh
   systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 --
   ```

   Use at most 3 parallel jobs. A thread test can use many threads inside its cap. Bound each run with `timeout`.
3. A task is done when each command of its acceptance list passes. Put the output of each command in the PR body.
4. The common acceptance commands apply to each task, also when the task does not list them:

   ```sh
   CAP zig build
   CAP zig build test
   CAP zig build test -Doptimize=ReleaseSafe
   CAP zig build test -Djit=false
   CAP zig build wasm && node tools/wasm-smoke.mjs
   CAP tools/suite.sh -a
   CAP tools/suite.sh -a -j
   CAP tools/jit-diff.sh
   ```

   The pass count of each suite file must not drop. `thread.test` gains.
5. Put thread code in its own files. A change to `src/interp.zig`, `src/vm.zig`, `src/event.zig`, `src/child.zig`, `src/main.zig`, or `src/ztcl.zig` stays inside the hunks that the task names. Other work changes the call path, the list ownership, `switch`, and the TclOO calls of `interp.zig` and `vm.zig` at the same time.
6. No value crosses threads by pointer. Only the thread that owns a heap allocates from it.
7. Each wait is a slice of at most 50 ms, and the thread checks its stop flag after each slice.
8. Each new source file starts with a `//!` comment that explains its algorithm, and an SPDX line for BSD-2-Clause.
9. Write fresh code. Copy no code from the Thread package or another project. Credit each source in `docs/references/thread.md`.
10. Use only the Zig 0.16.0 standard library. The WebAssembly build has no thread command until task 14.
11. Use the words "step limit" for the limit on steps. Name no AI model or vendor in the repository. Add no attribution line.
12. If a gate fails, do not change the gate. Report the measured number and the cause.
13. If a fact in a task is wrong, stop and report it. Do not guess.

## The tasks

| Task | Platform | Title |
|---|---|---|
| [01](01-core.md) | shared | The group, the threads, the messages, and the stop flag |
| [02](02-thread-commands.md) | shared | The `thread::*` commands and `thread.test` |
| [03](03-tsv.md) | shared | The shared variables |
| [04](04-sync.md) | shared | The mutexes, the conditions, and `thread::eval` |
| [05](05-tpool.md) | shared | The thread pools |
| [06](06-channels.md) | Linux | `thread::transfer`, `thread::detach`, and `thread::attach` |
| [07](07-socket-tests.md) | Linux | The thread tests of `socket.test` and `unixNotfy.test` |
| [08](08-limits-races.md) | shared | The tests of the capability, the limits, the teardown, and the races |
| [09](09-tsan.md) | Linux | ThreadSanitizer |
| [10](10-benchmarks.md) | Linux | The benchmarks against `tclsh` with Thread |
| [11](11-macos.md) | macOS | arm64 and x86-64 macOS |
| [12](12-windows.md) | Windows | x86-64 Windows |
| [13](13-docs.md) | shared | The counts and the docs |
| [14](14-wasm-workers.md) | shared/web | Threads in WebAssembly with Web Workers |

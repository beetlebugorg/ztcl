# Tasks for WASI

[The design](../wasi.md) gives the model. Issue 2 has the goal. Do the tasks in the order of their numbers. One task is one branch and one review.

## Milestones

| Milestone | Tasks | Result |
|---|---|---|
| 1: preview 1 | 01 to 04 | `ztcl.wasm` runs scripts under wasmtime, with the capabilities and the suite. CI runs it. The first component comes from the adapter. |
| 2: preview 2 | 05 to 07 | Native WASI 0.2 imports, no adapter, and sockets. |
| 3: embedding | 08 to 09 | The `ztcl:embed` world, the counts under two runtimes, and the docs. |

The user answers the questions below before task 01 merges.

## Platforms

| Mark | Where the task runs |
|---|---|
| shared | Any platform. The tests run on Linux first. |
| shared/wasi | The `wasm32-wasi` build under wasmtime, from Linux. |

## Rules for each task

1. Read AGENTS.md, WRITING.md, `docs/design.md`, `docs/embedding.md`, `docs/webassembly.md`, and `docs/wasi.md` first.
2. Run each build, test, and suite under the memory cap. `CAP` in each task means this prefix:

   ```sh
   systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 --
   ```

   Bound each wasmtime run with `timeout`.
3. A task is done when each command of its acceptance list passes. Put the output of each command in the PR body.
4. The common acceptance commands apply to each task, also when the task does not list them:

   ```sh
   CAP zig build
   CAP zig build test
   CAP zig build test -Djit=false
   CAP zig build wasm && node tools/wasm-smoke.mjs zig-out/lib/ztcl.wasm
   CAP tools/suite.sh                       # total: pass 19877
   CAP zig build -Dtarget=wasm32-wasi       # from task 01 on
   CAP tools/wasi-smoke.sh                  # from task 02 on
   ```

   The pass count of each native suite file must not drop.
5. Put WASI code in its own files: `src/sys_wasi.zig`, `src/fsroot_wasi.zig`, and `src/wasi/` for the generated bindings. A change to another file is a comptime switch on the target, and it stays inside the hunks that the task names.
6. Each capability stays off by default. A test proves that each one is absent by default in the WASI build.
7. Each new source file starts with a `//!` comment that explains its algorithm, and an SPDX line for BSD-2-Clause.
8. Use only the Zig 0.16.0 standard library. `wasmtime` and `wasm-tools` are test and packaging tools. Pin each version, and check each download with SHA-256.
9. Write fresh code. Credit each source in `docs/references/wasi.md`.
10. Use the words "step limit" for the limit on steps. Name no AI model or vendor in the repository. Add no attribution line.
11. If a gate fails, do not change the gate. Report the measured number and the cause.
12. If a fact in a task is wrong, stop and report it. Do not guess.

## The tasks

| Task | Platform | Title |
|---|---|---|
| [01](01-build.md) | shared/wasi | `zig build -Dtarget=wasm32-wasi` on preview 1 |
| [02](02-ci.md) | shared/wasi | The smoke tests and the CI job under wasmtime |
| [03](03-p1-capabilities.md) | shared/wasi | Files, clock, random, env, and the event loop on preview 1 |
| [04](04-adapter-component.md) | shared/wasi | The first component with the adapter |
| [05](05-wit-bindings.md) | shared | The WIT files and the bindings generator |
| [06](06-p2-native.md) | shared/wasi | Native preview 2 for the CLI, clocks, random, and files |
| [07](07-p2-sockets.md) | shared/wasi | Sockets and the event loop on `wasi:sockets` and `wasi:io/poll` |
| [08](08-embed-world.md) | shared/wasi | The `ztcl:embed` world for the library |
| [09](09-counts-docs.md) | shared/wasi | Two runtimes, the counts, threads, and the docs |

## Questions for the user

1. **The pinned WASI version.** Plan: WASI 0.2.N, with N the newest version that wasmtime 50 and the second runtime both support. Is a preview 3 track out of scope for now?
2. **The adapter.** Task 04 downloads the preview 1 adapter module of the pinned wasmtime release, with a SHA-256 check, at build time. The adapter goes away at task 06. Is a downloaded build input acceptable for this step? The other choice is to skip task 04 and go to preview 2 directly.
3. **The second runtime** for the counts of task 09. Candidates: jco in Node.js (a test tool from npm), and WAMR or Wasmer if they run 0.2 components. Which one?
4. **Threads.** The plan keeps `thread` absent on WASI until a WASI thread interface is stable. Is that the right call, or does the WASI build need threads earlier?
5. **The `ztcl:embed` world.** Is the shape in the design (an `interp` resource, `eval`, `call`, one `host-command` import) right for zslice and other hosts?
6. **Issue 2 names `docs/ports.md`** for the name lookup rule. The file is not on main. The plan uses AGENTS.md rule 3. Is a separate ports doc wanted?

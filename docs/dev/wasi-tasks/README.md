# Tasks for WASI

[The design](../wasi.md) gives the model. Issue 2 has the goal. Do the tasks in the order of their numbers. One task is one branch and one review.

## Milestones

| Milestone | Tasks | Result |
|---|---|---|
| 1: preview 1 | 01 to 03 | `ztcl.wasm` runs scripts under wasmtime, with the capabilities and the suite. CI runs it. |
| 2: WASI 0.3.2 | 04 to 07 | The async canonical ABI, native WASI 0.3.2 imports, the command component, and sockets. |
| 3: embedding | 08 to 09 | The `ztcl:embed` world, the counts under two runtimes, and the docs. |

## Platforms

| Mark | Where the task runs |
|---|---|
| shared | Any platform. The tests run on Linux first. |
| shared/wasi | The `wasm32-wasi` build under wasmtime, from Linux. |

## Rules for each task

1. Read AGENTS.md, WRITING.md, `docs/design.md`, `docs/embedding.md`, `docs/webassembly.md`, and `docs/dev/wasi.md` first.
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
10. Use the words "compute limit" for the limit on steps. Name no AI model or vendor in the repository. Add no attribution line.
11. If a gate fails, do not change the gate. Report the measured number and the cause.
12. If a fact in a task is wrong, stop and report it. Do not guess.

## The tasks

| Task | Platform | Title | State |
|---|---|---|---|
| [01](01-build.md) | shared/wasi | `zig build -Dtarget=wasm32-wasi` on preview 1 | merged (#78) |
| [02](02-ci.md) | shared/wasi | The smoke tests and the CI job under wasmtime | merged (#86) |
| [03](03-p1-capabilities.md) | shared/wasi | Files, clock, random, env, and the event loop on preview 1 | merged (#83) |
| [04](04-async-abi.md) | shared/wasi | The async canonical ABI of WASI 0.3, and the first component | merged (#210) |
| [05](05-wit-bindings.md) | shared | The WIT files of WASI 0.3.2 and the bindings generator | PR (this branch) |
| [06](06-native.md) | shared/wasi | Native WASI 0.3 for the CLI, clocks, random, and files | open |
| [07](07-sockets.md) | shared/wasi | Sockets on `wasi:sockets` 0.3 | open |
| [08](08-embed-world.md) | shared/wasi | The `ztcl:embed` world for the library | open |
| [09](09-counts-docs.md) | shared/wasi | Two runtimes, the counts, threads, and the docs | open |

## Decisions

The user answered the questions on 25 November 2026:

1. **The pinned WASI version.** WASI 0.3.2, the newest 0.3.N release. Task 04 checks that the pinned wasmtime accepts it.
2. **A WASI 0.2 build.** No 0.2 build for now. The plan builds only 0.3.
3. **The second runtime** for the counts of task 09 is jco in Node.js.
4. **Threads.** `thread` stays absent on WASI for now.
5. **The `ztcl:embed` world.** The shape in the design is the world: an `interp` resource, `eval`, `call`, and one `host-command` import.
6. **The ports doc.** No new doc for WASI. The rule of the name lookup goes in the existing ports doc, [docs/dev/ports.md](../ports.md).

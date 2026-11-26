# Tasks for point procs to WebAssembly

[The design](../wasm-compile.md) gives the module and the reasons. Issue 3 has the goal. This list is level 2 only. Do the tasks in the order of their numbers. One task is one branch and one review.

## Milestones

| Milestone | Tasks | Result |
|---|---|---|
| 1: the parts | 01 to 02 | A wasm writer and the runtime module, with tests. |
| 2: the compiler | 03 to 05 | `ztcl compile` makes a module that equals the interpreter, with the limits and a fuzzer. |
| 3: proof and use | 06 to 07 | The speed gate, the host example, and the docs for zslice. |

The user answers the questions below before task 01 merges.

## State

- Task 01: merged in PR #79.
- Task 02: merged in PR #81. The user chose choice 1 (decision 7 of the plan).
- Task 03: merged in PR #87. `ztcl compile` and `tools/point-wasm-diff.sh`. The module equals `Program.run` in bits for the fixed procs of `tests/point/`, in both forms.
- Task 04: merged in PR #88. `Program.steps(n)` and `tools/point-wasm-limits.mjs`.
- Task 05: PR #89. The fuzzer and the fixes of decisions 8 and 9.
- Task 06: done in PR #184. `tools/point-wasm-bench.mjs` and `bench/point-wasm.tsv`. The gate fails for 4 of the 5 fixed procs. Only `int_zero` is faster in the module. The numbers came from `node tools/point-wasm-bench.mjs --write bench/point-wasm.tsv` on 2026-11-26, on an Intel Core i7-6700K with Node.js 26.12.0 on Linux. The three procs with `noise2` or `noise3` are 1.7 to 2.7 times slower in the module, and `elseif_noise` has only `noise3`. So the noise functions of the module are the first suspect. A wasm profile of the module was not made. On 2026-11-26 the user accepted the gate result as it is, and task 06 is done. Point procs stay opt-in in wasm: `ztcl-simd.wasm` and `ztcl-host.wasm` have them, and the default `ztcl.wasm` does not, for its size limit of 1.5 MB.
- Task 07: PR #185. `ztcl compile -manifest`, `examples/point-wasm/run.mjs`, and the section "Compile a point proc" of `docs/webassembly.md`.

## Platforms

| Mark | Where the task runs |
|---|---|
| shared | Any platform. The tests run on Linux first. |
| shared/web | The module in Node.js. |
| shared/wasi | The module in wasmtime, from Linux. |

## Rules for each task

1. Read AGENTS.md, WRITING.md, `docs/design.md` (the section on point procs), `docs/webassembly.md`, and `docs/dev/wasm-compile.md` first.
2. Run each build, test, and benchmark under the memory cap. `CAP` in each task means this prefix:

   ```sh
   systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 --
   ```

3. A task is done when each command of its acceptance list passes. Put the output of each command in the PR body.
4. The common acceptance commands apply to each task, also when the task does not list them:

   ```sh
   CAP zig build
   CAP zig build test
   CAP zig build wasm && node tools/wasm-smoke.mjs zig-out/lib/ztcl.wasm
   CAP tools/suite.sh                       # total: pass 19877
   CAP tools/point-wasm-diff.sh             # from task 03 on
   ```

5. Do not change the behavior of `point.compile`, `Program.run`, or `point.runSlow`. A task may add a pure function to `src/point.zig`, as named in the task. Decision 7 of [the plan](../wasm-compile.md#decisions) is the one exception: task 02 fixes the result of `clamp` and the limits for zeros and NaN.
6. A module has no import, and no code path in it reaches the host.
7. Each new source file starts with a `//!` comment that explains its algorithm, and an SPDX line for BSD-2-Clause.
8. Use only the Zig 0.16.0 standard library. Node.js, `wasm-tools`, and `wasmtime` are test tools.
9. Write fresh code. Write the encoder from the WebAssembly specification. Credit each source in `docs/references/wasm-compile.md`.
10. Use the words "compute limit" for the limit on steps. Name no AI model or vendor in the repository. Add no attribution line.
11. If a gate fails, do not change the gate. Report the measured number and the cause.
12. If a fact in a task is wrong, stop and report it. Do not guess.

## The tasks

| Task | Platform | Title |
|---|---|---|
| [01](01-writer.md) | shared | The wasm writer |
| [02](02-runtime.md) | shared/web | The runtime module and the function append |
| [03](03-codegen.md) | shared/web | The code generation and `ztcl compile` |
| [04](04-limits.md) | shared/web | The compute limit and the memory limit in the module |
| [05](05-fuzzer.md) | shared/web | The random proc fuzzer and the wasmtime run |
| [06](06-speed.md) | shared/web | The speed gate |
| [07](07-host-docs.md) | shared | The host example, the manifest fragment, and the docs |

## Questions for the user

1. **The speed gate.** Answered on 2026-11-26: the user accepted the result of task 06 against the native `Program.run`. Issue 3 asks that each point is faster than the vector path of the interpreter. The plan compares the module with the interpreter's vector path in the same host: `Program.run` in a wasm build of ztcl, both in Node.js. The other choice is the native `Program.run`. Which one?
2. **The step unit.** The plan counts one compute unit for each operation of the program for each block of 1024 points. The vector path of the interpreter counts no steps today. Is that unit right for zslice?
3. **The scalar form.** The plan has a `-simd off` form for a host with no wasm SIMD. The zslice plugin runtime is not chosen yet. Is the scalar form needed?
4. **The manifest.** The plan writes a manifest fragment with `-manifest FILE` and puts the facts in the custom section `ztcl.point`. Does zslice want the fragment, or only the custom section?
5. **Imports.** Point procs declare no host functions today, so a module has no imports. Is a declared import (a host function in a point proc) part of level 2, or later work?
6. **The IR.** The plan uses the vector program of `point.zig` as the IR, and it does not use `tier2_lower.zig`. Is that right?

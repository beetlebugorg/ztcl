# Tasks of the AOT phase (issue #40)

This folder has the task list of phase 2 of [the static build](../static-build.md): the code of the JIT tiers, made at build time and put into the binary. Phase 1 (steps 1 to 4 of the static build) is the payload, the slot, and `ztcl build` with the interpreter and the JIT.

## What the code generators give now

A read of `src/jit/` on main of 2026-11-26 gives these facts. Each task starts from them.

- **The code has no absolute address.** Branches are PC-relative. A call of a helper is an indirect call through the table of helpers, and the code loads the address of the table from the context of `enter` (`ctxField("helpers")` in `src/jit/tier1_x64.zig`). Operands of the bytecode go to the helpers as the number of the instruction and the stack depth, not as addresses. So the code of tier 1 is position independent already. Task 05 checks this for each instruction, on x86-64 and arm64.
- **The offsets come from a probe at run time.** `src/jit/layout.zig` finds the byte offsets of `Value`, of the cell of a variable, and of the fields that the code reads, because Zig does not fix the layout of a tagged union. A build on one machine for another target cannot know these offsets from its own probe.
- **Tier 2 needs the types of live values.** `compileLoop` in `src/jit.zig` reads the kinds of the variables of the frame (int, double, or any) at the first tier up of a loop. At build time there is no frame.
- **The region is write-once memory.** `src/jit/mem.zig` copies each function into pages with `mprotect`, or into a `MAP_JIT` region on arm64 macOS. AOT code is in the text segment of the file, so it needs neither.

## Decisions of this plan

- **The layout record.** Each AOT runtime binary has a layout record in its slot: the output of `layout.probe` of that runtime, made by CI when it builds the runtime. The build reads the record from the runtime file and gives it to the code generators. At start, the runtime probes its layout again and compares it with the record. If they differ, the runtime uses no AOT code, and the program runs in the interpreter and the JIT. A wrong offset can never run.
- **Tier 1 first.** Tasks 05 and 06 compile tier 1 only. Tier 1 needs no type data, and each instruction keeps its helper. Tier 2 at build time comes in task 07, from a profile of a training run (`ztcl run --profile`), with the guards of the JIT. With no profile, a loop stays in tier 1.
- **The bytecode stays.** The payload keeps the bytecode of each proc and its hash. A proc gets its AOT entry only when the hash of its bytecode at start is the hash of the record, so a proc defined again, `eval` of a string, and `source` of a new file run in the interpreter and the JIT.
- **The same bytes in the CLI and the browser.** The AOT target of the code generators writes into a buffer and calls no system function, so `ztcl.wasm` gives the same code as the CLI (task 08).

## Tasks

| Task | Platform | Title | State |
|---|---|---|---|
| 05 | shared | The AOT target of the code generators: tier 1 code with no address of the build, the layout record, and a test that compares AOT code with JIT code on `tests/jit/` | open |
| 06 | linux | The code region, the data region, and the table in the runtime, the check of the layout record at start, and `ztcl build --aot` on Linux x86-64, checked with `tools/jit-diff.sh` | open |
| 07 | shared | Tier 2 at build time from a profile, with the guards and the exits of the JIT | open |
| 08 | linux, macos, windows | arm64 Linux and macOS, then the Win64 calling convention for Windows x86-64, and the code generators in `ztcl.wasm` | open |

## Acceptance of the phase

- `ztcl build --aot -o app main.tcl` on Linux x86-64 gives a binary that runs the corpus of `tests/jit/` with the same output as `ztcl`, and with no writable and executable page (`/proc/self/maps` of the process shows none).
- A runtime with a changed layout record runs the program with no AOT code and gives the same output.
- The start time of the hello world of `docs/build.md` with `--aot` is at most the start time without it.
- The size job reports the size of the regions and of the binary for each target.

## Rules

- No code of another AOT compiler. The design comes from the code generators of ztcl and the plan of [the static build](../static-build.md).
- Each task adds its numbers to the static build page: the size of the code of each instruction, the size of the regions, and the start time.

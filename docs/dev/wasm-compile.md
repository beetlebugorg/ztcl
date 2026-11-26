# Point procs to WebAssembly

This is the plan for level 2 of [issue 3](https://github.com/beetlebugorg/ztcl/issues/3): `ztcl compile` turns a point proc into a small standalone WebAssembly module with no interpreter. The first user is the plugin sandbox of zslice: a fuzzy skin module. Levels 1 and 3 stay open in the issue. [The tasks](wasm-compile-tasks/README.md) give the order.

## The front end and the IR

The IR is the vector program of `src/point.zig` (`Program`, with `setup` and `ops`). The check of `point proc` already made it. It is typed, it has no branches (an `if` is a mask and a select), and it has no loops except the loop over the points. `Program.run` is the reference for each operation. Rule 6 of AGENTS.md keeps it equal to the slow path, bit for bit.

The tier 2 lowering in `src/jit/tier2_lower.zig` works on loops of Tcl bytecode, with register budgets, exits to the interpreter, and step checks in a loop. A point program has no exits and no inner loops, so the code generator does not use it. It uses the same idea for the step check: one check at a fixed place, with a cost that is known before the code runs.

## The Tcl subset

The subset is the subset of the point proc check, with no change:

- parameters that are point fields (`x y z width height speed flow feature layer path dist`),
- `set` of local numbers, `if` / `elseif` / `else` with braced conditions, `return` with no value,
- `expr` with numbers, the math functions, and a compare of the feature with a name,
- `noise3` and `noise2`,
- the output commands `offset`, `move`, `width`, `flow`, `speed`, and `skip`.

A proc that fails the check gives the same error, with the line and the reason, from `ztcl compile`.

## The module

ABI version 1:

- **Imports:** none. Point procs declare no host functions today. The math functions and the noise are in the module.
- **Memory:** one memory, defined in the module and exported as `memory`. Its minimum and maximum are the same page count. The code has no `memory.grow`.
- **Globals:** exported immutable `i32` values: `abi` (1), `cap` (the most points for one call), and the byte offset of each column: `in_<field>` for each parameter, `feature` for the feature numbers (one byte for each point), `out_<column>` for each output that the proc writes, and `limits` (the five `f64` of `point.Limits`).
- **Function:** `run(n: i32, seed: i32, in_mask: i32, out_mask: i32, steps: i64) -> i64`. A bit of `in_mask` says that an input column is present. A missing input reads as 0. A bit of `out_mask` says that an output column is present. A missing output is not written. The result is the count of steps used, or -1 for the compute limit, or -2 when `n` is more than `cap`.
- **Custom section `ztcl.point`:** JSON with the ABI version, the proc name, the parameters, the outputs, the feature names in their number order, the block size, the compute units of one block, and the SHA-256 of the source.

The host writes the columns into `memory` at the offsets, calls `run`, and reads the outputs. A module has no state between calls.

## The code generation

1. `point.compile` makes the `Program`.
2. The generator writes one function `run`. Its body is a loop over blocks of `point.block` points. Inside a block, a loop goes over the points two at a time, and each register of the program is a `v128` local with two `f64` lanes. All operations of the program are in one loop body, so a register needs no block of scratch memory.
3. A mask is a `v128` of lane masks. A select is `v128.bitselect`.
4. Each operation uses a wasm instruction only when that instruction gives the bits of `Program.run` for each input, also for NaN, -0, and infinities. All other operations call a function of the runtime, one lane at a time.
5. `noise3` runs only for the lanes in its mask, as in `Program.run`.
6. `point.bound` runs at the end of each block, from the runtime.
7. A scalar form (`-simd off`) uses `f64` locals and one point at a time, for a host with no wasm SIMD.

The runtime is a wasm module that the build makes from Zig source: the math functions of the point path, `noise3`, and `bound`. It calls the same Zig functions as the interpreter, so there is one source for each function. `ztcl` embeds the bytes of the runtime. The generator adds the function `run` to a copy of the runtime, with new function indices, and writes the sections again.

## The limits

- **Steps.** One block costs a fixed count of steps: the count of `ops`. The setup costs the count of `setup` one time. `run` checks the compute units that are left before each block. When a block does not fit, `run` returns -1. The outputs of the blocks before the stop are written, and the host discards them. `Program.steps(n)` gives the same count in the interpreter, so a test can compare the two.
- **Memory.** `ztcl compile -max-mem BYTES` sets the size of the memory. `cap` comes from the size and the bytes of one point. The module cannot grow its memory, so the memory limit holds in any host.
- **Native stack.** The code has no recursion. The wasm stack of `run` has a fixed depth.

## The test against the interpreter

A differential test runs each proc three ways on the same random points: `Program.run`, `point.runSlow`, and the module in Node.js. All outputs must be equal, bit for bit, and the count of compute units of the module must equal `Program.steps(n)`. A generator makes random procs from the subset. The fuzzer and the fixed procs (the fuzzy skin proc and the proc with branches of the point tests) run in CI.

## How zslice loads a module

The zslice plugin design is a proposal: a plugin is a WebAssembly module and a JSON manifest with permissions. zslice checks each import against the manifest and sets a compute limit and a memory limit for each call. A per-layer path transform (fuzzy skin is one) needs the permission `slice.write`.

A compiled point proc fits this design:

- It has no imports, so the manifest lists no imports for it.
- zslice reads the custom section `ztcl.point` to find the columns and the feature names, and maps its own path features to those numbers.
- For each path of a layer, zslice writes the columns, calls `run` with its compute limit for the call, and reads the outputs. On -1 the slice goes on without the plugin, with a message.

`ztcl compile -manifest FILE` writes a manifest fragment with these facts. The zslice plugin runtime is not chosen yet, so ztcl tests the module in Node.js and in wasmtime. This plan does not change zslice.

The fragment is JSON: `abi`, `proc`, `exports` (the names of `run`, `memory`, `cap`, and `limits`), `inputs` and `outputs` (the name and the global of each column), `features`, `block`, `setup_compute_units`, `block_compute_units`, `cap`, `memory` (in bytes), `simd`, and `imports` (an empty list). `examples/point-wasm/run.mjs` is a host that reads the custom section and runs a module.

## Decisions

The user answered the questions of [the task list](wasm-compile-tasks/README.md#questions-for-the-user) on 2026-11-25:

1. **The speed gate.** The reference is the native `Program.run`.
2. **The step unit.** One step is one operation of the program for each block of 1024 points, as proposed.
3. **The scalar form.** Yes. `-simd off` makes a module for a runtime with no SIMD.
4. **The manifest.** The module has the custom section `ztcl.point`. `-manifest FILE` writes an optional manifest fragment.
5. **Imports.** A host function in a point proc is later work. A level 2 module has no imports.
6. **The IR.** The IR is the vector program of `src/point.zig`. The code generator does not use tier 2.
7. **Zeros and NaN in `clamp` and the limits (an exception to rule 5 of the task list).** The user chose this on 2026-11-25 after the gate of task 02 failed. Zig `@min` and `@max` leave the sign of a zero result to the target: x86-64 gave the first operand for -0 and +0, and wasm gave the IEEE 754-2019 result. `clamp` of `expr`, `clamp` of point procs, and `point.bound` now use `expr.minF` and `expr.maxF`, a compare and select. A NaN operand gives the other operand, and for equal operands the result is the first operand. So native x86-64, arm64, and the wasm forms give the same bits. The native results change only in the sign of a zero on a target where `@min` gave the other zero.
8. **The mask of an `elseif` condition (an exception to rule 5).** The user chose this on 2026-11-25 after the fuzzer of task 05 found the fault. `branch` left the mask of the body in `c.mask`, so a `noise3` in the next `elseif` condition ran only for the points of that body. `point.compile` now sets the mask of the points that no earlier branch took before each condition. `tests/point/elseif_noise.tcl` has the proc.
9. **Integer zero results (an exception to rule 5).** The user chose this on 2026-11-25. Tcl has no integer -0, so an integer result that can be -0 in the vector program (`0 * -3`, `0 / -2`, `-0`, `int(-0.5)`, `round(-0.25)`) gets `+ 0.0`. A value that is an integer for some points and a double for others can still differ from Tcl in the sign of a zero, because the vector program has no type for each point. The fuzzer counts these points and stops on each other difference of `Program.run` and `runSlow`. `tests/point/int_zero.tcl` has a proc.

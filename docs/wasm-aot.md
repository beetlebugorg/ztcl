# Procs compiled to WebAssembly

This is the design of level 3 of [issue 3](https://github.com/beetlebugorg/ztcl/issues/3): each proc of a script becomes a WebAssembly function in the same module as the ztcl runtime. The runtime stays in the module for lists, strings, dicts, and each slow path. Level 2 ([point procs](wasm-compile.md)) and level 1 (a bundle) are separate.

## The command

```sh
zig build wasm-aot                  # zig-out/lib/ztcl-aot.wasm, the runtime
ztcl compile --wasm app.tcl -o app.wasm
```

`app.wasm` has the exports of `ztcl.wasm`, so `web/ztcl.mjs` loads it with no change. A host runs `app.tcl` in it as before. When a proc body compiles to the same bytecode as a compiled function, that function runs in place of the interpreter.

## The choice: a linker in ztcl

`ztcl compile --wasm` reads `ztcl-aot.wasm`, adds one function for each proc, and writes the module again. The other choice was to emit Zig source or object code and link it with the runtime at build time. That choice needs the Zig toolchain on the machine of each user, and a build for each script. The linker needs no tool: the module format has a few sections, and the change is an append to each one.

| Section | Change |
|---|---|
| Type | Two new types: `(i32) -> i32` for a function and `(i32 i32 i32) -> i32` for a helper. |
| Function, code | One function for each compiled body. |
| Table | The size grows by the count of functions. |
| Element | One new active segment puts the functions at the end of the table. |
| Memory | The least size grows by the pages of the directory. |
| Data | One new segment has the directory. A second one writes the address of the directory to the variable `ztcl_aot_dir` of the runtime. |

The allocator of the runtime (`std.heap.wasm_allocator`) uses only pages from `memory.grow`, so the new pages at the end of the least size are free for the directory.

## The runtime

`ztcl-aot.wasm` is `ztcl.wasm` with the build option `aot`. It adds:

- An export for each helper of `src/jit/helpers.zig`: `ztcl_h_NAME` for a proc body and `ztcl_hn_NAME` for named code. The linker finds them in the export section and calls them with a direct `call`.
- `ztcl_aot_dir`, a variable with the address of the directory, or 0.
- A hook in `vm.runFull`: the first run of a `Code` looks for its function in the directory. Then `vm.runLoop` calls the function through the table, as it calls the machine code of the JIT.
- `ztcl_aot_record`: a test mode that writes the parameters and the body text of each proc that compiles to bytecode.

## The directory

The directory is a table in linear memory, sorted by a hash of the bytecode. For each compiled function, it has the bytecode in a fixed byte form, the static stack depth of each instruction, the flag of named code, and the table index of the function.

A `Code` uses a compiled function only when all of these are true:

1. The bytecode bytes are equal.
2. The verifier of the JIT accepts the `Code` in the runtime.
3. The depths of the verifier in the runtime equal the depths in the directory.

The generated code reads each literal, site, word, and table from the `Code` at run time, as the JIT does. So two procs with equal bytecode and other literals share one function. Each failed check leaves the `Code` in the interpreter.

## The code of one function

The design is tier 1 of [the JIT](jit.md): one bytecode instruction gives one fixed piece of code, and the state at each instruction boundary equals the state of the interpreter.

- The function has the signature `(ctx) -> status`. `ctx` is the `jit.EnterCtx` of the JIT. The status is 0 for a result, 1 for an error, and 2 for a fallback to `exec`, as in the JIT.
- The value stack stays in linear memory. The depth is static at each instruction, so each instruction passes its own constant `sp`.
- Each instruction calls its helper: the same function of `vm.zig` that the interpreter calls. A helper that fails writes the error to the context. The code then writes `pc` and `sp` to the context and returns 1. `vm.runLoop` adds the error trace and handles `break` and `continue` as for `exec`.
- Control flow: each jump target starts a block. The blocks are nested in one `loop`. A forward jump is a `br` to the end of the block before its target. A backward jump writes the target block to a local and goes to the `br_table` at the top of the loop.
- The entry: pc 0 and each target of `break` and `continue` of the ranges. Another `pc`, or a depth that is not the static depth, gives the fallback.

Inline paths come after the helper form: integer math, compares, the jumps on them, `load`, `store`, `push`, and `incr`. They follow the rules of tier 1: each inline path checks the tags, and each other case calls the helper.

## Exactness

| Feature | Mechanism |
|---|---|
| The step limit | Each instruction calls the helper or runs the inline step check that the interpreter runs, at the same place. |
| The memory limit | The same: the check is in `step` and in the helpers. |
| The collector | The precise collector of the WebAssembly build collects only at a safe point of a clean chain of frames. The compiled function keeps no value in a local: each value is in the value stack or in a cell. The helpers set the safe points as for `exec`. |
| Errors and `errorInfo` | The context gets the exact `pc` and `sp` of the failed instruction. |
| `eval`, `uplevel`, traces, a redefined command | The helpers and the guards of the bytecode handle them, as in the interpreter. |
| Shimmering | Each inline path checks the tag at each use. |
| TclOO | A method body is a proc body. |
| A failed assumption | The `Code` stays in the interpreter: the bytecode differs, the verifier refuses it, or an entry is not valid. |

## Coroutines

The WebAssembly build has no coroutines: `coroutine` returns an error. So a compiled proc never suspends. A host with stack switching (JSPI, or the stack switching proposal) is later work. Then a proc that yields runs in the interpreter first.

## A wasm JIT

The JS host can compile a module at run time and add its functions to the table of the runtime. The code generator is plain Zig and can run in the runtime. This mode is later work. The ahead-of-time path and the record mode cover the gates.

## The gates

- **The suite.** The Tcl suite runs in Node.js on `ztcl-aot.wasm` two times: first with the record mode, then on a module that has each recorded proc. The counts of each file must equal the counts of the interpreter on the same runtime.
- **A differential fuzzer.** The generators of `tools/jit-fuzz.zig` make programs. Each program runs in the interpreter and in the compiled module, and the output, the error, and the step count must be equal.
- **The scripts of `tests/jit/` and `bench/`**, as in `tools/jit-diff.sh`.
- **Speed.** Measured against the WebAssembly interpreter and native `tclsh` on `bench/` and the outside programs. No target is set before the measurement.

## State

| Part | State |
|---|---|
| The design and the module writer (`src/wasm_aot/wasm.zig`) | Done. |
| The runtime (`zig build wasm-aot`, `src/wasm_aot/rt.zig`), the generator with one helper call for each instruction (`gen.zig`), the compiler (`aot.zig`, `src/compile.zig`), and `tools/wasm-aot.mjs` | Done. On the scripts of `tests/jit/`, `tests/mem/`, and `bench/`: 89 scripts, no difference, 177 functions found, no proc body with no function. Also with `--sweep 8` (8 step limits for each script). |
| Inline paths: the step check, integer math, compares, jumps, `load`, `store`, `push`, `incr` | Next. The generator needs the wasm32 form of `jit/layout.zig`: put the probed layout in `gen.zig` as a constant, and make the runtime compare `layout.probe()` with it at the first lookup and turn the directory off when they differ. |
| The suite in a compile-everything mode | Next. Run `tools/tcltest.tcl`, each top-level command of a test file in its own `ztcl_eval`, and `tools/tcltest-end.tcl` in Node.js, with the record mode, then on the compiled module. Compare the counts of each file. |
| The fuzzer | Next. Reuse the program generators of `tools/jit-fuzz.zig` to write scripts for `tools/wasm-aot.mjs`. |
| The speed numbers, `docs/webassembly.md`, and the site | Next. A first measure of the helper form, in Node.js 26 on a shared x86-64 Linux machine, best of 5 runs of each `eval`: the compiled module took 0.89 to 1.03 times the time of the interpreter on the 9 scripts of `bench/` (for example `sum.tcl` 38.0 ms against 40.3 ms, `fib.tcl` 26.6 ms against 29.5 ms). The helper form removes only the dispatch of `exec`, so the gain needs the inline paths. |

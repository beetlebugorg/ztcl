# Task 04e: C packages in WebAssembly in native ztcl

This file has the plan for native ztcl to run the packages of [task 04w](04w-wasm-bridge.md) through a WebAssembly engine of ztcl (#202). The package is the same module that ztcl.wasm loads: the C sources, `libztclstubs.a`, and wasi-libc, built with `zig cc -target wasm32-wasi`.

## Goal

`load sqlite.wasm` in the `ztcl` program runs the package in the sandbox and in the limits of ztcl. The module reaches only its linear memory and its imports. The compute limit counts its work, and the memory limit caps its linear memory. No third-party engine is linked: #202 builds the engine in Zig.

## What the engine needs for a package

The SQLite package of task 04w is built with the default features of Zig for `wasm32-wasi`. It has one memory and no threads. The decoder of step 1 gives the exact list of the features that it uses.

| Need | Source |
|---|---|
| A validating decoder of the binary format | #202 step 1 |
| An interpreter of the instructions of the package | #202 step 2 |
| The imports `ztcl.*` of the bridge | This plan |
| The WASI preview 1 imports of wasi-libc | #202, with the capabilities of ztcl |
| A meter of compute units | #202, the same units as the interpreter of Tcl |
| A tier that compiles hot functions with the JIT backends | #202, later |

## The bridge in the engine

The imports of the module `ztcl` are the 6 functions of task 04w: `cmd_create`, `cmd_delete`, `eval`, `var_get`, `var_set`, and `pkg_provide`. In native ztcl they are Zig functions of the engine host, with the same code as the exports of `src/wasm_cext.zig`:

1. A command of the package is a native command of ztcl, as in `src/wasm_cext.zig`. Its call writes the `Arg` records and the text into the memory of the module and calls the export `ztcl_cext_dispatch`.
2. An import reads its arguments from the memory of the module and writes the reply into the `reply` record of the module. The JavaScript glue of `web/ztcl.mjs` is absent: the engine copies text between the heap of ztcl and the linear memory with one `memcpy`.
3. `src/wasm_cext.zig` and the engine host share one file for the conversion of `Arg` records to values of ztcl. The file has no dependency on the wasm target.

## Limits

- **Compute.** The engine counts one compute unit for each N instructions, or one for each loop back edge and call. The choice comes from a measurement in #202. The count stops a C loop as it stops a Tcl loop, and the error is the error of the compute limit.
- **Memory.** `memory.grow` fails when the linear memory reaches the memory limit of the interp. The size of the linear memory counts in the memory of the interp.
- **Stack.** The engine has its own stack of frames with a maximum depth. A deep recursion in C gives an error, and the host keeps running.
- **Files.** WASI calls go through the `file` capability. With no `file`, `path_open` gives `ENOTCAPABLE`, and SQLite runs only with `:memory:`.

## Steps

| Step | Result |
|---|---|
| 1 | The decoder and the interpreter of #202 run the SQLite package with the imports of this plan stubbed: `Sqlite3_Init` returns. |
| 2 | The engine host of the 6 imports and `load FILE.wasm` in the `package` capability of the `ztcl` program. |
| 3 | WASI preview 1 through the capabilities: files in the root folder or host mode, the clock of `clock`, random bytes of `random`. |
| 4 | The test files of task 02 give the same counts in native ztcl as in Node.js. |
| 5 | The cost: `bench.tcl` against tclsh and against Node.js. With the interpreter of step 1, the `sql-only` part is slower than in Node.js. The JIT tier of #202 is the plan for it. |

## State

Steps 1 and 2 are done with `ztcl::wasm package FILE ?prefix?` (`src/wasmrt/cext.zig`, docs/dev/wasm-engine.md). `tools/cext/engine-check.sh` runs the test packages of task 04w through the engine, and each one gives the output of tclsh. Step 3 (WASI on the capabilities) is in `src/wasmrt/wasi.zig`. The command `load FILE.wasm` is next.

## Open questions

- The cost of an interpreter of WebAssembly for SQLite. A rough guess is 10 to 30 times the native code for `sql-only`, before the JIT tier. Step 5 measures it.
- The size of the engine in the `ztcl` program. It is behind a build option, off in the library default.

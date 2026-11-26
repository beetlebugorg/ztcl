# Task 04w: the bridge of the WebAssembly path

The user chose both paths on 2026-11-26 (issue #1). This file has the plan of the WebAssembly path. The native path has its own task file. The two paths implement the same slots in the same groups. [The result page](../cext.md) has the group list and the coverage table, and both paths update that page.

## Goal

A C package that `zig cc -target wasm32-wasi` builds runs in ztcl.wasm and ztcl-host.wasm. The bridge is in Zig. The cost of a call from C to a slot is near the cost of a call in the native build. Then native ztcl runs the same module through the wasm engine of #202.

The scope is the complete public stubs table of Tcl 8.6, over time. The slots that packages use come first: the 56 slots of the SQLite binding, then the slots of the next measured package. A slot with no implementation calls `Tcl_Panic` with its number and name, and the error of `load` names the slot.

## The shape

The spike of task 02 kept the objects in JavaScript, so each slot was a call through JavaScript with copies of text. 19% of the time of `insert` was in the creation of `DataView` objects. The bridge moves the objects into the package module:

1. **`libztclstubs.a`, in Zig, linked into the package.** It is the stubs table of the package. It has the shadow `Tcl_Obj` records, their reference counts and types, the text form, lists, byte arrays, dynamic strings, and the interp result. The slots of these groups make no call out of the module: memory, objects, results, dynamic strings, `Tcl_GetIndexFromObjStruct`, and `Tcl_GetVersion`. A small C file in the library has the variadic slots (`Tcl_AppendResult`, `Tcl_VarEval`, `Tcl_SetErrorCode`, `Tcl_AppendStringsToObj`, `Tcl_ObjPrintf`, `Tcl_AppendPrintfToObj`, `Tcl_Panic`). It collects the arguments and calls the Zig code.
2. **A small import set to ztcl.** Only the commands, the scripts, and the variables leave the module. The imports of the module `ztcl` are `cmd_create`, `cmd_delete`, `eval`, `var_get`, `var_set`, and `pkg_provide`. A value crosses as its kind and an int, a double, or text. An int and a double cross as a wasm `i64` or `f64` with no text form.
3. **ztcl exports.** ztcl.wasm and ztcl-host.wasm get exports for these imports behind the build option `-Dcext`, off by default. A command of the package is a command of ztcl. Its call goes to the export `ztcl_cext_dispatch` of the package with the id of the command and the arguments.
4. **Text.** Text crosses through one exchange buffer in each memory and one `memory.copy` in the JavaScript glue. In the wasm engine of #202, the engine copies the text and the glue is absent.
5. **Compiled scripts.** `eval` of the same text again reuses the compiled script of ztcl. The cache key is the text, and the package gives the address of the object as a hint.

The build of a package needs no generator: `libztclstubs.a` has the complete table, and `tclStubsPtr` points to it. `tools/cext-spike/slots.py` stays a tool of the spike.

## Steps

| Step | Result |
|---|---|
| 1 | `src/cext/wasm_stubs.zig`: the objects, the results, the dynamic strings, and the memory slots. Unit tests in Zig on the native target. |
| 2 | The exports of ztcl (`-Dcext`), the glue in `web/ztcl.mjs` (`Interp.loadPackage(bytes)`), and the `load` command for a `.wasm` file in the `package` capability. |
| 3 | The SQLite binding with `libztclstubs.a`: the test files of task 02 give the same counts. |
| 4 | The cost of a call: `bench.tcl` and a micro bench of one slot of each group, against tclsh with the native binding. |
| 5 | The other groups of the public table, in the order of their use by the measured packages. Each group adds its rows to the coverage table of the result page. |
| 6 | The plan of native ztcl through the wasm engine of #202. |

## Gate

The `insert` part of `tools/cext-spike/bench.tcl` is within 3 times tclsh with the native binding. In task 02, tclsh took 81 ms and the spike took 3,253 ms. The gate is 243 ms on the same machine. Each step reports the 4 parts of `bench.tcl`.

## Resume

- The spike is in `tools/cext-spike/`. `wasm.sh` builds the module and runs the test files. `host.mjs` is the JavaScript bridge that step 3 replaces.
- The spike data is in `$SPIKE`: the SQLite sources, `tclsqlite3.c`, and the counts of each run.

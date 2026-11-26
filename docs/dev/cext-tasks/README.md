# Tasks for Tcl packages with C modules

Issue #1 has the goal: load an existing Tcl package with a C module through an optional library. The comment of 2026-11-25 on the issue adds a second path: compile the C module to WebAssembly and load it in a sandbox. Do the tasks in the order of their numbers. One task is one branch and one review. Tasks 01 and 02 are a measured spike, and the user picks a path after them.

## The two paths

| Path | Load | Safety |
|---|---|---|
| Native | `load pkg.so` gives the module a stubs table of ztcl. | Native code, outside each limit and the sandbox. A separate library, `ztcl-cext`, never in the default build. |
| WebAssembly | `zig cc -target wasm32-wasi` builds the C sources and a stubs shim into one module. `load pkg.wasm` gives each `Tcl_*` call as an import. | The module reaches only its linear memory and the imports. Its memory maximum is its memory limit, and a meter of the runtime counts compute units. |

## Tasks

| Task | Result |
|---|---|
| [01](01-native.md) | Spike, native: build the Tcl binding of SQLite against the Tcl 8.6 stubs with a recording table, run its tests on tclsh with the recording table in front of the real one, and report the slots that it calls, out of the 636 public and 223 internal slots of Tcl 8.6. |
| 02 | Spike, WebAssembly: build the same binding with `zig cc -target wasm32-wasi` and a recording shim, run its tests in Node.js with stub imports that forward to the wasm build of ztcl, and report the slots, the module size, and the speed against task 01. |
| 03 | The result page `docs/dev/cext.md`: the slots of both spikes, the shape of the `Tcl_Obj` bridge (a shadow `Tcl_Obj` for each value, synced at each call), and the choice for the user. |
| 04 | After the choice: the bridge for the slots of task 03, one group of slots for each branch. |

## Rules for each task

1. Read AGENTS.md, WRITING.md, and `docs/dev/design.md` first. Run each build and test under the memory cap.
2. Copy no code from Tcl. The stubs table follows the published layout of `tclDecls.h` only for the slot numbers and the signatures, and `docs/references/tcl.md` credits it.
3. The default build has no code of this work. The native library and the wasm loader are each a build option that is off by default, and an embedder turns each one on.
4. Do not describe the native path as sandboxed.

## State

- Task 01: [01-native.md](01-native.md). The binding called 56 public slots and no internal slot.

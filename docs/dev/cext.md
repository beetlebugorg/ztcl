# Tcl packages with C modules

This page has the result of the spikes of [the task list](cext-tasks/README.md) for issue #1, and the choice for the user. [Task 01](cext-tasks/01-native.md) and [task 02](cext-tasks/02-wasm.md) have the measurements.

## The slots

The Tcl binding of SQLite 3.54.1 called 56 of the 630 functions of the public stubs table of Tcl 8.6 in the native run. It called no slot of the internal table or of the platform tables. In the WebAssembly run, it called 53 slots, and each one is also in the native list. The 3 slots of the native run only are `Tcl_ListObjIndex`, `Tcl_ListObjLength`, and `Tcl_BackgroundError`.

These are the slots in groups, one group for each branch of task 04:

| Group | Slots | Functions |
|---|---:|---|
| Memory | 2 | `Tcl_Alloc`, `Tcl_Free` |
| Objects | 22 | `Tcl_NewObj`, `Tcl_NewStringObj`, `Tcl_NewIntObj`, `Tcl_NewWideIntObj`, `Tcl_NewDoubleObj`, `Tcl_NewByteArrayObj`, `Tcl_NewListObj`, `Tcl_DuplicateObj`, `TclFreeObj`, `Tcl_GetString`, `Tcl_GetStringFromObj`, `Tcl_GetIntFromObj`, `Tcl_GetWideIntFromObj`, `Tcl_GetDoubleFromObj`, `Tcl_GetBooleanFromObj`, `Tcl_GetByteArrayFromObj`, `Tcl_SetIntObj`, `Tcl_SetWideIntObj`, `Tcl_ListObjAppendElement`, `Tcl_ListObjGetElements`, `Tcl_ListObjIndex`, `Tcl_ListObjLength` |
| Results | 8 | `Tcl_SetObjResult`, `Tcl_GetObjResult`, `Tcl_SetResult`, `Tcl_GetStringResult`, `Tcl_ResetResult`, `Tcl_AppendResult`, `Tcl_WrongNumArgs`, `Tcl_BackgroundError` |
| Commands | 3 | `Tcl_CreateObjCommand`, `Tcl_NRCreateCommand`, `Tcl_DeleteCommand` |
| Scripts | 6 | `Tcl_EvalObjEx`, `Tcl_Eval`, `Tcl_GlobalEval`, `Tcl_VarEval`, `Tcl_NREvalObj`, `Tcl_NRAddCallback` |
| Variables | 2 | `Tcl_GetVar2Ex`, `Tcl_ObjSetVar2` |
| Dynamic strings | 4 | `Tcl_DStringInit`, `Tcl_DStringAppend`, `Tcl_DStringAppendElement`, `Tcl_DStringFree` |
| Packages and helpers | 5 | `Tcl_PkgProvideEx`, `Tcl_PkgRequireEx`, `Tcl_GetVersion`, `Tcl_GetIndexFromObjStruct`, `Tcl_TranslateFileName` |
| Channels | 4 | `Tcl_CreateChannel`, `Tcl_RegisterChannel`, `Tcl_GetChannelName`, `Tcl_UnregisterChannel` (only `incrblob`) |

One package gives one list. Other packages use other slots, for example the channel types of a socket package or `Tcl_CreateObjType`. The recording table of task 01 measures a new package with no change.

## The shape of the Tcl_Obj bridge

C code reads and writes fields of a `Tcl_Obj` directly, so each value that goes to the module has a shadow `Tcl_Obj` in the memory of the module. Task 02 used this shape, and it ran 636 test files with the same counts as tclsh:

- **Layout.** The object is the layout of Tcl 8.6: `refCount`, `bytes`, `length`, `typePtr`, and 8 bytes (wasm32) or 16 bytes (x86-64) of internal form. It is 24 bytes on wasm32 and 48 bytes on x86-64.
- **Reference counts.** `Tcl_IncrRefCount` and `Tcl_DecrRefCount` are macros, so the count is in the memory of the module. The bridge frees the shadow at `TclFreeObj`. In Tcl, a variable owns the object of `Tcl_GetVar2Ex` and of `Tcl_ObjSetVar2`. In the bridge the variable is in ztcl, so the bridge frees such an object with no reference when the command ends.
- **Types.** The bridge gives a shadow of an int, a double, a list, or bytes the `Tcl_ObjType` with the name of Tcl: `wideInt`, `double`, `list`, or `bytearray`. The binding of SQLite reads `typePtr->name` and `bytes` to bind a variable as a number or a blob. A value of ztcl gives its kind (`int`, `double`, `str`, `list`) to the bridge.
- **Text.** `bytes` is null until `Tcl_GetString`, and then it is the text in the modified UTF-8 of Tcl (U+0000 is C0 80). The text of a double follows `tcl_precision`, and the text of a list uses the quoting of the `list` command.
- **Sync.** The bridge makes the shadows at each call: the arguments of a command, a variable, and the result of a script. The value goes back to ztcl at the result of a command and at `Tcl_ObjSetVar2`, with its kind. No shadow stays in sync with a value of ztcl after the call.
- **Commands.** A command of the module is a command of ztcl that runs in the frame of the caller. The non-recursive engine (`Tcl_NREvalObj`, `Tcl_NRAddCallback`) is one loop after the function returns: the script, then the callbacks, last in first.

## The two paths

| | Native | WebAssembly |
|---|---|---|
| Load | `load pkg.so`, built against the stubs of Tcl 8.6 with no change | `load pkg.wasm`, built from the C sources with `zig cc -target wasm32-wasi` and the shim of `slots.py` |
| Slots | 56 | 53, a subset of the 56 |
| Safety | Native code with the rights of the process, outside the compute limit, the memory limit, and the root folder | The module reaches only its memory and its imports. The memory maximum and a meter of the runtime give the limits. |
| Speed of SQLite | The reference | 2 times slower (`bench.tcl`, the `sql-only` part) |
| Size of SQLite | 1,339,448 bytes, stripped, x86-64 | 1,313,689 bytes (492,107 gzip) |
| Platform gaps | None for the tests | The WASI build of SQLite has no WAL mode and no file locks. Threads are absent. |
| Builds | One build for each platform and each Tcl ABI | One module for all platforms |
| Runtime | The C ABI of the host and a stubs table in Zig | In ztcl.wasm, the engine of the page or of Node.js. In the native ztcl, a WebAssembly runtime. ztcl has no runtime of its own today: `src/` writes and links modules, and runs none. |

The bridge is the same for both paths: the same slots, the same shadow objects, and the same handling of commands and scripts. Only the call path is different. In the native path, the stubs table holds C functions of Zig. In the WebAssembly path, each slot is an import.

The calls through the bridge of the spike were 23 to 104 times slower than tclsh. That bridge is JavaScript, and each call goes through two modules and text copies. A bridge in Zig in the same module as the interpreter has no JavaScript call and no text copy for an int or a double. The spike did not measure that bridge.

## Recommendation

The WebAssembly path, first in ztcl.wasm and ztcl-host.wasm. The reasons:

1. The module runs in the sandbox and in the limits of ztcl. A native module runs outside each limit, and AGENTS.md rule 3 keeps the sandbox for the default build.
2. The module needs the same slots as the native build, and one module runs on each platform.
3. The engine of the page or of Node.js runs the module, so the web forms need no new runtime.
4. The cost is 2 times for the work in C, and the WASI gaps (WAL, file locks, threads) are the gaps that the sandbox has for scripts too.

For the native ztcl, the WebAssembly path needs a runtime of our own: an interpreter of WebAssembly, or a compiler of WebAssembly to the code of the JIT. That is a new piece of the stack with its own tasks. The native path needs no runtime, but it is not sandboxed, and it stays a separate library (`ztcl-cext`) that an embedder turns on.

## The choice for the user

1. **The WebAssembly path in the web forms first** (the default): the bridge of task 04 in Zig, `load pkg.wasm` in ztcl.wasm and ztcl-host.wasm, the slot groups above in order, and the shim generator of `tools/cext-spike/slots.py` as the build tool for a package. The native ztcl gets a WebAssembly runtime later, as a separate plan.
2. **The native path first**: `ztcl-cext`, a library with a stubs table in Zig, for the `ztcl` program on Linux, macOS, and Windows. Packages load with no rebuild, outside the sandbox.
3. **Both**: the bridge with two call paths. The native library first for the `ztcl` program, and the WebAssembly loader for the web forms.

Each choice keeps the default build free of this code: the loader and the library are build options that are off by default.

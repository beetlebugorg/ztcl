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
| Parse | 0 | the 9 parse slots and `Tcl_ParseArgsObjv` (shared). `Tcl_ParseExpr` sets the message of a syntax error, and no error code or error info. | as in the WebAssembly path |
| Channels | 4 | `Tcl_CreateChannel`, `Tcl_RegisterChannel`, `Tcl_GetChannelName`, `Tcl_UnregisterChannel` (only `incrblob`) |

One package gives one list. Other packages use other slots, for example the channel types of a socket package or `Tcl_CreateObjType`. The recording table of task 01 measures a new package with no change.

## Coverage

The two paths use one implementation of each slot. `src/cext/obj.zig` has the objects, the interp result, the dynamic strings, and `Tcl_GetIndexFromObjStruct`. `src/cext/mem.zig` has the memory slots. `src/cext/hash.zig` has the hash tables and the assoc data. `src/cext/parse.zig` has the parser of Tcl 8.6 for the parse slots, the substitution of `Tcl_EvalTokensStandard`, and `Tcl_ParseArgsObjv`. It is a port of the parser of Tcl 8.6.16, so a package reads the token tree of Tcl. `src/cext/host.zig` has the slots that call ztcl: commands, scripts, variables, and the non-recursive engine. They call ztcl through a set of functions with the handle of the interp: the imports of the module in the WebAssembly path, and the functions of `src/cext/native.zig` in the native path. Both sets call `src/cext/zside.zig` in ztcl. `src/cext/table.zig` builds the table of each path from its list of group files: `src/cext/stubs.zig` for the native path and `src/cext/wasm_stubs.zig` for the WebAssembly path. `Tcl_Panic` is in `src/cext/mem.zig` and the package slots are in `src/cext/host.zig`, for both paths. `src/cext/pkgs.zig` has the startup slots of an application, for the native path only. The unit tests of `zig build test-cext` check the shared files on the native target, and the test packages of `tools/cext/check.sh` check the native path against tclsh. `tools/cext/wasm-check.sh` builds the same packages for wasm32-wasi and runs their scripts on ztcl-host.wasm in Node.js against tclsh. `src/cext/chan.zig` has the generic layer of the channels. A row gives the slots of the group that each path has.

| Group | SQLite slots | WebAssembly | Native |
|---|---:|---|---|
| Memory | 2 | 2 of 2, and the other 14 slots of the area memory (shared) | 2 of 2, and the other 14 slots of the area memory (shared) |
| Objects | 22 | 22 of 22, and the area objects except the bignum slots (shared) | 22 of 22, and the area objects except the bignum slots (shared) |
| Results | 8 | 8 of 8, and `Tcl_AppendElement` (shared) | 8 of 8, and `Tcl_AppendElement` (shared) |
| Commands | 3 | 3 of 3, and `Tcl_DeleteCommandFromToken` (shared) | 3 of 3, and `Tcl_DeleteCommandFromToken` (shared) |
| Scripts | 6 | 6 of 6, and the rest of the area scripts and results (shared) | 6 of 6, and the rest of the area scripts and results (shared) |
| Variables | 2 | 2 of 2, and 6 more get and set slots (shared) | 2 of 2, and 6 more get and set slots (shared) |
| Dynamic strings | 4 | 4 of 4, and 5 more (shared) | 4 of 4, and 5 more (shared) |
| Packages and helpers | 5 | 5 of 5, and `Tcl_PkgProvide`, `Tcl_PkgRequire`, `Tcl_PkgPresentEx`, `Tcl_PkgPresent` (shared) | as in the WebAssembly path, and the startup slots of `pkgs.zig` |
| Hash tables | 0 | the area hash tables (shared). `close()` of `web/ztcl.mjs` frees the interp of each package, so the delete procs of its assoc data run. | the area hash tables (shared) |
| Channels | 4 | the area channels (shared, `src/cext/chan.zig`): the generic layer of a channel type of C, with the buffers, the translation, the encodings `utf-8`, `iso8859-1`, and `binary`, the options, stacked transforms, the channel handlers, and the close handlers. A channel of ztcl (`stdout`, a channel of `open`) is reached through scripts of ztcl. The WebAssembly library has no channel commands, so only C code reaches a channel of a package. | as in the WebAssembly path. A registered channel of a package is also a channel of the interp of ztcl, so `puts`, `gets`, `read`, `seek`, `fconfigure`, and `close` of a script reach it. A transform stacks on a channel of `open`. A script of `fileevent` on a channel of a package is a channel handler: `Tcl_NotifyChannel` of the driver runs it, and buffered input gives readable events, as in Tcl. `fcopy` with a channel of a package copies characters: the size and the count are in characters. `fcopy -command` is not available on any channel yet. |
| Errors | 0 | the area errors (shared, `src/cext/errors.zig`). The interp of a package keeps its error code, error info, and error line, and Tcl_ResetResult clears them. After a script or a variable of ztcl fails, the host call `err_get` gives the package the error state of ztcl. A command that ends with TCL_ERROR or TCL_RETURN gives its state to ztcl with `err_set`. Tcl_ParseExpr sets {TCL PARSE EXPR ...} and the error info of Tcl. Tcl_BackgroundException queues the error for the bgerror handler of ztcl. Tcl_SignalId and Tcl_SignalMsg give "unknown signal": WASI has no signals. | as in the WebAssembly path, with the signal names of the host. |
| Strings | 0 | the area strings and encodings (shared, `src/cext/strings.zig`, `encoding.zig`, and `regexp.zig`). Tcl_Format and Tcl_AppendFormatToObj use `render` of `src/format.zig`, the engine of `format`, with the objects of the package as the arguments. Tcl_ObjPrintf reads its C arguments by the conversions of the format string and gives them to the same engine. A `Tcl_UniChar` has 16 bits, and the Unicode form of an object is the internal form of the type "string". The classes and the case maps of characters come from `src/ucd.zig`. The built-in encodings are `utf-8`, `iso8859-1`, `ascii`, `identity`, and `unicode`, with the limits of free space of Tcl, and Tcl_CreateEncoding adds an encoding of the package. The `encoding` command of ztcl does not see an encoding of a package, and the table encodings of `src/enc.zig` are not in the slots. The regular expression slots evaluate `::regexp` with the options of the flags and keep the interp result. | as in the WebAssembly path |
| Lists and dicts | 0 | the area lists and dicts (shared, `src/cext/lists.zig`). An element has the quoting of the `list` command. A dict is the internal form of the type "dict", in the order of insertion. A search holds a copy of the keys and the values. | as in the WebAssembly path |

## The shape of the Tcl_Obj bridge

C code reads and writes fields of a `Tcl_Obj` directly, so each value that goes to the module has a shadow `Tcl_Obj` in the memory of the module. Task 02 used this shape, and it ran 636 test files with the same counts as tclsh:

- **Layout.** The object is the layout of Tcl 8.6: `refCount`, `bytes`, `length`, `typePtr`, and 8 bytes (wasm32) or 16 bytes (x86-64) of internal form. It is 24 bytes on wasm32 and 48 bytes on x86-64.
- **Reference counts.** `Tcl_IncrRefCount` and `Tcl_DecrRefCount` are macros, so the count is in the memory of the module. The bridge frees the shadow at `TclFreeObj`. In Tcl, a variable owns the object of `Tcl_GetVar2Ex` and of `Tcl_ObjSetVar2`. In the bridge the variable is in ztcl, so the bridge frees such an object with no reference when the command ends.
- **Types.** The bridge gives a shadow of an int, a double, a list, or bytes the `Tcl_ObjType` with the name of Tcl: `int`, `double`, `list`, or `bytearray`. Where a `long` has 32 bits (wasm32, Windows), an int that does not fit a `long` has the type `wideInt`, as in Tcl 8.6. The binding of SQLite reads `typePtr->name` and `bytes` to bind a variable as a number or a blob. A value of ztcl gives its kind (`int`, `double`, `str`, `list`) to the bridge.
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

## The build-out of the stubs tables

On 2026-11-26 the user chose both paths, with the complete stubs API of Tcl 8.6 as the goal: all 630 functions of the public table, then the internal and platform tables. A slot with no function is an error that names the slot during the build-out. At the end, no slot is left without a function. [Task 04n](cext-tasks/04n-native.md) has the steps of the native path, and [task 04w](cext-tasks/04w-wasm-bridge.md) has the steps of the WebAssembly path.

### The areas

`tools/cext/stubs.py` reads the slots from the Tcl 8.6 headers and gives each public slot one area by its name. The use of a corpus of packages gives the order of the areas. The memory and package slots go first, because `Tcl_InitStubs` and each package need them.

`tools/cext/corpus.py` reads the output of the C preprocessor with `USE_TCL_STUBS` for each C file of a package. Each call of the C API is then a field of a stubs table, so the scan counts the slots that each package names. A slot in a branch that does not run counts too. So the counts are an upper bound of the slots that a package calls. These are the packages of the corpus, from `tools/cext/corpus.sh`:

| Package | C files read | Public and internal slots |
|---|---:|---:|
| SQLite 3.54.1 (`tclsqlite3.c`) | 1 of 1 | 66 |
| Itcl 4.3.2 | 19 of 20 | 127 |
| Thread 2.8.11 | 10 of 11 | 68 |
| TDBC 1.1.10 | 3 of 4 | 9 |
| tdbc::mysql 1.1.10 | 1 of 2 | 9 |
| tdbc::odbc 1.1.10 | 1 of 2 | 8 |
| tdbc::postgres 1.1.10 | 1 of 2 | 8 |
| TclTLS 1.7.22 | 3 of 4 | 20 |
| Memchan 2.3 | 19 of 19 | 32 |
| TclX 8.4.1 | 35 of 35 | 158 |

The preprocessor stops at a file that needs a header of its configure step, so the table shows the files that it read. The corpus names 240 public slots and 31 internal slots, and no platform slot. Itcl and TclX use the internal table, and Itcl also uses the stubs table of TclOO. That table is outside the four tables. tdom has a copyleft license, so it is not in the corpus.

| Order | Area | Slots | Slots the corpus names | Sum of packages over those slots |
|---:|---|---:|---:|---:|
| 1 | memory | 16 | 4 | 16 |
| 2 | packages | 18 | 7 | 16 |
| 3 | objects | 58 | 32 | 98 |
| 4 | scripts and results | 58 | 27 | 67 |
| 5 | channels | 92 | 37 | 52 |
| 6 | strings and encodings | 86 | 31 | 42 |
| 7 | lists and dicts | 28 | 14 | 41 |
| 8 | errors | 25 | 16 | 30 |
| 9 | interps and commands | 64 | 21 | 28 |
| 10 | hash tables | 13 | 9 | 21 |
| 11 | variables | 21 | 8 | 21 |
| 12 | events | 35 | 12 | 14 |
| 13 | namespaces | 25 | 13 | 13 |
| 14 | threads | 15 | 5 | 6 |
| 15 | filesystem | 63 | 4 | 5 |
| 16 | zlib | 13 | 0 | 0 |

### Coverage of the complete table

`tools/cext/coverage.py` writes this table from the group files of `src/cext/stubs.zig` (native) and `src/cext/wasm_stubs.zig` (WebAssembly). A slot is done in a path when a group of the path has its function. The internal and platform tables follow the public table.

<!-- coverage -->
| Area | Slots | Native | WebAssembly | Missing in native |
|---|---:|---:|---:|---|
| memory | 16 | 16 | 16 | none |
| packages | 18 | 12 | 7 | `Tcl_RegisterConfig`, `Tcl_PkgRequireProc`, `Tcl_SetStartupScript`, `Tcl_GetStartupScript`, `Tcl_LoadFile`, `Tcl_FindSymbol` |
| objects | 58 | 52 | 52 | `Tcl_NewBignumObj`, `Tcl_DbNewBignumObj`, `Tcl_SetBignumObj`, `Tcl_GetBignumFromObj`, `Tcl_TakeBignumFromObj`, `Tcl_InitBignumFromDouble` |
| scripts and results | 58 | 58 | 58 | none |
| channels | 92 | 92 | 92 | none |
| strings and encodings | 86 | 86 | 86 | none |
| lists and dicts | 28 | 28 | 28 | none |
| errors | 25 | 25 | 25 | none |
| interps and commands | 64 | 3 | 3 | 61 slots |
| hash tables | 13 | 13 | 13 | none |
| variables | 21 | 8 | 8 | 13 slots |
| events | 35 | 0 | 0 | 35 slots |
| namespaces | 25 | 0 | 0 | 25 slots |
| threads | 15 | 0 | 0 | 15 slots |
| filesystem | 63 | 1 | 1 | 62 slots |
| zlib | 13 | 0 | 0 | 13 slots |
| **public, all** | **630** | **394** (62%) | **389** (61%) | |
| **internal** | **173** | **0** | **0** | |
| **internal platform** | **23** | **0** | **0** | |
| **platform** | **0** | **0** | **0** | |
<!-- /coverage -->

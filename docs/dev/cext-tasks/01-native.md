# Task 01: the native spike

The Tcl binding of SQLite 3.54.1 (`tclsqlite3.c`, made by `make tclsqlite3.c` of the SQLite sources) is built against the Tcl 8.6.16 stubs with a recording table. Its tests ran on tclsh 8.6.16 with the recording table in front of the real table. The binding called 56 slots of the public table. It called no slot of the internal table or of the platform tables.

## The recording table

`tools/cext-spike/slots.py` reads the four stubs tables from the output of the C preprocessor on the Tcl 8.6.16 headers. It writes one x86-64 trampoline for each slot. A trampoline adds 1 to the count of its slot with `lock incq` and jumps to the real function, so it works for each signature, the variadic ones too. `tools/cext-spike/recstub.c` gives the extension its own `Tcl_InitStubs`: it reads the real table of the interp and gives the extension a copy of each table with the trampolines in the slots. At exit, a destructor writes the counts to the file of `$RECSTUB_OUT`.

On Linux, the tables have these slots:

| Table | Slots | Functions | Reserved |
|---|---:|---:|---:|
| Public (`TclStubs`) | 691 | 630 | 61 |
| Internal (`TclIntStubs`) | 262 | 173 | 89 |
| Internal platform (`TclIntPlatStubs`) | 31 | 23 | 8 |
| Platform (`TclPlatStubs`) | 0 | 0 | 0 |

The counts of 636 public and 223 internal slots of issue #1 are the `declare` lines of `generic/tcl.decls` and `generic/tclInt.decls`. They include the slots of Windows and macOS.

## The tests

The test files of SQLite need `testfixture`, a tclsh with the test commands of SQLite in C. A plain tclsh does not have them. `tools/cext-spike/shim.tcl` gives each missing command a neutral result through `unknown`, and it sets `sqlite_options` to 1 for each feature, except the extensions that this build does not have. So a test that needs a command of `testfixture` fails or skips. The failures are failures of the harness, and they are the same in the native run and the wasm run of task 02.

`tools/cext-spike/native.sh` ran each of the 1,199 test files in its own folder, 6 at a time, with a time limit of 60 s:

- 1,157 files loaded the binding.
- 697 files ran to the end: 199,530 tests, 4,851 errors.
- 42 files reached the time limit.

A test file that starts a child tclsh writes its counts to the same file, so some counts include the child.

## The slots

The calls are the sum over all files. The files are the count of files that called the slot.

| Slot | Function | Calls | Files |
|---:|---|---:|---:|
| 0 | `Tcl_PkgProvideEx` | 1,157 | 1,157 |
| 1 | `Tcl_PkgRequireEx` | 1,157 | 1,157 |
| 3 | `Tcl_Alloc` | 412,484 | 1,152 |
| 4 | `Tcl_Free` | 411,095 | 1,074 |
| 29 | `Tcl_DuplicateObj` | 26 | 6 |
| 30 | `TclFreeObj` | 91,586 | 415 |
| 32 | `Tcl_GetBooleanFromObj` | 32 | 13 |
| 33 | `Tcl_GetByteArrayFromObj` | 1,008 | 9 |
| 35 | `Tcl_GetDoubleFromObj` | 42,421 | 5 |
| 38 | `Tcl_GetIntFromObj` | 37,779 | 1,152 |
| 41 | `Tcl_GetStringFromObj` | 2,370,786 | 1,152 |
| 44 | `Tcl_ListObjAppendElement` | 4,606,236 | 693 |
| 45 | `Tcl_ListObjGetElements` | 32,616 | 34 |
| 46 | `Tcl_ListObjIndex` | 14 | 1 |
| 47 | `Tcl_ListObjLength` | 11 | 1 |
| 50 | `Tcl_NewByteArrayObj` | 10,609 | 25 |
| 51 | `Tcl_NewDoubleObj` | 153,969 | 91 |
| 52 | `Tcl_NewIntObj` | 3,549,081 | 602 |
| 53 | `Tcl_NewListObj` | 32,616 | 34 |
| 55 | `Tcl_NewObj` | 1,490,665 | 900 |
| 56 | `Tcl_NewStringObj` | 1,300,428 | 701 |
| 61 | `Tcl_SetIntObj` | 52 | 1 |
| 70 | `Tcl_AppendResult` | 39,437 | 1,152 |
| 76 | `Tcl_BackgroundError` | 2 | 1 |
| 88 | `Tcl_CreateChannel` | 146 | 9 |
| 96 | `Tcl_CreateObjCommand` | 2,314 | 1,157 |
| 103 | `Tcl_DeleteCommand` | 37,154 | 924 |
| 117 | `Tcl_DStringAppend` | 1,991 | 11 |
| 118 | `Tcl_DStringAppendElement` | 9,867 | 11 |
| 120 | `Tcl_DStringFree` | 39,681 | 1,152 |
| 122 | `Tcl_DStringInit` | 1,991 | 11 |
| 129 | `Tcl_Eval` | 186 | 6 |
| 156 | `Tcl_GetChannelName` | 146 | 9 |
| 166 | `Tcl_GetObjResult` | 32,868 | 54 |
| 174 | `Tcl_GetStringResult` | 35,397 | 37 |
| 177 | `Tcl_GlobalEval` | 1,969 | 9 |
| 196 | `Tcl_ObjSetVar2` | 258,091 | 87 |
| 210 | `Tcl_RegisterChannel` | 146 | 9 |
| 217 | `Tcl_ResetResult` | 1,441 | 91 |
| 232 | `Tcl_SetResult` | 263 | 38 |
| 235 | `Tcl_SetObjResult` | 1,625,193 | 901 |
| 249 | `Tcl_TranslateFileName` | 37,690 | 1,152 |
| 252 | `Tcl_UnregisterChannel` | 8 | 2 |
| 260 | `Tcl_VarEval` | 2,032 | 3 |
| 264 | `Tcl_WrongNumArgs` | 25 | 4 |
| 279 | `Tcl_GetVersion` | 60,557 | 1,152 |
| 293 | `Tcl_EvalObjEx` | 63,952 | 54 |
| 304 | `Tcl_GetIndexFromObjStruct` | 1,702,636 | 1,152 |
| 306 | `Tcl_GetVar2Ex` | 3,533,415 | 94 |
| 340 | `Tcl_GetString` | 1,666,996 | 1,152 |
| 487 | `Tcl_GetWideIntFromObj` | 1,304,712 | 74 |
| 488 | `Tcl_NewWideIntObj` | 45,855 | 28 |
| 489 | `Tcl_SetWideIntObj` | 180 | 17 |
| 583 | `Tcl_NRCreateCommand` | 37,657 | 1,152 |
| 584 | `Tcl_NREvalObj` | 22,900 | 94 |
| 587 | `Tcl_NRAddCallback` | 22,900 | 94 |

## What the slots show

- The binding reads and makes values with 21 functions of `Tcl_Obj`, and it frees them with `TclFreeObj` (slot 30), through the macro `Tcl_DecrRefCount`. So it reads and writes `refCount` in the memory of the object.
- To bind a Tcl variable to an SQL parameter, the binding reads `typePtr->name` and `bytes` of the object directly (lines 4545 and 4954 of `tclsqlite-ex.c`, a file that `make` writes). It binds a `bytearray` with no string form as a blob, and a `double`, `int`, `wideInt`, or `boolean` as a number. A bridge must give these objects the type names of Tcl.
- `db eval` with a script uses the non-recursive engine: `Tcl_NRCreateCommand`, `Tcl_NREvalObj`, and `Tcl_NRAddCallback`. The bridge can run the script after the command function returns and then call the callbacks, last in first.
- `incrblob` makes a channel: `Tcl_CreateChannel`, `Tcl_RegisterChannel`, `Tcl_GetChannelName`, and `Tcl_UnregisterChannel`. 9 files used it.
- `Tcl_GetVar2Ex` and `Tcl_ObjSetVar2` have 3,791,506 calls together. `db eval` with an array name or a script writes the columns of each row to variables.

## Reproduce

```sh
tools/cext-spike/fetch.sh
tools/cext-spike/native.sh -j 6
```

`fetch.sh` downloads the SQLite sources to `$SPIKE` (default `~/.cache/cext-spike`), checks the SHA3-256 hash of the archive, and makes `tclsqlite3.c`. It gets the Tcl sources with `tools/fetch-tcl.sh`. The sources are data for the spike, and ztcl does not build them. The run used tclsh 8.6.16 and gcc on x86-64 Linux, on 2026-11-26.

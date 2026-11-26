# Task 02: the WebAssembly spike

The same Tcl binding of SQLite 3.54.1 is built for `wasm32-wasi` with `zig cc`, and its tests ran in Node.js 26.12.0 in `ztcl-host.wasm`. Each `Tcl_*` slot of the module is an import. The imports in `tools/cext-spike/host.mjs` implement the slots with shadow `Tcl_Obj` records in the memory of the module, and they forward commands, scripts, and variables to ztcl. The binding called 53 public slots. Each of them is also in the list of task 01.

## The module

`tools/cext-spike/slots.py` writes `wshim.c`, the stubs table of the module. Each slot is a C function that adds 1 to its count in `shim_cnt` and calls the import `tcl.<name>`. The variadic slots (`Tcl_AppendResult`, `Tcl_SetErrorCode`, `Tcl_AppendStringsToObj`, `Tcl_VarEval`) give the import a pointer to the argument area of the call. `Tcl_Panic`, `Tcl_ObjPrintf`, and `Tcl_AppendPrintfToObj` format the text with `vsnprintf` in the module and give the import the text. `Tcl_InitStubs` of the shim sets `tclStubsPtr` to this table.

| File | Bytes | Gzip |
|---|---:|---:|
| `sqlite.wasm` (binding, SQLite, shim, wasi-libc) | 1,313,689 | 492,107 |
| `librecsqlite.so` of task 01, stripped, x86-64 | 1,339,448 | |

The module has 630 imports of the module `tcl` (one for each function slot) and 23 imports of `wasi_snapshot_preview1`. Its exports are `Sqlite3_Init`, `malloc`, `free`, `shim_cnt`, the memory, and the function table. SQLite reaches its files through WASI, and the preopen `/` is the work folder of the test. The WASI build of SQLite (`SQLITE_WASI`) has no WAL mode and no file locks.

## The bridge

`host.mjs` is the bridge of the spike, in JavaScript:

- **Objects.** A `Tcl_Obj` is 24 bytes in the memory of the module: `refCount`, `bytes`, `length`, `typePtr`, and the internal form. The host keeps the value of each object in a record (text, int, double, list, or bytes). `Tcl_GetString` writes the text into the memory of the module at the first call. `Tcl_IncrRefCount` and `Tcl_DecrRefCount` are macros that change `refCount` in the memory of the module, and `TclFreeObj` frees the record.
- **Types.** An object with an int, a double, a list, or bytes gets a `Tcl_ObjType` with the name of Tcl (`wideInt`, `double`, `list`, `bytearray`), because the binding reads `typePtr->name` to bind a variable. A value from ztcl keeps its kind: ztcl gives the kind of each argument and of each result (`int`, `double`, `str`, or `list`).
- **Commands.** `Tcl_CreateObjCommand` and `Tcl_NRCreateCommand` make a proc in ztcl: `proc db args { tailcall __cext_call ID [lindex [info level 0] 0] {*}$args }`. So the command runs in the frame of the caller, as `db eval` needs, and a `rename` of the proc keeps it working.
- **Scripts and variables.** `Tcl_EvalObjEx`, `Tcl_Eval`, `Tcl_GlobalEval`, and `Tcl_VarEval` run the text in ztcl and give the code: ok, error, return, break, or continue. `Tcl_GetVar2Ex` and `Tcl_ObjSetVar2` read and write the variable directly.
- **The non-recursive engine.** After the function of an NR command returns, the host runs the script of `Tcl_NREvalObj`, then the callbacks of `Tcl_NRAddCallback`, last in first, in one loop.
- **The interp.** The `Tcl_Interp` of the module is 64 bytes of zeros. The host keeps the result object of the interp.

The spike needs a hook in ztcl for commands of the host. `tools/cext-spike/ztcl-host-cext.patch` adds it to `ztcl-host.wasm` only, in a separate worktree. The patch is not part of ztcl: it is the shape of the API that the bridge needs.

| Export or import | What it does |
|---|---|
| import `ztcl_host.cext_call(argc, argv)` | Runs a command of the host. Each argument is the address, the length, and the kind of its text. |
| export `ztcl_cext_command(h, name)` | Makes a command that calls `cext_call`. |
| export `ztcl_cext_eval(h, script)` | Runs a script in the current frame and gives the code of the result. |
| export `ztcl_cext_get(h, name)` and `ztcl_cext_set(h, name, value, kind)` | Read and write a variable of the current frame. |

A test that runs for a long time needs the top-level eval of `ztcl_eval`, because only it sets up the scan range of the collector. With `ztcl_cext_eval` at the top, `collate1.test` used the 4 GiB of the memory of ztcl.

## The tests

The run used the 696 test files that ran to the end in task 01, 6 at a time, with a time limit of 300 s. The test harness is the same `tools/cext-spike/shim.tcl`. ztcl-host.wasm has no `file`, `glob`, `open`, or `exec`, so `host.mjs` gives the test scripts a small `file`, `glob`, and `source` on the work folder.

- 662 files ran to the end: 162,439 tests, 7,058 errors. The same 662 files have 199,200 tests and 4,847 errors in task 01.
- 636 files have the same count of tests and of errors as in task 01: 156,924 tests.
- 26 files ran to the end with other counts. 34 files stopped early.

The differences have these causes:

| Cause | Files |
|---|---|
| The WASI build of SQLite has no WAL mode and no file locks. | `wal7`, `wal8`, `wal9`, `walbig`, `walhook`, `walseh1`, `walcrash2`, `walcrash4`, `busy`, `lock3`, `pager4`, `readonly`, `tkt-f3e5abed55`, `incrblob_err`, `mmapcorrupt`, `mmapleak` |
| `format %.32e` of ztcl gives 17 significant digits and then zeros. The test compares the text with the double. | `atof1` (it stops at 1,000 errors) |
| The `file` of `host.mjs` has no `attributes -permissions` or `executable`, and ztcl-host.wasm has no channels or `exec`. | `temptable`, the `shell*` files |
| Threads, and the test commands of `testfixture` in C. | `thread*`, `walthread`, `sharedA`, `sharedB`, `notify2` |
| Speed: `selectG-100` checks a time. | `selectG` |
| Not checked. | `like3` (UTF-8 in `LIKE`), `view` (an empty column name in `view-22.2`), `e_vacuum` (the page size after `VACUUM`), `delete`, `backup2`, `main` (`main-3.2.2` gives no error after an error of a channel; the same SQL alone gives the error) |

Three bridge bugs were found in the run and fixed in `host.mjs`: the text of a double did not follow `tcl_precision`, the text of a list did not follow the quoting of Tcl (it now comes from the `list` command of ztcl), and the objects of `Tcl_GetVar2Ex` and `Tcl_ObjSetVar2` were not freed. After the fixes, every 7th file of the first full run (90 files) ran again, and each one has the same counts as before.

## The slots

The wasm run used 696 files and the native run 1,199, so the counts of files are not comparable. The 3 slots that only the native run called are `Tcl_ListObjIndex`, `Tcl_ListObjLength`, and `Tcl_BackgroundError`.

| Slot | Function | Native files | Wasm files | Wasm calls |
|---:|---|---:|---:|---:|
| 0 | `Tcl_PkgProvideEx` | 1,157 | 695 | 695 |
| 1 | `Tcl_PkgRequireEx` | 1,157 | 695 | 695 |
| 3 | `Tcl_Alloc` | 1,152 | 694 | 215,506 |
| 4 | `Tcl_Free` | 1,074 | 672 | 215,353 |
| 29 | `Tcl_DuplicateObj` | 6 | 3 | 12 |
| 30 | `TclFreeObj` | 415 | 274 | 395,398 |
| 32 | `Tcl_GetBooleanFromObj` | 13 | 5 | 14 |
| 33 | `Tcl_GetByteArrayFromObj` | 9 | 2 | 2 |
| 35 | `Tcl_GetDoubleFromObj` | 5 | 2 | 2,690 |
| 38 | `Tcl_GetIntFromObj` | 1,152 | 694 | 27,083 |
| 41 | `Tcl_GetStringFromObj` | 1,152 | 694 | 473,845 |
| 44 | `Tcl_ListObjAppendElement` | 693 | 446 | 4,026,546 |
| 45 | `Tcl_ListObjGetElements` | 34 | 20 | 469 |
| 46 | `Tcl_ListObjIndex` | 1 | 0 | 0 |
| 47 | `Tcl_ListObjLength` | 1 | 0 | 0 |
| 50 | `Tcl_NewByteArrayObj` | 25 | 11 | 10,389 |
| 51 | `Tcl_NewDoubleObj` | 91 | 70 | 151,261 |
| 52 | `Tcl_NewIntObj` | 602 | 400 | 3,231,449 |
| 53 | `Tcl_NewListObj` | 34 | 20 | 469 |
| 55 | `Tcl_NewObj` | 900 | 515 | 800,263 |
| 56 | `Tcl_NewStringObj` | 701 | 433 | 973,643 |
| 61 | `Tcl_SetIntObj` | 1 | 1 | 52 |
| 70 | `Tcl_AppendResult` | 1,152 | 694 | 28,729 |
| 76 | `Tcl_BackgroundError` | 1 | 0 | 0 |
| 88 | `Tcl_CreateChannel` | 9 | 2 | 4 |
| 96 | `Tcl_CreateObjCommand` | 1,157 | 695 | 1,390 |
| 103 | `Tcl_DeleteCommand` | 924 | 669 | 26,991 |
| 117 | `Tcl_DStringAppend` | 11 | 7 | 1,882 |
| 118 | `Tcl_DStringAppendElement` | 11 | 7 | 9,338 |
| 120 | `Tcl_DStringFree` | 1,152 | 694 | 28,939 |
| 122 | `Tcl_DStringInit` | 11 | 7 | 1,882 |
| 129 | `Tcl_Eval` | 6 | 4 | 176 |
| 156 | `Tcl_GetChannelName` | 9 | 2 | 4 |
| 166 | `Tcl_GetObjResult` | 54 | 28 | 651 |
| 174 | `Tcl_GetStringResult` | 37 | 21 | 5,828 |
| 177 | `Tcl_GlobalEval` | 9 | 6 | 1,864 |
| 196 | `Tcl_ObjSetVar2` | 87 | 64 | 249,690 |
| 210 | `Tcl_RegisterChannel` | 9 | 2 | 4 |
| 217 | `Tcl_ResetResult` | 91 | 63 | 930 |
| 232 | `Tcl_SetResult` | 38 | 7 | 14 |
| 235 | `Tcl_SetObjResult` | 901 | 516 | 905,805 |
| 249 | `Tcl_TranslateFileName` | 1,152 | 694 | 27,057 |
| 252 | `Tcl_UnregisterChannel` | 2 | 1 | 1 |
| 260 | `Tcl_VarEval` | 3 | 2 | 2,015 |
| 264 | `Tcl_WrongNumArgs` | 4 | 1 | 2 |
| 279 | `Tcl_GetVersion` | 1,152 | 694 | 48,325 |
| 293 | `Tcl_EvalObjEx` | 54 | 28 | 2,273 |
| 304 | `Tcl_GetIndexFromObjStruct` | 1,152 | 694 | 961,372 |
| 306 | `Tcl_GetVar2Ex` | 94 | 58 | 1,114,826 |
| 340 | `Tcl_GetString` | 1,152 | 694 | 934,984 |
| 487 | `Tcl_GetWideIntFromObj` | 74 | 43 | 749,264 |
| 488 | `Tcl_NewWideIntObj` | 28 | 23 | 45,659 |
| 489 | `Tcl_SetWideIntObj` | 17 | 8 | 125 |
| 583 | `Tcl_NRCreateCommand` | 1,152 | 694 | 27,055 |
| 584 | `Tcl_NREvalObj` | 94 | 67 | 21,270 |
| 587 | `Tcl_NRAddCallback` | 94 | 67 | 21,270 |

## Speed

`tools/cext-spike/bench.tcl` uses a database in memory with 100,000 rows. The times are the median of 3 runs, in ms, on the same machine.

| Part | Native | Wasm | Ratio |
|---|---:|---:|---:|
| `insert`: 100,000 `db eval` calls, each with one variable | 81 | 3,253 | 40 |
| `select-list`: one `db eval` that gives a list of 300,000 values | 29 | 674 | 23 |
| `select-script`: one `db eval` with a script for each of the 100,000 rows | 47 | 4,882 | 104 |
| `sql-only`: one `db eval` with the work in SQLite | 8 | 16 | 2 |

The work of SQLite is 2 times slower in the module. The other time is in the bridge of the spike: each call goes through JavaScript, each text goes into the memory of ztcl or of the module, and `ztcl_cext_eval` compiles the script of `db eval` again for each row. A profile of the `insert` part had 19% of the time in the creation of `DataView` objects before the views of the memory were kept. A bridge in Zig has none of the calls through JavaScript, and it can keep the compiled script in the object.

## Reproduce

```sh
tools/cext-spike/fetch.sh
ZIG=zig tools/cext-spike/wasm.sh LIST -j 6
```

`LIST` has one name of a test file on each line. `wasm.sh` builds `sqlite.wasm`, applies the patch in a worktree of ztcl at `$SPIKE/ztcl`, builds `ztcl-host.wasm` there, and runs the files. The run used Zig 0.17.0 and Node.js 26.12.0 on x86-64 Linux, on 2026-11-26.

# Task 04n: the native path

The user chose both paths on 2026-11-26 (issue #1). This file has the steps of the native path. The goal is the complete stubs API of Tcl 8.6: each of the 630 functions of the public table, then the 173 functions of the internal table and the platform tables. [The result page](../cext.md) has the areas, their order, and the coverage table.

## The shape

- `-Dcext=true` builds `src/cext/` and links the C library. The default build has no code of it. The capability `cext` registers `load`, and only an embedder or `--allow cext` turns it on. A package runs with the rights of the process, outside each limit and the root folder. `cext` is not sandboxed.
- `src/cext/slots.zig` has the slot names of the four tables, from `tools/cext/stubs.py`. `src/cext/stubs.zig` builds the tables at compile time. A slot gets the function of its name from a group file, or a function that records the call. The call into C then ends with the error "the C package called NAME (slot N of the public stubs table), which ztcl does not have".
- The `Tcl_Interp` of a package is a shadow (`cext.Shadow`). Its first fields have the layout of the start of `struct Interp` of Tcl 8.6, so `Tcl_InitStubs` reads `stubTable`, and a package can read `result` and `errorLine`.
- A group file has no dependency on `Interp` when its area has no need of one (memory, objects, lists and dicts, strings, hash tables). The WebAssembly path can then build the same file for wasm32.

## Steps

One step is one PR. Each group PR adds C test packages in `tests/cext/` and runs them with `tools/cext/check.sh`, which compares the output of tclsh and ztcl. Each PR updates the coverage table with `tools/cext/coverage.py`.

| Step | Result |
|---|---|
| 1 | The tables, the shadow, `load`, the capability, the memory area, and the package slots that need no `Tcl_Obj`. |
| 2 | Objects: `Tcl_Obj` in the layout of Tcl 8.6, the types `int`, `double`, `boolean`, `bytearray`, `list`, `dict`, and the types of packages. A value of ztcl becomes a `Tcl_Obj` at each call into C, and a `Tcl_Obj` becomes a value at each return. |
| 3 | Scripts and results, with commands of packages (`Tcl_CreateObjCommand`) and the non-recursive engine. |
| 4 | Channels: channel types of packages, stacked channels, and the channels of ztcl as `Tcl_Channel`. |
| 5 to 16 | The other areas in the order of the result page: strings and encodings, lists and dicts, errors, interps and commands, hash tables, variables, events, namespaces, threads, filesystem, zlib. The rest of the package area goes with objects. |
| 17 | The internal table, then the platform tables, then the stubs tables of TclOO and of libtommath (`tcl::tommath`). A package gets each one from `Tcl_PkgRequireEx` of `TclOO` or `tcl::tommath`. Itcl uses the TclOO table, and a package with the bignum slots uses the libtommath table. |
| 18 | The SQLite binding, then TclX and Itcl: their own tests on ztcl, with the pass counts next to tclsh. |
| 19 | A shim `libtcl8.6` for packages that link Tcl with no stubs. |
| 20 | The user page "C packages": the capability, the limits, and the platform notes. |

## Platforms

Linux on x86-64 is first. macOS uses the same `dlopen` and the same table. The platform table has 3 slots on macOS, and 4 slots with 3 functions on Windows. Windows needs `LoadLibraryW` and the Windows layout of the public table, where some slots are reserved. `stubs.py` reads the Unix headers today. The platform sessions test their builds later.

## Resume

- `tools/cext/check.sh [ZTCL] [NAME...]` builds `tests/cext/NAME.c` with the headers and the stub library of the tclsh of the host, and compares the outputs of `NAME.tcl`. Build the runner with `zig build -Dcext=true` first.
- `tools/cext/corpus.sh` downloads the corpus and writes the slot counts of each package.
- `python3 -I tools/cext/coverage.py` writes the coverage table, and `--check` fails when the table is old.

## Notes for step 3

`src/cext/host.zig` has the slots of commands, scripts, results, variables, and the non-recursive engine for both paths. `src/cext/native.zig` gives them the interpreter through `src/cext/zside.zig`, and `src/wasm_cext.zig` uses the same functions. `tests/cext/cxcmd.c` checks them against tclsh. A value crosses as an `Arg`. A list crosses as an array of `Arg`s, one for each element, and text crosses in modified UTF-8 (U+0000 is C0 80). The rest of the area scripts and results is the next PR.

## Notes for step 2

Step 2 is done except the 6 bignum slots of the area objects, which need the `mp_int` of libtommath. They go with the libtommath table in step 17. `src/cext/obj.zig` has the slots of both paths, and `cext.toObj` and `cext.fromObj` are the bridge of values. `tests/cext/cxobj.c` checks the area against tclsh.

- `Tcl_Obj` is 48 bytes on x86-64: `refCount` (int), `bytes`, `length` (int), `typePtr`, and 16 bytes of internal form. `Tcl_IncrRefCount` and `Tcl_DecrRefCount` are macros in the package, so the count is in that memory, and the package calls `TclFreeObj` at 0.
- `Tcl_Alloc` is `malloc` (`mem.zig`), so `std.heap.c_allocator` and `ckfree` free the same blocks. A package can set `bytes` with `ckalloc` in its own `updateStringProc`.
- The type names on LP64 Unix are the names of Tcl 8.6 there: `int` (no `wideInt`), `double`, `bytearray`, `list`, `dict`, `bignum`. Windows is LLP64, so `wideInt` is a separate type there.
- `value.zig` has `parseInt`, `parseDouble`, `formatDouble`, `parseList`, `listToString`, and `appendElement`, with no `Interp`. The objects can use them for the text forms.
- The error of a slot such as `Tcl_GetIntFromObj` goes to the result of the interp. Step 2 keeps a result object in the shadow, and step 3 adds the result slots on it. At the return to ztcl, the result object becomes the value of the command or the message of the error.
- A ztcl value becomes a `Tcl_Obj` with its kind: an int, a double, a list with its elements, or a string with the text in modified UTF-8 (U+0000 is C0 80). A `Tcl_Obj` of a type of a package becomes its string.

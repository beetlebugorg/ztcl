# libztcl

libztcl is a shared library with the C API of Tcl 8.6. A program that links libtcl8.6 loads libztcl in its place and runs its Tcl on ztcl, with no change to the program (issue #246).

## Build and use

```sh
zig build libztcl
```

The step writes `zig-out/lib/libtcl8.6.so` on Linux (the SONAME is `libtcl8.6.so`), `zig-out/lib/libtcl8.6.dylib` on macOS (the install name is `@rpath/libtcl8.6.dylib`), and the name `tcl86.dll` is set for Windows. The Windows build fails today with the reason: the C package code has no Windows port, and Zig 0.17 has no `VaList` with LLVM on x86-64 Windows. The library has the cext code of `-Dcext=true` in it, so `load` of C packages works in each interp.

A program that links libtcl8.6 dynamically uses libztcl with `LD_LIBRARY_PATH`:

```sh
LD_LIBRARY_PATH=zig-out/lib /usr/bin/tclsh8.6 script.tcl
```

A program built for libztcl links it as libtcl8.6:

```sh
cc $TCL_INCLUDE_SPEC app.c -Lzig-out/lib -ltcl8.6 -Wl,-rpath,zig-out/lib
```

The step also installs the development kit of [docs/libztcl.md](../libztcl.md): the headers of Tcl 8.6.16 in `include/tcl8.6` (from `packaging/libztcl/include`, with no change), the stub library `lib/libtclstub8.6.a` (`src/tclstub.zig`), `lib/tclConfig.sh`, and `lib/pkgconfig/tcl.pc` and `ztcl.pc` (`addKit` in build.zig).

## What the library exports

`src/libztcl.zig` is the root of the library. Each named slot of the public, internal, and internal platform stubs tables (`src/cext/slots.zig`) is an exported function with the name of Tcl and the C ABI. A slot gets the function of the first group of `src/cext/stubs.zig` that has it: the same function that a C package reaches through the stubs table. A slot with no function gets a function that writes the slot name to the standard error and aborts:

```
libztcl: the program called Tcl_ThreadQueueEvent (slot 319 of the public stubs table), which ztcl does not have
```

So a program loads, and it stops at the first call of a missing function with the name of that function. The functions of `tcl.h` outside the stubs table are `Tcl_MainEx`, `Tcl_PkgInitStubsCheck`, and `Tcl_GetMemoryInfo`, from `src/cext/app.zig`, and `Tcl_Main` as a function for a program built against older headers. The libtcl8.6 of Arch Linux exports 884 functions. libztcl exports 815 functions. The 86 other functions of libtcl8.6 are the bignum functions of the tommath stubs table (`TclBN_*`) and 8 helpers of the Unix port (`TclpGetPwNam` and others).

## The interp of `Tcl_CreateInterp`

`src/cext/app.zig` has the slots of an application: `Tcl_CreateInterp`, `Tcl_DeleteInterp`, `Tcl_InterpDeleted`, `Tcl_Exit`, `Tcl_Finalize`, the exit handlers, and the startup script. An interp of `Tcl_CreateInterp` is a ztcl interp on the C heap. Its `Tcl_Interp` pointer is the shadow of `src/cext/cext.zig`, so the slots of the other groups reach the interp by its handle, as for a package.

The interp has the capabilities of tclsh in host mode: `package`, `interp`, `clock`, `channels` (with `stdin`, `stdout`, and `stderr`), `file`, `event`, `socket` (the network policy `any`), `exec` (with the environment of the process), `thread`, `random`, `env`, `sqlite`, and `cext`. It has the `exit` command, which calls `Tcl_Exit`. It has no memory limit and no compute limit. This interp is not sandboxed: it has the full power of the user, as in Tcl.

`Tcl_DeleteInterp` deletes the interp at once. Tcl waits for each `Tcl_Release` of the interp first. The delete flushes `stdout` and `stderr` and leaves the descriptors 0, 1, and 2 open for the program. `Tcl_Exit` runs the exit handlers, last in first, deletes each interp, and calls `exit` of the C library.

A call of `Tcl_Eval` (and the other script slots) with no script of ztcl running is a top-level eval (`Interp.evalTop`): it sets the scan range of the collector, and an error there sets `errorInfo` and `errorCode`, as in Tcl.

`Tcl_MainEx` follows the manual page of `Tcl_Main`. The first word of `argv` that does not start with `-` is the script, and `-encoding name fileName` gives the script with an encoding. The function sets `argv0`, `argv`, `argc`, and `tcl_interactive`, and calls the init function of the application. Then it runs the script, or the commands of the standard input one complete command at a time. In a terminal, it sources `tcl_rcFileName` first, shows each result, and shows the prompt `% `. An error of the script writes `errorInfo` to the standard error and ends the process with code 1.

## Tests

| Command | What it checks |
|---|---|
| `tools/libztcl/check.sh` | Builds `tests/libztcl/embed.c` against the libtcl8.6 of the host and against libztcl, and compares the output and the exit code of 7 cases: `Tcl_Main` with a script, `exit`, a script error, the commands of the standard input, and `Tcl_CreateInterp` and `Tcl_Eval` with no `Tcl_Main`. |
| `tools/libztcl/tclsh.sh` | Builds the tclsh of `unix/tclAppInit.c` of Tcl 8.6.16 against both libraries and compares `tests/libztcl/tclsh-*.tcl` and the commands of the standard input. |
| `tools/libztcl/kit.sh PREFIX [ZTCL]` | Builds `tests/libztcl/kit/kitext.c` with the variables of `PREFIX/lib/tclConfig.sh` and the stub library, as TEA does, and `kitembed.c` with `pkg-config --cflags --libs tcl`. It runs `kit.tcl` in `kitembed` on libztcl, in the runner `ZTCL`, and in the tclsh of the host, and compares each output with `kit.want`. |
| `python3 -I tools/libztcl/needs.py FILE...` | Lists the Tcl functions that a program or a library imports and that libztcl does not have, and ranks them by the count of files that need them. |

`embed.c` is a test program of ztcl. It uses the public API only: `Tcl_FindExecutable`, `Tcl_Main`, `Tcl_CreateInterp`, `Tcl_Init`, `Tcl_CreateObjCommand`, `Tcl_Eval`, the result slots, the variable slots, the list and number slots, and `Tcl_DeleteInterp`.

## Test subjects

The results of 2026-11-27 on x86-64 Linux. A subject runs; its source is not read unless its license allows it (Tcl and SQLite).

| Program | How it was built | Tcl imports | Missing | Result |
|---|---|---:|---:|---|
| `tests/libztcl/embed.c` | `cc` against the Tcl 8.6 headers | 19 | 0 | The 7 cases of `check.sh` give the output of libtcl8.6. |
| tclsh of Tcl 8.6.16 (`unix/tclAppInit.c`) | `cc` against the Tcl 8.6 headers | 5 | 0 | `tclsh-basic.tcl` (namespaces, regexp, clock, files, glob, `exec`, a socket on loopback, `vwait`, `exit`) and the standard input give the output of libtcl8.6. |
| `/usr/bin/tclsh8.6` of Arch Linux, unchanged | the package `tcl` 8.6 | 5 | 0 | With `LD_LIBRARY_PATH`, `tclsh-basic.tcl` gives the output of libtcl8.6. |
| tclsh of SQLite 3.54.1 (`tclsqlite3.c` with `-DTCLSH=1`) | `cc` | 71 | 0 | A script with a transaction, a function of Tcl, an array row, a blob, and an error gives the output of libtcl8.6. |
| `/usr/lib/whiptcl.so` of newt (a Tcl package that links libtcl8.6) | the package `libnewt` | 8 | 1 | Not run. |

## Missing functions by programs blocked

From `tools/libztcl/needs.py` on the subjects above. This list goes to the agent of the stubs tables (#1).

| Function | Programs blocked |
|---|---|
| `Tcl_CreateCommand` | whiptcl.so |

## Not done

- The tommath stubs table (`TclBN_*`) and the Unix helpers outside the four tables.
- The thread model of Tcl for servers: `Tcl_Mutex`, `Tcl_Condition`, thread data, and `Tcl_ThreadQueueEvent` on ztcl threads. AOLserver and NaviServer need it.
- The legacy fields of `Tcl_Interp` other than the first four: `result` is an empty string, and a program that reads `interp->result` gets no text.
- The Windows build (`Tcl_MainExW`, the platform table of Windows), and a run on macOS. The macOS library builds (`-Dtarget=aarch64-macos`) and is not run yet.
- libztk, the library of Tk 8.6 for Python's `_tkinter` (ztk #223).

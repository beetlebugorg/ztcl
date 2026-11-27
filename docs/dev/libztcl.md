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

## Threads, commands, and files

`src/cext/threads.zig` has the thread slots: `Tcl_MutexLock`, `Tcl_MutexUnlock`, `Tcl_ConditionWait` (with a time limit), `Tcl_ConditionNotify`, their finalize slots, `Tcl_GetThreadData`, `Tcl_CreateThread`, `Tcl_JoinThread`, `Tcl_ExitThread`, the exit handlers of a thread, `Tcl_GetTime`, `Tcl_Sleep`, the async slots, and `Tcl_InitNotifier`. A mutex and a condition are pthread objects. The first use makes them under one global lock.

`src/cext/cmds.zig` has `Tcl_CreateCommand` (a command with a string function), `Tcl_GetCommandInfo`, `Tcl_SetCommandInfo`, their forms with a token, and `TclRenameCommand`. The info of a command of ztcl has an object function that runs a copy of the command under a hidden name, so a new command with the old name (Expect does this for `close`) does not change what the saved function runs.

`src/cext/fs.zig` has the filesystem slots of the native filesystem: the path functions, the file functions over the C library, `Tcl_FSMatchInDirectory` over `glob`, and `Tcl_FSLoadFile` over `dlopen`. `Tcl_FSGetTranslatedStringPath` gives a copy that the caller frees, as its manual page says. A normalized path is its own normalized path.

A slot with no interp argument, such as `Tcl_OpenFileChannel(NULL, ...)` or `Tcl_GetStdChannel`, uses the interp of the last command. With no such interp, as in a server that reads its config before it makes an interp, libztcl gives the slot a hidden interp of the thread (`spareInterp` of `src/libztcl.zig`). The runner of ztcl has no hidden interp. `Tcl_FindExecutable` keeps the absolute path of the program.

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
| `/usr/lib/whiptcl.so` of newt (a Tcl package that links libtcl8.6) | the package `libnewt` | 8 | 0 | Not run. |
| `expect` 5.45.4 of Arch Linux, unchanged | the package `expect`, extracted to a folder | 5 (and the stubs table) | | Loads `Expect`, and stops at the async slots and `Tcl_GetGlobalNamespace` (the stubs agent has the namespace slots). |
| NaviServer 5.0.3, unchanged | `./configure --with-tcl=KIT/lib` against the kit of [libztcl.md](../libztcl.md), and against the Tcl 8.6 of the host | 238 | 0 | Serves the static file, the ADP pages, and its index page on libztcl with the bodies and the log warnings of the build on Tcl. [The benchmark](#the-page-load-benchmark) has the numbers. |
| AOLserver 4.5.1, unchanged | `./configure --with-tcl=/usr/lib` and `make` | | | Does not build with GCC 15 against the Tcl of the host: `nsthread/pthread.c` has an implicit declaration of `pthread_getattr_np`, an error in GCC 15. So NaviServer, its maintained fork, is the subject. |

## The page-load benchmark

`tools/libztcl/naviserver.sh build TARBALL KIT OUT` builds NaviServer twice from its release tarball with no change: against the kit of `zig build libztcl --prefix KIT` and against the Tcl of the host. `tools/libztcl/naviserver.sh bench KIT OUT` runs `tools/libztcl/httpload.zig`, a small load generator in Zig (the host has no `wrk` or `ab`), on four cases with keep-alive connections. The config is `simple-config.tcl` of NaviServer with a new port.

To run on libztcl, NaviServer needed these changes in libztcl (PR #502):

- The filesystem slots (`fs.zig`) and `Tcl_FindExecutable` with the absolute path. `nsd` finds its home folder from the path of the program.
- `Tcl_FSGetTranslatedStringPath` gives a copy that the caller frees, as its manual page says. A normalized path is its own normalized path.
- A channel slot with no interp (`Tcl_OpenFileChannel(NULL, ...)` for the config file) uses a hidden interp of the thread. `chan.last` no longer points to the shadow of a deleted interp.
- The create proc of a hash table with a null flag pointer only finds, as in Tcl 8.6. The `nsv` commands call it so.
- `Tcl_DStringAppendElement` with a null element appends an empty element, as in Tcl 8.6.
- The thread slots (`threads.zig`).

Results of 2026-11-27 on x86-64 Linux (8 cores, with other builds on the host, so the load average was 14). NaviServer 5.0.3 with its default 10 connection threads, libztcl in ReleaseFast. The ranges are of 3 rounds.

| Case | Connections | Tcl 8.6.16: requests/s | p50 ms | p99 ms | libztcl: requests/s | p50 ms | p99 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| Static file, 4 KB | 20 | 6,054 to 9,566 | 2.08 to 2.60 | 4.32 to 16.62 | 7,618 to 8,618 | 2.38 to 2.65 | 4.40 to 4.73 |
| Small ADP page | 20 | 5,567 to 10,396 | 2.08 to 2.87 | 4.59 to 19.75 | 6,303 to 8,836 | 2.30 to 3.22 | 4.60 to 6.44 |
| ADP page with Tcl work | 8 | 358 to 1,062 | 6.89 to 19.15 | 18.02 to 64.33 | 2,060 to 2,317 | 2.81 to 3.35 | 11.94 to 14.00 |
| Small ADP page | 200 | 8,034 to 8,511 | 20.95 to 21.91 | 29.49 to 42.83 | 6,419 to 7,706 | 20.12 to 26.65 | 31.48 to 49.12 |

The resident memory of `nsd` after a round is 27 MB to 28 MB on Tcl and 248 MB to 255 MB on libztcl. Each connection thread of NaviServer has its own interp, and an interp of ztcl takes more memory than an interp of Tcl. This is the next item for servers.

### Profile and changes

`perf record --user-callchains` on `nsd` under `httpload` (this host allows user call chains only). The CPU time of `nsd` for each request (user and system time from `/proc`, divided by the requests) is steadier than the requests per second on this host, which had a load average of 14 to 26.

| CPU µs for each request | Static file | Small ADP page | ADP page with Tcl work | RSS after the runs |
|---|---:|---:|---:|---:|
| Tcl 8.6.16 | 98 to 105 | 123 to 128 | 3,295 to 3,370 | 28 MB |
| libztcl, first run | 111 | 148 | 1,260 | 247 MB |
| libztcl, this PR | 113 to 120 | 129 to 137 | 1,335 to 1,380 | 255 MB to 284 MB |

- The static file runs in the C code of NaviServer and libc. The functions of libztcl are 10% of its CPU (14% for libtcl8.6 on Tcl), mostly `Tcl_DStringSetLength` and `Tcl_DStringAppend` for the log, with the same work as in Tcl. The differences on this page are in the range of the noise of the host.
- On the small page, a `switch -glob` of the scripts of NaviServer parsed its literal list of patterns and bodies at each call (`cmdSwitch`, `listSlow`, `parseList`: 5% of the CPU). The compiler now keeps such a literal as a list value (`listSwitchBody` in `src/vm.zig`), as Tcl keeps the list form of a literal.
- A command of a C package looked up its own name at each call (`native.cmdC`). It now uses the command of the call site when the site is current.
- The memory is in the heaps of the 10 interps: a collection waits for 16 MB of heap in each interp, and each interp keeps up to 16 MB of free blocks. A threshold of 1 MB and a smaller margin after each collection gave 100 MB to 125 MB for 25% more CPU on the work page. Those changes are in the collector, so they are in issue #526 with the numbers. This PR only sets the first threshold and the free lists of an interp of `Tcl_CreateInterp`.
- The JIT is off in an interp of `Tcl_CreateInterp`.

## Missing functions by programs blocked

From `tools/libztcl/needs.py` on the subjects above. This list goes to the agent of the stubs tables (#1).

None of the subjects above imports a missing function now. The slots that Expect and NaviServer reach through the stubs table are in the table of the subjects.

## Not done

- The tommath stubs table (`TclBN_*`) and the Unix helpers outside the four tables.
- `Tcl_ThreadQueueEvent` and `Tcl_ThreadAlert`: they need the event queue of the C API.
- ztcl does not call `Tcl_AsyncInvoke` between commands yet.
- The memory of an interp: NaviServer on libztcl uses 9 times the memory of NaviServer on Tcl (issue #526).
- The JIT in interps of `Tcl_CreateInterp`, and compiled code shared across the interps of the threads.
- The legacy fields of `Tcl_Interp` other than the first four: `result` is an empty string, and a program that reads `interp->result` gets no text.
- The Windows build (`Tcl_MainExW`, the platform table of Windows), and a run on macOS. The macOS library builds (`-Dtarget=aarch64-macos`) and is not run yet.
- libztk, the library of Tk 8.6 for Python's `_tkinter` (ztk #223).

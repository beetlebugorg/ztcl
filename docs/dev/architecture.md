# Architecture: the module map and the layout of src/

This page has the map of the modules of `src/` by area, the target layout by folder, the rules of the layers, and the place of a new feature. Issue #537 has the findings and the plan of the moves. Phase 1 moves no file. The layout below is a target, and the moves of phase 2 make it true one area at a time.

## The tool

`tools/modmap.zig` reads each `.zig` file below `src/` and prints the map in Markdown. The areas file `tools/modmap.areas` gives the area of each file and the rules of the layers.

```sh
zig run tools/modmap.zig -- --dot zig-out/modmap.dot --area-dot zig-out/modmap-areas.dot > zig-out/modmap.md
zig run tools/modmap.zig -- --only summary,areas,cycles,layers
zig test tools/modmap.zig
```

The report has these sections: `summary`, `areas`, `cycles`, `layers`, `unmapped`, `deadfiles`, `deadfns`, `dups`, and `map`. The `map` section gives the lines, the test blocks, the imports, the importers, and the test files of each file. The top of `tools/modmap.zig` has the method of each section and the format of the areas file.

The CI job `Module map` runs the tool on each push and each pull request. It writes the summary to the page of the run and keeps the full report and the DOT files as the artifact `modmap`. The job is a report: a layering break does not fail it. A later PR makes the layer rules a check (phase 2 of #537).

Give a new file an area in `tools/modmap.areas` in the same PR. The section `unmapped` of the report lists each file with no area.

## The map today

Measured with `zig run tools/modmap.zig` on main at `ad53887` (2026-11-27).

| Item | Count |
|---|---|
| Files | 270 |
| Lines | 160,746 |
| Test blocks | 624 |
| Imports between files | 1,142 |
| Cycles (components of 2 or more files) | 6 |
| Layering breaks | 92 |
| Files that no build root reaches | 0 |

| Area | Files | Lines | What it owns |
|---|---|---|---|
| core | 35 | 35,574 | The parser, the interpreter, values, the bytecode compiler and executor, the JIT, the heap, the collector, namespaces, traces, coroutines, and the features of a build. |
| point | 4 | 2,444 | Point procs: the small part of Tcl that runs for each point of a path, its runtime, and its WebAssembly compiler. |
| cmds | 14 | 12,254 | The commands of the language, by family: lists, strings, dicts, `format`, `regexp`, TclOO, `package`, `interp`, and the commands of Tcl 9.1. |
| meter | 2 | 870 | `ztcl::meter`: the use of compute units, time, memory, and I/O. |
| sys | 6 | 3,265 | The platform interface of the event loop, `socket`, and `exec`, with one file for each OS. |
| os | 28 | 14,409 | The capabilities that reach the host: channels, encodings, files and the folder jail, processes, PTYs, sockets, serial ports, the event loop, `clock`, `ztcl::open`, `ztcl::notify`, `ztcl::watch`, D-Bus, zip mounts, and the Windows and macOS APIs. |
| thread | 6 | 4,779 | The capability `thread`: groups, messages, pools, shared variables, mutexes, and channels between threads. |
| isolate | 7 | 5,017 | Isolated threads: the broker, the protocol, and the sandbox of each OS. |
| stdlib | 45 | 14,324 | Libraries with no Tcl in them: `aio`, crypto kernels, HTTP/2, TLS, inflate, zip, and the WebAssembly writer. |
| stdcmd | 9 | 3,334 | The commands of the batteries on those libraries: `ztcl::json`, `ztcl::tls`, and `ztcl::vt`. |
| vm | 21 | 16,554 | `ztcl::vm`: the monitors on KVM, the Windows Hypervisor Platform, and Virtualization.framework, virtio, the NAT, and the signed guest images. |
| wasm | 16 | 9,698 | The WebAssembly library, its files and channels, its threads, the host commands `dom` and `web::`, the AOT compiler, and the WebAssembly runtime `ztcl::wasm`. |
| cext | 28 | 15,365 | C packages: the stubs table, the C API of Tcl 8.6, libztcl, and the bridge in WebAssembly. |
| debug | 5 | 3,767 | Probes, record and replay, `ztcl debug`, DAP, and MCP. |
| registry | 1 | 152 | The table of built-in modules (`modules.zig`). |
| cli | 20 | 7,192 | The runner, its shell, `ztcl build`, `ztcl compile`, and `ztcl build --strip`. |
| api | 3 | 878 | The roots that embedders import: `ztcl.zig`, `wasm.zig`, and `enclave_core.zig`. |
| tests | 20 | 10,870 | `tests.zig` and the `*_tests.zig` files. |

The import graph has one large cycle of 125 files. `interp.zig` imports about 50 modules of each area to turn on their commands and capabilities, and each of those modules imports `interp.zig`. The other five cycles are small: an interface and its OS forms (`sys.zig` and `sys_*.zig`, `aio/aio.zig` and its backends), `kvm.zig` and `vm/kvm_snapshot.zig`, three virtio devices, and `wasm.zig` with `wasm_cext.zig` and `wasm_shell.zig`.

## The target layout

Each area is one folder. The file names below are the target names. Phase 2 of #537 makes each move in a move-only PR.

| Folder | Area | Files today |
|---|---|---|
| `src/` | api, registry | `ztcl.zig`, `wasm.zig`, `enclave_core.zig`, `modules.zig` |
| `src/core/` | core | `interp.zig`, `value.zig`, `expr.zig`, `expr_diag.zig`, `heap.zig`, `gc.zig`, `compact.zig`, `features.zig`, `features_table.zig`, `bigint.zig`, `ucd.zig`, `ns.zig`, `trace.zig`, `coro.zig`, `noise.zig`, `mathns.zig` |
| `src/core/bytecode/` | core | `vm.zig` (renamed: the name `vm` is also `ztcl::vm` and `src/vm/`) |
| `src/core/jit/` | core | `jit.zig` and `jit/` |
| `src/point/` | point | `point.zig`, `point_rt.zig`, `point_wasm.zig`, `point_fuzz.zig` |
| `src/cmds/` | cmds | `cmds.zig`, `dict.zig`, `more.zig`, `extra.zig`, `format.zig`, `regex.zig`, `math9.zig`, `oo.zig`, `pkg.zig`, `tcl9.zig`, `child.zig`, `disasm.zig`, `agent.zig`, `hello.zig` |
| `src/meter/` | meter | `meter.zig`, `metercmd.zig` |
| `src/sys/` | sys | `sys.zig`, `sys_windows.zig`, `sys_wasi.zig`, `sys_wasi3.zig`, `wasi/p3.zig`, `wasi/async.zig` |
| `src/os/` | os | `chan.zig`, `chanrefl.zig`, `enc.zig`, `filecmd.zig`, `fsroot*.zig`, `proc*.zig`, `pty*.zig`, `sock.zig`, `serial.zig`, `event.zig`, `clock.zig`, `launch.zig`, `notify*.zig`, `watch*.zig`, `dbus.zig`, `vfs.zig`, `mac.zig` |
| `src/os/windows/` | os | `winreg.zig`, `wincred.zig`, `winfolder.zig` |
| `src/thread/` | thread | `thread.zig`, `threadcmd.zig`, `tpool.zig`, `tsv.zig`, `tsync.zig`, `tchan.zig` |
| `src/isolate/` | isolate | `isobroker.zig`, `isoproto.zig`, `isothread.zig`, `isovm.zig`, `isolate_linux.zig`, `isolate_mac.zig`, `isolate_windows.zig` |
| `src/stdlib/` | stdlib, stdcmd | `aio/`, `crypto/`, `h2/`, `tls/`, `json/`, `vt.zig`, and `zip/` with `zipread.zig`, `zipwrite.zig`, `inflate.zig` |
| `src/stdlib/wasmbin/` | stdlib | `wasm_out.zig`, `wasm_link.zig` |
| `src/vm/` | vm | `microvm.zig`, `kvm.zig`, `whp.zig`, `vz.zig`, `vmagent.zig`, `vmimage.zig`, `vmstore.zig`, and the folder `vm/` of today |
| `src/wasm/` | wasm | `wasm_shell.zig`, `wasmbundle.zig`, `wasmdom.zig`, `wasmfiles.zig`, `wasmweb.zig`, `webasync.zig`, `webthread.zig`, `wasm_aot/`, `wasmrt/` |
| `src/cext/` | cext | `cext/`, `cext_stubs.zig`, `wasm_cext.zig`, `libtcl.zig`, `libztcl.zig`, `tclstub.zig` |
| `src/debug/` | debug | `debug.zig`, `debugmcp.zig`, `dap.zig`, `probe.zig`, `tape.zig` |
| `src/cli/` | cli | `main.zig`, `buildcmd.zig`, `buildnative.zig`, `stripbuild.zig`, `stripscan.zig`, `macho.zig`, `compile.zig`, `compilecmd.zig`, `wasi/run.zig`, `shell/` |

The tests of a module move with the module: `debug_tests.zig` goes to `src/debug/`, and `isolate_linux_tests.zig` goes to `src/isolate/`.

The draft of #537 had one area `stdlib` for the batteries. The graph gives two layers in that folder. The libraries (`aio`, `tls`, `h2`, zip) import no file outside `stdlib`, and only their command files (`json/`, `tls/cmd.zig`, `vt.zig`) import the interpreter. The draft had the JIT in core. `jit/` imports `interp.zig` and `vm.zig`, and `vm.zig` imports `jit.zig`, so the JIT stays in core. The draft had no folders for threads and isolation. Those are 13 files and 9,796 lines with their own layer, so they get `thread/` and `isolate/`. `sys/` is a separate area because `os/`, `thread/`, `isolate/`, `vm/`, and `cext/` all use the platform interface.

## The rules of the layers

`tools/modmap.areas` has these rules as `area` lines. The section `layers` of the report lists each import that breaks one.

1. `stdlib/` libraries import no other area. Only a command file of a battery (area stdcmd) imports the interpreter.
2. `sys/` imports only `stdlib/`.
3. `core/` imports only `stdlib/`. It never imports `cmds/`, `os/`, `vm/`, `wasm/`, `cext/`, `debug/`, or an OS form.
4. `cmds/` imports `core/`, `point/`, and `stdlib/` only. A command that reaches the host goes in `os/`.
5. Platform code for one OS stays behind one interface file. The other areas import the interface (`sys.zig`, `fsroot.zig`, `proc.zig`, `pty.zig`, `watch.zig`, `notify.zig`), never a `_windows`, `_macos`, `_linux`, or `_wasi` file. The interface picks the form with `builtin.os.tag`.
6. `os/`, `thread/`, `isolate/`, `vm/`, `wasm/`, `cext/`, and `debug/` are above `core/` and `cmds/`, in that order. A lower area does not import a higher one.
7. Nothing in `src/` imports an api root (`ztcl.zig`, `wasm.zig`). Only tests, `cli/`, and embedders import them.
8. No import cycle between two areas. A cycle inside one area is allowed only between an interface and its OS forms.
9. Each module keeps its tests in its own `test` blocks or in `NAME_tests.zig` beside it. A `tests.zig` file only imports test files.

The capability table is the one place where the rules need new code. Today `interp.zig` turns on each capability and registers each command family. Phase 3 of #537 moves that table to a registry above all areas (`src/caps.zig`), which `ztcl.zig` and the runners give to `Interp`. The probes and the record and replay of `debug/` get a hook interface in `core/`, so `core/` and `os/` call the hooks with no import of `debug/`.

## File size

Keep a file under about 2,000 lines. Split a larger file by concern, with one concern in each file. Generated tables and golden test data have no limit: `jit/x64_golden.zig` (8,943 lines) and `jit/a64_golden.zig` (3,242 lines).

A method of a struct can live in another file. Write the function with the struct as its first parameter and add `pub const name = @import("file.zig").name;` in the struct. Calls such as `it.evalCmd(...)` then stay the same.

The splits for the five largest files follow. Each split is a PR of its own after the moves of its area, with no change of behavior. The line numbers are of main at `ad53887`.

### `interp.zig` (3,726 lines)

| New file | Lines today | Concern |
|---|---|---|
| `core/parse.zig` | 41 to 466 | The compiled form (`Word`, `Cmd`, `Script`) and the parser. |
| `core/frame.zig` | 467 to 638 | Variables, element links, and frames. |
| `core/command.zig` | 639 to 1,018 | `Proc`, `Command`, the command table, `Output`, and `Counting`. |
| `core/caps.zig` | 1,019 to 1,261 | `TclVersion`, `Capability`, `ReturnCode`, and the text cache. |
| `core/interp.zig` | 1,262 to 2,272 | `Interp`: its fields, `init`, `reset`, and the limits. The code that turns on each capability goes to the registry (phase 3). |
| `core/eval.zig` | 2,273 to 3,280 | `evalTop`, `evalCmd`, the fast paths, `call`, frames, and lambdas. |
| `core/vars.zig` | 3,281 to the end | The reads and the writes of variables and elements. |

### `microvm.zig` (3,692 lines)

| New file | Lines today | Concern |
|---|---|---|
| `vm/cmd.zig` | 1 to 179 | `Host`, `register`, and the ensemble `ztcl::vm`. |
| `vm/fetch.zig` | 180 to 512 | Image names, releases, and `image fetch`, on `vmstore.zig`. |
| `vm/args.zig` | 513 to 660 | The arguments of `vsock`, `exec`, and `mount`, and the network policy of the NAT. |
| `vm/backend_macos.zig` | 661 to 1,338 | The `mac` backend on `vz.zig`. |
| `vm/backend_linux.zig` | 1,339 to 2,682 | The `lin` backend on `kvm.zig`. |
| `vm/backend_windows.zig` | 2,683 to the end | The `win` backend on `whp.zig`. |

The three backends then have one interface in `vm/cmd.zig`, as rule 5 asks.

### `tests.zig` (3,608 lines)

Each group moves beside its module, and `tests.zig` keeps only the imports.

| New file | Lines today | Tests |
|---|---|---|
| `core/parse_tests.zig` | 41 to 503 | The parser, `expr`, and `dict`. |
| `core/limits_tests.zig` | 504 to 907 | The compute limit, the memory limit, and the bounds of `glob` and `info`. |
| `core/bytecode/tests.zig` | 908 to 1,186 and 2,723 to 2,873 | The bytecode, `lset` in place, `switch`, and `lassign`. |
| `os/caps_tests.zig` | 1,187 to 2,281 | Traces, modules, the capabilities of a child, the folder jail, `exec`, and `socket`. |
| `core/gc_tests.zig` | 2,282 to 2,722 | The collector. |
| `cmds/binary_tests.zig` | 2,874 to 2,990 | `binary encode` and `binary decode` of base64. |
| `os/launch_tests.zig` | 2,991 to 3,258 | `ztcl::open` and `ztcl::notify`. |
| `vm/tests.zig` | 3,259 to 3,575 | `ztcl::vm`. |
| `isolate/tests.zig` | 3,576 to the end | Isolated threads. |

### `cmds.zig` (2,947 lines)

| New file | Lines today | Commands |
|---|---|---|
| `cmds/cmds.zig` | 1 to 110 | The registration of the core commands. |
| `cmds/var.zig` | 111 to 284 | `set`, `unset`, `incr`, `append`, `global`, `variable`, `upvar`, `uplevel`. |
| `cmds/control.zig` | 285 to 561 | `if`, `while`, `for`, `foreach`, `lfilter`, `break`, `continue`, `switch`. |
| `cmds/proc.zig` | 562 to 1,313 | `proc`, `apply`, `rename`, `return`, `error`, `throw`, `catch`, `try`, `expr`, `eval`, `subst`. |
| `cmds/list.zig` | 1,314 to 1,756 | `list`, `lindex`, `llength`, `lappend`, `lrange`, `lreverse`, `linsert`, `lreplace`, `lassign`, `lrepeat`, `lsearch`, `join`, `split`, `concat`, with `lset` and `lsort` of `more.zig`. |
| `cmds/string.zig` | 1,757 to 2,630 | `string` and its subcommands. |
| `cmds/info.zig` | 2,631 to the end | `info`, `puts`, and `noise3`. |

`more.zig` then has only `binary` and `scan`, and becomes `cmds/binary.zig`. `extra.zig` has `array`, `case`, and `tcl::prefix`, and goes to `cmds/array.zig` and `cmds/prefix.zig`.

### `vm.zig` (2,655 lines)

The file moves to `core/bytecode/` and splits:

| New file | Lines today | Concern |
|---|---|---|
| `core/bytecode/code.zig` | 1 to 187 | `Op`, `Range`, and `Code`. |
| `core/bytecode/guard.zig` | 188 to 243 | The guard of a compiled body. |
| `core/bytecode/compile.zig` | 244 to 1,413 | The compiler. |
| `core/bytecode/exec.zig` | 1,414 to 1,735 | The executor. |
| `core/bytecode/ops.zig` | 1,736 to the end | The instructions. |

## Names

- A file name is a noun in snake case for the one thing that the file owns, such as `bytecode.zig` or `list.zig`. Do not use general names such as `more.zig` and `extra.zig`, or a name of another area, such as `vm.zig` for the bytecode.
- In a folder, the root file has the name of the folder, as `aio/aio.zig` has, and the command file of a module is `cmd.zig`. Outside a folder, a command file is `NAMEcmd.zig` today. After the moves, it is `NAME/cmd.zig`.
- An OS form has one of these suffixes: `_linux`, `_macos`, `_windows`, `_wasi`, `_wasi3`. `_posix` is the form for Linux and macOS. Today `pty_mac.zig` and `isolate_mac.zig` use `_mac`. The moves rename them to `_macos`.
- A test file is `NAME_tests.zig`. Today `h2/conn_test.zig` and `h2/hpack_test.zig` use `_test`. The moves rename them.
- A file name does not repeat the name of its folder: use `vm/fetch.zig` in place of `vm/vmfetch.zig`.

## Where a new feature goes

| Feature | Folder |
|---|---|
| A command of Tcl 8.6 or 9.1 with no host access | `cmds/`, in the file of its family |
| A change to the parser, values, bytecode, or the JIT | `core/` |
| A capability that reaches the host | `os/`, with its interface file and one `_OS` file for each platform |
| A new platform form of the event loop, sockets, or processes | `sys/` |
| A protocol, a format, or a codec with no Tcl | `stdlib/NAME/` |
| The `ztcl::` commands of a battery | `stdlib/NAME/cmd.zig`, with its page in `docs/modules/` |
| A device, a monitor, or a guest feature of `ztcl::vm` | `vm/` |
| A slot of the C API or of libztcl | `cext/` |
| A command or a file of the WebAssembly library | `wasm/` |
| A probe, a debugger feature, or an MCP tool | `debug/` |
| A subcommand of the `ztcl` program | `cli/` |
| A test | the module's own `test` blocks or `NAME_tests.zig` beside it |

Add the file to `tools/modmap.areas` and check the section `layers` of the report before the PR.

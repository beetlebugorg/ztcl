# Module ztcl::wasm

`ztcl::wasm` runs WebAssembly modules inside ztcl. A program in C, Rust, Zig, Go (TinyGo), AssemblyScript, or another language that compiles to wasm runs in the sandbox and the limits of the interpreter. The engine is part of ztcl: a validating decoder of the binary format and an interpreter, written in Zig from the WebAssembly specification. [Design](../dev/wasm-engine.md) has the plan and its state.

> [!NOTE]
> `ztcl::wasm` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

The module needs no capability for a module that has only its own imports. A module reaches only its linear memory and the imports that the script gives it. `ztcl::wasm load` reads a file, so it needs the capability `file`. The WASI imports follow the capabilities of the interpreter: see [WASI](#wasi).

The engine reads core WebAssembly 2.0: multi-value, bulk memory, reference types, sign extension, and the non-trapping float to int conversions. It also reads the extended constant expressions. It does not read SIMD, threads, exceptions, tail calls, multiple memories, or memory64 yet. The engine passes the 27,412 binary tests of the spec test suite of WebAssembly 2.0.

The module is in the native `ztcl` programs. It is not in `ztcl.wasm`. The build flag `-Dmod-wasmrt=false` leaves it out.

## An example

The bytes below are a module with one function `add` of two `i32` values. A module from a compiler is a file, for `ztcl::wasm load`.

<!-- run -->
```tcl
package require ztcl::wasm
set bytes [binary decode hex 0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b]
set m [ztcl::wasm new $bytes]
set w [ztcl::wasm instantiate $m]
puts [ztcl::wasm call $w add 40 2]
puts [ztcl::wasm exports $m]
```

```text
42
add func {{i32 i32} i32}
```

## Commands

| Command | What it does |
|---|---|
| `ztcl::wasm load fileName` | Reads, decodes, and validates a module file. Gives a module handle `wasmmodN`. Needs `file`. |
| `ztcl::wasm new bytes` | Decodes and validates the bytes of a module (a byte string, as from `binary decode`). Gives a module handle. |
| `ztcl::wasm instantiate module ?option value ...?` | Links the imports, runs the start function, and gives an instance handle `wasmN`. |
| `ztcl::wasm call instance function ?-limit units? ?-raw? ?--? ?arg ...?` | Calls an exported function. Gives the result, a list for more than one result, or an empty string for none. |
| `ztcl::wasm package fileName ?prefix? ?-wasi dict?` | Loads a Tcl C package built for `wasm32-wasi` with `libztclstubs.a`, and runs its init function `Prefix_Init`. Needs `file`. See [C packages](#c-packages). |
| `ztcl::wasm run module\|fileName ?option value ...?` | Runs a WASI command: instantiates it with the WASI imports, calls `_start`, and gives the exit code. |
| `ztcl::wasm memory instance size` | The size of the memory in pages of 65,536 bytes. |
| `ztcl::wasm memory instance grow pages` | Grows the memory. Gives the old size in pages, or -1. |
| `ztcl::wasm memory instance read address length` | The bytes at `address`, as a byte string. |
| `ztcl::wasm memory instance write address bytes ?-text?` | Writes a byte string at `address`. With `-text`, writes the UTF-8 bytes of a string. Gives the count of bytes. |
| `ztcl::wasm memory instance string address ?length?` | The UTF-8 text at `address`, up to a zero byte or `length` bytes. |
| `ztcl::wasm global instance name ?value?` | Reads an exported global, or sets a mutable one. |
| `ztcl::wasm exports module\|instance` | A list of name, kind, and type for each export. |
| `ztcl::wasm imports module` | A list of module, name, kind, and type for each import. |
| `ztcl::wasm info module` | A dict of counts and the features that the module uses. |
| `ztcl::wasm delete handle ?handle ...?` | Deletes modules and instances. |

The memory commands use the memory that the instance exports as `memory`, or its first memory.

### Options of instantiate

| Option | Value |
|---|---|
| `-imports dict` | For each import module, a dict of names and Tcl command prefixes. A call of the import calls the prefix with the arguments as Tcl values. The result of the command is the result of the import. |
| `-link dict` | For each import module, an instance handle. An import gets the export of the same name from the instance: a function, a table, a memory, or a global. |
| `-wasi dict` | Gives the module the imports of WASI preview 1. The keys are `args` (a list), `env` (a dict), `dirs` (a dict of guest names and paths), and `stdin` (text). |
| `-command name` | Makes a command `name function ?arg ...?` that calls the exports. |
| `-limit units` | The most compute units for the start function. |

A module that imports from `wasi_snapshot_preview1` and exports `_initialize` (a WASI reactor) runs `_initialize` after the instantiation.

## Values

| Type | Tcl value |
|---|---|
| `i32` | An integer from -2147483648 to 4294967295. A result is signed. |
| `i64` | An integer. A result is signed. |
| `f32`, `f64` | A floating-point number. |
| `externref` | An integer, or an empty string for null. |
| `funcref` | The address of a function in the store, or an empty string for null. |

With `-raw`, `call` reads and gives each value as the unsigned integer of its bits: an `f64` is its 64 bits. Use it for the exact bits of a NaN.

## Host functions

An import of `-imports` is a Tcl command. Wasm code can call Tcl code with it, and that code can call the instance again.

<!-- run -->
```tcl
package require ztcl::wasm
# (import "env" "log" (func (param i32))) and an export "run" that calls it with 7.
set bytes [binary decode hex 0061736d0100000001080260017f00600000020b0103656e76036c6f670000030201010707010372756e00010a08010600410710000b]
set m [ztcl::wasm new $bytes]
proc log {x} { puts "log $x" }
set w [ztcl::wasm instantiate $m -imports {env {log log}}]
ztcl::wasm call $w run
```

```text
log 7
```

## Limits

- **Compute.** Each call and each pass of a loop uses one compute unit of the interpreter, and a copy or a fill of memory or a table uses one unit for each 4,096 bytes or elements. A runaway loop of C code stops at the compute limit, as a Tcl loop does. `call -limit units` caps one call: the call then stops with the error `wasm trap: compute limit reached` (`ZTCL WASM LIMIT`), which `catch` can catch, and the units that the call used leave the limit of the interpreter.
- **Memory.** The bytes of the modules, the linear memories, the tables, and the stack of the engine count toward the memory limit of the interpreter. `memory.grow` gives -1 at the memory limit.
- **Stack.** The engine keeps its frames in its own memory, up to 20,000 frames and 1,048,576 values. A deeper recursion traps with `call stack exhausted`, and the host keeps running.

A trap gives the error `wasm trap: TEXT` with the error code `ZTCL WASM TRAP TEXT`. The texts are the texts of the spec tests, such as `integer divide by zero` and `out of bounds memory access`.

## C packages

A Tcl package in C builds for WebAssembly with the stub library of ztcl, as in [C packages](../dev/cext.md): `zig cc -target wasm32-wasi -mexec-model=reactor -DUSE_TCL_STUBS pkg.c libztclstubs.a` with the exports `ztcl_cext_*` and the init function. `ztcl::wasm package` loads it in the native ztcl: the commands of the package are commands of the interpreter, and the package runs in the limits of the interpreter. The package gets the imports of WASI with no folder, unless `-wasi` gives one. The package of SQLite (`tclsqlite3.c`) loads this way.

```tcl
package require ztcl::wasm
ztcl::wasm package sqlite.wasm Sqlite3
sqlite3 db :memory:
db eval {create table t(a)}
```

## WASI

`ztcl::wasm run` and `instantiate -wasi` give a module the imports of WASI preview 1, so a plain `wasm32-wasi` program of C (`zig cc -target wasm32-wasi`), Zig, Rust, or TinyGo (`-target=wasip1`) runs. Each import goes through the capabilities of the interpreter:

| WASI | ztcl |
|---|---|
| Arguments and environment | Only the values of `args` and `env`. The first argument of `run` is the name of the module. |
| Standard output and error | `puts -nonewline stdout` and `stderr`, so the output goes to the channel or to the callback of the embedder. |
| Standard input | The text of `stdin`, then the end of the file. |
| Files | Each pair of `dirs` is a preopened folder: the guest name and a path of ztcl. It needs the capability `file`. The folder is inside the root folder of the jail, or a host path in host mode. A guest path stays inside its folder: `..` above the folder gives `ENOTCAPABLE`. |
| Clocks | `clock_time_get` needs the capability `clock`. Without it, the call gives `ENOTCAPABLE`. |
| Random bytes | `random_get` needs the capability `random`. |
| `poll_oneoff` | A clock subscription is due at once: the engine does not sleep. |
| Sockets, links, and symlinks | `ENOTSUP`. |

Each call of a WASI function uses one compute unit.

```tcl
package require ztcl::wasm
# A C program, built with: zig cc -target wasm32-wasi -O2 hello.c -o hello.wasm
set code [ztcl::wasm run hello.wasm -args {a b} -env {WHO me} -dirs {. .}]
```

# Targets

This page lists each target of ztcl. For each target it gives what `ztcl build` makes, the JIT, the features that differ, the known limits, and how CI checks it. `tests/targets.sh` checks that the page lists each target of `zig build runtimes` and each target with a JIT.

## The native targets

`ztcl build --target TARGET` copies the runtime of the target and adds the payload. [Build a program](build.md) tells how. Each host builds the binary of each target, with no Zig toolchain. The sizes are the runtimes of `zig build runtimes` on main, on 2026-11-26.

| Target | Runtime | JIT | `coroutine` | `exec` and `ztcl::pty` | `ztcl::watch` |
|---|---|---|---|---|---|
| `x86_64-linux` | 2,494,256 bytes | tier 1 and tier 2 | yes | yes | yes |
| `aarch64-linux` | 2,014,696 bytes | no | no | yes | yes |
| `x86_64-macos` | 2,292,412 bytes | no | no | yes | no |
| `aarch64-macos` | 2,256,584 bytes | tier 1 and tier 2 | yes | yes | no |
| `x86_64-windows` | 2,691,584 bytes | no | yes | yes | no |
| `aarch64-windows` | 2,144,256 bytes | no | no | no | no |

- **JIT**: tier 1 compiles the bytecode of a proc, and tier 2 compiles a hot loop. [The JIT](jit.md) has the details. On a target with no JIT, `--jit` has no effect, and `enableJit` returns false. A binary of `ztcl build` has no machine code compiled at build time yet.
- **`coroutine`**: on a target with no coroutines, `coroutine` gives the error `coroutine is not available on this target`.
- **`exec` and `ztcl::pty`**: [Run programs](processes.md) and [ztcl::pty](modules/pty.md) list the differences of Linux, macOS, and Windows.
- **`ztcl::watch`**: on macOS and Windows, `add` gives the error `ZTCL WATCH UNAVAILABLE`.
- **`ztcl::open` and `ztcl::notify`**: these modules use the system on macOS and Windows, and on Linux they need a host callback. [ztcl::open](modules/open.md) and [ztcl::notify](modules/notify.md) have the tables.
- **arm64 Windows**: the system layer of ztcl (`src/sys.zig`) has no port to arm64 Windows yet, so `exec` and `ztcl::pty` are absent there.

### Signing

A binary for macOS has an ad hoc code signature from `ztcl build`. A binary for Windows has no signature. [Build a program](build.md#macos-and-windows) has the commands for a release signature.

## WebAssembly

| Build | What it is | JIT | `coroutine` | Host commands |
|---|---|---|---|---|
| `ztcl.wasm` | The library for the browser and Node.js | no | no | none |
| `ztcl-threads.wasm` | The library with shared threads | no | no | none |
| `ztcl-shell.wasm` | The library with the shell, for this site | no | no | none |
| `ztcl-host.wasm` | The library with `clock` and `dom`, which the page turns on | no | no | `clock` and `dom` after a call of the page |
| `wasm32-wasi` | The runner for a WASI runtime | no | no | files in the folders of the runtime |

- WebAssembly has no JIT and no coroutines. [WebAssembly](webassembly.md) lists the commands of each build.
- `ztcl-threads.wasm` has no `ztcl::vt`.
- `ztcl build` has no WebAssembly target. A program for the web uses `ztcl.wasm` and its scripts.

## How CI checks each target

| Target | Each pull request | The full run, every 6 hours on main |
|---|---|---|
| `x86_64-linux` | the unit tests, the Tcl suite, `ztcl build` and a run of the binary | the same |
| `aarch64-linux` | `ztcl build` from Linux, and a run under qemu | the same |
| `x86_64-macos` | `ztcl build` from Linux, with no run | the unit tests on an Intel Mac |
| `aarch64-macos` | `ztcl build` from Linux, with no run | the unit tests, the JIT tests, and `ztcl build` with a run and the signature |
| `x86_64-windows` | `ztcl build` from Linux, with no run | the unit tests, and `ztcl build` with a run |
| `aarch64-windows` | `ztcl build` from Linux, with no run | not checked |
| WebAssembly | the tests of `ztcl.wasm`, `ztcl-shell.wasm`, and `ztcl-host.wasm` in Node.js | the same |
| `wasm32-wasi` | the build, and a smoke test in wasmtime | the same |

## Later targets

- riscv64 (issue #8) and the AVR targets for microcontrollers (issue #9) are plans. They have no runtime yet.

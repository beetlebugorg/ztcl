# Targets

This page lists each target of ztcl. For each target it gives what `ztcl build` makes, the JIT, the features that differ, the known limits, and how CI checks it. `tests/targets.sh` checks that the page lists each target of `zig build runtimes` and each target with a JIT.

## The native targets

`ztcl build --target TARGET` copies the runtime of the target and adds the payload. [Build a program](build.md) tells how. Each host builds the binary of each target, with no Zig toolchain. The sizes are the runtimes of `zig build runtimes` on main, on 2026-11-26.

| Target | Runtime | JIT | `coroutine` | `exec` and `ztcl::pty` | `ztcl::watch` |
|---|---|---|---|---|---|
| `x86_64-linux` | 2,494,256 bytes | tier 1 and tier 2 | yes | yes | yes |
| `aarch64-linux` | 2,014,696 bytes | tier 1 and tier 2 | no | yes | yes |
| `x86_64-macos` | 2,292,412 bytes | no | no | yes | no |
| `aarch64-macos` | 2,256,584 bytes | tier 1 and tier 2 | yes | yes | no |
| `x86_64-windows` | 2,691,584 bytes | tier 1 and tier 2 | yes | yes | yes |
| `aarch64-windows` | 2,144,256 bytes | no | no | no | no |

- **JIT**: tier 1 compiles the bytecode of a proc, and tier 2 compiles a hot loop. [The JIT](jit.md) has the details. The JIT is on by default. On a target with no JIT, `--no-jit` has no effect, and `enableJit` returns false. A binary of `ztcl build` has no machine code compiled at build time yet. See "Code compiled ahead of time" below.
- **`coroutine`**: on a target with no coroutines, `coroutine` gives the error `coroutine is not available on this target`.
- **`exec` and `ztcl::pty`**: [Run programs](processes.md) and [ztcl::pty](modules/pty.md) list the differences of Linux, macOS, and Windows.
- **`ztcl::watch`**: Linux has inotify and x86-64 Windows has `ReadDirectoryChangesW`. On macOS, `add` gives the error `ZTCL WATCH UNAVAILABLE`. [ztcl::watch](modules/watch.md#platforms) has the details.
- **Isolated threads**: the level `process` of `thread::create -isolation` runs on Linux, macOS, and Windows. [Isolated threads](isolation.md) has the sandbox of each system.
- **The JIT on x86-64 Windows**: the machine code is the code of x86-64 Linux, and each call between Zig and that code uses the System V ABI, so the machine code keeps one calling convention. The region registers each function in a growable function table, so an exception and a debugger walk through JIT frames.
- **`ztcl::open` and `ztcl::notify`**: these modules use the system on macOS and Windows, and on Linux they need a host callback. [ztcl::open](modules/open.md) and [ztcl::notify](modules/notify.md) have the tables.
- **arm64 Windows**: the system layer of ztcl (`src/sys.zig`) has no port to arm64 Windows yet, so `exec` and `ztcl::pty` are absent there.

### Signing

A binary for macOS has an ad hoc code signature from `ztcl build`. A binary for Windows has no signature. [Build a program](build.md#macos-and-windows) has the commands for a release signature.

## Code compiled ahead of time

| Target | State | Limits |
|---|---|---|
| `wasm32` | `ztcl compile --wasm` compiles the procs of a script into a module. [WebAssembly](webassembly.md#compile-procs-to-webassembly) tells how. | A proc that a script makes from a computed string runs in the interpreter. Coroutines are not in the WebAssembly build. |
| `x86_64-linux` | Planned: tier 1 code in the binary of `ztcl build --aot` (issue [#40](https://github.com/beetlebugorg/ztcl/issues/40)) | |
| `aarch64-linux`, `aarch64-macos`, `x86_64-windows` | Planned after `x86_64-linux` | |
| `avr` (ATmega2560), then Cortex-M and 32-bit RISC-V | Planned: `ztcl aot` for firmware (issue [#9](https://github.com/beetlebugorg/ztcl/issues/9)) | The ATmega2560 has 8 KB of RAM and no FPU, so the plan has small ints and soft floats. A board has no `exec`, files, or sockets unless the firmware gives them. |

The output, the errors, and the count of compute units of compiled code are the same as in the interpreter.

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
| `aarch64-linux` | `ztcl build` from Linux, and a run under qemu. On an arm64 Linux runner: the unit tests, `tools/jit-diff.sh`, and the JIT fuzzer | the same |
| `x86_64-macos` | `ztcl build` from Linux, with no run | the unit tests on an Intel Mac |
| `aarch64-macos` | `ztcl build` from Linux, with no run | the unit tests, the JIT tests, and `ztcl build` with a run and the signature |
| `x86_64-windows` | `ztcl build` from Linux, with no run | the unit tests, and `ztcl build` with a run |
| `aarch64-windows` | `ztcl build` from Linux, with no run | not checked |
| WebAssembly | the tests of `ztcl.wasm`, `ztcl-shell.wasm`, and `ztcl-host.wasm` in Node.js | the same |
| `wasm32-wasi` | the build, and a smoke test in wasmtime | the same |

## Later targets

- riscv64 (issue #8) and the AVR targets for microcontrollers (issue #9) are plans. They have no runtime yet.

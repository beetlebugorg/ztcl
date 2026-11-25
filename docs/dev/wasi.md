# WASI

This is the plan for [issue 2](https://github.com/beetlebugorg/ztcl/issues/2). The goal is the newest WASI that has shipped, WASI 0.3.2, and the component model. The `ztcl` program ships as a WASI command component, and the library ships as a component with its own WIT world. [The tasks](wasi-tasks/README.md) give the order.

## The WASI version

The plan pins WASI 0.3.2, the latest release of the WASI subgroup (13 October 2026). WASI 0.3.0 shipped on 11 June 2026, and 0.3.1 on 11 August 2026. The first form of this plan targeted WASI 0.2. These are the changes from 0.2 that the plan follows:

- **Native async.** The component model has `async func`, `stream<T>`, and `future<T>` as types of the canonical ABI. A core module uses built-in functions for waitable sets, streams, futures, task return, and subtasks. Task 04 writes this layer.
- **No `wasi:io`.** The package is removed. A `pollable` is a `future`, an `input-stream` and an `output-stream` are a `stream<u8>`, `poll` is a wait on a waitable set, and a pair `start-foo` and `finish-foo` is one `async func`.
- **The interfaces.** `wasi:cli` gives stdin, stdout, and stderr as `stream<u8>`, and `run` is an `async func`. `wasi:clocks` has the types `system-clock` and `instant`, with `wait-for` and `wait-until`. Most `descriptor` methods of `wasi:filesystem` are `async func`. `wasi:random` renames `len` to `max-len`. `wasi:sockets` has two interfaces, `types` and `ip-name-lookup`, in place of seven. 0.3.1 adds the type `map<K, V>`. 0.3.2 publishes the specification of 0.3.1 and changes no interface that ztcl uses.
- **Runtimes.** Wasmtime 46 is the first release with the final WASI 0.3.0, on by default with the async feature of the component model. Wasmtime 41 to 45 have release candidates and cannot run a component of 0.3.0. jco supports WASI 0.3 for JavaScript. Task 04 checks that the pinned wasmtime accepts imports at `@0.3.2`.
- **Tools.** `wasm-tools component embed` and `component new` make the component. Task 04 pins the version that validates the async built-ins.
- **No adapter step.** The adapter of preview 1 makes a 0.2 component, so the plan has no adapter task. Preview 1 stays only as the first build of the interpreter under wasmtime (tasks 01 to 03).

## The state on main

Measured on Zig 0.16.0, wasmtime 50.0.0, and wasm-tools 1.261.0, for the first form of this plan. Task 04 measures the 0.3 tooling again:

- `zig build -Dtarget=wasm32-wasi` fails with 2 errors. The compiler stops after these 2, so more errors can follow.
  - `src/sys.zig:127` calls `std.os.linux.poll`. `std/os/linux.zig` has no system calls for wasm32 and gives a compile error.
  - `src/main.zig:413` puts a `u64` in `mem_limit`, a `usize`. On wasm32, `usize` has 32 bits.
- Eight source files call `std.os.linux` directly: `sys.zig`, `fsroot.zig`, `proc.zig`, `chan.zig`, `filecmd.zig`, `child.zig`, `thread.zig`, and `interp.zig` (one call).
- The Zig standard library has preview 1 bindings in `std/os/wasi.zig`. It has no bindings for preview 2 or WASI 0.3. Zig has one OS tag, `wasi`, for both previews.
- `wasm-tools component new` needs the preview 1 adapter module of wasmtime for a preview 1 core module, and the adapter makes a WASI 0.2 component. The plan does not use it.

## The two steps

1. **Preview 1.** The core module imports `wasi_snapshot_preview1` through `std.os.wasi`. This step proves the build, the capabilities, the suite under wasmtime, and CI. Wasmtime runs a preview 1 core module with no component.
2. **WASI 0.3.** The core module imports the WASI 0.3.2 interfaces directly, with the names of the canonical ABI (`wasi:filesystem/types@0.3.2`), and the async built-ins of task 04. A small generator writes the `extern` declarations from the WIT files. `wasm-tools component embed` and `wasm-tools component new` make the component.

Zig has no OS tag for WASI 0.3, so the build is still `-Dtarget=wasm32-wasi`. A build option `-Dwasi=p1|p3` picks the imports. The default becomes `p3` at task 06.

The interpreter runs a script to its end on one task. The event loop of `vwait`, `after`, and `fileevent` is a wait on a waitable set of the futures and the streams that the script uses.

## The capabilities

Each capability stays off by default, as on the other targets (AGENTS.md rule 3). The runner turns them on from its flags, as on Linux.

| Capability | Preview 1 | WASI 0.3.2 |
|---|---|---|
| `puts`, stdin channel | `fd_write`, `fd_read` on 0 to 2 | `stream<u8>` of `wasi:cli/stdout`, `stdin`, `stderr` |
| args, `env` | `args_get`, `environ_get` | `wasi:cli/environment` |
| `clock`, `after` | `clock_time_get` | `wasi:clocks` (`system-clock`, `instant`, `wait-for`) |
| `random` | `random_get` | `wasi:random/random` |
| `file`, channels | `path_open` under a preopen | `wasi:filesystem/types` (async methods), `preopens` |
| event loop | `poll_oneoff` | a waitable set of futures and streams |
| `socket` | none | `wasi:sockets/types`, `ip-name-lookup` |
| `exec` | none | none |

### Files and the root folder

The root folder jail maps to one preopened directory. The runner gives `--root DIR`, and the host preopens DIR (for wasmtime: `--dir DIR::/`). `fsroot` opens each path relative to the descriptor of that preopen, with the same checks as on Linux: no `..` above the root, and no symlink that leaves it. WASI also limits paths to the preopen, so there are two checks. The ztcl check stays the one that the tests prove.

### Sockets

`socket` goes through the network policy of the embedder. `sys.resolve` is the only name lookup, and it uses `wasi:sockets/ip-name-lookup`. The policy check runs on each resolved address, on the address of each connection, and on each peer of a server. The tests use only loopback addresses. Issue 2 points to a rule in `docs/ports.md`. That file is not on main, so the rule of AGENTS.md rule 3 applies.

### exec

`exec` stays off. WASI has no process interface. The command is absent, and a test proves it.

## The collector, coroutines, and threads

- The WASI build uses the same collector options as `zig build wasm`.
- `coroutine` is present and gives an error, as in the browser build. A design for wasm coroutines is separate work.
- `thread` is absent. `thread.supported` is false for wasm today. [Threads task 14](../threads-tasks/14-wasm-workers.md) adds Web Workers for the browser library only. WASI 0.3 adds async concurrency on one thread, and no thread interface. wasi-threads is a preview 1 proposal. The WASI build keeps the `thread` command absent until a WASI thread interface is stable. A test proves the absence.

## The component for embedders

A WIT world `ztcl:embed/interp` exports these functions:

- `new(limits) -> interp`: a resource with the step limit and the memory limit.
- `eval(interp, script) -> result<string, error>`: the error has the code, the message, and `errorInfo`.
- `call(interp, list<string>) -> result<string, error>`.

The world imports `host-command: async func(name, list<string>) -> result<string, string>`, so a host can do work of its own before it answers. The embedder lists the names of its commands at `new`. Each capability import (files, clocks, sockets) is in the world only when the embedder build turns it on.

## Tests and CI

- `tools/wasi-run.sh` runs `zig-out/bin/ztcl.wasm` under wasmtime with the root folder as a preopen. `tools/suite.sh -r tools/wasi-run.sh` runs the Tcl suite under WASI.
- A CI job installs a pinned wasmtime release with a SHA-256 check, builds with `-Dtarget=wasm32-wasi`, runs the smoke tests, and runs the core suite.
- The last task runs the suite under a second component runtime and publishes both counts.

## Decisions for the user

The open questions are in [the task list](wasi-tasks/README.md#questions-for-the-user).

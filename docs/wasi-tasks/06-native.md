# Task 06: native WASI 0.3 for the CLI, clocks, random, and files

Platform: shared/wasi.

## Goal

With `-Dwasi=p3`, the core module imports only WASI 0.3.2 functions. `zig build wasi-component` makes the command component with `wasm-tools component embed` and `wasm-tools component new`, with no adapter. The default of `-Dwasi` becomes `p3`.

## Files

- `src/sys_wasi.zig`, `src/fsroot_wasi.zig`: a 0.3 form of each function on `src/wasi/p3.zig`. Standard input, output, and error are `stream<u8>` of `wasi:cli`. Files use the `descriptor` methods of `wasi:filesystem/types`, which are `async func` in 0.3, and `wasi:filesystem/preopens`. The clocks are `wasi:clocks` (`system-clock`, `instant`, `wait-for`, `wait-until`), and random is `wasi:random`.
- `src/main.zig`: the export `wasi:cli/run#run` in the form that task 04 measured. Args and env come from `wasi:cli/environment`.
- `build.zig`: the option `-Dwasi=p1|p3`, and the component step for p3.

## Rules

- The event loop waits on a waitable set: the futures and the streams of the channels and the timers of `wait-for`. WASI 0.3 has no `pollable` and no `wasi:io/poll`.
- Each handle (a resource, a stream end, a future end, a subtask) is dropped on each path, also on an error.

## Acceptance

```sh
CAP zig build wasi-component
wasm-tools component wit zig-out/bin/ztcl.component.wasm | grep -c wasi_snapshot_preview1   # 0
wasm-tools component wit zig-out/bin/ztcl.component.wasm | grep -c '@0.2'                     # 0
CAP tools/wasi-smoke.sh --component
CAP tools/suite.sh -t core-8-6-16 -r 'tools/wasi-run.sh --component'
```

Gate: each suite file passes at least the count of task 03.

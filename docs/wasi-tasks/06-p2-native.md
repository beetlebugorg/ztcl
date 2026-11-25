# Task 06: native preview 2 for the CLI, clocks, random, and files

Platform: shared/wasi.

## Goal

With `-Dwasi=p2`, the core module imports only WASI 0.2 functions. `zig build wasi-component` makes the component with `wasm-tools component embed` and `wasm-tools component new`, with no adapter. The default of `-Dwasi` becomes `p2`.

## Files

- `src/sys_wasi.zig`, `src/fsroot_wasi.zig`: a p2 form of each function on `src/wasi/p2.zig`: streams of `wasi:cli`, `wasi:filesystem/types` descriptors, `wasi:filesystem/preopens`, the clocks, and `wasi:random`.
- `src/main.zig`: the entry `wasi:cli/run#run` for p2. Args and env come from `wasi:cli/environment`.
- `build.zig`: the option `-Dwasi=p1|p2`, and the component step for p2.
- `tools/wasi-adapter.sh`: removed.

## Rules

- The event loop uses `wasi:io/poll` on the pollables of the streams and the monotonic clock.
- A resource handle is closed with its `drop` function on each path, also on an error.

## Acceptance

```sh
CAP zig build wasi-component
wasm-tools component wit zig-out/bin/ztcl.component.wasm | grep -c wasi_snapshot_preview1   # 0
CAP tools/wasi-smoke.sh --component
CAP tools/suite.sh -t core-8-6-16 -r 'tools/wasi-run.sh --component'
```

Gate: each suite file passes at least the count of task 03.

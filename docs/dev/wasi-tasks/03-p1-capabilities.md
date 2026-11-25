# Task 03: files, clock, random, env, and the event loop on preview 1

Platform: shared/wasi.

## Goal

The runner turns on `file`, channels, `clock`, `random`, `env`, and the event loop (`after`, `vwait`, `update`, `fileevent`) with the same `--allow` flags as on Linux. Each one uses preview 1 imports.

## Files

- `src/sys_wasi.zig`: the functions of `sys.zig` for WASI: `read`, `write`, `close`, `setBlocking`, `poll` (on `poll_oneoff`), and `seek`. `listenAt`, `connectTo`, `accept`, and `resolve` give `ENOTSUP`.
- `src/fsroot_wasi.zig`: the root folder on the descriptor of a preopen. Each path opens relative to that descriptor with the checks of `fsroot.zig`: no `..` above the root, and no symlink that leaves it.
- `src/sys.zig`, `src/fsroot.zig`: one hunk each that picks the WASI file on the WASI target.
- `src/main.zig`: `--root DIR` finds the preopen with the name DIR, or `/`.

## Rules

- `clock` reads `clock_time_get`. `random` reads `random_get`. With no capability on, scripts stay deterministic.
- The tests of the jail run under wasmtime: `..`, an absolute path, a symlink out of the root, and a rename out of the root each fail with the error text of Linux.

## Acceptance

```sh
CAP zig build -Dtarget=wasm32-wasi
CAP tools/wasi-smoke.sh
CAP tools/suite.sh -t core-8-6-16 -r tools/wasi-run.sh
```

Gate: each suite file under WASI passes at least the count of task 02. Report the new total, and the count of each file that is lower than the native count with the cause.

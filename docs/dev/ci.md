# CI times

This file records the wall times of the CI workflow (`.github/workflows/ci.yml`) for pull requests, before and after each change of issue #270. The wall time of a pull request is the time from the start of the run to the end of its last job. The slowest job sets it.

## Before (2026-11-26)

Runs of three pull requests on main at 346dc5c, in minutes:

| Job | iso-thread-fixes (code) | perf-ideas (docs and tools) | wasi-06-native (wasm) |
|---|---|---|---|
| WebAssembly | 13.1 | 13.5 | 10.8 |
| ztcl build (ubuntu-latest) | 5.5 | 6.2 | 4.9 |
| C packages (Linux) | 3.1 | 3.4 | 4.7 |
| Test (ubuntu-latest) | 3.9 | 4.0 | 3.3 |
| Tcl 8.6.16 suite | 2.0 | 4.1 | 3.7 |
| WASI | 2.0 | 2.1 | 1.9 |
| docs | 1.5 | 1.3 | 1.1 |
| Run wall time | 13.9 | 17.0 | 13.4 |

The perf-ideas PR changed files in `tools/`, so all the code jobs ran.

The steps of the WebAssembly job in the iso-thread-fixes run, in seconds:

| Step | Time |
|---|---|
| `zig build wasm` | 112 |
| `zig build wasm-shell` | 23 |
| `zig build wasm-host` | 25 |
| `zig build enclave-core` | 15 |
| `zig build` (native) | 133 |
| Procs compiled to wasm (`zig build wasm-aot` and the checks) | 191 |
| Point procs compiled to wasm | 218 |
| `zig build wasm-threads` and its checks | 42 |

Facts from the logs of these runs:

- `mlugg/setup-zig` caches the Zig toolchain and the Zig cache today. It sets `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR` to `.zig-cache`, restores the cache of the last run of the same job, and saves a new cache at the end of each job. The WebAssembly job restored 263 MB.
- A change in `src/` changes the input of each artifact, so each artifact compiles again with a warm cache too. The cache helps the build runner and the artifacts that do not use the changed files.
- The Actions cache of the repository is at its limit of 10 GB (44 caches). Each pull request saves a cache for each job, and GitHub deletes the oldest caches first, so the caches of main go out after a few hours.
- The concurrency group was `ci-<ref>` with cancel-in-progress for each event. A push to main cancelled the run of the push before it, so its jobs saved no cache. The scheduled run of 2026-11-26 21:42 was cancelled in the same way.

## Changes

1. The WebAssembly job is three jobs that run at the same time: the libraries (`wasm`), the compiled procs (`wasm-aot`), and the point procs (`wasm-point`). Each job builds all of its steps with one `zig build`. A run on main or a scheduled run is no longer cancelled by a later push.

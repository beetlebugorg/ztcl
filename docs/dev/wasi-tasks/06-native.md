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
CAP tools/wasi-component.sh
CAP tools/suite.sh -t core-8-6-16 -r tools/wasi-run-component.sh
```

`tools/wasi-component.sh` is the smoke test of the component. `tools/suite.sh -r` reads the path of one program, so `tools/wasi-run-component.sh` runs `tools/wasi-run.sh --component`.

Gate: each suite file passes at least the count of task 03.

## Part 1: the command component on the CLI streams (2026-11-26)

- `src/wasi/run.zig` is the entry of the core module. It exports `wasi:cli/run@0.3.2#run` with the synchronous lift and `cabi_realloc`. Its declaration `ztcl_wasi_p3` makes `sys.zig` use `src/sys_wasi3.zig`. Its panic handler traps, and the debug `Io` of the standard library is `std.Io.failing`. With the default debug `Io`, the module imports 28 preview 1 functions from `std.Io.Threaded`, also for a script with no capability.
- `src/sys_wasi3.zig` writes descriptors 1 and 2 to the `stream<u8>` of `wasi:cli/stdout` and `stderr`, reads descriptor 0 from `wasi:cli/stdin`, reads the script file through `wasi:filesystem/preopens` and `open-at`, gets the arguments from `wasi:cli/environment`, and ends with `exit-with-code` of `wasi:cli/exit`.
- `zig build wasi-component` makes `zig-out/bin/ztcl.component.wasm` with the world `ztcl:cli/command`. The component imports only these 0.3.2 interfaces: `wasi:cli/environment`, `exit`, `types`, `stdout`, `stderr`, and `wasi:filesystem/types` and `preopens`. `tools/wasi-component.sh` runs its tests under wasmtime.
- Size: 2,318,185 bytes, 703,305 bytes with `gzip -9` (ReleaseFast, stripped). The time of a full `wasmtime run` of a script of one `puts` is 46 ms, the mean of 20 runs after one run that fills the compile cache, at a load average of 5.5.
- Not yet in part 1: the flags of `src/main.zig` (`--allow`, `--root`, the limits), the capabilities (`file`, channels, `clock`, `random`, `env`, the event loop), and the option `-Dwasi=p1|p3`. The runner of `src/main.zig` uses `std.process.Init` and `std.Io`, and on WASI both use preview 1. Part 2 gives the runner a host layer that `run.zig` can fill with WASI 0.3.2 functions, then the suite runs under `tools/wasi-run.sh --component`.

## Part 2: the flags of the runner and the capabilities (2026-11-27)

- `src/main.zig` has a `Host`: the arguments, the output and input, the read of a script file, the exit, a monotonic clock, and the hosts of `clock` and of the event loop. `runWith` fills it from `std.process.Init` and calls `runHost`. `runHost` reads the flags and runs the scripts. `src/wasi/run.zig` fills it with WASI 0.3.2 functions and calls the same `runHost`. So the component reads each flag of `ztcl`: `--allow`, `--root`, `--compute`, `--mem`, `--tclsh`, and the others. With no file, it reads commands from standard input. An error gives `file:line: message` on standard output and the exit code 1, as `ztcl` does. `--tclsh` gives `argv`, `exit`, and `errorInfo` on standard error. Part 1 gave them with no flag.
- Files and channels: a descriptor of 3 or more is a slot in `src/sys_wasi3.zig` with a `descriptor` resource and a position. A read opens `read-via-stream` at the position and drops it after one copy. A write gives a new stream to `write-via-stream`, or to `append-via-stream` in append mode, and waits for the future of the result. `seek` to the end reads the size from `stat`. `src/fsroot_wasi3.zig` is the jail of `fsroot.zig` on `open-at`, `stat-at`, `read-directory`, `create-directory-at`, `remove-directory-at`, `unlink-file-at`, and `rename-at`, with no symlink followed. `stat` gives the halves of `metadata-hash-at` (new in `tools/witgen/needed.txt`) as the inode and the device, because WASI 0.3.2 has no inode number.
- `clock` reads `wasi:clocks/system-clock`. The event loop reads `monotonic-clock` and sleeps with `wait-for`: the task waits for the subtask in the waitable set of `src/sys_wasi3.zig`. A channel read or write blocks the task until it ends, so `poll` marks each wanted descriptor as ready.
- `random` and `env` have no command yet, on each platform, so the component has no import for them.
- `-Dwasi=p3` with `-Dtarget=wasm32-wasi` makes `zig build` install `zig-out/bin/ztcl.component.wasm` in place of `ztcl.wasm`. The default stays `p1`, because the CI job of WASI builds `-Dtarget=wasm32-wasi` and tests the preview 1 module with `tools/wasi-smoke.sh`.
- Suite: `tools/suite.sh -t core-8-6-16 -r tools/wasi-run-component.sh` gives pass 19,890, fail 409, skip 533. The preview 1 module gives the same count for each of the 37 files.
- Size: 2,883,702 bytes, 865,465 bytes with `gzip -9`. Part 1 was 703,305 bytes gzip. The rest of the runner (the flags, the file commands, the channels, and the event loop) is the new code.

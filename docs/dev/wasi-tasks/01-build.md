# Task 01: `zig build -Dtarget=wasm32-wasi` on preview 1

Platform: shared/wasi.

## Goal

`zig build -Dtarget=wasm32-wasi` builds `zig-out/bin/ztcl.wasm`, the runner as a WASI preview 1 command. Under wasmtime, it runs a script from a file and from stdin, with args and `puts`. Each capability stays off in this task.

## Files

- `build.zig`: the WASI target builds the runner with the collector options of `zig build wasm`, the JIT off, and no thread code.
- `src/sys.zig`, `src/fsroot.zig`, `src/proc.zig`, `src/chan.zig`, `src/filecmd.zig`, `src/child.zig`, `src/thread.zig`, `src/interp.zig`: each direct use of `std.os.linux` goes behind the `supported` constant of its file, or behind a comptime check of the target. No body changes on Linux.
- `src/cli/main.zig`: the parse of `--thread-mem` and `--threads-mem` checks that the number fits in `usize`. The runner reads args, the script file, and stdin through `std.process.Init` and `std.Io`.

## Rules

- First list each compile error. The probe of the plan saw 2 (`sys.zig:127` and `main.zig:413`), and the compiler stops early, so more can follow. Put the full list in the PR body.
- A capability that has no WASI form yet is absent. Its command gives the same error as when the embedder did not turn it on.
- The compute limit, the memory limit, the nesting limit, and the native stack limit work as on Linux. `--compute` and `--max-mem` work.

## Acceptance

```sh
CAP zig build -Dtarget=wasm32-wasi
printf 'puts [expr {6*7}]\n' | timeout 10 wasmtime run zig-out/bin/ztcl.wasm         # 42
printf 'puts ok\n' > zig-out/t.tcl && timeout 10 wasmtime run --dir zig-out::/ zig-out/bin/ztcl.wasm /t.tcl   # ok
printf 'while 1 {}\n' | timeout 10 wasmtime run zig-out/bin/ztcl.wasm --compute 1000  # the compute limit error
```

## Must not change

The Linux, macOS, and Windows builds. The suite counts.

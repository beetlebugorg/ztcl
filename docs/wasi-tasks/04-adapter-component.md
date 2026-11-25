# Task 04: the first component with the adapter

Platform: shared/wasi.

## Goal

`zig build wasi-component` makes `zig-out/bin/ztcl.component.wasm` from the preview 1 module and the preview 1 adapter of the pinned wasmtime release. `wasmtime run` runs it as a WASI command.

## Files

- `build.zig`: the step `wasi-component`. It runs `wasm-tools component new zig-out/bin/ztcl.wasm --adapt wasi_snapshot_preview1=<adapter> -o ...`.
- `tools/wasi-adapter.sh`: downloads the command adapter of the pinned release into the cache, and checks its SHA-256.
- `tools/wasi-run.sh`: an option to run the component.

## Rules

- `wasm-tools` and the adapter are build tools of this step. The repository does not hold the adapter file.
- If the user declined the adapter (question 2), close this task with no code and go to task 05.

## Acceptance

```sh
CAP zig build wasi-component
wasm-tools validate --features component-model zig-out/bin/ztcl.component.wasm
wasm-tools component wit zig-out/bin/ztcl.component.wasm        # imports wasi:cli, wasi:filesystem, ...
CAP tools/wasi-smoke.sh --component
```

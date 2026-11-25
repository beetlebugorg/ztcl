# Task 04: the async canonical ABI of WASI 0.3

Platform: shared/wasi.

## Goal

ztcl has a small Zig layer for the async canonical ABI of the component model, as WASI 0.3 uses it: the built-in functions for waitable sets, `stream<T>`, `future<T>`, task return, and subtasks. A core module built on it, and made into a component with `wasm-tools component embed` and `component new`, runs under the pinned wasmtime and writes to stdout through `wasi:cli/stdout@0.3.2`.

## Files

- `src/wasi/async.zig`: `extern` declarations of the canonical built-ins that ztcl uses, imported from the component, and the Zig types of their results. The functions block the calling task where ztcl needs a blocking call: a write of a stream, a read of a stream, and the wait for a future.
- `tools/wasi-spike/`: the core module of the check: it creates a stream, gives its readable end to `write-via-stream`, writes a text, and waits for the future of the result.
- `build.zig`: the step `wasi-spike`.

## Rules

- First measure the form of the lift of the export `wasi:cli/run@0.3.2#run` and of the lowerings of the async imports that the pinned `wasm-tools` and wasmtime accept: a synchronous lift and lowering, or the async form with a callback. Record the result in `docs/wasi.md`. If neither form runs, stop and report.
- Pin the versions of `wasm-tools` and wasmtime, and check each download with SHA-256. Wasmtime 46 is the first release with the final WASI 0.3.0. Check that the pinned release accepts imports at `@0.3.2`. If it does not, report the newest 0.3.N that it accepts, and stop.
- Write the layer from the text of the canonical ABI of the component model (`CanonicalABI.md` and `Async.md`). Credit them in `docs/references/wasi.md`.

## Acceptance

```sh
CAP zig build wasi-spike
wasm-tools validate --features component-model,cm-async zig-out/bin/wasi-spike.component.wasm
wasm-tools component wit zig-out/bin/wasi-spike.component.wasm     # imports wasi:cli/stdout@0.3.2
timeout 10 wasmtime run zig-out/bin/wasi-spike.component.wasm       # prints the text
```

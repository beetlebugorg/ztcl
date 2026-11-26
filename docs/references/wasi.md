# References for WASI 0.3

[The plan](../dev/wasi.md) uses these sources. ztcl has no code of any of them.

## The canonical ABI of the component model

WebAssembly Community Group, the component model: `CanonicalABI.md` and `Async.md`.

**License:** Apache License 2.0.

**How ztcl uses it:** `src/wasi/async.zig` follows the built-ins of waitable sets, streams, and futures: the value `0xffffffff` of a copy that did not end at once, the event codes of `waitable-set.wait`, and the state and the count in the result of a copy. The legacy names of the core imports come from the measurements of task 04 with wasm-tools 1.261.0 and wasmtime 50.0.0.

## The WIT files of WASI 0.3.2

The WASI subgroup, release v0.3.2 (13 October 2026): `cli/wit/stdio.wit` and `cli/wit/run.wit`.

**License:** Apache License 2.0 with the LLVM exception.

**How ztcl uses it:** `tools/wasi-spike/wit/deps/cli/` has copies of the two files. The one change is the package line at the top of `run.wit`. `wasm-tools component embed` reads them to make the component of `zig build wasi-spike`.

# References for WASI 0.3

[The plan](../dev/wasi.md) uses these sources. ztcl has no code of any of them.

## The canonical ABI of the component model

WebAssembly Community Group, the component model: `CanonicalABI.md` and `Async.md`.

**License:** Apache License 2.0.

**How ztcl uses it:** `src/wasi/async.zig` follows the built-ins of waitable sets, streams, and futures: the value `0xffffffff` of a copy that did not end at once, the event codes of `waitable-set.wait`, and the state and the count in the result of a copy. The legacy names of the core imports come from the measurements of task 04 with wasm-tools 1.261.0 and wasmtime 50.0.0.

## The WIT files of WASI 0.3.2

The WASI subgroup, release v0.3.2 (13 October 2026): the `wit/` folders of the proposals `cli`, `clocks`, `random`, `filesystem`, and `sockets`.

**License:** the W3C Community Contributor License Agreement, as the `LICENSE.md` file of each proposal says. `licenses/wasi-W3C-CLA.md` is a copy of that file. A search of the release found no other license text for the WIT files.

**How ztcl uses it:** `wit/deps/` has unchanged copies of the WIT files of the five proposals. `tools/witgen/` reads them to write `src/wasi/p3.zig`, and `wasm-tools component embed` reads them to make the components. `tools/wasi-spike/wit/deps/cli/` has copies of `stdio.wit` and `run.wit` for `zig build wasi-spike`, with a package line at the top of `run.wit`.

## The lowering of the canonical ABI

WebAssembly Community Group, the component model: `CanonicalABI.md`, the sections on the size and the alignment of each type, flattening, and `canon lower`.

**License:** Apache License 2.0.

**How ztcl uses it:** `tools/witgen/witgen.zig` computes the size, the alignment, and the flat core types of each WIT type, joins the cases of a variant, and puts the parameters in memory past 16 flat values (4 for an async lowering) and the result in a return area past 1 flat value (always for an async lowering). The order of the built-ins of the streams and the futures of a function was checked with `wasm-tools component new` 1.261.0 on the component of `zig build wasi-bindings`.

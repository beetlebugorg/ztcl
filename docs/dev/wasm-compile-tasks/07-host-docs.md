# Task 07: the host example, the manifest fragment, and the docs

Platform: shared.

## Goal

An embedder can load a compiled point proc from the docs alone. `ztcl compile -manifest FILE` writes the fragment of the design.

## Files

- `examples/point-wasm/`: a Node.js host. It reads the custom section `ztcl.point`, maps the feature names, writes the columns, calls `run` with a compute limit, and reads the outputs.
- `src/main.zig`: one hunk: the option `-manifest FILE` of `compile`. The fragment has the ABI version, the export names, the columns, the feature names, the compute units of one block, `cap`, the memory size, and an empty list of imports.
- `docs/dev/wasm-compile.md`: the module ABI as a reference for hosts, and a section for zslice.
- `docs/webassembly.md`: a section "Compile a point proc".
- `docs/references/wasm-compile.md`: the sources.

## Acceptance

```sh
CAP zig build && zig-out/bin/ztcl compile tests/point/fuzzy.tcl -proc fuzzy -o zig-out/fuzzy.wasm -manifest zig-out/fuzzy.json
node examples/point-wasm/run.mjs zig-out/fuzzy.wasm
CAP tools/point-wasm-diff.sh
```

This task does not change zslice.

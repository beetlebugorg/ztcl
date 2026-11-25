# Task 05: the WIT files of WASI 0.3.2 and the bindings generator

Platform: shared.

## Goal

The repository has the WIT files of WASI 0.3.2, and a generator writes the Zig `extern` declarations of the canonical ABI for the functions that ztcl uses, with the async layer of task 04 for each `async func`, `stream<T>`, and `future<T>`.

## Files

- `wit/deps/`: the WIT packages `wasi:cli`, `wasi:clocks`, `wasi:random`, `wasi:filesystem`, and `wasi:sockets` at 0.3.2. WASI 0.3 has no `wasi:io` package. The license of the WIT files goes in `licenses/`.
- `wit/ztcl.wit`: the world `ztcl:cli/command` that the runner uses.
- `tools/witgen/`: a Zig program. It reads a list of the needed functions and writes `src/wasi/p3.zig`: one `extern "wasi:.../...@0.3.2"` declaration for each function, with the lowered parameters of the canonical ABI, the record layouts, and the handle types of each stream and future.
- `build.zig`: the step `witgen`, and a test that the checked-in `src/wasi/p3.zig` equals the output of the generator.

## Rules

- The generator handles only the WIT types that the list uses, also `map<K, V>` of 0.3.1 if the list needs it. It gives an error for any other type.
- Write the lowering from the canonical ABI text of the component model. Credit it in `docs/references/wasi.md`.

## Acceptance

```sh
CAP zig build witgen && git diff --exit-code src/wasi/p3.zig
CAP zig build test
wasm-tools component wit wit/       # parses
```

# Task 05: the WIT files and the bindings generator

Platform: shared.

## Goal

The repository has the WIT files of the pinned WASI 0.2 version, and a generator writes the Zig `extern` declarations of the canonical ABI for the functions that ztcl uses.

## Files

- `wit/deps/`: the WIT packages `wasi:cli`, `wasi:clocks`, `wasi:random`, `wasi:filesystem`, `wasi:io`, and `wasi:sockets` at the pinned version. The license of the WIT files goes in `licenses/`.
- `wit/ztcl.wit`: the world `ztcl:cli/command` that the runner uses.
- `tools/witgen/`: a Zig program. It reads a list of the needed functions and writes `src/wasi/p2.zig`: one `extern "wasi:.../...@0.2.N"` declaration for each function, with the lowered parameters of the canonical ABI, and the record layouts.
- `build.zig`: the step `witgen`, and a test that the checked-in `src/wasi/p2.zig` equals the output of the generator.

## Rules

- The generator handles only the WIT types that the list uses. It gives an error for any other type.
- Write the lowering from the canonical ABI text of the component model. Credit it in `docs/references/wasi.md`.

## Acceptance

```sh
CAP zig build witgen && git diff --exit-code src/wasi/p2.zig
CAP zig build test
wasm-tools component wit wit/       # parses
```

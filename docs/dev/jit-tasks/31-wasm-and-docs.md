# Task 31: WebAssembly and the port docs

## Goal

Prove that the WebAssembly build has no JIT code, and record the state of each target.

## Files

- `build.zig`, `src/jit.zig`, `docs/dev/jit.md` (the target table gets the measured state), `docs/embedding.md`, `README.md`.

## Rules

- The `wasm` step passes `jit = false`. `jit.built` is false for `wasm32`, and `enableJit` returns false.
- `src/wasm.zig` gets no new export.
- The docs say: WebAssembly runs the interpreter only, and has no collector (task 03).

## Acceptance

```sh
CAP zig build wasm && node tools/wasm-smoke.mjs
ls -l zig-out/lib/ztcl.wasm         # at most 1 % larger than before task 10
CAP zig build test
```

A test (`tools/wasm-smoke.mjs`) checks that the module has no export whose name has `jit`.

For each target of `docs/dev/jit.md`, the table has: tested or not, the machine, the date, and the result of `tools/jit-diff.sh`.

## Must not change

The exports of the WebAssembly module.

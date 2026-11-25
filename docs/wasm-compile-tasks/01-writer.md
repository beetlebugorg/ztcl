# Task 01: the wasm writer

Platform: shared.

## Goal

`src/wasm_out.zig` writes a WebAssembly binary module: the type, function, memory, global, export, code, and custom sections, with the instructions that the code generation needs.

## Files

- `src/wasm_out.zig`: LEB128, the section writer, a function body builder with locals, and the instructions: control (`block`, `loop`, `br`, `br_if`, `if`, `return`, `call`), locals and globals, `i32`, `i64`, and `f64` arithmetic and compares, loads and stores, and the SIMD subset of `f64x2` and `v128` (`load`, `store`, `splat`, `extract_lane`, `replace_lane`, arithmetic, compares, `bitselect`, `and`, `or`, `not`).
- `src/wasm_out.zig` also reads a module into its sections, for task 02.
- `tools/wasm-validate.sh`: runs `wasm-tools validate` on each module that the tests write to `zig-out/wasm-out/`.

## Rules

- The writer checks the type of each instruction against a small operand stack, and gives an error before it writes an invalid body.
- Golden tests: small modules with known bytes from the specification.

## Acceptance

```sh
CAP zig build test
CAP tools/wasm-validate.sh
node -e 'WebAssembly.compile(require("fs").readFileSync("zig-out/wasm-out/simd.wasm"))'
```

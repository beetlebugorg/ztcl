# References for the WebAssembly compiler of point procs

[The plan](../dev/wasm-compile.md) uses these sources. ztcl has no code of any of them.

## The binary format

WebAssembly Community Group, "WebAssembly Core Specification", version 2.0. https://webassembly.github.io/spec/core/

**License:** W3C Software and Document License.

**How ztcl uses it:** `src/wasm_out.zig` follows chapter 5 (binary format) for LEB128, the section order, the encoding of types, limits, globals, exports, code entries, and the opcodes, with the SIMD opcodes after the prefix 0xfd. The operand stack check of `Body` follows the validation algorithm of the appendix of chapter 3. The golden test of a small module follows the encoding of chapter 5, byte for byte.

## The JavaScript API

WebAssembly Community Group, "WebAssembly JavaScript Interface". https://webassembly.github.io/spec/js-api/

**License:** W3C Software and Document License.

**How ztcl uses it:** `examples/point-wasm/run.mjs` and the tools of `tools/point-wasm-*.mjs` read the custom section `ztcl.point` with `WebAssembly.Module.customSections` and pass a 64-bit compute limit to `run` as a `BigInt`, as the interface maps `i64`.

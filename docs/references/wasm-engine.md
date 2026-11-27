# References for the wasm engine of ztcl::wasm

[The plan](../dev/wasm-engine.md) uses these sources. ztcl has no code of any of them, and no code of another WebAssembly engine.

## The core specification

WebAssembly Community Group, "WebAssembly Core Specification", version 2.0. https://webassembly.github.io/spec/core/

**License:** W3C Software and Document License.

**How ztcl uses it:** `src/wasmrt/module.zig` follows chapter 5 (binary format) for the sections, LEB128, and the opcodes, and the validation algorithm of the appendix of chapter 3 for the operand stack and the control stack. `src/wasmrt/exec.zig` follows chapter 4 (execution) for the store, the instantiation, the traps, and the numeric operators, such as `fmin`, `fnearest`, and the truncations.

## The extended constant expressions

WebAssembly Community Group, "Extended Constant Expressions" proposal. https://github.com/WebAssembly/extended-const

**License:** W3C Software and Document License.

**How ztcl uses it:** a constant expression can have `i32` and `i64` `add`, `sub`, and `mul`.

## The spec test suite

WebAssembly Community Group, the tests of `test/core` at the tag `wg-2.0` of https://github.com/WebAssembly/spec.

**License:** Apache License 2.0.

**How ztcl uses it:** as data only. CI converts the `.wast` files with `wasm-tools json-from-wast`, and `src/wasmrt/spec_runner.zig` runs the commands. The repository has no copy of the tests.

## WASI preview 1

WebAssembly System Interface Subgroup, "WASI Preview 1" (`wasi_snapshot_preview1`), the witx documents of https://github.com/WebAssembly/WASI.

**License:** Apache License 2.0 with the LLVM exception.

**How ztcl uses it:** `src/wasmrt/wasi.zig` follows the documents for the names, the signatures, the errno values, and the layout of `fdstat`, `filestat`, `prestat`, `dirent`, `iovec`, `subscription`, and `event`.

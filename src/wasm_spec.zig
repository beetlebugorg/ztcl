//! The root of `zig build wasm-spec`: the runner of the spec tests of the
//! wasm engine is in `wasmrt/spec_runner.zig`. The root is in `src/` so
//! that the engine can import the JIT of `src/jit/`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

pub const main = @import("wasmrt/spec_runner.zig").main;

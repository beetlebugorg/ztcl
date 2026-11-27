//! The root of `zig build wasm-fuzz`, the differential fuzzer of the wasm
//! JIT in `wasmrt/fuzz.zig`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

pub const main = @import("wasmrt/fuzz.zig").main;

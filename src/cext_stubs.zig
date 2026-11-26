//! The root of the stubs library of C packages in WebAssembly
//! (`src/cext/wasm_stubs.zig`). The root is in `src/`, so the files of
//! the library can import `src/value.zig`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

pub const wasm_stubs = @import("cext/wasm_stubs.zig");

comptime {
    _ = wasm_stubs;
}

test {
    _ = wasm_stubs;
    _ = @import("cext/obj.zig");
}

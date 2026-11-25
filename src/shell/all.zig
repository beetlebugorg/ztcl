//! The tests of the interactive shell of the runner. `zig build test`
//! runs them with the tests of the interpreter.
//!
//! SPDX-License-Identifier: BSD-2-Clause

test {
    _ = @import("text.zig");
    _ = @import("keys.zig");
    _ = @import("history.zig");
    _ = @import("editor.zig");
    _ = @import("highlight.zig");
    _ = @import("render.zig");
}

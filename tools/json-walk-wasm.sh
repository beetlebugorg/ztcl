#!/bin/sh
# Makes src/json/walk_wasm.zig from src/json/walk.zig: the same file
# without the `align(hot_align)` of each function. Run it after each
# change to walk.zig. A unit test in src/json/tests.zig checks the copy.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sed 's/ align(hot_align)//' "$here/src/json/walk.zig" > "$here/src/json/walk_wasm.zig"

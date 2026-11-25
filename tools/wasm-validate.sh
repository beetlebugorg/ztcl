#!/bin/sh
# Runs `wasm-tools validate` on each module that the tests wrote to
# zig-out/wasm-out/. Run `zig build test` first.
#
#   tools/wasm-validate.sh
#
# SPDX-License-Identifier: BSD-2-Clause
set -eu
dir=zig-out/wasm-out
count=0
for f in "$dir"/*.wasm; do
  [ -e "$f" ] || { echo "no modules in $dir; run zig build test first" >&2; exit 1; }
  wasm-tools validate --features all "$f"
  count=$((count + 1))
done
echo "valid: $count modules"

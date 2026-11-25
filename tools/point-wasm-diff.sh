#!/bin/sh
# Compiles each fixed point proc of tests/point/ to a module with SIMD
# and to a scalar module, and compares each module with Program.run and
# point.runSlow (tools/point-wasm-diff.mjs).
#
#   tools/point-wasm-diff.sh
#
# Run it under the memory cap of AGENTS.md.
#
# SPDX-License-Identifier: BSD-2-Clause
set -eu
zig build
zig build point-rt
mkdir -p zig-out/point-wasm
status=0
for f in tests/point/*.tcl; do
  base=$(basename "$f" .tcl)
  proc=$(sed -n 's/^point proc \([A-Za-z0-9_]*\) .*/\1/p' "$f" | head -n 1)
  for simd in on off; do
    out=zig-out/point-wasm/$base-$simd.wasm
    zig-out/bin/ztcl compile "$f" -proc "$proc" -o "$out" -simd "$simd"
    wasm-tools validate "$out"
    node tools/point-wasm-diff.mjs "$f" "$proc" "$out" || status=1
  done
done
exit $status

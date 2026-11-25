#!/bin/sh
# Compiles each fixed point proc of tests/point/ to a module with SIMD
# and to a scalar module, and compares each module with Program.run and
# point.runSlow (tools/point-wasm-diff.mjs).
#
#   tools/point-wasm-diff.sh [--wasmtime]
#
# With --wasmtime, each module also runs in wasmtime: `run` through
# `wasmtime run --invoke` on the fixed input in memory (the zero bytes
# of a new instance) for 3000 points, and the script checks that the
# result is the step count of the custom section ztcl.point.
#
# Run it under the memory cap of AGENTS.md.
#
# SPDX-License-Identifier: BSD-2-Clause
set -eu
wasmtime=0
[ "${1:-}" = --wasmtime ] && wasmtime=1
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
    if command -v wasm-tools >/dev/null; then wasm-tools validate "$out"; fi
    node tools/point-wasm-diff.mjs "$f" "$proc" "$out" || status=1
    if [ $wasmtime = 1 ]; then
      want=$(node -e 'const m = new WebAssembly.Module(require("fs").readFileSync(process.argv[1])); const j = JSON.parse(new TextDecoder().decode(WebAssembly.Module.customSections(m, "ztcl.point")[0])); console.log(j.setup_steps + Math.ceil(3000 / j.block) * j.block_steps)' "$out")
      got=$(wasmtime run --invoke run "$out" 3000 1 2047 127 1000000 2>/dev/null | tail -n 1)
      if [ "$got" = "$want" ]; then
        echo "$out: wasmtime: steps $got"
      else
        echo "$out: wasmtime: steps $got, expected $want" >&2
        status=1
      fi
    fi
  done
done
exit $status

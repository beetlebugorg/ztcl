#!/bin/sh
# Runs bench.tcl 3 times on tclsh with the native binding of task 01 and
# 3 times in ztcl-host.wasm with the package of bridge.sh, in turns, and
# prints the median of each part and the ratio. Run bridge.sh first.
#   tools/cext-spike/bridge-bench.sh [script.tcl]
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
SPIKE=${SPIKE:-$HOME/.cache/cext-spike}
script=$(realpath "${1:-$here/bench.tcl}")
out=$SPIKE/bridge; cd "$out"
: > native.txt; : > wasm.txt
for i in 1 2 3; do
  printf 'load %s Sqlite3\nsource %s\n' "$SPIKE/rec/librecsqlite.so" "$script" | RECSTUB_OUT=/dev/null tclsh | tr '\n' ' ' >> native.txt; echo >> native.txt
  node --no-warnings "$here/bridge.mjs" "$root/zig-out/lib/ztcl-host.wasm" "$out/sqlite.wasm" "$script" | tr '\n' ' ' >> wasm.txt; echo >> wasm.txt
done
python3 -I - native.txt wasm.txt <<'PY'
import sys, statistics
def med(f):
    rows = [l.split() for l in open(f) if l.strip()]
    keys = rows[0][0::2]
    return keys, {k: statistics.median(float(r[2 * i + 1]) for r in rows) for i, k in enumerate(keys)}
keys, n = med(sys.argv[1]); _, w = med(sys.argv[2])
print(f"{'part':14} {'native':>7} {'wasm':>7} {'ratio':>6}")
for k in keys: print(f"{k:14} {n[k]:7.0f} {w[k]:7.0f} {w[k] / n[k]:6.1f}")
PY

#!/bin/sh
# Task 02 of docs/dev/cext-tasks/: builds the SQLite Tcl binding and the
# shim of slots.py (wshim.c) for wasm32-wasi with zig cc, builds
# ztcl-host.wasm with ztcl-host-cext.patch in a worktree, and runs each
# SQLite test file of LIST in Node.js with host.mjs. The counts of each
# slot go to $SPIKE/wasm/out/NAME.slots. Run fetch.sh first.
#   tools/cext-spike/wasm.sh LIST [-j N]
# LIST has one name of a test file on each line, with no .test.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
SPIKE=${SPIKE:-$HOME/.cache/cext-spike}; export SPIKE
list=$(realpath "$1"); jobs=6; [ "${2:-}" = -j ] && jobs=$3
zig=${ZIG:-zig}
tcl=$root/.tcl-src/core-8-6-16
rec=$SPIKE/rec
python3 -I "$here/slots.py" "$tcl" "$rec" >/dev/null
F="-target wasm32-wasi -O2 -DUSE_TCL_STUBS -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION
 -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_PERCENTILE -D_WASI_EMULATED_MMAN
 -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_SIGNAL -I$tcl/generic -I$SPIKE/bld"
$zig cc $F -c "$rec/wshim.c" -o "$rec/wshim.o"
$zig cc $F -c "$SPIKE/bld/tclsqlite3.c" -o "$rec/tclsqlite3.wasm.o"
$zig cc $F -mexec-model=reactor "$rec/wshim.o" "$rec/tclsqlite3.wasm.o" -o "$rec/sqlite.wasm" \
  -lwasi-emulated-mman -lwasi-emulated-getpid -lwasi-emulated-signal \
  -Wl,--export=Sqlite3_Init -Wl,--export=malloc -Wl,--export=free -Wl,--export=shim_cnt \
  -Wl,--export-table -Wl,--growable-table -Wl,--strip-debug
wt=$SPIKE/ztcl
if [ ! -d "$wt" ]; then
  git -C "$root" worktree add -q --detach "$wt" HEAD
  git -C "$wt" apply "$here/ztcl-host-cext.patch"
fi
(cd "$wt" && $zig build wasm-host)
out=$SPIKE/wasm/out; mkdir -p "$out" "$SPIKE/wasm/work"; : > "$out/status"
xargs -P "$jobs" -I{} sh -c '
  n={}; d=$SPIKE/wasm/work/$n; mkdir -p $d; cd $d
  t0=$(date +%s%N)
  timeout 300 node '"$here"'/host.mjs $SPIKE/ztcl/zig-out/lib/ztcl-host.wasm $SPIKE/rec/sqlite.wasm $d '"$out"'/$n.slots '"$here"'/wone.tcl $SPIKE/src/sqlite-src-3540100/test/$n.test > '"$out"'/$n.log 2>&1
  rc=$?; t1=$(date +%s%N)
  echo "$n $rc $(( (t1 - t0) / 1000000 ))" >> '"$out"'/status' < "$list"
python3 -I "$here/report.py" "$rec/slots.tsv" "$out"

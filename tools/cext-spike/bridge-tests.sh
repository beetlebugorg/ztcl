#!/bin/sh
# Task 04w of docs/dev/cext-tasks/, step 3: runs each SQLite test file of
# LIST in ztcl-host.wasm with the binding of libztclstubs.a
# (bridge-test.mjs), and compares the counts of each file with the run
# of task 02 in $SPIKE/wasm/out. Run bridge.sh once first: it builds
# $SPIKE/bridge/sqlite.wasm and ztcl-host.wasm.
#   tools/cext-spike/bridge-tests.sh LIST [-j N]
# LIST has one name of a test file on each line, with no .test.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
SPIKE=${SPIKE:-$HOME/.cache/cext-spike}; export SPIKE
list=$(realpath "$1"); jobs=6; [ "${2:-}" = -j ] && jobs=$3
out=$SPIKE/bridge/out; mkdir -p "$out" "$SPIKE/bridge/work"; : > "$out/status"
export here root
xargs -P "$jobs" -I{} sh -c '
  n={}; d=$SPIKE/bridge/work/$n; rm -rf $d; mkdir -p $d
  t0=$(date +%s%N)
  rc=0
  timeout 300 node $here/bridge-test.mjs $root/zig-out/lib/ztcl-host.wasm $SPIKE/bridge/sqlite.wasm $d $here/bwone.tcl $SPIKE/src/sqlite-src-3540100/test/$n.test > $SPIKE/bridge/out/$n.log 2>&1 || rc=$?
  t1=$(date +%s%N)
  echo "$n $rc $(( (t1 - t0) / 1000000 ))" >> $SPIKE/bridge/out/status' < "$list"
python3 -I "$here/compare.py" "$SPIKE/wasm/out" "$out" < "$list"

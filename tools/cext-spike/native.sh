#!/bin/sh
# Task 01 of docs/dev/cext-tasks/: builds the SQLite Tcl binding against
# the Tcl 8.6 stubs with the recording table of recstub.c, runs each
# SQLite test file on tclsh with it, and writes the counts of each slot
# to $SPIKE/native/out/NAME.slots. Run fetch.sh first.
#   tools/cext-spike/native.sh [-j N]
# FILES (default *.test) picks the test files, or LIST names a file
# with one name of a test file on each line, with no .test.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SPIKE=${SPIKE:-$HOME/.cache/cext-spike}; export SPIKE
jobs=6; [ "${1:-}" = -j ] && jobs=$2
tcl=$here/../../.tcl-src/core-8-6-16
rec=$SPIKE/rec
python3 -I "$here/slots.py" "$tcl" "$rec" >/dev/null
cc -O2 -fPIC -c "$rec/tramp.S" -o "$rec/tramp.o" 2>/dev/null
cc -O2 -fPIC -DUSE_TCL_STUBS -I"$tcl/generic" -I"$rec" -c "$here/recstub.c" -o "$rec/recstub.o"
cc -O2 -fPIC -shared -DUSE_TCL_STUBS -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_PERCENTILE \
  -DSQLITE_THREADSAFE=1 -I"$tcl/generic" -I"$SPIKE/bld" "$SPIKE/bld/tclsqlite3.c" \
  "$rec/recstub.o" "$rec/tramp.o" -o "$rec/librecsqlite.so" -lm
out=$SPIKE/native/out; mkdir -p "$out" "$SPIKE/native/work"; : > "$out/status"
if [ -n "${LIST:-}" ]; then
  sed "s|^|$SPIKE/src/sqlite-src-3540100/test/|; s|\$|.test|" "$LIST"
else
  ls "$SPIKE"/src/sqlite-src-3540100/test/${FILES:-*.test}
fi | xargs -P "$jobs" -I{} sh -c '
  n=$(basename {} .test); d=$SPIKE/native/work/$n; mkdir -p $d; cd $d
  t0=$(date +%s%N)
  RECSTUB_OUT='"$out"'/$n.slots timeout 60 tclsh '"$here"'/one.tcl {} > '"$out"'/$n.log 2>&1
  rc=$?; t1=$(date +%s%N)
  echo "$n $rc $(( (t1 - t0) / 1000000 ))" >> '"$out"'/status'
python3 -I "$here/report.py" "$rec/slots.tsv" "$out"

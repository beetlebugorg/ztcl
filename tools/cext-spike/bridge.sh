#!/bin/sh
# Task 04w of docs/dev/cext-tasks/: builds the SQLite Tcl binding for
# wasm32-wasi with libztclstubs.a, builds ztcl-host.wasm with -Dcext-wasm, and
# runs a script with the package in Node.js (bridge.mjs). Run fetch.sh
# first.
#   tools/cext-spike/bridge.sh script.tcl [args]
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
SPIKE=${SPIKE:-$HOME/.cache/cext-spike}
zig=${ZIG:-zig}
tcl=$root/.tcl-src/core-8-6-16
[ -d "$tcl" ] || tcl=$SPIKE/src/tcl-core-8-6-16
out=$SPIKE/bridge; mkdir -p "$out"
(cd "$root" && $zig build cext-stubs wasm-host -Dcext-wasm=true)
F="-target wasm32-wasi -O2 -DUSE_TCL_STUBS -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION
 -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_PERCENTILE -D_WASI_EMULATED_MMAN
 -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_SIGNAL -I$tcl/generic -I$SPIKE/bld"
[ "$out/tclsqlite3.o" -nt "$SPIKE/bld/tclsqlite3.c" ] || $zig cc $F -c "$SPIKE/bld/tclsqlite3.c" -o "$out/tclsqlite3.o"
ex=""
for n in Sqlite3_Init ztcl_cext_buf ztcl_cext_args ztcl_cext_reply ztcl_cext_dispatch ztcl_cext_interp ztcl_cext_result; do
  ex="$ex -Wl,--export=$n"
done
$zig cc $F -mexec-model=reactor "$out/tclsqlite3.o" "$root/zig-out/lib/libztclstubs.a" -o "$out/sqlite.wasm" \
  -lwasi-emulated-mman -lwasi-emulated-getpid -lwasi-emulated-signal $ex -Wl,--strip-debug
node "$here/bridge.mjs" "$root/zig-out/lib/ztcl-host.wasm" "$out/sqlite.wasm" "$@"

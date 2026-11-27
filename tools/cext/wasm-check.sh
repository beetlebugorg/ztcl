#!/bin/sh
# Builds each test package of tests/cext for wasm32-wasi with the stub
# library of the WebAssembly path, and runs each test script on tclsh
# and on ztcl-host.wasm in Node.js. The two outputs of a script must be
# equal. Build the libraries first:
#   zig build cext-stubs wasm-host -Dcext-wasm=true
#   tools/cext/wasm-check.sh [NAME...]
# The Tcl headers come from the tclConfig.sh of the tclsh of the host.
# TCLSH names that tclsh (default tclsh), and ZIG names zig.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$here/../..
tclsh=${TCLSH:-tclsh}
zig=${ZIG:-zig}
cfg=$(echo 'puts [info library]' | "$tclsh")/tclConfig.sh
for c in "$cfg" /usr/lib/tclConfig.sh /usr/lib/tcl8.6/tclConfig.sh /usr/lib/x86_64-linux-gnu/tcl8.6/tclConfig.sh /usr/local/lib/tclConfig.sh /opt/homebrew/lib/tclConfig.sh; do
  [ -f "$c" ] && { cfg=$c; break; }
done
. "$cfg"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# cxfile uses the channel commands, which the WebAssembly library does
# not have. cxpanic and cxscript stop the process or run threads.
skip=" cxfile cxpanic cxscript "
names=${*:-$(cd "$root/tests/cext" && ls *.tcl | sed 's/\.tcl$//')}
# Only the headers of Tcl: the folder of tcl.h can be /usr/include, whose
# C headers are those of the host and not those of WASI.
mkdir "$out/inc"
for h in tcl.h tclDecls.h tclPlatDecls.h; do
  cp "${TCL_INCLUDE_SPEC#-I}/$h" "$out/inc/"
done
exports=""
for e in buf args reply dispatch interp interp_free result precision; do
  exports="$exports -Wl,--export=ztcl_cext_$e"
done
fail=0
for n in $names; do
  case "$skip" in *" $n "*) [ $# -eq 0 ] && continue ;; esac
  init=$(echo "$n" | sed 's/^./\U&/')_Init
  # shellcheck disable=SC2086
  "$zig" cc -target wasm32-wasi -O1 -DUSE_TCL_STUBS -I"$out/inc" -mexec-model=reactor \
    "$root/tests/cext/$n.c" "$root/zig-out/lib/libztclstubs.a" -Wl,--export="$init" $exports -o "$out/$n.wasm"
  # tclsh loads the native package of the same name.
  # shellcheck disable=SC2086
  cc -shared -fPIC -O1 -DUSE_TCL_STUBS $TCL_INCLUDE_SPEC "$root/tests/cext/$n.c" -o "$out/$n.so" $TCL_STUB_LIB_SPEC
  { echo "set dir $out"; cat "$root/tests/cext/$n.tcl"; } > "$out/$n.tcl"
  "$tclsh" "$out/$n.tcl" > "$out/$n.want" 2>&1 || true
  node "$root/tools/cext/wasm-check.mjs" "$root/zig-out/lib/ztcl-host.wasm" "$out/$n.tcl" > "$out/$n.got" 2>&1 || true
  if diff -u "$out/$n.want" "$out/$n.got" > "$out/$n.diff"; then
    echo "$n: ok ($(wc -l < "$out/$n.want") lines)"
  else
    sed "s|$out|OUT|g" "$out/$n.diff"
    fail=1
  fi
done
exit $fail

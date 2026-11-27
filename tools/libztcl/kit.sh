#!/bin/sh
# Checks the development kit of libztcl (docs/libztcl.md) under PREFIX,
# the --prefix of `zig build libztcl`.
#   tools/libztcl/kit.sh PREFIX [ZTCL]
# 1. Builds tests/libztcl/kit/kitext.c as a TEA extension is built: with
#    the variables of PREFIX/lib/tclConfig.sh and the stub library.
# 2. Builds tests/libztcl/kit/kitembed.c with `pkg-config --cflags --libs
#    tcl` of PREFIX/lib/pkgconfig.
# 3. Runs tests/libztcl/kit/kit.tcl in kitembed (on libztcl), in ZTCL (a
#    runner built with -Dcext=true), and in the tclsh of the host (on
#    the libtcl8.6 of Tcl), and compares each output with kit.want.
# TCLSH names the tclsh (default tclsh); a missing tclsh skips its run.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
prefix=$(CDPATH= cd -- "$1" && pwd)
ztcl=${2:-}
tclsh=${TCLSH:-tclsh}
src=$root/tests/libztcl/kit
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# TEA sets TCL_BIN_DIR to the folder of tclConfig.sh and sources it.
TCL_BIN_DIR=$prefix/lib
. "$TCL_BIN_DIR/tclConfig.sh"
CC=${CC:-$TCL_CC}
CFLAGS="-O1 -Wall"
LDFLAGS=
LIBS=
# shellcheck disable=SC2086
$CC $CFLAGS -DUSE_TCL_STUBS $TCL_SHLIB_CFLAGS $TCL_INCLUDE_SPEC -c "$src/kitext.c" -o "$out/kitext.o"
ext=kitext$TCL_SHLIB_SUFFIX
eval "$TCL_SHLIB_LD -o \"$out/$ext\" \"$out/kitext.o\" $TCL_STUB_LIB_SPEC"
echo "package ifneeded kitext 1.0 [list load [file join \$dir $ext] Kitext]" > "$out/pkgIndex.tcl"
# The extension must not import a Tcl function: each call goes through
# the stubs table.
if command -v nm > /dev/null; then
  if nm -u "$out/$ext" | grep -E ' _?(Tcl|tcl)[A-Za-z_]'; then
    echo "kitext imports Tcl functions"
    exit 1
  fi
fi

PKG_CONFIG_PATH=$prefix/lib/pkgconfig
export PKG_CONFIG_PATH
[ "$(pkg-config --cflags --libs tcl)" = "$(pkg-config --cflags --libs ztcl)" ] || { echo "tcl.pc and ztcl.pc differ"; exit 1; }
# shellcheck disable=SC2046
$CC $CFLAGS "$src/kitembed.c" -o "$out/kitembed" $(pkg-config --cflags --libs tcl) -Wl,-rpath,"$prefix/lib"
if command -v ldd > /dev/null; then
  ldd "$out/kitembed" | grep -q "$prefix/lib/libtcl8.6.so" || { echo "kitembed does not load $prefix/lib/libtcl8.6.so"; exit 1; }
fi

fail=0
check() {
  if diff -u "$src/kit.want" "$out/$1.got" > "$out/$1.diff"; then
    echo "$1: ok"
  else
    sed "s|$out|OUT|g" "$out/$1.diff"
    fail=1
  fi
}
"$out/kitembed" "$out" "$src/kit.tcl" > "$out/libztcl.got" 2>&1 || true
check libztcl
if [ -n "$ztcl" ]; then
  { echo "set dir $out"; cat "$src/kit.tcl"; } > "$out/run.tcl"
  "$ztcl" --allow cext,package,channels,file "$out/run.tcl" > "$out/ztcl.got" 2>&1 || true
  check ztcl
fi
if command -v "$tclsh" > /dev/null; then
  { echo "set dir $out"; cat "$src/kit.tcl"; } > "$out/run.tcl"
  "$tclsh" "$out/run.tcl" > "$out/tcl.got" 2>&1 || true
  check tcl
else
  echo "tcl: skipped, no $tclsh"
fi
exit $fail

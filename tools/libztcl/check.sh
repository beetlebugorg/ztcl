#!/bin/sh
# Builds the test program tests/libztcl/embed.c twice, against the
# libtcl8.6 of the host and against libztcl, and compares the output and
# the exit code of each case.
#   tools/libztcl/check.sh [LIBDIR]
# LIBDIR has libtcl8.6.so of `zig build libztcl` (default zig-out/lib).
# The headers and libtcl8.6 come from the tclConfig.sh of the tclsh of
# the host. TCLSH names that tclsh (default tclsh). CC names the C
# compiler (default cc).
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
lib=$(CDPATH= cd -- "${1:-$root/zig-out/lib}" && pwd)
tclsh=${TCLSH:-tclsh}
# The C compiler: cc, or zig cc when the host has no cc (the container
# of the self-hosted runner).
if [ -n "${CC:-}" ]; then cc=$CC; elif command -v cc > /dev/null; then cc=cc; else cc="${ZIG:-zig} cc"; fi
cfg=$(echo 'puts [info library]' | "$tclsh")/tclConfig.sh
for c in "$cfg" /usr/lib/tclConfig.sh /usr/lib/tcl8.6/tclConfig.sh /usr/lib/x86_64-linux-gnu/tcl8.6/tclConfig.sh /usr/local/lib/tclConfig.sh /opt/homebrew/lib/tclConfig.sh; do
  [ -f "$c" ] && { cfg=$c; break; }
done
. "$cfg"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
src=$root/tests/libztcl
# shellcheck disable=SC2086
$cc -O1 -Wall $TCL_INCLUDE_SPEC "$src/embed.c" -o "$out/embed-tcl" $TCL_LIB_SPEC
# shellcheck disable=SC2086
$cc -O1 -Wall $TCL_INCLUDE_SPEC "$src/embed.c" -o "$out/embed-ztcl" -L"$lib" -ltcl8.6 -Wl,-rpath,"$lib"
# The program of libztcl must load the libtcl8.6.so of LIBDIR.
if command -v ldd > /dev/null; then
  ldd "$out/embed-ztcl" | grep -q "$lib/libtcl8.6.so" || { echo "embed-ztcl does not load $lib/libtcl8.6.so"; exit 1; }
fi
cp "$src/embed.tcl" "$out/embed.tcl"
printf 'puts [sum 4 5]\nset x 7\nerror boom\nputs "x $x [rev {1 2 3}]"\nproc p {} {\n  return multi\n}\nputs [p]\n' > "$out/stdin.txt"
printf 'puts start\nerror "the end"\n' > "$out/fail.tcl"
fail=0
n=0
run() {
  name=$1
  shift
  n=$((n + 1))
  for v in tcl ztcl; do
    code=0
    (cd "$out" && "./embed-$v" "$@" < "$out/in" > "$out/$v.out" 2>&1) || code=$?
    echo "exit $code" >> "$out/$v.out"
  done
  if diff -u "$out/tcl.out" "$out/ztcl.out" > "$out/diff"; then
    echo "$name: ok"
  else
    echo "$name: differs"
    sed "s|$out|OUT|g" "$out/diff"
    fail=1
  fi
}
: > "$out/in"
run script embed.tcl a b c
run exit embed.tcl exit 3
run error fail.tcl
run eval -eval 'set out [rev [list [sum 1 2] x]]; string length $out'
run eval-error -eval 'sum 1 two'
run eval-code -eval 'catch {error boom {} {MY CODE}} m o; set out [list $m [dict get $o -errorcode] $::errorCode]'
cp "$out/stdin.txt" "$out/in"
run stdin
exit $fail

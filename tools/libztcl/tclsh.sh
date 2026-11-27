#!/bin/sh
# Builds the tclsh of Tcl 8.6.16 (unix/tclAppInit.c) twice, against the
# libtcl8.6 of the host and against libztcl, and runs scripts on both.
# The output and the exit code of each script must be equal.
#   tools/libztcl/tclsh.sh [LIBDIR] [SCRIPT...]
# LIBDIR has libtcl8.6.so of `zig build libztcl` (default zig-out/lib).
# The default scripts are tests/libztcl/*.tcl with no argument. The Tcl
# source comes from tools/fetch-tcl.sh. TCLSH and CC are as in check.sh.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
lib=$(CDPATH= cd -- "${1:-$root/zig-out/lib}" && pwd)
[ $# -gt 0 ] && shift
tclsh=${TCLSH:-tclsh}
cc=${CC:-cc}
cfg=$(echo 'puts [info library]' | "$tclsh")/tclConfig.sh
for c in "$cfg" /usr/lib/tclConfig.sh /usr/lib/tcl8.6/tclConfig.sh /usr/lib/x86_64-linux-gnu/tcl8.6/tclConfig.sh /usr/local/lib/tclConfig.sh /opt/homebrew/lib/tclConfig.sh; do
  [ -f "$c" ] && { cfg=$c; break; }
done
. "$cfg"
tcl=$("$root/tools/fetch-tcl.sh" core-8-6-16)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
app=$tcl/unix/tclAppInit.c
# shellcheck disable=SC2086
$cc -O1 $TCL_INCLUDE_SPEC "$app" -o "$out/tclsh-tcl" $TCL_LIB_SPEC
# shellcheck disable=SC2086
$cc -O1 $TCL_INCLUDE_SPEC "$app" -o "$out/tclsh-ztcl" -L"$lib" -ltcl8.6 -Wl,-rpath,"$lib"
if [ $# -eq 0 ]; then
  set -- "$root"/tests/libztcl/tclsh-*.tcl
fi
fail=0
for s in "$@"; do
  name=$(basename "$s" .tcl)
  for v in tcl ztcl; do
    code=0
    (cd "$out" && "./tclsh-$v" "$s" < /dev/null > "$out/$v.out" 2>&1) || code=$?
    echo "exit $code" >> "$out/$v.out"
  done
  if diff -u "$out/tcl.out" "$out/ztcl.out" > "$out/diff"; then
    echo "$name: ok ($(wc -l < "$out/tcl.out") lines)"
  else
    echo "$name: differs"
    sed "s|$out|OUT|g" "$out/diff" | head -40
    fail=1
  fi
done
# The commands of the standard input.
printf 'set a 6\nputs [expr {$a * 7}]\nputs $tcl_interactive\nexit 4\n' > "$out/in"
for v in tcl ztcl; do
  code=0
  (cd "$out" && "./tclsh-$v" < "$out/in" > "$out/$v.out" 2>&1) || code=$?
  echo "exit $code" >> "$out/$v.out"
done
if diff -u "$out/tcl.out" "$out/ztcl.out"; then echo "stdin: ok"; else fail=1; fi
exit $fail

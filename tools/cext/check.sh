#!/bin/sh
# Builds each test package of tests/cext and runs each test script on
# tclsh and on ztcl. The two outputs of a script must be equal.
#   tools/cext/check.sh [ZTCL] [NAME...]
# ZTCL is a runner built with -Dcext=true (default zig-out/bin/ztcl).
# The headers and the stub library come from the tclConfig.sh of the
# tclsh of the host. TCLSH names that tclsh (default tclsh).
# SPDX-License-Identifier: BSD-2-Clause
set -eu
# The C compiler of the native packages for tclsh: cc, or zig cc when
# the host has no cc (the container of the self-hosted runner).
if [ -n "${CC:-}" ]; then cc_cmd=$CC; elif command -v cc > /dev/null; then cc_cmd=cc; else cc_cmd="${ZIG:-zig} cc"; fi
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$here/../..
ztcl=${1:-$root/zig-out/bin/ztcl}
[ $# -gt 0 ] && shift
tclsh=${TCLSH:-tclsh}
cfg=$(echo 'puts [info library]' | "$tclsh")/tclConfig.sh
for c in "$cfg" /usr/lib/tclConfig.sh /usr/lib/tcl8.6/tclConfig.sh /usr/lib/x86_64-linux-gnu/tcl8.6/tclConfig.sh /usr/local/lib/tclConfig.sh /opt/homebrew/lib/tclConfig.sh; do
  [ -f "$c" ] && { cfg=$c; break; }
done
. "$cfg"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
names=${*:-$(cd "$root/tests/cext" && ls *.tcl | sed 's/\.tcl$//')}
fail=0
for n in $names; do
  # shellcheck disable=SC2086
  $cc_cmd -shared -fPIC -O1 -Wall -DUSE_TCL_STUBS $TCL_INCLUDE_SPEC "$root/tests/cext/$n.c" -o "$out/$n.so" $TCL_STUB_LIB_SPEC
  # The script reads the folder of the packages from $dir.
  { echo "set dir $out"; cat "$root/tests/cext/$n.tcl"; } > "$out/$n.tcl"
  "$tclsh" "$out/$n.tcl" > "$out/$n.want" 2>&1 || true
  # The tclsh of the comparison is Tcl 8.6, and the runner follows 9.1
  # by default.
  "$ztcl" --tcl 8.6 --allow cext,package,channels,interp,event "$out/$n.tcl" > "$out/$n.got" 2>&1 || true
  if diff -u "$out/$n.want" "$out/$n.got" > "$out/$n.diff"; then
    echo "$n: ok ($(wc -l < "$out/$n.want") lines)"
  else
    sed "s|$out|OUT|g" "$out/$n.diff"
    fail=1
  fi
done
exit $fail

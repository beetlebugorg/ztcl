#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Counts the user instructions, in millions, of ztcl with no JIT, of
# ztcl with both JIT tiers (the default of the runner), and of tclsh.
#
#   count.sh FILE.tcl          counts one script
#   count.sh -p PROC           counts one proc of micro.tcl
#   count.sh -c 'COMMAND'      counts a loop of 1,000,000 passes of one
#                              command. The loop has the variables a
#                              (hello), d ({a 1 b 2}), l ({1 2 3}), s, i.
#
# RUNNER sets the runner (default zig-out/bin/ztcl). TCLSH sets the tclsh.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runner=${RUNNER:-$here/../../zig-out/bin/ztcl}
tclsh=${TCLSH:-tclsh}
work=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-count.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
count() {
    perf stat -x, -e instructions:u -o "$work/perf" -- "$@" > /dev/null 2>&1
    awk -F, '$1 > 0 { printf "%.1f", $1 / 1e6 }' "$work/perf"
}
case $1 in
-p)
    name=$2
    sed "s/^set PL .*/set PL {$2}/" "$here/micro.tcl" > "$work/s.tcl" ;;
-c)
    name=$2
    printf 'proc f {n} {set a hello; set d {a 1 b 2}; set l {1 2 3}; set s 0; for {set i 0} {$i<$n} {incr i} {%s}; return $s}\nf 1000000\n' "$2" > "$work/s.tcl" ;;
*)
    name=${1##*/}
    cp "$1" "$work/s.tcl" ;;
esac
printf '%-40s interp %8s  jit %8s  tclsh %8s\n' "$name" \
    "$(count "$runner" --allow clock --no-jit "$work/s.tcl")" \
    "$(count "$runner" --allow clock "$work/s.tcl")" \
    "$(count "$tclsh" "$work/s.tcl")"

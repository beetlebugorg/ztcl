#!/bin/sh
# Builds the tier 2 models of model.s and prints the instruction count of
# one pass of each loop and the model count of each benchmark:
# the startup count of the runner (`puts hi`) plus the passes of its hot
# loops times the count of one pass.
#
#   tools/jit-model/run.sh [-r runner]
#
# Each count is `perf stat -e instructions:u`. Run the tool under the
# memory cap of AGENTS.md.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runner="$here/../../zig-out/bin/ztcl"
[ "${1:-}" = -r ] && runner=$2
work=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-model.XXXXXX")
trap 'rm -rf "$work"' EXIT
zig cc -O2 -o "$work/model" "$here/model.c" "$here/model.s"
count() { perf stat -x, -e instructions:u "$@" 2>&1 >/dev/null | tail -n 1 | cut -d, -f1; }
echo 'puts hi' > "$work/hi.tcl"
start=$(count "$runner" "$work/hi.tcl")
pass() {
    a=$(count "$work/model" "$1" 0)
    b=$(count "$work/model" "$1" 1000000)
    echo $(( (b - a) / 1000000 ))
}
sum=$(pass sum); nested=$(pass nested); fe=$(pass foreach); dsum=$(pass dsum)
printf 'one pass: sum %d, nested inner %d, foreach %d, dsum %d instructions\n' "$sum" "$nested" "$fe" "$dsum"
printf 'startup (puts hi): %d\n' "$start"
printf '%-12s %14s\n' script model
printf '%-12s %14d\n' sum.tcl $((start + 1000000 * sum))
printf '%-12s %14d\n' nested.tcl $((start + 1000000 * nested))
printf '%-12s %14d\n' foreach.tcl $((start + 1000000 * fe + 100000 * nested))
printf '%-12s %14d\n' dsum.tcl $((start + 1000000 * dsum))

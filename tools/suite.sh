#!/bin/sh
# Runs test files of the Tcl source on ztcl and prints the counts.
#
#   tools/suite.sh [-r runner] [-t tag | -s tests-dir] [file.test ...]
#
#   -r  The ztcl binary. The default is zig-out/bin/ztcl.
#   -t  A Tcl release tag. The script fetches it. The default is
#       core-8-6-16.
#   -s  A folder of Tcl test files. It replaces -t.
#
# Prints one line for each file (the counts of the tests that pass,
# fail, and are skipped), then the totals. The step limit stops a test that loops.
# The memory limit (2 GiB) stops a test that allocates without end.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tcl="$here/../zig-out/bin/ztcl"; tag=core-8-6-16; tests=
while getopts r:t:s: o; do
    case $o in
    r) tcl=$OPTARG ;;
    t) tag=$OPTARG ;;
    s) tests=$OPTARG ;;
    *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
if [ -z "$tests" ]; then
    src=$("$here/fetch-tcl.sh" "$tag") || exit 1
    tests="$src/tests"
fi
[ $# -eq 0 ] && set -- set.test incr.test if.test while.test for.test \
    foreach.test proc.test uplevel.test upvar.test expr.test list.test \
    lindex.test llength.test lrange.test linsert.test lreplace.test \
    lsearch.test join.test split.test concat.test append.test \
    string.test format.test switch.test eval.test parse.test \
    lmap.test apply.test rename.test error.test \
    lset.test namespace.test regexp.test binary.test info.test dict.test scan.test
tp=0; tf=0; ts=0
for f in "$@"; do
    out=$(timeout 60 "$tcl" --max-steps 200000000 --mem 2147483648 --keep-going "$here/tcltest.tcl" "$tests/$f" 2>&1 | grep -E '^pass [0-9]+ fail' | tail -1)
    printf '%-16s %s\n' "$f" "${out:-no result (the file stopped early or crashed)}"
    if [ -n "$out" ]; then
        read -r _ p _ x _ y _ <<EOF
$out
EOF
        tp=$((tp + p)); tf=$((tf + x)); ts=$((ts + y))
    fi
done
printf '%-16s pass %d fail %d skip %d\n' total "$tp" "$tf" "$ts"

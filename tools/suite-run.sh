#!/bin/sh
# Runs all files of the Tcl 8.6.16 suite with the suite runner, without
# and with the JIT, and writes docs/dev/suite.md, docs/dev/suite-tests.tsv,
# and docs/dev/suite-counts.tsv with tools/suite-md.py.
#
#   zig build -Doptimize=ReleaseSafe suite-runner
#   tools/suite-run.sh [-d dir] [-O optimize]
#
#   -d  The folder for the logs. The default is a new temporary folder.
#   -O  The optimize mode of the build, for the page. The default is
#       ReleaseSafe.
#
# The two runs go at the same time.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dir=; opt=ReleaseSafe
while getopts d:O: o; do
    case $o in
    d) dir=$OPTARG ;;
    O) opt=$OPTARG ;;
    *) exit 2 ;;
    esac
done
[ -n "$dir" ] || dir=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-suite-run.XXXXXX") || exit 1
mkdir -p "$dir" || exit 1
run="$here/../zig-out/bin/ztcl-suite"
"$here/suite.sh" -a -r "$run" -o "$dir/files.tsv" -p "$dir/tests.tsv" > "$dir/out.txt" 2>&1 &
a=$!
"$here/suite.sh" -a -j -r "$run" -o "$dir/files-jit.tsv" -p "$dir/tests-jit.tsv" > "$dir/out-jit.txt" 2>&1 &
b=$!
wait $a; wait $b
tail -1 "$dir/out.txt"
tail -1 "$dir/out-jit.txt"
{
    printf 'date\t%s\n' "$(date -u +%Y-%m-%d)"
    printf 'commit\t%s\n' "$(git -C "$here/.." rev-parse --short HEAD)"
    printf 'optimize\t%s\n' "$opt"
} > "$dir/meta"
python3 -I "$here/suite-md.py" "$dir"
echo "logs: $dir"

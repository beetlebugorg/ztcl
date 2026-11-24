#!/bin/sh
# Counts the user instructions of the runner on `puts hi` and on each
# script of bench/, and compares the counts with a baseline or the gates.
#
#   tools/jit-perf.sh --record          writes bench/jit-baseline.tsv
#   tools/jit-perf.sh --check off       no flag: each count at most 1 %
#                                       above the baseline
#   tools/jit-perf.sh --check jit       `--jit`: each count at most its
#                                       gate in bench/jit-gates.tsv
#   tools/jit-perf.sh --check jit2      `--jit --jit-tier2`: each count at
#                                       most its gate in
#                                       bench/jit-gates2.tsv
#   tools/jit-perf.sh --show [flags]    prints the counts with the flags
#
# `-r runner` sets the runner. The default is zig-out/bin/ztcl. `-l N`
# sets the limit of `--check off` in tenths of a percent (default 10).
# The limit of `puts hi` is 5000 instructions above the baseline.
# Each count is `perf stat -x, -e instructions:u` of the whole process.
# Run the tool under the memory cap of AGENTS.md.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root="$here/.."
runner="$root/zig-out/bin/ztcl"
base="$root/bench/jit-baseline.tsv"
gates="$root/bench/jit-gates.tsv"
limit=10
mode=
what=
while [ $# -gt 0 ]; do
    case $1 in
    --record) mode=record; shift ;;
    --check) mode=check; what=$2; shift 2 ;;
    --show) mode=show; shift; break ;;
    -r) runner=$2; shift 2 ;;
    -l) limit=$2; shift 2 ;;
    *) echo "usage: jit-perf.sh --record | --check off|jit | --show [flags]" >&2; exit 2 ;;
    esac
done
[ -n "$mode" ] || { echo "usage: jit-perf.sh --record | --check off|jit | --show [flags]" >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-perf.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
printf 'puts hi\n' > "$work/hi.tcl"

# count FILE FLAGS...: prints the instruction count of one run.
count() {
    f=$1; shift
    perf stat -x, -e instructions:u -o "$work/perf" -- "$runner" "$@" "$f" > /dev/null 2>&1 || { echo 0; return; }
    awk -F, '/instructions/ { print $1 }' "$work/perf"
}

scripts="$work/hi.tcl"
for f in "$root"/bench/*.tcl; do scripts="$scripts $f"; done
name() { case $1 in "$work/hi.tcl") echo hi ;; *) b=${1##*/}; echo "${b%.tcl}" ;; esac; }

status=0
case $mode in
record)
    : > "$base"
    for f in $scripts; do printf '%s\t%s\n' "$(name "$f")" "$(count "$f")" >> "$base"; done
    cat "$base"
    ;;
show)
    for f in $scripts; do printf '%s\t%s\n' "$(name "$f")" "$(count "$f" "$@")"; done
    ;;
check)
    case $what in
    off) flags= ; table=$base ;;
    jit) flags=--jit; table=$gates ;;
    jit2) flags="--jit --jit-tier2"; table="$root/bench/jit-gates2.tsv" ;;
    *) echo "--check needs off, jit, or jit2" >&2; exit 2 ;;
    esac
    [ -f "$table" ] || { echo "no table $table"; exit 0; }
    for f in $scripts; do
        n=$(name "$f")
        want=$(awk -F'\t' -v n="$n" '$1 == n { print $2 }' "$table")
        [ -n "$want" ] || continue
        got=$(count "$f" $flags)
        if [ "$what" = off ] && [ "$n" = hi ]; then
            # The startup gate is 5000 instructions.
            max=$((want + 5000))
        elif [ "$what" = off ]; then
            max=$((want + want * limit / 1000))
        else
            max=$want
        fi
        if [ "$got" -gt 0 ] && [ "$got" -le "$max" ]; then r=ok; else r=FAIL; status=1; fi
        printf '%-10s %12s %12s %6s  %s\n' "$n" "$got" "$want" "$(awk -v a="$got" -v b="$want" 'BEGIN { printf "%.3f", a / b }')" "$r"
    done
    ;;
esac
exit $status

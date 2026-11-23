#!/bin/sh
# Runs each script of tests/mem with N passes and with 10 N passes, and
# prints the peak memory of both runs.
#
#   tools/mem-flat.sh [-r runner] [script ...]
#
# The peak comes from `--report`. A script is flat when the peak for
# 10 N passes is at most 10 % above the peak for N passes. The exit code
# is 1 when a script is not flat. The table shows the bytes for each pass.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runner="$here/../zig-out/bin/ztcl"
while getopts r: o; do
    case $o in
    r) runner=$OPTARG ;;
    *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -gt 0 ] || set -- lset pass lassign switch method b64enc b64dec append list dict proc coro
printf '%-9s %8s %12s %12s %10s  %s\n' script N peak_N peak_10N B/pass result
bad=0
for s in "$@"; do
    n=300000
    case $s in b64enc | b64dec) n=300 ;; append | coro) n=1500000 ;; esac
    file="$here/../tests/mem/$s.tcl"
    peak() {
        "$runner" --report --max-steps 100000000000 --mem 6442450944 --tclsh "$file" "$1" 2>&1 >/dev/null |
            sed -n 's/^report .* peak=\([0-9]*\)$/\1/p'
    }
    a=$(peak "$n")
    b=$(peak $((n * 10)))
    if [ -z "$a" ] || [ -z "$b" ]; then
        printf '%-9s %8d %12s %12s %10s  %s\n' "$s" "$n" "${a:--}" "${b:--}" - ERROR
        bad=1
        continue
    fi
    per=$(((b - a) / (n * 9)))
    if [ $((b * 10)) -le $((a * 11)) ]; then r=flat; else r=GROWS; bad=1; fi
    printf '%-9s %8d %12d %12d %10d  %s\n' "$s" "$n" "$a" "$b" "$per" "$r"
done
exit $bad

#!/bin/sh
# Runs the thread tests of tests/thread/ and prints the counts.
#
#   tools/thread-tests.sh [-r runner] [-x flags] [-n runs] [file.tcl ...]
#
#   -r  The ztcl binary. The default is zig-out/bin/ztcl.
#   -x  Extra flags for the runner, for example "--jit-threshold 0" or "--no-jit".
#   -n  Runs each file this many times in a row. The default is 1.
#   -p  A prelude of tests/thread/ that runs after lib.tcl, for example
#       prelude/vm.tcl, which runs each thread at the level vm.
#
# Each file runs after tests/thread/lib.tcl in one interpreter with the
# capabilities thread, event, package, and clock. A line
# "# thread-tests-flags: ..." in a file adds runner flags, and the file
# then runs with a new root folder for `file` and channels. A file passes when its last
# line is "pass N fail 0" and the runner exits with 0. Each run has a
# time limit of 120 seconds.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dir="$here/../tests/thread"
tcl="$here/../zig-out/bin/ztcl"; extra=; runs=1; prelude=
while getopts r:x:n:p: o; do
    case $o in
    r) tcl=$OPTARG ;;
    x) extra=$OPTARG ;;
    n) runs=$OPTARG ;;
    p) prelude=$OPTARG ;;
    *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
# A file with flags runs in another folder, so the runner path is absolute.
case $tcl in /*) ;; *) tcl=$PWD/$tcl ;; esac
if [ $# -eq 0 ]; then
    for f in "$dir"/*.tcl; do
        [ "${f##*/}" = lib.tcl ] || set -- "$@" "$f"
    done
fi
bad=0
for f in "$@"; do
    case $f in */*) ;; *) f=$dir/$f ;; esac
    n=0; ok=0
    flags=$(sed -n 's/^# thread-tests-flags: //p' "$f")
    while [ $n -lt "$runs" ]; do
        n=$((n + 1))
        root=
        if [ -n "$flags" ]; then
            root=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-thread.XXXXXX") || exit 1
            cp "$dir/lib.tcl" "$f" ${prelude:+"$dir/$prelude"} "$root/"
            prelude_here=${prelude:+${prelude##*/}}
        fi
        # shellcheck disable=SC2086
        if [ -n "$root" ]; then
            out=$(cd "$root" && timeout 120 "$tcl" --tcl 8.6 --allow thread,event,package,clock $flags --root "$root" $extra lib.tcl $prelude_here "${f##*/}" 2>&1)
        else
            out=$(timeout 120 "$tcl" --tcl 8.6 --allow thread,event,package,clock $extra "$dir/lib.tcl" ${prelude:+"$dir/$prelude"} "$f" 2>&1)
        fi
        rc=$?
        [ -n "$root" ] && rm -rf -- "$root"
        last=$(printf '%s\n' "$out" | tail -n 1)
        case $last in
        "pass "*" fail 0") [ $rc -eq 0 ] && ok=$((ok + 1)) ;;
        esac
        if [ $ok -ne $n ]; then
            printf '%s\n' "$out" | tail -n ${TAIL:-20}
            echo "status $rc"
            break
        fi
    done
    printf '%-20s %s, %d of %d runs\n' "${f##*/}" "$last" "$ok" "$runs"
    [ $ok -eq "$runs" ] || bad=1
done
exit $bad

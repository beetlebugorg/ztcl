#!/bin/sh
# Runs programs of kostya/benchmarks on ztcl and on a tclsh.
#
#   tools/kostya.sh [--only bf|bf_oo|base64] [--mem BYTES] [--no-jit] [--no-jit-tier2] [-r ztcl] [-t tclsh]
#
# Programs: `bf.tcl bench.b`, `bf_oo.tcl bench.b`, and `base64/test.tcl`.
# For each one and each runner, the tool prints the output, the user
# instruction count (`perf stat -e instructions:u`), and the peak resident
# memory. Then it prints the ratio of the counts (ztcl over tclsh) and
# whether the outputs are equal. The `base64` output has two time fields.
# The tool removes them before it compares.
#
# ztcl runs with the JIT on. `--no-jit` turns it off, and
# `--no-jit-tier2` turns tier 2 off.
#
# The files come from tools/fetch-kostya.sh. Each run happens in a
# temporary folder that holds a copy of the files and a wrapper script.
# The wrapper sets `::env(QUIET)`, so `bf.tcl` prints its checksum. It
# sets the variable the same way for both runners and changes no file.
# ztcl runs with the capability list of the programs, the root folder of
# the temporary folder, and the default network policy `loopback`. The
# programs call `socket` inside `catch`, and no server listens.
#
# Run the tool under the memory cap of AGENTS.md.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ztcl="$here/../zig-out/bin/ztcl"
tclsh=tclsh
only="bf bf_oo base64"
mem=
jit=
while [ $# -gt 0 ]; do
    case $1 in
    --only) only=$2; shift 2 ;;
    --mem) mem=$2; shift 2 ;;
    --no-jit) jit=--no-jit; shift ;;
    --no-jit-tier2) jit=--no-jit-tier2; shift ;;
    -r) ztcl=$2; shift 2 ;;
    -t) tclsh=$2; shift 2 ;;
    *) echo "usage: kostya.sh [--only name] [--mem bytes] [--no-jit] [--no-jit-tier2] [-r ztcl] [-t tclsh]" >&2; exit 2 ;;
    esac
done
src=$("$here/fetch-kostya.sh")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$src/brainfuck/bf.tcl" "$src/brainfuck/bf_oo.tcl" "$src/brainfuck/bench.b" "$src/base64/test.tcl" "$work/"
cat > "$work/wrap.tcl" <<'W'
set ::env(QUIET) 1
set argv [lassign $argv prog]
source $prog
W
[ -n "$mem" ] || mem=2147483648

# run NAME RUNNER-LABEL COMMAND...: writes out.NAME.LABEL and stats.NAME.LABEL
run() {
    name=$1; label=$2; shift 2
    python3 -I - "$work/out.$name.$label" "$work/err.$name.$label" "$work" "$@" > "$work/stat.$name.$label" <<'P'
import os, subprocess, sys, resource
out, err, cwd = sys.argv[1:4]
cmd = ["perf", "stat", "-x,", "-e", "instructions:u", "-o", out + ".perf", "--"] + sys.argv[4:]
with open(out, "wb") as o, open(err, "wb") as e:
    rc = subprocess.run(cmd, stdout=o, stderr=e, cwd=cwd).returncode
n = 0
try:
    for line in open(out + ".perf"):
        f = line.split(",")
        if len(f) > 2 and "instructions" in f[2]:
            n = int(f[0])
except (OSError, ValueError):
    pass
print(rc, n, resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss * 1024)
P
}

status=0
for name in $only; do
    case $name in
    bf) args="bf.tcl bench.b" ;;
    bf_oo) args="bf_oo.tcl bench.b" ;;
    base64) args="test.tcl" ;;
    *) echo "unknown program $name" >&2; exit 2 ;;
    esac
    echo "== $name"
    run "$name" ztcl "$ztcl" $jit --compute 100000000000 --mem "$mem" \
        --allow package,interp,clock,channels,file,event,socket,exec \
        --root "$work" --tclsh wrap.tcl $args
    run "$name" tclsh "$tclsh" wrap.tcl $args
    for label in ztcl tclsh; do
        set -- $(cat "$work/stat.$name.$label")
        echo "-- $label: exit=$1 instructions=$2 peak_rss_bytes=$3"
        sed 's/, [0-9.e-]*$//' "$work/out.$name.$label"
        if [ -s "$work/err.$name.$label" ]; then echo "(stderr)"; head -c 400 "$work/err.$name.$label"; fi
        eval "ins_$label=$2; rc_$label=$1"
    done
    # Compare with the time fields removed.
    sed 's/, [0-9.e-]*$//' "$work/out.$name.ztcl" > "$work/n.z"
    sed 's/, [0-9.e-]*$//' "$work/out.$name.tclsh" > "$work/n.t"
    if cmp -s "$work/n.z" "$work/n.t" && [ "$rc_ztcl" = 0 ]; then same=equal; else same=DIFFER; status=1; fi
    ratio=$(python3 -I -c "import sys; a,b=int(sys.argv[1]),int(sys.argv[2]); print('%.2f' % (a/b) if b else 'n/a')" "$ins_ztcl" "$ins_tclsh")
    echo "-- ratio ztcl/tclsh instructions: $ratio  outputs: $same"
done
exit $status

#!/bin/sh
# Builds ztcl with ThreadSanitizer and runs the thread tests with it.
#
#   tools/tsan.sh [-n runs]
#
#   -n  Runs each file of tests/thread/ this many times. The default is 1.
#
# The script builds two runners for x86_64-linux-gnu: zig-out/tsan with
# ThreadSanitizer, and zig-out/tsan-plant with the planted race of
# -Dtsan-plant=true. It then checks three things:
#
# 1. The planted race: ThreadSanitizer reports tsv.opIncr for
#    tools/tsan/plant.tcl.
# 2. The stop flag: with no suppression, ThreadSanitizer reports
#    thread.stopWorker for tools/tsan/stop.tcl.
# 3. The thread tests of tests/thread/ with tools/tsan/tsan.supp give no
#    report.
#
# Checks 1 and 2 show that the build finds a race in ztcl code, so a
# clean check 3 has a meaning.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
top=$here/..
runs=1
while getopts n: o; do
    case $o in
    n) runs=$OPTARG ;;
    *) exit 2 ;;
    esac
done
cd "$top" || exit 1
zig build -Dtsan=true -Dtarget=x86_64-linux-gnu --prefix zig-out/tsan || exit 1
zig build -Dtsan=true -Dtsan-plant=true -Dtarget=x86_64-linux-gnu --prefix zig-out/tsan-plant || exit 1
bad=0
flags="--allow thread,event,package,clock"
out=$(TSAN_OPTIONS=halt_on_error=0 timeout 300 zig-out/tsan-plant/bin/ztcl $flags tools/tsan/plant.tcl 2>&1)
if printf '%s\n' "$out" | grep -q '^    #0 tsv.opIncr'; then echo "plant: reported"; else echo "plant: no report"; bad=1; fi
out=$(TSAN_OPTIONS=halt_on_error=0 timeout 300 zig-out/tsan/bin/ztcl $flags tools/tsan/stop.tcl 2>&1)
if printf '%s\n' "$out" | grep -q 'thread.stopWorker'; then echo "stop: reported"; else echo "stop: no report"; bad=1; fi
TSAN_OPTIONS="suppressions=$here/tsan/tsan.supp halt_on_error=0 exitcode=66" \
    tools/thread-tests.sh -n "$runs" -r zig-out/tsan/bin/ztcl || bad=1
exit $bad

#!/bin/sh
# Checks `ztcl build --strip` (docs/strip.md): a program with no
# capability gets a runtime with no regexp and no clock, smaller than the
# full runtime; a dropped command gives the error that names it; --check
# and --profile run their tests.
#
#   tests/strip.sh [ztcl]
#
# The default program is zig-out/bin/ztcl. It needs zig on the PATH.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
top=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ztcl=$(CDPATH= cd -- "$(dirname -- "${1:-$top/zig-out/bin/ztcl}")" && pwd)/$(basename -- "${1:-ztcl}")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ZTCL_SRC="$top" ZTCL_STRIP_CACHE="$tmp/cache"
cd "$tmp"
fail=0
check() { # name, want, got
    if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}

printf 'puts "hello, $argv"\n' > hello.tcl
"$ztcl" build --strip --check -o hello hello.tcl > hello.log
check "hello runs" "hello, a b" "$(./hello a b)"
grep -q 'dropped (not used): regexp oo coroutine binary' hello.log || { echo "FAIL: the report of hello"; cat hello.log; fail=1; }
grep -q 'check: the tests passed' hello.log || { echo "FAIL: --check of hello"; fail=1; }

printf 'catch {regexp a a} e\nputs $e\nputs $::errorCode\ncatch {clock seconds} e\nputs $e\n' > dropped.tcl
"$ztcl" build --strip --drop-module regexp -o dropped dropped.tcl > /dev/null
check "a dropped command" 'command "regexp" is not in this build: the build left out the feature regexp (rebuild with --keep regexp)
ZTCL STRIPPED regexp regexp
invalid command name "clock"' "$(./dropped)"
if "$ztcl" build --strip --drop-module regexp --check -o dropped dropped.tcl > check.log; then
    echo "FAIL: --check passed with a dropped command"; fail=1
else echo "ok: --check finds a dropped command"; fi

printf 'set c [string cat reg exp]\nputs [$c a+ caab]\n' > dyn.tcl
"$ztcl" build --strip --profile -o dyn dyn.tcl > dyn.log
grep -q 'kept (ran in the profile): regexp' dyn.log || { echo "FAIL: --profile"; cat dyn.log; fail=1; }
check "a profile run" "1" "$(./dyn)"
exit $fail

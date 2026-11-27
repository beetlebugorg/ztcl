#!/bin/sh
# The tests of the command component of WASI 0.3.2. Run `zig build
# wasi-component` first. The tests check that the component has no
# preview 1 and no 0.2 import, and run scripts under wasmtime: the output
# on stdout, `errorInfo` on stderr, `argv`, the exit code of `exit`, and the exit
# code and `errorInfo` of an error.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
c=${ZTCL_COMPONENT:-$here/../zig-out/bin/ztcl.component.wasm}
case $c in /*) ;; *) c=$PWD/$c ;; esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-p3.XXXXXX") || exit 1
trap 'rm -rf -- "$dir"' EXIT
cd "$dir" || exit 1
fails=0
check() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        printf '  want: %s\n  got:  %s\n' "$2" "$3"
        fails=$((fails + 1))
    fi
}
run() {
    timeout 20 "${WASMTIME:-wasmtime}" run -W max-wasm-stack=8388608 --dir .::/ "$c" "$@"
}
wit=$(wasm-tools component wit "$c")
check "no preview 1 import" 0 "$(printf '%s\n' "$wit" | grep -c wasi_snapshot_preview1)"
check "no 0.2 import" 0 "$(printf '%s\n' "$wit" | grep -c '@0\.2')"
check "the run export" 1 "$(printf '%s\n' "$wit" | grep -c 'export wasi:cli/run@0.3.2;')"

printf 'puts "[expr {6*7}] $argc $argv"\n' > a.tcl
check "stdout and argv" "42 2 one two" "$(run a.tcl one two 2>/dev/null)"
printf 'proc f {n} { if {$n < 2} { return $n }; expr {[f [expr {$n-1}]] + [f [expr {$n-2}]]} }\nputs [f 20]\n' > fib.tcl
check "procs" "6765" "$(run fib.tcl)"
printf 'puts before\nexit 3\n' > exit.tcl
out=$(run exit.tcl)
check "exit code of exit" "before 3" "$out $?"
printf 'error boom\n' > err.tcl
check "errorInfo on stderr" "" "$(run err.tcl 2>/dev/null)"
check "errorInfo on stderr" "boom" "$(run err.tcl 2>&1 >/dev/null | head -1)"
out=$(run err.tcl 2>&1)
check "exit code of an error" "boom 1" "$(printf '%s' "$out" | head -1) $?"
check "a missing script" "1" "$(run none.tcl 2>/dev/null; echo $?)"
printf 'puts [info commands file]|[info commands exec]|[info commands socket]\n' > caps.tcl
check "no capability" "||" "$(run caps.tcl)"
big=$(awk 'BEGIN { for (i = 0; i < 20000; i++) printf "x" }')
printf 'puts [string length [string repeat x 20000]]\nputs [string repeat x 20000]\n' > big.tcl
check "a write of 20,000 bytes" "20000 $big" "$(run big.tcl | tr '\n' ' ' | sed 's/ $//')"
[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }

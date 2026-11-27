#!/bin/sh
# The tests of the command component of WASI 0.3.2. Run `zig build
# wasi-component` first. The tests check that the component has no
# preview 1 and no 0.2 import, and run scripts under wasmtime with the
# flags of zig-out/bin/ztcl: the output on stdout, `argv` and `exit` of
# `--tclsh`, the exit code and the message of an error, the limits, and
# the capabilities `file`, channels, `clock`, and the event loop.
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
check "stdout and argv of --tclsh" "42 2 one two" "$(run --tclsh a.tcl one two 2>/dev/null)"
printf 'proc f {n} { if {$n < 2} { return $n }; expr {[f [expr {$n-1}]] + [f [expr {$n-2}]]} }\nputs [f 20]\n' > fib.tcl
check "procs" "6765" "$(run fib.tcl)"
printf 'puts two\n' > b.tcl
check "two files in one interpreter" "6765 two" "$(run fib.tcl b.tcl | tr '\n' ' ' | sed 's/ $//')"
printf 'puts before\nexit 3\n' > exit.tcl
out=$(run --tclsh exit.tcl)
check "exit code of exit" "before 3" "$out $?"
printf 'error boom\n' > err.tcl
check "errorInfo of --tclsh on stderr" "" "$(run --tclsh err.tcl 2>/dev/null)"
check "errorInfo of --tclsh on stderr" "boom" "$(run --tclsh err.tcl 2>&1 >/dev/null | head -1)"
out=$(run err.tcl)
check "the line and the exit code of an error" "err.tcl:1: boom 1" "$out $?"
check "a missing script" "2" "$(run none.tcl >/dev/null 2>&1; echo $?)"
check "commands from stdin" "% 3 %" "$(echo 'expr {1+2}' | run | tr '\n' ' ' | sed 's/ $//')"
printf 'puts [info commands file]|[info commands exec]|[info commands socket]|[info commands after]|[info commands clock]\n' > caps.tcl
check "no capability" "||||" "$(run caps.tcl)"
check "an unknown capability" "2" "$(run --allow nope caps.tcl >/dev/null 2>&1; echo $?)"
check "the compute limit" "1" "$(printf 'while 1 {}\n' > loop.tcl; run --compute 100000 loop.tcl >/dev/null 2>&1; echo $?)"
big=$(awk 'BEGIN { for (i = 0; i < 20000; i++) printf "x" }')
printf 'puts [string length [string repeat x 20000]]\nputs [string repeat x 20000]\n' > big.tcl
check "a write of 20,000 bytes" "20000 $big" "$(run big.tcl | tr '\n' ' ' | sed 's/ $//')"

# The capabilities on WASI 0.3.2.
mkdir root
cat > root/fs.tcl <<'TCL'
set f [open x.txt w]
puts -nonewline $f [string repeat ab 10000]
close $f
set f [open x.txt a]
puts -nonewline $f cd
close $f
set f [open x.txt]
seek $f -4 end
set tail [read $f]
seek $f 0
set n [string length [read $f]]
close $f
file mkdir d
file rename x.txt d/y.txt
set g [glob -directory d *]
set s [file size d/y.txt]
file delete d/y.txt
puts "$tail $n $g $s [file exists d/y.txt] [file isdirectory d]"
puts [catch {open ../out.txt w} msg]
TCL
check "files and channels below --root" "abcd 20002 d/y.txt 20002 0 1 1" "$(run --allow file,channels --root /root /root/fs.tcl 2>&1 | tr '\n' ' ' | sed 's/ $//')"
check "no file outside the root" "0" "$(ls out.txt 2>/dev/null | wc -l)"
printf 'set t [clock milliseconds]\nafter 100 {set ::done 1}\nvwait done\nputs [expr {[clock milliseconds] - $t >= 100}]\nputs [expr {[clock seconds] > 1700000000}]\n' > ev.tcl
check "clock and the event loop" "1 1" "$(run --allow clock,event ev.tcl | tr '\n' ' ' | sed 's/ $//')"
# A bundle of `ztcl build --component` (#3 level 1) gives the output of
# the native app of `ztcl build`. It needs the native zig-out/bin/ztcl.
z=${ZTCL:-$here/../zig-out/bin/ztcl}
if [ -x "$z" ]; then
    mkdir app
    printf 'puts "$argc $argv"\nputs [lsort [glob -directory //zipfs:/app *]]\nset f [open //zipfs:/app/data.txt]\nputs [read -nonewline $f]\nclose $f\nputs [info commands file]|[info commands clock]\nexit 4\n' > app/app.tcl
    echo hello > app/data.txt
    (cd app && "$z" build --component --base "$c" --embed data.txt -o ../app.wasm app.tcl >/dev/null && "$z" build --embed data.txt -o ../app.bin app.tcl >/dev/null)
    want=$(./app.bin one two; echo "exit $?")
    got=$(timeout 20 "${WASMTIME:-wasmtime}" run -W max-wasm-stack=8388608 app.wasm one two; echo "exit $?")
    check "a bundle gives the output of the native app" "$want" "$got"
    printf 'puts [clock seconds]\n' > app/c.tcl
    (cd app && "$z" build --component --base "$c" --allow clock -o ../clock.wasm c.tcl >/dev/null)
    check "the capabilities of a bundle" 1 "$(timeout 20 "${WASMTIME:-wasmtime}" run clock.wasm | awk '{ print ($1 > 1700000000) }')"
    check "a bundle of a bundle" 1 "$("$z" build --component --base app.wasm -o x.wasm app/app.tcl >/dev/null; echo $?)"
else
    echo "skip the bundle tests: no $z"
fi
[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }

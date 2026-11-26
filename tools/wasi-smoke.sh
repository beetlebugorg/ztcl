#!/bin/sh
# The smoke tests of the WASI build. Run `zig build -Dtarget=wasm32-wasi`
# first. Each test runs zig-out/bin/ztcl.wasm under wasmtime through
# tools/wasi-run.sh and compares the output with the expected text.
#
# The tests: a script from stdin and from a file, the compute limit, the
# memory limit, the nesting limit, the commands of each capability that
# are absent by default, and `exec`, `thread`, and `socket`, which are
# absent also when `--allow` names them. With `--allow`, the tests use
# files and channels in a root folder, the checks of the jail, `clock`,
# and the event loop.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
run="$here/wasi-run.sh"
dir=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-wasi.XXXXXX") || exit 1
trap 'rm -rf -- "$dir"' EXIT
cd "$dir" || exit 1
fails=0
# check NAME EXPECTED ACTUAL
check() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        echo "  expected: $2"
        echo "  got:      $3"
        fails=$((fails + 1))
    fi
}
t() { timeout 20 "$run" "$@" 2>&1; }

check stdin '% 42' "$(printf 'puts [expr {6*7}]\n' | t | head -1)"
printf 'puts ok\n' > t.tcl
check file-absolute ok "$(t /t.tcl)"
check file-relative ok "$(t t.tcl)"
check step-limit '% error: compute limit reached' "$(printf 'while 1 {}\n' | t --compute 1000 | head -1)"
printf 'set l {}; while 1 {lappend l [string repeat x 1000]}\n' > m.tcl
check mem-limit '/m.tcl:1: the script used too much memory' "$(t --mem 1000000 /m.tcl)"
printf 'proc f {n} {f [incr n]}\ncatch {f 0} m\nputs $m\n' > n.tcl
check nest-limit 'too many nested evaluations (infinite loop?)' "$(t /n.tcl)"
cat > caps.tcl <<'TCL'
set out {}
foreach c {interp clock open file after vwait fileevent socket exec sqlite3 thread} {
    if {[llength [info commands $c]]} { lappend out $c }
}
if {[info exists ::env]} { lappend out env }
puts "present: $out"
TCL
check caps-default 'present: ' "$(t /caps.tcl)"
check caps-absent 'present: ' "$(t --allow exec,thread,socket /caps.tcl)"
mkdir -p root/sub
ln -s /etc root/out
ln -s /etc/passwd root/sub/pw
cat > root/files.tcl <<'TCL'
set f [open /a.txt w]; puts $f hello; close $f
set f [open a.txt]; puts -nonewline [gets $f]; close $f
puts " [lsort [glob *]] [file isdirectory sub] [file size a.txt]"
file mkdir d1/d2; file rename a.txt d1/b.txt
puts "[file exists d1/b.txt] [file delete -force d1][file exists d1]"
TCL
check files 'hello a.txt files.tcl out sub 1 6 1 0' "$(t --allow file,channels --root "$dir/root" "$dir/root/files.tcl" | tr '\n' ' ' | sed 's/ $//')"
cat > root/jail.tcl <<'TCL'
foreach p {../x /../x out/passwd sub/pw} { catch {open $p} m; puts $m }
catch {file rename files.tcl ../x} m; puts $m
TCL
check jail 'couldn'"'"'t open "../x": permission denied|couldn'"'"'t open "/../x": permission denied|couldn'"'"'t open "out/passwd": permission denied|couldn'"'"'t open "sub/pw": permission denied|couldn'"'"'t access "../x": permission denied' \
    "$(t --allow file,channels --root "$dir/root" "$dir/root/jail.tcl" | tr '\n' '|' | sed 's/|$//')"
printf 'puts [clock format 0 -gmt 1]\nafter 5 {set ::x 1}; vwait ::x; puts $::x\n' > ev.tcl
check clock-event 'Thu Jan 01 00:00:00 GMT 1970 1' "$(t --allow clock,event /ev.tcl | tr '\n' ' ' | sed 's/ $//')"
[ "$fails" -eq 0 ] && echo "wasi smoke ok" && exit 0
echo "wasi smoke: $fails failed"
exit 1

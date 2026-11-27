#!/bin/sh
# Builds each test package of tests/cext for wasm32-wasi with the stub
# library of the WebAssembly path, and runs each test script on tclsh
# and on the native ztcl, where `load DIR/NAME.so` loads DIR/NAME.wasm
# with `ztcl::wasm package` (docs/dev/cext-tasks/04e-wasm-engine.md).
# The two outputs of a script must be equal. Build first:
#   zig build install cext-stubs
#   tools/cext/engine-check.sh [NAME...]
# TCLSH names that tclsh (default tclsh), ZIG names zig, and ZTCL the
# runner (default zig-out/bin/ztcl).
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$here/../..
tclsh=${TCLSH:-tclsh}
zig=${ZIG:-zig}
ztcl=${ZTCL:-$root/zig-out/bin/ztcl}
cfg=$(echo 'puts [info library]' | "$tclsh")/tclConfig.sh
for c in "$cfg" /usr/lib/tclConfig.sh /usr/lib/tcl8.6/tclConfig.sh /usr/lib/x86_64-linux-gnu/tcl8.6/tclConfig.sh /usr/local/lib/tclConfig.sh /opt/homebrew/lib/tclConfig.sh; do
  [ -f "$c" ] && { cfg=$c; break; }
done
. "$cfg"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# The same skips as wasm-check.sh: cxchild needs the command interp, cxfile the channels of a
# package, and cxpanic and cxscript stop the process or run threads.
# cxthr uses the thread and command info slots of the native path.
skip=" cxchild cxfile cxpanic cxscript cxthr "
names=${*:-$(cd "$root/tests/cext" && ls *.tcl | sed 's/\.tcl$//')}
mkdir "$out/inc"
for h in tcl.h tclDecls.h tclPlatDecls.h; do
  cp "${TCL_INCLUDE_SPEC#-I}/$h" "$out/inc/"
done
exports=""
for e in buf args reply dispatch interp interp_free result precision; do
  exports="$exports -Wl,--export=ztcl_cext_$e"
done
fail=0
for n in $names; do
  case "$skip" in *" $n "*) [ $# -eq 0 ] && continue ;; esac
  init=$(echo "$n" | sed 's/^./\U&/')_Init
  # shellcheck disable=SC2086
  "$zig" cc -target wasm32-wasi -O1 -DUSE_TCL_STUBS -I"$out/inc" -mexec-model=reactor \
    "$root/tests/cext/$n.c" "$root/zig-out/lib/libztclstubs.a" -Wl,--export="$init" $exports -o "$out/$n.wasm"
  # shellcheck disable=SC2086
  cc -shared -fPIC -O1 -DUSE_TCL_STUBS $TCL_INCLUDE_SPEC "$root/tests/cext/$n.c" -o "$out/$n.so" $TCL_STUB_LIB_SPEC
  { echo "set dir $out"; cat "$root/tests/cext/$n.tcl"; } > "$out/$n.tcl"
  "$tclsh" "$out/$n.tcl" > "$out/$n.want" 2>&1 || true
  {
    echo 'package require ztcl::wasm'
    # The rules of `load` in Tcl: a file loads once, and a missing file
    # gives the text of dlopen.
    cat <<'EOT'
proc load {file args} {
    set p [lindex $args 0]
    if {[info exists ::loaded($file)]} {
        if {$p eq "" || [string tolower $p] eq [string tolower $::loaded($file)]} return
        error "file \"$file\" is already loaded for package \"$::loaded($file)\""
    }
    set w [string map {.so .wasm} $file]
    if {![file exists $w]} {
        error "couldn't load file \"$file\": $file: cannot open shared object file: No such file or directory"
    }
    set r [uplevel 1 [list ztcl::wasm package $w {*}$args]]
    if {$p eq ""} { set p [file rootname [file tail $file]] }
    set ::loaded($file) [string totitle $p]
    return $r
}
EOT
    cat "$out/$n.tcl"
  } > "$out/$n.ztcl"
  "$ztcl" --allow file,channels,event "$out/$n.ztcl" > "$out/$n.got" 2>&1 || true
  if diff -u "$out/$n.want" "$out/$n.got" > "$out/$n.diff"; then
    echo "$n: ok ($(wc -l < "$out/$n.want") lines)"
  else
    sed "s|$out|OUT|g" "$out/$n.diff" | head -40
    fail=1
  fi
done
exit $fail

#!/bin/sh
# Builds the WASI programs of this folder and runs each one with
# `ztcl::wasm run` of the native ztcl. Compares the output with the
# file NAME.out. With wasmtime on the PATH, also compares the output
# of wasmtime. A Go program runs only when tinygo is on the PATH.
#
#   tests/wasm/run.sh [path/to/ztcl]
#
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ztcl=${1:-$here/../../zig-out/bin/ztcl}
case $ztcl in /*) ;; *) ztcl=$PWD/$ztcl ;; esac
work=$(mktemp -d) || exit 1
[ -n "$KEEP" ] || trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
fail=0
zig cc -target wasm32-wasi -O2 -s "$here/hello.c" -o hello.wasm || exit 1
zig cc -target wasm32-wasi -O2 -s "$here/files.c" -o files.wasm || exit 1
zig build-exe -target wasm32-wasi -OReleaseSmall "$here/hello.zig" -femit-bin=zhello.wasm || exit 1
progs="hello files zhello"
if command -v tinygo > /dev/null; then
    tinygo build -target=wasip1 -o gohello.wasm "$here/hello.go" && progs="$progs gohello"
fi
for p in $progs; do
    mkdir -p "dir-$p"
    cat > "$p.tcl" <<EOT
package require ztcl::wasm
set code [ztcl::wasm run $work/$p.wasm -args {a b} -env {WHO me} -stdin "in line\n" -dirs {. $work/dir-$p}]
puts "exit \$code"
EOT
    "$ztcl" --allow file,channels "$p.tcl" > "$p.got" 2>&1
    if ! diff -u "$here/$p.out" "$p.got"; then
        echo "FAIL $p"; fail=1
    fi
    if command -v wasmtime > /dev/null; then
        mkdir -p "wt-$p"
        (cd "wt-$p" && printf 'in line\n' | wasmtime run --dir . --env WHO=me "../$p.wasm" a b > ../"$p.wt" 2>&1; echo "exit $?" >> ../"$p.wt")
        # The order of stdout and stderr in one file can differ.
        if [ "$(sort "$p.wt")" != "$(sort "$p.got" | sed "s|$work/||")" ]; then
            echo "FAIL $p: the output differs from wasmtime"; diff "$p.wt" "$p.got"; fail=1
        fi
    fi
done
[ $fail = 0 ] && echo "wasm programs: ok ($progs)"
exit $fail

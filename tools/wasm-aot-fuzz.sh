#!/bin/sh
# The differential fuzzer of procs compiled to wasm.
#
#   tools/wasm-aot-fuzz.sh [-s SEED] [-n COUNT] [-k SWEEP] [-g GC_STRESS]
#
# Writes COUNT programs of the generator of tools/jit-fuzz.zig, from
# seed SEED, and runs them with tools/wasm-aot.mjs: each program runs in
# the interpreter of ztcl-aot.wasm and on a module with each of its
# procs compiled, with SWEEP more step limits. The result, the output,
# the error, and the steps used must be equal. A difference prints the
# file, and the program stays in zig-out/wasm-aot-fuzz.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
seed=1; count=200; sweep=4; gc=
while getopts s:n:k:g: o; do
    case $o in
    s) seed=$OPTARG ;;
    n) count=$OPTARG ;;
    k) sweep=$OPTARG ;;
    g) gc="--gc-stress $OPTARG" ;;
    *) exit 2 ;;
    esac
done
cd "$here/.." || exit 1
dir=zig-out/wasm-aot-fuzz
rm -rf -- "$dir"
mkdir -p "$dir" || exit 1
zig build jit-fuzz -- --write "$dir" --seed "$seed" --count "$count" || exit 1
# Each program in its own call, so the list of files stays short.
bad=0
for f in "$dir"/prog-*.tcl; do
    out=$(node tools/wasm-aot.mjs --quiet --sweep "$sweep" $gc "$f") || { bad=$((bad + 1)); printf '%s\n' "$out"; }
done
echo "$count programs from seed $seed, $bad differ"
[ "$bad" -eq 0 ]

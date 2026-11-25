#!/bin/sh
# Runs zig-out/bin/ztcl.wasm under wasmtime with the arguments of
# zig-out/bin/ztcl, so `tools/suite.sh -r tools/wasi-run.sh` runs the
# suite under WASI.
#
# The current folder is the preopen `/`. Each argument that is the
# absolute path of a file or a folder gets a preopen of its folder at
# the same path, so the runner opens it by its absolute path. The
# runner picks the preopen with the longest prefix of the path.
#
# Wasmtime limits the native stack of wasm code to 512 KiB by default.
# The interpreter can use 5 MiB (`max_native`), so the limit is 8 MiB.
#
# `WASMTIME` names the wasmtime binary, and `ZTCL_WASM` the module.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
wasm=${ZTCL_WASM:-$here/../zig-out/bin/ztcl.wasm}
set -- "$@" --
dirs=
while [ "$1" != -- ]; do
    a=$1
    shift
    case $a in
    /*)
        if [ -d "$a" ]; then d=$a; elif [ -e "$a" ]; then d=$(dirname -- "$a"); else d=; fi
        if [ -n "$d" ] && [ "$d" != / ]; then
            case " $dirs " in *" $d "*) ;; *) dirs="$dirs $d" ;; esac
        fi
        ;;
    esac
    set -- "$@" "$a"
done
shift
pre="--dir .::/"
for d in $dirs; do pre="$pre --dir $d::$d"; done
# shellcheck disable=SC2086
exec "${WASMTIME:-wasmtime}" run -W max-wasm-stack=8388608 $pre "$wasm" "$@"

#!/bin/sh
# Fetches the data files and the outside C parsers of the benchmarks and
# checks the SHA-256 of each file. The repository has no copy of them.
#
#   bench/stdlib/fetch.sh [DIR]      (the default is zig-out/bench-data)
#
# Prints the folder.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dir=${1:-$here/../../zig-out/bench-data}
mkdir -p "$dir" || exit 1
dir=$(CDPATH= cd -- "$dir" && pwd)
# tcllib 2.0 for the json package of tclsh.
# SQLite 3.54.0 for the `sqlite3` package of tclsh and the C API row.
# The nativejson-benchmark data, at a fixed commit.
nj=https://raw.githubusercontent.com/miloyip/nativejson-benchmark/478d5727c2a4048e835a29c65adecc7d795360d5/data
sj=https://github.com/simdjson/simdjson/releases/download/v4.2.0
yy=https://raw.githubusercontent.com/ibireme/yyjson/0.12.0/src
while read -r name sum url; do
    f=$dir/$name
    if [ -f "$f" ] && echo "$sum  $f" | sha256sum -c --status 2>/dev/null; then continue; fi
    curl -sSfL --retry 3 -o "$f.part" "$url" || { echo "cannot fetch $url" >&2; exit 1; }
    if ! echo "$sum  $f.part" | sha256sum -c --status; then
        echo "the SHA-256 of $name does not match" >&2; rm -f "$f.part"; exit 1
    fi
    mv "$f.part" "$f"
done <<EOT
twitter.json a08b769f32b95f426cbc3abafcec65c1a19d3eb544d4ddf320eae142c99efc5d $nj/twitter.json
canada.json f83b3b354030d5dd58740c68ac4fecef64cb730a0d12a90362a7f23077f50d78 $nj/canada.json
citm_catalog.json a73e7a883f6ea8de113dff59702975e60119b4b58d451d518a929f31c92e2059 $nj/citm_catalog.json
simdjson.h f3a1e3ad2b74b099964b45482e8cea76c75c81a65addad3d5a5f0054456a9013 $sj/simdjson.h
simdjson.cpp 6e05f22c1c4666496e0cc51cbd08c0d7e3a28a21545f39a65d88f5e8bc61043a $sj/simdjson.cpp
yyjson.c ac2e9bbb2e2d9149d90878d40506a1d624fa0b33c979a11b61075c54782c6d6a $yy/yyjson.c
yyjson.h 175867c5493a5df648cec566717fa1c29aa2f6096f5f0cf1efad0b65e1f6d7b3 $yy/yyjson.h
tcllib.tar.gz c239f54cedc2fc11eb9fd5a7bbf2df1e12965937cd7fd1110e17383ec8f5e632 https://github.com/tcltk/tcllib/archive/refs/tags/tcllib-2-0.tar.gz
sqlite-autoconf-3540000.tar.gz 134ec0802dda5795816e25d25872d20b312cb3973438c49b30bc40b7705ea9ed https://sqlite.org/2026/sqlite-autoconf-3540000.tar.gz
EOT
echo "$dir"

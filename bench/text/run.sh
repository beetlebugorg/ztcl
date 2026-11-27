#!/bin/sh
# Compares the segmenters of ztcl::text with ICU on five texts of
# 1,000,000 bytes or more: English, French with accents, Chinese, Hindi,
# and emoji. It prints one TSV line per runtime, text, and unit: the
# count and the MB/s of UTF-8 input. ICU runs on UTF-16 that it gets
# before its clock starts.
#
#   bench/text/run.sh [OUT_DIR]
#
# SPDX-License-Identifier: BSD-2-Clause
set -eu
top=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-$top/zig-out/text-bench}
mkdir -p "$out"
python3 -I "$top/bench/text/texts.py" "$out"
cd "$top"
zig build text-bench -- "$out"/english.txt "$out"/french.txt "$out"/chinese.txt "$out"/hindi.txt "$out"/emoji.txt
if pkg-config --exists icu-uc; then
    cc -O2 bench/text/icu.c -o "$out/icu-bench" $(pkg-config --cflags --libs icu-uc)
    for t in english french chinese hindi emoji; do
        "$out/icu-bench" "$out/$t.txt" 5 | sed "s/^icu\t/icu\t$t\t/"
    done
fi

#!/bin/sh
# Reports the size of each built-in module and checks the budget.
#
#   tools/size-report.sh [--check] [--plant BYTES] [--out DIR] [--no-wasm]
#
# The script builds the runner with -Dbatteries=core, with full, and with
# full and each module off, each with -Dstrip=true. The size of a module
# is the full size minus the size without it. The row "table" is the rest:
# the full size minus the core size minus the sum of the modules. The
# script also builds ztcl.wasm (ReleaseSmall) with the modules and with
# -Dbatteries=core.
#
# It writes size.md (Markdown) and size.tsv to DIR (the default is
# zig-out/size). --check compares the numbers with the goals in
# tools/size-budget.tsv and writes a warning when:
#   - the full runner is above 6,850,000 bytes (x86-64 Linux only),
#   - a module is more than 10 % above its row,
#   - ztcl.wasm with modules is above 1,600,000 bytes, or the wasm build
#     with no module is above 1,000,000 bytes.
# The sizes are goals, not gates: a row over its goal does not fail the
# job. Add --strict to exit with 1 when a row is over its goal.
# --plant BYTES adds that many bytes of data to the test module hello,
# to show the warning.
#
# On macOS, the size of a runner is the sum of the sizes of its sections
# (`size -m`). The file of a Mach-O binary grows in pages of 16 KiB on
# arm64, so the difference of two file sizes is 0 or a whole page.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
top=$here/..
check=; strict=; plant=0; out=$top/zig-out/size; wasm=1
while [ $# -gt 0 ]; do
    case $1 in
    --check) check=1 ;;
    --strict) check=1; strict=1 ;;
    --plant) plant=$2; shift ;;
    --out) out=$2; shift ;;
    --no-wasm) wasm= ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
mkdir -p "$out" || exit 1
cd "$top" || exit 1
# The modules of build.zig: the rows of `all_modules`.
mods=$(sed -n '/^const all_modules = /,/^};/p' build.zig | sed -n 's/.*\.name = "\([^"]*\)".*/\1/p')
exe=ztcl; case $(uname -s) in MINGW*|MSYS*|CYGWIN*|Windows*) exe=ztcl.exe ;; esac
size_of() {
    case $1 in
    *.wasm) wc -c < "$1" | tr -d ' ' ;;
    *) if [ "$(uname -s)" = Darwin ]; then
           size -m "$1" | awk '/^[[:space:]]*Section / { s += $3 } END { print s }'
       else
           wc -c < "$1" | tr -d ' '
       fi ;;
    esac
}
build() { # name, flags...
    n=$1; shift
    zig build -Doptimize=ReleaseFast -Dstrip=true -Dsize-plant="$plant" --prefix "$out/$n" "$@" >"$out/$n.log" 2>&1 || {
        echo "the build $n failed:" >&2; cat "$out/$n.log" >&2; exit 1; }
    size_of "$out/$n/bin/$exe"
}
# Start each build in the background first, ${SIZE_JOBS:-4} at a time,
# so that the builds run in parallel. The builds below then find their
# files in the Zig cache. A failed build fails again below, with its log.
jobs=${SIZE_JOBS:-4}; started=0
start() { # name, flags of zig build...
    n=$1; shift
    zig build "$@" >"$out/$n.log" 2>&1 &
    started=$((started + 1))
    if [ $((started % jobs)) -eq 0 ]; then wait; fi
}
start core -Dstrip=true -Dsize-plant="$plant" --prefix "$out/core" -Dbatteries=core
start full -Dstrip=true -Dsize-plant="$plant" --prefix "$out/full" -Dbatteries=full
for m in $mods; do
    start "no-$m" -Dstrip=true -Dsize-plant="$plant" --prefix "$out/no-$m" -Dbatteries=full "-Dmod-$m=false"
done
if [ -n "$wasm" ]; then
    start wasm wasm -Dsize-plant="$plant" --prefix "$out/wasm"
    start wasm-core wasm -Dbatteries=core --prefix "$out/wasm-core"
fi
wait
core=$(build core -Dbatteries=core) || exit 1
full=$(build full -Dbatteries=full) || exit 1
printf 'row\tbytes\n' > "$out/size.tsv"
printf 'core\t%s\nfull\t%s\n' "$core" "$full" >> "$out/size.tsv"
rest=$((full - core))
for m in $mods; do
    without=$(build "no-$m" -Dbatteries=full "-Dmod-$m=false") || exit 1
    printf '%s\t%s\n' "$m" $((full - without)) >> "$out/size.tsv"
    rest=$((rest - (full - without)))
done
printf 'table\t%s\n' "$rest" >> "$out/size.tsv"
if [ -n "$wasm" ]; then
    zig build wasm -Dsize-plant="$plant" --prefix "$out/wasm" >"$out/wasm.log" 2>&1 || { cat "$out/wasm.log" >&2; exit 1; }
    zig build wasm -Dbatteries=core --prefix "$out/wasm-core" >"$out/wasm-core.log" 2>&1 || { cat "$out/wasm-core.log" >&2; exit 1; }
    printf 'wasm\t%s\nwasm-core\t%s\n' "$(size_of "$out/wasm/lib/ztcl.wasm")" "$(size_of "$out/wasm-core/lib/ztcl.wasm")" >> "$out/size.tsv"
fi
# The table and the check.
target=$(uname -sm)
awk -F'\t' -v check="$check" -v target="$target" -v md="$out/size.md" '
/^#/ || $1 == "row" { next }
FILENAME ~ /size-budget/ { budget[$1] = $2; note[$1] = $3; next }
{ row[++n] = $1; bytes[$1] = $2 }
END {
    print "| Row | Bytes | Budget | Limit (+10 %) | Status |" > md
    print "|---|---:|---:|---:|---|" > md
    bad = 0
    for (i = 1; i <= n; i++) {
        r = row[i]; b = bytes[r]; lim = ""; st = ""
        if (r == "full") { lim = 6850000; if (target != "Linux x86_64") lim = "" }
        else if (r == "wasm") lim = 1600000
        else if (r == "wasm-core") lim = 1000000
        else if (r != "core" && (r in budget)) lim = int(budget[r] * 1.1)
        if (lim != "") { st = (b + 0 <= lim + 0) ? "ok" : "over"; if (st == "over") bad = 1 }
        printf "| %s | %d | %s | %s | %s |\n", r, b, (r in budget) ? budget[r] : "", lim, st > md
    }
    close(md)
    if (check && bad) exit 1
}' "$here/size-budget.tsv" "$out/size.tsv"
rc=$?
cat "$out/size.md"
if [ -n "$GITHUB_STEP_SUMMARY" ]; then
    { echo "### Size of the runner and the modules ($target)"; echo; cat "$out/size.md"; } >> "$GITHUB_STEP_SUMMARY"
fi
if [ -n "$check" ] && [ $rc -ne 0 ]; then
    if [ -n "$GITHUB_ACTIONS" ]; then
        echo "::warning title=Size::a row is over its size goal (see the job summary)"
    fi
    echo "size: a row is over its goal" >&2
    [ -n "$strict" ] && exit 1
fi
exit 0

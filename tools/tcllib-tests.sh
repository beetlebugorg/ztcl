#!/bin/sh
# Runs test files of tcllib 2.0 on ztcl, over the built-in modules.
#
#   tools/tcllib-tests.sh [-r runner] name ...      (for example json json_write)
#
# The script fetches tcllib 2.0 with a SHA-256 check to zig-out/tcllib,
# checks that its license is the BSD-style license of tcllib, and runs
# each file modules/MODULE/NAME.test with tools/tcltest.tcl. The module
# of a name is the part before "_". The commands of the tcllib test
# harness (devtools/testutilities.tcl) come from tools/tcllib-shim.tcl,
# which loads the package with `package require` from the built-in
# modules. The repository has no copy of tcllib.
#
# Prints one line for each file with the counts, then the names of the
# tests that fail. Exits with 1 when a file stops before its end.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tcl=$here/../zig-out/bin/ztcl
while getopts r: o; do
    case $o in
    r) tcl=$OPTARG ;;
    *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
case $tcl in /*) ;; *) tcl=$PWD/$tcl ;; esac
dir=$here/../zig-out/tcllib
url=https://github.com/tcltk/tcllib/archive/refs/tags/tcllib-2-0.tar.gz
sum=c239f54cedc2fc11eb9fd5a7bbf2df1e12965937cd7fd1110e17383ec8f5e632
if [ ! -d "$dir/modules" ]; then
    mkdir -p "$dir" || exit 1
    curl -sSfL --retry 3 -o "$dir/tcllib.tar.gz" "$url" || exit 1
    echo "$sum  $dir/tcllib.tar.gz" | sha256sum -c --status || { echo "the SHA-256 of tcllib does not match" >&2; exit 1; }
    tar xzf "$dir/tcllib.tar.gz" -C "$dir" --strip-components=1 || exit 1
    rm -f "$dir/tcllib.tar.gz"
fi
# Rule 9 of the tasks: the test files run only under the license of tcllib.
grep -q 'The authors hereby grant permission to use, copy, modify, distribute' "$dir/license.terms" || {
    echo "the license of tcllib is not the expected BSD-style license" >&2; exit 1; }
rc=0
for name in "$@"; do
    mod=${name%%_*}
    root=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-tcllib.XXXXXX") || exit 1
    mkdir -p "$root/modules"
    cp -R "$dir/modules/$mod" "$root/modules/$mod"
    # The test file reads its data files from the folder of the module.
    printf 'cd /modules/%s\n' "$mod" > "$root/cd.tcl"
    out=$(timeout 600 "$tcl" --tcl 8.6 --compute 2000000000 --mem 2147483648 --allow channels,file,clock \
        --root "$root" "$root/cd.tcl" "$here/tcltest.tcl" "$here/tcllib-shim.tcl" \
        "$root/modules/$mod/$name.test" "$here/tcltest-end.tcl" 2>&1)
    rm -rf -- "$root"
    line=$(printf '%s\n' "$out" | grep -aE '^pass [0-9]+ fail' | tail -1)
    printf '%-16s %s\n' "$name.test" "${line:-no result (the file stopped early)}"
    printf '%s\n' "$out" | grep -aE '^FAIL ' | sed 's/^/    /'
    [ -n "$line" ] || { printf '%s\n' "$out" | tail -5; rc=1; }
done
exit $rc

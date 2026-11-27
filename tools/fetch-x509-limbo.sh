#!/bin/sh
# Downloads limbo.json of x509-limbo and checks its SHA-256. Prints the
# path of the file.
#
#   tools/fetch-x509-limbo.sh [DIR]      (the default is zig-out/limbo)
#   zig build tls-x509-test -- "$(tools/fetch-x509-limbo.sh)"
#
# The file is from a fixed commit of github.com/C2SP/x509-limbo
# (Apache-2.0). The repository has no copy of it.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dir=${1:-$here/../zig-out/limbo}
mkdir -p "$dir" || exit 1
dir=$(CDPATH= cd -- "$dir" && pwd)
url=https://raw.githubusercontent.com/C2SP/x509-limbo/b12423782a88abead01141fa6582254e3eb49e74/limbo.json
sum=56799cefd65fc9e0bdb9cb0f97fce6734533b45df3de4fc17fdc7b7b79654fca
f=$dir/limbo.json
if ! { [ -f "$f" ] && echo "$sum  $f" | sha256sum -c --status 2>/dev/null; }; then
    curl -sSfL --retry 3 -o "$f.part" "$url" || { echo "cannot fetch limbo.json" >&2; exit 1; }
    if ! echo "$sum  $f.part" | sha256sum -c --status; then
        echo "the SHA-256 of limbo.json does not match" >&2; rm -f "$f.part"; exit 1
    fi
    mv "$f.part" "$f"
fi
echo "$f"

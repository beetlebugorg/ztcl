#!/bin/sh
# Downloads the benchmark files of kostya/benchmarks into .kostya/ and
# prints the path.
#
#   tools/fetch-kostya.sh
#
# The commit is pinned. The folder is ignored by git. The files are MIT
# licensed and stay outside the repository.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
commit=5bc68b3705fddd0fdb16b8748c4f2c73e1032a43
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dest="$root/.kostya"
if [ ! -f "$dest/COMMIT" ] || [ "$(cat "$dest/COMMIT")" != "$commit" ]; then
    rm -rf "$dest"
    mkdir -p "$dest"
    curl -fsSL "https://github.com/kostya/benchmarks/archive/$commit.tar.gz" |
        tar -xz --strip-components=1 -C "$dest" \
            --wildcards '*/brainfuck/*' '*/base64/*'
    echo "$commit" > "$dest/COMMIT"
fi
echo "$dest"

#!/bin/sh
# Downloads a Tcl source release into .tcl-src/<tag> and prints the path.
#
#   tools/fetch-tcl.sh [tag]
#
# The default tag is core-8-6-16. The folder is ignored by git.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
tag=${1:-core-8-6-16}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dest="$root/.tcl-src/$tag"
if [ ! -d "$dest/tests" ]; then
    mkdir -p "$dest"
    curl -fsSL "https://github.com/tcltk/tcl/archive/refs/tags/$tag.tar.gz" |
        tar -xz --strip-components=1 -C "$dest"
fi
echo "$dest"

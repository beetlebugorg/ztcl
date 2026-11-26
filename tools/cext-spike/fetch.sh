#!/bin/sh
# Downloads the SQLite 3.54.1 sources into $SPIKE (default
# ~/.cache/cext-spike), checks the SHA3-256 hash, and makes the Tcl
# binding in one file, $SPIKE/bld/tclsqlite3.c. Also fetches the Tcl
# 8.6.16 sources with tools/fetch-tcl.sh. The sources are data for the
# spike of docs/dev/cext-tasks/ and are not part of ztcl.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SPIKE=${SPIKE:-$HOME/.cache/cext-spike}
sum=877c6f4996ce7adb368686bce21638de9e3d91534832ad3d9d119037d1bc22ad
mkdir -p "$SPIKE/src" "$SPIKE/bld"
"$here/../fetch-tcl.sh" core-8-6-16 >/dev/null
cd "$SPIKE/src"
if [ ! -d sqlite-src-3540100 ]; then
  curl -sSfL -o sqlite.zip https://sqlite.org/2026/sqlite-src-3540100.zip
  got=$(python3 -I -c 'import hashlib,sys;print(hashlib.sha3_256(open(sys.argv[1],"rb").read()).hexdigest())' sqlite.zip)
  [ "$got" = "$sum" ] || { echo "sqlite.zip: bad hash $got" >&2; exit 1; }
  unzip -q sqlite.zip
fi
cd "$SPIKE/bld"
[ -f Makefile ] || ../src/sqlite-src-3540100/configure --with-tcl=/usr/lib >cfg.log 2>&1
[ -f tclsqlite3.c ] || make tclsqlite3.c >mk.log 2>&1
echo "$SPIKE/bld/tclsqlite3.c"

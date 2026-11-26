#!/bin/sh
# Downloads the corpus of Tcl C packages of docs/dev/cext.md, checks the
# SHA-256 hash of each archive, and runs corpus.py on it.
#   tools/cext/corpus.sh [DIR]   (default ~/.cache/cext-corpus)
# The SQLite binding is the tclsqlite3.c of tools/cext-spike/fetch.sh.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dir=${1:-$HOME/.cache/cext-corpus}
mkdir -p "$dir"
cd "$dir"
get() { # name url sha256 untar-flag
  [ -f "$1" ] || curl -sSfL -o "$1" "$2"
  echo "$3  $1" | sha256sum -c --quiet -
  tar "$4" "$1"
}
get tcl.tgz https://prdownloads.sourceforge.net/tcl/tcl8.6.16-src.tar.gz 91cb8fa61771c63c262efb553059b7c7ad6757afa5857af6265e4b0bdc2a14a5 -xzf
get tcltls.tgz https://core.tcl-lang.org/tcltls/uv/tcltls-1.7.22.tar.gz e84e2b7a275ec82c4aaa9d1b1f9786dbe4358c815e917539ffe7f667ff4bc3b4 -xzf
get memchan.tgz https://sourceforge.net/projects/memchan/files/memchan/2.3/Memchan2.3.tar.gz/download adaa5952fe532a917372dcdbc873c082656c49b613d92b09e7938d8f276f2749 -xzf
get tclx.tbz https://sourceforge.net/projects/tclx/files/TclX/8.4.1/tclx8.4.1.tar.bz2/download a9b41f606ec6c1268b9c78512e6e1cb533bd9ae3e786e650d111fc16ffe758ec -xjf
mkdir -p sqlite
spike=${SPIKE:-$HOME/.cache/cext-spike}
[ -f "$spike/bld/tclsqlite3.c" ] && cp "$spike/bld/tclsqlite3.c" "$spike/bld/sqlite3.h" sqlite/
p=tcl8.6.16/pkgs
python3 -I "$here/corpus.py" tcl8.6.16 sqlite $p/itcl4.3.2 $p/tdbc1.1.10 $p/tdbcmysql1.1.10 \
  $p/tdbcodbc1.1.10 $p/tdbcpostgres1.1.10 $p/thread2.8.11 tcltls-1.7.22 Memchan2.3 tclx8.4 > counts.tsv
echo "$dir/counts.tsv"

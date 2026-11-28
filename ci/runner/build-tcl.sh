#!/bin/sh
# Builds Tcl 8.6.16 from its source release for the comparisons of CI
# with tclsh (tools/cext/*.sh, tools/libztcl/*.sh). The tests expect the
# behavior of 8.6.16, and Ubuntu 24.04 has 8.6.14.
#
#   ci/runner/build-tcl.sh DESTDIR
#
# The files go to DESTDIR/usr/local: bin/tclsh8.6, lib/libtcl8.6.so,
# lib/libtclstub8.6.a, lib/tclConfig.sh, and include/tcl.h. Copy them to
# /usr/local and run ldconfig. The Dockerfile of the CI image and the
# jobs on the runners of GitHub use this script. Tcl is under a BSD
# license (license.terms of the release).
# SPDX-License-Identifier: BSD-2-Clause
set -eu
dest=${1:?usage: build-tcl.sh DESTDIR}
version=8.6.16
sha256=91cb8fa61771c63c262efb553059b7c7ad6757afa5857af6265e4b0bdc2a14a5
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -sSfL -o "$work/tcl.tar.gz" "https://prdownloads.sourceforge.net/tcl/tcl$version-src.tar.gz"
echo "$sha256  $work/tcl.tar.gz" | sha256sum -c -
tar -xzf "$work/tcl.tar.gz" -C "$work"
cd "$work/tcl$version/unix"
# Ubuntu has /usr/local/man as a link to share/man.
./configure --prefix=/usr/local --mandir=/usr/local/share/man --enable-shared > /dev/null
make -j"$(nproc)" > /dev/null
make install DESTDIR="$dest" > /dev/null
# The tests call it tclsh8.6, and some tools call tclsh.
ln -sf tclsh8.6 "$dest/usr/local/bin/tclsh"
echo "built Tcl $version in $dest/usr/local"

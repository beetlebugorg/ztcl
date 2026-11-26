#!/bin/sh
# Runs test.tcl with zig-out/bin/ztcl, signed ad hoc with the
# virtualization entitlement, in GUESTDIR (Image and agent.cpio, from
# the vm-guest artifact and pack.sh).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dir=${1:?usage: test.sh GUESTDIR}
bin=$dir/ztcl-vm
cp "$here/../../zig-out/bin/ztcl" "$bin"
codesign --force --sign - --entitlements "$here/vz.entitlements" "$bin"
cd "$dir"
exec ./ztcl-vm --root . --allow vm,file,channels,clock "$here/test.tcl"

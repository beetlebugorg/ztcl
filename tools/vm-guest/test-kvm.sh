#!/bin/sh
# Runs test-kvm.tcl with zig-out/bin/ztcl in GUESTDIR (bzImage, vmlinux,
# and agent.cpio, from the vm-guest-x86_64 artifact and
# `TARGET=x86_64-linux-musl pack.sh`). KERNEL=vmlinux boots the ELF
# kernel instead of the bzImage. Without access to /dev/kvm and
# /dev/vhost-vsock, it exits 0 with the reason.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dir=${1:?usage: test-kvm.sh GUESTDIR}
for dev in /dev/kvm /dev/vhost-vsock; do
    if [ ! -r "$dev" ] || [ ! -w "$dev" ]; then
        echo "skip: no read and write access to $dev"
        exit 0
    fi
done
cd "$dir"
# The runner gives a script no environment, so the name of the kernel
# goes in a file.
printf %s "${KERNEL:-bzImage}" > kernel.name
"$here/../../zig-out/bin/ztcl" --root . --allow vm,file,channels,clock,event,socket "$here/test-kvm.tcl"
# The snapshots, restores, and clones (ztcl#468).
exec "$here/../../zig-out/bin/ztcl" --root . --allow vm,file,channels,clock,event "$here/test-kvm-snapshot.tcl"

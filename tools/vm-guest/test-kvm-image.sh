#!/bin/sh
# The boot test of `ztcl::vm create -image` on KVM: RELDIR is a test
# release (the artifact vm-image-test, or fetch-test-image.sh), and
# zig-out/bin/ztcl (or ZTCL) is a build with -Dvm-test-key. The guest
# boots its root disk through dm-verity. Then a change of one byte of the
# root disk in the store gives a guest with no agent. Without access to
# /dev/kvm and /dev/vhost-vsock, it exits 0 with the reason.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
rel=$(cd "${1:?usage: test-kvm-image.sh RELDIR}" && pwd)
for dev in /dev/kvm /dev/vhost-vsock; do
    if [ ! -r "$dev" ] || [ ! -w "$dev" ]; then
        echo "skip: no read and write access to $dev"
        exit 0
    fi
done
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
cp -r "$rel" "$work/rel"
ztcl=${ZTCL:-$here/../../zig-out/bin/ztcl}
export ZTCL_VM_IMAGES="$work/store"
cd "$work"
printf good > mode
"$ztcl" --root . --allow vm,file,channels,clock "$here/test-kvm-image.tcl"
# One byte of the root disk in the store changes, after the install
# checked its SHA-256: dm-verity in the guest refuses the block.
obj="$work/store/objects/$(sha256sum rel/x86_64-root.img | cut -d' ' -f1)"
chmod u+w "$obj"
printf '\377' | dd of="$obj" bs=1 seek=0 conv=notrunc 2>/dev/null
printf bad > mode
"$ztcl" --root . --allow vm,file,channels,clock "$here/test-kvm-image.tcl"

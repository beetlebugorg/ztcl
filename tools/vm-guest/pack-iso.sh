#!/bin/sh
# Makes iso.cpio, the initramfs of the guest of `thread::create -isolation
# vm` (ztcl#468): the ztcl runner as /sbin/ztcl, the first process of the
# guest, and an empty /dev. RUNNER is a static ztcl runner for the guest
# (default zig-out/bin/ztcl of an x86-64 Linux build), and OUT the folder of
# iso.cpio. The runner of the host then gets the guest with
#   ZTCL_VM_ISO_KERNEL=bzImage ZTCL_VM_ISO_INITRD=OUT/iso.cpio
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$here/out}
runner=${RUNNER:-$here/../../zig-out/bin/ztcl}
root=$(mktemp -d)
mkdir -p "$root/sbin" "$root/dev" "$out"
objcopy --strip-all "$runner" "$root/sbin/ztcl" 2>/dev/null || cp "$runner" "$root/sbin/ztcl"
chmod +x "$root/sbin/ztcl"
(cd "$root" && find . | cpio -o -H newc 2>/dev/null) > "$out/iso.cpio"
rm -rf "$root"
ls -l "$out/iso.cpio"

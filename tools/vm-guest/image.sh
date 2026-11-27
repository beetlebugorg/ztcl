#!/bin/sh
# Makes the signed-image files of one architecture (ARCH arm64 or
# x86_64) from out/ of build.sh, on Linux with Zig, squashfs-tools, and
# cryptsetup (veritysetup):
#   out/root.img     a squashfs root (BusyBox and the agent) with its
#                    dm-verity hash tree after the data
#   out/ARCH.json    the entry of the architecture for manifest.sh: the
#                    kernel, the disk, its verity parameters, and the
#                    command line, with the SHA-256 of each file
# The same inputs give the same bytes: fixed times, owners, and salt.
# The names of the files of a release are flat (ARCH-Image,
# ARCH-root.img), as the assets of a GitHub release are.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$here/out}
arch=${ARCH:-arm64}
case $arch in
    arm64) zt=aarch64 kernel=Image ;;
    x86_64) zt=x86_64 kernel=bzImage ;;
    *) echo "ARCH must be arm64 or x86_64" >&2; exit 2 ;;
esac
# A fixed salt: the salt only keeps one tree from matching another, and a
# fixed one keeps the build reproducible.
salt=$(printf 'ztcl-guest-%s' "$arch" | sha256sum | cut -c1-64)
root=$(mktemp -d)
mkdir -p "$root/bin" "$root/sbin" "$root/dev" "$root/proc" "$root/sys" "$root/tmp" "$root/mnt" "$root/run" "$root/etc"
# The root is read-only: the agent writes the name server of -net nat in
# /run, a tmpfs, and /etc/resolv.conf points there.
ln -s /run/resolv.conf "$root/etc/resolv.conf"
zig build-exe -target $zt-linux-musl -OReleaseSmall -fstrip "$here/agent.zig" -femit-bin="$root/sbin/agent"
rm -f "$root/sbin/agent.o"
cp "$out/busybox" "$root/bin/busybox"
chmod 755 "$root/bin/busybox" "$root/sbin/agent"
rm -f "$out/root.img"
mksquashfs "$root" "$out/root.img" -noappend -all-root -no-xattrs -comp gzip \
    -mkfs-time 0 -all-time 0 -reproducible -quiet
rm -rf "$root"
# The data fills whole blocks of 4,096 bytes, and the tree starts after it.
size=$(stat -c %s "$out/root.img")
blocks=$(( (size + 4095) / 4096 ))
data=$(( blocks * 4096 ))
truncate -s "$data" "$out/root.img"
veritysetup format "$out/root.img" "$out/root.img" --hash-offset="$data" --no-superblock \
    --salt="$salt" --data-block-size=4096 --hash-block-size=4096 --hash=sha256 > "$out/verity.txt"
hash=$(sed -n 's/^Root hash:[[:space:]]*//p' "$out/verity.txt")
[ ${#hash} -eq 64 ] || { echo "no root hash" >&2; exit 1; }
# The device of dm-verity is the root, read-only: data and tree on
# /dev/vda, the tree from block `blocks` (no superblock).
table="0 $(( blocks * 8 )) verity 1 /dev/vda /dev/vda 4096 4096 $blocks $blocks sha256 $hash $salt"
cmdline="init=/sbin/agent root=/dev/dm-0 rootfstype=squashfs ro dm-mod.waitfor=/dev/vda dm-mod.create=\"root,,,ro,$table\" quiet"
sum() { sha256sum "$1" | cut -c1-64; }
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
cat > "$out/$arch.json" <<JSON
{"kernel":{"file":"$arch-$kernel","sha256":"$(sum "$out/$kernel")"},"cmdline":"$(esc "$cmdline")","disks":[{"name":"root","file":"$arch-root.img","sha256":"$(sum "$out/root.img")","size":$(stat -c %s "$out/root.img"),"read_only":true,"verity":{"root_hash":"$hash","salt":"$salt","data_block":4096,"hash_block":4096,"hash_offset":$data}}]}
JSON
echo "$arch: kernel $(sum "$out/$kernel")"
echo "$arch: root.img $(sum "$out/root.img")"
echo "$arch: verity root hash $hash"

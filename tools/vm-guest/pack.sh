#!/bin/sh
# Makes out/initramfs.cpio.gz from out/busybox, the agent, and init, on
# any host with Zig, cpio, and gzip.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$here/out}
root=$(mktemp -d)
mkdir -p "$root/bin" "$root/sbin" "$root/dev"
cp "$out/busybox" "$root/bin/busybox"
chmod +x "$root/bin/busybox"
zig build-exe -target aarch64-linux-musl -OReleaseSmall -fstrip "$here/agent.zig" -femit-bin="$root/sbin/agent"
cp "$here/init" "$root/init"
(cd "$root" && find . | cpio -o -H newc 2>/dev/null) | gzip -9 > "$out/initramfs.cpio.gz"
rm -rf "$root"
ls -l "$out/initramfs.cpio.gz"

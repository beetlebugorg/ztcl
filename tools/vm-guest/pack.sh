#!/bin/sh
# Makes the initramfs files of the spike guest from out/busybox, the
# agent, and init, on any host with Zig, cpio, and gzip. TARGET is the
# Zig target of the agent (aarch64-linux-musl, or x86_64-linux-musl for
# KVM):
#   out/initramfs.cpio.gz  BusyBox, init (a shell script), and the agent
#   out/agent.cpio         the agent alone, as /sbin/agent, uncompressed
#   out/agent.cpio.gz      the same, with gzip
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$here/out}
root=$(mktemp -d)
mkdir -p "$root/bin" "$root/sbin" "$root/dev" "$root/mnt/share"
zig build-exe -target "${TARGET:-aarch64-linux-musl}" -OReleaseSmall -fstrip "$here/agent.zig" -femit-bin="$root/sbin/agent"
rm -f "$root/sbin/agent.o"
(cd "$root" && find . | cpio -o -H newc 2>/dev/null) > "$out/agent.cpio"
gzip -9 < "$out/agent.cpio" > "$out/agent.cpio.gz"
cp "$out/busybox" "$root/bin/busybox"
chmod +x "$root/bin/busybox"
cp "$here/init" "$root/init"
(cd "$root" && find . | cpio -o -H newc 2>/dev/null) | gzip -9 > "$out/initramfs.cpio.gz"
rm -rf "$root"
ls -l "$out"/*.cpio*

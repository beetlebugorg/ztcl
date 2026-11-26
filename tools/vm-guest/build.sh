#!/bin/sh
# Builds the kernel and BusyBox of the spike guest of ztcl::vm (ztcl#203)
# on arm64 Linux: out/Image (an uncompressed arm64 kernel, the format of
# VZLinuxBootLoader) and out/busybox (static).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KERNEL=${KERNEL:-6.12.10}
BUSYBOX=${BUSYBOX:-1.37.0}
work=${WORK:-$here/work}
out=${OUT:-$here/out}
mkdir -p "$work" "$out"
cd "$work"

curl -fsSLO "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL.tar.xz"
curl -fsSLO "https://busybox.net/downloads/busybox-$BUSYBOX.tar.bz2"
sha256sum "linux-$KERNEL.tar.xz" "busybox-$BUSYBOX.tar.bz2"
tar xf "linux-$KERNEL.tar.xz"
tar xf "busybox-$BUSYBOX.tar.bz2"

cd "linux-$KERNEL"
make tinyconfig
./scripts/kconfig/merge_config.sh -m .config "$here/kernel.fragment"
make olddefconfig
# The options of the fragment that the merge dropped, for the log.
grep -v '^#' "$here/kernel.fragment" | grep . | while read -r opt; do
    grep -qx "$opt" .config || echo "missing: $opt"
done
make -j"$(nproc)" Image
cp arch/arm64/boot/Image "$out/Image"
cp .config "$out/kernel.config"
cd ..

cd "busybox-$BUSYBOX"
make defconfig
sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
make -j"$(nproc)" busybox
cp busybox "$out/busybox"
ls -l "$out"

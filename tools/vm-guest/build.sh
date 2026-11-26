#!/bin/sh
# Builds the kernel and BusyBox of the spike guest of ztcl::vm (ztcl#203)
# on arm64 Linux: out/Image (an uncompressed arm64 kernel, the format of
# VZLinuxBootLoader) and out/busybox (static).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
KERNEL=${KERNEL:-6.12.10}
BUSYBOX=${BUSYBOX:-1.37.0}
# The SHA-256 of each archive, from the first build.
KERNEL_SHA=4a516e5ed748537a73cb42ec47fbbeb6df8b1298e8892c29c0e91de79095b297
BUSYBOX_SHA=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4
work=${WORK:-$here/work}
out=${OUT:-$here/out}
mkdir -p "$work" "$out"
cd "$work"

curl -fsSLO "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL.tar.xz"
curl -fsSLO "https://busybox.net/downloads/busybox-$BUSYBOX.tar.bz2"
printf '%s  %s\n%s  %s\n' "$KERNEL_SHA" "linux-$KERNEL.tar.xz" "$BUSYBOX_SHA" "busybox-$BUSYBOX.tar.bz2" | sha256sum -c
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
# The SHA code for the SHA-NI of x86 does not build on arm64.
sed -i 's/^CONFIG_SHA1_HWACCEL=y/# CONFIG_SHA1_HWACCEL is not set/' .config
sed -i 's/^CONFIG_SHA256_HWACCEL=y/# CONFIG_SHA256_HWACCEL is not set/' .config
yes "" | make oldconfig >/dev/null
make -j"$(nproc)" busybox
cp busybox "$out/busybox"
ls -l "$out"

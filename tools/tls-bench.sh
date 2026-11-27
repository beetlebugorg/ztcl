#!/bin/sh
# Prints the speed of the TLS record layer of ztcl (zig build tls-bench)
# for the native CPU and for the baseline CPU, and `openssl speed -evp`
# for the same AEADs on records of 16,384 bytes. openssl prints k as
# 1000 bytes per second.
#
#   tools/tls-bench.sh
#
# SPDX-License-Identifier: BSD-2-Clause
set -eu
cd "$(dirname -- "$0")/.."
for cpu in native baseline; do
    echo "ztcl, -Dcpu=$cpu"
    zig build tls-bench -Dcpu=$cpu 2>&1
done
echo "$(openssl version)"
for a in aes-128-gcm aes-256-gcm chacha20-poly1305; do
    openssl speed -evp $a -bytes 16384 -seconds 2 2>/dev/null | tail -n 1
done

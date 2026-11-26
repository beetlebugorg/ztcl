#!/bin/sh
# Builds the macOS spike of ztcl::vm, signs it ad hoc with the
# virtualization entitlement, and runs it on GUESTDIR.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin=${BIN:-$here/out/vm-spike}
mkdir -p "$(dirname "$bin")"
zig build-exe -lc --dep vz -Mroot="$here/spike.zig" -Mvz="$here/../../src/vz.zig" -femit-bin="$bin"
codesign --force --sign - --entitlements "$here/vz.entitlements" "$bin"
exec "$bin" "$@"

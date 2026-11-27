#!/bin/sh
# Joins the entries of image.sh into a manifest (docs/dev/vm-image.md):
#   manifest.sh NAME VERSION COUNTER MIN_ZTCL ARM64.json X86_64.json > manifest.json
# NAME ends in -test for a manifest that the test key signs.
set -eu
[ $# -eq 6 ] || { echo "usage: manifest.sh name version counter min_ztcl arm64.json x86_64.json" >&2; exit 2; }
printf '{"format":1,"name":"%s","version":"%s","counter":%s,"min_ztcl":"%s","archs":{"arm64":%s,"x86_64":%s}}\n' \
    "$1" "$2" "$3" "$4" "$(cat "$5")" "$(cat "$6")"

#!/bin/sh
# Downloads the test-signed guest image release of the latest build of
# main (the artifact vm-image-test of the workflow VM guest) into DIR, and
# checks it with the verifier of ztcl in a test-key build:
#   tools/vm-guest/fetch-test-image.sh DIR
# The release has manifest.json, manifest.json.sig (the test key, name
# ztcl-guest-test), and arm64-Image, arm64-root.img, x86_64-bzImage, and
# x86_64-root.img. `ztcl::vm image install DIR` takes it in a build with
# -Dvm-test-key. Needs gh (signed in) and Zig.
set -eu
dir=${1:?usage: fetch-test-image.sh DIR}
repo=${REPO:-beetlebugorg/ztcl}
run=$(gh run list -R "$repo" --workflow vm-guest.yml --branch "${BRANCH:-main}" --status success --limit 1 --json databaseId -q '.[0].databaseId')
[ -n "$run" ] || { echo "no successful VM guest run on ${BRANCH:-main}" >&2; exit 1; }
mkdir -p "$dir"
gh run download -R "$repo" "$run" -n vm-image-test -D "$dir"
here=$(cd "$(dirname "$0")/../.." && pwd)
(cd "$here" && zig build vm-image-verify -Dvm-test-key -- "$(cd "$dir" && pwd)")
echo "test image of run $run in $dir"

#!/bin/sh
# Checks that docs/targets.md has a row for each target of
# `zig build runtimes` (runtime_targets in build.zig), and that the JIT
# column says "tier 1" for each target with a JIT backend (src/jit.zig).
# SPDX-License-Identifier: BSD-2-Clause
set -eu
cd "$(dirname "$0")/.."
page=docs/targets.md
fail=0
targets=$(sed -n 's/^const runtime_targets = .*{ \(.*\) };$/\1/p' build.zig | tr -d '",')
[ -n "$targets" ] || { echo "FAIL: no runtime_targets in build.zig"; exit 1; }
for t in $targets; do
    grep -q "^| \`$t\` |" "$page" || { echo "FAIL: $page has no row for $t"; fail=1; }
done
# The JIT backends: lines such as (builtin.cpu.arch == .x86_64 and
# builtin.os.tag == .linux) in the `backend` constant.
jit=$(sed -n '/^pub const backend =/,/;$/p' src/jit.zig | sed -n 's/.*arch == \.\([a-z0-9_]*\) and builtin\.os\.tag == \.\([a-z]*\)).*/\1-\2/p')
[ -n "$jit" ] || { echo "FAIL: no JIT backends in src/jit.zig"; exit 1; }
for t in $targets; do
    row=$(grep "^| \`$t\` |" "$page" | head -1)
    case " $(echo $jit) " in
        *" $t "*) echo "$row" | grep -q "| tier 1" || { echo "FAIL: $t has a JIT, and its row does not say tier 1"; fail=1; } ;;
        *) echo "$row" | grep -q "| tier 1" && { echo "FAIL: $t has no JIT, and its row says tier 1"; fail=1; } ;;
    esac
done
[ $fail = 0 ] && echo "ok: $page lists $(echo $targets | wc -w) targets and the JIT of $(echo $jit | wc -w)"
exit $fail

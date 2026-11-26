#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Checks the built docs site for text that leaked from the Markdown: a
# comment line such as `<!-- run -->` that shows as text on a page has
# the escaped form `&lt;!--` in the HTML. The check reads each page
# except llms-full.txt, which has the Markdown on purpose.
#
# Use: tests/site.sh [site folder]    (default: build the site into a temp folder)
# Exit status: 0 pass, 1 fail.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
site="${1:-}"
if [ -z "$site" ]; then
    site="$(mktemp -d)"
    trap 'rm -rf "$site"' EXIT
    python3 "$root/tools/build-docs.py" "$site" >/dev/null
fi
hits="$(grep -rl --include=index.html '&lt;!--' "$site" || true)"
if [ -n "$hits" ]; then
    echo "FAIL: a comment of the Markdown shows as text on these pages:"
    echo "$hits" | sed "s|^$site/||"
    exit 1
fi
echo "ok: no page shows a comment of the Markdown as text ($(find "$site" -name index.html | wc -l) pages)"

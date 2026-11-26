#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Checks that each ztcl:: command of src/ has a reference page.

Use: python3 -I tools/doc-coverage.py

The script finds each name `ztcl::NAME` that src/ registers as a command
or as a module, and each page in docs/modules/. A command is covered
when a page has a heading with its name, or a code line that starts
with its name. The test modules and the names of PENDING are skipped.
The script exits with 1 when a command has no page.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# The test modules of the module table.
SKIP = {"ztcl::hello", "ztcl::hello::greet", "ztcl::hellonet"}
# The commands whose pages are not written yet. Remove a name with its page.
PENDING: set[str] = set()

NAME = re.compile(r'(?:register\(|\.name = )"(ztcl::[a-z0-9_:]+)"')


def main():
    names = set()
    for f in (ROOT / "src").rglob("*.zig"):
        names.update(NAME.findall(f.read_text(encoding="utf-8")))
    pages = "\n".join(p.read_text(encoding="utf-8") for p in (ROOT / "docs/modules").glob("*.md"))
    missing = []
    for n in sorted(names - SKIP - PENDING):
        # A subcommand of an ensemble is covered by the page of its parent.
        top = "ztcl::" + n.split("::")[1]
        if any(re.search(rf"(?m)^(#+ .*|){re.escape(x)}\b", pages) for x in (n, top)):
            continue
        missing.append(n)
    for n in missing:
        print(f"no reference page has {n}")
    print(f"{len(names - SKIP)} commands, {len(PENDING)} pending, {len(missing)} missing")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())

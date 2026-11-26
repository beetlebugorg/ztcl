#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Runs the examples of the reference pages of the modules.

Use: python3 -I tools/doc-examples.py RUNNER docs/modules/NAME.md ...

An example is a ```tcl block that follows a line `<!-- run -->`. The
script runs each example in its own runner process. When a ```text block
follows the example, the output of the run must equal that block. The
script exits with 1 when an example fails or its output differs.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

BLOCK = re.compile(r"<!-- run -->\n```tcl\n(.*?)```\n(?:\n?```text\n(.*?)```\n)?", re.S)


def main():
    runner, pages = sys.argv[1], sys.argv[2:]
    fail = 0
    count = 0
    for page in pages:
        text = pathlib.Path(page).read_text(encoding="utf-8")
        for m in BLOCK.finditer(text):
            count += 1
            line = text.count("\n", 0, m.start()) + 1
            with tempfile.NamedTemporaryFile("w", suffix=".tcl", delete=False, encoding="utf-8") as f:
                f.write(m.group(1))
            r = subprocess.run([runner, f.name], capture_output=True, text=True, timeout=60)
            pathlib.Path(f.name).unlink()
            want = m.group(2)
            if r.returncode != 0:
                print(f"FAIL {page}:{line}: exit {r.returncode}: {r.stderr.strip()}")
                fail = 1
            elif want is not None and r.stdout != want:
                print(f"FAIL {page}:{line}: output\n{r.stdout}want\n{want}")
                fail = 1
    print(f"{count} examples, {'a failure' if fail else 'all pass'}")
    return fail


if __name__ == "__main__":
    sys.exit(main())

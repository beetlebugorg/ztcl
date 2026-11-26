#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Runs the examples of the reference pages of the modules.

Use: python3 -I tools/doc-examples.py RUNNER docs/modules/NAME.md ...

An example is a ```tcl block that follows a line `<!-- run -->` or
`<!-- run: FLAGS -->`. The script runs each example in its own runner
process, with the FLAGS before the script, in a new empty folder. When a ```text block
follows the example, the output of the run must equal that block. The
script exits with 1 when an example fails or its output differs.
The flag `native` goes to no runner: `<!-- run: native -->` marks an
example that needs a command of the native build, such as `coroutine`,
so the page shows it as plain code.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

BLOCK = re.compile(r"<!-- run(?:: ([^>]*?))? -->\n```tcl\n(.*?)```\n(?:\n?```text\n(.*?)```\n)?", re.S)


def main():
    runner, pages = str(pathlib.Path(sys.argv[1]).resolve()), sys.argv[2:]
    fail = 0
    count = 0
    for page in pages:
        text = pathlib.Path(page).read_text(encoding="utf-8")
        for m in BLOCK.finditer(text):
            count += 1
            line = text.count("\n", 0, m.start()) + 1
            with tempfile.NamedTemporaryFile("w", suffix=".tcl", delete=False, encoding="utf-8") as f:
                f.write(m.group(2))
            flags = [f for f in (m.group(1) or "").split() if f != "native"]
            with tempfile.TemporaryDirectory() as cwd:
                r = subprocess.run([runner, *flags, f.name], capture_output=True, text=True, timeout=60, cwd=cwd)
            pathlib.Path(f.name).unlink()
            want = m.group(3)
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

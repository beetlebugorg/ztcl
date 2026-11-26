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

A lesson of the Learn course (docs/learn/NN-slug.md) runs as one script:
its checkpoint, then each code box (`<!-- define -->`) and each Run link
in the order of the page. A Run link is [`command`](run: "result"). The
result of the command must equal the title of the link, or the message
of its error when the title starts with "error: ". A step that expects
"error: compute limit reached" runs alone after the checkpoint, with the
compute limit of the shell of the site. A Run link with no
title must not fail. The files of the page (`<!-- file: NAME -->`) are
in the folder of the run. `<!-- checkpoint: FLAGS -->` gives FLAGS to the
runner, for a lesson that needs a capability.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

FILE = re.compile(r"<!-- file: (\S+) -->\n```\w*\n(.*?)```\n", re.S)
CHECKPOINT = re.compile(r"<!-- checkpoint(?:: ([^>]*?))? -->\n```tcl\n(.*?)```\n", re.S)
STEP = re.compile(r'<!-- define -->\n```tcl\n(.*?)```\n|\[`([^`]+)`\]\(run:(?: "((?:[^"\\]|\\.)*)")?\)', re.S)
BLOCK = re.compile(r"<!-- run(?:: ([^>]*?))? -->\n```tcl\n(.*?)```\n(?:\n?```text\n(.*?)```\n)?", re.S)


def tcl_string(text):
    """A Tcl word in double quotes with the same text."""
    out = text.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("[", "\\[").replace("]", "\\]")
    return '"' + out.replace("\n", "\\n") + '"'


def lesson(runner, page, text):
    """Runs the steps of a lesson. Gives the count of steps and 1 on a failure."""
    m = CHECKPOINT.search(text)
    script = [m.group(2) if m else ""]
    flags = (m.group(1) or "").split() if m else []
    steps, limited = [], []
    for s in STEP.finditer(text):
        code, cmd, want = s.group(1), s.group(2), s.group(3)
        line = text.count("\n", 0, s.start()) + 1
        want = None if want is None else re.sub(r"\\(.)", r"\1", want)
        if want == "error: compute limit reached":
            # The limit stops the whole script, so this step runs alone,
            # after the checkpoint, with the compute limit of the shell.
            limited.append((line, code or cmd))
            continue
        steps.append((line, code or cmd, want))
        script.append(f"set ::__s {tcl_string(code or cmd)}\n"
                      "set ::__c [catch {uplevel #0 $::__s} ::__v]\n"
                      'puts -nonewline "\\x1f$::__c\\x1f$::__v\\x1e"\n')
    with tempfile.NamedTemporaryFile("w", suffix=".tcl", delete=False, encoding="utf-8") as f:
        f.write("\n".join(script))
    with tempfile.TemporaryDirectory() as cwd:
        for name, body in FILE.findall(text):
            pathlib.Path(cwd, name).write_text(body, encoding="utf-8")
        r = subprocess.run([runner, *flags, f.name], capture_output=True, text=True, timeout=60, cwd=cwd)
    pathlib.Path(f.name).unlink()
    got = re.findall(r"\x1f(\d+)\x1f(.*?)\x1e", r.stdout, re.S)
    if r.returncode != 0 or len(got) != len(steps):
        print(f"FAIL {page}: exit {r.returncode}, {len(got)} of {len(steps)} steps ran: {r.stderr.strip()}")
        return len(steps), 1
    fail = 0
    for line, cmd in limited:
        with tempfile.NamedTemporaryFile("w", suffix=".tcl", delete=False, encoding="utf-8") as f:
            f.write(script[0] + "\n" + cmd + "\n")
        with tempfile.TemporaryDirectory() as cwd:
            r = subprocess.run([runner, *flags, "--compute", "10000000", f.name], capture_output=True, text=True, timeout=60, cwd=cwd)
        pathlib.Path(f.name).unlink()
        if "compute limit reached" not in r.stderr + r.stdout:
            print(f"FAIL {page}:{line}: {cmd!r} did not stop at the compute limit: {r.stderr.strip()}")
            fail = 1
    for (line, cmd, want), (code, value) in zip(steps, got):
        if want is not None and want.startswith("error: "):
            ok = code == "1" and value == want[len("error: "):]
        else:
            ok = code == "0" and (want is None or value == want)
        if not ok:
            print(f"FAIL {page}:{line}: {cmd!r} gave {'an error' if code == '1' else 'the result'} {value!r}, want {want!r}")
            fail = 1
    return len(steps) + len(limited), fail


def main():
    runner, pages = str(pathlib.Path(sys.argv[1]).resolve()), sys.argv[2:]
    fail = 0
    count = 0
    for page in pages:
        text = pathlib.Path(page).read_text(encoding="utf-8")
        if "<!-- checkpoint" in text or "/learn/" in page:
            n, bad = lesson(runner, page, text)
            count += n
            fail |= bad
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

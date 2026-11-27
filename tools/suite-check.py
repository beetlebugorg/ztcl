#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Compares the pass counts of a full suite run with docs/dev/suite-counts.tsv.

    python3 -I tools/suite-check.py files.tsv files-jit.tsv [counts.tsv]

The two files are logs of `tools/suite.sh -a -o` with the suite runner,
without and with -j. The pass count of each file must be at least the
count in docs/dev/suite-counts.tsv, or in counts.tsv when it is given. The timing tests of socket.test,
io.test, and chanio.test change between runs, so their counts can be
lower by 2. Prints a Markdown table of the counts and exits with
status 1 when a count dropped.
"""
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
LOOSE = {"socket.test": 2, "io.test": 2, "chanio.test": 2}


def load(path):
    runs = {}
    with open(path, errors="replace") as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            if len(c) == 5:
                runs[c[0]] = int(c[1])
    return runs


base = {}
# A third argument is another file of counts, such as the counts of Tcl 9.1.
with open(sys.argv[3] if len(sys.argv) > 3 else os.path.join(here, "../docs/dev/suite-counts.tsv")) as f:
    for line in f:
        if line.startswith("#") or not line.strip():
            continue
        name, p, jp = line.rstrip("\n").split("\t")
        base[name] = (int(p), int(jp))

runs = (load(sys.argv[1]), load(sys.argv[2]))
drops = []
print("| Run | Pass | Recorded | Change |")
print("|---|---|---|---|")
for i, label in enumerate(("interpreter", "JIT")):
    total = sum(runs[i].values())
    want = base["total"][i]
    print(f"| {label} | {total:,} | {want:,} | {total - want:+,} |")
    for name, counts in sorted(base.items()):
        if name == "total":
            continue
        got = runs[i].get(name, 0)
        if got < counts[i] - LOOSE.get(name, 0):
            drops.append(f"{label}: {name} pass {got}, recorded {counts[i]}")
for d in drops:
    print(f"- {d}")
sys.exit(1 if drops else 0)

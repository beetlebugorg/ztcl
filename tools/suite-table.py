#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Writes docs/compatibility.md from a log of tools/suite.sh -a -o.

    python3 -I tools/suite-table.py <log> > docs/compatibility.md

tools/suite-scope.tsv has the scope, the reason, and the test count of
each file. The total of a file is the larger of that count and the
tests that ran. A test that did not pass or fail is blocked: a false
constraint stopped it, or the file stopped before it.
"""
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
NAMES = {"in": "In scope", "decide": "Needs a decision", "na": "Cannot apply"}

scope = {}
with open(os.path.join(here, "suite-scope.tsv")) as f:
    for line in f:
        if line.startswith("#") or not line.strip():
            continue
        name, sc, count, why = line.rstrip("\n").split("\t")
        scope[name] = (sc, int(count), why)

runs, reasons = {}, {}
with open(sys.argv[1], errors="replace") as f:
    for line in f:
        c = line.rstrip("\n").split("\t")
        if len(c) == 4 and c[1] == "skipped":
            reasons.setdefault(c[0], []).append((int(c[3]), c[2]))
        elif len(c) == 5:
            runs[c[0]] = (int(c[1]), int(c[2]), int(c[3]), c[4])

missing = sorted(set(runs) ^ set(scope))
if missing:
    sys.exit("files without a scope or a run: " + " ".join(missing))

rows = {"in": [], "decide": [], "na": []}
for name in sorted(scope):
    sc, count, why = scope[name]
    p, x, s, rc = runs[name]
    total = max(count, p + x + s)
    blocked = total - p - x
    top = sorted(reasons.get(name, []), key=lambda r: (-r[0], r[1]))[:3]
    cons = ", ".join(f"`{w}` {n}" for n, w in top if "|" not in w and len(w) < 40)
    unreached = total - p - x - s
    if unreached:
        cons = (cons + ", " if cons else "") + f"unreached {unreached}"
    rows[sc].append((name, total, p, x, blocked, cons, why))

out = sys.stdout
out.write("""# Compatibility with the Tcl 8.6.16 tests

This page lists each of the 152 test files of Tcl 8.6.16. `tools/suite-table.py` makes it from a run of `tools/suite.sh -a`. The repository has no copy of the tests.

## How to read the counts

- **Total** is the number of tests in the file. `tools/suite-count.tcl` counts the `test` calls in a safe tclsh, and a text search counts the test lines. The table uses the larger count, or the count of tests that ran if that is larger.
- **Pass** and **Fail** are results of ztcl with the stand-in `tools/tcltest.tcl`.
- **Blocked** is Total minus Pass minus Fail. A blocked test did not run, so it is not a pass. A false constraint blocked it, or the file stopped before it (`unreached`).
- **Blocked by** gives the largest constraints and their counts. Tcl also skips some of these, for example `knownBug` and `emptyTest`.

## Scopes

- **In scope:** the language and the core commands.
- **Needs a decision:** tests of commands that the sandbox omits today, such as `file`, `open`, `socket`, `exec`, `clock`, and `interp`.
- **Cannot apply:** tests of the C API through the `test*` commands of the Tcl test binary, tests for Windows or macOS only, and tests of threads.

## Totals

| Scope | Files | Total | Pass | Fail | Blocked | Pass rate |
|---|---|---|---|---|---|---|
""")
grand = [0, 0, 0, 0, 0]
for sc in ("in", "decide", "na"):
    r = rows[sc]
    t, p, x, b = (sum(v[i] for v in r) for i in (1, 2, 3, 4))
    for i, v in enumerate((len(r), t, p, x, b)):
        grand[i] += v
    rate = 100 * p / t if t else 0
    out.write(f"| {NAMES[sc]} | {len(r)} | {t} | {p} | {x} | {b} | {rate:.1f} % |\n")
rate = 100 * grand[2] / grand[1]
out.write(f"| **All** | **{grand[0]}** | **{grand[1]}** | **{grand[2]}** | **{grand[3]}** | **{grand[4]}** | **{rate:.1f} %** |\n")
for sc in ("in", "decide", "na"):
    out.write(f"\n## {NAMES[sc]}\n\n| File | Total | Pass | Fail | Blocked | Blocked by | Reason |\n|---|---|---|---|---|---|---|\n")
    for name, t, p, x, b, cons, why in rows[sc]:
        out.write(f"| `{name}` | {t} | {p} | {x} | {b} | {cons} | {why} |\n")

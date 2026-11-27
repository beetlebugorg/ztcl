#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Writes docs/dev/suite.md and docs/dev/suite-tests.tsv from suite runs.

    tools/suite-run.sh            # runs the suite and this script
    python3 -I tools/suite-md.py DIR

DIR has the logs of tools/suite.sh with the suite runner: files.tsv and
tests.tsv (-o and -p, no JIT), and files-jit.tsv and tests-jit.tsv (-o
and -p, with -j). DIR/meta has `date<TAB>...` and `commit<TAB>...`.

tools/suite-buckets.tsv puts each test that does not pass into a
bucket. The first rule that matches a test is its bucket. A rule has a
kind (skip, fail, unreached, or *), a glob for `file/test name`, a
regular expression for the detail (the constraint of a skip, the start
of the result of a failure), the bucket, and the reason. A test with
no rule is in the bucket `untriaged`.
"""
import datetime
import fnmatch
import os
import re
import sys

here = os.path.dirname(os.path.abspath(__file__))
top = os.path.dirname(here)
BUCKETS = [
    ("bug", "A bug in ztcl"),
    ("feature", "A missing feature or option"),
    ("message", "An error message or -errorcode differs"),
    ("internals", "Needs Tcl internals (C test commands, memory debugging)"),
    ("design", "Absent by design"),
    ("platform", "Platform only"),
    ("tcl", "Skipped by tclsh too (knownBug, emptyTest, and others)"),
    ("untriaged", "Not triaged yet"),
]
BNAMES = dict(BUCKETS)


def load_rules():
    rules = []
    with open(os.path.join(here, "suite-buckets.tsv")) as f:
        for n, line in enumerate(f, 1):
            if line.startswith("#") or not line.strip():
                continue
            c = line.rstrip("\n").split("\t")
            if len(c) != 5 or c[3] not in BNAMES:
                sys.exit(f"suite-buckets.tsv:{n}: bad rule")
            kind, glob, rx, bucket, why = c
            rules.append((kind, glob, re.compile(rx) if rx else None, bucket, why))
    return rules


def bucket_of(rules, kind, path, detail):
    for k, glob, rx, bucket, why in rules:
        if k != "*" and k != kind:
            continue
        if not fnmatch.fnmatchcase(path, glob):
            continue
        if rx and not rx.search(detail):
            continue
        return bucket, why
    return "untriaged", ""


def load_files(path):
    runs = {}
    with open(path, errors="replace") as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            if len(c) == 5:
                runs[c[0]] = (int(c[1]), int(c[2]), int(c[3]), c[4])
    return runs


def load_tests(path):
    tests = {}
    with open(path, errors="replace") as f:
        for line in f:
            c = line.rstrip("\n").split("\t", 3)
            if len(c) < 3:
                continue
            fname, kind, name = c[0], c[1], c[2]
            detail = c[3] if len(c) > 3 else ""
            # A name can repeat in a file. Keep the first record and
            # count each one.
            key = (fname, name)
            n = 1
            while key in tests:
                n += 1
                key = (fname, f"{name} ({n})")
            tests[key] = (kind, detail)
    return tests


def load_internals():
    rows = []
    with open(os.path.join(here, "suite-internals.tsv")) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            rows.append(tuple(line.rstrip("\n").split("\t")))
    return rows


# The name of a C test command in the detail of a test.
TESTCMD = re.compile(r'^(test[a-z0-9]+|memory|Tcltest|TcltestPackage|procbodytest|pkga?u?a\.soRequired|teststaticpkg(_8\.x)?|drainEventQueue|applylambda|testWithLimit|testCPUID|hasIsoLocale)$')
NOCMD = re.compile(r'invalid command name "(test[a-z0-9]+)"|^code [^:]*: (test[a-z0-9]+): .* has no stand-in')


def blocker(kind, fname, detail):
    """The test command that blocks a test of the bucket internals."""
    if kind == "skip":
        for w in re.split(r"[\s&|!()]+", detail):
            w = w.removeprefix("expr:")
            if TESTCMD.match(w):
                return w
    m = NOCMD.search(detail)
    if m:
        return m.group(1) or m.group(2)
    return f"(other, {fname})"


def cell(s, n=90):
    s = s.replace("|", "\\|").replace("`", "'")
    return s if len(s) <= n else s[: n - 3] + "..."


def main():
    d = sys.argv[1]
    meta = {}
    with open(os.path.join(d, "meta")) as f:
        for line in f:
            k, _, v = line.rstrip("\n").partition("\t")
            meta[k] = v
    rules = load_rules()
    scope = {}
    with open(os.path.join(here, "suite-scope.tsv")) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            name, sc, count, why = line.rstrip("\n").split("\t")
            scope[name] = (sc, int(count), why)
    files = load_files(os.path.join(d, "files.tsv"))
    jfiles = load_files(os.path.join(d, "files-jit.tsv"))
    tests = load_tests(os.path.join(d, "tests.tsv"))
    jtests = load_tests(os.path.join(d, "tests-jit.tsv"))

    names = sorted(set(files) | set(scope))
    per = {f: [] for f in names}
    for (fname, name), v in tests.items():
        per.setdefault(fname, []).append((name, v))
    rows, tsv = [], []
    tot = dict(total=0, pass_=0, fail=0, skip=0, unreached=0)
    jtot = dict(pass_=0, fail=0, skip=0)
    btot = {b: 0 for b, _ in BUCKETS}
    reasons = {}
    fails, skips, diffs = {}, {}, []
    blocked = {}
    for fname in names:
        sc, count, why = scope.get(fname, ("in", 0, ""))
        p, x, s, rc = files.get(fname, (0, 0, 0, "absent"))
        jp, jx, js, jrc = jfiles.get(fname, (0, 0, 0, "absent"))
        ran = p + x + s
        total = max(count, ran)
        unreached = total - ran
        for k, v in (("total", total), ("pass_", p), ("fail", x), ("skip", s), ("unreached", unreached)):
            tot[k] += v
        jtot["pass_"] += jp; jtot["fail"] += jx; jtot["skip"] += js
        if unreached:
            b, bw = bucket_of(rules, "unreached", f"{fname}/*", f"status {rc}")
            btot[b] += unreached
            reasons[(b, bw)] = reasons.get((b, bw), 0) + unreached
            skips.setdefault(fname, []).append((f"(file stopped early, status {rc})", unreached, b, bw))
        sk = {}
        for name, (kind, detail) in sorted(per.get(fname, [])):
            jk = jtests.get((fname, name), ("absent", ""))[0]
            if jk != kind:
                diffs.append((fname, name, kind, jk))
            if kind == "pass":
                tsv.append((fname, name, kind, jk, "", ""))
                continue
            b, bw = bucket_of(rules, kind, f"{fname}/{name}", detail)
            btot[b] += 1
            reasons[(b, bw)] = reasons.get((b, bw), 0) + 1
            if b == "internals":
                k = blocker(kind, fname, detail)
                blocked[k] = blocked.get(k, 0) + 1
            tsv.append((fname, name, kind, jk, b, detail))
            if kind == "fail":
                fails.setdefault(fname, []).append((name, b, bw, detail))
            else:
                k = (detail, b, bw)
                sk[k] = sk.get(k, 0) + 1
        for (detail, b, bw), n in sorted(sk.items(), key=lambda t: (-t[1], t[0])):
            skips.setdefault(fname, []).append((detail, n, b, bw))
        rows.append((fname, sc, total, p, x, s, unreached, jp, jx, js))

    out = []
    w = out.append
    w("# Tcl 8.6.16 suite results")
    w("")
    w(f"`tools/suite-run.sh` makes this page with `tools/suite-md.py`. Do not edit it by hand. Run on {meta.get('date', '?')} at commit `{meta.get('commit', '?')}`, with the suite runner `zig-out/bin/ztcl-suite` ({meta.get('optimize', '?')}) on all {len(names)} test files. `docs/dev/suite-tests.tsv` has one line for each test.")
    w("")
    w("A test is applicable when it is outside the buckets `design`, `platform`, `internals`, and `tcl`. The goal of issue 244 is a pass for each applicable test.")
    w("")
    w("## Totals")
    w("")
    w("| Run | Total | Pass | Fail | Skip | Unreached |")
    w("|---|---|---|---|---|---|")
    fmt = "{:,}".format
    w(f"| Interpreter | {fmt(tot['total'])} | {fmt(tot['pass_'])} | {fmt(tot['fail'])} | {fmt(tot['skip'])} | {fmt(tot['unreached'])} |")
    jun = tot["total"] - jtot["pass_"] - jtot["fail"] - jtot["skip"]
    w(f"| JIT (`-j`) | {fmt(tot['total'])} | {fmt(jtot['pass_'])} | {fmt(jtot['fail'])} | {fmt(jtot['skip'])} | {fmt(jun)} |")
    w("")
    w("Unreached is the test count of `tools/suite-scope.tsv` minus the tests that ran: the file stopped before them.")
    w("")
    w9 = os.path.join(top, "docs/dev/suite-counts-9.tsv")
    if os.path.exists(w9):
        c9 = {}
        with open(w9) as f:
            for line in f:
                if not line.startswith("#") and line.strip():
                    n, p, jp = line.rstrip("\n").split("\t")
                    c9[n] = (int(p), int(jp))
        w("## Tcl 9.1.0")
        w("")
        w(f"`tools/suite.sh -t core-9-1-0` runs the {len(c9) - 1} core test files of Tcl 9.1.0 with `--tcl 9.1`. `docs/dev/suite-counts-9.tsv` has the pass count of each file, and the scheduled CI run checks them. The counts do not compare with the counts of 8.6.16: the files differ.")
        w("")
        w("| Run | Pass |")
        w("|---|---|")
        w(f"| Interpreter | {fmt(c9['total'][0])} |")
        w(f"| JIT (`-j`) | {fmt(c9['total'][1])} |")
        w("")
    w("## Buckets")
    w("")
    w("The tests of the interpreter run that do not pass, by bucket.")
    w("")
    w("| Bucket | Meaning | Tests |")
    w("|---|---|---|")
    for b, m in BUCKETS:
        w(f"| `{b}` | {m} | {fmt(btot[b])} |")
    applicable = tot["total"] - sum(btot[b] for b in ("design", "platform", "internals", "tcl"))
    rate = 100.0 * tot["pass_"] / applicable if applicable else 0.0
    w("")
    w(f"Applicable tests: {fmt(applicable)}. Pass rate of the applicable tests: {rate:.1f} %.")
    w("")
    w("## Reasons")
    w("")
    w("The tests of the buckets `bug`, `feature`, `message`, and `untriaged`, by the reason of their rule in `tools/suite-buckets.tsv`.")
    w("")
    w("| Bucket | Reason | Tests |")
    w("|---|---|---|")
    for (b, bw), n in sorted(reasons.items(), key=lambda t: (t[0][0], -t[1], t[0][1])):
        if b in ("bug", "feature", "message", "untriaged"):
            w(f"| `{b}` | {cell(bw or '(no rule)')} | {fmt(n)} |")
    w("")
    w("## Internals by test command")
    w("")
    w("The tests of the bucket `internals`, by the command of the Tcl test binary that blocks them (issue 480). The path is from `tools/suite-internals.tsv`: `C package` is Tcl's own test command, built as a C package on the stubs of ztcl; `runner` is a stand-in in `tools/suite_cmds.zig`; `design` tests check the internal layout of Tcl. The other commands are in one line, and a test with no command name is in the line of its file.")
    w("")
    w("| Command | Tests | Path | What the tests check |")
    w("|---|---|---|---|")
    known = {r[0]: r for r in load_internals()}
    rest, rest_cmds = 0, 0
    for k, n in sorted(blocked.items(), key=lambda t: (-t[1], t[0])):
        if k in known:
            w(f"| `{k}` | {fmt(n)} | {known[k][1]} | {cell(known[k][2], 200)} |")
        elif k.startswith("(other"):
            w(f"| {k[1:-1]} | {fmt(n)} | C package | Tests of the C API in a file of the bucket. |")
        else:
            rest += n
            rest_cmds += 1
    if rest:
        w(f"| {fmt(rest_cmds)} other commands | {fmt(rest)} | C package | Other functions of the C API, one command for each. |")
    w("")
    w("## JIT differences")
    w("")
    if diffs:
        w("Tests with a different result in the JIT run. `socket.test`, `io.test`, and `chanio.test` have timing tests that can change between two runs of one mode. `tools/suite.sh` runs `socket.test`, and `chanio.test` after a failure of `chan-io-36.1`, one more time and keeps the run with more passes. The leak tests of `memory` read the live bytes of the heap, and these change between two runs.")
        w("")
        w("| File | Test | Interpreter | JIT |")
        w("|---|---|---|---|")
        for fname, name, a, b in diffs:
            w(f"| {fname} | {cell(name)} | {a} | {b} |")
    else:
        w("Each test has the same result in the two runs.")
    w("")
    w("## Files")
    w("")
    w("| File | Scope | Total | Pass | Fail | Skip | Unreached | JIT pass | JIT fail | JIT skip |")
    w("|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        w("| " + " | ".join([r[0], r[1]] + [fmt(v) for v in r[2:]]) + " |")
    w("")
    w("## Tests that do not pass")
    w("")
    w("Each failure has its own line. Skips are grouped by the constraint that stopped them.")
    for fname in names:
        if fname not in fails and fname not in skips:
            continue
        w("")
        w(f"### {fname}")
        if fname in fails:
            w("")
            w("| Test | Bucket | Result (start) |")
            w("|---|---|---|")
            for name, b, bw, detail in fails[fname]:
                w(f"| {cell(name, 40)} | `{b}`{': ' + cell(bw, 60) if bw else ''} | {cell(detail)} |")
        if fname in skips:
            w("")
            w("| Skipped by | Tests | Bucket |")
            w("|---|---|---|")
            for detail, n, b, bw in skips[fname]:
                w(f"| {cell(detail, 60)} | {n} | `{b}`{': ' + cell(bw, 80) if bw else ''} |")
    with open(os.path.join(top, "docs/dev/suite.md"), "w") as f:
        f.write("\n".join(out) + "\n")
    with open(os.path.join(top, "docs/dev/suite-tests.tsv"), "w") as f:
        f.write("# file\ttest\tinterpreter\tjit\tbucket\tdetail\n")
        for r in tsv:
            f.write("\t".join(r[:5]) + "\t" + cell(r[5], 200) + "\n")
    # The counts that the scheduled CI run compares.
    with open(os.path.join(top, "docs/dev/suite-counts.tsv"), "w") as f:
        f.write("# file\tpass\tjit pass\n")
        for r in rows:
            f.write(f"{r[0]}\t{r[3]}\t{r[7]}\n")
        f.write(f"total\t{tot['pass_']}\t{jtot['pass_']}\n")


main()

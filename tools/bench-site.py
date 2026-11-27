#!/usr/bin/env python3
# Measures the numbers that the site, the README, and docs/performance.md
# quote, and prints them as Markdown tables.
#
#   python3 -I tools/bench-site.py --ztcl PATH --tclsh PATH [--out FILE]
#
# The tables:
#   - The scripts of bench/ (not the thread scripts): CPU ms of the whole
#     process, best of 11 runs, for `--no-jit`, the default, and tclsh.
#   - The same scripts: user instructions (`perf stat -e instructions:u`)
#     in millions for `--no-jit`, `--no-jit-tier2`, the default, and
#     tclsh. The table is empty when perf has no hardware counter.
#   - `sum` of bench/sum.tcl with 10,000,000 passes: wall ms of the call
#     from `clock microseconds`, best of 5 runs.
#   - The thread scripts: the ms of each line that a script prints
#     (`name ms ...`), best of 5.
#   - The start: wall ms of `ztcl hi.tcl` for one `puts`, median of 50.
#   - The size of the runner in bytes, and with gzip -9.
# SPDX-License-Identifier: BSD-2-Clause

import argparse
import glob
import gzip
import os
import re
import resource
import shutil
import statistics
import subprocess
import tempfile
import time

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def cpu_ms(cmd):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return 1000 * ((after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime))


def wall_ms(cmd):
    t = time.perf_counter()
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return 1000 * (time.perf_counter() - t)


def instructions(cmd):
    if shutil.which("perf") is None:
        return None
    with tempfile.NamedTemporaryFile("r", suffix=".perf") as f:
        subprocess.run(["perf", "stat", "-x,", "-e", "instructions:u", "-o", f.name, "--"] + cmd,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        for line in f.read().splitlines():
            parts = line.split(",")
            if len(parts) > 2 and "instructions" in parts[2] and parts[0].strip().isdigit():
                return int(parts[0]) / 1e6
    return None


def printed_ms(cmd):
    out = subprocess.run(cmd, capture_output=True, text=True, check=False).stdout
    nums = re.findall(r"([0-9]+(?:\.[0-9]+)?)\s*ms", out)
    return float(nums[-1]) if nums else None


def fmt(v, digits=1):
    return "n/a" if v is None else f"{v:,.{digits}f}"


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--ztcl", default=os.path.join(root, "zig-out", "bin", "ztcl"))
    a.add_argument("--tclsh", default="tclsh")
    a.add_argument("--out")
    args = a.parse_args()
    z, t = args.ztcl, args.tclsh
    out = []
    scripts = [p for p in sorted(glob.glob(os.path.join(root, "bench", "*.tcl")))
               if not os.path.basename(p).startswith("thread_")]

    out.append("## CPU ms, best of 11\n")
    out.append("| Script | `--no-jit` | default | tclsh |")
    out.append("|---|---|---|---|")
    for p in scripts:
        row = [min(cpu_ms(c) for _ in range(11)) for c in ([z, "--no-jit", p], [z, p], [t, p])]
        out.append(f"| `{os.path.basename(p)}` | " + " | ".join(fmt(v) for v in row) + " |")

    out.append("\n## Instructions, millions\n")
    out.append("| Script | `--no-jit` | `--no-jit-tier2` | default | tclsh |")
    out.append("|---|---|---|---|---|")
    for p in scripts:
        row = [instructions(c) for c in ([z, "--no-jit", p], [z, "--no-jit-tier2", p], [z, p], [t, p])]
        out.append(f"| `{os.path.basename(p)}` | " + " | ".join(fmt(v) for v in row) + " |")

    work = tempfile.mkdtemp()
    loop = os.path.join(work, "loop.tcl")
    with open(os.path.join(root, "bench", "sum.tcl")) as f:
        body = f.read().replace("puts [sum 1000000]", "")
    with open(loop, "w") as f:
        f.write(body + "set t [clock microseconds]\nsum 10000000\n"
                "puts \"[expr {([clock microseconds] - $t) / 1000.0}] ms\"\n")
    out.append("\n## sum 10,000,000, wall ms of the call, best of 5\n")
    out.append("| Runner | ms |")
    out.append("|---|---|")
    for name, c in (("`--no-jit`", [z, "--no-jit", "--allow", "clock", loop]),
                    ("`--no-jit-tier2`", [z, "--no-jit-tier2", "--allow", "clock", loop]),
                    ("default", [z, "--allow", "clock", loop]), ("tclsh", [t, loop])):
        vals = [v for v in (printed_ms(c) for _ in range(5)) if v is not None]
        out.append(f"| {name} | {fmt(min(vals) if vals else None)} |")

    out.append("\n## Threads, ms that the script prints, best of 5\n")
    out.append("| Line | ztcl | tclsh |")
    out.append("|---|---|---|")
    for p in sorted(glob.glob(os.path.join(root, "bench", "thread_*.tcl"))):
        best = [{}, {}]
        for k, c in enumerate(([z, "--allow", "thread,event,package,clock", p], [t, p])):
            for _ in range(5):
                text = subprocess.run(c, capture_output=True, text=True, check=False).stdout
                for m in re.finditer(r"^(\S+) ([0-9]+)", text, re.M):
                    v = int(m.group(2))
                    best[k][m.group(1)] = min(v, best[k].get(m.group(1), v))
        for name in best[0]:
            out.append(f"| `{os.path.basename(p)}` {name} | {best[0][name]} | {best[1].get(name, 'n/a')} |")

    hi = os.path.join(work, "hi.tcl")
    with open(hi, "w") as f:
        f.write("puts hi\n")
    start = statistics.median(wall_ms([z, hi]) for _ in range(50))
    tstart = statistics.median(wall_ms([t, hi]) for _ in range(50))
    with open(z, "rb") as f:
        data = f.read()
    out.append("\n## Start and size\n")
    out.append(f"- `ztcl hi.tcl`, median of 50: {start:.2f} ms (tclsh: {tstart:.2f} ms)")
    out.append(f"- runner: {len(data):,} bytes, gzip -9: {len(gzip.compress(data, 9)):,} bytes")
    shutil.rmtree(work)

    text = "\n".join(out) + "\n"
    print(text)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text)


if __name__ == "__main__":
    main()

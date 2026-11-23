#!/usr/bin/env python3
# Runs the scripts in bench/ on ztcl and on a reference tclsh.
#
#   python3 -I tools/bench.py [--ztcl PATH] [--tclsh PATH] [--runs N]
#
# Each time is the best CPU time (user and system) of N runs of the
# whole process, in milliseconds. --tclsh selects the Tcl version.
# SPDX-License-Identifier: BSD-2-Clause
import argparse
import glob
import os
import subprocess
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def cpu_ms(cmd):
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL)
    _, status, usage = os.wait4(p.pid, 0)
    p.returncode = os.waitstatus_to_exitcode(status)
    if p.returncode != 0:
        sys.exit(f"{cmd} failed with code {p.returncode}")
    return (usage.ru_utime + usage.ru_stime) * 1000


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--ztcl", default=os.path.join(root, "zig-out", "bin", "ztcl"))
    a.add_argument("--tclsh", default="tclsh")
    a.add_argument("--runs", type=int, default=5)
    args = a.parse_args()
    level = subprocess.run([args.tclsh], input="puts [info patchlevel]\n",
                           capture_output=True, text=True, check=True).stdout.strip()
    print(f"| Benchmark | ztcl (ms) | tclsh {level} (ms) |")
    print("|---|---|---|")
    for path in sorted(glob.glob(os.path.join(root, "bench", "*.tcl"))):
        z = min(cpu_ms([args.ztcl, path]) for _ in range(args.runs))
        t = min(cpu_ms([args.tclsh, path]) for _ in range(args.runs))
        print(f"| `{os.path.basename(path)}` | {z:.1f} | {t:.1f} |")


main()

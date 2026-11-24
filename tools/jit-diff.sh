#!/bin/sh
# Compares the JIT with the interpreter on each test script.
#
#   tools/jit-diff.sh [--stress] [-t] [-r runner] [-x extra-flags] [script ...]
#
# For each script of tests/jit/, tests/mem/, and bench/, the tool runs
# the runner with `--report --gc off` in three modes:
#
#   1. no flag (the reference)
#   2. --jit --jit-threshold 0
#   3. --jit (the default threshold)
#
# It compares stdout, stderr without the `jit` and `report` lines, the
# exit code, and the `steps` and `mem` fields of the report. When a
# script of tests/jit/ has a file `name.out`, the stdout and stderr of
# mode 1 must equal it. Each `.out` file comes from tclsh 8.6.16. A
# script with a line `# jit-diff-flags: ...` gets those flags in each
# mode. A script of tests/mem/ runs with `--tclsh` and a small pass
# count.
#
# With the suite runner next to the runner, it runs tests/jit/stack/
# with and without the JIT: the JIT must use no more native stack.
#
# Then it runs the step limit sweep on each script of tests/jit/sweep/:
# for each step limit from 0 to the full step count of the script (at
# most 3000), modes 1 and 2 give the same output, exit code, steps, and
# memory count.
#
# `-t` adds `--jit-tier2 --jit-tier2-count 2` to each JIT mode.
#
# `--stress` runs modes 2 and 3 again with each stress mode of the JIT
# alone (`--jit-stress` 1, 2, 4, 8, 16) and all together (31). The
# environment variable JIT_STRESS_BITS adds more values. Mode 1
# also runs with the first failed allocation at 2, 3, and 5. The step
# limit sweep then also runs mode 2 with all stress modes.
#
# `-x` adds flags to each mode, for example `-x "--gc-stress 1"`: the
# memory count then differs, so the tool does not compare it.
# Run the tool under the memory cap of AGENTS.md. The exit code is 1
# when a script differs.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runner="$here/../zig-out/bin/ztcl"
extra=
tier2=0
stress=0
if [ "${1:-}" = --stress ]; then
    stress=1
    shift
fi
while getopts r:x:t o; do
    case $o in
    r) runner=$OPTARG ;;
    x) extra=$OPTARG ;;
    t) tier2=1 ;;
    *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
exec python3 -I - "$here/.." "$runner" "$extra" "$stress" "$tier2" "$@" <<'PY'
import os, re, subprocess, sys
root, runner, extra, stress = sys.argv[1], sys.argv[2], sys.argv[3].split(), sys.argv[4] == "1"
only = sys.argv[6:]
t2 = ["--jit-tier2", "--jit-tier2-count", "2"] if sys.argv[5] == "1" else []
modes = [[], ["--jit", "--jit-threshold", "0"] + t2, ["--jit"] + t2]
sweep_mode = modes[1]
if stress:
    jit_modes = []
    # JIT_STRESS_BITS adds stress values, for example "32 63" for the
    # guard schedule of tier 2 when the runner has it.
    for n in [1, 2, 4, 8, 16, 31] + [int(x) for x in os.environ.get("JIT_STRESS_BITS", "").split()]:
        for m in modes[1:]:
            jit_modes.append(m + ["--jit-stress", str(n)])
    for k in (2, 3, 5):
        jit_modes.append(modes[1] + ["--jit-stress", "1", "--jit-stress-alloc", str(k)])
    modes = [modes[0]] + jit_modes
    sweep_mode = ["--jit", "--jit-threshold", "0"] + t2 + ["--jit-stress", "31"]
base = ["--report", "--gc", "off", "--max-steps", "1000000000"] + extra
compare_mem = not extra

def scripts():
    out = []
    for d in ("tests/jit", "tests/mem", "bench"):
        for f in sorted(os.listdir(os.path.join(root, d))):
            if f.endswith(".tcl"):
                out.append(os.path.join(d, f))
    return out

def flags_of(path):
    for line in open(os.path.join(root, path)):
        m = re.match(r"# jit-diff-flags: (.*)", line)
        if m:
            return m.group(1).split()
    return []

def run(path, mode, limit=None):
    args = [runner] + base + flags_of(path) + mode
    if limit is not None:
        args[args.index("--max-steps") + 1] = str(limit)
    if path.startswith("tests/mem/"):
        n = "30" if "b64" in path else "2000"
        args += ["--tclsh", path, n]
    else:
        args.append(path)
    p = subprocess.run(args, cwd=root, capture_output=True, timeout=120)
    err = p.stderr.decode(errors="replace").splitlines()
    rep = [l for l in err if l.startswith("report ")]
    rest = [l for l in err if not l.startswith(("report ", "jit ", "gc collections"))]
    fields = {}
    if rep:
        for kv in rep[-1].split()[1:]:
            k, v = kv.split("=")
            fields[k] = v
    key = {"stdout": p.stdout, "stderr": rest, "code": p.returncode, "steps": fields.get("steps")}
    if compare_mem:
        key["mem"] = fields.get("mem")
    return key

bad = 0
count = 0
for path in (only or scripts()):
    ref = run(path, modes[0])
    exp = os.path.join(root, path[:-4] + ".out")
    if path.startswith("tests/jit/") and os.path.exists(exp) and not extra:
        want = open(exp, "rb").read()
        got = ref["stdout"] + "".join(l + "\n" for l in ref["stderr"]).encode()
        if got != want:
            print("DIFF %s: the interpreter differs from tclsh" % path)
            bad += 1
    for m in modes[1:]:
        got = run(path, m)
        count += 1
        if got != ref:
            print("DIFF %s %s" % (path, " ".join(m)))
            for k in ref:
                if ref[k] != got[k]:
                    print("  %s: %r != %r" % (k, ref[k] if k != "stdout" else ref[k][:300], got[k] if k != "stdout" else got[k][:300]))
            bad += 1
print("scripts: %d runs compared, %d differ" % (count, bad))

sweep = os.path.join(root, "tests/jit/sweep")
sweeps = 0
if not only:
    for f in sorted(os.listdir(sweep)):
        if not f.endswith(".tcl"):
            continue
        path = os.path.join("tests/jit/sweep", f)
        full = int(run(path, modes[0])["steps"])
        for limit in range(0, min(full, 3000) + 1):
            a = run(path, modes[0], limit)
            b = run(path, sweep_mode, limit)
            sweeps += 1
            if a != b:
                print("DIFF %s at step limit %d" % (path, limit))
                for k in a:
                    if a[k] != b[k]:
                        print("  %s: %r != %r" % (k, a[k], b[k]))
                bad += 1
                break
    print("sweep: %d step limits compared" % sweeps)
# The native stack of one proc call level: the JIT uses no more.
suite = os.path.join(os.path.dirname(runner), "ztcl-suite")
if not only and os.path.exists(suite):
    path = "tests/jit/stack/depth.tcl"
    got = []
    for m in ([], ["--jit", "--jit-threshold", "0"]):
        p = subprocess.run([suite] + m + [path], cwd=root, capture_output=True, timeout=120)
        got.append(int(p.stdout.split()[-1]) if p.returncode == 0 and p.stdout.split() else -1)
    ok = got[0] > 0 and 0 < got[1] <= got[0]
    print("native stack of 500 calls: %d bytes without the JIT, %d with it: %s" % (got[0], got[1], "ok" if ok else "FAIL"))
    if not ok:
        bad += 1
print("total: %d differ" % bad)
sys.exit(1 if bad else 0)
PY

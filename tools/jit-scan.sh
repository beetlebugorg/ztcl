#!/bin/sh
# Checks the security rules of the JIT that need the runner.
#
#   tools/jit-scan.sh [-r runner]
#
# 1. No script constant in code. A script uses the integers 0x13371337
#    and 0x0BADC0DE in `expr`, `incr`, `set`, and compares. The runner
#    compiles each proc with `--jit-dump`. No dump file has the four
#    bytes of either number, in either byte order. A second run adds
#    tier 2, and at least one loop must compile to tier 2.
# 2. Bounds. A proc with 2049 local variables, a proc with more than
#    32 768 bytecode instructions, and a proc with a word of 2049 parts
#    stay in the interpreter: each one counts in `failed`, and the
#    output equals the output with no JIT.
# 3. The limits. A script defines 100 000 procs with one `eval` and
#    calls each one two times with `--mem 2147483648`. It ends,
#    `code_bytes + data_bytes` is at most the JIT memory limit, and the
#    output equals the output with no JIT.
# 4. The maps. The suite runner runs `expr.test` of the Tcl source with
#    the JIT at threshold 0, then `testjitmaps`: no mapping of the
#    process is writable and executable.
#
# Run the tool under the memory cap of AGENTS.md. The exit code is 1
# when a check fails.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runner="$here/../zig-out/bin/ztcl"
while getopts r: o; do
    case $o in
    r) runner=$OPTARG ;;
    *) exit 2 ;;
    esac
done
case $runner in /*) ;; *) runner=$PWD/$runner ;; esac
src=$("$here/fetch-tcl.sh" core-8-6-16) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-scan.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
python3 -I - "$here/.." "$runner" "$work" "$src/tests" <<'PY'
import os, re, struct, subprocess, sys
root, runner, work, tests = sys.argv[1:5]
suite = os.path.join(os.path.dirname(runner), "ztcl-suite")
bad = 0
limit = 16 << 20

def run(args, script):
    path = os.path.join(work, "s.tcl")
    with open(path, "w") as f:
        f.write(script)
    p = subprocess.run([runner, "--max-steps", "100000000"] + args + [path], capture_output=True, timeout=600)
    err = p.stderr.decode(errors="replace")
    stats = {}
    for line in err.splitlines():
        if line.startswith("jit "):
            for kv in line.split()[1:]:
                k, v = kv.split("=")
                stats[k] = int(v)
    return p.stdout, p.returncode, stats

def check(name, ok, detail=""):
    global bad
    print("%s: %s%s" % (name, "ok" if ok else "FAIL", (" (" + detail + ")") if detail else ""))
    if not ok:
        bad += 1

# 1. No script constant in code.
consts = [0x13371337, 0x0BADC0DE]
script = """
proc a {x} { set y 0x13371337; set z [expr {$x + 0x13371337}]; incr z 0x0BADC0DE; if {$z == 0x0BADC0DE} { return 1 }; return [expr {$x < 0x13371337}] }
proc b {x} { set s 0; for {set i 0} {$i < 0x13371337} {incr i 0x0BADC0DE} { incr s $i; if {$s > 0x0BADC0DE} break }; return $s }
proc c {x} { set k [expr {$x * 0x0BADC0DE}]; set m [expr {$k - 0x13371337}]; if {$m != 0x13371337} { incr m 322376503 }; return [list $k $m [expr {$x == 195936478}]] }
proc d {x} { while {$x < 0x0BADC0DE} { set x [expr {$x + 0x13371337}] }; return $x }
puts [a 1]; puts [b 2]; puts [c 3]; puts [d 4]
"""
# The second run adds tier 2 at a loop count of 1, so the loops of `b`
# and `d` also compile to tier 2. The dump then has the tier 2 code.
for tier, flags in (("tier 1", []), ("tier 2", ["--jit-tier2", "--jit-tier2-count", "1"])):
    dump = os.path.join(work, "dump" + str(len(flags)))
    os.mkdir(dump)
    out, rc, st = run(["--jit", "--jit-threshold", "0", "--jit-stats", "--jit-dump", dump] + flags, script)
    files = sorted(os.listdir(dump))
    hits = []
    for f in files:
        data = open(os.path.join(dump, f), "rb").read()
        for c in consts:
            for pat in (struct.pack("<I", c), struct.pack(">I", c)):
                if pat in data:
                    hits.append("%s has %s" % (f, pat.hex()))
    ok = rc == 0 and len(files) >= 4 and not hits and (not flags or st.get("tier2", 0) >= 1)
    check("no script constant in code, " + tier, ok,
          "%d functions, tier2=%d, %s" % (len(files), st.get("tier2", 0), "; ".join(hits) or "no hit"))

# 2. Bounds.
many = "proc many {} {\n" + "".join("set v%d %d\n" % (k, k) for k in range(2049)) + "return [expr {$v0 + $v2048}]\n}\n"
long = "proc long {} {\n set a 0\n" + "incr a\n" * 17000 + "return $a\n}\n"
wide = "proc wide {} {\n set a x\n return [string length \"" + "$a" * 2049 + "\"]\n}\n"
script = many + long + wide + "puts [many]; puts [long]; puts [wide]\n"
ref, rc0, _ = run([], script)
out, rc1, st = run(["--jit", "--jit-threshold", "0", "--jit-stats"], script)
check("bounds: the three procs stay in the interpreter", rc0 == 0 and out == ref and rc1 == 0 and st.get("failed", 0) >= 3,
      "failed=%s, output %s" % (st.get("failed"), "equal" if out == ref else "differs"))

# 3. The limits.
script = """
set text {}
for {set i 0} {$i < 100000} {incr i} { append text "proc p$i {x} {set s \\$x; for {set k 0} {\\$k < 2} {incr k} { incr s $i }; return \\$s}\\n" }
eval $text
set t 0
for {set r 0} {$r < 2} {incr r} { for {set i 0} {$i < 100000} {incr i} { incr t [p$i 1] } }
puts $t
"""
ref, rc0, _ = run(["--mem", "2147483648"], script)
out, rc1, st = run(["--jit", "--mem", "2147483648", "--jit-stats"], script)
used = st.get("code_bytes", 0) + st.get("data_bytes", 0)
check("limits: 100 000 procs", rc0 == 0 and rc1 == 0 and out == ref and used <= limit and st.get("compiled", 0) > 0,
      "compiled=%s failed=%s code_bytes+data_bytes=%d limit=%d" % (st.get("compiled"), st.get("failed"), used, limit))

# 4. The maps after expr.test.
if not os.path.exists(suite):
    check("maps: the suite runner exists", False, suite)
else:
    r = os.path.join(work, "root")
    os.mkdir(r)
    end = os.path.join(work, "end.tcl")
    with open(end, "w") as f:
        f.write('puts "jit-wx [testjitmaps]"\n')
    p = subprocess.run([suite, "--jit", "--jit-threshold", "0", "--jit-stats", "--max-steps", "200000000", "--mem", "2147483648",
                        "--allow", "package,interp,clock,channels,file,event", "--root", r, "--keep-going",
                        os.path.join(root, "tools/tcltest.tcl"), os.path.join(tests, "expr.test"),
                        os.path.join(root, "tools/tcltest-end.tcl"), end], capture_output=True, timeout=1200)
    text = p.stdout.decode(errors="replace")
    m = re.search(r"^jit-wx (-?\d+)$", text, re.M)
    counts = re.search(r"^pass (\d+) fail", text, re.M)
    comp = re.search(r"compiled=(\d+)", p.stderr.decode(errors="replace"))
    check("maps: no writable and executable mapping after expr.test", m is not None and m.group(1) == "0" and comp is not None and int(comp.group(1)) > 0,
          "testjitmaps=%s, expr.test pass=%s, compiled=%s" % (m.group(1) if m else None, counts.group(1) if counts else None, comp.group(1) if comp else None))

print("total: %d failed" % bad)
sys.exit(1 if bad else 0)
PY
exit $?

#!/usr/bin/env python3
# Runs random Tcl programs with a collection at each allocation.
#
#   tools/gc-fuzz.py -r runner [-b reference] [-n count] [-s seed] [-g N] [-j] [-T]
#
# A grammar makes each program from a seed. The program uses procs,
# loops, lists, dicts, arrays, strings, regexp, upvar, uplevel, catch,
# rename, traces, namespaces, TclOO with constructors, `next`, and
# `self caller`, coroutines, `tailcall` with `catch`, child interpreters,
# and errors. Each statement prints its result, so a damaged value changes
# the output.
#
# The reference run uses `--gc off`. The test run uses `--gc-stress N`.
# With -j, the test run also has the JIT at threshold 0, so the machine
# code runs with a collection at each allocation. -T adds tier 2 with a
# loop count of 2 to -j. A program that reaches
# the nesting limit can then stop at another depth: the tool counts it
# and does not compare it.
# The exit code, stdout, and steps must be equal. A run that stops at the
# memory limit compares only the output that both runs have. A difference
# or a crash prints the seed and keeps the program in the folder of -k.
# SPDX-License-Identifier: BSD-2-Clause
import argparse
import os
import random
import subprocess
import sys
import tempfile

WORDS = ["", "a", "b c", "{x y}", "0", "-0", "007", "12", "-7", "1.5", "0x1f", "9223372036854775807", "foo", "key", "x" * 40, "é", "\\n"]


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.out = []
        self.procs = 0

    def var(self):
        return self.r.choice("abcdef")

    def lit(self):
        w = self.r.choice(WORDS)
        return "{" + w + "}" if "{" not in w and "\\" not in w else '"' + w.replace("{", "(").replace("}", ")").replace("\\", "") + '"'

    def val(self, d=0):
        r = self.r
        if d > 2 or r.random() < 0.3:
            return self.lit() if r.random() < 0.5 else f"[v {self.var()}]"
        k = r.randrange(16)
        a, b = self.val(d + 1), self.val(d + 1)
        n = r.randrange(0, 6)
        return [
            f"[string repeat {a} {n}]", f"[list {a} {b}]", f"[concat {a} {b}]", f"[string length {a}]",
            f"[string toupper {a}]", f"[lindex {a} {n}]", f"[lrange {a} 0 {n}]", f"[join {a} -]",
            f"[split {a} {{ }}]", f"[string map {{a b}} {a}]", f"[dict create k {a} m {b}]",
            f"[string range {a} 1 {n}]", f"[lsort [list {a} {b}]]", f"[format %s-%s {a} {b}]",
            f"[regsub -all a {a} zz]", f"[lreplace {a} 0 0 {b}]",
        ][k]

    def stmt(self, d=0):
        r = self.r
        x, y = self.var(), self.var()
        v = self.val()
        flat = [
            lambda: f"set {x} {v}",
            lambda: f"append {x} {v}",
            lambda: f"lappend {x} {v}",
            lambda: f"catch {{lset {x} 0 {v}}}",
            lambda: f"lassign {v} {x} {y}",
            lambda: f"set arr({r.randrange(4)}) {v}",
            lambda: f"catch {{dict set {x} k{r.randrange(4)} {v}}}",
            lambda: f"catch {{dict get ${x} k1}} {y}",
            lambda: f"catch {{incr {x}}}",
            lambda: f"catch {{expr {{${x} + 1}}}} {y}",
            lambda: f"regexp {{(a+)|(b)}} {v} {x} {y}",
            lambda: f"catch {{error {v}}} {x}",
            lambda: f"unset -nocomplain {x}",
            lambda: f"switch -exact -- {v} {{a {{set {x} 1}} foo {{set {x} 2}} default {{set {x} [string repeat q 9]}}}}",
            lambda: f"set {x} [lsort -command cmp [list {v} b a]]",
            lambda: f"set {x} [lmap q {v} {{string length $q}}]",
            lambda: f"set {x} [string is integer -strict {v}]",
        ]
        # These forms nest, so they stop at a depth of three.
        nested = [
            lambda: f"foreach q {v} {{{self.body(d)}}}",
            lambda: f"for {{set i 0}} {{$i < {r.randrange(1, 5)}}} {{incr i}} {{{self.body(d)}}}",
            lambda: f"if {{[string length {v}] > 2}} {{{self.body(d)}}} else {{{self.body(d)}}}",
            lambda: f"catch {{{self.body(d)}}} {x}",
            lambda: f"set {x} [p{r.randrange(4)} {v} {x}]",
            lambda: f"uplevel 1 {{{self.body(d)}}}",
            lambda: f"eval {{{self.body(d)}}}",
            lambda: f"namespace eval n{r.randrange(2)} {{variable w {v}; set w}}",
            lambda: f"trace add variable {x} write tr; set {x} {v}; trace remove variable {x} write tr",
            lambda: f"set o [C new]; set {x} [$o add {v}]; $o destroy",
            lambda: f"set o [D new {v}]; set {x} [$o add {v}]; catch {{$o who}} {y}; $o destroy",
            lambda: f"set {x} [tc {v}]",
            lambda: f"set {x} [tcc {v}]",
            lambda: f"catch {{tailcall list {v}}} {x}",
            lambda: f"catch {{coroutine co{r.randrange(3)} gen {v}}} {x}; catch {{co0}} {y}",
            lambda: f"catch {{interp create k; k eval {{set z [string repeat m 30]; list $z $z}}}} {x}; catch {{interp delete k}}",
        ]
        return r.choice(flat + nested if d < 3 else flat)()

    def body(self, d):
        return "; ".join(self.stmt(d + 1) for _ in range(self.r.randrange(1, 4)))

    def program(self):
        head = r"""
proc v {n} { upvar 1 $n x; if {[info exists x] && ![array exists x]} { return $x }; return {} }
proc cmp {a b} { string compare $a $b }
proc tr {args} { set ::t [string repeat t 12] }
proc gen {x} { set l [list $x $x]; yield [llength $l]; yield $x; return $l }
oo::class create C { variable t; constructor {} { set t {} }; method add {k} { lappend t $k; return $t } }
oo::class create D { superclass C; constructor {x} { next; my add [string repeat $x 2] }; method add {k} { set r [next $k]; return [list [llength $r] $r] }; method who {} { return [self caller] } }
proc tc {x} { set y [list $x $x]; tailcall concat $y [string repeat z 3] }
proc tcc {x} { set r [catch {tailcall list $x} m]; return [list after $r $m] }
"""
        procs = []
        for i in range(4):
            lines = "\n    ".join(f"catch {{{self.stmt(2)}}} r; puts [list p{i} $r]" for _ in range(self.r.randrange(1, 4)))
            procs.append(f"proc p{i} {{a b}} {{\n    upvar 1 $b up\n    set c $a\n    {lines}\n    return [list $a $c]\n}}\n")
        main = "\n".join(f"catch {{{self.stmt()}}} r; puts [list {i} $r]" for i in range(self.r.randrange(4, 14)))
        tail = 'foreach n {a b c d e f} { if {[info exists $n] && ![array exists $n]} { puts [list $n [set $n]] } }\nputs [lsort [array names arr]]\n'
        return head + "".join(procs) + main + "\n" + tail


def run(cmd, path, timeout):
    try:
        p = subprocess.run(cmd + ["--report", path], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    steps = [l for l in p.stderr.split(b"\n") if l.startswith(b"report ")]
    step = steps[-1].split()[1] if steps else b""
    return p.returncode, p.stdout, step, p.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-r", required=True, help="the runner under test")
    ap.add_argument("-b", help="the reference runner (default: the same runner)")
    ap.add_argument("-n", type=int, default=100)
    ap.add_argument("-s", type=int, default=1)
    ap.add_argument("-g", type=int, default=1)
    ap.add_argument("-k", default=tempfile.gettempdir())
    ap.add_argument("-t", type=int, default=60, help="the timeout of one run in seconds")
    ap.add_argument("-j", action="store_true", help="run the test run with the JIT at threshold 0")
    ap.add_argument("-T", action="store_true", help="add tier 2 to -j")
    o = ap.parse_args()
    base = ["--max-steps", "400000", "--mem", str(256 << 20), "--allow", "interp"]
    bad = slow = deep = 0
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "p.tcl")
        for seed in range(o.s, o.s + o.n):
            text = Gen(seed).program()
            with open(path, "w") as f:
                f.write(text)
            ref = run([o.b or o.r, "--gc", "off"] + base, path, o.t)
            jit = ["--jit", "--jit-threshold", "0"] if o.j else []
            if o.j and o.T:
                jit += ["--jit-tier2", "--jit-tier2-count", "2"]
            got = run([o.r, "--gc-stress", str(o.g)] + jit + base, path, o.t * 5)
            if ref is None or got is None:
                slow += 1
                continue
            # The place of the memory error can differ with the collector
            # on, so a run that ends there compares its common output.
            limit = b"too much memory"
            if limit in ref[1] + ref[3] or limit in got[1] + got[3]:
                # The last line can be the error of the run.
                a, b = [x[:x.rfind(b"\n", 0, len(x) - 1) + 1] for x in (ref[1], got[1])]
                k = min(len(a), len(b))
                if a[:k] == b[:k] and got[0] in (0, 1):
                    continue
            # With the JIT, one proc call level uses less native stack, so
            # a deep recursion can stop at another depth (docs/dev/jit.md).
            nest = b"too many nested evaluations"
            if o.j and (nest in ref[1] + ref[3] or nest in got[1] + got[3]) and ref[:3] != got[:3]:
                deep += 1
                continue
            if ref[:3] != got[:3]:
                bad += 1
                keep = os.path.join(o.k, f"gc-fuzz-{seed}.tcl")
                with open(keep, "w") as f:
                    f.write(text)
                print(f"seed {seed}: differs (rc {ref[0]} and {got[0]}, steps {ref[2]!r} and {got[2]!r}): {keep}")
                print(got[3][-400:].decode(errors="replace"))
    print(f"programs {o.n} differ {bad} timed out {slow} other depth at the nesting limit {deep}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

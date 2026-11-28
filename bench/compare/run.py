#!/usr/bin/env python3
"""Runs the comparison benchmarks: the same tasks in ztcl, Tcl 8.6,
Python, Go, and Zig.

Run from the root of the repository, after `zig build -Doptimize=ReleaseFast`:

    python3 -I bench/compare/run.py            # the full run, about 15 minutes
    python3 -I bench/compare/run.py --check    # small inputs, output check only

The runner makes the inputs (gen.py), builds the Go and Zig programs,
and runs
each program in rounds. A round runs each task once in each language, in
a new order, so the load of the machine falls on all languages alike.
After 5 rounds, it goes on until the interquartile range of each time is
at most 5 % of its median, or until 15 rounds.

Each time is the wall clock of the whole process in milliseconds, from
the start of the process to its exit, so it includes the start of the
runtime. The http task gives requests for each second. Each task must
give the same output in each language; the runner stops if it does not.

The results go to bench/compare/results.tsv, with the CPU, the OS, the
versions, and the load average in its comment lines. chart.py makes the
charts from that file. It uses only the standard library of Python.
"""
import argparse
import hashlib
import os
import platform
import random
import shutil
import socket
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
WORK = os.path.join(HERE, ".work")

# The languages, in the order of the charts.
LANGS = ["ztcl", "ztcl-nojit", "tclsh", "python", "go", "zig"]

# task: (family, unit, argument at scale 1, argument for --check).
# An argument of None means the data folder.
TASKS = {
    "base64": ("data", "ms", None, None),
    "json": ("data", "ms", None, None),
    "csv": ("data", "ms", None, None),
    "weblog": ("text", "ms", None, None),
    "wordfreq": ("text", "ms", None, None),
    "strfmt": ("text", "ms", "1000000", "10000"),
    "template": ("text", "ms", "100000", "1000"),
    "sort_int": ("sort", "ms", None, None),
    "sort_str": ("sort", "ms", None, None),
    "http": ("net", "req/s", "3", "0.5"),
    "tls": ("net", "ms", "20", "2"),
    "hello": ("start", "ms", None, None),
    "fib": ("micro", "ms", "30", "20"),
    "nbody": ("micro", "ms", "50000", "1000"),
}

# Tasks that a language has no program for, with the reason for the notes.
MISSING = {
    ("tls", "tclsh"): "Tcl 8.6 has no TLS in its core; the tcltls package needs OpenSSL",
}

ZTCL_ALLOW = "channels,file,package"
ZTCL_ALLOW_NET = "channels,file,package,socket,event"


def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def version(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, input="", timeout=30)
        return (out.stdout + out.stderr).strip().splitlines()[0]
    except Exception as e:  # The tool is missing.
        return "missing (%s)" % e


def cpu_model():
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or platform.machine()


def loadavg():
    try:
        return "%.1f %.1f %.1f" % os.getloadavg()
    except OSError:
        return "unknown"


def stale(binary, src):
    return not os.path.exists(binary) or os.path.getmtime(binary) < os.path.getmtime(src)


def build(tools):
    out = os.path.join(WORK, "bin")
    os.makedirs(out, exist_ok=True)
    env = dict(os.environ, GOFLAGS="-trimpath")
    for name in sorted(os.listdir(os.path.join(HERE, "go"))):
        if name.endswith(".go") and stale(os.path.join(out, "go-" + name[:-3]), os.path.join(HERE, "go", name)):
            sh(["nice", "-n", "19", tools["go"], "build", "-o", os.path.join(out, "go-" + name[:-3]), name],
               cwd=os.path.join(HERE, "go"), env=env)
    zsrc = [os.path.join(HERE, "zig", n) for n in sorted(os.listdir(os.path.join(HERE, "zig"))) if n.endswith(".zig")]
    zsrc.append(os.path.join(HERE, "load", "load.zig"))
    for src in zsrc:
        name = os.path.basename(src)[:-4]
        if stale(os.path.join(out, "zig-" + name), src):
            sh(["nice", "-n", "19", tools["zig"], "build-exe", "-OReleaseFast", "-femit-bin=" + os.path.join(out, "zig-" + name), src])
    return out


def script(lang, task):
    if lang.startswith("ztcl"):
        p = os.path.join(HERE, "ztcl", task + ".tcl")
        if os.path.exists(p):
            return p
    return os.path.join(HERE, "tcl", task + ".tcl")


def command(lang, task, arg, tools, bindir):
    """Gives the command of one run, or None when the language has no program for the task."""
    if (task, lang) in MISSING:
        return None
    allow = ZTCL_ALLOW_NET if task in ("http", "tls") else ZTCL_ALLOW
    if lang == "ztcl":
        # --tclsh: the words after the script are its argv, as in tclsh.
        return [tools["ztcl"], "--allow", allow, "--tclsh", script(lang, task)] + arg
    if lang == "ztcl-nojit":
        return [tools["ztcl"], "--no-jit", "--allow", allow, "--tclsh", script(lang, task)] + arg
    if lang == "tclsh":
        return [tools["tclsh"], script(lang, task)] + arg
    if lang == "python":
        return [tools["python"], "-I", os.path.join(HERE, "py", task + ".py")] + arg
    if lang in ("go", "zig"):
        return [os.path.join(bindir, lang + "-" + task)] + arg
    raise ValueError(lang)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start_server(cmd, env):
    p = subprocess.Popen(["nice", "-n", "10"] + cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    line = p.stdout.readline()
    if line.strip() != "ready":
        p.kill()
        raise RuntimeError("server did not start: %s %s" % (cmd, p.stderr.read()[:400]))
    return p


def run_once(lang, task, arg, tools, bindir, env, outpath, tls_ctx):
    """Runs one program once. Gives the measured value, or None."""
    if task == "http":
        port = str(free_port())
        cmd = command(lang, task, [port], tools, bindir)
        if cmd is None:
            return None
        senv = dict(env, GOMAXPROCS="1") if lang == "go" else env
        srv = start_server(cmd, senv)
        try:
            out = subprocess.run(["nice", "-n", "10", os.path.join(bindir, "zig-load"), port, arg[0]],
                                 capture_output=True, text=True, check=True, timeout=float(arg[0]) + 60)
            with open(outpath, "w") as f:
                f.write("ok\n")
            return float(out.stdout.strip())
        finally:
            srv.kill()
            srv.wait()
    if task == "tls":
        arg = [tls_ctx["port"], tls_ctx["ca"]] + arg
    cmd = command(lang, task, arg, tools, bindir)
    if cmd is None:
        return None
    with open(outpath, "wb") as out:
        t0 = time.perf_counter_ns()
        r = subprocess.run(["nice", "-n", "10"] + cmd, stdout=out, stderr=subprocess.PIPE, env=env)
        t1 = time.perf_counter_ns()
    if r.returncode != 0:
        raise RuntimeError("%s %s failed: %s" % (lang, task, r.stderr.decode(errors="replace")[:600]))
    return (t1 - t0) / 1e6


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def check_outputs(task, outs):
    """Stops the run when two languages give different output for a task."""
    ds = {lang: digest(p) for lang, p in outs.items()}
    if len(set(ds.values())) > 1:
        lines = []
        for lang, p in outs.items():
            with open(p, "rb") as f:
                lines.append("  %-11s %s %r" % (lang, ds[lang][:12], f.read(160)))
        sys.exit("different output for %s:\n%s" % (task, "\n".join(lines)))


def quartiles(xs):
    if len(xs) < 4:
        return min(xs), max(xs)
    q = statistics.quantiles(xs, n=4, method="inclusive")
    return q[0], q[2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="small inputs, one round, output check only")
    ap.add_argument("--only", help="a comma-separated list of tasks")
    ap.add_argument("--langs", default=",".join(LANGS))
    ap.add_argument("--min-rounds", type=int, default=5)
    ap.add_argument("--max-rounds", type=int, default=15)
    ap.add_argument("--target", type=float, default=0.05, help="the largest IQR / median to stop at")
    ap.add_argument("--ztcl", default=os.path.join(ROOT, "zig-out", "bin", "ztcl"))
    ap.add_argument("--tclsh", default=shutil.which("tclsh") or "tclsh")
    ap.add_argument("--python", default=sys.executable)
    ap.add_argument("--go", default=shutil.which("go") or "go")
    ap.add_argument("--zig", default=shutil.which("zig") or "zig")
    ap.add_argument("--tcllib", help="the modules folder of tcllib, for the json task of tclsh")
    ap.add_argument("--out", default=os.path.join(HERE, "results.tsv"))
    a = ap.parse_args()
    tools = {"ztcl": a.ztcl, "tclsh": a.tclsh, "python": a.python, "go": a.go, "zig": a.zig}
    langs = a.langs.split(",")
    tasks = a.only.split(",") if a.only else list(TASKS)
    scale = 0.01 if a.check else 1.0

    data = os.path.join(WORK, "data-%g" % scale)
    if not os.path.exists(os.path.join(data, "done")):
        sh(["nice", "-n", "19", sys.executable, "-I", os.path.join(HERE, "gen.py"), data, str(scale)])
        open(os.path.join(data, "done"), "w").close()
    bindir = build(tools)
    env = dict(os.environ)
    if a.tcllib:
        env["TCLLIBPATH"] = a.tcllib
    else:
        MISSING[("json", "tclsh")] = "the core of Tcl 8.6 has no JSON parser; give tcllib with --tcllib"
    outdir = os.path.join(WORK, "out")
    os.makedirs(outdir, exist_ok=True)

    tls_ctx = None
    tls_srv = None
    if "tls" in tasks:
        tls_ctx = {"port": str(free_port()), "ca": os.path.join(WORK, "ca.pem")}
        tls_srv = start_server([os.path.join(bindir, "go-tlsserver"), tls_ctx["port"], WORK], env)

    env_lines = [
        "date\t%s" % time.strftime("%Y-%m-%d %H:%M %Z"),
        "cpu\t%s, %d logical CPUs" % (cpu_model(), os.cpu_count()),
        "os\t%s %s" % (platform.system(), platform.release()),
        "load_start\t%s" % loadavg(),
        "ztcl\t" + subprocess.run([a.ztcl, "--allow", "channels", "--tclsh"], input="puts [info patchlevel]", capture_output=True, text=True).stdout.strip()
        + ", commit " + subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip(),
        "tclsh\t" + subprocess.run([a.tclsh], input="puts [info patchlevel]", capture_output=True, text=True).stdout.strip(),
        "python\t%s" % version([a.python, "-V"]),
        "go\t%s" % version([a.go, "version"]),
        "zig\t%s" % version([a.zig, "version"]),
        "nice\t10 for each run, 19 for the builds",
    ]

    samples = {(t, l): [] for t in tasks for l in langs if command(l, t, [], tools, bindir) is not None}
    rng = random.Random(7)
    rounds = 1 if a.check else a.max_rounds
    try:
        for rnd in range(rounds):
            order = list(samples)
            rng.shuffle(order)
            outs = {}
            for task, lang in order:
                arg = TASKS[task][3] if a.check else TASKS[task][2]
                arg = [data] if arg is None and task not in ("hello",) else ([] if arg is None else [arg])
                outpath = os.path.join(outdir, "%s.%s.out" % (task, lang))
                v = run_once(lang, task, arg, tools, bindir, env, outpath, tls_ctx)
                samples[(task, lang)].append(v)
                outs.setdefault(task, {})[lang] = outpath
            if rnd == 0:
                for task, o in outs.items():
                    check_outputs(task, o)
                print("round 1: the outputs agree for each task")
            if rnd + 1 >= a.min_rounds:
                worst = 0.0
                for k, xs in samples.items():
                    q1, q3 = quartiles(xs)
                    worst = max(worst, (q3 - q1) / statistics.median(xs))
                print("round %d: largest IQR / median %.1f %%, load %s" % (rnd + 1, worst * 100, loadavg()))
                if worst <= a.target:
                    break
            else:
                print("round %d, load %s" % (rnd + 1, loadavg()))
    finally:
        if tls_srv:
            tls_srv.kill()
    if a.check:
        for (task, lang), xs in sorted(samples.items()):
            print("%-9s %-11s %10.1f %s" % (task, lang, xs[0], TASKS[task][1]))
        return
    env_lines.append("load_end\t%s" % loadavg())
    with open(a.out, "w") as f:
        f.write("# The results of bench/compare/run.py. One row for each task and language.\n")
        for line in env_lines:
            f.write("# %s\n" % line)
        for (t, l), why in MISSING.items():
            f.write("# missing\t%s\t%s\t%s\n" % (t, l, why))
        f.write("task\tfamily\tlang\tunit\tmedian\tq1\tq3\tmin\tmax\truns\n")
        for (task, lang), xs in samples.items():
            q1, q3 = quartiles(xs)
            f.write("%s\t%s\t%s\t%s\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%d\n" % (
                task, TASKS[task][0], lang, TASKS[task][1], statistics.median(xs), q1, q3, min(xs), max(xs), len(xs)))
    print(a.out)


if __name__ == "__main__":
    main()

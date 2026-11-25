"""Runs the outside benchmarks of the standard library modules.

    python3 -I tools/bench-stdlib.py [--only json,http,tls,sqlite]
                                     [--others-only] [--check GATES]
                                     [--dry-run] [--ztcl PATH]
                                     [--data DIR] [--out DIR] [--quick]

Each measure runs 5 times, and the table keeps the best run. The script
writes bench.md (Markdown) and bench.tsv to OUT (the default is
zig-out/bench) and adds the table to the job summary in CI.

--check GATES compares the ratio of ztcl to each other runtime with the
minimum ratio of each row of GATES (bench/stdlib/gates.tsv). A gate fails
when the ratio is below its minimum, or when a row has no ztcl number.
--dry-run reads the last bench.tsv and runs no program. It prints each
comparison, and only a malformed gate file fails it.

A runtime that is absent gives a row with the value "absent" and its
reason. The script fetches the data and the C parsers with
bench/stdlib/fetch.sh, which checks a SHA-256 of each file.

SPDX-License-Identifier: BSD-2-Clause
"""

import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TOP = os.path.dirname(HERE)
BENCH = os.path.join(TOP, "bench", "stdlib")
JSON_FILES = ["twitter.json", "canada.json", "citm_catalog.json"]
JSON_MODES = ["validate", "parse", "query", "read3", "walk", "encode"]
RUNS = 5

rows = []  # (group, measure, case, runtime, version, value, unit)


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def run(cmd, timeout=600, env=None, cwd=None):
    """Runs a command and gives its standard output, or raises."""
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env, cwd=cwd)
    if r.returncode != 0:
        raise RuntimeError("%s: exit %d: %s" % (" ".join(cmd), r.returncode, (r.stderr or r.stdout)[-400:]))
    return r.stdout


def version_of(cmd, pattern=r"(\S+)"):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        text = (out.stdout + out.stderr).strip()
        m = re.search(pattern, text)
        return m.group(1) if m else text.splitlines()[0]
    except (OSError, subprocess.SubprocessError, IndexError):
        return None


def add(group, measure, case, runtime, version, value, unit):
    rows.append((group, measure, case, runtime, version or "", value, unit))
    log("%-6s %-9s %-18s %-24s %s %s" % (group, measure, case, runtime, value, unit))


def best_seconds(cmd, env=None, cwd=None):
    """The best of RUNS runs of a program that prints seconds or "skip"."""
    best = None
    for _ in range(RUNS):
        out = run(cmd, env=env, cwd=cwd).strip().splitlines()
        if not out or out[-1] == "skip":
            return None
        s = float(out[-1])
        best = s if best is None else min(best, s)
    return best


# ---- setup -------------------------------------------------------------


def setup(data, out):
    """Builds the C parsers, the Go programs, the tclsh packages, and a
    Python environment with orjson, pysimdjson, and uvicorn."""
    bindir = os.path.join(out, "bin")
    tools = {"bindir": bindir}
    os.makedirs(bindir, exist_ok=True)
    # simdjson and yyjson, compiled for the build machine.
    exe = os.path.join(bindir, "bench_c")
    if not os.path.exists(exe):
        # simdjson selects its kernel at run time, so the build needs no
        # -march. A C++ compiler of the system goes first.
        cxx = shutil.which("c++") or shutil.which("g++") or shutil.which("clang++")
        cmd = [cxx] if cxx else ["zig", "c++"]
        try:
            run(cmd + ["-O3", "-std=c++17", "-DNDEBUG", "-x", "c++", "-I", data,
                       os.path.join(BENCH, "json", "bench_c.cpp"), os.path.join(data, "simdjson.cpp"),
                       "-x", "c", os.path.join(data, "yyjson.c"), "-o", exe], timeout=1200)
        except (OSError, RuntimeError) as e:
            log("cannot build the C parsers: %s" % e)
    if os.path.exists(exe):
        tools["bench_c"] = exe
    # Python with the outside libraries.
    venv = os.path.join(out, "venv")
    py = os.path.join(venv, "bin", "python3")
    if not os.path.exists(py):
        try:
            run([sys.executable, "-m", "venv", venv])
            # The newest releases have wheels for the newest Python. The
            # table records the version of each.
            for pkg in ["orjson", "pysimdjson", "uvicorn"]:
                try:
                    run([py, "-m", "pip", "install", "-q", "--only-binary", ":all:", pkg], timeout=1200)
                except RuntimeError as e:
                    log("cannot install %s: %s" % (pkg, e))
        except (OSError, RuntimeError) as e:
            log("cannot make the Python environment: %s" % e)
    tools["python"] = py if os.path.exists(py) else sys.executable
    # tcllib json for tclsh: the module files of tcllib 2.0.
    tcllib = os.path.join(data, "tcllib")
    if not os.path.isdir(tcllib) and os.path.exists(os.path.join(data, "tcllib.tar.gz")):
        with tarfile.open(os.path.join(data, "tcllib.tar.gz")) as t:
            for m in t.getmembers():
                parts = m.name.split("/")
                if len(parts) > 3 and parts[1] == "modules" and parts[2] == "json" and m.isfile():
                    m.name = "/".join(["json"] + parts[3:])
                    t.extract(m, tcllib, filter="data")
    if os.path.isdir(tcllib):
        tools["tcllib"] = tcllib
    # The sqlite3 package of tclsh and the C program, from SQLite 3.54.0.
    tclsqlite = os.path.join(out, "tclsqlite")
    src = os.path.join(out, "sqlite-autoconf-3540000")
    if not os.path.isdir(src) and os.path.exists(os.path.join(data, "sqlite-autoconf-3540000.tar.gz")):
        with tarfile.open(os.path.join(data, "sqlite-autoconf-3540000.tar.gz")) as t:
            t.extractall(out, filter="data")
    if os.path.isdir(src) and not os.path.isdir(tclsqlite):
        try:
            os.makedirs(tclsqlite)
            run(["zig", "cc", "-O2", "-shared", "-fPIC", "-DUSE_TCL_STUBS", "-DSQLITE_THREADSAFE=0",
                 "-I", src, "-I/usr/include", "-I/usr/include/tcl8.6", os.path.join(src, "tea", "generic", "tclsqlite3.c"),
                 "-L/usr/lib", "-L/usr/lib/x86_64-linux-gnu", "-ltclstub8.6", "-o", os.path.join(tclsqlite, "libtclsqlite3.so")], timeout=1200)
            with open(os.path.join(tclsqlite, "pkgIndex.tcl"), "w") as f:
                f.write("package ifneeded sqlite3 3.54.0 [list load [file join $dir libtclsqlite3.so] Sqlite3]\n")
            run(["zig", "cc", "-O2", "-DSQLITE_THREADSAFE=0", "-I", src, os.path.join(BENCH, "sqlite", "bench.c"),
                 os.path.join(src, "sqlite3.c"), "-o", os.path.join(bindir, "sqlite_c")], timeout=1200)
        except (OSError, RuntimeError) as e:
            log("cannot build the sqlite3 package: %s" % e)
            shutil.rmtree(tclsqlite, ignore_errors=True)
    if os.path.exists(os.path.join(tclsqlite, "libtclsqlite3.so")):
        tools["tclsqlite"] = tclsqlite
    # The Go programs.
    for name, d, files in [("go_json", "json", ["bench.go"]), ("go_http", "http", None),
                           ("go_tls", "tls", ["server.go"]), ("go_bulk", "tls", ["bulk.go"])]:
        exe = os.path.join(bindir, name)
        if not os.path.exists(exe) and shutil.which("go"):
            try:
                env = dict(os.environ, GOFLAGS="-mod=mod")
                cmd = ["go", "build", "-o", exe] + (files or ["."])
                run(cmd, cwd=os.path.join(BENCH, d), env=env, timeout=1200)
            except (OSError, RuntimeError) as e:
                log("cannot build %s: %s" % (name, e))
        if os.path.exists(exe):
            tools[name] = exe
    return tools


# ---- JSON ---------------------------------------------------------------


def bench_json(data, tools, ztcl, others_only):
    sizes = {f: os.path.getsize(os.path.join(data, f)) for f in JSON_FILES}
    # The ztcl script reads its files in the root folder DATA.
    for name in ["paths.json", "bench_ztcl.tcl"]:
        shutil.copy(os.path.join(BENCH, "json", name), os.path.join(data, name))
    py = tools["python"]
    pyver = version_of([py, "--version"], r"Python (\S+)")
    progs = [
        ("node", version_of(["node", "--version"]), lambda m, f: ["node", os.path.join(BENCH, "json", "bench.js"), m, f], shutil.which("node")),
        ("go encoding/json", version_of(["go", "version"], r"go(\d\S*)"), lambda m, f: [tools["go_json"], m, f], "go_json" in tools),
        ("python json", pyver, lambda m, f: [py, "-I", os.path.join(BENCH, "json", "bench.py"), "json", m, f], True),
        ("python orjson", version_of([py, "-c", "import orjson; print(orjson.__version__)"]),
         lambda m, f: [py, "-I", os.path.join(BENCH, "json", "bench.py"), "orjson", m, f], True),
        ("python pysimdjson", version_of([py, "-c", "import importlib.metadata as m; print(m.version('pysimdjson'))"]),
         lambda m, f: [py, "-I", os.path.join(BENCH, "json", "bench.py"), "simdjson", m, f], True),
        ("tclsh tcllib json", version_of(["sh", "-c", "echo 'puts [info patchlevel]' | tclsh"]) and
         "%s, tcllib 2.0" % version_of(["sh", "-c", "echo 'puts [info patchlevel]' | tclsh"]),
         lambda m, f: ["tclsh", os.path.join(BENCH, "json", "bench_tcllib.tcl"), m, f], shutil.which("tclsh") and "tcllib" in tools),
        ("simdjson dom", "4.2.0", lambda m, f: [tools["bench_c"], "simdjson-dom", m, f], "bench_c" in tools),
        ("simdjson ondemand", "4.2.0", lambda m, f: [tools["bench_c"], "simdjson-ondemand", m, f], "bench_c" in tools),
        ("yyjson", "0.12.0", lambda m, f: [tools["bench_c"], "yyjson", m, f], "bench_c" in tools),
    ]
    if not others_only:
        zver = version_of(["git", "-C", TOP, "rev-parse", "--short", "HEAD"])
        progs.insert(0, ("ztcl", zver, lambda m, f: [ztcl, "--allow", "channels,clock", "--root", data, "--tclsh",
                                                     "bench_ztcl.tcl", m, f], ztcl and os.path.exists(ztcl)))
    env = dict(os.environ, TCLLIB=tools.get("tcllib", ""), BENCH_JSON_DIR=os.path.join(BENCH, "json"))
    for name, ver, cmd, ok in progs:
        for mode in JSON_MODES:
            for f in JSON_FILES:
                case = f[:-5]
                if not ok:
                    if mode == JSON_MODES[0] and f == JSON_FILES[0]:
                        add("json", "all", "-", name, ver, "absent", "MB/s")
                    continue
                try:
                    arg = f if name == "ztcl" else os.path.join(data, f)
                    s = best_seconds(cmd(mode, arg), env=env)
                except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as e:
                    log("%s %s %s: %s" % (name, mode, f, e))
                    add("json", mode, case, name, ver, "error", "MB/s")
                    continue
                if s is None:
                    if mode == JSON_MODES[0] or name == "ztcl":
                        pass
                    continue
                add("json", mode, case, name, ver, "%.1f" % (sizes[f] / 1e6 / s), "MB/s")


# ---- HTTP ---------------------------------------------------------------


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_port(port, proc, seconds=30):
    end = time.time() + seconds
    while time.time() < end:
        if proc.poll() is not None:
            return False
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def start(cmd, port, cpus, env=None):
    if shutil.which("taskset"):
        cmd = ["taskset", "-c", cpus] + cmd
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    if not wait_port(port, p):
        stop(p)
        raise RuntimeError("the server did not start: " + " ".join(cmd))
    return p


def stop(p):
    p.terminate()
    try:
        p.wait(10)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()


def split_cpus():
    n = os.cpu_count() or 2
    half = max(1, n // 2)
    return "0-%d" % (half - 1), "%d-%d" % (half, n - 1), half


def wrk(url, seconds, client_cpus, threads, pipeline):
    cmd = ["wrk", "-t%d" % threads, "-c256", "-d%ds" % seconds, "--latency", url]
    if pipeline:
        cmd = cmd[:-1] + ["-s", os.path.join(BENCH, "http", "pipeline.lua"), url, "--", "16"]
    if shutil.which("taskset"):
        cmd = ["taskset", "-c", client_cpus] + cmd
    out = run(cmd, timeout=seconds + 60)
    rps = float(re.search(r"Requests/sec:\s+([\d.]+)", out).group(1))
    m = re.search(r"99%\s+([\d.]+)(us|ms|s)", out)
    p99 = None
    if m:
        p99 = float(m.group(1)) * {"us": 1e-3, "ms": 1.0, "s": 1e3}[m.group(2)]
    return rps, p99


def bench_http(tools, quick):
    seconds = 5 if quick else 30
    server_cpus, client_cpus, half = split_cpus()
    py = tools["python"]
    uv = version_of([py, "-c", "import uvicorn; print(uvicorn.__version__)"])
    servers = [
        ("go net/http", version_of(["go", "version"], r"go(\d\S*)"), lambda p: [tools["go_http"], str(p)], "go_http" in tools),
        ("node http", version_of(["node", "--version"]), lambda p: ["node", os.path.join(BENCH, "http", "server.js"), str(p)], shutil.which("node")),
        ("python uvicorn", uv,
         lambda p: [py, "-m", "uvicorn", "--app-dir", os.path.join(BENCH, "http"), "--log-level", "warning",
                    "--no-access-log", "--port", str(p), "app:app"], uv is not None),
    ]
    has_wrk = shutil.which("wrk") is not None
    for name, ver, cmd, ok in servers:
        for case, path, pipe in [("plaintext", "/plaintext", True), ("json", "/json", False)]:
            if not ok or not has_wrk:
                why = "absent" if not ok else "absent (no wrk)"
                add("http", "rps", case, name, ver if ok else None, why, "req/s")
                continue
            port = free_port()
            try:
                p = start(cmd(port), port, server_cpus)
            except RuntimeError as e:
                log(str(e))
                add("http", "rps", case, name, ver, "error", "req/s")
                continue
            try:
                best_rps, best_p99 = 0.0, None
                for _ in range(1 if not quick else 1):
                    rps, p99 = wrk("http://127.0.0.1:%d%s" % (port, path), seconds, client_cpus, max(1, half), pipe)
                    best_rps = max(best_rps, rps)
                    best_p99 = p99 if best_p99 is None or (p99 is not None and p99 < best_p99) else best_p99
                add("http", "rps", case, name, ver, "%.0f" % best_rps, "req/s")
                if best_p99 is not None:
                    add("http", "p99", case, name, ver, "%.2f" % best_p99, "ms")
            except (RuntimeError, AttributeError, subprocess.SubprocessError) as e:
                log("%s %s: %s" % (name, case, e))
                add("http", "rps", case, name, ver, "error", "req/s")
            finally:
                stop(p)
    # HTTP/2 with h2load against Go h2c.
    if "go_http" in tools and shutil.which("h2load"):
        port = free_port()
        p = start([tools["go_http"], str(port), "h2c"], port, server_cpus)
        try:
            cmd = ["h2load", "-c", "256", "-m", "16", "-t", str(half), "-D", str(seconds),
                   "http://127.0.0.1:%d/plaintext" % port]
            if shutil.which("taskset"):
                cmd = ["taskset", "-c", client_cpus] + cmd
            out = run(cmd, timeout=seconds + 60)
            rps = float(re.search(r"finished in [\d.]+\w+, ([\d.]+) req/s", out).group(1))
            add("http", "h2-rps", "plaintext", "go net/http h2c", servers[0][1], "%.0f" % rps, "req/s")
        except (RuntimeError, AttributeError) as e:
            log("h2load: %s" % e)
            add("http", "h2-rps", "plaintext", "go net/http h2c", servers[0][1], "error", "req/s")
        finally:
            stop(p)
    else:
        add("http", "h2-rps", "plaintext", "go net/http h2c", None, "absent (no h2load)", "req/s")


# ---- TLS ----------------------------------------------------------------


def bench_tls(tools, out, quick):
    seconds = 3 if quick else 10
    sslver = version_of(["openssl", "version"], r"OpenSSL (\S+)")
    gover = version_of(["go", "version"], r"go(\d\S*)")
    if not shutil.which("openssl"):
        for m in ["handshake", "resumed", "bulk"]:
            add("tls", m, "-", "openssl", None, "absent", "")
        return
    key = os.path.join(out, "tls-key.pem")
    cert = os.path.join(out, "tls-cert.pem")
    if not os.path.exists(cert):
        run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
             "-keyout", key, "-out", cert, "-days", "2", "-subj", "/CN=localhost"])
    server_cpus, client_cpus, _ = split_cpus()
    servers = [
        ("go crypto/tls", gover, lambda p: [tools["go_tls"], str(p), cert, key], "go_tls" in tools),
        ("openssl s_server", sslver, lambda p: ["openssl", "s_server", "-quiet", "-accept", str(p), "-cert", cert,
                                                "-key", key, "-tls1_3", "-groups", "X25519", "-www"], True),
    ]
    for name, ver, cmd, ok in servers:
        for measure, flag in [("handshake", "-new"), ("resumed", "-reuse")]:
            if not ok:
                add("tls", measure, "x25519-p256", name, None, "absent", "conn/s")
                continue
            port = free_port()
            p = start(cmd(port), port, server_cpus)
            try:
                best = 0.0
                for _ in range(1 if quick else 3):
                    c = ["openssl", "s_time", "-connect", "127.0.0.1:%d" % port, flag, "-time", str(seconds)]
                    if shutil.which("taskset"):
                        c = ["taskset", "-c", client_cpus] + c
                    o = run(c, timeout=seconds + 60)
                    m = re.search(r"(\d+) connections in (\d+) real seconds", o)
                    best = max(best, int(m.group(1)) / max(1, int(m.group(2))))
                add("tls", measure, "x25519-p256", name, ver, "%.0f" % best, "conn/s")
            except (RuntimeError, AttributeError) as e:
                log("%s %s: %s" % (name, measure, e))
                add("tls", measure, "x25519-p256", name, ver, "error", "conn/s")
            finally:
                stop(p)
    for alg in ["aes-128-gcm", "chacha20-poly1305"]:
        try:
            o = run(["openssl", "speed", "-evp", alg, "-bytes", "16384", "-seconds", "1" if quick else "3", "-mr"],
                    timeout=120)
            m = re.search(r"^\+F:\d+:[^:]+:([\d.]+)", o, re.M)
            add("tls", "bulk", alg, "openssl speed", sslver, "%.1f" % (float(m.group(1)) / 1e6), "MB/s")
        except (RuntimeError, AttributeError) as e:
            log("openssl speed %s: %s" % (alg, e))
            add("tls", "bulk", alg, "openssl speed", sslver, "error", "MB/s")
    if "go_bulk" in tools:
        for line in run([tools["go_bulk"]]).splitlines():
            alg, mb = line.split()
            add("tls", "bulk", alg, "go crypto", gover, mb, "MB/s")
    else:
        add("tls", "bulk", "-", "go crypto", None, "absent", "MB/s")


# ---- SQLite -------------------------------------------------------------


def bench_sqlite(tools, quick):
    nrows = 100000 if quick else 1000000
    try:
        c = dict(l.split() for l in run([os.path.join(tools["bindir"], "sqlite_c"), str(nrows)]).splitlines())
    except (OSError, RuntimeError, ValueError) as e:
        log("sqlite C: %s" % e)
        c = None
    if c:
        for m in ["select", "insert"]:
            add("sqlite", m, "per-row", "C API", "3.54.0", "%.1f" % (float(c[m]) / nrows * 1e9), "ns/row")
    else:
        add("sqlite", "select", "per-row", "C API", None, "absent", "ns/row")
    if "tclsqlite" not in tools or not shutil.which("tclsh") or not c:
        add("sqlite", "select", "per-row", "tclsh sqlite3", None, "absent", "ns/row")
        return
    env = dict(os.environ, TCLSQLITE=tools["tclsqlite"])
    t = dict(l.split() for l in run(["tclsh", os.path.join(BENCH, "sqlite", "bench.tcl"), str(nrows)], env=env, timeout=1200).splitlines())
    ver = "%s, sqlite3 3.54.0" % version_of(["sh", "-c", "echo 'puts [info patchlevel]' | tclsh"])
    for m in ["select", "insert"]:
        # The cost of the binding: the time of each row above the C API.
        add("sqlite", m, "per-row", "tclsh sqlite3", ver, "%.1f" % ((float(t[m]) - float(c[m])) / nrows * 1e9), "ns/row")


# ---- the table and the check -------------------------------------------


def write(out):
    tsv = os.path.join(out, "bench.tsv")
    with open(tsv, "w") as f:
        f.write("group\tmeasure\tcase\truntime\tversion\tvalue\tunit\n")
        for r in rows:
            f.write("\t".join(r) + "\n")
    md = ["| Group | Measure | Case | Runtime | Version | Value | Unit |", "|---|---|---|---|---|---:|---|"]
    for r in rows:
        md.append("| " + " | ".join(r) + " |")
    text = "\n".join(md) + "\n"
    with open(os.path.join(out, "bench.md"), "w") as f:
        f.write(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("### The outside benchmarks\n\n" + text)
    print(text)


def read_tsv(path):
    out = []
    with open(path) as f:
        next(f)
        for line in f:
            out.append(tuple(line.rstrip("\n").split("\t")))
    return out


def check(gates_path, table, dry_run, groups=None):
    """Each gate row: group, measure, case (or *), other runtime, the
    minimum ratio, and higher or lower (which side is better)."""
    gates = []
    with open(gates_path) as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if parts[0] == "group":
                continue
            if len(parts) != 6 or parts[5] not in ("higher", "lower"):
                raise SystemExit("%s:%d: a row needs 6 fields: group measure case other ratio higher|lower" % (gates_path, n))
            float(parts[4])
            gates.append(parts)
    values = {}
    for r in table:
        try:
            values[(r[0], r[1], r[2], r[3])] = float(r[5])
        except ValueError:
            pass
    bad = 0
    for group, measure, case, other, ratio, better in gates:
        if groups is not None and group not in groups:
            continue
        cases = sorted({k[2] for k in values if k[0] == group and k[1] == measure}) if case == "*" else [case]
        if not cases:
            cases = [case]
        for c in cases:
            z = values.get((group, measure, c, "ztcl"))
            o = values.get((group, measure, c, other))
            if z is None or o is None:
                print("%-6s %-9s %-14s ztcl/%-20s no number (ztcl %s, other %s)" % (group, measure, c, other, z, o))
                bad += 0 if dry_run else 1
                continue
            r = z / o if better == "higher" else o / z
            ok = r >= float(ratio)
            print("%-6s %-9s %-14s ztcl/%-20s %.2f (gate %s) %s" % (group, measure, c, other, r, ratio, "ok" if ok else "FAIL"))
            if not ok and not dry_run:
                bad += 1
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="json,http,tls,sqlite")
    ap.add_argument("--others-only", action="store_true")
    ap.add_argument("--check")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--ztcl", default=os.path.join(TOP, "zig-out", "bin", "ztcl"))
    ap.add_argument("--data")
    ap.add_argument("--out", default=os.path.join(TOP, "zig-out", "bench"))
    ap.add_argument("--quick", action="store_true", help="shorter runs, for a test of the harness")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    out = os.path.abspath(a.out)
    if a.check and a.dry_run:
        tsv = os.path.join(out, "bench.tsv")
        table = read_tsv(tsv) if os.path.exists(tsv) else []
        check(a.check, table, True)
        return 0
    data = run(["sh", os.path.join(BENCH, "fetch.sh")] + ([a.data] if a.data else []), timeout=1200).strip()
    tools = setup(data, out)
    ztcl = None if a.others_only else os.path.abspath(a.ztcl)
    groups = a.only.split(",")
    if "json" in groups:
        bench_json(data, tools, ztcl, a.others_only)
    if "http" in groups:
        bench_http(tools, a.quick)
    if "tls" in groups:
        bench_tls(tools, out, a.quick)
    if "sqlite" in groups:
        bench_sqlite(tools, a.quick)
    write(out)
    if a.check:
        return 1 if check(a.check, rows, False, groups) else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

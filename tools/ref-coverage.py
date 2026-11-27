#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Checks that the command reference covers each registered command.

Use: python3 -I tools/ref-coverage.py RUNNER

The script runs RUNNER with each capability on, loads the built-in
modules, and lists each command of each namespace. Each name must be the
name of an entry of docs/reference/*.txt or in the `names` of one. For
each ensemble, it reads the list of subcommands from the error of a bad
subcommand, and each one must have a `sub` line. The list of `info` is
the list of Tcl 8.6: a subcommand that gives "not supported by ztcl"
needs no entry. It exits with 1 when a name has no entry.
"""
import importlib.util
import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("reference", HERE / "reference.py")
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)

ALLOW = "package,interp,clock,channels,file,event,socket,exec,thread,launch,notify"
# Commands of the internals of a module.
SKIP = re.compile(r"^(ztcl::json::_|oo::Obj\d+::my$|oo::Link$|oo::UnknownDefinition$|tcl::SourceIndex$|tcl::UnknownBuiltin$|tcl::history::)")
SCRIPT = r"""
proc walk_ns {ns} {
    set out [info commands ${ns}::*]
    foreach c [namespace children $ns] { lappend out {*}[walk_ns $c] }
    return $out
}
foreach m {ztcl::json ztcl::vt ztcl::pty ztcl::watch ztcl::open ztcl::notify} { catch {package require $m} }
oo::class create __Probe
set names {}
foreach c [walk_ns ::] {
    set c [string trimleft $c :]
    if {$c ni {walk_ns __Probe}} { lappend names $c }
}
puts "names\t[lsort -unique $names]"
foreach c {string dict info namespace file chan array interp clock package trace binary encoding zipfs} {
    catch {$c __bogus__} m
    if {![regexp {must be (.*)$} $m -> list]} continue
    set list [string map {", or " " " ", " " "} $list]
    # The list of `info` is the list of Tcl 8.6. A subcommand that ztcl
    # does not have gives "not supported by ztcl" and needs no entry.
    if {$c eq "info"} {
        set have {}
        foreach w $list {
            if {[catch {info $w} m2] && [string match "*not supported by ztcl*" $m2]} continue
            lappend have $w
        }
        set list $have
    }
    puts "subs\t$c\t$list"
}
"""


def main():
    runner = sys.argv[1]
    with tempfile.NamedTemporaryFile("w", suffix=".tcl", delete=False, encoding="utf-8") as f:
        f.write(SCRIPT)
    r = subprocess.run([runner, "--allow", ALLOW, f.name], capture_output=True, text=True, timeout=60)
    pathlib.Path(f.name).unlink()
    if r.returncode != 0:
        print(f"FAIL: the runner exited with {r.returncode}: {r.stderr.strip()}")
        return 1
    entries = ref.parse()
    covered = {n for e in entries for n in ref.names(e)}
    subs = {e["name"]: set(ref.subcommands(e)) for e in entries}
    missing, count = [], 0
    for line in r.stdout.splitlines():
        kind, _, rest = line.partition("\t")
        if kind == "names":
            for name in rest.split():
                count += 1
                if not SKIP.match(name) and name not in covered:
                    missing.append(name)
        elif kind == "subs":
            cmd, _, words = rest.partition("\t")
            for w in words.split():
                count += 1
                if w not in subs.get(cmd, set()):
                    missing.append(f"{cmd} {w}")
    for m in missing:
        print(f"FAIL: no entry in docs/reference/ for {m}")
    print(f"{count} commands and subcommands, {len(missing) or 'none'} missing")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())

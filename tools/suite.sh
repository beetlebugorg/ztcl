#!/bin/sh
# Runs test files of the Tcl source on ztcl and prints the counts.
#
#   tools/suite.sh [-a] [-o file] [-r runner] [-t tag | -s tests-dir]
#                  [file.test ...]
#
#   -r  The ztcl binary. The default is zig-out/bin/ztcl.
#   -t  A Tcl release tag. The script fetches it. The default is
#       core-8-6-16.
#   -s  A folder of Tcl test files. It replaces -t.
#   -a  Runs each .test file of the folder.
#   -o  Writes one line for each file and skip reason to this file:
#       `file<TAB>pass<TAB>fail<TAB>skip<TAB>status`, then
#       `file<TAB>skipped<TAB>reason<TAB>count`.
#
# Prints one line for each file (the counts of the tests that pass,
# fail, and are skipped), then the totals. The step limit stops a test that loops.
# The memory limit (2 GiB) stops a test that allocates without end.
# SPDX-License-Identifier: BSD-2-Clause
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tcl="$here/../zig-out/bin/ztcl"; tag=core-8-6-16; tests=; all=; log=
while getopts ar:t:s:o: o; do
    case $o in
    r) tcl=$OPTARG ;;
    t) tag=$OPTARG ;;
    s) tests=$OPTARG ;;
    a) all=1 ;;
    o) log=$OPTARG; : > "$log" ;;
    *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
if [ -z "$tests" ]; then
    src=$("$here/fetch-tcl.sh" "$tag") || exit 1
    tests="$src/tests"
fi
if [ -n "$all" ]; then
    set --
    for f in "$tests"/*.test; do set -- "$@" "${f##*/}"; done
fi
[ $# -eq 0 ] && set -- set.test incr.test if.test while.test for.test \
    foreach.test proc.test uplevel.test upvar.test expr.test list.test \
    lindex.test llength.test lrange.test linsert.test lreplace.test \
    lsearch.test join.test split.test concat.test append.test \
    string.test format.test switch.test eval.test parse.test \
    lmap.test apply.test rename.test error.test \
    lset.test namespace.test regexp.test binary.test info.test dict.test scan.test
caps=package,interp,clock,channels,file,event,socket,exec
# The script `ztclsh` runs in another folder, so the runner path is absolute.
case $tcl in /*) ;; *) tcl=$PWD/$tcl ;; esac
# A time limit for one run. Without timeout(1), perl sets it and stops the
# process group of the run with exit status 124.
limit() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$@"
    else
        perl -e '$s = shift; $p = fork(); if (!$p) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127 }
            $SIG{ALRM} = sub { kill "KILL", -$p; waitpid($p, 0); exit 124 }; alarm $s; waitpid($p, 0);
            exit($? >> 8)' "$@"
    fi
}
# Windows: the runner is a native program, so it gets native paths, and
# the shell leaves its arguments as they are.
win=
case $(uname -s) in
MINGW* | MSYS* | CYGWIN*)
    win=1
    export MSYS_NO_PATHCONV=1
    ;;
esac
host_path() {
    if [ -n "$win" ]; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
hhere=$(host_path "$here")
htests=$(host_path "$tests")
execpath=/usr/bin:/bin
[ -z "$win" ] || execpath=$(cygpath -wsp /usr/bin:/bin)
# A system with no root folder jail runs the files with no `file` and no
# `exec`, so the runner has no --root.
jail=1
probe=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-suite.XXXXXX") || exit 1
: > "$probe/probe.tcl"
"$tcl" --root "$(host_path "$probe")" "$(host_path "$probe/probe.tcl")" >/dev/null 2>&1 || jail=
rm -rf -- "$probe"
[ -n "$jail" ] || caps=package,interp,clock,channels,event,socket
tp=0; tf=0; ts=0
for f in "$@"; do
    # A fresh root folder for each file, outside the repository.
    root=$(mktemp -d "${TMPDIR:-/tmp}/ztcl-suite.XXXXXX") || exit 1
    hroot=$(host_path "$root")
    # The support scripts of the Tcl tests, as a copy in the root.
    cp -- "$tests"/*.tcl "$tests"/httpd "$root"/ 2>/dev/null
    # `exec` runs only for the test files, in the root folder, with a
    # program list, a time limit, and an environment with no data of
    # the caller. `ztclsh` is the `tclsh` of the tests: this runner.
    progs=cat,echo,sh,/bin/sh,sleep,ls,grep,fgrep,wc,id,groups,whoami,ps,kill,mknod,true,false,/ztclsh
    # A process id of Windows is not an id of the `kill` and `ps` of Git
    # Bash, so these two stay off the list there.
    [ -z "$win" ] || progs=cat,echo,sh,sleep,ls,grep,fgrep,wc,id,groups,whoami,true,false,/ztclsh
    set_exec="--exec-timeout 120000 --exec-env PATH=$execpath --exec-env HOME=$hroot --exec-env LANG=C --exec-allow $progs --exe-name /ztclsh"
    [ -z "$win" ] || set_exec="$set_exec --exec-env SYSTEMROOT=$SYSTEMROOT"
    [ -n "$jail" ] || set_exec=
    cat > "$root/ztclsh" <<EOF
#!/bin/sh
exec "$tcl" --max-steps 200000000 --mem 2147483648 --allow $caps --root "$root" $set_exec --cwd "\$PWD" --tclsh "\$@"
EOF
    chmod +x "$root/ztclsh"
    if [ -n "$win" ]; then
        cp -- "$(dirname -- "$tcl")/ztclsh-launch.exe" "$root/ztclsh.exe"
        printf '%s\n' "$(cygpath -w "$tcl")" --max-steps 200000000 --mem 2147483648 --allow "$caps" --root "$hroot" $set_exec > "$root/ztclsh.args"
    fi
    raw=$(limit 1200 "$tcl" --max-steps 200000000 --mem 2147483648 --allow $caps ${jail:+--root} ${jail:+"$hroot"} $set_exec --keep-going "$hhere/tcltest.tcl" "$htests/$f" "$hhere/tcltest-end.tcl" 2>&1)
    rc=$?
    rm -rf -- "$root"
    out=$(printf '%s\n' "$raw" | grep -aE '^pass [0-9]+ fail' | tail -1)
    printf '%-16s %s\n' "$f" "${out:-no result (the file stopped early or crashed, status $rc)}"
    p=0; x=0; y=0
    if [ -n "$out" ]; then
        read -r _ p _ x _ y _ <<EOF
$out
EOF
        tp=$((tp + p)); tf=$((tf + x)); ts=$((ts + y))
    fi
    if [ -n "$log" ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$p" "$x" "$y" "$rc" >> "$log"
        printf '%s\n' "$raw" | grep -a '^skipped	' | sed "s|^skipped|$f	skipped|" >> "$log"
    fi
done
printf '%-16s pass %d fail %d skip %d\n' total "$tp" "$tf" "$ts"

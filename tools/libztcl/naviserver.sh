#!/bin/sh
# The page-load benchmark of libztcl with NaviServer (docs/dev/libztcl.md).
#   tools/libztcl/naviserver.sh build TARBALL KIT OUT
#   tools/libztcl/naviserver.sh bench KIT OUT [ROUNDS]
# build: extracts the NaviServer release TARBALL twice under OUT and
#   builds it with no change, once with --with-tcl=KIT/lib (the kit of
#   `zig build libztcl --prefix KIT`) into OUT/ns-ztcl, and once with the
#   tclConfig.sh of the Tcl of the host into OUT/ns-tcl.
# bench: writes the pages and a config with ports 18001 (Tcl) and 18002
#   (libztcl), and runs tools/libztcl/httpload.zig on each case: a static
#   file of 4 KB, a small ADP page, an ADP page with Tcl work (lists,
#   dicts, strings, and a JSON text of 200 records), and 200 keep-alive
#   connections on the small page. It prints the requests per second,
#   p50, p99, and the resident memory of nsd after the run.
# The source of NaviServer is not read; the script runs its build.
# SPDX-License-Identifier: BSD-2-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
zig=${ZIG:-zig}

build() {
  tarball=$1 kit=$(CDPATH= cd -- "$2" && pwd) out=$3
  mkdir -p "$out"
  out=$(CDPATH= cd -- "$out" && pwd)
  hostcfg=$(dirname "$(echo 'puts [info library]' | tclsh)")
  for v in ztcl tcl; do
    rm -rf "$out/src-$v"
    mkdir -p "$out/src-$v"
    tar -C "$out/src-$v" --strip-components=1 -xzf "$tarball"
    if [ $v = ztcl ]; then with=$kit/lib; else with=$hostcfg; fi
    [ -f "$with/tclConfig.sh" ] || with=/usr/lib
    (cd "$out/src-$v" && ./configure --prefix="$out/ns-$v" --with-tcl="$with" > configure.log &&
      make -j2 > make.log && make install > install.log)
  done
  ldd "$out/ns-ztcl/bin/nsd" | grep libtcl8.6
}

pages() {
  p=$1/pages
  head -c 4096 /dev/zero | tr '\0' x > "$p/static.txt"
  echo '<html><body><p>Hello <%= [ns_conn url] %> at <%= [clock seconds] %></p></body></html>' > "$p/small.adp"
  cat > "$p/work.adp" <<'EOF'
<%
set rows {}
for {set i 0} {$i < 200} {incr i} {
    lappend rows [dict create id $i name "item-$i" tags [list a b [expr {$i % 7}]] score [expr {$i * 1.5}]]
}
set out {}
foreach r $rows {
    set parts {}
    dict for {k v} $r {
        lappend parts "\"$k\": \"[string map {\" \\\"} $v]\""
    }
    lappend out "{[join $parts {, }]}"
}
set json "\[[join $out {, }]\]"
set counts [dict create]
foreach w [split [string repeat "alpha beta gamma delta " 50]] { if {$w ne ""} { dict incr counts $w } }
ns_adp_puts "<pre>[string length $json] [dict get $counts beta]</pre>"
%>
EOF
}

bench() {
  kit=$(CDPATH= cd -- "$1" && pwd) out=$(CDPATH= cd -- "$2" && pwd) rounds=${3:-2}
  "$zig" build-exe -O ReleaseFast -lc "$root/tools/libztcl/httpload.zig" -femit-bin="$out/httpload" > /dev/null
  for v in tcl ztcl; do
    port=18001; [ $v = ztcl ] && port=18002
    pages "$out/ns-$v"
    sed "s/port            8000/port            $port/" "$out/ns-$v/conf/simple-config.tcl" > "$out/ns-$v/conf/bench.tcl"
  done
  r=0
  while [ $r -lt "$rounds" ]; do
    r=$((r + 1))
    for v in tcl ztcl; do
      port=18001 lp=
      [ $v = ztcl ] && port=18002 lp=$kit/lib
      (cd "$out/ns-$v" && LD_LIBRARY_PATH=$lp exec ./bin/nsd -f -t conf/bench.tcl > "$out/nsd-$v.log" 2>&1) &
      sleep 8
      pid=$(pgrep -f "^./bin/nsd -f -t conf/bench.tcl" | head -1)
      "$out/httpload" $port work.adp 300 4 > /dev/null 2>&1
      for c in "static static.txt 30000 20" "small small.adp 10000 20" "work work.adp 2000 8" "keepalive small.adp 20000 200"; do
        set -- $c
        echo "round $r $v $1 $("$out/httpload" $port "$2" "$3" "$4" 2>&1)"
      done
      echo "round $r $v rss_kb=$(ps -o rss= -p "$pid")"
      kill "$pid"
      sleep 2
    done
  done
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
  build) build "$@" ;;
  bench) bench "$@" ;;
  *) echo "usage: $0 build TARBALL KIT OUT | bench KIT OUT [ROUNDS]" >&2; exit 2 ;;
esac

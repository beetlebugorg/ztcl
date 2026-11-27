# SPDX-License-Identifier: BSD-2-Clause
# Times regexp with and without groups on one log line. Needs --allow clock.
proc t {name body} {
    set t0 [clock microseconds]
    uplevel #0 $body
    puts [format "%-22s %8.1f ms" $name [expr {([clock microseconds]-$t0)/1000.0}]]
}
set line {10.0.12.200 - - [26/Nov/2026:10:00:00 +0000] "GET /api/v1/users HTTP/1.1" 200 4312}
proc full {line n} {for {set i 0} {$i<$n} {incr i} {regexp {^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+)} $line -> a b c d e f}; return $f}
proc nocap {line n} {for {set i 0} {$i<$n} {incr i} {set r [regexp {^\S+ \S+ \S+ \[[^\]]+\] "\S+ \S+ [^"]*" \d+ \d+} $line]}; return $r}
proc two {line n} {for {set i 0} {$i<$n} {incr i} {regexp {(\d+) (\d+)$} $line -> e f}; return $f}
proc simple {line n} {for {set i 0} {$i<$n} {incr i} {regexp {"(\S+) (\S+)} $line -> e f}; return $f}
proc kv {n} {for {set i 0} {$i<$n} {incr i} {regexp {^(\w+)=(.*)$} "key$i=value of $i" -> k v}; return $v}
t full {full $line 20000}
t nocap {nocap $line 20000}
t two {two $line 20000}
t simple {simple $line 20000}
t kv {kv 20000}

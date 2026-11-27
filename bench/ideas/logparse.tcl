# SPDX-License-Identifier: BSD-2-Clause
# Reads web server log lines with one regexp with six groups and counts by status and path.
proc gen {n} {
    set paths {/index.html /api/v1/users /api/v1/items /static/app.js /img/logo.png /login}
    set st {200 200 200 404 500 302}
    set s 7
    set out {}
    for {set i 0} {$i < $n} {incr i} {
        set s [expr {($s * 1103515245 + 12345) & 0x7fffffff}]
        set p [lindex $paths [expr {$s % 6}]]
        set c [lindex $st [expr {($s >> 8) % 6}]]
        lappend out "10.0.[expr {$s % 255}].[expr {($s>>4) % 255}] - - \[26/Nov/2026:10:00:00 +0000\] \"GET $p HTTP/1.1\" $c [expr {$s % 5000}]"
    }
    return $out
}
proc parse {lines} {
    array set bystatus {}
    set bypath [dict create]
    set bytes 0
    foreach line $lines {
        if {[regexp {^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d+) (\d+)} $line -> ip ts m path code sz]} {
            incr bystatus($code)
            dict incr bypath $path
            incr bytes $sz
        }
    }
    set r {}
    foreach k [lsort [array names bystatus]] {lappend r $k $bystatus($k)}
    return [list $r $bypath $bytes]
}
set l [gen 100000]
puts [parse $l]

# SPDX-License-Identifier: BSD-2-Clause
# Times a list of records as dicts: build, filter, dict set, dict lappend, and three sorts. Needs --allow clock.
proc t {name body} {
    set t0 [clock microseconds]
    uplevel #0 $body
    puts [format "%-14s %8.1f ms" $name [expr {([clock microseconds]-$t0)/1000.0}]]
}
proc mk {n} {
    set l {}
    for {set i 0} {$i < $n} {incr i} {
        lappend l [dict create id $i name "n[expr {$i*7919%10007}]" age [expr {$i%80}] tags [list a$i b c]]
    }
    return $l
}
proc filt {l} {
    set out {}
    foreach r $l { if {[dict get $r age] > 30} { lappend out $r } }
    return $out
}
proc dset {l} {
    set out {}
    foreach r $l { dict set r senior 1; lappend out $r }
    return $out
}
proc dlapp {l} {
    set out {}
    foreach r $l { dict lappend r tags old; lappend out $r }
    return $out
}
proc srt {l} { lsort -command {apply {{a b} {string compare [dict get $a name] [dict get $b name]}}} $l }
proc cmpn {a b} {string compare [dict get $a name] [dict get $b name]}
proc srt2 {l} { lsort -command cmpn $l }
proc srt3 {l} { lsort -index 3 $l }
t mk {set L [mk 150000]}
t filt {set F [filt $L]}
t dset {set D [dset $L]}
t dlapp {set A [dlapp $L]}
set S [lrange $F 0 20000]
t sort-apply {srt $S}
t sort-proc {srt2 $S}
t sort-index {srt3 $S}

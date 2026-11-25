# A parallel map: a list of 1 000 000 integers in 8 parts, a proc on
# each element in 8 threads, and the results back. Prints the time of
# the map in milliseconds.
# SPDX-License-Identifier: BSD-2-Clause
package require Thread
set n 1000000
set parts 8
set data {}
for {set i 0} {$i < $n} {incr i} {lappend data $i}
set ts {}
for {set p 0} {$p < $parts} {incr p} {
    lappend ts [thread::create {
        proc f {x} {expr {$x * $x + 1}}
        proc work {l} {
            set r {}
            foreach x $l {lappend r [f $x]}
            return $r
        }
        thread::wait
    }]
}
set size [expr {$n / $parts}]
set t0 [clock milliseconds]
for {set p 0} {$p < $parts} {incr p} {
    set part [lrange $data [expr {$p * $size}] [expr {($p + 1) * $size - 1}]]
    thread::send -async [lindex $ts $p] [list work $part] ::res($p)
}
for {set p 0} {$p < $parts} {incr p} {
    while {![info exists ::res($p)]} {vwait ::res($p)}
}
set total 0
for {set p 0} {$p < $parts} {incr p} {incr total [llength $::res($p)]}
puts "map [expr {[clock milliseconds] - $t0}] $total"
foreach t $ts {thread::release $t}

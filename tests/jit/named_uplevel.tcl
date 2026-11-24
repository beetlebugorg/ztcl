# SPDX-License-Identifier: BSD-2-Clause
# Differential test: `uplevel` of a loop body.
proc run {body} { uplevel 1 $body }
proc caller {} {
    set sum 0
    run { for {set i 0} {$i < 25} {incr i} { incr sum $i; if {$i == 20} break } }
    run { foreach x {a b c} { append word $x } }
    return [list $sum $i $word]
}
puts [caller]
set g 0
run { for {set j 0} {$j < 10} {incr j} { incr g [expr {$j * 3}] } }
puts [list $g $j]
proc deep {} { uplevel #0 { for {set q 0} {$q < 5} {incr q} { lappend ::ql $q } } }
deep; deep
puts $ql

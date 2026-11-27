# SPDX-License-Identifier: BSD-2-Clause
# Reads fields of CSV lines as numbers and sums them by group: split, lindex, expr on strings, dict.
# numeric strings from split used in expr: shimmer test
proc gen {n} {
    set out {}
    for {set i 0} {$i < $n} {incr i} {lappend out "$i,[expr {$i%17}],[expr {$i*3%1000}].5,name$i"}
    return [join $out \n]
}
proc agg {text} {
    set sum 0; set g [dict create]
    foreach line [split $text \n] {
        set f [split $line ,]
        set k [lindex $f 1]
        set v [lindex $f 2]
        set sum [expr {$sum + $v}]
        if {[dict exists $g $k]} {dict set g $k [expr {[dict get $g $k] + $v}]} else {dict set g $k $v}
    }
    return [list $sum [dict size $g] [dict get $g 3]]
}
set t [gen 200000]
puts [agg $t]
puts [agg $t]

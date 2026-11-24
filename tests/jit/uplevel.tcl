# SPDX-License-Identifier: BSD-2-Clause
# Differential test: uplevel, eval, and namespace eval change compiled locals.
proc setter {} { uplevel 1 {set y [expr {$x * 3}]} }
proc f {x} {
    set y 0
    setter
    eval {set z [expr {$y + 1}]}
    set w [eval [list expr {$z + 1}]]
    namespace eval ::tmp { variable q 4 }
    return [list $x $y $z $w $::tmp::q]
}
puts [f 2]
puts [f 5]
proc loop {} { set s 0; for {set i 0} {$i < 4} {incr i} { uplevel 0 {incr s $i} }; return $s }
puts [loop]

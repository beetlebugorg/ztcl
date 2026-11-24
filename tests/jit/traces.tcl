# SPDX-License-Identifier: BSD-2-Clause
# Differential test: variable traces on compiled locals.
proc f {} {
    set log {}
    set v 0
    for {set i 0} {$i < 5} {incr i} {
        if {$i == 2} { trace add variable v write [list apply {{n1 n2 op} { upvar 1 log log; lappend log w }}] }
        if {$i == 4} { trace remove variable v write [list apply {{n1 n2 op} { upvar 1 log log; lappend log w }}] }
        set v [expr {$v + $i}]
        incr v
    }
    trace add variable v read [list apply {{n1 n2 op} { upvar 1 log log; lappend log r }}]
    set x [expr {$v * 2}]
    return [list $v $x $log]
}
puts [f]
puts [f]
proc g {} { set a 5; trace add variable a unset [list apply {{args} { puts unset }}]; unset a; return [info exists a] }
puts [g]

# SPDX-License-Identifier: BSD-2-Clause
# Differential test: `info exists name` with a literal name in a proc is
# a test of the slot. Each form of a variable gives the result of the
# general command.
proc plainvar {n} {
    set r {}
    for {set i 0} {$i < $n} {incr i} {
        lappend r [info exists x]
        if {$i % 2 == 0} { set x $i } else { unset x }
    }
    return $r
}
puts [plainvar 6]
proc forms {} {
    set r [list [info exists a] [info exists g] [info exists e] [info exists l]]
    set a(1) one
    global g
    set g 5
    upvar 0 a(1) e
    upvar 0 a(2) l
    lappend r [info exists a] [info exists g] [info exists e] [info exists l]
    unset a(1)
    lappend r [info exists e] [info exists a]
    set a(2) two
    lappend r [info exists l]
    unset a
    lappend r [info exists a] [info exists l]
    return $r
}
puts [forms]
proc owned {} {
    set l {}
    set r {}
    for {set i 0} {$i < 5} {incr i} {
        lappend l $i
        lset l 0 $i
        dict set d k $i
        lappend r [info exists l] [info exists d]
    }
    list $r $l $d
}
puts [owned]
proc traced {} {
    set ::fired 0
    trace add variable t read {apply {args { incr ::fired }}}
    set r [info exists t]
    set t 1
    lappend r [info exists t]
    unset t
    lappend r [info exists t]
}
puts [traced]
proc nsvar {} {
    variable v
    set r [info exists v]
    set v 1
    lappend r [info exists v] [info exists ::v]
}
puts [nsvar]
proc redefined {} {
    set x 1
    set r [info exists x]
    rename info info_saved
    proc info {args} { return "mine $args" }
    lappend r [info exists x]
    rename info {}
    rename info_saved info
    lappend r [info exists x]
}
puts [redefined]
proc loop {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        if {![info exists seen]} { set seen 1; incr s 100 }
        if {[info exists seen]} { incr s }
        if {$i == $n / 2} { unset seen }
    }
    return $s
}
puts [loop 40]

# SPDX-License-Identifier: BSD-2-Clause
# Differential test: the reads `dict get`, `dict exists`, and `dict size`
# of an owned dict keep the ownership, and a copy never changes.
proc setget {n} {
    set d {}
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        set k k[expr {$i % 7}]
        dict set d $k $i
        incr s [dict get $d $k]
        if {[dict exists $d k3]} { incr s [dict size $d] }
    }
    return [list $s $d]
}
puts [setget 50]
proc copy {} {
    set d {a 1 b 2}
    dict set d a 10
    set c $d
    puts [dict get $d a]
    dict set d a 20
    list $c $d [dict get $c a] [dict get $d a]
}
puts [copy]
proc inlist {} {
    set d {a 1}
    dict set d b 2
    set l [list [dict get $d a] $d]
    dict set d a 3
    list $l $d
}
puts [inlist]
proc up {name} { upvar 1 $name v; dict set v z [dict size $v]; dict get $v z }
proc viaup {} {
    set d {a 1}
    dict set d b 2
    set r [up d]
    list $r $d [dict exists $d z]
}
puts [viaup]
proc traced {} {
    set d {a 1}
    set log {}
    for {set i 0} {$i < 4} {incr i} {
        dict set d a $i
        lappend log [dict get $d a]
        if {$i == 1} { trace add variable d read {apply {{args} {uplevel 1 {lappend log read}}}} }
    }
    list $log $d
}
puts [traced]
proc missing {} {
    set d {a 1}
    dict set d b 2
    list [catch {dict get $d nosuch} m] $m $::errorCode [dict exists $d nosuch] [catch {dict size "x \{"} m] $m
}
puts [missing]
proc selfkey {} {
    set d {a 1}
    dict set d b 2
    set k $d
    dict set d $k 5
    list [dict get $d $k] [catch {dict get $d $d} m] [dict exists $d $d] [dict size $d]
}
puts [selfkey]
proc notdict {} {
    set d {a b c}
    list [catch {dict get $d a} m] $m [dict exists $d a] [catch {dict size $d} m] $m
}
puts [notdict]
set g {x 1}
dict set g y 2
puts [list [dict get $g y] [dict exists $g x] [dict size $g]]
proc armset {} {
    set d {a 1}
    set c {}
    for {set i 0} {$i < 4} {incr i} {
        if {$i != 2} { dict set d a $i } else { set c $d }
    }
    set r [if {1} { dict set d b 9 }]
    list $c $d $r [if {0} { dict set d x 1 } else { dict incr d a }]
}
puts [armset]
proc joined {n} {
    set d {}
    set s 0
    for {set x 0} {$x < $n} {incr x} {
        for {set y 0} {$y < 3} {incr y} {
            dict set d $x,$y [expr {$x * $y}]
            incr s [dict get $d $x,$y]
            if {[dict exists $d $x,[expr {$y + 1}]]} { incr s 100 }
        }
    }
    list $s [dict size $d] [lindex [list a b c] $y-1]
}
puts [joined 4]

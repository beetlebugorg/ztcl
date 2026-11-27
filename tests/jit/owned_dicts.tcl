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
# A `dict set` with two or more keys writes the inner dicts in place
# when the cell owns the outer dict. Each read form of an inner dict
# below gives a copy that a later write must not change.
proc nest {n} {
    set d {}
    for {set i 0} {$i < $n} {incr i} {
        dict set d [expr {$i % 5}] [expr {$i % 3}] $i
    }
    return $d
}
puts [nest 40]
proc nestreads {} {
    set d {}
    set keep {}
    for {set i 0} {$i < 30} {incr i} {
        dict set d a b c $i
        dict set d a x $i
        switch [expr {$i % 10}] {
            0 { lappend keep [dict get $d a] }
            1 { lappend keep [dict get $d a b] }
            2 { set c $d; lappend keep $c }
            3 { foreach {k v} $d { lappend keep $v } }
            4 { dict for {k v} $d { lappend keep $v } }
            5 { lappend keep [lindex $d 1] [lindex $d 1 1] }
            6 { dict update d a e {}; lappend keep $e }
            7 { lappend keep [lrange $d 1 1] [lassign $d k] }
            8 { lappend keep [dict get [dict get $d a] b] [dict values $d] }
            9 { set m [dict merge $d]; lappend keep $m }
        }
        dict set d a b c [expr {$i * 100}]
        dict set d a b y $i
    }
    list $d $keep
}
puts [nestreads]
proc keep {v} { lappend ::held $v }
set held {}
proc nestpass {} {
    set d {}
    for {set i 0} {$i < 20} {incr i} {
        dict set d p q $i
        if {$i % 4 == 0} { keep [dict get $d p] }
        if {$i % 4 == 1} { keep $d }
        if {$i % 4 == 2} { upvar 0 d e; keep [dict get $e p] }
        dict set d p q -$i
    }
    return $d
}
puts [list [nestpass] $held]
proc nestedge {} {
    set d {a {x}}
    set r [list [catch {dict set d a b 1} m] $m $d]
    set d {}
    dict set d a 1
    lappend r [catch {dict set d a b c 2} m] $m $d
    set d {}
    for {set i 0} {$i < 6} {incr i} { dict set d k$i m n $i }
    dict set d k2 m z 7
    dict set d k9 m n 9
    lappend r $d [dict size $d]
    set d {a {b 1 b 2}}
    dict set d a c 3
    lappend r $d
    set d {}
    dict set d a b 1
    lset d 1 1 X
    dict set d a c 2
    lappend r $d
    set l {}
    for {set i 0} {$i < 3} {incr i} { lappend l [dict create k $i] }
    set d [dict create l $l]
    dict set d l 1
    dict set d n o $i
    lappend r $d
}
puts [nestedge]
proc nesttrace {} {
    set d {}
    set ::fired 0
    trace add variable d write {apply {args { incr ::fired }}}
    for {set i 0} {$i < 5} {incr i} { dict set d a b $i }
    list $d $::fired
}
puts [nesttrace]
proc nestlist {} {
    set d {}
    set keep {}
    for {set i 0} {$i < 12} {incr i} {
        dict set d r [expr {$i % 3}] [list $i]
        dict lappend d s $i
        dict append d t $i
        if {$i % 3 == 0} { lappend keep [dict get $d r] [dict get $d s] }
    }
    list $d $keep
}
puts [nestlist]

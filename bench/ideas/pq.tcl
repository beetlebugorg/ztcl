# SPDX-License-Identifier: BSD-2-Clause
# A binary heap in a list and a shortest path search on a grid: lset, lrange, dict set, dict get.
# binary heap priority queue + dijkstra on a grid graph
proc hpush {hv item} {
    upvar 1 $hv h
    lappend h $item
    set i [expr {[llength $h] - 1}]
    while {$i > 0} {
        set p [expr {($i - 1) / 2}]
        if {[lindex $h $p 0] <= [lindex $h $i 0]} break
        set t [lindex $h $p]
        lset h $p [lindex $h $i]
        lset h $i $t
        set i $p
    }
}
proc hpop {hv} {
    upvar 1 $hv h
    set top [lindex $h 0]
    set last [lindex $h end]
    set h [lrange $h 0 end-1]
    set n [llength $h]
    if {$n == 0} {return $top}
    lset h 0 $last
    set i 0
    while 1 {
        set l [expr {2*$i+1}]; set r [expr {$l+1}]; set m $i
        if {$l < $n && [lindex $h $l 0] < [lindex $h $m 0]} {set m $l}
        if {$r < $n && [lindex $h $r 0] < [lindex $h $m 0]} {set m $r}
        if {$m == $i} break
        set t [lindex $h $m]; lset h $m [lindex $h $i]; lset h $i $t
        set i $m
    }
    return $top
}
proc dijkstra {w hgt} {
    set dist [dict create]
    set heap {}
    hpush heap [list 0 0 0]
    dict set dist 0,0 0
    set seen 0
    while {[llength $heap]} {
        lassign [hpop heap] d x y
        if {$d > [dict get $dist $x,$y]} continue
        incr seen
        foreach {dx dy} {1 0 -1 0 0 1 0 -1} {
            set nx [expr {$x+$dx}]; set ny [expr {$y+$dy}]
            if {$nx < 0 || $ny < 0 || $nx >= $w || $ny >= $hgt} continue
            set nd [expr {$d + 1 + (($nx*7 + $ny*13) % 5)}]
            set k $nx,$ny
            if {![dict exists $dist $k] || $nd < [dict get $dist $k]} {
                dict set dist $k $nd
                hpush heap [list $nd $nx $ny]
            }
        }
    }
    return [list $seen [dict get $dist [expr {$w-1}],[expr {$hgt-1}]]]
}
puts [dijkstra 120 120]

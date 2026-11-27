# Deep recursion with temporary values in each frame: the stacks and the
# frames that a collection scans.
proc walk {d} {
    set mine [list $d [string repeat z 32]]
    if {$d == 0} { return [llength $mine] }
    return [expr {[walk [expr {$d - 1}]] + [llength $mine]}]
}
for {set r 0} {$r < 3000} {incr r} { walk 200 }

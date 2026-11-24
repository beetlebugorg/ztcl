# SPDX-License-Identifier: BSD-2-Clause
# Loops with helper calls in tier 2: to_bool of a value from a helper,
# incr of a value from a helper, and a jump on a string.
proc cut {line limit cutoff} {
    set r {}
    while {[string length $line] > $limit} {
        for {set c [expr {$limit-1}]} {$c >= $cutoff} {incr c -1} {
            set char [string index $line $c]
            if {$char == " " || $char == "\t"} {
                break
            }
        }
        lappend r $c
        incr c
        set line [string range $line $c end]
    }
    return $r
}
set s "so we hope to have only a single beta release and to go final in early October, 1996. and more words here to cut again"
for {set k 0} {$k < 4} {incr k} { puts [cut $s 56 50] }
proc sum {l} {
    set s 0
    for {set i 0} {$i < [llength $l]} {incr i} { incr s [lindex $l $i] }
    return $s
}
puts [sum {1 2 3 4 5 6 7 8 9 10 11 12}]
proc flags {l} {
    set n 0
    foreach f $l { if {$f} { incr n } }
    return $n
}
puts [flags {yes no 1 0 true false on off 1 1}]

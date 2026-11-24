# SPDX-License-Identifier: BSD-2-Clause
# Differential test: a loop at the global level, and one script of a
# global loop that runs two times.
set s 0
for {set i 0} {$i < 40} {incr i} { incr s $i; if {$i % 7 == 0} continue; set t [expr {$s * 2 - $i}] }
puts [list $s $t $i]
set body {
    set n 0
    foreach {a b} {1 2 3 4 5 6 7} { incr n [expr {$a + 1}]; lappend seen $a $b }
    while {$n > 3} { incr n -3 }
    set n
}
puts [eval $body]
puts [eval $body]
puts [llength $seen]

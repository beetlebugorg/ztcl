# SPDX-License-Identifier: BSD-2-Clause
# jit-diff-flags: --allow event
# Differential test: an event script that runs 100 times.
set n 0
set sum 0
set script {
    incr n
    for {set i 0} {$i < 3} {incr i} { incr sum [expr {$n * $i}] }
    if {$n < 100} { after 0 $script } else { set done 1 }
}
after 0 $script
vwait done
puts [list $n $sum]

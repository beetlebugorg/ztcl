# SPDX-License-Identifier: BSD-2-Clause
# A nested loop that builds lists with lappend and reads llength.
proc nested {n m} {
    set total 0
    for {set i 0} {$i < $n} {incr i} {
        set row {}
        for {set j 0} {$j < $m} {incr j} {
            lappend row [expr {$i * $j}]
        }
        incr total [llength $row]
    }
    return $total
}
puts [nested 1000 1000]
